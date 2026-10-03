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
	return &Service{d: d, pages: pages, now: d.Config.Clock()}, nil
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
// no duplicates (unique index on recurring_id, date); occurrences for which
// an equal expense already exists are skipped (Store.ExpenseDatesLike). An
// error in one rule does not stop the others; all errors are returned
// together.
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

// MaterializeRule is Materialize for the rule id only (e.g. right after it
// was created or resumed) and returns the count of its new instances. Other
// due rules are left to the next run. Unknown, paused or not yet due rules
// create nothing.
func (s *Service) MaterializeRule(ctx context.Context, id int64, today time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	today = domain.DateOf(today)
	r, err := s.d.Store.GetRecurring(ctx, id)
	if errors.Is(err, store.ErrNotFound) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	if !r.Active || r.NextDate.After(today) {
		return 0, nil
	}
	n, err := s.materializeRule(ctx, r, today)
	if err != nil {
		return n, fmt.Errorf("recurring rule %d (%q): %w", r.ID, r.Template.Title, err)
	}
	return n, nil
}

func (s *Service) materializeRule(ctx context.Context, r store.Recurring, today time.Time) (int, error) {
	if !r.Frequency.Valid() {
		return 0, fmt.Errorf("unknown frequency %q", r.Frequency)
	}
	existing, err := s.d.Store.ExpenseDatesLike(ctx, r.Template, r.NextDate, today)
	if err != nil {
		return 0, err
	}
	n := 0
	for i, d := 0, r.NextDate; !d.After(today); i++ {
		if i == maxInstancesPerRun {
			s.d.Log.Info("recurring expenses: per-run limit reached, the rest follows in the next run",
				"rule", r.ID, "next_date", d.Format(domain.DateLayout), "limit", maxInstancesPerRun)
			break
		}
		created, err := s.createOccurrence(ctx, r, d, existing[d])
		if created {
			n++
		}
		if err == nil {
			next := domain.NextDate(r.Frequency, r.StartDate, d)
			err = s.d.Store.SetRecurringNextDate(ctx, r.ID, d, next)
			d = next
		}
		if errors.Is(err, store.ErrRecurringChanged) {
			// Paused, deleted or resumed meanwhile (r is a snapshot): that
			// change wins, nothing more to do for this rule.
			s.d.Log.Info("recurring expenses: rule changed meanwhile, stopping its catch-up", "rule", r.ID)
			return n, nil
		}
		if err != nil {
			return n, err // next_date stays: the next run retries this occurrence
		}
	}
	return n, nil
}

// createOccurrence creates the instance of rule r for date d and reports
// whether it did. It creates none if the occurrence already exists (e.g.
// after a crash before advancing next_date) or if exists is set: an equal
// expense was entered by hand or by a deleted rule (Store.ExpenseDatesLike).
func (s *Service) createOccurrence(ctx context.Context, r store.Recurring, d time.Time, exists bool) (bool, error) {
	if exists {
		s.d.Log.Info("recurring expense: an equal expense already exists, skipping the occurrence",
			"rule", r.ID, "date", d.Format(domain.DateLayout))
		return false, nil
	}
	in, err := s.instance(ctx, r, d)
	if err != nil {
		return false, err
	}
	_, err = s.d.Store.CreateExpense(ctx, 0, in)
	if errors.Is(err, store.ErrRecurringExists) {
		return false, nil
	}
	return err == nil, err
}

// instance builds the expense for the occurrence date from the template. For
// a foreign currency, the rate of the occurrence date applies (via d.FX).
// If the rate is only temporarily unavailable (ECB not reachable, database
// error), instance returns an error, so that the occurrence is retried in the
// next run instead of being stored with a stale rate for good. If no rate
// exists for the date at all (domain.ValidationError, e.g. a currency the ECB
// does not publish), the template's rate is kept: waiting would block the
// rule forever.
func (s *Service) instance(ctx context.Context, r store.Recurring, date time.Time) (store.ExpenseInput, error) {
	in := r.Template
	in.Parts = slices.Clone(in.Parts)
	in.Date, in.RecurringID = date, r.ID
	cur := in.OriginalCurrency
	if domain.IsEUR(cur) || s.d.FX == nil {
		return in, nil
	}
	rate, err := s.d.FX.Rate(ctx, cur, date)
	var ve domain.ValidationError
	switch {
	case errors.As(err, &ve):
		s.d.Log.Warn("recurring expense: no rate for the date, using the template's rate",
			"rule", r.ID, "currency", cur, "date", date.Format(domain.DateLayout), "err", err)
		return in, nil
	case err != nil:
		return in, fmt.Errorf("rate for %s on %s not available, retrying in the next run: %w",
			cur, date.Format(domain.DateLayout), err)
	}
	amount := domain.ToEURCents(in.OriginalAmountMinor, cur, rate.Rate)
	if amount <= 0 || amount > domain.MaxAmountCents {
		return in, nil
	}
	// For SplitAmount the weights are amounts in cur; the store distributes
	// the converted amount in proportion to them.
	in.AmountCents, in.FXRate, in.FXSource = amount, rate.Rate, rate.Source
	return in, nil
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
