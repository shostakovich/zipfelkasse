# MCP – analysis and entry with Claude

Zipfelkasse has its own MCP server through which Claude can analyze the expenses and enter new ones. Two tools
**add** expenses and reimbursements; nothing can be changed or deleted via MCP – that stays in the app. All other
tools only read. It runs at `/mcp/<MCP_SECRET>`. Without `MCP_SECRET` it is disabled.

The whole MCP interface is in English (tool names, parameters, output keys, instructions, error messages). Data
values from the database (names, titles, categories, notes) are returned as entered, i.e. usually in German. One
exception: when the app's own rules refuse an entry of a write tool (e.g. the split does not add up), the error starts
with "The app refused the entry (message in German):" followed by the app's German message.

## Tools

| Tool | Purpose |
|---|---|
| `balances` | balance per person and a settlement proposal |
| `balance_history` | balance per person at the end of each month, week or year |
| `search_expenses` | individual expenses, filtered by date, category, people, text, amount and `reimbursements`, sortable, compact or with shares (`detail`) |
| `statistics` | totals by `group_by` = `category`, `title`, `year`, `month`, `week`, `person` or `category_month`. Either total amounts or – with `share_of` – only one person's share, optionally compared with the previous year. Reimbursements never count |
| `activity` | the activity log: who created, changed or deleted what when |
| `schema` | explains tables and columns, lists people and categories, returns the CREATE statements |
| `sql_query` | any `SELECT`/`WITH` (SQLite) as `query`, at most 500 rows, aborted after 2 s |
| `create_expense` | **writes:** creates an expense |
| `create_reimbursement` | **writes:** records a settlement payment from one person to another |

Parameters in detail. Choice values (`interval`, `reimbursements`, `sort`, `detail`, `group_by`, `compare`, `action`,
`split`) are matched ignoring case. Arguments of the wrong type or unknown arguments are refused with a message
naming the argument. Optional text parameters that are empty count as not
given; numbers such as `limit`, `expense_id` and `before_id` must respect the minimum of the schema (1) and are refused
otherwise.

- `search_expenses`: `from`, `to` (dates, inclusive), `category`, `person` (expenses the person paid **or** takes
  part in), `paid_by` (only paid by), `involved` (only with a share of), `text` (substring of title or notes; a list
  matches if any term occurs), `min_amount`, `max_amount` (euros, inclusive), `reimbursements` (`exclude` = default,
  `include`, `only`), `sort` (`date_desc` = default, `date_asc`, `amount_desc`, `amount_asc`), `detail` (`compact` =
  default, `full` adds split, shares, notes and foreign currency), `limit` (1–500, default 50).
- `statistics`: `group_by` (required), `from`, `to`, `share_of` (only this person's share counts; empty = total
  amounts), `category`, `text` (as in `search_expenses`), `compare` (`previous_year`), `limit` (1–500, default 500;
  `total` always covers all rows).
  - `title` groups by expense title, case-insensitively (i.e. by merchant). `week` is the ISO week (`2026-W40`).
  - `year`, `month` and `week` list periods without expenses with 0: from `from` (or the first expense) to `to` (or
    today), never beyond today. `category_month` is not filled.
  - `compare: "previous_year"` adds `previous`, `change` and `change_percent` to each row. Time groupings compare
    each period with the same period a year earlier. `category`, `title` and `person` compare `from`…`to` (`to`
    defaults to today) with the same range a year earlier and need `from`. Groups that only existed a year earlier
    appear with 0 (for `category_month` if their month is in the range). 29 February becomes 28 February, week 53 of
    a year is compared in week 52 of the next one if that has no week 53.
- `balance_history`: `interval` (`month` = default, `week`, `year`), `from` (default: the first expense), `to`
  (default: today, or the last expense if one is dated later), `person`. Each row is the balance after all expenses
  dated up to the end of its period, so without `to` the last row equals `balances`. Computed from the current data
  by expense date, so later edits and deletions apply retroactively; expenses before `from` are the opening balance.
  At most 500 periods.
- `activity`: `from`, `to` (days in the server time zone), `person` (who made the change), `action`, `expense_id`,
  `before_id` (paging), `limit` (1–500, default 50).
- `create_expense`: `title`, `amount`, `paid_by` (required), `date` (default today), `category`, `currency` (default
  EUR), `fx_rate` (default: the ECB rate of the date, as in the form), `split` (`equal` = default, `shares`,
  `percent`, `amount`), `participants` (for `equal`; default all active people), `weights` (for the other modes:
  person → value, e.g. `{"Anna": 70, "Ben": 30}`), `notes`, `allow_duplicate`.
- `create_reimbursement`: `from`, `to`, `amount` (required), `date`, `currency`, `fx_rate`, `notes`,
  `allow_duplicate`. The title is "Rückzahlung", as in the form.

Rules for both write tools:

- The person who paid (`paid_by` or `from`) counts as the author in the activity log; MCP has no logged-in user. The
  entry carries the text "Über MCP angelegt", so entries created through MCP can be told apart.
- Titles are limited to 200 characters and notes to 2000, as in the app.
- Amounts are strict: digits with a dot as decimal separator, no thousands separator (`"1234.50"`, not `"1.234,50"`),
  so `"1.234"` is refused instead of becoming 1234 €.
- Archived people and categories cannot be used.
- An entry with the same date, payer, amount (in euros) and title – for reimbursements: recipient – is refused as a
  likely duplicate (e.g. a retried call) unless `allow_duplicate` is `true`.
- The tools are marked as not read-only and not idempotent (`readOnlyHint`/`idempotentHint` false), so Claude asks
  for confirmation before running them.
- The result is the created entry (as in `search_expenses` with `detail=full`). Every created entry is also logged
  (`mcp: entry created` with its id).

`category: "none"` selects expenses without a category, both in `search_expenses` and in `statistics` (which labels
them "No category"; that label is accepted as input too). A real category with that name takes precedence. The
instructions and the `schema` text state today's date in the server time zone (`TZ`), computed per request;
`server/discover` is therefore cached at most until midnight.

The instructions also contain a data overview, read from the database per request: the number of expenses and
reimbursements, their date range, how many expenses have no category, and all values of `activity.action`. As
`server/discover` may be cached for up to an hour, the overview can be that old.

Every amount appears twice: as locale-neutral text `"1234.56"` (dot as decimal separator, no thousands separator, no
currency sign) and as an integer number of cents (field ending in `_cents`), e.g. `amount`/`amount_cents`,
`balance`/`balance_cents`, `total`/`total_cents`. Foreign-currency originals look like `"23.40 USD"`.

Tool results are a single text block containing the JSON object (`schema` returns plain text). There is no
`structuredContent` and no `outputSchema`: a second copy of the same JSON would double the response size. Claude.ai and
Claude Desktop only pass the text on to the model, Claude Code and VS Code only `structuredContent` when there is one,
otherwise the text – so the text alone reaches every client.

Main output keys:

- `balances`: `balances[]` (`person`, `balance`, `balance_cents`, `status`), `settlements[]` (`from`, `to`, `amount`,
  `amount_cents`), `note`.
- `search_expenses`: `matches`, `shown`, `truncated`, `total`, `total_cents`, `expenses[]` (`id`, `date`, `title`,
  `category`, `paid_by`, `amount`, `amount_cents`, `reimbursement`, `recipient`; with `detail=full` also `original`,
  `fx_rate`, `fx_source`, `notes`, `split`, `shares[]`), with `person` or `involved` also `person_share`.
- `statistics`: `group_by`, `perspective`, `period`, `rows[]` (`category`, `title`, `year`, `month`, `week`,
  `person`, `count`, `amount`, `amount_cents`, with `group_by=person` also `paid`, `paid_cents`, with `compare` also
  `previous`, `previous_cents`, `change`, `change_cents`, `change_percent`), `rows_total`, `truncated`, `total`,
  `total_cents`, with `compare` also `previous_period`, `previous_total`, `previous_total_cents`, `note`.
- `balance_history`: `interval`, `period`, `rows[]` (`month`/`week`/`year`, `balances[]` with `person`, `balance` and
  `balance_cents`), `note`.
- `activity`: `entries[]` (`id`, `at` in the server time zone, `actor` (`system` for automatic changes), `action`,
  `expense_id`, `title`, `amount`, `amount_cents`, `changes[]` (`field`, `old`, `new`, as shown in the app), `text`),
  `shown`, `more`, and `note` with the next `before_id` when there are more.
- `sql_query`: `columns`, `rows`, `row_count`, `truncated`, and `note` when truncated. Numbers are JSON numbers, infinite
  values (`9e999`) appear as the strings `"Infinity"` and `"-Infinity"`.

**Protection in `sql_query`:** the query does not run on the real database. It runs on a fresh in-memory copy. The
server attaches the real file, copies the allowed tables in a read transaction and detaches the file again. After
that, `ATTACH` is blocked via `sqlite3_limit` and `PRAGMA query_only` is on. The query (without trailing semicolons)
is embedded as a subquery, `SELECT * FROM (<query>)`, so only a single `SELECT` or `WITH … SELECT` parses; anything else
gets SQLite's error.

SQLite runs on the only thread of the app, so a slow query makes the whole app (web UI, YNAB sync, other MCP calls)
wait. Queries are therefore aborted after 2 seconds, including the copy of the data. Columns with the same name get a
numeric suffix (`x`, `x:1`).

The allowed tables are participants, categories, expenses, expense_shares, recurring, activity, fx_rates and settings
(without `ynab…` keys). The YNAB tables holding the token do not exist in the copy at all. New tables only become
visible once they are listed in `Store::EXPOSED_TABLES`.

## Access

Only `POST` is served; any other method gets **405** before the checks below. There are three checks, in this
order:

1. The secret in the path is compared in constant time. If it is wrong, the response is a plain **404** and reveals
   nothing.
2. The client IP must be in `MCP_ALLOWED_CIDRS`. The default is `160.79.104.0/21`, which is Anthropic. Otherwise the
   response is **403**.
3. A non-empty `Origin` header results in **403**. Browsers should never access this endpoint, which is why the
   MCP Inspector in the browser does not work either.

For the client IP: if the connection comes from an address in `TRUSTED_PROXIES`, `X-Forwarded-For` counts. It is
read from the right, and the first address that is not itself a trusted proxy counts. Entries must be plain
addresses (no port); anything else is refused. If the header is missing, `X-Real-IP` applies. In all other cases the
TCP address counts, and forwarded headers are ignored.

Every access is logged: IP, JSON-RPC method, tool, status and duration. The path containing the secret is never logged.

### Environment variables

| Variable | Example |
|---|---|
| `MCP_SECRET` | `openssl rand -hex 32` (only `[0-9a-f]`, so URL-safe) |
| `MCP_ALLOWED_CIDRS` | `160.79.104.0/21` (default), for the LAN e.g. `160.79.104.0/21,192.168.178.0/24` |
| `TRUSTED_PROXIES` | exactly the address of the Newt/Pangolin container as /32, e.g. `172.18.0.5/32` (not the whole Docker network, see below) |

## Setting up Pangolin

1. Open the Zipfelkasse resource, go to **Rules** and enable the rules.
2. Add a rule: action **Bypass Auth**, match **Path**, value `/mcp/*`. This lets Claude through without the Pangolin
   login. The app protects itself with the secret, the IP filter and the Origin check.
3. Set `TRUSTED_PROXIES`: start the app without the variable first and call the endpoint once via the domain. The
   log then shows `mcp: IP not allowed` with `remote=<address>` (that is the Newt/Traefik hop) and
   `x_forwarded_for=[…]`. Alternatively: `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' newt`
   (adjust the container name). Enter **only this one address as /32** in `TRUSTED_PROXIES`, e.g. `172.18.0.5/32`.
   After that, `ip=` must show the real client address.

   Why not the whole Docker network (`172.18.0.0/16`)? Every container in that network could then set
   `X-Forwarded-For` and pretend to be Anthropic – a compromised neighbor container would get past the IP filter
   that way. To keep the address stable across restarts, give the Newt container a fixed address in its compose file
   (`networks: <network>: ipv4_address: 172.18.0.5`) or check it again after updates.
4. Check the headers: Traefik in Pangolin sets `X-Forwarded-For` and `X-Real-Ip`. If `x_forwarded_for` is empty,
   `X-Real-IP` is enough.

### With Caddy between Newt and Zipfelkasse

If the path is `Pangolin → Newt → Caddy → Zipfelkasse`, there are two proxy hops. Then:

- **Caddy must trust Newt**, otherwise it discards the incoming `X-Forwarded-For` (with the Anthropic IP) and only
  writes the Newt address into it. Globally in the Caddyfile:

  ```caddyfile
  {
  	servers {
  		trusted_proxies static 172.18.0.5/32  # address of the Newt container
  	}
  }
  ```

  Caddy then appends the Newt address: `X-Forwarded-For: <Anthropic IP>, <Newt IP>`.
- **Zipfelkasse must trust both:** `TRUSTED_PROXIES=<Caddy IP>/32,<Newt IP>/32`. Zipfelkasse reads from the right,
  skips Newt and arrives at the Anthropic IP.
- Check via the log line as above: `remote=` is Caddy, `x_forwarded_for=[<Anthropic IP> <Newt IP>]`, `ip=` the
  Anthropic IP.

On the home network (directly via Caddy, without Pangolin), `x_forwarded_for` contains your LAN address. If Claude
Code should have access from the LAN, add your network to `MCP_ALLOWED_CIDRS` as well.

## Connecting Claude

**Claude (web/desktop):** go to Settings → Connectors → **Add custom connector** and enter:

- Name: `zipfelkasse`
- URL: `https://<domain>/mcp/<MCP_SECRET>`
- no authentication (no OAuth)

The requests then come from Anthropic, i.e. from `160.79.104.0/21`.

**Claude Code on the LAN**, directly without Pangolin:

```sh
claude mcp add --transport http zipfelkasse http://homeserver:8080/mcp/<MCP_SECRET>
```

For this, the LAN must be in `MCP_ALLOWED_CIDRS`. Depending on the Docker setup, the Docker gateway (e.g.
`172.17.0.1`) arrives instead of the LAN address. The actual address is in the log under `ip=`.

## Example questions

Questions can be asked in any language; Claude maps them to the English tools.

- "Who owes whom how much right now?"
- "How much did I (Robert) spend on restaurants in 2026, month by month?"
- "What were the ten most expensive expenses on vacation in August?"
- "Which category grew the most compared to last year?"
- "Show all expenses in USD with their exchange rate."
- "Who paid how much up front and how much did each person consume?"
- "How did Ben's balance develop this year?"
- "Who changed the dinner expense last week, and what was changed?"
- "Ich habe gerade 23,40 € bei Rewe für Anna und mich bezahlt." (creates an expense)
- "Ben hat mir 50 € überwiesen." (creates a reimbursement)

## Testing with curl

Locally, your own address must be allowed, e.g. with `MCP_ALLOWED_CIDRS=127.0.0.1/32`:

```sh
URL=http://localhost:8080/mcp/$MCP_SECRET

META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}'
curl -s $URL -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: server/discover' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{$META}}"
curl -s $URL -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/call' -H 'Mcp-Name: statistics' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"statistics\",\"arguments\":{\"group_by\":\"category\"},$META}}"

# Expected errors
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/mcp/wrong   # 404
curl -s -o /dev/null -w '%{http_code}\n' $URL                                       # 405 (GET)
```

## Protocol

Only protocol version 2026-07-28 is supported (stateless, as current Claude clients speak it):

- Every request carries `_meta.io.modelcontextprotocol/protocolVersion` = `2026-07-28`. A missing or other version
  results in 400 with `-32022` and `data.supported`; there is no `initialize` handshake.
- The headers `MCP-Protocol-Version`, `Mcp-Method` and, for `tools/call`, `Mcp-Name` (also as `=?base64?…?=`) must
  match the body, otherwise the response is 400 with `-32020`.
- Supported are `server/discover`, `tools/list`, `tools/call` and `ping`; an unknown method results in 404 with
  `-32601`. Notifications (no `id`) and answers of the client result in 202 without a body.
- Responses are only sent as `application/json`, without SSE and without session IDs. Batches are rejected, and a
  message may be at most 1 MiB (413).
