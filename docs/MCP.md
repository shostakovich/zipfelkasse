# MCP

Zipfelkasse has an MCP server for AI assistants such as Claude: they can analyse the expenses and enter new ones.

- Endpoint: `POST /mcp/<MCP_SECRET>`. Without `MCP_SECRET` there is none.
- Two tools **add** expenses and reimbursements; nothing can be changed or deleted through MCP. All other tools only
  read.
- The interface is English (tool names, arguments, output keys, messages). Data comes back as entered, usually German.
  When the app's own rules refuse an entry, the message starts with
  `The app refused the entry (message in German):` followed by the app's German message.

## Tools

| Tool | Purpose |
|---|---|
| `balances` | balance per person and the transfers that settle them |
| `balance_history` | balance per person at the end of each month, week or year |
| `search_expenses` | individual expenses by date, category, people, text, amount and `reimbursements`; sortable; `detail=full` adds split, shares, notes and foreign currency |
| `statistics` | totals by `category`, `title`, `year`, `month`, `week`, `person` or `category_month`, optionally only one person's share (`share_of`) and compared with the previous year |
| `activity` | the activity log: who created, changed or deleted what and when |
| `schema` | the tables and columns in words, people and categories, the CREATE statements |
| `sql_query` | one `SELECT` or `WITH … SELECT` (SQLite) on a copy of the data |
| `create_expense` | **writes:** an expense |
| `create_reimbursement` | **writes:** a settlement payment from one person to another |

Arguments:

- Every input schema is strict: unknown arguments and wrong types are refused, naming the argument. Choices
  (`interval`, `sort`, `group_by`, …) ignore case and underscores. Empty texts count as not given.
- Dates are `YYYY-MM-DD` (`DD.MM.YYYY` works too), from 2000 to 2100. `from` and `to` are inclusive.
- People and categories are given by name, regardless of case. `category: "none"` (or `"No category"`) selects
  expenses without a category, unless a category has that name.
- `limit` is 1–500 (`search_expenses` and `activity` default to 50, `statistics` to 500).
- `statistics`: `year`, `month` and `week` (ISO, `2026-W40`) list periods without expenses with 0, never beyond today.
  `compare: "previous_year"` adds `previous`, `change` and `change_percent`; `category`, `title` and `person` then need
  `from`. 29 February compares with 28 February, week 53 with week 52 of a year without week 53. `title` groups by the
  case-folded title, i.e. by merchant. Reimbursements never count.
- `balance_history`: at most 500 periods; computed by expense date from the current data, so later edits apply
  retroactively.
- `activity`: `from` and `to` are days in the server time zone; `before_id` pages back.

Write tools:

- `create_expense`: `title`, `amount`, `paid_by` (required), `date` (today), `category`, `currency` (EUR), `fx_rate`
  (the ECB rate of the date), `split` (`equal`, `shares`, `percent`, `amount`), `participants` (for `equal`; all
  active people by default), `weights` (person → value for the other modes), `notes`, `allow_duplicate`.
- `create_reimbursement`: `from`, `to`, `amount` (required), `currency`, `fx_rate`, `date`, `notes`,
  `allow_duplicate`; the title is "Rückzahlung".
- Amounts are strict: digits and a dot, no thousands separator (`"1234.50"`); `"1.234"` is refused.
- Archived people and categories are refused.
- The same date, payer, euro amount and title (for a reimbursement: recipient) is refused as a likely duplicate unless
  `allow_duplicate` is true.
- The payer is the author in the activity log, with the text "Über MCP angelegt". The result is the created entry.

Output:

- Every amount appears twice: as text with a dot and no grouping (`"1234.56"`) and in cents (`*_cents`). Foreign
  originals look like `"23.40 USD"`.
- A result is one text block with the JSON (`schema`: plain text), no `structuredContent`.
- `sql_query` returns `columns`, `rows`, `row_count`, `truncated` and a `note` when cut after 500 rows or 8 MiB.
  Cells longer than 2000 characters are cut, blobs appear as `"[BLOB, n Bytes]"`, infinite numbers as
  `"Infinity"`/`"-Infinity"`.
- `server/discover` adds today's date and time zone and a data overview (counts, date range, share without
  category, values of `activities.action`) to the instructions; it may be cached until local midnight.

## The SQL sandbox

- The query never runs on the real database: a fresh in-memory database attaches the file read-only, copies the
  visible tables and detaches it again.
- Then the connection only reads (`PRAGMA query_only`), and `ATTACH`, `DETACH` and pragmas are not authorized.
- The query is wrapped as `SELECT * FROM (<query>) LIMIT 501`, and SQLite must compile all of it: only a single
  `SELECT` or `WITH … SELECT` without parameters runs. Anything else, also a second statement after it, gets an SQL
  error. The query may be at most 100,000 bytes long.
- At most 500 rows and 8 MiB are returned; long texts are cut inside SQLite, before they reach the app.
- It is cancelled after 2 seconds, the copy included.
- Visible tables: `participants`, `categories`, `expenses`, `expense_shares`, `recurring_expenses`, `activities`,
  `fx_rates`, `settings`. The YNAB tables (they hold tokens) are never copied.
- `expenses.title_folded` and `notes_folded` are case-folded copies of title and notes (Unicode-correct, "ß" as
  "ss"): compare them with a folded term, e.g. `instr(title_folded, 'bäckerei') > 0`.
- `recurring_expenses.template` is the expense as JSON without date: `title`, `category_id`, `paid_by_id`, `notes`,
  `reimbursement`, `split_mode`, `amount_cents`, `original_amount`, `original_currency`, `fx_rate`, `fx_source` and
  `parts` (`[{"participant_id", "weight"}]`).
- `activities.details` is compact JSON with only the keys that apply: `title` and `amount_cents` of the expense,
  `changes` of an update (`[{"field", "old", "new"}]`, German as shown in the app) and `text`.

## Access

Checked in this order:

1. The secret in the path, compared in constant time. A wrong one is a plain `404` for every method.
2. `POST` only; other methods get `405` with `Allow: POST`.
3. The client address must be in `MCP_ALLOWED_CIDRS` (default `160.79.104.0/21`, Anthropic), else `403`.
4. Any `Origin` header means a browser: `403`.
5. `Content-Type: application/json` (`415`) and at most 1 MiB (`413`).

- The client address is the TCP peer. Only when the peer is in `TRUSTED_PROXIES`, `X-Forwarded-For` counts, read from
  the right: the first hop that is not a trusted proxy is the client. Without that header, `X-Real-IP` counts. An
  unparsable hop (also one with a port) refuses the call.
- There is no session, no CSRF token and no person: the MCP is outside the web app.
- Every call is logged with address, method, tool (a known one), status and duration, a refused tool call also with
  its message (`tool_error`, cut after 300 characters). The path with the secret is never logged.

| Variable | Meaning |
|---|---|
| `MCP_SECRET` | the secret path segment, e.g. `openssl rand -hex 32`; empty turns the MCP off |
| `MCP_ALLOWED_CIDRS` | client networks or addresses, comma or space separated (default `160.79.104.0/21`) |
| `TRUSTED_PROXIES` | proxies whose `X-Forwarded-For` counts (default none) |

## Behind a reverse proxy

- If the proxy puts a login in front of the app, exclude `/mcp/` from it: MCP clients cannot log in. The app protects
  the endpoint itself (secret, address filter, no browsers).
- Keep the secret in the path: never strip or rewrite `/mcp/<secret>`.
- Put exactly the proxy's own address into `TRUSTED_PROXIES` (as `/32`), not a whole network: every host in a trusted
  network could claim any client address.
- With two proxies in a row, the outer one must be trusted by the inner one, and the app must trust both.
- To find the addresses, call the endpoint once: a refused call logs `ip=`, `remote=` (the peer) and the forwarding
  headers it saw.

## Connecting

- Claude (web or desktop): add a custom connector with the URL `https://<host>/mcp/<MCP_SECRET>`, without
  authentication.
- Claude Code: `claude mcp add --transport http zipfelkasse https://<host>/mcp/<MCP_SECRET>`; its address must be in
  `MCP_ALLOWED_CIDRS`.

## Protocol

- Only version `2026-07-28`, stateless: no `initialize`, no session id, no SSE, no batches.
- Every request carries `_meta["io.modelcontextprotocol/protocolVersion"] = "2026-07-28"`; a missing or other
  version gets `400` with `-32022` and `data.supported`.
- The headers `MCP-Protocol-Version`, `Mcp-Method` and, for `tools/call`, `Mcp-Name` (also as `=?base64?…?=`) must
  match the body, else `400` with `-32020`.
- Methods: `server/discover`, `ping`, `tools/list`, `tools/call`. An unknown method is `404` with `-32601`, an unknown
  tool `-32602`. Notifications and answers of the client get `202` without a body; ids are echoed, `"id": null` too.
- Every result carries `resultType: "complete"` and `_meta["io.modelcontextprotocol/serverInfo"]`.

## Testing with curl

With your own address allowed, e.g. `MCP_ALLOWED_CIDRS=127.0.0.1/32`:

```sh
URL=http://localhost:4000/mcp/$MCP_SECRET
META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}'

curl -s $URL -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2026-07-28' \
  -H 'Mcp-Method: server/discover' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{$META}}"

curl -s $URL -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2026-07-28' \
  -H 'Mcp-Method: tools/call' -H 'Mcp-Name: statistics' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"statistics\",\"arguments\":{\"group_by\":\"category\"},$META}}"

curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:4000/mcp/wrong   # 404
curl -s -o /dev/null -w '%{http_code}\n' $URL                                       # 405
```
