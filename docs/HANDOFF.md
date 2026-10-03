# Handoff: Crystal port of Zipfelkasse

For the next session (Robert continues locally). Read this, then `docs/PORTING.md` (rules, decisions,
deviations, conventions, checklist). Delete this file at the end of the port.

## Rules that still apply

- Answer in German. Behaviour 1:1, not byte-level Go parity. No Go compatibility layer.
- Shards: only kemal, db, sqlite3 (ask Robert before adding any).
- Few comments in code, only where really needed (PORTING.md "Comments").
- Small thematic commits; `crystal tool format --check` and `crystal spec` before each commit.
- No PR until Robert asks. Never commit a real DB backup (only into a gitignored folder).
- At the very end remove all migration scaffolding (see step 4).

## State (branch `claude/sharp-dirac-5i8uew`)

| Part | State |
|---|---|
| Phase 0–2 (inventory, E2E suite against Go, foundation) | done |
| Phase 3 wave 1: store + data migrations 2/4/5, review | done |
| Phase 3 wave 2: web pages, fx, recurring, export, ynab, mcp | ported, `crystal spec` 354 green |
| Review wave 2: jobs (fx/recurring/ynab/export) | done (4 fixes) |
| Review wave 2: web | **interrupted**, partial fixes committed (specs green) |
| Review wave 2: mcp | **interrupted**; Go-style decoder messages already replaced |
| Phase 4 | open |

Last full E2E diff run (Crystal vs Go, before the reviews): 107/108 identical. The one difference:
`e2e/mcp_spec.cr:225` — for the oversized MCP bodies (413 "Message too large or incomplete.") Go sends
`Connection: close`, Crystal doesn't. Fix in `src/zipfelkasse/mcp/` (set the header where Go does, keep
draining the body), with a spec.

## Next steps

1. Finish the two interrupted reviews, each: compare with Go, failing spec first, then fix.
   - Web: handlers/templates vs `internal/web`, and the root cause of the compiler crash
     "BUG: trying to downcast IO+ <- String::Builder" in templates (workarounds: `Renderer#page` block
     typing, Int32 stored as Int64 on the YNAB page, Array instead of closure in export `write_ofx`);
     remove workarounds if the root cause is fixed.
   - MCP: the `Connection: close` difference above; tools/schemas/texts vs `internal/mcp`; simplicity.
2. Build and run the E2E suite in diff mode until 108/108:
   `crystal build src/zipfelkasse.cr -o bin/zipfelkasse`, then
   `E2E_BIN=bin/zipfelkasse E2E_REF_BIN=<go binary> crystal spec e2e/` (~2.5 min).
3. Phase 4: Docker (`Dockerfile.crystal` → `Dockerfile`; static OpenSSL needs `SSL_CERT_FILE` or
   `/etc/ssl/cert.pem`; check that libxml2 links statically), CI, remove Go (`main.go`, `internal/`,
   `go.*`; first move static files and migrations into the Crystal tree — today they are embedded from
   `internal/`), docs (README).
4. Then remove the migration scaffolding: E2E diff mode and reference binary (`E2E_REF_BIN`, two apps per
   `World`, `Compare`/`DOM` canonicalisation, `compare_spec.cr`, seed "built by the reference"),
   `docs/porting/`, `docs/PORTING.md`, this file, all "like Go"/"Go's …" wording in specs and comments,
   names that only make sense next to Go. Keep the E2E scenarios as plain black-box tests (fakes and the
   frozen clock stay) and the unit specs.

## Local setup

- Crystal 1.21.x and `shards install` (kemal 1.14, db 0.14, sqlite3 0.23).
- SQLite ≥ 3.46 must be the library Crystal links (week stats use `strftime('%G-W%V')`; 3.45 returns
  NULL). The cloud session used a self-built 3.53.4 in `/usr/local/lib`.
- Go (only until phase 4) for the reference binary: `go build -o /tmp/zk-go-ref .`
- Tests: `crystal spec` (unit), `E2E_BIN=bin/zipfelkasse crystal spec e2e/` (black box, see
  `e2e/README.md`). Seeds are cached in `e2e/data/` (gitignored).

## Pitfalls seen

- Kemal keeps routes and handlers globally: `App.new` resets them (`Web.reset_kemal`), so specs can build
  many apps (`spec/web/web_helper.cr`, `TestServer`).
- `Time#to_rfc3339` always prints UTC; local times with an offset need own formatting (MCP does).
- libxml2 repairs broken XML unless parsed with `XML::ParserOptions::NONET` only.
- Unread request bodies: Crystal's server closes the connection and the client sees a reset; drain the
  body (bounded) when answering early (LimitBody, MCP).
- `rescue` inside a `query_one` block and some IO unions crash the 1.21.1 compiler.
