require "set"

module Zipfelkasse::YNAB
  record Posting,
    expense_id : Int64,
    date : Time,
    amount_cents : Int64, # positive = outflow
    payee : String,
    memo : String,
    category_id : Int64? do
    def milliunits : Int64
      -amount_cents * 10
    end
  end

  # Reimbursements go through the bank as transfers in YNAB.
  def self.posting_for(e : Store::Expense, participant_id : Int64) : Posting?
    return if e.deleted? || e.reimbursement?
    share = e.share_of(participant_id)
    return if share <= 0
    Posting.new(e.id, e.date, share, truncate(e.title, MAX_PAYEE_LEN), memo(e), e.category_id)
  end

  # Sync and export use the same rule, so both yield the same balance of "Geteilt": an expense dated up to today
  # belongs if it is dated on or after start, was entered after the setup (connected_at), or is already in YNAB.
  # Without start, all past expenses count.
  struct Selection
    getter start : Time?
    getter connected_at : Time?
    getter today : Time
    getter in_ynab : Set(Int64)

    def initialize(@today, @start = nil, @connected_at = nil, @in_ynab = Set(Int64).new)
    end

    def self.for_config(store : Store, cfg : Store::YNABConfig, connected_at : Time?, today : Time) : Selection
      start = cfg.start_date
      return new(today) if start.nil? || cfg.account_id.nil?
      in_ynab = store.list_ynab_sync(cfg.participant_id).select { |row| row.txn_id || row.state.pending? }.to_set(&.expense_id)
      new(today, start, connected_at, in_ynab)
    end

    def self.for_participant(store : Store, participant_id : Int64, today : Time) : Selection
      cfg = store.get_ynab_config?(participant_id) || return new(today)
      for_config(store, cfg, cfg.connected_at, today)
    end

    def includes?(e : Store::Expense, p : Posting) : Bool
      return false if p.date > today
      start = @start
      return true if start.nil? || p.date >= start
      connected, created = @connected_at, e.created_at
      return true if connected && created && created >= connected
      in_ynab.includes?(e.id)
    end

    def postings(es : Array(Store::Expense), participant_id : Int64) : Array(Posting)
      es.compact_map { |e| YNAB.posting_for(e, participant_id).try { |p| p if includes?(e, p) } }
        .sort_by! { |p| {p.date, p.expense_id} }
    end
  end

  # German, as it lands in the user's budget; the sync recognizes its own transactions by the marker at the end.
  def self.memo(e : Store::Expense) : String
    total = "Gesamt " + Domain.format_cents(e.amount_cents)
    total += " (#{Domain.format_money(e.original_amount_minor, e.original_currency)})" if e.foreign?
    suffix = " · " + marker(e.id)
    head = total + " · bezahlt von " + e.paid_by_name
    truncate(head, MAX_MEMO_LEN - suffix.size) + suffix
  end

  MARKER_PREFIX = "zipfelkasse #"

  def self.marker(expense_id : Int64) : String
    MARKER_PREFIX + expense_id.to_s
  end

  # \z and explicit classes: the marker must end the memo, with ASCII digits and spaces only.
  MARKER_RE = /zipfelkasse #([0-9]+)[ \t\n\f\r]*\z/

  def self.marker_id(memo : String) : Int64?
    MARKER_RE.match(memo).try(&.[1].to_i64?)
  end

  def self.truncate(s : String, n : Int32) : String
    return s if s.size <= n
    return s[0, Math.max(n, 0)] if n <= 1
    s[0, n - 1] + "…"
  end
end
