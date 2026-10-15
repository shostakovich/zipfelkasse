defmodule ZipfelkasseWeb.RatesLiveTest do
  use ZipfelkasseWeb.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Setzkasten.Test.Confirm
  import Zipfelkasse.ActivityTexts
  import Zipfelkasse.Fixtures
  import ZipfelkasseWeb.PageText

  alias Zipfelkasse.{FakeEcb, Fx, LocalTime}
  alias Zipfelkasse.Fx.{Loader, Rate}

  setup %{conn: conn} do
    h = household()
    %{h: h, conn: init_test_session(conn, participant_id: h.anna)}
  end

  defp save(view, params),
    do: view |> form("#rate-form", rate: params) |> render_submit()

  test "an empty cache and no manual rates", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/rates")

    assert page_title(view) == "Wechselkurse · Zipfelkasse"
    assert texts(view, "main") |> hd() =~ "Noch keine manuellen Kurse."

    assert texts(view, "#rates-stats") == [
             "Noch keine EZB-Kurse zwischengespeichert – sie werden bei Bedarf automatisch geladen. " <>
               "Neue Kurse werden täglich um 17 Uhr automatisch abgerufen."
           ]

    assert has_element?(view, "#rate_date[value='#{Date.to_iso8601(LocalTime.today())}']")
    refute has_element?(view, "#ecb-rates")
    refute has_element?(view, "#used-rates")
  end

  test "keeps the manual rate as typed through a re-render", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/rates")

    view
    |> form("#rate-form", rate: %{currency: "THB", date: "2026-09-01", rate: "38,5"})
    |> render_change()

    view |> element("#rates-refresh") |> render_click()

    assert has_element?(view, "#rate_currency[value='THB']")
    assert has_element?(view, "#rate_date[value='2026-09-01']")
    assert has_element?(view, "#rate_rate[value='38,5']")
  end

  test "adds a manual rate as typed and deletes it after asking", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/rates")

    save(view, %{currency: " usd ", date: "2026-10-01", rate: "1,0850"})

    assert flash(view, :info) == "Kurs für USD gespeichert."
    assert texts(view, "#manual-rates tr") == ["USD 01.10.2026 1,085 USD"]
    assert has_element?(view, "#rate_currency[value=''][phx-patch-focused]")
    assert has_element?(view, "#rate_rate[value=''][phx-patch-focused]")
    assert last_activity() == "Manueller Kurs für USD ab 01.10.2026 gespeichert: 1 € = 1,085 USD"

    confirm_click(
      view,
      "#manual-USD-2026-10-01-delete",
      "Manuellen Kurs für USD ab 01.10.2026 löschen?"
    )

    assert flash(view, :info) == "Manueller Kurs für USD gelöscht."
    refute has_element?(view, "#manual-rates")
    assert Fx.list_manual_rates() == []
  end

  test "keeps the typed values with the errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/rates")

    save(view, %{currency: "EUR", date: "", rate: "abc"})

    assert texts(view, "#rate_currency-error-0") == ["Für Euro braucht es keinen Kurs."]
    assert texts(view, "#rate_date-error-0") == ["Bitte ein Datum angeben."]

    assert texts(view, "#rate_rate-error-0") == [
             "Ungültiger Wechselkurs „abc“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €)."
           ]

    assert has_element?(view, "#rate_rate[value=abc]")

    save(view, %{currency: "US", date: "2026-10-01", rate: ""})

    assert texts(view, "#rate_currency-error-0") ==
             ["Bitte einen dreistelligen Währungscode angeben (z. B. USD)."]

    assert texts(view, "#rate_rate-error-0") == ["Der Kurs muss größer als 0 sein."]
    assert Fx.list_manual_rates() == []
  end

  test "a rate deleted meanwhile", %{conn: conn, h: h} do
    {:ok, _rate} = Fx.put_manual_rate(h.ben, %{currency: "CHF", date: ~D[2026-09-01], rate: 0.95})
    {:ok, view, _html} = live(conn, ~p"/settings/rates")
    {:ok, _activity} = Fx.delete_manual_rate(h.ben, "CHF", ~D[2026-09-01])

    confirm_click(view, "#manual-CHF-2026-09-01-delete")

    assert flash(view, :error) == "Diesen manuellen Kurs gibt es nicht (mehr)."
    refute has_element?(view, "#manual-rates")
  end

  test "the ECB cache, its newest day and the rates of recent expenses", %{conn: conn, h: h} do
    :ok =
      Fx.save_ecb_rates([
        %{currency: "USD", date: ~D[2026-09-30], rate: 1.0912},
        %{currency: "USD", date: ~D[2026-10-01], rate: 1.1195},
        %{currency: "JPY", date: ~D[2026-10-01], rate: 177.39}
      ])

    usd = foreign(h, "Diner", 4200, "USD", 1.1195, "2026-10-01", h.anna, [h.anna, h.ben])
    expense = create!(usd)

    {:ok, view, _html} = live(conn, ~p"/settings/rates")

    assert texts(view, "#rates-stats") |> hd() =~
             "Zwischengespeichert: 3 Kurse für 2 Währungen vom 30.09.2026 bis 01.10.2026."

    assert texts(view, "#ecb-rates tr") ==
             ["JPY 01.10.2026 177,39 JPY", "USD 01.10.2026 1,1195 USD"]

    assert texts(view, "#used-rates tr") ==
             ["Diner 01.10.2026 · EZB 01.10.2026 1,1195 USD EZB"]

    assert has_element?(view, ~s(#used-rates a[href="/expenses/#{expense.id}"]))
  end

  test "refreshing the ECB rates in the background reports a failure", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/rates")

    view |> element("#rates-refresh") |> render_click()
    render_async(view)

    assert flash(view, :error) =~ "Die EZB-Kurse konnten nicht geladen werden"
    refute has_element?(view, "#rates-refresh[aria-busy]")
    assert Zipfelkasse.Repo.aggregate(Rate, :count) == 0
  end

  test "refreshing loads the newest ECB rates", %{conn: conn} do
    ecb = FakeEcb.start(~D[2026-10-01])
    :ok = Supervisor.terminate_child(Zipfelkasse.Supervisor, Loader)
    on_exit(fn -> Supervisor.restart_child(Zipfelkasse.Supervisor, Loader) end)

    start_supervised!(
      {Loader, base_url: ecb.url, clock: fn -> LocalTime.to_utc(~N[2026-10-02 12:00:00]) end},
      id: :test_loader
    )

    {:ok, view, _html} = live(conn, ~p"/settings/rates")

    view |> element("#rates-refresh") |> render_click()
    assert has_element?(view, "#rates-refresh[aria-busy]")
    render_async(view)

    assert flash(view, :info) == "EZB-Kurse aktualisiert (Stand 01.10.2026)."
    assert texts(view, "#ecb-rates tr") |> length() == 10
  end
end
