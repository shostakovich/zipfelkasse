// Package ynab synchronisiert den eigenen Anteil jeder Ausgabe in ein
// YNAB-Verrechnungskonto „Geteilt“ (pro Person mit eigenem Token).
//
// Stand Phase 0: Stub. Der Change-Hook ist schon verdrahtet.
package ynab

import (
	"context"
	"embed"
	"net/http"

	"teilen/internal/store"
	"teilen/internal/web"
)

//go:embed templates/*.html
var templatesFS embed.FS

// Service ist der Sync-Worker plus Einstellungsseiten.
type Service struct {
	d     web.Deps
	pages *web.Pages
	queue chan int64
}

// New erzeugt den Service und registriert Trigger am Store-Change-Hook.
func New(d web.Deps) (*Service, error) {
	pages, err := d.Render.Load(templatesFS, "templates/*.html")
	if err != nil {
		return nil, err
	}
	s := &Service{d: d, pages: pages, queue: make(chan int64, 256)}
	d.Store.OnExpenseChange(func(c store.ExpenseChange) { s.Trigger(c.ExpenseID) })
	return s, nil
}

// Register hängt die Routen unter /einstellungen/ynab an.
func (s *Service) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /einstellungen/ynab", func(w http.ResponseWriter, r *http.Request) {
		s.pages.Render(w, r, http.StatusOK, "ynab.html", web.Page{Title: "YNAB", Nav: web.NavSettings})
	})
}

// Trigger merkt eine Ausgabe zum Synchronisieren vor. Blockiert nie.
func (s *Service) Trigger(expenseID int64) {
	select {
	case s.queue <- expenseID:
	default:
		s.d.Log.Warn("ynab: queue voll, sync verworfen", "expense", expenseID)
	}
}

// Run arbeitet die Queue ab, bis ctx beendet ist (eigene Goroutine).
func (s *Service) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case id := <-s.queue:
			s.d.Log.Debug("ynab: sync noch nicht implementiert", "expense", id)
		}
	}
}
