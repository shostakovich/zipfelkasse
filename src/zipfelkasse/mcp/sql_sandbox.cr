module Zipfelkasse::MCP
  # Runs a single SELECT/WITH query of the sql_query tool in a sandbox and
  # returns at most MAX_ROWS rows. Input and SQL errors are ValidationErrors
  # (English).
  #
  # The sandbox is a fresh in-memory database: Store::EXPOSED_TABLES are
  # copied into it from the database file in one read transaction, then the
  # file is detached. The YNAB tables do not exist there at all. Further
  # layers: no ATTACH (sqlite3_limit), query_only, the lexical check, and the
  # query embedded as a subquery so that only a SELECT parses.
  #
  # SQLite blocks the only thread while it steps, so TIMEOUT is kept short:
  # the whole app waits for a slow query.
  class SQLSandbox
    MAX_ROWS       = 500
    TIMEOUT        = 2.seconds # total, including the copy
    MAX_CELL_CHARS = 2000
    MAX_RESULT     = 8 << 20 # bytes, SQLITE_LIMIT_LENGTH

    alias Value = Int64 | Float64 | String | Nil

    record Result, columns : Array(String), rows : Array(Array(Value)), truncated : Bool

    def initialize(@path : String)
    end

    def query(query : String, timeout : Time::Span = TIMEOUT) : Result
      body = SQLSandbox.check_select(query)
      deadline = Time.instant + timeout
      begin
        with_sandbox(deadline) { |conn| SQLSandbox.select_rows(conn, body) }
      rescue ex : SQLite3::Exception
        raise SQLSandbox.translate(ex, deadline)
      end
    end

    protected def self.translate(ex : SQLite3::Exception, deadline : Time::Instant) : Domain::ValidationError
      message = if Time.instant >= deadline
                  "The query was aborted after #{TIMEOUT.total_seconds.to_i} s. Please narrow it down (WHERE, LIMIT) or simplify it."
                elsif ex.code == LibSQLite3::Code::TOOBIG.value
                  "The result is too large. Please query fewer columns/rows."
                else
                  "SQL error: #{ex.message} (#{ex.code})"
                end
      Domain::ValidationError.new(message)
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

    # The newline ends a trailing "--" comment of the query.
    def self.select_rows(conn : SQLite3::Connection, body : String) : Result
      conn.query("SELECT * FROM (\n#{body}\n) LIMIT #{MAX_ROWS + 1}") do |rs|
        rows = [] of Array(Value)
        rs.each { rows << Array(Value).new(rs.column_count) { cell(rs.read) } }
        Result.new(rs.column_names, rows.first(MAX_ROWS), rows.size > MAX_ROWS)
      end
    end

    private def self.cell(value : DB::Any) : Value
      case value
      when Bytes  then "[BLOB, #{value.size} Bytes]"
      when String then value.size > MAX_CELL_CHARS ? value[0, MAX_CELL_CHARS] : value
      else             value.as(Value)
      end
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
