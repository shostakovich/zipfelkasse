package recurring

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

// Register adds the routes under /einstellungen/wiederkehrend:
//
//	GET  /einstellungen/wiederkehrend                  list of rules
//	GET  /einstellungen/wiederkehrend/neu?ausgabe={id} create a rule from an expense
//	POST /einstellungen/wiederkehrend/neu              (ausgabe, haeufigkeit)
//	POST /einstellungen/wiederkehrend/{id}/pausieren
//	POST /einstellungen/wiederkehrend/{id}/fortsetzen
//	POST /einstellungen/wiederkehrend/{id}/vorlage     take the template from the latest instance
//	POST /einstellungen/wiederkehrend/{id}/loeschen
func (s *Service) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /einstellungen/wiederkehrend", s.handleList)
	mux.HandleFunc("GET /einstellungen/wiederkehrend/neu", s.handleNew)
	mux.HandleFunc("POST /einstellungen/wiederkehrend/neu", s.handleCreate)
	mux.HandleFunc("POST /einstellungen/wiederkehrend/{id}/pausieren", s.handleSetActive(false))
	mux.HandleFunc("POST /einstellungen/wiederkehrend/{id}/fortsetzen", s.handleSetActive(true))
	mux.HandleFunc("POST /einstellungen/wiederkehrend/{id}/vorlage", s.handleRefreshTemplate)
	mux.HandleFunc("POST /einstellungen/wiederkehrend/{id}/loeschen", s.handleDelete)
}

const listPath = "/einstellungen/wiederkehrend"

func (s *Service) serverError(w http.ResponseWriter, r *http.Request, err error) {
	s.d.Log.Error("request", "method", r.Method, "path", r.URL.Path, "err", err)
	s.d.Render.Error(w, r, http.StatusInternalServerError, "Da ist etwas schiefgegangen.")
}

func (s *Service) notFound(w http.ResponseWriter, r *http.Request) {
	s.d.Render.Error(w, r, http.StatusNotFound, "Wiederkehrende Ausgabe nicht gefunden.")
}

func actorID(r *http.Request) int64 {
	if me, ok := web.Me(r.Context()); ok {
		return me.ID
	}
	return 0
}

// --- List --------------------------------------------------------------------

type ruleRow struct {
	store.Recurring
	PaidByName string
}

type listData struct {
	Rules []ruleRow
}

func (s *Service) handleList(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	rules, err := s.d.Store.ListRecurring(ctx)
	if err != nil {
		s.serverError(w, r, err)
		return
	}
	names, err := s.participantNames(r)
	if err != nil {
		s.serverError(w, r, err)
		return
	}
	data := listData{Rules: make([]ruleRow, len(rules))}
	for i, rule := range rules {
		data.Rules[i] = ruleRow{Recurring: rule, PaidByName: names[rule.Template.PaidBy]}
	}
	s.pages.Render(w, r, http.StatusOK, "wiederkehrend.html", web.Page{
		Title: "Wiederkehrende Ausgaben", Nav: web.NavSettings, Data: data,
	})
}

func (s *Service) participantNames(r *http.Request) (map[int64]string, error) {
	ps, err := s.d.Store.ListParticipants(r.Context(), true)
	if err != nil {
		return nil, err
	}
	m := make(map[int64]string, len(ps))
	for _, p := range ps {
		m[p.ID] = p.Name
	}
	return m, nil
}

// ruleLabel describes a rule for the activity log:
// `Wiederholung „Miete“ (monatlich)`.
func ruleLabel(r store.Recurring) string {
	return fmt.Sprintf("Wiederholung „%s“ (%s)", r.Template.Title, strings.ToLower(r.Frequency.Label()))
}

func ruleID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return id, err == nil && id > 0
}

func (s *Service) handleSetActive(active bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, ok := ruleID(r)
		if !ok {
			s.notFound(w, r)
			return
		}
		rule, err := s.d.Store.GetRecurring(r.Context(), id)
		if err == nil {
			err = s.d.Store.SetRecurringActive(r.Context(), id, active, s.today())
		}
		switch {
		case errors.Is(err, store.ErrNotFound):
			s.notFound(w, r)
			return
		case err != nil:
			s.serverError(w, r, err)
			return
		}
		msg := "Pausiert."
		verb := "pausiert"
		if active {
			verb = "fortgesetzt"
		}
		s.d.LogSettings(r, ruleLabel(rule)+" "+verb)
		if active {
			msg = "Fortgesetzt."
			n, err := s.MaterializeRule(r.Context(), id, s.today())
			if err != nil {
				s.d.Log.Error("recurring expenses", "err", err)
			}
			if n > 0 {
				msg += fmt.Sprintf(" %s angelegt.", countText(n))
			}
		}
		web.SetFlash(w, msg)
		http.Redirect(w, r, listPath, http.StatusSeeOther)
	}
}

func (s *Service) handleRefreshTemplate(w http.ResponseWriter, r *http.Request) {
	id, ok := ruleID(r)
	if !ok {
		s.notFound(w, r)
		return
	}
	rule, err := s.d.Store.GetRecurring(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		s.notFound(w, r)
		return
	}
	if err != nil {
		s.serverError(w, r, err)
		return
	}
	err = s.d.Store.UpdateRecurringTemplateFromLatest(r.Context(), id)
	switch {
	case errors.Is(err, store.ErrNotFound):
		web.SetFlash(w, "Es gibt keine Ausgabe dieser Wiederholung mehr, aus der die Vorlage übernommen werden könnte.")
	case err != nil:
		s.serverError(w, r, err)
		return
	default:
		s.d.LogSettings(r, ruleLabel(rule)+": Vorlage aus der letzten Ausgabe übernommen")
		web.SetFlash(w, "Vorlage aus der letzten Ausgabe übernommen.")
	}
	http.Redirect(w, r, listPath, http.StatusSeeOther)
}

func (s *Service) handleDelete(w http.ResponseWriter, r *http.Request) {
	id, ok := ruleID(r)
	if !ok {
		s.notFound(w, r)
		return
	}
	err := s.d.Store.DeleteRecurring(r.Context(), actorID(r), id)
	switch {
	case errors.Is(err, store.ErrNotFound):
		s.notFound(w, r)
		return
	case err != nil:
		s.serverError(w, r, err)
		return
	}
	web.SetFlash(w, "Wiederholung gelöscht. Bereits angelegte Ausgaben bleiben erhalten.")
	http.Redirect(w, r, listPath, http.StatusSeeOther)
}

// --- New ---------------------------------------------------------------------

type freqOption struct {
	Value    domain.Frequency
	Label    string
	Next     time.Time // first occurrence after the template
	Missed   int       // occurrences up to today (counted up to maxMissedCount+1)
	Existing int       // of these, occurrences skipped as an equal expense exists
	Checked  bool
}

// Note describes what happens to the missed occurrences, e.g. "3 verpasste
// Termine werden sofort eingetragen; 1 bereits als Ausgabe vorhandener Termin
// wird übersprungen"; "" if there are none. Materialize processes at most
// maxInstancesPerRun occurrences per run, the rest in the next (hourly) runs.
func (o freqOption) Note() string {
	capped := o.Missed > maxMissedCount
	when := "sofort eingetragen"
	if o.Missed > maxInstancesPerRun {
		when = fmt.Sprintf("eingetragen – die ersten %d Termine sofort, der Rest in den nächsten Stunden", maxInstancesPerRun)
	}
	var parts []string
	switch n := o.Missed - o.Existing; {
	case capped:
		parts = append(parts, fmt.Sprintf("mehr als %d verpasste Termine werden %s", maxMissedCount, when))
	case n == 1:
		parts = append(parts, "1 verpasster Termin wird "+when)
	case n > 1:
		parts = append(parts, fmt.Sprintf("%d verpasste Termine werden %s", n, when))
	}
	atLeast := ""
	if capped {
		atLeast = "mindestens "
	}
	if o.Existing == 1 {
		parts = append(parts, atLeast+"1 bereits als Ausgabe vorhandener Termin wird übersprungen")
	} else if o.Existing > 1 {
		parts = append(parts, fmt.Sprintf("%s%d bereits als Ausgabe vorhandene Termine werden übersprungen", atLeast, o.Existing))
	}
	return strings.Join(parts, "; ")
}

type newData struct {
	Expense  *store.Expense // nil: no expense selected
	Options  []freqOption
	Existing int64 // the expense already belongs to this recurring rule
}

// maxMissedCount caps counting missed occurrences for the preview: beyond
// it, the preview says "mehr als 1000".
const maxMissedCount = 1000

func (s *Service) newData(ctx context.Context, e store.Expense, selected domain.Frequency) (newData, error) {
	today := s.today()
	data := newData{Expense: &e, Existing: e.RecurringID}
	var existing map[time.Time]bool
	if e.Date.Before(today) {
		var err error
		existing, err = s.d.Store.ExpenseDatesLike(ctx, e.ExpenseInput, e.Date.AddDate(0, 0, 1), today)
		if err != nil {
			return data, err
		}
	}
	for _, f := range domain.Frequencies {
		o := freqOption{Value: f, Label: f.Label(), Next: domain.NextDate(f, e.Date, e.Date), Checked: f == selected}
		for d := o.Next; !d.After(today) && o.Missed <= maxMissedCount; d = domain.NextDate(f, e.Date, d) {
			o.Missed++
			if existing[d] {
				o.Existing++
			}
		}
		data.Options = append(data.Options, o)
	}
	return data, nil
}

func (s *Service) renderNew(w http.ResponseWriter, r *http.Request, status int, data newData, errMsg string) {
	s.pages.Render(w, r, status, "wiederkehrend_neu.html", web.Page{
		Title: "Wiederkehrende Ausgabe anlegen", Nav: web.NavSettings, Error: errMsg, Data: data,
	})
}

// loadExpense reads the expense from the "ausgabe" parameter; ok=false means
// the response has already been written.
func (s *Service) loadExpense(w http.ResponseWriter, r *http.Request) (store.Expense, bool) {
	id, err := strconv.ParseInt(r.FormValue("ausgabe"), 10, 64)
	if err != nil || id <= 0 {
		s.d.Render.Error(w, r, http.StatusNotFound, "Ausgabe nicht gefunden.")
		return store.Expense{}, false
	}
	e, err := s.d.Store.GetExpense(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) || (err == nil && e.Deleted()) {
		s.d.Render.Error(w, r, http.StatusNotFound, "Ausgabe nicht gefunden.")
		return e, false
	}
	if err != nil {
		s.serverError(w, r, err)
		return e, false
	}
	return e, true
}

func (s *Service) handleNew(w http.ResponseWriter, r *http.Request) {
	if r.FormValue("ausgabe") == "" {
		s.renderNew(w, r, http.StatusOK, newData{}, "")
		return
	}
	e, ok := s.loadExpense(w, r)
	if !ok {
		return
	}
	data, err := s.newData(r.Context(), e, domain.FreqMonthly)
	if err != nil {
		s.serverError(w, r, err)
		return
	}
	s.renderNew(w, r, http.StatusOK, data, "")
}

func (s *Service) handleCreate(w http.ResponseWriter, r *http.Request) {
	e, ok := s.loadExpense(w, r)
	if !ok {
		return
	}
	freq := domain.Frequency(r.FormValue("haeufigkeit"))
	id, err := s.d.Store.CreateRecurringFromExpense(r.Context(), actorID(r), e.ID, freq)
	var ve domain.ValidationError
	switch {
	case errors.As(err, &ve):
		data, err := s.newData(r.Context(), e, freq)
		if err != nil {
			s.serverError(w, r, err)
			return
		}
		s.renderNew(w, r, http.StatusUnprocessableEntity, data, ve.Msg)
		return
	case errors.Is(err, store.ErrNotFound):
		s.d.Render.Error(w, r, http.StatusNotFound, "Ausgabe nicht gefunden.")
		return
	case err != nil:
		s.serverError(w, r, err)
		return
	}
	msg := fmt.Sprintf("„%s“ wiederholt sich jetzt %s.", e.Title, adverb(freq))
	n, err := s.MaterializeRule(r.Context(), id, s.today())
	if err != nil {
		s.d.Log.Error("recurring expenses", "err", err)
	}
	if n > 0 {
		msg += fmt.Sprintf(" %s nachgetragen.", countText(n))
	}
	web.SetFlash(w, msg)
	http.Redirect(w, r, listPath, http.StatusSeeOther)
}

func adverb(f domain.Frequency) string {
	switch f {
	case domain.FreqWeekly:
		return "wöchentlich"
	case domain.FreqMonthly:
		return "monatlich"
	case domain.FreqYearly:
		return "jährlich"
	}
	return string(f)
}

func countText(n int) string {
	if n == 1 {
		return "1 Ausgabe"
	}
	return fmt.Sprintf("%d Ausgaben", n)
}
