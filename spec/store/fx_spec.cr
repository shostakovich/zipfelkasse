require "./expense_fixture"

private alias Store = Zipfelkasse::Store
private alias Domain = Zipfelkasse::Domain

private def rate(currency : String, d : String, r : Float64) : Domain::FXRate
  Domain::FXRate.new(currency, date(d), r, "")
end

describe "Store exchange rates" do
  it "stores ECB and manual rates side by side" do
    with_store do |s|
      s.save_ecb_rates([
        rate("USD", "2026-09-29", 1.10),
        rate("USD", "2026-09-30", 1.11),
        rate("GBP", "2026-09-30", 0.85),
        rate("bad", "2026-09-30", 1),
        rate("JPY", "2026-09-30", 0),
      ])
      r = s.lookup_fx_rate("USD", Domain::FX_SOURCE_ECB, date("2026-10-02"), date("2026-09-22"))
      r.should eq Domain::FXRate.new("USD", date("2026-09-30"), 1.11, "ezb")
      expect_raises(Store::NotFound) do
        s.lookup_fx_rate("USD", Domain::FX_SOURCE_ECB, date("2026-10-20"), date("2026-10-10"))
      end
      expect_raises(Store::NotFound) do
        s.lookup_fx_rate("JPY", Domain::FX_SOURCE_ECB, date("2026-10-02"), date("2026-09-01"))
      end

      # Neither overwrites the other.
      s.set_manual_fx_rate(0_i64, " usd ", date("2026-09-30"), 1.2)
      s.save_ecb_rates([rate("USD", "2026-09-30", 1.111)])
      r = s.lookup_fx_rate("USD", Domain::FX_SOURCE_MANUAL, date("2026-12-01"))
      {r.rate, r.source}.should eq({1.2, "manuell"})
      s.lookup_fx_rate("USD", Domain::FX_SOURCE_ECB, date("2026-09-30")).should eq Domain::FXRate.new("USD", date("2026-09-30"), 1.111, "ezb")
      s.set_manual_fx_rate(0_i64, "USD", date("2026-09-30"), 1.21)
      s.lookup_fx_rate("USD", Domain::FX_SOURCE_MANUAL, date("2026-09-30")).rate.should eq 1.21

      [{"EUR", 1.0}, {"US", 1.0}, {"USD", 0.0}, {"USD", -1.0}].each do |cur, bad|
        store_validation_error { s.set_manual_fx_rate(0_i64, cur, date("2026-09-30"), bad) }
      end
      store_validation_error { s.set_manual_fx_rate(0_i64, "USD", nil, 1.2) }.should eq "Bitte ein Datum angeben."

      s.list_manual_fx_rates.map(&.currency).should eq ["USD"]
      latest = s.latest_ecb_rates
      latest.map(&.currency).should eq ["GBP", "USD"]
      latest[1].rate.should eq 1.111
      s.ecb_cache_stats.should eq Store::FXCacheStats.new(3, 2, date("2026-09-29"), date("2026-09-30"))
      s.list_fx_currencies.should eq ["GBP", "USD"]
      s.has_ecb_currency?("GBP").should be_true
      s.has_ecb_currency?("CHF").should be_false

      s.delete_manual_fx_rate(0_i64, "USD", date("2026-09-30"))
      expect_raises(Store::NotFound) { s.delete_manual_fx_rate(0_i64, "USD", date("2026-09-30")) }
      # The ECB rate of that day is still there.
      s.lookup_fx_rate("USD", Domain::FX_SOURCE_ECB, date("2026-09-30")).rate.should eq 1.111
      expect_raises(Store::NotFound) { s.lookup_fx_rate("USD", Domain::FX_SOURCE_MANUAL, date("2026-12-01")) }
      expect_raises(Store::NotFound) { s.delete_manual_fx_rate(0_i64, "GBP", date("2026-09-30")) }

      texts = s.list_activity.map(&.details.text)
      texts.should eq [
        "Manueller Kurs für USD ab 30.09.2026 gelöscht",
        "Manueller Kurs für USD ab 30.09.2026 gespeichert: 1 € = 1,21 USD",
        "Manueller Kurs für USD ab 30.09.2026 gespeichert: 1 € = 1,2 USD",
      ]
    end
  end

  it "has empty cache stats without ECB rates" do
    with_store do |s|
      s.ecb_cache_stats.should eq Store::FXCacheStats.new(0, 0, nil, nil)
      s.latest_ecb_rates.should be_empty
    end
  end

  it "lists the rates of foreign-currency expenses only" do
    with_expense_fixture do |f|
      input = f.equal("Hotel", 9009, "2026-09-01", f.anna, f.anna, f.ben)
      input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 10000_i64, 1.11, "ezb"
      f.must_create(input)
      f.must_create(f.equal("Brot", 300, "2026-09-02", f.anna, f.anna))
      used = f.s.recent_used_fx_rates(10)
      used.size.should eq 1
      {used[0].currency, used[0].rate, used[0].title, used[0].date}.should eq({"USD", 1.11, "Hotel", date("2026-09-01")})
    end
  end

  it "keeps a manual and an ECB rate of the same day and rejects other sources" do
    with_store do |s|
      s.db.exec("INSERT INTO fx_rates (date, currency, rate, source) VALUES ('2026-09-30', 'USD', 1.1, 'ezb'), ('2026-09-30', 'USD', 1.2, 'manuell')")
      s.lookup_fx_rate("USD", Domain::FX_SOURCE_MANUAL, date("2026-10-01")).rate.should eq 1.2
      s.lookup_fx_rate("USD", Domain::FX_SOURCE_ECB, date("2026-10-01")).rate.should eq 1.1
      expect_raises(SQLite3::Exception) do
        s.db.exec("INSERT INTO fx_rates (date, currency, rate, source) VALUES ('2026-08-01', 'USD', 1, 'foo')")
      end
    end
  end
end
