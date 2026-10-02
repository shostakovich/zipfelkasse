package store

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

func TestFXRatesECBAndManual(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	err := s.SaveECBRates(ctx, []domain.FXRate{
		{Currency: "USD", Date: date("2026-09-29"), Rate: 1.10},
		{Currency: "USD", Date: date("2026-09-30"), Rate: 1.11},
		{Currency: "GBP", Date: date("2026-09-30"), Rate: 0.85},
		{Currency: "bad", Date: date("2026-09-30"), Rate: 1},
		{Currency: "JPY", Date: date("2026-09-30"), Rate: 0},
	})
	if err != nil {
		t.Fatal(err)
	}
	r, err := s.LookupFXRate(ctx, "USD", domain.FXSourceECB, date("2026-10-02"), date("2026-09-22"))
	if err != nil || r.Rate != 1.11 || r.Date != date("2026-09-30") || r.Source != "ezb" {
		t.Errorf("Lookup = %+v, %v", r, err)
	}
	if _, err := s.LookupFXRate(ctx, "USD", domain.FXSourceECB, date("2026-10-20"), date("2026-10-10")); !errors.Is(err, ErrNotFound) {
		t.Errorf("outside the window: %v", err)
	}
	if _, err := s.LookupFXRate(ctx, "JPY", domain.FXSourceECB, date("2026-10-02"), date("2026-09-01")); !errors.Is(err, ErrNotFound) {
		t.Errorf("invalid rate stored: %v", err)
	}

	// Manual and ECB rates of the same day are stored side by side: neither
	// overwrites the other.
	if err := s.SetManualFXRate(ctx, " usd ", date("2026-09-30"), 1.2); err != nil {
		t.Fatal(err)
	}
	if err := s.SaveECBRates(ctx, []domain.FXRate{{Currency: "USD", Date: date("2026-09-30"), Rate: 1.111}}); err != nil {
		t.Fatal(err)
	}
	r, err = s.LookupFXRate(ctx, "USD", domain.FXSourceManual, date("2026-12-01"), time.Time{})
	if err != nil || r.Rate != 1.2 || r.Source != "manuell" {
		t.Errorf("manual = %+v, %v", r, err)
	}
	r, _ = s.LookupFXRate(ctx, "USD", domain.FXSourceECB, date("2026-09-30"), time.Time{})
	if r.Date != date("2026-09-30") || r.Rate != 1.111 || r.Source != "ezb" {
		t.Errorf("ECB rate of Sep 30 next to the manual one: %+v", r)
	}
	if err := s.SetManualFXRate(ctx, "USD", date("2026-09-30"), 1.21); err != nil {
		t.Fatal(err)
	}
	if r, _ = s.LookupFXRate(ctx, "USD", domain.FXSourceManual, date("2026-09-30"), time.Time{}); r.Rate != 1.21 {
		t.Errorf("manual rate updated = %+v", r)
	}

	for _, bad := range []struct {
		cur  string
		rate float64
	}{{"EUR", 1}, {"US", 1}, {"USD", 0}, {"USD", -1}} {
		if err := s.SetManualFXRate(ctx, bad.cur, date("2026-09-30"), bad.rate); !isValidation(err) {
			t.Errorf("SetManualFXRate(%q, %v) = %v", bad.cur, bad.rate, err)
		}
	}

	ms, _ := s.ListManualFXRates(ctx)
	if len(ms) != 1 || ms[0].Currency != "USD" {
		t.Errorf("ListManualFXRates = %+v", ms)
	}
	latest, _ := s.LatestECBRates(ctx)
	if len(latest) != 2 || latest[0].Currency != "GBP" || latest[1].Currency != "USD" || latest[1].Rate != 1.111 {
		t.Errorf("LatestECBRates = %+v", latest)
	}
	st, _ := s.ECBCacheStats(ctx)
	if st.Count != 3 || st.Currencies != 2 || st.From != date("2026-09-29") || st.To != date("2026-09-30") {
		t.Errorf("ECBCacheStats = %+v", st)
	}
	curs, _ := s.ListFXCurrencies(ctx)
	if len(curs) != 2 || curs[0] != "GBP" || curs[1] != "USD" {
		t.Errorf("ListFXCurrencies = %v", curs)
	}

	if err := s.DeleteManualFXRate(ctx, "USD", date("2026-09-30")); err != nil {
		t.Fatal(err)
	}
	if err := s.DeleteManualFXRate(ctx, "USD", date("2026-09-30")); !errors.Is(err, ErrNotFound) {
		t.Errorf("second delete = %v", err)
	}
	// Deleting the manual rate leaves the ECB rate of that day.
	if r, err = s.LookupFXRate(ctx, "USD", domain.FXSourceECB, date("2026-09-30"), time.Time{}); err != nil ||
		r.Date != date("2026-09-30") || r.Rate != 1.111 {
		t.Errorf("ECB rate after deleting the manual one = %+v, %v", r, err)
	}
	if _, err := s.LookupFXRate(ctx, "USD", domain.FXSourceManual, date("2026-12-01"), time.Time{}); !errors.Is(err, ErrNotFound) {
		t.Errorf("manual rate after delete: %v", err)
	}
	if err := s.DeleteManualFXRate(ctx, "GBP", date("2026-09-30")); !errors.Is(err, ErrNotFound) {
		t.Errorf("ECB rate must not be deleted as manual: %v", err)
	}
}

func TestRecentUsedFXRates(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	in := f.equal("Hotel", 9009, "2026-09-01", f.anna, f.anna, f.ben)
	in.OriginalCurrency, in.OriginalAmountMinor, in.FXRate, in.FXSource = "USD", 10000, 1.11, "ezb"
	if _, err := f.s.CreateExpense(ctx, f.anna, in); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.CreateExpense(ctx, f.anna, f.equal("Brot", 300, "2026-09-02", f.anna, f.anna)); err != nil {
		t.Fatal(err)
	}
	used, err := f.s.RecentUsedFXRates(ctx, 10)
	if err != nil || len(used) != 1 || used[0].Currency != "USD" || used[0].Rate != 1.11 || used[0].Title != "Hotel" {
		t.Errorf("RecentUsedFXRates = %+v, %v", used, err)
	}
}

// Migration 003 moves fx_rates to the primary key (currency, source, date)
// and keeps all existing rates.
func TestMigrationSeparatesFXRateSources(t *testing.T) {
	path := filepath.Join(t.TempDir(), "zipfelkasse.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	// Old state: one row per (currency, date), schema version 2.
	for _, q := range []string{
		"DROP TABLE fx_rates",
		`CREATE TABLE fx_rates (
			date     TEXT NOT NULL,
			currency TEXT NOT NULL,
			rate     REAL NOT NULL CHECK (rate > 0),
			source   TEXT NOT NULL DEFAULT 'ezb',
			PRIMARY KEY (currency, date)
		) WITHOUT ROWID`,
		"INSERT INTO fx_rates (date, currency, rate, source) VALUES ('2026-09-29', 'USD', 1.1, 'ezb'), ('2026-09-30', 'USD', 1.2, 'manuell')",
		"PRAGMA user_version = 2",
	} {
		if _, err := s.db.ExecContext(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	s.Close()

	if s, err = Open(path); err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if v, _ := s.SchemaVersion(ctx); v != 3 {
		t.Errorf("SchemaVersion = %d", v)
	}
	if r, err := s.LookupFXRate(ctx, "USD", domain.FXSourceManual, date("2026-10-01"), time.Time{}); err != nil || r.Rate != 1.2 {
		t.Errorf("manual rate after migration = %+v, %v", r, err)
	}
	if r, err := s.LookupFXRate(ctx, "USD", domain.FXSourceECB, date("2026-10-01"), time.Time{}); err != nil || r.Rate != 1.1 {
		t.Errorf("ECB rate after migration = %+v, %v", r, err)
	}
	// The ECB rate of the manual rate's day can now be stored next to it.
	if err := s.SaveECBRates(ctx, []domain.FXRate{{Currency: "USD", Date: date("2026-09-30"), Rate: 1.11}}); err != nil {
		t.Fatal(err)
	}
	if r, _ := s.LookupFXRate(ctx, "USD", domain.FXSourceECB, date("2026-09-30"), time.Time{}); r.Rate != 1.11 {
		t.Errorf("ECB rate next to the manual one = %+v", r)
	}
	if _, err := s.db.ExecContext(ctx, "INSERT INTO fx_rates (date, currency, rate, source) VALUES ('2026-08-01', 'USD', 1, 'foo')"); err == nil {
		t.Error("unknown source accepted")
	}
}
