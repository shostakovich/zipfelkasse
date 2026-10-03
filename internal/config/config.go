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

	// Test-only overrides for the black-box E2E suite (e2e/). Never set them
	// in production.
	Now         func() time.Time // ZIPFELKASSE_TEST_NOW (RFC 3339): frozen clock; nil = time.Now
	ECBBaseURL  string           // ZIPFELKASSE_TEST_ECB_URL: replaces https://www.ecb.europa.eu/stats/eurofxref/
	YNABBaseURL string           // ZIPFELKASSE_TEST_YNAB_URL: replaces https://api.ynab.com/v1
	YNABDelay   time.Duration    // ZIPFELKASSE_TEST_YNAB_DELAY: start delay and debounce of the YNAB sync
}

// Clock returns the clock to use: the frozen test clock or time.Now.
func (c Config) Clock() func() time.Time {
	if c.Now != nil {
		return c.Now
	}
	return time.Now
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
	if err := c.testOverrides(getenv); err != nil {
		return c, err
	}
	return c, nil
}

// testOverrides reads the ZIPFELKASSE_TEST_* variables of the E2E suite.
func (c *Config) testOverrides(getenv func(string) string) error {
	if v := strings.TrimSpace(getenv("ZIPFELKASSE_TEST_NOW")); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			return fmt.Errorf("ZIPFELKASSE_TEST_NOW: %w", err)
		}
		c.Now = func() time.Time { return t }
	}
	c.ECBBaseURL = strings.TrimSpace(getenv("ZIPFELKASSE_TEST_ECB_URL"))
	c.YNABBaseURL = strings.TrimSpace(getenv("ZIPFELKASSE_TEST_YNAB_URL"))
	if v := strings.TrimSpace(getenv("ZIPFELKASSE_TEST_YNAB_DELAY")); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return fmt.Errorf("ZIPFELKASSE_TEST_YNAB_DELAY: %w", err)
		}
		c.YNABDelay = d
	}
	return nil
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
