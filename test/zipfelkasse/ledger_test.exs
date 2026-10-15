defmodule Zipfelkasse.LedgerTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.Ledger

  defp entry(paid_by, cents, shares) do
    %{
      paid_by_id: paid_by,
      amount_cents: cents,
      shares: Enum.map(shares, fn {id, cents} -> %{participant_id: id, amount_cents: cents} end)
    }
  end

  defp transfer(from, to, cents), do: %{from: from, to: to, amount_cents: cents}

  test "computes each balance from what a person paid and what they share" do
    a_pays_for_all = entry(1, 3000, [{1, 1000}, {2, 1000}, {3, 1000}])
    b_pays_for_c = entry(2, 1000, [{3, 1000}])
    c_pays_back_a = entry(3, 500, [{1, 500}])

    balances = Ledger.balances([a_pays_for_all, b_pays_for_c, c_pays_back_a])

    assert balances == %{1 => 1500, 2 => 0, 3 => -1500}
    assert balances |> Map.values() |> Enum.sum() == 0
  end

  test "returns no balances for no entries" do
    assert Ledger.balances([]) == %{}
  end

  describe "settle/1" do
    for {name, balances, transfers} <- [
          {"empty", %{}, []},
          {"settled", %{1 => 0, 2 => 0}, []},
          {"simple", %{1 => 1500, 2 => -1500}, [{2, 1, 1500}]},
          {"greedy", %{1 => 5000, 2 => -3000, 3 => -1500, 4 => -500},
           [{2, 1, 3000}, {3, 1, 1500}, {4, 1, 500}]},
          {"multiple creditors", %{1 => 2000, 2 => 1000, 3 => -2500, 4 => -500},
           [{3, 1, 2000}, {3, 2, 500}, {4, 2, 500}]},
          {"tie broken by ID", %{5 => 100, 2 => 100, 9 => -100, 3 => -100},
           [{3, 2, 100}, {9, 5, 100}]},
          {"one creditor, tied debtors", %{1 => 300, 2 => -100, 3 => -100, 4 => -100},
           [{2, 1, 100}, {3, 1, 100}, {4, 1, 100}]},
          {"tied creditors", %{1 => 100, 2 => 100, 3 => -150, 4 => -50},
           [{3, 1, 100}, {3, 2, 50}, {4, 2, 50}]}
        ] do
      test name do
        want =
          Enum.map(unquote(Macro.escape(transfers)), fn {from, to, cents} ->
            transfer(from, to, cents)
          end)

        assert Ledger.settle(unquote(Macro.escape(balances))) == want
      end
    end
  end
end
