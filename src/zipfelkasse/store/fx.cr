module Zipfelkasse
  # Exchange rates live in fx_rates in ECB format (foreign currency per 1 EUR),
  # at most one per (currency, source, date): manual and ECB rates of the same
  # day sit side by side. The lookup in the fx service prefers manual rates, so
  # deleting one brings back the ECB rate of that day.
  class Store
    UPSERT_FX_RATE_SQL = "INSERT INTO fx_rates (date, currency, rate, source) VALUES (?, ?, ?, ?) " \
                         "ON CONFLICT (currency, source, date) DO UPDATE SET rate = excluded.rate"

    # The most recent rate of source with not_before <= date of rate <= date;
    # raises NotFound.
    def lookup_fx_rate(currency : String, source : String, date : Time, not_before : Time? = nil) : Domain::FXRate
      q = "SELECT date, rate FROM fx_rates WHERE currency = ? AND source = ? AND date <= ?"
      args = [currency, source, Store.format_date(date)] of DB::Any
      if not_before
        q += " AND date >= ?"
        args << Store.format_date(not_before)
      end
      q += " ORDER BY date DESC LIMIT 1"
      @db.query(q, args: args) do |rs|
        rs.each do
          d, rate = rs.read(String), rs.read(Float64)
          return Domain::FXRate.new(currency, Store.parse_date(d), rate, source)
        end
      end
      raise NotFound.new
    end

    # Invalid rows are skipped silently; manual rates are left untouched.
    def save_ecb_rates(rates : Array(Domain::FXRate)) : Nil
      transaction do |tx|
        rates.each do |r|
          next unless r.rate > 0 && !r.rate.infinite? && Domain.valid_currency_code?(r.currency)
          tx.exec(UPSERT_FX_RATE_SQL, Store.format_date(r.date), r.currency, r.rate, Domain::FX_SOURCE_ECB)
        end
      end
    end

    # Valid from date on; replaces a manual rate of the same day.
    def set_manual_fx_rate(actor_id : Int64, currency : String, date : Time?, rate : Float64) : Nil
      currency = currency.strip.upcase
      raise Domain::ValidationError.new("Für Euro braucht es keinen Kurs.") if currency == "EUR"
      unless Domain.valid_currency_code?(currency)
        raise Domain::ValidationError.new("Bitte einen dreistelligen Währungscode angeben (z. B. USD).")
      end
      raise Domain::ValidationError.new("Bitte ein Datum angeben.") unless date
      unless rate > 0 && !rate.infinite? && rate <= 1e9
        raise Domain::ValidationError.new("Der Kurs muss größer als 0 sein.")
      end
      date = Domain.date_of(date)
      transaction do |tx|
        tx.exec(UPSERT_FX_RATE_SQL, Store.format_date(date), currency, rate, Domain::FX_SOURCE_MANUAL)
        log_settings(tx, actor_id, "Manueller Kurs für #{currency} ab #{Domain.format_date(date)} gespeichert: " \
                                   "1 € = #{Domain.format_rate(rate)} #{currency}")
      end
    end

    # Raises NotFound if there is no manual rate; an ECB rate of that day stays.
    def delete_manual_fx_rate(actor_id : Int64, currency : String, date : Time) : Nil
      currency = currency.strip.upcase
      transaction do |tx|
        Store.check_affected(tx.exec("DELETE FROM fx_rates WHERE currency = ? AND date = ? AND source = 'manuell'",
          currency, Store.format_date(date)))
        log_settings(tx, actor_id, "Manueller Kurs für #{currency} ab #{Domain.format_date(date)} gelöscht")
      end
    end

    def list_manual_fx_rates : Array(Domain::FXRate)
      query_fx_rates("SELECT currency, date, rate, source FROM fx_rates WHERE source = 'manuell' ORDER BY currency, date DESC")
    end

    # The ECB rates of the most recent cached day; empty if nothing is cached.
    def latest_ecb_rates : Array(Domain::FXRate)
      query_fx_rates("SELECT currency, date, rate, source FROM fx_rates " \
                     "WHERE source = 'ezb' AND date = (SELECT max(date) FROM fx_rates WHERE source = 'ezb') ORDER BY currency")
    end

    record FXCacheStats, count : Int32, currencies : Int32, from : Time?, to : Time?

    def ecb_cache_stats : FXCacheStats
      count, currencies, from, to = @db.query_one(
        "SELECT count(*), count(DISTINCT currency), min(date), max(date) FROM fx_rates WHERE source = 'ezb'",
        as: {Int64, Int64, String?, String?})
      FXCacheStats.new(count.to_i32, currencies.to_i32, Store.parse_date?(from), Store.parse_date?(to))
    end

    protected def self.parse_date?(s : String?) : Time?
      Store.parse_date(s) if s
    rescue
      nil
    end

    # Currencies with any rate, of either source.
    def list_fx_currencies : Array(String)
      @db.query_all("SELECT DISTINCT currency FROM fx_rates ORDER BY currency", as: String)
    end

    def has_ecb_currency?(currency : String) : Bool
      @db.scalar("SELECT count(*) FROM (SELECT 1 FROM fx_rates WHERE currency = ? AND source = 'ezb' LIMIT 1)",
        currency).as(Int64) > 0
    end

    # A rate used in an expense: fx.date is the expense date, fx.source its fx_source.
    record UsedFXRate, fx : Domain::FXRate, expense_id : Int64, title : String do
      delegate currency, date, rate, source, to: fx
    end

    # The rates of the most recent non-deleted foreign-currency expenses.
    def recent_used_fx_rates(limit : Int32) : Array(UsedFXRate)
      out = [] of UsedFXRate
      @db.query("SELECT id, title, original_currency, date, fx_rate, fx_source FROM expenses " \
                "WHERE deleted_at IS NULL AND original_currency <> 'EUR' ORDER BY date DESC, id DESC LIMIT ?", limit) do |rs|
        rs.each do
          id, title, currency = rs.read(Int64), rs.read(String), rs.read(String)
          date, rate, source = Store.parse_date(rs.read(String)), rs.read(Float64), rs.read(String)
          out << UsedFXRate.new(Domain::FXRate.new(currency, date, rate, source), id, title)
        end
      end
      out
    end

    private def query_fx_rates(q : String) : Array(Domain::FXRate)
      out = [] of Domain::FXRate
      @db.query(q) do |rs|
        rs.each do
          out << Domain::FXRate.new(rs.read(String), Store.parse_date(rs.read(String)), rs.read(Float64), rs.read(String))
        end
      end
      out
    end
  end
end
