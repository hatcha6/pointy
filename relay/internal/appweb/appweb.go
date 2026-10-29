// Package appweb serves the shop app's web build (frontend/) on its own host,
// app.dftr.ly: a shop's staff open it from anywhere — an iPhone in Safari,
// where there is no app to install — and reach their shop through the relay.
//
// The app and the relay share the host, so the app calls the relay on its own
// origin and needs no CORS: /api/ (the relay's tunnel into the shop: the
// sign-in route, then tickets) and /v1/relay-ticket-refresh go on to the
// relay; every other path is the build. Pages of the app are index.html.
//
// The shop's backend checks a browser's Origin against its own address,
// which behind the connector is the backend's LAN host — so a request the
// app makes on this origin would fail its CSRF check. The relay served the
// page, so it vouches for its own origin and drops that Origin; any other
// origin passes untouched and is refused by the backend as before. The CSRF
// token itself is still checked.
package appweb

import (
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"path"
	"strings"

	"pointy/relay/internal/webbuild"
)

// Config says where the build is and which hosts it answers.
type Config struct {
	// Hosts are the host names the web app is served on (app.dftr.ly).
	// Requests to any other host go to the relay as before.
	Hosts []string
	// Files is the build (frontend/build/web): index.html at its root.
	Files fs.FS
}

// Handler serves the web build for its hosts and hands everything else on.
type Handler struct {
	hosts map[string]bool
	files fs.FS
	next  http.Handler
}

// Wrap puts the web app in front of next for cfg's hosts.
func Wrap(next http.Handler, cfg Config) (*Handler, error) {
	if len(cfg.Hosts) == 0 {
		return nil, errors.New("appweb: no host to serve the web app on")
	}
	if cfg.Files == nil {
		return nil, errors.New("appweb: no web build")
	}
	if !webbuild.IsFile(cfg.Files, "index.html") {
		return nil, errors.New("appweb: the web build has no index.html")
	}
	hosts := make(map[string]bool, len(cfg.Hosts))
	for _, host := range cfg.Hosts {
		host = strings.ToLower(strings.TrimSpace(host))
		if host == "" || strings.ContainsAny(host, "/:") {
			return nil, fmt.Errorf("appweb: %q is not a host name", host)
		}
		hosts[host] = true
	}
	return &Handler{hosts: hosts, files: cfg.Files, next: next}, nil
}

// relayPath reports whether a path is the relay's own, not the build's.
func relayPath(urlPath string) bool {
	return strings.HasPrefix(urlPath, "/api/") || urlPath == "/v1/relay-ticket-refresh"
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	host := webbuild.HostOf(r.Host)
	if !h.hosts[host] {
		h.next.ServeHTTP(w, r)
		return
	}
	if relayPath(r.URL.Path) {
		if strings.EqualFold(strings.TrimRight(r.Header.Get("Origin"), "/"), "https://"+host) {
			r = r.Clone(r.Context())
			r.Header.Del("Origin")
			r.Header.Del("Referer")
		}
		h.next.ServeHTTP(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	header := w.Header()
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("Referrer-Policy", "strict-origin-when-cross-origin")
	// A shop's books in someone else's frame is a click-jacking page.
	header.Set("X-Frame-Options", "DENY")
	name := webbuild.Name(r.URL.Path)
	if name != "" && webbuild.IsFile(h.files, name) {
		webbuild.SetCaching(header, name)
		webbuild.Serve(w, r, h.files, name)
		return
	}
	// A missing file is a 404; any other address is a page of the app.
	if path.Ext(name) != "" {
		http.NotFound(w, r)
		return
	}
	webbuild.SetCaching(header, "index.html")
	webbuild.Serve(w, r, h.files, "index.html")
}
