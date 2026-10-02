package export

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/ynab"
)

// --- Expenses as CSV (for Excel/Numbers) -------------------------------------

// writeExpensesCSV writes all expenses as CSV in the German Excel format:
// UTF-8 with BOM, semicolon, comma as decimal separator, CRLF. The headers are
// German (user-facing). There is one column "Anteil <Name>" per involved
// person. es is sorted chronologically.
func writeExpensesCSV(w io.Writer, people []store.Participant, es []store.Expense) error {
	if _, err := io.WriteString(w, "\uFEFF"); err != nil {
		return err
	}
	people = involved(people, es)
	cw := csv.NewWriter(w)
	cw.Comma = ';'
	cw.UseCRLF = true
	head := []string{"ID", "Datum", "Titel", "Kategorie", "Bezahlt von", "Betrag (EUR)", "Originalbetrag", "Währung",
		"Kurs", "Art", "Aufteilung", "Notiz"}
	for _, p := range people {
		head = append(head, "Anteil "+p.Name)
	}
	if err := cw.Write(head); err != nil {
		return err
	}
	for _, e := range es {
		kind, rate := "Ausgabe", ""
		if e.IsReimbursement {
			kind = "Rückzahlung"
		}
		if e.IsForeign() {
			rate = domain.FormatRate(e.FXRate)
		}
		rec := []string{
			strconv.FormatInt(e.ID, 10),
			domain.FormatDate(e.Date),
			cell(e.Title),
			cell(e.CategoryName),
			cell(e.PaidByName),
			domain.FormatDecimal(e.AmountCents, 2, ','),
			domain.FormatDecimal(e.OriginalAmountMinor, domain.CurrencyDecimals(e.OriginalCurrency), ','),
			e.OriginalCurrency,
			rate,
			kind,
			e.SplitMode.Label(),
			cell(e.Notes),
		}
		for _, p := range people {
			v := ""
			if slices.ContainsFunc(e.Shares, func(s domain.Share) bool { return s.ParticipantID == p.ID }) {
				v = domain.FormatDecimal(e.ShareOf(p.ID), 2, ',')
			}
			rec = append(rec, v)
		}
		if err := cw.Write(rec); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

// involved filters people to those who pay or take part in es.
func involved(people []store.Participant, es []store.Expense) []store.Participant {
	seen := map[int64]bool{}
	for _, e := range es {
		seen[e.PaidBy] = true
		for _, s := range e.Shares {
			seen[s.ParticipantID] = true
		}
	}
	var out []store.Participant
	for _, p := range people {
		if seen[p.ID] {
			out = append(out, p)
		}
	}
	return out
}

// cell defuses text that spreadsheet programs would otherwise execute as a
// formula (CSV injection): a leading =, +, -, @, tab or CR gets a '.
func cell(s string) string {
	if s != "" && strings.ContainsRune("=+-@\t\r", rune(s[0])) {
		return "'" + s
	}
	return s
}

// --- Expenses as JSON ---------------------------------------------------------

type jsonExport struct {
	Group        string            `json:"group"`
	ExportedAt   time.Time         `json:"exported_at"`
	From         string            `json:"from,omitempty"`
	To           string            `json:"to,omitempty"`
	Currency     string            `json:"currency"`
	Participants []jsonParticipant `json:"participants"`
	Expenses     []jsonExpense     `json:"expenses"`
}

type jsonParticipant struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Archived bool   `json:"archived"`
}

type jsonExpense struct {
	ID                  int64       `json:"id"`
	Date                string      `json:"date"`
	Title               string      `json:"title"`
	CategoryID          *int64      `json:"category_id"`
	Category            string      `json:"category"`
	PaidBy              int64       `json:"paid_by"`
	PaidByName          string      `json:"paid_by_name"`
	AmountCents         int64       `json:"amount_cents"`
	IsReimbursement     bool        `json:"is_reimbursement"`
	SplitMode           string      `json:"split_mode"`
	OriginalAmountMinor int64       `json:"original_amount_minor"`
	OriginalCurrency    string      `json:"original_currency"`
	FXRate              float64     `json:"fx_rate"`
	FXSource            string      `json:"fx_source"`
	Notes               string      `json:"notes"`
	RecurringID         *int64      `json:"recurring_id"`
	Shares              []jsonShare `json:"shares"`
	CreatedAt           time.Time   `json:"created_at"`
	UpdatedAt           time.Time   `json:"updated_at"`
}

type jsonShare struct {
	ParticipantID int64  `json:"participant_id"`
	Name          string `json:"name"`
	Weight        int64  `json:"weight"`
	AmountCents   int64  `json:"amount_cents"`
}

func optID(id int64) *int64 {
	if id == 0 {
		return nil
	}
	return &id
}

func writeExpensesJSON(w io.Writer, group string, now time.Time, p period, people []store.Participant, es []store.Expense) error {
	names := map[int64]string{}
	out := jsonExport{Group: group, ExportedAt: now.UTC(), Currency: "EUR",
		Participants: []jsonParticipant{}, Expenses: []jsonExpense{}}
	if !p.From.IsZero() {
		out.From = p.From.Format(domain.DateLayout)
	}
	if !p.To.IsZero() {
		out.To = p.To.Format(domain.DateLayout)
	}
	for _, pp := range people {
		names[pp.ID] = pp.Name
		out.Participants = append(out.Participants, jsonParticipant{ID: pp.ID, Name: pp.Name, Archived: pp.Archived()})
	}
	for _, e := range es {
		je := jsonExpense{
			ID: e.ID, Date: e.Date.Format(domain.DateLayout), Title: e.Title,
			CategoryID: optID(e.CategoryID), Category: e.CategoryName,
			PaidBy: e.PaidBy, PaidByName: e.PaidByName, AmountCents: e.AmountCents,
			IsReimbursement: e.IsReimbursement, SplitMode: string(e.SplitMode),
			OriginalAmountMinor: e.OriginalAmountMinor, OriginalCurrency: e.OriginalCurrency,
			FXRate: e.FXRate, FXSource: e.FXSource, Notes: e.Notes, RecurringID: optID(e.RecurringID),
			Shares: []jsonShare{}, CreatedAt: e.CreatedAt.UTC(), UpdatedAt: e.UpdatedAt.UTC(),
		}
		for _, s := range e.Shares {
			je.Shares = append(je.Shares, jsonShare{ParticipantID: s.ParticipantID, Name: names[s.ParticipantID],
				Weight: s.Weight, AmountCents: s.AmountCents})
		}
		out.Expenses = append(out.Expenses, je)
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(out)
}

// --- My shares for YNAB: OFX ----------------------------------------------------

// writeOFX writes the transactions as OFX 1.02 (SGML) – a statement of the
// clearing account. FITID is stable per expense ("zipfelkasse-<ID>").
// Encoding UTF-8 (declared as such), line ending CRLF.
func writeOFX(w io.Writer, ps []ynab.Posting, accountID string, from, to, now time.Time) error {
	if from.IsZero() || to.IsZero() {
		lo, hi := now, now
		if len(ps) > 0 {
			lo, hi = ps[0].Date, ps[len(ps)-1].Date
		}
		if from.IsZero() {
			from = lo
		}
		if to.IsZero() {
			to = hi
		}
	}
	var total int64
	for _, p := range ps {
		total -= p.AmountCents
	}
	var b strings.Builder
	line := func(format string, args ...any) {
		fmt.Fprintf(&b, format, args...)
		b.WriteString("\r\n")
	}
	for _, h := range []string{"OFXHEADER:100", "DATA:OFXSGML", "VERSION:102", "SECURITY:NONE", "ENCODING:UTF-8",
		"CHARSET:NONE", "COMPRESSION:NONE", "OLDFILEUID:NONE", "NEWFILEUID:NONE", ""} {
		line("%s", h)
	}
	line("<OFX>")
	line("<SIGNONMSGSRSV1>")
	line("<SONRS>")
	line("<STATUS>")
	line("<CODE>0")
	line("<SEVERITY>INFO")
	line("</STATUS>")
	line("<DTSERVER>%s", now.UTC().Format("20060102150405"))
	line("<LANGUAGE>GER")
	line("</SONRS>")
	line("</SIGNONMSGSRSV1>")
	line("<BANKMSGSRSV1>")
	line("<STMTTRNRS>")
	line("<TRNUID>1")
	line("<STATUS>")
	line("<CODE>0")
	line("<SEVERITY>INFO")
	line("</STATUS>")
	line("<STMTRS>")
	line("<CURDEF>EUR")
	line("<BANKACCTFROM>")
	line("<BANKID>ZIPFEL") // OFX allows at most 9 characters
	line("<ACCTID>%s", sgml(accountID, 22))
	line("<ACCTTYPE>CHECKING")
	line("</BANKACCTFROM>")
	line("<BANKTRANLIST>")
	line("<DTSTART>%s", from.Format("20060102"))
	line("<DTEND>%s", to.Format("20060102"))
	for _, p := range ps {
		line("<STMTTRN>")
		line("<TRNTYPE>DEBIT")
		line("<DTPOSTED>%s", p.Date.Format("20060102"))
		line("<TRNAMT>%s", domain.FormatDecimal(-p.AmountCents, 2, '.'))
		line("<FITID>zipfelkasse-%d", p.ExpenseID)
		line("<NAME>%s", sgml(p.Payee, 32))
		line("<MEMO>%s", sgml(p.Memo, 255))
		line("</STMTTRN>")
	}
	line("</BANKTRANLIST>")
	line("<LEDGERBAL>")
	line("<BALAMT>%s", domain.FormatDecimal(total, 2, '.'))
	line("<DTASOF>%s", to.Format("20060102"))
	line("</LEDGERBAL>")
	line("</STMTRS>")
	line("</STMTTRNRS>")
	line("</BANKMSGSRSV1>")
	line("</OFX>")
	_, err := io.WriteString(w, b.String())
	return err
}

// sgml truncates to n characters (OFX field lengths), removes line breaks and
// escapes &, < and >.
func sgml(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > n {
		s = strings.TrimSpace(string(r[:n]))
	}
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

// --- My shares for YNAB: CSV -----------------------------------------------------

// writeYNABCSV writes the transactions in the CSV format of the YNAB file
// import: Date,Payee,Memo,Outflow,Inflow; ISO date (year first, unambiguous),
// amounts with a dot, UTF-8 without BOM.
func writeYNABCSV(w io.Writer, ps []ynab.Posting) error {
	cw := csv.NewWriter(w)
	if err := cw.Write([]string{"Date", "Payee", "Memo", "Outflow", "Inflow"}); err != nil {
		return err
	}
	for _, p := range ps {
		if err := cw.Write([]string{p.Date.Format(domain.DateLayout), cell(p.Payee), cell(p.Memo), domain.FormatDecimal(p.AmountCents, 2, '.'), ""}); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}
