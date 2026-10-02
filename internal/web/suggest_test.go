package web

import (
	"strings"
	"testing"

	"github.com/shostakovich/zipfelkasse/internal/store"
)

func TestTitleKey(t *testing.T) {
	for in, want := range map[string]string{
		"Kaufland":          "kaufland",
		"  KAUFLAND  Mitte": "kaufland mitte",
		"Miete 03/24":       "miete",
		"Bäckerei-Müller!":  "bäckerei müller",
		"2024":              "",
	} {
		if got := titleKey(in); got != want {
			t.Errorf("titleKey(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSuggestCategories(t *testing.T) {
	const food, dining, home = 1, 2, 3
	var hist []store.TitleCategory // newest first
	add := func(title string, cat int64, n int) {
		for range n {
			hist = append(hist, store.TitleCategory{Title: title, CategoryID: cat})
		}
	}
	add("Kaufland", food, 2)
	add("kaufland", dining, 1) // outlier
	add("Kaufland", food, 3)
	add("DM", home, 1) // tie: the most recent one wins
	add("dm", food, 1)
	add("Aldi Süd", food, 1)
	add("Rewe", dining, 3) // within the window, food wins 7:3 …
	add("Rewe", food, 7)
	add("Rewe", dining, 10) // … older ones beyond the window do not count

	s := suggestCategories(hist)
	for key, want := range map[string]int64{"kaufland": food, "dm": home, "aldi süd": food, "rewe": food} {
		if got := s.Titles[key]; got != want {
			t.Errorf("Titles[%q] = %d, want %d", key, got, want)
		}
	}
	if _, ok := s.Titles["aldi"]; ok {
		t.Error(`Titles contains "aldi"`)
	}
	// Words: every word of a title, with the support of the suggested category.
	for w, want := range map[string]wordSuggest{
		"kaufland": {food, 5},
		"aldi":     {food, 1},
		"süd":      {food, 1},
		"rewe":     {food, 7},
	} {
		if got := s.Words[w]; got != want {
			t.Errorf("Words[%q] = %v, want %v", w, got, want)
		}
	}
	// Ambiguous words (1:1) and filler words do not count as single words.
	for _, w := range []string{"dm", "und"} {
		if got, ok := suggestCategories([]store.TitleCategory{{"dm", home}, {"DM", food}, {"Brot und Butter", food}, {"Brot und Käse", food}}).Words[w]; ok {
			t.Errorf("Words[%q] = %v, want none", w, got)
		}
	}
	// A word counts once per title.
	if got := suggestCategories([]store.TitleCategory{{"Rewe Rewe", food}}).Words["rewe"]; got != (wordSuggest{food, 1}) {
		t.Errorf("repeated word: %v", got)
	}
}

// The expense form carries the learned suggestions for expense-form.js.
func TestExpenseFormSuggestions(t *testing.T) {
	g := newGroup(t, nil)
	v := g.form()
	v.Set("titel", "Kaufland Mitte")
	g.create(v)
	_, body := g.get("/ausgaben/neu")
	want := `data-suggest="{"t":{"kaufland mitte":` + id(g.food) + `},"w":{"kaufland":[` + id(g.food) + `,1],"mitte":[` + id(g.food) + `,1]}}"`
	if !strings.Contains(body, want) {
		t.Errorf("form does not contain %s", want)
	}
}
