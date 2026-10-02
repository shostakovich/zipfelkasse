# Plan: "Zipfelkasse" – a Spliit port in Go

## Context

A port of [Spliit](https://github.com/spliit-app/spliit) for my own home server. There is **one
group** and **no receipt scanning**. Further goals:
- as little maintenance and as few external dependencies as possible
- usable on desktop and phone
- analysis by AI via MCP
- fill YNAB from my own point of view

Runs in a Docker container behind Pangolin. Instead of logging in, you just tell the app who you are.

The user interface is German; code, comments and docs are English.

The folder `/Users/shostakovich/Code/teilen` is empty; there is no existing code.

## Decisions made

| Topic | Decision |
|---|---|
| Language | Go 1.26, standard library only. **Only dependency:** `modernc.org/sqlite` (pure Go, no CGO) |
| Frontend | The server renders the HTML with `html/template`. On top of that come one CSS file and a little vanilla JS. There is no build step, everything is packed into the binary via `embed`, and the app can be installed as a PWA |
| DB | SQLite in WAL mode at `/data/zipfelkasse.db`. Migrations are embedded `.sql` files, controlled via `PRAGMA user_version`, without a migration library |
| Money | Amounts are integer cents. Rounding remainders are distributed using the largest-remainder method, deterministically |
| Identity | Cookie `wer` holding the participant ID. Selection page on the first visit; at the top it says "Du bist X · wechseln" (you are X · switch) |
| Features | Expenses (title, amount, date, category, payer, notes) and splitting evenly, by shares, by percentage or by fixed amounts. Plus reimbursements, balances, a settlement suggestion (greedy), search, export as CSV/JSON, **recurring expenses**, **activity log** and **foreign currencies**. The UI is German only |
| Not included | Multiple groups, receipt scanning, attaching receipts, login |
| Foreign currency | ECB reference rates (`eurofxref-daily.xml`, `eurofxref-hist.zip`, read with `encoding/xml` and `archive/zip`) are cached in SQLite. The rate of the expense date applies, otherwise the last banking day before it. The rate can be overridden by hand, e.g. for the actual card rate. Currencies the ECB does not cover get a manual rate |
| Deletion | Soft delete (`deleted_at`), so that the YNAB sync can pass deletions on |
| YNAB | Via the API with a Personal Access Token, separately for each person. Model **clearing account "Geteilt"** (shared) in the budget: the app writes only *my share* of each expense as an outflow with the mapped YNAB category (PATCH on change, DELETE on deletion). Bank payments for shared expenses and reimbursements are marked in YNAB as transfers ↔ "Geteilt". Afterwards: balance of "Geteilt" = balance in the app. There is a start date from which syncing begins. **Fallback:** the same transactions as an OFX/CSV export |
| AI | A custom MCP server without an SDK (JSON-RPC 2.0 over Streamable HTTP, responses as JSON only). It has read-only tools exclusively |
| MCP access | Path `/mcp/{MCP_SECRET}`, no auth. Only `MCP_ALLOWED_CIDRS` may connect; the default is `160.79.104.0/21` (Anthropic). Exception: if the request comes from an address in `TRUSTED_PROXIES` (Pangolin), the client IP from `X-Forwarded-For` counts. Pangolin needs a "Bypass Auth" rule for `/mcp/*` |
| Backup | One `VACUUM INTO` per night to `/data/backups/`; the last 7 snapshots are kept |
| Docker | Multi-stage build: `golang:1.26-alpine` (CGO_ENABLED=0) builds, the result runs on `scratch`. The CA certificates are copied along; time zones come via `import _ "time/tzdata"`. The health check runs via the subcommand `zipfelkasse healthcheck` |

## Architecture / package structure

```
main.go                     config (ENV), wiring, subcommands (serve, healthcheck)
internal/domain/            pure logic: money, split, balances, settlement, recurrence rules (no IO)
internal/store/             SQLite, migrations/*.sql (embed), queries, activity log, backup
internal/web/               handlers, templates/*.html, static/ (css, js, manifest, sw.js, icons)
internal/fx/                ECB client and rate cache
internal/recurring/         creates due instances (at startup and hourly)
internal/ynab/              API client (net/http), sync worker, category mapping
internal/export/            CSV, JSON, OFX
internal/mcp/               JSON-RPC handler, tools, CIDR/proxy filter
Dockerfile, compose.yaml, docs/PLAN.md, README.md
```

Every feature package provides `Register(mux *http.ServeMux, deps)`. `main.go` calls all `Register`
functions. That way, parallel work packages only touch their own package.

### Data model (migration 001)

- `participants(id, name, archived_at)`
- `categories(id, name, archived_at)` with default categories as seed
- `expenses`:
  - basics: `id, title, date, category_id, paid_by, notes`
  - type: `is_reimbursement, split_mode`
  - amount: `amount_cents` (EUR), `original_amount_minor, original_currency, fx_rate, fx_source`
  - bookkeeping: `recurring_id, created_at, updated_at, deleted_at`
- `expense_shares(expense_id, participant_id, weight, amount_cents)`. `weight` depends on the mode (shares, basis points or cents). `amount_cents` is computed and stored, which simplifies SQL via MCP
- `recurring(id, template_json, frequency [weekly|monthly|yearly], next_date, active)`
- `activity(id, at, actor_id, action, expense_id, details_json)`
- `fx_rates(date, currency, rate)`
- `ynab_config(participant_id, token, budget_id, account_id, start_date)`, `ynab_category_map(participant_id, category_id, ynab_category_id)`
- `ynab_sync(expense_id, participant_id, ynab_txn_id, synced_hash, synced_at, last_error)`
- `settings(key, value)` (group name, default currency)

### Pages

- `/` – expenses by month, search, own balance at the top
- `/ausgaben/neu`, `/ausgaben/{id}` – form with live preview of the split and currency conversion (vanilla JS)
- `/salden` – balances, settlement suggestion, button "als erstattet eintragen" (record as reimbursed)
- `/aktivitaet`
- `/einstellungen` – participants, categories, recurring, YNAB (token, choose budget/account via API, category mapping, "jetzt synchronisieren" (sync now), status/errors), export
- Forms follow the POST → redirect pattern

### MCP tools

- `balances`
- `search_expenses` (date range, category incl. `none`, person, text, reimbursements)
- `statistics` (grouped by category, month, person or category and month; optionally only one person's share)
- `schema`
- `sql_query` (runs on an in-memory copy of the allowed tables, read-only, row limit, timeout)

Supported protocol versions: 2026-07-28 (stateless: `server/discover`, `tools/list`, `tools/call`) and the legacy
versions 2025-11-25, 2025-06-18 and 2025-03-26 (`initialize`, `notifications/initialized`, `ping`, `tools/list`,
`tools/call`). Details: [MCP.md](MCP.md).

## Work plan and subagents

**Phase 0 – foundation (myself, sequentially)**
1. Set up git: `git init` (in the sandbox run this failed with "Operation not permitted", so run it again with approval). Then `go mod init`.
2. Copy this plan to `docs/PLAN.md`. It is the briefing basis for all agents.
3. Build:
   - `internal/domain`, test-driven: split modes, rounding, balances, settlement, computing the next occurrence
   - `internal/store`: schema, basic queries, activity log
   - `main.go`, layout template, identity middleware, CSS skeleton, Dockerfile
   - stub `Register` for all packages

   Result: the project compiles, the tests are green, and you can pick a person in the app.
4. Commit.

**Phase 1 – in parallel, each with `isolation: "worktree"`**

| Agent | Package(s) | Content |
|---|---|---|
| A | `internal/web` | Expense CRUD, list/search, balances page, reimbursements, participant/category management, activity page, PWA (manifest, SW, icons) |
| B | `internal/fx`, `internal/recurring` | ECB client with cache, tests against XML fixtures. Creation of recurring expenses. Endpoint `GET /api/kurs?waehrung=&datum=` for the form |
| C | `internal/ynab`, `internal/export` | API client, sync (create/update/delete, milliunits, error status), YNAB settings page, OFX/CSV/JSON export. Tests with an `httptest` fake YNAB |
| D | `internal/mcp` | JSON-RPC, tools, read-only connection, CIDR and trusted-proxy filter. Tests with `httptest` |

Every agent gets these instructions:
- `docs/PLAN.md` and its own section of it
- **no new dependencies**
- changes only in its own package. Shared store queries go into a separate file `internal/store/<package>.go`
- `go test ./...` and `go vet ./...` must be green
- one commit in the worktree at the end

**Phase 2 – integration (myself)**

The worktrees are merged:
- wire up the form hooks: currency field (B) and recurring option (B) into A's form
- attach the sync trigger (C) to save/delete

Then review with `/code-review` and an end-to-end test (see below).

## Verification

1. `go vet ./... && go test ./...`: domain table tests (rounding, all split modes, settlement), store tests with `:memory:`, handler tests with `httptest`
2. Check `docker build -t zipfelkasse . && docker run -p 8080:8080 -v zipfelkasse-data:/data -e MCP_SECRET=… zipfelkasse`: the image is about 20 MB and the health check is green
3. In the browser pane `localhost:8080`, then:
   - pick a person
   - create expenses in all split modes, including one in USD
   - check balances and the suggestion, record a reimbursement
   - look at the activity log
   - check the phone viewport (375 px)
4. MCP: `curl` with `initialize` / `tools/list` / `tools/call balances` against `/mcp/<secret>`. A 403 is expected for a wrong IP or wrong secret. Then `claude mcp add --transport http zipfelkasse http://localhost:8080/mcp/<secret>` (locally with an extended CIDR) and ask real questions
5. YNAB: check against a test budget with account "Geteilt":
   - create, change, delete an expense → transaction appears, changes, or disappears
   - balance of "Geteilt" = balance in the app
   - the OFX file can be imported into YNAB
6. Recurring: a rule with `next_date` in the past creates the due instances at startup, without duplicates on restart

## Open but not critical (checked during implementation)

- Pangolin rule syntax for the bypass rule on `/mcp/*` and which headers Pangolin passes on (`X-Forwarded-For` / `X-Real-IP`). This is verified during setup and documented in the README
- The current MCP protocol version is looked up in the spec when building package D

## Interfaces (as of phase 0)

Briefing for the agents in phase 1. Everything here is a **contract**: do not change signatures, only add.
`main.go`, `internal/store/store.go`, `internal/store/migrations/001_init.sql`, `internal/web/deps.go`,
`internal/web/render.go` and `internal/web/identity.go` are shared files. Feature agents do not touch
them; agent A may add to `internal/web`, but must not break any exported signature, template block or CSS
class from this list.

### Working environment

- Go commands with `GOPROXY=off` and, in the sandbox, additionally `GOCACHE=$TMPDIR/gocache`
  (the normal build cache is not writable there).
- Ports cannot be opened in the sandbox. **Never write handler tests with `httptest.NewServer`**; call the
  handler directly instead: `rec := httptest.NewRecorder(); h.ServeHTTP(rec, req)` (template:
  `internal/web/web_test.go`, `main_test.go`). Build fake servers for YNAB/ECB accordingly as an
  `http.RoundTripper` or `http.Client{Transport: handlerTransport}`.
- `main_test.go` (`TestAppWiring`) wires up the complete app and calls every route once. Anyone adding new
  routes uses it to check for pattern conflicts (the mux panics on conflicts).

### Import direction

```
domain  ←  store  ←  web  ←  fx, recurring, ynab, export, mcp  ←  main
config  ←  web (Deps.Config), mcp, main
```
`web` imports **none** of the feature packages. Cross-references go through `web.Deps` (e.g. `Deps.FX`) and
the store change hook.

### `web.Deps` and wiring

```go
type Deps struct {
    Config config.Config   // Addr, DBPath, BackupDir, MCPSecret, MCPAllowedCIDRs/TrustedProxies []netip.Prefix, Location
    Store  *store.Store
    Render *web.Renderer
    Log    *slog.Logger
    FX     web.FXRater     // = *fx.Service, set by main; possibly nil in tests
}
func (d Deps) Today() time.Time          // today's date in Config.Location (00:00 UTC, see domain)
func web.WriteJSON(w, status int, v any)
```

`main.newApp` does exactly this (fixed order):

| Package | Constructor / registration | Background (own goroutine, blocks until ctx is done) |
|---|---|---|
| web | `web.Register(mux, d)`, at the end `web.Wrap(d, mux)` | – |
| fx | `fx.New(d) (*fx.Service, error)`, then `d.FX = svc`; `svc.Register(mux)` | `svc.Run(ctx)` (e.g. daily ECB fetch) |
| recurring | `recurring.New(d) (*recurring.Service, error)`; `svc.Register(mux)` | `svc.Run(ctx)`: `Materialize` immediately, then hourly |
| ynab | `ynab.New(d) (*ynab.Service, error)` – registers `Trigger` on the store hook; `svc.Register(mux)` | `svc.Run(ctx)`: works through the queue |
| export | `export.Register(mux, d) error` | – |
| mcp | `mcp.Register(mux, d) error` (no-op without `MCP_SECRET`) | – |

Further fixed methods: `fx.Service.Rate(ctx, currency, date) (domain.FXRate, error)`,
`recurring.Service.Materialize(ctx, today time.Time) (int, error)`, `ynab.Service.Trigger(expenseID int64)`
(never blocks). Anyone who needs additional dependencies gets them from `Deps` or builds them in their own
`New`/`Register` (e.g. an HTTP client with timeout in the service struct) – not in `main.go`.

### Routes

Patterns **always with method** (`"GET /path"`, `"POST /path/{id}"`), no catch-alls such as `"/"` or `"GET /"`
(they collide with other patterns). Exception: `mcp` registers `"/mcp/{secret}"` without a method.

| Package | Prefix / routes |
|---|---|
| web (A) | `GET /{$}`, `/ausgaben/…`, `/salden`, `/aktivitaet`, `/einstellungen`, `/einstellungen/teilnehmer…`, `/einstellungen/kategorien…`, `/wer`, `/wer/neu`, `/static/…`, `/healthz`, `/manifest.webmanifest`, `/sw.js` |
| fx (B) | `GET /api/kurs`, `/einstellungen/kurse…` |
| recurring (B) | `/einstellungen/wiederkehrend…` |
| ynab (C) | `/einstellungen/ynab…` |
| export (C) | `/export…` (e.g. `GET /export/ausgaben.csv`, `…/ausgaben.json`, `…/ynab.ofx`) |
| mcp (D) | `/mcp/{secret}` |

The `/einstellungen` page already links to participants, categories, `/einstellungen/wiederkehrend`,
`/einstellungen/kurse`, `/einstellungen/ynab` and `/export`. Forms: POST → `http.Redirect(…, 303)`,
with a success message set beforehand via `web.SetFlash(w, "Gespeichert.")`.

**Identity** (`web.Wrap`): cookie `wer` = participant ID. `web.Me(r.Context()) (store.Participant, bool)`
returns the person; behind the middleware it is set on all non-public paths (archived people count as
"nobody"). Without a person: `GET` → 303 to `/wer?zurueck=<path>`, `/api/…` → 401 JSON
`{"error": "…"}`. Public (reachable without a person): `/wer`, `/wer/neu`, `/healthz`, `/static/…`, `/mcp/…`,
`/manifest.webmanifest`, `/sw.js`, `/favicon.ico`. Tests of other packages set the person with
`web.WithMe(ctx, p)`. Security headers for everything; **the CSP allows no inline scripts** (`script-src 'self'`),
inline styles are allowed. So JS goes into files: web under `/static/`, feature packages via their own
`GET` route under their prefix from their embed.FS.

### Renderer (shared layout)

```go
//go:embed templates/*.html
var templatesFS embed.FS

pages, err := d.Render.Load(templatesFS, "templates/*.html")    // in New/Register, once
pages.Render(w, r, http.StatusOK, "ynab.html", web.Page{
    Title: "YNAB",            // <title>Title · group name</title>
    Nav:   web.NavSettings,   // active tab: NavExpenses | NavBalances | NavActivity | NavSettings
    Error: "",                // red message at the top (e.g. ValidationError.Msg), status is then 422
    Data:  myData,            // available in the template as .Data
})
d.Render.Error(w, r, http.StatusNotFound, "Ausgabe nicht gefunden.") // error page within the layout
```

- Every page file defines `{{define "content"}}…{{end}}`, optionally `{{define "head"}}` (in `<head>`) and
  `{{define "scripts"}}` (before `</body>`, e.g. `<script src="/einstellungen/ynab/ynab.js" defer></script>`).
- Files whose name starts with `_` are partials and are available to all pages of the same `Load`.
- Template data (`.`): `.Title`, `.Nav`, `.Error`, `.Data`, `.Me` (`*store.Participant`, nil without a person),
  `.GroupName`, `.Flash`, `.Path`.
- Template functions everywhere: `eur` (cents → "1.234,56 €"), `amountInput` (cents → "1234,56" for `<input>`),
  `money` (minor, currency → "12,34 USD"), `percent` (basis points → "33,33 %"), `date` (→ "02.10.2026"),
  `isoDate` (→ "2026-10-02" for `<input type=date>`), `dateTime` (timestamp in local time),
  `signClass` (int64 → `positive`/`negative`/""), `static` ("app.css" → versioned URL), `dict` (k, v, … → map for partials).
- Render buffers: template error → 500 without a half-rendered page. Rendered with `Cache-Control: no-store`.

### CSS (`internal/web/static/app.css`)

Design tokens in shadcn/ui style (neutral), each for light + dark (`prefers-color-scheme`), as HSL components:
`hsl(var(--token))`. Tokens: `--background --foreground --card --card-foreground --popover
--popover-foreground --primary --primary-foreground --secondary --secondary-foreground --muted
--muted-foreground --accent --accent-foreground --destructive --destructive-foreground --success --border
--input --ring --radius --positive --negative`, plus `--font-sans`, `--touch` (minimum height of touch targets).

Classes: layout `.container .main .site-header .site-header-inner .brand .whoami .tabs` (tab bar,
active tab via `aria-current="page"`); cards `.card .card-header .card-title .card-description
.card-content .card-footer`; buttons `.btn` + `.btn-primary .btn-secondary .btn-outline .btn-ghost
.btn-destructive`, sizes `.btn-sm .btn-lg .btn-block`; forms `.form .field .field-error .help`
(inputs/selects/textareas are styled without a class); tables `.table-wrap` + `table/th/td`; messages
`.alert .alert-success .alert-destructive`; helpers `.link-list .stack .stack-sm .row .muted .amount
.positive .negative .sr-only`. Agent A ports the Spliit look and may extend the CSS; feature packages
use only these classes (no CSS of their own).

### Store

- Own queries go into **`internal/store/<package>.go`** (`fx.go`, `recurring.go`, `ynab.go`, `export.go`,
  `mcp.go`; A possibly `web.go`) plus tests in `<package>_test.go`. Available there: `s.db`,
  `s.inTx(ctx, func(*sql.Tx) error)`, `s.nowString()` (RFC 3339 UTC), `s.Path()`, helpers `formatDate`,
  `parseDate`, `parseTime`, `nullInt`, `placeholders(n)`, `invalid(fmt, …)` (→ `domain.ValidationError`),
  `isUniqueViolation`, `checkAffected`. Tests: `newTestStore(t)` (`:memory:`), `newFixture(t)` (Anna, Ben,
  Cleo, category Lebensmittel) from `store_test.go`.
- **The schema is complete** (all tables from the data model, see `001_init.sql` with comments).
  Additions to the plan: `participants.created_at`, `categories.position`, `recurring.start_date` (anchor),
  `recurring.created_by/created_at/updated_at`, `fx_rates.source` ('ezb'|'manuell'), `ynab_config.enabled/updated_at`.
  The foreign-currency fields in `expenses` are NOT NULL (EUR: original = amount, rate 1, source '').
  If a migration does become necessary: additive only, own number range (A 010–019, B 020–029,
  C 030–039, D 040–049); recreate dev databases afterwards.
- Conventions: amounts `int64` cents; calendar dates `time.Time` 00:00 UTC (`domain.DateOf`), stored as
  'YYYY-MM-DD'; timestamps RFC 3339 UTC; nothing referenced is hard-deleted.
- `store.Open(path)`: WAL, `foreign_keys=ON`, `busy_timeout=5000`, `synchronous=NORMAL`, `BEGIN IMMEDIATE`;
  `":memory:"` = a single connection (so inside `inTx` use **only `tx`**, otherwise deadlock).
- Errors: `store.ErrNotFound`; input errors are `domain.ValidationError` (German `.Msg`, show directly).

API (excerpt, everything `ctx`-first):

| Area | Methods |
|---|---|
| People | `ListParticipants(includeArchived)`, `GetParticipant(id)`, `CreateParticipant(name) (id)`, `RenameParticipant(id, name)`, `SetParticipantArchived(id, bool)` |
| Categories | `ListCategories(includeArchived)`, `GetCategory`, `CreateCategory`, `RenameCategory`, `SetCategoryArchived` |
| Expenses | `CreateExpense(actorID, ExpenseInput) (id)`, `UpdateExpense(actorID, id, ExpenseInput)`, `DeleteExpense(actorID, id)` (soft), `GetExpense(id)` (including deleted ones, `e.Deleted()`), `ListExpenses(ExpenseFilter{Text, CategoryID, ParticipantID, From, To, Limit, Offset})` (without deleted ones, newest first) |
| Balances | `BalanceEntries() []domain.Entry`, `Balances() map[participantID]cent` (positive = is owed money) |
| Activity | `ListActivity(ActivityFilter{ExpenseID, BeforeID, Limit})`, `AddActivity(actorID, action, expenseID, ActivityDetails)` |
| Settings | `GetSetting(key)` (ErrNotFound), `SetSetting(key, value)`, `GroupName()`; keys `group_name`, `default_currency`, own keys with prefix (`ynab.…`) |
| Hook | `OnExpenseChange(func(store.ExpenseChange{ExpenseID, Action}))` |
| Operations | `Ping`, `SchemaVersion`, `Backup(dir, keep) (path)`, `RotateBackups(dir, keep)`, `Path`, `Close` |

`store.ExpenseInput`: `Title, Date, CategoryID (0 = none), PaidBy, Notes, IsReimbursement, SplitMode,
AmountCents (always EUR, > 0), Parts []domain.Part{ParticipantID, Weight}, OriginalAmountMinor,
OriginalCurrency ("" / "EUR" = no foreign currency), FXRate, FXSource, RecurringID` (JSON tags present).
The store computes the cent shares itself via `domain.Split`. `store.Expense` embeds `ExpenseInput`
(Parts from the stored weights, so it can be passed straight back to `UpdateExpense`) and additionally has
`ID, Shares []domain.Share, CategoryName, PaidByName, CreatedAt, UpdatedAt, DeletedAt`, methods
`Deleted()`, `IsForeign()`, `ShareOf(participantID) int64`.
- **Reimbursement** = `IsReimbursement: true`, `PaidBy` pays exactly one other person `Parts[0]`
  (SplitMode becomes `equal`).
- **Activity**: create/update/delete automatically write an entry (`expense_created|updated|deleted`)
  with `actorID` (0 = system, e.g. recurrence). Details: `Title`, `AmountCents`, on update `Changes
  []FieldChange{Field, Old, New}` (German field names, fully formatted values). An update without changes
  logs nothing and does not fire the hook. `RecurringID` stays unchanged on update.
- **Change hook**: called after a successful commit, synchronously in the caller's goroutine, also for
  deletions. Callbacks must not block (only enqueue) and must not keep using the request context.
  Register only at startup (in `New`).

### domain

`ValidationError{Msg}`; money: `FormatCents`, `FormatCentsInput`, `ParseCents` ("12,34", "12.34",
"1.234,56 €"), `ParseMinor(s, decimals)`, `FormatMoney(minor, currency)`, `CurrencyDecimals(cur)`,
`ToEURCents(minor, currency, rate)`, `FormatBasisPoints`, `ParseBasisPoints`, `MaxAmountCents`.
Splitting: `SplitMode` (`equal|shares|percent|amount`, `.Valid()`, `.Label()`), `SplitModes`,
`Split(mode, totalCents, []Part, rotation) ([]Share, error)` (largest remainder; on ties the extra cent rotates
with `rotation` = expense ID round-robin over the tied people; result sorted by ID). Balances: `Entry{PaidBy, AmountCents, Shares}`, `Balances([]Entry)`, `Settle(map) []Transfer{From, To,
AmountCents}`. Dates: `DateLayout`, `DateOf`, `Today(loc)`, `ParseDate` ("2026-10-02" / "02.10.2026"),
`FormatDate`. Recurrence: `Frequency` (`weekly|monthly|yearly`, `.Valid()`, `.Label()`), `Frequencies`,
`Occurrence(f, anchor, n)`, `NextDate(f, anchor, after)` (first occurrence strictly after `after`, always from the
anchor: 31.01. → 28.02. → 31.03.). Rates: `FXRate{Currency, Date, Rate, Source}`, `FXSourceECB` ("ezb"),
`FXSourceManual` ("manuell"), `FXSourceFixed` ("fest").

### Package-specific

- **fx (B)**: `Rate` returns the rate in ECB format (foreign currency per 1 EUR) for the date or the last
  banking day before it; manual rates (`fx_rates.source = 'manuell'`) take precedence. EUR → rate 1,
  source "fest". `GET /api/kurs?waehrung=USD&datum=2026-10-01` (date optional = today, also "01.10.2026")
  → 200 `{"currency","date","rate","source"}` (`fx.RateResponse`), errors → 4xx/5xx `{"error": "…"}`.
  Phase 2: A computes `AmountCents = domain.ToEURCents(minor, cur, rate.Rate)` server-side via `d.FX`.
- **recurring (B)**: table `recurring` (`template_json` = `store.ExpenseInput` as JSON, its date
  ignored; `start_date` = anchor; `next_date` = next due occurrence; `active`). `Materialize(ctx, today)`
  creates, for every occurrence ≤ today, an expense via `store.CreateExpense(ctx, 0, in)` with `in.Date = occurrence`,
  `in.RecurringID = id` and sets `next_date = domain.NextDate(freq, start_date, occurrence)`.
  `store.ErrRecurringExists` (unique index `recurring_id, date`) means "already exists" → skip.
  Phase 2: the "wiederkehrend" (recurring) option in A's form calls a store function from `store/recurring.go`.
- **ynab (C)**: tables `ynab_config` (per person), `ynab_category_map`, `ynab_sync`. `New` attaches `Trigger`
  to the hook; `Run` syncs (create/PATCH/DELETE; `GetExpense` also returns deleted ones, my share =
  `e.ShareOf(participantID)`). Settings refer to `web.Me(ctx)`.
- **export (C)**: uses `ListExpenses`/`GetExpense`; downloads with `Content-Disposition: attachment`.
- **mcp (D)**: `d.Config.MCPSecret`, `d.Config.MCPAllowedCIDRs`, `d.Config.TrustedProxies` (`[]netip.Prefix`),
  helper `config.ContainsAddr(prefixes, addr)`. D builds the read-only connection in `store/mcp.go`
  from `s.Path()` (e.g. `file:<path>?mode=ro` + `_pragma=query_only(1)`, verify yourself); `:memory:` is unsuitable for it, tests
  use a temp file (`t.TempDir()`).
