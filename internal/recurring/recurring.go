// Package recurring verwaltet wiederkehrende Ausgaben und legt fällige
// Instanzen an (beim Start und stündlich).
//
// Eine Wiederholung entsteht immer aus einer bestehenden Ausgabe: Sie ist
// Vorlage und erste Instanz, ihr Datum ist der Anker. Alle Termine werden vom
// Anker aus berechnet (domain.Occurrence/NextDate), damit z. B. der 31. eines
// Monats nach dem Februar wieder der 31. ist.
package recurring

import (
	"cmp"
	"context"
	"embed"
	"errors"
	"fmt"
	"math/bits"
	"slices"
	"sync"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

//go:embed templates/*.html
var templatesFS embed.FS

// maxInstancesPerRun begrenzt die Termine, die Materialize je Regel und Lauf
// abarbeitet (z. B. bei einem sehr alten Startdatum). Den Rest holt der
// nächste Lauf nach (stündlich).
const maxInstancesPerRun = 400

// Service erzeugt fällige Instanzen wiederkehrender Ausgaben.
type Service struct {
	d     web.Deps
	pages *web.Pages
	now   func() time.Time // in Tests überschreibbar

	mu sync.Mutex // serialisiert Materialize
}

// New erzeugt den Service.
func New(d web.Deps) (*Service, error) {
	pages, err := d.Render.Load(templatesFS, "templates/*.html")
	if err != nil {
		return nil, err
	}
	return &Service{d: d, pages: pages, now: time.Now}, nil
}

// today liefert das heutige Datum in der konfigurierten Zeitzone.
func (s *Service) today() time.Time {
	loc := s.d.Config.Location
	if loc == nil {
		loc = time.Local
	}
	return domain.DateOf(s.now().In(loc))
}

// Materialize legt alle bis einschließlich today fälligen Instanzen an (je
// Regel höchstens maxInstancesPerRun) und liefert deren Anzahl. Mehrfacher Aufruf erzeugt keine Duplikate (Unique-Index
// auf recurring_id, date). Fehler einer Regel halten die anderen nicht auf;
// alle Fehler kommen gesammelt zurück.
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
			errs = append(errs, fmt.Errorf("wiederholung %d („%s“): %w", r.ID, r.Template.Title, err))
		}
		if ctx.Err() != nil {
			break
		}
	}
	return n, errors.Join(errs...)
}

func (s *Service) materializeRule(ctx context.Context, r store.Recurring, today time.Time) (int, error) {
	if !r.Frequency.Valid() {
		return 0, fmt.Errorf("unbekannte häufigkeit %q", r.Frequency)
	}
	n := 0
	for i, d := 0, r.NextDate; !d.After(today); i++ {
		if i == maxInstancesPerRun {
			s.d.Log.Info("wiederkehrende Ausgaben: Obergrenze je Lauf erreicht, Rest folgt beim nächsten Lauf",
				"regel", r.ID, "naechster_termin", d.Format(domain.DateLayout), "grenze", maxInstancesPerRun)
			break
		}
		_, err := s.d.Store.CreateExpense(ctx, 0, s.instance(ctx, r, d))
		switch {
		case err == nil:
			n++
		case errors.Is(err, store.ErrRecurringExists):
			// gibt es schon (z. B. nach Absturz vor dem Fortschreiben)
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

// instance baut die Ausgabe für den Termin date aus der Vorlage. Bei
// Fremdwährung gilt der Kurs vom Termin (über d.FX); ist keiner zu bekommen,
// bleibt es beim Kurs der Vorlage.
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
		s.d.Log.Warn("wiederkehrende Ausgabe: Kurs nicht verfügbar, nehme Kurs der Vorlage",
			"regel", r.ID, "waehrung", cur, "datum", date.Format(domain.DateLayout), "err", err)
		return in
	}
	amount := domain.ToEURCents(in.OriginalAmountMinor, cur, rate.Rate)
	if amount <= 0 || amount > domain.MaxAmountCents {
		return in
	}
	if in.SplitMode == domain.SplitAmount && !in.IsReimbursement {
		in.Parts = rescale(in.Parts, amount)
	}
	in.AmountCents, in.FXRate, in.FXSource = amount, rate.Rate, rate.Source
	return in
}

// rescale verteilt total proportional zu den bisherigen festen Beträgen
// (Methode des größten Rests, bei Gleichstand kleinere ID). Für
// SplitAmount-Vorlagen, deren Euro-Betrag sich mit dem Kurs ändert.
func rescale(parts []domain.Part, total int64) []domain.Part {
	var sum int64
	for _, p := range parts {
		sum += p.Weight
	}
	if sum <= 0 || sum == total {
		return parts
	}
	out := slices.Clone(parts)
	rems := make([]uint64, len(out))
	var allocated int64
	for i, p := range out {
		hi, lo := bits.Mul64(uint64(p.Weight), uint64(total))
		q, rem := bits.Div64(hi, lo, uint64(sum)) // p.Weight ≤ sum → kein Überlauf
		out[i].Weight, rems[i] = int64(q), rem
		allocated += int64(q)
	}
	order := make([]int, len(out))
	for i := range order {
		order[i] = i
	}
	slices.SortStableFunc(order, func(a, b int) int {
		if c := cmp.Compare(rems[b], rems[a]); c != 0 {
			return c
		}
		return cmp.Compare(out[a].ParticipantID, out[b].ParticipantID)
	})
	for k := 0; allocated < total; k++ {
		out[order[k%len(order)]].Weight++
		allocated++
	}
	return out
}

// Run ruft Materialize sofort und danach stündlich auf. Blockiert, bis ctx
// beendet ist (main startet Run in einer eigenen Goroutine).
func (s *Service) Run(ctx context.Context) {
	tick := time.NewTicker(time.Hour)
	defer tick.Stop()
	for {
		if n, err := s.Materialize(ctx, s.today()); err != nil {
			if ctx.Err() == nil {
				s.d.Log.Error("wiederkehrende Ausgaben", "err", err)
			}
		} else if n > 0 {
			s.d.Log.Info("wiederkehrende Ausgaben angelegt", "anzahl", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
