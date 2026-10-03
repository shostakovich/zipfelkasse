# Porting inventory: `internal/mcp`, `internal/store/mcp.go`, `internal/export`

Target: a 1:1 port to Crystal + Kemal. Sources read in full: `internal/mcp/{mcp,access,rpc,tools,write}.go`,
`internal/store/mcp.go`, `internal/export/{export,formats}.go`, `internal/export/templates/export.html`, `docs/MCP.md`.
Helpers they depend on were read where they affect output: `domain/{money,date,split,balance}.go`, `config/config.go`,
`store/{expenses,activity,fold,participants,categories,store}.go`, `web/{deps,identity}.go`, `ynab/posting.go`, `main.go`.

**Ground truth captures.** I ran probe tests against an unmodified copy of the repo (Go 1.26.5, modernc sqlite v1.60.1).
The byte-exact HTTP outputs are in `docs/porting/probes/`.
The complete, exact `tools/list` wire response is under `### tools/list legacy` in `probe_mcp_decoded.txt`.

- `probes/probe_mcp_decoded.txt`: status, headers and body for about 120 MCP requests (transport errors, every tool, every error path), decoded and readable. The inner tool text is shown on `TEXT:` lines.
- `probes/probe2.txt`: JSON decoding edge cases (case-insensitive keys, null, floats for ints, and so on).
- `probes/probe_export.txt`: every export route with headers and full bodies.

> Note on `probe_mcp*`: the cases "create archived payer" and "create archived part" did **not** archive Cleo. The archive
> was refused because Cleo had a non-zero balance. Their success there is therefore *not* a bug. The real archived-person
> behaviour is described in section 2.8.

In the probes `TZ` is unset, so instructions say `server time zone Local`. In production `TZ=Europe/Berlin` gives
`server time zone Europe/Berlin` (see Pitfall P20).

---

## 1. MCP transport

### 1.1 Mounting, routing, config

- `main.go` builds two muxes. `root.Handle("/mcp/", web.SecurityHeaders(mcpMux))` and `root.Handle("/", web.Wrap(d, mux))`.
  MCP is **outside** the web middleware stack: no identity cookie, no CSRF check, no body-limit middleware. It has only the
  security headers:
  - `X-Content-Type-Options: nosniff`
  - `Referrer-Policy: same-origin`
  - `X-Frame-Options: DENY`
  - `Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'`
- `mcp.Register(mux, d)`:
  - If `Config.MCPSecret == ""`: logs `INFO "MCP disabled (MCP_SECRET is empty)"` and registers nothing. Every `/mcp/...`
    request then gets Go's 404 `404 page not found\n` (text/plain; charset=utf-8, plus `X-Content-Type-Options: nosniff`).
    Requests never fall through to the web app.
  - Otherwise: `mux.Handle("/mcp/{secret}", server)`. The pattern has no method, so it matches all methods. `{secret}`
    matches exactly **one** path segment, and its value is percent-decoded. `/mcp/`, `/mcp/a/b` and `/mcp/` with an empty
    secret all give the Go mux 404 (`404 page not found\n`). Go's ServeMux also 301-redirects `/mcp` to `/mcp/` and cleans
    paths such as `//` and `..` by redirect.
  - Logs `INFO "MCP enabled" path=/mcp/*** allowed=[160.79.104.0/21] proxies=[10.0.0.1/32]`. These use Go's `%v` of
    `[]netip.Prefix`: space-separated inside `[...]`, and `[]` when empty.
- Env vars (`config.FromEnv`):
  - `MCP_SECRET`: `strings.TrimSpace`. Empty disables MCP.
  - `MCP_ALLOWED_CIDRS`: default `160.79.104.0/21`, used when the value is empty or whitespace.
  - `TRUSTED_PROXIES`: default empty.
  - Both lists use `ParsePrefixes`: split on `,`, space, `\t`, `\n`. A token containing `/` goes to `netip.ParsePrefix`
    and is then `.Masked()`. A bare IP becomes `/32` or `/128`, after `Unmap()`. Any parse error aborts startup with
    `MCP_ALLOWED_CIDRS: <err>` or `TRUSTED_PROXIES: <err>`.
  - `TZ`: `time.LoadLocation`. When unset, the location is `time.Local`, whose `String()` is `"Local"`.
- `const maxBody = 1 << 20` (1 MiB). `toolTimeout = 20s`, a context around dispatch, including `initialize`.
  `listTTL = 1h`. Server timeouts: ReadHeader 10s, Read 30s, Write 60s, Idle 2m.

### 1.2 Request pipeline (`ServeHTTP` then `handlePost`): the order is significant

| # | Check | Failure response |
|---|---|---|
| 1 | `subtle.ConstantTimeCompare(PathValue("secret"), MCPSecret) != 1` | `http.NotFound`: **404**, body `404 page not found\n`, `Content-Type: text/plain; charset=utf-8`, `X-Content-Type-Options: nosniff`. Log `WARN "mcp: wrong secret" ip=<ip> remote=<RemoteAddr>` |
| 2 | `ip` invalid **or** not in `MCP_ALLOWED_CIDRS` (`ContainsAddr` unmaps) | **403**, JSON `{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access from this address is not allowed."}}\n`. Log `WARN "mcp: IP not allowed" ip=… remote=… x_forwarded_for=[…] x_real_ip="…"` |
| 3 | `Origin` header non-empty (any value, including `null`) | **403**, JSON `{"jsonrpc":"2.0","error":{"code":-32000,"message":"Access from a browser is not allowed."}}\n`. Log `WARN "mcp: Origin header rejected" ip=… origin=…` |
| 4 | Method ≠ `POST` (GET, DELETE, HEAD, OPTIONS, …) | **405**, header `Allow: POST`, body `Method Not Allowed\n` (`http.Error`: text/plain; charset=utf-8 + nosniff). Log `INFO mcp ip=… http=GET status=405` (no duration) |
| 5 | `mime.ParseMediaType(Content-Type)` media type ≠ `application/json`. Parameters such as charset are fine and the type is lower-cased; a parse error is ignored when a type is still returned | **415** `{"jsonrpc":"2.0","error":{"code":-32600,"message":"Content-Type must be application/json."}}` |
| 6 | Body read through `http.MaxBytesReader(1 MiB)` fails | **413** `…"code":-32600,"message":"Message too large or incomplete."` |
| 7 | `bytes.TrimSpace(body)` starts with `[` | **400** `…"code":-32600,"message":"JSON-RPC batches are not supported."` |
| 8 | `json.Unmarshal(body, &message)` fails. This includes `"method":5` and `"jsonrpc":2`, which are type errors | **400** `…"code":-32700,"message":"Invalid JSON: <go error>"`. Examples: `Invalid JSON: invalid character 'b' looking for beginning of object key string`, `Invalid JSON: unexpected end of JSON input` (empty body), `Invalid JSON: invalid character 'x' after top-level value`, `Invalid JSON: json: cannot unmarshal number into Go struct field message.method of type string` |
| 9 | `method == ""` and (`result` or `error` key present, even `null`) | **202**, empty body, no Content-Type (the client sent a response) |
| 10 | `method == ""` otherwise | **400** with `id` echoed if present: `{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Field method is missing."}}` |
| 11 | `jsonrpc != "2.0"` (missing, `"1.0"`, …) | **400** `…"code":-32600,"message":"jsonrpc must be \"2.0\"."` (id echoed) |
| 12 | `params` present, not empty and not literally `null`, and unmarshalling into `{_meta: map, name, arguments, protocolVersion}` fails | **400** `…"code":-32602,"message":"Invalid params: json: cannot unmarshal array into Go value of type mcp.params"`. Other examples: `…cannot unmarshal string into Go value of type mcp.params`, `…cannot unmarshal number into Go struct field params.name of type string`, `…cannot unmarshal number into Go struct field params._meta of type map[string]json.RawMessage` |
| 13 | `_meta["io.modelcontextprotocol/protocolVersion"]` exists but is not a non-empty JSON string | **400** `…"code":-32602,"message":"_meta.io.modelcontextprotocol/protocolVersion must be a non-empty string."` |
| 14 | Era and version determination (section 1.3) | see 1.3 |
| 15 | Notification (the `id` key is **absent**; `"id":null` is *not* a notification) | **202**, empty body |
| 16 | Dispatch (section 1.4) | 200, or a JSON-RPC error (section 1.4) |

Error responses from steps 5 to 8 never carry an `id`. From step 10 on, the raw `id` is echoed verbatim:

- `"id":null` gives `"id":null`.
- `1.50` stays `1.50`.
- `"abc"`, `true` and `{"a":1}` are echoed unchanged.
- Raw JSON is re-compacted by the encoder, so whitespace inside an object id is removed.

The id is omitted only when the key is absent (`json.RawMessage` with `omitempty`).

Every POST that reaches step 5 or later is logged after the response:

`INFO mcp ip=<ip> method=<m> status=<code> duration=<Go Duration rounded to ms, e.g. 0s, 12ms, 1.234s> [tool=<name>] [version=<v>] [tool_error="<msg>"]`

The format is Go slog TextHandler (`time=… level=INFO msg=mcp …`). Values are quoted only when needed: `method=""` for an
empty method. The path is never logged. `ip` is `netip.Addr.String()`, and the string `invalid IP` when invalid.

### 1.3 Protocol versions, era determination

```
modernVersions = ["2026-07-28"]
legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
allVersions    = modern + legacy  (in this order)
legacyDefault  = "2025-03-26"   (no MCP-Protocol-Version header)
```

The rules are applied in this order:

1. **`metaVersion != ""`** (a modern request; the body carries `params._meta["io.modelcontextprotocol/protocolVersion"]`):
   - `info.version = metaVersion`.
   - Notification: **202** immediately, before any header check.
   - `checkHeaders` (below). On failure: **400** `-32020`.
   - `metaVersion` in modern: `modern = true`.
   - `metaVersion` in legacy: answered legacy-style, with no `resultType` and no `_meta` (`{"jsonrpc":"2.0","id":"a","result":{}}` for ping).
   - Anything else: **400** `{"code":-32022,"message":"Unsupported protocol version.","data":{"requested":"<v>","supported":["2026-07-28","2025-11-25","2025-06-18","2025-03-26"]}}`. The `data` keys are alphabetical: `requested`, then `supported`.
2. **`method == "initialize"`** (and no meta): `info.version = negotiate(params.protocolVersion)`. The requested version is
   used if it is in legacy, otherwise `"2025-11-25"`. Headers are ignored, including a modern `MCP-Protocol-Version`.
3. **Otherwise (legacy)**: `v = header MCP-Protocol-Version`, or `"2025-03-26"` when absent. `info.version = v`.
   - `v` in legacy: OK. A notification gives 202.
   - `v` in modern: **400** `-32020` `Header MCP-Protocol-Version is 2026-07-28, but params._meta["io.modelcontextprotocol/protocolVersion"] is missing.`
     The key is Go-`%q`-quoted. This happens even for notifications, and then the body has no id.
   - Anything else: **400** `-32022` with `data` as above. This also applies to notifications, again with no id.

`checkHeaders(r, method, params.name, version)` returns the first error message in this order:

- `Header mismatch: header MCP-Protocol-Version is missing.`
- `Header mismatch: MCP-Protocol-Version "<h>" does not match _meta "<v>".` (Go `%q`)
- `Header mismatch: header Mcp-Method is missing.`
- `Header mismatch: Mcp-Method "<h>" does not match method "<m>".`
- Only when `method == "tools/call"`:
  - `Header mismatch: header Mcp-Name is missing.`
  - `Header mismatch: Mcp-Name is not valid Base64.`
  - `Header mismatch: Mcp-Name "<decoded>" does not match params.name "<name>".`

`decodeHeaderValue(v)` behaves as follows:

- If `v` starts with `=?base64?`, ends with `?=` and is at least 11 bytes long, the middle is decoded with
  `base64.StdEncoding`, falling back to `RawStdEncoding` (no padding). If both fail, the value is "not valid Base64".
- Otherwise the value is returned unchanged. `=?base64?=` is too short and is returned literally.

Headers are read with `Header.Get`, which is case-insensitive. There are **no sessions**. `Mcp-Session-Id` is never
sent or read, there is no SSE, and the `Accept` header is ignored.

### 1.4 Dispatch, methods, results

`dispatch(ctx, modern, method, params)` returns a `map[string]any` (result) or an `*rpcError`.

| method | legacy result | modern |
|---|---|---|
| `initialize` | `{"capabilities":{"tools":{"listChanged":false}},"instructions":<instructions>,"protocolVersion":<negotiated>,"serverInfo":{"name":"zipfelkasse","title":"Zipfelkasse – shared expenses","version":"1.1.0"}}` | `break`, so it falls through to Unknown method and **404** `-32601` `Unknown method: initialize` |
| `server/discover` | the same map as modern but without `resultType` (allowed in legacy too) | `{"_meta":{"io.modelcontextprotocol/serverInfo":{…}},"cacheScope":"public","capabilities":{"tools":{"listChanged":false}},"instructions":…,"resultType":"complete","supportedVersions":[4 versions],"ttlMs":<min(3600000, ms until next local midnight)>}` |
| `ping` | `{}` | `{"_meta":{…serverInfo},"resultType":"complete"}` |
| `tools/list` | `{"tools":[…9 defs…]}` | `{"_meta":…,"cacheScope":"public","resultType":"complete","tools":[…],"ttlMs":3600000}` |
| `tools/call` | see 2.1 | the same plus `_meta` and `resultType` |
| anything else | **HTTP 200** `{"jsonrpc":"2.0","id":…,"error":{"code":-32601,"message":"Unknown method: <m>"}}` | **HTTP 404**, same body |

For modern requests, after dispatch succeeds, `result["resultType"]="complete"` and `result["_meta"][serverInfoKey]=serverInfo()`
are added. This also happens for `isError:true` tool results. The map is then marshalled, so **keys are sorted
alphabetically** (Go `map[string]any`), and `_meta` sorts first because `_` (0x5F) is less than `a`.

Error codes:

| code | meaning |
|---|---|
| -32700 | parse |
| -32600 | invalid request |
| -32601 | method not found |
| -32602 | invalid params, and also an **unknown tool** (`Unknown tool: <name>`, or `Unknown tool: ` when the name is missing) |
| -32603 | `Result cannot be serialized.` |
| -32000 | forbidden |
| -32020 | header mismatch |
| -32022 | unsupported version |

The HTTP status is 200 for every dispatch error except modern -32601, which gives 404.

Response envelope (Go struct, so this field order is fixed):

```
{"jsonrpc":"2.0","id":<raw, omitempty>,"result":<omitempty>,"error":{"code":…,"message":…,"data":<omitempty>}}
```

`writeJSON` behaviour:

- Header `Content-Type: application/json`, with **no charset**.
- The body is `marshal(v)` + `"\n"`, a **trailing newline**.
- `marshal` is `json.Encoder` with `SetEscapeHTML(false)` and its own trailing newline trimmed, so `& < >` stay literal.
  `U+2028` and `U+2029` are still escaped as ` ` and ` ` (see section 3).
- If marshalling fails: `http.Error(…,"Internal Server Error",500)`.

`Content-Length` and `Date` are added by Go's server.

### 1.5 Instructions (dynamic, computed per request)

`instructions(ctx) = instructionsText + "\n" + todayLine() + ["\n" + overviewText(o)]`. If `Store.MCPOverview` fails,
the last part is omitted and `ERROR "mcp: data overview" err=…` is logged.

`instructionsText` (exact; the lines are joined with `\n`, and there is no trailing newline):

```
Zipfelkasse manages the shared expenses of a single group (like Splitwise/Spliit). All tools are read-only except create_expense and create_reimbursement, which add entries (nothing can be changed or deleted via MCP).
Amounts are in euros. Every amount in a result appears twice: as text with a dot as decimal separator and no thousands separator ("1234.56") and as an integer in cents (field ending in _cents).
Balance: positive = is owed money by the others, negative = owes money.
Reimbursements are settlement payments between two people, not expenses; they count for balances, not for expense statistics.
Dates use the format YYYY-MM-DD. Refer to people and categories by name (case-insensitive). Names, titles, categories and notes are stored as entered (often in German).
How to proceed: balances and settlement → balances; their development over time → balance_history. Finding individual expenses → search_expenses. Totals by category, merchant, period or person, also compared with the previous year → statistics. Who changed what when → activity.
Anything else → read schema first, then sql_query (SQLite, SELECT only).
Entering an expense → create_expense; a settlement payment between two people → create_reimbursement. Confirm unclear details with the user first and report what was created.
```

`todayLine()`:

```
Today is %s (%s), server time zone %s. Resolve relative periods such as "last month" from this date.
```

- The date is `DateOf(now().In(loc))` in `YYYY-MM-DD`.
- The weekday is Go's English `Weekday.String()` (`Friday`).
- The zone is `loc.String()`: `Europe/Berlin`, or **`Local`** when `TZ` is unset. Fixed zones give their name, for example `Test/Zone`.

`overviewText(o)`:

```
"Data overview: " +
  (FirstDate zero ? "there are no expenses yet."
                  : "%d expenses and %d reimbursements dated %s to %s. " + "%d of the expenses (%.1f%%) have no category.")
  + (len(ActivityActions)>0 ? " Values of activity.action: " + join(actions, ", ") + "." : "")
```

- `pct = WithoutCategory*100/Expenses`, or 0.0 when there are no expenses. Formatting is Go `%.1f`: correctly rounded, half-to-even on the exact binary value.
- Words are never pluralised differently: "1 reimbursements" is correct as written.
- Example: `Data overview: 4 expenses and 1 reimbursements dated 2026-08-15 to 2026-09-20. 1 of the expenses (25.0%) have no category. Values of activity.action: expense_created, expense_updated, settings_updated.`
- Empty database: `Data overview: there are no expenses yet. Values of activity.action: settings_updated.` Creating people logs `settings_updated`.

`MCPOverview` SQL:

```sql
SELECT coalesce(sum(is_reimbursement = 0), 0), coalesce(sum(is_reimbursement = 1), 0),
  coalesce(sum(is_reimbursement = 0 AND category_id IS NULL), 0), min(date), max(date)
  FROM expenses WHERE deleted_at IS NULL;
SELECT DISTINCT action FROM activity ORDER BY action;
```

`discoverTTL = min(1h, nextLocalMidnight - now)`, in milliseconds (an int64 JSON number). For example, 23:30 local gives 1800000.

### 1.6 Client IP (`clientIP`), exactly

```
remote = parseAddr(r.RemoteAddr)
if !remote.valid || remote ∉ TRUSTED_PROXIES: return remote        # headers ignored entirely
hops = for each X-Forwarded-For header line in order, split(",") → trim → drop empty
if hops empty:
    real = trim(Header.Get("X-Real-IP"))
    return real != "" ? parseAddr(real) : remote              # X-Real-IP is NOT checked against trusted
for i = len(hops)-1 down to 0:                                # right to left
    a = parseAddr(hops[i]); if !a.valid: return INVALID       # fail closed → 403
    if a ∉ TRUSTED_PROXIES: return a                          # first untrusted hop from the right = client
return parseAddr(hops[0])                                     # all hops trusted → leftmost
```

`parseAddr(s)` behaviour:

- Trims `s`, then tries `netip.ParseAddr`, then `net.SplitHostPort` followed by `ParseAddr(host)`.
- The result is `.Unmap().WithZone("")`, so IPv4-mapped IPv6 becomes IPv4 and zones are dropped.
- Accepted: `1.2.3.4`, `1.2.3.4:567`, `::1`, `[::1]:567`. Rejected (invalid): `[::1]` without a port, `garbage`, `@`.

`ContainsAddr` unmaps and uses `Prefix.Contains`. The table cases are in `TestClientIP` (section 6).

---

## 2. Tools

### 2.1 Common mechanics

- Registration order defines the `tools/list` order: `balances, balance_history, search_expenses, statistics, activity, schema, sql_query, create_expense, create_reimbursement`.
- Each definition is a **map**, so it is emitted with alphabetical keys: `{"annotations","description","inputSchema","name","title"}`. Every nested schema map is alphabetical too, for example `{"additionalProperties":false,"properties":{…},"required":[…],"type":"object"}`.
- Annotations:
  - Read tools: `{"destructiveHint":false,"idempotentHint":true,"openWorldHint":false,"readOnlyHint":true}`.
  - Write tools: `{"destructiveHint":false,"idempotentHint":false,"openWorldHint":false,"readOnlyHint":false}`.
- `tools/call` with an unknown name gives a JSON-RPC error `-32602` `Unknown tool: <name>` (HTTP 200), **not** `isError`. `info.tool` is set only for known tools.
- Tool success: `{"content":[{"text":"<text>","type":"text"}],"isError":false}`. The text is the tool's plain text (`schema`), or `marshal(data)` (compact JSON, no HTML escaping, **no trailing newline**). There is no `structuredContent` and no `outputSchema`.
- Tool failure: `{"content":[{"text":"<msg>","type":"text"}],"isError":true}` (HTTP 200).
  - If `errors.As(err, domain.ValidationError)`, `msg = err.Error()`.
  - Otherwise `msg = "Internal error while running the tool (details in the server log)."` and `ERROR "mcp: tool failed" tool=<n> err=<err>` is logged.
  - `msg` is also logged as `tool_error=`.
- Marshal failure of `data` (for example a NaN or Inf float) gives a JSON-RPC error `-32603` `Result cannot be serialized.`.
- `decodeArgs(raw, &args)`:
  - Empty, whitespace-only or `null` arguments count as `{}`. A missing `arguments` key does too.
  - Otherwise a `json.Decoder` with `DisallowUnknownFields` decodes **one** value. A failure becomes the `ValidationError` `Invalid arguments: <go error>`.
  - Go's texts (the port does not reproduce them; it names the field and the expected type, e.g. `Invalid arguments: limit must be an integer.`, see PORTING.md "Deliberate deviations"):
    - `Invalid arguments: json: unknown field "x"`
    - `Invalid arguments: json: cannot unmarshal array into Go value of type struct {}`
    - `Invalid arguments: json: cannot unmarshal string into Go value of type struct {}`
    - `Invalid arguments: json: cannot unmarshal string into Go struct field .limit of type int`
    - `Invalid arguments: json: cannot unmarshal number 0.5 into Go struct field .limit of type int` (also `5.0` and `1e2`)
    - `Invalid arguments: json: cannot unmarshal number 1.5 into Go struct field .expense_id of type int64`
    - `Invalid arguments: json: cannot unmarshal string into Go struct field .min_amount of type float64`
    - `Invalid arguments: json: cannot unmarshal string into Go struct field .allow_duplicate of type bool`
    - `Invalid arguments: json: cannot unmarshal string into Go struct field .moneyArgs.fx_rate of type float64`
    - `Invalid arguments: must be a string or a list of strings` (the `text` field)
    - `Invalid arguments: must be a string or a number` (`amount` or a `weights` value)
  - **Go field matching is case-insensitive** (not ported: keys match exactly). `{"LIMIT":2}` sets `limit`, `{"Name":"balances"}` works, and `{"Method":"ping"}` works at the envelope level. The **last duplicate key wins**.
  - `null` for a scalar field leaves its zero value. `"text": null` gives `[""]`, which means no filter.
- `eur(c)` = `FormatDecimal(c, 2, '.')`. For example `123456` gives `"1234.56"`, `-5` gives `"-0.05"` and `-300000` gives `"-3000.00"`.
- `money(minor, cur)` = `FormatDecimal(minor, CurrencyDecimals(upper(trim(cur))), '.') + " " + CUR`. For example `"23.40 USD"` and `"1500 JPY"`.
- `CurrencyDecimals`:
  - 0 for JPY, KRW, ISK, HUF, CLP, VND, XAF, XOF, PYG, UGX, IDR.
  - 3 for KWD, BHD, OMR, JOD, TND, LYD, IQD.
  - 2 for everything else.
- Date arguments (`parseDateArg(name, v)`):
  - Trimmed; empty means unset.
  - Otherwise `domain.ParseDate` tries the layouts `2006-01-02`, `02.01.2006` and `2.1.2006`. Go `time.Parse` validates day ranges, so `2026-02-30` is rejected, and the year must be within 2000–2100.
  - Any failure gives `Invalid date for <name>: "<v>" (expected YYYY-MM-DD).` (`%q`).
- `parseRange`: if `to < from`, the error is `"to" (YYYY-MM-DD) is before "from" (YYYY-MM-DD).`
- `describeRange(from,to)` returns one of: `all time`, `from X`, `until Y`, `X to Y`.
- Person lookup `findPerson`:
  - Over `ListParticipants(includeArchived=true)`, ordered `name COLLATE NOCASE, id`.
  - Matches with `strings.EqualFold` after trimming the argument.
  - Error: `Unknown person "<trimmed>". Available: A, B, C.` The list includes archived people.
- Category lookup `findCategory`:
  - Over `ListCategories(true)`, ordered `position, name COLLATE NOCASE, id`.
  - Error: `Unknown category "<x>". Available: Lebensmittel, Restaurant, ….`
- `categoryArg(name)`:
  - Blank means no filter.
  - A real category match wins.
  - Otherwise `none` or `No category` (EqualFold) means "without category".
  - Otherwise the findCategory error is returned.
- `cmpOr(v, fallback)` trims `v`. Enum arguments are therefore trimmed before validation, except `group_by` (trimmed separately) and the person and category names.

### 2.2 `balances`: "Balances and settlement"

Description:

```
Current balance of each person in euros and a settlement proposal (who transfers how much to whom so that everyone ends at 0). Positive balance = is owed money, negative = owes money. Includes all non-deleted expenses and reimbursements.
```

inputSchema: `{"additionalProperties":false,"properties":{},"type":"object"}`

Logic:

- `bal = Store.Balances()`: sum over non-deleted entries; payer `+amount`, each share `-share`.
- People are listed in ListParticipants(true) order. An archived person whose balance is 0 is skipped.
- `status` is `"is owed money"` when the balance is > 0, `"owes money"` when < 0, and `"settled"` otherwise.
- `settlements` comes from `domain.Settle` (greedy):
  - Repeatedly, the largest creditor and the largest debtor are chosen; ties go to the smaller id.
  - The transfer amount is `min(cred, -debt)`.
- Settlement names come from the id → name map, which includes archived people.

Output. The outer object is a map, so keys are alphabetical; the items are structs, so their keys keep field order:

```json
{"balances":[{"person":"Anna","balance":"12.50","balance_cents":1250,"status":"is owed money"},…],
 "note":"Positive balance = is owed money, negative = owes money. settlements: the transfers needed so that everyone ends at 0.",
 "settlements":[{"from":"Ben","to":"Anna","amount":"12.50","amount_cents":1250}]}
```

Empty lists are `[]`, never `null`.

### 2.3 `balance_history`: "Balance history"

Description:

```
Balance of each person at the end of each month (or week/year): how the balances developed over time. Based on the current data by expense date (later edits and deletions apply retroactively). Positive balance = is owed money, negative = owes money. Reimbursements count.
```

inputSchema:

```json
{"additionalProperties":false,"properties":{"from":{"description":"First period: the one containing this date. Default: the first expense. Format YYYY-MM-DD (DD.MM.YYYY is accepted too).","type":"string"},"interval":{"description":"Length of a period: month (default), week (ISO week) or year.","enum":["month","week","year"],"type":"string"},"person":{"description":"Name of a person: only their balance. Empty = everyone.","type":"string"},"to":{"description":"Last period: the one containing this date. Default: today. Format YYYY-MM-DD (DD.MM.YYYY is accepted too).","type":"string"}},"type":"object"}
```

Validation order and messages:

1. decode.
2. `interval` = `cmpOr(interval, "month")` must be in `[month, week, year]`, else `interval must be one of month, week, year.`
3. parseRange.
4. person (findPerson).
5. If `from` is set: count `Periods(interval, from, min(to or today, today))`. If it exceeds 500: `That is %d periods, at most 500 are possible. Please narrow down from/to or choose a longer interval.`

Algorithm:

- `until = PeriodEnd(interval, to)` if `to` is set, else open.
- `es = DatedBalanceEntries(until)` gives non-deleted expenses with shares, ordered `date, id, participant_id`, oldest first.
- If `to` is unset: `to = today`, or the date of the last entry if that is later.
- If `from` is unset and there are entries: `from = first entry date`.
- If `from` is still zero, or `to < from`: `from = to`.
- `periods = Periods(interval, from, to)`, followed by the same >500 check.
- Walk the periods. Entries with `PeriodOf(date) <= p` (a **string** comparison) are consumed cumulatively; entries before the first period form the opening balance. A snapshot is taken per period.
- Row people:
  - With `person`: only that person, even if archived.
  - Without: everyone except archived people who were zero in every snapshot.

Output:

```json
{"interval":"month","note":"Balance after all expenses dated up to the end of each period (in the current period also those dated later this period), positive = is owed money, negative = owes money. Without to, the last row equals the current balances. Computed from the current data by expense date: later edits and deletions apply retroactively.","period":"2026-07-01 to 2026-10-02","rows":[{"month":"2026-07","balances":[{"person":"Anna","balance":"0.00","balance_cents":0,"status":""},…]},…]}
```

The row struct is `historyOut{year omitempty, month omitempty, week omitempty, balances}`. Exactly one period key is
present. **Each balance item carries `"status":""`**, because `balanceOut.Status` has no omitempty (P11).

### 2.4 `search_expenses`: "Search expenses"

Description:

```
Searches individual expenses (newest first unless sort says otherwise) with amount, payer and category; with detail=full also split (each person's share), notes and foreign currency. All filters are optional and are combined. Also returns the total number of matches, their total and – with person – the total of that person's shares. For plain totals by category/month, statistics is the better choice.
```

inputSchema (exact, as emitted):

```json
{"additionalProperties":false,"properties":{"category":{"description":"Category name, e.g. \"Lebensmittel\". Use \"none\" for expenses without a category (statistics labels them \"No category\").","type":"string"},"detail":{"description":"compact (default): id, date, title, category, payer and amount per expense. full: additionally split, each person's share, notes and foreign currency.","enum":["compact","full"],"type":"string"},"from":{"description":"First date (inclusive). Format YYYY-MM-DD (DD.MM.YYYY is accepted too).","type":"string"},"involved":{"description":"Name of a person: only expenses this person has a share in.","type":"string"},"limit":{"description":"Maximum number of expenses returned, default 50.","maximum":500,"minimum":1,"type":"integer"},"max_amount":{"description":"Largest amount in euros (inclusive).","minimum":0,"type":"number"},"min_amount":{"description":"Smallest amount in euros (inclusive), e.g. 50 or 12.5.","minimum":0,"type":"number"},"paid_by":{"description":"Name of a person: only expenses this person paid.","type":"string"},"person":{"description":"Name of a person: finds expenses they paid OR take part in.","type":"string"},"reimbursements":{"description":"Reimbursements (settlement payments between people): hide them (exclude, default), include them (include) or return only them (only).","enum":["exclude","include","only"],"type":"string"},"sort":{"description":"Order of the expenses: date_desc (newest first, default), date_asc, amount_desc (most expensive first), amount_asc.","enum":["date_desc","date_asc","amount_desc","amount_asc"],"type":"string"},"text":{"anyOf":[{"type":"string"},{"items":{"type":"string"},"type":"array"}],"description":"Substring of the title or notes (case-insensitive). A list matches if any of the terms occurs, e.g. [\"Rewe\", \"Edeka\", \"Lidl\"]."},"to":{"description":"Last date (inclusive). Format YYYY-MM-DD (DD.MM.YYYY is accepted too).","type":"string"}},"type":"object"}
```

The category description is assembled from `categoryHint` =
`Use "none" for expenses without a category (statistics labels them "No category").`

Validation order and messages:

1. decode. `text` is a `stringList`: a string becomes `[s]`; an array of strings is kept; anything else gives `must be a string or a list of strings`.
2. parseRange.
3. category (categoryArg).
4. `person`, `paid_by`, `involved`, in that order, each through findPerson when not blank.
5. `min_amount`, then `max_amount`: `amountArg`. If the value is `<0`, NaN or `>1e12`: `<name> must be an amount in euros of at least 0.` Otherwise cents = `math.Round(v*100)`, rounding half away from zero (P14).
6. If `max_amount` was given and is 0 cents: `max_amount must be greater than 0.`
7. If `MaxCents != 0 && MinCents > MaxCents`: `min_amount (20.00) is greater than max_amount (10.00).`
8. `reimbursements` (cmpOr, default `exclude`): `reimbursements must be "exclude", "include" or "only".`
9. `sort` (default `date_desc`): `sort must be one of date_desc, date_asc, amount_desc, amount_asc.`
10. `detail` (default `compact`): `detail must be "compact" or "full".`
11. `limit`: 0 means 50; otherwise it must be within 1–500, else `limit must be between 1 and 500.`

Query (`ListExpenses`):

- Base condition: `deleted_at IS NULL`.
- Text: `textCond` folds each non-blank term in Go and adds `instr(zipfelkasse_fold(e.title), ?) > 0 OR instr(zipfelkasse_fold(e.notes), ?) > 0` per term; the terms are ORed inside parentheses.
- Category: `category_id IS NULL`, or `= ?`.
- person: `(paid_by = ? OR EXISTS share)`. paid_by: `paid_by = ?`. involved: `EXISTS share`.
- Amounts: `amount_cents >= ?` and `<= ?`, each only when non-zero.
- Dates: `date >= ?` and `<= ?`, both inclusive.
- Order:
  - `date_desc`: `e.date DESC, e.id DESC`
  - `date_asc`: `e.date, e.id`
  - `amount_desc`: `e.amount_cents DESC, e.date DESC, e.id DESC`
  - `amount_asc`: `e.amount_cents, e.date DESC, e.id DESC`
- Reimbursements are filtered **in Go** after the query (`exclude` or `only`).
- `matches` counts every remaining hit, and `total` sums their amounts. `person_share` sums `ShareOf(sharer)`, where the sharer is `person`, falling back to `involved`. Only the first `limit` hits are serialised.

Output (a map, so keys are alphabetical):

```
{"expenses":[expenseOut…],"matches":N,["person_share":{"amount":"..","amount_cents":..,"person":".."}],"shown":n,"total":"..","total_cents":..,"truncated":bool}
```

`person_share` is a map, so its keys are alphabetical too. `expenses` is `[]` when empty.

`expenseOut` (struct, field order fixed):

| field | json | omitempty |
|---|---|---|
| ID | `id` | no |
| Date | `date` | no |
| Title | `title` | no |
| Category | `category` | yes |
| PaidBy | `paid_by` | no |
| Amount | `amount` | no |
| AmountCents | `amount_cents` | no |
| Reimbursement | `reimbursement` | yes (false omitted) |
| Recipient | `recipient` | yes |
| Original | `original` | yes |
| FXRate | `fx_rate` | yes (float64, 0 omitted) |
| FXSource | `fx_source` | yes |
| Notes | `notes` | yes |
| Split | `split` | yes |
| Shares | `shares` | yes (`[{"person","amount","amount_cents"}]`) |

`expenseToOut`:

- Compact: id, date, title, category, paid_by, amount and amount_cents. A reimbursement additionally gets `reimbursement:true` and `recipient`, the name of the first share's participant.
- Full adds:
  - `notes`.
  - If foreign (`!IsEUR(OriginalCurrency)`): `original = money(...)`, `fx_rate` and `fx_source`.
  - If not a reimbursement: `split` (the mode string) and `shares`, in the store's order (by ParticipantID).
- Example (full):
  `{"id":4,"date":"2026-09-20","title":"Diner NYC","category":"Restaurant","paid_by":"Anna","amount":"20.00","amount_cents":2000,"original":"23.40 USD","fx_rate":1.17,"fx_source":"ezb","notes":"a\"b c","split":"equal","shares":[…]}`

### 2.5 `statistics`: "Statistics"

Description:

```
Expense totals grouped by category, title (merchant), year, month (YYYY-MM), ISO week (YYYY-Www), person or category_month, optionally for a period. Without share_of: total amounts of the expenses. With share_of: only that person's share of each expense, i.e. what they consumed themselves (e.g. "How much did I spend on restaurants in 2026?"). With group_by=person, amount is each person's share (consumption) and paid is what they paid up front. year, month and week list periods without expenses with 0. compare=previous_year adds the amount of the same group one year earlier and the change. Reimbursements and deleted expenses never count.
```

inputSchema:

```json
{"additionalProperties":false,"properties":{"category":{"description":"Only count expenses of this category (name, case-insensitive). Use \"none\" for expenses without a category (statistics labels them \"No category\").","type":"string"},"compare":{"description":"previous_year: compare each row with the same group one year earlier (month 2026-03 with 2025-03, category in from…to with from…to minus one year). For category, title and person, from is required.","enum":["previous_year"],"type":"string"},"from":{"description":"First date (inclusive). Format YYYY-MM-DD (DD.MM.YYYY is accepted too).","type":"string"},"group_by":{"description":"What to group by. title groups by expense title (case-insensitive), i.e. by merchant.","enum":["category","title","year","month","week","person","category_month"],"type":"string"},"limit":{"description":"Maximum number of rows, default 500. total always covers all rows.","maximum":500,"minimum":1,"type":"integer"},"share_of":{"description":"Name of a person: only their share counts (that person's perspective). Empty = total amounts.","type":"string"},"text":{"anyOf":[{"type":"string"},{"items":{"type":"string"},"type":"array"}],"description":"Substring of the title or notes (case-insensitive). A list matches if any of the terms occurs, e.g. [\"Rewe\", \"Edeka\", \"Lidl\"]."},"to":{"description":"Last date (inclusive). Format YYYY-MM-DD (DD.MM.YYYY is accepted too).","type":"string"}},"required":["group_by"],"type":"object"}
```

The limit description is generated with `fmt.Sprintf("… default %d. …", 500)`.

Validation order and messages:

1. decode.
2. `group_by` (trimmed) must be in the list, else `group_by must be one of category, title, year, month, week, person, category_month.`
3. parseRange.
4. category.
5. `share_of`: findPerson. This sets `perspective = "only the share of <Name>"`; the default is `"total amounts of the expenses"`.
6. `limit`: 0 means 500, else it must be within 1–500 (`limit must be between 1 and 500.`).
7. `compare` (trimmed):
   - `""` is fine.
   - Anything other than `previous_year`: `compare must be "previous_year".`
   - If the grouping is not time-keyed and `from` is zero: `compare=previous_year with group_by=<g> needs from (and optionally to): the period to compare.`
   - If not time-keyed and `to` is zero: when `today < from`, the error is `from (YYYY-MM-DD) is in the future; compare=previous_year needs a period up to today or an explicit to.`; otherwise `f.To = today`. This also changes the `period` text.

`timeKeyed` means `year`, `month`, `week` or `category_month`. `IsTimeGrouping` means `year`, `month` or `week` only.

Algorithm:

- `statRows = Store.Stats(f)` (SQL in section 4.5).
- For IsTimeGrouping, `fillGaps` runs:
  - `first = from`, or `PeriodStart(first row)`.
  - `last = min(to, today)` (via `cmpTime`).
  - `FillPeriods` adds zero rows for missing periods in first..last. Rows outside that range are kept, and everything is stable-sorted by period string.
- `total` is the sum over the (filled) rows.
- `out[i] = statToOut(row)`:
  - Period goes to `year`, `week` or (default) `month`.
  - Person grouping sets `paid` and `paid_cents` (pointer, so 0 is present).
- Compare (`comparePrevious`):
  - `prev = f` with `From` and `To` shifted −1 year via `ShiftDateYear` (Feb 29 becomes Feb 28).
  - `prevRows = Stats(prev)` when either bound is set; otherwise `prevRows = statRows`.
  - Each prev row's period is shifted +1 year via `ShiftPeriodYear` (`W53` becomes `W52` if the target year has no W53). The key is `category\0fold(title)\0person\0year\0month\0week`. Duplicate keys (W53 merged into W52) add `AmountCents` only.
  - For every out row: `previous = prev[key]` or 0, and `change = amount - previous`. `change_percent = math.Round(change*1000/previous)/10`, present only when `previous != 0`; it is a float such as `16.7` or `-100`.
  - Previous-only keys are appended in prev order as zero rows (`amount "0.00"`, count 0; person grouping also gets `paid "0.00"` and `paid_cents 0`). For time-keyed groupings a row is appended only if its period is within the window `[PeriodOf(from) or the min period of statRows, PeriodOf(min(to,today))]`; with no rows and no from, nothing is appended.
  - If anything was appended and the grouping is time-keyed, the output is stable-sorted by (period asc, amount_cents desc, category asc).
  - `previous_period`: `describeRange(prev.From, prev.To)`, or for time-keyed `"each " + TrimPrefix(group_by,"category_") + " one year earlier"`, which gives `each month one year earlier`, `each week …` or `each year …`.
  - `previous_total` is the sum of `previous_cents` over **all** rows, before truncation.
- `rows_total = len(out)` and `truncated = len(out) > limit`; then `out` is cut to `limit`.
- `note`:
  - Always: `Reimbursements and deleted expenses are not included. count = number of expenses.`
  - For person grouping, append: ` amount = the person's share (consumption), paid = what they paid for the group.`
  - With compare, append: ` previous = same group one year earlier, change = amount − previous, change_percent relative to previous (missing if previous is 0).` The `−` is U+2212.

Output map keys (alphabetical):

```
group_by, note, period, perspective, [previous_period, previous_total, previous_total_cents], rows, rows_total, total, total_cents, truncated
```

`statOut` (struct order):

| field | json | type and omitempty |
|---|---|---|
| Category | `category` | string, omitempty |
| Title | `title` | string, omitempty |
| Year | `year` | string, omitempty |
| Month | `month` | string, omitempty |
| Week | `week` | string, omitempty |
| Person | `person` | string, omitempty |
| Count | `count` | int64 |
| Amount | `amount` | string |
| AmountCents | `amount_cents` | int64 |
| Paid | `paid` | string, omitempty |
| PaidCents | `paid_cents` | *int64, omitempty |
| Previous | `previous` | string, omitempty |
| PreviousCents | `previous_cents` | *int64, omitempty |
| Change | `change` | string, omitempty |
| ChangeCents | `change_cents` | *int64, omitempty |
| ChangePercent | `change_percent` | *float64, omitempty |

The `rows` list is `[]` when empty.

### 2.6 `activity`: "Activity log"

Description:

```
Who created, changed or deleted which expense when, and other changes (settings, people, categories, rates, recurring expenses), newest first. Entries of expense_updated list the changed fields with old and new value (field names and values as shown in the app, in German).
```

inputSchema:

```json
{"additionalProperties":false,"properties":{"action":{"description":"Only this action, e.g. expense_created, expense_updated, expense_deleted, settings_updated.","type":"string"},"before_id":{"description":"Paging: only entries with a smaller id (pass the id of the last entry of the previous page).","minimum":1,"type":"integer"},"expense_id":{"description":"Only entries of this expense (id as in search_expenses).","minimum":1,"type":"integer"},"from":{"description":"First day (inclusive, server time zone). Format YYYY-MM-DD (DD.MM.YYYY is accepted too).","type":"string"},"limit":{"description":"Maximum number of entries, default 50.","maximum":500,"minimum":1,"type":"integer"},"person":{"description":"Name of a person: only changes they made.","type":"string"},"to":{"description":"Last day (inclusive, server time zone). Format YYYY-MM-DD (DD.MM.YYYY is accepted too).","type":"string"}},"type":"object"}
```

Validation order and messages:

1. decode. `expense_id` and `before_id` are int64.
2. parseRange.
3. `Since = from 00:00` in loc, and `Until = (to+1 day) 00:00` in loc.
4. person: findPerson, which sets ActorID.
5. If either id is negative: `expense_id and before_id must be positive.`
6. limit: 0 means 50, else `limit must be between 1 and 500.`

Query (`ListActivity`):

- Filters: `a.expense_id = ?`, `a.actor_id = ?`, `a.action = ?` (action trimmed, exact match).
- Time bounds: `a.at >= Since.UTC().Format(RFC3339)` and `a.at < Until…`. This is a text comparison; `at` is stored as RFC3339 UTC with second precision.
- Paging: `a.id < ?`.
- Order and limit: `ORDER BY a.id DESC LIMIT limit+1`.
- `details_json` that cannot be parsed is ignored.

Then `more = len > limit`, and the list is cut to `limit`.

`activityOut` (struct order):

| field | json | omitempty |
|---|---|---|
| ID | `id` | no |
| At | `at` | no |
| Actor | `actor` | no |
| Action | `action` | no |
| ExpenseID | `expense_id` | yes (int, 0 omitted) |
| Title | `title` | yes |
| Amount | `amount` | yes |
| AmountCents | `amount_cents` | yes (*int64) |
| Changes | `changes` | yes (`[{"field","old","new"}]`, values German as stored) |
| Text | `text` | yes |

- `at` is `a.At.In(loc).Format(time.RFC3339)`, for example `2026-10-03T08:13:34+02:00`, with `Z` when the offset is 0.
- `actor` is `cmpOr(ActorName, "system")`.
- `amount` and `amount_cents` are set only when `Details.AmountCents != 0`.

Output map: `{"entries":[…],"more":bool,["note":"There are older entries: call again with before_id=<last id>."],"shown":n}`.
`entries` is `[]` when empty, because it is built with `make`.

### 2.7 `schema`: "Database schema" (plain text result)

Description:

```
Explains the database tables and columns in words (amounts in cents, deleted expenses, reimbursements, shares, foreign currency), lists people and categories and returns the CREATE statements. Call before sql_query.
```

Input schema: `{"additionalProperties":false,"properties":{},"type":"object"}`

Text:

```
todayLine + "\n\n" + schemaText + "\nPeople (id: name): " + join("<id>: <name>[ (archived)]", ", ")
+ "\nCategories (id: name): " + join(same) + "\n\nCREATE statements:\n" + for each object: SQL + ";\n"
```

`schemaText` is verbatim from `internal/mcp/tools.go` lines 1164–1200, ending with `GROUP BY 1 ORDER BY 2 DESC;\n`.
It embeds `coalesce(c.name, 'No category')`. The full rendered output, including the today line, people, categories and
all CREATE statements of the current migrations, is in `probe_mcp_decoded.txt` under `### tool schema` (the `TEXT:`
line). Copy it byte for byte. Note `→`, `–` and `−` in the text.

CREATE statements come from `MCPSchema`:

```sql
SELECT type, name, tbl_name, sql FROM main.sqlite_schema WHERE type IN ('table','index') AND sql IS NOT NULL ORDER BY type DESC, rowid
```

Rows are kept only if `tbl_name` is in MCPTables, so tables come first, then indexes, each in rowid order. The text is
exactly what SQLite stored, so the migrations must be ported byte-identically, including comments and alignment, for this
output to match.

### 2.8 `sql_query`: "SQL query"

Description, built with `fmt.Sprintf` from 500 and 5:

```
Runs exactly one read-only SQL query (SQLite dialect, only SELECT or WITH … SELECT) on a read-only copy of the data. Call schema first. Important: amounts are cents (divide by 100.0 for euros), exclude deleted expenses with deleted_at IS NULL, reimbursements (is_reimbursement = 1) are not expenses, a person's share is expense_shares.amount_cents. At most 500 rows, aborted after 5 seconds, texts longer than 2000 characters are truncated. For standard questions, balances, search_expenses and statistics are simpler.
```

inputSchema:

```json
{"additionalProperties":false,"properties":{"query":{"description":"The SQL query, e.g. SELECT name FROM participants WHERE archived_at IS NULL","type":"string"}},"required":["query"],"type":"object"}
```

Steps:

1. decode.
2. If the query is blank after trimming: `Parameter query is missing.`
3. A semaphore of capacity **2** (`sqlSem`). If it cannot be acquired before ctx is done (20 s tool timeout or client gone): `Too many concurrent queries, please try again.`
4. `Store.ReadOnlyQuery` (section 4). A ValidationError is passed through; any other error becomes `sql_query: <err>`, which surfaces as the generic Internal error text.
5. Output map: `{"columns":[…],["note":"There are more than 500 rows; only the first 500 are included. Please aggregate or narrow down with WHERE/LIMIT."],"row_count":n,"rows":[[…]…],"truncated":bool}`.

### 2.9 `create_expense`: "Create expense" (write)

Description:

```
Creates an expense, as if the payer had entered it in the app. Ask the user before calling it if anything is unclear (amount, payer, who takes part); then tell them what was created. Without participants and weights, the amount is split equally among all active people. An entry with the same date, payer, amount and title is refused unless allow_duplicate is set. Settlement payments between people are not expenses: use create_reimbursement for them.
```

inputSchema:

```json
{"additionalProperties":false,"properties":{"allow_duplicate":{"description":"Create it even if an entry with the same date, payer, amount and title exists. Only set after asking the user.","type":"boolean"},"amount":{"description":"Amount in currency (default EUR) with a dot as decimal separator, e.g. \"23.40\".","type":["string","number"]},"category":{"description":"Category name (case-insensitive). Empty = no category.","type":"string"},"currency":{"description":"ISO currency code, e.g. USD. Default EUR.","type":"string"},"date":{"description":"Date of the expense. Default today. Format YYYY-MM-DD (DD.MM.YYYY is accepted too).","type":"string"},"fx_rate":{"description":"Only for a foreign currency: units of that currency per 1 EUR. Default: the ECB reference rate of the date.","exclusiveMinimum":0,"type":"number"},"notes":{"description":"Optional note.","type":"string"},"paid_by":{"description":"Name of the person who paid.","type":"string"},"participants":{"description":"Only for split=equal: names of the people the expense is for. Default: all active people.","items":{"type":"string"},"type":"array"},"split":{"description":"equal (default): evenly among participants. shares, percent, amount: by the values in weights.","enum":["equal","shares","percent","amount"],"type":"string"},"title":{"description":"What was bought, e.g. \"Rewe\" or \"Pizza\" (usually German, like the existing titles).","type":"string"},"weights":{"additionalProperties":{"type":["string","number"]},"description":"For shares, percent and amount: person name → value, e.g. {\"Anna\": 2, \"Ben\": 1} (shares), {\"Anna\": 70, \"Ben\": 30} (percent, sum 100) or {\"Anna\": \"15.00\", \"Ben\": \"8.40\"} (amounts in currency, sum = amount). These people are the participants.","type":"object"}},"required":["title","amount","paid_by"],"type":"object"}
```

Arguments: the embedded `moneyArgs{amount amountText, currency string, fx_rate *float64}`, plus title, date, paid_by,
category, split, `participants []string`, `weights map[string]amountText`, notes and `allow_duplicate bool`.

`amountText` accepts a JSON string as is, or a JSON number as its **literal text** (`json.Number.String()`, so `8.40`
stays `8.40` and `1e3` stays `1e3`). Anything else gives `must be a string or a number`.

Validation order and messages:

1. decode.
2. `title` is trimmed. If empty: `Parameter title is missing.`
3. `split` = `cmpOr(split, "equal")`. If not valid: `split must be one of equal, shares, percent, amount.`
4. `date` = parseDateArg("date"), or today in the server timezone. Error: `Invalid date for date: "morgen" (expected YYYY-MM-DD).`
5. `setMoney`:
   1. `cur = upper(cmpOr(currency,"EUR"))`. If it is not three ASCII A–Z letters: `currency must be a three-letter ISO code such as USD, not "<original currency arg>".`
   2. Blank amount: `Parameter amount is missing.`
   3. `parseDecimal(amount, CurrencyDecimals(cur))`. On error: `Invalid amount "<amount>" for <CUR>: <reason>`. Reasons:
      - `use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50`
      - `must be a whole number`
      - `at most <n> decimal places`
      - `too large`
      - Note that this message has **no trailing period**.
   4. If `minor <= 0`: `amount must be greater than 0.`
   5. EUR: if `fx_rate` is given, `fx_rate is only for foreign currencies.`; otherwise `AmountCents = minor`.
   6. Foreign currency:
      - `OriginalAmountMinor` and `OriginalCurrency` are set.
      - If `fx_rate` is given: when `<= 0`, the error is `fx_rate must be greater than 0.`; otherwise `FXSource = "manuell"`.
      - If no fx_rate: `FX.Rate(ctx, cur, date)`. If FX is nil, the call errors or the rate is `<= 0`:
        `There is no exchange rate for <CUR> on <YYYY-MM-DD>. Ask the user for the rate and pass it as fx_rate.`
        An FX error is also logged as `INFO "mcp: rate not available" currency=… date=… err=…`.
        Otherwise `FXSource = rate.Source`, or `"ezb"` when that is empty.
6. People: `participantNames` (all people, including archived). `activePerson(ps, "paid_by", paid_by)`:
   - Blank: `Parameter paid_by is missing.`
   - Matches an archived person (EqualFold): `<Name> is archived and cannot take part in new entries.`
   - No match: `Unknown person "<trimmed>" in paid_by. Available: <active names>.` The list contains active people only.
7. `category` (if not blank): findCategory, so the unknown-category error applies. If the category is archived: `Category <Name> is archived.`
8. `splitArgs(ps, mode, cmpOr(OriginalCurrency,"EUR"), participants, weights)`:
   - **equal**:
     - Non-empty weights: `weights are only for split=shares, percent or amount; use participants for an equal split.`
     - No participants: every **active** person, in ListParticipants order, with weight 0.
     - Otherwise each name goes through `activePerson(ps, "the split", name)`. Errors: `Unknown person "X" in the split. Available: …`, or the archived message. A repeated name gives `<Name> appears twice in the split.`
   - **other modes**:
     - Participants given: `With split=<mode>, weights name the participants; leave participants out.`
     - Empty weights: `split=<mode> needs weights (person name → value).`
     - Weights are processed in **sorted key order** (Go byte-wise sort). Each value goes through `parseDecimal(value, WeightDecimals(mode,cur))`: shares 0, percent 2 (basis points), amount uses the currency's decimals. Error: `Invalid value "<v>" for <name> in weights: <reason>.`, which **has** a trailing period. Then addPart.
9. `create(...)`, shared with create_reimbursement:
   - `cents = AmountCents`, or `ToEURCents(minor, cur, rate)` for foreign currency (`round(minor/10^dec/rate*100)`, half away from zero).
   - Unless `allow_duplicate`, and when cents > 0: `ListExpenses{From=To=date, PaidBy, MinCents=MaxCents=cents}`. A hit of the same kind matches when, for an expense, `Fold(e.Title) == Fold(in.Title)`, or for a reimbursement, when `e.ShareOf(recipient) != 0`. Error:
     `This looks like a duplicate of entry <id> (<YYYY-MM-DD>, <title>, <eur> EUR, paid by <payer>). Ask the user; if it really is a second one, call again with allow_duplicate=true.`
   - `Store.CreateExpense(ctx, actorID=payer.ID, in)`. A store ValidationError gives `The app refused the entry (message in German): <German msg>`, for example `…: Die Prozente müssen zusammen 100 % ergeben (aktuell 90,00 %).`
   - Logs `INFO "mcp: entry created" id=<id> reimbursement=<bool>`.
   - Result: `{"created":<expenseToOut(GetExpense(id), full=true)>,"note":"Created as entry <id> with <payer> as author. Changing or deleting it is only possible in the app."}`

`parseDecimal(s, decimals)` exactly:

```
s = TrimSpace(s); whole, frac = Cut(s, "."); frac = TrimRight(frac, "0")
digits(v) := Trim(v, "0123456789") == ""      # ASCII digits only; empty string counts as digits
if whole=="" || !digits(whole) || !digits(frac) → "use digits with a dot …, e.g. 1234.50"
elif len(frac) > decimals && decimals == 0        → "must be a whole number"
elif len(frac) > decimals                          → "at most %d decimal places"
elif len(whole) > 15                               → "too large"
return ParseInt(whole + frac + "0"*(decimals-len(frac)))
```

| accepted | result |
|---|---|
| `"23.4",2` | 2340 |
| `"23.40"` | 2340 |
| `"23"` | 2300 |
| `"1.000"` | 100 |
| `"1200.00",0` | 1200 |
| `"0.5"` | 50 |
| `" 7 "` | 700 |
| `"5."` | 500 |

Rejected: `1.234` (3 decimals), `1,5`, `1.000,00`, `-1`, `+1`, `.5`, `1e3`, `""`, `1.2.3`, `1 000`.

### 2.10 `create_reimbursement`: "Create reimbursement" (write)

Description:

```
Records a settlement payment: from paid amount to to (e.g. a bank transfer to settle up). It changes the balances, but is not an expense. An entry with the same date, payer, amount and recipient is refused unless allow_duplicate is set.
```

inputSchema:

```json
{"additionalProperties":false,"properties":{"allow_duplicate":{"description":"Create it even if an entry with the same date, payer, amount and recipient exists. Only set after asking the user.","type":"boolean"},"amount":{"description":"Amount in currency (default EUR) with a dot as decimal separator, e.g. \"23.40\".","type":["string","number"]},"currency":{"description":"ISO currency code, e.g. USD. Default EUR.","type":"string"},"date":{"description":"Date of the payment. Default today. Format YYYY-MM-DD (DD.MM.YYYY is accepted too).","type":"string"},"from":{"description":"Name of the person who paid the money.","type":"string"},"fx_rate":{"description":"Only for a foreign currency: units of that currency per 1 EUR. Default: the ECB reference rate of the date.","exclusiveMinimum":0,"type":"number"},"notes":{"description":"Optional note.","type":"string"},"to":{"description":"Name of the person who received it.","type":"string"}},"required":["from","to","amount"],"type":"object"}
```

Validation order:

1. decode. A `title` argument gives `Invalid arguments: json: unknown field "title"`.
2. `Title = "Rückzahlung"` and `IsReimbursement = true` (no SplitMode is set; the store decides).
3. date.
4. setMoney.
5. `activePerson(ps,"from",from)`: `Parameter from is missing.` or `Unknown person "X" in from. Available: …`
6. `activePerson(ps,"to",to)`: `Parameter to is missing.` and so on.
7. If from and to are the same person: `from and to must be different people.`
8. `Parts = [{ParticipantID: to}]`.
9. `create(...)` (duplicate check by recipient).

The result's `created` has `reimbursement:true` and `recipient`, and no split or shares.

---

## 3. JSON serialisation rules a port must match byte for byte

1. **Go maps are serialised with keys sorted by bytes.** All tool result envelopes, tool definitions, schemas, `serverInfo`, `annotations`, `capabilities`, `person_share`, the error `data`, and the result maps of `balances`, `search_expenses`, `statistics`, `activity`, `sql_query` and `create`.
2. **Go structs keep declaration order.** These include `response{jsonrpc,id,result,error}`, `rpcError{code,message,data}`, `balanceOut{person,balance,balance_cents,status}`, `transferOut{from,to,amount,amount_cents}`, `shareOut{person,amount,amount_cents}`, `expenseOut`, `statOut`, `historyOut`, `activityOut`, `FieldChange{field,old,new}`, and the export structs (section 5). Use ordered emission (`JSON::Builder` in field order) for structs, and **sort keys** for the "map" objects.
3. `omitempty`:
   - Omits `""`, `0`, `false`, nil pointers, and nil or **empty** slices and maps.
   - A non-nil `*int64` pointing to 0 **is** emitted (`paid_cents`, `previous_cents`, `change_cents`, `amount_cents` in activity).
   - `"status":""` in balance_history is emitted because that field has no omitempty.
4. Empty slices:
   - Built as `[]T{}` or with `make`, so they emit `[]`: balances, settlements, expenses, rows (statistics, history, sql), entries, history row balances.
   - `shares` in expenseOut is nil when there are no shares; with omitempty it is omitted either way.
   - `sql_query` rows are forced to `[]`.
5. HTML escaping:
   - **MCP**: `SetEscapeHTML(false)`, so `<`, `>` and `&` are literal.
   - **Export JSON**: `json.NewEncoder(w)` with the **default** escaping, so `<` becomes `<`, `>` becomes `>` and `&` becomes `&`.
6. Escapes always applied by Go:
   - `\"` and `\\`.
   - `\b`, `\f`, `\n`, `\r`, `\t`.
   - Other control characters below 0x20 become `\u00XX`, with **lowercase** hex.
   - **U+2028 and U+2029 become ` ` and ` `, even with EscapeHTML(false).**
   - Invalid UTF-8 bytes become `�`.
   - `/` is **not** escaped, and non-ASCII characters (ü, €, –, →) are emitted raw as UTF-8.
7. Trailing newline:
   - MCP HTTP bodies are `marshal(...) + "\n"`.
   - The inner tool `text` JSON has **no** trailing newline.
   - Export JSON (`Encoder.Encode` with `SetIndent("", "  ")`) ends with `"\n"`.
8. float64 formatting (`fx_rate`, `change_percent`, sql_query reals; also `fx_rate` in the export):
   - Shortest round-trip digits (`strconv` with `-1` precision).
   - Format `'f'` if `1e-6 <= |x| < 1e21` or `x == 0`, else `'e'`. In `'e'`, an exponent of the form `e-0X` is shortened to `e-X` (only that case). Examples: `1e+30`, `1e-7`, `1.5e-7`, `1e+21`.
   - Integral floats print **without** `.0`: `1`, `160`, `-100`, `50`.
   - NaN and ±Inf are unsupported. They give a marshal error, which for MCP becomes -32603 `Result cannot be serialized.`
   - Crystal's `Float#to_json` prints `1.0`, `1.0e+30` and `1.0e-07`, so a custom formatter is needed.
9. Integers are plain decimal int64.
10. `time.Time` (export only): `MarshalJSON` uses RFC3339Nano. Fractional seconds appear only when non-zero and have trailing zeros trimmed (`2026-10-03T06:14:49.339316322Z`). In UTC the suffix is `Z`.
11. A raw JSON `id` is echoed as given (compacted).

---

## 4. `internal/store/mcp.go`: the SQL sandbox and statistics

### 4.1 Constants

| name | value |
|---|---|
| `MCPTables` | `participants, categories, expenses, expense_shares, recurring, activity, fx_rates, settings` |
| `mcpRowFilter` | `{"settings": "key NOT LIKE 'ynab%'"}` |
| `SQLMaxRows` | 500 |
| `SQLTimeout` | 5s, total, including the copy |
| `sqlMaxCellRunes` | 2000 |
| `sqlMaxResult` | 8 MiB (`SQLITE_LIMIT_LENGTH`) |

### 4.2 `ReadOnlyQuery(ctx, query)`

1. `body = checkSelect(query)`, a lexical check (4.3). It returns the query cut at the first top-level `;`.
2. A context with a 5 s timeout.
3. `sandbox(ctx)`:
   - If `store.path` is `":memory:"` or `""`: `sql_query needs a database file (not available with :memory:).`
   - `filepath.Abs(path)`.
   - Open a new `sql.Open("sqlite", ":memory:")` with `MaxOpenConns=1` and take one `*sql.Conn`.
   - `fillSandbox(conn, abs)`:
     1. `ATTACH DATABASE ? AS src` with `url.URL{Scheme:"file", Path:abs, RawQuery:"mode=ro"}.String()`, which gives `file:///abs/path?mode=ro` with the path percent-escaped. On failure: `open database read-only: <err>`.
     2. `BEGIN`. `schemaObjects(conn,"src")` returns the src tables, then the indexes, in rowid order, filtered by MCPTables.
     3. For each object: exec its CREATE SQL in main. For a table, also run `INSERT INTO main."<t>" SELECT * FROM src."<t>"` plus ` WHERE key NOT LIKE 'ynab%'` for settings. Errors are wrapped as `sandbox <name>: <err>`.
     4. `COMMIT`. On error, `ROLLBACK` with a background context.
     5. `DETACH DATABASE src`.
     6. `sqlite3_limit(SQLITE_LIMIT_ATTACHED, 0)`, so ATTACH fails afterwards.
     7. `sqlite3_limit(SQLITE_LIMIT_LENGTH, 8 MiB)`.
     8. `PRAGMA query_only = ON`.
   - The YNAB tables never exist in the copy. `sqlite_schema`, `pragma_database_list` and `pragma_table_list` show nothing about YNAB. `temp.` and `src.` references fail.
   - The scalar function `zipfelkasse_fold(x)` is available in the sandbox, because modernc registers it globally for every connection. It returns the folded text for text and blobs, NULL for NULL, and other values unchanged (`zipfelkasse_fold(42)` is `42`).
4. `runWrapped(conn, body)`:
   - Column info comes from **preparing `body` alone**, as `sqlite3_column_name` for each column. If there are no columns: `The query returns no columns. Only SELECT or WITH … SELECT is allowed.`
   - Column names are the alias, or the expression text for unaliased columns (`SELECT 1, 1, 'a' AS x, 'b' AS x` gives `["1","1","x","x"]`). Duplicates are allowed.
   - The executed SQL (exact whitespace):

     ```
     WITH mcp_u(c0, c1, …) AS (
     <body>
     )
     SELECT count(*), json_group_array(json_array(<cell0>, <cell1>, …)) FROM (SELECT * FROM mcp_u LIMIT 501)
     ```

     with each cell being:

     ```
     CASE typeof(cI) WHEN 'blob' THEN '[BLOB, ' || length(cI) || ' Bytes]' WHEN 'text' THEN substr(cI, 1, 2000) ELSE cI END
     ```

   - The whole result is produced in **one `sqlite3_step`**. The driver calls `sqlite3_interrupt` when the context expires.
   - The JSON array is decoded with `UseNumber`. If there are more than 500 rows, the first 500 are kept and `Truncated=true`.
   - Each number is converted to int64 when `ParseInt` succeeds, else float64 when `ParseFloat` succeeds, else left as a `json.Number` and emitted verbatim. `9e999` therefore comes out as `9.0e+999`, the text SQLite's JSON printer produced.
   - Cell values are int64, float64, string or nil (SQL NULL becomes JSON null). Booleans do not occur.
   - Observed values:
     - `1.0` → `1`
     - `0.1+0.2` → `0.30000000000000004`
     - `1e30` → `1e+30`
     - `1e-7` → `1e-7`
     - `-0.0` → `0`
     - a blob → `"[BLOB, 2 Bytes]"`
     - `json_object(...)` → a JSON **string** (the subtype is lost through the CASE)
     - `'<&>'` → `"<&>"`
5. Error mapping (`sandboxErr`), in order:
   1. ctx deadline exceeded (either check): `The query was aborted after 5 s. Please narrow it down (WHERE, LIMIT) or simplify it.`
   2. An existing ValidationError is passed through.
   3. A `*sqlite.Error` with code `SQLITE_TOOBIG`: `The result is too large. Please query fewer columns/rows.`
   4. Any other `*sqlite.Error`: `SQL error: ` + `TrimPrefix(err.Error(), "SQL logic error: ")`. The modernc error text is `"<sqlite3_errstr(rc)>: <sqlite3_errmsg> (<rc>)"`, so this gives for example:
      - `SQL error: no such table: doesnotexist (1)`
      - `SQL error: near "FROM": syntax error (1)`
      - `SQL error: no such table: ynab_config (1)`

      When `errmsg == errstr`, the text is `"<errstr> (<rc>)"`. For `SQLITE_BUSY`, ` (SQLITE_BUSY)` is appended.
   5. Anything else is returned raw, and the tool layer turns it into an Internal error.

### 4.3 `checkSelect(query)`: a lexical scanner, mirroring SQLite's tokenizer for the relevant parts

- A NUL byte anywhere gives `The query contains a NUL character.`
- The scanner skips whitespace (` \t\n\r\f\v`), `--` comments to the newline, `/* … */` comments (unterminated runs to the end), quoted runs in `'…'`, `"…"` and `` `…` `` (a doubled quote is an escape; unterminated runs to the end), and `[…]`.
- The first `;` at top level sets `end`. Further `;` characters are fine. Any other token after `end` gives `Please send only a single query (no second statement after ";").`
- The first keyword is the run of ASCII letters and `_` from the first token start, upper-cased. A non-letter token start uses that single character.
- The keyword must be `SELECT` or `WITH`, else `Only a single read-only query is allowed (SELECT … or WITH … SELECT …).` This rejects empty input, comment-only input, `(SELECT 1)`, `EXPLAIN …`, `PRAGMA …`, `ATTACH …` and `VACUUM …`.
- It returns `query[:end]`, which keeps leading whitespace and comments.
- The test cases are listed in section 6.

### 4.4 Defence layers (all must exist in the port)

1. Lexical: one SELECT or WITH statement.
2. Syntactic: the query is embedded as a CTE body, so a non-SELECT body is a syntax error.
3. The query runs on an in-memory copy, never the real file. The copy is made over a `mode=ro` URI attach inside a read transaction, which gives a consistent snapshot.
4. `ATTACH` is impossible because of the limit of 0 attached databases.
5. `query_only`.
6. The length limit caps the result size.
7. 5 s total, including the copy, enforced through interrupt.
8. At most 2 concurrent sandboxes.

### 4.5 Statistics (used by the `statistics` tool)

Constants:

```
group_by values: category, title, year, month, week, person, category_month
NoCategory = "No category"
statsPeriod (SQL):
  year:           substr(e.date, 1, 4)
  month:          substr(e.date, 1, 7)
  category_month: substr(e.date, 1, 7)
  week:           strftime('%G-W%V', e.date)      # needs SQLite ≥ 3.46 (P16)
```

`Stats(f)`:

```
where = ["e.deleted_at IS NULL", "e.is_reimbursement = 0"]
        + ["e.date >= ?"] + ["e.date <= ?"]
        + ("e.category_id IS NULL" | "e.category_id = ?")
        + textCond(AnyText)
person grouping → statsByPerson
from   = "expenses e LEFT JOIN categories c ON c.id = e.category_id"
amount = "e.amount_cents"
if ParticipantID: from += " JOIN expense_shares x ON x.expense_id = e.id AND x.participant_id = ?"
                  (that arg is PREPENDED); amount = "x.amount_cents"
cat = "coalesce(c.name, 'No category')"
category:       SELECT cat, ''                  GROUP BY cat                   ORDER BY 4 DESC, 1
title:          SELECT max(e.title), ''         GROUP BY zipfelkasse_fold(e.title) ORDER BY 4 DESC, 1
year/month/week:SELECT '', <period>             GROUP BY <period>              ORDER BY 2
category_month: SELECT cat, <period>            GROUP BY cat, <period>         ORDER BY 2, 4 DESC, 1
query = "SELECT <sel>, count(*), sum(<amount>) FROM <from> WHERE <and-joined> GROUP BY <group> ORDER BY <order>"
unknown grouping → invalid("Unknown grouping %q.")
```

The label goes to `Title` for title grouping, otherwise to `Category`. `max(e.title)` uses binary collation, so
`Rewe` beats `REWE`.

`statsByPerson`:

```sql
SELECT p.name,
  (SELECT count(*) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id WHERE x.participant_id = p.id AND <cond>),
  (SELECT coalesce(sum(x.amount_cents), 0) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id WHERE x.participant_id = p.id AND <cond>),
  (SELECT coalesce(sum(e.amount_cents), 0) FROM expenses e WHERE e.paid_by = p.id AND <cond>)
FROM participants p WHERE 1 = 1[ AND p.id = ?]
```

- The arguments are repeated three times, with the optional p.id last.
- Rows with `count == 0 && paid == 0` are dropped. Archived people are included otherwise.
- Rows are stable-sorted by amount desc, then `strings.ToLower(name)` asc.
- With share_of, only that person is returned. Its amount is still that person's own share.

Period helpers. ISO weeks follow Go's `ISOWeek`.

- `PeriodOf`: `"2006"`, `"2006-01"` or `"%d-W%02d"`.
- `Periods(first, last)`: from the period start of `first`, step by period, until reaching `PeriodOf(last)` (string compare). Returns nil if `last < first`.
- `PeriodEnd`: the next period start minus one day.
- `PeriodStart(groupBy, period)`: parses with Sscanf `%4d`, `%4d-W%2d` or `%4d-%2d`. Week N starts at the Monday of the week containing Jan 4, plus 7·(N−1) days. Zero on a parse error.
- `ShiftPeriodYear`:
  - `"" → ""`.
  - The first 4 characters are the year. A non-numeric year leaves the value unchanged.
  - The output is `%04d` + the rest.
  - `-W53` becomes `-W52` when Dec 28 of the target year falls in ISO week < 53.
- `ShiftDateYear`: Feb 29 becomes Feb 28 in non-leap years. Everything else keeps month and day.
- `FillPeriods`: only for year, month and week; unchanged if `last < first`.

---

## 5. Export (`internal/export`)

### 5.1 Routes

All are behind `web.Wrap`: security headers, the 1 MiB body limit, cross-origin protection and the identity cookie `wer`.
Without a valid, non-archived identity, a GET gets **303** `Location: /wer?zurueck=<QueryEscape(RequestURI)>` with the
body `<a href="…">See Other</a>.\n\n`. A POST gets 303 to `/wer`. The patterns are method-specific (`GET /export…`), so a
POST with a valid identity gets **405** from Go's mux.

| route | handler | Content-Type | filename |
|---|---|---|---|
| `GET /export` | HTML page `export.html` (title "Export", nav = settings) | text/html | n/a |
| `GET /export/ausgaben.csv` | all expenses as CSV | `text/csv; charset=utf-8` | `zipfelkasse-ausgaben-<suffix>.csv` |
| `GET /export/ausgaben.json` | all expenses as JSON | `application/json; charset=utf-8` | `zipfelkasse-ausgaben-<suffix>.json` |
| `GET /export/ynab.ofx` | **my** postings as OFX 1.02 SGML | `application/x-ofx` | `zipfelkasse-ynab-<suffix>.ofx` |
| `GET /export/ynab.csv` | my postings in YNAB CSV | `text/csv; charset=utf-8` | `zipfelkasse-ynab-<suffix>.csv` |

There is no ZIP export.

Download headers (`send`), on top of the security headers:

```
Content-Type: <type>
Content-Disposition: attachment; filename="<filename>"
Cache-Control: no-store
Content-Length: <bytes>
```

The body is fully buffered.

Query parameters are `von` and `bis`, both optional and inclusive. Each takes the first value; an empty string means unset.

- Both are parsed with `domain.ParseDate`, which accepts `YYYY-MM-DD`, `DD.MM.YYYY` and `D.M.YYYY` with years 2000–2100.
- `bis < von` gives the ValidationError `„Bis“ liegt vor „Von“.`
- Parse errors give the German ParseDate messages: `Ungültiges Datum „x“.`, `Das Datum „%s“ liegt nicht zwischen 2000 und 2100.` or `Bitte ein Datum angeben.`
- On any error, **every** route (including the page) re-renders `export.html` with status **422**, `Error: <msg>`, and **empty** von/bis fields. The fallback message is `Ungültiger Zeitraum.`
- A store failure gives `d.ServerError`: 500 and the error page `Da ist etwas schiefgegangen.`

Filename `suffix(today)`:

| von | bis | suffix |
|---|---|---|
| set | set | `<von>_<bis>` |
| set | unset | `ab-<von>` |
| unset | set | `bis-<bis>` |
| unset | unset | `<today>` |

Dates are `YYYY-MM-DD`. `today` is `Deps.Today()`, the date in the config location.

Data loading:

- `ListExpenses{From, To, ParticipantID}` returns non-deleted rows, including reimbursements.
- `ParticipantID` is 0 for `ausgaben.*` and `me.ID` for ynab.
- The list is **reversed**, so it ends up chronological: date asc, id asc.

### 5.2 `ausgaben.csv`: German Excel format

- It starts with a UTF-8 **BOM** `﻿`.
- Delimiter `;`. Line ending **CRLF**, including inside quoted fields (see quoting).
- Decimal comma, no thousands separator.
- Header:

  ```
  ID;Datum;Titel;Kategorie;Bezahlt von;Betrag (EUR);Originalbetrag;Währung;Kurs;Art;Aufteilung;Notiz
  ```

  followed by one column `Anteil <Name>` per involved person.
- Involved people are those who paid or have a share in the **exported** expenses, in ListParticipants order (`name COLLATE NOCASE, id`), archived people included. The header names are not passed through `cell()`.

Per row:

| column | value |
|---|---|
| ID | `strconv.FormatInt(id)` |
| Datum | `02.01.2006`, i.e. `DD.MM.YYYY` |
| Titel | `cell(title)` |
| Kategorie | `cell(category name or "")` |
| Bezahlt von | `cell(payer)` |
| Betrag (EUR) | `FormatDecimal(amount_cents, 2, ',')` |
| Originalbetrag | `FormatDecimal(original_amount_minor, CurrencyDecimals(cur), ',')`, e.g. `2000` for JPY |
| Währung | `original_currency` as stored (`EUR`) |
| Kurs | if foreign: `FormatRate`, i.e. `strconv.FormatFloat(rate,'f',-1)` with the first `.` replaced by `,` (`1,125`, `160,5`); otherwise `""` |
| Art | `Ausgabe` or `Rückzahlung` |
| Aufteilung | `Gleichmäßig`, `Nach Anteilen`, `Nach Prozent` or `Nach Beträgen` (or the raw mode string) |
| Notiz | `cell(notes)` |
| Anteil X | if X has a share row, even a 0 share: `FormatDecimal(share, 2, ',')`; otherwise `""` |

`cell(s)`:

- If `s` is non-empty and its **first byte** is one of `= + - @ \t \r`, a `'` is prepended. This prevents CSV injection.
- It is applied only to Titel, Kategorie, Bezahlt von, Notiz, and to YNAB Payee and Memo.

Go `encoding/csv` quoting (P9):

- A field is quoted if it contains the delimiter, `"`, `\r` or `\n`, if it equals `\.` exactly, or if its **first rune** is `unicode.IsSpace`. An empty field is never quoted.
- Inside quotes, `"` becomes `""`.
- With `UseCRLF`, each `\n` becomes `\r\n` and each `\r` is **dropped**. So `a\r\nb` becomes `a\r\nb`, and `a\nb` also becomes `a\r\nb`.
- Each record ends with `\r\n`.

Golden examples (from `TestExpensesCSVGolden` and the probe):

```
﻿ID;Datum;Titel;Kategorie;Bezahlt von;Betrag (EUR);Originalbetrag;Währung;Kurs;Art;Aufteilung;Notiz;Anteil Anna;Anteil Ben;Anteil Jürgen\r\n
1;01.09.2026;Café & Kuchen;Restaurant;Anna;12,01;12,01;EUR;;Ausgabe;Gleichmäßig;"lecker; „süß“";6,01;;6,00\r\n
2;03.09.2026;"Diner ""NYC""";;Ben;80,00;90,00;USD;1,125;Ausgabe;Gleichmäßig;;40,00;40,00;\r\n
3;05.09.2026;Rückzahlung;;Jürgen;6,00;6,00;EUR;;Rückzahlung;Gleichmäßig;;6,00;;\r\n
4;10.09.2026;'=SUMME(A1);Lebensmittel;Ben;5,00;5,00;EUR;;Ausgabe;Gleichmäßig;;;5,00;\r\n
5;05.09.2026;"'=Formel <&> ""q""";;Anna;10,00;10,00;EUR;;Ausgabe;Nach Anteilen;"Zeile1\r\nZeile2\r\nZeile3; x";6,67;3,33\r\n
6;06.09.2026;Sushi;;Anna;12,46;2000;JPY;160,5;Ausgabe;Gleichmäßig;;6,23;6,23\r\n
```

With no rows, only the BOM and the 12-column header plus CRLF are written; there are no `Anteil` columns.

### 5.3 `ausgaben.json`

- `json.NewEncoder(w)` with `SetIndent("", "  ")` and **HTML escaping on**.
- Ends with `\n`.
- Struct field order:

```
jsonExport { group, exported_at (time, RFC3339Nano UTC), from (omitempty, YYYY-MM-DD), to (omitempty),
             currency ("EUR"), participants [jsonParticipant], expenses [jsonExpense] }
jsonParticipant { id, name, archived (bool) }            -- ALL people (ListParticipants(true)), not only involved
jsonExpense { id, date, title, category_id (*int64; null if 0), category ("" if none), paid_by (id),
              paid_by_name, amount_cents, is_reimbursement, split_mode (raw mode string), original_amount_minor,
              original_currency, fx_rate (float64, EUR → 1), fx_source ("" for EUR), notes,
              recurring_id (*int64; null if 0), shares [jsonShare], created_at, updated_at (time, UTC) }
jsonShare { participant_id, name, weight, amount_cents }
```

- `group` is `Store.GroupName()`: the `group_name` setting, or the default `Zipfelkasse`.
- `exported_at` is `now.UTC()` with nanoseconds, e.g. `"2026-10-03T06:14:49.339316322Z"`.
- `created_at` and `updated_at` have second precision as stored (`"…Z"`).
- `participants` and `expenses` are `[]` when empty; so are `shares`.

The exact golden output is in `export_test.go` `TestExpensesJSONGolden` and in `probe_export.txt`.

### 5.4 `ynab.ofx`: OFX 1.02 SGML, UTF-8, CRLF everywhere

Postings come from `ynab.SelectionFor(ctx, store, me.ID, ynab.Today(now, loc))` and then `sel.Postings(es, me.ID)`:

- One posting per expense where my share is > 0. Deleted expenses and reimbursements are skipped.
- `date <= Today`, where `Today = min(local date, UTC date)`.
- The YNAB start, connectedAt and inYNAB rules apply if YNAB is configured.
- Postings are sorted by date, then ExpenseID.
- `Payee` is the title truncated to 200 runes, with `…` when cut.
- `Memo` is `Gesamt <FormatCents(amount)>[ (<FormatMoney(orig,cur)>)] · bezahlt von <payer>`, truncated so that it plus the suffix fits 500 runes, followed by ` · zipfelkasse #<id>`.
  - `FormatCents` uses a thousands dot, a decimal comma and `" €"` with a regular space.
  - The separators are U+00B7 with regular spaces.
  - Example: `Gesamt 80,00 € (90,00 USD) · bezahlt von Ben · zipfelkasse #2`. JPY: `(2.000 JPY)`.

`writeOFX(ps, acct="ZIPFELKASSE-<me.ID>", from, to, now)`:

- If `from` or `to` is zero: `lo` and `hi` are the first and last posting dates, or `now` (local time.Now) if there are no postings. A missing `from` takes `lo` and a missing `to` takes `hi`.
- `total = -sum(AmountCents)`.
- Each line is followed by `\r\n`.
- Output, verbatim:

```
OFXHEADER:100
DATA:OFXSGML
VERSION:102
SECURITY:NONE
ENCODING:UTF-8
CHARSET:NONE
COMPRESSION:NONE
OLDFILEUID:NONE
NEWFILEUID:NONE
<empty line>
<OFX>
<SIGNONMSGSRSV1>
<SONRS>
<STATUS>
<CODE>0
<SEVERITY>INFO
</STATUS>
<DTSERVER>{now.UTC() 20060102150405}
<LANGUAGE>GER
</SONRS>
</SIGNONMSGSRSV1>
<BANKMSGSRSV1>
<STMTTRNRS>
<TRNUID>1
<STATUS>
<CODE>0
<SEVERITY>INFO
</STATUS>
<STMTRS>
<CURDEF>EUR
<BANKACCTFROM>
<BANKID>ZIPFEL
<ACCTID>{sgml(acct, 22)}
<ACCTTYPE>CHECKING
</BANKACCTFROM>
<BANKTRANLIST>
<DTSTART>{from 20060102}
<DTEND>{to 20060102}
  per posting:
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>{date 20060102}
<TRNAMT>{FormatDecimal(-cents, 2, '.')}     e.g. -6.01, -0.05
<FITID>zipfelkasse-{ExpenseID}
<NAME>{sgml(payee, 32)}
<MEMO>{sgml(memo, 255)}
</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL>
<BALAMT>{FormatDecimal(total, 2, '.')}       e.g. -46.01, 0.00
<DTASOF>{to 20060102}
</LEDGERBAL>
</STMTRS>
</STMTTRNRS>
</BANKMSGSRSV1>
</OFX>
```

The file ends with `</OFX>\r\n`. There are no closing tags for leaf elements, and the file has no BOM.

`DTSTART`, `DTEND` and `DTASOF` are formatted in the **location of the time value**:

- Query dates are UTC midnight.
- Posting dates are UTC midnight.
- `now` is server-local. An empty export with no range gives `DTSTART` equal to the local date of now, while `DTSERVER` is in UTC; the probe shows `20261002` next to `20261002213000`.

`sgml(s, n)`:

1. `strings.Fields(s)` joined with `" "`. This collapses and trims all Unicode whitespace, including newlines.
2. If longer than `n` runes: cut to `n` runes and then `TrimSpace`.
3. Then replace `&` with `&amp;`, `<` with `&lt;` and `>` with `&gt;`. Escaping happens **after** truncation.

Example: `<NAME>Sehr langer Titel mit &lt;Sonderzei`.

### 5.5 `ynab.csv`: YNAB import format

- Go `csv.Writer` with defaults: delimiter `,`, `\n` line endings, **no BOM**.
- Header: `Date,Payee,Memo,Outflow,Inflow`.
- Rows: `YYYY-MM-DD`, `cell(payee)`, `cell(memo)`, `FormatDecimal(cents,2,'.')` (positive, e.g. `6.01`), and an empty Inflow.
- Example:

  ```
  2026-09-01,Café & Kuchen,"Gesamt 12,01 € · bezahlt von Anna · zipfelkasse #1",6.01,
  ```

  The memo is quoted because it contains a comma.
- With no postings, only `Date,Payee,Memo,Outflow,Inflow\n` is written.

### 5.6 Export page (`templates/export.html`)

A GET form with action `/export/ausgaben.csv` and two date inputs:

- `von` with `value="{{isoDate .From}}"`; isoDate of a zero time is empty.
- `bis`, the same.

Four buttons use `formaction`:

| formaction | label |
|---|---|
| `/export/ausgaben.csv` | `CSV (Excel, Numbers)` |
| `/export/ausgaben.json` | `JSON` |
| `/export/ynab.ofx` | `OFX` |
| `/export/ynab.csv` | `CSV (YNAB-Format)` |

The German copy is verbatim in the template (16 content lines; copy the file). The page is rendered within the shared
layout with `web.Page{Title:"Export", Nav: NavSettings, Error: msg}`.

---

## 6. Tests (case lists for the port's spec suite)

### `internal/mcp/access_test.go`

`TestClientIP`. Trusted is `10.0.0.0/8, 172.16.0.5`. Expected results:

| case | result |
|---|---|
| direct | 1.2.3.4 |
| direct IPv6 `[2001:db8::1]:5000` | 2001:db8::1 |
| direct without port | 1.2.3.4 |
| XFF spoof without proxy | ignored |
| X-Real-IP spoof without proxy | ignored |
| proxy + XFF | 160.79.104.1 |
| proxy + `160.79.104.1, 6.6.6.6` | 6.6.6.6 |
| chain `6.6.6.6, 160.79.104.1, 172.16.0.5` | 160.79.104.1 |
| multiple XFF headers `6.6.6.6` and `160.79.104.1` | 160.79.104.1 |
| XFF with port | the address |
| XFF `[2001:db8::7]:443` | 2001:db8::7 |
| XFF `garbage` | invalid |
| XFF partly garbage | invalid |
| XFF and X-Real-IP | XFF wins |
| only X-Real-IP | used |
| X-Real-IP garbage | invalid |
| proxy without headers | the proxy address |
| only trusted hops `10.0.0.3, 10.0.0.4` | 10.0.0.3 (leftmost) |
| IPv4-mapped proxy and XFF | unmapped |
| RemoteAddr `@` | invalid |

`TestDecodeHeaderValue`:

| input | result |
|---|---|
| `balances` | as is |
| `=?base64?SGVsbG8sIOS4lueVjA==?=` | `Hello, 世界` |
| a base64 of a literal `=?base64?literal?=` | that literal |
| no padding (`SGVsbG8`) | `Hello` |
| `!!!` | fails |
| `=?base64?=` | returned literally |

### `internal/mcp/mcp_test.go`

The environment: secret `s3cr3t-0123456789abcdef`, remote `160.79.104.10:40000`, `TRUSTED_PROXIES=10.0.0.1`,
people Anna, Ben and Cleo, and default categories.

- `TestAccess`: 16 cases.
  - 200: allowed; via proxy with XFF; via proxy with X-Real-IP.
  - 404: wrong secret; secret prefix; wrong secret from a foreign IP. The 404 body must not contain "mcp".
  - 403: foreign IP; XFF or X-Real-IP spoof without proxy; prepended forgery; proxy without header; `Origin` set; `Origin: null`.
  - 405: GET and DELETE, with `Allow: POST`.
  - 415: `text/plain`.
  - The log never contains the secret or its first 10 characters. It contains `method=ping`, `ip=160.79.104.10`, `wrong secret`, `IP not allowed` and `Origin header rejected`.
- `TestDisabledWithoutSecret`: POST `/mcp/` gives 404.
- `TestLegacyProtocol`:
  - `initialize` 2025-06-18 is echoed. There is no `Mcp-Session-Id`, and `Content-Type: application/json`.
  - Capabilities include tools; serverInfo name is `zipfelkasse`; the instructions contain "Balance"; there is no `resultType`.
  - Version 2024-11-05 negotiates to 2025-11-25.
  - `notifications/initialized` gives 202 with an empty body.
  - `tools/list` has the 9 tools in order, with correct annotations, a non-empty description and inputSchema type object. It works without the header too.
  - Header `1999-01-01` gives 400 -32022.
  - `ping` gives `{}`. `resources/list` gives -32601. An unknown tool gives -32602.
- `TestTodayInInstructionsAndSchema`:
  - FixedZone `Test/Zone` at +2. At 21:30 UTC, the text says `Today is 2026-10-02 (Friday), server time zone Test/Zone.` and `ttlMs` is 1800000.
  - One hour later, schema says `2026-10-03 (Saturday)` and `ttlMs` is 3600000.
- `TestModernProtocol`:
  - discover returns `resultType complete`, `cacheScope public`, `ttlMs>0`, supportedVersions[0] = modern with 4 entries, and `_meta` serverInfo.
  - `tools/list` returns 9 tools and ttlMs.
  - `tools/call balances` has text starting `{"balances":` and no structuredContent.
  - A Base64 Mcp-Name works.
  - 11 bad cases, all with `id:"a-1"` echoed:
    - 400/-32020: version header missing or wrong, Mcp-Method missing or wrong, Mcp-Name missing, wrong, Base64-wrong or Base64-broken.
    - 404/-32601: unknown method; `initialize` in modern.
    - 200/-32602: unknown tool.
  - Modern 2099 gives 400 -32022 with `data.requested` and `data.supported`.
  - A modern header without `_meta` gives 400 -32020.
  - A modern notification gives 202.
- `TestMalformed`: `{broken` gives 400/-32700. A batch gives 400/-32600. No jsonrpc gives 400/-32600. No method gives 400/-32600. `params:[1]` gives 400/-32602. A `_meta` version of 7 gives 400/-32602. A client response gives 202. A body over 1 MiB gives 413.
- `TestSearchExpensesUmlauts`: `BÄCKEREI`, `bäcker`, `ölwechsel` and `Ölwechsel` match case-insensitively, including umlauts.
- `TestCategoryNone`: `none`, `No category` and `NONE` select expenses without a category. statistics labels the row `No category`. `category` combines with group_by=person. An unknown category is an error that names the category.
- `TestCategoryNamedNone`: a real category named "None" wins over the special value.
- `TestMoney`: `eur(-300000)="-3000.00"`, `money(2340,"usd")="23.40 USD"`, `money(1500,"JPY")="1500 JPY"`.
- `TestTools`:
  - balances values and status, and the text contains `"balance":"-30.00"`, `"from":"Ben"` and `"settlements":[`.
  - search person/full: foreign original, fx_rate 1.17, shares.
  - reimbursements `only` and `include`.
  - category with limit 1 gives `truncated`.
  - `&` is not escaped.
  - 17 invalid-argument cases each give isError without "Internal error". The person error lists `Anna, Ben, Cleo`; the range error text is checked.
  - statistics with share_of, person (paid), month with a DD.MM.YYYY `to`, and category_month.
  - 7 invalid statistics cases.
  - schema text checks.
  - sql_query: columns and rows, truncation at 500 with the note, and 5 rejected queries. The database is unchanged afterwards, and `tool=sql_query` is logged.
- `TestSearchExpensesOptions`:
  - The orderings for each sort.
  - min/max amounts (`19.99`–`24`).
  - A text list, paid_by, involved, person, and paid_by+involved.
  - `person_share` for involved.
  - compact vs full keys.
- `TestStatisticsOptions` (today 2026-04-15):
  - Month gap filling up to today, also with no matches and with `to` in the future.
  - Years; weeks W12 and W13; titles case-insensitive.
  - A text list.
  - `limit` with `rows_total=14` and total over all rows.
  - compare by month: `change_percent=16.7`, nil for 0.
  - compare by category, with a previous-only group given amount 0. `previous_period` is `2025-01-01 to 2025-12-31`.
- `TestBalanceHistory`: monthly snapshots; year interval with person and opening balance; weeks `2026-W10`; without `to`, later expenses are included; `to` cuts. Invalid cases: interval `day`, unknown person, too many weeks, year 1900.
- `TestActivity`: 7 entries newest first (system category text `Kategorie „Kino“ hinzugefügt`); update by Cleo with changes; filters person, action and expense_id; limit/more/note; before_id; today/yesterday date filters; 4 invalid cases.
- `TestDataOverviewInInstructions`: the empty text, then `4 expenses and 1 reimbursements dated 2025-03-10 to 2026-09-30.`, `2 of the expenses (50.0%) have no category.` and `Values of activity.action: expense_created, settings_updated.` initialize carries it too.
- `TestStatisticsCompareEdgeCases`:
  - category_month previous-only "No category" appended with 0, and `previous_total_cents=57000`.
  - Leap day: the previous range ends 2023-02-28.
  - Title fold ß=ss.
  - Week 51.
  - 2021-W52 vs 2020-W53 (800).
  - A future `from` gives "future".
- `TestCreateExpense` (fakeFX USD 1.25 "ezb"; Cleo archived):
  - Defaults: equal split among active people, today, category case-insensitive.
  - The activity actor is the payer.
  - A number amount 12.5, participants, notes and date.
  - Weights for shares, percent and amount.
  - USD with the ECB rate; JPY with manual fx_rate 160 gives 1250 cents and source `manuell`.
  - Duplicate refusal, allow_duplicate, and a different date.
  - 27 invalid cases.
  - CHF mentions fx_rate. Fractional shares say "whole number". A percent sum of 90 gives the German store error prefix.
  - The expense count stays 9.
- `TestCreateReimbursement`: the fields are created and balances become settled; duplicate refusal; another recipient is fine; 4 invalid cases, including an unknown `title` field.
- `TestParseDecimal`: the accepted and rejected tables in 2.9.

### `internal/store/mcp_test.go`

- `TestCheckSelect`. Accepted, with the returned value:

  | input | returned |
  |---|---|
  | `SELECT 1` | `SELECT 1` |
  | `  select 1 ;  ` | `  select 1 ` |
  | `-- comment\nWITH x AS (SELECT 1) SELECT * FROM x;; -- end` | cut at the first `;` |
  | `/* a; b */ SELECT ';' AS x` | unchanged |
  | `SELECT "a;b", [c;d], `` `e;f` `` | unchanged |
  | `SELECT 'it''s; fine'` | unchanged |

  Rejected: `""`, whitespace, comment-only, DELETE, PRAGMA, ATTACH, VACUUM INTO, `SELECT 1; DELETE`, `SELECT 1; ATTACH…`, `SELECT 'a'; PRAGMA…`, `SELECT 1 /* ; */; SELECT 2`, NUL, `(SELECT 1)`, `EXPLAIN SELECT 1`.
- `TestReadOnlyQuery`:
  - Columns are aliases. Rows hold int64, text, the real 1 as int, null and `[BLOB, 2 Bytes]`.
  - An empty result has 4 columns and 0 rows.
  - A recursive 1000-row query is truncated to 500, keeping the ORDER BY DESC order.
  - A 5000-character text is cut to 2000.
  - An unknown table gives a ValidationError containing the table name.
- `TestReadOnlyQueryHasFold`: `zipfelkasse_fold('BÄCKER Straße')` gives `bäcker strasse`; NULL gives nil; 42 gives 42.
- `TestReadOnlyQueryHidesYNAB`: the YNAB tables are unreachable through any qualifier or case. settings, sqlite_schema, pragma_database_list and pragma_table_list reveal nothing. The settings keys are `[default_currency] [group_name]`. MCPSchema has 8 tables and nothing YNAB.
- `TestSandboxLayers`:
  - On the raw sandbox connection, INSERT, UPDATE, DELETE, CREATE, CREATE TEMP, ATTACH (plain and `mode=ro`) and VACUUM INTO all fail.
  - After `PRAGMA query_only=OFF`, ATTACH still fails while DELETE works on the copy only.
  - runWrapped rejects DELETE, PRAGMA and an injection attempt.
  - The DB file is byte-identical afterwards.
- `TestReadOnlyQueryTimeout`: an infinite recursive CTE with a 300 ms ctx gives an "aborted" ValidationError in under 3 s.
- `TestReadOnlyQueryMemory`: a `:memory:` store gives a ValidationError.
- `TestStats`: 15 filter and grouping combinations with exact row strings, for example `Lebensmittel|||2|4000|0;Restaurant|||1|4000|0;No category|||1|500|0;` and person rows `Ben|3|3500|1000;Cleo|2|3000|4000;Anna|3|2000|3500;`. An unknown grouping gives a ValidationError.
- `TestStatsByTitleIgnoresCase`: Rewe and REWE are grouped together.
- `TestFillPeriods`: months, weeks across the year boundary, years, and non-time groupings left unchanged.
- `TestPeriods`:
  - PeriodStart/PeriodOf round trips, including `2026-W01` starting on 2025-12-29 and `2020-W53`.
  - ShiftDateYear: leap day.
  - ShiftPeriodYear:

    | input | output |
    |---|---|
    | `2025-09` | `2026-09` |
    | `2025-W40` | `2026-W40` |
    | `2025` | `2026` |
    | `""` | `""` |
    | `2020-W53` | `2021-W52` |
    | `2025-W53` | `2026-W53` |

### `internal/export/export_test.go`

- `TestExpensesCSVGolden`: the full CSV golden in 5.2.
- `TestExpensesJSONGolden`: the full indented JSON golden, with `from` only, a null category_id, recurring_id 7 and fx 1.125.
- `TestYNABPostingsMatchSync`: Anna's postings are only expenses 1 and 2.
- `TestOFXGolden`: the full OFX golden. DTSTART and DTEND are derived from the postings, BALAMT is -46.01, and `&amp;` appears in NAME.
- `TestOFXLimitsAndPeriod`: NAME is cut to 32 characters before escaping, the MEMO newline collapses, TRNAMT is `-0.05`, and the explicit period is used.
- `TestYNABCSVGolden`: the full YNAB CSV golden.
- `TestExportPage`: the page loads with `value="2026-09-01"`. `von=garbage` gives 422. A reversed range gives 422 containing `„Bis“ liegt vor „Von“`.
- `TestExpensesDownload`: CSV headers and filename `…2026-09-01_2026-09-30.csv`; the BOM; the date filter; deleted rows excluded; chronological order. The JSON includes everything, `from` is empty, and there are 2 participants.
- `TestYNABDownloads`: OFX type and filename `…ab-2026-09-01.ofx`, a single STMTTRN, `-5.00`, and `ACCTID ZIPFELKASSE-<id>`. The CSV golden.
- `TestYNABDownloadsFollowSync`: future expenses are excluded; the YNAB start, entered-later and already-synced rules apply.
- `TestYNABCSVInjection`: `"'=HYPERLINK(""x"")"` and `'+1 · …`.

---

## 7. Porting pitfalls (Crystal/Kemal specific)

- **P1. Key order.** Go map output is alphabetical, while Go struct output follows declaration order. Mixing them up changes the bytes. Crystal `Hash#to_json` keeps insertion order, so either insert in sorted order or sort before emitting.
- **P2. Floats.** Implement Go's float formatting (§3.8): `1` not `1.0`, `1e+30` not `1.0e+30`, `1e-7` not `1.0e-07`, and shortest round-trip digits. This affects `fx_rate`, `change_percent`, sql_query reals and the export `fx_rate`. In sql_query, numbers SQLite printed but Go could not parse (`9.0e+999`) are emitted verbatim.
- **P3. Escaping.** MCP output must not HTML-escape, but must escape U+2028 and U+2029. The export JSON **must** HTML-escape `<>&` as `<`, `>` and `&`. Control characters use lowercase `\u00xx`, plus `\b` and `\f` short forms. Invalid UTF-8 becomes `�`. Crystal's JSON escapes differently (for example it may use `\u001F` casing) and never HTML-escapes.
- **P4. Trailing newlines.** MCP HTTP bodies end with `\n`, inner tool text does not, and export JSON ends with `\n`.
- **P5. `id` handling.** Echo the raw JSON id verbatim. An absent id means a notification; `null` is a request and gets `"id":null`. Parse into a raw value, not a typed one.
- **P6. Case-insensitive field matching.** Go decodes `{"Method":…}`, `{"LIMIT":…}` and `{"Name":…}` into the lower-case fields, and the last duplicate key wins. With DisallowUnknownFields, a differently cased known key is *not* unknown. `JSON::Serializable` is case-sensitive, so a custom decoder is needed for parity.
- **P7. Go error texts are exposed to clients.** `Invalid arguments: json: …`, `Invalid params: json: …` and `Invalid JSON: …` carry Go-specific messages. Exact parity needs a hand-written mapping:
  - `json: unknown field "x"`
  - `json: cannot unmarshal <jsontype> into Go struct field .<name> of type <gotype>`, where the Go types are `int`, `int64`, `float64`, `bool`, `string`, `[]string`, `map[string]mcp.amountText` and so on, and an embedded field gets the prefix `.moneyArgs.`
  - `cannot unmarshal number <literal> into …` for a non-integer value in an int field
  - `cannot unmarshal array into Go value of type struct {}` or `mcp.params`
  - the syntax errors `invalid character 'b' looking for beginning of object key string`, `unexpected end of JSON input` and `invalid character 'x' after top-level value`

  If exact parity is not required, document the deviation; the tests only check isError, the absence of "Internal error", and some substrings.
- **P8. Error message quoting with `%q`.** Go `strconv.Quote` keeps printable Unicode and escapes `"`, `\`, control characters (`\n`, `\t`, `\x00`) and non-printables (`­`). Crystal's `String#inspect` differs (`\#{`, `\u{…}`), so implement a Go-compatible quote.
- **P9. CSV.** Crystal's `CSV::Builder` quoting rules differ. Go quotes on the separator, `"`, CR, LF, a leading Unicode space, or a field equal to `\.`. Go never quotes an empty field. With CRLF mode, Go **drops `\r`** and turns `\n` into `\r\n` inside quoted fields. The BOM appears in ausgaben.csv only. YNAB CSV uses LF.
- **P10. `cell()`** checks the **first byte** (`=+-@\t\r`), not the first character, and is applied only to the columns listed.
- **P11. `status`.** balance_history balances carry `"status":""`, an artifact of the shared struct. Keep it.
- **P12. `omitempty` with pointers.** A `paid_cents`, `previous_cents`, `change_cents` or activity `amount_cents` of 0 is emitted when set, and `change_percent` is omitted when previous is 0. `fx_rate` 0 and `reimbursement` false are omitted.
- **P13. Strict integer arguments.** Integers must be JSON integers. `5.0`, `1e2` and `0.5` are errors, and so are values that overflow `int`/`int64`.
- **P14. Rounding.** Go `math.Round` rounds half away from zero (`amountArg`, `change_percent`, `ToEURCents`). Crystal `Float#round` defaults to ties-even, so use `round(:ties_away)` / `RoundingMode::TIES_AWAY`. Go `%.1f` in the overview is correctly rounded on the binary value, the same as C `printf`.
- **P15. Case folding.**
  - `strings.EqualFold` is Unicode *simple* folding, so `ß` ≠ `ss`. Crystal `compare(case_insensitive: true)` and `downcase(:fold)` use full folding, under which `ß` = `ss`. Use `downcase` with default options and a char-by-char simple fold to match.
  - `store.Fold` is `strings.ToLower` followed by `ß` → `ss`. Go's ToLower is per-rune simple mapping (`İ` → `i`), while Crystal's `downcase` applies special casing (`İ` → `i̇`). This is an edge case.
- **P16. SQLite version.**
  - `strftime('%G-W%V')` (ISO week) requires **SQLite ≥ 3.46**; older versions return NULL and the week stats break.
  - `json_group_array` and `json_array` require JSON1, which is built in from 3.38. `sqlite_schema` requires ≥ 3.33, and `pragma_table_list` ≥ 3.37.
  - The modernc build ships a recent SQLite. Check the system `libsqlite3` used by crystal-sqlite3.
- **P17. The `zipfelkasse_fold` SQL function** must be registered on **every** connection, including the sandbox's in-memory connection. Stats, search and sql_query use it. crystal-sqlite3 has no create_function API, so `sqlite3_create_function_v2` must be bound through FFI.
- **P18. Sandbox primitives.** Bind `sqlite3_limit` (`SQLITE_LIMIT_ATTACHED=7`, `SQLITE_LIMIT_LENGTH=0`) and `sqlite3_interrupt` yourself.
  - The ATTACH of `file:///…?mode=ro` needs URI filenames enabled: open the sandbox connection with `SQLITE_OPEN_URI` or rely on the global `SQLITE_USE_URI`. **Otherwise SQLite silently creates a file literally named `file:///…?mode=ro`** and the copy ends up empty.
  - Percent-encode the path the way Go's `url.URL.String()` does.
  - Column names must come from preparing the body alone.
- **P19. Timeouts in Crystal.** A blocking `sqlite3_step` in a single-threaded Crystal runtime blocks all fibers, so a timer fiber cannot call `sqlite3_interrupt`. Use `sqlite3_progress_handler` that checks a deadline (returning non-zero interrupts the query), or run the query on another thread (`-Dpreview_mt` / ExecutionContext). The deadline covers both the copy and the query: 5 s. The tool timeout is 20 s. Keep the semaphore of 2.
- **P20. Time zone name.** `loc.String()` for the `TZ` location is `Europe/Berlin`, but when `TZ` is unset Go prints `Local`. Crystal's `Time::Location.local.name` is `"Local"` too, but it is loaded from `/etc/localtime` and `TZ`. When `TZ` is set, use exactly the `TZ` string. Weekday names are English.
- **P21. RFC3339 offsets.** Go prints `Z` for any zero offset. Crystal prints `Z` only for the UTC location, so a zero-offset zone such as Europe/London in winter gives `+00:00`. Export `exported_at` uses RFC3339**Nano** with trailing zeros trimmed. Crystal `to_rfc3339(fraction_digits: 9)` pads, so trim manually.
- **P22. Status codes and plain-text bodies.** Go's helpers produce `404 page not found\n` and `Method Not Allowed\n`, both `text/plain; charset=utf-8` with `X-Content-Type-Options: nosniff`, and the 405 has `Allow: POST`. Kemal's defaults differ: they produce HTML 404 pages, and Kemal may handle `HEAD` automatically. All `/mcp/*` routes, including non-matching ones, must produce the Go 404 text, never the web app's 404 or identity redirect.
- **P23. Check order.** The order is secret, IP, Origin, method, Content-Type, size, batch, parse. A GET with a wrong secret must give 404, not 405. Kemal's method-specific routes would otherwise intercept.
- **P24. Kemal body parsing.** Read the raw body (≤ 1 MiB, then 413) without Kemal's JSON param parsing. A Content-Type with parameters is fine. Return 413 when the body exceeds 1 MiB; Go also returns 413 when the read fails.
- **P25. Responses to notifications and client replies** are 202 with no body and no Content-Type. Go adds `Content-Length: 0`.
- **P26. Modern results** get `resultType` and `_meta`, merged into the result map. These also apply to `isError` results, but not to legacy-version-in-`_meta` requests. `initialize` in modern gives 404.
- **P27. Duplicate detection** compares `Fold(title)` for expenses and the recipient share for reimbursements, at the same euro-cent amount, payer and date, and only for the same kind.
- **P28. Weights iteration order** is sorted by key (byte order), which fixes which error appears first. Crystal `Hash` keeps insertion order, so sort the keys.
- **P29. Unknown-person lists.** findPerson lists **all** people, including archived ones. activePerson lists only active people and has a separate archived message.
- **P30. Export dates.** OFX `DTSTART`/`DTEND` without a range come from postings or from local `now`. `DTSERVER` is UTC. `ynab.Today` is `min(local date, UTC date)`.
- **P31. Export JSON participants** are **all** people. Export CSV share columns are only the **involved** people.
- **P32. Schema text** includes the CREATE SQL text exactly as stored in `sqlite_schema` by the migrations. Port the migration SQL byte-identically, including comments and spacing, or the `schema` output differs.
- **P33. Go time parsing** in `ParseDate`:
  - `2006-01-02` requires 2-digit months and days; `2026-9-1` is rejected.
  - `02.01.2006` also requires 2 digits, while `2.1.2006` accepts 1 or 2.
  - The calendar is validated: Feb 30 is rejected.
  - Leading and trailing spaces are trimmed first.
  - Crystal's `Time.parse` is more lenient with `%m`/`%d`, so validate explicitly.
- **P34. Logs.** The Go slog text format is `time=… level=INFO msg=… k=v`; quote only when needed. The log fields are listed in §1.2. Never log the path.
- **P35. Period strings** compare lexicographically (`PeriodOf(date) <= p`), which works because all formats are zero-padded. Use ISO week-year (`%G`), not the calendar year, for weeks: `Time#calendar_week` returns `{year, week}`.
