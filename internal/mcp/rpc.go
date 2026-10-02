package mcp

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// Protocol versions. Modern = stateless with _meta per request, legacy =
// initialize handshake. The first version of each list is the preferred one.
var (
	modernVersions = []string{"2026-07-28"}
	legacyVersions = []string{"2025-11-25", "2025-06-18", "2025-03-26"}
	allVersions    = slices.Concat(modernVersions, legacyVersions)
)

// legacyDefault applies to requests without an MCP-Protocol-Version header
// (as the spec requires for clients before 2025-06-18).
const legacyDefault = "2025-03-26"

// JSON-RPC and MCP error codes.
const (
	codeParseError         = -32700
	codeInvalidRequest     = -32600
	codeMethodNotFound     = -32601
	codeInvalidParams      = -32602
	codeInternal           = -32603
	codeForbidden          = -32000 // implementation-specific: access denied
	codeHeaderMismatch     = -32020
	codeUnsupportedVersion = -32022
)

// _meta keys (modern).
const (
	metaProtocolVersion = "io.modelcontextprotocol/protocolVersion"
	metaServerInfo      = "io.modelcontextprotocol/serverInfo"
)

// toolTimeout limits a tool call (sql_query additionally has 5 s).
const toolTimeout = 20 * time.Second

// listTTL is the cache hint (ttlMs) for tools/list and server/discover.
const listTTL = time.Hour

type message struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"` // nil = notification (field missing)
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
	Result  json.RawMessage `json:"result"`
	Error   json.RawMessage `json:"error"`
}

type params struct {
	Meta            map[string]json.RawMessage `json:"_meta"`
	Name            string                     `json:"name"`            // tools/call
	Arguments       json.RawMessage            `json:"arguments"`       // tools/call
	ProtocolVersion string                     `json:"protocolVersion"` // initialize
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

func errorResponse(id json.RawMessage, code int, msg string, data any) response {
	return response{JSONRPC: "2.0", ID: id, Error: &rpcError{Code: code, Message: msg, Data: data}}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	b, err := marshal(v)
	if err != nil {
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(append(b, '\n'))
}

// marshal is json.Marshal without HTML escaping ("&" stays "&").
func marshal(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// handlePost answers exactly one JSON-RPC message.
func (s *server) handlePost(w http.ResponseWriter, r *http.Request) (info requestInfo) {
	fail := func(status int, id json.RawMessage, code int, msg string, data any) requestInfo {
		writeJSON(w, status, errorResponse(id, code, msg, data))
		return info
	}
	if mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); mt != "application/json" {
		return fail(http.StatusUnsupportedMediaType, nil, codeInvalidRequest, "Content-Type must be application/json.", nil)
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		return fail(http.StatusRequestEntityTooLarge, nil, codeInvalidRequest, "Message too large or incomplete.", nil)
	}
	if b := bytes.TrimSpace(body); len(b) > 0 && b[0] == '[' {
		return fail(http.StatusBadRequest, nil, codeInvalidRequest, "JSON-RPC batches are not supported.", nil)
	}
	var m message
	if err := json.Unmarshal(body, &m); err != nil {
		return fail(http.StatusBadRequest, nil, codeParseError, "Invalid JSON: "+err.Error(), nil)
	}
	info.method = m.Method
	if m.Method == "" {
		if m.Result != nil || m.Error != nil {
			w.WriteHeader(http.StatusAccepted) // a response from the client – we never send requests
			return info
		}
		return fail(http.StatusBadRequest, m.ID, codeInvalidRequest, "Field method is missing.", nil)
	}
	if m.JSONRPC != "2.0" {
		return fail(http.StatusBadRequest, m.ID, codeInvalidRequest, `jsonrpc must be "2.0".`, nil)
	}
	var p params
	if len(m.Params) > 0 && string(m.Params) != "null" {
		if err := json.Unmarshal(m.Params, &p); err != nil {
			return fail(http.StatusBadRequest, m.ID, codeInvalidParams, "Invalid params: "+err.Error(), nil)
		}
	}
	metaVersion := ""
	if raw, ok := p.Meta[metaProtocolVersion]; ok {
		if err := json.Unmarshal(raw, &metaVersion); err != nil || metaVersion == "" {
			return fail(http.StatusBadRequest, m.ID, codeInvalidParams, "_meta."+metaProtocolVersion+" must be a non-empty string.", nil)
		}
	}
	notification := m.ID == nil
	headerVersion := r.Header.Get("MCP-Protocol-Version")

	// Determine era and version.
	modern := false
	switch {
	case metaVersion != "":
		// Modern request: the version is in the body, headers must match it.
		info.version = metaVersion
		if notification {
			w.WriteHeader(http.StatusAccepted)
			return info
		}
		if msg := checkHeaders(r, m.Method, p.Name, metaVersion); msg != "" {
			return fail(http.StatusBadRequest, m.ID, codeHeaderMismatch, msg, nil)
		}
		switch {
		case slices.Contains(modernVersions, metaVersion):
			modern = true
		case slices.Contains(legacyVersions, metaVersion):
			// Older version with _meta: answer like legacy.
		default:
			return fail(http.StatusBadRequest, m.ID, codeUnsupportedVersion, "Unsupported protocol version.",
				map[string]any{"supported": allVersions, "requested": metaVersion})
		}
	case m.Method == "initialize":
		info.version = negotiate(p.ProtocolVersion)
	default:
		v := headerVersion
		if v == "" {
			v = legacyDefault
		}
		info.version = v
		if !slices.Contains(legacyVersions, v) {
			if slices.Contains(modernVersions, v) {
				return fail(http.StatusBadRequest, m.ID, codeHeaderMismatch,
					fmt.Sprintf("Header MCP-Protocol-Version is %s, but params._meta[%q] is missing.", v, metaProtocolVersion), nil)
			}
			return fail(http.StatusBadRequest, m.ID, codeUnsupportedVersion, "Unsupported protocol version.",
				map[string]any{"supported": allVersions, "requested": v})
		}
		if notification {
			w.WriteHeader(http.StatusAccepted) // e.g. notifications/initialized
			return info
		}
	}
	if notification {
		w.WriteHeader(http.StatusAccepted)
		return info
	}

	ctx, cancel := context.WithTimeout(r.Context(), toolTimeout)
	defer cancel()
	result, rerr := s.dispatch(ctx, modern, m.Method, p, &info)
	if rerr != nil {
		status := http.StatusOK
		if modern && rerr.Code == codeMethodNotFound {
			status = http.StatusNotFound // required by spec 2026-07-28
		}
		writeJSON(w, status, response{JSONRPC: "2.0", ID: m.ID, Error: rerr})
		return info
	}
	if modern {
		result["resultType"] = "complete"
		meta, _ := result["_meta"].(map[string]any)
		if meta == nil {
			meta = map[string]any{}
		}
		meta[metaServerInfo] = serverInfo()
		result["_meta"] = meta
	}
	writeJSON(w, http.StatusOK, response{JSONRPC: "2.0", ID: m.ID, Result: result})
	return info
}

// negotiate picks the legacy version for initialize: the requested one if
// supported, otherwise the newest legacy version.
func negotiate(requested string) string {
	if slices.Contains(legacyVersions, requested) {
		return requested
	}
	return legacyVersions[0]
}

// checkHeaders checks the mandatory headers of modern requests against the
// body and returns an error message (empty = fine).
func checkHeaders(r *http.Request, method, name, version string) string {
	h := r.Header.Get("MCP-Protocol-Version")
	switch {
	case h == "":
		return "Header mismatch: header MCP-Protocol-Version is missing."
	case h != version:
		return fmt.Sprintf("Header mismatch: MCP-Protocol-Version %q does not match _meta %q.", h, version)
	}
	h = r.Header.Get("Mcp-Method")
	switch {
	case h == "":
		return "Header mismatch: header Mcp-Method is missing."
	case h != method:
		return fmt.Sprintf("Header mismatch: Mcp-Method %q does not match method %q.", h, method)
	}
	if method == "tools/call" {
		h = r.Header.Get("Mcp-Name")
		if h == "" {
			return "Header mismatch: header Mcp-Name is missing."
		}
		v, ok := decodeHeaderValue(h)
		if !ok {
			return "Header mismatch: Mcp-Name is not valid Base64."
		}
		if v != name {
			return fmt.Sprintf("Header mismatch: Mcp-Name %q does not match params.name %q.", v, name)
		}
	}
	return ""
}

// decodeHeaderValue decodes the Base64 format =?base64?…?= (other values are
// returned as they are).
func decodeHeaderValue(v string) (string, bool) {
	const prefix, suffix = "=?base64?", "?="
	if !strings.HasPrefix(v, prefix) || !strings.HasSuffix(v, suffix) || len(v) < len(prefix)+len(suffix) {
		return v, true
	}
	enc := v[len(prefix) : len(v)-len(suffix)]
	b, err := base64.StdEncoding.DecodeString(enc)
	if err != nil {
		if b, err = base64.RawStdEncoding.DecodeString(enc); err != nil {
			return "", false
		}
	}
	return string(b), true
}

// dispatch runs the method. Results are maps so that handlePost can add the
// mandatory modern fields.
func (s *server) dispatch(ctx context.Context, modern bool, method string, p params, info *requestInfo) (map[string]any, *rpcError) {
	switch method {
	case "initialize":
		if modern {
			break
		}
		return map[string]any{
			"protocolVersion": info.version,
			"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
			"serverInfo":      serverInfo(),
			"instructions":    s.instructions(ctx),
		}, nil
	case "server/discover":
		return map[string]any{
			"supportedVersions": allVersions,
			"capabilities":      map[string]any{"tools": map[string]any{"listChanged": false}},
			"instructions":      s.instructions(ctx),
			"_meta":             map[string]any{metaServerInfo: serverInfo()},
			"ttlMs":             s.discoverTTL().Milliseconds(),
			"cacheScope":        "public",
		}, nil
	case "ping":
		// Removed in 2026-07-28, but harmless.
		return map[string]any{}, nil
	case "tools/list":
		res := map[string]any{"tools": s.toolDefs()}
		if modern {
			res["ttlMs"] = listTTL.Milliseconds()
			res["cacheScope"] = "public"
		}
		return res, nil
	case "tools/call":
		return s.callTool(ctx, p, info)
	}
	return nil, &rpcError{Code: codeMethodNotFound, Message: "Unknown method: " + method}
}

func (s *server) callTool(ctx context.Context, p params, info *requestInfo) (map[string]any, *rpcError) {
	t, ok := s.tools[p.Name]
	if !ok {
		return nil, &rpcError{Code: codeInvalidParams, Message: "Unknown tool: " + p.Name}
	}
	info.tool = p.Name
	res, err := t.run(ctx, p.Arguments)
	if err != nil {
		msg := err.Error()
		var ve domain.ValidationError
		if !errors.As(err, &ve) {
			s.log.Error("mcp: tool failed", "tool", p.Name, "err", err)
			msg = "Internal error while running the tool (details in the server log)."
		}
		info.toolError = msg
		return map[string]any{
			"content": []any{map[string]any{"type": "text", "text": msg}},
			"isError": true,
		}, nil
	}
	text := res.text
	if text == "" {
		b, err := marshal(res.data)
		if err != nil {
			return nil, &rpcError{Code: codeInternal, Message: "Result cannot be serialized."}
		}
		text = string(b)
	}
	// Only the text, no structuredContent: a copy of the JSON in both would
	// double the size. Claude.ai/Desktop only pass content on to the model,
	// Claude Code and VS Code only structuredContent if it is there – and
	// content otherwise. Hence no outputSchema either (it requires
	// structuredContent).
	return map[string]any{
		"content": []any{map[string]any{"type": "text", "text": text}},
		"isError": false,
	}, nil
}
