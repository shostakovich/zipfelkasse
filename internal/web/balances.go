package web

import (
	"net/http"
	"net/url"
	"strconv"

	"teilen/internal/domain"
	"teilen/internal/store"
)

type balancesData struct {
	Rows      []balanceRow
	Transfers []transferRow
}

// balanceRow ist eine Zeile der Saldenliste mit Balken wie bei Spliit.
type balanceRow struct {
	Participant store.Participant
	Cents       int64
	Width       int // Balkenbreite in Prozent der halben Zeile (0–100)
}

// transferRow ist ein Ausgleichsvorschlag „From zahlt To Cents“.
type transferRow struct {
	From, To store.Participant
	Cents    int64
	Link     string // vorbefülltes Rückzahlungsformular
}

func (h handlers) balances(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	balances, err := h.d.Store.Balances(ctx)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	people, err := h.d.Store.ListParticipants(ctx, true)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	byID := map[int64]store.Participant{}
	var maxAbs int64
	for _, b := range balances {
		maxAbs = max(maxAbs, b, -b)
	}
	var data balancesData
	for _, p := range people {
		byID[p.ID] = p
		b := balances[p.ID]
		// Archivierte Personen nur, solange sie noch einen Saldo haben.
		if p.Archived() && b == 0 {
			continue
		}
		row := balanceRow{Participant: p, Cents: b}
		if maxAbs > 0 && b != 0 {
			row.Width = max(1, int((max(b, -b)*100+maxAbs/2)/maxAbs))
		}
		data.Rows = append(data.Rows, row)
	}
	for _, t := range domain.Settle(balances) {
		v := url.Values{
			"rueckzahlung": {"1"},
			"von":          {strconv.FormatInt(t.From, 10)},
			"an":           {strconv.FormatInt(t.To, 10)},
			"betrag":       {strconv.FormatInt(t.AmountCents, 10)},
		}
		data.Transfers = append(data.Transfers, transferRow{
			From: byID[t.From], To: byID[t.To], Cents: t.AmountCents, Link: "/ausgaben/neu?" + v.Encode(),
		})
	}
	h.d.Render.Page(w, r, http.StatusOK, "balances.html", Page{Title: "Salden", Nav: NavBalances, Data: data})
}
