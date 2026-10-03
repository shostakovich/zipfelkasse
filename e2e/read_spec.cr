require "./e2e_helper"

# Read-only crawl over the seed household: every page, every expense, filters,
# paging, exports, the rate API and the MCP read tools.
describe "Read everything" do
  world = E2E.seeded_world
  people = [] of {Int64, String}
  categories = [] of {Int64, String}
  rule_expenses = [] of Int64

  newest_ids = ->(where : String) do
    E2E::Database.open(world.app.db_path) do |db|
      db.query_all("SELECT id FROM expenses WHERE deleted_at IS NULL AND #{where} ORDER BY date DESC, id DESC LIMIT 100", as: Int64)
    end
  end
  listed_ids = ->(page : E2E::Response) do
    page.doc.xpath_nodes(%(//a[starts-with(@id, "ausgabe-")])).map { |a| a["id"].lchop("ausgabe-").to_i64 }
  end

  before_all do
    E2E::Database.open(world.app.db_path) do |d|
      people = d.query_all("SELECT id, name FROM participants WHERE archived_at IS NULL ORDER BY id", as: {Int64, String})
      categories = d.query_all("SELECT id, name FROM categories ORDER BY id", as: {Int64, String})
      rule_expenses = d.query_all("SELECT min(id) FROM expenses WHERE deleted_at IS NULL GROUP BY coalesce(recurring_id, -id) ORDER BY 1 LIMIT 25", as: Int64)
    end
  end

  scenario "main pages for every person", world do
    people.each do |id, name|
      user = world.user
      user.login(name).status.should eq 303
      ["/", "/salden", "/aktivitaet", "/einstellungen", "/einstellungen/teilnehmer", "/einstellungen/kategorien",
       "/einstellungen/wiederkehrend", "/einstellungen/kurse", "/einstellungen/ynab", "/export", "/ausgaben/neu"].each do |path|
        page = user.get(path)
        {path, page.status, E2E::Web.whoami(page)}.should eq({path, 200, name})
      end
    end
  end

  scenario "unknown expenses are not found", world do
    user = world.user
    user.login(people.first[1])
    ["/ausgaben/0", "/ausgaben/999999", "/ausgaben/abc", "/ausgaben/-1"].each { |p| user.get(p).status.should eq 404 }
  end

  scenario "home filters and search show the matching expenses", world do
    user = world.user
    user.login(people[1][1])
    categories.each do |id, _|
      listed_ids.call(user.get("/?kategorie=#{id}")).should eq newest_ids.call("category_id = #{id}")
    end
    people.each do |id, _|
      listed_ids.call(user.get("/?person=#{id}")).should eq newest_ids.call("(paid_by = #{id} OR id IN (SELECT expense_id FROM expense_shares WHERE participant_id = #{id}))")
    end
    {"pizza" => "pizza", "PIZZA" => "pizza", "  rewe  " => "rewe", "korrigiert" => "korrigiert", "no-match" => nil}.each do |query, term|
      expected = term ? newest_ids.call("(lower(title) LIKE '%#{term}%' OR lower(notes) LIKE '%#{term}%')") : [] of Int64
      expected.should_not be_empty if term
      {query, listed_ids.call(user.get("/?q=#{URI.encode_www_form(query)}"))}.should eq({query, expected})
    end
    ["müller", "MÜLLER", "<script>", "&", "\"Luigi\"", "ß", "strasse"].each do |q|
      user.get("/?q=#{URI.encode_www_form(q)}").status.should eq 200
    end
    user.get("/?q=rewe&kategorie=#{categories.first[0]}&person=#{people.first[0]}").status.should eq 200
  end

  scenario "unusable paging and filter parameters still give a page", world do
    user = world.user
    user.login(people.first[1])
    ["/?anzahl=abc", "/?anzahl=-5", "/?anzahl=100000000", "/?kategorie=abc", "/?person=999", "/aktivitaet?vor=abc"].each do |path|
      user.get(path).status.should eq 200
    end
  end

  scenario "reimbursement and recurring forms", world do
    user = world.user
    user.login(people.first[1])
    people.each do |from, _|
      people.each do |to, _|
        user.get("/ausgaben/neu?rueckzahlung=1&von=#{from}&an=#{to}&betrag=12345").status.should eq 200 unless from == to
      end
    end
    user.get("/ausgaben/neu?rueckzahlung=1&von=x&an=&betrag=-3").status.should eq 200
    rule_expenses.each { |id| user.get("/einstellungen/wiederkehrend/neu?ausgabe=#{id}").status.should eq 200 }
    user.get("/einstellungen/wiederkehrend/neu").status.should eq 200
    user.get("/einstellungen/ynab?neu=1").status.should eq 200
  end

  scenario "exports", world do
    user = world.user
    user.login(people.first[1])
    # query => {status, first day, last day}
    ranges = {
      ""                               => {200, "0000-01-01", "9999-12-31"},
      "?von=2025-01-01"                => {200, "2025-01-01", "9999-12-31"},
      "?bis=2025-06-30"                => {200, "0000-01-01", "2025-06-30"},
      "?von=2025-01-01&bis=2025-12-31" => {200, "2025-01-01", "2025-12-31"},
      "?von=01.09.2026&bis=03.10.2026" => {200, "2026-09-01", "2026-10-03"},
      "?von=&bis="                     => {200, "0000-01-01", "9999-12-31"},
      "?von=2026-01-01&bis=2025-01-01" => {422, "", ""},
      "?von=broken"                    => {422, "", ""},
    }
    types = {
      "/export"               => "text/html",
      "/export/ausgaben.csv"  => "text/csv",
      "/export/ausgaben.json" => "application/json",
      "/export/ynab.ofx"      => "application/x-ofx",
      "/export/ynab.csv"      => "text/csv",
    }
    ranges.each do |q, (status, first, last)|
      types.each do |path, type|
        r = user.get(path + q)
        {path + q, r.status}.should eq({path + q, status})
        r.content_type.should start_with(type) if status == 200
      end
      next unless status == 200
      expected = E2E::Database.open(world.app.db_path) do |db|
        db.query_all("SELECT id FROM expenses WHERE deleted_at IS NULL AND date BETWEEN ? AND ? ORDER BY date, id", first, last, as: Int64)
      end
      {q, user.get("/export/ausgaben.json" + q).json["expenses"].as_a.map(&.["id"].as_i64)}.should eq({q, expected})
    end
    user.login(people[1][1])
    {"/export/ynab.ofx", "/export/ynab.csv"}.each { |path| user.get(path).status.should eq 200 }
  end

  scenario "rate API, PWA and static files", world do
    user = world.user
    user.login(people.first[1])
    # nil: the answer depends on the rates in the database.
    [{"EUR", "", 200}, {"eur", "2025-01-01", 200}, {"", "", 400}, {"US", "", 400}, {"USD", "gestern", 400},
     {"USD", "", nil}, {"USD", "2024-05-18", nil}, {"JPY", "2026-10-03", nil}, {"THB", "2026-09-12", nil},
     {"KWD", "2025-11-20", nil}, {"XAF", "", nil}, {"usd", "01.06.2024", nil}, {"GBP", "2023-01-01", nil}].each do |cur, date, status|
      r = user.get("/api/kurs?waehrung=#{cur}" + (date.empty? ? "" : "&datum=#{date}"))
      r.content_type.should start_with "application/json"
      r.json
      status ? r.status.should(eq status) : r.status.should(be < 500)
    end
    {"/manifest.webmanifest" => 200, "/sw.js" => 200, "/favicon.ico" => 200, "/healthz" => 200,
     "/does-not-exist" => 404, "/salden/" => 404}.each do |path, status|
      {path, user.get(path).status}.should eq({path, status})
    end
    page = user.get("/ausgaben/neu")
    assets = page.doc.xpath_nodes("//link[@href]|//script[@src]|//img[@src]").map { |n| n["href"]? || n["src"] }
    assets.select(&.starts_with?("/static/")).each do |path|
      user.get(path).status.should eq 200
      user.get(path.split('?').first).status.should eq 200
    end
    %w(app.css app.js expense-form.js icons.svg mascot.webp sw.js icons/apple-touch-icon.png icons/favicon-32.png
      icons/icon-192.png icons/icon-512.png icons/maskable-512.png).each do |f|
      user.get("/static/#{f}").status.should eq 200
    end
    user.get("/static/missing.css").status.should eq 404
  end

  scenario "identity redirects", world do
    anonymous = world.user
    ["/salden", "/salden?x=1", "/ausgaben/1", "/export/ausgaben.csv"].each do |p|
      r = anonymous.get(p)
      {r.status, r.location}.should eq({303, "/wer?zurueck=#{URI.encode_www_form(p)}"})
    end
    {anonymous.get("/"), anonymous.post("/ausgaben/neu", {"titel" => "x"})}.each do |r|
      {r.status, r.location}.should eq({303, "/wer"})
    end
    anonymous.get("/api/kurs?waehrung=USD").status.should eq 401
    anonymous.get("/wer").status.should eq 200
    anonymous.get("/static/app.css").status.should eq 200
  end

  scenario "MCP read tools", world do
    user = world.user
    names = people.map(&.[1])
    ok = ->(tool : String, args : String) { E2E::MCPKit.text(user.tool(tool, JSON.parse(args).as_h)) }
    refused = ->(tool : String, args : String) { E2E::MCPKit.text(user.tool(tool, JSON.parse(args).as_h), error: true) }
    init = E2E::MCPKit.result(user.mcp("initialize", {"protocolVersion" => JSON::Any.new("2025-06-18"), "capabilities" => JSON.parse("{}"),
                                                      "clientInfo" => JSON.parse(%({"name":"e2e","version":"1"}))}))
    init["instructions"].as_s.should contain "Zipfelkasse"
    E2E::MCPKit.result(user.mcp("tools/list"))["tools"].as_a.map(&.["name"].as_s).should contain "sql_query"

    balances = JSON.parse(ok.call("balances", "{}"))["balances"].as_a
    balances.sum { |b| b["balance_cents"].as_i64 }.should eq 0
    ok.call("balance_history", "{}")
    ["month", "week", "year"].each do |interval|
      ok.call("balance_history", {interval: interval, from: "2025-01-01", to: "2026-10-03"}.to_json)
    end
    names.each { |n| ok.call("balance_history", {person: n, interval: "year"}.to_json) }
    refused.call("balance_history", %({"person":"Niemand"})).should contain "Unknown person"

    ok.call("search_expenses", "{}")
    [
      {text: "pizza"}, {text: ["Rewe", "Döner"]}, {text: "<script>", detail: "full"}, {category: "none"},
      {category: "restaurant", sort: "amount_desc", limit: 5}, {min_amount: 50, max_amount: 120.5, sort: "amount_asc"},
      {reimbursements: "only", detail: "full"}, {reimbursements: "include", from: "2026-01-01", to: "2026-12-31"},
      {person: names[1], detail: "full", limit: 500}, {paid_by: names[2], involved: names[0]}, {limit: 1},
    ].each { |args| ok.call("search_expenses", args.to_json) }
    refused.call("search_expenses", %({"sort":"random"})).should contain "sort must be one of"
    refused.call("search_expenses", %({"from":"gestern"})).should contain "Invalid date"

    %w(category title year month week person category_month).each do |g|
      ok.call("statistics", {group_by: g}.to_json)
      ok.call("statistics", {group_by: g, from: "2025-01-01", to: "2025-12-31", compare: "previous_year"}.to_json)
      ok.call("statistics", {group_by: g, share_of: names[0], from: "2026-01-01"}.to_json)
    end
    spent = E2E::Database.count(world.app.db_path, "SELECT sum(amount_cents) FROM expenses WHERE deleted_at IS NULL AND is_reimbursement = 0")
    %w(category year month).each do |g|
      stats = JSON.parse(ok.call("statistics", {group_by: g}.to_json))
      {g, stats["total_cents"].as_i64, stats["rows"].as_a.sum { |row| row["amount_cents"].as_i64 }}.should eq({g, spent, spent})
    end
    ok.call("statistics", {group_by: "month", category: "Lebensmittel", text: ["rewe", "markt"]}.to_json)
    ok.call("statistics", {group_by: "title", limit: 3}.to_json)
    refused.call("statistics", {group_by: "category", compare: "previous_year"}.to_json).should contain "needs from"
    refused.call("statistics", "{}").should contain "group_by must be one of"

    ok.call("activity", "{}")
    [{limit: 500}, {action: "expense_updated"}, {person: names[0], from: "2026-10-01"}, {expense_id: 5},
     {before_id: 50, limit: 10}, {from: "2026-10-03", to: "2026-10-03"}].each { |args| ok.call("activity", args.to_json) }

    ok.call("schema", "{}")
    [
      "SELECT count(*) AS n, sum(amount_cents) / 100.0 AS eur FROM expenses WHERE deleted_at IS NULL",
      "SELECT p.name, sum(s.amount_cents) FROM expense_shares s JOIN participants p ON p.id = s.participant_id GROUP BY p.name ORDER BY 1",
      "WITH m AS (SELECT substr(date, 1, 7) AS month, sum(amount_cents) AS c FROM expenses GROUP BY 1) SELECT * FROM m ORDER BY month",
      "SELECT * FROM expenses ORDER BY id",
      "SELECT zipfelkasse_fold('Straße ÄÖÜ'), 1.0, 1e300, x'00ff', NULL, 'x' || char(10) || 'y'",
      "SELECT strftime('%G-W%V', date) AS week, count(*) FROM expenses GROUP BY 1 ORDER BY 1 DESC LIMIT 3",
    ].each { |q| JSON.parse(ok.call("sql_query", {query: q}.to_json))["row_count"].as_i }
    [
      "SELECT * FROM ynab_config", "DELETE FROM expenses", "UPDATE participants SET name = 'x'", "SELECT 1; SELECT 2",
      "ATTACH DATABASE '/tmp/x.db' AS x", "PRAGMA table_info(expenses)", "SELECT * FROM nonexistent",
    ].each { |q| refused.call("sql_query", {query: q}.to_json) }
    refused.call("sql_query", {query: ""}.to_json).should contain "query is missing"
    E2E::MCPKit.error(user.tool("no_such_tool")).should eq({-32602_i64, "Unknown tool: no_such_tool"})
  end
end
