// Package ynab synchronisiert den eigenen Anteil jeder Ausgabe in ein
// YNAB-Verrechnungskonto „Geteilt“ (pro Person mit eigenem Token).
//
// Modell: Die App schreibt je Ausgabe nur den Anteil der Person als Ausgang
// mit zugeordneter YNAB-Kategorie. Bank-Zahlungen für geteilte Ausgaben und
// Rückzahlungen markiert man in YNAB als Transfer ↔ „Geteilt“. Dann gilt:
// Saldo „Geteilt“ in YNAB = Saldo der Person in der App.
package ynab

import (
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"net/http"
	"sync"
	"time"

	"teilen/internal/store"
	"teilen/internal/web"
)

//go:embed templates/*.html
var templatesFS embed.FS

const (
	defaultDebounce   = 5 * time.Second  // Sammeln von Änderungen vor einem Lauf
	defaultStartDelay = 15 * time.Second // erster Vollabgleich nach dem Start
	fullInterval      = time.Hour        // Vollabgleich
	cacheTTL          = 10 * time.Minute // Pläne/Konten/Kategorien für die Einstellungsseite
	httpTimeout       = 30 * time.Second
)

// Service ist der Sync-Worker plus Einstellungsseiten.
type Service struct {
	d     web.Deps
	pages *web.Pages

	http    *http.Client
	baseURL string
	now     func() time.Time

	wake       chan struct{} // Trigger → Run (Puffer 1, nie blockierend)
	debounce   time.Duration
	startDelay time.Duration

	syncMu sync.Mutex // höchstens ein Abgleich gleichzeitig (Worker oder Knopf)

	cacheMu sync.Mutex
	cache   map[string]cacheEntry
}

type cacheEntry struct {
	at  time.Time
	val any
}

// New erzeugt den Service und registriert Trigger am Store-Change-Hook.
func New(d web.Deps) (*Service, error) {
	pages, err := d.Render.Load(templatesFS, "templates/*.html")
	if err != nil {
		return nil, err
	}
	s := &Service{
		d: d, pages: pages,
		http:     &http.Client{Timeout: httpTimeout},
		baseURL:  DefaultBaseURL,
		now:      time.Now,
		wake:     make(chan struct{}, 1),
		debounce: defaultDebounce, startDelay: defaultStartDelay,
		cache: map[string]cacheEntry{},
	}
	d.Store.OnExpenseChange(func(c store.ExpenseChange) { s.Trigger(c.ExpenseID) })
	return s, nil
}

func (s *Service) client(token string) *client {
	return &client{http: s.http, baseURL: s.baseURL, token: token}
}

func (s *Service) loc() *time.Location {
	if s.d.Config.Location != nil {
		return s.d.Config.Location
	}
	return time.Local
}

// Trigger merkt einen Abgleich vor. Blockiert nie. Jeder Lauf vergleicht den
// kompletten Soll-Zustand mit ynab_sync (ohne Anfragen, wenn nichts anders
// ist), daher genügt ein Signal; die Ausgaben-ID wird nicht gebraucht.
func (s *Service) Trigger(expenseID int64) {
	select {
	case s.wake <- struct{}{}:
	default: // es steht schon ein Lauf an
	}
}

// Run arbeitet Trigger ab (gesammelt nach kurzer Wartezeit), gleicht
// stündlich vollständig ab und wiederholt nach Anfragelimit/Störung, bis ctx
// beendet ist (eigene Goroutine).
func (s *Service) Run(ctx context.Context) {
	timer := time.NewTimer(s.startDelay)
	defer timer.Stop()
	deadline := time.Now().Add(s.startDelay)
	var lastFull time.Time
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.wake:
			if time.Until(deadline) > s.debounce {
				deadline = time.Now().Add(s.debounce)
				timer.Reset(s.debounce)
			}
		case <-timer.C:
			full := lastFull.IsZero() || time.Since(lastFull) >= fullInterval-time.Minute
			if full {
				lastFull = time.Now()
			}
			next := s.SyncAll(ctx, full)
			deadline = time.Now().Add(next)
			timer.Reset(next)
		}
	}
}

// SyncAll gleicht alle eingerichteten Personen ab und liefert die Wartezeit
// bis zum nächsten nötigen Lauf.
func (s *Service) SyncAll(ctx context.Context, full bool) time.Duration {
	s.syncMu.Lock()
	defer s.syncMu.Unlock()
	next := fullInterval
	cfgs, err := s.d.Store.ListYNABConfigs(ctx)
	if err != nil {
		s.d.Log.Error("ynab: konfigurationen lesen", "err", err)
		return retryDelay
	}
	for _, cfg := range cfgs {
		if ctx.Err() != nil {
			return next
		}
		if !cfg.Ready() {
			continue
		}
		res, st, err := s.syncOne(ctx, cfg, full)
		switch err.(type) {
		case nil:
			if res.Created+res.Updated+res.Deleted+res.Failed > 0 {
				s.d.Log.Info("ynab: abgeglichen", "person", cfg.ParticipantID, "ergebnis", res.String())
			}
		case backoffError:
		default:
			if err != errTokenInvalid {
				s.d.Log.Warn("ynab: abgleich fehlgeschlagen", "person", cfg.ParticipantID, "err", redact(err.Error(), cfg.Token))
			}
		}
		if res.Again {
			next = min(next, s.debounce)
		}
		if wait := st.RetryAt.Sub(s.now()); wait > 0 {
			next = min(next, wait+time.Second)
		}
	}
	return next
}

// SyncNow gleicht eine Person sofort vollständig ab („Jetzt synchronisieren“).
func (s *Service) SyncNow(ctx context.Context, participantID int64) (syncResult, error) {
	s.syncMu.Lock()
	defer s.syncMu.Unlock()
	cfg, err := s.d.Store.GetYNABConfig(ctx, participantID)
	if err != nil && err != store.ErrNotFound {
		return syncResult{}, err
	}
	if !cfg.Ready() {
		return syncResult{}, errNotReady
	}
	res, _, err := s.syncOne(ctx, cfg, true)
	return res, err
}

// --- Cache für die Einstellungsseite ----------------------------------------

func fingerprint(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:8])
}

func (s *Service) cached(key string, refresh bool, load func() (any, error)) (any, error) {
	s.cacheMu.Lock()
	e, ok := s.cache[key]
	s.cacheMu.Unlock()
	if ok && !refresh && s.now().Sub(e.at) < cacheTTL {
		return e.val, nil
	}
	v, err := load()
	if err != nil {
		return nil, err
	}
	s.cacheMu.Lock()
	s.cache[key] = cacheEntry{at: s.now(), val: v}
	s.cacheMu.Unlock()
	return v, nil
}

func (s *Service) plans(ctx context.Context, token string, refresh bool) ([]apiPlan, error) {
	v, err := s.cached("plans:"+fingerprint(token), refresh, func() (any, error) {
		return s.client(token).plans(ctx)
	})
	if err != nil {
		return nil, err
	}
	return v.([]apiPlan), nil
}

func (s *Service) categories(ctx context.Context, token, planID string, refresh bool) ([]apiCategoryGroup, error) {
	v, err := s.cached("categories:"+fingerprint(token)+":"+planID, refresh, func() (any, error) {
		return s.client(token).categories(ctx, planID)
	})
	if err != nil {
		return nil, err
	}
	return v.([]apiCategoryGroup), nil
}
