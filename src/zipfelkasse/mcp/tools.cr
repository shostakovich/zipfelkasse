require "json"

module Zipfelkasse::MCP
  SERVER_VERSION = "1.1.0"

  # Explains the server to the model (initialize, server/discover);
  # Server#instructions appends today's date and a data overview.
  INSTRUCTIONS_TEXT = <<-TEXT
    Zipfelkasse manages the shared expenses of a single group (like Splitwise/Spliit). All tools are read-only except create_expense and create_reimbursement, which add entries (nothing can be changed or deleted via MCP).
    Amounts are in euros. Every amount in a result appears twice: as text with a dot as decimal separator and no thousands separator ("1234.56") and as an integer in cents (field ending in _cents).
    Balance: positive = is owed money by the others, negative = owes money.
    Reimbursements are settlement payments between two people, not expenses; they count for balances, not for expense statistics.
    Dates use the format YYYY-MM-DD. Refer to people and categories by name (case-insensitive). Names, titles, categories and notes are stored as entered (often in German).
    How to proceed: balances and settlement → balances; their development over time → balance_history. Finding individual expenses → search_expenses. Totals by category, merchant, period or person, also compared with the previous year → statistics. Who changed what when → activity.
    Anything else → read schema first, then sql_query (SQLite, SELECT only).
    Entering an expense → create_expense; a settlement payment between two people → create_reimbursement. Confirm unclear details with the user first and report what was created.
    TEXT

  # The category value for expenses without a category.
  NO_CATEGORY_ARG = "none"
  CATEGORY_HINT   = %(Use "#{NO_CATEGORY_ARG}" for expenses without a category (statistics labels them "#{Store::NO_CATEGORY}").)

  REIMBURSEMENTS_EXCLUDE = "exclude"
  REIMBURSEMENTS_INCLUDE = "include"
  REIMBURSEMENTS_ONLY    = "only"
  REIMBURSEMENT_MODES    = [REIMBURSEMENTS_EXCLUDE, REIMBURSEMENTS_INCLUDE, REIMBURSEMENTS_ONLY]

  SORT_ORDERS = [Store::SORT_DATE_DESC, Store::SORT_DATE_ASC, Store::SORT_AMOUNT_DESC, Store::SORT_AMOUNT_ASC]

  DETAIL_COMPACT = "compact"
  DETAIL_FULL    = "full"
  DETAIL_LEVELS  = [DETAIL_COMPACT, DETAIL_FULL]

  GROUPINGS = [Store::STATS_BY_CATEGORY, Store::STATS_BY_TITLE, Store::STATS_BY_YEAR, Store::STATS_BY_MONTH,
               Store::STATS_BY_WEEK, Store::STATS_BY_PERSON, Store::STATS_BY_CATEGORY_MONTH]
  HISTORY_INTERVALS     = [Store::STATS_BY_MONTH, Store::STATS_BY_WEEK, Store::STATS_BY_YEAR]
  COMPARE_PREVIOUS_YEAR = "previous_year"

  # The semaphore wait of sql_query; the query itself stops after
  # Store::SQL_TIMEOUT.
  TOOL_TIMEOUT = 20.seconds

  READ_ONLY = {"readOnlyHint" => true, "destructiveHint" => false, "idempotentHint" => true, "openWorldHint" => false}

  # A tool returns its result as text: JSON, or plain text for schema.
  record Tool, definition : JSON::Any, run : Proc(String?, String)

  def self.server_info : JSON::Any
    any({name: "zipfelkasse", title: "Zipfelkasse – shared expenses", version: SERVER_VERSION})
  end

  def self.capabilities : JSON::Any
    any({tools: {listChanged: false}})
  end

  def self.any(value) : JSON::Any
    JSON.parse(value.to_json)
  end

  def self.invalid(message : String) : Domain::ValidationError
    Domain::ValidationError.new(message)
  end

  # Locale-neutral: 123456 → "1234.56".
  def self.eur(cents : Int64) : String
    Domain.format_decimal(cents, 2, '.')
  end

  # (2340, "usd") → "23.40 USD".
  def self.money(minor : Int64, currency : String) : String
    currency = currency.strip.upcase
    "#{Domain.format_decimal(minor, Domain.currency_decimals(currency), '.')} #{currency}"
  end

  def self.ymd(t : Time) : String
    t.to_s(Domain::DATE_LAYOUT)
  end

  # Shortest round-trip digits like JSON elsewhere: plain notation from 1e-6
  # up to 1e21 (integral values without ".0"), else 1e-7 / 1e+30. Infinite
  # reals as SQLite prints them, so that numbers look the same in every tool.
  def self.float(j : JSON::Builder, f : Float64) : Nil
    if f.infinite?
      j.raw(f > 0 ? "9.0e+999" : "-9.0e+999")
    elsif f.nan?
      j.number(f) # raises
    elsif f.zero?
      j.raw("0")
    else
      j.raw(plain_float(f))
    end
  end

  private def self.plain_float(f : Float64) : String
    mantissa, _, exponent = f.abs.to_s.partition('e')
    whole, _, fraction = mantissa.partition('.')
    exp10 = exponent.to_i? || 0
    if whole == "0"
      leading = fraction.size - fraction.lstrip('0').size
      digits = fraction.lstrip('0')
      exp10 -= leading + 1
    else
      digits = whole + fraction
      exp10 += whole.size - 1
    end
    digits = digits.rstrip('0')
    sign = f < 0 ? "-" : ""
    if exp10 < -6 || exp10 >= 21
      rest = digits.size > 1 ? ".#{digits[1..]}" : ""
      "#{sign}#{digits[0]}#{rest}e#{exp10 < 0 ? "-" : "+"}#{exp10.abs.to_s.rjust(exp10 < 0 ? 1 : 2, '0')}"
    elsif exp10 < 0
      "#{sign}0.#{"0" * (-exp10 - 1)}#{digits}"
    elsif digits.size <= exp10 + 1
      "#{sign}#{digits}#{"0" * (exp10 + 1 - digits.size)}"
    else
      "#{sign}#{digits[0, exp10 + 1]}.#{digits[exp10 + 1..]}"
    end
  end

  def self.trim_or(v : String, fallback : String) : String
    v.strip.presence || fallback
  end

  # t, or fallback if t is nil or after fallback.
  def self.min_time(t : Time?, fallback : Time) : Time
    t.nil? || t > fallback ? fallback : t
  end

  def self.parse_date_arg(name : String, v : String) : Time?
    v = v.strip
    return if v.empty?
    Domain.parse_date(v)
  rescue Domain::ValidationError
    raise invalid("Invalid date for #{name}: #{v.inspect} (expected YYYY-MM-DD).")
  end

  def self.parse_range(from_arg : String, to_arg : String) : {Time?, Time?}
    from = parse_date_arg("from", from_arg)
    to = parse_date_arg("to", to_arg)
    if from && to && to < from
      raise invalid(%("to" (#{ymd(to)}) is before "from" (#{ymd(from)}).))
    end
    {from, to}
  end

  def self.describe_range(from : Time?, to : Time?) : String
    if from && to
      "#{ymd(from)} to #{ymd(to)}"
    elsif from
      "from #{ymd(from)}"
    elsif to
      "until #{ymd(to)}"
    else
      "all time"
    end
  end

  def self.overview_text(o : Store::DataOverview) : String
    String.build do |b|
      b << "Data overview: "
      first, last = o.first_date, o.last_date
      if first && last
        b << o.expenses << " expenses and " << o.reimbursements << " reimbursements dated " << ymd(first) << " to " << ymd(last) << ". "
        pct = o.expenses > 0 ? o.without_category.to_f * 100 / o.expenses : 0.0
        b << o.without_category << " of the expenses (" << "%.1f" % pct << "%) have no category."
      else
        b << "there are no expenses yet."
      end
      b << " Values of activity.action: " << o.activity_actions.join(", ") << '.' unless o.activity_actions.empty?
    end
  end

  # Tool arguments: unknown fields are errors, null leaves the default.
  module Args
    macro included
      include Decodable

      protected def on_unknown_json_attribute(pull, key, key_location)
        raise MCP.invalid(%(Invalid arguments: unknown field #{key.inspect}.))
      end
    end
  end

  def self.args(type : T.class, raw : String?) : T forall T
    T.from_json(raw || "{}")
  rescue ex : JSON::SerializableError
    raise invalid("Invalid arguments: #{decode_error(T, ex, "arguments")}")
  end

  # A string or a list of strings.
  module TextList
    def self.from_json(pull : JSON::PullParser) : Array(String)
      not_text = MCP.invalid("Invalid arguments: must be a string or a list of strings")
      return [pull.read_string] if pull.kind.string?
      raise not_text unless pull.kind.begin_array?
      list = [] of String
      pull.read_array do
        case pull.kind
        when .string? then list << pull.read_string
        when .null?   then pull.read_null
        else               raise not_text
        end
      end
      list
    end
  end

  struct NoArgs
    include Args
  end

  struct HistoryArgs
    include Args
    getter interval = "", from = "", to = "", person = ""
  end

  struct SearchArgs
    include Args
    getter from = "", to = "", category = "", person = "", paid_by = "", involved = ""
    @[JSON::Field(converter: Zipfelkasse::MCP::TextList)]
    getter text = [] of String
    getter min_amount : Float64? = nil
    getter max_amount : Float64? = nil
    getter reimbursements = "", sort = "", detail = ""
    getter limit = 0_i64
  end

  struct StatisticsArgs
    include Args
    getter group_by = "", from = "", to = "", share_of = "", category = ""
    @[JSON::Field(converter: Zipfelkasse::MCP::TextList)]
    getter text = [] of String
    getter compare = ""
    getter limit = 0_i64
  end

  struct ActivityArgs
    include Args
    getter from = "", to = "", person = "", action = ""
    getter expense_id = 0_i64, before_id = 0_i64, limit = 0_i64
  end

  struct SQLArgs
    include Args
    getter query = ""
  end

  class StatOut
    property category = ""
    property title = ""
    property year = ""
    property month = ""
    property week = ""
    property person = ""
    property count = 0_i64
    property amount_cents = 0_i64
    property paid_cents : Int64? = nil
    property previous_cents : Int64? = nil
    property change_cents : Int64? = nil
    property change_percent : Float64? = nil

    def period : String
      year + month + week
    end

    def initialize
    end

    def initialize(r : Store::StatRow, group_by : String)
      @category, @title, @person, @count, @amount_cents = r.category, r.title, r.person, r.count, r.amount_cents
      case group_by
      when Store::STATS_BY_YEAR then @year = r.period
      when Store::STATS_BY_WEEK then @week = r.period
      else                           @month = r.period
      end
      @paid_cents = r.paid_cents if group_by == Store::STATS_BY_PERSON
    end

    def set_previous(p : Int64) : Nil
      change = amount_cents - p
      @previous_cents = p
      @change_cents = change
      @change_percent = (change.to_f * 1000 / p).round(:ties_away) / 10 if p != 0
    end

    def to_json(j : JSON::Builder) : Nil
      j.object do
        {"category" => category, "title" => title, "year" => year, "month" => month, "week" => week, "person" => person}.each do |k, v|
          j.field k, v unless v.empty?
        end
        j.field "count", count
        j.field "amount", MCP.eur(amount_cents)
        j.field "amount_cents", amount_cents
        {"paid" => paid_cents, "previous" => previous_cents, "change" => change_cents}.each do |k, v|
          next unless v
          j.field k, MCP.eur(v)
          j.field "#{k}_cents", v
        end
        change_percent.try { |pct| j.field("change_percent") { MCP.float(j, pct) } }
      end
    end
  end

  class Server
    @tools = {} of String => Tool
    @order = [] of String # tools/list order
    @sql_sem = Channel(Nil).new(2)
    @log : Logger

    def initialize(@d : Web::Deps)
      @log = @d.log
      register_read_tools
      register_write_tools
    end

    def location : Time::Location
      @d.config.location
    end

    def today : Time
      @d.today
    end

    # The current date in the server time zone, computed per request so that
    # long-running servers never report a stale date.
    def today_line : String
      t = today
      %(Today is #{MCP.ymd(t)} (#{t.day_of_week}), server time zone #{@d.config.location_name}. Resolve relative periods such as "last month" from this date.)
    end

    # With the data overview, left out if it cannot be read.
    def instructions : String
      text = INSTRUCTIONS_TEXT + "\n" + today_line
      begin
        text + "\n" + MCP.overview_text(@d.store.mcp_overview)
      rescue ex
        @log.error("mcp: data overview", err: ex)
        text
      end
    end

    # server/discover contains the date, so it is cached at most until the
    # next midnight in the server time zone.
    def discover_ttl : Time::Span
      t = @d.now.in(location)
      midnight = Time.local(t.year, t.month, t.day, location: location).shift(days: 1)
      {LIST_TTL, midnight - t}.min
    end

    private def add(name : String, title : String, description : String, schema : JSON::Any, annotations = READ_ONLY,
                    &run : String? -> String) : Nil
      @order << name
      definition = MCP.any({name: name, title: title, description: description, inputSchema: schema, annotations: annotations})
      @tools[name] = Tool.new(definition, run)
    end

    def self.object_schema(properties, required : Array(String)? = nil) : JSON::Any
      h = MCP.any({type: "object", properties: properties, additionalProperties: false}).as_h
      h["required"] = MCP.any(required) if required
      JSON::Any.new(h)
    end

    def self.date_prop(description : String)
      {"type" => "string", "description" => description + " Format YYYY-MM-DD (DD.MM.YYYY is accepted too)."}
    end

    def self.limit_prop(description : String)
      {"type" => "integer", "minimum" => 1, "maximum" => Store::SQL_MAX_ROWS, "description" => description}
    end

    private def register_read_tools : Nil
      text_prop = {
        "anyOf"       => [{"type" => "string"}, {"type" => "array", "items" => {"type" => "string"}}],
        "description" => %(Substring of the title or notes (case-insensitive). A list matches if any of the terms occurs, e.g. ["Rewe", "Edeka", "Lidl"].),
      }
      no_args = Server.object_schema({} of String => String)

      add("balances", "Balances and settlement",
        "Current balance of each person in euros and a settlement proposal (who transfers how much to whom so that everyone ends at 0). " \
        "Positive balance = is owed money, negative = owes money. Includes all non-deleted expenses and reimbursements.",
        no_args) { |raw| balances(raw) }

      add("balance_history", "Balance history",
        "Balance of each person at the end of each month (or week/year): how the balances developed over time. " \
        "Based on the current data by expense date (later edits and deletions apply retroactively). " \
        "Positive balance = is owed money, negative = owes money. Reimbursements count.",
        Server.object_schema({
          "interval" => {"type" => "string", "enum" => HISTORY_INTERVALS, "description" => "Length of a period: month (default), week (ISO week) or year."},
          "from"     => Server.date_prop("First period: the one containing this date. Default: the first expense."),
          "to"       => Server.date_prop("Last period: the one containing this date. Default: today."),
          "person"   => {"type" => "string", "description" => "Name of a person: only their balance. Empty = everyone."},
        })) { |raw| balance_history(raw) }

      add("search_expenses", "Search expenses",
        "Searches individual expenses (newest first unless sort says otherwise) with amount, payer and category; with detail=full also split (each person's share), notes and foreign currency. " \
        "All filters are optional and are combined. Also returns the total number of matches, their total and – with person – " \
        "the total of that person's shares. For plain totals by category/month, statistics is the better choice.",
        Server.object_schema({
          "from"           => Server.date_prop("First date (inclusive)."),
          "to"             => Server.date_prop("Last date (inclusive)."),
          "category"       => {"type" => "string", "description" => %(Category name, e.g. "Lebensmittel". ) + CATEGORY_HINT},
          "person"         => {"type" => "string", "description" => "Name of a person: finds expenses they paid OR take part in."},
          "paid_by"        => {"type" => "string", "description" => "Name of a person: only expenses this person paid."},
          "involved"       => {"type" => "string", "description" => "Name of a person: only expenses this person has a share in."},
          "text"           => text_prop,
          "min_amount"     => {"type" => "number", "minimum" => 0, "description" => "Smallest amount in euros (inclusive), e.g. 50 or 12.5."},
          "max_amount"     => {"type" => "number", "minimum" => 0, "description" => "Largest amount in euros (inclusive)."},
          "reimbursements" => {"type" => "string", "enum" => REIMBURSEMENT_MODES,
                               "description" => "Reimbursements (settlement payments between people): hide them (exclude, default), include them (include) or return only them (only)."},
          "sort" => {"type" => "string", "enum" => SORT_ORDERS,
                     "description" => "Order of the expenses: date_desc (newest first, default), date_asc, amount_desc (most expensive first), amount_asc."},
          "detail" => {"type" => "string", "enum" => DETAIL_LEVELS,
                       "description" => "compact (default): id, date, title, category, payer and amount per expense. full: additionally split, each person's share, notes and foreign currency."},
          "limit" => Server.limit_prop("Maximum number of expenses returned, default 50."),
        })) { |raw| search_expenses(raw) }

      add("statistics", "Statistics",
        "Expense totals grouped by category, title (merchant), year, month (YYYY-MM), ISO week (YYYY-Www), person or category_month, optionally for a period. " \
        "Without share_of: total amounts of the expenses. With share_of: only that person's share of each expense, i.e. what they consumed themselves " \
        "(e.g. \"How much did I spend on restaurants in 2026?\"). With group_by=person, amount is each person's share (consumption) " \
        "and paid is what they paid up front. year, month and week list periods without expenses with 0. " \
        "compare=previous_year adds the amount of the same group one year earlier and the change. Reimbursements and deleted expenses never count.",
        Server.object_schema({
          "group_by" => {"type" => "string", "enum" => GROUPINGS, "description" => "What to group by. title groups by expense title (case-insensitive), i.e. by merchant."},
          "from"     => Server.date_prop("First date (inclusive)."),
          "to"       => Server.date_prop("Last date (inclusive)."),
          "share_of" => {"type" => "string", "description" => "Name of a person: only their share counts (that person's perspective). Empty = total amounts."},
          "category" => {"type" => "string", "description" => "Only count expenses of this category (name, case-insensitive). " + CATEGORY_HINT},
          "text"     => text_prop,
          "compare"  => {"type" => "string", "enum" => [COMPARE_PREVIOUS_YEAR],
                        "description" => "previous_year: compare each row with the same group one year earlier (month 2026-03 with 2025-03, category in from…to with from…to minus one year). " \
                                         "For category, title and person, from is required."},
          "limit" => Server.limit_prop("Maximum number of rows, default #{Store::SQL_MAX_ROWS}. total always covers all rows."),
        }, ["group_by"])) { |raw| statistics(raw) }

      add("activity", "Activity log",
        "Who created, changed or deleted which expense when, and other changes (settings, people, categories, rates, recurring expenses), newest first. " \
        "Entries of expense_updated list the changed fields with old and new value (field names and values as shown in the app, in German).",
        Server.object_schema({
          "from"       => Server.date_prop("First day (inclusive, server time zone)."),
          "to"         => Server.date_prop("Last day (inclusive, server time zone)."),
          "person"     => {"type" => "string", "description" => "Name of a person: only changes they made."},
          "action"     => {"type" => "string", "description" => "Only this action, e.g. expense_created, expense_updated, expense_deleted, settings_updated."},
          "expense_id" => {"type" => "integer", "minimum" => 1, "description" => "Only entries of this expense (id as in search_expenses)."},
          "before_id"  => {"type" => "integer", "minimum" => 1, "description" => "Paging: only entries with a smaller id (pass the id of the last entry of the previous page)."},
          "limit"      => Server.limit_prop("Maximum number of entries, default 50."),
        })) { |raw| activity(raw) }

      add("schema", "Database schema",
        "Explains the database tables and columns in words (amounts in cents, deleted expenses, reimbursements, shares, foreign currency), " \
        "lists people and categories and returns the CREATE statements. Call before sql_query.",
        no_args) { |raw| schema(raw) }

      add("sql_query", "SQL query",
        "Runs exactly one read-only SQL query (SQLite dialect, only SELECT or WITH … SELECT) on a read-only copy of the data. " \
        "Call schema first. Important: amounts are cents (divide by 100.0 for euros), exclude deleted expenses with deleted_at IS NULL, " \
        "reimbursements (is_reimbursement = 1) are not expenses, a person's share is expense_shares.amount_cents. " \
        "At most #{Store::SQL_MAX_ROWS} rows, aborted after #{Store::SQL_TIMEOUT.total_seconds.to_i} seconds, texts longer than 2000 characters are truncated. " \
        "For standard questions, balances, search_expenses and statistics are simpler.",
        Server.object_schema({
          "query" => {"type" => "string", "description" => "The SQL query, e.g. SELECT name FROM participants WHERE archived_at IS NULL"},
        }, ["query"])) { |raw| sql_query(raw) }
    end

    # All people, archived ones too, ordered by name.
    private def participants : Array(Store::Participant)
      @d.store.list_participants(include_archived: true)
    end

    # nil for a blank name.
    private def person_arg(name : String) : Store::Participant?
      Server.find_named(participants, "person", name) unless name.blank?
    end

    private def find_category(name : String) : Store::Category
      Server.find_named(@d.store.list_categories(include_archived: true), "category", name)
    end

    def self.find_named(items : Array(T), kind : String, name : String) : T forall T
      name = name.strip
      items.find(&.name.compare(name, case_insensitive: true).zero?) ||
        raise MCP.invalid("Unknown #{kind} #{name.inspect}. Available: #{items.join(", ", &.name)}.")
    end

    # A category name, or "none" / "No category" (the statistics label) for
    # expenses without a category; a real category of that name wins.
    # Returns {category_id, without_category}.
    private def category_arg(name : String) : {Int64, Bool}
      return {0_i64, false} if name.blank?
      {find_category(name).id, false}
    rescue ex : Domain::ValidationError
      n = name.strip
      raise ex unless {NO_CATEGORY_ARG, Store::NO_CATEGORY}.any? { |v| n.compare(v, case_insensitive: true).zero? }
      {0_i64, true}
    end

    def self.balance_out(j : JSON::Builder, person : String, cents : Int64, status : String) : Nil
      j.object do
        j.field "person", person
        j.field "balance", MCP.eur(cents)
        j.field "balance_cents", cents
        j.field "status", status
      end
    end

    private def balances(raw : String?) : String
      MCP.args(NoArgs, raw)
      bal = @d.store.balances
      ps = participants
      names = ps.to_h { |p| {p.id, p.name} }
      JSON.build do |j|
        j.object do
          j.field "balances" do
            j.array do
              ps.each do |p|
                v = bal[p.id]? || 0_i64
                next if p.archived? && v == 0
                Server.balance_out(j, p.name, v, v > 0 ? "is owed money" : (v < 0 ? "owes money" : "settled"))
              end
            end
          end
          j.field "note", "Positive balance = is owed money, negative = owes money. settlements: the transfers needed so that everyone ends at 0."
          j.field "settlements" do
            j.array do
              Domain.settle(bal).each do |t|
                j.object do
                  j.field "from", names[t.from]? || ""
                  j.field "to", names[t.to]? || ""
                  j.field "amount", MCP.eur(t.amount_cents)
                  j.field "amount_cents", t.amount_cents
                end
              end
            end
          end
        end
      end
    end

    private def balance_history(raw : String?) : String
      a = MCP.args(HistoryArgs, raw)
      interval = MCP.trim_or(a.interval, Store::STATS_BY_MONTH)
      unless HISTORY_INTERVALS.includes?(interval)
        raise MCP.invalid("interval must be one of #{HISTORY_INTERVALS.join(", ")}.")
      end
      from, to = MCP.parse_range(a.from, a.to)
      person = person_arg(a.person)
      today = self.today
      too_many = ->(periods : Array(String)) do
        if periods.size > Store::SQL_MAX_ROWS
          raise MCP.invalid("That is #{periods.size} periods, at most #{Store::SQL_MAX_ROWS} are possible. " \
                            "Please narrow down from/to or choose a longer interval.")
        end
      end
      # The obvious case before loading anything.
      too_many.call(Store.periods(interval, from, MCP.min_time(to, today))) if from

      # Up to the end of the last period: each row is the balance after all
      # expenses dated in or before its period.
      es = @d.store.dated_balance_entries(to.try { |t| Store.period_end(interval, t) })
      ps = participants
      if to.nil?
        # Until today, or the last expense if one is dated later: the last row
        # then equals the current balances.
        to = today
        if (last = es.last?) && last.date > to
          to = last.date
        end
      end
      from = es.first?.try(&.date) if from.nil?
      from = to unless from && from <= to
      periods = Store.periods(interval, from, to)
      too_many.call(periods)

      # Expenses before the first period are the opening balance.
      bal = Hash(Int64, Int64).new(0_i64)
      ever_non_zero = Set(Int64).new
      i = 0
      snapshots = periods.map do |p|
        entries = [] of Domain::Entry
        while i < es.size && Store.period_of(interval, es[i].date) <= p
          entries << es[i].entry
          i += 1
        end
        Domain.balances(entries).each { |id, v| bal[id] += v }
        bal.each { |id, v| ever_non_zero << id if v != 0 }
        bal.dup
      end
      JSON.build do |j|
        j.object do
          j.field "interval", interval
          j.field "note", "Balance after all expenses dated up to the end of each period (in the current period also those dated later this period), " \
                          "positive = is owed money, negative = owes money. Without to, the last row equals the current balances. " \
                          "Computed from the current data by expense date: later edits and deletions apply retroactively."
          j.field "period", MCP.describe_range(from, to)
          j.field "rows" do
            j.array do
              periods.each_with_index do |p, pi|
                j.object do
                  j.field interval, p
                  j.field "balances" do
                    j.array do
                      ps.each do |pp|
                        next if person ? pp.id != person.id : (pp.archived? && !ever_non_zero.includes?(pp.id))
                        Server.balance_out(j, pp.name, snapshots[pi][pp.id]? || 0_i64, "")
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    private def search_expenses(raw : String?) : String
      a = MCP.args(SearchArgs, raw)
      f = Store::ExpenseFilter.new(any_text: a.text)
      f.from, f.to = MCP.parse_range(a.from, a.to)
      f.category_id, f.without_category = category_arg(a.category)
      person, payer, involved = person_arg(a.person), person_arg(a.paid_by), person_arg(a.involved)
      f.participant_id = person.try(&.id) || 0_i64
      f.paid_by = payer.try(&.id) || 0_i64
      f.involved_id = involved.try(&.id) || 0_i64
      f.min_cents = Server.amount_arg("min_amount", a.min_amount)
      f.max_cents = Server.amount_arg("max_amount", a.max_amount)
      raise MCP.invalid("max_amount must be greater than 0.") if a.max_amount && f.max_cents == 0
      if f.max_cents != 0 && f.min_cents > f.max_cents
        raise MCP.invalid("min_amount (#{MCP.eur(f.min_cents)}) is greater than max_amount (#{MCP.eur(f.max_cents)}).")
      end
      mode = MCP.trim_or(a.reimbursements, REIMBURSEMENTS_EXCLUDE)
      raise MCP.invalid(%(reimbursements must be "exclude", "include" or "only".)) unless REIMBURSEMENT_MODES.includes?(mode)
      f.sort = MCP.trim_or(a.sort, Store::SORT_DATE_DESC)
      raise MCP.invalid("sort must be one of #{SORT_ORDERS.join(", ")}.") unless SORT_ORDERS.includes?(f.sort)
      detail = MCP.trim_or(a.detail, DETAIL_COMPACT)
      raise MCP.invalid(%(detail must be "compact" or "full".)) unless DETAIL_LEVELS.includes?(detail)
      sharer = person || involved # whose shares are summed up
      limit = Server.limit(a.limit, 50)

      es = @d.store.list_expenses(f).select do |e|
        mode == REIMBURSEMENTS_INCLUDE || e.reimbursement? == (mode == REIMBURSEMENTS_ONLY)
      end
      names = participants.to_h { |p| {p.id, p.name} }
      total = es.sum(0_i64, &.amount_cents)
      shown = es.first(limit)
      JSON.build do |j|
        j.object do
          j.field("expenses") { j.array { shown.each { |e| Server.expense_out(j, e, names, detail == DETAIL_FULL) } } }
          j.field "matches", es.size
          if sharer
            share = es.sum(0_i64, &.share_of(sharer.id))
            j.field "person_share" do
              j.object do
                j.field "amount", MCP.eur(share)
                j.field "amount_cents", share
                j.field "person", sharer.name
              end
            end
          end
          j.field "shown", shown.size
          j.field "total", MCP.eur(total)
          j.field "total_cents", total
          j.field "truncated", es.size > shown.size
        end
      end
    end

    # 0 = the default, otherwise 1 to Store::SQL_MAX_ROWS.
    def self.limit(v : Int64, default : Int32) : Int32
      return default if v == 0
      raise MCP.invalid("limit must be between 1 and #{Store::SQL_MAX_ROWS}.") unless 1 <= v <= Store::SQL_MAX_ROWS
      v.to_i
    end

    # Euros to cents; nil = 0.
    def self.amount_arg(name : String, v : Float64?) : Int64
      return 0_i64 unless v
      raise MCP.invalid("#{name} must be an amount in euros of at least 0.") if v < 0 || v.nan? || v > 1e12
      (v * 100).round(:ties_away).to_i64
    end

    # Without full only the compact fields (no split, shares, notes and
    # foreign currency).
    def self.expense_out(j : JSON::Builder, e : Store::Expense, names : Hash(Int64, String), full : Bool) : Nil
      j.object do
        j.field "id", e.id
        j.field "date", MCP.ymd(e.date)
        j.field "title", e.title
        j.field "category", e.category_name unless e.category_name.empty?
        j.field "paid_by", e.paid_by_name
        j.field "amount", MCP.eur(e.amount_cents)
        j.field "amount_cents", e.amount_cents
        if e.reimbursement?
          j.field "reimbursement", true
          recipient = e.shares.first?.try { |s| names[s.participant_id]? } || ""
          j.field "recipient", recipient unless recipient.empty?
        end
        next unless full
        if e.foreign?
          j.field "original", MCP.money(e.original_amount_minor, e.original_currency)
          j.field("fx_rate") { MCP.float(j, e.fx_rate) } unless e.fx_rate == 0
          j.field "fx_source", e.fx_source unless e.fx_source.empty?
        end
        j.field "notes", e.notes unless e.notes.empty?
        next if e.reimbursement?
        j.field "split", e.split_mode.value unless e.split_mode.value.empty?
        next if e.shares.empty?
        j.field "shares" do
          j.array do
            e.shares.each do |sh|
              j.object do
                j.field "person", names[sh.participant_id]? || ""
                j.field "amount", MCP.eur(sh.amount_cents)
                j.field "amount_cents", sh.amount_cents
              end
            end
          end
        end
      end
    end

    private def statistics(raw : String?) : String
      a = MCP.args(StatisticsArgs, raw)
      f = Store::StatsFilter.new(group_by: a.group_by.strip, any_text: a.text)
      raise MCP.invalid("group_by must be one of #{GROUPINGS.join(", ")}.") unless GROUPINGS.includes?(f.group_by)
      f.from, f.to = MCP.parse_range(a.from, a.to)
      f.category_id, f.without_category = category_arg(a.category)
      perspective = "total amounts of the expenses"
      if p = person_arg(a.share_of)
        f.participant_id = p.id
        perspective = "only the share of #{p.name}"
      end
      limit = Server.limit(a.limit, Store::SQL_MAX_ROWS)
      today = self.today
      compare = a.compare.strip
      time_keyed = Store.time_grouping?(f.group_by) || f.group_by == Store::STATS_BY_CATEGORY_MONTH
      unless compare.empty?
        raise MCP.invalid(%(compare must be "#{COMPARE_PREVIOUS_YEAR}".)) if compare != COMPARE_PREVIOUS_YEAR
        unless time_keyed
          from = f.from || raise MCP.invalid("compare=previous_year with group_by=#{f.group_by} needs from (and optionally to): the period to compare.")
          if f.to.nil?
            if today < from
              raise MCP.invalid("from (#{MCP.ymd(from)}) is in the future; compare=previous_year needs a period up to today or an explicit to.")
            end
            f.to = today
          end
        end
      end

      stat_rows = @d.store.stats(f)
      rows = Store.time_grouping?(f.group_by) ? Server.fill_gaps(stat_rows, f, today) : stat_rows
      total = rows.sum(0_i64, &.amount_cents)
      items = rows.map { |r| StatOut.new(r, f.group_by) }
      previous_period = ""
      unless compare.empty?
        prev = f
        prev.from = f.from.try { |t| Store.shift_date_year(t, -1) }
        prev.to = f.to.try { |t| Store.shift_date_year(t, -1) }
        # Without from and to, the previous year's rows are the same rows.
        prev_rows = prev.from || prev.to ? @d.store.stats(prev) : stat_rows
        window = time_keyed ? Server.period_window(f, stat_rows, today) : nil
        items = Server.compare_previous(items, prev_rows, f.group_by, window)
        previous_period = time_keyed ? "each #{f.group_by.lchop("category_")} one year earlier" : MCP.describe_range(prev.from, prev.to)
      end
      note = "Reimbursements and deleted expenses are not included. count = number of expenses."
      note += " amount = the person's share (consumption), paid = what they paid for the group." if f.group_by == Store::STATS_BY_PERSON
      unless compare.empty?
        note += " previous = same group one year earlier, change = amount − previous, change_percent relative to previous (missing if previous is 0)."
      end
      JSON.build do |j|
        j.object do
          j.field "group_by", f.group_by
          j.field "note", note
          j.field "period", MCP.describe_range(f.from, f.to)
          j.field "perspective", perspective
          unless compare.empty?
            previous_total = items.sum(0_i64) { |o| o.previous_cents || 0_i64 }
            j.field "previous_period", previous_period
            j.field "previous_total", MCP.eur(previous_total)
            j.field "previous_total_cents", previous_total
          end
          j.field "rows", items.first(limit)
          j.field "rows_total", items.size
          j.field "total", MCP.eur(total)
          j.field "total_cents", total
          j.field "truncated", items.size > limit
        end
      end
    end

    # Lists the periods without expenses of a time grouping with 0: from from
    # (or the first row) to to (or today), never beyond today.
    def self.fill_gaps(rows : Array(Store::StatRow), f : Store::StatsFilter, today : Time) : Array(Store::StatRow)
      first = f.from || rows.first?.try { |r| Store.period_start(f.group_by, r.period) }
      return rows unless first
      Store.fill_periods(rows, f.group_by, first, MCP.min_time(f.to, today))
    end

    # Whether a period lies within the requested range of a time-keyed
    # grouping: from from (or the first row) to to (or today), never beyond
    # today.
    def self.period_window(f : Store::StatsFilter, rows : Array(Store::StatRow), today : Time) : Proc(String, Bool)
      lo = f.from.try { |t| Store.period_of(f.group_by, t) } || rows.min_of?(&.period)
      return ->(p : String) { false } unless lo
      hi = Store.period_of(f.group_by, MCP.min_time(f.to, today))
      ->(p : String) { lo <= p <= hi }
    end

    # Adds previous and change to each row. prev are the rows of the period
    # one year earlier; their periods are shifted by one year to match. Groups
    # that only exist in prev are appended with 0 – for time-keyed groupings
    # (window given) only if their period lies within window.
    def self.compare_previous(items : Array(StatOut), prev : Array(Store::StatRow), group_by : String,
                              window : Proc(String, Bool)?) : Array(StatOut)
      key = ->(o : StatOut) { {o.category, Store.fold(o.title), o.person, o.year, o.month, o.week} }
      prev_by = {} of {String, String, String, String, String, String} => StatOut
      prev.each do |r|
        o = StatOut.new(r.copy_with(period: Store.shift_period_year(r.period, 1)), group_by)
        if have = prev_by[key.call(o)]?
          have.amount_cents += o.amount_cents # week 53 merged into week 52 of a year without week 53
        else
          prev_by[key.call(o)] = o
        end
      end
      items.each { |o| o.set_previous(prev_by.delete(key.call(o)).try(&.amount_cents) || 0_i64) }
      appended = false
      prev_by.each_value do |p|
        next if window && !window.call(p.period)
        o = StatOut.new
        o.category, o.title, o.year, o.month, o.week, o.person = p.category, p.title, p.year, p.month, p.week, p.person
        o.paid_cents = 0_i64 if group_by == Store::STATS_BY_PERSON
        o.set_previous(p.amount_cents)
        items << o
        appended = true
      end
      if appended && window
        # Back into the order of Store#stats: by period, then amount, then category.
        items = items.each_with_index.to_a.sort_by! { |o, i| {o.period, -o.amount_cents, o.category, i} }.map(&.[0])
      end
      items
    end

    private def activity(raw : String?) : String
      a = MCP.args(ActivityArgs, raw)
      from, to = MCP.parse_range(a.from, a.to)
      loc = location
      since = from.try { |t| Time.local(t.year, t.month, t.day, location: loc) }
      until_ = to.try { |t| Time.local(t.year, t.month, t.day, location: loc).shift(days: 1) }
      actor = person_arg(a.person).try(&.id) || 0_i64
      expense_id, before_id = a.expense_id, a.before_id
      raise MCP.invalid("expense_id and before_id must be positive.") if expense_id < 0 || before_id < 0
      limit = Server.limit(a.limit, 50)
      acts = @d.store.list_activity(Store::ActivityFilter.new(
        expense_id: expense_id, actor_id: actor, action: a.action.strip, since: since, until: until_,
        before_id: before_id, limit: limit + 1))
      more = acts.size > limit
      acts = acts.first(limit)
      JSON.build do |j|
        j.object do
          j.field "entries" do
            j.array do
              acts.each do |act|
                j.object do
                  j.field "id", act.id
                  j.field "at", MCP.rfc3339((act.at || Time.utc(1, 1, 1)).in(loc))
                  j.field "actor", act.actor_name.presence || "system"
                  j.field "action", act.action
                  j.field "expense_id", act.expense_id unless act.expense_id == 0
                  d = act.details
                  j.field "title", d.title unless d.title.empty?
                  unless d.amount_cents == 0
                    j.field "amount", MCP.eur(d.amount_cents)
                    j.field "amount_cents", d.amount_cents
                  end
                  unless d.changes.empty?
                    j.field "changes" do
                      j.array do
                        d.changes.each do |c|
                          j.object do
                            j.field "field", c.field
                            j.field "old", c.old
                            j.field "new", c.new
                          end
                        end
                      end
                    end
                  end
                  j.field "text", d.text unless d.text.empty?
                end
              end
            end
          end
          j.field "more", more
          j.field "note", "There are older entries: call again with before_id=#{acts.last.id}." if more
          j.field "shown", acts.size
        end
      end
    end

    SCHEMA_TEXT = <<-TEXT + "\n"
      Database of Zipfelkasse (SQLite). A single group.
      Conventions: amounts are INTEGER in euro cents (divide by 100.0 for euros). Calendar dates are TEXT 'YYYY-MM-DD', timestamps TEXT RFC 3339 in UTC. Booleans are 0/1.
      Data values (names, titles, categories, notes) are stored as entered, often in German.

      Tables:
      - participants: people in the group. archived_at set = archived (no longer active, their entries remain).
      - categories: categories (name, position = display order, archived_at).
      - expenses: expenses AND reimbursements.
        * deleted_at set = deleted (soft delete) → ALWAYS filter with "deleted_at IS NULL".
        * amount_cents: amount in euro cents (converted for foreign currency). paid_by: who paid (participants.id). category_id NULL = no category.
        * is_reimbursement = 1: reimbursement – paid_by paid money to the person in the single expense_shares row. It is not an expense
          (expense analyses use "is_reimbursement = 0"), but it counts for balances.
        * split_mode: equal (evenly), shares (by shares), percent (by percentage), amount (fixed amounts).
        * Foreign currency: original_currency ('EUR' if none), original_amount_minor (amount in the smallest unit of that currency),
          fx_rate (units of foreign currency per 1 EUR, ECB format), fx_source ('ezb' = ECB reference rate, 'manuell' = entered manually, or '' for EUR). amount_cents is already converted.
        * recurring_id: created automatically from a recurring rule. created_at/updated_at: timestamps.
      - expense_shares: split of each expense across people. amount_cents = this person's share in cents (sum per expense = expenses.amount_cents).
        weight depends on split_mode: equal 1, shares the share count, percent basis points (sum 10000), amount the amount in the smallest unit of original_currency (sum = original_amount_minor; cents for EUR).
      - recurring: rules for recurring expenses (template_json = template as JSON, frequency weekly|monthly|yearly, start_date, next_date, active).
      - activity: change log (at, actor_id NULL = system, action expense_created|expense_updated|expense_deleted, expense_id, details_json).
      - fx_rates: exchange rates per currency, source ('ezb' or 'manuell') and date (foreign currency per 1 EUR).
        A day can have both an ECB and a manual rate; the most recent manual rate on or before a date takes precedence over the ECB rate.
      - settings: settings (key/value, e.g. group_name, default_currency).
      YNAB tables (credentials) are not visible via MCP.

      Balance of a person = sum of amount_cents of the expenses they paid − sum of their shares in expense_shares
      (only deleted_at IS NULL, reimbursements included). Positive = is owed money.

      Example – Anna's share per category in 2026:
      SELECT coalesce(c.name, '#{Store::NO_CATEGORY}') AS category, sum(x.amount_cents) / 100.0 AS euros
      FROM expenses e
      JOIN expense_shares x ON x.expense_id = e.id
      JOIN participants p ON p.id = x.participant_id AND p.name = 'Anna'
      LEFT JOIN categories c ON c.id = e.category_id
      WHERE e.deleted_at IS NULL AND e.is_reimbursement = 0 AND e.date BETWEEN '2026-01-01' AND '2026-12-31'
      GROUP BY 1 ORDER BY 2 DESC;
      TEXT

    private def schema(raw : String?) : String
      MCP.args(NoArgs, raw)
      objects = @d.store.mcp_schema
      ps = participants
      cs = @d.store.list_categories(include_archived: true)
      String.build do |b|
        b << today_line << "\n\n" << SCHEMA_TEXT
        b << "\nPeople (id: name): "
        ps.join(b, ", ") { |p, io| io << p.id << ": " << p.name << (p.archived? ? " (archived)" : "") }
        b << "\nCategories (id: name): "
        cs.join(b, ", ") { |c, io| io << c.id << ": " << c.name << (c.archived? ? " (archived)" : "") }
        b << "\n\nCREATE statements:\n"
        objects.each { |o| b << o.sql << ";\n" }
      end
    end

    private def sql_query(raw : String?) : String
      a = MCP.args(SQLArgs, raw)
      query = a.query
      raise MCP.invalid("Parameter query is missing.") if query.blank?
      select
      when @sql_sem.send(nil)
      when timeout(TOOL_TIMEOUT)
        raise MCP.invalid("Too many concurrent queries, please try again.")
      end
      res = begin
        @d.store.read_only_query(query)
      ensure
        @sql_sem.receive
      end
      JSON.build do |j|
        j.object do
          j.field "columns", res.columns
          if res.truncated?
            j.field "note", "There are more than #{Store::SQL_MAX_ROWS} rows; only the first #{Store::SQL_MAX_ROWS} are included. " \
                            "Please aggregate or narrow down with WHERE/LIMIT."
          end
          j.field "row_count", res.rows.size
          j.field "rows" do
            j.array do
              res.rows.each do |row|
                j.array do
                  row.each do |v|
                    case v
                    when Float64 then MCP.float(j, v)
                    else              v.to_json(j)
                    end
                  end
                end
              end
            end
          end
          j.field "truncated", res.truncated?
        end
      end
    end
  end

  # RFC 3339 in t's zone ("Z" for any zero offset); Time#to_rfc3339 would
  # convert to UTC.
  def self.rfc3339(t : Time) : String
    t.offset == 0 ? t.to_s("%Y-%m-%dT%H:%M:%SZ") : t.to_s("%Y-%m-%dT%H:%M:%S%:z")
  end
end
