require "./mcp_helper"

private alias Env = MCPSpec::Env
private alias MCP = Zipfelkasse::MCP

private def with_env(location = Time::Location::UTC, &)
  MCPSpec.with_env(location) { |e| yield e }
end

private def titles(d : JSON::Any) : String
  d["expenses"].as_a.join(",", &.["title"].as_s)
end

describe "MCP access" do
  it "checks secret, address, origin, method and content type" do
    with_env do |e|
      ping = %({"jsonrpc":"2.0","id":1,"method":"ping"})
      path = MCPSpec::PATH
      [
        {"allowed", "POST", path, MCPSpec::ANTHROPIC, {} of String => String, 200},
        {"wrong secret", "POST", "/mcp/wrong", MCPSpec::ANTHROPIC, {} of String => String, 404},
        {"secret prefix", "POST", path[0...-1], MCPSpec::ANTHROPIC, {} of String => String, 404},
        {"wrong secret from foreign IP", "POST", "/mcp/wrong", "1.2.3.4:1", {} of String => String, 404},
        {"foreign IP", "POST", path, "1.2.3.4:1", {} of String => String, 403},
        {"XFF spoofing without proxy", "POST", path, "1.2.3.4:1", {"X-Forwarded-For" => "160.79.104.10"}, 403},
        {"X-Real-IP spoofing without proxy", "POST", path, "1.2.3.4:1", {"X-Real-IP" => "160.79.104.10"}, 403},
        {"allowed via proxy", "POST", path, "10.0.0.1:9", {"X-Forwarded-For" => "160.79.104.10"}, 200},
        {"via proxy, prepended forgery", "POST", path, "10.0.0.1:9", {"X-Forwarded-For" => "160.79.104.10, 1.2.3.4"}, 403},
        {"via proxy without header", "POST", path, "10.0.0.1:9", {} of String => String, 403},
        {"via proxy with X-Real-IP", "POST", path, "10.0.0.1:9", {"X-Real-IP" => "160.79.104.10"}, 200},
        {"Origin set", "POST", path, MCPSpec::ANTHROPIC, {"Origin" => "https://evil.example"}, 403},
        {"Origin null", "POST", path, MCPSpec::ANTHROPIC, {"Origin" => "null"}, 403},
        {"GET", "GET", path, MCPSpec::ANTHROPIC, {} of String => String, 405},
        {"DELETE", "DELETE", path, MCPSpec::ANTHROPIC, {} of String => String, 405},
        {"wrong Content-Type", "POST", path, MCPSpec::ANTHROPIC, {"Content-Type" => "text/plain"}, 415},
      ].each do |name, method, p, remote, headers, want|
        r = e.send(method, p, ping, headers, remote)
        {name, r.status}.should eq({name, want})
        r.body.should_not contain("mcp") if want == 404
      end
      e.send("GET", path).headers["Allow"]?.should eq "POST"
      # The secret never shows up in the log, but accesses do.
      e.logs.should_not contain(MCPSpec::SECRET[0, 10])
      ["method=ping", "ip=160.79.104.10", "wrong secret", "IP not allowed", "Origin header rejected"].each do |want|
        e.logs.should contain(want)
      end
    end
  end

  it "is disabled without a secret" do
    with_server do |srv|
      r = srv.request("POST", "/mcp/", %({"jsonrpc":"2.0","id":1,"method":"ping"}), HTTP::Headers{"Content-Type" => "application/json"})
      r.status_code.should eq 404
      r.body.should eq "404 page not found\n"
      srv.log_io.to_s.should contain("MCP disabled")
    end
  end

  it "is mounted by the app with a secret" do
    config = Zipfelkasse::Config.from_env({"MCP_SECRET" => MCPSpec::SECRET, "MCP_ALLOWED_CIDRS" => "0.0.0.0/0"})
    with_server(config) do |srv|
      r = srv.request("POST", MCPSpec::PATH, %({"jsonrpc":"2.0","id":1,"method":"ping"}), HTTP::Headers{"Content-Type" => "application/json"})
      r.status_code.should eq 403 # no client address in memory: fails closed
      r.headers["X-Frame-Options"].should eq "DENY"
      srv.request("POST", "/mcp/x/y").body.should eq "404 page not found\n"
      srv.log_io.to_s.should contain(%(msg="MCP enabled" path=/mcp/*** allowed=[0.0.0.0/0] proxies=[]))
    end
  end
end

describe "MCP protocol" do
  it "speaks the legacy protocol" do
    with_env do |e|
      r = e.post(%({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-ai","version":"0.1.0"}}}))
      res = r.result
      res["protocolVersion"].should eq "2025-06-18"
      r.headers["Mcp-Session-Id"]?.should be_nil
      r.headers["Content-Type"].should eq "application/json"
      r.body.should end_with("}\n")
      res["capabilities"]["tools"].should eq JSON.parse(%({"listChanged":false}))
      res["serverInfo"]["name"].should eq "zipfelkasse"
      res["instructions"].as_s.should contain("Balance")
      res.as_h.has_key?("resultType").should be_false
      # Unknown version → newest legacy version.
      e.post(%({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05"}})).result["protocolVersion"].should eq "2025-11-25"
      # notifications/initialized → 202 without body.
      r = e.post(%({"jsonrpc":"2.0","method":"notifications/initialized"}), {"MCP-Protocol-Version" => "2025-06-18"})
      {r.status, r.body, r.headers["Content-Type"]?}.should eq({202, "", nil})

      tools = e.legacy("tools/list").result["tools"].as_a
      tools.map(&.["name"].as_s).should eq %w(balances balance_history search_expenses statistics activity schema sql_query create_expense create_reimbursement)
      tools.each do |t|
        writes = t["name"].as_s.starts_with?("create_")
        t["description"].as_s.should_not be_empty
        t["inputSchema"]["type"].should eq "object"
        t["annotations"].should eq JSON.parse({readOnlyHint: !writes, destructiveHint: false, idempotentHint: !writes, openWorldHint: false}.to_json)
      end
      r = e.post(%({"jsonrpc":"2.0","id":2,"method":"tools/list"}))
      {r.status, r.result["tools"].as_a.size}.should eq({200, 9})
      # Unsupported version in the header → 400 with the list.
      r = e.post(%({"jsonrpc":"2.0","id":3,"method":"tools/list"}), {"MCP-Protocol-Version" => "1999-01-01"})
      {r.status, r.error_code}.should eq({400, MCP::CODE_UNSUPPORTED_VERSION})
      r.json["error"]["data"].should eq JSON.parse(%({"requested":"1999-01-01","supported":["2026-07-28","2025-11-25","2025-06-18","2025-03-26"]}))
      e.legacy("ping").result.should eq JSON.parse("{}")
      e.legacy("resources/list").error_code.should eq MCP::CODE_METHOD_NOT_FOUND
      # An unknown tool is a protocol error.
      r = e.legacy("tools/call", %({"name":"doesnotexist"}))
      {r.status, r.error_code, r.json["error"]["message"]}.should eq({200, MCP::CODE_INVALID_PARAMS, "Unknown tool: doesnotexist"})
    end
  end

  it "puts today's date of the server time zone into instructions and schema" do
    with_env(Time::Location.fixed("Test/Zone", 2 * 3600)) do |e|
      now = Time.utc(2026, 10, 2, 21, 30) # 23:30 local time
      e.server.clock = -> { now }
      friday = "Today is 2026-10-02 (Friday), server time zone Test/Zone."
      e.post(%({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}})).result["instructions"].as_s.should contain(friday)
      res = e.modern("server/discover").result
      res["instructions"].as_s.should contain(friday)
      res["ttlMs"].should eq 30 * 60 * 1000
      now += 1.hour # 00:30 local time, next day
      e.call("schema")[1].should contain("Today is 2026-10-03 (Saturday), server time zone Test/Zone.")
      e.modern("server/discover").result["ttlMs"].should eq 3_600_000
    end
  end

  it "speaks the modern protocol" do
    with_env do |e|
      r = e.modern("server/discover")
      res = r.result
      {r.status, res["resultType"], res["cacheScope"]}.should eq({200, "complete", "public"})
      res["ttlMs"].as_i.should be > 0
      res["supportedVersions"].as_a.map(&.as_s).should eq MCP::ALL_VERSIONS
      res["_meta"]["io.modelcontextprotocol/serverInfo"]["name"].should eq "zipfelkasse"
      res = e.modern("tools/list").result
      {res["resultType"], res["ttlMs"], res["tools"].as_a.size}.should eq({"complete", 3_600_000, 9})
      res = e.modern("tools/call", %({"name":"balances","arguments":{}})).result
      {res["resultType"], res["isError"], res["structuredContent"]?}.should eq({"complete", false, nil})
      res["content"][0]["text"].as_s.should start_with(%({"balances":))
      # Mcp-Name in Base64 format.
      r = e.modern("tools/call", %({"name":"balances"}), {"Mcp-Name" => "=?base64?YmFsYW5jZXM=?="})
      {r.status, r.result["isError"]}.should eq({200, false})

      [
        {"version header missing", "tools/list", "{}", {"MCP-Protocol-Version" => ""}, 400, MCP::CODE_HEADER_MISMATCH},
        {"version header wrong", "tools/list", "{}", {"MCP-Protocol-Version" => "2025-11-25"}, 400, MCP::CODE_HEADER_MISMATCH},
        {"Mcp-Method missing", "tools/list", "{}", {"Mcp-Method" => ""}, 400, MCP::CODE_HEADER_MISMATCH},
        {"Mcp-Method wrong", "tools/list", "{}", {"Mcp-Method" => "tools/call"}, 400, MCP::CODE_HEADER_MISMATCH},
        {"Mcp-Name missing", "tools/call", %({"name":"balances"}), {"Mcp-Name" => ""}, 400, MCP::CODE_HEADER_MISMATCH},
        {"Mcp-Name wrong", "tools/call", %({"name":"balances"}), {"Mcp-Name" => "schema"}, 400, MCP::CODE_HEADER_MISMATCH},
        {"Mcp-Name Base64 wrong", "tools/call", %({"name":"balances"}), {"Mcp-Name" => "=?base64?c2NoZW1h?="}, 400, MCP::CODE_HEADER_MISMATCH},
        {"Mcp-Name Base64 broken", "tools/call", %({"name":"balances"}), {"Mcp-Name" => "=?base64?***?="}, 400, MCP::CODE_HEADER_MISMATCH},
        {"unknown method", "resources/list", "{}", {} of String => String, 404, MCP::CODE_METHOD_NOT_FOUND},
        {"initialize modern", "initialize", "{}", {} of String => String, 404, MCP::CODE_METHOD_NOT_FOUND},
        {"unknown tool", "tools/call", %({"name":"nothing"}), {} of String => String, 200, MCP::CODE_INVALID_PARAMS},
      ].each do |name, method, params, headers, status, code|
        r = e.modern(method, params, headers)
        {name, r.status, r.error_code, r.json["id"]}.should eq({name, status, code, "a-1"})
      end

      # Unsupported modern version: 400 with supported/requested.
      r = e.modern("tools/list", %({"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01"}}), {"MCP-Protocol-Version" => "2099-01-01"})
      {r.status, r.error_code}.should eq({400, MCP::CODE_UNSUPPORTED_VERSION})
      r.json["error"]["data"]["requested"].should eq "2099-01-01"
      r.json["error"]["data"]["supported"][0].should eq MCPSpec::MODERN
      # Modern header, but no _meta in the body.
      r = e.post(%({"jsonrpc":"2.0","id":1,"method":"tools/list"}), {"MCP-Protocol-Version" => MCPSpec::MODERN, "Mcp-Method" => "tools/list"})
      {r.status, r.error_code}.should eq({400, MCP::CODE_HEADER_MISMATCH})
      r.json["error"]["message"].should eq %(Header MCP-Protocol-Version is 2026-07-28, but params._meta["io.modelcontextprotocol/protocolVersion"] is missing.)
      # Notification → 202.
      r = e.post(%({"jsonrpc":"2.0","method":"notifications/whatever","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}),
        {"MCP-Protocol-Version" => MCPSpec::MODERN})
      {r.status, r.body}.should eq({202, ""})
    end
  end

  it "rejects malformed messages" do
    with_env do |e|
      [
        {400, MCP::CODE_PARSE_ERROR, %({broken)},
        {400, MCP::CODE_INVALID_REQUEST, %([{"jsonrpc":"2.0","id":1,"method":"ping"}])},
        {400, MCP::CODE_INVALID_REQUEST, %({"id":1,"method":"ping"})},
        {400, MCP::CODE_INVALID_REQUEST, %({"jsonrpc":"2.0","id":1})},
        {400, MCP::CODE_INVALID_PARAMS, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":[1]})},
        {400, MCP::CODE_INVALID_PARAMS, %({"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":7}}})},
        {400, MCP::CODE_PARSE_ERROR, %({"jsonrpc":"2.0","id":1,"method":5})},
        {400, MCP::CODE_PARSE_ERROR, %({"jsonrpc":"2.0","id":1,"method":"ping"} x)},
        {400, MCP::CODE_PARSE_ERROR, ""},
        {202, nil, %({"jsonrpc":"2.0","id":1,"result":{}})},
        {202, nil, %({"jsonrpc":"2.0","id":1,"result":null})},
      ].each do |status, code, body|
        r = e.post(body)
        {body, r.status, status == 202 ? nil : r.error_code}.should eq({body, status, code})
      end
      r = e.post(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":5}}))
      r.json["error"]["message"].should eq "Invalid params: json: cannot unmarshal number into Go struct field params.name of type string"
      big = %({"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":") + "a" * MCP::MAX_BODY + %("}})
      e.post(big).status.should eq 413
    end
  end

  it "echoes ids verbatim and matches keys case-insensitively" do
    with_env do |e|
      e.post(%({"jsonrpc":"2.0","id":1.50,"method":"ping"})).body.should eq %({"jsonrpc":"2.0","id":1.50,"result":{}}\n)
      e.post(%({"jsonrpc":"2.0","id":null,"method":"ping"})).body.should eq %({"jsonrpc":"2.0","id":null,"result":{}}\n)
      e.post(%({"jsonrpc":"2.0","id":{"a": 1},"method":"ping"})).body.should eq %({"jsonrpc":"2.0","id":{"a":1},"result":{}}\n)
      e.post(%({"JSONRPC":"2.0","ID":7,"Method":"ping"})).body.should eq %({"jsonrpc":"2.0","id":7,"result":{}}\n)
      e.ok("search_expenses", %({"LIMIT":2,"limit":3})).should eq JSON.parse(%({"expenses":[],"matches":0,"shown":0,"total":"0.00","total_cents":0,"truncated":false}))
    end
  end
end

describe "MCP tools" do
  it "finds umlauts case-insensitively" do
    with_env do |e|
      e.expense("Bäckerei", 300, "2026-09-01", "Anna", "Lebensmittel", "Anna", "Ben")
      e.expense("ÖLWECHSEL", 9000, "2026-09-02", "Ben", "", "Anna", "Ben")
      {"BÄCKEREI" => "Bäckerei", "bäcker" => "Bäckerei", "ölwechsel" => "ÖLWECHSEL", "Ölwechsel" => "ÖLWECHSEL"}.each do |text, want|
        d = e.ok("search_expenses", {text: text}.to_json)
        {d["matches"], titles(d)}.should eq({1, want})
      end
    end
  end

  it "selects expenses without a category with none" do
    with_env do |e|
      e.expense("Tanken", 5000, "2026-09-01", "Anna", "", "Anna", "Ben")
      e.expense("Rewe", 3000, "2026-09-02", "Ben", "Lebensmittel", "Anna", "Ben")
      e.expense("Pizza", 2000, "2026-09-03", "Ben", "Restaurant", "Ben")
      ["none", "No category", "NONE"].each do |cat|
        d = e.ok("search_expenses", {category: cat}.to_json)
        {cat, d["matches"], titles(d)}.should eq({cat, 1, "Tanken"})
      end
      d = e.ok("statistics", %({"group_by":"category","category":"none"}))
      {d["rows"].as_a.size, d["rows"][0]["category"], d["total_cents"]}.should eq({1, "No category", 5000})
      d = e.ok("statistics", %({"group_by":"person","category":"lebensmittel"}))
      {d["rows"].as_a.size, d["total_cents"]}.should eq({2, 3000})
      e.fail("statistics", %({"group_by":"month","category":"Yacht"})).should contain("Yacht")
    end
  end

  it "prefers a real category named None" do
    with_env do |e|
      e.cats["None"] = e.store.create_category(0_i64, "None")
      e.expense("Tanken", 5000, "2026-09-01", "Anna", "", "Anna", "Ben")
      e.expense("Kram", 1000, "2026-09-02", "Anna", "None", "Anna", "Ben")
      d = e.ok("search_expenses", %({"category":"none"}))
      {d["matches"], titles(d)}.should eq({1, "Kram"})
    end
  end

  it "formats amounts" do
    MCP.eur(-300000).should eq "-3000.00"
    MCP.money(2340, "usd").should eq "23.40 USD"
    MCP.money(1500, "JPY").should eq "1500 JPY"
  end

  it "formats floats" do
    {1.0, 160.0, -100.0, -0.0, 1.17, 16.7, 0.30000000000000004, 1e30, Float64::INFINITY, -Float64::INFINITY}.map do |f|
      JSON.build { |j| MCP.float(j, f) }
    end.to_a.should eq ["1", "160", "-100", "0", "1.17", "16.7", "0.30000000000000004", "1e+30", "9.0e+999", "-9.0e+999"]
  end

  it "answers every read tool" do
    with_env do |e|
      e.expense("Rewe", 3000, "2026-08-15", "Anna", "Lebensmittel", "Anna", "Ben", "Cleo")
      e.expense("Pizza & Wein", 4000, "2026-09-10", "Cleo", "Restaurant", "Ben", "Cleo")
      e.expense("Edeka", 1000, "2026-09-01", "Ben", "Lebensmittel", "Anna", "Ben")
      e.store.create_expense(e.ids["Anna"], Zipfelkasse::Store::ExpenseInput.new(title: "Diner NYC", date: Zipfelkasse::Domain.parse_date("2026-09-20"),
        paid_by: e.ids["Anna"], amount_cents: 2000, original_amount_minor: 2340, original_currency: "USD", fx_rate: 1.17, fx_source: "ezb",
        category_id: e.cats["Restaurant"], parts: [Zipfelkasse::Domain::Part.new(e.ids["Anna"]), Zipfelkasse::Domain::Part.new(e.ids["Ben"])]))
      e.reimbursement(500, "2026-09-20", "Ben", "Anna")

      # balances: Anna paid 5000, shares 2500, received a reimbursement of 500 → +2000
      d, text, _ = e.call("balances")
      d = d.not_nil!
      d["balances"].as_a.to_h { |b| {b["person"].as_s, {b["balance_cents"].as_i, b["status"].as_s}} }.should eq({
        "Anna" => {2000, "is owed money"}, "Ben" => {-3000, "owes money"}, "Cleo" => {1000, "is owed money"},
      })
      text.should contain(%("balance":"-30.00"))
      text.should contain(%("from":"Ben"))
      text.should contain(%("settlements":[))

      # search_expenses
      d = e.ok("search_expenses", %({"person":"anna","from":"2026-09-01","detail":"full"}))
      {d["matches"], d["total_cents"], d["total"]}.should eq({2, 3000, "30.00"})
      d["person_share"].should eq JSON.parse(%({"amount":"15.00","amount_cents":1500,"person":"Anna"}))
      d["expenses"][0].should eq JSON.parse(%({"id":4,"date":"2026-09-20","title":"Diner NYC","category":"Restaurant","paid_by":"Anna","amount":"20.00","amount_cents":2000,"original":"23.40 USD","fx_rate":1.17,"fx_source":"ezb","split":"equal","shares":[{"person":"Anna","amount":"10.00","amount_cents":1000},{"person":"Ben","amount":"10.00","amount_cents":1000}]}))
      d = e.ok("search_expenses", %({"reimbursements":"only"}))
      {d["matches"], d["expenses"][0]["recipient"], d["expenses"][0]["reimbursement"]}.should eq({1, "Anna", true})
      e.ok("search_expenses", %({"reimbursements":"include"}))["matches"].should eq 5
      d = e.ok("search_expenses", %({"category":"lebensmittel","limit":1}))
      {d["matches"], d["shown"], d["truncated"], d["total_cents"]}.should eq({2, 1, true, 4000})
      e.call("search_expenses", %({"text":"wein"}))[1].should contain("Pizza & Wein")
      [
        %({"person":"Dora"}), %({"category":"Yacht"}), %({"from":"yesterday"}), %({"from":"2026-09-02","to":"2026-09-01"}),
        %({"limit":1000}), %({"reimbursements":"whatever"}), %({"unknown":1}), %({"limit":"ten"}), %({"von":"2026-09-01"}),
        %({"sort":"random"}), %({"detail":"all"}), %({"min_amount":-1}), %({"max_amount":0}), %({"min_amount":20,"max_amount":10}),
        %({"text":5}), %({"paid_by":"Dora"}), %({"involved":"Dora"}),
      ].each do |args|
        msg = e.fail("search_expenses", args)
        msg.should_not be_empty
        msg.should_not contain("Internal error")
      end
      e.fail("search_expenses", %({"person":"Dora"})).should eq %(Unknown person "Dora". Available: Anna, Ben, Cleo.)
      e.fail("search_expenses", %({"from":"2026-09-02","to":"2026-09-01"})).should eq %("to" (2026-09-01) is before "from" (2026-09-02).)
      e.fail("search_expenses", %({"unknown":1})).should eq %(Invalid arguments: json: unknown field "unknown")
      e.fail("search_expenses", %({"limit":"ten"})).should eq "Invalid arguments: json: cannot unmarshal string into Go struct field .limit of type int"
      e.fail("search_expenses", %({"limit":5.0})).should eq "Invalid arguments: json: cannot unmarshal number 5.0 into Go struct field .limit of type int"
      e.fail("search_expenses", %({"text":5})).should eq "Invalid arguments: must be a string or a list of strings"
      e.fail("balances", %([])).should eq "Invalid arguments: json: cannot unmarshal array into Go value of type struct {}"

      # statistics
      d = e.ok("statistics", %({"group_by":"category","share_of":"Ben"}))
      {d["rows"].as_a.size, d["rows"][0]["category"], d["rows"][0]["amount_cents"], d["total_cents"], d["total"], d["perspective"]}
        .should eq({2, "Restaurant", 3000, 4500, "45.00", "only the share of Ben"})
      d = e.ok("statistics", %({"group_by":"person"}))
      {d["rows"][0]["person"], d["rows"][0]["paid_cents"], d["rows"][0]["paid"], d["total_cents"]}.should eq({"Ben", 1000, "10.00", 10000})
      d = e.ok("statistics", %({"group_by":"month","from":"2026-09-01","to":"30.09.2026"}))
      d["rows"].should eq JSON.parse(%([{"month":"2026-09","count":3,"amount":"70.00","amount_cents":7000}]))
      d["period"].should eq "2026-09-01 to 2026-09-30"
      d = e.ok("statistics", %({"group_by":"category_month","share_of":"anna"}))
      {d["rows"].as_a.size, d["period"]}.should eq({3, "all time"})
      d["rows"][0]["month"].as_s.should_not be_empty
      d["rows"][0]["category"].as_s.should_not be_empty
      [nil, %({"group_by":"decade"}), %({"group_by":"month","person":"Anna"}), %({"group_by":"category","compare":"previous_year"}),
       %({"group_by":"month","compare":"last_week"}), %({"group_by":"month","limit":0.5}), %({"group_by":"month","share_of":"Dora"})].each do |args|
        e.fail("statistics", args).should_not contain("Internal error")
      end

      # schema
      d, text, error = e.call("schema")
      {d, error}.should eq({nil, false})
      ["deleted_at IS NULL", "CREATE TABLE expenses", ": Anna", "\nPeople (id: name): 1: Anna, 2: Ben, 3: Cleo\nCategories (id: name): 1: Lebensmittel, "].each do |want|
        text.should contain(want)
      end
      text.should_not contain("CREATE TABLE ynab")
      text.should contain("GROUP BY 1 ORDER BY 2 DESC;\n\nPeople")

      # sql_query
      d = e.ok("sql_query", %({"query":"SELECT name, archived_at FROM participants ORDER BY name"}))
      d.should eq JSON.parse(%({"columns":["name","archived_at"],"row_count":3,"rows":[["Anna",null],["Ben",null],["Cleo",null]],"truncated":false}))
      d = e.ok("sql_query", %({"query":"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 600) SELECT i FROM n"}))
      {d["truncated"], d["row_count"]}.should eq({true, 500})
      d["note"].as_s.should contain("more than")
      e.call("sql_query", %({"query":"SELECT 1.0, 1.5, 9e999, -9e999, 'a<&>'"}))[1]
        .should eq %({"columns":["1.0","1.5","9e999","-9e999","'a<&>'"],"row_count":1,"rows":[[1,1.5,9.0e+999,-9.0e+999,"a<&>"]],"truncated":false})
      ["SELECT token FROM ynab_config", "DELETE FROM expenses", "SELECT 1; DELETE FROM expenses", "SELECT * FROM doesnotexist", ""].each do |q|
        e.fail("sql_query", {query: q}.to_json).should_not contain("Internal error")
      end
      e.fail("sql_query", %({"query":"SELECT * FROM doesnotexist"})).should eq "SQL error: no such table: doesnotexist (1)"
      e.store.list_expenses.size.should eq 5
      e.logs.should contain("tool=sql_query")
    end
  end

  it "filters and sorts search_expenses" do
    with_env do |e|
      e.expense("Rewe", 3000, "2026-08-15", "Anna", "Lebensmittel", "Anna", "Ben", "Cleo")
      e.expense("Edeka", 1000, "2026-09-01", "Ben", "Lebensmittel", "Anna", "Ben")
      e.expense("Kino", 2400, "2026-09-05", "Cleo", "", "Ben", "Cleo")
      e.expense("Lidl", 1999, "2026-09-07", "Cleo", "Lebensmittel", "Cleo")
      {
        %({})                                               => "Lidl,Kino,Edeka,Rewe",
        %({"sort":"date_asc"})                              => "Rewe,Edeka,Kino,Lidl",
        %({"sort":"amount_desc"})                           => "Rewe,Kino,Lidl,Edeka",
        %({"sort":"amount_asc"})                            => "Edeka,Lidl,Kino,Rewe",
        %({"min_amount":19.99,"max_amount":24})             => "Lidl,Kino",
        %({"min_amount":20})                                => "Kino,Rewe",
        %({"text":["rewe","LIDL"]})                         => "Lidl,Rewe",
        %({"text":"edeka"})                                 => "Edeka",
        %({"paid_by":"Cleo"})                               => "Lidl,Kino",
        %({"involved":"Ben"})                               => "Kino,Edeka,Rewe",
        %({"person":"Ben"})                                 => "Kino,Edeka,Rewe",
        %({"paid_by":"Cleo","involved":"Ben"})              => "Kino",
        %({"text":null,"min_amount":null})                  => "Lidl,Kino,Edeka,Rewe",
        %({"min_amount":20,"min_amount":null})              => "Lidl,Kino,Edeka,Rewe",
        %({"reimbursements":" include ","SORT":"date_asc"}) => "Rewe,Edeka,Kino,Lidl",
      }.each do |args, want|
        {args, titles(e.ok("search_expenses", args))}.should eq({args, want})
      end
      # involved sums up the person's shares like person.
      e.ok("search_expenses", %({"involved":"Ben"}))["person_share"].should eq JSON.parse(%({"amount":"27.00","amount_cents":2700,"person":"Ben"}))
      # compact (default) leaves out split, shares and notes, full includes them.
      text = e.call("search_expenses", %({"text":"Kino"}))[1]
      text.should_not contain(%("shares"))
      text.should_not contain(%("split"))
      text.should contain(%("amount":"24.00"))
      text = e.call("search_expenses", %({"text":"Kino","detail":"full"}))[1]
      text.should contain(%("shares"))
      text.should contain(%("split":"equal"))
    end
  end

  it "computes statistics" do
    with_env do |e|
      e.at("2026-04-15")
      e.expense("Rewe", 3000, "2025-03-10", "Anna", "Lebensmittel", "Anna", "Ben")
      e.expense("Pizza", 1000, "2025-05-02", "Anna", "Restaurant", "Anna")
      e.expense("Rewe", 4000, "2026-01-05", "Anna", "Lebensmittel", "Anna", "Ben")
      e.expense("REWE", 2000, "2026-03-20", "Ben", "Lebensmittel", "Anna", "Ben")
      e.expense("Kino", 1500, "2026-03-21", "Ben", "", "Ben")
      rows = ->(args : String) { e.ok("statistics", args)["rows"].as_a }

      # Months without expenses appear with 0, from from (or the first row) to today.
      r = rows.call(%({"group_by":"month","from":"2026-01-01"}))
      r.map { |x| {x["month"].as_s, x["amount_cents"].as_i} }.should eq [{"2026-01", 4000}, {"2026-02", 0}, {"2026-03", 3500}, {"2026-04", 0}]
      rows.call(%({"group_by":"month","from":"2026-01-01","text":"nothing like this"})).size.should eq 4
      rows.call(%({"group_by":"month","from":"2026-01-01","to":"2026-12-31"})).size.should eq 4
      r = rows.call(%({"group_by":"year"}))
      r.map { |x| {x["year"].as_s, x["amount_cents"].as_i} }.should eq [{"2025", 4000}, {"2026", 7500}]
      r = rows.call(%({"group_by":"week","from":"2026-03-16","to":"2026-03-29"}))
      r.map { |x| {x["week"].as_s, x["count"].as_i, x["amount_cents"].as_i} }.should eq [{"2026-W12", 2, 3500}, {"2026-W13", 0, 0}]
      # title groups case-insensitively, text filters.
      r = rows.call(%({"group_by":"title","from":"2026-01-01"}))
      {r.size, r[0]["title"].as_s.downcase, r[0]["count"], r[0]["amount_cents"]}.should eq({2, "rewe", 2, 6000})
      rows.call(%({"group_by":"category","text":["kino","pizza"]})).size.should eq 2
      # limit truncates the rows, but total covers all of them.
      d = e.ok("statistics", %({"group_by":"month","limit":2}))
      {d["rows"].as_a.size, d["truncated"], d["rows_total"], d["total_cents"]}.should eq({2, true, 14, 11500})

      # compare=previous_year by month: each month against the same month a year earlier.
      d = e.ok("statistics", %({"group_by":"month","from":"2026-01-01","to":"2026-03-31","compare":"previous_year"}))
      d["rows"].should eq JSON.parse(%([
        {"month":"2026-01","count":1,"amount":"40.00","amount_cents":4000,"previous":"0.00","previous_cents":0,"change":"40.00","change_cents":4000},
        {"month":"2026-02","count":0,"amount":"0.00","amount_cents":0,"previous":"0.00","previous_cents":0,"change":"0.00","change_cents":0},
        {"month":"2026-03","count":2,"amount":"35.00","amount_cents":3500,"previous":"30.00","previous_cents":3000,"change":"5.00","change_cents":500,"change_percent":16.7}]))
      {d["previous_total_cents"], d["previous_period"]}.should eq({3000, "each month one year earlier"})
      # By category: groups only present a year earlier appear with 0.
      d = e.ok("statistics", %({"group_by":"category","from":"2026-01-01","to":"2026-12-31","compare":"previous_year"}))
      d["rows"].as_a.to_h { |x| {x["category"].as_s, {x["amount_cents"].as_i, x["previous_cents"].as_i}} }.should eq({
        "Lebensmittel" => {6000, 3000}, "No category" => {1500, 0}, "Restaurant" => {0, 1000},
      })
      d["previous_period"].should eq "2025-01-01 to 2025-12-31"
    end
  end

  it "computes the balance history" do
    with_env do |e|
      e.expense("Rewe", 3000, "2026-01-10", "Anna", "Lebensmittel", "Anna", "Ben", "Cleo")
      e.expense("Kino", 2000, "2026-03-05", "Ben", "", "Anna", "Ben")
      e.reimbursement(1000, "2026-03-20", "Ben", "Anna")
      history = ->(args : String?) do
        e.ok("balance_history", args)["rows"].as_a.map { |r| r["balances"].as_a.to_h { |b| {b["person"].as_s, b["balance_cents"].as_i} } }
      end
      e.at("2026-03-25")
      history.call(%({"from":"2025-12-01","to":"2026-03-31"})).should eq [
        {"Anna" => 0, "Ben" => 0, "Cleo" => 0},
        {"Anna" => 2000, "Ben" => -1000, "Cleo" => -1000},
        {"Anna" => 2000, "Ben" => -1000, "Cleo" => -1000},
        {"Anna" => 0, "Ben" => 1000, "Cleo" => -1000},
      ]
      # A later first period starts with the opening balance; person narrows down.
      history.call(%({"interval":"year","from":"2026-02-01","to":"2026-12-31","person":"ben"})).should eq [{"Ben" => 1000}]
      d = e.ok("balance_history", %({"interval":"week","from":"2026-03-02","to":"2026-03-15"}))
      d["rows"].as_a.map(&.["week"].as_s).should eq ["2026-W10", "2026-W11"]
      d["rows"][0]["balances"][0].should eq JSON.parse(%({"person":"Anna","balance":"10.00","balance_cents":1000,"status":""}))
      # Without to, the last row includes expenses dated later and equals
      # balances; with to, later expenses are left out.
      e.expense("Miete", 3000, "2026-05-01", "Cleo", "", "Anna", "Ben", "Cleo")
      rows = history.call(nil)
      {rows.size, rows[4]["Cleo"], rows[3]["Cleo"]}.should eq({5, -1000 + 2000, -1000})
      rows = history.call(%({"to":"2026-04-30"}))
      {rows.size, rows[3]["Cleo"]}.should eq({4, -1000})
      {
        %({"interval":"day"})                                        => "interval must be one of month, week, year.",
        %({"person":"Dora"})                                         => %(Unknown person "Dora". Available: Anna, Ben, Cleo.),
        %({"interval":"week","from":"2000-01-01","to":"2026-01-01"}) => "That is 1358 periods, at most 500 are possible. Please narrow down from/to or choose a longer interval.",
        %({"interval":"week","from":"1900-01-01"})                   => %(Invalid date for from: "1900-01-01" (expected YYYY-MM-DD).),
      }.each { |args, msg| e.fail("balance_history", args).should eq msg }
    end
  end

  it "lists the activity log" do
    with_env do |e|
      e.expense("Rewe", 3000, "2026-01-10", "Anna", "Lebensmittel", "Anna", "Ben")
      kino_id = e.expense("Kino", 2000, "2026-03-05", "Ben", "", "Anna", "Ben")
      kino = e.store.get_expense(kino_id)
      input = kino.input
      input.title = "Kino & Popcorn"
      input.amount_cents = 2500
      e.store.update_expense(e.ids["Cleo"], kino_id, input)
      e.store.create_category(0_i64, "Kino")
      entries = ->(args : String?) { e.ok("activity", args) }

      # Newest first: the category, the update, the two expenses, and the
      # three people (system entries).
      all = entries.call(nil)["entries"].as_a
      all.size.should eq 7
      {all[0]["actor"], all[0]["text"]}.should eq({"system", "Kategorie „Kino“ hinzugefügt"})
      {all[1]["actor"], all[1]["action"], all[1]["title"]}.should eq({"Cleo", "expense_updated", "Kino & Popcorn"})
      all[1]["changes"].as_a.should_not be_empty
      {all[3]["amount"], all[3]["amount_cents"], all[3]["expense_id"]}.should eq({"30.00", 3000, 1})
      all[3]["at"].as_s.should match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
      entries.call(%({"person":"cleo"}))["entries"].as_a.map(&.["action"]).should eq ["expense_updated"]
      entries.call(%({"action":"expense_created"}))["entries"].as_a.size.should eq 2
      entries.call({expense_id: kino_id}.to_json)["entries"].as_a.size.should eq 2
      d = entries.call(%({"limit":3}))
      {d["entries"].as_a.size, d["more"], d["shown"]}.should eq({3, true, 3})
      d["note"].should eq "There are older entries: call again with before_id=#{d["entries"][2]["id"]}."
      entries.call({before_id: d["entries"][2]["id"]}.to_json)["entries"].as_a.size.should eq 4
      # The log was written just now (real clock): today is in, yesterday is not.
      today = Time.utc.to_s("%F")
      yesterday = Time.utc.shift(days: -1).to_s("%F")
      entries.call({from: today, to: today}.to_json)["entries"].as_a.size.should eq 7
      entries.call({to: yesterday}.to_json)["entries"].as_a.size.should eq 0
      [%({"person":"Dora"}), %({"limit":0.5}), %({"from":"gestern"}), %({"expense_id":-1})].each do |args|
        e.fail("activity", args).should_not contain("Internal error")
      end
      e.fail("activity", %({"expense_id":-1})).should eq "expense_id and before_id must be positive."
    end
  end

  it "puts a data overview into the instructions" do
    with_env do |e|
      instructions = -> { e.modern("server/discover").result["instructions"].as_s }
      instructions.call.should end_with("\nData overview: there are no expenses yet. Values of activity.action: settings_updated.")
      e.expense("Rewe", 3000, "2025-03-10", "Anna", "Lebensmittel", "Anna", "Ben")
      e.expense("Kino", 2000, "2026-09-05", "Ben", "", "Anna", "Ben")
      e.expense("Bahn", 2000, "2026-09-06", "Ben", "", "Ben")
      e.expense("Pizza", 2000, "2026-09-07", "Ben", "Restaurant", "Ben")
      e.reimbursement(1000, "2026-09-30", "Ben", "Anna")
      instructions.call.should end_with("\nData overview: 4 expenses and 1 reimbursements dated 2025-03-10 to 2026-09-30. " \
                                        "2 of the expenses (50.0%) have no category. Values of activity.action: expense_created, settings_updated.")
      e.post(%({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}})).result["instructions"].as_s.should contain("4 expenses")
    end
  end

  it "handles the edge cases of compare=previous_year" do
    with_env do |e|
      e.at("2026-10-02")
      e.expense("Rewe", 7000, "2025-03-10", "Anna", "Lebensmittel", "Anna")
      e.expense("Hotel", 50000, "2025-03-12", "Anna", "", "Anna")
      e.expense("Rewe", 10000, "2026-03-10", "Anna", "Lebensmittel", "Anna")
      e.expense("Miete", 90000, "2023-03-01", "Anna", "", "Anna")
      e.expense("Bäckerei Groß", 300, "2026-05-02", "Anna", "", "Anna")
      e.expense("BÄCKEREI GROSS", 200, "2025-05-02", "Anna", "", "Anna")
      e.expense("Glühwein", 800, "2020-12-30", "Anna", "", "Anna")

      # category_month: a category that only had expenses a year earlier appears with 0.
      d = e.ok("statistics", %({"group_by":"category_month","from":"2026-03-01","to":"2026-03-31","compare":"previous_year"}))
      d["rows"].should eq JSON.parse(%([
        {"category":"Lebensmittel","month":"2026-03","count":1,"amount":"100.00","amount_cents":10000,"previous":"70.00","previous_cents":7000,"change":"30.00","change_cents":3000,"change_percent":42.9},
        {"category":"No category","month":"2026-03","count":0,"amount":"0.00","amount_cents":0,"previous":"500.00","previous_cents":50000,"change":"-500.00","change_cents":-50000,"change_percent":-100}]))
      d["previous_total_cents"].should eq 57000
      # 29 February: the previous range ends on 28 February, not 1 March.
      d = e.ok("statistics", %({"group_by":"category","from":"2024-02-01","to":"2024-02-29","compare":"previous_year"}))
      {d["previous_total_cents"], d["previous_period"]}.should eq({0, "2023-02-01 to 2023-02-28"})
      # Titles are matched like Stats groups them (ß = ss).
      r = e.ok("statistics", %({"group_by":"title","from":"2026-05-01","to":"2026-05-31","compare":"previous_year"}))["rows"].as_a
      {r.size, r[0]["previous_cents"]}.should eq({1, 200})
      # Week 53 of 2020 is compared with week 52 of 2021.
      r = e.ok("statistics", %({"group_by":"week","from":"2021-12-20","to":"2021-12-26","compare":"previous_year"}))["rows"].as_a
      r.map(&.["week"]).should eq ["2021-W51"]
      r = e.ok("statistics", %({"group_by":"week","from":"2021-12-27","to":"2022-01-02","compare":"previous_year"}))["rows"].as_a
      {r.size, r[0]["week"], r[0]["previous_cents"]}.should eq({1, "2021-W52", 800})
      # A future from without to cannot be compared up to today.
      e.fail("statistics", %({"group_by":"category","from":"2026-12-01","compare":"previous_year"})).should contain("future")
    end
  end
end

# A fixed ECB rate for USD and nothing for other currencies.
private class FakeFX
  include Zipfelkasse::Web::FXRater

  def rate(currency : String, date : Time) : Zipfelkasse::Domain::FXRate
    raise "no rate" unless currency == "USD"
    Zipfelkasse::Domain::FXRate.new(currency, date, 1.25, Zipfelkasse::Domain::FX_SOURCE_ECB)
  end
end

describe "MCP write tools" do
  it "creates expenses" do
    with_env do |e|
      e.deps.fx = FakeFX.new
      e.at("2026-10-02")
      e.store.set_participant_archived(e.ids["Anna"], e.ids["Cleo"], true)
      created = ->(tool : String, args : String) do
        d = e.ok(tool, args)
        d["note"].as_s.should start_with("Created as entry ")
        d["created"]
      end
      shares = ->(x : JSON::Any) { x["shares"].as_a.join(",") { |s| "#{s["person"]}=#{s["amount"]}" } }

      # Defaults: today, EUR, equal among all active people (not the archived Cleo).
      x = created.call("create_expense", %({"title":"Rewe","amount":"23.40","paid_by":"ben","category":"lebensmittel"}))
      {x["date"], x["amount_cents"], x["paid_by"], x["category"], x["split"], shares.call(x)}
        .should eq({"2026-10-02", 2340, "Ben", "Lebensmittel", "equal", "Anna=11.70,Ben=11.70"})
      # The payer is the author in the activity log.
      acts = e.store.list_activity(Zipfelkasse::Store::ActivityFilter.new(expense_id: x["id"].as_i64))
      acts.map(&.actor_name).should eq ["Ben"]
      e.logs.should contain("msg=\"mcp: entry created\" id=#{x["id"]} reimbursement=false")
      # A JSON number as amount, participants, notes, date.
      x = created.call("create_expense", %({"title":"Kino","amount":12.5,"paid_by":"Anna","participants":["Anna"],"date":"2026-09-30","notes":"Sneak"}))
      {x["amount"], shares.call(x), x["notes"], x["date"]}.should eq({"12.50", "Anna=12.50", "Sneak", "2026-09-30"})
      # Weights: shares, percent, amount.
      shares.call(created.call("create_expense", %({"title":"Hotel","amount":"90","paid_by":"Anna","split":"shares","weights":{"Anna":"2.0","Ben":1}}))).should eq "Anna=60.00,Ben=30.00"
      shares.call(created.call("create_expense", %({"title":"Auto","amount":"100","paid_by":"Anna","split":"percent","weights":{"Anna":70,"Ben":30}}))).should eq "Anna=70.00,Ben=30.00"
      shares.call(created.call("create_expense", %({"title":"Essen","amount":"23.40","paid_by":"Ben","split":"amount","weights":{"Anna":"15.00","Ben":8.4}}))).should eq "Anna=15.00,Ben=8.40"
      # Foreign currency: ECB rate by default, fx_rate as a manual rate.
      x = created.call("create_expense", %({"title":"Diner","amount":"25.00","currency":"usd","paid_by":"Anna"}))
      {x["original"], x["amount_cents"], x["fx_rate"], x["fx_source"]}.should eq({"25.00 USD", 2000, 1.25, "ezb"})
      x = created.call("create_expense", %({"title":"Sushi","amount":2000,"currency":"JPY","fx_rate":160,"paid_by":"Anna"}))
      {x["original"], x["amount_cents"], x["fx_source"]}.should eq({"2000 JPY", 1250, "manuell"})
      e.call("create_expense", %({"title":"Sushi2","amount":2000,"currency":"JPY","fx_rate":160,"paid_by":"Anna"}))[1].should contain(%("fx_rate":160,))

      # The same expense again is refused, unless allow_duplicate is set.
      msg = e.fail("create_expense", %({"title":"REWE","amount":"23.40","paid_by":"Ben"}))
      msg.should eq "This looks like a duplicate of entry 1 (2026-10-02, Rewe, 23.40 EUR, paid by Ben). " \
                    "Ask the user; if it really is a second one, call again with allow_duplicate=true."
      created.call("create_expense", %({"title":"Rewe","amount":"23.40","paid_by":"Ben","allow_duplicate":true}))
      created.call("create_expense", %({"title":"Rewe","amount":"23.40","paid_by":"Ben","date":"2026-10-01"}))

      x = %("title":"X","amount":"1","paid_by":"Anna")
      {
        %({"amount":"1","paid_by":"Anna"})                                              => "Parameter title is missing.",
        %({"title":"X","paid_by":"Anna"})                                               => "Parameter amount is missing.",
        %({"title":"X","amount":"1"})                                                   => "Parameter paid_by is missing.",
        %({"title":"X","amount":"0","paid_by":"Anna"})                                  => "amount must be greater than 0.",
        %({"title":"X","amount":"-5","paid_by":"Anna"})                                 => %(Invalid amount "-5" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
        %({"title":"X","amount":"abc","paid_by":"Anna"})                                => %(Invalid amount "abc" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
        %({"title":"X","amount":"1.234","paid_by":"Anna"})                              => %(Invalid amount "1.234" for EUR: at most 2 decimal places),
        %({"title":"X","amount":"1,50","paid_by":"Anna"})                               => %(Invalid amount "1,50" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
        %({"title":"X","amount":"1.000,00","paid_by":"Anna"})                           => %(Invalid amount "1.000,00" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
        %({"title":"X","amount":"1e3","paid_by":"Anna","currency":"JPY","fx_rate":160}) => %(Invalid amount "1e3" for JPY: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
        %({"title":"X","amount":"1.5","paid_by":"Anna","currency":"JPY","fx_rate":160}) => %(Invalid amount "1.5" for JPY: must be a whole number),
        %({"title":"X","amount":"12 €","paid_by":"Anna"})                               => %(Invalid amount "12 €" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
        %({"title":"X","amount":"1234567890123456","paid_by":"Anna"})                   => %(Invalid amount "1234567890123456" for EUR: too large),
        %({"title":"X","amount":"1","paid_by":"Dora"})                                  => %(Unknown person "Dora" in paid_by. Available: Anna, Ben.),
        %({"title":"X","amount":"1","paid_by":"Cleo"})                                  => "Cleo is archived and cannot take part in new entries.",
        %({#{x},"participants":["Cleo"]})                                               => "Cleo is archived and cannot take part in new entries.",
        %({#{x},"participants":["Anna","anna"]})                                        => "Anna appears twice in the split.",
        %({#{x},"category":"Yacht"})                                                    => %(Unknown category "Yacht". Available: Lebensmittel, Restaurant, Haushalt, Miete & Nebenkosten, Transport, Reisen, Freizeit, Gesundheit, Geschenke, Sonstiges.),
        %({#{x},"split":"thirds"})                                                      => "split must be one of equal, shares, percent, amount.",
        %({#{x},"split":"shares"})                                                      => "split=shares needs weights (person name → value).",
        %({#{x},"weights":{"Anna":1}})                                                  => "weights are only for split=shares, percent or amount; use participants for an equal split.",
        %({#{x},"split":"shares","participants":["Anna"],"weights":{"Anna":1}})         => "With split=shares, weights name the participants; leave participants out.",
        %({#{x},"split":"percent","weights":{"Anna":60,"Ben":30}})                      => "The app refused the entry (message in German): Die Prozente müssen zusammen 100 % ergeben (aktuell 90,00 %).",
        %({#{x},"split":"shares","weights":{"Anna":"zwei"}})                            => %(Invalid value "zwei" for Anna in weights: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50.),
        %({#{x},"split":"shares","weights":{"Anna":"1.5"}})                             => %(Invalid value "1.5" for Anna in weights: must be a whole number.),
        %({#{x},"split":"shares","weights":{"Zoe":1,"Anna":"x"}})                       => %(Invalid value "x" for Anna in weights: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50.),
        %({#{x},"currency":"EURO"})                                                     => %(currency must be a three-letter ISO code such as USD, not "EURO".),
        %({#{x},"currency":"CHF"})                                                      => "There is no exchange rate for CHF on 2026-10-02. Ask the user for the rate and pass it as fx_rate.",
        %({#{x},"fx_rate":1.1})                                                         => "fx_rate is only for foreign currencies.",
        %({#{x},"currency":"USD","fx_rate":0})                                          => "fx_rate must be greater than 0.",
        %({#{x},"date":"morgen"})                                                       => %(Invalid date for date: "morgen" (expected YYYY-MM-DD).),
        %({"title":"X","amount":true,"paid_by":"Anna"})                                 => "Invalid arguments: must be a string or a number",
        %({#{x},"titel":"Y"})                                                           => %(Invalid arguments: json: unknown field "titel"),
        %({#{x},"participants":"Anna"})                                                 => "Invalid arguments: json: cannot unmarshal string into Go struct field .participants of type []string",
        %({#{x},"allow_duplicate":"yes"})                                               => "Invalid arguments: json: cannot unmarshal string into Go struct field .allow_duplicate of type bool",
        %({#{x},"weights":["Anna"]})                                                    => "Invalid arguments: json: cannot unmarshal array into Go struct field .weights of type map[string]mcp.amountText",
        # The order of the checks.
        %({"amount":"x","paid_by":"Zoe","split":"x","date":"x"})                                 => "Parameter title is missing.",
        %({"title":"X","amount":"x","paid_by":"Zoe","date":"x"})                                 => %(Invalid date for date: "x" (expected YYYY-MM-DD).),
        %({"title":"X","amount":"1","paid_by":"Anna","category":"Yacht","participants":["Zoe"]}) => %(Unknown category "Yacht". Available: Lebensmittel, Restaurant, Haushalt, Miete & Nebenkosten, Transport, Reisen, Freizeit, Gesundheit, Geschenke, Sonstiges.),
      }.each do |args, want|
        {args, e.fail("create_expense", args)}.should eq({args, want})
      end
      e.store.list_expenses.size.should eq 10
    end
  end

  it "creates reimbursements" do
    with_env do |e|
      e.at("2026-10-02")
      e.expense("Rewe", 3000, "2026-09-01", "Anna", "Lebensmittel", "Anna", "Ben")
      d = e.ok("create_reimbursement", %({"from":"Ben","to":"anna","amount":"15","notes":"PayPal"}))
      d["created"].should eq JSON.parse(%({"id":2,"date":"2026-10-02","title":"Rückzahlung","paid_by":"Ben","amount":"15.00","amount_cents":1500,"reimbursement":true,"recipient":"Anna","notes":"PayPal"}))
      d["note"].should eq "Created as entry 2 with Ben as author. Changing or deleting it is only possible in the app."
      e.ok("balances")["settlements"].as_a.should be_empty
      e.fail("create_reimbursement", %({"from":"Ben","to":"Anna","amount":"15.00"})).should contain("duplicate")
      e.ok("create_reimbursement", %({"from":"Ben","to":"Cleo","amount":"15.00"}))
      {
        %({"from":"Ben","to":"Ben","amount":"1"})                   => "from and to must be different people.",
        %({"from":"Ben","amount":"1"})                              => "Parameter to is missing.",
        %({"from":"Ben","to":"Dora","amount":"1"})                  => %(Unknown person "Dora" in to. Available: Anna, Ben, Cleo.),
        %({"from":"Ben","to":"Anna","amount":"1","title":"Geld"})   => %(Invalid arguments: json: unknown field "title"),
        %({"from":"Zoe","to":"Zoe","amount":"x"})                   => %(Invalid amount "x" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
        %({"from":"Ben","to":"Anna","amount":"5","currency":"XAF"}) => "There is no exchange rate for XAF on 2026-10-02. Ask the user for the rate and pass it as fx_rate.",
      }.each do |args, want|
        e.fail("create_reimbursement", args).should eq want
      end
    end
  end

  it "parses decimals" do
    {"23.4" => {2, 2340}, "23.40" => {2, 2340}, "23" => {2, 2300}, "1.000" => {2, 100}, "1200.00" => {0, 1200}, "0.5" => {2, 50},
     " 7 " => {2, 700}, "5." => {2, 500}}.each do |s, (decimals, want)|
      MCP.parse_decimal(s, decimals).should eq want
    end
    ["1.234", "1,5", "1.000,00", "-1", "+1", ".5", "1e3", "", "1.2.3", "1 000"].each do |s|
      expect_raises(MCP::DecimalError) { MCP.parse_decimal(s, 2) }
    end
  end
end
