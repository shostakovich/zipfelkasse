defmodule ZipfelkasseWeb.ExpenseLiveTest do
  use ZipfelkasseWeb.ConnCase

  import Phoenix.LiveViewTest
  import Setzkasten.Test.Confirm
  import Zipfelkasse.Fixtures
  import ZipfelkasseWeb.PageText

  alias Setzkasten.Format
  alias Zipfelkasse.{Expenses, LocalTime, Repo}
  alias Zipfelkasse.Fx.Rate

  setup %{conn: conn} do
    h = household()
    %{h: h, conn: init_test_session(conn, participant_id: h.anna)}
  end

  defp today, do: LocalTime.today()

  defp value(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
  end

  defp change(view, params), do: view |> form("#expense-form", expense: params) |> render_change()
  defp submit(view, params), do: view |> form("#expense-form", expense: params) |> render_submit()

  defp rows(selected) do
    for {flag, index} <- Enum.with_index(selected),
        into: %{},
        do: {"#{index}", %{"selected" => "#{flag}"}}
  end

  defp newest, do: Expenses.list_expenses() |> Enum.max_by(& &1.id)

  test "a new expense is dated today, paid by the reader and shared by everybody",
       %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/expenses/new")

    assert page_title(view) == "Neue Ausgabe · Zipfelkasse"
    assert text(view, "h1") == "Ausgabe hinzufügen"
    assert value(view, "#expense_date") == [Date.to_iso8601(today())]
    assert value(view, "#expense_paid_by_id option[selected]") == ["#{h.anna}"]
    assert value(view, "#expense_currency option[selected]") == ["EUR"]
    assert length(value(view, "#expense-rows input[type=checkbox][checked]")) == 3

    assert value(view, "#expense-rows input[type=hidden][name$='[participant_id]']") ==
             ["#{h.anna}", "#{h.ben}", "#{h.cleo}"]

    refute has_element?(view, "#expense_rate")
    refute has_element?(view, "[id^=expense-delete]")
    assert has_element?(view, "#expense-submit", "Anlegen")
  end

  test "the split shows while typing and follows a new split mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/expenses/new")

    change(view, %{amount: "10"})
    shares = text(view, "#expense-rows")
    assert shares =~ "3,34 €"
    assert shares =~ "3,33 €"

    change(view, %{split_mode: "percent"})
    assert value(view, "#expense-rows input[name$='[weight]']") == ["33,34", "33,33", "33,33"]
    assert text(view, "#expense-split-sum") == "Summe 100 %."
    assert has_element?(view, "#expense-split-more[open]")

    change(view, %{rows: %{"0" => %{weight: "50"}}})
    assert text(view, "#expense-split-sum") == "Summe 116,66 % – 16,66 zu viel %."
    assert has_element?(view, "#expense-split-sum.text-error-ink")
  end

  test "selecting everybody or nobody", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/expenses/new")

    assert text(view, "#expense-select-all") == "Keine auswählen"
    view |> element("#expense-select-all") |> render_click()
    assert value(view, "#expense-rows input[type=checkbox][checked]") == []
    assert text(view, "#expense-select-all") == "Alle auswählen"
  end

  test "creating an expense goes back to the list with a message", %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/expenses/new")

    submit(view, %{title: "  Wochen   markt ", amount: "30", category_id: "#{h.food}"})

    {path, flash} = assert_redirect(view)
    assert {path, flash["info"]} == {"/", "Ausgabe „Wochen markt“ angelegt."}
    expense = newest()

    assert {expense.title, expense.amount_cents, expense.paid_by_id} ==
             {"Wochen markt", 3000, h.anna}

    assert Enum.map(expense.shares, & &1.amount_cents) |> Enum.sum() == 3000
  end

  test "errors show at the top with their count and stay until their field changes",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/expenses/new")

    submit(view, %{title: "Kino", amount: ""})

    assert text(view, "#expense-form [role=alert]") =~ "1 Feld ist noch nicht richtig"
    assert text(view, "#expense_amount-error-0") == "Bitte einen Betrag eingeben."
    assert has_element?(view, "#expense_amount[aria-invalid=true]")

    assert has_element?(
             view,
             "#expense-form[phx-hook='Setzkasten.Components.Forms.FocusInvalid']"
           )

    change(view, %{notes: "Spätvorstellung"})
    assert has_element?(view, "#expense_amount-error-0")

    change(view, %{amount: "12"})
    refute has_element?(view, "#expense_amount-error-0")
    refute has_element?(view, "#expense-form [role=alert]")

    submit(view, %{title: " ", rows: rows([false, false, false])})

    assert text(view, "#expense-rows-error-0") ==
             "Bitte mindestens eine Person ankreuzen, für die bezahlt wurde."

    assert has_element?(view, "#expense-split[aria-invalid=true]")
    assert Expenses.list_expenses() == []
  end

  test "editing shows the values and history and saves the changes", %{conn: conn, h: h} do
    expense =
      create!(equal(h, "Gleich 1", 1000, "2026-10-01", h.anna, [h.anna, h.ben, h.cleo]), h.anna)

    {:ok, view, _html} = live(conn, ~p"/expenses/#{expense}")

    assert page_title(view) == "Gleich 1 · Zipfelkasse"
    assert text(view, "h1") == "Ausgabe bearbeiten"
    assert text(view, "main header") =~ "Angelegt am #{Format.date(LocalTime.today())}"
    assert value(view, "#expense_amount") == ["10,00"]
    assert text(view, "#expense-activities") =~ "Anna hat „Gleich 1“ angelegt (10,00 €)."

    assert has_element?(
             view,
             ~s(a[href="/settings/recurring/new?expense_id=#{expense.id}"]),
             "Als wiederkehrend einrichten"
           )

    submit(view, %{title: "Gleich groß", amount: "45", split_mode: "shares"})

    {"/", %{"info" => "Ausgabe „Gleich groß“ gespeichert."}} = assert_redirect(view)

    {:ok, view, _html} = live(conn, ~p"/expenses/#{expense}")
    assert text(view, "#expense-activities") =~ "Titel: Gleich 1 → Gleich groß"
    assert has_element?(view, "#expense-activities del", "10,00 €")
    assert has_element?(view, "#expense-activities ins", "45,00 €")
  end

  test "deleting asks first, then the expense is read-only", %{conn: conn, h: h} do
    expense = create!(equal(h, "Pizza", 3000, "2026-10-01", h.anna, [h.anna, h.ben]))

    {:ok, view, _html} = live(conn, ~p"/expenses/#{expense}")

    assert asked(view, "#expense-delete").text ==
             "Sie verschwindet aus Liste und Salden; im Aktivitätsprotokoll bleibt sie sichtbar."

    confirm_click(view, "#expense-delete", "Diese Ausgabe wirklich löschen?")
    assert {"/", %{"info" => "„Pizza“ gelöscht."}} = assert_redirect(view)

    {:ok, view, _html} = live(conn, ~p"/expenses/#{expense}")
    assert text(view, "h1") == "Gelöschte Ausgabe"
    assert text(view, "main [role=status]") =~ "gelöscht und zählt nicht mehr zu den Salden."
    assert has_element?(view, "#expense-form fieldset[disabled]")
    refute has_element?(view, "#expense-submit")
    refute has_element?(view, "a", "Als wiederkehrend einrichten")
    assert text(view, "#expense-activities") =~ "Anna hat „Pizza“ gelöscht (30,00 €)."
  end

  test "an unknown expense is not found", %{conn: conn} do
    for path <- ["/expenses/999", "/expenses/abc", "/expenses/0"] do
      {404, _headers, body} = assert_error_sent(404, fn -> get(conn, path) end)
      assert body =~ "Ausgabe nicht gefunden."
      assert body =~ "Zur Startseite"
    end
  end

  test "a suggested reimbursement comes prefilled", %{conn: conn, h: h} do
    path = ~p"/expenses/new?#{[reimbursement: 1, from: h.cleo, to: h.anna, amount: 1001]}"
    {:ok, view, _html} = live(conn, path)

    assert value(view, "#expense_reimbursement[checked]") == ["true"]
    assert value(view, "#expense_title") == ["Rückzahlung"]
    assert value(view, "#expense_amount") == ["10,01"]
    assert value(view, "#expense_paid_by_id option[selected]") == ["#{h.cleo}"]
    assert text(view, "label[for=expense_paid_by_id]") == "Zurückgezahlt von"
    assert text(view, "#expense-split-heading") == "An wen?"
    assert length(value(view, "#expense-rows input[type=checkbox][checked]")) == 1
    refute has_element?(view, "#expense-select-all")

    submit(view, %{})

    assert {"/", %{"info" => "Rückzahlung „Rückzahlung“ angelegt."}} = assert_redirect(view)
    expense = newest()

    assert {expense.reimbursement, expense.paid_by_id, expense.amount_cents} ==
             {true, h.cleo, 1001}

    assert [%{participant_id: anna, amount_cents: 1001}] = expense.shares
    assert anna == h.anna
  end

  test "nonsense in the prefill gives an empty reimbursement", %{conn: conn, h: h} do
    {:ok, view, _html} =
      live(conn, ~p"/expenses/new?#{[reimbursement: 1, from: "x", to: 999, amount: -3]}")

    assert value(view, "#expense_paid_by_id option[selected]") == ["#{h.anna}"]
    assert value(view, "#expense_amount") == [""]
    assert value(view, "#expense-rows input[type=checkbox][checked]") == []
  end

  test "a foreign amount looks its rate up and takes a typed one", %{conn: conn} do
    Repo.insert!(%Rate{currency: "USD", source: :ecb, date: Date.add(today(), -1), rate: 1.25})
    {:ok, view, _html} = live(conn, ~p"/expenses/new")

    change(view, %{currency: "USD", amount: "10"})
    render_async(view)

    assert value(view, "#expense_rate") == ["1,25"]

    assert text(view, "#expense_rate-help") ==
             "EZB-Kurs vom #{Format.date(Date.add(today(), -1))}."

    assert text(view, "#expense-eur") == "8,00 €"

    change(view, %{rate: "1,6"})
    assert text(view, "#expense_rate-help") == "Von Hand eingetragener Kurs."
    assert has_element?(view, "#expense-load-rate")
    submit(view, %{title: "Diner"})

    assert {"/", _flash} = assert_redirect(view)
    expense = newest()

    assert {expense.original_currency, expense.original_amount, expense.fx_rate,
            expense.fx_source, expense.amount_cents} == {"USD", 1000, 1.6, :manual, 625}
  end

  test "a reconnect recovers the form as typed, without what an edit implies",
       %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/expenses/new")

    render_hook(view, "recover", %{
      "expense" => %{
        "title" => "Ferienhaus",
        "currency" => "USD",
        "amount" => "300",
        "rate" => "1,2",
        "rate_source" => "manual",
        "split_mode" => "shares",
        "rows" => %{
          "0" => %{"participant_id" => "#{h.anna}", "selected" => "true", "weight" => "2"},
          "1" => %{"participant_id" => "#{h.ben}", "selected" => "true", "weight" => "1"},
          "2" => %{"participant_id" => "#{h.cleo}", "selected" => "false", "weight" => ""}
        }
      }
    })

    assert value(view, "#expense-rows input[name$='[weight]']") == ["2", "1", ""]
    assert value(view, "#expense_rate") == ["1,2"]
    assert text(view, "#expense_rate-help") == "Von Hand eingetragener Kurs."
    assert text(view, "#expense-eur") == "250,00 €"
  end

  test "a currency without a rate asks for one by hand", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/expenses/new")

    change(view, %{currency: ""})
    change(view, %{currency_other: "thb", amount: "100"})
    render_async(view)

    assert text(view, "#expense_rate-help") ==
             "Kein Kurs verfügbar. Kurs bitte von Hand eintragen."

    submit(view, %{title: "Tuk-Tuk"})
    assert text(view, "#expense_rate-error-0") =~ "Für THB ist am"

    change(view, %{rate: "40"})
    assert text(view, "#expense-eur") == "2,50 €"
    submit(view, %{})
    assert {"/", _flash} = assert_redirect(view)
    assert %{original_currency: "THB", amount_cents: 250} = newest()
  end

  test "a title suggests the category of earlier ones", %{conn: conn, h: h} do
    create!(
      Map.put(
        equal(h, "Kaufland", 1000, "2026-10-01", h.anna, [h.anna]),
        :category_id,
        h.restaurant
      )
    )

    {:ok, view, _html} = live(conn, ~p"/expenses/new")

    change(view, %{title: "Kaufland"})

    assert value(view, "#expense_category_id option[selected]") == ["#{h.restaurant}"]
    assert text(view, "#expense_category_id-help") == "Vorschlag anhand früherer Ausgaben"
  end
end
