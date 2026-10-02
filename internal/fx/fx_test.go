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

	"github.com/shostakovich/zipfelkasse/internal/config"
	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

// fakeECB answers requests to the ECB from testdata (http.RoundTripper, no
// port needed).
type fakeECB struct {
	mu     sync.Mutex
	files  map[string][]byte
	hits   map[string]int
	err    error         // simulate a network error
	status int           // != 0: return this HTTP status
	block  chan struct{} // != nil: respond only after close
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
		select {
		case <-block:
		case <-req.Context().Done():
			return nil, req.Context().Err()
		}
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

// at returns a clock that always shows t (Europe/Berlin, "2006-01-02 15:04").
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

// newTestService: today is Friday, 2026-10-02, 12:00 (the day's rates are
// not yet published).
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
		t.Errorf("loaded without need: %v", f.hits)
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
		t.Errorf("fetches = %v", f.hits)
	}
	if !strings.HasPrefix(f.agents[0], "zipfelkasse/") {
		t.Errorf("User-Agent = %q", f.agents[0])
	}
	// Today before 16:30: yesterday's rate is the latest → from the cache.
	r, err = s.Rate(ctx, "USD", day("2026-10-02"))
	if err != nil || r.Date != day("2026-10-01") {
		t.Errorf("today = %+v, %v", r, err)
	}
	// Future → latest rate.
	r, err = s.Rate(ctx, "GBP", day("2026-12-24"))
	if err != nil || r.Rate != 0.85373 {
		t.Errorf("future = %+v, %v", r, err)
	}
	if f.total() != 1 {
		t.Errorf("cache not used: %v", f.hits)
	}
}

func TestRateOlderUses90d(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	ctx := context.Background()
	// Sunday → rate of the Friday before.
	r, err := s.Rate(ctx, "JPY", day("2026-09-27"))
	if err != nil || r.Rate != 176.5 || r.Date != day("2026-09-25") {
		t.Fatalf("JPY = %+v, %v", r, err)
	}
	if f.count(file90d) != 1 || f.total() != 1 {
		t.Errorf("fetches = %v", f.hits)
	}
	// Now cached, also for other days.
	if r, err := s.Rate(ctx, "USD", day("2026-09-29")); err != nil || r.Rate != 1.1251 {
		t.Errorf("USD = %+v, %v", r, err)
	}
	if f.total() != 1 {
		t.Errorf("fetches = %v", f.hits)
	}
}

func TestRateDailyEscalatesTo90d(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	s.now = at("2026-10-02 17:00")
	f.files[fileDaily] = []byte(`<?xml version="1.0"?><gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref"><Cube><Cube time="2026-10-02"><Cube currency="USD" rate="1.1311"/></Cube></Cube></gesmes:Envelope>`)
	ctx := context.Background()
	r, err := s.Rate(ctx, "USD", day("2026-10-01"))
	if err != nil || r.Rate != 1.1298 || r.Date != day("2026-10-01") {
		t.Fatalf("yesterday = %+v, %v", r, err)
	}
	if f.count(fileDaily) != 1 || f.count(file90d) != 1 {
		t.Errorf("fetches = %v", f.hits)
	}
	if r, err := s.Rate(ctx, "USD", day("2026-10-02")); err != nil || r.Rate != 1.1311 {
		t.Errorf("today = %+v, %v", r, err)
	}
	if f.total() != 2 {
		t.Errorf("fetches = %v", f.hits)
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
		t.Errorf("fetches = %v", f.hits)
	}
	// Weekend → the Friday before; everything from the cache.
	if r, err := s.Rate(ctx, "GBP", day("2022-03-06")); err != nil || r.Rate != 0.836 || r.Date != day("2022-03-01") {
		t.Errorf("2022 = %+v, %v", r, err)
	}
	// RUB has not been quoted since March 2022.
	if _, err := s.Rate(ctx, "RUB", day("2024-01-03")); !isValidation(err, "um den 03.01.2024 keinen EZB-Kurs") {
		t.Errorf("RUB 2024 = %v", err)
	}
	if _, err := s.Rate(ctx, "XYZ", day("2024-01-03")); !isValidation(err, "Für XYZ gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen.") {
		t.Errorf("XYZ = %v", err)
	}
	if f.total() != 1 {
		t.Errorf("fetches = %v", f.hits)
	}

	// Restart: the history is already cached and is not loaded again.
	s2, f2 := newTestService(t, st)
	if r, err := s2.Rate(ctx, "USD", day("2024-01-02")); err != nil || r.Rate != 1.0956 {
		t.Errorf("after restart = %+v, %v", r, err)
	}
	if _, err := s2.Rate(ctx, "JPY", day("1998-12-31")); !isValidation(err, "keinen EZB-Kurs") {
		t.Errorf("before 1999 = %v", err)
	}
	if f2.total() != 0 {
		t.Errorf("history loaded again: %v", f2.hits)
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
		t.Errorf("fetches = %v (must not reload shortly after a fetch)", f.hits)
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
		t.Errorf("manual = %+v, %v", r, err)
	}
	if r, err := s.Rate(ctx, "XYZ", day("2026-06-01")); err != nil || r.Rate != 4.5 {
		t.Errorf("XYZ manual = %+v, %v", r, err)
	}
	if f.total() != 0 {
		t.Errorf("loaded despite manual rate: %v", f.hits)
	}
	// Before the manual rate, the ECB rate applies.
	r, err = s.Rate(ctx, "USD", day("2026-09-29"))
	if err != nil || r.Rate != 1.1251 || r.Source != domain.FXSourceECB {
		t.Errorf("before manual = %+v, %v", r, err)
	}
}

func TestRateFetchErrors(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	ctx := context.Background()
	f.err = errors.New("connection refused")
	_, err := s.Rate(ctx, "USD", day("2026-10-01"))
	var fe *FetchError
	if !errors.As(err, &fe) || !strings.Contains(err.Error(), "nicht geladen werden") {
		t.Fatalf("network error = %v", err)
	}
	// Shortly afterwards: no new attempt.
	s.Rate(ctx, "USD", day("2026-10-01"))
	if f.total() != 1 {
		t.Errorf("fetches = %v", f.hits)
	}
	// After the cooldown again, now with an HTTP error.
	s.now = at("2026-10-02 12:05")
	f.err, f.status = nil, http.StatusInternalServerError
	if _, err := s.Rate(ctx, "USD", day("2026-10-01")); !errors.As(err, &fe) || !strings.Contains(err.Error(), "500") {
		t.Errorf("HTTP 500 = %v", err)
	}
	// Broken file.
	s.now = at("2026-10-02 12:10")
	f.status = 0
	f.files[fileDaily] = []byte("<broken")
	if _, err := s.Rate(ctx, "USD", day("2026-10-01")); !errors.As(err, &fe) {
		t.Errorf("broken XML = %v", err)
	}
	if f.count(fileDaily) != 3 {
		t.Errorf("fetches = %v", f.hits)
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
				err = errors.New("wrong rate")
			}
			errs <- err
		})
	}
	for f.total() == 0 {
		time.Sleep(time.Millisecond)
	}
	time.Sleep(20 * time.Millisecond) // let the others wait
	close(f.block)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Error(err)
		}
	}
	if f.total() != 1 {
		t.Errorf("file loaded more than once: %v", f.hits)
	}
}

func TestFetchContextCancel(t *testing.T) {
	s, f := newTestService(t, newTestStore(t))
	f.block = make(chan struct{})
	defer close(f.block)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, err := s.Rate(ctx, "USD", day("2026-10-01")); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("cancel = %v", err)
	}
}

func TestRefresh(t *testing.T) {
	st := newTestStore(t)
	s, f := newTestService(t, st)
	ctx := context.Background()
	// Empty cache → 90-day file.
	latest, err := s.Refresh(ctx)
	if err != nil || latest != day("2026-10-01") || f.count(file90d) != 1 {
		t.Fatalf("Refresh = %v, %v, %v", latest, err, f.hits)
	}
	// Current cache → daily file, even shortly after the last fetch (force).
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
			t.Errorf("Easter %d = %s, want %s", y, got.Format(domain.DateLayout), want)
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
		t.Errorf("lastBusinessDay(Easter Monday) = %s", got)
	}
	for now, want := range map[string]string{
		"2026-10-02 12:00": "2026-10-02 16:30",
		"2026-10-02 16:30": "2026-10-05 16:30",
		"2026-10-02 17:00": "2026-10-05 16:30",
		"2026-12-24 17:00": "2026-12-28 16:30",
		"2026-03-28 10:00": "2026-03-30 16:30", // DST change on 29 March
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
	// N/A and empty columns are skipped.
	n := map[string]int{}
	for _, r := range rates {
		n[r.Currency]++
	}
	if n["USD"] != 6 || n["CYP"] != 1 || n["RUB"] != 2 || n["BGN"] != 4 || n[""] != 0 {
		t.Errorf("CSV currencies = %v", n)
	}
	if _, err := parseHistCSV(strings.NewReader("Foo,USD\n")); err == nil {
		t.Error("wrong header without error")
	}
	if _, err := parseHistZip([]byte("not a zip")); err == nil {
		t.Error("broken ZIP without error")
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
		t.Errorf("network error: %d %s", rec.Code, rec.Body)
	}
	_ = f
}

func TestSettingsPage(t *testing.T) {
	st := newTestStore(t)
	s, f := newTestService(t, st)
	ctx := context.Background()
	annaID, err := st.CreateParticipant(ctx, "Anna")
	if err != nil {
		t.Fatal(err)
	}
	anna, _ := st.GetParticipant(ctx, annaID)
	inner := newMux(s)
	mux := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		inner.ServeHTTP(w, r.WithContext(web.WithMe(r.Context(), anna)))
	})

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
		t.Errorf("saved: %+v, %v", r, err)
	}
	rec = do(mux, "POST", "/einstellungen/kurse", url.Values{"waehrung": {"IDR"}, "datum": {"02.09.2026"}, "kurs": {"20.274,71"}})
	if rec.Code != http.StatusSeeOther {
		t.Errorf("POST IDR: %d", rec.Code)
	}
	if r, _ := st.LookupFXRate(ctx, "IDR", domain.FXSourceManual, day("2026-10-01"), time.Time{}); r.Rate != 20274.71 {
		t.Errorf("IDR = %v", r.Rate)
	}
	// Thousands separator as for amounts: "17.000" = 17000, also English
	// "17,000.5"; after a leading zero the dot is a decimal point.
	for _, tt := range []struct {
		in   string
		want float64
	}{{"0.856", 0.856}, {"17.000", 17000}, {"17,000.5", 17000.5}} {
		rec = do(mux, "POST", "/einstellungen/kurse", url.Values{"waehrung": {"VND"}, "datum": {"2026-09-03"}, "kurs": {tt.in}})
		if r, _ := st.LookupFXRate(ctx, "VND", domain.FXSourceManual, day("2026-10-01"), time.Time{}); rec.Code != http.StatusSeeOther || r.Rate != tt.want {
			t.Errorf("VND %q: %d, %v", tt.in, rec.Code, r.Rate)
		}
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
		t.Errorf("list without manual rate: %s", rec.Body)
	}

	if text := lastActivity(t, st); text != "Manueller Kurs für VND ab 03.09.2026 gespeichert: 1 € = 17000,5 VND" {
		t.Errorf("activity = %q", text)
	}
	rec = do(mux, "POST", "/einstellungen/kurse/loeschen", url.Values{"waehrung": {"THB"}, "datum": {"2026-09-01"}})
	if rec.Code != http.StatusSeeOther {
		t.Errorf("delete: %d", rec.Code)
	}
	if text := lastActivity(t, st); text != "Manueller Kurs für THB ab 01.09.2026 gelöscht" {
		t.Errorf("activity = %q", text)
	}
	rec = do(mux, "POST", "/einstellungen/kurse/loeschen", url.Values{"waehrung": {"THB"}, "datum": {"2026-09-01"}})
	if rec.Code != http.StatusNotFound {
		t.Errorf("second delete: %d", rec.Code)
	}

	rec = do(mux, "POST", "/einstellungen/kurse/aktualisieren", nil)
	if rec.Code != http.StatusSeeOther || f.count(file90d) != 1 {
		t.Errorf("refresh: %d %v", rec.Code, f.hits)
	}
	rec = do(mux, "GET", "/einstellungen/kurse", nil)
	if !strings.Contains(rec.Body.String(), "1,1298 USD") || !strings.Contains(rec.Body.String(), "bis 01.10.2026") {
		t.Errorf("ECB list missing: %s", rec.Body)
	}

	f.err = errors.New("timeout")
	rec = do(mux, "POST", "/einstellungen/kurse/aktualisieren", nil)
	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "nicht geladen werden") {
		t.Errorf("refresh with error: %d", rec.Code)
	}
}

// lastActivity returns the text of the latest activity entry
// ("settings_updated", otherwise "").
func lastActivity(t *testing.T, st *store.Store) string {
	t.Helper()
	acts, err := st.ListActivity(context.Background(), store.ActivityFilter{Limit: 1})
	if err != nil || len(acts) != 1 || acts[0].Action != store.ActionSettingsUpdated || acts[0].ActorID == 0 {
		t.Errorf("Activity = %+v, %v", acts, err)
		return ""
	}
	return acts[0].Details.Text
}

// Run returns only once no ECB fetch is running anymore; main closes the
// store afterwards.
func TestRunWaitsForDownloads(t *testing.T) {
	st := newTestStore(t)
	s, f := newTestService(t, st)
	block := make(chan struct{})
	t.Cleanup(func() { close(block) })
	f.mu.Lock()
	f.block = block
	f.mu.Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	runDone := make(chan struct{})
	go func() { s.Run(ctx); close(runDone) }()
	deadline := time.Now().Add(2 * time.Second)
	for f.total() == 0 { // empty cache: Run loads immediately
		if time.Now().After(deadline) {
			t.Fatal("Run does not load")
		}
		time.Sleep(time.Millisecond)
	}
	cancel()
	select {
	case <-runDone:
	case <-time.After(2 * time.Second):
		t.Fatal("Run hangs")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for file, l := range s.loads {
		select {
		case <-l.done:
		default:
			t.Errorf("fetch %s still running after Run", file)
		}
	}
}
