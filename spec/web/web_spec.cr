require "./web_helper"

private alias Web = Zipfelkasse::Web
private alias Store = Zipfelkasse::Store

private def form_post(srv : TestServer, path : String, form : Hash(String, String), headers = HTTP::Headers.new,
                      cookies = {} of String => String) : HTTP::Client::Response
  headers = headers.dup
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  srv.request("POST", path, URI::Params.encode(form), headers, cookies)
end

describe Zipfelkasse::Web do
  it "sends visitors without identity to the who page" do
    with_server do |srv|
      res = srv.get("/salden?x=1")
      res.status_code.should eq 303
      res.headers["Location"].should eq "/wer?zurueck=%2Fsalden%3Fx%3D1"
      res = srv.get("/")
      res.status_code.should eq 303
      res.headers["Location"].should eq "/wer"
      srv.get("/", who_cookie(42)).status_code.should eq 303
      res = srv.get("/api/kurs")
      res.status_code.should eq 401
      res.body.should contain "error"
    end
  end

  it "serves the public paths without identity" do
    with_server do |srv|
      res = srv.get("/healthz")
      res.status_code.should eq 200
      res.body.should eq "ok\n"
      res = srv.get("/wer")
      res.status_code.should eq 200
      res.body.should contain "Wer bist du?"
      res.body.should contain "Neue Person"
      res.body.should_not contain "Hauptnavigation"
      res = srv.get("/static/app.css")
      res.status_code.should eq 200
      res.body.should contain "--background"
      res.headers["X-Content-Type-Options"].should eq "nosniff"
    end
  end

  it "creates a person, selects it and logs the creation" do
    with_server do |srv|
      res = srv.post_form("/wer/neu", {"name" => "Jörg", "zurueck" => "/salden"})
      res.status_code.should eq 303
      res.headers["Location"].should eq "/salden"
      who = res.cookies[Web::IDENTITY_COOKIE]
      who.http_only.should be_true
      who.samesite.should eq HTTP::Cookie::SameSite::Lax
      flash = res.cookies[Web::FLASH_COOKIE]
      ps = srv.store.list_participants(false)
      ps.map(&.name).should eq ["Jörg"]
      who.value.should eq ps[0].id.to_s
      act = srv.store.list_activity(Store::ActivityFilter.new(limit: 1)).first
      act.action.should eq Store::Action::SettingsUpdated
      act.actor_id.should eq ps[0].id
      act.details.text.should eq "Person „Jörg“ hinzugefügt"

      body = srv.get("/salden", {who.name => who.value, flash.name => flash.value}).body
      ["Du bist <strong>Jörg</strong>", %(href="/salden" aria-current="page"), "Willkommen!", "/static/app.css?v="].each do |want|
        body.should contain want
      end

      res = srv.post_form("/wer/neu", {"name" => "jörg"})
      res.status_code.should eq 422
      res.body.should contain "gibt es schon"
    end
  end

  it "selects a person and returns only to local paths" do
    with_server do |srv|
      id = must_participant(srv.store, "Anna")
      {"/aktivitaet" => "/aktivitaet", "//evil.example" => "/", "https://evil.example" => "/", "" => "/"}.each do |ret, want|
        res = srv.post_form("/wer", {"id" => id.to_s, "zurueck" => ret})
        res.status_code.should eq 303
        res.headers["Location"].should eq want
        res.cookies[Web::IDENTITY_COOKIE].value.should eq id.to_s
      end
      srv.get("/wer").body.should contain "Anna"
      srv.post_form("/wer", {"id" => "999"}).status_code.should eq 422
      srv.post_form("/wer", {"id" => " #{id}"}).status_code.should eq 422
      srv.get("/", who_cookie(id)).status_code.should eq 200
      srv.request("GET", "/", headers: HTTP::Headers{"Cookie" => %(wer=" #{id}")}).status_code.should eq 303
      srv.store.set_participant_archived(nil, id, true)
      srv.get("/", who_cookie(id)).status_code.should eq 303
    end
  end

  it "percent-encodes non-ASCII bytes and cleans the path of a redirect target" do
    with_server do |srv|
      id = must_participant(srv.store, "Anna")
      res = srv.post_form("/wer", {"id" => id.to_s, "zurueck" => "/salden?q=Käse"})
      res.headers["Location"].should eq "/salden?q=K%c3%a4se"
      res = srv.post_form("/wer", {"id" => id.to_s, "zurueck" => "/salden#/../aktivitaet?x=/../y"})
      res.headers["Location"].should eq "/aktivitaet?x=/../y"
    end
  end

  it "renders the main pages with the active tab" do
    with_server do |srv|
      me = who_cookie(must_participant(srv.store, "Anna"))
      ["/", "/salden", "/aktivitaet", "/einstellungen"].each do |path|
        res = srv.get(path, me)
        res.status_code.should eq 200
        res.body.should contain %(aria-current="page")
      end
    end
  end

  it "rejects cross-origin form posts" do
    with_server do |srv|
      id = must_participant(srv.store, "Anna")
      post = ->(h : HTTP::Headers) { form_post(srv, "/wer", {"id" => id.to_s}, h) }
      res = post.call(HTTP::Headers{"Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example"})
      res.status_code.should eq 403
      res.body.should contain "fremden Seite"
      post.call(HTTP::Headers{"Origin" => "https://evil.example"}).status_code.should eq 403
      post.call(HTTP::Headers{"Sec-Fetch-Site" => "same-origin", "Origin" => "http://example.com"}).status_code.should eq 303
      post.call(HTTP::Headers.new).status_code.should eq 303
      post.call(HTTP::Headers{"Origin" => ""}).status_code.should eq 303
    end
  end

  it "accepts only local return targets" do
    {
      "/aktivitaet"           => "/aktivitaet",
      "/salden?x=1#a"         => "/salden?x=1#a",
      "/%09/evil.example/x"   => "/",
      "/\t/evil.example/x"    => "/",
      "/\r\n/evil.example"    => "/",
      "//evil"                => "/",
      "/\\evil"               => "/",
      "/a\\b"                 => "/",
      "https://evil"          => "/",
      "evil"                  => "/",
      "/wer?zurueck=/"        => "/",
      ""                      => "/",
      "/%2F/evil.example"     => "/",
      "/ausgaben/neu?von=%2F" => "/ausgaben/neu?von=%2F",
      "/%77er"                => "/",
      "/%zz"                  => "/",
      "/a%2"                  => "/",
      "/a?%zz"                => "/a?%zz",
      "/a#b%"                 => "/",
      "/a?b#%zz"              => "/",
      "/a#/../b"              => "/a#/../b",
      "/%C2%85"               => "/",
      "/ä"                    => "/ä",
    }.each do |input, want|
      Web.safe_return(input).should eq(want), "safe_return(#{input.inspect})"
    end
  end

  it "never logs the MCP secret" do
    with_server do |srv|
      headers = HTTP::Headers{"Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example"}
      srv.request("POST", "/mcp/geheim123", "{}", headers).status_code.should eq 404
      srv.log_io.to_s.should_not contain "geheim123"
    end
    {"/mcp/abc" => "/mcp/***", "/mcp/" => "/mcp/***", "/ausgaben/1" => "/ausgaben/1", "/mcpx" => "/mcpx"}.each do |input, want|
      Web.log_path(input).should eq want
    end
  end

  it "limits the request body" do
    with_server do |srv|
      anna = must_participant(srv.store, "Anna")
      big = URI::Params.encode({"name" => "a" * Web::MAX_BODY_BYTES})
      post = ->(path : String, chunked : Bool) do
        headers = HTTP::Headers{"Host" => "example.com", "Content-Type" => "application/x-www-form-urlencoded",
                                "Cookie" => "#{Web::IDENTITY_COOKIE}=#{anna}"}
        req = HTTP::Request.new("POST", path, headers, big)
        if chunked
          req.headers.delete("Content-Length")
          req.body = IO::Memory.new(big)
        end
        srv.call(req)
      end
      [false, true].each do |chunked|
        res = post.call("/einstellungen/teilnehmer", chunked)
        res.status_code.should eq 413
        res.body.should contain "zu groß"
        res.headers["Content-Type"].should start_with "text/html"
        res = post.call("/api/kurs", chunked)
        res.status_code.should eq 413
        res.headers["Content-Type"].should start_with "application/json"
        res.body.should contain "zu groß"
      end
      srv.store.list_participants(true).size.should eq 1
      srv.post_form("/einstellungen/teilnehmer", {"name" => "Ben"}, who_cookie(anna)).status_code.should eq 303
    end
  end

  it "answers an unexpected error with the error page and a log entry" do
    with_server do |srv|
      Web.route(srv.d, "GET", "/kaputt") { |_| raise "Platte voll" }
      me = who_cookie(must_participant(srv.store, "Anna"))
      res = srv.get("/kaputt", me)
      res.status_code.should eq 500
      res.body.should contain "Da ist etwas schiefgegangen."
      res.body.should contain "Du bist <strong>Anna</strong>"
      srv.log_io.to_s.should contain %(level=ERROR msg=request method=GET path=/kaputt err="Platte voll")
    end
  end

  it "answers health checks and unknown paths" do
    with_server do |srv|
      srv.get("/healthz").body.should eq "ok\n"
      srv.get("/gibtsnicht", who_cookie(must_participant(srv.store, "Anna"))).status_code.should eq 404
    end
  end
end
