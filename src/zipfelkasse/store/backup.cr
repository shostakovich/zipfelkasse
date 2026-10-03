module Zipfelkasse
  class Store
    BACKUP_PREFIX = "zipfelkasse-"
    BACKUP_SUFFIX = ".db"

    def backup(dir : String, keep : Int32) : String
      begin
        Dir.mkdir_p(dir)
      rescue ex
        raise Exception.new("create backup directory: #{ex.message}")
      end
      path = File.join(dir, BACKUP_PREFIX + @clock.call.to_utc.to_s("%Y%m%d-%H%M%S") + BACKUP_SUFFIX)
      raise Exception.new("backup #{path} already exists") if File.exists?(path)
      begin
        @db.exec("VACUUM INTO ?", path)
      rescue ex
        raise Exception.new("vacuum into: #{ex.message}")
      end
      Store.rotate_backups(dir, keep)
      path
    end

    def self.rotate_backups(dir : String, keep : Int32) : Nil
      names = Dir.children(dir).select do |n|
        n.starts_with?(BACKUP_PREFIX) && n.ends_with?(BACKUP_SUFFIX) && File.file?(File.join(dir, n))
      end
      # The timestamp in the name sorts correctly lexicographically.
      names.sort!
      while names.size > Math.max(keep, 0)
        File.delete(File.join(dir, names.shift))
      end
    end
  end
end
