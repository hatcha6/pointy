package relay

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAdminArtifactFetchPublishesForRollout(t *testing.T) {
	server, _, art := newUpdateTestServer(t)
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("PK\x03\x04bundle-bytes"))
	}))
	defer host.Close()

	admin := func(method, path, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, "http://relay"+path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer admin-token")
		rec := httptest.NewRecorder()
		server.ServeHTTP(rec, req)
		return rec
	}

	unauth := httptest.NewRequest(http.MethodPost, "http://relay/v1/artifacts/1.5.0/fetch", strings.NewReader(`{}`))
	unauthRec := httptest.NewRecorder()
	server.ServeHTTP(unauthRec, unauth)
	if unauthRec.Code != http.StatusUnauthorized {
		t.Fatalf("fetch without admin token: %d", unauthRec.Code)
	}
	if rec := admin(http.MethodPost, "/v1/artifacts/1.5.0/fetch", `{"url":"ftp://x/y.zip"}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad url status %d: %s", rec.Code, rec.Body.String())
	}
	if rec := admin(http.MethodGet, "/v1/artifacts/1.5.0/fetch", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("status before any fetch: %d", rec.Code)
	}

	if rec := admin(http.MethodPost, "/v1/artifacts/1.5.0/fetch", `{"url":"`+host.URL+`/b.zip"}`); rec.Code != http.StatusAccepted {
		t.Fatalf("fetch status %d: %s", rec.Code, rec.Body.String())
	}
	var status struct {
		State string `json:"state"`
	}
	deadline := time.Now().Add(5 * time.Second)
	for status.State != "done" {
		if time.Now().After(deadline) {
			t.Fatalf("fetch never finished: %+v", status)
		}
		rec := admin(http.MethodGet, "/v1/artifacts/1.5.0/fetch", "")
		if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
			t.Fatal(err)
		}
		if status.State == "failed" {
			t.Fatalf("fetch failed: %s", rec.Body.String())
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !art.Has("1.5.0") {
		t.Fatal("fetched bundle should be published")
	}
	// Exactly as if it had been uploaded: the channel target now accepts it.
	if rec := admin(http.MethodPut, "/v1/fleet/channels/stable", `{"target_version":"1.5.0","rollout_phase":"all"}`); rec.Code != http.StatusOK {
		t.Fatalf("set channel target status %d: %s", rec.Code, rec.Body.String())
	}
}
