# Zipfelkasse

Zipfelkasse shares expenses within a household: a slimmed-down, single-group app in Crystal + SQLite,
inspired by [Spliit](https://github.com/spliit-app/spliit). **The user interface is German.**

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
- MCP server for asking an AI about your expenses and letting it enter new ones: [docs/MCP.md](docs/MCP.md)
- Installable as a PWA, works on desktop and phone

## Quick start

Locally (Crystal 1.21, SQLite 3.46 or newer):

```sh
shards install
shards build                     # bin/zipfelkasse
bin/zipfelkasse                  # = serve, listens on :8080, DB in ./data/zipfelkasse.db
```

With Docker:

```sh
docker compose up -d --build
# or
docker build -t zipfelkasse .
docker run -p 8080:8080 -v zipfelkasse-data:/data -e MCP_SECRET=… zipfelkasse
```

Or use the prebuilt image (linux/amd64), built by GitHub Actions after the tests pass:
`ghcr.io/shostakovich/zipfelkasse:latest` follows `main`, version tags `v1.2.3` become `1.2.3` and `1.2`,
and every build is also tagged `sha-<commit>`. In `compose.yaml`, replace `build: .` with
`image: ghcr.io/shostakovich/zipfelkasse:latest` and update with `docker compose pull && docker compose up -d`.

The image is based on `scratch` and runs as user `65532`. If you use a bind mount instead of a volume, the
directory must be writable for that user (`chown 65532:65532 ./data`). The container health check runs
`zipfelkasse healthcheck` (checks `GET /healthz`).

## Tests

```sh
crystal spec                                                          # unit specs
shards build -Dtest_hooks && E2E_BIN=bin/zipfelkasse crystal spec e2e/ # black-box suite
```

The E2E suite needs a binary built with `-Dtest_hooks` (it reads the `ZIPFELKASSE_TEST_*` variables only
then) and the libxml2 development files, because it parses the HTML answers with Crystal's `XML` module
(already present on macOS; Debian/Ubuntu: `libxml2-dev`, Alpine: `libxml2-dev`). How it works:
[e2e/README.md](e2e/README.md).

`.claude/launch.json` (for the preview in Claude Code) serves a copy of real data from `data/prod/` on
port 8090. It builds with `-Dtest_hooks` only to point YNAB at a dead address, so that a copy of real data
never talks to the real YNAB.

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

## License

Unlicense (public domain), see [LICENSE](LICENSE). Icons come from Lucide; see [THIRD_PARTY.md](THIRD_PARTY.md).
