defmodule Zipfelkasse.Ynab.Selection do
  @moduledoc """
  Which expenses go to a person's YNAB account. The sync and the YNAB exports share the rule, so
  both give the account the same balance: an expense dated up to YNAB's today belongs if it is
  dated on or after the start date, was entered after plan and account were chosen
  (`connected_at`), or is in YNAB already. Without a start date, all past expenses count.
  """

  alias Zipfelkasse.Ynab.Posting

  @enforce_keys [:today]
  defstruct [:today, :start, :connected_at, in_ynab: MapSet.new()]

  @type t :: %__MODULE__{
          today: Date.t(),
          start: Date.t() | nil,
          connected_at: DateTime.t() | nil,
          in_ynab: MapSet.t(integer())
        }

  @doc "Whether the posting of `expense` belongs."
  def includes?(%__MODULE__{} = selection, expense, %Posting{date: date}) do
    cond do
      Date.after?(date, selection.today) -> false
      is_nil(selection.start) or not Date.before?(date, selection.start) -> true
      entered_after?(expense, selection.connected_at) -> true
      true -> MapSet.member?(selection.in_ynab, expense.id)
    end
  end

  defp entered_after?(_expense, nil), do: false

  defp entered_after?(%{inserted_at: %DateTime{} = created}, connected_at),
    do: DateTime.compare(created, connected_at) != :lt

  defp entered_after?(_expense, _connected_at), do: false

  @doc "The postings of a person's shares that belong, by date and expense id."
  def postings(%__MODULE__{} = selection, expenses, participant_id) do
    expenses
    |> Enum.flat_map(&belonging(selection, &1, Posting.from_expense(&1, participant_id)))
    |> Enum.sort_by(&{Date.to_gregorian_days(&1.date), &1.expense_id})
  end

  defp belonging(_selection, _expense, nil), do: []

  defp belonging(selection, expense, posting),
    do: if(includes?(selection, expense, posting), do: [posting], else: [])
end
