// Package export bietet Ausgaben als CSV/JSON und die eigenen Anteile als
// OFX/CSV für YNAB zum Herunterladen an.
//
// Stand Phase 0: Stub.
package export

import (
	"embed"
	"net/http"

	"teilen/internal/web"
)

//go:embed templates/*.html
var templatesFS embed.FS

// Register hängt die Routen unter /export an.
func Register(mux *http.ServeMux, d web.Deps) error {
	pages, err := d.Render.Load(templatesFS, "templates/*.html")
	if err != nil {
		return err
	}
	mux.HandleFunc("GET /export", func(w http.ResponseWriter, r *http.Request) {
		pages.Render(w, r, http.StatusOK, "export.html", web.Page{Title: "Export", Nav: web.NavSettings})
	})
	return nil
}
