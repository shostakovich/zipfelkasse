package store

import (
	"context"
	"errors"
	"testing"

	"github.com/shostakovich/zipfelkasse/internal/domain"
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
		t.Errorf("invalid frequency: %v", err)
	}
	if _, err := f.s.CreateRecurringFromExpense(ctx, f.anna, 999, domain.FreqMonthly); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown expense: %v", err)
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
		t.Errorf("rule = %+v", r)
	}
	if r.Template.Title != "Miete" || r.Template.AmountCents != 100000 || r.Template.Notes != "Januar" ||
		len(r.Template.Parts) != 2 || !r.Template.Date.IsZero() || r.Template.RecurringID != 0 || r.Template.OriginalCurrency != "EUR" {
		t.Errorf("template = %+v", r.Template)
	}
	e, _ := f.s.GetExpense(ctx, eid)
	if e.RecurringID != rid {
		t.Errorf("original expense recurring_id = %d, want %d", e.RecurringID, rid)
	}
	if _, err := f.s.CreateRecurringFromExpense(ctx, f.anna, eid, domain.FreqWeekly); !isValidation(err) {
		t.Errorf("second rule for the same expense: %v", err)
	}
	acts, _ := f.s.ListActivity(ctx, ActivityFilter{ExpenseID: eid})
	if len(acts) != 2 || acts[0].Action != ActionRecurringCreated || acts[0].Details.Text == "" {
		t.Errorf("Activity = %+v", acts)
	}

	// The original expense at the anchor counts as the first instance.
	in.RecurringID = rid
	if _, err := f.s.CreateExpense(ctx, 0, in); !errors.Is(err, ErrRecurringExists) {
		t.Errorf("instance at anchor = %v, want ErrRecurringExists", err)
	}

	due, _ := f.s.DueRecurring(ctx, date("2026-02-27"))
	if len(due) != 0 {
		t.Errorf("DueRecurring before occurrence = %+v", due)
	}
	due, _ = f.s.DueRecurring(ctx, date("2026-02-28"))
	if len(due) != 1 {
		t.Errorf("DueRecurring on occurrence = %+v", due)
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
		t.Errorf("paused rule due: %+v", due)
	}
	// Resuming on Wednesday, Mar 4: next occurrence Monday, Mar 9 (no catch-up).
	if err := f.s.SetRecurringActive(ctx, rid, true, date("2026-03-04")); err != nil {
		t.Fatal(err)
	}
	r, _ := f.s.GetRecurring(ctx, rid)
	if !r.Active || r.NextDate != date("2026-03-09") {
		t.Errorf("after resume: %+v", r)
	}
	// Resuming exactly on an occurrence: the occurrence itself counts.
	f.s.SetRecurringActive(ctx, rid, false, date("2026-03-05"))
	f.s.SetRecurringActive(ctx, rid, true, date("2026-03-16"))
	r, _ = f.s.GetRecurring(ctx, rid)
	if r.NextDate != date("2026-03-16") {
		t.Errorf("resume on occurrence: %+v", r)
	}
	if err := f.s.SetRecurringActive(ctx, 999, true, date("2026-03-16")); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown rule: %v", err)
	}

	// next_date only advances from the expected value.
	if err := f.s.SetRecurringNextDate(ctx, rid, date("2026-03-09"), date("2026-03-23")); !errors.Is(err, ErrRecurringChanged) {
		t.Errorf("advance from a stale next_date: %v", err)
	}
	if err := f.s.SetRecurringNextDate(ctx, rid, date("2026-03-16"), date("2026-03-23")); err != nil {
		t.Fatal(err)
	}
	list, _ := f.s.ListRecurring(ctx)
	if len(list) != 1 || list[0].NextDate != date("2026-03-23") {
		t.Errorf("ListRecurring = %+v", list)
	}

	// A paused rule neither advances nor gets instances.
	f.s.SetRecurringActive(ctx, rid, false, date("2026-03-23"))
	if err := f.s.SetRecurringNextDate(ctx, rid, date("2026-03-23"), date("2026-03-30")); !errors.Is(err, ErrRecurringChanged) {
		t.Errorf("advance a paused rule: %v", err)
	}
	in := f.equal("Kino", 2000, "2026-03-23", f.anna, f.anna, f.ben)
	in.RecurringID = rid
	if _, err := f.s.CreateExpense(ctx, 0, in); !errors.Is(err, ErrRecurringChanged) {
		t.Errorf("instance of a paused rule: %v", err)
	}
	f.s.SetRecurringActive(ctx, rid, true, date("2026-03-23"))

	if err := f.s.DeleteRecurring(ctx, f.ben, rid); err != nil {
		t.Fatal(err)
	}
	// A deleted rule: no foreign key error, but ErrRecurringChanged.
	if _, err := f.s.CreateExpense(ctx, 0, in); !errors.Is(err, ErrRecurringChanged) {
		t.Errorf("instance of a deleted rule: %v", err)
	}
	if err := f.s.SetRecurringNextDate(ctx, rid, date("2026-03-23"), date("2026-03-30")); !errors.Is(err, ErrRecurringChanged) {
		t.Errorf("advance a deleted rule: %v", err)
	}
	if _, err := f.s.GetRecurring(ctx, rid); !errors.Is(err, ErrNotFound) {
		t.Errorf("after delete: %v", err)
	}
	e, err := f.s.GetExpense(ctx, eid)
	if err != nil || e.Deleted() || e.RecurringID != 0 {
		t.Errorf("expense after deleting the rule: %+v, %v", e, err)
	}
	if err := f.s.DeleteRecurring(ctx, f.ben, rid); !errors.Is(err, ErrNotFound) {
		t.Errorf("second delete: %v", err)
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
		t.Errorf("template = %+v", r.Template)
	}
	// Deleted instances do not count.
	f.s.DeleteExpense(ctx, f.anna, id2)
	f.s.DeleteExpense(ctx, f.anna, eid)
	if err := f.s.UpdateRecurringTemplateFromLatest(ctx, rid); !errors.Is(err, ErrNotFound) {
		t.Errorf("without instance: %v", err)
	}
}
