package mcp

import (
	"bytes"
	"context"
	"encoding/json"
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
	e := &env{t: t, h: mux, st: st, logs: logs, ids: map[string]int64{}, cats: map[string]int64{}}
	ctx := context.Background()
	for _, n := range []string{"Anna", "Ben", "Cleo"} {
		if e.ids[n], err = st.CreateParticipant(ctx, n); err != nil {
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

// call calls a tool (legacy) and returns structuredContent, the text and isError.
func (e *env) call(name string, args map[string]any) (map[string]any, string, bool) {
	e.t.Helper()
	res := e.legacy("tools/call", map[string]any{"name": name, "arguments": args}).result(e.t)
	content := res["content"].([]any)[0].(map[string]any)
	sc, _ := res["structuredContent"].(map[string]any)
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
	if strings.Join(names, ",") != "balances,search_expenses,statistics,schema,sql_query" {
		t.Errorf("Tools = %v", names)
	}
	r = e.send("POST", "/mcp/"+testSecret, "", nil, `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	if r.status != 200 || len(r.result(t)["tools"].([]any)) != 5 {
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
	if res["resultType"] != "complete" || res["ttlMs"] == nil || len(res["tools"].([]any)) != 5 {
		t.Errorf("tools/list: %v", res)
	}
	res = e.modern("tools/call", map[string]any{"name": "balances", "arguments": map[string]any{}}, nil).result(t)
	if res["resultType"] != "complete" || res["isError"] != false || res["structuredContent"] == nil {
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
	id, err := e.st.CreateCategory(context.Background(), "None")
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
	sc, _, isErr = e.call("search_expenses", map[string]any{"person": "anna", "from": "2026-09-01"})
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
	for _, args := range []map[string]any{nil, {"group_by": "year"}, {"group_by": "month", "person": "Anna"}, {"group_by": "month", "share_of": "Dora"}} {
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
