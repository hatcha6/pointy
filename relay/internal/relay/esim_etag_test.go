package relay

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// An app holding the shelf or a destination's plans is told "not modified"
// until something they are built from moves, and each answer has its own tag.
func TestESIMShelfAndDestinationsAnswerNotModified(t *testing.T) {
	h := newESIMHarness(t)
	ask := func(path, tag string) (int, string, int) {
		t.Helper()
		request := httptest.NewRequest(http.MethodGet, "http://relay.test"+path, nil)
		request.RemoteAddr = "203.0.113.9:4000"
		if tag != "" {
			request.Header.Set("If-None-Match", tag)
		}
		recorder := httptest.NewRecorder()
		h.server.ServeHTTP(recorder, request)
		return recorder.Code, recorder.Header().Get("ETag"), recorder.Body.Len()
	}
	tags := map[string]string{}
	for _, path := range []string{
		"/v1/customers/esim/destinations",
		"/v1/customers/esim/destinations/turkey",
		"/v1/customers/esim/destinations/europe",
	} {
		status, tag, size := ask(path, "")
		if status != http.StatusOK || tag == "" || size == 0 {
			t.Fatalf("%s: %d tag %q, %d bytes", path, status, tag, size)
		}
		for other, seen := range tags {
			if seen == tag {
				t.Fatalf("%s and %s share the tag %s", path, other, tag)
			}
		}
		tags[path] = tag
		if status, again, size := ask(path, tag); status != http.StatusNotModified || again != tag || size != 0 {
			t.Fatalf("%s asked again: %d tag %q, %d bytes", path, status, again, size)
		}
	}
	// One route's tag is no answer to another's.
	if status, _, _ := ask("/v1/customers/esim/destinations/turkey", tags["/v1/customers/esim/destinations/europe"]); status != http.StatusOK {
		t.Fatalf("another destination's tag: %d", status)
	}
	// A destination that is not sold is still "not found", tag or no tag.
	if status, _, _ := ask("/v1/customers/esim/destinations/atlantis", tags["/v1/customers/esim/destinations/turkey"]); status != http.StatusNotFound {
		t.Fatalf("unknown destination: %d", status)
	}
	// The dollar moved: every price did, so every answer is sent again.
	h.cards.setRate(t, "8.25")
	for path, tag := range tags {
		if status, moved, _ := ask(path, tag); status != http.StatusOK || moved == tag {
			t.Fatalf("%s after the rate moved: %d tag %q (was %q)", path, status, moved, tag)
		}
	}
}
