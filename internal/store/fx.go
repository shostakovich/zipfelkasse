package store

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// Exchange rates live in fx_rates in ECB format (foreign currency per 1 EUR).
// There is at most one entry per (currency, source, date): manual and ECB
// rates of the same day are stored side by side and never overwrite each
// other. Manual rates take precedence in the lookup (fx.Service.Rate), so
// deleting a manual rate brings back the ECB rate of that day.

// LookupFXRate returns the most recent rate from source (domain.FXSourceECB
// or domain.FXSourceManual) for currency with notBefore ≤ date of rate ≤ date.
// Zero notBefore = no lower bound. No match: ErrNotFound.
func (s *Store) LookupFXRate(ctx context.Context, currency, source string, date, notBefore time.Time) (domain.FXRate, error) {
	q := "SELECT date, rate FROM fx_rates WHERE currency = ? AND source = ? AND date <= ?"
	args := []any{currency, source, formatDate(date)}
	if !notBefore.IsZero() {
		q += " AND date >= ?"
		args = append(args, formatDate(notBefore))
	}
	q += " ORDER BY date DESC LIMIT 1"
	var d string
	r := domain.FXRate{Currency: currency, Source: source}
	err := s.db.QueryRowContext(ctx, q, args...).Scan(&d, &r.Rate)
	if errors.Is(err, sql.ErrNoRows) {
		return r, ErrNotFound
	}
	if err != nil {
		return r, err
	}
	r.Date, err = parseDate(d)
	return r, err
}

// SaveECBRates stores ECB rates (Source is set to "ezb"). Existing ECB rates
// are updated; manual rates are left untouched.
func (s *Store) SaveECBRates(ctx context.Context, rates []domain.FXRate) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		stmt, err := tx.PrepareContext(ctx, `INSERT INTO fx_rates (date, currency, rate, source) VALUES (?, ?, ?, 'ezb')
			ON CONFLICT (currency, source, date) DO UPDATE SET rate = excluded.rate`)
		if err != nil {
			return err
		}
		defer stmt.Close()
		for _, r := range rates {
			if !(r.Rate > 0) || math.IsInf(r.Rate, 0) || !domain.ValidCurrencyCode(r.Currency) {
				continue
			}
			if _, err := stmt.ExecContext(ctx, formatDate(r.Date), r.Currency, r.Rate); err != nil {
				return err
			}
		}
		return nil
	})
}

// SetManualFXRate stores a manually entered rate, valid from date on
// (replacing an existing manual rate of the same day; an ECB rate of that
// day is kept).
func (s *Store) SetManualFXRate(ctx context.Context, currency string, date time.Time, rate float64) error {
	currency = strings.ToUpper(strings.TrimSpace(currency))
	switch {
	case currency == "EUR":
		return invalid("Für Euro braucht es keinen Kurs.")
	case !domain.ValidCurrencyCode(currency):
		return invalid("Bitte einen dreistelligen Währungscode angeben (z. B. USD).")
	case date.IsZero():
		return invalid("Bitte ein Datum angeben.")
	case !(rate > 0) || math.IsInf(rate, 0) || rate > 1e9:
		return invalid("Der Kurs muss größer als 0 sein.")
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO fx_rates (date, currency, rate, source) VALUES (?, ?, ?, 'manuell')
		ON CONFLICT (currency, source, date) DO UPDATE SET rate = excluded.rate`,
		formatDate(domain.DateOf(date)), currency, rate)
	return err
}

// DeleteManualFXRate deletes a manual rate (ErrNotFound if it does not
// exist). An ECB rate of the same day stays.
func (s *Store) DeleteManualFXRate(ctx context.Context, currency string, date time.Time) error {
	res, err := s.db.ExecContext(ctx, "DELETE FROM fx_rates WHERE currency = ? AND date = ? AND source = 'manuell'",
		strings.ToUpper(currency), formatDate(date))
	return checkAffected(res, err)
}

// ListManualFXRates returns all manual rates (by currency, then newest first).
func (s *Store) ListManualFXRates(ctx context.Context) ([]domain.FXRate, error) {
	return s.queryFXRates(ctx, "SELECT currency, date, rate, source FROM fx_rates WHERE source = 'manuell' ORDER BY currency, date DESC")
}

// LatestECBRates returns the ECB rates of the most recent cached day (sorted
// by currency); empty if nothing is cached yet.
func (s *Store) LatestECBRates(ctx context.Context) ([]domain.FXRate, error) {
	return s.queryFXRates(ctx, `SELECT currency, date, rate, source FROM fx_rates
		WHERE source = 'ezb' AND date = (SELECT max(date) FROM fx_rates WHERE source = 'ezb') ORDER BY currency`)
}

// FXCacheStats describes the contents of the ECB cache.
type FXCacheStats struct {
	Count      int       // number of ECB rates
	Currencies int       // number of currencies
	From, To   time.Time // oldest/newest day; zero values for an empty cache
}

// ECBCacheStats returns statistics about the ECB cache.
func (s *Store) ECBCacheStats(ctx context.Context) (FXCacheStats, error) {
	var st FXCacheStats
	var from, to sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT count(*), count(DISTINCT currency), min(date), max(date)
		FROM fx_rates WHERE source = 'ezb'`).Scan(&st.Count, &st.Currencies, &from, &to)
	if err != nil {
		return st, err
	}
	if from.Valid {
		st.From, _ = parseDate(from.String)
	}
	if to.Valid {
		st.To, _ = parseDate(to.String)
	}
	return st, nil
}

// ListFXCurrencies returns all currencies for which any rate exists.
func (s *Store) ListFXCurrencies(ctx context.Context) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT DISTINCT currency FROM fx_rates ORDER BY currency")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// HasECBCurrency reports whether the cache has any ECB rate for currency.
func (s *Store) HasECBCurrency(ctx context.Context, currency string) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx,
		"SELECT count(*) FROM (SELECT 1 FROM fx_rates WHERE currency = ? AND source = 'ezb' LIMIT 1)", currency).Scan(&n)
	return n > 0, err
}

// UsedFXRate is a rate used in an expense.
type UsedFXRate struct {
	domain.FXRate        // Date = expense date, Source = the expense's fx_source
	ExpenseID     int64  //
	Title         string // expense title
}

// RecentUsedFXRates returns the rates of the most recent (non-deleted)
// foreign-currency expenses, newest first.
func (s *Store) RecentUsedFXRates(ctx context.Context, limit int) ([]UsedFXRate, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, title, original_currency, date, fx_rate, fx_source FROM expenses
		WHERE deleted_at IS NULL AND original_currency <> 'EUR' ORDER BY date DESC, id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []UsedFXRate
	for rows.Next() {
		var u UsedFXRate
		var d string
		if err := rows.Scan(&u.ExpenseID, &u.Title, &u.Currency, &d, &u.Rate, &u.Source); err != nil {
			return nil, err
		}
		if u.Date, err = parseDate(d); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (s *Store) queryFXRates(ctx context.Context, q string, args ...any) ([]domain.FXRate, error) {
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []domain.FXRate
	for rows.Next() {
		var r domain.FXRate
		var d string
		if err := rows.Scan(&r.Currency, &d, &r.Rate, &r.Source); err != nil {
			return nil, err
		}
		if r.Date, err = parseDate(d); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
