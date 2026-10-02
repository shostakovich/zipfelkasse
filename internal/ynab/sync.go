package ynab

import (
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/shostakovich/zipfelkasse/internal/domain"
	"github.com/shostakovich/zipfelkasse/internal/store"
)

// Sync: for each person with a YNAB connection, the desired state (one
// transaction per own expense, see PostingFor) is compared with ynab_sync.
// Only the differences go to YNAB – batched to spare the limit of 200
// requests per hour: new → one POST for all, changed → one PATCH for all,
// gone → DELETE one by one (the API has no bulk DELETE).
// Without differences a run costs not a single request.
//
// Meaning of ynab_sync.synced_hash:
//   - fingerprint of the last transferred desired state (hashOf)
//   - "error:" + fingerprint: transferring this state failed; it is retried
//     only on change, in the hourly full sync or via "Jetzt
//     synchronisieren"
//   - "pending": creation is in progress or its outcome is unknown (timeout,
//     5xx). The next run looks for the transaction in the account via the memo
//     marker "zipfelkasse #ID" instead of blindly creating it again (which
//     could create duplicates).
//   - "retarget" (store.YNABHashRetarget, without transaction ID): plan or
//     account changed. Like "pending", the next run looks for the
//     transaction in the new account via the memo marker (it is there already
//     after switching back) – but only for expenses that belong there; the
//     rows of the others are simply dropped.
//   - "": unknown, or create/update
//
// Transactions deliberately get no import_id: YNAB tries to merge imported
// transactions with manually entered transactions of the same amount (±10
// days) in the same account. In the "Geteilt" account those are the
// transfers for reimbursements – with equal amounts (very common: half paid
// back) YNAB would merge the share with the transfer and the balance would no
// longer be right. The "pending" mechanism prevents duplicates instead.
const (
	pendingHash      = "pending"
	retargetHash     = store.YNABHashRetarget
	errorHashPrefix  = "error:"
	hashVersion      = "v1"
	chunkSize        = 100 // transactions per POST/PATCH
	maxDeletesPerRun = 40  // each DELETE costs one request
	maxSinglePerRun  = 20  // single attempts after a rejected batch call
	systemicFailures = 3   // this many single failures in a row without success: defer the rest
	retryDelay       = 5 * time.Minute
	maxBackoff       = time.Hour
)

// errTokenInvalid and the other messages stored in Status.Error or
// ynab_sync.last_error are shown on the YNAB settings page, hence German.
var errTokenInvalid = errors.New("Der YNAB-Token ist ungültig oder abgelaufen. Bitte einen neuen Token eintragen.")

// backoffError: YNAB is not asked until until (rate limit or outage). Only
// logged, never shown on a page.
type backoffError struct{ until time.Time }

func (e backoffError) Error() string {
	return "YNAB paused until " + e.until.Format("15:04") + " (rate limit or outage)"
}

// Status is the sync state of a person (settings key "ynab.status.<id>").
// Summary and Error are shown on the YNAB settings page (German).
type Status struct {
	LastRun      time.Time     `json:"last_run,omitzero"`  // last attempt
	LastSync     time.Time     `json:"last_sync,omitzero"` // last complete sync
	Summary      string        `json:"summary,omitempty"`  // result of the last sync
	Error        string        `json:"error,omitempty"`    // error of the last attempt (without token)
	TokenInvalid bool          `json:"token_invalid,omitempty"`
	RetryAt      time.Time     `json:"retry_at,omitzero"` // no requests before this
	Backoff      time.Duration `json:"backoff,omitempty"` // last delay after 429
}

func statusKey(participantID int64) string {
	return "ynab.status." + strconv.FormatInt(participantID, 10)
}

func (s *Service) loadStatus(ctx context.Context, participantID int64) Status {
	var st Status
	if v, err := s.d.Store.GetSetting(ctx, statusKey(participantID)); err == nil {
		json.Unmarshal([]byte(v), &st)
	}
	return st
}

func (s *Service) saveStatus(ctx context.Context, participantID int64, st Status) error {
	b, err := json.Marshal(st)
	if err != nil {
		return err
	}
	return s.d.Store.SetSetting(ctx, statusKey(participantID), string(b))
}

// syncResult counts what a run did in YNAB.
type syncResult struct {
	Created, Updated, Deleted, Failed int
	Again                             bool // work remains: run again soon
}

// String is the summary shown on the YNAB settings page (German).
func (r syncResult) String() string {
	s := fmt.Sprintf("%d neu · %d geändert · %d gelöscht", r.Created, r.Updated, r.Deleted)
	if r.Failed > 0 {
		s += fmt.Sprintf(" · %d fehlgeschlagen", r.Failed)
	}
	return s
}

// logValue summarizes the result for the log.
func (r syncResult) logValue() string {
	return fmt.Sprintf("%d created, %d updated, %d deleted, %d failed", r.Created, r.Updated, r.Deleted, r.Failed)
}

// want is the desired state of a transaction in YNAB.
type want struct {
	Posting
	category string // YNAB category ID, "" = uncategorized
	hash     string
	txnID    string // existing transaction (for PATCH)
}

func (w want) milliunits() int64 { return -w.AmountCents * 10 } // 1 cent = 10 milliunits; outflow is negative

func (w want) newTxn(accountID string) saveTxn {
	approved := true
	t := saveTxn{
		AccountID: accountID, Date: w.Date.Format(domain.DateLayout), Amount: w.milliunits(),
		PayeeName: w.Payee, Memo: w.Memo, Cleared: "cleared", Approved: &approved,
	}
	if w.category != "" {
		t.CategoryID = &w.category
	}
	return t
}

// patchTxn changes date, amount, payee, memo and – only if mapped – the
// category. Without a mapping, a category set manually in YNAB is kept; the
// sync no longer touches cleared/approved after creation (e.g. reconciled
// transactions).
func (w want) patchTxn() saveTxn {
	t := saveTxn{ID: w.txnID, Date: w.Date.Format(domain.DateLayout), Amount: w.milliunits(), PayeeName: w.Payee, Memo: w.Memo}
	if w.category != "" {
		t.CategoryID = &w.category
	}
	return t
}

func hashOf(w want) string {
	h := sha256.New()
	fmt.Fprintf(h, "%s\x00%s\x00%d\x00%s\x00%s\x00%s", hashVersion, w.Date.Format(domain.DateLayout),
		w.milliunits(), w.Payee, w.Memo, w.category)
	return hex.EncodeToString(h.Sum(nil)[:16])
}

// today is the last day that YNAB will certainly not reject as future.
func (s *Service) today() time.Time { return Today(s.now(), s.d.Config.Location) }

// Today is the last day that YNAB will certainly not reject as future:
// today in the app time zone loc, but at most today in UTC.
func Today(now time.Time, loc *time.Location) time.Time {
	if loc == nil {
		loc = time.Local
	}
	local, utc := domain.DateOf(now.In(loc)), domain.DateOf(now.UTC())
	if utc.Before(local) {
		return utc
	}
	return local
}

// desired computes the desired state of a person (see Selection), by
// expense ID.
func (s *Service) desired(ctx context.Context, cfg store.YNABConfig) (map[int64]want, error) {
	sel, err := NewSelection(ctx, s.d.Store, cfg, s.today())
	if err != nil {
		return nil, err
	}
	// All of the person's expenses, not just from the start date: earlier ones
	// can belong too (entered later or already in YNAB).
	es, err := s.d.Store.ListExpenses(ctx, store.ExpenseFilter{ParticipantID: cfg.ParticipantID})
	if err != nil {
		return nil, err
	}
	cats, err := s.d.Store.YNABCategoryMap(ctx, cfg.ParticipantID)
	if err != nil {
		return nil, err
	}
	out := map[int64]want{}
	for _, p := range sel.Postings(es, cfg.ParticipantID) {
		w := want{Posting: p}
		if p.CategoryID != 0 {
			w.category = cats[p.CategoryID]
		}
		w.hash = hashOf(w)
		out[p.ExpenseID] = w
	}
	return out, nil
}

// runLevel: errors that abort the person's whole run (including database
// errors and unclear outcomes). Other 4xx concern single transactions.
func runLevel(err error) bool {
	switch statusOf(err) {
	case 0, http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound, http.StatusTooManyRequests:
		return true
	}
	return uncertain(err)
}

// syncOne syncs one person and maintains their status. full also retries
// unchanged transactions that failed before.
func (s *Service) syncOne(ctx context.Context, cfg store.YNABConfig, full bool) (syncResult, Status, error) {
	pid := cfg.ParticipantID
	st := s.loadStatus(ctx, pid)
	now := s.now()
	if st.TokenInvalid {
		return syncResult{}, st, errTokenInvalid
	}
	if now.Before(st.RetryAt) {
		return syncResult{}, st, backoffError{st.RetryAt}
	}
	st.LastRun = now
	res, err := s.syncParticipant(ctx, cfg, full)
	if err != nil {
		var ae *APIError
		errors.As(err, &ae)
		switch code := statusOf(err); {
		case code == http.StatusUnauthorized:
			st.TokenInvalid = true
			st.Error = errTokenInvalid.Error()
		case code == http.StatusTooManyRequests:
			st.Backoff = min(max(2*st.Backoff, retryDelay), maxBackoff)
			st.RetryAt = now.Add(max(st.Backoff, ae.RetryAfter))
			st.Error = "Das YNAB-Anfragelimit ist erreicht. Nächster Versuch um " +
				st.RetryAt.In(s.loc()).Format("15:04") + " Uhr."
		case code == http.StatusNotFound:
			st.Error = "Plan oder Konto gibt es in YNAB nicht (mehr). Bitte Plan und Konto neu wählen."
		case uncertain(err):
			st.RetryAt = now.Add(retryDelay)
			st.Error = redact(err.Error(), cfg.Token)
		default:
			st.Error = redact(err.Error(), cfg.Token)
		}
	} else {
		st.Error, st.Backoff, st.RetryAt = "", 0, time.Time{}
		st.LastSync, st.Summary = now, res.String()
	}
	if serr := s.saveStatus(ctx, pid, st); serr != nil && err == nil {
		err = serr
	}
	return res, st, err
}

// syncParticipant is the actual sync of one person.
func (s *Service) syncParticipant(ctx context.Context, cfg store.YNABConfig, full bool) (syncResult, error) {
	var res syncResult
	pid := cfg.ParticipantID
	wants, err := s.desired(ctx, cfg)
	if err != nil {
		return res, err
	}
	list, err := s.d.Store.ListYNABSync(ctx, pid)
	if err != nil {
		return res, err
	}
	rows := make(map[int64]store.YNABSync, len(list))
	var pending []int64
	for _, r := range list {
		rows[r.ExpenseID] = r
		_, wanted := wants[r.ExpenseID]
		if r.TxnID == "" && (r.Hash == pendingHash || r.Hash == retargetHash && wanted) {
			pending = append(pending, r.ExpenseID)
		}
	}
	c := s.client(cfg.Token)
	if len(pending) > 0 {
		if err := s.resolvePending(ctx, c, cfg, wants, rows, pending); err != nil {
			return res, err
		}
	}

	var creates, updates []want
	var deletes []store.YNABSync
	var forget []int64
	for id, w := range wants {
		r, ok := rows[id]
		failedSame := r.Hash == errorHashPrefix+w.hash
		switch {
		case !full && failedSame:
			// failed and unchanged: retry only in the full sync
		case !ok || r.TxnID == "":
			creates = append(creates, w)
		case r.Hash != w.hash:
			w.txnID = r.TxnID
			updates = append(updates, w)
		}
	}
	for id, r := range rows {
		if _, ok := wants[id]; ok {
			continue
		}
		// Gone (deleted or share 0): always delete, even if the last
		// attempt (e.g. a PATCH) failed.
		if r.TxnID == "" {
			forget = append(forget, id)
		} else {
			deletes = append(deletes, r)
		}
	}
	byID := func(a, b want) int { return cmp.Compare(a.ExpenseID, b.ExpenseID) }
	slices.SortFunc(creates, byID)
	slices.SortFunc(updates, byID)
	slices.SortFunc(deletes, func(a, b store.YNABSync) int { return cmp.Compare(a.ExpenseID, b.ExpenseID) })
	slices.Sort(forget)

	if err := s.d.Store.DeleteYNABSync(ctx, pid, forget...); err != nil {
		return res, err
	}
	if err := s.create(ctx, c, cfg, creates, &res); err != nil {
		return res, err
	}
	if err := s.update(ctx, c, cfg, updates, &res); err != nil {
		return res, err
	}
	if err := s.remove(ctx, c, cfg, deletes, &res); err != nil {
		return res, err
	}
	return res, nil
}

// resolvePending resolves creations with an unknown outcome and rows after a
// change of the target (retargetHash) via the memo marker of the
// transactions in the account (one request).
func (s *Service) resolvePending(ctx context.Context, c *client, cfg store.YNABConfig, wants map[int64]want, rows map[int64]store.YNABSync, pending []int64) error {
	since, err := s.pendingSince(ctx, cfg, wants, pending)
	if err != nil {
		return err
	}
	txns, err := c.accountTransactions(ctx, cfg.PlanID, cfg.AccountID, since)
	if err != nil {
		return err
	}
	found := map[int64]string{}
	for _, t := range txns {
		if t.Deleted {
			continue
		}
		if id, ok := markerID(t.memo()); ok {
			found[id] = t.ID
		}
	}
	upd := make([]store.YNABSync, 0, len(pending))
	for _, id := range pending {
		r := rows[id]
		r.TxnID, r.Hash = found[id], "" // "" forces a PATCH (found) or a new creation
		rows[id] = r
		upd = append(upd, r)
	}
	return s.d.Store.PutYNABSync(ctx, upd...)
}

// pendingSince is the date from which resolvePending searches: the start
// date, or the earliest date of the pending expenses if earlier (backdated
// expenses belong too, see Selection).
func (s *Service) pendingSince(ctx context.Context, cfg store.YNABConfig, wants map[int64]want, pending []int64) (time.Time, error) {
	since := cfg.StartDate
	for _, id := range pending {
		w, ok := wants[id]
		date := w.Date
		if !ok {
			// no longer wanted (e.g. deleted): its date from the expense
			e, err := s.d.Store.GetExpense(ctx, id)
			if err != nil {
				return since, err
			}
			date = e.Date
		}
		if date.Before(since) {
			since = date
		}
	}
	return since, nil
}

func (s *Service) row(cfg store.YNABConfig, w want) store.YNABSync {
	return store.YNABSync{ExpenseID: w.ExpenseID, ParticipantID: cfg.ParticipantID}
}

func (s *Service) failedRow(cfg store.YNABConfig, w want, txnID string, err error) store.YNABSync {
	r := s.row(cfg, w)
	r.TxnID, r.Hash, r.LastError = txnID, errorHashPrefix+w.hash, redact(err.Error(), cfg.Token)
	return r
}

// create creates new transactions in batches.
func (s *Service) create(ctx context.Context, c *client, cfg store.YNABConfig, ws []want, res *syncResult) error {
	for len(ws) > 0 {
		chunk := ws[:min(chunkSize, len(ws))]
		ws = ws[len(chunk):]
		if err := s.markPending(ctx, cfg, chunk, pendingHash); err != nil {
			return err
		}
		txns := make([]saveTxn, len(chunk))
		for i, w := range chunk {
			txns[i] = w.newTxn(cfg.AccountID)
		}
		got, err := c.createTransactions(ctx, cfg.PlanID, txns)
		switch {
		case err == nil:
			if err := s.applyCreated(ctx, cfg, chunk, got, res); err != nil {
				return err
			}
		case uncertain(err):
			return err // stays "pending", the next run resolves it
		case runLevel(err):
			// certainly not created: undo the pending mark
			s.markPending(ctx, cfg, chunk, "")
			return err
		default:
			// Batch call rejected (400/409/…): try one by one to find the
			// faulty transaction.
			if err := s.createEach(ctx, c, cfg, chunk, res); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Service) markPending(ctx context.Context, cfg store.YNABConfig, ws []want, hash string) error {
	rows := make([]store.YNABSync, len(ws))
	for i, w := range ws {
		rows[i] = s.row(cfg, w)
		rows[i].Hash = hash
	}
	return s.d.Store.PutYNABSync(ctx, rows...)
}

func (s *Service) applyCreated(ctx context.Context, cfg store.YNABConfig, ws []want, got []apiTxn, res *syncResult) error {
	ids := map[int64]string{}
	for _, t := range got {
		if id, ok := markerID(t.memo()); ok {
			ids[id] = t.ID
		}
	}
	rows := make([]store.YNABSync, 0, len(ws))
	now := s.now()
	for _, w := range ws {
		r := s.row(cfg, w)
		if txnID, ok := ids[w.ExpenseID]; ok {
			r.TxnID, r.Hash, r.SyncedAt = txnID, w.hash, now
			res.Created++
		} else {
			// not in the response: stays "pending" and is resolved in the next run
			r.Hash, r.LastError = pendingHash, "YNAB hat das Anlegen nicht bestätigt."
			res.Failed++
			res.Again = true
		}
		rows = append(rows, r)
	}
	return s.d.Store.PutYNABSync(ctx, rows...)
}

func (s *Service) createEach(ctx context.Context, c *client, cfg store.YNABConfig, ws []want, res *syncResult) error {
	succeeded := false
	for i, w := range ws {
		if i >= maxSinglePerRun {
			res.Again = true
			return s.markPending(ctx, cfg, ws[i:], "")
		}
		got, err := c.createTransactions(ctx, cfg.PlanID, []saveTxn{w.newTxn(cfg.AccountID)})
		switch {
		case err == nil:
			succeeded = true
			if err := s.applyCreated(ctx, cfg, []want{w}, got, res); err != nil {
				return err
			}
		case uncertain(err):
			s.markPending(ctx, cfg, ws[i+1:], "")
			return err
		case runLevel(err):
			s.markPending(ctx, cfg, ws[i:], "")
			return err
		default:
			res.Failed++
			if err := s.d.Store.PutYNABSync(ctx, s.failedRow(cfg, w, "", err)); err != nil {
				return err
			}
			if !succeeded && i+1 >= systemicFailures {
				// Everything fails the same way (e.g. account closed): do not
				// try the rest one by one, defer it until the full sync.
				return s.failAll(ctx, cfg, ws[i+1:], false, err, res)
			}
		}
	}
	return nil
}

// failAll marks ws as failed with err (without requests).
func (s *Service) failAll(ctx context.Context, cfg store.YNABConfig, ws []want, keepTxn bool, err error, res *syncResult) error {
	rows := make([]store.YNABSync, len(ws))
	for i, w := range ws {
		txnID := ""
		if keepTxn {
			txnID = w.txnID
		}
		rows[i] = s.failedRow(cfg, w, txnID, err)
	}
	res.Failed += len(ws)
	return s.d.Store.PutYNABSync(ctx, rows...)
}

// update changes transactions in batches (PATCH is idempotent: on an unclear
// outcome the next run simply repeats it).
func (s *Service) update(ctx context.Context, c *client, cfg store.YNABConfig, ws []want, res *syncResult) error {
	for len(ws) > 0 {
		chunk := ws[:min(chunkSize, len(ws))]
		ws = ws[len(chunk):]
		txns := make([]saveTxn, len(chunk))
		for i, w := range chunk {
			txns[i] = w.patchTxn()
		}
		got, err := c.updateTransactions(ctx, cfg.PlanID, txns)
		switch {
		case err == nil:
			if err := s.applyUpdated(ctx, cfg, chunk, got, res); err != nil {
				return err
			}
		case runLevel(err) && statusOf(err) != http.StatusNotFound:
			return err
		default:
			// rejected or 404 (a transaction is missing in YNAB): resolve one by one
			if err := s.updateEach(ctx, c, cfg, chunk, res); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Service) applyUpdated(ctx context.Context, cfg store.YNABConfig, ws []want, got []apiTxn, res *syncResult) error {
	byTxn := map[string]apiTxn{}
	for _, t := range got {
		byTxn[t.ID] = t
	}
	rows := make([]store.YNABSync, 0, len(ws))
	now := s.now()
	for _, w := range ws {
		r := s.row(cfg, w)
		t, ok := byTxn[w.txnID]
		switch {
		case !ok:
			r = s.failedRow(cfg, w, w.txnID, errors.New("YNAB hat die Änderung nicht bestätigt."))
			res.Failed++
		case t.Deleted:
			// deleted manually in YNAB: create again (the app is authoritative)
			res.Again = true
		default:
			r.TxnID, r.Hash, r.SyncedAt = w.txnID, w.hash, now
			res.Updated++
		}
		rows = append(rows, r)
	}
	return s.d.Store.PutYNABSync(ctx, rows...)
}

func (s *Service) updateEach(ctx context.Context, c *client, cfg store.YNABConfig, ws []want, res *syncResult) error {
	succeeded := false
	for i, w := range ws {
		if i >= maxSinglePerRun {
			res.Again = true
			return nil
		}
		got, err := c.updateTransactions(ctx, cfg.PlanID, []saveTxn{w.patchTxn()})
		switch {
		case err == nil:
			succeeded = true
			if err := s.applyUpdated(ctx, cfg, []want{w}, got, res); err != nil {
				return err
			}
		case statusOf(err) == http.StatusNotFound:
			// The transaction no longer exists in YNAB: create it again.
			if err := s.confirmTarget(ctx, c, cfg); err != nil {
				return err
			}
			succeeded = true
			res.Again = true
			if err := s.d.Store.PutYNABSync(ctx, s.row(cfg, w)); err != nil {
				return err
			}
		case runLevel(err):
			return err
		default:
			res.Failed++
			if err := s.d.Store.PutYNABSync(ctx, s.failedRow(cfg, w, w.txnID, err)); err != nil {
				return err
			}
			if !succeeded && i+1 >= systemicFailures {
				return s.failAll(ctx, cfg, ws[i+1:], true, err, res)
			}
		}
	}
	return nil
}

// remove deletes transactions that are gone (one by one; 404 counts as done
// if plan and account exist).
func (s *Service) remove(ctx context.Context, c *client, cfg store.YNABConfig, rows []store.YNABSync, res *syncResult) error {
	for i, r := range rows {
		if i >= maxDeletesPerRun {
			res.Again = true
			return nil
		}
		err := c.deleteTransaction(ctx, cfg.PlanID, r.TxnID)
		if statusOf(err) == http.StatusNotFound {
			if err := s.confirmTarget(ctx, c, cfg); err != nil {
				return err
			}
			err = nil // already deleted in YNAB
		}
		switch {
		case err == nil:
			res.Deleted++
			if err := s.d.Store.DeleteYNABSync(ctx, cfg.ParticipantID, r.ExpenseID); err != nil {
				return err
			}
		case runLevel(err):
			return err
		default:
			res.Failed++
			r.LastError = redact(err.Error(), cfg.Token)
			if err := s.d.Store.PutYNABSync(ctx, r); err != nil {
				return err
			}
		}
	}
	return nil
}

// confirmTarget checks – once per run, with one request – that plan and
// account exist before a 404 for a single transaction is taken as "the
// transaction is gone". YNAB answers 404 for every transaction as well if the
// whole plan is gone or invisible to the token (token of another YNAB user);
// dropping transaction IDs or counting DELETEs as done would then lead to
// duplicates and leftovers once the setup is corrected. Its error stops the
// run (404: "Plan oder Konto gibt es nicht").
func (s *Service) confirmTarget(ctx context.Context, c *client, cfg store.YNABConfig) error {
	if c.targetOK {
		return nil
	}
	a, err := c.account(ctx, cfg.PlanID, cfg.AccountID)
	if err == nil && a.Deleted {
		err = &APIError{Status: http.StatusNotFound, Detail: "Konto gelöscht"}
	}
	if err != nil {
		return err
	}
	c.targetOK = true
	return nil
}

// redact removes the token from error texts before they are stored, logged
// or shown.
func redact(msg, token string) string {
	if token != "" {
		msg = strings.ReplaceAll(msg, token, "•••")
	}
	return msg
}
