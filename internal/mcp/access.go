package mcp

import (
	"net"
	"net/http"
	"net/netip"
	"strings"

	"teilen/internal/config"
)

// clientIP ermittelt die Adresse des Clients.
//
// Kommt die Verbindung nicht von einem vertrauenswürdigen Proxy, zählt nur
// RemoteAddr – Header wie X-Forwarded-For werden dann ignoriert (sonst könnte
// jeder sie fälschen). Kommt sie von einem Proxy aus trusted, wird
// X-Forwarded-For von rechts gelesen: Die erste Adresse, die nicht selbst ein
// vertrauenswürdiger Proxy ist, ist der Client (alles links davon hat der
// Client ggf. selbst geschrieben). Ohne X-Forwarded-For gilt X-Real-IP, ohne
// beides der Proxy selbst. Ist ein Eintrag unlesbar, ist das Ergebnis
// ungültig (fail closed).
func clientIP(r *http.Request, trusted []netip.Prefix) netip.Addr {
	remote := parseAddr(r.RemoteAddr)
	if !remote.IsValid() || !config.ContainsAddr(trusted, remote) {
		return remote
	}
	var hops []string
	for _, v := range r.Header.Values("X-Forwarded-For") {
		for _, h := range strings.Split(v, ",") {
			if h = strings.TrimSpace(h); h != "" {
				hops = append(hops, h)
			}
		}
	}
	if len(hops) == 0 {
		if real := strings.TrimSpace(r.Header.Get("X-Real-IP")); real != "" {
			return parseAddr(real)
		}
		return remote
	}
	for i := len(hops) - 1; i >= 0; i-- {
		a := parseAddr(hops[i])
		if !a.IsValid() {
			return netip.Addr{}
		}
		if !config.ContainsAddr(trusted, a) {
			return a
		}
	}
	// Die ganze Kette besteht aus vertrauenswürdigen Proxys.
	return parseAddr(hops[0])
}

// parseAddr liest "1.2.3.4", "1.2.3.4:567", "::1", "[::1]:567" (IPv4-mapped
// IPv6 wird entpackt). Unlesbares ergibt eine ungültige Adresse.
func parseAddr(s string) netip.Addr {
	s = strings.TrimSpace(s)
	if a, err := netip.ParseAddr(s); err == nil {
		return a.Unmap().WithZone("")
	}
	if host, _, err := net.SplitHostPort(s); err == nil {
		if a, err := netip.ParseAddr(host); err == nil {
			return a.Unmap().WithZone("")
		}
	}
	return netip.Addr{}
}
