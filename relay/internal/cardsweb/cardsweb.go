// Package cardsweb serves «دفتر كروت»'s web build (cards/) on its own host,
// cards.dftr.ly, from the same relay that answers its API on my.dftr.ly.
//
// The build is plain files. Every page of the app (/brand/pubg, /category/…)
// is index.html: Flutter reads the address itself. The two .well-known files
// are what let phones open the same addresses in the installed app (iOS
// Universal Links, Android App Links), so they go out as JSON, unredirected.
package cardsweb

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path"
	"strings"
)

// Config says where the build is and which hosts it answers.
type Config struct {
	// Hosts are the host names the web app is served on (cards.dftr.ly).
	// Requests to any other host go to the relay as before.
	Hosts []string
	// Files is the build (cards/build/web): index.html at its root.
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
		return nil, errors.New("cardsweb: no host to serve the web app on")
	}
	if cfg.Files == nil {
		return nil, errors.New("cardsweb: no web build")
	}
	if info, err := fs.Stat(cfg.Files, "index.html"); err != nil || info.IsDir() {
		return nil, errors.New("cardsweb: the web build has no index.html")
	}
	hosts := make(map[string]bool, len(cfg.Hosts))
	for _, host := range cfg.Hosts {
		host = strings.ToLower(strings.TrimSpace(host))
		if host == "" || strings.ContainsAny(host, "/:") {
			return nil, fmt.Errorf("cardsweb: %q is not a host name", host)
		}
		hosts[host] = true
	}
	return &Handler{hosts: hosts, files: cfg.Files, next: next}, nil
}

// Dir is the web build in a directory, checked by [Wrap].
func Dir(dir string) fs.FS {
	return os.DirFS(dir)
}

// ParseHosts reads a comma-separated host list (POINTY_RELAY_CARDS_WEB_HOSTS).
func ParseHosts(raw string) []string {
	var hosts []string
	for _, host := range strings.Split(raw, ",") {
		if host = strings.TrimSpace(host); host != "" {
			hosts = append(hosts, host)
		}
	}
	return hosts
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !h.hosts[hostOf(r.Host)] {
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
	// Flutter's files keep their names from build to build (main.dart.js),
	// so every one is checked again: a new build reaches people at once,
	// an unchanged one costs a 304.
	header.Set("Cache-Control", "no-cache")

	name := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
	if name == ".well-known/apple-app-site-association" {
		// Apple reads it only as JSON, and the file has no extension.
		header.Set("Content-Type", "application/json")
	}
	if name != "" && h.isFile(name) {
		http.ServeFileFS(w, r, h.files, name)
		return
	}
	// A missing file is a 404; any other address is a page of the app.
	if path.Ext(name) != "" || strings.HasPrefix(name, ".well-known/") {
		http.NotFound(w, r)
		return
	}
	http.ServeFileFS(w, r, h.files, "index.html")
}

func (h *Handler) isFile(name string) bool {
	info, err := fs.Stat(h.files, name)
	return err == nil && info.Mode().IsRegular()
}

// hostOf is the request's host name without its port, lower-cased.
func hostOf(hostport string) string {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	return strings.ToLower(strings.TrimSuffix(host, "."))
}
