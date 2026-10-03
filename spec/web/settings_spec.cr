require "./web_helper"

# Anna, Ben and Cleo; Anna is logged in.
private def with_group(&)
  with_server do |srv|
    f = ExpenseFixture.new(srv.store)
    yield srv, f, who_cookie(f.anna)
  end
end

private def page(srv : TestServer, path : String, cookies) : {Int32, String}
  res = srv.get(path, cookies)
  {res.status_code, HTML.unescape(res.body)}
end

private def post(srv : TestServer, path : String, cookies, form = {} of String => String) : HTTP::Client::Response
  srv.post_form(path, form, cookies)
end

private def body_of(res : HTTP::Client::Response) : String
  HTML.unescape(res.body)
end

private def location(res : HTTP::Client::Response) : String
  res.headers["Location"]? || ""
end

private def flash_of(res : HTTP::Client::Response) : String?
  c = res.cookies[Zipfelkasse::Web::FLASH_COOKIE]? || return nil
  URI.decode_www_form(c.value)
end

private def error_of(body : String) : String
  body[/role="alert">([^<]*)</, 1]? || "(no error message)"
end

private def activity_texts(s : Zipfelkasse::Store) : Array(String)
  s.list_activity.map(&.details.text.to_s)
end

describe "settings pages" do
  it "links the settings pages and renames the group" do
    with_group do |srv, _, me|
      status, body = page(srv, "/einstellungen", me)
      status.should eq 200
      body.should contain %(<a href="/einstellungen" aria-current="page">)
      body.should contain %(value="Zipfelkasse")
      ["/einstellungen/teilnehmer", "/einstellungen/kategorien", "/einstellungen/wiederkehrend",
       "/einstellungen/kurse", "/einstellungen/ynab", "/export"].each do |link|
        body.should contain %(href="#{link}")
      end

      res = post(srv, "/einstellungen", me, {"gruppenname" => "WG Süd"})
      {res.status_code, location(res), flash_of(res)}.should eq({303, "/einstellungen", "Gespeichert."})
      srv.store.group_name.should eq "WG Süd"
      _, body = page(srv, "/salden", me)
      body.should contain "<title>Salden · WG Süd</title>"
      flash = {Zipfelkasse::Web::FLASH_COOKIE => res.cookies[Zipfelkasse::Web::FLASH_COOKIE].value}
      _, body = page(srv, "/einstellungen", me.merge(flash))
      body.should contain %(<p class="alert alert-success" role="status">Gespeichert.</p>)
      body.should contain %(value="WG Süd")

      res = post(srv, "/einstellungen", me, {"gruppenname" => "  "})
      res.status_code.should eq 422
      error_of(body_of(res)).should contain "Namen"
      body_of(res).should contain %(value="  ")
      activity_texts(srv.store).should contain "Gruppe umbenannt: „Zipfelkasse“ → „WG Süd“"
    end
  end

  it "adds, renames, archives and restores participants" do
    with_group do |srv, f, me|
      status, body = page(srv, "/einstellungen/teilnehmer", me)
      status.should eq 200
      body.should contain %(value="Ben")
      body.should contain "das bist du"

      res = post(srv, "/einstellungen/teilnehmer", me, {"name" => "  Dora "})
      {res.status_code, location(res), flash_of(res)}.should eq({303, "/einstellungen/teilnehmer", "„Dora“ hinzugefügt."})
      res = post(srv, "/einstellungen/teilnehmer", me, {"name" => "dora"})
      res.status_code.should eq 422
      error_of(body_of(res)).should contain "gibt es schon"
      body_of(res).should contain %(value="dora")
      dora = srv.store.list_participants.find!(&.name.==("Dora")).id

      res = post(srv, "/einstellungen/teilnehmer/#{dora}", me, {"name" => "Dorothea"})
      {res.status_code, flash_of(res)}.should eq({303, "Gespeichert."})
      srv.store.get_participant(dora).name.should eq "Dorothea"
      post(srv, "/einstellungen/teilnehmer/#{dora}", me, {"name" => "Ben"}).status_code.should eq 422
      post(srv, "/einstellungen/teilnehmer/999", me, {"name" => "X"}).status_code.should eq 404
      post(srv, "/einstellungen/teilnehmer/abc", me, {"name" => "X"}).status_code.should eq 404

      f.must_create(f.equal("Einkauf", 3000, "2026-09-30", f.anna, f.anna, f.ben, f.cleo))
      res = post(srv, "/einstellungen/teilnehmer/#{f.ben}/archivieren", me)
      res.status_code.should eq 422
      error_of(body_of(res)).should contain "Ben hat noch einen Saldo von -10,00 €"
      body_of(res).should contain %(1 Ausgabe · Saldo <span class="amount negative">-10,00 €</span>)

      res = post(srv, "/einstellungen/teilnehmer/#{dora}/archivieren", me)
      {res.status_code, location(res), flash_of(res)}.should eq({303, "/einstellungen/teilnehmer", "„Dorothea“ archiviert."})
      srv.store.get_participant(dora).archived?.should be_true
      _, body = page(srv, "/einstellungen/teilnehmer", me)
      body.should contain "Archiviert"
      body.should contain "/einstellungen/teilnehmer/#{dora}/reaktivieren"
      res = post(srv, "/einstellungen/teilnehmer/#{dora}/reaktivieren", me)
      {res.status_code, flash_of(res)}.should eq({303, "„Dorothea“ reaktiviert."})
      srv.store.get_participant(dora).archived?.should be_false
      post(srv, "/einstellungen/teilnehmer/999/archivieren", me).status_code.should eq 404

      texts = activity_texts(srv.store)
      ["Person „Dora“ hinzugefügt", "Person „Dora“ umbenannt in „Dorothea“",
       "Person „Dorothea“ archiviert", "Person „Dorothea“ reaktiviert"].each { |want| texts.should contain want }
    end
  end

  it "adds, renames, moves, archives and restores categories" do
    with_group do |srv, f, me|
      status, body = page(srv, "/einstellungen/kategorien", me)
      status.should eq 200
      body.should contain %(value="Lebensmittel")

      res = post(srv, "/einstellungen/kategorien", me, {"name" => "Haustier"})
      {res.status_code, location(res), flash_of(res)}.should eq({303, "/einstellungen/kategorien", "Kategorie „Haustier“ hinzugefügt."})
      res = post(srv, "/einstellungen/kategorien", me, {"name" => ""})
      res.status_code.should eq 422
      error_of(body_of(res)).should contain "Namen"
      first, second = srv.store.list_categories[0], srv.store.list_categories[1]

      post(srv, "/einstellungen/kategorien/#{first.id}", me, {"name" => "Essen & Trinken"}).status_code.should eq 303
      res = post(srv, "/einstellungen/kategorien/#{second.id}/hoch", me)
      {res.status_code, location(res), flash_of(res)}.should eq({303, "/einstellungen/kategorien#kategorie-#{second.id}", nil})
      cats = srv.store.list_categories
      cats[0].id.should eq second.id
      cats[1].name.should eq "Essen & Trinken"
      act = srv.store.list_activity(Zipfelkasse::Store::ActivityFilter.new(limit: 1)).first
      act.action.should eq Zipfelkasse::Store::Action::SettingsUpdated
      act.actor_id.should eq f.anna
      act.details.text.should eq "Kategorie „#{second.name}“ nach oben verschoben"
      _, body = page(srv, "/einstellungen/kategorien", me)
      body.should contain %(aria-label="#{second.name} nach oben" disabled>)

      post(srv, "/einstellungen/kategorien/#{second.id}/runter", me).status_code.should eq 303
      res = post(srv, "/einstellungen/kategorien/#{first.id}/archivieren", me)
      {res.status_code, location(res), flash_of(res)}.should eq({303, "/einstellungen/kategorien", "Kategorie „Essen & Trinken“ archiviert."})
      srv.store.get_category(first.id).archived?.should be_true
      srv.store.list_categories.map(&.id).should_not contain first.id
      _, body = page(srv, "/einstellungen/kategorien", me)
      body.should contain "/einstellungen/kategorien/#{first.id}/reaktivieren"
      post(srv, "/einstellungen/kategorien/#{first.id}/hoch", me).status_code.should eq 404
      post(srv, "/einstellungen/kategorien/#{first.id}/reaktivieren", me).status_code.should eq 303
      srv.store.get_category(first.id).archived?.should be_false
      post(srv, "/einstellungen/kategorien/999/archivieren", me).status_code.should eq 404
    end
  end

  it "serves the PWA manifest, service worker and icons" do
    with_group do |srv, _, me|
      srv.store.set_group_name(nil, "WG Süd")
      res = srv.get("/manifest.webmanifest")
      res.status_code.should eq 200
      res.headers["Content-Type"].should start_with "application/manifest+json"
      m = JSON.parse(res.body)
      {m["name"], m["lang"], m["display"], m["start_url"], m["theme_color"]}.should eq({"WG Süd", "de", "standalone", "/", "#047756"})
      purposes = m["icons"].as_a.map do |icon|
        res = srv.get(icon["src"].as_s)
        {res.status_code, res.headers["Content-Type"]}.should eq({200, "image/png"})
        "#{icon["sizes"]} #{icon["purpose"]}"
      end
      purposes.should eq ["192x192 any", "512x512 any", "512x512 maskable"]

      res = srv.get("/sw.js")
      res.status_code.should eq 200
      res.headers["Content-Type"].should start_with "text/javascript"
      res.headers["Cache-Control"].should eq "no-cache"
      res.body.should contain "addEventListener"
      res.body.should_not contain "caches."
      res = srv.get("/favicon.ico")
      {res.status_code, res.headers["Content-Type"]}.should eq({200, "image/png"})
      srv.get("/static/icons/apple-touch-icon.png").status_code.should eq 200
      _, body = page(srv, "/", me)
      [%(rel="manifest" href="/manifest.webmanifest"), %(rel="apple-touch-icon"), "/static/app.js?v="].each do |want|
        body.should contain want
      end
    end
  end

  it "serves the scripts and icons, and the CSS has the promised classes" do
    with_server do |srv|
      ["/static/app.js", "/static/expense-form.js", "/static/icons.svg"].each do |path|
        srv.get(path).status_code.should eq 200
      end
      css = srv.get("/static/app.css").body
      %w(.container .main .site-header .site-header-inner .brand .whoami .tabs
        .card .card-header .card-title .card-description .card-content .card-footer
        .btn .btn-primary .btn-secondary .btn-outline .btn-ghost .btn-destructive .btn-sm .btn-lg .btn-block
        .form .field .field-error .help .table-wrap .alert .alert-success .alert-destructive
        .link-list .stack .stack-sm .row .muted .amount .positive .negative .sr-only).each do |cls|
        {" ", ",", "{"}.any? { |c| css.includes?(cls + c) }.should be_true, "app.css: class #{cls} missing"
      end
    end
  end
end
