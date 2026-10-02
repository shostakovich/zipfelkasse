// Package fx liefert Wechselkurse (EZB-Referenzkurse mit Cache in SQLite,
// manuelle Kurse) und den Endpunkt GET /api/kurs für das Ausgabenformular.
//
// Regeln für Rate(currency, date):
//   - EUR → 1 (Source "fest").
//   - Manuelle Kurse haben Vorrang: Es gilt der jüngste manuelle Kurs, dessen
//     „gültig ab“ ≤ date ist – bis ein neuerer manueller Kurs eingetragen wird.
//   - Sonst der EZB-Kurs vom Datum oder vom letzten Bankarbeitstag davor (bis
//     lookbackDays zurück). Fehlt er im Cache, wird nachgeladen: die
//     Tagesdatei für heute/gestern, die 90-Tage-Datei für jüngere Daten, sonst
//     einmalig die komplette Historie (eurofxref-hist.zip).
package fx

import (
	"context"
	"embed"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"teilen/internal/domain"
	"teilen/internal/store"
	"teilen/internal/web"
)

//go:embed templates/*.html
var templatesFS embed.FS

// lookbackDays: so viele Tage vor dem gewünschten Datum darf ein EZB-Kurs
// höchstens liegen (Wochenenden, Feiertage).
const lookbackDays = 10

// Service implementiert web.FXRater.
type Service struct {
	d       web.Deps
	pages   *web.Pages
	client  *http.Client
	baseURL string
	now     func() time.Time // in Tests überschreibbar
	berlin  *time.Location   // Zeitzone der EZB-Veröffentlichung

	mu    sync.Mutex
	loads map[string]*load // letzter bzw. laufender Abruf pro Datei
}

var _ web.FXRater = (*Service)(nil)

// New erzeugt den Service. main setzt ihn danach als Deps.FX.
func New(d web.Deps) (*Service, error) {
	pages, err := d.Render.Load(templatesFS, "templates/*.html")
	if err != nil {
		return nil, err
	}
	berlin, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		berlin = time.FixedZone("MEZ", 3600)
	}
	return &Service{
		d:       d,
		pages:   pages,
		client:  &http.Client{Timeout: 60 * time.Second},
		baseURL: defaultBaseURL,
		now:     time.Now,
		berlin:  berlin,
		loads:   map[string]*load{},
	}, nil
}

// today liefert das heutige Datum in der konfigurierten Zeitzone.
func (s *Service) today() time.Time {
	loc := s.d.Config.Location
	if loc == nil {
		loc = time.Local
	}
	return domain.DateOf(s.now().In(loc))
}

// expectedDate ist der jüngste Tag ≤ date, für den die EZB schon Kurse
// veröffentlicht haben sollte.
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

// Rate liefert den Kurs für currency am Datum date (EZB-Format: Einheiten
// Fremdwährung pro 1 EUR). Fehler: domain.ValidationError (ungültige Währung,
// kein Kurs vorhanden – Text direkt anzeigbar), *FetchError (EZB nicht
// erreichbar) oder Datenbankfehler.
func (s *Service) Rate(ctx context.Context, currency string, date time.Time) (domain.FXRate, error) {
	cur := strings.ToUpper(strings.TrimSpace(currency))
	date = domain.DateOf(date)
	if cur == "EUR" {
		return domain.FXRate{Currency: "EUR", Date: date, Rate: 1, Source: domain.FXSourceFixed}, nil
	}
	if !store.ValidCurrencyCode(cur) {
		if cur == "" {
			return domain.FXRate{}, domain.ValidationError{Msg: "Bitte eine Währung angeben."}
		}
		return domain.FXRate{}, domain.ValidationError{Msg: "Ungültige Währung „" + currency + "“."}
	}
	if today := s.today(); date.After(today) {
		date = today // Zukunft: aktuellster Kurs
	}
	st := s.d.Store

	// 1. Manuelle Kurse haben Vorrang.
	r, err := st.LookupFXRate(ctx, cur, domain.FXSourceManual, date, time.Time{})
	if err == nil {
		return r, nil
	}
	if !errors.Is(err, store.ErrNotFound) {
		return r, err
	}

	// 2. EZB-Cache.
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

	// 3. Nachladen: passende Datei, bei Bedarf die nächstgrößere.
	var res loadResult
	var fetchErr error
	for _, file := range filesFor(date, s.today()) {
		if file == fileHist && !date.After(s.histUntil(ctx)) {
			break // schon komplett im Cache
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

// noRate baut den Fehler „kein EZB-Kurs“: Kennt die EZB die Währung gar nicht,
// heißt es das; sonst fehlt nur der Kurs für das Datum.
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

// filesFor liefert die Dateien, die für date nacheinander in Frage kommen.
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

// Refresh lädt die neuesten EZB-Kurse (Tagesdatei; bei Lücken im Cache die
// 90-Tage-Datei) und liefert den jüngsten Kurstag.
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

// Run holt beim Start fehlende Tageskurse und danach an jedem
// Bankarbeitstag nach 16:30 Uhr (Europe/Berlin) die neuen. Fehler werden nur
// protokolliert. Blockiert, bis ctx beendet ist.
func (s *Service) Run(ctx context.Context) {
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
		// Noch nicht veröffentlicht oder Fehler: bis zu dreimal stündlich nachfassen.
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
		s.d.Log.Error("EZB-Kurse aktualisieren", "err", err)
	}
	return latest
}
