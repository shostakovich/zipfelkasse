require "db"
require "sqlite3"
require "./lib_sqlite"

module Zipfelkasse
  # Zipfelkasse's database: schema/migrations, queries, activity log, backup
  # and the change hook for expenses.
  #
  # Feature packages put their queries in src/zipfelkasse/store/<package>.cr
  # (reopening this class) and use `db` (reads) or `transaction` (writes).
  #
  # Concurrency: all fibers share one Store. Reads go through the connection
  # pool. Writes go through `transaction`: BEGIN IMMEDIATE like Go, plus a
  # fiber-aware mutex, because SQLite's busy handler sleeps inside C and would
  # block the only thread while another fiber holds the write lock.
  class Store
    # A record does not exist (or, for expenses, is already deleted where that
    # matters).
    class NotFound < Exception
      def initialize(message = "not found")
        super
      end
    end

    # Time format of timestamps in the database (RFC 3339, UTC, seconds).
    TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

    # The migrations/*.sql files, embedded: {number, file name, SQL}.
    MIGRATION_FILES = [] of {Int32, String, String}
    {% for name in system("ls #{__DIR__}/../../../internal/store/migrations").lines.sort %}
      MIGRATION_FILES << Tuple.new({{ name.split("_")[0].to_i }}, {{ name }}, {{ read_file("#{__DIR__}/../../../internal/store/migrations/#{name.id}") }})
    {% end %}

    # Migrations written in Crystal (Go in the original) for data fixes that
    # SQL alone cannot do. They share the numbering with the SQL files and
    # register themselves here (see resplit.cr, amountweights.cr,
    # ynabstate.cr).
    GO_MIGRATIONS = {} of Int32 => Proc(Store, DB::Connection, Nil)

    getter db : DB::Database
    getter path : String
    # The clock for timestamps such as created_at (tests replace it).
    property clock : Proc(Time) = ->{ Time.utc }

    @write_lock = Mutex.new # :checked: a nested transaction raises instead of deadlocking
    @hooks = [] of ExpenseChange -> Nil

    # Opens (or creates) the database at path and applies missing
    # migrations. ":memory:" creates an ephemeral database (tests).
    # Settings: WAL, foreign_keys=ON, busy_timeout=5s, synchronous=NORMAL,
    # transactions with BEGIN IMMEDIATE.
    def self.open(path : String) : Store
      memory = path == ":memory:"
      unless memory
        dir = File.dirname(path)
        begin
          Dir.mkdir_p(dir) unless dir.empty?
        rescue ex
          raise Exception.new("create database directory: #{ex.message}")
        end
      end
      store = new(path, connect(path, memory))
      begin
        store.migrate
      rescue ex
        store.close
        raise ex
      end
      store
    end

    protected def initialize(@path : String, @db : DB::Database)
    end

    private def self.connect(path : String, memory : Bool) : DB::Database
      conn_options = DB::Connection::Options.new
      # A memory database exists once per connection: keep exactly one.
      pool_options = memory ? DB::Pool::Options.new(initial_pool_size: 1, max_pool_size: 1, max_idle_pool_size: 1) : DB::Pool::Options.new
      sqlite_options = SQLite3::Connection::Options.new(
        filename: path, busy_timeout: "5000", foreign_keys: "1", journal_mode: "WAL", synchronous: "NORMAL")
      db = DB::Database.new(conn_options, pool_options) do
        SQLite3::Connection.new(conn_options, sqlite_options)
      end
      db.setup_connection { |conn| Store.setup(conn) }
      db
    end

    # Per connection: extended result codes (to tell UNIQUE from CHECK
    # violations) and the zipfelkasse_fold function.
    def self.setup(conn : DB::Connection) : Nil
      handle = conn.as(SQLite3::Connection).to_unsafe
      LibSQLite3.extended_result_codes(handle, 1)
      register_fold(handle)
    end

    def close : Nil
      @db.close
    end

    # Checks whether the database is reachable (health check).
    def ping : Nil
      @db.scalar("SELECT 1")
    end

    def schema_version : Int32
      @db.scalar("PRAGMA user_version").as(Int64).to_i32
    end

    # Runs the block in a write transaction (BEGIN IMMEDIATE); commits when
    # it returns, rolls back when it raises.
    def transaction(& : DB::Connection -> T) : T forall T
      @write_lock.synchronize do
        @db.using_connection do |conn|
          conn.exec("BEGIN IMMEDIATE")
          begin
            result = yield conn
            conn.exec("COMMIT")
            result
          rescue ex
            conn.exec("ROLLBACK") rescue nil
            raise ex
          end
        end
      end
    end

    # Applies all migrations (SQL files and GO_MIGRATIONS) whose number is
    # greater than PRAGMA user_version, each in its own transaction.
    def migrate : Nil
      migrations = MIGRATION_FILES.map { |n, name, sql| {n, name, sql.as(String?)} }
      GO_MIGRATIONS.each_key { |n| migrations << {n, "%03d (Go)" % n, nil} }
      migrations.sort_by!(&.[0])
      migrations.each_cons_pair do |a, b|
        raise Exception.new("migration #{a[0]} is defined twice") if a[0] == b[0]
      end
      current = schema_version
      migrations.each do |n, name, sql|
        next if n <= current
        begin
          transaction do |tx|
            if sql
              Store.exec_script(tx, sql)
            else
              GO_MIGRATIONS[n].call(self, tx)
            end
            tx.exec("PRAGMA user_version = #{n}")
          end
        rescue ex
          raise Exception.new("migration #{name}: #{ex.message}")
        end
      end
    end

    # Runs SQL with several statements (crystal-sqlite3's exec only runs the
    # first one).
    def self.exec_script(conn : DB::Connection, sql : String) : Nil
      handle = conn.as(SQLite3::Connection).to_unsafe
      if LibSQLite3.exec(handle, sql, nil, nil, nil) != 0
        raise SQLite3::Exception.new(handle)
      end
    end

    # The current time as stored in the database.
    def now_string : String
      @clock.call.to_utc.to_s(TIME_FORMAT)
    end

    def self.format_date(t : Time) : String
      t.to_s("%Y-%m-%d")
    end

    def self.parse_date(s : String) : Time
      Time.parse(s, "%Y-%m-%d", Time::Location::UTC)
    end

    # Timestamp from the database; nil when NULL, empty or unreadable.
    def self.parse_time(s : String?) : Time?
      return nil if s.nil? || s.empty?
      Time.parse_rfc3339(s) rescue nil
    end

    # Whether an error is a UNIQUE or PRIMARY KEY violation.
    def self.unique_violation?(ex : Exception) : Bool
      ex.is_a?(SQLite3::Exception) && ex.code.in?(2067, 1555) # SQLITE_CONSTRAINT_UNIQUE, _PRIMARYKEY
    end

    # --- change hook -----------------------------------------------------------

    # A successfully stored change to an expense. action is
    # ACTION_EXPENSE_CREATED, ACTION_EXPENSE_UPDATED or ACTION_EXPENSE_DELETED.
    record ExpenseChange, expense_id : Int64, action : String

    # Registers a callback that runs after every successful commit of an
    # expense change, in the caller's fiber. It must not block.
    def on_expense_change(&block : ExpenseChange -> Nil) : Nil
      @hooks << block
    end

    protected def notify(change : ExpenseChange) : Nil
      @hooks.dup.each(&.call(change))
    end

    # --- names -----------------------------------------------------------------

    # A person's or category's name as stored: surrounding spaces removed,
    # inner runs of whitespace collapsed to one.
    def self.normalize_name(name : String) : String
      name.split.join(" ")
    end

    # Validates and normalizes names of people/categories.
    def self.clean_name(name : String, what : String) : String
      name = normalize_name(name)
      raise Domain::ValidationError.new("Bitte einen Namen für #{what} angeben.") if name.empty?
      raise Domain::ValidationError.new("Der Name ist zu lang (höchstens 60 Zeichen).") if name.size > 60
      name
    end
  end
end
