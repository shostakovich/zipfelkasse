# Porting inventory: `internal/web`, `main.go`, `internal/config`

Source: Go 1.26.5 module `github.com/shostakovich/zipfelkasse`. All line numbers refer to the repo at
`/home/user/zipfelkasse`. Behaviour marked **[probed]** was verified by running the real Go app in a scratch
copy with `httptest` (repo untouched).

Files covered (all read fully): `main.go`, `internal/config/config.go`, `internal/web/{web,deps,render,format,identity,expenses,settings,activity,balances,pwa,suggest}.go`,
`internal/web/templates/layout.html`, `internal/web/templates/pages/*.html`, `internal/web/static/sw.js` (+ skim of `app.js`, `expense-form.js`).

---------------------------------------------------------------------------------------------------

## 0. Handler stack (top level, `main.go:67-110`)

```
http.Server
└─ root ServeMux                       (Go mux: path cleaning + subtree redirect, NO security headers on those redirects)
   ├─ "/mcp/"  → web.SecurityHeaders → mcpMux { "/mcp/{secret}" (any method) → mcp server }   (only if MCP_SECRET != "")
   └─ "/"      → web.Wrap(d, mux) = SecurityHeaders → limitBody → crossOrigin → identity → mux
                                         mux = web.Register + fx.Register + recurring.Register
                                               + ynab.Register + export.Register
```

* Registration order in `newApp`: `web.NewRenderer` → `Deps{Config,Store,Render,Log}` → `fx.New(d)` → `d.FX = fxSvc`
  → `recurring.New(d)` → `ynab.New(d)` → `web.Register` → `fxSvc.Register` → `rec.Register` → `yn.Register` →
  `export.Register(mux,d)` → `mcp.Register(mcpMux,d)`.
* Error wrapping in `newApp`: `"fx: %w"`, `"recurring: %w"`, `"ynab: %w"`, `"export: %w"`, `"mcp: %w"`; renderer
  errors are returned unwrapped (`"layout: %w"`, `"template %s: %w"`, `"partials: %w"`, `"duplicate template %s"`,
  `"no templates for %v"`).
* MCP is outside `Wrap`: no identity, no CSRF, no `limitBody` (it has its own 1 MiB limit), but it keeps the
  security headers. When MCP is disabled `mcpMux` is empty ⇒ every `/mcp/...` → Go plain 404.
* There is **no access-log middleware, no panic-recovery middleware, no method-override, no gzip** anywhere.
  Panics are handled by net/http itself (logs `http: panic serving <remote>: <value>` + stack via the std `log`
  package to stderr, connection is aborted, client gets no response).

---------------------------------------------------------------------------------------------------

## 1. Route table

Legend: **GET** routes in Go 1.22+ mux also match **HEAD** (body discarded). `{id}` = one path segment.
"render X (status)" = full layout page via `Renderer.Page` (always `Content-Type: text/html; charset=utf-8`,
`Cache-Control: no-store`). "303 → X" = `http.Redirect(w,r,X,303)`. All flashes are set via the `flash` cookie
(see §1.3). `me` = participant from identity middleware.

### 1.1 Routes of package `web` (`internal/web/web.go:18-54`)

| # | Method + pattern | Handler (file:line) | Public? | Reads | Success | Error / other outcomes |
|---|---|---|---|---|---|---|
| 1 | `GET /static/` | `cacheStatic(http.StripPrefix("/static/", http.FileServerFS(static)))` web.go:20, 59-68 | yes (prefix `/static/`) | query `v` (only presence) | 200 file, `Cache-Control` see §4 | 404 `404 page not found\n` text/plain (Cache-Control stripped); dirs → listing (see §4) |
| 2 | `GET /healthz` | `healthz` web.go:70-77 | yes | – | 200 body `ok\n`, `Content-Type: text/plain; charset=utf-8` | Store.Ping fails → `http.Error(w, "db: "+err.Error(), 503)` |
| 3 | `GET /manifest.webmanifest` | `manifest` pwa.go:23-50 | yes | group name | 200 JSON (§4.4), `Content-Type: application/manifest+json; charset=utf-8`, `Cache-Control: no-cache` | – |
| 4 | `GET /sw.js` | `serviceWorker` pwa.go:54-63 | yes | – | 200 bytes of `static/sw.js`, `Content-Type: text/javascript; charset=utf-8`, `Cache-Control: no-cache` | read error → ServerError 500 |
| 5 | `GET /favicon.ico` | `favicon` pwa.go:65-74 | yes | – | 200 bytes of `static/icons/favicon-32.png`, `Content-Type: image/png`, `Cache-Control: public, max-age=86400` | read error → 500 |
| 6 | `GET /wer` | `whoPage` web.go:95-97 | yes | query `zurueck` → `safeReturn` | render `who.html` (200), Title `Wer bist du?` | – |
| 7 | `POST /wer` | `whoSelect` web.go:99-109 | yes | `r.FormValue("zurueck")`, `r.FormValue("id")` (ParseInt, error ignored → 0) | set cookie `wer`; 303 → `safeReturn(zurueck)` | person missing/archived → render `who.html` **422**, Error `Diese Person gibt es nicht (mehr).` |
| 8 | `POST /wer/neu` | `whoCreate` web.go:111-127 | yes | `FormValue("zurueck")`, `FormValue("name")` | `Store.JoinAsParticipant(name)`; set cookie `wer`; flash `Willkommen!`; 303 → `safeReturn(zurueck)` | ValidationError → render `who.html` **422** with `Name` = raw input, Error = msg (e.g. `„Jörg“ gibt es schon.`); other err → 500 |
| 9 | `GET /{$}` (exactly `/`) | `home` expenses.go:56-126 | no | query `q` (TrimSpace), `kategorie` (formID), `person` (formID), `anzahl` (Atoi) | render `home.html` 200, Title `Ausgaben`, Nav `ausgaben` | store errors → 500 |
| 10 | `GET /ausgaben/neu` | `expenseNew` expenses.go:576-584 | no | query `rueckzahlung`, `von`, `an`, `betrag` | render `expense.html` 200, Title `Neue Ausgabe` | 500 |
| 11 | `POST /ausgaben/neu` | `expenseCreate` → `saveExpense(nil)` expenses.go:586-588, 616-662 | no | body fields §1.4 | flash `Ausgabe „<title>“ angelegt.` / `Rückzahlung „<title>“ angelegt.`; 303 → `/` | ParseForm err → error page **400** `Ungültige Anfrage.`; validation → render `expense.html` **422** with Error; `store.ErrNotFound` → 404 `Ausgabe nicht gefunden.`; else 500 |
| 12 | `GET /ausgaben/{id}` | `expenseShow` expenses.go:590-601 | no | path `id` (PathID) | render `expense.html` 200, Title = expense title (also for deleted ones) | id invalid/≤0 or not found → 404 `Ausgabe nicht gefunden.` |
| 13 | `POST /ausgaben/{id}` | `expenseUpdate` expenses.go:603-613 | no | path `id`, body §1.4 | flash `Ausgabe „…“ gespeichert.` / `Rückzahlung „…“ gespeichert.`; 303 → `/` | 404 as #12; deleted → error page **409** `Diese Ausgabe wurde gelöscht und kann nicht mehr bearbeitet werden.`; then same as #11 |
| 14 | `POST /ausgaben/{id}/loeschen` | `expenseDelete` expenses.go:664-680 | no | path `id` (no body read) | `Store.DeleteExpense`; flash `„<e.Title>“ gelöscht.` (title NOT whitespace-collapsed); 303 → `/` | load 404 `Ausgabe nicht gefunden.`; already deleted (`ErrNotFound` from delete) → 404 `Ausgabe nicht gefunden oder schon gelöscht.`; 500 |
| 15 | `GET /salden` | `balances` balances.go:30-73 | no | – | render `balances.html` 200, Title `Salden`, Nav `salden` | 500 |
| 16 | `GET /aktivitaet` | `activity` activity.go:51-78 | no | query `vor` (formID) | render `activity.html` 200, Title `Aktivität`, Nav `aktivitaet` | 500 |
| 17 | `GET /einstellungen` | `settings` settings.go:18-20 | no | group name | render `settings.html` 200, Title `Einstellungen`, Nav `einstellungen` | – |
| 18 | `POST /einstellungen` | `settingsSave` settings.go:28-41 | no | `FormValue("gruppenname")` | `Store.SetGroupName(me, name)`; flash `Gespeichert.`; 303 → `/einstellungen` | ValidationError → render `settings.html` **422** with GroupName = raw input; 500 |
| 19 | `GET /einstellungen/teilnehmer` | `participants` settings.go:56-58 | no | – | render `participants.html` 200, Title `Teilnehmer`, Nav `einstellungen` | 500 |
| 20 | `POST /einstellungen/teilnehmer` | `participantCreate` settings.go:89-102 | no | `FormValue("name")` | `Store.CreateParticipant`; flash `„<NormalizeName(name)>“ hinzugefügt.`; 303 → `/einstellungen/teilnehmer` | ValidationError → render participants **422** with `Name` = raw input; 500 |
| 21 | `POST /einstellungen/teilnehmer/{id}` | `participantRename` settings.go:104-120 | no | path id, `FormValue("name")` | flash `Gespeichert.`; 303 → `/einstellungen/teilnehmer` | not found → 404 `Person nicht gefunden.`; ValidationError → participants **422** (Name input empty); 500 |
| 22 | `POST /einstellungen/teilnehmer/{id}/archivieren` | `participantArchive(true)` settings.go:124-150 | no | path id | flash `„<p.Name>“ archiviert.`; 303 → `/einstellungen/teilnehmer` | 404 `Person nicht gefunden.` (load or store ErrNotFound); ValidationError (e.g. open balance: `Ben hat noch einen Saldo von -10,00 €…`) → participants **422**; 500 |
| 23 | `POST /einstellungen/teilnehmer/{id}/reaktivieren` | `participantArchive(false)` | no | path id | flash `„<p.Name>“ reaktiviert.`; 303 → same | as #22 |
| 24 | `GET /einstellungen/kategorien` | `categories` settings.go:178-180 | no | – | render `categories.html` 200, Title `Kategorien`, Nav `einstellungen` | 500 |
| 25 | `POST /einstellungen/kategorien` | `categoryCreate` settings.go:209-222 | no | `FormValue("name")` | flash `Kategorie „<NormalizeName(name)>“ hinzugefügt.`; 303 → `/einstellungen/kategorien` | ValidationError → categories **422** with Name; 500 |
| 26 | `POST /einstellungen/kategorien/{id}` | `categoryRename` settings.go:224-240 | no | path id, `FormValue("name")` | flash `Gespeichert.`; 303 → `/einstellungen/kategorien` | 404 `Kategorie nicht gefunden.`; ValidationError → categories **422**; 500 |
| 27 | `POST /einstellungen/kategorien/{id}/archivieren` | `categoryArchive(true)` settings.go:242-259 | no | path id | flash `Kategorie „<c.Name>“ archiviert.`; 303 → `/einstellungen/kategorien` | 404 from load; **any** store error (incl. validation) → 500 (no ValidationError handling!) |
| 28 | `POST /einstellungen/kategorien/{id}/reaktivieren` | `categoryArchive(false)` | no | path id | flash `Kategorie „<c.Name>“ reaktiviert.`; 303 → same | as #27 |
| 29 | `POST /einstellungen/kategorien/{id}/hoch` | `categoryMove(true)` settings.go:261-278 | no | path id | **no flash**; 303 → `/einstellungen/kategorien#kategorie-<id>` | 404 from load; store `ErrNotFound` (e.g. archived category) → 404 `Kategorie nicht gefunden.`; 500 |
| 30 | `POST /einstellungen/kategorien/{id}/runter` | `categoryMove(false)` | no | path id | same | same |

`ServerError` (deps.go:44-47) = log `ERROR msg=request method=… path=<logPath> err=…` + error page **500**
`Da ist etwas schiefgegangen.`

ID parsing helpers (web.go:142-158):
* `PathID(r)`: `strconv.ParseInt(r.PathValue("id"),10,64)`; error or `<=0` → 0. Accepts `+5`, `007` (→ 5, 7).
* `formID(v)`: same but on `strings.TrimSpace(v)`.
* `loadParticipant`/`loadCategory` pass `PathID` (possibly 0) straight to the store → store returns ErrNotFound → 404.
  `loadExpense` short-circuits id 0 → 404.

### 1.2 Routes registered by other packages (wired in `main.go`)

All are behind `web.Wrap` (identity + CSRF + body limit + security headers) unless noted.

| Package | Routes |
|---|---|
| `fx` (internal/fx/handlers.go:21-27) | `GET /api/kurs` (JSON; query `waehrung`, `datum`), `GET /einstellungen/kurse`, `POST /einstellungen/kurse`, `POST /einstellungen/kurse/loeschen`, `POST /einstellungen/kurse/aktualisieren` |
| `recurring` (internal/recurring/handlers.go:26-34) | `GET /einstellungen/wiederkehrend`, `GET /einstellungen/wiederkehrend/neu` (query `ausgabe`), `POST /einstellungen/wiederkehrend/neu`, `POST /einstellungen/wiederkehrend/{id}/pausieren`, `…/{id}/fortsetzen`, `…/{id}/vorlage`, `…/{id}/loeschen` |
| `ynab` (internal/ynab/handlers.go:20-27) | `GET /einstellungen/ynab`, `POST /einstellungen/ynab/token`, `…/trennen`, `…/konto`, `…/kategorien`, `…/sync` |
| `export` (internal/export/export.go:34-45) | `GET /export`, `GET /export/ausgaben.csv`, `GET /export/ausgaben.json`, `GET /export/ynab.ofx`, `GET /export/ynab.csv` |
| `mcp` (internal/mcp/mcp.go:26-33) | `/mcp/{secret}` any method, on the separate `mcpMux` **outside Wrap** (only SecurityHeaders). Only if `MCP_SECRET` non-empty. |

These packages render via `d.Render.Load(templatesFS, "templates/*.html")` (fx, recurring, ynab, export) and use the
same layout/FuncMap/flash/Me mechanics.

### 1.3 Cookies

| Name | Set where | Attributes (exact Go output) | Read where |
|---|---|---|---|
| `wer` (const `IdentityCookie`, identity.go:17) | `SetIdentity` identity.go:34-44 (POST /wer, POST /wer/neu) | Value = decimal participant ID. `Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax` plus `; Secure` iff `r.TLS != nil` **or** `r.Header.Get("X-Forwarded-Proto") == "https"` (exact, case-sensitive, first header value). Rendered: `wer=1; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax` **[probed]**. No `Expires`. Never deleted by the app. | `identity` middleware every request (`r.Cookie("wer")` = first cookie of that name; `strconv.ParseInt(value,10,64)`) |
| `flash` (const `flashCookie`, render.go:254) | `SetFlash(w,msg)` render.go:258-263 | Value = `base64.RawURLEncoding` (URL alphabet `-_`, **no padding**) of the UTF-8 message. `flash=<b64>; Path=/; Max-Age=60; HttpOnly; SameSite=Lax` (never Secure) **[probed]** | `takeFlash` in **every** `Pages.Render` (also error pages, 422 re-renders, and pages of other packages). If cookie present (even if undecodable): emits delete cookie `flash=; Path=/; Max-Age=0` (Go `MaxAge:-1`) **[probed]**; undecodable → no message. |

### 1.4 Form fields / query params (exact names)

* `/wer`: GET query `zurueck`; POST body/query (`FormValue` = body first, then URL query) `zurueck`, `id`.
* `/wer/neu`: `zurueck`, `name`.
* Home `/` query: `q`, `kategorie`, `person`, `anzahl`.
* Expense form (POST `/ausgaben/neu`, `/ausgaben/{id}`) – read with `r.ParseForm()` then **`PostFormValue` / `r.PostForm` only (URL query ignored)** (expenses.go:301-343):
  * `titel` (raw, not trimmed), `datum` (TrimSpace), `kategorie` (formID), `waehrung` (ToUpper(TrimSpace)),
    `waehrung_andere` (ToUpper(TrimSpace)), `betrag` (TrimSpace), `kurs` (TrimSpace), `kurs_quelle` (raw),
    `bezahlt_von` (formID), `notiz` (raw), `rueckzahlung` (non-empty ⇒ true), `aufteilung` (SplitMode;
    invalid ⇒ `equal`), `teil` (multi-valued, each formID, 0s dropped), `wert_<participantID>` (TrimSpace).
* New-expense query (`GET /ausgaben/neu`): `rueckzahlung` (non-empty ⇒ reimbursement), `von`, `an` (formID),
  `betrag` (cents, `strconv.ParseInt`, must be > 0).
* `/aktivitaet` query: `vor` (activity ID for paging, formID).
* `/einstellungen`: `gruppenname`. Participants/categories create/rename: `name`.
* `FormValue` (used in who/settings handlers) also triggers `ParseMultipartForm(32 MiB)` so multipart bodies work
  there; `saveExpense` calls `ParseForm` first, after which `PostForm` is non-nil, so multipart bodies would yield
  an **empty** expense form (edge case; HTML forms are urlencoded).

### 1.5 Response headers per response class

| Response | Headers |
|---|---|
| everything through `Wrap` or `/mcp/` | `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin`, `X-Frame-Options: DENY`, `Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'` (identity.go:108-117) |
| rendered pages (incl. error pages) | `Content-Type: text/html; charset=utf-8`, `Cache-Control: no-store` |
| redirect for GET/HEAD request | `Location`, `Content-Type: text/html; charset=utf-8`; GET body `<a href="<html-escaped url>">See Other</a>.\n\n` (Fprintln adds the 2nd `\n`) **[probed]** |
| redirect for POST | `Location` only, **no body, no Content-Type** |
| `http.Error` (mux 404/405, healthz 503, "Interner Fehler") | `Content-Type: text/plain; charset=utf-8`, `X-Content-Type-Options: nosniff`, body = msg + `\n` |
| 413 from limitBody | additionally `Connection: close` |
| `WriteJSON` (deps.go:50-54) | `Content-Type: application/json; charset=utf-8`; body `json.NewEncoder(w).Encode(v)` ⇒ HTML-escaping on (`<`→`<`, `>`→`>`, `&`→`&`), trailing `\n`, map keys sorted |
| root-mux cleaning redirects (`//salden`, `/a/../salden`, `/mcp`→`/mcp/`) | **307** `Temporary Redirect`, `Location`, `Content-Type: text/html; charset=utf-8`, **no security headers** **[probed]** |

---------------------------------------------------------------------------------------------------

## 2. Middleware chain (outer → inner), `identity.go:119-189`

`Wrap(d,h) = SecurityHeaders(limitBody(d, crossOrigin(d, identity(d.Store, h))))`

1. **SecurityHeaders** (identity.go:108-117): sets the 4 headers above before calling next (so they are on every
   response incl. 404/405/413/403/redirects). Also applied alone to `/mcp/`.

2. **limitBody** (identity.go:133-161), `maxBodyBytes = 1 << 20` (1 048 576):
   * If `r.Body == nil || r.Body == http.NoBody` → pass.
   * Wrap body in `http.MaxBytesReader(w, r.Body, 1<<20)`.
   * `tooLarge = r.ContentLength > 1<<20` (exactly 1 MiB is allowed).
   * If `ContentLength < 0` (chunked/unknown): call `r.ParseForm()` now; `tooLarge` = error is `*http.MaxBytesError`.
     (Other parse errors are ignored here.)
   * If not too large → next. Else: log `WARN msg="request body too large" method=… path=<logPath> content_length=<n>`
     (only if `d.Log != nil`), header `Connection: close`, then
     * path prefix `/api/` → JSON **413** `{"error":"Die Anfrage ist zu groß."}`
     * else error page **413** `Die gesendeten Daten sind zu groß. Bitte kürze die Eingaben und versuche es noch einmal.`
   * Note: this runs *before* identity, so the 413 page has no `Me` (no nav, no "Du bist").
   * A too-large body with a *known* Content-Length is rejected without reading it.

3. **crossOrigin** (identity.go:176-189) = Go 1.25 `http.NewCrossOriginProtection()` with custom deny handler,
   no trusted origins / bypass patterns. Exact `Check` algorithm (Go source csrf.go):
   1. Method `GET`, `HEAD`, `OPTIONS` → allow.
   2. `Sec-Fetch-Site` header: `same-origin` or `none` → allow; any other non-empty value (`cross-site`,
      `same-site`, garbage) → **reject**.
   3. Header absent: `Origin` absent → allow (curl, old browsers). Else parse Origin as URL; if `o.Host == r.Host`
      (host:port compare, scheme ignored) → allow; else reject.
   * Deny handler: log `WARN msg="cross-origin request rejected" method=… path=<logPath> origin=<Origin header>`;
     `/api/` prefix → JSON **403** `{"error":"Anfrage von einer fremden Seite abgelehnt."}`; else error page **403**
     `Diese Anfrage kam von einer fremden Seite und wurde abgelehnt. Bitte lade die Seite neu und versuche es noch einmal.`
   * Runs before identity ⇒ cross-site POST without cookie gets 403, not a redirect; page has no `Me`.

4. **identity** (identity.go:57-81):
   1. If cookie `wer` exists, parses as int64, `Store.GetParticipant(id)` succeeds and the person is **not archived**
      → put participant into context (`WithMe`) and call next (for *any* path, public or not).
   2. Else if `isPublic(path)` → next without Me. Public = exactly `/wer`, `/wer/neu`, `/healthz`,
      `/manifest.webmanifest`, `/sw.js`, `/favicon.ico`, or prefix `/static/` (note: `/static` without slash is NOT public).
   3. Else if path prefix `/api/` → JSON **401** `{"error":"Bitte zuerst auswählen, wer du bist."}`.
   4. Else **303** → `/wer`, plus `?zurueck=` + `url.QueryEscape(r.URL.RequestURI())` **only if** method is `GET`
      and `r.URL.Path != "/"` (so `/` and `/?q=x` → plain `/wer`; POST/HEAD → plain `/wer`).
      Example: `GET /salden?x=1` → `Location: /wer?zurueck=%2Fsalden%3Fx%3D1` (QueryEscape: uppercase hex, space→`+`).
   * The DB lookup happens on every request carrying the cookie (incl. static files).
   * Invalid/unknown/archived cookie is *not* cleared.

5. **mux** (Go 1.22+ `ServeMux`) – see §10 for semantics. Unknown path (with valid identity) → plain
   `404 page not found\n`; wrong method → **405** `Method Not Allowed\n` + `Allow:` header (e.g. `GET, HEAD`,
   `POST`, `GET, HEAD, POST`) **[probed]**. These are NOT the German error page.

`logPath(p)` (identity.go:166-171): if `strings.HasPrefix(p, "/mcp/")` → `/mcp/***` else p (`/mcp` and `/mcpx` unchanged).

`safeReturn(s)` (identity.go:87-103) → returns `s` or `"/"`:
* `"/"` if `s` contains `\` or any `unicode.IsControl` rune (tabs, CR, LF, NUL, U+0080–U+009F…).
* `url.Parse(s)`; `"/"` if parse error, or Scheme/Host/Opaque/User set, or `s` doesn't start with `/`, or starts
  with `//`, or decoded `u.Path` doesn't start with `/` or starts with `//`, or `u.Path` contains unsafe runes
  (so `%09`, `%2F/` at start are caught), or `u.Path` starts with `/wer` (also `/werbung`!).
* Otherwise `s` unchanged (query and `#fragment` kept, e.g. `/salden?x=1#a`).
* Then `http.Redirect` additionally **`path.Clean`s the path part** (`/a/../salden` → `/salden`, trailing slash
  preserved) and hex-escapes non-ASCII bytes in `Location` (lowercase hex) **[probed]**.

---------------------------------------------------------------------------------------------------

## 3. Templates

### 3.1 Parsing / composition (`render.go`)

* Embeds: `//go:embed templates/layout.html` (layoutFS), `//go:embed templates/pages/*.html` (pagesFS),
  `//go:embed static` (staticFS).
* `NewRenderer(st, loc, log)`: `loc==nil` → `time.Local`; `log==nil` → `slog.Default()`.
  1. Walks `static/` and builds `static map[relpath]hash` where hash = **lowercase hex of the first 5 bytes of
     SHA-256** of the file contents (10 hex chars). Keys like `app.css`, `icons/icon-192.png`, `sw.js`.
  2. `base = template.New("layout.html").Funcs(r.Funcs()).ParseFS(layoutFS, "templates/layout.html")`.
  3. `pages = r.Load(pagesFS, "templates/pages/*.html")`.
* `Load(fsys, patterns...)` (render.go:175-216): globs all patterns; files whose **base name starts with `_`** are
  partials; for each non-partial file: `t = base.Clone()`, parse all partials into it, then parse the page file;
  key = base file name (`home.html`); duplicate key → error `duplicate template X`; zero pages → error
  `no templates for [patterns]`. So every page set = layout + set partials + one page; pages override the
  `content`, `head`, `scripts` definitions.
* `layout.html` defines `{{define "layout"}}`, calls `{{template "content" .}}`, has `{{block "head" .}}{{end}}`
  inside `<head>` (after the app.js script tag) and `{{block "scripts" .}}{{end}}` right before `</body>`.
  Only `expense.html` defines `scripts`: `<script src="{{static "expense-form.js"}}" defer></script>`. No page
  defines `head`.
* `_activity.html` (partial) defines `activity-item` (expects `dict "A" item "Link" bool`) and `activity-actor`.
* `Pages.Render(w, req, status, name, page)` (render.go:220-242):
  1. Unknown name → log `ERROR msg="unknown template" name=…`, `http.Error(w,"Interner Fehler",500)`.
  2. Build `View{Page, GroupName: Store.GroupName(ctx), Path: req.URL.Path, Me: &me if in ctx, Flash: takeFlash(w,req)}`.
  3. Execute `"layout"` into a buffer; on error log `ERROR msg=template name=… err=…` and
     `http.Error(w, "Interner Fehler", 500)` (plain text, nothing of the page written; the flash-delete cookie may
     already be in the headers).
  4. Set `Content-Type: text/html; charset=utf-8`, `Cache-Control: no-store`, WriteHeader(status), write buffer.
* `Renderer.Page` = render from web's own set; `Renderer.Error(w, req, status, msg)` = `Page(status, "error.html",
  Page{Title: msg})` (Nav "", so no tab is `aria-current`).
* Template data (`View`, dot in layout): `.Title`, `.Nav`, `.Error`, `.Data`, `.Me` (*Participant or nil),
  `.GroupName`, `.Flash`, `.Path` (unused by templates).
* Exec semantics a port must mirror: `{{with}}`/`{{if}}` truthiness (empty string, 0, nil pointer, empty slice
  are false); `and`/`or` short-circuit (e.g. `{{if and $.Me (eq $.Me.ID .ID)}}` must not deref nil);
  `{{- $deleted := and $e $e.Deleted}}` (nil if no expense, else bool); `{{range … else}}`;
  `{{index .ForNames 0}}` errors (→ 500 "Interner Fehler") if the slice is empty; method calls
  (`.Archived`, `.Deleted`, `.IsForeign`, `.Label`, `.CurrencyCode`, `.Active`, `.UpdatedAt.Equal`);
  `{{.}}` of a `SplitMode` prints the raw value (`equal`/`shares`/`percent`/`amount`).
  Whitespace control `{{-`/`-}}` is used heavily; tests match substrings that depend on it (see §9/§10).

### 3.2 Layout (`layout.html`) essentials

* `<html lang="de">`; `<title>{{with .Title}}{{.}} · {{end}}{{.GroupName}}</title>` (separator is
  ` · ` = space U+00B7 space). Error page: `<title>Ausgabe nicht gefunden. · Zipfelkasse</title>`.
* Static meta: `viewport` `width=device-width, initial-scale=1, viewport-fit=cover`; `color-scheme` `light dark`;
  theme-color `#fcfdfe` (light) / `#0c0a09` (dark); `<link rel="manifest" href="/manifest.webmanifest">`;
  icon `{{static "icons/favicon-32.png"}}` type image/png sizes 32x32; apple-touch-icon
  `{{static "icons/apple-touch-icon.png"}}`; `<meta name="apple-mobile-web-app-title" content="{{.GroupName}}">`;
  stylesheet `{{static "app.css"}}`; `<script src="{{static "app.js"}}" defer></script>`.
* `<body{{if .Me}} class="has-tabbar"{{end}}>`; header with brand link `/` + `<img src="{{static "mascot.webp"}}" alt="" width="155" height="144">Zipfelkasse`
  (brand text is literally `Zipfelkasse`, not the group name).
* With Me: `<p class="whoami">Du bist <strong>{{.Name}}</strong> · <a href="/wer">wechseln</a></p>` and
  `<nav class="tabs" aria-label="Hauptnavigation">` with 4 links: `/` (`ausgaben`, icon receipt, `Ausgaben`),
  `/salden` (`salden`, icon scale, `Salden`), `/aktivitaet` (`aktivitaet`, icon activity, `Aktivität`),
  `/einstellungen` (`einstellungen`, icon settings, `Einstellungen`); active one gets ` aria-current="page"`
  directly after the href attribute (`href="/salden" aria-current="page"`).
* `<main class="container main">`: flash `<p class="alert alert-success" role="status">…</p>`, then error
  `<p class="alert alert-destructive" role="alert">…</p>`, then content.

### 3.3 FuncMap (`render.go:103-154`) – every function

All money/number formatting lives in `internal/domain/money.go` / `date.go`.

| Name | Signature | Exact behaviour |
|---|---|---|
| `eur` | `(int64 cents) string` | `domain.FormatCents`: `formatFixed(c,2,group=true) + " €"`. Separator before `€` is a plain ASCII space U+0020 (not NBSP). Decimal comma, thousands `.` (groups of 3 from the right, only if int part > 3 digits), negative = ASCII `-` prefix before the digits. `123456` → `1.234,56 €`; `-1000` → `-10,00 €`; `5` → `0,05 €`; `0` → `0,00 €`; `123456789` → `1.234.567,89 €`. |
| `amountInput` | `(int64) string` | `FormatCentsInput`: `formatFixed(c,2,false)` → `1234,56` (no grouping, no symbol). Registered but unused in any template. |
| `money` | `(int64 minor, string cur) string` | `FormatMoney`: if `IsEUR(cur)` (`""`/`EUR`, trimmed, case-insensitive) → `eur`; else `formatFixed(minor, CurrencyDecimals(cur), true) + " " + upper(trim(cur))`. Decimals: 0 for `JPY KRW ISK HUF CLP VND XAF XOF PYG UGX IDR`; 3 for `KWD BHD OMR JOD TND LYD IQD`; else 2. With 0 decimals no comma: `(170000,"IDR")` → `170.000 IDR`. `(1000,"USD")` → `10,00 USD`. |
| `percent` | `(int64 bp) string` | `FormatBasisPoints`: `formatFixed(bp,2,false) + " %"` (ASCII space) → `33,33 %`. Unused in templates. |
| `date` | `(time.Time) string` | `FormatDate`: zero → `""`, else `t.Format("02.01.2006")` → `02.10.2026`. |
| `isoDate` | `(time.Time) string` | zero → `""`, else `2006-01-02`. Used only by fx/ynab/export templates. |
| `dateTime` | `(time.Time) string` | zero → `""`, else `t.In(r.loc).Format("02.01.2006, 15:04")` (24h, zero-padded) → `03.10.2026, 06:13`. `r.loc` = `Config.Location`. |
| `signClass` | `(int64) string` | `>0` → `positive`, `<0` → `negative`, `0` → `""`. |
| `static` | `(string name) string` | `"/static/" + name` + (`"?v=" + hash` iff name is a key of the static map). E.g. `/static/app.css?v=<10 hex>`. |
| `icon` | `(string name) template.HTML` | **Raw HTML**: `<svg class="icon" aria-hidden="true"><use href="` + `template.HTMLEscapeString(staticURL("icons.svg") + "#" + name)` + `"></use></svg>`. HTMLEscapeString escapes `& ' < > "` and NUL (not `+`). Example: `<svg class="icon" aria-hidden="true"><use href="/static/icons.svg?v=6472248079#receipt"></use></svg>`. |
| `categoryIcon` | `(string) string` | `format.go:9-42`: lower-case the name (`strings.ToLower`), first table entry whose keyword is a **substring** wins, default `tag`. Table in order: `cart`: lebensmittel, einkauf, supermarkt, drogerie · `utensils`: restaurant, essen, café, cafe, gastro, lieferdienst · `key`: miete, wohnung · `zap`: nebenkosten, strom, wasser, heizung, energie · `home`: haushalt, möbel, garten, reparatur · `car`: transport, auto, bahn, tank, taxi, parken, fahrt, öpnv · `plane`: reise, urlaub, hotel, flug · `ticket`: freizeit, kino, konzert, sport, ausflug, hobby, unterhaltung · `heart`: gesundheit, apotheke, arzt, medizin · `gift`: geschenk, spende · `shirt`: kleidung, mode, schuhe · `baby`: kind, baby, kita · `paw`: haustier, tier · `graduation`: bildung, schule, kurs, buch, bücher · `phone`: handy, internet, telefon, abo, streaming · `shield`: versicherung · `receipt`: sonstig, allgemein. (`Miete & Nebenkosten` → `key` because `key` precedes `zap`.) |
| `minorInput` | `(int64, string) string` | `FormatMinorInput`: `FormatDecimal(minor, CurrencyDecimals(cur), ',')`, no grouping: `(123456,"USD")` → `1234,56`, `(500,"JPY")` → `500`. Unused in templates (used directly in Go). |
| `rateInput` | `(float64) string` | `FormatRate`: `!(rate>0)` (incl. NaN) → `""`; else `strconv.FormatFloat(rate,'f',-1,64)` (shortest round-trip, **never exponent notation, no trailing `.0`**) with the first `.` → `,`: `1.0876` → `1,0876`, `17000` → `17000`, `1.25` → `1,25`. Unused in templates (used in Go). |
| `dict` | `(kv ...any) (map[string]any, error)` | Odd count → error `dict: odd number of arguments`; non-string key → error `dict: key %v is not a string`. |

`formatFixed`/`formatSep` algorithm: take |v| as decimal digits; left-pad with zeros to `decimals+1` digits; split
int/frac; group int part with `.` if requested and len>3; join with `,` (if decimals>0); prefix `-` if negative.
There are no German weekday/month names and no relative-date helpers in the FuncMap; relative period labels are
computed in Go (§8).

Icons available in `static/icons.svg` (symbol ids): receipt scale activity settings plus search chevron-right
chevron-up chevron-down save trash repeat archive undo banknote tag cart utensils home key zap car plane ticket heart
gift shirt baby paw graduation phone shield user users pencil refresh.

### 3.4 Deliberately raw (unescaped) output

* **Only** `icon` returns `template.HTML` (render.go:132-135). No `template.JS`, `template.URL`, `template.HTMLAttr`,
  `template.CSS` anywhere in the repo's non-test Go code.
* `Data.Suggest` (expense page) is a plain `string` of JSON placed in `data-suggest="…"` → it IS HTML-escaped
  (`"` → `&#34;`), e.g. `data-suggest="{&#34;t&#34;:{&#34;kaufland mitte&#34;:1},&#34;w&#34;:{…}}"` **[probed]**.

### 3.5 Context-sensitive escaping a port must replicate (html/template)

Verified with Go 1.26.5 **[probed]**:

* **HTML text, RCDATA (`<title>`, `<textarea>`) and quoted attribute values (plain attrs incl. `value`,
  `content`, `aria-label`, `data-*`, `datetime`, `id`, `for`)**: replace `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`,
  `"`→`&#34;`, `'`→`&#39;`, **`+`→`&#43;`**, NUL→U+FFFD. Non-ASCII stays literal UTF-8.
  Example: `Anna <b>"&'` → `Anna &lt;b&gt;&#34;&amp;&#39;`.
* **URL attributes** (`href`, `src`, `action`, `formaction`; also any `data-*`/attr whose name contains
  `src`/`uri`/`url`):
  * Value at attribute start (`href="{{.Link}}"`, `href="{{.}}"` for More links): scheme filter (only
    `http`, `https`, `mailto` or no scheme; otherwise the whole value becomes `#ZgotmplZ`), then URL
    normalization (percent-encode bytes not allowed in URLs, e.g. space → `%20`, `"` → `%22`, `<` → `%3c`,
    non-ASCII → UTF-8 bytes `%c3%bc` – **lowercase hex**; existing `%xx`, `&`, `?`, `=`, `/`, `+` kept), then
    attribute escaping (`&`→`&amp;`, `+`→`&#43;`). E.g. balances link renders as
    `href="/ausgaben/neu?an=1&amp;betrag=61728395&amp;rueckzahlung=1&amp;von=2"`; a `q=a b` More link
    (`url.Values.Encode` → `q=a+b`) renders `q=a&#43;b`.
  * Value inside the path after static text (`/ausgaben/{{.ID}}`, `/einstellungen/kategorien/{{.ID}}/hoch`):
    normalizer (all values here are int64 IDs, so plain digits).
  * Value in the query part (`?ausgabe={{.ID}}`): full query escaping (`%2f`, `%3f`, `%26`, `%2b`, lowercase);
    only ints are used here.
* **CSS attribute** `style="width: {{.Width}}%"` (balances): ints pass through unchanged (`width: 50%`).
* **No dynamic JS contexts**: no inline `<script>` bodies, no `on*` attributes with template values (CSP forbids
  inline scripts anyway). `<script src>` gets only `static` output.
* `<time datetime="{{$a.At.Format "2006-01-02T15:04:05Z07:00"}}">` → `2026-10-03T06:13:21Z` (store returns UTC, so
  always `Z`).

### 3.6 Page templates (data and notable output)

* **who.html** (`whoData{Participants (active only, ListParticipants(false)), Return, Name}`): H1 `Wer bist du?`,
  description `Wähle dich aus. Die App merkt sich das auf diesem Gerät.`; if participants: form POST `/wer` with
  hidden `zurueck` and one `<button … type="submit" name="id" value="{{.ID}}">Name</button>` per person
  (` aria-current="true"` for current Me); else `Noch niemand da. Leg dich unten als erste Person an.`; second card
  `Neue Person`: form POST `/wer/neu`, hidden `zurueck`, input `name` (`required maxlength="60" autocomplete="given-name"`),
  button `Anlegen und auswählen`.
* **home.html** (`homeData{Balance, Today, Groups, Filter{Text,CategoryID,ParticipantID}, Categories, Participants, More}`):
  balance card `Dein Saldo` + `eur Balance` with `signClass`, help `Du bekommst noch Geld.` / `Du schuldest noch Geld.` /
  `Alles ausgeglichen.`; search form GET `/` (input `q` type=search maxlength 200, selects `kategorie` (`Alle Kategorien`)
  and `person` (`Alle Personen`) with `data-autosubmit`, button `Suchen`, `Filter zurücksetzen` link if filter active);
  list `<div class="card-list" data-more-list data-sync-url>`; each group `<div class="expense-group" data-group="Label">`
  + `<h2 class="list-group-label">`; each row `<a class="expense[ reimbursement]" id="ausgabe-ID" href="/ausgaben/ID">`
  with icon (banknote for reimbursement else `categoryIcon .CategoryName`), title (+ repeat badge if `RecurringID`),
  meta: reimbursement `<strong>Payer</strong> an <strong>ForNames[0]</strong>`; else
  `Bezahlt von <strong>Payer</strong> für ` + (`<strong>alle</strong>` if Everyone, else names joined `, ` each in
  `<strong>`); second meta `Dein Saldo: <span class="signClass"><strong>eur</strong></span>` or `Du bist nicht beteiligt`;
  side: `eur AmountCents`, `money OriginalAmountMinor OriginalCurrency` if foreign, `date .Date`. Empty:
  `Keine Ausgaben gefunden. <a href="/">Filter zurücksetzen</a>` (filter active) or
  `Noch keine Ausgaben. <a class="btn-link" href="/ausgaben/neu">Erste Ausgabe anlegen</a>`. More:
  `<a class="btn btn-outline" href="{{.}}" data-more>Weitere anzeigen</a>`. FAB `<a class="fab" href="/ausgaben/neu" aria-label="Ausgabe hinzufügen">… Ausgabe</a>`.
* **expense.html** (`expensePage{Form, Expense, Categories, Payers, Currencies, SplitModes, History, Rotation, Suggest}`):
  form `id="expense-form" method="post" data-rotation="{{Rotation}}" action="/ausgaben/ID"|"/ausgaben/neu"`;
  `<fieldset class="stack" disabled>` when deleted; H1 `Gelöschte Ausgabe` / `Ausgabe bearbeiten` /
  `Ausgabe hinzufügen`; for existing: `Angelegt am {{dateTime CreatedAt}}` + ` · geändert am {{dateTime UpdatedAt}}` if
  different + recurring badge link `/einstellungen/wiederkehrend`; deleted alert
  `Diese Ausgabe wurde am {{dateTime DeletedAt}} gelöscht und zählt nicht mehr zu den Salden.`;
  fields `titel` (maxlength 200, placeholder `z. B. Einkauf Wochenmarkt`), `datum` type=date, `kategorie` select
  (`Keine Kategorie` + categories, ` (archiviert)` suffix, `data-suggest`), `bezahlt_von` select, `waehrung` select
  (14 currencies `EUR USD GBP CHF DKK SEK NOK PLN CZK HUF TRY JPY CAD AUD`, EUR label `EUR – Euro`, last
  `<option value="">Andere …</option>` selected when Currency==""), `waehrung_andere` (maxlength 3,
  `pattern="[A-Za-z]{3}"`), `betrag` with unit `€` or code, fx box (`kurs`, hidden `kurs_quelle`, hint
  `Von Hand eingetragener Kurs.` (manuell) / `EZB-Kurs.` (ezb) / `Leer lassen für den EZB-Kurs.`, button
  `EZB-Kurs laden` hidden, preview `Umgerechnet in Euro` = `eur EURCents` or `–`), checkbox
  `<input type="checkbox" id="rueckzahlung" name="rueckzahlung" value="1" checked>` + `Das ist eine Rückzahlung`,
  `notiz` textarea (rows 2, maxlength 2000); split card `Für wen?`/`An wen?`, rows
  `<div class="split-row" data-id="ID">` with `<input type="checkbox" name="teil" value="ID" checked>`, name
  (+ ` <span class="muted">(archiviert)</span>`), `<span class="split-share" data-share>` = `eur Cents` if checked
  and Cents≠0, `<input id="wert_ID" name="wert_ID" value="…" inputmode="decimal" autocomplete="off">`, unit
  `Anteile` / `%` / `€` / code; `<details class="disclosure not-reimbursement"[ open if mode≠equal]>` with select
  `aufteilung` options `<option value="equal" selected>Gleichmäßig` / `Nach Anteilen` / `Nach Prozent` /
  `Nach Beträgen`; actions (not if deleted): submit `Speichern`/`Anlegen`, delete button
  `formaction="/ausgaben/ID/loeschen" formnovalidate data-confirm="Diese Ausgabe wirklich löschen? Sie verschwindet aus Liste und Salden; im Aktivitätsprotokoll bleibt sie sichtbar."`,
  `Abbrechen` → `/`; history card `Verlauf` (recurring note or link `/einstellungen/wiederkehrend/neu?ausgabe=ID`
  `Als wiederkehrend einrichten`; items via `activity-item` with Link=false; empty `Noch keine Einträge.`).
* **_activity.html**: wrapper is `<a class="activity-item" href="/ausgaben/ID">` (Link && ExpenseID≠0) else
  `<div class="activity-item">`; verb form `<strong>Actor</strong> hat <em>„Title“</em> Verb` + ` <span class="amount muted">(eur)</span>`
  if ShowAmount + `.`; other actions `<strong>Actor</strong>: Text` (fallback raw `Action`); changes list
  `<li>Field: <del>Old|–</del> → <ins>New|–</ins></li>`; time element. Actor = `ActorName` if `ActorID≠0` else
  `Automatisch`.
* **activity.html**: H1 `Aktivität`, `Wer hat wann was angelegt, geändert oder gelöscht.`; groups
  `<div class="activity-group" data-group="Label">`; empty `Noch keine Aktivität.`; More `Ältere anzeigen`.
* **balances.html**: rows `<div class="balance-row[ negative-row][ me]">`, name (+ ` <span class="muted">(archiviert)</span>`),
  `eur Cents`, bar `<div class="balance-bar" style="width: N%"></div>` if Width≠0; empty `Noch niemand da.`;
  transfers `<strong>From</strong> schuldet <strong>To</strong>` + `<a class="btn btn-link" href="Link">Als erstattet markieren</a>`
  + `eur`; empty `Alles ausgeglichen – niemand muss etwas zurückzahlen.`
* **settings.html**: input `gruppenname` (maxlength 60); link list `/einstellungen/teilnehmer` (users)
  `Teilnehmer`, `/einstellungen/kategorien` (tag) `Kategorien`, `/einstellungen/wiederkehrend` (repeat)
  `Wiederkehrende Ausgaben`, `/einstellungen/kurse` (banknote) `Wechselkurse`, `/einstellungen/ynab` (receipt) `YNAB`,
  `/export` (archive) `Export`.
* **participants.html**: per active person `<li id="person-ID">` rename form (input `name` id `name-ID`), archive
  button with `data-confirm="NAME archivieren?"`, meta `N Ausgabe|Ausgaben · Saldo <span class="amount signClass">eur</span>`
  + ` · <strong>das bist du</strong>`; add form; archived section with `Zurückholen` → `/reaktivieren`;
  back link `← Zurück zu den Einstellungen`.
* **categories.html**: like participants, `<li id="kategorie-ID">`, icon via `categoryIcon`, up/down buttons
  (`disabled` on First/Last), archive; no confirm.
* **error.html**: `<h1 class="card-title">{{.Title}}</h1>` + `<a class="btn btn-outline" href="/">Zur Startseite</a>`.

---------------------------------------------------------------------------------------------------

## 4. Static files, PWA

### 4.1 `/static/` (web.go:19-20, 59-68)

* Source: `embed.FS` of `internal/web/static` (app.css, app.js, expense-form.js, icons.svg, mascot.webp, sw.js,
  icons/{apple-touch-icon,favicon-32,icon-192,icon-512,maskable-512}.png), served via
  `http.StripPrefix("/static/", http.FileServerFS(fs.Sub(staticFS,"static")))`.
* `cacheStatic` sets **before** serving: `Cache-Control: public, max-age=31536000, immutable` if query param `v`
  is non-empty (any value, not checked against the hash), else `Cache-Control: public, max-age=300`.
* Content-Type from Go's built-in extension table (system mime files cannot override built-ins):
  `.css` `text/css; charset=utf-8`, `.js` `text/javascript; charset=utf-8`, `.svg` `image/svg+xml`,
  `.png` `image/png`, `.webp` `image/webp`. `Content-Length`, `Accept-Ranges: bytes`, Range/If-Range supported.
* **No `ETag`, no `Last-Modified`** (embed FS ModTime is zero ⇒ ServeContent omits Last-Modified and ignores
  If-Modified-Since). No compression.
* 404 (`/static/nope.css`): `serveError` strips `Cache-Control` → plain `404 page not found\n` **[probed]**.
* Directory requests: `/static/` → **200 HTML directory listing**
  (`<!doctype html>\n<meta name="viewport" content="width=device-width">\n<pre>\n<a href="app.css">app.css</a>\n…</pre>\n`,
  sorted names, dirs with `/`) **[probed]**; `/static/icons` → **301** `Location: icons/` (relative, empty body);
  `/static/index.html` → **301** `Location: ./`; `/static` (no slash) → mux **307** → `/static/` (with identity) or
  303 → `/wer?zurueck=%2Fstatic` (without, since `/static` isn't public).
* HEAD supported (same headers, no body).

### 4.2 Cache busting

`static "x"` / `staticURL` appends `?v=<first 10 hex of sha256(file)>` (computed once at startup).

### 4.3 Service worker

* `GET /sw.js` serves `static/sw.js` bytes with `Content-Type: text/javascript; charset=utf-8`,
  `Cache-Control: no-cache` (no `Service-Worker-Allowed` header; scope `/` because it's at the root). Also
  reachable as `/static/sw.js` with static caching.
* sw.js: `install` → `skipWaiting()`, `activate` → `clients.claim()`, `fetch` only for `mode === "navigate"`:
  network, on failure a synthetic **503** HTML (`<title>Offline</title>`, `<h1>Keine Verbindung</h1>`,
  `Der Server ist gerade nicht erreichbar.`, `Erneut versuchen`). No Cache API usage (a test asserts the file
  contains no `caches.`).
* Registered by app.js: `navigator.serviceWorker.register("/sw.js")` on `load` if `isSecureContext`.

### 4.4 Manifest (`pwa.go:23-50`) – generated per request

`json.NewEncoder(w).Encode(map[string]any{…})` ⇒ keys alphabetically sorted, trailing newline. Exact output for
default group name **[probed]**:

```
{"background_color":"#ffffff","description":"Gemeinsame Ausgaben teilen","dir":"ltr","display":"standalone","icons":[{"src":"/static/icons/icon-192.png?v=0d23eb359b","sizes":"192x192","type":"image/png","purpose":"any"},{"src":"/static/icons/icon-512.png?v=17f68298a2","sizes":"512x512","type":"image/png","purpose":"any"},{"src":"/static/icons/maskable-512.png?v=7e9b5b5227","sizes":"512x512","type":"image/png","purpose":"maskable"}],"id":"/","lang":"de","name":"Zipfelkasse","scope":"/","short_name":"Zipfelkasse","shortcuts":[{"name":"Ausgabe hinzufügen","url":"/ausgaben/neu"},{"name":"Salden","url":"/salden"}],"start_url":"/","theme_color":"#047756"}
```

* `name` = `short_name` = `Store.GroupName` (fallback `Zipfelkasse`). Icon objects keep struct field order
  `src, sizes, type, purpose` (`purpose` omitempty). Shortcut maps are sorted (`name`, `url`).
  `theme_color` const `themeColor = "#047756"`.
* Headers: `Content-Type: application/manifest+json; charset=utf-8`, `Cache-Control: no-cache`.

### 4.5 JS ↔ server contracts (app.js / expense-form.js)

* "More" paging: app.js fetches the `data-more` link (same-origin), parses the HTML, takes the `[data-more-list]`
  element and merges groups by identical `data-group` label; with `data-sync-url` it `history.replaceState`s.
  Server must keep these attributes and identical labels.
* `select[data-autosubmit]`, `[data-confirm]` (window.confirm), POST-form submit lock.
* expense-form.js: reads `data-rotation`, `data-currency`, `data-id`, `[data-share]`, `[data-unit]`,
  `data-suggest` (JSON `{"t":{titleKey:catID}, "w":{word:[catID,support]}}`), fetches
  `/api/kurs?waehrung=XXX&datum=YYYY-MM-DD` with `Accept: application/json`, writes `kurs` and `kurs_quelle`
  (`ezb`/`manuell`). Its `titleKey` = `s.toLowerCase().split(/[^\p{L}]+/u).filter(Boolean).join(" ")` and must equal
  Go's `titleKey`.

---------------------------------------------------------------------------------------------------

## 5. Error handling summary

| Situation | Status | Body |
|---|---|---|
| Unknown route (with identity) | 404 | Go plain `404 page not found\n` (NOT the German page) |
| Unknown route (no identity, GET) | 303 | → `/wer?zurueck=…` |
| Wrong method on known path | 405 | plain `Method Not Allowed\n`, `Allow: GET, HEAD` / `POST` / `GET, HEAD, POST` (for `/wer`) |
| Handler "not found" | 404 | German error page; titles: `Ausgabe nicht gefunden.`, `Ausgabe nicht gefunden oder schon gelöscht.`, `Person nicht gefunden.`, `Kategorie nicht gefunden.` |
| Edit deleted expense | 409 | `Diese Ausgabe wurde gelöscht und kann nicht mehr bearbeitet werden.` |
| Expense form ParseForm error | 400 | `Ungültige Anfrage.` |
| Validation | 422 | re-rendered form page with `<p class="alert alert-destructive" role="alert">msg</p>` |
| Cross-origin POST | 403 | `Diese Anfrage kam von einer fremden Seite und wurde abgelehnt. Bitte lade die Seite neu und versuche es noch einmal.` / JSON `{"error":"Anfrage von einer fremden Seite abgelehnt."}` |
| Body > 1 MiB | 413 | `Die gesendeten Daten sind zu groß. Bitte kürze die Eingaben und versuche es noch einmal.` / JSON `{"error":"Die Anfrage ist zu groß."}` + `Connection: close` |
| No identity on `/api/…` | 401 | JSON `{"error":"Bitte zuerst auswählen, wer du bist."}` |
| Store/other errors | 500 | page `Da ist etwas schiefgegangen.` + log |
| Template exec error / unknown template | 500 | plain `Interner Fehler\n` |
| `/healthz` DB down | 503 | plain `db: <err>\n` |
| Panic | – | connection aborted by net/http (no recovery middleware) |

Error pages are rendered with the layout; Me/nav present only if identity already ran (not for 403/413).

Validation messages produced in web itself (expenses.go): `Bitte einen Titel angeben.`,
`Ungültige Währung „%s“ – bitte einen dreistelligen ISO-Code wie USD angeben.`, `Der Betrag muss größer als 0 sein.`,
`Eine Rückzahlung geht an genau eine Person – bitte genau einen Empfänger ankreuzen.`,
`Bitte mindestens eine Person ankreuzen, für die bezahlt wurde.`, `%s: Negative Werte sind nicht erlaubt.`,
`<Name>: <domain msg>` prefixing (unless msg already starts with the name),
`Für %s ist am %s kein Wechselkurs verfügbar. Kurs bitte von Hand eintragen.` (date via `FormatDate`). Others come
from `domain` (ParseDate/ParseMinor/ParseRate/ParseWeight) and `store` (sum checks, names, recurring collision).

---------------------------------------------------------------------------------------------------

## 6. Handler logic details (web)

### 6.1 Home (`expenses.go:56-157`)
* `limit = 100` (`homePageSize`); if `Atoi(anzahl)` ok and `> 100` → `min(n, 100000)`.
* `ListExpenses(Text, CategoryID, ParticipantID, Limit: limit+1)` (store excludes deleted, sorts date desc).
  If more than `limit` → truncate and `More = "/?" + url.Values{q?, kategorie?, person?, anzahl=limit+100}.Encode()`
  (keys sorted: `anzahl`, `kategorie`, `person`, `q`; only non-empty/non-zero filters).
* Balance = `Store.Balances()[me.ID]`. Filter options = non-archived + the selected (even archived) one.
* `groupExpenses`: `active` = IDs of non-archived people. Per expense: `Everyone = len(active) >= 4 && len(Shares) == len(active) && every share's person is active`;
  `ForNames` = names for each share in share order (sorted by participant ID); `Involved` if me has a share or paid;
  `MyBalance = (paid? Amount : 0) - ShareOf(me)`. Consecutive expenses with the same period form one group
  (input is date-desc so periods are monotonic).

### 6.2 Expense form (`expenses.go:159-574`)
* `newExpenseForm`: Date = today (`2006-01-02`), Currency `EUR`, PaidBy = me, SplitMode `equal`. Reimbursement
  (`rueckzahlung` non-empty): IsReimbursement, Title `Rückzahlung`, PaidBy = `von` if non-zero (not validated),
  Amount = `FormatCentsInput(betrag)` if it parses and > 0. Rows: all people except archived ones that are neither
  PaidBy nor `an`; Checked = not archived (normal) or `id == an` (reimbursement).
* `formFromExpense`: Currency = original currency if in the 14 common ones else CurrencyOther; foreign:
  Amount = `FormatMinorInput(OriginalAmountMinor, cur)`, Rate = `FormatRate(FXRate)`, RateSource = FXSource;
  EUR: Amount = `FormatCentsInput(AmountCents)`; EURCents = AmountCents. Rows: everyone except archived people not
  in shares and not payer; values: shares → integer weight, percent → `FormatBasisPoints(w)` minus suffix `" %"`,
  amount → `FormatMinorInput(weight, cur)`; Cents = share amount.
* `readExpenseForm`: rows = non-archived + archived if checked / in existing (payer or share) / == PaidBy.
* `CurrencyCode()` = Currency or CurrencyOther, upper+trim, empty → `EUR`. `Foreign()` = code ≠ EUR.
* `toInput` order: title non-blank → `ParseDate` (`2006-01-02`, `02.01.2006`, `2.1.2006`, years 2000–2100) →
  currency `ValidCurrencyCode` (3 ASCII uppercase) → EUR: `ParseCents`, >0; foreign: `ParseMinor(decimals)`, >0,
  `formRate`, `EURCents = ToEURCents` → reimbursement: SplitMode forced `equal`, exactly one checked row, Part
  without weight → else `splitParts` (≥1 checked; per row `splitWeight`: empty value ⇒ `"1"` for shares, `"0"`
  otherwise; `ParseWeight`; negative rejected).
* `formRate`: if `kurs` non-empty: `ParseRate` (error → return); if `kurs_quelle != "ezb"` → manual
  (`manuell`); if existing expense is ECB with same currency, same date and identical rate → keep (no lookup);
  otherwise (no rate, or ECB-marked rate) → `lookupRate` via `d.FX.Rate(ctx,cur,date)`; failure/rate≤0/FX nil →
  ValidationError (and form `kurs`/`kurs_quelle` cleared); success → form fields overwritten with
  `FormatRate(looked.Rate)` and source (empty source ⇒ `ezb`). FX errors logged `INFO msg="rate not available" currency=… date=… err=…`.
* `renderExpense`: categories = non-archived + selected; Payers = non-archived + PaidBy; Rotation = form ID or
  `Store.NextExpenseID()`; Suggest = `json.Marshal(suggestCategories(Store.CategoryHistory()))`; title
  `Neue Ausgabe` or expense title; History = `ListActivity(ExpenseID, Limit 50)` mapped via `activityItems`.
* Flash after save: `fmt.Sprintf("%s „%s“ angelegt.|gespeichert.", kind, strings.Join(strings.Fields(in.Title), " "))`
  (whitespace collapsed incl. NBSP, since Go `unicode.IsSpace` includes U+00A0/U+0085).

### 6.3 Category suggestions (`suggest.go`)
* `titleKey(t)`: `strings.ToLower`, split on every rune that is not `unicode.IsLetter`, join with single space.
  `"Miete 03/24"` → `miete`, `"Bäckerei-Müller!"` → `bäckerei müller`, `"2024"` → `""`.
* History is newest-first; per title key and per word keep at most the 10 (`suggestWindow`) most recent category IDs.
  Words: unique words of the key (sorted+deduped, so a word counts once per title), minus filler words
  `und oder für mit ohne bei von vom zu zum zur in im an am auf aus nach über der die das den dem des ein eine einen einem einer`.
* `majority(cats)`: highest count; ties → the one appearing first (newest).
* Titles map: every key → majority. Words map only if `3*n >= 2*len(cats)` → `[cat, n]`.
* JSON: `{"t":{…},"w":{"word":[cat,support]}}` (maps non-nil ⇒ `{}` when empty; keys sorted).

### 6.4 Activity (`activity.go`)
* Page size 50; `ListActivity(BeforeID: vor, Limit: 51)`; if 51 → truncate, `More = "/aktivitaet?vor=" + lastID`.
* `activityItems`: `expense_created` → Verb `angelegt`, ShowAmount = AmountCents≠0; `expense_updated` → `geändert`
  (no amount); `expense_deleted` → `gelöscht`, ShowAmount = AmountCents≠0; other actions → Verb "".
* Group label = `activityPeriod(DateOf(At.In(Config.Location or time.Local)), Today())`.

### 6.5 Balances (`balances.go`)
* `maxAbs` = max |balance| over **all** balances. Rows: all participants (name order, case-insensitive) except
  archived ones with balance 0. `Width = max(1, (|b|*100 + maxAbs/2) / maxAbs)` (integer, half-up) if maxAbs>0
  and b≠0, else 0.
* Transfers = `domain.Settle(balances)`; Link = `/ausgaben/neu?` + Encode{rueckzahlung=1, von, an, betrag=cents}
  → `an=…&betrag=…&rueckzahlung=1&von=…`.

### 6.6 Settings
* Group name save: `Store.SetGroupName(me, raw)`; 422 re-render shows the raw input.
* Participants page rows: `Balance` from `Store.Balances`, `Expenses` from `ExpenseCountByParticipant`; split
  active/archived.
* Categories page: `ExpenseCountByCategory`; `First`/`Last` flags on the active list.

---------------------------------------------------------------------------------------------------

## 7. Config, CLI, server lifecycle, logging

### 7.1 Env vars (`internal/config/config.go`)

| Var | Field | Default | Parsing |
|---|---|---|---|
| `ZIPFELKASSE_ADDR` | `Addr` | `:8080` | `or()` = TrimSpace; empty → default |
| `ZIPFELKASSE_DB` | `DBPath` | `./data/zipfelkasse.db` | TrimSpace/default |
| `ZIPFELKASSE_BACKUP_DIR` | `BackupDir` | `filepath.Join(filepath.Dir(DBPath), "backups")` (cleaned: default → `data/backups`; `/data/zipfelkasse.db` → `/data/backups`; `:memory:` → `backups`) | TrimSpace/default |
| `MCP_SECRET` | `MCPSecret` | `""` (= MCP disabled) | TrimSpace |
| `MCP_ALLOWED_CIDRS` | `MCPAllowedCIDRs` | `160.79.104.0/21` (const `DefaultMCPAllowedCIDRs`) | TrimSpace/default, then `ParsePrefixes`; error → `MCP_ALLOWED_CIDRS: <err>` |
| `TRUSTED_PROXIES` | `TrustedProxies` | empty | `ParsePrefixes` (not trimmed, but separators handle it); error → `TRUSTED_PROXIES: <err>` |
| `TZ` | `Location` | `time.Local` | if non-empty (NOT trimmed): `time.LoadLocation(tz)`; error → `TZ: unknown time zone Mars/Olympus` |

* `ParsePrefixes(s)`: split on `,`, space, `\t`, `\n` (not `\r`), drop empties; entry containing `/` →
  `netip.ParsePrefix` then `.Masked()` (host bits zeroed); otherwise `netip.ParseAddr`, `.Unmap()`, prefix of full
  bit length (/32 or /128). First error aborts (Go error text, e.g. `netip.ParsePrefix("1.2.3.4/99"): prefix length out of range`,
  `ParseAddr("not-a-cidr"): unable to parse IP`).
* `ContainsAddr(prefixes, a)`: `a.Unmap()` then any `p.Contains(a)` (so `::ffff:192.168.1.5` matches `192.168.1.5/32`).
* `time.Local` itself comes from Go's runtime: TZ unset → `/etc/localtime` (absent in the scratch image ⇒ UTC);
  `TZ=""` → UTC. `_ "time/tzdata"` in main.go embeds the zone DB. Docker image sets `TZ=Europe/Berlin`,
  `ZIPFELKASSE_ADDR=:8080`, `ZIPFELKASSE_DB=/data/zipfelkasse.db`.

### 7.2 CLI (`main.go:36-55`)

* `cmd = os.Args[1]` if present, else `serve`. Extra args ignored.
  * `serve` → `serve()`.
  * `healthcheck` → `healthcheck(os.Getenv("ZIPFELKASSE_ADDR"))` (raw env, not trimmed).
  * anything else (incl. `-h`) → stderr `unknown command "<cmd>"\nusage: zipfelkasse [serve|healthcheck]\n`, **exit 2**.
* Any returned error → stderr `zipfelkasse: <err>\n`, **exit 1**. Success → exit 0.
* `healthURL(addr)`: `""` → `:8080`; `net.SplitHostPort` (error → `ZIPFELKASSE_ADDR "broken": address broken: missing port in address`);
  host `""`, `0.0.0.0`, `::` → `127.0.0.1`; `"http://" + JoinHostPort(host,port) + "/healthz"` (IPv6 hosts get
  brackets). `http.Client{Timeout: 3s}` GET (follows redirects); non-200 → error `healthz: status <code>`.

### 7.3 `serve()` (`main.go:112-166`)

1. `config.FromEnv(os.Getenv)` (error → exit 1).
2. Logger `slog.New(slog.NewTextHandler(os.Stderr, nil))`.
3. `store.Open(cfg.DBPath)`; error → `database <path>: <err>`. `defer st.Close()`.
4. `newApp` (MCP logs `INFO msg="MCP disabled (MCP_SECRET is empty)"` or `INFO msg="MCP enabled" path=/mcp/*** allowed=[…] proxies=[…]`).
5. `net.Listen("tcp", cfg.Addr)` (error returned raw, e.g. `listen tcp :8080: bind: address already in use`).
6. `signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)`.
7. Start 4 goroutines (WaitGroup): `fx.Run(ctx)` (ECB rates: on start if cache stale, then each business day after
   16:30 Europe/Berlin, hourly retries ≤3), `recurring.Run(ctx)` (materialize now, then hourly ticker),
   `ynab.Run(ctx)` (debounced sync, hourly full sync), `backupLoop`.
8. `http.Server{ReadHeaderTimeout: 10s, ReadTimeout: 30s, WriteTimeout: 60s, IdleTimeout: 2m}` (default
   MaxHeaderBytes 1 MiB, HTTP/1.1 + h2c not enabled; no TLS). `srv.Serve(ln)` in goroutine.
9. Log `INFO msg="Zipfelkasse running" addr=<Addr> db=<DBPath> tz=<Location.String()>` (after listen).
10. Wait for Serve error or signal. On signal: log `INFO msg="shutting down"`, `srv.Shutdown` with 10 s timeout
    (deadline exceeded → returned as error ⇒ exit 1). Then `stop()` (cancels ctx for the background jobs even when
    Serve failed), `wg.Wait()`, `http.ErrServerClosed` → nil.

`backupLoop` (`main.go:170-196`): loop: `next = nextBackup(now in cfg.Location)` = today 03:00:00 local if strictly
after now, else tomorrow 03:00 (`time.Date(..., day+1, 3,0,0,0, loc)`); timer; on ctx done return; then
`st.Backup(ctx, cfg.BackupDir, 7)` (VACUUM INTO `<prefix><UTC 20060102-150405><suffix>`, rotate to last 7);
error → `ERROR msg="backup failed" err=…` and continue; success → `INFO msg="backup written" path=…`.
(No backup at startup.)

### 7.4 Logging format

`log/slog` TextHandler to **stderr**, default options: level INFO (debug suppressed), no source. Line format:
`time=2026-10-03T08:13:21.123+02:00 level=INFO msg="Zipfelkasse running" addr=:8080 db=/data/zipfelkasse.db tz=Europe/Berlin`
(time RFC3339 with milliseconds in local zone; values quoted only when they contain spaces/special chars; errors
via `Error()`; slices like `[160.79.104.0/21]`). Levels `INFO`, `WARN`, `ERROR`.
Log events in scope: `request` (ERROR, method/path/err), `request body too large` (WARN, method/path/content_length),
`cross-origin request rejected` (WARN, method/path/origin), `rate not available` (INFO, currency/date/err),
`unknown template` (ERROR, name), `template` (ERROR, name/err), `Zipfelkasse running`, `shutting down`,
`backup failed`, `backup written`, `MCP disabled (MCP_SECRET is empty)`, `MCP enabled`. Paths are passed through
`logPath` (MCP secret masked). Go's own server errors (panics, TLS handshake etc.) go via std `log` (`2006/01/02 15:04:05 http: …`).

---------------------------------------------------------------------------------------------------

## 8. Time-zone handling / "today"

* Calendar dates (expense date) are `time.Time` at 00:00 **UTC**; stored as `2006-01-02`.
* `Deps.Today()` = `domain.Today(loc)` = `DateOf(time.Now().In(loc))` → the local calendar date expressed as 00:00 UTC.
  `loc = Config.Location`, or `time.Local` if nil (tests leave Config zero).
* Timestamps (`CreatedAt`, `UpdatedAt`, `DeletedAt`, activity `At`) are stored RFC3339 UTC and parsed as UTC;
  displayed with `dateTime` → `In(Renderer.loc)` (= `Config.Location`); the `<time datetime>` attribute keeps UTC (`…Z`).
* Activity grouping converts `At` to `Config.Location` before taking the date.
* Backup at 03:00 in `Config.Location`. fx uses its own hard-coded Europe/Berlin for ECB publishing times.
* New-expense default date and period grouping use `Today()`.
* Period labels (`format.go:44-116`), week starts **Monday** (`weekStart(d) = d - ((weekday+6)%7) days`),
  `lastMonth` = first of current month minus 1 month:
  * Expenses (`expensePeriod`, checked in order): `d > today` → `Bevorstehend`; `d >= weekStart(today)` →
    `Diese Woche` (even if in previous month); same year+month → `Früher in diesem Monat`; lastMonth's year+month →
    `Letzter Monat` (works across New Year); same year → `Früher in diesem Jahr`; year-1 → `Letztes Jahr`; else `Älter`.
  * Activity (`activityPeriod`): `d >= today` → `Heute`; `d == today-1` → `Gestern` (checked before week, so
    Sunday is "Gestern" on a Monday); `d >= weekStart` → `Früher in dieser Woche`; `d >= weekStart-7` →
    `Letzte Woche`; same month → `Früher in diesem Monat`; last month → `Letzter Monat`; same year →
    `Früher in diesem Jahr`; year-1 → `Letztes Jahr`; else `Älter`.

---------------------------------------------------------------------------------------------------

## 9. Tests in scope

### `internal/web/web_test.go` (helpers: `newTestServer` = in-memory store + `Wrap(Register)`, Renderer loc UTC)
* `TestRedirectWithoutIdentity` – no cookie: `/salden?x=1` → 303 `/wer?zurueck=%2Fsalden%3Fx%3D1`; `/` → 303 `/wer`; unknown ID cookie → 303; `/api/kurs` → 401 JSON with `error`.
* `TestPublicPaths` – `/healthz` → `ok\n`; `/wer` renders without nav (`Hauptnavigation` absent); `/static/app.css` 200 with nosniff.
* `TestCreateAndSelectPerson` – POST `/wer/neu` creates person, 303 to `zurueck`, cookie HttpOnly+Lax, activity `Person „Jörg“ hinzugefügt` with the new person as actor; next page shows `Du bist <strong>Jörg</strong>`, active tab, flash `Willkommen!`, `/static/app.css?v=`; duplicate name (case-insensitive) → 422 `gibt es schon`.
* `TestSelectPerson` – `zurueck` sanitization (`//evil.example`, `https://evil.example`, `""` → `/`); unknown id → 422; archived person's cookie → redirect.
* `TestPagesRender` – `/`, `/salden`, `/aktivitaet`, `/einstellungen` render 200 with `aria-current="page"`.
* `TestLoadForeignTemplates` – `Render.Load` with MapFS partial `_partial.html` + page; output contains `<p>Hallo Welt 12,34 €</p>`, `<title>YNAB · Zipfelkasse</title>`, nav; Load with no matches errors.
* `TestRenderTemplateErrorGives500` – exec error → 500 and no `<html` in body.
* `TestCrossOriginProtection` – cross-site POST → 403 with `fremden Seite`; foreign Origin only → 403; same-origin → 303; no headers → 303.
* `TestSafeReturn` – table of 14 inputs (tabs, CRLF, `%09`, `%2F`, backslashes, `/wer?…`, absolute URLs, keeps `/salden?x=1#a`, `/ausgaben/neu?von=%2F`).
* `TestLogsHideMCPSecret` – cross-site POST `/mcp/geheim123` through Wrap → 403, log contains `/mcp/***` not the secret; `logPath` table.
* `TestBodyLimit` – >1 MiB body with known and unknown length → 413 HTML (`zu groß`) and JSON under `/api/`; nothing created; small POST → 303.

### `internal/web/expenses_test.go` (helpers: `newGroup` with Anna/Ben/Cleo, Anna logged in; `g.get/g.post` HTML-unescape bodies; `errorOf` extracts `role="alert">…<`)
* `TestExpenseCreateSplitModes` – equal (cent rotation by expense ID), equal two, shares (empty = 1), percent, amounts → expected shares.
* `TestExpenseCreateFlashAndList` – flash `Ausgabe „Wochenmarkt“ angelegt.`, `Diese Woche`, `Bezahlt von <strong>Anna</strong> für <strong>Anna</strong>, <strong>Ben</strong>, <strong>Cleo</strong>`, `30,00 €`, `Dein Saldo`, `20,00 €`.
* `TestExpenseValidation` – 10 cases → 422 with messages (`Bitte einen Titel angeben.`, `Ungültiger Betrag`, `größer als 0`, `Bitte ein Datum angeben.`, `mindestens eine Person`, `100 %`, `zusammen 30,00 € ergeben`, `Ben: Anteile müssen ganze Zahlen sein`, `genau eine Person`, `Ungültige Währung`); inputs (`notiz` textarea, `value="Mein Titel"`) preserved; nothing saved.
* `TestExpenseEditAndDelete` – edit form prefilled (`value="30,00"`, `Ausgabe bearbeiten`, recurring link); update; history `<del>30,00 €</del> → <ins>45,00 €</ins>`; empty amount → 422; delete → 303; deleted page `Gelöschte Ausgabe` + `<fieldset class="stack" disabled>`; POST to deleted → 409; delete twice → 404; `/ausgaben/999` and `/ausgaben/abc` → 404; not in list.
* `TestExpenseForeignCurrency` – USD via FX (1.25 → 800 cents, `ezb`); manual THB rate; JPY with `kurs_quelle=ezb`; CHF without rate → message; amounts split in USD (667/400/267) and edit form shows `6,00`/`4,00`, `<option value="USD" selected>`, `name="kurs" value="1,5"`; wrong USD sum message contains `10,00 USD`; list shows `10,00 USD` and `8,00 €`.
* `TestExpenseForeignWithoutFX` – FX nil → `Kurs bitte von Hand eintragen`.
* `TestReimbursementFromSuggestion` – `/salden` text `<strong>Ben</strong> schuldet <strong>Anna</strong>`, link with sorted query, `width: 100%`/`width: 50%`; prefilled form (`checked`, `value="Rückzahlung"`, `value="10,00"`, payer selected, only Anna checked); save forces equal; list shows `class="expense reimbursement"` and `<strong>Ben</strong> an <strong>Anna</strong>`.
* `TestHomeSearch` – text search (case/umlaut-insensitive), category and person filters, empty result text, preselected option, `Filter zurücksetzen`, `für <strong>Ben</strong>`.
* `TestExpenseFormRotation` – `data-rotation` = expense ID (edit) / next ID (new).
* `TestNewExpenseDefaults` – today's date, me as payer, active people checked, EUR selected, `<option value="equal" selected>Gleichmäßig`, expense-form.js with `?v=`, archived Cleo absent.
* `TestActivityPage` – `Heute`, created/changed/deleted lines, `Titel: <del>Einkauf</del> → <ins>Einkauf groß</ins>`, link to expense, `<strong>Automatisch</strong>: Kategorie „Regel“ hinzugefügt`, amount only for created/deleted, `geändert.`.
* `TestActivityPaging` – 55 entries: first page has newest 50 + `/aktivitaet?vor=`; second page has rest, no `Ältere anzeigen`.
* `TestExpenseRateWithThousands` – IDR `170.000`/`17.000` → 170000 / 17000; `17.000,5`; rate `0` → 422 `Wechselkurs`.
* `TestExpenseForeignAmountsTieBreak` – remainder cent goes by expense ID over people sorted by ID.
* `TestExpenseForeignAmountsRoundTrip` – amounts in USD shown unchanged in edit form; unchanged save logs nothing.
* `TestExpenseUpdateOnlyRate` – rate-only change saved and shown in history (`1,2501`).
* `TestExpenseUpdateRecurringCollision` – 422 `Für diesen Termin gibt es schon eine Ausgabe dieser Wiederholung.`
* `TestExpenseStaleECBRate` – ECB-marked stale rate replaced by looked-up rate; matching kept; unmarked = manual; no ECB rate for THB → 422 and `name="kurs" value=""`.
* `TestExpenseKeepsSavedECBRate` – unchanged ECB expense keeps old rate though FX changed.

### `internal/web/settings_test.go`
* `TestSettingsGroupName` – links on settings page; rename → 303 `/einstellungen`; `<title>Salden · WG Süd</title>`; blank → 422 (`Namen`); activity `Gruppe umbenannt: „Zipfelkasse“ → „WG Süd“`.
* `TestSettingsParticipants` – list (`value="Ben"`, `das bist du`), create, duplicate 422 with `value="dora"` kept, rename, rename to existing 422, unknown 404, archive with balance 422 `Ben hat noch einen Saldo von -10,00 €`, archive/reactivate, activity texts.
* `TestSettingsCategories` – list, create, empty 422, rename, move up → 303 `/einstellungen/kategorien#kategorie-<id>` + activity `Kategorie „X“ nach oben verschoben`, down, archive (absent from new-expense form), move archived → 404, reactivate, unknown → 404.
* `TestPWA` – manifest JSON fields, icons served as image/png, 3 icon purposes; `/sw.js` text/javascript + `no-cache`, no `caches.`; `/favicon.ico` image/png; apple-touch-icon; layout contains manifest link, apple-touch-icon, `/static/app.js?v=`.
* `TestStaticAssets` – JS/SVG served; app.css contains listed class selectors.
* `TestExpensePeriod` – expense and activity period labels for given dates (incl. Monday-in-previous-month, January → December = `Letzter Monat`).
* `TestFormatHelpers` – `categoryIcon` table cases.
* `TestGroupExpensesRows` – Everyone/Involved/MyBalance/ForNames incl. archived-person edge cases.

### `internal/web/suggest_test.go`
* `TestTitleKey` – normalization cases.
* `TestSuggestCategories` – window of 10, majority, tie → newest, 2/3 word threshold, filler words, word once per title.
* `TestExpenseFormSuggestions` – exact `data-suggest` JSON in the new-expense page.

### `main_test.go`
* `TestAppWiring` – full app: status codes for 17 requests (healthz, wer, `/` with/without cookie, all settings pages incl. other packages, `/api/kurs?waehrung=EUR` 200, `waehrung=` 400, `/mcp/falsch` 404, `/mcp/geheim` 403 for test IP, `/gibtsnicht` 404).
* `TestMCPBesideWrap` – MCP works without cookie, keeps security headers, not blocked by Sec-Fetch-Site, Origin rejected by MCP (403 JSON-RPC), oversized → 413 JSON-RPC, other `/mcp/…` paths 404, secret never logged.
* `TestNextBackup` – 01:00 → same day 03:00; 03:00 → next day; 23:59 → next day.
* `TestHealthURL` – address → URL table; `broken` → error.

### `internal/config/config_test.go`
* `TestFromEnvDefaults` – defaults incl. `data/backups` and CIDR default.
* `TestFromEnv` – all vars set; secret trimmed; BackupDir derived; IP → /32; IPv4-mapped match; IPv6 proxies.
* `TestFromEnvErrors` – bad CIDR, bad prefix length, unknown TZ → error.

---------------------------------------------------------------------------------------------------

## 10. Subtleties a port can easily get wrong

1. **Go 1.22+ ServeMux semantics**
   * `GET /x` also serves `HEAD /x`. 405 is automatic with an `Allow` header listing all methods registered for
     the path (`GET, HEAD`, `POST`, `GET, HEAD, POST`). OPTIONS on a GET route → 405 too.
   * `GET /{$}` matches only `/`. Unknown paths → plain-text 404 (not the German page). `/salden/` → 404,
     `/ausgaben/1/` → 404 (no trailing-slash tolerance).
   * Most specific pattern wins: `GET /ausgaben/neu` beats `GET /ausgaben/{id}`; `POST /ausgaben/neu` beats
     `POST /ausgaben/{id}`. `{id}` matches any single segment (`abc` → handler → 404 page via PathID 0).
   * Path cleaning at the **root** mux: `//salden`, `/a/../salden`, `/./x` → **307** to the clean path, without
     security headers. Subtree redirect: `/mcp` → 307 `/mcp/`; inside Wrap `/static` → 307 `/static/`.
   * Path values are matched on unescaped segments; `r.PathValue` returns the decoded segment.
2. **Redirect codes**: all app redirects are **303 See Other** (also identity redirect for GET). Go adds a tiny
   HTML body only for GET; POST redirects have no body/Content-Type. `http.Redirect` `path.Clean`s the target.
3. **Identity redirect** includes `?zurueck=` only for GET and path ≠ `/`; uses `url.QueryEscape(RequestURI)` (raw
   request URI incl. query, uppercase hex, `/`→`%2F`).
4. **Middleware order** matters: 413 before 403 before 401/303; 403/413 pages lack Me/nav.
5. **CSRF** is header-based only (no tokens): Sec-Fetch-Site first, then Origin vs Host; requests without either pass.
6. **`FormValue` vs `PostFormValue`**: who/settings handlers merge body + URL query (body wins); expense form reads
   body only. Repeated `teil` values. Invalid IDs silently become 0. `ParseInt` accepts `+5`/`007`.
   `ParseForm` error (e.g. bad `%zz` escape, or `;` in query) → 400 only in saveExpense; elsewhere ignored.
7. **Flash cookie** is consumed by *any* rendered page (incl. 422 re-renders and other packages' pages), base64url
   without padding, deleted with `Max-Age=0`.
8. **`wer` cookie `Secure`** depends on TLS or `X-Forwarded-Proto: https` exactly.
9. **Escaping parity**: `+` → `&#43;` in text/attributes; `'` → `&#39;`, `"` → `&#34;`; URL attrs percent-encode
   with **lowercase** hex and `&` → `&amp;`; `javascript:` URLs → `#ZgotmplZ`. The `icon` helper is the only raw HTML.
   `data-suggest` JSON is attribute-escaped (`&#34;`). JSON responses escape `<>&` as `<…`.
10. **Number formatting**: `" €"` uses an ASCII space; negative sign is ASCII `-`; `FormatRate` must not produce
    `1.0e-5`/`17000.0` (Crystal's `Float#to_s` does) – emulate Go `FormatFloat(f,'f',-1,64)` (shortest
    round-trip digits, plain notation) then replace the first `.` with `,`.
11. **Static files**: no ETag/Last-Modified; `Cache-Control` depends only on presence of `v` query; 404 strips it;
    directory listing for `/static/` and `/static/icons/`; `/static/index.html` → 301 `./`; `/static/icons` → 301 `icons/`.
12. **Content-Type**: always set explicitly (no reliance on sniffing) except FileServer which uses extension;
    `http.Error` forces `text/plain; charset=utf-8` + nosniff.
13. **Template errors** produce plain 500 `Interner Fehler` with no partial HTML (render to buffer first).
14. **Manifest JSON** key order is alphabetical (Go map encoding) except the icon objects (struct order).
15. **Period logic**: week starts Monday; `Diese Woche` beats month checks; activity `Heute` includes future
    timestamps; `Gestern` beats `Früher in dieser Woche`.
16. **Unicode**: `strings.Fields`/`unicode.IsSpace` (incl. NBSP U+00A0, U+0085) for name normalization and flash
    titles; `unicode.IsLetter` + `strings.ToLower` in `titleKey` (must match the JS `\p{L}` split);
    `unicode.IsControl` in `safeReturn`.
17. **Balances width** uses integer half-up division; archived people with zero balance hidden; rows sorted by name
    (NOCASE), not by balance.
18. **More links** use `url.Values.Encode` (sorted keys, space → `+`).
19. **`whoSelect` with archived person** → 422 (not redirect); archived cookie holder is treated as anonymous.
20. **Graceful shutdown**: 10 s; background jobs stopped via context and awaited; Shutdown timeout → exit 1.
21. **healthcheck** subcommand reads `ZIPFELKASSE_ADDR` untrimmed and rewrites wildcard hosts to `127.0.0.1`.
22. **Server timeouts**: ReadHeader 10 s, Read 30 s, Write 60 s, Idle 120 s.
