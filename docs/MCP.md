# MCP – Auswertung mit Claude

teilen hat einen eigenen MCP-Server, über den Claude die Ausgaben auswerten kann. Er hat **nur lesende Tools**.
Er läuft unter `/mcp/<MCP_SECRET>`. Ohne `MCP_SECRET` ist er abgeschaltet.

## Tools

| Tool | Wofür |
|---|---|
| `salden` | Saldo je Person und Ausgleichsvorschlag |
| `ausgaben_suchen` | einzelne Ausgaben mit Anteilen, gefiltert nach Zeitraum, Kategorie, Person, Text und Rückzahlungen (ohne/mit/nur), mit Limit |
| `statistik` | Summen nach `kategorie`, `monat`, `person` oder `kategorie_monat`. Entweder Gesamtbeträge oder nur der Anteil einer Person. Rückzahlungen zählen nicht mit |
| `schema` | erklärt Tabellen und Spalten, listet Personen und Kategorien, liefert die CREATE-Statements |
| `sql_abfrage` | ein beliebiges `SELECT`/`WITH` (SQLite), höchstens 500 Zeilen, Abbruch nach 5 s |

Jeder Betrag kommt zweimal: als Text `"1234,56"` und als Cent-Wert (Feld mit der Endung `_cent`).

**Schutz in `sql_abfrage`:** Die Abfrage läuft nicht auf der echten Datenbank. Sie läuft auf einer frischen
In-Memory-Kopie. Der Server hängt die echte Datei per `ATTACH 'file:…?mode=ro'` an, kopiert die freigegebenen Tabellen
in einer Lese-Transaktion und hängt die Datei wieder ab. Danach ist `ATTACH` per `sqlite3_limit` gesperrt und
`PRAGMA query_only` an. Lexikalisch ist nur genau ein `SELECT`/`WITH` erlaubt. Die Abfrage wird zusätzlich als
Unterabfrage eingebettet.

Freigegeben sind participants, categories, expenses, expense_shares, recurring, activity, fx_rates und settings
(ohne `ynab…`-Schlüssel). Die YNAB-Tabellen mit dem Token existieren in der Kopie gar nicht. Neue Tabellen sind erst
sichtbar, wenn sie in `store.MCPTables` stehen.

## Zugang

Es gibt drei Prüfungen, in dieser Reihenfolge:

1. Das Secret im Pfad wird in konstanter Zeit verglichen. Ist es falsch, kommt **404**, und die Antwort verrät nichts.
2. Die Client-IP muss in `MCP_ALLOWED_CIDRS` liegen. Standard ist `160.79.104.0/21`, das ist Anthropic. Sonst
   kommt **403**.
3. Ein nicht leerer `Origin`-Header ergibt **403**. Browser sollen hier nie zugreifen, deshalb funktioniert auch der
   MCP Inspector im Browser nicht.

Bei der Client-IP gilt: Kommt die Verbindung von einer Adresse in `TRUSTED_PROXIES`, zählt `X-Forwarded-For`. Gelesen
wird von rechts, und es zählt die erste Adresse, die selbst kein vertrauenswürdiger Proxy ist. Fehlt der Header, gilt
`X-Real-IP`. In allen anderen Fällen zählt die TCP-Adresse, und Forwarded-Header werden ignoriert.

Jeder Zugriff wird geloggt: IP, Methode, Tool, Status und Dauer. Der Pfad mit dem Secret steht nie im Log.

### Umgebungsvariablen

| Variable | Beispiel |
|---|---|
| `MCP_SECRET` | `openssl rand -hex 32` (nur `[0-9a-f]`, also URL-sicher) |
| `MCP_ALLOWED_CIDRS` | `160.79.104.0/21` (Standard), für das LAN z. B. `160.79.104.0/21,192.168.178.0/24` |
| `TRUSTED_PROXIES` | genau die Adresse des Newt-/Pangolin-Containers als /32, z. B. `172.18.0.5/32` (nicht das ganze Docker-Netz, siehe unten) |

## Pangolin einrichten

1. Öffne die Ressource von teilen, gehe zu **Rules** und aktiviere die Regeln.
2. Lege eine Regel an: Aktion **Bypass Auth**, Match **Path**, Wert `/mcp/*`. Damit kommt Claude ohne Pangolin-Login
   durch. Die App schützt sich mit Secret, IP-Filter und Origin-Prüfung selbst.
3. Stelle `TRUSTED_PROXIES` ein: Starte die App zunächst ohne die Variable und rufe den Endpunkt einmal über die Domain
   auf. Im Log steht dann `mcp: IP nicht erlaubt` mit `remote=<Adresse>` (das ist der Newt-/Traefik-Hop) und
   `x_forwarded_for=[…]`. Alternativ: `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' newt`
   (Containername anpassen). Trage **nur diese eine Adresse als /32** in `TRUSTED_PROXIES` ein, z. B. `172.18.0.5/32`.
   Danach muss `ip=` die echte Client-Adresse zeigen.

   Warum nicht das ganze Docker-Netz (`172.18.0.0/16`)? Jeder Container in diesem Netz dürfte dann
   `X-Forwarded-For` setzen und sich als Anthropic ausgeben – ein kompromittierter Nachbar-Container käme so am
   IP-Filter vorbei. Damit die Adresse nach einem Neustart gleich bleibt, gib dem Newt-Container in seinem
   Compose-File eine feste Adresse (`networks: <netz>: ipv4_address: 172.18.0.5`) oder prüfe sie nach Updates erneut.
4. Prüfe die Header: Traefik in Pangolin setzt `X-Forwarded-For` und `X-Real-Ip`. Steht in `x_forwarded_for` nichts,
   reicht `X-Real-IP`.

## Claude verbinden

**Claude (Web/Desktop):** Gehe zu Einstellungen → Connectors → **Custom Connector hinzufügen** und trage ein:

- Name: `teilen`
- URL: `https://<domain>/mcp/<MCP_SECRET>`
- keine Authentifizierung (kein OAuth)

Die Anfragen kommen dann von Anthropic, also aus `160.79.104.0/21`.

**Claude Code im LAN**, direkt ohne Pangolin:

```sh
claude mcp add --transport http teilen http://heimserver:8080/mcp/<MCP_SECRET>
```

Dafür muss das LAN in `MCP_ALLOWED_CIDRS` stehen. Je nach Docker-Setup kommt statt der LAN-Adresse das Docker-Gateway
an, etwa `172.17.0.1`. Die tatsächliche Adresse steht im Log unter `ip=`.

## Beispielfragen

- „Wer schuldet wem gerade wie viel?“
- „Wie viel habe ich (Robert) 2026 für Restaurants ausgegeben, Monat für Monat?“
- „Was waren die zehn teuersten Ausgaben im Urlaub im August?“
- „Welche Kategorie ist im Vergleich zum Vorjahr am stärksten gestiegen?“
- „Zeig alle Ausgaben in USD mit Kurs.“
- „Wer hat wie viel vorgestreckt und wie viel selbst verbraucht?“

## Test mit curl

Lokal muss die eigene Adresse erlaubt sein, z. B. mit `MCP_ALLOWED_CIDRS=127.0.0.1/32`:

```sh
URL=http://localhost:8080/mcp/$MCP_SECRET

# Legacy-Client (initialize-Handshake)
curl -s $URL -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
curl -s $URL -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"salden","arguments":{}}}'

# Moderner Client (2026-07-28, zustandslos, Pflicht-Header)
META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
curl -s $URL -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: server/discover' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{$META}}"
curl -s $URL -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/call' -H 'Mcp-Name: statistik' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"statistik\",\"arguments\":{\"gruppierung\":\"kategorie\"},$META}}"

# Erwartete Fehler
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/mcp/falsch   # 404
curl -s -o /dev/null -w '%{http_code}\n' $URL                                       # 405 (GET)
```

## Protokoll

Der Server ist „Dual-Era“:

- **Modern (2026-07-28):** zustandslos. Jede Anfrage trägt `_meta.io.modelcontextprotocol/protocolVersion`. Die
  Header `MCP-Protocol-Version`, `Mcp-Method` und bei `tools/call` `Mcp-Name` (auch als `=?base64?…?=`) müssen zum
  Body passen, sonst kommt 400 mit `-32020`. Eine unbekannte Version ergibt 400 mit `-32022` und `data.supported`,
  eine unbekannte Methode 404 mit `-32601`. Unterstützt werden `server/discover`, `tools/list`, `tools/call` und
  `ping`.
- **Legacy (2025-11-25, 2025-06-18, 2025-03-26):** `initialize` handelt die Version aus, `notifications/initialized`
  ergibt 202. Danach folgen `tools/list`, `tools/call` und `ping`. Fehlt der Versions-Header, gilt 2025-03-26.
- Für beide gilt: Antworten kommen nur als `application/json`, ohne SSE und ohne Session-IDs. GET und DELETE ergeben
  405, Notifications 202 ohne Body. Batches werden abgelehnt, und eine Nachricht darf höchstens 1 MB groß sein.
