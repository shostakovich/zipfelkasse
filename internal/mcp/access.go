package mcp

import (
	"net"
	"net/http"
	"net/netip"
	"strings"

	"github.com/shostakovich/zipfelkasse/internal/config"
)

// clientIP determines the client's address.
//
// If the connection does not come from a trusted proxy, only RemoteAddr
// counts – headers such as X-Forwarded-For are ignored then (otherwise anyone
// could forge them). If it comes from a proxy in trusted, X-Forwarded-For is
// read from the right: the first address that is not itself a trusted proxy
// is the client (anything to the left of it may have been written by the
// client). Without X-Forwarded-For, X-Real-IP applies; without both, the
// proxy itself. If an entry is unparsable, the result is invalid (fail
// closed).
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
	// The whole chain consists of trusted proxies.
	return parseAddr(hops[0])
}

// parseAddr parses "1.2.3.4", "1.2.3.4:567", "::1", "[::1]:567" (IPv4-mapped
// IPv6 is unmapped). Anything unparsable yields an invalid address.
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
