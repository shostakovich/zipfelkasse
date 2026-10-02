package web

import (
	"net/http"
	"strconv"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
)

// activityPageSize is the number of entries per page of the activity list.
const activityPageSize = 50

// activityItem is an entry of the activity log, prepared for display.
type activityItem struct {
	store.Activity
	Verb string // "angelegt", "geändert", "gelöscht"; "" = other action (Details.Text)
	// ShowAmount: show Details.AmountCents after the title (created and
	// deleted; changes of the amount are listed in Details.Changes).
	ShowAmount bool
}

func activityItems(acts []store.Activity) []activityItem {
	out := make([]activityItem, len(acts))
	for i, a := range acts {
		out[i] = activityItem{Activity: a}
		switch a.Action {
		case store.ActionExpenseCreated:
			out[i].Verb, out[i].ShowAmount = "angelegt", a.Details.AmountCents != 0
		case store.ActionExpenseUpdated:
			out[i].Verb = "geändert"
		case store.ActionExpenseDeleted:
			out[i].Verb, out[i].ShowAmount = "gelöscht", a.Details.AmountCents != 0
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
	More   string // URL of the next page, "" = no more
}

func (h handlers) activity(w http.ResponseWriter, r *http.Request) {
	before := formID(r.URL.Query().Get("vor"))
	acts, err := h.d.Store.ListActivity(r.Context(), store.ActivityFilter{BeforeID: before, Limit: activityPageSize + 1})
	if err != nil {
		h.d.ServerError(w, r, err)
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
