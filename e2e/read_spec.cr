require "./e2e_helper"

# Read-only crawl over the seed household (or a real database, see README):
# every page, every expense, filters, paging, exports, the rate API and the
# MCP read tools. Pages must render, errors must be answers rather than
# crashes, and no page may contain injected scripts.
describe "Read everything" do
  db = E2E.seed_db
  world = E2E::World.new("read", seed_db: db)
  after_all { world.stop }

  people = E2E::Snapshot.open(db) { |d| d.query_all("SELECT id, name FROM participants WHERE archived_at IS NULL ORDER BY id", as: {Int64, String}) }
  categories = E2E::Snapshot.open(db) { |d| d.query_all("SELECT id, name FROM categories ORDER BY id", as: {Int64, String}) }
  expense_ids = E2E::Snapshot.open(db) { |d| d.query_all("SELECT id FROM expenses ORDER BY id", as: Int64) }
  rule_expenses = E2E::Snapshot.open(db) { |d| d.query_all("SELECT min(id) FROM expenses WHERE deleted_at IS NULL GROUP BY coalesce(recurring_id, -id) ORDER BY 1 LIMIT 25", as: Int64) }

  scenario "main pages for every person", world do
    people.each do |id, name|
      user = world.user
      user.login(name).status.should eq 303
      ["/", "/salden", "/aktivitaet", "/einstellungen", "/einstellungen/teilnehmer", "/einstellungen/kategorien",
       "/einstellungen/wiederkehrend", "/einstellungen/kurse", "/einstellungen/ynab", "/export", "/ausgaben/neu"].each do |path|
        user.get(path).status.should eq 200
      end
    end
  end

  scenario "every expense", world do
    user = world.user
    user.login(people.first[1])
    expense_ids.each { |id| user.get("/ausgaben/#{id}").status.should eq 200 }
    ["/ausgaben/0", "/ausgaben/999999", "/ausgaben/abc", "/ausgaben/-1"].each { |p| user.get(p).status.should eq 404 }
  end

  scenario "home filters, search and paging", world do
    user = world.user
    user.login(people[1][1])
    categories.each { |id, _| user.get("/?kategorie=#{id}").status.should eq 200 }
    people.each { |id, _| user.get("/?person=#{id}").status.should eq 200 }
    ["pizza", "PIZZA", "müller", "MÜLLER", "<script>", "&", "\"Luigi\"", "korrigiert", "nichts-zu-finden", "  rewe  ", "ß", "strasse"].each do |q|
      user.get("/?q=#{URI.encode_www_form(q)}").status.should eq 200
    end
    user.get("/?q=rewe&kategorie=#{categories.first[0]}&person=#{people.first[0]}").status.should eq 200
    more = "/"
    10.times do
      page = user.get(more)
      page.status.should eq 200
      link = page.doc.xpath_node("//a[@data-more]").try(&.["href"])
      break unless link
      more = link
    end
    ["/?anzahl=abc", "/?anzahl=-5", "/?anzahl=100000000", "/?kategorie=abc", "/?person=999"].each { |p| user.get(p).status.should eq 200 }
  end

  scenario "activity paging", world do
    user = world.user
    user.login(people.first[1])
    path = "/aktivitaet"
    100.times do
      page = user.get(path)
      page.status.should eq 200
      link = page.doc.xpath_node(%(//a[contains(@href, "vor=")])).try(&.["href"])
      break unless link
      path = link
    end
    user.get("/aktivitaet?vor=abc").status.should eq 200
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
    ranges = {
      ""                               => 200,
      "?von=2025-01-01"                => 200,
      "?bis=2025-06-30"                => 200,
      "?von=2025-01-01&bis=2025-12-31" => 200,
      "?von=01.09.2026&bis=03.10.2026" => 200,
      "?von=&bis="                     => 200,
      "?von=2026-01-01&bis=2025-01-01" => 422,
      "?von=kaputt"                    => 422,
    }
    types = {
      "/export"               => "text/html",
      "/export/ausgaben.csv"  => "text/csv",
      "/export/ausgaben.json" => "application/json",
      "/export/ynab.ofx"      => "application/x-ofx",
      "/export/ynab.csv"      => "text/csv",
    }
    ranges.each do |q, status|
      types.each do |path, type|
        r = user.get(path + q)
        {path + q, r.status}.should eq({path + q, status})
        r.content_type.should start_with(type) if status == 200
      end
    end
    user.get("/export/ausgaben.json").json["expenses"].as_a
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
     "/gibt-es-nicht" => 404, "/salden/" => 404}.each do |path, status|
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
    user.get("/static/fehlt.css").status.should eq 404
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
      {person: names[1], detail: "full", limit: 500}, {paid_by: names[2], involved: names[0]}, {limit: 0},
    ].each { |args| ok.call("search_expenses", args.to_json) }
    refused.call("search_expenses", %({"sort":"random"})).should contain "sort must be one of"
    refused.call("search_expenses", %({"from":"gestern"})).should contain "Invalid date"

    %w(category title year month week person category_month).each do |g|
      ok.call("statistics", {group_by: g}.to_json)
      ok.call("statistics", {group_by: g, from: "2025-01-01", to: "2025-12-31", compare: "previous_year"}.to_json)
      ok.call("statistics", {group_by: g, share_of: names[0], from: "2026-01-01"}.to_json)
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
      "ATTACH DATABASE '/tmp/x.db' AS x", "PRAGMA table_info(expenses)", "SELECT * FROM gibtsnicht",
    ].each { |q| refused.call("sql_query", {query: q}.to_json) }
    refused.call("sql_query", {query: ""}.to_json).should contain "query is missing"
    E2E::MCPKit.error(user.tool("gibt_es_nicht")).should eq({-32602_i64, "Unknown tool: gibt_es_nicht"})
  end
end
