// Package store encapsulates the SQLite database: schema/migrations, queries,
// activity log, backup and the change hook for expenses.
//
// Feature packages put their own queries in internal/store/<package>.go
// (e.g. store/ynab.go) and use s.db or s.tx directly there.
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

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// ErrNotFound is returned when a record does not exist (or, for expenses,
// is already deleted where that matters).
var ErrNotFound = errors.New("not found")

// Store is Zipfelkasse's database. All methods are safe for concurrent use.
type Store struct {
	db   *sql.DB
	path string

	hooksMu sync.RWMutex
	hooks   []func(ExpenseChange)

	// now can be overridden in tests.
	now func() time.Time
}

// Open opens (or creates) the database at path and applies missing
// migrations. path ":memory:" creates an ephemeral database (tests).
// Settings: WAL, foreign_keys=ON, busy_timeout=5s, synchronous=NORMAL,
// transactions with BEGIN IMMEDIATE.
func Open(path string) (*Store, error) {
	memory := path == ":memory:"
	if !memory {
		if dir := filepath.Dir(path); dir != "" {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return nil, fmt.Errorf("create database directory: %w", err)
			}
		}
	}
	dsn := path + "?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_txlock=immediate"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	if memory {
		// Otherwise every connection would get its own empty database.
		db.SetMaxOpenConns(1)
	}
	s := &Store{db: db, path: path, now: time.Now}
	if err := s.migrate(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

// Close closes the database.
func (s *Store) Close() error { return s.db.Close() }

// Path is the database file path (":memory:" in tests).
func (s *Store) Path() string { return s.path }

// Ping checks whether the database is reachable (health check).
func (s *Store) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

// SchemaVersion returns PRAGMA user_version.
func (s *Store) SchemaVersion(ctx context.Context) (int, error) {
	var v int
	err := s.db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&v)
	return v, err
}

// goMigrations are migrations written in Go for data fixes that SQL alone
// cannot do. They share the numbering with migrations/*.sql.
var goMigrations = map[int]func(s *Store, ctx context.Context, tx *sql.Tx) error{
	2: (*Store).resplitShares,
	4: (*Store).convertAmountWeights,
}

// migrate applies all migrations (migrations/NNN_*.sql and goMigrations)
// whose number is greater than PRAGMA user_version, each in its own
// transaction.
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
			return fmt.Errorf("migration %s: file name must start with NNN_", base)
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
			return fmt.Errorf("migration %d is defined twice", m.n)
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

// inTx runs fn in a transaction (commit on nil, rollback otherwise).
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

// ExpenseChange describes a successfully stored change to an expense.
// Action is ActionExpenseCreated, ActionExpenseUpdated or
// ActionExpenseDeleted.
type ExpenseChange struct {
	ExpenseID int64
	Action    string
}

// OnExpenseChange registers fn; fn is called after every successful commit
// of an expense change (create, update, delete), synchronously in the
// caller's goroutine. So fn must not block (e.g. only enqueue into a
// queue/channel) and must not keep using the request context.
// Register at startup, before the first request.
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

// Time formats in the database.
const timeLayout = time.RFC3339

// SetClock replaces the store's clock (timestamps such as created_at); for
// tests only, including those of other packages. Do not call concurrently
// with writes.
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

// cleanName validates and normalizes names of people/categories.
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
