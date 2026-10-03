require "../web/web_helper"
require "./fake_ecb"

private alias FX = Zipfelkasse::FX
private alias Domain = Zipfelkasse::Domain

private BERLIN = Time::Location.load("Europe/Berlin")

# A point in time in Europe/Berlin ("2006-01-02 15:04").
private def at(s : String) : Time
  Time.parse(s, "%Y-%m-%d %H:%M", BERLIN)
end

private def fx_config(fake : FXSpec::FakeECB) : Zipfelkasse::Config
  config = Zipfelkasse::Config.new
  config.location = BERLIN
  config.ecb_base_url = fake.base_url
  config
end

# Today is Friday, 2026-10-02, 12:00 (the day's rates are not yet published).
private def new_service(store : Zipfelkasse::Store, fake : FXSpec::FakeECB) : FX::Service
  d = Zipfelkasse::Web::Deps.new(fx_config(fake), store, Zipfelkasse::Web::Renderer.new(store),
    Zipfelkasse::Logger.new(IO::Memory.new))
  service = FX::Service.new(d)
  service.clock = -> { at("2026-10-02 12:00") }
  service
end

private def with_service(store = new_test_store, &)
  fake = FXSpec::FakeECB.new
  begin
    yield new_service(store, fake), fake, store
  ensure
    fake.close
    store.close
  end
end

private def last_activity(store : Zipfelkasse::Store) : String
  acts = store.list_activity(Zipfelkasse::Store::ActivityFilter.new(limit: 1))
  acts.size.should eq 1
  acts[0].action.should eq Zipfelkasse::Store::ACTION_SETTINGS_UPDATED
  acts[0].actor_id.should_not eq 0
  acts[0].details.text
end

private def wait_for(timeout = 2.seconds, &) : Nil
  deadline = Time.instant + timeout
  until yield
    fail "timeout" if Time.instant > deadline
    sleep 1.millisecond
  end
end

describe Zipfelkasse::FX::Service do
  it "returns 1 for EUR and rejects invalid currencies without loading" do
    with_service do |s, fake|
      r = s.rate(" eur ", date("2026-09-01"))
      r.should eq Domain::FXRate.new("EUR", date("2026-09-01"), 1.0, Domain::FX_SOURCE_FIXED)
      ["", "US", "US1", "EURO"].each do |bad|
        store_validation_error { s.rate(bad, date("2026-09-01")) }
      end
      fake.total.should eq 0
    end
  end

  it "loads the daily file and then answers from the cache" do
    with_service do |s, fake|
      r = s.rate("usd", date("2026-10-01"))
      r.should eq Domain::FXRate.new("USD", date("2026-10-01"), 1.1298, Domain::FX_SOURCE_ECB)
      fake.count(FX::FILE_DAILY).should eq 1
      fake.total.should eq 1
      fake.agents[0].should start_with("zipfelkasse/")
      # Today before 16:30: yesterday's rate is the latest.
      s.rate("USD", date("2026-10-02")).date.should eq date("2026-10-01")
      # Future: the latest rate.
      s.rate("GBP", date("2026-12-24")).rate.should eq 0.85373
      fake.total.should eq 1
    end
  end

  it "uses the 90-day file for older dates" do
    with_service do |s, fake|
      # Sunday gives the rate of the Friday before.
      r = s.rate("JPY", date("2026-09-27"))
      r.rate.should eq 176.5
      r.date.should eq date("2026-09-25")
      fake.count(FX::FILE_90D).should eq 1
      fake.total.should eq 1
      s.rate("USD", date("2026-09-29")).rate.should eq 1.1251
      fake.total.should eq 1
    end
  end

  it "escalates from the daily file to the 90-day file" do
    with_service do |s, fake|
      s.clock = -> { at("2026-10-02 17:00") }
      fake.files[FX::FILE_DAILY] = (%(<?xml version="1.0"?><gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" ) +
                                    %(xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref"><Cube><Cube time="2026-10-02">) +
                                    %(<Cube currency="USD" rate="1.1311"/></Cube></Cube></gesmes:Envelope>)).to_slice
      r = s.rate("USD", date("2026-10-01"))
      r.rate.should eq 1.1298
      r.date.should eq date("2026-10-01")
      fake.count(FX::FILE_DAILY).should eq 1
      fake.count(FX::FILE_90D).should eq 1
      s.rate("USD", date("2026-10-02")).rate.should eq 1.1311
      fake.total.should eq 2
    end
  end

  it "loads the complete history only once" do
    store = new_test_store
    with_service(store) do |s, fake|
      s.rate("USD", date("2024-01-03")).rate.should eq 1.0919
      fake.count(FX::FILE_HIST).should eq 1
      fake.total.should eq 1
      # Weekend: the Friday before, from the cache.
      r = s.rate("GBP", date("2022-03-06"))
      r.rate.should eq 0.836
      r.date.should eq date("2022-03-01")
      # RUB has not been quoted since March 2022.
      store_validation_error { s.rate("RUB", date("2024-01-03")) }.should contain("um den 03.01.2024 keinen EZB-Kurs")
      store_validation_error { s.rate("XYZ", date("2024-01-03")) }
        .should eq "Für XYZ gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen."
      fake.total.should eq 1

      # Restart: the history is cached and not loaded again.
      fake2 = FXSpec::FakeECB.new
      begin
        s2 = new_service(store, fake2)
        s2.rate("USD", date("2024-01-02")).rate.should eq 1.0956
        store_validation_error { s2.rate("JPY", date("1998-12-31")) }.should contain("keinen EZB-Kurs")
        fake2.total.should eq 0
      ensure
        fake2.close
      end
    end
  end

  it "does not load again shortly after a fetch for an unknown currency" do
    with_service do |s, fake|
      store_validation_error { s.rate("XYZ", date("2026-10-01")) }
        .should eq "Für XYZ gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen."
      store_validation_error { s.rate("XYZ", date("2026-10-01")) }.should contain("Für XYZ gibt es keinen EZB-Kurs")
      fake.total.should eq 1
    end
  end

  it "prefers manual rates" do
    with_service do |s, fake, store|
      store.set_manual_fx_rate(0_i64, "USD", date("2026-09-30"), 1.2)
      store.set_manual_fx_rate(0_i64, "XYZ", date("2026-01-01"), 4.5)
      r = s.rate("USD", date("2026-10-01"))
      r.should eq Domain::FXRate.new("USD", date("2026-09-30"), 1.2, Domain::FX_SOURCE_MANUAL)
      s.rate("XYZ", date("2026-06-01")).rate.should eq 4.5
      fake.total.should eq 0
      # Before the manual rate, the ECB rate applies.
      r = s.rate("USD", date("2026-09-29"))
      r.rate.should eq 1.1251
      r.source.should eq Domain::FX_SOURCE_ECB
    end
  end

  it "reports fetch errors and waits for the cooldown before trying again" do
    with_service do |s, fake|
      fake.network_error = true
      expect_raises(FX::FetchError, /nicht geladen werden/) { s.rate("USD", date("2026-10-01")) }
      # Shortly afterwards: no new attempt.
      expect_raises(FX::FetchError) { s.rate("USD", date("2026-10-01")) }
      fake.total.should eq 1
      # After the cooldown again, now with an HTTP error.
      s.clock = -> { at("2026-10-02 12:05") }
      fake.network_error = false
      fake.status = 500
      expect_raises(FX::FetchError, /500/) { s.rate("USD", date("2026-10-01")) }
      # Broken file.
      s.clock = -> { at("2026-10-02 12:10") }
      fake.status = nil
      fake.files[FX::FILE_DAILY] = "<broken".to_slice
      expect_raises(FX::FetchError) { s.rate("USD", date("2026-10-01")) }
      fake.count(FX::FILE_DAILY).should eq 3
    end
  end

  it "loads a file only once for concurrent callers" do
    with_service do |s, fake|
      fake.block
      results = Channel(Domain::FXRate | Exception).new(5)
      5.times do
        spawn do
          results.send(begin
            s.rate("USD", date("2026-10-01"))
          rescue ex
            ex
          end)
        end
      end
      wait_for { fake.total > 0 }
      sleep 20.milliseconds # let the others wait
      fake.release
      5.times do
        r = results.receive
        r.should be_a(Domain::FXRate)
        r.as(Domain::FXRate).rate.should eq 1.1298
      end
      fake.total.should eq 1
    end
  end

  it "refreshes with the 90-day file on an empty cache, otherwise with the daily file" do
    with_service do |s, fake|
      s.refresh.should eq date("2026-10-01")
      fake.count(FX::FILE_90D).should eq 1
      # Current cache: the daily file, even right after the last fetch.
      s.refresh
      fake.count(FX::FILE_DAILY).should eq 1
      s.refresh
      fake.count(FX::FILE_DAILY).should eq 2
    end
  end

  it "returns from run only once no download is running" do
    with_service do |s, fake|
      fake.block
      stopper = Zipfelkasse::Stopper.new
      done = Channel(Nil).new
      spawn do
        s.run(stopper)
        done.close
      end
      # Empty cache: run loads immediately.
      wait_for { fake.total > 0 }
      stopper.stop
      select
      when done.receive?
      when timeout(2.seconds)
        fail "run hangs"
      end
      s.@loads.each_value(&.finished?.should(be_true))
    end
  end
end

describe "FX calendar" do
  it "knows Easter, TARGET business days and the next publication" do
    {2024 => "2024-03-31", 2025 => "2025-04-20", 2026 => "2026-04-05", 2027 => "2027-03-28"}.each do |y, want|
      FX.easter_sunday(y).should eq date(want)
    end
    {
      "2026-10-02" => true, "2026-10-03" => false, "2026-10-04" => false, "2026-04-03" => false,
      "2026-04-06" => false, "2026-05-01" => false, "2026-12-24" => true, "2026-12-25" => false,
      "2027-01-01" => false, "2026-10-05" => true,
    }.each do |d, want|
      FX.business_day?(date(d)).should eq(want), "business_day?(#{d})"
    end
    FX.last_business_day(date("2026-04-06")).should eq date("2026-04-02")
    {
      "2026-10-02 12:00" => "2026-10-02 16:30",
      "2026-10-02 16:30" => "2026-10-05 16:30",
      "2026-10-02 17:00" => "2026-10-05 16:30",
      "2026-12-24 17:00" => "2026-12-28 16:30",
      "2026-03-28 10:00" => "2026-03-30 16:30", # DST change on 29 March
    }.each do |now, want|
      FX.next_publish(at(now)).to_s("%Y-%m-%d %H:%M").should eq want
    end
    FX.next_publish(at("2026-03-28 10:00")).should eq Time.utc(2026, 3, 30, 14, 30)
  end
end

describe "FX file parsing" do
  it "parses the XML and CSV files and rejects broken ones" do
    rates = FX.parse_xml(File.read("#{FXSpec::FakeECB::TESTDATA}/#{FX::FILE_90D}"))
    rates.size.should eq 18
    res = FX::LoadResult.new(rates)
    res.from.should eq date("2026-07-06")
    res.to.should eq date("2026-10-01")
    res.currencies.size.should eq 3

    rates = File.open("#{FXSpec::FakeECB::TESTDATA}/eurofxref-hist.csv") { |f| FX.parse_hist_csv(f) }
    # N/A and empty columns are skipped.
    n = rates.map(&.currency).tally
    n.should eq({"USD" => 6, "JPY" => 6, "BGN" => 4, "CYP" => 1, "GBP" => 6, "RUB" => 2})

    expect_raises(Exception, /csv: unexpected header/) { FX.parse_hist_csv(IO::Memory.new("Foo,USD\n")) }
    expect_raises(Exception, /zip: /) { FX.parse_hist_zip("not a zip".to_slice) }
    {"1.1298" => 1.1298, " 2 " => 2.0, "N/A" => nil, "" => nil, "-1" => nil, "NaN" => nil, "Inf" => nil}.each do |s, want|
      FX.parse_ecb_rate(s).should eq(want), "parse_ecb_rate(#{s.inspect})"
    end
  end
end

private def with_fx_server(&)
  fake = FXSpec::FakeECB.new
  begin
    with_server(fx_config(fake)) do |srv|
      service = srv.d.fx.as(FX::Service)
      service.clock = -> { at("2026-10-02 12:00") }
      yield srv, fake, who_cookie(must_participant(srv.store, "Anna"))
    end
  ensure
    fake.close
  end
end

describe "FX handlers" do
  it "answers GET /api/kurs" do
    with_fx_server do |srv, _, me|
      {
        {"/api/kurs?waehrung=USD&datum=2026-10-01", 200, %({"currency":"USD","date":"2026-10-01","rate":1.1298,"source":"ezb"}\n)},
        {"/api/kurs?waehrung=usd&datum=01.10.2026", 200, %("rate":1.1298)},
        {"/api/kurs?waehrung=USD", 200, %("date":"2026-10-01")},
        {"/api/kurs?waehrung=EUR", 200, %({"currency":"EUR","date":"2026-10-02","rate":1,"source":"fest"}\n)},
        {"/api/kurs", 400, %("error":"Bitte eine Währung angeben.")},
        {"/api/kurs?waehrung=US1", 400, %({"error":"Ungültige Währung „US1“."})},
        {"/api/kurs?waehrung=USD&datum=gestern", 400, %("error")},
        {"/api/kurs?waehrung=XYZ&datum=2026-10-01", 422, "keinen EZB-Kurs"},
      }.each do |path, status, body|
        res = srv.get(path, me)
        {path, res.status_code}.should eq({path, status})
        res.body.should contain(body)
        res.headers["Content-Type"].should start_with("application/json")
      end
    end
  end

  it "answers 502 when the ECB is unreachable" do
    with_fx_server do |srv, fake, me|
      fake.network_error = true
      res = srv.get("/api/kurs?waehrung=USD", me)
      res.status_code.should eq 502
      res.body.should contain("nicht geladen werden")
    end
  end

  it "shows, saves and deletes manual rates and refreshes the ECB rates" do
    with_fx_server do |srv, fake, me|
      store = srv.store
      res = srv.get("/einstellungen/kurse", me)
      res.status_code.should eq 200
      res.body.should contain("Manuelle Kurse")
      res.body.should contain("Noch keine EZB-Kurse")
      res.body.should contain("Vorrang")

      res = srv.post_form("/einstellungen/kurse", {"waehrung" => "thb", "datum" => "2026-09-01", "kurs" => "38,02"}, me)
      res.status_code.should eq 303
      res.headers["Location"].should eq "/einstellungen/kurse"
      store.lookup_fx_rate("THB", Domain::FX_SOURCE_MANUAL, date("2026-10-01")).rate.should eq 38.02
      res = srv.post_form("/einstellungen/kurse", {"waehrung" => "IDR", "datum" => "02.09.2026", "kurs" => "20.274,71"}, me)
      res.status_code.should eq 303
      store.lookup_fx_rate("IDR", Domain::FX_SOURCE_MANUAL, date("2026-10-01")).rate.should eq 20274.71
      # Thousands separators as for amounts: "17.000" = 17000, also English
      # "17,000.5"; after a leading zero the dot is a decimal point.
      {"0.856" => 0.856, "17.000" => 17000.0, "17,000.5" => 17000.5}.each do |input, want|
        res = srv.post_form("/einstellungen/kurse", {"waehrung" => "VND", "datum" => "2026-09-03", "kurs" => input}, me)
        res.status_code.should eq 303
        store.lookup_fx_rate("VND", Domain::FX_SOURCE_MANUAL, date("2026-10-01")).rate.should eq want
      end

      [
        {"waehrung" => "TH", "datum" => "2026-09-01", "kurs" => "38"},
        {"waehrung" => "THB", "datum" => "", "kurs" => "38"},
        {"waehrung" => "THB", "datum" => "2026-09-01", "kurs" => "0"},
        {"waehrung" => "THB", "datum" => "2026-09-01", "kurs" => "abc"},
      ].each do |bad|
        res = srv.post_form("/einstellungen/kurse", bad, me)
        res.status_code.should eq 422
        res.body.should contain("alert-destructive")
      end

      srv.get("/einstellungen/kurse", me).body.should contain("38,02 THB")
      last_activity(store).should eq "Manueller Kurs für VND ab 03.09.2026 gespeichert: 1 € = 17000,5 VND"

      res = srv.post_form("/einstellungen/kurse/loeschen", {"waehrung" => "THB", "datum" => "2026-09-01"}, me)
      res.status_code.should eq 303
      last_activity(store).should eq "Manueller Kurs für THB ab 01.09.2026 gelöscht"
      res = srv.post_form("/einstellungen/kurse/loeschen", {"waehrung" => "THB", "datum" => "2026-09-01"}, me)
      res.status_code.should eq 404

      res = srv.post_form("/einstellungen/kurse/aktualisieren", {} of String => String, me)
      res.status_code.should eq 303
      fake.count(FX::FILE_90D).should eq 1
      body = srv.get("/einstellungen/kurse", me).body
      body.should contain("1,1298 USD")
      body.should contain("bis 01.10.2026")

      fake.network_error = true
      res = srv.post_form("/einstellungen/kurse/aktualisieren", {} of String => String, me)
      res.status_code.should eq 502
      res.body.should contain("nicht geladen werden")
    end
  end
end
