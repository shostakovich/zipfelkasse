package domain

import (
	"strings"
	"time"
)

// Calendar dates (expense date, occurrences) are time.Time at 00:00 UTC.
// That way they compare and store without time-zone surprises; they are
// stored as "2006-01-02".

// DateLayout is the storage and HTML <input type=date> format.
const DateLayout = "2006-01-02"

// DateOf truncates the time of day and returns the calendar date of t (in
// t's time zone) as 00:00 UTC.
func DateOf(t time.Time) time.Time {
	y, m, d := t.Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// Today returns today's date in the time zone loc.
func Today(loc *time.Location) time.Time {
	return DateOf(time.Now().In(loc))
}

// Plausible years for calendar dates. Guards against typos ("0026") and
// against huge loops for recurrences starting at an absurd date.
const (
	MinYear = 2000
	MaxYear = 2100
)

// ParseDate parses "2006-01-02" or "02.01.2006" (also "2.1.2006"). Years
// outside MinYear–MaxYear are rejected.
func ParseDate(s string) (time.Time, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, invalid("Bitte ein Datum angeben.")
	}
	for _, layout := range []string{DateLayout, "02.01.2006", "2.1.2006"} {
		if t, err := time.Parse(layout, s); err == nil {
			if y := t.Year(); y < MinYear || y > MaxYear {
				return time.Time{}, invalid("Das Datum „%s“ liegt nicht zwischen %d und %d.", s, MinYear, MaxYear)
			}
			return t, nil
		}
	}
	return time.Time{}, invalid("Ungültiges Datum „%s“.", s)
}

// FormatDate formats German style: "02.10.2026". Zero value → "".
func FormatDate(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.Format("02.01.2006")
}

// Frequency is the interval of a recurring expense.
type Frequency string

const (
	FreqWeekly  Frequency = "weekly"
	FreqMonthly Frequency = "monthly"
	FreqYearly  Frequency = "yearly"
)

var Frequencies = []Frequency{FreqWeekly, FreqMonthly, FreqYearly}

func (f Frequency) Valid() bool {
	switch f {
	case FreqWeekly, FreqMonthly, FreqYearly:
		return true
	}
	return false
}

// Label returns the German display name.
func (f Frequency) Label() string {
	switch f {
	case FreqWeekly:
		return "Wöchentlich"
	case FreqMonthly:
		return "Monatlich"
	case FreqYearly:
		return "Jährlich"
	}
	return string(f)
}

// Occurrence returns the n-th occurrence (n=0 is anchor) of a recurrence.
// Occurrences are always computed from the anchor date: an anchor on January 31
// yields February 28/29, then March 31 again. Invalid frequency → anchor.
func Occurrence(f Frequency, anchor time.Time, n int) time.Time {
	anchor = DateOf(anchor)
	switch f {
	case FreqWeekly:
		return anchor.AddDate(0, 0, 7*n)
	case FreqMonthly:
		return addMonthsClamped(anchor, n)
	case FreqYearly:
		return addMonthsClamped(anchor, 12*n)
	}
	return anchor
}

// NextDate returns the first occurrence of the recurrence strictly after
// after. If after is before the anchor, that is the anchor itself.
func NextDate(f Frequency, anchor, after time.Time) time.Time {
	anchor, after = DateOf(anchor), DateOf(after)
	if after.Before(anchor) || !f.Valid() {
		return anchor
	}
	// Estimate, then step forward.
	var n int
	switch f {
	case FreqWeekly:
		n = int(after.Sub(anchor).Hours()/24) / 7
	case FreqMonthly:
		n = monthsBetween(anchor, after)
	case FreqYearly:
		n = monthsBetween(anchor, after) / 12
	}
	n = max(n-1, 0)
	for {
		if t := Occurrence(f, anchor, n); t.After(after) {
			return t
		}
		n++
	}
}

func monthsBetween(a, b time.Time) int {
	return (b.Year()-a.Year())*12 + int(b.Month()) - int(a.Month())
}

func addMonthsClamped(t time.Time, months int) time.Time {
	y, m := t.Year(), int(t.Month())-1+months
	y += m / 12
	m %= 12
	if m < 0 {
		m += 12
		y--
	}
	month := time.Month(m + 1)
	day := min(t.Day(), daysIn(y, month))
	return time.Date(y, month, day, 0, 0, 0, 0, time.UTC)
}

func daysIn(year int, month time.Month) int {
	return time.Date(year, month+1, 0, 0, 0, 0, 0, time.UTC).Day()
}
