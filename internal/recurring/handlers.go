package recurring

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"teilen/internal/domain"
	"teilen/internal/store"
	"teilen/internal/web"
)

// Register hängt die Routen unter /einstellungen/wiederkehrend an:
//
//	GET  /einstellungen/wiederkehrend                  Liste der Regeln
//	GET  /einstellungen/wiederkehrend/neu?ausgabe={id} Regel aus einer Ausgabe anlegen
//	POST /einstellungen/wiederkehrend/neu              (ausgabe, haeufigkeit)
//	POST /einstellungen/wiederkehrend/{id}/pausieren
//	POST /einstellungen/wiederkehrend/{id}/fortsetzen
//	POST /einstellungen/wiederkehrend/{id}/vorlage     Vorlage aus jüngster Instanz übernehmen
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

// --- Liste -------------------------------------------------------------------

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

// ruleLabel beschreibt eine Regel fürs Aktivitätsprotokoll:
// „Wiederholung „Miete“ (monatlich)“.
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
			if n, err := s.Materialize(r.Context(), s.today()); err != nil {
				s.d.Log.Error("wiederkehrende Ausgaben", "err", err)
			} else if n > 0 {
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

// --- Neu ---------------------------------------------------------------------

type freqOption struct {
	Value   domain.Frequency
	Label   string
	Next    time.Time // erster Termin nach der Vorlage
	Missed  int       // Termine bis heute, die sofort nachgetragen werden
	Checked bool
}

type newData struct {
	Expense  *store.Expense // nil: keine Ausgabe gewählt
	Options  []freqOption
	Existing int64 // Ausgabe gehört schon zu dieser Wiederholung
}

// maxMissedCount begrenzt das Zählen verpasster Termine für die Vorschau.
const maxMissedCount = 1000

func (s *Service) newData(e store.Expense, selected domain.Frequency) newData {
	today := s.today()
	data := newData{Expense: &e, Existing: e.RecurringID}
	for _, f := range domain.Frequencies {
		o := freqOption{Value: f, Label: f.Label(), Next: domain.NextDate(f, e.Date, e.Date), Checked: f == selected}
		for d := o.Next; !d.After(today) && o.Missed < maxMissedCount; d = domain.NextDate(f, e.Date, d) {
			o.Missed++
		}
		data.Options = append(data.Options, o)
	}
	return data
}

func (s *Service) renderNew(w http.ResponseWriter, r *http.Request, status int, data newData, errMsg string) {
	s.pages.Render(w, r, status, "wiederkehrend_neu.html", web.Page{
		Title: "Wiederkehrende Ausgabe anlegen", Nav: web.NavSettings, Error: errMsg, Data: data,
	})
}

// loadExpense liest die Ausgabe aus dem Parameter „ausgabe“; ok=false heißt,
// die Antwort ist schon geschrieben.
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
	s.renderNew(w, r, http.StatusOK, s.newData(e, domain.FreqMonthly), "")
}

func (s *Service) handleCreate(w http.ResponseWriter, r *http.Request) {
	e, ok := s.loadExpense(w, r)
	if !ok {
		return
	}
	freq := domain.Frequency(r.FormValue("haeufigkeit"))
	_, err := s.d.Store.CreateRecurringFromExpense(r.Context(), actorID(r), e.ID, freq)
	var ve domain.ValidationError
	switch {
	case errors.As(err, &ve):
		s.renderNew(w, r, http.StatusUnprocessableEntity, s.newData(e, freq), ve.Msg)
		return
	case errors.Is(err, store.ErrNotFound):
		s.d.Render.Error(w, r, http.StatusNotFound, "Ausgabe nicht gefunden.")
		return
	case err != nil:
		s.serverError(w, r, err)
		return
	}
	msg := fmt.Sprintf("„%s“ wiederholt sich jetzt %s.", e.Title, adverb(freq))
	if n, err := s.Materialize(r.Context(), s.today()); err != nil {
		s.d.Log.Error("wiederkehrende Ausgaben", "err", err)
	} else if n > 0 {
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
