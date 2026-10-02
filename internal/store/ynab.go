package store

import (
	"context"
	"database/sql"
	"errors"
	"strconv"
	"time"
)

// Queries für den YNAB-Sync (Paket ynab). Tabellen: ynab_config (pro Person),
// ynab_category_map (App-Kategorie → YNAB-Kategorie pro Person) und
// ynab_sync (Abgleichsstand je Ausgabe und Person).

// YNABConfig ist die YNAB-Verbindung einer Person. Token ist geheim: nie
// ausgeben oder loggen.
type YNABConfig struct {
	ParticipantID int64
	Token         string    // Personal Access Token; "" = nicht verbunden
	PlanID        string    // YNAB-Plan (früher „Budget“; Spalte budget_id)
	AccountID     string    // Verrechnungskonto „Geteilt“
	StartDate     time.Time // Ausgaben ab diesem Datum; Nullwert = nicht gesetzt
	Enabled       bool
	UpdatedAt     time.Time
	// ConnectedAt: seit wann Plan und Konto gewählt sind (settings-Schlüssel
	// "ynab.connected.<id>"). Danach erfasste Ausgaben gehen auch dann nach
	// YNAB, wenn ihr Datum vor dem Startdatum liegt. Nullwert = unbekannt
	// (Altbestand, siehe EnsureYNABConnectedAt).
	ConnectedAt time.Time
}

// ynabConnectedKey ist der settings-Schlüssel für YNABConfig.ConnectedAt
// (wie alle ynab.…-Schlüssel für MCP unsichtbar).
func ynabConnectedKey(participantID int64) string {
	return "ynab.connected." + strconv.FormatInt(participantID, 10)
}

// Ready meldet, ob alles für einen Sync gesetzt ist.
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

// GetYNABConfig liefert die YNAB-Verbindung einer Person oder ErrNotFound.
func (s *Store) GetYNABConfig(ctx context.Context, participantID int64) (YNABConfig, error) {
	c, err := scanYNABConfig(s.db.QueryRowContext(ctx,
		"SELECT "+ynabConfigCols+" FROM ynab_config WHERE participant_id = ?", participantID))
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

// ListYNABConfigs liefert alle aktiven Verbindungen mit Token von nicht
// archivierten Personen (ob vollständig eingerichtet, sagt Ready).
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

// SetYNABToken setzt (oder ersetzt) den Token einer Person und aktiviert die
// Verbindung. token "" trennt die Verbindung (Plan, Konto, Zuordnung und
// Abgleichsstand bleiben erhalten, damit ein erneutes Verbinden mit demselben
// Konto keine Dubletten erzeugt).
func (s *Store) SetYNABToken(ctx context.Context, participantID int64, token string) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO ynab_config (participant_id, token, enabled, updated_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT (participant_id) DO UPDATE SET
			token = excluded.token, enabled = excluded.enabled, updated_at = excluded.updated_at`,
		participantID, token, token != "", s.nowString())
	return err
}

// SetYNABTarget setzt Plan, Konto und Startdatum. Die Verbindung muss
// existieren (sonst ErrNotFound). Wechseln Plan oder Konto, wird der
// Abgleichsstand der Person verworfen (die Buchungen im alten Konto bleiben
// dort, im neuen Konto wird alles neu angelegt) und ConnectedAt neu gesetzt.
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

// EnsureYNABConnectedAt liefert ConnectedAt der Person und setzt es auf
// jetzt, falls es noch fehlt (Verbindungen von vor Einführung des Werts).
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

// YNABCategoryMap liefert die Zuordnung App-Kategorie → YNAB-Kategorie-ID.
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

// SetYNABCategoryMap ersetzt die komplette Zuordnung einer Person. Leere
// Werte bedeuten „keine Zuordnung“ (in YNAB unkategorisiert).
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

// YNABSync ist der Abgleichsstand einer Ausgabe für eine Person.
// TxnID "" heißt: In YNAB gibt es (nach unserem Wissen) keine Buchung.
// Hash ist der Fingerabdruck des zuletzt übertragenen Soll-Zustands; seine
// Bedeutung legt das Paket ynab fest.
type YNABSync struct {
	ExpenseID     int64
	ParticipantID int64
	TxnID         string
	Hash          string
	SyncedAt      time.Time // Nullwert = noch nie erfolgreich
	LastError     string
}

// ListYNABSync liefert alle Abgleichszeilen einer Person.
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

// PutYNABSync legt Abgleichszeilen an bzw. überschreibt sie (eine Transaktion).
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

// DeleteYNABSync entfernt Abgleichszeilen einer Person.
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

// YNABSyncProblem ist eine Ausgabe, deren letzter Abgleich fehlschlug.
type YNABSyncProblem struct {
	ExpenseID int64
	Title     string
	Date      time.Time
	Error     string
}

// YNABSyncSummary liefert die Zahl der in YNAB vorhandenen Buchungen einer
// Person und die Ausgaben mit Fehlern (neueste zuerst).
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
