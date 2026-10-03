require "sqlite3"

module E2E
  # Direct access to an app's database for assertions.
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
  end
end
