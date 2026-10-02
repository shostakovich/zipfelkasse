package store

import (
	"cmp"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// Queries for the YNAB sync (package ynab). Tables: ynab_config (connection
// and sync status per person), ynab_category_map (app category → YNAB category per person) and
// ynab_sync (sync state per expense and person).

// YNABConfig is a person's YNAB connection. Token is secret: never print
// or log it.
type YNABConfig struct {
	ParticipantID int64
	Token         string    // Personal Access Token; "" = not connected
	PlanID        string    // YNAB plan (formerly "budget"; column budget_id)
	AccountID     string    // clearing account "Geteilt"
	StartDate     time.Time // expenses from this date on; zero value = not set
	Enabled       bool
	UpdatedAt     time.Time
	// ConnectedAt: since when plan and account have been chosen. Expenses
	// entered after that go to YNAB even if their date is before the start
	// date. Zero value = unknown (legacy data, see EnsureYNABConnectedAt).
	ConnectedAt time.Time
}

// Ready reports whether everything needed for a sync is set.
func (c YNABConfig) Ready() bool {
	return c.Enabled && c.Token != "" && c.PlanID != "" && c.AccountID != "" && !c.StartDate.IsZero()
}

const ynabConfigCols = "participant_id, token, budget_id, account_id, start_date, enabled, updated_at, connected_at"

func scanYNABConfig(row interface{ Scan(...any) error }) (YNABConfig, error) {
	var c YNABConfig
	var start, updated, connected sql.NullString
	if err := row.Scan(&c.ParticipantID, &c.Token, &c.PlanID, &c.AccountID, &start, &c.Enabled, &updated, &connected); err != nil {
		return c, err
	}
	if start.Valid && start.String != "" {
		t, err := parseDate(start.String)
		if err != nil {
			return c, err
		}
		c.StartDate = t
	}
	c.UpdatedAt = parseTime(updated)
	c.ConnectedAt = parseTime(connected)
	return c, nil
}

// GetYNABConfig returns a person's YNAB connection or ErrNotFound.
func (s *Store) GetYNABConfig(ctx context.Context, participantID int64) (YNABConfig, error) {
	return getYNABConfig(ctx, s.db, participantID)
}

func getYNABConfig(ctx context.Context, q interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}, participantID int64) (YNABConfig, error) {
	c, err := scanYNABConfig(q.QueryRowContext(ctx,
		"SELECT "+ynabConfigCols+" FROM ynab_config WHERE participant_id = ?", participantID))
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

// ListYNABConfigs returns all active connections with a token of
// non-archived people (whether fully set up is told by Ready).
func (s *Store) ListYNABConfigs(ctx context.Context) ([]YNABConfig, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT "+ynabConfigCols+` FROM ynab_config
		WHERE token != '' AND enabled = 1
		  AND participant_id IN (SELECT id FROM participants WHERE archived_at IS NULL)
		ORDER BY participant_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []YNABConfig
	for rows.Next() {
		c, err := scanYNABConfig(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// SetYNABToken sets (or replaces) a person's token and enables the
// connection. token "" disconnects (plan, account, mapping and sync state are
// kept so that reconnecting to the same account does not create duplicates).
// In the same write it resets what the status says about the old token
// (TokenInvalid, Error, RetryAt, Backoff); LastRun, LastSync and Summary
// stay.
//
// reachable tells whether the new token can reach a YNAB plan. If it cannot
// reach the chosen plan (token of another YNAB user), plan and account are
// reset as by SetYNABTarget with empty IDs, and targetReset is true;
// reachable nil keeps them. The activity entry names the person as actor.
func (s *Store) SetYNABToken(ctx context.Context, participantID int64, token string, reachable func(planID string) bool) (targetReset bool, err error) {
	err = s.inTx(ctx, func(tx *sql.Tx) error {
		old, err := getYNABConfig(ctx, tx, participantID)
		if err != nil && !errors.Is(err, ErrNotFound) {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO ynab_config (participant_id, token, enabled, updated_at)
			VALUES (?, ?, ?, ?)
			ON CONFLICT (participant_id) DO UPDATE SET
				token = excluded.token, enabled = excluded.enabled, updated_at = excluded.updated_at,
				token_invalid = 0, error = '', retry_at = NULL, backoff_seconds = 0`,
			participantID, token, token != "", s.nowString()); err != nil {
			return err
		}
		targetReset = token != "" && old.PlanID != "" && reachable != nil && !reachable(old.PlanID)
		if targetReset {
			if _, err := s.setYNABTarget(ctx, tx, participantID, "", "", old.StartDate); err != nil {
				return err
			}
		}
		var text string
		switch {
		case token == "":
			text = "YNAB-Verbindung getrennt"
		case targetReset:
			text = "YNAB-Token ersetzt (Plan und Konto zurückgesetzt)"
		case old.Token != "":
			text = "YNAB-Token ersetzt"
		default:
			text = "YNAB verbunden (Token gesetzt)"
		}
		return s.logSettings(ctx, tx, participantID, text)
	})
	return targetReset, err
}

// YNABTarget is where a person's expenses go in YNAB. The names are only for
// the activity log (the store does not know YNAB's names; "" = the ID).
type YNABTarget struct {
	PlanID, AccountID     string
	PlanName, AccountName string
	Start                 time.Time // zero value = not set
}

// SetYNABTarget sets plan, account and start date. The connection must
// exist (otherwise ErrNotFound). If plan or account change, ConnectedAt is
// reset and the person's sync rows are marked with YNABHashRetarget and
// without transaction ID: transactions in the old account stay there, and
// the sync first looks for each expense in the new account (it may be there
// already, e.g. after switching back) before creating it anew. A change of
// plan or account, or else of the start date, is logged with the person as
// actor.
func (s *Store) SetYNABTarget(ctx context.Context, participantID int64, t YNABTarget) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		old, err := s.setYNABTarget(ctx, tx, participantID, t.PlanID, t.AccountID, t.Start)
		if err != nil {
			return err
		}
		switch {
		case t.PlanID != old.PlanID || t.AccountID != old.AccountID:
			return s.logSettings(ctx, tx, participantID, fmt.Sprintf("YNAB: Konto „%s“ im Plan „%s“ gewählt, Startdatum %s",
				cmp.Or(t.AccountName, t.AccountID), cmp.Or(t.PlanName, t.PlanID), domain.FormatDate(t.Start)))
		case optionalDate(t.Start) != optionalDate(old.StartDate):
			return s.logSettings(ctx, tx, participantID, fmt.Sprintf("YNAB: Startdatum %s → %s",
				cmp.Or(domain.FormatDate(old.StartDate), "–"), domain.FormatDate(t.Start)))
		}
		return nil
	})
}

// setYNABTarget writes plan, account and start date in tx (see
// SetYNABTarget) and returns the connection as it was before.
func (s *Store) setYNABTarget(ctx context.Context, tx *sql.Tx, participantID int64, planID, accountID string, start time.Time) (YNABConfig, error) {
	old, err := getYNABConfig(ctx, tx, participantID)
	if err != nil {
		return old, err
	}
	var connected any // nil: keep connected_at
	if old.PlanID != planID || old.AccountID != accountID {
		if _, err := tx.ExecContext(ctx, `UPDATE ynab_sync SET ynab_txn_id = '', synced_hash = ?, synced_at = NULL, last_error = ''
			WHERE participant_id = ?`, YNABHashRetarget, participantID); err != nil {
			return old, err
		}
		connected = s.nowString()
	}
	_, err = tx.ExecContext(ctx, `UPDATE ynab_config SET budget_id = ?, account_id = ?, start_date = ?, updated_at = ?,
		connected_at = coalesce(?, connected_at)
		WHERE participant_id = ?`, planID, accountID, optionalDate(start), s.nowString(), connected, participantID)
	return old, err
}

// optionalDate formats a date column value: NULL for the zero value.
func optionalDate(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return formatDate(t)
}

// EnsureYNABConnectedAt returns the person's ConnectedAt and sets it to now
// if it is still missing (connections from before the value was introduced).
// Without a connection it returns ErrNotFound.
func (s *Store) EnsureYNABConnectedAt(ctx context.Context, participantID int64) (time.Time, error) {
	var v sql.NullString
	err := s.db.QueryRowContext(ctx, `UPDATE ynab_config SET connected_at = coalesce(connected_at, ?)
		WHERE participant_id = ? RETURNING connected_at`, s.nowString(), participantID).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, ErrNotFound
	}
	if err != nil {
		return time.Time{}, err
	}
	return parseTime(v), nil
}

// YNABStatus is the sync status of a person's connection. Its meaning (and
// the language of Summary and Error) is defined by package ynab, see
// ynab.Status.
type YNABStatus struct {
	LastRun      time.Time     // last attempt
	LastSync     time.Time     // last complete sync
	Summary      string        // result of the last sync
	Error        string        // error of the last attempt (without token)
	TokenInvalid bool          // YNAB rejected the token
	RetryAt      time.Time     // no requests before this
	Backoff      time.Duration // last delay after 429 (whole seconds)
}

const ynabStatusCols = "last_run, last_sync, summary, error, token_invalid, retry_at, backoff_seconds"

// GetYNABStatus returns a person's sync status, or ErrNotFound without a
// connection.
func (s *Store) GetYNABStatus(ctx context.Context, participantID int64) (YNABStatus, error) {
	var st YNABStatus
	var run, synced, retry sql.NullString
	var backoff int64
	err := s.db.QueryRowContext(ctx, "SELECT "+ynabStatusCols+" FROM ynab_config WHERE participant_id = ?", participantID).
		Scan(&run, &synced, &st.Summary, &st.Error, &st.TokenInvalid, &retry, &backoff)
	if errors.Is(err, sql.ErrNoRows) {
		return YNABStatus{}, ErrNotFound
	}
	if err != nil {
		return YNABStatus{}, err
	}
	st.LastRun, st.LastSync, st.RetryAt = parseTime(run), parseTime(synced), parseTime(retry)
	st.Backoff = time.Duration(backoff) * time.Second
	return st, nil
}

// SetYNABStatus overwrites a person's sync status. The connection must
// exist (otherwise ErrNotFound).
func (s *Store) SetYNABStatus(ctx context.Context, participantID int64, st YNABStatus) error {
	res, err := s.db.ExecContext(ctx, `UPDATE ynab_config SET last_run = ?, last_sync = ?, summary = ?, error = ?,
		token_invalid = ?, retry_at = ?, backoff_seconds = ? WHERE participant_id = ?`,
		statusTime(st.LastRun), statusTime(st.LastSync), st.Summary, st.Error,
		st.TokenInvalid, statusTime(st.RetryAt), int64(st.Backoff/time.Second), participantID)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil {
		return err
	} else if n == 0 {
		return ErrNotFound
	}
	return nil
}

// statusTime formats t for the status columns: NULL for the zero value,
// otherwise with fractional seconds so that RetryAt survives exactly.
func statusTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC().Format(time.RFC3339Nano)
}

// YNABCategoryMap returns the mapping app category → YNAB category ID.
func (s *Store) YNABCategoryMap(ctx context.Context, participantID int64) (map[int64]string, error) {
	return ynabCategoryMap(ctx, s.db, participantID)
}

func ynabCategoryMap(ctx context.Context, q queryer, participantID int64) (map[int64]string, error) {
	rows, err := q.QueryContext(ctx,
		"SELECT category_id, ynab_category_id FROM ynab_category_map WHERE participant_id = ?", participantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	m := map[int64]string{}
	for rows.Next() {
		var id int64
		var y string
		if err := rows.Scan(&id, &y); err != nil {
			return nil, err
		}
		m[id] = y
	}
	return m, rows.Err()
}

// SetYNABCategoryMap replaces a person's complete mapping. Empty values mean
// "no mapping" (uncategorized in YNAB). ynabNames (YNAB category ID → name)
// is only for the activity log, which lists the changed mappings with the
// person as actor.
func (s *Store) SetYNABCategoryMap(ctx context.Context, participantID int64, m map[int64]string, ynabNames map[string]string) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		old, err := ynabCategoryMap(ctx, tx, participantID)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM ynab_category_map WHERE participant_id = ?", participantID); err != nil {
			return err
		}
		for catID, ynabID := range m {
			if ynabID == "" {
				continue
			}
			var n int
			if err := tx.QueryRowContext(ctx, "SELECT count(*) FROM categories WHERE id = ?", catID).Scan(&n); err != nil {
				return err
			}
			if n == 0 {
				return invalid("Unbekannte Kategorie.")
			}
			if _, err := tx.ExecContext(ctx,
				"INSERT INTO ynab_category_map (participant_id, category_id, ynab_category_id) VALUES (?, ?, ?)",
				participantID, catID, ynabID); err != nil {
				return err
			}
		}
		text, err := mappingChanges(ctx, tx, old, m, ynabNames)
		if err != nil || text == "" {
			return err
		}
		return s.logSettings(ctx, tx, participantID, "YNAB: Kategorie-Zuordnung geändert ("+text+")")
	})
}

// mappingChanges describes the differences between the old and the new
// category mapping for the activity log: "Lebensmittel → Lebensmittel &
// Drogerie, Kino → unkategorisiert (vorher Freizeit)" (in the order of the
// app categories).
func mappingChanges(ctx context.Context, tx *sql.Tx, old, now map[int64]string, ynabNames map[string]string) (string, error) {
	rows, err := tx.QueryContext(ctx, "SELECT "+categoryCols+" FROM categories ORDER BY position, name COLLATE NOCASE, id")
	if err != nil {
		return "", err
	}
	defer rows.Close()
	ynabName := func(id string) string {
		if id == "" {
			return "unkategorisiert"
		}
		return cmp.Or(ynabNames[id], "(nicht mehr vorhanden)")
	}
	var parts []string
	for rows.Next() {
		c, err := scanCategory(rows)
		if err != nil {
			return "", err
		}
		o, n := old[c.ID], now[c.ID]
		if o == n {
			continue
		}
		p := c.Name + " → " + ynabName(n)
		if o != "" {
			p += " (vorher " + ynabName(o) + ")"
		}
		parts = append(parts, p)
	}
	return strings.Join(parts, ", "), rows.Err()
}

// YNABSync is the sync state of an expense for a person.
// TxnID "" means there is (as far as we know) no transaction in YNAB.
// Hash is the fingerprint of the last transferred target state; its meaning
// is defined by package ynab (except YNABHashRetarget).
type YNABSync struct {
	ExpenseID     int64
	ParticipantID int64
	TxnID         string
	Hash          string
	SyncedAt      time.Time // zero value = never succeeded
	LastError     string
}

// YNABHashRetarget is the Hash of sync rows after a change of plan or account
// (see SetYNABTarget).
const YNABHashRetarget = "retarget"

// ListYNABSync returns all of a person's sync rows.
func (s *Store) ListYNABSync(ctx context.Context, participantID int64) ([]YNABSync, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT expense_id, participant_id, ynab_txn_id, synced_hash, synced_at, last_error
		FROM ynab_sync WHERE participant_id = ? ORDER BY expense_id`, participantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []YNABSync
	for rows.Next() {
		var r YNABSync
		var at sql.NullString
		if err := rows.Scan(&r.ExpenseID, &r.ParticipantID, &r.TxnID, &r.Hash, &at, &r.LastError); err != nil {
			return nil, err
		}
		r.SyncedAt = parseTime(at)
		out = append(out, r)
	}
	return out, rows.Err()
}

// PutYNABSync creates or overwrites sync rows (in one transaction).
func (s *Store) PutYNABSync(ctx context.Context, rows ...YNABSync) error {
	if len(rows) == 0 {
		return nil
	}
	return s.inTx(ctx, func(tx *sql.Tx) error {
		for _, r := range rows {
			var at any
			if !r.SyncedAt.IsZero() {
				at = r.SyncedAt.UTC().Format(timeLayout)
			}
			if _, err := tx.ExecContext(ctx, `INSERT INTO ynab_sync
				(expense_id, participant_id, ynab_txn_id, synced_hash, synced_at, last_error) VALUES (?, ?, ?, ?, ?, ?)
				ON CONFLICT (expense_id, participant_id) DO UPDATE SET
					ynab_txn_id = excluded.ynab_txn_id, synced_hash = excluded.synced_hash,
					synced_at = excluded.synced_at, last_error = excluded.last_error`,
				r.ExpenseID, r.ParticipantID, r.TxnID, r.Hash, at, r.LastError); err != nil {
				return err
			}
		}
		return nil
	})
}

// DeleteYNABSync removes a person's sync rows.
func (s *Store) DeleteYNABSync(ctx context.Context, participantID int64, expenseIDs ...int64) error {
	if len(expenseIDs) == 0 {
		return nil
	}
	return s.inTx(ctx, func(tx *sql.Tx) error {
		for _, id := range expenseIDs {
			if _, err := tx.ExecContext(ctx, "DELETE FROM ynab_sync WHERE participant_id = ? AND expense_id = ?",
				participantID, id); err != nil {
				return err
			}
		}
		return nil
	})
}

// YNABSyncProblem is an expense whose last sync failed.
type YNABSyncProblem struct {
	ExpenseID int64
	Title     string
	Date      time.Time
	Error     string
}

// YNABSyncSummary returns the number of a person's transactions present in
// YNAB and the expenses with errors (newest first).
func (s *Store) YNABSyncSummary(ctx context.Context, participantID int64) (synced int, problems []YNABSyncProblem, err error) {
	if err := s.db.QueryRowContext(ctx,
		"SELECT count(*) FROM ynab_sync WHERE participant_id = ? AND ynab_txn_id != ''", participantID).Scan(&synced); err != nil {
		return 0, nil, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT y.expense_id, e.title, e.date, y.last_error
		FROM ynab_sync y JOIN expenses e ON e.id = y.expense_id
		WHERE y.participant_id = ? AND y.last_error != ''
		ORDER BY e.date DESC, e.id DESC`, participantID)
	if err != nil {
		return 0, nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var p YNABSyncProblem
		var d string
		if err := rows.Scan(&p.ExpenseID, &p.Title, &d, &p.Error); err != nil {
			return 0, nil, err
		}
		if p.Date, err = parseDate(d); err != nil {
			return 0, nil, err
		}
		problems = append(problems, p)
	}
	return synced, problems, rows.Err()
}
