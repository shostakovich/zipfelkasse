module Zipfelkasse
  class Store
    module NilIfEmpty
      def self.from_rs(rs : DB::ResultSet) : String?
        rs.read(String?).presence
      end
    end

    record YNABConfig,
      participant_id : Int64,
      token : String?,
      plan_id : String?,
      account_id : String?,
      start_date : Time?, # expenses from this date on
      enabled : Bool,
      updated_at : Time?,
      # Since when plan and account have been chosen. Expenses entered after
      # that go to YNAB even if their date is before start_date. nil =
      # unknown (see ensure_ynab_connected_at).
      connected_at : Time? do
      include DB::Serializable

      @[DB::Field(converter: Zipfelkasse::Store::NilIfEmpty)]
      @token : String?
      @[DB::Field(key: "budget_id", converter: Zipfelkasse::Store::NilIfEmpty)]
      @plan_id : String?
      @[DB::Field(converter: Zipfelkasse::Store::NilIfEmpty)]
      @account_id : String?
      @[DB::Field(converter: Zipfelkasse::Store::DateText)]
      @start_date : Time?
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @updated_at : Time?
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @connected_at : Time?

      def enabled? : Bool
        enabled
      end

      def connection : YNABConnection?
        return unless enabled?
        token, plan_id, account_id, start_date = self.token, self.plan_id, self.account_id, self.start_date
        return unless token && plan_id && account_id && start_date
        YNABConnection.new(participant_id, token, plan_id, account_id, start_date)
      end

      def ready? : Bool
        !connection.nil?
      end

      def inspect(io : IO) : Nil
        io << "YNABConfig(participant_id=" << participant_id << ", token=" << (token ? "[redacted]" : "none")
        io << ", plan_id=" << plan_id.inspect << ", account_id=" << account_id.inspect << ", enabled=" << enabled << ")"
      end
    end

    record YNABConnection, participant_id : Int64, token : String, plan_id : String, account_id : String, start_date : Time

    YNAB_CONFIG_COLS = "participant_id, token, budget_id, account_id, start_date, enabled, updated_at, connected_at"

    def get_ynab_config?(participant_id : Int64, db : DB::QueryMethods = @db) : YNABConfig?
      db.query_one?("SELECT #{YNAB_CONFIG_COLS} FROM ynab_config WHERE participant_id = ?", participant_id, as: YNABConfig)
    end

    def get_ynab_config(participant_id : Int64, db : DB::QueryMethods = @db) : YNABConfig
      get_ynab_config?(participant_id, db) || raise NotFound.new
    end

    def list_ynab_configs : Array(YNABConfig)
      @db.query_all("SELECT #{YNAB_CONFIG_COLS} FROM ynab_config WHERE token != '' AND enabled = 1 " \
                    "AND participant_id IN (SELECT id FROM participants WHERE archived_at IS NULL) ORDER BY participant_id",
        as: YNABConfig)
    end

    # nil or "" disconnects; plan, account, mapping and sync state are kept so
    # that reconnecting to the same account creates no duplicates. Resets what
    # the status says about the old token. The result is true if plan_ids (the
    # plans the new token reaches) lacks the chosen plan (token of another
    # YNAB user): plan and account are reset then.
    def set_ynab_token(participant_id : Int64, token : String?, plan_ids : Set(String)? = nil) : Bool
      token = token.presence
      transaction do |tx|
        old = get_ynab_config?(participant_id, tx)
        tx.exec("INSERT INTO ynab_config (participant_id, token, enabled, updated_at) VALUES (?, ?, ?, ?) " \
                "ON CONFLICT (participant_id) DO UPDATE SET " \
                "token = excluded.token, enabled = excluded.enabled, updated_at = excluded.updated_at, " \
                "token_invalid = 0, error = '', retry_at = NULL, backoff_seconds = 0",
          participant_id, token || "", !token.nil?, now_string)
        old_plan = old.try(&.plan_id)
        target_reset = !token.nil? && !old_plan.nil? && !plan_ids.nil? && !plan_ids.includes?(old_plan)
        set_ynab_target(tx, participant_id, nil, nil, old.try(&.start_date)) if target_reset
        text = if token.nil?
                 "YNAB-Verbindung getrennt"
               elsif target_reset
                 "YNAB-Token ersetzt (Plan und Konto zurückgesetzt)"
               elsif old.try(&.token)
                 "YNAB-Token ersetzt"
               else
                 "YNAB verbunden (Token gesetzt)"
               end
        log_settings(tx, participant_id, text)
        target_reset
      end
    end

    record YNABTarget, plan_id : String, account_id : String, plan_name : String? = nil, account_name : String? = nil,
      start : Time? = nil

    def set_ynab_target(participant_id : Int64, t : YNABTarget) : Nil
      transaction do |tx|
        old = set_ynab_target(tx, participant_id, t.plan_id, t.account_id, t.start)
        if t.plan_id != old.plan_id || t.account_id != old.account_id
          log_settings(tx, participant_id, "YNAB: Konto „#{t.account_name.presence || t.account_id}“ im Plan " \
                                           "„#{t.plan_name.presence || t.plan_id}“ gewählt, Startdatum #{t.start.try { |d| Domain.format_date(d) }}")
        elsif t.start != old.start_date
          log_settings(tx, participant_id, "YNAB: Startdatum #{old.start_date.try { |d| Domain.format_date(d) } || "–"} → " \
                                           "#{t.start.try { |d| Domain.format_date(d) }}")
        end
      end
    end

    private def set_ynab_target(tx : DB::Connection, participant_id : Int64, plan_id : String?, account_id : String?,
                                start : Time?) : YNABConfig
      old = get_ynab_config(participant_id, tx)
      connected = nil.as(String?) # nil keeps connected_at
      if old.plan_id != plan_id || old.account_id != account_id
        tx.exec("UPDATE ynab_sync SET ynab_txn_id = '', synced_hash = ?, synced_at = NULL, last_error = '' " \
                "WHERE participant_id = ?", YNABSync::RETARGET, participant_id)
        connected = now_string
      end
      tx.exec("UPDATE ynab_config SET budget_id = ?, account_id = ?, start_date = ?, updated_at = ?, " \
              "connected_at = coalesce(?, connected_at) WHERE participant_id = ?",
        plan_id || "", account_id || "", start.try { |d| Store.format_date(d) }, now_string, connected, participant_id)
      old
    end

    def ensure_ynab_connected_at(participant_id : Int64) : Time?
      values = transaction do |tx|
        tx.query_all("UPDATE ynab_config SET connected_at = coalesce(connected_at, ?) WHERE participant_id = ? " \
                     "RETURNING connected_at", now_string, participant_id, as: String?)
      end
      raise NotFound.new if values.empty?
      values.first.try { |s| Time.parse_rfc3339(s) }
    end

    module SecondsSpan
      def self.from_rs(rs : DB::ResultSet) : Time::Span
        rs.read(Int64).seconds
      end
    end

    record YNABStatus,
      last_run : Time? = nil,  # last attempt
      last_sync : Time? = nil, # last complete sync
      summary : String? = nil,
      error : String? = nil, # of the last attempt, without token
      token_invalid : Bool = false,
      retry_at : Time? = nil,                   # no requests before this
      backoff : Time::Span = Time::Span.zero do # last delay after 429, whole seconds
      include DB::Serializable

      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @last_run : Time?
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @last_sync : Time?
      @[DB::Field(converter: Zipfelkasse::Store::NilIfEmpty)]
      @summary : String?
      @[DB::Field(converter: Zipfelkasse::Store::NilIfEmpty)]
      @error : String?
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @retry_at : Time?
      @[DB::Field(key: "backoff_seconds", converter: Zipfelkasse::Store::SecondsSpan)]
      @backoff : Time::Span

      def token_invalid? : Bool
        token_invalid
      end
    end

    def get_ynab_status(participant_id : Int64) : YNABStatus
      @db.query_one?("SELECT last_run, last_sync, summary, error, token_invalid, retry_at, backoff_seconds " \
                     "FROM ynab_config WHERE participant_id = ?", participant_id, as: YNABStatus) || raise NotFound.new
    end

    def set_ynab_status(participant_id : Int64, st : YNABStatus) : Nil
      transaction do |tx|
        Store.check_affected(tx.exec("UPDATE ynab_config SET last_run = ?, last_sync = ?, summary = ?, error = ?, " \
                                     "token_invalid = ?, retry_at = ?, backoff_seconds = ? WHERE participant_id = ?",
          Store.status_time(st.last_run), Store.status_time(st.last_sync), st.summary || "", st.error || "",
          st.token_invalid?, Store.status_time(st.retry_at), st.backoff.to_i, participant_id))
      end
    end

    # With fractional seconds (trailing zeros dropped) so that retry_at
    # survives exactly.
    protected def self.status_time(t : Time?) : String?
      return unless t
      t = t.to_utc
      s = t.to_s("%Y-%m-%dT%H:%M:%S")
      s += "." + ("%09d" % t.nanosecond).rstrip('0') if t.nanosecond > 0
      s + "Z"
    end

    def ynab_category_map(participant_id : Int64, db : DB::QueryMethods = @db) : Hash(Int64, String)
      db.query_all("SELECT category_id, ynab_category_id FROM ynab_category_map WHERE participant_id = ?",
        participant_id, as: {Int64, String}).to_h
    end

    def set_ynab_category_map(participant_id : Int64, m : Hash(Int64, String),
                              ynab_names : Hash(String, String) = {} of String => String) : Nil
      transaction do |tx|
        old = ynab_category_map(participant_id, tx)
        tx.exec("DELETE FROM ynab_category_map WHERE participant_id = ?", participant_id)
        m.each do |category_id, ynab_id|
          next if ynab_id.empty?
          raise Domain::ValidationError.new("Unbekannte Kategorie.") unless get_category?(category_id, tx)
          tx.exec("INSERT INTO ynab_category_map (participant_id, category_id, ynab_category_id) VALUES (?, ?, ?)",
            participant_id, category_id, ynab_id)
        end
        text = mapping_changes(tx, old, m, ynab_names)
        log_settings(tx, participant_id, "YNAB: Kategorie-Zuordnung geändert (#{text})") unless text.empty?
      end
    end

    # "Lebensmittel → Lebensmittel & Drogerie, Kino → unkategorisiert (vorher
    # Freizeit)", in the order of the app categories (archived ones included).
    private def mapping_changes(tx : DB::Connection, old : Hash(Int64, String), now : Hash(Int64, String),
                                ynab_names : Hash(String, String)) : String
      ynab_name = ->(id : String) do
        id.empty? ? "unkategorisiert" : (ynab_names[id]?.presence || "(nicht mehr vorhanden)")
      end
      parts = [] of String
      list_categories(true, tx).each do |category|
        o, n = old[category.id]? || "", now[category.id]? || ""
        next if o == n
        part = "#{category.name} → #{ynab_name.call(n)}"
        part += " (vorher #{ynab_name.call(o)})" unless o.empty?
        parts << part
      end
      parts.join(", ")
    end

    # Sync state of an expense for a person. synced_hash holds the state:
    #   - the fingerprint of the last transferred state (see YNAB::Want)
    #   - "error:" + fingerprint: transferring this state failed; it is retried
    #     only on change, in the hourly full sync or via "Jetzt synchronisieren"
    #   - "error:delete": deleting the transaction (expense gone) failed; it is
    #     retried only in the full sync
    #   - "pending": creation is in progress or its outcome is unknown (timeout,
    #     5xx); the next run looks the transaction up via the memo marker
    #     instead of creating it again
    #   - "retarget" (without transaction ID): plan or account changed; like
    #     "pending", but only for expenses that belong to the new account
    #   - nil: unknown; forces a create (no transaction) or a PATCH
    # A txn_id of nil means there is (as far as we know) no transaction in YNAB.
    record YNABSync,
      expense_id : Int64,
      participant_id : Int64,
      txn_id : String? = nil,
      synced_hash : String? = nil,
      synced_at : Time? = nil, # nil = never succeeded
      last_error : String? = nil do
      include DB::Serializable

      PENDING       = "pending"
      RETARGET      = "retarget"
      ERROR_PREFIX  = "error:"
      DELETE_FAILED = ERROR_PREFIX + "delete"

      @[DB::Field(key: "ynab_txn_id", converter: Zipfelkasse::Store::NilIfEmpty)]
      @txn_id : String?
      @[DB::Field(converter: Zipfelkasse::Store::NilIfEmpty)]
      @synced_hash : String?
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @synced_at : Time?
      @[DB::Field(converter: Zipfelkasse::Store::NilIfEmpty)]
      @last_error : String?

      def self.pending(expense_id : Int64, participant_id : Int64, error : String? = nil) : YNABSync
        new(expense_id, participant_id, synced_hash: PENDING, last_error: error)
      end

      def self.synced(expense_id : Int64, participant_id : Int64, txn_id : String, fingerprint : String, at : Time) : YNABSync
        new(expense_id, participant_id, txn_id, fingerprint, at)
      end

      def self.failed(expense_id : Int64, participant_id : Int64, txn_id : String?, fingerprint : String, error : String) : YNABSync
        new(expense_id, participant_id, txn_id, ERROR_PREFIX + fingerprint, last_error: error)
      end

      def delete_failed(error : String) : YNABSync
        copy_with(synced_hash: DELETE_FAILED, last_error: error)
      end

      def unknown(txn_id : String? = nil) : YNABSync
        YNABSync.new(expense_id, participant_id, txn_id)
      end

      def pending? : Bool
        synced_hash == PENDING
      end

      def retarget? : Bool
        synced_hash == RETARGET
      end

      def unresolved? : Bool
        txn_id.nil? && (pending? || retarget?)
      end

      def failed_at?(fingerprint : String) : Bool
        synced_hash == ERROR_PREFIX + fingerprint
      end

      def delete_failed? : Bool
        synced_hash == DELETE_FAILED
      end

      def current?(fingerprint : String) : Bool
        synced_hash == fingerprint
      end

      def in_ynab? : Bool
        !txn_id.nil? || pending?
      end
    end

    def list_ynab_sync(participant_id : Int64) : Array(YNABSync)
      @db.query_all("SELECT expense_id, participant_id, ynab_txn_id, synced_hash, synced_at, last_error " \
                    "FROM ynab_sync WHERE participant_id = ? ORDER BY expense_id", participant_id, as: YNABSync)
    end

    def put_ynab_sync(*rows : YNABSync) : Nil
      put_ynab_sync(rows.to_a)
    end

    def put_ynab_sync(rows : Array(YNABSync)) : Nil
      return if rows.empty?
      transaction do |tx|
        rows.each do |r|
          tx.exec("INSERT INTO ynab_sync (expense_id, participant_id, ynab_txn_id, synced_hash, synced_at, last_error) " \
                  "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (expense_id, participant_id) DO UPDATE SET " \
                  "ynab_txn_id = excluded.ynab_txn_id, synced_hash = excluded.synced_hash, " \
                  "synced_at = excluded.synced_at, last_error = excluded.last_error",
            r.expense_id, r.participant_id, r.txn_id || "", r.synced_hash || "", r.synced_at.try { |t| Store.format_time(t) },
            r.last_error || "")
        end
      end
    end

    def delete_ynab_sync(participant_id : Int64, *expense_ids : Int64) : Nil
      delete_ynab_sync(participant_id, expense_ids.to_a)
    end

    def delete_ynab_sync(participant_id : Int64, expense_ids : Array(Int64)) : Nil
      return if expense_ids.empty?
      transaction do |tx|
        expense_ids.each do |id|
          tx.exec("DELETE FROM ynab_sync WHERE participant_id = ? AND expense_id = ?", participant_id, id)
        end
      end
    end

    record YNABSyncProblem, expense_id : Int64, title : String, date : Time, error : String do
      include DB::Serializable

      @[DB::Field(converter: Zipfelkasse::Store::DateText)]
      @date : Time
    end

    def ynab_sync_summary(participant_id : Int64) : {Int32, Array(YNABSyncProblem)}
      synced = @db.scalar("SELECT count(*) FROM ynab_sync WHERE participant_id = ? AND ynab_txn_id != ''",
        participant_id).as(Int64).to_i32
      problems = @db.query_all("SELECT y.expense_id, e.title, e.date, y.last_error AS error FROM ynab_sync y " \
                               "JOIN expenses e ON e.id = y.expense_id WHERE y.participant_id = ? AND y.last_error != '' " \
                               "ORDER BY e.date DESC, e.id DESC", participant_id, as: YNABSyncProblem)
      {synced, problems}
    end
  end
end
