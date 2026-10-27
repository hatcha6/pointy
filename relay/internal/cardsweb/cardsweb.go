// Package cardsweb serves «دفتر كروت»'s web build (cards/) on its own host,
// cards.dftr.ly, from the same relay that answers its API on my.dftr.ly.
//
// The build is plain files. Every page of the app (/brand/pubg, /category/…)
// is index.html: Flutter reads the address itself. The two .well-known files
// are what let phones open the same addresses in the installed app (iOS
// Universal Links, Android App Links), so they go out as JSON, unredirected.
//
// The build is large (the app's code alone is megabytes) and its customers
// are on Libyan mobile networks, so each file goes out as small as it can:
// the build ships each compressible file already compressed beside it
// (main.dart.js.br, main.dart.js.gz), and the one the browser accepts is
// sent. A fingerprinted file (main.3f9a2c1b7d.dart.js) never changes, so a
// browser keeps it for good; every other file is checked again each visit.
package cardsweb

import (
	"errors"
	"fmt"
	"io/fs"
	"mime"
	"net"
	"net/http"
	"os"
	"path"
	"regexp"
	"strconv"
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
	name := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
	if fingerprinted.MatchString(path.Base(name)) {
		// Its name changes whenever its content does.
		header.Set("Cache-Control", "public, max-age=31536000, immutable")
	} else {
		// The rest keep their names from build to build (index.html, the
		// fonts), so every one is checked again: a new build reaches people
		// at once, an unchanged one costs a 304.
		header.Set("Cache-Control", "no-cache")
	}
	if name == ".well-known/apple-app-site-association" {
		// Apple reads it only as JSON, and the file has no extension.
		header.Set("Content-Type", "application/json")
	}
	if name != "" && h.isFile(name) {
		h.serve(w, r, name)
		return
	}
	// A missing file is a 404; any other address is a page of the app.
	if path.Ext(name) != "" || strings.HasPrefix(name, ".well-known/") {
		http.NotFound(w, r)
		return
	}
	h.serve(w, r, "index.html")
}

// fingerprinted is a file name carrying a hash of its content.
var fingerprinted = regexp.MustCompile(`\.[0-9a-f]{10,}\.`)

// encodings are the compressed copies a build may carry, best first.
var encodings = []struct{ name, suffix string }{
	{"br", ".br"},
	{"gzip", ".gz"},
}

// serve sends name, compressed when the build has it so and the browser
// takes it.
func (h *Handler) serve(w http.ResponseWriter, r *http.Request, name string) {
	header := w.Header()
	header.Add("Vary", "Accept-Encoding")
	for _, encoding := range encodings {
		if !accepts(r.Header.Get("Accept-Encoding"), encoding.name) ||
			!h.isFile(name+encoding.suffix) {
			continue
		}
		if header.Get("Content-Type") == "" {
			kind := mime.TypeByExtension(path.Ext(name))
			if kind == "" {
				kind = "application/octet-stream"
			}
			header.Set("Content-Type", kind)
		}
		header.Set("Content-Encoding", encoding.name)
		http.ServeFileFS(w, r, h.files, name+encoding.suffix)
		return
	}
	http.ServeFileFS(w, r, h.files, name)
}

// accepts reports whether an Accept-Encoding header takes coding, at a
// quality above zero.
func accepts(header, coding string) bool {
	for _, part := range strings.Split(header, ",") {
		token, params, _ := strings.Cut(strings.TrimSpace(part), ";")
		if !strings.EqualFold(strings.TrimSpace(token), coding) {
			continue
		}
		if q, ok := strings.CutPrefix(strings.TrimSpace(params), "q="); ok {
			value, err := strconv.ParseFloat(q, 64)
			return err == nil && value > 0
		}
		return true
	}
	return false
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
