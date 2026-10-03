require "./web/web_helper"

describe Zipfelkasse::App do
  it "wires all routes without conflicts" do
    config = Zipfelkasse::Config.from_env({"MCP_SECRET" => "geheim"})
    with_server(config) do |srv|
      who = who_cookie(must_participant(srv.store, "Anna"))
      none = {} of String => String
      [
        {"GET", "/healthz", none, 200},
        {"GET", "/wer", none, 200},
        {"GET", "/", none, 303},
        {"GET", "/", who, 200},
        {"GET", "/salden", who, 200},
        {"GET", "/aktivitaet", who, 200},
        {"GET", "/einstellungen", who, 200},
        {"GET", "/einstellungen/wiederkehrend", who, 200},
        {"GET", "/einstellungen/kurse", who, 200},
        {"GET", "/einstellungen/ynab", who, 200},
        {"GET", "/export", who, 200},
        {"GET", "/api/kurs?waehrung=EUR", who, 200},
        {"GET", "/api/kurs?waehrung=", who, 400}, # no network; USD would query the ECB
        {"GET", "/einstellungen/wiederkehrend/neu", who, 200},
        {"POST", "/mcp/falsch", none, 404}, # a wrong secret reveals nothing
        {"POST", "/mcp/geheim", none, 403}, # no client address in memory: fails closed
        {"GET", "/gibtsnicht", who, 404},
      ].each do |method, path, cookies, want|
        {method, path, srv.request(method, path, cookies: cookies).status_code}.should eq({method, path, want})
      end
    end
  end

  it "starts the next backup at 03:00 local time" do
    berlin = Time::Location.load("Europe/Berlin")
    {
      {"2026-10-02 01:00", "2026-10-02 03:00"},
      {"2026-10-02 03:00", "2026-10-03 03:00"},
      {"2026-10-02 23:59", "2026-10-03 03:00"},
    }.each do |now, want|
      Zipfelkasse::CLI.next_backup(Time.parse(now, "%F %R", berlin)).to_s("%F %R").should eq want
    end
  end

  it "builds the health check URL from the address" do
    {
      ""               => "http://127.0.0.1:8080/healthz",
      ":8080"          => "http://127.0.0.1:8080/healthz",
      "0.0.0.0:9000"   => "http://127.0.0.1:9000/healthz",
      "[::]:9000"      => "http://127.0.0.1:9000/healthz",
      "127.0.0.1:8081" => "http://127.0.0.1:8081/healthz",
    }.each do |addr, want|
      Zipfelkasse::CLI.health_url(addr).should eq want
    end
    expect_raises(Exception) { Zipfelkasse::CLI.health_url("broken") }
  end
end
