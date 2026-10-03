require "../spec_helper"

private BERLIN = Time::Location.load("Europe/Berlin")

private module Fixture
  class_property! ecb : FakeECB
end

private def ecb : FakeECB
  Fixture.ecb
end

private def at(text : String) : Time
  Time.parse(text, "%Y-%m-%d %H:%M", BERLIN)
end

private def ecb_rate(currency : String, day : String) : Float64
  ecb.rate(currency, date(day)).to_f
end

private def fx_config(ecb : FakeECB, now : String) : Config
  config = Config.new
  config.location = BERLIN
  config.ecb_base_url = ecb.base_url
  config.now = at(now)
  config
end

# The service with the clock at Friday, 2026-10-02 12:00 in Berlin; the fake
# ECB has published up to Thursday.
private def new_service(store : Store, ecb : FakeECB, now = "2026-10-02 12:00") : FX::Service
  FX::Service.new(Web::Deps.new(fx_config(ecb, now), store))
end

private def service : FX::Service
  new_service(store, ecb)
end

describe FX::Service do
  use_store

  around_each do |example|
    Fixture.ecb = FakeECB.new(Time.utc(2026, 10, 1))
    begin
      example.run
    ensure
      ecb.close
    end
  end

  describe "#rate" do
    it "answers 1 for euros without loading anything" do
      service.rate(" eur ", date("2026-09-01"))
        .should eq Domain::FXRate.new("EUR", date("2026-09-01"), 1.0, Domain::FXSource::Fixed)
      ecb.requests.should be_empty
    end

    {"" => "Bitte eine Währung angeben.", "US" => "Ungültige Währung „US“.", "US1" => "Ungültige Währung „US1“.",
     "EURO" => "Ungültige Währung „EURO“."}.each do |currency, message|
      it "rejects the currency #{currency.inspect} without loading anything" do
        expect_invalid(message) { service.rate(currency, date("2026-09-01")) }
        ecb.requests.should be_empty
      end
    end

    it "loads the 90-day file into an empty cache and then answers from the cache until the next publication" do
      config = fx_config(ecb, "2026-10-02 12:00")
      service = FX::Service.new(Web::Deps.new(config, store))

      service.rate("usd", date("2026-10-01"))
        .should eq Domain::FXRate.new("USD", date("2026-10-01"), ecb_rate("USD", "2026-10-01"), Domain::FXSource::Ecb)
      ecb.requests.should eq [FX::RECENT]
      ecb.agents.first.should start_with "zipfelkasse/"

      rate = service.rate("JPY", date("2026-09-27"))
      {rate.date, rate.rate}.should eq({date("2026-09-25"), ecb_rate("JPY", "2026-09-25")})
      service.rate("USD", date("2026-10-02")).date.should eq date("2026-10-01")
      service.rate("GBP", date("2026-12-24")).rate.should eq ecb_rate("GBP", "2026-10-01")
      ecb.requests.size.should eq 1

      config.now = at("2026-10-02 15:59")
      service.rate("USD", date("2026-10-02")).date.should eq date("2026-10-01")
      ecb.requests.size.should eq 1

      ecb.last_day = Time.utc(2026, 10, 2)
      config.now = at("2026-10-02 16:00")
      service.rate("USD", date("2026-10-02")).date.should eq date("2026-10-02")
      ecb.requests.should eq [FX::RECENT, FX::RECENT]
    end

    it "waits for the next weekday's publication after the Friday rates, also after a restart" do
      ecb.last_day = Time.utc(2026, 10, 2)
      config = fx_config(ecb, "2026-10-02 17:00")
      service = FX::Service.new(Web::Deps.new(config, store))
      service.rate("USD", date("2026-10-02")).date.should eq date("2026-10-02")

      {"2026-10-03 10:00", "2026-10-04 23:00", "2026-10-05 15:59"}.each do |now|
        config.now = at(now)
        service.rate("USD", date(now[0, 10])).date.should eq date("2026-10-02")
        new_service(store, ecb, now).rate("USD", date(now[0, 10])).date.should eq date("2026-10-02")
      end
      ecb.requests.size.should eq 1

      ecb.last_day = Time.utc(2026, 10, 5)
      config.now = at("2026-10-05 16:00")
      service.rate("USD", date("2026-10-05")).date.should eq date("2026-10-05")
      ecb.requests.size.should eq 2
    end

    it "shares one download between concurrent requests" do
      service = service()
      ecb.block
      done = Channel(Float64).new
      2.times { spawn { done.send service.rate("USD", date("2026-10-01")).rate } }

      eventually { ecb.requests.size > 0 }
      sleep 50.milliseconds
      ecb.release
      2.times { done.receive.should eq ecb_rate("USD", "2026-10-01") }
      ecb.requests.should eq [FX::RECENT]
    end

    it "loads the full history for a date before the 90 days, once" do
      service = service()

      service.rate("USD", date("2024-01-03")).rate.should eq ecb_rate("USD", "2024-01-03")
      rate = service.rate("GBP", date("2024-03-02"))
      {rate.date, rate.rate}.should eq({date("2024-03-01"), ecb_rate("GBP", "2024-03-01")})
      service.rate("CHF", date("2026-09-30")).rate.should eq ecb_rate("CHF", "2026-09-30")
      ecb.requests.should eq [FX::HISTORY]
    end

    it "explains whether the ECB does not know the currency or only the date" do
      service = service()

      expect_invalid("Für USD gibt es um den 20.11.2023 keinen EZB-Kurs – bitte Kurs von Hand eintragen.") do
        service.rate("USD", date("2023-11-20"))
      end
      expect_invalid("Für RUB gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.") do
        service.rate("RUB", date("2024-01-03"))
      end
      ecb.requests.should eq [FX::HISTORY]
    end

    it "answers from the cache after a restart" do
      service.rate("USD", date("2024-01-03"))
      other = FakeECB.new
      begin
        restarted = new_service(store, other)
        restarted.rate("USD", date("2024-01-02")).rate.should eq ecb_rate("USD", "2024-01-02")
        restarted.rate("USD", date("2026-10-01")).rate.should eq ecb_rate("USD", "2026-10-01")
        other.requests.should be_empty
      ensure
        other.close
      end
    end

    it "does not load again shortly after a fetch for an unknown currency" do
      service = service()
      message = "Für XYZ gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen."

      expect_invalid(message) { service.rate("XYZ", date("2026-10-01")) }
      expect_invalid(message) { service.rate("XYZ", date("2026-10-02")) }
      ecb.requests.size.should eq 1
    end

    it "prefers a manual rate from its start date on and loads nothing for it" do
      store.set_manual_fx_rate(nil, "USD", date("2026-09-30"), 1.2)
      store.set_manual_fx_rate(nil, "XYZ", date("2026-01-01"), 4.5)
      service = service()

      service.rate("USD", date("2026-10-01"))
        .should eq Domain::FXRate.new("USD", date("2026-09-30"), 1.2, Domain::FXSource::Manual)
      service.rate("XYZ", date("2026-06-01")).rate.should eq 4.5
      ecb.requests.should be_empty

      before = service.rate("USD", date("2026-09-29"))
      {before.rate, before.source}.should eq({ecb_rate("USD", "2026-09-29"), Domain::FXSource::Ecb})
    end

    it "repeats a failed download's error until the cooldown is over" do
      service = service()
      ecb.failure = :network

      expect_raises(FX::FetchError, /nicht geladen werden/) { service.rate("USD", date("2026-10-01")) }
      ecb.failure = nil
      expect_raises(FX::FetchError) { service.rate("USD", date("2026-10-01")) }
      ecb.requests.size.should eq 1
    end

    {500 => /HTTP status 500/, :broken => /xml: /, :empty => /file contains no rates/}.each do |failure, reason|
      it "reports #{failure} as a failed download" do
        ecb.failure = failure
        expect_raises(FX::FetchError, reason) { service.rate("USD", date("2026-10-01")) }
      end
    end

    it "falls back to a cached rate when the download fails" do
      service.rate("USD", date("2026-09-30"))
      ecb.failure = 500

      new_service(store, ecb, "2026-10-02 17:00").rate("USD", date("2026-10-02")).date.should eq date("2026-10-01")
      ecb.requests.should eq [FX::RECENT, FX::RECENT]
    end
  end

  describe "#refresh" do
    it "loads the 90-day file and returns the newest day" do
      service = service()

      service.refresh.should eq date("2026-10-01")
      service.refresh
      ecb.requests.should eq [FX::RECENT, FX::RECENT]
    end

    it "loads the full history when the cache is older than the 90-day file" do
      store.save_ecb_rates([Domain::FXRate.new("USD", date("2026-06-01"), 1.1, Domain::FXSource::Ecb)])

      service.refresh.should eq date("2026-10-01")
      ecb.requests.should eq [FX::HISTORY]
    end
  end

  describe "#run" do
    it "returns once the stopper fires, although a download hangs" do
      service = service()
      ecb.block
      stopper = Stopper.new
      stopped = Channel(Nil).new
      spawn do
        service.run(stopper)
        stopped.close
      end

      eventually { ecb.requests.size > 0 }
      stopper.stop
      select
      when stopped.receive?
      when timeout(2.seconds)
        fail "run keeps waiting for the download"
      end
    end

    it "keeps running when the cache cannot be read at startup" do
      service = service()
      store.db.exec("DROP TABLE fx_rates")
      stopper = Stopper.new
      stopped = Channel(Exception?).new
      spawn do
        service.run(stopper)
        stopped.send(nil)
      rescue ex
        stopped.send(ex)
      end

      select
      when ex = stopped.receive
        fail "run returned before the stopper fired: #{ex.inspect}"
      when timeout(100.milliseconds)
      end
      stopper.stop
      stopped.receive.should be_nil
      ecb.requests.should be_empty
    end
  end
end
