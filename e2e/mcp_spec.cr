require "./e2e_helper"

# The MCP server at /mcp/<secret>: transport and access rules, both protocol
# eras, every tool with its results and messages, the SQL sandbox and the
# write tools. The wording of argument decoding errors is not part of the
# contract: such calls only have to fail and name the offending field
# (MCPKit.decode_fail).
private alias MK = E2E::MCPKit

private READ_TOOLS  = %w(balances balance_history search_expenses statistics activity schema sql_query)
private WRITE_TOOLS = %w(create_expense create_reimbursement)

private def security_headers!(r : E2E::Response) : Nil
  MK::SECURITY_HEADERS.each { |k, v| r.headers[k]?.should eq v }
end

private def json_error!(r : E2E::Response, status : Int32, code : Int32, message : String) : JSON::Any
  r.status.should eq status
  r.content_type.should eq "application/json"
  j = r.json
  j["jsonrpc"].should eq "2.0"
  MK.error(r).should eq({code.to_i64, message})
  j
end

private def plain!(r : E2E::Response, status : Int32, body : String) : Nil
  r.status.should eq status
  r.content_type.should eq "text/plain; charset=utf-8"
  r.body.should eq body
  security_headers!(r)
end

private def eur(c : Int) : String
  (c < 0 ? "-" : "") + "#{c.abs // 100}.#{(c.abs % 100).to_s.rjust(2, '0')}"
end

describe "MCP transport" do
  world = E2E::World.new("mcp-transport")
  after_all { world.stop }

  scenario "initialize negotiates the version and explains the server", world do
    user = world.user
    r = MK.rpc(user, "initialize", %({"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}), id: "0")
    r.status.should eq 200
    r.content_type.should eq "application/json"
    r.headers["Mcp-Session-Id"]?.should be_nil
    security_headers!(r)
    r.json["id"].should eq 0
    res = MK.result(r)
    res.as_h.keys.sort.should eq %w(capabilities instructions protocolVersion serverInfo)
    res["protocolVersion"].should eq "2025-06-18"
    res["capabilities"].should eq MK.json(%({"tools":{"listChanged":false}}))
    res["serverInfo"].should eq MK.json(%({"name":"zipfelkasse","title":"Zipfelkasse – shared expenses","version":"1.1.0"}))
    res["instructions"].should eq MK::INSTRUCTIONS + "\n" + MK.today_line("2026-10-03", "Saturday") +
                                  "\nData overview: there are no expenses yet."

    # Supported legacy versions are echoed, anything else gets the newest.
    {"2025-11-25" => "2025-11-25", "2025-03-26" => "2025-03-26", "2024-11-05" => "2025-11-25",
     "2026-07-28" => "2025-11-25", "" => "2025-11-25"}.each do |asked, got|
      MK.result(MK.rpc(user, "initialize", %({"protocolVersion":#{asked.to_json}})))["protocolVersion"].should eq got
    end
    MK.result(MK.rpc(user, "initialize"))["protocolVersion"].should eq "2025-11-25"
    MK.result(MK.rpc(user, "initialize", "null"))["protocolVersion"].should eq "2025-11-25"
    # initialize ignores the version header.
    MK.result(MK.rpc(user, "initialize", %({"protocolVersion":"2025-06-18"}), extra: {"MCP-Protocol-Version" => "1999-01-01"}))["protocolVersion"].should eq "2025-06-18"

    r = MK.rpc(user, "notifications/initialized", id: nil)
    r.status.should eq 202
    r.body.should eq ""
    r.headers["Content-Type"]?.should be_nil
    security_headers!(r)

    # The data overview follows the data: adding a person is a settings change.
    user.login("Anna").status.should eq 303
    MK.result(MK.rpc(user, "initialize", %({"protocolVersion":"2025-06-18"})))["instructions"].as_s
      .should end_with(MK.today_line("2026-10-03", "Saturday") + "\nData overview: there are no expenses yet. Values of activity.action: settings_updated.")
  end

  scenario "tools/list names, schemas and annotations", world do
    user = world.user
    res = MK.result(MK.rpc(user, "tools/list"))
    res.as_h.keys.should eq ["tools"]
    tools = res["tools"].as_a
    tools.map(&.["name"].as_s).should eq READ_TOOLS + WRITE_TOOLS
    tools.map(&.["title"].as_s).should eq ["Balances and settlement", "Balance history", "Search expenses", "Statistics",
                                           "Activity log", "Database schema", "SQL query", "Create expense", "Create reimbursement"]
    tools.each do |t|
      write = WRITE_TOOLS.includes?(t["name"].as_s)
      t.as_h.keys.sort.should eq %w(annotations description inputSchema name title)
      t["annotations"].should eq MK.json({readOnlyHint: !write, destructiveHint: false, idempotentHint: !write, openWorldHint: false}.to_json)
      t["inputSchema"]["type"].should eq "object"
      t["inputSchema"]["additionalProperties"].should eq false
    end
    tool = ->(name : String) { tools.find { |t| t["name"] == name }.not_nil! }
    props = ->(name : String) { tool.call(name)["inputSchema"]["properties"].as_h.keys.sort }
    required = ->(name : String) { tool.call(name)["inputSchema"]["required"]?.try(&.as_a.map(&.as_s)) }
    {
      "balances"             => {[] of String, nil},
      "balance_history"      => {"from interval person to".split, nil},
      "search_expenses"      => {"category detail from involved limit max_amount min_amount paid_by person reimbursements sort text to".split, nil},
      "statistics"           => {"category compare from group_by limit share_of text to".split, ["group_by"]},
      "activity"             => {"action before_id expense_id from limit person to".split, nil},
      "schema"               => {[] of String, nil},
      "sql_query"            => {"query".split, ["query"]},
      "create_expense"       => {"allow_duplicate amount category currency date fx_rate notes paid_by participants split title weights".split, %w(title amount paid_by)},
      "create_reimbursement" => {"allow_duplicate amount currency date from fx_rate notes to".split, %w(from to amount)},
    }.each do |name, (p, req)|
      props.call(name).should eq p
      required.call(name).should eq req
    end
    enum_of = ->(name : String, prop : String) { tool.call(name)["inputSchema"]["properties"][prop]["enum"].as_a.map(&.as_s) }
    enum_of.call("balance_history", "interval").should eq %w(month week year)
    enum_of.call("search_expenses", "reimbursements").should eq %w(exclude include only)
    enum_of.call("search_expenses", "sort").should eq %w(date_desc date_asc amount_desc amount_asc)
    enum_of.call("search_expenses", "detail").should eq %w(compact full)
    enum_of.call("statistics", "group_by").should eq %w(category title year month week person category_month)
    enum_of.call("statistics", "compare").should eq %w(previous_year)
    enum_of.call("create_expense", "split").should eq %w(equal shares percent amount)
    %w(search_expenses statistics activity).each do |name|
      limit = tool.call(name)["inputSchema"]["properties"]["limit"]
      {limit["type"], limit["minimum"], limit["maximum"]}.should eq({"integer", 1, 500})
    end
    tool.call("create_expense")["inputSchema"]["properties"]["amount"]["type"].should eq MK.json(%(["string","number"]))
    tool.call("search_expenses")["inputSchema"]["properties"]["text"]["anyOf"].should eq MK.json(%([{"type":"string"},{"items":{"type":"string"},"type":"array"}]))

    {
      "balances"             => "Current balance of each person in euros and a settlement proposal (who transfers how much to whom so that everyone ends at 0). Positive balance = is owed money, negative = owes money. Includes all non-deleted expenses and reimbursements.",
      "balance_history"      => "Balance of each person at the end of each month (or week/year): how the balances developed over time. Based on the current data by expense date (later edits and deletions apply retroactively). Positive balance = is owed money, negative = owes money. Reimbursements count.",
      "search_expenses"      => "Searches individual expenses (newest first unless sort says otherwise) with amount, payer and category; with detail=full also split (each person's share), notes and foreign currency. All filters are optional and are combined. Also returns the total number of matches, their total and – with person – the total of that person's shares. For plain totals by category/month, statistics is the better choice.",
      "statistics"           => %(Expense totals grouped by category, title (merchant), year, month (YYYY-MM), ISO week (YYYY-Www), person or category_month, optionally for a period. Without share_of: total amounts of the expenses. With share_of: only that person's share of each expense, i.e. what they consumed themselves (e.g. "How much did I spend on restaurants in 2026?"). With group_by=person, amount is each person's share (consumption) and paid is what they paid up front. year, month and week list periods without expenses with 0. compare=previous_year adds the amount of the same group one year earlier and the change. Reimbursements and deleted expenses never count.),
      "activity"             => "Who created, changed or deleted which expense when, and other changes (settings, people, categories, rates, recurring expenses), newest first. Entries of expense_updated list the changed fields with old and new value (field names and values as shown in the app, in German).",
      "schema"               => "Explains the database tables and columns in words (amounts in cents, deleted expenses, reimbursements, shares, foreign currency), lists people and categories and returns the CREATE statements. Call before sql_query.",
      "sql_query"            => "Runs exactly one read-only SQL query (SQLite dialect, only SELECT or WITH … SELECT) on a read-only copy of the data. Call schema first. Important: amounts are cents (divide by 100.0 for euros), exclude deleted expenses with deleted_at IS NULL, reimbursements (is_reimbursement = 1) are not expenses, a person's share is expense_shares.amount_cents. At most 500 rows, aborted after 5 seconds, texts longer than 2000 characters are truncated. For standard questions, balances, search_expenses and statistics are simpler.",
      "create_expense"       => "Creates an expense, as if the payer had entered it in the app. Ask the user before calling it if anything is unclear (amount, payer, who takes part); then tell them what was created. Without participants and weights, the amount is split equally among all active people. An entry with the same date, payer, amount and title is refused unless allow_duplicate is set. Settlement payments between people are not expenses: use create_reimbursement for them.",
      "create_reimbursement" => "Records a settlement payment: from paid amount to to (e.g. a bank transfer to settle up). It changes the balances, but is not an expense. An entry with the same date, payer, amount and recipient is refused unless allow_duplicate is set.",
    }.each { |name, desc| tool.call(name)["description"].should eq desc }

    # The same with the version header of a legacy client.
    MK.result(MK.rpc(user, "tools/list", extra: {"MCP-Protocol-Version" => "2025-06-18"}))["tools"].as_a.size.should eq 9
  end

  scenario "legacy requests: ping, versions, unknown methods and tools", world do
    user = world.user
    MK.result(MK.rpc(user, "ping")).should eq MK.json("{}")
    MK::LEGACY.each { |v| MK.result(MK.rpc(user, "ping", extra: {"MCP-Protocol-Version" => v})).should eq MK.json("{}") }

    j = json_error!(MK.rpc(user, "ping", id: "3", extra: {"MCP-Protocol-Version" => "1999-01-01"}), 400, -32022, "Unsupported protocol version.")
    j["id"].should eq 3
    j["error"]["data"].should eq MK.json(%({"requested":"1999-01-01","supported":["2026-07-28","2025-11-25","2025-06-18","2025-03-26"]}))
    json_error!(MK.rpc(user, "ping", extra: {"MCP-Protocol-Version" => "2026-07-28"}), 400, -32020,
      %(Header MCP-Protocol-Version is 2026-07-28, but params._meta["io.modelcontextprotocol/protocolVersion"] is missing.))
    # Notifications: fine with a legacy version, refused (without id) otherwise.
    r = MK.rpc(user, "notifications/cancelled", %({"requestId":1}), id: nil, extra: {"MCP-Protocol-Version" => "2025-11-25"})
    {r.status, r.body}.should eq({202, ""})
    j = json_error!(MK.rpc(user, "notifications/initialized", id: nil, extra: {"MCP-Protocol-Version" => "1999"}), 400, -32022, "Unsupported protocol version.")
    j.as_h.has_key?("id").should be_false
    j["error"]["data"]["requested"].should eq "1999"

    j = json_error!(MK.rpc(user, "resources/list", id: "4"), 200, -32601, "Unknown method: resources/list")
    j["id"].should eq 4
    json_error!(MK.rpc(user, "initialize/extra"), 200, -32601, "Unknown method: initialize/extra")
    json_error!(MK.call(user, "nope"), 200, -32602, "Unknown tool: nope")
    json_error!(MK.call(user, "Balances"), 200, -32602, "Unknown tool: Balances")
    json_error!(MK.rpc(user, "tools/call", %({"arguments":{}})), 200, -32602, "Unknown tool: ")

    # Missing or null arguments count as {}.
    expected = MK.json(%({"balances":[{"person":"Anna","balance":"0.00","balance_cents":0,"status":"settled"}],"note":"Positive balance = is owed money, negative = owes money. settlements: the transfers needed so that everyone ends at 0.","settlements":[]}))
    MK.data(MK.call(user, "balances", nil)).should eq expected
    MK.data(MK.call(user, "balances", "null")).should eq expected
    MK.data(MK.call(user, "balances", "{}")).should eq expected
    r = MK.call(user, "balances")
    MK.result(r).as_h.keys.sort.should eq %w(content isError)
  end

  scenario "malformed messages", world do
    user = world.user
    j = json_error!(MK.post(user, %({"id":1,"method":"ping"})), 400, -32600, %(jsonrpc must be "2.0".))
    j["id"].should eq 1
    json_error!(MK.post(user, %({"jsonrpc":"1.0","id":1,"method":"ping"})), 400, -32600, %(jsonrpc must be "2.0".))
    j = json_error!(MK.post(user, %({"jsonrpc":"2.0","id":7})), 400, -32600, "Field method is missing.")
    j["id"].should eq 7
    j = json_error!(MK.post(user, %({"jsonrpc":"2.0"})), 400, -32600, "Field method is missing.")
    j.as_h.has_key?("id").should be_false
    json_error!(MK.post(user, %({"jsonrpc":"2.0","id":1,"method":""})), 400, -32600, "Field method is missing.")

    # Answers from the client (we never send requests) are accepted silently.
    [%({"jsonrpc":"2.0","id":5,"result":{}}), %({"jsonrpc":"2.0","id":5,"error":{"code":-1,"message":"x"}}),
     %({"jsonrpc":"2.0","id":5,"result":null})].each do |b|
      r = MK.post(user, b)
      {r.status, r.body}.should eq({202, ""})
    end

    json_error!(MK.post(user, %([{"jsonrpc":"2.0","id":1,"method":"ping"}])), 400, -32600, "JSON-RPC batches are not supported.")
    j = json_error!(MK.post(user, %(  \n [])), 400, -32600, "JSON-RPC batches are not supported.")
    j.as_h.has_key?("id").should be_false

    j = json_error!(MK.rpc(user, "ping", %({"_meta":{"io.modelcontextprotocol/protocolVersion":7}})), 400, -32602,
      "_meta.io.modelcontextprotocol/protocolVersion must be a non-empty string.")
    j["id"].should eq 1
    json_error!(MK.rpc(user, "ping", %({"_meta":{"io.modelcontextprotocol/protocolVersion":""}})), 400, -32602,
      "_meta.io.modelcontextprotocol/protocolVersion must be a non-empty string.")

    # Parse errors and wrongly typed params carry decoder texts: only the
    # code and the prefix are fixed.
    [%({broken), "", %({"jsonrpc":"2.0","id":1,"method":"ping"} x), %({"jsonrpc":"2.0","id":1,"method":5})].each do |b|
      r = MK.post(user, b)
      r.status.should eq 400
      code, msg = MK.error(r)
      code.should eq -32700
      msg.should start_with("Invalid JSON")
      r.json.as_h.has_key?("id").should be_false
    end
    [%([1]), %("x"), %({"name":5})].each do |params|
      r = MK.post(user, MK.body("tools/call", params))
      r.status.should eq 400
      code, msg = MK.error(r)
      code.should eq -32602
      msg.should start_with("Invalid params")
      r.json["id"].should eq 1
    end
  end

  scenario "transport: content type, size, methods, origin, secret", world do
    user = world.user
    ping = MK.body("ping")
    ["application/json; charset=utf-8", "Application/JSON", "application/json;charset=UTF-8"].each do |ct|
      MK.result(MK.post(user, ping, content_type: ct)).should eq MK.json("{}")
    end
    ["text/plain", "application/x-www-form-urlencoded", "application/jsonx", "application/json-rpc"].each do |ct|
      r = json_error!(MK.post(user, ping, content_type: ct), 415, -32600, "Content-Type must be application/json.")
      r.as_h.has_key?("id").should be_false
      security_headers!(MK.post(user, ping, content_type: ct))
    end
    json_error!(MK.request(user, "POST", body: ping), 415, -32600, "Content-Type must be application/json.")

    # 1 MiB is fine, one byte more is not.
    exact = ping + " " * ((1 << 20) - ping.bytesize)
    exact.bytesize.should eq 1 << 20
    MK.result(MK.post(user, exact)).should eq MK.json("{}")
    json_error!(MK.post(user, exact + " "), 413, -32600, "Message too large or incomplete.")
    big = MK.body("tools/call", %({"name":"sql_query","arguments":{"query":"SELECT '#{"x" * (1 << 20)}'"}}))
    json_error!(MK.post(user, big), 413, -32600, "Message too large or incomplete.")

    # Only POST.
    %w(GET PUT DELETE PATCH OPTIONS).each do |m|
      r = MK.request(user, m)
      plain!(r, 405, "Method Not Allowed\n")
      r.headers["Allow"]?.should eq "POST"
    end
    r = MK.request(user, "HEAD")
    {r.status, r.headers["Allow"]?}.should eq({405, "POST"})
    r = MK.request(user, "GET", {"Accept" => "text/event-stream"})
    {r.status, r.headers["Allow"]?}.should eq({405, "POST"})

    # A browser (any Origin header, also "null") is refused – before the
    # method and content type are looked at.
    ["https://claude.ai", "null", "http://127.0.0.1"].each do |origin|
      json_error!(MK.post(user, ping, {"Origin" => origin}), 403, -32000, "Access from a browser is not allowed.")
    end
    json_error!(MK.request(user, "GET", {"Origin" => "https://evil.example"}), 403, -32000, "Access from a browser is not allowed.")
    json_error!(MK.post(user, ping, {"Origin" => "x"}, content_type: "text/plain"), 403, -32000, "Access from a browser is not allowed.")
    security_headers!(MK.post(user, ping, {"Origin" => "x"}))
    # The check order: method before content type, content type before size.
    plain!(MK.request(user, "GET", {"Content-Type" => "text/plain"}), 405, "Method Not Allowed\n")
    json_error!(MK.post(user, exact + " ", content_type: "text/plain"), 415, -32600, "Content-Type must be application/json.")
    json_error!(MK.post(user, "[" + " " * (1 << 20) + "]"), 413, -32600, "Message too large or incomplete.")

    # Wrong secret (or none): a plain 404 that does not give MCP away – also
    # for other methods and browsers.
    ["/mcp/falsch", "/mcp/e2e-gehei", "/mcp/e2e-geheim2", "/mcp/E2E-GEHEIM", "/mcp/e2e-geheim/tools", "/mcp/"].each do |path|
      r = MK.post(user, ping, path: path)
      plain!(r, 404, "404 page not found\n")
      r.body.should_not contain("mcp")
    end
    plain!(MK.request(user, "GET", path: "/mcp/falsch"), 404, "404 page not found\n")
    plain!(MK.request(user, "DELETE", path: "/mcp/falsch"), 404, "404 page not found\n")
    plain!(MK.post(user, ping, {"Origin" => "https://claude.ai"}, path: "/mcp/falsch"), 404, "404 page not found\n")
    plain!(MK.post(user, ping, content_type: "text/plain", path: "/mcp/falsch"), 404, "404 page not found\n")
  end

  scenario "JSON-RPC ids are echoed verbatim", world do
    user = world.user
    {"0" => 0_i64, "-3" => -3_i64, "9007199254740993" => 9007199254740993_i64}.each do |raw, id|
      r = MK.rpc(user, "ping", id: raw)
      r.json["id"].raw.should eq id
      r.body.should contain(%("id":#{raw}))
    end
    ["abc", "", "ä \"x\""].each do |s|
      MK.rpc(user, "ping", id: s.to_json).json["id"].should eq s
    end
    r = MK.rpc(user, "ping", id: "null")
    r.status.should eq 200
    r.json.as_h.has_key?("id").should be_true
    r.json["id"].raw.should be_nil
    MK.result(r).should eq MK.json("{}")
    # A request with id null is answered; only a missing id is a notification.
    r = MK.rpc(user, "tools/list", id: "null")
    MK.result(r)["tools"].as_a.size.should eq 9
    r = MK.rpc(user, "tools/list", id: nil)
    {r.status, r.body}.should eq({202, ""})
    j = json_error!(MK.rpc(user, "nix", id: %("x-1")), 200, -32601, "Unknown method: nix")
    j["id"].should eq "x-1"
    j = json_error!(MK.call(user, "nope"), 200, -32602, "Unknown tool: nope")
    j["id"].should eq 1
  end

  scenario "outside the web app: no identity, no CSRF check, client IP from the connection", world do
    user = world.user
    user.login("Anna")
    ping = MK.body("ping")
    # The identity cookie neither helps nor hurts.
    MK.result(user.run { |b| b.post_raw(MK::PATH, ping, "application/json", HTTP::Headers{"Cookie" => "wer=#{b.me}"}) }).should eq MK.json("{}")
    MK.result(MK.post(user, ping, {"Cookie" => "wer=999"})).should eq MK.json("{}")
    MK.result(MK.post(user, ping)).should eq MK.json("{}")
    # The web app's cross-origin protection does not apply (no Origin header).
    MK.result(MK.post(user, ping, {"Sec-Fetch-Site" => "cross-site"})).should eq MK.json("{}")
    MK.result(MK.post(user, ping, {"Sec-Fetch-Site" => "cross-site", "Sec-Fetch-Mode" => "cors"})).should eq MK.json("{}")
    # Without a trusted proxy, forwarding headers are ignored (127.0.0.1 is allowed).
    MK.result(MK.post(user, ping, {"X-Forwarded-For" => "6.6.6.6"})).should eq MK.json("{}")
    MK.result(MK.post(user, ping, {"X-Real-IP" => "6.6.6.6"})).should eq MK.json("{}")
    MK.result(MK.post(user, ping, {"X-Forwarded-For" => "garbage"})).should eq MK.json("{}")
    # Logged out: no redirect to /wer below /mcp/.
    anonymous = world.user
    plain!(anonymous.run { |b| b.request("GET", "/mcp/falsch", HTTP::Headers.new) }, 404, "404 page not found\n")
    plain!(anonymous.run { |b| b.request("GET", "/mcp/", HTTP::Headers.new) }, 404, "404 page not found\n")
    MK.result(anonymous.run(&.mcp("ping"))).should eq MK.json("{}")
    # The web app itself is unchanged.
    anonymous.get("/").status.should eq 303
  end

  scenario "modern protocol 2026-07-28: _meta and headers", world do
    user = world.user
    server_info = MK.json(%({"name":"zipfelkasse","title":"Zipfelkasse – shared expenses","version":"1.1.0"}))
    meta = MK.json({"io.modelcontextprotocol/serverInfo" => server_info}.to_json)

    r = MK.modern(user, "server/discover")
    r.json["id"].should eq "a-1"
    res = MK.result(r)
    res.as_h.keys.sort.should eq %w(_meta cacheScope capabilities instructions resultType supportedVersions ttlMs)
    res["_meta"].should eq meta
    res["cacheScope"].should eq "public"
    res["capabilities"].should eq MK.json(%({"tools":{"listChanged":false}}))
    res["resultType"].should eq "complete"
    res["supportedVersions"].should eq MK.json(MK::ALL.to_json)
    res["ttlMs"].should eq 3600000
    res["instructions"].as_s.should start_with(MK::INSTRUCTIONS + "\n" + MK.today_line("2026-10-03", "Saturday") + "\nData overview: ")
    # server/discover also works for legacy clients (without resultType).
    legacy = MK.result(MK.rpc(user, "server/discover"))
    legacy["supportedVersions"].should eq MK.json(MK::ALL.to_json)
    legacy.as_h.has_key?("resultType").should be_false

    res = MK.result(MK.modern(user, "tools/list"))
    res["tools"].as_a.map(&.["name"].as_s).should eq READ_TOOLS + WRITE_TOOLS
    {res["ttlMs"], res["cacheScope"], res["resultType"], res["_meta"]}.should eq({3600000, "public", "complete", meta})

    MK.result(MK.modern(user, "ping")).should eq MK.json({"_meta" => meta, "resultType" => "complete"}.to_json)

    r = MK.modern(user, "tools/call", %({"name":"balances","arguments":{}}))
    res = MK.result(r)
    res.as_h.keys.sort.should eq %w(_meta content isError resultType)
    {res["_meta"], res["resultType"], res["isError"]}.should eq({meta, "complete", false})
    MK.data(r)["balances"].as_a.map(&.["person"]).should eq ["Anna"]
    # Mcp-Name may be Base64 encoded (with or without padding), header names are case-insensitive.
    MK.data(MK.modern(user, "tools/call", %({"name":"balances"}), headers: MK.modern_headers("tools/call", MK.b64("balances"))))["note"].as_s.should start_with("Positive")
    MK.data(MK.modern(user, "tools/call", %({"name":"balances"}), headers: MK.modern_headers("tools/call", MK.b64("balances").sub("=?=", "?="))))
    MK.data(MK.modern(user, "tools/call", %({"name":"balances"}), headers: {"mcp-protocol-version" => MK::MODERN, "MCP-METHOD" => "tools/call", "mcp-name" => "balances"}))
    # A failed tool call is a result as well.
    r = MK.modern(user, "tools/call", %({"name":"sql_query","arguments":{"query":"DELETE FROM expenses"}}))
    MK.text(r, error: true).should eq "Only a single read-only query is allowed (SELECT … or WITH … SELECT …)."
    {MK.result(r)["resultType"], MK.result(r)["_meta"]}.should eq({"complete", meta})

    mismatch = ->(method : String, params : String, h : Hash(String, String), msg : String) do
      j = json_error!(MK.modern(user, method, params, headers: h), 400, -32020, msg)
      j["id"].should eq "a-1"
    end
    call = %({"name":"balances"})
    mismatch.call("ping", "{}", {"Mcp-Method" => "ping"}, "Header mismatch: header MCP-Protocol-Version is missing.")
    mismatch.call("ping", "{}", {"MCP-Protocol-Version" => "x", "Mcp-Method" => "ping"}, %(Header mismatch: MCP-Protocol-Version "x" does not match _meta "2026-07-28".))
    mismatch.call("ping", "{}", {"MCP-Protocol-Version" => "2025-06-18", "Mcp-Method" => "ping"}, %(Header mismatch: MCP-Protocol-Version "2025-06-18" does not match _meta "2026-07-28".))
    mismatch.call("ping", "{}", {"MCP-Protocol-Version" => MK::MODERN}, "Header mismatch: header Mcp-Method is missing.")
    mismatch.call("ping", "{}", MK.modern_headers("tools/list"), %(Header mismatch: Mcp-Method "tools/list" does not match method "ping".))
    mismatch.call("tools/call", call, MK.modern_headers("tools/call"), "Header mismatch: header Mcp-Name is missing.")
    mismatch.call("tools/call", call, MK.modern_headers("tools/call", "schema"), %(Header mismatch: Mcp-Name "schema" does not match params.name "balances".))
    mismatch.call("tools/call", call, MK.modern_headers("tools/call", MK.b64("schema")), %(Header mismatch: Mcp-Name "schema" does not match params.name "balances".))
    mismatch.call("tools/call", call, MK.modern_headers("tools/call", "=?base64?!!!?="), "Header mismatch: Mcp-Name is not valid Base64.")
    mismatch.call("tools/call", call, MK.modern_headers("tools/call", "Balances"), %(Header mismatch: Mcp-Name "Balances" does not match params.name "balances".))

    j = json_error!(MK.modern(user, "x/y"), 404, -32601, "Unknown method: x/y")
    j["id"].should eq "a-1"
    json_error!(MK.modern(user, "initialize", %({"protocolVersion":"2026-07-28"})), 404, -32601, "Unknown method: initialize")
    json_error!(MK.modern(user, "tools/call", %({"name":"nope"})), 200, -32602, "Unknown tool: nope")
    j = json_error!(MK.modern(user, "ping", version: "2099-01-01"), 400, -32022, "Unsupported protocol version.")
    j["error"]["data"].should eq MK.json(%({"requested":"2099-01-01","supported":["2026-07-28","2025-11-25","2025-06-18","2025-03-26"]}))
    j["id"].should eq "a-1"
    # An older version in _meta is answered the legacy way.
    MK.result(MK.modern(user, "ping", version: "2025-06-18")).should eq MK.json("{}")
    MK.result(MK.modern(user, "tools/list", version: "2025-11-25")).as_h.keys.should eq ["tools"]
    # Modern notifications need no headers.
    r = MK.modern(user, "notifications/cancelled", %({"requestId":"a-0"}), id: nil, headers: {} of String => String)
    {r.status, r.body}.should eq({202, ""})
  end

  scenario "today and the cache lifetime follow the server time zone", world do
    user = world.user
    world.restart("2026-10-03T21:30:00Z") # 23:30 in Berlin
    MK.result(MK.rpc(user, "initialize", %({"protocolVersion":"2025-06-18"})))["instructions"].as_s
      .should contain("\n" + MK.today_line("2026-10-03", "Saturday") + "\n")
    MK.result(MK.modern(user, "server/discover"))["ttlMs"].should eq 1800000
    MK.result(MK.modern(user, "tools/list"))["ttlMs"].should eq 3600000

    world.restart("2026-10-03T22:30:00Z") # already Sunday in Berlin
    MK.result(MK.rpc(user, "initialize"))["instructions"].as_s.should contain("\n" + MK.today_line("2026-10-04", "Sunday") + "\n")
    MK.result(MK.modern(user, "server/discover"))["ttlMs"].should eq 3600000
    MK.text(MK.call(user, "schema")).should start_with(MK.today_line("2026-10-04", "Sunday") + "\n\nDatabase of Zipfelkasse (SQLite). A single group.\n")
  end
end

describe "MCP access by client IP" do
  ping = MK.body("ping")
  not_allowed = "Access from this address is not allowed."

  only_10 = E2E::World.new("mcp-cidr", env: {"MCP_ALLOWED_CIDRS" => "10.0.0.0/8"})
  proxied = E2E::World.new("mcp-proxy", env: {"MCP_ALLOWED_CIDRS" => "10.0.0.0/8, 192.0.2.7", "TRUSTED_PROXIES" => "127.0.0.1 10.0.0.1"})
  disabled = E2E::World.new("mcp-off", env: {"MCP_SECRET" => " "})
  after_all do
    only_10.stop
    proxied.stop
    disabled.stop
  end

  scenario "127.0.0.1 is not in MCP_ALLOWED_CIDRS", only_10 do
    user = only_10.user
    j = json_error!(MK.post(user, ping), 403, -32000, not_allowed)
    j.as_h.has_key?("id").should be_false
    security_headers!(MK.post(user, ping))
    # Forwarding headers are ignored without a trusted proxy.
    json_error!(MK.post(user, ping, {"X-Forwarded-For" => "10.1.2.3"}), 403, -32000, not_allowed)
    json_error!(MK.post(user, ping, {"X-Real-IP" => "10.1.2.3"}), 403, -32000, not_allowed)
    # The IP check comes after the secret and before everything else.
    plain!(MK.post(user, ping, path: "/mcp/falsch"), 404, "404 page not found\n")
    json_error!(MK.request(user, "GET"), 403, -32000, not_allowed)
    json_error!(MK.post(user, ping, {"Origin" => "https://claude.ai"}), 403, -32000, not_allowed)
    json_error!(MK.post(user, ping, content_type: "text/plain"), 403, -32000, not_allowed)
    json_error!(MK.post(user, "{broken"), 403, -32000, not_allowed)
    # The web app is not restricted.
    user.get("/healthz").status.should eq 200
  end

  scenario "behind a trusted proxy the rightmost untrusted X-Forwarded-For hop counts", proxied do
    user = proxied.user
    allowed = ->(h : Hash(String, String)) { MK.result(MK.post(user, ping, h)).should eq MK.json("{}") }
    refused = ->(h : Hash(String, String)) { json_error!(MK.post(user, ping, h), 403, -32000, not_allowed) }
    # The proxy itself (127.0.0.1) is not allowed.
    refused.call({} of String => String)
    allowed.call({"X-Forwarded-For" => "10.1.2.3"})
    allowed.call({"X-Forwarded-For" => "192.0.2.7"})
    allowed.call({"X-Forwarded-For" => " 10.1.2.3 , "})
    # A client can prepend anything; only the hop the proxy appended counts.
    refused.call({"X-Forwarded-For" => "10.1.2.3, 6.6.6.6"})
    allowed.call({"X-Forwarded-For" => "6.6.6.6, 10.1.2.3"})
    allowed.call({"X-Forwarded-For" => "garbage, 10.1.2.3"})
    # Further trusted proxies on the right are skipped.
    allowed.call({"X-Forwarded-For" => "6.6.6.6, 10.1.2.3, 10.0.0.1"})
    refused.call({"X-Forwarded-For" => "10.1.2.3, 6.6.6.6, 10.0.0.1, 127.0.0.1"})
    # Only trusted hops: the leftmost one.
    allowed.call({"X-Forwarded-For" => "10.0.0.1, 127.0.0.1"})
    refused.call({"X-Forwarded-For" => "127.0.0.1, 10.0.0.1"})
    # Unparsable rightmost hops fail closed; ports and IPv4-mapped IPv6 are understood.
    refused.call({"X-Forwarded-For" => "garbage"})
    refused.call({"X-Forwarded-For" => "10.1.2.3, garbage"})
    refused.call({"X-Forwarded-For" => "[::1]"})
    allowed.call({"X-Forwarded-For" => "10.1.2.3:4711"})
    allowed.call({"X-Forwarded-For" => "::ffff:10.1.2.3"})
    allowed.call({"X-Forwarded-For" => "[::ffff:10.1.2.3]:443"})
    refused.call({"X-Forwarded-For" => "2001:db8::1"})
    # Without X-Forwarded-For, X-Real-IP is used.
    allowed.call({"X-Real-IP" => "10.9.9.9"})
    refused.call({"X-Real-IP" => "6.6.6.6"})
    refused.call({"X-Real-IP" => "garbage"})
    refused.call({"X-Forwarded-For" => "6.6.6.6", "X-Real-IP" => "10.9.9.9"})
    allowed.call({"X-Forwarded-For" => "10.1.2.3", "X-Real-IP" => "6.6.6.6"})
    # Header lines are joined in order.
    multi = ->(values : Array(String)) do
      user.run do |b|
        h = MK.headers
        values.each { |v| h.add("X-Forwarded-For", v) }
        b.post_raw(MK::PATH, ping, "application/json", h)
      end
    end
    MK.result(multi.call(["6.6.6.6", "10.1.2.3"])).should eq MK.json("{}")
    json_error!(multi.call(["10.1.2.3", "6.6.6.6"]), 403, -32000, not_allowed)
    # Allowed clients still need the right secret and no browser.
    plain!(MK.post(user, ping, {"X-Forwarded-For" => "10.1.2.3"}, path: "/mcp/falsch"), 404, "404 page not found\n")
    json_error!(MK.post(user, ping, {"X-Forwarded-For" => "10.1.2.3", "Origin" => "https://claude.ai"}), 403, -32000, "Access from a browser is not allowed.")
    MK.data(user.run { |b| b.post_raw(MK::PATH, MK.body("tools/call", %({"name":"balances"})), "application/json", MK.headers({"X-Forwarded-For" => "10.1.2.3"})) })["balances"].should eq MK.json("[]")
  end

  scenario "without MCP_SECRET there is no MCP endpoint", disabled do
    user = disabled.user
    ["/mcp/e2e-geheim", "/mcp/", "/mcp/x"].each do |path|
      plain!(MK.post(user, ping, path: path), 404, "404 page not found\n")
      plain!(MK.request(user, "GET", path: path), 404, "404 page not found\n")
    end
    user.get("/healthz").status.should eq 200
  end
end

describe "MCP tools" do
  world = E2E::World.new("mcp-tools")
  after_all { world.stop }

  people_line = "People (id: name): 1: Anna, 2: Ben, 3: Cleo, 4: Dora, 5: Emil (archived)"
  categories = "Lebensmittel, Restaurant, Haushalt, Miete & Nebenkosten, Transport, Reisen, Freizeit, Gesundheit, Geschenke, Sonstiges"
  all_people = "Available: Anna, Ben, Cleo, Dora, Emil."
  active_people = "Available: Anna, Ben, Cleo, Dora."
  unknown_category = %(Unknown category "Yacht". Available: #{categories}.)

  scenario "people and categories come from the app", world do
    user = world.user
    user.login("Anna").status.should eq 303
    %w(Ben Cleo Dora Emil).each { |n| user.post("/einstellungen/teilnehmer", {"name" => n}).status.should eq 303 }
    user.post("/einstellungen/teilnehmer/5/archivieren").status.should eq 303
    user.post("/einstellungen/kategorien/8/archivieren").status.should eq 303

    text = MK.text(MK.call(user, "schema"))
    text.should contain("\n#{people_line}\nCategories (id: name): 1: Lebensmittel, 2: Restaurant, 3: Haushalt, 4: Miete & Nebenkosten, 5: Transport, 6: Reisen, 7: Freizeit, 8: Gesundheit (archived), 9: Geschenke, 10: Sonstiges\n\nCREATE statements:\nCREATE TABLE participants (\n")
    MK.data(MK.call(user, "balances"))["balances"].as_a.map(&.["person"].as_s).should eq %w(Anna Ben Cleo Dora)
    MK.fail(user, "search_expenses", %({"person":"Zoe"})).should eq %(Unknown person "Zoe". #{all_people})
    MK.result(MK.rpc(user, "initialize"))["instructions"].as_s.should end_with("\nData overview: there are no expenses yet. Values of activity.action: settings_updated.")
  end

  scenario "create_expense: every refusal", world do
    user = world.user
    fail = ->(args : String) { MK.fail(user, "create_expense", args) }
    x = %("title":"X","amount":"10","paid_by":"Anna")
    jpy = %("title":"X","amount":"1000","currency":"JPY","fx_rate":160,"paid_by":"Anna")
    {
      %({"amount":"10","paid_by":"Anna"})                                        => "Parameter title is missing.",
      %({"title":"  ","amount":"10","paid_by":"Anna"})                           => "Parameter title is missing.",
      %({#{x},"split":"random"})                                                 => "split must be one of equal, shares, percent, amount.",
      %({#{x},"date":"morgen"})                                                  => %(Invalid date for date: "morgen" (expected YYYY-MM-DD).),
      %({#{x},"date":"2026-02-30"})                                              => %(Invalid date for date: "2026-02-30" (expected YYYY-MM-DD).),
      %({#{x},"date":"1999-12-31"})                                              => %(Invalid date for date: "1999-12-31" (expected YYYY-MM-DD).),
      %({#{x},"currency":"EURO"})                                                => %(currency must be a three-letter ISO code such as USD, not "EURO".),
      %({#{x},"currency":"U1D"})                                                 => %(currency must be a three-letter ISO code such as USD, not "U1D".),
      %({"title":"X","paid_by":"Anna"})                                          => "Parameter amount is missing.",
      %({"title":"X","amount":" ","paid_by":"Anna"})                             => "Parameter amount is missing.",
      %({"title":"X","amount":"1.234","paid_by":"Anna"})                         => %(Invalid amount "1.234" for EUR: at most 2 decimal places),
      %({"title":"X","amount":"1,5","paid_by":"Anna"})                           => %(Invalid amount "1,5" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
      %({"title":"X","amount":"1.000,00","paid_by":"Anna"})                      => %(Invalid amount "1.000,00" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
      %({"title":"X","amount":"-5","paid_by":"Anna"})                            => %(Invalid amount "-5" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
      %({"title":"X","amount":"10 €","paid_by":"Anna"})                          => %(Invalid amount "10 €" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
      %({"title":"X","amount":"1.5","currency":"JPY","paid_by":"Anna"})          => %(Invalid amount "1.5" for JPY: must be a whole number),
      %({"title":"X","amount":"1.2345","currency":"kwd","paid_by":"Anna"})       => %(Invalid amount "1.2345" for KWD: at most 3 decimal places),
      %({"title":"X","amount":"1234567890123456","paid_by":"Anna"})              => %(Invalid amount "1234567890123456" for EUR: too large),
      %({"title":"X","amount":"0","paid_by":"Anna"})                             => "amount must be greater than 0.",
      %({"title":"X","amount":"0.00","paid_by":"Anna"})                          => "amount must be greater than 0.",
      %({"title":"X","amount":0,"paid_by":"Anna"})                               => "amount must be greater than 0.",
      %({"title":"X","amount":true,"paid_by":"Anna"})                            => "Invalid arguments: must be a string or a number",
      %({#{x},"fx_rate":1.1})                                                    => "fx_rate is only for foreign currencies.",
      %({#{x},"currency":"eur","fx_rate":1})                                     => "fx_rate is only for foreign currencies.",
      %({#{x},"currency":"USD","fx_rate":0})                                     => "fx_rate must be greater than 0.",
      %({#{x},"currency":"USD","fx_rate":-1.5})                                  => "fx_rate must be greater than 0.",
      %({#{x},"currency":"XAF"})                                                 => "There is no exchange rate for XAF on 2026-10-03. Ask the user for the rate and pass it as fx_rate.",
      %({#{x},"currency":"USD","date":"2023-06-01"})                             => "There is no exchange rate for USD on 2023-06-01. Ask the user for the rate and pass it as fx_rate.",
      %({"title":"X","amount":"10"})                                             => "Parameter paid_by is missing.",
      %({"title":"X","amount":"10","paid_by":" "})                               => "Parameter paid_by is missing.",
      %({"title":"X","amount":"10","paid_by":"Zoe"})                             => %(Unknown person "Zoe" in paid_by. #{active_people}),
      %({"title":"X","amount":"10","paid_by":"emil"})                            => "Emil is archived and cannot take part in new entries.",
      %({#{x},"category":"Yacht"})                                               => unknown_category,
      %({#{x},"category":"gesundheit"})                                          => "Category Gesundheit is archived.",
      %({#{x},"weights":{"Anna":1}})                                             => "weights are only for split=shares, percent or amount; use participants for an equal split.",
      %({#{x},"split":"shares"})                                                 => "split=shares needs weights (person name → value).",
      %({#{x},"split":"amount","weights":{}})                                    => "split=amount needs weights (person name → value).",
      %({#{x},"split":"percent","participants":["Anna"],"weights":{"Anna":100}}) => "With split=percent, weights name the participants; leave participants out.",
      %({#{x},"participants":["Anna","anna"]})                                   => "Anna appears twice in the split.",
      %({#{x},"participants":["Anna","Zoe"]})                                    => %(Unknown person "Zoe" in the split. #{active_people}),
      %({#{x},"participants":["Emil"]})                                          => "Emil is archived and cannot take part in new entries.",
      %({#{x},"split":"shares","weights":{"Anna":"1.5","Ben":1}})                => %(Invalid value "1.5" for Anna in weights: must be a whole number.),
      %({#{x},"split":"shares","weights":{"Anna":"zwei"}})                       => %(Invalid value "zwei" for Anna in weights: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50.),
      # Weights are checked in the byte order of the names.
      %({#{x},"split":"shares","weights":{"Zoe":1,"Anna":"x"}})              => %(Invalid value "x" for Anna in weights: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50.),
      %({#{x},"split":"shares","weights":{"ben":1,"Anna":1,"Zoe":1}})        => %(Unknown person "Zoe" in the split. #{active_people}),
      %({#{x},"split":"shares","weights":{"anna":2,"Anna":1}})               => "Anna appears twice in the split.",
      %({#{x},"split":"shares","weights":{"Emil":1}})                        => "Emil is archived and cannot take part in new entries.",
      %({#{x},"split":"shares","weights":{"Anna":true}})                     => "Invalid arguments: must be a string or a number",
      %({#{x},"split":"percent","weights":{"Anna":"33.333","Ben":"66.667"}}) => %(Invalid value "33.333" for Anna in weights: at most 2 decimal places.),
      %({#{jpy},"split":"amount","weights":{"Anna":"500.5","Ben":500}})      => %(Invalid value "500.5" for Anna in weights: must be a whole number.),
      # The app's own split rules answer in German.
      %({#{x},"split":"percent","weights":{"Anna":60,"Ben":"30"}}) => "The app refused the entry (message in German): Die Prozente müssen zusammen 100 % ergeben (aktuell 90,00 %).",
      %({#{x},"split":"amount","weights":{"Anna":"5","Ben":"4"}})  => "The app refused the entry (message in German): Die Beträge müssen zusammen 10,00 € ergeben (aktuell 9,00 €).",
      %({#{x},"split":"shares","weights":{"Anna":0,"Ben":"0"}})    => "The app refused the entry (message in German): Die Summe der Anteile muss größer als 0 sein.",
      # The order of the checks.
      %({"amount":"x","paid_by":"Zoe","split":"x","date":"x"})                                 => "Parameter title is missing.",
      %({"title":"X","amount":"x","paid_by":"Zoe","split":"x","date":"x"})                     => "split must be one of equal, shares, percent, amount.",
      %({"title":"X","amount":"x","paid_by":"Zoe","date":"x"})                                 => %(Invalid date for date: "x" (expected YYYY-MM-DD).),
      %({"title":"X","amount":"x","paid_by":"Zoe","category":"Yacht"})                         => %(Invalid amount "x" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
      %({"title":"X","amount":"1","paid_by":"Zoe","category":"Yacht"})                         => %(Unknown person "Zoe" in paid_by. #{active_people}),
      %({"title":"X","amount":"1","paid_by":"Anna","category":"Yacht","participants":["Zoe"]}) => unknown_category,
    }.each do |args, message|
      fail.call(args).should eq message
    end
    MK.decode_fail(user, "create_expense", %({#{x},"titel":"Y"}), "titel")
    MK.decode_fail(user, "create_expense", %({"title":5,"amount":"10","paid_by":"Anna"}), "title")
    MK.decode_fail(user, "create_expense", %({#{x},"participants":"Anna"}), "participants")
    MK.decode_fail(user, "create_expense", %({#{x},"allow_duplicate":"yes"}), "allow_duplicate")
    MK.decode_fail(user, "create_expense", %({#{x},"currency":"USD","fx_rate":"1.2"}), "fx_rate")
    MK.decode_fail(user, "create_expense", %({#{x},"weights":["Anna"]}), "weights")

    E2E::Snapshot.count(world.app.db_path, "SELECT count(*) FROM expenses").should eq 0
  end

  scenario "create_reimbursement: every refusal", world do
    user = world.user
    {
      %({"to":"Anna","amount":"5"})                                  => "Parameter from is missing.",
      %({"from":"Ben","amount":"5"})                                 => "Parameter to is missing.",
      %({"from":"Ben","to":"Anna"})                                  => "Parameter amount is missing.",
      %({"from":"Zoe","to":"Anna","amount":"5"})                     => %(Unknown person "Zoe" in from. #{active_people}),
      %({"from":"Ben","to":"Zoe","amount":"5"})                      => %(Unknown person "Zoe" in to. #{active_people}),
      %({"from":"emil","to":"Anna","amount":"5"})                    => "Emil is archived and cannot take part in new entries.",
      %({"from":"Ben","to":"EMIL","amount":"5"})                     => "Emil is archived and cannot take part in new entries.",
      %({"from":"ben","to":" Ben ","amount":"5"})                    => "from and to must be different people.",
      %({"from":"Ben","to":"Anna","amount":"0"})                     => "amount must be greater than 0.",
      %({"from":"Ben","to":"Anna","amount":"5,50"})                  => %(Invalid amount "5,50" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
      %({"from":"Ben","to":"Anna","amount":"5","date":"31.02.2026"}) => %(Invalid date for date: "31.02.2026" (expected YYYY-MM-DD).),
      %({"from":"Ben","to":"Anna","amount":"5","currency":"XAF"})    => "There is no exchange rate for XAF on 2026-10-03. Ask the user for the rate and pass it as fx_rate.",
      %({"from":"Ben","to":"Anna","amount":"5","fx_rate":2})         => "fx_rate is only for foreign currencies.",
      %({"from":"Ben","to":"Anna","amount":"5","currency":"Dollar"}) => %(currency must be a three-letter ISO code such as USD, not "Dollar".),
      # Date and amount are checked before the people.
      %({"from":"Zoe","to":"Zoe","amount":"x"}) => %(Invalid amount "x" for EUR: use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50),
    }.each do |args, message|
      MK.fail(user, "create_reimbursement", args).should eq message
    end
    MK.decode_fail(user, "create_reimbursement", %({"from":"Ben","to":"Anna","amount":"5","title":"Rückzahlung"}), "title")
    MK.decode_fail(user, "create_reimbursement", %({"from":"Ben","to":"Anna","amount":"5","split":"equal"}), "split")
    MK.decode_fail(user, "create_reimbursement", %({"from":["Ben"],"to":"Anna","amount":"5"}), "from")
    E2E::Snapshot.count(world.app.db_path, "SELECT count(*) FROM expenses").should eq 0
  end

  scenario "create_expense and create_reimbursement store entries", world do
    user = world.user
    note = ->(id : Int32, who : String) { "Created as entry #{id} with #{who} as author. Changing or deleting it is only possible in the app." }
    created = ->(args : String) do
      d = MK.ok(user, args.includes?(%("from")) ? "create_reimbursement" : "create_expense", args)
      d.as_h.keys.sort.should eq %w(created note)
      d
    end

    # Equal split among the given participants; names and categories case-insensitive.
    d = created.call(%({"title":" Rewe ","amount":"30","paid_by":"anna","date":"2026-09-15","category":"lebensmittel","participants":["Anna","ben","CLEO"]}))
    d["created"].should eq MK.json(%({"id":1,"date":"2026-09-15","title":"Rewe","category":"Lebensmittel","paid_by":"Anna","amount":"30.00","amount_cents":3000,"split":"equal","shares":[{"person":"Anna","amount":"10.00","amount_cents":1000},{"person":"Ben","amount":"10.00","amount_cents":1000},{"person":"Cleo","amount":"10.00","amount_cents":1000}]}))
    d["note"].should eq note.call(1, "Anna")
    # Shares, the amount as a JSON number.
    d = created.call(%({"title":"Pizza & Wein","amount":40,"paid_by":"Ben","date":"2026-09-20","category":"Restaurant","split":"shares","weights":{"Anna":1,"Ben":"3"}}))
    d["created"].should eq MK.json(%({"id":2,"date":"2026-09-20","title":"Pizza & Wein","category":"Restaurant","paid_by":"Ben","amount":"40.00","amount_cents":4000,"split":"shares","shares":[{"person":"Anna","amount":"10.00","amount_cents":1000},{"person":"Ben","amount":"30.00","amount_cents":3000}]}))
    d["note"].should eq note.call(2, "Ben")
    # Percent, a German date, notes, no category.
    d = created.call(%({"title":"Kino <3D>","amount":"25.00","paid_by":"Cleo","date":"10.09.2025","split":"percent","weights":{"Anna":"50","Cleo":50},"notes":"Zeile 1\\nZeile \\"2\\""}))
    d["created"].should eq MK.json(%({"id":3,"date":"2025-09-10","title":"Kino <3D>","paid_by":"Cleo","amount":"25.00","amount_cents":2500,"notes":"Zeile 1\\nZeile \\"2\\"","split":"percent","shares":[{"person":"Anna","amount":"12.50","amount_cents":1250},{"person":"Cleo","amount":"12.50","amount_cents":1250}]}))
    MK.text(MK.call(user, "search_expenses", %({"text":"kino"}))).should contain(%("title":"Kino <3D>")) # no HTML escaping
    # A foreign currency with the ECB rate of the date; equal among all active people.
    usd = world.ecb.rate("USD", Time.utc(2026, 9, 30)).to_f
    (10000 / usd).round.should eq 8880
    d = created.call(%({"title":"Hotel","amount":"100","currency":"usd","paid_by":"Dora","date":"2026-09-30","category":"Reisen"}))
    d["created"].should eq MK.json(%({"id":4,"date":"2026-09-30","title":"Hotel","category":"Reisen","paid_by":"Dora","amount":"88.80","amount_cents":8880,"original":"100.00 USD","fx_rate":#{usd},"fx_source":"ezb","split":"equal","shares":[{"person":"Anna","amount":"22.20","amount_cents":2220},{"person":"Ben","amount":"22.20","amount_cents":2220},{"person":"Cleo","amount":"22.20","amount_cents":2220},{"person":"Dora","amount":"22.20","amount_cents":2220}]}))
    # A manual rate; amounts in the foreign currency.
    d = created.call(%({"title":"Sushi","amount":2000,"currency":"JPY","fx_rate":160,"paid_by":"Anna","date":"2026-10-01","split":"amount","weights":{"Anna":"1200","Ben":800}}))
    d["created"].should eq MK.json(%({"id":5,"date":"2026-10-01","title":"Sushi","paid_by":"Anna","amount":"12.50","amount_cents":1250,"original":"2000 JPY","fx_rate":160,"fx_source":"manuell","split":"amount","shares":[{"person":"Anna","amount":"7.50","amount_cents":750},{"person":"Ben","amount":"5.00","amount_cents":500}]}))
    # A reimbursement.
    d = created.call(%({"from":"Ben","to":"anna","amount":"15","date":"2026-10-02","notes":"PayPal"}))
    d["created"].should eq MK.json(%({"id":6,"date":"2026-10-02","title":"Rückzahlung","paid_by":"Ben","amount":"15.00","amount_cents":1500,"reimbursement":true,"recipient":"Anna","notes":"PayPal"}))
    d["note"].should eq note.call(6, "Ben")
    # Today by default; on a Saturday the rate of Friday applies.
    friday = world.ecb.rate("USD", Time.utc(2026, 10, 2)).to_f
    d = created.call(%({"title":"Taxi","amount":"10","currency":"USD","paid_by":"Ben"}))
    d["created"].should eq MK.json(%({"id":7,"date":"2026-10-03","title":"Taxi","paid_by":"Ben","amount":"8.90","amount_cents":890,"original":"10.00 USD","fx_rate":#{friday},"fx_source":"ezb","split":"equal","shares":[{"person":"Anna","amount":"2.23","amount_cents":223},{"person":"Ben","amount":"2.22","amount_cents":222},{"person":"Cleo","amount":"2.22","amount_cents":222},{"person":"Dora","amount":"2.23","amount_cents":223}]}))
    d["note"].should eq note.call(7, "Ben")

    MK.result(MK.rpc(user, "initialize"))["instructions"].as_s.should end_with(
      "\nData overview: 6 expenses and 1 reimbursements dated 2025-09-10 to 2026-10-03. 3 of the expenses (50.0%) have no category. Values of activity.action: expense_created, settings_updated.")
  end

  scenario "balances and balance_history", world do
    user = world.user
    note = "Positive balance = is owed money, negative = owes money. settlements: the transfers needed so that everyone ends at 0."
    MK.ok(user, "balances").should eq MK.json(%({"balances":[{"person":"Anna","balance":"-36.93","balance_cents":-3693,"status":"owes money"},{"person":"Ben","balance":"-5.52","balance_cents":-552,"status":"owes money"},{"person":"Cleo","balance":"-21.92","balance_cents":-2192,"status":"owes money"},{"person":"Dora","balance":"64.37","balance_cents":6437,"status":"is owed money"}],"note":#{note.to_json},"settlements":[{"from":"Anna","to":"Dora","amount":"36.93","amount_cents":3693},{"from":"Cleo","to":"Dora","amount":"21.92","amount_cents":2192},{"from":"Ben","to":"Dora","amount":"5.52","amount_cents":552}]}))
    MK.decode_fail(user, "balances", %({"x":1}), "x")
    MK.text(MK.post(user, MK.body("tools/call", %({"name":"balances","arguments":[]}))), error: true).should_not contain("Internal error")

    rows = ->(key : String, list : Array({String, Array(Int32)}), names : Array(String)) do
      MK.json(list.map { |period, cents|
        {key => period, "balances" => names.zip(cents).map { |n, c| {"person" => n, "balance" => eur(c), "balance_cents" => c, "status" => ""} }}
      }.to_json)
    end
    abcd = %w(Anna Ben Cleo Dora)
    history_note = "Balance after all expenses dated up to the end of each period (in the current period also those dated later this period), positive = is owed money, negative = owes money. Without to, the last row equals the current balances. Computed from the current data by expense date: later edits and deletions apply retroactively."
    d = MK.ok(user, "balance_history")
    d.as_h.keys.sort.should eq %w(interval note period rows)
    {d["interval"], d["period"], d["note"]}.should eq({"month", "2025-09-10 to 2026-10-03", history_note})
    months = d["rows"].as_a
    months.map(&.["month"].as_s).should eq %w(2025-09 2025-10 2025-11 2025-12 2026-01 2026-02 2026-03 2026-04 2026-05 2026-06 2026-07 2026-08 2026-09 2026-10)
    opening = [-1250, 0, 1250, 0]
    d["rows"].should eq rows.call("month", months.map(&.["month"].as_s).map { |m|
      {m, m < "2026-09" ? opening : (m == "2026-09" ? [-2470, -2220, -1970, 6660] : [-3693, -552, -2192, 6437])}
    }, abcd)

    d = MK.ok(user, "balance_history", %({"to":"2026-09-20"}))
    d["period"].should eq "2025-09-10 to 2026-09-20"
    d["rows"].as_a.size.should eq 13
    d["rows"].as_a.last.should eq rows.call("month", [{"2026-09", [-2470, -2220, -1970, 6660]}], abcd)[0]

    d = MK.ok(user, "balance_history", %({"interval":"year","person":"cleo"}))
    {d["interval"], d["period"]}.should eq({"year", "2025-09-10 to 2026-10-03"})
    d["rows"].should eq rows.call("year", [{"2025", [1250]}, {"2026", [-2192]}], ["Cleo"])
    # Weeks; the expenses before the first period are the opening balance.
    d = MK.ok(user, "balance_history", %({"interval":"week","from":"2026-09-14","to":"30.09.2026"}))
    d["period"].should eq "2026-09-14 to 2026-09-30"
    d["rows"].should eq rows.call("week", [{"2026-W38", [-250, 0, 250, 0]}, {"2026-W39", [-250, 0, 250, 0]}, {"2026-W40", [-3693, -552, -2192, 6437]}], abcd)
    # Archived Emil shows up when asked for.
    MK.ok(user, "balance_history", %({"interval":"year","person":"Emil","from":"2026-01-01"}))["rows"].should eq rows.call("year", [{"2026", [0]}], ["Emil"])

    {
      %({"interval":"day"})                      => "interval must be one of month, week, year.",
      %({"interval":"Month"})                    => "interval must be one of month, week, year.",
      %({"person":"Zoe"})                        => %(Unknown person "Zoe". #{all_people}),
      %({"interval":"week","from":"2000-01-01"}) => "That is 1397 periods, at most 500 are possible. Please narrow down from/to or choose a longer interval.",
      %({"from":"1900-01-01"})                   => %(Invalid date for from: "1900-01-01" (expected YYYY-MM-DD).),
      %({"to":"2026-13-01"})                     => %(Invalid date for to: "2026-13-01" (expected YYYY-MM-DD).),
      %({"from":"2026-10-01","to":"2026-09-01"}) => %("to" (2026-09-01) is before "from" (2026-10-01).),
    }.each { |args, message| MK.fail(user, "balance_history", args).should eq message }
    MK.decode_fail(user, "balance_history", %({"interval":5}), "interval")
  end

  scenario "search_expenses", world do
    user = world.user
    compact = {
      1 => %({"id":1,"date":"2026-09-15","title":"Rewe","category":"Lebensmittel","paid_by":"Anna","amount":"30.00","amount_cents":3000}),
      2 => %({"id":2,"date":"2026-09-20","title":"Pizza & Wein","category":"Restaurant","paid_by":"Ben","amount":"40.00","amount_cents":4000}),
      3 => %({"id":3,"date":"2025-09-10","title":"Kino <3D>","paid_by":"Cleo","amount":"25.00","amount_cents":2500}),
      4 => %({"id":4,"date":"2026-09-30","title":"Hotel","category":"Reisen","paid_by":"Dora","amount":"88.80","amount_cents":8880}),
      5 => %({"id":5,"date":"2026-10-01","title":"Sushi","paid_by":"Anna","amount":"12.50","amount_cents":1250}),
      6 => %({"id":6,"date":"2026-10-02","title":"Rückzahlung","paid_by":"Ben","amount":"15.00","amount_cents":1500,"reimbursement":true,"recipient":"Anna"}),
      7 => %({"id":7,"date":"2026-10-03","title":"Taxi","paid_by":"Ben","amount":"8.90","amount_cents":890}),
    }
    expect = ->(args : String, ids : Array(Int32), matches : Int32, total : Int32, extra : String) do
      d = MK.ok(user, "search_expenses", args)
      d["expenses"].should eq MK.json("[" + ids.map { |i| compact[i] }.join(",") + "]")
      expected = %({"expenses":#{d["expenses"].to_json},"matches":#{matches},"shown":#{ids.size},"total":"#{eur(total)}","total_cents":#{total},"truncated":#{matches > ids.size}#{extra}})
      d.should eq MK.json(expected)
    end
    expect.call("{}", [7, 5, 4, 2, 1, 3], 6, 20520, "")
    expect.call(%({"limit":1}), [7], 6, 20520, "")
    expect.call(%({"reimbursements":"only"}), [6], 1, 1500, "")
    expect.call(%({"reimbursements":" include ","sort":"date_asc"}), [3, 1, 2, 4, 5, 6, 7], 7, 22020, "")
    expect.call(%({"text":"RÜCKZAHLUNG","reimbursements":"only"}), [6], 1, 1500, "")
    expect.call(%({"text":"rückzahlung"}), [] of Int32, 0, 0, "")
    expect.call(%({"text":["sushi","ZEILE"]}), [5, 3], 2, 3750, "")
    expect.call(%({"text":"pizza & w"}), [2], 1, 4000, "")
    expect.call(%({"text":null}), [7, 5, 4, 2, 1, 3], 6, 20520, "")
    expect.call(%({"category":"none"}), [7, 5, 3], 3, 4640, "")
    expect.call(%({"category":"No Category"}), [7, 5, 3], 3, 4640, "")
    expect.call(%({"category":"REISEN"}), [4], 1, 8880, "")
    expect.call(%({"category":"gesundheit"}), [] of Int32, 0, 0, "")
    expect.call(%({"min_amount":12.5,"max_amount":30,"sort":"amount_asc"}), [5, 3, 1], 3, 6750, "")
    expect.call(%({"min_amount":40}), [4, 2], 2, 12880, "")
    expect.call(%({"max_amount":8.9}), [7], 1, 890, "")
    expect.call(%({"from":"2026-09-15","to":"30.09.2026","sort":"date_asc"}), [1, 2, 4], 3, 15880, "")
    expect.call(%({"from":"2026-10-01","to":"2026-10-01"}), [5], 1, 1250, "")
    expect.call(%({"paid_by":"Anna","involved":"ben"}), [5, 1], 2, 4250, %(,"person_share":{"amount":"15.00","amount_cents":1500,"person":"Ben"}))
    expect.call(%({"involved":"Dora"}), [7, 4], 2, 9770, %(,"person_share":{"amount":"24.43","amount_cents":2443,"person":"Dora"}))
    expect.call(%({"person":"Ben","sort":"amount_desc","limit":2}), [4, 2], 5, 18020, %(,"person_share":{"amount":"69.42","amount_cents":6942,"person":"Ben"}))
    expect.call(%({"person":"Emil"}), [] of Int32, 0, 0, %(,"person_share":{"amount":"0.00","amount_cents":0,"person":"Emil"}))
    expect.call(%({"paid_by":"Ben","reimbursements":"include"}), [7, 6, 2], 3, 6390, "")

    # detail=full: notes, foreign currency, split and shares.
    d = MK.ok(user, "search_expenses", %({"detail":"full","reimbursements":"include","to":"2026-10-02","from":"2026-09-30"}))
    d["expenses"].should eq MK.json(%([{"id":6,"date":"2026-10-02","title":"Rückzahlung","paid_by":"Ben","amount":"15.00","amount_cents":1500,"reimbursement":true,"recipient":"Anna","notes":"PayPal"},{"id":5,"date":"2026-10-01","title":"Sushi","paid_by":"Anna","amount":"12.50","amount_cents":1250,"original":"2000 JPY","fx_rate":160,"fx_source":"manuell","split":"amount","shares":[{"person":"Anna","amount":"7.50","amount_cents":750},{"person":"Ben","amount":"5.00","amount_cents":500}]},{"id":4,"date":"2026-09-30","title":"Hotel","category":"Reisen","paid_by":"Dora","amount":"88.80","amount_cents":8880,"original":"100.00 USD","fx_rate":#{world.ecb.rate("USD", Time.utc(2026, 9, 30))},"fx_source":"ezb","split":"equal","shares":[{"person":"Anna","amount":"22.20","amount_cents":2220},{"person":"Ben","amount":"22.20","amount_cents":2220},{"person":"Cleo","amount":"22.20","amount_cents":2220},{"person":"Dora","amount":"22.20","amount_cents":2220}]}]))
    MK.ok(user, "search_expenses", %({"detail":"full","text":"kino"}))["expenses"][0].should eq MK.json(%({"id":3,"date":"2025-09-10","title":"Kino <3D>","paid_by":"Cleo","amount":"25.00","amount_cents":2500,"notes":"Zeile 1\\nZeile \\"2\\"","split":"percent","shares":[{"person":"Anna","amount":"12.50","amount_cents":1250},{"person":"Cleo","amount":"12.50","amount_cents":1250}]}))
    MK.ok(user, "search_expenses", %({"detail":"compact","text":"Rewe"}))["expenses"][0].should eq MK.json(compact[1])

    {
      %({"limit":1000})                          => "limit must be between 1 and 500.",
      %({"limit":-1})                            => "limit must be between 1 and 500.",
      %({"text":5})                              => "Invalid arguments: must be a string or a list of strings",
      %({"text":["a",1]})                        => "Invalid arguments: must be a string or a list of strings",
      %({"from":"yesterday"})                    => %(Invalid date for from: "yesterday" (expected YYYY-MM-DD).),
      %({"to":"2026-02-30"})                     => %(Invalid date for to: "2026-02-30" (expected YYYY-MM-DD).),
      %({"from":"2101-01-01"})                   => %(Invalid date for from: "2101-01-01" (expected YYYY-MM-DD).),
      %({"from":"2026-9-1"})                     => %(Invalid date for from: "2026-9-1" (expected YYYY-MM-DD).),
      %({"from":"2026-09-02","to":"2026-09-01"}) => %("to" (2026-09-01) is before "from" (2026-09-02).),
      %({"from":"02.09.2026","to":"1.9.2026"})   => %("to" (2026-09-01) is before "from" (2026-09-02).),
      %({"person":"Zoe"})                        => %(Unknown person "Zoe". #{all_people}),
      %({"paid_by":" zoe "})                     => %(Unknown person "zoe". #{all_people}),
      %({"involved":"An"})                       => %(Unknown person "An". #{all_people}),
      %({"category":"Yacht"})                    => unknown_category,
      %({"reimbursements":"maybe"})              => %(reimbursements must be "exclude", "include" or "only".),
      %({"sort":"random"})                       => "sort must be one of date_desc, date_asc, amount_desc, amount_asc.",
      %({"detail":"verbose"})                    => %(detail must be "compact" or "full".),
      %({"min_amount":-1})                       => "min_amount must be an amount in euros of at least 0.",
      %({"max_amount":-0.5})                     => "max_amount must be an amount in euros of at least 0.",
      %({"min_amount":2e12})                     => "min_amount must be an amount in euros of at least 0.",
      %({"max_amount":0})                        => "max_amount must be greater than 0.",
      %({"max_amount":0.004})                    => "max_amount must be greater than 0.",
      %({"min_amount":20,"max_amount":10})       => "min_amount (20.00) is greater than max_amount (10.00).",
      %({"min_amount":10.01,"max_amount":10})    => "min_amount (10.01) is greater than max_amount (10.00).",
      # Checked in this order.
      %({"from":"x","person":"Zoe","sort":"x"}) => %(Invalid date for from: "x" (expected YYYY-MM-DD).),
      %({"person":"Zoe","category":"Yacht"})    => unknown_category,
      %({"person":"Zoe","sort":"x","limit":0})  => %(Unknown person "Zoe". #{all_people}),
    }.each { |args, message| MK.fail(user, "search_expenses", args).should eq message }
    MK.decode_fail(user, "search_expenses", %({"von":"2026-01-01"}), "von")
    MK.decode_fail(user, "search_expenses", %({"limit":"5"}), "limit")
    MK.decode_fail(user, "search_expenses", %({"limit":0.5}), "limit")
    MK.decode_fail(user, "search_expenses", %({"limit":5.0}), "limit")
    MK.decode_fail(user, "search_expenses", %({"min_amount":"5"}), "min_amount")
    MK.decode_fail(user, "search_expenses", %({"person":["Anna"]}), "person")
  end

  scenario "statistics", world do
    user = world.user
    base = "Reimbursements and deleted expenses are not included. count = number of expenses."
    person_note = " amount = the person's share (consumption), paid = what they paid for the group."
    compare_note = " previous = same group one year earlier, change = amount − previous, change_percent relative to previous (missing if previous is 0)."
    total = "total amounts of the expenses"

    MK.ok(user, "statistics", %({"group_by":"category"})).should eq MK.json(%({"group_by":"category","note":"#{base}","period":"all time","perspective":"#{total}","rows":[{"category":"Reisen","count":1,"amount":"88.80","amount_cents":8880},{"category":"No category","count":3,"amount":"46.40","amount_cents":4640},{"category":"Restaurant","count":1,"amount":"40.00","amount_cents":4000},{"category":"Lebensmittel","count":1,"amount":"30.00","amount_cents":3000}],"rows_total":4,"total":"205.20","total_cents":20520,"truncated":false}))
    d = MK.ok(user, "statistics", %({"group_by":" category ","limit":2}))
    {d["rows"].as_a.map(&.["category"].as_s), d["rows_total"], d["truncated"], d["total_cents"]}.should eq({["Reisen", "No category"], 4, true, 20520})
    MK.ok(user, "statistics", %({"group_by":"person"})).should eq MK.json(%({"group_by":"person","note":"#{base}#{person_note}","period":"all time","perspective":"#{total}","rows":[{"person":"Ben","count":5,"amount":"69.42","amount_cents":6942,"paid":"48.90","paid_cents":4890},{"person":"Anna","count":6,"amount":"64.43","amount_cents":6443,"paid":"42.50","paid_cents":4250},{"person":"Cleo","count":4,"amount":"46.92","amount_cents":4692,"paid":"25.00","paid_cents":2500},{"person":"Dora","count":2,"amount":"24.43","amount_cents":2443,"paid":"88.80","paid_cents":8880}],"rows_total":4,"total":"205.20","total_cents":20520,"truncated":false}))
    MK.ok(user, "statistics", %({"group_by":"person","category":"none"}))["rows"].should eq MK.json(%([{"person":"Anna","count":3,"amount":"22.23","amount_cents":2223,"paid":"12.50","paid_cents":1250},{"person":"Cleo","count":2,"amount":"14.72","amount_cents":1472,"paid":"25.00","paid_cents":2500},{"person":"Ben","count":2,"amount":"7.22","amount_cents":722,"paid":"8.90","paid_cents":890},{"person":"Dora","count":1,"amount":"2.23","amount_cents":223,"paid":"0.00","paid_cents":0}]))
    MK.ok(user, "statistics", %({"group_by":"year"}))["rows"].should eq MK.json(%([{"year":"2025","count":1,"amount":"25.00","amount_cents":2500},{"year":"2026","count":5,"amount":"180.20","amount_cents":18020}]))
    # Weeks: ISO weeks, gaps filled with 0, never beyond today.
    MK.ok(user, "statistics", %({"group_by":"week","from":"2026-09-14"})).should eq MK.json(%({"group_by":"week","note":"#{base}","period":"from 2026-09-14","perspective":"#{total}","rows":[{"week":"2026-W38","count":2,"amount":"70.00","amount_cents":7000},{"week":"2026-W39","count":0,"amount":"0.00","amount_cents":0},{"week":"2026-W40","count":3,"amount":"110.20","amount_cents":11020}],"rows_total":3,"total":"180.20","total_cents":18020,"truncated":false}))
    d = MK.ok(user, "statistics", %({"group_by":"week","from":"2026-09-28","to":"2026-12-31","share_of":"Dora"}))
    {d["period"], d["perspective"], d["rows"]}.should eq({"2026-09-28 to 2026-12-31", "only the share of Dora", MK.json(%([{"week":"2026-W40","count":2,"amount":"24.43","amount_cents":2443}]))})
    d = MK.ok(user, "statistics", %({"group_by":"month","from":"2026-06-15","to":"2026-08-31"}))
    {d["rows"].as_a.map(&.["month"].as_s), d["rows"].as_a.map(&.["amount_cents"]), d["total_cents"]}.should eq({["2026-06", "2026-07", "2026-08"], [0, 0, 0], 0})
    MK.ok(user, "statistics", %({"group_by":"title","from":"2025-09-01","to":"2026-09-30","share_of":"anna"})).should eq MK.json(%({"group_by":"title","note":"#{base}","period":"2025-09-01 to 2026-09-30","perspective":"only the share of Anna","rows":[{"title":"Hotel","count":1,"amount":"22.20","amount_cents":2220},{"title":"Kino <3D>","count":1,"amount":"12.50","amount_cents":1250},{"title":"Pizza & Wein","count":1,"amount":"10.00","amount_cents":1000},{"title":"Rewe","count":1,"amount":"10.00","amount_cents":1000}],"rows_total":4,"total":"54.70","total_cents":5470,"truncated":false}))
    MK.ok(user, "statistics", %({"group_by":"category_month","text":["hotel","SUSHI"]}))["rows"].should eq MK.json(%([{"category":"Reisen","month":"2026-09","count":1,"amount":"88.80","amount_cents":8880},{"category":"No category","month":"2026-10","count":1,"amount":"12.50","amount_cents":1250}]))
    MK.ok(user, "statistics", %({"group_by":"month","category":"Restaurant"}))["rows"].should eq MK.json(%([{"month":"2026-09","count":1,"amount":"40.00","amount_cents":4000},{"month":"2026-10","count":0,"amount":"0.00","amount_cents":0}]))

    # compare=previous_year by month and by category.
    MK.ok(user, "statistics", %({"group_by":"month","from":"2026-08-01","compare":"previous_year"})).should eq MK.json(%({"group_by":"month","note":"#{base}#{compare_note}","period":"from 2026-08-01","perspective":"#{total}","previous_period":"each month one year earlier","previous_total":"25.00","previous_total_cents":2500,"rows":[{"month":"2026-08","count":0,"amount":"0.00","amount_cents":0,"previous":"0.00","previous_cents":0,"change":"0.00","change_cents":0},{"month":"2026-09","count":3,"amount":"158.80","amount_cents":15880,"previous":"25.00","previous_cents":2500,"change":"133.80","change_cents":13380,"change_percent":535.2},{"month":"2026-10","count":2,"amount":"21.40","amount_cents":2140,"previous":"0.00","previous_cents":0,"change":"21.40","change_cents":2140}],"rows_total":3,"total":"180.20","total_cents":18020,"truncated":false}))
    MK.ok(user, "statistics", %({"group_by":"category","from":"2026-09-01","to":"2026-09-30","compare":" previous_year "})).should eq MK.json(%({"group_by":"category","note":"#{base}#{compare_note}","period":"2026-09-01 to 2026-09-30","perspective":"#{total}","previous_period":"2025-09-01 to 2025-09-30","previous_total":"25.00","previous_total_cents":2500,"rows":[{"category":"Reisen","count":1,"amount":"88.80","amount_cents":8880,"previous":"0.00","previous_cents":0,"change":"88.80","change_cents":8880},{"category":"Restaurant","count":1,"amount":"40.00","amount_cents":4000,"previous":"0.00","previous_cents":0,"change":"40.00","change_cents":4000},{"category":"Lebensmittel","count":1,"amount":"30.00","amount_cents":3000,"previous":"0.00","previous_cents":0,"change":"30.00","change_cents":3000},{"category":"No category","count":0,"amount":"0.00","amount_cents":0,"previous":"25.00","previous_cents":2500,"change":"-25.00","change_cents":-2500,"change_percent":-100}],"rows_total":4,"total":"158.80","total_cents":15880,"truncated":false}))
    # Without to, the period ends today.
    d = MK.ok(user, "statistics", %({"group_by":"person","from":"2026-09-10","compare":"previous_year","share_of":"Cleo"}))
    {d["period"], d["previous_period"], d["perspective"]}.should eq({"2026-09-10 to 2026-10-03", "2025-09-10 to 2025-10-03", "only the share of Cleo"})
    d["rows"].should eq MK.json(%([{"person":"Cleo","count":3,"amount":"34.42","amount_cents":3442,"paid":"0.00","paid_cents":0,"previous":"12.50","previous_cents":1250,"change":"21.92","change_cents":2192,"change_percent":175.4}]))
    d = MK.ok(user, "statistics", %({"group_by":"week","from":"2026-09-07","to":"2026-09-20","compare":"previous_year"}))
    {d["previous_period"], d["previous_total_cents"]}.should eq({"each week one year earlier", 2500})
    d["rows"].should eq MK.json(%([{"week":"2026-W37","count":0,"amount":"0.00","amount_cents":0,"previous":"25.00","previous_cents":2500,"change":"-25.00","change_cents":-2500,"change_percent":-100},{"week":"2026-W38","count":2,"amount":"70.00","amount_cents":7000,"previous":"0.00","previous_cents":0,"change":"70.00","change_cents":7000}]))

    {
      %({})                                                                  => "group_by must be one of category, title, year, month, week, person, category_month.",
      %({"group_by":"day"})                                                  => "group_by must be one of category, title, year, month, week, person, category_month.",
      %({"group_by":"Month"})                                                => "group_by must be one of category, title, year, month, week, person, category_month.",
      %({"group_by":"month","compare":"last_year"})                          => %(compare must be "previous_year".),
      %({"group_by":"title","compare":"previous_year"})                      => "compare=previous_year with group_by=title needs from (and optionally to): the period to compare.",
      %({"group_by":"category","compare":"previous_year","to":"2026-09-30"}) => "compare=previous_year with group_by=category needs from (and optionally to): the period to compare.",
      %({"group_by":"person","compare":"previous_year","from":"2026-12-01"}) => "from (2026-12-01) is in the future; compare=previous_year needs a period up to today or an explicit to.",
      %({"group_by":"month","limit":501})                                    => "limit must be between 1 and 500.",
      %({"group_by":"month","share_of":"Zoe"})                               => %(Unknown person "Zoe". #{all_people}),
      %({"group_by":"month","category":"Yacht"})                             => unknown_category,
      %({"group_by":"month","from":"2026-10-02","to":"2026-10-01"})          => %("to" (2026-10-01) is before "from" (2026-10-02).),
      %({"group_by":"month","from":"heute"})                                 => %(Invalid date for from: "heute" (expected YYYY-MM-DD).),
      %({"group_by":"month","text":7})                                       => "Invalid arguments: must be a string or a list of strings",
    }.each { |args, message| MK.fail(user, "statistics", args).should eq message }
    MK.decode_fail(user, "statistics", %({"group_by":"month","limit":"5"}), "limit")
    MK.decode_fail(user, "statistics", %({"group_by":"month","per":"Anna"}), "per")
  end

  scenario "activity", world do
    user = world.user
    at = "2026-10-03T12:00:00+02:00"
    settings = ["Person „Anna“ hinzugefügt", "Person „Ben“ hinzugefügt", "Person „Cleo“ hinzugefügt", "Person „Dora“ hinzugefügt",
                "Person „Emil“ hinzugefügt", "Person „Emil“ archiviert", "Kategorie „Gesundheit“ archiviert"]
    created = [{"Anna", "Rewe", 3000}, {"Ben", "Pizza & Wein", 4000}, {"Cleo", "Kino <3D>", 2500}, {"Dora", "Hotel", 8880},
               {"Anna", "Sushi", 1250}, {"Ben", "Rückzahlung", 1500}, {"Ben", "Taxi", 890}]
    entries = settings.map_with_index { |t, i| {"id" => i + 1, "at" => at, "actor" => "Anna", "action" => "settings_updated", "text" => t} }
    entries += created.map_with_index do |(actor, title, cents), i|
      {"id" => i + 8, "at" => at, "actor" => actor, "action" => "expense_created", "expense_id" => i + 1, "title" => title, "amount" => eur(cents), "amount_cents" => cents}
    end
    entries.reverse!
    none = [] of Hash(String, Int32 | String)
    page = ->(list : Array(Hash(String, Int32 | String)), more : Bool, note : String?) do
      MK.json(%({"entries":#{list.to_json},"more":#{more},"shown":#{list.size}#{note ? %(,"note":#{note.to_json}) : ""}}))
    end
    by_id = ->(ids : Array(Int32)) { ids.map { |id| entries.find { |e| e["id"] == id }.not_nil! } }

    MK.ok(user, "activity").should eq page.call(entries, false, nil)
    MK.ok(user, "activity", %({"limit":3})).should eq page.call(by_id.call([14, 13, 12]), true, "There are older entries: call again with before_id=12.")
    MK.ok(user, "activity", %({"limit":3,"before_id":12})).should eq page.call(by_id.call([11, 10, 9]), true, "There are older entries: call again with before_id=9.")
    MK.ok(user, "activity", %({"limit":2,"person":"ben"})).should eq page.call(by_id.call([14, 13]), true, "There are older entries: call again with before_id=13.")
    MK.ok(user, "activity", %({"person":"Ben","before_id":13})).should eq page.call(by_id.call([9]), false, nil)
    MK.ok(user, "activity", %({"expense_id":4})).should eq page.call(by_id.call([11]), false, nil)
    MK.ok(user, "activity", %({"action":" settings_updated ","limit":7})).should eq page.call(by_id.call([7, 6, 5, 4, 3, 2, 1]), false, nil)
    MK.ok(user, "activity", %({"action":"expense_deleted"})).should eq page.call(none, false, nil)
    MK.ok(user, "activity", %({"person":"Emil"})).should eq page.call(none, false, nil)
    MK.ok(user, "activity", %({"from":"2026-10-04"})).should eq page.call(none, false, nil)
    MK.ok(user, "activity", %({"to":"02.10.2026"})).should eq page.call(none, false, nil)
    MK.ok(user, "activity", %({"from":"03.10.2026","to":"2026-10-03","limit":500}))["shown"].should eq 14
    MK.ok(user, "activity", %({"limit":0}))["shown"].should eq 14

    {
      %({"expense_id":-1})                       => "expense_id and before_id must be positive.",
      %({"before_id":-5})                        => "expense_id and before_id must be positive.",
      %({"limit":501})                           => "limit must be between 1 and 500.",
      %({"limit":-1})                            => "limit must be between 1 and 500.",
      %({"person":"Zoe"})                        => %(Unknown person "Zoe". #{all_people}),
      %({"from":"gestern"})                      => %(Invalid date for from: "gestern" (expected YYYY-MM-DD).),
      %({"from":"2026-10-03","to":"2026-10-02"}) => %("to" (2026-10-02) is before "from" (2026-10-03).),
    }.each { |args, message| MK.fail(user, "activity", args).should eq message }
    MK.decode_fail(user, "activity", %({"expense_id":1.5}), "expense_id")
    MK.decode_fail(user, "activity", %({"before_id":"9"}), "before_id")
    MK.decode_fail(user, "activity", %({"actor":"Anna"}), "actor")
  end

  scenario "schema", world do
    user = world.user
    r = MK.call(user, "schema")
    text = MK.text(r)
    text.should start_with(MK.today_line("2026-10-03", "Saturday") + "\n\nDatabase of Zipfelkasse (SQLite). A single group.\nConventions: amounts are INTEGER in euro cents")
    text.should contain("YNAB tables (credentials) are not visible via MCP.\n")
    text.should contain("SELECT coalesce(c.name, 'No category') AS category, sum(x.amount_cents) / 100.0 AS euros\n")
    text.should contain("GROUP BY 1 ORDER BY 2 DESC;\n\n#{people_line}\n")
    text.should end_with("CREATE INDEX activity_expense ON activity (expense_id);\n")
    text.lines.select(&.starts_with?("CREATE TABLE ")).map(&.split[2]).should eq %w(participants categories recurring expenses expense_shares activity settings fx_rates)
    text.downcase.should_not contain("create table ynab")
    text.should contain("CREATE TABLE expenses (\n    id                    INTEGER PRIMARY KEY,\n")
    MK.decode_fail(user, "schema", %({"table":"expenses"}), "table")
  end

  scenario "sql_query: a read-only sandbox", world do
    user = world.user
    rows = ->(query : String) { MK.ok(user, "sql_query", {query: query}.to_json) }
    refused = ->(query : String) { MK.fail(user, "sql_query", {query: query}.to_json) }

    rows.call("SELECT name, archived_at IS NOT NULL AS archived FROM participants ORDER BY id").should eq MK.json(%({"columns":["name","archived"],"row_count":5,"rows":[["Anna",0],["Ben",0],["Cleo",0],["Dora",0],["Emil",1]],"truncated":false}))
    rows.call("  with s as (select paid_by, sum(amount_cents) as c from expenses where deleted_at is null group by paid_by)\n select p.name, s.c from s join participants p on p.id = s.paid_by order by s.c desc")["rows"].should eq MK.json(%([["Dora",8880],["Ben",6390],["Anna",4250],["Cleo",2500]]))
    rows.call("SELECT 1 AS one; -- done")["rows"].should eq MK.json("[[1]]")
    rows.call("/* a; b */ SELECT ';' AS x;;")["rows"].should eq MK.json(%([[";"]]))
    rows.call(%(SELECT 'it''s; fine' AS "a;b", [c;d] FROM (SELECT 1 AS [c;d])))["rows"].should eq MK.json(%([["it's; fine",1]]))
    rows.call("SELECT 1, 1, 'a' AS x, 'b' AS x").should eq MK.json(%({"columns":["1","1","x","x"],"row_count":1,"rows":[[1,1,"a","b"]],"truncated":false}))
    rows.call("SELECT * FROM participants WHERE 0").should eq MK.json(%({"columns":["id","name","created_at","archived_at"],"row_count":0,"rows":[],"truncated":false}))
    # Value types: integers, reals, text (also JSON text), NULL and blobs.
    d = rows.call("SELECT 42 AS i, 2.5 AS r, 0.1 + 0.2 AS s, 1e30 AS big, 'a<&>b' AS t, NULL AS n, x'00ff' AS b, json_object('a', 1) AS j, 9007199254740993 AS l")
    d["columns"].should eq MK.json(%(["i","r","s","big","t","n","b","j","l"]))
    d["rows"].should eq MK.json(%([[42,2.5,0.30000000000000004,1e30,"a<&>b",null,"[BLOB, 2 Bytes]","{\\"a\\":1}",9007199254740993]]))
    rows.call("SELECT zipfelkasse_fold('BÄCKER Straße') AS f, zipfelkasse_fold(NULL) AS n, zipfelkasse_fold(42) AS i")["rows"].should eq MK.json(%([["bäcker strasse",null,42]]))
    rows.call("SELECT title FROM expenses WHERE instr(zipfelkasse_fold(title), 'rückzahlung') > 0")["rows"].should eq MK.json(%([["Rückzahlung"]]))
    # Long texts are cut at 2000 characters.
    d = rows.call("SELECT length(substr(hex(zeroblob(2500)), 1, 5000)) AS n, substr(hex(zeroblob(2500)), 1, 5000) AS t, 'ä' || substr(hex(zeroblob(1500)), 1, 2999) AS u")
    d["rows"][0][0].should eq 5000
    d["rows"][0][1].should eq "0" * 2000
    d["rows"][0][2].should eq "ä" + "0" * 1999
    # At most 500 rows, in the query's order.
    d = rows.call("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 1000) SELECT i FROM n ORDER BY i DESC")
    d.as_h.keys.sort.should eq %w(columns note row_count rows truncated)
    {d["row_count"], d["truncated"], d["rows"][0], d["rows"][499]}.should eq({500, true, MK.json("[1000]"), MK.json("[501]")})
    d["rows"].as_a.size.should eq 500
    d["note"].should eq "There are more than 500 rows; only the first 500 are included. Please aggregate or narrow down with WHERE/LIMIT."
    d = rows.call("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 500) SELECT i FROM n")
    {d["row_count"], d["truncated"], d.as_h.has_key?("note")}.should eq({500, false, false})

    only_select = "Only a single read-only query is allowed (SELECT … or WITH … SELECT …)."
    single = %(Please send only a single query (no second statement after ";").)
    ["DELETE FROM expenses", "INSERT INTO settings VALUES ('a', 'b')", "UPDATE participants SET name = 'x'",
     "DROP TABLE expenses", "ATTACH DATABASE 'x.db' AS x", "PRAGMA query_only = OFF", "PRAGMA table_info(expenses)",
     "pragma writable_schema = 1", "VACUUM INTO '/tmp/x.db'", "CREATE TABLE x (a)", "REPLACE INTO settings VALUES ('a', 'b')",
     "EXPLAIN SELECT 1", "(SELECT 1)", "-- nur ein Kommentar", "/* SELECT 1 */", "SELEKT 1", "BEGIN", "DETACH src"].each do |q|
      refused.call(q).should eq only_select
    end
    ["SELECT 1; SELECT 2", "SELECT 1; DELETE FROM expenses", "SELECT 'a'; PRAGMA query_only = OFF", "SELECT 1 /* ; */; ATTACH 'x' AS y",
     "WITH x AS (SELECT 1) SELECT * FROM x; DROP TABLE expenses"].each do |q|
      refused.call(q).should eq single
    end
    refused.call("SELECT 1 \u0000").should eq "The query contains a NUL character."
    refused.call("").should eq "Parameter query is missing."
    refused.call(" \n\t").should eq "Parameter query is missing."
    MK.fail(user, "sql_query", "{}").should eq "Parameter query is missing."
    # Writes disguised as WITH return no columns.
    refused.call("WITH d AS (SELECT 1) DELETE FROM expenses").should eq "The query returns no columns. Only SELECT or WITH … SELECT is allowed."
    refused.call("WITH d AS (SELECT 1) INSERT INTO settings SELECT 'a', 'b' FROM d").should eq "The query returns no columns. Only SELECT or WITH … SELECT is allowed."
    # SQLite's own errors (the exact text belongs to SQLite).
    {
      "SELECT * FROM doesnotexist"        => "no such table: doesnotexist",
      "SELECT * FROM ynab_config"         => "no such table: ynab_config",
      "SELECT * FROM main.ynab_config"    => "no such table: main.ynab_config",
      "SELECT * FROM src.expenses"        => "no such table: src.expenses",
      "SELECT * FROM temp.expenses"       => "no such table: temp.expenses",
      "SELECT FROM"                       => "syntax error",
      "SELECT nosuchcolumn FROM expenses" => "no such column: nosuchcolumn",
    }.each do |q, msg|
      m = refused.call(q)
      m.should start_with("SQL error: ")
      m.should contain(msg)
    end
    # The YNAB tables do not exist in the copy.
    rows.call("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name")["rows"].as_a.map(&.[0].as_s).should eq %w(activity categories expense_shares expenses fx_rates participants recurring settings)
    rows.call("SELECT count(*) FROM pragma_table_list WHERE name LIKE '%ynab%'")["rows"].should eq MK.json("[[0]]")
    rows.call("SELECT count(*) FROM settings WHERE key LIKE 'ynab%'")["rows"].should eq MK.json("[[0]]")
    rows.call("SELECT count(*) AS n FROM pragma_database_list")["rows"].should eq MK.json("[[1]]")
    # Nothing has changed.
    rows.call("SELECT count(*) FROM expenses")["rows"].should eq MK.json("[[7]]")
    db = world.app.db_path
    E2E::Snapshot.count(db, "SELECT count(*) FROM expenses").should eq 7
    E2E::Snapshot.count(db, "SELECT count(*) FROM settings WHERE key = 'a'").should eq 0
    E2E::Snapshot.count(db, "SELECT count(*) FROM participants WHERE name = 'x'").should eq 0
    MK.decode_fail(user, "sql_query", %({"query":"SELECT 1","limit":5}), "limit")
    MK.decode_fail(user, "sql_query", %({"query":["SELECT 1"]}), "query")

    # A slow query is aborted after 5 seconds.
    t = Time.instant
    r = user.tool("sql_query", {"query" => JSON::Any.new("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000000000) SELECT count(*) FROM n")})
    took = Time.instant - t
    MK.text(r, error: true).should eq "The query was aborted after 5 s. Please narrow it down (WHERE, LIMIT) or simplify it."
    took.should be >= 4.5.seconds
    took.should be < 12.seconds
    # The server is still fine afterwards.
    rows.call("SELECT 1 AS ok")["rows"].should eq MK.json("[[1]]")
  end

  scenario "duplicates, more entries and the web app", world do
    user = world.user
    dup = ->(id : Int32, what : String) { "This looks like a duplicate of entry #{id} (#{what}). Ask the user; if it really is a second one, call again with allow_duplicate=true." }
    note = ->(id : Int32, who : String) { "Created as entry #{id} with #{who} as author. Changing or deleting it is only possible in the app." }
    MK.fail(user, "create_expense", %({"title":"rewe","amount":"30.00","paid_by":"Anna","date":"2026-09-15"})).should eq dup.call(1, "2026-09-15, Rewe, 30.00 EUR, paid by Anna")
    MK.fail(user, "create_expense", %({"title":"  REWE ","amount":30,"paid_by":"anna","date":"15.09.2026","category":"Haushalt","participants":["Dora"]})).should eq dup.call(1, "2026-09-15, Rewe, 30.00 EUR, paid by Anna")
    MK.fail(user, "create_expense", %({"title":"Hotel","amount":"100","currency":"USD","paid_by":"Dora","date":"2026-09-30"})).should eq dup.call(4, "2026-09-30, Hotel, 88.80 EUR, paid by Dora")
    MK.fail(user, "create_expense", %({"title":"Hotel","amount":"88.80","paid_by":"Dora","date":"2026-09-30"})).should eq dup.call(4, "2026-09-30, Hotel, 88.80 EUR, paid by Dora")
    MK.fail(user, "create_expense", %({"title":"Taxi","amount":"10","currency":"usd","paid_by":"Ben"})).should eq dup.call(7, "2026-10-03, Taxi, 8.90 EUR, paid by Ben")
    MK.fail(user, "create_reimbursement", %({"from":"Ben","to":"Anna","amount":15,"date":"2026-10-02","notes":"nochmal"})).should eq dup.call(6, "2026-10-02, Rückzahlung, 15.00 EUR, paid by Ben")

    # allow_duplicate, another date, another payer, another recipient or another kind are fine.
    MK.ok(user, "create_expense", %({"title":"rewe","amount":"30.00","paid_by":"Anna","date":"2026-09-15","allow_duplicate":true}))["note"].should eq note.call(8, "Anna")
    MK.ok(user, "create_expense", %({"title":"Rewe","amount":"30","paid_by":"Anna","date":"2026-09-16","participants":["Anna","Ben"]}))["created"]["id"].should eq 9
    MK.ok(user, "create_reimbursement", %({"from":"Ben","to":"Cleo","amount":"15","date":"2026-10-02"}))["created"].should eq MK.json(%({"id":10,"date":"2026-10-02","title":"Rückzahlung","paid_by":"Ben","amount":"15.00","amount_cents":1500,"reimbursement":true,"recipient":"Cleo"}))
    MK.ok(user, "create_expense", %({"title":"Rückzahlung","amount":"15","paid_by":"Ben","date":"2026-10-02","participants":["Anna"]}))["created"].should eq MK.json(%({"id":11,"date":"2026-10-02","title":"Rückzahlung","paid_by":"Ben","amount":"15.00","amount_cents":1500,"split":"equal","shares":[{"person":"Anna","amount":"15.00","amount_cents":1500}]}))
    # Amounts in euros; the logged-in person of the request does not matter, the payer is the author.
    user.login("Anna")
    r = user.run do |b|
      args = %({"title":"Gartenmöbel","amount":"23.40","paid_by":"Cleo","date":"2026-09-01","split":"amount","weights":{"Anna":"15.00","Ben":8.40}})
      b.post_raw(MK::PATH, MK.body("tools/call", %({"name":"create_expense","arguments":#{args}})), "application/json", HTTP::Headers{"Cookie" => "wer=#{b.me}"})
    end
    MK.data(r).should eq MK.json(%({"created":{"id":12,"date":"2026-09-01","title":"Gartenmöbel","paid_by":"Cleo","amount":"23.40","amount_cents":2340,"split":"amount","shares":[{"person":"Anna","amount":"15.00","amount_cents":1500},{"person":"Ben","amount":"8.40","amount_cents":840}]},"note":#{note.call(12, "Cleo").to_json}}))
    # A reimbursement in a foreign currency with a manual rate (rounded half away from zero).
    MK.ok(user, "create_reimbursement", %({"from":"Dora","to":"Cleo","amount":"50","currency":"chf","fx_rate":0.9,"date":"2026-09-05"})).should eq MK.json(%({"created":{"id":13,"date":"2026-09-05","title":"Rückzahlung","paid_by":"Dora","amount":"55.56","amount_cents":5556,"reimbursement":true,"recipient":"Cleo","original":"50.00 CHF","fx_rate":0.9,"fx_source":"manuell"},"note":#{note.call(13, "Dora").to_json}}))
    MK.fail(user, "create_reimbursement", %({"from":"Dora","to":"Cleo","amount":"55.56","date":"2026-09-05"})).should eq dup.call(13, "2026-09-05, Rückzahlung, 55.56 EUR, paid by Dora")
    MK.ok(user, "create_reimbursement", %({"from":"Dora","to":"Cleo","amount":"55.56","date":"2026-09-05","allow_duplicate":true}))["created"]["id"].should eq 14

    acts = MK.ok(user, "activity", %({"limit":7}))["entries"].as_a
    acts.map { |a| {a["expense_id"].as_i, a["actor"].as_s, a["action"].as_s} }.should eq [
      {14, "Dora", "expense_created"}, {13, "Dora", "expense_created"}, {12, "Cleo", "expense_created"}, {11, "Ben", "expense_created"},
      {10, "Ben", "expense_created"}, {9, "Anna", "expense_created"}, {8, "Anna", "expense_created"},
    ]

    # The entries are ordinary entries of the app, with the payer as author.
    user.login("Cleo")
    {
       1 => {"Rewe", "Anna hat „Rewe“ angelegt (30,00 €).", "2026-09-15"},
       4 => {"Hotel", "Dora hat „Hotel“ angelegt (88,80 €).", "2026-09-30"},
       6 => {"Rückzahlung", "Ben hat „Rückzahlung“ angelegt (15,00 €).", "2026-10-02"},
      12 => {"Gartenmöbel", "Cleo hat „Gartenmöbel“ angelegt (23,40 €).", "2026-09-01"},
      13 => {"Rückzahlung", "Dora hat „Rückzahlung“ angelegt (55,56 €).", "2026-09-05"},
    }.each do |id, (title, history, date)|
      page = user.get("/ausgaben/#{id}")
      page.status.should eq 200
      page.doc.xpath_node(%(//input[@name="titel"])).try(&.["value"]).should eq title
      page.doc.xpath_node(%(//input[@name="datum"])).try(&.["value"]).should eq date
      page.text.should contain(history)
    end
    hotel = user.get("/ausgaben/4")
    hotel.doc.xpath_node(%(//input[@name="betrag"])).try(&.["value"]).should eq "100,00"
    hotel.doc.xpath_node(%(//select[@name="bezahlt_von"]/option[@selected])).try(&.content.strip).should eq "Dora"
    activity = user.get("/aktivitaet").text
    activity.should contain("Ben hat „Taxi“ angelegt (8,90 €).")
    activity.should contain("Cleo hat „Gartenmöbel“ angelegt (23,40 €).")
    home = user.get("/").text
    %w(Gartenmöbel Sushi Hotel Taxi).each { |t| home.should contain(t) }
    # The balances page agrees with the balances tool.
    salden = user.get("/salden").text
    MK.ok(user, "balances")["balances"].as_a.each do |b|
      c = b["balance_cents"].as_i.abs
      salden.should contain("#{c // 100},#{(c % 100).to_s.rjust(2, '0')} €")
    end
  end
end

describe "MCP on the seed household" do
  db = E2E.seed_db
  world = E2E::World.new("mcp-seed", seed_db: db)
  after_all { world.stop }

  sql = ->(query : String) do
    E2E::Snapshot.open(world.app.db_path) do |d|
      d.query_all(query) { |rs| Array(DB::Any).new(rs.column_count) { rs.read } }
    end
  end
  int = ->(v : DB::Any) { v.as(Int64) }

  scenario "read tools agree with the database", world do
    user = world.user
    # Balances: every active person, archived ones only when not settled.
    expected = sql.call(<<-SQL).compact_map do |(name, archived, balance)|
      SELECT p.name, p.archived_at IS NOT NULL,
        coalesce((SELECT sum(e.amount_cents) FROM expenses e WHERE e.paid_by = p.id AND e.deleted_at IS NULL), 0) -
        coalesce((SELECT sum(s.amount_cents) FROM expense_shares s JOIN expenses e ON e.id = s.expense_id
                  WHERE s.participant_id = p.id AND e.deleted_at IS NULL), 0)
      FROM participants p ORDER BY p.name COLLATE NOCASE, p.id
      SQL
      next if int.call(archived) == 1 && int.call(balance) == 0
      {name.as(String), int.call(balance)}
    end
    r = MK.call(user, "balances")
    MK.text(r).should contain(%("person":"Cleo <b>&amp;</b>"))
    d = MK.data(r)
    d["balances"].as_a.map { |b| {b["person"].as_s, b["balance_cents"].as_i64} }.should eq expected
    d["balances"].as_a.each { |b| b["balance"].should eq eur(b["balance_cents"].as_i64) }
    d["balances"].as_a.map(&.["person"].as_s).should_not contain("Emil")
    left = expected.to_h
    left.values.sum.should eq 0
    d["settlements"].as_a.each do |s|
      s["amount"].should eq eur(s["amount_cents"].as_i64)
      left[s["from"].as_s] += s["amount_cents"].as_i64
      left[s["to"].as_s] -= s["amount_cents"].as_i64
    end
    left.values.uniq.should eq [0]

    # The data overview of the instructions.
    e, rb, nocat, first, last = sql.call("SELECT sum(is_reimbursement = 0), sum(is_reimbursement = 1), sum(is_reimbursement = 0 AND category_id IS NULL), min(date), max(date) FROM expenses WHERE deleted_at IS NULL")[0]
    actions = sql.call("SELECT DISTINCT action FROM activity ORDER BY action").map(&.[0].as(String))
    pct = "%.1f" % (int.call(nocat) * 100.0 / int.call(e))
    MK.result(MK.rpc(user, "initialize", %({"protocolVersion":"2025-03-26"})))["instructions"].as_s.should end_with(
      "\nData overview: #{e} expenses and #{rb} reimbursements dated #{first} to #{last}. #{nocat} of the expenses (#{pct}%) have no category. Values of activity.action: #{actions.join(", ")}.")

    # Names with quotes and the people list including archived ones.
    names = sql.call("SELECT name FROM participants ORDER BY name COLLATE NOCASE, id").map(&.[0].as(String))
    MK.fail(user, "search_expenses", %({"person":"Zoe"})).should eq %(Unknown person "Zoe". Available: #{names.join(", ")}.)
    cats = sql.call("SELECT name FROM categories ORDER BY position, name COLLATE NOCASE, id").map(&.[0].as(String))
    MK.fail(user, "statistics", %({"group_by":"month","category":"Yacht"})).should eq %(Unknown category "Yacht". Available: #{cats.join(", ")}.)
    dora = %(Dora "D" O'Neil)
    n, total, share = sql.call(<<-SQL)[0]
      SELECT count(*), sum(e.amount_cents), sum(s.amount_cents) FROM expenses e JOIN expense_shares s ON s.expense_id = e.id
      JOIN participants p ON p.id = s.participant_id
      WHERE p.name = 'Dora "D" O''Neil' AND e.deleted_at IS NULL AND e.is_reimbursement = 0 AND e.date >= '2026-01-01'
      SQL
    d = MK.ok(user, "search_expenses", {involved: dora.downcase, from: "2026-01-01", limit: 500}.to_json)
    {d["matches"], d["total_cents"], d["person_share"]}.should eq({n, total, MK.json({amount: eur(int.call(share)), amount_cents: int.call(share), person: dora}.to_json)})
    d["shown"].should eq [n.as(Int64), 500].min
    n, total = sql.call("SELECT count(*), sum(amount_cents) FROM expenses WHERE deleted_at IS NULL AND is_reimbursement = 0 AND (lower(title) LIKE '%pizza%' OR lower(notes) LIKE '%pizza%')")[0]
    d = MK.ok(user, "search_expenses", %({"text":"PIZZA"}))
    {d["matches"], d["total_cents"], d["shown"], d["truncated"]}.should eq({n, total, [int.call(n), 50].min, int.call(n) > 50})
    dates = d["expenses"].as_a.map(&.["date"].as_s)
    dates.should eq dates.sort.reverse
    d = MK.ok(user, "search_expenses", %({"category":"Lebensmittel","sort":"amount_desc","limit":500}))
    amounts = d["expenses"].as_a.map(&.["amount_cents"].as_i64)
    amounts.should eq amounts.sort.reverse
    d["matches"].should eq sql.call("SELECT count(*) FROM expenses e JOIN categories c ON c.id = e.category_id WHERE c.name = 'Lebensmittel' AND e.deleted_at IS NULL AND e.is_reimbursement = 0")[0][0]

    # Statistics by month compared with the previous year.
    by_month = ->(from : String, to : String) do
      sql.call("SELECT substr(date, 1, 7), sum(amount_cents) FROM expenses WHERE deleted_at IS NULL AND is_reimbursement = 0 AND date BETWEEN '#{from}' AND '#{to}' GROUP BY 1")
        .to_h { |row| {row[0].as(String), int.call(row[1])} }
    end
    now, before = by_month.call("2026-01-01", "2026-09-30"), by_month.call("2025-01-01", "2025-09-30")
    d = MK.ok(user, "statistics", %({"group_by":"month","from":"2026-01-01","to":"2026-09-30","compare":"previous_year"}))
    d["rows"].as_a.map(&.["month"].as_s).should eq (1..9).map { |m| "2026-%02d" % m }
    d["rows"].as_a.each do |row|
      m = row["month"].as_s
      cur, prev = now[m]? || 0_i64, before[m.sub("2026", "2025")]? || 0_i64
      {row["amount_cents"], row["previous_cents"], row["change_cents"]}.should eq({cur, prev, cur - prev})
      if prev == 0
        row.as_h.has_key?("change_percent").should be_false
      else
        (row["change_percent"].as_f? || row["change_percent"].as_i64.to_f).should be_close(((cur - prev) * 1000.0 / prev).round(:ties_away) / 10, 1e-9)
      end
    end
    {d["total_cents"], d["previous_total_cents"]}.should eq({now.values.sum, before.values.sum})

    # Statistics by ISO week, gaps filled, also compared with the previous year.
    week_of = ->(date : String) do
      y, w = Time.parse_utc(date, "%Y-%m-%d").calendar_week
      "%d-W%02d" % {y, w}
    end
    by_week = ->(from : String, to : String) do
      h = Hash(String, Int64).new(0_i64)
      sql.call("SELECT date, amount_cents FROM expenses WHERE deleted_at IS NULL AND is_reimbursement = 0 AND date BETWEEN '#{from}' AND '#{to}'").each do |row|
        h[week_of.call(row[0].as(String))] += int.call(row[1])
      end
      h
    end
    weeks = by_week.call("2026-08-01", "2026-09-30")
    d = MK.ok(user, "statistics", %({"group_by":"week","from":"2026-08-01","to":"2026-09-30"}))
    d["rows"].as_a.map(&.["week"].as_s).should eq (31..40).map { |w| "2026-W#{w}" }
    d["rows"].as_a.map(&.["amount_cents"].as_i64).should eq (31..40).map { |w| weeks["2026-W#{w}"] }
    prev_weeks = by_week.call("2025-09-01", "2025-09-30")
    d = MK.ok(user, "statistics", %({"group_by":"week","from":"2026-09-01","to":"2026-09-30","compare":"previous_year"}))
    d["rows"].as_a.map { |row| {row["week"].as_s, row["previous_cents"].as_i64} }.should eq (36..40).map { |w| {"2026-W#{w}", prev_weeks["2025-W#{w}"]} }

    # Activity paging.
    ids = sql.call("SELECT id FROM activity ORDER BY id DESC").map { |row| int.call(row[0]) }
    d = MK.ok(user, "activity", %({"limit":500}))
    d["entries"].as_a.map(&.["id"].as_i64).should eq ids.first(500)
    d["more"].should eq ids.size > 500
    d = MK.ok(user, "activity", {limit: 20, before_id: ids[30]}.to_json)
    d["entries"].as_a.map(&.["id"].as_i64).should eq ids[31, 20]
  end

  scenario "sql_query on real data hides YNAB", world do
    user = world.user
    E2E::Snapshot.count(world.app.db_path, "SELECT count(*) FROM ynab_config").should be > 0
    count = sql.call("SELECT count(*) FROM expenses")[0][0]
    MK.ok(user, "sql_query", %({"query":"SELECT count(*) AS n FROM expenses"}))["rows"].should eq MK.json("[[#{count}]]")
    d = MK.ok(user, "sql_query", %({"query":"SELECT * FROM expenses ORDER BY id"}))
    {d["row_count"], d["truncated"]}.should eq({500, true})
    d["columns"].as_a.map(&.as_s).should eq sql.call("SELECT name FROM pragma_table_info('expenses') ORDER BY cid").map(&.[0].as(String))
    d["rows"][0][0].should eq sql.call("SELECT min(id) FROM expenses")[0][0]
    ["SELECT * FROM ynab_config", "SELECT * FROM YNAB_CONFIG", "SELECT * FROM main.ynab_config", %(SELECT * FROM "ynab_config")].each do |q|
      MK.fail(user, "sql_query", {query: q}.to_json).should start_with("SQL error: no such table:")
    end
    MK.ok(user, "sql_query", %({"query":"SELECT group_concat(name) FROM (SELECT name FROM pragma_table_list ORDER BY name)"}))["rows"][0][0].as_s.should_not contain("ynab")
    MK.ok(user, "sql_query", %({"query":"SELECT group_concat(sql) FROM sqlite_schema"}))["rows"][0][0].as_s.downcase.should_not contain("ynab")
    MK.ok(user, "sql_query", %({"query":"SELECT key FROM settings ORDER BY key"}))["rows"].as_a.map(&.[0].as_s).should eq sql.call("SELECT key FROM settings WHERE key NOT LIKE 'ynab%' ORDER BY key").map(&.[0].as(String))
    text = MK.text(MK.call(user, "schema"))
    text.should contain(", 5: Emil (archived), ")
    text.should contain(", 8: Gesundheit (archived), ")
    text.downcase.should_not contain("create table ynab")
    # The token appears nowhere.
    text.should_not contain(E2E::FakeYNAB::TOKEN)
    %w(participants categories expenses expense_shares recurring activity fx_rates settings).each do |t|
      MK.text(MK.call(user, "sql_query", {query: "SELECT * FROM #{t}"}.to_json)).should_not contain(E2E::FakeYNAB::TOKEN)
    end
  end
end
