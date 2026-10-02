package domain

import (
	"strings"
	"time"
)

// Kalenderdaten (Ausgabedatum, Termine) sind time.Time um 00:00 UTC.
// So vergleichen und speichern sie sich ohne Zeitzonen-Überraschungen;
// gespeichert werden sie als "2006-01-02".

// DateLayout ist das Speicher- und HTML-<input type=date>-Format.
const DateLayout = "2006-01-02"

// DateOf schneidet die Uhrzeit ab und liefert das Kalenderdatum von t (in
// t's Zeitzone) als 00:00 UTC.
func DateOf(t time.Time) time.Time {
	y, m, d := t.Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// Today liefert das heutige Datum in der Zeitzone loc.
func Today(loc *time.Location) time.Time {
	return DateOf(time.Now().In(loc))
}

// Plausible Jahre für Kalenderdaten. Schützt vor Tippfehlern („0026“) und
// vor riesigen Schleifen bei Wiederholungen ab einem absurden Startdatum.
const (
	MinYear = 2000
	MaxYear = 2100
)

// ParseDate liest „2006-01-02“ oder „02.01.2006“ (auch „2.1.2006“). Jahre
// außerhalb MinYear–MaxYear werden abgelehnt.
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

// FormatDate formatiert deutsch: „02.10.2026“. Nullwert → "".
func FormatDate(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.Format("02.01.2006")
}

// Frequency ist der Rhythmus einer wiederkehrenden Ausgabe.
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

// Label liefert die deutsche Bezeichnung.
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

// Occurrence liefert den n-ten Termin (n=0 ist anchor) einer Wiederholung.
// Termine werden immer vom Ankerdatum aus berechnet: Ein Anker am 31. Januar
// ergibt 28./29. Februar, danach wieder den 31. März. Ungültige Frequenz → anchor.
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

// NextDate liefert den ersten Termin der Wiederholung, der strikt nach after
// liegt. Liegt after vor dem Anker, ist das der Anker selbst.
func NextDate(f Frequency, anchor, after time.Time) time.Time {
	anchor, after = DateOf(anchor), DateOf(after)
	if after.Before(anchor) || !f.Valid() {
		return anchor
	}
	// Schätzung, dann vorwärts laufen.
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
