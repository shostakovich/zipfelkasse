defmodule ZipfelkasseWeb.ContentSecurityPolicyTest do
  use ZipfelkasseWeb.ConnCase

  alias ZipfelkasseWeb.ContentSecurityPolicy

  defp csp(headers) do
    [policy] = for {"content-security-policy", value} <- headers, do: value

    Map.new(String.split(policy, "; "), fn directive ->
      [name | sources] = String.split(directive, " ")
      {name, sources}
    end)
  end

  test "pages get a strict policy with a fresh nonce for the theme script", %{conn: conn} do
    {:ok, anna} = Zipfelkasse.Participants.join(%{name: "Anna"})
    conn = conn |> init_test_session(participant_id: anna.id) |> get(~p"/")
    html = html_response(conn, 200)
    policy = csp(conn.resp_headers)

    assert ["'self'", "'nonce-" <> nonce] = policy["script-src"]
    nonce = String.trim_trailing(nonce, "'")
    assert byte_size(Base.decode64!(nonce)) == 18

    assert policy == %{
             "default-src" => ["'self'"],
             "script-src" => ["'self'", "'nonce-#{nonce}'"],
             "style-src" => ["'self'"],
             "font-src" => ["'self'"],
             "img-src" => ["'self'", "data:"],
             "connect-src" => ["'self'", "ws://localhost:4002"],
             "object-src" => ["'none'"],
             "frame-ancestors" => ["'none'"],
             "base-uri" => ["'self'"],
             "form-action" => ["'self'"]
           }

    refute Enum.any?(Map.values(policy), &("'unsafe-inline'" in &1 or "'unsafe-eval'" in &1))

    scripts = html |> LazyHTML.from_document() |> LazyHTML.query("script:not([src])")
    assert Enum.count(scripts) == 1
    assert LazyHTML.attribute(scripts, "nonce") == [nonce]

    other = build_conn() |> get(~p"/") |> Map.fetch!(:resp_headers) |> csp()
    refute other["script-src"] == policy["script-src"]
  end

  test "Phoenix's secure headers stay, with the referrer kept on the same origin", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert get_resp_header(conn, "referrer-policy") == ["same-origin"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "x-permitted-cross-domain-policies") == ["none"]
  end

  describe "every response but the socket's gets the policy" do
    test "the health check, the font and static files" do
      for path <- [
            ~p"/up",
            "/setzkasten/fonts/Figtree-Variable.woff2",
            ~p"/images/brand/mascot-light.webp"
          ] do
        assert csp(get(build_conn(), path).resp_headers)["default-src"] == ["'self'"], path
      end
    end

    test "a missing page" do
      conn = get(build_conn(), "/nope")

      assert conn.status == 404
      assert csp(conn.resp_headers)["default-src"] == ["'self'"]
    end

    test "a body that is too large" do
      {413, headers, _body} =
        assert_error_sent(413, fn ->
          build_conn()
          |> put_req_header("content-type", "application/x-www-form-urlencoded")
          |> post(~p"/", "a=" <> String.duplicate("x", 1_048_576))
        end)

      assert csp(headers)["default-src"] == ["'self'"]
    end
  end

  test "behind https the socket connects over wss to the public host" do
    assert ContentSecurityPolicy.policy("n", "https://kasse.example.org") =~
             "; connect-src 'self' wss://kasse.example.org;"

    assert ContentSecurityPolicy.policy("n", "http://localhost:4000") =~
             "; connect-src 'self' ws://localhost:4000;"
  end
end
