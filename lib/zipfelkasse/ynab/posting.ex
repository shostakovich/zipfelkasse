defmodule Zipfelkasse.Ynab.Posting do
  @moduledoc """
  A person's share of an expense as an outflow in YNAB. Reimbursements are left out: they go
  through the bank as transfers there. The memo describes the whole expense and ends with the
  marker by which the sync recognizes its own transactions.
  """

  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Money

  @max_payee 200
  @max_memo 500
  @marker_prefix "zipfelkasse #"

  @enforce_keys [:expense_id, :date, :amount_cents, :payee, :memo, :category_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          expense_id: integer(),
          date: Date.t(),
          amount_cents: pos_integer(),
          payee: String.t(),
          memo: String.t(),
          category_id: integer() | nil
        }

  @doc "The posting of a person's share of `expense` (with payer and shares), or nil for none."
  def from_expense(%Expense{} = expense, participant_id) do
    share = Expense.share_of(expense, participant_id)

    if not Expense.deleted?(expense) and not expense.reimbursement and share > 0 do
      %__MODULE__{
        expense_id: expense.id,
        date: expense.date,
        amount_cents: share,
        payee: truncate(expense.title, @max_payee),
        memo: memo(expense),
        category_id: expense.category_id
      }
    end
  end

  @doc "The amount in YNAB's milliunits, negative for an outflow."
  def milliunits(%__MODULE__{amount_cents: cents}), do: -cents * 10

  @doc """
  The memo, at most 500 characters: "Gesamt 12,34 € (… USD) · bezahlt von X · zipfelkasse #7".
  """
  def memo(%Expense{} = expense) do
    total = "Gesamt " <> Money.format_cents(expense.amount_cents)

    total =
      if Expense.foreign?(expense),
        do:
          total <>
            " (#{Money.format_money(expense.original_amount, expense.original_currency)})",
        else: total

    suffix = " · " <> marker(expense.id)
    head = total <> " · bezahlt von " <> expense.paid_by.name
    truncate(head, @max_memo - length(String.codepoints(suffix))) <> suffix
  end

  @doc "The marker of an expense in a memo."
  def marker(expense_id), do: @marker_prefix <> Integer.to_string(expense_id)

  @doc "The expense id of the marker that ends `memo`, or nil."
  def marker_id(memo) do
    case Regex.run(~r/zipfelkasse #([0-9]+)[ \t\n\f\r]*\z/, memo, capture: :all_but_first) do
      [id] -> String.to_integer(id)
      nil -> nil
    end
  end

  @doc "Cuts `text` to `max` characters (code points), the last one an ellipsis."
  def truncate(text, max) do
    codepoints = String.codepoints(text)

    cond do
      length(codepoints) <= max -> text
      max <= 1 -> codepoints |> Enum.take(max(max, 0)) |> Enum.join()
      true -> (codepoints |> Enum.take(max - 1) |> Enum.join()) <> "…"
    end
  end
end
