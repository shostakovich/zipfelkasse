package ynab

import (
	"cmp"
	"context"
	"errors"
	"regexp"
	"slices"
	"strconv"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
)

// Posting ist eine Buchung „aus meiner Sicht“: mein Anteil an einer Ausgabe
// als Ausgang im Verrechnungskonto „Geteilt“. Dieselben Buchungen schreibt
// der Sync nach YNAB und liefert der Export als OFX/CSV.
type Posting struct {
	ExpenseID   int64
	Date        time.Time
	AmountCents int64  // mein Anteil in Cent, positiv (= Ausgang)
	Payee       string // Titel der Ausgabe
	Memo        string // „Gesamt 84,00 € · bezahlt von Anna · zipfelkasse #123“
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

func sortPostings(ps []Posting) {
	slices.SortFunc(ps, func(a, b Posting) int {
		return cmp.Or(a.Date.Compare(b.Date), cmp.Compare(a.ExpenseID, b.ExpenseID))
	})
}

// Selection ist die Regel, welche Ausgaben einer Person nach YNAB gehören.
// Sync und Export (ynab.ofx/ynab.csv) verwenden dieselbe Regel, damit beide
// denselben Saldo „Geteilt“ ergeben. Eine Ausgabe gehört dazu, wenn es eine
// Buchung gibt (PostingFor), ihr Datum nicht nach Today liegt (künftige
// lehnt YNAB ab) und
//   - ihr Datum ≥ Start ist oder
//   - sie nach dem Einrichten erfasst wurde (created_at ≥ ConnectedAt): Der
//     Startsaldo von „Geteilt“ kennt sie nicht, auch wenn sie rückdatiert ist, oder
//   - sie schon in YNAB steht (InYNAB): Rückt ihr Datum später vor den Start,
//     bleibt sie trotzdem; entfernt wird sie nur bei Löschung oder Anteil 0.
//
// Ohne Start (YNAB nicht eingerichtet) zählen alle vergangenen Ausgaben.
type Selection struct {
	Start       time.Time
	ConnectedAt time.Time
	Today       time.Time
	InYNAB      map[int64]bool // Ausgaben-ID → Buchung in YNAB vorhanden (oder Anlage unklar)
}

// NewSelection liest die Regel für die Verbindung cfg. Fehlt ConnectedAt
// (Verbindungen von vor seiner Einführung), gilt ab jetzt.
func NewSelection(ctx context.Context, st *store.Store, cfg store.YNABConfig, today time.Time) (Selection, error) {
	sel := Selection{Today: today}
	if cfg.StartDate.IsZero() || cfg.AccountID == "" {
		return sel, nil
	}
	sel.Start, sel.ConnectedAt = cfg.StartDate, cfg.ConnectedAt
	if sel.ConnectedAt.IsZero() {
		at, err := st.EnsureYNABConnectedAt(ctx, cfg.ParticipantID)
		if err != nil {
			return sel, err
		}
		sel.ConnectedAt = at
	}
	rows, err := st.ListYNABSync(ctx, cfg.ParticipantID)
	if err != nil {
		return sel, err
	}
	sel.InYNAB = make(map[int64]bool, len(rows))
	for _, r := range rows {
		if r.TxnID != "" || r.Hash == pendingHash {
			sel.InYNAB[r.ExpenseID] = true
		}
	}
	return sel, nil
}

// SelectionFor ist NewSelection für participantID (ohne Verbindung: alle
// vergangenen Ausgaben).
func SelectionFor(ctx context.Context, st *store.Store, participantID int64, today time.Time) (Selection, error) {
	cfg, err := st.GetYNABConfig(ctx, participantID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return Selection{}, err
	}
	cfg.ParticipantID = participantID
	return NewSelection(ctx, st, cfg, today)
}

// Includes meldet, ob die Ausgabe e mit Buchung p dazugehört.
func (sel Selection) Includes(e store.Expense, p Posting) bool {
	if p.Date.After(sel.Today) {
		return false
	}
	return sel.Start.IsZero() || !p.Date.Before(sel.Start) ||
		(!sel.ConnectedAt.IsZero() && !e.CreatedAt.Before(sel.ConnectedAt)) || sel.InYNAB[e.ID]
}

// Postings liefert die ausgewählten Buchungen von participantID zu es, nach
// Datum und ID aufsteigend sortiert.
func (sel Selection) Postings(es []store.Expense, participantID int64) []Posting {
	var out []Posting
	for _, e := range es {
		if p, ok := PostingFor(e, participantID); ok && sel.Includes(e, p) {
			out = append(out, p)
		}
	}
	sortPostings(out)
	return out
}

// Memo beschreibt die Ausgabe für das Memo-Feld. Die Markierung „zipfelkasse #ID“
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

// markerPrefix starts the marker of an expense in the memo (see Marker).
const markerPrefix = "zipfelkasse #"

// Marker ist die Kennung einer Ausgabe im Memo.
func Marker(expenseID int64) string { return markerPrefix + strconv.FormatInt(expenseID, 10) }

var markerRe = regexp.MustCompile(regexp.QuoteMeta(markerPrefix) + `(\d+)\s*$`)

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
