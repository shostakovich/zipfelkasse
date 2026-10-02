package store

import (
	"context"
	"slices"
	"testing"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// newActivity returns the entries written since the entry with ID after
// (oldest first) and the ID of the newest entry.
func newActivity(t *testing.T, s *Store, after int64) ([]Activity, int64) {
	t.Helper()
	all, err := s.ListActivity(context.Background(), ActivityFilter{Limit: 1000})
	if err != nil {
		t.Fatal(err)
	}
	var out []Activity
	for _, a := range all {
		if a.ID > after {
			out = append(out, a)
		}
	}
	slices.Reverse(out)
	if len(all) > 0 {
		after = all[0].ID
	}
	return out, after
}

// Every settings mutation writes exactly one entry when it changes
// something, and none when it does not.
func TestSettingsMutationsLogActivity(t *testing.T) {
	f := newFixture(t)
	s := f.s
	ctx := context.Background()
	var dora, emil, kino, rule int64
	eid, err := s.CreateExpense(ctx, f.anna, f.equal("Miete", 100000, "2026-09-01", f.anna, f.anna, f.ben))
	if err != nil {
		t.Fatal(err)
	}
	if rule, err = s.CreateRecurringFromExpense(ctx, f.anna, eid, domain.FreqMonthly); err != nil {
		t.Fatal(err)
	}
	var reset bool
	setToken := func(token string, reachable func(string) bool) func() error {
		return func() (err error) {
			reset, err = s.SetYNABToken(ctx, f.anna, token, reachable)
			return err
		}
	}
	target := YNABTarget{PlanID: "p1", AccountID: "a1", PlanName: "Haushalt", AccountName: "Geteilt", Start: date("2026-09-01")}
	later := target
	later.Start = date("2026-09-15")
	reachable := func(string) bool { return true }
	unreachable := func(string) bool { return false }

	steps := []struct {
		name  string
		do    func() error
		actor *int64 // nil: f.anna
		want  string // "" = no entry
	}{
		{"group name", func() error { return s.SetGroupName(ctx, f.anna, " WG  Zipfel ") }, nil,
			"Gruppe umbenannt: „Zipfelkasse“ → „WG Zipfel“"},
		{"group name unchanged", func() error { return s.SetGroupName(ctx, f.anna, "WG Zipfel") }, nil, ""},
		{"create person", func() (err error) { dora, err = s.CreateParticipant(ctx, f.anna, "Dora"); return err }, nil,
			"Person „Dora“ hinzugefügt"},
		{"rename person unchanged", func() error { return s.RenameParticipant(ctx, f.ben, dora, " Dora ") }, &f.ben, ""},
		{"rename person", func() error { return s.RenameParticipant(ctx, f.ben, dora, "Doro") }, &f.ben,
			"Person „Dora“ umbenannt in „Doro“"},
		{"archive person", func() error { return s.SetParticipantArchived(ctx, f.anna, dora, true) }, nil,
			"Person „Doro“ archiviert"},
		{"restore person", func() error { return s.SetParticipantArchived(ctx, f.anna, dora, false) }, nil,
			"Person „Doro“ reaktiviert"},
		{"join", func() (err error) { emil, err = s.JoinAsParticipant(ctx, "Emil"); return err }, &emil,
			"Person „Emil“ hinzugefügt"},
		{"create category", func() (err error) { kino, err = s.CreateCategory(ctx, f.anna, "Kino"); return err }, nil,
			"Kategorie „Kino“ hinzugefügt"},
		{"rename category unchanged", func() error { return s.RenameCategory(ctx, f.anna, kino, "Kino") }, nil, ""},
		{"rename category", func() error { return s.RenameCategory(ctx, f.anna, kino, "Theater") }, nil,
			"Kategorie „Kino“ umbenannt in „Theater“"},
		{"move category", func() error { return s.MoveCategory(ctx, f.anna, kino, true) }, nil,
			"Kategorie „Theater“ nach oben verschoben"},
		{"move category at the edge", func() error { return s.MoveCategory(ctx, f.anna, f.food, true) }, nil, ""},
		{"archive category", func() error { return s.SetCategoryArchived(ctx, f.anna, kino, true) }, nil,
			"Kategorie „Theater“ archiviert"},
		{"restore category", func() error { return s.SetCategoryArchived(ctx, f.anna, kino, false) }, nil,
			"Kategorie „Theater“ reaktiviert"},
		{"manual rate", func() error { return s.SetManualFXRate(ctx, f.anna, " usd ", date("2026-09-01"), 1.25) }, nil,
			"Manueller Kurs für USD ab 01.09.2026 gespeichert: 1 € = 1,25 USD"},
		{"delete manual rate", func() error { return s.DeleteManualFXRate(ctx, f.anna, "usd", date("2026-09-01")) }, nil,
			"Manueller Kurs für USD ab 01.09.2026 gelöscht"},
		{"pause rule", func() error { return s.SetRecurringActive(ctx, f.anna, rule, false, date("2026-09-10")) }, nil,
			"Wiederholung „Miete“ (monatlich) pausiert"},
		{"resume rule", func() error { return s.SetRecurringActive(ctx, f.anna, rule, true, date("2026-09-10")) }, nil,
			"Wiederholung „Miete“ (monatlich) fortgesetzt"},
		{"refresh template", func() error { return s.UpdateRecurringTemplateFromLatest(ctx, f.anna, rule) }, nil,
			"Wiederholung „Miete“ (monatlich): Vorlage aus der letzten Ausgabe übernommen"},
		{"connect YNAB", setToken("tok", nil), nil, "YNAB verbunden (Token gesetzt)"},
		{"YNAB target", func() error { return s.SetYNABTarget(ctx, f.anna, target) }, nil,
			"YNAB: Konto „Geteilt“ im Plan „Haushalt“ gewählt, Startdatum 01.09.2026"},
		{"YNAB target unchanged", func() error { return s.SetYNABTarget(ctx, f.anna, target) }, nil, ""},
		{"YNAB start date", func() error { return s.SetYNABTarget(ctx, f.anna, later) }, nil,
			"YNAB: Startdatum 01.09.2026 → 15.09.2026"},
		{"replace YNAB token", setToken("tok-2", reachable), nil, "YNAB-Token ersetzt"},
		{"YNAB category map", func() error {
			return s.SetYNABCategoryMap(ctx, f.anna, map[int64]string{f.food: "y1"}, map[string]string{"y1": "Essen"})
		}, nil, "YNAB: Kategorie-Zuordnung geändert (Lebensmittel → Essen)"},
		{"YNAB category map unchanged", func() error {
			return s.SetYNABCategoryMap(ctx, f.anna, map[int64]string{f.food: "y1", kino: ""}, nil)
		}, nil, ""},
		{"YNAB category unmapped", func() error {
			return s.SetYNABCategoryMap(ctx, f.anna, map[int64]string{f.food: ""}, nil)
		}, nil, "YNAB: Kategorie-Zuordnung geändert (Lebensmittel → unkategorisiert (vorher (nicht mehr vorhanden)))"},
		{"YNAB token of another user", setToken("tok-3", unreachable), nil,
			"YNAB-Token ersetzt (Plan und Konto zurückgesetzt)"},
		{"disconnect YNAB", setToken("", nil), nil, "YNAB-Verbindung getrennt"},
	}
	_, last := newActivity(t, s, 0)
	for _, st := range steps {
		if err := st.do(); err != nil {
			t.Fatalf("%s: %v", st.name, err)
		}
		var acts []Activity
		acts, last = newActivity(t, s, last)
		actor := f.anna
		if st.actor != nil {
			actor = *st.actor
		}
		switch {
		case st.want == "" && len(acts) != 0:
			t.Errorf("%s: unexpected activity %+v", st.name, acts)
		case st.want == "":
		case len(acts) != 1:
			t.Errorf("%s: activity = %+v, want one entry", st.name, acts)
		case acts[0].Action != ActionSettingsUpdated || acts[0].Details.Text != st.want || acts[0].ActorID != actor || acts[0].ExpenseID != 0:
			t.Errorf("%s: activity = %+v, want %q by %d", st.name, acts[0], st.want, actor)
		}
		if st.name == "YNAB token of another user" {
			if c, _ := s.GetYNABConfig(ctx, f.anna); !reset || c.PlanID != "" || c.AccountID != "" || !c.StartDate.Equal(later.Start) {
				t.Errorf("target not reset: %v, %+v", reset, c)
			}
		}
	}
}

// Failed mutations write no entry.
func TestFailedMutationsLogNothing(t *testing.T) {
	f := newFixture(t)
	s := f.s
	ctx := context.Background()
	_, last := newActivity(t, s, 0)
	for name, err := range map[string]error{
		"duplicate person":   s.RenameParticipant(ctx, f.anna, f.ben, "anna"),
		"empty group name":   s.SetGroupName(ctx, f.anna, " "),
		"unknown category":   s.SetCategoryArchived(ctx, f.anna, 999, true),
		"unknown manual fx":  s.DeleteManualFXRate(ctx, f.anna, "USD", date("2026-09-01")),
		"unknown rule":       s.SetRecurringActive(ctx, f.anna, 999, false, date("2026-09-01")),
		"no YNAB connection": s.SetYNABTarget(ctx, f.anna, YNABTarget{PlanID: "p", AccountID: "a"}),
	} {
		if err == nil {
			t.Errorf("%s: no error", name)
		}
	}
	if acts, _ := newActivity(t, s, last); len(acts) != 0 {
		t.Errorf("activity = %+v", acts)
	}
}

// A failing activity insert rolls back the change it describes.
func TestActivityFailureRollsBackChange(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	if _, err := f.s.db.Exec(`CREATE TRIGGER no_activity BEFORE INSERT ON activity
		BEGIN SELECT RAISE(ABORT, 'no activity'); END`); err != nil {
		t.Fatal(err)
	}
	if err := f.s.RenameParticipant(ctx, f.anna, f.ben, "Benno"); err == nil {
		t.Fatal("RenameParticipant: no error")
	}
	if p, _ := f.s.GetParticipant(ctx, f.ben); p.Name != "Ben" {
		t.Errorf("name = %q, want the old one", p.Name)
	}
	if err := f.s.SetGroupName(ctx, f.anna, "WG"); err == nil {
		t.Fatal("SetGroupName: no error")
	}
	if got := f.s.GroupName(ctx); got != "Zipfelkasse" {
		t.Errorf("group name = %q, want the old one", got)
	}
}
