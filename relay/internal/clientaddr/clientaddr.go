// Package clientaddr is who is calling: the address rate limits and logs key
// on, for the operator console and the card app's customer routes alike.
package clientaddr

import (
	"net"
	"net/http"
	"strings"
)

// Of is the caller's address: the last X-Forwarded-For hop when the hop in
// front of the relay is trusted to write it, else the TCP peer. The last hop
// is the one the trusted proxy appended; earlier ones are the client's word.
func Of(r *http.Request, trustForwardedFor bool) string {
	if trustForwardedFor {
		if forwarded := r.Header.Values("X-Forwarded-For"); len(forwarded) > 0 {
			hops := strings.Split(forwarded[len(forwarded)-1], ",")
			if last := strings.TrimSpace(hops[len(hops)-1]); net.ParseIP(last) != nil {
				return last
			}
		}
	}
	return Peer(r)
}

// Peer is the TCP peer's address.
func Peer(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// PeerIsLocal reports whether the TCP peer is a loopback or private address:
// a reverse proxy on the same host or network (the self-hosted NGINX front).
// Traffic straight from the internet never comes from one, so such a peer's
// X-Forwarded-For can be believed.
func PeerIsLocal(r *http.Request) bool {
	ip := net.ParseIP(Peer(r))
	return ip != nil && (ip.IsLoopback() || ip.IsPrivate())
}
