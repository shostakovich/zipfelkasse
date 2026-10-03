require "db"
require "sqlite3"

# What crystal-sqlite3 does not bind.
lib LibSQLite3
  SQLITE_UTF8           =     1
  SQLITE_DETERMINISTIC  = 0x800
  SQLITE_LIMIT_LENGTH   =     0
  SQLITE_LIMIT_ATTACHED =     7

  fun extended_result_codes = sqlite3_extended_result_codes(db : SQLite3, onoff : Int32) : Int32
  fun errstr = sqlite3_errstr(code : Int32) : UInt8*
  fun value_type = sqlite3_value_type(value : SQLite3Value) : ::SQLite3::Type
  fun value_bytes = sqlite3_value_bytes(value : SQLite3Value) : Int32
  fun result_text = sqlite3_result_text(ctx : SQLite3Context, text : UInt8*, n : Int32, destructor : Void*) : Nil
  fun result_null = sqlite3_result_null(ctx : SQLite3Context) : Nil
  fun result_value = sqlite3_result_value(ctx : SQLite3Context, value : SQLite3Value) : Nil
  fun limit = sqlite3_limit(db : SQLite3, id : Int32, new_val : Int32) : Int32
  fun progress_handler = sqlite3_progress_handler(db : SQLite3, n_ops : Int32, callback : Void* -> Int32, arg : Void*) : Nil
end

# crystal-sqlite3 checks the return value of sqlite3_finalize, but that
# repeats the error of the statement's last failed step (e.g. a UNIQUE
# violation the app already handled). Closing a connection whose statement
# cache holds such a statement then raises. finalize itself cannot fail.
class SQLite3::Statement
  protected def do_close
    @arg_refs.try(&.clear)
    LibSQLite3.finalize(self)
  end
end

module Zipfelkasse
  class Store
    # SQL function for text search, registered on every connection (the
    # sandbox of sql_query included): lower-cased with ß as "ss", umlauts
    # kept, so "bäcker" finds "BÄCKER" but not "baecker".
    FOLD_FUNC = "zipfelkasse_fold"

    # Per connection: extended result codes (to tell UNIQUE from CHECK
    # violations) and the fold function.
    def self.setup(conn : DB::Connection) : Nil
      handle = conn.as(SQLite3::Connection).to_unsafe
      LibSQLite3.extended_result_codes(handle, 1)
      fold = ->(ctx : LibSQLite3::SQLite3Context, _argc : Int32, argv : LibSQLite3::SQLite3Value*) do
        arg = argv[0]
        case LibSQLite3.value_type(arg)
        when .text?, .blob?
          folded = String.new(LibSQLite3.value_text(arg), LibSQLite3.value_bytes(arg)).downcase(:fold)
          # SQLITE_TRANSIENT (-1): SQLite copies the text.
          LibSQLite3.result_text(ctx, folded, folded.bytesize, Pointer(Void).new(-1.to_u64!))
        when .null?
          LibSQLite3.result_null(ctx)
        else
          LibSQLite3.result_value(ctx, arg)
        end
        nil
      end
      rc = LibSQLite3.create_function(handle, FOLD_FUNC, 1, LibSQLite3::SQLITE_UTF8 | LibSQLite3::SQLITE_DETERMINISTIC,
        nil, fold, nil, nil)
      raise SQLite3::Exception.new(handle) unless rc == 0
    end

    # crystal-sqlite3's exec only runs the first of several statements.
    def self.exec_script(conn : DB::Connection, sql : String) : Nil
      handle = conn.as(SQLite3::Connection).to_unsafe
      raise SQLite3::Exception.new(handle) if LibSQLite3.exec(handle, sql, nil, nil, nil) != 0
    end

    # SQLITE_CONSTRAINT_UNIQUE and SQLITE_CONSTRAINT_PRIMARYKEY
    def self.unique_violation?(ex : Exception) : Bool
      ex.is_a?(SQLite3::Exception) && ex.code.in?(2067, 1555)
    end

    def self.on_duplicate(message : String, &)
      on_duplicate(Domain::ValidationError.new(message)) { yield }
    end

    def self.on_duplicate(error : Exception, &)
      yield
    rescue ex
      raise error if unique_violation?(ex)
      raise ex
    end

    # Timestamps are RFC 3339 in UTC, so they compare as text.
    def self.format_time(t : Time) : String
      t.to_utc.to_s(TIME_FORMAT)
    end

    # Calendar dates are YYYY-MM-DD.
    def self.format_date(t : Time) : String
      t.to_s("%Y-%m-%d")
    end

    # Strict: Time.parse would accept "2026-9-1" and trailing text.
    def self.parse_date(s : String) : Time
      raise Time::Format::Error.new("invalid date #{s.inspect}") unless s.matches?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/)
      Time.parse(s, "%Y-%m-%d", Time::Location::UTC)
    end

    # Column converters for DB::Field; NULL becomes nil.
    module TimeText
      def self.from_rs(rs : DB::ResultSet) : Time?
        rs.read(String?).try { |s| Time.parse_rfc3339(s) }
      end
    end

    module DateText
      def self.from_rs(rs : DB::ResultSet) : Time?
        rs.read(String?).try { |s| Store.parse_date(s) }
      end
    end

    module EnumText(T)
      def self.from_rs(rs : DB::ResultSet) : T
        key = rs.read(String)
        T.from_key?(key) || raise ArgumentError.new("unknown #{T} #{key.inspect}")
      end
    end

    module JSONText(T)
      def self.from_rs(rs : DB::ResultSet) : T
        T.from_json(rs.read(String))
      end
    end

    # "" means none (ynab_config and expenses keep their NOT NULL columns).
    module FXSourceText
      def self.from_rs(rs : DB::ResultSet) : Domain::FXSource?
        key = rs.read(String)
        key.empty? ? nil : Domain::FXSource.from_key?(key) || raise ArgumentError.new("unknown FX source #{key.inspect}")
      end
    end

    def self.check_affected(result : DB::ExecResult) : Nil
      raise NotFound.new if result.rows_affected == 0
    end
  end
end
