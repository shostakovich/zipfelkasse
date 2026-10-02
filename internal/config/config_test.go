package config

import (
	"net/netip"
	"testing"
)

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestFromEnvDefaults(t *testing.T) {
	c, err := FromEnv(env(nil))
	if err != nil {
		t.Fatal(err)
	}
	if c.Addr != ":8080" || c.DBPath != "./data/teilen.db" || c.BackupDir != "data/backups" || c.MCPSecret != "" {
		t.Errorf("Defaults = %+v", c)
	}
	if len(c.MCPAllowedCIDRs) != 1 || c.MCPAllowedCIDRs[0].String() != "160.79.104.0/21" || len(c.TrustedProxies) != 0 {
		t.Errorf("CIDRs = %v / %v", c.MCPAllowedCIDRs, c.TrustedProxies)
	}
}

func TestFromEnv(t *testing.T) {
	c, err := FromEnv(env(map[string]string{
		"TEILEN_ADDR":       "127.0.0.1:9000",
		"TEILEN_DB":         "/data/teilen.db",
		"MCP_SECRET":        " geheim ",
		"MCP_ALLOWED_CIDRS": "10.0.0.0/8, 192.168.1.5",
		"TRUSTED_PROXIES":   "172.18.0.2 fd00::/8",
		"TZ":                "Europe/Berlin",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if c.BackupDir != "/data/backups" || c.MCPSecret != "geheim" || c.Location.String() != "Europe/Berlin" {
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
		{"MCP_ALLOWED_CIDRS": "kein-cidr"},
		{"TRUSTED_PROXIES": "1.2.3.4/99"},
		{"TZ": "Mars/Olympus"},
	} {
		if _, err := FromEnv(env(m)); err == nil {
			t.Errorf("FromEnv(%v) ohne Fehler", m)
		}
	}
}
