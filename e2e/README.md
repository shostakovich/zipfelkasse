# E2E suite

A black-box test suite for the Zipfelkasse binary, written in Crystal (stdlib plus the sqlite3 shard). It starts the
binary with a fresh database, a frozen clock and fake ECB and YNAB servers, and talks to it like a browser (forms,
cookies, redirects) and like an MCP client.

```sh
crystal build -o bin/zipfelkasse src/zipfelkasse.cr
E2E_BIN=bin/zipfelkasse crystal spec e2e/
```

Every HTML answer is also checked for injected `<script>` elements and `on*` attributes (the test data is full of
HTML special characters).

## Seed data

`E2E.seed_db` builds a household through the app itself (`support/seed.cr`): six people (one archived), custom and
archived categories, about 870 expenses over 2.5 years in all split modes and seven currencies, edits, deletions,
reimbursements, recurring rules (monthly, weekly, yearly, month end, leap day, paused, deleted), manual exchange
rates, MCP entries and a YNAB connection with category mapping and sync. The seed runs in three phases with
different frozen clocks so that timestamps and the YNAB selection behave like in real use. It is cached in
`e2e/data/` per binary.

`E2E_SEED_DB=/path/to/backup.db` runs the read-only crawl (`read_spec.cr`) on another database, e.g. a backup of
real data. Never commit such a file; `e2e/data/` is ignored by git.

## Test-only environment variables

The app reads these only for the suite: `ZIPFELKASSE_TEST_NOW` (frozen clock), `ZIPFELKASSE_TEST_ECB_URL`,
`ZIPFELKASSE_TEST_YNAB_URL`, `ZIPFELKASSE_TEST_YNAB_DELAY`.

`E2E_KEEP=1` keeps the database and log of each run under `e2e/data/worlds/`.
