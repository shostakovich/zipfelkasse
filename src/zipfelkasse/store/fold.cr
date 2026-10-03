module Zipfelkasse
  class Store
    # Name of the SQL function for text search, registered on every
    # connection (including the sql_query sandbox, see `register_fold`).
    FOLD_FUNC = "zipfelkasse_fold"

    # Text compared the way the text search and the title statistics compare
    # it: Unicode lower-casing (including umlauts), ß becomes "ss". Umlauts
    # stay umlauts: "bäcker" finds "BÄCKER", not "baecker".
    def self.fold(s : String) : String
      s.downcase.gsub("ß", "ss")
    end

    def self.register_fold(handle : LibSQLite3::SQLite3) : Nil
      fn = ->(ctx : LibSQLite3::SQLite3Context, _argc : Int32, argv : LibSQLite3::SQLite3Value*) do
        arg = argv[0]
        case LibSQLite3.value_type(arg)
        when LibSQLite3::SQLITE_TEXT, LibSQLite3::SQLITE_BLOB
          bytes = Bytes.new(LibSQLite3.value_blob(arg), LibSQLite3.value_bytes(arg))
          folded = Store.fold(String.new(bytes))
          # SQLITE_TRANSIENT (-1): SQLite copies the text.
          LibSQLite3.result_text(ctx, folded, folded.bytesize, Pointer(Void).new(-1.to_u64!))
        when LibSQLite3::SQLITE_NULL
          LibSQLite3.result_null(ctx)
        else
          LibSQLite3.result_value(ctx, arg)
        end
        nil
      end
      rc = LibSQLite3.create_function_v2(handle, FOLD_FUNC, 1, LibSQLite3::SQLITE_UTF8 | LibSQLite3::SQLITE_DETERMINISTIC,
        nil, fn, nil, nil, nil)
      raise SQLite3::Exception.new(handle) unless rc == 0
    end
  end
end
