# Backlog (after version 1)

Deliberately deferred to keep version 1 lean. Source: acceptance test with the real Spliit data (October 2026).

## App

- **Category suggestion in the form:** the category last used for the same title is suggested.
  Background: 64 % of the imported expenses have no category. Already decided: only the suggestion, no page
  for filling them in afterwards.
- **Placeholders in the title of recurring expenses** (`{MM/JJ}`, `{Monat}` …), so that you don't end up with
  the same title "Miete 10/26" every month. Until then: give the expense a neutral name ("Miete") before
  "Als wiederkehrend einrichten" (set up as recurring).

## MCP

- `ausgaben_suchen`: sorting, amount bounds, multiple search terms, `bezahlt_von` separate from "beteiligt"
  (involved), more compact output.
- `statistik`: groupings `jahr`, `woche`, `titel` (merchant), filters `kategorie`/`text`, empty months as 0,
  year-over-year comparison.
- New tools `aktivitaet` and `saldo_verlauf`.
- Data overview in the instructions (date range, count, share without category), all values of `activity.action`.
- Halve the response size (the text is currently a copy of `structuredContent`; check `outputSchema`).

## Deliberately not planned

- Spliit import as a command (the migration runs once via the throwaway script).
- Negative amounts/credits (the two legacy cases are corrected by hand).
- Trips/events as a separate field.
