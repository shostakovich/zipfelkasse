require "../spec_helper"

private module Fixture
  class_property! server : MCP::Server
end

private def call(name : String, arguments : String = "{}") : {String, Bool}
  Fixture.server.run_tool(name, arguments)
end

private def data(name : String, arguments : String = "{}") : JSON::Any
  text, error = call(name, arguments)
  fail "#{name} #{arguments}: #{text}" if error
  JSON.parse(text)
end

private def refusal(name : String, arguments : String = "{}") : String
  text, error = call(name, arguments)
  fail "#{name} #{arguments}: expected an error, got #{text}" unless error
  text
end

private def entry(title : String, cents : Int64, on : String, category : Int64? = household.food) : Int64
  input = household.equal(title, cents, on, household.anna, household.anna)
  input.category_id = category
  household.create(input)
end

describe MCP::Server do
  use_household

  before_each do
    household.deps.config.location = Time::Location::UTC
    Fixture.server = MCP::Server.new(household.deps)
  end

  it "logs requests and refusals, but never the secret" do
    secret = "s3cr3t-0123456789abcdef"
    config = Config.new
    config.mcp_secret = secret
    server = TestServer.new(config, household.store)
    anthropic = Socket::IPAddress.new("160.79.104.10", 40000)
    headers = HTTP::Headers{"Content-Type" => "application/json", "MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "ping"}
    ping = %({"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"#{MCP::META_PROTOCOL_VERSION}":"2026-07-28"}}})

    server.request("POST", "/mcp/#{secret}", ping, headers, remote: anthropic).status_code.should eq 200
    server.request("POST", "/mcp/wrong", ping, headers, remote: anthropic).status_code.should eq 404
    server.request("POST", "/mcp/#{secret}", ping, headers, remote: Socket::IPAddress.new("1.2.3.4", 1)).status_code.should eq 403
    server.request("POST", "/mcp/#{secret}", ping, headers.dup.tap(&.["Origin"] = "https://evil.example"), remote: anthropic).status_code.should eq 403

    log = SPEC_LOG.to_s
    ["method=ping", "ip=160.79.104.10", "wrong secret", "IP not allowed", "Origin header rejected"].each do |entry|
      log.should contain entry
    end
    log.should_not contain secret[0, 10]
  end

  describe "category arguments" do
    it "selects expenses without a category with none, in any case, and with the statistics label" do
      entry("Tanken", 5000, "2026-09-01", nil)
      entry("Rewe", 3000, "2026-09-02")
      entry("Pizza", 2000, "2026-09-03", household.restaurant)

      ["none", "No category", "NONE"].each do |category|
        found = data("search_expenses", {category: category}.to_json)
        {category, found["expenses"].as_a.map(&.["title"])}.should eq({category, ["Tanken"]})
      end
      stats = data("statistics", %({"group_by":"category","category":"none"}))
      {stats["rows"].as_a.map(&.["category"]), stats["total_cents"]}.should eq({["No category"], 5000})
    end

    it "prefers a real category named None" do
      none = store.create_category(nil, "None")
      entry("Tanken", 5000, "2026-09-01", nil)
      entry("Kram", 1000, "2026-09-02", none)

      data("search_expenses", %({"category":"none"}))["expenses"].as_a.map(&.["title"]).should eq ["Kram"]
    end

    it "names an unknown category in the error" do
      refusal("statistics", %({"group_by":"month","category":"Yacht"})).should contain "Yacht"
    end
  end

  describe "statistics compared with the previous year" do
    before_each do
      household.now = Time.utc(2026, 10, 2, 12)
      entry("Rewe", 7000, "2025-03-10")
      entry("Hotel", 50000, "2025-03-12", nil)
      entry("Rewe", 10000, "2026-03-10")
      entry("Miete", 90000, "2023-03-01", nil)
      entry("Bäckerei Groß", 300, "2026-05-02", nil)
      entry("BÄCKEREI GROSS", 200, "2025-05-02", nil)
      entry("Glühwein", 800, "2020-12-30", nil)
    end

    it "lists a category that only had expenses a year earlier with 0" do
      stats = data("statistics", %({"group_by":"category_month","from":"2026-03-01","to":"2026-03-31","compare":"previous_year"}))

      stats["rows"].should eq JSON.parse(%([
        {"category":"Lebensmittel","month":"2026-03","count":1,"amount":"100.00","amount_cents":10000,"previous":"70.00","previous_cents":7000,"change":"30.00","change_cents":3000,"change_percent":42.9},
        {"category":"No category","month":"2026-03","count":0,"amount":"0.00","amount_cents":0,"previous":"500.00","previous_cents":50000,"change":"-500.00","change_cents":-50000,"change_percent":-100}]))
      stats["previous_total_cents"].should eq 57000
    end

    it "ends the previous range of 29 February on 28 February" do
      stats = data("statistics", %({"group_by":"category","from":"2024-02-01","to":"2024-02-29","compare":"previous_year"}))

      {stats["previous_total_cents"], stats["previous_period"]}.should eq({0, "2023-02-01 to 2023-02-28"})
    end

    it "matches titles the way the statistics group them, ß as ss" do
      rows = data("statistics", %({"group_by":"title","from":"2026-05-01","to":"2026-05-31","compare":"previous_year"}))["rows"].as_a

      {rows.size, rows[0]["previous_cents"]}.should eq({1, 200})
    end

    it "compares week 53 of 2020 with week 52 of 2021" do
      weeks = ->(from : String, to : String) do
        data("statistics", %({"group_by":"week","from":"#{from}","to":"#{to}","compare":"previous_year"}))["rows"].as_a
      end

      weeks.call("2021-12-20", "2021-12-26").map(&.["week"]).should eq ["2021-W51"]
      rows = weeks.call("2021-12-27", "2022-01-02")
      {rows.size, rows[0]["week"], rows[0]["previous_cents"]}.should eq({1, "2021-W52", 800})
    end

    it "refuses a start in the future without an end" do
      refusal("statistics", %({"group_by":"category","from":"2026-12-01","compare":"previous_year"})).should contain "future"
    end
  end

  describe "activity in the server time zone" do
    before_each do
      household.deps.config.location = Time::Location.load("Europe/Berlin")
      Fixture.server = MCP::Server.new(household.deps)
      store.clock = -> { Time.utc(2030, 1, 1, 23, 30) } # already 2 January in Berlin
      store.create_category(nil, "Kino")
    end

    it "shows the time of an entry in the server time zone" do
      data("activity", %({"limit":1}))["entries"][0]["at"].should eq "2030-01-02T00:30:00+01:00"
    end

    it "filters by the days of the server time zone" do
      data("activity", %({"from":"2030-01-02","to":"2030-01-02","limit":1}))["entries"].as_a.size.should eq 1
      data("activity", %({"from":"2030-01-01","to":"2030-01-01","limit":1}))["entries"].as_a.size.should eq 0
    end
  end
end
