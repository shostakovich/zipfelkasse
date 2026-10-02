# Backlog (nach Version 1)

Bewusst zurückgestellt, damit Version 1 schlank bleibt. Quelle: Abnahme mit den echten Spliit-Daten (Oktober 2026).

## App

- **Kategorie-Vorschlag im Formular:** Die Kategorie, die zuletzt für denselben Titel benutzt wurde, wird vorgeschlagen.
  Hintergrund: 64 % der importierten Ausgaben haben keine Kategorie. Schon entschieden: nur der Vorschlag, keine Seite
  zum Nachtragen.
- **Platzhalter im Titel wiederkehrender Ausgaben** (`{MM/JJ}`, `{Monat}` …), damit nicht jeden Monat derselbe
  Titel „Miete 10/26“ entsteht. Bis dahin: die Ausgabe vor „Als wiederkehrend einrichten“ neutral benennen
  („Miete“).

## MCP

- `ausgaben_suchen`: Sortierung, Betragsgrenzen, mehrere Suchwörter, `bezahlt_von` getrennt von „beteiligt“,
  kompaktere Ausgabe.
- `statistik`: Gruppierungen `jahr`, `woche`, `titel` (Händler), Filter `kategorie`/`text`, leere Monate als 0,
  Vorjahresvergleich.
- Neue Tools `aktivitaet` und `saldo_verlauf`.
- Datenüberblick in den Instructions (Zeitraum, Anzahl, Anteil ohne Kategorie), alle Werte von `activity.action`.
- Antwortgröße halbieren (Text ist heute eine Kopie von `structuredContent`; `outputSchema` prüfen).

## Bewusst nicht geplant

- Spliit-Import als Befehl (Umzug läuft einmalig über das Wegwerf-Skript).
- Negative Beträge/Gutschriften (die zwei Altfälle werden von Hand korrigiert).
- Reisen/Ereignisse als eigenes Feld.
