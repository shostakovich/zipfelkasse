defmodule ZipfelkasseWeb.RecurringLiveTest do
  use ZipfelkasseWeb.ConnCase

  import Phoenix.LiveViewTest
  import Setzkasten.Test.Confirm
  import Zipfelkasse.Fixtures
  import ZipfelkasseWeb.PageText

  alias Setzkasten.Format
  alias Zipfelkasse.{Expenses, LocalTime, Recurring, Repo}
  alias Zipfelkasse.Expenses.Expense

  setup %{conn: conn} do
    h = household()
    %{h: h, conn: init_test_session(conn, participant_id: h.anna)}
  end

  defp days_ago(days), do: LocalTime.today() |> Date.add(-days) |> Date.to_iso8601()

  # A weekly rule from an expense a week ago whose occurrence of today is still due.
  defp due_rule(h, title \\ "Gemüsekiste") do
    expense = create!(equal(h, title, 2890, days_ago(7), h.ben, [h.anna, h.ben]), h.ben)
    yesterday = Date.add(LocalTime.today(), -1)
    {:ok, rule, 0} = Recurring.create_rule(h.anna, expense, :weekly, today: yesterday)
    rule
  end

  test "without rules it says how to make one", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/recurring")

    assert page_title(view) == "Wiederkehrende Ausgaben · Zipfelkasse"
    assert texts(view, "main") |> hd() =~ "Noch keine wiederkehrenden Ausgaben."
    assert texts(view, "main") |> hd() =~ "„Als wiederkehrend einrichten“"
    refute has_element?(view, "#rules")
  end

  test "a rule shows how often, since when, who pays, the next date and the amount",
       %{conn: conn, h: h} do
    rule = due_rule(h)

    {:ok, view, _html} = live(conn, ~p"/settings/recurring")

    assert texts(view, "#rule-#{rule.id} p.truncate") == [
             "Wöchentlich seit #{Format.date(rule.start_date)}",
             "Zahlt Ben",
             "Nächster Termin #{Format.date(LocalTime.today())}"
           ]

    assert texts(view, "#rule-#{rule.id} .font-medium") == ["Gemüsekiste"]
    assert has_element?(view, "#rule-#{rule.id} data", "28,90")
    assert has_element?(view, ~s(#rule-#{rule.id} img[src^="/images/plush/shopping-cart"]))
  end

  test "pausing and resuming, which enters the dates due since", %{conn: conn, h: h} do
    rule = due_rule(h)
    {:ok, _paused} = Recurring.pause_rule(h.anna, rule)

    {:ok, view, _html} = live(conn, ~p"/settings/recurring")
    assert texts(view, "#rule-#{rule.id} .badge") == ["pausiert"]

    view |> element("#rule-#{rule.id}-resume") |> render_click()
    assert flash(view, :info) == "Fortgesetzt. 1 Ausgabe angelegt."
    assert Repo.aggregate(Expense, :count) == 2

    view |> element("#rule-#{rule.id}-pause") |> render_click()
    assert flash(view, :info) == "Pausiert."
    view |> element("#rule-#{rule.id}-resume") |> render_click()
    assert flash(view, :info) == "Fortgesetzt."
  end

  test "taking the template from the newest occurrence", %{conn: conn, h: h} do
    rule = due_rule(h)

    {:ok, view, _html} = live(conn, ~p"/settings/recurring")

    view |> element("#rule-#{rule.id}-template-menu-item") |> render_click()
    assert flash(view, :info) == "Vorlage aus der letzten Ausgabe übernommen."

    [expense] = Expenses.list_expenses()
    {:ok, _deleted} = Expenses.delete_expense(h.anna, expense)
    view |> element("#rule-#{rule.id}-template-menu-item") |> render_click()

    assert flash(view, :error) ==
             "Es gibt keine Ausgabe dieser Wiederholung mehr, aus der die Vorlage übernommen werden könnte."
  end

  test "deleting asks first and keeps the expenses", %{conn: conn, h: h} do
    rule = due_rule(h)

    {:ok, view, _html} = live(conn, ~p"/settings/recurring")

    assert asked(view, "#rule-#{rule.id}-delete-menu-item").text ==
             "Bereits eingetragene Ausgaben bleiben erhalten."

    confirm_click(
      view,
      "#rule-#{rule.id}-delete-menu-item",
      "Wiederholung von „Gemüsekiste“ löschen?"
    )

    assert flash(view, :info) ==
             "Wiederholung gelöscht. Bereits angelegte Ausgaben bleiben erhalten."

    refute has_element?(view, "#rule-#{rule.id}")
    assert [%Expense{recurring_expense_id: nil}] = Expenses.list_expenses()
  end

  test "a rule that is gone meanwhile", %{conn: conn, h: h} do
    rule = due_rule(h)
    {:ok, view, _html} = live(conn, ~p"/settings/recurring")
    {:ok, _deleted} = Recurring.delete_rule(h.anna, rule)

    view |> element("#rule-#{rule.id}-pause") |> render_click()

    assert flash(view, :error) == "Wiederkehrende Ausgabe nicht gefunden."
    refute has_element?(view, "#rule-#{rule.id}")
  end
end
