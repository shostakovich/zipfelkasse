// Package config reads the configuration from environment variables.
package config

import (
	"fmt"
	"net/netip"
	"path/filepath"
	"strings"
	"time"
)

// Config is the complete runtime configuration.
type Config struct {
	Addr            string         // ZIPFELKASSE_ADDR, default ":8080"
	DBPath          string         // ZIPFELKASSE_DB, default "./data/zipfelkasse.db" (container: /data/zipfelkasse.db)
	BackupDir       string         // ZIPFELKASSE_BACKUP_DIR, default <directory of the DB>/backups
	MCPSecret       string         // MCP_SECRET; empty = MCP disabled
	MCPAllowedCIDRs []netip.Prefix // MCP_ALLOWED_CIDRS, default 160.79.104.0/21
	TrustedProxies  []netip.Prefix // TRUSTED_PROXIES (IPs or CIDRs), default empty
	Location        *time.Location // from TZ (Go reads TZ itself), default UTC
}

// DefaultMCPAllowedCIDRs is Anthropic's address range.
const DefaultMCPAllowedCIDRs = "160.79.104.0/21"

// FromEnv builds the configuration from getenv (e.g. os.Getenv).
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

// ParsePrefixes parses a comma- or whitespace-separated list of CIDRs or
// single IP addresses (which become /32 or /128 respectively).
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

// ContainsAddr reports whether a lies in one of the prefixes (IPv4-mapped IPv6 is unmapped).
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
