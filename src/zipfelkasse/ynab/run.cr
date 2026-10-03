module Zipfelkasse::YNAB
  CHUNK_SIZE        = 100 # transactions per POST/PATCH
  MAX_DELETES       =  40 # each DELETE costs one request
  MAX_SINGLE        =  20 # single attempts after a rejected batch call
  SYSTEMIC_FAILURES =   3 # this many single failures in a row without success: defer the rest

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

    def to_s(io : IO) : Nil
      io << created << " neu · " << updated << " geändert · " << deleted << " gelöscht"
      io << " · " << failed << " fehlgeschlagen" if failed > 0
    end

    def log_value : String
      "#{created} created, #{updated} updated, #{deleted} deleted, #{failed} failed"
    end
  end

  class Run
    getter result = SyncResult.new
    @store : Store
    @target_confirmed = false

    def initialize(@store, @client : Client, @connection : Store::YNABConnection, @now : Proc(Time))
    end

    def call(wants : Hash(Int64, Want), full : Bool) : Nil
      rows = resolve_unclear(load_rows, wants)
      plan = Plan.build(wants, rows, full)
      @store.delete_ynab_sync(pid, plan.forget)
      create(plan.creates)
      update(plan.updates)
      remove(plan.deletes)
    end

    private def pid : Int64
      @connection.participant_id
    end

    private def plan_id : String
      @connection.plan_id
    end

    private def load_rows : Hash(Int64, Store::YNABSync)
      @store.list_ynab_sync(pid).to_h { |row| {row.expense_id, row} }
    end

    # Creations with an unknown outcome and rows after a change of the target
    # (only the expenses that belong to the new account) are looked up via
    # the memo marker in the account: one request for all of them, for the
    # whole account, because the date of the expense may have moved since.
    private def resolve_unclear(rows : Hash(Int64, Store::YNABSync), wants : Hash(Int64, Want)) : Hash(Int64, Store::YNABSync)
      unclear = rows.values.select { |row| row.pending? || (row.retarget? && wants.has_key?(row.expense_id)) }
      return rows if unclear.empty?
      found = {} of Int64 => String
      @client.account_transactions(plan_id, @connection.account_id).each do |txn|
        next if txn.deleted
        YNAB.marker_id(txn.memo || "").try { |expense_id| found[expense_id] = txn.id }
      end
      resolved = unclear.map { |row| row.unknown(found[row.expense_id]?) }
      @store.put_ynab_sync(resolved)
      rows.merge(resolved.to_h { |row| {row.expense_id, row} })
    end

    private def create(wants : Array(Want)) : Nil
      wants.each_slice(CHUNK_SIZE) do |chunk|
        mark_pending(chunk)
        begin
          created = @client.create_transactions(plan_id, chunk.map(&.new_txn(@connection.account_id)))
        rescue ex
          failure = Failure.of(ex)
          raise ex if failure.unclear? # stays pending, the next run resolves it
          if failure.aborts_run?
            unmark_pending(chunk) # certainly not created
            raise ex
          end
          create_each(chunk)
          next
        end
        apply_created(chunk, created)
      end
    end

    private def mark_pending(wants : Array(Want)) : Nil
      @store.put_ynab_sync(wants.map { |want| Store::YNABSync.pending(want.expense_id, pid) })
    end

    private def unmark_pending(wants : Array(Want)) : Nil
      @store.put_ynab_sync(wants.map { |want| Store::YNABSync.new(want.expense_id, pid) })
    rescue ex
      Log.warn(exception: ex, &.emit("ynab: undo pending mark", person: pid))
    end

    private def apply_created(wants : Array(Want), created : Array(APITxn)) : Nil
      ids = {} of Int64 => String
      created.each { |txn| YNAB.marker_id(txn.memo || "").try { |expense_id| ids[expense_id] = txn.id } }
      now = @now.call
      rows = wants.map do |want|
        if txn_id = ids[want.expense_id]?
          @result.created += 1
          Store::YNABSync.synced(want.expense_id, pid, txn_id, want.fingerprint, now)
        else
          @result.failed += 1
          @result.again = true
          Store::YNABSync.pending(want.expense_id, pid, "YNAB hat das Anlegen nicht bestätigt.")
        end
      end
      @store.put_ynab_sync(rows)
    end

    private def create_each(wants : Array(Want)) : Nil
      succeeded = false
      wants.each_with_index do |want, i|
        if i >= MAX_SINGLE
          @result.again = true
          return unmark_pending(wants[i..])
        end
        begin
          created = @client.create_transactions(plan_id, [want.new_txn(@connection.account_id)])
        rescue ex
          failure = Failure.of(ex)
          if failure.unclear?
            unmark_pending(wants[i + 1..]) # not tried yet
            raise ex
          elsif failure.aborts_run?
            unmark_pending(wants[i..])
            raise ex
          end
          @result.failed += 1
          @store.put_ynab_sync(failed_row(want, nil, ex))
          # Everything fails the same way (e.g. account closed): do not try
          # the rest one by one, defer it until the full sync.
          return fail_all(wants[i + 1..].map { |w| {w, nil.as(String?)} }, ex) if !succeeded && i + 1 >= SYSTEMIC_FAILURES
          next
        end
        succeeded = true
        apply_created([want], created)
      end
    end

    private def update(updates : Array(Update)) : Nil
      updates.each_slice(CHUNK_SIZE) do |chunk|
        begin
          updated = @client.update_transactions(plan_id, chunk.map { |u| u.want.patch_txn(u.txn_id) })
        rescue ex
          failure = Failure.of(ex)
          raise ex if failure.aborts_run? && !failure.not_found?
          update_each(chunk)
          next
        end
        apply_updated(chunk, updated)
      end
    end

    private def apply_updated(updates : Array(Update), updated : Array(APITxn)) : Nil
      by_id = updated.to_h { |txn| {txn.id, txn} }
      now = @now.call
      rows = updates.map do |update|
        want, txn = update.want, by_id[update.txn_id]?
        if txn.nil?
          @result.failed += 1
          Store::YNABSync.failed(want.expense_id, pid, update.txn_id, want.fingerprint, "YNAB hat die Änderung nicht bestätigt.")
        elsif txn.deleted
          # deleted by hand in YNAB: create it again (the app is authoritative)
          @result.again = true
          Store::YNABSync.new(want.expense_id, pid)
        else
          @result.updated += 1
          Store::YNABSync.synced(want.expense_id, pid, update.txn_id, want.fingerprint, now)
        end
      end
      @store.put_ynab_sync(rows)
    end

    private def update_each(updates : Array(Update)) : Nil
      succeeded = false
      updates.each_with_index do |update, i|
        if i >= MAX_SINGLE
          @result.again = true
          return
        end
        want = update.want
        begin
          updated = @client.update_transactions(plan_id, [want.patch_txn(update.txn_id)])
        rescue ex
          failure = Failure.of(ex)
          if failure.not_found?
            confirm_target
            succeeded = true
            @result.again = true
            @store.put_ynab_sync(Store::YNABSync.new(want.expense_id, pid))
            next
          end
          raise ex if failure.aborts_run?
          @result.failed += 1
          @store.put_ynab_sync(failed_row(want, update.txn_id, ex))
          return fail_all(updates[i + 1..].map { |u| {u.want, u.txn_id.as(String?)} }, ex) if !succeeded && i + 1 >= SYSTEMIC_FAILURES
          next
        end
        succeeded = true
        apply_updated([update], updated)
      end
    end

    private def remove(rows : Array(Store::YNABSync)) : Nil
      rows.each_with_index do |row, i|
        if i >= MAX_DELETES
          @result.again = true
          return
        end
        txn_id = row.txn_id.not_nil!
        error = begin
          @client.delete_transaction(plan_id, txn_id)
          nil
        rescue ex
          ex
        end
        if error && Failure.of(error).not_found?
          confirm_target
          error = nil # already deleted in YNAB
        end
        if error
          raise error if Failure.of(error).aborts_run?
          @result.failed += 1
          @store.put_ynab_sync(row.delete_failed(YNAB.redact(error.message || "", @connection.token)))
          next
        end
        @result.deleted += 1
        @store.delete_ynab_sync(pid, row.expense_id)
      end
    end

    # Checks, once per run with one request, that plan and account exist
    # before a 404 for a single transaction is taken as "the transaction is
    # gone". YNAB answers 404 for every transaction as well if the whole plan
    # is gone or invisible to the token (token of another YNAB user);
    # dropping transaction IDs or counting DELETEs as done would then lead to
    # duplicates and leftovers once the setup is corrected. Its error stops
    # the run.
    private def confirm_target : Nil
      return if @target_confirmed
      raise APIError.new(404, detail: "Konto gelöscht") if @client.account(plan_id, @connection.account_id).deleted
      @target_confirmed = true
    end

    private def fail_all(wants : Array({Want, String?}), error : Exception) : Nil
      @result.failed += wants.size
      @store.put_ynab_sync(wants.map { |want, txn_id| failed_row(want, txn_id, error) })
    end

    private def failed_row(want : Want, txn_id : String?, error : Exception | String) : Store::YNABSync
      message = error.is_a?(String) ? error : error.message || ""
      Store::YNABSync.failed(want.expense_id, pid, txn_id, want.fingerprint, YNAB.redact(message, @connection.token))
    end
  end
end
