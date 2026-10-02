package store

import (
	"cmp"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// convertAmountWeights (migration 4): for "by amounts" in a foreign currency,
// expense_shares.weight used to hold euro cents (the amounts entered in the
// foreign currency, converted); now it holds the amounts in that currency
// (see domain.SplitConverted). The old weights are converted back as well as
// possible (largest remainder on original_amount_minor, ties to the smaller
// participant ID, as the edit form did). The euro shares (amount_cents) stay
// unchanged, so balances and the YNAB fingerprints do too. Deleted expenses
// and the templates of recurring expenses are converted as well. A system
// entry in the activity log states what was converted, if anything.
func (s *Store) convertAmountWeights(ctx context.Context, tx *sql.Tx) error {
	type expense struct {
		id       int64
		original int64
		parts    []domain.Part
	}
	rows, err := tx.QueryContext(ctx, `SELECT e.id, e.original_amount_minor, x.participant_id, x.weight
		FROM expenses e JOIN expense_shares x ON x.expense_id = e.id
		WHERE e.split_mode = ? AND e.is_reimbursement = 0 AND e.original_currency <> 'EUR'
		ORDER BY e.id, x.participant_id`, string(domain.SplitAmount))
	if err != nil {
		return err
	}
	var es []expense
	for rows.Next() {
		var e expense
		var p domain.Part
		if err := rows.Scan(&e.id, &e.original, &p.ParticipantID, &p.Weight); err != nil {
			rows.Close()
			return err
		}
		if len(es) == 0 || es[len(es)-1].id != e.id {
			es = append(es, e)
		}
		last := &es[len(es)-1]
		last.parts = append(last.parts, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	expenses := 0
	for _, e := range es {
		parts, changed := toOriginalWeights(e.parts, e.original)
		if !changed {
			continue
		}
		expenses++
		for _, p := range parts {
			if _, err := tx.ExecContext(ctx, "UPDATE expense_shares SET weight = ? WHERE expense_id = ? AND participant_id = ?",
				p.Weight, e.id, p.ParticipantID); err != nil {
				return err
			}
		}
	}

	templates := 0
	trows, err := tx.QueryContext(ctx, "SELECT id, template_json FROM recurring ORDER BY id")
	if err != nil {
		return err
	}
	updates := map[int64]string{}
	for trows.Next() {
		var id int64
		var raw string
		if err := trows.Scan(&id, &raw); err != nil {
			trows.Close()
			return err
		}
		var t ExpenseInput
		if err := json.Unmarshal([]byte(raw), &t); err != nil {
			trows.Close()
			return fmt.Errorf("recurring %d: template: %w", id, err)
		}
		cur := strings.ToUpper(t.OriginalCurrency)
		if t.SplitMode != domain.SplitAmount || t.IsReimbursement || cur == "" || cur == "EUR" {
			continue
		}
		parts, changed := toOriginalWeights(t.Parts, t.OriginalAmountMinor)
		if !changed {
			continue
		}
		t.Parts = parts
		b, err := json.Marshal(t)
		if err != nil {
			trows.Close()
			return err
		}
		updates[id] = string(b)
	}
	trows.Close()
	if err := trows.Err(); err != nil {
		return err
	}
	for id, tmpl := range updates {
		if _, err := tx.ExecContext(ctx, "UPDATE recurring SET template_json = ? WHERE id = ?", tmpl, id); err != nil {
			return err
		}
		templates++
	}

	if expenses == 0 && templates == 0 {
		return nil
	}
	var what []string
	if expenses > 0 {
		what = append(what, countNoun(expenses, "Ausgabe", "Ausgaben"))
	}
	if templates > 0 {
		what = append(what, countNoun(templates, "wiederkehrende Ausgabe", "wiederkehrende Ausgaben"))
	}
	return s.insertActivity(ctx, tx, 0, ActionWeightsConverted, 0, ActivityDetails{Text: fmt.Sprintf(
		"Aufteilung nach Beträgen in Fremdwährung umgestellt (%s): Die Beträge pro Person stehen jetzt in der Originalwährung statt in Euro. Die Euro-Anteile bleiben unverändert.",
		strings.Join(what, " und "))})
}

// toOriginalWeights distributes original in proportion to the old weights
// (euro cents), sorted by participant ID. changed reports whether a weight
// differs; weights summing to 0 are left alone.
func toOriginalWeights(parts []domain.Part, original int64) ([]domain.Part, bool) {
	ps := slices.Clone(parts)
	slices.SortFunc(ps, func(a, b domain.Part) int { return cmp.Compare(a.ParticipantID, b.ParticipantID) })
	weights := make([]int64, len(ps))
	var sum int64
	for i, p := range ps {
		if p.Weight < 0 {
			return parts, false
		}
		weights[i] = p.Weight
		sum += p.Weight
	}
	if sum <= 0 || original <= 0 {
		return parts, false
	}
	changed := false
	for i, w := range domain.Allocate(original, weights, 0) {
		if w != ps[i].Weight {
			ps[i].Weight, changed = w, true
		}
	}
	return ps, changed
}

func countNoun(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return fmt.Sprintf("%d %s", n, many)
}
