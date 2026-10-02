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

	"teilen/internal/domain"
	"teilen/internal/store"
)

// Abgleich: Für jede Person mit YNAB-Verbindung wird der Soll-Zustand (eine
// Buchung je eigener Ausgabe, siehe PostingFor) mit ynab_sync verglichen.
// Nur die Unterschiede gehen an YNAB – gebündelt, um das Limit von 200
// Anfragen pro Stunde zu schonen: neu → ein POST für alle, geändert → ein
// PATCH für alle, entfallen → DELETE einzeln (die API kennt kein Sammel-DELETE).
// Ohne Unterschiede kostet ein Lauf keine einzige Anfrage.
//
// Bedeutung von ynab_sync.synced_hash:
//   - Fingerabdruck des zuletzt übertragenen Soll-Zustands (hashOf)
//   - "error:" + Fingerabdruck: Übertragen dieses Stands schlug fehl; wird erst
//     bei Änderung, im stündlichen Vollabgleich oder per „Jetzt
//     synchronisieren“ erneut versucht
//   - "pending": Anlegen läuft bzw. das Ergebnis ist unbekannt (Timeout, 5xx).
//     Der nächste Lauf sucht die Buchung über die Memo-Markierung „teilen #ID“
//     im Konto, statt blind neu anzulegen (sonst drohen Dubletten).
//   - "": unbekannt bzw. neu anlegen/ändern
//
// Buchungen bekommen bewusst keine import_id: YNAB versucht importierte
// Buchungen mit gleich hohen, von Hand erfassten Buchungen (±10 Tage) im
// selben Konto zusammenzuführen. Im Konto „Geteilt“ sind das die Transfers
// für Rückzahlungen – bei gleichen Beträgen (sehr häufig: Hälfte zurück)
// würde YNAB den Anteil mit dem Transfer verschmelzen und der Saldo stimmte
// nicht mehr. Dubletten verhindert stattdessen der "pending"-Mechanismus.
const (
	pendingHash      = "pending"
	errorHashPrefix  = "error:"
	hashVersion      = "v1"
	chunkSize        = 100 // Buchungen pro POST/PATCH
	maxDeletesPerRun = 40  // DELETE kostet je eine Anfrage
	maxSinglePerRun  = 20  // Einzelversuche nach einem abgelehnten Sammelaufruf
	systemicFailures = 3   // so viele Einzelfehler in Folge ohne Erfolg: Rest zurückstellen
	retryDelay       = 5 * time.Minute
	maxBackoff       = time.Hour
)

var errTokenInvalid = errors.New("Der YNAB-Token ist ungültig oder abgelaufen. Bitte einen neuen Token eintragen.")

// backoffError: YNAB wird bis until nicht gefragt (Anfragelimit oder Störung).
type backoffError struct{ until time.Time }

func (e backoffError) Error() string {
	return "YNAB pausiert bis " + e.until.Format("15:04") + " Uhr (Anfragelimit oder Störung)."
}

// Status ist der Sync-Zustand einer Person (settings-Schlüssel "ynab.status.<id>").
type Status struct {
	LastRun      time.Time     `json:"last_run,omitzero"`  // letzter Versuch
	LastSync     time.Time     `json:"last_sync,omitzero"` // letzter vollständiger Abgleich
	Summary      string        `json:"summary,omitempty"`  // Ergebnis des letzten Abgleichs
	Error        string        `json:"error,omitempty"`    // Fehler des letzten Versuchs (ohne Token)
	TokenInvalid bool          `json:"token_invalid,omitempty"`
	RetryAt      time.Time     `json:"retry_at,omitzero"` // vorher keine Anfragen
	Backoff      time.Duration `json:"backoff,omitempty"` // letzte Wartezeit nach 429
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

// syncResult zählt, was ein Lauf bei YNAB bewirkt hat.
type syncResult struct {
	Created, Updated, Deleted, Failed int
	Again                             bool // es bleibt Arbeit: bald erneut laufen
}

func (r syncResult) String() string {
	s := fmt.Sprintf("%d neu · %d geändert · %d gelöscht", r.Created, r.Updated, r.Deleted)
	if r.Failed > 0 {
		s += fmt.Sprintf(" · %d fehlgeschlagen", r.Failed)
	}
	return s
}

// want ist der Soll-Zustand einer Buchung in YNAB.
type want struct {
	Posting
	category string // YNAB-Kategorie-ID, "" = unkategorisiert
	hash     string
	txnID    string // vorhandene Buchung (für PATCH)
}

func (w want) milliunits() int64 { return -w.AmountCents * 10 } // 1 Cent = 10 Milliunits; Ausgang negativ

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

// patchTxn ändert Datum, Betrag, Empfänger, Memo und – nur wenn zugeordnet –
// die Kategorie. Ohne Zuordnung bleibt eine in YNAB von Hand gesetzte
// Kategorie erhalten; cleared/approved fasst der Sync nach dem Anlegen
// nicht mehr an (z. B. abgeglichene Buchungen).
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

// today ist der letzte Tag, den YNAB sicher nicht als Zukunft ablehnt.
func (s *Service) today() time.Time { return Today(s.now(), s.d.Config.Location) }

// Today ist der letzte Tag, den YNAB sicher nicht als Zukunft ablehnt:
// heute in der App-Zeitzone loc, höchstens aber heute in UTC.
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

// desired berechnet den Soll-Zustand einer Person (siehe Selection), nach
// Ausgaben-ID.
func (s *Service) desired(ctx context.Context, cfg store.YNABConfig) (map[int64]want, error) {
	sel, err := NewSelection(ctx, s.d.Store, cfg, s.today())
	if err != nil {
		return nil, err
	}
	// Alle Ausgaben der Person, nicht erst ab Startdatum: auch frühere können
	// dazugehören (nachträglich erfasst oder schon in YNAB).
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

// runLevel: Fehler, die den ganzen Lauf der Person abbrechen (auch
// Datenbankfehler und unklare Ausgänge). Übrige 4xx betreffen einzelne Buchungen.
func runLevel(err error) bool {
	switch statusOf(err) {
	case 0, http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound, http.StatusTooManyRequests:
		return true
	}
	return uncertain(err)
}

// syncOne gleicht eine Person ab und pflegt ihren Status. full versucht auch
// unveränderte, zuvor fehlgeschlagene Buchungen erneut.
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

// syncParticipant ist der eigentliche Abgleich einer Person.
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
		if r.TxnID == "" && r.Hash == pendingHash {
			pending = append(pending, r.ExpenseID)
		}
	}
	c := s.client(cfg.Token)
	if len(pending) > 0 {
		if err := s.resolvePending(ctx, c, cfg, rows, pending); err != nil {
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
			// fehlgeschlagen und unverändert: erst im Vollabgleich erneut
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
		// Entfallen (gelöscht oder Anteil 0): immer löschen, auch wenn der
		// letzte Versuch (z. B. ein PATCH) fehlschlug.
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

// resolvePending klärt Anlagen mit unbekanntem Ergebnis über die
// Memo-Markierung der Buchungen im Konto (eine Anfrage).
func (s *Service) resolvePending(ctx context.Context, c *client, cfg store.YNABConfig, rows map[int64]store.YNABSync, pending []int64) error {
	txns, err := c.accountTransactions(ctx, cfg.PlanID, cfg.AccountID, cfg.StartDate)
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
		r.TxnID, r.Hash = found[id], "" // "" erzwingt PATCH (gefunden) bzw. Neuanlage
		rows[id] = r
		upd = append(upd, r)
	}
	return s.d.Store.PutYNABSync(ctx, upd...)
}

func (s *Service) row(cfg store.YNABConfig, w want) store.YNABSync {
	return store.YNABSync{ExpenseID: w.ExpenseID, ParticipantID: cfg.ParticipantID}
}

func (s *Service) failedRow(cfg store.YNABConfig, w want, txnID string, err error) store.YNABSync {
	r := s.row(cfg, w)
	r.TxnID, r.Hash, r.LastError = txnID, errorHashPrefix+w.hash, redact(err.Error(), cfg.Token)
	return r
}

// create legt neue Buchungen gebündelt an.
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
			return err // bleibt "pending", der nächste Lauf klärt das
		case runLevel(err):
			// sicher nicht angelegt: Vormerkung zurücknehmen
			s.markPending(ctx, cfg, chunk, "")
			return err
		default:
			// Sammelaufruf abgelehnt (400/409/…): einzeln versuchen, um die
			// fehlerhafte Buchung zu finden.
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
			// nicht in der Antwort: bleibt "pending" und wird im nächsten Lauf geklärt
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
				// Alles scheitert gleich (z. B. Konto geschlossen): Rest nicht
				// einzeln probieren, sondern bis zum Vollabgleich zurückstellen.
				return s.failAll(ctx, cfg, ws[i+1:], false, err, res)
			}
		}
	}
	return nil
}

// failAll markiert ws als fehlgeschlagen mit err (ohne Anfragen).
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

// update ändert Buchungen gebündelt (PATCH ist idempotent: bei unklarem
// Ausgang wiederholt der nächste Lauf einfach).
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
			// abgelehnt oder 404 (eine Buchung fehlt in YNAB): einzeln klären
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
			// in YNAB von Hand gelöscht: neu anlegen (die App ist maßgeblich)
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
			// Buchung gibt es in YNAB nicht mehr: neu anlegen. (Ist der ganze
			// Plan weg, scheitert das Anlegen danach mit einem klaren Fehler.)
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

// remove löscht entfallene Buchungen (einzeln; 404 gilt als erledigt).
func (s *Service) remove(ctx context.Context, c *client, cfg store.YNABConfig, rows []store.YNABSync, res *syncResult) error {
	for i, r := range rows {
		if i >= maxDeletesPerRun {
			res.Again = true
			return nil
		}
		err := c.deleteTransaction(ctx, cfg.PlanID, r.TxnID)
		switch {
		case err == nil || statusOf(err) == http.StatusNotFound:
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

// redact entfernt den Token aus Fehlertexten, bevor sie gespeichert,
// geloggt oder angezeigt werden.
func redact(msg, token string) string {
	if token != "" {
		msg = strings.ReplaceAll(msg, token, "•••")
	}
	return msg
}
