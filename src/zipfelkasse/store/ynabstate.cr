module Zipfelkasse
  class Store
    YNAB_STATE_COLUMNS = {
      {"connected_at", "TEXT"},
      {"last_run", "TEXT"},
      {"last_sync", "TEXT"},
      {"summary", "TEXT NOT NULL DEFAULT ''"},
      {"error", "TEXT NOT NULL DEFAULT ''"},
      {"token_invalid", "INTEGER NOT NULL DEFAULT 0 CHECK (token_invalid IN (0, 1))"},
      {"retry_at", "TEXT"},
      {"backoff_seconds", "INTEGER NOT NULL DEFAULT 0"},
    }

    # Migration 5 moves a person's YNAB sync status and connection time from
    # the settings table (keys "ynab.status.<id>" as JSON and
    # "ynab.connected.<id>") into ynab_config, so that a new token and the
    # reset of the old token's status are one write. Existing columns keep
    # their values, so running it again (tests reset user_version) loses
    # nothing.
    def self.move_ynab_state_into_config(tx : DB::Connection) : Nil
      YNAB_STATE_COLUMNS.each do |name, definition|
        next if tx.scalar("SELECT count(*) FROM pragma_table_info('ynab_config') WHERE name = ?", name).as(Int64) > 0
        tx.exec("ALTER TABLE ynab_config ADD COLUMN #{name} #{definition}")
      end
      exec_script(tx, <<-SQL)
        UPDATE ynab_config SET connected_at = s.value
            FROM settings s
            WHERE s.key = 'ynab.connected.' || ynab_config.participant_id;

        -- Unreadable JSON counts as no status. backoff was stored in
        -- nanoseconds.
        UPDATE ynab_config SET
            last_run        = json_extract(s.value, '$.last_run'),
            last_sync       = json_extract(s.value, '$.last_sync'),
            summary         = coalesce(json_extract(s.value, '$.summary'), ''),
            error           = coalesce(json_extract(s.value, '$.error'), ''),
            token_invalid   = json_extract(s.value, '$.token_invalid') IS 1,
            retry_at        = json_extract(s.value, '$.retry_at'),
            backoff_seconds = CAST(coalesce(json_extract(s.value, '$.backoff'), 0) / 1000000000 AS INTEGER)
            FROM settings s
            WHERE s.key = 'ynab.status.' || ynab_config.participant_id AND json_valid(s.value);

        DELETE FROM settings WHERE key LIKE 'ynab.status.%' OR key LIKE 'ynab.connected.%';
        SQL
    end

    DATA_MIGRATIONS[5] = ->(_s : Store, tx : DB::Connection) { move_ynab_state_into_config(tx) }
  end
end
