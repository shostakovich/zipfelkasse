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
		{"weekly", FreqWeekly, "2026-01-05", "2026-01-05", "2026-01-12"},
		{"weekly across year boundary", FreqWeekly, "2025-12-29", "2025-12-30", "2026-01-05"},
		{"weekly before anchor", FreqWeekly, "2026-03-01", "2026-01-01", "2026-03-01"},
		{"monthly simple", FreqMonthly, "2026-01-15", "2026-01-15", "2026-02-15"},
		{"monthly Jan 31 → Feb 28", FreqMonthly, "2026-01-31", "2026-01-31", "2026-02-28"},
		{"monthly Jan 31 → Feb 29 leap year", FreqMonthly, "2028-01-31", "2028-01-31", "2028-02-29"},
		{"monthly back to anchor after February", FreqMonthly, "2026-01-31", "2026-02-28", "2026-03-31"},
		{"monthly April 30", FreqMonthly, "2026-01-31", "2026-03-31", "2026-04-30"},
		{"monthly December → January", FreqMonthly, "2026-12-31", "2026-12-31", "2027-01-31"},
		{"monthly mid-period", FreqMonthly, "2026-01-10", "2026-05-20", "2026-06-10"},
		{"monthly before anchor", FreqMonthly, "2026-05-10", "2026-01-01", "2026-05-10"},
		{"yearly", FreqYearly, "2026-03-15", "2026-03-15", "2027-03-15"},
		{"yearly Feb 29", FreqYearly, "2028-02-29", "2028-02-29", "2029-02-28"},
		{"yearly Feb 29 back in leap year", FreqYearly, "2028-02-29", "2031-03-01", "2032-02-29"},
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
			t.Errorf("%q invalid", f)
		}
	}
	if Frequency("daily").Valid() {
		t.Error("daily should be invalid")
	}
}

func TestFrequencyAdverb(t *testing.T) {
	for f, want := range map[Frequency]string{FreqWeekly: "wöchentlich", FreqMonthly: "monatlich", FreqYearly: "jährlich", "daily": "daily"} {
		if got := f.Adverb(); got != want {
			t.Errorf("%q.Adverb() = %q, want %q", f, got, want)
		}
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
		{"yesterday", "", true},
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
		t.Skip("no time zone data")
	}
	// 23:30 UTC on Oct 1 is already Oct 2 in Berlin.
	now := time.Date(2026, 10, 1, 23, 30, 0, 0, time.UTC)
	got := DateOf(now.In(loc))
	if got.Format(DateLayout) != "2026-10-02" || got.Location() != time.UTC {
		t.Errorf("DateOf = %v", got)
	}
}

func TestParseDateRangeMessage(t *testing.T) {
	_, err := ParseDate("0026-10-02")
	if err == nil || !strings.Contains(err.Error(), "2000") || !strings.Contains(err.Error(), "2100") {
		t.Errorf("message = %v", err)
	}
}
