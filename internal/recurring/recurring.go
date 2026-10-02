// Package recurring manages recurring expenses and creates due instances (on
// startup and hourly).
//
// A recurring rule is always created from an existing expense: it is the
// template and the first instance, and its date is the anchor. All
// occurrences are computed from the anchor (domain.Occurrence/NextDate), so
// that e.g. the 31st of a month is the 31st again after February.
package recurring

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

//go:embed templates/*.html
var templatesFS embed.FS

// maxInstancesPerRun limits the occurrences Materialize processes per rule
// and run (e.g. for a very old start date). The next run (hourly) catches up
// on the rest.
const maxInstancesPerRun = 400

// Service creates due instances of recurring expenses.
type Service struct {
	d     web.Deps
	pages *web.Pages
	now   func() time.Time // overridable in tests

	mu sync.Mutex // serializes Materialize
}

// New creates the service.
func New(d web.Deps) (*Service, error) {
	pages, err := d.Render.Load(templatesFS, "templates/*.html")
	if err != nil {
		return nil, err
	}
	return &Service{d: d, pages: pages, now: time.Now}, nil
}

// today returns today's date in the configured time zone.
func (s *Service) today() time.Time {
	loc := s.d.Config.Location
	if loc == nil {
		loc = time.Local
	}
	return domain.DateOf(s.now().In(loc))
}

// Materialize creates all instances due up to and including today (at most
// maxInstancesPerRun per rule) and returns their count. Repeated calls create
// no duplicates (unique index on recurring_id, date). An error in one rule
// does not stop the others; all errors are returned together.
func (s *Service) Materialize(ctx context.Context, today time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	today = domain.DateOf(today)
	due, err := s.d.Store.DueRecurring(ctx, today)
	if err != nil {
		return 0, err
	}
	var errs []error
	n := 0
	for _, r := range due {
		k, err := s.materializeRule(ctx, r, today)
		n += k
		if err != nil {
			errs = append(errs, fmt.Errorf("recurring rule %d (%q): %w", r.ID, r.Template.Title, err))
		}
		if ctx.Err() != nil {
			break
		}
	}
	return n, errors.Join(errs...)
}

func (s *Service) materializeRule(ctx context.Context, r store.Recurring, today time.Time) (int, error) {
	if !r.Frequency.Valid() {
		return 0, fmt.Errorf("unknown frequency %q", r.Frequency)
	}
	n := 0
	for i, d := 0, r.NextDate; !d.After(today); i++ {
		if i == maxInstancesPerRun {
			s.d.Log.Info("recurring expenses: per-run limit reached, the rest follows in the next run",
				"rule", r.ID, "next_date", d.Format(domain.DateLayout), "limit", maxInstancesPerRun)
			break
		}
		_, err := s.d.Store.CreateExpense(ctx, 0, s.instance(ctx, r, d))
		switch {
		case err == nil:
			n++
		case errors.Is(err, store.ErrRecurringExists):
			// already exists (e.g. after a crash before advancing next_date)
		default:
			return n, err
		}
		next := domain.NextDate(r.Frequency, r.StartDate, d)
		if err := s.d.Store.SetRecurringNextDate(ctx, r.ID, next); err != nil {
			return n, err
		}
		d = next
	}
	return n, nil
}

// instance builds the expense for the occurrence date from the template. For
// a foreign currency, the rate of the occurrence date applies (via d.FX); if
// none is available, the template's rate is kept.
func (s *Service) instance(ctx context.Context, r store.Recurring, date time.Time) store.ExpenseInput {
	in := r.Template
	in.Parts = slices.Clone(in.Parts)
	in.Date, in.RecurringID = date, r.ID
	cur := in.OriginalCurrency
	if cur == "" || cur == "EUR" || s.d.FX == nil {
		return in
	}
	rate, err := s.d.FX.Rate(ctx, cur, date)
	if err != nil {
		s.d.Log.Warn("recurring expense: rate not available, using the template's rate",
			"rule", r.ID, "currency", cur, "date", date.Format(domain.DateLayout), "err", err)
		return in
	}
	amount := domain.ToEURCents(in.OriginalAmountMinor, cur, rate.Rate)
	if amount <= 0 || amount > domain.MaxAmountCents {
		return in
	}
	// For SplitAmount the weights are amounts in cur; the store distributes
	// the converted amount in proportion to them.
	in.AmountCents, in.FXRate, in.FXSource = amount, rate.Rate, rate.Source
	return in
}

// Run calls Materialize immediately and then hourly. Blocks until ctx is
// done (main starts Run in its own goroutine).
func (s *Service) Run(ctx context.Context) {
	tick := time.NewTicker(time.Hour)
	defer tick.Stop()
	for {
		if n, err := s.Materialize(ctx, s.today()); err != nil {
			if ctx.Err() == nil {
				s.d.Log.Error("recurring expenses", "err", err)
			}
		} else if n > 0 {
			s.d.Log.Info("recurring expenses created", "count", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
