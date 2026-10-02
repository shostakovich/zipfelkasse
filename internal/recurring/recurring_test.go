package recurring

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/config"
	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

func day(s string) time.Time {
	t, err := time.Parse(domain.DateLayout, s)
	if err != nil {
		panic(err)
	}
	return t
}

// fakeFX returns fixed rates; an error if there is no entry.
type fakeFX struct {
	rates map[string]float64 // currency → rate
	calls []time.Time
}

func (f *fakeFX) Rate(_ context.Context, cur string, date time.Time) (domain.FXRate, error) {
	f.calls = append(f.calls, date)
	r, ok := f.rates[cur]
	if !ok {
		return domain.FXRate{}, errors.New("ECB not reachable")
	}
	return domain.FXRate{Currency: cur, Date: date, Rate: r, Source: domain.FXSourceECB}, nil
}

type env struct {
	t    *testing.T
	st   *store.Store
	svc  *Service
	fx   *fakeFX
	anna store.Participant
	ben  store.Participant
	ctx  context.Context
}

func newEnv(t *testing.T) *env {
	t.Helper()
	st, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	loc, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	r, err := web.NewRenderer(st, loc, log)
	if err != nil {
		t.Fatal(err)
	}
	fx := &fakeFX{rates: map[string]float64{}}
	d := web.Deps{Config: config.Config{Location: loc}, Store: st, Render: r, Log: log, FX: fx}
	svc, err := New(d)
	if err != nil {
		t.Fatal(err)
	}
	svc.now = func() time.Time { return time.Date(2026, 10, 2, 12, 0, 0, 0, loc) }
	e := &env{t: t, st: st, svc: svc, fx: fx, ctx: context.Background()}
	for i, name := range []string{"Anna", "Ben"} {
		id, err := st.CreateParticipant(e.ctx, name)
		if err != nil {
			t.Fatal(err)
		}
		p, _ := st.GetParticipant(e.ctx, id)
		if i == 0 {
			e.anna = p
		} else {
			e.ben = p
		}
	}
	return e
}

func (e *env) expense(title, date string, amount int64) store.ExpenseInput {
	return store.ExpenseInput{
		Title: title, Date: day(date), PaidBy: e.anna.ID, SplitMode: domain.SplitEqual, AmountCents: amount,
		Parts: []domain.Part{{ParticipantID: e.anna.ID}, {ParticipantID: e.ben.ID}},
	}
}

// rule creates an expense and makes it recurring.
func (e *env) rule(in store.ExpenseInput, f domain.Frequency) (ruleID, expenseID int64) {
	e.t.Helper()
	eid, err := e.st.CreateExpense(e.ctx, e.anna.ID, in)
	if err != nil {
		e.t.Fatal(err)
	}
	rid, err := e.st.CreateRecurringFromExpense(e.ctx, e.anna.ID, eid, f)
	if err != nil {
		e.t.Fatal(err)
	}
	return rid, eid
}

func (e *env) materialize(today string, want int) {
	e.t.Helper()
	n, err := e.svc.Materialize(e.ctx, day(today))
	if err != nil || n != want {
		e.t.Fatalf("Materialize(%s) = %d, %v; want %d", today, n, err, want)
	}
}

// instances returns all instances of the rule, in ascending date order.
func (e *env) instances(rid int64) []store.Expense {
	e.t.Helper()
	all, err := e.st.ListExpenses(e.ctx, store.ExpenseFilter{})
	if err != nil {
		e.t.Fatal(err)
	}
	var out []store.Expense
	for i := len(all) - 1; i >= 0; i-- {
		if all[i].RecurringID == rid {
			out = append(out, all[i])
		}
	}
	return out
}

func (e *env) dates(rid int64) string {
	var ds []string
	for _, x := range e.instances(rid) {
		ds = append(ds, x.Date.Format(domain.DateLayout))
	}
	return strings.Join(ds, " ")
}

func (e *env) next(rid int64) string {
	r, err := e.st.GetRecurring(e.ctx, rid)
	if err != nil {
		e.t.Fatal(err)
	}
	return r.NextDate.Format(domain.DateLayout)
}

func TestMaterializeMonthEnd(t *testing.T) {
	e := newEnv(t)
	rid, _ := e.rule(e.expense("Miete", "2026-01-31", 100000), domain.FreqMonthly)
	e.materialize("2026-02-27", 0)
	e.materialize("2026-05-15", 3) // three missed occurrences at once
	if got := e.dates(rid); got != "2026-01-31 2026-02-28 2026-03-31 2026-04-30" {
		t.Errorf("occurrences = %s", got)
	}
	if got := e.next(rid); got != "2026-05-31" {
		t.Errorf("next_date = %s", got)
	}
	e.materialize("2026-05-15", 0)
	e.materialize("2026-05-31", 1)
	for _, x := range e.instances(rid) {
		if x.Title != "Miete" || x.AmountCents != 100000 || len(x.Shares) != 2 || x.PaidBy != e.anna.ID {
			t.Errorf("instance = %+v", x)
		}
	}
	// Activity log: created automatically (system).
	acts, _ := e.st.ListActivity(e.ctx, store.ActivityFilter{Limit: 1})
	if len(acts) != 1 || acts[0].Action != store.ActionExpenseCreated || acts[0].ActorID != 0 {
		t.Errorf("Activity = %+v", acts)
	}
}

func TestMaterializeLeapYear(t *testing.T) {
	e := newEnv(t)
	yearly, _ := e.rule(e.expense("Versicherung", "2024-02-29", 12000), domain.FreqYearly)
	e.materialize("2028-03-01", 4)
	if got := e.dates(yearly); got != "2024-02-29 2025-02-28 2026-02-28 2027-02-28 2028-02-29" {
		t.Errorf("yearly = %s", got)
	}
}

func TestMaterializeWeeklyCatchUp(t *testing.T) {
	e := newEnv(t)
	rid, _ := e.rule(e.expense("Putzen", "2026-09-01", 4000), domain.FreqWeekly)
	e.materialize("2026-10-02", 4)
	if got := e.dates(rid); got != "2026-09-01 2026-09-08 2026-09-15 2026-09-22 2026-09-29" {
		t.Errorf("weekly = %s", got)
	}
	if got := e.next(rid); got != "2026-10-06" {
		t.Errorf("next_date = %s", got)
	}
}

func TestMaterializeIdempotentAfterCrash(t *testing.T) {
	e := newEnv(t)
	rid, _ := e.rule(e.expense("Strom", "2026-01-15", 5000), domain.FreqMonthly)
	// Simulate a crash: the instance for 15 Feb exists, but next_date was not
	// advanced anymore.
	in := e.expense("Strom", "2026-02-15", 5000)
	in.RecurringID = rid
	if _, err := e.st.CreateExpense(e.ctx, 0, in); err != nil {
		t.Fatal(err)
	}
	e.materialize("2026-03-20", 1) // only 15 Mar is new
	if got := e.dates(rid); got != "2026-01-15 2026-02-15 2026-03-15" {
		t.Errorf("occurrences = %s", got)
	}
	// Restart: new service on the same database.
	svc2, err := New(e.svc.d)
	if err != nil {
		t.Fatal(err)
	}
	if n, err := svc2.Materialize(e.ctx, day("2026-03-20")); n != 0 || err != nil {
		t.Errorf("after restart = %d, %v", n, err)
	}
	// A reset next_date creates no duplicates.
	if err := e.st.SetRecurringNextDate(e.ctx, rid, day("2026-01-15")); err != nil {
		t.Fatal(err)
	}
	e.materialize("2026-03-20", 0)
	if got := e.next(rid); got != "2026-04-15" {
		t.Errorf("next_date = %s", got)
	}
}

func TestMaterializePaused(t *testing.T) {
	e := newEnv(t)
	rid, _ := e.rule(e.expense("Kino", "2026-01-10", 2000), domain.FreqMonthly)
	if err := e.st.SetRecurringActive(e.ctx, rid, false, day("2026-01-20")); err != nil {
		t.Fatal(err)
	}
	e.materialize("2026-05-01", 0)
	// Resume on 1 May: the April occurrence and earlier ones are not caught up.
	if err := e.st.SetRecurringActive(e.ctx, rid, true, day("2026-05-01")); err != nil {
		t.Fatal(err)
	}
	e.materialize("2026-05-01", 0)
	e.materialize("2026-05-10", 1)
	if got := e.dates(rid); got != "2026-01-10 2026-05-10" {
		t.Errorf("occurrences = %s", got)
	}
}

func TestMaterializeForeignCurrency(t *testing.T) {
	e := newEnv(t)
	in := e.expense("Cloud", "2026-01-05", 9091)
	in.OriginalCurrency, in.OriginalAmountMinor, in.FXRate, in.FXSource = "USD", 10000, 1.1, domain.FXSourceECB
	rid, _ := e.rule(in, domain.FreqMonthly)

	e.fx.rates["USD"] = 1.25
	e.materialize("2026-02-05", 1)
	got := e.instances(rid)[1]
	if got.AmountCents != 8000 || got.FXRate != 1.25 || got.OriginalAmountMinor != 10000 || got.OriginalCurrency != "USD" ||
		got.FXSource != domain.FXSourceECB {
		t.Errorf("with the day's rate = %+v", got.ExpenseInput)
	}
	if len(e.fx.calls) != 1 || e.fx.calls[0] != day("2026-02-05") {
		t.Errorf("rate requested for %v", e.fx.calls)
	}

	// Rate not available → the template's rate.
	delete(e.fx.rates, "USD")
	e.materialize("2026-03-05", 1)
	got = e.instances(rid)[2]
	if got.AmountCents != 9091 || got.FXRate != 1.1 {
		t.Errorf("without rate = %+v", got.ExpenseInput)
	}
}

func TestMaterializeForeignFixedAmounts(t *testing.T) {
	e := newEnv(t)
	in := e.expense("Hotel", "2026-01-05", 9091)
	in.OriginalCurrency, in.OriginalAmountMinor, in.FXRate, in.FXSource = "USD", 10000, 1.1, domain.FXSourceECB
	in.SplitMode = domain.SplitAmount
	in.Parts = []domain.Part{{ParticipantID: e.anna.ID, Weight: 6000}, {ParticipantID: e.ben.ID, Weight: 3091}}
	rid, _ := e.rule(in, domain.FreqMonthly)
	e.fx.rates["USD"] = 1.25
	e.materialize("2026-02-05", 1)
	got := e.instances(rid)[1]
	if got.AmountCents != 8000 || got.ShareOf(e.anna.ID)+got.ShareOf(e.ben.ID) != 8000 || got.ShareOf(e.anna.ID) != 5280 {
		t.Errorf("fixed amounts converted = %+v", got.Shares)
	}
}

func TestRescale(t *testing.T) {
	parts := []domain.Part{{ParticipantID: 1, Weight: 1}, {ParticipantID: 2, Weight: 1}, {ParticipantID: 3, Weight: 1}}
	got := rescale(parts, 100)
	if got[0].Weight != 34 || got[1].Weight != 33 || got[2].Weight != 33 {
		t.Errorf("rescale = %+v", got)
	}
	if parts[0].Weight != 1 {
		t.Error("rescale modifies its input")
	}
	big := []domain.Part{{ParticipantID: 1, Weight: domain.MaxAmountCents - 1}, {ParticipantID: 2, Weight: 1}}
	got = rescale(big, domain.MaxAmountCents/2)
	if got[0].Weight+got[1].Weight != domain.MaxAmountCents/2 {
		t.Errorf("rescale large = %+v", got)
	}
}

// --- Handler ----------------------------------------------------------------

func (e *env) do(method, target string, form url.Values) *httptest.ResponseRecorder {
	mux := http.NewServeMux()
	e.svc.Register(mux)
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req := httptest.NewRequest(method, target, body)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	req = req.WithContext(web.WithMe(req.Context(), e.ben))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func TestHandlers(t *testing.T) {
	e := newEnv(t)
	rec := e.do("GET", "/einstellungen/wiederkehrend", nil)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "Noch keine wiederkehrenden Ausgaben") {
		t.Fatalf("empty list: %d %s", rec.Code, rec.Body)
	}
	rec = e.do("GET", "/einstellungen/wiederkehrend/neu", nil)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "Öffne zuerst die Ausgabe") {
		t.Errorf("new without expense: %d", rec.Code)
	}
	for _, q := range []string{"999", "abc"} {
		if rec = e.do("GET", "/einstellungen/wiederkehrend/neu?ausgabe="+q, nil); rec.Code != 404 {
			t.Errorf("new with expense %s: %d", q, rec.Code)
		}
	}

	eid, err := e.st.CreateExpense(e.ctx, e.anna.ID, e.expense("Miete", "2026-08-31", 100000))
	if err != nil {
		t.Fatal(err)
	}
	sid := strconv.FormatInt(eid, 10)
	rec = e.do("GET", "/einstellungen/wiederkehrend/neu?ausgabe="+sid, nil)
	body := rec.Body.String()
	if rec.Code != 200 || !strings.Contains(body, "Miete") || !strings.Contains(body, "nächster Termin 30.09.2026") ||
		!strings.Contains(body, "1 verpasster Termin wird sofort eingetragen") || !strings.Contains(body, "4 verpasste Termine") {
		t.Errorf("new: %d %s", rec.Code, body)
	}

	rec = e.do("POST", "/einstellungen/wiederkehrend/neu", url.Values{"ausgabe": {sid}, "haeufigkeit": {"taeglich"}})
	if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "Häufigkeit") {
		t.Errorf("invalid frequency: %d", rec.Code)
	}
	rec = e.do("POST", "/einstellungen/wiederkehrend/neu", url.Values{"ausgabe": {sid}, "haeufigkeit": {"monthly"}})
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/einstellungen/wiederkehrend" {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	rules, _ := e.st.ListRecurring(e.ctx)
	if len(rules) != 1 || rules[0].CreatedBy != e.ben.ID {
		t.Fatalf("rules = %+v", rules)
	}
	rid := rules[0].ID
	// Created right away: 30 Sep (today is 2026-10-02).
	if got := e.dates(rid); got != "2026-08-31 2026-09-30" {
		t.Errorf("occurrences = %s", got)
	}
	rec = e.do("GET", "/einstellungen/wiederkehrend/neu?ausgabe="+sid, nil)
	if !strings.Contains(rec.Body.String(), "gehört schon zu einer wiederkehrenden Ausgabe") {
		t.Errorf("already recurring: %s", rec.Body)
	}
	rec = e.do("POST", "/einstellungen/wiederkehrend/neu", url.Values{"ausgabe": {sid}, "haeufigkeit": {"monthly"}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("duplicate create: %d", rec.Code)
	}

	rec = e.do("GET", "/einstellungen/wiederkehrend", nil)
	body = rec.Body.String()
	if !strings.Contains(body, "Miete") || !strings.Contains(body, "Monatlich seit 31.08.2026") ||
		!strings.Contains(body, "31.10.2026") || !strings.Contains(body, "Pausieren") {
		t.Errorf("list: %s", body)
	}

	base := "/einstellungen/wiederkehrend/" + strconv.FormatInt(rid, 10)
	for _, step := range [][2]string{
		{"pausieren", "Wiederholung „Miete“ (monatlich) pausiert"},
		{"fortsetzen", "Wiederholung „Miete“ (monatlich) fortgesetzt"},
		{"vorlage", "Wiederholung „Miete“ (monatlich): Vorlage aus der letzten Ausgabe übernommen"},
	} {
		action, text := step[0], step[1]
		if rec = e.do("POST", base+"/"+action, nil); rec.Code != http.StatusSeeOther {
			t.Errorf("%s: %d", action, rec.Code)
		}
		acts, _ := e.st.ListActivity(e.ctx, store.ActivityFilter{Limit: 1})
		if len(acts) != 1 || acts[0].Action != store.ActionSettingsUpdated || acts[0].ActorID != e.ben.ID || acts[0].Details.Text != text {
			t.Errorf("%s: Activity = %+v", action, acts)
		}
		if rec = e.do("POST", "/einstellungen/wiederkehrend/999/"+action, nil); rec.Code != http.StatusNotFound {
			t.Errorf("%s unknown: %d", action, rec.Code)
		}
	}
	if rec = e.do("POST", base+"/loeschen", nil); rec.Code != http.StatusSeeOther {
		t.Errorf("delete: %d", rec.Code)
	}
	if rec = e.do("POST", base+"/loeschen", nil); rec.Code != http.StatusNotFound {
		t.Errorf("second delete: %d", rec.Code)
	}
	if n, _ := e.st.ListExpenses(e.ctx, store.ExpenseFilter{}); len(n) != 2 {
		t.Errorf("expenses after deleting the rule: %d", len(n))
	}
	acts, _ := e.st.ListActivity(e.ctx, store.ActivityFilter{Limit: 1})
	if len(acts) != 1 || acts[0].Action != store.ActionRecurringDeleted || acts[0].ActorID != e.ben.ID {
		t.Errorf("Activity = %+v", acts)
	}
}

// A very old start date does not create thousands of instances at once: at
// most maxInstancesPerRun per rule and run, the rest in the next run.
func TestMaterializeCapPerRun(t *testing.T) {
	e := newEnv(t)
	rid, _ := e.rule(e.expense("Putzen", "2000-01-03", 100), domain.FreqWeekly)
	e.materialize("2026-10-02", 400)
	if got, want := e.next(rid), domain.Occurrence(domain.FreqWeekly, day("2000-01-03"), 401).Format(domain.DateLayout); got != want {
		t.Errorf("next_date = %s, want %s", got, want)
	}
	e.materialize("2026-10-02", 400)
	if n := len(e.instances(rid)); n != 801 {
		t.Errorf("%d instances", n)
	}
}
