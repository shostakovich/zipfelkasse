package store

import (
	"context"
	"errors"
	"testing"

	"teilen/internal/domain"
)

func TestCreateRecurringFromExpense(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	in := f.equal("Miete", 100000, "2026-01-31", f.anna, f.anna, f.ben)
	in.Notes = "Januar"
	eid, err := f.s.CreateExpense(ctx, f.anna, in)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.CreateRecurringFromExpense(ctx, f.anna, eid, "daily"); !isValidation(err) {
		t.Errorf("ungültige Häufigkeit: %v", err)
	}
	if _, err := f.s.CreateRecurringFromExpense(ctx, f.anna, 999, domain.FreqMonthly); !errors.Is(err, ErrNotFound) {
		t.Errorf("unbekannte Ausgabe: %v", err)
	}
	rid, err := f.s.CreateRecurringFromExpense(ctx, f.anna, eid, domain.FreqMonthly)
	if err != nil {
		t.Fatal(err)
	}
	r, err := f.s.GetRecurring(ctx, rid)
	if err != nil {
		t.Fatal(err)
	}
	if r.StartDate != date("2026-01-31") || r.NextDate != date("2026-02-28") || !r.Active || r.CreatedBy != f.anna ||
		r.Frequency != domain.FreqMonthly {
		t.Errorf("Regel = %+v", r)
	}
	if r.Template.Title != "Miete" || r.Template.AmountCents != 100000 || r.Template.Notes != "Januar" ||
		len(r.Template.Parts) != 2 || !r.Template.Date.IsZero() || r.Template.RecurringID != 0 || r.Template.OriginalCurrency != "EUR" {
		t.Errorf("Vorlage = %+v", r.Template)
	}
	e, _ := f.s.GetExpense(ctx, eid)
	if e.RecurringID != rid {
		t.Errorf("Ursprungsausgabe recurring_id = %d, want %d", e.RecurringID, rid)
	}
	if _, err := f.s.CreateRecurringFromExpense(ctx, f.anna, eid, domain.FreqWeekly); !isValidation(err) {
		t.Errorf("zweite Regel für dieselbe Ausgabe: %v", err)
	}
	acts, _ := f.s.ListActivity(ctx, ActivityFilter{ExpenseID: eid})
	if len(acts) != 2 || acts[0].Action != ActionRecurringCreated || acts[0].Details.Text == "" {
		t.Errorf("Activity = %+v", acts)
	}

	// Ursprungsausgabe am Anker zählt als erste Instanz.
	in.RecurringID = rid
	if _, err := f.s.CreateExpense(ctx, 0, in); !errors.Is(err, ErrRecurringExists) {
		t.Errorf("Instanz am Anker = %v, want ErrRecurringExists", err)
	}

	due, _ := f.s.DueRecurring(ctx, date("2026-02-27"))
	if len(due) != 0 {
		t.Errorf("DueRecurring vor Termin = %+v", due)
	}
	due, _ = f.s.DueRecurring(ctx, date("2026-02-28"))
	if len(due) != 1 {
		t.Errorf("DueRecurring am Termin = %+v", due)
	}
}

func TestRecurringPauseResumeDelete(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	eid, _ := f.s.CreateExpense(ctx, f.anna, f.equal("Kino", 2000, "2026-01-05", f.anna, f.anna, f.ben))
	rid, err := f.s.CreateRecurringFromExpense(ctx, f.anna, eid, domain.FreqWeekly)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.s.SetRecurringActive(ctx, rid, false, date("2026-01-10")); err != nil {
		t.Fatal(err)
	}
	if due, _ := f.s.DueRecurring(ctx, date("2026-03-01")); len(due) != 0 {
		t.Errorf("pausierte Regel fällig: %+v", due)
	}
	// Fortsetzen am Mittwoch, 04.03.: nächster Termin Montag, 09.03. (keine Nachholung).
	if err := f.s.SetRecurringActive(ctx, rid, true, date("2026-03-04")); err != nil {
		t.Fatal(err)
	}
	r, _ := f.s.GetRecurring(ctx, rid)
	if !r.Active || r.NextDate != date("2026-03-09") {
		t.Errorf("nach Fortsetzen: %+v", r)
	}
	// Fortsetzen genau am Termin: der Termin selbst zählt.
	f.s.SetRecurringActive(ctx, rid, false, date("2026-03-05"))
	f.s.SetRecurringActive(ctx, rid, true, date("2026-03-16"))
	r, _ = f.s.GetRecurring(ctx, rid)
	if r.NextDate != date("2026-03-16") {
		t.Errorf("Fortsetzen am Termin: %+v", r)
	}
	if err := f.s.SetRecurringActive(ctx, 999, true, date("2026-03-16")); !errors.Is(err, ErrNotFound) {
		t.Errorf("unbekannte Regel: %v", err)
	}

	if err := f.s.SetRecurringNextDate(ctx, rid, date("2026-03-23")); err != nil {
		t.Fatal(err)
	}
	list, _ := f.s.ListRecurring(ctx)
	if len(list) != 1 || list[0].NextDate != date("2026-03-23") {
		t.Errorf("ListRecurring = %+v", list)
	}

	if err := f.s.DeleteRecurring(ctx, f.ben, rid); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.GetRecurring(ctx, rid); !errors.Is(err, ErrNotFound) {
		t.Errorf("nach Löschen: %v", err)
	}
	e, err := f.s.GetExpense(ctx, eid)
	if err != nil || e.Deleted() || e.RecurringID != 0 {
		t.Errorf("Ausgabe nach Löschen der Regel: %+v, %v", e, err)
	}
	if err := f.s.DeleteRecurring(ctx, f.ben, rid); !errors.Is(err, ErrNotFound) {
		t.Errorf("zweites Löschen: %v", err)
	}
}

func TestUpdateRecurringTemplateFromLatest(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	eid, _ := f.s.CreateExpense(ctx, f.anna, f.equal("Strom", 5000, "2026-01-15", f.anna, f.anna, f.ben))
	rid, _ := f.s.CreateRecurringFromExpense(ctx, f.anna, eid, domain.FreqMonthly)
	in := f.equal("Strom", 6000, "2026-02-15", f.anna, f.anna, f.ben, f.cleo)
	in.RecurringID = rid
	id2, err := f.s.CreateExpense(ctx, 0, in)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.s.UpdateRecurringTemplateFromLatest(ctx, rid); err != nil {
		t.Fatal(err)
	}
	r, _ := f.s.GetRecurring(ctx, rid)
	if r.Template.AmountCents != 6000 || len(r.Template.Parts) != 3 || !r.Template.Date.IsZero() {
		t.Errorf("Vorlage = %+v", r.Template)
	}
	// Gelöschte Instanzen zählen nicht.
	f.s.DeleteExpense(ctx, f.anna, id2)
	f.s.DeleteExpense(ctx, f.anna, eid)
	if err := f.s.UpdateRecurringTemplateFromLatest(ctx, rid); !errors.Is(err, ErrNotFound) {
		t.Errorf("ohne Instanz: %v", err)
	}
}
