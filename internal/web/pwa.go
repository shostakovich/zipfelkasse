package web

//go:generate go run gen_icons.go

import (
	"encoding/json"
	"net/http"
)

// themeColor ist die Primärfarbe (Spliit-Grün, --primary im hellen Modus).
const themeColor = "#047756"

type manifestIcon struct {
	Src     string `json:"src"`
	Sizes   string `json:"sizes"`
	Type    string `json:"type"`
	Purpose string `json:"purpose,omitempty"`
}

// manifest liefert das Web-App-Manifest (öffentlich, damit die Installation
// auch vor der Personenauswahl klappt). Der Name ist der Gruppenname.
func (h handlers) manifest(w http.ResponseWriter, r *http.Request) {
	name := h.d.Store.GroupName(r.Context())
	m := map[string]any{
		"name":             name,
		"short_name":       name,
		"description":      "Gemeinsame Ausgaben teilen",
		"lang":             "de",
		"dir":              "ltr",
		"id":               "/",
		"start_url":        "/",
		"scope":            "/",
		"display":          "standalone",
		"background_color": "#ffffff",
		"theme_color":      themeColor,
		"icons": []manifestIcon{
			{Src: h.d.Render.staticURL("icons/icon-192.png"), Sizes: "192x192", Type: "image/png", Purpose: "any"},
			{Src: h.d.Render.staticURL("icons/icon-512.png"), Sizes: "512x512", Type: "image/png", Purpose: "any"},
			{Src: h.d.Render.staticURL("icons/maskable-512.png"), Sizes: "512x512", Type: "image/png", Purpose: "maskable"},
		},
		"shortcuts": []map[string]string{
			{"name": "Ausgabe hinzufügen", "url": "/ausgaben/neu"},
			{"name": "Salden", "url": "/salden"},
		},
	}
	w.Header().Set("Content-Type", "application/manifest+json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	json.NewEncoder(w).Encode(m)
}

// serviceWorker liefert /sw.js aus static/ (Scope „/“ braucht die Datei an
// der Wurzel). Kein Caching, damit Änderungen sofort greifen.
func (h handlers) serviceWorker(w http.ResponseWriter, r *http.Request) {
	b, err := staticFS.ReadFile("static/sw.js")
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Write(b)
}

func (h handlers) favicon(w http.ResponseWriter, r *http.Request) {
	b, err := staticFS.ReadFile("static/icons/favicon-32.png")
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	w.Write(b)
}
