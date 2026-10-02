package ynab

import (
	"cmp"
	"regexp"
	"slices"
	"strconv"
	"time"

	"teilen/internal/domain"
	"teilen/internal/store"
)

// Posting ist eine Buchung „aus meiner Sicht“: mein Anteil an einer Ausgabe
// als Ausgang im Verrechnungskonto „Geteilt“. Dieselben Buchungen schreibt
// der Sync nach YNAB und liefert der Export als OFX/CSV.
type Posting struct {
	ExpenseID   int64
	Date        time.Time
	AmountCents int64  // mein Anteil in Cent, positiv (= Ausgang)
	Payee       string // Titel der Ausgabe
	Memo        string // „Gesamt 84,00 € · bezahlt von Anna · teilen #123“
	CategoryID  int64  // App-Kategorie, 0 = keine
}

// PostingFor liefert die Buchung von participantID zu e. ok ist false, wenn
// es keine gibt: gelöschte Ausgaben, Rückzahlungen (die laufen in YNAB als
// Transfer über die Bank) und Ausgaben ohne eigenen Anteil.
func PostingFor(e store.Expense, participantID int64) (p Posting, ok bool) {
	if e.Deleted() || e.IsReimbursement {
		return Posting{}, false
	}
	share := e.ShareOf(participantID)
	if share <= 0 {
		return Posting{}, false
	}
	return Posting{
		ExpenseID:   e.ID,
		Date:        e.Date,
		AmountCents: share,
		Payee:       truncate(e.Title, maxPayeeLen),
		Memo:        Memo(e),
		CategoryID:  e.CategoryID,
	}, true
}

// Postings liefert die Buchungen von participantID zu es, nach Datum und ID
// aufsteigend sortiert.
func Postings(es []store.Expense, participantID int64) []Posting {
	var out []Posting
	for _, e := range es {
		if p, ok := PostingFor(e, participantID); ok {
			out = append(out, p)
		}
	}
	slices.SortFunc(out, func(a, b Posting) int {
		return cmp.Or(a.Date.Compare(b.Date), cmp.Compare(a.ExpenseID, b.ExpenseID))
	})
	return out
}

// Memo beschreibt die Ausgabe für das Memo-Feld. Die Markierung „teilen #ID“
// steht immer am Ende; der Sync erkennt eigene Buchungen daran wieder.
func Memo(e store.Expense) string {
	total := "Gesamt " + domain.FormatCents(e.AmountCents)
	if e.IsForeign() {
		total += " (" + domain.FormatMoney(e.OriginalAmountMinor, e.OriginalCurrency) + ")"
	}
	suffix := " · " + Marker(e.ID)
	head := total + " · bezahlt von " + e.PaidByName
	return truncate(head, maxMemoLen-len([]rune(suffix))) + suffix
}

// Marker ist die Kennung einer Ausgabe im Memo.
func Marker(expenseID int64) string { return "teilen #" + strconv.FormatInt(expenseID, 10) }

var markerRe = regexp.MustCompile(`teilen #(\d+)\s*$`)

// markerID liest die Ausgaben-ID aus einem Memo (siehe Marker).
func markerID(memo string) (int64, bool) {
	m := markerRe.FindStringSubmatch(memo)
	if m == nil {
		return 0, false
	}
	id, err := strconv.ParseInt(m[1], 10, 64)
	return id, err == nil
}

// truncate kürzt s auf höchstens n Zeichen (Runen), mit „…“ am Ende.
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	if n <= 1 {
		return string(r[:max(n, 0)])
	}
	return string(r[:n-1]) + "…"
}
