defmodule ZipfelkasseWeb.RecurringNewLive.NoteTest do
  use ExUnit.Case, async: true

  alias ZipfelkasseWeb.RecurringNewLive

  @later "eingetragen – die ersten 400 Termine sofort, der Rest in den nächsten Stunden"

  for {{missed, existing}, note} <- [
        {{0, 0}, ""},
        {{1, 0}, "1 verpasster Termin wird sofort eingetragen"},
        {{4, 1},
         "3 verpasste Termine werden sofort eingetragen; 1 bereits als Ausgabe vorhandener Termin wird übersprungen"},
        {{2, 2}, "2 bereits als Ausgabe vorhandene Termine werden übersprungen"},
        {{400, 0}, "400 verpasste Termine werden sofort eingetragen"},
        {{610, 10},
         "600 verpasste Termine werden #{@later}; 10 bereits als Ausgabe vorhandene Termine werden übersprungen"},
        {{1001, 0}, "mehr als 1000 verpasste Termine werden #{@later}"},
        {{1001, 3},
         "mehr als 1000 verpasste Termine werden #{@later}; mindestens 3 bereits als Ausgabe vorhandene Termine werden übersprungen"}
      ] do
    test "#{missed} missed dates of which #{existing} exist" do
      assert RecurringNewLive.note(%{missed: unquote(missed), existing: unquote(existing)}) ==
               unquote(note)
    end
  end
end

defmodule ZipfelkasseWeb.RecurringNewLiveTest do
  use ZipfelkasseWeb.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Zipfelkasse.Fixtures
  import ZipfelkasseWeb.PageText

  alias Setzkasten.Format
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.{LocalTime, Recurring, Repo}

  setup %{conn: conn} do
    h = household()
    %{h: h, conn: init_test_session(conn, participant_id: h.anna)}
  end

  defp new_page(id), do: ~p"/settings/recurring/new?#{[expense_id: id]}"

  defp choose(view, frequency),
    do: view |> form("#recurring-form", recurring: %{frequency: frequency}) |> render_submit()

  test "without an expense it says where to start", %{conn: conn} do
    for path <- [~p"/settings/recurring/new", new_page("")] do
      {:ok, view, _html} = live(conn, path)

      assert texts(view, "h1") == ["Wiederkehrende Ausgabe anlegen"]

      assert texts(view, "main p") |> Enum.join(" ") =~
               "Öffne zuerst die Ausgabe, die sich wiederholen soll, und wähle dort „Als wiederkehrend einrichten“."

      assert has_element?(view, ~s(main a[href="/"]), "Zu den Ausgaben")
      refute has_element?(view, "#recurring-form")
    end
  end

  test "an unknown or deleted expense is not found", %{conn: conn, h: h} do
    expense = create!(equal(h, "Kino", 2400, "2026-09-01", h.anna, [h.anna, h.ben]))
    {:ok, _deleted} = Zipfelkasse.Expenses.delete_expense(h.anna, expense)

    for id <- ["abc", "0", "-1", "999", "1.5", "#{expense.id}"] do
      {404, _headers, body} = assert_error_sent(404, fn -> get(conn, new_page(id)) end)
      assert body =~ "Ausgabe nicht gefunden."
    end
  end

  test "summary and the frequencies with their previews", %{conn: conn, h: h} do
    date = Date.add(LocalTime.today(), -40)

    attrs =
      h
      |> equal("Miete", 100_000, Date.to_iso8601(date), h.anna, [h.anna, h.ben])
      |> Map.put(:notes, "Warm")

    expense = create!(attrs)
    {:ok, view, _html} = live(conn, new_page(expense.id))

    assert texts(view, "#recurring-expense dt") ==
             [
               "Titel",
               "Betrag",
               "Bezahlt von",
               "Kategorie",
               "Aufteilung",
               "Notiz",
               "Erster Termin"
             ]

    assert texts(view, "#recurring-expense dd") ==
             [
               "Miete",
               "1.000,00 €",
               "Anna",
               "Lebensmittel",
               "Gleichmäßig",
               "Warm",
               Format.date(date)
             ]

    [weekly, monthly, yearly] = Recurring.previews(expense)

    assert texts(view, "#recurring-form fieldset label") == [
             "Wöchentlich Nächster Termin #{Format.date(weekly.next_date)}; " <>
               "#{weekly.missed} verpasste Termine werden sofort eingetragen",
             "Monatlich Nächster Termin #{Format.date(monthly.next_date)}; " <>
               "1 verpasster Termin wird sofort eingetragen",
             "Jährlich Nächster Termin #{Format.date(yearly.next_date)}"
           ]

    assert has_element?(view, "#recurring_frequency_monthly[checked]")
    assert has_element?(view, ~s(a[href="/expenses/#{expense.id}"]), "Abbrechen")
  end

  test "a reconnect recovers the chosen frequency", %{conn: conn, h: h} do
    expense = create!(equal(h, "Kino", 2400, "2026-09-01", h.anna, [h.anna, h.ben]))
    {:ok, view, _html} = live(conn, new_page(expense.id))

    render_hook(view, "recover", %{"recurring" => %{"frequency" => "yearly"}})

    assert has_element?(view, "#recurring_frequency_yearly[checked]")
    refute has_element?(view, "#recurring_frequency_monthly[checked]")
  end

  test "makes the expense recurring and enters the missed dates", %{conn: conn, h: h} do
    date = Date.add(LocalTime.today(), -14)
    expense = create!(equal(h, "Gemüsekiste", 2890, Date.to_iso8601(date), h.ben, [h.ben]))
    {:ok, view, _html} = live(conn, new_page(expense.id))

    choose(view, "weekly")

    assert {"/settings/recurring", %{"info" => message}} = assert_redirect(view)
    assert message == "„Gemüsekiste“ wiederholt sich jetzt wöchentlich. 2 Ausgaben nachgetragen."
    assert Repo.aggregate(Expense, :count) == 3
    assert [rule] = Recurring.list_rules()
    assert {rule.frequency, rule.created_by_id} == {:weekly, h.anna}
  end

  test "a missing frequency and an expense that already recurs", %{conn: conn, h: h} do
    expense =
      create!(equal(h, "Zeitung", 2490, Date.to_iso8601(LocalTime.today()), h.anna, [h.anna]))

    {:ok, view, _html} = live(conn, new_page(expense.id))

    for frequency <- ["", "daily"] do
      render_hook(view, "create", %{"recurring" => %{"frequency" => frequency}})
      assert texts(view, "#recurring_frequency-error-0") == ["Bitte eine Häufigkeit wählen."]
    end

    render_hook(view, "create", %{})
    assert texts(view, "#recurring_frequency-error-0") == ["Bitte eine Häufigkeit wählen."]

    {:ok, _rule, 0} = Recurring.create_rule(h.ben, expense, :monthly)
    choose(view, "yearly")

    assert flash(view, :error) == "Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe."

    assert has_element?(
             view,
             "#recurring-exists",
             "Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe."
           )

    assert has_element?(view, ~s(#recurring-exists a[href="/settings/recurring"]))
    refute has_element?(view, "#recurring-form")
  end
end
