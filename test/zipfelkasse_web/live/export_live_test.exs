defmodule ZipfelkasseWeb.ExportLiveTest do
  use ZipfelkasseWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZipfelkasseWeb.PageText

  setup %{conn: conn} do
    {:ok, anna} = Zipfelkasse.Participants.join(%{name: "Anna"})
    %{conn: init_test_session(conn, participant_id: anna.id)}
  end

  defp hrefs(view) do
    for link <- view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("main a[download]"),
        do: link |> LazyHTML.attribute("href") |> hd()
  end

  defp period(view, from, to),
    do: view |> form("#export-period", %{from: from, to: to}) |> render_change()

  test "downloads everything without a period", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/export")

    assert page_title(view) == "Export · Zipfelkasse"

    assert hrefs(view) == [
             "/export/expenses.csv",
             "/export/expenses.json",
             "/export/ynab.ofx",
             "/export/ynab.csv"
           ]

    assert texts(view, "#export-expenses-csv") == ["CSV (Excel, Numbers)"]
    assert has_element?(view, "#export-expenses-csv.btn-primary")
    assert has_element?(view, ~s(main a[href="/settings/ynab"]), "YNAB-Verbindung")
  end

  test "the links follow the period", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/export")

    period(view, "2026-09-01", "2026-09-30")

    assert hrefs(view) == [
             "/export/expenses.csv?from=2026-09-01&to=2026-09-30",
             "/export/expenses.json?from=2026-09-01&to=2026-09-30",
             "/export/ynab.ofx?from=2026-09-01&to=2026-09-30",
             "/export/ynab.csv?from=2026-09-01&to=2026-09-30"
           ]

    period(view, "", "2026-09-30")
    assert hrefs(view) |> hd() == "/export/expenses.csv?to=2026-09-30"
  end

  test "an end before the start is shown and blocks the downloads", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/export")

    period(view, "2026-09-30", "2026-09-01")

    assert texts(view, "#to-error-0") == ["„Bis“ liegt vor „Von“."]
    assert hrefs(view) == []
    assert has_element?(view, ~s(a#export-ynab-ofx[aria-disabled="true"]))
    refute has_element?(view, "a#export-ynab-ofx[href]")
  end

  test "the period's error shows on the field not typed in too", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/export?to=2026-09-01")

    render_change(view, "period", %{
      "from" => "2026-09-30",
      "to" => "2026-09-01",
      "_unused_to" => ""
    })

    assert texts(view, "#to-error-0") == ["„Bis“ liegt vor „Von“."]
  end

  test "a period in the address is preset, with its error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/export?from=2026-09-30&to=2026-09-01")

    assert has_element?(view, "#from[value='2026-09-30']")
    assert texts(view, "#to-error-0") == ["„Bis“ liegt vor „Von“."]
    assert hrefs(view) == []

    {:ok, view, _html} = live(conn, ~p"/export?from=broken")
    assert texts(view, "#from-error-0") == ["Ungültiges Datum „broken“."]
    refute has_element?(view, "#to-error-0")

    {:ok, view, _html} = live(conn, ~p"/export?from=2026-09-01")
    assert hrefs(view) |> hd() == "/export/expenses.csv?from=2026-09-01"
  end
end
