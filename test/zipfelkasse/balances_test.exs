defmodule Zipfelkasse.BalancesTest do
  use Zipfelkasse.DataCase

  import Zipfelkasse.Fixtures

  alias Zipfelkasse.{Balances, Expenses}

  setup do
    h = household()
    create!(equal(h, "Essen", 3000, "2026-08-10", h.anna, [h.anna, h.ben, h.cleo]))
    create!(equal(h, "Kino", 1000, "2026-09-05", h.ben, [h.cleo]))
    create!(reimbursement(500, "2026-09-20", h.cleo, h.anna))
    %{h: h}
  end

  test "sums what each person paid minus their shares, reimbursements included", %{h: h} do
    assert Balances.balances() == %{h.anna => 1500, h.ben => 0, h.cleo => -1500}
    assert Balances.balance(h.cleo) == -1500
    assert Balances.balance(999) == 0
  end

  test "suggests the transfers that settle the balances", %{h: h} do
    assert Balances.settlement() == [%{from: h.cleo, to: h.anna, amount_cents: 1500}]
  end

  test "leaves deleted expenses out", %{h: h} do
    [kino] = Expenses.list_expenses(q: "Kino")
    {:ok, _deleted} = Expenses.delete_expense(nil, kino)

    assert Balances.balances() == %{h.anna => 1500, h.ben => -1000, h.cleo => -500}
  end

  test "gives the balances at the end of each month, from the first expense to today", %{h: h} do
    assert Balances.history(:month, today: ~D[2026-10-14]) == %{
             from: ~D[2026-08-10],
             to: ~D[2026-10-14],
             periods: [
               {"2026-08", %{h.anna => 2000, h.ben => -1000, h.cleo => -1000}},
               {"2026-09", %{h.anna => 1500, h.ben => 0, h.cleo => -1500}},
               {"2026-10", %{h.anna => 1500, h.ben => 0, h.cleo => -1500}}
             ]
           }
  end

  test "gives the balances of the periods asked for, counting all expenses before", %{h: h} do
    assert %{periods: periods} = Balances.history(:week, from: ~D[2026-09-01], to: ~D[2026-09-10])

    assert periods == [
             {"2026-W36", %{h.anna => 2000, h.ben => 0, h.cleo => -2000}},
             {"2026-W37", %{h.anna => 2000, h.ben => 0, h.cleo => -2000}}
           ]

    assert %{periods: [{"2026", _balances}]} =
             Balances.history(:year, from: ~D[2026-12-01], to: ~D[2026-01-01])
  end

  test "reaches a later expense without an end", %{h: h} do
    create!(equal(h, "Urlaub", 600, "2027-02-01", h.ben, [h.anna]))

    assert %{to: ~D[2027-02-01], periods: periods} =
             Balances.history(:year, today: ~D[2026-10-14])

    assert List.last(periods) == {"2027", %{h.anna => 900, h.ben => 600, h.cleo => -1500}}
  end
end
