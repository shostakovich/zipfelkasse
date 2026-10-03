-- Schema at user_version 5; later changes are numbered files in migrations/ from 6 on.
-- Conventions:
--   * Amounts in cents (INTEGER), foreign currency in its smallest unit.
--   * Calendar dates as TEXT 'YYYY-MM-DD', timestamps as TEXT RFC 3339 UTC.
--   * Booleans as INTEGER 0/1.
--   * Nothing that is referenced gets hard-deleted: archived_at / deleted_at.

CREATE TABLE participants (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE COLLATE NOCASE CHECK (length(trim(name)) > 0),
    created_at  TEXT    NOT NULL,
    archived_at TEXT
);

CREATE TABLE categories (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE COLLATE NOCASE CHECK (length(trim(name)) > 0),
    position    INTEGER NOT NULL DEFAULT 0,
    archived_at TEXT
);

-- Rule for recurring expenses. template_json is the expense input (ExpenseInput) as
-- JSON, without date and recurring_id. Occurrences are always computed from start_date
-- (the anchor); next_date is the next due occurrence.
CREATE TABLE recurring (
    id            INTEGER PRIMARY KEY,
    template_json TEXT    NOT NULL,
    frequency     TEXT    NOT NULL CHECK (frequency IN ('weekly', 'monthly', 'yearly')),
    start_date    TEXT    NOT NULL,
    next_date     TEXT    NOT NULL,
    active        INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_by    INTEGER REFERENCES participants (id),
    created_at    TEXT    NOT NULL,
    updated_at    TEXT    NOT NULL
);

CREATE INDEX recurring_due ON recurring (next_date) WHERE active = 1;

CREATE TABLE expenses (
    id                    INTEGER PRIMARY KEY,
    title                 TEXT    NOT NULL,
    date                  TEXT    NOT NULL,
    category_id           INTEGER REFERENCES categories (id),
    paid_by               INTEGER NOT NULL REFERENCES participants (id),
    notes                 TEXT    NOT NULL DEFAULT '',
    is_reimbursement      INTEGER NOT NULL DEFAULT 0 CHECK (is_reimbursement IN (0, 1)),
    split_mode            TEXT    NOT NULL CHECK (split_mode IN ('equal', 'shares', 'percent', 'amount')),
    amount_cents          INTEGER NOT NULL CHECK (amount_cents > 0),
    -- Original amount; for EUR equal to amount_cents, fx_rate 1, fx_source ''.
    original_amount_minor INTEGER NOT NULL,
    original_currency     TEXT    NOT NULL DEFAULT 'EUR',
    fx_rate               REAL    NOT NULL DEFAULT 1,  -- foreign currency per 1 EUR (ECB format)
    fx_source             TEXT    NOT NULL DEFAULT '', -- '' | 'ezb' | 'manuell'
    recurring_id          INTEGER REFERENCES recurring (id) ON DELETE SET NULL,
    created_at            TEXT    NOT NULL,
    updated_at            TEXT    NOT NULL,
    deleted_at            TEXT
);

CREATE INDEX expenses_date ON expenses (date DESC, id DESC) WHERE deleted_at IS NULL;
CREATE INDEX expenses_paid_by ON expenses (paid_by);
CREATE INDEX expenses_category ON expenses (category_id);
-- Prevents duplicate instances of a recurrence (also after a restart).
CREATE UNIQUE INDEX expenses_recurring_date ON expenses (recurring_id, date) WHERE recurring_id IS NOT NULL;

-- weight depends on split_mode: equal → 1, shares → shares,
-- percent → basis points (sum 10000), amount → cents. amount_cents is the
-- computed share in cents (sum = expenses.amount_cents).
CREATE TABLE expense_shares (
    expense_id     INTEGER NOT NULL REFERENCES expenses (id) ON DELETE CASCADE,
    participant_id INTEGER NOT NULL REFERENCES participants (id),
    weight         INTEGER NOT NULL,
    amount_cents   INTEGER NOT NULL,
    PRIMARY KEY (expense_id, participant_id)
) WITHOUT ROWID;

CREATE INDEX expense_shares_participant ON expense_shares (participant_id);

-- Activity log. actor_id NULL = system (e.g. recurrence).
-- details_json: the ActivityDetails as JSON.
CREATE TABLE activity (
    id           INTEGER PRIMARY KEY,
    at           TEXT    NOT NULL,
    actor_id     INTEGER REFERENCES participants (id),
    action       TEXT    NOT NULL,
    expense_id   INTEGER REFERENCES expenses (id),
    details_json TEXT    NOT NULL DEFAULT '{}'
);

CREATE INDEX activity_expense ON activity (expense_id);

CREATE TABLE ynab_config (
    participant_id  INTEGER PRIMARY KEY REFERENCES participants (id),
    token           TEXT    NOT NULL,
    budget_id       TEXT    NOT NULL DEFAULT '',
    account_id      TEXT    NOT NULL DEFAULT '',
    start_date      TEXT,
    enabled         INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    updated_at      TEXT    NOT NULL,
    connected_at    TEXT,
    last_run        TEXT,
    last_sync       TEXT,
    summary         TEXT    NOT NULL DEFAULT '',
    error           TEXT    NOT NULL DEFAULT '',
    token_invalid   INTEGER NOT NULL DEFAULT 0 CHECK (token_invalid IN (0, 1)),
    retry_at        TEXT,
    backoff_seconds INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE ynab_category_map (
    participant_id   INTEGER NOT NULL REFERENCES participants (id),
    category_id      INTEGER NOT NULL REFERENCES categories (id),
    ynab_category_id TEXT    NOT NULL,
    PRIMARY KEY (participant_id, category_id)
) WITHOUT ROWID;

CREATE TABLE ynab_sync (
    expense_id     INTEGER NOT NULL REFERENCES expenses (id),
    participant_id INTEGER NOT NULL REFERENCES participants (id),
    ynab_txn_id    TEXT    NOT NULL DEFAULT '',
    synced_hash    TEXT    NOT NULL DEFAULT '',
    synced_at      TEXT,
    last_error     TEXT    NOT NULL DEFAULT '',
    PRIMARY KEY (expense_id, participant_id)
) WITHOUT ROWID;

CREATE INDEX ynab_sync_participant ON ynab_sync (participant_id);

CREATE TABLE settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;

-- Exchange rates in ECB format (foreign currency per 1 EUR). Manual and ECB rates of
-- the same day sit side by side; the lookup prefers manual ones.
CREATE TABLE fx_rates (
    date     TEXT NOT NULL,
    currency TEXT NOT NULL,
    rate     REAL NOT NULL CHECK (rate > 0),
    source   TEXT NOT NULL DEFAULT 'ezb' CHECK (source IN ('ezb', 'manuell')),
    PRIMARY KEY (currency, source, date)
) WITHOUT ROWID;

INSERT INTO categories (name, position) VALUES
    ('Lebensmittel', 10),
    ('Restaurant', 20),
    ('Haushalt', 30),
    ('Miete & Nebenkosten', 40),
    ('Transport', 50),
    ('Reisen', 60),
    ('Freizeit', 70),
    ('Gesundheit', 80),
    ('Geschenke', 90),
    ('Sonstiges', 1000);

INSERT INTO settings (key, value) VALUES ('group_name', 'Zipfelkasse');
