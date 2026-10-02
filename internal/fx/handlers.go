package fx

import (
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

// Register adds the routes:
//
//	GET  /api/kurs?waehrung=USD&datum=2026-10-01 → RateResponse or {"error": "..."}
//	GET  /einstellungen/kurse                     → manual rates, cache, refresh
//	POST /einstellungen/kurse                     → save a manual rate
//	POST /einstellungen/kurse/loeschen            → delete a manual rate
//	POST /einstellungen/kurse/aktualisieren       → load ECB rates now
func (s *Service) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/kurs", s.handleRate)
	mux.HandleFunc("GET /einstellungen/kurse", s.handlePage)
	mux.HandleFunc("POST /einstellungen/kurse", s.handleSaveManual)
	mux.HandleFunc("POST /einstellungen/kurse/loeschen", s.handleDeleteManual)
	mux.HandleFunc("POST /einstellungen/kurse/aktualisieren", s.handleRefresh)
}

// RateResponse is the JSON response of GET /api/kurs.
type RateResponse struct {
	Currency string  `json:"currency"`
	Date     string  `json:"date"` // day the rate applies to (YYYY-MM-DD)
	Rate     float64 `json:"rate"` // foreign currency per 1 EUR
	Source   string  `json:"source"`
}

func jsonError(w http.ResponseWriter, status int, msg string) {
	web.WriteJSON(w, status, map[string]string{"error": msg})
}

func (s *Service) handleRate(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	cur := strings.ToUpper(strings.TrimSpace(q.Get("waehrung")))
	switch {
	case cur == "":
		jsonError(w, http.StatusBadRequest, "Bitte eine Währung angeben.")
		return
	case cur != "EUR" && !store.ValidCurrencyCode(cur):
		jsonError(w, http.StatusBadRequest, "Ungültige Währung „"+q.Get("waehrung")+"“.")
		return
	}
	date := s.today()
	if v := q.Get("datum"); v != "" {
		var err error
		if date, err = domain.ParseDate(v); err != nil {
			jsonError(w, http.StatusBadRequest, err.Error())
			return
		}
	}
	rate, err := s.Rate(r.Context(), cur, date)
	if err != nil {
		var ve domain.ValidationError
		var fe *FetchError
		switch {
		case errors.As(err, &ve):
			jsonError(w, http.StatusUnprocessableEntity, ve.Msg)
		case errors.As(err, &fe):
			jsonError(w, http.StatusBadGateway, fe.Error())
		default:
			s.d.Log.Error("rate", "currency", cur, "err", err)
			jsonError(w, http.StatusInternalServerError, "Der Kurs konnte nicht ermittelt werden.")
		}
		return
	}
	web.WriteJSON(w, http.StatusOK, RateResponse{
		Currency: rate.Currency, Date: rate.Date.Format(domain.DateLayout), Rate: rate.Rate, Source: rate.Source,
	})
}

// --- Page /einstellungen/kurse ----------------------------------------------

type rateRow struct {
	Currency string
	Date     time.Time
	Rate     string // German format, e.g. "1,1298"
	Source   string // display label: "EZB", "manuell", …
	Title    string // for used rates: title of the expense
	ID       int64  // for used rates: the expense
}

type manualForm struct {
	Currency, Date, Rate string
}

type pageData struct {
	Manual     []rateRow
	Latest     []rateRow
	Used       []rateRow
	Stats      store.FXCacheStats
	Currencies []string
	Form       manualForm
}

func formatRate(f float64) string {
	return strings.Replace(strconv.FormatFloat(f, 'f', -1, 64), ".", ",", 1)
}

func sourceLabel(src string) string {
	switch src {
	case domain.FXSourceECB:
		return "EZB"
	case domain.FXSourceManual:
		return "manuell"
	case domain.FXSourceFixed:
		return "fest"
	case "":
		return "–"
	}
	return src
}

func rows(rates []domain.FXRate) []rateRow {
	out := make([]rateRow, len(rates))
	for i, r := range rates {
		out[i] = rateRow{Currency: r.Currency, Date: r.Date, Rate: formatRate(r.Rate), Source: sourceLabel(r.Source)}
	}
	return out
}

func (s *Service) renderPage(w http.ResponseWriter, r *http.Request, status int, form manualForm, errMsg string) {
	ctx := r.Context()
	st := s.d.Store
	data := pageData{Form: form}
	if data.Form.Date == "" {
		data.Form.Date = s.today().Format(domain.DateLayout)
	}
	manual, err := st.ListManualFXRates(ctx)
	if err == nil {
		data.Manual = rows(manual)
		var latest []domain.FXRate
		if latest, err = st.LatestECBRates(ctx); err == nil {
			data.Latest = rows(latest)
		}
	}
	if err == nil {
		data.Stats, err = st.ECBCacheStats(ctx)
	}
	if err == nil {
		var used []store.UsedFXRate
		if used, err = st.RecentUsedFXRates(ctx, 10); err == nil {
			for _, u := range used {
				data.Used = append(data.Used, rateRow{Currency: u.Currency, Date: u.Date, Rate: formatRate(u.Rate),
					Source: sourceLabel(u.Source), Title: u.Title, ID: u.ExpenseID})
			}
		}
	}
	if err == nil {
		data.Currencies, err = st.ListFXCurrencies(ctx)
	}
	if err != nil {
		s.serverError(w, r, err)
		return
	}
	s.pages.Render(w, r, status, "kurse.html", web.Page{Title: "Wechselkurse", Nav: web.NavSettings, Error: errMsg, Data: data})
}

func (s *Service) serverError(w http.ResponseWriter, r *http.Request, err error) {
	s.d.Log.Error("request", "method", r.Method, "path", r.URL.Path, "err", err)
	s.d.Render.Error(w, r, http.StatusInternalServerError, "Da ist etwas schiefgegangen.")
}

func (s *Service) handlePage(w http.ResponseWriter, r *http.Request) {
	s.renderPage(w, r, http.StatusOK, manualForm{}, "")
}

func (s *Service) handleSaveManual(w http.ResponseWriter, r *http.Request) {
	form := manualForm{
		Currency: strings.ToUpper(strings.TrimSpace(r.FormValue("waehrung"))),
		Date:     strings.TrimSpace(r.FormValue("datum")),
		Rate:     strings.TrimSpace(r.FormValue("kurs")),
	}
	var logText string
	err := func() error {
		date, err := domain.ParseDate(form.Date)
		if err != nil {
			return err
		}
		rate, err := domain.ParseRate(form.Rate)
		if err != nil {
			return err
		}
		logText = fmt.Sprintf("Manueller Kurs für %s ab %s gespeichert: 1 € = %s %s",
			form.Currency, domain.FormatDate(date), formatRate(rate), form.Currency)
		return s.d.Store.SetManualFXRate(r.Context(), form.Currency, date, rate)
	}()
	var ve domain.ValidationError
	if errors.As(err, &ve) {
		s.renderPage(w, r, http.StatusUnprocessableEntity, form, ve.Msg)
		return
	}
	if err != nil {
		s.serverError(w, r, err)
		return
	}
	s.d.LogSettings(r, logText)
	web.SetFlash(w, "Kurs für "+form.Currency+" gespeichert.")
	http.Redirect(w, r, "/einstellungen/kurse", http.StatusSeeOther)
}

func (s *Service) handleDeleteManual(w http.ResponseWriter, r *http.Request) {
	cur := strings.ToUpper(strings.TrimSpace(r.FormValue("waehrung")))
	date, err := domain.ParseDate(r.FormValue("datum"))
	if err == nil {
		err = s.d.Store.DeleteManualFXRate(r.Context(), cur, date)
	}
	var ve domain.ValidationError
	switch {
	case errors.Is(err, store.ErrNotFound), errors.As(err, &ve):
		s.renderPage(w, r, http.StatusNotFound, manualForm{}, "Diesen manuellen Kurs gibt es nicht (mehr).")
		return
	case err != nil:
		s.serverError(w, r, err)
		return
	}
	s.d.LogSettings(r, fmt.Sprintf("Manueller Kurs für %s ab %s gelöscht", cur, domain.FormatDate(date)))
	web.SetFlash(w, "Manueller Kurs für "+cur+" gelöscht.")
	http.Redirect(w, r, "/einstellungen/kurse", http.StatusSeeOther)
}

func (s *Service) handleRefresh(w http.ResponseWriter, r *http.Request) {
	latest, err := s.Refresh(r.Context())
	var fe *FetchError
	switch {
	case errors.As(err, &fe):
		s.renderPage(w, r, http.StatusBadGateway, manualForm{}, fe.Error())
		return
	case err != nil:
		s.serverError(w, r, err)
		return
	}
	web.SetFlash(w, "EZB-Kurse aktualisiert (Stand "+domain.FormatDate(latest)+").")
	http.Redirect(w, r, "/einstellungen/kurse", http.StatusSeeOther)
}
