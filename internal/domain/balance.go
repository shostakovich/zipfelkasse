package domain

// Entry ist eine Ausgabe in der für Salden nötigen Form. Rückzahlungen sind
// normale Entries: Zahler = wer zurückzahlt, einziger Anteil = Empfänger.
type Entry struct {
	PaidBy      int64
	AmountCents int64
	Shares      []Share
}

// Balances berechnet den Saldo pro Person in Cent: positiv = bekommt Geld,
// negativ = schuldet Geld. Die Summe aller Salden ist 0.
func Balances(entries []Entry) map[int64]int64 {
	b := map[int64]int64{}
	for _, e := range entries {
		b[e.PaidBy] += e.AmountCents
		for _, s := range e.Shares {
			b[s.ParticipantID] -= s.AmountCents
		}
	}
	return b
}

// Transfer ist eine vorgeschlagene Zahlung: From zahlt AmountCents an To.
type Transfer struct {
	From        int64
	To          int64
	AmountCents int64
}

// Settle liefert einen Ausgleichsvorschlag (greedy): Es zahlt jeweils der
// größte Schuldner an den größten Gläubiger, bis alles ausgeglichen ist.
// Gleichstände werden nach kleinerer ID entschieden, das Ergebnis ist also
// deterministisch. Die Eingabe wird nicht verändert.
func Settle(balances map[int64]int64) []Transfer {
	b := make(map[int64]int64, len(balances))
	for id, v := range balances {
		if v != 0 {
			b[id] = v
		}
	}
	var out []Transfer
	for {
		var creditor, debtor int64
		for id, v := range b {
			if v > 0 && (creditor == 0 || v > b[creditor] || (v == b[creditor] && id < creditor)) {
				creditor = id
			}
			if v < 0 && (debtor == 0 || v < b[debtor] || (v == b[debtor] && id < debtor)) {
				debtor = id
			}
		}
		if creditor == 0 || debtor == 0 {
			return out
		}
		amount := min(b[creditor], -b[debtor])
		out = append(out, Transfer{From: debtor, To: creditor, AmountCents: amount})
		b[creditor] -= amount
		b[debtor] += amount
		if b[creditor] == 0 {
			delete(b, creditor)
		}
		if b[debtor] == 0 {
			delete(b, debtor)
		}
	}
}
