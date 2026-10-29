// Package cardsweb serves «دفتر كروت»'s web build (cards/) on its own host,
// cards.dftr.ly, from the same relay that answers its API on my.dftr.ly.
//
// The build is plain files. Every page of the app (/brand/pubg, /category/…)
// is index.html: Flutter reads the address itself. The two .well-known files
// are what let phones open the same addresses in the installed app (iOS
// Universal Links, Android App Links), so they go out as JSON, unredirected.
//
// Files go out compressed and cached as package webbuild serves every build.
//
// A page carries its own link preview (preview.go, page.go): a brand's link
// shows that brand's name and picture in WhatsApp or Telegram.
package cardsweb

import (
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"path"
	"strings"

	"pointy/relay/internal/webbuild"
)

// Config says where the build is and which hosts it answers.
type Config struct {
	// Hosts are the host names the web app is served on (cards.dftr.ly).
	// Requests to any other host go to the relay as before.
	Hosts []string
	// Files is the build (cards/build/web): index.html at its root.
	Files fs.FS
	// Previews is the catalog link previews name brands from; nil gives
	// every page the shelf's own preview.
	Previews Source
	Logger   *slog.Logger
}

// Handler serves the web build for its hosts and hands everything else on.
type Handler struct {
	hosts    map[string]bool
	files    fs.FS
	next     http.Handler
	index    []byte
	previews *previews
}

// Wrap puts the web app in front of next for cfg's hosts.
func Wrap(next http.Handler, cfg Config) (*Handler, error) {
	if len(cfg.Hosts) == 0 {
		return nil, errors.New("cardsweb: no host to serve the web app on")
	}
	if cfg.Files == nil {
		return nil, errors.New("cardsweb: no web build")
	}
	index, err := fs.ReadFile(cfg.Files, "index.html")
	if err != nil {
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
	return &Handler{
		hosts:    hosts,
		files:    cfg.Files,
		next:     next,
		index:    index,
		previews: newPreviews(cfg.Previews, cfg.Logger),
	}, nil
}

// Dir is the web build in a directory, checked by [Wrap].
func Dir(dir string) fs.FS {
	return webbuild.Dir(dir)
}

// ParseHosts reads a comma-separated host list (POINTY_RELAY_CARDS_WEB_HOSTS).
func ParseHosts(raw string) []string {
	return webbuild.ParseHosts(raw)
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
	name := webbuild.Name(r.URL.Path)
	webbuild.SetCaching(header, name)
	if name == ".well-known/apple-app-site-association" {
		// Apple reads it only as JSON, and the file has no extension.
		header.Set("Content-Type", "application/json")
	}
	if strings.HasPrefix(name, "og/") {
		h.servePicture(w, r, name)
		return
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
	h.servePage(w, r, name)
}

// serve sends name, compressed when the build has it so and the browser
// takes it.
func (h *Handler) serve(w http.ResponseWriter, r *http.Request, name string) {
	webbuild.Serve(w, r, h.files, name)
}

func (h *Handler) isFile(name string) bool {
	return webbuild.IsFile(h.files, name)
}

func hostOf(hostport string) string {
	return webbuild.HostOf(hostport)
}

func accepts(header, coding string) bool {
	return webbuild.Accepts(header, coding)
}
