require "sqlite3"

# C functions of SQLite that crystal-sqlite3 does not bind.
lib LibSQLite3
  SQLITE_UTF8          =     1
  SQLITE_DETERMINISTIC = 0x800

  SQLITE_INTEGER = 1
  SQLITE_FLOAT   = 2
  SQLITE_TEXT    = 3
  SQLITE_BLOB    = 4
  SQLITE_NULL    = 5

  SQLITE_LIMIT_LENGTH   = 0
  SQLITE_LIMIT_ATTACHED = 7

  SQLITE_TOOBIG = 18

  fun extended_result_codes = sqlite3_extended_result_codes(db : SQLite3, onoff : Int32) : Int32
  fun extended_errcode = sqlite3_extended_errcode(db : SQLite3) : Int32
  fun errstr = sqlite3_errstr(code : Int32) : UInt8*
  fun create_function_v2 = sqlite3_create_function_v2(db : SQLite3, name : UInt8*, n_arg : Int32, text_rep : Int32,
                                                      app : Void*, x_func : FuncCallback, x_step : Void*, x_final : Void*,
                                                      x_destroy : Void*) : Int32
  fun value_type = sqlite3_value_type(value : SQLite3Value) : Int32
  fun value_bytes = sqlite3_value_bytes(value : SQLite3Value) : Int32
  fun value_blob = sqlite3_value_blob(value : SQLite3Value) : UInt8*
  fun result_text = sqlite3_result_text(ctx : SQLite3Context, text : UInt8*, n : Int32, destructor : Void*) : Nil
  fun result_null = sqlite3_result_null(ctx : SQLite3Context) : Nil
  fun result_value = sqlite3_result_value(ctx : SQLite3Context, value : SQLite3Value) : Nil
  fun limit = sqlite3_limit(db : SQLite3, id : Int32, new_val : Int32) : Int32
  fun progress_handler = sqlite3_progress_handler(db : SQLite3, n_ops : Int32, callback : Void* -> Int32, arg : Void*) : Nil
  fun interrupt = sqlite3_interrupt(db : SQLite3) : Nil
  fun free = sqlite3_free(ptr : Void*) : Nil
end

# crystal-sqlite3 checks the return value of sqlite3_finalize, but that
# repeats the error of the statement's last failed step (e.g. a UNIQUE
# violation the app already handled). Closing a connection whose statement
# cache holds such a statement then raises. finalize itself cannot fail.
class SQLite3::Connection
  # crystal-sqlite3 always opens with READWRITE | CREATE; the sql_query
  # sandbox also needs URI (for ATTACH 'file:…?mode=ro'), and no pragmas.
  def initialize(options : ::DB::Connection::Options, filename : String, flags : SQLite3::Flag)
    super(options)
    check LibSQLite3.open_v2(filename, out @db, flags, nil)
  end
end

class SQLite3::Statement
  protected def do_close
    @arg_refs.try(&.clear)
    LibSQLite3.finalize(self)
  end
end
