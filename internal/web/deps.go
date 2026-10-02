// Package web enthält das HTTP-Gerüst von teilen: gemeinsame Abhängigkeiten
// (Deps), den Renderer mit gemeinsamem Layout, die Identitäts-Middleware,
// statische Dateien und die Seiten der Kern-App.
//
// Feature-Pakete (fx, recurring, ynab, export, mcp) importieren web für Deps,
// Renderer und Me(ctx) – web importiert umgekehrt keines von ihnen.
package web

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"teilen/internal/config"
	"teilen/internal/domain"
	"teilen/internal/store"
)

// Deps sind die gemeinsamen Abhängigkeiten aller HTTP-Pakete. main baut sie
// einmal und reicht sie als Wert weiter.
type Deps struct {
	Config config.Config
	Store  *store.Store
	Render *Renderer
	Log    *slog.Logger
	// FX liefert Wechselkurse (implementiert von fx.Service). Kann in Tests nil sein.
	FX FXRater
}

// FXRater liefert den Kurs einer Währung für ein Datum (EZB-Format: Einheiten
// Fremdwährung pro 1 EUR; Kurs vom Datum oder letzten Bankarbeitstag davor,
// manuelle Kurse haben Vorrang).
type FXRater interface {
	Rate(ctx context.Context, currency string, date time.Time) (domain.FXRate, error)
}

// Today liefert das heutige Datum in der konfigurierten Zeitzone.
func (d Deps) Today() time.Time {
	loc := d.Config.Location
	if loc == nil {
		loc = time.Local
	}
	return domain.Today(loc)
}

// WriteJSON schreibt v als JSON mit Status status.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
