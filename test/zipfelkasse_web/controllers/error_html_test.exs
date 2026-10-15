defmodule ZipfelkasseWeb.ErrorHTMLTest do
  use ZipfelkasseWeb.ConnCase

  alias ZipfelkasseWeb.ErrorHTML

  test "a missing page is German, with the way back to the start", %{conn: conn} do
    conn = get(conn, "/nope")
    body = html_response(conn, 404)

    assert body =~ "<title"
    assert body =~ "Seite nicht gefunden."
    assert body =~ ~s(href="/")
    assert body =~ "Zur Startseite"
    refute body =~ "Hauptnavigation"
  end

  test "the person using the app keeps the navigation on an error page", %{conn: conn} do
    {:ok, anna} = Zipfelkasse.Participants.join(%{name: "Anna"})
    conn = init_test_session(conn, participant_id: anna.id)

    {404, _headers, body} = assert_error_sent(404, fn -> get(conn, "/expenses/42") end)

    assert body =~ "Ausgabe nicht gefunden."
    assert body =~ "Hauptnavigation"
    assert body =~ "Anna"
  end

  test "the messages of the error statuses" do
    assert ErrorHTML.message(400) == "Ungültige Anfrage."
    assert ErrorHTML.message(403) =~ "Diese Anfrage kam von einer fremden Seite"
    assert ErrorHTML.message(413) =~ "Die gesendeten Daten sind zu groß."
    assert ErrorHTML.message(500) == "Da ist etwas schiefgegangen."
    assert ErrorHTML.message(418) == "I'm a teapot"
  end
end
