defmodule ZipfelkasseWeb.YnabLiveTest do
  use ZipfelkasseWeb.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Zipfelkasse.Fixtures
  import ZipfelkasseWeb.PageText

  alias Zipfelkasse.{FakeYnab, Ynab}
  alias Zipfelkasse.Ynab.{Connections, Sync}

  @target "plan-1|acc-geteilt"

  setup %{conn: conn} do
    h = household()
    %{h: h, fake: FakeYnab.start(), conn: init_test_session(conn, participant_id: h.anna)}
  end

  defp open(conn, path \\ ~p"/settings/ynab") do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp connect(h) do
    {:ok, _message} = Ynab.save_token(h.anna, FakeYnab.token())
    {:ok, _message} = Ynab.choose_target(h.anna, @target, "2026-09-01")
  end

  # A finished action reloads the overview in a second task.
  defp settle(view) do
    render_async(view)
    render_async(view)
  end

  defp save_token(view, token) do
    view |> form("#ynab-token-form", connection: %{token: token}) |> render_submit()
    settle(view)
  end

  defp click(view, selector) do
    view |> element(selector) |> render_click()
    settle(view)
  end

  test "loads YNAB in the background, explaining how it works", %{conn: conn} do
    assert conn |> get(~p"/settings/ynab") |> html_response(200) =~ ~s(id="ynab-loading")

    view = open(conn)

    assert page_title(view) == "YNAB · Zipfelkasse"
    assert has_element?(view, "section[aria-labelledby=ynab-how] li", "Lege in YNAB ein Konto")
    refute has_element?(view, "#ynab-loading")
    assert texts(view, "#ynab-token-submit") == ["Verbinden"]
    refute has_element?(view, "#ynab-target")
    refute has_element?(view, "#ynab-status")
    refute has_element?(view, "#ynab-disconnect")
  end

  test "checks the token with YNAB before saving it", %{conn: conn, h: h} do
    view = open(conn)

    save_token(view, " ")
    assert flash(view, :error) == "Bitte einen Token eingeben."

    save_token(view, "wrong")
    assert flash(view, :error) == "YNAB kennt diesen Token nicht. Bitte prüfen und neu kopieren."

    save_token(view, FakeYnab.token())
    assert flash(view, :info) == "Token gespeichert."
    assert has_element?(view, "#connection_token-1[value='']")
    assert Connections.get(h.anna).token == FakeYnab.token()

    assert texts(view, "section[aria-labelledby=ynab-connection] p.mb-3") |> List.last() ==
             "Token: gesetzt"

    assert texts(view, "#ynab-token-submit") == ["Token ersetzen"]

    assert has_element?(
             view,
             ~s(#target_account optgroup[label=Haushalt] option[value="#{@target}"]),
             "Geteilt"
           )

    refute has_element?(view, ~s(#target_account option), "Depot")
    assert texts(view, "#ynab-facts dt") == ["Dein Saldo in Zipfelkasse"]

    assert has_element?(
             view,
             "section[aria-labelledby=ynab-status] p",
             "Sobald Plan, Konto und Startdatum gewählt sind"
           )
  end

  test "choosing plan, account and start, then mapping categories", %{conn: conn, h: h} do
    {:ok, _message} = Ynab.save_token(h.anna, FakeYnab.token())
    view = open(conn)

    view
    |> form("#ynab-target-form", target: %{account: @target, start: "2026-09-01"})
    |> render_submit()

    settle(view)

    assert flash(view, :info) == "Gespeichert."
    assert %{plan_id: "plan-1", account_id: "acc-geteilt"} = Connections.get(h.anna)
    assert has_element?(view, "#target_account option[selected][value='#{@target}']")
    assert has_element?(view, "#target_start[value='2026-09-01']")

    assert has_element?(
             view,
             ~s(#mapping_#{h.food} optgroup[label="Wohnen & <Freizeit>"] option[value=c-rent]),
             "Miete"
           )

    refute has_element?(view, "#mapping_#{h.food} option[value=c-visa]")

    view
    |> form("#ynab-mapping-form", mapping: %{"#{h.food}" => "c-food"})
    |> render_submit()

    settle(view)

    assert flash(view, :info) == "Kategorie-Zuordnung gespeichert."
    assert has_element?(view, "#mapping_#{h.food} option[selected][value=c-food]")

    click(view, "#ynab-sync")

    assert flash(view, :info) ==
             "Synchronisierung gestartet – Status unten aktualisiert sich nach dem Neuladen."
  end

  test "the status after a sync and the problems of single expenses", %{conn: conn, h: h} do
    connect(h)
    create!(equal(h, "Kino", 2400, "2026-09-20", h.anna, [h.anna, h.ben]))
    create!(equal(h, "REJECT me", 1000, "2026-09-21", h.ben, [h.anna, h.ben]))
    Sync.sync_person(h.anna, true)

    view = open(conn)

    assert texts(view, "#ynab-facts dt") ==
             ["Dein Saldo in Zipfelkasse", "Synchronisierte Buchungen", "Letzter Abgleich"]

    [balance, synced, last] = texts(view, "#ynab-facts dd")
    assert {balance, synced} == {"+7,00 €", "1"}

    assert last =~
             ~r/^\d\d\.\d\d\.\d{4}, \d\d:\d\d \(1 neu · 0 geändert · 0 gelöscht · 1 fehlgeschlagen\)$/

    assert texts(view, "#ynab-problems tr") |> hd() =~ "REJECT me"
    assert has_element?(view, "#ynab-problems a[href^='/expenses/']")
  end

  test "YNAB unreachable, a token refused later and disconnecting",
       %{conn: conn, h: h, fake: fake} do
    connect(h)
    FakeYnab.fail(fake, [503, 503])

    view = open(conn, ~p"/settings/ynab?refresh=1")

    assert texts(view, "#ynab-api-error") ==
             ["YNAB ist gerade nicht erreichbar: YNAB-Fehler 503: Error 503 with •••"]

    refute render(view) =~ FakeYnab.token()

    assert texts(view, "section[aria-labelledby=ynab-categories] p") |> List.last() ==
             "Die Kategorien aus YNAB konnten nicht geladen werden."

    :ok = Connections.put_status(h.anna, %{Connections.get(h.anna) | token_invalid: true})

    view = open(conn)

    assert has_element?(
             view,
             "[role=alert]",
             "Der gespeicherte Token ist ungültig oder abgelaufen."
           )

    refute has_element?(view, "#ynab-target-form")

    click(view, "#ynab-disconnect")

    assert flash(view, :info) ==
             "YNAB-Verbindung getrennt. Die Buchungen in YNAB bleiben erhalten."

    assert Connections.get(h.anna).token == nil
    assert texts(view, "#ynab-token-submit") == ["Verbinden"]
  end
end
