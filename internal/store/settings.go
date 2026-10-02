package store

import (
	"context"
	"database/sql"
	"errors"
)

// Known keys in the settings table. Feature packages may use their own
// prefixed keys (e.g. "fx.").
const (
	SettingGroupName       = "group_name"
	SettingDefaultCurrency = "default_currency"
)

// GetSetting returns the value for key, or ErrNotFound.
func (s *Store) GetSetting(ctx context.Context, key string) (string, error) {
	var v string
	err := s.db.QueryRowContext(ctx, "SELECT value FROM settings WHERE key = ?", key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return v, err
}

// SetSetting sets key to value (creating the key if needed).
func (s *Store) SetSetting(ctx context.Context, key, value string) error {
	_, err := s.db.ExecContext(ctx,
		"INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
		key, value)
	return err
}

// GroupName returns the group name (fallback "Zipfelkasse").
func (s *Store) GroupName(ctx context.Context) string {
	v, err := s.GetSetting(ctx, SettingGroupName)
	if err != nil || v == "" {
		return "Zipfelkasse"
	}
	return v
}
