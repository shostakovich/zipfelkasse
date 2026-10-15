defmodule Zipfelkasse.Ynab.PlanTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.Ynab.{Plan, Posting, Transaction, Want}

  @person 1
  @day ~D[2026-09-01]

  defp want(id, cents \\ 1000, category \\ nil) do
    Want.new(
      %Posting{
        expense_id: id,
        date: @day,
        amount_cents: cents,
        payee: "Kino",
        memo: "memo #{id}",
        category_id: nil
      },
      category
    )
  end

  defp wants(list), do: Map.new(list, &{Want.expense_id(&1), &1})
  defp rows(list), do: Map.new(list, &{&1.expense_id, &1})

  defp row(id, fields \\ []),
    do: struct(%Transaction{expense_id: id, participant_id: @person}, fields)

  defp synced(want, transaction_id) do
    row(Want.expense_id(want),
      ynab_transaction_id: transaction_id,
      state: :synced,
      fingerprint: want.fingerprint,
      synced_at: ~U[2026-09-01 00:00:00Z]
    )
  end

  defp failed(id, transaction_id, fingerprint),
    do:
      row(id,
        ynab_transaction_id: transaction_id,
        state: :failed,
        fingerprint: fingerprint,
        last_error: "broken"
      )

  defp creates(plan), do: Enum.map(plan.creates, &Want.expense_id/1)

  test "creates what has no transaction yet" do
    [a, b] = [want(1), want(2)]

    assert Plan.build(wants([a, b]), rows([synced(a, "t1")]), false) == %Plan{creates: [b]}
    assert creates(Plan.build(wants([b, a]), %{}, false)) == [1, 2]
  end

  test "creates a row that lost its transaction" do
    a = want(1)

    assert Plan.build(wants([a]), rows([row(1)]), false).creates == [a]
    assert Plan.build(wants([a]), rows([row(1, state: :pending)]), false).creates == [a]
  end

  test "updates what changed since it was transferred" do
    [old, current] = [want(1), want(1, 2000)]

    plan = Plan.build(wants([current]), rows([synced(old, "t1")]), false)
    assert plan.updates == [{current, "t1"}]
    assert plan.creates == []
    assert Plan.build(wants([old]), rows([synced(old, "t1")]), false).updates == []

    assert length(
             Plan.build(wants([want(1, 1000, "c-food")]), rows([synced(old, "t1")]), false).updates
           ) == 1
  end

  test "retries a failed state only when it changed or in the full sync" do
    [a, changed] = [want(1), want(1, 2000)]
    broken = failed(1, "t1", a.fingerprint)

    assert Plan.build(wants([a]), rows([broken]), false).updates == []
    assert Plan.build(wants([a]), rows([broken]), true).updates == [{a, "t1"}]
    assert Plan.build(wants([changed]), rows([broken]), false).updates == [{changed, "t1"}]

    without = failed(1, nil, a.fingerprint)
    assert Plan.build(wants([a]), rows([without]), false).creates == []
    assert Plan.build(wants([a]), rows([without]), true).creates == [a]
  end

  test "deletes what is gone and forgets rows without a transaction" do
    gone = synced(want(1), "t1")
    plan = Plan.build(%{}, rows([gone, row(2), row(3, state: :pending)]), false)

    assert {plan.deletes, plan.forget} == {[gone], [2, 3]}
  end

  test "retries a failed delete only in the full sync" do
    broken = %{synced(want(1), "t1") | state: :delete_failed, last_error: "broken"}

    assert Plan.build(%{}, rows([broken]), false).deletes == []
    assert Plan.build(%{}, rows([broken]), true).deletes == [broken]
  end

  test "sorts everything by expense id" do
    old = Enum.map(1..3, &want/1)

    plan =
      Plan.build(
        wants([want(9), want(4), want(7, 2000)]),
        rows([
          synced(want(7), "t7"),
          synced(Enum.at(old, 2), "t3"),
          synced(Enum.at(old, 0), "t1")
        ]),
        false
      )

    assert {creates(plan), Enum.map(plan.updates, &Want.expense_id(elem(&1, 0))),
            Enum.map(plan.deletes, & &1.expense_id)} ==
             {[4, 9], [7], [1, 3]}
  end
end
