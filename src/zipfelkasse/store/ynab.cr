module Zipfelkasse
  # Queries for the YNAB sync. Tables: ynab_config (connection and sync status
  # per person), ynab_category_map (app category → YNAB category per person)
  # and ynab_sync (sync state per expense and person).
  class Store
    # token is secret: never print or log it.
    struct YNABConfig
      getter participant_id : Int64
      getter token : String   # "" = not connected
      getter plan_id : String # column budget_id
      getter account_id : String
      getter start_date : Time? # expenses from this date on
      getter? enabled : Bool
      getter updated_at : Time?
      # Since when plan and account have been chosen. Expenses entered after
      # that go to YNAB even if their date is before start_date. nil = unknown
      # (legacy data, see ensure_ynab_connected_at).
      getter connected_at : Time?

      def initialize(@participant_id, @token, @plan_id, @account_id, @start_date, @enabled, @updated_at, @connected_at)
      end

      def ready? : Bool
        enabled? && !token.empty? && !plan_id.empty? && !account_id.empty? && !start_date.nil?
      end
    end

    YNAB_CONFIG_COLS = "participant_id, token, budget_id, account_id, start_date, enabled, updated_at, connected_at"

    protected def self.read_ynab_config(rs : DB::ResultSet) : YNABConfig
      pid, token, plan, account = rs.read(Int64), rs.read(String), rs.read(String), rs.read(String)
      start = rs.read(String?).try { |s| parse_date(s) unless s.empty? }
      YNABConfig.new(pid, token, plan, account, start, rs.read(Bool), parse_time(rs.read(String?)), parse_time(rs.read(String?)))
    end

    # Raises NotFound.
    def get_ynab_config(participant_id : Int64) : YNABConfig
      Store.get_ynab_config(@db, participant_id)
    end

    def self.get_ynab_config(db : DB::QueryMethods, participant_id : Int64) : YNABConfig
      db.query("SELECT #{YNAB_CONFIG_COLS} FROM ynab_config WHERE participant_id = ?", participant_id) do |rs|
        rs.each { return read_ynab_config(rs) }
      end
      raise NotFound.new
    end

    # Enabled connections with a token of non-archived people; whether they
    # are fully set up tells ready?.
    def list_ynab_configs : Array(YNABConfig)
      out = [] of YNABConfig
      @db.query("SELECT #{YNAB_CONFIG_COLS} FROM ynab_config WHERE token != '' AND enabled = 1 " \
                "AND participant_id IN (SELECT id FROM participants WHERE archived_at IS NULL) ORDER BY participant_id") do |rs|
        rs.each { out << Store.read_ynab_config(rs) }
      end
      out
    end

    # Sets or replaces the token; "" disconnects (plan, account, mapping and
    # sync state are kept so that reconnecting to the same account does not
    # create duplicates). The same write resets what the status says about
    # the old token; last_run, last_sync and summary stay.
    #
    # If reachable says the new token cannot reach the chosen plan (token of
    # another YNAB user), plan and account are reset and the result is true.
    # reachable runs inside the write transaction.
    def set_ynab_token(participant_id : Int64, token : String, reachable : (String -> Bool)? = nil) : Bool
      transaction do |tx|
        old = begin
          Store.get_ynab_config(tx, participant_id)
        rescue NotFound
          nil
        end
        tx.exec("INSERT INTO ynab_config (participant_id, token, enabled, updated_at) VALUES (?, ?, ?, ?) " \
                "ON CONFLICT (participant_id) DO UPDATE SET " \
                "token = excluded.token, enabled = excluded.enabled, updated_at = excluded.updated_at, " \
                "token_invalid = 0, error = '', retry_at = NULL, backoff_seconds = 0",
          participant_id, token, !token.empty?, now_string)
        target_reset = false
        if old && !token.empty? && !old.plan_id.empty? && reachable && !reachable.call(old.plan_id)
          target_reset = true
          set_ynab_target(tx, participant_id, "", "", old.start_date)
        end
        text = if token.empty?
                 "YNAB-Verbindung getrennt"
               elsif target_reset
                 "YNAB-Token ersetzt (Plan und Konto zurückgesetzt)"
               elsif old && !old.token.empty?
                 "YNAB-Token ersetzt"
               else
                 "YNAB verbunden (Token gesetzt)"
               end
        log_settings(tx, participant_id, text)
        target_reset
      end
    end

    # The names are only for the activity log ("" = the ID).
    record YNABTarget, plan_id : String, account_id : String, plan_name : String = "", account_name : String = "",
      start : Time? = nil

    # Raises NotFound without a connection. A change of plan or account
    # resets connected_at and marks the person's sync rows with
    # YNAB_HASH_RETARGET and without transaction ID: transactions in the old
    # account stay there, and the sync first looks for each expense in the
    # new account (it may be there already, e.g. after switching back).
    def set_ynab_target(participant_id : Int64, t : YNABTarget) : Nil
      transaction do |tx|
        old = set_ynab_target(tx, participant_id, t.plan_id, t.account_id, t.start)
        if t.plan_id != old.plan_id || t.account_id != old.account_id
          log_settings(tx, participant_id, "YNAB: Konto „#{t.account_name.presence || t.account_id}“ im Plan " \
                                           "„#{t.plan_name.presence || t.plan_id}“ gewählt, Startdatum #{Domain.format_date(t.start)}")
        elsif Store.optional_date(t.start) != Store.optional_date(old.start_date)
          log_settings(tx, participant_id, "YNAB: Startdatum #{Domain.format_date(old.start_date).presence || "–"} → " \
                                           "#{Domain.format_date(t.start)}")
        end
      end
    end

    # Returns the connection as it was before.
    private def set_ynab_target(tx : DB::Connection, participant_id : Int64, plan_id : String, account_id : String,
                                start : Time?) : YNABConfig
      old = Store.get_ynab_config(tx, participant_id)
      connected = nil.as(String?) # nil keeps connected_at
      if old.plan_id != plan_id || old.account_id != account_id
        tx.exec("UPDATE ynab_sync SET ynab_txn_id = '', synced_hash = ?, synced_at = NULL, last_error = '' " \
                "WHERE participant_id = ?", YNAB_HASH_RETARGET, participant_id)
        connected = now_string
      end
      tx.exec("UPDATE ynab_config SET budget_id = ?, account_id = ?, start_date = ?, updated_at = ?, " \
              "connected_at = coalesce(?, connected_at) WHERE participant_id = ?",
        plan_id, account_id, Store.optional_date(start), now_string, connected, participant_id)
      old
    end

    protected def self.optional_date(t : Time?) : String?
      t.try { |d| format_date(d) }
    end

    # Sets connected_at to now if it is still missing (connections from before
    # it was introduced). Raises NotFound without a connection.
    def ensure_ynab_connected_at(participant_id : Int64) : Time?
      values = transaction do |tx|
        tx.query_all("UPDATE ynab_config SET connected_at = coalesce(connected_at, ?) WHERE participant_id = ? " \
                     "RETURNING connected_at", now_string, participant_id, as: String?)
      end
      raise NotFound.new if values.empty?
      Store.parse_time(values.first)
    end

    # The meaning of the fields (and the language of summary and error) is
    # defined by the YNAB sync.
    struct YNABStatus
      property last_run : Time?  # last attempt
      property last_sync : Time? # last complete sync
      property summary : String
      property error : String # of the last attempt, without token
      property? token_invalid : Bool
      property retry_at : Time?     # no requests before this
      property backoff : Time::Span # last delay after 429, whole seconds

      def initialize(*, @last_run = nil, @last_sync = nil, @summary = "", @error = "", @token_invalid = false,
                     @retry_at = nil, @backoff = Time::Span.zero)
      end
    end

    # Raises NotFound without a connection.
    def get_ynab_status(participant_id : Int64) : YNABStatus
      @db.query("SELECT last_run, last_sync, summary, error, token_invalid, retry_at, backoff_seconds " \
                "FROM ynab_config WHERE participant_id = ?", participant_id) do |rs|
        rs.each do
          return YNABStatus.new(
            last_run: Store.parse_time(rs.read(String?)), last_sync: Store.parse_time(rs.read(String?)),
            summary: rs.read(String), error: rs.read(String), token_invalid: rs.read(Bool),
            retry_at: Store.parse_time(rs.read(String?)), backoff: rs.read(Int64).seconds)
        end
      end
      raise NotFound.new
    end

    # Raises NotFound without a connection.
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

    # App category ID → YNAB category ID.
    def ynab_category_map(participant_id : Int64) : Hash(Int64, String)
      Store.ynab_category_map(@db, participant_id)
    end

    def self.ynab_category_map(db : DB::QueryMethods, participant_id : Int64) : Hash(Int64, String)
      m = {} of Int64 => String
      db.query("SELECT category_id, ynab_category_id FROM ynab_category_map WHERE participant_id = ?", participant_id) do |rs|
        rs.each { m[rs.read(Int64)] = rs.read(String) }
      end
      m
    end

    # Replaces the person's complete mapping; empty values mean
    # uncategorized in YNAB. ynab_names (YNAB category ID → name) is only for
    # the activity log.
    def set_ynab_category_map(participant_id : Int64, m : Hash(Int64, String),
                              ynab_names : Hash(String, String) = {} of String => String) : Nil
      transaction do |tx|
        old = Store.ynab_category_map(tx, participant_id)
        tx.exec("DELETE FROM ynab_category_map WHERE participant_id = ?", participant_id)
        m.each do |category_id, ynab_id|
          next if ynab_id.empty?
          if tx.scalar("SELECT count(*) FROM categories WHERE id = ?", category_id).as(Int64) == 0
            raise Domain::ValidationError.new("Unbekannte Kategorie.")
          end
          tx.exec("INSERT INTO ynab_category_map (participant_id, category_id, ynab_category_id) VALUES (?, ?, ?)",
            participant_id, category_id, ynab_id)
        end
        text = Store.mapping_changes(tx, old, m, ynab_names)
        log_settings(tx, participant_id, "YNAB: Kategorie-Zuordnung geändert (#{text})") unless text.empty?
      end
    end

    # "Lebensmittel → Lebensmittel & Drogerie, Kino → unkategorisiert (vorher
    # Freizeit)", in the order of the app categories (archived ones included).
    protected def self.mapping_changes(tx : DB::Connection, old : Hash(Int64, String), now : Hash(Int64, String),
                                       ynab_names : Hash(String, String)) : String
      ynab_name = ->(id : String) do
        id.empty? ? "unkategorisiert" : (ynab_names[id]?.presence || "(nicht mehr vorhanden)")
      end
      parts = [] of String
      tx.query("SELECT id, name FROM categories ORDER BY position, name COLLATE NOCASE, id") do |rs|
        rs.each do
          id, name = rs.read(Int64), rs.read(String)
          o, n = old[id]? || "", now[id]? || ""
          next if o == n
          part = "#{name} → #{ynab_name.call(n)}"
          part += " (vorher #{ynab_name.call(o)})" unless o.empty?
          parts << part
        end
      end
      parts.join(", ")
    end

    # Sync state of an expense for a person. txn_id "" means there is (as far
    # as we know) no transaction in YNAB. synced_hash is the fingerprint of the
    # last transferred state; its meaning is defined by the YNAB sync (except
    # YNAB_HASH_RETARGET).
    struct YNABSync
      property expense_id : Int64
      property participant_id : Int64
      property txn_id : String
      property synced_hash : String
      property synced_at : Time? # nil = never succeeded
      property last_error : String

      def initialize(@expense_id, @participant_id, @txn_id = "", @synced_hash = "", @synced_at = nil, @last_error = "")
      end
    end

    # synced_hash of sync rows after a change of plan or account.
    YNAB_HASH_RETARGET = "retarget"

    def list_ynab_sync(participant_id : Int64) : Array(YNABSync)
      out = [] of YNABSync
      @db.query("SELECT expense_id, participant_id, ynab_txn_id, synced_hash, synced_at, last_error " \
                "FROM ynab_sync WHERE participant_id = ? ORDER BY expense_id", participant_id) do |rs|
        rs.each do
          out << YNABSync.new(rs.read(Int64), rs.read(Int64), rs.read(String), rs.read(String),
            Store.parse_time(rs.read(String?)), rs.read(String))
        end
      end
      out
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
            r.expense_id, r.participant_id, r.txn_id, r.synced_hash, r.synced_at.try(&.to_utc.to_s(TIME_FORMAT)), r.last_error)
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

    record YNABSyncProblem, expense_id : Int64, title : String, date : Time, error : String

    # The number of the person's transactions present in YNAB and the
    # expenses whose last sync failed (newest first, deleted ones included).
    def ynab_sync_summary(participant_id : Int64) : {Int32, Array(YNABSyncProblem)}
      synced = @db.scalar("SELECT count(*) FROM ynab_sync WHERE participant_id = ? AND ynab_txn_id != ''",
        participant_id).as(Int64).to_i32
      problems = [] of YNABSyncProblem
      @db.query("SELECT y.expense_id, e.title, e.date, y.last_error FROM ynab_sync y JOIN expenses e ON e.id = y.expense_id " \
                "WHERE y.participant_id = ? AND y.last_error != '' ORDER BY e.date DESC, e.id DESC", participant_id) do |rs|
        rs.each do
          problems << YNABSyncProblem.new(rs.read(Int64), rs.read(String), Store.parse_date(rs.read(String)), rs.read(String))
        end
      end
      {synced, problems}
    end
  end
end
