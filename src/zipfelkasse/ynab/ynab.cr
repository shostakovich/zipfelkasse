require "wait_group"

# Each person's share of every expense goes as an outflow into their clearing account "Geteilt" in YNAB; bank payments
# and reimbursements are transfers to and from it there, so its balance equals the person's balance in the app.
module Zipfelkasse::YNAB
  Log = ::Log.for(self)

  DEFAULT_DEBOUNCE    = 5.seconds
  DEFAULT_START_DELAY = 15.seconds
  FULL_INTERVAL       = 1.hour
  CACHE_TTL           = 10.minutes

  class Service
    property base_url : String
    property debounce : Time::Span
    property start_delay : Time::Span

    @wake = Channel(Nil).new(1)
    @sync_mutex = Mutex.new
    @http = OutboundHTTP.new(HTTP_TIMEOUT, MAX_BODY)
    @bg_busy = Set(Int64).new
    @bg_wait = WaitGroup.new
    @plans_cache = {} of String => {Time, Array(APIPlan)}
    @categories_cache = {} of String => {Time, Array(APICategoryGroup)}

    def initialize(@d : Web::Deps)
      @base_url = @d.config.ynab_base_url || DEFAULT_BASE_URL
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

    # Every run compares the complete desired state with ynab_sync, so a pending signal is enough.
    def trigger : Nil
      select
      when @wake.send(nil)
      else
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

    # A sync running meanwhile would write transaction IDs of the old account into the state for the new one, or
    # overwrite the status just reset for a new token.
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

    def plans(token : String, refresh : Bool) : Array(APIPlan)
      cached(@plans_cache, "plans:" + token, refresh) { client(token).plans }
    end

    def categories(token : String, plan_id : String, refresh : Bool) : Array(APICategoryGroup)
      cached(@categories_cache, "categories:#{token}:#{plan_id}", refresh) do
        client(token).categories(plan_id)
      end
    end

    private def cached(cache : Hash(String, {Time, T}), key : String, refresh : Bool, & : -> T) : T forall T
      if !refresh && (e = cache[key]?) && @d.now - e[0] < CACHE_TTL
        return e[1]
      end
      v = yield
      cache[key] = {@d.now, v}
      v
    end
  end

  def self.redact(msg : String, token : String?) : String
    token ? msg.gsub(token, "•••") : msg
  end
end
