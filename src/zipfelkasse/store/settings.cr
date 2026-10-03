module Zipfelkasse
  class Store
    # Known keys in the settings table. Feature packages may use their own
    # prefixed keys (e.g. "fx.").
    SETTING_GROUP_NAME       = "group_name"
    SETTING_DEFAULT_CURRENCY = "default_currency"

    # The group name as long as none is set.
    DEFAULT_GROUP_NAME = "Zipfelkasse"

    # The value for key; raises NotFound.
    def get_setting(key : String) : String
      @db.query_one?("SELECT value FROM settings WHERE key = ?", key, as: String) || raise NotFound.new
    end

    SET_SETTING_SQL = "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value"

    # Sets key to value (creating the key if needed). It writes no activity
    # entry; it is meant for internal state (e.g. the ECB cache).
    def set_setting(key : String, value : String) : Nil
      transaction { |tx| tx.exec(SET_SETTING_SQL, key, value) }
    end

    # The group name (fallback "Zipfelkasse").
    def group_name : String
      v = get_setting(SETTING_GROUP_NAME)
      v.empty? ? DEFAULT_GROUP_NAME : v
    rescue # NotFound or a database error: like Go, fall back
      DEFAULT_GROUP_NAME
    end
  end
end
