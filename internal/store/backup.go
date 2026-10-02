package store

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

const backupPrefix, backupSuffix = "zipfelkasse-", ".db"

// Backup writes a consistent copy of the database to
// dir/zipfelkasse-YYYYMMDD-HHMMSS.db via VACUUM INTO and then deletes all but
// the newest keep backups in dir. Returns the path of the new file.
func (s *Store) Backup(ctx context.Context, dir string, keep int) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create backup directory: %w", err)
	}
	name := backupPrefix + s.now().UTC().Format("20060102-150405") + backupSuffix
	path := filepath.Join(dir, name)
	if _, err := os.Stat(path); err == nil {
		return "", fmt.Errorf("backup %s already exists", path)
	}
	if _, err := s.db.ExecContext(ctx, "VACUUM INTO ?", path); err != nil {
		return "", fmt.Errorf("vacuum into: %w", err)
	}
	return path, RotateBackups(dir, keep)
}

// RotateBackups deletes all backup files in dir except the newest keep.
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
	// The timestamp in the name sorts correctly lexicographically.
	slices.Sort(names)
	for len(names) > max(keep, 0) {
		if err := os.Remove(filepath.Join(dir, names[0])); err != nil {
			return err
		}
		names = names[1:]
	}
	return nil
}
