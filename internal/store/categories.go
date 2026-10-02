package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// Category ist eine Ausgabenkategorie. Kategorien werden nur archiviert.
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

// ListCategories liefert Kategorien in Anzeigereihenfolge.
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

// GetCategory liefert eine Kategorie (auch archiviert) oder ErrNotFound.
func (s *Store) GetCategory(ctx context.Context, id int64) (Category, error) {
	c, err := scanCategory(s.db.QueryRowContext(ctx, "SELECT "+categoryCols+" FROM categories WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

// CreateCategory legt eine Kategorie an (vor „Sonstiges“ einsortiert).
func (s *Store) CreateCategory(ctx context.Context, name string) (int64, error) {
	name, err := cleanName(name, "die Kategorie")
	if err != nil {
		return 0, err
	}
	res, err := s.db.ExecContext(ctx, `INSERT INTO categories (name, position)
		VALUES (?, (SELECT coalesce(max(position), 0) + 10 FROM categories WHERE position < 1000))`, name)
	if isUniqueViolation(err) {
		return 0, invalid("Die Kategorie „%s“ gibt es schon.", name)
	}
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// RenameCategory benennt eine Kategorie um.
func (s *Store) RenameCategory(ctx context.Context, id int64, name string) error {
	name, err := cleanName(name, "die Kategorie")
	if err != nil {
		return err
	}
	res, err := s.db.ExecContext(ctx, "UPDATE categories SET name = ? WHERE id = ?", name, id)
	if isUniqueViolation(err) {
		return invalid("Die Kategorie „%s“ gibt es schon.", name)
	}
	return checkAffected(res, err)
}

// SetCategoryArchived archiviert eine Kategorie bzw. holt sie zurück.
func (s *Store) SetCategoryArchived(ctx context.Context, id int64, archived bool) error {
	var v any
	if archived {
		v = s.nowString()
	}
	res, err := s.db.ExecContext(ctx, "UPDATE categories SET archived_at = ? WHERE id = ?", v, id)
	return checkAffected(res, err)
}
