# Porting inventory: `internal/store` + `internal/domain` (Go → Crystal/Kemal + crystal-sqlite3)

Source: `/home/user/zipfelkasse` (read-only). All non-test files in `internal/store` and `internal/domain` were read in full, plus both migration files. All test files were read for the case lists.
Facts marked **[verified]** were checked by running a probe on a *copy* of the repo (Go 1.26.5, modernc sqlite v1.60.1) and with Crystal 1.21.1 or the system `sqlite3` 3.45.1.

Files covered:

| package | files (lines) |
|---|---|
| store | store.go (256), expenses.go (767), activity.go (141), participants.go (186), categories.go (197), settings.go (45), web.go (136), fx.go (221), recurring.go (295), ynab.go (493), ynabstate.go (61), mcp.go (730), fold.go (39), backup.go (54), resplit.go (80), amountweights.go (162), migrations/001_init.sql (149), migrations/003_fx_rates_source_key.sql (21) |
| domain | money.go (344), split.go (248), balance.go (66), date.go (167), fx.go (19) |

---

## 1. SQLite driver, DSN, PRAGMAs, pool, custom functions, read-only connections

### Driver
`go.mod`: `require modernc.org/sqlite v1.60.1`. This is a pure-Go transpilation of SQLite. **[verified] It embeds SQLite 3.53.4.** Compile options include `ENABLE_MATH_FUNCTIONS`, `ENABLE_FTS5`, `MAX_VARIABLE_NUMBER=32766`, `DEFAULT_SYNCHRONOUS=2`, `THREADSAFE=1`, `LIKE_DOESNT_MATCH_BLOBS` and `TEMP_STORE=1`.
Imports used: `modernc.org/sqlite` (driver, `sqlite.Error`, `sqlite.Limit`, `sqlite.ColumnInfo`, `MustRegisterDeterministicScalarFunction`) and `sqlite3 "modernc.org/sqlite/lib"` (constants: `SQLITE_CONSTRAINT_UNIQUE`, `SQLITE_CONSTRAINT_PRIMARYKEY`, `SQLITE_TOOBIG`, `SQLITE_LIMIT_ATTACHED`, `SQLITE_LIMIT_LENGTH`).

> **System libsqlite3 on this box is 3.45.1 [verified].** crystal-sqlite3 links the system lib. **`strftime('%G-W%V', …)`, which `Stats` uses for week grouping, needs SQLite ≥ 3.46.0. On 3.45.1 it returns NULL [verified].** Either link Crystal against SQLite ≥ 3.46 (ideally 3.53.x, for example a static amalgamation) or replace that expression. See §9.

### DSN (store.go `Open`)
```go
dsn := path + "?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_txlock=immediate"
db, err := sql.Open("sqlite", dsn)
```
- modernc applies the `_pragma`s **on every new connection, in this order**: busy_timeout=5000 ms, foreign_keys=1, journal_mode=WAL, synchronous=NORMAL.
- `_txlock=immediate`: **every `db.BeginTx` issues `BEGIN IMMEDIATE`**. This applies to all `inTx` calls, migrations included.
- For `path == ":memory:"` the DSN is `":memory:?_pragma=…"`, which gives an in-memory DB. journal_mode WAL then reports `memory`.
- Before opening, when the path is not `:memory:`: `os.MkdirAll(filepath.Dir(path), 0o755)`. On failure the error is `"create database directory: %w"`.
- Test `TestOpenFileTwiceIsIdempotent` asserts `PRAGMA journal_mode` = `"wal"` and `PRAGMA foreign_keys` = `1` on a file DB.
- **[verified]** A Go-created file has WAL set persistently in the header (bytes 18/19 = 2/2), page_size 4096, auto_vacuum 0, encoding UTF-8, application_id 0. A Go-created DB opens fine with system SQLite 3.45.1: integrity_check ok, foreign_key_check clean.

crystal-sqlite3 (v0.23.0 / crystal-db 0.14.0, found in `scratchpad/shardtest/lib`) supports the URI params `busy_timeout`, `cache_size`, `foreign_keys`, `journal_mode`, `synchronous` and `wal_autocheckpoint`. It runs them per connection as `PRAGMA k=v;` in the order busy_timeout, cache_size, foreign_keys, journal_mode, synchronous, so the order is compatible. Suggested DSN:
`sqlite3://<path>?busy_timeout=5000&foreign_keys=1&journal_mode=wal&synchronous=normal`
**But crystal-sqlite3 transactions run a plain `BEGIN`, which is deferred.** You must issue `BEGIN IMMEDIATE` yourself. See §9.

### Connection pool
- File DB: Go `database/sql` defaults apply (MaxOpenConns unlimited, MaxIdleConns 2). Nothing is set explicitly.
- `:memory:`: `db.SetMaxOpenConns(1)`, with the comment "Otherwise every connection would get its own empty database." In Crystal use `max_pool_size=1` (and `max_idle_pool_size=1`) for `:memory:`.
- The MCP sandbox opens its own `sql.Open("sqlite", ":memory:")` with **no** pragmas, `SetMaxOpenConns(1)` and a dedicated `*sql.Conn`. See §4 (mcp.go).

### Custom SQL functions / collations
Only one function is registered, and no collations or LIKE overrides. fold.go:
```go
const foldFunc = "zipfelkasse_fold"

func init() {
	sqlite.MustRegisterDeterministicScalarFunction(foldFunc, 1, func(_ *sqlite.FunctionContext, args []driver.Value) (driver.Value, error) {
		switch v := args[0].(type) {
		case string:
			return fold(v), nil
		case []byte:
			return fold(string(v)), nil
		case nil:
			return nil, nil
		default:
			return v, nil
		}
	})
}

func Fold(s string) string { return fold(s) }

func fold(s string) string {
	return strings.ReplaceAll(strings.ToLower(s), "ß", "ss")
}
```
- It is registered **driver-wide**, so it exists on every connection, the MCP sandbox included (`TestReadOnlyQueryHasFold`: `zipfelkasse_fold('BÄCKER Straße')` gives `'bäcker strasse'`, `(NULL)` gives NULL, `(42)` gives `42` as an integer).
- It is deterministic (`SQLITE_DETERMINISTIC`), takes 1 argument and uses UTF-8.
- Return types: TEXT input returns TEXT. **A BLOB input returns TEXT** (folded). NULL returns NULL. Integers and reals pass through unchanged.
- In Crystal, register it per connection with `sqlite3_create_function_v2` (flags `SQLITE_UTF8 | SQLITE_DETERMINISTIC`). Use `DB::Database#setup_connection { |conn| … }` for the main pool and call it explicitly on the sandbox connection. crystal-sqlite3 itself also registers a `regexp` function on every connection. That is harmless, but it makes `REGEXP` work in the sandbox where Go lacks it.
- Collation: only SQLite's built-in `NOCASE`, which folds ASCII only, declared on the `participants.name` and `categories.name` columns and used in `ORDER BY … COLLATE NOCASE`. Both sides use the same SQLite semantics, so copy the SQL verbatim.

### Read-only connections
Only the MCP `sql_query` sandbox uses them: `ATTACH DATABASE 'file:///abs/path?mode=ro' AS src` from a fresh in-memory DB. This needs URI filenames enabled. **[verified]** System SQLite is compiled with `USE_URI`, and modernc handles it. Details are in §4 (mcp.go).

---

## 2. Migration mechanics (exact)

Recording: **only `PRAGMA user_version`**. There is no migrations table. The current latest version is **5** **[verified]**.

```go
//go:embed migrations/*.sql
var migrationsFS embed.FS

// goMigrations are migrations written in Go for data fixes that SQL alone
// cannot do. They share the numbering with migrations/*.sql.
var goMigrations = map[int]func(s *Store, ctx context.Context, tx *sql.Tx) error{
	2: (*Store).resplitShares,
	4: (*Store).convertAmountWeights,
	5: (*Store).moveYNABStateIntoConfig,
}

func (s *Store) migrate(ctx context.Context) error {
	names, err := fs.Glob(migrationsFS, "migrations/*.sql")
	...
	for _, name := range names {
		base := filepath.Base(name)
		num, _, ok := strings.Cut(base, "_")
		n, err := strconv.Atoi(num)
		if !ok || err != nil || n <= 0 {
			return fmt.Errorf("migration %s: file name must start with NNN_", base)
		}
		ms = append(ms, migration{n: n, name: name})
	}
	for n, fn := range goMigrations {
		ms = append(ms, migration{n: n, name: fmt.Sprintf("%03d (Go)", n), fn: fn})
	}
	slices.SortFunc(ms, func(a, b migration) int { return a.n - b.n })

	current, err := s.SchemaVersion(ctx)   // PRAGMA user_version
	...
	for i, m := range ms {
		if i > 0 && ms[i-1].n == m.n {
			return fmt.Errorf("migration %d is defined twice", m.n)
		}
		if m.n <= current {
			continue
		}
		err = s.inTx(ctx, func(tx *sql.Tx) error {
			if m.fn != nil {
				if err := m.fn(s, ctx, tx); err != nil { return err }
			} else {
				body, err := migrationsFS.ReadFile(m.name)
				...
				if _, err := tx.ExecContext(ctx, string(body)); err != nil { return err }
			}
			_, err := tx.ExecContext(ctx, fmt.Sprintf("PRAGMA user_version = %d", m.n))
			return err
		})
		if err != nil {
			return fmt.Errorf("migration %s: %w", filepath.Base(m.name), err)
		}
	}
	return nil
}
```
Points to reproduce exactly:
- **The "gap" (001, 003, no 002 SQL file) is not a gap.** Numbers 2, 4 and 5 are Go migrations. The full sequence is 1 (SQL) → 2 (Go resplit) → 3 (SQL fx_rates PK) → 4 (Go weight conversion) → 5 (Go YNAB columns).
- **Each migration runs in its own transaction** (`BEGIN IMMEDIATE`, via inTx). `PRAGMA user_version = N` is set **inside** the same transaction. user_version lives in the DB header and is transactional, so a failed migration rolls back its version bump too.
- **Each SQL file runs as one multi-statement `Exec`.** **[verified]** modernc executes all statements, including leading `--` comments. **crystal-sqlite3 `exec` prepares only the first statement.** Use `sqlite3_exec` (`LibSQLite3.exec`) on the raw handle, or split the statements carefully. Migration 5's Go code also runs a 3-statement SQL string with comments in one `ExecContext`.
- A DB whose `user_version` is greater than the latest is **not** an error. All migrations are simply skipped.
- Error wrapping: `"migration 001_init.sql: <err>"`, or for Go migrations `"migration 002 (Go): <err>"` (`filepath.Base("002 (Go)")` is unchanged).
- On a fresh DB the Go migrations 2 and 4 are no-ops (no expenses), so they write no activity. Migration 5 adds the YNAB columns.
- Tests re-run migrations by setting `PRAGMA user_version = 1/2/3/4` and reopening. Migrations 2, 4 and 5 must be **idempotent**: re-running them changes nothing and logs nothing the second time. Migration 5 checks `pragma_table_info` before each `ALTER TABLE ADD COLUMN`.
- `SchemaVersion(ctx)` = `SELECT`-scan of `PRAGMA user_version` into int.

### Byte-identical schema requirement
SQLite stores the **literal text** of each CREATE statement in `sqlite_schema`, **including inline comments** inside the statement **[verified]**, for example in `expenses`: `-- Original amount; for EUR equal to amount_cents, fx_rate 1, fx_source ''.` and `REAL    NOT NULL DEFAULT 1,  -- foreign currency per 1 EUR (ECB format)`.
- **Copy both `.sql` files byte-for-byte** (md5 `b46ca714ac1bcaaf9b963850a0fb4dbc` for 001_init.sql, `4568728517770c91033253ef360db879` for 003_fx_rates_source_key.sql). Embed them with `{{ read_file(...) }}`. 001_init.sql is UTF-8 because its comments contain "→".
- Migration 3's `ALTER TABLE fx_rates_new RENAME TO fx_rates` makes SQLite rewrite the stored text to `CREATE TABLE "fx_rates" (` with quotes **[verified]**.
- Migration 5 appends columns by running exactly these statements, in this order, only if the column is missing:
  ```
  ALTER TABLE ynab_config ADD COLUMN connected_at TEXT
  ALTER TABLE ynab_config ADD COLUMN last_run TEXT
  ALTER TABLE ynab_config ADD COLUMN last_sync TEXT
  ALTER TABLE ynab_config ADD COLUMN summary TEXT NOT NULL DEFAULT ''
  ALTER TABLE ynab_config ADD COLUMN error TEXT NOT NULL DEFAULT ''
  ALTER TABLE ynab_config ADD COLUMN token_invalid INTEGER NOT NULL DEFAULT 0 CHECK (token_invalid IN (0, 1))
  ALTER TABLE ynab_config ADD COLUMN retry_at TEXT
  ALTER TABLE ynab_config ADD COLUMN backoff_seconds INTEGER NOT NULL DEFAULT 0
  ```
  The resulting stored SQL **[verified]** ends with `    updated_at     TEXT    NOT NULL\n, connected_at TEXT, last_run TEXT, last_sync TEXT, summary TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '', token_invalid INTEGER NOT NULL DEFAULT 0 CHECK (token_invalid IN (0, 1)), retry_at TEXT, backoff_seconds INTEGER NOT NULL DEFAULT 0)`.
- Existence check: `SELECT count(*) FROM pragma_table_info('ynab_config') WHERE name = ?`.
- Resulting `sqlite_schema` order **[verified]** (rowid, root page): participants, sqlite_autoindex_participants_1, categories, sqlite_autoindex_categories_1, recurring, recurring_due, expenses, expenses_date, expenses_paid_by, expenses_category, expenses_recurring_date, expense_shares, expense_shares_participant, activity, activity_expense, ynab_config, ynab_category_map, ynab_sync, ynab_sync_participant, settings, fx_rates (re-created in migration 3, so it comes last). This order matters for `MCPSchema`, which orders by rowid.

### Migration 2: `resplitShares` (resplit.go)
- Query: `SELECT e.id, e.split_mode, e.amount_cents, x.participant_id, x.weight, x.amount_cents FROM expenses e JOIN expense_shares x ON x.expense_id = e.id ORDER BY e.id, x.participant_id`. It includes **deleted** expenses.
- For each expense it computes `fresh, err := domain.Split(mode, amount, parts(weights), e.id)`. On error it skips (`continue`) and leaves the expense unchanged. It compares `fresh[i].AmountCents` with the stored share at the same index (both sorted by participant). For each mismatch: `UPDATE expense_shares SET amount_cents = ? WHERE expense_id = ? AND participant_id = ?`.
- If `changed > 0`, it inserts activity: actor NULL, action `shares_recalculated`, expense_id NULL, details `{"text":"Rest-Cents von %d Ausgaben neu verteilt: Bei Gleichstand bekommt den Extra-Cent jetzt reihum eine andere Person statt immer dieselbe."}`.
- Note: it uses `Split`, which is EUR-only, so foreign-currency amount-mode expenses whose weights don't sum to amount_cents fail validation and are skipped.

### Migration 3 (SQL)
fx_rates gets PK `(currency, source, date)` and `CHECK (source IN ('ezb','manuell'))`. The steps are create new table, copy, drop, rename.

### Migration 4: `convertAmountWeights` (amountweights.go)
- Query: `SELECT e.id, e.original_amount_minor, x.participant_id, x.weight FROM expenses e JOIN expense_shares x ON x.expense_id = e.id WHERE e.split_mode = ? AND e.is_reimbursement = 0 AND e.original_currency <> 'EUR' ORDER BY e.id, x.participant_id`, with arg `'amount'`. It includes deleted expenses.
- `toOriginalWeights(parts, original)`:
  ```go
  ps := slices.Clone(parts)
  slices.SortFunc(ps, func(a, b domain.Part) int { return cmp.Compare(a.ParticipantID, b.ParticipantID) })
  ... if p.Weight < 0 { return parts, false }; sum += p.Weight
  if sum <= 0 || original <= 0 { return parts, false }
  for i, w := range domain.Allocate(original, weights, 0) {   // rotation 0 → ties to smaller participant ID
      if w != ps[i].Weight { ps[i].Weight, changed = w, true }
  }
  ```
  For each changed expense: `UPDATE expense_shares SET weight = ? WHERE expense_id = ? AND participant_id = ?` for **all** parts.
- Templates: `SELECT id, template_json FROM recurring ORDER BY id`. It unmarshals ExpenseInput. If that fails, the error is `"recurring %d: template: %w"` and the migration fails. A template is skipped when `SplitMode != amount || IsReimbursement || upper(OriginalCurrency) in ("", "EUR")`. Otherwise it converts and `json.Marshal`s, then runs `UPDATE recurring SET template_json = ? WHERE id = ?`. The updates run from a Go map (random order). That is irrelevant to the result.
- Activity, if anything changed: actor NULL, action `weights_converted`, details text:
  `"Aufteilung nach Beträgen in Fremdwährung umgestellt (%s): Die Beträge pro Person stehen jetzt in der Originalwährung statt in Euro. Die Euro-Anteile bleiben unverändert."`
  `%s` = the parts joined with `" und "` from `countNoun(n,"Ausgabe","Ausgaben")` and `countNoun(n,"wiederkehrende Ausgabe","wiederkehrende Ausgaben")`. `countNoun` gives `"1 Ausgabe"` or `"%d Ausgaben"`. Test expects `"2 Ausgaben und 1 wiederkehrende Ausgabe"`.

### Migration 5: `moveYNABStateIntoConfig` (ynabstate.go)
After adding the columns (above), it runs this one multi-statement Exec:
```sql
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

DELETE FROM settings WHERE key LIKE 'ynab.status.%' OR key LIKE 'ynab.connected.%';
```
- It needs `UPDATE … FROM` (SQLite ≥ 3.33) and JSON1, both of which 3.45 has.
- It copies timestamps **verbatim**, so migrated `last_run` values may carry an offset and fractions, for example `2026-09-20T12:00:00.5+02:00`. See §9.

---

## 3. Schema summary

Conventions, from the header comment of 001_init.sql:
- Amounts are INTEGER cents. Foreign currency is stored in its smallest unit.
- **Calendar dates are TEXT `'YYYY-MM-DD'`.**
- **Timestamps are TEXT RFC 3339 UTC.** Second precision `2026-10-03T12:05:06Z` comes from Go's `time.RFC3339` layout and **truncates** fractions **[verified]**. The exception is the YNAB status columns, which use RFC3339Nano (see below).
- Booleans are INTEGER 0/1 with CHECKs.
- Nothing referenced is hard-deleted. Records get `archived_at`/`deleted_at` instead. The exceptions are `recurring` and `fx_rates` (manual) rows and `ynab_*` rows, which can be hard-deleted.

| table | columns (type, constraints) | notes |
|---|---|---|
| **participants** | id INTEGER PK; name TEXT NOT NULL UNIQUE COLLATE NOCASE CHECK(length(trim(name))>0); created_at TEXT NOT NULL; archived_at TEXT | rowid table; autoindex for UNIQUE. NOCASE = ASCII only ("Ärger" ≠ "ärger") |
| **categories** | id INTEGER PK; name TEXT NOT NULL UNIQUE COLLATE NOCASE CHECK(...); position INTEGER NOT NULL DEFAULT 0; archived_at TEXT | **no created_at**. Seeds: Lebensmittel 10, Restaurant 20, Haushalt 30, Miete & Nebenkosten 40, Transport 50, Reisen 60, Freizeit 70, Gesundheit 80, Geschenke 90, Sonstiges 1000 (ids 1..10) |
| **recurring** | id INTEGER PK; template_json TEXT NOT NULL; frequency TEXT NOT NULL CHECK IN('weekly','monthly','yearly'); start_date TEXT NOT NULL; next_date TEXT NOT NULL; active INTEGER NOT NULL DEFAULT 1 CHECK IN(0,1); created_by INTEGER REFERENCES participants(id); created_at TEXT NOT NULL; updated_at TEXT NOT NULL | index `recurring_due ON recurring (next_date) WHERE active = 1` |
| **expenses** | id INTEGER PK; title TEXT NOT NULL; date TEXT NOT NULL; category_id INTEGER REFERENCES categories(id); paid_by INTEGER NOT NULL REFERENCES participants(id); notes TEXT NOT NULL DEFAULT ''; is_reimbursement INTEGER NOT NULL DEFAULT 0 CHECK IN(0,1); split_mode TEXT NOT NULL CHECK IN('equal','shares','percent','amount'); amount_cents INTEGER NOT NULL CHECK(amount_cents>0); original_amount_minor INTEGER NOT NULL; original_currency TEXT NOT NULL DEFAULT 'EUR'; fx_rate REAL NOT NULL DEFAULT 1; fx_source TEXT NOT NULL DEFAULT ''; recurring_id INTEGER REFERENCES recurring(id) ON DELETE SET NULL; created_at TEXT NOT NULL; updated_at TEXT NOT NULL; deleted_at TEXT | indexes: `expenses_date ON expenses (date DESC, id DESC) WHERE deleted_at IS NULL`; `expenses_paid_by (paid_by)`; `expenses_category (category_id)`; **`UNIQUE INDEX expenses_recurring_date ON expenses (recurring_id, date) WHERE recurring_id IS NOT NULL`** |
| **expense_shares** | expense_id INTEGER NOT NULL REFERENCES expenses(id) ON DELETE CASCADE; participant_id INTEGER NOT NULL REFERENCES participants(id); weight INTEGER NOT NULL; amount_cents INTEGER NOT NULL; PK(expense_id, participant_id) | **WITHOUT ROWID**; index `expense_shares_participant (participant_id)`. weight: equal=1, shares=shares, percent=basis points (sum 10000), amount=smallest unit of the **original currency** (since migration 4) |
| **activity** | id INTEGER PK; at TEXT NOT NULL; actor_id INTEGER REFERENCES participants(id) (NULL = system); action TEXT NOT NULL; expense_id INTEGER REFERENCES expenses(id); details_json TEXT NOT NULL DEFAULT '{}' | index `activity_expense (expense_id)` |
| **fx_rates** (after migration 3) | date TEXT NOT NULL; currency TEXT NOT NULL; rate REAL NOT NULL CHECK(rate>0); source TEXT NOT NULL DEFAULT 'ezb' CHECK(source IN ('ezb','manuell')); PK(currency, source, date) | WITHOUT ROWID; stored as `CREATE TABLE "fx_rates"` |
| **ynab_config** | participant_id INTEGER PK REFERENCES participants(id); token TEXT NOT NULL; budget_id TEXT NOT NULL DEFAULT '' (= PlanID); account_id TEXT NOT NULL DEFAULT ''; start_date TEXT (date); enabled INTEGER NOT NULL DEFAULT 1 CHECK IN(0,1); updated_at TEXT NOT NULL; + migration 5: connected_at TEXT, last_run TEXT, last_sync TEXT, summary TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '', token_invalid INTEGER NOT NULL DEFAULT 0 CHECK IN(0,1), retry_at TEXT, backoff_seconds INTEGER NOT NULL DEFAULT 0 | rowid table (INTEGER PK = rowid alias) |
| **ynab_category_map** | participant_id INTEGER NOT NULL REFERENCES participants(id); category_id INTEGER NOT NULL REFERENCES categories(id); ynab_category_id TEXT NOT NULL; PK(participant_id, category_id) | WITHOUT ROWID |
| **ynab_sync** | expense_id INTEGER NOT NULL REFERENCES expenses(id); participant_id INTEGER NOT NULL REFERENCES participants(id); ynab_txn_id TEXT NOT NULL DEFAULT ''; synced_hash TEXT NOT NULL DEFAULT ''; synced_at TEXT; last_error TEXT NOT NULL DEFAULT ''; PK(expense_id, participant_id) | WITHOUT ROWID; index `ynab_sync_participant (participant_id)` |
| **settings** | key TEXT PRIMARY KEY; value TEXT NOT NULL | WITHOUT ROWID. Seeds: `group_name`='Zipfelkasse', `default_currency`='EUR' |

There are **no triggers** and **no views**.

Non-obvious stored formats **[verified]**:
- `expenses.date`, `recurring.start_date/next_date`, `fx_rates.date`, `ynab_config.start_date`: `YYYY-MM-DD`.
- `*_at` columns written by `nowString()`: `2026-10-03T12:05:06Z`, which is UTC, RFC3339, with **no fractional seconds**.
- `ynab_config.last_run/last_sync/retry_at` (written by `SetYNABStatus`): **RFC3339Nano UTC** with trailing zeros trimmed, for example `2026-09-01T10:00:00.123456789Z`, `2026-09-01T10:00:00.5Z`, or `2026-09-01T10:00:00Z` when there is no fraction. NULL for the zero time. After migration 5 they may also contain offsets.
- `ynab_sync.synced_at`: RFC3339 seconds, UTC, or NULL.
- `fx_rate`: REAL. For EUR it is `1.0`, typeof real.
- Booleans are typeof integer.
- `category_id`, `recurring_id`, `actor_id`, `expense_id` (activity) and `created_by` are **NULL instead of 0**, via `nullInt(v)` = NULL when v == 0.
- `template_json` (recurring), exact Go `encoding/json` output of `store.ExpenseInput` **[verified]**:
  ```json
  {"title":"Pizza & <Wein>","date":"0001-01-01T00:00:00Z","category_id":1,"paid_by":1,"notes":"","is_reimbursement":false,"split_mode":"equal","amount_cents":2310,"parts":[{"participant_id":1,"weight":1},{"participant_id":2,"weight":1}],"original_amount_minor":2500,"original_currency":"USD","fx_rate":1.0823,"fx_source":"ezb","recurring_id":0}
  ```
  - Key order is fixed and nothing is omitted.
  - `date` is always Go's zero time `"0001-01-01T00:00:00Z"`.
  - `parts` is `null` if nil.
  - Go escapes `& < >` as `& < >`, and U+2028/2029 as well.
  - Floats use Go formatting: `1` (not `1.0`), `1e-7`, `1e+21`.
  - Old or test templates may be `'{}'` or lack keys. Missing values mean the zero value.
- `details_json` (activity), from Go `json.Marshal(ActivityDetails)` with `omitempty` **[verified]**:
  ```json
  {"text":"Person „Anna“ hinzugefügt"}
  {"title":"Pizza & <Wein>","amount_cents":1001}
  {"title":"…","amount_cents":2310,"changes":[{"field":"Betrag","old":"10,01 €","new":"23,10 €"},{"field":"Originalbetrag","old":"10,01 €","new":"25,00 USD"},{"field":"Kurs","old":"–","new":"1 € = 1,0823 USD (EZB)"},{"field":"Aufteilung","old":"Gleichmäßig: Anna 5,00 €, Ben 5,01 €","new":"Gleichmäßig: Anna 11,55 €, Ben 11,55 €"}]}
  {"title":"…","amount_cents":2310,"text":"„…“ wiederholt sich jetzt monatlich."}
  ```
  - Key order: title, amount_cents, changes, text. Each of them is omitted when empty or 0.
  - FieldChange always has `field`, `old`, `new`.
  - Non-ASCII characters (`„“ € –`) are written raw as UTF-8, not escaped.

---

## 4. Store API (every exported function)

General conventions:
- `inTx` = `BEGIN IMMEDIATE`. It commits when `fn` returns nil and rolls back otherwise.
- **The activity entry is always written inside the same transaction as the change.** If the activity insert fails, the change rolls back (`TestActivityFailureRollsBackChange`).
- Failed mutations write nothing (`TestFailedMutationsLogNothing`).
- `nowString()` = `s.now().UTC().Format(time.RFC3339)`. `s.now` defaults to `time.Now` and can be replaced with `SetClock(func() time.Time)`, which is for tests only.
- `formatDate(t)` = `t.Format("2006-01-02")` **in t's own location** (no UTC conversion). `parseDate(v)` = `time.Parse("2006-01-02", v)`, which gives 00:00 UTC.
- `parseTime(sql.NullString)`: NULL or `""` gives the zero time. Otherwise `time.Parse(time.RFC3339, s)`, which **accepts fractional seconds and any offset**. **A parse error is swallowed and returns the zero time.**
- `invalid(fmt, args…)` returns a `domain.ValidationError{Msg: fmt.Sprintf(...)}`. It is a German user-facing message, except in the MCP sandbox, where messages are English.
- `isUniqueViolation(err)`: `*sqlite.Error` with extended code `SQLITE_CONSTRAINT_UNIQUE` (2067) **or** `SQLITE_CONSTRAINT_PRIMARYKEY` (1555).
- `checkAffected(res, err)`: when RowsAffected == 0 it returns `ErrNotFound`.
- The `queryer` interface (`*sql.DB`, `*sql.Tx` or `*sql.Conn`) lets read helpers run inside or outside a transaction.

### Sentinel errors (exact messages)
| var | message |
|---|---|
| `ErrNotFound` | `not found` |
| `ErrRecurringExists` | `expense for this occurrence already exists` |
| `ErrRecurringChanged` | `recurring rule was paused, deleted or advanced meanwhile` |
| `ErrNoInstance` | `recurring rule has no expense` |
| `domain.ValidationError{Msg}` | `Error()` returns Msg |

### Activity actions (constants)
`expense_created`, `expense_updated`, `expense_deleted`, `settings_updated`, `shares_recalculated`, `weights_converted`, `recurring_created`, `recurring_deleted` (the last two are in recurring.go).

`insertActivity(ctx, tx, actorID, action, expenseID, d)` writes:
`INSERT INTO activity (at, actor_id, action, expense_id, details_json) VALUES (?, ?, ?, ?, ?)` with args `nowString(), nullInt(actorID), action, nullInt(expenseID), json(d)`.
`logSettings(tx, actor, text)` = `insertActivity(actor, "settings_updated", 0, {Text: text})`.

### store.go
| func | behaviour |
|---|---|
| `Open(path string) (*Store, error)` | See §1/§2. Runs migrations. On migration error it closes the DB and returns the error. |
| `(s) Close() error` | `db.Close()` |
| `(s) Path() string` | Returns the path as given (`":memory:"` in tests). |
| `(s) Ping(ctx) error` | `PingContext` (health check) |
| `(s) SchemaVersion(ctx) (int, error)` | `PRAGMA user_version` |
| `(s) OnExpenseChange(fn func(ExpenseChange))` | Appends a hook (RWMutex). |
| `(s) SetClock(now func() time.Time)` | Test clock. |
| `NormalizeName(name) string` | `strings.Join(strings.Fields(name), " ")`. Splits on Unicode whitespace, U+0085 included. |
| `type ExpenseChange{ExpenseID int64; Action string}` | |

`notify(c)` clones the hook slice under RLock, then calls each hook **synchronously after a successful commit**. Hooks run only for create, for update **when something changed**, and for delete.

`cleanName(name, what)`: NormalizeName. Empty gives `"Bitte einen Namen für %s angeben."` (`what` is `"die Person"`, `"die Kategorie"` or `"die Gruppe"`). `len([]rune(name)) > 60` gives `"Der Name ist zu lang (höchstens 60 Zeichen)."`.

### settings.go
| func | SQL / behaviour |
|---|---|
| `GetSetting(ctx, key) (string, error)` | `SELECT value FROM settings WHERE key = ?`. No row gives `ErrNotFound`. |
| `SetSetting(ctx, key, value) error` | `INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value` (constant `setSettingSQL`). **No activity.** Not in an explicit transaction. |
| `GroupName(ctx) string` | GetSetting("group_name"). Any error or `""` gives `"Zipfelkasse"`. |
| consts | `SettingGroupName="group_name"`, `SettingDefaultCurrency="default_currency"` |

### web.go
- `SetGroupName(ctx, actorID, name) error`
  - cleanName(name, "die Gruppe"), then in a transaction: `SELECT value FROM settings WHERE key = ?` (ErrNoRows is OK). `old = cmp.Or(old, "Zipfelkasse")`.
  - **It always executes the upsert** (`setSettingSQL`), even when the name is unchanged.
  - Logs only when `old != name`: `"Gruppe umbenannt: „%s“ → „%s“"`.
- `MoveCategory(ctx, actorID, id, up bool) error`
  - In a transaction: activeCategories(tx), then finds the index. Not found or archived gives `ErrNotFound`.
  - `other = idx-1` with dir `"oben"` when up, or `idx+1` with dir `"unten"`. At the edges it returns nil with no write and no log.
  - It swaps the IDs, runs renumberCategories (positions 10, 20, … for **active** categories only), and logs `"Kategorie „%s“ nach %s verschoben"` with the name `active[idx].Name`.
- `ExpenseCountByCategory(ctx) (map[int64]int, error)`: `SELECT category_id, count(*) FROM expenses WHERE deleted_at IS NULL AND category_id IS NOT NULL GROUP BY category_id`
- `ExpenseCountByParticipant(ctx) (map[int64]int, error)`:
  ```sql
  SELECT pid, count(DISTINCT eid) FROM (
      SELECT e.paid_by AS pid, e.id AS eid FROM expenses e WHERE e.deleted_at IS NULL
      UNION ALL
      SELECT x.participant_id, x.expense_id FROM expense_shares x
          JOIN expenses e ON e.id = x.expense_id WHERE e.deleted_at IS NULL
  ) GROUP BY pid
  ```
- `CategoryHistory(ctx) ([]TitleCategory, error)`: `SELECT e.title, e.category_id FROM expenses e JOIN categories c ON c.id = e.category_id WHERE e.deleted_at IS NULL AND e.is_reimbursement = 0 AND c.archived_at IS NULL ORDER BY e.date DESC, e.id DESC`. `TitleCategory{Title string; CategoryID int64}`.

### participants.go
- `Participant{ID, Name, CreatedAt, ArchivedAt time.Time}`, `Archived()` = `!ArchivedAt.IsZero()`. Columns: `id, name, created_at, archived_at`.
- `ListParticipants(ctx, includeArchived bool)`: `SELECT id, name, created_at, archived_at FROM participants [WHERE archived_at IS NULL] ORDER BY name COLLATE NOCASE, id`
- `GetParticipant(ctx, id)`: `SELECT … WHERE id = ?`. No row gives ErrNotFound. Archived participants are returned too.
- `CreateParticipant(ctx, actorID, name) (int64, error)` / `JoinAsParticipant(ctx, name)`
  - Both call `createParticipant(ctx, actorID, self, name)`: cleanName(name, "die Person"), then in a transaction `INSERT INTO participants (name, created_at) VALUES (?, ?)`.
  - A unique violation gives `invalid("„%s“ gibt es schon.", name)`.
  - id = LastInsertId. If self, actorID = id.
  - Logs `"Person „%s“ hinzugefügt"`.
- `RenameParticipant(ctx, actorID, id, name)`
  - cleanName, then in a transaction getParticipant (missing gives ErrNotFound), then `UPDATE participants SET name = ? WHERE id = ?`. This **runs even if unchanged**.
  - Unique violation gives `„%s“ gibt es schon.`.
  - Logs only if `old.Name != name` (case-sensitive): `"Person „%s“ umbenannt in „%s“"`.
- `SetParticipantArchived(ctx, actorID, id, archived bool)`
  - In a transaction: getParticipant.
  - When archiving, it computes the balance:
    ```sql
    SELECT
      (SELECT coalesce(sum(amount_cents), 0) FROM expenses WHERE paid_by = ?1 AND deleted_at IS NULL) -
      (SELECT coalesce(sum(x.amount_cents), 0) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id
         WHERE x.participant_id = ?1 AND e.deleted_at IS NULL)
    ```
    If the balance is not 0: `invalid("%s hat noch einen Saldo von %s. Bitte erst ausgleichen, dann archivieren.", p.Name, domain.FormatCents(balance))`. Test: `"Ben hat noch einen Saldo von -5,00 €"`.
  - Then `UPDATE participants SET archived_at = ? WHERE id = ?`, with `nowString()` or NULL.
  - **It always logs**, even when the state does not change: `"Person „%s“ archiviert"` or `"Person „%s“ reaktiviert"`.
  - Restoring does no balance check.

### categories.go
- `Category{ID, Name, Position int64, ArchivedAt}`. Columns: `id, name, position, archived_at`.
- `ListCategories(ctx, includeArchived)`: `… [WHERE archived_at IS NULL] ORDER BY position, name COLLATE NOCASE, id`
- `GetCategory(ctx, id)`: ErrNotFound when missing.
- `CreateCategory(ctx, actorID, name) (int64, error)`
  - cleanName(name, "die Kategorie"). In a transaction: `active` = active categories (read **before** the insert), then `INSERT INTO categories (name, position) VALUES (?, 0)`. A unique violation gives `"Die Kategorie „%s“ gibt es schon."`.
  - Insertion index `at` is the first active category with `strings.EqualFold(c.Name, "Sonstiges")`, else `len(active)`. New order: active[:at] + new + active[at:]. renumberCategories (`UPDATE categories SET position = ? WHERE id = ?` with (i+1)*10).
  - Logs `"Kategorie „%s“ hinzugefügt"`.
- `RenameCategory(ctx, actorID, id, name)`: like RenameParticipant, with the messages `"Die Kategorie „%s“ gibt es schon."` and `"Kategorie „%s“ umbenannt in „%s“"`.
- `SetCategoryArchived(ctx, actorID, id, archived)`: `UPDATE categories SET archived_at = ? WHERE id = ?` (now or NULL). Always logs `"Kategorie „%s“ archiviert|reaktiviert"`. There is no check on use, and the position is untouched.

### expenses.go

Types:
- `ExpenseInput`: JSON tags as in §3. Fields: Title, Date (time), CategoryID, PaidBy, Notes, IsReimbursement, SplitMode, AmountCents, Parts []domain.Part, OriginalAmountMinor, OriginalCurrency, FXRate float64, FXSource, RecurringID.
- `Expense{ID; ExpenseInput (embedded); Shares []domain.Share (sorted by participant); CategoryName ("" if none); PaidByName; CreatedAt; UpdatedAt; DeletedAt}`. Methods: `Deleted()`, `IsForeign()` = `!domain.IsEUR(OriginalCurrency)`, `ShareOf(pid)`, which returns 0 when absent.
- `ExpenseFilter{Text; AnyText []string; CategoryID; WithoutCategory; ParticipantID; PaidBy; InvolvedID; MinCents; MaxCents; From, To time.Time; Sort string; Limit, Offset int}`.
- Sort consts: `"date_desc"`, `"date_asc"`, `"amount_desc"`, `"amount_asc"`. The map `expenseOrder`:
  ```
  "" / date_desc → "e.date DESC, e.id DESC"
  date_asc       → "e.date, e.id"
  amount_desc    → "e.amount_cents DESC, e.date DESC, e.id DESC"
  amount_asc     → "e.amount_cents, e.date DESC, e.id DESC"
  ```
  An unknown sort gives a plain error `unknown sort order %q` (Go %q quoting). It is **not** a ValidationError.

`textCond(terms...)` handles text search. **It uses `instr` + fold, not LIKE, so no LIKE escaping is needed.**
```go
for _, t := range terms {
    if t = strings.TrimSpace(t); t == "" { continue }
    t = fold(t)
    ors = append(ors, "instr(zipfelkasse_fold(e.title), ?) > 0 OR instr(zipfelkasse_fold(e.notes), ?) > 0")
    args = append(args, t, t)
}
// → "(" + join(ors, " OR ") + ")"
```
Tests: "100%" finds "Kino 100%". "BÄCKER", "bäcker", "brötchen", "STRASSE", "straße" and "ẞ" all match case-insensitively, and "Baecker" does **not** match "bäcker".

`normalize(in)` validates. The order of checks is significant for which message appears:
1. `in.Title = strings.Join(strings.Fields(in.Title), " ")`; `in.Notes = strings.TrimSpace(in.Notes)` (notes are **stored with CRLF intact**).
2. Title "" gives `"Bitte einen Titel angeben."`. More than 200 runes gives `"Der Titel ist zu lang (höchstens 200 Zeichen)."`. Notes rune count, **after replacing `\r\n` with `\n`**, over 2000 gives `"Die Notiz ist zu lang (höchstens 2000 Zeichen)."`. Date zero gives `"Bitte ein Datum angeben."`. PaidBy ≤ 0 gives `"Bitte angeben, wer bezahlt hat."`.
3. `in.Date = domain.DateOf(in.Date)`.
4. Reimbursement: `len(Parts) != 1` gives `"Eine Rückzahlung geht an genau eine Person."`. Part == payer gives `"Bei einer Rückzahlung müssen Zahler und Empfänger verschieden sein."`. Then SplitMode is forced to `equal`.
5. `domain.IsEUR(cur)`: sets `OriginalCurrency="EUR"`, `OriginalAmountMinor=AmountCents`, `FXRate=1`, `FXSource=""`. **FXSource is cleared.**
   Otherwise: cur = upper(trim). Invalid code gives `"Ungültige Währung „%s“."`. OriginalAmountMinor ≤ 0 gives `"Bitte den Betrag in %s angeben."`. FXRate ≤ 0 gives `"Bitte einen Wechselkurs für %s angeben."`. **`AmountCents = domain.ToEURCents(minor, cur, rate)`, so the caller's value is ignored.** If that is ≤ 0: `"Umgerechnet ergibt der Betrag 0 € – bitte Betrag und Kurs prüfen."`.
6. `splitShares(in, 0)`, which is `domain.SplitConverted(mode, AmountCents, OriginalAmountMinor, OriginalCurrency, Parts, expenseID)`. This validates the split. Then `in.Parts` is replaced by the normalized parts: **sorted by participant ID, with equal weights set to 1**.

`checkRefs(tx, in)`:
- ids = [PaidBy] + part IDs, sorted and compacted. `SELECT count(*) FROM participants WHERE id IN (?,?,…)`. A count mismatch gives `"Unbekannte Person in der Ausgabe."`.
- CategoryID != 0: `SELECT count(*) FROM categories WHERE id = ?`. Not 1 gives `"Unbekannte Kategorie."`.
- **Archived people and categories are accepted.**

| func | details |
|---|---|
| `CreateExpense(ctx, actorID, in) (int64, error)` | normalize, then a transaction:<br>• checkRefs.<br>• If RecurringID != 0: `SELECT active FROM recurring WHERE id = ?`. No row or inactive gives **ErrRecurringChanged**.<br>• `INSERT INTO expenses (title, date, category_id, paid_by, notes, is_reimbursement, split_mode, amount_cents, original_amount_minor, original_currency, fx_rate, fx_source, recurring_id, created_at, updated_at) VALUES (15×?)` with `formatDate(date)`, `nullInt(cat)`, bool, `nullInt(recurringID)`, created_at = updated_at = now. A unique violation (recurring_id, date) gives **ErrRecurringExists**.<br>• id = LastInsertId. shares = `splitShares(in, id)`, **so the rotation uses the new ID**.<br>• insertShares: one `INSERT INTO expense_shares (expense_id, participant_id, weight, amount_cents) VALUES (?, ?, ?, ?)` per share.<br>• activity `expense_created`, expense_id=id, `{title, amount_cents}`.<br>After commit: notify(created). |
| `UpdateExpense(ctx, actorID, id, in) error` | normalize, then shares = splitShares(in, id) (before the transaction). In the transaction:<br>• getExpense(tx, id). Missing or **deleted** gives ErrNotFound.<br>• checkRefs. `in.RecurringID = old.RecurringID`, so it is kept.<br>• changes = diffExpense. **If there are no changes, it returns nil with no UPDATE (updated_at unchanged), no log and no hook.**<br>• `UPDATE expenses SET title=?, date=?, category_id=?, paid_by=?, notes=?, is_reimbursement=?, split_mode=?, amount_cents=?, original_amount_minor=?, original_currency=?, fx_rate=?, fx_source=?, updated_at=? WHERE id=?`. A unique violation gives `invalid("Für diesen Termin gibt es schon eine Ausgabe dieser Wiederholung.")`.<br>• `DELETE FROM expense_shares WHERE expense_id = ?` + insertShares.<br>• activity `expense_updated` `{title, amount_cents, changes}`.<br>notify(updated) only if changed. |
| `DeleteExpense(ctx, actorID, id) error` | In a transaction: getExpense. Missing or already deleted gives ErrNotFound. `UPDATE expenses SET deleted_at = ?, updated_at = ? WHERE id = ?` (both now). Activity `expense_deleted` `{title: old.Title, amount_cents: old.AmountCents}`. notify(deleted). Shares are kept. |
| `GetExpense(ctx, id) (Expense, error)` | Includes deleted expenses. Missing gives ErrNotFound. |
| `ListExpenses(ctx, f) ([]Expense, error)` | WHERE `e.deleted_at IS NULL` AND, in this order:<br>• textCond(Text + AnyText…)<br>• WithoutCategory → `e.category_id IS NULL`, else CategoryID → `e.category_id = ?`<br>• ParticipantID → `(e.paid_by = ? OR EXISTS (SELECT 1 FROM expense_shares x WHERE x.expense_id = e.id AND x.participant_id = ?))`<br>• PaidBy → `e.paid_by = ?`<br>• InvolvedID → `EXISTS (SELECT 1 FROM expense_shares x WHERE x.expense_id = e.id AND x.participant_id = ?)`<br>• MinCents != 0 → `e.amount_cents >= ?`; MaxCents != 0 → `e.amount_cents <= ?`<br>• From → `e.date >= ?`; To → `e.date <= ?`<br>Then ORDER BY. If `Limit > 0`: ` LIMIT ? OFFSET ?`. |
| `NextExpenseID(ctx) (int64, error)` | `SELECT coalesce(max(id), 0) + 1 FROM expenses` |
| `BalanceEntries(ctx) ([]domain.Entry, error)` | DatedBalanceEntries(zero), with the dates dropped. |
| `DatedBalanceEntries(ctx, to time.Time) ([]DatedEntry, error)` | `SELECT e.id, e.date, e.paid_by, e.amount_cents, x.participant_id, x.amount_cents FROM expenses e JOIN expense_shares x ON x.expense_id = e.id WHERE e.deleted_at IS NULL [AND e.date <= ?] ORDER BY e.date, e.id, x.participant_id`. Rows are grouped by e.id. Shares get only ParticipantID and AmountCents (Weight 0). `DatedEntry{Date; domain.Entry}`. |
| `Balances(ctx) (map[int64]int64, error)` | `domain.Balances(BalanceEntries)`. People with no entries are absent from the map. |

`expenseSelect`:
```sql
SELECT e.id, e.title, e.date, e.category_id, e.paid_by, e.notes, e.is_reimbursement,
	e.split_mode, e.amount_cents, e.original_amount_minor, e.original_currency, e.fx_rate, e.fx_source,
	e.recurring_id, e.created_at, e.updated_at, e.deleted_at, coalesce(c.name, ''), p.name
	FROM expenses e
	LEFT JOIN categories c ON c.id = e.category_id
	JOIN participants p ON p.id = e.paid_by
```
- `getExpense`: `expenseSelect + " WHERE e.id = ?"`.
- `queryExpenses`: scans the rows. A date parse error gives `"expense %d: date %q: %w"`. NullInt values become 0, and timestamps go through parseTime. It then calls `loadShares`.
- `loadShares`: chunks of **500** ids, `SELECT expense_id, participant_id, weight, amount_cents FROM expense_shares WHERE expense_id IN (…) ORDER BY expense_id, participant_id`. It fills both `Shares` and `Parts` ({pid, weight}).

`diffExpense(tx, old, in, shares)` builds `[]FieldChange` in this order and only for fields where old != new:
1. `"Art"`: kind(old.IsReimbursement) vs kind(in…), where kind gives `"Rückzahlung"` or `"Ausgabe"`.
2. `"Titel"`
3. `"Betrag"`: FormatCents.
4. `"Originalbetrag"`: `FormatMoney(OriginalAmountMinor, OriginalCurrency)`. **For EUR this repeats the Betrag change.**
5. `"Datum"`: domain.FormatDate (`02.01.2006`).
6. `"Kategorie"`: only if the CategoryID differs. Old is `cmp.Or(old.CategoryName, "–")`. New is `"–"` (U+2013) or `SELECT name FROM categories WHERE id = ?`.
7. `"Bezahlt von"`: names[old.PaidBy] vs names[in.PaidBy]. `participantNames` = `SELECT id, name FROM participants`.
8. `"Notiz"`
9. `"Kurs"`: rateSummary. `"–"` for EUR, else `"1 € = " + FormatRate(rate) + " " + upper(cur)` plus `" (EZB)"` if source is `ezb`, `" (<source>)"` for any other non-empty source, and nothing if empty.
10. `"Aufteilung"`: splitSummary = `mode.Label() + ": " + join("<name> <FormatCents(share)>", ", ")`.
11. If the split summaries are equal, field label = `{shares:"Anteile", percent:"Prozente", amount:"Beträge"}[in.SplitMode]`, defaulting to `"Gewichte"`. It compares weightSummary: `"<name> <w>"` joined `", "`, where percent → FormatBasisPoints, amount → `FormatMoney(weight, currency)` (old currency for old, new currency for new), and other modes → the decimal integer.

### activity.go
- `ActivityDetails{Title, AmountCents, Changes []FieldChange, Text}`: JSON `title,omitempty`, `amount_cents,omitempty`, `changes,omitempty`, `text,omitempty`.
- `FieldChange{Field, Old, New}`: JSON `field`, `old`, `new`.
- `Activity{ID; At; ActorID (0 = system); ActorName ("" for system); Action; ExpenseID; Details}`.
- `ActivityFilter{ExpenseID, ActorID, Action, Since, Until, BeforeID, Limit}`. A Limit ≤ 0 becomes 100.
- `ListActivity(ctx, f)`:
  - Base query: `SELECT a.id, a.at, a.actor_id, coalesce(p.name, ''), a.action, a.expense_id, a.details_json FROM activity a LEFT JOIN participants p ON p.id = a.actor_id`.
  - Conditions, joined with AND: `a.expense_id = ?`, `a.actor_id = ?`, `a.action = ?`, `a.at >= ?` (Since.UTC() in RFC3339), `a.at < ?` (Until likewise), `a.id < ?` (BeforeID).
  - Then `ORDER BY a.id DESC LIMIT ?`.
  - **Comparisons are text comparisons** on the RFC3339 UTC string.
  - `json.Unmarshal` errors on details are **ignored**.

### fx.go
- `LookupFXRate(ctx, currency, source string, date, notBefore time.Time) (domain.FXRate, error)`
  - `SELECT date, rate FROM fx_rates WHERE currency = ? AND source = ? AND date <= ? [AND date >= ?] ORDER BY date DESC LIMIT 1`.
  - Currency and source are used as given, with no uppercasing. No row gives ErrNotFound. The result carries Currency and Source as passed and the parsed Date.
- `SaveECBRates(ctx, []domain.FXRate)`
  - In a transaction with a prepared statement: `INSERT INTO fx_rates (date, currency, rate, source) VALUES (?, ?, ?, 'ezb') ON CONFLICT (currency, source, date) DO UPDATE SET rate = excluded.rate`.
  - It **silently skips** rows where `!(Rate > 0)` (this catches NaN), `IsInf`, or `!ValidCurrencyCode(Currency)` (no uppercasing; "bad" is skipped).
  - No activity.
- `SetManualFXRate(ctx, actorID, currency, date, rate)`
  - cur = upper(trim(currency)).
  - Validation order: `"EUR"` gives `"Für Euro braucht es keinen Kurs."`. An invalid code gives `"Bitte einen dreistelligen Währungscode angeben (z. B. USD)."`. A zero date gives `"Bitte ein Datum angeben."`. `!(rate>0) || Inf || rate > 1e9` gives `"Der Kurs muss größer als 0 sein."`.
  - `date = DateOf(date)`. Upsert with `'manuell'`.
  - Always logs `"Manueller Kurs für %s ab %s gespeichert: 1 € = %s %s"` (cur, FormatDate, FormatRate(rate), cur).
- `DeleteManualFXRate(ctx, actorID, currency, date)`
  - cur = upper(trim). `DELETE FROM fx_rates WHERE currency = ? AND date = ? AND source = 'manuell'`, then checkAffected (ErrNotFound when nothing was deleted).
  - Logs `"Manueller Kurs für %s ab %s gelöscht"`.
- `ListManualFXRates`: `SELECT currency, date, rate, source FROM fx_rates WHERE source = 'manuell' ORDER BY currency, date DESC`
- `LatestECBRates`: `SELECT currency, date, rate, source FROM fx_rates WHERE source = 'ezb' AND date = (SELECT max(date) FROM fx_rates WHERE source = 'ezb') ORDER BY currency`
- `ECBCacheStats` → `FXCacheStats{Count, Currencies int; From, To}`: `SELECT count(*), count(DISTINCT currency), min(date), max(date) FROM fx_rates WHERE source = 'ezb'`. Date parse errors are ignored.
- `ListFXCurrencies`: `SELECT DISTINCT currency FROM fx_rates ORDER BY currency` (both sources).
- `HasECBCurrency(ctx, cur)`: `SELECT count(*) FROM (SELECT 1 FROM fx_rates WHERE currency = ? AND source = 'ezb' LIMIT 1)`
- `RecentUsedFXRates(ctx, limit)` → `[]UsedFXRate{domain.FXRate (Date = expense date, Source = fx_source); ExpenseID; Title}`: `SELECT id, title, original_currency, date, fx_rate, fx_source FROM expenses WHERE deleted_at IS NULL AND original_currency <> 'EUR' ORDER BY date DESC, id DESC LIMIT ?`

### recurring.go
- `Recurring{ID; Template ExpenseInput; Frequency; StartDate; NextDate; Active bool; CreatedBy (0 = unknown); CreatedAt; UpdatedAt}`. Columns: `id, template_json, frequency, start_date, next_date, active, created_by, created_at, updated_at`.
- scanRecurring errors: `"recurring %d: template: %w"`, `"recurring %d: start_date %q: %w"`, `"recurring %d: next_date %q: %w"`.
- `templateOf(e)` = e.ExpenseInput with `Date = zero` and `RecurringID = 0`.
- `CreateRecurringFromExpense(ctx, actorID, expenseID, freq) (int64, error)`
  - `!freq.Valid()` gives `"Bitte eine Häufigkeit wählen."`.
  - In a transaction: getExpense. Missing or deleted gives ErrNotFound. `RecurringID != 0` gives `"Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe."`.
  - `next = domain.NextDate(freq, e.Date, e.Date)`.
  - `INSERT INTO recurring (template_json, frequency, start_date, next_date, active, created_by, created_at, updated_at) VALUES (?, ?, ?, ?, 1, ?, ?, ?)`, with `nullInt(actorID)` as created_by.
  - `UPDATE expenses SET recurring_id = ? WHERE id = ?`. The **expense's updated_at is not touched**.
  - Activity `recurring_created`, **expense_id = expenseID**, `{title, amount_cents, text: "„%s“ wiederholt sich jetzt %s."}` (title, freq.Adverb()).
- `GetRecurring(ctx, id)`: ErrNotFound when missing.
- `ListRecurring(ctx)`: `… ORDER BY active DESC, next_date, id`
- `DueRecurring(ctx, today)`: `… WHERE active = 1 AND next_date <= ? ORDER BY next_date, id`
- `ExpenseDatesLike(ctx, in, from, to) (map[time.Time]bool, error)`
  - Query: `SELECT DISTINCT date FROM expenses WHERE deleted_at IS NULL AND date BETWEEN ? AND ? AND title = ? AND paid_by = ? AND original_currency = ?` plus EUR: `AND amount_cents = ?` with args (…, "EUR", AmountCents), or foreign: `AND original_amount_minor = ?` with (…, upper(trim(cur)), OriginalAmountMinor).
  - The title is normalized with Fields/Join.
  - Map keys are `DateOf(t)`, which is 00:00 UTC.
- `SetRecurringNextDate(ctx, id, from, next)`: no transaction, no activity. `UPDATE recurring SET next_date = ?, updated_at = ? WHERE id = ? AND active = 1 AND next_date = ?`. 0 rows gives **ErrRecurringChanged**.
- `SetRecurringActive(ctx, actorID, id, active bool, today time.Time)`
  - In a transaction: getRecurring (ErrNotFound when missing). `next, verb := r.NextDate, "pausiert"`.
  - If active: verb `"fortgesetzt"`, and `if !r.Active && next.Before(today) { next = domain.NextDate(r.Frequency, r.StartDate, today.AddDate(0,0,-1)) }`.
  - `UPDATE recurring SET active = ?, next_date = ?, updated_at = ? WHERE id = ?`.
  - **Always logs** `ruleLabel(r) + " " + verb`, where `ruleLabel` = `fmt.Sprintf("Wiederholung „%s“ (%s)", r.Template.Title, strings.ToLower(r.Frequency.Label()))`. Example: `Wiederholung „Miete“ (monatlich) pausiert`.
- `UpdateRecurringTemplateFromLatest(ctx, actorID, id)`
  - In a transaction: getRecurring, then queryExpenses(tx, `expenseSelect + " WHERE e.recurring_id = ? AND e.deleted_at IS NULL ORDER BY e.date DESC, e.id DESC LIMIT 1"`). None gives **ErrNoInstance**.
  - `UPDATE recurring SET template_json = ?, updated_at = ? WHERE id = ?`.
  - Logs `ruleLabel(r) + ": Vorlage aus der letzten Ausgabe übernommen"`, using the old template title.
- `DeleteRecurring(ctx, actorID, id)`
  - In a transaction: getRecurring, then `DELETE FROM recurring WHERE id = ?`. **This relies on FK `ON DELETE SET NULL`** to clear `expenses.recurring_id`, so foreign_keys must be ON.
  - Activity `recurring_deleted`, expense_id NULL, `{title: tmpl.Title, amount_cents: tmpl.AmountCents, text: "Wiederholung von „%s“ beendet."}`.

### ynab.go / ynabstate.go
- `YNABConfig{ParticipantID; Token; PlanID (col budget_id); AccountID; StartDate (zero = NULL); Enabled; UpdatedAt; ConnectedAt}`
  - `Ready()` = `Enabled && Token != "" && PlanID != "" && AccountID != "" && !StartDate.IsZero()`.
  - Columns: `participant_id, token, budget_id, account_id, start_date, enabled, updated_at, connected_at`.
  - A non-empty start_date that fails to parse gives an error.
- `GetYNABConfig(ctx, pid)`: ErrNotFound when missing.
- `ListYNABConfigs(ctx)`: `… FROM ynab_config WHERE token != '' AND enabled = 1 AND participant_id IN (SELECT id FROM participants WHERE archived_at IS NULL) ORDER BY participant_id`
- `SetYNABToken(ctx, pid, token, reachable func(planID string) bool) (targetReset bool, err error)`
  - In a transaction: old = getYNABConfig (ErrNotFound tolerated). Then:
    ```sql
    INSERT INTO ynab_config (participant_id, token, enabled, updated_at) VALUES (?, ?, ?, ?)
    ON CONFLICT (participant_id) DO UPDATE SET
      token = excluded.token, enabled = excluded.enabled, updated_at = excluded.updated_at,
      token_invalid = 0, error = '', retry_at = NULL, backoff_seconds = 0
    ```
    with enabled = `token != ""` (bool).
  - `targetReset = token != "" && old.PlanID != "" && reachable != nil && !reachable(old.PlanID)`. **`reachable` (a network call) runs inside the write transaction.** If targetReset: `setYNABTarget(tx, pid, "", "", old.StartDate)`.
  - Log text, with the person as actor: `token == ""` gives `"YNAB-Verbindung getrennt"`; targetReset gives `"YNAB-Token ersetzt (Plan und Konto zurückgesetzt)"`; `old.Token != ""` gives `"YNAB-Token ersetzt"`; otherwise `"YNAB verbunden (Token gesetzt)"`.
- `YNABTarget{PlanID, AccountID, PlanName, AccountName string; Start time.Time}`
- `SetYNABTarget(ctx, pid, t)`
  - In a transaction: old = setYNABTarget(...). A missing config gives ErrNotFound.
  - If plan or account changed: log `"YNAB: Konto „%s“ im Plan „%s“ gewählt, Startdatum %s"` (cmp.Or(AccountName, AccountID), cmp.Or(PlanName, PlanID), FormatDate(Start), which is "" if zero).
  - Else if `optionalDate(t.Start) != optionalDate(old.StartDate)`: log `"YNAB: Startdatum %s → %s"` (cmp.Or(FormatDate(old), "–"), FormatDate(new)).
  - Otherwise no log, **but the UPDATE still ran** (updated_at changes).
- `setYNABTarget(tx, pid, plan, account, start)`
  - On a plan or account change: `UPDATE ynab_sync SET ynab_txn_id = '', synced_hash = ?, synced_at = NULL, last_error = '' WHERE participant_id = ?` with `"retarget"`, and connected = now. Otherwise connected = nil.
  - Then: `UPDATE ynab_config SET budget_id = ?, account_id = ?, start_date = ?, updated_at = ?, connected_at = coalesce(?, connected_at) WHERE participant_id = ?`.
  - `optionalDate(t)` = NULL if zero, else `formatDate`.
- `EnsureYNABConnectedAt(ctx, pid) (time.Time, error)`: `UPDATE ynab_config SET connected_at = coalesce(connected_at, ?) WHERE participant_id = ? RETURNING connected_at`. No row gives ErrNotFound. This needs RETURNING (SQLite ≥ 3.35). It runs without an explicit transaction.
- `YNABStatus{LastRun, LastSync time.Time; Summary, Error string; TokenInvalid bool; RetryAt time.Time; Backoff time.Duration}`. Columns: `last_run, last_sync, summary, error, token_invalid, retry_at, backoff_seconds`.
- `GetYNABStatus(ctx, pid)`: ErrNotFound when missing. `Backoff = backoff_seconds * time.Second`.
- `SetYNABStatus(ctx, pid, st)`: `UPDATE ynab_config SET last_run = ?, last_sync = ?, summary = ?, error = ?, token_invalid = ?, retry_at = ?, backoff_seconds = ? WHERE participant_id = ?`. `statusTime(t)` = NULL if zero, else `t.UTC().Format(time.RFC3339Nano)`. Backoff = `int64(st.Backoff / time.Second)` (truncating). 0 rows gives ErrNotFound. Test: the status round-trips exactly, including nanoseconds.
- `YNABCategoryMap(ctx, pid) (map[int64]string, error)`: `SELECT category_id, ynab_category_id FROM ynab_category_map WHERE participant_id = ?`
- `SetYNABCategoryMap(ctx, pid, m map[int64]string, ynabNames map[string]string)`
  - In a transaction: old = current map. `DELETE FROM ynab_category_map WHERE participant_id = ?`.
  - For each (cat, ynab) in m, skipping empty values (Go map iteration order is random): `SELECT count(*) FROM categories WHERE id = ?`. 0 gives `invalid("Unbekannte Kategorie.")`. Then INSERT.
  - `mappingChanges`: iterates over **all** categories, archived included, `ORDER BY position, name COLLATE NOCASE, id`. For each where `old[id] != now[id]` (a missing key counts as ""), the part is `c.Name + " → " + ynabName(n)`, plus `" (vorher " + ynabName(o) + ")"` if o != "". `ynabName("")` = `"unkategorisiert"`. An unknown id becomes `cmp.Or(ynabNames[id], "(nicht mehr vorhanden)")`. Parts are joined with `", "`.
  - If the text is non-empty, log `"YNAB: Kategorie-Zuordnung geändert (" + text + ")"`.
- `YNABSync{ExpenseID, ParticipantID, TxnID, Hash string; SyncedAt; LastError}`. `const YNABHashRetarget = "retarget"`.
- `ListYNABSync(ctx, pid)`: `SELECT expense_id, participant_id, ynab_txn_id, synced_hash, synced_at, last_error FROM ynab_sync WHERE participant_id = ? ORDER BY expense_id`
- `PutYNABSync(ctx, rows...)`: does nothing for 0 rows. Otherwise, in a transaction, per row: `INSERT INTO ynab_sync (expense_id, participant_id, ynab_txn_id, synced_hash, synced_at, last_error) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (expense_id, participant_id) DO UPDATE SET ynab_txn_id = excluded.ynab_txn_id, synced_hash = excluded.synced_hash, synced_at = excluded.synced_at, last_error = excluded.last_error`. synced_at is RFC3339 (seconds) UTC, or NULL.
- `DeleteYNABSync(ctx, pid, expenseIDs...)`: does nothing for 0 ids. Otherwise, in a transaction, per id: `DELETE FROM ynab_sync WHERE participant_id = ? AND expense_id = ?`
- `YNABSyncSummary(ctx, pid) (synced int, problems []YNABSyncProblem{ExpenseID, Title, Date, Error}, err)`:
  - `SELECT count(*) FROM ynab_sync WHERE participant_id = ? AND ynab_txn_id != ''`
  - then `SELECT y.expense_id, e.title, e.date, y.last_error FROM ynab_sync y JOIN expenses e ON e.id = y.expense_id WHERE y.participant_id = ? AND y.last_error != '' ORDER BY e.date DESC, e.id DESC`. Deleted expenses are included.

### mcp.go: stats, schema, SQL sandbox
- `MCPTables = ["participants","categories","expenses","expense_shares","recurring","activity","fx_rates","settings"]`. This is an allowlist, and the YNAB tables are excluded.
- `mcpRowFilter = {"settings": "key NOT LIKE 'ynab%'"}`.
- Consts: `SQLMaxRows = 500`, `SQLTimeout = 5s` (total, including the copy), `sqlMaxCellRunes = 2000`, `sqlMaxResult = 8<<20` (8388608, used for `SQLITE_LIMIT_LENGTH`).
- `QueryResult{Columns []string; Rows [][]any (int64|float64|string|nil); Truncated bool}`. `SchemaObject{Type ("table"|"index"), Name, SQL}`.
- `MCPSchema(ctx)` = `schemaObjects(db, "main")`: `SELECT type, name, tbl_name, sql FROM main.sqlite_schema WHERE type IN ('table', 'index') AND sql IS NOT NULL ORDER BY type DESC, rowid`, filtered to `tbl_name ∈ MCPTables`. Tables come first, then indexes, and autoindexes are excluded because their sql is NULL.
- `DataOverview{Expenses, Reimbursements, WithoutCategory int64; FirstDate, LastDate; ActivityActions []string}`
- `MCPOverview(ctx)`:
  - `SELECT coalesce(sum(is_reimbursement = 0), 0), coalesce(sum(is_reimbursement = 1), 0), coalesce(sum(is_reimbursement = 0 AND category_id IS NULL), 0), min(date), max(date) FROM expenses WHERE deleted_at IS NULL`
  - then `SELECT DISTINCT action FROM activity ORDER BY action`
- `ReadOnlyQuery(ctx, query) (QueryResult, error)`
  - `body = checkSelect(query)`, then a context with a 5 s timeout, then `sandbox(ctx)`, then `runWrapped(ctx, conn, body)`.
  - Errors are mapped by `sandboxErr`:
    - On deadline: `invalid("The query was aborted after %d s. Please narrow it down (WHERE, LIMIT) or simplify it.", 5)`.
    - A ValidationError passes through.
    - `*sqlite.Error` with code SQLITE_TOOBIG: `"The result is too large. Please query fewer columns/rows."`.
    - Other sqlite errors: `"SQL error: " + TrimPrefix(se.Error(), "SQL logic error: ")`. **[verified]** modernc's `Error()` format is `"SQL logic error: no such table: doesnotexist (1)"`, so the user sees `SQL error: no such table: doesnotexist (1)`. For other classes it is for example `"constraint failed: UNIQUE constraint failed: t.a (2067)"`.
    - Anything else is a plain error.
- `sandbox(ctx)`
  - A path of `":memory:"` or `""` gives `invalid("sql_query needs a database file (not available with :memory:).")`.
  - abs = `filepath.Abs(path)`. Opens a new `:memory:` DB with MaxOpenConns(1) and takes one Conn, then calls `fillSandbox`.
- `fillSandbox(conn, abs)`:
  1. `ATTACH DATABASE ? AS src` with `(&url.URL{Scheme:"file", Path: filepath.ToSlash(abs), RawQuery:"mode=ro"}).String()`. **[verified]** This gives `file:///tmp/a%20b/x%23.db?mode=ro` (percent-escaped). Error: `"open database read-only: %w"`.
  2. `BEGIN`, a plain deferred read transaction.
  3. `schemaObjects(conn, "src")`. For each object in order (tables first): execute its `SQL` verbatim (this creates the table or index in main). For tables: `INSERT INTO main."<name>" SELECT * FROM src."<name>"`, plus ` WHERE key NOT LIKE 'ynab%'` for settings. Errors: `"sandbox %s: %w"`.
  4. `COMMIT`. On error: `ROLLBACK` with a background context.
  5. `DETACH DATABASE src`.
  6. `sqlite3_limit(SQLITE_LIMIT_ATTACHED, 0)`, `sqlite3_limit(SQLITE_LIMIT_LENGTH, 8388608)`, `PRAGMA query_only = ON`.
- `runWrapped(ctx, conn, body)`
  - Prepares `body` to get column names via modernc `ColumnInfo`. **[read]** This is `sqlite3_prepare_v2` of the query (only the first statement), then `sqlite3_column_count` and `sqlite3_column_name`, then finalize. An empty or comment-only query gives `nil` columns.
  - 0 columns gives `invalid("The query returns no columns. Only SELECT or WITH … SELECT is allowed.")`.
  - Aliases are `c0…cN`. Each cell expression is `CASE typeof(cI) WHEN 'blob' THEN '[BLOB, ' || length(cI) || ' Bytes]' WHEN 'text' THEN substr(cI, 1, 2000) ELSE cI END`.
  - The final query:
    ```
    WITH mcp_u(c0, c1, …) AS (
    <body>
    )
    SELECT count(*), json_group_array(json_array(<cells>)) FROM (SELECT * FROM mcp_u LIMIT 501)
    ```
  - It decodes the JSON with UseNumber. If there are more than 500 rows, it truncates to 500 and sets `Truncated`. Each `json.Number` becomes int64 if `Int64()` parses, else float64. **SQLite renders REAL 1.0 as `1.0`, which fails Int64 and becomes float64 1.** Null rows become `[][]any{}`.
  - The whole result is produced in one `sqlite3_step`. modernc calls `sqlite3_interrupt` when ctx is done.
- `checkSelect(query) (string, error)`: a lexical scan, shown below. Note that `"SELECT 1; 'x'"` is accepted (a quoted token after `;` is not checked) and returns `"SELECT 1"`.
  ```go
  if strings.IndexByte(query, 0) >= 0 { return "", invalid("The query contains a NUL character.") }
  end := len(query); first := ""
  for i := 0; i < len(query); {
      c := query[i]
      switch {
      case c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v': i++
      case c == '-' && i+1 < len(query) && query[i+1] == '-': /* skip to after '\n' or end */
      case c == '/' && i+1 < len(query) && query[i+1] == '*': /* skip to after "*/" or end */
      case c == '\'' || c == '"' || c == '`': i = skipQuoted(query, i, c, c)
      case c == '[': i = skipQuoted(query, i, '[', ']')
      case c == ';': if end == len(query) { end = i }; i++
      default:
          if end != len(query) { return "", invalid("Please send only a single query (no second statement after \";\").") }
          if first == "" { j := i; for j < len(query) && (isLetter(query[j]) || query[j] == '_') { j++ }
              first = strings.ToUpper(query[i:j]); if first == "" { first = string(c) } }
          i++
      }
  }
  if first != "SELECT" && first != "WITH" { return "", invalid("Only a single read-only query is allowed (SELECT … or WITH … SELECT …).") }
  return query[:end], nil
  // skipQuoted: doubled close char = escaped (only when open == close); unterminated → len(s)
  ```
- Stats:
  - consts: `StatsByCategory="category"`, `StatsByTitle="title"`, `StatsByYear="year"`, `StatsByMonth="month"`, `StatsByWeek="week"`, `StatsByPerson="person"`, `StatsByCategoryMonth="category_month"`, `NoCategory = "No category"` (English).
  - `statsPeriod`: year → `substr(e.date, 1, 4)`; month and category_month → `substr(e.date, 1, 7)`; week → **`strftime('%G-W%V', e.date)`**.
  - `StatsFilter{GroupBy; From, To; ParticipantID; CategoryID; WithoutCategory; AnyText []string}`. `StatRow{Category, Title, Period, Person string; Count, AmountCents, PaidCents int64}`.
- `Stats(ctx, f)`:
  - where = `e.deleted_at IS NULL`, `e.is_reimbursement = 0`, then `e.date >= ?` (From), `e.date <= ?` (To), then `e.category_id IS NULL` (WithoutCategory) or `e.category_id = ?`, then textCond(AnyText).
  - GroupBy person goes to statsByPerson.
  - Otherwise `from = "expenses e LEFT JOIN categories c ON c.id = e.category_id"` and amount = `e.amount_cents`. If ParticipantID is set: `+ " JOIN expense_shares x ON x.expense_id = e.id AND x.participant_id = ?"`, with the **arg prepended**, and amount = `x.amount_cents`.
  - `cat = "coalesce(c.name, 'No category')"`. sel, group and order per grouping:
    - category: `cat+", ''"`, `cat`, `"4 DESC, 1"`
    - title: `"max(e.title), ''"`, `"zipfelkasse_fold(e.title)"`, `"4 DESC, 1"`
    - year/month/week: `"'', "+period`, `period`, `"2"`
    - category_month: `cat+", "+period`, `cat+", "+period`, `"2, 4 DESC, 1"`
    - unknown: `invalid("Unknown grouping %q.", f.GroupBy)`
  - SQL: `fmt.Sprintf("SELECT %s, count(*), sum(%s) FROM %s WHERE %s GROUP BY %s ORDER BY %s", sel, amount, from, where…, group, order)`. Scans label, period, count, sum. For title grouping label → Title, else label → Category.
  - Tests (`TestStats`) give expected strings, for example category: `Lebensmittel 2/4000; Restaurant 1/4000; No category 1/500` (the 4000 tie is broken by label, BINARY collation). Week: `2026-W33, 2026-W36, 2026-W37`.
- `statsByPerson(ctx, where, args, pid)`:
  ```sql
  SELECT p.name,
    (SELECT count(*) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id WHERE x.participant_id = p.id AND <cond>),
    (SELECT coalesce(sum(x.amount_cents), 0) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id WHERE x.participant_id = p.id AND <cond>),
    (SELECT coalesce(sum(e.amount_cents), 0) FROM expenses e WHERE e.paid_by = p.id AND <cond>)
    FROM participants p WHERE 1 = 1[ AND p.id = ?]
  ```
  - args = cond args ×3, then pid.
  - Rows with Count==0 && PaidCents==0 are skipped. Archived people are included.
  - Go-side sort: **`slices.SortStableFunc`** by AmountCents DESC, then `strings.Compare(strings.ToLower(a.Person), strings.ToLower(b.Person))`.
- Period helpers:
  - `IsTimeGrouping(g)`: year, month or week.
  - `PeriodOf(g, day)`: year `"2006"`, week `fmt.Sprintf("%d-W%02d", isoYear, isoWeek)`, default `"2006-01"`.
  - `FillPeriods(rows, g, first, last)`: no-op if not a time grouping or `last < first`. Otherwise every period of `Periods(...)` is taken from rows or zero-filled, rows outside the range are appended, and everything is **`SortStableFunc` by Period (string compare)**.
  - `Periods(g, first, last)`: from `periodStart(first)` step by `nextPeriod` until `p >= end` (string compare). nil if last < first.
  - `PeriodEnd(g, day)` = `nextPeriod(periodStart(day)) - 1 day`.
  - `PeriodStart(g, period)`: year uses `Sscanf "%4d"`, week uses `"%4d-W%2d"` and returns the Monday of week 1 (from Jan 4) + 7·(n−1) days, month uses `"%4d-%2d"`. A parse failure gives the zero time. Note that Sscanf ignores trailing input.
  - `ShiftPeriodYear(p, years)`: `Atoi(p[:min(4,len)])`. On error it returns p unchanged (so `""` stays `""`). For `-W53`, if the target year's Dec 28 ISO week is < 53 it returns `"%04d-W52"`. Otherwise `"%04d" + p[4:]`.
  - `ShiftDateYear(d, years)`: Feb 29 becomes Feb 28 in non-leap years. Time-of-day and location are kept.
  - `periodStart`: year Jan 1, week Monday (`-(weekday+6)%7` days), month day 1, all UTC. `nextPeriod`: AddDate +1y, +7d or +1m.

### backup.go
See §7.

---

## 5. Domain

### money.go
- Amounts are `int64` in the smallest unit. `MaxAmountCents int64 = 1_000_000_000_000` (10 billion €).
- `ValidationError{Msg}`. `invalid(fmt, args…)` uses `fmt.Sprintf`, **so `%%` in messages becomes `%`**.
- Formatting:
  - `FormatCents(c)` = `formatFixed(c, 2, true) + " €"`. Examples: `0 → "0,00 €"`, `100000 → "1.000,00 €"`, `123456789 → "1.234.567,89 €"`, `-1234 → "-12,34 €"`, `-5 → "-0,05 €"`.
  - `FormatCentsInput(c)` = `formatFixed(c, 2, false)`. Examples: `123456 → "1234,56"`, `-50 → "-0,50"`.
  - `FormatMoney(minor, cur)`: EUR or "" (IsEUR) → FormatCents. Otherwise cur = upper(trim), and the result is `formatFixed(minor, CurrencyDecimals(cur), true) + " " + cur`. Examples: `(123456,"JPY") → "123.456 JPY"`, `(1234,"kwd") → "1,234 KWD"`.
  - `FormatBasisPoints(bp)` = `formatFixed(bp, 2, false) + " %"`. Example: `3333 → "33,33 %"`.
  - `FormatDecimal(v, decimals, sep byte)` = `formatSep(v, decimals, sep, false)`. Examples: `(-5,2,'.') → "-0.05"`, `(7,0,'.') → "7"`, `(12345,3,'.') → "12.345"`.
  - `FormatMinorInput(minor, cur)` = `FormatDecimal(minor, CurrencyDecimals(cur), ',')`.
  - `FormatRate(rate)` = `""` if `!(rate > 0)`, else `strings.Replace(strconv.FormatFloat(rate, 'f', -1, 64), ".", ",", 1)`. This is the shortest round-trip decimal with **no exponent ever**. Examples: `1.0876 → "1,0876"`, `17000 → "17000"`, `0.856 → "0,856"`.

  ```go
  func formatSep(v int64, decimals int, sep byte, group bool) string {
      neg := v < 0
      u := uint64(v)
      if neg { u = uint64(-v) }          // MinInt64 safe via uint64 wrap
      s := strconv.FormatUint(u, 10)
      if len(s) <= decimals { s = strings.Repeat("0", decimals-len(s)+1) + s }
      intPart, frac := s[:len(s)-decimals], s[len(s)-decimals:]
      if group && len(intPart) > 3 {
          first := len(intPart) % 3
          // write intPart[:first] (if >0), then groups of 3 separated by '.'
      }
      out := intPart
      if decimals > 0 { out += string(sep) + frac }
      if neg { out = "-" + out }
      return out
  }
  ```
- Parsing (exact; port line by line):
  ```go
  func ParseCents(s string) (int64, error) { return ParseMinor(s, 2) }

  func ParseBasisPoints(s string) (int64, error) {
      s = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(s), "%"))
      v, err := parseFixed(s, 2)
      if err != nil { return 0, invalid("Ungültige Prozentangabe „%s“.", strings.TrimSpace(s)) }
      return v, nil
  }

  func ParseMinor(s string, decimals int) (int64, error) {
      s = strings.TrimSpace(s)
      s = strings.TrimSuffix(s, "€")    // only a trailing €, only once
      s = strings.TrimSpace(s)
      if s == "" { return 0, invalid("Bitte einen Betrag eingeben.") }
      return parseFixed(s, decimals)
  }

  func parseFixed(s string, decimals int) (int64, error) {
      s = strings.ReplaceAll(s, " ", "")
      s = strings.ReplaceAll(s, " ", "")   // NBSP (bytes C2 A0) – NOT U+202F
      if s == "" { return 0, invalid("Bitte einen Betrag eingeben.") }
      neg, intPart, frac, ok := splitNumber(s, decimals < 3)
      if !ok { return 0, invalid("Ungültiger Betrag „%s“.", s) }
      for len(frac) > decimals && frac[len(frac)-1] == '0' { frac = frac[:len(frac)-1] }
      if len(frac) > decimals {
          if decimals == 0 { return 0, invalid("Dieser Betrag darf keine Nachkommastellen haben.") }
          return 0, invalid("Höchstens %d Nachkommastellen erlaubt.", decimals)
      }
      if len(intPart) > 15 { return 0, invalid("Der Betrag ist zu groß.") }
      digits := intPart + frac + strings.Repeat("0", decimals-len(frac))
      v, err := strconv.ParseInt(digits, 10, 64)
      if err != nil { return 0, invalid("Ungültiger Betrag „%s“.", s) }
      if neg { v = -v }
      return v, nil
  }

  func splitNumber(s string, dotThousands bool) (neg bool, intPart, frac string, ok bool) {
      if s == "" { return false, "", "", false }
      switch s[0] { case '-': neg, s = true, s[1:]; case '+': s = s[1:] }
      if s == "" { return false, "", "", false }
      for _, r := range s { if (r < '0' || r > '9') && r != '.' && r != ',' { return false, "", "", false } }
      intPart = s
      lastDot, lastComma := strings.LastIndexByte(s, '.'), strings.LastIndexByte(s, ',')
      dots, commas := strings.Count(s, "."), strings.Count(s, ",")
      var thousands byte
      switch {
      case dots > 0 && commas > 0:
          dec := max(lastDot, lastComma)
          if s[dec] == '.' { thousands = ','; if dots > 1 { return false, "", "", false } } else {
                             thousands = '.'; if commas > 1 { return false, "", "", false } }
          intPart, frac = s[:dec], s[dec+1:]
      case dots+commas == 0:
      case dots+commas > 1:
          thousands = '.'; if commas > 0 { thousands = ',' }
      default: // exactly one separator
          pos := max(lastDot, lastComma)
          after := len(s) - pos - 1
          if s[pos] == '.' && after == 3 && dotThousands && strings.Trim(s[:pos], "0") != "" {
              thousands = '.'
          } else {
              intPart, frac = s[:pos], s[pos+1:]
              if frac == "" { return false, "", "", false }
          }
      }
      if strings.ContainsAny(frac, ".,") { return false, "", "", false }
      if thousands != 0 {
          groups := strings.Split(intPart, string(thousands))
          if len(groups[0]) == 0 || len(groups[0]) > 3 { return false, "", "", false }
          for _, g := range groups[1:] { if len(g) != 3 { return false, "", "", false } }
          intPart = strings.Join(groups, "")
      }
      if strings.ContainsAny(intPart, ".,") { return false, "", "", false }
      if intPart == "" { intPart = "0" }
      return neg, intPart, frac, true
  }
  ```
  Accepted inputs and their results, from the tests:
  - ParseCents:
    - `"12,34"`, `"12.34"` → 1234
    - `"12"` → 1200
    - `"12,3"` → 1230
    - `"12.5"` → 1250
    - `",50"` → 50
    - `"0"` → 0
    - `" 12,34 € "`, `"12,34€"` → 1234
    - `"1.234,56"`, `"1,234.56"` → 123456
    - `"1.234"` → 123400 (dot + 3 digits = thousands)
    - `"1.234.567"` → 123456700
    - `"1.234.567,89"` → 123456789
    - `"0.50"` → 50
    - `"-12,34"` → −1234 (**negatives are accepted by the parser**)
    - `"+3"` → 300
  - ParseCents errors: `"0.123"` (leading 0, so the dot is decimal, which gives too many decimals), `""`, `"   "`, `"abc"`, `"12,345"`, `"1,2,3"`, `"12.34.5"`, `"1.23,4"`, `"12,"`, `"-"`, `"99999999999999999999"`.
  - ParseMinor(s, 0):
    - `"1500"` → 1500, `"1.500"` → 1500
    - `"15,5"` → error
    - `"0.500"` → error (0.5 yen)
    - `"1200,00"` → 1200, `"1.200,00"` → 1200 (superfluous zeros are OK)
    - `"1200,50"` → error
  - ParseMinor(s, 3): `"1,234"` → 1234, `"1.5"` → 1500, `"0.123"` → 123.
  - ParseMinor(s, 2): `"12,340"` → 1234, `"12,345"` → error.
  - ParseBasisPoints: `"50"` → 5000, `"33,33"` → 3333, `"33.34"` → 3334, `"100"` → 10000, `"12,5 %"` → 1250.
  - With decimals ≥ 3, `dotThousands = false`, so a single dot is always decimal.
- `ParseRate(s) (float64, error)`:
  ```go
  s = strings.ReplaceAll(strings.TrimSpace(s), " ", ""); s = strings.ReplaceAll(s, " ", "")
  bad := invalid("Ungültiger Wechselkurs „%s“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €).", s)
  neg, intPart, frac, ok := splitNumber(s, true)
  if !ok || neg || len(intPart) > 12 || len(frac) > 12 { return 0, bad }
  v, err := strconv.ParseFloat(intPart+"."+frac+"0", 64)
  if err != nil || !(v > 0) || math.IsInf(v, 0) { return 0, bad }
  ```
  - OK: `"1,0857"`, `"1.0857"` → 1.0857; `"17000"`; `"17.000,5"`, `"17,000.5"` → 17000.5; `"17.000"` → 17000; `"1.085"` → 1085; `"0.856"`, `"00.856"` → 0.856; `"0.8565"`; `"1.234.567,25"`; `" 0,8653 "`; `"162,45"`; `"1,5"`.
  - Errors: `""`, `"0"`, `"0,0"`, `"-1,2"`, `"abc"`, `"1,2,3"`, `"1.2.3"`, `"17.00.0"`, `"1e5"`, `"NaN"`, `"Inf"`, `"1,"`, `",5x"`, `"0.000"`.
- `ValidCurrencyCode(s)`: exactly 3 **bytes**, each `A`–`Z`.
- `IsEUR(c)`: `upper(trim(c))` is `""` or `"EUR"`.
- `CurrencyDecimals(c)`: `strings.ToUpper(c)` with **no trim**.
  - 0 decimals: JPY, KRW, ISK, HUF, CLP, VND, XAF, XOF, PYG, UGX, IDR.
  - 3 decimals: KWD, BHD, OMR, JOD, TND, LYD, IQD.
  - Everything else: 2.
- **Currency conversion (rounding = half away from zero):**
  ```go
  func ToEURCents(minor int64, currency string, rate float64) int64 {
      if rate <= 0 || math.IsNaN(rate) || math.IsInf(rate, 0) { return 0 }
      scale := math.Pow10(CurrencyDecimals(currency))
      eur := float64(minor) / scale / rate * 100     // exact operation order matters
      return int64(math.Round(eur))                   // math.Round = half away from zero
  }
  ```
  Tests: `(10000,"USD",1.0823)` → 9240; `(1000,"JPY",160.5)` → 623; `(1234,"EUR",1)` → 1234; `(-10000,"USD",1.0823)` → −9240; rate 0 → 0.

### fx.go (domain)
`FXRate{Currency; Date (00:00 UTC); Rate float64; Source}`. Consts: `FXSourceECB="ezb"`, `FXSourceManual="manuell"`, `FXSourceFixed="fest"` (EUR itself, rate 1).

### split.go
- `SplitMode` string values: `equal`, `shares`, `percent`, `amount`. `SplitModes` order: equal, shares, percent, amount.
- `Valid()`. `Label()`: `"Gleichmäßig"`, `"Nach Anteilen"`, `"Nach Prozent"`, `"Nach Beträgen"`. An unknown mode gives the raw string.
- `maxShareWeight = 1_000_000`.
- `ParseWeight(mode, currency, v)`:
  - shares: `strconv.ParseInt(TrimSpace(v), 10, 64)`. It accepts `+5` and `-3`. On error: `"Anteile müssen ganze Zahlen sein („%s“)."` with the **untrimmed** v.
  - percent: ParseBasisPoints.
  - amount: `ParseMinor(v, CurrencyDecimals(currency))`.
  - equal: 0.
- `WeightDecimals(mode, cur)`: percent 2, amount CurrencyDecimals(cur), otherwise 0.
- `Part{ParticipantID, Weight}` with JSON `participant_id`, `weight`. `Share{ParticipantID, Weight, AmountCents}` with JSON `participant_id`, `weight`, `amount_cents`.
- `Split(mode, total, parts, rotation)` = `SplitConverted(mode, total, total, "EUR", parts, rotation)`.

```go
func SplitConverted(mode SplitMode, total, original int64, currency string, parts []Part, rotation int64) ([]Share, error) {
	if !mode.Valid() { return nil, invalid("Unbekannte Aufteilungsart „%s“.", mode) }
	if total <= 0 { return nil, invalid("Der Betrag muss größer als 0 sein.") }
	if total > MaxAmountCents { return nil, invalid("Der Betrag ist zu groß.") }
	if len(parts) == 0 { return nil, invalid("Mindestens eine Person muss an der Ausgabe beteiligt sein.") }
	ps := slices.Clone(parts)
	slices.SortFunc(ps, func(a, b Part) int { return cmp.Compare(a.ParticipantID, b.ParticipantID) })
	for i, p := range ps {
		if p.ParticipantID <= 0 { return nil, invalid("Ungültige Person in der Aufteilung.") }
		if i > 0 && ps[i-1].ParticipantID == p.ParticipantID { return nil, invalid("Eine Person ist in der Aufteilung doppelt aufgeführt.") }
		if mode != SplitEqual && p.Weight < 0 { return nil, invalid("Anteile dürfen nicht negativ sein.") }
	}
	var sum int64
	switch mode {
	case SplitEqual:
		for i := range ps { ps[i].Weight = 1 }
		sum = int64(len(ps))
	case SplitShares:
		for _, p := range ps {
			if p.Weight > maxShareWeight { return nil, invalid("Anteile dürfen höchstens %d sein.", maxShareWeight) }
			sum += p.Weight
		}
		if sum <= 0 { return nil, invalid("Die Summe der Anteile muss größer als 0 sein.") }
	case SplitPercent:
		for _, p := range ps {
			if p.Weight > 10000 { return nil, invalid("Die Prozente müssen zusammen 100 %% ergeben.") }   // → "100 % ergeben."
			sum += p.Weight
		}
		if sum != 10000 { return nil, invalid("Die Prozente müssen zusammen 100 %% ergeben (aktuell %s).", FormatBasisPoints(sum)) }
	case SplitAmount:
		for _, p := range ps {
			s, carry := bits.Add64(uint64(sum), uint64(p.Weight), 0)
			if carry != 0 || s > 1<<63-1 { return nil, invalid("Der Betrag ist zu groß.") }
			sum = int64(s)
		}
		if sum != original { return nil, invalid("Die Beträge müssen zusammen %s ergeben (aktuell %s).", FormatMoney(original, currency), FormatMoney(sum, currency)) }
	}
	weights := ...ps[i].Weight
	out := make([]Share, len(ps))
	for i, c := range Allocate(total, weights, rotation) {
		out[i] = Share{ParticipantID: ps[i].ParticipantID, Weight: ps[i].Weight, AmountCents: c}
	}
	return out, nil
}
```
The result is sorted by ParticipantID and sums exactly to `total`. Equal weights are stored as 1. For SplitAmount with EUR, the shares equal the weights exactly.

**Allocate**, the remainder-cent distribution (port exactly):
```go
func Allocate(total int64, weights []int64, rotation int64) []int64 {
	var sum uint64
	for _, w := range weights { sum += uint64(w) }
	out := make([]int64, len(weights))
	if sum == 0 { return out }
	rems := make([]uint64, len(weights))
	var allocated int64
	for i, w := range weights {
		hi, lo := bits.Mul64(uint64(total), uint64(w))     // 128-bit product
		q, r := bits.Div64(hi, lo, sum)                     // floor(total*w / sum), remainder
		out[i], rems[i] = int64(q), r
		allocated += out[i]
	}
	order := []int{0..n-1}
	// Largest remainder first; ties stay in index order and are then rotated by rotation.
	slices.SortStableFunc(order, func(a, b int) int { return cmp.Compare(rems[b], rems[a]) })
	for i := 0; i < len(order); {
		j := i + 1
		for j < len(order) && rems[order[j]] == rems[order[i]] { j++ }
		n := int64(j - i)
		rotate(order[i:j], int((rotation%n+n)%n))   // left-rotate the tie group by k
		i = j
	}
	for k := 0; allocated < total; k++ { out[order[k]]++; allocated++ }
	return out
}
func rotate(s []int, k int) { slices.Reverse(s[:k]); slices.Reverse(s[k:]); slices.Reverse(s) } // s[k] ends up first
```
The algorithm, step by step:
1. Floor shares are computed with 128-bit precision.
2. Indexes are stably sorted by remainder descending, so ties stay in ascending index order, which is participant-ID order.
3. **Each** tie group (equal remainder) is left-rotated by `((rotation mod n) + n) mod n`.
4. The leftover cents (at most 1 per entry) go along this order.

`rotation` is the **expense ID**. Previews use `NextExpenseID`. Migration 4 uses rotation 0, and so does normalize's validation call (its cents are discarded).

Test cases for Allocate:
- `(667,[600,400],0)` → `[400,267]`
- `(100,[1,1,1],0)` → `[34,33,33]`
- `(100,[1,1,1],4)` → `[33,34,33]`
- `(200,[1,1,1],1)` → `[66,67,67]`
- `(100,[1,1,1],-1)` → `[33,33,34]`
- `(100,[2,1,1,0],1)` → `[50,25,25,0]`
- `(909,[333,333,334],0)` → `[303,303,303]`
- `(1000,[250,750],3)` → `[250,750]`
- `(5,[0,0],0)` → `[0,0]`
- `(1e12,[999_999_999_999_999,1],0)` → `[1e12,0]`
- `(1e12,[1e14,1e14],1)` → `[5e11,5e11]`

Split test cases:
- equal 1000 among {3,1,2}, rot 0 → {1:334, 2:333, 3:333}
- equal 1001 → {1:334, 2:334, 3:333}
- equal 1 among 3 → {1:1, 2:0, 3:0}
- shares 1000 [1:1, 2:2] → {333, 667}
- percent 101 50/50 → {51, 50}
- percent 1999 70/30 → {1399, 600}
- Rotation: 1001 between {1,2} with rot 10 → {501, 500}; rot 11 → {500, 501}. Three people with rot 0/1/2/3 → the extra cent goes to idx 0/1/2/0. rot −1 → idx 2. 1001 with rot 2 → {1:334, 2:333, 3:334}. shares 5 [2,1,1] rot 1 → {3,1,1} (the largest remainder wins). shares 6 [2,1,1] rot 0/1 → {3,2,1}/{3,1,2}.
- SplitConverted(amount, 909, 1000, "USD", [{3,334},{1,333},{2,333}], 0) → `[{1,333,303},{2,333,303},{3,334,303}]`.

Error messages, from the tests:
- `"Mindestens eine Person"`
- `"größer als 0"`
- `"zu groß"`
- `"doppelt"`
- `"Ungültige Person"`
- `"Aufteilungsart"`
- `"negativ"`
- `"100 %"`
- `"10,00 €"`
- `"Die Beträge müssen zusammen 10,00 USD ergeben (aktuell 9,00 USD)."`

### balance.go
```go
type Entry struct { PaidBy int64; AmountCents int64; Shares []Share }

func Balances(entries []Entry) map[int64]int64 {
	b := map[int64]int64{}
	for _, e := range entries {
		b[e.PaidBy] += e.AmountCents
		for _, s := range e.Shares { b[s.ParticipantID] -= s.AmountCents }
	}
	return b
}
```
Positive means the person is owed money. Reimbursements are ordinary entries: the payer is the one paying back, and the single share is the recipient. Entries with a value of 0 can remain in the map, for example `{2: 0}` in the test.

**Settlement suggestion (greedy, deterministic):**
```go
type Transfer struct { From, To, AmountCents int64 }

func Settle(balances map[int64]int64) []Transfer {
	b := make(map[int64]int64, len(balances))
	for id, v := range balances { if v != 0 { b[id] = v } }
	var out []Transfer
	for {
		var creditor, debtor int64
		for id, v := range b {
			if v > 0 && (creditor == 0 || v > b[creditor] || (v == b[creditor] && id < creditor)) { creditor = id }
			if v < 0 && (debtor == 0 || v < b[debtor] || (v == b[debtor] && id < debtor)) { debtor = id }
		}
		if creditor == 0 || debtor == 0 { return out }
		amount := min(b[creditor], -b[debtor])
		out = append(out, Transfer{From: debtor, To: creditor, AmountCents: amount})
		b[creditor] -= amount; b[debtor] += amount
		if b[creditor] == 0 { delete(b, creditor) }
		if b[debtor] == 0 { delete(b, debtor) }
	}
}
```
In each round, the largest creditor and the largest debtor (most negative) are chosen, with ties going to the **smaller ID**. The result does not depend on map iteration order. ID 0 serves as the "none" sentinel, so IDs must be > 0. The input is not modified. It returns `nil`, not an empty slice, when nothing is owed.

Tests:
- `{1:5000, 2:-3000, 3:-1500, 4:-500}` → `2→1 3000, 3→1 1500, 4→1 500`
- `{1:2000, 2:1000, 3:-2500, 4:-500}` → `3→1 2000, 3→2 500, 4→2 500`
- `{5:100, 2:100, 9:-100, 3:-100}` → `3→2 100, 9→5 100`

### date.go
- `DateLayout = "2006-01-02"`. Calendar dates are `time.Time` at 00:00 UTC.
- `DateOf(t)` = `time.Date(t.Year(), t.Month(), t.Day(), 0,0,0,0, UTC)` using **t's own zone**.
- `Today(loc)` = `DateOf(time.Now().In(loc))`. Test: 23:30 UTC on Oct 1 is Oct 2 in Europe/Berlin.
- `MinYear=2000`, `MaxYear=2100`.
- `ParseDate(s)`:
  - TrimSpace. Empty gives `"Bitte ein Datum angeben."`.
  - Tries Go layouts `"2006-01-02"`, `"02.01.2006"`, `"2.1.2006"` in order. A year outside 2000–2100 gives `"Das Datum „%s“ liegt nicht zwischen 2000 und 2100."`. No layout matching gives `"Ungültiges Datum „%s“."`.
  - Go layout semantics **[verified]**:
    - `2006` means exactly 4 digits, and `01`/`02` mean exactly 2 digits. `2`/`1` accept 1–2 digits.
    - `"2026-9-01"` → error. `"02.1.2026"` and `"2.01.2026"` → OK (via `2.1.2006`). `"2.1.26"` → error. `"+2026-01-01"` → error.
    - Day-of-month is validated: `2026-02-30` → error.
    - `"0026-10-02"` parses as year 26, which gives the range error.
- `FormatDate(t)`: `""` for the zero time, else `"02.01.2006"`.
- `Frequency`: `weekly`, `monthly`, `yearly`.
  - `Label()`: `Wöchentlich`, `Monatlich`, `Jährlich`. `Adverb()`: `wöchentlich`, `monatlich`, `jährlich`. An unknown frequency gives the raw string.
  - `Frequencies` order: weekly, monthly, yearly.
```go
func Occurrence(f Frequency, anchor time.Time, n int) time.Time {
	anchor = DateOf(anchor)
	switch f {
	case FreqWeekly:  return anchor.AddDate(0, 0, 7*n)
	case FreqMonthly: return addMonthsClamped(anchor, n)
	case FreqYearly:  return addMonthsClamped(anchor, 12*n)
	}
	return anchor
}

func NextDate(f Frequency, anchor, after time.Time) time.Time {
	anchor, after = DateOf(anchor), DateOf(after)
	if after.Before(anchor) || !f.Valid() { return anchor }
	var n int
	switch f {
	case FreqWeekly:  n = int(after.Sub(anchor).Hours()/24) / 7
	case FreqMonthly: n = monthsBetween(anchor, after)
	case FreqYearly:  n = monthsBetween(anchor, after) / 12
	}
	n = max(n-1, 0)
	for { if t := Occurrence(f, anchor, n); t.After(after) { return t }; n++ }
}

func monthsBetween(a, b time.Time) int { return (b.Year()-a.Year())*12 + int(b.Month()) - int(a.Month()) }

func addMonthsClamped(t time.Time, months int) time.Time {
	y, m := t.Year(), int(t.Month())-1+months
	y += m / 12          // Go: truncating division
	m %= 12              // Go: remainder has sign of dividend
	if m < 0 { m += 12; y-- }
	month := time.Month(m + 1)
	day := min(t.Day(), daysIn(y, month))
	return time.Date(y, month, day, 0, 0, 0, 0, time.UTC)
}
func daysIn(year int, month time.Month) int { return time.Date(year, month+1, 0, 0, 0, 0, 0, time.UTC).Day() }
```
Occurrences are always computed from the anchor. With anchor Jan 31 the sequence is Feb 28 (or Feb 29 in a leap year), Mar 31, Apr 30, May 31. A yearly anchor of Feb 29 gives Feb 28 in non-leap years and Feb 29 again in leap years.

NextDate tests:
- weekly 2026-01-05 / after 01-05 → 01-12
- 2025-12-29 / 12-30 → 2026-01-05
- before the anchor → the anchor itself
- monthly 01-31 / 01-31 → 02-28
- 2028 → 02-29
- 01-31 / 02-28 → 03-31
- 01-31 / 03-31 → 04-30
- 12-31 → 2027-01-31
- 01-10 / 05-20 → 06-10
- yearly 03-15 → 2027-03-15
- 2028-02-29 → 2029-02-28
- 2028-02-29 / after 2031-03-01 → 2032-02-29

---

## 6. Sorting and collation

SQL-side (copy verbatim; SQLite decides the semantics):
- `ORDER BY name COLLATE NOCASE, id`: participants.
- `ORDER BY position, name COLLATE NOCASE, id`: categories. Used in ListCategories, activeCategories and mappingChanges.
- Expenses: see the `expenseOrder` map. Also `ORDER BY e.date DESC, e.id DESC` in CategoryHistory, YNABSyncSummary, RecentUsedFXRates and the template-from-latest query.
- `ORDER BY e.date, e.id, x.participant_id`: balances. `ORDER BY expense_id, participant_id`: shares. `ORDER BY e.id, x.participant_id`: migrations.
- `ORDER BY a.id DESC`: activity. `ORDER BY action`: distinct actions.
- `ORDER BY active DESC, next_date, id`: ListRecurring. `ORDER BY next_date, id`: DueRecurring.
- fx: `ORDER BY date DESC LIMIT 1`; `ORDER BY currency, date DESC`; `ORDER BY currency`.
- ynab: `ORDER BY participant_id`; `ORDER BY expense_id`.
- Stats: `ORDER BY 4 DESC, 1` / `2` / `2, 4 DESC, 1`. Here `1` is `coalesce(c.name,…)` or `max(e.title)`, which use BINARY collation (a function result does not inherit NOCASE).
- Schema: `ORDER BY type DESC, rowid`.
- Unique constraint on names: `UNIQUE COLLATE NOCASE`, which is case-insensitive for ASCII only.

Go-side sorting:
- `domain.SplitConverted`: `slices.SortFunc` by ParticipantID. IDs are unique, so stability is irrelevant.
- `domain.Allocate`: **`slices.SortStableFunc`** by remainder descending. Stability is essential.
- `toOriginalWeights` (migration 4): `slices.SortFunc` by ParticipantID.
- `checkRefs`: `slices.Sort` + `slices.Compact` of int64 ids.
- `statsByPerson`: **`slices.SortStableFunc`**: AmountCents desc, then `strings.Compare(strings.ToLower(a), strings.ToLower(b))`, which is a bytewise compare of Go-lowercased names.
- `FillPeriods`: **`slices.SortStableFunc`** by `strings.Compare(Period)`.
- `RotateBackups`: `slices.Sort(names)` (lexicographic).
- `migrate`: `slices.SortFunc` by number.
- `CreateCategory`: finds "Sonstiges" with `strings.EqualFold`, which is Unicode simple case folding.

Text comparison: `fold()` = `strings.ToLower` + `ß → ss` (and therefore `ẞ → ß → ss`), used through `instr`. No LIKE is used for user text.

---

## 7. Backups (backup.go + scheduling in main.go)

```go
const backupPrefix, backupSuffix = "zipfelkasse-", ".db"

func (s *Store) Backup(ctx context.Context, dir string, keep int) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil { return "", fmt.Errorf("create backup directory: %w", err) }
	name := backupPrefix + s.now().UTC().Format("20060102-150405") + backupSuffix
	path := filepath.Join(dir, name)
	if _, err := os.Stat(path); err == nil { return "", fmt.Errorf("backup %s already exists", path) }
	if _, err := s.db.ExecContext(ctx, "VACUUM INTO ?", path); err != nil { return "", fmt.Errorf("vacuum into: %w", err) }
	return path, RotateBackups(dir, keep)
}

func RotateBackups(dir string, keep int) error {
	entries, err := os.ReadDir(dir)
	...
	for _, e := range entries {
		n := e.Name()
		if e.Type().IsRegular() && strings.HasPrefix(n, backupPrefix) && strings.HasSuffix(n, backupSuffix) { names = append(names, n) }
	}
	slices.Sort(names)                       // timestamp sorts lexicographically
	for len(names) > max(keep, 0) {
		if err := os.Remove(filepath.Join(dir, names[0])); err != nil { return err }
		names = names[1:]
	}
	return nil
}
```
- File name: `zipfelkasse-YYYYMMDD-HHMMSS.db`, using the **UTC** time from the store clock, for example `zipfelkasse-20261003-010000.db` for 03:00 Berlin summer time.
- `VACUUM INTO ?` takes the path as a bound parameter. **[unverified]** Whether the output file keeps the WAL header bytes was not checked, because the shell was blocked mid-task. It doesn't matter: `Open` on a backup sets WAL again anyway.
- Rotation:
  - Only regular files with the prefix and suffix count. Symlinks and other files are left alone; the test checks that `notiz.txt` is untouched.
  - The oldest files are deleted first, keeping `keep` (7).
  - The new path is returned even if the rotation fails, together with the rotation error.
- Scheduling is **not in the store**. `main.go` has `backupLoop`: `nextBackup(now)` = the next **03:00 in `cfg.Location`** that is strictly after now. It calls `st.Backup(ctx, cfg.BackupDir, backupKeep)` with `const backupKeep = 7`, logs `"backup failed"` or `"backup written"` with the path, and loops until ctx is done.
- Test `TestBackupAndRotate`: 9 daily backups with keep 7 leave 7 files plus notiz.txt. The oldest is deleted. The newest opens via `Open` and has 3 participants.

---

## 8. Tests (per file, one-line summaries)

### internal/domain
**money_test.go**
- TestFormatCents: grouping, negative, small values ("-0,05 €").
- TestFormatCentsInput: no grouping ("1234,56", "-0,50").
- TestParseCents: 28 cases of accepted and rejected euro inputs, plus the ValidationError type (listed in §5).
- TestParseMinorDecimals: decimals 0/2/3, superfluous zeros, a leading-zero dot.
- TestBasisPoints: parsing "50", "33,33", "33.34", "100", "12,5 %" and formatting "33,33 %", "100,00 %".
- TestFormatMoney: EUR/""/USD/JPY grouping/lowercase "kwd".
- TestValidCurrencyCode: uppercase 3 ASCII letters only.
- TestIsEUR: "", "EUR", "eur", " EUR " are true. "USD" and "EU" are false.
- TestToEURCents: USD/JPY/EUR/negative/zero rate.
- TestParseRate: 14 OK and 14 invalid inputs.
- TestFormatDecimal: separators, negatives, decimals 0/3, plus FormatMinorInput per currency.
- TestFormatRate: shortest form with a comma. `0` and `-1` give "".

**split_test.go**
- TestSplit: 12 cases across modes. The sum equals the total, and the result is sorted by ID.
- TestSplitRotatesTies: 14 rotation cases (even/odd IDs, start 0–3, −1, the largest remainder winning, only tied entries rotating).
- TestSplitEqualStoresWeightOne: equal weights are normalized to 1.
- TestSplitErrors: 11 error messages (substrings).
- TestAllocate: 11 cases including 128-bit overflow safety.
- TestSplitConverted: foreign amounts, tie rotation, other modes, exact error texts.
- TestSplitModeValid: all modes are valid and labelled. "foo" is invalid.

**date_test.go**
- TestNextDate: 14 cases (weekly/monthly/yearly, month-end clamping, leap years).
- TestOccurrence: Jan 31 monthly sequence.
- TestFrequency: valid/labels; "daily" is invalid.
- TestFrequencyAdverb: adverbs; unknown passes through.
- TestParseDate: 13 cases (formats, range 2000–2100, Feb 30).
- TestFormatDate: "02.10.2026"; zero gives "".
- TestToday: DateOf in Europe/Berlin across midnight.
- TestParseDateRangeMessage: the message mentions 2000 and 2100.

**balance_test.go**
- TestBalances: 3 entries including a reimbursement; the balances sum to 0.
- TestBalancesEmpty: nil gives an empty map.
- TestSettle: empty, settled, simple, greedy, multiple creditors, ID tie-break.
- TestSettleDoesNotModifyInput.

### internal/store
**store_test.go**
- TestOpenMigratesAndSeeds: user_version = latest (≥4), no activity, 10 seed categories, group name, default currency.
- TestOpenFileTwiceIsIdempotent: nested dir creation, journal_mode wal, foreign_keys 1, reopen keeps data.
- TestParticipants: trim, duplicate (case-insensitive) and empty names are ValidationErrors, rename, archive/list, ErrNotFound.
- TestCategories: new category inserted before Sonstiges, duplicate ("lebensmittel"), rename, archive.
- TestSettings: GetSetting gives ErrNotFound; upsert twice; GroupName.
- TestCreateGetExpense: title normalization, joins, EUR fields, rotation (expense 1 gives Ben the extra cent), hook event, activity fields.
- TestCreateExpenseValidation: 16 invalid inputs; nothing is stored.
- TestArchiveParticipantWithBalance: the balance check message; deleted expenses don't count.
- TestNotesLength: 2000 characters with CRLF counted as 1 pass; 2001 is rejected.
- TestForeignCurrency: lowercase "usd" is normalized; derived EUR amount 9240.
- TestForeignCurrencyAmountIsDerived: AmountCents ignored for foreign currency (create and update).
- TestForeignAmountSharesRotateRemainder: USD 1000 @0.999 gives 1001 cents; the extra cent rotates with the ID.
- TestForeignCurrencyByAmounts: weights stay in USD; a no-op update logs nothing; a rate change recomputes; the history text; the weightSummary "Anna 4,33 USD"; the sum and 0 € errors.
- TestUpdateExpense: an unchanged save gives no log or hook; field changes "Betrag", "Kategorie" ("–") and "Aufteilung"; ErrNotFound.
- TestUpdateExpenseRateAndWeights: "Kurs" changes (EZB/manuell); weights 1:1 to 2:2 logged as "Anteile".
- TestDeleteExpense: soft delete, second delete gives ErrNotFound, update after delete gives ErrNotFound, hidden from list and balances, hook, activity.
- TestListExpensesFilter: newest-first default, text (title/notes), "100%", category, without category, participant, date range, limit/offset.
- TestExpenseSharesRotateRemainder: rotation by ID is preserved on update.
- TestMigrationResplitsShares: user_version 1, reopen twice; shares redistributed, amount-mode untouched, deleted expense included, one `shares_recalculated` entry with "3 Ausgaben".
- TestMigrationConvertsForeignAmountWeights: user_version 3; weights converted for live, deleted and template expenses; cents unchanged; one `weights_converted` entry "2 Ausgaben und 1 wiederkehrende Ausgabe".
- TestNextExpenseID: max(id)+1, also after a soft delete.
- TestListExpensesTextIgnoresCaseOfUmlauts: fold behaviour (ä, ö, ß/ẞ/SS; no "ae").
- TestBalancesWithReimbursement: reimbursement forced to equal mode; balances.
- TestRecurringDuplicate: the second instance on the same date gives ErrRecurringExists; system activity actor is 0 with an empty name.
- TestUpdateRecurringDateCollision: moving an instance onto another's date gives a ValidationError containing "Termin".
- TestBackupAndRotate: see §7.
- TestConcurrentWritesFile: 20 concurrent CreateExpense calls on a file DB without errors. This needs BEGIN IMMEDIATE plus busy_timeout.

**activity_test.go**
- TestSettingsMutationsLogActivity: 30 steps, each with the exact settings_updated text and actor, or no entry. These are the exact German strings.
- TestFailedMutationsLogNothing: 6 failing mutations write no activity.
- TestActivityFailureRollsBackChange: a trigger blocking activity inserts makes rename and group-name changes roll back.

**fx_test.go**
- TestFXRatesECBAndManual: invalid ECB rows skipped, the lookup window, manual and ECB rates side by side, updates, validation, lists/latest/stats/currencies, delete semantics.
- TestRecentUsedFXRates: only foreign, non-deleted expenses.
- TestMigrationSeparatesFXRateSources: an old PK table with user_version 2 is migrated; both rates are kept; the CHECK on source.

**mcp_test.go**
- TestCheckSelect: 6 accepted and 14 rejected query strings, with the exact returned body.
- TestReadOnlyQuery: column names, int/real/null/blob rendering, empty result, 500-row truncation, 2000-character text truncation, SQL errors as ValidationError.
- TestReadOnlyQueryHasFold: the fold function in the sandbox (text/NULL/int).
- TestReadOnlyQueryHidesYNAB: no ynab tables, settings rows or schema entries; MCPSchema table count = 8.
- TestSandboxLayers: writes, ATTACH and VACUUM INTO fail in the sandbox; the ATTACH limit holds even with query_only off; runWrapped rejects non-SELECT; the original file is unchanged.
- TestReadOnlyQueryTimeout: an infinite recursive CTE is aborted with the "aborted" message within 3 s.
- TestReadOnlyQueryMemory: a `:memory:` store gives a ValidationError.
- TestStats: 15 grouping/filter cases with exact output strings.
- TestStatsByTitleIgnoresCase: "Rewe" and "REWE" are grouped together.
- TestFillPeriods: month, week and year filling; non-time groupings are untouched.
- TestPeriods: PeriodStart/PeriodOf round trip, ShiftDateYear, ShiftPeriodYear (W53).

**recurring_test.go**
- TestCreateRecurringFromExpense: invalid frequency, unknown expense, rule fields, template fields (date zero, recurring_id 0), the expense linked, a second rule rejected, activity, the anchor counting as an instance (ErrRecurringExists), DueRecurring boundaries.
- TestRecurringPauseResumeDelete: pause/resume without catch-up (next Monday), resume on an occurrence day, ErrNotFound, optimistic SetRecurringNextDate, paused/deleted rules give ErrRecurringChanged, FK SET NULL on delete, second delete gives ErrNotFound.
- TestUpdateRecurringTemplateFromLatest: the latest instance is adopted; deleted instances are ignored; ErrNoInstance and ErrNotFound.

**web_test.go**
- TestSetGroupName: normalization; an empty name is rejected.
- TestMoveCategory: up/down, edges, archived and unknown give ErrNotFound.
- TestCreateCategoryAfterMove: insertion before an active "Sonstiges" wherever it is; at the end when it is archived.
- TestExpenseCounts: per participant (payer or share, distinct) and per category, excluding deleted expenses.
- TestCategoryHistory: excludes deleted, uncategorized, archived-category and reimbursement expenses; newest first.

**ynab_test.go**
- TestYNABConfig: ErrNotFound; target needs a token; Ready; list excludes archived and disconnected; disconnect keeps the plan.
- TestYNABTargetChangeResetsSync: a start-date change keeps sync rows; an account change marks them "retarget" and clears txn and synced_at.
- TestYNABCategoryMapAndSummary: empty values skipped; unknown category gives a ValidationError; summary count and problems; delete.
- TestYNABConnectedAt: set when the target is chosen; kept on a start-date change; reset on an account change; EnsureYNABConnectedAt sets once.
- TestYNABStatus: nanosecond round trip; target doesn't touch status; a new token or disconnect resets token_invalid, error, retry_at and backoff but keeps last_run, last_sync and summary.
- TestMigrationMovesYNABStateIntoConfig: drop the columns, user_version 4, settings keys moved (JSON incl. offset time and ns backoff), invalid JSON ignored, keys deleted; a re-run is idempotent.

---

## 9. Porting pitfalls (Go → Crystal)

### SQLite / driver
1. **SQLite version gap.** modernc embeds 3.53.4, but system libsqlite3 is 3.45.1.
   - `strftime('%G-W%V')` (Stats by week) **returns NULL on 3.45.1** [verified]. Go would fail scanning NULL into a string.
   - Fix this by linking a modern SQLite (≥ 3.46; best is the same 3.53.x, for example a statically compiled amalgamation passed via `--link-flags`), or by registering your own ISO-week function and changing the SQL. Changing the SQL is less faithful.
   - The MCP `sql_query` sandbox exposes the SQLite version to users, so the available functions differ too.
   - Also required: `UPDATE … FROM` (3.33), `RETURNING` (3.35), `sqlite_schema` (3.33), `ALTER TABLE DROP COLUMN` (tests only, 3.35), JSON1 and math functions. 3.45 has all of these.
2. **BEGIN IMMEDIATE.** crystal-db/crystal-sqlite3 `transaction` sends a deferred `BEGIN`. Go uses `BEGIN IMMEDIATE` for every transaction, migrations included. Deferred read-then-write transactions in WAL can fail with `SQLITE_BUSY` (snapshot upgrade), and busy_timeout does not help with that. Implement your own `in_tx` that checks out a connection, runs `exec "BEGIN IMMEDIATE"`, then COMMIT or ROLLBACK. `TestConcurrentWritesFile` depends on this.
3. **Multi-statement exec.** crystal-sqlite3 prepares only the first statement, and the rest is silently ignored. Use `LibSQLite3.exec` (sqlite3_exec) on the raw handle for migration files and for migration 5's 3-statement SQL. Comments in the SQL are fine with sqlite3_exec.
4. **Per-connection setup.** Pragmas come from the URI. The `zipfelkasse_fold` function must be registered on **every** pooled connection (`db.setup_connection`) **and** on the sandbox connection. Use `sqlite3_create_function_v2` with `SQLITE_UTF8|SQLITE_DETERMINISTIC` (`0x800`). The return types must match Go: TEXT for text, **TEXT for blob**, NULL for NULL, and int/real passed through. Note that crystal-sqlite3 binds only `create_function`, `value_text` and `result_int`, so you need extra `fun` bindings: `value_type`, `value_bytes`, `result_text`, `result_null`, `result_value`, `limit`, `extended_errcode`, `interrupt`, `progress_handler`, `column_name`, `extended_result_codes`.
5. **`:memory:` needs pool size 1** (`max_pool_size=1&max_idle_pool_size=1`). Otherwise every connection gets an empty DB.
6. **Foreign keys must be ON on every connection.** `DeleteRecurring` relies on `ON DELETE SET NULL`, and `TestRecurringPauseResumeDelete` checks `RecurringID == 0` after delete.
7. **Unique-violation detection.** Go checks the extended codes 2067 (UNIQUE) and 1555 (PRIMARYKEY). crystal-sqlite3 raises `SQLite3::Exception` with the primary code (19, CONSTRAINT), and CHECK/NOT NULL/FK violations are also 19. Call `sqlite3_extended_errcode`, or enable `sqlite3_extended_result_codes(db, 1)`, to tell them apart. A CHECK failure must *not* map to "„X“ gibt es schon.".
8. **The sandbox needs C-level calls:**
   - `sqlite3_limit(db, SQLITE_LIMIT_ATTACHED=7, 0)` and `sqlite3_limit(db, SQLITE_LIMIT_LENGTH=0, 8388608)`.
   - Column names via `sqlite3_prepare_v2` + `sqlite3_column_count` + `sqlite3_column_name`. An empty or comment-only query gives a NULL stmt and therefore "no columns".
   - The error `SQLITE_TOOBIG` (18).
   - **Timeout/interrupt:** Go interrupts via the context. In Crystal a blocking C call blocks the fiber scheduler, so a timer fiber cannot run. Use `sqlite3_progress_handler` with a deadline check, which returns non-zero to interrupt, or call `sqlite3_interrupt` from another thread. The message must be "The query was aborted after 5 s. …". The 5 s budget includes the copy.
   - To reproduce Go's error text, format as `"<errstr(code)>: <errmsg> (<extended code>)"` and strip the `"SQL logic error: "` prefix. Go shows, for example, `SQL error: no such table: doesnotexist (1)`.
   - ATTACH URI: `file:///abs/path?mode=ro`, with the path percent-escaped the way Go's `url.URL.String()` does it.
   - The sandbox DB has **no** pragmas (foreign_keys off) and uses a plain `BEGIN` for the copy.
9. **JSON number decoding in runWrapped.** SQLite json renders REAL as `1.0` and `1e+300`. Go converts to int64 only when it parses as an integer literal, otherwise to float64.
10. **Copy all SQL strings byte-for-byte.** That covers the migration files, the ALTER column definitions, and the CREATE statements produced for the sandbox (taken from `src.sqlite_schema`). It keeps the schema text identical and keeps `MCPSchema` output identical.
11. **Booleans.** Bind `Bool` as integer 0/1 (crystal-sqlite3 does). Read with `!= 0`. Go would *error* on values other than 0/1, but CHECK constraints prevent them.
12. **NULL handling.** Go uses `sql.NullString`/`NullInt64` and maps NULL to `""`/`0`/zero time. In Crystal, read as `String?`/`Int64?` and map the same way. **Write 0 IDs as NULL** (`nullInt`), and zero times or dates as NULL (`optionalDate`, `statusTime`, `SyncedAt`). `archived_at`/`deleted_at` are NULL or a timestamp.
13. **LIKE.** It is not used for user text, so no escaping concerns. The only LIKEs are `key NOT LIKE 'ynab%'` and migration 5's `LIKE 'ynab.status.%'`. SQLite's LIKE is ASCII case-insensitive.
14. **Wrong statement ordering in args.** In `Stats` with ParticipantID, the participant arg is **prepended**, because the JOIN comes before the WHERE. In `statsByPerson` the condition args repeat 3×, and then the pid follows. `SetParticipantArchived` uses `?1` twice with a single bound arg.

### Numbers / arithmetic
15. **Rounding.** `math.Round` is half away from zero. **Crystal's `Float#round` defaults to ties-to-even** [verified: `2.5.round` gives `2.0`]. Use `round(:ties_away)` in `ToEURCents`. Keep the exact float operation order `minor.to_f / scale / rate * 100`, with `scale = 10.0 ** decimals`, which is exact for 0–3.
16. **Integer division and modulo.** Go truncates toward zero, and `%` takes the sign of the dividend. **Crystal `//` and `%` floor** [verified: `-7 // 2` = -4, `-7 % 2` = 1]. Use `tdiv`/`remainder` for a 1:1 port.
    - `addMonthsClamped`: Go does `y += m/12; m %= 12; if m<0 {m+=12; y--}`. With Crystal's floor ops the fix-up never triggers, and the result happens to be the same. **Don't mix the two**, for example floor `//` with Go's fix-up, or `tdiv` without the fix-up.
    - `Allocate`'s `((rotation % n) + n) % n` gives the same result with either semantics.
    - `int(after.Sub(anchor).Hours()/24) / 7` is non-negative here because after ≥ anchor.
17. **Overflow.** Go's int64 arithmetic wraps silently. **Crystal raises `OverflowError`** on `+ - *`.
    - `Allocate` needs **128-bit**: `(total.to_u128 * w.to_u128) // sum.to_u128` and `% sum`.
    - The weight sum is uint64 in Go. Use `UInt64` with `&+`, or `Int128`.
    - The SplitAmount overflow check (`bits.Add64` + `> MaxInt64`) maps to an Int128 sum checked against `Int64::MAX` → "Der Betrag ist zu groß.".
    - `formatSep` negates `v` through uint64 (MinInt64-safe). In Crystal `-Int64::MIN` raises, so use `v.to_u64!` / `0_u64 &- v.to_u64!`.
    - `Balances` sums can't realistically overflow (amounts ≤ 1e12).
    - `parseFixed` caps at 15 integer digits before `ParseInt`. `"99999999999999999999"` is rejected by that length check.
18. **Float formatting.**
    - `FormatRate` uses Go `FormatFloat('f', -1)`: shortest round-trip, **never an exponent**, no trailing `.0` (`17000` → "17000", `1e9` → "1000000000"). Crystal `Float#to_s` gives `"17000.0"`, `"1.0e-7"` and `"1.0e+21"` [verified]. Write a custom formatter: take the shortest digits (`Float::Printer`), then expand to fixed notation without the trailing ".0".
    - Go's JSON float encoding (template_json `fx_rate`) uses `1`, `1.0823`, `1e-7` and `1e+21`, while Crystal's `to_json` gives `1.0`. Go *reads* `1.0` fine as float64. **But Go reads `1.0` as an error for int64 fields** (`weight`, `amount_cents`), so write integers with no decimal point. Crystal's Int64 serialization already does that.
19. **`ParseRate`** uses Go `ParseFloat(intPart + "." + frac + "0")`. Crystal `String#to_f` (strtod) is also correctly rounded. Guard against a Crystal `to_f?` that accepts `_` or other forms; the input is pre-validated by splitNumber anyway.
20. **`ValidCurrencyCode`** checks 3 **bytes** (`len(s) != 3`). "ÄBC" is 4 bytes, so it is false. In Crystal, check `bytesize == 3` and each byte `A`..`Z`.

### Strings / Unicode
21. **`strings.ToLower` vs `String#downcase`.** Go uses simple per-rune mapping, Crystal full Unicode mapping. [verified] `"İ"` becomes `"i"` in Go but `"i̇"` (2 code points) in Crystal. Greek final sigma is not context-sensitive in either. To match `fold()` exactly, use per-char `Char#downcase` (simple mapping), or `downcase(Unicode::CaseOptions::None)` plus a check. Then apply `gsub("ß", "ss")`. This affects search, stats-by-title grouping and statsByPerson ordering.
22. **`strings.Fields` / `TrimSpace`** use Go `unicode.IsSpace`, which **includes U+0085 (NEL)**. Crystal `Char#whitespace?` returns false for U+0085 [verified]. Both include NBSP and U+202F. Write a helper with Go's set: `\t \n \v \f \r space U+0085 U+00A0` plus Unicode White_Space (U+1680, U+2000–200A, U+2028, U+2029, U+202F, U+205F, U+3000). This is used in NormalizeName, the title and the ExpenseDatesLike title.
23. **Rune counts.** `len([]rune(s))` equals Crystal `s.size` for valid UTF-8. Go counts each invalid byte as one rune (U+FFFD). Name ≤ 60, title ≤ 200, notes ≤ 2000 **after `\r\n` → `\n`**, but the notes are stored unchanged.
24. **`strings.EqualFold`** (Unicode simple folding) for "Sonstiges". Crystal `compare(other, case_insensitive: true) == 0` is close enough for this ASCII target.
25. **JSON encoding differences.** Go `encoding/json` escapes `<`, `>`, `&`, U+2028 and U+2029 as `<` and so on [verified]. Crystal does not. Reading works either way. If you want byte-identical rows, write a custom string escaper. Key order and `omitempty` must be reproduced: `ActivityDetails` omits empty or 0 fields, and `ExpenseInput` omits nothing and includes `"date":"0001-01-01T00:00:00Z"` and `"recurring_id":0`. Decoding must tolerate missing keys (`'{}'` templates), `"parts": null`, ints for float fields, and **case-insensitive key matching** (Go's Unmarshal quirk; rarely relevant).
26. **`%q` formatting** in error messages (`unknown sort order %q`, `Unknown grouping %q.`, `date %q`) uses Go-quoted strings. Use `inspect`-like double-quoting. It differs for non-ASCII escapes only.
27. **German typographic quotes** `„…“` (U+201E/U+201C), the en dash `–` (U+2013), the arrow `→` and `€` appear in messages. Copy the strings exactly; activity texts are persisted.

### Time
28. **Timestamp writing.** `nowString` = UTC RFC3339 **with seconds, fractions truncated**: `Time.utc.to_rfc3339` (fraction_digits 0) → `2026-10-03T12:05:06Z`. `statusTime` = RFC3339Nano: 9 fraction digits with **trailing zeros stripped and the "." dropped if nothing remains**. Crystal has no direct equivalent, so write a formatter. `PutYNABSync.synced_at` = RFC3339 seconds.
29. **Timestamp reading** (`parseTime`) must accept: `Z` or `±hh:mm` offsets, **optional fractional seconds of any length** (Go's RFC3339 parser accepts fractions), values from migration 5 like `2026-09-20T12:00:00.5+02:00`, and test junk like `'x'`, which **silently becomes zero time**. Crystal `Time.parse_rfc3339` handles fractions and offsets [verified]. Rescue errors to return the zero time.
30. **Zero time.** Go's `time.Time{}` is year 1, used for "not set". Pick a Crystal sentinel (`nil` or `Time.utc(1,1,1)`). The zero time must serialize as `"0001-01-01T00:00:00Z"` in template_json [verified: Crystal `Time.utc(1,1,1).to_rfc3339` gives that].
31. **Dates are 00:00 UTC values.** `formatDate` formats in **t's own location**, and `DateOf` takes Y-M-D in t's location. Keep calendar dates as UTC midnight in Crystal. `Today(loc)` uses the configured zone (Europe/Berlin), and `SetRecurringActive` gets `today` from the caller. Backup file names use **UTC**, while scheduling uses local 03:00.
32. **`ParseDate` must be strict like Go** (§5): the 4-digit year, the 2-digit fields in `2006-01-02` and `02.01.2006`, 1–2 digit fields in `2.1.2006`, day validation and the year range. Crystal's `Time.parse` with `%m`/`%d` is more lenient. Use a regex plus `Time.utc(y,m,d)`, rescuing an `ArgumentError` for invalid days.
33. **ISO weeks.** Go's `ISOWeek()` corresponds to Crystal `Time#calendar_week` (`{year, week}`). `PeriodOf` week = `"%d-W%02d"`. `PeriodStart` uses `Sscanf("%4d-W%2d")`, which accepts a sign and ignores trailing input; reproduce it leniently or document the change.
34. **`ShiftDateYear`.** Go's `AddDate` normalizes overflow (Feb 29 + 1y = Mar 1), and the code clamps explicitly. Crystal `Time#shift(years: 1)` clamps to Feb 28 by itself. Port the explicit logic anyway, because it keeps time-of-day and location.
35. **`ListActivity` Since/Until** compare RFC3339 strings, which is only correct for the UTC `Z` format. Format the bounds the same way.

### Behavioural subtleties easy to miss
36. **Sort stability.** `Allocate`, `statsByPerson` and `FillPeriods` rely on stable sorts. **[verified]** Crystal 1.21 `Array#sort_by` is stable (merge sort). Still, prefer explicit tie keys, for example `{-rem, index}`, to make intent obvious.
37. **The UpdateExpense no-op path** skips the UPDATE, the activity entry and the hook. Comparison is on formatted strings (diffExpense), so for example a rate change of 1.25 → 1.2501 that keeps the cents identical is still a change ("Kurs").
38. **Writes happen even when nothing is logged**: SetGroupName upsert, Rename* UPDATE, SetYNABTarget UPDATE (updated_at). Some mutations **always log** even without a state change: SetParticipantArchived, SetCategoryArchived, SetRecurringActive and SetManualFXRate.
39. **Hooks** run after commit, synchronously, only on success, and for update only when changed.
40. **`SetYNABToken`** calls the `reachable` callback (network I/O) inside the write transaction while holding the write lock. Port it as is, or note the change.
41. **Migration idempotency.** Migrations 2 and 4 write activity only when something changed. Migration 5 checks columns before each ALTER. Tests rerun migrations after `PRAGMA user_version = N`.
42. **Go map iteration order is random** in `SetYNABCategoryMap` (the insert order and which unknown category is reported first) and in migration 4's template updates. Results don't depend on it. `Settle` is deterministic despite the map.
43. **`checkSelect` quirk.** Quoted tokens or comments after the first `;` are allowed and dropped (`"SELECT 1; 'x'"` is OK). Only an unquoted token triggers the "single query" error.
44. **`NoCategory` is the English "No category"**, and the sandbox error messages are English. Everything else is German.
45. **`ExpenseInput.FXSource`** is cleared for EUR but kept as given, possibly `""`, for foreign currency. `RecentUsedFXRates` returns it raw.
