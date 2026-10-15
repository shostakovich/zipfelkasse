# Zipfelkasse

Shared expenses for one household: who paid what for whom, the balances that follow and how to settle them,
inspired by [Spliit](https://github.com/spliit-app/spliit). **The user interface is German.**

## Before you use this

- A personal project, built for my own household.
- There is no login: you pick who you are. Never expose it publicly; run it in a private network or behind an
  authenticating access layer such as Tailscale, a VPN or an authenticating reverse proxy.
- No pull requests, but forks are welcome.

## What it does

- One group; expenses split equally, by shares, by percent or by amounts
- Reimbursements, balances and a settlement proposal
- Recurring expenses, an activity log, search
- Foreign currencies with ECB reference rates or a manual rate
- Exports as CSV, JSON, OFX and YNAB CSV; optional sync to [YNAB](https://www.ynab.com/)
- An MCP server for AI assistants to analyse and enter expenses: [docs/MCP.md](docs/MCP.md)
- Installable as a PWA, for phone and desktop

## Development

Erlang and Elixir as in `.tool-versions`.

```sh
mix setup        # deps, database in storage/, assets
mix phx.server   # http://localhost:4000
```

Checks, as CI runs them:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test --warnings-as-errors
mix assets.setup && mix assets.deploy
```

## Running it

- Image `ghcr.io/shostakovich/zipfelkasse` (linux/amd64): `latest` follows `main`, and every pushed image is also
  tagged `sha-<commit>`; pull requests are only built and smoke-tested.
- [compose.yaml](compose.yaml) is an example; put the app behind a reverse proxy that terminates TLS.
- The container runs as uid 1000; the data volume `/app/data` must be writable for it.
- Migrations run on start. The health check calls `/up`.
- A backup is written every night at 03:00 into `<database dir>/backups`; the last 7 are kept, as files with mode
  0600 because they hold the YNAB tokens.

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_PATH` | `/app/data/zipfelkasse.sqlite3` | the SQLite file |
| `PHX_HOST` | required | the public host name, e.g. `kasse.example.org` |
| `SECRET_KEY_BASE` | required | e.g. `openssl rand -hex 64` |
| `PORT` | `4000` | HTTP port |
| `MCP_SECRET` | empty = MCP off | the MCP endpoint is `/mcp/<MCP_SECRET>` |
| `MCP_ALLOWED_CIDRS` | `160.79.104.0/21` | who may call MCP (CIDRs or addresses, comma or space separated) |
| `TRUSTED_PROXIES` | empty | proxies whose `X-Forwarded-For` counts for MCP |
| `TZ` | `Europe/Berlin` | local time: "today", the jobs, times shown |

## Stack

Phoenix 1.8 with LiveView, SQLite via ecto_sqlite3, [Setzkasten](https://github.com/shostakovich/setzkasten) on
Tailwind CSS 4 and daisyUI 5; one container.

## License

Public domain ([The Unlicense](LICENSE)); third-party notices in [THIRD_PARTY.md](THIRD_PARTY.md).
