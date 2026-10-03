require "db"
require "sqlite3"
require "./lib_sqlite"

module Zipfelkasse
  # Feature files put their queries in src/zipfelkasse/store/<name>.cr
  # (reopening this class) and use `db` (reads) or `transaction` (writes).
  #
  # Concurrency: all fibers share one Store. Reads go through the connection
  # pool. Writes go through `transaction`: BEGIN IMMEDIATE plus a
  # fiber-aware mutex, because SQLite's busy handler sleeps inside C and would
  # block the only thread while another fiber holds the write lock.
  class Store
    # Also raised for expenses that are already deleted, where that matters.
    class NotFound < Exception
      def initialize(message = "not found")
        super
      end
    end

    TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

    # Embedded at compile time: {number, file name, SQL}.
    MIGRATION_FILES = [] of {Int32, String, String}
    {% for name in system("ls #{__DIR__}/migrations").lines.sort %}
      MIGRATION_FILES << Tuple.new({{ name.split("_")[0].to_i }}, {{ name }}, {{ read_file("#{__DIR__}/migrations/#{name.id}") }})
    {% end %}

    # Migrations written in Crystal for data fixes that SQL alone cannot do.
    # They share the numbering with the SQL files and register themselves here.
    DATA_MIGRATIONS = {} of Int32 => Proc(Store, DB::Connection, Nil)

    getter db : DB::Database
    getter path : String
    property clock : Proc(Time) = -> { Time.utc }

    @write_lock = Mutex.new # :checked: a nested transaction raises instead of deadlocking
    @hooks = [] of ExpenseChange -> Nil

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

    def ping : Nil
      @db.scalar("SELECT 1")
    end

    def schema_version : Int32
      @db.scalar("PRAGMA user_version").as(Int64).to_i32
    end

    # Commits when the block finishes; an exception or a `return`/`break` out
    # of the block rolls back.
    def transaction(& : DB::Connection -> T) : T forall T
      @write_lock.synchronize do
        @db.using_connection do |conn|
          conn.exec("BEGIN IMMEDIATE")
          committed = false
          begin
            result = yield conn
            conn.exec("COMMIT")
            committed = true
            result
          ensure
            unless committed
              conn.exec("ROLLBACK") rescue nil
            end
          end
        end
      end
    end

    def migrate : Nil
      migrations = MIGRATION_FILES.map { |n, name, sql| {n, name, sql.as(String?)} }
      DATA_MIGRATIONS.each_key { |n| migrations << {n, "%03d (data)" % n, nil} }
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
              DATA_MIGRATIONS[n].call(self, tx)
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

    def now_string : String
      @clock.call.to_utc.to_s(TIME_FORMAT)
    end

    def self.format_date(t : Time) : String
      t.to_s("%Y-%m-%d")
    end

    # Strict: Time.parse would accept "2026-9-1" and trailing text.
    def self.parse_date(s : String) : Time
      raise Time::Format::Error.new("invalid date #{s.inspect}") unless s.matches?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/)
      Time.parse(s, "%Y-%m-%d", Time::Location::UTC)
    end

    def self.parse_time(s : String?) : Time?
      return nil if s.nil? || s.empty?
      Time.parse_rfc3339(s) rescue nil
    end

    def self.unique_violation?(ex : Exception) : Bool
      ex.is_a?(SQLite3::Exception) && ex.code.in?(2067, 1555) # SQLITE_CONSTRAINT_UNIQUE, _PRIMARYKEY
    end

    # action is ACTION_EXPENSE_CREATED, _UPDATED or _DELETED.
    record ExpenseChange, expense_id : Int64, action : String

    # Runs after every successful commit of an expense change, in the caller's
    # fiber; it must not block.
    def on_expense_change(&block : ExpenseChange -> Nil) : Nil
      @hooks << block
    end

    protected def notify(change : ExpenseChange) : Nil
      @hooks.dup.each(&.call(change))
    end

    def self.normalize_name(name : String) : String
      name.split.join(" ")
    end

    def self.clean_name(name : String, what : String) : String
      name = normalize_name(name)
      raise Domain::ValidationError.new("Bitte einen Namen für #{what} angeben.") if name.empty?
      raise Domain::ValidationError.new("Der Name ist zu lang (höchstens 60 Zeichen).") if name.size > 60
      name
    end
  end
end
