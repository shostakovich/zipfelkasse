require "sqlite3"

module E2E
  # Read-only views of an app's database: complete content and schema.
  module Snapshot
    def self.open(path : String, &)
      DB.open("sqlite3://#{path}?busy_timeout=5000") { |db| yield db }
    end

    def self.count(path : String, sql : String) : Int64
      open(path) { |db| db.scalar(sql).as(Int64) }
    end

    # A consistent copy of a live database (WAL content included).
    def self.copy(path : String, to dest : String) : Nil
      File.delete(dest) if File.exists?(dest)
      open(path) { |db| db.exec("VACUUM INTO ?", dest) }
    end

    # Every table, every row, in a stable order, one line per row.
    def self.content(path : String) : String
      open(path) do |db|
        tables = db.query_all("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name", as: String)
        String.build do |io|
          tables.each do |t|
            io << "== " << t << "\n"
            db.query("SELECT * FROM \"#{t}\"") do |rs|
              rows = [] of String
              rs.each do
                rows << (0...rs.column_count).map { |i| column(rs.column_name(i), rs.read) }.join(" | ")
              end
              rows.sort!.each { |row| io << row << "\n" }
            end
          end
        end
      end
    end

    # The schema as SQLite stores it, plus user_version.
    def self.schema(path : String) : String
      open(path) do |db|
        String.build do |io|
          io << "user_version=" << db.scalar("PRAGMA user_version") << "\n"
          db.query("SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name") do |rs|
            rs.each do
              io << rs.read(String) << " " << rs.read(String) << " " << rs.read(String) << "\n"
              io << rs.read(String?) << "\n"
            end
          end
        end
      end
    end

    # *_json columns are compared by content, not by bytes.
    private def self.column(name : String, v) : String
      if name.ends_with?("_json") && v.is_a?(String)
        begin
          return "#{name}=json:#{Compare.json(JSON.parse(v)).gsub(/\n\s*/, " ")}"
        rescue JSON::ParseException
        end
      end
      "#{name}=#{value(v)}"
    end

    private def self.value(v) : String
      case v
      when Bytes then "x'#{v.hexstring}'"
      when Nil   then "NULL"
      else            v.inspect
      end
    end
  end
end
