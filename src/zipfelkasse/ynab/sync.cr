module Zipfelkasse::YNAB
  RETRY_DELAY = 5.minutes
  MAX_BACKOFF = 1.hour

  TOKEN_INVALID_MESSAGE = "Der YNAB-Token ist ungültig oder abgelaufen. Bitte einen neuen Token eintragen."
  NOT_READY_MESSAGE     = "YNAB ist noch nicht fertig eingerichtet (Token, Plan, Konto und Startdatum)."

  alias Status = Store::YNABStatus

  enum Skip
    NotReady     # token, plan, account or start date missing, or changed in the meantime
    TokenInvalid # YNAB refused the token before; a new one resets this
    BackedOff    # rate limit or outage: YNAB is not asked until status.retry_at
  end

  record Outcome, result : SyncResult, status : Status, error : Exception? = nil, skipped : Skip? = nil,
    message : String? = nil do
    def self.skipped(reason : Skip, status : Status = Status.new) : Outcome
      new(SyncResult.new, status, skipped: reason)
    end

    def failure : Failure?
      error.try { |ex| Failure.of(ex) }
    end
  end

  class Service
    def today : Time
      YNAB.today(@now.call, location)
    end

    def load_status(participant_id : Int64) : Status
      @d.store.get_ynab_status(participant_id)
    rescue Store::NotFound
      Status.new
    end

    def sync_all(full : Bool) : Time::Span
      next_run = FULL_INTERVAL
      configs = begin
        @d.store.list_ynab_configs
      rescue ex
        Log.error(exception: ex) { "ynab: read configs" }
        return RETRY_DELAY
      end
      configs.each do |config|
        return next_run if @http.stopped?
        next unless config.ready?
        outcome = sync_person(config.participant_id, full)
        next if outcome.skipped.try(&.not_ready?)
        next_run = Math.min(next_run, @debounce) if outcome.result.again?
        if retry_at = outcome.status.retry_at
          wait = retry_at - @now.call
          next_run = Math.min(next_run, wait + 1.second) if wait.positive?
        end
      end
      next_run
    end

    # Syncs one person under the mutex with the connection as it is now. A
    # sync uses the connection read at its start throughout, so token or
    # target must not change while it runs (see change_connection). full also
    # retries unchanged transactions that failed before.
    def sync_person(participant_id : Int64, full : Bool, manual : Bool = false) : Outcome
      @sync_mutex.synchronize do
        outcome = begin
          sync_connected(participant_id, full)
        rescue ex
          Outcome.new(SyncResult.new, Status.new, ex, message: ex.message)
        end
        log(participant_id, outcome, manual)
        outcome
      end
    end

    private def sync_connected(participant_id : Int64, full : Bool) : Outcome
      config = @d.store.get_ynab_config?(participant_id) || return Outcome.skipped(Skip::NotReady)
      connection = config.connection || return Outcome.skipped(Skip::NotReady)
      status = load_status(participant_id)
      now = @now.call
      return Outcome.skipped(Skip::TokenInvalid, status) if status.token_invalid?
      if (retry_at = status.retry_at) && now < retry_at
        return Outcome.skipped(Skip::BackedOff, status)
      end

      run = Run.new(@d.store, client(connection.token), connection, @now)
      error = begin
        connected_at = config.connected_at || @d.store.ensure_ynab_connected_at(participant_id)
        run.call(desired(config, connected_at), full)
        nil
      rescue ex
        ex
      end
      message = error.try { |ex| YNAB.redact(ex.message || ex.class.name, connection.token) }
      status = status_after(status, now, run.result, error, message)
      # Aborted by the shutdown: no error and no pause for the next start.
      return Outcome.new(run.result, status, error, message: message) if error && @http.stopped?
      begin
        @d.store.set_ynab_status(participant_id, status)
      rescue ex
        error ||= ex
        message ||= ex.message
      end
      Outcome.new(run.result, status, error, message: message)
    end

    private def status_after(status : Status, now : Time, result : SyncResult, error : Exception?, message : String?) : Status
      status = status.copy_with(last_run: now)
      return status.copy_with(last_sync: now, summary: result.to_s, error: nil, backoff: Time::Span.zero, retry_at: nil) unless error
      case Failure.of(error)
      in .unauthorized?
        status.copy_with(token_invalid: true, error: TOKEN_INVALID_MESSAGE)
      in .rate_limited?
        backoff = (status.backoff * 2).clamp(RETRY_DELAY, MAX_BACKOFF)
        retry_at = now + Math.max(backoff, error.as(APIError).retry_after)
        status.copy_with(backoff: backoff, retry_at: retry_at,
          error: "Das YNAB-Anfragelimit ist erreicht. Nächster Versuch um #{retry_at.in(location).to_s("%H:%M")} Uhr.")
      in .not_found?
        status.copy_with(error: "Plan oder Konto gibt es in YNAB nicht (mehr). Bitte Plan und Konto neu wählen.")
      in .unclear?
        status.copy_with(retry_at: now + RETRY_DELAY, error: message)
      in .forbidden?, .rejected?, .other?
        status.copy_with(error: message)
      end
    end

    private def desired(config : Store::YNABConfig, connected_at : Time?) : Hash(Int64, Want)
      selection = Selection.for_config(@d.store, config, connected_at, today)
      # All of the person's expenses, not just from the start date: earlier
      # ones can belong too (entered later or already in YNAB).
      expenses = @d.store.list_expenses(Store::ExpenseFilter.new(participant_id: config.participant_id))
      categories = @d.store.ynab_category_map(config.participant_id)
      selection.postings(expenses, config.participant_id).to_h do |posting|
        {posting.expense_id, Want.new(posting, posting.category_id.try { |id| categories[id]? })}
      end
    end

    # Never logs the token. A skipped sync is not logged: the settings page
    # shows the pause or the invalid token, and they recur on every run.
    private def log(participant_id : Int64, outcome : Outcome, manual : Bool) : Nil
      return if outcome.skipped
      how = manual ? " (now)" : ""
      if message = outcome.message
        Log.warn(&.emit("ynab: sync#{how} failed", person: participant_id, err: message))
      elsif manual || outcome.result.changes > 0
        Log.info(&.emit("ynab: synced#{how}", person: participant_id, result: outcome.result.log_value))
      end
    end
  end

  # The last day that YNAB will certainly not reject as future: today in the
  # app time zone, but at most today in UTC.
  def self.today(now : Time, location : Time::Location) : Time
    local, utc = Domain.date_of(now.in(location)), Domain.date_of(now.to_utc)
    utc < local ? utc : local
  end
end
