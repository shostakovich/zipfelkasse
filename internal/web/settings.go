package web

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"

	"github.com/shostakovich/zipfelkasse/internal/store"
)

// --- Overview and group name -----------------------------------------------

type settingsData struct {
	GroupName string // input (as entered, after an error)
}

func (h handlers) settings(w http.ResponseWriter, r *http.Request) {
	h.renderSettings(w, r, http.StatusOK, h.d.Store.GroupName(r.Context()), "")
}

func (h handlers) renderSettings(w http.ResponseWriter, r *http.Request, status int, name, errMsg string) {
	h.d.Render.Page(w, r, status, "settings.html", Page{
		Title: "Einstellungen", Nav: NavSettings, Error: errMsg, Data: settingsData{GroupName: name},
	})
}

func (h handlers) settingsSave(w http.ResponseWriter, r *http.Request) {
	name := r.FormValue("gruppenname")
	err := h.d.Store.SetGroupName(r.Context(), me(r).ID, name)
	if msg, ok := validationMsg(err); ok {
		h.renderSettings(w, r, http.StatusUnprocessableEntity, name, msg)
		return
	}
	if err != nil {
		h.d.ServerError(w, r, err)
		return
	}
	SetFlash(w, "Gespeichert.")
	http.Redirect(w, r, "/einstellungen", http.StatusSeeOther)
}

// --- Participants ------------------------------------------------------------

type participantsData struct {
	Active, Archived []participantRow
	Name             string // "new person" input after an error
}

type participantRow struct {
	store.Participant
	Balance  int64
	Expenses int
}

func (h handlers) participants(w http.ResponseWriter, r *http.Request) {
	h.renderParticipants(w, r, http.StatusOK, "", "")
}

func (h handlers) renderParticipants(w http.ResponseWriter, r *http.Request, status int, name, errMsg string) {
	ctx := r.Context()
	people, err := h.d.Store.ListParticipants(ctx, true)
	if err != nil {
		h.d.ServerError(w, r, err)
		return
	}
	balances, err := h.d.Store.Balances(ctx)
	if err != nil {
		h.d.ServerError(w, r, err)
		return
	}
	counts, err := h.d.Store.ExpenseCountByParticipant(ctx)
	if err != nil {
		h.d.ServerError(w, r, err)
		return
	}
	data := participantsData{Name: name}
	for _, p := range people {
		row := participantRow{Participant: p, Balance: balances[p.ID], Expenses: counts[p.ID]}
		if p.Archived() {
			data.Archived = append(data.Archived, row)
		} else {
			data.Active = append(data.Active, row)
		}
	}
	h.d.Render.Page(w, r, status, "participants.html", Page{Title: "Teilnehmer", Nav: NavSettings, Error: errMsg, Data: data})
}

func (h handlers) participantCreate(w http.ResponseWriter, r *http.Request) {
	name := r.FormValue("name")
	_, err := h.d.Store.CreateParticipant(r.Context(), me(r).ID, name)
	if msg, ok := validationMsg(err); ok {
		h.renderParticipants(w, r, http.StatusUnprocessableEntity, name, msg)
		return
	}
	if err != nil {
		h.d.ServerError(w, r, err)
		return
	}
	SetFlash(w, fmt.Sprintf("„%s“ hinzugefügt.", store.NormalizeName(name)))
	http.Redirect(w, r, "/einstellungen/teilnehmer", http.StatusSeeOther)
}

func (h handlers) participantRename(w http.ResponseWriter, r *http.Request) {
	old, ok := h.loadParticipant(w, r)
	if !ok {
		return
	}
	err := h.d.Store.RenameParticipant(r.Context(), me(r).ID, old.ID, r.FormValue("name"))
	if msg, ok := validationMsg(err); ok {
		h.renderParticipants(w, r, http.StatusUnprocessableEntity, "", msg)
		return
	}
	if err != nil {
		h.d.ServerError(w, r, err)
		return
	}
	SetFlash(w, "Gespeichert.")
	http.Redirect(w, r, "/einstellungen/teilnehmer", http.StatusSeeOther)
}

// participantArchive archives a person or brings them back. A person with an
// open balance cannot be archived (the store checks this).
func (h handlers) participantArchive(archive bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		p, ok := h.loadParticipant(w, r)
		if !ok {
			return
		}
		err := h.d.Store.SetParticipantArchived(r.Context(), me(r).ID, p.ID, archive)
		if msg, ok := validationMsg(err); ok {
			h.renderParticipants(w, r, http.StatusUnprocessableEntity, "", msg)
			return
		}
		if errors.Is(err, store.ErrNotFound) {
			h.notFound(w, r, "Person nicht gefunden.")
			return
		}
		if err != nil {
			h.d.ServerError(w, r, err)
			return
		}
		verb := "archiviert"
		if !archive {
			verb = "reaktiviert"
		}
		SetFlash(w, fmt.Sprintf("„%s“ %s.", p.Name, verb))
		http.Redirect(w, r, "/einstellungen/teilnehmer", http.StatusSeeOther)
	}
}

func (h handlers) loadParticipant(w http.ResponseWriter, r *http.Request) (store.Participant, bool) {
	p, err := h.d.Store.GetParticipant(r.Context(), PathID(r))
	if errors.Is(err, store.ErrNotFound) {
		h.notFound(w, r, "Person nicht gefunden.")
		return p, false
	}
	if err != nil {
		h.d.ServerError(w, r, err)
		return p, false
	}
	return p, true
}

// --- Categories --------------------------------------------------------------

type categoriesData struct {
	Active, Archived []categoryRow
	Name             string // "new category" input after an error
}

type categoryRow struct {
	store.Category
	Expenses    int
	First, Last bool
}

func (h handlers) categories(w http.ResponseWriter, r *http.Request) {
	h.renderCategories(w, r, http.StatusOK, "", "")
}

func (h handlers) renderCategories(w http.ResponseWriter, r *http.Request, status int, name, errMsg string) {
	ctx := r.Context()
	cats, err := h.d.Store.ListCategories(ctx, true)
	if err != nil {
		h.d.ServerError(w, r, err)
		return
	}
	counts, err := h.d.Store.ExpenseCountByCategory(ctx)
	if err != nil {
		h.d.ServerError(w, r, err)
		return
	}
	data := categoriesData{Name: name}
	for _, c := range cats {
		row := categoryRow{Category: c, Expenses: counts[c.ID]}
		if c.Archived() {
			data.Archived = append(data.Archived, row)
		} else {
			data.Active = append(data.Active, row)
		}
	}
	if n := len(data.Active); n > 0 {
		data.Active[0].First, data.Active[n-1].Last = true, true
	}
	h.d.Render.Page(w, r, status, "categories.html", Page{Title: "Kategorien", Nav: NavSettings, Error: errMsg, Data: data})
}

func (h handlers) categoryCreate(w http.ResponseWriter, r *http.Request) {
	name := r.FormValue("name")
	_, err := h.d.Store.CreateCategory(r.Context(), me(r).ID, name)
	if msg, ok := validationMsg(err); ok {
		h.renderCategories(w, r, http.StatusUnprocessableEntity, name, msg)
		return
	}
	if err != nil {
		h.d.ServerError(w, r, err)
		return
	}
	SetFlash(w, fmt.Sprintf("Kategorie „%s“ hinzugefügt.", store.NormalizeName(name)))
	http.Redirect(w, r, "/einstellungen/kategorien", http.StatusSeeOther)
}

func (h handlers) categoryRename(w http.ResponseWriter, r *http.Request) {
	old, ok := h.loadCategory(w, r)
	if !ok {
		return
	}
	err := h.d.Store.RenameCategory(r.Context(), me(r).ID, old.ID, r.FormValue("name"))
	if msg, ok := validationMsg(err); ok {
		h.renderCategories(w, r, http.StatusUnprocessableEntity, "", msg)
		return
	}
	if err != nil {
		h.d.ServerError(w, r, err)
		return
	}
	SetFlash(w, "Gespeichert.")
	http.Redirect(w, r, "/einstellungen/kategorien", http.StatusSeeOther)
}

func (h handlers) categoryArchive(archive bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, ok := h.loadCategory(w, r)
		if !ok {
			return
		}
		if err := h.d.Store.SetCategoryArchived(r.Context(), me(r).ID, c.ID, archive); err != nil {
			h.d.ServerError(w, r, err)
			return
		}
		verb := "archiviert"
		if !archive {
			verb = "reaktiviert"
		}
		SetFlash(w, fmt.Sprintf("Kategorie „%s“ %s.", c.Name, verb))
		http.Redirect(w, r, "/einstellungen/kategorien", http.StatusSeeOther)
	}
}

func (h handlers) categoryMove(up bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, ok := h.loadCategory(w, r)
		if !ok {
			return
		}
		err := h.d.Store.MoveCategory(r.Context(), me(r).ID, c.ID, up)
		if errors.Is(err, store.ErrNotFound) {
			h.notFound(w, r, "Kategorie nicht gefunden.")
			return
		}
		if err != nil {
			h.d.ServerError(w, r, err)
			return
		}
		http.Redirect(w, r, "/einstellungen/kategorien#kategorie-"+strconv.FormatInt(c.ID, 10), http.StatusSeeOther)
	}
}

func (h handlers) loadCategory(w http.ResponseWriter, r *http.Request) (store.Category, bool) {
	c, err := h.d.Store.GetCategory(r.Context(), PathID(r))
	if errors.Is(err, store.ErrNotFound) {
		h.notFound(w, r, "Kategorie nicht gefunden.")
		return c, false
	}
	if err != nil {
		h.d.ServerError(w, r, err)
		return c, false
	}
	return c, true
}
