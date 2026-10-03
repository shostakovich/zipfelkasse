# Porting inventory: background jobs, FX, recurring expenses, YNAB

Source: Go app `/home/user/zipfelkasse` (go 1.26.5). Covered packages:

| Area | Go files (non-test) | Templates / testdata |
|---|---|---|
| FX | `internal/fx/fx.go`, `ecb.go`, `calendar.go`, `handlers.go` | `templates/kurse.html`, `testdata/eurofxref-daily.xml`, `eurofxref-hist-90d.xml`, `eurofxref-hist.csv` |
| Recurring | `internal/recurring/recurring.go`, `handlers.go` | `templates/wiederkehrend.html`, `templates/wiederkehrend_neu.html` |
| YNAB | `internal/ynab/ynab.go`, `client.go`, `sync.go`, `posting.go`, `handlers.go` | `templates/ynab.html` (test fake: `fake_test.go`) |
| Store | `internal/store/fx.go`, `recurring.go`, `ynab.go`, `ynabstate.go` (migration 5), migrations `001_init.sql`, `003_fx_rates_source_key.sql` | – |
| Shared helpers used | `internal/domain/date.go` (Frequency, Occurrence, NextDate, ParseDate, DateOf), `domain/money.go` (ParseRate, FormatRate, ToEURCents, FormatCents, FormatMoney, CurrencyDecimals, ValidCurrencyCode, IsEUR), `domain/fx.go` | – |

Everything below says "Go does X". Where a Crystal choice matters, it is marked **PORT**.

---

## 0. Conventions shared by all three packages

- **Calendar dates** are `time.Time` at 00:00 **UTC**. `domain.DateOf(t)` takes y/m/d of `t` in *t's own zone* and returns `time.Date(y,m,d,0,0,0,0,UTC)`. Stored as TEXT `YYYY-MM-DD` (`domain.DateLayout = "2006-01-02"`).
- **Timestamps** are TEXT RFC 3339 UTC (`store.timeLayout = time.RFC3339`, written as `s.now().UTC().Format(RFC3339)` with **no** fractional seconds). Exception: YNAB status columns use `RFC3339Nano` (fractional seconds kept so `RetryAt` round-trips exactly). Reading uses `time.Parse(time.RFC3339, v)`, which **accepts** fractional seconds and offsets; a parse error yields the zero time (silently).
- **App time zone** is `Config.Location`. It comes from env `TZ` (`time.LoadLocation`); without `TZ` it is `time.Local` (UTC in the scratch container). compose.yaml sets `TZ: Europe/Berlin`. `today` in each service = `DateOf(now().In(Config.Location))`.
- **German display date**: `domain.FormatDate(t)` = `"02.01.2006"`; zero time gives `""`.
- **`domain.ParseDate(s)`** (used by all form/query dates): trims; `""` gives `ValidationError "Bitte ein Datum angeben."`; tries layouts `2006-01-02`, `02.01.2006`, `2.1.2006` in that order; year outside 2000..2100 gives `"Das Datum „%s“ liegt nicht zwischen 2000 und 2100."`; otherwise `"Ungültiges Datum „%s“."`.
- **Flash**: `web.SetFlash(w,msg)` sets cookie `flash` = base64 **RawURL** (no padding) of the UTF-8 text, `Path=/; HttpOnly; SameSite=Lax; Max-Age=60`. The next rendered page reads it and deletes it (`Max-Age=-1`). All successful POSTs below do `SetFlash` + `303 See Other` with a `Location` header.
- **Error page**: `d.Render.Error(w,r,status,msg)` renders `error.html` with `Page{Title: msg}`. `d.ServerError` logs `"request" method path err` and renders 500 `"Da ist etwas schiefgegangen."`.
- **Page errors**: `web.Page{Title, Nav, Error, Data}`; the layout shows `.Error` as a destructive alert (tests check that the body contains `alert-destructive` on 422).
- All routes are mounted on the browser mux behind `web.Wrap` (security headers, 1 MiB body limit, cross-origin/CSRF check, identity cookie). Handlers read the current person with `me, _ := web.Me(ctx)`; a missing person gives ID 0, which becomes actor `NULL`.
- **Activity log** (`activity` table): `logSettings(actor, text)` = action `settings_updated`, `expense_id NULL`, `details_json {"text": …}`. Actor 0 is stored as NULL (system).

---

## 1. Background jobs

### 1.1 Startup and shutdown (main.go)

```go
ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
var wg sync.WaitGroup
wg.Go(func() { a.fx.Run(ctx) })
wg.Go(func() { a.recurring.Run(ctx) })
wg.Go(func() { a.ynab.Run(ctx) })
wg.Go(func() { backupLoop(ctx, st, cfg, log) })   // not in scope: nightly 03:00 local backup
...
// on ctx.Done: srv.Shutdown(10s timeout); stop(); wg.Wait(); then deferred st.Close()
```

- Wiring order in `newApp`: `fx.New(d)`, then `d.FX = fxSvc` (so recurring/ynab/web/mcp see it), then `recurring.New(d)`, then `ynab.New(d)`. **`ynab.New` registers a store hook** `d.Store.OnExpenseChange(func(c){ s.Trigger(c.ExpenseID) })`. The hook runs synchronously after every committed expense create/update/delete, *including* expenses created by recurring materialization and by MCP.
- Shutdown order: the HTTP server shuts down first (10 s), then all `Run` loops return (each waits for its own background work), and only then is the store closed. **PORT**: keep "jobs finish before DB close".
- Logging: `log/slog` TextHandler on stderr (`level=INFO msg=... key=value`).

### 1.2 FX job `fx.Service.Run(ctx)` (ECB rates)

```go
func (s *Service) Run(ctx context.Context) {
    defer s.stop()                       // cancel bgCtx, wait for running downloads
    if stats, err := s.d.Store.ECBCacheStats(ctx); err == nil && stats.To.Before(s.expectedDate(s.today())) {
        s.refreshLogged(ctx)             // run-at-startup only if the cache is behind
    }
    retries := 0
    for {
        wait := time.Until(nextPublish(s.now().In(s.berlin)))
        if retries > 0 { wait = time.Hour }
        timer := time.NewTimer(wait)
        select { case <-ctx.Done(): timer.Stop(); return; case <-timer.C: }
        latest := s.refreshLogged(ctx)
        // Not yet published or failed: retry hourly, up to three times.
        if latest.Before(s.expectedDate(s.today())) && retries < 3 { retries++ } else { retries = 0 }
    }
}
func (s *Service) refreshLogged(ctx) time.Time {
    latest, err := s.Refresh(ctx)
    if err != nil && ctx.Err() == nil { s.d.Log.Error("refresh ECB rates", "err", err) }
    return latest                         // zero time on error
}
```

- **Schedule**: every TARGET business day at **16:30 Europe/Berlin** (`publishHour=16, publishMinute=30`). The Berlin location is loaded independently of `Config.Location` (`time.LoadLocation("Europe/Berlin")`, falling back to `time.FixedZone("CET", 3600)`).
- **Retry**: if after a run the newest rate is older than expected (not published yet, or an error), it waits 1 h instead and tries again, at most 3 times. Then it returns to the 16:30 schedule. No jitter.
- **Run at startup**: only if `ECBCacheStats.To < expectedDate(today)`. An empty cache has a zero `To`, so it always refreshes (the 90-day file, see `Refresh`). If `ECBCacheStats` errors, the startup refresh is skipped silently.
- **Clock**: `s.now func() time.Time` (default `time.Now`) is used for `today`, `expectedDate`, `nextPublish` and the cooldowns. `time.Until` / timers use the **real** clock, so a fake `now` mixed with real timers gives odd waits. **PORT/E2E**: an injectable clock needs to cover both, or the E2E suite should never rely on the 16:30 tick.
- Shutdown: `stop()` takes `mu`, cancels `bgCtx`, then waits on the `bg` WaitGroup. After that, `fetch` refuses new downloads (`FetchError{Err: context.Canceled}`).

Calendar (`calendar.go`):

```go
func isBusinessDay(d time.Time) bool {           // d = date at 00:00 UTC
    switch d.Weekday() { case Saturday, Sunday: return false }
    y, m, day := d.Date()
    if (m==Jan&&day==1) || (m==May&&day==1) || (m==Dec&&(day==25||day==26)) { return false }
    easter := easterSunday(y)
    if d.Equal(easter.AddDate(0,0,-2)) || d.Equal(easter.AddDate(0,0,1)) { return false } // Good Friday, Easter Monday
    return true
}
func lastBusinessDay(d) { for !isBusinessDay(d) { d = d.AddDate(0,0,-1) }; return d }
func easterSunday(y int) time.Time {               // Meeus/Jones/Butcher, integer division
    a := y % 19; b, c := y/100, y%100; d, e := b/4, b%4; f := (b+8)/25; g := (b-f+1)/3
    h := (19*a + b - d - g + 15) % 30; i, k := c/4, c%4; l := (32 + 2*e + 2*i - h - k) % 7
    m := (a + 11*h + 22*l) / 451
    month := (h + l - 7*m + 114) / 31; day := (h+l-7*m+114)%31 + 1
    return time.Date(y, time.Month(month), day, 0,0,0,0, time.UTC)
}
func nextPublish(now time.Time) time.Time {        // now in Europe/Berlin
    t := time.Date(now.Year(), now.Month(), now.Day(), 16, 30, 0, 0, now.Location())
    for !t.After(now) || !isBusinessDay(time.Date(t.Year(), t.Month(), t.Day(), 0,0,0,0, time.UTC)) {
        t = time.Date(t.Year(), t.Month(), t.Day()+1, 16, 30, 0, 0, now.Location())   // day overflow is normalised!
    }
    return t
}
```

Test expectations (`TestCalendar`): Easter 2024-03-31, 2025-04-20, 2026-04-05, 2027-03-28. Business days: 2026-10-02 true; 10-03 and 10-04 false (weekend); 2026-04-03 (Good Friday) false; 04-06 (Easter Monday) false; 05-01 false; 12-24 **true**; 12-25 false; 2027-01-01 false; 2026-10-05 true. `lastBusinessDay(2026-04-06) = 2026-04-02`. `nextPublish`: "2026-10-02 12:00" gives "2026-10-02 16:30"; "16:30" exactly gives "2026-10-05 16:30" (strictly after); "17:00" gives 10-05 16:30; "2026-12-24 17:00" gives "2026-12-28 16:30"; "2026-03-28 10:00" gives "2026-03-30 16:30" (DST change on 29 March).

`expectedDate(date)` is the latest day ≤ `date` for which the ECB should already have published:

```go
func (s *Service) expectedDate(date time.Time) time.Time {
    now := s.now().In(s.berlin)
    if todayBerlin := domain.DateOf(now); !date.Before(todayBerlin) {
        date = todayBerlin
        if now.Hour()*60+now.Minute() < 16*60+30 { date = date.AddDate(0,0,-1) }
    }
    return lastBusinessDay(date)
}
```

### 1.3 Recurring job `recurring.Service.Run(ctx)`

```go
func (s *Service) Run(ctx context.Context) {
    tick := time.NewTicker(time.Hour)
    defer tick.Stop()
    for {
        if n, err := s.Materialize(ctx, s.today()); err != nil {
            if ctx.Err() == nil { s.d.Log.Error("recurring expenses", "err", err) }
        } else if n > 0 {
            s.d.Log.Info("recurring expenses created", "count", n)
        }
        select { case <-ctx.Done(): return; case <-tick.C: }
    }
}
```

- Runs **immediately at startup**, then **every hour** (ticker from process start, no jitter, not aligned to the clock).
- `today` = `DateOf(s.now().In(Config.Location))` (default `time.Local` if nil). The clock `s.now` is overridable in tests; `Materialize(ctx, today)` also takes `today` as a parameter.
- Concurrency: `s.mu` serialises `Materialize` and `MaterializeRule` (the HTTP handlers call `MaterializeRule`).
- Shutdown: `Materialize` stops after the current rule if `ctx.Err() != nil`. Store calls with a cancelled context fail; their errors are logged only if ctx is still alive.

### 1.4 YNAB job `ynab.Service.Run(ctx)`

Constants: `defaultDebounce = 5s`, `defaultStartDelay = 15s`, `fullInterval = 1h`, `cacheTTL = 10m`, `httpTimeout = 30s`, `retryDelay = 5m`, `maxBackoff = 1h`.

```go
func (s *Service) Run(ctx context.Context) {
    timer := time.NewTimer(s.startDelay)            // first full sync 15 s after start
    defer timer.Stop()
    deadline := time.Now().Add(s.startDelay)
    var lastFull time.Time
    defer s.stopBackground()                         // cancel + wait for "Jetzt synchronisieren" goroutines
    for {
        select {
        case <-ctx.Done(): return
        case <-s.wake:                               // Trigger(): buffered chan, cap 1
            if time.Until(deadline) > s.debounce {    // only ever shortens the wait to 5 s
                deadline = time.Now().Add(s.debounce); timer.Reset(s.debounce)
            }
        case <-timer.C:
            full := lastFull.IsZero() || time.Since(lastFull) >= fullInterval-time.Minute  // ≥ 59 min
            if full { lastFull = time.Now() }
            next := s.SyncAll(ctx, full)
            deadline = time.Now().Add(next); timer.Reset(next)
        }
    }
}
func (s *Service) Trigger(expenseID int64) {        // never blocks
    select { case s.wake <- struct{}{}: default: }
}
```

- Trigger sources: the store hook (every expense create/update/delete), and the handlers after saving token, target or categories (`s.Trigger(0)`).
- `SyncAll(ctx, full)` returns the delay until the next run:

```go
func (s *Service) SyncAll(ctx context.Context, full bool) time.Duration {
    next := fullInterval
    cfgs, err := s.d.Store.ListYNABConfigs(ctx)       // token != '' AND enabled = 1 AND person not archived, ORDER BY participant_id
    if err != nil { s.d.Log.Error("ynab: read configs", "err", err); return retryDelay }
    for _, c := range cfgs {
        if ctx.Err() != nil { return next }
        if !c.Ready() { continue }
        cfg, res, st, err := s.syncPerson(ctx, c.ParticipantID, full)  // takes syncMu, re-reads config
        if err == errNotReady { continue }
        if err != nil || res.Created+res.Updated+res.Deleted+res.Failed > 0 { s.logSync("", cfg, res, err) }
        if res.Again { next = min(next, s.debounce) }                              // 5 s
        if wait := st.RetryAt.Sub(s.now()); wait > 0 { next = min(next, wait+time.Second) }
    }
    return next
}
```

- Logging (`logSync(how, cfg, res, err)`, `how` = `""` or `" (now)"`):
  - success: `Info "ynab: synced"+how person=<id> result="%d created, %d updated, %d deleted, %d failed"`
  - `backoffError` (paused) or `errTokenInvalid` (token already marked invalid): **not logged**
  - otherwise: `Warn "ynab: sync"+how+" failed" person=<id> err=<redacted>` (the token is replaced by `•••`)
- Clock: `s.now` is used for status times, RetryAt, Today and cache TTL. Scheduling uses the real `time.Now` / timers. Tests override the fields `http`, `baseURL`, `now`, `debounce`, `startDelay`.
- Concurrency:
  - `syncMu` makes syncs strictly serial (one person at a time). Token/target changes from handlers run under the same mutex (`changeConnection`).
  - "Jetzt synchronisieren" runs `syncPerson(bgCtx, id, full=true)` in a goroutine, at most one per person (`bgBusy` map). It is not started once `bgCtx` is cancelled.
  - On shutdown `stopBackground()` cancels `bgCtx` and waits for those goroutines.

### 1.5 Summary table

| Job | Start | Interval | TZ | Clock injection | Stop |
|---|---|---|---|---|---|
| fx | at start if cache is behind expected date | next TARGET business day 16:30 Berlin; on miss/error +1 h, max 3 retries | Europe/Berlin (hard-coded) | `Service.now` field (tests only) | ctx cancel; waits for downloads |
| recurring | immediately | every 1 h (ticker) | `Config.Location` | `Service.now` field; `Materialize(ctx, today)` | ctx cancel |
| ynab | first full sync after 15 s | full sync every ~1 h (≥59 min); triggered runs 5 s after a change; `Again` gives 5 s; RetryAt gives wait+1 s; config DB error gives 5 min | `Config.Location` for Today, but Today ≤ UTC today | `Service.now`, `debounce`, `startDelay` fields | ctx cancel; waits for background syncs |

---

## 2. External HTTP

### 2.1 ECB (package fx)

- Base URL: `defaultBaseURL = "https://www.ecb.europa.eu/stats/eurofxref/"` (**with trailing slash**; the URL is `baseURL + file`).

| const | file | contents |
|---|---|---|
| `fileDaily` | `eurofxref-daily.xml` | last business day |
| `file90d` | `eurofxref-hist-90d.xml` | about 90 calendar days |
| `fileHist` | `eurofxref-hist.zip` | everything since 1999 (CSV in a ZIP) |

So the real URLs are `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`, `.../eurofxref-hist-90d.xml`, `.../eurofxref-hist.zip`.

- Request: `GET`. Only header set: `User-Agent: zipfelkasse/1.0 (self-hosted expense tracker; ECB reference rates)`. Go adds `Accept-Encoding: gzip` with transparent decompression, and honours `HTTP(S)_PROXY` (DefaultTransport).
- HTTP client: `&http.Client{Timeout: 60 * time.Second}`, follows redirects (Go default).
- Status ≠ 200 gives error `fmt.Errorf("HTTP status %d", code)`. The body is read through `io.LimitReader(body, 32 MiB)`, which **truncates silently**. A ZIP entry is read with a 128 MiB limit.
- Parsing:
  - Files ending in `.zip` go to `parseHistZip`, everything else to `parseXML`.
  - Zero parsed rates gives `errors.New("file contains no rates")`.
  - Then `SaveECBRates`. For `fileHist`, also `SetSetting("fx.ezb_hist_bis", maxDate)`.
- **XML** (`eurofxref-daily.xml` / `-hist-90d.xml`): the decoder maps `<Envelope><Cube><Cube time="YYYY-MM-DD"><Cube currency="USD" rate="1.1298"/>…`. Namespaces are ignored and the root name is not checked. Day `time` is trimmed and parsed as `2006-01-02`; a bad date aborts the whole file (`"xml: date %q: %w"`). Each rate is kept only if `parseECBRate(rate)` is ok and `ValidCurrencyCode(currency)` (currency **not** trimmed). Decode error gives `"xml: %w"`.
- **ZIP**: the first entry whose extension is `.csv` (case-insensitive) is parsed as CSV; none gives `"zip: no CSV file found"`; a broken zip gives `"zip: %w"`.
- **CSV** (`eurofxref-hist.csv`): header `Date,USD,JPY,…,` (trailing comma, so the last header is `""`). Parsing rules:
  - Go `encoding/csv` with `FieldsPerRecord = -1` and `TrimLeadingSpace = true`.
  - `header[0]` with the BOM `﻿` stripped and trimmed must equal `Date` case-insensitively; otherwise `"csv: unexpected header %q"`.
  - Currency names are the trimmed header cells.
  - Rows that are empty or have an empty first cell are skipped; the date is parsed `2006-01-02`, and a failure is an error.
  - Each cell becomes a rate if `parseECBRate` is ok and the header is a valid currency code. `N/A` and the empty trailing column are dropped.
- `parseECBRate(s)`: `strconv.ParseFloat(strings.TrimSpace(s), 64)`; it is ok only if there was no error, `f > 0` (which also rules out NaN) and `f <= 1e12` (which rules out +Inf). Test table: `"1.1298"→1.1298, " 2 "→2, "N/A","","-1","NaN","Inf"` are all rejected.
- Error type `FetchError{File, Err}`, message (shown to users):
  `Die EZB-Kurse konnten nicht geladen werden (%v). Bitte später erneut versuchen oder den Kurs von Hand eintragen.`
  Here `%v` is the inner Go error text (`HTTP status 500`, the Go net error, `xml: ...`, `file contains no rates`, `context canceled`). Tests only assert `"nicht geladen werden"` and, for HTTP errors, `"500"`.
- **Fetch deduplication and cooldown** (`fetch(ctx, file, force)`):
  - At most one download per file at a time; later callers wait for the running download.
  - After a finished fetch, the same file is fetched again only after `cooldownOK = 15m` (success) or `cooldownError = 1m` (error), measured with `s.now()`. Within the cooldown the cached `(res, err)` is returned. `force=true` (used by `Refresh`) bypasses the cooldown but still waits for a running fetch.
  - The download runs in a background goroutine with `bgCtx` (not the request ctx). The caller waits on `done` or on `ctx.Done()`; the latter returns `ctx.Err()`, which is **not** a FetchError.
  - Logs: `Warn "loading ECB rates failed" file err` or `Info "ECB rates loaded" file rates=<count> from=YYYY-MM-DD to=YYYY-MM-DD`.
- Rate limiting: none (ECB has none); the cooldowns stop hammering.

### 2.2 YNAB API (package ynab, client.go)

- Base URL: `DefaultBaseURL = "https://api.ynab.com/v1"` (**no** trailing slash; paths start with `/`). The code uses the newer `/plans` paths ("budgets" were renamed to "plans" in API v1.79). IDs go through `url.PathEscape`.
- HTTP client: `&http.Client{Timeout: 30 * time.Second}`.
- Headers on every request: `Authorization: Bearer <token>`, `Accept: application/json`; `Content-Type: application/json` when there is a body. No User-Agent is set (Go default `Go-http-client/1.1`).

| Purpose | Method + path | Body / query | Response fields used |
|---|---|---|---|
| plans + accounts (token check, settings page) | `GET /plans?include_accounts=true` | – | `data.plans[]{id,name,currency_format{iso_code},accounts[]{id,name,type,on_budget,closed,deleted}}` |
| categories | `GET /plans/{plan}/categories` | – | `data.category_groups[]{id,name,hidden,internal,deleted,categories[]{id,name,hidden,internal,deleted}}` |
| confirm target | `GET /plans/{plan}/accounts/{acc}` | – | `data.account{…deleted}` |
| create (batch) | `POST /plans/{plan}/transactions` | `{"transactions":[saveTxn…]}` | `data.transactions[]` (`data.transaction_ids` declared, unused) |
| update (batch) | `PATCH /plans/{plan}/transactions` | `{"transactions":[saveTxn with id…]}` | `data.transactions[]` |
| delete | `DELETE /plans/{plan}/transactions/{txn}` | – | ignored |
| search by memo marker | `GET /plans/{plan}/accounts/{acc}/transactions?since_date=YYYY-MM-DD` | – | `data.transactions[]` |

- `apiTxn` JSON: `id, date, amount (int64 milliunits), memo (*string), payee_name (*string), category_id (*string), account_id, cleared, approved, deleted`.
- `saveTxn` JSON (Go field order, `omitempty` where marked):

  ```go
  ID         string  `json:"id,omitempty"`
  AccountID  string  `json:"account_id,omitempty"`
  Date       string  `json:"date"`
  Amount     int64   `json:"amount"`
  PayeeName  string  `json:"payee_name"`      // always sent, even ""
  Memo       string  `json:"memo"`            // always sent
  CategoryID *string `json:"category_id,omitempty"` // only when mapped
  Cleared    string  `json:"cleared,omitempty"`
  Approved   *bool   `json:"approved,omitempty"`
  ```

  - Create: `{account_id, date, amount, payee_name, memo, [category_id], cleared:"cleared", approved:true}`.
  - PATCH: `{id, date, amount, payee_name, memo, [category_id]}`, with no account/cleared/approved.
  - **No `import_id`, ever.** The fake rejects it with 400. Reason: YNAB would merge imported transactions with reimbursement transfers of equal amount.
- Response handling (`client.do`):
  - Transport error: `unclearError{"YNAB nicht erreichbar: %w"}`.
  - Body read (limit 64 MiB) error: `unclearError{"YNAB-Antwort unvollständig: %w"}`.
  - Non-2xx: `*APIError{Status, ID, Name, Detail, RetryAfter}`, parsed from `{"error":{"id","name","detail"}}` (a parse failure is ignored). `Retry-After` is honoured only as an integer number of seconds > 0.
  - 2xx with an unparseable JSON body: `unclearError{"YNAB-Antwort unlesbar: %w"}`.
- `APIError.Error()`:
  - 401: `"YNAB: Token ungültig oder abgelaufen"`
  - 429: `"YNAB: Anfragelimit erreicht (200 pro Stunde)"`
  - else: `"YNAB-Fehler %d"`, plus `": "+Detail` if set, else `": "+Name` if set.
- `uncertain(err)` = unclearError or status ≥ 500. `runLevel(err)` = status ∈ {0 (non-API error), 401, 403, 404, 429} or uncertain.
- Rate limit (YNAB: 200 requests/hour/token). Handled per person, in the status:
  - Backoff: `Backoff = min(max(2*Backoff, 5m), 1h)`; `RetryAt = now + max(Backoff, RetryAfter)`.
  - While `now < RetryAt`, no requests (`backoffError`).
  - Requests are batched: one POST and one PATCH per ≤100 txns, DELETE one by one with ≤40 per run, ≤20 single retries after a rejected batch.
- Settings-page cache:
  - Keys: `"plans:"+fp` and `"categories:"+fp+":"+planID`, where `fp = hex(sha256(token)[:8])` (16 hex chars).
  - TTL 10 min (by `s.now`). `refresh=true` re-loads and overwrites. Errors are not cached.

### 2.3 Configurability / what the E2E suite must override

| Setting | Go today | Override needed for E2E |
|---|---|---|
| ECB base URL | unexported struct field `fx.Service.baseURL`, set only in package tests (they actually replace `client` with a RoundTripper fake, and the fake routes on `path.Base(URL.Path)`) | **Yes.** There is no env var. Add e.g. `ZIPFELKASSE_ECB_BASE_URL` (must end in `/`; the fake must serve `eurofxref-daily.xml`, `eurofxref-hist-90d.xml`, `eurofxref-hist.zip`). |
| YNAB base URL | unexported `ynab.Service.baseURL`; tests set `"https://api.test/v1"` and replace `http` with the RoundTripper `fakeYNAB` | **Yes.** There is no env var. Add e.g. `ZIPFELKASSE_YNAB_BASE_URL` (no trailing slash, includes `/v1`). |
| Clock (fx, recurring, ynab, store) | struct fields `now` / `store.SetClock`, tests only | **Probably**: recurring "today", ECB expected date (before/after 16:30 Berlin), YNAB "Today" and RetryAt all depend on it. E.g. `ZIPFELKASSE_FAKE_NOW`. |
| YNAB debounce / start delay | fields `debounce` (5 s) and `startDelay` (15 s), tests only | Optional. Without it the E2E suite waits about 5 s after a change and about 15 s after boot, or uses "Jetzt synchronisieren" (POST `/einstellungen/ynab/sync`, async) and polls. |
| HTTP timeouts | 60 s ECB, 30 s YNAB, hard-coded | no |
| TZ | env `TZ` | set `TZ=Europe/Berlin` in E2E for parity |

Startup side effect: on boot `fx.Run` immediately downloads `eurofxref-hist-90d.xml` when the cache is empty. Without a fake ECB this only logs an error (non-fatal). `ynab.Run` does nothing until someone has a Ready config.

### 2.4 Test fakes to mirror (what responses look like)

**fakeECB** (`fx_test.go`):
- Serves the testdata files keyed by base name. The ZIP is built on the fly from `eurofxref-hist.csv`, with the entry named `eurofxref-hist.csv`.
- Unknown file gives 404. Fields `err` (network error), `status` (override) and `block` (hang until close) let tests inject failures. It also records `User-Agent`; the test asserts it starts with `zipfelkasse/`.

**Testdata contents:**
- `eurofxref-daily.xml`: day 2026-10-01 with USD 1.1298, JPY 178.49, GBP 0.85373, CHF 0.9437, IDR 20274.71. Uses single quotes.
- `eurofxref-hist-90d.xml`: 18 rates (3 currencies × 6 days). Days 2026-10-01 (USD 1.1298, JPY 178.49, GBP 0.85373), 09-30 (1.1275/177.9/0.8541), 09-29 (1.1251/177.12/0.8533), 09-28 (1.1240/176.8/0.8529), 09-25 (1.1222/176.5/0.8520), 07-06 (1.1102/171.3/0.8601).
- `eurofxref-hist.csv`:

  ```
  Date,USD,JPY,BGN,CYP,GBP,RUB,
  2026-10-01,1.1298,178.49,N/A,N/A,0.85373,N/A,
  2024-01-03,1.0919,155.94,1.9558,N/A,0.86375,N/A,
  2024-01-02,1.0956,155.67,1.9558,N/A,0.86960,N/A,
  2022-03-01,1.1124,128.38,1.9558,N/A,0.83600,N/A,
  2022-02-28,1.1240,129.27,1.9558,N/A,0.83790,117.2470,
  1999-01-04,1.1789,133.73,N/A,0.58231,0.71110,25.2156,
  ```

  Expected counts: USD 6, CYP 1, RUB 2, BGN 4.

**fakeYNAB** (`ynab/fake_test.go`, an in-memory RoundTripper; the E2E fake needs the same behaviour):
- Accepts tokens `geheimer-token-123` (testToken) and `token-anderer-nutzer` (otherToken). Any other `Authorization` value gives 401 `{"error":{"id":"401","name":"unauthorized","detail":"Unauthorized"}}`.
- Error injection, in order of precedence:
  - `failNext` queue: 429 sets `Retry-After: 60` with error `too_many_requests`; any other code returns detail `"Fehler <code> mit geheimer-token-123"` (contains the token, which tests use to check redaction).
  - Host ≠ `api.test` gives 404.
  - `otherToken` behaves like a different YNAB user: `GET /v1/plans` lists `plan-2` "Anderer Haushalt" with account `acc-2` "Geteilt"; every other path gives 404 `resource_not_found`.
- Fixed data:
  - Plan `plan-1` "Haushalt", currency `EUR`.
  - Accounts: `acc-geteilt` "Geteilt" (cash, on_budget); `acc-giro` "Girokonto" (checking, on_budget); `acc-depot` "Depot" (off budget); `acc-alt` "Altes Konto" (closed).
  - Category groups:
    - `g-int` internal, containing `c-rta` "Inflow: Ready to Assign"
    - `g-cc` "Credit Card Payments", containing `c-visa`
    - `g-1` "Alltag", containing `c-food` "Lebensmittel & Drogerie", `c-out` "Essen gehen", and `c-old` "Versteckt" (hidden)
- Routes (under `/v1`): `GET /plans` (requires `include_accounts=true`, else 400), `GET /plans/{plan}/categories`, `POST|PATCH /plans/{plan}/transactions`, `DELETE /plans/{plan}/transactions/{id}`, `GET /plans/{plan}/accounts/{acc}`, `GET /plans/{plan}/accounts/{acc}/transactions?since_date=`.
- POST behaviour:
  - Rejects the **whole batch** with 400 if any txn has `import_id`, or if any `payee_name` contains `ABLEHNEN` (detail `"payee rejected"`).
  - Assigns IDs `t1, t2…` and returns 201 `{"data":{"transaction_ids":[…],"transactions":[…],"server_knowledge":2}}`.
  - `lostPost`: stores the transactions but answers 500.
- PATCH: 404 if any id is unknown. Deleted txns are returned unchanged (with `deleted:true`).
- DELETE: 404 if unknown or already deleted; otherwise marks it deleted.
- List: non-deleted txns of that account with `date >= since_date`.

---

## 3. HTTP routes

### 3.1 FX (`fx.Service.Register`)

| Method | Path | Inputs | Success | Errors |
|---|---|---|---|---|
| GET | `/api/kurs` | query `waehrung`, optional `datum` | 200 JSON `{"currency":"USD","date":"2026-10-01","rate":1.1298,"source":"ezb"}` | 400 `{"error":"Bitte eine Währung angeben."}` if trimmed currency is empty; 400 `{"error":"Ungültige Währung „<raw query value>“."}` if not EUR and not `[A-Z]{3}` after upper-casing; 400 with the ParseDate message for a bad `datum`; 422 `{"error":<ValidationError msg>}` (no rate); 502 `{"error":<FetchError text>}`; 500 `{"error":"Der Kurs konnte nicht ermittelt werden."}` (and log `Error "rate" currency err`) |
| GET | `/einstellungen/kurse` | – | 200 page `kurse.html`, Title `Wechselkurse`, Nav `einstellungen` | 500 on DB error |
| POST | `/einstellungen/kurse` | form `waehrung` (trim + upper), `datum` (trim; ParseDate), `kurs` (trim; ParseRate) | flash `Kurs für <CUR> gespeichert.` and 303 to `/einstellungen/kurse` | 422 page with `.Error` = validation message; the form keeps its values |
| POST | `/einstellungen/kurse/loeschen` | form `waehrung`, `datum` | flash `Manueller Kurs für <CUR> gelöscht.` and 303 to `/einstellungen/kurse` | **404** page with error `Diesen manuellen Kurs gibt es nicht (mehr).` (also for an unparseable date) |
| POST | `/einstellungen/kurse/aktualisieren` | – | `Refresh()`, then flash `EZB-Kurse aktualisiert (Stand <dd.mm.yyyy>).` and 303 | **502** page with `.Error` = FetchError text; 500 otherwise |

`/api/kurs` details:
- Content-Type is `application/json; charset=utf-8`; the body is `json.NewEncoder(w).Encode(v)`, so it has a **trailing newline** and HTML characters escaped as `<` etc.
- Without `datum`, the date is `s.today()`.
- For EUR, the response date is the *requested* date (not clamped), rate `1`, source `"fest"`. Test: `/api/kurs?waehrung=EUR` gives `{"currency":"EUR","date":"2026-10-02","rate":1,"source":"fest"}`.
- The response date is the date of the rate actually used (e.g. Friday for a Sunday request).
- **Rate encoding**: Go encodes `1.0` as `1` and `1.1298` as `1.1298` (shortest repr, no exponent for 1e-6 ≤ |x| < 1e21).
- Used by `internal/web/static/expense-form.js`: `"/api/kurs?waehrung=" + encodeURIComponent(cur) + "&datum=" + encodeURIComponent(dateEl.value)`.

Manual-rate validation order in `handleSaveManual`:
1. `ParseDate(datum)`
2. `ParseRate(kurs)`: `"Ungültiger Wechselkurs „%s“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €)."` (`%s` = the input with spaces and NBSPs removed)
3. `Store.SetManualFXRate`, whose own checks run in this order:
   - `EUR`: `"Für Euro braucht es keinen Kurs."`
   - invalid code: `"Bitte einen dreistelligen Währungscode angeben (z. B. USD)."`
   - zero date: `"Bitte ein Datum angeben."`
   - rate not > 0, infinite, or > 1e9: `"Der Kurs muss größer als 0 sein."`

Activity entries (actor = me):
- save: `Manueller Kurs für %s ab %s gespeichert: 1 € = %s %s` (currency, FormatDate, FormatRate, currency). E.g. `Manueller Kurs für VND ab 03.09.2026 gespeichert: 1 € = 17000,5 VND`.
- delete: `Manueller Kurs für %s ab %s gelöscht`.

Page data (`pageData`):
- `Manual []rateRow` (all manual rates, `ORDER BY currency, date DESC`)
- `Latest []rateRow` (ECB rates of the newest cached day, by currency)
- `Used []rateRow` (10 most recent non-deleted non-EUR expenses: `ORDER BY date DESC, id DESC`; fields Title, ID, date = expense date, rate = expense.fx_rate, source label of expense.fx_source)
- `Stats FXCacheStats{Count, Currencies, From, To}`
- `Currencies []string` (all distinct currencies in fx_rates, used for the `<datalist>`)
- `Form manualForm{Currency, Date, Rate}` (Date defaults to today as `YYYY-MM-DD`)
- `rateRow.Rate` = `FormatRate`, a German decimal like `1,1298`. Source labels: `ezb`→`EZB`, `manuell`→`manuell`, `fest`→`fest`, `""`→`–`, otherwise the raw value.

### 3.2 Recurring (`recurring.Service.Register`)

| Method | Path | Inputs | Success | Errors |
|---|---|---|---|---|
| GET | `/einstellungen/wiederkehrend` | – | 200 `wiederkehrend.html`, Title `Wiederkehrende Ausgaben` | 500 |
| GET | `/einstellungen/wiederkehrend/neu` | query `ausgabe` (optional) | 200 `wiederkehrend_neu.html`, Title `Wiederkehrende Ausgabe anlegen`. Without `ausgabe` (empty) it shows the "Öffne zuerst…" hint. | 404 error page `Ausgabe nicht gefunden.` (non-numeric, ≤0, unknown, or deleted) |
| POST | `/einstellungen/wiederkehrend/neu` | form `ausgabe`, `haeufigkeit` ∈ `weekly`/`monthly`/`yearly` | creates the rule, then `MaterializeRule(id, today)`; flash `„<Title>“ wiederholt sich jetzt <wöchentlich/monatlich/jährlich>.` plus `" 1 Ausgabe nachgetragen."` / `" N Ausgaben nachgetragen."` if n>0; 303 to `/einstellungen/wiederkehrend` | 404 `Ausgabe nicht gefunden.`; 422 page re-rendered with `.Error` = `Bitte eine Häufigkeit wählen.` or `Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe.` (the form shows options with `Checked = (f == submitted freq)`) |
| POST | `/einstellungen/wiederkehrend/{id}/pausieren` | – | flash `Pausiert.` and 303 to list | 404 error page `Wiederkehrende Ausgabe nicht gefunden.` (bad id or ErrNotFound) |
| POST | `/einstellungen/wiederkehrend/{id}/fortsetzen` | – | `SetRecurringActive(true)`, then `MaterializeRule`; flash `Fortgesetzt.` plus `" 1 Ausgabe angelegt."` / `" N Ausgaben angelegt."` | 404 as above |
| POST | `/einstellungen/wiederkehrend/{id}/vorlage` | – | flash `Vorlage aus der letzten Ausgabe übernommen.`; if no instance exists: flash `Es gibt keine Ausgabe dieser Wiederholung mehr, aus der die Vorlage übernommen werden könnte.` (still 303) | 404 as above |
| POST | `/einstellungen/wiederkehrend/{id}/loeschen` | – | flash `Wiederholung gelöscht. Bereits angelegte Ausgaben bleiben erhalten.` and 303 | 404 as above |

More details:
- `{id}` is parsed by `web.PathID`: `ParseInt`; error or ≤0 gives 0, which gives 404.
- `ausgabe` is read via `r.FormValue`, so query or body both work.
- Errors from `MaterializeRule` in handlers are only logged (`Error "recurring expenses" err`). The flash is still set.
- Activity entries (actor = me):
  - pause/resume: `Wiederholung „<Title>“ (<label lower>) pausiert` / `… fortgesetzt` (label lower = `wöchentlich`/`monatlich`/`jährlich`)
  - template refresh: `Wiederholung „<Title>“ (<label lower>): Vorlage aus der letzten Ausgabe übernommen`
  - create: action `recurring_created`, `expense_id` = template expense, details `{title, amount_cents, text:"„<Title>“ wiederholt sich jetzt <adverb>."}`
  - delete: action `recurring_deleted`, `expense_id NULL`, details `{title, amount_cents, text:"Wiederholung von „<Title>“ beendet."}`

### 3.3 YNAB (`ynab.Service.Register`), all under `/einstellungen/ynab`

| Method | Path | Inputs | Success | Errors |
|---|---|---|---|---|
| GET | `/einstellungen/ynab` | query `neu=1` (bypass the 10-min cache) | 200 `ynab.html`, Title `YNAB` | 500 |
| POST | `/einstellungen/ynab/token` | form `token` (TrimSpace) | `GET /plans` with the new token (forced refresh), then store it under syncMu. If the old plan is not among the token's plans, plan/account are reset and the flash is `Token gespeichert. Der bisher gewählte Plan ist mit diesem Token nicht erreichbar – bitte Plan und Konto neu wählen.` (no Trigger). Otherwise `Trigger(0)` and flash `Token gespeichert.` 303 to `/einstellungen/ynab`. | 422: `Bitte einen Token eingeben.` (empty); `Das sieht nicht wie ein YNAB-Token aus.` (len > 200 bytes or contains space/tab/CR/LF); on a YNAB error, 401 gives `YNAB kennt diesen Token nicht. Bitte prüfen und neu kopieren.` and anything else gives `YNAB ist gerade nicht erreichbar: <redacted err>` (also **422**). The token is **not** stored on error. |
| POST | `/einstellungen/ynab/trennen` | – | `SetYNABToken(me, "", nil)` under syncMu; flash `YNAB-Verbindung getrennt. Die Buchungen in YNAB bleiben erhalten.` (no Trigger) | 500 |
| POST | `/einstellungen/ynab/konto` | form `ziel` = `"<planID>\|<accountID>"` (split at first `\|`), `start` (ParseDate) | `SetYNABTarget` under syncMu, `Trigger(0)`, flash `Gespeichert.` | 422 `Bitte zuerst einen Token eingeben.` (no config or empty token); 422 `Bitte ein gültiges Startdatum angeben.`; 502 `apiMessage(err)` if plans fail (cached call); 422 `Bitte Plan und Konto auswählen.` (account not in a usable account of that plan) |
| POST | `/einstellungen/ynab/kategorien` | form fields `kat-<appCategoryID>` = YNAB category ID or `""` | full **replace** of the mapping; `Trigger(0)`; flash `Kategorie-Zuordnung gespeichert.` | 422 `Bitte zuerst Token, Plan und Konto einrichten.` (no config / token / plan); 502 apiMessage (categories, cached); 400 `Ungültiges Formular.` (ParseForm error); 422 `Unbekannte YNAB-Kategorie. Bitte die Seite neu laden.` (value not empty, not a usable category, and not already the stored value for that id); 422 store validation `Unbekannte Kategorie.` |
| POST | `/einstellungen/ynab/sync` | – | starts a background full sync for me; flash `Synchronisierung gestartet – Status unten aktualisiert sich nach dem Neuladen.` | 422 `YNAB ist noch nicht fertig eingerichtet (Token, Plan, Konto und Startdatum).` if not Ready; 500 on DB error |

- `apiMessage(err, token)`: 401 gives `Der YNAB-Token ist ungültig oder abgelaufen. Bitte einen neuen Token eintragen.`; anything else gives `"YNAB ist gerade nicht erreichbar: " + redact(err.Error(), token)`.
- `kat-` keys that do not parse as int64 are ignored. App categories missing from the form lose their mapping.
- `usableAccounts(plan)` = accounts with `on_budget && !closed && !deleted`.
- `usableGroups`: skip groups that are `internal || hidden || deleted || name == "Credit Card Payments"`; inside a group skip categories that are `hidden || deleted || internal`; drop empty groups.

Render logic (`render(w,r,status,errMsg,refresh)`) builds `pageData`:

| Field | Value |
|---|---|
| `TokenSet` | `cfg.Token != ""` |
| `TokenInvalid` | `TokenSet && Status.TokenInvalid` |
| `StartDate` | `cfg.StartDate`, or `today()` (min of local and UTC date) |
| `Ready` | `cfg.Ready()` |
| `HasTarget` | `cfg.AccountID != ""` |
| `Status` | GetYNABStatus (zero without config) |
| `RetryAt` | `Status.RetryAt` only if after `now` |
| `Synced` | count of sync rows with a txn ID |
| `Problems` | rows with `last_error != ''`, joined with expense title/date, newest first |
| `Balance` | `Store.Balances()[me.ID]` (cents) |
| `Plans` | if `TokenSet && !TokenInvalid`: plans (cached unless refresh); on error `APIError` is set. `planOption{Name, Accounts[{Value:"plan\|acc", Name, Selected}]}`, only plans with usable accounts. For the selected account: `PlanName`, `AccountName`, and `Currency` = plan iso_code if it is neither `""` nor `EUR`. |
| `Groups` | if `PlanID != ""` and no APIError: categories, then usableGroups |
| `Categories` | if `HasTarget`: `ListCategories(includeArchived=true)`, skipping archived ones without a mapping. `categoryRow{ID, Name, Archived, Selected = mapped ID, Missing = Selected != "" && len(Groups) > 0 && !known[Selected]}` |

The token is never put into `pageData`. Test: the HTML must never contain the token.

---

## 4. Recurring expenses

### 4.1 Rule storage (`recurring` table, migration 001)

```sql
CREATE TABLE recurring (
    id            INTEGER PRIMARY KEY,
    template_json TEXT    NOT NULL,             -- store.ExpenseInput as JSON (date ignored)
    frequency     TEXT    NOT NULL CHECK (frequency IN ('weekly','monthly','yearly')),
    start_date    TEXT    NOT NULL,             -- anchor, YYYY-MM-DD
    next_date     TEXT    NOT NULL,             -- next occurrence not yet created
    active        INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
    created_by    INTEGER REFERENCES participants (id),
    created_at    TEXT    NOT NULL, updated_at TEXT NOT NULL);
CREATE INDEX recurring_due ON recurring (next_date) WHERE active = 1;
-- in expenses: recurring_id INTEGER REFERENCES recurring (id) ON DELETE SET NULL
CREATE UNIQUE INDEX expenses_recurring_date ON expenses (recurring_id, date) WHERE recurring_id IS NOT NULL;
```

`template_json` = `json.Marshal(templateOf(e))`, the Go `ExpenseInput` with JSON tags:

```json
{"title":"Miete","date":"0001-01-01T00:00:00Z","category_id":0,"paid_by":1,"notes":"","is_reimbursement":false,
 "split_mode":"equal","amount_cents":100000,"parts":[{"participant_id":1,"weight":1},{"participant_id":2,"weight":1}],
 "original_amount_minor":100000,"original_currency":"EUR","fx_rate":1,"fx_source":"","recurring_id":0}
```

- `date` is Go's zero time in RFC 3339; `recurring_id` is 0.
- Parts hold the **normalized weights** read back from the expense.
- Migration 4 (`convertAmountWeights`, not in scope) also rewrites templates.

**PORT**: Crystal must read existing rows of exactly this format and write the same format, including `"date":"0001-01-01T00:00:00Z"`, `fx_rate` as a JSON number (`1`, not `1.0`, if byte-identity matters), and missing keys taking zero values.

Frequency labels: `Label()` gives `Wöchentlich`/`Monatlich`/`Jährlich`; `Adverb()` gives `wöchentlich`/`monatlich`/`jährlich`. `domain.Frequencies` order: weekly, monthly, yearly.

### 4.2 Occurrence arithmetic (`domain/date.go`), anchor-based with end-of-month clamping

```go
func Occurrence(f Frequency, anchor time.Time, n int) time.Time {   // n=0 is the anchor
    anchor = DateOf(anchor)
    switch f {
    case FreqWeekly:  return anchor.AddDate(0, 0, 7*n)
    case FreqMonthly: return addMonthsClamped(anchor, n)
    case FreqYearly:  return addMonthsClamped(anchor, 12*n)
    }
    return anchor
}
func NextDate(f Frequency, anchor, after time.Time) time.Time {   // first occurrence strictly after `after`
    anchor, after = DateOf(anchor), DateOf(after)
    if after.Before(anchor) || !f.Valid() { return anchor }
    var n int
    switch f {
    case FreqWeekly:  n = int(after.Sub(anchor).Hours()/24) / 7
    case FreqMonthly: n = monthsBetween(anchor, after)
    case FreqYearly:  n = monthsBetween(anchor, after) / 12
    }
    n = max(n-1, 0)
    for { if t := Occurrence(f, anchor, n); t.After(after) { return t }; n++ }
}
func monthsBetween(a, b) int { return (b.Year()-a.Year())*12 + int(b.Month()) - int(a.Month()) }
func addMonthsClamped(t time.Time, months int) time.Time {
    y, m := t.Year(), int(t.Month())-1+months
    y += m / 12; m %= 12
    if m < 0 { m += 12; y-- }
    month := time.Month(m + 1)
    day := min(t.Day(), daysIn(y, month))
    return time.Date(y, month, day, 0,0,0,0, time.UTC)
}
func daysIn(year int, month time.Month) int { return time.Date(year, month+1, 0, 0,0,0,0, time.UTC).Day() }
```

- Month-end: anchor 31 Jan gives 28 Feb, 31 Mar, 30 Apr, 31 May (always from the anchor, so no drift).
- Leap day: anchor 2024-02-29 yearly gives 2025-02-28, 2026-02-28, 2027-02-28, 2028-02-29.
- **No timezone in the arithmetic**: all values are UTC-midnight dates; "today" comes from `Config.Location`.

### 4.3 Creating a rule (`Store.CreateRecurringFromExpense(actor, expenseID, freq)`)

1. If `!freq.Valid()`: `ValidationError "Bitte eine Häufigkeit wählen."`. This is checked **before** the expense lookup.
2. In a transaction:
   - Load the expense; missing or deleted gives `ErrNotFound`.
   - If `RecurringID != 0`: `ValidationError "Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe."`.
   - `next = NextDate(freq, e.Date, e.Date)` (the first occurrence after the anchor).
   - INSERT recurring (`active = 1`, `created_by = NULLIF(actor, 0)`, `created_at = updated_at = now`).
   - `UPDATE expenses SET recurring_id = <new id> WHERE id = expenseID`. The original expense is instance #0.
   - Insert activity `recurring_created`.

### 4.4 Materialization (catch-up) algorithm

```go
func (s *Service) Materialize(ctx context.Context, today time.Time) (int, error) {
    s.mu.Lock(); defer s.mu.Unlock()
    today = domain.DateOf(today)
    due, err := s.d.Store.DueRecurring(ctx, today) // active=1 AND next_date <= today ORDER BY next_date, id
    if err != nil { return 0, err }
    var errs []error; n := 0
    for _, r := range due {
        k, err := s.materializeRule(ctx, r, today); n += k
        if err != nil { errs = append(errs, fmt.Errorf("recurring rule %d (%q): %w", r.ID, r.Template.Title, err)) }
        if ctx.Err() != nil { break }
    }
    return n, errors.Join(errs...)
}
// MaterializeRule(ctx, id, today): same lock; unknown id → (0,nil); !Active or NextDate > today → (0,nil);
// error wrapped the same way.

func (s *Service) materializeRule(ctx, r store.Recurring, today) (int, error) {
    if !r.Frequency.Valid() { return 0, fmt.Errorf("unknown frequency %q", r.Frequency) }
    existing, err := s.d.Store.ExpenseDatesLike(ctx, r.Template, r.NextDate, today)
    if err != nil { return 0, err }
    n := 0
    for i, d := 0, r.NextDate; !d.After(today); i++ {
        if i == maxInstancesPerRun /*400*/ {
            s.d.Log.Info("recurring expenses: per-run limit reached, the rest follows in the next run",
                "rule", r.ID, "next_date", d.Format(DateLayout), "limit", 400)
            break
        }
        created, err := s.createOccurrence(ctx, r, d, existing[d])
        if created { n++ }
        if err == nil {
            next := domain.NextDate(r.Frequency, r.StartDate, d)
            err = s.d.Store.SetRecurringNextDate(ctx, r.ID, d, next)   // optimistic: WHERE active=1 AND next_date=d
            d = next
        }
        if errors.Is(err, store.ErrRecurringChanged) {
            s.d.Log.Info("recurring expenses: rule changed meanwhile, stopping its catch-up", "rule", r.ID)
            return n, nil
        }
        if err != nil { return n, err }   // next_date stays → retried next run
    }
    return n, nil
}

func (s *Service) createOccurrence(ctx, r, d, exists bool) (bool, error) {
    if exists {
        s.d.Log.Info("recurring expense: an equal expense already exists, skipping the occurrence", "rule", r.ID, "date", d)
        return false, nil
    }
    in, err := s.instance(ctx, r, d); if err != nil { return false, err }
    _, err = s.d.Store.CreateExpense(ctx, 0 /*system actor*/, in)
    if errors.Is(err, store.ErrRecurringExists) { return false, nil }   // unique (recurring_id,date)
    return err == nil, err
}

func (s *Service) instance(ctx, r, date) (store.ExpenseInput, error) {
    in := r.Template; in.Parts = slices.Clone(in.Parts)
    in.Date, in.RecurringID = date, r.ID
    cur := in.OriginalCurrency
    if domain.IsEUR(cur) || s.d.FX == nil { return in, nil }
    rate, err := s.d.FX.Rate(ctx, cur, date)
    var ve domain.ValidationError
    switch {
    case errors.As(err, &ve):   // no rate exists → keep the template's rate/source
        s.d.Log.Warn("recurring expense: no rate for the date, using the template's rate", "rule", r.ID, "currency", cur, "date", date, "err", err)
        return in, nil
    case err != nil:            // temporary (ECB down, DB) → error, the occurrence is retried next run
        return in, fmt.Errorf("rate for %s on %s not available, retrying in the next run: %w", cur, date, err)
    }
    amount := domain.ToEURCents(in.OriginalAmountMinor, cur, rate.Rate)
    if amount <= 0 || amount > domain.MaxAmountCents /*1e12*/ { return in, nil }
    in.AmountCents, in.FXRate, in.FXSource = amount, rate.Rate, rate.Source   // "ezb" or "manuell"
    return in, nil
}
```

Notes:
- **Catch-up**: all missed occurrences up to and including today are created in one run, up to 400 per rule per run. The rest follow in the next hourly run.
- **Skip rule** (`Store.ExpenseDatesLike(in, from, to)`) returns the set of dates in `[from, to]` on which a non-deleted expense exists with:
  - the same title (normalized with `strings.Join(strings.Fields(title), " ")`), the same `paid_by` and the same `original_currency`, and
  - for EUR, the same `amount_cents`; for foreign currency, the same `original_amount_minor` (currency upper-cased and trimmed).

  It does **not** filter on `recurring_id`, so the rule's own existing instances count too. Skipped occurrences still advance `next_date`.
- `CreateExpense` with `RecurringID != 0` checks inside the transaction that the rule exists and is active. Otherwise it returns `ErrRecurringChanged`, which stops the rule's catch-up without an error.
- `CreateExpense` runs `normalize()`. For foreign currency it **recomputes** `AmountCents = ToEURCents(OriginalAmountMinor, cur, FXRate)` (a given value is ignored), and EUR inputs force `OriginalAmountMinor = AmountCents`, `FXRate = 1`, `FXSource = ""`.
- **Generated expense**: same title/category/payer/notes/split/parts as the template, `date` = occurrence, `recurring_id` = rule id, `created_at` = now.
  - Activity: action `expense_created`, `actor_id NULL` (system), `expense_id` = new id, details `{"title":…,"amount_cents":…}`.
  - It fires the store change hook, which triggers YNAB.
- Split by amounts with foreign currency: the weights stay in the foreign currency, and euro shares follow the occurrence's rate (`TestMaterializeForeignFixedAmounts`: USD 60/40 at 1.25 gives 4800/3200 cents).

### 4.5 Pause / resume / template / delete (store)

`SetRecurringActive(actor, id, active, today)`:

```go
next, verb := r.NextDate, "pausiert"
if active {
    verb = "fortgesetzt"
    if !r.Active && next.Before(today) {
        next = domain.NextDate(r.Frequency, r.StartDate, today.AddDate(0, 0, -1))  // first occurrence ≥ today
    }
}
UPDATE recurring SET active=?, next_date=?, updated_at=? WHERE id=?
logSettings(actor, ruleLabel(r)+" "+verb)
```

- Missed occurrences from the pause are **not** caught up. Resuming exactly on an occurrence date keeps that date.
- Example: weekly anchor Mon 2026-01-05, resumed on Wed 2026-03-04, gives next 2026-03-09.
- `SetRecurringNextDate(id, from, next)`: `UPDATE … SET next_date=?, updated_at=? WHERE id=? AND active=1 AND next_date=?`. 0 rows gives `ErrRecurringChanged`.
- `UpdateRecurringTemplateFromLatest`:
  - Takes the latest non-deleted instance (`recurring_id = id ORDER BY date DESC, id DESC LIMIT 1`) and stores `templateOf()` of it.
  - No rule gives `ErrNotFound`; no instance gives `ErrNoInstance`.
- `DeleteRecurring`: hard `DELETE FROM recurring`; expenses keep existing (`ON DELETE SET NULL`). Missing rule gives `ErrNotFound`.
- `ListRecurring`: `ORDER BY active DESC, next_date, id`.

### 4.6 "New rule" preview (`newData`, `freqOption.Note()`)

- `existing = ExpenseDatesLike(e.ExpenseInput, e.Date+1day, today)`, computed only if `e.Date < today`.
- For each frequency:
  - `Next = NextDate(f, e.Date, e.Date)`.
  - Count occurrences `d` from Next while `d <= today && Missed <= 1000` (so the count stops at 1001).
  - `Existing` counts the dates found in `existing`.
- `Checked = (f == selected)`: GET uses monthly; POST errors use the submitted value.

`Note()` (exact strings):

```go
capped := o.Missed > 1000
when := "sofort eingetragen"
if o.Missed > 400 { when = "eingetragen – die ersten 400 Termine sofort, der Rest in den nächsten Stunden" }
switch n := o.Missed - o.Existing; {
case capped: parts += "mehr als 1000 verpasste Termine werden " + when
case n == 1: parts += "1 verpasster Termin wird " + when
case n > 1:  parts += fmt.Sprintf("%d verpasste Termine werden %s", n, when)
}
atLeast := ""; if capped { atLeast = "mindestens " }
if o.Existing == 1 { parts += atLeast + "1 bereits als Ausgabe vorhandener Termin wird übersprungen" }
else if o.Existing > 1 { parts += fmt.Sprintf("%s%d bereits als Ausgabe vorhandene Termine werden übersprungen", atLeast, o.Existing) }
return strings.Join(parts, "; ")
```

The `when` text depends on `Missed` (not on `Missed - Existing`). So with Missed=610 and Existing=10 the note says "600 verpasste Termine werden eingetragen – die ersten 400…".

---

## 5. FX

### 5.1 Storage (`fx_rates`, migrations 001 and 003)

After migration 003:

```sql
CREATE TABLE fx_rates (
    date     TEXT NOT NULL,
    currency TEXT NOT NULL,
    rate     REAL NOT NULL CHECK (rate > 0),          -- foreign currency per 1 EUR (ECB format)
    source   TEXT NOT NULL DEFAULT 'ezb' CHECK (source IN ('ezb', 'manuell')),
    PRIMARY KEY (currency, source, date)
) WITHOUT ROWID;
```

- **Migration 003 ("source key")**: before it the primary key was `(currency, date)`, so a manual rate overwrote the ECB row of its day, and deleting it left a gap.
  - Now manual and ECB rows of the same day sit side by side. Precedence is applied in the lookup (`fx.Service.Rate`), not in the table.
  - The migration copies rows into `fx_rates_new`, drops the old table and renames the new one.
  - Test `TestMigrationSeparatesFXRateSources`: an old DB at version 2 with `('2026-09-29','USD',1.1,'ezb')` and `('2026-09-30','USD',1.2,'manuell')` keeps both after migrating.
- Source values: `domain.FXSourceECB = "ezb"`, `FXSourceManual = "manuell"`, `FXSourceFixed = "fest"` (EUR only, never stored in fx_rates). The expense column `fx_source` is `'' | 'ezb' | 'manuell'`.
- Settings key: `fx.ezb_hist_bis` = latest date (YYYY-MM-DD) of a fully loaded `eurofxref-hist.zip`. Days ≤ this date are treated as fully cached: a missing day is a real gap, not a reason to fetch.
- Store functions:
  - `SaveECBRates`: in one transaction, upsert `ON CONFLICT (currency, source, date) DO UPDATE SET rate = excluded.rate` with source `'ezb'`; skips `rate` not > 0, infinite rates and invalid codes.
  - `SetManualFXRate`: upsert source `'manuell'` plus activity.
  - `DeleteManualFXRate`: deletes only `source = 'manuell'`; 0 rows gives `ErrNotFound`.
  - `LookupFXRate(currency, source, date, notBefore)`:
    ```sql
    SELECT date, rate FROM fx_rates WHERE currency=? AND source=? AND date <= ? [AND date >= notBefore] ORDER BY date DESC LIMIT 1
    ```
    A zero `notBefore` means no lower bound; no row gives `ErrNotFound`.
  - `ECBCacheStats`: `count(*)`, `count(DISTINCT currency)`, `min(date)`, `max(date)` over `source='ezb'`.
  - `LatestECBRates`: rows where `date = max(date)` of ezb, ordered by currency.
  - `ListManualFXRates`: ordered by currency, then date DESC.
  - `ListFXCurrencies`: distinct currencies over all sources.
  - `HasECBCurrency`: whether any ezb row exists for the currency.
  - `RecentUsedFXRates(limit)`: from expenses, as in §3.1.

### 5.2 Lookup rules: `Service.Rate(ctx, currency, date)` (full algorithm)

```go
cur := strings.ToUpper(strings.TrimSpace(currency)); date = DateOf(date)
if cur == "EUR" { return FXRate{"EUR", date, 1, "fest"} }
if !ValidCurrencyCode(cur) {
    if cur == "" { return ValidationError("Bitte eine Währung angeben.") }
    return ValidationError("Ungültige Währung „" + currency /*raw*/ + "“.")
}
if today := s.today(); date.After(today) { date = today }          // future → latest rate
// 1. manual rate: latest manual with valid-from <= date, no lower bound
if r, err := LookupFXRate(cur, "manuell", date, zero); err == nil { return r } else if !NotFound(err) { return err }
// 2. ECB cache within 10 days back
window := date.AddDate(0,0,-10); histUntil := s.histUntil()
r, err = LookupFXRate(cur, "ezb", date, window)
switch {
case err == nil && (!r.Date.Before(s.expectedDate(date)) || !date.After(histUntil)): return r     // fresh enough or history complete
case err != nil && !NotFound(err): return err
case err != nil && !date.After(histUntil): return s.noRate(cur, date, nil)     // fully cached period: real gap
}                                                                               // else: fetch
// 3. fetch the matching file, escalating to bigger ones
var res loadResult; var fetchErr error
for _, file := range filesFor(date, s.today()) {
    if file == fileHist && !date.After(s.histUntil()) { break }
    res, fetchErr = s.fetch(ctx, file, false)
    if fetchErr != nil || res.covers(date) { break }    // covers: !res.From.IsZero() && date >= res.From
}
r, err = LookupFXRate(cur, "ezb", date, window)
switch { case err == nil: return r; case !NotFound(err): return err; case fetchErr != nil: return fetchErr }
return s.noRate(cur, date, res.Currencies)

func filesFor(date, today) []string {
    age := int(today.Sub(date).Hours() / 24)
    switch { case age <= 1: return {daily, 90d, hist}; case age < 85: return {90d, hist} }
    return {hist}
}
func noRate(cur, date, fetched) error {
    known := fetched[cur]; if !known { known = Store.HasECBCurrency(cur) }
    if !known { return ValidationError("Für " + cur + " gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.") }
    return ValidationError("Für " + cur + " gibt es um den " + FormatDate(date) + " keinen EZB-Kurs – bitte Kurs von Hand eintragen.")
}
```

Notes on the lookup:
- "Nearest previous date": a manual rate applies from its date until a newer manual rate, with no time limit. An ECB rate applies from its date up to **10 days** later (`lookbackDays = 10`).
- The returned `FXRate.Date` is the date of the rate actually used.
- A fetch error on the first file stops the escalation (the loop breaks).
- `Refresh(ctx)`:
  - Uses the daily file, unless the cache is empty or `stats.To < lastBusinessDay(expectedDate(today) - 1 day)`; then it uses the 90-day file.
  - Calls `fetch(file, force=true)` and returns `res.To`, the newest date in the file.

Scenario expectations (fake clock Fri 2026-10-02 12:00 Berlin):
- USD 2026-10-01 loads the daily file: 1.1298.
- USD 2026-10-02 (before 16:30) gives the cached 10-01 rate with no fetch.
- GBP 2026-12-24 (future) gives the latest rate, 0.85373.
- JPY Sun 2026-09-27 loads the 90d file and returns Fri 09-25's 176.5.
- At 17:00, if the daily file only contains 10-02, a request for 10-01 escalates to the 90d file.
- USD 2024-01-03 loads hist.zip once: 1.0919.
  - GBP 2022-03-06 gives 0.836 dated 2022-03-01, served from cache.
  - RUB 2024-01-03 gives `"…um den 03.01.2024 keinen EZB-Kurs…"`.
  - XYZ gives `"Für XYZ gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen."`.
  - After a restart nothing is re-downloaded; JPY 1998-12-31 gives "keinen EZB-Kurs".
- Unknown XYZ for a recent date fetches once; a repeated call within 15 min does not fetch again.
- A manual USD 1.2 from 09-30 wins for 10-01 (source manuell, date 09-30); 09-29 still returns the ECB rate 1.1251.

### 5.3 Manual rate parsing and formatting

**`domain.ParseRate(s)`**:
1. Remove ASCII spaces and NBSP (U+00A0).
2. `splitNumber(s, dotThousands=true)`:
   - Optional leading `-`/`+`. Only digits, `.` and `,` are allowed.
   - If both `.` and `,` occur, the last one is the decimal separator; the other is the thousands separator and must not repeat on the decimal side.
   - A repeated single separator kind means thousands separators.
   - A single `.` followed by exactly 3 digits is a thousands separator, unless the integer part is all zeros (`"0.856"` = 0.856).
   - Groups after the first must have 3 digits; the first group has 1–3.
3. Reject if negative, or more than 12 integer or 12 fraction digits.
4. `strconv.ParseFloat(intPart + "." + frac + "0", 64)`; the result must be > 0 and not Inf.

Examples: `"38,02"`→38.02, `"20.274,71"`→20274.71, `"0.856"`→0.856, `"17.000"`→17000, `"17,000.5"`→17000.5, `"1.085"`→1085 (!), `"0"`/`"abc"` rejected.

**`domain.FormatRate(rate)`**: `strconv.FormatFloat(rate, 'f', -1, 64)` with the first `.` replaced by `,`; returns `""` if rate ≤ 0. Shortest round-trip digits, **never an exponent**, no thousands separators: 17000.5 gives `17000,5`; 1 gives `1`.

### 5.4 Converting amounts (rounding)

```go
func ToEURCents(minor int64, currency string, rate float64) int64 {
    if rate <= 0 || math.IsNaN(rate) || math.IsInf(rate, 0) { return 0 }
    scale := math.Pow10(CurrencyDecimals(currency))
    eur := float64(minor) / scale / rate * 100           // this exact operation order
    return int64(math.Round(eur))                        // half away from zero
}
// CurrencyDecimals: 0 for JPY KRW ISK HUF CLP VND XAF XOF PYG UGX IDR; 3 for KWD BHD OMR JOD TND LYD IQD; else 2
```

Examples: 10000 USD minor at 1.25 gives 8000; at 1.1 gives 9091; at 1.3 gives 7692. 9000 USD minor at 1.125 gives 8000.

---

## 6. YNAB

### 6.1 Model and what is synced

- Each person with their own YNAB token gets **their own share** of every expense, written as an outflow transaction in a clearing account they choose (by convention named "Geteilt").
- Not synced: reimbursements (handled as bank transfers in YNAB), deleted expenses, expenses where the person's share is 0, and future-dated expenses.
- Result: the balance of "Geteilt" equals the person's app balance.
- **`PostingFor(e, pid)`**: none if `e.Deleted() || e.IsReimbursement || e.ShareOf(pid) <= 0`. Otherwise:

  ```go
  Posting{ExpenseID: e.ID, Date: e.Date, AmountCents: share,
          Payee: truncate(e.Title, 200), Memo: Memo(e), CategoryID: e.CategoryID}
  ```

- **Memo** (German; the marker is always at the end):

  ```go
  total := "Gesamt " + domain.FormatCents(e.AmountCents)                 // "Gesamt 84,00 €" (plain space before €)
  if e.IsForeign() { total += " (" + domain.FormatMoney(e.OriginalAmountMinor, e.OriginalCurrency) + ")" } // "(90,00 USD)"
  suffix := " · " + "zipfelkasse #" + strconv.FormatInt(e.ID, 10)        // "·" = U+00B7
  head := total + " · bezahlt von " + e.PaidByName
  return truncate(head, 500 - runeLen(suffix)) + suffix
  ```

  Example: `Gesamt 84,00 € · bezahlt von Ben · zipfelkasse #12`; foreign: `Gesamt 80,00 € (90,00 USD) · bezahlt von Cleo · zipfelkasse #7`. `FormatCents` uses `.` as thousands separator: `1.234,56 €`.
- `truncate(s, n)` works in runes: if it fits, `s`; if `n <= 1`, the first `max(n,0)` runes; else the first `n-1` runes + `"…"`.
- Marker regexp: `zipfelkasse #(\d+)\s*$` (RE2; `$` = end of text). `markerID` returns the int64 id. `"zipfelkasse #12 und mehr"` does not match.
- Amount: `milliunits = -AmountCents * 10` (outflow is negative; 4200 cents gives -42000).
- Category: `ynab_category_map[pid][e.CategoryID]`, or `""` (uncategorized).
  - Create sends `category_id` only if mapped.
  - PATCH sends `category_id` only if mapped, so a category set by hand in YNAB survives app edits.
  - `cleared`/`approved` are set only on create (`"cleared"`, `true`) and never touched afterwards.

### 6.2 Selection (shared with the export `/export/ynab.ofx|csv`)

```go
func NewSelection(ctx, st, cfg, today) (Selection, error) {
    sel := Selection{Today: today}
    if cfg.StartDate.IsZero() || cfg.AccountID == "" { return sel, nil }   // all past expenses
    sel.Start, sel.ConnectedAt = cfg.StartDate, cfg.ConnectedAt
    if sel.ConnectedAt.IsZero() { sel.ConnectedAt = st.EnsureYNABConnectedAt(pid) }  // sets connected_at = now if NULL
    for r in st.ListYNABSync(pid) { if r.TxnID != "" || r.Hash == "pending" { sel.InYNAB[r.ExpenseID] = true } }
    return sel, nil
}
func (sel Selection) Includes(e, p) bool {
    if p.Date.After(sel.Today) { return false }
    return sel.Start.IsZero() || !p.Date.Before(sel.Start) ||
        (!sel.ConnectedAt.IsZero() && !e.CreatedAt.Before(sel.ConnectedAt)) || sel.InYNAB[e.ID]
}
// Postings: PostingFor + Includes, sorted by (Date, ExpenseID) ascending
// Today(now, loc) = min(DateOf(now.In(loc)), DateOf(now.UTC()))   — YNAB rejects future dates
```

- An expense is included if it is dated on/after the start date, **or** was entered after the connection was set up (even if backdated), **or** is already in YNAB.
- Moving an expense's date (or the start date) later keeps already-synced transactions. They are removed only when the expense is deleted or the share drops to 0.

### 6.3 Stored state

**`ynab_config`** (one row per person; migration 001 plus columns added by migration 5):

| Column | Meaning |
|---|---|
| `participant_id` PK | person |
| `token` | YNAB personal access token, **plaintext**; `""` = disconnected. Never rendered or logged; errors are redacted with `strings.ReplaceAll(msg, token, "•••")`. |
| `budget_id` | the plan ID (named `PlanID` in code) |
| `account_id` | clearing account |
| `start_date` | TEXT date or NULL |
| `enabled` | 1 when the token is non-empty |
| `updated_at` | |
| `connected_at` | when plan/account were chosen; reset to now on every plan/account change |
| `last_run`, `last_sync` | |
| `summary` | `"%d neu · %d geändert · %d gelöscht"` + `" · %d fehlgeschlagen"` if failed > 0 |
| `error` | German, shown on the page |
| `token_invalid` | 0/1 |
| `retry_at` | RFC3339Nano UTC or NULL |
| `backoff_seconds` | int |

`Ready() = Enabled && Token != "" && PlanID != "" && AccountID != "" && !StartDate.IsZero()`.

**`ynab_category_map(participant_id, category_id, ynab_category_id)`**, PK `(participant_id, category_id)`. `SetYNABCategoryMap` replaces the whole map:
- It deletes all rows, then inserts the non-empty values.
- An unknown app category gives `"Unbekannte Kategorie."`.
- An activity entry is written only if something changed: `YNAB: Kategorie-Zuordnung geändert (<parts>)`.
  - Parts are `"<AppCat> → <YnabName>"`, plus `" (vorher <OldName>)"` if there was an old mapping, joined with `", "`.
  - Order: `categories ORDER BY position, name COLLATE NOCASE, id`.
  - An empty mapping is shown as `unkategorisiert`; an unknown YNAB id as `(nicht mehr vorhanden)`.

**`ynab_sync(expense_id, participant_id, ynab_txn_id, synced_hash, synced_at, last_error)`**, PK `(expense_id, participant_id)`, index on `participant_id`. `synced_hash` values:

| Value | Meaning |
|---|---|
| 32-hex fingerprint | the last state transferred to YNAB |
| `"error:"+hash` | transferring this state failed; retried only if the expense changes, in a full sync, or via "Jetzt synchronisieren" |
| `"error:delete"` | DELETE failed; retried only in a full sync |
| `"pending"` | create in progress or outcome unknown; the next run searches the account by memo marker |
| `"retarget"` (`store.YNABHashRetarget`) | plan/account changed; `txn_id` was cleared |
| `""` | unknown; forces create (no txn) or PATCH (with txn) |

Fingerprint:

```go
h := sha256.New()
fmt.Fprintf(h, "%s\x00%s\x00%d\x00%s\x00%s\x00%s", "v1", w.Date.Format("2006-01-02"), w.milliunits(), w.Payee, w.Memo, w.category)
return hex.EncodeToString(h.Sum(nil)[:16])   // 32 lowercase hex chars
```

**PORT**: must be byte-identical, or every row looks changed and the first Crystal run PATCHes everything.

**Status** is kept in `ynab_config` since migration 5; before that it lived in settings keys `ynab.status.<id>` (JSON) and `ynab.connected.<id>`. The migration moves them, converts backoff from nanoseconds to seconds, treats unreadable JSON as "no status" and deletes the old keys. It is idempotent: it checks columns via `pragma_table_info`.

**Store write paths:**
- `SetYNABToken(pid, token, reachable)` runs in one transaction:
  1. `INSERT … ON CONFLICT DO UPDATE SET token, enabled = (token != ""), updated_at, token_invalid = 0, error = '', retry_at = NULL, backoff_seconds = 0`. LastRun, LastSync and Summary stay.
  2. If the token is non-empty, an old plan exists, and `reachable(oldPlan)` is false, reset the target to empty plan/account (same as `setYNABTarget`; keeps the start date).
  3. Activity: `YNAB-Verbindung getrennt` / `YNAB-Token ersetzt (Plan und Konto zurückgesetzt)` / `YNAB-Token ersetzt` / `YNAB verbunden (Token gesetzt)`.

  Disconnect keeps plan, account, mapping and sync rows so that reconnecting does not create duplicates. Note: disconnecting without an existing row **inserts** a row with an empty token and `enabled = 0`.
- `SetYNABTarget(pid, {PlanID, AccountID, PlanName, AccountName, Start})`:
  - No config row gives `ErrNotFound`.
  - If plan or account changed:
    - every sync row of the person is reset (`ynab_txn_id = ''`, `synced_hash = 'retarget'`, `synced_at = NULL`, `last_error = ''`)
    - `connected_at` is set to now
    - activity: `YNAB: Konto „<AccountName or ID>“ im Plan „<PlanName or ID>“ gewählt, Startdatum <dd.mm.yyyy>`
  - Else if only the start date changed: activity `YNAB: Startdatum <old or "–"> → <new>`.
  - Otherwise no activity is logged.
- `EnsureYNABConnectedAt`: `UPDATE … SET connected_at = coalesce(connected_at, now) … RETURNING connected_at`.
- `PutYNABSync(rows…)` upserts all fields (`synced_at` RFC3339 or NULL). `DeleteYNABSync(pid, ids…)`.
- `YNABSyncSummary(pid)`:
  - `synced` = count of rows with `ynab_txn_id != ''`.
  - `problems` = rows with `last_error != ''` joined with expenses, `ORDER BY e.date DESC, e.id DESC`.

### 6.4 Sync algorithm (per person, under `syncMu`)

`syncPerson(ctx, pid, full)`:
1. Re-read the config. If it is not Ready, return `errNotReady` (`"YNAB ist noch nicht fertig eingerichtet (Token, Plan, Konto und Startdatum)."`).
2. Otherwise call `syncOne`.

`syncOne(cfg, full)` maintains the status:

```go
st := loadStatus(pid)                           // zero if no row
now := s.now()
if st.TokenInvalid   { return errTokenInvalid }  // no status write, no requests
if now.Before(st.RetryAt) { return backoffError{st.RetryAt} }  // ditto
st.LastRun = now
res, err := s.syncParticipant(ctx, cfg, full)
if err != nil {
    switch code := statusOf(err); {
    case code == 401: st.TokenInvalid = true; st.Error = "Der YNAB-Token ist ungültig oder abgelaufen. Bitte einen neuen Token eintragen."
    case code == 429:
        st.Backoff = min(max(2*st.Backoff, 5*time.Minute), time.Hour)
        st.RetryAt = now.Add(max(st.Backoff, ae.RetryAfter))
        st.Error = "Das YNAB-Anfragelimit ist erreicht. Nächster Versuch um " + st.RetryAt.In(loc).Format("15:04") + " Uhr."
    case code == 404: st.Error = "Plan oder Konto gibt es in YNAB nicht (mehr). Bitte Plan und Konto neu wählen."
    case uncertain(err): st.RetryAt = now.Add(5*time.Minute); st.Error = redact(err.Error(), cfg.Token)
    default: st.Error = redact(err.Error(), cfg.Token)
    }
} else {
    st.Error, st.Backoff, st.RetryAt = "", 0, time.Time{}
    st.LastSync, st.Summary = now, res.String()
}
SetYNABStatus(pid, st)   // its error is returned only if there was no sync error
```

`syncParticipant(cfg, full)`:

```go
wants := desired(cfg)            // map expenseID → want{Posting, category, hash}
// desired: NewSelection(today=Today(now,loc)); ListExpenses(ParticipantID: pid) (non-deleted, paid or involved);
//          Postings; category = catMap[p.CategoryID] if CategoryID != 0; hash = hashOf(w)
rows := ListYNABSync(pid) as map
pending := ids where row.TxnID == "" && (row.Hash == "pending" || (row.Hash == "retarget" && wanted))
c := client(token)               // c.targetOK caches confirmTarget for this run
if len(pending) > 0 { resolvePending(...) }   // one GET request
for id, w := range wants {
    r, ok := rows[id]; failedSame := r.Hash == "error:"+w.hash
    switch {
    case !full && failedSame:          // skip (failed and unchanged)
    case !ok || r.TxnID == "":          creates += w
    case r.Hash != w.hash:              w.txnID = r.TxnID; updates += w
    }
}
for id, r := range rows where id not in wants {
    switch {
    case r.TxnID == "":                     forget += id      // also drops "retarget" rows that are no longer wanted
    case !full && r.Hash == "error:delete": // skip
    default:                                deletes += r      // even if the last PATCH failed
    }
}
sort all by ExpenseID
DeleteYNABSync(forget...); create(creates); update(updates); remove(deletes)   // each aborts the run on error
```

`resolvePending`:
- `since` = min(cfg.StartDate, the date of every pending expense). For a pending expense that is no longer wanted, the date comes from `GetExpense(id)` (deleted expenses included); an error aborts the run.
- `GET …/accounts/{acc}/transactions?since_date=since`.
- For non-deleted txns, `markerID(memo)` maps expense id to txn id.
- Each pending row gets `TxnID = found[id]` (may be `""`) and `Hash = ""`, then `PutYNABSync`.
- The normal diff then produces a PATCH (if found and wanted), a create (if not found), a DELETE (found but no longer wanted) or a forget.

`create(ws)`, in chunks of 100:
1. `markPending(chunk)`: rows with `Hash = "pending"`, empty TxnID, `last_error = ''`.
2. `POST` all of them:
   - **OK**: `applyCreated` maps memo marker to txn id.
     - Found: `TxnID`, `Hash = w.hash`, `SyncedAt = now`, Created++.
     - Missing from the response: `Hash = "pending"`, `LastError = "YNAB hat das Anlegen nicht bestätigt."`, Failed++, `Again = true`.
   - **uncertain** (network / ≥500): return the error; the rows stay "pending".
   - **runLevel** (0/401/403/404/429): `unmarkPending` (Hash `""`; a failure here is only logged as `Warn "ynab: undo pending mark"`), then return the error.
   - **other 4xx** (400/409/422…): `createEach(chunk)`.

`createEach(ws)`:
- For each `i`:
  - If `i >= 20`: `Again = true`, `markPending(ws[i:], "")`, return.
  - Single `POST`:
    - OK: `succeeded = true`, `applyCreated`.
    - uncertain: `unmarkPending(ws[i+1:])`, return the error (the current row stays pending).
    - runLevel: `unmarkPending(ws[i:])`, return the error.
    - else: Failed++, row `{TxnID:"", Hash:"error:"+hash, LastError: redact(err)}`.
      - If `!succeeded && i+1 >= 3`: `failAll(ws[i+1:], keepTxn=false, err)` marks the rest failed **without requests**, then return.

`update(ws)`, in chunks of 100:
- PATCH all of them:
  - **OK**: `applyUpdated`.
    - Not in the response: failed row (txn kept) with `"YNAB hat die Änderung nicht bestätigt."`, Failed++.
    - Response says `deleted:true`: row reset to `{TxnID:"", Hash:""}` and `Again = true` (it is recreated next run; the app is authoritative).
    - Otherwise TxnID, hash, SyncedAt, Updated++.
  - **runLevel except 404**: return the error.
  - **else** (4xx including 404 = a txn is missing): `updateEach`.

`updateEach(ws)`:
- If `i >= 20`: `Again = true`, return.
- Single PATCH:
  - OK: `succeeded = true`, `applyUpdated`.
  - 404: `confirmTarget` (error aborts the run), `succeeded = true`, `Again = true`, row reset `{TxnID:"", Hash:""}` so it is recreated next run.
  - runLevel: return the error.
  - else: Failed++, failed row (txn kept). If `!succeeded && i+1 >= 3`: `failAll(rest, keepTxn=true)`.

`remove(rows)`:
- If `i >= 40`: `Again = true`, return.
- DELETE:
  - 404: `confirmTarget()` (error aborts the run), then treat as deleted.
  - OK: Deleted++, `DeleteYNABSync`.
  - runLevel: return the error.
  - else: Failed++, `Hash = "error:delete"`, `LastError = redact(err)` (txn kept).

`confirmTarget(c, cfg)`:
- Runs once per run: `GET /plans/{plan}/accounts/{acc}`.
- If the account is `deleted`, it becomes `APIError{404, Detail:"Konto gelöscht"}`.
- An error aborts the run, so the status gets the "Plan oder Konto…" message and sync rows are left untouched (`TestSyncPlanNotAccessible`).

**Idempotency:**
- A run with no differences makes **zero** requests (`TestSyncCreateUpdateDelete` "second run").
- Duplicates on a lost POST response are prevented by the "pending" state plus the memo-marker search.
- Switching account and back finds the existing txns in the old account again (`retarget`).
- No import_id is sent.

**Delete handling:**
- An expense that is deleted or loses the person's share causes a DELETE in YNAB on the next run; a failed PATCH does not delay this.
- A transaction deleted by hand in YNAB is recreated.
- Disconnecting the token does **not** delete anything in YNAB.

### 6.5 Logging / redaction

- `redact(msg, token)` replaces every occurrence of the token with `•••`. It is applied to the status error, `last_error` and log lines.
- `backoffError.Error()` = `"YNAB paused until HH:MM (rate limit or outage)"` (log only, formatted in the time's own zone).

---

## 7. Templates: functions, variables, raw HTML

Template engine: Go `html/template` with auto-escaping. Each page defines `{{define "content"}}`; the shared layout (`internal/web/templates`) renders `View{Page, Me, GroupName, Flash, Path}`. **No `template.HTML` / raw HTML is used in these three templates.** All `„“`, `–`, `→`, `…`, `·` are literal UTF-8. Test: `>Lebensmittel &amp; Drogerie<` shows `&` is escaped. In `kurse.html` the "Ausgabe" link is `href="/ausgaben/{{.ID}}"`.

Functions used (from `web.Renderer.Funcs`):

| func | Go impl | used in |
|---|---|---|
| `date` | `domain.FormatDate`, gives `dd.mm.yyyy` (`""` for zero) | kurse, wiederkehrend, wiederkehrend_neu, ynab |
| `isoDate` | `t.Format("2006-01-02")`, `""` for zero | kurse (hidden `datum`), ynab (`start` value) |
| `eur` | `domain.FormatCents`, gives `1.234,56 €` | wiederkehrend, wiederkehrend_neu, ynab |
| `money` | `domain.FormatMoney(minor, cur)`, gives `12,34 USD` (EUR gives `€`) | wiederkehrend, wiederkehrend_neu |
| `dateTime` | `t.In(Config.Location).Format("02.01.2006, 15:04")`, `""` for zero | ynab (LastSync, RetryAt) |
| `signClass` | `>0` gives `positive`, `<0` gives `negative`, else `""` | ynab (balance) |
| built-ins | `with`, `if`, `else if`, `range`, `and`, `not`, `eq`, `$d := .Data`, `$sel := .Selected`, whitespace trim `{{-` | all |

Method calls inside templates:
- `.Frequency.Label`, `.Template.Title/AmountCents/OriginalCurrency/OriginalAmountMinor`, `.StartDate`, `.NextDate`, `.Active`, `.ID`, `.PaidByName` (wiederkehrend)
- `.IsForeign`, `.SplitMode.Label`, `.CategoryName`, `.Notes`, `.Title`, `.PaidByName`, `.Date`, `.AmountCents` on `*store.Expense`; options `.Value/.Label/.Next/.Note/.Checked`; `.Data.Existing` (int64 truthiness) (wiederkehrend_neu)
- `$d.Status.LastSync.IsZero`, `$d.RetryAt.IsZero` (ynab)
- `{{with .Data.Stats}}`: a struct is always truthy, so the inner `{{if .Count}}` decides (kurse)

### kurse.html (`.Data` = pageData)

- Header card: `Wechselkurse` plus an explanatory paragraph (test checks for "Vorrang").
- "Manuelle Kurse" card:
  - Table columns `Währung | Gültig ab | 1 € = | (sr-only Aktion)`; rows show `{{.Rate}} {{.Currency}}` (e.g. `38,02 THB`).
  - Each row has a delete form posting to `/einstellungen/kurse/loeschen` with hidden `waehrung` and `datum` (`isoDate`) and button `Löschen<span class="sr-only"> (CUR ab dd.mm.yyyy)</span>`.
  - With no rates: `Noch keine manuellen Kurse.`
- Add form posting to `/einstellungen/kurse`:
  - `waehrung`: `id=kurs-waehrung`, required, `maxlength=3`, `pattern="[A-Za-z]{3}"`, `list=kurs-waehrungen` (datalist of `.Data.Currencies`)
  - `datum`: `type=date`, value `.Data.Form.Date`
  - `kurs`: `inputmode=decimal`, placeholder `1,0850`
  - help text `Für 1 € gibt es 1,08 US-Dollar → 1,08.`; button `Kurs speichern`
- "EZB-Referenzkurse" card:
  - If `Count`: `Zwischengespeichert: N Kurse für M Währungen vom dd.mm.yyyy bis dd.mm.yyyy.`; else `Noch keine EZB-Kurse zwischengespeichert – sie werden bei Bedarf automatisch geladen.`. Always followed by ` Neue Kurse werden an Bankarbeitstagen nach 16:30 Uhr automatisch abgerufen.`
  - Button form posting to `/einstellungen/kurse/aktualisieren`: `EZB-Kurse jetzt aktualisieren`.
  - Latest table: `Währung | Stand | 1 € =`.
- "Zuletzt verwendet" card, only if `Used` is non-empty: `Ausgabe (link) | Datum | 1 € = | Quelle`.

### wiederkehrend.html

- Header text explains rules.
- Table columns `Ausgabe | Betrag | Nächster Termin | (Aktionen)`.
  - Cell 1: `<strong>Title</strong>` and `<span class="muted">{Label} seit {date StartDate}{ · zahlt {PaidByName}}</span>`.
  - Amount: if `OriginalCurrency == "EUR"`, `eur AmountCents`; else `money OriginalAmountMinor OriginalCurrency`.
  - Next: `date NextDate` if active, else `<span class="muted">pausiert</span>`.
- Actions:
  - `Pausieren` or `Fortsetzen` form
  - `Vorlage aktualisieren` form with `title="Betrag, Aufteilung usw. der zuletzt eingetragenen Ausgabe dieser Wiederholung übernehmen"`
  - `<details><summary>Löschen…</summary>` containing a form posting to `/loeschen`, help text `Bereits eingetragene Ausgaben bleiben erhalten.` and button `Wiederholung löschen`
- Empty list: `Noch keine wiederkehrenden Ausgaben.`
- Payer names come from `ListParticipants(includeArchived=true)`.

### wiederkehrend_neu.html

- With an expense:
  - Summary table: Titel, Betrag, Bezahlt von, Kategorie (if set), Aufteilung, Notiz (if set), Erster Termin.
  - Foreign amount: `money … (eur …; künftig zum Kurs des jeweiligen Tages)`.
- Without an expense: `Öffne zuerst die Ausgabe, die sich wiederholen soll, und wähle dort „Wiederkehrend machen“.` and link `Zu den Ausgaben` to `/`.
- If already recurring (`.Data.Existing` ≠ 0): `Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe.` and link to the list.
- Otherwise the form posting to `/einstellungen/wiederkehrend/neu`:
  - hidden `ausgabe`
  - fieldset legend `Wie oft?`
  - radios `name="haeufigkeit" value="weekly|monthly|yearly" required [checked]`, labelled `{Label} <span class="muted">– nächster Termin {date Next}{; Note}</span>`
  - buttons `Wiederkehrend machen` and `Abbrechen` (link to `/ausgaben/{id}`)

### ynab.html

- Explanation card with the 4-step `<ol>`.
- "Verbindung" card:
  - If TokenSet and TokenInvalid: alert `Der gespeicherte Token ist ungültig oder abgelaufen. Bitte einen neuen eintragen.`; else `Token: <strong>gesetzt</strong>`.
  - Form posting to `/einstellungen/ynab/token` with `input#token name=token type=password maxlength=200 required`. Label and button read `Token ersetzen` when a token is set; otherwise the label is `Token` and the button `Verbinden`.
  - If TokenSet: form posting to `/trennen` with button `Verbindung trennen`.
- "Plan und Konto" card (only if TokenSet and not TokenInvalid):
  - APIError alert.
  - Currency alert: `Achtung: Dieser Plan rechnet in {CUR}. Zipfelkasse überträgt Euro-Beträge.`
  - If Plans:
    - `select#ziel name=ziel required` with `<option value="">Bitte wählen …</option>` and `<optgroup label="{PlanName}">` with `<option value="plan|acc"[ selected]>Name</option>`
    - `input#start name=start type=date value={isoDate StartDate}`
    - button `Speichern` and link `Listen von YNAB neu laden` (`/einstellungen/ynab?neu=1`)
  - Else if there is no APIError: `In deinem YNAB gibt es kein offenes Konto im Budget. Lege zuerst das Konto „Geteilt“ an und lade die <a href="/einstellungen/ynab?neu=1">Liste neu</a>.`
- "Kategorien" card (if HasTarget and Categories):
  - If Groups: form posting to `/einstellungen/ynab/kategorien`, table `In Zipfelkasse | In YNAB`.
    - Per row: label `kat-{ID}` with `(archiviert)` if archived; `select#kat-{ID} name=kat-{ID}`.
    - Options: `<option value="">– unkategorisiert –</option>`; if Missing, `<option value="{sel}" selected>Nicht mehr vorhanden (in YNAB gelöscht oder versteckt)</option>`; then the groups/options, with `selected` where `eq .ID $sel`.
    - Button `Zuordnung speichern`.
  - Else: `Die Kategorien aus YNAB konnten nicht geladen werden.`
- "Status" card (if TokenSet):
  - `Dein Saldo in Zipfelkasse: <strong class="amount {signClass}">{eur Balance}</strong> <span class="muted">– so viel sollte auch „Geteilt“ in YNAB zeigen.</span>`
  - If Ready:
    - `Synchronisierte Buchungen: <strong>N</strong>` (test asserts this exact substring)
    - `Letzter Abgleich: {dateTime LastSync} <span class="muted">(Summary)</span>`, or `Noch nicht synchronisiert.`
    - Error alert.
    - `Nächster Versuch ab {dateTime RetryAt}.`
  - Else: `Sobald Plan, Konto und Startdatum gewählt sind, synchronisiert Zipfelkasse automatisch: kurz nach jeder Änderung und stündlich.`
  - Problems table `Datum | Ausgabe (link /ausgaben/{id}) | Fehler`.
  - If Ready: footer form posting to `/einstellungen/ynab/sync` with button `Jetzt synchronisieren`.

---

## 8. Test inventory (one line each)

### internal/fx/fx_test.go

| Test | Checks |
|---|---|
| TestRateEURAndInvalid | `" eur "` gives rate 1/"fest"/requested date; `""`, `US`, `US1`, `EURO` give ValidationError; no fetch |
| TestRateDailyAndCache | USD 10-01 from the daily file (1 fetch, User-Agent `zipfelkasse/…`); today before 16:30 gives yesterday from cache; a future date gives the latest rate; cache reused |
| TestRateOlderUses90d | Sunday 09-27 gives Friday 09-25 (176.5) via the 90d file; other days then come from cache |
| TestRateDailyEscalatesTo90d | at 17:00, a daily file holding only 10-02 means a request for 10-01 escalates to 90d; today's rate comes from the daily file; 2 fetches total |
| TestRateHistZipLoadedOnce | 2024 date loads hist.zip once; weekend lookback; RUB "um den 03.01.2024 keinen EZB-Kurs"; XYZ unknown; after a restart (same DB) no re-fetch, and pre-1999 gives no rate |
| TestRateUnknownCurrency | XYZ gives the "keinen EZB-Kurs – bitte Kurs von Hand eintragen." message; the second call within cooldown makes no new fetch |
| TestRateManualPrecedence | manual USD 1.2 (09-30) wins on 10-01; manual XYZ works; no fetch; 09-29 uses ECB 1.1251 |
| TestRateFetchErrors | network error gives FetchError "nicht geladen werden"; no retry within 1 min; HTTP 500 after 5 min; broken XML gives FetchError; 3 daily fetches |
| TestFetchSingleflight | 5 concurrent Rate calls cause a single download |
| TestFetchContextCancel | caller ctx timeout gives `context.DeadlineExceeded` while the download hangs |
| TestRefresh | empty cache uses the 90d file; a current cache uses the daily file; force bypasses the cooldown (daily fetched twice) |
| TestCalendar | Easter dates, business days, lastBusinessDay, nextPublish incl. DST (§1.2) |
| TestParseFiles | 90d XML gives 18 rates, From 07-06 / To 10-01, 3 currencies; CSV counts USD 6 / CYP 1 / RUB 2 / BGN 4; bad header and broken zip give errors; parseECBRate table |
| TestAPIRate | `/api/kurs` table (200 exact JSON; DD.MM.YYYY date; default date; EUR `rate:1`; 400 missing/invalid currency or date; 422 XYZ); network error gives 502 |
| TestSettingsPage | GET page texts; POST THB `38,02` and IDR `20.274,71`; VND `0.856`/`17.000`/`17,000.5`; four invalid inputs give 422 + `alert-destructive`; list shows `38,02 THB`; activity texts; delete gives 303 then 404; refresh gives 303 (90d) and the list shows `1,1298 USD` and `bis 01.10.2026`; refresh error gives 502 |
| TestRunWaitsForDownloads | `Run` loads immediately on an empty cache; after cancel, Run returns only once no download is running |

### internal/recurring/recurring_test.go

(Fake clock 2026-10-02 12:00 Europe/Berlin; fakeFX: `err` or ValidationError when the currency is missing.)

| Test | Checks |
|---|---|
| TestMaterializeMonthEnd | anchor 01-31 monthly: nothing on 02-27; on 05-15 three created (02-28, 03-31, 04-30), next 05-31; activity `expense_created` by system |
| TestMaterializeLeapYear | yearly 2024-02-29 gives 2025/26/27-02-28 and 2028-02-29 |
| TestMaterializeWeeklyCatchUp | weekly from 09-01: 4 instances up to 10-02, next 10-06 |
| TestMaterializeIdempotentAfterCrash | an existing instance is not duplicated; a restart creates 0; a reset next_date creates no duplicates and re-advances to 04-15 |
| TestMaterializePaused | paused creates nothing; resume on 05-01 skips missed occurrences; 05-10 created |
| TestMaterializeForeignCurrency | USD instance uses the day's rate 1.25 (8000 cents, source ezb); FX error means not created, next_date kept, error returned; ValidationError means the template rate (9091 / 1.1) is used |
| TestMaterializeForeignManualTemplateRate | manual template rate 1.3 (7692 cents) is not carried over; next instance uses 1.25 / ezb |
| TestMaterializeForeignFixedAmounts | SplitAmount USD weights 6000/4000 stay; EUR shares become 4800/3200 |
| TestHandlers | list empty; new without/with a bad expense (404); preview texts (`nächster Termin 30.09.2026`, `1 verpasster Termin wird sofort eingetragen`, `4 verpasste Termine`); invalid freq gives 422 "Häufigkeit"; create gives 303 + immediate instance 09-30; duplicate gives 422; list texts; pause/resume/template activity texts; unknown id gives 404; delete gives 303 then 404; expenses remain; activity `recurring_deleted` |
| TestMaterializeCapPerRun | weekly from 2000-01-03: 400 per run, next = Occurrence(401); 801 instances after two runs |
| TestMaterializeRuleChangedMeanwhile | a pause / delete / pause+resume during the catch-up stops the rule without error and does not override the change |
| TestFlashCountsOnlyTheRule | flash `„Miete“ wiederholt sich jetzt monatlich. 1 Ausgabe nachgetragen.` and `Fortgesetzt. 1 Ausgabe angelegt.` count only that rule; other due rules are untouched |
| TestFreqOptionNote | Note() table (§4.6) plus the "mehr als 1000" preview for anchor 2000-01-03 |
| TestMaterializeSkipsExistingExpenses | a same title+amount+payer expense is skipped; a different amount/title/payer or a deleted duplicate is not; next 05-31 |
| TestMaterializeSkipsExistingForeignExpenses | foreign duplicates are matched by original amount + currency; the FX rate is requested only for created ones |
| TestRecreateRuleSkipsExistingOccurrences | deleting and recreating the rule: preview "5 verpasste … 3 bereits … übersprungen"; no duplicates created |

### internal/ynab/ynab_test.go

(Env: TZ UTC, now 2026-10-02 12:00 UTC, persons Anna/Ben/Cleo, categories Lebensmittel(food)/Restaurant; the fake from §2.4; baseURL `https://api.test/v1`.)

| Test | Checks |
|---|---|
| TestSyncCreateUpdateDelete | POST with exact fields (amount -42000, memo, category c-food, cleared/approved); idempotent full run makes 0 requests; edit gives PATCH; delete gives DELETE; summary `0 neu · 0 geändert · 0 gelöscht` |
| TestSyncBundlesRequests | 5 creates in one POST; renaming the payer gives one PATCH for all 5 |
| TestSyncUncategorizedKeepsManualCategory | unmapped: no category_id; a manual YNAB category survives PATCH; once mapped, PATCH sets it |
| TestSyncFilters | start date / reimbursement / no share / deleted / future filters; start earlier adds; start later keeps; due date creates; share 0 gives DELETE |
| TestSyncForeignCurrencyMemo | memo `Gesamt 80,00 € (90,00 USD) · bezahlt von Cleo · zipfelkasse #ID`, amount -40000 |
| TestSyncRateLimitBackoff | 429 gives RetryAt +5 min, Backoff 5 min, error "Anfragelimit", row unmarked; no requests during the pause; second 429 doubles to 10 min; success resets; SyncAll next ≈ 5 min (+≤1 s) |
| TestSyncUnauthorized | 401 gives TokenInvalid + error; later runs make 0 requests; page shows "ungültig oder abgelaufen"; a new token via form resets it |
| TestSyncLostResponseNoDuplicate | lost POST response leaves "pending"; next run does GET account txns, then PATCH; no duplicate |
| TestSyncRecreatesTransactionsDeletedInYNAB | PATCH returns deleted / 404 gives Again, then recreated next run |
| TestSyncRejectedTransaction | batch 400 then single POSTs (3 requests total); failed row; not retried in incremental runs; retried in full (2 POSTs); problems list |
| TestErrorsAreRedacted | 503 detail containing the token is stored as `•••` |
| TestTriggerNeverBlocks | 10000 Trigger calls in <2 s |
| TestRunSyncsAfterChange | Run with debounce 10 ms syncs after an expense hook |
| TestPostingFor | payee truncated to 200 runes; memo format; no share or reimbursement gives none; markerID end-anchored |
| TestSettingsPageFlow | full page flow: wrong token 422 "kennt diesen Token nicht"; token never in HTML; account options/filters; Depot gives 422; `01.09.2026` start accepted; category options (no RTA/Visa/hidden); unknown category 422; mapping saved/preselected; caching (request counts); sync now; error 503 shown redacted; disconnect; SyncAll next = 1 h |
| TestSettingsChangeAccountResetsSync | account change clears TxnIDs; next sync does GET new-account txns then POST |
| TestSyncTargetChangeBackNoDuplicates | switch A→B→A: back in A, one GET plus one PATCH (2 updated, 0 created/deleted); "Weg" stays in A; then idempotent |
| TestSyncBackdatedExpenseAfterConnect | an expense entered after connecting with a date before start is synced; after an account change, only start counts |
| TestSyncLostResponseBackdatedNoDuplicate | pending search uses the expense's own earlier date; deleted pending gives GET then DELETE |
| TestSyncKeepsExpenseMovedBeforeStart | moved before start gives PATCH, not DELETE; deleted only on deletion |
| TestSyncDeletesAfterFailedPatch | after a failed PATCH, deleting the expense gives an immediate DELETE |
| TestSaveTokenOfOtherYNABUser | same user's token keeps the target; another user's token resets plan/account; flash "neu wählen" |
| TestSyncPlanNotAccessible | 404 on the target means the run stops, error "Plan oder Konto", rows untouched; the correct token then gives 1 update + 1 delete |
| TestSyncFailedDeleteRetriedOnlyInFullSync | failed DELETE is skipped in incremental runs and retried in full |
| TestSyncNowLog | log contains "sync (now) failed" with `•••`, never the token; an invalid token is not logged again |
| TestSyncNowDoesNotBlock | POST /sync answers 303 + flash while YNAB hangs |
| TestSettingsChangeAccountDuringSync | an account change waits for the running sync; the row ends up pointing at the new account |
| TestSettingsNewTokenDuringSync | a new token saved during a sync stays valid (status reset not overwritten) |
| TestSettingsActivity | exact activity texts for token set/replace, account choose, start date change, category mapping, disconnect (§6.3) |

### internal/store (relevant tests)

| Test | Checks |
|---|---|
| fx_test TestFXRatesECBAndManual | window lookup; invalid rates skipped; manual and ECB side by side; manual upsert; validation table; list/latest/stats/currencies; delete manual (twice gives ErrNotFound; an ECB row is not deleted as manual) |
| fx_test TestRecentUsedFXRates | only foreign expenses are listed |
| fx_test TestMigrationSeparatesFXRateSources | migration 003 keeps both rows |
| recurring_test TestCreateRecurringFromExpense | invalid freq / unknown expense; rule fields (next 02-28); template zeroed date; original gets recurring_id; second rule gives validation error; activity; instance at anchor gives ErrRecurringExists; DueRecurring boundaries |
| recurring_test TestRecurringPauseResumeDelete | resume on Wednesday gives next Monday; resume on an occurrence day keeps it; SetRecurringNextDate optimistic lock; paused/deleted rule gives ErrRecurringChanged for CreateExpense and SetNextDate; delete keeps expenses (recurring_id → NULL) |
| recurring_test TestUpdateRecurringTemplateFromLatest | latest non-deleted instance becomes the template; none gives ErrNoInstance; unknown rule gives ErrNotFound |
| ynab_test TestYNABConfig | not-found / target without token; Ready; ListYNABConfigs excludes archived and disconnected; disconnect keeps plan |
| ynab_test TestYNABTargetChangeResetsSync | start-only change keeps rows; account change sets `retarget`, clears TxnID and synced_at |
| ynab_test TestYNABCategoryMapAndSummary | empty values ignored; unknown category gives validation error; summary counts/problems; DeleteYNABSync |
| ynab_test TestYNABConnectedAt | set on target, kept on start-only change, reset on account change; EnsureYNABConnectedAt |
| ynab_test TestYNABStatus | round-trip incl. nanoseconds; the target does not touch the status; new token/disconnect resets TokenInvalid/Error/RetryAt/Backoff only |
| ynab_test TestMigrationMovesYNABStateIntoConfig | migration 5 from settings JSON (incl. `.5+02:00` time, backoff nanoseconds, broken JSON) and is idempotent |
| main_test TestAppWiring | routes `/einstellungen/wiederkehrend`, `/kurse`, `/ynab`, `/api/kurs?waehrung=EUR` give 200; `/api/kurs?waehrung=` gives 400; `/einstellungen/wiederkehrend/neu` gives 200 |

---

## 9. Porting pitfalls (Go to Crystal)

1. **Month arithmetic**: in these packages Go **never** calls `AddDate` with months. Monthly and yearly recurrences use an explicit clamping function (`addMonthsClamped`) computed **from the anchor** with `n*months`.
   - Crystal `Time#shift(months: n)` also clamps (Jan 31 + 1 month = Feb 28/29), so `anchor.shift(months: n)` matches. Never chain from the previous occurrence: `shift(months:1)` repeatedly drifts 31 to 28 to 28.
   - Port the explicit algorithm anyway to stay independent of stdlib semantics.
   - If any *other* Go code relies on `AddDate(0,1,0)` normalisation (Jan 31 + 1 month = **Mar 3** in Go), Crystal's clamping would differ. In scope, only day shifts (`AddDate(0,0,±n)`) occur; they are identical on UTC dates.
2. **`time.Date` overflow normalisation**:
   - `daysIn` uses `time.Date(y, m+1, 0, …)` (day 0 = last day of the previous month) and `nextPublish` uses `t.Day()+1`. Go normalises day 32 or day 0 silently.
   - Crystal `Time.utc(y, m, 32)` raises `ArgumentError`. Use `Time.days_in_month(y, m)` and `date.shift(days: 1)` before rebuilding 16:30 in Europe/Berlin (`Time.local(y, m, d, 16, 30, location: berlin)`).
   - Check DST: `nextPublish("2026-03-28 10:00")` must give `"2026-03-30 16:30"`.
3. **Date-only values must be UTC midnight**, built from y/m/d *in the source zone* (`DateOf`). Crystal `Time#at_beginning_of_day` keeps the zone; port `DateOf` as `Time.utc(t.year, t.month, t.day)` after `t.in(loc)`.
   - Comparisons (`Before`/`After`/`Equal`) and map keys (`existing[d]`) rely on identical UTC midnight values. A Crystal `Hash(Time, Bool)` key includes the location, so normalise to UTC.
4. **Go `time.Parse(RFC3339)`** accepts fractional seconds and any offset. Writes use `RFC3339` (no fraction) except the YNAB status columns (`RFC3339Nano`, trailing zeros trimmed, e.g. `2026-09-01T10:00:00.123456789Z`).
   - The Go zero time formats as `0001-01-01T00:00:00Z` (in template_json).
   - Crystal: `Time::Format::RFC_3339` parses fractions and offsets; for output use `to_rfc3339(fraction_digits: 0)` for normal timestamps and nanosecond output without trailing zeros for status times.
5. **ParseDate** must try `YYYY-MM-DD`, then `DD.MM.YYYY`, then `D.M.YYYY`, all **strict**; the year range is 2000..2100. Go's `"2.1.2006"` layout also accepts two-digit day/month (`02.01.2026`), but `"02.01.2006"` requires exactly two digits. Crystal `Time.parse` with `%-d` vs `%d` behaves differently, so write a small regex-based parser.
6. **Float parsing of ECB rates**:
   - Go `ParseFloat` accepts `NaN`, `Inf`, `infinity`, exponents and hex floats; the app then rejects `!(f > 0) || f > 1e12`.
   - Crystal `String#to_f?` handles whitespace differently: it accepts leading/trailing whitespace by default, while Go needs the explicit `TrimSpace`, which is present. Keep `strip` and the same post-checks; `N/A` must be rejected.
   - For the 1e12 bound, NaN compares false in both languages.
7. **ParseRate (manual)** is a custom separator algorithm (§5.3). Port `splitNumber` exactly, including `"1.085"` = 1085, `"0.856"` = 0.856, `"17,000.5"` = 17000.5, NBSP stripping, and ≤12 digits per part. Afterwards it is `ParseFloat(int + "." + frac + "0")`.
8. **Float formatting**:
   - `FormatRate` = Go shortest `'f'` formatting with no exponent and no trailing `.0`: 1 gives `1`, 17000.5 gives `17000,5`.
   - Crystal `Float64#to_s` gives `1.0` and switches to exponent notation (`1.0e-5`, `1.0e+16`). Implement shortest round-trip digits without exponent and strip `.0`.
   - Same for JSON: `/api/kurs` must emit `"rate":1` for EUR (test asserts exact JSON). Crystal `1.0.to_json` gives `1.0`. Go's JSON uses `'e'` notation only for |x| < 1e-6 or ≥ 1e21.
   - Go JSON escapes `<`, `>`, `&` as `<` etc. and writes a trailing `\n` after `Encode`.
   - SQLite REAL round-trips exactly in both.
9. **Rounding**: `ToEURCents` uses `math.Round`, i.e. **half away from zero**. Crystal's `Float#round` defaults to `:ties_even` (banker's rounding); use `round(:ties_away)`.
   - Keep the exact float operation order `minor / 10^dec / rate * 100`; reordering changes results at .5 boundaries.
   - `math.Pow10` is exact for these small exponents.
10. **Hash fingerprint** (§6.3) must be byte-identical: `"v1\0YYYY-MM-DD\0<milliunits>\0payee\0memo\0category"`, sha256, first 16 bytes, lowercase hex. Otherwise the first Crystal run PATCHes every transaction (costs requests out of the 200/hour limit, but stays correct).
11. **Memo marker regex**: Go RE2 `zipfelkasse #(\d+)\s*$`, where `$` = end of text only. In PCRE (Crystal) `$` also matches before a final `\n`; use `\z` (`/zipfelkasse #(\d+)\s*\z/`).
    - `\d` must be ASCII. Write `[0-9]` (and `[ \t\n\f\r]*` instead of `\s*`) so the result does not depend on whether Crystal's PCRE2 options include UCP.
12. **Rune-based truncation**: Go `[]rune` length equals Crystal `String#size` (codepoints). `truncate` appends `"…"` (U+2026) after n-1 runes. The memo limit is 500 runes including the suffix; payee is limited to 200.
13. **Memo text characters**: `·` = U+00B7; plain space before `€` in `FormatCents`; `„“` = U+201E/U+201C in German messages; `–` = U+2013; `→` = U+2192; `•••` = three U+2022.
14. **Go `strings.TrimSpace`** trims Unicode whitespace. Crystal `String#strip` also strips Unicode whitespace, which is equivalent enough. The token check `ContainsAny(" \t\r\n")` and `len(token) > 200` count **bytes**, so use `bytesize`.
15. **`strings.Fields` title normalisation** in `ExpenseDatesLike` collapses all Unicode whitespace runs to single spaces. Crystal: `title.split.join(" ")` (`split` without arguments splits on whitespace).
16. **Concurrency model**:
    - Go goroutines + mutexes become Crystal fibers. One sync at a time (`syncMu`).
    - Per-file ECB download dedup with cooldown, where the request waits but can give up via ctx (Crystal has no ctx; use a timeout `select` on a channel).
    - Non-blocking `Trigger` = `Channel(Nil).new(1)` with `select … else`.
    - A debounce timer that only shortens the wait.
    - Background "sync now" fibers tracked per person and awaited on shutdown.
    - Crystal's single-threaded default scheduler makes many races moot, but blocking DB/HTTP calls must not hold a Mutex across fibers unexpectedly. `Mutex` in Crystal is fiber-aware.
17. **HTTP client differences**:
    - Go sends `Accept-Encoding: gzip` with transparent decompression, follows redirects and uses `HTTPS_PROXY` from the environment. Crystal `HTTP::Client` decompresses gzip but follows **no redirects** and has **no proxy support**.
    - Timeouts: Go's `Client.Timeout` covers the whole request (60 s ECB, 30 s YNAB). In Crystal set `connect_timeout`, `read_timeout` and `write_timeout` (no total timeout).
    - The ECB body limit of 32 MiB truncates silently in Go; the real files are small.
18. **YNAB JSON body** must omit `id`/`account_id`/`category_id`/`cleared`/`approved` exactly as described (§2.2), and always include `payee_name` and `memo` (even empty).
    - Parsing: `memo`, `payee_name` and `category_id` can be `null`; unknown fields are ignored.
    - `Retry-After` is honoured only as integer seconds.
19. **Error classification** (`uncertain` / `runLevel`) drives correctness (no duplicates). Port it exactly:
    - transport errors, read errors and unparseable 2xx bodies are "unclear"
    - status ≥ 500 is uncertain
    - 401/403/404/429 and non-API errors abort the run
    - other 4xx are per-transaction
20. **Status time comparisons** use the injected clock (`s.now`) while timers use real time. Keep that split, or inject both consistently for E2E.
21. **Store hook**: YNAB must be triggered after every committed expense create/update/delete (including recurring-generated and MCP-created ones). Without the hook, only the hourly full sync picks changes up.
22. **template_json compatibility** (§4.1): read and write Go's format exactly. Missing fields default to zero; `parts` entries are `{"participant_id","weight"}`.
23. **SQLite specifics**:
    - `ON CONFLICT … DO UPDATE` upserts.
    - `UPDATE … RETURNING` (needs SQLite ≥ 3.35).
    - Partial unique index `expenses_recurring_date`: a violation (SQLite extended codes `SQLITE_CONSTRAINT_UNIQUE`/`PRIMARYKEY`) must map to `ErrRecurringExists`, which means a skip, not an error.
    - `WITHOUT ROWID` tables; `PRAGMA user_version` migrations (Go migrations 2, 4, 5 interleave with SQL 1, 3).
24. **Flash cookie** is base64 **RawURL** without padding. Tests decode it, and E2E tests may too.
25. **Go `html/template` contextual escaping** applies to text and attribute values (`value="{{…}}"`, `label="{{.Name}}"`).
    - Go's HTML escaper maps `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, `"`→`&#34;`, `'`→`&#39;`, `+`→`&#43;`.
    - Crystal `HTML.escape` (used by ECR/Kilt helpers) maps `"`→`&quot;` and `'`→`&#39;`, and leaves `+` alone.
    - Tests only assert simple substrings such as `>Lebensmittel &amp; Drogerie<`, `value="c-food" selected` and `value="plan-1|acc-geteilt"`. Byte-identical HTML is only needed if E2E compares snippets containing `"`, `'` or `+`.

