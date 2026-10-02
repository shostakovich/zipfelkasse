// Package recurring verwaltet wiederkehrende Ausgaben und legt fällige
// Instanzen an (beim Start und stündlich).
//
// Stand Phase 0: Stub.
package recurring

import (
	"context"
	"embed"
	"net/http"
	"time"

	"teilen/internal/web"
)

//go:embed templates/*.html
var templatesFS embed.FS

// Service erzeugt fällige Instanzen wiederkehrender Ausgaben.
type Service struct {
	d     web.Deps
	pages *web.Pages
}

// New erzeugt den Service.
func New(d web.Deps) (*Service, error) {
	pages, err := d.Render.Load(templatesFS, "templates/*.html")
	if err != nil {
		return nil, err
	}
	return &Service{d: d, pages: pages}, nil
}

// Register hängt die Routen unter /einstellungen/wiederkehrend an.
func (s *Service) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /einstellungen/wiederkehrend", func(w http.ResponseWriter, r *http.Request) {
		s.pages.Render(w, r, http.StatusOK, "wiederkehrend.html", web.Page{Title: "Wiederkehrende Ausgaben", Nav: web.NavSettings})
	})
}

// Materialize legt alle bis einschließlich today fälligen Instanzen an und
// liefert deren Anzahl. Mehrfacher Aufruf erzeugt keine Duplikate.
func (s *Service) Materialize(ctx context.Context, today time.Time) (int, error) {
	return 0, nil
}

// Run ruft Materialize sofort und danach stündlich auf. Blockiert, bis ctx
// beendet ist (main startet Run in einer eigenen Goroutine).
func (s *Service) Run(ctx context.Context) {
	tick := time.NewTicker(time.Hour)
	defer tick.Stop()
	for {
		if n, err := s.Materialize(ctx, s.d.Today()); err != nil {
			s.d.Log.Error("wiederkehrende Ausgaben", "err", err)
		} else if n > 0 {
			s.d.Log.Info("wiederkehrende Ausgaben angelegt", "anzahl", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
