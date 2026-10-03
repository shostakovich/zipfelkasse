require "wait_group"

# Syncs each person's own share of every expense into a YNAB clearing
# account "Geteilt" (per person, with their own token).
#
# Model: for each expense the app writes only the person's share as an
# outflow with the mapped YNAB category. Bank payments for shared expenses and
# reimbursements are marked in YNAB as transfers to/from "Geteilt". Then the
# balance of "Geteilt" in YNAB equals the person's balance in the app.
module Zipfelkasse::YNAB
  Log = ::Log.for(self)

  DEFAULT_DEBOUNCE    = 5.seconds  # collect changes before a run
  DEFAULT_START_DELAY = 15.seconds # first full sync after startup
  FULL_INTERVAL       = 1.hour
  CACHE_TTL           = 10.minutes # plans/accounts/categories for the settings page

  class Service
    getter d : Web::Deps
    property base_url : String
    # Status times, retry_at, today and the cache use this clock; scheduling
    # uses the monotonic one.
    property now : Proc(Time)
    property debounce : Time::Span
    property start_delay : Time::Span

    @wake = Channel(Nil).new(1)
    # At most one sync at a time (worker or button); changes of token or
    # target wait for it (see change_connection).
    @sync_mutex = Mutex.new
    @http = OutboundHTTP.new(HTTP_TIMEOUT, MAX_BODY)
    @bg_busy = Set(Int64).new
    @bg_wait = WaitGroup.new
    @plans_cache = {} of String => {Time, Array(APIPlan)}
    @categories_cache = {} of String => {Time, Array(APICategoryGroup)}

    def initialize(@d : Web::Deps)
      @base_url = @d.config.ynab_base_url.presence || DEFAULT_BASE_URL
      @now = -> { @d.now }
      delay = @d.config.ynab_delay
      @debounce = delay && delay.positive? ? delay : DEFAULT_DEBOUNCE
      @start_delay = delay && delay.positive? ? delay : DEFAULT_START_DELAY
      @d.store.on_change = -> { trigger }
    end

    def client(token : String) : Client
      Client.new(@base_url, token, @http)
    end

    def location : Time::Location
      @d.config.location
    end

    # Never blocks. Every run compares the complete desired state with
    # ynab_sync (without requests if nothing differs), so a signal is
    # enough.
    def trigger : Nil
      select
      when @wake.send(nil)
      else # a run is already pending
      end
    end

    def run(stopper : Stopper) : Nil
      spawn do
        stopper.done.receive?
        @http.stop
      end
      deadline = Time.instant + @start_delay
      last_full = nil.as(Time::Instant?)
      loop do
        wait = deadline - Time.instant
        select
        when stopper.done.receive?
          break
        when @wake.receive
          if deadline - Time.instant > @debounce
            deadline = Time.instant + @debounce
          end
        when timeout(wait.positive? ? wait : Time::Span.zero)
          full = last_full.nil? || last_full.elapsed >= FULL_INTERVAL - 1.minute
          last_full = Time.instant if full
          next_run = sync_all(full)
          deadline = Time.instant + next_run
        end
      end
    ensure
      stop
    end

    # Runs a change of token or target under the sync mutex so that it never
    # interleaves with a sync: otherwise the sync would write transaction IDs
    # of the old account into the state for the new one, or overwrite the
    # status just reset for a new token with its own result.
    def change_connection(&)
      @sync_mutex.synchronize { yield }
    end

    def sync_in_background(participant_id : Int64) : Nil
      return if @http.stopped? || @bg_busy.includes?(participant_id)
      @bg_busy << participant_id
      @bg_wait.spawn do
        sync_person(participant_id, true, manual: true)
      ensure
        @bg_busy.delete(participant_id)
      end
    end

    def stop : Nil
      @http.stop
      @bg_wait.wait
    end

    def wait_background : Nil
      @bg_wait.wait
    end

    def plans(token : String, refresh : Bool) : Array(APIPlan)
      cached(@plans_cache, "plans:" + token, refresh) { client(token).plans }
    end

    def categories(token : String, plan_id : String, refresh : Bool) : Array(APICategoryGroup)
      cached(@categories_cache, "categories:#{token}:#{plan_id}", refresh) do
        client(token).categories(plan_id)
      end
    end

    private def cached(cache : Hash(String, {Time, T}), key : String, refresh : Bool, & : -> T) : T forall T
      if !refresh && (e = cache[key]?) && @now.call - e[0] < CACHE_TTL
        return e[1]
      end
      v = yield
      cache[key] = {@now.call, v}
      v
    end
  end

  protected def self.empty_config(participant_id : Int64) : Store::YNABConfig
    Store::YNABConfig.new(participant_id, nil, nil, nil, nil, false, nil, nil)
  end

  def self.redact(msg : String, token : String?) : String
    token ? msg.gsub(token, "•••") : msg
  end
end
