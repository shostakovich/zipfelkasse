package ynab

import (
	"errors"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"

	"teilen/internal/domain"
	"teilen/internal/store"
	"teilen/internal/web"
)

var errNotReady = errors.New("YNAB ist noch nicht fertig eingerichtet (Token, Plan, Konto und Startdatum).")

// Register hängt die Routen unter /einstellungen/ynab an.
func (s *Service) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /einstellungen/ynab", s.page)
	mux.HandleFunc("POST /einstellungen/ynab/token", s.saveToken)
	mux.HandleFunc("POST /einstellungen/ynab/trennen", s.disconnect)
	mux.HandleFunc("POST /einstellungen/ynab/konto", s.saveTarget)
	mux.HandleFunc("POST /einstellungen/ynab/kategorien", s.saveCategories)
	mux.HandleFunc("POST /einstellungen/ynab/sync", s.syncNow)
}

const pagePath = "/einstellungen/ynab"

// pageData ist .Data der Seite. Enthält bewusst nie den Token.
type pageData struct {
	TokenSet     bool
	TokenInvalid bool
	APIError     string // YNAB nicht erreichbar o. Ä. (Seite bleibt bedienbar)
	Plans        []planOption
	PlanName     string
	AccountName  string
	Currency     string // Währung des gewählten Plans, falls nicht EUR
	HasTarget    bool
	StartDate    time.Time
	Categories   []categoryRow
	Groups       []groupOption
	Ready        bool
	Status       Status
	RetryAt      time.Time // nur gesetzt, wenn in der Zukunft
	Synced       int
	Problems     []store.YNABSyncProblem
	Balance      int64 // eigener Saldo in der App
}

type planOption struct {
	Name     string
	Accounts []accountOption
}

type accountOption struct {
	Value    string // "planID|accountID"
	Name     string
	Selected bool
}

type groupOption struct {
	Name       string
	Categories []categoryOption
}

type categoryOption struct {
	ID, Name string
}

type categoryRow struct {
	ID       int64
	Name     string
	Archived bool
	Selected string // YNAB-Kategorie-ID oder ""
	Missing  bool   // zugeordnete YNAB-Kategorie gibt es nicht mehr
}

func (s *Service) page(w http.ResponseWriter, r *http.Request) {
	s.render(w, r, http.StatusOK, "", r.URL.Query().Get("neu") == "1")
}

// render baut die Seite für die aktuelle Person. refresh lädt Pläne und
// Kategorien neu von YNAB statt aus dem Cache.
func (s *Service) render(w http.ResponseWriter, r *http.Request, status int, errMsg string, refresh bool) {
	ctx := r.Context()
	me, _ := web.Me(ctx)
	cfg, err := s.d.Store.GetYNABConfig(ctx, me.ID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.serverError(w, r, err)
		return
	}
	data := pageData{TokenSet: cfg.Token != "", StartDate: cfg.StartDate, Ready: cfg.Ready(), HasTarget: cfg.AccountID != ""}
	if data.StartDate.IsZero() {
		data.StartDate = s.today()
	}
	data.Status = s.loadStatus(ctx, me.ID)
	data.TokenInvalid = data.TokenSet && data.Status.TokenInvalid
	if data.Status.RetryAt.After(s.now()) {
		data.RetryAt = data.Status.RetryAt
	}
	if data.Synced, data.Problems, err = s.d.Store.YNABSyncSummary(ctx, me.ID); err != nil {
		s.serverError(w, r, err)
		return
	}
	balances, err := s.d.Store.Balances(ctx)
	if err != nil {
		s.serverError(w, r, err)
		return
	}
	data.Balance = balances[me.ID]

	if data.TokenSet && !data.TokenInvalid {
		if plans, err := s.plans(ctx, cfg.Token, refresh); err != nil {
			data.APIError = s.apiMessage(err, cfg.Token)
		} else {
			s.fillPlans(&data, plans, cfg)
		}
		if cfg.PlanID != "" && data.APIError == "" {
			if groups, err := s.categories(ctx, cfg.Token, cfg.PlanID, refresh); err != nil {
				data.APIError = s.apiMessage(err, cfg.Token)
			} else {
				data.Groups = usableGroups(groups)
			}
		}
	}
	if data.HasTarget {
		if data.Categories, err = s.categoryRows(r, me.ID, data.Groups); err != nil {
			s.serverError(w, r, err)
			return
		}
	}
	s.pages.Render(w, r, status, "ynab.html", web.Page{Title: "YNAB", Nav: web.NavSettings, Error: errMsg, Data: data})
}

func (s *Service) fillPlans(data *pageData, plans []apiPlan, cfg store.YNABConfig) {
	for _, p := range plans {
		opt := planOption{Name: p.Name}
		for _, a := range usableAccounts(p) {
			sel := p.ID == cfg.PlanID && a.ID == cfg.AccountID
			opt.Accounts = append(opt.Accounts, accountOption{Value: p.ID + "|" + a.ID, Name: a.Name, Selected: sel})
			if sel {
				data.PlanName, data.AccountName = p.Name, a.Name
				if c := p.currency(); c != "" && c != "EUR" {
					data.Currency = c
				}
			}
		}
		if len(opt.Accounts) > 0 {
			data.Plans = append(data.Plans, opt)
		}
	}
}

// usableAccounts: offene, nicht gelöschte Konten im Budget (nur dort
// lassen sich Ausgaben kategorisieren).
func usableAccounts(p apiPlan) []apiAccount {
	var out []apiAccount
	for _, a := range p.Accounts {
		if a.OnBudget && !a.Closed && !a.Deleted {
			out = append(out, a)
		}
	}
	return out
}

// usableGroups: sichtbare Kategorien ohne interne Gruppen („Inflow: Ready to
// Assign“) und ohne Kreditkarten-Zahlungskategorien (die lehnt die API ab).
func usableGroups(groups []apiCategoryGroup) []groupOption {
	var out []groupOption
	for _, g := range groups {
		if g.Internal || g.Hidden || g.Deleted || g.Name == "Credit Card Payments" {
			continue
		}
		opt := groupOption{Name: g.Name}
		for _, c := range g.Categories {
			if !c.Hidden && !c.Deleted && !c.Internal {
				opt.Categories = append(opt.Categories, categoryOption{ID: c.ID, Name: c.Name})
			}
		}
		if len(opt.Categories) > 0 {
			out = append(out, opt)
		}
	}
	return out
}

func (s *Service) categoryRows(r *http.Request, participantID int64, groups []groupOption) ([]categoryRow, error) {
	cats, err := s.d.Store.ListCategories(r.Context(), true)
	if err != nil {
		return nil, err
	}
	m, err := s.d.Store.YNABCategoryMap(r.Context(), participantID)
	if err != nil {
		return nil, err
	}
	known := knownCategories(groups)
	var rows []categoryRow
	for _, c := range cats {
		sel := m[c.ID]
		if c.Archived() && sel == "" {
			continue
		}
		rows = append(rows, categoryRow{ID: c.ID, Name: c.Name, Archived: c.Archived(), Selected: sel,
			Missing: sel != "" && len(groups) > 0 && !known[sel]})
	}
	return rows, nil
}

func knownCategories(groups []groupOption) map[string]bool {
	known := map[string]bool{}
	for _, g := range groups {
		for _, c := range g.Categories {
			known[c.ID] = true
		}
	}
	return known
}

func (s *Service) apiMessage(err error, token string) string {
	if statusOf(err) == http.StatusUnauthorized {
		return errTokenInvalid.Error()
	}
	return "YNAB ist gerade nicht erreichbar: " + redact(err.Error(), token)
}

func (s *Service) serverError(w http.ResponseWriter, r *http.Request, err error) {
	s.d.Log.Error("request", "method", r.Method, "path", r.URL.Path, "err", err)
	s.d.Render.Error(w, r, http.StatusInternalServerError, "Da ist etwas schiefgegangen.")
}

func (s *Service) done(w http.ResponseWriter, r *http.Request, msg string) {
	web.SetFlash(w, msg)
	http.Redirect(w, r, pagePath, http.StatusSeeOther)
}

// saveToken prüft den Token mit einer Anfrage an YNAB und speichert ihn.
func (s *Service) saveToken(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	me, _ := web.Me(ctx)
	token := strings.TrimSpace(r.FormValue("token"))
	switch {
	case token == "":
		s.render(w, r, http.StatusUnprocessableEntity, "Bitte einen Token eingeben.", false)
		return
	case len(token) > 200 || strings.ContainsAny(token, " \t\r\n"):
		s.render(w, r, http.StatusUnprocessableEntity, "Das sieht nicht wie ein YNAB-Token aus.", false)
		return
	}
	if _, err := s.plans(ctx, token, true); err != nil {
		msg := s.apiMessage(err, token)
		if statusOf(err) == http.StatusUnauthorized {
			msg = "YNAB kennt diesen Token nicht. Bitte prüfen und neu kopieren."
		}
		s.render(w, r, http.StatusUnprocessableEntity, msg, false)
		return
	}
	if err := s.d.Store.SetYNABToken(ctx, me.ID, token); err != nil {
		s.serverError(w, r, err)
		return
	}
	// neuer Token: Sperren und alte Fehler zurücksetzen
	st := s.loadStatus(ctx, me.ID)
	st.TokenInvalid, st.RetryAt, st.Backoff, st.Error = false, time.Time{}, 0, ""
	if err := s.saveStatus(ctx, me.ID, st); err != nil {
		s.serverError(w, r, err)
		return
	}
	s.Trigger(0)
	s.done(w, r, "Token gespeichert.")
}

func (s *Service) disconnect(w http.ResponseWriter, r *http.Request) {
	me, _ := web.Me(r.Context())
	if err := s.d.Store.SetYNABToken(r.Context(), me.ID, ""); err != nil {
		s.serverError(w, r, err)
		return
	}
	s.done(w, r, "YNAB-Verbindung getrennt. Die Buchungen in YNAB bleiben erhalten.")
}

func (s *Service) saveTarget(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	me, _ := web.Me(ctx)
	cfg, err := s.d.Store.GetYNABConfig(ctx, me.ID)
	if errors.Is(err, store.ErrNotFound) || (err == nil && cfg.Token == "") {
		s.render(w, r, http.StatusUnprocessableEntity, "Bitte zuerst einen Token eingeben.", false)
		return
	}
	if err != nil {
		s.serverError(w, r, err)
		return
	}
	planID, accountID, _ := strings.Cut(r.FormValue("ziel"), "|")
	start, err := domain.ParseDate(r.FormValue("start"))
	if err != nil {
		s.render(w, r, http.StatusUnprocessableEntity, "Bitte ein gültiges Startdatum angeben.", false)
		return
	}
	plans, err := s.plans(ctx, cfg.Token, false)
	if err != nil {
		s.render(w, r, http.StatusBadGateway, s.apiMessage(err, cfg.Token), false)
		return
	}
	if !accountExists(plans, planID, accountID) {
		s.render(w, r, http.StatusUnprocessableEntity, "Bitte Plan und Konto auswählen.", false)
		return
	}
	if err := s.d.Store.SetYNABTarget(ctx, me.ID, planID, accountID, start); err != nil {
		s.serverError(w, r, err)
		return
	}
	s.Trigger(0)
	s.done(w, r, "Gespeichert.")
}

func accountExists(plans []apiPlan, planID, accountID string) bool {
	for _, p := range plans {
		if p.ID == planID {
			return slices.ContainsFunc(usableAccounts(p), func(a apiAccount) bool { return a.ID == accountID })
		}
	}
	return false
}

func (s *Service) saveCategories(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	me, _ := web.Me(ctx)
	cfg, err := s.d.Store.GetYNABConfig(ctx, me.ID)
	if errors.Is(err, store.ErrNotFound) || (err == nil && (cfg.Token == "" || cfg.PlanID == "")) {
		s.render(w, r, http.StatusUnprocessableEntity, "Bitte zuerst Token, Plan und Konto einrichten.", false)
		return
	}
	if err != nil {
		s.serverError(w, r, err)
		return
	}
	groups, err := s.categories(ctx, cfg.Token, cfg.PlanID, false)
	if err != nil {
		s.render(w, r, http.StatusBadGateway, s.apiMessage(err, cfg.Token), false)
		return
	}
	known := knownCategories(usableGroups(groups))
	old, err := s.d.Store.YNABCategoryMap(ctx, me.ID)
	if err != nil {
		s.serverError(w, r, err)
		return
	}
	if err := r.ParseForm(); err != nil {
		s.render(w, r, http.StatusBadRequest, "Ungültiges Formular.", false)
		return
	}
	m := map[int64]string{}
	for key, vals := range r.PostForm {
		idStr, ok := strings.CutPrefix(key, "kat-")
		if !ok || len(vals) == 0 {
			continue
		}
		id, err := strconv.ParseInt(idStr, 10, 64)
		if err != nil {
			continue
		}
		v := vals[0]
		// Unbekannte IDs nur zulassen, wenn sie schon zugeordnet waren
		// (Kategorie in YNAB gelöscht/versteckt – Zuordnung nicht stillschweigend verlieren).
		if v != "" && !known[v] && old[id] != v {
			s.render(w, r, http.StatusUnprocessableEntity, "Unbekannte YNAB-Kategorie. Bitte die Seite neu laden.", false)
			return
		}
		m[id] = v
	}
	err = s.d.Store.SetYNABCategoryMap(ctx, me.ID, m)
	var ve domain.ValidationError
	if errors.As(err, &ve) {
		s.render(w, r, http.StatusUnprocessableEntity, ve.Msg, false)
		return
	}
	if err != nil {
		s.serverError(w, r, err)
		return
	}
	s.Trigger(0)
	s.done(w, r, "Kategorie-Zuordnung gespeichert.")
}

// syncNow stößt einen vollständigen Abgleich im Hintergrund an und leitet
// sofort zurück; das Ergebnis zeigt der Status nach dem Neuladen.
func (s *Service) syncNow(w http.ResponseWriter, r *http.Request) {
	me, _ := web.Me(r.Context())
	cfg, err := s.d.Store.GetYNABConfig(r.Context(), me.ID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.serverError(w, r, err)
		return
	}
	if !cfg.Ready() {
		s.render(w, r, http.StatusUnprocessableEntity, errNotReady.Error(), false)
		return
	}
	s.syncInBackground(me.ID)
	s.done(w, r, "Synchronisierung gestartet – Status unten aktualisiert sich nach dem Neuladen.")
}
