module Zipfelkasse
  class Store
    # Tables visible via MCP (schema, sql_query). An allowlist on purpose: new
    # tables only become visible once listed here; the YNAB tables (token!)
    # stay out.
    MCP_TABLES = %w(participants categories expenses expense_shares recurring activity fx_rates settings)

    # Restricts tables when they are copied into the sandbox. YNAB keeps its
    # state in ynab_config; should ynab… keys reappear in settings, they stay
    # hidden all the same.
    MCP_ROW_FILTER = {"settings" => "key NOT LIKE 'ynab%'"}

    SQL_MAX_ROWS       = 500
    SQL_TIMEOUT        = 5.seconds # total, including the copy
    SQL_MAX_CELL_RUNES = 2000
    SQL_MAX_RESULT     = 8 << 20 # bytes, SQLITE_LIMIT_LENGTH

    alias SQLValue = Int64 | Float64 | String | Nil

    struct QueryResult
      getter columns : Array(String)
      getter rows : Array(Array(SQLValue))
      getter? truncated : Bool # there were more than SQL_MAX_ROWS rows

      def initialize(@columns, @rows, @truncated = false)
      end
    end

    # type is "table" or "index".
    record SchemaObject, type : String, name : String, sql : String

    # Deleted expenses do not count; the dates are nil without any expense.
    record DataOverview, expenses : Int64, reimbursements : Int64, without_category : Int64,
      first_date : Time?, last_date : Time?, activity_actions : Array(String)

    # CREATE statements of MCP_TABLES and their indexes, tables first.
    def mcp_schema : Array(SchemaObject)
      Store.schema_objects(@db, "main")
    end

    protected def self.schema_objects(db : DB::QueryMethods, schema : String) : Array(SchemaObject)
      objects = [] of SchemaObject
      db.query_each("SELECT type, name, tbl_name, sql FROM #{schema}.sqlite_schema " \
                    "WHERE type IN ('table', 'index') AND sql IS NOT NULL ORDER BY type DESC, rowid") do |rs|
        type, name, table, sql = rs.read(String, String, String, String)
        objects << SchemaObject.new(type, name, sql) if MCP_TABLES.includes?(table)
      end
      objects
    end

    def mcp_overview : DataOverview
      expenses, reimbursements, without, first, last = @db.query_one(
        "SELECT coalesce(sum(is_reimbursement = 0), 0), coalesce(sum(is_reimbursement = 1), 0), " \
        "coalesce(sum(is_reimbursement = 0 AND category_id IS NULL), 0), min(date), max(date) " \
        "FROM expenses WHERE deleted_at IS NULL", as: {Int64, Int64, Int64, String?, String?})
      actions = @db.query_all("SELECT DISTINCT action FROM activity ORDER BY action", as: String)
      DataOverview.new(expenses, reimbursements, without,
        first.try { |d| Store.parse_date(d) }, last.try { |d| Store.parse_date(d) }, actions)
    end

    # Runs a single SELECT/WITH query in a sandbox and returns at most
    # SQL_MAX_ROWS rows. Input and SQL errors are ValidationErrors (English).
    #
    # The sandbox is a fresh in-memory database: MCP_TABLES are copied into it
    # from the file attached read-only, in one read transaction, then the file
    # is detached. The YNAB tables do not exist there at all. Further layers:
    # no ATTACH (sqlite3_limit), query_only, the lexical check, and the query
    # embedded as a CTE body so that only a SELECT parses.
    def read_only_query(query : String, timeout : Time::Span = SQL_TIMEOUT) : QueryResult
      body = Store.check_select(query)
      deadline = Time.instant + timeout
      begin
        with_sandbox(deadline) { |conn| Store.run_wrapped(conn, body) }
      rescue ex : Domain::ValidationError
        raise ex
      rescue ex
        raise Store.sandbox_error(ex, deadline)
      end
    end

    protected def self.sandbox_error(ex : Exception, deadline : Time::Instant) : Exception
      if Time.instant >= deadline
        return Domain::ValidationError.new("The query was aborted after #{SQL_TIMEOUT.total_seconds.to_i} s. " \
                                           "Please narrow it down (WHERE, LIMIT) or simplify it.")
      end
      return ex unless ex.is_a?(SQLite3::Exception)
      if ex.code == LibSQLite3::SQLITE_TOOBIG
        return Domain::ValidationError.new("The result is too large. Please query fewer columns/rows.")
      end
      Domain::ValidationError.new("SQL error: #{sqlite_error_text(ex)}")
    end

    # "<error class>: <message> (<code>)" without the most common class
    # "SQL logic error", e.g. "no such table: x (1)".
    protected def self.sqlite_error_text(ex : SQLite3::Exception) : String
      kind = String.new(LibSQLite3.errstr(ex.code))
      msg = ex.message || ""
      text = msg == kind ? "#{kind} (#{ex.code})" : "#{kind}: #{msg} (#{ex.code})"
      text.lchop("SQL logic error: ")
    end

    # Yields the locked-down sandbox connection; SQLite interrupts every
    # statement on it once deadline has passed (a timer fiber could not run
    # while sqlite3_step blocks the thread).
    def with_sandbox(deadline : Time::Instant, & : SQLite3::Connection -> T) : T forall T
      if @path.empty? || @path == ":memory:"
        raise Domain::ValidationError.new("sql_query needs a database file (not available with :memory:).")
      end
      src = Store.read_only_uri(File.expand_path(@path))
      conn = SQLite3::Connection.new(DB::Connection::Options.new, ":memory:",
        SQLite3::Flag::READWRITE | SQLite3::Flag::CREATE | SQLite3::Flag::URI)
      begin
        Store.setup(conn)
        LibSQLite3.progress_handler(conn.to_unsafe, 1000, ->(arg : Void*) {
          Time.instant >= arg.as(Time::Instant*).value ? 1 : 0
        }, pointerof(deadline).as(Void*))
        Store.fill_sandbox(conn, src)
        yield conn
      ensure
        conn.close
      end
    end

    protected def self.fill_sandbox(conn : SQLite3::Connection, src : String) : Nil
      conn.exec("ATTACH DATABASE ? AS src", src)
      # One read transaction: all tables from the same snapshot.
      conn.exec("BEGIN")
      begin
        schema_objects(conn, "src").each do |o|
          conn.exec(o.sql)
          next unless o.type == "table"
          q = %(INSERT INTO main."#{o.name}" SELECT * FROM src."#{o.name}")
          if filter = MCP_ROW_FILTER[o.name]?
            q += " WHERE " + filter
          end
          conn.exec(q)
        end
        conn.exec("COMMIT")
      rescue ex
        conn.exec("ROLLBACK") rescue nil
        raise ex
      end
      conn.exec("DETACH DATABASE src")
      handle = conn.to_unsafe
      LibSQLite3.limit(handle, LibSQLite3::SQLITE_LIMIT_ATTACHED, 0)
      LibSQLite3.limit(handle, LibSQLite3::SQLITE_LIMIT_LENGTH, SQL_MAX_RESULT)
      conn.exec("PRAGMA query_only = ON")
    end

    # file:///abs/path?mode=ro, the path percent-encoded like a URL path.
    protected def self.read_only_uri(path : String) : String
      String.build do |io|
        io << "file://"
        path.each_byte do |b|
          c = b.unsafe_chr
          if c.ascii_alphanumeric? || "-_.~$&+,/:;=@".includes?(c)
            io << c
          else
            io << '%' << b.to_s(16, upcase: true).rjust(2, '0')
          end
        end
        io << "?mode=ro"
      end
    end

    # Embeds body as
    #
    #     WITH mcp_u(c0, c1, …) AS (<body>)
    #     SELECT count(*), json_group_array(json_array(…)) FROM (SELECT * FROM mcp_u LIMIT n+1)
    #
    # so the whole result comes from a single step and only a SELECT parses.
    # Reals go through quote(): SQLite >= 3.54 writes them with only 15
    # significant digits in JSON.
    def self.run_wrapped(conn : SQLite3::Connection, body : String) : QueryResult
      columns = column_names(conn, body)
      if columns.empty?
        raise Domain::ValidationError.new("The query returns no columns. Only SELECT or WITH … SELECT is allowed.")
      end
      aliases = Array.new(columns.size) { |i| "c#{i}" }
      cells = aliases.map do |a|
        "CASE typeof(#{a}) WHEN 'blob' THEN '[BLOB, ' || length(#{a}) || ' Bytes]' " \
        "WHEN 'text' THEN substr(#{a}, 1, #{SQL_MAX_CELL_RUNES}) " \
        "WHEN 'real' THEN json(quote(#{a})) ELSE #{a} END"
      end
      q = "WITH mcp_u(#{aliases.join(", ")}) AS (\n#{body}\n)\n" \
          "SELECT count(*), json_group_array(json_array(#{cells.join(", ")})) FROM (SELECT * FROM mcp_u LIMIT #{SQL_MAX_ROWS + 1})"
      _, data = conn.query_one(q, as: {Int64, String})
      rows = parse_rows(data)
      truncated = rows.size > SQL_MAX_ROWS
      QueryResult.new(columns, truncated ? rows[0, SQL_MAX_ROWS] : rows, truncated)
    end

    # From preparing body alone; empty for an empty statement.
    private def self.column_names(conn : SQLite3::Connection, body : String) : Array(String)
      handle = conn.to_unsafe
      if LibSQLite3.prepare_v2(handle, body, body.bytesize, out stmt, nil) != 0
        raise SQLite3::Exception.new(handle)
      end
      return [] of String if stmt.null?
      begin
        Array.new(LibSQLite3.column_count(stmt)) { |i| String.new(LibSQLite3.column_name(stmt, i)) }
      ensure
        LibSQLite3.finalize(stmt)
      end
    end

    # SQLite writes infinite reals as ±9.0e+999, which no Float64 parser
    # accepts.
    private def self.parse_rows(data : String) : Array(Array(SQLValue))
      pull = JSON::PullParser.new(data)
      rows = [] of Array(SQLValue)
      pull.read_array do
        row = [] of SQLValue
        pull.read_array do
          row << case pull.kind
          when .int? then pull.read_int
          when .float?
            raw = pull.read_raw
            raw.to_f64? || (raw.starts_with?('-') ? -Float64::INFINITY : Float64::INFINITY)
          when .string? then pull.read_string
          else               pull.read_null
          end
        end
        rows << row
      end
      rows
    end

    # Checks lexically that query is exactly one statement starting with
    # SELECT or WITH and returns it without the trailing ";". Follows SQLite's
    # tokenizer: '…', "…", `…` (doubling escapes), […], -- and /* */
    # comments. Tokens after the first ";" may only be quoted or comments.
    def self.check_select(query : String) : String
      raise Domain::ValidationError.new("The query contains a NUL character.") if query.includes?('\0')
      size = query.bytesize
      finish = size
      first = ""
      i = 0
      while i < size
        c = query.byte_at(i).unsafe_chr
        case
        when c.in?(' ', '\t', '\n', '\r', '\f', '\v')
          i += 1
        when c == '-' && byte_char(query, i + 1) == '-'
          i = (query.byte_index('\n', i) || size - 1) + 1
        when c == '/' && byte_char(query, i + 1) == '*'
          e = query.byte_index("*/", i + 2)
          i = e ? e + 2 : size
        when c.in?('\'', '"', '`')
          i = skip_quoted(query, i, c, c)
        when c == '['
          i = skip_quoted(query, i, '[', ']')
        when c == ';'
          finish = i if finish == size
          i += 1
        else
          if finish != size
            raise Domain::ValidationError.new(%(Please send only a single query (no second statement after ";").))
          end
          if first.empty?
            j = i
            while byte_char(query, j).try { |d| d.ascii_letter? || d == '_' }
              j += 1
            end
            first = j > i ? query.byte_slice(i, j - i).upcase : c.to_s
          end
          i += 1
        end
      end
      unless first.in?("SELECT", "WITH")
        raise Domain::ValidationError.new("Only a single read-only query is allowed (SELECT … or WITH … SELECT …).")
      end
      query.byte_slice(0, finish)
    end

    private def self.byte_char(s : String, i : Int32) : Char?
      s.byte_at?(i).try(&.unsafe_chr)
    end

    # The position after the literal that starts at i.
    private def self.skip_quoted(s : String, i : Int32, open : Char, close : Char) : Int32
      j = i + 1
      while j < s.bytesize
        if byte_char(s, j) == close
          return j + 1 unless open == close && byte_char(s, j + 1) == close
          j += 1 # doubled quote character
        end
        j += 1
      end
      s.bytesize
    end

    # Groupings of `stats` (also the group_by values of the MCP statistics tool).
    STATS_BY_CATEGORY       = "category"
    STATS_BY_TITLE          = "title"
    STATS_BY_YEAR           = "year"
    STATS_BY_MONTH          = "month"
    STATS_BY_WEEK           = "week"
    STATS_BY_PERSON         = "person"
    STATS_BY_CATEGORY_MONTH = "category_month"

    # Periods look like "2026", "2026-09" and ISO week "2026-W40".
    STATS_PERIOD = {
      STATS_BY_YEAR           => "substr(e.date, 1, 4)",
      STATS_BY_MONTH          => "substr(e.date, 1, 7)",
      STATS_BY_WEEK           => "strftime('%G-W%V', e.date)",
      STATS_BY_CATEGORY_MONTH => "substr(e.date, 1, 7)",
    }

    # Group label of expenses without a category.
    NO_CATEGORY = "No category"

    # Reimbursements and deleted expenses never count.
    struct StatsFilter
      property group_by : String
      property from : Time? # inclusive
      property to : Time?   # inclusive
      # 0 = total amounts, otherwise only this person's share.
      property participant_id : Int64
      property category_id : Int64      # 0 = all
      property? without_category : Bool # category_id is then ignored
      property any_text : Array(String) # title or notes contain one of them

      def initialize(*, @group_by = "", @from = nil, @to = nil, @participant_id = 0_i64, @category_id = 0_i64,
                     @without_category = false, @any_text = [] of String)
      end
    end

    # Depending on the grouping, category, title, period and/or person are
    # set. title is one of the group's titles (grouped case-insensitively);
    # paid_cents is only set for person (paid by the person, while
    # amount_cents is their share).
    record StatRow, category : String = "", title : String = "", period : String = "", person : String = "",
      count : Int64 = 0_i64, amount_cents : Int64 = 0_i64, paid_cents : Int64 = 0_i64

    # Time groupings are sorted by period, the others by amount (largest
    # first); periods without expenses are missing (see `fill_periods`).
    def stats(f : StatsFilter) : Array(StatRow)
      where = ["e.deleted_at IS NULL", "e.is_reimbursement = 0"]
      args = [] of DB::Any
      if from = f.from
        where << "e.date >= ?"
        args << Store.format_date(from)
      end
      if to = f.to
        where << "e.date <= ?"
        args << Store.format_date(to)
      end
      if f.without_category?
        where << "e.category_id IS NULL"
      elsif f.category_id != 0
        where << "e.category_id = ?"
        args << f.category_id
      end
      cond, cond_args = Store.text_cond(f.any_text)
      unless cond.empty?
        where << cond
        args.concat(cond_args)
      end
      return stats_by_person(where, args, f.participant_id) if f.group_by == STATS_BY_PERSON

      from = "expenses e LEFT JOIN categories c ON c.id = e.category_id"
      amount = "e.amount_cents"
      if f.participant_id != 0
        from += " JOIN expense_shares x ON x.expense_id = e.id AND x.participant_id = ?"
        args.unshift(f.participant_id) # the JOIN comes before the WHERE
        amount = "x.amount_cents"
      end
      cat = "coalesce(c.name, '#{NO_CATEGORY}')"
      period = STATS_PERIOD[f.group_by]? || ""
      # Columns: label (category or title), period.
      sel, group, order =
        case f.group_by
        when STATS_BY_CATEGORY                            then {"#{cat}, ''", cat, "4 DESC, 1"}
        when STATS_BY_TITLE                               then {"max(e.title), ''", "#{FOLD_FUNC}(e.title)", "4 DESC, 1"}
        when STATS_BY_YEAR, STATS_BY_MONTH, STATS_BY_WEEK then {"'', #{period}", period, "2"}
        when STATS_BY_CATEGORY_MONTH                      then {"#{cat}, #{period}", "#{cat}, #{period}", "2, 4 DESC, 1"}
        else
          raise Domain::ValidationError.new("Unknown grouping #{f.group_by.inspect}.")
        end
      q = "SELECT #{sel}, count(*), sum(#{amount}) FROM #{from} WHERE #{where.join(" AND ")} GROUP BY #{group} ORDER BY #{order}"
      @db.query_all(q, args: args) do |rs|
        label, p, count, cents = rs.read(String, String, Int64, Int64)
        if f.group_by == STATS_BY_TITLE
          StatRow.new(title: label, period: p, count: count, amount_cents: cents)
        else
          StatRow.new(category: label, period: p, count: count, amount_cents: cents)
        end
      end
    end

    private def stats_by_person(where : Array(String), args : Array(DB::Any), participant_id : Int64) : Array(StatRow)
      cond = where.join(" AND ")
      q = <<-SQL
        SELECT p.name,
          (SELECT count(*) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id WHERE x.participant_id = p.id AND #{cond}),
          (SELECT coalesce(sum(x.amount_cents), 0) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id WHERE x.participant_id = p.id AND #{cond}),
          (SELECT coalesce(sum(e.amount_cents), 0) FROM expenses e WHERE e.paid_by = p.id AND #{cond})
          FROM participants p WHERE 1 = 1
        SQL
      # The conditions appear three times, so do their arguments.
      all = args + args + args
      if participant_id != 0
        q += " AND p.id = ?"
        all << participant_id
      end
      rows = @db.query_all(q, args: all) do |rs|
        person, count, cents, paid = rs.read(String, Int64, Int64, Int64)
        StatRow.new(person: person, count: count, amount_cents: cents, paid_cents: paid)
      end
      rows.reject! { |r| r.count == 0 && r.paid_cents == 0 }
      rows.sort_by { |r| {-r.amount_cents, r.person.downcase} }
    end

    # Groupings whose rows are periods only.
    def self.time_grouping?(group_by : String) : Bool
      group_by.in?(STATS_BY_YEAR, STATS_BY_MONTH, STATS_BY_WEEK)
    end

    # The period of day as in StatRow#period.
    def self.period_of(group_by : String, day : Time) : String
      case group_by
      when STATS_BY_YEAR then day.to_s("%Y")
      when STATS_BY_WEEK
        year, week = day.calendar_week
        "%d-W%02d" % {year, week}
      else day.to_s("%Y-%m")
      end
    end

    # Adds a zero row for every period of a time grouping between first and
    # last (inclusive) that has none. Rows outside that range stay.
    def self.fill_periods(rows : Array(StatRow), group_by : String, first : Time, last : Time) : Array(StatRow)
      return rows if !time_grouping?(group_by) || last < first
      have = rows.to_h { |r| {r.period, r} }
      filled = periods(group_by, first, last).map { |p| have.delete(p) || StatRow.new(period: p) }
      rows.each { |r| filled << r if have.has_key?(r.period) }
      filled.sort_by(&.period)
    end

    # The periods from the one containing first to the one containing last;
    # empty if last is before first.
    def self.periods(group_by : String, first : Time, last : Time) : Array(String)
      result = [] of String
      return result if last < first
      final = period_of(group_by, last)
      d = start_of_period(group_by, first)
      loop do
        p = period_of(group_by, d)
        result << p
        break if p >= final
        d = next_period(group_by, d)
      end
      result
    end

    # The last day of the period that contains day.
    def self.period_end(group_by : String, day : Time) : Time
      next_period(group_by, start_of_period(group_by, day)) - 1.day
    end

    # The first day of a period ("2026", "2026-09", "2026-W40"); nil if it
    # cannot be parsed.
    def self.period_start(group_by : String, period : String) : Time?
      case group_by
      when STATS_BY_YEAR
        m = /\A(\d{1,4})/.match(period) || return
        Time.utc(m[1].to_i, 1, 1)
      when STATS_BY_WEEK
        m = /\A(\d{1,4})-W(\d{1,2})/.match(period) || return
        # 4 January is always in week 1.
        start_of_period(STATS_BY_WEEK, Time.utc(m[1].to_i, 1, 4)) + (7 * (m[2].to_i - 1)).days
      else
        m = /\A(\d{1,4})-(\d{1,2})/.match(period) || return
        Time.utc(m[1].to_i, 1, 1).shift(months: m[2].to_i - 1)
      end
    rescue ArgumentError
      nil
    end

    # Moves a period ("2025-09", "2025-W40", "2025") by years; "" stays "".
    # Week 53 becomes week 52 in a year without week 53.
    def self.shift_period_year(period : String, years : Int32) : String
      y = period[0, 4].to_i?(whitespace: false) || return period
      y += years
      if period.ends_with?("-W53") && Time.utc(y, 12, 28).calendar_week[1] < 53
        return "%04d-W52" % y
      end
      "%04d" % y + (period[4..]? || "")
    end

    # Moves a date by years; 29 February becomes 28 February in a year that
    # is not a leap year.
    def self.shift_date_year(d : Time, years : Int32) : Time
      y = d.year + years
      day = Math.min(d.day, Time.days_in_month(y, d.month))
      Time.local(y, d.month, day, d.hour, d.minute, d.second, nanosecond: d.nanosecond, location: d.location)
    end

    private def self.start_of_period(group_by : String, d : Time) : Time
      case group_by
      when STATS_BY_YEAR then Time.utc(d.year, 1, 1)
      when STATS_BY_WEEK then Time.utc(d.year, d.month, d.day) - (d.day_of_week.value - 1).days
      else                    Time.utc(d.year, d.month, 1)
      end
    end

    private def self.next_period(group_by : String, d : Time) : Time
      case group_by
      when STATS_BY_YEAR then d.shift(years: 1)
      when STATS_BY_WEEK then d + 7.days
      else                    d.shift(months: 1)
      end
    end
  end
end
