package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"teilen/internal/config"
	"teilen/internal/domain"
	"teilen/internal/store"
	"teilen/internal/web"
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
	st, err := store.Open(filepath.Join(t.TempDir(), "teilen.db"))
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

// send schickt eine Anfrage. hdr: zusätzliche Header; remote "" = anthropic.
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
			e.t.Fatalf("Antwort kein JSON: %v: %s", err, r.raw)
		}
	}
	return r
}

// legacy schickt eine Legacy-Anfrage (Header MCP-Protocol-Version 2025-06-18).
func (e *env) legacy(method string, params any) reply {
	e.t.Helper()
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	return e.send("POST", "/mcp/"+testSecret, "", map[string]string{"MCP-Protocol-Version": "2025-06-18"}, string(b))
}

// modernReq baut eine moderne Anfrage mit passenden Headern.
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
		t.Fatalf("kein result (status %d): %s", r.status, r.raw)
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

// call ruft ein Tool (Legacy) und liefert structuredContent bzw. Text und isError.
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
		{"erlaubt", "POST", path, "", nil, 200},
		{"falsches Secret", "POST", "/mcp/falsch", "", nil, 404},
		{"Secret-Präfix", "POST", path[:len(path)-1], "", nil, 404},
		{"falsches Secret von fremder IP", "POST", "/mcp/falsch", "1.2.3.4:1", nil, 404},
		{"fremde IP", "POST", path, "1.2.3.4:1", nil, 403},
		{"XFF-Spoofing ohne Proxy", "POST", path, "1.2.3.4:1", map[string]string{"X-Forwarded-For": "160.79.104.10"}, 403},
		{"X-Real-IP-Spoofing ohne Proxy", "POST", path, "1.2.3.4:1", map[string]string{"X-Real-IP": "160.79.104.10"}, 403},
		{"über Proxy erlaubt", "POST", path, "10.0.0.1:9", map[string]string{"X-Forwarded-For": "160.79.104.10"}, 200},
		{"über Proxy, vorangestellte Fälschung", "POST", path, "10.0.0.1:9", map[string]string{"X-Forwarded-For": "160.79.104.10, 1.2.3.4"}, 403},
		{"über Proxy ohne Header", "POST", path, "10.0.0.1:9", nil, 403},
		{"über Proxy mit X-Real-IP", "POST", path, "10.0.0.1:9", map[string]string{"X-Real-IP": "160.79.104.10"}, 200},
		{"Origin gesetzt", "POST", path, "", map[string]string{"Origin": "https://evil.example"}, 403},
		{"Origin null", "POST", path, "", map[string]string{"Origin": "null"}, 403},
		{"GET", "GET", path, "", nil, 405},
		{"DELETE", "DELETE", path, "", nil, 405},
		{"falscher Content-Type", "POST", path, "", map[string]string{"Content-Type": "text/plain"}, 415},
	}
	for _, tt := range tests {
		r := e.send(tt.method, tt.path, tt.remote, tt.hdr, ping)
		if r.status != tt.want {
			t.Errorf("%s: status %d, want %d (%s)", tt.name, r.status, tt.want, r.raw)
		}
		if tt.want == 404 && strings.Contains(r.raw, "mcp") {
			t.Errorf("%s: 404 verrät etwas: %q", tt.name, r.raw)
		}
	}
	if r := e.send("GET", path, "", nil, ""); r.header.Get("Allow") != "POST" {
		t.Errorf("405 ohne Allow: %v", r.header)
	}
	// Das Secret taucht nirgends im Log auf, Zugriffe aber schon.
	logs := e.logs.String()
	if strings.Contains(logs, testSecret) || strings.Contains(logs, testSecret[:10]) {
		t.Errorf("Secret im Log:\n%s", logs)
	}
	for _, want := range []string{"methode=ping", "ip=160.79.104.10", "falsches Secret", "IP nicht erlaubt", "Origin"} {
		if !strings.Contains(logs, want) {
			t.Errorf("Log ohne %q:\n%s", want, logs)
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
	// initialize ohne Versions-Header, gewünschte Version wird übernommen.
	b := `{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-ai","version":"0.1.0"}}}`
	r := e.send("POST", "/mcp/"+testSecret, "", nil, b)
	res := r.result(t)
	if res["protocolVersion"] != "2025-06-18" || r.header.Get("Mcp-Session-Id") != "" || r.header.Get("Content-Type") != "application/json" {
		t.Errorf("initialize: %d %v %v", r.status, res, r.header)
	}
	if tools := res["capabilities"].(map[string]any)["tools"]; tools == nil {
		t.Errorf("capabilities ohne tools: %v", res)
	}
	if res["serverInfo"].(map[string]any)["name"] != "teilen" || !strings.Contains(res["instructions"].(string), "Saldo") {
		t.Errorf("serverInfo/instructions: %v", res)
	}
	if _, ok := res["resultType"]; ok {
		t.Error("Legacy-Ergebnis mit resultType")
	}
	// Unbekannte Version → neueste Legacy-Version.
	b = `{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}`
	if v := e.send("POST", "/mcp/"+testSecret, "", nil, b).result(t)["protocolVersion"]; v != "2025-11-25" {
		t.Errorf("Aushandlung 2024-11-05 → %v", v)
	}
	// notifications/initialized → 202 ohne Body.
	r = e.send("POST", "/mcp/"+testSecret, "", map[string]string{"MCP-Protocol-Version": "2025-06-18"},
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	if r.status != 202 || r.raw != "" {
		t.Errorf("initialized: %d %q", r.status, r.raw)
	}
	// tools/list mit und ohne Header (ohne = 2025-03-26).
	res = e.legacy("tools/list", nil).result(t)
	tools := res["tools"].([]any)
	var names []string
	for _, tl := range tools {
		m := tl.(map[string]any)
		names = append(names, m["name"].(string))
		if m["description"] == "" || m["inputSchema"].(map[string]any)["type"] != "object" || m["annotations"].(map[string]any)["readOnlyHint"] != true {
			t.Errorf("Tool unvollständig: %v", m)
		}
	}
	if strings.Join(names, ",") != "salden,ausgaben_suchen,statistik,schema,sql_abfrage" {
		t.Errorf("Tools = %v", names)
	}
	r = e.send("POST", "/mcp/"+testSecret, "", nil, `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	if r.status != 200 || len(r.result(t)["tools"].([]any)) != 5 {
		t.Errorf("tools/list ohne Header: %d %s", r.status, r.raw)
	}
	// Nicht unterstützte Version im Header → 400 mit Liste.
	r = e.send("POST", "/mcp/"+testSecret, "", map[string]string{"MCP-Protocol-Version": "1999-01-01"}, `{"jsonrpc":"2.0","id":3,"method":"tools/list"}`)
	if r.status != 400 || r.errCode() != codeUnsupportedVersion {
		t.Errorf("unbekannte Version: %d %s", r.status, r.raw)
	}
	// ping, unbekannte Methode.
	if r = e.legacy("ping", nil); r.status != 200 || len(r.result(t)) != 0 {
		t.Errorf("ping: %s", r.raw)
	}
	if r = e.legacy("resources/list", nil); r.errCode() != codeMethodNotFound {
		t.Errorf("unbekannte Methode: %d %s", r.status, r.raw)
	}
	// Unbekanntes Tool ist ein Protokollfehler.
	if r = e.legacy("tools/call", map[string]any{"name": "gibtsnicht"}); r.errCode() != codeInvalidParams {
		t.Errorf("unbekanntes Tool: %s", r.raw)
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
	if res["_meta"].(map[string]any)["io.modelcontextprotocol/serverInfo"].(map[string]any)["name"] != "teilen" {
		t.Errorf("serverInfo fehlt: %v", res)
	}
	res = e.modern("tools/list", nil, nil).result(t)
	if res["resultType"] != "complete" || res["ttlMs"] == nil || len(res["tools"].([]any)) != 5 {
		t.Errorf("tools/list: %v", res)
	}
	res = e.modern("tools/call", map[string]any{"name": "salden", "arguments": map[string]any{}}, nil).result(t)
	if res["resultType"] != "complete" || res["isError"] != false || res["structuredContent"] == nil {
		t.Errorf("tools/call: %v", res)
	}
	// Mcp-Name im Base64-Format.
	r = e.modern("tools/call", map[string]any{"name": "salden"}, map[string]string{"Mcp-Name": "=?base64?c2FsZGVu?="})
	if r.status != 200 || r.result(t)["isError"] != false {
		t.Errorf("Base64-Mcp-Name: %d %s", r.status, r.raw)
	}

	bad := []struct {
		name   string
		method string
		params map[string]any
		hdr    map[string]string
		status int
		code   float64
	}{
		{"Versions-Header fehlt", "tools/list", nil, map[string]string{"MCP-Protocol-Version": ""}, 400, codeHeaderMismatch},
		{"Versions-Header falsch", "tools/list", nil, map[string]string{"MCP-Protocol-Version": "2025-11-25"}, 400, codeHeaderMismatch},
		{"Mcp-Method fehlt", "tools/list", nil, map[string]string{"Mcp-Method": ""}, 400, codeHeaderMismatch},
		{"Mcp-Method falsch", "tools/list", nil, map[string]string{"Mcp-Method": "tools/call"}, 400, codeHeaderMismatch},
		{"Mcp-Name fehlt", "tools/call", map[string]any{"name": "salden"}, map[string]string{"Mcp-Name": ""}, 400, codeHeaderMismatch},
		{"Mcp-Name falsch", "tools/call", map[string]any{"name": "salden"}, map[string]string{"Mcp-Name": "schema"}, 400, codeHeaderMismatch},
		{"Mcp-Name Base64 falsch", "tools/call", map[string]any{"name": "salden"}, map[string]string{"Mcp-Name": "=?base64?c2NoZW1h?="}, 400, codeHeaderMismatch},
		{"Mcp-Name Base64 kaputt", "tools/call", map[string]any{"name": "salden"}, map[string]string{"Mcp-Name": "=?base64?***?="}, 400, codeHeaderMismatch},
		{"unbekannte Methode", "resources/list", nil, nil, 404, codeMethodNotFound},
		{"initialize modern", "initialize", nil, nil, 404, codeMethodNotFound},
		{"unbekanntes Tool", "tools/call", map[string]any{"name": "nix"}, nil, 200, codeInvalidParams},
	}
	for _, tt := range bad {
		r := e.modern(tt.method, tt.params, tt.hdr)
		if r.status != tt.status || r.errCode() != tt.code || r.body["id"] != "a-1" {
			t.Errorf("%s: %d %s; want %d/%v", tt.name, r.status, r.raw, tt.status, tt.code)
		}
	}

	// Nicht unterstützte moderne Version: 400 mit supported/requested.
	meta := map[string]any{"io.modelcontextprotocol/protocolVersion": "2099-01-01", "io.modelcontextprotocol/clientCapabilities": map[string]any{}}
	r = e.modern("tools/list", map[string]any{"_meta": meta}, map[string]string{"MCP-Protocol-Version": "2099-01-01"})
	if r.status != 400 || r.errCode() != codeUnsupportedVersion {
		t.Fatalf("2099: %d %s", r.status, r.raw)
	}
	data := r.body["error"].(map[string]any)["data"].(map[string]any)
	if data["requested"] != "2099-01-01" || data["supported"].([]any)[0] != modern {
		t.Errorf("data = %v", data)
	}
	// Moderner Header, aber kein _meta im Body.
	r = e.send("POST", "/mcp/"+testSecret, "", map[string]string{"MCP-Protocol-Version": modern, "Mcp-Method": "tools/list"},
		`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	if r.status != 400 || r.errCode() != codeHeaderMismatch {
		t.Errorf("ohne _meta: %d %s", r.status, r.raw)
	}
	// Notification → 202.
	r = e.send("POST", "/mcp/"+testSecret, "", map[string]string{"MCP-Protocol-Version": modern},
		`{"jsonrpc":"2.0","method":"notifications/irgendwas","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}`)
	if r.status != 202 || r.raw != "" {
		t.Errorf("Notification: %d %q", r.status, r.raw)
	}
}

func TestMalformed(t *testing.T) {
	e := newEnv(t)
	tests := []struct {
		body   string
		status int
		code   float64
	}{
		{`{kaputt`, 400, codeParseError},
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
		t.Errorf("zu groß: %d", r.status)
	}
}

func TestAusgabenSuchenUmlaute(t *testing.T) {
	e := newEnv(t)
	e.expense("Bäckerei", 300, "2026-09-01", "Anna", "Lebensmittel", "Anna", "Ben")
	e.expense("ÖLWECHSEL", 9000, "2026-09-02", "Ben", "", "Anna", "Ben")
	for text, want := range map[string]string{"BÄCKEREI": "Bäckerei", "bäcker": "Bäckerei", "ölwechsel": "ÖLWECHSEL", "Ölwechsel": "ÖLWECHSEL"} {
		sc, msg, isErr := e.call("ausgaben_suchen", map[string]any{"text": text})
		if isErr || sc["treffer"].(float64) != 1 || sc["ausgaben"].([]any)[0].(map[string]any)["titel"] != want {
			t.Errorf("text %q: %s", text, msg)
		}
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
	// Salden: Anna bezahlt 5000, Anteile 2500, Rückzahlung erhalten 500 → +2000
	sc, text, isErr := e.call("salden", nil)
	if isErr {
		t.Fatal(text)
	}
	got := map[string]float64{}
	for _, s := range sc["salden"].([]any) {
		m := s.(map[string]any)
		got[m["person"].(string)] = m["saldo_cent"].(float64)
	}
	if got["Anna"] != 2000 || got["Ben"] != -3000 || got["Cleo"] != 1000 {
		t.Errorf("salden = %v", got)
	}
	if !strings.Contains(text, `"saldo":"-30,00"`) || !strings.Contains(text, `"von":"Ben"`) {
		t.Errorf("salden-Text: %s", text)
	}

	// ausgaben_suchen
	sc, _, isErr = e.call("ausgaben_suchen", map[string]any{"person": "anna", "von": "2026-09-01"})
	if isErr || sc["treffer"].(float64) != 2 || sc["summe_cent"].(float64) != 3000 {
		t.Errorf("suche person: %v", sc)
	}
	if a := sc["anteil_person"].(map[string]any); a["summe_cent"].(float64) != 1500 || a["summe"] != "15,00" {
		t.Errorf("anteil_person = %v", a)
	}
	first := sc["ausgaben"].([]any)[0].(map[string]any)
	if first["titel"] != "Diner NYC" || first["original"] != "23,40 USD" || first["kurs"].(float64) != 1.17 || len(first["anteile"].([]any)) != 2 {
		t.Errorf("Fremdwährung: %v", first)
	}
	sc, _, _ = e.call("ausgaben_suchen", map[string]any{"rueckzahlungen": "nur"})
	if sc["treffer"].(float64) != 1 || sc["ausgaben"].([]any)[0].(map[string]any)["an"] != "Anna" {
		t.Errorf("nur Rückzahlungen: %v", sc)
	}
	sc, _, _ = e.call("ausgaben_suchen", map[string]any{"kategorie": "lebensmittel", "limit": 1})
	if sc["treffer"].(float64) != 2 || sc["angezeigt"].(float64) != 1 || sc["gekuerzt"] != true || sc["summe_cent"].(float64) != 4000 {
		t.Errorf("kategorie+limit: %v", sc)
	}
	_, text, _ = e.call("ausgaben_suchen", map[string]any{"text": "wein"})
	if !strings.Contains(text, "Pizza & Wein") {
		t.Errorf("Text ohne & : %s", text)
	}
	for _, args := range []map[string]any{
		{"person": "Dora"}, {"kategorie": "Yacht"}, {"von": "gestern"}, {"von": "2026-09-02", "bis": "2026-09-01"},
		{"limit": 1000}, {"rueckzahlungen": "egal"}, {"unbekannt": 1}, {"limit": "zehn"},
	} {
		if _, text, isErr := e.call("ausgaben_suchen", args); !isErr || text == "" || strings.Contains(text, "Interner Fehler") {
			t.Errorf("%v: isError=%v %q", args, isErr, text)
		}
	}
	if _, text, _ := e.call("ausgaben_suchen", map[string]any{"person": "Dora"}); !strings.Contains(text, "Anna, Ben, Cleo") {
		t.Errorf("Fehler ohne Namensliste: %s", text)
	}

	// statistik
	sc, _, isErr = e.call("statistik", map[string]any{"gruppierung": "kategorie", "person": "Ben"})
	if isErr {
		t.Fatal(sc)
	}
	zeilen := sc["zeilen"].([]any)
	if len(zeilen) != 2 || zeilen[0].(map[string]any)["kategorie"] != "Restaurant" || zeilen[0].(map[string]any)["summe_cent"].(float64) != 3000 ||
		sc["gesamt_cent"].(float64) != 4500 || !strings.Contains(sc["sicht"].(string), "Ben") {
		t.Errorf("statistik Ben: %v", sc)
	}
	sc, _, _ = e.call("statistik", map[string]any{"gruppierung": "person"})
	if z := sc["zeilen"].([]any)[0].(map[string]any); z["person"] != "Ben" || z["bezahlt_cent"].(float64) != 1000 || sc["gesamt_cent"].(float64) != 10000 {
		t.Errorf("statistik person: %v", sc)
	}
	sc, _, _ = e.call("statistik", map[string]any{"gruppierung": "monat", "von": "2026-09-01", "bis": "30.09.2026"})
	if z := sc["zeilen"].([]any); len(z) != 1 || z[0].(map[string]any)["monat"] != "2026-09" || sc["zeitraum"] != "2026-09-01 bis 2026-09-30" {
		t.Errorf("statistik monat: %v", sc)
	}
	if _, _, isErr := e.call("statistik", map[string]any{"gruppierung": "jahr"}); !isErr {
		t.Error("ungültige gruppierung ohne Fehler")
	}
	if _, _, isErr := e.call("statistik", nil); !isErr {
		t.Error("fehlende gruppierung ohne Fehler")
	}

	// schema
	sc, text, isErr = e.call("schema", nil)
	if isErr || sc != nil || !strings.Contains(text, "deleted_at IS NULL") || !strings.Contains(text, "CREATE TABLE expenses") ||
		!strings.Contains(text, ": Anna") || strings.Contains(text, "CREATE TABLE ynab") {
		t.Errorf("schema: %s", text)
	}

	// sql_abfrage
	sc, _, isErr = e.call("sql_abfrage", map[string]any{"abfrage": "SELECT name, archived_at FROM participants ORDER BY name"})
	if isErr || sc["anzahl"].(float64) != 3 || sc["zeilen"].([]any)[0].([]any)[0] != "Anna" || sc["spalten"].([]any)[1] != "archived_at" {
		t.Errorf("sql: %v", sc)
	}
	for _, q := range []string{"SELECT token FROM ynab_config", "DELETE FROM expenses", "SELECT 1; DELETE FROM expenses", "SELECT * FROM gibtsnicht", ""} {
		if _, text, isErr := e.call("sql_abfrage", map[string]any{"abfrage": q}); !isErr || strings.Contains(text, "Interner Fehler") {
			t.Errorf("sql %q: isError=%v %s", q, isErr, text)
		}
	}
	if es, _ := e.st.ListExpenses(ctx, store.ExpenseFilter{}); len(es) != 5 {
		t.Errorf("Ausgaben nach sql_abfrage: %d", len(es))
	}
	if !strings.Contains(e.logs.String(), "tool=sql_abfrage") {
		t.Error("Tool-Aufruf nicht geloggt")
	}
}
