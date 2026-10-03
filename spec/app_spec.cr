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

  it "serves MCP beside the browser middleware" do
    secret = "geheim-a1b2c3"
    config = Zipfelkasse::Config.from_env({"MCP_SECRET" => secret, "MCP_ALLOWED_CIDRS" => "192.0.2.0/24"})
    with_server(config) do |srv|
      send = ->(path : String, body : String, headers : Hash(String, String)) do
        h = HTTP::Headers{"Host" => "example.com", "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream"}
        headers.each { |k, v| h[k] = v }
        req = HTTP::Request.new("POST", path, h, body)
        req.remote_address = Socket::IPAddress.new("192.0.2.1", 1234)
        srv.call(req)
      end
      initialize_request = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}})
      path = "/mcp/#{secret}"

      # No person is selected and no redirect to /wer happens.
      res = send.call(path, initialize_request, {} of String => String)
      res.status_code.should eq 200
      res.body.should contain %("serverInfo")
      res.headers["X-Content-Type-Options"].should eq "nosniff"
      res.headers["Content-Security-Policy"]?.should_not be_nil
      # The CSRF check does not apply.
      send.call(path, initialize_request, {"Sec-Fetch-Site" => "cross-site"}).status_code.should eq 200
      # MCP rejects an Origin header itself, with a JSON-RPC error.
      res = send.call(path, initialize_request, {"Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example"})
      res.status_code.should eq 403
      res.body.should contain %("jsonrpc")
      # Too large messages get the JSON-RPC error, not the 413 page.
      big = %({"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"#{"a" * (1 << 20)}"}})
      res = send.call(path, big, {} of String => String)
      res.status_code.should eq 413
      res.body.should contain %("jsonrpc")
      # A wrong secret and other paths below /mcp/ are 404 and never reach the browser middleware.
      ["/mcp/falsch", "/mcp/", "#{path}/x"].each do |p|
        send.call(p, "{}", {"Origin" => "https://evil.example"}).status_code.should eq 404
      end
      srv.log_io.to_s.should_not contain secret
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

  it "drops connections that stall reading or writing" do
    server = Zipfelkasse::CLI::TimeoutServer.new("127.0.0.1", 0)
    client = TCPSocket.new("127.0.0.1", server.local_address.port)
    conn = server.accept?.not_nil!
    {conn.read_timeout, conn.write_timeout}.should eq({30.seconds, 60.seconds})
  ensure
    conn.try &.close
    client.try &.close
    server.try &.close
  end
end
