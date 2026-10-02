package web

import (
	"context"
	"errors"
	"html"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"teilen/internal/domain"
	"teilen/internal/store"
)

// fakeFX liefert feste Kurse; unbekannte Währungen ergeben einen Fehler.
type fakeFX map[string]float64

func (f fakeFX) Rate(_ context.Context, cur string, date time.Time) (domain.FXRate, error) {
	r, ok := f[cur]
	if !ok {
		return domain.FXRate{}, errors.New("kein Kurs")
	}
	return domain.FXRate{Currency: cur, Date: date, Rate: r, Source: domain.FXSourceECB}, nil
}

// group ist ein Testaufbau mit drei Personen; Anna ist angemeldet.
type group struct {
	t               *testing.T
	srv             testServer
	d               Deps
	anna, ben, cleo int64
	food            int64
	cookie          *http.Cookie
}

func newGroup(t *testing.T, fx FXRater) *group {
	t.Helper()
	st, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	r, err := NewRenderer(st, time.UTC, log)
	if err != nil {
		t.Fatal(err)
	}
	d := Deps{Store: st, Render: r, Log: log, FX: fx}
	mux := http.NewServeMux()
	Register(mux, d)
	g := &group{t: t, srv: testServer{h: Wrap(d, mux)}, d: d}
	ctx := context.Background()
	g.anna, _ = st.CreateParticipant(ctx, "Anna")
	g.ben, _ = st.CreateParticipant(ctx, "Ben")
	g.cleo, _ = st.CreateParticipant(ctx, "Cleo")
	cats, _ := st.ListCategories(ctx, false)
	g.food = cats[0].ID
	g.cookie = whoCookie(g.anna)
	return g
}

func (g *group) get(path string) (int, string) {
	g.t.Helper()
	res, body := get(g.t, g.srv, path, g.cookie)
	return res.StatusCode, html.UnescapeString(body)
}

// post schickt ein Formular als Anna und liefert Status, Location und Body.
func (g *group) post(path string, v url.Values) (int, string, string) {
	g.t.Helper()
	req := httptest.NewRequest("POST", path, strings.NewReader(v.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(g.cookie)
	res := g.srv.do(req)
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, res.Header.Get("Location"), html.UnescapeString(string(b))
}

func id(v int64) string { return strconv.FormatInt(v, 10) }

// form liefert ein gültiges Formular: Anna zahlt 30 € für alle, gleichmäßig.
func (g *group) form() url.Values {
	return url.Values{
		"titel": {"Einkauf"}, "datum": {"2026-09-30"}, "kategorie": {id(g.food)}, "waehrung": {"EUR"},
		"betrag": {"30,00"}, "bezahlt_von": {id(g.anna)}, "aufteilung": {"equal"},
		"teil": {id(g.anna), id(g.ben), id(g.cleo)},
	}
}

// create legt eine Ausgabe an und liefert die gespeicherte Ausgabe.
func (g *group) create(v url.Values) store.Expense {
	g.t.Helper()
	status, loc, body := g.post("/ausgaben/neu", v)
	if status != http.StatusSeeOther || loc != "/" {
		g.t.Fatalf("POST /ausgaben/neu: %d → %q\n%s", status, loc, errorOf(body))
	}
	es, err := g.d.Store.ListExpenses(context.Background(), store.ExpenseFilter{Limit: 1})
	if err != nil || len(es) == 0 {
		g.t.Fatalf("keine Ausgabe gespeichert: %v", err)
	}
	return es[0]
}

// errorOf zieht die Fehlermeldung aus einer gerenderten Seite (für Testausgaben).
func errorOf(body string) string {
	_, after, ok := strings.Cut(body, `role="alert">`)
	if !ok {
		return "(keine Fehlermeldung)"
	}
	msg, _, _ := strings.Cut(after, "<")
	return msg
}

func shares(e store.Expense) map[int64]int64 {
	m := map[int64]int64{}
	for _, s := range e.Shares {
		m[s.ParticipantID] = s.AmountCents
	}
	return m
}

func TestExpenseCreateSplitModes(t *testing.T) {
	tests := []struct {
		name   string
		mode   string
		amount string
		values map[string]string // Person → Wert
		who    []string
		want   map[string]int64
	}{
		{"gleichmäßig", "equal", "10,00", nil, []string{"anna", "ben", "cleo"},
			map[string]int64{"anna": 334, "ben": 333, "cleo": 333}},
		{"gleichmäßig zwei", "equal", "10,00", nil, []string{"ben", "cleo"},
			map[string]int64{"ben": 500, "cleo": 500}},
		{"Anteile", "shares", "40,00", map[string]string{"anna": "2", "ben": "1", "cleo": ""}, []string{"anna", "ben", "cleo"},
			map[string]int64{"anna": 2000, "ben": 1000, "cleo": 1000}},
		{"Prozent", "percent", "10,00", map[string]string{"anna": "50", "ben": "25,5", "cleo": "24,5"}, []string{"anna", "ben", "cleo"},
			map[string]int64{"anna": 500, "ben": 255, "cleo": 245}},
		{"Beträge", "amount", "10,00", map[string]string{"anna": "5", "ben": "3,50", "cleo": "1,50"}, []string{"anna", "ben", "cleo"},
			map[string]int64{"anna": 500, "ben": 350, "cleo": 150}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			g := newGroup(t, nil)
			ids := map[string]int64{"anna": g.anna, "ben": g.ben, "cleo": g.cleo}
			v := g.form()
			v.Set("aufteilung", tt.mode)
			v.Set("betrag", tt.amount)
			v.Del("teil")
			for _, n := range tt.who {
				v.Add("teil", id(ids[n]))
			}
			for n, val := range tt.values {
				v.Set("wert_"+id(ids[n]), val)
			}
			e := g.create(v)
			if string(e.SplitMode) != tt.mode {
				t.Errorf("SplitMode = %q", e.SplitMode)
			}
			got := shares(e)
			if len(got) != len(tt.want) {
				t.Errorf("Anteile = %v", got)
			}
			for n, c := range tt.want {
				if got[ids[n]] != c {
					t.Errorf("%s: %d, want %d (alle: %v)", n, got[ids[n]], c, got)
				}
			}
			if e.Title != "Einkauf" || e.CategoryID != g.food || e.PaidBy != g.anna || e.Date.Format(domain.DateLayout) != "2026-09-30" {
				t.Errorf("Ausgabe = %+v", e.ExpenseInput)
			}
		})
	}
}

func TestExpenseCreateFlashAndList(t *testing.T) {
	g := newGroup(t, nil)
	v := g.form()
	v.Set("datum", g.d.Today().Format(domain.DateLayout))
	v.Set("titel", "Wochenmarkt")
	req := httptest.NewRequest("POST", "/ausgaben/neu", strings.NewReader(v.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(g.cookie)
	res := g.srv.do(req)
	var flash *http.Cookie
	for _, c := range res.Cookies() {
		if c.Name == flashCookie {
			flash = c
		}
	}
	if res.StatusCode != http.StatusSeeOther || flash == nil {
		t.Fatalf("POST: %d, Flash %v", res.StatusCode, flash)
	}
	r, body := get(t, g.srv, "/", g.cookie, flash)
	body = html.UnescapeString(body)
	for _, want := range []string{
		"Ausgabe „Wochenmarkt“ angelegt.", "Diese Woche", "Wochenmarkt", "Bezahlt von <strong>Anna</strong> für <strong>Anna</strong>, <strong>Ben</strong>, <strong>Cleo</strong>",
		"30,00 €", "Dein Saldo", "20,00 €", `href="/ausgaben/neu"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("Startseite enthält nicht %q", want)
		}
	}
	if r.StatusCode != 200 {
		t.Errorf("Status %d", r.StatusCode)
	}
}

func TestExpenseValidation(t *testing.T) {
	g := newGroup(t, nil)
	tests := []struct {
		name   string
		change func(url.Values)
		want   string
	}{
		{"ohne Titel", func(v url.Values) { v.Set("titel", " ") }, "Bitte einen Titel angeben."},
		{"Betrag kaputt", func(v url.Values) { v.Set("betrag", "12,3,4") }, "Ungültiger Betrag"},
		{"Betrag 0", func(v url.Values) { v.Set("betrag", "0") }, "größer als 0"},
		{"Datum fehlt", func(v url.Values) { v.Set("datum", "") }, "Bitte ein Datum angeben."},
		{"niemand", func(v url.Values) { v.Del("teil") }, "mindestens eine Person"},
		{"Prozent falsch", func(v url.Values) {
			v.Set("aufteilung", "percent")
			v.Set("wert_"+id(g.anna), "50")
			v.Set("wert_"+id(g.ben), "20")
			v.Set("wert_"+id(g.cleo), "20")
		}, "100 %"},
		{"Beträge falsch", func(v url.Values) {
			v.Set("aufteilung", "amount")
			v.Set("wert_"+id(g.anna), "10")
		}, "zusammen 30,00 € ergeben"},
		{"Anteile keine Zahl", func(v url.Values) {
			v.Set("aufteilung", "shares")
			v.Set("wert_"+id(g.ben), "1,5")
		}, "Ben: Anteile müssen ganze Zahlen sein"},
		{"Rückzahlung an zwei", func(v url.Values) { v.Set("rueckzahlung", "1") }, "genau eine Person"},
		{"Währung kaputt", func(v url.Values) { v.Set("waehrung", ""); v.Set("waehrung_andere", "EURO") }, "Ungültige Währung"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v := g.form()
			v.Set("titel", "Mein Titel")
			v.Set("notiz", "Bitte behalten")
			tt.change(v)
			status, _, body := g.post("/ausgaben/neu", v)
			if status != http.StatusUnprocessableEntity {
				t.Fatalf("Status %d, want 422", status)
			}
			if msg := errorOf(body); !strings.Contains(msg, tt.want) {
				t.Errorf("Meldung %q, want %q", msg, tt.want)
			}
			// Eingaben bleiben erhalten.
			if !strings.Contains(body, "Bitte behalten</textarea>") {
				t.Error("Notiz nicht erhalten")
			}
			if v.Get("titel") == "Mein Titel" && !strings.Contains(body, `value="Mein Titel"`) {
				t.Error("Titel nicht erhalten")
			}
		})
	}
	if es, _ := g.d.Store.ListExpenses(context.Background(), store.ExpenseFilter{}); len(es) != 0 {
		t.Errorf("trotz Fehlern gespeichert: %d", len(es))
	}
}

func TestExpenseEditAndDelete(t *testing.T) {
	g := newGroup(t, nil)
	e := g.create(g.form())
	path := "/ausgaben/" + id(e.ID)

	status, body := g.get(path)
	if status != 200 || !strings.Contains(body, `value="Einkauf"`) || !strings.Contains(body, `value="30,00"`) ||
		!strings.Contains(body, "Ausgabe bearbeiten") || !strings.Contains(body, "/einstellungen/wiederkehrend/neu?ausgabe="+id(e.ID)) {
		t.Fatalf("GET %s: %d", path, status)
	}

	// Bearbeiten: Betrag und Aufteilung ändern.
	v := g.form()
	v.Set("betrag", "45,00")
	v.Set("aufteilung", "shares")
	v.Set("wert_"+id(g.anna), "1")
	v.Set("wert_"+id(g.ben), "2")
	v.Del("teil")
	v.Add("teil", id(g.anna))
	v.Add("teil", id(g.ben))
	status, loc, body := g.post(path, v)
	if status != http.StatusSeeOther || loc != "/" {
		t.Fatalf("POST %s: %d %s", path, status, errorOf(body))
	}
	got, _ := g.d.Store.GetExpense(context.Background(), e.ID)
	if got.AmountCents != 4500 || shares(got)[g.ben] != 3000 || len(got.Shares) != 2 {
		t.Errorf("nach Bearbeiten: %+v", got.Shares)
	}
	status, body = g.get(path)
	if status != 200 || !strings.Contains(body, `name="wert_`+id(g.ben)+`" value="2"`) || !strings.Contains(body, "geändert") ||
		!strings.Contains(body, "<del>30,00 €</del> → <ins>45,00 €</ins>") {
		t.Errorf("Formular/Verlauf nach Bearbeiten falsch")
	}

	// Fehler beim Bearbeiten: 422, nichts geändert.
	v.Set("betrag", "")
	if status, _, _ := g.post(path, v); status != http.StatusUnprocessableEntity {
		t.Errorf("leerer Betrag: %d", status)
	}

	// Löschen.
	status, loc, _ = g.post(path+"/loeschen", nil)
	if status != http.StatusSeeOther || loc != "/" {
		t.Fatalf("Löschen: %d %q", status, loc)
	}
	got, _ = g.d.Store.GetExpense(context.Background(), e.ID)
	if !got.Deleted() {
		t.Error("nicht gelöscht")
	}
	status, body = g.get(path)
	if status != 200 || !strings.Contains(body, "Gelöschte Ausgabe") || !strings.Contains(body, "<fieldset class=\"stack\" disabled>") {
		t.Errorf("gelöschte Ausgabe: %d", status)
	}
	if status, _, _ := g.post(path, g.form()); status != http.StatusConflict {
		t.Errorf("gelöschte bearbeiten: %d", status)
	}
	if status, _, _ := g.post(path+"/loeschen", nil); status != http.StatusNotFound {
		t.Errorf("doppelt löschen: %d", status)
	}
	if status, _ := g.get("/ausgaben/999"); status != http.StatusNotFound {
		t.Errorf("unbekannte Ausgabe: %d", status)
	}
	if status, _ := g.get("/ausgaben/abc"); status != http.StatusNotFound {
		t.Errorf("ungültige ID: %d", status)
	}
	if _, body := g.get("/"); strings.Contains(body, "Einkauf") {
		t.Error("gelöschte Ausgabe in der Liste")
	}
}

func TestExpenseForeignCurrency(t *testing.T) {
	g := newGroup(t, fakeFX{"USD": 1.25, "JPY": 160})
	ctx := context.Background()

	// Ohne Kurs im Formular: Kurs über FX.
	v := g.form()
	v.Set("waehrung", "USD")
	v.Set("betrag", "10,00")
	e := g.create(v)
	if e.OriginalCurrency != "USD" || e.OriginalAmountMinor != 1000 || e.FXRate != 1.25 || e.FXSource != domain.FXSourceECB || e.AmountCents != 800 {
		t.Errorf("USD über FX: %+v", e.ExpenseInput)
	}

	// Kurs von Hand → manuell; „Andere“ Währung mit ISO-Code.
	v = g.form()
	v.Set("waehrung", "")
	v.Set("waehrung_andere", "thb")
	v.Set("betrag", "100")
	v.Set("kurs", "40")
	e = g.create(v)
	if e.OriginalCurrency != "THB" || e.FXRate != 40 || e.FXSource != domain.FXSourceManual || e.AmountCents != 250 {
		t.Errorf("THB manuell: %+v", e.ExpenseInput)
	}

	// Vom Formular übernommener EZB-Kurs bleibt „ezb“.
	v = g.form()
	v.Set("waehrung", "JPY")
	v.Set("betrag", "1600")
	v.Set("kurs", "160")
	v.Set("kurs_quelle", "ezb")
	e = g.create(v)
	if e.OriginalAmountMinor != 1600 || e.AmountCents != 1000 || e.FXSource != domain.FXSourceECB {
		t.Errorf("JPY: %+v", e.ExpenseInput)
	}

	// Kein Kurs verfügbar → verständliche Meldung.
	v = g.form()
	v.Set("waehrung", "CHF")
	v.Set("betrag", "10")
	status, _, body := g.post("/ausgaben/neu", v)
	if status != http.StatusUnprocessableEntity || !strings.Contains(errorOf(body), "Kurs bitte von Hand eintragen") {
		t.Errorf("ohne Kurs: %d %q", status, errorOf(body))
	}

	// Nach Beträgen in Fremdwährung: Beträge in USD, gespeichert in Euro-Cent.
	v = g.form()
	v.Set("waehrung", "USD")
	v.Set("betrag", "10,00")
	v.Set("kurs", "1,5")
	v.Set("aufteilung", "amount")
	v.Del("teil")
	v.Add("teil", id(g.anna))
	v.Add("teil", id(g.ben))
	v.Set("wert_"+id(g.anna), "6,00")
	v.Set("wert_"+id(g.ben), "4")
	e = g.create(v)
	if e.AmountCents != 667 || shares(e)[g.anna] != 400 || shares(e)[g.ben] != 267 {
		t.Errorf("Beträge in USD: %d %v", e.AmountCents, shares(e))
	}
	// Das Bearbeiten-Formular zeigt die Beträge wieder in USD.
	_, body = g.get("/ausgaben/" + id(e.ID))
	if !strings.Contains(body, `name="wert_`+id(g.anna)+`" value="6,00"`) || !strings.Contains(body, `name="wert_`+id(g.ben)+`" value="4,00"`) ||
		!strings.Contains(body, `<option value="USD" selected>`) || !strings.Contains(body, `name="kurs" value="1,5"`) {
		t.Error("Formular zeigt Fremdwährungsbeträge nicht")
	}
	// Summe in USD falsch → Fehler in USD.
	v.Set("wert_"+id(g.ben), "3")
	status, _, body = g.post("/ausgaben/neu", v)
	if status != http.StatusUnprocessableEntity || !strings.Contains(errorOf(body), "10,00 USD") {
		t.Errorf("falsche USD-Summe: %d %q", status, errorOf(body))
	}

	// Liste zeigt den Originalbetrag klein.
	_, body = g.get("/")
	if !strings.Contains(body, "10,00 USD") || !strings.Contains(body, "8,00 €") {
		t.Error("Liste ohne Originalbetrag")
	}
	n, _ := g.d.Store.ListExpenses(ctx, store.ExpenseFilter{})
	if len(n) != 4 {
		t.Errorf("%d Ausgaben", len(n))
	}
}

func TestExpenseForeignWithoutFX(t *testing.T) {
	g := newGroup(t, nil) // d.FX == nil
	v := g.form()
	v.Set("waehrung", "USD")
	v.Set("betrag", "10")
	status, _, body := g.post("/ausgaben/neu", v)
	if status != http.StatusUnprocessableEntity || !strings.Contains(errorOf(body), "Kurs bitte von Hand eintragen") {
		t.Errorf("FX nil: %d %q", status, errorOf(body))
	}
}

func TestReimbursementFromSuggestion(t *testing.T) {
	g := newGroup(t, nil)
	g.create(g.form()) // Anna zahlt 30 € für alle → Ben und Cleo schulden je 10 €.

	status, body := g.get("/salden")
	if status != 200 || !strings.Contains(body, "<strong>Ben</strong> schuldet <strong>Anna</strong>") {
		t.Fatalf("/salden: %d", status)
	}
	link := "/ausgaben/neu?" + url.Values{"rueckzahlung": {"1"}, "von": {id(g.ben)}, "an": {id(g.anna)}, "betrag": {"1000"}}.Encode()
	if !strings.Contains(body, `href="`+link+`"`) {
		t.Fatalf("Link %q fehlt", link)
	}
	for _, want := range []string{"Anna", "20,00 €", "-10,00 €", "width: 100%", "width: 50%"} {
		if !strings.Contains(body, want) {
			t.Errorf("/salden enthält nicht %q", want)
		}
	}

	// Formular ist als Rückzahlung vorbefüllt.
	status, body = g.get(link)
	if status != 200 || !strings.Contains(body, `id="rueckzahlung" name="rueckzahlung" value="1" checked`) ||
		!strings.Contains(body, `value="Rückzahlung"`) || !strings.Contains(body, `value="10,00"`) ||
		!strings.Contains(body, `<option value="`+id(g.ben)+`" selected>Ben`) ||
		!strings.Contains(body, `name="teil" value="`+id(g.anna)+`" checked`) ||
		strings.Contains(body, `name="teil" value="`+id(g.cleo)+`" checked`) {
		t.Fatalf("Rückzahlungsformular nicht vorbefüllt")
	}

	// Absenden wie vorbefüllt.
	v := url.Values{
		"titel": {"Rückzahlung"}, "datum": {"2026-10-01"}, "waehrung": {"EUR"}, "betrag": {"10,00"},
		"bezahlt_von": {id(g.ben)}, "rueckzahlung": {"1"}, "aufteilung": {"shares"}, "teil": {id(g.anna)},
	}
	e := g.create(v)
	if !e.IsReimbursement || e.SplitMode != domain.SplitEqual || e.PaidBy != g.ben || shares(e)[g.anna] != 1000 {
		t.Errorf("Rückzahlung: %+v", e)
	}
	b, _ := g.d.Store.Balances(context.Background())
	if b[g.anna] != 1000 || b[g.ben] != 0 || b[g.cleo] != -1000 {
		t.Errorf("Salden nach Rückzahlung: %v", b)
	}
	_, body = g.get("/")
	if !strings.Contains(body, `class="expense reimbursement"`) || !strings.Contains(body, "<strong>Ben</strong> an <strong>Anna</strong>") {
		t.Error("Rückzahlung in der Liste nicht abgesetzt")
	}
	_, body = g.get("/salden")
	if strings.Contains(body, "<strong>Ben</strong> schuldet") || !strings.Contains(body, "<strong>Cleo</strong> schuldet <strong>Anna</strong>") {
		t.Error("Vorschlag nach Rückzahlung falsch")
	}
}

func TestHomeSearch(t *testing.T) {
	g := newGroup(t, nil)
	cats, _ := g.d.Store.ListCategories(context.Background(), false)
	g.create(g.form())
	v := g.form()
	v.Set("titel", "Kinoabend")
	v.Set("kategorie", id(cats[6].ID)) // Freizeit
	v.Del("teil")
	v.Add("teil", id(g.ben))
	g.create(v)

	tests := []struct {
		query     string
		want, not string
	}{
		{"q=kino", "Kinoabend", ">Einkauf<"},
		{"kategorie=" + id(g.food), ">Einkauf<", "Kinoabend"},
		{"person=" + id(g.cleo), ">Einkauf<", "Kinoabend"},
		{"q=gibtsnicht", "Keine Ausgaben gefunden", "Kinoabend"},
	}
	for _, tt := range tests {
		status, body := g.get("/?" + tt.query)
		if status != 200 || !strings.Contains(body, tt.want) || strings.Contains(body, tt.not) {
			t.Errorf("?%s: %d, want %q ohne %q", tt.query, status, tt.want, tt.not)
		}
	}
	_, body := g.get("/?person=" + id(g.cleo))
	if !strings.Contains(body, `<option value="`+id(g.cleo)+`" selected>Cleo`) || !strings.Contains(body, "Filter zurücksetzen") {
		t.Error("Filter nicht vorausgewählt")
	}
	// Anna ist an „Kinoabend“ beteiligt (zahlt), Ben hat den Anteil.
	_, body = g.get("/?q=kino")
	if !strings.Contains(body, "für <strong>Ben</strong>") {
		t.Error("„für Ben“ fehlt")
	}
}

func TestNewExpenseDefaults(t *testing.T) {
	g := newGroup(t, nil)
	g.d.Store.SetParticipantArchived(context.Background(), g.cleo, true)
	status, body := g.get("/ausgaben/neu")
	if status != 200 {
		t.Fatalf("Status %d", status)
	}
	for _, want := range []string{
		`value="` + g.d.Today().Format(domain.DateLayout) + `"`,
		`<option value="` + id(g.anna) + `" selected>Anna`,
		`name="teil" value="` + id(g.anna) + `" checked`,
		`name="teil" value="` + id(g.ben) + `" checked`,
		`<option value="EUR" selected>`,
		`<option value="equal" selected>Gleichmäßig`,
		"/static/expense-form.js?v=",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("Formular enthält nicht %q", want)
		}
	}
	if strings.Contains(body, "Cleo") {
		t.Error("archivierte Person im neuen Formular")
	}
}

func TestActivityPage(t *testing.T) {
	g := newGroup(t, nil)
	e := g.create(g.form())
	v := g.form()
	v.Set("titel", "Einkauf groß")
	g.post("/ausgaben/"+id(e.ID), v)
	g.post("/ausgaben/"+id(e.ID)+"/loeschen", nil)
	g.d.Store.AddActivity(context.Background(), 0, "recurring_created", 0, store.ActivityDetails{Text: "Regel angelegt"})

	status, body := g.get("/aktivitaet")
	if status != 200 {
		t.Fatalf("Status %d", status)
	}
	for _, want := range []string{
		"Heute", "<strong>Anna</strong> hat <em>„Einkauf“</em> angelegt", "<em>„Einkauf groß“</em> geändert",
		"<em>„Einkauf groß“</em> gelöscht", "Titel: <del>Einkauf</del> → <ins>Einkauf groß</ins>",
		`href="/ausgaben/` + id(e.ID) + `"`, "<strong>Automatisch</strong>: Regel angelegt",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("/aktivitaet enthält nicht %q", want)
		}
	}
}

func TestActivityPaging(t *testing.T) {
	g := newGroup(t, nil)
	ctx := context.Background()
	for i := range activityPageSize + 5 {
		g.d.Store.AddActivity(ctx, g.anna, "test", 0, store.ActivityDetails{Text: "Eintrag " + strconv.Itoa(i)})
	}
	_, body := g.get("/aktivitaet")
	if !strings.Contains(body, "Eintrag 54") || strings.Contains(body, "Eintrag 4<") || !strings.Contains(body, "/aktivitaet?vor=") {
		t.Fatal("erste Seite falsch")
	}
	i := strings.Index(body, "/aktivitaet?vor=")
	next := body[i : i+strings.IndexByte(body[i:], '"')]
	_, body = g.get(next)
	if !strings.Contains(body, "Eintrag 4<") || strings.Contains(body, "Eintrag 54") || strings.Contains(body, "Ältere anzeigen") {
		t.Error("zweite Seite falsch")
	}
}
