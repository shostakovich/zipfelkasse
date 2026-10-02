# Plan: „Zipfelkasse“ – Spliit-Nachbau in Go

## Context

Nachbau von [Spliit](https://github.com/spliit-app/spliit) für den eigenen Heimserver. Es gibt **eine
Gruppe** und **keinen Beleg-Scan**. Weitere Ziele:
- möglichst wenig Wartung und externe Abhängigkeiten
- nutzbar auf Desktop und Handy
- Auswertung per KI über MCP
- YNAB aus der eigenen Sicht befüllen

Läuft in einem Docker-Container hinter Pangolin. Statt einer Anmeldung sagt man der App nur, wer man ist.

Der Ordner `/Users/shostakovich/Code/teilen` ist leer, es gibt keinen Bestandscode.

## Festgelegte Entscheidungen

| Thema | Entscheidung |
|---|---|
| Sprache | Go 1.26, nur die Standardbibliothek. **Einzige Abhängigkeit:** `modernc.org/sqlite` (reines Go, ohne CGO) |
| Frontend | Der Server rendert das HTML mit `html/template`. Dazu kommen eine CSS-Datei und wenig Vanilla-JS. Es gibt keinen Build-Step, alles wird per `embed` ins Binary gepackt, und die App ist als PWA installierbar |
| DB | SQLite im WAL-Modus in `/data/zipfelkasse.db`. Migrationen sind eingebettete `.sql`-Dateien und werden über `PRAGMA user_version` gesteuert, ohne Migrations-Bibliothek |
| Geld | Beträge sind Integer-Cent. Rundungsreste werden nach der Methode des größten Rests verteilt, deterministisch |
| Identität | Cookie `wer` mit der Teilnehmer-ID. Auswahlseite beim ersten Besuch, oben steht „Du bist X · wechseln“ |
| Features | Ausgaben (Titel, Betrag, Datum, Kategorie, Zahler, Notiz) und Aufteilen gleichmäßig, nach Anteilen, Prozent oder festen Beträgen. Dazu Rückzahlungen, Salden, ein Ausgleichsvorschlag (greedy), Suche, Export als CSV/JSON, **wiederkehrende Ausgaben**, **Aktivitätsprotokoll** und **Fremdwährungen**. Die Oberfläche ist nur auf Deutsch |
| Nicht dabei | Mehrere Gruppen, Beleg-Scan, Belege anhängen, Login |
| Fremdwährung | EZB-Referenzkurse (`eurofxref-daily.xml`, `eurofxref-hist.zip`, gelesen mit `encoding/xml` und `archive/zip`) werden in SQLite zwischengespeichert. Es gilt der Kurs vom Ausgabedatum, sonst der letzte Bankarbeitstag davor. Der Kurs lässt sich von Hand überschreiben, etwa für den echten Kartenkurs. Währungen, die die EZB nicht führt, bekommen einen manuellen Kurs |
| Löschen | Soft-Delete (`deleted_at`), damit der YNAB-Sync Löschungen weitergeben kann |
| YNAB | Über die API mit Personal Access Token, für jede Person einzeln. Modell **Verrechnungskonto „Geteilt“** im Budget: Die App schreibt nur *meinen Anteil* jeder Ausgabe als Ausgang mit der zugeordneten YNAB-Kategorie (PATCH bei Änderung, DELETE bei Löschung). Bank-Zahlungen für geteilte Ausgaben und Rückzahlungen markiert man in YNAB als Transfer ↔ „Geteilt“. Danach gilt: Saldo „Geteilt“ = Saldo in der App. Es gibt ein Startdatum, ab dem synchronisiert wird. **Fallback:** dieselben Buchungen als OFX-/CSV-Export |
| KI | Ein eigener MCP-Server ohne SDK (JSON-RPC 2.0 über Streamable HTTP, Antworten nur als JSON). Er hat ausschließlich Lese-Tools |
| MCP-Zugang | Pfad `/mcp/{MCP_SECRET}`, keine Auth. Nur `MCP_ALLOWED_CIDRS` darf zugreifen, Standard ist `160.79.104.0/21` (Anthropic). Ausnahme: Kommt die Anfrage von einer Adresse in `TRUSTED_PROXIES` (Pangolin), zählt die Client-IP aus `X-Forwarded-For`. In Pangolin braucht es eine Regel „Bypass Auth“ für `/mcp/*` |
| Backup | Ein `VACUUM INTO` pro Nacht nach `/data/backups/`, die letzten 7 Stände bleiben erhalten |
| Docker | Multi-Stage-Build: `golang:1.26-alpine` (CGO_ENABLED=0) baut, das Ergebnis läuft auf `scratch`. Mitkopiert werden die CA-Zertifikate, die Zeitzonen kommen per `import _ "time/tzdata"`. Der Healthcheck läuft über den Unterbefehl `zipfelkasse healthcheck` |

## Architektur / Paketstruktur

```
main.go                     Config (ENV), Verdrahtung, Unterbefehle (serve, healthcheck)
internal/domain/            reine Logik: Money, Split, Salden, Ausgleich, Wiederholungsregeln (ohne IO)
internal/store/             SQLite, migrations/*.sql (embed), Queries, Activity-Log, Backup
internal/web/               Handler, templates/*.html, static/ (css, js, manifest, sw.js, icons)
internal/fx/                EZB-Client und Kurs-Cache
internal/recurring/         legt fällige Instanzen an (beim Start und stündlich)
internal/ynab/              API-Client (net/http), Sync-Worker, Kategorie-Mapping
internal/export/            CSV, JSON, OFX
internal/mcp/               JSON-RPC-Handler, Tools, CIDR-/Proxy-Filter
Dockerfile, compose.yaml, docs/PLAN.md, README.md
```

Jedes Feature-Paket stellt `Register(mux *http.ServeMux, deps)` bereit. `main.go` ruft alle `Register`
auf. Dadurch berühren parallele Arbeitspakete nur ihr eigenes Paket.

### Datenmodell (Migration 001)

- `participants(id, name, archived_at)`
- `categories(id, name, archived_at)` mit Standard-Kategorien als Seed
- `expenses`:
  - Grunddaten: `id, title, date, category_id, paid_by, notes`
  - Typ: `is_reimbursement, split_mode`
  - Betrag: `amount_cents` (EUR), `original_amount_minor, original_currency, fx_rate, fx_source`
  - Verwaltung: `recurring_id, created_at, updated_at, deleted_at`
- `expense_shares(expense_id, participant_id, weight, amount_cents)`. `weight` hängt vom Modus ab (Anteile, Basispunkte oder Cent). `amount_cents` ist berechnet und gespeichert, das vereinfacht SQL über MCP
- `recurring(id, template_json, frequency [weekly|monthly|yearly], next_date, active)`
- `activity(id, at, actor_id, action, expense_id, details_json)`
- `fx_rates(date, currency, rate)`
- `ynab_config(participant_id, token, budget_id, account_id, start_date)`, `ynab_category_map(participant_id, category_id, ynab_category_id)`
- `ynab_sync(expense_id, participant_id, ynab_txn_id, synced_hash, synced_at, last_error)`
- `settings(key, value)` (Gruppenname, Standardwährung)

### Seiten

- `/` – Ausgaben nach Monat, Suche, oben der eigene Saldo
- `/ausgaben/neu`, `/ausgaben/{id}` – Formular mit Live-Vorschau der Aufteilung und Währungsumrechnung (Vanilla-JS)
- `/salden` – Salden, Ausgleichsvorschlag, Knopf „als erstattet eintragen“
- `/aktivitaet`
- `/einstellungen` – Teilnehmer, Kategorien, Wiederkehrend, YNAB (Token, Budget/Konto per API wählen, Kategorie-Mapping, „jetzt synchronisieren“, Status/Fehler), Export
- Formulare arbeiten nach dem Muster POST → Redirect

### MCP-Tools

- `salden`
- `ausgaben_suchen` (Zeitraum, Kategorie, Person, Text)
- `statistik` (gruppiert nach Kategorie, Monat oder Person)
- `schema`
- `sql_abfrage` (eigene Verbindung mit `mode=ro` und `PRAGMA query_only`, Zeilenlimit, Timeout)

Unterstützte Methoden: `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`.

## Arbeitsplan und Subagenten

**Phase 0 – Fundament (ich selbst, nacheinander)**
1. Git einrichten: `git init` (im Sandbox-Lauf scheiterte das an „Operation not permitted“, also mit Freigabe erneut ausführen). Dann `go mod init`.
2. Diesen Plan nach `docs/PLAN.md` kopieren. Er ist die Briefing-Grundlage für alle Agenten.
3. Bauen:
   - `internal/domain`, testgetrieben: Split-Modi, Rundung, Salden, Ausgleich, Berechnung des nächsten Termins
   - `internal/store`: Schema, Basis-Queries, Activity-Log
   - `main.go`, Layout-Template, Identitäts-Middleware, CSS-Grundgerüst, Dockerfile
   - Stub-`Register` für alle Pakete

   Ergebnis: Das Projekt kompiliert, die Tests sind grün, und man kann in der App eine Person auswählen.
4. Commit.

**Phase 1 – parallel, jeweils `isolation: "worktree"`**

| Agent | Paket(e) | Inhalt |
|---|---|---|
| A | `internal/web` | Ausgaben-CRUD, Liste/Suche, Salden-Seite, Rückzahlungen, Teilnehmer-/Kategorie-Verwaltung, Aktivitätsseite, PWA (Manifest, SW, Icons) |
| B | `internal/fx`, `internal/recurring` | EZB-Client mit Cache, Tests gegen XML-Fixtures. Erzeugung der wiederkehrenden Ausgaben. Endpunkt `GET /api/kurs?waehrung=&datum=` für das Formular |
| C | `internal/ynab`, `internal/export` | API-Client, Sync (Anlegen/Ändern/Löschen, Milliunits, Fehlerstatus), YNAB-Einstellungsseite, OFX-/CSV-/JSON-Export. Tests mit `httptest`-Fake-YNAB |
| D | `internal/mcp` | JSON-RPC, Tools, schreibgeschützte Verbindung, Filter für CIDR und Trusted Proxy. Tests mit `httptest` |

Jeder Agent bekommt diese Vorgaben:
- `docs/PLAN.md` und seinen Abschnitt daraus
- **keine neuen Abhängigkeiten**
- Änderungen nur im eigenen Paket. Gemeinsame Store-Queries kommen in eine eigene Datei `internal/store/<paket>.go`
- `go test ./...` und `go vet ./...` müssen grün sein
- am Ende ein Commit im Worktree

**Phase 2 – Integration (ich selbst)**

Die Worktrees werden gemergt:
- Formular-Hooks einbinden: Währungsfeld (B) und Wiederkehrend-Option (B) ins Formular von A
- den Sync-Trigger (C) an Speichern/Löschen hängen

Danach Review mit `/code-review` und Ende-zu-Ende-Test (siehe unten).

## Verifikation

1. `go vet ./... && go test ./...`: Domain-Tabellentests (Rundung, alle Split-Modi, Ausgleich), Store-Tests mit `:memory:`, Handler-Tests mit `httptest`
2. `docker build -t zipfelkasse . && docker run -p 8080:8080 -v zipfelkasse-data:/data -e MCP_SECRET=… zipfelkasse` prüfen: Das Image ist ca. 20 MB groß und der Healthcheck ist grün
3. Im Browser-Pane `localhost:8080`, dann:
   - Person wählen
   - Ausgaben in allen Split-Modi anlegen, auch eine in USD
   - Salden und Vorschlag prüfen, eine Rückzahlung eintragen
   - Aktivitätslog ansehen
   - Handy-Viewport (375 px) prüfen
4. MCP: `curl` mit `initialize` / `tools/list` / `tools/call salden` gegen `/mcp/<secret>`. Erwartet wird ein 403 bei falscher IP oder falschem Secret. Danach `claude mcp add --transport http zipfelkasse http://localhost:8080/mcp/<secret>` (lokal mit erweiterter CIDR) und echte Fragen stellen
5. YNAB: gegen ein Test-Budget mit Konto „Geteilt“ prüfen:
   - Ausgabe anlegen, ändern, löschen → Buchung erscheint, ändert sich bzw. verschwindet
   - Saldo „Geteilt“ = Saldo in der App
   - OFX-Datei lässt sich in YNAB importieren
6. Wiederkehrend: Eine Regel mit `next_date` in der Vergangenheit erzeugt beim Start die fälligen Instanzen, ohne Duplikate beim Neustart

## Offen, aber unkritisch (wird bei der Umsetzung geprüft)

- Pangolin-Regelsyntax für die Bypass-Regel auf `/mcp/*` und welche Header Pangolin weitergibt (`X-Forwarded-For` / `X-Real-IP`). Das wird beim Setup verifiziert und im README dokumentiert
- Die aktuelle MCP-Protokollversion wird beim Bau von Paket D in der Spec nachgeschaut

## Schnittstellen (Stand Phase 0)

Briefing für die Agenten in Phase 1. Alles hier ist **Vertrag**: Signaturen nicht ändern, nur ergänzen.
`main.go`, `internal/store/store.go`, `internal/store/migrations/001_init.sql`, `internal/web/deps.go`,
`internal/web/render.go` und `internal/web/identity.go` sind gemeinsame Dateien. Feature-Agenten fassen
sie nicht an; Agent A darf in `internal/web` ergänzen, aber keine exportierte Signatur, keinen Template-Block
und keine CSS-Klasse aus dieser Liste brechen.

### Arbeitsumgebung

- Go-Befehle mit `GOPROXY=off` und in der Sandbox zusätzlich `GOCACHE=$TMPDIR/gocache`
  (der normale Build-Cache ist dort nicht beschreibbar).
- In der Sandbox kann man keine Ports öffnen. **Handler-Tests nie mit `httptest.NewServer`**, sondern den
  Handler direkt aufrufen: `rec := httptest.NewRecorder(); h.ServeHTTP(rec, req)` (Vorlage:
  `internal/web/web_test.go`, `main_test.go`). Fake-Server für YNAB/EZB entsprechend als `http.RoundTripper`
  bzw. `http.Client{Transport: handlerTransport}` bauen.
- `main_test.go` (`TestAppWiring`) verdrahtet die komplette App und ruft jede Route einmal auf. Wer neue
  Routen anlegt, prüft damit Muster-Konflikte (der Mux panict bei Konflikten).

### Import-Richtung

```
domain  ←  store  ←  web  ←  fx, recurring, ynab, export, mcp  ←  main
config  ←  web (Deps.Config), mcp, main
```
`web` importiert **keines** der Feature-Pakete. Querbezüge laufen über `web.Deps` (z. B. `Deps.FX`) und
den Store-Change-Hook.

### `web.Deps` und Verdrahtung

```go
type Deps struct {
    Config config.Config   // Addr, DBPath, BackupDir, MCPSecret, MCPAllowedCIDRs/TrustedProxies []netip.Prefix, Location
    Store  *store.Store
    Render *web.Renderer
    Log    *slog.Logger
    FX     web.FXRater     // = *fx.Service, von main gesetzt; in Tests ggf. nil
}
func (d Deps) Today() time.Time          // heutiges Datum in Config.Location (00:00 UTC, siehe domain)
func web.WriteJSON(w, status int, v any)
```

`main.newApp` macht genau das (Reihenfolge fest):

| Paket | Konstruktor / Registrierung | Hintergrund (eigene Goroutine, blockiert bis ctx done) |
|---|---|---|
| web | `web.Register(mux, d)`, am Ende `web.Wrap(d, mux)` | – |
| fx | `fx.New(d) (*fx.Service, error)`, danach `d.FX = svc`; `svc.Register(mux)` | `svc.Run(ctx)` (z. B. täglicher EZB-Abruf) |
| recurring | `recurring.New(d) (*recurring.Service, error)`; `svc.Register(mux)` | `svc.Run(ctx)`: `Materialize` sofort, dann stündlich |
| ynab | `ynab.New(d) (*ynab.Service, error)` – registriert `Trigger` am Store-Hook; `svc.Register(mux)` | `svc.Run(ctx)`: arbeitet die Queue ab |
| export | `export.Register(mux, d) error` | – |
| mcp | `mcp.Register(mux, d) error` (ohne `MCP_SECRET` no-op) | – |

Weitere fest vorgesehene Methoden: `fx.Service.Rate(ctx, currency, date) (domain.FXRate, error)`,
`recurring.Service.Materialize(ctx, today time.Time) (int, error)`, `ynab.Service.Trigger(expenseID int64)`
(blockiert nie). Wer zusätzliche Abhängigkeiten braucht, holt sie aus `Deps` oder baut sie im eigenen
`New`/`Register` (z. B. HTTP-Client mit Timeout im Service-Struct) – nicht in `main.go`.

### Routen

Muster **immer mit Methode** (`"GET /pfad"`, `"POST /pfad/{id}"`), keine Catch-alls wie `"/"` oder `"GET /"`
(kollidieren mit fremden Mustern). Ausnahme: `mcp` registriert `"/mcp/{secret}"` ohne Methode.

| Paket | Präfix / Routen |
|---|---|
| web (A) | `GET /{$}`, `/ausgaben/…`, `/salden`, `/aktivitaet`, `/einstellungen`, `/einstellungen/teilnehmer…`, `/einstellungen/kategorien…`, `/wer`, `/wer/neu`, `/static/…`, `/healthz`, `/manifest.webmanifest`, `/sw.js` |
| fx (B) | `GET /api/kurs`, `/einstellungen/kurse…` |
| recurring (B) | `/einstellungen/wiederkehrend…` |
| ynab (C) | `/einstellungen/ynab…` |
| export (C) | `/export…` (z. B. `GET /export/ausgaben.csv`, `…/ausgaben.json`, `…/ynab.ofx`) |
| mcp (D) | `/mcp/{secret}` |

Die Seite `/einstellungen` verlinkt schon auf Teilnehmer, Kategorien, `/einstellungen/wiederkehrend`,
`/einstellungen/kurse`, `/einstellungen/ynab` und `/export`. Formulare: POST → `http.Redirect(…, 303)`,
Erfolgsmeldung vorher mit `web.SetFlash(w, "Gespeichert.")`.

**Identität** (`web.Wrap`): Cookie `wer` = Teilnehmer-ID. `web.Me(r.Context()) (store.Participant, bool)`
liefert die Person; hinter der Middleware ist sie auf allen nicht-öffentlichen Pfaden gesetzt (archivierte
Personen gelten als „niemand“). Ohne Person: `GET` → 303 auf `/wer?zurueck=<pfad>`, `/api/…` → 401 JSON
`{"error": "…"}`. Öffentlich (ohne Person erreichbar): `/wer`, `/wer/neu`, `/healthz`, `/static/…`, `/mcp/…`,
`/manifest.webmanifest`, `/sw.js`, `/favicon.ico`. Tests anderer Pakete setzen die Person mit
`web.WithMe(ctx, p)`. Security-Header für alles; **CSP erlaubt keine Inline-Skripte** (`script-src 'self'`),
Inline-Styles sind erlaubt. JS daher als Datei: web unter `/static/`, Feature-Pakete über eine eigene
`GET`-Route unter ihrem Präfix aus ihrem embed.FS.

### Renderer (gemeinsames Layout)

```go
//go:embed templates/*.html
var templatesFS embed.FS

pages, err := d.Render.Load(templatesFS, "templates/*.html")    // in New/Register, einmal
pages.Render(w, r, http.StatusOK, "ynab.html", web.Page{
    Title: "YNAB",            // <title>Titel · Gruppenname</title>
    Nav:   web.NavSettings,   // aktiver Tab: NavExpenses | NavBalances | NavActivity | NavSettings
    Error: "",                // rote Meldung oben (z. B. ValidationError.Msg), Status dann 422
    Data:  myData,            // im Template als .Data
})
d.Render.Error(w, r, http.StatusNotFound, "Ausgabe nicht gefunden.") // Fehlerseite im Layout
```

- Jede Seitendatei definiert `{{define "content"}}…{{end}}`, optional `{{define "head"}}` (in `<head>`) und
  `{{define "scripts"}}` (vor `</body>`, z. B. `<script src="/einstellungen/ynab/ynab.js" defer></script>`).
- Dateien, deren Name mit `_` beginnt, sind Partials und stehen allen Seiten desselben `Load` zur Verfügung.
- Template-Daten (`.`): `.Title`, `.Nav`, `.Error`, `.Data`, `.Me` (`*store.Participant`, nil ohne Person),
  `.GroupName`, `.Flash`, `.Path`.
- Template-Funktionen überall: `eur` (Cent → „1.234,56 €“), `amountInput` (Cent → „1234,56“ für `<input>`),
  `money` (minor, Währung → „12,34 USD“), `percent` (Basispunkte → „33,33 %“), `date` (→ „02.10.2026“),
  `isoDate` (→ „2026-10-02“ für `<input type=date>`), `dateTime` (Zeitstempel in Ortszeit),
  `signClass` (int64 → `positive`/`negative`/""), `static` („app.css“ → versionierte URL), `dict` (k, v, … → map für Partials).
- Render puffert: Template-Fehler → 500 ohne halbe Seite. Gerendert wird mit `Cache-Control: no-store`.

### CSS (`internal/web/static/app.css`)

Design-Tokens im shadcn/ui-Stil (neutral), je Light + Dark (`prefers-color-scheme`), als HSL-Komponenten:
`hsl(var(--token))`. Tokens: `--background --foreground --card --card-foreground --popover
--popover-foreground --primary --primary-foreground --secondary --secondary-foreground --muted
--muted-foreground --accent --accent-foreground --destructive --destructive-foreground --success --border
--input --ring --radius --positive --negative`, dazu `--font-sans`, `--touch` (Mindesthöhe Touch-Ziele).

Klassen: Layout `.container .main .site-header .site-header-inner .brand .whoami .tabs` (Tab-Leiste,
aktiver Tab per `aria-current="page"`); Karten `.card .card-header .card-title .card-description
.card-content .card-footer`; Buttons `.btn` + `.btn-primary .btn-secondary .btn-outline .btn-ghost
.btn-destructive`, Größen `.btn-sm .btn-lg .btn-block`; Formulare `.form .field .field-error .help`
(Inputs/Selects/Textareas sind ohne Klasse gestylt); Tabellen `.table-wrap` + `table/th/td`; Meldungen
`.alert .alert-success .alert-destructive`; Helfer `.link-list .stack .stack-sm .row .muted .amount
.positive .negative .sr-only`. Agent A portiert die Spliit-Optik und darf das CSS ausbauen; Feature-Pakete
nutzen nur diese Klassen (kein eigenes CSS).

### Store

- Eigene Queries kommen in **`internal/store/<paket>.go`** (`fx.go`, `recurring.go`, `ynab.go`, `export.go`,
  `mcp.go`; A ggf. `web.go`) plus Tests in `<paket>_test.go`. Dort stehen zur Verfügung: `s.db`,
  `s.inTx(ctx, func(*sql.Tx) error)`, `s.nowString()` (RFC 3339 UTC), `s.Path()`, Helfer `formatDate`,
  `parseDate`, `parseTime`, `nullInt`, `placeholders(n)`, `invalid(fmt, …)` (→ `domain.ValidationError`),
  `isUniqueViolation`, `checkAffected`. Tests: `newTestStore(t)` (`:memory:`), `newFixture(t)` (Anna, Ben,
  Cleo, Kategorie Lebensmittel) aus `store_test.go`.
- **Schema ist komplett** (alle Tabellen aus dem Datenmodell, siehe `001_init.sql` mit Kommentaren).
  Ergänzungen zum Plan: `participants.created_at`, `categories.position`, `recurring.start_date` (Anker),
  `recurring.created_by/created_at/updated_at`, `fx_rates.source` ('ezb'|'manuell'), `ynab_config.enabled/updated_at`.
  Fremdwährungsfelder in `expenses` sind NOT NULL (EUR: original = amount, rate 1, source '').
  Falls doch eine Migration nötig wird: nur additiv, eigener Nummernbereich (A 010–019, B 020–029,
  C 030–039, D 040–049); Dev-Datenbanken danach neu anlegen.
- Konventionen: Beträge `int64` Cent; Kalenderdaten `time.Time` 00:00 UTC (`domain.DateOf`), gespeichert
  'YYYY-MM-DD'; Zeitstempel RFC 3339 UTC; nichts Referenziertes wird hart gelöscht.
- `store.Open(path)`: WAL, `foreign_keys=ON`, `busy_timeout=5000`, `synchronous=NORMAL`, `BEGIN IMMEDIATE`;
  `":memory:"` = eine einzige Verbindung (also innerhalb von `inTx` **nur `tx`** benutzen, sonst Deadlock).
- Fehler: `store.ErrNotFound`; Eingabefehler sind `domain.ValidationError` (deutsche `.Msg`, direkt anzeigen).

API (Auszug, alles `ctx`-first):

| Bereich | Methoden |
|---|---|
| Personen | `ListParticipants(includeArchived)`, `GetParticipant(id)`, `CreateParticipant(name) (id)`, `RenameParticipant(id, name)`, `SetParticipantArchived(id, bool)` |
| Kategorien | `ListCategories(includeArchived)`, `GetCategory`, `CreateCategory`, `RenameCategory`, `SetCategoryArchived` |
| Ausgaben | `CreateExpense(actorID, ExpenseInput) (id)`, `UpdateExpense(actorID, id, ExpenseInput)`, `DeleteExpense(actorID, id)` (soft), `GetExpense(id)` (auch gelöschte, `e.Deleted()`), `ListExpenses(ExpenseFilter{Text, CategoryID, ParticipantID, From, To, Limit, Offset})` (ohne gelöschte, neueste zuerst) |
| Salden | `BalanceEntries() []domain.Entry`, `Balances() map[participantID]cent` (positiv = bekommt Geld) |
| Aktivität | `ListActivity(ActivityFilter{ExpenseID, BeforeID, Limit})`, `AddActivity(actorID, action, expenseID, ActivityDetails)` |
| Settings | `GetSetting(key)` (ErrNotFound), `SetSetting(key, value)`, `GroupName()`; Schlüssel `group_name`, `default_currency`, eigene mit Präfix (`ynab.…`) |
| Hook | `OnExpenseChange(func(store.ExpenseChange{ExpenseID, Action}))` |
| Betrieb | `Ping`, `SchemaVersion`, `Backup(dir, keep) (path)`, `RotateBackups(dir, keep)`, `Path`, `Close` |

`store.ExpenseInput`: `Title, Date, CategoryID (0 = keine), PaidBy, Notes, IsReimbursement, SplitMode,
AmountCents (immer EUR, > 0), Parts []domain.Part{ParticipantID, Weight}, OriginalAmountMinor,
OriginalCurrency ("" / "EUR" = keine Fremdwährung), FXRate, FXSource, RecurringID` (JSON-Tags vorhanden).
Der Store berechnet die Cent-Anteile selbst per `domain.Split`. `store.Expense` bettet `ExpenseInput` ein
(Parts aus den gespeicherten Gewichten, also direkt an `UpdateExpense` zurückgebbar) und hat zusätzlich
`ID, Shares []domain.Share, CategoryName, PaidByName, CreatedAt, UpdatedAt, DeletedAt`, Methoden
`Deleted()`, `IsForeign()`, `ShareOf(participantID) int64`.
- **Rückzahlung** = `IsReimbursement: true`, `PaidBy` zahlt an genau eine andere Person `Parts[0]`
  (SplitMode wird `equal`).
- **Activity**: Create/Update/Delete schreiben automatisch einen Eintrag (`expense_created|updated|deleted`)
  mit `actorID` (0 = System, z. B. Wiederholung). Details: `Title`, `AmountCents`, bei Update `Changes
  []FieldChange{Field, Old, New}` (deutsche Feldnamen, fertig formatierte Werte). Ein Update ohne Änderung
  protokolliert nichts und löst keinen Hook aus. `RecurringID` bleibt bei Update unverändert.
- **Change-Hook**: wird nach erfolgreichem Commit synchron im Goroutine des Aufrufers aufgerufen, auch für
  Löschungen. Callbacks dürfen nicht blockieren (nur einreihen) und keinen Request-Context weiterverwenden.
  Registrierung nur beim Start (in `New`).

### domain

`ValidationError{Msg}`; Geld: `FormatCents`, `FormatCentsInput`, `ParseCents` („12,34“, „12.34“,
„1.234,56 €“), `ParseMinor(s, decimals)`, `FormatMoney(minor, currency)`, `CurrencyDecimals(cur)`,
`ToEURCents(minor, currency, rate)`, `FormatBasisPoints`, `ParseBasisPoints`, `MaxAmountCents`.
Aufteilung: `SplitMode` (`equal|shares|percent|amount`, `.Valid()`, `.Label()`), `SplitModes`,
`Split(mode, totalCents, []Part, rotation) ([]Share, error)` (größter Rest; bei Gleichstand rotiert der Extra-Cent
mit `rotation` = Ausgaben-ID reihum über die gleichrangigen Personen; Ergebnis nach ID sortiert). Salden: `Entry{PaidBy, AmountCents, Shares}`, `Balances([]Entry)`, `Settle(map) []Transfer{From, To,
AmountCents}`. Daten: `DateLayout`, `DateOf`, `Today(loc)`, `ParseDate` („2026-10-02“ / „02.10.2026“),
`FormatDate`. Wiederholung: `Frequency` (`weekly|monthly|yearly`, `.Valid()`, `.Label()`), `Frequencies`,
`Occurrence(f, anchor, n)`, `NextDate(f, anchor, after)` (erster Termin strikt nach `after`, immer vom Anker
aus: 31.01. → 28.02. → 31.03.). Kurse: `FXRate{Currency, Date, Rate, Source}`, `FXSourceECB` ("ezb"),
`FXSourceManual` ("manuell"), `FXSourceFixed` ("fest").

### Paket-spezifisch

- **fx (B)**: `Rate` liefert den Kurs im EZB-Format (Fremdwährung pro 1 EUR) vom Datum oder dem letzten
  Bankarbeitstag davor; manuelle Kurse (`fx_rates.source = 'manuell'`) haben Vorrang. EUR → Rate 1,
  Source "fest". `GET /api/kurs?waehrung=USD&datum=2026-10-01` (Datum optional = heute, auch „01.10.2026“)
  → 200 `{"currency","date","rate","source"}` (`fx.RateResponse`), Fehler → 4xx/5xx `{"error": "…"}`.
  Phase 2: A rechnet serverseitig `AmountCents = domain.ToEURCents(minor, cur, rate.Rate)` über `d.FX`.
- **recurring (B)**: Tabelle `recurring` (`template_json` = `store.ExpenseInput` als JSON, Datum darin
  ignoriert; `start_date` = Anker; `next_date` = nächster fälliger Termin; `active`). `Materialize(ctx, today)`
  legt für jeden Termin ≤ today per `store.CreateExpense(ctx, 0, in)` mit `in.Date = Termin`,
  `in.RecurringID = id` an und setzt `next_date = domain.NextDate(freq, start_date, Termin)`.
  `store.ErrRecurringExists` (Unique-Index `recurring_id, date`) heißt „gibt es schon“ → überspringen.
  Phase 2: Option „wiederkehrend“ im Formular von A ruft eine Store-Funktion aus `store/recurring.go`.
- **ynab (C)**: Tabellen `ynab_config` (pro Person), `ynab_category_map`, `ynab_sync`. `New` hängt `Trigger`
  an den Hook; `Run` synchronisiert (Anlegen/PATCH/DELETE; `GetExpense` liefert auch gelöschte, mein Anteil =
  `e.ShareOf(participantID)`). Einstellungen beziehen sich auf `web.Me(ctx)`.
- **export (C)**: nutzt `ListExpenses`/`GetExpense`; Downloads mit `Content-Disposition: attachment`.
- **mcp (D)**: `d.Config.MCPSecret`, `d.Config.MCPAllowedCIDRs`, `d.Config.TrustedProxies` (`[]netip.Prefix`),
  Helfer `config.ContainsAddr(prefixes, addr)`. Die schreibgeschützte Verbindung baut D in `store/mcp.go`
  aus `s.Path()` (z. B. `file:<pfad>?mode=ro` + `_pragma=query_only(1)`, selbst verifizieren); `:memory:` ist dafür ungeeignet, Tests
  nehmen eine Temp-Datei (`t.TempDir()`).
