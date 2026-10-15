defmodule Zipfelkasse.Expenses.ForeignExpensesTest do
  use Zipfelkasse.DataCase

  import Zipfelkasse.Fixtures

  alias Zipfelkasse.{Activities, Expenses}
  alias Zipfelkasse.Expenses.Expense

  setup do
    %{h: household()}
  end

  defp share(expense, participant_id), do: Expense.share_of(expense, participant_id)

  defp changes(expense) do
    [%{action: :expense_updated, details: details}] =
      Activities.list_activities(expense_id: expense.id, limit: 1)

    Map.new(details.changes, &{&1.field, {&1.old, &1.new}})
  end

  test "stores the original amount, the currency in capitals, the rate and its source", %{h: h} do
    expense =
      h
      |> foreign("Diner NYC", 10_000, "usd", 1.0823, "2026-08-01", h.ben, [h.anna, h.ben])
      |> create!(h.ben)

    assert Expense.foreign?(expense)

    assert {expense.original_currency, expense.amount_cents, expense.fx_rate, expense.fx_source} ==
             {"USD", 9240, 1.0823, :ecb}
  end

  test "derives the euro amount from the original amount and the rate, whatever amount was given",
       %{h: h} do
    attrs = %{
      foreign(h, "Diner NYC", 10_000, "USD", 1.0823, "2026-08-01", h.ben, [h.anna, h.ben])
      | amount_cents: 1
    }

    expense = create!(attrs, h.ben)

    assert expense.amount_cents == 9240
    assert share(expense, h.anna) + share(expense, h.ben) == 9240

    {:ok, updated} =
      Expenses.update_expense(h.ben, expense, %{Expenses.input(expense) | amount_cents: 1})

    assert updated.amount_cents == 9240
  end

  test "rotates the extra euro cent of foreign amounts with the expense ID", %{h: h} do
    people = [h.anna, h.ben]

    for _ <- 1..4 do
      expense =
        h
        |> foreign("Taxi", 1000, "USD", 0.999, "2026-09-01", h.anna, people)
        |> Map.merge(%{
          split_mode: :amount,
          parts: [%{participant_id: h.anna, weight: 500}, %{participant_id: h.ben, weight: 500}]
        })
        |> create!(h.anna)

      assert expense.amount_cents == 1001
      assert share(expense, Enum.at(people, rem(expense.id, 2))) == 501
    end
  end

  describe "split by amounts in the foreign currency" do
    setup %{h: h} do
      expense =
        h
        |> foreign("Hotel", 1000, "USD", 1.1, "2026-08-01", h.anna, [])
        |> Map.merge(%{
          split_mode: :amount,
          parts: [
            %{participant_id: h.cleo, weight: 334},
            %{participant_id: h.anna, weight: 333},
            %{participant_id: h.ben, weight: 333}
          ]
        })
        |> create!(h.anna)

      %{expense: expense}
    end

    test "stores the weights as entered and distributes the euro cents in proportion to them", %{
      h: h,
      expense: expense
    } do
      assert expense.amount_cents == 909
      assert share(expense, h.anna) + share(expense, h.ben) + share(expense, h.cleo) == 909
      assert share(expense, h.cleo) == 303
      assert Enum.map(expense.shares, & &1.weight) == [333, 333, 334]
    end

    test "logs nothing when it is saved unchanged", %{h: h, expense: expense} do
      {:ok, _same} = Expenses.update_expense(h.anna, expense, Expenses.input(expense))

      assert length(Activities.list_activities(expense_id: expense.id)) == 1
    end

    test "keeps the weights and changes the euro shares when the rate changes", %{
      h: h,
      expense: expense
    } do
      {:ok, updated} =
        Expenses.update_expense(h.anna, expense, %{Expenses.input(expense) | fx_rate: 1.25})

      assert {updated.amount_cents, share(updated, h.cleo), Enum.at(updated.shares, 2).weight} ==
               {800, 267, 334}
    end

    test "lists changed shares in euros in the history", %{h: h, expense: expense} do
      [anna, ben, cleo] = Expenses.input(expense).parts

      {:ok, _updated} =
        Expenses.update_expense(h.anna, expense, %{
          Expenses.input(expense)
          | fx_rate: 1.25,
            parts: [%{anna | weight: 433}, ben, %{cleo | weight: 234}]
        })

      {_old, new} = changes(expense)["Aufteilung"]
      assert new =~ "Anna 3,46 €"
    end

    test "refuses amounts that do not add up to the amount in the foreign currency", %{
      h: h,
      expense: expense
    } do
      [anna | rest] = Expenses.input(expense).parts

      assert {:error, changeset} =
               Expenses.update_expense(h.anna, expense, %{
                 Expenses.input(expense)
                 | parts: [%{anna | weight: 300} | rest]
               })

      assert errors_on(changeset) == %{
               parts: ["Die Beträge müssen zusammen 10,00 USD ergeben (aktuell 9,67 USD)."]
             }
    end

    test "refuses a rate that converts the amount to 0 €", %{h: h, expense: expense} do
      assert {:error, changeset} =
               Expenses.update_expense(h.anna, expense, %{
                 Expenses.input(expense)
                 | fx_rate: 1.0e9
               })

      assert errors_on(changeset) == %{
               amount_cents: ["Umgerechnet ergibt der Betrag 0 € – bitte Betrag und Kurs prüfen."]
             }
    end
  end

  describe "changes of only the rate, the rate source or the weights" do
    setup %{h: h} do
      attrs =
        h
        |> foreign("Diner", 1000, "USD", 1.25, "2026-08-01", h.ben, [])
        |> Map.merge(%{
          split_mode: :shares,
          parts: [%{participant_id: h.anna, weight: 1}, %{participant_id: h.ben, weight: 1}]
        })

      %{attrs: attrs, expense: create!(attrs, h.ben)}
    end

    test "stores and logs a changed rate that leaves the euro cents as they are", %{
      h: h,
      attrs: attrs,
      expense: expense
    } do
      {:ok, updated} = Expenses.update_expense(h.anna, expense, %{attrs | fx_rate: 1.2501})

      assert updated.fx_rate == 1.2501
      assert changes(expense)["Kurs"] == {"1 € = 1,25 USD (EZB)", "1 € = 1,2501 USD (EZB)"}
    end

    test "stores and logs a changed rate source", %{h: h, attrs: attrs, expense: expense} do
      {:ok, updated} = Expenses.update_expense(h.anna, expense, %{attrs | fx_source: :manual})

      assert updated.fx_source == :manual
      assert changes(expense)["Kurs"] == {"1 € = 1,25 USD (EZB)", "1 € = 1,25 USD (manuell)"}
    end

    test "stores and logs changed weights that leave the euro cents as they are", %{
      h: h,
      attrs: attrs,
      expense: expense
    } do
      parts = [%{participant_id: h.anna, weight: 2}, %{participant_id: h.ben, weight: 2}]
      {:ok, updated} = Expenses.update_expense(h.anna, expense, %{attrs | parts: parts})

      assert hd(updated.shares).weight == 2
      assert changes(expense) == %{"Anteile" => {"Anna 1, Ben 1", "Anna 2, Ben 2"}}
    end
  end

  test "a euro expense drops a rate and its source", %{h: h} do
    expense =
      create!(
        %{equal(h, "Brot", 300, "2026-09-02", h.anna, [h.anna]) | amount_cents: 300}
        |> Map.merge(%{fx_rate: 1.3, fx_source: :ecb})
      )

    assert {expense.original_currency, expense.original_amount, expense.fx_rate,
            expense.fx_source} == {"EUR", 300, 1.0, nil}
  end
end
