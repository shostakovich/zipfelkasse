package web

import (
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
)

// --- Home page: expense list ------------------------------------------------

// homePageSize is the number of expenses per "Weitere anzeigen" (show more) step.
const homePageSize = 100

type homeData struct {
	Balance      int64 // own balance (cents)
	Today        time.Time
	Groups       []expenseGroup
	Filter       homeFilter
	Categories   []store.Category
	Participants []store.Participant
	More         string // URL for more expenses, "" = all shown
}

type homeFilter struct {
	Text          string
	CategoryID    int64
	ParticipantID int64
}

func (f homeFilter) Active() bool { return f.Text != "" || f.CategoryID != 0 || f.ParticipantID != 0 }

// expenseGroup holds the expenses of a period ("Diese Woche", …).
type expenseGroup struct {
	Label string
	Rows  []expenseRow
}

// expenseRow is a row of the expense list.
type expenseRow struct {
	store.Expense
	ForNames  []string // names of the participants involved
	Everyone  bool     // all (active) people involved, from 4 people on
	Involved  bool     // the current person pays or is involved
	MyBalance int64    // effect on one's own balance
}

func (h handlers) home(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	me := me(r)
	q := r.URL.Query()
	f := homeFilter{
		Text:          strings.TrimSpace(q.Get("q")),
		CategoryID:    formID(q.Get("kategorie")),
		ParticipantID: formID(q.Get("person")),
	}
	limit := homePageSize
	if n, err := strconv.Atoi(q.Get("anzahl")); err == nil && n > limit {
		limit = min(n, 100_000)
	}
	expenses, err := h.d.Store.ListExpenses(ctx, store.ExpenseFilter{
		Text: f.Text, CategoryID: f.CategoryID, ParticipantID: f.ParticipantID, Limit: limit + 1,
	})
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	balances, err := h.d.Store.Balances(ctx)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	people, err := h.d.Store.ListParticipants(ctx, true)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	cats, err := h.d.Store.ListCategories(ctx, true)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	data := homeData{Balance: balances[me.ID], Today: h.d.Today(), Filter: f}
	// Filter options: active entries plus the currently selected one (even if archived).
	for _, c := range cats {
		if !c.Archived() || c.ID == f.CategoryID {
			data.Categories = append(data.Categories, c)
		}
	}
	names := map[int64]string{}
	active := 0
	for _, p := range people {
		names[p.ID] = p.Name
		if !p.Archived() {
			active++
		}
		if !p.Archived() || p.ID == f.ParticipantID {
			data.Participants = append(data.Participants, p)
		}
	}
	if len(expenses) > limit {
		expenses = expenses[:limit]
		v := url.Values{}
		if f.Text != "" {
			v.Set("q", f.Text)
		}
		if f.CategoryID != 0 {
			v.Set("kategorie", strconv.FormatInt(f.CategoryID, 10))
		}
		if f.ParticipantID != 0 {
			v.Set("person", strconv.FormatInt(f.ParticipantID, 10))
		}
		v.Set("anzahl", strconv.Itoa(limit+homePageSize))
		data.More = "/?" + v.Encode()
	}
	data.Groups = groupExpenses(expenses, data.Today, me.ID, names, active)
	h.d.Render.Page(w, r, http.StatusOK, "home.html", Page{Title: "Ausgaben", Nav: NavExpenses, Data: data})
}

// groupExpenses splits the expenses (sorted by date, descending) into periods
// and prepares the rows.
func groupExpenses(es []store.Expense, today time.Time, meID int64, names map[int64]string, activeCount int) []expenseGroup {
	var groups []expenseGroup
	last := -1
	for _, e := range es {
		row := expenseRow{Expense: e, Everyone: len(e.Shares) == activeCount && activeCount >= 4}
		for _, sh := range e.Shares {
			row.ForNames = append(row.ForNames, names[sh.ParticipantID])
			if sh.ParticipantID == meID {
				row.Involved = true
			}
		}
		if e.PaidBy == meID {
			row.Involved = true
			row.MyBalance += e.AmountCents
		}
		row.MyBalance -= e.ShareOf(meID)
		p := expensePeriod(e.Date, today)
		if p != last {
			groups = append(groups, expenseGroup{Label: periodLabels[p]})
			last = p
		}
		groups[len(groups)-1].Rows = append(groups[len(groups)-1].Rows, row)
	}
	return groups
}

// --- Form ----------------------------------------------------------------------

// commonCurrencies are offered in the form; other ISO codes are possible via
// "Andere …" (other).
var commonCurrencies = []string{"EUR", "USD", "GBP", "CHF", "DKK", "SEK", "NOK", "PLN", "CZK", "HUF", "TRY", "JPY", "CAD", "AUD"}

// expenseForm holds the form values as text, so that after an error they are
// shown again exactly as they were entered.
type expenseForm struct {
	ID              int64 // 0 = new expense
	Title           string
	Date            string // YYYY-MM-DD
	Category        int64
	Currency        string // from commonCurrencies, "" = other
	CurrencyOther   string
	Amount          string // in the selected currency
	Rate            string // foreign currency per 1 EUR
	RateSource      string // domain.FXSource*
	PaidBy          int64
	Notes           string
	IsReimbursement bool
	SplitMode       domain.SplitMode
	Rows            []splitRow
	EURCents        int64 // converted amount (display), 0 = unknown
}

// splitRow is a person in the split.
type splitRow struct {
	ID       int64
	Name     string
	Archived bool
	Checked  bool
	Value    string // shares / percent / amount, depending on the mode
	Cents    int64  // computed share (only for saved expenses)
}

// CurrencyCode is the effectively selected currency.
func (f expenseForm) CurrencyCode() string {
	c := f.Currency
	if c == "" {
		c = f.CurrencyOther
	}
	c = strings.ToUpper(strings.TrimSpace(c))
	if c == "" {
		return "EUR"
	}
	return c
}

func (f expenseForm) Foreign() bool { return f.CurrencyCode() != "EUR" }

type expensePage struct {
	Form       expenseForm
	Expense    *store.Expense // nil for a new expense
	Categories []store.Category
	Payers     []store.Participant
	Currencies []string
	SplitModes []domain.SplitMode
	History    []activityItem
	Rotation   int64  // expense ID (the expected one for new expenses) for the cent distribution of the preview
	Suggest    string // categorySuggestions as JSON for expense-form.js
}

// formFromExpense fills the form from a saved expense.
func formFromExpense(e store.Expense, people []store.Participant) expenseForm {
	f := expenseForm{
		ID: e.ID, Title: e.Title, Date: e.Date.Format(domain.DateLayout), Category: e.CategoryID,
		PaidBy: e.PaidBy, Notes: e.Notes, IsReimbursement: e.IsReimbursement, SplitMode: e.SplitMode,
		EURCents: e.AmountCents,
	}
	cur := e.OriginalCurrency
	if slices.Contains(commonCurrencies, cur) {
		f.Currency = cur
	} else {
		f.CurrencyOther = cur
	}
	if e.IsForeign() {
		f.Amount = minorInput(e.OriginalAmountMinor, cur)
		f.Rate, f.RateSource = rateInput(e.FXRate), e.FXSource
	} else {
		f.Amount = domain.FormatCentsInput(e.AmountCents)
	}
	// For "by amounts" in a foreign currency, the form holds amounts in the
	// foreign currency; euro cents are stored → convert back proportionally.
	var origWeights []int64
	if e.IsForeign() && e.SplitMode == domain.SplitAmount {
		w := make([]int64, len(e.Shares))
		for i, sh := range e.Shares {
			w[i] = sh.Weight
		}
		origWeights = allocate(e.OriginalAmountMinor, w)
	}
	shareIdx := map[int64]int{}
	for i, sh := range e.Shares {
		shareIdx[sh.ParticipantID] = i
	}
	for _, p := range people {
		i, in := shareIdx[p.ID]
		if p.Archived() && !in && p.ID != e.PaidBy {
			continue
		}
		row := splitRow{ID: p.ID, Name: p.Name, Archived: p.Archived(), Checked: in}
		if in {
			sh := e.Shares[i]
			row.Cents = sh.AmountCents
			switch e.SplitMode {
			case domain.SplitShares:
				row.Value = strconv.FormatInt(sh.Weight, 10)
			case domain.SplitPercent:
				row.Value = strings.TrimSuffix(domain.FormatBasisPoints(sh.Weight), " %")
			case domain.SplitAmount:
				if origWeights != nil {
					row.Value = minorInput(origWeights[i], cur)
				} else {
					row.Value = domain.FormatCentsInput(sh.Weight)
				}
			}
		}
		f.Rows = append(f.Rows, row)
	}
	return f
}

// newExpenseForm returns the empty form (all active people involved, I paid)
// or a prefilled reimbursement (?rueckzahlung=1&von=ID&an=ID&betrag=cents, like
// Spliit's "mark as paid").
func newExpenseForm(q url.Values, today time.Time, meID int64, people []store.Participant) expenseForm {
	f := expenseForm{
		Date: today.Format(domain.DateLayout), Currency: "EUR", PaidBy: meID, SplitMode: domain.SplitEqual,
	}
	reimb := q.Get("rueckzahlung") != ""
	to := formID(q.Get("an"))
	if reimb {
		f.IsReimbursement, f.Title = true, "Rückzahlung"
		if from := formID(q.Get("von")); from != 0 {
			f.PaidBy = from
		}
		if c, err := strconv.ParseInt(q.Get("betrag"), 10, 64); err == nil && c > 0 {
			f.Amount = domain.FormatCentsInput(c)
		}
	}
	for _, p := range people {
		if p.Archived() && p.ID != f.PaidBy && p.ID != to {
			continue
		}
		checked := !p.Archived()
		if reimb {
			checked = p.ID == to
		}
		f.Rows = append(f.Rows, splitRow{ID: p.ID, Name: p.Name, Archived: p.Archived(), Checked: checked})
	}
	return f
}

// readExpenseForm reads the form values (without validation). people are all
// people including archived ones; active and checked ones are shown.
func readExpenseForm(r *http.Request, id int64, people []store.Participant, existing *store.Expense) expenseForm {
	f := expenseForm{
		ID:              id,
		Title:           r.PostFormValue("titel"),
		Date:            strings.TrimSpace(r.PostFormValue("datum")),
		Category:        formID(r.PostFormValue("kategorie")),
		Currency:        strings.ToUpper(strings.TrimSpace(r.PostFormValue("waehrung"))),
		CurrencyOther:   strings.ToUpper(strings.TrimSpace(r.PostFormValue("waehrung_andere"))),
		Amount:          strings.TrimSpace(r.PostFormValue("betrag")),
		Rate:            strings.TrimSpace(r.PostFormValue("kurs")),
		RateSource:      r.PostFormValue("kurs_quelle"),
		PaidBy:          formID(r.PostFormValue("bezahlt_von")),
		Notes:           r.PostFormValue("notiz"),
		IsReimbursement: r.PostFormValue("rueckzahlung") != "",
		SplitMode:       domain.SplitMode(r.PostFormValue("aufteilung")),
	}
	if !f.SplitMode.Valid() {
		f.SplitMode = domain.SplitEqual
	}
	checked := map[int64]bool{}
	for _, v := range r.PostForm["teil"] {
		if id := formID(v); id != 0 {
			checked[id] = true
		}
	}
	inExisting := map[int64]bool{}
	if existing != nil {
		inExisting[existing.PaidBy] = true
		for _, sh := range existing.Shares {
			inExisting[sh.ParticipantID] = true
		}
	}
	for _, p := range people {
		if p.Archived() && !checked[p.ID] && !inExisting[p.ID] && p.ID != f.PaidBy {
			continue
		}
		f.Rows = append(f.Rows, splitRow{
			ID: p.ID, Name: p.Name, Archived: p.Archived(), Checked: checked[p.ID],
			Value: strings.TrimSpace(r.PostFormValue("wert_" + strconv.FormatInt(p.ID, 10))),
		})
	}
	return f
}

// toInput validates the form and builds the store input from it. Errors are
// domain.ValidationError with a German message. If the rate is missing for a
// foreign currency, it is fetched via d.FX and copied into the form.
func (h handlers) toInput(r *http.Request, f *expenseForm) (store.ExpenseInput, error) {
	in := store.ExpenseInput{
		Title: f.Title, CategoryID: f.Category, PaidBy: f.PaidBy, Notes: f.Notes,
		IsReimbursement: f.IsReimbursement, SplitMode: f.SplitMode,
	}
	if strings.TrimSpace(f.Title) == "" {
		return in, invalidf("Bitte einen Titel angeben.")
	}
	date, err := domain.ParseDate(f.Date)
	if err != nil {
		return in, err
	}
	in.Date = date

	cur := f.CurrencyCode()
	if !isCurrencyCode(cur) {
		return in, invalidf("Ungültige Währung „%s“ – bitte einen dreistelligen ISO-Code wie USD angeben.", cur)
	}
	if cur == "EUR" {
		if in.AmountCents, err = domain.ParseCents(f.Amount); err != nil {
			return in, err
		}
	} else {
		dec := domain.CurrencyDecimals(cur)
		if in.OriginalAmountMinor, err = domain.ParseMinor(f.Amount, dec); err != nil {
			return in, err
		}
		if in.OriginalAmountMinor <= 0 {
			return in, invalidf("Der Betrag muss größer als 0 sein.")
		}
		in.OriginalCurrency = cur
		if f.Rate != "" {
			if in.FXRate, err = domain.ParseRate(f.Rate); err != nil {
				return in, err
			}
			in.FXSource = domain.FXSourceManual
			if f.RateSource == domain.FXSourceECB {
				in.FXSource = domain.FXSourceECB
			}
		} else {
			rate, err := h.lookupRate(r, cur, date)
			if err != nil {
				return in, err
			}
			in.FXRate, in.FXSource = rate.Rate, rate.Source
			f.Rate, f.RateSource = rateInput(rate.Rate), rate.Source
		}
		in.AmountCents = domain.ToEURCents(in.OriginalAmountMinor, cur, in.FXRate)
		if in.AmountCents <= 0 {
			return in, invalidf("Umgerechnet ergibt der Betrag 0 € – bitte Betrag und Kurs prüfen.")
		}
		f.EURCents = in.AmountCents
	}
	if in.AmountCents <= 0 {
		return in, invalidf("Der Betrag muss größer als 0 sein.")
	}

	// Split.
	var rows []splitRow
	for _, row := range f.Rows {
		if row.Checked {
			rows = append(rows, row)
		}
	}
	if f.IsReimbursement {
		if len(rows) != 1 {
			return in, invalidf("Eine Rückzahlung geht an genau eine Person – bitte genau einen Empfänger ankreuzen.")
		}
		in.SplitMode = domain.SplitEqual
		in.Parts = []domain.Part{{ParticipantID: rows[0].ID}}
		return in, nil
	}
	if len(rows) == 0 {
		return in, invalidf("Bitte mindestens eine Person ankreuzen, für die bezahlt wurde.")
	}
	foreignAmounts := cur != "EUR" && in.SplitMode == domain.SplitAmount
	var origSum int64
	for _, row := range rows {
		p := domain.Part{ParticipantID: row.ID}
		v := row.Value
		var err error
		switch in.SplitMode {
		case domain.SplitShares:
			if v == "" {
				v = "1"
			}
			p.Weight, err = strconv.ParseInt(v, 10, 64)
			if err != nil {
				err = invalidf("%s: Anteile müssen ganze Zahlen sein („%s“).", row.Name, v)
			}
		case domain.SplitPercent:
			if v == "" {
				v = "0"
			}
			p.Weight, err = domain.ParseBasisPoints(v)
		case domain.SplitAmount:
			if v == "" {
				v = "0"
			}
			if foreignAmounts {
				p.Weight, err = domain.ParseMinor(v, domain.CurrencyDecimals(cur))
				origSum += p.Weight
			} else {
				p.Weight, err = domain.ParseCents(v)
			}
		}
		if err != nil {
			if msg, ok := validationMsg(err); ok && !strings.HasPrefix(msg, row.Name) {
				err = invalidf("%s: %s", row.Name, msg)
			}
			return in, err
		}
		if p.Weight < 0 {
			return in, invalidf("%s: Negative Werte sind nicht erlaubt.", row.Name)
		}
		in.Parts = append(in.Parts, p)
	}
	if foreignAmounts {
		if origSum != in.OriginalAmountMinor {
			return in, invalidf("Die Beträge müssen zusammen %s ergeben (aktuell %s).",
				domain.FormatMoney(in.OriginalAmountMinor, cur), domain.FormatMoney(origSum, cur))
		}
		// Sort by ID: a tie in the remainder → smaller ID, as in domain.Split
		// and in the JS preview (independent of the order in the form).
		slices.SortFunc(in.Parts, func(a, b domain.Part) int { return cmp.Compare(a.ParticipantID, b.ParticipantID) })
		w := make([]int64, len(in.Parts))
		for i, p := range in.Parts {
			w[i] = p.Weight
		}
		for i, c := range allocate(in.AmountCents, w) {
			in.Parts[i].Weight = c
		}
	}
	return in, nil
}

// lookupRate fetches the rate via d.FX (may be nil in tests).
func (h handlers) lookupRate(r *http.Request, cur string, date time.Time) (domain.FXRate, error) {
	msg := fmt.Sprintf("Für %s ist am %s kein Wechselkurs verfügbar. Kurs bitte von Hand eintragen.", cur, domain.FormatDate(date))
	if h.d.FX == nil {
		return domain.FXRate{}, invalidf("%s", msg)
	}
	rate, err := h.d.FX.Rate(r.Context(), cur, date)
	if err != nil || rate.Rate <= 0 {
		if err != nil {
			h.d.Log.Info("rate not available", "currency", cur, "date", date.Format(domain.DateLayout), "err", err)
		}
		return domain.FXRate{}, invalidf("%s", msg)
	}
	if rate.Source == "" {
		rate.Source = domain.FXSourceECB
	}
	return rate, nil
}

func isCurrencyCode(s string) bool {
	if len(s) != 3 {
		return false
	}
	for _, c := range s {
		if c < 'A' || c > 'Z' {
			return false
		}
	}
	return true
}

func invalidf(format string, args ...any) error {
	return domain.ValidationError{Msg: fmt.Sprintf(format, args...)}
}

// renderExpense renders the form (new or edit).
func (h handlers) renderExpense(w http.ResponseWriter, r *http.Request, status int, f expenseForm, e *store.Expense, errMsg string) {
	ctx := r.Context()
	cats, err := h.d.Store.ListCategories(ctx, true)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	people, err := h.d.Store.ListParticipants(ctx, true)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	p := expensePage{Form: f, Expense: e, Currencies: commonCurrencies, SplitModes: domain.SplitModes, Rotation: f.ID}
	if p.Rotation == 0 {
		if p.Rotation, err = h.d.Store.NextExpenseID(ctx); err != nil {
			h.serverError(w, r, err)
			return
		}
	}
	for _, c := range cats {
		if !c.Archived() || c.ID == f.Category {
			p.Categories = append(p.Categories, c)
		}
	}
	hist, err := h.d.Store.CategoryHistory(ctx)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	suggest, err := json.Marshal(suggestCategories(hist))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	p.Suggest = string(suggest)
	for _, x := range people {
		if !x.Archived() || x.ID == f.PaidBy {
			p.Payers = append(p.Payers, x)
		}
	}
	title := "Neue Ausgabe"
	if e != nil {
		title = e.Title
		acts, err := h.d.Store.ListActivity(ctx, store.ActivityFilter{ExpenseID: e.ID, Limit: 50})
		if err != nil {
			h.serverError(w, r, err)
			return
		}
		p.History = activityItems(acts)
	}
	h.d.Render.Page(w, r, status, "expense.html", Page{Title: title, Nav: NavExpenses, Error: errMsg, Data: p})
}

func (h handlers) expenseNew(w http.ResponseWriter, r *http.Request) {
	people, err := h.d.Store.ListParticipants(r.Context(), true)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	f := newExpenseForm(r.URL.Query(), h.d.Today(), me(r).ID, people)
	h.renderExpense(w, r, http.StatusOK, f, nil, "")
}

func (h handlers) expenseCreate(w http.ResponseWriter, r *http.Request) {
	h.saveExpense(w, r, nil)
}

func (h handlers) expenseShow(w http.ResponseWriter, r *http.Request) {
	e, ok := h.loadExpense(w, r)
	if !ok {
		return
	}
	people, err := h.d.Store.ListParticipants(r.Context(), true)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.renderExpense(w, r, http.StatusOK, formFromExpense(e, people), &e, "")
}

func (h handlers) expenseUpdate(w http.ResponseWriter, r *http.Request) {
	e, ok := h.loadExpense(w, r)
	if !ok {
		return
	}
	if e.Deleted() {
		h.d.Render.Error(w, r, http.StatusConflict, "Diese Ausgabe wurde gelöscht und kann nicht mehr bearbeitet werden.")
		return
	}
	h.saveExpense(w, r, &e)
}

// saveExpense creates an expense (existing == nil) or updates it.
func (h handlers) saveExpense(w http.ResponseWriter, r *http.Request, existing *store.Expense) {
	ctx := r.Context()
	if err := r.ParseForm(); err != nil {
		h.d.Render.Error(w, r, http.StatusBadRequest, "Ungültige Anfrage.")
		return
	}
	people, err := h.d.Store.ListParticipants(ctx, true)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	var id int64
	if existing != nil {
		id = existing.ID
	}
	f := readExpenseForm(r, id, people, existing)
	in, err := h.toInput(r, &f)
	if err == nil {
		if existing == nil {
			_, err = h.d.Store.CreateExpense(ctx, me(r).ID, in)
		} else {
			err = h.d.Store.UpdateExpense(ctx, me(r).ID, existing.ID, in)
		}
	}
	if msg, ok := validationMsg(err); ok {
		h.renderExpense(w, r, http.StatusUnprocessableEntity, f, existing, msg)
		return
	}
	if errors.Is(err, store.ErrNotFound) {
		h.notFound(w, r, "Ausgabe nicht gefunden.")
		return
	}
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	kind := "Ausgabe"
	if in.IsReimbursement {
		kind = "Rückzahlung"
	}
	if existing == nil {
		SetFlash(w, fmt.Sprintf("%s „%s“ angelegt.", kind, strings.Join(strings.Fields(in.Title), " ")))
	} else {
		SetFlash(w, fmt.Sprintf("%s „%s“ gespeichert.", kind, strings.Join(strings.Fields(in.Title), " ")))
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (h handlers) expenseDelete(w http.ResponseWriter, r *http.Request) {
	e, ok := h.loadExpense(w, r)
	if !ok {
		return
	}
	err := h.d.Store.DeleteExpense(r.Context(), me(r).ID, e.ID)
	if errors.Is(err, store.ErrNotFound) {
		h.notFound(w, r, "Ausgabe nicht gefunden oder schon gelöscht.")
		return
	}
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	SetFlash(w, fmt.Sprintf("„%s“ gelöscht.", e.Title))
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// loadExpense loads the expense from the path (deleted ones too); on error the
// response has already been written.
func (h handlers) loadExpense(w http.ResponseWriter, r *http.Request) (store.Expense, bool) {
	id := pathID(r)
	if id == 0 {
		h.notFound(w, r, "Ausgabe nicht gefunden.")
		return store.Expense{}, false
	}
	e, err := h.d.Store.GetExpense(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		h.notFound(w, r, "Ausgabe nicht gefunden.")
		return e, false
	}
	if err != nil {
		h.serverError(w, r, err)
		return e, false
	}
	return e, true
}
