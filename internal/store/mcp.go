package store

// Queries für den MCP-Server (internal/mcp): Statistik, Schema und die
// schreibgeschützte SQL-Sandbox für das Tool sql_abfrage.

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// MCPTables sind die Tabellen, die über MCP (schema, sql_abfrage) sichtbar
// sind. Bewusst eine Positivliste: Neue Tabellen sind erst sichtbar, wenn sie
// hier stehen. Die YNAB-Tabellen (Token!) fehlen absichtlich.
var MCPTables = []string{
	"participants", "categories", "expenses", "expense_shares",
	"recurring", "activity", "fx_rates", "settings",
}

// mcpRowFilter schränkt einzelne Tabellen beim Kopieren in die Sandbox ein.
var mcpRowFilter = map[string]string{
	"settings": `key NOT LIKE 'ynab%'`, // eigene Schlüssel von YNAB (ynab.…) nie zeigen
}

// Grenzen der SQL-Sandbox.
const (
	SQLMaxRows      = 500             // so viele Zeilen liefert ReadOnlyQuery höchstens
	SQLTimeout      = 5 * time.Second // Gesamtdauer inkl. Kopie
	sqlMaxCellRunes = 2000            // längere Texte werden gekürzt
	sqlMaxResult    = 8 << 20         // Bytes, sqlite3_limit(SQLITE_LIMIT_LENGTH)
)

// QueryResult ist das Ergebnis von ReadOnlyQuery. Rows enthält int64,
// float64, string oder nil.
type QueryResult struct {
	Columns   []string
	Rows      [][]any
	Truncated bool // es gab mehr als SQLMaxRows Zeilen
}

// SchemaObject ist eine Tabelle oder ein Index samt CREATE-Statement.
type SchemaObject struct {
	Type string // "table" | "index"
	Name string
	SQL  string
}

// MCPSchema liefert die CREATE-Statements der über MCP sichtbaren Tabellen
// (MCPTables) und ihrer Indizes.
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

// ReadOnlyQuery führt eine einzelne SELECT-/WITH-Abfrage in einer Sandbox aus
// und liefert höchstens SQLMaxRows Zeilen.
//
// Die Sandbox ist eine frische In-Memory-Datenbank: Die Tabellen aus
// MCPTables werden über eine schreibgeschützte Verbindung (ATTACH
// 'file:<pfad>?mode=ro') in einer Lese-Transaktion hineinkopiert, danach wird
// die Datei wieder abgehängt. Die Abfrage sieht also nur diese Kopie – die
// YNAB-Tabellen samt Token existieren dort gar nicht. Zusätzlich: ATTACH ist
// per sqlite3_limit verboten, PRAGMA query_only ist an, die Abfrage muss
// lexikalisch genau ein SELECT/WITH sein und wird als Unterabfrage in eine
// Aggregation eingebettet (dadurch läuft sie in einem einzigen, per Context
// abbrechbaren Schritt). Eingabefehler sind domain.ValidationError.
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

// sandboxErr übersetzt Fehler in verständliche Meldungen. SQLite-Fehler
// (Syntax, unbekannte Tabelle …) gehen als ValidationError an den Aufrufer.
func sandboxErr(ctx context.Context, err error) error {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) {
		return invalid("Die Abfrage wurde nach %d s abgebrochen. Bitte einschränken (WHERE, LIMIT) oder vereinfachen.", int(SQLTimeout/time.Second))
	}
	var ve domain.ValidationError
	if errors.As(err, &ve) {
		return err
	}
	var se *sqlite.Error
	if errors.As(err, &se) {
		if se.Code() == sqlite3.SQLITE_TOOBIG {
			return invalid("Das Ergebnis ist zu groß. Bitte weniger Spalten/Zeilen abfragen.")
		}
		return invalid("SQL-Fehler: %s", strings.TrimPrefix(se.Error(), "SQL logic error: "))
	}
	return err
}

// sandbox baut die In-Memory-Kopie und liefert die (abgesicherte) Verbindung.
func (s *Store) sandbox(ctx context.Context) (*sql.Conn, func(), error) {
	if s.path == ":memory:" || s.path == "" {
		return nil, nil, invalid("sql_abfrage braucht eine Datenbankdatei (nicht verfügbar bei :memory:).")
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
		return fmt.Errorf("datenbank schreibgeschützt öffnen: %w", err)
	}
	// Lese-Transaktion: alle Tabellen aus demselben Stand.
	err := func() error {
		if _, err := conn.ExecContext(ctx, "BEGIN"); err != nil {
			return err
		}
		objs, err := schemaObjects(ctx, conn, "src")
		if err != nil {
			return err
		}
		// Erst Tabellen, dann Indizes (schemaObjects sortiert so).
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
	// Ab hier: keine weiteren Datenbanken, keine Schreibzugriffe, begrenzte Größe.
	if _, err := sqlite.Limit(conn, sqlite3.SQLITE_LIMIT_ATTACHED, 0); err != nil {
		return err
	}
	if _, err := sqlite.Limit(conn, sqlite3.SQLITE_LIMIT_LENGTH, sqlMaxResult); err != nil {
		return err
	}
	_, err = conn.ExecContext(ctx, "PRAGMA query_only = ON")
	return err
}

// runWrapped bettet die Abfrage ein:
//
//	WITH mcp_u(c0, c1, …) AS (<abfrage>)
//	SELECT count(*), json_group_array(json_array(…)) FROM (SELECT * FROM mcp_u LIMIT n+1)
//
// So entsteht das ganze Ergebnis in einem einzigen sqlite3_step, den der
// Treiber bei Ablauf des Contexts unterbricht, und die Abfrage kann
// syntaktisch nur ein SELECT sein.
func runWrapped(ctx context.Context, conn *sql.Conn, body string) (QueryResult, error) {
	var cols []sqlite.ColumnInfo
	err := conn.Raw(func(dc any) error {
		ci, ok := dc.(interface {
			ColumnInfo(string) ([]sqlite.ColumnInfo, error)
		})
		if !ok {
			return fmt.Errorf("sqlite-treiber ohne ColumnInfo (%T)", dc)
		}
		var err error
		cols, err = ci.ColumnInfo(body)
		return err
	})
	if err != nil {
		return QueryResult{}, err
	}
	if len(cols) == 0 {
		return QueryResult{}, invalid("Die Abfrage liefert keine Spalten. Erlaubt ist nur SELECT bzw. WITH … SELECT.")
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
		return QueryResult{}, fmt.Errorf("ergebnis lesen: %w", err)
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

// checkSelect prüft lexikalisch, dass query genau eine Anweisung ist, die mit
// SELECT oder WITH beginnt, und liefert sie ohne abschließendes Semikolon.
// Die Regeln entsprechen SQLites Tokenizer: '…', "…", `…` (Verdopplung als
// Escape), […], Kommentare mit -- und /* */.
func checkSelect(query string) (string, error) {
	if strings.IndexByte(query, 0) >= 0 {
		return "", invalid("Die Abfrage enthält ein NUL-Zeichen.")
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
				return "", invalid("Bitte nur eine einzelne Abfrage schicken (kein zweites Statement nach „;“).")
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
		return "", invalid("Erlaubt ist nur eine einzelne lesende Abfrage (SELECT … oder WITH … SELECT …).")
	}
	return query[:end], nil
}

func isLetter(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }

// skipQuoted liefert die Position hinter dem Literal, das bei i beginnt.
func skipQuoted(s string, i int, open, close byte) int {
	for j := i + 1; j < len(s); j++ {
		if s[j] != close {
			continue
		}
		if open == close && j+1 < len(s) && s[j+1] == close {
			j++ // verdoppeltes Anführungszeichen
			continue
		}
		return j + 1
	}
	return len(s)
}

// --- Statistik ----------------------------------------------------------------

// Gruppierungen für Stats.
const (
	StatsByCategory      = "kategorie"
	StatsByMonth         = "monat"
	StatsByPerson        = "person"
	StatsByCategoryMonth = "kategorie_monat"
)

// StatsFilter steuert Stats. Rückzahlungen und gelöschte Ausgaben zählen nie.
type StatsFilter struct {
	GroupBy       string    // StatsBy…
	From, To      time.Time // Datum inklusive, Nullwert = offen
	ParticipantID int64     // 0 = Gesamtbeträge, sonst nur der Anteil dieser Person
	// CategoryID limits the statistics to one category (0 = all);
	// WithoutCategory to expenses without a category (label NoCategory).
	CategoryID      int64
	WithoutCategory bool
}

// StatRow ist eine Zeile der Statistik. Je nach Gruppierung sind Category,
// Month ("YYYY-MM") und/oder Person gesetzt.
type StatRow struct {
	Category    string
	Month       string
	Person      string
	Count       int64 // Zahl der Ausgaben
	AmountCents int64 // Summe (Gesamtbetrag bzw. Anteil; bei person: Anteil der Person)
	PaidCents   int64 // nur bei person: von der Person bezahlt
}

// NoCategory ist der Gruppenname für Ausgaben ohne Kategorie.
const NoCategory = "Ohne Kategorie"

// Stats summiert Ausgaben (ohne Rückzahlungen und gelöschte) nach f.GroupBy.
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
	month := "substr(e.date, 1, 7)"
	var sel, group, order string
	switch f.GroupBy {
	case StatsByCategory:
		sel, group, order = cat+", ''", cat, "4 DESC, 1"
	case StatsByMonth:
		sel, group, order = "'', "+month, month, "2"
	case StatsByCategoryMonth:
		sel, group, order = cat+", "+month, cat+", "+month, "2, 4 DESC, 1"
	default:
		return nil, invalid("Unbekannte Gruppierung „%s“.", f.GroupBy)
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
		if err := rows.Scan(&r.Category, &r.Month, &r.Count, &r.AmountCents); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
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
	// Die Bedingungen kommen dreimal vor, die Parameter also auch.
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
