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

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
)

//go:embed templates/layout.html
var layoutFS embed.FS

//go:embed templates/pages/*.html
var pagesFS embed.FS

//go:embed static
var staticFS embed.FS

// Values for Page.Nav: which tab of the main navigation is active.
const (
	NavExpenses = "ausgaben"
	NavBalances = "salden"
	NavActivity = "aktivitaet"
	NavSettings = "einstellungen"
)

// Page describes a page to render.
type Page struct {
	Title string // page title (without the group name)
	Nav   string // active tab, see the Nav* constants; "" = none
	Error string // error message at the top of the page (e.g. validation error)
	Data  any    // page-specific data, available as .Data in the template
}

// View is what templates get as dot (.).
type View struct {
	Page
	Me        *store.Participant // nil if nobody has been selected (yet)
	GroupName string
	Flash     string // success message from SetFlash, shown once
	Path      string // current request path
}

// Renderer combines the shared layout with page templates. Each package
// loads its templates with Load from its own embed.FS.
type Renderer struct {
	store  *store.Store
	loc    *time.Location
	log    *slog.Logger
	base   *template.Template
	static map[string]string // file name → short hash for cache busting
	pages  *Pages            // pages of package web itself
}

// NewRenderer parses the layout and its own pages. loc is the time zone for
// displaying timestamps.
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

// Funcs are the template functions available in all templates.
func (r *Renderer) Funcs() template.FuncMap {
	return template.FuncMap{
		"eur":         domain.FormatCents,      // int64 cents → "1.234,56 €"
		"amountInput": domain.FormatCentsInput, // int64 cents → "1234,56" (for <input>)
		"money":       domain.FormatMoney,      // (minor, "USD") → "12,34 USD"
		"percent":     domain.FormatBasisPoints,
		"date":        domain.FormatDate, // time.Time → "02.10.2026"
		"isoDate": func(t time.Time) string { // for <input type=date>
			if t.IsZero() {
				return ""
			}
			return t.Format(domain.DateLayout)
		},
		"dateTime": func(t time.Time) string { // timestamp in local time
			if t.IsZero() {
				return ""
			}
			return t.In(r.loc).Format("02.01.2006, 15:04")
		},
		"signClass": func(v int64) string { // for balances: "positive" / "negative" / ""
			switch {
			case v > 0:
				return "positive"
			case v < 0:
				return "negative"
			}
			return ""
		},
		"static": r.staticURL, // "app.css" → "/static/app.css?v=…"
		"icon": func(name string) template.HTML { // icon from static/icons.svg, e.g. {{icon "plus"}}
			return template.HTML(`<svg class="icon" aria-hidden="true"><use href="` +
				template.HTMLEscapeString(r.staticURL("icons.svg")+"#"+name) + `"></use></svg>`)
		},
		"categoryIcon": categoryIcon, // category name → icon name for {{icon …}}
		"minorInput":   minorInput,   // (minor, "USD") → "12,34" (for <input>)
		"rateInput":    rateInput,    // rate 1.0876 → "1,0876" (for <input>)
		"dict": func(kv ...any) (map[string]any, error) { // for partials with several values
			if len(kv)%2 != 0 {
				return nil, fmt.Errorf("dict: odd number of arguments")
			}
			m := make(map[string]any, len(kv)/2)
			for i := 0; i < len(kv); i += 2 {
				k, ok := kv[i].(string)
				if !ok {
					return nil, fmt.Errorf("dict: key %v is not a string", kv[i])
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

// Pages is a set of loaded pages of a package.
type Pages struct {
	r   *Renderer
	set map[string]*template.Template
}

// Load loads page templates from fsys. Each file matching one of the patterns
// becomes a page (name = file name, e.g. "ynab.html") and defines at least
// {{define "content"}}; optionally "head" (in <head>) and "scripts" (before
// </body>). Files whose name starts with "_" are partials and are available
// to all pages of this set.
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
			return nil, fmt.Errorf("duplicate template %s", name)
		}
		p.set[name] = t
	}
	if len(p.set) == 0 {
		return nil, fmt.Errorf("no templates for %v", patterns)
	}
	return p, nil
}

// Render renders the page name in the layout and writes it with status.
// Template errors result in a 500, without a half-written page.
func (p *Pages) Render(w http.ResponseWriter, req *http.Request, status int, name string, page Page) {
	t, ok := p.set[name]
	if !ok {
		p.r.log.Error("unknown template", "name", name)
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

// Page renders a page of package web itself.
func (r *Renderer) Page(w http.ResponseWriter, req *http.Request, status int, name string, page Page) {
	r.pages.Render(w, req, status, name, page)
}

// Error renders an error page in the layout (e.g. 404 "Nicht gefunden").
func (r *Renderer) Error(w http.ResponseWriter, req *http.Request, status int, msg string) {
	r.Page(w, req, status, "error.html", Page{Title: msg})
}

const flashCookie = "flash"

// SetFlash stores a success message for the next rendered page (pattern
// POST → redirect → message). Call it before the redirect.
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
