package fx

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/csv"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
)

// ECB files (https://www.ecb.europa.eu/stats/eurofxref/).
const (
	defaultBaseURL = "https://www.ecb.europa.eu/stats/eurofxref/"
	fileDaily      = "eurofxref-daily.xml"    // last business day
	file90d        = "eurofxref-hist-90d.xml" // about 90 calendar days
	fileHist       = "eurofxref-hist.zip"     // everything since 1999 (CSV in a ZIP)

	userAgent   = "zipfelkasse/1.0 (self-hosted expense tracker; ECB reference rates)"
	maxBodySize = 32 << 20

	// After a fetch, the same file is loaded again only after this time at the
	// earliest (except for an explicit refresh).
	cooldownOK    = 15 * time.Minute
	cooldownError = time.Minute

	// settingHistUntil: the latest day from eurofxref-hist.zip, if it has been
	// loaded completely before. Older days are fully cached.
	settingHistUntil = "fx.ezb_hist_bis"
)

// FetchError means the ECB rates could not be loaded (network, HTTP status,
// broken file). Its message is shown to the user.
type FetchError struct {
	File string
	Err  error
}

func (e *FetchError) Error() string {
	return fmt.Sprintf("Die EZB-Kurse konnten nicht geladen werden (%v). Bitte später erneut versuchen oder den Kurs von Hand eintragen.", e.Err)
}

func (e *FetchError) Unwrap() error { return e.Err }

// loadResult describes a loaded file.
type loadResult struct {
	From, To   time.Time       // earliest/latest day in the file
	Currencies map[string]bool // all currencies in the file
	Count      int             // number of rates
}

func (r loadResult) covers(d time.Time) bool {
	return !r.From.IsZero() && !d.Before(r.From)
}

// load is a (running or finished) fetch of a file.
type load struct {
	done chan struct{}
	at   time.Time // end of the fetch
	res  loadResult
	err  error
}

// fetch loads file from the ECB and stores the rates in the cache. The same
// file is never loaded concurrently: further callers wait for the running
// fetch. Shortly after a fetch, fetch returns its result again without
// loading (force bypasses this). The fetch runs to completion independently
// of ctx (the HTTP client has a timeout); ctx only limits the waiting. On
// shutdown (end of Run), fetches are cancelled and no new ones are started.
func (s *Service) fetch(ctx context.Context, file string, force bool) (loadResult, error) {
	s.mu.Lock()
	l := s.loads[file]
	if l != nil {
		select {
		case <-l.done:
			cool := cooldownOK
			if l.err != nil {
				cool = cooldownError
			}
			if !force && s.now().Sub(l.at) < cool {
				s.mu.Unlock()
				return l.res, l.err
			}
			l = nil
		default: // still running
		}
	}
	if l == nil {
		if err := s.bgCtx.Err(); err != nil {
			s.mu.Unlock()
			return loadResult{}, &FetchError{File: file, Err: err}
		}
		l = &load{done: make(chan struct{})}
		s.loads[file] = l
		s.bg.Go(func() {
			res, err := s.download(s.bgCtx, file)
			if err != nil {
				s.d.Log.Warn("loading ECB rates failed", "file", file, "err", err)
				err = &FetchError{File: file, Err: err}
			} else {
				s.d.Log.Info("ECB rates loaded", "file", file, "rates", res.Count,
					"from", res.From.Format(domain.DateLayout), "to", res.To.Format(domain.DateLayout))
			}
			s.mu.Lock()
			l.res, l.err, l.at = res, err, s.now()
			s.mu.Unlock()
			close(l.done)
		})
	}
	s.mu.Unlock()
	select {
	case <-l.done:
		return l.res, l.err
	case <-ctx.Done():
		return loadResult{}, ctx.Err()
	}
}

// download fetches file, parses it and stores the rates.
func (s *Service) download(ctx context.Context, file string) (loadResult, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.baseURL+file, nil)
	if err != nil {
		return loadResult{}, err
	}
	req.Header.Set("User-Agent", userAgent)
	res, err := s.client.Do(req)
	if err != nil {
		return loadResult{}, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return loadResult{}, fmt.Errorf("HTTP status %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, maxBodySize))
	if err != nil {
		return loadResult{}, err
	}
	var rates []domain.FXRate
	if strings.HasSuffix(file, ".zip") {
		rates, err = parseHistZip(body)
	} else {
		rates, err = parseXML(bytes.NewReader(body))
	}
	if err != nil {
		return loadResult{}, err
	}
	if len(rates) == 0 {
		return loadResult{}, errors.New("file contains no rates")
	}
	if err := s.d.Store.SaveECBRates(ctx, rates); err != nil {
		return loadResult{}, err
	}
	r := summarize(rates)
	if file == fileHist {
		if err := s.d.Store.SetSetting(ctx, settingHistUntil, r.To.Format(domain.DateLayout)); err != nil {
			return loadResult{}, err
		}
	}
	return r, nil
}

func summarize(rates []domain.FXRate) loadResult {
	r := loadResult{Currencies: map[string]bool{}, Count: len(rates)}
	for _, x := range rates {
		r.Currencies[x.Currency] = true
		if r.From.IsZero() || x.Date.Before(r.From) {
			r.From = x.Date
		}
		if x.Date.After(r.To) {
			r.To = x.Date
		}
	}
	return r
}

// histUntil returns the latest day from an earlier complete import (zero
// value if eurofxref-hist.zip has never been loaded).
func (s *Service) histUntil(ctx context.Context) time.Time {
	v, err := s.d.Store.GetSetting(ctx, settingHistUntil)
	if err != nil {
		return time.Time{}
	}
	t, _ := time.Parse(domain.DateLayout, v)
	return t
}

// --- Parser ----------------------------------------------------------------

// ecbEnvelope is eurofxref-daily.xml or eurofxref-hist-90d.xml:
// <gesmes:Envelope><Cube><Cube time="…"><Cube currency="USD" rate="1.1"/>…
type ecbEnvelope struct {
	Days []struct {
		Time  string `xml:"time,attr"`
		Rates []struct {
			Currency string `xml:"currency,attr"`
			Rate     string `xml:"rate,attr"`
		} `xml:"Cube"`
	} `xml:"Cube>Cube"`
}

func parseXML(r io.Reader) ([]domain.FXRate, error) {
	var env ecbEnvelope
	if err := xml.NewDecoder(r).Decode(&env); err != nil {
		return nil, fmt.Errorf("xml: %w", err)
	}
	var out []domain.FXRate
	for _, day := range env.Days {
		d, err := time.Parse(domain.DateLayout, strings.TrimSpace(day.Time))
		if err != nil {
			return nil, fmt.Errorf("xml: date %q: %w", day.Time, err)
		}
		for _, c := range day.Rates {
			if rate, ok := parseECBRate(c.Rate); ok && store.ValidCurrencyCode(c.Currency) {
				out = append(out, domain.FXRate{Currency: c.Currency, Date: d, Rate: rate, Source: domain.FXSourceECB})
			}
		}
	}
	return out, nil
}

// parseHistZip reads eurofxref-hist.csv from the ZIP:
// "Date,USD,JPY,…," followed by "2026-10-01,1.1298,178.49,N/A,…,".
func parseHistZip(b []byte) ([]domain.FXRate, error) {
	zr, err := zip.NewReader(bytes.NewReader(b), int64(len(b)))
	if err != nil {
		return nil, fmt.Errorf("zip: %w", err)
	}
	for _, f := range zr.File {
		if !strings.EqualFold(path.Ext(f.Name), ".csv") {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return nil, fmt.Errorf("zip: %w", err)
		}
		defer rc.Close()
		return parseHistCSV(io.LimitReader(rc, 4*maxBodySize))
	}
	return nil, errors.New("zip: no CSV file found")
}

func parseHistCSV(r io.Reader) ([]domain.FXRate, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	cr.TrimLeadingSpace = true
	header, err := cr.Read()
	if err != nil {
		return nil, fmt.Errorf("csv: header: %w", err)
	}
	if len(header) == 0 || !strings.EqualFold(strings.TrimSpace(strings.TrimPrefix(header[0], "\uFEFF")), "Date") {
		return nil, fmt.Errorf("csv: unexpected header %q", header)
	}
	curs := make([]string, len(header))
	for i, h := range header[1:] {
		curs[i+1] = strings.TrimSpace(h)
	}
	var out []domain.FXRate
	for {
		rec, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("csv: %w", err)
		}
		if len(rec) == 0 || strings.TrimSpace(rec[0]) == "" {
			continue
		}
		d, err := time.Parse(domain.DateLayout, strings.TrimSpace(rec[0]))
		if err != nil {
			return nil, fmt.Errorf("csv: date %q: %w", rec[0], err)
		}
		for i := 1; i < len(rec) && i < len(curs); i++ {
			if rate, ok := parseECBRate(rec[i]); ok && store.ValidCurrencyCode(curs[i]) {
				out = append(out, domain.FXRate{Currency: curs[i], Date: d, Rate: rate, Source: domain.FXSourceECB})
			}
		}
	}
	return out, nil
}

// parseECBRate reads "1.1298"; "N/A", empty or ≤ 0 → false.
func parseECBRate(s string) (float64, bool) {
	f, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil || !(f > 0) || f > 1e12 {
		return 0, false
	}
	return f, true
}
