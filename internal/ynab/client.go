package ynab

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
)

// DefaultBaseURL is the YNAB API (v1). Since v1.79 budgets are called
// "plans" there; we use the /plans paths.
const DefaultBaseURL = "https://api.ynab.com/v1"

// Field lengths according to the OpenAPI spec (SaveTransactionWithOptionalFields).
const (
	maxPayeeLen = 200
	maxMemoLen  = 500
)

// client talks to the YNAB API on behalf of a token.
type client struct {
	http    *http.Client
	baseURL string
	token   string

	targetOK bool // plan and account confirmed in this sync run (see Service.confirmTarget)
}

// APIError is an error response of the YNAB API. Its message (German) is
// shown on the YNAB settings page.
type APIError struct {
	Status     int
	ID, Name   string // from {"error": {"id", "name", "detail"}}
	Detail     string
	RetryAfter time.Duration // on 429, if given
}

func (e *APIError) Error() string {
	switch e.Status {
	case http.StatusUnauthorized:
		return "YNAB: Token ungültig oder abgelaufen"
	case http.StatusTooManyRequests:
		return "YNAB: Anfragelimit erreicht (200 pro Stunde)"
	}
	msg := fmt.Sprintf("YNAB-Fehler %d", e.Status)
	if e.Detail != "" {
		msg += ": " + e.Detail
	} else if e.Name != "" {
		msg += ": " + e.Name
	}
	return msg
}

func statusOf(err error) int {
	var ae *APIError
	if errors.As(err, &ae) {
		return ae.Status
	}
	return 0
}

// unclearError: transport error, timeout or unreadable response – whether
// YNAB processed the request is unknown.
type unclearError struct{ err error }

func (e unclearError) Error() string { return e.err.Error() }
func (e unclearError) Unwrap() error { return e.err }

// uncertain reports errors for which it is unclear whether YNAB processed
// the request (network error, timeout, 5xx).
func uncertain(err error) bool {
	var ue unclearError
	return errors.As(err, &ue) || statusOf(err) >= 500
}

// --- Response types (only the fields in use) ---------------------------------

type apiPlan struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	CurrencyFormat *struct {
		ISOCode string `json:"iso_code"`
	} `json:"currency_format"`
	Accounts []apiAccount `json:"accounts"`
}

func (p apiPlan) currency() string {
	if p.CurrencyFormat == nil {
		return ""
	}
	return p.CurrencyFormat.ISOCode
}

type apiAccount struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Type     string `json:"type"`
	OnBudget bool   `json:"on_budget"`
	Closed   bool   `json:"closed"`
	Deleted  bool   `json:"deleted"`
}

type apiCategoryGroup struct {
	ID         string        `json:"id"`
	Name       string        `json:"name"`
	Hidden     bool          `json:"hidden"`
	Internal   bool          `json:"internal"`
	Deleted    bool          `json:"deleted"`
	Categories []apiCategory `json:"categories"`
}

type apiCategory struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Hidden   bool   `json:"hidden"`
	Internal bool   `json:"internal"`
	Deleted  bool   `json:"deleted"`
}

type apiTxn struct {
	ID         string  `json:"id"`
	Date       string  `json:"date"`
	Amount     int64   `json:"amount"`
	Memo       *string `json:"memo"`
	PayeeName  *string `json:"payee_name"`
	CategoryID *string `json:"category_id"`
	AccountID  string  `json:"account_id"`
	Cleared    string  `json:"cleared"`
	Approved   bool    `json:"approved"`
	Deleted    bool    `json:"deleted"`
}

func (t apiTxn) memo() string {
	if t.Memo == nil {
		return ""
	}
	return *t.Memo
}

// saveTxn is a transaction to create (without ID) or to update (with ID).
type saveTxn struct {
	ID         string  `json:"id,omitempty"`
	AccountID  string  `json:"account_id,omitempty"`
	Date       string  `json:"date"`
	Amount     int64   `json:"amount"`
	PayeeName  string  `json:"payee_name"`
	Memo       string  `json:"memo"`
	CategoryID *string `json:"category_id,omitempty"` // nil = do not set (new: uncategorized)
	Cleared    string  `json:"cleared,omitempty"`
	Approved   *bool   `json:"approved,omitempty"`
}

// --- Calls -------------------------------------------------------------------

func (c *client) do(ctx context.Context, method, path string, body, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	// The error messages end up on the YNAB settings page, hence German.
	res, err := c.http.Do(req)
	if err != nil {
		return unclearError{fmt.Errorf("YNAB nicht erreichbar: %w", err)}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if err != nil {
		return unclearError{fmt.Errorf("YNAB-Antwort unvollständig: %w", err)}
	}
	if res.StatusCode < 200 || res.StatusCode > 299 {
		ae := &APIError{Status: res.StatusCode}
		var er struct {
			Error struct {
				ID     string `json:"id"`
				Name   string `json:"name"`
				Detail string `json:"detail"`
			} `json:"error"`
		}
		if json.Unmarshal(data, &er) == nil {
			ae.ID, ae.Name, ae.Detail = er.Error.ID, er.Error.Name, er.Error.Detail
		}
		if s, err := strconv.Atoi(strings.TrimSpace(res.Header.Get("Retry-After"))); err == nil && s > 0 {
			ae.RetryAfter = time.Duration(s) * time.Second
		}
		return ae
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return unclearError{fmt.Errorf("YNAB-Antwort unlesbar: %w", err)}
	}
	return nil
}

func planPath(planID string) string { return "/plans/" + url.PathEscape(planID) }

// plans returns all plans including accounts (a single call).
func (c *client) plans(ctx context.Context) ([]apiPlan, error) {
	var out struct {
		Data struct {
			Plans []apiPlan `json:"plans"`
		} `json:"data"`
	}
	err := c.do(ctx, http.MethodGet, "/plans?include_accounts=true", nil, &out)
	return out.Data.Plans, err
}

// categories returns the category groups of a plan.
func (c *client) categories(ctx context.Context, planID string) ([]apiCategoryGroup, error) {
	var out struct {
		Data struct {
			CategoryGroups []apiCategoryGroup `json:"category_groups"`
		} `json:"data"`
	}
	err := c.do(ctx, http.MethodGet, planPath(planID)+"/categories", nil, &out)
	return out.Data.CategoryGroups, err
}

// account returns an account of a plan.
func (c *client) account(ctx context.Context, planID, accountID string) (apiAccount, error) {
	var out struct {
		Data struct {
			Account apiAccount `json:"account"`
		} `json:"data"`
	}
	err := c.do(ctx, http.MethodGet, planPath(planID)+"/accounts/"+url.PathEscape(accountID), nil, &out)
	return out.Data.Account, err
}

type saveResult struct {
	Data struct {
		TransactionIDs []string `json:"transaction_ids"`
		Transactions   []apiTxn `json:"transactions"`
	} `json:"data"`
}

// createTransactions creates several transactions with one call.
func (c *client) createTransactions(ctx context.Context, planID string, txns []saveTxn) ([]apiTxn, error) {
	var out saveResult
	err := c.do(ctx, http.MethodPost, planPath(planID)+"/transactions", map[string]any{"transactions": txns}, &out)
	return out.Data.Transactions, err
}

// updateTransactions updates several transactions (by id) with one call.
func (c *client) updateTransactions(ctx context.Context, planID string, txns []saveTxn) ([]apiTxn, error) {
	var out saveResult
	err := c.do(ctx, http.MethodPatch, planPath(planID)+"/transactions", map[string]any{"transactions": txns}, &out)
	return out.Data.Transactions, err
}

// deleteTransaction deletes a transaction.
func (c *client) deleteTransaction(ctx context.Context, planID, txnID string) error {
	return c.do(ctx, http.MethodDelete, planPath(planID)+"/transactions/"+url.PathEscape(txnID), nil, nil)
}

// accountTransactions returns the (non-deleted) transactions of an account from since on.
func (c *client) accountTransactions(ctx context.Context, planID, accountID string, since time.Time) ([]apiTxn, error) {
	var out struct {
		Data struct {
			Transactions []apiTxn `json:"transactions"`
		} `json:"data"`
	}
	path := planPath(planID) + "/accounts/" + url.PathEscape(accountID) + "/transactions?since_date=" + since.Format(domain.DateLayout)
	err := c.do(ctx, http.MethodGet, path, nil, &out)
	return out.Data.Transactions, err
}
