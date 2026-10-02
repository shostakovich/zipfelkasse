package store

import (
	"cmp"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// Queries needed only by the web UI (package web).

// SetGroupName changes the group name. Empty or overly long names yield a
// domain.ValidationError. Only an actual change of the name is logged.
func (s *Store) SetGroupName(ctx context.Context, actorID int64, name string) error {
	name, err := cleanName(name, "die Gruppe")
	if err != nil {
		return err
	}
	return s.inTx(ctx, func(tx *sql.Tx) error {
		var old string
		err := tx.QueryRowContext(ctx, "SELECT value FROM settings WHERE key = ?", SettingGroupName).Scan(&old)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		old = cmp.Or(old, defaultGroupName)
		if _, err := tx.ExecContext(ctx, setSettingSQL, SettingGroupName, name); err != nil || old == name {
			return err
		}
		return s.logSettings(ctx, tx, actorID, fmt.Sprintf("Gruppe umbenannt: „%s“ → „%s“", old, name))
	})
}

// MoveCategory moves an active category one position up (up) or down in
// the display order, among the active categories. Afterwards the positions
// of the active categories are renumbered (10, 20, …); CreateCategory still
// sorts new categories in before "Sonstiges", wherever it is. Nothing happens
// (and nothing is logged) at the edges. Unknown or archived categories yield
// ErrNotFound.
func (s *Store) MoveCategory(ctx context.Context, actorID, id int64, up bool) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		active, err := activeCategories(ctx, tx)
		if err != nil {
			return err
		}
		ids := make([]int64, len(active))
		idx := -1
		for i, c := range active {
			ids[i] = c.ID
			if c.ID == id {
				idx = i
			}
		}
		if idx < 0 {
			return ErrNotFound
		}
		other, dir := idx+1, "unten"
		if up {
			other, dir = idx-1, "oben"
		}
		if other < 0 || other >= len(ids) {
			return nil
		}
		ids[idx], ids[other] = ids[other], ids[idx]
		if err := renumberCategories(ctx, tx, ids); err != nil {
			return err
		}
		return s.logSettings(ctx, tx, actorID, fmt.Sprintf("Kategorie „%s“ nach %s verschoben", active[idx].Name, dir))
	})
}

// ExpenseCountByCategory returns the number of non-deleted expenses per
// category (for category management). Categories without expenses are missing.
func (s *Store) ExpenseCountByCategory(ctx context.Context) (map[int64]int, error) {
	return s.countBy(ctx, `SELECT category_id, count(*) FROM expenses
		WHERE deleted_at IS NULL AND category_id IS NOT NULL GROUP BY category_id`)
}

// ExpenseCountByParticipant returns the number of non-deleted expenses a
// person is involved in (as payer or with a share).
func (s *Store) ExpenseCountByParticipant(ctx context.Context) (map[int64]int, error) {
	return s.countBy(ctx, `SELECT pid, count(DISTINCT eid) FROM (
			SELECT e.paid_by AS pid, e.id AS eid FROM expenses e WHERE e.deleted_at IS NULL
			UNION ALL
			SELECT x.participant_id, x.expense_id FROM expense_shares x
				JOIN expenses e ON e.id = x.expense_id WHERE e.deleted_at IS NULL
		) GROUP BY pid`)
}

func (s *Store) countBy(ctx context.Context, q string) (map[int64]int, error) {
	rows, err := s.db.QueryContext(ctx, strings.TrimSpace(q))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64]int{}
	for rows.Next() {
		var id int64
		var n int
		if err := rows.Scan(&id, &n); err != nil {
			return nil, err
		}
		out[id] = n
	}
	return out, rows.Err()
}

// TitleCategory is the title and category of a past expense (for category
// suggestions).
type TitleCategory struct {
	Title      string
	CategoryID int64
}

// CategoryHistory returns title and category of all non-deleted expenses
// with an active category, newest first. Reimbursements are left out.
func (s *Store) CategoryHistory(ctx context.Context) ([]TitleCategory, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT e.title, e.category_id FROM expenses e
		JOIN categories c ON c.id = e.category_id
		WHERE e.deleted_at IS NULL AND e.is_reimbursement = 0 AND c.archived_at IS NULL
		ORDER BY e.date DESC, e.id DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TitleCategory
	for rows.Next() {
		var tc TitleCategory
		if err := rows.Scan(&tc.Title, &tc.CategoryID); err != nil {
			return nil, err
		}
		out = append(out, tc)
	}
	return out, rows.Err()
}
