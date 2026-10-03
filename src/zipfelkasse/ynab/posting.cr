require "set"

module Zipfelkasse::YNAB
  # A person's share of an expense as an outflow in the clearing account
  # "Geteilt". The sync writes the same transactions to YNAB that the export
  # delivers as OFX/CSV.
  record Posting,
    expense_id : Int64,
    date : Time,
    amount_cents : Int64, # positive = outflow
    payee : String,
    memo : String,
    category_id : Int64? # app category

  # Nil for deleted expenses, reimbursements (those go through the bank as
  # transfers in YNAB) and expenses without an own share.
  def self.posting_for(e : Store::Expense, participant_id : Int64) : Posting?
    return if e.deleted? || e.reimbursement?
    share = e.share_of(participant_id)
    return if share <= 0
    Posting.new(e.id, e.date, share, truncate(e.title, MAX_PAYEE_LEN), memo(e), e.category_id)
  end

  # Which of a person's expenses belong in YNAB; sync and export use the same
  # rule so that both yield the same balance of "Geteilt". An expense belongs
  # if it has a posting dated no later than today (YNAB rejects future ones)
  # and
  #   - its date is on or after start, or
  #   - it was entered after the setup (created_at >= connected_at): the
  #     starting balance of "Geteilt" does not know it, even if backdated, or
  #   - it is already in YNAB: it stays even if its date moves before the
  #     start; it is only removed on deletion or share 0.
  #
  # Without start (YNAB not set up), all past expenses count.
  struct Selection
    getter start : Time?
    getter connected_at : Time?
    getter today : Time
    getter in_ynab : Set(Int64) # transaction exists in YNAB (or its creation is unclear)

    def initialize(@today, @start = nil, @connected_at = nil, @in_ynab = Set(Int64).new)
    end

    # A missing connected_at (connections from before it existed) becomes now.
    def self.for_config(store : Store, cfg : Store::YNABConfig, today : Time) : Selection
      start = cfg.start_date
      return new(today) if start.nil? || cfg.account_id.empty?
      connected = cfg.connected_at || store.ensure_ynab_connected_at(cfg.participant_id)
      in_ynab = Set(Int64).new
      store.list_ynab_sync(cfg.participant_id).each do |r|
        in_ynab << r.expense_id if !r.txn_id.empty? || r.synced_hash == PENDING_HASH
      end
      new(today, start, connected, in_ynab)
    end

    # Without a connection: all past expenses.
    def self.for_participant(store : Store, participant_id : Int64, today : Time) : Selection
      cfg = store.get_ynab_config?(participant_id) || return new(today)
      for_config(store, cfg, today)
    end

    def includes?(e : Store::Expense, p : Posting) : Bool
      return false if p.date > today
      start = @start
      return true if start.nil? || p.date >= start
      connected, created = @connected_at, e.created_at
      return true if connected && created && created >= connected
      in_ynab.includes?(e.id)
    end

    # Sorted by date, then expense ID.
    def postings(es : Array(Store::Expense), participant_id : Int64) : Array(Posting)
      es.compact_map { |e| YNAB.posting_for(e, participant_id).try { |p| p if includes?(e, p) } }
        .sort_by! { |p| {p.date, p.expense_id} }
    end
  end

  # The text is German (it lands in the user's budget). The marker is always
  # at the end; the sync recognizes its own transactions by it.
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

  # \z and explicit classes: the marker must end the memo, and digits and
  # spaces are ASCII only.
  MARKER_RE = /zipfelkasse #([0-9]+)[ \t\n\f\r]*\z/

  def self.marker_id(memo : String) : Int64?
    MARKER_RE.match(memo).try(&.[1].to_i64?)
  end

  # Counts characters (code points), with "…" at the end.
  def self.truncate(s : String, n : Int32) : String
    return s if s.size <= n
    return s[0, Math.max(n, 0)] if n <= 1
    s[0, n - 1] + "…"
  end
end
