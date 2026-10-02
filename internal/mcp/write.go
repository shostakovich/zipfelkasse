package mcp

// The write tools: create_expense and create_reimbursement. They only add
// entries – nothing is changed or deleted. The person who paid counts as the
// author in the activity log (MCP has no logged-in user).

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
)

// reimbursementTitle is the title of reimbursements, as in the expense form.
const reimbursementTitle = "Rückzahlung"

// registerWriteTools adds the write tools. They are neither read-only nor
// idempotent, so clients ask before running them.
func (s *server) registerWriteTools(dateProp func(string) map[string]any) {
	annotations := map[string]any{"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false}
	add := func(name, title, desc string, schema map[string]any, run func(context.Context, json.RawMessage) (toolResult, error)) {
		s.order = append(s.order, name)
		s.tools[name] = tool{
			def: map[string]any{"name": name, "title": title, "description": desc, "inputSchema": schema, "annotations": annotations},
			run: run,
		}
	}
	amountProp := map[string]any{"type": []string{"string", "number"},
		"description": `Amount in currency (default EUR) with a dot as decimal separator, e.g. "23.40".`}
	currencyProp := map[string]any{"type": "string", "description": "ISO currency code, e.g. USD. Default EUR."}
	rateProp := map[string]any{"type": "number", "exclusiveMinimum": 0,
		"description": "Only for a foreign currency: units of that currency per 1 EUR. Default: the ECB reference rate of the date."}
	dupProp := func(same string) map[string]any {
		return map[string]any{"type": "boolean",
			"description": "Create it even if an entry with the same date, payer, amount and " + same + " exists. Only set after asking the user."}
	}

	add("create_expense", "Create expense",
		"Creates an expense, as if the payer had entered it in the app. Ask the user before calling it if anything is unclear "+
			"(amount, payer, who takes part); then tell them what was created. Without participants and weights, the amount is "+
			"split equally among all active people. An entry with the same date, payer, amount and title is refused unless allow_duplicate is set. "+
			"Settlement payments between people are not expenses: use create_reimbursement for them.",
		map[string]any{
			"type": "object",
			"properties": map[string]any{
				"title":    map[string]any{"type": "string", "description": "What was bought, e.g. \"Rewe\" or \"Pizza\" (usually German, like the existing titles)."},
				"amount":   amountProp,
				"currency": currencyProp,
				"fx_rate":  rateProp,
				"date":     dateProp("Date of the expense. Default today."),
				"paid_by":  map[string]any{"type": "string", "description": "Name of the person who paid."},
				"category": map[string]any{"type": "string", "description": "Category name (case-insensitive). Empty = no category."},
				"split": map[string]any{"type": "string", "enum": domain.SplitModes,
					"description": "equal (default): evenly among participants. shares, percent, amount: by the values in weights."},
				"participants": map[string]any{"type": "array", "items": map[string]any{"type": "string"},
					"description": "Only for split=equal: names of the people the expense is for. Default: all active people."},
				"weights": map[string]any{"type": "object", "additionalProperties": map[string]any{"type": []string{"string", "number"}},
					"description": `For shares, percent and amount: person name → value, e.g. {"Anna": 2, "Ben": 1} (shares), {"Anna": 70, "Ben": 30} (percent, sum 100) ` +
						`or {"Anna": "15.00", "Ben": "8.40"} (amounts in currency, sum = amount). These people are the participants.`},
				"notes":           map[string]any{"type": "string", "description": "Optional note."},
				"allow_duplicate": dupProp("title"),
			},
			"required":             []string{"title", "amount", "paid_by"},
			"additionalProperties": false,
		},
		s.createExpense)

	add("create_reimbursement", "Create reimbursement",
		"Records a settlement payment: from paid amount to to (e.g. a bank transfer to settle up). It changes the balances, but is not an expense. "+
			"An entry with the same date, payer, amount and recipient is refused unless allow_duplicate is set.",
		map[string]any{
			"type": "object",
			"properties": map[string]any{
				"from":            map[string]any{"type": "string", "description": "Name of the person who paid the money."},
				"to":              map[string]any{"type": "string", "description": "Name of the person who received it."},
				"amount":          amountProp,
				"currency":        currencyProp,
				"fx_rate":         rateProp,
				"date":            dateProp("Date of the payment. Default today."),
				"notes":           map[string]any{"type": "string", "description": "Optional note."},
				"allow_duplicate": dupProp("recipient"),
			},
			"required":             []string{"from", "to", "amount"},
			"additionalProperties": false,
		},
		s.createReimbursement)
}

// amountText is an amount argument given as a string or a JSON number; it is
// parsed later, once the currency (and its decimals) is known.
type amountText string

func (a *amountText) UnmarshalJSON(b []byte) error {
	var str string
	if err := json.Unmarshal(b, &str); err == nil {
		*a = amountText(str)
		return nil
	}
	var n json.Number
	if err := json.Unmarshal(b, &n); err != nil {
		return fmt.Errorf("must be a string or a number")
	}
	*a = amountText(n.String())
	return nil
}

// parseDecimal parses a non-negative number with a dot as decimal separator
// and at most decimals decimal places (superfluous zeros are fine) into the
// smallest unit: ("23.4", 2) → 2340. Unlike domain.ParseMinor it accepts no
// thousands separators, so "1.234" is never 1234.
func parseDecimal(s string, decimals int) (int64, error) {
	s = strings.TrimSpace(s)
	whole, frac, _ := strings.Cut(s, ".")
	frac = strings.TrimRight(frac, "0")
	digits := func(v string) bool { return strings.Trim(v, "0123456789") == "" }
	switch {
	case whole == "" || !digits(whole) || !digits(frac):
		return 0, fmt.Errorf("use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50")
	case len(frac) > decimals:
		return 0, fmt.Errorf("at most %d decimal places", decimals)
	case len(whole) > 15:
		return 0, fmt.Errorf("too large")
	}
	return strconv.ParseInt(whole+frac+strings.Repeat("0", decimals-len(frac)), 10, 64)
}

// moneyArgs are the amount arguments shared by both tools.
type moneyArgs struct {
	Amount   amountText `json:"amount"`
	Currency string     `json:"currency"`
	FXRate   *float64   `json:"fx_rate"`
}

// setMoney fills amount, currency and rate of in (in.Date must be set). A
// foreign currency without fx_rate gets the ECB rate of the date.
func (s *server) setMoney(ctx context.Context, in *store.ExpenseInput, a moneyArgs) error {
	cur := strings.ToUpper(cmpOr(a.Currency, "EUR"))
	if len(cur) != 3 || strings.Trim(cur, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") != "" {
		return invalid("currency must be a three-letter ISO code such as USD, not %q.", a.Currency)
	}
	if strings.TrimSpace(string(a.Amount)) == "" {
		return invalid("Parameter amount is missing.")
	}
	minor, err := parseDecimal(string(a.Amount), domain.CurrencyDecimals(cur))
	if err != nil {
		return invalid("Invalid amount %q for %s: %v", a.Amount, cur, err)
	}
	if minor <= 0 {
		return invalid("amount must be greater than 0.")
	}
	if cur == "EUR" {
		if a.FXRate != nil {
			return invalid("fx_rate is only for foreign currencies.")
		}
		in.AmountCents = minor
		return nil
	}
	in.OriginalAmountMinor, in.OriginalCurrency = minor, cur
	if a.FXRate != nil {
		if *a.FXRate <= 0 {
			return invalid("fx_rate must be greater than 0.")
		}
		in.FXRate, in.FXSource = *a.FXRate, domain.FXSourceManual
		return nil
	}
	noRate := invalid("There is no exchange rate for %s on %s. Ask the user for the rate and pass it as fx_rate.", cur, in.Date.Format(domain.DateLayout))
	if s.d.FX == nil {
		return noRate
	}
	rate, err := s.d.FX.Rate(ctx, cur, in.Date)
	if err != nil || rate.Rate <= 0 {
		if err != nil {
			s.log.Info("mcp: rate not available", "currency", cur, "date", in.Date.Format(domain.DateLayout), "err", err)
		}
		return noRate
	}
	in.FXRate, in.FXSource = rate.Rate, cmpOr(rate.Source, domain.FXSourceECB)
	return nil
}

// dateOrToday parses a date argument; empty = today in the server time zone.
func (s *server) dateOrToday(v string) (time.Time, error) {
	d, err := parseDateArg("date", v)
	if err != nil || !d.IsZero() {
		return d, err
	}
	return domain.DateOf(s.now().In(s.location())), nil
}

// activePerson resolves a name to a person who is not archived.
func activePerson(ps []store.Participant, arg, name string) (store.Participant, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return store.Participant{}, invalid("Parameter %s is missing.", arg)
	}
	var names []string
	for _, p := range ps {
		if p.Archived() {
			if strings.EqualFold(p.Name, name) {
				return store.Participant{}, invalid("%s is archived and cannot take part in new entries.", p.Name)
			}
			continue
		}
		if strings.EqualFold(p.Name, name) {
			return p, nil
		}
		names = append(names, p.Name)
	}
	return store.Participant{}, invalid("Unknown person %q in %s. Available: %s.", name, arg, strings.Join(names, ", "))
}

func (s *server) createExpense(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct {
		moneyArgs
		Title          string                `json:"title"`
		Date           string                `json:"date"`
		PaidBy         string                `json:"paid_by"`
		Category       string                `json:"category"`
		Split          string                `json:"split"`
		Participants   []string              `json:"participants"`
		Weights        map[string]amountText `json:"weights"`
		Notes          string                `json:"notes"`
		AllowDuplicate bool                  `json:"allow_duplicate"`
	}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	in := store.ExpenseInput{Title: strings.TrimSpace(args.Title), Notes: args.Notes, SplitMode: domain.SplitMode(cmpOr(args.Split, string(domain.SplitEqual)))}
	if in.Title == "" {
		return toolResult{}, invalid("Parameter title is missing.")
	}
	if !in.SplitMode.Valid() {
		return toolResult{}, invalid("split must be one of equal, shares, percent, amount.")
	}
	var err error
	if in.Date, err = s.dateOrToday(args.Date); err != nil {
		return toolResult{}, err
	}
	if err := s.setMoney(ctx, &in, args.moneyArgs); err != nil {
		return toolResult{}, err
	}
	_, ps, err := s.participantNames(ctx)
	if err != nil {
		return toolResult{}, err
	}
	payer, err := activePerson(ps, "paid_by", args.PaidBy)
	if err != nil {
		return toolResult{}, err
	}
	in.PaidBy = payer.ID
	if strings.TrimSpace(args.Category) != "" {
		c, err := s.findCategory(ctx, args.Category)
		if err != nil {
			return toolResult{}, err
		}
		if c.Archived() {
			return toolResult{}, invalid("Category %s is archived.", c.Name)
		}
		in.CategoryID = c.ID
	}
	if in.Parts, err = splitArgs(ps, in.SplitMode, cmpOr(in.OriginalCurrency, "EUR"), args.Participants, args.Weights); err != nil {
		return toolResult{}, err
	}
	return s.create(ctx, in, payer, args.AllowDuplicate)
}

// splitArgs turns participants (equal) or weights (other modes) into parts.
// Without either, equal goes to all active people.
func splitArgs(ps []store.Participant, mode domain.SplitMode, cur string, participants []string, weights map[string]amountText) ([]domain.Part, error) {
	var parts []domain.Part
	seen := map[int64]bool{}
	addPart := func(name string, w int64) error {
		p, err := activePerson(ps, "the split", name)
		if err != nil {
			return err
		}
		if seen[p.ID] {
			return invalid("%s appears twice in the split.", p.Name)
		}
		seen[p.ID] = true
		parts = append(parts, domain.Part{ParticipantID: p.ID, Weight: w})
		return nil
	}
	if mode == domain.SplitEqual {
		if len(weights) > 0 {
			return nil, invalid("weights are only for split=shares, percent or amount; use participants for an equal split.")
		}
		if len(participants) == 0 {
			for _, p := range ps {
				if !p.Archived() {
					parts = append(parts, domain.Part{ParticipantID: p.ID})
				}
			}
			return parts, nil
		}
		for _, name := range participants {
			if err := addPart(name, 0); err != nil {
				return nil, err
			}
		}
		return parts, nil
	}
	if len(participants) > 0 {
		return nil, invalid("With split=%s, weights name the participants; leave participants out.", mode)
	}
	if len(weights) == 0 {
		return nil, invalid("split=%s needs weights (person name → value).", mode)
	}
	for _, name := range slices.Sorted(maps.Keys(weights)) {
		var w int64
		var err error
		switch mode {
		case domain.SplitPercent:
			w, err = parseDecimal(string(weights[name]), 2) // basis points
		case domain.SplitAmount:
			w, err = parseDecimal(string(weights[name]), domain.CurrencyDecimals(cur))
		default:
			w, err = domain.ParseWeight(mode, cur, string(weights[name]))
		}
		if err != nil {
			return nil, invalid("Invalid value %q for %s in weights.", weights[name], name)
		}
		if w < 0 {
			return nil, invalid("Negative value for %s in weights.", name)
		}
		if err := addPart(name, w); err != nil {
			return nil, err
		}
	}
	return parts, nil
}

func (s *server) createReimbursement(ctx context.Context, raw json.RawMessage) (toolResult, error) {
	var args struct {
		moneyArgs
		From           string `json:"from"`
		To             string `json:"to"`
		Date           string `json:"date"`
		Notes          string `json:"notes"`
		AllowDuplicate bool   `json:"allow_duplicate"`
	}
	if err := decodeArgs(raw, &args); err != nil {
		return toolResult{}, err
	}
	in := store.ExpenseInput{Title: reimbursementTitle, Notes: args.Notes, IsReimbursement: true}
	var err error
	if in.Date, err = s.dateOrToday(args.Date); err != nil {
		return toolResult{}, err
	}
	if err := s.setMoney(ctx, &in, args.moneyArgs); err != nil {
		return toolResult{}, err
	}
	_, ps, err := s.participantNames(ctx)
	if err != nil {
		return toolResult{}, err
	}
	from, err := activePerson(ps, "from", args.From)
	if err != nil {
		return toolResult{}, err
	}
	to, err := activePerson(ps, "to", args.To)
	if err != nil {
		return toolResult{}, err
	}
	if from.ID == to.ID {
		return toolResult{}, invalid("from and to must be different people.")
	}
	in.PaidBy, in.Parts = from.ID, []domain.Part{{ParticipantID: to.ID}}
	return s.create(ctx, in, from, args.AllowDuplicate)
}

// create stores in with the payer as author, unless an identical entry
// exists (same date, payer, amount in euros, kind and title or recipient), and
// returns the stored entry.
func (s *server) create(ctx context.Context, in store.ExpenseInput, payer store.Participant, allowDuplicate bool) (toolResult, error) {
	cents := in.AmountCents
	if in.OriginalCurrency != "" {
		cents = domain.ToEURCents(in.OriginalAmountMinor, in.OriginalCurrency, in.FXRate)
	}
	if !allowDuplicate && cents > 0 {
		same, err := s.d.Store.ListExpenses(ctx, store.ExpenseFilter{From: in.Date, To: in.Date, PaidBy: in.PaidBy, MinCents: cents, MaxCents: cents})
		if err != nil {
			return toolResult{}, err
		}
		for _, e := range same {
			if e.IsReimbursement != in.IsReimbursement {
				continue
			}
			if (in.IsReimbursement && e.ShareOf(in.Parts[0].ParticipantID) != 0) || (!in.IsReimbursement && store.Fold(e.Title) == store.Fold(in.Title)) {
				return toolResult{}, invalid("This looks like a duplicate of entry %d (%s, %s, %s EUR, paid by %s). "+
					"Ask the user; if it really is a second one, call again with allow_duplicate=true.",
					e.ID, e.Date.Format(domain.DateLayout), e.Title, eur(e.AmountCents), e.PaidByName)
			}
		}
	}
	id, err := s.d.Store.CreateExpense(ctx, payer.ID, in)
	if err != nil {
		return toolResult{}, err
	}
	s.log.Info("mcp: entry created", "id", id, "reimbursement", in.IsReimbursement)
	e, err := s.d.Store.GetExpense(ctx, id)
	if err != nil {
		return toolResult{}, err
	}
	names, _, err := s.participantNames(ctx)
	if err != nil {
		return toolResult{}, err
	}
	return toolResult{data: map[string]any{
		"created": expenseToOut(e, names, true),
		"note":    fmt.Sprintf("Created as entry %d with %s as author. Changing or deleting it is only possible in the app.", id, payer.Name),
	}}, nil
}
