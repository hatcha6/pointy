package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestCardsWebHostsMayCallTheCustomerRoutes(t *testing.T) {
	cases := []struct{ origins, want string }{
		{"", "https://cards.dftr.ly"},
		{"http://localhost:8093", "http://localhost:8093,https://cards.dftr.ly"},
		{"https://cards.dftr.ly/", "https://cards.dftr.ly/"},
	}
	for _, c := range cases {
		if got := withCardsWebOrigins(c.origins, []string{"Cards.dftr.ly"}); got != c.want {
			t.Fatalf("%q: got %q, want %q", c.origins, got, c.want)
		}
	}
	if got := withCardsWebOrigins("https://a.example", nil); got != "https://a.example" {
		t.Fatalf("no hosts changed the origins: %q", got)
	}
}

func TestCardsWebServesTheBuildOnItsHostOnly(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	relay := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "relay") })

	same, err := buildCardsWeb(relay, nil, "/nowhere", logger)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	same.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "http://cards.dftr.ly/", nil))
	if recorder.Body.String() != "relay" {
		t.Fatal("served a web app nobody asked for")
	}

	if _, err := buildCardsWeb(relay, []string{"cards.dftr.ly"}, t.TempDir(), logger); err == nil {
		t.Fatal("started without a web build")
	}

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("cards"), 0o644); err != nil {
		t.Fatal(err)
	}
	handler, err := buildCardsWeb(relay, []string{"cards.dftr.ly"}, dir, logger)
	if err != nil {
		t.Fatal(err)
	}
	for host, want := range map[string]string{"cards.dftr.ly": "cards", "my.dftr.ly": "relay"} {
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "http://"+host+"/brand/pubg", nil))
		if recorder.Body.String() != want {
			t.Fatalf("%s: %q", host, recorder.Body.String())
		}
	}
}
