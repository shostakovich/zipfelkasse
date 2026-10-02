package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestYNABConfig(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	if _, err := f.s.GetYNABConfig(ctx, f.anna); !errors.Is(err, ErrNotFound) {
		t.Fatalf("leer: %v", err)
	}
	if err := f.s.SetYNABTarget(ctx, f.anna, "p", "a", date("2026-09-01")); !errors.Is(err, ErrNotFound) {
		t.Errorf("Ziel ohne Token: %v", err)
	}
	if err := f.s.SetYNABToken(ctx, f.anna, "tok"); err != nil {
		t.Fatal(err)
	}
	c, err := f.s.GetYNABConfig(ctx, f.anna)
	if err != nil || c.Token != "tok" || !c.Enabled || c.Ready() || !c.StartDate.IsZero() {
		t.Fatalf("nach Token: %+v, %v", c, err)
	}
	if err := f.s.SetYNABTarget(ctx, f.anna, "p", "a", date("2026-09-01")); err != nil {
		t.Fatal(err)
	}
	c, _ = f.s.GetYNABConfig(ctx, f.anna)
	if c.PlanID != "p" || c.AccountID != "a" || c.StartDate != date("2026-09-01") || !c.Ready() {
		t.Errorf("nach Ziel: %+v", c)
	}

	// Ben hat einen Token, Cleo ist archiviert, Anna trennt später.
	f.s.SetYNABToken(ctx, f.ben, "tok-b")
	f.s.SetYNABToken(ctx, f.cleo, "tok-c")
	f.s.SetParticipantArchived(ctx, f.cleo, true)
	list, err := f.s.ListYNABConfigs(ctx)
	if err != nil || len(list) != 2 || list[0].ParticipantID != f.anna || list[1].ParticipantID != f.ben {
		t.Errorf("ListYNABConfigs = %+v, %v", list, err)
	}
	f.s.SetYNABToken(ctx, f.anna, "")
	c, _ = f.s.GetYNABConfig(ctx, f.anna)
	if c.Token != "" || c.Enabled || c.Ready() || c.PlanID != "p" {
		t.Errorf("nach Trennen: %+v", c)
	}
	if list, _ := f.s.ListYNABConfigs(ctx); len(list) != 1 {
		t.Errorf("nach Trennen: %+v", list)
	}
}

func TestYNABTargetChangeResetsSync(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	id, _ := f.s.CreateExpense(ctx, f.anna, f.equal("Kino", 1000, "2026-09-10", f.anna, f.anna, f.ben))
	f.s.SetYNABToken(ctx, f.anna, "tok")
	f.s.SetYNABTarget(ctx, f.anna, "p", "a", date("2026-09-01"))
	at := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	if err := f.s.PutYNABSync(ctx, YNABSync{ExpenseID: id, ParticipantID: f.anna, TxnID: "t1", Hash: "h", SyncedAt: at}); err != nil {
		t.Fatal(err)
	}
	rows, _ := f.s.ListYNABSync(ctx, f.anna)
	if len(rows) != 1 || rows[0].TxnID != "t1" || !rows[0].SyncedAt.Equal(at) {
		t.Fatalf("rows = %+v", rows)
	}
	// Nur das Startdatum ändern: Abgleich bleibt.
	f.s.SetYNABTarget(ctx, f.anna, "p", "a", date("2026-08-01"))
	if rows, _ := f.s.ListYNABSync(ctx, f.anna); len(rows) != 1 {
		t.Error("Startdatum hat Abgleich verworfen")
	}
	f.s.SetYNABTarget(ctx, f.anna, "p", "b", date("2026-08-01"))
	if rows, _ := f.s.ListYNABSync(ctx, f.anna); len(rows) != 0 {
		t.Error("Kontowechsel hat Abgleich nicht verworfen")
	}
}

func TestYNABCategoryMapAndSummary(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	if err := f.s.SetYNABCategoryMap(ctx, f.anna, map[int64]string{f.food: "y1", 999: ""}); err != nil {
		t.Fatal(err)
	}
	if err := f.s.SetYNABCategoryMap(ctx, f.anna, map[int64]string{999: "y2"}); !isValidation(err) {
		t.Errorf("unbekannte Kategorie: %v", err)
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
		YNABSync{ExpenseID: b, ParticipantID: f.anna, LastError: "kaputt"})
	n, problems, err := f.s.YNABSyncSummary(ctx, f.anna)
	if err != nil || n != 1 || len(problems) != 1 || problems[0].Title != "B" || problems[0].Error != "kaputt" || problems[0].Date != date("2026-09-11") {
		t.Errorf("summary = %d, %+v, %v", n, problems, err)
	}
	if err := f.s.DeleteYNABSync(ctx, f.anna, a, b); err != nil {
		t.Fatal(err)
	}
	if rows, _ := f.s.ListYNABSync(ctx, f.anna); len(rows) != 0 {
		t.Errorf("rows = %+v", rows)
	}
}
