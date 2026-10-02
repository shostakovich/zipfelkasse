package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func mustParticipant(t *testing.T, s *Store, name string) int64 {
	t.Helper()
	id, err := s.CreateParticipant(context.Background(), name)
	if err != nil {
		t.Fatalf("CreateParticipant(%q): %v", name, err)
	}
	return id
}

func date(s string) time.Time {
	t, err := time.Parse(domain.DateLayout, s)
	if err != nil {
		panic(err)
	}
	return t
}

func isValidation(err error) bool {
	var ve domain.ValidationError
	return errors.As(err, &ve)
}

func TestOpenMigratesAndSeeds(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	v, err := s.SchemaVersion(ctx)
	if err != nil || v != 3 {
		t.Fatalf("SchemaVersion = %d, %v; want 3", v, err)
	}
	if acts, _ := s.ListActivity(ctx, ActivityFilter{}); len(acts) != 0 {
		t.Errorf("empty database: activity %+v", acts)
	}
	cats, err := s.ListCategories(ctx, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(cats) != 10 || cats[0].Name != "Lebensmittel" || cats[len(cats)-1].Name != "Sonstiges" {
		t.Errorf("wrong seed categories: %+v", cats)
	}
	if got := s.GroupName(ctx); got != "Zipfelkasse" {
		t.Errorf("GroupName = %q", got)
	}
	if cur, _ := s.GetSetting(ctx, SettingDefaultCurrency); cur != "EUR" {
		t.Errorf("default_currency = %q", cur)
	}
}

func TestOpenFileTwiceIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sub", "zipfelkasse.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	mustParticipant(t, s, "Anna")
	var mode string
	if err := s.db.QueryRow("PRAGMA journal_mode").Scan(&mode); err != nil || mode != "wal" {
		t.Errorf("journal_mode = %q, %v", mode, err)
	}
	var fk int
	if err := s.db.QueryRow("PRAGMA foreign_keys").Scan(&fk); err != nil || fk != 1 {
		t.Errorf("foreign_keys = %d, %v", fk, err)
	}
	s.Close()

	s, err = Open(path)
	if err != nil {
		t.Fatalf("second Open: %v", err)
	}
	defer s.Close()
	ps, err := s.ListParticipants(context.Background(), false)
	if err != nil || len(ps) != 1 {
		t.Errorf("participants after reopening = %v, %v", ps, err)
	}
}

func TestParticipants(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	anna := mustParticipant(t, s, "  Anna  ")
	ben := mustParticipant(t, s, "Ben")

	if _, err := s.CreateParticipant(ctx, "anna"); !isValidation(err) {
		t.Errorf("duplicate name: err = %v, want ValidationError", err)
	}
	if _, err := s.CreateParticipant(ctx, "   "); !isValidation(err) {
		t.Errorf("empty name: err = %v", err)
	}
	p, err := s.GetParticipant(ctx, anna)
	if err != nil || p.Name != "Anna" || p.Archived() || p.CreatedAt.IsZero() {
		t.Errorf("GetParticipant = %+v, %v", p, err)
	}
	if err := s.RenameParticipant(ctx, ben, "Benedikt"); err != nil {
		t.Fatal(err)
	}
	if err := s.RenameParticipant(ctx, ben, "ANNA"); !isValidation(err) {
		t.Errorf("rename to a taken name: %v", err)
	}
	if err := s.SetParticipantArchived(ctx, ben, true); err != nil {
		t.Fatal(err)
	}
	active, _ := s.ListParticipants(ctx, false)
	all, _ := s.ListParticipants(ctx, true)
	if len(active) != 1 || len(all) != 2 || !all[1].Archived() {
		t.Errorf("active=%v all=%v", active, all)
	}
	if err := s.SetParticipantArchived(ctx, ben, false); err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetParticipant(ctx, 999); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown ID: %v", err)
	}
	if err := s.RenameParticipant(ctx, 999, "X"); !errors.Is(err, ErrNotFound) {
		t.Errorf("rename unknown ID: %v", err)
	}
}

func TestCategories(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	id, err := s.CreateCategory(ctx, "Haustiere")
	if err != nil {
		t.Fatal(err)
	}
	cats, _ := s.ListCategories(ctx, false)
	if cats[len(cats)-1].Name != "Sonstiges" || cats[len(cats)-2].ID != id {
		t.Errorf("new category not before Sonstiges: %+v", cats)
	}
	if _, err := s.CreateCategory(ctx, "lebensmittel"); !isValidation(err) {
		t.Errorf("duplicate category: %v", err)
	}
	if err := s.RenameCategory(ctx, id, "Tiere"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetCategoryArchived(ctx, id, true); err != nil {
		t.Fatal(err)
	}
	c, err := s.GetCategory(ctx, id)
	if err != nil || c.Name != "Tiere" || !c.Archived() {
		t.Errorf("GetCategory = %+v, %v", c, err)
	}
}

func TestSettings(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	if _, err := s.GetSetting(ctx, "nix"); !errors.Is(err, ErrNotFound) {
		t.Errorf("GetSetting(nix) = %v", err)
	}
	if err := s.SetSetting(ctx, SettingGroupName, "WG Sonnenallee"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetSetting(ctx, SettingGroupName, "WG Sonnenallee 2"); err != nil {
		t.Fatal(err)
	}
	if got := s.GroupName(ctx); got != "WG Sonnenallee 2" {
		t.Errorf("GroupName = %q", got)
	}
}

type fixture struct {
	s               *Store
	anna, ben, cleo int64
	food            int64
}

func newFixture(t *testing.T) fixture {
	s := newTestStore(t)
	f := fixture{s: s, anna: mustParticipant(t, s, "Anna"), ben: mustParticipant(t, s, "Ben"), cleo: mustParticipant(t, s, "Cleo")}
	cats, _ := s.ListCategories(context.Background(), false)
	f.food = cats[0].ID
	return f
}

func (f fixture) equal(title string, amount int64, d string, payer int64, who ...int64) ExpenseInput {
	in := ExpenseInput{Title: title, Date: date(d), PaidBy: payer, SplitMode: domain.SplitEqual, AmountCents: amount, CategoryID: f.food}
	for _, id := range who {
		in.Parts = append(in.Parts, domain.Part{ParticipantID: id})
	}
	return in
}

func TestCreateGetExpense(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	var events []ExpenseChange
	f.s.OnExpenseChange(func(c ExpenseChange) { events = append(events, c) })

	id, err := f.s.CreateExpense(ctx, f.anna, f.equal(" Einkauf  Rewe ", 1000, "2026-09-30", f.anna, f.anna, f.ben, f.cleo))
	if err != nil {
		t.Fatal(err)
	}
	e, err := f.s.GetExpense(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if e.Title != "Einkauf Rewe" || e.PaidByName != "Anna" || e.CategoryName != "Lebensmittel" || e.Date.Format(domain.DateLayout) != "2026-09-30" {
		t.Errorf("Expense = %+v", e)
	}
	if e.OriginalCurrency != "EUR" || e.OriginalAmountMinor != 1000 || e.FXRate != 1 || e.IsForeign() {
		t.Errorf("currency fields = %+v", e)
	}
	// Expense 1: the extra cent goes to index 1 mod 3 of the tied people (Ben).
	if len(e.Shares) != 3 || e.ShareOf(f.anna) != 333 || e.ShareOf(f.ben) != 334 || e.ShareOf(f.cleo) != 333 {
		t.Errorf("Shares = %+v", e.Shares)
	}
	if len(e.Parts) != 3 || e.Parts[0].Weight != 1 {
		t.Errorf("Parts = %+v", e.Parts)
	}
	if len(events) != 1 || events[0] != (ExpenseChange{id, ActionExpenseCreated}) {
		t.Errorf("hook events = %+v", events)
	}
	acts, err := f.s.ListActivity(ctx, ActivityFilter{})
	if err != nil || len(acts) != 1 {
		t.Fatalf("ListActivity = %v, %v", acts, err)
	}
	a := acts[0]
	if a.Action != ActionExpenseCreated || a.ActorID != f.anna || a.ActorName != "Anna" || a.ExpenseID != id || a.Details.Title != "Einkauf Rewe" || a.Details.AmountCents != 1000 {
		t.Errorf("Activity = %+v", a)
	}
	if _, err := f.s.GetExpense(ctx, 999); !errors.Is(err, ErrNotFound) {
		t.Errorf("GetExpense(999) = %v", err)
	}
}

func TestCreateExpenseValidation(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	base := f.equal("Kino", 2000, "2026-09-01", f.anna, f.anna, f.ben)
	tests := []struct {
		name string
		mod  func(*ExpenseInput)
	}{
		{"without title", func(in *ExpenseInput) { in.Title = " " }},
		{"without date", func(in *ExpenseInput) { in.Date = time.Time{} }},
		{"without payer", func(in *ExpenseInput) { in.PaidBy = 0 }},
		{"amount 0", func(in *ExpenseInput) { in.AmountCents = 0 }},
		{"no participants", func(in *ExpenseInput) { in.Parts = nil }},
		{"unknown payer", func(in *ExpenseInput) { in.PaidBy = 999 }},
		{"unknown person", func(in *ExpenseInput) { in.Parts = append(in.Parts, domain.Part{ParticipantID: 999}) }},
		{"unknown category", func(in *ExpenseInput) { in.CategoryID = 999 }},
		{"wrong percent", func(in *ExpenseInput) {
			in.SplitMode = domain.SplitPercent
			in.Parts = []domain.Part{{ParticipantID: f.anna, Weight: 5000}}
		}},
		{"foreign currency without rate", func(in *ExpenseInput) { in.OriginalCurrency = "USD"; in.OriginalAmountMinor = 2200 }},
		{"foreign currency without amount", func(in *ExpenseInput) { in.OriginalCurrency = "USD"; in.FXRate = 1.1 }},
		{"reimbursement to two", func(in *ExpenseInput) { in.IsReimbursement = true }},
		{"reimbursement to oneself", func(in *ExpenseInput) {
			in.IsReimbursement = true
			in.Parts = []domain.Part{{ParticipantID: f.anna}}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			in := base
			in.Parts = append([]domain.Part(nil), base.Parts...)
			tt.mod(&in)
			if _, err := f.s.CreateExpense(ctx, f.anna, in); !isValidation(err) {
				t.Errorf("err = %v, want ValidationError", err)
			}
		})
	}
	if es, _ := f.s.ListExpenses(ctx, ExpenseFilter{}); len(es) != 0 {
		t.Errorf("invalid expenses were stored: %d", len(es))
	}
}

func TestForeignCurrency(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	in := f.equal("Diner NYC", domain.ToEURCents(10000, "USD", 1.0823), "2026-08-01", f.ben, f.anna, f.ben)
	in.OriginalCurrency, in.OriginalAmountMinor, in.FXRate, in.FXSource = "usd", 10000, 1.0823, domain.FXSourceECB
	id, err := f.s.CreateExpense(ctx, f.ben, in)
	if err != nil {
		t.Fatal(err)
	}
	e, _ := f.s.GetExpense(ctx, id)
	if !e.IsForeign() || e.OriginalCurrency != "USD" || e.AmountCents != 9240 || e.FXRate != 1.0823 || e.FXSource != "ezb" {
		t.Errorf("Expense = %+v", e)
	}
}

func TestUpdateExpense(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	id, err := f.s.CreateExpense(ctx, f.anna, f.equal("Pizza", 3000, "2026-09-01", f.anna, f.anna, f.ben))
	if err != nil {
		t.Fatal(err)
	}
	var events []ExpenseChange
	f.s.OnExpenseChange(func(c ExpenseChange) { events = append(events, c) })

	e, _ := f.s.GetExpense(ctx, id)
	// Saving unchanged: no log entry, no hook.
	if err := f.s.UpdateExpense(ctx, f.ben, id, e.ExpenseInput); err != nil {
		t.Fatal(err)
	}
	if len(events) != 0 {
		t.Errorf("hook for unchanged expense: %v", events)
	}

	in := e.ExpenseInput
	in.Title = "Pizza & Wein"
	in.AmountCents = 4500
	in.SplitMode = domain.SplitShares
	in.Parts = []domain.Part{{ParticipantID: f.anna, Weight: 2}, {ParticipantID: f.ben, Weight: 1}}
	in.CategoryID = 0
	if err := f.s.UpdateExpense(ctx, f.ben, id, in); err != nil {
		t.Fatal(err)
	}
	e, _ = f.s.GetExpense(ctx, id)
	if e.Title != "Pizza & Wein" || e.AmountCents != 4500 || e.ShareOf(f.anna) != 3000 || e.ShareOf(f.ben) != 1500 || e.CategoryID != 0 || e.CategoryName != "" {
		t.Errorf("after update: %+v", e)
	}
	if len(events) != 1 || events[0].Action != ActionExpenseUpdated {
		t.Errorf("hook events = %v", events)
	}
	acts, _ := f.s.ListActivity(ctx, ActivityFilter{ExpenseID: id})
	if len(acts) != 2 || acts[0].Action != ActionExpenseUpdated || acts[0].ActorName != "Ben" {
		t.Fatalf("Activity = %+v", acts)
	}
	fields := map[string]FieldChange{}
	for _, c := range acts[0].Details.Changes {
		fields[c.Field] = c
	}
	if c := fields["Betrag"]; c.Old != "30,00 €" || c.New != "45,00 €" {
		t.Errorf("Betrag change = %+v", c)
	}
	if c := fields["Kategorie"]; c.Old != "Lebensmittel" || c.New != "–" {
		t.Errorf("Kategorie change = %+v", c)
	}
	if c := fields["Aufteilung"]; !strings.HasPrefix(c.New, "Nach Anteilen: Anna 30,00 €") {
		t.Errorf("Aufteilung change = %+v", c)
	}
	if _, ok := fields["Datum"]; ok {
		t.Error("Datum logged as changed")
	}

	if err := f.s.UpdateExpense(ctx, f.ben, 999, in); !errors.Is(err, ErrNotFound) {
		t.Errorf("update unknown = %v", err)
	}
}

// Changes only to rate, rate source or weights (with the same cents) are
// stored and logged.
func TestUpdateExpenseRateAndWeights(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	in := f.equal("Diner", domain.ToEURCents(1000, "USD", 1.25), "2026-08-01", f.ben, f.anna, f.ben)
	in.OriginalCurrency, in.OriginalAmountMinor, in.FXRate, in.FXSource = "USD", 1000, 1.25, domain.FXSourceECB
	in.SplitMode = domain.SplitShares
	in.Parts = []domain.Part{{ParticipantID: f.anna, Weight: 1}, {ParticipantID: f.ben, Weight: 1}}
	id, err := f.s.CreateExpense(ctx, f.ben, in)
	if err != nil {
		t.Fatal(err)
	}
	changes := func() map[string]FieldChange {
		t.Helper()
		acts, _ := f.s.ListActivity(ctx, ActivityFilter{ExpenseID: id, Limit: 1})
		m := map[string]FieldChange{}
		if len(acts) == 1 && acts[0].Action == ActionExpenseUpdated {
			for _, c := range acts[0].Details.Changes {
				m[c.Field] = c
			}
		}
		return m
	}

	in.FXRate = 1.2501 // same euro cents
	if err := f.s.UpdateExpense(ctx, f.anna, id, in); err != nil {
		t.Fatal(err)
	}
	if e, _ := f.s.GetExpense(ctx, id); e.FXRate != 1.2501 {
		t.Errorf("rate not stored: %v", e.FXRate)
	}
	if c := changes()["Kurs"]; c.Old != "1 € = 1,25 USD (EZB)" || c.New != "1 € = 1,2501 USD (EZB)" {
		t.Errorf("Kurs change = %+v", changes())
	}

	in.FXSource = domain.FXSourceManual
	if err := f.s.UpdateExpense(ctx, f.anna, id, in); err != nil {
		t.Fatal(err)
	}
	if e, _ := f.s.GetExpense(ctx, id); e.FXSource != domain.FXSourceManual {
		t.Errorf("source not stored: %v", e.FXSource)
	}
	if c := changes()["Kurs"]; c.New != "1 € = 1,2501 USD (manuell)" {
		t.Errorf("source change = %+v", changes())
	}

	in.Parts = []domain.Part{{ParticipantID: f.anna, Weight: 2}, {ParticipantID: f.ben, Weight: 2}}
	if err := f.s.UpdateExpense(ctx, f.anna, id, in); err != nil {
		t.Fatal(err)
	}
	if e, _ := f.s.GetExpense(ctx, id); e.Parts[0].Weight != 2 {
		t.Errorf("weights not stored: %+v", e.Parts)
	}
	if c := changes()["Anteile"]; c.Old != "Anna 1, Ben 1" || c.New != "Anna 2, Ben 2" {
		t.Errorf("Anteile change = %+v", changes())
	}
}

func TestDeleteExpense(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	id, _ := f.s.CreateExpense(ctx, f.anna, f.equal("Bahn", 5000, "2026-09-02", f.anna, f.anna, f.ben))
	var events []ExpenseChange
	f.s.OnExpenseChange(func(c ExpenseChange) { events = append(events, c) })

	if err := f.s.DeleteExpense(ctx, f.ben, id); err != nil {
		t.Fatal(err)
	}
	if err := f.s.DeleteExpense(ctx, f.ben, id); !errors.Is(err, ErrNotFound) {
		t.Errorf("second delete = %v", err)
	}
	e, err := f.s.GetExpense(ctx, id)
	if err != nil || !e.Deleted() {
		t.Errorf("deleted expense: %+v, %v", e, err)
	}
	if err := f.s.UpdateExpense(ctx, f.ben, id, e.ExpenseInput); !errors.Is(err, ErrNotFound) {
		t.Errorf("update of deleted expense = %v", err)
	}
	if es, _ := f.s.ListExpenses(ctx, ExpenseFilter{}); len(es) != 0 {
		t.Errorf("deleted expense in list")
	}
	if b, _ := f.s.Balances(ctx); len(b) != 0 {
		t.Errorf("deleted expense in balance: %v", b)
	}
	if len(events) != 1 || events[0] != (ExpenseChange{id, ActionExpenseDeleted}) {
		t.Errorf("hook events = %v", events)
	}
	acts, _ := f.s.ListActivity(ctx, ActivityFilter{Limit: 1})
	if acts[0].Action != ActionExpenseDeleted || acts[0].Details.Title != "Bahn" {
		t.Errorf("Activity = %+v", acts[0])
	}
}

func TestListExpensesFilter(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	mk := func(in ExpenseInput) int64 {
		id, err := f.s.CreateExpense(ctx, f.anna, in)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	a := mk(f.equal("Rewe Einkauf", 1000, "2026-09-01", f.anna, f.anna, f.ben))
	b := mk(f.equal("Kino 100%", 2000, "2026-09-15", f.ben, f.ben, f.cleo))
	in := f.equal("Tanken", 3000, "2026-10-01", f.cleo, f.cleo)
	in.CategoryID = 0
	in.Notes = "Rewe-Tankstelle"
	c := mk(in)

	ids := func(es []Expense) []int64 {
		var out []int64
		for _, e := range es {
			out = append(out, e.ID)
		}
		return out
	}
	tests := []struct {
		name string
		f    ExpenseFilter
		want []int64
	}{
		{"all, newest first", ExpenseFilter{}, []int64{c, b, a}},
		{"text in title/notes", ExpenseFilter{Text: "rewe"}, []int64{c, a}},
		{"LIKE characters escaped", ExpenseFilter{Text: "100%"}, []int64{b}},
		{"category", ExpenseFilter{CategoryID: f.food}, []int64{b, a}},
		{"without category", ExpenseFilter{WithoutCategory: true}, []int64{c}},
		{"person pays or is involved", ExpenseFilter{ParticipantID: f.cleo}, []int64{c, b}},
		{"date range", ExpenseFilter{From: date("2026-09-01"), To: date("2026-09-15")}, []int64{b, a}},
		{"Limit/Offset", ExpenseFilter{Limit: 1, Offset: 1}, []int64{b}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			es, err := f.s.ListExpenses(ctx, tt.f)
			if err != nil {
				t.Fatal(err)
			}
			got := ids(es)
			if len(got) != len(tt.want) {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Fatalf("got %v, want %v", got, tt.want)
				}
			}
			for _, e := range es {
				if len(e.Shares) == 0 {
					t.Errorf("expense %d without shares", e.ID)
				}
			}
		})
	}
}

// The extra cent of odd amounts rotates with the expense ID, also after an
// update.
func TestExpenseSharesRotateRemainder(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	people := []int64{f.anna, f.ben}
	extra := map[int64]int{}
	for range 4 {
		id, err := f.s.CreateExpense(ctx, f.anna, f.equal("Kaffee", 301, "2026-09-01", f.anna, f.ben, f.anna))
		if err != nil {
			t.Fatal(err)
		}
		e, _ := f.s.GetExpense(ctx, id)
		want := people[id%2]
		if e.ShareOf(want) != 151 {
			t.Errorf("expense %d: extra cent at %v, want person %d", id, e.Shares, want)
		}
		extra[want]++

		in := e.ExpenseInput
		in.AmountCents = 501
		if err := f.s.UpdateExpense(ctx, f.anna, id, in); err != nil {
			t.Fatal(err)
		}
		if e, _ = f.s.GetExpense(ctx, id); e.ShareOf(want) != 251 {
			t.Errorf("expense %d after update: %v, want extra cent at %d", id, e.Shares, want)
		}
	}
	if extra[f.anna] != 2 || extra[f.ben] != 2 {
		t.Errorf("extra cents unevenly distributed: %v", extra)
	}
}

// Migration 2 redistributes the leftover cents of existing expenses using the
// new rule (domain.Split with expense ID), exactly once.
func TestMigrationResplitsShares(t *testing.T) {
	path := filepath.Join(t.TempDir(), "zipfelkasse.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	f := fixture{s: s, anna: mustParticipant(t, s, "Anna"), ben: mustParticipant(t, s, "Ben"), cleo: mustParticipant(t, s, "Cleo")}
	ctx := context.Background()
	var ids []int64
	for range 4 {
		ids = append(ids, f.mustCreate(t, f.equal("Kaffee", 301, "2026-09-01", f.anna, f.anna, f.ben)))
	}
	fixed := f.equal("Fest", 301, "2026-09-01", f.anna, f.anna, f.ben)
	fixed.SplitMode, fixed.Parts = domain.SplitAmount, []domain.Part{{ParticipantID: f.anna, Weight: 151}, {ParticipantID: f.ben, Weight: 150}}
	fixedID := f.mustCreate(t, fixed)
	gone := f.mustCreate(t, f.equal("Gelöscht", 1000, "2026-09-01", f.anna, f.anna, f.ben, f.cleo))
	if err := s.DeleteExpense(ctx, f.anna, gone); err != nil {
		t.Fatal(err)
	}
	// Old state: extra cent to the smallest ID (for deleted expense 6 to Ben;
	// under the new rule it belongs to index 6 mod 3 = Anna), schema version 1.
	for _, q := range []string{
		"UPDATE expense_shares SET amount_cents = 151 WHERE participant_id = 1 AND expense_id <= 4",
		"UPDATE expense_shares SET amount_cents = 150 WHERE participant_id = 2 AND expense_id <= 4",
		"UPDATE expense_shares SET amount_cents = CASE participant_id WHEN 2 THEN 334 ELSE 333 END WHERE expense_id = 6",
		"PRAGMA user_version = 1",
	} {
		if _, err := s.db.ExecContext(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	before, _ := s.ListActivity(ctx, ActivityFilter{})
	s.Close()

	for round := range 2 {
		if s, err = Open(path); err != nil {
			t.Fatal(err)
		}
		if v, _ := s.SchemaVersion(ctx); v != 3 {
			t.Errorf("round %d: SchemaVersion = %d", round, v)
		}
		for _, id := range ids {
			e, _ := s.GetExpense(ctx, id)
			if want := []int64{f.anna, f.ben}[id%2]; e.ShareOf(want) != 151 {
				t.Errorf("round %d, expense %d: %v, extra cent belongs to %d", round, id, e.Shares, want)
			}
		}
		if e, _ := s.GetExpense(ctx, fixedID); e.ShareOf(f.anna) != 151 || e.ShareOf(f.ben) != 150 {
			t.Errorf("fixed amounts changed: %v", e.Shares)
		}
		if e, _ := s.GetExpense(ctx, gone); e.ShareOf(f.cleo) != 333 || e.ShareOf(f.anna) != 334 || e.ShareOf(f.ben) != 333 {
			t.Errorf("deleted expense 6: %v", e.Shares)
		}
		acts, _ := s.ListActivity(ctx, ActivityFilter{})
		if len(acts) != len(before)+1 || acts[0].Action != ActionSharesRecalculated || acts[0].ActorID != 0 ||
			!strings.Contains(acts[0].Details.Text, "3 Ausgaben") {
			t.Errorf("round %d: activity %+v", round, acts[0])
		}
		s.Close()
	}
}

func TestNextExpenseID(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	if n, err := f.s.NextExpenseID(ctx); err != nil || n != 1 {
		t.Fatalf("empty: %d, %v", n, err)
	}
	id := f.mustCreate(t, f.equal("Kaffee", 300, "2026-09-01", f.anna, f.anna))
	if err := f.s.DeleteExpense(ctx, f.anna, id); err != nil {
		t.Fatal(err)
	}
	if n, _ := f.s.NextExpenseID(ctx); n != id+1 {
		t.Errorf("NextExpenseID = %d, want %d", n, id+1)
	}
	if got := f.mustCreate(t, f.equal("Tee", 300, "2026-09-01", f.anna, f.anna)); got != id+1 {
		t.Errorf("new ID %d, want %d", got, id+1)
	}
}

func TestListExpensesTextIgnoresCaseOfUmlauts(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	mk := func(title, notes string) int64 {
		in := f.equal(title, 1000, "2026-09-01", f.anna, f.anna, f.ben)
		in.Notes = notes
		id, err := f.s.CreateExpense(ctx, f.anna, in)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	lower := mk("bäckerei am markt", "")
	upper := mk("BÄCKER SCHMIDT", "")
	mixed := mk("Brötchen", "vom Bäcker")
	street := mk("Parken Hauptstraße", "")
	caps := mk("PARKHAUS HAUPTSTRASSE", "")
	mk("Baecker ohne Umlaut", "")

	tests := []struct {
		text string
		want []int64
	}{
		{"BÄCKER", []int64{mixed, upper, lower}},
		{"bäcker", []int64{mixed, upper, lower}},
		{"Bäckerei", []int64{lower}},
		{"brötchen", []int64{mixed}},
		{"BRÖTCHEN", []int64{mixed}},
		{"straße", []int64{caps, street}},
		{"STRASSE", []int64{caps, street}},
		{"ẞ", []int64{caps, street}},
	}
	for _, tt := range tests {
		es, err := f.s.ListExpenses(ctx, ExpenseFilter{Text: tt.text})
		if err != nil {
			t.Fatal(err)
		}
		var got []int64
		for _, e := range es {
			got = append(got, e.ID)
		}
		if !slices.Equal(got, tt.want) {
			t.Errorf("Text %q: got %v, want %v", tt.text, got, tt.want)
		}
	}
}

func TestBalancesWithReimbursement(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	if _, err := f.s.CreateExpense(ctx, f.anna, f.equal("Essen", 3000, "2026-09-01", f.anna, f.anna, f.ben, f.cleo)); err != nil {
		t.Fatal(err)
	}
	// Ben pays Anna back 10 €.
	r := ExpenseInput{Title: "Rückzahlung", Date: date("2026-09-02"), PaidBy: f.ben, IsReimbursement: true,
		AmountCents: 1000, Parts: []domain.Part{{ParticipantID: f.anna}}}
	id, err := f.s.CreateExpense(ctx, f.ben, r)
	if err != nil {
		t.Fatal(err)
	}
	e, _ := f.s.GetExpense(ctx, id)
	if !e.IsReimbursement || e.SplitMode != domain.SplitEqual || e.ShareOf(f.anna) != 1000 {
		t.Errorf("reimbursement = %+v", e)
	}
	b, err := f.s.Balances(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if b[f.anna] != 1000 || b[f.ben] != 0 || b[f.cleo] != -1000 {
		t.Errorf("Balances = %v", b)
	}
}

func TestRecurringDuplicate(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	res, err := f.s.db.Exec(`INSERT INTO recurring (template_json, frequency, start_date, next_date, created_at, updated_at)
		VALUES ('{}', 'monthly', '2026-01-31', '2026-02-28', 'x', 'x')`)
	if err != nil {
		t.Fatal(err)
	}
	rid, _ := res.LastInsertId()
	in := f.equal("Miete", 100000, "2026-01-31", f.anna, f.anna, f.ben)
	in.RecurringID = rid
	if _, err := f.s.CreateExpense(ctx, 0, in); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.CreateExpense(ctx, 0, in); !errors.Is(err, ErrRecurringExists) {
		t.Errorf("second instance = %v, want ErrRecurringExists", err)
	}
	acts, _ := f.s.ListActivity(ctx, ActivityFilter{})
	if len(acts) != 1 || acts[0].ActorID != 0 || acts[0].ActorName != "" {
		t.Errorf("system activity = %+v", acts)
	}
}

// Moving an instance onto the date of another instance of the same
// recurrence is an input error (not a 500).
func TestUpdateRecurringDateCollision(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	res, err := f.s.db.Exec(`INSERT INTO recurring (template_json, frequency, start_date, next_date, created_at, updated_at)
		VALUES ('{}', 'monthly', '2026-01-31', '2026-03-31', 'x', 'x')`)
	if err != nil {
		t.Fatal(err)
	}
	rid, _ := res.LastInsertId()
	in := f.equal("Miete", 100000, "2026-01-31", f.anna, f.anna, f.ben)
	in.RecurringID = rid
	if _, err := f.s.CreateExpense(ctx, 0, in); err != nil {
		t.Fatal(err)
	}
	in.Date = date("2026-02-28")
	second, err := f.s.CreateExpense(ctx, 0, in)
	if err != nil {
		t.Fatal(err)
	}
	in.Date = date("2026-01-31")
	err = f.s.UpdateExpense(ctx, f.anna, second, in)
	var ve domain.ValidationError
	if !errors.As(err, &ve) || !strings.Contains(ve.Msg, "Termin") {
		t.Errorf("UpdateExpense = %v, want ValidationError", err)
	}
}

func TestAddActivity(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	if err := f.s.AddActivity(ctx, f.anna, "recurring_created", 0, ActivityDetails{Text: "Miete monatlich"}); err != nil {
		t.Fatal(err)
	}
	acts, _ := f.s.ListActivity(ctx, ActivityFilter{})
	if len(acts) != 1 || acts[0].Details.Text != "Miete monatlich" || acts[0].ExpenseID != 0 {
		t.Errorf("Activity = %+v", acts)
	}
}

func TestBackupAndRotate(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	dir := t.TempDir()
	// Unrelated files are left untouched.
	os.WriteFile(filepath.Join(dir, "notiz.txt"), []byte("x"), 0o644)
	base := time.Date(2026, 10, 1, 3, 0, 0, 0, time.UTC)
	var paths []string
	for i := range 9 {
		f.s.now = func() time.Time { return base.AddDate(0, 0, i) }
		p, err := f.s.Backup(ctx, dir, 7)
		if err != nil {
			t.Fatalf("Backup %d: %v", i, err)
		}
		paths = append(paths, p)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 8 {
		t.Errorf("%d files in backup directory, want 7 backups + notiz.txt", len(entries))
	}
	if _, err := os.Stat(paths[0]); !os.IsNotExist(err) {
		t.Errorf("oldest backup not rotated")
	}
	b, err := Open(paths[8])
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	ps, err := b.ListParticipants(ctx, false)
	if err != nil || len(ps) != 3 {
		t.Errorf("backup contents: %v, %v", ps, err)
	}
}

func TestConcurrentWritesFile(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	anna := mustParticipant(t, s, "Anna")
	var wg sync.WaitGroup
	errs := make(chan error, 20)
	for i := range 20 {
		wg.Go(func() {
			in := ExpenseInput{Title: "x", Date: date("2026-09-01"), PaidBy: anna, SplitMode: domain.SplitEqual,
				AmountCents: int64(100 + i), Parts: []domain.Part{{ParticipantID: anna}}}
			if _, err := s.CreateExpense(ctx, anna, in); err != nil {
				errs <- err
			}
		})
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Errorf("concurrent write: %v", err)
	}
}
