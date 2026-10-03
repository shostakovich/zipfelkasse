require "json"

module Zipfelkasse::MCP
  # The no-category value of statistics rows and of the category arguments.
  NO_CATEGORY_ARG   = "none"
  NO_CATEGORY_LABEL = "No category"

  # The tool results. Fields that are nil are left out; every amount appears
  # as text ("1234.56") and in cents.
  record BalanceOut, person : String, balance : String, balance_cents : Int64, status : String? = nil do
    include JSON::Serializable

    def self.of(person : String, cents : Int64, status : String? = nil) : BalanceOut
      new(person, MCP.eur(cents), cents, status)
    end
  end

  record SettlementOut, from : String, to : String, amount : String, amount_cents : Int64 do
    include JSON::Serializable

    def self.of(from : String, to : String, cents : Int64) : SettlementOut
      new(from, to, MCP.eur(cents), cents)
    end
  end

  record BalancesOut, balances : Array(BalanceOut), note : String, settlements : Array(SettlementOut) do
    include JSON::Serializable
  end

  # The period is a field named after the interval ("month", "week", "year").
  record HistoryRow, interval : Domain::PeriodUnit, label : String, balances : Array(BalanceOut) do
    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field interval.to_s.underscore, label
        json.field "balances", balances
      end
    end
  end

  record HistoryOut, interval : String, note : String, period : String, rows : Array(HistoryRow) do
    include JSON::Serializable
  end

  record ShareOut, person : String, amount : String, amount_cents : Int64 do
    include JSON::Serializable
  end

  # Without full only the compact fields (no split, shares, notes and foreign
  # currency).
  struct ExpenseOut
    include JSON::Serializable

    getter id : Int64
    getter date : String
    getter title : String
    getter category : String?
    getter paid_by : String
    getter amount : String
    getter amount_cents : Int64
    getter reimbursement : Bool?
    getter recipient : String?
    getter original : String?
    getter fx_rate : Float64?
    getter fx_source : String?
    getter notes : String?
    getter split : String?
    getter shares : Array(ShareOut)?

    def initialize(e : Store::Expense, names : Hash(Int64, String), full : Bool)
      @id, @title, @category, @paid_by = e.id, e.title, e.category_name, e.paid_by_name
      @date = Store.format_date(e.date)
      @amount, @amount_cents = MCP.eur(e.amount_cents), e.amount_cents
      if e.reimbursement?
        @reimbursement = true
        @recipient = e.shares.first?.try { |s| names[s.participant_id]? }
      end
      return unless full
      if e.foreign?
        @original = MCP.money(e.original_amount_minor, e.original_currency)
        @fx_rate = e.fx_rate unless e.fx_rate == 0
        @fx_source = e.fx_source.try(&.key)
      end
      @notes = e.notes.presence
      return if e.reimbursement?
      @split = e.split_mode.key
      @shares = e.shares.map { |s| ShareOut.new(names[s.participant_id]? || "", MCP.eur(s.amount_cents), s.amount_cents) } unless e.shares.empty?
    end
  end

  record PersonShareOut, amount : String, amount_cents : Int64, person : String do
    include JSON::Serializable
  end

  record SearchOut, expenses : Array(ExpenseOut), matches : Int32, person_share : PersonShareOut?, shown : Int32,
    total : String, total_cents : Int64, truncated : Bool do
    include JSON::Serializable
  end

  struct StatLine
    include JSON::Serializable

    getter category : String?
    getter title : String?
    getter year : String?
    getter month : String?
    getter week : String?
    getter person : String?
    getter count : Int64
    getter amount : String
    getter amount_cents : Int64
    getter paid : String?
    getter paid_cents : Int64?
    getter previous : String?
    getter previous_cents : Int64?
    getter change : String?
    getter change_cents : Int64?
    getter change_percent : Float64?

    def initialize(row : Store::StatRow, group : Store::StatsGroup, previous : Int64? = nil)
      @category = row.category || NO_CATEGORY_LABEL if group.category? || group.category_month?
      @title, @person = row.title, row.person
      case group
      when .year?                    then @year = row.period
      when .week?                    then @week = row.period
      when .month?, .category_month? then @month = row.period
      end
      @count, @amount_cents = row.count, row.amount_cents
      @amount = MCP.eur(row.amount_cents)
      if group.person? && (paid = row.paid_cents)
        @paid, @paid_cents = MCP.eur(paid), paid
      end
      return unless previous
      change = row.amount_cents - previous
      @previous, @previous_cents = MCP.eur(previous), previous
      @change, @change_cents = MCP.eur(change), change
      @change_percent = (change.to_f * 1000 / previous).round(:ties_away) / 10 unless previous == 0
    end
  end

  record StatisticsOut, group_by : String, note : String, period : String, perspective : String,
    previous_period : String?, previous_total : String?, previous_total_cents : Int64?,
    rows : Array(StatLine), rows_total : Int32, total : String, total_cents : Int64, truncated : Bool do
    include JSON::Serializable
  end

  struct ActivityEntryOut
    include JSON::Serializable

    getter id : Int64
    getter at : String
    getter actor : String
    getter action : String
    getter expense_id : Int64?
    getter title : String?
    getter amount : String?
    getter amount_cents : Int64?
    getter changes : Array(Store::FieldChange)?
    getter text : String?

    def initialize(a : Store::Activity, location : Time::Location)
      @id, @expense_id = a.id, a.expense_id
      @at = MCP.rfc3339(a.at.in(location))
      @actor = a.actor_name.presence || "system"
      @action = a.action.key
      details = a.details
      @title, @text = details.title, details.text
      @amount_cents = details.amount_cents
      @amount = MCP.eur?(@amount_cents)
      @changes = details.changes unless details.changes.empty?
    end
  end

  record ActivityOut, entries : Array(ActivityEntryOut), more : Bool, note : String?, shown : Int32 do
    include JSON::Serializable
  end

  record QueryOut, columns : Array(String), note : String?, row_count : Int32, rows : Array(Array(SQLSandbox::Value)),
    truncated : Bool do
    include JSON::Serializable
  end

  record CreatedOut, created : ExpenseOut, note : String do
    include JSON::Serializable
  end
end
