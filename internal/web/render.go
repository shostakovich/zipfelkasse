package web

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"html/template"
	"io/fs"
	"log/slog"
	"net/http"
	"path"
	"strings"
	"time"

	"teilen/internal/domain"
	"teilen/internal/store"
)

//go:embed templates/layout.html
var layoutFS embed.FS

//go:embed templates/pages/*.html
var pagesFS embed.FS

//go:embed static
var staticFS embed.FS

// Werte für Page.Nav: welcher Tab der Hauptnavigation aktiv ist.
const (
	NavExpenses = "ausgaben"
	NavBalances = "salden"
	NavActivity = "aktivitaet"
	NavSettings = "einstellungen"
)

// Page beschreibt eine zu rendernde Seite.
type Page struct {
	Title string // Seitentitel (ohne Gruppennamen)
	Nav   string // aktiver Tab, siehe Nav*-Konstanten; "" = keiner
	Error string // Fehlermeldung oben auf der Seite (z. B. Validierungsfehler)
	Data  any    // seitenspezifische Daten, im Template als .Data
}

// View ist das, was Templates als Punkt (.) bekommen.
type View struct {
	Page
	Me        *store.Participant // nil, wenn (noch) niemand ausgewählt ist
	GroupName string
	Flash     string // Erfolgsmeldung aus SetFlash, einmalig
	Path      string // aktueller Request-Pfad
}

// Renderer kombiniert das gemeinsame Layout mit Seiten-Templates. Jedes Paket
// lädt seine Templates mit Load aus seinem eigenen embed.FS.
type Renderer struct {
	store  *store.Store
	loc    *time.Location
	log    *slog.Logger
	base   *template.Template
	static map[string]string // Dateiname → Kurz-Hash für Cache-Busting
	pages  *Pages            // Seiten des Pakets web selbst
}

// NewRenderer parst das Layout und die eigenen Seiten. loc ist die Zeitzone
// für die Anzeige von Zeitstempeln.
func NewRenderer(st *store.Store, loc *time.Location, log *slog.Logger) (*Renderer, error) {
	if loc == nil {
		loc = time.Local
	}
	if log == nil {
		log = slog.Default()
	}
	r := &Renderer{store: st, loc: loc, log: log, static: map[string]string{}}
	err := fs.WalkDir(staticFS, "static", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := staticFS.ReadFile(p)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(b)
		r.static[strings.TrimPrefix(p, "static/")] = hex.EncodeToString(sum[:5])
		return nil
	})
	if err != nil {
		return nil, err
	}
	r.base, err = template.New("layout.html").Funcs(r.Funcs()).ParseFS(layoutFS, "templates/layout.html")
	if err != nil {
		return nil, fmt.Errorf("layout: %w", err)
	}
	if r.pages, err = r.Load(pagesFS, "templates/pages/*.html"); err != nil {
		return nil, err
	}
	return r, nil
}

// Funcs sind die Template-Funktionen, die in allen Templates verfügbar sind.
func (r *Renderer) Funcs() template.FuncMap {
	return template.FuncMap{
		"eur":         domain.FormatCents,      // int64 Cent → "1.234,56 €"
		"amountInput": domain.FormatCentsInput, // int64 Cent → "1234,56" (für <input>)
		"money":       domain.FormatMoney,      // (minor, "USD") → "12,34 USD"
		"percent":     domain.FormatBasisPoints,
		"date":        domain.FormatDate, // time.Time → "02.10.2026"
		"isoDate": func(t time.Time) string { // für <input type=date>
			if t.IsZero() {
				return ""
			}
			return t.Format(domain.DateLayout)
		},
		"dateTime": func(t time.Time) string { // Zeitstempel in lokaler Zeit
			if t.IsZero() {
				return ""
			}
			return t.In(r.loc).Format("02.01.2006, 15:04")
		},
		"signClass": func(v int64) string { // für Salden: "positive" / "negative" / ""
			switch {
			case v > 0:
				return "positive"
			case v < 0:
				return "negative"
			}
			return ""
		},
		"static": r.staticURL, // "app.css" → "/static/app.css?v=…"
		"icon": func(name string) template.HTML { // Icon aus static/icons.svg, z. B. {{icon "plus"}}
			return template.HTML(`<svg class="icon" aria-hidden="true"><use href="` +
				template.HTMLEscapeString(r.staticURL("icons.svg")+"#"+name) + `"></use></svg>`)
		},
		"categoryIcon": categoryIcon, // Kategoriename → Icon-Name für {{icon …}}
		"minorInput":   minorInput,   // (minor, "USD") → "12,34" (für <input>)
		"rateInput":    rateInput,    // Kurs 1.0876 → "1,0876" (für <input>)
		"dict": func(kv ...any) (map[string]any, error) { // für Partials mit mehreren Werten
			if len(kv)%2 != 0 {
				return nil, fmt.Errorf("dict: ungerade Anzahl Argumente")
			}
			m := make(map[string]any, len(kv)/2)
			for i := 0; i < len(kv); i += 2 {
				k, ok := kv[i].(string)
				if !ok {
					return nil, fmt.Errorf("dict: schlüssel %v ist kein string", kv[i])
				}
				m[k] = kv[i+1]
			}
			return m, nil
		},
	}
}

func (r *Renderer) staticURL(name string) string {
	u := "/static/" + name
	if h, ok := r.static[name]; ok {
		u += "?v=" + h
	}
	return u
}

// Pages ist ein Satz geladener Seiten eines Pakets.
type Pages struct {
	r   *Renderer
	set map[string]*template.Template
}

// Load lädt Seiten-Templates aus fsys. Jede Datei, die auf eines der Muster
// passt, wird eine Seite (Name = Dateiname, z. B. "ynab.html") und definiert
// mindestens {{define "content"}}; optional "head" (in <head>) und "scripts"
// (vor </body>). Dateien, deren Name mit "_" beginnt, sind Partials und
// stehen allen Seiten dieses Satzes zur Verfügung.
func (r *Renderer) Load(fsys fs.FS, patterns ...string) (*Pages, error) {
	var files []string
	for _, pat := range patterns {
		m, err := fs.Glob(fsys, pat)
		if err != nil {
			return nil, err
		}
		files = append(files, m...)
	}
	var partials, pages []string
	for _, f := range files {
		if strings.HasPrefix(path.Base(f), "_") {
			partials = append(partials, f)
		} else {
			pages = append(pages, f)
		}
	}
	p := &Pages{r: r, set: map[string]*template.Template{}}
	for _, f := range pages {
		t, err := r.base.Clone()
		if err != nil {
			return nil, err
		}
		if len(partials) > 0 {
			if t, err = t.ParseFS(fsys, partials...); err != nil {
				return nil, fmt.Errorf("partials: %w", err)
			}
		}
		if t, err = t.ParseFS(fsys, f); err != nil {
			return nil, fmt.Errorf("template %s: %w", f, err)
		}
		name := path.Base(f)
		if _, dup := p.set[name]; dup {
			return nil, fmt.Errorf("template %s doppelt", name)
		}
		p.set[name] = t
	}
	if len(p.set) == 0 {
		return nil, fmt.Errorf("keine templates für %v", patterns)
	}
	return p, nil
}

// Render rendert die Seite name im Layout und schreibt sie mit status.
// Template-Fehler ergeben einen 500er, ohne halbe Seite.
func (p *Pages) Render(w http.ResponseWriter, req *http.Request, status int, name string, page Page) {
	t, ok := p.set[name]
	if !ok {
		p.r.log.Error("template unbekannt", "name", name)
		http.Error(w, "Interner Fehler", http.StatusInternalServerError)
		return
	}
	v := View{Page: page, GroupName: p.r.store.GroupName(req.Context()), Path: req.URL.Path}
	if me, ok := Me(req.Context()); ok {
		v.Me = &me
	}
	v.Flash = takeFlash(w, req)
	var buf bytes.Buffer
	if err := t.ExecuteTemplate(&buf, "layout", v); err != nil {
		p.r.log.Error("template", "name", name, "err", err)
		http.Error(w, "Interner Fehler", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	w.Write(buf.Bytes())
}

// Page rendert eine Seite des Pakets web selbst.
func (r *Renderer) Page(w http.ResponseWriter, req *http.Request, status int, name string, page Page) {
	r.pages.Render(w, req, status, name, page)
}

// Error rendert eine Fehlerseite im Layout (z. B. 404 „Nicht gefunden“).
func (r *Renderer) Error(w http.ResponseWriter, req *http.Request, status int, msg string) {
	r.Page(w, req, status, "error.html", Page{Title: msg})
}

const flashCookie = "flash"

// SetFlash merkt eine Erfolgsmeldung für die nächste gerenderte Seite
// (Muster POST → Redirect → Meldung). Vor dem Redirect aufrufen.
func SetFlash(w http.ResponseWriter, msg string) {
	http.SetCookie(w, &http.Cookie{
		Name: flashCookie, Value: base64.RawURLEncoding.EncodeToString([]byte(msg)),
		Path: "/", HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: 60,
	})
}

func takeFlash(w http.ResponseWriter, req *http.Request) string {
	c, err := req.Cookie(flashCookie)
	if err != nil {
		return ""
	}
	http.SetCookie(w, &http.Cookie{Name: flashCookie, Path: "/", MaxAge: -1})
	b, err := base64.RawURLEncoding.DecodeString(c.Value)
	if err != nil {
		return ""
	}
	return string(b)
}
