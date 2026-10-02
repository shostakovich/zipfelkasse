package export

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"teilen/internal/domain"
	"teilen/internal/store"
	"teilen/internal/web"
	"teilen/internal/ynab"
)

func day(s string) time.Time {
	t, err := time.Parse(domain.DateLayout, s)
	if err != nil {
		panic(err)
	}
	return t
}

var (
	anna    = store.Participant{ID: 1, Name: "Anna"}
	ben     = store.Participant{ID: 2, Name: "Ben"}
	juergen = store.Participant{ID: 3, Name: "Jürgen"}
	cleo    = store.Participant{ID: 4, Name: "Cleo", ArchivedAt: day("2026-01-01")} // nirgends beteiligt
	people  = []store.Participant{anna, ben, cleo, juergen}
	stamp   = time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
)

// sample sind Ausgaben in chronologischer Reihenfolge.
func sample() []store.Expense {
	eur := func(id int64, title, date string, cents int64, cat int64, catName string, payer store.Participant, shares ...domain.Share) store.Expense {
		e := store.Expense{ID: id, ExpenseInput: store.ExpenseInput{Title: title, Date: day(date), CategoryID: cat,
			PaidBy: payer.ID, SplitMode: domain.SplitEqual, AmountCents: cents,
			OriginalAmountMinor: cents, OriginalCurrency: "EUR", FXRate: 1},
			Shares: shares, CategoryName: catName, PaidByName: payer.Name, CreatedAt: stamp, UpdatedAt: stamp}
		for _, s := range shares {
			e.Parts = append(e.Parts, domain.Part{ParticipantID: s.ParticipantID, Weight: s.Weight})
		}
		return e
	}
	sh := func(p store.Participant, cents int64) domain.Share {
		return domain.Share{ParticipantID: p.ID, Weight: 1, AmountCents: cents}
	}
	cafe := eur(1, "Café & Kuchen", "2026-09-01", 1201, 2, "Restaurant", anna, sh(anna, 601), sh(juergen, 600))
	cafe.Notes = "lecker; „süß“"
	diner := eur(2, "Diner \"NYC\"", "2026-09-03", 8000, 0, "", ben, sh(anna, 4000), sh(ben, 4000))
	diner.OriginalAmountMinor, diner.OriginalCurrency, diner.FXRate, diner.FXSource = 9000, "USD", 1.125, "ezb"
	diner.RecurringID = 7
	back := eur(3, "Rückzahlung", "2026-09-05", 600, 0, "", juergen, sh(anna, 600))
	back.IsReimbursement = true
	formula := eur(4, "=SUMME(A1)", "2026-09-10", 500, 1, "Lebensmittel", ben, sh(ben, 500))
	return []store.Expense{cafe, diner, back, formula}
}

func TestExpensesCSVGolden(t *testing.T) {
	var buf bytes.Buffer
	if err := writeExpensesCSV(&buf, people, sample()); err != nil {
		t.Fatal(err)
	}
	want := "\uFEFF" +
		"ID;Datum;Titel;Kategorie;Bezahlt von;Betrag (EUR);Originalbetrag;Währung;Kurs;Art;Aufteilung;Notiz;Anteil Anna;Anteil Ben;Anteil Jürgen\r\n" +
		"1;01.09.2026;Café & Kuchen;Restaurant;Anna;12,01;12,01;EUR;;Ausgabe;Gleichmäßig;\"lecker; „süß“\";6,01;;6,00\r\n" +
		"2;03.09.2026;\"Diner \"\"NYC\"\"\";;Ben;80,00;90,00;USD;1,125;Ausgabe;Gleichmäßig;;40,00;40,00;\r\n" +
		"3;05.09.2026;Rückzahlung;;Jürgen;6,00;6,00;EUR;;Rückzahlung;Gleichmäßig;;6,00;;\r\n" +
		"4;10.09.2026;'=SUMME(A1);Lebensmittel;Ben;5,00;5,00;EUR;;Ausgabe;Gleichmäßig;;;5,00;\r\n"
	if got := buf.String(); got != want {
		t.Errorf("CSV:\n%s\nwant:\n%s", got, want)
	}
}

func TestExpensesJSONGolden(t *testing.T) {
	var buf bytes.Buffer
	es := sample()[1:2]
	now := time.Date(2026, 10, 2, 12, 0, 0, 0, time.UTC)
	if err := writeExpensesJSON(&buf, "WG Süd", now, period{From: day("2026-09-01")}, people[:2], es); err != nil {
		t.Fatal(err)
	}
	want := `{
  "group": "WG Süd",
  "exported_at": "2026-10-02T12:00:00Z",
  "from": "2026-09-01",
  "currency": "EUR",
  "participants": [
    {
      "id": 1,
      "name": "Anna",
      "archived": false
    },
    {
      "id": 2,
      "name": "Ben",
      "archived": false
    }
  ],
  "expenses": [
    {
      "id": 2,
      "date": "2026-09-03",
      "title": "Diner \"NYC\"",
      "category_id": null,
      "category": "",
      "paid_by": 2,
      "paid_by_name": "Ben",
      "amount_cents": 8000,
      "is_reimbursement": false,
      "split_mode": "equal",
      "original_amount_minor": 9000,
      "original_currency": "USD",
      "fx_rate": 1.125,
      "fx_source": "ezb",
      "notes": "",
      "recurring_id": 7,
      "shares": [
        {
          "participant_id": 1,
          "name": "Anna",
          "weight": 1,
          "amount_cents": 4000
        },
        {
          "participant_id": 2,
          "name": "Ben",
          "weight": 1,
          "amount_cents": 4000
        }
      ],
      "created_at": "2026-09-01T10:00:00Z",
      "updated_at": "2026-09-01T10:00:00Z"
    }
  ]
}
`
	if got := buf.String(); got != want {
		t.Errorf("JSON:\n%s\nwant:\n%s", got, want)
	}
}

func TestYNABPostingsMatchSync(t *testing.T) {
	ps := ynab.Selection{Today: day("2026-10-02")}.Postings(sample(), anna.ID)
	// Rückzahlung fehlt, Ausgabe 4 hat keinen Anteil von Anna.
	if len(ps) != 2 || ps[0].ExpenseID != 1 || ps[1].ExpenseID != 2 {
		t.Fatalf("postings = %+v", ps)
	}
}

func TestOFXGolden(t *testing.T) {
	ps := ynab.Selection{Today: day("2026-10-02")}.Postings(sample(), anna.ID)
	var buf bytes.Buffer
	now := time.Date(2026, 10, 2, 12, 30, 0, 0, time.UTC)
	if err := writeOFX(&buf, ps, "TEILEN-1", time.Time{}, time.Time{}, now); err != nil {
		t.Fatal(err)
	}
	want := strings.ReplaceAll(`OFXHEADER:100
DATA:OFXSGML
VERSION:102
SECURITY:NONE
ENCODING:UTF-8
CHARSET:NONE
COMPRESSION:NONE
OLDFILEUID:NONE
NEWFILEUID:NONE

<OFX>
<SIGNONMSGSRSV1>
<SONRS>
<STATUS>
<CODE>0
<SEVERITY>INFO
</STATUS>
<DTSERVER>20261002123000
<LANGUAGE>GER
</SONRS>
</SIGNONMSGSRSV1>
<BANKMSGSRSV1>
<STMTTRNRS>
<TRNUID>1
<STATUS>
<CODE>0
<SEVERITY>INFO
</STATUS>
<STMTRS>
<CURDEF>EUR
<BANKACCTFROM>
<BANKID>TEILEN
<ACCTID>TEILEN-1
<ACCTTYPE>CHECKING
</BANKACCTFROM>
<BANKTRANLIST>
<DTSTART>20260901
<DTEND>20260903
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260901
<TRNAMT>-6.01
<FITID>teilen-1
<NAME>Café &amp; Kuchen
<MEMO>Gesamt 12,01 € · bezahlt von Anna · teilen #1
</STMTTRN>
<STMTTRN>
<TRNTYPE>DEBIT
<DTPOSTED>20260903
<TRNAMT>-40.00
<FITID>teilen-2
<NAME>Diner "NYC"
<MEMO>Gesamt 80,00 € (90,00 USD) · bezahlt von Ben · teilen #2
</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL>
<BALAMT>-46.01
<DTASOF>20260903
</LEDGERBAL>
</STMTRS>
</STMTTRNRS>
</BANKMSGSRSV1>
</OFX>
`, "\n", "\r\n")
	if got := buf.String(); got != want {
		t.Errorf("OFX:\n%s\nwant:\n%s", got, want)
	}
}

func TestOFXLimitsAndPeriod(t *testing.T) {
	ps := []ynab.Posting{{ExpenseID: 9, Date: day("2026-09-02"), AmountCents: 5, Payee: "Sehr langer Titel mit <Sonderzeichen> und Überlänge",
		Memo: "Zeile 1\nZeile 2"}}
	var buf bytes.Buffer
	if err := writeOFX(&buf, ps, "X", day("2026-09-01"), day("2026-09-30"), stamp); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	for _, want := range []string{"<NAME>Sehr langer Titel mit &lt;Sonderzei\r\n", "<MEMO>Zeile 1 Zeile 2\r\n", "<TRNAMT>-0.05\r\n",
		"<DTSTART>20260901\r\n", "<DTEND>20260930\r\n"} {
		if !strings.Contains(out, want) {
			t.Errorf("OFX ohne %q:\n%s", want, out)
		}
	}
}

func TestYNABCSVGolden(t *testing.T) {
	var buf bytes.Buffer
	if err := writeYNABCSV(&buf, ynab.Selection{Today: day("2026-10-02")}.Postings(sample(), anna.ID)); err != nil {
		t.Fatal(err)
	}
	want := "Date,Payee,Memo,Outflow,Inflow\n" +
		"2026-09-01,Café & Kuchen,\"Gesamt 12,01 € · bezahlt von Anna · teilen #1\",6.01,\n" +
		"2026-09-03,\"Diner \"\"NYC\"\"\",\"Gesamt 80,00 € (90,00 USD) · bezahlt von Ben · teilen #2\",40.00,\n"
	if got := buf.String(); got != want {
		t.Errorf("YNAB-CSV:\n%s\nwant:\n%s", got, want)
	}
}

func TestDecimal(t *testing.T) {
	tests := []struct {
		minor int64
		dec   int
		want  string
	}{{0, 2, "0,00"}, {5, 2, "0,05"}, {123456, 2, "1234,56"}, {-42, 2, "-0,42"}, {1500, 0, "1500"}, {1234, 3, "1,234"}}
	for _, tt := range tests {
		if got := decimal(tt.minor, tt.dec, ','); got != tt.want {
			t.Errorf("decimal(%d, %d) = %q, want %q", tt.minor, tt.dec, got, tt.want)
		}
	}
}

// --- Handler ---------------------------------------------------------------------

type fixture struct {
	h          http.Handler
	st         *store.Store
	anna, juer int64
}

func newFixture(t *testing.T) fixture {
	t.Helper()
	st, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	r, err := web.NewRenderer(st, time.UTC, log)
	if err != nil {
		t.Fatal(err)
	}
	d := web.Deps{Store: st, Render: r, Log: log}
	mux := http.NewServeMux()
	if err := Register(mux, d); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	f := fixture{h: web.Wrap(d, mux), st: st}
	f.anna, _ = st.CreateParticipant(ctx, "Anna")
	f.juer, _ = st.CreateParticipant(ctx, "Jürgen")
	add := func(title, date string, cents int64, payer int64, who ...int64) int64 {
		in := store.ExpenseInput{Title: title, Date: day(date), PaidBy: payer, SplitMode: domain.SplitEqual, AmountCents: cents}
		for _, id := range who {
			in.Parts = append(in.Parts, domain.Part{ParticipantID: id})
		}
		id, err := st.CreateExpense(ctx, payer, in)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	add("Brötchen", "2026-08-30", 400, f.juer, f.anna, f.juer)
	add("Käse", "2026-09-02", 1000, f.juer, f.anna, f.juer)
	gone := add("Gelöscht", "2026-09-03", 999, f.anna, f.anna, f.juer)
	st.DeleteExpense(ctx, f.anna, gone)
	add("Nur Jürgen", "2026-09-04", 700, f.juer, f.juer)
	return f
}

func (f fixture) get(path string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("GET", path, nil)
	req.AddCookie(&http.Cookie{Name: web.IdentityCookie, Value: strconv.FormatInt(f.anna, 10)})
	rec := httptest.NewRecorder()
	f.h.ServeHTTP(rec, req)
	return rec
}

func TestExportPage(t *testing.T) {
	f := newFixture(t)
	rec := f.get("/export?von=2026-09-01")
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `formaction="/export/ynab.ofx"`) ||
		!strings.Contains(rec.Body.String(), `value="2026-09-01"`) {
		t.Errorf("Seite: %d", rec.Code)
	}
	if rec := f.get("/export?von=kaputt"); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("ungültiges Datum: %d", rec.Code)
	}
	if rec := f.get("/export/ausgaben.csv?von=2026-09-10&bis=2026-09-01"); rec.Code != http.StatusUnprocessableEntity ||
		!strings.Contains(rec.Body.String(), "„Bis“ liegt vor „Von“") {
		t.Errorf("bis vor von: %d", rec.Code)
	}
}

func TestExpensesDownload(t *testing.T) {
	f := newFixture(t)
	rec := f.get("/export/ausgaben.csv?von=01.09.2026&bis=2026-09-30")
	if rec.Code != 200 || rec.Header().Get("Content-Disposition") != `attachment; filename="teilen-ausgaben-2026-09-01_2026-09-30.csv"` ||
		rec.Header().Get("Content-Type") != "text/csv; charset=utf-8" {
		t.Fatalf("CSV: %d %v", rec.Code, rec.Header())
	}
	body := rec.Body.String()
	if !strings.HasPrefix(body, "\uFEFFID;") || !strings.Contains(body, ";Käse;") || strings.Contains(body, "Brötchen") ||
		strings.Contains(body, "Gelöscht") || strings.Index(body, "Käse") > strings.Index(body, "Nur Jürgen") {
		t.Errorf("CSV:\n%s", body)
	}

	rec = f.get("/export/ausgaben.json")
	if rec.Code != 200 || !strings.HasPrefix(rec.Header().Get("Content-Disposition"), `attachment; filename="teilen-ausgaben-`) {
		t.Fatalf("JSON: %d", rec.Code)
	}
	var out jsonExport
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Expenses) != 3 || out.Expenses[0].Title != "Brötchen" || len(out.Participants) != 2 || out.From != "" {
		t.Errorf("JSON = %+v", out)
	}
}

func TestYNABDownloads(t *testing.T) {
	f := newFixture(t)
	rec := f.get("/export/ynab.ofx?von=2026-09-01")
	if rec.Code != 200 || rec.Header().Get("Content-Type") != "application/x-ofx" ||
		rec.Header().Get("Content-Disposition") != `attachment; filename="teilen-ynab-ab-2026-09-01.ofx"` {
		t.Fatalf("OFX: %d %v", rec.Code, rec.Header())
	}
	body := rec.Body.String()
	// Nur Annas Anteil an „Käse“ (Brötchen vor dem Zeitraum, gelöscht und „Nur Jürgen“ ohne Anteil).
	if strings.Count(body, "<STMTTRN>") != 1 || !strings.Contains(body, "<NAME>Käse\r\n") || !strings.Contains(body, "<TRNAMT>-5.00\r\n") ||
		!strings.Contains(body, "<ACCTID>TEILEN-"+strconv.FormatInt(f.anna, 10)+"\r\n") {
		t.Errorf("OFX:\n%s", body)
	}
	rec = f.get("/export/ynab.csv")
	want := "Date,Payee,Memo,Outflow,Inflow\n" +
		"2026-08-30,Brötchen,\"Gesamt 4,00 € · bezahlt von Jürgen · teilen #1\",2.00,\n" +
		"2026-09-02,Käse,\"Gesamt 10,00 € · bezahlt von Jürgen · teilen #2\",5.00,\n"
	if rec.Code != 200 || rec.Body.String() != want {
		t.Errorf("YNAB-CSV: %d\n%s", rec.Code, rec.Body)
	}
}

// Die YNAB-Dateien enthalten genau das, was auch der Sync überträgt.
func TestYNABDownloadsFollowSync(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	// ohne YNAB: alle vergangenen Ausgaben, keine künftigen
	future := store.ExpenseInput{Title: "Zukunft", Date: time.Now().AddDate(0, 0, 3), PaidBy: f.juer, SplitMode: domain.SplitEqual,
		AmountCents: 800, Parts: []domain.Part{{ParticipantID: f.anna}, {ParticipantID: f.juer}}}
	if _, err := f.st.CreateExpense(ctx, f.juer, future); err != nil {
		t.Fatal(err)
	}
	if body := f.get("/export/ynab.csv").Body.String(); strings.Contains(body, "Zukunft") || !strings.Contains(body, "Brötchen") {
		t.Errorf("ohne YNAB:\n%s", body)
	}

	// mit YNAB ab 01.09.: Brötchen (30.08., vor dem Einrichten erfasst) fehlt,
	// eine danach rückdatiert erfasste Ausgabe ist dabei.
	clock := time.Now().Add(time.Hour)
	f.st.SetClock(func() time.Time { return clock })
	f.st.SetYNABToken(ctx, f.anna, "tok")
	if err := f.st.SetYNABTarget(ctx, f.anna, "p", "a", day("2026-09-01")); err != nil {
		t.Fatal(err)
	}
	clock = clock.Add(time.Minute)
	late := store.ExpenseInput{Title: "Nachgetragen", Date: day("2026-08-15"), PaidBy: f.juer, SplitMode: domain.SplitEqual,
		AmountCents: 600, Parts: []domain.Part{{ParticipantID: f.anna}, {ParticipantID: f.juer}}}
	if _, err := f.st.CreateExpense(ctx, f.juer, late); err != nil {
		t.Fatal(err)
	}
	rec := f.get("/export/ynab.csv")
	body := rec.Body.String()
	if !strings.Contains(body, "Nachgetragen") || !strings.Contains(body, "Käse") || strings.Contains(body, "Brötchen") || strings.Contains(body, "Zukunft") {
		t.Errorf("mit YNAB:\n%s", body)
	}
	// Schon in YNAB vorhanden → bleibt dabei; der Zeitraum filtert zusätzlich.
	f.st.PutYNABSync(ctx, store.YNABSync{ExpenseID: 1, ParticipantID: f.anna, TxnID: "t1", Hash: "h"})
	if body := f.get("/export/ynab.csv").Body.String(); !strings.Contains(body, "Brötchen") {
		t.Errorf("in YNAB vorhanden:\n%s", body)
	}
	if body := f.get("/export/ynab.ofx?von=2026-09-01").Body.String(); strings.Count(body, "<STMTTRN>") != 1 || !strings.Contains(body, "<NAME>Käse") {
		t.Errorf("OFX mit Zeitraum:\n%s", body)
	}
}

func TestYNABCSVInjection(t *testing.T) {
	var buf bytes.Buffer
	ps := []ynab.Posting{{ExpenseID: 1, Date: day("2026-09-01"), AmountCents: 100, Payee: "=HYPERLINK(\"x\")", Memo: "+1 · teilen #1"}}
	if err := writeYNABCSV(&buf, ps); err != nil {
		t.Fatal(err)
	}
	if got := buf.String(); !strings.Contains(got, `"'=HYPERLINK(""x"")"`) || !strings.Contains(got, "'+1 · teilen #1") {
		t.Errorf("YNAB-CSV:\n%s", got)
	}
}
