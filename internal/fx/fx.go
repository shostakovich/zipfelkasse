// Package fx liefert Wechselkurse (EZB-Referenzkurse mit Cache in SQLite,
// manuelle Kurse) und den Endpunkt GET /api/kurs für das Ausgabenformular.
//
// Stand Phase 0: Stub. Nur EUR liefert einen Kurs.
package fx

import (
	"context"
	"embed"
	"errors"
	"net/http"
	"strings"
	"time"

	"teilen/internal/domain"
	"teilen/internal/web"
)

//go:embed templates/*.html
var templatesFS embed.FS

// ErrNotImplemented: (noch) kein Kurs verfügbar.
var ErrNotImplemented = errors.New("Wechselkurse sind noch nicht verfügbar.")

// Service implementiert web.FXRater.
type Service struct {
	d     web.Deps
	pages *web.Pages
}

var _ web.FXRater = (*Service)(nil)

// New erzeugt den Service. main setzt ihn danach als Deps.FX.
func New(d web.Deps) (*Service, error) {
	pages, err := d.Render.Load(templatesFS, "templates/*.html")
	if err != nil {
		return nil, err
	}
	return &Service{d: d, pages: pages}, nil
}

// Rate liefert den Kurs für currency am Datum date (EZB-Format: Einheiten
// Fremdwährung pro 1 EUR).
func (s *Service) Rate(ctx context.Context, currency string, date time.Time) (domain.FXRate, error) {
	currency = strings.ToUpper(strings.TrimSpace(currency))
	if currency == "EUR" {
		return domain.FXRate{Currency: "EUR", Date: domain.DateOf(date), Rate: 1, Source: domain.FXSourceFixed}, nil
	}
	return domain.FXRate{}, ErrNotImplemented
}

// Register hängt die Routen an:
//
//	GET /api/kurs?waehrung=USD&datum=2026-10-01 → RateResponse bzw. {"error": "..."}
//	GET /einstellungen/kurse                     → Seite für manuelle Kurse
func (s *Service) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/kurs", s.handleRate)
	mux.HandleFunc("GET /einstellungen/kurse", func(w http.ResponseWriter, r *http.Request) {
		s.pages.Render(w, r, http.StatusOK, "kurse.html", web.Page{Title: "Wechselkurse", Nav: web.NavSettings})
	})
}

// Run ist für Hintergrundarbeit vorgesehen (z. B. täglicher Abruf der
// EZB-Kurse). Blockiert, bis ctx beendet ist (main startet Run in einer
// eigenen Goroutine). Stub: wartet nur.
func (s *Service) Run(ctx context.Context) {
	<-ctx.Done()
}

// RateResponse ist die JSON-Antwort von GET /api/kurs.
type RateResponse struct {
	Currency string  `json:"currency"`
	Date     string  `json:"date"` // Tag, für den der Kurs gilt (YYYY-MM-DD)
	Rate     float64 `json:"rate"` // Fremdwährung pro 1 EUR
	Source   string  `json:"source"`
}

func (s *Service) handleRate(w http.ResponseWriter, r *http.Request) {
	date := s.d.Today()
	if v := r.URL.Query().Get("datum"); v != "" {
		var err error
		if date, err = domain.ParseDate(v); err != nil {
			web.WriteJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
	}
	rate, err := s.Rate(r.Context(), r.URL.Query().Get("waehrung"), date)
	if err != nil {
		web.WriteJSON(w, http.StatusNotImplemented, map[string]string{"error": err.Error()})
		return
	}
	web.WriteJSON(w, http.StatusOK, RateResponse{
		Currency: rate.Currency, Date: rate.Date.Format(domain.DateLayout), Rate: rate.Rate, Source: rate.Source,
	})
}
