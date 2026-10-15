defmodule ZipfelkasseWeb.WhoControllerTest do
  use ZipfelkasseWeb.ConnCase

  import ZipfelkasseWeb.PageText

  alias Zipfelkasse.{Activities, Participants}

  defp document(conn), do: conn |> html_response(conn.status) |> LazyHTML.from_document()

  defp attribute(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  test "before anybody exists the page asks to add oneself, without the navigation", %{conn: conn} do
    doc = conn |> get(~p"/who?#{[return_to: "/balances"]}") |> document()

    assert texts(doc, "title") == ["Wer bist du? · Zipfelkasse"]
    assert texts(doc, "h1") == ["Wer bist du?"]
    assert LazyHTML.text(doc) =~ "Wähle dich aus. Die App merkt sich das auf diesem Gerät."
    assert LazyHTML.text(doc) =~ "Leg dich unten als erste Person an."
    assert texts(doc, ~s(nav[aria-label="Hauptnavigation"])) == []
    assert attribute(doc, ~s(#who-create input[name="return_to"]), "value") == ["/balances"]
    assert attribute(doc, ~s(#who-create input[name="person[name]"]), "maxlength") == ["60"]
    assert texts(doc, "#who-create button") == ["Anlegen und auswählen"]
  end

  test "unsafe return targets become the start page", %{conn: conn} do
    for target <- ["//evil.example", "https://evil.example", "/who", "javascript:alert(1)"] do
      doc = build_conn() |> get(~p"/who?#{[return_to: target]}") |> document()
      assert attribute(doc, ~s(#who-create input[name="return_to"]), "value") == ["/"]
    end

    assert conn |> get(~p"/who") |> html_response(200)
  end

  test "adding oneself chooses the new person and welcomes them", %{conn: conn} do
    conn =
      post(conn, ~p"/who/new", %{"person" => %{"name" => "  Jörg  "}, "return_to" => "/balances"})

    assert redirected_to(conn) == "/balances"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Willkommen!"
    [joerg] = Participants.list_participants()
    assert {joerg.name, get_session(conn, :participant_id)} == {"Jörg", joerg.id}

    assert [%{actor_id: actor, details: %{text: "Person „Jörg“ hinzugefügt"}}] =
             Activities.list_activities()

    assert actor == joerg.id
  end

  test "a name that is taken or empty is refused on the field", %{conn: conn} do
    {:ok, _joerg} = Participants.join(%{name: "Jörg"})

    conn = post(conn, ~p"/who/new", %{"person" => %{"name" => " jörg "}, "return_to" => "/x"})
    doc = document(conn)

    assert conn.status == 422
    assert texts(doc, "#who-create [id$=error-0]") == ["„jörg“ gibt es schon."]
    assert attribute(doc, ~s(#who-create input[name="person[name]"]), "value") == ["jörg"]
    assert attribute(doc, ~s(#who-create input[name="return_to"]), "value") == ["/x"]
    refute get_session(conn, :participant_id)

    doc = build_conn() |> post(~p"/who/new", %{"person" => %{"name" => "  "}}) |> document()

    assert texts(doc, "#who-create [id$=error-0]") == [
             "Bitte einen Namen für die Person angeben."
           ]
  end

  test "choosing a person goes back to where the visitor came from", %{conn: conn} do
    {:ok, anna} = Participants.join(%{name: "Anna"})
    {:ok, ben} = Participants.join(%{name: "Ben"})

    conn = post(conn, ~p"/who", %{"id" => "#{ben.id}", "return_to" => "/activity?x=1"})
    assert redirected_to(conn) == "/activity?x=1"
    assert get_session(conn, :participant_id) == ben.id

    doc = conn |> recycle() |> get(~p"/who") |> document()
    assert texts(doc, "#who-choose button") == ["Anna", "Ben"]
    assert attribute(doc, ~s(#who-choose button[aria-current="true"]), "value") == ["#{ben.id}"]
    assert texts(doc, "#current-participant") == ["Ben"]

    conn = post(build_conn(), ~p"/who", %{"id" => "#{anna.id}", "return_to" => "//evil.example"})
    assert redirected_to(conn) == "/"
  end

  test "an unknown or archived person cannot be chosen", %{conn: conn} do
    {:ok, _anna} = Participants.join(%{name: "Anna"})
    {:ok, ben} = Participants.join(%{name: "Ben"})
    {:ok, _ben} = Participants.archive_participant(nil, ben)

    for id <- ["#{ben.id}", "999", "abc", "", "0"] do
      conn = post(build_conn(), ~p"/who", %{"id" => id, "return_to" => "/balances"})
      doc = document(conn)

      assert conn.status == 422
      assert texts(doc, ~s(main [role="alert"])) == ["Diese Person gibt es nicht (mehr)."]
      assert attribute(doc, ~s(#who-choose input[name="return_to"]), "value") == ["/balances"]
      assert texts(doc, "#who-choose button") == ["Anna"]
    end

    assert conn |> post(~p"/who", %{}) |> html_response(422)
  end
end
