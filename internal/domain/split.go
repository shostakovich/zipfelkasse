package domain

import (
	"cmp"
	"math/bits"
	"slices"
)

// SplitMode determines how an expense is divided among the participants and
// what Part.Weight means.
type SplitMode string

const (
	SplitEqual   SplitMode = "equal"   // evenly; Weight is ignored and stored as 1
	SplitShares  SplitMode = "shares"  // by shares; Weight = integer shares (>= 0)
	SplitPercent SplitMode = "percent" // by percentage; Weight = basis points, sum 10000
	// by amounts; Weight = amount in the smallest unit of the currency the
	// expense was entered in (cents for EUR), sum = amount in that currency
	SplitAmount SplitMode = "amount"
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

// Split divides total (euro cents, > 0) of an expense entered in euros among
// parts according to mode; see SplitConverted.
func Split(mode SplitMode, total int64, parts []Part, rotation int64) ([]Share, error) {
	return SplitConverted(mode, total, total, "EUR", parts, rotation)
}

// SplitConverted divides total (euro cents, > 0) among parts according to
// mode, for an expense entered as original (smallest unit of currency) and
// converted to total; for euros original = total. Only SplitAmount depends on
// it: the weights are amounts in currency and must add up to original; total
// is distributed in proportion to them (for euros the shares are exactly the
// weights).
//
// The result is sorted by ParticipantID and sums to exactly total; the cents
// are distributed by Allocate with rotation (the expense ID).
func SplitConverted(mode SplitMode, total, original int64, currency string, parts []Part, rotation int64) ([]Share, error) {
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
			s, carry := bits.Add64(uint64(sum), uint64(p.Weight), 0)
			if carry != 0 || s > 1<<63-1 {
				return nil, invalid("Der Betrag ist zu groß.")
			}
			sum = int64(s)
		}
		if sum != original {
			return nil, invalid("Die Beträge müssen zusammen %s ergeben (aktuell %s).", FormatMoney(original, currency), FormatMoney(sum, currency))
		}
	}

	weights := make([]int64, len(ps))
	for i, p := range ps {
		weights[i] = p.Weight
	}
	out := make([]Share, len(ps))
	for i, c := range Allocate(total, weights, rotation) {
		out[i] = Share{ParticipantID: ps[i].ParticipantID, Weight: ps[i].Weight, AmountCents: c}
	}
	return out, nil
}

// Allocate distributes total (>= 0) in proportion to weights (>= 0, sum at
// most MaxInt64) using the largest-remainder method; the result sums to exactly total (all zero if the
// weights sum to 0). On tied remainders, precedence rotates with rotation
// (the expense ID): the tied entries form a circle in index order, the first
// cent goes to the one at index rotation mod count, the next to the
// following one, and so on. That way, across many unevenly split expenses,
// the extra cent does not always land on the same person. Callers pass the
// weights sorted by participant ID. Computes with 128-bit products, so that
// total · weight cannot overflow. The JS preview (static/expense-form.js)
// computes the same way.
func Allocate(total int64, weights []int64, rotation int64) []int64 {
	var sum uint64
	for _, w := range weights {
		sum += uint64(w)
	}
	out := make([]int64, len(weights))
	if sum == 0 {
		return out
	}
	rems := make([]uint64, len(weights))
	var allocated int64
	for i, w := range weights {
		hi, lo := bits.Mul64(uint64(total), uint64(w))
		q, r := bits.Div64(hi, lo, sum) // w ≤ sum → hi < sum, no overflow
		out[i], rems[i] = int64(q), r
		allocated += out[i]
	}
	order := make([]int, len(weights))
	for i := range order {
		order[i] = i
	}
	// Largest remainder first; ties stay in index order and are then rotated
	// by rotation.
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
	// The remainder is smaller than the number of entries with a remainder:
	// at most one cent each.
	for k := 0; allocated < total; k++ {
		out[order[k]]++
		allocated++
	}
	return out
}

// rotate rotates s left by k positions (s[k] ends up first).
func rotate(s []int, k int) {
	slices.Reverse(s[:k])
	slices.Reverse(s[k:])
	slices.Reverse(s)
}
