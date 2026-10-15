defmodule Zipfelkasse.Balances do
  @moduledoc """
  Balances over all expenses that are not deleted, reimbursements included: positive means the
  others owe the person. See `Zipfelkasse.Ledger` for the math.
  """

  import Ecto.Query

  alias Zipfelkasse.Expenses.{Expense, ExpenseShare}
  alias Zipfelkasse.{Ledger, LocalTime, Periods, Repo}

  @doc "The balance of everybody who paid or shares an expense, by participant id."
  @spec balances() :: %{integer() => integer()}
  def balances do
    paid =
      from e in Expense,
        where: is_nil(e.deleted_at),
        group_by: e.paid_by_id,
        select: {e.paid_by_id, sum(e.amount_cents)}

    shared =
      from s in ExpenseShare,
        join: e in assoc(s, :expense),
        where: is_nil(e.deleted_at),
        group_by: s.participant_id,
        select: {s.participant_id, sum(s.amount_cents)}

    balances = Map.new(Repo.all(paid))

    shared
    |> Repo.all()
    |> Enum.reduce(balances, fn {id, cents}, balances ->
      Map.update(balances, id, -cents, &(&1 - cents))
    end)
  end

  @doc "The balance of one person."
  @spec balance(integer()) :: integer()
  def balance(participant_id), do: Map.get(balances(), participant_id, 0)

  @doc "The transfers that settle all balances."
  @spec settlement() :: [Ledger.transfer()]
  def settlement, do: Ledger.settle(balances())

  @doc """
  The balances at the end of each period of `unit` (`:year`, `:month` or `:week`), by expense
  date: later edits and deletions apply retroactively. Options: `:from` and `:to` (dates in the
  first and last period; by default the first expense and today, or a later expense) and
  `:today`.
  """
  def history(unit, opts \\ []) do
    to = opts[:to]
    entries = dated_entries(to && Periods.last_day(unit, to))
    to = to || last_date(entries, Keyword.get_lazy(opts, :today, &LocalTime.today/0))
    from = opts[:from] || first_date(entries)
    from = if from && not Date.after?(from, to), do: from, else: to

    {periods, _rest, _balances} =
      unit
      |> Periods.labels(from, to)
      |> Enum.reduce({[], entries, %{}}, fn label, {periods, entries, balances} ->
        {until, rest} =
          Enum.split_while(entries, fn {date, _entry} -> Periods.label(unit, date) <= label end)

        balances =
          until
          |> Enum.map(&elem(&1, 1))
          |> Ledger.balances()
          |> Map.merge(balances, fn _id, a, b -> a + b end)

        {[{label, balances} | periods], rest, balances}
      end)

    %{from: from, to: to, periods: Enum.reverse(periods)}
  end

  defp last_date([], today), do: today
  defp last_date(entries, today), do: Enum.max([today, entries |> List.last() |> elem(0)], Date)

  defp first_date([]), do: nil
  defp first_date([{date, _entry} | _]), do: date

  defp dated_entries(to) do
    query =
      from e in Expense,
        join: s in assoc(e, :shares),
        where: is_nil(e.deleted_at),
        order_by: [e.date, e.id, s.participant_id],
        select: {e.id, e.date, e.paid_by_id, e.amount_cents, s.participant_id, s.amount_cents}

    query = if to, do: where(query, [e], e.date <= ^to), else: query

    query
    |> Repo.all()
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map(fn [{_id, date, paid_by_id, cents, _pid, _share} | _] = rows ->
      shares =
        Enum.map(rows, fn {_, _, _, _, pid, share} ->
          %{participant_id: pid, amount_cents: share}
        end)

      {date, %{paid_by_id: paid_by_id, amount_cents: cents, shares: shares}}
    end)
  end
end
