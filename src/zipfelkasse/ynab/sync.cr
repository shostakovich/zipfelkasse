module Zipfelkasse::YNAB
  # Sync: for each person with a YNAB connection, the desired state (one
  # transaction per own expense, see posting_for) is compared with ynab_sync.
  # Only the differences go to YNAB, batched to spare the limit of 200
  # requests per hour: new → one POST for all, changed → one PATCH for all,
  # gone → DELETE one by one (the API has no bulk DELETE). Without
  # differences a run costs not a single request.
  #
  # Meaning of ynab_sync.synced_hash:
  #   - fingerprint of the last transferred desired state (Want#fingerprint)
  #   - "error:" + fingerprint: transferring this state failed; it is retried
  #     only on change, in the hourly full sync or via "Jetzt synchronisieren"
  #   - "error:delete": deleting the transaction (expense gone) failed; it is
  #     retried only in the full sync
  #   - "pending": creation is in progress or its outcome is unknown (timeout,
  #     5xx). The next run looks for the transaction in the account via the
  #     memo marker instead of blindly creating it again (duplicates).
  #   - "retarget" (Store::YNAB_HASH_RETARGET, without transaction ID): plan or
  #     account changed. Like "pending", the next run looks for the
  #     transaction in the new account (it is there already after switching
  #     back), but only for expenses that belong there; the other rows are
  #     dropped.
  #   - "": unknown; forces a create (no transaction) or a PATCH
  PENDING_HASH       = "pending"
  RETARGET_HASH      = Store::YNAB_HASH_RETARGET
  ERROR_HASH_PREFIX  = "error:"
  DELETE_FAILED_HASH = ERROR_HASH_PREFIX + "delete"
  HASH_VERSION       = "v1"
  CHUNK_SIZE         = 100 # transactions per POST/PATCH
  MAX_DELETES        =  40 # each DELETE costs one request
  MAX_SINGLE         =  20 # single attempts after a rejected batch call
  SYSTEMIC_FAILURES  =   3 # this many single failures in a row without success: defer the rest
  RETRY_DELAY        = 5.minutes
  MAX_BACKOFF        = 1.hour

  TOKEN_INVALID_MESSAGE = "Der YNAB-Token ist ungültig oder abgelaufen. Bitte einen neuen Token eintragen."
  NOT_READY_MESSAGE     = "YNAB ist noch nicht fertig eingerichtet (Token, Plan, Konto und Startdatum)."

  alias Status = Store::YNABStatus

  class TokenInvalidError < Exception
    def initialize
      super(TOKEN_INVALID_MESSAGE)
    end
  end

  class NotReadyError < Exception
    def initialize
      super(NOT_READY_MESSAGE)
    end
  end

  # YNAB is not asked until `until` (rate limit or outage). Only logged.
  class BackoffError < Exception
    getter until : Time

    def initialize(@until)
      super("YNAB paused until #{@until.to_s("%H:%M")} (rate limit or outage)")
    end
  end

  class SyncResult
    property created = 0
    property updated = 0
    property deleted = 0
    property failed = 0
    property? again = false # work remains: run again soon

    def_equals created, updated, deleted, failed, again?

    def changes : Int32
      created + updated + deleted + failed
    end

    # The summary on the settings page.
    def to_s(io : IO) : Nil
      io << created << " neu · " << updated << " geändert · " << deleted << " gelöscht"
      io << " · " << failed << " fehlgeschlagen" if failed > 0
    end

    def log_value : String
      "#{created} created, #{updated} updated, #{deleted} deleted, #{failed} failed"
    end
  end

  # The desired state of a transaction in YNAB.
  struct Want
    getter posting : Posting
    getter category : String # YNAB category ID, "" = uncategorized
    getter fingerprint : String
    property txn_id = "" # existing transaction (for PATCH)

    delegate expense_id, date, payee, memo, to: @posting

    def initialize(@posting, @category)
      @fingerprint = Want.fingerprint(@posting, @category)
    end

    # 1 cent = 10 milliunits; an outflow is negative.
    def milliunits : Int64
      -posting.amount_cents * 10
    end

    def new_txn(account_id : String) : SaveTxn
      SaveTxn.new(account_id: account_id, date: date_string, amount: milliunits, payee_name: payee, memo: memo,
        category_id: category.presence, cleared: "cleared", approved: true)
    end

    # Changes the category only if mapped: without a mapping a category set
    # by hand in YNAB is kept. cleared/approved are no longer touched after
    # creation (e.g. reconciled transactions).
    def patch_txn : SaveTxn
      SaveTxn.new(id: txn_id, date: date_string, amount: milliunits, payee_name: payee, memo: memo,
        category_id: category.presence)
    end

    private def date_string : String
      date.to_s("%Y-%m-%d")
    end

    # Stored in ynab_sync: must stay byte-identical across versions, or every
    # transaction looks changed and gets PATCHed.
    def self.fingerprint(p : Posting, category : String) : String
      data = String.build do |s|
        s << HASH_VERSION << '\0' << p.date.to_s("%Y-%m-%d") << '\0' << -p.amount_cents * 10 << '\0'
        s << p.payee << '\0' << p.memo << '\0' << category
      end
      Digest::SHA256.digest(data)[0, 16].hexstring
    end
  end

  # The last day that YNAB will certainly not reject as future: today in the
  # app time zone, but at most today in UTC.
  def self.today(now : Time, location : Time::Location) : Time
    local, utc = Domain.date_of(now.in(location)), Domain.date_of(now.to_utc)
    utc < local ? utc : local
  end

  # Errors that abort the person's whole run (including database errors and
  # unclear outcomes). Other 4xx concern single transactions.
  def self.run_level?(ex : Exception) : Bool
    status_of(ex).in?(0, 401, 403, 404, 429) || uncertain?(ex)
  end

  class Service
    def today : Time
      YNAB.today(@now.call, location)
    end

    # Zero status without a connection.
    def load_status(participant_id : Int64) : Status
      @d.store.get_ynab_status(participant_id)
    rescue Store::NotFound
      Status.new
    end

    # Syncs one person and maintains their status. full also retries
    # unchanged transactions that failed before.
    def sync_one(cfg : Store::YNABConfig, full : Bool) : {SyncResult, Status, Exception?}
      pid = cfg.participant_id
      res = SyncResult.new
      st = begin
        load_status(pid)
      rescue ex
        return {res, Status.new, ex}
      end
      now = @now.call
      return {res, st, TokenInvalidError.new} if st.token_invalid?
      if (retry_at = st.retry_at) && now < retry_at
        return {res, st, BackoffError.new(retry_at)}
      end
      st.last_run = now
      err = begin
        sync_participant(cfg, full, res)
        nil
      rescue ex
        ex
      end
      # Aborted by the shutdown: no error and no pause for the next start.
      return {res, st, err} if err && @connections.stopped?
      if err
        if err.is_a?(APIError) && err.status == 401
          st.token_invalid = true
          st.error = TOKEN_INVALID_MESSAGE
        elsif err.is_a?(APIError) && err.status == 429
          st.backoff = (st.backoff * 2).clamp(RETRY_DELAY, MAX_BACKOFF)
          retry_at = now + Math.max(st.backoff, err.retry_after)
          st.retry_at = retry_at
          st.error = "Das YNAB-Anfragelimit ist erreicht. Nächster Versuch um #{retry_at.in(location).to_s("%H:%M")} Uhr."
        elsif YNAB.status_of(err) == 404
          st.error = "Plan oder Konto gibt es in YNAB nicht (mehr). Bitte Plan und Konto neu wählen."
        elsif YNAB.uncertain?(err)
          st.retry_at = now + RETRY_DELAY
          st.error = YNAB.redact(err.message || "", cfg.token)
        else
          st.error = YNAB.redact(err.message || err.class.name, cfg.token)
        end
      else
        st.error, st.backoff, st.retry_at = "", Time::Span.zero, nil
        st.last_sync, st.summary = now, res.to_s
      end
      begin
        @d.store.set_ynab_status(pid, st)
      rescue ex
        err ||= ex
      end
      {res, st, err}
    end

    private def sync_participant(cfg : Store::YNABConfig, full : Bool, res : SyncResult) : Nil
      pid = cfg.participant_id
      wants = desired(cfg)
      rows = {} of Int64 => Store::YNABSync
      pending = [] of Int64
      @d.store.list_ynab_sync(pid).each do |r|
        rows[r.expense_id] = r
        if r.txn_id.empty? && (r.synced_hash == PENDING_HASH || (r.synced_hash == RETARGET_HASH && wants.has_key?(r.expense_id)))
          pending << r.expense_id
        end
      end
      c = client(cfg.token)
      resolve_pending(c, cfg, wants, rows, pending) unless pending.empty?

      creates, updates = [] of Want, [] of Want
      deletes, forget = [] of Store::YNABSync, [] of Int64
      wants.each do |id, w|
        r = rows[id]?
        if !full && r && r.synced_hash == ERROR_HASH_PREFIX + w.fingerprint
          # failed and unchanged: retry only in the full sync
        elsif r.nil? || r.txn_id.empty?
          creates << w
        elsif r.synced_hash != w.fingerprint
          w.txn_id = r.txn_id
          updates << w
        end
      end
      rows.each do |id, r|
        next if wants.has_key?(id)
        # Gone (deleted or share 0): delete, even if the last attempt (e.g. a
        # PATCH) failed. Only a failed DELETE waits for the full sync.
        if r.txn_id.empty?
          forget << id
        elsif full || r.synced_hash != DELETE_FAILED_HASH
          deletes << r
        end
      end
      creates.sort_by!(&.expense_id)
      updates.sort_by!(&.expense_id)
      deletes.sort_by!(&.expense_id)
      forget.sort!

      @d.store.delete_ynab_sync(pid, forget)
      create(c, cfg, creates, res)
      update(c, cfg, updates, res)
      remove(c, cfg, deletes, res)
    end

    # By expense ID.
    private def desired(cfg : Store::YNABConfig) : Hash(Int64, Want)
      sel = Selection.for_config(@d.store, cfg, today)
      # All of the person's expenses, not just from the start date: earlier
      # ones can belong too (entered later or already in YNAB).
      es = @d.store.list_expenses(Store::ExpenseFilter.new(participant_id: cfg.participant_id))
      cats = @d.store.ynab_category_map(cfg.participant_id)
      sel.postings(es, cfg.participant_id).to_h do |p|
        category = p.category_id.try { |id| cats[id]? } || ""
        {p.expense_id, Want.new(p, category)}
      end
    end

    # Resolves creations with an unknown outcome and rows after a change of
    # the target via the memo marker of the transactions in the account (one
    # request).
    private def resolve_pending(c : Client, cfg : Store::YNABConfig, wants : Hash(Int64, Want),
                                rows : Hash(Int64, Store::YNABSync), pending : Array(Int64)) : Nil
      txns = c.account_transactions(cfg.plan_id, cfg.account_id, pending_since(cfg, wants, pending))
      found = {} of Int64 => String
      txns.each do |t|
        next if t.deleted
        if id = YNAB.marker_id(t.memo || "")
          found[id] = t.id
        end
      end
      upd = pending.map do |id|
        r = rows[id]
        # "" forces a PATCH (found) or a new creation
        r.txn_id, r.synced_hash = found[id]? || "", ""
        rows[id] = r
      end
      @d.store.put_ynab_sync(upd)
    end

    # The start date, or the earliest date of the pending expenses if earlier
    # (backdated expenses belong too, see Selection).
    private def pending_since(cfg : Store::YNABConfig, wants : Hash(Int64, Want), pending : Array(Int64)) : Time
      since = cfg.start_date || raise "YNAB connection without start date"
      pending.each do |id|
        # no longer wanted (e.g. deleted): its date from the expense
        date = wants[id]?.try(&.date) || @d.store.get_expense(id).date
        since = date if date < since
      end
      since
    end

    private def row(cfg : Store::YNABConfig, w : Want) : Store::YNABSync
      Store::YNABSync.new(w.expense_id, cfg.participant_id)
    end

    private def failed_row(cfg : Store::YNABConfig, w : Want, txn_id : String, ex : Exception) : Store::YNABSync
      Store::YNABSync.new(w.expense_id, cfg.participant_id, txn_id, ERROR_HASH_PREFIX + w.fingerprint,
        last_error: YNAB.redact(ex.message || "", cfg.token))
    end

    private def create(c : Client, cfg : Store::YNABConfig, ws : Array(Want), res : SyncResult) : Nil
      ws.each_slice(CHUNK_SIZE) do |chunk|
        mark_pending(cfg, chunk, PENDING_HASH)
        begin
          got = c.create_transactions(cfg.plan_id, chunk.map(&.new_txn(cfg.account_id)))
        rescue ex
          raise ex if YNAB.uncertain?(ex) # stays "pending", the next run resolves it
          if YNAB.run_level?(ex)
            unmark_pending(cfg, chunk) # certainly not created
            raise ex
          end
          # Batch call rejected (400/409/…): try one by one to find the
          # faulty transaction.
          create_each(c, cfg, chunk, res)
          next
        end
        apply_created(cfg, chunk, got, res)
      end
    end

    private def mark_pending(cfg : Store::YNABConfig, ws : Array(Want), hash : String) : Nil
      @d.store.put_ynab_sync(ws.map { |w| Store::YNABSync.new(w.expense_id, cfg.participant_id, synced_hash: hash) })
    end

    # Undoes the pending mark of transactions that were certainly not
    # created. A failure is only logged (the run ends with an error anyway):
    # rows left "pending" cost the next run one search request.
    private def unmark_pending(cfg : Store::YNABConfig, ws : Array(Want)) : Nil
      mark_pending(cfg, ws, "")
    rescue ex
      Log.warn(exception: ex, &.emit("ynab: undo pending mark", person: cfg.participant_id))
    end

    private def apply_created(cfg : Store::YNABConfig, ws : Array(Want), got : Array(APITxn), res : SyncResult) : Nil
      ids = {} of Int64 => String
      got.each do |t|
        if id = YNAB.marker_id(t.memo || "")
          ids[id] = t.id
        end
      end
      now = @now.call
      rows = ws.map do |w|
        r = row(cfg, w)
        if txn_id = ids[w.expense_id]?
          r.txn_id, r.synced_hash, r.synced_at = txn_id, w.fingerprint, now
          res.created += 1
        else
          # not in the response: stays "pending" and is resolved in the next run
          r.synced_hash, r.last_error = PENDING_HASH, "YNAB hat das Anlegen nicht bestätigt."
          res.failed += 1
          res.again = true
        end
        r
      end
      @d.store.put_ynab_sync(rows)
    end

    private def create_each(c : Client, cfg : Store::YNABConfig, ws : Array(Want), res : SyncResult) : Nil
      succeeded = false
      ws.each_with_index do |w, i|
        if i >= MAX_SINGLE
          res.again = true
          return mark_pending(cfg, ws[i..], "")
        end
        begin
          got = c.create_transactions(cfg.plan_id, [w.new_txn(cfg.account_id)])
        rescue ex
          if YNAB.uncertain?(ex)
            unmark_pending(cfg, ws[i + 1..]) # not tried yet
            raise ex
          elsif YNAB.run_level?(ex)
            unmark_pending(cfg, ws[i..])
            raise ex
          end
          res.failed += 1
          @d.store.put_ynab_sync(failed_row(cfg, w, "", ex))
          # Everything fails the same way (e.g. account closed): do not try
          # the rest one by one, defer it until the full sync.
          return fail_all(cfg, ws[i + 1..], false, ex, res) if !succeeded && i + 1 >= SYSTEMIC_FAILURES
          next
        end
        succeeded = true
        apply_created(cfg, [w], got, res)
      end
    end

    # Marks ws as failed with ex (without requests).
    private def fail_all(cfg : Store::YNABConfig, ws : Array(Want), keep_txn : Bool, ex : Exception, res : SyncResult) : Nil
      res.failed += ws.size
      @d.store.put_ynab_sync(ws.map { |w| failed_row(cfg, w, keep_txn ? w.txn_id : "", ex) })
    end

    # PATCH is idempotent: on an unclear outcome the next run repeats it.
    private def update(c : Client, cfg : Store::YNABConfig, ws : Array(Want), res : SyncResult) : Nil
      ws.each_slice(CHUNK_SIZE) do |chunk|
        begin
          got = c.update_transactions(cfg.plan_id, chunk.map(&.patch_txn))
        rescue ex
          raise ex if YNAB.run_level?(ex) && YNAB.status_of(ex) != 404
          # rejected or 404 (a transaction is missing in YNAB): one by one
          update_each(c, cfg, chunk, res)
          next
        end
        apply_updated(cfg, chunk, got, res)
      end
    end

    private def apply_updated(cfg : Store::YNABConfig, ws : Array(Want), got : Array(APITxn), res : SyncResult) : Nil
      by_txn = got.to_h { |t| {t.id, t} }
      now = @now.call
      rows = ws.map do |w|
        r = row(cfg, w)
        t = by_txn[w.txn_id]?
        if t.nil?
          res.failed += 1
          failed_row(cfg, w, w.txn_id, Exception.new("YNAB hat die Änderung nicht bestätigt."))
        elsif t.deleted
          # deleted by hand in YNAB: create it again (the app is authoritative)
          res.again = true
          r
        else
          r.txn_id, r.synced_hash, r.synced_at = w.txn_id, w.fingerprint, now
          res.updated += 1
          r
        end
      end
      @d.store.put_ynab_sync(rows)
    end

    private def update_each(c : Client, cfg : Store::YNABConfig, ws : Array(Want), res : SyncResult) : Nil
      succeeded = false
      ws.each_with_index do |w, i|
        if i >= MAX_SINGLE
          res.again = true
          return
        end
        begin
          got = c.update_transactions(cfg.plan_id, [w.patch_txn])
        rescue ex
          if YNAB.status_of(ex) == 404
            # The transaction no longer exists in YNAB: create it again.
            confirm_target(c, cfg)
            succeeded = true
            res.again = true
            @d.store.put_ynab_sync(row(cfg, w))
            next
          end
          raise ex if YNAB.run_level?(ex)
          res.failed += 1
          @d.store.put_ynab_sync(failed_row(cfg, w, w.txn_id, ex))
          return fail_all(cfg, ws[i + 1..], true, ex, res) if !succeeded && i + 1 >= SYSTEMIC_FAILURES
          next
        end
        succeeded = true
        apply_updated(cfg, [w], got, res)
      end
    end

    # Deletes transactions that are gone, one by one; a 404 counts as done if
    # plan and account exist.
    private def remove(c : Client, cfg : Store::YNABConfig, rows : Array(Store::YNABSync), res : SyncResult) : Nil
      rows.each_with_index do |r, i|
        if i >= MAX_DELETES
          res.again = true
          return
        end
        err = begin
          c.delete_transaction(cfg.plan_id, r.txn_id)
          nil
        rescue ex
          ex
        end
        if YNAB.status_of(err) == 404
          confirm_target(c, cfg)
          err = nil # already deleted in YNAB
        end
        if err
          raise err if YNAB.run_level?(err)
          res.failed += 1
          r.synced_hash, r.last_error = DELETE_FAILED_HASH, YNAB.redact(err.message || "", cfg.token)
          @d.store.put_ynab_sync(r)
          next
        end
        res.deleted += 1
        @d.store.delete_ynab_sync(cfg.participant_id, r.expense_id)
      end
    end

    # Checks, once per run with one request, that plan and account exist
    # before a 404 for a single transaction is taken as "the transaction is
    # gone". YNAB answers 404 for every transaction as well if the whole plan
    # is gone or invisible to the token (token of another YNAB user);
    # dropping transaction IDs or counting DELETEs as done would then lead to
    # duplicates and leftovers once the setup is corrected. Its error stops
    # the run.
    private def confirm_target(c : Client, cfg : Store::YNABConfig) : Nil
      return if c.target_ok?
      a = c.account(cfg.plan_id, cfg.account_id)
      raise APIError.new(404, detail: "Konto gelöscht") if a.deleted
      c.target_ok = true
    end
  end
end
