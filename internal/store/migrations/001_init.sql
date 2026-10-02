-- Migration 001: komplettes Grundschema von Zipfelkasse.
-- Konventionen:
--   * Beträge in Cent (INTEGER), Fremdwährung in der kleinsten Einheit.
--   * Kalenderdaten als TEXT 'YYYY-MM-DD', Zeitstempel als TEXT RFC 3339 UTC.
--   * Wahrheitswerte als INTEGER 0/1.
--   * Nichts wird hart gelöscht, was referenziert ist: archived_at / deleted_at.

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

-- Regel für wiederkehrende Ausgaben. template_json ist ein store.ExpenseInput
-- als JSON (das Datum darin wird ignoriert). Termine werden immer vom
-- start_date (Anker) aus berechnet, next_date ist der nächste fällige Termin.
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
    -- Originalbetrag; bei EUR gleich amount_cents, fx_rate 1, fx_source ''.
    original_amount_minor INTEGER NOT NULL,
    original_currency     TEXT    NOT NULL DEFAULT 'EUR',
    fx_rate               REAL    NOT NULL DEFAULT 1,  -- Fremdwährung pro 1 EUR (EZB-Format)
    fx_source             TEXT    NOT NULL DEFAULT '', -- '' | 'ezb' | 'manuell'
    recurring_id          INTEGER REFERENCES recurring (id) ON DELETE SET NULL,
    created_at            TEXT    NOT NULL,
    updated_at            TEXT    NOT NULL,
    deleted_at            TEXT
);

CREATE INDEX expenses_date ON expenses (date DESC, id DESC) WHERE deleted_at IS NULL;
CREATE INDEX expenses_paid_by ON expenses (paid_by);
CREATE INDEX expenses_category ON expenses (category_id);
-- Verhindert doppelte Instanzen einer Wiederholung (auch nach Neustart).
CREATE UNIQUE INDEX expenses_recurring_date ON expenses (recurring_id, date) WHERE recurring_id IS NOT NULL;

-- weight hängt von split_mode ab: equal → 1, shares → Anteile,
-- percent → Basispunkte (Summe 10000), amount → Cent. amount_cents ist der
-- berechnete Anteil in Cent (Summe = expenses.amount_cents).
CREATE TABLE expense_shares (
    expense_id     INTEGER NOT NULL REFERENCES expenses (id) ON DELETE CASCADE,
    participant_id INTEGER NOT NULL REFERENCES participants (id),
    weight         INTEGER NOT NULL,
    amount_cents   INTEGER NOT NULL,
    PRIMARY KEY (expense_id, participant_id)
) WITHOUT ROWID;

CREATE INDEX expense_shares_participant ON expense_shares (participant_id);

-- Aktivitätsprotokoll. actor_id NULL = System (z. B. Wiederholung).
-- details_json: siehe store.ActivityDetails.
CREATE TABLE activity (
    id           INTEGER PRIMARY KEY,
    at           TEXT    NOT NULL,
    actor_id     INTEGER REFERENCES participants (id),
    action       TEXT    NOT NULL,
    expense_id   INTEGER REFERENCES expenses (id),
    details_json TEXT    NOT NULL DEFAULT '{}'
);

CREATE INDEX activity_expense ON activity (expense_id);

-- Wechselkurse im EZB-Format (Fremdwährung pro 1 EUR).
CREATE TABLE fx_rates (
    date     TEXT NOT NULL,
    currency TEXT NOT NULL,
    rate     REAL NOT NULL CHECK (rate > 0),
    source   TEXT NOT NULL DEFAULT 'ezb', -- 'ezb' | 'manuell'
    PRIMARY KEY (currency, date)
) WITHOUT ROWID;

CREATE TABLE ynab_config (
    participant_id INTEGER PRIMARY KEY REFERENCES participants (id),
    token          TEXT    NOT NULL,
    budget_id      TEXT    NOT NULL DEFAULT '',
    account_id     TEXT    NOT NULL DEFAULT '',
    start_date     TEXT,
    enabled        INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    updated_at     TEXT    NOT NULL
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

INSERT INTO settings (key, value) VALUES
    ('group_name', 'Zipfelkasse'),
    ('default_currency', 'EUR');
