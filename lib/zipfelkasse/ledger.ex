defmodule Zipfelkasse.Ledger do
  @moduledoc """
  Balances and their settlement. A balance is what a person paid minus their shares: positive
  means the others owe them. A reimbursement is an entry whose payer pays back and whose single
  share is the recipient.
  """

  @type entry :: %{
          paid_by_id: integer(),
          amount_cents: integer(),
          shares: [%{participant_id: integer(), amount_cents: integer()}]
        }
  @type transfer :: %{from: integer(), to: integer(), amount_cents: pos_integer()}

  @doc "The balance of everybody who paid or shares in `entries`, by participant id."
  @spec balances([entry()]) :: %{integer() => integer()}
  def balances(entries) do
    Enum.reduce(entries, %{}, fn entry, balances ->
      balances =
        Map.update(balances, entry.paid_by_id, entry.amount_cents, &(&1 + entry.amount_cents))

      Enum.reduce(entry.shares, balances, fn share, balances ->
        Map.update(
          balances,
          share.participant_id,
          -share.amount_cents,
          &(&1 - share.amount_cents)
        )
      end)
    end)
  end

  @doc """
  Transfers that bring every balance to 0, greedily: the largest debtor pays the largest
  creditor; ties go to the smaller id.
  """
  @spec settle(%{integer() => integer()}) :: [transfer()]
  def settle(balances) do
    balances |> Map.reject(fn {_id, balance} -> balance == 0 end) |> settle([])
  end

  defp settle(open, transfers) do
    creditors = Enum.filter(open, fn {_id, balance} -> balance > 0 end)
    debtors = Enum.filter(open, fn {_id, balance} -> balance < 0 end)

    if creditors == [] or debtors == [] do
      Enum.reverse(transfers)
    else
      {to, credit} = Enum.min_by(creditors, fn {id, balance} -> {-balance, id} end)
      {from, debt} = Enum.min_by(debtors, fn {id, balance} -> {balance, id} end)
      amount = min(credit, -debt)

      open
      |> settle_part(to, credit - amount)
      |> settle_part(from, debt + amount)
      |> settle([%{from: from, to: to, amount_cents: amount} | transfers])
    end
  end

  defp settle_part(open, id, 0), do: Map.delete(open, id)
  defp settle_part(open, id, balance), do: Map.put(open, id, balance)
end
