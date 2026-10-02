// Package mcp ist ein schreibgeschützter MCP-Server (JSON-RPC 2.0 über
// Streamable HTTP, Antworten nur als JSON) unter /mcp/{MCP_SECRET}.
//
// Zugang (siehe docs/MCP.md): falsches Secret → 404, Client-IP nicht in
// MCP_ALLOWED_CIDRS → 403 (hinter TRUSTED_PROXIES zählt X-Forwarded-For),
// Origin-Header gesetzt → 403. Ohne MCP_SECRET ist MCP abgeschaltet.
//
// Protokoll: „Dual-Era“. Moderne Clients (2026-07-28, zustandslos, _meta in
// jeder Anfrage, Pflicht-Header) und ältere Clients mit initialize-Handshake
// (2025-11-25, 2025-06-18, 2025-03-26) werden auf demselben Endpunkt bedient.
// Es gibt keine Sessions und keine SSE-Streams.
package mcp

import (
	"crypto/subtle"
	"log/slog"
	"net/http"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/config"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

// Register hängt /mcp/{secret} an. Ohne MCP_SECRET bleibt MCP abgeschaltet.
func Register(mux *http.ServeMux, d web.Deps) error {
	if d.Config.MCPSecret == "" {
		d.Log.Info("MCP abgeschaltet (MCP_SECRET ist leer)")
		return nil
	}
	mux.Handle("/mcp/{secret}", newServer(d))
	d.Log.Info("MCP aktiv", "pfad", "/mcp/***", "erlaubt", d.Config.MCPAllowedCIDRs, "proxys", d.Config.TrustedProxies)
	return nil
}

// maxBody begrenzt die Größe einer JSON-RPC-Nachricht.
const maxBody = 1 << 20

// ServeHTTP prüft den Zugang und beantwortet dann die JSON-RPC-Nachricht.
// Der Pfad (enthält das Secret) wird nie geloggt.
func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	ip := clientIP(r, s.d.Config.TrustedProxies)
	log := s.log.With("ip", ip.String())

	if subtle.ConstantTimeCompare([]byte(r.PathValue("secret")), []byte(s.d.Config.MCPSecret)) != 1 {
		log.Warn("mcp: falsches Secret", "remote", r.RemoteAddr)
		http.NotFound(w, r)
		return
	}
	if !ip.IsValid() || !config.ContainsAddr(s.d.Config.MCPAllowedCIDRs, ip) {
		log.Warn("mcp: IP nicht erlaubt", "remote", r.RemoteAddr,
			"x_forwarded_for", r.Header.Values("X-Forwarded-For"), "x_real_ip", r.Header.Get("X-Real-IP"))
		writeJSON(w, http.StatusForbidden, errorResponse(nil, codeForbidden, "Zugriff von dieser Adresse nicht erlaubt.", nil))
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" {
		log.Warn("mcp: Origin-Header abgelehnt", "origin", origin)
		writeJSON(w, http.StatusForbidden, errorResponse(nil, codeForbidden, "Zugriff aus dem Browser ist nicht erlaubt.", nil))
		return
	}
	if r.Method != http.MethodPost {
		// Keine SSE-Streams und keine Sessions: GET/DELETE gibt es nicht.
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		log.Info("mcp", "http", r.Method, "status", http.StatusMethodNotAllowed)
		return
	}

	rec := &statusRecorder{ResponseWriter: w}
	info := s.handlePost(rec, r)
	attrs := []any{"methode", info.method, "status", rec.status, "dauer", time.Since(start).Round(time.Millisecond)}
	if info.tool != "" {
		attrs = append(attrs, "tool", info.tool)
	}
	if info.version != "" {
		attrs = append(attrs, "version", info.version)
	}
	if info.toolError != "" {
		attrs = append(attrs, "toolfehler", info.toolError)
	}
	log.Info("mcp", attrs...)
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	if r.status == 0 {
		r.status = code
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	return r.ResponseWriter.Write(b)
}

// requestInfo sammelt, was über eine Anfrage geloggt wird.
type requestInfo struct {
	method, tool, version, toolError string
}

func newLogger(d web.Deps) *slog.Logger {
	if d.Log != nil {
		return d.Log
	}
	return slog.New(slog.DiscardHandler)
}
