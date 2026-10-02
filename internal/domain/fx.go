package domain

import "time"

// FXRate ist ein Wechselkurs im EZB-Format: Rate Einheiten der Währung
// entsprechen 1 EUR. Date ist der Tag, für den der Kurs gilt (bei EZB-Kursen
// ggf. der letzte Bankarbeitstag vor dem gewünschten Datum).
type FXRate struct {
	Currency string    // ISO 4217, Großbuchstaben
	Date     time.Time // Kalenderdatum (00:00 UTC)
	Rate     float64   // Fremdwährung pro 1 EUR
	Source   string    // FXSourceECB, FXSourceManual, FXSourceFixed
}

const (
	FXSourceECB    = "ezb"     // EZB-Referenzkurs
	FXSourceManual = "manuell" // von Hand eingetragen/überschrieben
	FXSourceFixed  = "fest"    // EUR selbst, Kurs 1
)
