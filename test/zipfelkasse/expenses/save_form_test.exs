defmodule Zipfelkasse.Expenses.SaveFormTest do
  use Zipfelkasse.DataCase

  import Zipfelkasse.Fixtures

  alias Ecto.Changeset
  alias Zipfelkasse.{Expenses, FakeEcb, LocalTime}
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Fx.{Loader, Rate}

  @today ~D[2026-10-01]

  setup do
    h = household()
    Repo.insert!(%Rate{currency: "USD", source: :ecb, date: ~D[2026-09-30], rate: 1.2})
    form = Expenses.new_form(today: @today, participant_id: h.anna)
    %{h: h, form: %{form | title: "Mein Titel", amount: "30,00", category_id: h.food}}
  end

  defp save(form, existing \\ nil), do: Expenses.save_form(nil, form, existing, today: @today)

  defp error(form, existing \\ nil) do
    {:error, changeset} = save(form, existing)
    [{_field, {message, _opts}} | _] = changeset.errors
    message
  end

  test "creates an expense from the form", %{h: h, form: form} do
    assert {:ok, expense} = save(form)

    assert {expense.title, expense.amount_cents, expense.category_id} ==
             {"Mein Titel", 3000, h.food}

    assert Enum.map(expense.shares, & &1.amount_cents) |> Enum.sum() == 3000
  end

  test "refuses what the expense refuses, on the fields of the form", %{form: form} do
    assert {:error, changeset} = save(%{form | title: "  "})

    assert changeset.action == :insert
    assert errors_on(changeset) == %{title: ["Bitte einen Titel angeben."]}
    assert error(%{form | amount: "20.000.000.000"}) == "Der Betrag ist zu groß."
    assert error(%{form | paid_by_id: nil}) == "Bitte angeben, wer bezahlt hat."
    assert error(%{form | paid_by_id: 99}) == "Unbekannte Person in der Ausgabe."
    assert error(%{form | category_id: 99}) == "Unbekannte Kategorie."
    assert Expenses.list_expenses() == []
  end

  test "refuses split rules", %{h: h, form: form} do
    with_weights = fn mode, weights ->
      %{form | split_mode: mode, rows: Enum.zip_with(form.rows, weights, &%{&1 | weight: &2})}
    end

    assert error(with_weights.(:percent, ["50", "20", "20"])) ==
             "Die Prozente müssen zusammen 100 % ergeben (aktuell 90,00 %)."

    assert error(with_weights.(:percent, ["150", "", ""])) ==
             "Die Prozente müssen zusammen 100 % ergeben."

    assert error(with_weights.(:amount, ["10", "", ""])) ==
             "Die Beträge müssen zusammen 30,00 € ergeben (aktuell 10,00 €)."

    assert error(with_weights.(:shares, ["0", "0", "0"])) ==
             "Die Summe der Anteile muss größer als 0 sein."

    assert error(with_weights.(:shares, ["1000001", "", ""])) ==
             "Anteile dürfen höchstens 1000000 sein."

    reimbursement = %{
      form
      | reimbursement: true,
        rows: Enum.map(form.rows, &%{&1 | selected: &1.participant_id == h.anna})
    }

    assert error(reimbursement) ==
             "Bei einer Rückzahlung müssen Zahler und Empfänger verschieden sein."
  end

  describe "a foreign amount" do
    setup %{form: form} do
      %{usd: %{form | currency: "USD", amount: "12,00"}}
    end

    test "without a rate takes the rate of its date", %{usd: usd} do
      assert {:ok, expense} = save(usd)

      assert {expense.original_amount, expense.fx_rate, expense.fx_source, expense.amount_cents} ==
               {1200, 1.2, :ecb, 1000}
    end

    test "keeps a typed rate as manual", %{usd: usd} do
      assert {:ok, expense} = save(%{usd | rate: "1,5"})

      assert {expense.fx_rate, expense.fx_source, expense.amount_cents} == {1.5, :manual, 800}
    end

    test "looks a rate marked as ECB up again", %{usd: usd} do
      assert {:ok, expense} = save(%{usd | rate: "1,08", rate_source: :ecb})

      assert {expense.fx_rate, expense.fx_source} == {1.2, :ecb}
    end

    test "keeps the saved ECB rate when currency, date and rate are unchanged", %{h: h} do
      expense =
        create!(foreign(h, "Einkauf USA", 1080, "USD", 1.08, "2026-09-30", h.anna, [h.anna]))

      form = %{Expenses.edit_form(expense) | title: "Einkauf in den USA"}

      assert {:ok, saved} = save(form, expense)

      assert {saved.title, saved.fx_rate, saved.fx_source, saved.amount_cents} ==
               {"Einkauf in den USA", 1.08, :ecb, 1000}

      assert {:ok, %{fx_rate: 1.2}} = save(%{form | date: "2026-10-01"}, saved)
    end

    test "without any rate is refused and the rate cleared", %{form: form} do
      assert {:error, changeset} =
               save(%{
                 form
                 | currency: "",
                   currency_other: "xaf",
                   amount: "1000",
                   rate: "0,85",
                   rate_source: :ecb
               })

      assert errors_on(changeset) == %{
               rate: [
                 "Für XAF ist am 01.10.2026 kein Wechselkurs verfügbar. Kurs bitte von Hand eintragen."
               ]
             }

      assert {Changeset.get_field(changeset, :rate), Changeset.get_field(changeset, :rate_source)} ==
               {"", nil}
    end

    @tag :capture_log
    test "is refused the same way while the ECB rates cannot be loaded", %{form: form} do
      ecb = FakeEcb.start(~D[2026-10-01])
      FakeEcb.put(ecb, :failure, 500)
      clock = fn -> LocalTime.to_utc(~N[2026-10-01 18:00:00]) end
      loader = start_supervised!({Loader, name: nil, base_url: ecb.url, clock: clock})
      form = %{form | currency: "CHF", amount: "1000", rate: ""}

      assert {:error, changeset} =
               Expenses.save_form(nil, form, nil, today: @today, loader: loader)

      assert errors_on(changeset) == %{
               rate: [
                 "Für CHF ist am 01.10.2026 kein Wechselkurs verfügbar. Kurs bitte von Hand eintragen."
               ]
             }
    end

    test "shows the looked-up rate when another error follows", %{usd: usd} do
      assert {:error, changeset} = save(%{usd | title: ""})

      assert Changeset.get_field(changeset, :rate) == "1,2"
      assert errors_on(changeset) == %{title: ["Bitte einen Titel angeben."]}
    end

    test "that converts to 0 € is refused", %{usd: usd} do
      assert error(%{usd | amount: "0,01", rate: "1000"}) ==
               "Umgerechnet ergibt der Betrag 0 € – bitte Betrag und Kurs prüfen."
    end
  end

  test "updates an expense from its form and refuses a deleted one", %{h: h} do
    expense = create!(equal(h, "Gleich 1", 1000, "2026-10-01", h.anna, [h.anna, h.ben, h.cleo]))
    form = Expenses.edit_form(expense)
    assert form.rows |> Enum.map(& &1.selected) == [true, true, true]

    form = %{
      form
      | title: "Gleich groß",
        amount: "45",
        split_mode: :shares,
        category_id: nil,
        notes: "neu",
        date: "02.10.2026"
    }

    form = %{
      form
      | rows:
          Enum.zip_with(form.rows, [{true, "1"}, {true, "2"}, {false, ""}], fn row,
                                                                               {selected, weight} ->
            %{row | selected: selected, weight: weight}
          end)
    }

    assert {:ok, saved} = save(form, expense)

    assert {Expense.share_of(saved, h.anna), Expense.share_of(saved, h.ben), saved.date} ==
             {1500, 3000, ~D[2026-10-02]}

    {:ok, _deleted} = Expenses.delete_expense(nil, saved)
    assert save(form, saved) == {:error, :deleted}
  end

  test "previews a new expense with the id it will get and a saved one with its own", %{
    h: h,
    form: form
  } do
    next = Expenses.next_id()
    lucky = Enum.at([h.anna, h.ben, h.cleo], rem(next, 3))

    assert Expenses.preview_form(%{form | amount: "10"}).shares[lucky] == 334

    expense = create!(equal(h, "Kino", 1000, "2026-10-01", h.anna, [h.anna, h.ben, h.cleo]))
    form = Expenses.edit_form(expense)

    assert Expenses.preview_form(form).shares ==
             Map.new(expense.shares, &{&1.participant_id, &1.amount_cents})
  end

  test "looks the rate of the form up", %{form: form} do
    assert %{rate: "1,2", rate_source: :ecb} =
             %{form | currency: "USD"}
             |> Expenses.lookup_form_rate(today: @today)
             |> Changeset.apply_changes()

    assert %{rate: "", rate_hint: "Kein Kurs verfügbar. Kurs bitte von Hand eintragen."} =
             %{form | currency: "CHF"}
             |> Expenses.lookup_form_rate(today: @today)
             |> Changeset.apply_changes()

    assert Expenses.lookup_form_rate(%{form | currency: "USD", date: "morgen"}).changes == %{}
  end
end
