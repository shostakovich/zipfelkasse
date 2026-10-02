package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// Aktionen im Aktivitätsprotokoll für wiederkehrende Ausgaben.
const (
	ActionRecurringCreated = "recurring_created"
	ActionRecurringDeleted = "recurring_deleted"
)

// Recurring ist eine Regel für eine wiederkehrende Ausgabe.
type Recurring struct {
	ID        int64
	Template  ExpenseInput // Vorlage; Date und RecurringID darin sind bedeutungslos
	Frequency domain.Frequency
	StartDate time.Time // Anker, von dem aus alle Termine berechnet werden
	NextDate  time.Time // nächster noch nicht angelegter Termin
	Active    bool
	CreatedBy int64 // 0 = unbekannt
	CreatedAt time.Time
	UpdatedAt time.Time
}

const recurringCols = "id, template_json, frequency, start_date, next_date, active, created_by, created_at, updated_at"

func scanRecurring(row interface{ Scan(...any) error }) (Recurring, error) {
	var r Recurring
	var tmpl, freq, start, next string
	var createdBy sql.NullInt64
	var created, updated sql.NullString
	if err := row.Scan(&r.ID, &tmpl, &freq, &start, &next, &r.Active, &createdBy, &created, &updated); err != nil {
		return r, err
	}
	if err := json.Unmarshal([]byte(tmpl), &r.Template); err != nil {
		return r, fmt.Errorf("wiederholung %d: vorlage: %w", r.ID, err)
	}
	var err error
	if r.StartDate, err = parseDate(start); err != nil {
		return r, fmt.Errorf("wiederholung %d: start_date %q: %w", r.ID, start, err)
	}
	if r.NextDate, err = parseDate(next); err != nil {
		return r, fmt.Errorf("wiederholung %d: next_date %q: %w", r.ID, next, err)
	}
	r.Frequency = domain.Frequency(freq)
	r.CreatedBy = createdBy.Int64
	r.CreatedAt, r.UpdatedAt = parseTime(created), parseTime(updated)
	return r, nil
}

func (s *Store) queryRecurring(ctx context.Context, q string, args ...any) ([]Recurring, error) {
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Recurring
	for rows.Next() {
		r, err := scanRecurring(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// templateOf macht aus einer gespeicherten Ausgabe eine Vorlage.
func templateOf(e Expense) ExpenseInput {
	t := e.ExpenseInput
	t.Date = time.Time{}
	t.RecurringID = 0
	return t
}

// CreateRecurringFromExpense legt eine Wiederholung mit der Ausgabe expenseID
// als Vorlage und erster Instanz an: Anker ist das Datum der Ausgabe, die
// Ausgabe bekommt die recurring_id, und der nächste Termin ist der erste nach
// dem Anker. Ausgaben, die schon zu einer Wiederholung gehören, ergeben einen
// ValidationError.
func (s *Store) CreateRecurringFromExpense(ctx context.Context, actorID, expenseID int64, freq domain.Frequency) (int64, error) {
	if !freq.Valid() {
		return 0, invalid("Bitte eine Häufigkeit wählen.")
	}
	var id int64
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		e, err := getExpense(ctx, tx, expenseID)
		if err != nil {
			return err
		}
		if e.Deleted() {
			return ErrNotFound
		}
		if e.RecurringID != 0 {
			return invalid("Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe.")
		}
		tmpl, err := json.Marshal(templateOf(e))
		if err != nil {
			return err
		}
		now := s.nowString()
		next := domain.NextDate(freq, e.Date, e.Date)
		res, err := tx.ExecContext(ctx, `INSERT INTO recurring
			(template_json, frequency, start_date, next_date, active, created_by, created_at, updated_at)
			VALUES (?, ?, ?, ?, 1, ?, ?, ?)`,
			string(tmpl), string(freq), formatDate(e.Date), formatDate(next), nullInt(actorID), now, now)
		if err != nil {
			return err
		}
		if id, err = res.LastInsertId(); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "UPDATE expenses SET recurring_id = ? WHERE id = ?", id, expenseID); err != nil {
			return err
		}
		return s.insertActivity(ctx, tx, actorID, ActionRecurringCreated, expenseID, ActivityDetails{
			Title: e.Title, AmountCents: e.AmountCents,
			Text: fmt.Sprintf("„%s“ wiederholt sich jetzt %s.", e.Title, frequencyAdverb(freq)),
		})
	})
	if err != nil {
		return 0, err
	}
	return id, nil
}

func frequencyAdverb(f domain.Frequency) string {
	switch f {
	case domain.FreqWeekly:
		return "wöchentlich"
	case domain.FreqMonthly:
		return "monatlich"
	case domain.FreqYearly:
		return "jährlich"
	}
	return string(f)
}

// GetRecurring liefert eine Wiederholung oder ErrNotFound.
func (s *Store) GetRecurring(ctx context.Context, id int64) (Recurring, error) {
	r, err := scanRecurring(s.db.QueryRowContext(ctx, "SELECT "+recurringCols+" FROM recurring WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return r, ErrNotFound
	}
	return r, err
}

// ListRecurring liefert alle Wiederholungen: aktive zuerst, dann nach
// nächstem Termin.
func (s *Store) ListRecurring(ctx context.Context) ([]Recurring, error) {
	return s.queryRecurring(ctx, "SELECT "+recurringCols+" FROM recurring ORDER BY active DESC, next_date, id")
}

// DueRecurring liefert die aktiven Wiederholungen mit next_date ≤ today.
func (s *Store) DueRecurring(ctx context.Context, today time.Time) ([]Recurring, error) {
	return s.queryRecurring(ctx, "SELECT "+recurringCols+" FROM recurring WHERE active = 1 AND next_date <= ? ORDER BY next_date, id",
		formatDate(today))
}

// SetRecurringNextDate schreibt den nächsten fälligen Termin fort.
func (s *Store) SetRecurringNextDate(ctx context.Context, id int64, next time.Time) error {
	res, err := s.db.ExecContext(ctx, "UPDATE recurring SET next_date = ?, updated_at = ? WHERE id = ?",
		formatDate(next), s.nowString(), id)
	return checkAffected(res, err)
}

// SetRecurringActive pausiert eine Wiederholung bzw. setzt sie fort. Beim
// Fortsetzen werden Termine aus der Pause nicht nachgeholt: next_date wird auf
// den ersten Termin ab today gesetzt (falls er nicht ohnehin später liegt).
func (s *Store) SetRecurringActive(ctx context.Context, id int64, active bool, today time.Time) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		r, err := scanRecurring(tx.QueryRowContext(ctx, "SELECT "+recurringCols+" FROM recurring WHERE id = ?", id))
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		next := r.NextDate
		if active && !r.Active && next.Before(today) {
			next = domain.NextDate(r.Frequency, r.StartDate, today.AddDate(0, 0, -1))
		}
		_, err = tx.ExecContext(ctx, "UPDATE recurring SET active = ?, next_date = ?, updated_at = ? WHERE id = ?",
			active, formatDate(next), s.nowString(), id)
		return err
	})
}

// UpdateRecurringTemplateFromLatest übernimmt die jüngste (nicht gelöschte)
// Instanz der Wiederholung als neue Vorlage – z. B. nachdem dort der Betrag
// geändert wurde. Ohne Instanz: ErrNotFound.
func (s *Store) UpdateRecurringTemplateFromLatest(ctx context.Context, id int64) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		es, err := queryExpenses(ctx, tx, expenseSelect+
			" WHERE e.recurring_id = ? AND e.deleted_at IS NULL ORDER BY e.date DESC, e.id DESC LIMIT 1", id)
		if err != nil {
			return err
		}
		if len(es) == 0 {
			return ErrNotFound
		}
		tmpl, err := json.Marshal(templateOf(es[0]))
		if err != nil {
			return err
		}
		res, err := tx.ExecContext(ctx, "UPDATE recurring SET template_json = ?, updated_at = ? WHERE id = ?",
			string(tmpl), s.nowString(), id)
		return checkAffected(res, err)
	})
}

// DeleteRecurring löscht eine Wiederholung. Bereits angelegte Ausgaben
// bleiben erhalten (ihre recurring_id wird per ON DELETE SET NULL geleert).
func (s *Store) DeleteRecurring(ctx context.Context, actorID, id int64) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		r, err := scanRecurring(tx.QueryRowContext(ctx, "SELECT "+recurringCols+" FROM recurring WHERE id = ?", id))
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM recurring WHERE id = ?", id); err != nil {
			return err
		}
		return s.insertActivity(ctx, tx, actorID, ActionRecurringDeleted, 0, ActivityDetails{
			Title: r.Template.Title, AmountCents: r.Template.AmountCents,
			Text: fmt.Sprintf("Wiederholung von „%s“ beendet.", r.Template.Title),
		})
	})
}
