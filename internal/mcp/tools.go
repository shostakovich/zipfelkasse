package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
)

const serverVersion = "1.0.0"

func serverInfo() map[string]any {
	return map[string]any{"name": "zipfelkasse", "title": "Zipfelkasse – shared expenses", "version": serverVersion}
}

// instructionsText explains the server to the model (initialize,
// server/discover); instructions() appends today's date.
const instructionsText = `Zipfelkasse manages the shared expenses of a single group (like Splitwise/Spliit). All tools are read-only.
Amounts are in euros. Every amount in a result appears twice: as text with a dot as decimal separator and no thousands separator ("1234.56") and as an integer in cents (field ending in _cents).
Balance: positive = is owed money by the others, negative = owes money.
Reimbursements are settlement payments between two people, not expenses; they count for balances, not for expense statistics.
Dates use the format YYYY-MM-DD. Refer to people and categories by name (case-insensitive). Names, titles, categories and notes are stored as entered (often in German).
How to proceed: balances and settlement → balances. Finding individual expenses → search_expenses. Totals by category, month or person → statistics.
Anything else → read schema first, then sql_query (SQLite, SELECT only).`

// categoryHint explains the category value for expenses without a category.
const categoryHint = `Use "` + noCategoryArg + `" for expenses without a category (statistics labels them "` + store.NoCategory + `").`

// server is the MCP handler with its tools.
type server struct {
	d      web.Deps
	log    *slog.Logger
	order  []string // tool order for tools/list (deterministic)
	tools  map[string]tool
	sqlSem chan struct{} // limits concurrent sql_query sandboxes
	now    func() time.Time
}

// location is the server time zone (TZ).
func (s *server) location() *time.Location {
	if s.d.Config.Location != nil {
		return s.d.Config.Location
	}
	return time.Local
}

// todayLine states the current date in the server time zone. It is computed
// per request so that long-running servers never report a stale date.
func (s *server) todayLine() string {
	loc := s.location()
	today := domain.DateOf(s.now().In(loc))
	return fmt.Sprintf("Today is %s (%s), server time zone %s. Resolve relative periods such as \"last month\" from this date.",
		today.Format(domain.DateLayout), today.Weekday(), loc)
}

func (s *server) instructions() string { return instructionsText + "\n" + s.todayLine() }

// discoverTTL caches server/discover (which contains the date) at most until
// the next midnight in the server time zone.
func (s *server) discoverTTL() time.Duration {
	now := s.now().In(s.location())
	y, m, d := now.Date()
	return min(listTTL, time.Date(y, m, d+1, 0, 0, 0, 0, now.Location()).Sub(now))
}

type tool struct {
	def map[string]any
	run func(ctx context.Context, args json.RawMessage) (toolResult, error)
}

// toolResult: data becomes structuredContent (and, without text, the text
// content as JSON).
type toolResult struct {
	text string
	data any
}

// Values of the reimbursements argument of search_expenses.
const (
	reimbursementsExclude = "exclude"
	reimbursementsInclude = "include"
	reimbursementsOnly    = "only"
)

var reimbursementModes = []string{reimbursementsExclude, reimbursementsInclude, reimbursementsOnly}

// groupings are the valid group_by values of statistics.
var groupings = []string{store.StatsByCategory, store.StatsByMonth, store.StatsByPerson, store.StatsByCategoryMonth}

func newServer(d web.Deps) *server {
	s := &server{d: d, log: newLogger(d), tools: map[string]tool{}, sqlSem: make(chan struct{}, 2), now: time.Now}
	readOnly := map[string]any{"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
	add := func(name, title, desc string, schema map[string]any, run func(context.Context, json.RawMessage) (toolResult, error)) {
		s.order = append(s.order, name)
		s.tools[name] = tool{
			def: map[string]any{"name": name, "title": title, "description": desc, "inputSchema": schema, "annotations": readOnly},
			run: run,
		}
	}
	dateProp := func(desc string) map[string]any {
		return map[string]any{"type": "string", "description": desc + " Format YYYY-MM-DD (DD.MM.YYYY is accepted too)."}
	}

	add("balances", "Balances and settlement",
		"Current balance of each person in euros and a settlement proposal (who transfers how much to whom so that everyone ends at 0). "+
			"Positive balance = is owed money, negative = owes money. Includes all non-deleted expenses and reimbursements.",
		map[string]any{"type": "object", "properties": map[string]any{}, "additionalProperties": false},
		s.balances)

	add("search_expenses", "Search expenses",
		"Searches individual expenses (newest first) with amount, payer, category and split (each person's share). "+
			"All filters are optional and are combined. Also returns the total number of matches, their total and – with person – "+
			"the total of that person's shares. For plain totals by category/month, statistics is the better choice.",
		map[string]any{
			"type": "object",
			"properties": map[string]any{
				"from":     dateProp("First date (inclusive)."),
				"to":       dateProp("Last date (inclusive)."),
				"category": map[string]any{"type": "string", "description": `Category name, e.g. "Lebensmittel". ` + categoryHint},
				"person":   map[string]any{"type": "string", "description": "Name of a person: finds expenses they paid OR take part in."},
				"text":     map[string]any{"type": "string", "description": "Substring of the title or notes (case-insensitive)."},
				"reimbursements": map[string]any{"type": "string", "enum": reimbursementModes,
					"description": "Reimbursements (settlement payments between people): hide them (exclude, default), include them (include) or return only them (only)."},
				"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": store.SQLMaxRows, "description": "Maximum number of expenses returned, default 50."},
			},
			"additionalProperties": false,
		},
		s.searchExpenses)

	add("statistics", "Statistics",
		"Expense totals grouped by category, month (YYYY-MM), person or category_month, optionally for a period. "+
			"Without share_of: total amounts of the expenses. With share_of: only that person's share of each expense, i.e. what they consumed themselves "+
			`(e.g. "How much did I spend on restaurants in 2026?"). With group_by=person, amount is each person's share (consumption) `+
			"and paid is what they paid up front. Reimbursements and deleted expenses never count.",
		map[string]any{
			"type": "object",
			"properties": map[string]any{
				"group_by": map[string]any{"type": "string", "enum": groupings, "description": "What to group by."},
				"from":     dateProp("First date (inclusive)."),
				"to":       dateProp("Last date (inclusive)."),
				"share_of": map[string]any{"type": "string", "description": "Name of a person: only their share counts (that person's perspective). Empty = total amounts."},
				"category": map[string]any{"type": "string", "description": "Only count expenses of this category (name, case-insensitive). " + categoryHint},
			},
			"required":             []string{"group_by"},
			"additionalProperties": false,
		},
		s.statistics)

	add("schema", "Database schema",
		"Explains the database tables and columns in words (amounts in cents, deleted expenses, reimbursements, shares, foreign currency), "+
			"lists people and categories and returns the CREATE statements. Call before sql_query.",
		map[string]any{"type": "object", "properties": map[string]any{}, "additionalProperties": false},
		s.schema)

	add("sql_query", "SQL query",
		fmt.Sprintf("Runs exactly one read-only SQL query (SQLite dialect, only SELECT or WITH … SELECT) on a read-only copy of the data. "+
			"Call schema first. Important: amounts are cents (divide by 100.0 for euros), exclude deleted expenses with deleted_at IS NULL, "+
			"reimbursements (is_reimbursement = 1) are not expenses, a person's share is expense_shares.amount_cents. "+
			"At most %d rows, aborted after %d seconds, texts longer than 2000 characters are truncated. "+
			"For standard questions, balances, search_expenses and statistics are simpler.", store.SQLMaxRows, int(store.SQLTimeout/time.Second)),
		map[string]any{
			"type": "object",
			"properties": map[string]any{
				"query": map[string]any{"type": "string", "description": "The SQL query, e.g. SELECT name FROM participants WHERE archived_at IS NULL"},
			},
			"required":             []string{"query"},
			"additionalProperties": false,
		},
		s.sqlQuery)
	return s
}

func (s *server) toolDefs() []any {
	out := make([]any, len(s.order))
	for i, name := range s.order {
		out[i] = s.tools[name].def
	}
	return out
}

func invalid(format string, args ...any) error {
	return domain.ValidationError{Msg: fmt.Sprintf(format, args...)}
}

// decodeArgs decodes the tool arguments strictly (unknown fields are errors).
func decodeArgs(raw json.RawMessage, v any) error {
	if b := bytes.TrimSpace(raw); len(b) == 0 || string(b) == "null" {
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return invalid("Invalid arguments: %v", err)
	}
	return nil
}

// eur formats cents as a locale-neutral amount: 123456 → "1234.56" (dot as
// decimal separator, no thousands separator, no currency sign).
func eur(c int64) string { return domain.FormatDecimal(c, 2, '.') }

// money formats an amount in the smallest unit of a currency: (2340, "USD")
// → "23.40 USD".
func money(minor int64, currency string) string {
	currency = strings.ToUpper(strings.TrimSpace(currency))
	return domain.FormatDecimal(minor, domain.CurrencyDecimals(currency), '.') + " " + currency
}

func parseDateArg(name, v string) (time.Time, error) {
	if v = strings.TrimSpace(v); v == "" {
		return time.Time{}, nil
	}
	t, err := domain.ParseDate(v)
	if err != nil {
		return time.Time{}, invalid("Invalid date for %s: %q (expected YYYY-MM-DD).", name, v)
	}
	return t, nil
}

func parseRange(fromArg, toArg string) (time.Time, time.Time, error) {
	from, err := parseDateArg("from", fromArg)
	if err != nil {
		return from, from, err
	}
	to, err := parseDateArg("to", toArg)
	if err != nil {
		return from, to, err
	}
	if !from.IsZero() && !to.IsZero() && to.Before(from) {
		return from, to, invalid(`"to" (%s) is before "from" (%s).`, to.Format(domain.DateLayout), from.Format(domain.DateLayout))
	}
	return from, to, nil
}

func describeRange(from, to time.Time) string {
	switch {
	case from.IsZero() && to.IsZero():
		return "all time"
	case to.IsZero():
		return "from " + from.Format(domain.DateLayout)
	case from.IsZero():
		return "until " + to.Format(domain.DateLayout)
	}
	return from.Format(domain.DateLayout) + " to " + to.Format(domain.DateLayout)
}

// participantNames returns id → name of all people (archived ones too).
func (s *server) participantNames(ctx context.Context) (map[int64]string, []store.Participant, error) {
	ps, err := s.d.Store.ListParticipants(ctx, true)
	if err != nil {
		return nil, nil, err
	}
	m := make(map[int64]string, len(ps))
	for _, p := range ps {
		m[p.ID] = p.Name
	}
	return m, ps, nil
}

func (s *server) findPerson(ctx context.Context, name string) (store.Participant, error) {
	_, ps, err := s.participantNames(ctx)
	if err != nil {
		return store.Participant{}, err
	}
	name = strings.TrimSpace(name)
	names := make([]string, 0, len(ps))
	for _, p := range ps {
		if strings.EqualFold(p.Name, name) {
			return p, nil
		}
		names = append(names, p.Name)
	}
	return store.Participant{}, invalid("Unknown person %q. Available: %s.", name, strings.Join(names, ", "))
}

func (s *server) findCategory(ctx context.Context, name string) (store.Category, error) {
	cs, err := s.d.Store.ListCategories(ctx, true)
	if err != nil {
		return store.Category{}, err
	}
	name = strings.TrimSpace(name)
	names := make([]string, 0, len(cs))
	for _, c := range cs {
		if strings.EqualFold(c.Name, name) {
			return c, nil
		}
		names = append(names, c.Name)
	}
	return store.Category{}, invalid("Unknown category %q. Available: %s.", name, strings.Join(names, ", "))
}

// categoryArg resolves a category argument: a category name, or "none" /
// "No category" (the statistics label) for expenses without a category.
// A real category with that name takes precedence.
func (s *server) categoryArg(ctx context.Context, name string) (id int64, without bool, err error) {
	if strings.TrimSpace(name) == "" {
		return 0, false, nil
	}
	c, err := s.findCategory(ctx, name)
	if err == nil {
		return c.ID, false, nil
	}
	if n := strings.TrimSpace(name); strings.EqualFold(n, noCategoryArg) || strings.EqualFold(n, store.NoCategory) {
		return 0, true, nil
	}
	return 0, false, err
}

// noCategoryArg is the category value for expenses without a category.
const noCategoryArg = "none"

// --- balances ----------------------------------------------------------------

type balanceOut struct {
	Person       string `json:"person"`
	Balance      string `json:"balance"`
	BalanceCents int64  `json:"balance_cents"`
	Status       string `json:"status"`
}

type transferOut struct {
	From        string `json:"from"`
	To          string `json:"to"`
	Amount      string `json:"amount"`
	AmountCents int64  `json:"amount_cents"`
}

func (s *server) balances(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct{}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	bal, err := s.d.Store.Balances(ctx)
	if err != nil {
		return toolResult{}, err
	}
	names, ps, err := s.participantNames(ctx)
	if err != nil {
		return toolResult{}, err
	}
	balances := []balanceOut{}
	for _, p := range ps {
		v := bal[p.ID]
		if p.Archived() && v == 0 {
			continue
		}
		status := "settled"
		switch {
		case v > 0:
			status = "is owed money"
		case v < 0:
			status = "owes money"
		}
		balances = append(balances, balanceOut{Person: p.Name, Balance: eur(v), BalanceCents: v, Status: status})
	}
	settlements := []transferOut{}
	for _, t := range domain.Settle(bal) {
		settlements = append(settlements, transferOut{From: names[t.From], To: names[t.To], Amount: eur(t.AmountCents), AmountCents: t.AmountCents})
	}
	return toolResult{data: map[string]any{
		"balances":    balances,
		"settlements": settlements,
		"note":        "Positive balance = is owed money, negative = owes money. settlements: the transfers needed so that everyone ends at 0.",
	}}, nil
}

// --- search_expenses -------------------------------------------------------------

type shareOut struct {
	Person      string `json:"person"`
	Amount      string `json:"amount"`
	AmountCents int64  `json:"amount_cents"`
}

type expenseOut struct {
	ID            int64      `json:"id"`
	Date          string     `json:"date"`
	Title         string     `json:"title"`
	Category      string     `json:"category,omitempty"`
	PaidBy        string     `json:"paid_by"`
	Amount        string     `json:"amount"`
	AmountCents   int64      `json:"amount_cents"`
	Reimbursement bool       `json:"reimbursement,omitempty"`
	Recipient     string     `json:"recipient,omitempty"` // recipient of a reimbursement
	Original      string     `json:"original,omitempty"`
	FXRate        float64    `json:"fx_rate,omitempty"`
	FXSource      string     `json:"fx_source,omitempty"`
	Notes         string     `json:"notes,omitempty"`
	Split         string     `json:"split,omitempty"`
	Shares        []shareOut `json:"shares,omitempty"`
}

func (s *server) searchExpenses(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct {
		From           string `json:"from"`
		To             string `json:"to"`
		Category       string `json:"category"`
		Person         string `json:"person"`
		Text           string `json:"text"`
		Reimbursements string `json:"reimbursements"`
		Limit          int    `json:"limit"`
	}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	var f store.ExpenseFilter
	var err error
	if f.From, f.To, err = parseRange(args.From, args.To); err != nil {
		return toolResult{}, err
	}
	f.Text = strings.TrimSpace(args.Text)
	if f.CategoryID, f.WithoutCategory, err = s.categoryArg(ctx, args.Category); err != nil {
		return toolResult{}, err
	}
	var person store.Participant
	if strings.TrimSpace(args.Person) != "" {
		if person, err = s.findPerson(ctx, args.Person); err != nil {
			return toolResult{}, err
		}
		f.ParticipantID = person.ID
	}
	mode := cmpOr(args.Reimbursements, reimbursementsExclude)
	if !slices.Contains(reimbursementModes, mode) {
		return toolResult{}, invalid(`reimbursements must be "exclude", "include" or "only".`)
	}
	limit := args.Limit
	switch {
	case limit == 0:
		limit = 50
	case limit < 1 || limit > store.SQLMaxRows:
		return toolResult{}, invalid("limit must be between 1 and %d.", store.SQLMaxRows)
	}

	es, err := s.d.Store.ListExpenses(ctx, f)
	if err != nil {
		return toolResult{}, err
	}
	names, _, err := s.participantNames(ctx)
	if err != nil {
		return toolResult{}, err
	}
	var sum, share int64
	hits := 0
	out := []expenseOut{}
	for _, e := range es {
		if (mode == reimbursementsExclude && e.IsReimbursement) || (mode == reimbursementsOnly && !e.IsReimbursement) {
			continue
		}
		hits++
		sum += e.AmountCents
		share += e.ShareOf(person.ID)
		if len(out) < limit {
			out = append(out, expenseToOut(e, names))
		}
	}
	data := map[string]any{
		"matches":     hits,
		"shown":       len(out),
		"truncated":   hits > len(out),
		"total":       eur(sum),
		"total_cents": sum,
		"expenses":    out,
	}
	if person.ID != 0 {
		data["person_share"] = map[string]any{"person": person.Name, "amount": eur(share), "amount_cents": share}
	}
	return toolResult{data: data}, nil
}

func expenseToOut(e store.Expense, names map[int64]string) expenseOut {
	o := expenseOut{
		ID: e.ID, Date: e.Date.Format(domain.DateLayout), Title: e.Title, Category: e.CategoryName,
		PaidBy: e.PaidByName, Amount: eur(e.AmountCents), AmountCents: e.AmountCents, Notes: e.Notes,
	}
	if e.IsForeign() {
		o.Original = money(e.OriginalAmountMinor, e.OriginalCurrency)
		o.FXRate, o.FXSource = e.FXRate, e.FXSource
	}
	if e.IsReimbursement {
		o.Reimbursement = true
		if len(e.Shares) > 0 {
			o.Recipient = names[e.Shares[0].ParticipantID]
		}
		return o
	}
	o.Split = string(e.SplitMode)
	for _, sh := range e.Shares {
		o.Shares = append(o.Shares, shareOut{Person: names[sh.ParticipantID], Amount: eur(sh.AmountCents), AmountCents: sh.AmountCents})
	}
	return o
}

func cmpOr(v, fallback string) string {
	if v = strings.TrimSpace(v); v != "" {
		return v
	}
	return fallback
}

// --- statistics ------------------------------------------------------------------

type statOut struct {
	Category    string `json:"category,omitempty"`
	Month       string `json:"month,omitempty"`
	Person      string `json:"person,omitempty"`
	Count       int64  `json:"count"`
	Amount      string `json:"amount"`
	AmountCents int64  `json:"amount_cents"`
	Paid        string `json:"paid,omitempty"`
	PaidCents   *int64 `json:"paid_cents,omitempty"`
}

func (s *server) statistics(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct {
		GroupBy  string `json:"group_by"`
		From     string `json:"from"`
		To       string `json:"to"`
		ShareOf  string `json:"share_of"`
		Category string `json:"category"`
	}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	f := store.StatsFilter{GroupBy: strings.TrimSpace(args.GroupBy)}
	if !slices.Contains(groupings, f.GroupBy) {
		return toolResult{}, invalid("group_by must be one of %s.", strings.Join(groupings, ", "))
	}
	var err error
	if f.From, f.To, err = parseRange(args.From, args.To); err != nil {
		return toolResult{}, err
	}
	if f.CategoryID, f.WithoutCategory, err = s.categoryArg(ctx, args.Category); err != nil {
		return toolResult{}, err
	}
	perspective := "total amounts of the expenses"
	if strings.TrimSpace(args.ShareOf) != "" {
		p, err := s.findPerson(ctx, args.ShareOf)
		if err != nil {
			return toolResult{}, err
		}
		f.ParticipantID = p.ID
		perspective = "only the share of " + p.Name
	}
	rows, err := s.d.Store.Stats(ctx, f)
	if err != nil {
		return toolResult{}, err
	}
	var total int64
	out := []statOut{}
	for _, r := range rows {
		o := statOut{Category: r.Category, Month: r.Month, Person: r.Person, Count: r.Count, Amount: eur(r.AmountCents), AmountCents: r.AmountCents}
		if f.GroupBy == store.StatsByPerson {
			paid := r.PaidCents
			o.Paid, o.PaidCents = eur(paid), &paid
		}
		total += r.AmountCents
		out = append(out, o)
	}
	note := "Reimbursements and deleted expenses are not included. count = number of expenses."
	if f.GroupBy == store.StatsByPerson {
		note += " amount = the person's share (consumption), paid = what they paid for the group."
	}
	return toolResult{data: map[string]any{
		"group_by":    f.GroupBy,
		"perspective": perspective,
		"period":      describeRange(f.From, f.To),
		"rows":        out,
		"total":       eur(total),
		"total_cents": total,
		"note":        note,
	}}, nil
}

// --- schema -----------------------------------------------------------------------

const schemaText = `Database of Zipfelkasse (SQLite). A single group.
Conventions: amounts are INTEGER in euro cents (divide by 100.0 for euros). Calendar dates are TEXT 'YYYY-MM-DD', timestamps TEXT RFC 3339 in UTC. Booleans are 0/1.
Data values (names, titles, categories, notes) are stored as entered, often in German.

Tables:
- participants: people in the group. archived_at set = archived (no longer active, their entries remain).
- categories: categories (name, position = display order, archived_at).
- expenses: expenses AND reimbursements.
  * deleted_at set = deleted (soft delete) → ALWAYS filter with "deleted_at IS NULL".
  * amount_cents: amount in euro cents (converted for foreign currency). paid_by: who paid (participants.id). category_id NULL = no category.
  * is_reimbursement = 1: reimbursement – paid_by paid money to the person in the single expense_shares row. It is not an expense
    (expense analyses use "is_reimbursement = 0"), but it counts for balances.
  * split_mode: equal (evenly), shares (by shares), percent (by percentage), amount (fixed amounts).
  * Foreign currency: original_currency ('EUR' if none), original_amount_minor (amount in the smallest unit of that currency),
    fx_rate (units of foreign currency per 1 EUR, ECB format), fx_source ('ezb' = ECB reference rate, 'manuell' = entered manually, or '' for EUR). amount_cents is already converted.
  * recurring_id: created automatically from a recurring rule. created_at/updated_at: timestamps.
- expense_shares: split of each expense across people. amount_cents = this person's share in cents (sum per expense = expenses.amount_cents).
  weight depends on split_mode: equal 1, shares the share count, percent basis points (sum 10000), amount the amount in the smallest unit of original_currency (sum = original_amount_minor; cents for EUR).
- recurring: rules for recurring expenses (template_json = template as JSON, frequency weekly|monthly|yearly, start_date, next_date, active).
- activity: change log (at, actor_id NULL = system, action expense_created|expense_updated|expense_deleted, expense_id, details_json).
- fx_rates: exchange rates per currency, source ('ezb' or 'manuell') and date (foreign currency per 1 EUR).
  A day can have both an ECB and a manual rate; the most recent manual rate on or before a date takes precedence over the ECB rate.
- settings: settings (key/value, e.g. group_name, default_currency).
YNAB tables (credentials) are not visible via MCP.

Balance of a person = sum of amount_cents of the expenses they paid − sum of their shares in expense_shares
(only deleted_at IS NULL, reimbursements included). Positive = is owed money.

Example – Anna's share per category in 2026:
SELECT coalesce(c.name, '` + store.NoCategory + `') AS category, sum(x.amount_cents) / 100.0 AS euros
FROM expenses e
JOIN expense_shares x ON x.expense_id = e.id
JOIN participants p ON p.id = x.participant_id AND p.name = 'Anna'
LEFT JOIN categories c ON c.id = e.category_id
WHERE e.deleted_at IS NULL AND e.is_reimbursement = 0 AND e.date BETWEEN '2026-01-01' AND '2026-12-31'
GROUP BY 1 ORDER BY 2 DESC;
`

func (s *server) schema(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct{}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	objs, err := s.d.Store.MCPSchema(ctx)
	if err != nil {
		return toolResult{}, err
	}
	_, ps, err := s.participantNames(ctx)
	if err != nil {
		return toolResult{}, err
	}
	cs, err := s.d.Store.ListCategories(ctx, true)
	if err != nil {
		return toolResult{}, err
	}
	var b strings.Builder
	b.WriteString(s.todayLine())
	b.WriteString("\n\n")
	b.WriteString(schemaText)
	b.WriteString("\nPeople (id: name): ")
	for i, p := range ps {
		if i > 0 {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "%d: %s", p.ID, p.Name)
		if p.Archived() {
			b.WriteString(" (archived)")
		}
	}
	b.WriteString("\nCategories (id: name): ")
	for i, c := range cs {
		if i > 0 {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "%d: %s", c.ID, c.Name)
		if c.Archived() {
			b.WriteString(" (archived)")
		}
	}
	b.WriteString("\n\nCREATE statements:\n")
	for _, o := range objs {
		b.WriteString(o.SQL)
		b.WriteString(";\n")
	}
	return toolResult{text: b.String()}, nil
}

// --- sql_query --------------------------------------------------------------------

func (s *server) sqlQuery(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct {
		Query string `json:"query"`
	}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	if strings.TrimSpace(args.Query) == "" {
		return toolResult{}, invalid("Parameter query is missing.")
	}
	select {
	case s.sqlSem <- struct{}{}:
		defer func() { <-s.sqlSem }()
	case <-ctx.Done():
		return toolResult{}, invalid("Too many concurrent queries, please try again.")
	}
	res, err := s.d.Store.ReadOnlyQuery(ctx, args.Query)
	if err != nil {
		var ve domain.ValidationError
		if errors.As(err, &ve) {
			return toolResult{}, err
		}
		return toolResult{}, fmt.Errorf("sql_query: %w", err)
	}
	data := map[string]any{
		"columns":   res.Columns,
		"rows":      res.Rows,
		"row_count": len(res.Rows),
		"truncated": res.Truncated,
	}
	if res.Truncated {
		data["note"] = fmt.Sprintf("There are more than %d rows; only the first %d are included. Please aggregate or narrow down with WHERE/LIMIT.", store.SQLMaxRows, store.SQLMaxRows)
	}
	return toolResult{data: data}, nil
}
