package store

import (
	"database/sql/driver"
	"strings"

	"modernc.org/sqlite"
)

// foldFunc is the name of the SQL function for text search. It is registered
// with the driver and is therefore available on every connection (including
// the sql_abfrage sandbox).
const foldFunc = "zipfelkasse_fold"

func init() {
	sqlite.MustRegisterDeterministicScalarFunction(foldFunc, 1, func(_ *sqlite.FunctionContext, args []driver.Value) (driver.Value, error) {
		switch v := args[0].(type) {
		case string:
			return fold(v), nil
		case []byte:
			return fold(string(v)), nil
		case nil:
			return nil, nil
		default:
			return v, nil
		}
	})
}

// fold prepares text for case-insensitive search: Unicode lower-casing
// (including umlauts), ß and ẞ become "ss". Umlauts stay umlauts: "bäcker"
// finds "BÄCKER", not "baecker".
func fold(s string) string {
	return strings.ReplaceAll(strings.ToLower(s), "ß", "ss")
}
