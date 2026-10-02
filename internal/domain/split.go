package domain

import (
	"cmp"
	"slices"
)

// SplitMode determines how an expense is divided among the participants and
// what Part.Weight means.
type SplitMode string

const (
	SplitEqual   SplitMode = "equal"   // evenly; Weight is ignored and stored as 1
	SplitShares  SplitMode = "shares"  // by shares; Weight = integer shares (>= 0)
	SplitPercent SplitMode = "percent" // by percentage; Weight = basis points, sum 10000
	SplitAmount  SplitMode = "amount"  // by amounts; Weight = cents, sum = total amount
)

// SplitModes in the order in which they are offered in the form.
var SplitModes = []SplitMode{SplitEqual, SplitShares, SplitPercent, SplitAmount}

// maxShareWeight caps shares so that total*weight cannot overflow.
const maxShareWeight = 1_000_000

func (m SplitMode) Valid() bool {
	switch m {
	case SplitEqual, SplitShares, SplitPercent, SplitAmount:
		return true
	}
	return false
}

// Label returns the German display name.
func (m SplitMode) Label() string {
	switch m {
	case SplitEqual:
		return "Gleichmäßig"
	case SplitShares:
		return "Nach Anteilen"
	case SplitPercent:
		return "Nach Prozent"
	case SplitAmount:
		return "Nach Beträgen"
	}
	return string(m)
}

// Part is an input to Split: who takes part, with which weight.
type Part struct {
	ParticipantID int64 `json:"participant_id"`
	Weight        int64 `json:"weight"`
}

// Share is a person's computed share of an expense.
type Share struct {
	ParticipantID int64 `json:"participant_id"`
	Weight        int64 `json:"weight"`
	AmountCents   int64 `json:"amount_cents"`
}

// Split divides total (cents, > 0) among parts according to mode. The result
// is sorted by ParticipantID and sums to exactly total. Rounding remainders
// are distributed using the largest-remainder method. On ties, precedence
// rotates with rotation (the expense ID): the tied people form a circle
// sorted by ID, the first cent goes to the one at index rotation mod count,
// the next to the following one, and so on. That way, across many unevenly
// split expenses, the extra cent does not always land on the same person.
// The JS preview (static/expense-form.js) computes the same way.
func Split(mode SplitMode, total int64, parts []Part, rotation int64) ([]Share, error) {
	if !mode.Valid() {
		return nil, invalid("Unbekannte Aufteilungsart „%s“.", mode)
	}
	if total <= 0 {
		return nil, invalid("Der Betrag muss größer als 0 sein.")
	}
	if total > MaxAmountCents {
		return nil, invalid("Der Betrag ist zu groß.")
	}
	if len(parts) == 0 {
		return nil, invalid("Mindestens eine Person muss an der Ausgabe beteiligt sein.")
	}
	ps := slices.Clone(parts)
	slices.SortFunc(ps, func(a, b Part) int { return cmp.Compare(a.ParticipantID, b.ParticipantID) })
	for i, p := range ps {
		if p.ParticipantID <= 0 {
			return nil, invalid("Ungültige Person in der Aufteilung.")
		}
		if i > 0 && ps[i-1].ParticipantID == p.ParticipantID {
			return nil, invalid("Eine Person ist in der Aufteilung doppelt aufgeführt.")
		}
		if mode != SplitEqual && p.Weight < 0 {
			return nil, invalid("Anteile dürfen nicht negativ sein.")
		}
	}

	var sum int64
	switch mode {
	case SplitEqual:
		for i := range ps {
			ps[i].Weight = 1
		}
		sum = int64(len(ps))
	case SplitShares:
		for _, p := range ps {
			if p.Weight > maxShareWeight {
				return nil, invalid("Anteile dürfen höchstens %d sein.", maxShareWeight)
			}
			sum += p.Weight
		}
		if sum <= 0 {
			return nil, invalid("Die Summe der Anteile muss größer als 0 sein.")
		}
	case SplitPercent:
		for _, p := range ps {
			if p.Weight > 10000 {
				return nil, invalid("Die Prozente müssen zusammen 100 %% ergeben.")
			}
			sum += p.Weight
		}
		if sum != 10000 {
			return nil, invalid("Die Prozente müssen zusammen 100 %% ergeben (aktuell %s).", FormatBasisPoints(sum))
		}
	case SplitAmount:
		for _, p := range ps {
			if p.Weight > MaxAmountCents {
				return nil, invalid("Der Betrag ist zu groß.")
			}
			sum += p.Weight
		}
		if sum != total {
			return nil, invalid("Die Beträge müssen zusammen %s ergeben (aktuell %s).", FormatCents(total), FormatCents(sum))
		}
		out := make([]Share, len(ps))
		for i, p := range ps {
			out[i] = Share{ParticipantID: p.ParticipantID, Weight: p.Weight, AmountCents: p.Weight}
		}
		return out, nil
	}

	out := make([]Share, len(ps))
	rems := make([]int64, len(ps))
	var allocated int64
	for i, p := range ps {
		prod := total * p.Weight
		out[i] = Share{ParticipantID: p.ParticipantID, Weight: p.Weight, AmountCents: prod / sum}
		rems[i] = prod % sum
		allocated += out[i].AmountCents
	}
	order := make([]int, len(ps))
	for i := range order {
		order[i] = i
	}
	// Largest remainder first; ties stay sorted by ID (ps is) and are then
	// rotated by rotation.
	slices.SortStableFunc(order, func(a, b int) int { return cmp.Compare(rems[b], rems[a]) })
	for i := 0; i < len(order); {
		j := i + 1
		for j < len(order) && rems[order[j]] == rems[order[i]] {
			j++
		}
		n := int64(j - i)
		rotate(order[i:j], int((rotation%n+n)%n))
		i = j
	}
	// The remainder is smaller than the number of people: at most one cent per person.
	for k := 0; allocated < total; k++ {
		out[order[k]].AmountCents++
		allocated++
	}
	return out, nil
}

// rotate rotates s left by k positions (s[k] ends up first).
func rotate(s []int, k int) {
	slices.Reverse(s[:k])
	slices.Reverse(s[k:])
	slices.Reverse(s)
}
