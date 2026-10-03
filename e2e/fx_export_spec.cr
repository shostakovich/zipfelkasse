require "./e2e_helper"
require "csv"

# Exchange rates (ECB download, /api/kurs, manual rates, the rates page,
# expenses in foreign currencies, the 16:30 schedule) and the exports (CSV,
# JSON, OFX and CSV for YNAB). The CSV and JSON files are compared by value,
# the OFX file by line.

# The JSON /api/kurs answers with (compact, trailing newline).
private def kurs_json(currency : String, date : String, rate : String, source : String) : String
  %({"currency":"#{currency}","date":"#{date}","rate":#{E2E::FxExport.shortest_float(rate)},"source":"#{source}"}\n)
end

private def error_json(msg : String) : String
  %({"error":"#{msg}"}\n)
end

# Thousands dot, decimal comma, " €".
private def eur(cents : Int64) : String
  euros = (cents.abs // 100).to_s.reverse.scan(/\d{1,3}/).map(&.[0]).join(".").reverse
  "#{cents < 0 ? "-" : ""}#{euros},#{(cents.abs % 100).to_s.rjust(2, '0')} €"
end

# The OFX file (CRLF after every line).
private def ofx_file(acct : String, from : String, to : String, server : String, transactions : Array(String), balance : String) : String
  head = ["OFXHEADER:100", "DATA:OFXSGML", "VERSION:102", "SECURITY:NONE", "ENCODING:UTF-8", "CHARSET:NONE",
          "COMPRESSION:NONE", "OLDFILEUID:NONE", "NEWFILEUID:NONE", "", "<OFX>", "<SIGNONMSGSRSV1>", "<SONRS>", "<STATUS>",
          "<CODE>0", "<SEVERITY>INFO", "</STATUS>", "<DTSERVER>#{server}", "<LANGUAGE>GER", "</SONRS>", "</SIGNONMSGSRSV1>",
          "<BANKMSGSRSV1>", "<STMTTRNRS>", "<TRNUID>1", "<STATUS>", "<CODE>0", "<SEVERITY>INFO", "</STATUS>", "<STMTRS>",
          "<CURDEF>EUR", "<BANKACCTFROM>", "<BANKID>ZIPFEL", "<ACCTID>#{acct}", "<ACCTTYPE>CHECKING", "</BANKACCTFROM>",
          "<BANKTRANLIST>", "<DTSTART>#{from}", "<DTEND>#{to}"]
  tail = ["</BANKTRANLIST>", "<LEDGERBAL>", "<BALAMT>#{balance}", "<DTASOF>#{to}", "</LEDGERBAL>", "</STMTRS>",
          "</STMTTRNRS>", "</BANKMSGSRSV1>", "</OFX>"]
  crlf(head + transactions + tail)
end

private def ofx_trn(date : String, amount : String, id : Int32, name : String, memo : String) : Array(String)
  ["<STMTTRN>", "<TRNTYPE>DEBIT", "<DTPOSTED>#{date}", "<TRNAMT>#{amount}", "<FITID>zipfelkasse-#{id}",
   "<NAME>#{name}", "<MEMO>#{memo}", "</STMTTRN>"]
end

private def ynab_memo(total : String, extra : String, payer : String, id : Int32) : String
  "Gesamt #{total} €#{extra} · bezahlt von #{payer} · zipfelkasse ##{id}"
end

private def crlf(lines : Array(String)) : String
  lines.join { |l| l + "\r\n" }
end

private def lf(lines : Array(String)) : String
  lines.join { |l| l + "\n" }
end

private def csv_rows(text : String, separator : Char) : Array(Array(String))
  CSV.parse(text.lchop('\u{FEFF}'), separator: separator)
end

# The helpers of E2E::FxExport, without putting them into the top level of
# the other specs.
module FxExportSpec
  extend E2E::FxExport

  describe "Exchange rates" do
    world = E2E::World.new("fx")
    after_all { world.stop }
    last = Time.utc(2026, 10, 2) # newest day the fake ECB publishes
    rate = ->(cur : String, d : String) { world.ecb.rate(cur, day(d)) }
    count = ->(file : String) { world.ecb.requests.count(file) }
    nf = "eurofxref-hist-90d.xml"
    zip = "eurofxref-hist.zip"
    currencies = E2E::FakeECB::BASE.keys.sort

    scenario "downloads the 90-day file at startup and shows the latest rates", world do
      world.app
      # On an empty cache the app loads the 90-day file, nothing else.
      count.call(nf).should eq 1
      count.call(zip).should eq 0
      days = (0...90).map { |i| last - i.days }.select { |d| E2E::FakeECB.business_day?(d) }
      E2E::Database.open(world.app.db_path) do |db|
        db.query_one("SELECT count(*), count(DISTINCT currency), min(date), max(date) FROM fx_rates WHERE source = 'ezb'",
          as: {Int64, Int64, String, String}).should eq({days.size * 16, 16, "2026-07-06", "2026-10-02"})
        db.scalar("SELECT count(*) FROM fx_rates WHERE source <> 'ezb'").should eq 0
        db.scalar("SELECT rate FROM fx_rates WHERE currency = 'JPY' AND date = '2026-09-25'").should eq rate.call("JPY", "2026-09-25").to_f
      end

      user = world.user
      user.login("Anna")
      page = user.get("/einstellungen/kurse")
      page.status.should eq 200
      page.doc.xpath_node("//title").not_nil!.content.should contain("Wechselkurse")
      page.text.should contain("Noch keine manuellen Kurse.")
      page.text.should contain("Zwischengespeichert: #{days.size * 16} Kurse für 16 Währungen vom 06.07.2026 bis 02.10.2026. " \
                               "Neue Kurse werden an Bankarbeitstagen nach 16:30 Uhr automatisch abgerufen.")
      table_rows(page, "EZB-Referenzkurse").should eq currencies.map { |c| [c, "02.10.2026", "#{german_rate(rate.call(c, "2026-10-02"))} #{c}"] }
      table_rows(page, "Manuelle Kurse").should be_empty
      page.text.should_not contain("Zuletzt verwendet")
      # The form for a manual rate starts with today's date.
      input_value(page, "kurs-datum").should eq "2026-10-03"
      input_value(page, "kurs-waehrung").should eq ""
      page.doc.xpath_nodes(%(//datalist[@id="kurs-waehrungen"]/option)).map(&.["value"]).should eq currencies
    end

    scenario "/api/kurs answers from the cache: EUR, weekends, formats, errors", world do
      user = world.user
      user.login("Anna")
      before = {count.call(nf), count.call(zip)}
      {
        "waehrung=EUR"                           => kurs_json("EUR", "2026-10-03", "1", "fest"),
        "waehrung=%20eur%20&datum=2027-01-01"    => kurs_json("EUR", "2027-01-01", "1", "fest"),
        "waehrung=EUR&datum=01.06.2024"          => kurs_json("EUR", "2024-06-01", "1", "fest"),
        "waehrung=USD"                           => kurs_json("USD", "2026-10-02", rate.call("USD", "2026-10-02"), "ezb"),
        "waehrung=USD&datum="                    => kurs_json("USD", "2026-10-02", rate.call("USD", "2026-10-02"), "ezb"),
        "waehrung=usd&datum=01.10.2026"          => kurs_json("USD", "2026-10-01", rate.call("USD", "2026-10-01"), "ezb"),
        "waehrung=JPY&datum=2026-09-27"          => kurs_json("JPY", "2026-09-25", rate.call("JPY", "2026-09-25"), "ezb"),
        "waehrung=GBP&datum=5.9.2026"            => kurs_json("GBP", "2026-09-04", rate.call("GBP", "2026-09-04"), "ezb"),
        "waehrung=IDR&datum=2026-07-06"          => kurs_json("IDR", "2026-07-06", rate.call("IDR", "2026-07-06"), "ezb"),
        "waehrung=THB&datum=2026-12-24"          => kurs_json("THB", "2026-10-02", rate.call("THB", "2026-10-02"), "ezb"),
        "waehrung=%20chf&datum=%202026-10-01%20" => kurs_json("CHF", "2026-10-01", rate.call("CHF", "2026-10-01"), "ezb"),
      }.each do |query, body|
        r = user.get("/api/kurs?#{query}")
        {query, r.status, r.body}.should eq({query, 200, body})
        r.content_type.should eq "application/json; charset=utf-8"
      end
      {
        ""                              => "Bitte eine Währung angeben.",
        "waehrung="                     => "Bitte eine Währung angeben.",
        "waehrung=%20%20"               => "Bitte eine Währung angeben.",
        "waehrung=US"                   => "Ungültige Währung „US“.",
        "waehrung=us1"                  => "Ungültige Währung „us1“.",
        "waehrung=%20EURO"              => "Ungültige Währung „ EURO“.",
        "waehrung=US&datum=gestern"     => "Ungültige Währung „US“.",
        "waehrung=USD&datum=gestern"    => "Ungültiges Datum „gestern“.",
        "waehrung=EUR&datum=31.02.2026" => "Ungültiges Datum „31.02.2026“.",
        "waehrung=USD&datum=1999-12-31" => "Das Datum „1999-12-31“ liegt nicht zwischen 2000 und 2100.",
        "waehrung=USD&datum=%20"        => "Bitte ein Datum angeben.",
      }.each do |query, msg|
        r = user.get("/api/kurs?#{query}".rchop('?'))
        {query, r.status, r.body}.should eq({query, 400, error_json(msg)})
        r.content_type.should eq "application/json; charset=utf-8"
      end
      # HTML characters are escaped by the JSON encoder; the text is the same.
      r = user.get("/api/kurs?waehrung=%3Cb%3E")
      r.status.should eq 400
      r.json["error"].should eq "Ungültige Währung „<b>“."
      # Everything came from the cache.
      {count.call(nf), count.call(zip)}.should eq before

      anonymous = world.user
      r = anonymous.get("/api/kurs?waehrung=USD")
      {r.status, r.body}.should eq({401, error_json("Bitte zuerst auswählen, wer du bist.")})
      r.content_type.should eq "application/json; charset=utf-8"
    end

    scenario "/api/kurs: unknown currencies", world do
      user = world.user
      user.login("Anna")
      # A recent date: the 90-day file was just loaded (cooldown), so the app
      # knows without a download that the ECB does not publish XAF.
      3.times do
        r = user.get("/api/kurs?waehrung=XAF&datum=2026-09-15")
        {r.status, r.body}.should eq({422, error_json("Für XAF gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.")})
      end
      r = user.get("/api/kurs?waehrung=xyz")
      {r.status, r.body}.should eq({422, error_json("Für XYZ gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.")})
      count.call(nf).should eq 1
      count.call(zip).should eq 0
    end

    scenario "/api/kurs: old dates load the history file once", world do
      user = world.user
      user.login("Anna")
      r = user.get("/api/kurs?waehrung=USD&datum=2024-05-19") # Sunday
      {r.status, r.body}.should eq({200, kurs_json("USD", "2024-05-17", rate.call("USD", "2024-05-17"), "ezb")})
      count.call(zip).should eq 1
      E2E::Database.open(world.app.db_path) do |db|
        db.scalar("SELECT value FROM settings WHERE key = 'fx.ezb_hist_bis'").should eq "2026-10-02"
        db.scalar("SELECT min(date) FROM fx_rates WHERE source = 'ezb'").should eq "2023-12-01"
      end
      {
        # Easter Monday and Good Friday 2026 are no TARGET days.
        "waehrung=GBP&datum=2026-04-06" => kurs_json("GBP", "2026-04-02", rate.call("GBP", "2026-04-02"), "ezb"),
        "waehrung=CHF&datum=01.01.2025" => kurs_json("CHF", "2024-12-31", rate.call("CHF", "2024-12-31"), "ezb"),
        "waehrung=HUF&datum=2025-12-26" => kurs_json("HUF", "2025-12-24", rate.call("HUF", "2025-12-24"), "ezb"),
        "waehrung=IDR&datum=2024-01-02" => kurs_json("IDR", "2024-01-02", rate.call("IDR", "2024-01-02"), "ezb"),
      }.each do |query, body|
        r = user.get("/api/kurs?#{query}")
        {query, r.status, r.body}.should eq({query, 200, body})
      end
      # Before the first rate of the file: a gap, no new download.
      r = user.get("/api/kurs?waehrung=USD&datum=2023-11-15")
      {r.status, r.body}.should eq({422, error_json("Für USD gibt es um den 15.11.2023 keinen EZB-Kurs – bitte Kurs von Hand eintragen.")})
      r = user.get("/api/kurs?waehrung=XAF&datum=2024-03-01")
      {r.status, r.body}.should eq({422, error_json("Für XAF gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.")})
      count.call(zip).should eq 1
      count.call(nf).should eq 1
    end

    scenario "manual rates: saving, every validation message, deleting, precedence", world do
      user = world.user
      user.login("Anna")
      r = user.post("/einstellungen/kurse", {"waehrung" => " usd ", "datum" => "30.09.2026", "kurs" => " 1,2 "})
      {r.status, r.location, r.flash}.should eq({303, "/einstellungen/kurse", "Kurs für USD gespeichert."})
      page = user.get("/einstellungen/kurse")
      page.doc.xpath_node(%(//*[@role="status"])).not_nil!.content.strip.should eq "Kurs für USD gespeichert."
      table_rows(page, "Manuelle Kurse").should eq [["USD", "30.09.2026", "1,2 USD", "Löschen (USD ab 30.09.2026)"]]

      # The manual rate applies from its date on, also to future dates.
      usd = ->(d : String) { rate.call("USD", d) }
      {
        "datum=2026-09-30" => kurs_json("USD", "2026-09-30", "1.2", "manuell"),
        "datum=2026-10-01" => kurs_json("USD", "2026-09-30", "1.2", "manuell"),
        ""                 => kurs_json("USD", "2026-09-30", "1.2", "manuell"),
        "datum=2027-02-01" => kurs_json("USD", "2026-09-30", "1.2", "manuell"),
        "datum=2026-09-29" => kurs_json("USD", "2026-09-29", usd.call("2026-09-29"), "ezb"),
        "datum=2024-05-17" => kurs_json("USD", "2024-05-17", usd.call("2024-05-17"), "ezb"),
      }.each do |query, body|
        r = user.get("/api/kurs?waehrung=USD&#{query}")
        {query, r.status, r.body}.should eq({query, 200, body})
      end

      # A newer manual rate takes over from its date; the older one still
      # applies before it. Saving the same day again replaces the rate.
      user.post("/einstellungen/kurse", {"waehrung" => "USD", "datum" => "2026-10-01", "kurs" => "1,3"}).status.should eq 303
      user.post("/einstellungen/kurse", {"waehrung" => "USD", "datum" => "2026-10-01", "kurs" => "1,25"}).status.should eq 303
      user.get("/api/kurs?waehrung=USD&datum=2026-10-02").body.should eq kurs_json("USD", "2026-10-01", "1.25", "manuell")
      user.get("/api/kurs?waehrung=USD&datum=2026-09-30").body.should eq kurs_json("USD", "2026-09-30", "1.2", "manuell")
      # Currencies the ECB does not publish, without a time limit; the ways
      # of writing a rate.
      {
        {"kwd", "2024-06-01", "0,3312"}    => "0,3312",
        {"VND", "2026-09-01", "0.856"}     => "0,856",
        {"VND", "2026-09-02", "17.000"}    => "17000",
        {"VND", "2026-09-03", "17,000.5"}  => "17000,5",
        {"IDR", "2026-09-04", "20.274,71"} => "20274,71",
        {"THB", "2026-09-01", "39,5"}      => "39,5",
        {"XAF", "2026-01-01", "655 957"}   => "655957",
      }.each do |(cur, date, input), _|
        r = user.post("/einstellungen/kurse", {"waehrung" => cur, "datum" => date, "kurs" => input})
        {cur, date, r.status}.should eq({cur, date, 303})
      end
      user.get("/api/kurs?waehrung=KWD&datum=2026-10-03").body.should eq kurs_json("KWD", "2024-06-01", "0.3312", "manuell")
      r = user.get("/api/kurs?waehrung=KWD&datum=2024-05-31")
      {r.status, r.body}.should eq({422, error_json("Für KWD gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.")})
      user.get("/api/kurs?waehrung=VND&datum=2026-09-02").body.should eq kurs_json("VND", "2026-09-02", "17000", "manuell")
      # A manual IDR rate beats the ECB rate of the same day.
      user.get("/api/kurs?waehrung=IDR&datum=2026-09-04").body.should eq kurs_json("IDR", "2026-09-04", "20274.71", "manuell")
      user.get("/api/kurs?waehrung=IDR&datum=2026-09-03").body.should eq kurs_json("IDR", "2026-09-03", rate.call("IDR", "2026-09-03"), "ezb")

      page = user.get("/einstellungen/kurse")
      table_rows(page, "Manuelle Kurse").map(&.first(3)).should eq [
        ["IDR", "04.09.2026", "20274,71 IDR"],
        ["KWD", "01.06.2024", "0,3312 KWD"],
        ["THB", "01.09.2026", "39,5 THB"],
        ["USD", "01.10.2026", "1,25 USD"],
        ["USD", "30.09.2026", "1,2 USD"],
        ["VND", "03.09.2026", "17000,5 VND"],
        ["VND", "02.09.2026", "17000 VND"],
        ["VND", "01.09.2026", "0,856 VND"],
        ["XAF", "01.01.2026", "655957 XAF"],
      ]
      page.doc.xpath_nodes(%(//form[@action="/einstellungen/kurse/loeschen"])).first.xpath_nodes(".//input[@type='hidden']").map { |i| {i["name"], i["value"]} }
        .should eq [{"waehrung", "IDR"}, {"datum", "2026-09-04"}]
      page.doc.xpath_nodes(%(//datalist[@id="kurs-waehrungen"]/option)).map(&.["value"]).should eq (currencies + ["KWD", "VND", "XAF"]).sort

      manual_rows = -> { E2E::Database.count(world.app.db_path, "SELECT count(*) FROM fx_rates WHERE source = 'manuell'") }
      saved = manual_rows.call
      bad_rate = ->(s : String) { "Ungültiger Wechselkurs „#{s}“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €)." }
      [
        {"usd", "", "1", "Bitte ein Datum angeben."},
        {"usd", "   ", "1", "Bitte ein Datum angeben."},
        {"usd", "broken", "1", "Ungültiges Datum „broken“."},
        {"usd", "30.02.2026", "1", "Ungültiges Datum „30.02.2026“."},
        {"usd", "1999-12-31", "1", "Das Datum „1999-12-31“ liegt nicht zwischen 2000 und 2100."},
        {"usd", "01.01.2101", "1", "Das Datum „01.01.2101“ liegt nicht zwischen 2000 und 2100."},
        {"usd", "2026-10-01", "abc", bad_rate.call("abc")},
        {"usd", "2026-10-01", "", bad_rate.call("")},
        {"usd", "2026-10-01", "0", bad_rate.call("0")},
        {"usd", "2026-10-01", "0,000", bad_rate.call("0,000")},
        {"usd", "2026-10-01", "-1,5", bad_rate.call("-1,5")},
        {"usd", "2026-10-01", " 1 2x ", bad_rate.call("12x")},
        {"usd", "2026-10-01", "1,2,3", bad_rate.call("1,2,3")},
        {"usd", "2026-10-01", "1.0000000000000", bad_rate.call("1.0000000000000")},
        {"eur", "2026-10-01", "1", "Für Euro braucht es keinen Kurs."},
        {"US", "2026-10-01", "1", "Bitte einen dreistelligen Währungscode angeben (z. B. USD)."},
        {"", "2026-10-01", "1", "Bitte einen dreistelligen Währungscode angeben (z. B. USD)."},
        {"U5D", "2026-10-01", "1", "Bitte einen dreistelligen Währungscode angeben (z. B. USD)."},
        {"usd", "2026-10-01", "1.000.000.001", "Der Kurs muss größer als 0 sein."},
        # The date is checked first, then the rate, then the currency.
        {"US", "broken", "abc", "Ungültiges Datum „broken“."},
        {"eur", "2026-10-01", "abc", bad_rate.call("abc")},
      ].each do |cur, date, input, msg|
        r = user.post("/einstellungen/kurse", {"waehrung" => cur, "datum" => date, "kurs" => input})
        {cur, date, input, r.status, r.error_message}.should eq({cur, date, input, 422, msg})
        # The form keeps what was entered (trimmed, the currency upper-cased;
        # an empty date becomes today).
        {input_value(r, "kurs-waehrung"), input_value(r, "kurs-datum"), input_value(r, "kurs-kurs")}
          .should eq({cur.strip.upcase, date.strip.presence || "2026-10-03", input.strip})
        table_rows(r, "Manuelle Kurse").size.should eq 9
      end
      manual_rows.call.should eq saved

      # Deleting: only the manual rate goes; the ECB rate of the day stays.
      r = user.post("/einstellungen/kurse/loeschen", {"waehrung" => "idr", "datum" => "2026-09-04"})
      {r.status, r.location, r.flash}.should eq({303, "/einstellungen/kurse", "Manueller Kurs für IDR gelöscht."})
      user.get("/api/kurs?waehrung=IDR&datum=2026-09-04").body.should eq kurs_json("IDR", "2026-09-04", rate.call("IDR", "2026-09-04"), "ezb")
      r = user.post("/einstellungen/kurse/loeschen", {"waehrung" => "USD", "datum" => "01.10.2026"})
      {r.status, r.flash}.should eq({303, "Manueller Kurs für USD gelöscht."})
      user.get("/api/kurs?waehrung=USD&datum=2026-10-02").body.should eq kurs_json("USD", "2026-09-30", "1.2", "manuell")
      [
        {"USD", "2026-10-01"}, # already deleted
        {"USD", "2026-10-02"}, # only an ECB rate
        {"USD", "broken"},
        {"", "2026-09-30"},
      ].each do |cur, date|
        r = user.post("/einstellungen/kurse/loeschen", {"waehrung" => cur, "datum" => date})
        {cur, date, r.status, r.error_message}.should eq({cur, date, 404, "Diesen manuellen Kurs gibt es nicht (mehr)."})
      end
      E2E::Database.count(world.app.db_path, "SELECT count(*) FROM fx_rates WHERE currency = 'USD' AND date = '2026-10-02' AND source = 'ezb'").should eq 1
      manual_rows.call.should eq saved - 2

      activity = user.get("/aktivitaet").text
      activity.should contain("Manueller Kurs für USD ab 30.09.2026 gespeichert: 1 € = 1,2 USD")
      activity.should contain("Manueller Kurs für USD ab 01.10.2026 gespeichert: 1 € = 1,25 USD")
      activity.should contain("Manueller Kurs für VND ab 03.09.2026 gespeichert: 1 € = 17000,5 VND")
      activity.should contain("Manueller Kurs für IDR ab 04.09.2026 gelöscht")
      count.call(zip).should eq 1
      count.call(nf).should eq 1
    end

    scenario "refreshing the ECB rates by hand", world do
      user = world.user
      user.login("Anna")
      daily = count.call("eurofxref-daily.xml")
      r = user.post("/einstellungen/kurse/aktualisieren")
      {r.status, r.location, r.flash}.should eq({303, "/einstellungen/kurse", "EZB-Kurse aktualisiert (Stand 02.10.2026)."})
      # A cache without gaps only needs the daily file.
      count.call("eurofxref-daily.xml").should be >= daily + 1
      count.call(nf).should eq 1
      user.get("/einstellungen/kurse").text.should contain("EZB-Kurse aktualisiert (Stand 02.10.2026).")
    end

    scenario "expenses in foreign currencies: ECB or manual rate, conversion, the form", world do
      user = world.user
      user.login("Anna")
      user.post("/einstellungen/teilnehmer", {"name" => "Ben"}).status.should eq 303
      anna = id_of(world, "participants", "Anna")
      ben = id_of(world, "participants", "Ben")
      both = {anna => "", ben => ""}
      create = ->(form : Array({String, String})) do
        r = user.post("/ausgaben/neu", form)
        {form.to_h["titel"], r.status, r.status == 422 ? r.error_message : nil}.should eq({form.to_h["titel"], 303, nil})
        newest_expense_id(world)
      end

      # No rate entered: the ECB rate of the day.
      gbp = rate.call("GBP", "2026-10-01")
      pub = create.call(expense_form("Pub", "2026-10-01", "100,00", anna, both, currency: "GBP"))
      expense_row(world, pub).should eq({"amount_cents" => to_eur_cents(10000, 2, gbp.to_f).to_s, "original_amount_minor" => "10000",
                                         "original_currency" => "GBP", "fx_rate" => shortest_float(gbp), "fx_source" => "ezb", "date" => "2026-10-01"})
      form = user.get("/ausgaben/#{pub}")
      {input_value(form, "betrag"), input_value(form, "kurs"), input_value(form, "kurs_quelle")}.should eq({"100,00", german_rate(gbp), "ezb"})
      form.doc.xpath_node(%(//*[@id="kurs-hinweis"])).not_nil!.content.strip.should eq "EZB-Kurs."
      form.doc.xpath_node(%(//*[@id="eur-vorschau"])).not_nil!.content.strip.should eq eur(to_eur_cents(10000, 2, gbp.to_f))
      form.doc.xpath_node(%(//select[@id="waehrung"]/option[@selected])).not_nil!["value"].should eq "GBP"

      # A weekend date takes Friday's rate; a manual rate wins over the ECB.
      sat = create.call(expense_form("Samstag", "2026-09-26", "45,50", ben, both, currency: "CHF"))
      chf = rate.call("CHF", "2026-09-25")
      expense_row(world, sat)["fx_rate"].should eq shortest_float(chf)
      expense_row(world, sat)["amount_cents"].should eq to_eur_cents(4550, 2, chf.to_f).to_s
      usd = create.call(expense_form("Mietwagen", "2026-10-01", "100,00", anna, both, currency: "USD"))
      expense_row(world, usd).should eq({"amount_cents" => "8333", "original_amount_minor" => "10000", "original_currency" => "USD",
                                         "fx_rate" => "1.2", "fx_source" => "manuell", "date" => "2026-10-01"})
      thb = create.call(expense_form("Massage", "2026-09-12", "1.200", ben, both, currency: "", other_currency: "thb"))
      expense_row(world, thb).should eq({"amount_cents" => "3038", "original_amount_minor" => "120000", "original_currency" => "THB",
                                         "fx_rate" => "39.5", "fx_source" => "manuell", "date" => "2026-09-12"})
      form = user.get("/ausgaben/#{thb}")
      {input_value(form, "kurs"), input_value(form, "kurs_quelle"), input_value(form, "waehrung_andere")}.should eq({"39,5", "manuell", "THB"})
      form.doc.xpath_node(%(//*[@id="kurs-hinweis"])).not_nil!.content.strip.should eq "Von Hand eingetragener Kurs."

      # A rate typed into the form; conversion rounds half away from zero.
      half = create.call(expense_form("Halber Cent", "2026-09-20", "1,25", anna, both, currency: "USD", rate: "2"))
      expense_row(world, half).should eq({"amount_cents" => "63", "original_amount_minor" => "125", "original_currency" => "USD",
                                          "fx_rate" => "2", "fx_source" => "manuell", "date" => "2026-09-20"})
      yen = create.call(expense_form("Ramen", "2026-09-21", "125", anna, both, currency: "JPY", rate: "200"))
      expense_row(world, yen)["amount_cents"].should eq "63"
      expense_row(world, yen)["original_amount_minor"].should eq "125"
      kwd = create.call(expense_form("Souk", "2026-09-22", "12,345", ben, both, currency: "", other_currency: "KWD", rate: "0,3312"))
      expense_row(world, kwd).should eq({"amount_cents" => to_eur_cents(12345, 3, 0.3312).to_s, "original_amount_minor" => "12345",
                                         "original_currency" => "KWD", "fx_rate" => "0.3312", "fx_source" => "manuell", "date" => "2026-09-22"})
      to_eur_cents(12345, 3, 0.3312).should eq 3727
      nine = create.call(expense_form("Neun", "2026-09-23", "100,00", anna, both, currency: "SEK", rate: "1,1"))
      expense_row(world, nine)["amount_cents"].should eq "9091"

      # A rate marked as ECB rate is checked against the ECB (without JS a
      # stale rate stays in the field) and replaced.
      stale = create.call(expense_form("Fondue", "2026-10-01", "80,00", anna, both, currency: "CHF", rate: "1,5", rate_source: "ezb"))
      chf = rate.call("CHF", "2026-10-01")
      expense_row(world, stale).should eq({"amount_cents" => to_eur_cents(8000, 2, chf.to_f).to_s, "original_amount_minor" => "8000",
                                           "original_currency" => "CHF", "fx_rate" => shortest_float(chf), "fx_source" => "ezb", "date" => "2026-10-01"})

      # Errors after the rate lookup show the looked-up rate in the form.
      r = user.post("/ausgaben/neu", expense_form("Ohne Leute", "2026-09-29", "250,00", anna, {} of Int64 => String, currency: "GBP"))
      r.status.should eq 422
      r.error_message.should eq "Bitte mindestens eine Person ankreuzen, für die bezahlt wurde."
      gbp = rate.call("GBP", "2026-09-29")
      {input_value(r, "kurs"), input_value(r, "kurs_quelle")}.should eq({german_rate(gbp), "ezb"})
      r.doc.xpath_node(%(//*[@id="eur-vorschau"])).not_nil!.content.strip.should eq eur(to_eur_cents(25000, 2, gbp.to_f))
      # No rate available: the form asks for one.
      r = user.post("/ausgaben/neu", expense_form("Markt", "2026-09-01", "1000", anna, both, currency: "", other_currency: "xof"))
      r.status.should eq 422
      r.error_message.should eq "Für XOF ist am 01.09.2026 kein Wechselkurs verfügbar. Kurs bitte von Hand eintragen."
      {input_value(r, "kurs"), input_value(r, "kurs_quelle"), input_value(r, "waehrung_andere")}.should eq({"", "", "XOF"})
      r = user.post("/ausgaben/neu", expense_form("Alt", "2023-11-15", "10,00", anna, both, currency: "USD"))
      r.error_message.should eq "Für USD ist am 15.11.2023 kein Wechselkurs verfügbar. Kurs bitte von Hand eintragen."

      # The rates page lists the rates of the newest expenses.
      # The rates page lists the rates of the newest expenses (date, then ID,
      # descending).
      page = user.get("/einstellungen/kurse")
      table_rows(page, "Zuletzt verwendet").should eq [
        ["Fondue", "01.10.2026", "#{german_rate(chf)} CHF", "EZB"],
        ["Mietwagen", "01.10.2026", "1,2 USD", "manuell"],
        ["Pub", "01.10.2026", "#{german_rate(rate.call("GBP", "2026-10-01"))} GBP", "EZB"],
        ["Samstag", "26.09.2026", "#{german_rate(rate.call("CHF", "2026-09-25"))} CHF", "EZB"],
        ["Neun", "23.09.2026", "1,1 SEK", "manuell"],
        ["Souk", "22.09.2026", "0,3312 KWD", "manuell"],
        ["Ramen", "21.09.2026", "200 JPY", "manuell"],
        ["Halber Cent", "20.09.2026", "2 USD", "manuell"],
        ["Massage", "12.09.2026", "39,5 THB", "manuell"],
      ]
      page.doc.xpath_nodes(%(//section[.//h2[normalize-space(.)="Zuletzt verwendet"]]//tbody/tr/td/a)).map(&.["href"])
        .should eq [stale, usd, pub, sat, nine, kwd, yen, half, thb].map { |id| "/ausgaben/#{id}" }
      count.call(zip).should eq 1
    end

    scenario "after a restart nothing is downloaded again", world do
      requests = {count.call(nf), count.call(zip)}
      world.restart(E2E::DEFAULT_NOW)
      sleep 250.milliseconds
      user = world.user
      user.login("Anna")
      user.get("/api/kurs?waehrung=JPY&datum=2024-05-17").body.should eq kurs_json("JPY", "2024-05-17", rate.call("JPY", "2024-05-17"), "ezb")
      r = user.get("/api/kurs?waehrung=USD&datum=2023-11-20")
      {r.status, r.body}.should eq({422, error_json("Für USD gibt es um den 20.11.2023 keinen EZB-Kurs – bitte Kurs von Hand eintragen.")})
      {count.call(nf), count.call(zip)}.should eq requests
    end
  end

  describe "Exchange rates when the ECB fails" do
    upstream = E2E::FakeECB.new
    ecb = E2E::SwitchableECB.new(upstream)
    world = E2E::World.new("fx-failure", env: {"ZIPFELKASSE_TEST_ECB_URL" => ecb.base_url})
    after_all do
      world.stop
      ecb.close
      upstream.close
    end
    failed = ->(why : String) { "Die EZB-Kurse konnten nicht geladen werden (#{why}). Bitte später erneut versuchen oder den Kurs von Hand eintragen." }

    scenario "refresh, /api/kurs and the expense form report the failure", world do
      world.app
      user = world.user
      user.login("Anna")
      ecb.failure = 500
      r = user.post("/einstellungen/kurse/aktualisieren")
      r.status.should eq 502
      r.error_message.should eq failed.call("HTTP status 500")
      r.text.should contain("EZB-Referenzkurse")
      r.flash.should be_nil
      # The cached rates still work.
      user.get("/api/kurs?waehrung=USD&datum=2026-10-01").status.should eq 200

      zips = ecb.count("eurofxref-hist.zip")
      r = user.get("/api/kurs?waehrung=USD&datum=2024-05-17")
      {r.status, r.body}.should eq({502, error_json(failed.call("HTTP status 500"))})
      r.content_type.should eq "application/json; charset=utf-8"
      ecb.count("eurofxref-hist.zip").should eq zips + 1
      # Right after a failure the app does not ask again.
      ecb.failure = nil
      r = user.get("/api/kurs?waehrung=USD&datum=2024-05-17")
      {r.status, r.body}.should eq({502, error_json(failed.call("HTTP status 500"))})
      r = user.post("/ausgaben/neu", expense_form("Hotel", "2024-05-17", "100,00", user.me.not_nil!, {user.me.not_nil! => ""}, currency: "USD"))
      r.status.should eq 422
      r.error_message.should eq "Für USD ist am 17.05.2024 kein Wechselkurs verfügbar. Kurs bitte von Hand eintragen."
      ecb.count("eurofxref-hist.zip").should eq zips + 1

      ecb.failure = 404
      r = user.post("/einstellungen/kurse/aktualisieren")
      {r.status, r.error_message}.should eq({502, failed.call("HTTP status 404")})
      ecb.failure = :empty
      r = user.post("/einstellungen/kurse/aktualisieren")
      {r.status, r.error_message}.should eq({502, failed.call("file contains no rates")})
      ecb.failure = nil
      r = user.post("/einstellungen/kurse/aktualisieren")
      {r.status, r.flash}.should eq({303, "EZB-Kurse aktualisiert (Stand 02.10.2026)."})
    end
  end

  # The frozen clock does not advance, so the FX job's wait for the next 16:30
  # never ends within a scenario and downloads can be counted exactly.
  describe "ECB schedule" do
    fri = Time.utc(2036, 11, 7)
    mon = fri + 3.days
    later = fri + 7.days
    first = E2E::FakeECB.new(fri)
    ecb = E2E::SwitchableECB.new(first)
    fakes = [first, E2E::FakeECB.new(mon), E2E::FakeECB.new(later)]
    world = E2E::World.new("fx-schedule", now: "2036-11-08T11:00:00Z", env: {"ZIPFELKASSE_TEST_ECB_URL" => ecb.base_url})
    after_all do
      world.stop
      ecb.close
      fakes.each(&.close)
    end
    newest = -> { E2E::Database.open(world.app.db_path) { |db| db.scalar("SELECT max(date) FROM fx_rates WHERE source = 'ezb'").as(String) } }
    # Restarts at *now* (UTC) and checks which files the startup fetched.
    restart = ->(now : String, files : Array(String)) do
      before = ecb.requests.size
      world.restart(now)
      expected = files
      E2E.wait_until("startup downloads at #{now}", 10.seconds) { ecb.requests.size >= before + expected.size }
      sleep 250.milliseconds # nothing else follows
      ecb.requests[before..].sort.should eq expected.sort
    end

    scenario "loads at startup only when the cache is behind the last 16:30 (Berlin)", world do
      {fri.friday?, mon.monday?, later.friday?}.should eq({true, true, true})
      world.app
      ecb.requests.should eq ["eurofxref-hist-90d.xml"]
      newest.call.should eq "2036-11-07"
      user = world.user
      user.login("Anna")
      # Unknown currency for today: the daily file is asked once, then the
      # answer is reused (cooldown).
      2.times do
        r = user.get("/api/kurs?waehrung=XAF")
        {r.status, r.body}.should eq({422, error_json("Für XAF gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.")})
      end
      ecb.count("eurofxref-daily.xml").should eq 1

      # Monday 16:29 in Berlin (CET): Friday's rates are the newest expected.
      restart.call("2036-11-10T15:29:00Z", [] of String)
      user.get("/api/kurs?waehrung=USD").body.should eq kurs_json("USD", "2036-11-07", first.rate("USD", fri), "ezb")
      # 16:30 in Berlin (15:30 UTC): Monday's rates are due, the daily file is
      # enough.
      ecb.upstream = fakes[1]
      restart.call("2036-11-10T15:30:00Z", ["eurofxref-daily.xml"])
      newest.call.should eq "2036-11-10"
      user.get("/api/kurs?waehrung=USD").body.should eq kurs_json("USD", "2036-11-10", fakes[1].rate("USD", mon), "ezb")
      user.get("/einstellungen/kurse").text.should contain("bis 10.11.2036.")
      # Tuesday morning: nothing new is expected yet.
      restart.call("2036-11-11T07:00:00Z", [] of String)
      # A week later, with gaps in the cache: the 90-day file.
      ecb.upstream = fakes[2]
      restart.call("2036-11-15T11:00:00Z", ["eurofxref-hist-90d.xml"])
      newest.call.should eq "2036-11-14"
      E2E::Database.count(world.app.db_path, "SELECT count(DISTINCT date) FROM fx_rates WHERE source = 'ezb' AND date > '2036-11-10'").should eq 4
      # Sunday evening: still Friday's rates.
      restart.call("2036-11-16T19:00:00Z", [] of String)
      user.get("/api/kurs?waehrung=GBP&datum=2036-11-16").body.should eq kurs_json("GBP", "2036-11-14", fakes[2].rate("GBP", later), "ezb")
    end
  end

  describe "Export" do
    world = E2E::World.new("export")
    after_all { world.stop }
    ids = {} of String => Int64
    bom = 0xFEFF.chr.to_s
    header = "ID;Datum;Titel;Kategorie;Bezahlt von;Betrag (EUR);Originalbetrag;Währung;Kurs;Art;Aufteilung;Notiz"
    long_title = "Sehr langer Titel mit <Sonderzeichen> & mehr Text dahinter"
    # Anna's postings: her share of every expense up to today; NAME is cut
    # to 32 characters before escaping.
    anna_trns = [
      ofx_trn("20260830", "-2.00", 1, "Brötchen", ynab_memo("4,00", "", "Jürgen", 1)),
      ofx_trn("20260901", "-6.01", 2, "Café &amp; Kuchen", ynab_memo("12,01", "", "Anna", 2)),
      ofx_trn("20260903", "-40.00", 3, %(Diner "NYC"), ynab_memo("80,00", " (90,00 USD)", "Ben", 3)),
      ofx_trn("20260905", "-6.67", 6, %(=Formel &lt;&amp;&gt; "q"), ynab_memo("10,00", "", "Anna", 6)),
      ofx_trn("20260906", "-6.23", 7, "Sushi", ynab_memo("12,46", " (2.000 JPY)", "Anna", 7)),
      ofx_trn("20260907", "-5.00", 8, "+49 Telefon", ynab_memo("20,00", "", "Ben", 8)),
      ofx_trn("20260908", "-7.50", 9, "-Rabatt", ynab_memo("7,50", "", "Dora", 9)),
      ofx_trn("20260912", "-3.33", 12, "Sehr langer Titel mit &lt;Sonderzei", ynab_memo("9,99", "", "Anna", 12)),
      ofx_trn("20261003", "-1.50", 13, "Heute", ynab_memo("3,00", "", "Anna", 13)),
    ]

    # Downloads *path*, checks the download headers and returns the body.
    download = ->(user : E2E::User, path : String, type : String, filename : String) do
      r = user.get(path)
      {path, r.status, r.content_type, r.headers["Content-Disposition"]?, r.headers["Cache-Control"]?}
        .should eq({path, 200, type, %(attachment; filename="#{filename}"), "no-store"})
      r.headers["Content-Length"].should eq r.body.bytesize.to_s
      r.body
    end
    csv_type = "text/csv; charset=utf-8"
    json_type = "application/json; charset=utf-8"
    ofx_type = "application/x-ofx"

    scenario "a household with every kind of expense", world do
      user = world.user
      user.login("Anna")
      ["Ben", "Dora", "Emil", "Jürgen", "Xaver"].each { |name| user.post("/einstellungen/teilnehmer", {"name" => name}).status.should eq 303 }
      ["Anna", "Ben", "Dora", "Emil", "Jürgen", "Xaver"].each { |name| ids[name] = id_of(world, "participants", name) }
      user.post("/einstellungen/teilnehmer/#{ids["Xaver"]}/archivieren").status.should eq 303
      user.post("/einstellungen", {"gruppenname" => %(WG <Zipfel> & "Co")}).status.should eq 303
      anna, ben, dora, jue = ids["Anna"], ids["Ben"], ids["Dora"], ids["Jürgen"]
      [
        expense_form("Brötchen", "2026-08-30", "4,00", jue, {anna => "", jue => ""}),
        expense_form("Café & Kuchen", "2026-09-01", "12,01", anna, {anna => "", jue => ""},
          category: id_of(world, "categories", "Restaurant"), notes: "lecker; „süß“"),
        expense_form(%(Diner "NYC"), "2026-09-03", "90,00", ben, {anna => "", ben => ""}, currency: "USD", rate: "1,125"),
        expense_form("Rückzahlung", "2026-09-05", "6,00", jue, {anna => ""}, reimbursement: true),
        expense_form("=SUMME(A1)", "2026-09-10", "5,00", ben, {ben => ""}, category: id_of(world, "categories", "Lebensmittel")),
        expense_form(%(=Formel <&> "q"), "2026-09-05", "10,00", anna, {anna => "2", jue => "1"}, mode: "shares",
          notes: "Zeile1\nZeile2\r\nZeile3; x"),
        expense_form("Sushi", "2026-09-06", "2000", anna, {anna => "", jue => ""}, currency: "JPY", rate: "160,5"),
        expense_form("+49 Telefon", "2026-09-07", "20,00", ben, {anna => "25", ben => "75"}, mode: "percent",
          category: id_of(world, "categories", "Haushalt"), notes: "@home"),
        expense_form("-Rabatt", "2026-09-08", "7,50", dora, {anna => "7,50", ben => "0"}, mode: "amount"),
        expense_form("Gelöscht", "2026-09-09", "1,00", anna, {anna => ""}),
        expense_form("Konzert", "2026-12-04", "50,00", ben, {anna => "", ben => ""}),
        expense_form(long_title, "2026-09-12", "9,99", anna, {anna => "", ben => "", dora => ""}),
        expense_form("Heute", "2026-10-03", "3,00", anna, {anna => "", ben => ""}),
      ].each_with_index do |form, i|
        r = user.post("/ausgaben/neu", form)
        {form.to_h["titel"], r.status}.should eq({form.to_h["titel"], 303})
        newest_expense_id(world).should eq i + 1
      end
      user.post("/ausgaben/10/loeschen").status.should eq 303
    end

    scenario "/export/ausgaben.csv: German Excel CSV of all expenses", world do
      user = world.user
      user.login("Emil")
      body = download.call(user, "/export/ausgaben.csv", csv_type, "zipfelkasse-ausgaben-2026-10-03.csv")
      body.should start_with bom
      csv_rows(body, ';').should eq csv_rows(lf([
        "#{header};Anteil Anna;Anteil Ben;Anteil Dora;Anteil Jürgen",
        "1;30.08.2026;Brötchen;;Jürgen;4,00;4,00;EUR;;Ausgabe;Gleichmäßig;;2,00;;;2,00",
        "2;01.09.2026;Café & Kuchen;Restaurant;Anna;12,01;12,01;EUR;;Ausgabe;Gleichmäßig;\"lecker; „süß“\";6,01;;;6,00",
        "3;03.09.2026;\"Diner \"\"NYC\"\"\";;Ben;80,00;90,00;USD;1,125;Ausgabe;Gleichmäßig;;40,00;40,00;;",
        "4;05.09.2026;Rückzahlung;;Jürgen;6,00;6,00;EUR;;Rückzahlung;Gleichmäßig;;6,00;;;",
        "6;05.09.2026;\"'=Formel <&> \"\"q\"\"\";;Anna;10,00;10,00;EUR;;Ausgabe;Nach Anteilen;\"Zeile1\nZeile2\r\nZeile3; x\";6,67;;;3,33",
        "7;06.09.2026;Sushi;;Anna;12,46;2000;JPY;160,5;Ausgabe;Gleichmäßig;;6,23;;;6,23",
        "8;07.09.2026;'+49 Telefon;Haushalt;Ben;20,00;20,00;EUR;;Ausgabe;Nach Prozent;'@home;5,00;15,00;;",
        "9;08.09.2026;'-Rabatt;;Dora;7,50;7,50;EUR;;Ausgabe;Nach Beträgen;;7,50;0,00;;",
        "5;10.09.2026;'=SUMME(A1);Lebensmittel;Ben;5,00;5,00;EUR;;Ausgabe;Gleichmäßig;;;5,00;;",
        "12;12.09.2026;#{long_title};;Anna;9,99;9,99;EUR;;Ausgabe;Gleichmäßig;;3,33;3,33;3,33;",
        "13;03.10.2026;Heute;;Anna;3,00;3,00;EUR;;Ausgabe;Gleichmäßig;;1,50;1,50;;",
        "11;04.12.2026;Konzert;;Ben;50,00;50,00;EUR;;Ausgabe;Gleichmäßig;;25,00;25,00;;",
      ]), ';')

      # A range: only the people involved in it get a column.
      csv_rows(download.call(user, "/export/ausgaben.csv?von=2026-09-03&bis=06.09.2026", csv_type,
        "zipfelkasse-ausgaben-2026-09-03_2026-09-06.csv"), ';').should eq csv_rows(lf([
        "#{header};Anteil Anna;Anteil Ben;Anteil Jürgen",
        "3;03.09.2026;\"Diner \"\"NYC\"\"\";;Ben;80,00;90,00;USD;1,125;Ausgabe;Gleichmäßig;;40,00;40,00;",
        "4;05.09.2026;Rückzahlung;;Jürgen;6,00;6,00;EUR;;Rückzahlung;Gleichmäßig;;6,00;;",
        "6;05.09.2026;\"'=Formel <&> \"\"q\"\"\";;Anna;10,00;10,00;EUR;;Ausgabe;Nach Anteilen;\"Zeile1\nZeile2\r\nZeile3; x\";6,67;;3,33",
        "7;06.09.2026;Sushi;;Anna;12,46;2000;JPY;160,5;Ausgabe;Gleichmäßig;;6,23;;6,23",
      ]), ';')
      csv_rows(download.call(user, "/export/ausgaben.csv?von=2026-12-01", csv_type, "zipfelkasse-ausgaben-ab-2026-12-01.csv"), ';')
        .should eq csv_rows(lf(["#{header};Anteil Anna;Anteil Ben", "11;04.12.2026;Konzert;;Ben;50,00;50,00;EUR;;Ausgabe;Gleichmäßig;;25,00;25,00"]), ';')
      csv_rows(download.call(user, "/export/ausgaben.csv?bis=2026-08-31&von=", csv_type, "zipfelkasse-ausgaben-bis-2026-08-31.csv"), ';')
        .should eq csv_rows(lf(["#{header};Anteil Anna;Anteil Jürgen", "1;30.08.2026;Brötchen;;Jürgen;4,00;4,00;EUR;;Ausgabe;Gleichmäßig;;2,00;2,00"]), ';')
      # Nothing in the range: only the fixed columns.
      csv_rows(download.call(user, "/export/ausgaben.csv?von=1.1.2020&bis=02.01.2020", csv_type, "zipfelkasse-ausgaben-2020-01-01_2020-01-02.csv"), ';')
        .should eq csv_rows(header, ';')
    end

    scenario "/export/ausgaben.json: everything with shares", world do
      user = world.user
      user.login("Emil")
      anna, ben, jue = ids["Anna"], ids["Ben"], ids["Jürgen"]
      share = ->(id : Int64, name : String, weight : Int32, cents : Int32) do
        {"participant_id" => JSON::Any.new(id), "name" => JSON::Any.new(name), "weight" => JSON::Any.new(weight.to_i64), "amount_cents" => JSON::Any.new(cents.to_i64)}
      end
      expense = ->(id : Int32, date : String, title : String, paid_by : Int64, payer : String, cents : Int32, reimb : Bool, mode : String, minor : Int32, cur : String, rate : Float64, source : String, notes : String, shares : Array(Hash(String, JSON::Any))) do
        {"id" => id, "date" => date, "title" => title, "category_id" => nil, "category" => "", "paid_by" => paid_by, "paid_by_name" => payer,
         "amount_cents" => cents, "is_reimbursement" => reimb, "split_mode" => mode, "original_amount_minor" => minor,
         "original_currency" => cur, "fx_rate" => rate, "fx_source" => source, "notes" => notes, "recurring_id" => nil,
         "shares" => shares, "created_at" => "2026-10-03T10:00:00Z", "updated_at" => "2026-10-03T10:00:00Z"}
      end
      expected = {
        "group"        => %(WG <Zipfel> & "Co"),
        "exported_at"  => "2026-10-03T10:00:00Z",
        "from"         => "2026-09-03",
        "to"           => "2026-09-06",
        "currency"     => "EUR",
        "participants" => ["Anna", "Ben", "Dora", "Emil", "Jürgen", "Xaver"].map { |name| {"id" => ids[name], "name" => name, "archived" => name == "Xaver"} },
        "expenses"     => [
          expense.call(3, "2026-09-03", %(Diner "NYC"), ben, "Ben", 8000, false, "equal", 9000, "USD", 1.125, "manuell", "",
            [share.call(anna, "Anna", 1, 4000), share.call(ben, "Ben", 1, 4000)]),
          expense.call(4, "2026-09-05", "Rückzahlung", jue, "Jürgen", 600, true, "equal", 600, "EUR", 1.0, "", "",
            [share.call(anna, "Anna", 1, 600)]),
          expense.call(6, "2026-09-05", %(=Formel <&> "q"), anna, "Anna", 1000, false, "shares", 1000, "EUR", 1.0, "", "Zeile1\nZeile2\r\nZeile3; x",
            [share.call(anna, "Anna", 2, 667), share.call(jue, "Jürgen", 1, 333)]),
          expense.call(7, "2026-09-06", "Sushi", anna, "Anna", 1246, false, "equal", 2000, "JPY", 160.5, "manuell", "",
            [share.call(anna, "Anna", 1, 623), share.call(jue, "Jürgen", 1, 623)]),
        ],
      }
      body = download.call(user, "/export/ausgaben.json?von=2026-09-03&bis=2026-09-06", json_type, "zipfelkasse-ausgaben-2026-09-03_2026-09-06.json")
      body.should end_with("}\n")
      JSON.parse(body).should eq JSON.parse(expected.to_json)

      # Without a range: no from/to, all non-deleted expenses chronologically,
      # categories and percent/amount weights.
      json = JSON.parse(download.call(user, "/export/ausgaben.json", json_type, "zipfelkasse-ausgaben-2026-10-03.json"))
      json.as_h.keys.sort.should eq ["currency", "expenses", "exported_at", "group", "participants"]
      json["expenses"].as_a.map(&.["id"].as_i).should eq [1, 2, 3, 4, 6, 7, 8, 9, 5, 12, 13, 11]
      phone = json["expenses"].as_a.find! { |e| e["id"] == 8 }
      {phone["category_id"], phone["category"], phone["notes"], phone["split_mode"]}
        .should eq({JSON::Any.new(id_of(world, "categories", "Haushalt")), JSON::Any.new("Haushalt"), JSON::Any.new("@home"), JSON::Any.new("percent")})
      phone["shares"].should eq JSON.parse([share.call(anna, "Anna", 2500, 500), share.call(ben, "Ben", 7500, 1500)].to_json)
      discount = json["expenses"].as_a.find! { |e| e["id"] == 9 }
      discount["shares"].should eq JSON.parse([share.call(anna, "Anna", 750, 750), share.call(ben, "Ben", 0, 0)].to_json)

      json = JSON.parse(download.call(user, "/export/ausgaben.json?von=2020-01-01&bis=2020-01-02", json_type,
        "zipfelkasse-ausgaben-2020-01-01_2020-01-02.json"))
      {json["expenses"], json["from"], json["to"], json["participants"].size}.should eq({JSON.parse("[]"), "2020-01-01", "2020-01-02", 6})
    end

    scenario "/export/ynab.ofx and /export/ynab.csv: my shares", world do
      user = world.user
      user.login("Anna")
      acct = "ZIPFELKASSE-#{ids["Anna"]}"
      now = "20261003100000"
      download.call(user, "/export/ynab.ofx", ofx_type, "zipfelkasse-ynab-2026-10-03.ofx")
        .should eq ofx_file(acct, "20260830", "20261003", now, anna_trns.flatten, "-78.24")
      download.call(user, "/export/ynab.ofx?von=2026-09-06", ofx_type, "zipfelkasse-ynab-ab-2026-09-06.ofx")
        .should eq ofx_file(acct, "20260906", "20261003", now, anna_trns[4..].flatten, "-23.56")
      download.call(user, "/export/ynab.ofx?von=01.09.2026&bis=2026-09-05", ofx_type, "zipfelkasse-ynab-2026-09-01_2026-09-05.ofx")
        .should eq ofx_file(acct, "20260901", "20260905", now, anna_trns[1..3].flatten, "-52.68")
      download.call(user, "/export/ynab.ofx?von=2020-01-01&bis=2020-01-02", ofx_type, "zipfelkasse-ynab-2020-01-01_2020-01-02.ofx")
        .should eq ofx_file(acct, "20200101", "20200102", now, [] of String, "0.00")

      csv_rows(download.call(user, "/export/ynab.csv", csv_type, "zipfelkasse-ynab-2026-10-03.csv"), ',').should eq csv_rows(lf([
        "Date,Payee,Memo,Outflow,Inflow",
        %(2026-08-30,Brötchen,"Gesamt 4,00 € · bezahlt von Jürgen · zipfelkasse #1",2.00,),
        %(2026-09-01,Café & Kuchen,"Gesamt 12,01 € · bezahlt von Anna · zipfelkasse #2",6.01,),
        %(2026-09-03,"Diner ""NYC""","Gesamt 80,00 € (90,00 USD) · bezahlt von Ben · zipfelkasse #3",40.00,),
        %(2026-09-05,"'=Formel <&> ""q""","Gesamt 10,00 € · bezahlt von Anna · zipfelkasse #6",6.67,),
        %(2026-09-06,Sushi,"Gesamt 12,46 € (2.000 JPY) · bezahlt von Anna · zipfelkasse #7",6.23,),
        %(2026-09-07,'+49 Telefon,"Gesamt 20,00 € · bezahlt von Ben · zipfelkasse #8",5.00,),
        %(2026-09-08,'-Rabatt,"Gesamt 7,50 € · bezahlt von Dora · zipfelkasse #9",7.50,),
        %(2026-09-12,#{long_title},"Gesamt 9,99 € · bezahlt von Anna · zipfelkasse #12",3.33,),
        %(2026-10-03,Heute,"Gesamt 3,00 € · bezahlt von Anna · zipfelkasse #13",1.50,),
      ]), ',')
      csv_rows(download.call(user, "/export/ynab.csv?bis=2026-08-31", csv_type, "zipfelkasse-ynab-bis-2026-08-31.csv"), ',')
        .should eq csv_rows(lf(["Date,Payee,Memo,Outflow,Inflow", %(2026-08-30,Brötchen,"Gesamt 4,00 € · bezahlt von Jürgen · zipfelkasse #1",2.00,)]), ',')

      # Ben has other shares; Emil has none (the period then is today).
      user.login("Ben")
      csv_rows(download.call(user, "/export/ynab.csv?von=2026-09-07", csv_type, "zipfelkasse-ynab-ab-2026-09-07.csv"), ',').should eq csv_rows(lf([
        "Date,Payee,Memo,Outflow,Inflow",
        %(2026-09-07,'+49 Telefon,"Gesamt 20,00 € · bezahlt von Ben · zipfelkasse #8",15.00,),
        %(2026-09-10,'=SUMME(A1),"Gesamt 5,00 € · bezahlt von Ben · zipfelkasse #5",5.00,),
        %(2026-09-12,#{long_title},"Gesamt 9,99 € · bezahlt von Anna · zipfelkasse #12",3.33,),
        %(2026-10-03,Heute,"Gesamt 3,00 € · bezahlt von Anna · zipfelkasse #13",1.50,),
      ]), ',')
      user.login("Emil")
      download.call(user, "/export/ynab.ofx", ofx_type, "zipfelkasse-ynab-2026-10-03.ofx")
        .should eq ofx_file("ZIPFELKASSE-#{ids["Emil"]}", "20261003", "20261003", now, [] of String, "0.00")
      csv_rows(download.call(user, "/export/ynab.csv", csv_type, "zipfelkasse-ynab-2026-10-03.csv"), ',').should eq [["Date", "Payee", "Memo", "Outflow", "Inflow"]]
    end

    scenario "/export page, invalid ranges and identity", world do
      user = world.user
      user.login("Anna")
      page = user.get("/export")
      page.status.should eq 200
      page.headers["Cache-Control"]?.should eq "no-store"
      form = page.doc.xpath_node(%(//form[@action="/export/ausgaben.csv"])).not_nil!
      form["method"].should eq "get"
      {input_value(page, "von"), input_value(page, "bis")}.should eq({"", ""})
      form.xpath_nodes(".//button[@formaction]").map { |b| {b["formaction"], b.content.strip} }.should eq [
        {"/export/ausgaben.csv", "CSV (Excel, Numbers)"}, {"/export/ausgaben.json", "JSON"},
        {"/export/ynab.ofx", "OFX"}, {"/export/ynab.csv", "CSV (YNAB-Format)"},
      ]
      page.text.should contain("Leer lassen für alle Ausgaben.")
      page = user.get("/export?von=1.9.2026&bis=30.09.2026")
      {page.status, input_value(page, "von"), input_value(page, "bis")}.should eq({200, "2026-09-01", "2026-09-30"})

      {
        "von=broken"                    => "Ungültiges Datum „broken“.",
        "von=broken&bis=2026-09-30"     => "Ungültiges Datum „broken“.",
        "von=2026-09-01&bis=31.02.2026" => "Ungültiges Datum „31.02.2026“.",
        "bis=1999-12-31"                => "Das Datum „1999-12-31“ liegt nicht zwischen 2000 und 2100.",
        "von=%20"                       => "Bitte ein Datum angeben.",
        "von=2026-09-30&bis=2026-09-01" => "„Bis“ liegt vor „Von“.",
        "von=2026-09-30&bis=29.09.2026" => "„Bis“ liegt vor „Von“.",
      }.each do |query, msg|
        ["/export", "/export/ausgaben.csv", "/export/ausgaben.json", "/export/ynab.ofx", "/export/ynab.csv"].each do |path|
          r = user.get("#{path}?#{query}")
          {path, query, r.status, r.content_type, r.headers["Content-Disposition"]?, r.error_message}
            .should eq({path, query, 422, "text/html; charset=utf-8", nil, msg})
          # The page comes back with empty dates.
          {input_value(r, "von"), input_value(r, "bis")}.should eq({"", ""})
        end
      end
      # The same day as start and end is fine.
      download.call(user, "/export/ausgaben.csv?von=2026-09-01&bis=2026-09-01", csv_type,
        "zipfelkasse-ausgaben-2026-09-01_2026-09-01.csv").lines.size.should eq 2

      user.post("/export/ausgaben.csv").status.should eq 405
      anonymous = world.user
      r = anonymous.get("/export/ausgaben.csv?von=2026-09-01")
      {r.status, r.location}.should eq({303, "/wer?zurueck=%2Fexport%2Fausgaben.csv%3Fvon%3D2026-09-01"})
      ["/export", "/export/ausgaben.json", "/export/ynab.ofx", "/export/ynab.csv"].each do |path|
        r = anonymous.get(path)
        {r.status, r.location}.should eq({303, "/wer?zurueck=#{URI.encode_www_form(path)}"})
      end
    end

    scenario "shortly after midnight in Berlin the YNAB files end with the UTC date", world do
      # 00:30 in Berlin is still the previous day in UTC. YNAB rejects dates
      # in its future, so the YNAB files leave out today's expenses; the file
      # names and the other exports use the local date.
      world.restart("2026-10-02T22:30:00Z")
      user = world.user
      user.login("Anna")
      csv_rows(download.call(user, "/export/ynab.csv?von=2026-09-12", csv_type, "zipfelkasse-ynab-ab-2026-09-12.csv"), ',')
        .should eq csv_rows(lf(["Date,Payee,Memo,Outflow,Inflow", %(2026-09-12,#{long_title},"Gesamt 9,99 € · bezahlt von Anna · zipfelkasse #12",3.33,)]), ',')
      download.call(user, "/export/ynab.ofx", ofx_type, "zipfelkasse-ynab-2026-10-03.ofx")
        .should eq ofx_file("ZIPFELKASSE-#{ids["Anna"]}", "20260830", "20260912", "20261002223000", anna_trns[0..7].flatten, "-76.74")
      csv_rows(download.call(user, "/export/ausgaben.csv?von=2026-10-01&bis=2026-10-31", csv_type, "zipfelkasse-ausgaben-2026-10-01_2026-10-31.csv"), ';')
        .should eq csv_rows(lf(["#{header};Anteil Anna;Anteil Ben", "13;03.10.2026;Heute;;Anna;3,00;3,00;EUR;;Ausgabe;Gleichmäßig;;1,50;1,50"]), ';')
      download.call(user, "/export/ausgaben.json?bis=2026-12-31", json_type, "zipfelkasse-ausgaben-bis-2026-12-31.json")
    end
  end
end
