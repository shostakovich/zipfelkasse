defmodule Zipfelkasse.Expenses.Form do
  @moduledoc """
  The expense form as entered: German text in its fields, so that values stay as typed after an
  error. A row per person holds whether they share the expense and their weight as text; an
  empty weight is one share, or nothing of a percentage or an amount.

  `changeset/3` also follows what one edit implies for the rest: a new split mode fills in even
  weights, a reimbursement goes to one recipient, a new currency drops the rate, a typed rate
  is manual, and a title suggests a category. `preview/2` splits the amount as entered;
  `input/1` reads a valid form into an expense input.
  """

  use Zipfelkasse.Schema

  import Ecto.Changeset

  alias Zipfelkasse.{Dates, Money, Split, Suggestions}
  alias Zipfelkasse.Expenses.Expense

  # Offered in the form; other ISO codes go in currency_other.
  @common_currencies ~w(EUR USD GBP CHF DKK SEK NOK PLN CZK HUF TRY JPY CAD AUD)
  @text_fields [:title, :date, :currency, :currency_other, :amount, :rate, :notes]
  @error_fields %{
    title: :title,
    notes: :notes,
    date: :date,
    paid_by_id: :paid_by_id,
    category_id: :category_id,
    parts: :rows,
    amount_cents: :amount,
    original_amount: :amount,
    original_currency: :currency,
    fx_rate: :rate,
    recurring_expense_id: :date
  }

  @primary_key false
  embedded_schema do
    field :expense_id, :integer
    field :title, :string, default: ""
    field :date, :string, default: ""
    field :category_id, :integer
    field :category_suggested, :boolean, default: false
    field :currency, :string, default: "EUR"
    field :currency_other, :string, default: ""
    field :amount, :string, default: ""
    field :rate, :string, default: ""
    field :rate_source, Ecto.Enum, values: [:ecb, :manual]
    field :rate_hint, :string
    field :paid_by_id, :integer
    field :notes, :string, default: ""
    field :reimbursement, :boolean, default: false
    field :split_mode, Ecto.Enum, values: Split.modes(), default: :equal

    embeds_many :rows, Row,
      primary_key: {:participant_id, :integer, autogenerate: false},
      on_replace: :delete do
      field :name, :string
      field :archived, :boolean, default: false
      field :selected, :boolean, default: false
      field :weight, :string, default: ""
    end
  end

  @doc "The currencies the form offers."
  def common_currencies, do: @common_currencies

  @doc """
  A blank form for `today`, paid by `:participant_id`, shared by every active person of
  `people`. With `reimbursement: true` it pays `:amount_cents` back from `:from` to `:to`.
  """
  def new(people, opts) do
    if Keyword.get(opts, :reimbursement, false) do
      new_reimbursement(people, opts)
    else
      paid_by = opts[:participant_id]

      %__MODULE__{
        date: Date.to_iso8601(Keyword.fetch!(opts, :today)),
        paid_by_id: paid_by,
        rows:
          for(
            person <- people,
            not archived?(person) or person.id == paid_by,
            do: row(person, not archived?(person), "")
          )
      }
    end
  end

  defp new_reimbursement(people, opts) do
    to = opts[:to]
    paid_by = opts[:from] || opts[:participant_id]

    %__MODULE__{
      title: Expense.reimbursement_title(),
      date: Date.to_iso8601(Keyword.fetch!(opts, :today)),
      amount: prefilled_amount(opts[:amount_cents]),
      paid_by_id: paid_by,
      reimbursement: true,
      rows:
        for(
          person <- people,
          not archived?(person) or person.id in [paid_by, to],
          do: row(person, person.id == to, "")
        )
    }
  end

  defp prefilled_amount(cents) when is_integer(cents) and cents > 0,
    do: Money.format_cents_input(cents)

  defp prefilled_amount(_cents), do: ""

  @doc "The form of a saved expense; archived people show only when they paid or share it."
  def from_expense(%Expense{} = expense, people) do
    shares = Map.new(expense.shares, &{&1.participant_id, &1})

    struct(
      %__MODULE__{
        expense_id: expense.id,
        title: expense.title,
        date: Date.to_iso8601(expense.date),
        category_id: expense.category_id,
        paid_by_id: expense.paid_by_id,
        notes: expense.notes,
        reimbursement: expense.reimbursement,
        split_mode: expense.split_mode,
        rows:
          for person <- people,
              share <- [shares[person.id]],
              not archived?(person) or share != nil or person.id == expense.paid_by_id do
            row(person, share != nil, share && weight_text(expense, share))
          end
      },
      amount_fields(expense)
    )
  end

  defp amount_fields(%Expense{original_currency: currency} = expense) do
    fields =
      if currency in @common_currencies,
        do: %{currency: currency, currency_other: ""},
        else: %{currency: "", currency_other: currency}

    if Expense.foreign?(expense) do
      Map.merge(fields, %{
        amount: Money.format_minor_input(expense.original_amount, currency),
        rate: Money.format_rate(expense.fx_rate),
        rate_source: expense.fx_source
      })
    else
      Map.put(fields, :amount, Money.format_cents_input(expense.amount_cents))
    end
  end

  defp archived?(person), do: not is_nil(person.archived_at)

  defp row(person, selected?, weight) do
    %__MODULE__.Row{
      participant_id: person.id,
      name: person.name,
      archived: archived?(person),
      selected: selected?,
      weight: weight || ""
    }
  end

  defp weight_text(%Expense{split_mode: :equal}, _share), do: ""
  defp weight_text(%Expense{split_mode: :shares}, share), do: Integer.to_string(share.weight)

  defp weight_text(%Expense{split_mode: :percent}, share), do: format_percent(share.weight)

  defp weight_text(%Expense{split_mode: :amount} = expense, share),
    do: Money.format_minor_input(share.weight, expense.original_currency)

  @doc """
  Applies the form's params and what they imply. Option `:suggestions` (see
  `Zipfelkasse.Suggestions`) suggests a category for a new title while none was chosen.
  """
  def changeset(%__MODULE__{} = form, params, opts \\ []) do
    form
    |> restore(params)
    |> follow_reimbursement(form)
    |> follow_split(form)
    |> follow_rate(form)
    |> follow_category(form, opts[:suggestions])
  end

  @doc """
  Applies the params as they are, as a reconnect recovers them: the form's state before it
  was lost, not an edit with consequences.
  """
  def restore(%__MODULE__{} = form, params) do
    form
    |> cast(params, @text_fields, empty_values: [])
    |> cast(params, [:category_id, :paid_by_id, :rate_source, :split_mode, :reimbursement])
    |> update_change(:split_mode, &(&1 || :equal))
    |> update_change(:reimbursement, &(&1 || false))
    |> cast_embed(:rows, with: &row_changeset/2)
    |> drop_unknown_rows(form)
  end

  defp row_changeset(row, params) do
    row
    |> cast(params, [:participant_id, :weight], empty_values: [])
    |> cast(params, [:selected])
    |> update_change(:selected, &(&1 || false))
  end

  defp drop_unknown_rows(changeset, form) do
    known = MapSet.new(form.rows, & &1.participant_id)
    rows = get_field(changeset, :rows)

    if Enum.all?(rows, &(&1.participant_id in known)) do
      changeset
    else
      put_embed(
        changeset,
        :rows,
        for(row <- rows, row.participant_id in known, do: Map.from_struct(row))
      )
    end
  end

  defp follow_reimbursement(changeset, form) do
    newly_selected = selected_ids(changeset) -- selected_ids(form)

    cond do
      not get_field(changeset, :reimbursement) ->
        changeset

      not form.reimbursement ->
        payer = get_field(changeset, :paid_by_id)
        keep = changeset |> selected_ids() |> Enum.sort() |> Enum.find(&(&1 != payer))

        changeset |> default_title() |> select_only(keep)

      newly_selected != [] ->
        select_only(changeset, hd(newly_selected))

      true ->
        changeset
    end
  end

  defp default_title(changeset) do
    if String.trim(get_field(changeset, :title)) == "",
      do: put_change(changeset, :title, Expense.reimbursement_title()),
      else: changeset
  end

  defp select_only(changeset, id),
    do: map_rows(changeset, &%{&1 | selected: &1.participant_id == id})

  defp follow_split(changeset, form) do
    cond do
      get_field(changeset, :split_mode) != form.split_mode ->
        fill_defaults(changeset)

      mode(changeset) in [:percent, :amount] and selected_ids(changeset) != selected_ids(form) ->
        fill_defaults(changeset)

      true ->
        changeset
    end
  end

  defp follow_rate(changeset, form) do
    cond do
      currency_code(changeset) != currency_code(change(form)) ->
        changeset
        |> put_change(:rate, "")
        |> put_change(:rate_source, nil)
        |> put_change(:rate_hint, nil)

      get_field(changeset, :rate) != form.rate ->
        changeset
        |> put_change(:rate_source, :manual)
        |> put_change(:rate_hint, "Von Hand eingetragener Kurs.")

      true ->
        changeset
    end
  end

  defp follow_category(changeset, form, suggestions) do
    cond do
      get_field(changeset, :category_id) != form.category_id ->
        put_change(changeset, :category_suggested, false)

      suggestions && get_field(changeset, :title) != form.title &&
          (is_nil(form.category_id) or form.category_suggested) ->
        category_id = Suggestions.suggest(suggestions, get_field(changeset, :title))

        changeset
        |> put_change(:category_id, category_id)
        |> put_change(:category_suggested, not is_nil(category_id))

      true ->
        changeset
    end
  end

  @doc "Selects every person, or nobody when everybody is selected."
  def select_all(%__MODULE__{} = form) do
    selected? = not Enum.all?(form.rows, & &1.selected)
    changeset = form |> change() |> map_rows(&%{&1 | selected: selected?})

    if mode(changeset) in [:percent, :amount], do: fill_defaults(changeset), else: changeset
  end

  defp fill_defaults(changeset) do
    selected = changeset |> selected_ids() |> Enum.sort()
    defaults = Map.new(Enum.zip(selected, defaults(changeset, length(selected))))
    map_rows(changeset, &%{&1 | weight: Map.get(defaults, &1.participant_id, "")})
  end

  defp defaults(_changeset, 0), do: []

  defp defaults(changeset, count) do
    ones = List.duplicate(1, count)

    case mode(changeset) do
      :shares ->
        List.duplicate("1", count)

      :percent ->
        10_000 |> Split.allocate(ones, 0) |> Enum.map(&format_percent/1)

      :amount ->
        decimals = changeset |> currency_code() |> Money.decimals()

        case Money.parse(get_field(changeset, :amount), decimals) do
          {:ok, total} when total > 0 ->
            total |> Split.allocate(ones, 0) |> Enum.map(&Money.format_minor(&1, decimals))

          _none ->
            List.duplicate("", count)
        end

      :equal ->
        List.duplicate("", count)
    end
  end

  defp format_percent(points) when rem(points, 100) == 0, do: Integer.to_string(div(points, 100))
  defp format_percent(points), do: Money.format_minor(points, 2)

  @doc """
  Puts a looked-up rate (see `Zipfelkasse.Fx.rate/3`) into the form, or clears it when there is
  none.
  """
  def put_rate(%__MODULE__{} = form, {:ok, rate}) do
    hint = if rate.source == :manual, do: "Manueller Kurs", else: "EZB-Kurs"

    change(form,
      rate: Money.format_rate(rate.rate),
      rate_source: rate.source,
      rate_hint: "#{hint} vom #{Dates.format(rate.date)}."
    )
  end

  def put_rate(%__MODULE__{} = form, {:error, _reason}) do
    change(form,
      rate: "",
      rate_source: nil,
      rate_hint: "Kein Kurs verfügbar. Kurs bitte von Hand eintragen."
    )
  end

  @doc """
  Whether a change of the form calls for looking the rate up: in another currency than euros,
  when the currency changed, or the date while the rate is not manual.
  """
  def rate_lookup?(%Ecto.Changeset{data: form} = changeset) do
    currency = currency_code(changeset)

    Money.valid_currency?(currency) and currency != "EUR" and
      (currency != currency_code(change(form)) or
         (get_field(changeset, :date) != form.date and
            get_field(changeset, :rate_source) != :manual))
  end

  @doc """
  The split of the amount as entered, as the form shows it while typing: the amount in euro cents
  (nil until it is valid), the cents of each selected person (by the largest remainder with
  `rotation`, the expense id), and a hint on the sum of percentages or amounts.
  """
  def preview(%Ecto.Changeset{} = changeset, rotation),
    do: changeset |> apply_changes() |> preview(rotation)

  def preview(%__MODULE__{} = form, rotation) do
    currency =
      case currency_code(form) do
        "" -> "EUR"
        code -> code
      end

    total = eur_total(form, currency)
    selected = form.rows |> Enum.filter(& &1.selected) |> Enum.sort_by(& &1.participant_id)

    cond do
      not (is_integer(total) and total > 0) -> %{eur_cents: nil, sum: nil, shares: %{}}
      selected == [] -> %{eur_cents: total, sum: nil, shares: %{}}
      true -> split_preview(form, currency, total, selected, rotation)
    end
  end

  defp split_preview(form, currency, total, selected, rotation) do
    mode = form |> change() |> mode()
    decimals = if mode == :amount, do: Money.decimals(currency), else: 2
    weights = Enum.map(selected, &preview_weight(mode, currency, &1.weight))

    {sum, shares} =
      if Enum.all?(weights, &(is_integer(&1) and &1 >= 0)),
        do: preview_sum(form, mode, currency, decimals, weights, total, rotation),
        else: {{:error, "Bitte nur gültige Zahlen eingeben."}, nil}

    ids = Enum.map(selected, & &1.participant_id)

    %{
      eur_cents: total,
      sum: sum,
      shares: if(shares, do: Map.new(Enum.zip(ids, shares)), else: %{})
    }
  end

  defp eur_total(form, "EUR"), do: ok_or_nil(Money.parse(form.amount, 2))

  defp eur_total(form, currency) do
    with {:ok, minor} <- Money.parse(form.amount, Money.decimals(currency)),
         {:ok, rate} <- Money.parse_rate(form.rate),
         {:ok, cents} <- Money.to_eur_cents(minor, currency, rate),
         do: cents,
         else: (_invalid -> nil)
  end

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_error), do: nil

  defp preview_weight(:equal, _currency, _text), do: 1

  defp preview_weight(mode, currency, text),
    do: ok_or_nil(Split.parse_weight(mode, currency, weight_or_default(mode, text)))

  defp preview_sum(_form, :percent, _currency, _decimals, weights, total, rotation) do
    case 10_000 - Enum.sum(weights) do
      0 ->
        {{:ok, "Summe 100 %."}, allocate(total, weights, rotation)}

      missing ->
        sum = format_percent(Enum.sum(weights))

        rest =
          if missing > 0,
            do: "es fehlen #{format_percent(missing)}",
            else: "#{format_percent(-missing)} zu viel"

        {{:error, "Summe #{sum} % – #{rest} %."}, nil}
    end
  end

  defp preview_sum(form, :amount, currency, decimals, weights, total, rotation) do
    target = if currency == "EUR", do: total, else: ok_or_nil(Money.parse(form.amount, decimals))
    unit = if currency == "EUR", do: " €", else: " " <> currency
    sum = Enum.sum(weights)

    cond do
      sum == target ->
        {{:ok, "Passt: #{Money.format_minor(sum, decimals)}#{unit}."},
         allocate(total, weights, rotation)}

      target > sum ->
        {{:error, "Noch #{Money.format_minor(target - sum, decimals)}#{unit} offen."}, nil}

      true ->
        {{:error, "#{Money.format_minor(sum - target, decimals)}#{unit} zu viel."}, nil}
    end
  end

  defp preview_sum(_form, _mode, _currency, _decimals, weights, total, rotation),
    do: {nil, allocate(total, weights, rotation)}

  defp allocate(total, weights, rotation) do
    if Enum.sum(weights) > 0, do: Split.allocate(total, weights, rotation)
  end

  @doc """
  Reads the form into an expense input (see `Zipfelkasse.Expenses.input/1`); the rate of a
  foreign currency is as typed and still to be resolved. Errors go on the form's fields.
  """
  def input(%Ecto.Changeset{} = changeset), do: changeset |> apply_changes() |> input()

  def input(%__MODULE__{} = form) do
    changeset = change(form)
    currency = currency_code(changeset)

    {changeset, input} =
      {changeset, %{}}
      |> read(:date, fn -> Dates.parse(form.date) end)
      |> read(:currency, fn -> read_currency(currency) end)
      |> read(:amount, fn -> read_amount(form, currency) end)
      |> read(:rate, fn -> read_rate(form, currency) end)
      |> read(:rows, fn -> parts(form, currency) end)

    if changeset.errors == [] do
      {:ok,
       %{
         title: form.title,
         date: input.date,
         category_id: form.category_id,
         paid_by_id: form.paid_by_id,
         notes: form.notes,
         reimbursement: form.reimbursement,
         split_mode: mode(changeset),
         amount_cents: input.amount,
         original_amount: input.amount,
         original_currency: currency,
         fx_rate: input.rate,
         fx_source: if(input.rate, do: form.rate_source),
         parts: input.rows
       }}
    else
      {:error, %{changeset | action: :validate}}
    end
  end

  defp read({changeset, input}, field, read) do
    case read.() do
      {:ok, value} -> {changeset, Map.put(input, field, value)}
      {:error, message} -> {add_error(changeset, field, message), Map.put(input, field, nil)}
    end
  end

  defp read_currency(""), do: {:error, "Bitte eine Währung angeben."}

  defp read_currency(currency) do
    if Money.valid_currency?(currency),
      do: {:ok, currency},
      else:
        {:error,
         "Ungültige Währung „#{currency}“ – bitte einen dreistelligen ISO-Code wie USD angeben."}
  end

  defp read_amount(form, currency) do
    case Money.parse(form.amount, Money.decimals(currency)) do
      {:ok, minor} when minor <= 0 -> {:error, "Der Betrag muss größer als 0 sein."}
      result -> result
    end
  end

  defp read_rate(form, currency) do
    if Money.eur?(currency) or String.trim(form.rate) == "",
      do: {:ok, nil},
      else: Money.parse_rate(form.rate)
  end

  defp parts(form, currency) do
    selected = Enum.filter(form.rows, & &1.selected)

    cond do
      form.reimbursement and length(selected) != 1 ->
        {:error,
         "Eine Rückzahlung geht an genau eine Person – bitte genau einen Empfänger ankreuzen."}

      form.reimbursement ->
        {:ok, [%{participant_id: hd(selected).participant_id, weight: 0}]}

      selected == [] ->
        {:error, "Bitte mindestens eine Person ankreuzen, für die bezahlt wurde."}

      true ->
        read_weights(selected, form.split_mode, currency)
    end
  end

  defp read_weights(rows, mode, currency) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, parts} ->
      case weight(mode, currency, row) do
        {:ok, weight} ->
          {:cont, {:ok, parts ++ [%{participant_id: row.participant_id, weight: weight}]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp weight(mode, currency, row) do
    case Split.parse_weight(mode, currency, weight_or_default(mode, row.weight)) do
      {:ok, weight} when weight < 0 ->
        {:error, "#{row.name}: Negative Werte sind nicht erlaubt."}

      {:ok, weight} ->
        {:ok, weight}

      {:error, message} ->
        {:error,
         if(String.starts_with?(message, row.name), do: message, else: "#{row.name}: #{message}")}
    end
  end

  defp weight_or_default(mode, text) do
    case String.trim(text) do
      "" when mode == :shares -> "1"
      "" -> "0"
      text -> text
    end
  end

  @doc "Puts the errors of an expense changeset on the fields of the form."
  def put_errors(%__MODULE__{} = form, %Ecto.Changeset{} = expense_changeset) do
    changeset =
      Enum.reduce(expense_changeset.errors, change(form), fn {field, {message, opts}},
                                                             changeset ->
        add_error(changeset, Map.get(@error_fields, field, :title), message, opts)
      end)

    %{changeset | action: expense_changeset.action || :validate}
  end

  @doc "The currency code the form is in: the chosen one or the one typed as other."
  def currency_code(%Ecto.Changeset{} = changeset) do
    case get_field(changeset, :currency) do
      blank when blank in [nil, ""] -> get_field(changeset, :currency_other)
      currency -> currency
    end
    |> Money.normalize_currency()
  end

  def currency_code(%__MODULE__{} = form), do: form |> change() |> currency_code()

  defp mode(changeset) do
    if get_field(changeset, :reimbursement), do: :equal, else: get_field(changeset, :split_mode)
  end

  defp selected_ids(%__MODULE__{rows: rows}),
    do: for(row <- rows, row.selected, do: row.participant_id)

  defp selected_ids(changeset),
    do: changeset |> get_field(:rows) |> then(&selected_ids(%__MODULE__{rows: &1}))

  # As maps: Ecto takes a struct with a known primary key for the unchanged row.
  defp map_rows(changeset, fun) do
    rows = for row <- get_field(changeset, :rows), do: row |> fun.() |> Map.from_struct()
    put_embed(changeset, :rows, rows)
  end
end
