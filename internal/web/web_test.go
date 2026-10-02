package web

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/store"
)

// testServer calls the handler directly (no port needed, also works in the sandbox).
type testServer struct {
	h http.Handler
}

func (s testServer) do(req *http.Request) *http.Response {
	rec := httptest.NewRecorder()
	s.h.ServeHTTP(rec, req)
	return rec.Result()
}

func (s testServer) postForm(path string, v url.Values) *http.Response {
	req := httptest.NewRequest("POST", path, strings.NewReader(v.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return s.do(req)
}

func newTestServer(t *testing.T) (testServer, Deps) {
	t.Helper()
	st, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	r, err := NewRenderer(st, time.UTC, log)
	if err != nil {
		t.Fatal(err)
	}
	d := Deps{Store: st, Render: r, Log: log}
	mux := http.NewServeMux()
	Register(mux, d)
	return testServer{h: Wrap(d, mux)}, d
}

func get(t *testing.T, srv testServer, path string, cookies ...*http.Cookie) (*http.Response, string) {
	t.Helper()
	req := httptest.NewRequest("GET", path, nil)
	for _, c := range cookies {
		req.AddCookie(c)
	}
	res := srv.do(req)
	b, _ := io.ReadAll(res.Body)
	return res, string(b)
}

func whoCookie(id int64) *http.Cookie {
	return &http.Cookie{Name: IdentityCookie, Value: strconv.FormatInt(id, 10)}
}

func TestRedirectWithoutIdentity(t *testing.T) {
	srv, _ := newTestServer(t)
	res, _ := get(t, srv, "/salden?x=1")
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/wer?zurueck=%2Fsalden%3Fx%3D1" {
		t.Errorf("without cookie: %d → %q", res.StatusCode, res.Header.Get("Location"))
	}
	res, _ = get(t, srv, "/")
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/wer" {
		t.Errorf("/ without cookie: %d → %q", res.StatusCode, res.Header.Get("Location"))
	}
	res, _ = get(t, srv, "/", whoCookie(42))
	if res.StatusCode != http.StatusSeeOther {
		t.Errorf("unknown ID in cookie: %d", res.StatusCode)
	}
	res, body := get(t, srv, "/api/kurs")
	if res.StatusCode != http.StatusUnauthorized || !strings.Contains(body, "error") {
		t.Errorf("/api without cookie: %d %s", res.StatusCode, body)
	}
}

func TestPublicPaths(t *testing.T) {
	srv, _ := newTestServer(t)
	res, body := get(t, srv, "/healthz")
	if res.StatusCode != 200 || body != "ok\n" {
		t.Errorf("/healthz: %d %q", res.StatusCode, body)
	}
	res, body = get(t, srv, "/wer")
	if res.StatusCode != 200 || !strings.Contains(body, "Wer bist du?") || !strings.Contains(body, "Neue Person") {
		t.Errorf("/wer: %d", res.StatusCode)
	}
	if strings.Contains(body, "Hauptnavigation") {
		t.Error("/wer without identity shows the navigation")
	}
	res, body = get(t, srv, "/static/app.css")
	if res.StatusCode != 200 || !strings.Contains(body, "--background") || res.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("/static/app.css: %d", res.StatusCode)
	}
}

func TestCreateAndSelectPerson(t *testing.T) {
	srv, d := newTestServer(t)
	res := srv.postForm("/wer/neu", url.Values{"name": {"Jörg"}, "zurueck": {"/salden"}})
	res.Body.Close()
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/salden" {
		t.Fatalf("POST /wer/neu: %d → %q", res.StatusCode, res.Header.Get("Location"))
	}
	var who, flash *http.Cookie
	for _, c := range res.Cookies() {
		switch c.Name {
		case IdentityCookie:
			who = c
		case flashCookie:
			flash = c
		}
	}
	if who == nil || !who.HttpOnly || who.SameSite != http.SameSiteLaxMode {
		t.Fatalf("cookie missing/wrong: %+v", who)
	}
	ps, _ := d.Store.ListParticipants(context.Background(), false)
	if len(ps) != 1 || ps[0].Name != "Jörg" || who.Value != strconv.FormatInt(ps[0].ID, 10) {
		t.Fatalf("person not created: %+v / %v", ps, who)
	}
	// Logged with the new person as the actor.
	if acts, _ := d.Store.ListActivity(context.Background(), store.ActivityFilter{Limit: 1}); len(acts) != 1 ||
		acts[0].Action != store.ActionSettingsUpdated || acts[0].ActorID != ps[0].ID || acts[0].Details.Text != "Person „Jörg“ hinzugefügt" {
		t.Errorf("activity = %+v", acts)
	}

	res, body := get(t, srv, "/salden", who, flash)
	if res.StatusCode != 200 {
		t.Fatalf("/salden with cookie: %d", res.StatusCode)
	}
	for _, want := range []string{"Du bist <strong>Jörg</strong>", `href="/salden" aria-current="page"`, "Willkommen!", "/static/app.css?v="} {
		if !strings.Contains(body, want) {
			t.Errorf("/salden does not contain %q", want)
		}
	}

	// Duplicate name → error message in the form.
	res = srv.postForm("/wer/neu", url.Values{"name": {"jörg"}})
	b, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusUnprocessableEntity || !strings.Contains(string(b), "gibt es schon") {
		t.Errorf("duplicate name: %d", res.StatusCode)
	}
}

func TestSelectPerson(t *testing.T) {
	srv, d := newTestServer(t)
	id, _ := d.Store.CreateParticipant(context.Background(), "Anna")
	for _, tc := range []struct{ ret, want string }{
		{"/aktivitaet", "/aktivitaet"},
		{"//evil.example", "/"},
		{"https://evil.example", "/"},
		{"", "/"},
	} {
		res := srv.postForm("/wer", url.Values{"id": {strconv.FormatInt(id, 10)}, "zurueck": {tc.ret}})
		res.Body.Close()
		if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != tc.want {
			t.Errorf("zurueck=%q: %d → %q, want %q", tc.ret, res.StatusCode, res.Header.Get("Location"), tc.want)
		}
	}
	res := srv.postForm("/wer", url.Values{"id": {"999"}})
	res.Body.Close()
	if res.StatusCode != http.StatusUnprocessableEntity {
		t.Errorf("unknown person: %d", res.StatusCode)
	}
	// An archived person no longer counts as an identity.
	d.Store.SetParticipantArchived(context.Background(), id, true)
	if res, _ := get(t, srv, "/", whoCookie(id)); res.StatusCode != http.StatusSeeOther {
		t.Errorf("archived person: %d", res.StatusCode)
	}
}

func TestPagesRender(t *testing.T) {
	srv, d := newTestServer(t)
	id, _ := d.Store.CreateParticipant(context.Background(), "Anna")
	for _, p := range []string{"/", "/salden", "/aktivitaet", "/einstellungen"} {
		res, body := get(t, srv, p, whoCookie(id))
		if res.StatusCode != 200 || !strings.Contains(body, `aria-current="page"`) {
			t.Errorf("%s: %d", p, res.StatusCode)
		}
	}
}

func TestLoadForeignTemplates(t *testing.T) {
	_, d := newTestServer(t)
	fsys := fstest.MapFS{
		"templates/_partial.html": {Data: []byte(`{{define "hello"}}Hallo {{.}}{{end}}`)},
		"templates/ynab.html":     {Data: []byte(`{{define "content"}}<p>{{template "hello" .Data.Name}} {{eur .Data.Cents}}</p>{{end}}`)},
	}
	pages, err := d.Render.Load(fsys, "templates/*.html")
	if err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/einstellungen/ynab", nil)
	req = req.WithContext(WithMe(req.Context(), store.Participant{ID: 1, Name: "Anna"}))
	pages.Render(rec, req, http.StatusOK, "ynab.html", Page{Title: "YNAB", Nav: NavSettings, Data: map[string]any{"Name": "Welt", "Cents": int64(1234)}})
	body := rec.Body.String()
	for _, want := range []string{"<p>Hallo Welt 12,34 €</p>", "<title>YNAB · Zipfelkasse</title>", `href="/einstellungen" aria-current="page"`, "Du bist <strong>Anna</strong>"} {
		if !strings.Contains(body, want) {
			t.Errorf("body does not contain %q:\n%s", want, body)
		}
	}
	if _, err := d.Render.Load(fsys, "nothing/*.html"); err == nil {
		t.Error("Load without matches should return an error")
	}
}

func TestRenderTemplateErrorGives500(t *testing.T) {
	_, d := newTestServer(t)
	pages, err := d.Render.Load(fstest.MapFS{"t/bad.html": {Data: []byte(`{{define "content"}}{{.Data.Missing.Deeper}}{{end}}`)}}, "t/*.html")
	if err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	pages.Render(rec, httptest.NewRequest("GET", "/", nil), 200, "bad.html", Page{Data: 5})
	if rec.Code != 500 || strings.Contains(rec.Body.String(), "<html") {
		t.Errorf("template error: %d %q", rec.Code, rec.Body.String())
	}
}

func TestCrossOriginProtection(t *testing.T) {
	srv, d := newTestServer(t)
	id, _ := d.Store.CreateParticipant(context.Background(), "Anna")
	post := func(hdr map[string]string) *http.Response {
		req := httptest.NewRequest("POST", "/wer", strings.NewReader(url.Values{"id": {strconv.FormatInt(id, 10)}}.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
		return srv.do(req)
	}
	// Cross-site (a foreign site submits a form) → 403 with an error page.
	res := post(map[string]string{"Sec-Fetch-Site": "cross-site", "Origin": "https://evil.example"})
	b, _ := io.ReadAll(res.Body)
	if res.StatusCode != http.StatusForbidden || !strings.Contains(string(b), "fremden Seite") {
		t.Errorf("cross-site POST: %d %s", res.StatusCode, b)
	}
	// Old browsers without Sec-Fetch-Site: Origin does not match the host → 403.
	if res := post(map[string]string{"Origin": "https://evil.example"}); res.StatusCode != http.StatusForbidden {
		t.Errorf("POST with foreign origin: %d", res.StatusCode)
	}
	// Same origin → normal (303).
	if res := post(map[string]string{"Sec-Fetch-Site": "same-origin", "Origin": "http://example.com"}); res.StatusCode != http.StatusSeeOther {
		t.Errorf("same-origin POST: %d", res.StatusCode)
	}
	// Without browser headers (curl, MCP clients) → let through.
	if res := post(nil); res.StatusCode != http.StatusSeeOther {
		t.Errorf("POST without browser headers: %d", res.StatusCode)
	}
}

func TestSafeReturn(t *testing.T) {
	for in, want := range map[string]string{
		"/aktivitaet":           "/aktivitaet",
		"/salden?x=1#a":         "/salden?x=1#a",
		"/%09/evil.example/x":   "/",
		"/\t/evil.example/x":    "/",
		"/\r\n/evil.example":    "/",
		"//evil":                "/",
		"/\\evil":               "/",
		"/a\\b":                 "/",
		"https://evil":          "/",
		"evil":                  "/",
		"/wer?zurueck=/":        "/",
		"":                      "/",
		"/%2F/evil.example":     "/",
		"/ausgaben/neu?von=%2F": "/ausgaben/neu?von=%2F",
	} {
		if got := safeReturn(in); got != want {
			t.Errorf("safeReturn(%q) = %q, want %q", in, got, want)
		}
	}
}

// Request bodies are limited to maxBodyBytes: too large ones get a 413 with
// an error page (JSON under /api/), whether the length is known up front or
// not. /mcp/ applies its own limit with JSON-RPC errors.
func TestBodyLimit(t *testing.T) {
	srv, d := newTestServer(t)
	anna, _ := d.Store.CreateParticipant(context.Background(), "Anna")
	big := url.Values{"name": {strings.Repeat("a", maxBodyBytes)}}.Encode()
	post := func(path string, chunked bool) (*http.Response, string) {
		req := httptest.NewRequest("POST", path, strings.NewReader(big))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.AddCookie(whoCookie(anna))
		if chunked {
			req.ContentLength = -1
		}
		res := srv.do(req)
		b, _ := io.ReadAll(res.Body)
		return res, string(b)
	}
	for _, chunked := range []bool{false, true} {
		res, body := post("/einstellungen/teilnehmer", chunked)
		if res.StatusCode != http.StatusRequestEntityTooLarge || !strings.Contains(body, "zu groß") ||
			!strings.HasPrefix(res.Header.Get("Content-Type"), "text/html") {
			t.Errorf("chunked=%v: %d %.200s", chunked, res.StatusCode, body)
		}
		res, body = post("/api/kurs", chunked)
		if res.StatusCode != http.StatusRequestEntityTooLarge || !strings.HasPrefix(res.Header.Get("Content-Type"), "application/json") ||
			!strings.Contains(body, "zu groß") {
			t.Errorf("api chunked=%v: %d %.200s", chunked, res.StatusCode, body)
		}
	}
	if res, _ := post("/mcp/geheim", false); res.StatusCode == http.StatusRequestEntityTooLarge {
		t.Error("/mcp/ rejected by the web limit instead of its own")
	}
	if ps, _ := d.Store.ListParticipants(context.Background(), true); len(ps) != 1 {
		t.Errorf("participants: %d", len(ps))
	}
	// Normal requests pass.
	req := httptest.NewRequest("POST", "/einstellungen/teilnehmer", strings.NewReader("name=Ben"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(whoCookie(anna))
	if res := srv.do(req); res.StatusCode != http.StatusSeeOther {
		t.Errorf("small request: %d", res.StatusCode)
	}
}
