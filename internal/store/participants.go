package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
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

// CreateParticipant creates a person, with actorID as the actor of the
// activity entry. Duplicate names (case-insensitive) yield a
// domain.ValidationError.
func (s *Store) CreateParticipant(ctx context.Context, actorID int64, name string) (int64, error) {
	return s.createParticipant(ctx, actorID, false, name)
}

// JoinAsParticipant creates a person who adds themselves (who page, before
// they have an identity): the activity entry names the new person as actor.
// Errors as in CreateParticipant.
func (s *Store) JoinAsParticipant(ctx context.Context, name string) (int64, error) {
	return s.createParticipant(ctx, 0, true, name)
}

// createParticipant creates a person; self makes the new person the actor.
func (s *Store) createParticipant(ctx context.Context, actorID int64, self bool, name string) (int64, error) {
	name, err := cleanName(name, "die Person")
	if err != nil {
		return 0, err
	}
	var id int64
	err = s.inTx(ctx, func(tx *sql.Tx) error {
		res, err := tx.ExecContext(ctx, "INSERT INTO participants (name, created_at) VALUES (?, ?)", name, s.nowString())
		if isUniqueViolation(err) {
			return invalid("„%s“ gibt es schon.", name)
		}
		if err != nil {
			return err
		}
		if id, err = res.LastInsertId(); err != nil {
			return err
		}
		if self {
			actorID = id
		}
		return s.logSettings(ctx, tx, actorID, fmt.Sprintf("Person „%s“ hinzugefügt", name))
	})
	if err != nil {
		return 0, err
	}
	return id, nil
}

// getParticipant reads a person in tx (ErrNotFound if missing).
func getParticipant(ctx context.Context, tx *sql.Tx, id int64) (Participant, error) {
	p, err := scanParticipant(tx.QueryRowContext(ctx, "SELECT "+participantCols+" FROM participants WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return p, ErrNotFound
	}
	return p, err
}

// RenameParticipant renames a person. Only an actual change of the name is
// logged.
func (s *Store) RenameParticipant(ctx context.Context, actorID, id int64, name string) error {
	name, err := cleanName(name, "die Person")
	if err != nil {
		return err
	}
	return s.inTx(ctx, func(tx *sql.Tx) error {
		old, err := getParticipant(ctx, tx, id)
		if err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, "UPDATE participants SET name = ? WHERE id = ?", name, id)
		if isUniqueViolation(err) {
			return invalid("„%s“ gibt es schon.", name)
		}
		if err != nil || old.Name == name {
			return err
		}
		return s.logSettings(ctx, tx, actorID, fmt.Sprintf("Person „%s“ umbenannt in „%s“", old.Name, name))
	})
}

// SetParticipantArchived archives or restores a person. A person with an open
// balance cannot be archived (domain.ValidationError); otherwise they would
// disappear from forms while money is still owed. Check and archiving run in
// one transaction, so that no expense can come in between.
func (s *Store) SetParticipantArchived(ctx context.Context, actorID, id int64, archived bool) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		p, err := getParticipant(ctx, tx, id)
		if err != nil {
			return err
		}
		verb, at := "reaktiviert", any(nil)
		if archived {
			var balance int64
			if err := tx.QueryRowContext(ctx, `SELECT
				(SELECT coalesce(sum(amount_cents), 0) FROM expenses WHERE paid_by = ?1 AND deleted_at IS NULL) -
				(SELECT coalesce(sum(x.amount_cents), 0) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id
					WHERE x.participant_id = ?1 AND e.deleted_at IS NULL)`, id).Scan(&balance); err != nil {
				return err
			}
			if balance != 0 {
				return invalid("%s hat noch einen Saldo von %s. Bitte erst ausgleichen, dann archivieren.", p.Name, domain.FormatCents(balance))
			}
			verb, at = "archiviert", s.nowString()
		}
		if _, err := tx.ExecContext(ctx, "UPDATE participants SET archived_at = ? WHERE id = ?", at, id); err != nil {
			return err
		}
		return s.logSettings(ctx, tx, actorID, fmt.Sprintf("Person „%s“ %s", p.Name, verb))
	})
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
