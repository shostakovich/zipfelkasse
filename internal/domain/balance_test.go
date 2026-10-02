package domain

import (
	"reflect"
	"testing"
)

func TestBalances(t *testing.T) {
	entries := []Entry{
		// A (1) zahlt 30 € für alle drei
		{PaidBy: 1, AmountCents: 3000, Shares: []Share{{ParticipantID: 1, AmountCents: 1000}, {ParticipantID: 2, AmountCents: 1000}, {ParticipantID: 3, AmountCents: 1000}}},
		// B (2) zahlt 10 € nur für C
		{PaidBy: 2, AmountCents: 1000, Shares: []Share{{ParticipantID: 3, AmountCents: 1000}}},
		// Rückzahlung: C zahlt 5 € an A (A hat 100 % Anteil)
		{PaidBy: 3, AmountCents: 500, Shares: []Share{{ParticipantID: 1, AmountCents: 500}}},
	}
	got := Balances(entries)
	want := map[int64]int64{1: 1500, 2: 0, 3: -1500}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Balances = %v, want %v", got, want)
	}
	var sum int64
	for _, v := range got {
		sum += v
	}
	if sum != 0 {
		t.Errorf("Summe der Salden = %d, want 0", sum)
	}
}

func TestBalancesEmpty(t *testing.T) {
	if got := Balances(nil); len(got) != 0 {
		t.Errorf("Balances(nil) = %v", got)
	}
}

func TestSettle(t *testing.T) {
	tests := []struct {
		name     string
		balances map[int64]int64
		want     []Transfer
	}{
		{"leer", map[int64]int64{}, nil},
		{"ausgeglichen", map[int64]int64{1: 0, 2: 0}, nil},
		{"einfach", map[int64]int64{1: 1500, 2: -1500}, []Transfer{{From: 2, To: 1, AmountCents: 1500}}},
		{
			"greedy",
			map[int64]int64{1: 5000, 2: -3000, 3: -1500, 4: -500},
			[]Transfer{{From: 2, To: 1, AmountCents: 3000}, {From: 3, To: 1, AmountCents: 1500}, {From: 4, To: 1, AmountCents: 500}},
		},
		{
			"mehrere Gläubiger",
			map[int64]int64{1: 2000, 2: 1000, 3: -2500, 4: -500},
			[]Transfer{{From: 3, To: 1, AmountCents: 2000}, {From: 3, To: 2, AmountCents: 500}, {From: 4, To: 2, AmountCents: 500}},
		},
		{
			"Gleichstand nach ID",
			map[int64]int64{5: 100, 2: 100, 9: -100, 3: -100},
			[]Transfer{{From: 3, To: 2, AmountCents: 100}, {From: 9, To: 5, AmountCents: 100}},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Settle(tt.balances)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("Settle = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestSettleDoesNotModifyInput(t *testing.T) {
	b := map[int64]int64{1: 100, 2: -100}
	Settle(b)
	if b[1] != 100 || b[2] != -100 {
		t.Errorf("Eingabe verändert: %v", b)
	}
}
