package web

import (
	"context"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"teilen/internal/store"
)

// IdentityCookie enthält die ID der Person, die man ist. Keine Anmeldung:
// Wer die App öffnen kann, darf jede Person wählen.
const IdentityCookie = "wer"

type meKey struct{}

// Me liefert die aktuell gewählte Person aus dem Request-Context. Hinter der
// Identitäts-Middleware ist sie auf allen nicht-öffentlichen Pfaden gesetzt.
func Me(ctx context.Context) (store.Participant, bool) {
	p, ok := ctx.Value(meKey{}).(store.Participant)
	return p, ok
}

// WithMe setzt die Person im Context (für Tests anderer Pakete).
func WithMe(ctx context.Context, p store.Participant) context.Context {
	return context.WithValue(ctx, meKey{}, p)
}

// SetIdentity setzt das Cookie für Person id (1 Jahr gültig).
func SetIdentity(w http.ResponseWriter, r *http.Request, id int64) {
	http.SetCookie(w, &http.Cookie{
		Name:     IdentityCookie,
		Value:    strconv.FormatInt(id, 10),
		Path:     "/",
		MaxAge:   365 * 24 * 3600,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https",
	})
}

// isPublic: Pfade, die ohne gewählte Person erreichbar sind.
func isPublic(p string) bool {
	switch p {
	case "/wer", "/wer/neu", "/healthz", "/manifest.webmanifest", "/sw.js", "/favicon.ico":
		return true
	}
	return strings.HasPrefix(p, "/static/") || strings.HasPrefix(p, "/mcp/")
}

// identity liest das Cookie, legt die Person in den Context und schickt
// Besucher ohne (gültige) Person auf /wer. /api/… bekommt stattdessen 401.
func identity(st *store.Store, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if c, err := r.Cookie(IdentityCookie); err == nil {
			if id, err := strconv.ParseInt(c.Value, 10, 64); err == nil {
				if p, err := st.GetParticipant(r.Context(), id); err == nil && !p.Archived() {
					next.ServeHTTP(w, r.WithContext(WithMe(r.Context(), p)))
					return
				}
			}
		}
		if isPublic(r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/api/") {
			WriteJSON(w, http.StatusUnauthorized, map[string]string{"error": "Bitte zuerst auswählen, wer du bist."})
			return
		}
		target := "/wer"
		if r.Method == http.MethodGet && r.URL.Path != "/" {
			target += "?zurueck=" + url.QueryEscape(r.URL.RequestURI())
		}
		http.Redirect(w, r, target, http.StatusSeeOther)
	})
}

// safeReturn lässt nur lokale Pfade als Rücksprungziel zu.
func safeReturn(s string) string {
	if !strings.HasPrefix(s, "/") || strings.HasPrefix(s, "//") || strings.HasPrefix(s, "/\\") || strings.HasPrefix(s, "/wer") {
		return "/"
	}
	return s
}

// securityHeaders setzt Standard-Header. CSP: Skripte nur aus /static
// (keine Inline-Skripte!), Inline-Styles sind erlaubt.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "same-origin")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'")
		next.ServeHTTP(w, r)
	})
}

// Wrap legt die gemeinsamen Middlewares (Security-Header, Identität) um den
// kompletten Mux. main ruft das genau einmal auf.
func Wrap(d Deps, h http.Handler) http.Handler {
	return securityHeaders(identity(d.Store, h))
}
