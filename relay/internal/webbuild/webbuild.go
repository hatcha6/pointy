// Package webbuild serves a Flutter web build the relay hosts on a host of its
// own: «دفتر كروت» on cards.dftr.ly (package cardsweb) and the shop app on
// app.dftr.ly (package appweb).
//
// Builds are large and their users are on Libyan mobile networks, so each
// file goes out as small as it can: a build ships each compressible file
// already compressed beside it (main.dart.js.br, main.dart.js.gz), and the
// one the browser accepts is sent. A fingerprinted file
// (main.3f9a2c1b7d.dart.js) never changes, so a browser keeps it for good;
// every other file is checked again each visit.
package webbuild

import (
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

// Dir is a web build in a directory.
func Dir(dir string) fs.FS {
	return os.DirFS(dir)
}

// ParseHosts reads a comma-separated host list.
func ParseHosts(raw string) []string {
	var hosts []string
	for _, host := range strings.Split(raw, ",") {
		if host = strings.TrimSpace(host); host != "" {
			hosts = append(hosts, host)
		}
	}
	return hosts
}

// HostOf is a request's host name without its port, lower-cased.
func HostOf(hostport string) string {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	return strings.ToLower(strings.TrimSuffix(host, "."))
}

// Name is the build file a request path names: cleaned, without its leading
// slash ("" for the root).
func Name(urlPath string) string {
	return strings.TrimPrefix(path.Clean("/"+urlPath), "/")
}

// fingerprinted is a file name carrying a hash of its content.
var fingerprinted = regexp.MustCompile(`\.[0-9a-f]{10,}\.`)

// SetCaching says how long a browser may keep name.
func SetCaching(header http.Header, name string) {
	if fingerprinted.MatchString(path.Base(name)) {
		// Its name changes whenever its content does.
		header.Set("Cache-Control", "public, max-age=31536000, immutable")
		return
	}
	// The rest keep their names from build to build (index.html, the
	// fonts), so every one is checked again: a new build reaches people at
	// once, an unchanged one costs a 304.
	header.Set("Cache-Control", "no-cache")
}

// encodings are the compressed copies a build may carry, best first.
var encodings = []struct{ name, suffix string }{
	{"br", ".br"},
	{"gzip", ".gz"},
}

// Serve sends name from files, compressed when the build has it so and the
// browser takes it.
func Serve(w http.ResponseWriter, r *http.Request, files fs.FS, name string) {
	header := w.Header()
	header.Add("Vary", "Accept-Encoding")
	for _, encoding := range encodings {
		if !Accepts(r.Header.Get("Accept-Encoding"), encoding.name) ||
			!IsFile(files, name+encoding.suffix) {
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
		http.ServeFileFS(w, r, files, name+encoding.suffix)
		return
	}
	http.ServeFileFS(w, r, files, name)
}

// Accepts reports whether an Accept-Encoding header takes coding, at a
// quality above zero.
func Accepts(header, coding string) bool {
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

// IsFile reports whether name is a regular file in files.
func IsFile(files fs.FS, name string) bool {
	info, err := fs.Stat(files, name)
	return err == nil && info.Mode().IsRegular()
}
