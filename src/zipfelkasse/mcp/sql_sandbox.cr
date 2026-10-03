module Zipfelkasse::MCP
  # Runs a query on an in-memory copy of Store::EXPOSED_TABLES with query_only and without ATTACH, embedded as a
  # subquery so that only a single SELECT parses. SQLite blocks the only thread while it steps, hence the short TIMEOUT.
  class SQLSandbox
    MAX_ROWS       = 500
    TIMEOUT        = 2.seconds
    MAX_CELL_CHARS = 2000
    MAX_RESULT     = 8 << 20

    alias Value = Int64 | Float64 | String | Nil

    record Result, columns : Array(String), rows : Array(Array(Value)), truncated : Bool

    def initialize(@path : String)
    end

    def query(query : String, timeout : Time::Span = TIMEOUT) : Result
      raise Domain::ValidationError.new("The query contains a NUL character.") if query.includes?('\0')
      body = query.strip.rstrip("; \t\n\r")
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

    # A timer fiber could not run while sqlite3_step blocks the thread: SQLite's progress handler checks the deadline.
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

    # The newline ends a trailing "--" comment of the query, but "/*" can still comment out the LIMIT.
    def self.select_rows(conn : SQLite3::Connection, body : String) : Result
      conn.query("SELECT * FROM (\n#{body}\n) LIMIT #{MAX_ROWS + 1}") do |rs|
        rows = [] of Array(Value)
        rs.each do
          rows << Array(Value).new(rs.column_count) { cell(rs.read) }
          break if rows.size > MAX_ROWS
        end
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
  end
end
