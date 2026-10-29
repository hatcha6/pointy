package appweb

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"testing/fstest"
)

func newHandler(t *testing.T) (*Handler, *[]*http.Request) {
	t.Helper()
	var relayed []*http.Request
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		relayed = append(relayed, r)
		w.WriteHeader(http.StatusTeapot)
	})
	handler, err := Wrap(next, Config{
		Hosts: []string{"app.dftr.ly"},
		Files: fstest.MapFS{
			"index.html":                   {Data: []byte("<html>app</html>")},
			"main.0123456789ab.dart.js":    {Data: []byte("code")},
			"main.0123456789ab.dart.js.br": {Data: []byte("brotli")},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return handler, &relayed
}

func get(handler http.Handler, host, path string, edit func(*http.Request)) *http.Response {
	request := httptest.NewRequest(http.MethodGet, "https://"+host+path, nil)
	if edit != nil {
		edit(request)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder.Result()
}

func TestServesTheBuildAndItsPages(t *testing.T) {
	handler, relayed := newHandler(t)
	for _, path := range []string{"/", "/sales/42"} {
		response := get(handler, "app.dftr.ly", path, nil)
		body, _ := io.ReadAll(response.Body)
		if response.StatusCode != http.StatusOK || string(body) != "<html>app</html>" {
			t.Fatalf("%s: expected index.html, got %d %q", path, response.StatusCode, body)
		}
		if response.Header.Get("Cache-Control") != "no-cache" || response.Header.Get("X-Frame-Options") != "DENY" {
			t.Fatalf("%s: unexpected headers %v", path, response.Header)
		}
	}
	code := get(handler, "app.dftr.ly", "/main.0123456789ab.dart.js", func(r *http.Request) {
		r.Header.Set("Accept-Encoding", "gzip, br")
	})
	body, _ := io.ReadAll(code.Body)
	if string(body) != "brotli" || code.Header.Get("Content-Encoding") != "br" {
		t.Fatalf("expected the brotli copy, got %q %v", body, code.Header)
	}
	if code.Header.Get("Cache-Control") != "public, max-age=31536000, immutable" {
		t.Fatalf("fingerprinted file should be kept for good, got %q", code.Header.Get("Cache-Control"))
	}
	if missing := get(handler, "app.dftr.ly", "/nope.js", nil); missing.StatusCode != http.StatusNotFound {
		t.Fatalf("a missing file is a 404, got %d", missing.StatusCode)
	}
	if len(*relayed) != 0 {
		t.Fatalf("no build request should reach the relay")
	}
}

func TestRelayPathsGoOnWithTheAppsOwnOriginDropped(t *testing.T) {
	handler, relayed := newHandler(t)
	get(handler, "app.dftr.ly", "/api/auth/login/", func(r *http.Request) {
		r.Header.Set("Origin", "https://app.dftr.ly")
		r.Header.Set("Referer", "https://app.dftr.ly/")
	})
	get(handler, "app.dftr.ly", "/api/products/", func(r *http.Request) {
		r.Header.Set("Origin", "https://evil.example")
	})
	get(handler, "app.dftr.ly", "/v1/relay-ticket-refresh", nil)
	if len(*relayed) != 3 {
		t.Fatalf("expected 3 relayed requests, got %d", len(*relayed))
	}
	if got := (*relayed)[0].Header.Get("Origin") + (*relayed)[0].Header.Get("Referer"); got != "" {
		t.Fatalf("the app's own origin should be dropped, got %q", got)
	}
	if got := (*relayed)[1].Header.Get("Origin"); got != "https://evil.example" {
		t.Fatalf("a foreign origin must pass untouched for the backend to refuse, got %q", got)
	}
}

func TestOtherHostsReachTheRelay(t *testing.T) {
	handler, relayed := newHandler(t)
	if response := get(handler, "my.dftr.ly", "/", nil); response.StatusCode != http.StatusTeapot {
		t.Fatalf("expected the relay, got %d", response.StatusCode)
	}
	if len(*relayed) != 1 {
		t.Fatalf("expected the request at the relay")
	}
}
