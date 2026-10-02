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
		{"gleichmäßig glatt", SplitEqual, 900, []Part{{1, 1}, {2, 1}, {3, 1}}, map[int64]int64{1: 300, 2: 300, 3: 300}},
		{"gleichmäßig Rest an kleinste ID", SplitEqual, 1000, []Part{{3, 1}, {1, 1}, {2, 1}}, map[int64]int64{1: 334, 2: 333, 3: 333}},
		{"gleichmäßig zwei Cent Rest", SplitEqual, 1001, []Part{{1, 0}, {2, 0}, {3, 0}}, map[int64]int64{1: 334, 2: 334, 3: 333}},
		{"gleichmäßig eine Person", SplitEqual, 1234, []Part{{7, 1}}, map[int64]int64{7: 1234}},
		{"gleichmäßig 1 Cent auf 3", SplitEqual, 1, []Part{{1, 1}, {2, 1}, {3, 1}}, map[int64]int64{1: 1, 2: 0, 3: 0}},
		{"Anteile 2:1", SplitShares, 900, []Part{{1, 2}, {2, 1}}, map[int64]int64{1: 600, 2: 300}},
		{"Anteile größter Rest", SplitShares, 1000, []Part{{1, 1}, {2, 2}}, map[int64]int64{1: 333, 2: 667}},
		{"Anteile mit Null", SplitShares, 1000, []Part{{1, 1}, {2, 0}}, map[int64]int64{1: 1000, 2: 0}},
		{"Prozent", SplitPercent, 1000, []Part{{1, 3333}, {2, 3333}, {3, 3334}}, map[int64]int64{1: 333, 2: 333, 3: 334}},
		{"Prozent Rest nach größtem Rest", SplitPercent, 101, []Part{{1, 5000}, {2, 5000}}, map[int64]int64{1: 51, 2: 50}},
		{"Prozent 70/30", SplitPercent, 1999, []Part{{1, 7000}, {2, 3000}}, map[int64]int64{1: 1399, 2: 600}},
		{"Beträge", SplitAmount, 1000, []Part{{1, 250}, {2, 750}}, map[int64]int64{1: 250, 2: 750}},
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
					t.Errorf("Ergebnis nicht nach ParticipantID sortiert: %v", got)
				}
			}
			if sum != tt.total {
				t.Errorf("Summe %d != %d", sum, tt.total)
			}
		})
	}
}

// Bei Gleichstand im Rest rotiert der Extra-Cent mit dem Startwert
// (Ausgaben-ID) reihum über die gleichrangigen Personen (nach ID sortiert).
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
		{"zwei Personen, gerade ID", SplitEqual, 1001, []Part{{1, 1}, {2, 1}}, 10, map[int64]int64{1: 501, 2: 500}},
		{"zwei Personen, ungerade ID", SplitEqual, 1001, []Part{{1, 1}, {2, 1}}, 11, map[int64]int64{1: 500, 2: 501}},
		{"drei, Start 0", SplitEqual, 1000, three, 0, map[int64]int64{1: 334, 2: 333, 3: 333}},
		{"drei, Start 1", SplitEqual, 1000, three, 1, map[int64]int64{1: 333, 2: 334, 3: 333}},
		{"drei, Start 2", SplitEqual, 1000, three, 2, map[int64]int64{1: 333, 2: 333, 3: 334}},
		{"drei, Start 3 = 0", SplitEqual, 1000, three, 3, map[int64]int64{1: 334, 2: 333, 3: 333}},
		{"zwei Cent, Start 1", SplitEqual, 1001, three, 1, map[int64]int64{1: 333, 2: 334, 3: 334}},
		{"zwei Cent, Start 2 (reihum)", SplitEqual, 1001, three, 2, map[int64]int64{1: 334, 2: 333, 3: 334}},
		{"negativer Startwert", SplitEqual, 1000, three, -1, map[int64]int64{1: 333, 2: 333, 3: 334}},
		{"größter Rest geht vor", SplitShares, 5, []Part{{1, 2}, {2, 1}, {3, 1}}, 1, map[int64]int64{1: 3, 2: 1, 3: 1}},
		{"nur die Gleichrangigen rotieren, Start 0", SplitShares, 6, []Part{{1, 2}, {2, 1}, {3, 1}}, 0, map[int64]int64{1: 3, 2: 2, 3: 1}},
		{"nur die Gleichrangigen rotieren, Start 1", SplitShares, 6, []Part{{1, 2}, {2, 1}, {3, 1}}, 1, map[int64]int64{1: 3, 2: 1, 3: 2}},
		{"Prozent 50/50", SplitPercent, 101, []Part{{1, 5000}, {2, 5000}}, 7, map[int64]int64{1: 50, 2: 51}},
		{"Beträge unberührt", SplitAmount, 1000, []Part{{1, 250}, {2, 750}}, 1, map[int64]int64{1: 250, 2: 750}},
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
		{"keine Personen", SplitEqual, 100, nil, "Mindestens eine Person"},
		{"Betrag null", SplitEqual, 0, []Part{{1, 1}}, "größer als 0"},
		{"Betrag negativ", SplitEqual, -5, []Part{{1, 1}}, "größer als 0"},
		{"Betrag zu groß", SplitEqual, MaxAmountCents + 1, []Part{{1, 1}}, "zu groß"},
		{"doppelt", SplitEqual, 100, []Part{{1, 1}, {1, 1}}, "doppelt"},
		{"ungültige ID", SplitEqual, 100, []Part{{0, 1}}, "Ungültige Person"},
		{"unbekannter Modus", SplitMode("x"), 100, []Part{{1, 1}}, "Aufteilungsart"},
		{"negative Anteile", SplitShares, 100, []Part{{1, -1}, {2, 2}}, "negativ"},
		{"Anteile Summe null", SplitShares, 100, []Part{{1, 0}}, "größer als 0"},
		{"Prozent ungleich 100", SplitPercent, 100, []Part{{1, 5000}, {2, 4000}}, "100 %"},
		{"Beträge Summe falsch", SplitAmount, 1000, []Part{{1, 500}, {2, 400}}, "10,00 €"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Split(tt.mode, tt.total, tt.parts, 0)
			if err == nil {
				t.Fatal("erwarte Fehler")
			}
			var ve ValidationError
			if !errors.As(err, &ve) {
				t.Fatalf("kein ValidationError: %v", err)
			}
			if !strings.Contains(ve.Msg, tt.wantMsg) {
				t.Errorf("Meldung %q enthält nicht %q", ve.Msg, tt.wantMsg)
			}
		})
	}
}

func TestSplitModeValid(t *testing.T) {
	for _, m := range SplitModes {
		if !m.Valid() || m.Label() == "" {
			t.Errorf("%q ungültig oder ohne Label", m)
		}
	}
	if SplitMode("foo").Valid() {
		t.Error("foo sollte ungültig sein")
	}
}
