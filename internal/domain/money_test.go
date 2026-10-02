package domain

import (
	"errors"
	"testing"
)

func TestFormatCents(t *testing.T) {
	tests := []struct {
		in   int64
		want string
	}{
		{0, "0,00 €"},
		{1, "0,01 €"},
		{99, "0,99 €"},
		{1234, "12,34 €"},
		{100000, "1.000,00 €"},
		{123456789, "1.234.567,89 €"},
		{-1234, "-12,34 €"},
		{-5, "-0,05 €"},
	}
	for _, tt := range tests {
		if got := FormatCents(tt.in); got != tt.want {
			t.Errorf("FormatCents(%d) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestFormatCentsInput(t *testing.T) {
	tests := []struct {
		in   int64
		want string
	}{
		{0, "0,00"},
		{1234, "12,34"},
		{123456, "1234,56"},
		{-50, "-0,50"},
	}
	for _, tt := range tests {
		if got := FormatCentsInput(tt.in); got != tt.want {
			t.Errorf("FormatCentsInput(%d) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestParseCents(t *testing.T) {
	tests := []struct {
		in      string
		want    int64
		wantErr bool
	}{
		{"12,34", 1234, false},
		{"12.34", 1234, false},
		{"12", 1200, false},
		{"12,3", 1230, false},
		{"12.5", 1250, false},
		{",50", 50, false},
		{"0", 0, false},
		{" 12,34 € ", 1234, false},
		{"12,34€", 1234, false},
		{"1.234,56", 123456, false},
		{"1,234.56", 123456, false},
		{"1.234", 123400, false},
		{"1.234.567", 123456700, false},
		{"1.234.567,89", 123456789, false},
		{"-12,34", -1234, false},
		{"+3", 300, false},
		{"", 0, true},
		{"   ", 0, true},
		{"abc", 0, true},
		{"12,345", 0, true},
		{"1,2,3", 0, true},
		{"12.34.5", 0, true},
		{"1.23,4", 0, true},
		{"12,", 0, true},
		{"-", 0, true},
		{"99999999999999999999", 0, true},
	}
	for _, tt := range tests {
		got, err := ParseCents(tt.in)
		if tt.wantErr {
			if err == nil {
				t.Errorf("ParseCents(%q) = %d, want error", tt.in, got)
			} else if !errors.As(err, new(ValidationError)) {
				t.Errorf("ParseCents(%q) error %v is not a ValidationError", tt.in, err)
			}
			continue
		}
		if err != nil {
			t.Errorf("ParseCents(%q) unexpected error: %v", tt.in, err)
			continue
		}
		if got != tt.want {
			t.Errorf("ParseCents(%q) = %d, want %d", tt.in, got, tt.want)
		}
	}
}

func TestParseMinorDecimals(t *testing.T) {
	tests := []struct {
		in       string
		decimals int
		want     int64
		wantErr  bool
	}{
		{"1500", 0, 1500, false},
		{"1.500", 0, 1500, false},
		{"15,5", 0, 0, true},
		{"1,234", 3, 1234, false},
		{"1.5", 3, 1500, false},
	}
	for _, tt := range tests {
		got, err := ParseMinor(tt.in, tt.decimals)
		if (err != nil) != tt.wantErr {
			t.Errorf("ParseMinor(%q, %d) err = %v, wantErr %v", tt.in, tt.decimals, err, tt.wantErr)
			continue
		}
		if !tt.wantErr && got != tt.want {
			t.Errorf("ParseMinor(%q, %d) = %d, want %d", tt.in, tt.decimals, got, tt.want)
		}
	}
}

func TestBasisPoints(t *testing.T) {
	parse := []struct {
		in   string
		want int64
	}{
		{"50", 5000},
		{"33,33", 3333},
		{"33.34", 3334},
		{"100", 10000},
		{"12,5 %", 1250},
	}
	for _, tt := range parse {
		got, err := ParseBasisPoints(tt.in)
		if err != nil || got != tt.want {
			t.Errorf("ParseBasisPoints(%q) = %d, %v, want %d", tt.in, got, err, tt.want)
		}
	}
	if got := FormatBasisPoints(3333); got != "33,33 %" {
		t.Errorf("FormatBasisPoints(3333) = %q", got)
	}
	if got := FormatBasisPoints(10000); got != "100,00 %" {
		t.Errorf("FormatBasisPoints(10000) = %q", got)
	}
}

func TestFormatMoney(t *testing.T) {
	tests := []struct {
		minor    int64
		currency string
		want     string
	}{
		{1234, "EUR", "12,34 €"},
		{1234, "", "12,34 €"},
		{1234, "USD", "12,34 USD"},
		{123456, "JPY", "123.456 JPY"},
		{1234, "kwd", "1,234 KWD"},
	}
	for _, tt := range tests {
		if got := FormatMoney(tt.minor, tt.currency); got != tt.want {
			t.Errorf("FormatMoney(%d, %q) = %q, want %q", tt.minor, tt.currency, got, tt.want)
		}
	}
}

func TestToEURCents(t *testing.T) {
	tests := []struct {
		minor    int64
		currency string
		rate     float64
		want     int64
	}{
		{10000, "USD", 1.0823, 9240}, // 100 USD / 1.0823 = 92.396... €
		{1000, "JPY", 160.5, 623},    // 1000 JPY / 160.5 = 6.2305 €
		{1234, "EUR", 1, 1234},
		{-10000, "USD", 1.0823, -9240},
		{100, "USD", 0, 0}, // ungültiger Kurs
	}
	for _, tt := range tests {
		if got := ToEURCents(tt.minor, tt.currency, tt.rate); got != tt.want {
			t.Errorf("ToEURCents(%d, %s, %v) = %d, want %d", tt.minor, tt.currency, tt.rate, got, tt.want)
		}
	}
}

func TestParseRate(t *testing.T) {
	tests := []struct {
		in   string
		want float64
	}{
		{"1,0857", 1.0857},
		{"1.0857", 1.0857},
		{"17000", 17000},
		{"17.000,5", 17000.5},
		{"17,000.5", 17000.5},
		{"17.000", 17000}, // Punkt vor genau drei Ziffern = Tausender (wie bei Beträgen)
		{"1.234.567,25", 1234567.25},
		{" 0,8653 ", 0.8653},
		{"162,45", 162.45},
		{"1,5", 1.5},
	}
	for _, tt := range tests {
		got, err := ParseRate(tt.in)
		if err != nil || got != tt.want {
			t.Errorf("ParseRate(%q) = %v, %v; want %v", tt.in, got, err, tt.want)
		}
	}
	for _, in := range []string{"", "0", "0,0", "-1,2", "abc", "1,2,3", "1.2.3", "17.00.0", "1e5", "NaN", "Inf", "1,", ",5x"} {
		if v, err := ParseRate(in); err == nil {
			t.Errorf("ParseRate(%q) = %v, want Fehler", in, v)
		} else if _, ok := err.(ValidationError); !ok {
			t.Errorf("ParseRate(%q): %T", in, err)
		}
	}
}
