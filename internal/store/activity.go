package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"time"
)

// Activity log actions. Feature packages may add their own actions
// (e.g. "recurring_created"); the activity page shows unknown actions
// using Details.Text.
const (
	ActionExpenseCreated = "expense_created"
	ActionExpenseUpdated = "expense_updated"
	ActionExpenseDeleted = "expense_deleted"
	// ActionSettingsUpdated: settings changed (people, categories, rates,
	// recurrences, YNAB …); Details.Text describes the change.
	ActionSettingsUpdated = "settings_updated"
	// ActionSharesRecalculated: a migration recomputed the cent shares of
	// existing expenses (system, Details.Text).
	ActionSharesRecalculated = "shares_recalculated"
	// ActionWeightsConverted: a migration converted the weights of existing
	// expenses (system, Details.Text).
	ActionWeightsConverted = "weights_converted"
)

// ActivityDetails is the content of activity.details_json.
type ActivityDetails struct {
	Title       string        `json:"title,omitempty"`        // expense title (as of after the action)
	AmountCents int64         `json:"amount_cents,omitempty"` // expense amount
	Changes     []FieldChange `json:"changes,omitempty"`      // for expense_updated
	Text        string        `json:"text,omitempty"`         // free-form description for other actions
}

// FieldChange is a changed property, already formatted for display
// (German field names, formatted values).
type FieldChange struct {
	Field string `json:"field"`
	Old   string `json:"old"`
	New   string `json:"new"`
}

// Activity is an entry in the activity log.
type Activity struct {
	ID        int64
	At        time.Time
	ActorID   int64  // 0 = system
	ActorName string // "" for system
	Action    string
	ExpenseID int64 // 0 = not related to an expense
	Details   ActivityDetails
}

// ActivityFilter narrows ListActivity.
type ActivityFilter struct {
	ExpenseID int64 // only entries for this expense
	BeforeID  int64 // for paging: only entries with a smaller ID
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

// AddActivity writes a custom entry (for actions outside the expense
// methods, which write their own entries).
func (s *Store) AddActivity(ctx context.Context, actorID int64, action string, expenseID int64, d ActivityDetails) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		return s.insertActivity(ctx, tx, actorID, action, expenseID, d)
	})
}

// ListActivity returns the newest entries first.
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
		_ = json.Unmarshal([]byte(details), &a.Details) // broken details are no reason to fail the whole list
		out = append(out, a)
	}
	return out, rows.Err()
}
