# Handoff: Crystal port of Zipfelkasse (state after the first session)

Written for the next Claude context. Read this first, then `docs/PORTING.md` (decisions, conventions, checklist).
Delete this file at the end of the port.

## Task and the user

- Robert (developer at CONSUST) wants Zipfelkasse ported from Go to **Crystal + Kemal**. Answer in **German**.
- The original prompt is in the plan of the first session; its essentials live in `docs/PORTING.md` ("Fixed rules",
  "Progress checklist"). Phases: 0 map Go → 1 E2E net against Go → 2 foundation → 3 port in waves with subagents
  and adversarial reviews → 4 E2E/diff green against Crystal, Docker, CI, remove Go, docs.
- Robert's clarifications during the session (binding):
  - **"1:1 not too literally"**: the app must be consistent and behave exactly as before, but Go runtime quirks
    and byte-level parity are not goals (see "Deliberate deviations" in PORTING.md).
  - **No Go compatibility layer** (`go_compat`) in the app: plain idiomatic Crystal; only real app logic (e.g.
    user-visible number formats like `1,0876`) as normal helpers in `Domain`.
  - Work with **subagents** (he asked explicitly); Phase 3 may be split further.
  - **Commit after each phase, on the extra worktree**, and push (push works since GitHub permissions were fixed).
  - No PR until he asks.

## Where things are

- Worktree (session cwd): `/home/user/zipfelkasse/.claude/worktrees/crystal`, branch `claude/sharp-dirac-5i8uew`,
  pushed to origin. The main checkout `/home/user/zipfelkasse` is on a detached HEAD; don't work there.
- The worktree guard refuses shell commands that are "too complex" (heredocs into interpreters, `$(...)` around
  crystal/git, `cd` elsewhere). Use the Write/Edit tools for files and plain commands; put scratch code in `tmp/`
  (gitignored) inside the worktree.
- Commits so far (newest last): Go test overrides · Go mapping (docs) · E2E harness + seed · seed via reference ·
  foundation (WIP) · FX/export E2E · Go fix for the ECB timer · several "Work in progress" snapshots (agents' files)
  · MCP E2E · "start removing the Go compatibility layer" (**does not compile**, see below).

## Environment (container, not persistent across sessions)

- Crystal 1.21.1 from the openSUSE repo (`download.opensuse.org/repositories/devel:/languages:/crystal/xUbuntu_24.04/`,
  .deb installed with apt). Shards: kemal 1.14.0, db 0.14.0, sqlite3 0.23.0 (`shards install`, GitHub clone via the
  git proxy works).
- **SQLite 3.53.4** built from sqlite.org into `/usr/local/lib` (same version Go's modernc driver embeds; Ubuntu's
  3.45 returns NULL for `strftime('%G-W%V')`). Crystal links it automatically.
- Docker: start the daemon with `dockerd` in the background. Builds that need the network inside a container need
  `--network host -e HTTPS_PROXY -v /root/.ccr/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro`.
  A static Kemal + SQLite hello world built fine in `crystallang/crystal:1.21.1-alpine` with `sqlite-static`.
- Go reference binaries: `go build -o /tmp/zk-go . && cp /tmp/zk-go /tmp/zk-go-ref` (rebuild after Go changes).

## Done

- **Phase 0**: `docs/PORTING.md` (index, decisions, deviations, conventions, checklist) and `docs/porting/*.md`
  (per-package inventories with routes, SQL, algorithms, texts, test lists, pitfalls; `probes/` = Go's exact output).
- **Go changes** (test-only, production unchanged): `ZIPFELKASSE_TEST_NOW` (frozen clock), `ZIPFELKASSE_TEST_ECB_URL`,
  `ZIPFELKASSE_TEST_YNAB_URL`, `ZIPFELKASSE_TEST_YNAB_DELAY` (config.Config + wiring), and the ECB timer fix in
  `internal/fx/fx.go` (wait measured with the service clock; otherwise a tight download loop under a frozen clock).
  The Crystal port must implement the same overrides and the same timer logic.
- **Phase 1 – E2E suite** (`e2e/`, see `e2e/README.md`): 108 examples, green against Go, and Go vs Go in diff mode
  with 0 differences (full run ~2.5 min). Files: `seed_spec`, `read_spec` (crawl of everything on the seed),
  `compare_spec` (unit tests of the comparison), `web_spec`, `mcp_spec`, `fx_export_spec`, `recurring_ynab_spec`,
  helpers in `e2e/support/`. Seed = realistic household built through the app (≈870 expenses, all features, XSS
  data), built by the reference binary when there is one and cached as `e2e/data/seed-<hash>.db`.
  Run: `E2E_BIN=/tmp/zk-go crystal spec e2e/` and with `E2E_REF_BIN=/tmp/zk-go-ref` for diff mode.
- **Phase 2 – foundation** (written, partly tested, not yet compiled as a whole):
  - `src/zipfelkasse.cr` (entry), `all.cr` (requires), `app.cr` (App wiring, CLI serve/healthcheck, backup loop,
    graceful shutdown, `App.wire_<feature>` hook per package), `config/config.cr` (+ spec, green), `logger.cr`
    (slog-like lines), `stopper.cr` (shutdown signal for jobs).
  - `store/`: `store.cr` (pool with Go's PRAGMAs, `transaction` = BEGIN IMMEDIATE behind a fiber-aware write mutex,
    migrations from `internal/store/migrations` + `GO_MIGRATIONS` registry for data migrations 2/4/5, extended error
    codes, `unique_violation?`), `lib_sqlite.cr` (extra FFI + **patch for crystal-sqlite3's finalize check**, which
    otherwise raises on close after any failed statement), `fold.cr`, `backup.cr`, `settings.cr`,
    `participants.cr`, `activity.cr`. Store core was tested against the Go seed DB (opens at version 5, fold works).
  - `web/`: `ecr_process.cr` + `html.cr` (our ECR front end: `<%= %>` escapes, `<%== %>` raw, `<%-`/`-%>` trim like
    Go's `{{-`/`-}}`; tested), `deps.cr` (Deps, Request helpers, cookies, redirect, HTTPError), `render.cr`
    (Renderer, Page, Helpers = the FuncMap), `static.cr` (embedded `internal/web/static`, hashes), `middleware.cr`
    (security headers, MCP mount, body limit, cross-origin, identity, `safe_return`), `server.cr` (ErrorHandler
    incl. 404/405, Kemal chain), `web.cr` (route helper, healthz, static, who page), `pwa.cr`.
  - Views: `src/views/layout.ecr`, `src/views/web/{error,who}.ecr`.
  - `Dockerfile.crystal` (static Alpine build → scratch; replaces `Dockerfile` in phase 4).
- **domain** ported by a subagent (all Go test cases as specs) — but on top of a GoCompat layer.

## Open right now (resume here)

1. **Finish removing GoCompat** (Robert's decision). State: `go_compat/json.cr` and `time.cr` deleted; still
   referencing `GoCompat::JSON`: `store/activity.cr` (details_json → use `JSON.build`, keep omitempty), `web/pwa.cr`
   (manifest), `web/deps.cr` (`Request#json` should yield a `JSON::Builder` and add a trailing newline).
   The domain agent was stopped mid-conversion: check `src/zipfelkasse/domain/*.cr` and `spec/domain/*`, replace
   remaining `GoCompat.*` calls (`fields`/`trim_space` → `split`/`strip`, `to_lower` → `downcase`, `quote` →
   `inspect`, `parse_float`/`parse_int` → `to_f?`/`to_i64?` with the app's validation, `format_float` → a private
   helper in `domain/money.cr` for `format_rate`), then delete `src/zipfelkasse/go_compat/` and `spec/go_compat/`.
2. **E2E**: make `Snapshot.content` compare `*_json` columns structurally (parse + canonicalise, e.g. with
   `Compare.json`) instead of byte-wise, since Crystal's JSON bytes differ from Go's.
3. Get the foundation to compile: `crystal build src/zipfelkasse.cr -o bin/zipfelkasse` and `crystal spec`.
   Known issue: `app.cr` passes `self` before `@handlers` is set → initialise `@handlers` at declaration.
   Then smoke-test: start the binary, `/healthz`, `/wer`, create a person (it can't pass `App#start`'s ECB wait until
   `fx` is ported; use `World.new(..., wait_for_rates: false)` or curl).
4. Commit phase 2, push.
5. **Phase 3** (subagents, disjoint folders, each ports the Go tests as specs, then self-review against Go):
   - Wave 1 (store, after domain compiles): define shared store types first (Expense, ExpenseInput, Category, filters)
     so agents can work in parallel; then S1 = expenses/categories/web.go/resplit/amountweights (+ store_test,
     web_test, activity_test), S2 = fx/recurring/ynab/ynabstate (+ tests), S3 = mcp.go (+ mcp_test).
   - Wave 2: web pages (expenses, balances, activity, settings, format/suggest), fx, recurring, ynab, export, mcp
     (big: split transport/tools). Each feature package hooks in via `App.wire_<name>`.
   - After each wave: an adversarial review agent compares with Go (rounding, cent arithmetic, dates/time zones,
     sorting/collation, texts, escaping), fixes, then E2E against the Crystal binary.
6. Phase 4 as in PORTING.md, **plus Robert's final requirement**: at the very end, remove all migration
   scaffolding so that only clean tests remain that one would have written without a migration:
   - remove the diff mode and everything about a reference binary (`E2E_REF_BIN`, `World` with two apps,
     `Compare`/`DOM` canonicalisation, `compare_spec.cr`, the "built by the reference" seed logic),
   - remove `docs/porting/` (inventories, probes), `docs/PORTING.md`, this handoff, Go-related wording in specs
     and comments ("like Go", "Go's …"),
   - keep the E2E scenarios as plain black-box tests with assertions (fakes for ECB/YNAB and the frozen clock
     stay, they are normal test infrastructure), and the unit specs as normal Crystal specs.

## Findings worth remembering

- Frozen clock pitfalls: every expense created in the same phase as the YNAB connection counts as "entered after
  connecting" (the seed therefore runs in three phases with restarts); cooldowns/caches never expire.
- Go accepts underscores in `ParseFloat` ("1_000"); SQLite NOCASE folds ASCII only ("jÖRG" ≠ "Jörg"); equal split
  of 890 ct over 4 people gives 223/222/222/223 (rotation); unknown IDs in `teil` are dropped silently; every
  rendered page (also 403/413) consumes the flash cookie.
- Crystal: `Float#round` is ties-even (use `:ties_away`), `//`/`%` floor (use `tdiv`/`remainder`), overflow raises,
  `Float#to_s` uses exponents; `HTTP::Client` has no proxy support (deviation noted in PORTING.md "Later").
- Real data (read via the Zipfelkasse MCP, aggregates only): 2 people, 766 entries since 2024-02, almost all equal
  splits in EUR, 1 monthly recurring rule. No real data was copied anywhere.
