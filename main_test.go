package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/config"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

// TestAppWiring builds the complete app like serve() and checks that all
// Register calls succeed without pattern conflicts and the routes respond.
func TestAppWiring(t *testing.T) {
	cfg, err := config.FromEnv(func(k string) string {
		return map[string]string{"MCP_SECRET": "geheim"}[k]
	})
	if err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	a, err := newApp(cfg, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	anna, _ := st.CreateParticipant(context.Background(), "Anna")
	who := &http.Cookie{Name: web.IdentityCookie, Value: strconv.FormatInt(anna, 10)}

	tests := []struct {
		method, path string
		cookie       bool
		want         int
	}{
		{"GET", "/healthz", false, 200},
		{"GET", "/wer", false, 200},
		{"GET", "/", false, http.StatusSeeOther},
		{"GET", "/", true, 200},
		{"GET", "/salden", true, 200},
		{"GET", "/aktivitaet", true, 200},
		{"GET", "/einstellungen", true, 200},
		{"GET", "/einstellungen/wiederkehrend", true, 200},
		{"GET", "/einstellungen/kurse", true, 200},
		{"GET", "/einstellungen/ynab", true, 200},
		{"GET", "/export", true, 200},
		{"GET", "/api/kurs?waehrung=EUR", true, 200},
		{"GET", "/api/kurs?waehrung=", true, http.StatusBadRequest}, // no network; USD would query the ECB
		{"GET", "/einstellungen/wiederkehrend/neu", true, 200},
		{"POST", "/mcp/falsch", false, http.StatusNotFound},  // wrong secret reveals nothing
		{"POST", "/mcp/geheim", false, http.StatusForbidden}, // test IP 192.0.2.1 not allowed
		{"GET", "/gibtsnicht", true, 404},
	}
	for _, tt := range tests {
		req := httptest.NewRequest(tt.method, tt.path, nil)
		if tt.cookie {
			req.AddCookie(who)
		}
		rec := httptest.NewRecorder()
		a.handler.ServeHTTP(rec, req)
		if rec.Code != tt.want {
			t.Errorf("%s %s: %d, want %d", tt.method, tt.path, rec.Code, tt.want)
		}
	}
}

// TestMCPThroughWrap: the CSRF protection in web.Wrap lets MCP clients (POST
// without browser headers) through.
func TestMCPThroughWrap(t *testing.T) {
	cfg, err := config.FromEnv(func(k string) string {
		return map[string]string{"MCP_SECRET": "geheim", "MCP_ALLOWED_CIDRS": "192.0.2.0/24"}[k]
	})
	if err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	a, err := newApp(cfg, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	body := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}`
	req := httptest.NewRequest("POST", "/mcp/geheim", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	rec := httptest.NewRecorder()
	a.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"serverInfo"`) {
		t.Errorf("MCP initialize: %d %s", rec.Code, rec.Body.String())
	}
}

func TestNextBackup(t *testing.T) {
	loc, _ := time.LoadLocation("Europe/Berlin")
	tests := []struct{ now, want string }{
		{"2026-10-02 01:00", "2026-10-02 03:00"},
		{"2026-10-02 03:00", "2026-10-03 03:00"},
		{"2026-10-02 23:59", "2026-10-03 03:00"},
	}
	for _, tt := range tests {
		now, _ := time.ParseInLocation("2006-01-02 15:04", tt.now, loc)
		if got := nextBackup(now).Format("2006-01-02 15:04"); got != tt.want {
			t.Errorf("nextBackup(%s) = %s, want %s", tt.now, got, tt.want)
		}
	}
}

func TestHealthURL(t *testing.T) {
	tests := map[string]string{
		"":               "http://127.0.0.1:8080/healthz",
		":8080":          "http://127.0.0.1:8080/healthz",
		"0.0.0.0:9000":   "http://127.0.0.1:9000/healthz",
		"[::]:9000":      "http://127.0.0.1:9000/healthz",
		"127.0.0.1:8081": "http://127.0.0.1:8081/healthz",
	}
	for in, want := range tests {
		if got, err := healthURL(in); err != nil || got != want {
			t.Errorf("healthURL(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if _, err := healthURL("broken"); err == nil {
		t.Error("healthURL(broken) returned no error")
	}
}
