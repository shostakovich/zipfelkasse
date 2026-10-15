# Decisions

## 0001. Phoenix, LiveView and SQLite in one container

Accepted, 2026-10-15

- **Context:** One household, a handful of people and a few thousand expenses a year, run on a small server with
  as little upkeep as possible.
- **Decision:** One Phoenix 1.8 app: LiveView for every page, SQLite (WAL) via ecto_sqlite3 as the only store,
  the jobs (exchange rates, recurring expenses, backup, YNAB sync) as processes in the same release, shipped as
  one container image.
- **Consequences:** No database server, job queue or second container; a backup is one file. Writes are
  serialized (immediate transactions with a busy timeout), so the app runs as a single instance.

## 0002. The UI is built on Setzkasten

Accepted, 2026-10-15

- **Context:** The pages are ordinary app screens (lists, forms, dialogs, navigation) for phones and desktops;
  styling them per app repeats work and drifts apart.
- **Decision:** Tailwind CSS 4 and daisyUI 5 with the components, themes and design rules of
  [Setzkasten](https://github.com/shostakovich/setzkasten) (`use Setzkasten`). Lucide icons and the app's plush
  images plug into its icon and plush behaviours; app styles live only in `assets/css/app.css`.
- **Consequences:** A missing component or a bug is fixed in Setzkasten, not worked around in the app.
  Setzkasten is a git dependency, and the asset build needs the Tailwind and esbuild binaries.

## 0003. No login: you pick who you are

Accepted, 2026-10-15

- **Context:** The people of one household trust each other and use the app on shared phones and laptops;
  accounts and passwords would only add friction.
- **Decision:** No accounts. "Wer bist du?" lets a visitor choose or add a person; the choice lives in the signed
  session cookie, and every page needs a chosen, non-archived person. Keeping strangers out is left to a private
  network or an authenticating layer in front.
- **Consequences:** Whoever reaches the app can act as anyone, so it must never be exposed publicly. The activity
  log names the chosen person, not a verified identity. MCP is protected on its own (0006).

## 0004. Cents and a largest-remainder split rotated by expense id

Accepted, 2026-10-15

- **Context:** Shares must add up to the expense exactly and balances to zero, and the cent that does not divide
  evenly must not always fall on the same person.
- **Decision:** Money is integer euro cents; a foreign amount is stored in its currency's minor units and
  converted with rounding half away from zero. Shares are allocated by largest remainder over the participants
  ordered by id; ties take turns by the expense id.
- **Consequences:** No floating-point drift and reproducible splits: the same expense always splits the same way,
  and the form previews the split with the next id. Changing the allocation would change stored shares, so it
  stays fixed.

## 0005. YNAB sync with the app as the source of truth

Accepted, 2026-10-15

- **Context:** Each person can mirror their share of every expense into their own YNAB account. Expenses change
  and disappear after they were synced, and requests can fail with an unknown outcome.
- **Decision:** The app creates, updates and deletes its transactions in YNAB and never takes changes back. No
  `import_id` (YNAB would merge the imports with reimbursement transfers of the same amount); every memo ends with
  the marker `zipfelkasse #<expense id>`, which finds transactions after an unclear outcome or a change of account.
  A fingerprint (`v1\0date\0milliunits\0payee\0memo\0category`, the first 16 bytes of SHA-256 as hex) per
  share decides whether an update is needed.
- **Consequences:** Date, amount, payee or memo edited in YNAB are overwritten when the expense changes. The
  fingerprint and memo format must stay byte-identical, or every transaction looks changed. The tokens are stored
  in the database, so backups are private.

## 0006. A stateless MCP server behind a secret path and an address filter

Accepted, 2026-10-15

- **Context:** AI assistants should analyse the expenses and enter new ones, but the app has no login and the
  data is private.
- **Decision:** Only MCP protocol version 2026-07-28, stateless (no handshake, session or SSE). The endpoint is
  `/mcp/<MCP_SECRET>`, compared in constant time, for client addresses in `MCP_ALLOWED_CIDRS` only, and refuses
  browsers (any `Origin`). Tools only read, except two that add entries. `sql_query` runs on an in-memory copy
  of the visible tables, read-only, without ATTACH or pragmas, cancelled after 2 seconds.
- **Consequences:** No server state to lose and no older protocol versions to support; clients that do not speak
  2026-07-28 cannot connect. A query can never change or lock the real database or see the YNAB tokens, at the
  cost of copying the data per query.

## 0007. Case-folded columns instead of a custom SQL function

Accepted, 2026-10-15

- **Context:** Search, duplicate checks, recurring skips and statistics by title must ignore case the Unicode way
  ("ß" as "ss", umlauts); SQLite's `lower()` and `LIKE` fold only ASCII. Exqlite cannot register custom SQL
  functions, and one would exist neither in the MCP sandbox nor in the `sqlite3` shell.
- **Decision:** `expenses.title_folded` and `notes_folded` hold `:string.casefold/1` of title and notes, written
  by the changeset on every insert and update; queries compare them with a folded term.
- **Consequences:** Plain SQL works everywhere, including MCP's `sql_query`. Every write must go through the
  changeset (or set the columns itself), and the texts are stored twice.
