defmodule ZipfelkasseWeb.EndpointTest do
  use ZipfelkasseWeb.ConnCase

  test "serves Setzkasten's Figtree font", %{conn: conn} do
    conn = get(conn, "/setzkasten/fonts/Figtree-Variable.woff2")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["font/woff2"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=86400"]
  end

  test "serves the app's images", %{conn: conn} do
    conn = get(conn, ~p"/images/brand/mascot-light.webp")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
  end

  test "does not read multipart bodies: the app takes no uploads", %{conn: conn} do
    body = "--x\r\ncontent-disposition: form-data; name=\"person[name]\"\r\n\r\nJörg\r\n--x--\r\n"

    conn =
      conn
      |> put_req_header("content-type", "multipart/form-data; boundary=x")
      |> post(~p"/who/new", body)

    assert conn.status == 422
    assert Zipfelkasse.Participants.list_participants() == []
  end

  test "reads request bodies up to 1 MiB, like the MCP endpoint", %{conn: conn} do
    form = fn size ->
      conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post(~p"/who", "x=" <> String.duplicate("a", size - 2))
    end

    assert form.(1_048_576).status == 422
    assert_error_sent 413, fn -> form.(1_048_577) end
  end

  test "a form needs the CSRF token of the session", %{conn: conn} do
    page = get(conn, ~p"/who")

    token =
      page
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(#who-create input[name="_csrf_token"]))
      |> LazyHTML.attribute("value")
      |> hd()

    form = fn params ->
      page
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post(~p"/who/new", Map.put(params, "person", %{"name" => "Jörg"}))
    end

    assert_error_sent 403, fn -> form.(%{}) end
    assert_error_sent 403, fn -> form.(%{"_csrf_token" => "forged"}) end
    assert redirected_to(form.(%{"_csrf_token" => token})) == "/"
  end
end
