module Zipfelkasse::MCP
  # Runs a single SELECT/WITH query of the sql_query tool in a sandbox and
  # returns at most MAX_ROWS rows. Input and SQL errors are ValidationErrors
  # (English).
  #
  # The sandbox is a fresh in-memory database: Store::EXPOSED_TABLES are
  # copied into it from the database file in one read transaction, then the
  # file is detached. The YNAB tables do not exist there at all. Further
  # layers: no ATTACH (sqlite3_limit), query_only, the lexical check, and the
  # query embedded as a CTE body so that only a SELECT parses.
  class SQLSandbox
    MAX_ROWS       = 500
    TIMEOUT        = 5.seconds # total, including the copy
    MAX_CELL_RUNES = 2000
    MAX_RESULT     = 8 << 20 # bytes, SQLITE_LIMIT_LENGTH

    alias Value = Int64 | Float64 | String | Nil

    struct Result
      getter columns : Array(String)
      getter rows : Array(Array(Value))
      getter? truncated : Bool # there were more than MAX_ROWS rows

      def initialize(@columns, @rows, @truncated = false)
      end
    end

    def initialize(@path : String)
    end

    def query(query : String, timeout : Time::Span = TIMEOUT) : Result
      body = SQLSandbox.check_select(query)
      deadline = Time.instant + timeout
      begin
        with_sandbox(deadline) { |conn| SQLSandbox.run_wrapped(conn, body) }
      rescue ex : Domain::ValidationError
        raise ex
      rescue ex
        raise SQLSandbox.sandbox_error(ex, deadline)
      end
    end

    protected def self.sandbox_error(ex : Exception, deadline : Time::Instant) : Exception
      if Time.instant >= deadline
        return Domain::ValidationError.new("The query was aborted after #{TIMEOUT.total_seconds.to_i} s. " \
                                           "Please narrow it down (WHERE, LIMIT) or simplify it.")
      end
      return ex unless ex.is_a?(SQLite3::Exception)
      if ex.code == LibSQLite3::Code::TOOBIG.value
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
      conn = SQLite3::Connection.new(DB::Connection::Options.new, SQLite3::Connection::Options.new(filename: ":memory:"))
      begin
        Store.setup(conn)
        LibSQLite3.progress_handler(conn.to_unsafe, 1000, ->(arg : Void*) {
          Time.instant >= arg.as(Time::Instant*).value ? 1 : 0
        }, pointerof(deadline).as(Void*))
        fill_sandbox(conn)
        yield conn
      ensure
        conn.close
      end
    end

    private def fill_sandbox(conn : SQLite3::Connection) : Nil
      conn.exec("ATTACH DATABASE ? AS src", File.expand_path(@path))
      # One read transaction: all tables from the same snapshot.
      conn.exec("BEGIN")
      begin
        Store.schema_objects(conn, "src").each do |o|
          conn.exec(o.sql)
          conn.exec(%(INSERT INTO main."#{o.name}" SELECT * FROM src."#{o.name}")) if o.type == "table"
        end
        conn.exec("COMMIT")
      rescue ex
        conn.exec("ROLLBACK") rescue nil
        raise ex
      end
      conn.exec("DETACH DATABASE src")
      handle = conn.to_unsafe
      LibSQLite3.limit(handle, LibSQLite3::SQLITE_LIMIT_ATTACHED, 0)
      LibSQLite3.limit(handle, LibSQLite3::SQLITE_LIMIT_LENGTH, MAX_RESULT)
      conn.exec("PRAGMA query_only = ON")
    end

    # Embeds body as
    #
    #     WITH mcp_u(c0, c1, …) AS (<body>)
    #     SELECT count(*), json_group_array(json_array(…)) FROM (SELECT * FROM mcp_u LIMIT n+1)
    #
    # so the whole result comes from a single step and only a SELECT parses.
    # Reals go through quote(): SQLite >= 3.54 writes them with only 15
    # significant digits in JSON.
    def self.run_wrapped(conn : SQLite3::Connection, body : String) : Result
      columns = column_names(conn, body)
      if columns.empty?
        raise Domain::ValidationError.new("The query returns no columns. Only SELECT or WITH … SELECT is allowed.")
      end
      aliases = Array.new(columns.size) { |i| "c#{i}" }
      cells = aliases.map do |a|
        "CASE typeof(#{a}) WHEN 'blob' THEN '[BLOB, ' || length(#{a}) || ' Bytes]' " \
        "WHEN 'text' THEN substr(#{a}, 1, #{MAX_CELL_RUNES}) " \
        "WHEN 'real' THEN json(quote(#{a})) ELSE #{a} END"
      end
      q = "WITH mcp_u(#{aliases.join(", ")}) AS (\n#{body}\n)\n" \
          "SELECT count(*), json_group_array(json_array(#{cells.join(", ")})) FROM (SELECT * FROM mcp_u LIMIT #{MAX_ROWS + 1})"
      _, data = conn.query_one(q, as: {Int64, String})
      rows = parse_rows(data)
      truncated = rows.size > MAX_ROWS
      Result.new(columns, truncated ? rows[0, MAX_ROWS] : rows, truncated)
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
    private def self.parse_rows(data : String) : Array(Array(Value))
      pull = JSON::PullParser.new(data)
      rows = [] of Array(Value)
      pull.read_array do
        row = [] of Value
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
  end
end
