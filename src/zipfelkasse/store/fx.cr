# Rates are units of the currency per 1 EUR; manual and ECB rates of a day sit side by side.
struct Zipfelkasse::Domain::FXRate
  include DB::Serializable

  @[DB::Field(converter: Zipfelkasse::Store::DateText)]
  @date : Time
  @[DB::Field(converter: Zipfelkasse::Store::FXSourceText)]
  @source : Zipfelkasse::Domain::FXSource
end

module Zipfelkasse
  class Store
    UPSERT_FX_RATE_SQL = "INSERT INTO fx_rates (date, currency, rate, source) VALUES (?, ?, ?, ?) " \
                         "ON CONFLICT (currency, source, date) DO UPDATE SET rate = excluded.rate"

    FX_RATE_COLS = "currency, date, rate, source"

    def lookup_fx_rate?(currency : String, source : Domain::FXSource, date : Time, not_before : Time? = nil) : Domain::FXRate?
      q = "SELECT #{FX_RATE_COLS} FROM fx_rates WHERE currency = ? AND source = ? AND date <= ?"
      args = [currency, source.key, Store.format_date(date)] of DB::Any
      if not_before
        q += " AND date >= ?"
        args << Store.format_date(not_before)
      end
      @db.query_one?(q + " ORDER BY date DESC LIMIT 1", args: args, as: Domain::FXRate)
    end

    def save_ecb_rates(rates : Array(Domain::FXRate)) : Nil
      transaction do |tx|
        rates.each do |r|
          next unless r.rate > 0 && !r.rate.infinite? && Domain.valid_currency_code?(r.currency)
          tx.exec(UPSERT_FX_RATE_SQL, Store.format_date(r.date), r.currency, r.rate, Domain::FXSource::Ecb.key)
        end
      end
    end

    def set_manual_fx_rate(actor_id : Int64?, currency : String, date : Time?, rate : Float64) : Nil
      currency = currency.strip.upcase
      raise Domain::ValidationError.new("Für Euro braucht es keinen Kurs.") if currency == "EUR"
      unless Domain.valid_currency_code?(currency)
        raise Domain::ValidationError.new("Bitte einen dreistelligen Währungscode angeben (z. B. USD).")
      end
      date = Domain.date_of(date || raise Domain::ValidationError.new("Bitte ein Datum angeben."))
      unless rate > 0 && !rate.infinite? && rate <= 1e9
        raise Domain::ValidationError.new("Der Kurs muss größer als 0 sein.")
      end
      transaction do |tx|
        tx.exec(UPSERT_FX_RATE_SQL, Store.format_date(date), currency, rate, Domain::FXSource::Manual.key)
        log_settings(tx, actor_id, "Manueller Kurs für #{currency} ab #{Domain.format_date(date)} gespeichert: " \
                                   "1 € = #{Domain.format_rate(rate)} #{currency}")
      end
    end

    def delete_manual_fx_rate(actor_id : Int64?, currency : String, date : Time) : Nil
      currency = currency.strip.upcase
      transaction do |tx|
        Store.check_affected(tx.exec("DELETE FROM fx_rates WHERE currency = ? AND date = ? AND source = ?",
          currency, Store.format_date(date), Domain::FXSource::Manual.key))
        log_settings(tx, actor_id, "Manueller Kurs für #{currency} ab #{Domain.format_date(date)} gelöscht")
      end
    end

    def list_manual_fx_rates : Array(Domain::FXRate)
      @db.query_all("SELECT #{FX_RATE_COLS} FROM fx_rates WHERE source = ? ORDER BY currency, date DESC",
        Domain::FXSource::Manual.key, as: Domain::FXRate)
    end

    def latest_ecb_rates : Array(Domain::FXRate)
      @db.query_all("SELECT #{FX_RATE_COLS} FROM fx_rates WHERE source = ? " \
                    "AND date = (SELECT max(date) FROM fx_rates WHERE source = ?) ORDER BY currency",
        Domain::FXSource::Ecb.key, Domain::FXSource::Ecb.key, as: Domain::FXRate)
    end

    record FXCacheStats, count : Int32, currencies : Int32, from : Time?, to : Time? do
      include DB::Serializable

      @[DB::Field(converter: Zipfelkasse::Store::DateText)]
      @from : Time?
      @[DB::Field(converter: Zipfelkasse::Store::DateText)]
      @to : Time?
    end

    def ecb_cache_stats : FXCacheStats
      @db.query_one("SELECT count(*) AS count, count(DISTINCT currency) AS currencies, min(date) AS \"from\", " \
                    "max(date) AS \"to\" FROM fx_rates WHERE source = ?", Domain::FXSource::Ecb.key, as: FXCacheStats)
    end

    def ecb_date_range : Range(Time, Time)?
      from, to = @db.query_one("SELECT min(date), max(date) FROM fx_rates WHERE source = ?", Domain::FXSource::Ecb.key,
        as: {String?, String?})
      Store.parse_date(from)..Store.parse_date(to) if from && to
    end

    def list_fx_currencies : Array(String)
      @db.query_all("SELECT DISTINCT currency FROM fx_rates ORDER BY currency", as: String)
    end

    def has_ecb_currency?(currency : String) : Bool
      @db.scalar("SELECT count(*) FROM (SELECT 1 FROM fx_rates WHERE currency = ? AND source = ? LIMIT 1)",
        currency, Domain::FXSource::Ecb.key).as(Int64) > 0
    end

    record UsedFXRate, expense_id : Int64, title : String, currency : String, date : Time, rate : Float64,
      source : Domain::FXSource do
      include DB::Serializable

      @[DB::Field(converter: Zipfelkasse::Store::DateText)]
      @date : Time
      @[DB::Field(converter: Zipfelkasse::Store::FXSourceText)]
      @source : Domain::FXSource
    end

    def recent_used_fx_rates(limit : Int32) : Array(UsedFXRate)
      @db.query_all("SELECT id AS expense_id, title, original_currency AS currency, date, fx_rate AS rate, " \
                    "fx_source AS source FROM expenses " \
                    "WHERE deleted_at IS NULL AND original_currency <> 'EUR' ORDER BY date DESC, id DESC LIMIT ?",
        limit, as: UsedFXRate)
    end
  end
end
