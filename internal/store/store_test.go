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

	"teilen/internal/domain"
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
	if err != nil || v != 1 {
		t.Fatalf("SchemaVersion = %d, %v; want 1", v, err)
	}
	cats, err := s.ListCategories(ctx, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(cats) != 10 || cats[0].Name != "Lebensmittel" || cats[len(cats)-1].Name != "Sonstiges" {
		t.Errorf("Seed-Kategorien falsch: %+v", cats)
	}
	if got := s.GroupName(ctx); got != "teilen" {
		t.Errorf("GroupName = %q", got)
	}
	if cur, _ := s.GetSetting(ctx, SettingDefaultCurrency); cur != "EUR" {
		t.Errorf("default_currency = %q", cur)
	}
}

func TestOpenFileTwiceIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sub", "teilen.db")
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
		t.Fatalf("zweites Open: %v", err)
	}
	defer s.Close()
	ps, err := s.ListParticipants(context.Background(), false)
	if err != nil || len(ps) != 1 {
		t.Errorf("Participants nach Neuöffnen = %v, %v", ps, err)
	}
}

func TestParticipants(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	anna := mustParticipant(t, s, "  Anna  ")
	ben := mustParticipant(t, s, "Ben")

	if _, err := s.CreateParticipant(ctx, "anna"); !isValidation(err) {
		t.Errorf("doppelter Name: err = %v, want ValidationError", err)
	}
	if _, err := s.CreateParticipant(ctx, "   "); !isValidation(err) {
		t.Errorf("leerer Name: err = %v", err)
	}
	p, err := s.GetParticipant(ctx, anna)
	if err != nil || p.Name != "Anna" || p.Archived() || p.CreatedAt.IsZero() {
		t.Errorf("GetParticipant = %+v, %v", p, err)
	}
	if err := s.RenameParticipant(ctx, ben, "Benedikt"); err != nil {
		t.Fatal(err)
	}
	if err := s.RenameParticipant(ctx, ben, "ANNA"); !isValidation(err) {
		t.Errorf("Umbenennen auf vergebenen Namen: %v", err)
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
		t.Errorf("unbekannte ID: %v", err)
	}
	if err := s.RenameParticipant(ctx, 999, "X"); !errors.Is(err, ErrNotFound) {
		t.Errorf("unbekannte ID umbenennen: %v", err)
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
		t.Errorf("neue Kategorie nicht vor Sonstiges: %+v", cats)
	}
	if _, err := s.CreateCategory(ctx, "lebensmittel"); !isValidation(err) {
		t.Errorf("doppelte Kategorie: %v", err)
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
		t.Errorf("Währungsfelder = %+v", e)
	}
	if len(e.Shares) != 3 || e.ShareOf(f.anna) != 334 || e.ShareOf(f.ben) != 333 || e.ShareOf(f.cleo) != 333 {
		t.Errorf("Shares = %+v", e.Shares)
	}
	if len(e.Parts) != 3 || e.Parts[0].Weight != 1 {
		t.Errorf("Parts = %+v", e.Parts)
	}
	if len(events) != 1 || events[0] != (ExpenseChange{id, ActionExpenseCreated}) {
		t.Errorf("Hook-Events = %+v", events)
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
		{"ohne Titel", func(in *ExpenseInput) { in.Title = " " }},
		{"ohne Datum", func(in *ExpenseInput) { in.Date = time.Time{} }},
		{"ohne Zahler", func(in *ExpenseInput) { in.PaidBy = 0 }},
		{"Betrag 0", func(in *ExpenseInput) { in.AmountCents = 0 }},
		{"keine Beteiligten", func(in *ExpenseInput) { in.Parts = nil }},
		{"unbekannter Zahler", func(in *ExpenseInput) { in.PaidBy = 999 }},
		{"unbekannte Person", func(in *ExpenseInput) { in.Parts = append(in.Parts, domain.Part{ParticipantID: 999}) }},
		{"unbekannte Kategorie", func(in *ExpenseInput) { in.CategoryID = 999 }},
		{"Prozent falsch", func(in *ExpenseInput) {
			in.SplitMode = domain.SplitPercent
			in.Parts = []domain.Part{{ParticipantID: f.anna, Weight: 5000}}
		}},
		{"Fremdwährung ohne Kurs", func(in *ExpenseInput) { in.OriginalCurrency = "USD"; in.OriginalAmountMinor = 2200 }},
		{"Fremdwährung ohne Betrag", func(in *ExpenseInput) { in.OriginalCurrency = "USD"; in.FXRate = 1.1 }},
		{"Rückzahlung an zwei", func(in *ExpenseInput) { in.IsReimbursement = true }},
		{"Rückzahlung an sich selbst", func(in *ExpenseInput) {
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
		t.Errorf("ungültige Ausgaben wurden gespeichert: %d", len(es))
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
	// Unverändert speichern: kein Protokoll, kein Hook.
	if err := f.s.UpdateExpense(ctx, f.ben, id, e.ExpenseInput); err != nil {
		t.Fatal(err)
	}
	if len(events) != 0 {
		t.Errorf("Hook bei unveränderter Ausgabe: %v", events)
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
		t.Errorf("nach Update: %+v", e)
	}
	if len(events) != 1 || events[0].Action != ActionExpenseUpdated {
		t.Errorf("Hook-Events = %v", events)
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
		t.Errorf("Betrag-Änderung = %+v", c)
	}
	if c := fields["Kategorie"]; c.Old != "Lebensmittel" || c.New != "–" {
		t.Errorf("Kategorie-Änderung = %+v", c)
	}
	if c := fields["Aufteilung"]; !strings.HasPrefix(c.New, "Nach Anteilen: Anna 30,00 €") {
		t.Errorf("Aufteilung-Änderung = %+v", c)
	}
	if _, ok := fields["Datum"]; ok {
		t.Error("Datum als geändert protokolliert")
	}

	if err := f.s.UpdateExpense(ctx, f.ben, 999, in); !errors.Is(err, ErrNotFound) {
		t.Errorf("Update unbekannt = %v", err)
	}
}

// Änderungen nur an Kurs, Kursquelle oder Gewichten (bei gleichen Cent)
// werden gespeichert und protokolliert.
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

	in.FXRate = 1.2501 // gleiche Euro-Cent
	if err := f.s.UpdateExpense(ctx, f.anna, id, in); err != nil {
		t.Fatal(err)
	}
	if e, _ := f.s.GetExpense(ctx, id); e.FXRate != 1.2501 {
		t.Errorf("Kurs nicht gespeichert: %v", e.FXRate)
	}
	if c := changes()["Kurs"]; c.Old != "1 € = 1,25 USD (EZB)" || c.New != "1 € = 1,2501 USD (EZB)" {
		t.Errorf("Kurs-Änderung = %+v", changes())
	}

	in.FXSource = domain.FXSourceManual
	if err := f.s.UpdateExpense(ctx, f.anna, id, in); err != nil {
		t.Fatal(err)
	}
	if e, _ := f.s.GetExpense(ctx, id); e.FXSource != domain.FXSourceManual {
		t.Errorf("Quelle nicht gespeichert: %v", e.FXSource)
	}
	if c := changes()["Kurs"]; c.New != "1 € = 1,2501 USD (manuell)" {
		t.Errorf("Quellen-Änderung = %+v", changes())
	}

	in.Parts = []domain.Part{{ParticipantID: f.anna, Weight: 2}, {ParticipantID: f.ben, Weight: 2}}
	if err := f.s.UpdateExpense(ctx, f.anna, id, in); err != nil {
		t.Fatal(err)
	}
	if e, _ := f.s.GetExpense(ctx, id); e.Parts[0].Weight != 2 {
		t.Errorf("Gewichte nicht gespeichert: %+v", e.Parts)
	}
	if c := changes()["Anteile"]; c.Old != "Anna 1, Ben 1" || c.New != "Anna 2, Ben 2" {
		t.Errorf("Anteile-Änderung = %+v", changes())
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
		t.Errorf("zweites Löschen = %v", err)
	}
	e, err := f.s.GetExpense(ctx, id)
	if err != nil || !e.Deleted() {
		t.Errorf("gelöschte Ausgabe: %+v, %v", e, err)
	}
	if err := f.s.UpdateExpense(ctx, f.ben, id, e.ExpenseInput); !errors.Is(err, ErrNotFound) {
		t.Errorf("Update gelöschter Ausgabe = %v", err)
	}
	if es, _ := f.s.ListExpenses(ctx, ExpenseFilter{}); len(es) != 0 {
		t.Errorf("gelöschte Ausgabe in Liste")
	}
	if b, _ := f.s.Balances(ctx); len(b) != 0 {
		t.Errorf("gelöschte Ausgabe im Saldo: %v", b)
	}
	if len(events) != 1 || events[0] != (ExpenseChange{id, ActionExpenseDeleted}) {
		t.Errorf("Hook-Events = %v", events)
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
		{"alle, neueste zuerst", ExpenseFilter{}, []int64{c, b, a}},
		{"Text in Titel/Notiz", ExpenseFilter{Text: "rewe"}, []int64{c, a}},
		{"LIKE-Zeichen escaped", ExpenseFilter{Text: "100%"}, []int64{b}},
		{"Kategorie", ExpenseFilter{CategoryID: f.food}, []int64{b, a}},
		{"Person zahlt oder beteiligt", ExpenseFilter{ParticipantID: f.cleo}, []int64{c, b}},
		{"Zeitraum", ExpenseFilter{From: date("2026-09-01"), To: date("2026-09-15")}, []int64{b, a}},
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
					t.Errorf("Ausgabe %d ohne Shares", e.ID)
				}
			}
		})
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
	// Ben zahlt Anna 10 € zurück.
	r := ExpenseInput{Title: "Rückzahlung", Date: date("2026-09-02"), PaidBy: f.ben, IsReimbursement: true,
		AmountCents: 1000, Parts: []domain.Part{{ParticipantID: f.anna}}}
	id, err := f.s.CreateExpense(ctx, f.ben, r)
	if err != nil {
		t.Fatal(err)
	}
	e, _ := f.s.GetExpense(ctx, id)
	if !e.IsReimbursement || e.SplitMode != domain.SplitEqual || e.ShareOf(f.anna) != 1000 {
		t.Errorf("Rückzahlung = %+v", e)
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
		t.Errorf("zweite Instanz = %v, want ErrRecurringExists", err)
	}
	acts, _ := f.s.ListActivity(ctx, ActivityFilter{})
	if len(acts) != 1 || acts[0].ActorID != 0 || acts[0].ActorName != "" {
		t.Errorf("System-Activity = %+v", acts)
	}
}

// Verschiebt man eine Instanz auf den Termin einer anderen Instanz derselben
// Wiederholung, ist das ein Eingabefehler (kein 500).
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
	// Fremde Dateien bleiben unangetastet.
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
		t.Errorf("%d Dateien im Backup-Verzeichnis, want 7 Backups + notiz.txt", len(entries))
	}
	if _, err := os.Stat(paths[0]); !os.IsNotExist(err) {
		t.Errorf("ältestes Backup nicht rotiert")
	}
	b, err := Open(paths[8])
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	ps, err := b.ListParticipants(ctx, false)
	if err != nil || len(ps) != 3 {
		t.Errorf("Backup-Inhalt: %v, %v", ps, err)
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
		t.Errorf("paralleles Schreiben: %v", err)
	}
}
