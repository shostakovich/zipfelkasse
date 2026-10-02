package store

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

const backupPrefix, backupSuffix = "teilen-", ".db"

// Backup schreibt per VACUUM INTO eine konsistente Kopie der Datenbank nach
// dir/teilen-YYYYMMDD-HHMMSS.db und löscht danach alle bis auf die neuesten
// keep Backups in dir. Liefert den Pfad der neuen Datei.
func (s *Store) Backup(ctx context.Context, dir string, keep int) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("backup-verzeichnis anlegen: %w", err)
	}
	name := backupPrefix + s.now().UTC().Format("20060102-150405") + backupSuffix
	path := filepath.Join(dir, name)
	if _, err := os.Stat(path); err == nil {
		return "", fmt.Errorf("backup %s existiert bereits", path)
	}
	if _, err := s.db.ExecContext(ctx, "VACUUM INTO ?", path); err != nil {
		return "", fmt.Errorf("vacuum into: %w", err)
	}
	return path, RotateBackups(dir, keep)
}

// RotateBackups löscht in dir alle Backup-Dateien bis auf die neuesten keep.
func RotateBackups(dir string, keep int) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	var names []string
	for _, e := range entries {
		n := e.Name()
		if e.Type().IsRegular() && strings.HasPrefix(n, backupPrefix) && strings.HasSuffix(n, backupSuffix) {
			names = append(names, n)
		}
	}
	// Der Zeitstempel im Namen sortiert lexikografisch richtig.
	slices.Sort(names)
	for len(names) > max(keep, 0) {
		if err := os.Remove(filepath.Join(dir, names[0])); err != nil {
			return err
		}
		names = names[1:]
	}
	return nil
}
