package web

import (
	"math/big"
	"strconv"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// categoryIcon maps a category name to an icon from static/icons.svg.
// Categories can be named freely, so it searches for (German) keywords.
func categoryIcon(name string) string {
	n := strings.ToLower(name)
	for _, m := range categoryIcons {
		for _, kw := range m.keywords {
			if strings.Contains(n, kw) {
				return m.icon
			}
		}
	}
	return "tag"
}

var categoryIcons = []struct {
	icon     string
	keywords []string
}{
	{"cart", []string{"lebensmittel", "einkauf", "supermarkt", "drogerie"}},
	{"utensils", []string{"restaurant", "essen", "café", "cafe", "gastro", "lieferdienst"}},
	{"key", []string{"miete", "wohnung"}},
	{"zap", []string{"nebenkosten", "strom", "wasser", "heizung", "energie"}},
	{"home", []string{"haushalt", "möbel", "garten", "reparatur"}},
	{"car", []string{"transport", "auto", "bahn", "tank", "taxi", "parken", "fahrt", "öpnv"}},
	{"plane", []string{"reise", "urlaub", "hotel", "flug"}},
	{"ticket", []string{"freizeit", "kino", "konzert", "sport", "ausflug", "hobby", "unterhaltung"}},
	{"heart", []string{"gesundheit", "apotheke", "arzt", "medizin"}},
	{"gift", []string{"geschenk", "spende"}},
	{"shirt", []string{"kleidung", "mode", "schuhe"}},
	{"baby", []string{"kind", "baby", "kita"}},
	{"paw", []string{"haustier", "tier"}},
	{"graduation", []string{"bildung", "schule", "kurs", "buch", "bücher"}},
	{"phone", []string{"handy", "internet", "telefon", "abo", "streaming"}},
	{"shield", []string{"versicherung"}},
	{"receipt", []string{"sonstig", "allgemein"}},
}

// minorInput formats an amount in the currency's minor unit for an input
// field: (123456, "USD") → "1234,56", (500, "JPY") → "500".
func minorInput(minor int64, currency string) string {
	dec := domain.CurrencyDecimals(currency)
	if dec == 2 {
		return domain.FormatCentsInput(minor)
	}
	neg := minor < 0
	if neg {
		minor = -minor
	}
	s := strconv.FormatInt(minor, 10)
	if dec > 0 {
		if len(s) <= dec {
			s = strings.Repeat("0", dec-len(s)+1) + s
		}
		s = s[:len(s)-dec] + "," + s[len(s)-dec:]
	}
	if neg {
		s = "-" + s
	}
	return s
}

// rateInput formats an exchange rate for an input field (comma as decimal
// separator, without superfluous zeros). 0 → "".
func rateInput(rate float64) string {
	if rate <= 0 {
		return ""
	}
	return strings.Replace(strconv.FormatFloat(rate, 'f', -1, 64), ".", ",", 1)
}

// allocate distributes total proportionally to weights (largest remainder,
// ties go to the smaller index; sum of weights > 0). Needed for "by amounts"
// in a foreign currency: the amounts per person are in the foreign currency,
// while euro cents are stored, which must add up exactly. Computes with
// big.Int so that large amounts do not overflow.
func allocate(total int64, weights []int64) []int64 {
	sum := new(big.Int)
	for _, w := range weights {
		sum.Add(sum, big.NewInt(w))
	}
	out := make([]int64, len(weights))
	if sum.Sign() <= 0 {
		return out
	}
	rems := make([]*big.Int, len(weights))
	var allocated int64
	for i, w := range weights {
		q, r := new(big.Int).QuoRem(new(big.Int).Mul(big.NewInt(total), big.NewInt(w)), sum, new(big.Int))
		out[i], rems[i] = q.Int64(), r
		allocated += out[i]
	}
	for allocated < total {
		best := -1
		for i, r := range rems {
			if r.Sign() > 0 && (best < 0 || r.Cmp(rems[best]) > 0) {
				best = i
			}
		}
		if best < 0 {
			break
		}
		out[best]++
		rems[best] = new(big.Int)
		allocated++
	}
	return out
}

// Periods of the expense list as in Spliit (the week starts on Monday).
const (
	periodUpcoming = iota
	periodThisWeek
	periodEarlierThisMonth
	periodLastMonth
	periodEarlierThisYear
	periodLastYear
	periodOlder
)

var periodLabels = []string{
	"Bevorstehend", "Diese Woche", "Früher in diesem Monat", "Letzter Monat",
	"Früher in diesem Jahr", "Letztes Jahr", "Älter",
}

// expensePeriod maps an expense date to a period relative to today (both
// calendar dates, 00:00 UTC).
func expensePeriod(d, today time.Time) int {
	lastMonth := today.AddDate(0, 0, -today.Day()+1).AddDate(0, -1, 0)
	switch {
	case d.After(today):
		return periodUpcoming
	case !d.Before(weekStart(today)):
		return periodThisWeek
	case d.Year() == today.Year() && d.Month() == today.Month():
		return periodEarlierThisMonth
	case d.Year() == lastMonth.Year() && d.Month() == lastMonth.Month():
		return periodLastMonth
	case d.Year() == today.Year():
		return periodEarlierThisYear
	case d.Year() == today.Year()-1:
		return periodLastYear
	}
	return periodOlder
}

// weekStart returns the Monday of d's week.
func weekStart(d time.Time) time.Time {
	return d.AddDate(0, 0, -((int(d.Weekday()) + 6) % 7))
}

// Periods of the activity list as in Spliit.
var activityPeriodLabels = []string{
	"Heute", "Gestern", "Früher in dieser Woche", "Letzte Woche", "Früher in diesem Monat",
	"Letzter Monat", "Früher in diesem Jahr", "Letztes Jahr", "Älter",
}

// activityPeriod maps a calendar date relative to today to an entry of
// activityPeriodLabels.
func activityPeriod(d, today time.Time) int {
	lastMonth := today.AddDate(0, 0, -today.Day()+1).AddDate(0, -1, 0)
	ws := weekStart(today)
	switch {
	case !d.Before(today):
		return 0
	case d.Equal(today.AddDate(0, 0, -1)):
		return 1
	case !d.Before(ws):
		return 2
	case !d.Before(ws.AddDate(0, 0, -7)):
		return 3
	case d.Year() == today.Year() && d.Month() == today.Month():
		return 4
	case d.Year() == lastMonth.Year() && d.Month() == lastMonth.Month():
		return 5
	case d.Year() == today.Year():
		return 6
	case d.Year() == today.Year()-1:
		return 7
	}
	return 8
}
