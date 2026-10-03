require "wait_group"

# Exchange rates: ECB reference rates cached in SQLite, manual rates, and
# GET /api/kurs for the expense form.
#
# Rules for Service#rate(currency, date):
# - EUR gives 1 (source "fest").
# - Manual rates take precedence: the most recent manual rate whose "valid
#   from" <= date applies, until a newer manual rate is entered.
# - Otherwise the ECB rate of that date or of the last business day before it
#   (up to LOOKBACK_DAYS back). If it is missing from the cache, it is fetched:
#   the daily file for today/yesterday, the 90-day file for recent dates,
#   otherwise the complete history once (eurofxref-hist.zip).
module Zipfelkasse::FX
  # How far an ECB rate may lie before the requested date (weekends, holidays).
  LOOKBACK_DAYS = 10

  class Service
    include Web::FXRater
    include Web::Helpers

    property clock : Proc(Time)
    @berlin : Time::Location
    @base_url : String
    @mutex = Mutex.new
    @loads = {} of String => Load
    @clients = Set(HTTP::Client).new
    @bg = WaitGroup.new
    @stopped = false

    def initialize(@d : Web::Deps)
      d = @d
      @clock = -> { d.now }
      @berlin = begin
        Time::Location.load("Europe/Berlin")
      rescue Time::Location::InvalidLocationNameError
        Time::Location.fixed("CET", 3600)
      end
      @base_url = d.config.ecb_base_url.presence || DEFAULT_BASE_URL
    end

    def today : Time
      Domain.date_of(@clock.call.in(@d.config.location))
    end

    # The latest day <= date for which the ECB should already have published.
    def expected_date(date : Time) : Time
      now = @clock.call.in(@berlin)
      today_berlin = Domain.date_of(now)
      if date >= today_berlin
        date = today_berlin
        date = date.shift(days: -1) if now.hour * 60 + now.minute < PUBLISH_HOUR * 60 + PUBLISH_MINUTE
      end
      FX.last_business_day(date)
    end

    # The rate in ECB format (units of currency per 1 EUR). Raises
    # Domain::ValidationError (invalid currency, no rate; the text can be
    # shown as is), FetchError (ECB not reachable) or a database error.
    def rate(currency : String, date : Time) : Domain::FXRate
      cur = currency.strip.upcase
      date = Domain.date_of(date)
      return Domain::FXRate.new("EUR", date, 1.0, Domain::FX_SOURCE_FIXED) if cur == "EUR"
      unless Domain.valid_currency_code?(cur)
        raise Domain::ValidationError.new("Bitte eine Währung angeben.") if cur.empty?
        raise Domain::ValidationError.new("Ungültige Währung „#{currency}“.")
      end
      today = self.today
      date = today if date > today # future: latest rate

      begin
        return @d.store.lookup_fx_rate(cur, Domain::FX_SOURCE_MANUAL, date)
      rescue Store::NotFound
      end

      window = date.shift(days: -LOOKBACK_DAYS)
      cached = hist_covers?(date)
      if r = lookup_ecb(cur, date, window)
        return r if r.date >= expected_date(date) || cached
      elsif cached
        raise no_rate(cur, date)
      end

      result = nil
      fetch_error = nil
      FX.files_for(date, today).each do |file|
        break if file == FILE_HIST && hist_covers?(date)
        begin
          result = fetch(file)
        rescue ex : FetchError
          fetch_error = ex
          break
        end
        break if result.covers?(date)
      end
      if r = lookup_ecb(cur, date, window)
        return r
      end
      raise fetch_error if fetch_error
      raise no_rate(cur, date, result.try(&.currencies))
    end

    private def lookup_ecb(cur : String, date : Time, window : Time) : Domain::FXRate?
      @d.store.lookup_fx_rate(cur, Domain::FX_SOURCE_ECB, date, window)
    rescue Store::NotFound
      nil
    end

    private def hist_covers?(date : Time) : Bool
      hist = hist_until
      !hist.nil? && date <= hist
    end

    # If the ECB does not know the currency at all, says so; otherwise only
    # the rate for the date is missing.
    private def no_rate(cur : String, date : Time, fetched : Set(String)? = nil) : Domain::ValidationError
      known = fetched.try(&.includes?(cur)) || @d.store.has_ecb_currency?(cur)
      unless known
        return Domain::ValidationError.new("Für #{cur} gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.")
      end
      Domain::ValidationError.new("Für #{cur} gibt es um den #{Domain.format_date(date)} keinen EZB-Kurs – bitte Kurs von Hand eintragen.")
    end

    # Loads the latest ECB rates (daily file; the 90-day file if the cache has
    # gaps) and returns the most recent rate date.
    def refresh : Time
      to = @d.store.ecb_cache_stats.to
      expected = expected_date(today)
      file = to.nil? || to < FX.last_business_day(expected.shift(days: -1)) ? FILE_90D : FILE_DAILY
      fetch(file, force: true).to
    end

    # Fetches missing rates on startup, then the new ones on every business
    # day after 16:30 Europe/Berlin. Errors are only logged. Returns when the
    # stopper fires, after running downloads have ended.
    def run(stopper : Stopper) : Nil
      spawn do
        stopper.done.receive?
        abort_downloads
      end
      stats = @d.store.ecb_cache_stats rescue nil
      if stats && ((to = stats.to).nil? || to < expected_date(today))
        refresh_logged(stopper)
      end
      retries = 0
      loop do
        # Measured with the service clock: under a frozen test clock, a
        # publication time in the real past would fire again and again.
        now = @clock.call
        wait = retries > 0 ? 1.hour : FX.next_publish(now.in(@berlin)) - now
        break unless stopper.wait(wait)
        latest = refresh_logged(stopper)
        # Not yet published or failed: retry hourly, up to three times.
        if (latest.nil? || latest < expected_date(today)) && retries < 3
          retries += 1
        else
          retries = 0
        end
      end
    ensure
      stop
    end

    private def refresh_logged(stopper : Stopper) : Time?
      refresh
    rescue ex
      @d.log.error("refresh ECB rates", err: ex) unless stopper.stopped?
      nil
    end

    # Aborts running downloads and refuses new ones.
    private def abort_downloads : Nil
      @mutex.synchronize do
        @stopped = true
        @clients.each(&.close)
      end
    end

    private def stop : Nil
      abort_downloads
      @bg.wait
    end
  end

  # The files that, in this order, may contain date.
  def self.files_for(date : Time, today : Time) : Array(String)
    age = (today - date).total_days.to_i
    if age <= 1
      [FILE_DAILY, FILE_90D, FILE_HIST]
    elsif age < 85
      [FILE_90D, FILE_HIST]
    else
      [FILE_HIST]
    end
  end
end

def Zipfelkasse::App.wire_fx(app : App, d : Web::Deps, mcp : Web::MCPMount) : Nil
  service = FX::Service.new(d)
  d.fx = service
  service.register
  app.jobs << ->(s : Stopper) { service.run(s) }
end
