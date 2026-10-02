// Package export bietet Ausgaben als CSV/JSON und die eigenen Anteile als
// OFX/CSV für YNAB zum Herunterladen an.
//
// Die YNAB-Dateien enthalten genau die Buchungen, die auch der YNAB-Sync
// schreibt (ynab.Postings) – als Fallback für den Dateiimport ins Konto „Geteilt“.
package export

import (
	"bytes"
	"embed"
	"errors"
	"net/http"
	"slices"
	"strconv"
	"time"

	"teilen/internal/domain"
	"teilen/internal/store"
	"teilen/internal/web"
	"teilen/internal/ynab"
)

//go:embed templates/*.html
var templatesFS embed.FS

type handlers struct {
	d     web.Deps
	pages *web.Pages
	now   func() time.Time
}

// Register hängt die Routen unter /export an.
func Register(mux *http.ServeMux, d web.Deps) error {
	pages, err := d.Render.Load(templatesFS, "templates/*.html")
	if err != nil {
		return err
	}
	h := handlers{d: d, pages: pages, now: time.Now}
	mux.HandleFunc("GET /export", h.page)
	mux.HandleFunc("GET /export/ausgaben.csv", h.expensesCSV)
	mux.HandleFunc("GET /export/ausgaben.json", h.expensesJSON)
	mux.HandleFunc("GET /export/ynab.ofx", h.ynabOFX)
	mux.HandleFunc("GET /export/ynab.csv", h.ynabCSV)
	return nil
}

// period ist der optionale Zeitraum (?von=…&bis=…, jeweils inklusive).
type period struct {
	From, To time.Time
}

func parsePeriod(r *http.Request) (period, error) {
	var p period
	var err error
	if v := r.URL.Query().Get("von"); v != "" {
		if p.From, err = domain.ParseDate(v); err != nil {
			return p, err
		}
	}
	if v := r.URL.Query().Get("bis"); v != "" {
		if p.To, err = domain.ParseDate(v); err != nil {
			return p, err
		}
	}
	if !p.From.IsZero() && !p.To.IsZero() && p.To.Before(p.From) {
		return p, domain.ValidationError{Msg: "„Bis“ liegt vor „Von“."}
	}
	return p, nil
}

// suffix für Dateinamen: Zeitraum oder Tagesdatum.
func (p period) suffix(today time.Time) string {
	switch {
	case !p.From.IsZero() && !p.To.IsZero():
		return p.From.Format(domain.DateLayout) + "_" + p.To.Format(domain.DateLayout)
	case !p.From.IsZero():
		return "ab-" + p.From.Format(domain.DateLayout)
	case !p.To.IsZero():
		return "bis-" + p.To.Format(domain.DateLayout)
	}
	return today.Format(domain.DateLayout)
}

type pageData struct {
	From, To time.Time
}

func (h handlers) page(w http.ResponseWriter, r *http.Request) {
	p, err := parsePeriod(r)
	if err != nil {
		h.invalid(w, r, err)
		return
	}
	h.render(w, r, http.StatusOK, "", p)
}

func (h handlers) render(w http.ResponseWriter, r *http.Request, status int, msg string, p period) {
	h.pages.Render(w, r, status, "export.html", web.Page{Title: "Export", Nav: web.NavSettings, Error: msg,
		Data: pageData{From: p.From, To: p.To}})
}

func (h handlers) invalid(w http.ResponseWriter, r *http.Request, err error) {
	msg := "Ungültiger Zeitraum."
	var ve domain.ValidationError
	if errors.As(err, &ve) {
		msg = ve.Msg
	}
	h.render(w, r, http.StatusUnprocessableEntity, msg, period{})
}

func (h handlers) serverError(w http.ResponseWriter, r *http.Request, err error) {
	h.d.Log.Error("request", "method", r.Method, "path", r.URL.Path, "err", err)
	h.d.Render.Error(w, r, http.StatusInternalServerError, "Da ist etwas schiefgegangen.")
}

// expenses lädt die nicht gelöschten Ausgaben im Zeitraum, chronologisch.
func (h handlers) expenses(r *http.Request, p period, participantID int64) ([]store.Expense, error) {
	es, err := h.d.Store.ListExpenses(r.Context(), store.ExpenseFilter{From: p.From, To: p.To, ParticipantID: participantID})
	if err != nil {
		return nil, err
	}
	slices.Reverse(es) // ListExpenses liefert neueste zuerst
	return es, nil
}

// load parst den Zeitraum und lädt die Ausgaben; false = Antwort schon geschrieben.
func (h handlers) load(w http.ResponseWriter, r *http.Request, participantID int64) (period, []store.Expense, bool) {
	p, err := parsePeriod(r)
	if err != nil {
		h.invalid(w, r, err)
		return p, nil, false
	}
	es, err := h.expenses(r, p, participantID)
	if err != nil {
		h.serverError(w, r, err)
		return p, nil, false
	}
	return p, es, true
}

// send schreibt einen fertig gepufferten Download.
func send(w http.ResponseWriter, contentType, filename string, body []byte) {
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Disposition", `attachment; filename="`+filename+`"`)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.Write(body)
}

func (h handlers) expensesCSV(w http.ResponseWriter, r *http.Request) {
	p, es, ok := h.load(w, r, 0)
	if !ok {
		return
	}
	people, err := h.d.Store.ListParticipants(r.Context(), true)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	var buf bytes.Buffer
	if err := writeExpensesCSV(&buf, people, es); err != nil {
		h.serverError(w, r, err)
		return
	}
	send(w, "text/csv; charset=utf-8", "teilen-ausgaben-"+p.suffix(h.d.Today())+".csv", buf.Bytes())
}

func (h handlers) expensesJSON(w http.ResponseWriter, r *http.Request) {
	p, es, ok := h.load(w, r, 0)
	if !ok {
		return
	}
	people, err := h.d.Store.ListParticipants(r.Context(), true)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	var buf bytes.Buffer
	if err := writeExpensesJSON(&buf, h.d.Store.GroupName(r.Context()), h.now(), p, people, es); err != nil {
		h.serverError(w, r, err)
		return
	}
	send(w, "application/json; charset=utf-8", "teilen-ausgaben-"+p.suffix(h.d.Today())+".json", buf.Bytes())
}

// postings liefert meine Buchungen (aktuelle Person) im Zeitraum.
func (h handlers) postings(w http.ResponseWriter, r *http.Request) (store.Participant, period, []ynab.Posting, bool) {
	me, _ := web.Me(r.Context())
	p, es, ok := h.load(w, r, me.ID)
	if !ok {
		return me, p, nil, false
	}
	return me, p, ynab.Postings(es, me.ID), true
}

func (h handlers) ynabOFX(w http.ResponseWriter, r *http.Request) {
	me, p, ps, ok := h.postings(w, r)
	if !ok {
		return
	}
	var buf bytes.Buffer
	acct := "TEILEN-" + strconv.FormatInt(me.ID, 10)
	if err := writeOFX(&buf, ps, acct, p.From, p.To, h.now()); err != nil {
		h.serverError(w, r, err)
		return
	}
	send(w, "application/x-ofx", "teilen-ynab-"+p.suffix(h.d.Today())+".ofx", buf.Bytes())
}

func (h handlers) ynabCSV(w http.ResponseWriter, r *http.Request) {
	_, p, ps, ok := h.postings(w, r)
	if !ok {
		return
	}
	var buf bytes.Buffer
	if err := writeYNABCSV(&buf, ps); err != nil {
		h.serverError(w, r, err)
		return
	}
	send(w, "text/csv; charset=utf-8", "teilen-ynab-"+p.suffix(h.d.Today())+".csv", buf.Bytes())
}
