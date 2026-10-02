package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/config"
	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

const (
	testSecret = "s3cr3t-0123456789abcdef"
	anthropic  = "160.79.104.10:40000" // in MCP_ALLOWED_CIDRS
	modern     = "2026-07-28"
)

type env struct {
	t     *testing.T
	h     http.Handler
	st    *store.Store
	logs  *bytes.Buffer
	ids   map[string]int64
	cats  map[string]int64
	today time.Time
	deps  web.Deps
}

// at lets the server run with a fixed clock (date in the server time zone,
// noon).
func (e *env) at(date string) {
	e.t.Helper()
	d, err := domain.ParseDate(date)
	if err != nil {
		e.t.Fatal(err)
	}
	srv := newServer(e.deps)
	now := time.Date(d.Year(), d.Month(), d.Day(), 12, 0, 0, 0, srv.location())
	srv.now = func() time.Time { return now }
	mux := http.NewServeMux()
	mux.Handle("/mcp/{secret}", srv)
	e.h = mux
}

func newEnv(t *testing.T) *env {
	t.Helper()
	cfg, err := config.FromEnv(func(k string) string {
		return map[string]string{"MCP_SECRET": testSecret, "TRUSTED_PROXIES": "10.0.0.1"}[k]
	})
	if err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(filepath.Join(t.TempDir(), "zipfelkasse.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	logs := &bytes.Buffer{}
	d := web.Deps{Config: cfg, Store: st, Log: slog.New(slog.NewTextHandler(logs, nil))}
	mux := http.NewServeMux()
	if err := Register(mux, d); err != nil {
		t.Fatal(err)
	}
	e := &env{t: t, h: mux, st: st, logs: logs, ids: map[string]int64{}, cats: map[string]int64{}, deps: d}
	ctx := context.Background()
	for _, n := range []string{"Anna", "Ben", "Cleo"} {
		if e.ids[n], err = st.CreateParticipant(ctx, 0, n); err != nil {
			t.Fatal(err)
		}
	}
	cs, _ := st.ListCategories(ctx, true)
	for _, c := range cs {
		e.cats[c.Name] = c.ID
	}
	return e
}

func (e *env) expense(title string, cents int64, date, payer, category string, who ...string) {
	e.t.Helper()
	d, _ := domain.ParseDate(date)
	in := store.ExpenseInput{Title: title, Date: d, PaidBy: e.ids[payer], SplitMode: domain.SplitEqual, AmountCents: cents, CategoryID: e.cats[category]}
	for _, w := range who {
		in.Parts = append(in.Parts, domain.Part{ParticipantID: e.ids[w]})
	}
	if _, err := e.st.CreateExpense(context.Background(), e.ids[payer], in); err != nil {
		e.t.Fatal(err)
	}
}

type reply struct {
	status int
	header http.Header
	raw    string
	body   map[string]any
}

// send sends a request. hdr: additional headers; remote "" = anthropic.
func (e *env) send(method, path, remote string, hdr map[string]string, body string) reply {
	e.t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.RemoteAddr = remote
	if remote == "" {
		req.RemoteAddr = anthropic
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	for k, v := range hdr {
		if v == "" {
			req.Header.Del(k)
		} else {
			req.Header.Set(k, v)
		}
	}
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	r := reply{status: rec.Code, header: rec.Header(), raw: rec.Body.String()}
	if strings.HasPrefix(rec.Header().Get("Content-Type"), "application/json") {
		if err := json.Unmarshal(rec.Body.Bytes(), &r.body); err != nil {
			e.t.Fatalf("response is not JSON: %v: %s", err, r.raw)
		}
	}
	return r
}

// legacy sends a legacy request (header MCP-Protocol-Version 2025-06-18).
func (e *env) legacy(method string, params any) reply {
	e.t.Helper()
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	return e.send("POST", "/mcp/"+testSecret, "", map[string]string{"MCP-Protocol-Version": "2025-06-18"}, string(b))
}

// modern builds a modern request with matching headers.
func (e *env) modern(method string, params map[string]any, hdr map[string]string) reply {
	e.t.Helper()
	if params == nil {
		params = map[string]any{}
	}
	if _, ok := params["_meta"]; !ok {
		params["_meta"] = map[string]any{
			"io.modelcontextprotocol/protocolVersion":    modern,
			"io.modelcontextprotocol/clientInfo":         map[string]any{"name": "test", "version": "1"},
			"io.modelcontextprotocol/clientCapabilities": map[string]any{},
		}
	}
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": "a-1", "method": method, "params": params})
	h := map[string]string{"MCP-Protocol-Version": modern, "Mcp-Method": method}
	if name, ok := params["name"].(string); ok {
		h["Mcp-Name"] = name
	}
	for k, v := range hdr {
		h[k] = v
	}
	return e.send("POST", "/mcp/"+testSecret, "", h, string(b))
}

func (r reply) result(t *testing.T) map[string]any {
	t.Helper()
	res, ok := r.body["result"].(map[string]any)
	if !ok {
		t.Fatalf("no result (status %d): %s", r.status, r.raw)
	}
	return res
}

func (r reply) errCode() float64 {
	if e, ok := r.body["error"].(map[string]any); ok {
		c, _ := e["code"].(float64)
		return c
	}
	return 0
}

// call calls a tool (legacy) and returns the text parsed as a JSON object
// (nil if it is not one), the text and isError.
func (e *env) call(name string, args map[string]any) (map[string]any, string, bool) {
	e.t.Helper()
	res := e.legacy("tools/call", map[string]any{"name": name, "arguments": args}).result(e.t)
	content := res["content"].([]any)[0].(map[string]any)
	if _, ok := res["structuredContent"]; ok {
		e.t.Errorf("%s: structuredContent duplicates the text", name)
	}
	var sc map[string]any
	_ = json.Unmarshal([]byte(content["text"].(string)), &sc)
	return sc, content["text"].(string), res["isError"] == true
}

func TestAccess(t *testing.T) {
	e := newEnv(t)
	ping := `{"jsonrpc":"2.0","id":1,"method":"ping"}`
	path := "/mcp/" + testSecret
	tests := []struct {
		name   string
		method string
		path   string
		remote string
		hdr    map[string]string
		want   int
	}{
		{"allowed", "POST", path, "", nil, 200},
		{"wrong secret", "POST", "/mcp/wrong", "", nil, 404},
		{"secret prefix", "POST", path[:len(path)-1], "", nil, 404},
		{"wrong secret from foreign IP", "POST", "/mcp/wrong", "1.2.3.4:1", nil, 404},
		{"foreign IP", "POST", path, "1.2.3.4:1", nil, 403},
		{"XFF spoofing without proxy", "POST", path, "1.2.3.4:1", map[string]string{"X-Forwarded-For": "160.79.104.10"}, 403},
		{"X-Real-IP spoofing without proxy", "POST", path, "1.2.3.4:1", map[string]string{"X-Real-IP": "160.79.104.10"}, 403},
		{"allowed via proxy", "POST", path, "10.0.0.1:9", map[string]string{"X-Forwarded-For": "160.79.104.10"}, 200},
		{"via proxy, prepended forgery", "POST", path, "10.0.0.1:9", map[string]string{"X-Forwarded-For": "160.79.104.10, 1.2.3.4"}, 403},
		{"via proxy without header", "POST", path, "10.0.0.1:9", nil, 403},
		{"via proxy with X-Real-IP", "POST", path, "10.0.0.1:9", map[string]string{"X-Real-IP": "160.79.104.10"}, 200},
		{"Origin set", "POST", path, "", map[string]string{"Origin": "https://evil.example"}, 403},
		{"Origin null", "POST", path, "", map[string]string{"Origin": "null"}, 403},
		{"GET", "GET", path, "", nil, 405},
		{"DELETE", "DELETE", path, "", nil, 405},
		{"wrong Content-Type", "POST", path, "", map[string]string{"Content-Type": "text/plain"}, 415},
	}
	for _, tt := range tests {
		r := e.send(tt.method, tt.path, tt.remote, tt.hdr, ping)
		if r.status != tt.want {
			t.Errorf("%s: status %d, want %d (%s)", tt.name, r.status, tt.want, r.raw)
		}
		if tt.want == 404 && strings.Contains(r.raw, "mcp") {
			t.Errorf("%s: 404 reveals something: %q", tt.name, r.raw)
		}
	}
	if r := e.send("GET", path, "", nil, ""); r.header.Get("Allow") != "POST" {
		t.Errorf("405 without Allow: %v", r.header)
	}
	// The secret never shows up in the log, but accesses do.
	logs := e.logs.String()
	if strings.Contains(logs, testSecret) || strings.Contains(logs, testSecret[:10]) {
		t.Errorf("secret in the log:\n%s", logs)
	}
	for _, want := range []string{"method=ping", "ip=160.79.104.10", "wrong secret", "IP not allowed", "Origin header rejected"} {
		if !strings.Contains(logs, want) {
			t.Errorf("log without %q:\n%s", want, logs)
		}
	}
}

func TestDisabledWithoutSecret(t *testing.T) {
	mux := http.NewServeMux()
	d := web.Deps{Log: slog.New(slog.DiscardHandler)}
	if err := Register(mux, d); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("POST", "/mcp/", nil))
	if rec.Code != 404 {
		t.Errorf("status %d, want 404", rec.Code)
	}
}

func TestLegacyProtocol(t *testing.T) {
	e := newEnv(t)
	// initialize without version header, the requested version is accepted.
	b := `{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-ai","version":"0.1.0"}}}`
	r := e.send("POST", "/mcp/"+testSecret, "", nil, b)
	res := r.result(t)
	if res["protocolVersion"] != "2025-06-18" || r.header.Get("Mcp-Session-Id") != "" || r.header.Get("Content-Type") != "application/json" {
		t.Errorf("initialize: %d %v %v", r.status, res, r.header)
	}
	if tools := res["capabilities"].(map[string]any)["tools"]; tools == nil {
		t.Errorf("capabilities without tools: %v", res)
	}
	if res["serverInfo"].(map[string]any)["name"] != "zipfelkasse" || !strings.Contains(res["instructions"].(string), "Balance") {
		t.Errorf("serverInfo/instructions: %v", res)
	}
	if _, ok := res["resultType"]; ok {
		t.Error("legacy result with resultType")
	}
	// Unknown version → newest legacy version.
	b = `{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}`
	if v := e.send("POST", "/mcp/"+testSecret, "", nil, b).result(t)["protocolVersion"]; v != "2025-11-25" {
		t.Errorf("negotiation 2024-11-05 → %v", v)
	}
	// notifications/initialized → 202 without body.
	r = e.send("POST", "/mcp/"+testSecret, "", map[string]string{"MCP-Protocol-Version": "2025-06-18"},
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	if r.status != 202 || r.raw != "" {
		t.Errorf("initialized: %d %q", r.status, r.raw)
	}
	// tools/list with and without header (without = 2025-03-26).
	res = e.legacy("tools/list", nil).result(t)
	tools := res["tools"].([]any)
	var names []string
	for _, tl := range tools {
		m := tl.(map[string]any)
		names = append(names, m["name"].(string))
		if m["description"] == "" || m["inputSchema"].(map[string]any)["type"] != "object" || m["annotations"].(map[string]any)["readOnlyHint"] != true {
			t.Errorf("tool incomplete: %v", m)
		}
	}
	if strings.Join(names, ",") != "balances,balance_history,search_expenses,statistics,activity,schema,sql_query" {
		t.Errorf("Tools = %v", names)
	}
	r = e.send("POST", "/mcp/"+testSecret, "", nil, `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	if r.status != 200 || len(r.result(t)["tools"].([]any)) != 7 {
		t.Errorf("tools/list without header: %d %s", r.status, r.raw)
	}
	// Unsupported version in the header → 400 with list.
	r = e.send("POST", "/mcp/"+testSecret, "", map[string]string{"MCP-Protocol-Version": "1999-01-01"}, `{"jsonrpc":"2.0","id":3,"method":"tools/list"}`)
	if r.status != 400 || r.errCode() != codeUnsupportedVersion {
		t.Errorf("unknown version: %d %s", r.status, r.raw)
	}
	// ping, unknown method.
	if r = e.legacy("ping", nil); r.status != 200 || len(r.result(t)) != 0 {
		t.Errorf("ping: %s", r.raw)
	}
	if r = e.legacy("resources/list", nil); r.errCode() != codeMethodNotFound {
		t.Errorf("unknown method: %d %s", r.status, r.raw)
	}
	// An unknown tool is a protocol error.
	if r = e.legacy("tools/call", map[string]any{"name": "doesnotexist"}); r.errCode() != codeInvalidParams {
		t.Errorf("unknown tool: %s", r.raw)
	}
}

// The current date (server time zone) is computed per request for the
// instructions and the schema text; discover is cached at most until midnight.
func TestTodayInInstructionsAndSchema(t *testing.T) {
	e := newEnv(t)
	cfg := config.Config{MCPSecret: testSecret, MCPAllowedCIDRs: []netip.Prefix{netip.MustParsePrefix("160.79.104.0/21")},
		Location: time.FixedZone("Test/Zone", 2*3600)}
	srv := newServer(web.Deps{Config: cfg, Store: e.st})
	now := time.Date(2026, 10, 2, 21, 30, 0, 0, time.UTC) // 23:30 local time
	srv.now = func() time.Time { return now }
	mux := http.NewServeMux()
	mux.Handle("/mcp/{secret}", srv)
	e.h = mux

	const friday = "Today is 2026-10-02 (Friday), server time zone Test/Zone."
	res := e.send("POST", "/mcp/"+testSecret, "", nil,
		`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`).result(t)
	if !strings.Contains(res["instructions"].(string), friday) {
		t.Errorf("initialize instructions: %s", res["instructions"])
	}
	res = e.modern("server/discover", nil, nil).result(t)
	if !strings.Contains(res["instructions"].(string), friday) || res["ttlMs"].(float64) != 30*60*1000 {
		t.Errorf("discover: ttlMs %v, %s", res["ttlMs"], res["instructions"])
	}
	now = now.Add(time.Hour) // 00:30 local time, next day
	if _, text, _ := e.call("schema", nil); !strings.Contains(text, "Today is 2026-10-03 (Saturday), server time zone Test/Zone.") {
		t.Errorf("schema without date: %.200s", text)
	}
	if res = e.modern("server/discover", nil, nil).result(t); res["ttlMs"].(float64) != float64(listTTL.Milliseconds()) {
		t.Errorf("discover ttlMs after midnight = %v", res["ttlMs"])
	}
}

func TestModernProtocol(t *testing.T) {
	e := newEnv(t)
	r := e.modern("server/discover", nil, nil)
	res := r.result(t)
	if r.status != 200 || res["resultType"] != "complete" || res["cacheScope"] != "public" || res["ttlMs"].(float64) <= 0 {
		t.Errorf("discover: %d %s", r.status, r.raw)
	}
	if v := res["supportedVersions"].([]any); v[0] != modern || len(v) != len(allVersions) {
		t.Errorf("supportedVersions = %v", v)
	}
	if res["_meta"].(map[string]any)["io.modelcontextprotocol/serverInfo"].(map[string]any)["name"] != "zipfelkasse" {
		t.Errorf("serverInfo missing: %v", res)
	}
	res = e.modern("tools/list", nil, nil).result(t)
	if res["resultType"] != "complete" || res["ttlMs"] == nil || len(res["tools"].([]any)) != 7 {
		t.Errorf("tools/list: %v", res)
	}
	res = e.modern("tools/call", map[string]any{"name": "balances", "arguments": map[string]any{}}, nil).result(t)
	if text := res["content"].([]any)[0].(map[string]any)["text"].(string); res["resultType"] != "complete" || res["isError"] != false ||
		res["structuredContent"] != nil || !strings.HasPrefix(text, `{"balances":`) {
		t.Errorf("tools/call: %v", res)
	}
	// Mcp-Name in Base64 format.
	r = e.modern("tools/call", map[string]any{"name": "balances"}, map[string]string{"Mcp-Name": "=?base64?YmFsYW5jZXM=?="})
	if r.status != 200 || r.result(t)["isError"] != false {
		t.Errorf("Base64 Mcp-Name: %d %s", r.status, r.raw)
	}

	bad := []struct {
		name   string
		method string
		params map[string]any
		hdr    map[string]string
		status int
		code   float64
	}{
		{"version header missing", "tools/list", nil, map[string]string{"MCP-Protocol-Version": ""}, 400, codeHeaderMismatch},
		{"version header wrong", "tools/list", nil, map[string]string{"MCP-Protocol-Version": "2025-11-25"}, 400, codeHeaderMismatch},
		{"Mcp-Method missing", "tools/list", nil, map[string]string{"Mcp-Method": ""}, 400, codeHeaderMismatch},
		{"Mcp-Method wrong", "tools/list", nil, map[string]string{"Mcp-Method": "tools/call"}, 400, codeHeaderMismatch},
		{"Mcp-Name missing", "tools/call", map[string]any{"name": "balances"}, map[string]string{"Mcp-Name": ""}, 400, codeHeaderMismatch},
		{"Mcp-Name wrong", "tools/call", map[string]any{"name": "balances"}, map[string]string{"Mcp-Name": "schema"}, 400, codeHeaderMismatch},
		{"Mcp-Name Base64 wrong", "tools/call", map[string]any{"name": "balances"}, map[string]string{"Mcp-Name": "=?base64?c2NoZW1h?="}, 400, codeHeaderMismatch},
		{"Mcp-Name Base64 broken", "tools/call", map[string]any{"name": "balances"}, map[string]string{"Mcp-Name": "=?base64?***?="}, 400, codeHeaderMismatch},
		{"unknown method", "resources/list", nil, nil, 404, codeMethodNotFound},
		{"initialize modern", "initialize", nil, nil, 404, codeMethodNotFound},
		{"unknown tool", "tools/call", map[string]any{"name": "nothing"}, nil, 200, codeInvalidParams},
	}
	for _, tt := range bad {
		r := e.modern(tt.method, tt.params, tt.hdr)
		if r.status != tt.status || r.errCode() != tt.code || r.body["id"] != "a-1" {
			t.Errorf("%s: %d %s; want %d/%v", tt.name, r.status, r.raw, tt.status, tt.code)
		}
	}

	// Unsupported modern version: 400 with supported/requested.
	meta := map[string]any{"io.modelcontextprotocol/protocolVersion": "2099-01-01", "io.modelcontextprotocol/clientCapabilities": map[string]any{}}
	r = e.modern("tools/list", map[string]any{"_meta": meta}, map[string]string{"MCP-Protocol-Version": "2099-01-01"})
	if r.status != 400 || r.errCode() != codeUnsupportedVersion {
		t.Fatalf("2099: %d %s", r.status, r.raw)
	}
	data := r.body["error"].(map[string]any)["data"].(map[string]any)
	if data["requested"] != "2099-01-01" || data["supported"].([]any)[0] != modern {
		t.Errorf("data = %v", data)
	}
	// Modern header, but no _meta in the body.
	r = e.send("POST", "/mcp/"+testSecret, "", map[string]string{"MCP-Protocol-Version": modern, "Mcp-Method": "tools/list"},
		`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	if r.status != 400 || r.errCode() != codeHeaderMismatch {
		t.Errorf("without _meta: %d %s", r.status, r.raw)
	}
	// Notification → 202.
	r = e.send("POST", "/mcp/"+testSecret, "", map[string]string{"MCP-Protocol-Version": modern},
		`{"jsonrpc":"2.0","method":"notifications/whatever","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}`)
	if r.status != 202 || r.raw != "" {
		t.Errorf("notification: %d %q", r.status, r.raw)
	}
}

func TestMalformed(t *testing.T) {
	e := newEnv(t)
	tests := []struct {
		body   string
		status int
		code   float64
	}{
		{`{broken`, 400, codeParseError},
		{`[{"jsonrpc":"2.0","id":1,"method":"ping"}]`, 400, codeInvalidRequest},
		{`{"id":1,"method":"ping"}`, 400, codeInvalidRequest},
		{`{"jsonrpc":"2.0","id":1}`, 400, codeInvalidRequest},
		{`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[1]}`, 400, codeInvalidParams},
		{`{"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":7}}}`, 400, codeInvalidParams},
		{`{"jsonrpc":"2.0","id":1,"result":{}}`, 202, 0},
	}
	for _, tt := range tests {
		r := e.send("POST", "/mcp/"+testSecret, "", nil, tt.body)
		if r.status != tt.status || r.errCode() != tt.code {
			t.Errorf("%s: %d %s; want %d/%v", tt.body, r.status, r.raw, tt.status, tt.code)
		}
	}
	big := `{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"` + strings.Repeat("a", maxBody) + `"}}`
	if r := e.send("POST", "/mcp/"+testSecret, "", nil, big); r.status != http.StatusRequestEntityTooLarge {
		t.Errorf("too large: %d", r.status)
	}
}

func TestSearchExpensesUmlauts(t *testing.T) {
	e := newEnv(t)
	e.expense("Bäckerei", 300, "2026-09-01", "Anna", "Lebensmittel", "Anna", "Ben")
	e.expense("ÖLWECHSEL", 9000, "2026-09-02", "Ben", "", "Anna", "Ben")
	for text, want := range map[string]string{"BÄCKEREI": "Bäckerei", "bäcker": "Bäckerei", "ölwechsel": "ÖLWECHSEL", "Ölwechsel": "ÖLWECHSEL"} {
		sc, msg, isErr := e.call("search_expenses", map[string]any{"text": text})
		if isErr || sc["matches"].(float64) != 1 || sc["expenses"].([]any)[0].(map[string]any)["title"] != want {
			t.Errorf("text %q: %s", text, msg)
		}
	}
}

// category "none" (and the statistics label "No category") selects expenses
// without a category.
func TestCategoryNone(t *testing.T) {
	e := newEnv(t)
	e.expense("Tanken", 5000, "2026-09-01", "Anna", "", "Anna", "Ben")
	e.expense("Rewe", 3000, "2026-09-02", "Ben", "Lebensmittel", "Anna", "Ben")
	e.expense("Pizza", 2000, "2026-09-03", "Ben", "Restaurant", "Ben")
	for _, cat := range []string{"none", "No category", "NONE"} {
		sc, text, isErr := e.call("search_expenses", map[string]any{"category": cat})
		if isErr || sc["matches"].(float64) != 1 || sc["expenses"].([]any)[0].(map[string]any)["title"] != "Tanken" {
			t.Errorf("search_expenses %q: %s", cat, text)
		}
	}
	sc, text, isErr := e.call("statistics", map[string]any{"group_by": "category", "category": "none"})
	if rows := sc["rows"].([]any); isErr || len(rows) != 1 || rows[0].(map[string]any)["category"] != "No category" || sc["total_cents"].(float64) != 5000 {
		t.Errorf("statistics none: %s", text)
	}
	sc, text, _ = e.call("statistics", map[string]any{"group_by": "person", "category": "lebensmittel"})
	if rows := sc["rows"].([]any); len(rows) != 2 || sc["total_cents"].(float64) != 3000 {
		t.Errorf("statistics person/Lebensmittel: %s", text)
	}
	if _, text, isErr := e.call("statistics", map[string]any{"group_by": "month", "category": "Yacht"}); !isErr || !strings.Contains(text, "Yacht") {
		t.Errorf("unknown category: %v %s", isErr, text)
	}
}

// A real category named like the special value takes precedence.
func TestCategoryNamedNone(t *testing.T) {
	e := newEnv(t)
	id, err := e.st.CreateCategory(context.Background(), 0, "None")
	if err != nil {
		t.Fatal(err)
	}
	e.cats["None"] = id
	e.expense("Tanken", 5000, "2026-09-01", "Anna", "", "Anna", "Ben")
	e.expense("Kram", 1000, "2026-09-02", "Anna", "None", "Anna", "Ben")
	sc, text, isErr := e.call("search_expenses", map[string]any{"category": "none"})
	if isErr || sc["matches"].(float64) != 1 || sc["expenses"].([]any)[0].(map[string]any)["title"] != "Kram" {
		t.Errorf("category None: %s", text)
	}
}

func TestMoney(t *testing.T) {
	if got := eur(-300000); got != "-3000.00" {
		t.Errorf("eur = %q", got)
	}
	if got := money(2340, "usd"); got != "23.40 USD" {
		t.Errorf("money USD = %q", got)
	}
	if got := money(1500, "JPY"); got != "1500 JPY" {
		t.Errorf("money JPY = %q", got)
	}
}

func TestTools(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	e.expense("Rewe", 3000, "2026-08-15", "Anna", "Lebensmittel", "Anna", "Ben", "Cleo")
	e.expense("Pizza & Wein", 4000, "2026-09-10", "Cleo", "Restaurant", "Ben", "Cleo")
	e.expense("Edeka", 1000, "2026-09-01", "Ben", "Lebensmittel", "Anna", "Ben")
	usd, _ := domain.ParseDate("2026-09-20")
	if _, err := e.st.CreateExpense(ctx, e.ids["Anna"], store.ExpenseInput{Title: "Diner NYC", Date: usd, PaidBy: e.ids["Anna"],
		SplitMode: domain.SplitEqual, AmountCents: 2000, OriginalAmountMinor: 2340, OriginalCurrency: "USD", FXRate: 1.17, FXSource: "ezb",
		CategoryID: e.cats["Restaurant"], Parts: []domain.Part{{ParticipantID: e.ids["Anna"]}, {ParticipantID: e.ids["Ben"]}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.st.CreateExpense(ctx, e.ids["Ben"], store.ExpenseInput{Title: "Rückzahlung", Date: usd, PaidBy: e.ids["Ben"],
		AmountCents: 500, IsReimbursement: true, Parts: []domain.Part{{ParticipantID: e.ids["Anna"]}}}); err != nil {
		t.Fatal(err)
	}
	// balances: Anna paid 5000, shares 2500, received a reimbursement of 500 → +2000
	sc, text, isErr := e.call("balances", nil)
	if isErr {
		t.Fatal(text)
	}
	got := map[string]float64{}
	status := map[string]string{}
	for _, s := range sc["balances"].([]any) {
		m := s.(map[string]any)
		got[m["person"].(string)] = m["balance_cents"].(float64)
		status[m["person"].(string)] = m["status"].(string)
	}
	if got["Anna"] != 2000 || got["Ben"] != -3000 || got["Cleo"] != 1000 {
		t.Errorf("balances = %v", got)
	}
	if status["Anna"] != "is owed money" || status["Ben"] != "owes money" {
		t.Errorf("status = %v", status)
	}
	if !strings.Contains(text, `"balance":"-30.00"`) || !strings.Contains(text, `"from":"Ben"`) || !strings.Contains(text, `"settlements":[`) {
		t.Errorf("balances text: %s", text)
	}

	// search_expenses
	sc, _, isErr = e.call("search_expenses", map[string]any{"person": "anna", "from": "2026-09-01", "detail": "full"})
	if isErr || sc["matches"].(float64) != 2 || sc["total_cents"].(float64) != 3000 || sc["total"] != "30.00" {
		t.Errorf("search person: %v", sc)
	}
	if a := sc["person_share"].(map[string]any); a["amount_cents"].(float64) != 1500 || a["amount"] != "15.00" || a["person"] != "Anna" {
		t.Errorf("person_share = %v", a)
	}
	first := sc["expenses"].([]any)[0].(map[string]any)
	if first["title"] != "Diner NYC" || first["original"] != "23.40 USD" || first["fx_rate"].(float64) != 1.17 || first["fx_source"] != "ezb" ||
		first["split"] != "equal" || first["paid_by"] != "Anna" || first["category"] != "Restaurant" || len(first["shares"].([]any)) != 2 {
		t.Errorf("foreign currency: %v", first)
	}
	if sh := first["shares"].([]any)[0].(map[string]any); sh["amount"] != "10.00" || sh["amount_cents"].(float64) != 1000 {
		t.Errorf("share = %v", sh)
	}
	sc, _, _ = e.call("search_expenses", map[string]any{"reimbursements": "only"})
	if r := sc["expenses"].([]any)[0].(map[string]any); sc["matches"].(float64) != 1 || r["recipient"] != "Anna" || r["reimbursement"] != true {
		t.Errorf("only reimbursements: %v", sc)
	}
	sc, _, _ = e.call("search_expenses", map[string]any{"reimbursements": "include"})
	if sc["matches"].(float64) != 5 {
		t.Errorf("include reimbursements: %v", sc)
	}
	sc, _, _ = e.call("search_expenses", map[string]any{"category": "lebensmittel", "limit": 1})
	if sc["matches"].(float64) != 2 || sc["shown"].(float64) != 1 || sc["truncated"] != true || sc["total_cents"].(float64) != 4000 {
		t.Errorf("category+limit: %v", sc)
	}
	_, text, _ = e.call("search_expenses", map[string]any{"text": "wein"})
	if !strings.Contains(text, "Pizza & Wein") {
		t.Errorf("text without &: %s", text)
	}
	for _, args := range []map[string]any{
		{"person": "Dora"}, {"category": "Yacht"}, {"from": "yesterday"}, {"from": "2026-09-02", "to": "2026-09-01"},
		{"limit": 1000}, {"reimbursements": "whatever"}, {"unknown": 1}, {"limit": "ten"}, {"von": "2026-09-01"},
		{"sort": "random"}, {"detail": "all"}, {"min_amount": -1}, {"max_amount": 0}, {"min_amount": 20, "max_amount": 10},
		{"text": 5}, {"paid_by": "Dora"}, {"involved": "Dora"},
	} {
		if _, text, isErr := e.call("search_expenses", args); !isErr || text == "" || strings.Contains(text, "Internal error") {
			t.Errorf("%v: isError=%v %q", args, isErr, text)
		}
	}
	if _, text, _ := e.call("search_expenses", map[string]any{"person": "Dora"}); !strings.Contains(text, "Anna, Ben, Cleo") {
		t.Errorf("error without list of names: %s", text)
	}
	if _, text, _ := e.call("search_expenses", map[string]any{"from": "2026-09-02", "to": "2026-09-01"}); !strings.Contains(text, `"to" (2026-09-01) is before "from" (2026-09-02)`) {
		t.Errorf("range error: %s", text)
	}

	// statistics
	sc, _, isErr = e.call("statistics", map[string]any{"group_by": "category", "share_of": "Ben"})
	if isErr {
		t.Fatal(sc)
	}
	rows := sc["rows"].([]any)
	if len(rows) != 2 || rows[0].(map[string]any)["category"] != "Restaurant" || rows[0].(map[string]any)["amount_cents"].(float64) != 3000 ||
		sc["total_cents"].(float64) != 4500 || sc["total"] != "45.00" || !strings.Contains(sc["perspective"].(string), "Ben") {
		t.Errorf("statistics Ben: %v", sc)
	}
	sc, _, _ = e.call("statistics", map[string]any{"group_by": "person"})
	if r := sc["rows"].([]any)[0].(map[string]any); r["person"] != "Ben" || r["paid_cents"].(float64) != 1000 || r["paid"] != "10.00" || sc["total_cents"].(float64) != 10000 {
		t.Errorf("statistics person: %v", sc)
	}
	sc, _, _ = e.call("statistics", map[string]any{"group_by": "month", "from": "2026-09-01", "to": "30.09.2026"})
	if r := sc["rows"].([]any); len(r) != 1 || r[0].(map[string]any)["month"] != "2026-09" || r[0].(map[string]any)["count"].(float64) != 3 ||
		sc["period"] != "2026-09-01 to 2026-09-30" {
		t.Errorf("statistics month: %v", sc)
	}
	sc, _, _ = e.call("statistics", map[string]any{"group_by": "category_month", "share_of": "anna"})
	if r := sc["rows"].([]any); len(r) != 3 || sc["period"] != "all time" || r[0].(map[string]any)["month"] == "" || r[0].(map[string]any)["category"] == "" {
		t.Errorf("statistics category_month: %v", sc)
	}
	for _, args := range []map[string]any{nil, {"group_by": "decade"}, {"group_by": "month", "person": "Anna"},
		{"group_by": "category", "compare": "previous_year"}, {"group_by": "month", "compare": "last_week"}, {"group_by": "month", "limit": 0.5}, {"group_by": "month", "share_of": "Dora"}} {
		if _, text, isErr := e.call("statistics", args); !isErr || strings.Contains(text, "Internal error") {
			t.Errorf("statistics %v: isError=%v %s", args, isErr, text)
		}
	}

	// schema
	sc, text, isErr = e.call("schema", nil)
	if isErr || sc != nil || !strings.Contains(text, "deleted_at IS NULL") || !strings.Contains(text, "CREATE TABLE expenses") ||
		!strings.Contains(text, ": Anna") || strings.Contains(text, "CREATE TABLE ynab") {
		t.Errorf("schema: %s", text)
	}

	// sql_query
	sc, _, isErr = e.call("sql_query", map[string]any{"query": "SELECT name, archived_at FROM participants ORDER BY name"})
	if isErr || sc["row_count"].(float64) != 3 || sc["rows"].([]any)[0].([]any)[0] != "Anna" || sc["columns"].([]any)[1] != "archived_at" || sc["truncated"] != false {
		t.Errorf("sql: %v", sc)
	}
	sc, _, _ = e.call("sql_query", map[string]any{"query": "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 600) SELECT i FROM n"})
	if note, _ := sc["note"].(string); sc["truncated"] != true || sc["row_count"].(float64) != store.SQLMaxRows || !strings.Contains(note, "more than") {
		t.Errorf("sql truncated: %v %v", sc["row_count"], sc["note"])
	}
	for _, q := range []string{"SELECT token FROM ynab_config", "DELETE FROM expenses", "SELECT 1; DELETE FROM expenses", "SELECT * FROM doesnotexist", ""} {
		if _, text, isErr := e.call("sql_query", map[string]any{"query": q}); !isErr || strings.Contains(text, "Internal error") {
			t.Errorf("sql %q: isError=%v %s", q, isErr, text)
		}
	}
	if es, _ := e.st.ListExpenses(ctx, store.ExpenseFilter{}); len(es) != 5 {
		t.Errorf("expenses after sql_query: %d", len(es))
	}
	if !strings.Contains(e.logs.String(), "tool=sql_query") {
		t.Error("tool call not logged")
	}
}

func TestSearchExpensesOptions(t *testing.T) {
	e := newEnv(t)
	e.expense("Rewe", 3000, "2026-08-15", "Anna", "Lebensmittel", "Anna", "Ben", "Cleo")
	e.expense("Edeka", 1000, "2026-09-01", "Ben", "Lebensmittel", "Anna", "Ben")
	e.expense("Kino", 2400, "2026-09-05", "Cleo", "", "Ben", "Cleo")
	e.expense("Lidl", 1999, "2026-09-07", "Cleo", "Lebensmittel", "Cleo")
	titles := func(args map[string]any) string {
		t.Helper()
		sc, text, isErr := e.call("search_expenses", args)
		if isErr {
			t.Fatalf("%v: %s", args, text)
		}
		var out []string
		for _, x := range sc["expenses"].([]any) {
			out = append(out, x.(map[string]any)["title"].(string))
		}
		return strings.Join(out, ",")
	}
	for _, c := range []struct {
		args map[string]any
		want string
	}{
		{map[string]any{}, "Lidl,Kino,Edeka,Rewe"},
		{map[string]any{"sort": "date_asc"}, "Rewe,Edeka,Kino,Lidl"},
		{map[string]any{"sort": "amount_desc"}, "Rewe,Kino,Lidl,Edeka"},
		{map[string]any{"sort": "amount_asc"}, "Edeka,Lidl,Kino,Rewe"},
		{map[string]any{"min_amount": 19.99, "max_amount": 24}, "Lidl,Kino"},
		{map[string]any{"min_amount": 20}, "Kino,Rewe"},
		{map[string]any{"text": []string{"rewe", "LIDL"}}, "Lidl,Rewe"},
		{map[string]any{"text": "edeka"}, "Edeka"},
		{map[string]any{"paid_by": "Cleo"}, "Lidl,Kino"},
		{map[string]any{"involved": "Ben"}, "Kino,Edeka,Rewe"},
		{map[string]any{"person": "Ben"}, "Kino,Edeka,Rewe"},
		{map[string]any{"paid_by": "Cleo", "involved": "Ben"}, "Kino"},
	} {
		if got := titles(c.args); got != c.want {
			t.Errorf("%v = %s, want %s", c.args, got, c.want)
		}
	}

	// involved sums up the person's shares like person.
	sc, _, _ := e.call("search_expenses", map[string]any{"involved": "Ben"})
	if ps := sc["person_share"].(map[string]any); ps["person"] != "Ben" || ps["amount_cents"].(float64) != 1000+500+1200 {
		t.Errorf("person_share involved = %v", ps)
	}
	// compact (default) leaves out split, shares and notes, full includes them.
	_, text, _ := e.call("search_expenses", map[string]any{"text": "Kino"})
	if strings.Contains(text, `"shares"`) || strings.Contains(text, `"split"`) || !strings.Contains(text, `"amount":"24.00"`) {
		t.Errorf("compact: %s", text)
	}
	_, text, _ = e.call("search_expenses", map[string]any{"text": "Kino", "detail": "full"})
	if !strings.Contains(text, `"shares"`) || !strings.Contains(text, `"split":"equal"`) {
		t.Errorf("full: %s", text)
	}
}

func TestStatisticsOptions(t *testing.T) {
	e := newEnv(t)
	e.at("2026-04-15")
	e.expense("Rewe", 3000, "2025-03-10", "Anna", "Lebensmittel", "Anna", "Ben")
	e.expense("Pizza", 1000, "2025-05-02", "Anna", "Restaurant", "Anna")
	e.expense("Rewe", 4000, "2026-01-05", "Anna", "Lebensmittel", "Anna", "Ben")
	e.expense("REWE", 2000, "2026-03-20", "Ben", "Lebensmittel", "Anna", "Ben")
	e.expense("Kino", 1500, "2026-03-21", "Ben", "", "Ben")
	rows := func(args map[string]any) ([]map[string]any, map[string]any) {
		t.Helper()
		sc, text, isErr := e.call("statistics", args)
		if isErr {
			t.Fatalf("%v: %s", args, text)
		}
		var out []map[string]any
		for _, r := range sc["rows"].([]any) {
			out = append(out, r.(map[string]any))
		}
		return out, sc
	}

	// Months without expenses appear with 0, from from (or the first row) to today.
	r, _ := rows(map[string]any{"group_by": "month", "from": "2026-01-01"})
	if len(r) != 4 || r[0]["month"] != "2026-01" || r[1]["month"] != "2026-02" || r[1]["amount_cents"].(float64) != 0 || r[2]["amount_cents"].(float64) != 3500 ||
		r[3]["month"] != "2026-04" || r[3]["amount_cents"].(float64) != 0 {
		t.Errorf("months: %v", r)
	}
	if r, _ = rows(map[string]any{"group_by": "month", "from": "2026-01-01", "text": "nothing like this"}); len(r) != 4 {
		t.Errorf("months without matches: %v", r)
	}
	if r, _ = rows(map[string]any{"group_by": "month", "from": "2026-01-01", "to": "2026-12-31"}); len(r) != 4 {
		t.Errorf("months beyond today: %v", r)
	}
	r, _ = rows(map[string]any{"group_by": "year"})
	if len(r) != 2 || r[0]["year"] != "2025" || r[1]["amount_cents"].(float64) != 7500 {
		t.Errorf("years: %v", r)
	}
	r, _ = rows(map[string]any{"group_by": "week", "from": "2026-03-16", "to": "2026-03-29"})
	if len(r) != 2 || r[0]["week"] != "2026-W12" || r[0]["count"].(float64) != 2 || r[1]["week"] != "2026-W13" || r[1]["amount_cents"].(float64) != 0 {
		t.Errorf("weeks: %v", r)
	}
	// title groups case-insensitively, text filters.
	r, _ = rows(map[string]any{"group_by": "title", "from": "2026-01-01"})
	if len(r) != 2 || !strings.EqualFold(r[0]["title"].(string), "rewe") || r[0]["count"].(float64) != 2 || r[0]["amount_cents"].(float64) != 6000 {
		t.Errorf("titles: %v", r)
	}
	r, _ = rows(map[string]any{"group_by": "category", "text": []string{"kino", "pizza"}})
	if len(r) != 2 {
		t.Errorf("text: %v", r)
	}
	// limit truncates the rows, but total covers all of them.
	r, sc := rows(map[string]any{"group_by": "month", "limit": 2})
	if len(r) != 2 || sc["truncated"] != true || sc["rows_total"].(float64) != 14 || sc["total_cents"].(float64) != 11500 {
		t.Errorf("limit: %d rows, %v %v %v", len(r), sc["truncated"], sc["rows_total"], sc["total_cents"])
	}

	// compare=previous_year by month: each month against the same month a year earlier.
	r, sc = rows(map[string]any{"group_by": "month", "from": "2026-01-01", "to": "2026-03-31", "compare": "previous_year"})
	if len(r) != 3 || r[2]["month"] != "2026-03" || r[2]["previous_cents"].(float64) != 3000 || r[2]["change_cents"].(float64) != 500 ||
		r[2]["change_percent"].(float64) != 16.7 || r[0]["previous_cents"].(float64) != 0 || r[0]["change_percent"] != nil ||
		sc["previous_total_cents"].(float64) != 3000 {
		t.Errorf("compare months: %v %v", r, sc)
	}
	// By category: groups only present a year earlier appear with 0.
	r, sc = rows(map[string]any{"group_by": "category", "from": "2026-01-01", "to": "2026-12-31", "compare": "previous_year"})
	got := map[string][2]float64{}
	for _, x := range r {
		got[x["category"].(string)] = [2]float64{x["amount_cents"].(float64), x["previous_cents"].(float64)}
	}
	if len(r) != 3 || got["Lebensmittel"] != [2]float64{6000, 3000} || got["No category"] != [2]float64{1500, 0} || got["Restaurant"] != [2]float64{0, 1000} ||
		sc["previous_period"] != "2025-01-01 to 2025-12-31" {
		t.Errorf("compare categories: %v %v", got, sc["previous_period"])
	}
}

func TestBalanceHistory(t *testing.T) {
	e := newEnv(t)
	e.expense("Rewe", 3000, "2026-01-10", "Anna", "Lebensmittel", "Anna", "Ben", "Cleo")
	e.expense("Kino", 2000, "2026-03-05", "Ben", "", "Anna", "Ben")
	d, _ := domain.ParseDate("2026-03-20")
	if _, err := e.st.CreateExpense(context.Background(), e.ids["Ben"], store.ExpenseInput{Title: "Rückzahlung", Date: d, PaidBy: e.ids["Ben"],
		AmountCents: 1000, IsReimbursement: true, Parts: []domain.Part{{ParticipantID: e.ids["Anna"]}}}); err != nil {
		t.Fatal(err)
	}
	history := func(args map[string]any) []map[string]float64 {
		t.Helper()
		sc, text, isErr := e.call("balance_history", args)
		if isErr {
			t.Fatalf("%v: %s", args, text)
		}
		var out []map[string]float64
		for _, r := range sc["rows"].([]any) {
			m := map[string]float64{}
			for _, b := range r.(map[string]any)["balances"].([]any) {
				b := b.(map[string]any)
				m[b["person"].(string)] = b["balance_cents"].(float64)
			}
			out = append(out, m)
		}
		return out
	}
	e.at("2026-03-25")
	rows := history(map[string]any{"from": "2025-12-01", "to": "2026-03-31"})
	want := []map[string]float64{
		{"Anna": 0, "Ben": 0, "Cleo": 0},
		{"Anna": 2000, "Ben": -1000, "Cleo": -1000},
		{"Anna": 2000, "Ben": -1000, "Cleo": -1000},
		{"Anna": 0, "Ben": 1000, "Cleo": -1000},
	}
	if fmt.Sprint(rows) != fmt.Sprint(want) {
		t.Errorf("months = %v", rows)
	}
	// A later first period starts with the opening balance; person narrows down.
	rows = history(map[string]any{"interval": "year", "from": "2026-02-01", "to": "2026-12-31", "person": "ben"})
	if len(rows) != 1 || len(rows[0]) != 1 || rows[0]["Ben"] != 1000 {
		t.Errorf("year Ben = %v", rows)
	}
	sc, _, _ := e.call("balance_history", map[string]any{"interval": "week", "from": "2026-03-02", "to": "2026-03-15"})
	if r := sc["rows"].([]any); len(r) != 2 || r[0].(map[string]any)["week"] != "2026-W10" {
		t.Errorf("weeks = %v", r)
	}
	// Without to, the last row includes expenses dated later and equals balances;
	// with to, later expenses are left out.
	e.expense("Miete", 3000, "2026-05-01", "Cleo", "", "Anna", "Ben", "Cleo")
	rows = history(nil)
	if len(rows) != 5 || rows[4]["Cleo"] != -1000+2000 || rows[3]["Cleo"] != -1000 {
		t.Errorf("until the last expense = %v", rows)
	}
	if rows = history(map[string]any{"to": "2026-04-30"}); len(rows) != 4 || rows[3]["Cleo"] != -1000 {
		t.Errorf("until April = %v", rows)
	}
	for _, args := range []map[string]any{{"interval": "day"}, {"person": "Dora"}, {"interval": "week", "from": "2000-01-01", "to": "2026-01-01"},
		{"interval": "week", "from": "1900-01-01"}} {
		if _, text, isErr := e.call("balance_history", args); !isErr || strings.Contains(text, "Internal error") {
			t.Errorf("%v: isError=%v %s", args, isErr, text)
		}
	}
}

func TestActivity(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	e.expense("Rewe", 3000, "2026-01-10", "Anna", "Lebensmittel", "Anna", "Ben")
	e.expense("Kino", 2000, "2026-03-05", "Ben", "", "Anna", "Ben")
	es, _ := e.st.ListExpenses(ctx, store.ExpenseFilter{Text: "Kino"})
	kino := es[0]
	in := kino.ExpenseInput
	in.Title, in.AmountCents = "Kino & Popcorn", 2500
	if err := e.st.UpdateExpense(ctx, e.ids["Cleo"], kino.ID, in); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddActivity(ctx, 0, store.ActionSettingsUpdated, 0, store.ActivityDetails{Text: "Kategorie angelegt"}); err != nil {
		t.Fatal(err)
	}
	entries := func(args map[string]any) ([]map[string]any, map[string]any) {
		t.Helper()
		sc, text, isErr := e.call("activity", args)
		if isErr {
			t.Fatalf("%v: %s", args, text)
		}
		var out []map[string]any
		for _, x := range sc["entries"].([]any) {
			out = append(out, x.(map[string]any))
		}
		return out, sc
	}
	all, _ := entries(nil)
	if len(all) != 4 || all[0]["actor"] != "system" || all[0]["text"] != "Kategorie angelegt" || all[1]["actor"] != "Cleo" ||
		all[1]["action"] != "expense_updated" || all[1]["title"] != "Kino & Popcorn" || all[1]["changes"] == nil ||
		all[3]["amount"] != "30.00" || all[3]["expense_id"] == nil {
		t.Errorf("all = %v", all)
	}
	if got, _ := entries(map[string]any{"person": "cleo"}); len(got) != 1 || got[0]["action"] != "expense_updated" {
		t.Errorf("person = %v", got)
	}
	if got, _ := entries(map[string]any{"action": "expense_created"}); len(got) != 2 {
		t.Errorf("action = %v", got)
	}
	if got, _ := entries(map[string]any{"expense_id": kino.ID}); len(got) != 2 {
		t.Errorf("expense_id = %v", got)
	}
	got, sc := entries(map[string]any{"limit": 3})
	if len(got) != 3 || sc["more"] != true || !strings.Contains(sc["note"].(string), "before_id") {
		t.Errorf("limit = %v", sc)
	}
	if got, _ = entries(map[string]any{"before_id": got[2]["id"]}); len(got) != 1 {
		t.Errorf("before_id = %v", got)
	}
	// The log was written just now (real clock): today is in, yesterday is not.
	today := time.Now().In(time.Local).Format(domain.DateLayout)
	yesterday := time.Now().In(time.Local).AddDate(0, 0, -1).Format(domain.DateLayout)
	if got, _ := entries(map[string]any{"from": today, "to": today}); len(got) != 4 {
		t.Errorf("today = %d", len(got))
	}
	if got, _ := entries(map[string]any{"to": yesterday}); len(got) != 0 {
		t.Errorf("until yesterday = %d", len(got))
	}
	for _, args := range []map[string]any{{"person": "Dora"}, {"limit": 0.5}, {"from": "gestern"}, {"expense_id": -1}} {
		if _, text, isErr := e.call("activity", args); !isErr || strings.Contains(text, "Internal error") {
			t.Errorf("%v: isError=%v %s", args, isErr, text)
		}
	}
}

func TestDataOverviewInInstructions(t *testing.T) {
	e := newEnv(t)
	instructions := func() string {
		t.Helper()
		return e.modern("server/discover", nil, nil).result(t)["instructions"].(string)
	}
	if got := instructions(); !strings.Contains(got, "Data overview: there are no expenses yet.") {
		t.Errorf("empty: %s", got)
	}
	e.expense("Rewe", 3000, "2025-03-10", "Anna", "Lebensmittel", "Anna", "Ben")
	e.expense("Kino", 2000, "2026-09-05", "Ben", "", "Anna", "Ben")
	e.expense("Bahn", 2000, "2026-09-06", "Ben", "", "Ben")
	e.expense("Pizza", 2000, "2026-09-07", "Ben", "Restaurant", "Ben")
	d, _ := domain.ParseDate("2026-09-30")
	if _, err := e.st.CreateExpense(context.Background(), e.ids["Ben"], store.ExpenseInput{Title: "Rückzahlung", Date: d, PaidBy: e.ids["Ben"],
		AmountCents: 1000, IsReimbursement: true, Parts: []domain.Part{{ParticipantID: e.ids["Anna"]}}}); err != nil {
		t.Fatal(err)
	}
	got := instructions()
	for _, want := range []string{
		"4 expenses and 1 reimbursements dated 2025-03-10 to 2026-09-30.",
		"2 of the expenses (50.0%) have no category.",
		"Values of activity.action: expense_created.",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in %s", want, got)
		}
	}
	init := e.send("POST", "/mcp/"+testSecret, "", nil,
		`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`).result(t)
	if !strings.Contains(init["instructions"].(string), "4 expenses") {
		t.Errorf("initialize: %s", init["instructions"])
	}
}

// Edge cases of compare=previous_year.
func TestStatisticsCompareEdgeCases(t *testing.T) {
	e := newEnv(t)
	e.at("2026-10-02")
	e.expense("Rewe", 7000, "2025-03-10", "Anna", "Lebensmittel", "Anna")
	e.expense("Hotel", 50000, "2025-03-12", "Anna", "", "Anna")
	e.expense("Rewe", 10000, "2026-03-10", "Anna", "Lebensmittel", "Anna")
	e.expense("Miete", 90000, "2023-03-01", "Anna", "", "Anna")
	e.expense("Bäckerei Groß", 300, "2026-05-02", "Anna", "", "Anna")
	e.expense("BÄCKEREI GROSS", 200, "2025-05-02", "Anna", "", "Anna")
	e.expense("Glühwein", 800, "2020-12-30", "Anna", "", "Anna")
	call := func(args map[string]any) ([]map[string]any, map[string]any) {
		t.Helper()
		sc, text, isErr := e.call("statistics", args)
		if isErr {
			t.Fatalf("%v: %s", args, text)
		}
		var out []map[string]any
		for _, r := range sc["rows"].([]any) {
			out = append(out, r.(map[string]any))
		}
		return out, sc
	}

	// category_month: a category that only had expenses a year earlier appears with 0.
	r, sc := call(map[string]any{"group_by": "category_month", "from": "2026-03-01", "to": "2026-03-31", "compare": "previous_year"})
	if len(r) != 2 || r[1]["category"] != "No category" || r[1]["amount_cents"].(float64) != 0 || r[1]["previous_cents"].(float64) != 50000 ||
		sc["previous_total_cents"].(float64) != 57000 {
		t.Errorf("category_month: %v %v", r, sc["previous_total_cents"])
	}
	// 29 February: the previous range ends on 28 February, not 1 March.
	if _, sc = call(map[string]any{"group_by": "category", "from": "2024-02-01", "to": "2024-02-29", "compare": "previous_year"}); sc["previous_total_cents"].(float64) != 0 ||
		sc["previous_period"] != "2023-02-01 to 2023-02-28" {
		t.Errorf("leap day: %v %v", sc["previous_total_cents"], sc["previous_period"])
	}
	// Titles are matched like Stats groups them (ß = ss).
	if r, _ = call(map[string]any{"group_by": "title", "from": "2026-05-01", "to": "2026-05-31", "compare": "previous_year"}); len(r) != 1 || r[0]["previous_cents"].(float64) != 200 {
		t.Errorf("title ß: %v", r)
	}
	// Week 53 of 2020 is compared with week 52 of 2021.
	if r, _ = call(map[string]any{"group_by": "week", "from": "2021-12-20", "to": "2021-12-26", "compare": "previous_year"}); len(r) != 1 || r[0]["week"] != "2021-W51" {
		t.Errorf("week 51: %v", r)
	}
	if r, _ = call(map[string]any{"group_by": "week", "from": "2021-12-27", "to": "2022-01-02", "compare": "previous_year"}); len(r) != 1 || r[0]["week"] != "2021-W52" ||
		r[0]["previous_cents"].(float64) != 800 {
		t.Errorf("week 53 → 52: %v", r)
	}
	// A future from without to cannot be compared up to today.
	if _, text, isErr := e.call("statistics", map[string]any{"group_by": "category", "from": "2026-12-01", "compare": "previous_year"}); !isErr || !strings.Contains(text, "future") {
		t.Errorf("future from: %v %s", isErr, text)
	}
}
