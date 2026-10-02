package fx

import "time"

// The ECB publishes reference rates on TARGET business days around 16:00
// CET/CEST: Monday to Friday except New Year's Day, Good Friday, Easter
// Monday, 1 May, 25 and 26 December.

// publishHour/publishMinute: from then on, the day's rates count as
// published (Europe/Berlin).
const (
	publishHour   = 16
	publishMinute = 30
)

// isBusinessDay reports whether the ECB publishes rates on date d (00:00 UTC).
func isBusinessDay(d time.Time) bool {
	switch d.Weekday() {
	case time.Saturday, time.Sunday:
		return false
	}
	y, m, day := d.Date()
	switch {
	case m == time.January && day == 1,
		m == time.May && day == 1,
		m == time.December && (day == 25 || day == 26):
		return false
	}
	easter := easterSunday(y)
	if d.Equal(easter.AddDate(0, 0, -2)) || d.Equal(easter.AddDate(0, 0, 1)) {
		return false
	}
	return true
}

// lastBusinessDay returns the last business day ≤ d.
func lastBusinessDay(d time.Time) time.Time {
	for !isBusinessDay(d) {
		d = d.AddDate(0, 0, -1)
	}
	return d
}

// easterSunday computes Easter Sunday (Gregorian, Anonymous Gregorian
// Algorithm / Meeus-Jones-Butcher) at 00:00 UTC.
func easterSunday(y int) time.Time {
	a := y % 19
	b, c := y/100, y%100
	d, e := b/4, b%4
	f := (b + 8) / 25
	g := (b - f + 1) / 3
	h := (19*a + b - d - g + 15) % 30
	i, k := c/4, c%4
	l := (32 + 2*e + 2*i - h - k) % 7
	m := (a + 11*h + 22*l) / 451
	month := (h + l - 7*m + 114) / 31
	day := (h+l-7*m+114)%31 + 1
	return time.Date(y, time.Month(month), day, 0, 0, 0, 0, time.UTC)
}

// nextPublish returns the next point in time after now (in now's zone, meant
// for Europe/Berlin) at which new daily rates should be available.
func nextPublish(now time.Time) time.Time {
	t := time.Date(now.Year(), now.Month(), now.Day(), publishHour, publishMinute, 0, 0, now.Location())
	for !t.After(now) || !isBusinessDay(time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)) {
		t = time.Date(t.Year(), t.Month(), t.Day()+1, publishHour, publishMinute, 0, 0, now.Location())
	}
	return t
}
