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

# The service with the clock at Friday, 2026-10-02 12:00 in Berlin: the rates
# of that day are not yet published, those of Thursday are.
private def new_service(store : Store, ecb : FakeECB) : FX::Service
  config = Config.new
  config.location = BERLIN
  config.ecb_base_url = ecb.base_url
  service = FX::Service.new(Web::Deps.new(config, store))
  service.clock = -> { at("2026-10-02 12:00") }
  service
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

    it "loads the daily file for yesterday and then answers from the cache" do
      service = service()

      service.rate("usd", date("2026-10-01"))
        .should eq Domain::FXRate.new("USD", date("2026-10-01"), ecb_rate("USD", "2026-10-01"), Domain::FXSource::Ecb)
      ecb.requests.should eq [FX::FILE_DAILY]
      ecb.agents.first.should start_with "zipfelkasse/"

      service.rate("USD", date("2026-10-02")).date.should eq date("2026-10-01")
      service.rate("GBP", date("2026-12-24")).rate.should eq ecb_rate("GBP", "2026-10-01")
      ecb.requests.size.should eq 1
    end

    it "loads the 90-day file for older dates and takes the Friday before a Sunday" do
      service = service()

      rate = service.rate("JPY", date("2026-09-27"))
      {rate.date, rate.rate}.should eq({date("2026-09-25"), ecb_rate("JPY", "2026-09-25")})
      service.rate("USD", date("2026-09-29")).rate.should eq ecb_rate("USD", "2026-09-29")
      ecb.requests.should eq [FX::FILE_90D]
    end

    it "escalates from the daily file to the 90-day file when the daily file lacks the date" do
      service = service()
      service.clock = -> { at("2026-10-02 17:00") }
      ecb.last_day = Time.utc(2026, 10, 2)

      service.rate("USD", date("2026-10-01")).rate.should eq ecb_rate("USD", "2026-10-01")
      service.rate("USD", date("2026-10-02")).rate.should eq ecb_rate("USD", "2026-10-02")
      ecb.requests.should eq [FX::FILE_DAILY, FX::FILE_90D]
    end

    it "loads the complete history only once and answers from the cache afterwards" do
      service = service()

      service.rate("USD", date("2024-01-03")).rate.should eq ecb_rate("USD", "2024-01-03")
      rate = service.rate("GBP", date("2024-03-02"))
      {rate.date, rate.rate}.should eq({date("2024-03-01"), ecb_rate("GBP", "2024-03-01")})
      ecb.requests.should eq [FX::FILE_HIST]
    end

    it "explains whether the ECB does not know the currency or only the date" do
      service = service()

      expect_invalid("Für USD gibt es um den 20.11.2023 keinen EZB-Kurs – bitte Kurs von Hand eintragen.") do
        service.rate("USD", date("2023-11-20"))
      end
      expect_invalid("Für RUB gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.") do
        service.rate("RUB", date("2024-01-03"))
      end
      ecb.requests.should eq [FX::FILE_HIST]
    end

    it "does not load the history again after a restart" do
      service.rate("USD", date("2024-01-03"))
      other = FakeECB.new
      begin
        restarted = new_service(store, other)
        restarted.rate("USD", date("2024-01-02")).rate.should eq ecb_rate("USD", "2024-01-02")
        expect_raises(Domain::ValidationError, "keinen EZB-Kurs") { restarted.rate("JPY", date("2023-11-01")) }
        other.requests.should be_empty
      ensure
        other.close
      end
    end

    it "does not load again shortly after a fetch for an unknown currency" do
      service = service()
      message = "Für XYZ gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen."

      expect_invalid(message) { service.rate("XYZ", date("2026-10-01")) }
      expect_invalid(message) { service.rate("XYZ", date("2026-10-01")) }
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

    it "waits for the cooldown before trying again after an error" do
      service = service()
      ecb.failure = :network

      expect_raises(FX::FetchError, /nicht geladen werden/) { service.rate("USD", date("2026-10-01")) }
      expect_raises(FX::FetchError) { service.rate("USD", date("2026-10-01")) }
      ecb.requests.size.should eq 1

      service.clock = -> { at("2026-10-02 12:05") }
      ecb.failure = 500
      expect_raises(FX::FetchError, /500/) { service.rate("USD", date("2026-10-01")) }

      service.clock = -> { at("2026-10-02 12:10") }
      ecb.failure = :broken
      expect_raises(FX::FetchError) { service.rate("USD", date("2026-10-01")) }
      ecb.count(FX::FILE_DAILY).should eq 3
    end

    it "loads a file only once for concurrent callers" do
      service = service()
      ecb.block
      results = Channel(Domain::FXRate | Exception).new(5)
      5.times do
        spawn do
          results.send(begin
            service.rate("USD", date("2026-10-01"))
          rescue ex
            ex
          end)
        end
      end
      eventually { ecb.requests.size > 0 }
      sleep 20.milliseconds
      ecb.release

      5.times do
        result = results.receive
        result.should be_a(Domain::FXRate)
        result.as(Domain::FXRate).rate.should eq ecb_rate("USD", "2026-10-01")
      end
      ecb.requests.size.should eq 1
    end
  end

  describe "#refresh" do
    it "loads the 90-day file into an empty cache and the daily file into a current one" do
      service = service()

      service.refresh.should eq date("2026-10-01")
      service.refresh
      service.refresh
      ecb.requests.should eq [FX::FILE_90D, FX::FILE_DAILY, FX::FILE_DAILY]
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
  end
end
