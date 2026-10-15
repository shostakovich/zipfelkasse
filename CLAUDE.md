# CLAUDE.md – Zipfelkasse

Shared household expenses (one group, no login: you pick who you are), Phoenix LiveView on SQLite. UI text
is German; code, comments and docs English, sparse comments: only a non-obvious why. Decisions: `DECISIONS.md`.

## Validation

```
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test --warnings-as-errors
```

CI runs the same plus `mix assets.setup && mix assets.deploy`. Erlang/Elixir versions: `.tool-versions`.

## Conventions

- Schemas `use Zipfelkasse.Schema` (`:utc_datetime_usec` timestamps). Migrations are recorded in
  production: add new ones, leave old ones as they are; releases run them via `Release.migrate/0`.
- DB tests run synchronously with `pool_size: 1` (SQLite is busy otherwise). Tests are mostly fast unit
  tests of pure modules; outside services are faked by Bandit stub servers that tests point at via
  `base_url`. `config/test.exs` turns the background jobs off (`jobs: false`).
- Money is integer cents; local time is the host's `TZ` (no time zone database).
- UI: Setzkasten components (Tailwind 4, daisyUI 5) via `use Setzkasten`; app-specific styles only in
  `assets/css/app.css`; Lucide icons in `assets/vendor/lucide`. A gap or bug in Setzkasten is fixed in
  Setzkasten, not worked around in the app.
- Pages assign their whole title with `Layouts.page_title/1`.
- The strict CSP allows no inline scripts or styles; an inline script carries `@csp_nonce`.
- Dependencies: few and mature, each with a reason.

## Running locally

- Dev reads `DATABASE_PATH` (another SQLite file) and `YNAB_BASE_URL` (another YNAB address); with
  `DATABASE_PATH` but no `YNAB_BASE_URL`, YNAB is the dead address `http://127.0.0.1:9`.
- `.claude/launch.json`: `zipfelkasse` is the dev server; `zipfelkasse-production-copy` serves a copy of
  `data/prod/zipfelkasse.sqlite3` on port 4001 with YNAB at a dead address.
