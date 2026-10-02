package store

import (
	"context"
	"database/sql"
	"errors"
	"strconv"
	"time"
)

// Queries for the YNAB sync (package ynab). Tables: ynab_config (per person),
// ynab_category_map (app category → YNAB category per person) and
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
	// ConnectedAt: since when plan and account have been chosen (settings key
	// "ynab.connected.<id>"). Expenses entered after that go to YNAB even if
	// their date is before the start date. Zero value = unknown (legacy data,
	// see EnsureYNABConnectedAt).
	ConnectedAt time.Time
}

// ynabConnectedKey is the settings key for YNABConfig.ConnectedAt (like all
// ynab.… keys, invisible to MCP).
func ynabConnectedKey(participantID int64) string {
	return "ynab.connected." + strconv.FormatInt(participantID, 10)
}

// Ready reports whether everything needed for a sync is set.
func (c YNABConfig) Ready() bool {
	return c.Enabled && c.Token != "" && c.PlanID != "" && c.AccountID != "" && !c.StartDate.IsZero()
}

const ynabConfigCols = "participant_id, token, budget_id, account_id, start_date, enabled, updated_at, " +
	"(SELECT value FROM settings WHERE key = 'ynab.connected.' || participant_id)"

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
	c, err := scanYNABConfig(s.db.QueryRowContext(ctx,
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
func (s *Store) SetYNABToken(ctx context.Context, participantID int64, token string) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO ynab_config (participant_id, token, enabled, updated_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT (participant_id) DO UPDATE SET
			token = excluded.token, enabled = excluded.enabled, updated_at = excluded.updated_at`,
		participantID, token, token != "", s.nowString())
	return err
}

// SetYNABTarget sets plan, account and start date. The connection must
// exist (otherwise ErrNotFound). If plan or account change, the person's sync
// state is discarded (transactions in the old account stay there, everything
// is created anew in the new account) and ConnectedAt is reset.
func (s *Store) SetYNABTarget(ctx context.Context, participantID int64, planID, accountID string, start time.Time) error {
	var startVal any
	if !start.IsZero() {
		startVal = formatDate(start)
	}
	return s.inTx(ctx, func(tx *sql.Tx) error {
		var oldPlan, oldAccount string
		err := tx.QueryRowContext(ctx, "SELECT budget_id, account_id FROM ynab_config WHERE participant_id = ?",
			participantID).Scan(&oldPlan, &oldAccount)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if oldPlan != planID || oldAccount != accountID {
			if _, err := tx.ExecContext(ctx, "DELETE FROM ynab_sync WHERE participant_id = ?", participantID); err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx, `INSERT INTO settings (key, value) VALUES (?, ?)
				ON CONFLICT (key) DO UPDATE SET value = excluded.value`, ynabConnectedKey(participantID), s.nowString()); err != nil {
				return err
			}
		}
		_, err = tx.ExecContext(ctx, `UPDATE ynab_config SET budget_id = ?, account_id = ?, start_date = ?, updated_at = ?
			WHERE participant_id = ?`, planID, accountID, startVal, s.nowString(), participantID)
		return err
	})
}

// EnsureYNABConnectedAt returns the person's ConnectedAt and sets it to now
// if it is still missing (connections from before the value was introduced).
func (s *Store) EnsureYNABConnectedAt(ctx context.Context, participantID int64) (time.Time, error) {
	key := ynabConnectedKey(participantID)
	if _, err := s.db.ExecContext(ctx, "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO NOTHING",
		key, s.nowString()); err != nil {
		return time.Time{}, err
	}
	v, err := s.GetSetting(ctx, key)
	if err != nil {
		return time.Time{}, err
	}
	return parseTime(sql.NullString{String: v, Valid: true}), nil
}

// YNABCategoryMap returns the mapping app category → YNAB category ID.
func (s *Store) YNABCategoryMap(ctx context.Context, participantID int64) (map[int64]string, error) {
	rows, err := s.db.QueryContext(ctx,
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
// "no mapping" (uncategorized in YNAB).
func (s *Store) SetYNABCategoryMap(ctx context.Context, participantID int64, m map[int64]string) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
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
		return nil
	})
}

// YNABSync is the sync state of an expense for a person.
// TxnID "" means there is (as far as we know) no transaction in YNAB.
// Hash is the fingerprint of the last transferred target state; its meaning
// is defined by package ynab.
type YNABSync struct {
	ExpenseID     int64
	ParticipantID int64
	TxnID         string
	Hash          string
	SyncedAt      time.Time // zero value = never succeeded
	LastError     string
}

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
