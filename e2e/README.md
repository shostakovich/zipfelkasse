# E2E suite

A black-box test suite for the Zipfelkasse binary, written in Crystal (stdlib plus the sqlite3 shard). It starts the
binary with a fresh database, a frozen clock and fake ECB and YNAB servers, and talks to it like a browser (forms,
cookies, redirects) and like an MCP client.

```sh
shards build -Dtest_hooks
E2E_BIN=bin/zipfelkasse crystal spec e2e/
```

The binary must be built with `-Dtest_hooks`, otherwise the app ignores the test-only variables below.

Every HTML answer is also checked for injected `<script>` elements and `on*` attributes (the test data is full of
HTML special characters).

## Seed data

`E2E.seeded_world` is a household built through the app itself (`support/seed.cr`): six people (one archived),
custom and archived categories, about 870 expenses over 2.5 years in all split modes and seven foreign
currencies, edits, deletions, reimbursements, recurring rules (monthly, weekly, yearly, month end, leap day,
paused, deleted), manual exchange rates, MCP entries and a YNAB connection with category mapping and sync.
The seed runs in three phases with different frozen clocks so that timestamps and the YNAB selection behave
like in real use. It is built once per run, on first use, and shared by the read-only specs (`read_spec.cr`,
the seed part of `mcp_spec.cr`); nothing is cached between runs.

## Test-only environment variables

The app reads these only when built with `-Dtest_hooks`: `ZIPFELKASSE_TEST_NOW` (frozen clock),
`ZIPFELKASSE_TEST_ECB_URL`, `ZIPFELKASSE_TEST_YNAB_URL`, `ZIPFELKASSE_TEST_YNAB_DELAY_MS`.

Every world lives in a temporary directory that is removed at the end of the run; `E2E_KEEP=1` keeps them
(database and log of each world) and prints where.
