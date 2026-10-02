// Package web contains the HTTP scaffolding of Zipfelkasse: shared
// dependencies (Deps), the renderer with the shared layout, the identity
// middleware, static files and the pages of the core app.
//
// Feature packages (fx, recurring, ynab, export, mcp) import web for Deps,
// Renderer and Me(ctx); web in turn imports none of them.
package web

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/config"
	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
)

// Deps are the shared dependencies of all HTTP packages. main builds them
// once and passes them on by value.
type Deps struct {
	Config config.Config
	Store  *store.Store
	Render *Renderer
	Log    *slog.Logger
	// FX provides exchange rates (implemented by fx.Service). May be nil in tests.
	FX FXRater
}

// FXRater returns the rate of a currency for a date (ECB format: units of
// foreign currency per 1 EUR; the rate of that date or of the last business
// day before it, manual rates take precedence).
type FXRater interface {
	Rate(ctx context.Context, currency string, date time.Time) (domain.FXRate, error)
}

// Today returns today's date in the configured time zone.
func (d Deps) Today() time.Time {
	loc := d.Config.Location
	if loc == nil {
		loc = time.Local
	}
	return domain.Today(loc)
}

// ServerError logs err and renders the error page with status 500. The path
// is logged without the MCP secret (see logPath).
func (d Deps) ServerError(w http.ResponseWriter, r *http.Request, err error) {
	d.Log.Error("request", "method", r.Method, "path", logPath(r.URL.Path), "err", err)
	d.Render.Error(w, r, http.StatusInternalServerError, "Da ist etwas schiefgegangen.")
}

// WriteJSON writes v as JSON with the given status.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
