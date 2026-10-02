package store

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// newFileFixture is newFixture with a real file (the sandbox attaches the
// file read-only, :memory: does not work for that) and a YNAB token and
// status.
func newFileFixture(t *testing.T) fixture {
	t.Helper()
	path := filepath.Join(t.TempDir(), "zipfelkasse.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	f := fixture{s: s, anna: mustParticipant(t, s, "Anna"), ben: mustParticipant(t, s, "Ben"), cleo: mustParticipant(t, s, "Cleo")}
	cats, _ := s.ListCategories(context.Background(), false)
	f.food = cats[0].ID
	ctx := context.Background()
	if _, err := s.db.ExecContext(ctx, `INSERT INTO ynab_config (participant_id, token, updated_at) VALUES (?, 'SECRET-TOKEN', '2026-01-01T00:00:00Z')`, f.anna); err != nil {
		t.Fatal(err)
	}
	if err := s.SetYNABStatus(ctx, f.anna, YNABStatus{Error: "SECRET-STATUS", LastRun: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetSetting(ctx, "ynab.token_backup", "SECRET-TOKEN"); err != nil {
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
		"-- comment\nWITH x AS (SELECT 1) SELECT * FROM x;; -- end": "-- comment\nWITH x AS (SELECT 1) SELECT * FROM x",
		"/* a; b */ SELECT ';' AS x":                                "/* a; b */ SELECT ';' AS x",
		`SELECT "a;b", [c;d], ` + "`e;f`":                           `SELECT "a;b", [c;d], ` + "`e;f`",
		"SELECT 'it''s; fine'":                                      "SELECT 'it''s; fine'",
	}
	for in, want := range ok {
		got, err := checkSelect(in)
		if err != nil || got != want {
			t.Errorf("checkSelect(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	bad := []string{
		"", "   ", "-- only a comment",
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

	res, err := f.s.ReadOnlyQuery(ctx, `SELECT e.title AS title, e.amount_cents, e.fx_rate, NULL AS empty, x'00ff' AS b
		FROM expenses e WHERE e.deleted_at IS NULL ORDER BY e.date DESC;`)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(res.Columns, ",") != "title,amount_cents,fx_rate,empty,b" {
		t.Errorf("columns = %v", res.Columns)
	}
	want := fmt.Sprint([][]any{{"Kino", int64(2000), int64(1), nil, "[BLOB, 2 Bytes]"}, {"Rewe", int64(3000), int64(1), nil, "[BLOB, 2 Bytes]"}})
	if got := fmt.Sprint(res.Rows); got != want || res.Truncated {
		t.Errorf("rows = %s (truncated %v), want %s", got, res.Truncated, want)
	}

	// Empty result, WITH, row limit, order.
	res, err = f.s.ReadOnlyQuery(ctx, "SELECT * FROM participants WHERE name = 'Nobody'")
	if err != nil || len(res.Rows) != 0 || len(res.Columns) != 4 {
		t.Errorf("empty: %+v, %v", res, err)
	}
	res, err = f.s.ReadOnlyQuery(ctx, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 1000) SELECT i FROM n ORDER BY i DESC")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Rows) != SQLMaxRows || !res.Truncated || res.Rows[0][0] != int64(1000) || res.Rows[SQLMaxRows-1][0] != int64(1000-SQLMaxRows+1) {
		t.Errorf("limit: %d rows, truncated %v, first %v", len(res.Rows), res.Truncated, res.Rows[0])
	}
	// Long texts are truncated.
	res, err = f.s.ReadOnlyQuery(ctx, "SELECT length(x), x FROM (SELECT printf('%.5000c', 'a') AS x)")
	if err != nil || res.Rows[0][0] != int64(5000) || len(res.Rows[0][1].(string)) != sqlMaxCellRunes {
		t.Errorf("truncation: %v", err)
	}
	// SQL errors are ValidationErrors with the SQLite message.
	if _, err := f.s.ReadOnlyQuery(ctx, "SELECT x FROM doesnotexist"); !isValidation(err) || !strings.Contains(err.Error(), "doesnotexist") {
		t.Errorf("unknown table: %v", err)
	}
}

func TestReadOnlyQueryHasFold(t *testing.T) {
	f := newFileFixture(t)
	res, err := f.s.ReadOnlyQuery(context.Background(), "SELECT "+foldFunc+"('BÄCKER Straße'), "+foldFunc+"(NULL), "+foldFunc+"(42)")
	if err != nil {
		t.Fatal(err)
	}
	if got := res.Rows[0]; got[0] != "bäcker strasse" || got[1] != nil || got[2] != int64(42) {
		t.Errorf("fold in the sandbox = %#v", got)
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
			t.Errorf("%s: err = %v, want error", q, err)
		}
	}
	// Nothing in the sandbox contains the token – not via the schema or settings either.
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
		if s := fmt.Sprint(res.Rows); strings.Contains(s, "SECRET") || strings.Contains(strings.ToLower(s), "ynab") {
			t.Errorf("%s reveals YNAB: %s", q, s)
		}
	}
	res, _ := f.s.ReadOnlyQuery(ctx, "SELECT key FROM settings ORDER BY key")
	if fmt.Sprint(res.Rows) != "[[default_currency] [group_name]]" {
		t.Errorf("settings = %v", res.Rows)
	}
	// The schema via MCP shows no YNAB tables.
	objs, err := f.s.MCPSchema(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tables := 0
	for _, o := range objs {
		if strings.Contains(o.Name, "ynab") || strings.Contains(o.SQL, "ynab") {
			t.Errorf("MCPSchema contains %s", o.Name)
		}
		if o.Type == "table" {
			tables++
		}
	}
	if tables != len(MCPTables) {
		t.Errorf("%d tables in the schema, want %d", tables, len(MCPTables))
	}
}

// TestSandboxLayers checks the protection layers below the lexical check
// directly on the sandbox connection.
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
	other := filepath.Join(t.TempDir(), "copy.db")
	for _, q := range []string{
		"INSERT INTO participants (name, created_at) VALUES ('X', 'x')",
		"UPDATE expenses SET amount_cents = 1",
		"DELETE FROM expenses",
		"CREATE TABLE t (x)",
		"CREATE TEMP TABLE t (x)",
		"ATTACH DATABASE '" + f.s.Path() + "' AS real",
		"ATTACH DATABASE 'file:" + f.s.Path() + "?mode=ro' AS real",
		"VACUUM INTO '" + other + "'",
	} {
		if _, err := conn.ExecContext(ctx, q); err == nil {
			t.Errorf("%s: no error", q)
		}
	}
	if _, err := os.Stat(other); err == nil {
		t.Error("VACUUM INTO wrote a file")
	}
	// Even if someone turns query_only off: the file is out of reach.
	if _, err := conn.ExecContext(ctx, "PRAGMA query_only = OFF"); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.ExecContext(ctx, "ATTACH DATABASE '"+f.s.Path()+"' AS real"); err == nil {
		t.Error("ATTACH possible despite the limit")
	}
	if _, err := conn.ExecContext(ctx, "DELETE FROM expenses"); err != nil {
		t.Fatalf("delete in the copy: %v", err)
	}
	// Embedded in runWrapped, only SELECTs are syntactically possible.
	for _, body := range []string{"DELETE FROM expenses", "PRAGMA query_only = OFF", "SELECT 1) SELECT 1; ATTACH 'x' AS y; SELECT (1"} {
		if _, err := runWrapped(ctx, conn, body); err == nil {
			t.Errorf("runWrapped(%q): no error", body)
		}
	}
	closeFn()

	after, _ := os.ReadFile(f.s.Path())
	if string(before) != string(after) {
		t.Error("database file was modified")
	}
	es, _ := f.s.ListExpenses(ctx, ExpenseFilter{})
	if len(es) != 1 {
		t.Errorf("real expenses = %d, want 1", len(es))
	}
}

func TestReadOnlyQueryTimeout(t *testing.T) {
	f := newFileFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := f.s.ReadOnlyQuery(ctx, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT i FROM n WHERE i < 0")
	if !isValidation(err) || !strings.Contains(err.Error(), "aborted") {
		t.Errorf("err = %v, want abort", err)
	}
	if d := time.Since(start); d > 3*time.Second {
		t.Errorf("abort took %v", d)
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
	in = f.equal("Uncategorized", 500, "2026-09-11", f.anna, f.anna)
	in.CategoryID = 0
	f.mustCreate(t, in)
	del := f.mustCreate(t, f.equal("Deleted", 9999, "2026-09-12", f.anna, f.anna))
	if err := f.s.DeleteExpense(ctx, f.anna, del); err != nil {
		t.Fatal(err)
	}
	f.mustCreate(t, ExpenseInput{Title: "Reimbursement", Date: date("2026-09-13"), PaidBy: f.ben, AmountCents: 777,
		IsReimbursement: true, Parts: []domain.Part{{ParticipantID: f.anna}}})

	str := func(rows []StatRow) string {
		var b strings.Builder
		for _, r := range rows {
			fmt.Fprintf(&b, "%s|%s|%s|%d|%d|%d;", r.Category+r.Title, r.Period, r.Person, r.Count, r.AmountCents, r.PaidCents)
		}
		return b.String()
	}
	tests := []struct {
		f    StatsFilter
		want string
	}{
		{StatsFilter{GroupBy: StatsByCategory}, "Lebensmittel|||2|4000|0;Restaurant|||1|4000|0;No category|||1|500|0;"},
		{StatsFilter{GroupBy: StatsByMonth}, "|2026-08||1|3000|0;|2026-09||3|5500|0;"},
		{StatsFilter{GroupBy: StatsByCategoryMonth, From: date("2026-09-01")}, "Restaurant|2026-09||1|4000|0;Lebensmittel|2026-09||1|1000|0;No category|2026-09||1|500|0;"},
		{StatsFilter{GroupBy: StatsByCategory, ParticipantID: f.ben}, "Restaurant|||1|2000|0;Lebensmittel|||2|1500|0;"},
		{StatsFilter{GroupBy: StatsByMonth, ParticipantID: f.anna, To: date("2026-08-31")}, "|2026-08||1|1000|0;"},
		{StatsFilter{GroupBy: StatsByPerson}, "||Ben|3|3500|1000;||Cleo|2|3000|4000;||Anna|3|2000|3500;"},
		{StatsFilter{GroupBy: StatsByPerson, From: date("2026-09-01"), ParticipantID: f.anna}, "||Anna|2|1000|500;"},
		{StatsFilter{GroupBy: StatsByCategory, WithoutCategory: true}, "No category|||1|500|0;"},
		{StatsFilter{GroupBy: StatsByMonth, CategoryID: f.food}, "|2026-08||1|3000|0;|2026-09||1|1000|0;"},
		{StatsFilter{GroupBy: StatsByPerson, CategoryID: rest}, "||Ben|1|2000|0;||Cleo|1|2000|4000;"},
		{StatsFilter{GroupBy: StatsByPerson, WithoutCategory: true}, "||Anna|1|500|500;"},
		{StatsFilter{GroupBy: StatsByYear}, "|2026||4|8500|0;"},
		{StatsFilter{GroupBy: StatsByWeek}, "|2026-W33||1|3000|0;|2026-W36||1|1000|0;|2026-W37||2|4500|0;"},
		{StatsFilter{GroupBy: StatsByTitle, AnyText: []string{"pizza", "REWE"}}, "Pizza|||1|4000|0;Rewe|||1|3000|0;"},
		{StatsFilter{GroupBy: StatsByMonth, AnyText: []string{"edeka"}}, "|2026-09||1|1000|0;"},
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
	if _, err := f.s.Stats(ctx, StatsFilter{GroupBy: "nonsense"}); !isValidation(err) {
		t.Errorf("unknown grouping: %v", err)
	}
}

func TestStatsByTitleIgnoresCase(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	f.mustCreate(t, f.equal("Rewe", 3000, "2026-08-15", f.anna, f.anna))
	f.mustCreate(t, f.equal("REWE", 1000, "2026-08-16", f.anna, f.anna))
	f.mustCreate(t, f.equal("Lidl", 500, "2026-08-17", f.anna, f.anna))
	rows, err := f.s.Stats(ctx, StatsFilter{GroupBy: StatsByTitle})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || !strings.EqualFold(rows[0].Title, "rewe") || rows[0].Count != 2 || rows[0].AmountCents != 4000 {
		t.Errorf("rows = %+v", rows)
	}
}

func TestFillPeriods(t *testing.T) {
	periods := func(rows []StatRow) string {
		var p []string
		for _, r := range rows {
			p = append(p, fmt.Sprintf("%s=%d", r.Period, r.AmountCents))
		}
		return strings.Join(p, ",")
	}
	rows := []StatRow{{Period: "2026-01", AmountCents: 1}, {Period: "2026-04", AmountCents: 4}}
	if got := periods(FillPeriods(rows, StatsByMonth, date("2025-12-20"), date("2026-04-02"))); got != "2025-12=0,2026-01=1,2026-02=0,2026-03=0,2026-04=4" {
		t.Errorf("months = %s", got)
	}
	rows = []StatRow{{Period: "2025-W52", AmountCents: 1}}
	if got := periods(FillPeriods(rows, StatsByWeek, date("2025-12-24"), date("2026-01-07"))); got != "2025-W52=1,2026-W01=0,2026-W02=0" {
		t.Errorf("weeks = %s", got)
	}
	if got := periods(FillPeriods(nil, StatsByYear, date("2024-06-01"), date("2026-01-01"))); got != "2024=0,2025=0,2026=0" {
		t.Errorf("years = %s", got)
	}
	if got := FillPeriods(rows, StatsByCategory, date("2024-06-01"), date("2026-01-01")); len(got) != 1 {
		t.Errorf("category filled: %v", got)
	}
}

func TestPeriods(t *testing.T) {
	for _, c := range []struct{ groupBy, period, start string }{
		{StatsByYear, "2026", "2026-01-01"},
		{StatsByMonth, "2026-09", "2026-09-01"},
		{StatsByWeek, "2026-W01", "2025-12-29"},
		{StatsByWeek, "2026-W40", "2026-09-28"},
		{StatsByWeek, "2020-W53", "2020-12-28"},
	} {
		got := PeriodStart(c.groupBy, c.period)
		if got.Format("2006-01-02") != c.start || PeriodOf(c.groupBy, got) != c.period {
			t.Errorf("%s %s: %s", c.groupBy, c.period, got)
		}
	}
	if !PeriodStart(StatsByMonth, "nonsense").IsZero() {
		t.Error("nonsense parsed")
	}
	for _, c := range []struct{ in, want string }{{"2024-02-29", "2023-02-28"}, {"2024-03-31", "2023-03-31"}, {"2023-02-28", "2022-02-28"}} {
		if got := ShiftDateYear(date(c.in), -1).Format("2006-01-02"); got != c.want {
			t.Errorf("ShiftDateYear(%s) = %s", c.in, got)
		}
	}
	if got := ShiftDateYear(date("2023-02-28"), 1).Format("2006-01-02"); got != "2024-02-28" {
		t.Errorf("ShiftDateYear forward = %s", got)
	}
	for in, want := range map[string]string{"2025-09": "2026-09", "2025-W40": "2026-W40", "2025": "2026", "": "",
		"2020-W53": "2021-W52", "2025-W53": "2026-W53"} {
		if got := ShiftPeriodYear(in, 1); got != want {
			t.Errorf("shift %q = %q", in, got)
		}
	}
}
