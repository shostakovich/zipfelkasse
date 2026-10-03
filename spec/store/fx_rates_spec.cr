require "../spec_helper"

private def rate(currency : String, d : String, r : Float64) : Domain::FXRate
  Domain::FXRate.new(currency, date(d), r, Domain::FXSource::Ecb)
end

describe "Store exchange rates" do
  use_store

  it "stores ECB and manual rates side by side" do
    store.save_ecb_rates([
      rate("USD", "2026-09-29", 1.10),
      rate("USD", "2026-09-30", 1.11),
      rate("GBP", "2026-09-30", 0.85),
      rate("bad", "2026-09-30", 1),
      rate("JPY", "2026-09-30", 0),
    ])
    store.lookup_fx_rate?("USD", Domain::FXSource::Ecb, date("2026-10-02"), date("2026-09-22"))
      .should eq Domain::FXRate.new("USD", date("2026-09-30"), 1.11, Domain::FXSource::Ecb)
    store.lookup_fx_rate?("USD", Domain::FXSource::Ecb, date("2026-10-20"), date("2026-10-10")).should be_nil
    store.lookup_fx_rate?("JPY", Domain::FXSource::Ecb, date("2026-10-02"), date("2026-09-01")).should be_nil

    # Neither overwrites the other.
    store.set_manual_fx_rate(nil, " usd ", date("2026-09-30"), 1.2)
    store.save_ecb_rates([rate("USD", "2026-09-30", 1.111)])
    r = store.lookup_fx_rate?("USD", Domain::FXSource::Manual, date("2026-12-01")).not_nil!
    {r.rate, r.source}.should eq({1.2, Domain::FXSource::Manual})
    store.lookup_fx_rate?("USD", Domain::FXSource::Ecb, date("2026-09-30"))
      .should eq Domain::FXRate.new("USD", date("2026-09-30"), 1.111, Domain::FXSource::Ecb)
    store.set_manual_fx_rate(nil, "USD", date("2026-09-30"), 1.21)
    store.lookup_fx_rate?("USD", Domain::FXSource::Manual, date("2026-09-30")).not_nil!.rate.should eq 1.21

    [{"EUR", 1.0}, {"US", 1.0}, {"USD", 0.0}, {"USD", -1.0}].each do |cur, bad|
      expect_raises(Domain::ValidationError) { store.set_manual_fx_rate(nil, cur, date("2026-09-30"), bad) }
    end
    expect_invalid("Bitte ein Datum angeben.") { store.set_manual_fx_rate(nil, "USD", nil, 1.2) }

    store.list_manual_fx_rates.map(&.currency).should eq ["USD"]
    latest = store.latest_ecb_rates
    latest.map(&.currency).should eq ["GBP", "USD"]
    latest[1].rate.should eq 1.111
    store.ecb_cache_stats.should eq Store::FXCacheStats.new(3, 2, date("2026-09-29"), date("2026-09-30"))
    store.list_fx_currencies.should eq ["GBP", "USD"]
    store.has_ecb_currency?("GBP").should be_true
    store.has_ecb_currency?("CHF").should be_false

    store.delete_manual_fx_rate(nil, "USD", date("2026-09-30"))
    expect_raises(Store::NotFound) { store.delete_manual_fx_rate(nil, "USD", date("2026-09-30")) }
    # The ECB rate of that day is still there.
    store.lookup_fx_rate?("USD", Domain::FXSource::Ecb, date("2026-09-30")).not_nil!.rate.should eq 1.111
    store.lookup_fx_rate?("USD", Domain::FXSource::Manual, date("2026-12-01")).should be_nil
    expect_raises(Store::NotFound) { store.delete_manual_fx_rate(nil, "GBP", date("2026-09-30")) }

    texts = store.list_activity.map(&.details.text)
    texts.should eq [
      "Manueller Kurs für USD ab 30.09.2026 gelöscht",
      "Manueller Kurs für USD ab 30.09.2026 gespeichert: 1 € = 1,21 USD",
      "Manueller Kurs für USD ab 30.09.2026 gespeichert: 1 € = 1,2 USD",
    ]
  end

  it "has empty cache stats without ECB rates" do
    store.ecb_cache_stats.should eq Store::FXCacheStats.new(0, 0, nil, nil)
    store.latest_ecb_rates.should be_empty
  end

  it "keeps a manual and an ECB rate of the same day and rejects other sources" do
    store.db.exec("INSERT INTO fx_rates (date, currency, rate, source) VALUES ('2026-09-30', 'USD', 1.1, 'ezb'), ('2026-09-30', 'USD', 1.2, 'manuell')")
    store.lookup_fx_rate?("USD", Domain::FXSource::Manual, date("2026-10-01")).not_nil!.rate.should eq 1.2
    store.lookup_fx_rate?("USD", Domain::FXSource::Ecb, date("2026-10-01")).not_nil!.rate.should eq 1.1
    expect_raises(SQLite3::Exception) do
      store.db.exec("INSERT INTO fx_rates (date, currency, rate, source) VALUES ('2026-08-01', 'USD', 1, 'foo')")
    end
  end
end

describe "Store exchange rates used by expenses" do
  use_household

  it "lists the rates of foreign-currency expenses only" do
    h = household
    input = h.equal("Hotel", 9009, "2026-09-01", h.anna, h.anna, h.ben)
    input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 10000_i64, 1.11, Domain::FXSource::Ecb
    h.create(input)
    h.create(h.equal("Brot", 300, "2026-09-02", h.anna, h.anna))
    used = store.recent_used_fx_rates(10)
    used.size.should eq 1
    {used[0].currency, used[0].rate, used[0].title, used[0].date}.should eq({"USD", 1.11, "Hotel", date("2026-09-01")})
  end
end
