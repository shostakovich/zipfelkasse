-- Absent YNAB values become NULL (a disconnected token as well, so enabled goes), and the sync state packed into
-- ynab_sync.synced_hash ("pending", "retarget", "error:delete", "error:" + fingerprint, fingerprint) gets the
-- columns state and fingerprint.
CREATE TABLE ynab_config_new (
    participant_id  INTEGER PRIMARY KEY REFERENCES participants (id),
    token           TEXT,
    budget_id       TEXT,
    account_id      TEXT,
    start_date      TEXT,
    updated_at      TEXT    NOT NULL,
    connected_at    TEXT,
    last_run        TEXT,
    last_sync       TEXT,
    summary         TEXT,
    error           TEXT,
    token_invalid   INTEGER NOT NULL DEFAULT 0 CHECK (token_invalid IN (0, 1)),
    retry_at        TEXT,
    backoff_seconds INTEGER NOT NULL DEFAULT 0
);

INSERT INTO ynab_config_new
SELECT participant_id, CASE WHEN enabled = 1 THEN nullif(token, '') END, nullif(budget_id, ''), nullif(account_id, ''),
       start_date, updated_at, connected_at, last_run, last_sync, nullif(summary, ''), nullif(error, ''), token_invalid,
       retry_at, backoff_seconds
FROM ynab_config;

DROP TABLE ynab_config;
ALTER TABLE ynab_config_new RENAME TO ynab_config;

CREATE TABLE ynab_sync_new (
    expense_id     INTEGER NOT NULL REFERENCES expenses (id),
    participant_id INTEGER NOT NULL REFERENCES participants (id),
    ynab_txn_id    TEXT,
    state          TEXT    NOT NULL DEFAULT 'unknown'
                           CHECK (state IN ('unknown', 'synced', 'pending', 'retarget', 'failed', 'delete_failed')),
    fingerprint    TEXT,
    synced_at      TEXT,
    last_error     TEXT,
    PRIMARY KEY (expense_id, participant_id)
) WITHOUT ROWID;

INSERT INTO ynab_sync_new
SELECT expense_id, participant_id, nullif(ynab_txn_id, ''),
       CASE
           WHEN synced_hash = '' THEN 'unknown'
           WHEN synced_hash IN ('pending', 'retarget') THEN synced_hash
           WHEN synced_hash = 'error:delete' THEN 'delete_failed'
           WHEN synced_hash LIKE 'error:%' THEN 'failed'
           ELSE 'synced'
       END,
       CASE
           WHEN synced_hash IN ('', 'pending', 'retarget', 'error:delete') THEN NULL
           WHEN synced_hash LIKE 'error:%' THEN substr(synced_hash, 7)
           ELSE synced_hash
       END,
       synced_at, nullif(last_error, '')
FROM ynab_sync;

DROP TABLE ynab_sync;
ALTER TABLE ynab_sync_new RENAME TO ynab_sync;
CREATE INDEX ynab_sync_participant ON ynab_sync (participant_id);
