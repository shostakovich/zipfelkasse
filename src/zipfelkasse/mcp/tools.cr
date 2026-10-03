require "json"

module Zipfelkasse::MCP
  SERVER_VERSION = "1.1.0"

  # Explains the server to the model (initialize, server/discover);
  # Server#instructions appends today's date and a data overview.
  INSTRUCTIONS_TEXT = {{ read_file("#{__DIR__}/texts/instructions.txt") }}.rstrip

  SCHEMA_TEXT = {{ read_file("#{__DIR__}/texts/schema.txt") }}

  CATEGORY_HINT = %(Use "#{NO_CATEGORY_ARG}" for expenses without a category (statistics labels them "#{NO_CATEGORY_LABEL}").)

  # A tool returns its result as text: JSON, or plain text for schema.
  record Tool, definition : ToolDefinition, run : Proc(String?, String)

  # The people of the group, archived ones too, looked up by name; read once
  # per tool call.
  class Directory
    getter people : Array(Store::Participant)
    getter names : Hash(Int64, String)

    def initialize(@people)
      @names = @people.to_h { |person| {person.id, person.name} }
    end

    def name(id : Int64) : String
      @names[id]? || ""
    end

    # nil for a blank name.
    def find?(name : String?) : Store::Participant?
      name = MCP.given(name) || return
      MCP.find_named(@people, "person", name)
    end

    # A person who is not archived.
    def active(arg : String, name : String?) : Store::Participant
      name = MCP.given(name) || raise MCP.invalid("Parameter #{arg} is missing.")
      available = [] of String
      @people.each do |person|
        same = person.name.compare(name, case_insensitive: true).zero?
        if person.archived?
          raise MCP.invalid("#{person.name} is archived and cannot take part in new entries.") if same
        else
          return person if same
          available << person.name
        end
      end
      raise MCP.invalid("Unknown person #{name.inspect} in #{arg}. Available: #{available.join(", ")}.")
    end
  end

  class Server
    @tools = {} of String => Tool

    def initialize(@d : Web::Deps)
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
      %(Today is #{Store.format_date(today)} (#{today.day_of_week}), server time zone #{@d.config.location_name}. ) +
        %(Resolve relative periods such as "last month" from this date.)
    end

    # With the data overview, left out if it cannot be read.
    def instructions : String
      text = INSTRUCTIONS_TEXT + "\n" + today_line
      begin
        text + "\n" + MCP.overview_text(@d.store.overview)
      rescue ex
        Log.error(exception: ex) { "mcp: data overview" }
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

    private def directory : Directory
      Directory.new(@d.store.list_participants(include_archived: true))
    end

    private def add(args : T.class, name : String, title : String, description : String, properties : Hash(String, Prop),
                    required : Array(String)? = nil, annotations = READ_ONLY, &run : T -> R) forall T, R
      definition = ToolDefinition.new(name, title, description, ObjectSchema.new(properties, required), annotations)
      @tools[name] = Tool.new(definition, ->(raw : String?) do
        result = run.call(MCP.args(T, raw))
        result.is_a?(String) ? result : result.to_json
      end)
    end

    private def register_read_tools : Nil
      text_prop = Schema.text_or_list(
        %(Substring of the title or notes (case-insensitive). A list matches if any of the terms occurs, e.g. ["Rewe", "Edeka", "Lidl"].))

      add(NoArgs, "balances", "Balances and settlement",
        "Current balance of each person in euros and a settlement proposal (who transfers how much to whom so that everyone ends at 0). " \
        "Positive balance = is owed money, negative = owes money. Includes all non-deleted expenses and reimbursements.",
        {} of String => Prop) { balances }

      add(HistoryArgs, "balance_history", "Balance history",
        "Balance of each person at the end of each month (or week/year): how the balances developed over time. " \
        "Based on the current data by expense date (later edits and deletions apply retroactively). " \
        "Positive balance = is owed money, negative = owes money. Reimbursements count.",
        {
          "interval" => Schema.choice(Domain::PeriodUnit, "Length of a period: month (default), week (ISO week) or year."),
          "from"     => Schema.date("First period: the one containing this date. Default: the first expense."),
          "to"       => Schema.date("Last period: the one containing this date. Default: today."),
          "person"   => Schema.text("Name of a person: only their balance. Empty = everyone."),
        }) { |a| balance_history(a) }

      add(SearchArgs, "search_expenses", "Search expenses",
        "Searches individual expenses (newest first unless sort says otherwise) with amount, payer and category; with detail=full also split (each person's share), notes and foreign currency. " \
        "All filters are optional and are combined. Also returns the total number of matches, their total and – with person – " \
        "the total of that person's shares. For plain totals by category/month, statistics is the better choice.",
        {
          "from"           => Schema.date("First date (inclusive)."),
          "to"             => Schema.date("Last date (inclusive)."),
          "category"       => Schema.text(%(Category name, e.g. "Lebensmittel". ) + CATEGORY_HINT),
          "person"         => Schema.text("Name of a person: finds expenses they paid OR take part in."),
          "paid_by"        => Schema.text("Name of a person: only expenses this person paid."),
          "involved"       => Schema.text("Name of a person: only expenses this person has a share in."),
          "text"           => text_prop,
          "min_amount"     => Schema.number("Smallest amount in euros (inclusive), e.g. 50 or 12.5.", minimum: 0),
          "max_amount"     => Schema.number("Largest amount in euros (inclusive).", minimum: 0),
          "reimbursements" => Schema.choice(ReimbursementFilter,
            "Reimbursements (settlement payments between people): hide them (exclude, default), include them (include) or return only them (only)."),
          "sort"   => Schema.choice(Store::ExpenseSort, "Order of the expenses: date_desc (newest first, default), date_asc, amount_desc (most expensive first), amount_asc."),
          "detail" => Schema.choice(Detail, "compact (default): id, date, title, category, payer and amount per expense. full: additionally split, each person's share, notes and foreign currency."),
          "limit"  => Schema.limit("Maximum number of expenses returned, default 50."),
        }) { |a| search_expenses(a) }

      add(StatisticsArgs, "statistics", "Statistics",
        "Expense totals grouped by category, title (merchant), year, month (YYYY-MM), ISO week (YYYY-Www), person or category_month, optionally for a period. " \
        "Without share_of: total amounts of the expenses. With share_of: only that person's share of each expense, i.e. what they consumed themselves " \
        "(e.g. \"How much did I spend on restaurants in 2026?\"). With group_by=person, amount is each person's share (consumption) " \
        "and paid is what they paid up front. year, month and week list periods without expenses with 0. " \
        "compare=previous_year adds the amount of the same group one year earlier and the change. Reimbursements and deleted expenses never count.",
        {
          "group_by" => Schema.choice(Store::StatsGroup, "What to group by. title groups by expense title (case-insensitive), i.e. by merchant."),
          "from"     => Schema.date("First date (inclusive)."),
          "to"       => Schema.date("Last date (inclusive)."),
          "share_of" => Schema.text("Name of a person: only their share counts (that person's perspective). Empty = total amounts."),
          "category" => Schema.text("Only count expenses of this category (name, case-insensitive). " + CATEGORY_HINT),
          "text"     => text_prop,
          "compare"  => Schema.choice(Comparison,
            "previous_year: compare each row with the same group one year earlier (month 2026-03 with 2025-03, category in from…to with from…to minus one year). " \
            "For category, title and person, from is required."),
          "limit" => Schema.limit("Maximum number of rows, default #{SQLSandbox::MAX_ROWS}. total always covers all rows."),
        }, ["group_by"]) { |a| statistics(a) }

      add(ActivityArgs, "activity", "Activity log",
        "Who created, changed or deleted which expense when, and other changes (settings, people, categories, rates, recurring expenses), newest first. " \
        "Entries of expense_updated list the changed fields with old and new value (field names and values as shown in the app, in German).",
        {
          "from"       => Schema.date("First day (inclusive, server time zone)."),
          "to"         => Schema.date("Last day (inclusive, server time zone)."),
          "person"     => Schema.text("Name of a person: only changes they made."),
          "action"     => Schema.choice(Store::Action, "Only this action, e.g. expense_created, expense_updated, expense_deleted, settings_updated."),
          "expense_id" => Schema.integer("Only entries of this expense (id as in search_expenses).", minimum: 1),
          "before_id"  => Schema.integer("Paging: only entries with a smaller id (pass the id of the last entry of the previous page).", minimum: 1),
          "limit"      => Schema.limit("Maximum number of entries, default 50."),
        }) { |a| activity(a) }

      add(NoArgs, "schema", "Database schema",
        "Explains the database tables and columns in words (amounts in cents, deleted expenses, reimbursements, shares, foreign currency), " \
        "lists people and categories and returns the CREATE statements. Call before sql_query.",
        {} of String => Prop) { schema }

      add(SQLArgs, "sql_query", "SQL query",
        "Runs exactly one read-only SQL query (SQLite dialect, only SELECT or WITH … SELECT) on a read-only copy of the data. " \
        "Call schema first. Important: amounts are cents (divide by 100.0 for euros), exclude deleted expenses with deleted_at IS NULL, " \
        "reimbursements (is_reimbursement = 1) are not expenses, a person's share is expense_shares.amount_cents. " \
        "At most #{SQLSandbox::MAX_ROWS} rows, aborted after #{SQLSandbox::TIMEOUT.total_seconds.to_i} seconds, texts longer than #{SQLSandbox::MAX_CELL_CHARS} characters are truncated. " \
        "For standard questions, balances, search_expenses and statistics are simpler.",
        {"query" => Schema.text("The SQL query, e.g. SELECT name FROM participants WHERE archived_at IS NULL")},
        ["query"]) { |a| sql_query(a) }
    end

    private def find_category(name : String) : Store::Category
      MCP.find_named(@d.store.list_categories(include_archived: true), "category", name)
    end

    # A category name, or "none" / "No category" (the statistics label) for
    # expenses without a category; a real category of that name wins.
    # Returns {category_id, without_category}.
    private def category_arg(name : String?) : {Int64?, Bool}
      name = MCP.given(name) || return {nil, false}
      {find_category(name).id, false}
    rescue ex : Domain::ValidationError
      raise ex unless {NO_CATEGORY_ARG, NO_CATEGORY_LABEL}.any? { |label| name.try(&.compare(label, case_insensitive: true).zero?) }
      {nil, true}
    end

    private def balances : BalancesOut
      balances = @d.store.balances
      directory = self.directory
      entries = directory.people.compact_map do |person|
        cents = balances[person.id]? || 0_i64
        next if person.archived? && cents == 0
        BalanceOut.of(person.name, cents, cents > 0 ? "is owed money" : (cents < 0 ? "owes money" : "settled"))
      end
      transfers = Domain.settle(balances).map { |t| SettlementOut.of(directory.name(t.from), directory.name(t.to), t.amount_cents) }
      BalancesOut.new(entries, "Positive balance = is owed money, negative = owes money. settlements: the transfers needed so that everyone ends at 0.", transfers)
    end

    private def check_period_count(periods : Array(String)) : Nil
      return if periods.size <= SQLSandbox::MAX_ROWS
      raise MCP.invalid("That is #{periods.size} periods, at most #{SQLSandbox::MAX_ROWS} are possible. " \
                        "Please narrow down from/to or choose a longer interval.")
    end

    private def balance_history(a : HistoryArgs) : HistoryOut
      unit = a.interval || Domain::PeriodUnit::Month
      from, to = MCP.parse_range(a.from, a.to)
      directory = self.directory
      person = directory.find?(a.person)
      today = self.today
      # The obvious case before loading anything.
      check_period_count(Domain::Period.labels(unit, from, MCP.min_time(to, today))) if from

      # Up to the end of the last period: each row is the balance after all
      # expenses dated in or before its period.
      entries = @d.store.dated_balance_entries(to.try { |t| Domain::Period.last_day(unit, t) })
      if to.nil?
        # Until today, or the last expense if one is dated later: the last row
        # then equals the current balances.
        to = today
        if (last = entries.last?) && last.date > to
          to = last.date
        end
      end
      from = entries.first?.try(&.date) if from.nil?
      from = to unless from && from <= to
      periods = Domain::Period.labels(unit, from, to)
      check_period_count(periods)

      # Expenses before the first period are the opening balance.
      balance = Hash(Int64, Int64).new(0_i64)
      ever_non_zero = Set(Int64).new
      i = 0
      rows = periods.map do |label|
        until_period = [] of Domain::Entry
        while i < entries.size && Domain::Period.label(unit, entries[i].date) <= label
          until_period << entries[i].entry
          i += 1
        end
        Domain.balances(until_period).each { |id, v| balance[id] += v }
        balance.each { |id, v| ever_non_zero << id if v != 0 }
        shown = directory.people.reject { |pp| person ? pp.id != person.id : (pp.archived? && !ever_non_zero.includes?(pp.id)) }
        HistoryRow.new(unit, label, shown.map { |pp| BalanceOut.of(pp.name, balance[pp.id]? || 0_i64) })
      end
      HistoryOut.new(unit.to_s.underscore,
        "Balance after all expenses dated up to the end of each period (in the current period also those dated later this period), " \
        "positive = is owed money, negative = owes money. Without to, the last row equals the current balances. " \
        "Computed from the current data by expense date: later edits and deletions apply retroactively.",
        MCP.describe_range(from, to), rows)
    end

    private def search_expenses(a : SearchArgs) : SearchOut
      from, to = MCP.parse_range(a.from, a.to)
      category_id, without_category = category_arg(a.category)
      directory = self.directory
      person, payer, involved = directory.find?(a.person), directory.find?(a.paid_by), directory.find?(a.involved)
      min_cents = MCP.amount_cents("min_amount", a.min_amount)
      max_cents = MCP.amount_cents("max_amount", a.max_amount)
      raise MCP.invalid("max_amount must be greater than 0.") if max_cents == 0
      if min_cents && max_cents && min_cents > max_cents
        raise MCP.invalid("min_amount (#{MCP.eur(min_cents)}) is greater than max_amount (#{MCP.eur(max_cents)}).")
      end
      mode = a.reimbursements || ReimbursementFilter::Exclude
      filter = Store::ExpenseFilter.new(any_text: a.text, from: from, to: to, category_id: category_id,
        without_category: without_category, participant_id: person.try(&.id), paid_by: payer.try(&.id),
        involved_id: involved.try(&.id), min_cents: min_cents, max_cents: max_cents,
        sort: a.sort || Store::ExpenseSort::DateDesc)
      sharer = person || involved # whose shares are summed up
      limit = MCP.limit(a.limit, 50)

      matches = @d.store.list_expenses(filter).select do |e|
        mode.include? || e.reimbursement? == mode.only?
      end
      shown = matches.first(limit)
      full = a.detail == Detail::Full
      total = matches.sum(0_i64, &.amount_cents)
      person_share = sharer.try do |s|
        share = matches.sum(0_i64, &.share_of(s.id))
        PersonShareOut.new(MCP.eur(share), share, s.name)
      end
      SearchOut.new(shown.map { |e| ExpenseOut.new(e, directory.names, full) }, matches.size, person_share, shown.size,
        MCP.eur(total), total, matches.size > shown.size)
    end

    private def statistics(a : StatisticsArgs) : StatisticsOut
      group = a.group_by || raise MCP.one_of("group_by", Store::StatsGroup)
      from, to = MCP.parse_range(a.from, a.to)
      category_id, without_category = category_arg(a.category)
      perspective = "total amounts of the expenses"
      participant_id = nil
      if person = directory.find?(a.share_of)
        participant_id = person.id
        perspective = "only the share of #{person.name}"
      end
      limit = MCP.limit(a.limit, SQLSandbox::MAX_ROWS)
      today = self.today
      compare = !a.compare.nil?
      time_keyed = group.time? || group.category_month?
      if compare && !time_keyed
        range_start = from || raise MCP.invalid("compare=previous_year with group_by=#{group.to_s.underscore} needs from (and optionally to): the period to compare.")
        if to.nil?
          if today < range_start
            raise MCP.invalid("from (#{Store.format_date(range_start)}) is in the future; compare=previous_year needs a period up to today or an explicit to.")
          end
          to = today
        end
      end
      filter = Store::StatsFilter.new(group_by: group, from: from, to: to, participant_id: participant_id,
        category_id: category_id, without_category: without_category, any_text: a.text)

      stat_rows = @d.store.stats(filter)
      rows = group.time? ? Statistics.fill_gaps(stat_rows, filter, today) : stat_rows
      total = rows.sum(0_i64, &.amount_cents)
      previous_period = nil
      pairs = rows.map { |row| {row, nil.as(Int64?)} }
      if compare
        previous_filter = filter.copy_with(from: filter.from.try(&.shift(years: -1)), to: filter.to.try(&.shift(years: -1)))
        # Without from and to, the previous year's rows are the same rows.
        previous_rows = previous_filter.from || previous_filter.to ? @d.store.stats(previous_filter) : stat_rows
        window = time_keyed ? Statistics.period_window(filter, stat_rows, today) : nil
        pairs = Statistics.with_previous(rows, previous_rows, window, group).map { |row, previous| {row, previous.as(Int64?)} }
        previous_period = time_keyed ? "each #{group.to_s.underscore.lchop("category_")} one year earlier" : MCP.describe_range(previous_filter.from, previous_filter.to)
      end
      note = "Reimbursements and deleted expenses are not included. count = number of expenses."
      note += " amount = the person's share (consumption), paid = what they paid for the group." if group.person?
      if compare
        note += " previous = same group one year earlier, change = amount − previous, change_percent relative to previous (missing if previous is 0)."
      end
      previous_total = pairs.sum(0_i64) { |_, previous| previous || 0_i64 } if compare
      StatisticsOut.new(group.to_s.underscore, note, MCP.describe_range(filter.from, filter.to), perspective,
        previous_period, MCP.eur?(previous_total), previous_total,
        pairs.first(limit).map { |row, previous| StatLine.new(row, group, previous) }, pairs.size,
        MCP.eur(total), total, pairs.size > limit)
    end

    private def activity(a : ActivityArgs) : ActivityOut
      from, to = MCP.parse_range(a.from, a.to)
      location = self.location
      since = from.try { |t| Time.local(t.year, t.month, t.day, location: location) }
      until_ = to.try { |t| Time.local(t.year, t.month, t.day, location: location).shift(days: 1) }
      actor = directory.find?(a.person).try(&.id)
      if {a.expense_id, a.before_id}.any? { |id| id && id < 1 }
        raise MCP.invalid("expense_id and before_id must be positive.")
      end
      limit = MCP.limit(a.limit, 50)
      entries = @d.store.list_activity(Store::ActivityFilter.new(expense_id: a.expense_id, actor_id: actor,
        action: a.action, since: since, until: until_, before_id: a.before_id, limit: limit + 1))
      more = entries.size > limit
      entries = entries.first(limit)
      note = "There are older entries: call again with before_id=#{entries.last.id}." if more
      ActivityOut.new(entries.map { |entry| ActivityEntryOut.new(entry, location) }, more, note, entries.size)
    end

    private def schema : String
      directory = self.directory
      categories = @d.store.list_categories(include_archived: true)
      String.build do |b|
        b << today_line << "\n\n" << SCHEMA_TEXT
        b << "\nPeople (id: name): "
        directory.people.join(b, ", ") { |p, io| io << p.id << ": " << p.name << (p.archived? ? " (archived)" : "") }
        b << "\nCategories (id: name): "
        categories.join(b, ", ") { |c, io| io << c.id << ": " << c.name << (c.archived? ? " (archived)" : "") }
        b << "\n\nCREATE statements:\n"
        @d.store.schema.each { |o| b << o.sql << ";\n" }
      end
    end

    private def sql_query(a : SQLArgs) : QueryOut
      query = a.query
      raise MCP.invalid("Parameter query is missing.") if query.nil? || query.blank?
      result = SQLSandbox.new(@d.store.path).query(query)
      note = "There are more than #{SQLSandbox::MAX_ROWS} rows; only the first #{SQLSandbox::MAX_ROWS} are included. " \
             "Please aggregate or narrow down with WHERE/LIMIT." if result.truncated
      QueryOut.new(result.columns, note, result.rows.size, result.rows.map { |row| row.map { |value| json_value(value) } },
        result.truncated)
    end

    # JSON has no infinite numbers.
    private def json_value(value : SQLSandbox::Value) : SQLSandbox::Value
      value.is_a?(Float64) && !value.finite? ? value.to_s : value
    end
  end
end
