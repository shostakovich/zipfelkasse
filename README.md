# Zipfelkasse

Zipfelkasse is a port of [Spliit](https://github.com/spliit-app/spliit): a slimmed-down, single-group
rewrite in Go + SQLite for sharing expenses within a household. **The user interface is German.**

## Before you use this

- This is a personal project, built for my own household.
- There is deliberately no login: you just pick who you are. So please do **not** host it publicly on the
  internet. Run it only inside a private network or behind an access layer such as Tailscale, a VPN or
  Cloudflare Zero Trust (or a comparable authenticating reverse proxy, e.g. Pangolin).
- I don't accept pull requests (benevolent dictator and all that), but forks are very welcome. I'd be
  happy if you find it useful!

## What it does

One group, no login ("Wer bist du?" – who are you?), SQLite, a single binary.

- Expenses with title, amount, date, category, payer and notes, split evenly, by shares, by percentage or by
  fixed amounts
- Reimbursements, balances and a settlement suggestion
- Recurring expenses, activity log, search
- Foreign currencies with ECB reference rates (or a manual rate)
- Export as CSV/JSON/OFX, optional sync to [YNAB](https://www.ynab.com/)
- Read-only MCP server for asking an AI about your expenses: [docs/MCP.md](docs/MCP.md)
- Installable as a PWA, works on desktop and phone

Details and design decisions: [docs/PLAN.md](docs/PLAN.md).

## Quick start

Locally (Go 1.26):

```sh
go run .                 # = go run . serve, listens on :8080, DB in ./data/zipfelkasse.db
go test ./... && go vet ./...
```

With Docker:

```sh
docker compose up -d --build
# or
docker build -t zipfelkasse .
docker run -p 8080:8080 -v zipfelkasse-data:/data -e MCP_SECRET=… zipfelkasse
```

The image is based on `scratch` and runs as user `65532`. If you use a bind mount instead of a volume, the
directory must be writable for that user (`chown 65532:65532 ./data`). The container health check runs
`zipfelkasse healthcheck` (checks `GET /healthz`).

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `ZIPFELKASSE_ADDR` | `:8080` | Listen address |
| `ZIPFELKASSE_DB` | `./data/zipfelkasse.db` (container: `/data/zipfelkasse.db`) | SQLite file |
| `ZIPFELKASSE_BACKUP_DIR` | `<DB directory>/backups` | Nightly backup (03:00, `VACUUM INTO`), the last 7 are kept |
| `MCP_SECRET` | empty = MCP off | MCP endpoint at `/mcp/<MCP_SECRET>` |
| `MCP_ALLOWED_CIDRS` | `160.79.104.0/21` | Who may call MCP (comma-separated, CIDR or IP) |
| `TRUSTED_PROXIES` | empty | Reverse proxies (e.g. Pangolin) whose `X-Forwarded-For` counts for MCP |
| `TZ` | container: `Europe/Berlin` | Time zone for "today", backups and timestamps |

## Subcommands

- `zipfelkasse serve` (default) – starts the server
- `zipfelkasse healthcheck` – exit code 0 if `GET /healthz` on `ZIPFELKASSE_ADDR` answers with 200
