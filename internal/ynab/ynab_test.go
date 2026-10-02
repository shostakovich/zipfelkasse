package ynab

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"teilen/internal/config"
	"teilen/internal/domain"
	"teilen/internal/store"
	"teilen/internal/web"
)

type env struct {
	t                *testing.T
	ctx              context.Context
	st               *store.Store
	svc              *Service
	fake             *fakeYNAB
	h                http.Handler
	now              time.Time
	anna, ben, cleo  int64
	food, restaurant int64
}

func newEnv(t *testing.T) *env {
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
	d := web.Deps{Config: config.Config{Location: time.UTC}, Store: st, Render: r, Log: log}
	svc, err := New(d)
	if err != nil {
		t.Fatal(err)
	}
	e := &env{t: t, ctx: context.Background(), st: st, svc: svc, fake: newFake(),
		now: time.Date(2026, 10, 2, 12, 0, 0, 0, time.UTC)}
	svc.http = &http.Client{Transport: e.fake}
	svc.baseURL = "https://api.test/v1"
	svc.now = func() time.Time { return e.now }
	mux := http.NewServeMux()
	svc.Register(mux)
	e.h = web.Wrap(d, mux)
	for _, p := range []struct {
		id   *int64
		name string
	}{{&e.anna, "Anna"}, {&e.ben, "Ben"}, {&e.cleo, "Cleo"}} {
		if *p.id, err = st.CreateParticipant(e.ctx, p.name); err != nil {
			t.Fatal(err)
		}
	}
	cats, _ := st.ListCategories(e.ctx, false)
	e.food, e.restaurant = cats[0].ID, cats[1].ID // Lebensmittel, Restaurant
	return e
}

func day(s string) time.Time {
	t, err := time.Parse(domain.DateLayout, s)
	if err != nil {
		panic(err)
	}
	return t
}

// connect richtet Annas YNAB ein (Token, Plan, Konto, Startdatum).
func (e *env) connect(start string) {
	e.t.Helper()
	if err := e.st.SetYNABToken(e.ctx, e.anna, testToken); err != nil {
		e.t.Fatal(err)
	}
	if err := e.st.SetYNABTarget(e.ctx, e.anna, testPlan, testAccount, day(start)); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) input(title string, cents int64, date string, payer int64, who ...int64) store.ExpenseInput {
	in := store.ExpenseInput{Title: title, Date: day(date), PaidBy: payer, SplitMode: domain.SplitEqual,
		AmountCents: cents, CategoryID: e.food}
	for _, id := range who {
		in.Parts = append(in.Parts, domain.Part{ParticipantID: id})
	}
	return in
}

func (e *env) create(in store.ExpenseInput) int64 {
	e.t.Helper()
	id, err := e.st.CreateExpense(e.ctx, in.PaidBy, in)
	if err != nil {
		e.t.Fatal(err)
	}
	return id
}

func (e *env) sync(full bool) (syncResult, error) {
	e.t.Helper()
	cfg, err := e.st.GetYNABConfig(e.ctx, e.anna)
	if err != nil {
		e.t.Fatal(err)
	}
	res, _, err := e.svc.syncOne(e.ctx, cfg, full)
	return res, err
}

func (e *env) mustSync(full bool) syncResult {
	e.t.Helper()
	res, err := e.sync(full)
	if err != nil {
		e.t.Fatalf("sync: %v", err)
	}
	return res
}

func (e *env) expectRequests(want ...string) {
	e.t.Helper()
	got := e.fake.takeRequests()
	if !slices.Equal(got, want) {
		e.t.Errorf("Anfragen = %q, want %q", got, want)
	}
}

func (e *env) syncRows() map[int64]store.YNABSync {
	rows, err := e.st.ListYNABSync(e.ctx, e.anna)
	if err != nil {
		e.t.Fatal(err)
	}
	m := map[int64]store.YNABSync{}
	for _, r := range rows {
		m[r.ExpenseID] = r
	}
	return m
}

func str(p *string) string {
	if p == nil {
		return "<nil>"
	}
	return *p
}

const (
	pathTxns = "/v1/plans/plan-1/transactions"
	post     = "POST " + pathTxns
	patch    = "PATCH " + pathTxns
)

func TestSyncCreateUpdateDelete(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	if err := e.st.SetYNABCategoryMap(e.ctx, e.anna, map[int64]string{e.food: "c-food"}); err != nil {
		t.Fatal(err)
	}
	id := e.create(e.input("Einkauf Rewe", 8400, "2026-09-15", e.ben, e.anna, e.ben))

	res := e.mustSync(false)
	if res.Created != 1 || res.Updated+res.Deleted+res.Failed != 0 {
		t.Errorf("res = %+v", res)
	}
	e.expectRequests(post)
	live := e.fake.live()
	if len(live) != 1 {
		t.Fatalf("live = %+v", live)
	}
	tx := live[0]
	wantMemo := "Gesamt 84,00 € · bezahlt von Ben · teilen #" + strconv.FormatInt(id, 10)
	if tx.Amount != -42000 || tx.Date != "2026-09-15" || str(tx.PayeeName) != "Einkauf Rewe" || str(tx.Memo) != wantMemo ||
		str(tx.CategoryID) != "c-food" || tx.AccountID != testAccount || tx.Cleared != "cleared" || !tx.Approved {
		t.Errorf("Buchung = %+v (payee %q, memo %q, kat %q)", tx, str(tx.PayeeName), str(tx.Memo), str(tx.CategoryID))
	}
	if r := e.syncRows()[id]; r.TxnID != tx.ID || r.Hash == "" || r.SyncedAt.IsZero() || r.LastError != "" {
		t.Errorf("ynab_sync = %+v", r)
	}

	// Idempotent: nichts geändert → keine Anfrage.
	if res := e.mustSync(true); res != (syncResult{}) {
		t.Errorf("zweiter Lauf: %+v", res)
	}
	e.expectRequests()

	// Ändern → PATCH.
	in := e.input("Einkauf Rewe groß", 10000, "2026-09-16", e.ben, e.anna, e.ben)
	if err := e.st.UpdateExpense(e.ctx, e.ben, id, in); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Updated != 1 || res.Created != 0 {
		t.Errorf("Ändern: %+v", res)
	}
	e.expectRequests(patch)
	tx = e.fake.live()[0]
	if tx.Amount != -50000 || tx.Date != "2026-09-16" || str(tx.PayeeName) != "Einkauf Rewe groß" || !strings.HasPrefix(str(tx.Memo), "Gesamt 100,00 €") {
		t.Errorf("nach PATCH: %+v", tx)
	}

	// Löschen → DELETE.
	if err := e.st.DeleteExpense(e.ctx, e.ben, id); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Deleted != 1 {
		t.Errorf("Löschen: %+v", res)
	}
	e.expectRequests("DELETE " + pathTxns + "/" + tx.ID)
	if len(e.fake.live()) != 0 || len(e.syncRows()) != 0 {
		t.Errorf("nach Löschen: live %v, rows %v", e.fake.live(), e.syncRows())
	}
	e.mustSync(true)
	e.expectRequests()

	st := e.svc.loadStatus(e.ctx, e.anna)
	if st.LastSync != e.now || st.Error != "" || st.Summary != "0 neu · 0 geändert · 0 gelöscht" {
		t.Errorf("Status = %+v", st)
	}
}

func TestSyncBundlesRequests(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	var ids []int64
	for i := range 5 {
		ids = append(ids, e.create(e.input("Ausgabe "+strconv.Itoa(i), 1000, "2026-09-1"+strconv.Itoa(i), e.anna, e.anna, e.ben)))
	}
	if res := e.mustSync(false); res.Created != 5 {
		t.Errorf("res = %+v", res)
	}
	e.expectRequests(post)
	// Umbenennen der Zahlerin ändert alle Memos → ein einziger PATCH.
	if err := e.st.RenameParticipant(e.ctx, e.anna, "Änna"); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Updated != 5 {
		t.Errorf("res = %+v", res)
	}
	e.expectRequests(patch)
	for _, tx := range e.fake.live() {
		if !strings.Contains(str(tx.Memo), "bezahlt von Änna") {
			t.Errorf("Memo = %q", str(tx.Memo))
		}
	}
	_ = ids
}

func TestSyncUncategorizedKeepsManualCategory(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	id := e.create(e.input("Pizza", 3000, "2026-09-20", e.anna, e.anna, e.ben, e.cleo))
	e.mustSync(false)
	tx := e.fake.live()[0]
	if tx.CategoryID != nil || tx.Amount != -10000 {
		t.Fatalf("unkategorisiert erwartet: %+v", tx)
	}
	// In YNAB von Hand kategorisiert; eine Änderung in der App lässt das stehen.
	manual := "c-out"
	e.fake.txns[tx.ID].CategoryID = &manual
	in := e.input("Pizza Napoli", 3000, "2026-09-20", e.anna, e.anna, e.ben, e.cleo)
	if err := e.st.UpdateExpense(e.ctx, e.anna, id, in); err != nil {
		t.Fatal(err)
	}
	e.mustSync(false)
	if tx := e.fake.live()[0]; str(tx.CategoryID) != "c-out" || str(tx.PayeeName) != "Pizza Napoli" {
		t.Errorf("manuelle Kategorie überschrieben: %+v", tx)
	}
	// Mit Zuordnung setzt der Sync die Kategorie.
	if err := e.st.SetYNABCategoryMap(e.ctx, e.anna, map[int64]string{e.food: "c-food"}); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Updated != 1 {
		t.Errorf("res = %+v", res)
	}
	if tx := e.fake.live()[0]; str(tx.CategoryID) != "c-food" {
		t.Errorf("Kategorie = %q", str(tx.CategoryID))
	}
}

func TestSyncFilters(t *testing.T) {
	e := newEnv(t)
	clock := time.Date(2026, 9, 20, 10, 0, 0, 0, time.UTC)
	e.st.SetClock(func() time.Time { return clock })
	e.connect("2026-09-10")
	// Alle Ausgaben gab es schon vor dem Einrichten (sonst zählte created_at).
	e.st.SetSetting(e.ctx, "ynab.connected."+strconv.FormatInt(e.anna, 10), "2026-09-21T10:00:00Z")
	early := e.create(e.input("Vor dem Start", 1000, "2026-09-01", e.anna, e.anna, e.ben))
	ok := e.create(e.input("Passt", 2000, "2026-09-15", e.ben, e.anna, e.ben))
	e.create(e.input("Ohne Anna", 3000, "2026-09-15", e.anna, e.ben, e.cleo)) // Anna zahlt, ist aber nicht beteiligt
	e.create(e.input("Ben und Cleo", 3000, "2026-09-15", e.ben, e.ben, e.cleo))
	future := e.create(e.input("Zukunft", 4000, "2026-10-05", e.anna, e.anna, e.ben))
	reimb := e.input("Rückzahlung", 1500, "2026-09-20", e.ben, e.anna)
	reimb.IsReimbursement = true
	e.create(reimb)
	gone := e.create(e.input("Gelöscht", 5000, "2026-09-16", e.anna, e.anna, e.ben))
	if err := e.st.DeleteExpense(e.ctx, e.anna, gone); err != nil {
		t.Fatal(err)
	}

	if res := e.mustSync(false); res.Created != 1 {
		t.Errorf("res = %+v", res)
	}
	if live := e.fake.live(); len(live) != 1 || !strings.HasSuffix(str(live[0].Memo), "#"+strconv.FormatInt(ok, 10)) {
		t.Fatalf("live = %+v", live)
	}

	// Startdatum vorziehen → frühere Ausgabe kommt dazu.
	if err := e.st.SetYNABTarget(e.ctx, e.anna, testPlan, testAccount, day("2026-09-01")); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Created != 1 || len(e.fake.live()) != 2 {
		t.Errorf("vorgezogen: %+v, live %d", res, len(e.fake.live()))
	}
	// Startdatum nach hinten → schon übertragene Buchungen bleiben (gelöscht
	// wird nur bei Löschung der Ausgabe oder Anteil 0).
	if err := e.st.SetYNABTarget(e.ctx, e.anna, testPlan, testAccount, day("2026-09-16")); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Deleted != 0 || len(e.fake.live()) != 2 {
		t.Errorf("später: %+v, live %d", res, len(e.fake.live()))
	}
	if _, has := e.syncRows()[early]; !has {
		t.Error("Zeile für frühe Ausgabe entfernt")
	}
	// Zukünftige Ausgabe kommt, sobald sie fällig ist.
	e.now = time.Date(2026, 10, 5, 8, 0, 0, 0, time.UTC)
	if res := e.mustSync(true); res.Created != 1 {
		t.Errorf("fällig: %+v", res)
	}
	if live := e.fake.live(); len(live) != 3 || live[2].Date != "2026-10-05" {
		t.Errorf("live = %+v (future %d)", live, future)
	}
	// Anteil auf 0: Anna nicht mehr beteiligt → DELETE.
	if err := e.st.UpdateExpense(e.ctx, e.anna, future, e.input("Zukunft", 4000, "2026-10-05", e.anna, e.ben)); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Deleted != 1 || len(e.fake.live()) != 2 {
		t.Errorf("Anteil 0: %+v", res)
	}
}

func TestSyncForeignCurrencyMemo(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	in := e.input("Diner in NYC", domain.ToEURCents(9000, "USD", 1.125), "2026-09-20", e.cleo, e.anna, e.cleo)
	in.OriginalCurrency, in.OriginalAmountMinor, in.FXRate, in.FXSource = "USD", 9000, 1.125, domain.FXSourceECB
	id := e.create(in)
	e.mustSync(false)
	tx := e.fake.live()[0]
	want := "Gesamt 80,00 € (90,00 USD) · bezahlt von Cleo · teilen #" + strconv.FormatInt(id, 10)
	if str(tx.Memo) != want || tx.Amount != -40000 {
		t.Errorf("memo %q / amount %d, want %q / -40000", str(tx.Memo), tx.Amount, want)
	}
}

func TestSyncRateLimitBackoff(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	id := e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	e.fake.fail(429)
	if _, err := e.sync(false); statusOf(err) != http.StatusTooManyRequests {
		t.Fatalf("err = %v", err)
	}
	e.expectRequests(post)
	st := e.svc.loadStatus(e.ctx, e.anna)
	if !st.RetryAt.Equal(e.now.Add(5*time.Minute)) || st.Backoff != 5*time.Minute || !strings.Contains(st.Error, "Anfragelimit") {
		t.Errorf("Status = %+v", st)
	}
	if r := e.syncRows()[id]; r.Hash == pendingHash || r.TxnID != "" {
		t.Errorf("nach 429 nicht zurückgesetzt: %+v", r)
	}
	// Während der Pause keine Anfragen.
	var be backoffError
	if _, err := e.sync(false); !errors.As(err, &be) {
		t.Errorf("err = %v, want backoffError", err)
	}
	e.expectRequests()
	// Zweites 429 verdoppelt die Pause.
	e.now = e.now.Add(6 * time.Minute)
	e.fake.fail(429)
	e.sync(false)
	if st := e.svc.loadStatus(e.ctx, e.anna); st.Backoff != 10*time.Minute {
		t.Errorf("Backoff = %v", st.Backoff)
	}
	e.now = e.now.Add(11 * time.Minute)
	e.fake.takeRequests()
	if res := e.mustSync(false); res.Created != 1 {
		t.Errorf("res = %+v", res)
	}
	if st := e.svc.loadStatus(e.ctx, e.anna); st.Error != "" || st.Backoff != 0 || !st.RetryAt.IsZero() {
		t.Errorf("Status nach Erfolg = %+v", st)
	}
	// SyncAll plant den nächsten Lauf nach Ablauf der Pause.
	e.fake.fail(429)
	e.st.UpdateExpense(e.ctx, e.anna, id, e.input("Kino 2", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	if next := e.svc.SyncAll(e.ctx, false); next > 5*time.Minute+time.Second || next < 5*time.Minute {
		t.Errorf("next = %v", next)
	}
}

func TestSyncUnauthorized(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	if err := e.st.SetYNABToken(e.ctx, e.anna, "falsch"); err != nil {
		t.Fatal(err)
	}
	e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	if _, err := e.sync(false); statusOf(err) != http.StatusUnauthorized {
		t.Fatalf("err = %v", err)
	}
	st := e.svc.loadStatus(e.ctx, e.anna)
	if !st.TokenInvalid || !strings.Contains(st.Error, "Token") {
		t.Errorf("Status = %+v", st)
	}
	e.fake.takeRequests()
	if _, err := e.sync(true); !errors.Is(err, errTokenInvalid) {
		t.Errorf("err = %v", err)
	}
	e.expectRequests()

	// Seite zeigt den Hinweis; neuer Token über das Formular setzt zurück.
	_, body := e.get("/einstellungen/ynab")
	if !strings.Contains(body, "ungültig oder abgelaufen") {
		t.Error("Hinweis auf ungültigen Token fehlt")
	}
	res := e.post("/einstellungen/ynab/token", url.Values{"token": {testToken}})
	if res.Code != http.StatusSeeOther {
		t.Fatalf("token: %d %s", res.Code, res.Body)
	}
	if res := e.mustSync(false); res.Created != 1 {
		t.Errorf("res = %+v", res)
	}
}

func TestSyncLostResponseNoDuplicate(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	id := e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	e.fake.lostPost = true
	if _, err := e.sync(false); !uncertain(err) {
		t.Fatalf("err = %v", err)
	}
	if r := e.syncRows()[id]; r.Hash != pendingHash {
		t.Errorf("row = %+v", r)
	}
	e.now = e.now.Add(6 * time.Minute)
	e.fake.takeRequests()
	e.mustSync(false)
	// Suche über die Memo-Markierung statt neu anzulegen; danach PATCH auf den Soll-Zustand.
	e.expectRequests("GET /v1/plans/plan-1/accounts/acc-geteilt/transactions", patch)
	if live := e.fake.live(); len(live) != 1 {
		t.Fatalf("Dublette: %+v", live)
	}
	if r := e.syncRows()[id]; r.TxnID != e.fake.live()[0].ID || r.Hash == pendingHash {
		t.Errorf("row = %+v", r)
	}
}

func TestSyncRecreatesTransactionsDeletedInYNAB(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	a := e.create(e.input("A", 1000, "2026-09-20", e.anna, e.anna, e.ben))
	b := e.create(e.input("B", 2000, "2026-09-21", e.anna, e.anna, e.ben))
	e.mustSync(false)
	rows := e.syncRows()
	// A in YNAB gelöscht (PATCH liefert deleted), B ganz verschwunden (404).
	e.fake.txns[rows[a].TxnID].Deleted = true
	delete(e.fake.txns, rows[b].TxnID)
	e.st.UpdateExpense(e.ctx, e.anna, a, e.input("A2", 1000, "2026-09-20", e.anna, e.anna, e.ben))
	e.st.UpdateExpense(e.ctx, e.anna, b, e.input("B2", 2000, "2026-09-21", e.anna, e.anna, e.ben))
	e.fake.takeRequests()
	res := e.mustSync(false)
	if !res.Again {
		t.Errorf("res = %+v", res)
	}
	e.mustSync(false)
	live := e.fake.live()
	if len(live) != 2 || str(live[0].PayeeName) != "A2" || str(live[1].PayeeName) != "B2" {
		t.Errorf("live = %+v", live)
	}
}

func TestSyncRejectedTransaction(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	good := e.create(e.input("Gut", 1000, "2026-09-20", e.anna, e.anna, e.ben))
	bad := e.create(e.input("ABLEHNEN", 2000, "2026-09-21", e.anna, e.anna, e.ben))
	res := e.mustSync(false)
	if res.Created != 1 || res.Failed != 1 {
		t.Errorf("res = %+v", res)
	}
	e.expectRequests(post, post, post) // Sammelaufruf abgelehnt → einzeln
	rows := e.syncRows()
	if rows[good].TxnID == "" || rows[bad].TxnID != "" || !strings.Contains(rows[bad].LastError, "payee abgelehnt") {
		t.Errorf("rows = %+v", rows)
	}
	// Unverändert fehlgeschlagen: nur im Vollabgleich erneut.
	e.mustSync(false)
	e.expectRequests()
	e.mustSync(true)
	e.expectRequests(post, post)
	_, problems, _ := e.st.YNABSyncSummary(e.ctx, e.anna)
	if len(problems) != 1 || problems[0].Title != "ABLEHNEN" {
		t.Errorf("problems = %+v", problems)
	}
}

func TestErrorsAreRedacted(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	e.fake.fail(503) // Detail enthält den Token
	_, err := e.sync(false)
	if err == nil {
		t.Fatal("kein Fehler")
	}
	st := e.svc.loadStatus(e.ctx, e.anna)
	if strings.Contains(st.Error, testToken) || !strings.Contains(st.Error, "•••") {
		t.Errorf("Status.Error = %q", st.Error)
	}
}

func TestTriggerNeverBlocks(t *testing.T) {
	e := newEnv(t)
	done := make(chan struct{})
	go func() {
		for i := range 10000 {
			e.svc.Trigger(int64(i))
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Trigger blockiert")
	}
}

func TestRunSyncsAfterChange(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	e.svc.debounce = 10 * time.Millisecond
	e.svc.startDelay = time.Hour
	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan struct{})
	go func() { e.svc.Run(ctx); close(stopped) }()
	defer func() { cancel(); <-stopped }()

	e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben)) // Hook → Trigger
	deadline := time.Now().Add(3 * time.Second)
	for len(e.fake.live()) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("Run hat nicht synchronisiert")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestPostingFor(t *testing.T) {
	e := store.Expense{ID: 7, ExpenseInput: store.ExpenseInput{Title: strings.Repeat("x", 250), Date: day("2026-09-01"),
		AmountCents: 1000, OriginalCurrency: "EUR"}, PaidByName: "Anna",
		Shares: []domain.Share{{ParticipantID: 1, AmountCents: 500}, {ParticipantID: 2, AmountCents: 500}}}
	p, ok := PostingFor(e, 1)
	if !ok || p.AmountCents != 500 || len([]rune(p.Payee)) != maxPayeeLen || p.Memo != "Gesamt 10,00 € · bezahlt von Anna · teilen #7" {
		t.Errorf("p = %+v", p)
	}
	if _, ok := PostingFor(e, 3); ok {
		t.Error("ohne Anteil")
	}
	e.IsReimbursement = true
	if _, ok := PostingFor(e, 1); ok {
		t.Error("Rückzahlung")
	}
	if id, ok := markerID("bla · teilen #123"); !ok || id != 123 {
		t.Errorf("markerID = %d, %v", id, ok)
	}
	if _, ok := markerID("teilen #12 und mehr"); ok {
		t.Error("Markierung mitten im Text")
	}
}

// --- Einstellungsseite -------------------------------------------------------

func (e *env) do(req *http.Request) *httptest.ResponseRecorder {
	req.AddCookie(&http.Cookie{Name: web.IdentityCookie, Value: strconv.FormatInt(e.anna, 10)})
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	return rec
}

func (e *env) get(path string) (*httptest.ResponseRecorder, string) {
	rec := e.do(httptest.NewRequest("GET", path, nil))
	return rec, rec.Body.String()
}

func (e *env) post(path string, v url.Values) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", path, strings.NewReader(v.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return e.do(req)
}

func TestSettingsPageFlow(t *testing.T) {
	e := newEnv(t)
	rec, body := e.get("/einstellungen/ynab")
	if rec.Code != 200 || !strings.Contains(body, "Verbinden") || !strings.Contains(body, "Verrechnungskonto") && !strings.Contains(body, "„Geteilt“") {
		t.Fatalf("leer: %d", rec.Code)
	}
	e.expectRequests() // ohne Token keine Anfrage

	// Falscher Token wird abgelehnt.
	rec = e.post("/einstellungen/ynab/token", url.Values{"token": {"falsch"}})
	if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "kennt diesen Token nicht") {
		t.Errorf("falscher Token: %d", rec.Code)
	}
	if _, err := e.st.GetYNABConfig(e.ctx, e.anna); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("falscher Token gespeichert: %v", err)
	}
	e.fake.takeRequests()

	rec = e.post("/einstellungen/ynab/token", url.Values{"token": {testToken}})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("token: %d %s", rec.Code, rec.Body)
	}
	_, body = e.get("/einstellungen/ynab")
	if strings.Contains(body, testToken) {
		t.Fatal("Token im HTML!")
	}
	for _, want := range []string{"gesetzt", `value="plan-1|acc-geteilt"`, ">Geteilt<", ">Girokonto<", `label="Haushalt"`} {
		if !strings.Contains(body, want) {
			t.Errorf("Seite ohne %q", want)
		}
	}
	for _, unwanted := range []string{"Depot", "Altes Konto"} {
		if strings.Contains(body, unwanted) {
			t.Errorf("Seite mit %q", unwanted)
		}
	}
	e.expectRequests("GET /v1/plans") // Token-Prüfung; die Seite nutzt den Cache

	// Unbekanntes Konto wird abgelehnt.
	rec = e.post("/einstellungen/ynab/konto", url.Values{"ziel": {"plan-1|acc-depot"}, "start": {"2026-09-01"}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("Depot: %d", rec.Code)
	}
	rec = e.post("/einstellungen/ynab/konto", url.Values{"ziel": {"plan-1|acc-geteilt"}, "start": {"01.09.2026"}})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("konto: %d %s", rec.Code, rec.Body)
	}
	cfg, _ := e.st.GetYNABConfig(e.ctx, e.anna)
	if cfg.PlanID != testPlan || cfg.AccountID != testAccount || cfg.StartDate != day("2026-09-01") || !cfg.Ready() {
		t.Errorf("cfg = %+v", cfg)
	}

	_, body = e.get("/einstellungen/ynab")
	for _, want := range []string{`label="Alltag"`, ">Lebensmittel &amp; Drogerie<", "Jetzt synchronisieren", `name="kat-` + strconv.FormatInt(e.food, 10)} {
		if !strings.Contains(body, want) {
			t.Errorf("Seite ohne %q", want)
		}
	}
	for _, unwanted := range []string{"Ready to Assign", "Visa", "Versteckt", testToken} {
		if strings.Contains(body, unwanted) {
			t.Errorf("Seite mit %q", unwanted)
		}
	}

	rec = e.post("/einstellungen/ynab/kategorien", url.Values{"kat-" + strconv.FormatInt(e.food, 10): {"c-gibtsnicht"}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("unbekannte Kategorie: %d", rec.Code)
	}
	rec = e.post("/einstellungen/ynab/kategorien", url.Values{
		"kat-" + strconv.FormatInt(e.food, 10):       {"c-food"},
		"kat-" + strconv.FormatInt(e.restaurant, 10): {""},
	})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("kategorien: %d %s", rec.Code, rec.Body)
	}
	if m, _ := e.st.YNABCategoryMap(e.ctx, e.anna); len(m) != 1 || m[e.food] != "c-food" {
		t.Errorf("map = %v", m)
	}
	_, body = e.get("/einstellungen/ynab")
	if !strings.Contains(body, `value="c-food" selected`) {
		t.Error("Zuordnung nicht vorausgewählt")
	}
	e.expectRequests("GET /v1/plans/plan-1/categories") // danach aus dem Cache

	e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	rec = e.post("/einstellungen/ynab/sync", nil)
	e.svc.waitBackground()
	if rec.Code != http.StatusSeeOther || len(e.fake.live()) != 1 {
		t.Fatalf("sync: %d, live %d", rec.Code, len(e.fake.live()))
	}
	if str(e.fake.live()[0].CategoryID) != "c-food" {
		t.Errorf("Kategorie = %q", str(e.fake.live()[0].CategoryID))
	}
	_, body = e.get("/einstellungen/ynab")
	if !strings.Contains(body, "Synchronisierte Buchungen: <strong>1</strong>") {
		t.Error("Status fehlt")
	}

	// Sync-Fehler werden angezeigt (ohne Token).
	e.fake.fail(503)
	e.st.CreateExpense(e.ctx, e.anna, e.input("Bar", 1000, "2026-09-21", e.anna, e.anna, e.ben))
	rec = e.post("/einstellungen/ynab/sync", nil)
	e.svc.waitBackground()
	if rec.Code != http.StatusSeeOther {
		t.Errorf("sync-Fehler: %d", rec.Code)
	}
	if _, body := e.get("/einstellungen/ynab"); !strings.Contains(body, "Fehler 503") || strings.Contains(body, testToken) {
		t.Errorf("Status zeigt den Fehler nicht (oder den Token)")
	}

	rec = e.post("/einstellungen/ynab/trennen", nil)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("trennen: %d", rec.Code)
	}
	if cfg, _ := e.st.GetYNABConfig(e.ctx, e.anna); cfg.Token != "" || cfg.Ready() {
		t.Errorf("cfg nach trennen = %+v", cfg)
	}
	if next := e.svc.SyncAll(e.ctx, true); next != fullInterval {
		t.Errorf("next = %v", next)
	}
}

func TestSettingsChangeAccountResetsSync(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	e.mustSync(false)
	if len(e.syncRows()) != 1 {
		t.Fatal("keine Zeile")
	}
	if err := e.st.SetYNABTarget(e.ctx, e.anna, testPlan, "acc-giro", day("2026-09-01")); err != nil {
		t.Fatal(err)
	}
	if len(e.syncRows()) != 0 {
		t.Error("Kontowechsel setzt den Abgleich nicht zurück")
	}
	if res := e.mustSync(false); res.Created != 1 {
		t.Errorf("res = %+v", res)
	}
}

// Rückdatiert erfasst: Eine nach dem Einrichten erfasste Ausgabe mit Datum vor
// dem Startdatum kennt der Startsaldo von „Geteilt“ nicht – sie muss nach YNAB.
func TestSyncBackdatedExpenseAfterConnect(t *testing.T) {
	e := newEnv(t)
	clock := time.Date(2026, 9, 20, 10, 0, 0, 0, time.UTC)
	e.st.SetClock(func() time.Time { return clock })
	e.create(e.input("Vor dem Verbinden", 1000, "2026-09-01", e.anna, e.anna, e.ben))
	clock = clock.Add(time.Hour)
	e.connect("2026-09-10")
	clock = clock.Add(time.Hour)
	late := e.create(e.input("Nachgetragen", 2000, "2026-09-05", e.ben, e.anna, e.ben))

	if res := e.mustSync(false); res.Created != 1 {
		t.Errorf("res = %+v", res)
	}
	live := e.fake.live()
	if len(live) != 1 || live[0].Date != "2026-09-05" || !strings.HasSuffix(str(live[0].Memo), "#"+strconv.FormatInt(late, 10)) {
		t.Errorf("live = %+v", live)
	}
	// Kontowechsel = neu eingerichtet: Jetzt zählt wieder nur das Startdatum.
	clock = clock.Add(time.Hour)
	if err := e.st.SetYNABTarget(e.ctx, e.anna, testPlan, "acc-giro", day("2026-09-10")); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Created != 0 {
		t.Errorf("nach Kontowechsel: %+v", res)
	}
}

// Datum vor den Start verschoben: Eine schon übertragene Ausgabe bleibt in
// YNAB (der Startsaldo enthält sie nicht) und wird nur geändert.
func TestSyncKeepsExpenseMovedBeforeStart(t *testing.T) {
	e := newEnv(t)
	clock := time.Date(2026, 9, 20, 10, 0, 0, 0, time.UTC)
	e.st.SetClock(func() time.Time { return clock })
	id := e.create(e.input("Kino", 2400, "2026-09-15", e.anna, e.anna, e.ben))
	clock = clock.Add(time.Hour)
	e.connect("2026-09-10")
	if res := e.mustSync(false); res.Created != 1 {
		t.Fatalf("res = %+v", res)
	}
	e.fake.takeRequests()
	if err := e.st.UpdateExpense(e.ctx, e.anna, id, e.input("Kino", 2400, "2026-09-01", e.anna, e.anna, e.ben)); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(true); res.Updated != 1 || res.Deleted != 0 {
		t.Errorf("res = %+v", res)
	}
	e.expectRequests(patch)
	if live := e.fake.live(); len(live) != 1 || live[0].Date != "2026-09-01" {
		t.Errorf("live = %+v", live)
	}
	// Gelöscht wird erst bei Löschung der Ausgabe.
	e.st.DeleteExpense(e.ctx, e.anna, id)
	if res := e.mustSync(false); res.Deleted != 1 || len(e.fake.live()) != 0 {
		t.Errorf("Löschen: %+v", res)
	}
}

// Eine Ausgabe, deren PATCH fehlschlug, wird nach dem Löschen sofort aus
// YNAB entfernt – nicht erst beim stündlichen Vollabgleich.
func TestSyncDeletesAfterFailedPatch(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	id := e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	e.mustSync(false)
	e.st.UpdateExpense(e.ctx, e.anna, id, e.input("Kino 2", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	e.fake.fail(400, 400) // Sammel-PATCH und Einzelversuch abgelehnt
	if res := e.mustSync(false); res.Failed != 1 {
		t.Fatalf("res = %+v", res)
	}
	if r := e.syncRows()[id]; r.TxnID == "" || r.LastError == "" {
		t.Fatalf("row = %+v", r)
	}
	e.fake.takeRequests()
	e.st.DeleteExpense(e.ctx, e.anna, id)
	if res := e.mustSync(false); res.Deleted != 1 || len(e.fake.live()) != 0 {
		t.Errorf("Löschen nach Fehler: %+v, live %d", res, len(e.fake.live()))
	}
}

// „Jetzt synchronisieren“ wartet nicht auf YNAB.
func TestSyncNowDoesNotBlock(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	hold := make(chan struct{})
	e.fake.hold = hold
	done := make(chan *httptest.ResponseRecorder)
	go func() { done <- e.post("/einstellungen/ynab/sync", nil) }()
	select {
	case rec := <-done:
		if rec.Code != http.StatusSeeOther {
			t.Errorf("sync: %d", rec.Code)
		}
		if msg := flashOf(rec); !strings.Contains(msg, "Synchronisierung gestartet") {
			t.Errorf("Flash = %q", msg)
		}
	case <-time.After(2 * time.Second):
		close(hold)
		t.Fatal("POST /einstellungen/ynab/sync blockiert")
	}
	close(hold)
	e.svc.waitBackground()
	if len(e.fake.live()) != 1 {
		t.Errorf("live = %+v", e.fake.live())
	}
}

func flashOf(rec *httptest.ResponseRecorder) string {
	for _, c := range rec.Result().Cookies() {
		if c.Name == "flash" {
			b, _ := base64.RawURLEncoding.DecodeString(c.Value)
			return string(b)
		}
	}
	return ""
}
