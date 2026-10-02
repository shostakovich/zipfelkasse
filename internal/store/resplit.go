package store

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// resplitShares (migration 2) recomputes expense_shares.amount_cents of all
// expenses (including deleted ones) using the current domain.Split rule: on
// tied remainders the extra cent rotates with the expense ID instead of always
// going to the smallest participant ID. Weights stay as they are. Expenses
// whose stored weights domain.Split rejects (e.g. old imports) are left
// unchanged. A system entry in the activity log states the number of changed
// expenses; the YNAB sync notices the new shares via its fingerprint and
// transfers them on the next run.
func (s *Store) resplitShares(ctx context.Context, tx *sql.Tx) error {
	type expense struct {
		id     int64
		mode   domain.SplitMode
		amount int64
		shares []domain.Share
	}
	rows, err := tx.QueryContext(ctx, `SELECT e.id, e.split_mode, e.amount_cents, x.participant_id, x.weight, x.amount_cents
		FROM expenses e JOIN expense_shares x ON x.expense_id = e.id ORDER BY e.id, x.participant_id`)
	if err != nil {
		return err
	}
	var es []expense
	for rows.Next() {
		var e expense
		var sh domain.Share
		if err := rows.Scan(&e.id, &e.mode, &e.amount, &sh.ParticipantID, &sh.Weight, &sh.AmountCents); err != nil {
			rows.Close()
			return err
		}
		if len(es) == 0 || es[len(es)-1].id != e.id {
			es = append(es, e)
		}
		last := &es[len(es)-1]
		last.shares = append(last.shares, sh)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	changed := 0
	for _, e := range es {
		parts := make([]domain.Part, len(e.shares))
		for i, sh := range e.shares {
			parts[i] = domain.Part{ParticipantID: sh.ParticipantID, Weight: sh.Weight}
		}
		fresh, err := domain.Split(e.mode, e.amount, parts, e.id)
		if err != nil {
			continue
		}
		diff := false
		for i, sh := range fresh { // both sorted by ParticipantID
			if sh.AmountCents == e.shares[i].AmountCents {
				continue
			}
			diff = true
			if _, err := tx.ExecContext(ctx, "UPDATE expense_shares SET amount_cents = ? WHERE expense_id = ? AND participant_id = ?",
				sh.AmountCents, e.id, sh.ParticipantID); err != nil {
				return err
			}
		}
		if diff {
			changed++
		}
	}
	if changed == 0 {
		return nil
	}
	return s.insertActivity(ctx, tx, 0, ActionSharesRecalculated, 0, ActivityDetails{Text: fmt.Sprintf(
		"Rest-Cents von %d Ausgaben neu verteilt: Bei Gleichstand bekommt den Extra-Cent jetzt reihum eine andere Person statt immer dieselbe.", changed)})
}
