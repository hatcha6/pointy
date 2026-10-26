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
