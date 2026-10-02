package web

import (
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"strconv"
	"strings"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
)

// Register adds the routes of package web to the mux.
//
// Always specify route patterns with a method ("GET /path"), no catch-all
// patterns like "/" or "GET /": they collide with patterns of other packages.
func Register(mux *http.ServeMux, d Deps) {
	h := handlers{d}
	static, _ := fs.Sub(staticFS, "static")
	mux.Handle("GET /static/", cacheStatic(http.StripPrefix("/static/", http.FileServerFS(static))))
	mux.HandleFunc("GET /healthz", h.healthz)
	mux.HandleFunc("GET /manifest.webmanifest", h.manifest)
	mux.HandleFunc("GET /sw.js", h.serviceWorker)
	mux.HandleFunc("GET /favicon.ico", h.favicon)

	mux.HandleFunc("GET /wer", h.whoPage)
	mux.HandleFunc("POST /wer", h.whoSelect)
	mux.HandleFunc("POST /wer/neu", h.whoCreate)

	mux.HandleFunc("GET /{$}", h.home)
	mux.HandleFunc("GET /ausgaben/neu", h.expenseNew)
	mux.HandleFunc("POST /ausgaben/neu", h.expenseCreate)
	mux.HandleFunc("GET /ausgaben/{id}", h.expenseShow)
	mux.HandleFunc("POST /ausgaben/{id}", h.expenseUpdate)
	mux.HandleFunc("POST /ausgaben/{id}/loeschen", h.expenseDelete)

	mux.HandleFunc("GET /salden", h.balances)
	mux.HandleFunc("GET /aktivitaet", h.activity)

	mux.HandleFunc("GET /einstellungen", h.settings)
	mux.HandleFunc("POST /einstellungen", h.settingsSave)
	mux.HandleFunc("GET /einstellungen/teilnehmer", h.participants)
	mux.HandleFunc("POST /einstellungen/teilnehmer", h.participantCreate)
	mux.HandleFunc("POST /einstellungen/teilnehmer/{id}", h.participantRename)
	mux.HandleFunc("POST /einstellungen/teilnehmer/{id}/archivieren", h.participantArchive(true))
	mux.HandleFunc("POST /einstellungen/teilnehmer/{id}/reaktivieren", h.participantArchive(false))
	mux.HandleFunc("GET /einstellungen/kategorien", h.categories)
	mux.HandleFunc("POST /einstellungen/kategorien", h.categoryCreate)
	mux.HandleFunc("POST /einstellungen/kategorien/{id}", h.categoryRename)
	mux.HandleFunc("POST /einstellungen/kategorien/{id}/archivieren", h.categoryArchive(true))
	mux.HandleFunc("POST /einstellungen/kategorien/{id}/reaktivieren", h.categoryArchive(false))
	mux.HandleFunc("POST /einstellungen/kategorien/{id}/hoch", h.categoryMove(true))
	mux.HandleFunc("POST /einstellungen/kategorien/{id}/runter", h.categoryMove(false))
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
	Name         string // "new person" input after an error
}

func (h handlers) renderWho(w http.ResponseWriter, r *http.Request, status int, data whoData, errMsg string) {
	ps, err := h.d.Store.ListParticipants(r.Context(), false)
	if err != nil {
		h.d.ServerError(w, r, err)
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
		h.d.ServerError(w, r, err)
		return
	}
	// The actor is the new person themselves (no cookie yet, hence no Me).
	p, _ := h.d.Store.GetParticipant(r.Context(), id)
	if err := h.d.Store.AddActivity(r.Context(), id, actionSettingsUpdated, 0,
		store.ActivityDetails{Text: fmt.Sprintf("Person „%s“ hinzugefügt", p.Name)}); err != nil {
		h.d.Log.Error("activity", "err", err)
	}
	SetIdentity(w, r, id)
	SetFlash(w, "Willkommen!")
	http.Redirect(w, r, ret, http.StatusSeeOther)
}

func (h handlers) notFound(w http.ResponseWriter, r *http.Request, msg string) {
	h.d.Render.Error(w, r, http.StatusNotFound, msg)
}

// validationMsg returns the message of a domain.ValidationError.
func validationMsg(err error) (string, bool) {
	var ve domain.ValidationError
	if errors.As(err, &ve) {
		return ve.Msg, true
	}
	return "", false
}

// pathID reads the path parameter {id}; invalid → 0.
func pathID(r *http.Request) int64 {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		return 0
	}
	return id
}

// formID reads an ID from a form or query value; invalid → 0.
func formID(v string) int64 {
	id, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
	if err != nil || id <= 0 {
		return 0
	}
	return id
}

// me returns the current person (always set behind the middleware).
func me(r *http.Request) store.Participant {
	p, _ := Me(r.Context())
	return p
}
