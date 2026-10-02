package store

import (
	"context"
	"errors"
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
		t.Errorf("außerhalb des Fensters: %v", err)
	}
	if _, err := s.LookupFXRate(ctx, "JPY", domain.FXSourceECB, date("2026-10-02"), date("2026-09-01")); !errors.Is(err, ErrNotFound) {
		t.Errorf("ungültiger Kurs gespeichert: %v", err)
	}

	// Manuell ersetzt den EZB-Kurs desselben Tages, EZB überschreibt manuell nicht.
	if err := s.SetManualFXRate(ctx, " usd ", date("2026-09-30"), 1.2); err != nil {
		t.Fatal(err)
	}
	if err := s.SaveECBRates(ctx, []domain.FXRate{{Currency: "USD", Date: date("2026-09-30"), Rate: 1.11}}); err != nil {
		t.Fatal(err)
	}
	r, err = s.LookupFXRate(ctx, "USD", domain.FXSourceManual, date("2026-12-01"), time.Time{})
	if err != nil || r.Rate != 1.2 || r.Source != "manuell" {
		t.Errorf("manuell = %+v, %v", r, err)
	}
	r, _ = s.LookupFXRate(ctx, "USD", domain.FXSourceECB, date("2026-09-30"), time.Time{})
	if r.Date != date("2026-09-29") {
		t.Errorf("EZB-Kurs vom 30.09. sollte durch manuellen ersetzt sein: %+v", r)
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
	if len(latest) != 1 || latest[0].Currency != "GBP" {
		t.Errorf("LatestECBRates = %+v", latest)
	}
	st, _ := s.ECBCacheStats(ctx)
	if st.Count != 2 || st.Currencies != 2 || st.From != date("2026-09-29") || st.To != date("2026-09-30") {
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
		t.Errorf("zweites Löschen = %v", err)
	}
	if err := s.DeleteManualFXRate(ctx, "GBP", date("2026-09-30")); !errors.Is(err, ErrNotFound) {
		t.Errorf("EZB-Kurs darf nicht als manuell gelöscht werden: %v", err)
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
