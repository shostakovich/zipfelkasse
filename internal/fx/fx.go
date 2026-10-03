// Package fx provides exchange rates (ECB reference rates cached in SQLite,
// manual rates) and the GET /api/kurs endpoint for the expense form.
//
// Rules for Rate(currency, date):
//   - EUR → 1 (source "fest").
//   - Manual rates take precedence: the most recent manual rate whose
//     "valid from" ≤ date applies, until a newer manual rate is entered.
//   - Otherwise the ECB rate of that date or of the last business day before
//     it (up to lookbackDays back). If it is missing from the cache, it is
//     fetched: the daily file for today/yesterday, the 90-day file for recent
//     dates, otherwise the complete history once (eurofxref-hist.zip).
package fx

import (
	"context"
	"embed"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

//go:embed templates/*.html
var templatesFS embed.FS

// lookbackDays is the maximum number of days an ECB rate may lie before the
// requested date (weekends, holidays).
const lookbackDays = 10

// Service implements web.FXRater.
type Service struct {
	d       web.Deps
	pages   *web.Pages
	client  *http.Client
	baseURL string
	now     func() time.Time // overridable in tests
	berlin  *time.Location   // time zone of the ECB publication

	mu    sync.Mutex
	loads map[string]*load // last or running fetch per file

	// Fetches run in their own goroutines with bgCtx (independent of the
	// request). Run cancels them on shutdown and waits for them, so that
	// main closes the store only afterwards.
	bgCtx    context.Context
	bgCancel context.CancelFunc
	bg       sync.WaitGroup
}

var _ web.FXRater = (*Service)(nil)

// New creates the service. main then sets it as Deps.FX.
func New(d web.Deps) (*Service, error) {
	pages, err := d.Render.Load(templatesFS, "templates/*.html")
	if err != nil {
		return nil, err
	}
	berlin, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		berlin = time.FixedZone("CET", 3600)
	}
	s := &Service{
		d:       d,
		pages:   pages,
		client:  &http.Client{Timeout: 60 * time.Second},
		baseURL: defaultBaseURL,
		now:     d.Config.Clock(),
		berlin:  berlin,
		loads:   map[string]*load{},
	}
	if d.Config.ECBBaseURL != "" {
		s.baseURL = d.Config.ECBBaseURL
	}
	s.bgCtx, s.bgCancel = context.WithCancel(context.Background())
	return s, nil
}

// stop cancels running fetches, waits for them and prevents new ones.
func (s *Service) stop() {
	s.mu.Lock()
	s.bgCancel()
	s.mu.Unlock()
	s.bg.Wait()
}

// today returns today's date in the configured time zone.
func (s *Service) today() time.Time {
	loc := s.d.Config.Location
	if loc == nil {
		loc = time.Local
	}
	return domain.DateOf(s.now().In(loc))
}

// expectedDate is the latest day ≤ date for which the ECB should already have
// published rates.
func (s *Service) expectedDate(date time.Time) time.Time {
	now := s.now().In(s.berlin)
	if todayBerlin := domain.DateOf(now); !date.Before(todayBerlin) {
		date = todayBerlin
		if now.Hour()*60+now.Minute() < publishHour*60+publishMinute {
			date = date.AddDate(0, 0, -1)
		}
	}
	return lastBusinessDay(date)
}

// Rate returns the rate for currency on date (ECB format: units of foreign
// currency per 1 EUR). Errors: domain.ValidationError (invalid currency, no
// rate available; the text can be shown as is), *FetchError (ECB not
// reachable) or a database error.
func (s *Service) Rate(ctx context.Context, currency string, date time.Time) (domain.FXRate, error) {
	cur := strings.ToUpper(strings.TrimSpace(currency))
	date = domain.DateOf(date)
	if cur == "EUR" {
		return domain.FXRate{Currency: "EUR", Date: date, Rate: 1, Source: domain.FXSourceFixed}, nil
	}
	if !domain.ValidCurrencyCode(cur) {
		if cur == "" {
			return domain.FXRate{}, domain.ValidationError{Msg: "Bitte eine Währung angeben."}
		}
		return domain.FXRate{}, domain.ValidationError{Msg: "Ungültige Währung „" + currency + "“."}
	}
	if today := s.today(); date.After(today) {
		date = today // future: latest rate
	}
	st := s.d.Store

	// 1. Manual rates take precedence.
	r, err := st.LookupFXRate(ctx, cur, domain.FXSourceManual, date, time.Time{})
	if err == nil {
		return r, nil
	}
	if !errors.Is(err, store.ErrNotFound) {
		return r, err
	}

	// 2. ECB cache.
	window := date.AddDate(0, 0, -lookbackDays)
	histUntil := s.histUntil(ctx)
	r, err = st.LookupFXRate(ctx, cur, domain.FXSourceECB, date, window)
	switch {
	case err == nil && (!r.Date.Before(s.expectedDate(date)) || !date.After(histUntil)):
		return r, nil
	case err != nil && !errors.Is(err, store.ErrNotFound):
		return r, err
	case err != nil && !date.After(histUntil):
		return r, s.noRate(ctx, cur, date, nil)
	}

	// 3. Fetch: the matching file, the next larger one if needed.
	var res loadResult
	var fetchErr error
	for _, file := range filesFor(date, s.today()) {
		if file == fileHist && !date.After(s.histUntil(ctx)) {
			break // already fully cached
		}
		res, fetchErr = s.fetch(ctx, file, false)
		if fetchErr != nil || res.covers(date) {
			break
		}
	}
	r, err = st.LookupFXRate(ctx, cur, domain.FXSourceECB, date, window)
	switch {
	case err == nil:
		return r, nil
	case !errors.Is(err, store.ErrNotFound):
		return r, err
	case fetchErr != nil:
		return r, fetchErr
	}
	return r, s.noRate(ctx, cur, date, res.Currencies)
}

// noRate builds the "no ECB rate" error: if the ECB does not know the
// currency at all, it says so; otherwise only the rate for the date is missing.
func (s *Service) noRate(ctx context.Context, cur string, date time.Time, fetched map[string]bool) error {
	known := fetched[cur]
	if !known {
		var err error
		if known, err = s.d.Store.HasECBCurrency(ctx, cur); err != nil {
			return err
		}
	}
	if !known {
		return domain.ValidationError{Msg: "Für " + cur + " gibt es keinen EZB-Kurs – bitte Kurs von Hand eintragen."}
	}
	return domain.ValidationError{Msg: "Für " + cur + " gibt es um den " + domain.FormatDate(date) +
		" keinen EZB-Kurs – bitte Kurs von Hand eintragen."}
}

// filesFor returns the files that, in order, may contain date.
func filesFor(date, today time.Time) []string {
	age := int(today.Sub(date).Hours() / 24)
	switch {
	case age <= 1:
		return []string{fileDaily, file90d, fileHist}
	case age < 85:
		return []string{file90d, fileHist}
	}
	return []string{fileHist}
}

// Refresh loads the latest ECB rates (daily file; the 90-day file if the cache
// has gaps) and returns the most recent rate date.
func (s *Service) Refresh(ctx context.Context) (time.Time, error) {
	stats, err := s.d.Store.ECBCacheStats(ctx)
	if err != nil {
		return time.Time{}, err
	}
	file := fileDaily
	expected := s.expectedDate(s.today())
	if stats.To.IsZero() || stats.To.Before(lastBusinessDay(expected.AddDate(0, 0, -1))) {
		file = file90d
	}
	res, err := s.fetch(ctx, file, true)
	if err != nil {
		return time.Time{}, err
	}
	return res.To, nil
}

// Run fetches missing daily rates on startup and then the new ones on every
// business day after 16:30 (Europe/Berlin). Errors are only logged. Blocks
// until ctx is done.
func (s *Service) Run(ctx context.Context) {
	defer s.stop()
	if stats, err := s.d.Store.ECBCacheStats(ctx); err == nil && stats.To.Before(s.expectedDate(s.today())) {
		s.refreshLogged(ctx)
	}
	retries := 0
	for {
		wait := time.Until(nextPublish(s.now().In(s.berlin)))
		if retries > 0 {
			wait = time.Hour
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		latest := s.refreshLogged(ctx)
		// Not yet published or failed: retry hourly, up to three times.
		if latest.Before(s.expectedDate(s.today())) && retries < 3 {
			retries++
		} else {
			retries = 0
		}
	}
}

func (s *Service) refreshLogged(ctx context.Context) time.Time {
	latest, err := s.Refresh(ctx)
	if err != nil && ctx.Err() == nil {
		s.d.Log.Error("refresh ECB rates", "err", err)
	}
	return latest
}
