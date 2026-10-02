// Package domain contains Zipfelkasse's pure business logic: money, splitting,
// balances, settlement and recurrence rules. No IO, no dependencies.
package domain

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Amounts are int64 in the smallest unit everywhere (cents for EUR).

// MaxAmountCents caps amounts so that multiplications during splitting
// cannot overflow (10 billion €).
const MaxAmountCents int64 = 1_000_000_000_000

// ValidationError is an input error with a German, user-readable message.
// Handlers show Error() directly in the form.
type ValidationError struct {
	Msg string
}

func (e ValidationError) Error() string { return e.Msg }

func invalid(format string, args ...any) error {
	return ValidationError{Msg: fmt.Sprintf(format, args...)}
}

// FormatCents formats cents as a German euro amount: 123456 → "1.234,56 €".
func FormatCents(c int64) string {
	return formatFixed(c, 2, true) + " €"
}

// FormatCentsInput formats cents for an input field, without thousands
// separators and without currency symbol: 123456 → "1234,56".
func FormatCentsInput(c int64) string {
	return formatFixed(c, 2, false)
}

// FormatMoney formats an amount given in the currency's smallest unit:
// (1234, "USD") → "12,34 USD", EUR or "" → "12,34 €".
func FormatMoney(minor int64, currency string) string {
	currency = strings.ToUpper(strings.TrimSpace(currency))
	if currency == "" || currency == "EUR" {
		return FormatCents(minor)
	}
	return formatFixed(minor, CurrencyDecimals(currency), true) + " " + currency
}

// FormatBasisPoints formats basis points as a percentage: 3333 → "33,33 %".
func FormatBasisPoints(bp int64) string {
	return formatFixed(bp, 2, false) + " %"
}

// ParseCents parses a euro amount such as "12,34", "12.34", "1.234,56 €".
func ParseCents(s string) (int64, error) {
	return ParseMinor(s, 2)
}

// ParseBasisPoints parses a percentage such as "33,33" or "50 %" as basis points.
func ParseBasisPoints(s string) (int64, error) {
	s = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(s), "%"))
	v, err := parseFixed(s, 2)
	if err != nil {
		return 0, invalid("Ungültige Prozentangabe „%s“.", strings.TrimSpace(s))
	}
	return v, nil
}

// ParseMinor parses an amount with the given number of decimal places and
// returns it in the smallest unit. Both comma and dot are accepted as
// decimal separator; thousands separators are recognized.
func ParseMinor(s string, decimals int) (int64, error) {
	s = strings.TrimSpace(s)
	s = strings.TrimSuffix(s, "€")
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, invalid("Bitte einen Betrag eingeben.")
	}
	v, err := parseFixed(s, decimals)
	if err != nil {
		return 0, err
	}
	return v, nil
}

func parseFixed(s string, decimals int) (int64, error) {
	s = strings.ReplaceAll(s, " ", "")
	s = strings.ReplaceAll(s, " ", "")
	if s == "" {
		return 0, invalid("Bitte einen Betrag eingeben.")
	}
	neg, intPart, frac, ok := splitNumber(s, decimals < 3)
	if !ok {
		return 0, invalid("Ungültiger Betrag „%s“.", s)
	}
	if len(frac) > decimals {
		if decimals == 0 {
			return 0, invalid("Dieser Betrag darf keine Nachkommastellen haben.")
		}
		return 0, invalid("Höchstens %d Nachkommastellen erlaubt.", decimals)
	}
	if len(intPart) > 15 {
		return 0, invalid("Der Betrag ist zu groß.")
	}
	digits := intPart + frac + strings.Repeat("0", decimals-len(frac))
	v, err := strconv.ParseInt(digits, 10, 64)
	if err != nil {
		return 0, invalid("Ungültiger Betrag „%s“.", s)
	}
	if neg {
		v = -v
	}
	return v, nil
}

// splitNumber splits a number with comma or dot as decimal separator and
// optional thousands separators into sign, integer digits and fraction
// digits (without separators; intPart is at least "0"). If both separators
// occur, the last one is the decimal separator; repeated occurrences of the
// same kind are thousands separators. A single dot before exactly three
// digits counts as a thousands separator if dotThousands is set
// ("17.000" = 17000), unless the digits before it are only zeros: then it is
// a decimal point ("0.856" = 0,856), since no number starts with a zero
// thousands group.
func splitNumber(s string, dotThousands bool) (neg bool, intPart, frac string, ok bool) {
	if s == "" {
		return false, "", "", false
	}
	switch s[0] {
	case '-':
		neg, s = true, s[1:]
	case '+':
		s = s[1:]
	}
	if s == "" {
		return false, "", "", false
	}
	for _, r := range s {
		if (r < '0' || r > '9') && r != '.' && r != ',' {
			return false, "", "", false
		}
	}

	intPart = s
	lastDot, lastComma := strings.LastIndexByte(s, '.'), strings.LastIndexByte(s, ',')
	dots, commas := strings.Count(s, "."), strings.Count(s, ",")
	var thousands byte
	switch {
	case dots > 0 && commas > 0:
		dec := max(lastDot, lastComma)
		if s[dec] == '.' {
			thousands = ','
			if dots > 1 {
				return false, "", "", false
			}
		} else {
			thousands = '.'
			if commas > 1 {
				return false, "", "", false
			}
		}
		intPart, frac = s[:dec], s[dec+1:]
	case dots+commas == 0:
	case dots+commas > 1:
		// Only one kind of separator, repeated: thousands separators.
		thousands = '.'
		if commas > 0 {
			thousands = ','
		}
	default:
		// Exactly one separator.
		pos := max(lastDot, lastComma)
		after := len(s) - pos - 1
		if s[pos] == '.' && after == 3 && dotThousands && strings.Trim(s[:pos], "0") != "" {
			thousands = '.'
		} else {
			intPart, frac = s[:pos], s[pos+1:]
			if frac == "" {
				return false, "", "", false
			}
		}
	}
	if strings.ContainsAny(frac, ".,") {
		return false, "", "", false
	}
	if thousands != 0 {
		groups := strings.Split(intPart, string(thousands))
		if len(groups[0]) == 0 || len(groups[0]) > 3 {
			return false, "", "", false
		}
		for _, g := range groups[1:] {
			if len(g) != 3 {
				return false, "", "", false
			}
		}
		intPart = strings.Join(groups, "")
	}
	if strings.ContainsAny(intPart, ".,") {
		return false, "", "", false
	}
	if intPart == "" {
		intPart = "0"
	}
	return neg, intPart, frac, true
}

// ParseRate parses an exchange rate (units of the currency per 1 €) such as
// "1,0857", "1.0857", "17000", "17.000,5" or "17,000.5". Separators work as
// for amounts (ParseMinor): a single dot before exactly three digits is a
// thousands separator ("17.000" = 17000, "1.085" = 1085), except after a
// leading zero ("0.856" = 0,856); otherwise decimals must be given with a
// comma or with more/fewer than three digits. Rates ≤ 0 are invalid.
func ParseRate(s string) (float64, error) {
	s = strings.ReplaceAll(strings.TrimSpace(s), " ", "")
	s = strings.ReplaceAll(s, " ", "")
	bad := invalid("Ungültiger Wechselkurs „%s“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €).", s)
	neg, intPart, frac, ok := splitNumber(s, true)
	if !ok || neg || len(intPart) > 12 || len(frac) > 12 {
		return 0, bad
	}
	v, err := strconv.ParseFloat(intPart+"."+frac+"0", 64)
	if err != nil || !(v > 0) || math.IsInf(v, 0) {
		return 0, bad
	}
	return v, nil
}

// formatFixed formats v with the given number of decimals, a comma as
// decimal separator and optionally dots as thousands separators.
func formatFixed(v int64, decimals int, group bool) string {
	neg := v < 0
	u := uint64(v)
	if neg {
		u = uint64(-v)
	}
	s := strconv.FormatUint(u, 10)
	if len(s) <= decimals {
		s = strings.Repeat("0", decimals-len(s)+1) + s
	}
	intPart, frac := s[:len(s)-decimals], s[len(s)-decimals:]
	if group && len(intPart) > 3 {
		var b strings.Builder
		first := len(intPart) % 3
		if first > 0 {
			b.WriteString(intPart[:first])
		}
		for i := first; i < len(intPart); i += 3 {
			if b.Len() > 0 {
				b.WriteByte('.')
			}
			b.WriteString(intPart[i : i+3])
		}
		intPart = b.String()
	}
	out := intPart
	if decimals > 0 {
		out += "," + frac
	}
	if neg {
		out = "-" + out
	}
	return out
}

// CurrencyDecimals returns the number of decimal places of a currency
// (ISO 4217). Unknown currencies have 2.
func CurrencyDecimals(currency string) int {
	switch strings.ToUpper(currency) {
	case "JPY", "KRW", "ISK", "HUF", "CLP", "VND", "XAF", "XOF", "PYG", "UGX", "IDR":
		return 0
	case "KWD", "BHD", "OMR", "JOD", "TND", "LYD", "IQD":
		return 3
	default:
		return 2
	}
}

// ToEURCents converts a foreign-currency amount (smallest unit) to euro
// cents. rate is given in ECB format: units of foreign currency per 1 EUR.
// Rounds half away from zero. For an invalid rate (<= 0) the result is 0.
func ToEURCents(minor int64, currency string, rate float64) int64 {
	if rate <= 0 || math.IsNaN(rate) || math.IsInf(rate, 0) {
		return 0
	}
	scale := math.Pow10(CurrencyDecimals(currency))
	eur := float64(minor) / scale / rate * 100
	return int64(math.Round(eur))
}
