package store

import (
	"context"
	"database/sql"
)

// ynabStateColumns are the columns that migration 5 adds to ynab_config.
var ynabStateColumns = []struct{ name, def string }{
	{"connected_at", "TEXT"},
	{"last_run", "TEXT"},
	{"last_sync", "TEXT"},
	{"summary", "TEXT NOT NULL DEFAULT ''"},
	{"error", "TEXT NOT NULL DEFAULT ''"},
	{"token_invalid", "INTEGER NOT NULL DEFAULT 0 CHECK (token_invalid IN (0, 1))"},
	{"retry_at", "TEXT"},
	{"backoff_seconds", "INTEGER NOT NULL DEFAULT 0"},
}

// moveYNABStateIntoConfig (migration 5) keeps a person's YNAB sync status
// and connection time in ynab_config instead of the settings table (keys
// "ynab.status.<id>" as JSON and "ynab.connected.<id>"), so that a new token
// and the reset of the old token's status are one write. Package ynab
// defines what the status means (ynab.Status). Columns that already exist
// are kept with their values, so running the migration again (tests that
// reset user_version) loses nothing.
func (s *Store) moveYNABStateIntoConfig(ctx context.Context, tx *sql.Tx) error {
	for _, c := range ynabStateColumns {
		var n int
		if err := tx.QueryRowContext(ctx, "SELECT count(*) FROM pragma_table_info('ynab_config') WHERE name = ?",
			c.name).Scan(&n); err != nil {
			return err
		}
		if n > 0 {
			continue
		}
		if _, err := tx.ExecContext(ctx, "ALTER TABLE ynab_config ADD COLUMN "+c.name+" "+c.def); err != nil {
			return err
		}
	}
	_, err := tx.ExecContext(ctx, `
		UPDATE ynab_config SET connected_at = s.value
			FROM settings s
			WHERE s.key = 'ynab.connected.' || ynab_config.participant_id;

		-- Unreadable JSON counts as no status, as it did when package ynab
		-- read it. backoff was a time.Duration in nanoseconds.
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

		DELETE FROM settings WHERE key LIKE 'ynab.status.%' OR key LIKE 'ynab.connected.%';`)
	return err
}
