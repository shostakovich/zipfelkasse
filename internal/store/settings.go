package store

import (
	"context"
	"database/sql"
	"errors"
)

// Bekannte Schlüssel in der Tabelle settings. Feature-Pakete dürfen eigene
// Schlüssel mit Präfix verwenden (z. B. "ynab.").
const (
	SettingGroupName       = "group_name"
	SettingDefaultCurrency = "default_currency"
)

// GetSetting liefert den Wert zu key oder ErrNotFound.
func (s *Store) GetSetting(ctx context.Context, key string) (string, error) {
	var v string
	err := s.db.QueryRowContext(ctx, "SELECT value FROM settings WHERE key = ?", key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return v, err
}

// SetSetting setzt key auf value (legt den Schlüssel bei Bedarf an).
func (s *Store) SetSetting(ctx context.Context, key, value string) error {
	_, err := s.db.ExecContext(ctx,
		"INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
		key, value)
	return err
}

// GroupName liefert den Gruppennamen (Fallback „teilen“).
func (s *Store) GroupName(ctx context.Context) string {
	v, err := s.GetSetting(ctx, SettingGroupName)
	if err != nil || v == "" {
		return "teilen"
	}
	return v
}
