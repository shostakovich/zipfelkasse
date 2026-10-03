module Zipfelkasse
  class Store
    record YNABConfig,
      participant_id : Int64,
      token : String?,
      plan_id : String?,
      account_id : String?,
      start_date : Time?,
      # Since when plan and account are chosen: expenses entered later go to YNAB even if dated before start_date.
      connected_at : Time? do
      include DB::Serializable

      @[DB::Field(key: "budget_id")]
      @plan_id : String?
      @[DB::Field(converter: Zipfelkasse::Store::DateText)]
      @start_date : Time?
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @connected_at : Time?

      def connection : {token: String, plan_id: String, account_id: String}?
        token, plan_id, account_id = self.token, self.plan_id, self.account_id
        {token: token, plan_id: plan_id, account_id: account_id} if token && plan_id && account_id && start_date
      end

      def ready? : Bool
        !connection.nil?
      end

      def inspect(io : IO) : Nil
        io << "YNABConfig(participant_id=" << participant_id << ", token=" << (token ? "[redacted]" : "none")
        io << ", plan_id=" << plan_id.inspect << ", account_id=" << account_id.inspect << ")"
      end
    end

    YNAB_CONFIG_COLS = "participant_id, token, budget_id, account_id, start_date, connected_at"

    def get_ynab_config?(participant_id : Int64, db : DB::QueryMethods = @db) : YNABConfig?
      db.query_one?("SELECT #{YNAB_CONFIG_COLS} FROM ynab_config WHERE participant_id = ?", participant_id, as: YNABConfig)
    end

    def get_ynab_config(participant_id : Int64, db : DB::QueryMethods = @db) : YNABConfig
      get_ynab_config?(participant_id, db) || raise NotFound.new
    end

    def list_ynab_configs : Array(YNABConfig)
      @db.query_all("SELECT #{YNAB_CONFIG_COLS} FROM ynab_config WHERE token IS NOT NULL " \
                    "AND participant_id IN (SELECT id FROM participants WHERE archived_at IS NULL) ORDER BY participant_id",
        as: YNABConfig)
    end

    # nil or "" disconnects; plan, account, mapping and sync state stay, so that reconnecting creates no duplicates.
    # True if plan_ids (the plans the new token reaches) lacks the chosen plan: plan and account are reset then.
    def set_ynab_token(participant_id : Int64, token : String?, plan_ids : Set(String)? = nil) : Bool
      token = token.presence
      transaction do |tx|
        old = get_ynab_config?(participant_id, tx)
        tx.exec("INSERT INTO ynab_config (participant_id, token, updated_at) VALUES (?, ?, ?) " \
                "ON CONFLICT (participant_id) DO UPDATE SET token = excluded.token, updated_at = excluded.updated_at, " \
                "token_invalid = 0, error = NULL, retry_at = NULL, backoff_seconds = 0",
          participant_id, token, now_string)
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
      connected = nil.as(String?)
      if old.plan_id != plan_id || old.account_id != account_id
        tx.exec("UPDATE ynab_sync SET ynab_txn_id = NULL, state = 'retarget', fingerprint = NULL, synced_at = NULL, " \
                "last_error = NULL WHERE participant_id = ?", participant_id)
        connected = now_string
      end
      tx.exec("UPDATE ynab_config SET budget_id = ?, account_id = ?, start_date = ?, updated_at = ?, " \
              "connected_at = coalesce(?, connected_at) WHERE participant_id = ?",
        plan_id, account_id, start.try { |d| Store.format_date(d) }, now_string, connected, participant_id)
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
      last_run : Time? = nil,
      last_sync : Time? = nil,
      summary : String? = nil,
      error : String? = nil,
      token_invalid : Bool = false,
      retry_at : Time? = nil,
      backoff : Time::Span = Time::Span.zero do
      include DB::Serializable

      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @last_run : Time?
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @last_sync : Time?
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
          Store.status_time(st.last_run), Store.status_time(st.last_sync), st.summary, st.error,
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

    # Pending: creating is in progress or its outcome unknown; Retarget: plan or account changed. Both are looked up by
    # the memo marker instead of created again. Failed (this fingerprint) and DeleteFailed wait for the full sync.
    enum YNABSyncState
      Unknown
      Synced
      Pending
      Retarget
      Failed
      DeleteFailed
    end

    module YNABSyncStateText
      def self.from_rs(rs : DB::ResultSet) : YNABSyncState
        YNABSyncState.parse(rs.read(String))
      end
    end

    record YNABSync,
      expense_id : Int64,
      participant_id : Int64,
      txn_id : String? = nil,
      state : YNABSyncState = Zipfelkasse::Store::YNABSyncState::Unknown,
      fingerprint : String? = nil,
      synced_at : Time? = nil,
      last_error : String? = nil do
      include DB::Serializable

      @[DB::Field(key: "ynab_txn_id")]
      @txn_id : String?
      @[DB::Field(converter: Zipfelkasse::Store::YNABSyncStateText)]
      @state : YNABSyncState
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @synced_at : Time?

      def self.pending(expense_id : Int64, participant_id : Int64, error : String? = nil) : YNABSync
        new(expense_id, participant_id, state: YNABSyncState::Pending, last_error: error)
      end

      def self.synced(expense_id : Int64, participant_id : Int64, txn_id : String, fingerprint : String, at : Time) : YNABSync
        new(expense_id, participant_id, txn_id, YNABSyncState::Synced, fingerprint, at)
      end

      def self.failed(expense_id : Int64, participant_id : Int64, txn_id : String?, fingerprint : String, error : String) : YNABSync
        new(expense_id, participant_id, txn_id, YNABSyncState::Failed, fingerprint, last_error: error)
      end

      def at?(state : YNABSyncState, fingerprint : String) : Bool
        self.state == state && self.fingerprint == fingerprint
      end
    end

    def list_ynab_sync(participant_id : Int64) : Array(YNABSync)
      @db.query_all("SELECT expense_id, participant_id, ynab_txn_id, state, fingerprint, synced_at, last_error " \
                    "FROM ynab_sync WHERE participant_id = ? ORDER BY expense_id", participant_id, as: YNABSync)
    end

    def put_ynab_sync(*rows : YNABSync) : Nil
      put_ynab_sync(rows.to_a)
    end

    def put_ynab_sync(rows : Array(YNABSync)) : Nil
      return if rows.empty?
      transaction do |tx|
        rows.each do |r|
          tx.exec("INSERT INTO ynab_sync (expense_id, participant_id, ynab_txn_id, state, fingerprint, synced_at, last_error) " \
                  "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (expense_id, participant_id) DO UPDATE SET " \
                  "ynab_txn_id = excluded.ynab_txn_id, state = excluded.state, fingerprint = excluded.fingerprint, " \
                  "synced_at = excluded.synced_at, last_error = excluded.last_error",
            r.expense_id, r.participant_id, r.txn_id, r.state.to_s.underscore, r.fingerprint,
            r.synced_at.try { |t| Store.format_time(t) }, r.last_error)
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
      synced = @db.scalar("SELECT count(*) FROM ynab_sync WHERE participant_id = ? AND ynab_txn_id IS NOT NULL",
        participant_id).as(Int64).to_i32
      problems = @db.query_all("SELECT y.expense_id, e.title, e.date, y.last_error AS error FROM ynab_sync y " \
                               "JOIN expenses e ON e.id = y.expense_id WHERE y.participant_id = ? AND y.last_error IS NOT NULL " \
                               "ORDER BY e.date DESC, e.id DESC", participant_id, as: YNABSyncProblem)
      {synced, problems}
    end
  end
end
