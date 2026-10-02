package store

import (
	"context"
	"errors"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestYNABConfig(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	if _, err := f.s.GetYNABConfig(ctx, f.anna); !errors.Is(err, ErrNotFound) {
		t.Fatalf("empty: %v", err)
	}
	if err := f.s.SetYNABTarget(ctx, f.anna, YNABTarget{PlanID: "p", AccountID: "a", Start: date("2026-09-01")}); !errors.Is(err, ErrNotFound) {
		t.Errorf("target without token: %v", err)
	}
	if _, err := f.s.SetYNABToken(ctx, f.anna, "tok", nil); err != nil {
		t.Fatal(err)
	}
	c, err := f.s.GetYNABConfig(ctx, f.anna)
	if err != nil || c.Token != "tok" || !c.Enabled || c.Ready() || !c.StartDate.IsZero() {
		t.Fatalf("after token: %+v, %v", c, err)
	}
	if err := f.s.SetYNABTarget(ctx, f.anna, YNABTarget{PlanID: "p", AccountID: "a", Start: date("2026-09-01")}); err != nil {
		t.Fatal(err)
	}
	c, _ = f.s.GetYNABConfig(ctx, f.anna)
	if c.PlanID != "p" || c.AccountID != "a" || c.StartDate != date("2026-09-01") || !c.Ready() {
		t.Errorf("after target: %+v", c)
	}

	// Ben has a token, Cleo is archived, Anna disconnects later.
	f.s.SetYNABToken(ctx, f.ben, "tok-b", nil)
	f.s.SetYNABToken(ctx, f.cleo, "tok-c", nil)
	f.s.SetParticipantArchived(ctx, 0, f.cleo, true)
	list, err := f.s.ListYNABConfigs(ctx)
	if err != nil || len(list) != 2 || list[0].ParticipantID != f.anna || list[1].ParticipantID != f.ben {
		t.Errorf("ListYNABConfigs = %+v, %v", list, err)
	}
	f.s.SetYNABToken(ctx, f.anna, "", nil)
	c, _ = f.s.GetYNABConfig(ctx, f.anna)
	if c.Token != "" || c.Enabled || c.Ready() || c.PlanID != "p" {
		t.Errorf("after disconnect: %+v", c)
	}
	if list, _ := f.s.ListYNABConfigs(ctx); len(list) != 1 {
		t.Errorf("after disconnect: %+v", list)
	}
}

func TestYNABTargetChangeResetsSync(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	id, _ := f.s.CreateExpense(ctx, f.anna, f.equal("Kino", 1000, "2026-09-10", f.anna, f.anna, f.ben))
	f.s.SetYNABToken(ctx, f.anna, "tok", nil)
	f.s.SetYNABTarget(ctx, f.anna, YNABTarget{PlanID: "p", AccountID: "a", Start: date("2026-09-01")})
	at := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	if err := f.s.PutYNABSync(ctx, YNABSync{ExpenseID: id, ParticipantID: f.anna, TxnID: "t1", Hash: "h", SyncedAt: at}); err != nil {
		t.Fatal(err)
	}
	rows, _ := f.s.ListYNABSync(ctx, f.anna)
	if len(rows) != 1 || rows[0].TxnID != "t1" || !rows[0].SyncedAt.Equal(at) {
		t.Fatalf("rows = %+v", rows)
	}
	// Changing only the start date: sync state is kept.
	f.s.SetYNABTarget(ctx, f.anna, YNABTarget{PlanID: "p", AccountID: "a", Start: date("2026-08-01")})
	if rows, _ := f.s.ListYNABSync(ctx, f.anna); len(rows) != 1 {
		t.Error("start date discarded sync state")
	}
	// Changing the account: the rows stay (the sync looks for their
	// transactions in the new account), but without the old transaction.
	f.s.SetYNABTarget(ctx, f.anna, YNABTarget{PlanID: "p", AccountID: "b", Start: date("2026-08-01")})
	rows, _ = f.s.ListYNABSync(ctx, f.anna)
	if len(rows) != 1 || rows[0].TxnID != "" || rows[0].Hash != YNABHashRetarget || !rows[0].SyncedAt.IsZero() {
		t.Errorf("after account change: %+v", rows)
	}
	if n, _, _ := f.s.YNABSyncSummary(ctx, f.anna); n != 0 {
		t.Errorf("synced after account change = %d", n)
	}
}

func TestYNABCategoryMapAndSummary(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	if err := f.s.SetYNABCategoryMap(ctx, f.anna, map[int64]string{f.food: "y1", 999: ""}, nil); err != nil {
		t.Fatal(err)
	}
	if err := f.s.SetYNABCategoryMap(ctx, f.anna, map[int64]string{999: "y2"}, nil); !isValidation(err) {
		t.Errorf("unknown category: %v", err)
	}
	m, err := f.s.YNABCategoryMap(ctx, f.anna)
	if err != nil || len(m) != 1 || m[f.food] != "y1" {
		t.Errorf("map = %v, %v", m, err)
	}
	if m, _ := f.s.YNABCategoryMap(ctx, f.ben); len(m) != 0 {
		t.Errorf("Ben = %v", m)
	}

	a, _ := f.s.CreateExpense(ctx, f.anna, f.equal("A", 1000, "2026-09-10", f.anna, f.anna, f.ben))
	b, _ := f.s.CreateExpense(ctx, f.anna, f.equal("B", 1000, "2026-09-11", f.anna, f.anna, f.ben))
	f.s.PutYNABSync(ctx,
		YNABSync{ExpenseID: a, ParticipantID: f.anna, TxnID: "t1", Hash: "h"},
		YNABSync{ExpenseID: b, ParticipantID: f.anna, LastError: "broken"})
	n, problems, err := f.s.YNABSyncSummary(ctx, f.anna)
	if err != nil || n != 1 || len(problems) != 1 || problems[0].Title != "B" || problems[0].Error != "broken" || problems[0].Date != date("2026-09-11") {
		t.Errorf("summary = %d, %+v, %v", n, problems, err)
	}
	if err := f.s.DeleteYNABSync(ctx, f.anna, a, b); err != nil {
		t.Fatal(err)
	}
	if rows, _ := f.s.ListYNABSync(ctx, f.anna); len(rows) != 0 {
		t.Errorf("rows = %+v", rows)
	}
}

func TestYNABConnectedAt(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	clock := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.s.SetClock(func() time.Time { return clock })
	f.s.SetYNABToken(ctx, f.anna, "tok", nil)
	if c, _ := f.s.GetYNABConfig(ctx, f.anna); !c.ConnectedAt.IsZero() {
		t.Errorf("token only: ConnectedAt = %v", c.ConnectedAt)
	}
	f.s.SetYNABTarget(ctx, f.anna, YNABTarget{PlanID: "p", AccountID: "a", Start: date("2026-09-01")})
	if c, _ := f.s.GetYNABConfig(ctx, f.anna); !c.ConnectedAt.Equal(clock) {
		t.Errorf("after target: ConnectedAt = %v", c.ConnectedAt)
	}
	// Changing only the start date: timestamp is kept.
	clock = clock.Add(time.Hour)
	f.s.SetYNABTarget(ctx, f.anna, YNABTarget{PlanID: "p", AccountID: "a", Start: date("2026-08-01")})
	if c, _ := f.s.GetYNABConfig(ctx, f.anna); !c.ConnectedAt.Equal(clock.Add(-time.Hour)) {
		t.Errorf("start date changed: ConnectedAt = %v", c.ConnectedAt)
	}
	// Account changed: set up anew.
	f.s.SetYNABTarget(ctx, f.anna, YNABTarget{PlanID: "p", AccountID: "b", Start: date("2026-08-01")})
	c, _ := f.s.GetYNABConfig(ctx, f.anna)
	if !c.ConnectedAt.Equal(clock) {
		t.Errorf("account change: ConnectedAt = %v", c.ConnectedAt)
	}
	if list, _ := f.s.ListYNABConfigs(ctx); len(list) != 1 || !list[0].ConnectedAt.Equal(clock) {
		t.Errorf("ListYNABConfigs = %+v", list)
	}
	// Legacy data without a stored timestamp: EnsureYNABConnectedAt sets it once.
	f.s.SetYNABToken(ctx, f.ben, "tok-b", nil)
	got, err := f.s.EnsureYNABConnectedAt(ctx, f.ben)
	if err != nil || !got.Equal(clock) {
		t.Errorf("Ensure = %v, %v", got, err)
	}
	clock = clock.Add(time.Hour)
	if got, _ := f.s.EnsureYNABConnectedAt(ctx, f.ben); !got.Equal(clock.Add(-time.Hour)) {
		t.Errorf("Ensure overwrites: %v", got)
	}
	if _, err := f.s.EnsureYNABConnectedAt(ctx, f.cleo); !errors.Is(err, ErrNotFound) {
		t.Errorf("Ensure without connection: %v", err)
	}
}

func TestYNABStatus(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	if _, err := f.s.GetYNABStatus(ctx, f.anna); !errors.Is(err, ErrNotFound) {
		t.Errorf("without connection: %v", err)
	}
	if err := f.s.SetYNABStatus(ctx, f.anna, YNABStatus{Summary: "x"}); !errors.Is(err, ErrNotFound) {
		t.Errorf("set without connection: %v", err)
	}
	f.s.SetYNABToken(ctx, f.anna, "tok", nil)
	if st, err := f.s.GetYNABStatus(ctx, f.anna); err != nil || st != (YNABStatus{}) {
		t.Errorf("new connection: %+v, %v", st, err)
	}
	run := time.Date(2026, 9, 1, 10, 0, 0, 123456789, time.UTC)
	want := YNABStatus{LastRun: run, LastSync: run.Add(-time.Hour), Summary: "1 neu", Error: "kaputt",
		TokenInvalid: true, RetryAt: run.Add(5 * time.Minute), Backoff: 10 * time.Minute}
	if err := f.s.SetYNABStatus(ctx, f.anna, want); err != nil {
		t.Fatal(err)
	}
	if st, err := f.s.GetYNABStatus(ctx, f.anna); err != nil || st != want {
		t.Errorf("status = %+v, %v; want %+v", st, err, want)
	}
	// The target does not touch the status.
	f.s.SetYNABTarget(ctx, f.anna, YNABTarget{PlanID: "p", AccountID: "a", Start: date("2026-09-01")})
	if st, _ := f.s.GetYNABStatus(ctx, f.anna); st != want {
		t.Errorf("after target: %+v", st)
	}
	// A new token resets what belonged to the old one, in the same write.
	f.s.SetYNABToken(ctx, f.anna, "tok-2", nil)
	reset := YNABStatus{LastRun: want.LastRun, LastSync: want.LastSync, Summary: want.Summary}
	if st, _ := f.s.GetYNABStatus(ctx, f.anna); st != reset {
		t.Errorf("after new token: %+v; want %+v", st, reset)
	}
	f.s.SetYNABStatus(ctx, f.anna, want)
	f.s.SetYNABToken(ctx, f.anna, "", nil)
	if st, _ := f.s.GetYNABStatus(ctx, f.anna); st != reset {
		t.Errorf("after disconnect: %+v", st)
	}
}

// Migration 5 moves the YNAB status (JSON) and connection time from the
// settings table into ynab_config and removes the old keys.
func TestMigrationMovesYNABStateIntoConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "zipfelkasse.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	f := fixture{s: s, anna: mustParticipant(t, s, "Anna"), ben: mustParticipant(t, s, "Ben"), cleo: mustParticipant(t, s, "Cleo")}
	ctx := context.Background()
	for _, id := range []int64{f.anna, f.ben} {
		if _, err := s.SetYNABToken(ctx, id, "tok", nil); err != nil {
			t.Fatal(err)
		}
	}
	// Old state: schema version 4, the values in settings.
	key := func(prefix string, id int64) string { return prefix + strconv.FormatInt(id, 10) }
	for _, q := range []string{
		"ALTER TABLE ynab_config DROP COLUMN connected_at",
		"ALTER TABLE ynab_config DROP COLUMN last_run",
		"ALTER TABLE ynab_config DROP COLUMN last_sync",
		"ALTER TABLE ynab_config DROP COLUMN summary",
		"ALTER TABLE ynab_config DROP COLUMN error",
		"ALTER TABLE ynab_config DROP COLUMN token_invalid",
		"ALTER TABLE ynab_config DROP COLUMN retry_at",
		"ALTER TABLE ynab_config DROP COLUMN backoff_seconds",
		"PRAGMA user_version = 4",
	} {
		if _, err := s.db.ExecContext(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	for k, v := range map[string]string{
		key("ynab.connected.", f.anna): "2026-09-01T10:00:00Z",
		key("ynab.status.", f.anna): `{"last_run":"2026-09-20T12:00:00.5+02:00","last_sync":"2026-09-20T09:00:00Z",` +
			`"summary":"1 neu · 0 geändert · 0 gelöscht","error":"Das YNAB-Anfragelimit ist erreicht.",` +
			`"token_invalid":true,"retry_at":"2026-09-20T10:10:00Z","backoff":600000000000}`,
		key("ynab.status.", f.ben):     "{kaputt",              // unreadable: like no status
		key("ynab.connected.", f.cleo): "2026-09-01T10:00:00Z", // no connection: dropped
		key("ynab.status.", f.cleo):    "{}",
	} {
		if err := s.SetSetting(ctx, k, v); err != nil {
			t.Fatal(err)
		}
	}
	s.Close()

	for round := range 2 {
		if s, err = Open(path); err != nil {
			t.Fatal(err)
		}
		if v, _ := s.SchemaVersion(ctx); v != latestVersion(t) {
			t.Errorf("round %d: SchemaVersion = %d", round, v)
		}
		c, _ := s.GetYNABConfig(ctx, f.anna)
		if !c.ConnectedAt.Equal(time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)) {
			t.Errorf("round %d: ConnectedAt = %v", round, c.ConnectedAt)
		}
		want := YNABStatus{
			LastRun:  time.Date(2026, 9, 20, 10, 0, 0, 5e8, time.UTC),
			LastSync: time.Date(2026, 9, 20, 9, 0, 0, 0, time.UTC),
			Summary:  "1 neu · 0 geändert · 0 gelöscht", Error: "Das YNAB-Anfragelimit ist erreicht.",
			TokenInvalid: true, RetryAt: time.Date(2026, 9, 20, 10, 10, 0, 0, time.UTC), Backoff: 10 * time.Minute,
		}
		st, err := s.GetYNABStatus(ctx, f.anna)
		if err != nil || !st.LastRun.Equal(want.LastRun) || !st.LastSync.Equal(want.LastSync) || !st.RetryAt.Equal(want.RetryAt) {
			t.Errorf("round %d: status = %+v, %v; want %+v", round, st, err, want)
		}
		st.LastRun, st.LastSync, st.RetryAt = want.LastRun, want.LastSync, want.RetryAt
		if st != want {
			t.Errorf("round %d: status = %+v; want %+v", round, st, want)
		}
		if c, _ := s.GetYNABConfig(ctx, f.ben); !c.ConnectedAt.IsZero() {
			t.Errorf("round %d: Ben ConnectedAt = %v", round, c.ConnectedAt)
		}
		if st, err := s.GetYNABStatus(ctx, f.ben); err != nil || st != (YNABStatus{}) {
			t.Errorf("round %d: Ben status = %+v, %v", round, st, err)
		}
		var n int
		s.db.QueryRowContext(ctx, "SELECT count(*) FROM settings WHERE key LIKE 'ynab%'").Scan(&n)
		if n != 0 {
			t.Errorf("round %d: %d ynab keys left in settings", round, n)
		}
		s.Close()
	}
}
