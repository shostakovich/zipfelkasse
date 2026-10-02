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

// Posting is a transaction "from my point of view": my share of an expense
// as an outflow in the clearing account "Geteilt". The sync writes the same
// transactions to YNAB that the export delivers as OFX/CSV.
type Posting struct {
	ExpenseID   int64
	Date        time.Time
	AmountCents int64  // my share in cents, positive (= outflow)
	Payee       string // title of the expense
	Memo        string // "Gesamt 84,00 € · bezahlt von Anna · zipfelkasse #123"
	CategoryID  int64  // app category, 0 = none
}

// PostingFor returns the posting of participantID for e. ok is false if
// there is none: deleted expenses, reimbursements (those go through the bank
// as transfers in YNAB) and expenses without an own share.
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

// Selection is the rule which of a person's expenses belong in YNAB. Sync
// and export (ynab.ofx/ynab.csv) use the same rule so that both yield the
// same balance of "Geteilt". An expense belongs if there is a posting
// (PostingFor), its date is not after Today (YNAB rejects future ones) and
//   - its date is ≥ Start, or
//   - it was entered after the setup (created_at ≥ ConnectedAt): the starting
//     balance of "Geteilt" does not know it, even if it is backdated, or
//   - it is already in YNAB (InYNAB): if its date later moves before the
//     start, it stays anyway; it is only removed on deletion or share 0.
//
// Without Start (YNAB not set up), all past expenses count.
type Selection struct {
	Start       time.Time
	ConnectedAt time.Time
	Today       time.Time
	InYNAB      map[int64]bool // expense ID → transaction exists in YNAB (or creation unclear)
}

// NewSelection reads the rule for the connection cfg. If ConnectedAt is
// missing (connections from before it was introduced), now applies.
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

// SelectionFor is NewSelection for participantID (without a connection: all
// past expenses).
func SelectionFor(ctx context.Context, st *store.Store, participantID int64, today time.Time) (Selection, error) {
	cfg, err := st.GetYNABConfig(ctx, participantID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return Selection{}, err
	}
	cfg.ParticipantID = participantID
	return NewSelection(ctx, st, cfg, today)
}

// Includes reports whether the expense e with posting p belongs.
func (sel Selection) Includes(e store.Expense, p Posting) bool {
	if p.Date.After(sel.Today) {
		return false
	}
	return sel.Start.IsZero() || !p.Date.Before(sel.Start) ||
		(!sel.ConnectedAt.IsZero() && !e.CreatedAt.Before(sel.ConnectedAt)) || sel.InYNAB[e.ID]
}

// Postings returns the selected postings of participantID for es, sorted by
// date and ID ascending.
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

// Memo describes the expense for the memo field. The text is German (it
// lands in the user's YNAB budget). The marker "zipfelkasse #ID" is always
// at the end; the sync recognizes its own transactions by it.
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

// Marker is the identifier of an expense in the memo.
func Marker(expenseID int64) string { return markerPrefix + strconv.FormatInt(expenseID, 10) }

var markerRe = regexp.MustCompile(regexp.QuoteMeta(markerPrefix) + `(\d+)\s*$`)

// markerID reads the expense ID from a memo (see Marker).
func markerID(memo string) (int64, bool) {
	m := markerRe.FindStringSubmatch(memo)
	if m == nil {
		return 0, false
	}
	id, err := strconv.ParseInt(m[1], 10, 64)
	return id, err == nil
}

// truncate shortens s to at most n characters (runes), with "…" at the end.
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
