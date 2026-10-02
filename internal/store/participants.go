package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// Participant is a person in the group. People are never deleted, only
// archived (ArchivedAt not null).
type Participant struct {
	ID         int64
	Name       string
	CreatedAt  time.Time
	ArchivedAt time.Time
}

func (p Participant) Archived() bool { return !p.ArchivedAt.IsZero() }

const participantCols = "id, name, created_at, archived_at"

func scanParticipant(row interface{ Scan(...any) error }) (Participant, error) {
	var p Participant
	var created, archived sql.NullString
	if err := row.Scan(&p.ID, &p.Name, &created, &archived); err != nil {
		return p, err
	}
	p.CreatedAt, p.ArchivedAt = parseTime(created), parseTime(archived)
	return p, nil
}

// ListParticipants returns people alphabetically, archived ones only on request.
func (s *Store) ListParticipants(ctx context.Context, includeArchived bool) ([]Participant, error) {
	q := "SELECT " + participantCols + " FROM participants"
	if !includeArchived {
		q += " WHERE archived_at IS NULL"
	}
	q += " ORDER BY name COLLATE NOCASE, id"
	rows, err := s.db.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Participant
	for rows.Next() {
		p, err := scanParticipant(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// GetParticipant returns a person (archived ones too) or ErrNotFound.
func (s *Store) GetParticipant(ctx context.Context, id int64) (Participant, error) {
	p, err := scanParticipant(s.db.QueryRowContext(ctx, "SELECT "+participantCols+" FROM participants WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return p, ErrNotFound
	}
	return p, err
}

// CreateParticipant creates a person. Duplicate names (case-insensitive)
// yield a domain.ValidationError.
func (s *Store) CreateParticipant(ctx context.Context, name string) (int64, error) {
	name, err := cleanName(name, "die Person")
	if err != nil {
		return 0, err
	}
	res, err := s.db.ExecContext(ctx, "INSERT INTO participants (name, created_at) VALUES (?, ?)", name, s.nowString())
	if isUniqueViolation(err) {
		return 0, invalid("„%s“ gibt es schon.", name)
	}
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// RenameParticipant renames a person.
func (s *Store) RenameParticipant(ctx context.Context, id int64, name string) error {
	name, err := cleanName(name, "die Person")
	if err != nil {
		return err
	}
	res, err := s.db.ExecContext(ctx, "UPDATE participants SET name = ? WHERE id = ?", name, id)
	if isUniqueViolation(err) {
		return invalid("„%s“ gibt es schon.", name)
	}
	return checkAffected(res, err)
}

// SetParticipantArchived archives or restores a person.
func (s *Store) SetParticipantArchived(ctx context.Context, id int64, archived bool) error {
	var v any
	if archived {
		v = s.nowString()
	}
	res, err := s.db.ExecContext(ctx, "UPDATE participants SET archived_at = ? WHERE id = ?", v, id)
	return checkAffected(res, err)
}

func checkAffected(res sql.Result, err error) error {
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
