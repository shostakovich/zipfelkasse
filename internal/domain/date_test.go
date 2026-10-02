package domain

import (
	"strings"
	"testing"
	"time"
)

func d(s string) time.Time {
	t, err := time.Parse(DateLayout, s)
	if err != nil {
		panic(err)
	}
	return t
}

func TestNextDate(t *testing.T) {
	tests := []struct {
		name   string
		freq   Frequency
		anchor string
		after  string
		want   string
	}{
		{"wöchentlich", FreqWeekly, "2026-01-05", "2026-01-05", "2026-01-12"},
		{"wöchentlich über Jahresgrenze", FreqWeekly, "2025-12-29", "2025-12-30", "2026-01-05"},
		{"wöchentlich vor Anker", FreqWeekly, "2026-03-01", "2026-01-01", "2026-03-01"},
		{"monatlich einfach", FreqMonthly, "2026-01-15", "2026-01-15", "2026-02-15"},
		{"monatlich 31. Jan → 28. Feb", FreqMonthly, "2026-01-31", "2026-01-31", "2026-02-28"},
		{"monatlich 31. Jan → 29. Feb Schaltjahr", FreqMonthly, "2028-01-31", "2028-01-31", "2028-02-29"},
		{"monatlich nach Februar zurück zum Anker", FreqMonthly, "2026-01-31", "2026-02-28", "2026-03-31"},
		{"monatlich 30. April", FreqMonthly, "2026-01-31", "2026-03-31", "2026-04-30"},
		{"monatlich Dezember → Januar", FreqMonthly, "2026-12-31", "2026-12-31", "2027-01-31"},
		{"monatlich mitten im Zeitraum", FreqMonthly, "2026-01-10", "2026-05-20", "2026-06-10"},
		{"monatlich vor Anker", FreqMonthly, "2026-05-10", "2026-01-01", "2026-05-10"},
		{"jährlich", FreqYearly, "2026-03-15", "2026-03-15", "2027-03-15"},
		{"jährlich 29. Feb", FreqYearly, "2028-02-29", "2028-02-29", "2029-02-28"},
		{"jährlich 29. Feb zurück im Schaltjahr", FreqYearly, "2028-02-29", "2031-03-01", "2032-02-29"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := NextDate(tt.freq, d(tt.anchor), d(tt.after))
			if got.Format(DateLayout) != tt.want {
				t.Errorf("NextDate(%s, %s, %s) = %s, want %s", tt.freq, tt.anchor, tt.after, got.Format(DateLayout), tt.want)
			}
		})
	}
}

func TestOccurrence(t *testing.T) {
	anchor := d("2026-01-31")
	want := []string{"2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31"}
	for n, w := range want {
		if got := Occurrence(FreqMonthly, anchor, n).Format(DateLayout); got != w {
			t.Errorf("Occurrence(%d) = %s, want %s", n, got, w)
		}
	}
}

func TestFrequency(t *testing.T) {
	for _, f := range Frequencies {
		if !f.Valid() || f.Label() == "" {
			t.Errorf("%q ungültig", f)
		}
	}
	if Frequency("daily").Valid() {
		t.Error("daily sollte ungültig sein")
	}
}

func TestParseDate(t *testing.T) {
	tests := []struct {
		in      string
		want    string
		wantErr bool
	}{
		{"2026-10-02", "2026-10-02", false},
		{"02.10.2026", "2026-10-02", false},
		{"2.10.2026", "2026-10-02", false},
		{" 2026-10-02 ", "2026-10-02", false},
		{"", "", true},
		{"2026-02-30", "", true},
		{"gestern", "", true},
		{"2000-01-01", "2000-01-01", false},
		{"2100-12-31", "2100-12-31", false},
		{"1999-12-31", "", true},
		{"2101-01-01", "", true},
		{"0026-10-02", "", true},
		{"9999-12-31", "", true},
	}
	for _, tt := range tests {
		got, err := ParseDate(tt.in)
		if (err != nil) != tt.wantErr {
			t.Errorf("ParseDate(%q) err = %v", tt.in, err)
			continue
		}
		if !tt.wantErr {
			if got.Format(DateLayout) != tt.want || got.Location() != time.UTC || got.Hour() != 0 {
				t.Errorf("ParseDate(%q) = %v, want %s UTC 00:00", tt.in, got, tt.want)
			}
		}
	}
}

func TestFormatDate(t *testing.T) {
	if got := FormatDate(d("2026-10-02")); got != "02.10.2026" {
		t.Errorf("FormatDate = %q", got)
	}
	if got := FormatDate(time.Time{}); got != "" {
		t.Errorf("FormatDate(zero) = %q", got)
	}
}

func TestToday(t *testing.T) {
	loc, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		t.Skip("keine Zeitzonendaten")
	}
	// 23:30 UTC am 1.10. ist in Berlin schon der 2.10.
	now := time.Date(2026, 10, 1, 23, 30, 0, 0, time.UTC)
	got := DateOf(now.In(loc))
	if got.Format(DateLayout) != "2026-10-02" || got.Location() != time.UTC {
		t.Errorf("DateOf = %v", got)
	}
}

func TestParseDateRangeMessage(t *testing.T) {
	_, err := ParseDate("0026-10-02")
	if err == nil || !strings.Contains(err.Error(), "2000") || !strings.Contains(err.Error(), "2100") {
		t.Errorf("Meldung = %v", err)
	}
}
