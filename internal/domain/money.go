// Package domain enthält die reine Fachlogik von Zipfelkasse: Geld, Aufteilung,
// Salden, Ausgleich und Wiederholungsregeln. Kein IO, keine Abhängigkeiten.
package domain

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Beträge sind überall int64 in der kleinsten Einheit (Cent bei EUR).

// MaxAmountCents begrenzt Beträge, damit Multiplikationen bei der Aufteilung
// nicht überlaufen (10 Mrd. €).
const MaxAmountCents int64 = 1_000_000_000_000

// ValidationError ist ein Eingabefehler mit einer deutschen, für Nutzer
// lesbaren Meldung. Handler zeigen Error() direkt im Formular an.
type ValidationError struct {
	Msg string
}

func (e ValidationError) Error() string { return e.Msg }

func invalid(format string, args ...any) error {
	return ValidationError{Msg: fmt.Sprintf(format, args...)}
}

// FormatCents formatiert Cent als deutschen Euro-Betrag: 123456 → "1.234,56 €".
func FormatCents(c int64) string {
	return formatFixed(c, 2, true) + " €"
}

// FormatCentsInput formatiert Cent für ein Eingabefeld, ohne Tausenderpunkte
// und ohne Währungszeichen: 123456 → "1234,56".
func FormatCentsInput(c int64) string {
	return formatFixed(c, 2, false)
}

// FormatMoney formatiert einen Betrag in der kleinsten Einheit der Währung:
// (1234, "USD") → "12,34 USD", EUR bzw. "" → "12,34 €".
func FormatMoney(minor int64, currency string) string {
	currency = strings.ToUpper(strings.TrimSpace(currency))
	if currency == "" || currency == "EUR" {
		return FormatCents(minor)
	}
	return formatFixed(minor, CurrencyDecimals(currency), true) + " " + currency
}

// FormatBasisPoints formatiert Basispunkte als Prozent: 3333 → "33,33 %".
func FormatBasisPoints(bp int64) string {
	return formatFixed(bp, 2, false) + " %"
}

// ParseCents liest einen Euro-Betrag wie „12,34“, „12.34“, „1.234,56 €“.
func ParseCents(s string) (int64, error) {
	return ParseMinor(s, 2)
}

// ParseBasisPoints liest eine Prozentangabe wie „33,33“ oder „50 %“ als Basispunkte.
func ParseBasisPoints(s string) (int64, error) {
	s = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(s), "%"))
	v, err := parseFixed(s, 2)
	if err != nil {
		return 0, invalid("Ungültige Prozentangabe „%s“.", strings.TrimSpace(s))
	}
	return v, nil
}

// ParseMinor liest einen Betrag mit der gegebenen Zahl an Nachkommastellen
// und liefert ihn in der kleinsten Einheit. Komma und Punkt sind als
// Dezimaltrennzeichen erlaubt; Tausendertrennzeichen werden erkannt.
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

// splitNumber zerlegt eine Zahl mit Komma oder Punkt als Dezimaltrenner
// und optionalen Tausendertrennern in Vorzeichen, Ganzzahl- und
// Nachkommaziffern (ohne Trenner; intPart mindestens "0"). Kommen beide
// Trenner vor, ist der letzte der Dezimaltrenner; mehrfach dieselbe Sorte
// sind Tausendertrenner. Ein einzelner Punkt vor genau drei Ziffern gilt als
// Tausendertrenner, wenn dotThousands gesetzt ist („17.000“ = 17000).
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
		// Nur eine Sorte Trenner, mehrfach: Tausendertrenner.
		thousands = '.'
		if commas > 0 {
			thousands = ','
		}
	default:
		// Genau ein Trenner.
		pos := max(lastDot, lastComma)
		after := len(s) - pos - 1
		if s[pos] == '.' && after == 3 && dotThousands && pos > 0 {
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

// ParseRate liest einen Wechselkurs (Einheiten der Währung pro 1 €) wie
// „1,0857“, „1.0857“, „17000“, „17.000,5“ oder „17,000.5“. Trenner wie bei
// Beträgen (ParseMinor): Ein einzelner Punkt vor genau drei Ziffern ist ein
// Tausenderpunkt („17.000“ = 17000, „1.085“ = 1085); Nachkommastellen also
// mit Komma oder mit mehr/weniger als drei Ziffern angeben. Kurse ≤ 0 sind ungültig.
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

// formatFixed formatiert v mit decimals Nachkommastellen, Komma als
// Dezimaltrenner und optional Punkten als Tausendertrenner.
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

// CurrencyDecimals liefert die Zahl der Nachkommastellen einer Währung
// (ISO 4217). Unbekannte Währungen haben 2.
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

// ToEURCents rechnet einen Fremdwährungsbetrag (kleinste Einheit) in Euro-Cent
// um. rate ist im EZB-Format angegeben: Einheiten Fremdwährung pro 1 EUR.
// Gerundet wird kaufmännisch. Bei ungültigem Kurs (<= 0) ist das Ergebnis 0.
func ToEURCents(minor int64, currency string, rate float64) int64 {
	if rate <= 0 || math.IsNaN(rate) || math.IsInf(rate, 0) {
		return 0
	}
	scale := math.Pow10(CurrencyDecimals(currency))
	eur := float64(minor) / scale / rate * 100
	return int64(math.Round(eur))
}
