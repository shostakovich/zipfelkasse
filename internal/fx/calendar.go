package fx

import "time"

// Die EZB veröffentlicht Referenzkurse an TARGET-Geschäftstagen gegen 16:00
// Uhr MEZ/MESZ: Montag bis Freitag außer Neujahr, Karfreitag, Ostermontag,
// 1. Mai, 25. und 26. Dezember.

// publishHour/publishMinute: ab dann gelten die Kurse des Tages als
// veröffentlicht (Europe/Berlin).
const (
	publishHour   = 16
	publishMinute = 30
)

// isBusinessDay meldet, ob die EZB am Datum d (00:00 UTC) Kurse veröffentlicht.
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

// lastBusinessDay liefert den letzten Geschäftstag ≤ d.
func lastBusinessDay(d time.Time) time.Time {
	for !isBusinessDay(d) {
		d = d.AddDate(0, 0, -1)
	}
	return d
}

// easterSunday berechnet den Ostersonntag (gregorianisch, Anonymous
// Gregorian Algorithm / Meeus-Jones-Butcher) als 00:00 UTC.
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

// nextPublish liefert den nächsten Zeitpunkt nach now (in now's Zone, gedacht
// für Europe/Berlin), an dem neue Tageskurse vorliegen sollten.
func nextPublish(now time.Time) time.Time {
	t := time.Date(now.Year(), now.Month(), now.Day(), publishHour, publishMinute, 0, 0, now.Location())
	for !t.After(now) || !isBusinessDay(time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)) {
		t = time.Date(t.Year(), t.Month(), t.Day()+1, publishHour, publishMinute, 0, 0, now.Location())
	}
	return t
}
