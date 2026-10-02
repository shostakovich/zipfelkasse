package web

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"unicode"

	"github.com/shostakovich/zipfelkasse/internal/store"
)

// IdentityCookie holds the ID of the person you are. No login: whoever can
// open the app may pick any person.
const IdentityCookie = "wer"

type meKey struct{}

// Me returns the currently selected person from the request context. Behind
// the identity middleware it is set on all non-public paths.
func Me(ctx context.Context) (store.Participant, bool) {
	p, ok := ctx.Value(meKey{}).(store.Participant)
	return p, ok
}

// WithMe sets the person in the context (for tests of other packages).
func WithMe(ctx context.Context, p store.Participant) context.Context {
	return context.WithValue(ctx, meKey{}, p)
}

// SetIdentity sets the cookie for person id (valid for 1 year).
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

// isPublic reports paths that are reachable without a selected person.
func isPublic(p string) bool {
	switch p {
	case "/wer", "/wer/neu", "/healthz", "/manifest.webmanifest", "/sw.js", "/favicon.ico":
		return true
	}
	return strings.HasPrefix(p, "/static/")
}

// identity reads the cookie, puts the person into the context and sends
// visitors without a (valid) person to /wer. /api/… gets a 401 instead.
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

// safeReturn only allows local paths as a return target. Rejected are control
// characters and backslashes (browsers strip tabs/newlines or read "\" as
// "/", so "/\t/evil" would become "//evil"), anything with a scheme or host,
// and paths that start with "//", even only after decoding.
func safeReturn(s string) string {
	if strings.ContainsFunc(s, isUnsafeRune) {
		return "/"
	}
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "" || u.Host != "" || u.Opaque != "" || u.User != nil ||
		!strings.HasPrefix(s, "/") || strings.HasPrefix(s, "//") ||
		!strings.HasPrefix(u.Path, "/") || strings.HasPrefix(u.Path, "//") ||
		strings.ContainsFunc(u.Path, isUnsafeRune) || strings.HasPrefix(u.Path, "/wer") {
		return "/"
	}
	return s
}

func isUnsafeRune(r rune) bool {
	return r == '\\' || unicode.IsControl(r)
}

// SecurityHeaders sets standard headers. CSP: scripts only from /static (no
// inline scripts!), inline styles are allowed. Part of Wrap; exported for
// handlers that main mounts outside Wrap.
func SecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "same-origin")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'")
		next.ServeHTTP(w, r)
	})
}

// Wrap wraps the shared middlewares (security headers, body limit, CSRF
// protection, identity) around the mux of the browser app. main calls it
// exactly once.
func Wrap(d Deps, h http.Handler) http.Handler {
	return SecurityHeaders(limitBody(d, crossOrigin(d, identity(d.Store, h))))
}

// maxBodyBytes limits request bodies (forms are a few KB).
const maxBodyBytes = 1 << 20

// limitBody rejects request bodies larger than maxBodyBytes with 413. Form
// bodies without Content-Length are parsed here already, so that an oversized
// one also yields 413 instead of an empty form (r.FormValue ignores parse
// errors).
func limitBody(d Deps, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body == nil || r.Body == http.NoBody {
			next.ServeHTTP(w, r)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
		tooLarge := r.ContentLength > maxBodyBytes
		if r.ContentLength < 0 {
			if err := r.ParseForm(); err != nil {
				var mbe *http.MaxBytesError
				tooLarge = errors.As(err, &mbe)
			}
		}
		if !tooLarge {
			next.ServeHTTP(w, r)
			return
		}
		if d.Log != nil {
			d.Log.Warn("request body too large", "method", r.Method, "path", r.URL.Path, "content_length", r.ContentLength)
		}
		w.Header().Set("Connection", "close")
		if strings.HasPrefix(r.URL.Path, "/api/") {
			WriteJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "Die Anfrage ist zu groß."})
			return
		}
		d.Render.Error(w, r, http.StatusRequestEntityTooLarge, "Die gesendeten Daten sind zu groß. Bitte kürze die Eingaben und versuche es noch einmal.")
	})
}

// crossOrigin rejects POSTs and the like that a browser sends from a foreign
// site (Sec-Fetch-Site or Origin ≠ Host). Requests without these headers
// (curl) pass, since they carry no victim's cookie.
func crossOrigin(d Deps, next http.Handler) http.Handler {
	cop := http.NewCrossOriginProtection()
	cop.SetDenyHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if d.Log != nil {
			d.Log.Warn("cross-origin request rejected", "method", r.Method, "path", r.URL.Path, "origin", r.Header.Get("Origin"))
		}
		if strings.HasPrefix(r.URL.Path, "/api/") {
			WriteJSON(w, http.StatusForbidden, map[string]string{"error": "Anfrage von einer fremden Seite abgelehnt."})
			return
		}
		d.Render.Error(w, r, http.StatusForbidden, "Diese Anfrage kam von einer fremden Seite und wurde abgelehnt. Bitte lade die Seite neu und versuche es noch einmal.")
	}))
	return cop.Handler(next)
}
