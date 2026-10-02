package store

import (
	"database/sql/driver"
	"strings"

	"modernc.org/sqlite"
)

// foldFunc ist der Name der SQL-Funktion für die Textsuche. Sie ist beim
// Treiber registriert und steht damit jeder Verbindung zur Verfügung (auch der
// Sandbox von sql_abfrage).
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

// fold bereitet Text für die Suche ohne Rücksicht auf Groß-/Kleinschreibung
// auf: Unicode-Kleinschreibung (auch Umlaute), ß und ẞ werden zu „ss“.
// Umlaute bleiben Umlaute: „bäcker“ findet „BÄCKER“, nicht „baecker“.
func fold(s string) string {
	return strings.ReplaceAll(strings.ToLower(s), "ß", "ss")
}
