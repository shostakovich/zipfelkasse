require "db"
require "sqlite3"
require "./sqlite"

module Zipfelkasse
  # Feature files reopen this class with their queries and use `db` (reads)
  # or `transaction` (writes).
  class Store
    Log = ::Log.for(self)

    class Error < Exception; end

    class NotFound < Exception; end

    TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

    SCHEMA_SQL   = {{ read_file("#{__DIR__}/schema.sql") }}
    BASE_VERSION = 5

    # {version, SQL} of migrations/NNN_*.sql, from version 6 on.
    MIGRATIONS = [] of {Int32, String}
    {% for name in system(%(ls "#{__DIR__}/migrations" 2>/dev/null || true)).lines.sort %}
      MIGRATIONS << {{ {name.split("_")[0].to_i, read_file("#{__DIR__}/migrations/#{name.id}")} }}
    {% end %}

    LATEST_VERSION = MIGRATIONS.last?.try(&.[0]) || BASE_VERSION

    getter db : DB::Database
    getter path : String
    property clock : Proc(Time) = -> { Time.utc }
    # Runs after every committed expense change, in the caller's fiber; it must not block.
    property on_change : Proc(Nil)?

    # SQLite's busy handler sleeps inside C and would block the only thread
    # while another fiber holds the write lock, so writers queue here.
    @write_lock = Mutex.new

    def self.open(path : String) : Store
      Dir.mkdir_p(File.dirname(path)) unless path == ":memory:"
      store = new(path, connect(path))
      begin
        store.migrate
      rescue ex
        store.close
        raise ex
      end
      store
    rescue ex
      raise Error.new("database #{path}", cause: ex)
    end

    protected def initialize(@path : String, @db : DB::Database)
    end

    private def self.connect(path : String) : DB::Database
      conn_options = DB::Connection::Options.new
      # A memory database exists once per connection: keep exactly one.
      pool_options = path == ":memory:" ? DB::Pool::Options.new(initial_pool_size: 1, max_pool_size: 1, max_idle_pool_size: 1) : DB::Pool::Options.new
      sqlite_options = SQLite3::Connection::Options.new(
        filename: path, busy_timeout: "5000", foreign_keys: "1", journal_mode: "WAL", synchronous: "NORMAL")
      db = DB::Database.new(conn_options, pool_options) do
        SQLite3::Connection.new(conn_options, sqlite_options)
      end
      db.setup_connection { |conn| Store.setup(conn) }
      db
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
    # of the block rolls back. Inside the block, read through the yielded
    # connection only: the pool of a memory database has a single connection,
    # so reading from `db` would wait for it forever.
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

    # A new database gets the schema of version BASE_VERSION, then every migration.
    def migrate(migrations = MIGRATIONS) : Nil
      current = schema_version
      latest = migrations.last?.try(&.[0]) || BASE_VERSION
      if 0 < current < BASE_VERSION
        raise Error.new("schema version #{current} is older than the oldest supported one (#{BASE_VERSION})")
      elsif current > latest
        raise Error.new("schema version #{current} is newer than this release knows (#{latest})")
      end
      steps = migrations.select { |version, _| version > current }
      steps.unshift({BASE_VERSION, SCHEMA_SQL}) if current == 0
      steps.each do |version, sql|
        transaction do |tx|
          Store.exec_script(tx, sql)
          tx.exec("PRAGMA user_version = #{version}")
        end
      rescue ex
        raise Error.new("migration #{version}", cause: ex)
      end
    end

    def now : Time
      @clock.call
    end

    def now_string : String
      Store.format_time(now)
    end

    protected def changed(expense_id : Int64) : Nil
      @on_change.try &.call
    rescue ex
      Log.error(exception: ex, &.emit("expense change hook failed", expense_id: expense_id))
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
