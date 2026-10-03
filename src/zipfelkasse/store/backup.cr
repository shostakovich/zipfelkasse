module Zipfelkasse
  class Store
    BACKUP_PREFIX = "zipfelkasse-"
    BACKUP_SUFFIX = ".db"

    def backup(dir : String, keep : Int32) : String
      path = File.join(dir, BACKUP_PREFIX + now.to_utc.to_s("%Y%m%d-%H%M%S") + BACKUP_SUFFIX)
      begin
        Dir.mkdir_p(dir)
        raise Error.new("#{path} already exists") if File.exists?(path)
        vacuum_into(path)
      rescue ex
        raise Error.new("backup #{path}", cause: ex)
      end
      Store.rotate_backups(dir, keep)
      path
    end

    # The backup holds the YNAB tokens, so it is private from the start.
    # VACUUM INTO refuses an existing file, hence the umask; it blocks the
    # only thread, so no other fiber creates a file meanwhile.
    private def vacuum_into(path : String) : Nil
      previous = LibC.umask(0o077)
      begin
        @db.exec("VACUUM INTO ?", path)
      ensure
        LibC.umask(previous)
      end
    end

    def self.rotate_backups(dir : String, keep : Int32) : Nil
      names = Dir.children(dir).select do |n|
        n.starts_with?(BACKUP_PREFIX) && n.ends_with?(BACKUP_SUFFIX) &&
          File.info?(File.join(dir, n), follow_symlinks: false).try(&.file?)
      end
      names.sort!
      while names.size > Math.max(keep, 0)
        File.delete(File.join(dir, names.shift))
      end
    end
  end
end
