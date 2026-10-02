package domain

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

func amounts(shares []Share) map[int64]int64 {
	m := map[int64]int64{}
	for _, s := range shares {
		m[s.ParticipantID] = s.AmountCents
	}
	return m
}

func TestSplit(t *testing.T) {
	tests := []struct {
		name  string
		mode  SplitMode
		total int64
		parts []Part
		want  map[int64]int64
	}{
		{"equal even", SplitEqual, 900, []Part{{1, 1}, {2, 1}, {3, 1}}, map[int64]int64{1: 300, 2: 300, 3: 300}},
		{"equal remainder to smallest ID", SplitEqual, 1000, []Part{{3, 1}, {1, 1}, {2, 1}}, map[int64]int64{1: 334, 2: 333, 3: 333}},
		{"equal two cents remainder", SplitEqual, 1001, []Part{{1, 0}, {2, 0}, {3, 0}}, map[int64]int64{1: 334, 2: 334, 3: 333}},
		{"equal one person", SplitEqual, 1234, []Part{{7, 1}}, map[int64]int64{7: 1234}},
		{"equal 1 cent among 3", SplitEqual, 1, []Part{{1, 1}, {2, 1}, {3, 1}}, map[int64]int64{1: 1, 2: 0, 3: 0}},
		{"shares 2:1", SplitShares, 900, []Part{{1, 2}, {2, 1}}, map[int64]int64{1: 600, 2: 300}},
		{"shares largest remainder", SplitShares, 1000, []Part{{1, 1}, {2, 2}}, map[int64]int64{1: 333, 2: 667}},
		{"shares with zero", SplitShares, 1000, []Part{{1, 1}, {2, 0}}, map[int64]int64{1: 1000, 2: 0}},
		{"percent", SplitPercent, 1000, []Part{{1, 3333}, {2, 3333}, {3, 3334}}, map[int64]int64{1: 333, 2: 333, 3: 334}},
		{"percent remainder by largest remainder", SplitPercent, 101, []Part{{1, 5000}, {2, 5000}}, map[int64]int64{1: 51, 2: 50}},
		{"percent 70/30", SplitPercent, 1999, []Part{{1, 7000}, {2, 3000}}, map[int64]int64{1: 1399, 2: 600}},
		{"amounts", SplitAmount, 1000, []Part{{1, 250}, {2, 750}}, map[int64]int64{1: 250, 2: 750}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Split(tt.mode, tt.total, tt.parts, 0)
			if err != nil {
				t.Fatalf("Split: %v", err)
			}
			if m := amounts(got); !reflect.DeepEqual(m, tt.want) {
				t.Errorf("got %v, want %v", m, tt.want)
			}
			var sum int64
			for i, s := range got {
				sum += s.AmountCents
				if i > 0 && got[i-1].ParticipantID >= s.ParticipantID {
					t.Errorf("result not sorted by ParticipantID: %v", got)
				}
			}
			if sum != tt.total {
				t.Errorf("sum %d != %d", sum, tt.total)
			}
		})
	}
}

// On tied remainders the extra cent rotates with the start value (expense
// ID) round-robin over the tied people (sorted by ID).
func TestSplitRotatesTies(t *testing.T) {
	three := []Part{{3, 1}, {1, 1}, {2, 1}}
	tests := []struct {
		name     string
		mode     SplitMode
		total    int64
		parts    []Part
		rotation int64
		want     map[int64]int64
	}{
		{"two people, even ID", SplitEqual, 1001, []Part{{1, 1}, {2, 1}}, 10, map[int64]int64{1: 501, 2: 500}},
		{"two people, odd ID", SplitEqual, 1001, []Part{{1, 1}, {2, 1}}, 11, map[int64]int64{1: 500, 2: 501}},
		{"three, start 0", SplitEqual, 1000, three, 0, map[int64]int64{1: 334, 2: 333, 3: 333}},
		{"three, start 1", SplitEqual, 1000, three, 1, map[int64]int64{1: 333, 2: 334, 3: 333}},
		{"three, start 2", SplitEqual, 1000, three, 2, map[int64]int64{1: 333, 2: 333, 3: 334}},
		{"three, start 3 = 0", SplitEqual, 1000, three, 3, map[int64]int64{1: 334, 2: 333, 3: 333}},
		{"two cents, start 1", SplitEqual, 1001, three, 1, map[int64]int64{1: 333, 2: 334, 3: 334}},
		{"two cents, start 2 (round-robin)", SplitEqual, 1001, three, 2, map[int64]int64{1: 334, 2: 333, 3: 334}},
		{"negative start value", SplitEqual, 1000, three, -1, map[int64]int64{1: 333, 2: 333, 3: 334}},
		{"largest remainder takes precedence", SplitShares, 5, []Part{{1, 2}, {2, 1}, {3, 1}}, 1, map[int64]int64{1: 3, 2: 1, 3: 1}},
		{"only the tied rotate, start 0", SplitShares, 6, []Part{{1, 2}, {2, 1}, {3, 1}}, 0, map[int64]int64{1: 3, 2: 2, 3: 1}},
		{"only the tied rotate, start 1", SplitShares, 6, []Part{{1, 2}, {2, 1}, {3, 1}}, 1, map[int64]int64{1: 3, 2: 1, 3: 2}},
		{"percent 50/50", SplitPercent, 101, []Part{{1, 5000}, {2, 5000}}, 7, map[int64]int64{1: 50, 2: 51}},
		{"amounts unaffected", SplitAmount, 1000, []Part{{1, 250}, {2, 750}}, 1, map[int64]int64{1: 250, 2: 750}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Split(tt.mode, tt.total, tt.parts, tt.rotation)
			if err != nil {
				t.Fatal(err)
			}
			if m := amounts(got); !reflect.DeepEqual(m, tt.want) {
				t.Errorf("got %v, want %v", m, tt.want)
			}
		})
	}
}

func TestSplitEqualStoresWeightOne(t *testing.T) {
	got, err := Split(SplitEqual, 100, []Part{{1, 0}, {2, 5}}, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range got {
		if s.Weight != 1 {
			t.Errorf("weight = %d, want 1", s.Weight)
		}
	}
}

func TestSplitErrors(t *testing.T) {
	tests := []struct {
		name    string
		mode    SplitMode
		total   int64
		parts   []Part
		wantMsg string
	}{
		{"no people", SplitEqual, 100, nil, "Mindestens eine Person"},
		{"amount zero", SplitEqual, 0, []Part{{1, 1}}, "größer als 0"},
		{"amount negative", SplitEqual, -5, []Part{{1, 1}}, "größer als 0"},
		{"amount too large", SplitEqual, MaxAmountCents + 1, []Part{{1, 1}}, "zu groß"},
		{"duplicate", SplitEqual, 100, []Part{{1, 1}, {1, 1}}, "doppelt"},
		{"invalid ID", SplitEqual, 100, []Part{{0, 1}}, "Ungültige Person"},
		{"unknown mode", SplitMode("x"), 100, []Part{{1, 1}}, "Aufteilungsart"},
		{"negative shares", SplitShares, 100, []Part{{1, -1}, {2, 2}}, "negativ"},
		{"shares sum zero", SplitShares, 100, []Part{{1, 0}}, "größer als 0"},
		{"percent not 100", SplitPercent, 100, []Part{{1, 5000}, {2, 4000}}, "100 %"},
		{"amounts sum wrong", SplitAmount, 1000, []Part{{1, 500}, {2, 400}}, "10,00 €"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Split(tt.mode, tt.total, tt.parts, 0)
			if err == nil {
				t.Fatal("expected error")
			}
			var ve ValidationError
			if !errors.As(err, &ve) {
				t.Fatalf("not a ValidationError: %v", err)
			}
			if !strings.Contains(ve.Msg, tt.wantMsg) {
				t.Errorf("message %q does not contain %q", ve.Msg, tt.wantMsg)
			}
		})
	}
}

func TestSplitModeValid(t *testing.T) {
	for _, m := range SplitModes {
		if !m.Valid() || m.Label() == "" {
			t.Errorf("%q invalid or without label", m)
		}
	}
	if SplitMode("foo").Valid() {
		t.Error("foo should be invalid")
	}
}
