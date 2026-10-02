-- Migration 005: keep a person's YNAB sync status and connection time in
-- ynab_config instead of the settings table (keys "ynab.status.<id>" as JSON
-- and "ynab.connected.<id>"), so that a new token and the reset of the old
-- token's status are one write. Package ynab defines what the status means
-- (ynab.Status).
-- The table is built anew and copied (as in 003) instead of using ADD COLUMN,
-- which would fail when the migration runs again on a database that already
-- has the columns (tests that reset user_version).

CREATE TABLE ynab_config_new (
    participant_id  INTEGER PRIMARY KEY REFERENCES participants (id),
    token           TEXT    NOT NULL,
    budget_id       TEXT    NOT NULL DEFAULT '',
    account_id      TEXT    NOT NULL DEFAULT '',
    start_date      TEXT,
    enabled         INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    updated_at      TEXT    NOT NULL,
    connected_at    TEXT,
    -- sync status
    last_run        TEXT,
    last_sync       TEXT,
    summary         TEXT    NOT NULL DEFAULT '',
    error           TEXT    NOT NULL DEFAULT '',
    token_invalid   INTEGER NOT NULL DEFAULT 0 CHECK (token_invalid IN (0, 1)),
    retry_at        TEXT,
    backoff_seconds INTEGER NOT NULL DEFAULT 0
);

INSERT INTO ynab_config_new (participant_id, token, budget_id, account_id, start_date, enabled, updated_at)
    SELECT participant_id, token, budget_id, account_id, start_date, enabled, updated_at FROM ynab_config;

DROP TABLE ynab_config;

ALTER TABLE ynab_config_new RENAME TO ynab_config;

UPDATE ynab_config SET connected_at = s.value
    FROM settings s
    WHERE s.key = 'ynab.connected.' || ynab_config.participant_id;

-- Unreadable JSON counts as no status, as it did when package ynab read it.
-- backoff was a time.Duration in nanoseconds.
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
