package web

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"teilen/internal/domain"
	"teilen/internal/store"
)

func TestSettingsGroupName(t *testing.T) {
	g := newGroup(t, nil)
	status, body := g.get("/einstellungen")
	for _, link := range []string{"/einstellungen/teilnehmer", "/einstellungen/kategorien", "/einstellungen/wiederkehrend", "/einstellungen/kurse", "/einstellungen/ynab", "/export"} {
		if !strings.Contains(body, `href="`+link+`"`) {
			t.Errorf("Link %s fehlt", link)
		}
	}
	if status != 200 {
		t.Fatalf("Status %d", status)
	}
	status, loc, _ := g.post("/einstellungen", url.Values{"gruppenname": {"WG Süd"}})
	if status != http.StatusSeeOther || loc != "/einstellungen" {
		t.Fatalf("POST: %d %q", status, loc)
	}
	if n := g.d.Store.GroupName(context.Background()); n != "WG Süd" {
		t.Errorf("GroupName = %q", n)
	}
	_, body = g.get("/salden")
	if !strings.Contains(body, "<title>Salden · WG Süd</title>") {
		t.Error("Gruppenname nicht im Titel")
	}
	status, _, body = g.post("/einstellungen", url.Values{"gruppenname": {"  "}})
	if status != http.StatusUnprocessableEntity || !strings.Contains(errorOf(body), "Namen") {
		t.Errorf("leerer Name: %d %q", status, errorOf(body))
	}
	_, body = g.get("/aktivitaet")
	if !strings.Contains(body, "Gruppe umbenannt: „teilen“ → „WG Süd“") {
		t.Error("Umbenennung nicht protokolliert")
	}
}

func TestSettingsParticipants(t *testing.T) {
	g := newGroup(t, nil)
	ctx := context.Background()
	status, body := g.get("/einstellungen/teilnehmer")
	if status != 200 || !strings.Contains(body, `value="Ben"`) || !strings.Contains(body, "das bist du") {
		t.Fatalf("GET: %d", status)
	}

	// Anlegen, doppelt anlegen.
	status, loc, _ := g.post("/einstellungen/teilnehmer", url.Values{"name": {"Dora"}})
	if status != http.StatusSeeOther || loc != "/einstellungen/teilnehmer" {
		t.Fatalf("anlegen: %d", status)
	}
	status, _, body = g.post("/einstellungen/teilnehmer", url.Values{"name": {"dora"}})
	if status != http.StatusUnprocessableEntity || !strings.Contains(errorOf(body), "gibt es schon") || !strings.Contains(body, `value="dora"`) {
		t.Errorf("doppelt: %d %q", status, errorOf(body))
	}
	ps, _ := g.d.Store.ListParticipants(ctx, false)
	var dora int64
	for _, p := range ps {
		if p.Name == "Dora" {
			dora = p.ID
		}
	}
	if dora == 0 {
		t.Fatal("Dora fehlt")
	}

	// Umbenennen.
	if status, _, _ := g.post("/einstellungen/teilnehmer/"+id(dora), url.Values{"name": {"Dorothea"}}); status != http.StatusSeeOther {
		t.Errorf("umbenennen: %d", status)
	}
	if p, _ := g.d.Store.GetParticipant(ctx, dora); p.Name != "Dorothea" {
		t.Errorf("Name = %q", p.Name)
	}
	if status, _, _ := g.post("/einstellungen/teilnehmer/"+id(dora), url.Values{"name": {"Ben"}}); status != http.StatusUnprocessableEntity {
		t.Errorf("umbenennen auf vorhandenen Namen: %d", status)
	}
	if status, _, _ := g.post("/einstellungen/teilnehmer/999", url.Values{"name": {"X"}}); status != http.StatusNotFound {
		t.Errorf("unbekannte Person: %d", status)
	}

	// Archivieren mit offenem Saldo geht nicht.
	g.create(g.form())
	status, _, body = g.post("/einstellungen/teilnehmer/"+id(g.ben)+"/archivieren", nil)
	if status != http.StatusUnprocessableEntity || !strings.Contains(errorOf(body), "Ben hat noch einen Saldo von -10,00 €") {
		t.Errorf("archivieren mit Saldo: %d %q", status, errorOf(body))
	}
	// Ohne Saldo: archivieren und zurückholen.
	if status, _, _ := g.post("/einstellungen/teilnehmer/"+id(dora)+"/archivieren", nil); status != http.StatusSeeOther {
		t.Errorf("archivieren: %d", status)
	}
	if p, _ := g.d.Store.GetParticipant(ctx, dora); !p.Archived() {
		t.Error("nicht archiviert")
	}
	_, body = g.get("/einstellungen/teilnehmer")
	if !strings.Contains(body, "Archiviert") || !strings.Contains(body, "/einstellungen/teilnehmer/"+id(dora)+"/reaktivieren") {
		t.Error("archivierte Person nicht gelistet")
	}
	if status, _, _ := g.post("/einstellungen/teilnehmer/"+id(dora)+"/reaktivieren", nil); status != http.StatusSeeOther {
		t.Errorf("reaktivieren: %d", status)
	}
	if p, _ := g.d.Store.GetParticipant(ctx, dora); p.Archived() {
		t.Error("nicht reaktiviert")
	}
	_, body = g.get("/aktivitaet")
	for _, want := range []string{"Person „Dora“ hinzugefügt", "Person „Dora“ umbenannt in „Dorothea“", "Person „Dorothea“ archiviert", "Person „Dorothea“ reaktiviert"} {
		if !strings.Contains(body, want) {
			t.Errorf("Aktivität enthält nicht %q", want)
		}
	}
}

func TestSettingsCategories(t *testing.T) {
	g := newGroup(t, nil)
	ctx := context.Background()
	status, body := g.get("/einstellungen/kategorien")
	if status != 200 || !strings.Contains(body, `value="Lebensmittel"`) {
		t.Fatalf("GET: %d", status)
	}
	status, _, _ = g.post("/einstellungen/kategorien", url.Values{"name": {"Haustier"}})
	if status != http.StatusSeeOther {
		t.Fatalf("anlegen: %d", status)
	}
	if status, _, body := g.post("/einstellungen/kategorien", url.Values{"name": {""}}); status != http.StatusUnprocessableEntity {
		t.Errorf("leer: %d %q", status, errorOf(body))
	}
	cats, _ := g.d.Store.ListCategories(ctx, false)
	first, second := cats[0], cats[1]

	if status, _, _ := g.post("/einstellungen/kategorien/"+id(first.ID), url.Values{"name": {"Essen & Trinken"}}); status != http.StatusSeeOther {
		t.Errorf("umbenennen: %d", status)
	}
	status, loc, _ := g.post("/einstellungen/kategorien/"+id(second.ID)+"/hoch", nil)
	if status != http.StatusSeeOther || loc != "/einstellungen/kategorien#kategorie-"+id(second.ID) {
		t.Errorf("hoch: %d %q", status, loc)
	}
	cats, _ = g.d.Store.ListCategories(ctx, false)
	if cats[0].ID != second.ID || cats[1].Name != "Essen & Trinken" {
		t.Errorf("Reihenfolge: %s, %s", cats[0].Name, cats[1].Name)
	}
	if acts, _ := g.d.Store.ListActivity(ctx, store.ActivityFilter{Limit: 1}); len(acts) != 1 ||
		acts[0].Action != store.ActionSettingsUpdated || acts[0].ActorID != g.anna ||
		acts[0].Details.Text != "Kategorie „"+second.Name+"“ nach oben verschoben" {
		t.Errorf("Aktivität = %+v", acts)
	}
	if status, _, _ := g.post("/einstellungen/kategorien/"+id(second.ID)+"/runter", nil); status != http.StatusSeeOther {
		t.Errorf("runter: %d", status)
	}
	if status, _, _ := g.post("/einstellungen/kategorien/"+id(first.ID)+"/archivieren", nil); status != http.StatusSeeOther {
		t.Errorf("archivieren: %d", status)
	}
	if c, _ := g.d.Store.GetCategory(ctx, first.ID); !c.Archived() {
		t.Error("nicht archiviert")
	}
	// Archivierte Kategorie fehlt im neuen Formular …
	if _, body := g.get("/ausgaben/neu"); strings.Contains(body, "Essen &amp; Trinken") || strings.Contains(body, "Essen & Trinken") {
		t.Error("archivierte Kategorie im Formular")
	}
	if status, _, _ := g.post("/einstellungen/kategorien/"+id(first.ID)+"/hoch", nil); status != http.StatusNotFound {
		t.Errorf("archivierte verschieben: %d", status)
	}
	if status, _, _ := g.post("/einstellungen/kategorien/"+id(first.ID)+"/reaktivieren", nil); status != http.StatusSeeOther {
		t.Errorf("reaktivieren: %d", status)
	}
	if status, _, _ := g.post("/einstellungen/kategorien/999/archivieren", nil); status != http.StatusNotFound {
		t.Errorf("unbekannt: %d", status)
	}
}

func TestPWA(t *testing.T) {
	g := newGroup(t, nil)
	g.d.Store.SetGroupName(context.Background(), "WG Süd")
	// Öffentlich, ohne Person.
	res, body := get(t, g.srv, "/manifest.webmanifest")
	if res.StatusCode != 200 || !strings.HasPrefix(res.Header.Get("Content-Type"), "application/manifest+json") {
		t.Fatalf("manifest: %d %s", res.StatusCode, res.Header.Get("Content-Type"))
	}
	var m struct {
		Name, ShortName, Lang, Display, StartURL, ThemeColor string
		Icons                                                []manifestIcon
	}
	var raw map[string]any
	if err := json.Unmarshal([]byte(body), &raw); err != nil {
		t.Fatal(err)
	}
	json.Unmarshal([]byte(body), &m)
	if raw["name"] != "WG Süd" || raw["lang"] != "de" || raw["display"] != "standalone" || raw["start_url"] != "/" || raw["theme_color"] != themeColor {
		t.Errorf("manifest = %v", raw)
	}
	purposes := map[string]bool{}
	for _, ic := range m.Icons {
		purposes[ic.Sizes+" "+ic.Purpose] = true
		res, _ := get(t, g.srv, ic.Src)
		if res.StatusCode != 200 || res.Header.Get("Content-Type") != "image/png" {
			t.Errorf("Icon %s: %d %s", ic.Src, res.StatusCode, res.Header.Get("Content-Type"))
		}
	}
	for _, want := range []string{"192x192 any", "512x512 any", "512x512 maskable"} {
		if !purposes[want] {
			t.Errorf("Icon %q fehlt", want)
		}
	}

	res, body = get(t, g.srv, "/sw.js")
	if res.StatusCode != 200 || !strings.HasPrefix(res.Header.Get("Content-Type"), "text/javascript") ||
		res.Header.Get("Cache-Control") != "no-cache" || !strings.Contains(body, "addEventListener") {
		t.Errorf("sw.js: %d %s", res.StatusCode, res.Header.Get("Content-Type"))
	}
	if strings.Contains(body, "caches.") {
		t.Error("sw.js cacht")
	}
	res, _ = get(t, g.srv, "/favicon.ico")
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "image/png" {
		t.Errorf("favicon: %d", res.StatusCode)
	}
	res, _ = get(t, g.srv, "/static/icons/apple-touch-icon.png")
	if res.StatusCode != 200 {
		t.Errorf("apple-touch-icon: %d", res.StatusCode)
	}
	_, body = g.get("/")
	for _, want := range []string{`rel="manifest" href="/manifest.webmanifest"`, `rel="apple-touch-icon"`, "/static/app.js?v="} {
		if !strings.Contains(body, want) {
			t.Errorf("Layout enthält nicht %q", want)
		}
	}
}

// TestStaticAssets prüft, dass die eingebetteten Skripte/Icons ausgeliefert
// werden und das CSS die vertraglich zugesagten Klassen enthält.
func TestStaticAssets(t *testing.T) {
	g := newGroup(t, nil)
	for _, p := range []string{"/static/app.js", "/static/expense-form.js", "/static/icons.svg"} {
		if res, _ := get(t, g.srv, p); res.StatusCode != 200 {
			t.Errorf("%s: %d", p, res.StatusCode)
		}
	}
	_, css := get(t, g.srv, "/static/app.css")
	for _, cls := range []string{
		".container", ".main", ".site-header", ".site-header-inner", ".brand", ".whoami", ".tabs",
		".card", ".card-header", ".card-title", ".card-description", ".card-content", ".card-footer",
		".btn", ".btn-primary", ".btn-secondary", ".btn-outline", ".btn-ghost", ".btn-destructive", ".btn-sm", ".btn-lg", ".btn-block",
		".form", ".field", ".field-error", ".help", ".table-wrap", ".alert", ".alert-success", ".alert-destructive",
		".link-list", ".stack", ".stack-sm", ".row", ".muted", ".amount", ".positive", ".negative", ".sr-only",
	} {
		if !strings.Contains(css, cls+" ") && !strings.Contains(css, cls+",") && !strings.Contains(css, cls+"{") {
			t.Errorf("app.css: Klasse %s fehlt", cls)
		}
	}
}

func TestExpensePeriod(t *testing.T) {
	today := date("2026-10-02") // Freitag
	tests := map[string]string{
		"2026-10-05": "Bevorstehend",
		"2026-10-02": "Diese Woche",
		"2026-09-28": "Diese Woche", // Montag, anderer Monat
		"2026-09-27": "Letzter Monat",
		"2026-10-01": "Diese Woche",
		"2026-08-31": "Früher in diesem Jahr",
		"2025-12-31": "Letztes Jahr",
		"2024-06-01": "Älter",
	}
	for d, want := range tests {
		if got := periodLabels[expensePeriod(date(d), today)]; got != want {
			t.Errorf("%s: %q, want %q", d, got, want)
		}
	}
	today = date("2026-10-20")
	if got := periodLabels[expensePeriod(date("2026-10-05"), today)]; got != "Früher in diesem Monat" {
		t.Errorf("Monatsanfang: %q", got)
	}
	// Januar: Dezember ist „Letzter Monat“, nicht „Letztes Jahr“.
	if got := periodLabels[expensePeriod(date("2025-12-15"), date("2026-01-20"))]; got != "Letzter Monat" {
		t.Errorf("Jahreswechsel: %q", got)
	}
	acts := map[string]string{
		"2026-10-20": "Heute", "2026-10-19": "Gestern", "2026-10-18": "Letzte Woche", "2026-10-12": "Letzte Woche",
		"2026-10-11": "Früher in diesem Monat", "2026-09-30": "Letzter Monat", "2026-01-01": "Früher in diesem Jahr",
	}
	for d, want := range acts {
		if got := activityPeriodLabels[activityPeriod(date(d), today)]; got != want {
			t.Errorf("Aktivität %s: %q, want %q", d, got, want)
		}
	}
}

func TestFormatHelpers(t *testing.T) {
	for _, tt := range []struct {
		total   int64
		weights []int64
		want    []int64
	}{
		{667, []int64{600, 400}, []int64{400, 267}},
		{100, []int64{1, 1, 1}, []int64{34, 33, 33}},
		{1_000_000_000_000, []int64{999_999_999_999_999, 1}, []int64{1_000_000_000_000, 0}},
		{5, []int64{0, 0}, []int64{0, 0}},
	} {
		got := allocate(tt.total, tt.weights)
		for i := range got {
			if got[i] != tt.want[i] {
				t.Errorf("allocate(%d, %v) = %v, want %v", tt.total, tt.weights, got, tt.want)
				break
			}
		}
	}
	for in, want := range map[[2]string]string{
		{"123456", "USD"}: "1234,56", {"500", "JPY"}: "500", {"1234", "KWD"}: "1,234", {"5", "EUR"}: "0,05",
	} {
		var n int64
		for _, c := range in[0] {
			n = n*10 + int64(c-'0')
		}
		if got := minorInput(n, in[1]); got != want {
			t.Errorf("minorInput(%s) = %q, want %q", in, got, want)
		}
	}
	if rateInput(1.0876) != "1,0876" || rateInput(0) != "" {
		t.Error("rateInput")
	}
	for name, want := range map[string]string{"Lebensmittel": "cart", "Miete & Nebenkosten": "key", "Restaurant": "utensils", "Was anderes": "tag", "Sonstiges": "receipt"} {
		if got := categoryIcon(name); got != want {
			t.Errorf("categoryIcon(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestGroupExpensesRows(t *testing.T) {
	today := date("2026-10-02")
	names := map[int64]string{1: "A", 2: "B", 3: "C", 4: "D"}
	es := []store.Expense{
		{ID: 1, ExpenseInput: store.ExpenseInput{Date: today, PaidBy: 1, AmountCents: 400}, Shares: []domain.Share{{ParticipantID: 1, AmountCents: 100}, {ParticipantID: 2, AmountCents: 100}, {ParticipantID: 3, AmountCents: 100}, {ParticipantID: 4, AmountCents: 100}}},
		{ID: 2, ExpenseInput: store.ExpenseInput{Date: date("2026-09-01"), PaidBy: 2, AmountCents: 300}, Shares: []domain.Share{{ParticipantID: 2, AmountCents: 150}, {ParticipantID: 3, AmountCents: 150}}},
	}
	groups := groupExpenses(es, today, 1, names, 4)
	if len(groups) != 2 || groups[0].Label != "Diese Woche" || groups[1].Label != "Letzter Monat" {
		t.Fatalf("Gruppen: %+v", groups)
	}
	r := groups[0].Rows[0]
	if !r.Everyone || !r.Involved || r.MyBalance != 300 {
		t.Errorf("Zeile 1: %+v", r)
	}
	r = groups[1].Rows[0]
	if r.Everyone || r.Involved || r.MyBalance != 0 || strings.Join(r.ForNames, ",") != "B,C" {
		t.Errorf("Zeile 2: %+v", r)
	}
}

func date(s string) time.Time {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		panic(err)
	}
	return t
}
