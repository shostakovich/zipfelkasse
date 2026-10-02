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

	"github.com/shostakovich/zipfelkasse/internal/config"
	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
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

// connect sets up Anna's YNAB (token, plan, account, start date).
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
		e.t.Errorf("requests = %q, want %q", got, want)
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
	wantMemo := "Gesamt 84,00 € · bezahlt von Ben · zipfelkasse #" + strconv.FormatInt(id, 10)
	if tx.Amount != -42000 || tx.Date != "2026-09-15" || str(tx.PayeeName) != "Einkauf Rewe" || str(tx.Memo) != wantMemo ||
		str(tx.CategoryID) != "c-food" || tx.AccountID != testAccount || tx.Cleared != "cleared" || !tx.Approved {
		t.Errorf("transaction = %+v (payee %q, memo %q, cat %q)", tx, str(tx.PayeeName), str(tx.Memo), str(tx.CategoryID))
	}
	if r := e.syncRows()[id]; r.TxnID != tx.ID || r.Hash == "" || r.SyncedAt.IsZero() || r.LastError != "" {
		t.Errorf("ynab_sync = %+v", r)
	}

	// Idempotent: nothing changed → no request.
	if res := e.mustSync(true); res != (syncResult{}) {
		t.Errorf("second run: %+v", res)
	}
	e.expectRequests()

	// Change → PATCH.
	in := e.input("Einkauf Rewe groß", 10000, "2026-09-16", e.ben, e.anna, e.ben)
	if err := e.st.UpdateExpense(e.ctx, e.ben, id, in); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Updated != 1 || res.Created != 0 {
		t.Errorf("change: %+v", res)
	}
	e.expectRequests(patch)
	tx = e.fake.live()[0]
	if tx.Amount != -50000 || tx.Date != "2026-09-16" || str(tx.PayeeName) != "Einkauf Rewe groß" || !strings.HasPrefix(str(tx.Memo), "Gesamt 100,00 €") {
		t.Errorf("after PATCH: %+v", tx)
	}

	// Delete → DELETE.
	if err := e.st.DeleteExpense(e.ctx, e.ben, id); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Deleted != 1 {
		t.Errorf("delete: %+v", res)
	}
	e.expectRequests("DELETE " + pathTxns + "/" + tx.ID)
	if len(e.fake.live()) != 0 || len(e.syncRows()) != 0 {
		t.Errorf("after delete: live %v, rows %v", e.fake.live(), e.syncRows())
	}
	e.mustSync(true)
	e.expectRequests()

	st := e.svc.loadStatus(e.ctx, e.anna)
	if st.LastSync != e.now || st.Error != "" || st.Summary != "0 neu · 0 geändert · 0 gelöscht" {
		t.Errorf("status = %+v", st)
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
	// Renaming the payer changes all memos → a single PATCH.
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
		t.Fatalf("expected uncategorized: %+v", tx)
	}
	// Categorized manually in YNAB; a change in the app leaves that alone.
	manual := "c-out"
	e.fake.txns[tx.ID].CategoryID = &manual
	in := e.input("Pizza Napoli", 3000, "2026-09-20", e.anna, e.anna, e.ben, e.cleo)
	if err := e.st.UpdateExpense(e.ctx, e.anna, id, in); err != nil {
		t.Fatal(err)
	}
	e.mustSync(false)
	if tx := e.fake.live()[0]; str(tx.CategoryID) != "c-out" || str(tx.PayeeName) != "Pizza Napoli" {
		t.Errorf("manual category overwritten: %+v", tx)
	}
	// With a mapping, the sync sets the category.
	if err := e.st.SetYNABCategoryMap(e.ctx, e.anna, map[int64]string{e.food: "c-food"}); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Updated != 1 {
		t.Errorf("res = %+v", res)
	}
	if tx := e.fake.live()[0]; str(tx.CategoryID) != "c-food" {
		t.Errorf("category = %q", str(tx.CategoryID))
	}
}

func TestSyncFilters(t *testing.T) {
	e := newEnv(t)
	clock := time.Date(2026, 9, 20, 10, 0, 0, 0, time.UTC)
	e.st.SetClock(func() time.Time { return clock })
	e.connect("2026-09-10")
	// All expenses existed before the setup (otherwise created_at would count).
	e.st.SetSetting(e.ctx, "ynab.connected."+strconv.FormatInt(e.anna, 10), "2026-09-21T10:00:00Z")
	early := e.create(e.input("Vor dem Start", 1000, "2026-09-01", e.anna, e.anna, e.ben))
	ok := e.create(e.input("Passt", 2000, "2026-09-15", e.ben, e.anna, e.ben))
	e.create(e.input("Ohne Anna", 3000, "2026-09-15", e.anna, e.ben, e.cleo)) // Anna pays but is not involved
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

	// Move the start date earlier → an earlier expense is added.
	if err := e.st.SetYNABTarget(e.ctx, e.anna, testPlan, testAccount, day("2026-09-01")); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Created != 1 || len(e.fake.live()) != 2 {
		t.Errorf("earlier: %+v, live %d", res, len(e.fake.live()))
	}
	// Move the start date later → already transferred transactions stay
	// (they are only deleted on deletion of the expense or share 0).
	if err := e.st.SetYNABTarget(e.ctx, e.anna, testPlan, testAccount, day("2026-09-16")); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Deleted != 0 || len(e.fake.live()) != 2 {
		t.Errorf("later: %+v, live %d", res, len(e.fake.live()))
	}
	if _, has := e.syncRows()[early]; !has {
		t.Error("row for early expense removed")
	}
	// A future expense is added once it is due.
	e.now = time.Date(2026, 10, 5, 8, 0, 0, 0, time.UTC)
	if res := e.mustSync(true); res.Created != 1 {
		t.Errorf("due: %+v", res)
	}
	if live := e.fake.live(); len(live) != 3 || live[2].Date != "2026-10-05" {
		t.Errorf("live = %+v (future %d)", live, future)
	}
	// Share to 0: Anna no longer involved → DELETE.
	if err := e.st.UpdateExpense(e.ctx, e.anna, future, e.input("Zukunft", 4000, "2026-10-05", e.anna, e.ben)); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Deleted != 1 || len(e.fake.live()) != 2 {
		t.Errorf("share 0: %+v", res)
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
	want := "Gesamt 80,00 € (90,00 USD) · bezahlt von Cleo · zipfelkasse #" + strconv.FormatInt(id, 10)
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
		t.Errorf("status = %+v", st)
	}
	if r := e.syncRows()[id]; r.Hash == pendingHash || r.TxnID != "" {
		t.Errorf("not reset after 429: %+v", r)
	}
	// No requests during the pause.
	var be backoffError
	if _, err := e.sync(false); !errors.As(err, &be) {
		t.Errorf("err = %v, want backoffError", err)
	}
	e.expectRequests()
	// A second 429 doubles the pause.
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
		t.Errorf("status after success = %+v", st)
	}
	// SyncAll schedules the next run after the pause ends.
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
		t.Errorf("status = %+v", st)
	}
	e.fake.takeRequests()
	if _, err := e.sync(true); !errors.Is(err, errTokenInvalid) {
		t.Errorf("err = %v", err)
	}
	e.expectRequests()

	// The page shows the notice; a new token via the form resets it.
	_, body := e.get("/einstellungen/ynab")
	if !strings.Contains(body, "ungültig oder abgelaufen") {
		t.Error("notice about invalid token missing")
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
	// Search via the memo marker instead of creating again; then PATCH to the desired state.
	e.expectRequests("GET /v1/plans/plan-1/accounts/acc-geteilt/transactions", patch)
	if live := e.fake.live(); len(live) != 1 {
		t.Fatalf("duplicate: %+v", live)
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
	// A deleted in YNAB (PATCH returns deleted), B gone entirely (404).
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
	e.expectRequests(post, post, post) // batch call rejected → one by one
	rows := e.syncRows()
	if rows[good].TxnID == "" || rows[bad].TxnID != "" || !strings.Contains(rows[bad].LastError, "payee rejected") {
		t.Errorf("rows = %+v", rows)
	}
	// Failed and unchanged: retried only in the full sync.
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
	e.fake.fail(503) // the detail contains the token
	_, err := e.sync(false)
	if err == nil {
		t.Fatal("no error")
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
		t.Fatal("Trigger blocks")
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
			t.Fatal("Run did not sync")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestPostingFor(t *testing.T) {
	e := store.Expense{ID: 7, ExpenseInput: store.ExpenseInput{Title: strings.Repeat("x", 250), Date: day("2026-09-01"),
		AmountCents: 1000, OriginalCurrency: "EUR"}, PaidByName: "Anna",
		Shares: []domain.Share{{ParticipantID: 1, AmountCents: 500}, {ParticipantID: 2, AmountCents: 500}}}
	p, ok := PostingFor(e, 1)
	if !ok || p.AmountCents != 500 || len([]rune(p.Payee)) != maxPayeeLen || p.Memo != "Gesamt 10,00 € · bezahlt von Anna · zipfelkasse #7" {
		t.Errorf("p = %+v", p)
	}
	if _, ok := PostingFor(e, 3); ok {
		t.Error("without share")
	}
	e.IsReimbursement = true
	if _, ok := PostingFor(e, 1); ok {
		t.Error("reimbursement")
	}
	if id, ok := markerID("bla · zipfelkasse #123"); !ok || id != 123 {
		t.Errorf("markerID = %d, %v", id, ok)
	}
	if _, ok := markerID("zipfelkasse #12 und mehr"); ok {
		t.Error("marker in the middle of the text")
	}
}

// --- Settings page -----------------------------------------------------------

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
		t.Fatalf("empty: %d", rec.Code)
	}
	e.expectRequests() // no request without a token

	// A wrong token is rejected.
	rec = e.post("/einstellungen/ynab/token", url.Values{"token": {"falsch"}})
	if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "kennt diesen Token nicht") {
		t.Errorf("wrong token: %d", rec.Code)
	}
	if _, err := e.st.GetYNABConfig(e.ctx, e.anna); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("wrong token stored: %v", err)
	}
	e.fake.takeRequests()

	rec = e.post("/einstellungen/ynab/token", url.Values{"token": {testToken}})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("token: %d %s", rec.Code, rec.Body)
	}
	_, body = e.get("/einstellungen/ynab")
	if strings.Contains(body, testToken) {
		t.Fatal("token in the HTML!")
	}
	for _, want := range []string{"gesetzt", `value="plan-1|acc-geteilt"`, ">Geteilt<", ">Girokonto<", `label="Haushalt"`} {
		if !strings.Contains(body, want) {
			t.Errorf("page without %q", want)
		}
	}
	for _, unwanted := range []string{"Depot", "Altes Konto"} {
		if strings.Contains(body, unwanted) {
			t.Errorf("page with %q", unwanted)
		}
	}
	e.expectRequests("GET /v1/plans") // token check; the page uses the cache

	// An unknown account is rejected.
	rec = e.post("/einstellungen/ynab/konto", url.Values{"ziel": {"plan-1|acc-depot"}, "start": {"2026-09-01"}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("Depot: %d", rec.Code)
	}
	rec = e.post("/einstellungen/ynab/konto", url.Values{"ziel": {"plan-1|acc-geteilt"}, "start": {"01.09.2026"}})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("account: %d %s", rec.Code, rec.Body)
	}
	cfg, _ := e.st.GetYNABConfig(e.ctx, e.anna)
	if cfg.PlanID != testPlan || cfg.AccountID != testAccount || cfg.StartDate != day("2026-09-01") || !cfg.Ready() {
		t.Errorf("cfg = %+v", cfg)
	}

	_, body = e.get("/einstellungen/ynab")
	for _, want := range []string{`label="Alltag"`, ">Lebensmittel &amp; Drogerie<", "Jetzt synchronisieren", `name="kat-` + strconv.FormatInt(e.food, 10)} {
		if !strings.Contains(body, want) {
			t.Errorf("page without %q", want)
		}
	}
	for _, unwanted := range []string{"Ready to Assign", "Visa", "Versteckt", testToken} {
		if strings.Contains(body, unwanted) {
			t.Errorf("page with %q", unwanted)
		}
	}

	rec = e.post("/einstellungen/ynab/kategorien", url.Values{"kat-" + strconv.FormatInt(e.food, 10): {"c-gibtsnicht"}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("unknown category: %d", rec.Code)
	}
	rec = e.post("/einstellungen/ynab/kategorien", url.Values{
		"kat-" + strconv.FormatInt(e.food, 10):       {"c-food"},
		"kat-" + strconv.FormatInt(e.restaurant, 10): {""},
	})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("categories: %d %s", rec.Code, rec.Body)
	}
	if m, _ := e.st.YNABCategoryMap(e.ctx, e.anna); len(m) != 1 || m[e.food] != "c-food" {
		t.Errorf("map = %v", m)
	}
	_, body = e.get("/einstellungen/ynab")
	if !strings.Contains(body, `value="c-food" selected`) {
		t.Error("mapping not preselected")
	}
	e.expectRequests("GET /v1/plans/plan-1/categories") // afterwards from the cache

	e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	rec = e.post("/einstellungen/ynab/sync", nil)
	e.svc.waitBackground()
	if rec.Code != http.StatusSeeOther || len(e.fake.live()) != 1 {
		t.Fatalf("sync: %d, live %d", rec.Code, len(e.fake.live()))
	}
	if str(e.fake.live()[0].CategoryID) != "c-food" {
		t.Errorf("category = %q", str(e.fake.live()[0].CategoryID))
	}
	_, body = e.get("/einstellungen/ynab")
	if !strings.Contains(body, "Synchronisierte Buchungen: <strong>1</strong>") {
		t.Error("status missing")
	}

	// Sync errors are shown (without the token).
	e.fake.fail(503)
	e.st.CreateExpense(e.ctx, e.anna, e.input("Bar", 1000, "2026-09-21", e.anna, e.anna, e.ben))
	rec = e.post("/einstellungen/ynab/sync", nil)
	e.svc.waitBackground()
	if rec.Code != http.StatusSeeOther {
		t.Errorf("sync error: %d", rec.Code)
	}
	if _, body := e.get("/einstellungen/ynab"); !strings.Contains(body, "Fehler 503") || strings.Contains(body, testToken) {
		t.Errorf("status does not show the error (or shows the token)")
	}

	rec = e.post("/einstellungen/ynab/trennen", nil)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("disconnect: %d", rec.Code)
	}
	if cfg, _ := e.st.GetYNABConfig(e.ctx, e.anna); cfg.Token != "" || cfg.Ready() {
		t.Errorf("cfg after disconnect = %+v", cfg)
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
		t.Fatal("no row")
	}
	if err := e.st.SetYNABTarget(e.ctx, e.anna, testPlan, "acc-giro", day("2026-09-01")); err != nil {
		t.Fatal(err)
	}
	for _, r := range e.syncRows() {
		if r.TxnID != "" {
			t.Errorf("changing the account keeps the old transaction: %+v", r)
		}
	}
	e.fake.takeRequests()
	if res := e.mustSync(false); res.Created != 1 {
		t.Errorf("res = %+v", res)
	}
	// Looked for in the new account first (it could be there already).
	e.expectRequests("GET /v1/plans/plan-1/accounts/acc-giro/transactions", post)
}

// Switching to another account and back must not create the transactions in
// the first account a second time: they are found again via the memo marker.
func TestSyncTargetChangeBackNoDuplicates(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	a := e.create(e.input("A", 1000, "2026-09-20", e.anna, e.anna, e.ben))
	b := e.create(e.input("B", 2000, "2026-09-21", e.anna, e.anna, e.ben))
	gone := e.create(e.input("Weg", 3000, "2026-09-22", e.anna, e.anna, e.ben))
	e.mustSync(false)
	inA := e.syncRows()

	if err := e.st.SetYNABTarget(e.ctx, e.anna, testPlan, "acc-giro", day("2026-09-01")); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Created != 3 {
		t.Errorf("account B: %+v", res)
	}
	// While syncing to B: one expense changes, one is deleted.
	e.st.UpdateExpense(e.ctx, e.anna, a, e.input("A2", 1000, "2026-09-20", e.anna, e.anna, e.ben))
	e.st.DeleteExpense(e.ctx, e.anna, gone)
	e.mustSync(false)

	if err := e.st.SetYNABTarget(e.ctx, e.anna, testPlan, testAccount, day("2026-09-01")); err != nil {
		t.Fatal(err)
	}
	e.fake.takeRequests()
	res := e.mustSync(false)
	if res.Created != 0 || res.Updated != 2 || res.Deleted != 0 {
		t.Errorf("back to A: %+v", res)
	}
	// No DELETE with transaction IDs of account B (they do not belong to A).
	e.expectRequests("GET /v1/plans/plan-1/accounts/acc-geteilt/transactions", patch)
	rows := e.syncRows()
	if rows[a].TxnID != inA[a].TxnID || rows[b].TxnID != inA[b].TxnID {
		t.Errorf("rows = %+v, in A before %+v", rows, inA)
	}
	if _, ok := rows[gone]; ok {
		t.Errorf("row of the deleted expense kept: %+v", rows[gone])
	}
	var inAccountA []string
	for _, tx := range e.fake.live() {
		if tx.AccountID == testAccount {
			inAccountA = append(inAccountA, str(tx.PayeeName))
		}
	}
	// "Weg" was created in A before the switch and stays there (the app no
	// longer knows its transaction); A and B are not duplicated.
	if !slices.Equal(inAccountA, []string{"A2", "B", "Weg"}) {
		t.Errorf("account A = %q", inAccountA)
	}
	if res := e.mustSync(false); res != (syncResult{}) {
		t.Errorf("afterwards: %+v", res)
	}
}

// Backdated: an expense entered after the setup with a date before the start
// date is unknown to the starting balance of "Geteilt" – it must go to YNAB.
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
	// Account change = set up anew: now only the start date counts again.
	clock = clock.Add(time.Hour)
	if err := e.st.SetYNABTarget(e.ctx, e.anna, testPlan, "acc-giro", day("2026-09-10")); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Created != 0 {
		t.Errorf("after account change: %+v", res)
	}
}

// A backdated expense whose creation had an unclear outcome is looked for
// from its own date on, not only from the start date – also if it has been
// deleted in the meantime.
func TestSyncLostResponseBackdatedNoDuplicate(t *testing.T) {
	for _, deleted := range []bool{false, true} {
		e := newEnv(t)
		clock := time.Date(2026, 9, 20, 10, 0, 0, 0, time.UTC)
		e.st.SetClock(func() time.Time { return clock })
		e.connect("2026-09-10")
		clock = clock.Add(time.Hour)
		id := e.create(e.input("Nachgetragen", 2000, "2026-09-05", e.ben, e.anna, e.ben))
		e.fake.lostPost = true
		if _, err := e.sync(false); !uncertain(err) {
			t.Fatalf("err = %v", err)
		}
		e.now = e.now.Add(6 * time.Minute)
		e.fake.takeRequests()
		if !deleted {
			e.mustSync(false)
			e.expectRequests("GET /v1/plans/plan-1/accounts/acc-geteilt/transactions", patch)
			live := e.fake.live()
			if len(live) != 1 || live[0].Date != "2026-09-05" {
				t.Fatalf("duplicate: %+v", live)
			}
			if r := e.syncRows()[id]; r.TxnID != live[0].ID {
				t.Errorf("row = %+v", r)
			}
			continue
		}
		created := e.fake.live()[0].ID
		e.st.DeleteExpense(e.ctx, e.ben, id)
		e.mustSync(false)
		e.expectRequests("GET /v1/plans/plan-1/accounts/acc-geteilt/transactions", "DELETE "+pathTxns+"/"+created)
		if live := e.fake.live(); len(live) != 0 {
			t.Errorf("deleted: live = %+v", live)
		}
	}
}

// Date moved before the start: an already transferred expense stays in YNAB
// (the starting balance does not contain it) and is only updated.
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
	// It is only deleted when the expense is deleted.
	e.st.DeleteExpense(e.ctx, e.anna, id)
	if res := e.mustSync(false); res.Deleted != 1 || len(e.fake.live()) != 0 {
		t.Errorf("delete: %+v", res)
	}
}

// An expense whose PATCH failed is removed from YNAB right after deletion –
// not only in the hourly full sync.
func TestSyncDeletesAfterFailedPatch(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	id := e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	e.mustSync(false)
	e.st.UpdateExpense(e.ctx, e.anna, id, e.input("Kino 2", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	e.fake.fail(400, 400) // batch PATCH and single attempt rejected
	if res := e.mustSync(false); res.Failed != 1 {
		t.Fatalf("res = %+v", res)
	}
	if r := e.syncRows()[id]; r.TxnID == "" || r.LastError == "" {
		t.Fatalf("row = %+v", r)
	}
	e.fake.takeRequests()
	e.st.DeleteExpense(e.ctx, e.anna, id)
	if res := e.mustSync(false); res.Deleted != 1 || len(e.fake.live()) != 0 {
		t.Errorf("delete after error: %+v, live %d", res, len(e.fake.live()))
	}
}

// A token of another YNAB user does not know the chosen plan: plan and account
// are reset so that they are chosen anew.
func TestSaveTokenOfOtherYNABUser(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	// The same YNAB user: the target stays.
	if rec := e.post("/einstellungen/ynab/token", url.Values{"token": {testToken}}); rec.Code != http.StatusSeeOther {
		t.Fatalf("token: %d %s", rec.Code, rec.Body)
	}
	if cfg, _ := e.st.GetYNABConfig(e.ctx, e.anna); cfg.PlanID != testPlan || cfg.AccountID != testAccount {
		t.Errorf("same user: cfg = %+v", cfg)
	}
	rec := e.post("/einstellungen/ynab/token", url.Values{"token": {otherToken}})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("token: %d %s", rec.Code, rec.Body)
	}
	if msg := flashOf(rec); !strings.Contains(msg, "neu wählen") {
		t.Errorf("Flash = %q", msg)
	}
	cfg, _ := e.st.GetYNABConfig(e.ctx, e.anna)
	if cfg.Token != otherToken || cfg.PlanID != "" || cfg.AccountID != "" || cfg.Ready() {
		t.Errorf("other user: cfg = %+v", cfg)
	}
}

// If plan or account are unknown to YNAB (e.g. token of another YNAB user),
// the 404 for single transactions must not be taken as "transaction gone":
// the run stops, the sync state stays as it is.
func TestSyncPlanNotAccessible(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	a := e.create(e.input("A", 1000, "2026-09-20", e.anna, e.anna, e.ben))
	b := e.create(e.input("B", 2000, "2026-09-21", e.anna, e.anna, e.ben))
	e.mustSync(false)
	before := e.syncRows()
	if err := e.st.SetYNABToken(e.ctx, e.anna, otherToken); err != nil {
		t.Fatal(err)
	}
	check := func(step string) {
		t.Helper()
		if _, err := e.sync(false); statusOf(err) != http.StatusNotFound {
			t.Errorf("%s: err = %v", step, err)
		}
		if st := e.svc.loadStatus(e.ctx, e.anna); !strings.Contains(st.Error, "Plan oder Konto") {
			t.Errorf("%s: status = %+v", step, st)
		}
		rows := e.syncRows()
		if rows[a].TxnID != before[a].TxnID || rows[b].TxnID != before[b].TxnID {
			t.Errorf("%s: rows = %+v", step, rows)
		}
	}
	e.st.DeleteExpense(e.ctx, e.anna, b)
	check("delete")
	e.st.UpdateExpense(e.ctx, e.anna, a, e.input("A2", 1000, "2026-09-20", e.anna, e.anna, e.ben))
	check("update")

	if err := e.st.SetYNABToken(e.ctx, e.anna, testToken); err != nil {
		t.Fatal(err)
	}
	if res := e.mustSync(false); res.Updated != 1 || res.Deleted != 1 || res.Created != 0 {
		t.Errorf("res = %+v", res)
	}
	if live := e.fake.live(); len(live) != 1 || str(live[0].PayeeName) != "A2" {
		t.Errorf("live = %+v", live)
	}
}

// A DELETE rejected by YNAB is retried only in the full sync, not in every run
// after a change (each attempt costs a request of the hourly limit).
func TestSyncFailedDeleteRetriedOnlyInFullSync(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	id := e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	e.mustSync(false)
	del := "DELETE " + pathTxns + "/" + e.fake.live()[0].ID
	e.st.DeleteExpense(e.ctx, e.anna, id)
	e.fake.takeRequests()
	e.fake.fail(400)
	if res := e.mustSync(false); res.Failed != 1 {
		t.Errorf("res = %+v", res)
	}
	e.expectRequests(del)
	if r := e.syncRows()[id]; r.TxnID == "" || r.LastError == "" {
		t.Errorf("row = %+v", r)
	}
	// The next change does not repeat it.
	e.create(e.input("Pizza", 3000, "2026-09-21", e.anna, e.anna, e.ben))
	if res := e.mustSync(false); res.Created != 1 || res.Failed+res.Deleted != 0 {
		t.Errorf("res = %+v", res)
	}
	e.expectRequests(post)
	if res := e.mustSync(true); res.Deleted != 1 {
		t.Errorf("full: %+v", res)
	}
	e.expectRequests(del)
}

// "Jetzt synchronisieren" does not wait for YNAB.
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
		t.Fatal("POST /einstellungen/ynab/sync blocks")
	}
	close(hold)
	e.svc.waitBackground()
	if len(e.fake.live()) != 1 {
		t.Errorf("live = %+v", e.fake.live())
	}
}

// postDuringSync sends a form while a sync (SyncAll) hangs in its first
// request to YNAB. It lets the sync go on once the handler has answered or
// after a short wait (if the handler waits for the sync), and returns after
// both have finished.
func (e *env) postDuringSync(path string, v url.Values) *httptest.ResponseRecorder {
	e.t.Helper()
	hold := make(chan struct{})
	e.fake.hold = hold
	e.fake.takeRequests()
	synced := make(chan struct{})
	go func() { e.svc.SyncAll(e.ctx, false); close(synced) }()
	for deadline := time.Now().Add(3 * time.Second); e.fake.requestCount() == 0; time.Sleep(time.Millisecond) {
		if time.Now().After(deadline) {
			close(hold)
			e.t.Fatal("sync did not start")
		}
	}
	answered := make(chan *httptest.ResponseRecorder, 1)
	go func() { answered <- e.post(path, v) }()
	var rec *httptest.ResponseRecorder
	select {
	case rec = <-answered:
	case <-time.After(100 * time.Millisecond):
	}
	close(hold)
	<-synced
	if rec == nil {
		rec = <-answered
	}
	e.fake.hold = nil
	return rec
}

// Changing the account while a sync runs must not end up with transaction
// IDs of the old account in the new sync state.
func TestSettingsChangeAccountDuringSync(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	id := e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	if _, err := e.svc.plans(e.ctx, testToken, true); err != nil { // the handler uses the cache
		t.Fatal(err)
	}
	rec := e.postDuringSync("/einstellungen/ynab/konto", url.Values{"ziel": {"plan-1|acc-giro"}, "start": {"2026-09-01"}})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("account: %d %s", rec.Code, rec.Body)
	}
	if r := e.syncRows()[id]; r.TxnID != "" {
		t.Errorf("row after account change = %+v", r)
	}
	e.mustSync(false)
	byID := map[string]apiTxn{}
	for _, tx := range e.fake.live() {
		byID[tx.ID] = tx
	}
	if tx := byID[e.syncRows()[id].TxnID]; tx.AccountID != "acc-giro" {
		t.Errorf("row points to %+v, live %+v", tx, e.fake.live())
	}
}

// A new token saved while a sync with the old (invalid) token runs stays
// valid: the end of the sync must not overwrite the reset status.
func TestSettingsNewTokenDuringSync(t *testing.T) {
	e := newEnv(t)
	e.connect("2026-09-01")
	if err := e.st.SetYNABToken(e.ctx, e.anna, "abgelaufen"); err != nil {
		t.Fatal(err)
	}
	e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
	rec := e.postDuringSync("/einstellungen/ynab/token", url.Values{"token": {testToken}})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("token: %d %s", rec.Code, rec.Body)
	}
	if st := e.svc.loadStatus(e.ctx, e.anna); st.TokenInvalid || st.Error != "" {
		t.Errorf("status = %+v", st)
	}
	if res := e.mustSync(false); res.Created != 1 {
		t.Errorf("res = %+v", res)
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

// Changes to the YNAB settings end up in the activity log – without the token.
func TestSettingsActivity(t *testing.T) {
	e := newEnv(t)
	last := func() string {
		t.Helper()
		acts, _ := e.st.ListActivity(e.ctx, store.ActivityFilter{Limit: 1})
		if len(acts) != 1 || acts[0].Action != store.ActionSettingsUpdated || acts[0].ActorID != e.anna {
			t.Errorf("Activity = %+v", acts)
			return ""
		}
		if strings.Contains(acts[0].Details.Text, testToken) {
			t.Fatal("token in the activity log!")
		}
		return acts[0].Details.Text
	}
	steps := []struct {
		path string
		form url.Values
		want string
	}{
		{"/einstellungen/ynab/token", url.Values{"token": {testToken}}, "YNAB verbunden (Token gesetzt)"},
		{"/einstellungen/ynab/token", url.Values{"token": {testToken}}, "YNAB-Token ersetzt"},
		{"/einstellungen/ynab/konto", url.Values{"ziel": {"plan-1|acc-geteilt"}, "start": {"2026-09-01"}},
			"YNAB: Konto „Geteilt“ im Plan „Haushalt“ gewählt, Startdatum 01.09.2026"},
		{"/einstellungen/ynab/konto", url.Values{"ziel": {"plan-1|acc-geteilt"}, "start": {"2026-09-15"}},
			"YNAB: Startdatum 01.09.2026 → 15.09.2026"},
		{"/einstellungen/ynab/kategorien", url.Values{"kat-" + strconv.FormatInt(e.food, 10): {"c-food"}},
			"YNAB: Kategorie-Zuordnung geändert (Lebensmittel → Lebensmittel & Drogerie)"},
		{"/einstellungen/ynab/trennen", nil, "YNAB-Verbindung getrennt"},
	}
	for _, s := range steps {
		if rec := e.post(s.path, s.form); rec.Code != http.StatusSeeOther {
			t.Fatalf("%s: %d %s", s.path, rec.Code, rec.Body)
		}
		if got := last(); got != s.want {
			t.Errorf("%s: activity = %q, want %q", s.path, got, s.want)
		}
	}
}
