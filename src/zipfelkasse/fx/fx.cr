# Rules for Service#rate: EUR is 1; the newest manual rate valid on the date
# wins; otherwise the ECB rate of the date or of the last business day before
# it. The ECB cache is complete from its first to its last day: a date outside
# loads the 90-day file, or the full history for older dates.
module Zipfelkasse::FX
  Log = ::Log.for(self)

  # How far an ECB rate may lie before the requested date (weekends, holidays).
  LOOKBACK_DAYS = 10
  # The 90-day file still reaches this far back.
  RECENT_DAYS = 85
  # After the ECB publishes, around 16:00 CET.
  REFRESH_HOUR = 17
  # A file is downloaded on demand at most this often.
  COOLDOWN = 15.minutes

  BERLIN = Time::Location.load("Europe/Berlin")

  class Service
    @http = OutboundHTTP.new(60.seconds, MAX_BODY_SIZE)
    @attempts = {} of String => {Time::Instant, FetchError?}

    def initialize(@d : Web::Deps)
      @base_url = d.config.ecb_base_url || DEFAULT_BASE_URL
    end

    def rate(currency : String, date : Time) : Domain::FXRate
      code = currency.strip.upcase
      date = Domain.date_of(date)
      return Domain::FXRate.new("EUR", date, 1.0, Domain::FXSource::Fixed) if code == "EUR"
      raise Domain::ValidationError.new("Bitte eine Währung angeben.") if code.empty?
      raise Domain::ValidationError.new("Ungültige Währung „#{currency}“.") unless Domain.valid_currency_code?(code)
      date = Math.min(date, @d.today)
      if manual = @d.store.lookup_fx_rate?(code, Domain::FXSource::Manual, date)
        return manual
      end
      error = load_missing(date)
      @d.store.lookup_fx_rate?(code, Domain::FXSource::Ecb, date, date.shift(days: -LOOKBACK_DAYS)) ||
        raise error || no_rate(code, date)
    end

    private def load_missing(date : Time) : FetchError?
      cache = @d.store.ecb_cache_stats
      from, to = cache.from, cache.to
      return if from && to && from <= date <= to
      file = file_reaching(to && date > to ? to : date)
      if (attempt = @attempts[file]?) && Time.instant - attempt[0] < COOLDOWN
        return attempt[1]
      end
      fetch(file)
      nil
    rescue ex : FetchError
      ex
    end

    private def file_reaching(day : Time) : String
      day >= @d.today.shift(days: -RECENT_DAYS) ? RECENT : HISTORY
    end

    private def no_rate(code : String, date : Time) : Domain::ValidationError
      if @d.store.has_ecb_currency?(code)
        Domain::ValidationError.new("Für #{code} gibt es um den #{Domain.format_date(date)} keinen EZB-Kurs – bitte Kurs von Hand eintragen.")
      else
        Domain::ValidationError.new("Für #{code} gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.")
      end
    end

    def refresh : Time
      fetch(file_reaching(@d.store.ecb_cache_stats.to || @d.today))
    end

    # Loads at startup when the cache lacks the last daily refresh, then daily
    # at REFRESH_HOUR. Returns when the stopper fires.
    def run(stopper : Stopper) : Nil
      spawn do
        stopper.done.receive?
        @http.stop
      end
      to = @d.store.ecb_cache_stats.to
      refresh_logged(stopper) if to.nil? || to < Domain.date_of(@d.now.in(BERLIN) - REFRESH_HOUR.hours)
      # Waits on the configured clock: a frozen test clock never reaches the next refresh.
      while stopper.wait(Domain.next_at_hour(@d.now.in(BERLIN), REFRESH_HOUR) - @d.now)
        refresh_logged(stopper)
      end
    end

    private def refresh_logged(stopper : Stopper) : Nil
      refresh
    rescue ex
      Log.error(exception: ex) { "refresh ECB rates" } unless stopper.stopped?
    end

    private def fetch(file : String) : Time
      rates = download(file)
      @attempts[file] = {Time.instant, nil}
      newest = rates.max_of(&.date)
      Log.info(&.emit("ECB rates loaded", file: file, rates: rates.size,
        from: Store.format_date(rates.min_of(&.date)), to: Store.format_date(newest)))
      newest
    rescue ex
      Log.warn(exception: ex, &.emit("loading ECB rates failed", file: file))
      error = ex.as?(FetchError) || FetchError.new(ex.message || ex.class.name)
      @attempts[file] = {Time.instant, error}
      raise error
    end

    private def download(file : String) : Array(Domain::FXRate)
      raise FetchError.new("shutting down") if @http.stopped?
      res = @http.request("GET", @base_url + file, HTTP::Headers{"User-Agent" => USER_AGENT})
      raise "HTTP status #{res.status}" unless res.status == 200
      rates = FX.parse_xml(String.new(res.body))
      raise "file contains no rates" if rates.empty?
      @d.store.save_ecb_rates(rates)
      rates
    end
  end
end
