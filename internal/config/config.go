// Package config liest die Konfiguration aus Umgebungsvariablen.
package config

import (
	"fmt"
	"net/netip"
	"path/filepath"
	"strings"
	"time"
)

// Config ist die gesamte Laufzeitkonfiguration.
type Config struct {
	Addr            string         // ZIPFELKASSE_ADDR, Standard ":8080"
	DBPath          string         // ZIPFELKASSE_DB, Standard "./data/zipfelkasse.db" (Container: /data/zipfelkasse.db)
	BackupDir       string         // ZIPFELKASSE_BACKUP_DIR, Standard <Verzeichnis der DB>/backups
	MCPSecret       string         // MCP_SECRET; leer = MCP abgeschaltet
	MCPAllowedCIDRs []netip.Prefix // MCP_ALLOWED_CIDRS, Standard 160.79.104.0/21
	TrustedProxies  []netip.Prefix // TRUSTED_PROXIES (IPs oder CIDRs), Standard leer
	Location        *time.Location // aus TZ (Go liest TZ selbst), Standard UTC
}

// DefaultMCPAllowedCIDRs ist der Adressbereich von Anthropic.
const DefaultMCPAllowedCIDRs = "160.79.104.0/21"

// FromEnv baut die Konfiguration aus getenv (z. B. os.Getenv).
func FromEnv(getenv func(string) string) (Config, error) {
	c := Config{
		Addr:      or(getenv("ZIPFELKASSE_ADDR"), ":8080"),
		DBPath:    or(getenv("ZIPFELKASSE_DB"), "./data/zipfelkasse.db"),
		MCPSecret: strings.TrimSpace(getenv("MCP_SECRET")),
		Location:  time.Local,
	}
	c.BackupDir = or(getenv("ZIPFELKASSE_BACKUP_DIR"), filepath.Join(filepath.Dir(c.DBPath), "backups"))
	var err error
	if c.MCPAllowedCIDRs, err = ParsePrefixes(or(getenv("MCP_ALLOWED_CIDRS"), DefaultMCPAllowedCIDRs)); err != nil {
		return c, fmt.Errorf("MCP_ALLOWED_CIDRS: %w", err)
	}
	if c.TrustedProxies, err = ParsePrefixes(getenv("TRUSTED_PROXIES")); err != nil {
		return c, fmt.Errorf("TRUSTED_PROXIES: %w", err)
	}
	if tz := getenv("TZ"); tz != "" {
		if c.Location, err = time.LoadLocation(tz); err != nil {
			return c, fmt.Errorf("TZ: %w", err)
		}
	}
	return c, nil
}

// ParsePrefixes liest eine durch Komma oder Leerzeichen getrennte Liste von
// CIDRs oder einzelnen IP-Adressen (diese werden zu /32 bzw. /128).
func ParsePrefixes(s string) ([]netip.Prefix, error) {
	var out []netip.Prefix
	for _, f := range strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' || r == '\n' }) {
		if strings.Contains(f, "/") {
			p, err := netip.ParsePrefix(f)
			if err != nil {
				return nil, err
			}
			out = append(out, p.Masked())
			continue
		}
		a, err := netip.ParseAddr(f)
		if err != nil {
			return nil, err
		}
		out = append(out, netip.PrefixFrom(a.Unmap(), a.Unmap().BitLen()))
	}
	return out, nil
}

// ContainsAddr meldet, ob a in einem der Präfixe liegt (IPv4-mapped IPv6 wird entpackt).
func ContainsAddr(prefixes []netip.Prefix, a netip.Addr) bool {
	a = a.Unmap()
	for _, p := range prefixes {
		if p.Contains(a) {
			return true
		}
	}
	return false
}

func or(v, fallback string) string {
	if v = strings.TrimSpace(v); v != "" {
		return v
	}
	return fallback
}
