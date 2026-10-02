// Package ynab syncs each person's own share of every expense into a YNAB
// clearing account "Geteilt" (per person, with their own token).
//
// Model: for each expense the app writes only the person's share as an
// outflow with the mapped YNAB category. Bank payments for shared expenses and
// reimbursements are marked in YNAB as transfers ↔ "Geteilt". Then:
// balance of "Geteilt" in YNAB = the person's balance in the app.
package ynab

import (
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

//go:embed templates/*.html
var templatesFS embed.FS

const (
	defaultDebounce   = 5 * time.Second  // collect changes before a run
	defaultStartDelay = 15 * time.Second // first full sync after startup
	fullInterval      = time.Hour        // full sync
	cacheTTL          = 10 * time.Minute // plans/accounts/categories for the settings page
	httpTimeout       = 30 * time.Second
)

// Service is the sync worker plus the settings pages.
type Service struct {
	d     web.Deps
	pages *web.Pages

	http    *http.Client
	baseURL string
	now     func() time.Time

	wake       chan struct{} // Trigger → Run (buffer 1, never blocking)
	debounce   time.Duration
	startDelay time.Duration

	// syncMu: at most one sync at a time (worker or button). Changes of
	// token or target wait for it (see changeConnection).
	syncMu sync.Mutex

	// Background syncs via "Jetzt synchronisieren" (see syncInBackground).
	// Run cancels them on shutdown and waits for them.
	bgMu     sync.Mutex
	bgCtx    context.Context
	bgCancel context.CancelFunc
	bgBusy   map[int64]bool // person → sync already running
	bgWG     sync.WaitGroup

	cacheMu sync.Mutex
	cache   map[string]cacheEntry
}

type cacheEntry struct {
	at  time.Time
	val any
}

// New creates the service and registers Trigger with the store change hook.
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
		cache:  map[string]cacheEntry{},
		bgBusy: map[int64]bool{},
	}
	s.bgCtx, s.bgCancel = context.WithCancel(context.Background())
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

// Trigger schedules a sync. It never blocks. Every run compares the complete
// desired state with ynab_sync (without requests if nothing differs), so a
// signal is enough; the expense ID is not needed.
func (s *Service) Trigger(expenseID int64) {
	select {
	case s.wake <- struct{}{}:
	default: // a run is already pending
	}
}

// Run processes triggers (batched after a short delay), runs a full sync
// every hour and retries after rate limits/outages until ctx is done (run it
// in its own goroutine).
func (s *Service) Run(ctx context.Context) {
	timer := time.NewTimer(s.startDelay)
	defer timer.Stop()
	deadline := time.Now().Add(s.startDelay)
	var lastFull time.Time
	defer s.stopBackground()
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

// SyncAll syncs all configured people and returns the delay until the next
// necessary run. syncMu is taken per person, so a change of the settings
// waits for one person's run at most.
func (s *Service) SyncAll(ctx context.Context, full bool) time.Duration {
	next := fullInterval
	cfgs, err := s.d.Store.ListYNABConfigs(ctx)
	if err != nil {
		s.d.Log.Error("ynab: read configs", "err", err)
		return retryDelay
	}
	for _, c := range cfgs {
		if ctx.Err() != nil {
			return next
		}
		if !c.Ready() {
			continue
		}
		cfg, res, st, err := s.syncPerson(ctx, c.ParticipantID, full)
		if err == errNotReady {
			continue // changed in the meantime
		}
		if err != nil || res.Created+res.Updated+res.Deleted+res.Failed > 0 {
			s.logSync("", cfg, res, err)
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

// logSync logs the outcome of a person's run (how: "" or " (now)"), never
// with the token. A pause after a rate limit and an invalid token are not
// logged: the settings page shows them, and they recur on every run.
func (s *Service) logSync(how string, cfg store.YNABConfig, res syncResult, err error) {
	var be backoffError
	switch {
	case err == nil:
		s.d.Log.Info("ynab: synced"+how, "person", cfg.ParticipantID, "result", res.logValue())
	case errors.As(err, &be), err == errTokenInvalid:
	default:
		s.d.Log.Warn("ynab: sync"+how+" failed", "person", cfg.ParticipantID, "err", redact(err.Error(), cfg.Token))
	}
}

// syncPerson syncs one person under syncMu with the connection as it is now.
// A sync uses the connection read at its start throughout, so token or
// target must not change while it runs (see changeConnection).
func (s *Service) syncPerson(ctx context.Context, participantID int64, full bool) (store.YNABConfig, syncResult, Status, error) {
	s.syncMu.Lock()
	defer s.syncMu.Unlock()
	cfg, err := s.d.Store.GetYNABConfig(ctx, participantID)
	if err != nil && err != store.ErrNotFound {
		return cfg, syncResult{}, Status{}, err
	}
	if !cfg.Ready() {
		return cfg, syncResult{}, Status{}, errNotReady
	}
	res, st, err := s.syncOne(ctx, cfg, full)
	return cfg, res, st, err
}

// changeConnection runs fn – a change of token or target – under syncMu, so
// that it never interleaves with a sync: otherwise the sync would write
// transaction IDs of the old account into the state for the new one, or
// overwrite the status just reset for a new token with its own result.
func (s *Service) changeConnection(fn func() error) error {
	s.syncMu.Lock()
	defer s.syncMu.Unlock()
	return fn()
}

// syncInBackground fully syncs participantID right away ("Jetzt
// synchronisieren") in its own goroutine so that the request does not wait
// for YNAB. If one is already running for the person or Run has ended,
// nothing happens. The result ends up in the person's status.
func (s *Service) syncInBackground(participantID int64) {
	s.bgMu.Lock()
	defer s.bgMu.Unlock()
	if s.bgCtx.Err() != nil || s.bgBusy[participantID] {
		return
	}
	s.bgBusy[participantID] = true
	s.bgWG.Go(func() {
		defer func() {
			s.bgMu.Lock()
			delete(s.bgBusy, participantID)
			s.bgMu.Unlock()
		}()
		cfg, res, _, err := s.syncPerson(s.bgCtx, participantID, true)
		cfg.ParticipantID = participantID // also if it could not be read
		s.logSync(" (now)", cfg, res, err)
	})
}

// stopBackground cancels running background syncs and waits for them (so
// that main closes the store only afterwards).
func (s *Service) stopBackground() {
	s.bgMu.Lock()
	s.bgCancel()
	s.bgMu.Unlock()
	s.bgWG.Wait()
}

// waitBackground waits for running background syncs (tests).
func (s *Service) waitBackground() { s.bgWG.Wait() }

// --- Cache for the settings page --------------------------------------------

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
