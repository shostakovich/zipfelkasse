package fx

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path"
	"strings"
	"sync"
	"testing"
	"time"

	"teilen/internal/config"
	"teilen/internal/domain"
	"teilen/internal/store"
	"teilen/internal/web"
)

// fakeECB beantwortet Anfragen an die EZB aus testdata (http.RoundTripper,
// kein Port nötig).
type fakeECB struct {
	mu     sync.Mutex
	files  map[string][]byte
	hits   map[string]int
	err    error         // Netzwerkfehler simulieren
	status int           // != 0: diesen HTTP-Status liefern
	block  chan struct{} // != nil: Antwort erst nach close
	agents []string
}

func newFakeECB(t *testing.T) *fakeECB {
	t.Helper()
	f := &fakeECB{files: map[string][]byte{}, hits: map[string]int{}}
	for _, name := range []string{fileDaily, file90d} {
		b, err := os.ReadFile("testdata/" + name)
		if err != nil {
			t.Fatal(err)
		}
		f.files[name] = b
	}
	csv, err := os.ReadFile("testdata/eurofxref-hist.csv")
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w, _ := zw.Create("eurofxref-hist.csv")
	w.Write(csv)
	zw.Close()
	f.files[fileHist] = buf.Bytes()
	return f
}

func (f *fakeECB) RoundTrip(req *http.Request) (*http.Response, error) {
	name := path.Base(req.URL.Path)
	f.mu.Lock()
	f.hits[name]++
	f.agents = append(f.agents, req.Header.Get("User-Agent"))
	body, ok := f.files[name]
	err, status, block := f.err, f.status, f.block
	f.mu.Unlock()
	if block != nil {
		<-block
	}
	if err != nil {
		return nil, err
	}
	if status == 0 {
		status = http.StatusOK
	}
	if !ok {
		status = http.StatusNotFound
	}
	return &http.Response{StatusCode: status, Header: http.Header{}, Body: io.NopCloser(bytes.NewReader(body)), Request: req}, nil
}

func (f *fakeECB) count(name string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[name]
}

func (f *fakeECB) total() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, v := range f.hits {
		n += v
	}
	return n
}

var berlin = mustLoc("Europe/Berlin")

func mustLoc(name string) *time.Location {
	loc, err := time.LoadLocation(name)
	if err != nil {
		panic(err)
	}
	return loc
}

func day(s string) time.Time {
	t, err := time.Parse(domain.DateLayout, s)
	if err != nil {
		panic(err)
	}
	return t
}

// at liefert eine Uhr, die immer t (Europe/Berlin, "2006-01-02 15:04") zeigt.
func at(s string) func() time.Time {
	t, err := time.ParseInLocation("2006-01-02 15:04", s, berlin)
	if err != nil {
		panic(err)
	}
	return func() time.Time { return t }
}

func newTestDeps(t *testing.T, st *store.Store) web.Deps {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	r, err := web.NewRenderer(st, berlin, log)
	if err != nil {
		t.Fatal(err)
	}
	return web.Deps{Config: config.Config{Location: berlin}, Store: st, Render: r, Log: log}
}

func newTestStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

// newTestService: heute ist Freitag, 02.10.2026, 12:00 Uhr (Kurse vom Tag
// noch nicht veröffentlicht).
func newTestService(t *testing.T, st *store.Store) (*Service, *fakeECB) {
	t.Helper()
	s, err := New(newTestDeps(t, st))
	if err != nil {
		t.Fatal(err)
	}
	f := newFakeECB(t)
	s.client = &http.Client{Transport: f, Timeout: 5 * time.Second}
	s.now = at("2026-10-02 12:00")
	return s, f
}

func isValidation(err error, contains string) bool {
	var ve domain.ValidationError
	return errors.As(err, &ve) && strings.Contains(ve.Msg, contains)
}

func TestRateEURAndInvalid(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	ctx := context.Background()
	r, err := s.Rate(ctx, " eur ", day("2026-09-01"))
	if err != nil || r.Rate != 1 || r.Source != domain.FXSourceFixed || r.Currency != "EUR" || r.Date != day("2026-09-01") {
		t.Errorf("EUR = %+v, %v", r, err)
	}
	for _, bad := range []string{"", "US", "US1", "EURO"} {
		if _, err := s.Rate(ctx, bad, day("2026-09-01")); !isValidation(err, "") {
			t.Errorf("Rate(%q) = %v", bad, err)
		}
	}
	if f.total() != 0 {
		t.Errorf("ohne Bedarf geladen: %v", f.hits)
	}
}

func TestRateDailyAndCache(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	ctx := context.Background()
	r, err := s.Rate(ctx, "usd", day("2026-10-01"))
	if err != nil || r.Rate != 1.1298 || r.Date != day("2026-10-01") || r.Source != domain.FXSourceECB || r.Currency != "USD" {
		t.Fatalf("USD = %+v, %v", r, err)
	}
	if f.count(fileDaily) != 1 || f.total() != 1 {
		t.Errorf("Abrufe = %v", f.hits)
	}
	if !strings.HasPrefix(f.agents[0], "teilen/") {
		t.Errorf("User-Agent = %q", f.agents[0])
	}
	// Heute vor 16:30: Der Kurs von gestern ist der aktuellste → aus dem Cache.
	r, err = s.Rate(ctx, "USD", day("2026-10-02"))
	if err != nil || r.Date != day("2026-10-01") {
		t.Errorf("heute = %+v, %v", r, err)
	}
	// Zukunft → aktuellster Kurs.
	r, err = s.Rate(ctx, "GBP", day("2026-12-24"))
	if err != nil || r.Rate != 0.85373 {
		t.Errorf("Zukunft = %+v, %v", r, err)
	}
	if f.total() != 1 {
		t.Errorf("Cache nicht genutzt: %v", f.hits)
	}
}

func TestRateOlderUses90d(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	ctx := context.Background()
	// Sonntag → Kurs vom Freitag davor.
	r, err := s.Rate(ctx, "JPY", day("2026-09-27"))
	if err != nil || r.Rate != 176.5 || r.Date != day("2026-09-25") {
		t.Fatalf("JPY = %+v, %v", r, err)
	}
	if f.count(file90d) != 1 || f.total() != 1 {
		t.Errorf("Abrufe = %v", f.hits)
	}
	// Liegt jetzt im Cache, auch für andere Tage.
	if r, err := s.Rate(ctx, "USD", day("2026-09-29")); err != nil || r.Rate != 1.1251 {
		t.Errorf("USD = %+v, %v", r, err)
	}
	if f.total() != 1 {
		t.Errorf("Abrufe = %v", f.hits)
	}
}

func TestRateDailyEscalatesTo90d(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	s.now = at("2026-10-02 17:00")
	f.files[fileDaily] = []byte(`<?xml version="1.0"?><gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref"><Cube><Cube time="2026-10-02"><Cube currency="USD" rate="1.1311"/></Cube></Cube></gesmes:Envelope>`)
	ctx := context.Background()
	r, err := s.Rate(ctx, "USD", day("2026-10-01"))
	if err != nil || r.Rate != 1.1298 || r.Date != day("2026-10-01") {
		t.Fatalf("gestern = %+v, %v", r, err)
	}
	if f.count(fileDaily) != 1 || f.count(file90d) != 1 {
		t.Errorf("Abrufe = %v", f.hits)
	}
	if r, err := s.Rate(ctx, "USD", day("2026-10-02")); err != nil || r.Rate != 1.1311 {
		t.Errorf("heute = %+v, %v", r, err)
	}
	if f.total() != 2 {
		t.Errorf("Abrufe = %v", f.hits)
	}
}

func TestRateHistZipLoadedOnce(t *testing.T) {
	st := newTestStore(t)
	s, f := newTestService(t, st)
	ctx := context.Background()
	r, err := s.Rate(ctx, "USD", day("2024-01-03"))
	if err != nil || r.Rate != 1.0919 {
		t.Fatalf("2024 = %+v, %v", r, err)
	}
	if f.count(fileHist) != 1 || f.total() != 1 {
		t.Errorf("Abrufe = %v", f.hits)
	}
	// Wochenende → Freitag davor; alles aus dem Cache.
	if r, err := s.Rate(ctx, "GBP", day("2022-03-06")); err != nil || r.Rate != 0.836 || r.Date != day("2022-03-01") {
		t.Errorf("2022 = %+v, %v", r, err)
	}
	// RUB gibt es seit März 2022 nicht mehr.
	if _, err := s.Rate(ctx, "RUB", day("2024-01-03")); !isValidation(err, "um den 03.01.2024 keinen EZB-Kurs") {
		t.Errorf("RUB 2024 = %v", err)
	}
	if _, err := s.Rate(ctx, "XYZ", day("2024-01-03")); !isValidation(err, "Für XYZ gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.") {
		t.Errorf("XYZ = %v", err)
	}
	if f.total() != 1 {
		t.Errorf("Abrufe = %v", f.hits)
	}

	// Neustart: Die Historie ist schon im Cache und wird nicht erneut geladen.
	s2, f2 := newTestService(t, st)
	if r, err := s2.Rate(ctx, "USD", day("2024-01-02")); err != nil || r.Rate != 1.0956 {
		t.Errorf("nach Neustart = %+v, %v", r, err)
	}
	if _, err := s2.Rate(ctx, "JPY", day("1998-12-31")); !isValidation(err, "keinen EZB-Kurs") {
		t.Errorf("vor 1999 = %v", err)
	}
	if f2.total() != 0 {
		t.Errorf("Historie erneut geladen: %v", f2.hits)
	}
}

func TestRateUnknownCurrency(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	ctx := context.Background()
	_, err := s.Rate(ctx, "XYZ", day("2026-10-01"))
	if !isValidation(err, "Für XYZ gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.") {
		t.Fatalf("XYZ = %v", err)
	}
	_, err = s.Rate(ctx, "XYZ", day("2026-10-01"))
	if !isValidation(err, "Für XYZ gibt es keinen EZB-Kurs") {
		t.Errorf("XYZ (2) = %v", err)
	}
	if f.total() != 1 {
		t.Errorf("Abrufe = %v (kurz nach einem Abruf nicht erneut laden)", f.hits)
	}
}

func TestRateManualPrecedence(t *testing.T) {
	st := newTestStore(t)
	s, f := newTestService(t, st)
	ctx := context.Background()
	if err := st.SetManualFXRate(ctx, "USD", day("2026-09-30"), 1.2); err != nil {
		t.Fatal(err)
	}
	if err := st.SetManualFXRate(ctx, "XYZ", day("2026-01-01"), 4.5); err != nil {
		t.Fatal(err)
	}
	r, err := s.Rate(ctx, "USD", day("2026-10-01"))
	if err != nil || r.Rate != 1.2 || r.Source != domain.FXSourceManual || r.Date != day("2026-09-30") {
		t.Errorf("manuell = %+v, %v", r, err)
	}
	if r, err := s.Rate(ctx, "XYZ", day("2026-06-01")); err != nil || r.Rate != 4.5 {
		t.Errorf("XYZ manuell = %+v, %v", r, err)
	}
	if f.total() != 0 {
		t.Errorf("trotz manuellem Kurs geladen: %v", f.hits)
	}
	// Vor dem manuellen Kurs gilt die EZB.
	r, err = s.Rate(ctx, "USD", day("2026-09-29"))
	if err != nil || r.Rate != 1.1251 || r.Source != domain.FXSourceECB {
		t.Errorf("vor manuell = %+v, %v", r, err)
	}
}

func TestRateFetchErrors(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	ctx := context.Background()
	f.err = errors.New("connection refused")
	_, err := s.Rate(ctx, "USD", day("2026-10-01"))
	var fe *FetchError
	if !errors.As(err, &fe) || !strings.Contains(err.Error(), "nicht geladen werden") {
		t.Fatalf("Netzwerkfehler = %v", err)
	}
	// Kurz danach: kein neuer Versuch.
	s.Rate(ctx, "USD", day("2026-10-01"))
	if f.total() != 1 {
		t.Errorf("Abrufe = %v", f.hits)
	}
	// Nach Ablauf der Sperre erneut, jetzt mit HTTP-Fehler.
	s.now = at("2026-10-02 12:05")
	f.err, f.status = nil, http.StatusInternalServerError
	if _, err := s.Rate(ctx, "USD", day("2026-10-01")); !errors.As(err, &fe) || !strings.Contains(err.Error(), "500") {
		t.Errorf("HTTP 500 = %v", err)
	}
	// Kaputte Datei.
	s.now = at("2026-10-02 12:10")
	f.status = 0
	f.files[fileDaily] = []byte("<kaputt")
	if _, err := s.Rate(ctx, "USD", day("2026-10-01")); !errors.As(err, &fe) {
		t.Errorf("kaputtes XML = %v", err)
	}
	if f.count(fileDaily) != 3 {
		t.Errorf("Abrufe = %v", f.hits)
	}
}

func TestFetchSingleflight(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	f.block = make(chan struct{})
	ctx := context.Background()
	var wg sync.WaitGroup
	errs := make(chan error, 5)
	for range 5 {
		wg.Go(func() {
			r, err := s.Rate(ctx, "USD", day("2026-10-01"))
			if err == nil && r.Rate != 1.1298 {
				err = errors.New("falscher kurs")
			}
			errs <- err
		})
	}
	for f.total() == 0 {
		time.Sleep(time.Millisecond)
	}
	time.Sleep(20 * time.Millisecond) // die anderen warten lassen
	close(f.block)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Error(err)
		}
	}
	if f.total() != 1 {
		t.Errorf("Datei mehrfach geladen: %v", f.hits)
	}
}

func TestFetchContextCancel(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	f.block = make(chan struct{})
	defer close(f.block)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, err := s.Rate(ctx, "USD", day("2026-10-01")); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Abbruch = %v", err)
	}
}

func TestRefresh(t *testing.T) {
	st := newTestStore(t)
	s, f := newTestService(t, st)
	ctx := context.Background()
	// Leerer Cache → 90-Tage-Datei.
	latest, err := s.Refresh(ctx)
	if err != nil || latest != day("2026-10-01") || f.count(file90d) != 1 {
		t.Fatalf("Refresh = %v, %v, %v", latest, err, f.hits)
	}
	// Aktueller Cache → Tagesdatei, auch kurz nach dem letzten Abruf (force).
	if _, err := s.Refresh(ctx); err != nil || f.count(fileDaily) != 1 {
		t.Errorf("Refresh (2) = %v, %v", err, f.hits)
	}
	if _, err := s.Refresh(ctx); err != nil || f.count(fileDaily) != 2 {
		t.Errorf("Refresh (3) = %v, %v", err, f.hits)
	}
}

func TestCalendar(t *testing.T) {
	for y, want := range map[int]string{2024: "2024-03-31", 2025: "2025-04-20", 2026: "2026-04-05", 2027: "2027-03-28"} {
		if got := easterSunday(y); got != day(want) {
			t.Errorf("Ostern %d = %s, want %s", y, got.Format(domain.DateLayout), want)
		}
	}
	for d, want := range map[string]bool{
		"2026-10-02": true, "2026-10-03": false, "2026-10-04": false, "2026-04-03": false, "2026-04-06": false,
		"2026-05-01": false, "2026-12-24": true, "2026-12-25": false, "2027-01-01": false, "2026-10-05": true,
	} {
		if got := isBusinessDay(day(d)); got != want {
			t.Errorf("isBusinessDay(%s) = %v", d, got)
		}
	}
	if got := lastBusinessDay(day("2026-04-06")); got != day("2026-04-02") {
		t.Errorf("lastBusinessDay(Ostermontag) = %s", got)
	}
	for now, want := range map[string]string{
		"2026-10-02 12:00": "2026-10-02 16:30",
		"2026-10-02 16:30": "2026-10-05 16:30",
		"2026-10-02 17:00": "2026-10-05 16:30",
		"2026-12-24 17:00": "2026-12-28 16:30",
		"2026-03-28 10:00": "2026-03-30 16:30", // Zeitumstellung am 29.03.
	} {
		if got := nextPublish(at(now)()).Format("2006-01-02 15:04"); got != want {
			t.Errorf("nextPublish(%s) = %s, want %s", now, got, want)
		}
	}
}

func TestParseFiles(t *testing.T) {
	b, _ := os.ReadFile("testdata/" + file90d)
	rates, err := parseXML(bytes.NewReader(b))
	if err != nil || len(rates) != 18 {
		t.Fatalf("parseXML = %d, %v", len(rates), err)
	}
	res := summarize(rates)
	if res.From != day("2026-07-06") || res.To != day("2026-10-01") || len(res.Currencies) != 3 {
		t.Errorf("summarize = %+v", res)
	}
	csv, _ := os.ReadFile("testdata/eurofxref-hist.csv")
	rates, err = parseHistCSV(bytes.NewReader(csv))
	if err != nil {
		t.Fatal(err)
	}
	// N/A und leere Spalten werden übersprungen.
	n := map[string]int{}
	for _, r := range rates {
		n[r.Currency]++
	}
	if n["USD"] != 6 || n["CYP"] != 1 || n["RUB"] != 2 || n["BGN"] != 4 || n[""] != 0 {
		t.Errorf("CSV-Währungen = %v", n)
	}
	if _, err := parseHistCSV(strings.NewReader("Foo,USD\n")); err == nil {
		t.Error("falsche Kopfzeile ohne Fehler")
	}
	if _, err := parseHistZip([]byte("kein zip")); err == nil {
		t.Error("kaputtes ZIP ohne Fehler")
	}
	for in, want := range map[string]float64{"1.1298": 1.1298, " 2 ": 2, "N/A": 0, "": 0, "-1": 0, "NaN": 0, "Inf": 0} {
		if got, _ := parseECBRate(in); got != want {
			t.Errorf("parseECBRate(%q) = %v", in, got)
		}
	}
}

// --- Handler ----------------------------------------------------------------

func newMux(s *Service) *http.ServeMux {
	mux := http.NewServeMux()
	s.Register(mux)
	return mux
}

func do(h http.Handler, method, target string, form url.Values) *httptest.ResponseRecorder {
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req := httptest.NewRequest(method, target, body)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestAPIRate(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	mux := newMux(s)
	tests := []struct {
		target string
		status int
		body   string
	}{
		{"/api/kurs?waehrung=USD&datum=2026-10-01", 200, `{"currency":"USD","date":"2026-10-01","rate":1.1298,"source":"ezb"}`},
		{"/api/kurs?waehrung=usd&datum=01.10.2026", 200, `"rate":1.1298`},
		{"/api/kurs?waehrung=USD", 200, `"date":"2026-10-01"`},
		{"/api/kurs?waehrung=EUR", 200, `{"currency":"EUR","date":"2026-10-02","rate":1,"source":"fest"}`},
		{"/api/kurs", 400, `"error":"Bitte eine Währung angeben."`},
		{"/api/kurs?waehrung=US1", 400, `"error"`},
		{"/api/kurs?waehrung=USD&datum=gestern", 400, `"error"`},
		{"/api/kurs?waehrung=XYZ&datum=2026-10-01", 422, `keinen EZB-Kurs`},
	}
	for _, tt := range tests {
		rec := do(mux, "GET", tt.target, nil)
		if rec.Code != tt.status || !strings.Contains(rec.Body.String(), tt.body) ||
			!strings.HasPrefix(rec.Header().Get("Content-Type"), "application/json") {
			t.Errorf("%s: %d %s", tt.target, rec.Code, rec.Body)
		}
	}
	s2, f2 := newTestService(t, newTestStore(t))
	f2.err = errors.New("no route to host")
	rec := do(newMux(s2), "GET", "/api/kurs?waehrung=USD", nil)
	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "nicht geladen werden") {
		t.Errorf("Netzwerkfehler: %d %s", rec.Code, rec.Body)
	}
	_ = f
}

func TestSettingsPage(t *testing.T) {
	st := newTestStore(t)
	s, f := newTestService(t, st)
	mux := newMux(s)
	ctx := context.Background()

	rec := do(mux, "GET", "/einstellungen/kurse", nil)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "Manuelle Kurse") ||
		!strings.Contains(rec.Body.String(), "Noch keine EZB-Kurse") || !strings.Contains(rec.Body.String(), "Vorrang") {
		t.Fatalf("GET: %d %s", rec.Code, rec.Body)
	}

	rec = do(mux, "POST", "/einstellungen/kurse", url.Values{"waehrung": {"thb"}, "datum": {"2026-09-01"}, "kurs": {"38,02"}})
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/einstellungen/kurse" {
		t.Fatalf("POST: %d %s", rec.Code, rec.Body)
	}
	if r, err := st.LookupFXRate(ctx, "THB", domain.FXSourceManual, day("2026-10-01"), time.Time{}); err != nil || r.Rate != 38.02 {
		t.Errorf("gespeichert: %+v, %v", r, err)
	}
	rec = do(mux, "POST", "/einstellungen/kurse", url.Values{"waehrung": {"IDR"}, "datum": {"02.09.2026"}, "kurs": {"20.274,71"}})
	if rec.Code != http.StatusSeeOther {
		t.Errorf("POST IDR: %d", rec.Code)
	}
	if r, _ := st.LookupFXRate(ctx, "IDR", domain.FXSourceManual, day("2026-10-01"), time.Time{}); r.Rate != 20274.71 {
		t.Errorf("IDR = %v", r.Rate)
	}

	for _, bad := range []url.Values{
		{"waehrung": {"TH"}, "datum": {"2026-09-01"}, "kurs": {"38"}},
		{"waehrung": {"THB"}, "datum": {""}, "kurs": {"38"}},
		{"waehrung": {"THB"}, "datum": {"2026-09-01"}, "kurs": {"0"}},
		{"waehrung": {"THB"}, "datum": {"2026-09-01"}, "kurs": {"abc"}},
	} {
		rec = do(mux, "POST", "/einstellungen/kurse", bad)
		if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "alert-destructive") {
			t.Errorf("POST %v: %d", bad, rec.Code)
		}
	}

	rec = do(mux, "GET", "/einstellungen/kurse", nil)
	if !strings.Contains(rec.Body.String(), "38,02 THB") {
		t.Errorf("Liste ohne manuellen Kurs: %s", rec.Body)
	}

	rec = do(mux, "POST", "/einstellungen/kurse/loeschen", url.Values{"waehrung": {"THB"}, "datum": {"2026-09-01"}})
	if rec.Code != http.StatusSeeOther {
		t.Errorf("Löschen: %d", rec.Code)
	}
	rec = do(mux, "POST", "/einstellungen/kurse/loeschen", url.Values{"waehrung": {"THB"}, "datum": {"2026-09-01"}})
	if rec.Code != http.StatusNotFound {
		t.Errorf("zweites Löschen: %d", rec.Code)
	}

	rec = do(mux, "POST", "/einstellungen/kurse/aktualisieren", nil)
	if rec.Code != http.StatusSeeOther || f.count(file90d) != 1 {
		t.Errorf("Aktualisieren: %d %v", rec.Code, f.hits)
	}
	rec = do(mux, "GET", "/einstellungen/kurse", nil)
	if !strings.Contains(rec.Body.String(), "1,1298 USD") || !strings.Contains(rec.Body.String(), "bis 01.10.2026") {
		t.Errorf("EZB-Liste fehlt: %s", rec.Body)
	}

	f.err = errors.New("timeout")
	rec = do(mux, "POST", "/einstellungen/kurse/aktualisieren", nil)
	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "nicht geladen werden") {
		t.Errorf("Aktualisieren mit Fehler: %d", rec.Code)
	}
}
