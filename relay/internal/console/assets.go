package console

import (
	"bytes"
	"embed"
	"io/fs"
	"net/http"
	"path"
	"strings"
	"time"
)

// dist is the built web app (relay/console-ui, `make relay-console-build`).
// Only .gitkeep is committed; the Docker image builds the app before the
// binary, so a release always carries it.
//
//go:embed all:dist
var dist embed.FS

// serveStatic serves the app's files, and index.html for every other
// /console/ path so the app's own routes survive a reload.
func (c *Console) serveStatic(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	name := strings.TrimPrefix(path.Clean(r.URL.Path), Prefix+"/")
	if name != "" && name != "index.html" && !strings.Contains(name, "..") {
		if content, err := fs.ReadFile(dist, "dist/"+name); err == nil {
			if strings.HasPrefix(name, "assets/") {
				// Vite names them by content hash.
				w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			} else {
				w.Header().Set("Cache-Control", "public, max-age=3600")
			}
			http.ServeContent(w, r, name, time.Time{}, bytes.NewReader(content))
			return
		}
		if strings.HasPrefix(name, "assets/") {
			http.NotFound(w, r)
			return
		}
	}
	index, err := fs.ReadFile(dist, "dist/index.html")
	if err != nil {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("The console app was not built into this binary: run `make relay-console-build`.\n"))
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	http.ServeContent(w, r, "index.html", time.Time{}, bytes.NewReader(index))
}
