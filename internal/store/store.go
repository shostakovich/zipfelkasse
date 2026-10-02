// Package store kapselt die SQLite-Datenbank: Schema/Migrationen, Queries,
// Activity-Log, Backup und den Change-Hook für Ausgaben.
//
// Feature-Pakete legen ihre eigenen Queries in internal/store/<paket>.go ab
// (z. B. store/ynab.go) und nutzen dort s.db bzw. s.tx direkt.
package store

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"

	"teilen/internal/domain"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// ErrNotFound wird geliefert, wenn ein Datensatz nicht existiert (oder bei
// Ausgaben: bereits gelöscht ist, wo das relevant ist).
var ErrNotFound = errors.New("nicht gefunden")

// Store ist die Datenbank von teilen. Alle Methoden sind nebenläufig nutzbar.
type Store struct {
	db   *sql.DB
	path string

	hooksMu sync.RWMutex
	hooks   []func(ExpenseChange)

	// now ist in Tests überschreibbar.
	now func() time.Time
}

// Open öffnet (bzw. erzeugt) die Datenbank unter path und spielt fehlende
// Migrationen ein. path ":memory:" erzeugt eine flüchtige Datenbank (Tests).
// Einstellungen: WAL, foreign_keys=ON, busy_timeout=5s, synchronous=NORMAL,
// Transaktionen mit BEGIN IMMEDIATE.
func Open(path string) (*Store, error) {
	memory := path == ":memory:"
	if !memory {
		if dir := filepath.Dir(path); dir != "" {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return nil, fmt.Errorf("datenbankverzeichnis anlegen: %w", err)
			}
		}
	}
	dsn := path + "?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_txlock=immediate"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	if memory {
		// Jede Verbindung hätte sonst ihre eigene, leere Datenbank.
		db.SetMaxOpenConns(1)
	}
	s := &Store{db: db, path: path, now: time.Now}
	if err := s.migrate(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

// Close schließt die Datenbank.
func (s *Store) Close() error { return s.db.Close() }

// Path ist der Dateipfad der Datenbank (":memory:" in Tests).
func (s *Store) Path() string { return s.path }

// Ping prüft, ob die Datenbank erreichbar ist (Health-Check).
func (s *Store) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

// SchemaVersion liefert PRAGMA user_version.
func (s *Store) SchemaVersion(ctx context.Context) (int, error) {
	var v int
	err := s.db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&v)
	return v, err
}

// goMigrations sind Migrationen in Go für Datenkorrekturen, die SQL allein
// nicht kann. Sie teilen sich den Nummernkreis mit migrations/*.sql.
var goMigrations = map[int]func(s *Store, ctx context.Context, tx *sql.Tx) error{
	2: (*Store).resplitShares,
}

// migrate spielt alle Migrationen (migrations/NNN_*.sql und goMigrations)
// ein, deren Nummer größer als PRAGMA user_version ist, jede in einer eigenen
// Transaktion.
func (s *Store) migrate(ctx context.Context) error {
	names, err := fs.Glob(migrationsFS, "migrations/*.sql")
	if err != nil {
		return err
	}
	type migration struct {
		n    int
		name string
		fn   func(s *Store, ctx context.Context, tx *sql.Tx) error
	}
	var ms []migration
	for _, name := range names {
		base := filepath.Base(name)
		num, _, ok := strings.Cut(base, "_")
		n, err := strconv.Atoi(num)
		if !ok || err != nil || n <= 0 {
			return fmt.Errorf("migration %s: dateiname muss mit NNN_ beginnen", base)
		}
		ms = append(ms, migration{n: n, name: name})
	}
	for n, fn := range goMigrations {
		ms = append(ms, migration{n: n, name: fmt.Sprintf("%03d (Go)", n), fn: fn})
	}
	slices.SortFunc(ms, func(a, b migration) int { return a.n - b.n })

	current, err := s.SchemaVersion(ctx)
	if err != nil {
		return err
	}
	for i, m := range ms {
		if i > 0 && ms[i-1].n == m.n {
			return fmt.Errorf("migration %d doppelt vergeben", m.n)
		}
		if m.n <= current {
			continue
		}
		err = s.inTx(ctx, func(tx *sql.Tx) error {
			if m.fn != nil {
				if err := m.fn(s, ctx, tx); err != nil {
					return err
				}
			} else {
				body, err := migrationsFS.ReadFile(m.name)
				if err != nil {
					return err
				}
				if _, err := tx.ExecContext(ctx, string(body)); err != nil {
					return err
				}
			}
			_, err := tx.ExecContext(ctx, fmt.Sprintf("PRAGMA user_version = %d", m.n))
			return err
		})
		if err != nil {
			return fmt.Errorf("migration %s: %w", filepath.Base(m.name), err)
		}
	}
	return nil
}

// inTx führt fn in einer Transaktion aus (Commit bei nil, sonst Rollback).
func (s *Store) inTx(ctx context.Context, fn func(tx *sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

// ExpenseChange beschreibt eine erfolgreich gespeicherte Änderung an einer
// Ausgabe. Action ist ActionExpenseCreated, ActionExpenseUpdated oder
// ActionExpenseDeleted.
type ExpenseChange struct {
	ExpenseID int64
	Action    string
}

// OnExpenseChange registriert fn; fn wird nach jedem erfolgreichen Commit
// einer Ausgaben-Änderung (Anlegen, Ändern, Löschen) aufgerufen – synchron im
// Goroutine des Aufrufers. fn darf also nicht blockieren (z. B. nur in eine
// Queue/Channel einreihen) und keinen Request-Context weiterverwenden.
// Registrierung beim Start, vor dem ersten Request.
func (s *Store) OnExpenseChange(fn func(ExpenseChange)) {
	s.hooksMu.Lock()
	defer s.hooksMu.Unlock()
	s.hooks = append(s.hooks, fn)
}

func (s *Store) notify(c ExpenseChange) {
	s.hooksMu.RLock()
	hooks := slices.Clone(s.hooks)
	s.hooksMu.RUnlock()
	for _, fn := range hooks {
		fn(c)
	}
}

// Zeitformate in der Datenbank.
const timeLayout = time.RFC3339

// SetClock ersetzt die Uhr des Stores (Zeitstempel wie created_at); nur für
// Tests, auch anderer Pakete. Nicht nebenläufig zu Schreibzugriffen aufrufen.
func (s *Store) SetClock(now func() time.Time) { s.now = now }

func (s *Store) nowString() string { return s.now().UTC().Format(timeLayout) }

func formatDate(t time.Time) string { return t.Format(domain.DateLayout) }

func parseDate(v string) (time.Time, error) { return time.Parse(domain.DateLayout, v) }

func parseTime(v sql.NullString) time.Time {
	if !v.Valid || v.String == "" {
		return time.Time{}
	}
	t, err := time.Parse(timeLayout, v.String)
	if err != nil {
		return time.Time{}
	}
	return t
}

func nullInt(v int64) sql.NullInt64 { return sql.NullInt64{Int64: v, Valid: v != 0} }

func isUniqueViolation(err error) bool {
	var se *sqlite.Error
	return errors.As(err, &se) && (se.Code() == sqlite3.SQLITE_CONSTRAINT_UNIQUE || se.Code() == sqlite3.SQLITE_CONSTRAINT_PRIMARYKEY)
}

func invalid(format string, args ...any) error {
	return domain.ValidationError{Msg: fmt.Sprintf(format, args...)}
}

// cleanName prüft und normalisiert Namen von Personen/Kategorien.
func cleanName(name, what string) (string, error) {
	name = strings.Join(strings.Fields(name), " ")
	if name == "" {
		return "", invalid("Bitte einen Namen für %s angeben.", what)
	}
	if len([]rune(name)) > 60 {
		return "", invalid("Der Name ist zu lang (höchstens 60 Zeichen).")
	}
	return name, nil
}
