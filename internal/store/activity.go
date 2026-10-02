package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"time"
)

// Aktionen im Aktivitätsprotokoll. Feature-Pakete dürfen eigene Aktionen
// ergänzen (z. B. "recurring_created"); die Aktivitätsseite zeigt
// unbekannte Aktionen mit Details.Text an.
const (
	ActionExpenseCreated = "expense_created"
	ActionExpenseUpdated = "expense_updated"
	ActionExpenseDeleted = "expense_deleted"
	// ActionSettingsUpdated: Einstellungen geändert (Personen, Kategorien,
	// Kurse, Wiederholungen, YNAB …); Details.Text beschreibt die Änderung.
	ActionSettingsUpdated = "settings_updated"
)

// ActivityDetails ist der Inhalt von activity.details_json.
type ActivityDetails struct {
	Title       string        `json:"title,omitempty"`        // Titel der Ausgabe (Stand nach der Aktion)
	AmountCents int64         `json:"amount_cents,omitempty"` // Betrag der Ausgabe
	Changes     []FieldChange `json:"changes,omitempty"`      // bei expense_updated
	Text        string        `json:"text,omitempty"`         // freie Beschreibung für sonstige Aktionen
}

// FieldChange ist eine geänderte Eigenschaft, bereits für die Anzeige
// formatiert (deutsche Feldnamen, formatierte Werte).
type FieldChange struct {
	Field string `json:"field"`
	Old   string `json:"old"`
	New   string `json:"new"`
}

// Activity ist ein Eintrag im Aktivitätsprotokoll.
type Activity struct {
	ID        int64
	At        time.Time
	ActorID   int64  // 0 = System
	ActorName string // "" bei System
	Action    string
	ExpenseID int64 // 0 = ohne Bezug
	Details   ActivityDetails
}

// ActivityFilter schränkt ListActivity ein.
type ActivityFilter struct {
	ExpenseID int64 // nur Einträge zu dieser Ausgabe
	BeforeID  int64 // für Blättern: nur Einträge mit kleinerer ID
	Limit     int   // 0 = 100
}

func (s *Store) insertActivity(ctx context.Context, tx *sql.Tx, actorID int64, action string, expenseID int64, d ActivityDetails) error {
	js, err := json.Marshal(d)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx,
		"INSERT INTO activity (at, actor_id, action, expense_id, details_json) VALUES (?, ?, ?, ?, ?)",
		s.nowString(), nullInt(actorID), action, nullInt(expenseID), string(js))
	return err
}

// AddActivity schreibt einen eigenen Eintrag (für Aktionen außerhalb der
// Ausgaben-Methoden, die ihre Einträge selbst schreiben).
func (s *Store) AddActivity(ctx context.Context, actorID int64, action string, expenseID int64, d ActivityDetails) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		return s.insertActivity(ctx, tx, actorID, action, expenseID, d)
	})
}

// ListActivity liefert die neuesten Einträge zuerst.
func (s *Store) ListActivity(ctx context.Context, f ActivityFilter) ([]Activity, error) {
	var where []string
	var args []any
	if f.ExpenseID != 0 {
		where = append(where, "a.expense_id = ?")
		args = append(args, f.ExpenseID)
	}
	if f.BeforeID != 0 {
		where = append(where, "a.id < ?")
		args = append(args, f.BeforeID)
	}
	if f.Limit <= 0 {
		f.Limit = 100
	}
	q := `SELECT a.id, a.at, a.actor_id, coalesce(p.name, ''), a.action, a.expense_id, a.details_json
		FROM activity a LEFT JOIN participants p ON p.id = a.actor_id`
	if len(where) > 0 {
		q += " WHERE " + strings.Join(where, " AND ")
	}
	q += " ORDER BY a.id DESC LIMIT ?"
	args = append(args, f.Limit)
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Activity
	for rows.Next() {
		var a Activity
		var at sql.NullString
		var actor, expense sql.NullInt64
		var details string
		if err := rows.Scan(&a.ID, &at, &actor, &a.ActorName, &a.Action, &expense, &details); err != nil {
			return nil, err
		}
		a.At, a.ActorID, a.ExpenseID = parseTime(at), actor.Int64, expense.Int64
		_ = json.Unmarshal([]byte(details), &a.Details) // kaputte Details sind kein Grund, die Liste scheitern zu lassen
		out = append(out, a)
	}
	return out, rows.Err()
}
