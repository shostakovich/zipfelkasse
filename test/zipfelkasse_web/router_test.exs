defmodule ZipfelkasseWeb.RouterTest do
  use ZipfelkasseWeb.ConnCase

  @moduletag :capture_log

  # The only routes for anonymous visitors. A new public route belongs here, on purpose.
  @public [
    {:get, "/up"},
    {:get, "/manifest.webmanifest"},
    {:get, "/sw.js"},
    {:get, "/favicon.ico"},
    {:get, "/who"},
    {:post, "/who"},
    {:post, "/who/new"}
  ]

  test "every other route turns an anonymous visitor away" do
    routes = Enum.reject(ZipfelkasseWeb.Router.__routes__(), &({&1.verb, &1.path} in @public))

    assert %{verb: :get, path: "/"} in Enum.map(routes, &Map.take(&1, [:verb, :path]))

    for %{verb: verb, path: path} <- routes do
      concrete = String.replace(path, ~r"[:*]\w+", "x")
      method = if verb == :*, do: "POST", else: verb |> to_string() |> String.upcase()
      conn = dispatch(build_conn(), @endpoint, method, concrete, nil)

      assert turned_away?(conn), "#{method} #{path} answered #{conn.status} without a person"
    end
  end

  # Pages send the visitor to choose a person; the MCP needs its secret.
  defp turned_away?(conn) do
    case {conn.status, conn.path_info} do
      {404, ["mcp" | _rest]} -> conn.resp_body == "Not Found\n"
      {302, _path} -> conn |> get_resp_header("location") |> hd() |> String.starts_with?("/who")
      _other -> false
    end
  end

  test "the public routes exist" do
    routes = for route <- ZipfelkasseWeb.Router.__routes__(), do: {route.verb, route.path}
    for route <- @public, do: assert(route in routes)
  end

  test "the person choice comes back to the page asked for" do
    conn = get(build_conn(), "/export/expenses.csv?from=2026-09-01")
    assert redirected_to(conn) == "/who?return_to=%2Fexport%2Fexpenses.csv%3Ffrom%3D2026-09-01"
    assert redirected_to(get(build_conn(), "/")) == "/who"
    assert redirected_to(get(build_conn(), "/balances")) == "/who?return_to=%2Fbalances"
  end

  test "an unknown or archived person counts as nobody" do
    {:ok, person} = Zipfelkasse.Participants.create_participant(nil, %{name: "Anna"})
    {:ok, _archived} = Zipfelkasse.Participants.archive_participant(nil, person)

    for id <- [person.id, 999, "1"] do
      conn = build_conn() |> init_test_session(participant_id: id) |> get("/balances")
      assert redirected_to(conn) =~ "/who"
    end
  end
end
