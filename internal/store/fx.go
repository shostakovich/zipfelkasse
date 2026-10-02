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

// Wechselkurse liegen in fx_rates im EZB-Format (Fremdwährung pro 1 EUR).
// Pro (Währung, Datum) gibt es höchstens einen Eintrag: Ein manueller Kurs
// ersetzt einen EZB-Kurs desselben Tages, EZB-Kurse überschreiben nie einen
// manuellen Kurs.

// ValidCurrencyCode meldet, ob s ein dreistelliger Großbuchstaben-Code ist.
func ValidCurrencyCode(s string) bool {
	if len(s) != 3 {
		return false
	}
	for _, c := range s {
		if c < 'A' || c > 'Z' {
			return false
		}
	}
	return true
}

// LookupFXRate liefert den jüngsten Kurs der Quelle source (domain.FXSourceECB
// oder domain.FXSourceManual) für currency mit notBefore ≤ Datum ≤ date.
// notBefore Nullwert = ohne Untergrenze. Ohne Treffer: ErrNotFound.
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

// SaveECBRates speichert EZB-Kurse (Source wird auf "ezb" gesetzt). Vorhandene
// EZB-Kurse werden aktualisiert, manuelle Kurse bleiben unangetastet.
func (s *Store) SaveECBRates(ctx context.Context, rates []domain.FXRate) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		stmt, err := tx.PrepareContext(ctx, `INSERT INTO fx_rates (date, currency, rate, source) VALUES (?, ?, ?, 'ezb')
			ON CONFLICT (currency, date) DO UPDATE SET rate = excluded.rate WHERE fx_rates.source = 'ezb'`)
		if err != nil {
			return err
		}
		defer stmt.Close()
		for _, r := range rates {
			if !(r.Rate > 0) || math.IsInf(r.Rate, 0) || !ValidCurrencyCode(r.Currency) {
				continue
			}
			if _, err := stmt.ExecContext(ctx, formatDate(r.Date), r.Currency, r.Rate); err != nil {
				return err
			}
		}
		return nil
	})
}

// SetManualFXRate speichert einen von Hand eingetragenen Kurs, gültig ab date
// (ersetzt einen vorhandenen Kurs desselben Tages).
func (s *Store) SetManualFXRate(ctx context.Context, currency string, date time.Time, rate float64) error {
	currency = strings.ToUpper(strings.TrimSpace(currency))
	switch {
	case currency == "EUR":
		return invalid("Für Euro braucht es keinen Kurs.")
	case !ValidCurrencyCode(currency):
		return invalid("Bitte einen dreistelligen Währungscode angeben (z. B. USD).")
	case date.IsZero():
		return invalid("Bitte ein Datum angeben.")
	case !(rate > 0) || math.IsInf(rate, 0) || rate > 1e9:
		return invalid("Der Kurs muss größer als 0 sein.")
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO fx_rates (date, currency, rate, source) VALUES (?, ?, ?, 'manuell')
		ON CONFLICT (currency, date) DO UPDATE SET rate = excluded.rate, source = 'manuell'`,
		formatDate(domain.DateOf(date)), currency, rate)
	return err
}

// DeleteManualFXRate löscht einen manuellen Kurs (ErrNotFound, wenn es ihn
// nicht gibt).
func (s *Store) DeleteManualFXRate(ctx context.Context, currency string, date time.Time) error {
	res, err := s.db.ExecContext(ctx, "DELETE FROM fx_rates WHERE currency = ? AND date = ? AND source = 'manuell'",
		strings.ToUpper(currency), formatDate(date))
	return checkAffected(res, err)
}

// ListManualFXRates liefert alle manuellen Kurse (Währung, dann neueste zuerst).
func (s *Store) ListManualFXRates(ctx context.Context) ([]domain.FXRate, error) {
	return s.queryFXRates(ctx, "SELECT currency, date, rate, source FROM fx_rates WHERE source = 'manuell' ORDER BY currency, date DESC")
}

// LatestECBRates liefert die EZB-Kurse des jüngsten zwischengespeicherten
// Tages (nach Währung sortiert); leer, wenn noch nichts im Cache ist.
func (s *Store) LatestECBRates(ctx context.Context) ([]domain.FXRate, error) {
	return s.queryFXRates(ctx, `SELECT currency, date, rate, source FROM fx_rates
		WHERE source = 'ezb' AND date = (SELECT max(date) FROM fx_rates WHERE source = 'ezb') ORDER BY currency`)
}

// FXCacheStats beschreibt den Inhalt des EZB-Caches.
type FXCacheStats struct {
	Count      int       // Anzahl EZB-Kurse
	Currencies int       // Anzahl Währungen
	From, To   time.Time // ältester/jüngster Tag; Nullwerte bei leerem Cache
}

// ECBCacheStats liefert Kennzahlen zum EZB-Cache.
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

// ListFXCurrencies liefert alle Währungen, für die es irgendeinen Kurs gibt.
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

// HasECBCurrency meldet, ob der Cache irgendeinen EZB-Kurs für currency hat.
func (s *Store) HasECBCurrency(ctx context.Context, currency string) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx,
		"SELECT count(*) FROM (SELECT 1 FROM fx_rates WHERE currency = ? AND source = 'ezb' LIMIT 1)", currency).Scan(&n)
	return n > 0, err
}

// UsedFXRate ist ein in einer Ausgabe verwendeter Kurs.
type UsedFXRate struct {
	domain.FXRate        // Date = Ausgabedatum, Source = fx_source der Ausgabe
	ExpenseID     int64  //
	Title         string // Titel der Ausgabe
}

// RecentUsedFXRates liefert die Kurse der jüngsten (nicht gelöschten)
// Fremdwährungs-Ausgaben, neueste zuerst.
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
