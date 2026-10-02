package web

import (
	"errors"
	"io/fs"
	"net/http"
	"strconv"
	"time"

	"teilen/internal/domain"
	"teilen/internal/store"
)

// Register hängt die Routen des Pakets web an den Mux.
//
// Routen-Muster immer mit Methode angeben ("GET /pfad"), keine Catch-all-
// Muster wie "/" oder "GET /" – die kollidieren mit Mustern anderer Pakete.
func Register(mux *http.ServeMux, d Deps) {
	h := handlers{d}
	static, _ := fs.Sub(staticFS, "static")
	mux.Handle("GET /static/", cacheStatic(http.StripPrefix("/static/", http.FileServerFS(static))))
	mux.HandleFunc("GET /healthz", h.healthz)

	mux.HandleFunc("GET /wer", h.whoPage)
	mux.HandleFunc("POST /wer", h.whoSelect)
	mux.HandleFunc("POST /wer/neu", h.whoCreate)

	// Platzhalter – werden von Agent A ausgebaut.
	mux.HandleFunc("GET /{$}", h.home)
	mux.HandleFunc("GET /salden", h.placeholder("balances.html", "Salden", NavBalances))
	mux.HandleFunc("GET /aktivitaet", h.placeholder("activity.html", "Aktivität", NavActivity))
	mux.HandleFunc("GET /einstellungen", h.placeholder("settings.html", "Einstellungen", NavSettings))
}

type handlers struct{ d Deps }

func cacheStatic(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("v") != "" {
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		} else {
			w.Header().Set("Cache-Control", "public, max-age=300")
		}
		next.ServeHTTP(w, r)
	})
}

func (h handlers) healthz(w http.ResponseWriter, r *http.Request) {
	if err := h.d.Store.Ping(r.Context()); err != nil {
		http.Error(w, "db: "+err.Error(), http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte("ok\n"))
}

type whoData struct {
	Participants []store.Participant
	Return       string
	Name         string // Eingabe „Neue Person“ nach Fehler
}

func (h handlers) renderWho(w http.ResponseWriter, r *http.Request, status int, data whoData, errMsg string) {
	ps, err := h.d.Store.ListParticipants(r.Context(), false)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	data.Participants = ps
	h.d.Render.Page(w, r, status, "who.html", Page{Title: "Wer bist du?", Error: errMsg, Data: data})
}

func (h handlers) whoPage(w http.ResponseWriter, r *http.Request) {
	h.renderWho(w, r, http.StatusOK, whoData{Return: safeReturn(r.URL.Query().Get("zurueck"))}, "")
}

func (h handlers) whoSelect(w http.ResponseWriter, r *http.Request) {
	ret := safeReturn(r.FormValue("zurueck"))
	id, _ := strconv.ParseInt(r.FormValue("id"), 10, 64)
	p, err := h.d.Store.GetParticipant(r.Context(), id)
	if err != nil || p.Archived() {
		h.renderWho(w, r, http.StatusUnprocessableEntity, whoData{Return: ret}, "Diese Person gibt es nicht (mehr).")
		return
	}
	SetIdentity(w, r, p.ID)
	http.Redirect(w, r, ret, http.StatusSeeOther)
}

func (h handlers) whoCreate(w http.ResponseWriter, r *http.Request) {
	ret := safeReturn(r.FormValue("zurueck"))
	name := r.FormValue("name")
	id, err := h.d.Store.CreateParticipant(r.Context(), name)
	var ve domain.ValidationError
	if errors.As(err, &ve) {
		h.renderWho(w, r, http.StatusUnprocessableEntity, whoData{Return: ret, Name: name}, ve.Msg)
		return
	}
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	SetIdentity(w, r, id)
	SetFlash(w, "Willkommen!")
	http.Redirect(w, r, ret, http.StatusSeeOther)
}

type homeData struct {
	Balance int64
	Today   time.Time
}

func (h handlers) home(w http.ResponseWriter, r *http.Request) {
	me, _ := Me(r.Context())
	balances, err := h.d.Store.Balances(r.Context())
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.d.Render.Page(w, r, http.StatusOK, "home.html", Page{
		Title: "Ausgaben", Nav: NavExpenses,
		Data: homeData{Balance: balances[me.ID], Today: h.d.Today()},
	})
}

func (h handlers) placeholder(tmpl, title, nav string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		h.d.Render.Page(w, r, http.StatusOK, tmpl, Page{Title: title, Nav: nav})
	}
}

func (h handlers) serverError(w http.ResponseWriter, r *http.Request, err error) {
	h.d.Log.Error("request", "method", r.Method, "path", r.URL.Path, "err", err)
	h.d.Render.Error(w, r, http.StatusInternalServerError, "Da ist etwas schiefgegangen.")
}
