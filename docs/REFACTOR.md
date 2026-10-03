# Refactor: from a Go port to idiomatic Crystal + Kemal

Temporary working document for the refactor waves; delete it when the refactor is done.

The port kept Go's shape because an E2E diff against the Go binary demanded identical bytes. That diff is
gone. Goal now: a clean Crystal/Kemal app that does the same things with less code. Finding IDs (B…, G…,
C…, S…, T…, D…) refer to the review page; a copy lives at
`/private/tmp/claude-501/-Users-shostakovich-Code-zipfelkasse--claude-worktrees-zipfelkasse-go-crystal-78337b/ff6dc48e-67ef-4457-b5f8-a0dcbf93c2bb/scratchpad/zipfelkasse-crystal-review.html`
(read it for details on any ID).

## Ground rules

- Everything in the repo is English (identifiers, comments, test names, commits, docs, MCP interface). German is
  only the web UI text, URL paths and form field names.
- Almost no comments. A comment is a missing name or test. Keep only comments that record a non-obvious
  decision or trap. No file header comments, no "the old code did…", no comments above single expressions.
  This applies to every line you touch.
- Shards: kemal, db, sqlite3 only. No new shards.
- Behaviour that users see stays: UI texts, URLs, form fields, MCP tool names and semantics, the values in
  exports, the stored data. Exact bytes do not matter (no Go formatting parity). Every intentional behaviour
  change is named in the commit message.
- The E2E suite is the safety net. Update an E2E assertion only where behaviour changes on purpose; replace
  byte assertions by value assertions; never weaken an assertion just to get green.
- Before every commit: `crystal tool format --check`, `crystal spec`, and the E2E suite are green.
- Small, logical commits. Message style: imperative sentence ("Read query results with DB::Serializable"),
  a short body when useful, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.

## Decisions

1. **Schema squash.** The production DB is at `user_version` 5. `store/migrations/` becomes one
   `schema.sql` with the current schema (same tables, columns, constraints, indexes as a fresh DB migrated
   by today's code). A DB at version 0 gets the schema and version 5; 5 is accepted; 1–4 and anything above
   the latest known version are rejected with a clear error. Future migrations are numbered SQL files from 6
   on. The data migrations (`resplit.cr`, `amountweights.cr`, `ynabstate.cr`) and their specs go.
   Verify: `.schema` of a fresh DB equals the old fresh schema (modulo whitespace and column order inside
   ynab_config is allowed to become the natural CREATE order), and the production copy in
   `data/prod/zipfelkasse.db` opens, serves every page and passes the read-only crawl.
2. **Exports.** Values matter, bytes don't: `CSV.build`, Crystal's JSON numbers, `null` for missing times.
3. **Test hooks.** `Config.from_env` reads the `ZIPFELKASSE_TEST_*` variables only when compiled with
   `-Dtest_hooks`. The config properties themselves (frozen clock, ECB URL, YNAB URL, YNAB delay) stay
   ordinary injectable config, so specs keep using them without the flag. The E2E binary and
   `.claude/launch.json` build with `-Dtest_hooks`; the release image does not. `ZIPFELKASSE_TEST_YNAB_DELAY`
   becomes `ZIPFELKASSE_TEST_YNAB_DELAY_MS` (integer).
4. **Kemal, consistently.** Routes with Kemal's `get`/`post` DSL, `before_all`/`before_*` filters with
   `halt`, `env.redirect`, `Kemal.config.max_request_body_size`, Kemal's exceptions mapped to 400/413. Kemal is
   no longer fought (`reset_kemal`, hand-written body limit, hand-written redirect). Keep what Kemal lacks:
   auto-escaping templates (`ecr_process.cr`), `TimeoutServer`, the quiet error handler, embedded static files.
5. **Logging** with `::Log` and a small logfmt formatter, `Log = ::Log.for(self)` per module; no own logger
   class, no `log` passed through layers.
6. **Absent values are `nil`.** `Int64?`/`Time?` instead of `0`, `""` and `0001-01-01`. Closed sets are
   enums (the DB keeps its strings).

## Waves and packages

Each package runs in its own git worktree on its own branch; the coordinator merges. Packages in the same
wave own disjoint files; where they must meet, the contract is stated.

### Wave 1

**W1-A Foundation** — `domain/`, `config/`, `logger.cr`, `store/` (incl. migrations, lib_sqlite), `all.cr`,
the entry point, plus mechanical caller updates anywhere so it compiles, plus the matching unit specs.
- Decisions 1, 3, 5, 6 (store/domain side; callers adapted mechanically).
- C1 enums: SplitMode, Frequency, statistics grouping, expense sort, activity Action, FXSource (DB strings
  stay `ezb`/`manuell`/`fest`). Domain keeps no German display labels; move `label`/`adverb` to
  `web/format.cr`.
- C2 `query_all(as:)`/`query_one?(as:)`/`DB::Serializable` with a time converter; C6 store side
  (`on_duplicate`, `get_x?` vs `get_x`); C7 one `get_x(id, db = @db)`; C9/C10 records, build expenses once.
- G3 `UNSET_TIME` gone; G9 squash; G10 `Time#shift`; G7/G8 SQLite glue minimal (keep what is needed and say
  why in one line); G17 own error messages for CIDRs, no `parse_duration`; G18 `cause:`; G19 no
  `Int64::MIN` contract; G20 `ActivityDetails` via `JSON::Serializable`; G25/G27 dead code and config
  cleanup (`frozen_now`, no duplicate defaults).
- S1: split `store/mcp.cr` into the read-only SQL sandbox (`src/zipfelkasse/mcp/sql_sandbox.cr`, class
  `MCP::SQLSandbox`, needs only the DB path), `store/stats.cr`, and `domain/period.cr` (pure period
  arithmetic). Store no longer says "MCP" (`EXPOSED_TABLES`, `schema`, `overview`). Keep the sandbox
  internals as they are; W2-B simplifies them.
- S2: dissolve `store/web.cr` and `store/types.cr` into the files their queries belong to; SQLite glue in
  one `store/sqlite.cr`.
- B2 (reject unknown/old schema versions), B3 (`YNABConfig#inspect` redacts the token), B13, B14, B19
  (backup files `0600`), D7 (no Go names in SQL comments).

**W1-B Harness and infra** — `e2e/` harness (`support/`, `seed_spec.cr`, `read_spec.cr`, one-line fixes in
other E2E specs), `README.md`, `e2e/README.md`, `Dockerfile`, `.dockerignore`, `.github/workflows/ci.yml`,
`.gitignore`, `.claude/launch.json`.
- T2 seed built once per process in a temp dir (no cross-process cache, no `Snapshot.copy`, no
  `FakeYNAB#dump/load`); T3 replace `seed_spec.cr` and the status-only checks in `read_spec.cr` by
  invariants on the shared seed (shares sum to amount, balances sum to 0, CSV rows = expenses, YNAB fake
  live transactions = selection, …); T4 no `level=ERROR`/"Unhandled exception" in the app log unless a
  scenario expects it; T5 new scenarios: graceful shutdown (exit code 0, log line), nightly backup (frozen
  clock just before 03:00), startup errors; T7 document the shared-world order dependency; T8 drop
  `E2E_SEED_DB`; T11 shorter waits; T12 dead harness code, `Snapshot` → `Database`, no mutexes in fakes,
  one raw-socket helper; T13 English test values (`secret`, `wrong`, `broken`, `REJECT`); T14.
- Decision 3 on the build side: E2E binary via `shards build -Dtest_hooks` (verify the syntax) or
  `crystal build -Dtest_hooks`, documented in both READMEs and CI; launch.json uses a `-Dtest_hooks` build.
  W1-A implements the flag in `config.cr`; until merged, keep both working.
- D1 `shards build` in README/CI; D3 track `.claude/launch.json` (English configuration name), ignore the rest
  of `.claude/`; D5 `COPY src ./src` after `shards install`, complete `.dockerignore`, one-line reason for
  `/tmp`; D6 CI cache for `lib/` and the Crystal cache keyed on `shard.lock`, `shards install --frozen`, unit
  and E2E as parallel jobs, `concurrency` cancel; D8 `flavor: latest=false` so `latest` follows main only;
  D9 README links `e2e/README.md`, libxml2 note, small fixes.

### Wave 2 (after wave 1 is merged)

**W2-A Web on Kemal** — `web/`, `src/views/`, `app.cr`, `mcp/mcp.cr` (HTTP entry and mounting),
`fx/handlers.cr`, `recurring/handlers.cr`, `ynab/handlers.cr`, `export/export.cr`, `fx/fx.cr` and
`recurring/recurring.cr` only where they mix in web helpers, plus web specs and the E2E expectations for
changed behaviour.
- Decision 4. G1/S4 explicit wiring in `App`, no `has_method?`, non-nil `fx`. Routes via Kemal DSL,
  identity/CSRF/security headers as filters, MCP route bypasses the browser filters.
- C4 views as records with auto-escaped templates (no ambient locals, no `__io__` in templates, no
  `Web::Helpers` in services); S3 every feature has a service (logic) and handlers (HTTP); S7 English view
  file names.
- G11 Kemal body limit (also covers MCP; one `drain` only where needed), G12 `env.redirect`, G21 unknown web
  URLs get the German error page (plain text only under `/mcp/`), G22 POST reads the body only, G23 ETag/304
  from the static hashes and no `Accept-Ranges`, G24, G14 manifest and suggestions via `to_json`, C6 web
  side (`or_404`), C9 `ExpenseForm` as record without side effects, C12 web parts, C14 graceful shutdown
  waits for in-flight requests.
- B4, B5, B6, B7, B11, B12, B20 (web parts), B21, B24, B25.

**W2-B MCP, YNAB, export formats** — `mcp/` except `mcp.cr`, `ynab/` except `handlers.cr`,
`export/formats.cr`, `fx/ecb.cr` only for the shared HTTP client helper, `store/ynab.cr`, plus their specs and
E2E expectations.
- C3 `handle_post` linear with `RPCError(status)`; C5 tool output via `JSON::Serializable` records or small
  builder helpers, schema helpers, prompts from text files via `read_file`; C1 enums for choice arguments;
  G2 `nil` instead of 0/"" in tool arguments (schema minimums enforced); G5 no Go float formatting; G6
  simpler sandbox query; G14 no sorted keys/`@order`/`JSON.parse(to_json)`; G16 no semaphore; G26 shared
  HTTP client helper (`ynab/client.cr`, `fx/ecb.cr`), `parse_decimal` reuses the domain parser,
  `REIMBURSEMENT_TITLE`.
- C8/G15 YNAB: `Outcome` record, `Failure` enum, a `Run` object, `YNABSync` state predicates, pure diff
  planning (`Plan.build`) with unit specs, one fingerprint formula.
- B1 double booking: resolve pending rows without the start-date cut (or store the posted date); a missing
  `data` envelope is an unclear outcome, never an empty list. Add a spec that reproduces the scenario first.
- B8 shorter SQL timeout and a sentence in `docs/MCP.md`; B15 no writes from the export; B16 length checks in
  the MCP write tool; B17 MCP entries marked in the activity details; B18 no draining for rejected requests
  (with W2-A); D2 `docs/MCP.md` matches the code.
- Export formats: `CSV.build`, OFX as one template, `'\u{FEFF}'`, `null` for missing times.
- **Contract with W2-A:** the public methods of `YNAB::Service` that `ynab/handlers.cr` calls at the start of
  wave 2 keep their names and signatures; `MCP` keeps the entry points `mcp.cr` calls. Anything else is free.

### Wave 3

**W3 Unit specs** — `spec/`, shared test support with `e2e/`.
- T1 drop HTTP-level unit specs that the E2E suite covers more strictly, after moving their unique edge cases
  to domain/store specs; T6 one `FakeYNAB`, one `FakeECB` (without `SwitchableECB`), shared fixtures in
  `spec/support/` used by `spec_helper.cr` and `e2e_helper.cr`; T9 rest; T10 `around_each`,
  `expect_raises(...).message`, custom matchers, full-sentence test names, one alias block.

### Then

Review per package (subagents), fixes, docs check, delete this file.

## Wave 1 outcome (merged)

State: `crystal spec` 371 green, E2E 115 green + 1 pending (nightly backup, see below). Build the E2E binary
with `shards build -Dtest_hooks`.

Contract from W1-A, use it as is:
- Logging: `Log = ::Log.for(self)` in `Zipfelkasse`, `Web`, `MCP`, `FX`, `YNAB`, `Recurring`, `Store`;
  `Log.info(&.emit("msg", k: v))`, `Log.error(exception: ex) { "msg" }`; `Zipfelkasse.setup_logging(io)`.
  No `Deps#log`; `App.new(config, store)`.
- Config: `Config::TEST_HOOKS`, `Config#read_test_hooks(env)`, `Config#now` (frozen or `Time.utc`),
  `backup_dir` derived from `db_path`.
- Store: `Store::Error`, `get_x?(id, db = @db)`/`get_x(id, db = @db)`, `Store.on_duplicate`,
  `Store.format_time`, `Store.check_affected`, `actor_id : Int64?` (nil = system). DB converters
  `Zipfelkasse::Store::{TimeText,DateText,EnumText(T),FXSourceText,JSONText(T),SecondsSpan}` (fully
  qualified in `DB::Field`).
- Enums with `key`/`from_key?`: `Domain::SplitMode`, `Domain::Frequency`, `Domain::FXSource`
  (`ezb`/`manuell`/`fest`), `Domain::PeriodUnit`, `Store::Action`, `Store::ExpenseSort`, `Store::StatsGroup`.
  German labels: `Web.split_mode_label`, `Web.frequency_label`, `Web.frequency_adverb`.
- Records: `Store::Expense` (flat, `shares`, `category_name : String?`, `reimbursement?`, `to_input`),
  `ExpenseFilter`/`StatsFilter` with nilable fields and `copy_with`, `StatRow` nilable, `Recurring#template`
  is an `ExpenseInput` (`paid_by : Int64?`, `fx_rate : Float64?`, `fx_source : FXSource?`).
- MCP: `MCP::SQLSandbox.new(path).query(sql)`, `Store::EXPOSED_TABLES`, `Store#schema`, `Store#overview`,
  `Store.fill_periods`, `Domain::Period`.

Left over from wave 1, now part of wave 2:
- W2-A: `ExpenseForm`/`HomeFilter` still use 0/"" (remove the bridges `Web.nil_if_zero`, `Web.form_id?`);
  `Store.format_date` vs `Domain.format_date` naming (C13); **bug: `App.backup_loop` uses the real clock
  (`Time.local`) instead of `config.now`** — fix it so one run per day happens even with a frozen clock, then
  turn the pending scenario in `e2e/process_spec.cr` into a real one and also assert the backup file mode
  `0600` (B19).
- W2-B: MCP tool arguments still use 0/""; `YNABStatus`/`YNABSync` still use "" for absent values and are
  mutable structs; `set_ynab_token(reachable:)` callback (G27); `docs/MCP.md` still says `store.MCPTables`
  (D2).
