package store

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"teilen/internal/domain"
)

// newFileFixture ist newFixture mit einer echten Datei (die Sandbox hängt die
// Datei schreibgeschützt an, :memory: geht dafür nicht) und einem YNAB-Token.
func newFileFixture(t *testing.T) fixture {
	t.Helper()
	path := filepath.Join(t.TempDir(), "teilen.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	f := fixture{s: s, anna: mustParticipant(t, s, "Anna"), ben: mustParticipant(t, s, "Ben"), cleo: mustParticipant(t, s, "Cleo")}
	cats, _ := s.ListCategories(context.Background(), false)
	f.food = cats[0].ID
	ctx := context.Background()
	if _, err := s.db.ExecContext(ctx, `INSERT INTO ynab_config (participant_id, token, updated_at) VALUES (?, 'GEHEIMES-TOKEN', '2026-01-01T00:00:00Z')`, f.anna); err != nil {
		t.Fatal(err)
	}
	if err := s.SetSetting(ctx, "ynab.token_backup", "GEHEIMES-TOKEN"); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f fixture) mustCreate(t *testing.T, in ExpenseInput) int64 {
	t.Helper()
	id, err := f.s.CreateExpense(context.Background(), f.anna, in)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestCheckSelect(t *testing.T) {
	ok := map[string]string{
		"SELECT 1":       "SELECT 1",
		"  select 1 ;  ": "  select 1 ",
		"-- Kommentar\nWITH x AS (SELECT 1) SELECT * FROM x;; -- Ende": "-- Kommentar\nWITH x AS (SELECT 1) SELECT * FROM x",
		"/* a; b */ SELECT ';' AS x":                                   "/* a; b */ SELECT ';' AS x",
		`SELECT "a;b", [c;d], ` + "`e;f`":                              `SELECT "a;b", [c;d], ` + "`e;f`",
		"SELECT 'it''s; fine'":                                         "SELECT 'it''s; fine'",
	}
	for in, want := range ok {
		got, err := checkSelect(in)
		if err != nil || got != want {
			t.Errorf("checkSelect(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	bad := []string{
		"", "   ", "-- nur Kommentar",
		"DELETE FROM expenses",
		"PRAGMA query_only = OFF",
		"ATTACH 'x.db' AS x",
		"VACUUM INTO '/tmp/x.db'",
		"SELECT 1; DELETE FROM expenses",
		"SELECT 1; ATTACH DATABASE 'file:x' AS y",
		"SELECT 'a'; PRAGMA query_only=0",
		"SELECT 1 /* ; */; SELECT 2",
		"SELECT 1\x00; DROP TABLE expenses",
		"(SELECT 1)",
		"EXPLAIN SELECT 1",
	}
	for _, in := range bad {
		if _, err := checkSelect(in); !isValidation(err) {
			t.Errorf("checkSelect(%q): err = %v, want ValidationError", in, err)
		}
	}
}

func TestReadOnlyQuery(t *testing.T) {
	f := newFileFixture(t)
	ctx := context.Background()
	f.mustCreate(t, f.equal("Rewe", 3000, "2026-09-01", f.anna, f.anna, f.ben, f.cleo))
	f.mustCreate(t, f.equal("Kino", 2000, "2026-09-02", f.ben, f.anna, f.ben))

	res, err := f.s.ReadOnlyQuery(ctx, `SELECT e.title AS titel, e.amount_cents, e.fx_rate, NULL AS nix, x'00ff' AS b
		FROM expenses e WHERE e.deleted_at IS NULL ORDER BY e.date DESC;`)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(res.Columns, ",") != "titel,amount_cents,fx_rate,nix,b" {
		t.Errorf("Spalten = %v", res.Columns)
	}
	want := fmt.Sprint([][]any{{"Kino", int64(2000), int64(1), nil, "[BLOB, 2 Bytes]"}, {"Rewe", int64(3000), int64(1), nil, "[BLOB, 2 Bytes]"}})
	if got := fmt.Sprint(res.Rows); got != want || res.Truncated {
		t.Errorf("Zeilen = %s (truncated %v), want %s", got, res.Truncated, want)
	}

	// Leeres Ergebnis, WITH, Zeilenlimit, Reihenfolge.
	res, err = f.s.ReadOnlyQuery(ctx, "SELECT * FROM participants WHERE name = 'Niemand'")
	if err != nil || len(res.Rows) != 0 || len(res.Columns) != 4 {
		t.Errorf("leer: %+v, %v", res, err)
	}
	res, err = f.s.ReadOnlyQuery(ctx, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 1000) SELECT i FROM n ORDER BY i DESC")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Rows) != SQLMaxRows || !res.Truncated || res.Rows[0][0] != int64(1000) || res.Rows[SQLMaxRows-1][0] != int64(1000-SQLMaxRows+1) {
		t.Errorf("Limit: %d Zeilen, truncated %v, erste %v", len(res.Rows), res.Truncated, res.Rows[0])
	}
	// Lange Texte werden gekürzt.
	res, err = f.s.ReadOnlyQuery(ctx, "SELECT length(x), x FROM (SELECT printf('%.5000c', 'a') AS x)")
	if err != nil || res.Rows[0][0] != int64(5000) || len(res.Rows[0][1].(string)) != sqlMaxCellRunes {
		t.Errorf("Kürzen: %v", err)
	}
	// SQL-Fehler sind ValidationErrors mit SQLite-Meldung.
	if _, err := f.s.ReadOnlyQuery(ctx, "SELECT nix FROM gibtsnicht"); !isValidation(err) || !strings.Contains(err.Error(), "gibtsnicht") {
		t.Errorf("unbekannte Tabelle: %v", err)
	}
}

func TestReadOnlyQueryHidesYNAB(t *testing.T) {
	f := newFileFixture(t)
	ctx := context.Background()
	for _, q := range []string{
		"SELECT token FROM ynab_config",
		"SELECT * FROM main.ynab_config",
		`SELECT * FROM "YNAB_CONFIG"`,
		"SELECT * FROM ynab_sync",
		"SELECT * FROM src.ynab_config",
		"SELECT * FROM temp.ynab_config",
	} {
		if _, err := f.s.ReadOnlyQuery(ctx, q); !isValidation(err) {
			t.Errorf("%s: err = %v, want Fehler", q, err)
		}
	}
	// Nichts in der Sandbox enthält das Token – auch nicht über Schema oder Settings.
	for _, q := range []string{
		"SELECT * FROM settings",
		"SELECT name, sql FROM sqlite_schema",
		"SELECT * FROM pragma_database_list",
		"SELECT * FROM pragma_table_list",
	} {
		res, err := f.s.ReadOnlyQuery(ctx, q)
		if err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		if s := fmt.Sprint(res.Rows); strings.Contains(s, "GEHEIM") || strings.Contains(strings.ToLower(s), "ynab") {
			t.Errorf("%s verrät YNAB: %s", q, s)
		}
	}
	res, _ := f.s.ReadOnlyQuery(ctx, "SELECT key FROM settings ORDER BY key")
	if fmt.Sprint(res.Rows) != "[[default_currency] [group_name]]" {
		t.Errorf("settings = %v", res.Rows)
	}
	// Schema über MCP zeigt keine YNAB-Tabellen.
	objs, err := f.s.MCPSchema(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tables := 0
	for _, o := range objs {
		if strings.Contains(o.Name, "ynab") || strings.Contains(o.SQL, "ynab") {
			t.Errorf("MCPSchema enthält %s", o.Name)
		}
		if o.Type == "table" {
			tables++
		}
	}
	if tables != len(MCPTables) {
		t.Errorf("%d Tabellen im Schema, want %d", tables, len(MCPTables))
	}
}

// TestSandboxLayers prüft die Schutzschichten unterhalb der lexikalischen
// Prüfung direkt auf der Sandbox-Verbindung.
func TestSandboxLayers(t *testing.T) {
	f := newFileFixture(t)
	ctx := context.Background()
	f.mustCreate(t, f.equal("Rewe", 3000, "2026-09-01", f.anna, f.anna, f.ben))
	before, _ := os.ReadFile(f.s.Path())

	conn, closeFn, err := f.s.sandbox(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer closeFn()
	other := filepath.Join(t.TempDir(), "kopie.db")
	for _, q := range []string{
		"INSERT INTO participants (name, created_at) VALUES ('X', 'x')",
		"UPDATE expenses SET amount_cents = 1",
		"DELETE FROM expenses",
		"CREATE TABLE t (x)",
		"CREATE TEMP TABLE t (x)",
		"ATTACH DATABASE '" + f.s.Path() + "' AS echt",
		"ATTACH DATABASE 'file:" + f.s.Path() + "?mode=ro' AS echt",
		"VACUUM INTO '" + other + "'",
	} {
		if _, err := conn.ExecContext(ctx, q); err == nil {
			t.Errorf("%s: kein Fehler", q)
		}
	}
	if _, err := os.Stat(other); err == nil {
		t.Error("VACUUM INTO hat eine Datei geschrieben")
	}
	// Selbst wenn jemand query_only abschaltet: die Datei ist nicht erreichbar.
	if _, err := conn.ExecContext(ctx, "PRAGMA query_only = OFF"); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.ExecContext(ctx, "ATTACH DATABASE '"+f.s.Path()+"' AS echt"); err == nil {
		t.Error("ATTACH trotz Limit möglich")
	}
	if _, err := conn.ExecContext(ctx, "DELETE FROM expenses"); err != nil {
		t.Fatalf("Löschen in der Kopie: %v", err)
	}
	// Eingebettet in runWrapped sind nur SELECTs syntaktisch möglich.
	for _, body := range []string{"DELETE FROM expenses", "PRAGMA query_only = OFF", "SELECT 1) SELECT 1; ATTACH 'x' AS y; SELECT (1"} {
		if _, err := runWrapped(ctx, conn, body); err == nil {
			t.Errorf("runWrapped(%q): kein Fehler", body)
		}
	}
	closeFn()

	after, _ := os.ReadFile(f.s.Path())
	if string(before) != string(after) {
		t.Error("Datenbankdatei wurde verändert")
	}
	es, _ := f.s.ListExpenses(ctx, ExpenseFilter{})
	if len(es) != 1 {
		t.Errorf("echte Ausgaben = %d, want 1", len(es))
	}
}

func TestReadOnlyQueryTimeout(t *testing.T) {
	f := newFileFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := f.s.ReadOnlyQuery(ctx, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT i FROM n WHERE i < 0")
	if !isValidation(err) || !strings.Contains(err.Error(), "abgebrochen") {
		t.Errorf("err = %v, want Abbruch", err)
	}
	if d := time.Since(start); d > 3*time.Second {
		t.Errorf("Abbruch dauerte %v", d)
	}
}

func TestReadOnlyQueryMemory(t *testing.T) {
	s := newTestStore(t)
	if _, err := s.ReadOnlyQuery(context.Background(), "SELECT 1"); !isValidation(err) {
		t.Errorf("err = %v, want ValidationError", err)
	}
}

func TestStats(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	cats, _ := f.s.ListCategories(ctx, false)
	rest := cats[1].ID
	f.mustCreate(t, f.equal("Rewe", 3000, "2026-08-15", f.anna, f.anna, f.ben, f.cleo))
	f.mustCreate(t, f.equal("Edeka", 1000, "2026-09-01", f.ben, f.anna, f.ben))
	in := f.equal("Pizza", 4000, "2026-09-10", f.cleo, f.ben, f.cleo)
	in.CategoryID = rest
	f.mustCreate(t, in)
	in = f.equal("Ohne", 500, "2026-09-11", f.anna, f.anna)
	in.CategoryID = 0
	f.mustCreate(t, in)
	del := f.mustCreate(t, f.equal("Gelöscht", 9999, "2026-09-12", f.anna, f.anna))
	if err := f.s.DeleteExpense(ctx, f.anna, del); err != nil {
		t.Fatal(err)
	}
	f.mustCreate(t, ExpenseInput{Title: "Rückzahlung", Date: date("2026-09-13"), PaidBy: f.ben, AmountCents: 777,
		IsReimbursement: true, Parts: []domain.Part{{ParticipantID: f.anna}}})

	str := func(rows []StatRow) string {
		var b strings.Builder
		for _, r := range rows {
			fmt.Fprintf(&b, "%s|%s|%s|%d|%d|%d;", r.Category, r.Month, r.Person, r.Count, r.AmountCents, r.PaidCents)
		}
		return b.String()
	}
	tests := []struct {
		f    StatsFilter
		want string
	}{
		{StatsFilter{GroupBy: StatsByCategory}, "Lebensmittel|||2|4000|0;Restaurant|||1|4000|0;Ohne Kategorie|||1|500|0;"},
		{StatsFilter{GroupBy: StatsByMonth}, "|2026-08||1|3000|0;|2026-09||3|5500|0;"},
		{StatsFilter{GroupBy: StatsByCategoryMonth, From: date("2026-09-01")}, "Restaurant|2026-09||1|4000|0;Lebensmittel|2026-09||1|1000|0;Ohne Kategorie|2026-09||1|500|0;"},
		{StatsFilter{GroupBy: StatsByCategory, ParticipantID: f.ben}, "Restaurant|||1|2000|0;Lebensmittel|||2|1500|0;"},
		{StatsFilter{GroupBy: StatsByMonth, ParticipantID: f.anna, To: date("2026-08-31")}, "|2026-08||1|1000|0;"},
		{StatsFilter{GroupBy: StatsByPerson}, "||Ben|3|3500|1000;||Cleo|2|3000|4000;||Anna|3|2000|3500;"},
		{StatsFilter{GroupBy: StatsByPerson, From: date("2026-09-01"), ParticipantID: f.anna}, "||Anna|2|1000|500;"},
	}
	for _, tt := range tests {
		rows, err := f.s.Stats(ctx, tt.f)
		if err != nil {
			t.Fatalf("%+v: %v", tt.f, err)
		}
		if got := str(rows); got != tt.want {
			t.Errorf("%+v:\n got %s\nwant %s", tt.f, got, tt.want)
		}
	}
	if _, err := f.s.Stats(ctx, StatsFilter{GroupBy: "quatsch"}); !isValidation(err) {
		t.Errorf("unbekannte Gruppierung: %v", err)
	}
}
