# Zipfelkasse

Ausgaben in einer Gruppe teilen – ein schlanker Nachbau von [Spliit](https://github.com/spliit-app/spliit)
für den eigenen Heimserver. Eine Gruppe, keine Anmeldung („Wer bist du?“), SQLite, ein einziges Binary.
Details und Entscheidungen: [docs/PLAN.md](docs/PLAN.md).

## Starten

Lokal (Go 1.26):

```sh
go run .                 # = go run . serve, lauscht auf :8080, DB in ./data/zipfelkasse.db
go test ./... && go vet ./...
```

Mit Docker:

```sh
docker compose up -d --build
# oder
docker build -t zipfelkasse .
docker run -p 8080:8080 -v zipfelkasse-data:/data -e MCP_SECRET=… zipfelkasse
```

Das Image basiert auf `scratch` und läuft als Benutzer `65532`. Bei einem Bind-Mount statt eines
Volumes muss das Verzeichnis für diesen Benutzer beschreibbar sein (`chown 65532:65532 ./data`).
Der Container-Healthcheck ruft `zipfelkasse healthcheck` auf (prüft `GET /healthz`).

## Umgebungsvariablen

| Variable | Standard | Bedeutung |
|---|---|---|
| `ZIPFELKASSE_ADDR` | `:8080` | Listen-Adresse |
| `ZIPFELKASSE_DB` | `./data/zipfelkasse.db` (Container: `/data/zipfelkasse.db`) | SQLite-Datei |
| `ZIPFELKASSE_BACKUP_DIR` | `<DB-Verzeichnis>/backups` | Nächtliches Backup (03:00, `VACUUM INTO`), die letzten 7 bleiben |
| `MCP_SECRET` | leer = MCP aus | MCP-Endpunkt unter `/mcp/<MCP_SECRET>` |
| `MCP_ALLOWED_CIDRS` | `160.79.104.0/21` | Wer MCP aufrufen darf (Komma-getrennt, CIDR oder IP) |
| `TRUSTED_PROXIES` | leer | Reverse-Proxies (z. B. Pangolin), deren `X-Forwarded-For` für MCP gilt |
| `TZ` | Container: `Europe/Berlin` | Zeitzone für „heute“, Backups und Zeitstempel |

## Unterbefehle

- `zipfelkasse serve` (Standard) – startet den Server
- `zipfelkasse healthcheck` – Exit-Code 0, wenn `GET /healthz` auf `ZIPFELKASSE_ADDR` mit 200 antwortet
