defmodule Zipfelkasse.ExpensesTest do
  use Zipfelkasse.DataCase

  import Zipfelkasse.Fixtures

  alias Zipfelkasse.{Activities, Balances, Categories, Expenses, Participants}
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Recurring.RecurringExpense

  setup do
    %{h: household()}
  end

  defp share(expense, participant_id), do: Expense.share_of(expense, participant_id)

  defp titles(expenses), do: Enum.map(expenses, & &1.title)

  defp changes(expense) do
    [%{action: :expense_updated, details: details}] =
      Activities.list_activities(expense_id: expense.id, limit: 1)

    Map.new(details.changes, &{&1.field, {&1.old, &1.new}})
  end

  describe "creating an expense" do
    test "normalizes the title and stores the split, the payer and the category", %{h: h} do
      expense =
        h
        |> equal(" Einkauf  Rewe ", 1000, "2026-09-30", h.anna, [h.anna, h.ben, h.cleo])
        |> create!(h.anna)

      assert %{title: "Einkauf Rewe", title_folded: "einkauf rewe", date: ~D[2026-09-30]} =
               expense

      assert {expense.paid_by.name, expense.category.name} == {"Anna", "Lebensmittel"}

      assert {expense.original_currency, expense.original_amount, expense.fx_rate} ==
               {"EUR", 1000, 1.0}

      refute Expense.foreign?(expense)
      assert Enum.map(expense.shares, & &1.weight) == [1, 1, 1]
    end

    test "gives the extra cent to the person at the expense ID modulo the tied people", %{h: h} do
      people = [h.anna, h.ben, h.cleo]
      expense = h |> equal("Einkauf", 1000, "2026-09-30", h.anna, people) |> create!(h.anna)

      lucky = Enum.at(people, rem(expense.id, 3))

      assert Enum.map(people, &share(expense, &1)) ==
               Enum.map(people, &if(&1 == lucky, do: 334, else: 333))
    end

    test "logs the creation and broadcasts it", %{h: h} do
      Expenses.subscribe()

      expense =
        h |> equal("Einkauf Rewe", 1000, "2026-09-30", h.anna, [h.anna]) |> create!(h.anna)

      assert_received {:expenses_changed, [id]}
      assert id == expense.id

      assert [
               %{
                 action: :expense_created,
                 actor: %{name: "Anna"},
                 expense_id: ^id,
                 details: details
               }
             ] =
               Activities.list_activities(expense_id: id)

      assert {details.title, details.amount_cents, details.changes} == {"Einkauf Rewe", 1000, []}
    end

    test "logs a text given for the entry", %{h: h} do
      {:ok, expense} =
        Expenses.create_expense(h.anna, equal(h, "Kino", 1000, "2026-09-01", h.anna, [h.anna]),
          text: "Über MCP angelegt"
        )

      assert [%{details: %{text: "Über MCP angelegt"}}] =
               Activities.list_activities(expense_id: expense.id)
    end

    test "predicts the ID of the next expense, also after a deletion", %{h: h} do
      next = Expenses.next_id()
      expense = h |> equal("Kaffee", 300, "2026-09-01", h.anna, [h.anna]) |> create!()
      assert expense.id == next

      {:ok, _deleted} = Expenses.delete_expense(h.anna, expense)
      assert Expenses.next_id() == expense.id + 1
      assert create!(equal(h, "Tee", 300, "2026-09-01", h.anna, [h.anna])).id == expense.id + 1
    end

    test "rolls back the expense when its activity entry fails", %{h: h} do
      Repo.query!(
        "CREATE TRIGGER no_activity BEFORE INSERT ON activities BEGIN SELECT RAISE(ABORT, 'no activity'); END"
      )

      assert_raise Exqlite.Error, ~r/no activity/, fn ->
        Expenses.create_expense(h.anna, equal(h, "Kino", 1000, "2026-09-01", h.anna, [h.anna]))
      end

      assert Expenses.list_expenses() == []
    end
  end

  describe "validating an expense" do
    for {name, field, message, change} <- [
          {"without a title", :title, "Bitte einen Titel angeben.",
           quote(do: %{&1 | title: " "})},
          {"without a date", :date, "Bitte ein Datum angeben.", quote(do: %{&1 | date: nil})},
          {"without a payer", :paid_by_id, "Bitte angeben, wer bezahlt hat.",
           quote(do: %{&1 | paid_by_id: nil})},
          {"with a title over 200 characters", :title,
           "Der Titel ist zu lang (höchstens 200 Zeichen).",
           quote(do: %{&1 | title: String.duplicate("x", 201)})},
          {"with a title over 200 code points", :title,
           "Der Titel ist zu lang (höchstens 200 Zeichen).",
           quote(do: %{&1 | title: String.duplicate("e\u0301", 101)})},
          {"with a note over 2000 characters", :notes,
           "Die Notiz ist zu lang (höchstens 2000 Zeichen).",
           quote(do: Map.put(&1, :notes, String.duplicate("ä", 2001)))},
          {"with the amount 0", :amount_cents, "Der Betrag muss größer als 0 sein.",
           quote(do: %{&1 | amount_cents: 0})},
          {"without anybody sharing it", :parts,
           "Mindestens eine Person muss an der Ausgabe beteiligt sein.",
           quote(do: %{&1 | parts: []})},
          {"with an unknown payer", :paid_by_id, "Unbekannte Person in der Ausgabe.",
           quote(do: %{&1 | paid_by_id: 999})},
          {"with an unknown person in the split", :parts, "Unbekannte Person in der Ausgabe.",
           quote(do: %{&1 | parts: &1.parts ++ [%{participant_id: 999, weight: 0}]})},
          {"with an unknown category", :category_id, "Unbekannte Kategorie.",
           quote(do: %{&1 | category_id: 999})},
          {"with percentages that do not add up", :parts,
           "Die Prozente müssen zusammen 100 % ergeben (aktuell 50,00 %).",
           quote(
             do: %{
               &1
               | split_mode: :percent,
                 parts: [%{participant_id: hd(&1.parts).participant_id, weight: 5000}]
             }
           )},
          {"in a foreign currency without a rate", :fx_rate,
           "Bitte einen Wechselkurs für USD angeben.",
           quote(do: Map.merge(&1, %{original_currency: "USD", original_amount: 2200}))},
          {"in a foreign currency without an amount", :original_amount,
           "Bitte den Betrag in USD angeben.",
           quote(do: Map.merge(&1, %{original_currency: "USD", fx_rate: 1.1}))},
          {"in a currency with an invalid code", :original_currency, "Ungültige Währung „U$D“.",
           quote(
             do: Map.merge(&1, %{original_currency: "U$D", original_amount: 2200, fx_rate: 1.1})
           )},
          {"in a currency with a two-letter code", :original_currency, "Ungültige Währung „US“.",
           quote(
             do: Map.merge(&1, %{original_currency: "us", original_amount: 2200, fx_rate: 1.1})
           )},
          {"as a reimbursement to two people", :parts,
           "Eine Rückzahlung geht an genau eine Person.",
           quote(do: Map.put(&1, :reimbursement, true))},
          {"as a reimbursement to oneself", :parts,
           "Bei einer Rückzahlung müssen Zahler und Empfänger verschieden sein.",
           quote(
             do:
               Map.merge(&1, %{
                 reimbursement: true,
                 parts: [%{participant_id: &1.paid_by_id, weight: 0}]
               })
           )}
        ] do
      test "rejects an expense #{name}", %{h: h} do
        attrs = (&unquote(change)).(equal(h, "Kino", 2000, "2026-09-01", h.anna, [h.anna, h.ben]))

        assert {:error, changeset} = Expenses.create_expense(h.anna, attrs)
        assert %{unquote(field) => [unquote(message)]} = errors_on(changeset)
        assert Expenses.list_expenses() == []
        assert Activities.list_activities() |> Enum.filter(& &1.expense_id) == []
      end
    end

    test "counts a line break of the notes (CR LF from a browser) as one character", %{h: h} do
      attrs =
        Map.put(
          equal(h, "Einkauf", 1000, "2026-08-01", h.anna, [h.anna]),
          :notes,
          String.duplicate("a\r\n", 999) <> "aa"
        )

      assert {:ok, _expense} = Expenses.create_expense(h.anna, attrs)

      assert {:error, changeset} =
               Expenses.create_expense(h.anna, Map.update!(attrs, :notes, &(&1 <> "a")))

      assert errors_on(changeset) == %{notes: ["Die Notiz ist zu lang (höchstens 2000 Zeichen)."]}
    end

    test "accepts archived people and categories", %{h: h} do
      [food | _] = Categories.list_categories()
      {:ok, _archived} = Categories.archive_category(nil, food)

      {:ok, _archived} =
        Participants.archive_participant(nil, Participants.get_participant!(h.cleo))

      assert {:ok, _expense} =
               Expenses.create_expense(
                 h.anna,
                 equal(h, "Kino", 1000, "2026-09-01", h.cleo, [h.cleo, h.anna])
               )
    end
  end

  describe "updating an expense" do
    setup %{h: h} do
      %{
        expense:
          h |> equal("Pizza", 3000, "2026-09-01", h.anna, [h.anna, h.ben]) |> create!(h.anna)
      }
    end

    test "writes nothing when it is saved unchanged", %{h: h, expense: expense} do
      Expenses.subscribe()

      assert {:ok, same} = Expenses.update_expense(h.ben, expense, Expenses.input(expense))

      assert same.updated_at == expense.updated_at
      refute_received {:expenses_changed, _ids}
      assert length(Activities.list_activities(expense_id: expense.id)) == 1
    end

    test "stores the new values and recomputes the shares", %{h: h, expense: expense} do
      attrs = %{
        Expenses.input(expense)
        | title: "Pizza & Wein",
          amount_cents: 4500,
          split_mode: :shares,
          parts: [%{participant_id: h.anna, weight: 2}, %{participant_id: h.ben, weight: 1}],
          category_id: nil
      }

      assert {:ok, updated} = Expenses.update_expense(h.ben, expense, attrs)

      assert {updated.title, updated.amount_cents, updated.category_id} ==
               {"Pizza & Wein", 4500, nil}

      assert {share(updated, h.anna), share(updated, h.ben)} == {3000, 1500}
    end

    test "logs each changed field with its old and new value and broadcasts it", %{
      h: h,
      expense: expense
    } do
      Expenses.subscribe()

      attrs = %{
        Expenses.input(expense)
        | amount_cents: 4500,
          split_mode: :shares,
          parts: [%{participant_id: h.anna, weight: 2}, %{participant_id: h.ben, weight: 1}],
          category_id: nil
      }

      {:ok, _updated} = Expenses.update_expense(h.ben, expense, attrs)

      assert_received {:expenses_changed, [id]}
      assert id == expense.id
      assert [%{actor: %{name: "Ben"}} | _] = Activities.list_activities(expense_id: expense.id)

      assert changes(expense) == %{
               "Betrag" => {"30,00 €", "45,00 €"},
               "Originalbetrag" => {"30,00 €", "45,00 €"},
               "Kategorie" => {"Lebensmittel", "–"},
               "Aufteilung" =>
                 {"Gleichmäßig: Anna 15,00 €, Ben 15,00 €",
                  "Nach Anteilen: Anna 30,00 €, Ben 15,00 €"}
             }
    end

    test "logs the details of the update", %{h: h, expense: expense} do
      {:ok, _updated} =
        Expenses.update_expense(h.anna, expense, %{Expenses.input(expense) | title: "Theater"})

      assert [%{details: details} | _] = Activities.list_activities(expense_id: expense.id)
      assert {details.title, details.amount_cents, details.text} == {"Theater", 3000, nil}
      assert changes(expense) == %{"Titel" => {"Pizza", "Theater"}}
    end

    test "keeps rotating the extra cent with the expense ID", %{h: h} do
      people = [h.anna, h.ben]

      lucky =
        for _ <- 1..4 do
          expense = h |> equal("Kaffee", 301, "2026-09-01", h.anna, people) |> create!()
          lucky = Enum.at(people, rem(expense.id, 2))
          assert share(expense, lucky) == 151

          {:ok, updated} =
            Expenses.update_expense(h.anna, expense, %{
              Expenses.input(expense)
              | amount_cents: 501
            })

          assert share(updated, lucky) == 251
          lucky
        end

      assert Enum.frequencies(lucky) == %{h.anna => 2, h.ben => 2}
    end

    test "cannot move an occurrence onto the date of another one", %{h: h} do
      {:ok, rule} =
        Repo.insert(%RecurringExpense{
          template: %RecurringExpense.Template{title: "Miete"},
          frequency: :monthly,
          start_date: ~D[2026-01-31],
          next_date: ~D[2026-01-31]
        })

      attrs = equal(h, "Miete", 100_000, "2026-01-31", h.anna, [h.anna, h.ben])
      {:ok, _first} = Expenses.create_expense(nil, attrs, recurring_expense_id: rule.id)
      Repo.update_all(where(RecurringExpense, id: ^rule.id), set: [next_date: ~D[2026-02-28]])

      {:ok, second} =
        Expenses.create_expense(nil, %{attrs | date: ~D[2026-02-28]},
          recurring_expense_id: rule.id
        )

      assert {:error, changeset} =
               Expenses.update_expense(h.anna, second, %{attrs | date: ~D[2026-01-31]})

      assert errors_on(changeset) == %{
               recurring_expense_id: [
                 "Für diesen Termin gibt es schon eine Ausgabe dieser Wiederholung."
               ]
             }

      assert {:error, _changeset} =
               Expenses.create_expense(nil, attrs, recurring_expense_id: rule.id)
    end
  end

  describe "deleting an expense" do
    setup %{h: h} do
      %{
        expense:
          h |> equal("Bahn", 5000, "2026-09-02", h.anna, [h.anna, h.ben]) |> create!(h.anna)
      }
    end

    test "keeps it as deleted, out of the list and the balances", %{h: h, expense: expense} do
      {:ok, deleted} = Expenses.delete_expense(h.ben, expense)

      assert Expense.deleted?(deleted)
      assert Expense.deleted?(Expenses.get_expense!(expense.id))
      assert Expenses.list_expenses() == []
      assert Balances.balances() == %{}
    end

    test "logs the deletion and broadcasts it", %{h: h, expense: expense} do
      Expenses.subscribe()

      {:ok, _deleted} = Expenses.delete_expense(h.ben, expense)

      assert_received {:expenses_changed, [id]}
      assert id == expense.id

      assert [%{action: :expense_deleted, details: %{title: "Bahn", amount_cents: 5000}} | _] =
               Activities.list_activities()
    end

    test "refuses to delete or update a deleted expense", %{h: h, expense: expense} do
      {:ok, _deleted} = Expenses.delete_expense(h.ben, expense)

      assert Expenses.delete_expense(h.ben, expense) == {:error, :not_found}

      assert Expenses.update_expense(h.ben, expense, Expenses.input(expense)) ==
               {:error, :deleted}

      assert Expenses.update_expense(h.ben, %Expense{id: 999}, Expenses.input(expense)) ==
               {:error, :not_found}
    end
  end

  describe "listing expenses" do
    setup %{h: h} do
      create!(equal(h, "Rewe Einkauf", 1000, "2026-09-01", h.anna, [h.anna, h.ben]))
      create!(equal(h, "Kino 100%", 2000, "2026-09-15", h.ben, [h.ben, h.cleo]))

      h
      |> equal("Tanken", 3000, "2026-10-01", h.cleo, [h.cleo])
      |> Map.merge(%{category_id: nil, notes: "Rewe-Tankstelle"})
      |> create!()

      :ok
    end

    test "lists the newest first, with their shares", %{h: _h} do
      expenses = Expenses.list_expenses()

      assert titles(expenses) == ["Tanken", "Kino 100%", "Rewe Einkauf"]
      assert Enum.all?(expenses, &(&1.shares != []))
    end

    test "pages after the last expense shown" do
      [first, second, third] = Expenses.list_expenses()

      assert Expenses.list_expenses([], limit: 2) == [first, second]
      assert Expenses.list_expenses([], limit: 2, after: {second.date, second.id}) == [third]
    end

    test "finds a text in the title or the notes, also one with a LIKE wildcard" do
      assert titles(Expenses.list_expenses(q: " rewe ")) == ["Tanken", "Rewe Einkauf"]
      assert titles(Expenses.list_expenses(q: "100%")) == ["Kino 100%"]
      assert length(Expenses.list_expenses(q: "", category_id: nil)) == 3
    end

    test "lists the expenses of a category", %{h: h} do
      assert titles(Expenses.list_expenses(category_id: h.food)) == ["Kino 100%", "Rewe Einkauf"]
    end

    test "lists the expenses a person paid or shares", %{h: h} do
      assert titles(Expenses.list_expenses(participant_id: h.cleo)) == ["Tanken", "Kino 100%"]
      assert titles(Expenses.list_expenses(participant_id: h.cleo, q: "kino")) == ["Kino 100%"]
    end
  end

  describe "searching a text" do
    setup %{h: h} do
      ids =
        for {key, title, notes} <- [
              {"lower", "bäckerei am markt", ""},
              {"upper", "BÄCKER SCHMIDT", ""},
              {"mixed", "Brötchen", "vom Bäcker"},
              {"street", "Parken Hauptstraße", ""},
              {"caps", "PARKHAUS HAUPTSTRASSE", ""},
              {"ascii", "Baecker ohne Umlaut", ""}
            ],
            into: %{} do
          expense =
            h
            |> equal(title, 1000, "2026-09-01", h.anna, [h.anna, h.ben])
            |> Map.put(:notes, notes)
            |> create!()

          {key, expense.id}
        end

      %{ids: ids}
    end

    for {text, expected} <- [
          {"BÄCKER", ~w(mixed upper lower)},
          {"bäcker", ~w(mixed upper lower)},
          {"Bäckerei", ~w(lower)},
          {"brötchen", ~w(mixed)},
          {"BRÖTCHEN", ~w(mixed)},
          {"straße", ~w(caps street)},
          {"STRASSE", ~w(caps street)},
          {"ẞ", ~w(caps street)}
        ] do
      test "finds #{Enum.join(expected, ", ")} for #{inspect(text)} regardless of the case of umlauts and ß",
           %{ids: ids} do
        assert Enum.map(Expenses.list_expenses(q: unquote(text)), & &1.id) ==
                 Enum.map(unquote(expected), &ids[&1])
      end
    end
  end

  test "computes the balances with a reimbursement", %{h: h} do
    create!(equal(h, "Essen", 3000, "2026-09-01", h.anna, [h.anna, h.ben, h.cleo]), h.anna)

    {:ok, paid_back} =
      Expenses.create_expense(h.ben, reimbursement(1000, "2026-09-02", h.ben, h.anna))

    assert {paid_back.reimbursement, paid_back.split_mode, share(paid_back, h.anna)} ==
             {true, :equal, 1000}

    assert Balances.balances() == %{h.anna => 1000, h.ben => 0, h.cleo => -1000}
  end

  test "a reimbursement is always split equally", %{h: h} do
    attrs =
      h.ben
      |> then(&reimbursement(1000, "2026-09-02", &1, h.anna))
      |> Map.put(:split_mode, :shares)

    assert {:ok, %{split_mode: :equal}} = Expenses.create_expense(h.ben, attrs)
  end

  describe "finding a likely duplicate" do
    setup %{h: h} do
      expense = create!(equal(h, "Rewe", 2340, "2026-09-01", h.anna, [h.anna, h.ben]))
      paid_back = create!(reimbursement(1000, "2026-09-02", h.ben, h.anna))
      %{expense: expense, paid_back: paid_back}
    end

    test "finds an expense of the same day, payer, amount and title regardless of case", %{
      h: h,
      expense: expense
    } do
      attrs = equal(h, " REWE ", 2340, "2026-09-01", h.anna, [h.anna])

      assert Expenses.find_duplicate(attrs).id == expense.id
      refute Expenses.find_duplicate(%{attrs | title: "Edeka"})
      refute Expenses.find_duplicate(%{attrs | amount_cents: 2341})
      refute Expenses.find_duplicate(%{attrs | date: ~D[2026-09-02]})
      refute Expenses.find_duplicate(%{attrs | paid_by_id: h.ben})
    end

    test "finds a reimbursement to the same recipient", %{h: h, paid_back: paid_back} do
      assert Expenses.find_duplicate(reimbursement(1000, "2026-09-02", h.ben, h.anna)).id ==
               paid_back.id

      refute Expenses.find_duplicate(reimbursement(1000, "2026-09-02", h.ben, h.cleo))
    end

    test "finds nothing for a deleted expense or an invalid input", %{h: h, expense: expense} do
      {:ok, _deleted} = Expenses.delete_expense(nil, expense)

      refute Expenses.find_duplicate(equal(h, "Rewe", 2340, "2026-09-01", h.anna, [h.anna]))
      refute Expenses.find_duplicate(%{})
    end
  end

  test "counts the live expenses a person paid or shares, and those of a category", %{h: h} do
    create!(equal(h, "A", 1000, "2026-09-30", h.anna, [h.anna, h.ben]))
    deleted = create!(equal(h, "B", 1000, "2026-09-30", h.ben, [h.ben]))
    create!(%{equal(h, "C", 1000, "2026-09-30", h.cleo, [h.ben]) | category_id: h.restaurant})
    {:ok, _deleted} = Expenses.delete_expense(h.anna, deleted)

    assert Expenses.count_by_participant() == %{h.anna => 1, h.ben => 2, h.cleo => 1}
    assert Expenses.count_by_category() == %{h.food => 1, h.restaurant => 1}
  end

  test "learns categories from the live expenses with an active category, newest first", %{h: h} do
    [_food, other, archived | _] = Categories.list_categories()

    mk = fn title, date, category_id ->
      create!(%{equal(h, title, 1000, date, h.anna, [h.anna, h.ben]) | category_id: category_id})
    end

    mk.("Kaufland", "2026-09-01", h.food)
    mk.("Kino", "2026-09-10", other.id)
    mk.("Ohne", "2026-09-11", nil)
    mk.("Archiviert", "2026-09-12", archived.id)
    {:ok, _deleted} = Expenses.delete_expense(nil, mk.("Gelöscht", "2026-09-13", h.food))
    {:ok, _archived} = Categories.archive_category(nil, archived)

    create!(
      Map.put(equal(h, "Kaufland", 500, "2026-09-14", h.ben, [h.anna]), :reimbursement, true)
    )

    assert Expenses.category_history() == [{"Kino", other.id}, {"Kaufland", h.food}]
    assert Expenses.category_suggestions().titles == %{"kino" => other.id, "kaufland" => h.food}
  end
end
