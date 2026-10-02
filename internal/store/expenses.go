package store

import (
	"cmp"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// ErrRecurringExists: this recurrence already has an expense on this date
// (unique index on recurring_id, date). Only CreateExpense returns it
// (recurring.Materialize then skips the occurrence); UpdateExpense reports
// the same case as a domain.ValidationError.
var ErrRecurringExists = errors.New("expense for this occurrence already exists")

// ErrRecurringChanged: the recurrence was paused, deleted or advanced since
// it was read. CreateExpense returns it for an instance (RecurringID set) of
// a paused or deleted recurrence, SetRecurringNextDate if next_date is no
// longer the expected one; recurring.Materialize then stops catching up on
// this recurrence.
var ErrRecurringChanged = errors.New("recurring rule was paused, deleted or advanced meanwhile")

// ExpenseInput is the data of an expense as supplied by the user (or by a
// recurrence). The store computes the shares in cents itself via
// domain.SplitConverted from SplitMode, the amounts and Parts. For
// SplitAmount, Parts[].Weight are amounts in the smallest unit of
// OriginalCurrency (cents for EUR) that add up to OriginalAmountMinor.
type ExpenseInput struct {
	Title           string           `json:"title"`
	Date            time.Time        `json:"date"`        // calendar date, see domain.DateOf
	CategoryID      int64            `json:"category_id"` // 0 = no category
	PaidBy          int64            `json:"paid_by"`
	Notes           string           `json:"notes"`
	IsReimbursement bool             `json:"is_reimbursement"` // reimbursement: PaidBy pays Parts[0]
	SplitMode       domain.SplitMode `json:"split_mode"`
	AmountCents     int64            `json:"amount_cents"` // always EUR, > 0
	Parts           []domain.Part    `json:"parts"`

	// Foreign currency. OriginalCurrency "" or "EUR" = no foreign currency; the
	// store then sets OriginalAmountMinor = AmountCents, FXRate = 1, FXSource = "".
	// Otherwise OriginalAmountMinor > 0 and FXRate > 0 are required; the store
	// computes AmountCents itself via domain.ToEURCents (a given value is
	// ignored).
	OriginalAmountMinor int64   `json:"original_amount_minor"`
	OriginalCurrency    string  `json:"original_currency"`
	FXRate              float64 `json:"fx_rate"`
	FXSource            string  `json:"fx_source"`

	// RecurringID links an automatically created instance to its rule.
	// Only set on creation; UpdateExpense keeps the old value.
	RecurringID int64 `json:"recurring_id"`
}

// Expense is a stored expense. The embedded ExpenseInput is filled in
// (including Parts from the stored weights) so that it can be passed straight
// back to UpdateExpense.
type Expense struct {
	ID int64
	ExpenseInput
	Shares       []domain.Share // sorted by ParticipantID
	CategoryName string         // "" without category
	PaidByName   string
	CreatedAt    time.Time
	UpdatedAt    time.Time
	DeletedAt    time.Time // zero value = not deleted
}

func (e Expense) Deleted() bool { return !e.DeletedAt.IsZero() }

// IsForeign reports whether the expense was entered in a foreign currency.
func (e Expense) IsForeign() bool { return !domain.IsEUR(e.OriginalCurrency) }

// ShareOf returns participantID's share (cents), 0 if not involved.
func (e Expense) ShareOf(participantID int64) int64 {
	for _, s := range e.Shares {
		if s.ParticipantID == participantID {
			return s.AmountCents
		}
	}
	return 0
}

// ExpenseFilter narrows ListExpenses. Zero values mean "no filter".
type ExpenseFilter struct {
	Text       string // substring of title or notes, case-insensitive (including umlauts, ß = ss)
	CategoryID int64  //
	// WithoutCategory: only expenses without a category (CategoryID is ignored).
	WithoutCategory bool
	ParticipantID   int64     // paid or is involved
	From, To        time.Time // date, both inclusive
	Limit, Offset   int       // Limit 0 = all
}

// maxNotesLen is the maximum length of the notes in characters (as maxlength
// in the expense form).
const maxNotesLen = 2000

// normalize validates the input (including the split). The cent shares are
// computed afterwards by splitShares, once the expense ID is known.
func normalize(in ExpenseInput) (ExpenseInput, error) {
	in.Title = strings.Join(strings.Fields(in.Title), " ")
	in.Notes = strings.TrimSpace(in.Notes)
	switch {
	case in.Title == "":
		return in, invalid("Bitte einen Titel angeben.")
	case len([]rune(in.Title)) > 200:
		return in, invalid("Der Titel ist zu lang (höchstens 200 Zeichen).")
	// Browsers count a line break as one character for maxlength but send
	// it as CR LF.
	case len([]rune(strings.ReplaceAll(in.Notes, "\r\n", "\n"))) > maxNotesLen:
		return in, invalid("Die Notiz ist zu lang (höchstens %d Zeichen).", maxNotesLen)
	case in.Date.IsZero():
		return in, invalid("Bitte ein Datum angeben.")
	case in.PaidBy <= 0:
		return in, invalid("Bitte angeben, wer bezahlt hat.")
	}
	in.Date = domain.DateOf(in.Date)
	if in.IsReimbursement {
		if len(in.Parts) != 1 {
			return in, invalid("Eine Rückzahlung geht an genau eine Person.")
		}
		if in.Parts[0].ParticipantID == in.PaidBy {
			return in, invalid("Bei einer Rückzahlung müssen Zahler und Empfänger verschieden sein.")
		}
		in.SplitMode = domain.SplitEqual
	}
	if domain.IsEUR(in.OriginalCurrency) {
		in.OriginalCurrency, in.OriginalAmountMinor, in.FXRate, in.FXSource = "EUR", in.AmountCents, 1, ""
	} else {
		cur := strings.ToUpper(strings.TrimSpace(in.OriginalCurrency))
		in.OriginalCurrency = cur
		switch {
		case !domain.ValidCurrencyCode(cur):
			return in, invalid("Ungültige Währung „%s“.", cur)
		case in.OriginalAmountMinor <= 0:
			return in, invalid("Bitte den Betrag in %s angeben.", cur)
		case in.FXRate <= 0:
			return in, invalid("Bitte einen Wechselkurs für %s angeben.", cur)
		}
		if in.AmountCents = domain.ToEURCents(in.OriginalAmountMinor, cur, in.FXRate); in.AmountCents <= 0 {
			return in, invalid("Umgerechnet ergibt der Betrag 0 € – bitte Betrag und Kurs prüfen.")
		}
	}
	shares, err := splitShares(in, 0)
	if err != nil {
		return in, err
	}
	in.Parts = make([]domain.Part, len(shares))
	for i, sh := range shares {
		in.Parts[i] = domain.Part{ParticipantID: sh.ParticipantID, Weight: sh.Weight}
	}
	return in, nil
}

// splitShares computes the cent shares of a validated input (normalize).
// The expense ID determines who gets the extra cent on ties.
func splitShares(in ExpenseInput, expenseID int64) ([]domain.Share, error) {
	return domain.SplitConverted(in.SplitMode, in.AmountCents, in.OriginalAmountMinor, in.OriginalCurrency, in.Parts, expenseID)
}

// checkRefs checks that payer, participants and category exist.
func checkRefs(ctx context.Context, tx *sql.Tx, in ExpenseInput) error {
	ids := []int64{in.PaidBy}
	for _, p := range in.Parts {
		ids = append(ids, p.ParticipantID)
	}
	slices.Sort(ids)
	ids = slices.Compact(ids)
	q := "SELECT count(*) FROM participants WHERE id IN (" + placeholders(len(ids)) + ")"
	var n int
	if err := tx.QueryRowContext(ctx, q, int64sToAny(ids)...).Scan(&n); err != nil {
		return err
	}
	if n != len(ids) {
		return invalid("Unbekannte Person in der Ausgabe.")
	}
	if in.CategoryID != 0 {
		if err := tx.QueryRowContext(ctx, "SELECT count(*) FROM categories WHERE id = ?", in.CategoryID).Scan(&n); err != nil {
			return err
		}
		if n != 1 {
			return invalid("Unbekannte Kategorie.")
		}
	}
	return nil
}

func insertShares(ctx context.Context, tx *sql.Tx, expenseID int64, shares []domain.Share) error {
	for _, sh := range shares {
		if _, err := tx.ExecContext(ctx,
			"INSERT INTO expense_shares (expense_id, participant_id, weight, amount_cents) VALUES (?, ?, ?, ?)",
			expenseID, sh.ParticipantID, sh.Weight, sh.AmountCents); err != nil {
			return err
		}
	}
	return nil
}

// CreateExpense creates an expense, writes the activity entry (actorID 0 =
// system) and then calls the change hooks. Input errors are
// domain.ValidationError.
func (s *Store) CreateExpense(ctx context.Context, actorID int64, in ExpenseInput) (int64, error) {
	in, err := normalize(in)
	if err != nil {
		return 0, err
	}
	var id int64
	err = s.inTx(ctx, func(tx *sql.Tx) error {
		if err := checkRefs(ctx, tx, in); err != nil {
			return err
		}
		if in.RecurringID != 0 {
			// Same transaction as the insert: a recurrence paused or deleted
			// meanwhile gets no instance (instead of a foreign key error).
			var active bool
			err := tx.QueryRowContext(ctx, "SELECT active FROM recurring WHERE id = ?", in.RecurringID).Scan(&active)
			if errors.Is(err, sql.ErrNoRows) || (err == nil && !active) {
				return ErrRecurringChanged
			}
			if err != nil {
				return err
			}
		}
		now := s.nowString()
		res, err := tx.ExecContext(ctx, `INSERT INTO expenses
			(title, date, category_id, paid_by, notes, is_reimbursement, split_mode, amount_cents,
			 original_amount_minor, original_currency, fx_rate, fx_source, recurring_id, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			in.Title, formatDate(in.Date), nullInt(in.CategoryID), in.PaidBy, in.Notes, in.IsReimbursement,
			string(in.SplitMode), in.AmountCents, in.OriginalAmountMinor, in.OriginalCurrency, in.FXRate,
			in.FXSource, nullInt(in.RecurringID), now, now)
		if isUniqueViolation(err) {
			return ErrRecurringExists
		}
		if err != nil {
			return err
		}
		if id, err = res.LastInsertId(); err != nil {
			return err
		}
		shares, err := splitShares(in, id)
		if err != nil {
			return err
		}
		if err := insertShares(ctx, tx, id, shares); err != nil {
			return err
		}
		return s.insertActivity(ctx, tx, actorID, ActionExpenseCreated, id,
			ActivityDetails{Title: in.Title, AmountCents: in.AmountCents})
	})
	if err != nil {
		return 0, err
	}
	s.notify(ExpenseChange{ExpenseID: id, Action: ActionExpenseCreated})
	return id, nil
}

// UpdateExpense updates a (non-deleted) expense. The activity entry contains
// the changed fields; if nothing changed, nothing is logged.
func (s *Store) UpdateExpense(ctx context.Context, actorID, id int64, in ExpenseInput) error {
	in, err := normalize(in)
	if err != nil {
		return err
	}
	shares, err := splitShares(in, id)
	if err != nil {
		return err
	}
	changed := false
	err = s.inTx(ctx, func(tx *sql.Tx) error {
		old, err := getExpense(ctx, tx, id)
		if err != nil {
			return err
		}
		if old.Deleted() {
			return ErrNotFound
		}
		if err := checkRefs(ctx, tx, in); err != nil {
			return err
		}
		in.RecurringID = old.RecurringID
		changes, err := diffExpense(ctx, tx, old, in, shares)
		if err != nil {
			return err
		}
		if len(changes) == 0 {
			return nil
		}
		changed = true
		_, err = tx.ExecContext(ctx, `UPDATE expenses SET
			title = ?, date = ?, category_id = ?, paid_by = ?, notes = ?, is_reimbursement = ?, split_mode = ?,
			amount_cents = ?, original_amount_minor = ?, original_currency = ?, fx_rate = ?, fx_source = ?,
			updated_at = ?
			WHERE id = ?`,
			in.Title, formatDate(in.Date), nullInt(in.CategoryID), in.PaidBy, in.Notes, in.IsReimbursement,
			string(in.SplitMode), in.AmountCents, in.OriginalAmountMinor, in.OriginalCurrency, in.FXRate,
			in.FXSource, s.nowString(), id)
		if isUniqueViolation(err) {
			// Unique index (recurring_id, date): here this is an input error.
			return invalid("Für diesen Termin gibt es schon eine Ausgabe dieser Wiederholung.")
		}
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM expense_shares WHERE expense_id = ?", id); err != nil {
			return err
		}
		if err := insertShares(ctx, tx, id, shares); err != nil {
			return err
		}
		return s.insertActivity(ctx, tx, actorID, ActionExpenseUpdated, id,
			ActivityDetails{Title: in.Title, AmountCents: in.AmountCents, Changes: changes})
	})
	if err != nil {
		return err
	}
	if changed {
		s.notify(ExpenseChange{ExpenseID: id, Action: ActionExpenseUpdated})
	}
	return nil
}

// DeleteExpense soft-deletes an expense (deleted_at). Already deleted or
// unknown expenses yield ErrNotFound.
func (s *Store) DeleteExpense(ctx context.Context, actorID, id int64) error {
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		old, err := getExpense(ctx, tx, id)
		if err != nil {
			return err
		}
		if old.Deleted() {
			return ErrNotFound
		}
		now := s.nowString()
		if _, err := tx.ExecContext(ctx, "UPDATE expenses SET deleted_at = ?, updated_at = ? WHERE id = ?", now, now, id); err != nil {
			return err
		}
		return s.insertActivity(ctx, tx, actorID, ActionExpenseDeleted, id,
			ActivityDetails{Title: old.Title, AmountCents: old.AmountCents})
	})
	if err != nil {
		return err
	}
	s.notify(ExpenseChange{ExpenseID: id, Action: ActionExpenseDeleted})
	return nil
}

// GetExpense returns an expense including shares, also deleted ones (see
// Deleted()), so that e.g. the YNAB sync can process deletions.
func (s *Store) GetExpense(ctx context.Context, id int64) (Expense, error) {
	return getExpense(ctx, s.db, id)
}

// ListExpenses returns non-deleted expenses, newest first (date, then ID).
func (s *Store) ListExpenses(ctx context.Context, f ExpenseFilter) ([]Expense, error) {
	where := []string{"e.deleted_at IS NULL"}
	var args []any
	if t := strings.TrimSpace(f.Text); t != "" {
		// Folded in Go (see fold): LIKE would only be case-insensitive for
		// ASCII.
		t = fold(t)
		where = append(where, "(instr("+foldFunc+"(e.title), ?) > 0 OR instr("+foldFunc+"(e.notes), ?) > 0)")
		args = append(args, t, t)
	}
	switch {
	case f.WithoutCategory:
		where = append(where, "e.category_id IS NULL")
	case f.CategoryID != 0:
		where = append(where, "e.category_id = ?")
		args = append(args, f.CategoryID)
	}
	if f.ParticipantID != 0 {
		where = append(where, "(e.paid_by = ? OR EXISTS (SELECT 1 FROM expense_shares x WHERE x.expense_id = e.id AND x.participant_id = ?))")
		args = append(args, f.ParticipantID, f.ParticipantID)
	}
	if !f.From.IsZero() {
		where = append(where, "e.date >= ?")
		args = append(args, formatDate(f.From))
	}
	if !f.To.IsZero() {
		where = append(where, "e.date <= ?")
		args = append(args, formatDate(f.To))
	}
	q := expenseSelect + " WHERE " + strings.Join(where, " AND ") + " ORDER BY e.date DESC, e.id DESC"
	if f.Limit > 0 {
		q += " LIMIT ? OFFSET ?"
		args = append(args, f.Limit, f.Offset)
	}
	return queryExpenses(ctx, s.db, q, args...)
}

// NextExpenseID is the ID the next new expense will most likely get (SQLite
// assigns max(id) + 1; deletes are soft only). The form preview needs it to
// distribute leftover cents like domain.Split; if someone creates an expense
// at the same time, the preview is off by at most one cent. What gets stored
// is always the store's calculation.
func (s *Store) NextExpenseID(ctx context.Context) (int64, error) {
	var n int64
	err := s.db.QueryRowContext(ctx, "SELECT coalesce(max(id), 0) + 1 FROM expenses").Scan(&n)
	return n, err
}

// BalanceEntries returns all non-deleted expenses in the form that
// domain.Balances needs.
func (s *Store) BalanceEntries(ctx context.Context) ([]domain.Entry, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT e.id, e.paid_by, e.amount_cents, x.participant_id, x.amount_cents
		FROM expenses e JOIN expense_shares x ON x.expense_id = e.id
		WHERE e.deleted_at IS NULL ORDER BY e.id, x.participant_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []domain.Entry
	var lastID int64
	for rows.Next() {
		var id, paidBy, amount, pid, share int64
		if err := rows.Scan(&id, &paidBy, &amount, &pid, &share); err != nil {
			return nil, err
		}
		if id != lastID {
			out = append(out, domain.Entry{PaidBy: paidBy, AmountCents: amount})
			lastID = id
		}
		e := &out[len(out)-1]
		e.Shares = append(e.Shares, domain.Share{ParticipantID: pid, AmountCents: share})
	}
	return out, rows.Err()
}

// Balances returns the balance per person (cents; positive = is owed money).
// People without entries are missing from the map (balance 0).
func (s *Store) Balances(ctx context.Context) (map[int64]int64, error) {
	entries, err := s.BalanceEntries(ctx)
	if err != nil {
		return nil, err
	}
	return domain.Balances(entries), nil
}

// --- Reading -------------------------------------------------------------

type queryer interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

const expenseSelect = `SELECT e.id, e.title, e.date, e.category_id, e.paid_by, e.notes, e.is_reimbursement,
	e.split_mode, e.amount_cents, e.original_amount_minor, e.original_currency, e.fx_rate, e.fx_source,
	e.recurring_id, e.created_at, e.updated_at, e.deleted_at, coalesce(c.name, ''), p.name
	FROM expenses e
	LEFT JOIN categories c ON c.id = e.category_id
	JOIN participants p ON p.id = e.paid_by`

func getExpense(ctx context.Context, q queryer, id int64) (Expense, error) {
	es, err := queryExpenses(ctx, q, expenseSelect+" WHERE e.id = ?", id)
	if err != nil {
		return Expense{}, err
	}
	if len(es) == 0 {
		return Expense{}, ErrNotFound
	}
	return es[0], nil
}

func queryExpenses(ctx context.Context, q queryer, query string, args ...any) ([]Expense, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	var out []Expense
	for rows.Next() {
		var e Expense
		var date, mode string
		var category, recurring sql.NullInt64
		var created, updated, deleted sql.NullString
		if err := rows.Scan(&e.ID, &e.Title, &date, &category, &e.PaidBy, &e.Notes, &e.IsReimbursement,
			&mode, &e.AmountCents, &e.OriginalAmountMinor, &e.OriginalCurrency, &e.FXRate, &e.FXSource,
			&recurring, &created, &updated, &deleted, &e.CategoryName, &e.PaidByName); err != nil {
			rows.Close()
			return nil, err
		}
		if e.Date, err = parseDate(date); err != nil {
			rows.Close()
			return nil, fmt.Errorf("expense %d: date %q: %w", e.ID, date, err)
		}
		e.SplitMode = domain.SplitMode(mode)
		e.CategoryID, e.RecurringID = category.Int64, recurring.Int64
		e.CreatedAt, e.UpdatedAt, e.DeletedAt = parseTime(created), parseTime(updated), parseTime(deleted)
		out = append(out, e)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := loadShares(ctx, q, out); err != nil {
		return nil, err
	}
	return out, nil
}

// loadShares fills in the expenses' Shares and Parts (in chunks of 500 IDs).
func loadShares(ctx context.Context, q queryer, es []Expense) error {
	idx := make(map[int64]int, len(es))
	for i, e := range es {
		idx[e.ID] = i
	}
	for start := 0; start < len(es); start += 500 {
		chunk := es[start:min(start+500, len(es))]
		ids := make([]any, len(chunk))
		for i, e := range chunk {
			ids[i] = e.ID
		}
		rows, err := q.QueryContext(ctx, "SELECT expense_id, participant_id, weight, amount_cents FROM expense_shares WHERE expense_id IN ("+
			placeholders(len(ids))+") ORDER BY expense_id, participant_id", ids...)
		if err != nil {
			return err
		}
		for rows.Next() {
			var eid int64
			var sh domain.Share
			if err := rows.Scan(&eid, &sh.ParticipantID, &sh.Weight, &sh.AmountCents); err != nil {
				rows.Close()
				return err
			}
			e := &es[idx[eid]]
			e.Shares = append(e.Shares, sh)
			e.Parts = append(e.Parts, domain.Part{ParticipantID: sh.ParticipantID, Weight: sh.Weight})
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
	}
	return nil
}

// --- Change log ----------------------------------------------------------

func diffExpense(ctx context.Context, tx *sql.Tx, old Expense, in ExpenseInput, shares []domain.Share) ([]FieldChange, error) {
	names, err := participantNames(ctx, tx)
	if err != nil {
		return nil, err
	}
	var changes []FieldChange
	add := func(field, o, n string) {
		if o != n {
			changes = append(changes, FieldChange{Field: field, Old: o, New: n})
		}
	}
	kind := func(r bool) string {
		if r {
			return "Rückzahlung"
		}
		return "Ausgabe"
	}
	add("Art", kind(old.IsReimbursement), kind(in.IsReimbursement))
	add("Titel", old.Title, in.Title)
	add("Betrag", domain.FormatCents(old.AmountCents), domain.FormatCents(in.AmountCents))
	add("Originalbetrag", domain.FormatMoney(old.OriginalAmountMinor, old.OriginalCurrency),
		domain.FormatMoney(in.OriginalAmountMinor, in.OriginalCurrency))
	add("Datum", domain.FormatDate(old.Date), domain.FormatDate(in.Date))
	if old.CategoryID != in.CategoryID {
		newCat := "–"
		if in.CategoryID != 0 {
			if err := tx.QueryRowContext(ctx, "SELECT name FROM categories WHERE id = ?", in.CategoryID).Scan(&newCat); err != nil {
				return nil, err
			}
		}
		add("Kategorie", cmp.Or(old.CategoryName, "–"), newCat)
	}
	add("Bezahlt von", names[old.PaidBy], names[in.PaidBy])
	add("Notiz", old.Notes, in.Notes)
	add("Kurs", rateSummary(old.ExpenseInput), rateSummary(in))
	oldSplit, newSplit := splitSummary(old.SplitMode, old.Shares, names), splitSummary(in.SplitMode, shares, names)
	add("Aufteilung", oldSplit, newSplit)
	if oldSplit == newSplit {
		// same cents but different weights (e.g. shares 1:1 → 2:2)
		label := map[domain.SplitMode]string{domain.SplitShares: "Anteile", domain.SplitPercent: "Prozente",
			domain.SplitAmount: "Beträge"}[in.SplitMode]
		add(cmp.Or(label, "Gewichte"), weightSummary(old.SplitMode, old.OriginalCurrency, old.Shares, names),
			weightSummary(in.SplitMode, in.OriginalCurrency, shares, names))
	}
	return changes, nil
}

// rateSummary describes the exchange rate: "1 € = 1,0857 USD (EZB)", or "–"
// without foreign currency.
func rateSummary(in ExpenseInput) string {
	if domain.IsEUR(in.OriginalCurrency) {
		return "–"
	}
	s := "1 € = " + domain.FormatRate(in.FXRate) + " " + strings.ToUpper(in.OriginalCurrency)
	switch in.FXSource {
	case "":
	case domain.FXSourceECB:
		s += " (EZB)"
	default:
		s += " (" + in.FXSource + ")"
	}
	return s
}

// weightSummary lists the weights per person in the mode's format (amounts in
// currency).
func weightSummary(mode domain.SplitMode, currency string, shares []domain.Share, names map[int64]string) string {
	parts := make([]string, len(shares))
	for i, sh := range shares {
		var w string
		switch mode {
		case domain.SplitPercent:
			w = domain.FormatBasisPoints(sh.Weight)
		case domain.SplitAmount:
			w = domain.FormatMoney(sh.Weight, currency)
		default:
			w = strconv.FormatInt(sh.Weight, 10)
		}
		parts[i] = names[sh.ParticipantID] + " " + w
	}
	return strings.Join(parts, ", ")
}

func splitSummary(mode domain.SplitMode, shares []domain.Share, names map[int64]string) string {
	parts := make([]string, len(shares))
	for i, sh := range shares {
		parts[i] = names[sh.ParticipantID] + " " + domain.FormatCents(sh.AmountCents)
	}
	return mode.Label() + ": " + strings.Join(parts, ", ")
}

func participantNames(ctx context.Context, tx *sql.Tx) (map[int64]string, error) {
	rows, err := tx.QueryContext(ctx, "SELECT id, name FROM participants")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	m := map[int64]string{}
	for rows.Next() {
		var id int64
		var name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, err
		}
		m[id] = name
	}
	return m, rows.Err()
}

// --- Helpers -------------------------------------------------------------

func placeholders(n int) string {
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

func int64sToAny(ids []int64) []any {
	out := make([]any, len(ids))
	for i, id := range ids {
		out[i] = id
	}
	return out
}
