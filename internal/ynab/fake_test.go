package ynab

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
)

const (
	testToken   = "geheimer-token-123"
	testPlan    = "plan-1"
	testAccount = "acc-geteilt"
)

// fakeYNAB ist eine minimale YNAB-API im Speicher, als http.RoundTripper
// (in der Sandbox lassen sich keine Ports öffnen).
type fakeYNAB struct {
	mu       sync.Mutex
	txns     map[string]*apiTxn // nach ID, inkl. gelöschter
	nextID   int
	requests []string // "METHOD /pfad"

	// Fehlerinjektion: Status für die nächsten Anfragen (0 = normal).
	failNext []int
	// lostPost: der nächste POST wird ausgeführt, die Antwort geht aber verloren (500).
	lostPost bool
	// hold: ist er gesetzt, wartet jede Anfrage, bis der Kanal geschlossen ist.
	hold chan struct{}
	mux  *http.ServeMux
}

func newFake() *fakeYNAB {
	f := &fakeYNAB{txns: map[string]*apiTxn{}}
	m := http.NewServeMux()
	m.HandleFunc("GET /v1/plans", f.plans)
	m.HandleFunc("GET /v1/plans/{plan}/categories", f.categories)
	m.HandleFunc("POST /v1/plans/{plan}/transactions", f.create)
	m.HandleFunc("PATCH /v1/plans/{plan}/transactions", f.update)
	m.HandleFunc("DELETE /v1/plans/{plan}/transactions/{id}", f.delete)
	m.HandleFunc("GET /v1/plans/{plan}/accounts/{acc}/transactions", f.list)
	f.mux = m
	return f
}

func (f *fakeYNAB) RoundTrip(req *http.Request) (*http.Response, error) {
	f.mu.Lock()
	f.requests = append(f.requests, req.Method+" "+req.URL.Path)
	var fail int
	if len(f.failNext) > 0 {
		fail, f.failNext = f.failNext[0], f.failNext[1:]
	}
	hold := f.hold
	f.mu.Unlock()
	if hold != nil {
		<-hold
	}
	rec := httptest.NewRecorder()
	switch {
	case req.Header.Get("Authorization") != "Bearer "+testToken:
		writeErr(rec, 401, "401", "unauthorized", "Unauthorized")
	case fail == 429:
		rec.Header().Set("Retry-After", "60")
		writeErr(rec, 429, "429", "too_many_requests", "Too many requests")
	case fail != 0:
		writeErr(rec, fail, fmt.Sprint(fail), "error", "Fehler "+fmt.Sprint(fail)+" mit "+testToken)
	case req.URL.Host != "api.test":
		writeErr(rec, 404, "404", "not_found", "falscher Host")
	default:
		f.mux.ServeHTTP(rec, req)
	}
	return rec.Result(), nil
}

func writeErr(w http.ResponseWriter, status int, id, name, detail string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"id": id, "name": name, "detail": detail}})
}

func writeData(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{"data": data})
}

func (f *fakeYNAB) plans(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("include_accounts") != "true" {
		writeErr(w, 400, "400", "bad_request", "include_accounts fehlt")
		return
	}
	writeData(w, 200, map[string]any{"plans": []map[string]any{{
		"id": testPlan, "name": "Haushalt",
		"currency_format": map[string]any{"iso_code": "EUR"},
		"accounts": []map[string]any{
			{"id": testAccount, "name": "Geteilt", "type": "cash", "on_budget": true, "closed": false, "deleted": false},
			{"id": "acc-giro", "name": "Girokonto", "type": "checking", "on_budget": true, "closed": false, "deleted": false},
			{"id": "acc-depot", "name": "Depot", "type": "otherAsset", "on_budget": false, "closed": false, "deleted": false},
			{"id": "acc-alt", "name": "Altes Konto", "type": "checking", "on_budget": true, "closed": true, "deleted": false},
		},
	}}})
}

func (f *fakeYNAB) categories(w http.ResponseWriter, r *http.Request) {
	if r.PathValue("plan") != testPlan {
		writeErr(w, 404, "404", "not_found", "plan")
		return
	}
	writeData(w, 200, map[string]any{"server_knowledge": 1, "category_groups": []map[string]any{
		{"id": "g-int", "name": "Internal Master Category", "hidden": false, "internal": true, "deleted": false,
			"categories": []map[string]any{{"id": "c-rta", "name": "Inflow: Ready to Assign", "hidden": false, "deleted": false}}},
		{"id": "g-cc", "name": "Credit Card Payments", "hidden": false, "internal": false, "deleted": false,
			"categories": []map[string]any{{"id": "c-visa", "name": "Visa", "hidden": false, "deleted": false}}},
		{"id": "g-1", "name": "Alltag", "hidden": false, "internal": false, "deleted": false,
			"categories": []map[string]any{
				{"id": "c-food", "name": "Lebensmittel & Drogerie", "hidden": false, "deleted": false},
				{"id": "c-out", "name": "Essen gehen", "hidden": false, "deleted": false},
				{"id": "c-old", "name": "Versteckt", "hidden": true, "deleted": false},
			}},
	}})
}

type txnBody struct {
	Transactions []map[string]any `json:"transactions"`
}

func (f *fakeYNAB) create(w http.ResponseWriter, r *http.Request) {
	var body txnBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || len(body.Transactions) == 0 {
		writeErr(w, 400, "400", "bad_request", "kaputt")
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, t := range body.Transactions {
		if _, ok := t["import_id"]; ok {
			writeErr(w, 400, "400", "bad_request", "import_id nicht erwartet")
			return
		}
		if payee, _ := t["payee_name"].(string); strings.Contains(payee, "ABLEHNEN") {
			writeErr(w, 400, "400", "bad_request", "payee abgelehnt")
			return
		}
	}
	var out []apiTxn
	var ids []string
	for _, t := range body.Transactions {
		f.nextID++
		id := fmt.Sprintf("t%d", f.nextID)
		txn := &apiTxn{ID: id}
		applyFields(txn, t)
		f.txns[id] = txn
		out = append(out, *txn)
		ids = append(ids, id)
	}
	if f.lostPost {
		f.lostPost = false
		writeErr(w, 500, "500", "internal", "verloren")
		return
	}
	writeData(w, 201, map[string]any{"transaction_ids": ids, "transactions": out, "server_knowledge": 2})
}

func applyFields(txn *apiTxn, t map[string]any) {
	if v, ok := t["account_id"].(string); ok {
		txn.AccountID = v
	}
	if v, ok := t["date"].(string); ok {
		txn.Date = v
	}
	if v, ok := t["amount"].(float64); ok {
		txn.Amount = int64(v)
	}
	if v, ok := t["memo"].(string); ok {
		txn.Memo = &v
	}
	if v, ok := t["payee_name"].(string); ok {
		txn.PayeeName = &v
	}
	if v, ok := t["category_id"]; ok {
		if s, ok := v.(string); ok {
			txn.CategoryID = &s
		} else {
			txn.CategoryID = nil
		}
	}
	if v, ok := t["cleared"].(string); ok {
		txn.Cleared = v
	}
	if v, ok := t["approved"].(bool); ok {
		txn.Approved = v
	}
}

func (f *fakeYNAB) update(w http.ResponseWriter, r *http.Request) {
	var body txnBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, 400, "400", "bad_request", "kaputt")
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, t := range body.Transactions {
		id, _ := t["id"].(string)
		if _, ok := f.txns[id]; !ok {
			writeErr(w, 404, "404", "not_found", "transaction not found")
			return
		}
	}
	var out []apiTxn
	for _, t := range body.Transactions {
		txn := f.txns[t["id"].(string)]
		if !txn.Deleted {
			applyFields(txn, t)
		}
		out = append(out, *txn)
	}
	writeData(w, 200, map[string]any{"transaction_ids": []string{}, "transactions": out, "server_knowledge": 3})
}

func (f *fakeYNAB) delete(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	txn, ok := f.txns[r.PathValue("id")]
	if !ok || txn.Deleted {
		writeErr(w, 404, "404", "not_found", "transaction not found")
		return
	}
	txn.Deleted = true
	writeData(w, 200, map[string]any{"transaction": txn, "server_knowledge": 4})
}

func (f *fakeYNAB) list(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	since := r.URL.Query().Get("since_date")
	var out []apiTxn
	for _, t := range f.txns {
		if !t.Deleted && t.AccountID == r.PathValue("acc") && t.Date >= since {
			out = append(out, *t)
		}
	}
	writeData(w, 200, map[string]any{"transactions": out, "server_knowledge": 5})
}

// live liefert die nicht gelöschten Buchungen, nach ID sortiert.
func (f *fakeYNAB) live() []apiTxn {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []apiTxn
	for _, t := range f.txns {
		if !t.Deleted {
			out = append(out, *t)
		}
	}
	slices.SortFunc(out, func(a, b apiTxn) int { return strings.Compare(a.ID, b.ID) })
	return out
}

func (f *fakeYNAB) takeRequests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	r := f.requests
	f.requests = nil
	return r
}

func (f *fakeYNAB) fail(statuses ...int) {
	f.mu.Lock()
	f.failNext = append(f.failNext, statuses...)
	f.mu.Unlock()
}
