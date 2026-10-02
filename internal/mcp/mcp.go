// Package mcp ist ein schreibgeschützter MCP-Server (JSON-RPC 2.0 über
// Streamable HTTP) unter /mcp/{MCP_SECRET}, nur für MCP_ALLOWED_CIDRS.
//
// Stand Phase 0: Stub. Prüft nur das Secret.
package mcp

import (
	"crypto/subtle"
	"net/http"

	"teilen/internal/web"
)

// Register hängt /mcp/{secret} an. Ohne MCP_SECRET bleibt MCP abgeschaltet.
func Register(mux *http.ServeMux, d web.Deps) error {
	if d.Config.MCPSecret == "" {
		d.Log.Info("MCP abgeschaltet (MCP_SECRET ist leer)")
		return nil
	}
	mux.Handle("/mcp/{secret}", handler{d})
	return nil
}

type handler struct{ d web.Deps }

func (h handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if subtle.ConstantTimeCompare([]byte(r.PathValue("secret")), []byte(h.d.Config.MCPSecret)) != 1 {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}
	web.WriteJSON(w, http.StatusNotImplemented, map[string]any{
		"jsonrpc": "2.0",
		"id":      nil,
		"error":   map[string]any{"code": -32601, "message": "MCP ist noch nicht implementiert"},
	})
}
