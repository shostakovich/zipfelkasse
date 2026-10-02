package domain

import "time"

// FXRate is an exchange rate in ECB format: Rate units of the currency
// equal 1 EUR. Date is the day the rate applies to (for ECB rates possibly
// the last banking day before the requested date).
type FXRate struct {
	Currency string    // ISO 4217, upper case
	Date     time.Time // calendar date (00:00 UTC)
	Rate     float64   // foreign currency per 1 EUR
	Source   string    // FXSourceECB, FXSourceManual, FXSourceFixed
}

const (
	FXSourceECB    = "ezb"     // ECB reference rate
	FXSourceManual = "manuell" // entered/overridden by hand
	FXSourceFixed  = "fest"    // EUR itself, rate 1
)
