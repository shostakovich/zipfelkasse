require "digest/sha256"
require "wait_group"

# Syncs each person's own share of every expense into a YNAB clearing
# account "Geteilt" (per person, with their own token).
#
# Model: for each expense the app writes only the person's share as an
# outflow with the mapped YNAB category. Bank payments for shared expenses and
# reimbursements are marked in YNAB as transfers to/from "Geteilt". Then the
# balance of "Geteilt" in YNAB equals the person's balance in the app.
module Zipfelkasse::YNAB
  DEFAULT_DEBOUNCE    = 5.seconds  # collect changes before a run
  DEFAULT_START_DELAY = 15.seconds # first full sync after startup
  FULL_INTERVAL       = 1.hour
  CACHE_TTL           = 10.minutes # plans/accounts/categories for the settings page

  # The sync worker plus the settings pages.
  class Service
    getter d : Web::Deps
    property base_url : String
    # Status times, retry_at, today and the cache use this clock; scheduling
    # uses the monotonic one.
    property now : Proc(Time)
    property debounce : Time::Span
    property start_delay : Time::Span

    # Trigger → run (buffer 1, never blocking).
    @wake = Channel(Nil).new(1)
    # At most one sync at a time (worker or button); changes of token or
    # target wait for it (see change_connection).
    @sync_mutex = Mutex.new
    @connections = Connections.new
    # Background syncs via "Jetzt synchronisieren"; run stops them on
    # shutdown and waits for them.
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
      @d.store.on_expense_change { trigger }
    end

    def client(token : String) : Client
      Client.new(@base_url, token, @connections)
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

    # Processes triggers (batched after a short delay), runs a full sync
    # every hour and retries after rate limits or outages until stopped.
    def run(stopper : Stopper) : Nil
      spawn do
        stopper.done.receive?
        @connections.stop
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

    # Syncs all configured people and returns the delay until the next
    # necessary run. The mutex is taken per person, so a change of the
    # settings waits for one person's run at most.
    def sync_all(full : Bool) : Time::Span
      next_run = FULL_INTERVAL
      cfgs = begin
        @d.store.list_ynab_configs
      rescue ex
        @d.log.error("ynab: read configs", err: ex)
        return RETRY_DELAY
      end
      cfgs.each do |c|
        return next_run if @connections.stopped?
        next unless c.ready?
        cfg, res, st, err = sync_person(c.participant_id, full)
        next if err.is_a?(NotReadyError) # changed in the meantime
        log_sync("", cfg, res, err) if err || res.changes > 0
        next_run = Math.min(next_run, @debounce) if res.again?
        if retry_at = st.retry_at
          wait = retry_at - @now.call
          next_run = Math.min(next_run, wait + 1.second) if wait.positive?
        end
      end
      next_run
    end

    # Never logs the token. A pause after a rate limit and an invalid token
    # are not logged: the settings page shows them, and they recur on every
    # run.
    def log_sync(how : String, cfg : Store::YNABConfig, res : SyncResult, err : Exception?) : Nil
      case err
      when nil
        @d.log.info("ynab: synced" + how, person: cfg.participant_id, result: res.log_value)
      when BackoffError, TokenInvalidError
      else
        @d.log.warn("ynab: sync" + how + " failed", person: cfg.participant_id,
          err: YNAB.redact(err.message || err.class.name, cfg.token))
      end
    end

    # Syncs one person under the mutex with the connection as it is now. A
    # sync uses the connection read at its start throughout, so token or
    # target must not change while it runs (see change_connection).
    def sync_person(participant_id : Int64, full : Bool) : {Store::YNABConfig, SyncResult, Status, Exception?}
      @sync_mutex.synchronize do
        cfg = begin
          @d.store.get_ynab_config(participant_id)
        rescue Store::NotFound
          nil
        rescue ex
          return {YNAB.empty_config(participant_id), SyncResult.new, Status.new, ex}
        end
        unless cfg && cfg.ready?
          return {cfg || YNAB.empty_config(participant_id), SyncResult.new, Status.new, NotReadyError.new}
        end
        res, st, err = sync_one(cfg, full)
        {cfg, res, st, err}
      end
    end

    # Runs a change of token or target under the sync mutex so that it never
    # interleaves with a sync: otherwise the sync would write transaction IDs
    # of the old account into the state for the new one, or overwrite the
    # status just reset for a new token with its own result.
    def change_connection(&)
      @sync_mutex.synchronize { yield }
    end

    # Fully syncs a person right away in its own fiber so that the request
    # does not wait for YNAB. Nothing happens if one is already running for
    # the person or run has ended; the result ends up in the status.
    def sync_in_background(participant_id : Int64) : Nil
      return if @connections.stopped? || @bg_busy.includes?(participant_id)
      @bg_busy << participant_id
      @bg_wait.spawn do
        cfg, res, _, err = sync_person(participant_id, true)
        log_sync(" (now)", cfg, res, err)
      ensure
        @bg_busy.delete(participant_id)
      end
    end

    # Aborts running requests, refuses new ones and waits for the background
    # syncs.
    def stop : Nil
      @connections.stop
      @bg_wait.wait
    end

    def wait_background : Nil
      @bg_wait.wait
    end

    def plans(token : String, refresh : Bool) : Array(APIPlan)
      cached(@plans_cache, "plans:" + YNAB.fingerprint(token), refresh) { client(token).plans }
    end

    def categories(token : String, plan_id : String, refresh : Bool) : Array(APICategoryGroup)
      cached(@categories_cache, "categories:#{YNAB.fingerprint(token)}:#{plan_id}", refresh) do
        client(token).categories(plan_id)
      end
    end

    # Errors are not cached.
    private def cached(cache : Hash(String, {Time, T}), key : String, refresh : Bool, & : -> T) : T forall T
      if !refresh && (e = cache[key]?) && @now.call - e[0] < CACHE_TTL
        return e[1]
      end
      v = yield
      cache[key] = {@now.call, v}
      v
    end
  end

  def self.fingerprint(token : String) : String
    Digest::SHA256.digest(token)[0, 8].hexstring
  end

  protected def self.empty_config(participant_id : Int64) : Store::YNABConfig
    Store::YNABConfig.new(participant_id, "", "", "", nil, false, nil, nil)
  end

  # Removes the token from error texts before they are stored, logged or
  # shown.
  def self.redact(msg : String, token : String) : String
    token.empty? ? msg : msg.gsub(token, "•••")
  end
end

def Zipfelkasse::App.wire_ynab(app : App, d : Web::Deps, mcp : Web::MCPMount) : Nil
  svc = YNAB::Service.new(d)
  app.ynab = svc
  svc.register
  app.jobs << ->(s : Stopper) { svc.run(s) }
end

class Zipfelkasse::App
  getter! ynab : YNAB::Service
  protected setter ynab
end
