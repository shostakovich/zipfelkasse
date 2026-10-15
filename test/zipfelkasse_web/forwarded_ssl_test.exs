defmodule ZipfelkasseWeb.ForwardedSSLTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ZipfelkasseWeb.ForwardedSSL

  defp request(proto) do
    conn = conn(:get, "http://kasse.example.org/")
    conn = if proto, do: put_req_header(conn, "x-forwarded-proto", proto), else: conn

    conn
    |> ForwardedSSL.call(ForwardedSSL.init([]))
    |> put_resp_cookie("chosen", "anna")
    |> send_resp(200, "ok")
  end

  test "a request forwarded as HTTPS counts as HTTPS: HSTS and secure cookies" do
    for proto <- ["https", "HTTPS", " https , http"] do
      conn = request(proto)

      assert {conn.scheme, conn.port, conn.status} == {:https, 443, 200}, proto

      assert get_resp_header(conn, "strict-transport-security") ==
               ["max-age=63072000; includeSubDomains"]

      assert conn.resp_cookies["chosen"][:secure] == true
    end
  end

  test "a plain request stays HTTP: no redirect, no HSTS, no secure cookies" do
    for proto <- [nil, "http", "http, https", ""] do
      conn = request(proto)

      assert {conn.scheme, conn.port, conn.status} == {:http, 80, 200}, inspect(proto)
      assert get_resp_header(conn, "strict-transport-security") == []
      refute conn.resp_cookies["chosen"][:secure]
    end
  end
end
