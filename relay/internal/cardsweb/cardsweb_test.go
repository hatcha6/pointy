package cardsweb

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func build() fstest.MapFS {
	return fstest.MapFS{
		"index.html":                             {Data: []byte("<!doctype html><title>دفتر كروت</title>")},
		"main.dart.js":                           {Data: []byte("main();")},
		"assets/fonts/x.otf":                     {Data: []byte("font")},
		".well-known/apple-app-site-association": {Data: []byte(`{"applinks":{}}`)},
		".well-known/assetlinks.json":            {Data: []byte(`[]`)},
	}
}

func handler(t *testing.T) *Handler {
	t.Helper()
	relay := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "relay")
	})
	h, err := Wrap(relay, Config{Hosts: []string{"cards.dftr.ly"}, Files: build()})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func get(h http.Handler, method, host, target string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, "http://"+host+target, nil)
	recorder := httptest.NewRecorder()
	h.ServeHTTP(recorder, request)
	return recorder
}

func TestEveryPageOfTheAppIsIndex(t *testing.T) {
	h := handler(t)
	for _, target := range []string{"/", "/brand/pubg?item=pubg-325", "/category/gaming", "/search?q=x", "/my-cards"} {
		got := get(h, http.MethodGet, "cards.dftr.ly", target)
		if got.Code != http.StatusOK || !strings.Contains(got.Body.String(), "دفتر كروت") {
			t.Fatalf("%s: %d %q", target, got.Code, got.Body.String())
		}
		if got.Header().Get("Cache-Control") != "no-cache" {
			t.Fatalf("%s: cache %q", target, got.Header().Get("Cache-Control"))
		}
	}
}

func TestFilesAreServedAndMissingOnesAreNotPages(t *testing.T) {
	h := handler(t)
	if got := get(h, http.MethodGet, "cards.dftr.ly", "/main.dart.js"); got.Body.String() != "main();" {
		t.Fatalf("main.dart.js: %d %q", got.Code, got.Body.String())
	}
	for _, target := range []string{"/missing.js", "/assets/nope.png", "/.well-known/other"} {
		if got := get(h, http.MethodGet, "cards.dftr.ly", target); got.Code != http.StatusNotFound {
			t.Fatalf("%s: %d", target, got.Code)
		}
	}
	// A directory is not listed: it is a page.
	if got := get(h, http.MethodGet, "cards.dftr.ly", "/assets"); !strings.Contains(got.Body.String(), "دفتر كروت") {
		t.Fatalf("/assets: %d %q", got.Code, got.Body.String())
	}
}

func TestTheLinkFilesGoOutAsJSON(t *testing.T) {
	h := handler(t)
	for _, target := range []string{"/.well-known/apple-app-site-association", "/.well-known/assetlinks.json"} {
		got := get(h, http.MethodGet, "cards.dftr.ly", target)
		if got.Code != http.StatusOK || !strings.HasPrefix(got.Header().Get("Content-Type"), "application/json") {
			t.Fatalf("%s: %d %q", target, got.Code, got.Header().Get("Content-Type"))
		}
	}
}

func TestOtherHostsAndPathTricksStayWithTheRelay(t *testing.T) {
	h := handler(t)
	if got := get(h, http.MethodGet, "my.dftr.ly", "/"); got.Body.String() != "relay" {
		t.Fatalf("my.dftr.ly went to the web app: %q", got.Body.String())
	}
	if got := get(h, http.MethodGet, "CARDS.dftr.ly:443", "/main.dart.js"); got.Body.String() != "main();" {
		t.Fatalf("host with port and case: %q", got.Body.String())
	}
	if got := get(h, http.MethodGet, "cards.dftr.ly", "/../../etc/passwd"); strings.Contains(got.Body.String(), "root:") {
		t.Fatal("escaped the build")
	}
	if got := get(h, http.MethodPost, "cards.dftr.ly", "/"); got.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST: %d", got.Code)
	}
}

func TestABuildWithoutIndexIsRefused(t *testing.T) {
	_, err := Wrap(http.NotFoundHandler(), Config{Hosts: []string{"cards.dftr.ly"}, Files: fstest.MapFS{}})
	if err == nil {
		t.Fatal("a build without index.html was accepted")
	}
	_, err = Wrap(http.NotFoundHandler(), Config{Hosts: []string{"https://cards.dftr.ly"}, Files: build()})
	if err == nil {
		t.Fatal("a URL was accepted as a host")
	}
}

func compressedBuild() fstest.MapFS {
	files := build()
	files["main.0123456789abcdef.dart.js"] = &fstest.MapFile{Data: []byte("main();")}
	files["main.0123456789abcdef.dart.js.br"] = &fstest.MapFile{Data: []byte("br-main")}
	files["main.0123456789abcdef.dart.js.gz"] = &fstest.MapFile{Data: []byte("gz-main")}
	files["index.html.gz"] = &fstest.MapFile{Data: []byte("gz-index")}
	files["canvaskit/skia.wasm"] = &fstest.MapFile{Data: []byte("wasm")}
	files["canvaskit/skia.wasm.br"] = &fstest.MapFile{Data: []byte("br-wasm")}
	return files
}

func getAccepting(h http.Handler, target, encoding string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodGet, "http://cards.dftr.ly"+target, nil)
	if encoding != "" {
		request.Header.Set("Accept-Encoding", encoding)
	}
	recorder := httptest.NewRecorder()
	h.ServeHTTP(recorder, request)
	return recorder
}

func TestTheSmallestCopyTheBrowserTakesIsSent(t *testing.T) {
	relay := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {})
	h, err := Wrap(relay, Config{Hosts: []string{"cards.dftr.ly"}, Files: compressedBuild()})
	if err != nil {
		t.Fatal(err)
	}
	const js = "/main.0123456789abcdef.dart.js"
	cases := []struct{ target, accept, body, encoding string }{
		{js, "gzip, deflate, br, zstd", "br-main", "br"},
		{js, "gzip", "gz-main", "gzip"},
		{js, "br;q=0, gzip;q=0.8", "gz-main", "gzip"},
		{js, "", "main();", ""},
		{js, "identity", "main();", ""},
		// A page is index.html, compressed too.
		{"/brand/pubg", "br, gzip", "gz-index", "gzip"},
		{"/canvaskit/skia.wasm", "br", "br-wasm", "br"},
	}
	for _, c := range cases {
		got := getAccepting(h, c.target, c.accept)
		if got.Code != http.StatusOK || got.Body.String() != c.body ||
			got.Header().Get("Content-Encoding") != c.encoding {
			t.Fatalf("%s %q: %d %q encoding %q", c.target, c.accept, got.Code,
				got.Body.String(), got.Header().Get("Content-Encoding"))
		}
		if got.Header().Get("Vary") != "Accept-Encoding" {
			t.Fatalf("%s: vary %q", c.target, got.Header().Get("Vary"))
		}
	}
	// The compressed copy keeps the original's type.
	if kind := getAccepting(h, js, "br").Header().Get("Content-Type"); !strings.Contains(kind, "javascript") {
		t.Fatalf("js type %q", kind)
	}
	if kind := getAccepting(h, "/canvaskit/skia.wasm", "br").Header().Get("Content-Type"); kind != "application/wasm" {
		t.Fatalf("wasm type %q", kind)
	}
	if kind := getAccepting(h, "/", "gzip").Header().Get("Content-Type"); !strings.HasPrefix(kind, "text/html") {
		t.Fatalf("page type %q", kind)
	}
}

func TestAFingerprintedFileIsKeptForGood(t *testing.T) {
	relay := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {})
	h, err := Wrap(relay, Config{Hosts: []string{"cards.dftr.ly"}, Files: compressedBuild()})
	if err != nil {
		t.Fatal(err)
	}
	if got := getAccepting(h, "/main.0123456789abcdef.dart.js", "br").Header().Get("Cache-Control"); got != "public, max-age=31536000, immutable" {
		t.Fatalf("fingerprinted cache %q", got)
	}
	for _, target := range []string{"/", "/main.dart.js", "/assets/fonts/x.otf"} {
		if got := getAccepting(h, target, "br").Header().Get("Cache-Control"); got != "no-cache" {
			t.Fatalf("%s cache %q", target, got)
		}
	}
}
