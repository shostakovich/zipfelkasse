module Zipfelkasse
  class Store
    SETTING_GROUP_NAME = "group_name"
    DEFAULT_GROUP_NAME = "Zipfelkasse"

    SET_SETTING_SQL = "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value"

    def get_setting?(key : String, db : DB::QueryMethods = @db) : String?
      db.query_one?("SELECT value FROM settings WHERE key = ?", key, as: String)
    end

    def get_setting(key : String) : String
      get_setting?(key) || raise NotFound.new
    end

    # Writes no activity entry; meant for internal state (e.g. the ECB cache).
    def set_setting(key : String, value : String) : Nil
      transaction { |tx| tx.exec(SET_SETTING_SQL, key, value) }
    end

    def group_name : String
      get_setting?(SETTING_GROUP_NAME).presence || DEFAULT_GROUP_NAME
    rescue DB::Error
      DEFAULT_GROUP_NAME
    end

    # Writes the name even if unchanged, but logs only a change.
    def set_group_name(actor_id : Int64?, name : String) : Nil
      name = Store.clean_name(name, "die Gruppe")
      transaction do |tx|
        old = get_setting?(SETTING_GROUP_NAME, tx).presence || DEFAULT_GROUP_NAME
        tx.exec(SET_SETTING_SQL, SETTING_GROUP_NAME, name)
        log_settings(tx, actor_id, "Gruppe umbenannt: „#{old}“ → „#{name}“") unless old == name
      end
    end
  end
end
