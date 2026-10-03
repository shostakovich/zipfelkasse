# Rules for Service#rate: EUR is 1; the newest manual rate valid on the date
# wins; otherwise the ECB rate of the date or of the last business day before
# it. The ECB cache is complete from its first to its last day: a date before
# it loads the full history (or the 90-day file), a date after it loads the
# 90-day file only once the ECB can have published since the last load.
module Zipfelkasse::FX
  Log = ::Log.for(self)

  # How far an ECB rate may lie before the requested date (weekends, holidays).
  LOOKBACK_DAYS = 10
  # The 90-day file still reaches this far back.
  RECENT_DAYS = 85
  # The ECB publishes on weekdays around 16:00 CET.
  PUBLISH_HOUR = 16
  REFRESH_HOUR = 17
  # A file is downloaded on demand at most this often.
  COOLDOWN = 15.minutes

  BERLIN = Time::Location.load("Europe/Berlin")

  class Service
    record Attempt, at : Time, error : FetchError?

    @http = OutboundHTTP.new(60.seconds, MAX_BODY_SIZE)
    @attempts = {} of String => Attempt
    @loads = Hash(String, Mutex).new { |loads, file| loads[file] = Mutex.new }
    @fetched_at : Time?
    @cached_days : Range(Time, Time)?
    @cached_days_read = false

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
      days = cached_days
      return if days && days.includes?(date)
      if days && date > days.end
        return unless published_since?(@fetched_at || published_at(days.end))
        file = file_reaching(days.end)
      else
        file = file_reaching(date)
      end
      @loads[file].synchronize do
        if (attempt = @attempts[file]?) && @d.now - attempt.at < COOLDOWN
          return attempt.error
        end
        fetch(file)
      end
      nil
    rescue ex : FetchError
      ex
    end

    # After a restart, the publication of the newest cached day stands in for the last load.
    private def published_at(day : Time) : Time
      Time.local(day.year, day.month, day.day, PUBLISH_HOUR, location: BERLIN)
    end

    private def published_since?(time : Time) : Bool
      publication = Domain.next_at_hour(time.in(BERLIN), PUBLISH_HOUR)
      while publication.saturday? || publication.sunday?
        publication = publication.shift(days: 1)
      end
      publication <= @d.now
    end

    # Only #fetch writes ECB rates, so the bounds are read once.
    private def cached_days : Range(Time, Time)?
      unless @cached_days_read
        @cached_days = @d.store.ecb_date_range
        @cached_days_read = true
      end
      @cached_days
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
      file = file_reaching(cached_days.try(&.end) || @d.today)
      @loads[file].synchronize { fetch(file) }
    end

    # Loads at startup when the cache lacks the last daily refresh, then daily
    # at REFRESH_HOUR. Returns when the stopper fires.
    def run(stopper : Stopper) : Nil
      spawn do
        stopper.done.receive?
        @http.stop
      end
      refresh_logged(stopper, if_stale: true)
      # Waits on the configured clock: a frozen test clock never reaches the next refresh.
      while stopper.wait(Domain.next_at_hour(@d.now.in(BERLIN), REFRESH_HOUR) - @d.now)
        refresh_logged(stopper)
      end
    end

    private def refresh_logged(stopper : Stopper, if_stale = false) : Nil
      if if_stale
        to = cached_days.try(&.end)
        return unless to.nil? || to < Domain.date_of(@d.now.in(BERLIN) - REFRESH_HOUR.hours)
      end
      refresh
    rescue ex
      Log.error(exception: ex) { "refresh ECB rates" } unless stopper.stopped?
    end

    private def fetch(file : String) : Time
      rates = download(file)
      @attempts[file] = Attempt.new(@d.now, nil)
      @fetched_at = @d.now
      oldest, newest = rates.minmax_of(&.date)
      @cached_days = cached_days.try { |days| Math.min(days.begin, oldest)..Math.max(days.end, newest) } || (oldest..newest)
      Log.info(&.emit("ECB rates loaded", file: file, rates: rates.size,
        from: Store.format_date(oldest), to: Store.format_date(newest)))
      newest
    rescue ex
      Log.warn(exception: ex, &.emit("loading ECB rates failed", file: file))
      error = ex.as?(FetchError) || FetchError.new(ex.message || ex.class.name)
      @attempts[file] = Attempt.new(@d.now, error)
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
