# E2E suite

A black-box test suite for the Zipfelkasse binary, written in Crystal (stdlib plus the sqlite3 shard). It starts the
binary with a fresh database, a frozen clock and fake ECB and YNAB servers, and talks to it like a browser (forms,
cookies, redirects) and like an MCP client.

```sh
shards build -Dtest_hooks
E2E_BIN=bin/zipfelkasse crystal spec e2e/
```

The binary must be built with `-Dtest_hooks`, otherwise the app ignores the test-only variables below. The suite
needs the libxml2 development files (it parses the HTML answers with Crystal's `XML` module) and runs for about
half a minute.

Every HTML answer is also checked for injected `<script>` elements and `on*` attributes (the test data is full of
HTML special characters), and a scenario fails if the app logged `level=ERROR` or an unhandled exception while it
ran (`scenario "…", world, errors: ["substring"]` allows errors a scenario provokes on purpose).

## Layout

- `web_spec.cr`, `fx_export_spec.cr`, `recurring_ynab_spec.cr`, `mcp_spec.cr`: the features, each `describe` in its
  own small world with an empty database.
- `process_spec.cr`: the process itself: graceful shutdown, startup errors, the nightly backup.
- `read_spec.cr`, `invariants_spec.cr`, the seed part of `mcp_spec.cr`: read-only checks on the shared seed household.
- `support/`: the harness (`World`, `App`, `Browser` and per-spec helpers). The fake ECB and YNAB servers are shared with the
  unit specs and live in `../spec/support/`.

Scenarios of one `describe` share their world and build on each other: IDs, people and settings come from earlier
scenarios. Run whole files; a single feature scenario with `-e`, or `--order random`, fails.

## Seed data and invariants

`E2E.seeded_world` is a household built through the app itself (`support/seed.cr`): six people (one archived),
custom and archived categories, about 870 expenses over 2.5 years in all split modes and seven foreign
currencies, edits, deletions, reimbursements, recurring rules (monthly, weekly, yearly, month end, leap day,
paused, deleted), manual exchange rates, MCP entries and a YNAB connection with category mapping and sync.
The seed runs in three phases with different frozen clocks so that timestamps and the YNAB selection behave
like in real use. It is built once per run, on first use, and shared by the read-only specs, which must not
change it; nothing is cached between runs.

`invariants_spec.cr` compares what the app shows and exports with what the database holds, computed independently
in the spec: shares add up to the amount, foreign amounts follow their rates, balances add up to zero and match the
balances page and its suggestions, the home page lists every live expense once with each person's balance, every
expense page shows the stored values, CSV and JSON exports hold exactly the live expenses, the YNAB fake holds exactly
the selected transactions, and the activity log is complete.

## Test-only environment variables

The app reads these only when built with `-Dtest_hooks`: `ZIPFELKASSE_TEST_NOW` (frozen clock),
`ZIPFELKASSE_TEST_ECB_URL`, `ZIPFELKASSE_TEST_YNAB_URL`, `ZIPFELKASSE_TEST_YNAB_DELAY_MS`.

Every world lives in a temporary directory that is removed at the end of the run; `E2E_KEEP=1` keeps them
(database and log of each world) and prints where.
