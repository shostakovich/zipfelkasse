defmodule ZipfelkasseWeb.YnabLiveStateTest do
  use ZipfelkasseWeb.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Zipfelkasse.Fixtures

  alias Zipfelkasse.{FakeYnab, Repo, Ynab}

  setup %{conn: conn} do
    h = household()
    %{h: h, fake: FakeYnab.start(), conn: init_test_session(conn, participant_id: h.anna)}
  end

  test "a failed load says so and loads again on request", %{conn: conn, h: h} do
    Repo.query!(
      "INSERT INTO ynab_connections (participant_id, start_date, inserted_at, updated_at) " <>
        "VALUES (?, 'kaputt', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')",
      [h.anna]
    )

    {:ok, view, _html} = live(conn, ~p"/settings/ynab")
    render_async(view)

    assert has_element?(
             view,
             "#ynab-failed",
             "Die YNAB-Einstellungen konnten nicht geladen werden."
           )

    refute has_element?(view, "#ynab-loading")

    Repo.query!("DELETE FROM ynab_connections")
    view |> element("#ynab-retry") |> render_click()
    render_async(view)

    refute has_element?(view, "#ynab-failed")
    assert has_element?(view, "#ynab-token-submit", "Verbinden")
  end

  test "while one change runs, the others wait", %{conn: conn, h: h, fake: fake} do
    {:ok, _message} = Ynab.save_token(h.anna, FakeYnab.token())
    {:ok, _message} = Ynab.choose_target(h.anna, "plan-1|acc-geteilt", "2026-09-01")
    {:ok, view, _html} = live(conn, ~p"/settings/ynab")
    render_async(view)

    FakeYnab.hold(fake)

    html =
      view
      |> form("#ynab-token-form", connection: %{token: FakeYnab.other_token()})
      |> render_submit()

    disabled =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("button[disabled]")
      |> LazyHTML.attribute("id")

    for id <-
          ~w(ynab-token-submit ynab-disconnect ynab-target-submit ynab-mapping-submit ynab-sync),
        do: assert(id in disabled)

    FakeYnab.release(fake)
    render_async(view)
    render_async(view)

    refute has_element?(view, "button#ynab-sync[disabled]")
  end
end
