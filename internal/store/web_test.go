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
		t.Errorf("leerer Name: %v", err)
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
		t.Errorf("nach hoch: %v", got)
	}
	// Am Rand: nichts passiert.
	if err := s.MoveCategory(ctx, second.ID, true); err != nil {
		t.Fatal(err)
	}
	if got := names(); got[0] != second.Name {
		t.Errorf("am Rand: %v", got)
	}
	if err := s.MoveCategory(ctx, second.ID, false); err != nil {
		t.Fatal(err)
	}
	if got := names(); got[0] != first.Name || got[1] != second.Name {
		t.Errorf("nach runter: %v", got)
	}
	// Archivierte werden übersprungen bzw. lassen sich nicht verschieben.
	s.SetCategoryArchived(ctx, second.ID, true)
	if err := s.MoveCategory(ctx, second.ID, true); !errors.Is(err, ErrNotFound) {
		t.Errorf("archiviert: %v", err)
	}
	if err := s.MoveCategory(ctx, 999, true); !errors.Is(err, ErrNotFound) {
		t.Errorf("unbekannt: %v", err)
	}
	// Neue Kategorie landet am Ende.
	cats, _ = s.ListCategories(ctx, false)
	s.MoveCategory(ctx, cats[len(cats)-1].ID, true)
	id, err := s.CreateCategory(ctx, "Neu")
	if err != nil {
		t.Fatal(err)
	}
	cats, _ = s.ListCategories(ctx, false)
	if cats[len(cats)-1].ID != id {
		t.Errorf("neue Kategorie nicht am Ende: %+v", cats[len(cats)-1])
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
