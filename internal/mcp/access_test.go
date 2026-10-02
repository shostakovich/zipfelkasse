package mcp

import (
	"net/http/httptest"
	"net/netip"
	"testing"

	"github.com/shostakovich/zipfelkasse/internal/config"
)

func TestClientIP(t *testing.T) {
	trusted, err := config.ParsePrefixes("10.0.0.0/8, 172.16.0.5")
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name   string
		remote string
		xff    []string
		real   string
		want   string // "" = invalid
	}{
		{"direct", "1.2.3.4:5000", nil, "", "1.2.3.4"},
		{"direct IPv6", "[2001:db8::1]:5000", nil, "", "2001:db8::1"},
		{"direct without port", "1.2.3.4", nil, "", "1.2.3.4"},
		{"XFF spoofing without proxy ignored", "1.2.3.4:5000", []string{"160.79.104.1"}, "", "1.2.3.4"},
		{"X-Real-IP spoofing without proxy ignored", "1.2.3.4:5000", nil, "160.79.104.1", "1.2.3.4"},
		{"proxy with XFF", "10.0.0.2:5000", []string{"160.79.104.1"}, "", "160.79.104.1"},
		{"proxy: address prepended by the client does not count", "10.0.0.2:5000", []string{"160.79.104.1, 6.6.6.6"}, "", "6.6.6.6"},
		{"proxy chain", "10.0.0.2:5000", []string{"6.6.6.6, 160.79.104.1, 172.16.0.5"}, "", "160.79.104.1"},
		{"multiple XFF headers", "10.0.0.2:5000", []string{"6.6.6.6", "160.79.104.1"}, "", "160.79.104.1"},
		{"XFF with port", "10.0.0.2:5000", []string{"160.79.104.1:443"}, "", "160.79.104.1"},
		{"XFF IPv6 in brackets", "10.0.0.2:5000", []string{"[2001:db8::7]:443"}, "", "2001:db8::7"},
		{"XFF unparsable → invalid", "10.0.0.2:5000", []string{"garbage"}, "", ""},
		{"XFF partly unparsable → invalid", "10.0.0.2:5000", []string{"160.79.104.1, garbage"}, "", ""},
		{"XFF beats X-Real-IP", "10.0.0.2:5000", []string{"6.6.6.6"}, "160.79.104.1", "6.6.6.6"},
		{"only X-Real-IP", "10.0.0.2:5000", nil, "160.79.104.9", "160.79.104.9"},
		{"X-Real-IP unparsable", "10.0.0.2:5000", nil, "garbage", ""},
		{"proxy without header", "10.0.0.2:5000", nil, "", "10.0.0.2"},
		{"only trusted hops", "10.0.0.2:5000", []string{"10.0.0.3, 10.0.0.4"}, "", "10.0.0.3"},
		{"IPv4-mapped proxy", "[::ffff:10.0.0.2]:5000", []string{"::ffff:160.79.104.1"}, "", "160.79.104.1"},
		{"RemoteAddr unparsable", "@", nil, "", ""},
	}
	for _, tt := range tests {
		r := httptest.NewRequest("POST", "/mcp/x", nil)
		r.RemoteAddr = tt.remote
		for _, v := range tt.xff {
			r.Header.Add("X-Forwarded-For", v)
		}
		if tt.real != "" {
			r.Header.Set("X-Real-IP", tt.real)
		}
		got := clientIP(r, trusted)
		want := netip.Addr{}
		if tt.want != "" {
			want = netip.MustParseAddr(tt.want)
		}
		if got != want {
			t.Errorf("%s: clientIP = %v, want %v", tt.name, got, want)
		}
	}
}

func TestDecodeHeaderValue(t *testing.T) {
	tests := []struct {
		in, want string
		ok       bool
	}{
		{"balances", "balances", true},
		{"=?base64?SGVsbG8sIOS4lueVjA==?=", "Hello, 世界", true},
		{"=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=", "=?base64?literal?=", true},
		{"=?base64?SGVsbG8?=", "Hello", true}, // without padding
		{"=?base64?!!!?=", "", false},
		{"=?base64?=", "=?base64?=", true}, // too short for the format
	}
	for _, tt := range tests {
		got, ok := decodeHeaderValue(tt.in)
		if got != tt.want || ok != tt.ok {
			t.Errorf("decodeHeaderValue(%q) = %q, %v; want %q, %v", tt.in, got, ok, tt.want, tt.ok)
		}
	}
}
