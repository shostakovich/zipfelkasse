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

	"teilen/internal/store"
)

// testServer ruft den Handler direkt auf (kein Port nötig, läuft auch in der Sandbox).
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
		t.Errorf("ohne Cookie: %d → %q", res.StatusCode, res.Header.Get("Location"))
	}
	res, _ = get(t, srv, "/")
	if res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/wer" {
		t.Errorf("/ ohne Cookie: %d → %q", res.StatusCode, res.Header.Get("Location"))
	}
	res, _ = get(t, srv, "/", whoCookie(42))
	if res.StatusCode != http.StatusSeeOther {
		t.Errorf("unbekannte ID im Cookie: %d", res.StatusCode)
	}
	res, body := get(t, srv, "/api/kurs")
	if res.StatusCode != http.StatusUnauthorized || !strings.Contains(body, "error") {
		t.Errorf("/api ohne Cookie: %d %s", res.StatusCode, body)
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
		t.Error("/wer ohne Identität zeigt Navigation")
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
		t.Fatalf("Cookie fehlt/falsch: %+v", who)
	}
	ps, _ := d.Store.ListParticipants(context.Background(), false)
	if len(ps) != 1 || ps[0].Name != "Jörg" || who.Value != strconv.FormatInt(ps[0].ID, 10) {
		t.Fatalf("Person nicht angelegt: %+v / %v", ps, who)
	}

	res, body := get(t, srv, "/salden", who, flash)
	if res.StatusCode != 200 {
		t.Fatalf("/salden mit Cookie: %d", res.StatusCode)
	}
	for _, want := range []string{"Du bist <strong>Jörg</strong>", `href="/salden" aria-current="page"`, "Willkommen!", "/static/app.css?v="} {
		if !strings.Contains(body, want) {
			t.Errorf("/salden enthält nicht %q", want)
		}
	}

	// Doppelter Name → Fehlermeldung im Formular.
	res = srv.postForm("/wer/neu", url.Values{"name": {"jörg"}})
	b, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusUnprocessableEntity || !strings.Contains(string(b), "gibt es schon") {
		t.Errorf("doppelter Name: %d", res.StatusCode)
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
		t.Errorf("unbekannte Person: %d", res.StatusCode)
	}
	// Archivierte Person gilt nicht mehr als Identität.
	d.Store.SetParticipantArchived(context.Background(), id, true)
	if res, _ := get(t, srv, "/", whoCookie(id)); res.StatusCode != http.StatusSeeOther {
		t.Errorf("archivierte Person: %d", res.StatusCode)
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
	for _, want := range []string{"<p>Hallo Welt 12,34 €</p>", "<title>YNAB · teilen</title>", `href="/einstellungen" aria-current="page"`, "Du bist <strong>Anna</strong>"} {
		if !strings.Contains(body, want) {
			t.Errorf("Body enthält nicht %q:\n%s", want, body)
		}
	}
	if _, err := d.Render.Load(fsys, "nichts/*.html"); err == nil {
		t.Error("Load ohne Treffer sollte Fehler liefern")
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
		t.Errorf("Template-Fehler: %d %q", rec.Code, rec.Body.String())
	}
}
