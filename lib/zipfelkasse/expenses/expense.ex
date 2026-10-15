defmodule Zipfelkasse.Expenses.Expense do
  @moduledoc """
  An expense, or a reimbursement between two people, in euro cents. A foreign one keeps its
  original amount (minor units of its currency) and the rate (units per 1 €) it was converted
  at; a euro one has its cents as original amount and rate 1.

  The virtual `parts` are the people and weights it is split by, as `Zipfelkasse.Split` takes
  them; the shares follow from them. Expenses are deleted softly.
  """

  use Zipfelkasse.Schema

  import Ecto.Changeset

  alias Zipfelkasse.Categories.Category
  alias Zipfelkasse.Expenses.ExpenseShare
  alias Zipfelkasse.{Money, Names, Split}
  alias Zipfelkasse.Participants.Participant
  alias Zipfelkasse.Recurring.RecurringExpense

  @reimbursement_title "Rückzahlung"
  # As maxlength in the expense form.
  @max_title 200
  @max_notes 2000
  @amount_fields [:original_currency, :original_amount, :fx_rate, :amount_cents, :parts]

  @fields [
    :title,
    :date,
    :category_id,
    :paid_by_id,
    :notes,
    :reimbursement,
    :split_mode,
    :amount_cents,
    :original_amount,
    :original_currency,
    :fx_rate,
    :fx_source,
    :parts
  ]

  schema "expenses" do
    field :title, :string, default: ""
    field :title_folded, :string
    field :date, :date
    belongs_to :category, Category
    belongs_to :paid_by, Participant
    field :notes, :string, default: ""
    field :notes_folded, :string, default: ""
    field :reimbursement, :boolean, default: false
    field :split_mode, Ecto.Enum, values: Split.modes(), default: :equal
    field :amount_cents, :integer
    field :original_amount, :integer
    field :original_currency, :string, default: "EUR"
    field :fx_rate, :float
    field :fx_source, Ecto.Enum, values: [:ecb, :manual]
    field :parts, {:array, :map}, virtual: true, default: []
    belongs_to :recurring_expense, RecurringExpense
    has_many :shares, ExpenseShare, preload_order: [asc: :participant_id]
    field :deleted_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The default title of a reimbursement."
  def reimbursement_title, do: @reimbursement_title

  @doc """
  Normalizes and checks an expense input: title and notes, payer, a reimbursement's recipient,
  the conversion of a foreign amount into euros and the split. Whether the people and the
  category exist is up to the caller.
  """
  def changeset(expense, attrs) do
    expense
    |> cast(attrs, @fields, empty_values: [])
    |> normalize_text()
    |> validate_title()
    |> validate_notes()
    |> validate_required(:date, message: "Bitte ein Datum angeben.")
    |> validate_payer()
    |> validate_reimbursement()
    |> convert_amount()
    |> validate_split()
    |> unique_constraint([:recurring_expense_id, :date],
      message: "Für diesen Termin gibt es schon eine Ausgabe dieser Wiederholung."
    )
  end

  defp normalize_text(changeset) do
    title = Names.normalize(get_field(changeset, :title) || "")
    notes = String.trim(get_field(changeset, :notes) || "")

    changeset
    |> put_change(:title, title)
    |> put_change(:title_folded, :string.casefold(title))
    |> put_change(:notes, notes)
    |> put_change(:notes_folded, :string.casefold(notes))
  end

  defp validate_title(changeset) do
    if get_field(changeset, :title) == "" do
      add_error(changeset, :title, "Bitte einen Titel angeben.")
    else
      validate_length(changeset, :title,
        max: @max_title,
        count: :codepoints,
        message: "Der Titel ist zu lang (höchstens #{@max_title} Zeichen)."
      )
    end
  end

  # Browsers count a line break as one character for maxlength but send it as CR LF.
  defp validate_notes(changeset) do
    notes = changeset |> get_field(:notes) |> String.replace("\r\n", "\n")

    if codepoints(notes) > @max_notes do
      add_error(changeset, :notes, "Die Notiz ist zu lang (höchstens #{@max_notes} Zeichen).")
    else
      changeset
    end
  end

  defp codepoints(text), do: text |> String.codepoints() |> length()

  defp validate_payer(changeset) do
    case get_field(changeset, :paid_by_id) do
      id when is_integer(id) and id > 0 -> changeset
      _missing -> add_error(changeset, :paid_by_id, "Bitte angeben, wer bezahlt hat.")
    end
  end

  defp validate_reimbursement(changeset) do
    if get_field(changeset, :reimbursement) do
      changeset
      |> put_change(:split_mode, :equal)
      |> validate_recipient(parts(changeset), get_field(changeset, :paid_by_id))
    else
      changeset
    end
  end

  defp validate_recipient(changeset, [%{participant_id: payer}], payer) do
    add_error(
      changeset,
      :parts,
      "Bei einer Rückzahlung müssen Zahler und Empfänger verschieden sein."
    )
  end

  defp validate_recipient(changeset, [_recipient], _payer), do: changeset

  defp validate_recipient(changeset, _parts, _payer),
    do: add_error(changeset, :parts, "Eine Rückzahlung geht an genau eine Person.")

  defp convert_amount(changeset) do
    currency = get_field(changeset, :original_currency) || ""

    if Money.eur?(currency) do
      changeset
      |> put_change(:original_currency, "EUR")
      |> put_change(:original_amount, get_field(changeset, :amount_cents))
      |> put_change(:fx_rate, 1.0)
      |> put_change(:fx_source, nil)
    else
      code = Money.normalize_currency(currency)
      changeset |> put_change(:original_currency, code) |> convert_foreign(code)
    end
  end

  defp convert_foreign(changeset, code) do
    minor = get_field(changeset, :original_amount)
    rate = get_field(changeset, :fx_rate)

    cond do
      not Money.valid_currency?(code) ->
        add_error(changeset, :original_currency, "Ungültige Währung „#{code}“.")

      not (is_integer(minor) and minor > 0) ->
        add_error(changeset, :original_amount, "Bitte den Betrag in #{code} angeben.")

      not (is_number(rate) and rate > 0) ->
        add_error(changeset, :fx_rate, "Bitte einen Wechselkurs für #{code} angeben.")

      true ->
        put_eur_cents(changeset, Money.to_eur_cents(minor, code, rate))
    end
  end

  defp put_eur_cents(changeset, {:ok, cents}) when cents > 0,
    do: put_change(changeset, :amount_cents, cents)

  defp put_eur_cents(changeset, {:ok, _zero}),
    do:
      add_error(
        changeset,
        :amount_cents,
        "Umgerechnet ergibt der Betrag 0 € – bitte Betrag und Kurs prüfen."
      )

  defp put_eur_cents(changeset, {:error, message}),
    do: add_error(changeset, :amount_cents, message)

  defp validate_split(changeset) do
    total = get_field(changeset, :amount_cents) || 0

    cond do
      Enum.any?(changeset.errors, fn {field, _error} -> field in @amount_fields end) ->
        changeset

      total <= 0 ->
        add_error(changeset, :amount_cents, "Der Betrag muss größer als 0 sein.")

      total > Money.max_cents() ->
        add_error(changeset, :amount_cents, "Der Betrag ist zu groß.")

      true ->
        case shares(apply_changes(changeset), 0) do
          {:ok, shares} ->
            put_change(changeset, :parts, Enum.map(shares, &Map.delete(&1, :amount_cents)))

          {:error, message} ->
            add_error(changeset, :parts, message)
        end
    end
  end

  defp parts(changeset), do: changeset |> get_field(:parts) |> Enum.map(&part/1)

  defp part(part) do
    %{participant_id: Map.get(part, :participant_id) || 0, weight: Map.get(part, :weight) || 0}
  end

  @doc """
  The shares of `expense` (with its parts set by `changeset/2`) in euro cents; ties take turns
  by `rotation`, the expense id.
  """
  def shares(expense, rotation) do
    Split.split(expense.split_mode, expense.amount_cents, Enum.map(expense.parts, &part/1),
      rotation: rotation,
      original: expense.original_amount,
      currency: expense.original_currency
    )
  end

  @doc "Whether the amount was entered in another currency than euros."
  def foreign?(%__MODULE__{original_currency: currency}), do: not Money.eur?(currency)

  @doc "The share of a person in euro cents, 0 if they have none."
  def share_of(%__MODULE__{shares: shares}, participant_id) do
    Enum.find_value(shares, 0, &(&1.participant_id == participant_id && &1.amount_cents))
  end

  @doc "Whether the expense is deleted."
  def deleted?(%__MODULE__{deleted_at: deleted_at}), do: not is_nil(deleted_at)
end
