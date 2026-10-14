package moamalat

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestClassifyOnlyTheDeathCodeIsDeath(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   Outcome
	}{
		{"accepted", 200, `{"listOfMerchant":[],"oprationstate":"1"}`, Alive},
		{"accepted without state", 200, `{"listOfMerchant":[]}`, Alive},
		{"dead", 401, `{"oprationstate": "6"}`, Dead},
		{"dead as a number", 401, `{"oprationstate": 6}`, Dead},
		{"dead inside data", 401, `{"data":{"oprationstate":"6"}}`, Dead},
		{"401 without the code", 401, `{"msg":"nope"}`, Transient},
		{"cloudflare challenge", 403, `<!DOCTYPE html><title>Just a moment...</title>`, Transient},
		{"cloudflare 200 page", 200, `<html>checking your browser</html>`, Transient},
		{"server error", 502, `{"oprationstate":"0"}`, Transient},
		{"6 on a 200 is neither", 200, `{"oprationstate":"6"}`, Transient},
	}
	for _, c := range cases {
		if got := Classify(c.status, http.Header{}, []byte(c.body)).Outcome; got != c.want {
			t.Errorf("%s: got %s, want %s", c.name, got, c.want)
		}
	}
	throttled := Classify(429, http.Header{"Retry-After": {"90"}}, []byte(`{}`))
	if throttled.Outcome != Transient || throttled.RetryAfter != 90*time.Second {
		t.Fatalf("429: %+v", throttled)
	}
}

func TestPokeSendsTheBearerToTheMerchantList(t *testing.T) {
	var gotAuth, gotPath string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotPath = r.Header.Get("Authorization"), r.URL.Path
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"listOfMerchant":[{"outlet_number":"1"}]}`))
	}))
	defer server.Close()
	result := (&Client{BaseURL: server.URL + "/api"}).Poke(context.Background(), "a.b.c")
	if result.Outcome != Alive || gotAuth != "Bearer a.b.c" || gotPath != "/api/get-merchant/dest" {
		t.Fatalf("poke %+v auth %q path %q", result, gotAuth, gotPath)
	}
	server.Close()
	if down := (&Client{BaseURL: server.URL}).Poke(context.Background(), "a.b.c"); down.Outcome != Transient || strings.Contains(down.Detail, "a.b.c") {
		t.Fatalf("a closed server is transient and never echoes the token: %+v", down)
	}
}

func TestCadenceKeepsThreeTriesInsideTheWindow(t *testing.T) {
	if got := NextAfterSuccess(0); got != Tick {
		t.Fatalf("tick %s", got)
	}
	if got := NextAfterSuccess(1); got != Tick+TickJitter {
		t.Fatalf("jitter %s", got)
	}
	// The ladder after a missed tick at 4 minutes.
	if got := NextAfterFailure(4*time.Minute, 1, 0); got != 20*time.Second {
		t.Fatalf("first retry %s", got)
	}
	if got := NextAfterFailure(5*time.Minute, 2, 0); got != 60*time.Second {
		t.Fatalf("second retry %s", got)
	}
	// The third rung would overshoot the at-risk mark: it stops there.
	if got := NextAfterFailure(7*time.Minute, 3, 0); got != time.Minute {
		t.Fatalf("third retry clipped to the at-risk mark, got %s", got)
	}
	if got := NextAfterFailure(9*time.Minute, 9, 0); got != AtRiskRetry {
		t.Fatalf("at risk %s", got)
	}
	if got := NextAfterFailure(20*time.Minute, 30, 0); got != LapsedRetry {
		t.Fatalf("lapsed %s", got)
	}
	// A long Retry-After is honoured only up to the window.
	if got := NextAfterFailure(5*time.Minute, 1, time.Hour); 5*time.Minute+got > Window {
		t.Fatalf("429 pushed the next try past the window: %s", got)
	}
	if got := NextAfterFailure(time.Minute, 1, 2*time.Minute); got != 2*time.Minute {
		t.Fatalf("a short Retry-After is honoured, got %s", got)
	}
}

func TestSealIsBoundToTheShopAndMerchant(t *testing.T) {
	key := make([]byte, KeyBytes)
	for i := range key {
		key[i] = byte(i)
	}
	sealer, err := NewSealer(key)
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := sealer.Seal("inst-1", "MID-1", "h.p.s")
	if err != nil || strings.Contains(sealed, "h.p.s") {
		t.Fatalf("sealed %q %v", sealed, err)
	}
	if plain, err := sealer.Open("inst-1", "MID-1", sealed); err != nil || plain != "h.p.s" {
		t.Fatalf("open %q %v", plain, err)
	}
	if _, err := sealer.Open("inst-2", "MID-1", sealed); err != ErrSealUnreadable {
		t.Fatalf("another shop's row must not open it: %v", err)
	}
	other, _ := NewSealer(make([]byte, KeyBytes))
	if _, err := other.Open("inst-1", "MID-1", sealed); err != ErrSealUnreadable {
		t.Fatalf("another key must not open it: %v", err)
	}
	if _, err := ParseKey("short"); err == nil {
		t.Fatal("a short key is refused")
	}
	generated, _ := GenerateKey()
	if _, err := ParseKey(generated); err != nil {
		t.Fatal(err)
	}
}
