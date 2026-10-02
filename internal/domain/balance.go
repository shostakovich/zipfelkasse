package domain

// Entry is an expense in the form needed for balances. Reimbursements are
// ordinary entries: payer = whoever pays back, single share = recipient.
type Entry struct {
	PaidBy      int64
	AmountCents int64
	Shares      []Share
}

// Balances computes each person's balance in cents: positive = is owed money,
// negative = owes money. All balances sum to 0.
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

// Transfer is a suggested payment: From pays AmountCents to To.
type Transfer struct {
	From        int64
	To          int64
	AmountCents int64
}

// Settle returns a settlement suggestion (greedy): the largest debtor pays
// the largest creditor until everything is settled. Ties are broken by the
// smaller ID, so the result is deterministic. The input is not modified.
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
