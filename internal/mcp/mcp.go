// Package mcp is an MCP server (JSON-RPC 2.0 over Streamable HTTP,
// JSON-only responses) at /mcp/{MCP_SECRET}. Its tools read, and two of them
// add expenses and reimbursements; nothing is changed or deleted.
//
// Access (see docs/MCP.md): wrong secret → 404, client IP not in
// MCP_ALLOWED_CIDRS → 403 (behind TRUSTED_PROXIES, X-Forwarded-For counts),
// Origin header set → 403. Without MCP_SECRET, MCP is disabled.
//
// Protocol: "dual era". Modern clients (2026-07-28, stateless, _meta in every
// request, mandatory headers) and older clients with the initialize handshake
// (2025-11-25, 2025-06-18, 2025-03-26) are served on the same endpoint.
// There are no sessions and no SSE streams.
package mcp

import (
	"crypto/subtle"
	"log/slog"
	"net/http"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/config"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

// Register mounts /mcp/{secret}. Without MCP_SECRET, MCP stays disabled.
func Register(mux *http.ServeMux, d web.Deps) error {
	if d.Config.MCPSecret == "" {
		d.Log.Info("MCP disabled (MCP_SECRET is empty)")
		return nil
	}
	mux.Handle("/mcp/{secret}", newServer(d))
	d.Log.Info("MCP enabled", "path", "/mcp/***", "allowed", d.Config.MCPAllowedCIDRs, "proxies", d.Config.TrustedProxies)
	return nil
}

// maxBody limits the size of a JSON-RPC message.
const maxBody = 1 << 20

// ServeHTTP checks access and then answers the JSON-RPC message.
// The path (it contains the secret) is never logged.
func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	ip := clientIP(r, s.d.Config.TrustedProxies)
	log := s.log.With("ip", ip.String())

	if subtle.ConstantTimeCompare([]byte(r.PathValue("secret")), []byte(s.d.Config.MCPSecret)) != 1 {
		log.Warn("mcp: wrong secret", "remote", r.RemoteAddr)
		http.NotFound(w, r)
		return
	}
	if !ip.IsValid() || !config.ContainsAddr(s.d.Config.MCPAllowedCIDRs, ip) {
		log.Warn("mcp: IP not allowed", "remote", r.RemoteAddr,
			"x_forwarded_for", r.Header.Values("X-Forwarded-For"), "x_real_ip", r.Header.Get("X-Real-IP"))
		writeJSON(w, http.StatusForbidden, errorResponse(nil, codeForbidden, "Access from this address is not allowed.", nil))
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" {
		log.Warn("mcp: Origin header rejected", "origin", origin)
		writeJSON(w, http.StatusForbidden, errorResponse(nil, codeForbidden, "Access from a browser is not allowed.", nil))
		return
	}
	if r.Method != http.MethodPost {
		// No SSE streams and no sessions: there is no GET/DELETE.
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		log.Info("mcp", "http", r.Method, "status", http.StatusMethodNotAllowed)
		return
	}

	rec := &statusRecorder{ResponseWriter: w}
	info := s.handlePost(rec, r)
	attrs := []any{"method", info.method, "status", rec.status, "duration", time.Since(start).Round(time.Millisecond)}
	if info.tool != "" {
		attrs = append(attrs, "tool", info.tool)
	}
	if info.version != "" {
		attrs = append(attrs, "version", info.version)
	}
	if info.toolError != "" {
		attrs = append(attrs, "tool_error", info.toolError)
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

// requestInfo collects what is logged about a request.
type requestInfo struct {
	method, tool, version, toolError string
}

func newLogger(d web.Deps) *slog.Logger {
	if d.Log != nil {
		return d.Log
	}
	return slog.New(slog.DiscardHandler)
}
