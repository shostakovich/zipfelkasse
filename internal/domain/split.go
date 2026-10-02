package domain

import (
	"cmp"
	"slices"
)

// SplitMode bestimmt, wie eine Ausgabe auf die Beteiligten verteilt wird und
// was Part.Weight bedeutet.
type SplitMode string

const (
	SplitEqual   SplitMode = "equal"   // gleichmäßig; Weight wird ignoriert und als 1 gespeichert
	SplitShares  SplitMode = "shares"  // nach Anteilen; Weight = ganzzahlige Anteile (>= 0)
	SplitPercent SplitMode = "percent" // nach Prozent; Weight = Basispunkte, Summe 10000
	SplitAmount  SplitMode = "amount"  // nach Beträgen; Weight = Cent, Summe = Gesamtbetrag
)

// SplitModes in der Reihenfolge, in der sie im Formular angeboten werden.
var SplitModes = []SplitMode{SplitEqual, SplitShares, SplitPercent, SplitAmount}

// maxShareWeight begrenzt Anteile, damit total*weight nicht überläuft.
const maxShareWeight = 1_000_000

func (m SplitMode) Valid() bool {
	switch m {
	case SplitEqual, SplitShares, SplitPercent, SplitAmount:
		return true
	}
	return false
}

// Label liefert die deutsche Bezeichnung.
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

// Part ist eine Eingabe für Split: wer ist beteiligt, mit welchem Gewicht.
type Part struct {
	ParticipantID int64 `json:"participant_id"`
	Weight        int64 `json:"weight"`
}

// Share ist der berechnete Anteil einer Person an einer Ausgabe.
type Share struct {
	ParticipantID int64 `json:"participant_id"`
	Weight        int64 `json:"weight"`
	AmountCents   int64 `json:"amount_cents"`
}

// Split verteilt total (Cent, > 0) gemäß mode auf parts. Das Ergebnis ist
// nach ParticipantID sortiert und summiert sich exakt zu total. Rundungsreste
// werden nach der Methode des größten Rests verteilt; bei Gleichstand bekommt
// die kleinere ParticipantID den Cent.
func Split(mode SplitMode, total int64, parts []Part) ([]Share, error) {
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
	// Größter Rest zuerst; bei Gleichstand kleinere ID (ps ist nach ID sortiert).
	slices.SortStableFunc(order, func(a, b int) int { return cmp.Compare(rems[b], rems[a]) })
	for k := 0; allocated < total; k++ {
		out[order[k%len(order)]].AmountCents++
		allocated++
	}
	return out, nil
}
