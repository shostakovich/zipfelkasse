package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

const serverVersion = "1.0.0"

func serverInfo() map[string]any {
	return map[string]any{"name": "zipfelkasse", "title": "Zipfelkasse – geteilte Ausgaben", "version": serverVersion}
}

// instructionsText explains the server to the model (initialize,
// server/discover); instructions() appends today's date.
const instructionsText = `Zipfelkasse ist die Ausgabenverwaltung einer einzigen Gruppe (wie Splitwise/Spliit). Alle Tools sind nur lesend.
Beträge sind Euro. In Ergebnissen steht jeder Betrag zweimal: als Text „1234,56“ und als Ganzzahl in Cent (Feld mit Endung _cent).
Saldo: positiv = bekommt Geld von den anderen, negativ = schuldet Geld.
Rückzahlungen sind Ausgleichszahlungen zwischen zwei Personen, keine Ausgaben; sie zählen für Salden, nicht für Ausgaben-Statistiken.
Datumsangaben im Format JJJJ-MM-TT. Personen und Kategorien mit ihrem Namen angeben (Groß-/Kleinschreibung egal).
Vorgehen: Salden und Ausgleich → salden. Einzelne Buchungen finden → ausgaben_suchen. Summen nach Kategorie, Monat oder Person → statistik.
Alles andere → zuerst schema lesen, dann sql_abfrage (SQLite, nur SELECT).`

// categoryHint explains the kategorie value for expenses without a category.
const categoryHint = `Use "ohne" for expenses without a category (statistik shows them as "` + store.NoCategory + `").`

// server ist der MCP-Handler mit seinen Tools.
type server struct {
	d      web.Deps
	log    *slog.Logger
	order  []string // Tool-Reihenfolge für tools/list (deterministisch)
	tools  map[string]tool
	sqlSem chan struct{} // begrenzt parallele sql_abfrage-Sandboxen
	now    func() time.Time
}

// location is the server time zone (TZ).
func (s *server) location() *time.Location {
	if s.d.Config.Location != nil {
		return s.d.Config.Location
	}
	return time.Local
}

// todayLine states the current date in the server time zone. It is computed
// per request so that long-running servers never report a stale date.
func (s *server) todayLine() string {
	loc := s.location()
	today := domain.DateOf(s.now().In(loc))
	return fmt.Sprintf("Today is %s (%s), server time zone %s. Resolve relative periods such as \"last month\" from this date.",
		today.Format(domain.DateLayout), today.Weekday(), loc)
}

func (s *server) instructions() string { return instructionsText + "\n" + s.todayLine() }

// discoverTTL caches server/discover (which contains the date) at most until
// the next midnight in the server time zone.
func (s *server) discoverTTL() time.Duration {
	now := s.now().In(s.location())
	y, m, d := now.Date()
	return min(listTTL, time.Date(y, m, d+1, 0, 0, 0, 0, now.Location()).Sub(now))
}

type tool struct {
	def map[string]any
	run func(ctx context.Context, args json.RawMessage) (toolResult, error)
}

// toolResult: data wird structuredContent (und, ohne text, als JSON der
// Textinhalt).
type toolResult struct {
	text string
	data any
}

func newServer(d web.Deps) *server {
	s := &server{d: d, log: newLogger(d), tools: map[string]tool{}, sqlSem: make(chan struct{}, 2), now: time.Now}
	readOnly := map[string]any{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
	add := func(name, title, desc string, schema map[string]any, run func(context.Context, json.RawMessage) (toolResult, error)) {
		s.order = append(s.order, name)
		s.tools[name] = tool{
			def: map[string]any{"name": name, "title": title, "description": desc, "inputSchema": schema, "annotations": readOnly},
			run: run,
		}
	}
	dateProp := func(desc string) map[string]any {
		return map[string]any{"type": "string", "description": desc + " Format JJJJ-MM-TT (auch TT.MM.JJJJ)."}
	}

	add("salden", "Salden und Ausgleich",
		"Aktueller Saldo jeder Person in Euro und ein Ausgleichsvorschlag (wer überweist wem wie viel, damit alle bei 0 sind). "+
			"Positiver Saldo = bekommt Geld, negativer = schuldet Geld. Berücksichtigt alle nicht gelöschten Ausgaben und Rückzahlungen.",
		map[string]any{"type": "object", "properties": map[string]any{}, "additionalProperties": false},
		s.salden)

	add("ausgaben_suchen", "Ausgaben suchen",
		"Sucht einzelne Ausgaben (neueste zuerst) mit Betrag, Zahler, Kategorie und Aufteilung (Anteil jeder Person). "+
			"Alle Filter sind optional und werden kombiniert. Liefert außerdem die Gesamtzahl der Treffer, deren Summe und – mit person – "+
			"die Summe der Anteile dieser Person. Für reine Summen nach Kategorie/Monat ist statistik besser.",
		map[string]any{
			"type": "object",
			"properties": map[string]any{
				"von":       dateProp("Erstes Datum (inklusive)."),
				"bis":       dateProp("Letztes Datum (inklusive)."),
				"kategorie": map[string]any{"type": "string", "description": "Name der Kategorie, z. B. „Lebensmittel“. " + categoryHint},
				"person":    map[string]any{"type": "string", "description": "Name einer Person: findet Ausgaben, die sie bezahlt hat ODER an denen sie beteiligt ist."},
				"text":      map[string]any{"type": "string", "description": "Teilstring in Titel oder Notiz (Groß-/Kleinschreibung egal)."},
				"rueckzahlungen": map[string]any{"type": "string", "enum": []string{"ohne", "mit", "nur"},
					"description": "Rückzahlungen (Ausgleichszahlungen zwischen Personen) ausblenden (ohne, Standard), mitliefern (mit) oder nur diese (nur)."},
				"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 500, "description": "Höchstzahl gelieferter Ausgaben, Standard 50."},
			},
			"additionalProperties": false,
		},
		s.ausgabenSuchen)

	add("statistik", "Statistik",
		"Summen der Ausgaben gruppiert nach kategorie, monat (JJJJ-MM), person oder kategorie_monat, optional für einen Zeitraum. "+
			"Ohne person: Gesamtbeträge der Ausgaben. Mit person: nur der Anteil dieser Person an jeder Ausgabe, also was sie selbst verbraucht hat "+
			"(z. B. „Wie viel habe ich 2026 für Restaurants ausgegeben?“). Bei gruppierung=person ist summe der Anteil (Verbrauch) jeder Person "+
			"und bezahlt, was sie vorgestreckt hat. Rückzahlungen und gelöschte Ausgaben zählen nie mit.",
		map[string]any{
			"type": "object",
			"properties": map[string]any{
				"gruppierung": map[string]any{"type": "string", "enum": []string{store.StatsByCategory, store.StatsByMonth, store.StatsByPerson, store.StatsByCategoryMonth},
					"description": "Wonach gruppiert wird."},
				"von":       dateProp("Erstes Datum (inklusive)."),
				"bis":       dateProp("Letztes Datum (inklusive)."),
				"person":    map[string]any{"type": "string", "description": "Name einer Person: nur ihr Anteil zählt (Sicht dieser Person). Leer = Gesamtbeträge."},
				"kategorie": map[string]any{"type": "string", "description": "Only count expenses of this category (name, case-insensitive). " + categoryHint},
			},
			"required":             []string{"gruppierung"},
			"additionalProperties": false,
		},
		s.statistik)

	add("schema", "Datenbankschema",
		"Erklärt die Tabellen und Spalten der Datenbank in Worten (Beträge in Cent, gelöschte Ausgaben, Rückzahlungen, Anteile, Fremdwährung), "+
			"listet Personen und Kategorien und liefert die CREATE-Statements. Vor sql_abfrage aufrufen.",
		map[string]any{"type": "object", "properties": map[string]any{}, "additionalProperties": false},
		s.schema)

	add("sql_abfrage", "SQL-Abfrage",
		fmt.Sprintf("Führt genau eine lesende SQL-Abfrage (SQLite-Dialekt, nur SELECT bzw. WITH … SELECT) auf einer schreibgeschützten Kopie der Daten aus. "+
			"Vorher schema aufrufen. Wichtig: Beträge sind Cent (für Euro durch 100.0 teilen), gelöschte Ausgaben mit deleted_at IS NULL ausschließen, "+
			"Rückzahlungen (is_reimbursement = 1) sind keine Ausgaben, den Anteil einer Person liefert expense_shares.amount_cents. "+
			"Höchstens %d Zeilen, Abbruch nach %d Sekunden, Texte über 2000 Zeichen werden gekürzt. "+
			"Für Standardfragen sind salden, ausgaben_suchen und statistik einfacher.", store.SQLMaxRows, int(store.SQLTimeout/time.Second)),
		map[string]any{
			"type": "object",
			"properties": map[string]any{
				"abfrage": map[string]any{"type": "string", "description": "Die SQL-Abfrage, z. B. SELECT name FROM participants WHERE archived_at IS NULL"},
			},
			"required":             []string{"abfrage"},
			"additionalProperties": false,
		},
		s.sqlAbfrage)
	return s
}

func (s *server) toolDefs() []any {
	out := make([]any, len(s.order))
	for i, name := range s.order {
		out[i] = s.tools[name].def
	}
	return out
}

func invalid(format string, args ...any) error {
	return domain.ValidationError{Msg: fmt.Sprintf(format, args...)}
}

// decodeArgs liest die Tool-Argumente streng (unbekannte Felder sind Fehler).
func decodeArgs(raw json.RawMessage, v any) error {
	if b := bytes.TrimSpace(raw); len(b) == 0 || string(b) == "null" {
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return invalid("Ungültige Parameter: %v", err)
	}
	return nil
}

// eur formatiert Cent als „1234,56“ (ohne Tausenderpunkte und €).
func eur(c int64) string { return domain.FormatCentsInput(c) }

func parseDateArg(name, v string) (time.Time, error) {
	if v = strings.TrimSpace(v); v == "" {
		return time.Time{}, nil
	}
	t, err := domain.ParseDate(v)
	if err != nil {
		return time.Time{}, invalid("Ungültiges Datum für %s: „%s“ (erwartet JJJJ-MM-TT).", name, v)
	}
	return t, nil
}

func parseRange(von, bis string) (time.Time, time.Time, error) {
	from, err := parseDateArg("von", von)
	if err != nil {
		return from, from, err
	}
	to, err := parseDateArg("bis", bis)
	if err != nil {
		return from, to, err
	}
	if !from.IsZero() && !to.IsZero() && to.Before(from) {
		return from, to, invalid("„bis“ (%s) liegt vor „von“ (%s).", domain.FormatDate(to), domain.FormatDate(from))
	}
	return from, to, nil
}

func describeRange(from, to time.Time) string {
	switch {
	case from.IsZero() && to.IsZero():
		return "gesamter Zeitraum"
	case to.IsZero():
		return "ab " + from.Format(domain.DateLayout)
	case from.IsZero():
		return "bis " + to.Format(domain.DateLayout)
	}
	return from.Format(domain.DateLayout) + " bis " + to.Format(domain.DateLayout)
}

// participantNames liefert id → Name aller Personen (auch archivierte).
func (s *server) participantNames(ctx context.Context) (map[int64]string, []store.Participant, error) {
	ps, err := s.d.Store.ListParticipants(ctx, true)
	if err != nil {
		return nil, nil, err
	}
	m := make(map[int64]string, len(ps))
	for _, p := range ps {
		m[p.ID] = p.Name
	}
	return m, ps, nil
}

func (s *server) findPerson(ctx context.Context, name string) (store.Participant, error) {
	_, ps, err := s.participantNames(ctx)
	if err != nil {
		return store.Participant{}, err
	}
	name = strings.TrimSpace(name)
	names := make([]string, 0, len(ps))
	for _, p := range ps {
		if strings.EqualFold(p.Name, name) {
			return p, nil
		}
		names = append(names, p.Name)
	}
	return store.Participant{}, invalid("Unbekannte Person „%s“. Vorhanden: %s.", name, strings.Join(names, ", "))
}

func (s *server) findCategory(ctx context.Context, name string) (store.Category, error) {
	cs, err := s.d.Store.ListCategories(ctx, true)
	if err != nil {
		return store.Category{}, err
	}
	name = strings.TrimSpace(name)
	names := make([]string, 0, len(cs))
	for _, c := range cs {
		if strings.EqualFold(c.Name, name) {
			return c, nil
		}
		names = append(names, c.Name)
	}
	return store.Category{}, invalid("Unbekannte Kategorie „%s“. Vorhanden: %s.", name, strings.Join(names, ", "))
}

// categoryArg resolves a kategorie argument: a category name, or "ohne" /
// "Ohne Kategorie" (the statistik label) for expenses without a category.
// A real category with that name takes precedence.
func (s *server) categoryArg(ctx context.Context, name string) (id int64, without bool, err error) {
	if strings.TrimSpace(name) == "" {
		return 0, false, nil
	}
	c, err := s.findCategory(ctx, name)
	if err == nil {
		return c.ID, false, nil
	}
	if n := strings.TrimSpace(name); strings.EqualFold(n, noCategoryArg) || strings.EqualFold(n, store.NoCategory) {
		return 0, true, nil
	}
	return 0, false, err
}

// noCategoryArg is the kategorie value for expenses without a category.
const noCategoryArg = "ohne"

// --- salden ------------------------------------------------------------------

type balanceOut struct {
	Person    string `json:"person"`
	Saldo     string `json:"saldo"`
	SaldoCent int64  `json:"saldo_cent"`
	Status    string `json:"status"`
}

type transferOut struct {
	Von        string `json:"von"`
	An         string `json:"an"`
	Betrag     string `json:"betrag"`
	BetragCent int64  `json:"betrag_cent"`
}

func (s *server) salden(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct{}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	bal, err := s.d.Store.Balances(ctx)
	if err != nil {
		return toolResult{}, err
	}
	names, ps, err := s.participantNames(ctx)
	if err != nil {
		return toolResult{}, err
	}
	salden := []balanceOut{}
	for _, p := range ps {
		v := bal[p.ID]
		if p.Archived() && v == 0 {
			continue
		}
		status := "ausgeglichen"
		switch {
		case v > 0:
			status = "bekommt Geld"
		case v < 0:
			status = "schuldet Geld"
		}
		salden = append(salden, balanceOut{Person: p.Name, Saldo: eur(v), SaldoCent: v, Status: status})
	}
	ausgleich := []transferOut{}
	for _, t := range domain.Settle(bal) {
		ausgleich = append(ausgleich, transferOut{Von: names[t.From], An: names[t.To], Betrag: eur(t.AmountCents), BetragCent: t.AmountCents})
	}
	return toolResult{data: map[string]any{
		"salden":    salden,
		"ausgleich": ausgleich,
		"hinweis":   "Saldo positiv = bekommt Geld, negativ = schuldet Geld. ausgleich: so viele Überweisungen wie nötig, damit alle bei 0 sind.",
	}}, nil
}

// --- ausgaben_suchen -----------------------------------------------------------

type shareOut struct {
	Person     string `json:"person"`
	Betrag     string `json:"betrag"`
	BetragCent int64  `json:"betrag_cent"`
}

type expenseOut struct {
	ID           int64      `json:"id"`
	Datum        string     `json:"datum"`
	Titel        string     `json:"titel"`
	Kategorie    string     `json:"kategorie,omitempty"`
	BezahltVon   string     `json:"bezahlt_von"`
	Betrag       string     `json:"betrag"`
	BetragCent   int64      `json:"betrag_cent"`
	Rueckzahlung bool       `json:"rueckzahlung,omitempty"`
	An           string     `json:"an,omitempty"` // Empfänger einer Rückzahlung
	Original     string     `json:"original,omitempty"`
	Kurs         float64    `json:"kurs,omitempty"`
	KursQuelle   string     `json:"kurs_quelle,omitempty"`
	Notiz        string     `json:"notiz,omitempty"`
	Aufteilung   string     `json:"aufteilung,omitempty"`
	Anteile      []shareOut `json:"anteile,omitempty"`
}

func (s *server) ausgabenSuchen(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct {
		Von            string `json:"von"`
		Bis            string `json:"bis"`
		Kategorie      string `json:"kategorie"`
		Person         string `json:"person"`
		Text           string `json:"text"`
		Rueckzahlungen string `json:"rueckzahlungen"`
		Limit          int    `json:"limit"`
	}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	var f store.ExpenseFilter
	var err error
	if f.From, f.To, err = parseRange(args.Von, args.Bis); err != nil {
		return toolResult{}, err
	}
	f.Text = strings.TrimSpace(args.Text)
	if f.CategoryID, f.WithoutCategory, err = s.categoryArg(ctx, args.Kategorie); err != nil {
		return toolResult{}, err
	}
	var person store.Participant
	if strings.TrimSpace(args.Person) != "" {
		if person, err = s.findPerson(ctx, args.Person); err != nil {
			return toolResult{}, err
		}
		f.ParticipantID = person.ID
	}
	mode := cmpOr(args.Rueckzahlungen, "ohne")
	if !slices.Contains([]string{"ohne", "mit", "nur"}, mode) {
		return toolResult{}, invalid("rueckzahlungen muss „ohne“, „mit“ oder „nur“ sein.")
	}
	limit := args.Limit
	switch {
	case limit == 0:
		limit = 50
	case limit < 1 || limit > store.SQLMaxRows:
		return toolResult{}, invalid("limit muss zwischen 1 und %d liegen.", store.SQLMaxRows)
	}

	es, err := s.d.Store.ListExpenses(ctx, f)
	if err != nil {
		return toolResult{}, err
	}
	names, _, err := s.participantNames(ctx)
	if err != nil {
		return toolResult{}, err
	}
	var sum, share int64
	hits := 0
	out := []expenseOut{}
	for _, e := range es {
		if (mode == "ohne" && e.IsReimbursement) || (mode == "nur" && !e.IsReimbursement) {
			continue
		}
		hits++
		sum += e.AmountCents
		share += e.ShareOf(person.ID)
		if len(out) < limit {
			out = append(out, expenseToOut(e, names))
		}
	}
	data := map[string]any{
		"treffer":    hits,
		"angezeigt":  len(out),
		"gekuerzt":   hits > len(out),
		"summe":      eur(sum),
		"summe_cent": sum,
		"ausgaben":   out,
	}
	if person.ID != 0 {
		data["anteil_person"] = map[string]any{"person": person.Name, "summe": eur(share), "summe_cent": share}
	}
	return toolResult{data: data}, nil
}

func expenseToOut(e store.Expense, names map[int64]string) expenseOut {
	o := expenseOut{
		ID: e.ID, Datum: e.Date.Format(domain.DateLayout), Titel: e.Title, Kategorie: e.CategoryName,
		BezahltVon: e.PaidByName, Betrag: eur(e.AmountCents), BetragCent: e.AmountCents, Notiz: e.Notes,
	}
	if e.IsForeign() {
		o.Original = domain.FormatMoney(e.OriginalAmountMinor, e.OriginalCurrency)
		o.Kurs, o.KursQuelle = e.FXRate, e.FXSource
	}
	if e.IsReimbursement {
		o.Rueckzahlung = true
		if len(e.Shares) > 0 {
			o.An = names[e.Shares[0].ParticipantID]
		}
		return o
	}
	o.Aufteilung = e.SplitMode.Label()
	for _, sh := range e.Shares {
		o.Anteile = append(o.Anteile, shareOut{Person: names[sh.ParticipantID], Betrag: eur(sh.AmountCents), BetragCent: sh.AmountCents})
	}
	return o
}

func cmpOr(v, fallback string) string {
	if v = strings.TrimSpace(v); v != "" {
		return v
	}
	return fallback
}

// --- statistik -------------------------------------------------------------------

type statOut struct {
	Kategorie   string `json:"kategorie,omitempty"`
	Monat       string `json:"monat,omitempty"`
	Person      string `json:"person,omitempty"`
	Anzahl      int64  `json:"anzahl"`
	Summe       string `json:"summe"`
	SummeCent   int64  `json:"summe_cent"`
	Bezahlt     string `json:"bezahlt,omitempty"`
	BezahltCent *int64 `json:"bezahlt_cent,omitempty"`
}

func (s *server) statistik(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct {
		Gruppierung string `json:"gruppierung"`
		Von         string `json:"von"`
		Bis         string `json:"bis"`
		Person      string `json:"person"`
		Kategorie   string `json:"kategorie"`
	}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	f := store.StatsFilter{GroupBy: strings.TrimSpace(args.Gruppierung)}
	valid := []string{store.StatsByCategory, store.StatsByMonth, store.StatsByPerson, store.StatsByCategoryMonth}
	if !slices.Contains(valid, f.GroupBy) {
		return toolResult{}, invalid("gruppierung muss eine von %s sein.", strings.Join(valid, ", "))
	}
	var err error
	if f.From, f.To, err = parseRange(args.Von, args.Bis); err != nil {
		return toolResult{}, err
	}
	if f.CategoryID, f.WithoutCategory, err = s.categoryArg(ctx, args.Kategorie); err != nil {
		return toolResult{}, err
	}
	view := "Gesamtbeträge der Ausgaben"
	if strings.TrimSpace(args.Person) != "" {
		p, err := s.findPerson(ctx, args.Person)
		if err != nil {
			return toolResult{}, err
		}
		f.ParticipantID = p.ID
		view = "nur der Anteil von " + p.Name
	}
	rows, err := s.d.Store.Stats(ctx, f)
	if err != nil {
		return toolResult{}, err
	}
	var total int64
	out := []statOut{}
	for _, r := range rows {
		o := statOut{Kategorie: r.Category, Monat: r.Month, Person: r.Person, Anzahl: r.Count, Summe: eur(r.AmountCents), SummeCent: r.AmountCents}
		if f.GroupBy == store.StatsByPerson {
			paid := r.PaidCents
			o.Bezahlt, o.BezahltCent = eur(paid), &paid
		}
		total += r.AmountCents
		out = append(out, o)
	}
	hint := "Rückzahlungen und gelöschte Ausgaben sind nicht enthalten. anzahl = Zahl der Ausgaben."
	if f.GroupBy == store.StatsByPerson {
		hint += " summe = Anteil (Verbrauch) der Person, bezahlt = was sie für die Gruppe bezahlt hat."
	}
	return toolResult{data: map[string]any{
		"gruppierung": f.GroupBy,
		"sicht":       view,
		"zeitraum":    describeRange(f.From, f.To),
		"zeilen":      out,
		"gesamt":      eur(total),
		"gesamt_cent": total,
		"hinweis":     hint,
	}}, nil
}

// --- schema -----------------------------------------------------------------------

const schemaText = `Datenbank von Zipfelkasse (SQLite). Eine einzige Gruppe.
Konventionen: Beträge sind INTEGER in Euro-Cent (für Euro durch 100.0 teilen). Kalenderdaten TEXT 'JJJJ-MM-TT', Zeitstempel TEXT RFC 3339 in UTC. Wahrheitswerte 0/1.

Tabellen:
- participants: Personen der Gruppe. archived_at gesetzt = archiviert (nicht mehr aktiv, ihre Buchungen bleiben).
- categories: Kategorien (name, position = Anzeigereihenfolge, archived_at).
- expenses: Ausgaben UND Rückzahlungen.
  * deleted_at gesetzt = gelöscht (Soft-Delete) → Auswertungen IMMER mit "deleted_at IS NULL".
  * amount_cents: Betrag in Euro-Cent (bei Fremdwährung umgerechnet). paid_by: wer bezahlt hat (participants.id). category_id NULL = ohne Kategorie.
  * is_reimbursement = 1: Rückzahlung – paid_by hat Geld an die Person aus dem einzigen expense_shares-Eintrag gezahlt. Das ist keine Ausgabe
    (Ausgaben-Auswertungen mit "is_reimbursement = 0"), zählt aber für Salden.
  * split_mode: equal (gleichmäßig), shares (nach Anteilen), percent (Prozent), amount (feste Beträge).
  * Fremdwährung: original_currency ('EUR' wenn keine), original_amount_minor (Betrag in der kleinsten Einheit dieser Währung),
    fx_rate (Einheiten Fremdwährung pro 1 EUR, EZB-Format), fx_source ('ezb', 'manuell' oder '' bei EUR). amount_cents ist schon umgerechnet.
  * recurring_id: automatisch aus einer wiederkehrenden Regel erzeugt. created_at/updated_at: Zeitstempel.
- expense_shares: Aufteilung jeder Ausgabe auf Personen. amount_cents = Anteil dieser Person in Cent (Summe je Ausgabe = expenses.amount_cents).
  weight je nach split_mode: equal 1, shares Anteile, percent Basispunkte (Summe 10000), amount Cent.
- recurring: Regeln für wiederkehrende Ausgaben (template_json = Vorlage als JSON, frequency weekly|monthly|yearly, start_date, next_date, active).
- activity: Änderungsprotokoll (at, actor_id NULL = System, action expense_created|expense_updated|expense_deleted, expense_id, details_json).
- fx_rates: Wechselkurse je Währung und Datum (Fremdwährung pro 1 EUR), source 'ezb' oder 'manuell'.
- settings: Einstellungen (key/value, z. B. group_name, default_currency).
YNAB-Tabellen (Zugangsdaten) sind über MCP nicht sichtbar.

Saldo einer Person = Summe amount_cents der von ihr bezahlten Ausgaben − Summe ihrer Anteile in expense_shares
(nur deleted_at IS NULL, Rückzahlungen eingeschlossen). Positiv = bekommt Geld.

Beispiel – Annas Anteil je Kategorie im Jahr 2026:
SELECT coalesce(c.name, 'Ohne Kategorie') AS kategorie, sum(x.amount_cents) / 100.0 AS euro
FROM expenses e
JOIN expense_shares x ON x.expense_id = e.id
JOIN participants p ON p.id = x.participant_id AND p.name = 'Anna'
LEFT JOIN categories c ON c.id = e.category_id
WHERE e.deleted_at IS NULL AND e.is_reimbursement = 0 AND e.date BETWEEN '2026-01-01' AND '2026-12-31'
GROUP BY 1 ORDER BY 2 DESC;
`

func (s *server) schema(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct{}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	objs, err := s.d.Store.MCPSchema(ctx)
	if err != nil {
		return toolResult{}, err
	}
	_, ps, err := s.participantNames(ctx)
	if err != nil {
		return toolResult{}, err
	}
	cs, err := s.d.Store.ListCategories(ctx, true)
	if err != nil {
		return toolResult{}, err
	}
	var b strings.Builder
	b.WriteString(s.todayLine())
	b.WriteString("\n\n")
	b.WriteString(schemaText)
	b.WriteString("\nPersonen (id: Name): ")
	for i, p := range ps {
		if i > 0 {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "%d: %s", p.ID, p.Name)
		if p.Archived() {
			b.WriteString(" (archiviert)")
		}
	}
	b.WriteString("\nKategorien (id: Name): ")
	for i, c := range cs {
		if i > 0 {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "%d: %s", c.ID, c.Name)
		if c.Archived() {
			b.WriteString(" (archiviert)")
		}
	}
	b.WriteString("\n\nCREATE-Statements:\n")
	for _, o := range objs {
		b.WriteString(o.SQL)
		b.WriteString(";\n")
	}
	return toolResult{text: b.String()}, nil
}

// --- sql_abfrage ------------------------------------------------------------------

func (s *server) sqlAbfrage(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct {
		Abfrage string `json:"abfrage"`
	}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	if strings.TrimSpace(args.Abfrage) == "" {
		return toolResult{}, invalid("Parameter abfrage fehlt.")
	}
	select {
	case s.sqlSem <- struct{}{}:
		defer func() { <-s.sqlSem }()
	case <-ctx.Done():
		return toolResult{}, invalid("Zu viele gleichzeitige Abfragen, bitte erneut versuchen.")
	}
	res, err := s.d.Store.ReadOnlyQuery(ctx, args.Abfrage)
	if err != nil {
		var ve domain.ValidationError
		if errors.As(err, &ve) {
			return toolResult{}, err
		}
		return toolResult{}, fmt.Errorf("sql_abfrage: %w", err)
	}
	data := map[string]any{
		"spalten":  res.Columns,
		"zeilen":   res.Rows,
		"anzahl":   len(res.Rows),
		"gekuerzt": res.Truncated,
	}
	if res.Truncated {
		data["hinweis"] = fmt.Sprintf("Es gibt mehr als %d Zeilen; nur die ersten %d sind enthalten. Bitte aggregieren oder mit WHERE/LIMIT einschränken.", store.SQLMaxRows, store.SQLMaxRows)
	}
	return toolResult{data: data}, nil
}
