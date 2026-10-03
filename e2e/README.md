# E2E suite

A black-box test suite for the Zipfelkasse binary, written in Crystal (stdlib plus the sqlite3 shard). It starts the
binary with a fresh database, a frozen clock and fake ECB and YNAB servers, and talks to it like a browser (forms,
cookies, redirects) and like an MCP client.

```sh
crystal build -o bin/zipfelkasse src/zipfelkasse.cr
E2E_BIN=bin/zipfelkasse crystal spec e2e/                          # assertions
E2E_BIN=bin/zipfelkasse E2E_REF_BIN=/path/to/other crystal spec e2e/ # plus diff mode
```

## Diff mode

With `E2E_REF_BIN`, every request goes to both binaries. The answers must be equivalent:

- HTML is compared as a normalised DOM (entities decoded, attributes sorted, whitespace collapsed the way a browser
  renders it), so `&#34;` and `&quot;` are equal, a missing space between two links is not;
- JSON is compared structurally (also JSON inside strings, e.g. MCP tool results);
- everything else byte for byte (CSV, OFX, static files);
- status, `Location`, cookies and the important headers must match.

After every scenario the complete database content, the schema and the state of the YNAB fakes must be identical.
Every HTML answer is also checked for injected `<script>` elements and `on*` attributes (the test data is full of
HTML special characters).

## Seed data

`E2E.seed_db` builds a household through the app itself (`support/seed.cr`): six people (one archived), custom and
archived categories, about 870 expenses over 2.5 years in all split modes and seven currencies, edits, deletions,
reimbursements, recurring rules (monthly, weekly, yearly, month end, leap day, paused, deleted), manual exchange
rates, MCP entries and a YNAB connection with category mapping and sync. The seed runs in three phases with
different frozen clocks so that timestamps and the YNAB selection behave like in real use. It is built by the
reference binary when there is one, so in diff mode `read_spec.cr` also proves that the binary under test opens a
database the reference created.

`E2E_SEED_DB=/path/to/backup.db` runs the read-only crawl (`read_spec.cr`) on another database, e.g. a backup of
real data. Never commit such a file; `e2e/data/` is ignored by git.

## Test-only environment variables

The app reads these only for the suite: `ZIPFELKASSE_TEST_NOW` (frozen clock), `ZIPFELKASSE_TEST_ECB_URL`,
`ZIPFELKASSE_TEST_YNAB_URL`, `ZIPFELKASSE_TEST_YNAB_DELAY`.

`E2E_KEEP=1` keeps the databases and logs of each run under `e2e/data/worlds/`.
