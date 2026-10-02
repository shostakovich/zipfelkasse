package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Category is an expense category. Categories are only ever archived.
type Category struct {
	ID         int64
	Name       string
	Position   int64
	ArchivedAt time.Time
}

func (c Category) Archived() bool { return !c.ArchivedAt.IsZero() }

const categoryCols = "id, name, position, archived_at"

func scanCategory(row interface{ Scan(...any) error }) (Category, error) {
	var c Category
	var archived sql.NullString
	if err := row.Scan(&c.ID, &c.Name, &c.Position, &archived); err != nil {
		return c, err
	}
	c.ArchivedAt = parseTime(archived)
	return c, nil
}

// ListCategories returns categories in display order.
func (s *Store) ListCategories(ctx context.Context, includeArchived bool) ([]Category, error) {
	q := "SELECT " + categoryCols + " FROM categories"
	if !includeArchived {
		q += " WHERE archived_at IS NULL"
	}
	q += " ORDER BY position, name COLLATE NOCASE, id"
	rows, err := s.db.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Category
	for rows.Next() {
		c, err := scanCategory(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// GetCategory returns a category (archived ones too) or ErrNotFound.
func (s *Store) GetCategory(ctx context.Context, id int64) (Category, error) {
	c, err := scanCategory(s.db.QueryRowContext(ctx, "SELECT "+categoryCols+" FROM categories WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

// otherCategory is the catch-all category: new categories are sorted in
// before it, wherever it has been moved to.
const otherCategory = "Sonstiges"

// CreateCategory creates a category directly before the active category
// "Sonstiges" (case-insensitive), or at the end without one. The positions of
// the active categories are then renumbered (10, 20, …), as in MoveCategory.
func (s *Store) CreateCategory(ctx context.Context, actorID int64, name string) (int64, error) {
	name, err := cleanName(name, "die Kategorie")
	if err != nil {
		return 0, err
	}
	var id int64
	err = s.inTx(ctx, func(tx *sql.Tx) error {
		active, err := activeCategories(ctx, tx)
		if err != nil {
			return err
		}
		res, err := tx.ExecContext(ctx, "INSERT INTO categories (name, position) VALUES (?, 0)", name)
		if isUniqueViolation(err) {
			return invalid("Die Kategorie „%s“ gibt es schon.", name)
		}
		if err != nil {
			return err
		}
		if id, err = res.LastInsertId(); err != nil {
			return err
		}
		at := len(active)
		for i, c := range active {
			if strings.EqualFold(c.Name, otherCategory) {
				at = i
				break
			}
		}
		ids := make([]int64, 0, len(active)+1)
		for _, c := range active[:at] {
			ids = append(ids, c.ID)
		}
		ids = append(ids, id)
		for _, c := range active[at:] {
			ids = append(ids, c.ID)
		}
		if err := renumberCategories(ctx, tx, ids); err != nil {
			return err
		}
		return s.logSettings(ctx, tx, actorID, fmt.Sprintf("Kategorie „%s“ hinzugefügt", name))
	})
	if err != nil {
		return 0, err
	}
	return id, nil
}

// activeCategories returns the active categories in display order.
func activeCategories(ctx context.Context, tx *sql.Tx) ([]Category, error) {
	rows, err := tx.QueryContext(ctx, "SELECT "+categoryCols+" FROM categories WHERE archived_at IS NULL ORDER BY position, name COLLATE NOCASE, id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Category
	for rows.Next() {
		c, err := scanCategory(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// renumberCategories sets the positions of the categories ids to 10, 20, …
// in this order.
func renumberCategories(ctx context.Context, tx *sql.Tx, ids []int64) error {
	for i, id := range ids {
		if _, err := tx.ExecContext(ctx, "UPDATE categories SET position = ? WHERE id = ?", (i+1)*10, id); err != nil {
			return err
		}
	}
	return nil
}

// getCategory reads a category in tx (ErrNotFound if missing).
func getCategory(ctx context.Context, tx *sql.Tx, id int64) (Category, error) {
	c, err := scanCategory(tx.QueryRowContext(ctx, "SELECT "+categoryCols+" FROM categories WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

// RenameCategory renames a category. Only an actual change of the name is
// logged.
func (s *Store) RenameCategory(ctx context.Context, actorID, id int64, name string) error {
	name, err := cleanName(name, "die Kategorie")
	if err != nil {
		return err
	}
	return s.inTx(ctx, func(tx *sql.Tx) error {
		old, err := getCategory(ctx, tx, id)
		if err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, "UPDATE categories SET name = ? WHERE id = ?", name, id)
		if isUniqueViolation(err) {
			return invalid("Die Kategorie „%s“ gibt es schon.", name)
		}
		if err != nil || old.Name == name {
			return err
		}
		return s.logSettings(ctx, tx, actorID, fmt.Sprintf("Kategorie „%s“ umbenannt in „%s“", old.Name, name))
	})
}

// SetCategoryArchived archives or restores a category.
func (s *Store) SetCategoryArchived(ctx context.Context, actorID, id int64, archived bool) error {
	verb, at := "reaktiviert", any(nil)
	if archived {
		verb, at = "archiviert", s.nowString()
	}
	return s.inTx(ctx, func(tx *sql.Tx) error {
		c, err := getCategory(ctx, tx, id)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "UPDATE categories SET archived_at = ? WHERE id = ?", at, id); err != nil {
			return err
		}
		return s.logSettings(ctx, tx, actorID, fmt.Sprintf("Kategorie „%s“ %s", c.Name, verb))
	})
}
