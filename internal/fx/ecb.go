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

	"teilen/internal/domain"
	"teilen/internal/store"
)

// Dateien der EZB (https://www.ecb.europa.eu/stats/eurofxref/).
const (
	defaultBaseURL = "https://www.ecb.europa.eu/stats/eurofxref/"
	fileDaily      = "eurofxref-daily.xml"    // letzter Geschäftstag
	file90d        = "eurofxref-hist-90d.xml" // ca. 90 Kalendertage
	fileHist       = "eurofxref-hist.zip"     // alles seit 1999 (CSV im ZIP)

	userAgent   = "teilen/1.0 (selbst gehostete Ausgabenverwaltung; EZB-Referenzkurse)"
	maxBodySize = 32 << 20

	// Nach einem Abruf wird dieselbe Datei frühestens nach dieser Zeit erneut
	// geladen (außer bei ausdrücklicher Aktualisierung).
	cooldownOK    = 15 * time.Minute
	cooldownError = time.Minute

	// settingHistUntil: jüngster Tag aus eurofxref-hist.zip, falls schon
	// einmal komplett geladen. Ältere Tage stehen vollständig im Cache.
	settingHistUntil = "fx.ezb_hist_bis"
)

// FetchError: Die EZB-Kurse konnten nicht geladen werden (Netzwerk, HTTP-Status,
// kaputte Datei).
type FetchError struct {
	File string
	Err  error
}

func (e *FetchError) Error() string {
	return fmt.Sprintf("Die EZB-Kurse konnten nicht geladen werden (%v). Bitte später erneut versuchen oder den Kurs von Hand eintragen.", e.Err)
}

func (e *FetchError) Unwrap() error { return e.Err }

// loadResult beschreibt eine geladene Datei.
type loadResult struct {
	From, To   time.Time       // ältester/jüngster Tag in der Datei
	Currencies map[string]bool // alle Währungen der Datei
	Count      int             // Anzahl Kurse
}

func (r loadResult) covers(d time.Time) bool {
	return !r.From.IsZero() && !d.Before(r.From)
}

// load ist ein (laufender oder beendeter) Abruf einer Datei.
type load struct {
	done chan struct{}
	at   time.Time // Ende des Abrufs
	res  loadResult
	err  error
}

// fetch lädt file von der EZB und speichert die Kurse im Cache. Dieselbe
// Datei wird nie parallel geladen: Weitere Aufrufer warten auf den laufenden
// Abruf. Kurz nach einem Abruf liefert fetch dessen Ergebnis erneut, ohne zu
// laden (force umgeht das). Der Abruf läuft unabhängig von ctx zu Ende (der
// HTTP-Client hat ein Timeout), ctx begrenzt nur das Warten.
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
		default: // läuft noch
		}
	}
	if l == nil {
		l = &load{done: make(chan struct{})}
		s.loads[file] = l
		go func() {
			res, err := s.download(context.WithoutCancel(ctx), file)
			if err != nil {
				s.d.Log.Warn("EZB-Kurse laden fehlgeschlagen", "datei", file, "err", err)
				err = &FetchError{File: file, Err: err}
			} else {
				s.d.Log.Info("EZB-Kurse geladen", "datei", file, "kurse", res.Count,
					"von", res.From.Format(domain.DateLayout), "bis", res.To.Format(domain.DateLayout))
			}
			s.mu.Lock()
			l.res, l.err, l.at = res, err, s.now()
			s.mu.Unlock()
			close(l.done)
		}()
	}
	s.mu.Unlock()
	select {
	case <-l.done:
		return l.res, l.err
	case <-ctx.Done():
		return loadResult{}, ctx.Err()
	}
}

// download holt file, parst es und speichert die Kurse.
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
		return loadResult{}, fmt.Errorf("HTTP-Status %d", res.StatusCode)
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
		return loadResult{}, errors.New("datei enthält keine kurse")
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

// histUntil liefert den jüngsten Tag aus einem früheren Komplett-Import
// (Nullwert, wenn eurofxref-hist.zip noch nie geladen wurde).
func (s *Service) histUntil(ctx context.Context) time.Time {
	v, err := s.d.Store.GetSetting(ctx, settingHistUntil)
	if err != nil {
		return time.Time{}
	}
	t, _ := time.Parse(domain.DateLayout, v)
	return t
}

// --- Parser ----------------------------------------------------------------

// ecbEnvelope ist eurofxref-daily.xml bzw. eurofxref-hist-90d.xml:
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
			return nil, fmt.Errorf("xml: datum %q: %w", day.Time, err)
		}
		for _, c := range day.Rates {
			if rate, ok := parseECBRate(c.Rate); ok && store.ValidCurrencyCode(c.Currency) {
				out = append(out, domain.FXRate{Currency: c.Currency, Date: d, Rate: rate, Source: domain.FXSourceECB})
			}
		}
	}
	return out, nil
}

// parseHistZip liest eurofxref-hist.csv aus dem ZIP:
// "Date,USD,JPY,…," gefolgt von "2026-10-01,1.1298,178.49,N/A,…,".
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
	return nil, errors.New("zip: keine CSV-Datei gefunden")
}

func parseHistCSV(r io.Reader) ([]domain.FXRate, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	cr.TrimLeadingSpace = true
	header, err := cr.Read()
	if err != nil {
		return nil, fmt.Errorf("csv: kopfzeile: %w", err)
	}
	if len(header) == 0 || !strings.EqualFold(strings.TrimSpace(strings.TrimPrefix(header[0], "\uFEFF")), "Date") {
		return nil, fmt.Errorf("csv: unerwartete kopfzeile %q", header)
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
			return nil, fmt.Errorf("csv: datum %q: %w", rec[0], err)
		}
		for i := 1; i < len(rec) && i < len(curs); i++ {
			if rate, ok := parseECBRate(rec[i]); ok && store.ValidCurrencyCode(curs[i]) {
				out = append(out, domain.FXRate{Currency: curs[i], Date: d, Rate: rate, Source: domain.FXSourceECB})
			}
		}
	}
	return out, nil
}

// parseECBRate liest "1.1298"; "N/A", leer oder ≤ 0 → false.
func parseECBRate(s string) (float64, bool) {
	f, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil || !(f > 0) || f > 1e12 {
		return 0, false
	}
	return f, true
}
