package web

import (
	"slices"
	"strings"
	"unicode"

	"github.com/shostakovich/zipfelkasse/internal/store"
)

// suggestWindow is the number of most recent categorized expenses per title
// (or word) that count for the category suggestion. Newer habits thus win
// over old ones after a few expenses, and single outliers do not matter.
const suggestWindow = 10

// categorySuggestions maps titles to the suggested category, learned from
// past expenses. The expense form (expense-form.js) looks up the normalized
// title (titleKey) in Titles; otherwise each of its words in Words and takes
// the word with the most support ("Einkauf bei Kaufland" → "kaufland").
// Words leaves out filler words and words without a clear majority.
type categorySuggestions struct {
	Titles map[string]int64       `json:"t"`
	Words  map[string]wordSuggest `json:"w"`
}

// fillerWords never count as single words: they occur in all kinds of
// titles ("Zug und Hotel", "Geschenk für Anna").
var fillerWords = map[string]bool{
	"und": true, "oder": true, "für": true, "mit": true, "ohne": true, "bei": true, "von": true, "vom": true,
	"zu": true, "zum": true, "zur": true, "in": true, "im": true, "an": true, "am": true, "auf": true,
	"aus": true, "nach": true, "über": true, "der": true, "die": true, "das": true, "den": true, "dem": true,
	"des": true, "ein": true, "eine": true, "einen": true, "einem": true, "einer": true,
}

// wordSuggest is the suggested category for a word and the number of recent
// expenses (at most suggestWindow) that support it. It is encoded as
// [category, support] to keep the page small.
type wordSuggest [2]int64

// suggestCategories learns the suggestions from hist (newest first, see
// store.CategoryHistory): per key, the most frequent category among the
// suggestWindow most recent expenses; on ties, the most recent one.
func suggestCategories(hist []store.TitleCategory) categorySuggestions {
	titles := map[string][]int64{}
	words := map[string][]int64{}
	add := func(m map[string][]int64, key string, cat int64) {
		if key != "" && len(m[key]) < suggestWindow {
			m[key] = append(m[key], cat)
		}
	}
	for _, h := range hist {
		key := titleKey(h.Title)
		add(titles, key, h.CategoryID)
		ws := strings.Fields(key)
		slices.Sort(ws)
		for _, w := range slices.Compact(ws) {
			if !fillerWords[w] {
				add(words, w, h.CategoryID)
			}
		}
	}
	s := categorySuggestions{Titles: make(map[string]int64, len(titles)), Words: make(map[string]wordSuggest, len(words))}
	for key, cats := range titles {
		s.Titles[key], _ = majority(cats)
	}
	// A single word only counts with a clear majority (at least two thirds),
	// so ambiguous words ("dm": household or groceries) suggest nothing.
	for w, cats := range words {
		if cat, n := majority(cats); 3*n >= 2*len(cats) {
			s.Words[w] = wordSuggest{cat, int64(n)}
		}
	}
	return s
}

// majority returns the most frequent category and its count; cats are newest
// first, so on ties the most recent one wins.
func majority(cats []int64) (int64, int) {
	count := map[int64]int{}
	for _, c := range cats {
		count[c]++
	}
	best := cats[0]
	for _, c := range cats {
		if count[c] > count[best] {
			best = c
		}
	}
	return best, count[best]
}

// titleKey normalizes a title for the suggestion: lower case, letters only,
// words separated by single spaces ("Miete 03/24" → "miete"). Must match
// titleKey in expense-form.js.
func titleKey(title string) string {
	return strings.Join(strings.FieldsFunc(strings.ToLower(title), func(r rune) bool { return !unicode.IsLetter(r) }), " ")
}
