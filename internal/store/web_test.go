package store

import (
	"context"
	"errors"
	"testing"
)

func TestSetGroupName(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	if err := s.SetGroupName(ctx, "  WG   Kastanienallee "); err != nil {
		t.Fatal(err)
	}
	if got := s.GroupName(ctx); got != "WG Kastanienallee" {
		t.Errorf("GroupName = %q", got)
	}
	if err := s.SetGroupName(ctx, "   "); !isValidation(err) {
		t.Errorf("empty name: %v", err)
	}
}

func TestMoveCategory(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	names := func() []string {
		cats, err := s.ListCategories(ctx, false)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, c := range cats[:3] {
			out = append(out, c.Name)
		}
		return out
	}
	cats, _ := s.ListCategories(ctx, false)
	first, second := cats[0], cats[1]
	if err := s.MoveCategory(ctx, second.ID, true); err != nil {
		t.Fatal(err)
	}
	if got := names(); got[0] != second.Name || got[1] != first.Name {
		t.Errorf("after up: %v", got)
	}
	// At the edge: nothing happens.
	if err := s.MoveCategory(ctx, second.ID, true); err != nil {
		t.Fatal(err)
	}
	if got := names(); got[0] != second.Name {
		t.Errorf("at the edge: %v", got)
	}
	if err := s.MoveCategory(ctx, second.ID, false); err != nil {
		t.Fatal(err)
	}
	if got := names(); got[0] != first.Name || got[1] != second.Name {
		t.Errorf("after down: %v", got)
	}
	// Archived ones are skipped and cannot be moved.
	s.SetCategoryArchived(ctx, second.ID, true)
	if err := s.MoveCategory(ctx, second.ID, true); !errors.Is(err, ErrNotFound) {
		t.Errorf("archived: %v", err)
	}
	if err := s.MoveCategory(ctx, 999, true); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown: %v", err)
	}
	// A new category ends up at the end.
	cats, _ = s.ListCategories(ctx, false)
	s.MoveCategory(ctx, cats[len(cats)-1].ID, true)
	id, err := s.CreateCategory(ctx, "Neu")
	if err != nil {
		t.Fatal(err)
	}
	cats, _ = s.ListCategories(ctx, false)
	if cats[len(cats)-1].ID != id {
		t.Errorf("new category not at the end: %+v", cats[len(cats)-1])
	}
}

func TestExpenseCounts(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	f.s.CreateExpense(ctx, f.anna, f.equal("A", 1000, "2026-09-30", f.anna, f.anna, f.ben))
	id, _ := f.s.CreateExpense(ctx, f.anna, f.equal("B", 1000, "2026-09-30", f.ben, f.ben))
	f.s.CreateExpense(ctx, f.anna, f.equal("C", 1000, "2026-09-30", f.cleo, f.ben))
	f.s.DeleteExpense(ctx, f.anna, id)

	byP, err := f.s.ExpenseCountByParticipant(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if byP[f.anna] != 1 || byP[f.ben] != 2 || byP[f.cleo] != 1 {
		t.Errorf("ExpenseCountByParticipant = %v", byP)
	}
	byC, err := f.s.ExpenseCountByCategory(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if byC[f.food] != 2 || len(byC) != 1 {
		t.Errorf("ExpenseCountByCategory = %v", byC)
	}
}

func TestCategoryHistory(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	cats, _ := f.s.ListCategories(ctx, false)
	other, archived := cats[1].ID, cats[2].ID
	mk := func(title, d string, cat int64) int64 {
		in := f.equal(title, 1000, d, f.anna, f.anna, f.ben)
		in.CategoryID = cat
		id, err := f.s.CreateExpense(ctx, f.anna, in)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	mk("Kaufland", "2026-09-01", f.food)
	mk("Kino", "2026-09-10", other)
	mk("Ohne", "2026-09-11", 0)
	mk("Archiviert", "2026-09-12", archived)
	gone := mk("Gelöscht", "2026-09-13", f.food)
	f.s.DeleteExpense(ctx, f.anna, gone)
	f.s.SetCategoryArchived(ctx, archived, true)
	back := f.equal("Rückzahlung", 500, "2026-09-14", f.ben, f.anna)
	back.IsReimbursement = true
	if _, err := f.s.CreateExpense(ctx, f.ben, back); err != nil {
		t.Fatal(err)
	}

	got, err := f.s.CategoryHistory(ctx)
	if err != nil {
		t.Fatal(err)
	}
	want := []TitleCategory{{"Kino", other}, {"Kaufland", f.food}}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("CategoryHistory = %v, want %v", got, want)
	}
}
