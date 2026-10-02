package store

import (
	"context"
	"database/sql"
	"strings"
)

// Queries needed only by the web UI (package web).

// SetGroupName changes the group name. Empty or overly long names yield a
// domain.ValidationError.
func (s *Store) SetGroupName(ctx context.Context, name string) error {
	name, err := cleanName(name, "die Gruppe")
	if err != nil {
		return err
	}
	return s.SetSetting(ctx, SettingGroupName, name)
}

// MoveCategory moves an active category one position up (up) or down in
// the display order, among the active categories. Afterwards the positions
// of the active categories are renumbered (10, 20, …), so new categories end
// up at the end. Nothing happens at the edges. Unknown or archived categories
// yield ErrNotFound.
func (s *Store) MoveCategory(ctx context.Context, id int64, up bool) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		rows, err := tx.QueryContext(ctx,
			"SELECT id FROM categories WHERE archived_at IS NULL ORDER BY position, name COLLATE NOCASE, id")
		if err != nil {
			return err
		}
		var ids []int64
		for rows.Next() {
			var v int64
			if err := rows.Scan(&v); err != nil {
				rows.Close()
				return err
			}
			ids = append(ids, v)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		idx := -1
		for i, v := range ids {
			if v == id {
				idx = i
			}
		}
		if idx < 0 {
			return ErrNotFound
		}
		other := idx + 1
		if up {
			other = idx - 1
		}
		if other < 0 || other >= len(ids) {
			return nil
		}
		ids[idx], ids[other] = ids[other], ids[idx]
		for i, v := range ids {
			if _, err := tx.ExecContext(ctx, "UPDATE categories SET position = ? WHERE id = ?", (i+1)*10, v); err != nil {
				return err
			}
		}
		return nil
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
