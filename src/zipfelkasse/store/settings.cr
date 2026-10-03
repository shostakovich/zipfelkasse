module Zipfelkasse
  class Store
    SETTING_GROUP_NAME = "group_name"
    DEFAULT_GROUP_NAME = "Zipfelkasse"

    def group_name(db : DB::QueryMethods = @db) : String
      db.query_one?("SELECT value FROM settings WHERE key = ?", SETTING_GROUP_NAME, as: String).presence || DEFAULT_GROUP_NAME
    end

    # Writes the name even if unchanged, but logs only a change.
    def set_group_name(actor_id : Int64?, name : String) : Nil
      name = Store.clean_name(name, "die Gruppe")
      transaction do |tx|
        old = group_name(tx)
        tx.exec("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
          SETTING_GROUP_NAME, name)
        log_settings(tx, actor_id, "Gruppe umbenannt: „#{old}“ → „#{name}“") unless old == name
      end
    end
  end
end
