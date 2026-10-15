defmodule ZipfelkasseWeb.MCPPlugTest do
  use ZipfelkasseWeb.MCPCase

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Zipfelkasse.Participants

  @meta %{
    "io.modelcontextprotocol/serverInfo" => %{
      "name" => "zipfelkasse",
      "title" => "Zipfelkasse – shared expenses",
      "version" => to_string(Application.spec(:zipfelkasse, :vsn))
    }
  }

  defp json_error(conn, status, code, message) do
    assert conn.status == status
    assert get_resp_header(conn, "content-type") == ["application/json"]
    assert json(conn)["jsonrpc"] == "2.0"
    assert error(conn) == {code, message}
    json(conn)
  end

  defp plain(conn, status, body) do
    assert {conn.status, conn.resp_body} == {status, body}
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  # Objects as lists of key-value pairs in the order of the text.
  defp ordered_json(text) do
    {value, :ok, ""} =
      :json.decode(text, :ok, %{object_finish: fn pairs, acc -> {Enum.reverse(pairs), acc} end})

    value
  end

  defp request(method, opts \\ []) do
    build_conn()
    |> then(
      &Enum.reduce(Keyword.get(opts, :headers, []), &1, fn {k, v}, c ->
        put_req_header(c, k, v)
      end)
    )
    |> dispatch(@endpoint, method, Keyword.get(opts, :path, path()), nil)
  end

  describe "server/discover" do
    test "explains the server and its data, cached until midnight at most" do
      conn = rpc("server/discover", %{}, id: "0")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json"]
      assert get_resp_header(conn, "mcp-session-id") == []
      assert json(conn)["id"] == "0"
      result = result(conn)

      assert Map.keys(result) |> Enum.sort() ==
               ~w(_meta cacheScope capabilities instructions resultType supportedVersions ttlMs)

      assert %{
               "_meta" => @meta,
               "cacheScope" => "public",
               "capabilities" => %{"tools" => %{"listChanged" => false}},
               "resultType" => "complete",
               "supportedVersions" => ["2026-07-28"]
             } = result

      assert result["ttlMs"] <= 3_600_000

      assert result["instructions"] =~
               "\nToday is #{Zipfelkasse.LocalTime.today().year}"

      assert String.ends_with?(
               result["instructions"],
               "\nData overview: there are no expenses yet."
             )

      {:ok, _anna} = Participants.join(%{name: "Anna"})

      assert String.ends_with?(
               result(rpc("server/discover"))["instructions"],
               "there are no expenses yet. Values of activities.action: settings_updated."
             )
    end

    test "is cached for an hour, or until local midnight" do
      midnight = NaiveDateTime.new!(Date.add(Zipfelkasse.LocalTime.today(), 1), ~T[00:00:00])

      half_an_hour_before =
        midnight |> Zipfelkasse.LocalTime.to_utc() |> DateTime.add(-30, :minute)

      assert Zipfelkasse.MCP.discover_ttl(half_an_hour_before) == 1_800_000

      assert Zipfelkasse.MCP.discover_ttl(DateTime.add(half_an_hour_before, -2, :hour)) ==
               3_600_000
    end
  end

  test "notifications and answers of the client need neither _meta nor headers and get 202" do
    for body <- [
          message("notifications/cancelled", %{"requestId" => "a-0"}, id: :none, version: nil),
          ~s({"jsonrpc":"2.0","id":5,"result":{}}),
          ~s({"jsonrpc":"2.0","id":5,"error":{"code":-1,"message":"x"}}),
          ~s({"jsonrpc":"2.0","id":5,"result":null})
        ] do
      conn = post_mcp(body)
      assert {conn.status, conn.resp_body} == {202, ""}
      assert get_resp_header(conn, "content-type") == []
    end

    conn = rpc("tools/list", %{}, id: :none)
    assert {conn.status, conn.resp_body} == {202, ""}
  end

  test "tools/list names the tools with strict schemas and annotations" do
    result = result(rpc("tools/list"))

    assert {result["ttlMs"], result["cacheScope"], result["resultType"], result["_meta"]} ==
             {3_600_000, "public", "complete", @meta}

    tools = result["tools"]

    assert Enum.map(tools, & &1["name"]) ==
             ~w(balances balance_history search_expenses statistics activity schema sql_query create_expense create_reimbursement)

    assert Enum.map(tools, & &1["title"]) == [
             "Balances and settlement",
             "Balance history",
             "Search expenses",
             "Statistics",
             "Activity log",
             "Database schema",
             "SQL query",
             "Create expense",
             "Create reimbursement"
           ]

    for tool <- tools do
      write? = tool["name"] in ~w(create_expense create_reimbursement)
      assert Enum.sort(Map.keys(tool)) == ~w(annotations description inputSchema name title)

      assert tool["annotations"] == %{
               "readOnlyHint" => not write?,
               "destructiveHint" => false,
               "idempotentHint" => not write?,
               "openWorldHint" => false
             }

      assert {tool["inputSchema"]["type"], tool["inputSchema"]["additionalProperties"]} ==
               {"object", false}
    end

    tool = fn name -> Enum.find(tools, &(&1["name"] == name)) end

    in_order = ordered_json(rpc("tools/list").resp_body)
    get = &(&1 |> List.keyfind(&2, 0) |> elem(1))

    properties = fn name ->
      in_order
      |> get.("result")
      |> get.("tools")
      |> Enum.find(&(get.(&1, "name") == name))
      |> get.("inputSchema")
      |> get.("properties")
      |> Enum.map(&elem(&1, 0))
    end

    for {name, props, required} <- [
          {"balances", [], nil},
          {"balance_history", ~w(interval from to person), nil},
          {"search_expenses",
           ~w(from to category person paid_by involved text min_amount max_amount reimbursements sort detail limit),
           nil},
          {"statistics", ~w(group_by from to share_of category text compare limit), ["group_by"]},
          {"activity", ~w(from to person action expense_id before_id limit), nil},
          {"schema", [], nil},
          {"sql_query", ["query"], ["query"]},
          {"create_expense",
           ~w(title amount currency fx_rate date paid_by category split participants weights notes allow_duplicate),
           ~w(title amount paid_by)},
          {"create_reimbursement", ~w(from to amount currency fx_rate date notes allow_duplicate),
           ~w(from to amount)}
        ] do
      assert {name, properties.(name), tool.(name)["inputSchema"]["required"]} ==
               {name, props, required}
    end

    choices = fn name, prop -> tool.(name)["inputSchema"]["properties"][prop]["enum"] end
    assert choices.("balance_history", "interval") == ~w(year month week)
    assert choices.("search_expenses", "reimbursements") == ~w(exclude include only)
    assert choices.("search_expenses", "sort") == ~w(date_desc date_asc amount_desc amount_asc)
    assert choices.("search_expenses", "detail") == ~w(compact full)

    assert choices.("statistics", "group_by") ==
             ~w(category title year month week person category_month)

    assert choices.("statistics", "compare") == ~w(previous_year)
    assert choices.("create_expense", "split") == ~w(equal shares percent amount)

    for name <- ~w(search_expenses statistics activity) do
      assert %{"type" => "integer", "minimum" => 1, "maximum" => 500} =
               tool.(name)["inputSchema"]["properties"]["limit"]
    end

    assert tool.("create_expense")["inputSchema"]["properties"]["amount"]["type"] == [
             "string",
             "number"
           ]

    assert tool.("search_expenses")["inputSchema"]["properties"]["text"]["anyOf"] ==
             [%{"type" => "string"}, %{"items" => %{"type" => "string"}, "type" => "array"}]

    assert tool.("balances")["description"] =~
             "Includes all non-deleted expenses and reimbursements."

    assert tool.("sql_query")["description"] =~
             "reimbursements (reimbursement = 1) are not expenses"
  end

  describe "the protocol" do
    test "ping answers an empty result" do
      assert result(rpc("ping")) == %{"_meta" => @meta, "resultType" => "complete"}
    end

    test "only version 2026-07-28 is spoken" do
      body =
        json_error(
          post_mcp(message("ping", %{}, id: "3", version: nil)),
          400,
          -32_022,
          "Unsupported protocol version."
        )

      assert body["id"] == "3"
      assert body["error"]["data"] == %{"supported" => ["2026-07-28"], "requested" => nil}

      for version <- ~w(2025-11-25 2025-06-18 2099-01-01) do
        body =
          json_error(
            rpc("ping", %{}, id: "a-1", version: version),
            400,
            -32_022,
            "Unsupported protocol version."
          )

        assert body["error"]["data"] == %{"supported" => ["2026-07-28"], "requested" => version}
      end

      json_error(
        rpc("initialize", %{"protocolVersion" => "2025-06-18"}),
        404,
        -32_601,
        "Unknown method: initialize"
      )
    end

    test "unknown methods and tools" do
      assert json_error(
               rpc("resources/list", %{}, id: 4),
               404,
               -32_601,
               "Unknown method: resources/list"
             )["id"] == 4

      assert json_error(call_tool("nope"), 200, -32_602, "Unknown tool: nope")["id"] == 1
      json_error(call_tool("Balances"), 200, -32_602, "Unknown tool: Balances")

      conn =
        post_mcp(message("tools/call", %{"arguments" => %{}}),
          headers: [{"content-type", "application/json"} | protocol_headers("tools/call")]
        )

      json_error(conn, 400, -32_020, "Header mismatch: header Mcp-Name is missing.")
    end

    test "missing or null arguments count as {}; a refused call is a result as well" do
      expected = ok("balances")
      assert text(call_tool("balances", :none)) |> JSON.decode!() == expected
      assert text(call_tool("balances", nil)) |> JSON.decode!() == expected
      assert expected["balances"] == [] and expected["settlements"] == []

      conn = call_tool("sql_query", %{"query" => "DELETE FROM expenses"})
      assert String.starts_with?(text(conn, true), "SQL error: ")
      assert {result(conn)["resultType"], result(conn)["_meta"]} == {"complete", @meta}
      refute text(call_tool("balances", []), true) =~ "Internal error"
    end

    test "the headers must match the body, Mcp-Name also in Base64" do
      call = message("tools/call", %{"name" => "balances"})
      b64 = "=?base64?" <> Base.encode64("balances") <> "?="

      for name <- [b64, String.replace(b64, "=?=", "?="), "balances"] do
        conn =
          post_mcp(call,
            headers: [{"content-type", "application/json"} | protocol_headers("tools/call", name)]
          )

        assert text(conn) =~ "Positive"
      end

      mismatch = fn body, headers, message ->
        conn = post_mcp(body, headers: [{"content-type", "application/json"} | headers])
        assert json_error(conn, 400, -32_020, message)["id"] == 1
      end

      ping = message("ping")

      mismatch.(
        ping,
        [{"mcp-method", "ping"}],
        "Header mismatch: header MCP-Protocol-Version is missing."
      )

      mismatch.(
        ping,
        [{"mcp-protocol-version", "x"}, {"mcp-method", "ping"}],
        ~s(Header mismatch: MCP-Protocol-Version "x" does not match _meta "2026-07-28".)
      )

      mismatch.(
        ping,
        [{"mcp-protocol-version", "2026-07-28"}],
        "Header mismatch: header Mcp-Method is missing."
      )

      mismatch.(
        ping,
        protocol_headers("tools/list"),
        ~s(Header mismatch: Mcp-Method "tools/list" does not match method "ping".)
      )

      mismatch.(
        call,
        protocol_headers("tools/call", "schema"),
        ~s(Header mismatch: Mcp-Name "schema" does not match params.name "balances".)
      )

      mismatch.(
        call,
        protocol_headers("tools/call", "=?base64?" <> Base.encode64("schema") <> "?="),
        ~s(Header mismatch: Mcp-Name "schema" does not match params.name "balances".)
      )

      mismatch.(
        call,
        protocol_headers("tools/call", "=?base64?!!!?="),
        "Header mismatch: Mcp-Name is not valid Base64."
      )

      conn =
        post_mcp(ping,
          headers: [
            {"content-type", "application/json"},
            {"mcp-protocol-version", " 2026-07-28 "},
            {"mcp-method", "\tping "}
          ]
        )

      assert conn.status == 200
    end

    test "malformed messages" do
      assert json_error(
               post_mcp(~s({"id":1,"method":"ping"})),
               400,
               -32_600,
               ~s(jsonrpc must be "2.0".)
             )["id"] == 1

      json_error(
        post_mcp(~s({"jsonrpc":"1.0","id":1,"method":"ping"})),
        400,
        -32_600,
        ~s(jsonrpc must be "2.0".)
      )

      assert json_error(
               post_mcp(~s({"jsonrpc":"2.0","id":7})),
               400,
               -32_600,
               "Field method is missing."
             )["id"] == 7

      refute Map.has_key?(
               json_error(
                 post_mcp(~s({"jsonrpc":"2.0"})),
                 400,
                 -32_600,
                 "Field method is missing."
               ),
               "id"
             )

      json_error(
        post_mcp(~s({"jsonrpc":"2.0","id":1,"method":""})),
        400,
        -32_600,
        "Field method is missing."
      )

      json_error(
        post_mcp(~s({"jsonrpc":"2.0","id":7,"Method":"ping"})),
        400,
        -32_600,
        "Field method is missing."
      )

      json_error(
        post_mcp(~s([{"jsonrpc":"2.0","id":1,"method":"ping"}])),
        400,
        -32_600,
        "JSON-RPC batches are not supported."
      )

      refute Map.has_key?(
               json_error(
                 post_mcp("  \n []"),
                 400,
                 -32_600,
                 "JSON-RPC batches are not supported."
               ),
               "id"
             )

      for version <- [7, ""] do
        body =
          ~s|{"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":#{JSON.encode!(version)}}}}|

        json_error(
          post_mcp(body),
          400,
          -32_602,
          "_meta.io.modelcontextprotocol/protocolVersion must be a non-empty string."
        )
      end

      for body <- [
            ~s({broken),
            "",
            "null",
            ~s({"jsonrpc":"2.0","id":1,"method":"ping"} x),
            ~s({"jsonrpc":"2.0","id":1,"method":5})
          ] do
        conn = post_mcp(body)
        assert conn.status == 400
        assert {-32_700, "Invalid JSON" <> _detail} = error(conn)
        refute Map.has_key?(json(conn), "id")
      end

      for params <- [[1], "x", %{"name" => 5}] do
        conn =
          post_mcp(
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => 1,
              "method" => "tools/call",
              "params" => params
            })
          )

        assert conn.status == 400
        assert {-32_602, "Invalid params" <> _detail} = error(conn)
        assert json(conn)["id"] == 1
      end
    end

    test "ids are echoed, null too; only a missing id makes a notification" do
      for id <- [0, -3, 9_007_199_254_740_993, "abc", "", ~s(ä "x")] do
        assert json(rpc("ping", %{}, id: id))["id"] === id
      end

      assert rpc("ping", %{}, id: 9_007_199_254_740_993).resp_body =~ ~s("id":9007199254740993)
      conn = rpc("tools/list", %{}, id: nil)
      assert conn.status == 200
      assert Map.has_key?(json(conn), "id") and json(conn)["id"] == nil
      assert length(result(conn)["tools"]) == 9
    end
  end

  describe "the transport" do
    test "takes JSON only, up to 1 MiB" do
      ping = message("ping")
      headers = &[{"content-type", &1} | protocol_headers("ping")]

      for type <- [
            "application/json; charset=utf-8",
            "Application/JSON",
            "application/json;charset=UTF-8"
          ],
          do: assert(post_mcp(ping, headers: headers.(type)).status == 200)

      for type <- [
            "text/plain",
            "application/x-www-form-urlencoded",
            "application/jsonx",
            "application/json-rpc"
          ] do
        body =
          json_error(
            post_mcp(ping, headers: headers.(type)),
            415,
            -32_600,
            "Content-Type must be application/json."
          )

        refute Map.has_key?(body, "id")
      end

      json_error(
        post_mcp(ping, headers: protocol_headers("ping")),
        415,
        -32_600,
        "Content-Type must be application/json."
      )

      exact = ping <> String.duplicate(" ", 1_048_576 - byte_size(ping))
      assert post_mcp(exact, headers: headers.("application/json")).status == 200

      json_error(
        post_mcp(exact <> " ", headers: headers.("application/json")),
        413,
        -32_600,
        "Message too large."
      )

      json_error(
        post_mcp(exact <> " ", headers: headers.("text/plain")),
        415,
        -32_600,
        "Content-Type must be application/json."
      )
    end

    test "answers POST only, with the right secret before any other check" do
      for method <- ~w(GET PUT DELETE PATCH OPTIONS HEAD) do
        conn = request(method, headers: [{"origin", "https://evil.example"}])
        assert {conn.status, get_resp_header(conn, "allow")} == {405, ["POST"]}
      end

      plain(request("GET"), 405, "Method Not Allowed\n")
    end

    test "refuses any browser, before the content type" do
      for origin <- ["https://claude.ai", "null", "http://127.0.0.1"] do
        json_error(
          post_mcp(message("ping"),
            headers: [{"origin", origin}, {"content-type", "application/json"}]
          ),
          403,
          -32_000,
          "Access from a browser is not allowed."
        )
      end

      json_error(
        post_mcp(message("ping"), headers: [{"origin", "x"}, {"content-type", "text/plain"}]),
        403,
        -32_000,
        "Access from a browser is not allowed."
      )
    end

    test "a wrong secret is a plain 404 that does not give the MCP away" do
      for path <- [
            "/mcp/wrong",
            "/mcp/test-secre",
            "/mcp/test-secret2",
            "/mcp/TEST-SECRET",
            "/mcp/test-secret/tools",
            "/mcp/test-secret/",
            "/mcp/",
            "/mcp"
          ] do
        plain(post_mcp(message("ping"), path: path), 404, "Not Found\n")

        for method <- ~w(GET HEAD PUT DELETE OPTIONS) do
          conn = request(method, path: path)
          assert {conn.status, get_resp_header(conn, "allow")} == {404, []}
        end
      end

      plain(
        post_mcp(message("ping"), path: "/mcp/wrong", headers: [{"origin", "https://claude.ai"}]),
        404,
        "Not Found\n"
      )
    end

    test "without a secret there is no MCP endpoint" do
      configure_mcp(secret: nil, allowed_cidrs: "127.0.0.1/32")

      for path <- ["/mcp/test-secret", "/mcp/", "/mcp/x"] do
        plain(post_mcp(message("ping"), path: path), 404, "Not Found\n")
        plain(request("GET", path: path), 404, "Not Found\n")
      end
    end

    test "is outside the web app: no person, no CSRF check, no session cookie" do
      conn =
        rpc("ping", %{},
          extra: [{"cookie", "_zipfelkasse_key=broken"}, {"sec-fetch-site", "cross-site"}]
        )

      assert conn.status == 200
      assert get_resp_header(conn, "set-cookie") == []
    end
  end

  describe "access by client address" do
    test "takes the address of the connection without a trusted proxy" do
      configure_mcp(allowed_cidrs: "10.0.0.0/8")
      not_allowed = "Access from this address is not allowed."

      refute Map.has_key?(json_error(rpc("ping"), 403, -32_000, not_allowed), "id")

      json_error(
        rpc("ping", %{}, extra: [{"x-forwarded-for", "10.1.2.3"}]),
        403,
        -32_000,
        not_allowed
      )

      json_error(rpc("ping", %{}, extra: [{"x-real-ip", "10.1.2.3"}]), 403, -32_000, not_allowed)
      plain(post_mcp(message("ping"), path: "/mcp/wrong"), 404, "Not Found\n")
      plain(request("GET"), 405, "Method Not Allowed\n")

      json_error(
        post_mcp("{broken", headers: [{"content-type", "text/plain"}]),
        403,
        -32_000,
        not_allowed
      )

      assert rpc("ping", %{}, remote_ip: {10, 9, 9, 9}).status == 200
    end

    test "behind a trusted proxy the rightmost untrusted X-Forwarded-For hop counts" do
      configure_mcp(allowed_cidrs: "10.0.0.0/8, 192.0.2.7", trusted_proxies: "127.0.0.1 10.0.0.1")
      status = fn headers -> rpc("ping", %{}, extra: headers).status end

      assert status.([]) == 403
      assert status.([{"x-forwarded-for", "10.1.2.3"}]) == 200
      assert status.([{"x-forwarded-for", " 10.1.2.3 , "}]) == 200
      assert status.([{"x-forwarded-for", "10.1.2.3, 6.6.6.6"}]) == 403
      assert status.([{"x-forwarded-for", "garbage, 10.1.2.3"}]) == 200
      assert status.([{"x-forwarded-for", "6.6.6.6, 10.1.2.3, 10.0.0.1"}]) == 200
      assert status.([{"x-forwarded-for", "10.0.0.1, 127.0.0.1"}]) == 200
      assert status.([{"x-forwarded-for", "127.0.0.1, 10.0.0.1"}]) == 403
      assert status.([{"x-forwarded-for", "10.1.2.3:4711"}]) == 403
      assert status.([{"x-forwarded-for", "::ffff:10.1.2.3"}]) == 200
      assert status.([{"x-real-ip", "10.9.9.9"}]) == 200
      assert status.([{"x-real-ip", "garbage"}]) == 403
      assert status.([{"x-forwarded-for", "6.6.6.6"}, {"x-real-ip", "10.9.9.9"}]) == 403
    end
  end

  test "logs calls and refusals, but never the secret" do
    configure_mcp(secret: "s3cr3t-0123456789abcdef", allowed_cidrs: "160.79.104.0/21")
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
    allowed = {160, 79, 104, 10}

    log =
      capture_log([level: :info], fn ->
        assert rpc("ping", %{}, path: "/mcp/s3cr3t-0123456789abcdef", remote_ip: allowed).status ==
                 200

        assert rpc("ping", %{}, path: "/mcp/wrong", remote_ip: allowed).status == 404

        assert rpc("ping", %{}, path: "/mcp/s3cr3t-0123456789abcdef", remote_ip: {1, 2, 3, 4}).status ==
                 403

        assert rpc("ping", %{},
                 path: "/mcp/s3cr3t-0123456789abcdef",
                 remote_ip: allowed,
                 extra: [{"origin", "https://evil.example"}]
               ).status ==
                 403

        assert rpc(
                 "tools/call",
                 %{"name" => "search_expenses", "arguments" => %{"from" => "neulich"}},
                 path: "/mcp/s3cr3t-0123456789abcdef",
                 remote_ip: allowed
               ).status == 200

        assert rpc(
                 "tools/call",
                 %{
                   "name" => "sql_query",
                   "arguments" => %{"query" => String.duplicate("x", 400)}
                 },
                 path: "/mcp/s3cr3t-0123456789abcdef",
                 remote_ip: allowed
               ).status == 200

        assert rpc("tools/call", %{"name" => "nope\nMCP ip=1.1.1.1"},
                 path: "/mcp/s3cr3t-0123456789abcdef",
                 remote_ip: allowed
               ).status == 200

        assert rpc("bad\nmethod", %{},
                 path: "/mcp/s3cr3t-0123456789abcdef",
                 remote_ip: allowed
               ).status == 404
      end)

    for entry <- [
          ~s(method="ping"),
          "ip=160.79.104.10",
          "wrong secret",
          "IP not allowed",
          "Origin header rejected",
          ~s(method="tools/call" tool="search_expenses" status=200 duration=),
          ~s(method="tools/call" status=200 duration=),
          ~S(method="bad\nmethod" status=404 duration=),
          ~S|ms tool_error="Invalid date for from: \"neulich\" (expected YYYY-MM-DD)."|
        ],
        do: assert(log =~ entry)

    refute log =~ ~r/tool_error=.*x{301}/
    assert log =~ ~r/tool_error=".*x{50}…"\n/
    refute log =~ "s3cr3t-01234"
    refute log =~ "nope"
  end
end
