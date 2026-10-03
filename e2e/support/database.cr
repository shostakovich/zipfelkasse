require "sqlite3"

module E2E
  module Database
    def self.open(path : String, &)
      DB.open("sqlite3://#{path}?busy_timeout=5000") { |db| yield db }
    end

    def self.count(path : String, sql : String) : Int64
      open(path) { |db| db.scalar(sql).as(Int64) }
    end
  end
end
