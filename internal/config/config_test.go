package config

import (
	"net/netip"
	"testing"
	"time"
)

func TestFromEnvTestOverrides(t *testing.T) {
	c, err := FromEnv(env(map[string]string{
		"ZIPFELKASSE_TEST_NOW":        "2026-10-03T10:00:00Z",
		"ZIPFELKASSE_TEST_ECB_URL":    "http://127.0.0.1:9/ecb/",
		"ZIPFELKASSE_TEST_YNAB_URL":   "http://127.0.0.1:9/v1",
		"ZIPFELKASSE_TEST_YNAB_DELAY": "200ms",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if got := c.Clock()(); !got.Equal(time.Date(2026, 10, 3, 10, 0, 0, 0, time.UTC)) {
		t.Errorf("Clock() = %v", got)
	}
	if c.ECBBaseURL != "http://127.0.0.1:9/ecb/" || c.YNABBaseURL != "http://127.0.0.1:9/v1" || c.YNABDelay != 200*time.Millisecond {
		t.Errorf("Config = %+v", c)
	}
	if c, _ := FromEnv(env(nil)); c.Now != nil || c.Clock() == nil {
		t.Errorf("default clock not time.Now")
	}
	for _, m := range []map[string]string{
		{"ZIPFELKASSE_TEST_NOW": "gestern"},
		{"ZIPFELKASSE_TEST_YNAB_DELAY": "kurz"},
	} {
		if _, err := FromEnv(env(m)); err == nil {
			t.Errorf("FromEnv(%v) returned no error", m)
		}
	}
}

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestFromEnvDefaults(t *testing.T) {
	c, err := FromEnv(env(nil))
	if err != nil {
		t.Fatal(err)
	}
	if c.Addr != ":8080" || c.DBPath != "./data/zipfelkasse.db" || c.BackupDir != "data/backups" || c.MCPSecret != "" {
		t.Errorf("Defaults = %+v", c)
	}
	if len(c.MCPAllowedCIDRs) != 1 || c.MCPAllowedCIDRs[0].String() != "160.79.104.0/21" || len(c.TrustedProxies) != 0 {
		t.Errorf("CIDRs = %v / %v", c.MCPAllowedCIDRs, c.TrustedProxies)
	}
}

func TestFromEnv(t *testing.T) {
	c, err := FromEnv(env(map[string]string{
		"ZIPFELKASSE_ADDR":  "127.0.0.1:9000",
		"ZIPFELKASSE_DB":    "/data/zipfelkasse.db",
		"MCP_SECRET":        " secret ",
		"MCP_ALLOWED_CIDRS": "10.0.0.0/8, 192.168.1.5",
		"TRUSTED_PROXIES":   "172.18.0.2 fd00::/8",
		"TZ":                "Europe/Berlin",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if c.BackupDir != "/data/backups" || c.MCPSecret != "secret" || c.Location.String() != "Europe/Berlin" {
		t.Errorf("Config = %+v", c)
	}
	if !ContainsAddr(c.MCPAllowedCIDRs, netip.MustParseAddr("10.1.2.3")) ||
		!ContainsAddr(c.MCPAllowedCIDRs, netip.MustParseAddr("::ffff:192.168.1.5")) ||
		ContainsAddr(c.MCPAllowedCIDRs, netip.MustParseAddr("192.168.1.6")) {
		t.Errorf("MCPAllowedCIDRs = %v", c.MCPAllowedCIDRs)
	}
	if !ContainsAddr(c.TrustedProxies, netip.MustParseAddr("172.18.0.2")) || !ContainsAddr(c.TrustedProxies, netip.MustParseAddr("fd00::1")) {
		t.Errorf("TrustedProxies = %v", c.TrustedProxies)
	}
}

func TestFromEnvErrors(t *testing.T) {
	for _, m := range []map[string]string{
		{"MCP_ALLOWED_CIDRS": "not-a-cidr"},
		{"TRUSTED_PROXIES": "1.2.3.4/99"},
		{"TZ": "Mars/Olympus"},
	} {
		if _, err := FromEnv(env(m)); err == nil {
			t.Errorf("FromEnv(%v) returned no error", m)
		}
	}
}
