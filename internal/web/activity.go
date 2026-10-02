package web

import (
	"net/http"
	"strconv"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
)

// actionSettingsUpdated protokolliert Änderungen an Gruppenname, Personen und
// Kategorien (Details.Text beschreibt die Änderung).
const actionSettingsUpdated = store.ActionSettingsUpdated

// activityPageSize ist die Zahl der Einträge pro Seite der Aktivitätsliste.
const activityPageSize = 50

// activityItem ist ein Eintrag im Aktivitätsprotokoll, für die Anzeige
// aufbereitet.
type activityItem struct {
	store.Activity
	Verb string // „angelegt“, „geändert“, „gelöscht“; "" = sonstige Aktion (Details.Text)
}

func activityItems(acts []store.Activity) []activityItem {
	out := make([]activityItem, len(acts))
	for i, a := range acts {
		out[i] = activityItem{Activity: a}
		switch a.Action {
		case store.ActionExpenseCreated:
			out[i].Verb = "angelegt"
		case store.ActionExpenseUpdated:
			out[i].Verb = "geändert"
		case store.ActionExpenseDeleted:
			out[i].Verb = "gelöscht"
		}
	}
	return out
}

type activityGroup struct {
	Label string
	Items []activityItem
}

type activityData struct {
	Groups []activityGroup
	More   string // URL der nächsten Seite, "" = keine weiteren
}

func (h handlers) activity(w http.ResponseWriter, r *http.Request) {
	before := formID(r.URL.Query().Get("vor"))
	acts, err := h.d.Store.ListActivity(r.Context(), store.ActivityFilter{BeforeID: before, Limit: activityPageSize + 1})
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	var data activityData
	if len(acts) > activityPageSize {
		acts = acts[:activityPageSize]
		data.More = "/aktivitaet?vor=" + strconv.FormatInt(acts[len(acts)-1].ID, 10)
	}
	loc := h.d.Config.Location
	if loc == nil {
		loc = time.Local
	}
	today := h.d.Today()
	last := -1
	for _, it := range activityItems(acts) {
		p := activityPeriod(domain.DateOf(it.At.In(loc)), today)
		if p != last {
			data.Groups = append(data.Groups, activityGroup{Label: activityPeriodLabels[p]})
			last = p
		}
		g := &data.Groups[len(data.Groups)-1]
		g.Items = append(g.Items, it)
	}
	h.d.Render.Page(w, r, http.StatusOK, "activity.html", Page{Title: "Aktivität", Nav: NavActivity, Data: data})
}

// logSettings schreibt einen Eintrag „Einstellungen geändert“ (siehe
// Deps.LogSettings).
func (h handlers) logSettings(r *http.Request, text string) { h.d.LogSettings(r, text) }

// LogSettings schreibt für die aktuelle Person (Me) einen Eintrag
// „Einstellungen geändert“ (store.ActionSettingsUpdated) mit text. Fehler
// werden nur geloggt – die eigentliche Änderung ist bereits gespeichert.
func (d Deps) LogSettings(r *http.Request, text string) {
	p, _ := Me(r.Context())
	if err := d.Store.AddActivity(r.Context(), p.ID, actionSettingsUpdated, 0, store.ActivityDetails{Text: text}); err != nil {
		d.Log.Error("aktivität", "err", err)
	}
}
