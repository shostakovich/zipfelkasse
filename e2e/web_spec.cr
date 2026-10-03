require "./e2e_helper"

# Black-box scenarios of the core web app: identity, expenses, balances, activity, settings, security, PWA, CLI.
# Each describe block runs in its own small, fresh world (empty database).
private alias W = E2E::Web

describe "Web: identity" do
  world = E2E::World.new("web-identity")
  after_all { world.stop }

  scenario "visitors without a person are sent to /wer", world do
    anon = world.user
    r = anon.get("/salden?x=1")
    r.status.should eq 303
    r.location.should eq "/wer?zurueck=%2Fsalden%3Fx%3D1"
    anon.get("/ausgaben/neu?von=1&an=2").location.should eq "/wer?zurueck=%2Fausgaben%2Fneu%3Fvon%3D1%26an%3D2"
    anon.get("/gibt-es-nicht").location.should eq "/wer?zurueck=%2Fgibt-es-nicht"
    # No return target for "/" (with or without query), POST and HEAD.
    anon.get("/").location.should eq "/wer"
    anon.get("/?q=pizza").location.should eq "/wer"
    r = anon.post("/einstellungen", {"gruppenname" => "X"})
    {r.status, r.location}.should eq({303, "/wer"})
    r = anon.head("/salden")
    {r.status, r.location}.should eq({303, "/wer"})
    # /api/ answers with JSON instead.
    r = anon.get("/api/kurs?waehrung=USD")
    r.status.should eq 401
    r.content_type.should start_with "application/json"
    r.json.should eq JSON.parse(%({"error":"Bitte zuerst auswählen, wer du bist."}))
    # Public paths work without a person.
    r = anon.get("/healthz")
    {r.status, r.body}.should eq({200, "ok\n"})
    r.content_type.should eq "text/plain; charset=utf-8"
    ["/wer", "/manifest.webmanifest", "/sw.js", "/favicon.ico", "/static/app.css"].each do |p|
      anon.get(p).status.should eq 200
    end
    world.app.log.should_not contain "panic"
  end

  scenario "the /wer page before anybody exists", world do
    anon = world.user
    r = anon.get("/wer?zurueck=%2Fsalden")
    r.status.should eq 200
    r.html?.should be_true
    r.headers["Cache-Control"].should eq "no-store"
    W.page_title(r).should eq "Wer bist du? · Zipfelkasse"
    W.h1(r).should eq "Wer bist du?"
    r.text.should contain "Wähle dich aus. Die App merkt sich das auf diesem Gerät."
    r.text.should contain "Noch niemand da. Leg dich unten als erste Person an."
    W.nav?(r).should be_false
    W.whoami(r).should be_nil
    W.text_of(r, "//h2").should eq "Neue Person"
    W.attr(r, %(//form[@action="/wer/neu"]//input[@name="zurueck"]), "value").should eq "/salden"
    W.attr(r, %(//form[@action="/wer/neu"]//input[@name="name"]), "maxlength").should eq "60"
    W.text_of(r, %(//form[@action="/wer/neu"]//button)).should eq "Anlegen und auswählen"
    # Unsafe return targets are replaced by "/".
    ["//evil.example", "https://evil.example", "/wer", "javascript:alert(1)"].each do |bad|
      W.attr(anon.get("/wer?zurueck=#{URI.encode_www_form(bad)}"), %(//input[@name="zurueck"]), "value").should eq "/"
    end
  end

  scenario "creating oneself sets the cookie and a welcome flash", world do
    user = world.user
    r = user.post("/wer/neu", {"name" => "  Jörg  ", "zurueck" => "/salden"})
    r.status.should eq 303
    r.location.should eq "/salden"
    wer = W.cookie(r, "wer").not_nil!
    wer.value.should eq "1"
    wer.path.should eq "/"
    wer.http_only.should be_true
    wer.secure.should be_false
    wer.samesite.should eq HTTP::Cookie::SameSite::Lax
    wer.max_age.should eq 365.days
    flash = W.cookie(r, "flash").not_nil!
    flash.path.should eq "/"
    flash.http_only.should be_true
    flash.samesite.should eq HTTP::Cookie::SameSite::Lax
    flash.max_age.should eq 60.seconds
    r.flash.should eq "Willkommen!"
    user.me.should eq 1

    # The next page shows (and consumes) the flash.
    r = user.get("/salden")
    r.status.should eq 200
    W.shown_flash(r).should eq "Willkommen!"
    W.cookie(r, "flash").not_nil!.value.should eq ""
    W.whoami(r).should eq "Jörg"
    r.text.should contain "Du bist Jörg · wechseln"
    W.current_tab(r).should eq "/salden"
    W.page_title(r).should eq "Salden · Zipfelkasse"
    W.attr(r, "//body", "class").should eq "has-tabbar"
    W.texts(r, %(//nav[@aria-label="Hauptnavigation"]/a)).should eq ["Ausgaben", "Salden", "Aktivität", "Einstellungen"]
    r = user.get("/salden")
    W.shown_flash(r).should be_nil
    W.cookie(r, "flash").should be_nil

    # Logged with the new person as actor.
    W.activity_texts(world).should eq ["Person „Jörg“ hinzugefügt"]
    user.get("/aktivitaet").text.should contain "Jörg: Person „Jörg“ hinzugefügt"
  end

  scenario "names for new people are checked", world do
    user = world.user
    r = user.post("/wer/neu", {"name" => "  jörg ", "zurueck" => "/salden"})
    r.status.should eq 422
    r.error_message.should eq "„jörg“ gibt es schon."
    W.attr(r, %(//form[@action="/wer/neu"]//input[@name="name"]), "value").should eq "  jörg "
    W.attr(r, %(//form[@action="/wer/neu"]//input[@name="zurueck"]), "value").should eq "/salden"
    W.page_title(r).should eq "Wer bist du? · Zipfelkasse"
    r.cookies["wer"]?.should be_nil
    user.post("/wer/neu", {"name" => "   "}).error_message.should eq "Bitte einen Namen für die Person angeben."
    user.post("/wer/neu", {"name" => "x" * 61}).error_message.should eq "Der Name ist zu lang (höchstens 60 Zeichen)."
    user.post("/wer/neu", {"name" => "ä" * 60}).status.should eq 303
    W.count(world, "SELECT count(*) FROM participants").should eq 2
  end

  scenario "picking a person and the return target", world do
    user = world.user
    page = user.get("/wer")
    buttons = page.doc.xpath_nodes(%(//form[@action="/wer"]//button[@name="id"]))
    buttons.map { |b| {b["value"], W.squish(b.content)} }.should eq [{"1", "Jörg"}, {"2", "ä" * 60}]
    {
      "/aktivitaet"           => "/aktivitaet",
      "/salden?x=1#a"         => "/salden?x=1#a",
      "/ausgaben/neu?von=%2F" => "/ausgaben/neu?von=%2F",
      ""                      => "/",
      "//evil.example"        => "/",
      "https://evil.example"  => "/",
      "evil"                  => "/",
      "/\\evil"               => "/",
      "/a\\b"                 => "/",
      "/%09/evil.example/x"   => "/",
      "/\t/evil.example/x"    => "/",
      "/\r\n/evil.example"    => "/",
      "/x\u0085y"             => "/",
      "/%2F/evil.example"     => "/",
      "/wer"                  => "/",
      "/wer?zurueck=/"        => "/",
      "/werbung"              => "/",
      "/wer/neu"              => "/",
    }.each do |ret, want|
      r = user.post("/wer", {"id" => "1", "zurueck" => ret})
      {ret, r.status, r.location}.should eq({ret, 303, want})
    end
    # The current person is marked on /wer.
    W.attr(user.get("/wer"), %(//button[@aria-current="true"]), "value").should eq "1"
    r = user.post("/wer", {"id" => "2", "zurueck" => "/"})
    user.me.should eq 2
    W.whoami(user.get("/einstellungen")).should eq "ä" * 60

    ["999", "abc", "", "0"].each do |id|
      r = user.post("/wer", {"id" => id, "zurueck" => "/salden"})
      r.status.should eq 422
      r.error_message.should eq "Diese Person gibt es nicht (mehr)."
      W.attr(r, %(//form[@action="/wer"]//input[@name="zurueck"]), "value").should eq "/salden"
    end
    user.me.should eq 2
  end

  scenario "the cookie is Secure only behind HTTPS", world do
    user = world.user
    r = user.post("/wer", {"id" => "1"}, HTTP::Headers{"X-Forwarded-Proto" => "https"})
    W.cookie(r, "wer").not_nil!.secure.should be_true
    r = user.post("/wer/neu", {"name" => "Kim"}, HTTP::Headers{"X-Forwarded-Proto" => "https"})
    W.cookie(r, "wer").not_nil!.secure.should be_true
    W.cookie(r, "flash").not_nil!.secure.should be_false
    r = user.post("/wer", {"id" => "1"}, HTTP::Headers{"X-Forwarded-Proto" => "http"})
    W.cookie(r, "wer").not_nil!.secure.should be_false
  end

  scenario "unknown and archived people count as nobody", world do
    joerg = world.user
    joerg.login("Jörg")
    ben = world.user
    ben.post("/wer/neu", {"name" => "Ben"}).status.should eq 303
    ben_id = ben.me.not_nil!
    r = joerg.post("/einstellungen/teilnehmer/#{ben_id}/archivieren")
    {r.status, r.flash}.should eq({303, "„Ben“ archiviert."})

    r = ben.get("/salden")
    {r.status, r.location}.should eq({303, "/wer?zurueck=%2Fsalden"})
    ben.get("/api/kurs?waehrung=USD").status.should eq 401
    r = ben.get("/wer")
    r.status.should eq 200
    W.nav?(r).should be_false
    W.whoami(r).should be_nil
    W.texts(r, %(//form[@action="/wer"]//button)).should_not contain "Ben"
    r = ben.post("/wer", {"id" => ben_id.to_s})
    {r.status, r.error_message}.should eq({422, "Diese Person gibt es nicht (mehr)."})
    # The stale cookie is not cleared.
    r.cookies["wer"]?.should be_nil
    ben.me.should eq ben_id

    other = world.user
    ["999", "abc", "-1", ""].each do |v|
      W.set_cookie(other, "wer", v)
      other.get("/einstellungen").location.should eq "/wer?zurueck=%2Feinstellungen"
    end
  end
end

# Rows of the split card: {id, checked?, value, shown share}.
private def split_rows(r : E2E::Response) : Array({String, Bool, String, String})
  r.doc.xpath_nodes(%(//div[@class="split-row"])).map do |row|
    {
      row["data-id"],
      !row.xpath_node(%(.//input[@name="teil"][@checked])).nil?,
      row.xpath_node(%(.//input[starts-with(@name, "wert_")])).try(&.["value"]?) || "",
      W.squish(row.xpath_node(%(.//*[@data-share])).try(&.content) || ""),
    }
  end
end

# Replaces (or adds) single values of a form; "teil" replaces all boxes.
private def change(form : Array({String, String}), changes : Hash(String, String | Array(String))) : Array({String, String})
  out = form.reject { |k, _| changes.has_key?(k) }
  changes.each do |k, v|
    case v
    when String then out << {k, v}
    else             v.each { |x| out << {k, x} }
    end
  end
  out
end

# A rate as the form shows it (shortest representation, decimal comma).
private def rate_input(rate : Float64) : String
  rate.to_s.sub(/\.0$/, "").sub('.', ',')
end

private def eur_cents(minor : Int64, decimals : Int32, rate : Float64) : Int64
  (minor.to_f / 10.0**decimals / rate * 100).round(:ties_away).to_i64
end

describe "Web: expenses" do
  world = E2E::World.new("web-expenses")
  after_all { world.stop }
  anna, ben, cleo = 1_i64, 2_i64, 3_i64
  all = [anna, ben, cleo]

  scenario "creating expenses in every split mode", world do
    user = world.user
    user.post("/wer/neu", {"name" => "Anna"}).status.should eq 303
    user.post("/einstellungen/teilnehmer", {"name" => "Ben"}).flash.should eq "„Ben“ hinzugefügt."
    user.post("/einstellungen/teilnehmer", {"name" => "Cleo"}).status.should eq 303

    new_page = user.get("/ausgaben/neu")
    W.page_title(new_page).should eq "Neue Ausgabe · Zipfelkasse"
    W.h1(new_page).should eq "Ausgabe hinzufügen"
    W.current_tab(new_page).should eq "/"
    W.attr(new_page, "//form[@id='expense-form']", "action").should eq "/ausgaben/neu"
    W.attr(new_page, "//form[@id='expense-form']", "data-rotation").should eq "1"
    W.input(new_page, "datum").should eq "2026-10-03"
    W.selected(new_page, "bezahlt_von").should eq "1"
    W.selected(new_page, "waehrung").should eq "EUR"
    W.selected(new_page, "aufteilung").should eq "equal"
    W.selected(new_page, "kategorie").should be_nil
    W.texts(new_page, %(//select[@name="waehrung"]/option)).should eq [
      "EUR – Euro", "USD", "GBP", "CHF", "DKK", "SEK", "NOK", "PLN", "CZK", "HUF", "TRY", "JPY", "CAD", "AUD", "Andere …",
    ]
    W.texts(new_page, %(//select[@name="aufteilung"]/option)).should eq ["Gleichmäßig", "Nach Anteilen", "Nach Prozent", "Nach Beträgen"]
    W.texts(new_page, %(//select[@name="kategorie"]/option)).first(3).should eq ["Keine Kategorie", "Lebensmittel", "Restaurant"]
    split_rows(new_page).should eq [{"1", true, "", ""}, {"2", true, "", ""}, {"3", true, "", ""}]
    new_page.doc.xpath_node(%(//details[@open])).should be_nil
    new_page.doc.xpath_node(%(//input[@name="rueckzahlung"][@checked])).should be_nil
    W.text_of(new_page, %(//form[@id="expense-form"]//button[@type="submit"])).should eq "Anlegen"
    new_page.doc.xpath_node(%(//button[@formaction])).should be_nil
    W.attr(new_page, %(//script[contains(@src, "expense-form.js")]), "src").not_nil!.should match(/^\/static\/expense-form\.js\?v=[0-9a-f]{10}$/)

    cases = [
      {"Gleich 1", "equal", "10,00", all, {} of Int64 => String, {anna => 333_i64, ben => 334_i64, cleo => 333_i64}},
      {"Gleich 2", "equal", "10,00", all, {} of Int64 => String, {anna => 333_i64, ben => 333_i64, cleo => 334_i64}},
      {"Zu zweit", "equal", "10,01", [ben, cleo], {} of Int64 => String, {ben => 500_i64, cleo => 501_i64}},
      {"Anteile", "shares", "40,00", all, {anna => "2", ben => "1", cleo => ""}, {anna => 2000_i64, ben => 1000_i64, cleo => 1000_i64}},
      {"Prozent", "percent", "10,00", all, {anna => "50", ben => "25,5", cleo => "24,5"}, {anna => 500_i64, ben => 255_i64, cleo => 245_i64}},
      {"Beträge", "amount", "10,00", all, {anna => "5", ben => "3,50", cleo => "1,50"}, {anna => 500_i64, ben => 350_i64, cleo => 150_i64}},
    ]
    cases.each_with_index do |(title, mode, amount, whom, values, want), i|
      r = user.post("/ausgaben/neu", W.expense(titel: title, betrag: amount, teil: whom, aufteilung: mode, werte: values, kategorie: "1"))
      {title, r.status, r.location, r.flash}.should eq({title, 303, "/", "Ausgabe „#{title}“ angelegt."})
      W.newest_expense(world).should eq i + 1
      W.shares(world, i + 1_i64).should eq want
    end
    W.count(world, "SELECT count(*) FROM expenses WHERE split_mode = 'equal'").should eq 3

    # The edit form shows values and computed shares.
    r = user.get("/ausgaben/4")
    W.selected(r, "aufteilung").should eq "shares"
    r.doc.xpath_node(%(//details[@open])).should_not be_nil
    split_rows(r).should eq [{"1", true, "2", "20,00 €"}, {"2", true, "1", "10,00 €"}, {"3", true, "1", "10,00 €"}]
    W.texts(r, %(//span[@data-unit])).uniq.should eq ["Anteile"]
    r = user.get("/ausgaben/5")
    split_rows(r).should eq [{"1", true, "50,00", "5,00 €"}, {"2", true, "25,50", "2,55 €"}, {"3", true, "24,50", "2,45 €"}]
    W.texts(r, %(//span[@data-unit])).uniq.should eq ["%"]
    r = user.get("/ausgaben/6")
    split_rows(r).should eq [{"1", true, "5,00", "5,00 €"}, {"2", true, "3,50", "3,50 €"}, {"3", true, "1,50", "1,50 €"}]
    W.texts(r, %(//span[@data-unit])).uniq.should eq ["€"]
    r = user.get("/ausgaben/3")
    split_rows(r).should eq [{"1", false, "", ""}, {"2", true, "", "5,00 €"}, {"3", true, "", "5,01 €"}]
    W.attr(user.get("/ausgaben/neu"), "//form[@id='expense-form']", "data-rotation").should eq "7"

    # Titles are stored with collapsed whitespace.
    r = user.post("/ausgaben/neu", W.expense(titel: "  Wochen \t  markt ", teil: all))
    r.flash.should eq "Ausgabe „Wochen markt“ angelegt."
    W.input(user.get("/ausgaben/7"), "titel").should eq "Wochen markt"
  end

  scenario "every validation message of the expense form", world do
    user = world.user
    user.login("Anna")
    base = W.expense(titel: "Mein Titel", notiz: "Bitte behalten", kategorie: "2", teil: all)
    before = W.count(world, "SELECT count(*) FROM expenses")
    acts = W.count(world, "SELECT count(*) FROM activity")
    shares_mode = {"aufteilung" => "shares", "wert_1" => "1", "wert_2" => "1", "wert_3" => "1"}
    [
      {"Bitte einen Titel angeben.", {"titel" => " \t "}},
      {"Der Titel ist zu lang (höchstens 200 Zeichen).", {"titel" => "x" * 201}},
      {"Die Notiz ist zu lang (höchstens 2000 Zeichen).", {"notiz" => "n" * 2001}},
      {"Bitte ein Datum angeben.", {"datum" => " "}},
      {"Ungültiges Datum „2026-02-30“.", {"datum" => "2026-02-30"}},
      {"Ungültiges Datum „morgen“.", {"datum" => "morgen"}},
      {"Das Datum „31.12.1999“ liegt nicht zwischen 2000 und 2100.", {"datum" => "31.12.1999"}},
      {"Ungültige Währung „EURO“ – bitte einen dreistelligen ISO-Code wie USD angeben.", {"waehrung" => "", "waehrung_andere" => "euro"}},
      {"Bitte einen Betrag eingeben.", {"betrag" => "  "}},
      {"Ungültiger Betrag „12,3,4“.", {"betrag" => "12,3,4"}},
      {"Ungültiger Betrag „abc“.", {"betrag" => "abc"}},
      {"Der Betrag muss größer als 0 sein.", {"betrag" => "0"}},
      {"Der Betrag muss größer als 0 sein.", {"betrag" => "-5"}},
      {"Höchstens 2 Nachkommastellen erlaubt.", {"betrag" => "1,234"}},
      {"Der Betrag ist zu groß.", {"betrag" => "1234567890123456"}},
      {"Der Betrag ist zu groß.", {"betrag" => "20.000.000.000"}},
      {"Bitte angeben, wer bezahlt hat.", {"bezahlt_von" => ""}},
      {"Unbekannte Person in der Ausgabe.", {"bezahlt_von" => "99"}},
      {"Unbekannte Kategorie.", {"kategorie" => "99"}},
      {"Bitte mindestens eine Person ankreuzen, für die bezahlt wurde.", {"teil" => [] of String}},
      {"Die Prozente müssen zusammen 100 % ergeben (aktuell 90,00 %).", {"aufteilung" => "percent", "wert_1" => "50", "wert_2" => "20", "wert_3" => "20"}},
      {"Die Prozente müssen zusammen 100 % ergeben.", {"aufteilung" => "percent", "wert_1" => "150"}},
      {"Ben: Ungültige Prozentangabe „abc“.", {"aufteilung" => "percent", "wert_1" => "100", "wert_2" => "abc"}},
      {"Ben: Negative Werte sind nicht erlaubt.", {"aufteilung" => "percent", "wert_1" => "125", "wert_2" => "-25"}},
      {"Die Beträge müssen zusammen 30,00 € ergeben (aktuell 10,00 €).", {"aufteilung" => "amount", "wert_1" => "10"}},
      {"Ben: Ungültiger Betrag „1,2,3“.", {"aufteilung" => "amount", "wert_2" => "1,2,3"}},
      {"Cleo: Höchstens 2 Nachkommastellen erlaubt.", {"aufteilung" => "amount", "wert_3" => "0,001"}},
      {"Ben: Anteile müssen ganze Zahlen sein („1,5“).", shares_mode.merge({"wert_2" => "1,5"})},
      {"Ben: Negative Werte sind nicht erlaubt.", shares_mode.merge({"wert_2" => "-1"})},
      {"Die Summe der Anteile muss größer als 0 sein.", shares_mode.merge({"wert_1" => "0", "wert_2" => "0", "wert_3" => "0"})},
      {"Anteile dürfen höchstens 1000000 sein.", shares_mode.merge({"wert_1" => "1000001"})},
      {"Eine Rückzahlung geht an genau eine Person – bitte genau einen Empfänger ankreuzen.", {"rueckzahlung" => "1"}},
      {"Eine Rückzahlung geht an genau eine Person – bitte genau einen Empfänger ankreuzen.", {"rueckzahlung" => "1", "teil" => [] of String}},
      {"Bei einer Rückzahlung müssen Zahler und Empfänger verschieden sein.", {"rueckzahlung" => "1", "teil" => ["1"]}},
      {"Dieser Betrag darf keine Nachkommastellen haben.", {"waehrung" => "JPY", "betrag" => "15,5"}},
      {"Ungültiger Wechselkurs „abc“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €).", {"waehrung" => "USD", "kurs" => "abc"}},
      {"Ungültiger Wechselkurs „0“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €).", {"waehrung" => "USD", "kurs" => "0"}},
      {"Umgerechnet ergibt der Betrag 0 € – bitte Betrag und Kurs prüfen.", {"waehrung" => "USD", "betrag" => "0,01", "kurs" => "1000"}},
      {"Für XAF ist am 01.10.2026 kein Wechselkurs verfügbar. Kurs bitte von Hand eintragen.", {"waehrung" => "", "waehrung_andere" => "xaf", "betrag" => "1000"}},
    ].each do |msg, changes|
      form = change(base, changes.transform_values { |v| v.as(String | Array(String)) })
      r = user.post("/ausgaben/neu", form)
      {changes, r.status}.should eq({changes, 422})
      {changes, r.error_message}.should eq({changes, msg})
      # The page is the form again, with the input kept.
      W.page_title(r).should eq "Neue Ausgabe · Zipfelkasse"
      W.attr(r, "//form[@id='expense-form']", "action").should eq "/ausgaben/neu"
      fields = form.to_h
      W.input(r, "titel").should eq fields["titel"]
      W.text_of(r, "//textarea[@name='notiz']").should eq fields["notiz"]
      W.input(r, "betrag").should eq fields["betrag"].strip
      W.selected(r, "kategorie").should eq fields["kategorie"] unless fields["kategorie"] == "99"
      W.checked(r).should eq form.select { |k, _| k == "teil" }.map(&.[1])
      r.cookies["flash"]?.should be_nil
    end
    W.count(world, "SELECT count(*) FROM expenses").should eq before
    W.count(world, "SELECT count(*) FROM activity").should eq acts

    # Boxes of unknown people are ignored.
    r = user.post("/ausgaben/neu", change(base, {"teil" => ["1", "77", "x"]} of String => String | Array(String)))
    {r.status, r.flash}.should eq({303, "Ausgabe „Mein Titel“ angelegt."})
    W.shares(world, W.newest_expense(world)).should eq({anna => 3000})

    # Mode, values, reimbursement flag and the other currency are kept too.
    r = user.post("/ausgaben/neu", change(base, shares_mode.merge({"wert_2" => "1,5", "waehrung" => "", "waehrung_andere" => "chf"}).transform_values(&.as(String | Array(String)))))
    r.status.should eq 422
    W.selected(r, "aufteilung").should eq "shares"
    r.doc.xpath_node(%(//details[@open])).should_not be_nil
    split_rows(r).map { |row| row[2] }.should eq ["1", "1,5", "1"]
    W.selected(r, "waehrung").should eq ""
    W.input(r, "waehrung_andere").should eq "CHF"
    W.text_of(r, %(//span[@id="betrag-einheit"])).should eq "CHF"
    r = user.post("/ausgaben/neu", change(base, {"rueckzahlung" => "1"}.transform_values(&.as(String | Array(String)))))
    r.doc.xpath_node(%(//input[@name="rueckzahlung"][@checked])).should_not be_nil

    # A broken form encoding is a bad request.
    r = W.raw(user, "POST", "/ausgaben/neu", "titel=%zz&betrag=1") do |app|
      HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Origin" => app.base_url}
    end
    r.status.should eq 400
    W.h1(r).should eq "Ungültige Anfrage."
  end

  scenario "editing an expense records the changes", world do
    user = world.user
    user.login("Anna")
    r = user.get("/ausgaben/1")
    r.status.should eq 200
    W.page_title(r).should eq "Gleich 1 · Zipfelkasse"
    W.h1(r).should eq "Ausgabe bearbeiten"
    W.text_of(r, "//div[@class='card-header']/p[@class='card-description']").should eq "Angelegt am 03.10.2026, 12:00"
    W.attr(r, "//form[@id='expense-form']", "action").should eq "/ausgaben/1"
    W.attr(r, "//form[@id='expense-form']", "data-rotation").should eq "1"
    W.input(r, "titel").should eq "Gleich 1"
    W.input(r, "betrag").should eq "10,00"
    W.input(r, "datum").should eq "2026-10-01"
    W.selected(r, "kategorie").should eq "1"
    W.text_of(r, %(//form[@id="expense-form"]//button[@type="submit"][not(@formaction)])).should eq "Speichern"
    W.attr(r, %(//button[@formaction="/ausgaben/1/loeschen"]), "data-confirm").should eq(
      "Diese Ausgabe wirklich löschen? Sie verschwindet aus Liste und Salden; im Aktivitätsprotokoll bleibt sie sichtbar.")
    W.text_of(r, %(//a[@href="/einstellungen/wiederkehrend/neu?ausgabe=1"])).should eq "Als wiederkehrend einrichten"
    W.texts(r, %(//div[@class="activity-item"])).should eq ["Anna hat „Gleich 1“ angelegt (10,00 €). 03.10.2026, 12:00"]
    W.attr(r, "//time", "datetime").should eq "2026-10-03T10:00:00Z"

    form = W.expense(titel: "Gleich groß", betrag: "45", teil: [anna, ben], aufteilung: "shares",
      werte: {anna => "1", ben => "2"}, kategorie: "", notiz: "neu", datum: "02.10.2026")
    r = user.post("/ausgaben/1", form)
    {r.status, r.location, r.flash}.should eq({303, "/", "Ausgabe „Gleich groß“ gespeichert."})
    W.shares(world, 1).should eq({anna => 1500, ben => 3000})
    r = user.get("/ausgaben/1")
    W.page_title(r).should eq "Gleich groß · Zipfelkasse"
    split_rows(r).should eq [{"1", true, "1", "15,00 €"}, {"2", true, "2", "30,00 €"}, {"3", false, "", ""}]
    W.input(r, "datum").should eq "2026-10-02"
    W.texts(r, %(//div[@class="activity-item"]//div[@class="activity-main"]/div[1])).should eq [
      "Anna hat „Gleich groß“ geändert.", "Anna hat „Gleich 1“ angelegt (10,00 €).",
    ]
    W.texts(r, %(//ul[@class="changes"]/li)).should eq [
      "Titel: Gleich 1 → Gleich groß",
      "Betrag: 10,00 € → 45,00 €",
      "Originalbetrag: 10,00 € → 45,00 €",
      "Datum: 01.10.2026 → 02.10.2026",
      "Kategorie: Lebensmittel → –",
      "Notiz: – → neu",
      "Aufteilung: Gleichmäßig: Anna 3,33 €, Ben 3,34 €, Cleo 3,33 € → Nach Anteilen: Anna 15,00 €, Ben 30,00 €",
    ]
    W.text_of(r, %(//ul[@class="changes"]/li[2]/del)).should eq "10,00 €"
    W.text_of(r, %(//ul[@class="changes"]/li[2]/ins)).should eq "45,00 €"

    # Saving unchanged changes nothing (no history entry).
    acts = W.count(world, "SELECT count(*) FROM activity")
    r = user.post("/ausgaben/1", form)
    {r.status, r.flash}.should eq({303, "Ausgabe „Gleich groß“ gespeichert."})
    W.count(world, "SELECT count(*) FROM activity").should eq acts
    # Only the weights change: listed as Anteile.
    user.post("/ausgaben/1", change(form, {"wert_1" => "2", "wert_2" => "4"} of String => String | Array(String))).status.should eq 303
    W.texts(user.get("/ausgaben/1"), %(//ul[@class="changes"]/li)).first.should eq "Anteile: Anna 1, Ben 2 → Anna 2, Ben 4"

    # Errors while editing keep the edit page.
    r = user.post("/ausgaben/1", change(form, {"betrag" => ""} of String => String | Array(String)))
    r.status.should eq 422
    r.error_message.should eq "Bitte einen Betrag eingeben."
    W.h1(r).should eq "Ausgabe bearbeiten"
    W.page_title(r).should eq "Gleich groß · Zipfelkasse"
    W.attr(r, "//form[@id='expense-form']", "action").should eq "/ausgaben/1"
    W.texts(r, %(//h2[@class="card-title"])).should contain "Verlauf"
    W.count(world, "SELECT amount_cents FROM expenses WHERE id = 1").should eq 4500

    # Turned into a reimbursement.
    r = user.post("/ausgaben/1", change(form, {"rueckzahlung" => "1", "teil" => ["2"]} of String => String | Array(String)))
    {r.status, r.flash}.should eq({303, "Rückzahlung „Gleich groß“ gespeichert."})
    W.texts(user.get("/ausgaben/1"), %(//ul[@class="changes"]/li)).first.should eq "Art: Ausgabe → Rückzahlung"
  end

  scenario "deleting an expense", world do
    user = world.user
    user.login("Anna")
    r = user.post("/ausgaben/2/loeschen")
    {r.status, r.location, r.flash}.should eq({303, "/", "„Gleich 2“ gelöscht."})
    W.count(world, "SELECT count(*) FROM expenses WHERE id = 2 AND deleted_at IS NOT NULL").should eq 1
    home = user.get("/")
    W.shown_flash(home).should eq "„Gleich 2“ gelöscht."
    home.doc.xpath_node(%(//a[@id="ausgabe-2"])).should be_nil
    home.doc.xpath_node(%(//a[@id="ausgabe-3"])).should_not be_nil

    r = user.get("/ausgaben/2")
    r.status.should eq 200
    W.h1(r).should eq "Gelöschte Ausgabe"
    W.page_title(r).should eq "Gleich 2 · Zipfelkasse"
    r.doc.xpath_node(%(//fieldset[@disabled])).should_not be_nil
    W.text_of(r, %(//p[@class="alert alert-destructive"])).should eq(
      "Diese Ausgabe wurde am 03.10.2026, 12:00 gelöscht und zählt nicht mehr zu den Salden.")
    r.doc.xpath_node(%(//form[@id="expense-form"]//button[@type="submit"])).should be_nil
    r.doc.xpath_node(%(//a[contains(@href, "/einstellungen/wiederkehrend/neu")])).should be_nil
    W.texts(r, %(//div[@class="activity-item"]//div[@class="activity-main"]/div[1])).first.should eq "Anna hat „Gleich 2“ gelöscht (10,00 €)."

    r = user.post("/ausgaben/2", W.expense(titel: "Wieder da", teil: all))
    r.status.should eq 409
    W.h1(r).should eq "Diese Ausgabe wurde gelöscht und kann nicht mehr bearbeitet werden."
    W.page_title(r).should eq "Diese Ausgabe wurde gelöscht und kann nicht mehr bearbeitet werden. · Zipfelkasse"
    r = user.post("/ausgaben/2/loeschen")
    {r.status, W.h1(r)}.should eq({404, "Ausgabe nicht gefunden oder schon gelöscht."})
    r.flash.should be_nil
    ["/ausgaben/999", "/ausgaben/abc", "/ausgaben/0", "/ausgaben/-1"].each do |p|
      r = user.get(p)
      {p, r.status, W.h1(r)}.should eq({p, 404, "Ausgabe nicht gefunden."})
      W.page_title(r).should eq "Ausgabe nicht gefunden. · Zipfelkasse"
      r.headers["Cache-Control"].should eq "no-store"
      W.attr(r, %(//main//a[@class="btn btn-outline"]), "href").should eq "/"
      W.text_of(r, %(//main//a[@class="btn btn-outline"])).should eq "Zur Startseite"
      W.whoami(r).should eq "Anna"
      W.current_tab(r).should be_nil
    end
    {user.post("/ausgaben/999", W.expense(teil: all)), user.post("/ausgaben/999/loeschen"), user.post("/ausgaben/x/loeschen")}.each do |res|
      {res.status, W.h1(res)}.should eq({404, "Ausgabe nicht gefunden."})
    end
    W.count(world, "SELECT count(*) FROM expenses WHERE deleted_at IS NOT NULL").should eq 1
  end

  scenario "foreign currencies with ECB and manual rates", world do
    user = world.user
    user.login("Anna")
    usd = world.ecb.rate("USD", Time.utc(2026, 10, 1)).to_f
    jpy = world.ecb.rate("JPY", Time.utc(2026, 9, 25)).to_f # Saturday 26th: Friday's rate
    gbp = world.ecb.rate("GBP", Time.utc(2026, 10, 1)).to_f

    # No rate in the form: the ECB rate of the day.
    r = user.post("/ausgaben/neu", W.expense(titel: "Diner", waehrung: "USD", betrag: "10,00", teil: all))
    {r.status, r.flash}.should eq({303, "Ausgabe „Diner“ angelegt."})
    id = W.newest_expense(world)
    row = E2E::Snapshot.open(world.app.db_path) do |db|
      db.query_one("SELECT original_currency, original_amount_minor, fx_rate, fx_source, amount_cents FROM expenses WHERE id = ?", id,
        as: {String, Int64, Float64, String, Int64})
    end
    row.should eq({"USD", 1000, usd, "ezb", eur_cents(1000, 2, usd)})
    r = user.get("/ausgaben/#{id}")
    W.selected(r, "waehrung").should eq "USD"
    W.input(r, "betrag").should eq "10,00"
    W.input(r, "kurs").should eq rate_input(usd)
    W.input(r, "kurs_quelle").should eq "ezb"
    W.text_of(r, %(//p[@id="kurs-hinweis"])).should eq "EZB-Kurs."
    W.text_of(r, %(//span[@id="betrag-einheit"])).should eq "USD"
    W.text_of(r, %(//span[@id="kurs-einheit"])).should eq "USD"
    W.attr(r, %(//div[@id="split-rows"]), "data-currency").should eq "USD"
    cents = eur_cents(1000, 2, usd)
    W.text_of(r, %(//strong[@id="eur-vorschau"])).should eq "#{cents // 100},#{(cents % 100).to_s.rjust(2, '0')} €"

    # A rate entered by hand; an "other" currency.
    r = user.post("/ausgaben/neu", W.expense(titel: "Tuk-Tuk", waehrung: "", waehrung_andere: " thb ", betrag: "100", kurs: "40", teil: all))
    r.status.should eq 303
    id = W.newest_expense(world)
    r = user.get("/ausgaben/#{id}")
    W.selected(r, "waehrung").should eq ""
    W.input(r, "waehrung_andere").should eq "THB"
    W.input(r, "kurs").should eq "40"
    W.input(r, "kurs_quelle").should eq "manuell"
    W.text_of(r, %(//p[@id="kurs-hinweis"])).should eq "Von Hand eingetragener Kurs."
    W.text_of(r, %(//strong[@id="eur-vorschau"])).should eq "2,50 €"
    W.count(world, "SELECT amount_cents FROM expenses WHERE id = #{id}").should eq 250

    # Currencies without decimals; a weekend date takes Friday's rate.
    r = user.post("/ausgaben/neu", W.expense(titel: "Ramen", waehrung: "JPY", betrag: "4.850", datum: "2026-09-26", teil: all))
    r.status.should eq 303
    id = W.newest_expense(world)
    W.count(world, "SELECT amount_cents FROM expenses WHERE id = #{id}").should eq eur_cents(4850, 0, jpy)
    W.input(user.get("/ausgaben/#{id}"), "betrag").should eq "4850"

    # Thousands separators in amount and rate.
    user.post("/ausgaben/neu", W.expense(titel: "Surfkurs", waehrung: "", waehrung_andere: "IDR", betrag: "1.250.000", kurs: "17.000", teil: all)).status.should eq 303
    surf = W.newest_expense(world)
    W.count(world, "SELECT amount_cents FROM expenses WHERE id = #{surf}").should eq 7353
    W.input(user.get("/ausgaben/#{surf}"), "kurs").should eq "17000"

    # A rate marked as ECB is checked against the ECB rate of that currency.
    r = user.post("/ausgaben/neu", W.expense(titel: "Pub", waehrung: "GBP", betrag: "17,00", kurs: "1,08", kurs_quelle: "ezb", teil: all))
    r.status.should eq 303
    id = W.newest_expense(world)
    W.input(user.get("/ausgaben/#{id}"), "kurs").should eq rate_input(gbp)
    W.count(world, "SELECT count(*) FROM expenses WHERE id = #{id} AND fx_source = 'ezb' AND fx_rate = #{gbp}").should eq 1
    # … and without a source it counts as manual.
    user.post("/ausgaben/neu", W.expense(titel: "Pub 2", waehrung: "GBP", betrag: "17,00", kurs: "1,08", teil: all)).status.should eq 303
    W.count(world, "SELECT count(*) FROM expenses WHERE title = 'Pub 2' AND fx_source = 'manuell' AND fx_rate = 1.08").should eq 1
    # No ECB rate: message, and the stale rate is not offered again.
    r = user.post("/ausgaben/#{id}", W.expense(titel: "Pub", waehrung: "", waehrung_andere: "XAF", betrag: "17", kurs: "0,85", kurs_quelle: "ezb", teil: all))
    r.status.should eq 422
    r.error_message.should eq "Für XAF ist am 01.10.2026 kein Wechselkurs verfügbar. Kurs bitte von Hand eintragen."
    W.input(r, "kurs").should eq ""
    W.input(r, "kurs_quelle").should eq ""
    W.text_of(r, %(//p[@id="kurs-hinweis"])).should eq "Leer lassen für den EZB-Kurs."

    # Split by amounts in the foreign currency.
    form = W.expense(titel: "Mietwagen", waehrung: "USD", betrag: "10,00", kurs: "1,5", aufteilung: "amount",
      teil: [anna, ben], werte: {anna => "6,00", ben => "4"})
    user.post("/ausgaben/neu", form).status.should eq 303
    id = W.newest_expense(world)
    W.count(world, "SELECT amount_cents FROM expenses WHERE id = #{id}").should eq 667
    W.shares(world, id).should eq({anna => 400, ben => 267})
    r = user.get("/ausgaben/#{id}")
    split_rows(r).should eq [{"1", true, "6,00", "4,00 €"}, {"2", true, "4,00", "2,67 €"}, {"3", false, "", ""}]
    W.input(r, "kurs").should eq "1,5"
    W.texts(r, %(//span[@data-unit])).uniq.should eq ["USD"]
    r = user.post("/ausgaben/neu", change(form, {"wert_2" => "3"} of String => String | Array(String)))
    r.error_message.should eq "Die Beträge müssen zusammen 10,00 USD ergeben (aktuell 9,00 USD)."

    # The list shows the original amount below the euro amount.
    home = user.get("/")
    row_text = W.text_of(home, %(//a[@id="ausgabe-#{id}"]//span[@class="expense-side"])).not_nil!
    row_text.should eq "6,67 € 10,00 USD 01.10.2026"
    W.text_of(home, %(//a[@id="ausgabe-#{surf}"]//span[@class="expense-side"])).should eq "73,53 € 1.250.000 IDR 01.10.2026"
  end
end

# The rows of the home page: {id, title, payer line, balance line, side}.
private def home_rows(r : E2E::Response) : Array({String, String, String, String, String})
  r.doc.xpath_nodes(%(//a[starts-with(@id, "ausgabe-")])).map do |a|
    metas = a.xpath_nodes(%(.//span[@class="expense-meta"])).map { |m| W.squish(m.content) }
    {
      a["id"].lchop("ausgabe-"),
      W.squish(a.xpath_node(%(.//span[@class="expense-title"])).not_nil!.content),
      metas[0], metas[1],
      W.squish(a.xpath_node(%(.//span[@class="expense-side"])).not_nil!.content),
    }
  end
end

private def row_ids(r : E2E::Response) : Array(String)
  r.doc.xpath_nodes(%(//a[starts-with(@id, "ausgabe-")])).map(&.["id"].lchop("ausgabe-"))
end

private def suggest(r : E2E::Response) : JSON::Any
  JSON.parse(W.attr(r, %(//select[@name="kategorie"]), "data-suggest").not_nil!)
end

# Tuesday, 20 October 2026: every period of the list can occur.
describe "Web: home page" do
  world = E2E::World.new("web-home", now: "2026-10-20T10:00:00Z")
  after_all { world.stop }

  scenario "an empty list", world do
    user = world.user
    user.post("/wer/neu", {"name" => "Anna"}).status.should eq 303
    %w(Ben Cleo Dora).each { |n| user.post("/einstellungen/teilnehmer", {"name" => n}).status.should eq 303 }
    r = user.get("/")
    r.status.should eq 200
    W.page_title(r).should eq "Ausgaben · Zipfelkasse"
    W.current_tab(r).should eq "/"
    W.text_of(r, %(//p[contains(@class, "my-balance-amount")])).should eq "0,00 €"
    W.attr(r, %(//p[contains(@class, "my-balance-amount")]), "class").not_nil!.split.should eq ["my-balance-amount"]
    r.text.should contain "Dein Saldo 0,00 € Alles ausgeglichen."
    W.text_of(r, %(//p[@class="empty"])).should eq "Noch keine Ausgaben. Erste Ausgabe anlegen"
    W.attr(r, %(//p[@class="empty"]/a), "href").should eq "/ausgaben/neu"
    W.attr(r, %(//a[@class="fab"]), "aria-label").should eq "Ausgabe hinzufügen"
    W.texts(r, %(//select[@name="kategorie"]/option)).first(2).should eq ["Alle Kategorien", "Lebensmittel"]
    W.texts(r, %(//select[@name="person"]/option)).should eq ["Alle Personen", "Anna", "Ben", "Cleo", "Dora"]
    r.doc.xpath_node(%(//a[text()="Filter zurücksetzen"])).should be_nil
    r.doc.xpath_node(%(//a[@data-more])).should be_nil
    r.doc.xpath_node(%(//div[@data-more-list][@data-sync-url])).should_not be_nil
    r = user.get("/?q=nichts")
    W.text_of(r, %(//p[@class="empty"])).should eq "Keine Ausgaben gefunden. Filter zurücksetzen"
    W.input(r, "q").should eq "nichts"
    suggest(user.get("/ausgaben/neu")).should eq JSON.parse(%({"t":{},"w":{}}))
  end

  scenario "groups by period, rows and the own balance", world do
    user = world.user
    user.login("Anna")
    a, b, c, d = 1_i64, 2_i64, 3_i64, 4_i64
    [
      W.expense(titel: "Kino mit Freunden", datum: "2026-10-25", kategorie: "7", betrag: "40", bezahlt_von: a, teil: [a, b, c, d]),
      W.expense(titel: "Rewe Einkauf", datum: "2026-10-19", kategorie: "1", betrag: "12", bezahlt_von: b, teil: [b, c]),
      W.expense(titel: "Rewe Getränke", datum: "2026-10-05", kategorie: "1", betrag: "9", bezahlt_von: c, teil: [a, c]),
      W.expense(titel: "Pizza bei Luigi", datum: "2026-09-15", kategorie: "2", betrag: "30", bezahlt_von: a, teil: [a, b, c], notiz: "mit Extra-Käse"),
      W.expense(titel: "Bahn-Tickets", datum: "2026-03-01", kategorie: "5", betrag: "20", bezahlt_von: d, teil: [a, b, c, d]),
      W.expense(titel: "Rewe Einkauf", datum: "2025-06-01", kategorie: "3", betrag: "10", bezahlt_von: a, teil: [a]),
      W.expense(titel: "Altes Zeug", datum: "2024-01-01", betrag: "8", bezahlt_von: b, teil: [b, d]),
      W.expense(titel: "Bäckerei Ölmühle", datum: "20.10.2026", kategorie: "1", betrag: "5", bezahlt_von: a, teil: [a]),
    ].each { |f| user.post("/ausgaben/neu", f).status.should eq 303 }

    r = user.get("/")
    W.groups(r).should eq ["Bevorstehend", "Diese Woche", "Früher in diesem Monat", "Letzter Monat", "Früher in diesem Jahr", "Letztes Jahr", "Älter"]
    W.texts(r, %(//h2[@class="list-group-label"])).should eq W.groups(r)
    home_rows(r).should eq [
      {"1", "Kino mit Freunden", "Bezahlt von Anna für alle", "Dein Saldo: 30,00 €", "40,00 € 25.10.2026"},
      {"8", "Bäckerei Ölmühle", "Bezahlt von Anna für Anna", "Dein Saldo: 0,00 €", "5,00 € 20.10.2026"},
      {"2", "Rewe Einkauf", "Bezahlt von Ben für Ben, Cleo", "Du bist nicht beteiligt", "12,00 € 19.10.2026"},
      {"3", "Rewe Getränke", "Bezahlt von Cleo für Anna, Cleo", "Dein Saldo: -4,50 €", "9,00 € 05.10.2026"},
      {"4", "Pizza bei Luigi", "Bezahlt von Anna für Anna, Ben, Cleo", "Dein Saldo: 20,00 €", "30,00 € 15.09.2026"},
      {"5", "Bahn-Tickets", "Bezahlt von Dora für alle", "Dein Saldo: -5,00 €", "20,00 € 01.03.2026"},
      {"6", "Rewe Einkauf", "Bezahlt von Anna für Anna", "Dein Saldo: 0,00 €", "10,00 € 01.06.2025"},
      {"7", "Altes Zeug", "Bezahlt von Ben für Ben, Dora", "Du bist nicht beteiligt", "8,00 € 01.01.2024"},
    ]
    W.texts(r, %(//div[@data-group="Diese Woche"]//span[@class="expense-title"])).should eq ["Bäckerei Ölmühle", "Rewe Einkauf"]
    W.attr(r, %(//a[@id="ausgabe-1"]), "href").should eq "/ausgaben/1"
    W.attr(r, %(//a[@id="ausgabe-1"]), "class").should eq "expense"
    W.attr(r, %(//a[@id="ausgabe-3"]//span[@class="expense-meta"]/span[strong]), "class").should eq "negative"
    W.attr(r, %(//a[@id="ausgabe-4"]//span[@class="expense-meta"]/span[strong]), "class").should eq "positive"
    W.attr(r, %(//a[@id="ausgabe-6"]//span[@class="expense-meta"]/span[strong]), "class").should eq ""
    icons = {"1" => "ticket", "8" => "cart", "4" => "utensils", "5" => "car", "6" => "home", "7" => "tag"}
    icons.each do |id, icon|
      W.attr(r, %(//a[@id="ausgabe-#{id}"]//span[@class="expense-icon"]//use), "href").not_nil!.should end_with "##{icon}"
    end
    W.text_of(r, %(//p[contains(@class, "my-balance-amount")])).should eq "40,50 €"
    W.attr(r, %(//p[contains(@class, "my-balance-amount")]), "class").not_nil!.split.should eq ["my-balance-amount", "positive"]
    r.text.should contain "Du bekommst noch Geld."
    ben = world.user
    ben.login("Ben")
    r = ben.get("/")
    W.text_of(r, %(//p[contains(@class, "my-balance-amount")])).should eq "-15,00 €"
    r.text.should contain "Du schuldest noch Geld."
  end

  scenario "search and filters", world do
    user = world.user
    user.login("Anna")
    {
      "q=rewe"                                  => ["2", "3", "6"],
      "q=REWE+EINK"                             => ["2", "6"],
      "q=#{URI.encode_www_form("ÖLMÜHLE")}"     => ["8"],
      "q=#{URI.encode_www_form("  bäckerei ")}" => ["8"],
      "q=k%C3%A4se"                             => ["4"],
      "kategorie=1"                             => ["8", "2", "3"],
      "person=4"                                => ["1", "5", "7"],
      "person=4&q=bahn"                         => ["5"],
      "kategorie=1&person=3&q=rewe"             => ["2", "3"],
      "kategorie=abc&person=&q="                => ["1", "8", "2", "3", "4", "5", "6", "7"],
      "q=gibtsnicht"                            => [] of String,
    }.each do |query, ids|
      r = user.get("/?#{query}")
      {query, r.status, row_ids(r)}.should eq({query, 200, ids})
    end
    r = user.get("/?kategorie=1&person=3&q=+rewe+")
    W.input(r, "q").should eq "rewe"
    W.selected(r, "kategorie").should eq "1"
    W.selected(r, "person").should eq "3"
    W.attr(r, %(//a[text()="Filter zurücksetzen"]), "href").should eq "/"
    r = user.get("/?q=gibtsnicht")
    W.text_of(r, %(//p[@class="empty"])).should eq "Keine Ausgaben gefunden. Filter zurücksetzen"
    r = user.get("/?kategorie=abc")
    W.selected(r, "kategorie").should be_nil
    r.doc.xpath_node(%(//a[text()="Filter zurücksetzen"])).should be_nil

    # An archived category stays selectable while it is the filter.
    user.post("/einstellungen/kategorien/2/archivieren").status.should eq 303
    W.texts(user.get("/"), %(//select[@name="kategorie"]/option)).should_not contain "Restaurant"
    r = user.get("/?kategorie=2")
    row_ids(r).should eq ["4"]
    W.selected(r, "kategorie").should eq "2"
    W.text_of(r, %(//select[@name="kategorie"]/option[@selected])).should eq "Restaurant"
    user.post("/einstellungen/kategorien/2/reaktivieren").status.should eq 303
  end

  scenario "category suggestions for the expense form", world do
    user = world.user
    user.login("Anna")
    expected = JSON.parse(%({
      "t": {"bahn tickets": 5, "bäckerei ölmühle": 1, "kino mit freunden": 7, "pizza bei luigi": 2, "rewe einkauf": 1, "rewe getränke": 1},
      "w": {"bahn": [5, 1], "bäckerei": [1, 1], "freunden": [7, 1], "getränke": [1, 1], "kino": [7, 1], "luigi": [2, 1],
            "ölmühle": [1, 1], "pizza": [2, 1], "rewe": [1, 2], "tickets": [5, 1]}
    }))
    suggest(user.get("/ausgaben/neu")).should eq expected
    suggest(user.get("/ausgaben/3")).should eq expected
    # Archived categories, deleted expenses and reimbursements do not count.
    user.post("/einstellungen/kategorien/2/archivieren").status.should eq 303
    user.post("/ausgaben/5/loeschen").status.should eq 303
    user.post("/ausgaben/neu", W.expense(titel: "Rewe Rückzahlung", datum: "2026-10-20", kategorie: "3", betrag: "1",
      bezahlt_von: 2, teil: [1_i64], rueckzahlung: true)).status.should eq 303
    s = suggest(user.get("/ausgaben/neu"))
    s["t"].as_h.keys.sort!.should eq ["bäckerei ölmühle", "kino mit freunden", "rewe einkauf", "rewe getränke"]
    s["w"]["rewe"].should eq JSON.parse("[1, 2]")
    s["w"]["pizza"]?.should be_nil
    user.post("/einstellungen/kategorien/2/reaktivieren").status.should eq 303
    # A reimbursement shows as such in the list.
    r = user.get("/")
    W.attr(r, %(//a[@id="ausgabe-9"]), "class").should eq "expense reimbursement"
    home_rows(r).find { |row| row[0] == "9" }.should eq({"9", "Rewe Rückzahlung", "Ben an Anna", "Dein Saldo: -1,00 €", "1,00 € 20.10.2026"})
    W.attr(r, %(//a[@id="ausgabe-9"]//span[@class="expense-icon"]//use), "href").not_nil!.should end_with "#banknote"
  end

  scenario "paging with Weitere anzeigen", world do
    user = world.user
    user.login("Anna")
    101.times do |i|
      user.post("/ausgaben/neu", W.expense(titel: "Posten #{i + 1}", datum: "2026-01-10", betrag: "1", teil: [1_i64])).status.should eq 303
    end
    total = 109 # 9 earlier ones (one of them deleted) and a reimbursement
    r = user.get("/")
    row_ids(r).size.should eq 100
    more = r.doc.xpath_node(%(//a[@data-more])).not_nil!
    more["href"].should eq "/?anzahl=200"
    W.squish(more.content).should eq "Weitere anzeigen"
    W.groups(r).should eq ["Bevorstehend", "Diese Woche", "Früher in diesem Monat", "Letzter Monat", "Früher in diesem Jahr"]
    r = user.get("/?anzahl=200")
    row_ids(r).size.should eq total
    r.doc.xpath_node(%(//a[@data-more])).should be_nil
    W.groups(r).last(2).should eq ["Letztes Jahr", "Älter"]
    row_ids(user.get("/?anzahl=50")).size.should eq 100
    row_ids(user.get("/?anzahl=abc")).size.should eq 100
    row_ids(user.get("/?anzahl=101")).size.should eq 101
    W.attr(user.get("/?anzahl=101"), %(//a[@data-more]), "href").should eq "/?anzahl=201"
    r = user.get("/?q=posten")
    row_ids(r).first.should eq "110"
    W.attr(r, %(//a[@data-more]), "href").should eq "/?anzahl=200&q=posten"
    r = user.get("/?person=1&q=posten&kategorie=")
    W.attr(r, %(//a[@data-more]), "href").should eq "/?anzahl=200&person=1&q=posten"
    row_ids(user.get("/?anzahl=200&person=1&q=posten")).size.should eq 101
    r = user.get("/?q=posten+1")
    row_ids(r).size.should eq 13
    r.doc.xpath_node(%(//a[@data-more])).should be_nil
  end
end

# Rows of the balances page: {name, amount, bar width or nil, row classes}.
private def balance_rows(r : E2E::Response) : Array({String, String, String?, Array(String)})
  r.doc.xpath_nodes(%(//div[contains(@class, "balance-row")])).map do |row|
    {
      W.squish(row.xpath_node(%(.//div[@class="balance-name"])).not_nil!.content),
      W.squish(row.xpath_node(%(.//div[contains(@class, "balance-value")])).not_nil!.content),
      row.xpath_node(%(.//div[@class="balance-bar"])).try(&.["style"]),
      row["class"].split,
    }
  end
end

# Settlement suggestions: {text, link}.
private def transfers(r : E2E::Response) : Array({String, String})
  r.doc.xpath_nodes(%(//div[@class="transfer"])).map do |t|
    {W.squish(t.content), t.xpath_node(".//a").not_nil!["href"]}
  end
end

describe "Web: balances" do
  world = E2E::World.new("web-balances")
  after_all { world.stop }

  scenario "balances, bars and settlement suggestions", world do
    user = world.user
    user.post("/wer/neu", {"name" => "Anna"}).status.should eq 303
    %w(Ben Cleo Dora Emil).each { |n| user.post("/einstellungen/teilnehmer", {"name" => n}).status.should eq 303 }
    r = user.get("/salden")
    r.status.should eq 200
    W.page_title(r).should eq "Salden · Zipfelkasse"
    W.current_tab(r).should eq "/salden"
    balance_rows(r).should eq [
      {"Anna", "0,00 €", nil, ["balance-row", "me"]}, {"Ben", "0,00 €", nil, ["balance-row"]},
      {"Cleo", "0,00 €", nil, ["balance-row"]}, {"Dora", "0,00 €", nil, ["balance-row"]}, {"Emil", "0,00 €", nil, ["balance-row"]},
    ]
    transfers(r).should be_empty
    r.text.should contain "Alles ausgeglichen – niemand muss etwas zurückzahlen."

    # Emil leaves without a balance and disappears from the list; an expense
    # for him (archived people can still be ticked) brings him back.
    user.post("/einstellungen/teilnehmer/5/archivieren").status.should eq 303
    balance_rows(user.get("/salden")).map(&.[0]).should eq ["Anna", "Ben", "Cleo", "Dora"]
    user.post("/ausgaben/neu", W.expense(titel: "Essen", betrag: "30", bezahlt_von: 1, teil: [1_i64, 2_i64, 3_i64])).status.should eq 303
    user.post("/ausgaben/neu", W.expense(titel: "Kaugummi", betrag: "0,01", bezahlt_von: 4, teil: [3_i64])).status.should eq 303
    user.post("/ausgaben/neu", W.expense(titel: "Für Emil", betrag: "2", bezahlt_von: 1, teil: [5_i64])).status.should eq 303

    r = user.get("/salden")
    balance_rows(r).should eq [
      {"Anna", "22,00 €", "width: 100%", ["balance-row", "me"]},
      {"Ben", "-10,00 €", "width: 45%", ["balance-row", "negative-row"]},
      {"Cleo", "-10,01 €", "width: 46%", ["balance-row", "negative-row"]},
      {"Dora", "0,01 €", "width: 1%", ["balance-row"]},
      {"Emil (archiviert)", "-2,00 €", "width: 9%", ["balance-row", "negative-row"]},
    ]
    transfers(r).should eq [
      {"Cleo schuldet Anna Als erstattet markieren 10,01 €", "/ausgaben/neu?an=1&betrag=1001&rueckzahlung=1&von=3"},
      {"Ben schuldet Anna Als erstattet markieren 10,00 €", "/ausgaben/neu?an=1&betrag=1000&rueckzahlung=1&von=2"},
      {"Emil schuldet Anna Als erstattet markieren 1,99 €", "/ausgaben/neu?an=1&betrag=199&rueckzahlung=1&von=5"},
      {"Emil schuldet Dora Als erstattet markieren 0,01 €", "/ausgaben/neu?an=4&betrag=1&rueckzahlung=1&von=5"},
    ]
    # Another person sees the same balances, marked as themselves.
    ben = world.user
    ben.login("Ben")
    balance_rows(ben.get("/salden")).map(&.[3]).should eq [
      ["balance-row"], ["balance-row", "negative-row", "me"], ["balance-row", "negative-row"], ["balance-row"], ["balance-row", "negative-row"],
    ]
  end

  scenario "marking a suggestion as reimbursed", world do
    user = world.user
    user.login("Anna")
    r = user.get("/ausgaben/neu?an=1&betrag=1001&rueckzahlung=1&von=3")
    r.status.should eq 200
    W.h1(r).should eq "Ausgabe hinzufügen"
    r.doc.xpath_node(%(//input[@name="rueckzahlung"][@checked])).should_not be_nil
    W.input(r, "titel").should eq "Rückzahlung"
    W.input(r, "betrag").should eq "10,01"
    W.selected(r, "bezahlt_von").should eq "3"
    W.checked(r).should eq ["1"]
    split_rows(r).map(&.[0]).should eq ["1", "2", "3", "4"]

    # An archived payer is offered for his own reimbursement.
    r = user.get("/ausgaben/neu?an=1&betrag=199&rueckzahlung=1&von=5")
    W.selected(r, "bezahlt_von").should eq "5"
    W.text_of(r, %(//select[@name="bezahlt_von"]/option[@selected])).should eq "Emil (archiviert)"
    split_rows(r).map(&.[0]).should eq ["1", "2", "3", "4", "5"]
    W.text_of(r, %(//div[@data-id="5"]//label[@class="check"]/span[1])).should eq "Emil (archiviert)"
    W.checked(r).should eq ["1"]
    # Nonsense parameters give an empty reimbursement.
    r = user.get("/ausgaben/neu?rueckzahlung=1&von=x&an=&betrag=-3")
    W.selected(r, "bezahlt_von").should eq "1"
    W.input(r, "betrag").should eq ""
    W.checked(r).should be_empty

    form = W.expense(titel: "Rückzahlung", datum: "2026-10-02", betrag: "10,01", bezahlt_von: 3, rueckzahlung: true,
      aufteilung: "shares", teil: [1_i64], werte: {1_i64 => "7"})
    r = user.post("/ausgaben/neu", form)
    {r.status, r.location, r.flash}.should eq({303, "/", "Rückzahlung „Rückzahlung“ angelegt."})
    id = W.newest_expense(world)
    W.count(world, "SELECT count(*) FROM expenses WHERE id = #{id} AND is_reimbursement = 1 AND split_mode = 'equal' AND paid_by = 3").should eq 1
    W.shares(world, id).should eq({1_i64 => 1001_i64})
    r = user.get("/")
    W.attr(r, %(//a[@id="ausgabe-#{id}"]), "class").should eq "expense reimbursement"
    home_rows(r).first.should eq({id.to_s, "Rückzahlung", "Cleo an Anna", "Dein Saldo: -10,01 €", "10,01 € 02.10.2026"})
    r = user.get("/ausgaben/#{id}")
    r.doc.xpath_node(%(//input[@name="rueckzahlung"][@checked])).should_not be_nil
    W.selected(r, "aufteilung").should eq "equal"

    r = user.get("/salden")
    balance_rows(r)[2].should eq({"Cleo", "0,00 €", nil, ["balance-row"]})
    transfers(r).map(&.[0]).should eq [
      "Ben schuldet Anna Als erstattet markieren 10,00 €",
      "Emil schuldet Anna Als erstattet markieren 1,99 €",
      "Emil schuldet Dora Als erstattet markieren 0,01 €",
    ]
  end
end

describe "Web: settings" do
  world = E2E::World.new("web-settings")
  after_all { world.stop }

  scenario "the group name", world do
    user = world.user
    user.post("/wer/neu", {"name" => "Anna"}).status.should eq 303
    %w(Ben Cleo).each { |n| user.post("/einstellungen/teilnehmer", {"name" => n}).status.should eq 303 }
    r = user.get("/einstellungen")
    r.status.should eq 200
    W.page_title(r).should eq "Einstellungen · Zipfelkasse"
    W.current_tab(r).should eq "/einstellungen"
    W.input(r, "gruppenname").should eq "Zipfelkasse"
    r.doc.xpath_nodes(%(//ul[@class="link-list"]//a)).map { |a| {a["href"], W.squish(a.content)} }.should eq [
      {"/einstellungen/teilnehmer", "Teilnehmer"}, {"/einstellungen/kategorien", "Kategorien"},
      {"/einstellungen/wiederkehrend", "Wiederkehrende Ausgaben"}, {"/einstellungen/kurse", "Wechselkurse"},
      {"/einstellungen/ynab", "YNAB"}, {"/export", "Export"},
    ]

    r = user.post("/einstellungen", {"gruppenname" => "  WG   Süd "})
    {r.status, r.location, r.flash}.should eq({303, "/einstellungen", "Gespeichert."})
    r = user.get("/einstellungen")
    W.input(r, "gruppenname").should eq "WG Süd"
    W.shown_flash(r).should eq "Gespeichert."
    W.page_title(user.get("/salden")).should eq "Salden · WG Süd"
    W.attr(r, %(//meta[@name="apple-mobile-web-app-title"]), "content").should eq "WG Süd"
    W.text_of(r, %(//a[@class="brand"])).should eq "Zipfelkasse"
    manifest = user.get("/manifest.webmanifest").json
    {manifest["name"], manifest["short_name"]}.should eq({"WG Süd", "WG Süd"})

    r = user.post("/einstellungen", {"gruppenname" => "  "})
    {r.status, r.error_message}.should eq({422, "Bitte einen Namen für die Gruppe angeben."})
    W.input(r, "gruppenname").should eq "  "
    W.page_title(r).should eq "Einstellungen · WG Süd"
    r = user.post("/einstellungen", {"gruppenname" => "y" * 61})
    {r.status, r.error_message}.should eq({422, "Der Name ist zu lang (höchstens 60 Zeichen)."})
    W.input(r, "gruppenname").should eq "y" * 61
    # Saving the same name logs nothing.
    user.post("/einstellungen", {"gruppenname" => "WG Süd"}).status.should eq 303
    W.activity_texts(world).last.should eq "Gruppe umbenannt: „Zipfelkasse“ → „WG Süd“"
    W.activity_texts(world).count(&.starts_with?("Gruppe")).should eq 1
    user.get("/aktivitaet").text.should contain "Anna: Gruppe umbenannt: „Zipfelkasse“ → „WG Süd“"
  end

  scenario "participants", world do
    user = world.user
    user.login("Anna")
    r = user.get("/einstellungen/teilnehmer")
    r.status.should eq 200
    W.page_title(r).should eq "Teilnehmer · WG Süd"
    W.current_tab(r).should eq "/einstellungen"
    r.doc.xpath_nodes(%(//li[starts-with(@id, "person-")])).map { |li| {li["id"], li.xpath_node(".//input[@name='name']").not_nil!["value"]} }
      .should eq [{"person-1", "Anna"}, {"person-2", "Ben"}, {"person-3", "Cleo"}]
    W.text_of(r, %(//li[@id="person-1"]//p[@class="row-meta"])).should eq "0 Ausgaben · Saldo 0,00 € · das bist du"
    W.attr(r, %(//li[@id="person-2"]//button[@title="Archivieren"]), "data-confirm").should eq "Ben archivieren?"
    W.attr(r, %(//li[@id="person-2"]//form[1]), "action").should eq "/einstellungen/teilnehmer/2"
    r.doc.xpath_node(%(//h2[text()="Archiviert"])).should be_nil
    W.text_of(r, %(//main//a[@href="/einstellungen"])).should eq "← Zurück zu den Einstellungen"

    r = user.post("/einstellungen/teilnehmer", {"name" => "  Dora   D. "})
    {r.status, r.location, r.flash}.should eq({303, "/einstellungen/teilnehmer", "„Dora D.“ hinzugefügt."})
    r = user.post("/einstellungen/teilnehmer", {"name" => " dora d. "})
    {r.status, r.error_message}.should eq({422, "„dora d.“ gibt es schon."})
    W.input(r, "name").should eq "Anna"
    W.attr(r, %(//input[@id="neu-name"]), "value").should eq " dora d. "
    user.post("/einstellungen/teilnehmer", {"name" => ""}).error_message.should eq "Bitte einen Namen für die Person angeben."
    user.post("/einstellungen/teilnehmer", {"name" => "z" * 61}).error_message.should eq "Der Name ist zu lang (höchstens 60 Zeichen)."

    r = user.post("/einstellungen/teilnehmer/4", {"name" => " Dorothea "})
    {r.status, r.location, r.flash}.should eq({303, "/einstellungen/teilnehmer", "Gespeichert."})
    r = user.post("/einstellungen/teilnehmer/4", {"name" => "ben"})
    {r.status, r.error_message}.should eq({422, "„ben“ gibt es schon."})
    W.attr(r, %(//input[@id="neu-name"]), "value").should eq ""
    user.post("/einstellungen/teilnehmer/4", {"name" => " "}).error_message.should eq "Bitte einen Namen für die Person angeben."
    user.post("/einstellungen/teilnehmer/4", {"name" => "Dorothea"}).status.should eq 303 # unchanged: not logged
    ["999", "abc", "0"].each do |id|
      ["", "/archivieren", "/reaktivieren"].each do |action|
        r = user.post("/einstellungen/teilnehmer/#{id}#{action}", {"name" => "X"})
        {id, action, r.status, W.h1(r)}.should eq({id, action, 404, "Person nicht gefunden."})
      end
    end

    # Archiving needs a settled balance.
    user.post("/ausgaben/neu", W.expense(titel: "Essen", betrag: "30", bezahlt_von: 1, teil: [1_i64, 2_i64, 3_i64])).status.should eq 303
    r = user.post("/einstellungen/teilnehmer/2/archivieren")
    {r.status, r.error_message}.should eq({422, "Ben hat noch einen Saldo von -10,00 €. Bitte erst ausgleichen, dann archivieren."})
    W.page_title(r).should eq "Teilnehmer · WG Süd"
    r = user.get("/einstellungen/teilnehmer")
    W.text_of(r, %(//li[@id="person-1"]//p[@class="row-meta"])).should eq "1 Ausgabe · Saldo 20,00 € · das bist du"
    W.text_of(r, %(//li[@id="person-2"]//p[@class="row-meta"])).should eq "1 Ausgabe · Saldo -10,00 €"
    W.attr(r, %(//li[@id="person-2"]//span[contains(@class, "amount")]), "class").not_nil!.split.should eq ["amount", "negative"]
    W.text_of(r, %(//li[@id="person-4"]//p[@class="row-meta"])).should eq "0 Ausgaben · Saldo 0,00 €"

    r = user.post("/einstellungen/teilnehmer/4/archivieren")
    {r.status, r.location, r.flash}.should eq({303, "/einstellungen/teilnehmer", "„Dorothea“ archiviert."})
    r = user.get("/einstellungen/teilnehmer")
    r.doc.xpath_nodes(%(//li[starts-with(@id, "person-")]//input[@name="name"])).map(&.["value"]).should eq ["Anna", "Ben", "Cleo"]
    W.text_of(r, %(//h2[text()="Archiviert"])).should eq "Archiviert"
    W.text_of(r, %(//li[@id="person-4"])).should eq "Dorothea Zurückholen 0 Ausgaben"
    W.attr(r, %(//li[@id="person-4"]//form), "action").should eq "/einstellungen/teilnehmer/4/reaktivieren"
    # Archived people are no longer offered.
    W.texts(user.get("/wer"), %(//form[@action="/wer"]//button)).should eq ["Anna", "Ben", "Cleo"]
    new_page = user.get("/ausgaben/neu")
    split_rows(new_page).map(&.[0]).should eq ["1", "2", "3"]
    W.texts(new_page, %(//select[@name="bezahlt_von"]/option)).should eq ["Anna", "Ben", "Cleo"]
    W.texts(user.get("/"), %(//select[@name="person"]/option)).should eq ["Alle Personen", "Anna", "Ben", "Cleo"]

    r = user.post("/einstellungen/teilnehmer/4/reaktivieren")
    {r.status, r.flash}.should eq({303, "„Dorothea“ reaktiviert."})
    user.post("/einstellungen/teilnehmer/2/reaktivieren").flash.should eq "„Ben“ reaktiviert."
    W.activity_texts(world).select(&.starts_with?("Person")).should eq [
      "Person „Anna“ hinzugefügt", "Person „Ben“ hinzugefügt", "Person „Cleo“ hinzugefügt", "Person „Dora D.“ hinzugefügt",
      "Person „Dora D.“ umbenannt in „Dorothea“", "Person „Dorothea“ archiviert", "Person „Dorothea“ reaktiviert",
      "Person „Ben“ reaktiviert",
    ]
  end

  scenario "categories", world do
    user = world.user
    user.login("Anna")
    names = ->(r : E2E::Response) { r.doc.xpath_nodes(%(//li[starts-with(@id, "kategorie-")]//input[@name="name"])).map(&.["value"]) }
    r = user.get("/einstellungen/kategorien")
    r.status.should eq 200
    W.page_title(r).should eq "Kategorien · WG Süd"
    defaults = ["Lebensmittel", "Restaurant", "Haushalt", "Miete & Nebenkosten", "Transport", "Reisen", "Freizeit", "Gesundheit", "Geschenke", "Sonstiges"]
    names.call(r).should eq defaults
    r.doc.xpath_nodes(%(//li[starts-with(@id, "kategorie-")])).map(&.["id"]).should eq (1..10).map { |i| "kategorie-#{i}" }
    icons = r.doc.xpath_nodes(%(//li[starts-with(@id, "kategorie-")]/span[@class="muted"]//use)).map(&.["href"].split('#').last)
    icons.should eq ["cart", "utensils", "home", "key", "car", "plane", "ticket", "heart", "gift", "receipt"]
    W.text_of(r, %(//li[@id="kategorie-1"]//p[@class="row-meta"])).should eq "0 Ausgaben"
    r.doc.xpath_node(%(//li[@id="kategorie-1"]//button[@title="Nach oben"][@disabled])).should_not be_nil
    r.doc.xpath_node(%(//li[@id="kategorie-1"]//button[@title="Nach unten"][@disabled])).should be_nil
    r.doc.xpath_node(%(//li[@id="kategorie-10"]//button[@title="Nach unten"][@disabled])).should_not be_nil

    r = user.post("/einstellungen/kategorien", {"name" => " Haus  tiere "})
    {r.status, r.location, r.flash}.should eq({303, "/einstellungen/kategorien", "Kategorie „Haus tiere“ hinzugefügt."})
    names.call(user.get("/einstellungen/kategorien")).last(3).should eq ["Geschenke", "Haus tiere", "Sonstiges"]
    r = user.post("/einstellungen/kategorien", {"name" => "haus tiere"})
    {r.status, r.error_message}.should eq({422, "Die Kategorie „haus tiere“ gibt es schon."})
    W.attr(r, %(//input[@id="neu-name"]), "value").should eq "haus tiere"
    user.post("/einstellungen/kategorien", {"name" => " "}).error_message.should eq "Bitte einen Namen für die Kategorie angeben."
    r = user.post("/einstellungen/kategorien/1", {"name" => "Essen & Trinken"})
    {r.status, r.location, r.flash}.should eq({303, "/einstellungen/kategorien", "Gespeichert."})
    user.post("/einstellungen/kategorien/1", {"name" => "restaurant"}).error_message.should eq "Die Kategorie „restaurant“ gibt es schon."

    # Moving: back to the moved row, no flash.
    r = user.post("/einstellungen/kategorien/2/hoch")
    {r.status, r.location, r.flash}.should eq({303, "/einstellungen/kategorien#kategorie-2", nil})
    names.call(user.get("/einstellungen/kategorien")).first(3).should eq ["Restaurant", "Essen & Trinken", "Haushalt"]
    acts = W.count(world, "SELECT count(*) FROM activity")
    user.post("/einstellungen/kategorien/2/hoch").location.should eq "/einstellungen/kategorien#kategorie-2"
    W.count(world, "SELECT count(*) FROM activity").should eq acts
    user.post("/einstellungen/kategorien/2/runter").location.should eq "/einstellungen/kategorien#kategorie-2"
    user.post("/einstellungen/kategorien/2/runter").status.should eq 303
    names.call(user.get("/einstellungen/kategorien")).first(4).should eq ["Essen & Trinken", "Haushalt", "Restaurant", "Miete & Nebenkosten"]
    W.activity_texts(world).last(3).should eq [
      "Kategorie „Restaurant“ nach oben verschoben", "Kategorie „Restaurant“ nach unten verschoben", "Kategorie „Restaurant“ nach unten verschoben",
    ]

    # Archiving and bringing back.
    user.post("/ausgaben/neu", W.expense(titel: "Brot", betrag: "3", kategorie: "1", teil: [1_i64])).status.should eq 303
    W.text_of(user.get("/einstellungen/kategorien"), %(//li[@id="kategorie-1"]//p[@class="row-meta"])).should eq "1 Ausgabe"
    r = user.post("/einstellungen/kategorien/1/archivieren")
    {r.status, r.location, r.flash}.should eq({303, "/einstellungen/kategorien", "Kategorie „Essen & Trinken“ archiviert."})
    r = user.get("/einstellungen/kategorien")
    names.call(r).first.should eq "Haushalt"
    W.text_of(r, %(//li[@id="kategorie-1"])).should eq "Essen & Trinken Zurückholen 1 Ausgabe"
    W.texts(user.get("/ausgaben/neu"), %(//select[@name="kategorie"]/option)).should_not contain "Essen & Trinken"
    # An expense keeps its archived category.
    brot = W.newest_expense(world)
    r = user.get("/ausgaben/#{brot}")
    W.selected(r, "kategorie").should eq "1"
    W.text_of(r, %(//select[@name="kategorie"]/option[@selected])).should eq "Essen & Trinken (archiviert)"
    %w(hoch runter).each do |dir|
      r = user.post("/einstellungen/kategorien/1/#{dir}")
      {r.status, W.h1(r)}.should eq({404, "Kategorie nicht gefunden."})
    end
    r = user.post("/einstellungen/kategorien/1/reaktivieren")
    {r.status, r.flash}.should eq({303, "Kategorie „Essen & Trinken“ reaktiviert."})
    names.call(user.get("/einstellungen/kategorien")).first.should eq "Essen & Trinken"
    ["999", "abc"].each do |id|
      ["", "/archivieren", "/reaktivieren", "/hoch", "/runter"].each do |action|
        r = user.post("/einstellungen/kategorien/#{id}#{action}", {"name" => "X"})
        {id, action, r.status, W.h1(r)}.should eq({id, action, 404, "Kategorie nicht gefunden."})
      end
    end
    W.activity_texts(world).select(&.starts_with?("Kategorie „Essen")).should eq [
      "Kategorie „Essen & Trinken“ archiviert", "Kategorie „Essen & Trinken“ reaktiviert",
    ]
    W.activity_texts(world).should contain "Kategorie „Lebensmittel“ umbenannt in „Essen & Trinken“"
    W.activity_texts(world).should contain "Kategorie „Haus tiere“ hinzugefügt"
  end

  scenario "activity paging", world do
    user = world.user
    user.login("Anna")
    55.times { |i| user.post("/einstellungen", {"gruppenname" => "Runde #{i}"}).status.should eq 303 }
    ids = E2E::Snapshot.open(world.app.db_path) { |db| db.query_all("SELECT id FROM activity ORDER BY id DESC", as: Int64) }
    items = ->(r : E2E::Response) { r.doc.xpath_nodes(%(//*[contains(@class, "activity-item")])) }
    r = user.get("/aktivitaet")
    W.page_title(r).should eq "Aktivität · Runde 54"
    W.current_tab(r).should eq "/aktivitaet"
    W.h1(r).should eq "Aktivität"
    r.text.should contain "Wer hat wann was angelegt, geändert oder gelöscht."
    items.call(r).size.should eq 50
    W.squish(items.call(r).first.content).should eq "Anna: Gruppe umbenannt: „Runde 53“ → „Runde 54“ 03.10.2026, 12:00"
    items.call(r).first.name.should eq "div"
    W.groups(r).should eq ["Heute"]
    more = r.doc.xpath_node(%(//a[@data-more])).not_nil!
    W.squish(more.content).should eq "Ältere anzeigen"
    more["href"].should eq "/aktivitaet?vor=#{ids[49]}"
    r = user.get(more["href"])
    items.call(r).size.should eq Math.min(50, ids.size - 50)
    W.squish(items.call(r).first.content).should start_with "Anna: Gruppe umbenannt: „Runde 3“ → „Runde 4“"
    W.attr(r, %(//a[@data-more]), "href").should eq(ids.size > 100 ? "/aktivitaet?vor=#{ids[99]}" : nil)
    r = user.get("/aktivitaet?vor=#{ids.last}")
    items.call(r).should be_empty
    W.text_of(r, %(//div[@data-more-list]/p)).should eq "Noch keine Aktivität."
    items.call(user.get("/aktivitaet?vor=abc")).size.should eq 50
  end
end

# The activity page as {group, [{element, link, first line, time}]}.
private def activity_groups(r : E2E::Response) : Array({String, Array({String, String?, String, String})})
  r.doc.xpath_nodes(%(//div[@class="activity-group"])).map do |g|
    items = g.xpath_nodes(%(.//*[contains(@class, "activity-item")])).map do |i|
      {i.name, i["href"]?, W.squish(i.xpath_node(%(.//div[@class="activity-main"]/div[1])).not_nil!.content),
       i.xpath_node(".//time").not_nil!["datetime"]}
    end
    {g["data-group"], items}
  end
end

private def wait_for_expenses(world : E2E::World, n : Int32) : Nil
  E2E.wait_until("#{n} expenses", 15.seconds) do
    E2E::Snapshot.count(world.app.db_path, "SELECT count(*) FROM expenses") >= n
  end
end

# The clock moves from 2024 to October 2026, so that the activity log has
# entries in every period.
describe "Web: activity over time" do
  world = E2E::World.new("web-activity", now: "2024-05-01T10:00:00Z")
  after_all { world.stop }

  scenario "period labels of the activity log", world do
    user = world.user
    user.post("/wer/neu", {"name" => "Anna"}).status.should eq 303
    W.input(user.get("/ausgaben/neu"), "datum").should eq "2024-05-01"
    world.restart("2025-07-01T10:00:00Z")
    user.post("/einstellungen/teilnehmer", {"name" => "Ben"}).status.should eq 303
    world.restart("2026-03-02T10:00:00Z")
    user.post("/ausgaben/neu", W.expense(titel: "Einkauf", betrag: "12,34", datum: "2026-03-02", teil: [1_i64, 2_i64])).status.should eq 303
    world.restart("2026-09-10T10:00:00Z")
    user.post("/ausgaben/1", W.expense(titel: "Einkauf groß", betrag: "12,34", datum: "2026-03-02", teil: [1_i64, 2_i64])).status.should eq 303
    r = user.get("/ausgaben/1")
    W.text_of(r, "//div[@class='card-header']/p[@class='card-description']").should eq "Angelegt am 02.03.2026, 11:00 · geändert am 10.09.2026, 12:00"
    world.restart("2026-09-22T10:00:00Z")
    user.post("/ausgaben/neu", W.expense(titel: "Wocheneinkauf", betrag: "25", datum: "2026-09-22", teil: [1_i64, 2_i64])).status.should eq 303
    user.post("/einstellungen/wiederkehrend/neu", {"ausgabe" => "2", "haeufigkeit" => "weekly"}).status.should eq 303
    # The recurring job enters the next week's expense by itself.
    world.restart("2026-10-01T10:00:00Z")
    wait_for_expenses(world, 3)
    # 23:30 in Berlin is still the 2nd …
    world.restart("2026-10-02T21:30:00Z")
    user.post("/einstellungen", {"gruppenname" => "WG Gestern"}).status.should eq 303
    # … 00:30 is already the 3rd.
    world.restart("2026-10-02T22:30:00Z")
    W.input(user.get("/ausgaben/neu"), "datum").should eq "2026-10-03"
    user.post("/einstellungen", {"gruppenname" => "WG Heute"}).status.should eq 303
    world.restart(E2E::DEFAULT_NOW)
    user.post("/ausgaben/1/loeschen").status.should eq 303

    r = user.get("/aktivitaet")
    activity_groups(r).should eq [
      {"Heute", [
        {"a", "/ausgaben/1", "Anna hat „Einkauf groß“ gelöscht (12,34 €).", "2026-10-03T10:00:00Z"},
        {"div", nil, "Anna: Gruppe umbenannt: „WG Gestern“ → „WG Heute“", "2026-10-02T22:30:00Z"},
      ]},
      {"Gestern", [{"div", nil, "Anna: Gruppe umbenannt: „Zipfelkasse“ → „WG Gestern“", "2026-10-02T21:30:00Z"}]},
      {"Früher in dieser Woche", [{"a", "/ausgaben/3", "Automatisch hat „Wocheneinkauf“ angelegt (25,00 €).", "2026-10-01T10:00:00Z"}]},
      {"Letzte Woche", [
        {"a", "/ausgaben/2", "Anna: „Wocheneinkauf“ wiederholt sich jetzt wöchentlich.", "2026-09-22T10:00:00Z"},
        {"a", "/ausgaben/2", "Anna hat „Wocheneinkauf“ angelegt (25,00 €).", "2026-09-22T10:00:00Z"},
      ]},
      {"Letzter Monat", [{"a", "/ausgaben/1", "Anna hat „Einkauf groß“ geändert.", "2026-09-10T10:00:00Z"}]},
      {"Früher in diesem Jahr", [{"a", "/ausgaben/1", "Anna hat „Einkauf“ angelegt (12,34 €).", "2026-03-02T10:00:00Z"}]},
      {"Letztes Jahr", [{"div", nil, "Anna: Person „Ben“ hinzugefügt", "2025-07-01T10:00:00Z"}]},
      {"Älter", [{"div", nil, "Anna: Person „Anna“ hinzugefügt", "2024-05-01T10:00:00Z"}]},
    ]
    W.texts(r, "//time").should eq [
      "03.10.2026, 12:00", "03.10.2026, 00:30", "02.10.2026, 23:30", "01.10.2026, 12:00", "22.09.2026, 12:00",
      "22.09.2026, 12:00", "10.09.2026, 12:00", "02.03.2026, 11:00", "01.07.2025, 12:00", "01.05.2024, 12:00",
    ]
    W.texts(r, %(//ul[@class="changes"]/li)).should eq ["Titel: Einkauf → Einkauf groß"]
    W.texts(r, %(//span[@class="amount muted"])).should eq ["(12,34 €)", "(25,00 €)", "(25,00 €)", "(12,34 €)"]
    W.attr(r, %(//a[@class="activity-item"]//span[@class="expense-chevron"]//use), "href").not_nil!.should end_with "#chevron-right"

    # An automatic expense and its history.
    r = user.get("/ausgaben/3")
    W.input(r, "datum").should eq "2026-09-29"
    W.text_of(r, "//div[@class='card-header']/p[@class='card-description']").should eq "Angelegt am 01.10.2026, 12:00 · Wiederkehrend"
    W.attr(r, %(//p[@class="card-description"]/a[contains(@class, "badge")]), "href").should eq "/einstellungen/wiederkehrend"
    r.text.should contain "Diese Ausgabe wird automatisch wiederholt. Wiederkehrende Ausgaben verwalten"
    r.doc.xpath_node(%(//a[contains(@href, "/einstellungen/wiederkehrend/neu")])).should be_nil
    W.texts(r, %(//div[@class="activity-item"]//div[@class="activity-main"]/div[1])).should eq ["Automatisch hat „Wocheneinkauf“ angelegt (25,00 €)."]
    W.attr(user.get("/"), %(//a[@id="ausgabe-3"]//span[@title="Wiederkehrend"]), "class").should eq "badge badge-muted"
  end

  scenario "the same log seen later in the month", world do
    world.restart("2026-10-20T10:00:00Z")
    wait_for_expenses(world, 6)
    user = world.user
    user.login("Anna")
    r = user.get("/aktivitaet")
    groups = activity_groups(r)
    groups.map(&.[0]).should eq ["Heute", "Früher in diesem Monat", "Letzter Monat", "Früher in diesem Jahr", "Letztes Jahr", "Älter"]
    groups[0][1].map(&.[2]).uniq.should eq ["Automatisch hat „Wocheneinkauf“ angelegt (25,00 €)."]
    groups[1][1].map(&.[3]).should eq ["2026-10-03T10:00:00Z", "2026-10-02T22:30:00Z", "2026-10-02T21:30:00Z", "2026-10-01T10:00:00Z"]
    groups[2][1].size.should eq 3
    W.groups(user.get("/")).should eq ["Diese Woche", "Früher in diesem Monat", "Letzter Monat"]
  end
end

private def security_headers!(r : E2E::Response) : Nil
  W::SECURITY_HEADERS.each { |k, v| {r.path, k, r.headers[k]?}.should eq({r.path, k, v}) }
end

describe "Web: security, PWA, static files and CLI" do
  world = E2E::World.new("web-security")
  after_all { world.stop }
  cross_origin = "Diese Anfrage kam von einer fremden Seite und wurde abgelehnt. Bitte lade die Seite neu und versuche es noch einmal."
  too_large = "Die gesendeten Daten sind zu groß. Bitte kürze die Eingaben und versuche es noch einmal."

  scenario "requests from foreign sites are rejected", world do
    user = world.user
    user.post("/wer/neu", {"name" => "Anna"}).status.should eq 303
    body = W.form_body({"gruppenname" => "Gekapert"})
    post = ->(headers : Hash(String, String)) do
      W.raw(user, "POST", "/einstellungen", body) do |app|
        h = HTTP::Headers{"Content-Type" => W::FORM_CT}
        headers.each { |k, v| h[k] = v.gsub("SELF", app.base_url) }
        h
      end
    end
    [
      {"Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example"},
      {"Sec-Fetch-Site" => "same-site"},
      {"Sec-Fetch-Site" => "cross-site", "Origin" => "SELF"},
      {"Origin" => "https://evil.example"},
      {"Origin" => "http://127.0.0.1:1"},
    ].each do |headers|
      r = post.call(headers)
      {headers, r.status}.should eq({headers, 403})
      W.h1(r).should eq cross_origin
      W.page_title(r).should eq "#{cross_origin} · Zipfelkasse"
      r.headers["Cache-Control"].should eq "no-store"
      W.nav?(r).should be_false
      security_headers!(r)
    end
    W.count(world, "SELECT count(*) FROM settings WHERE value = 'Gekapert'").should eq 0
    # Same origin, or no browser headers at all (curl), passes.
    [
      {"Sec-Fetch-Site" => "same-origin", "Origin" => "https://evil.example"},
      {"Sec-Fetch-Site" => "none"},
      {"Origin" => "SELF"},
      {} of String => String,
    ].each do |headers|
      r = post.call(headers)
      {headers, r.status, r.location}.should eq({headers, 303, "/einstellungen"})
    end
    # Reading is always allowed.
    user.get("/salden", HTTP::Headers{"Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example"}).status.should eq 200
    # Checked before the identity: no redirect, nobody created.
    anon = world.user
    r = anon.post("/wer/neu", {"name" => "Mallory"}, HTTP::Headers{"Sec-Fetch-Site" => "cross-site"})
    {r.status, W.h1(r), r.cookies["wer"]?}.should eq({403, cross_origin, nil})
    W.count(world, "SELECT count(*) FROM participants").should eq 1
    # /api/ gets JSON.
    r = user.post("/api/kurs", {"waehrung" => "USD"}, HTTP::Headers{"Sec-Fetch-Site" => "cross-site"})
    r.status.should eq 403
    r.content_type.should start_with "application/json"
    r.json.should eq JSON.parse(%({"error":"Anfrage von einer fremden Seite abgelehnt."}))
    security_headers!(r)
  end

  scenario "request bodies over 1 MiB are rejected", world do
    user = world.user
    user.login("Anna")
    big = W.form_body({"name" => "a" * (1 << 20)})
    [false, true].each do |chunked|
      send = ->(path : String) { W.post_large(user, path, big, chunked) }
      r = send.call("/einstellungen/teilnehmer")
      {chunked, r.status}.should eq({chunked, 413})
      r.html?.should be_true
      W.h1(r).should eq too_large
      r.headers["Connection"]?.should eq "close"
      W.nav?(r).should be_false
      security_headers!(r)
      r = send.call("/api/kurs")
      {chunked, r.status}.should eq({chunked, 413})
      r.json.should eq JSON.parse(%({"error":"Die Anfrage ist zu groß."}))
      r.headers["Connection"]?.should eq "close"
    end
    # The size limit comes before the origin check.
    r = W.post_large(user, "/einstellungen/teilnehmer", big, extra: HTTP::Headers{"Sec-Fetch-Site" => "cross-site"})
    r.status.should eq 413
    # Exactly 1 MiB is fine (and then too long a name).
    exact = "name=" + "b" * ((1 << 20) - 5)
    exact.bytesize.should eq 1 << 20
    r = W.raw(user, "POST", "/einstellungen/teilnehmer", exact) { HTTP::Headers{"Content-Type" => W::FORM_CT} }
    {r.status, r.error_message}.should eq({422, "Der Name ist zu lang (höchstens 60 Zeichen)."})
    W.count(world, "SELECT count(*) FROM participants").should eq 1
  end

  scenario "flash messages are shown once by whatever page comes next", world do
    user = world.user
    user.login("Anna")
    r = user.post("/einstellungen/teilnehmer", {"name" => "Ben"})
    r.flash.should eq "„Ben“ hinzugefügt."
    W.cookie(r, "flash").not_nil!.value.should eq "4oCeQmVu4oCcIGhpbnp1Z2Vmw7xndC4" # base64url, no padding
    # A 422 page consumes it as well.
    r = user.post("/einstellungen/teilnehmer", {"name" => "ben"})
    r.status.should eq 422
    W.shown_flash(r).should eq "„Ben“ hinzugefügt."
    r.error_message.should eq "„ben“ gibt es schon."
    W.cookie(r, "flash").not_nil!.value.should eq ""
    W.cookie(r, "flash").not_nil!.max_age.should eq 0.seconds
    W.shown_flash(user.get("/einstellungen/teilnehmer")).should be_nil
    # A broken cookie shows nothing but is removed.
    W.set_cookie(user, "flash", "%%%")
    r = user.get("/salden")
    W.shown_flash(r).should be_nil
    W.cookie(r, "flash").not_nil!.value.should eq ""
    # Flash cookies are only read by pages: redirects keep them.
    user.post("/einstellungen", {"gruppenname" => "Zipfelkasse"}).flash.should eq "Gespeichert."
    W.shown_flash(user.get("/einstellungen")).should eq "Gespeichert."
  end

  scenario "headers, unknown paths and wrong methods", world do
    user = world.user
    user.login("Anna")
    anon = world.user
    [user.get("/"), user.get("/ausgaben/999"), anon.get("/wer"), anon.get("/salden"), anon.get("/healthz"),
     anon.get("/static/app.css"), anon.get("/manifest.webmanifest"), anon.get("/sw.js"), anon.get("/favicon.ico"),
     anon.get("/api/kurs"), user.get("/gibt-es-nicht"), user.post("/salden")].each { |r| security_headers!(r) }
    r = user.get("/")
    {r.content_type, r.headers["Cache-Control"]}.should eq({"text/html; charset=utf-8", "no-store"})

    ["/gibt-es-nicht", "/salden/", "/ausgaben/1/x", "/ausgaben/1/", "/einstellungen/gibts/nicht", "/static/fehlt.css"].each do |p|
      {p, user.get(p).status}.should eq({p, 404})
    end
    user.get("/static/fehlt.css").headers["Cache-Control"]?.should be_nil

    {
      {"POST", "/salden"}                          => "GET, HEAD",
      {"POST", "/healthz"}                         => "GET, HEAD",
      {"GET", "/ausgaben/1/loeschen"}              => "POST",
      {"GET", "/wer/neu"}                          => "POST",
      {"GET", "/einstellungen/teilnehmer/1"}       => "POST",
      {"PUT", "/wer"}                              => "GET, HEAD, POST",
      {"DELETE", "/einstellungen"}                 => "GET, HEAD, POST",
      {"PATCH", "/ausgaben/1"}                     => "GET, HEAD, POST",
      {"OPTIONS", "/aktivitaet"}                   => "GET, HEAD",
      {"POST", "/einstellungen/kategorien/1/hoch"} => nil,
    }.each do |(method, path), allow|
      r = W.raw(user, method, path, method == "GET" ? nil : "") { HTTP::Headers{"Content-Type" => W::FORM_CT} }
      if allow
        {method, path, r.status, r.headers["Allow"]?}.should eq({method, path, 405, allow})
      else
        r.status.should eq 303
      end
    end
  end

  scenario "HEAD requests", world do
    user = world.user
    user.login("Anna")
    r = user.head("/")
    {r.status, r.content_type, r.body}.should eq({200, "text/html; charset=utf-8", ""})
    r = user.head("/static/app.css")
    {r.status, r.content_type, r.headers["Cache-Control"], r.body}.should eq({200, "text/css; charset=utf-8", "public, max-age=300", ""})
    {"/healthz" => 200, "/manifest.webmanifest" => 200, "/sw.js" => 200, "/ausgaben/999" => 404, "/einstellungen" => 200}.each do |p, status|
      {p, user.head(p).status}.should eq({p, status})
    end
  end

  scenario "web app manifest, service worker and favicon", world do
    anon = world.user
    r = anon.get("/manifest.webmanifest")
    r.status.should eq 200
    r.content_type.should eq "application/manifest+json; charset=utf-8"
    r.headers["Cache-Control"].should eq "no-cache"
    m = r.json
    m.as_h.keys.sort.should eq %w(background_color description dir display icons id lang name scope short_name shortcuts start_url theme_color)
    {
      "name" => "Zipfelkasse", "short_name" => "Zipfelkasse", "description" => "Gemeinsame Ausgaben teilen", "lang" => "de",
      "dir" => "ltr", "id" => "/", "start_url" => "/", "scope" => "/", "display" => "standalone",
      "background_color" => "#ffffff", "theme_color" => "#047756",
    }.each { |k, v| {k, m[k].as_s}.should eq({k, v}) }
    m["shortcuts"].should eq JSON.parse(%([{"name":"Ausgabe hinzufügen","url":"/ausgaben/neu"},{"name":"Salden","url":"/salden"}]))
    icons = m["icons"].as_a
    icons.map { |i| {i["src"].as_s.split('?').first, i["sizes"].as_s, i["type"].as_s, i["purpose"].as_s} }.should eq [
      {"/static/icons/icon-192.png", "192x192", "image/png", "any"},
      {"/static/icons/icon-512.png", "512x512", "image/png", "any"},
      {"/static/icons/maskable-512.png", "512x512", "image/png", "maskable"},
    ]
    icons.each do |i|
      src = i["src"].as_s
      src.should match(/\?v=[0-9a-f]{10}$/)
      png = anon.get(src)
      {png.status, png.content_type, png.headers["Cache-Control"]}.should eq({200, "image/png", "public, max-age=31536000, immutable"})
      W.sha10(png.body).should eq src.split("?v=").last
    end

    r = anon.get("/sw.js")
    {r.status, r.content_type, r.headers["Cache-Control"]}.should eq({200, "text/javascript; charset=utf-8", "no-cache"})
    r.body.should eq anon.get("/static/sw.js").body
    r.body.should contain "addEventListener"
    r.body.should_not contain "caches."
    r = anon.get("/favicon.ico")
    {r.status, r.content_type, r.headers["Cache-Control"]}.should eq({200, "image/png", "public, max-age=86400"})
    r.body.should eq anon.get("/static/icons/favicon-32.png").body
  end

  scenario "static files and cache busting", world do
    user = world.user
    user.login("Anna")
    {
      "app.css" => "text/css; charset=utf-8", "app.js" => "text/javascript; charset=utf-8",
      "expense-form.js" => "text/javascript; charset=utf-8", "sw.js" => "text/javascript; charset=utf-8",
      "icons.svg" => "image/svg+xml", "mascot.webp" => "image/webp", "icons/apple-touch-icon.png" => "image/png",
      "icons/favicon-32.png" => "image/png", "icons/icon-192.png" => "image/png", "icons/icon-512.png" => "image/png",
      "icons/maskable-512.png" => "image/png",
    }.each do |file, type|
      r = user.get("/static/#{file}")
      {file, r.status, r.content_type, r.headers["Cache-Control"]}.should eq({file, 200, type, "public, max-age=300"})
      r.body.bytesize.should eq r.headers["Content-Length"].to_i
      r2 = user.get("/static/#{file}?v=egal")
      r2.headers["Cache-Control"].should eq "public, max-age=31536000, immutable"
      r2.body.should eq r.body
      user.get("/static/#{file}?v=").headers["Cache-Control"].should eq "public, max-age=300"
    end
    # Every asset a page references carries the hash of its content.
    page = user.get("/ausgaben/neu")
    refs = page.doc.xpath_nodes("//link[@href]|//script[@src]|//img[@src]|//use[@href]").map { |n| n["href"]? || n["src"] }
    statics = refs.select(&.starts_with?("/static/")).map(&.split('#').first).uniq!
    statics.map(&.split('?').first).sort.should eq [
      "/static/app.css", "/static/app.js", "/static/expense-form.js", "/static/icons.svg", "/static/icons/apple-touch-icon.png",
      "/static/icons/favicon-32.png", "/static/mascot.webp",
    ]
    statics.each do |ref|
      path, v = ref.split("?v=")
      W.sha10(user.get(path).body).should eq v
    end
    W.attr(page, %(//link[@rel="manifest"]), "href").should eq "/manifest.webmanifest"
    W.attr(page, "//html", "lang").should eq "de"
  end

  scenario "the CLI", world do
    app = world.app
    app.healthcheck.exit_code.should eq 0
    app.healthcheck(":#{app.port}").exit_code.should eq 0
    app.healthcheck("0.0.0.0:#{app.port}").exit_code.should eq 0
    app.healthcheck("127.0.0.1:#{E2E::App.free_port}").exit_code.should eq 1
    app.healthcheck("127.0.0.1:#{world.ecb.port}").exit_code.should eq 1 # answers 404
    err = IO::Memory.new
    st = Process.run(app.bin, ["healthcheck"], env: {"ZIPFELKASSE_ADDR" => "127.0.0.1:#{world.ecb.port}"}, error: err)
    {st.exit_code, err.to_s}.should eq({1, "zipfelkasse: healthz: status 404\n"})
    err = IO::Memory.new
    st = Process.run(app.bin, ["healthcheck"], env: {"ZIPFELKASSE_ADDR" => "broken"}, error: err)
    st.exit_code.should eq 1
    err.to_s.should start_with "zipfelkasse: "
    err = IO::Memory.new
    st = Process.run(app.bin, ["frobnicate"], error: err)
    {st.exit_code, err.to_s}.should eq({2, %(unknown command "frobnicate"\nusage: zipfelkasse [serve|healthcheck]\n)})
  end
end
