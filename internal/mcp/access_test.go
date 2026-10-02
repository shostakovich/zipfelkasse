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
		want   string // "" = ungültig
	}{
		{"direkt", "1.2.3.4:5000", nil, "", "1.2.3.4"},
		{"direkt IPv6", "[2001:db8::1]:5000", nil, "", "2001:db8::1"},
		{"direkt ohne Port", "1.2.3.4", nil, "", "1.2.3.4"},
		{"XFF-Spoofing ohne Proxy ignoriert", "1.2.3.4:5000", []string{"160.79.104.1"}, "", "1.2.3.4"},
		{"X-Real-IP-Spoofing ohne Proxy ignoriert", "1.2.3.4:5000", nil, "160.79.104.1", "1.2.3.4"},
		{"Proxy mit XFF", "10.0.0.2:5000", []string{"160.79.104.1"}, "", "160.79.104.1"},
		{"Proxy: vom Client vorangestellte Adresse zählt nicht", "10.0.0.2:5000", []string{"160.79.104.1, 6.6.6.6"}, "", "6.6.6.6"},
		{"Proxy-Kette", "10.0.0.2:5000", []string{"6.6.6.6, 160.79.104.1, 172.16.0.5"}, "", "160.79.104.1"},
		{"mehrere XFF-Header", "10.0.0.2:5000", []string{"6.6.6.6", "160.79.104.1"}, "", "160.79.104.1"},
		{"XFF mit Port", "10.0.0.2:5000", []string{"160.79.104.1:443"}, "", "160.79.104.1"},
		{"XFF IPv6 in Klammern", "10.0.0.2:5000", []string{"[2001:db8::7]:443"}, "", "2001:db8::7"},
		{"XFF unlesbar → ungültig", "10.0.0.2:5000", []string{"kaputt"}, "", ""},
		{"XFF teils unlesbar → ungültig", "10.0.0.2:5000", []string{"160.79.104.1, kaputt"}, "", ""},
		{"XFF schlägt X-Real-IP", "10.0.0.2:5000", []string{"6.6.6.6"}, "160.79.104.1", "6.6.6.6"},
		{"nur X-Real-IP", "10.0.0.2:5000", nil, "160.79.104.9", "160.79.104.9"},
		{"X-Real-IP unlesbar", "10.0.0.2:5000", nil, "kaputt", ""},
		{"Proxy ohne Header", "10.0.0.2:5000", nil, "", "10.0.0.2"},
		{"nur vertrauenswürdige Hops", "10.0.0.2:5000", []string{"10.0.0.3, 10.0.0.4"}, "", "10.0.0.3"},
		{"IPv4-mapped Proxy", "[::ffff:10.0.0.2]:5000", []string{"::ffff:160.79.104.1"}, "", "160.79.104.1"},
		{"RemoteAddr unlesbar", "@", nil, "", ""},
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
		{"salden", "salden", true},
		{"=?base64?SGVsbG8sIOS4lueVjA==?=", "Hello, 世界", true},
		{"=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=", "=?base64?literal?=", true},
		{"=?base64?SGVsbG8?=", "Hello", true}, // ohne Padding
		{"=?base64?!!!?=", "", false},
		{"=?base64?=", "=?base64?=", true}, // zu kurz für das Format
	}
	for _, tt := range tests {
		got, ok := decodeHeaderValue(tt.in)
		if got != tt.want || ok != tt.ok {
			t.Errorf("decodeHeaderValue(%q) = %q, %v; want %q, %v", tt.in, got, ok, tt.want, tt.ok)
		}
	}
}
