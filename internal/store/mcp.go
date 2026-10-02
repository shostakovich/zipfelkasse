package store

// Queries for the MCP server (internal/mcp): statistics, schema and the
// read-only SQL sandbox for the sql_query tool.

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// MCPTables are the tables visible via MCP (schema, sql_query). Deliberately
// an allowlist: new tables only become visible once they are listed here. The
// YNAB tables (token!) are left out on purpose.
var MCPTables = []string{
	"participants", "categories", "expenses", "expense_shares",
	"recurring", "activity", "fx_rates", "settings",
}

// mcpRowFilter restricts individual tables when copying them into the sandbox.
var mcpRowFilter = map[string]string{
	"settings": `key NOT LIKE 'ynab%'`, // never show YNAB's own keys (ynab.…)
}

// Limits of the SQL sandbox.
const (
	SQLMaxRows      = 500             // the maximum number of rows ReadOnlyQuery returns
	SQLTimeout      = 5 * time.Second // total duration including the copy
	sqlMaxCellRunes = 2000            // longer texts are truncated
	sqlMaxResult    = 8 << 20         // bytes, sqlite3_limit(SQLITE_LIMIT_LENGTH)
)

// QueryResult is the result of ReadOnlyQuery. Rows contains int64, float64,
// string or nil.
type QueryResult struct {
	Columns   []string
	Rows      [][]any
	Truncated bool // there were more than SQLMaxRows rows
}

// SchemaObject is a table or an index with its CREATE statement.
type SchemaObject struct {
	Type string // "table" | "index"
	Name string
	SQL  string
}

// MCPSchema returns the CREATE statements of the tables visible via MCP
// (MCPTables) and their indexes.
func (s *Store) MCPSchema(ctx context.Context) ([]SchemaObject, error) {
	return schemaObjects(ctx, s.db, "main")
}

func schemaObjects(ctx context.Context, q queryer, schema string) ([]SchemaObject, error) {
	rows, err := q.QueryContext(ctx, fmt.Sprintf(`SELECT type, name, tbl_name, sql FROM %s.sqlite_schema
		WHERE type IN ('table', 'index') AND sql IS NOT NULL ORDER BY type DESC, rowid`, schema))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SchemaObject
	for rows.Next() {
		var o SchemaObject
		var table string
		if err := rows.Scan(&o.Type, &o.Name, &table, &o.SQL); err != nil {
			return nil, err
		}
		if slices.Contains(MCPTables, table) {
			out = append(out, o)
		}
	}
	return out, rows.Err()
}

// ReadOnlyQuery runs a single SELECT/WITH query in a sandbox and returns at
// most SQLMaxRows rows.
//
// The sandbox is a fresh in-memory database: the tables from MCPTables are
// copied into it over a read-only connection (ATTACH 'file:<path>?mode=ro')
// in a read transaction, then the file is detached again. The query therefore
// only sees this copy – the YNAB tables including the token do not exist
// there at all. In addition: ATTACH is forbidden via sqlite3_limit, PRAGMA
// query_only is on, the query must lexically be exactly one SELECT/WITH and
// is embedded as a subquery in an aggregation (so it runs in a single step
// that can be interrupted via the context). Input errors are
// domain.ValidationError.
func (s *Store) ReadOnlyQuery(ctx context.Context, query string) (QueryResult, error) {
	body, err := checkSelect(query)
	if err != nil {
		return QueryResult{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, SQLTimeout)
	defer cancel()
	conn, closeFn, err := s.sandbox(ctx)
	if err != nil {
		return QueryResult{}, sandboxErr(ctx, err)
	}
	defer closeFn()
	res, err := runWrapped(ctx, conn, body)
	if err != nil {
		return QueryResult{}, sandboxErr(ctx, err)
	}
	return res, nil
}

// sandboxErr turns errors into understandable messages. SQLite errors
// (syntax, unknown table …) go to the caller as ValidationError.
func sandboxErr(ctx context.Context, err error) error {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) {
		return invalid("The query was aborted after %d s. Please narrow it down (WHERE, LIMIT) or simplify it.", int(SQLTimeout/time.Second))
	}
	var ve domain.ValidationError
	if errors.As(err, &ve) {
		return err
	}
	var se *sqlite.Error
	if errors.As(err, &se) {
		if se.Code() == sqlite3.SQLITE_TOOBIG {
			return invalid("The result is too large. Please query fewer columns/rows.")
		}
		return invalid("SQL error: %s", strings.TrimPrefix(se.Error(), "SQL logic error: "))
	}
	return err
}

// sandbox builds the in-memory copy and returns the (locked-down) connection.
func (s *Store) sandbox(ctx context.Context) (*sql.Conn, func(), error) {
	if s.path == ":memory:" || s.path == "" {
		return nil, nil, invalid("sql_query needs a database file (not available with :memory:).")
	}
	abs, err := filepath.Abs(s.path)
	if err != nil {
		return nil, nil, err
	}
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		return nil, nil, err
	}
	db.SetMaxOpenConns(1)
	conn, err := db.Conn(ctx)
	if err != nil {
		db.Close()
		return nil, nil, err
	}
	closeFn := func() { conn.Close(); db.Close() }
	if err := fillSandbox(ctx, conn, abs); err != nil {
		closeFn()
		return nil, nil, err
	}
	return conn, closeFn, nil
}

func fillSandbox(ctx context.Context, conn *sql.Conn, path string) error {
	src := (&url.URL{Scheme: "file", Path: filepath.ToSlash(path), RawQuery: "mode=ro"}).String()
	if _, err := conn.ExecContext(ctx, "ATTACH DATABASE ? AS src", src); err != nil {
		return fmt.Errorf("open database read-only: %w", err)
	}
	// Read transaction: all tables from the same snapshot.
	err := func() error {
		if _, err := conn.ExecContext(ctx, "BEGIN"); err != nil {
			return err
		}
		objs, err := schemaObjects(ctx, conn, "src")
		if err != nil {
			return err
		}
		// Tables first, then indexes (schemaObjects sorts them that way).
		for _, o := range objs {
			if _, err := conn.ExecContext(ctx, o.SQL); err != nil {
				return fmt.Errorf("sandbox %s: %w", o.Name, err)
			}
			if o.Type != "table" {
				continue
			}
			q := fmt.Sprintf(`INSERT INTO main."%s" SELECT * FROM src."%s"`, o.Name, o.Name)
			if f := mcpRowFilter[o.Name]; f != "" {
				q += " WHERE " + f
			}
			if _, err := conn.ExecContext(ctx, q); err != nil {
				return fmt.Errorf("sandbox %s: %w", o.Name, err)
			}
		}
		_, err = conn.ExecContext(ctx, "COMMIT")
		return err
	}()
	if err != nil {
		conn.ExecContext(context.Background(), "ROLLBACK")
		return err
	}
	if _, err := conn.ExecContext(ctx, "DETACH DATABASE src"); err != nil {
		return err
	}
	// From here on: no further databases, no writes, limited size.
	if _, err := sqlite.Limit(conn, sqlite3.SQLITE_LIMIT_ATTACHED, 0); err != nil {
		return err
	}
	if _, err := sqlite.Limit(conn, sqlite3.SQLITE_LIMIT_LENGTH, sqlMaxResult); err != nil {
		return err
	}
	_, err = conn.ExecContext(ctx, "PRAGMA query_only = ON")
	return err
}

// runWrapped embeds the query:
//
//	WITH mcp_u(c0, c1, …) AS (<query>)
//	SELECT count(*), json_group_array(json_array(…)) FROM (SELECT * FROM mcp_u LIMIT n+1)
//
// This way the whole result is produced in a single sqlite3_step, which the
// driver interrupts when the context expires, and the query can only be a
// SELECT syntactically.
func runWrapped(ctx context.Context, conn *sql.Conn, body string) (QueryResult, error) {
	var cols []sqlite.ColumnInfo
	err := conn.Raw(func(dc any) error {
		ci, ok := dc.(interface {
			ColumnInfo(string) ([]sqlite.ColumnInfo, error)
		})
		if !ok {
			return fmt.Errorf("sqlite driver without ColumnInfo (%T)", dc)
		}
		var err error
		cols, err = ci.ColumnInfo(body)
		return err
	})
	if err != nil {
		return QueryResult{}, err
	}
	if len(cols) == 0 {
		return QueryResult{}, invalid("The query returns no columns. Only SELECT or WITH … SELECT is allowed.")
	}
	res := QueryResult{Columns: make([]string, len(cols))}
	aliases := make([]string, len(cols))
	cells := make([]string, len(cols))
	for i, c := range cols {
		res.Columns[i] = c.Name
		a := fmt.Sprintf("c%d", i)
		aliases[i] = a
		cells[i] = fmt.Sprintf("CASE typeof(%[1]s) WHEN 'blob' THEN '[BLOB, ' || length(%[1]s) || ' Bytes]' "+
			"WHEN 'text' THEN substr(%[1]s, 1, %[2]d) ELSE %[1]s END", a, sqlMaxCellRunes)
	}
	q := fmt.Sprintf("WITH mcp_u(%s) AS (\n%s\n)\nSELECT count(*), json_group_array(json_array(%s)) FROM (SELECT * FROM mcp_u LIMIT %d)",
		strings.Join(aliases, ", "), body, strings.Join(cells, ", "), SQLMaxRows+1)
	var n int
	var data string
	if err := conn.QueryRowContext(ctx, q).Scan(&n, &data); err != nil {
		return QueryResult{}, err
	}
	dec := json.NewDecoder(strings.NewReader(data))
	dec.UseNumber()
	var rows [][]any
	if err := dec.Decode(&rows); err != nil {
		return QueryResult{}, fmt.Errorf("read result: %w", err)
	}
	if len(rows) > SQLMaxRows {
		rows, res.Truncated = rows[:SQLMaxRows], true
	}
	for _, r := range rows {
		for j, v := range r {
			if num, ok := v.(json.Number); ok {
				if i, err := num.Int64(); err == nil {
					r[j] = i
				} else if f, err := num.Float64(); err == nil {
					r[j] = f
				}
			}
		}
	}
	res.Rows = rows
	if res.Rows == nil {
		res.Rows = [][]any{}
	}
	return res, nil
}

// checkSelect checks lexically that query is exactly one statement starting
// with SELECT or WITH and returns it without the trailing semicolon. The
// rules follow SQLite's tokenizer: '…', "…", `…` (doubling as escape), […],
// comments with -- and /* */.
func checkSelect(query string) (string, error) {
	if strings.IndexByte(query, 0) >= 0 {
		return "", invalid("The query contains a NUL character.")
	}
	end := len(query)
	first := ""
	for i := 0; i < len(query); {
		c := query[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v':
			i++
		case c == '-' && i+1 < len(query) && query[i+1] == '-':
			nl := strings.IndexByte(query[i:], '\n')
			if nl < 0 {
				i = len(query)
			} else {
				i += nl + 1
			}
		case c == '/' && i+1 < len(query) && query[i+1] == '*':
			e := strings.Index(query[i+2:], "*/")
			if e < 0 {
				i = len(query)
			} else {
				i += 2 + e + 2
			}
		case c == '\'' || c == '"' || c == '`':
			i = skipQuoted(query, i, c, c)
		case c == '[':
			i = skipQuoted(query, i, '[', ']')
		case c == ';':
			if end == len(query) {
				end = i
			}
			i++
		default:
			if end != len(query) {
				return "", invalid("Please send only a single query (no second statement after \";\").")
			}
			if first == "" {
				j := i
				for j < len(query) && (isLetter(query[j]) || query[j] == '_') {
					j++
				}
				first = strings.ToUpper(query[i:j])
				if first == "" {
					first = string(c)
				}
			}
			i++
		}
	}
	if first != "SELECT" && first != "WITH" {
		return "", invalid("Only a single read-only query is allowed (SELECT … or WITH … SELECT …).")
	}
	return query[:end], nil
}

func isLetter(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }

// skipQuoted returns the position after the literal that starts at i.
func skipQuoted(s string, i int, open, close byte) int {
	for j := i + 1; j < len(s); j++ {
		if s[j] != close {
			continue
		}
		if open == close && j+1 < len(s) && s[j+1] == close {
			j++ // doubled quote character
			continue
		}
		return j + 1
	}
	return len(s)
}

// --- Statistics ---------------------------------------------------------------

// Groupings for Stats (also the group_by values of the MCP statistics tool).
const (
	StatsByCategory      = "category"
	StatsByTitle         = "title"
	StatsByYear          = "year"
	StatsByMonth         = "month"
	StatsByWeek          = "week"
	StatsByPerson        = "person"
	StatsByCategoryMonth = "category_month"
)

// statsPeriod is the SQL expression of the period of each time grouping:
// "2026", "2026-09", ISO week "2026-W40".
var statsPeriod = map[string]string{
	StatsByYear:          "substr(e.date, 1, 4)",
	StatsByMonth:         "substr(e.date, 1, 7)",
	StatsByWeek:          "strftime('%G-W%V', e.date)",
	StatsByCategoryMonth: "substr(e.date, 1, 7)",
}

// StatsFilter controls Stats. Reimbursements and deleted expenses never count.
type StatsFilter struct {
	GroupBy       string    // StatsBy…
	From, To      time.Time // dates inclusive, zero value = open
	ParticipantID int64     // 0 = total amounts, otherwise only this person's share
	// CategoryID limits the statistics to one category (0 = all);
	// WithoutCategory to expenses without a category (label NoCategory).
	CategoryID      int64
	WithoutCategory bool
	// AnyText: only expenses whose title or notes contain one of the terms
	// (as ExpenseFilter.AnyText).
	AnyText []string
}

// StatRow is a row of the statistics. Depending on the grouping, Category,
// Title, Period and/or Person are set.
type StatRow struct {
	Category    string
	Title       string // for title: the title as in one of the expenses (grouped case-insensitively)
	Period      string // year "2026", month "2026-09" or ISO week "2026-W40"
	Person      string
	Count       int64 // number of expenses
	AmountCents int64 // sum (total amount or share; for person: the person's share)
	PaidCents   int64 // only for person: paid by the person
}

// NoCategory is the group label for expenses without a category.
const NoCategory = "No category"

// Stats sums up expenses (excluding reimbursements and deleted ones) by
// f.GroupBy. Time groupings are sorted by period, the others by amount
// (largest first); periods without expenses are missing (see FillPeriods).
func (s *Store) Stats(ctx context.Context, f StatsFilter) ([]StatRow, error) {
	where := []string{"e.deleted_at IS NULL", "e.is_reimbursement = 0"}
	var args []any
	if !f.From.IsZero() {
		where = append(where, "e.date >= ?")
		args = append(args, formatDate(f.From))
	}
	if !f.To.IsZero() {
		where = append(where, "e.date <= ?")
		args = append(args, formatDate(f.To))
	}
	switch {
	case f.WithoutCategory:
		where = append(where, "e.category_id IS NULL")
	case f.CategoryID != 0:
		where = append(where, "e.category_id = ?")
		args = append(args, f.CategoryID)
	}
	if c, a := textCond(f.AnyText...); c != "" {
		where = append(where, c)
		args = append(args, a...)
	}
	if f.GroupBy == StatsByPerson {
		return s.statsByPerson(ctx, where, args, f.ParticipantID)
	}

	from := "expenses e LEFT JOIN categories c ON c.id = e.category_id"
	amount := "e.amount_cents"
	if f.ParticipantID != 0 {
		from += " JOIN expense_shares x ON x.expense_id = e.id AND x.participant_id = ?"
		args = append([]any{f.ParticipantID}, args...)
		amount = "x.amount_cents"
	}
	cat := fmt.Sprintf("coalesce(c.name, '%s')", NoCategory)
	period := statsPeriod[f.GroupBy]
	// Columns: label (category or title), period.
	var sel, group, order string
	switch f.GroupBy {
	case StatsByCategory:
		sel, group, order = cat+", ''", cat, "4 DESC, 1"
	case StatsByTitle:
		sel, group, order = "max(e.title), ''", foldFunc+"(e.title)", "4 DESC, 1"
	case StatsByYear, StatsByMonth, StatsByWeek:
		sel, group, order = "'', "+period, period, "2"
	case StatsByCategoryMonth:
		sel, group, order = cat+", "+period, cat+", "+period, "2, 4 DESC, 1"
	default:
		return nil, invalid("Unknown grouping %q.", f.GroupBy)
	}
	q := fmt.Sprintf("SELECT %s, count(*), sum(%s) FROM %s WHERE %s GROUP BY %s ORDER BY %s",
		sel, amount, from, strings.Join(where, " AND "), group, order)
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []StatRow
	for rows.Next() {
		var r StatRow
		var label string
		if err := rows.Scan(&label, &r.Period, &r.Count, &r.AmountCents); err != nil {
			return nil, err
		}
		if f.GroupBy == StatsByTitle {
			r.Title = label
		} else {
			r.Category = label
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// IsTimeGrouping reports whether rows of groupBy are periods only (year,
// month, week).
func IsTimeGrouping(groupBy string) bool {
	return groupBy == StatsByYear || groupBy == StatsByMonth || groupBy == StatsByWeek
}

// PeriodOf returns the period of day for a time grouping (as in StatRow.Period).
func PeriodOf(groupBy string, day time.Time) string {
	switch groupBy {
	case StatsByYear:
		return day.Format("2006")
	case StatsByWeek:
		y, w := day.ISOWeek()
		return fmt.Sprintf("%d-W%02d", y, w)
	}
	return day.Format("2006-01")
}

// FillPeriods adds a row with 0 for every period of a time grouping between
// first and last (inclusive) that has no row. rows must be sorted by period.
func FillPeriods(rows []StatRow, groupBy string, first, last time.Time) []StatRow {
	if !IsTimeGrouping(groupBy) || last.Before(first) {
		return rows
	}
	have := make(map[string]StatRow, len(rows))
	for _, r := range rows {
		have[r.Period] = r
	}
	var out []StatRow
	add := func(p string) {
		if r, ok := have[p]; ok {
			out = append(out, r)
			delete(have, p)
		} else {
			out = append(out, StatRow{Period: p})
		}
	}
	end := PeriodOf(groupBy, last)
	for d := periodStart(groupBy, first); ; d = nextPeriod(groupBy, d) {
		p := PeriodOf(groupBy, d)
		add(p)
		if p >= end {
			break
		}
	}
	// Rows outside first…last stay.
	for _, r := range rows {
		if _, ok := have[r.Period]; ok {
			out = append(out, r)
		}
	}
	slices.SortStableFunc(out, func(a, b StatRow) int { return strings.Compare(a.Period, b.Period) })
	return out
}

// PeriodStart returns the first day of a period of a time grouping
// ("2026", "2026-09", "2026-W40"); zero if it cannot be parsed.
func PeriodStart(groupBy, period string) time.Time {
	var y, n int
	switch groupBy {
	case StatsByYear:
		if _, err := fmt.Sscanf(period, "%4d", &y); err != nil {
			return time.Time{}
		}
		return time.Date(y, 1, 1, 0, 0, 0, 0, time.UTC)
	case StatsByWeek:
		if _, err := fmt.Sscanf(period, "%4d-W%2d", &y, &n); err != nil {
			return time.Time{}
		}
		// 4 January is always in week 1.
		return periodStart(StatsByWeek, time.Date(y, 1, 4, 0, 0, 0, 0, time.UTC)).AddDate(0, 0, 7*(n-1))
	}
	if _, err := fmt.Sscanf(period, "%4d-%2d", &y, &n); err != nil {
		return time.Time{}
	}
	return time.Date(y, time.Month(n), 1, 0, 0, 0, 0, time.UTC)
}

// ShiftPeriodYear moves a period ("2025-09", "2025-W40", "2025") by years;
// "" stays "".
func ShiftPeriodYear(period string, years int) string {
	y, err := strconv.Atoi(period[:min(4, len(period))])
	if err != nil {
		return period
	}
	return fmt.Sprintf("%04d", y+years) + period[4:]
}

func periodStart(groupBy string, d time.Time) time.Time {
	y, m, day := d.Date()
	switch groupBy {
	case StatsByYear:
		return time.Date(y, 1, 1, 0, 0, 0, 0, time.UTC)
	case StatsByWeek:
		monday := time.Date(y, m, day, 0, 0, 0, 0, time.UTC)
		return monday.AddDate(0, 0, -(int(monday.Weekday())+6)%7)
	}
	return time.Date(y, m, 1, 0, 0, 0, 0, time.UTC)
}

func nextPeriod(groupBy string, d time.Time) time.Time {
	switch groupBy {
	case StatsByYear:
		return d.AddDate(1, 0, 0)
	case StatsByWeek:
		return d.AddDate(0, 0, 7)
	}
	return d.AddDate(0, 1, 0)
}

func (s *Store) statsByPerson(ctx context.Context, where []string, args []any, participantID int64) ([]StatRow, error) {
	cond := strings.Join(where, " AND ")
	pidCond := ""
	if participantID != 0 {
		pidCond = " AND p.id = ?"
		args = append(args, participantID)
	}
	q := fmt.Sprintf(`SELECT p.name,
		(SELECT count(*) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id WHERE x.participant_id = p.id AND %[1]s),
		(SELECT coalesce(sum(x.amount_cents), 0) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id WHERE x.participant_id = p.id AND %[1]s),
		(SELECT coalesce(sum(e.amount_cents), 0) FROM expenses e WHERE e.paid_by = p.id AND %[1]s)
		FROM participants p WHERE 1 = 1%[2]s`, cond, pidCond)
	// The conditions appear three times, so do the parameters.
	n := len(args)
	if participantID != 0 {
		n--
	}
	all := slices.Concat(args[:n], args[:n], args[:n], args[n:])
	rows, err := s.db.QueryContext(ctx, q, all...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []StatRow
	for rows.Next() {
		var r StatRow
		if err := rows.Scan(&r.Person, &r.Count, &r.AmountCents, &r.PaidCents); err != nil {
			return nil, err
		}
		if r.Count == 0 && r.PaidCents == 0 {
			continue
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	slices.SortStableFunc(out, func(a, b StatRow) int {
		if a.AmountCents != b.AmountCents {
			if a.AmountCents > b.AmountCents {
				return -1
			}
			return 1
		}
		return strings.Compare(strings.ToLower(a.Person), strings.ToLower(b.Person))
	})
	return out, nil
}
