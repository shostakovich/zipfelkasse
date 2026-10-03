# Porting Zipfelkasse from Go to Crystal + Kemal

Goal: the same app, written in Crystal. Users must not notice the switch: same pages, texts, forms,
calculations, data, MCP answers, exports, env vars and deployment. The database schema does not
change; Crystal opens a database created by Go without any migration.

"1:1" means **same behaviour**, not byte-identical output of Go runtime quirks. Where Go's standard
library does something by accident (e.g. its file server's directory listings), the port may differ;
such deviations are listed below under "Deliberate deviations".

This file is the index and the progress checklist. The detailed inventories (written from the Go
code in phase 0) live in `docs/porting/`:

| File | Covers |
|---|---|
| [porting/web.md](porting/web.md) | `main.go`, `internal/config`, `internal/web`: routes, middleware, cookies, templates, FuncMap, escaping, static files, PWA, CLI, logging, time zones |
| [porting/store_domain.md](porting/store_domain.md) | `internal/store`, `internal/domain`: driver/PRAGMAs, migrations, schema, every store function with its SQL, money/split/settle algorithms, backups |
| [porting/mcp_export.md](porting/mcp_export.md) | `internal/mcp`, `internal/store/mcp.go`, `internal/export`: transport, all tools, JSON rules, sql_query sandbox, CSV/JSON/OFX |
| [porting/jobs.md](porting/jobs.md) | `internal/fx`, `internal/recurring`, `internal/ynab` (+ their store files): jobs, external HTTP, routes, algorithms |

Each inventory ends with a test list and a "pitfalls" section. Read the pitfalls before porting a
package.

## Fixed rules

1. Schema unchanged. `internal/store/migrations/*.sql` are copied byte for byte (the CREATE text,
   comments included, ends up in `sqlite_schema` and in the MCP `schema` tool). Migration bookkeeping
   is `PRAGMA user_version` only; SQL migrations 1 and 3 and Go data migrations 2, 4, 5 share the
   numbering. Crystal ports all five.
2. Same functionality: routes, form field names, redirects, status codes, cookies, CLI, env vars,
   jobs, MCP, export, PWA. UI texts German, code comments English. No new features.
3. Dependencies: only the shards `kemal`, `db`, `sqlite3`. Everything else from the stdlib.
4. Escaping is the default (see Conventions).
5. Deployment as before: static binary, `FROM scratch`, same healthcheck, ENV defaults, user 65532,
   `VOLUME /data`; static files byte-identical and embedded.
6. Idiomatic, short Crystal; errors via exceptions and one central error handler;
   `crystal tool format --check` clean.

## Decisions (phase 0)

- **SQLite version.** Go embeds SQLite 3.53.4. Stats by week use `strftime('%G-W%V')`, which needs
  SQLite >= 3.46 (3.45 returns NULL). Ubuntu 24.04 ships 3.45.1, so local development links a
  self-built 3.53.4 (`/usr/local/lib`); the Docker build uses Alpine's `sqlite-static`.
- **Transactions.** Go runs every transaction as `BEGIN IMMEDIATE`. Crystal does the same through its
  own `Store#transaction` helper (crystal-db only sends a deferred `BEGIN`). Additionally a
  fiber-aware write mutex serialises write transactions inside the process: Crystal runs on one
  thread, and SQLite's busy handler sleeps inside C, so two fibers waiting on each other's write lock
  would otherwise freeze the whole server for `busy_timeout`.
- **Multi-statement SQL** (migrations) runs through `sqlite3_exec`; crystal-sqlite3's `exec` only
  runs the first statement.
- **Custom SQL function** `zipfelkasse_fold` is registered on every connection (and on the MCP
  sandbox connection) through FFI.
- **sql_query timeout** uses `sqlite3_progress_handler` with a deadline (a timer fiber cannot
  interrupt a blocking C call on one thread).
- **Stored JSON** (`activity.details_json`, `recurring.template_json`) is written exactly like Go's
  `encoding/json` (key order, `omitempty`, `<>&` escaped as `<…`, floats like `1` not `1.0`), so
  rows written by Go and Crystal are indistinguishable.
- **Test-only overrides** (added to the Go app in its own commit, ported identically):
  `ZIPFELKASSE_TEST_NOW` (frozen clock, RFC 3339), `ZIPFELKASSE_TEST_ECB_URL`,
  `ZIPFELKASSE_TEST_YNAB_URL`, `ZIPFELKASSE_TEST_YNAB_DELAY`. Unset in production.

## Deliberate deviations (behaviour of Go's runtime, not of the app)

| Go | Crystal | Why it is fine |
|---|---|---|
| `html/template` writes `&#34;`, `&#39;`, `&#43;` | standard entities (`&quot;`, `&#39;`, `+` unescaped where safe) | identical DOM; the E2E diff compares decoded DOM trees |
| Root mux cleans paths with a 307 (`//salden` → `/salden`), `/mcp` → 307 `/mcp/` | plain 404 for unclean paths | browsers and the app never produce such paths |
| `/static/` and `/static/icons/` show a directory listing; `/static/index.html` → 301 | 404 | not a feature |
| A panic aborts the connection without a response | central error handler renders the 500 page | friendlier, error path only |
| Go-specific JSON decoder messages in MCP errors (`json: cannot unmarshal …`) | equivalent German/English messages from the Crystal decoder | tests only check `isError` and the field name |
| `HTTPS_PROXY` is honoured for ECB/YNAB requests | not supported by Crystal's `HTTP::Client` | see "Later" |
| slog text log lines | same format (`time=… level=… msg=… k=v`), best effort | logs are not an interface |

## Later (noticed while porting, not changed)

- Outbound HTTP through a proxy (`HTTPS_PROXY`) is not supported by the Crystal port.

## Progress checklist

- [x] Phase 0: inventories in `docs/porting/`, this file
- [x] Test-only overrides in Go (commit `Add test-only overrides for the E2E suite`)
- [ ] Phase 1: E2E suite (`e2e/`) green against the Go binary, seed data, diff mode, compatibility test
- [ ] Phase 2: foundation (shard.yml, layout, config, CLI, DB + migrations, Kemal, escaping, assets,
      error handling, logging, Dockerfile, conventions below)
- [ ] Phase 3, wave 1: `domain` → `store`
- [ ] Phase 3, wave 2: `web`, `mcp`, `ynab`, `fx`, `export`, `recurring`
- [ ] Phase 3 reviews after each wave
- [ ] Phase 4: E2E + diff green against Crystal, Docker, CI, remove Go, docs

## Conventions

### Layout and names

| Go | Crystal |
|---|---|
| `main.go` | `src/zipfelkasse.cr` (entry point, CLI) |
| `internal/<pkg>/<file>.go` | `src/zipfelkasse/<pkg>/<file>.cr` (same file split) |
| `internal/<pkg>/<file>_test.go` | `spec/<pkg>/<file>_spec.cr` (same cases) |
| `internal/<pkg>/templates/*.html` | `src/views/<pkg>/*.ecr` |
| package `domain`, `store`, `web`, `fx`, … | `Zipfelkasse::Domain`, `Zipfelkasse::Store` (a class), `Zipfelkasse::Web`, `Zipfelkasse::FX`, `Zipfelkasse::Recurring`, `Zipfelkasse::YNAB`, `Zipfelkasse::Export`, `Zipfelkasse::MCP`, `Zipfelkasse::Config` |
| exported `FormatCents` | `format_cents` (snake_case methods, CamelCase types) |
| static files, migrations | stay where they are (`internal/web/static`, `internal/store/migrations`) until Go is removed; embedded at compile time |

Each package gets its own folder; agents only write inside their folders (plus their specs).

### Go semantics that Crystal does differently

Helpers live in `src/zipfelkasse/go_compat/` (`Zipfelkasse::GoCompat`); use them instead of ad-hoc code:

- **Whitespace**: Go's `unicode.IsSpace` includes U+0085; Crystal's `Char#whitespace?` does not. Use
  `GoCompat.space?`, `GoCompat.fields`, `GoCompat.trim_space` where Go uses `strings.Fields`/`TrimSpace`.
- **Lower case**: Go's `strings.ToLower` maps rune by rune (`İ` → `i`). Use `GoCompat.to_lower`.
- **Floats**: `GoCompat.format_float(f)` = `strconv.FormatFloat(f, 'f', -1, 64)` (shortest digits, never an
  exponent, no `.0`). JSON floats like Go: `GoCompat.json_float`.
- **JSON written to the database or to clients**: `GoCompat::JSON` writes like `encoding/json` (key order as
  given, `<>&` escaped as `<…` when `html: true`, U+2028/2029 always escaped, floats like Go).
- **Integer division/modulo on possibly negative numbers**: Go truncates; use `tdiv` / `remainder`, not
  `//` / `%`. Go wraps on overflow; Crystal raises. Use `Int128` or wrapping ops (`&+`) where Go relies on it.
- **Rounding**: `math.Round` is half away from zero: `round(:ties_away)` (Crystal's default is ties-to-even).
- **Dates**: calendar dates are `Time` at UTC midnight (`Time.utc(y, m, d)`); "not set" is `nil`
  (`Time?`), written as Go's zero time `0001-01-01T00:00:00Z` where Go stores it in JSON. Timestamps are
  written as RFC 3339 UTC without fraction (`2026-10-03T10:00:00Z`).
- **Strings in error messages** quoted with Go's `%q`: `GoCompat.quote`.
- **Rune counts**: `String#size` (code points) equals Go's `len([]rune(s))`; byte counts are `bytesize`.

### Errors

- `Domain::ValidationError` (message shown to the user, German) — handlers render the form again with 422.
- `Store::NotFound`, and per feature further specific errors where Go has sentinel errors.
- `Web::HTTPError.new(status, message)` renders the German error page with that status; any other exception
  reaches the central handler: logged, then the 500 page "Da ist etwas schiefgegangen.".

### HTML and escaping

Templates are ECR files compiled with `Web.render` (our own ECR front end): `<%= x %>` is **always HTML-escaped**
(`&`, `<`, `>`, `"`, `'`); raw output only with `<%== x %>` or values of type `Web::SafeHTML` (the `icon`
helper). Never build HTML by string concatenation in Crystal code. Whitespace of the Go templates is kept
where it is visible (between inline elements); `-%>`/`<%-` trim like Go's `{{-`/`-}}`.

### Tests

- Port each Go test file case by case to `spec/<pkg>/<file>_spec.cr`. `crystal spec` must be green.
- The E2E suite (`e2e/`) runs the built binary; see `e2e/README.md`.
