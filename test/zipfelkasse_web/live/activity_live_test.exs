defmodule ZipfelkasseWeb.ActivityLiveTest do
  use ZipfelkasseWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zipfelkasse.Fixtures
  import ZipfelkasseWeb.PageText

  alias Zipfelkasse.{Activities, Expenses, Repo}
  alias Zipfelkasse.Activities.Activity

  setup %{conn: conn} do
    h = household()
    %{h: h, conn: init_test_session(conn, participant_id: h.anna)}
  end

  defp age(activity, days) do
    moment = DateTime.add(activity.inserted_at, -days, :day)
    activity |> Ecto.Changeset.change(inserted_at: moment) |> Repo.update!()
  end

  test "entries under period headings say who did what, with the changes", %{conn: conn, h: h} do
    expense = create!(equal(h, "Einkauf", 1234, "2026-10-01", h.anna, [h.anna, h.ben]), h.anna)

    {:ok, _expense} =
      Expenses.update_expense(h.ben, expense, %{Expenses.input(expense) | title: "Einkauf groß"})

    for activity <- Repo.all(Activity),
        activity.action == :settings_updated,
        do: age(activity, 400)

    {:ok, view, _html} = live(conn, ~p"/activity")

    assert texts(view, "#activities > li[id^=group-]") == ["Heute", "Letztes Jahr"]

    assert [changed, created | settings] =
             texts(view, "#activities > li[id^=activity-] .list-col-grow")

    assert changed =~
             ~r/^Ben hat „Einkauf groß“ geändert\. Titel: Einkauf → Einkauf groß \d\d\.\d\d\.\d{4}, \d\d:\d\d$/

    assert created =~ "Anna hat „Einkauf“ angelegt (12,34 €)."
    assert settings |> hd() =~ "Automatisch: Person „Cleo“ hinzugefügt"
    assert has_element?(view, ~s(#activities a[href="/expenses/#{expense.id}"]))
    assert has_element?(view, "#activities del", "Einkauf")
    assert has_element?(view, "#activities ins", "Einkauf groß")
  end

  test "50 entries at a time, older ones on request", %{conn: conn} do
    for n <- 1..48, do: {:ok, _activity} = Activities.log_settings(nil, "Eintrag #{n}")

    {:ok, view, _html} = live(conn, ~p"/activity")
    assert length(texts(view, "#activities > li[id^=activity-]")) == 50

    view |> element("#activities-older") |> render_click()

    assert length(texts(view, "#activities > li[id^=activity-]")) == 51
    assert texts(view, "#activities > li[id^=group-]") == ["Heute"]
    refute has_element?(view, "#activities-older")
  end

  test "changes to expenses show at once", %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/activity")

    expense = create!(equal(h, "Kino", 2400, "2026-10-01", h.ben, [h.anna, h.ben]), h.ben)

    assert has_element?(view, "#activity-#{hd(Activities.list_activities(limit: 1)).id}", "Kino")
    assert texts(view, "#activities > li[id^=group-]") == ["Heute"]

    {:ok, _deleted} = Expenses.delete_expense(h.anna, expense)

    assert [deleted, _created | _settings] =
             texts(view, "#activities > li[id^=activity-] .list-col-grow")

    assert deleted =~ "Anna hat „Kino“ gelöscht (24,00 €)."
  end
end
