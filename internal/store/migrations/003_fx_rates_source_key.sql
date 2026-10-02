-- Migration 003: store manual and ECB rates of the same day side by side.
-- Before, a manual rate replaced the ECB row of its day (primary key
-- (currency, date)); deleting the manual rate then left a gap, and lookups
-- silently fell back to the previous day's ECB rate. Manual rates take
-- precedence in the lookup (fx.Service.Rate), not in the table.
-- SQLite cannot change a primary key: create the table anew and copy.

CREATE TABLE fx_rates_new (
    date     TEXT NOT NULL,
    currency TEXT NOT NULL,
    rate     REAL NOT NULL CHECK (rate > 0),
    source   TEXT NOT NULL DEFAULT 'ezb' CHECK (source IN ('ezb', 'manuell')),
    PRIMARY KEY (currency, source, date)
) WITHOUT ROWID;

INSERT INTO fx_rates_new (date, currency, rate, source)
    SELECT date, currency, rate, source FROM fx_rates;

DROP TABLE fx_rates;

ALTER TABLE fx_rates_new RENAME TO fx_rates;
