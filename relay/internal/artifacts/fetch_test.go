package artifacts

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

var fakeBundle = []byte("PK\x03\x04fake-bundle-bytes")

func serveBytes(t *testing.T, content []byte) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer asset-token" {
			http.Error(w, "nope", http.StatusNotFound)
			return
		}
		_, _ = w.Write(content)
	}))
	t.Cleanup(server.Close)
	return server
}

func waitFetch(t *testing.T, store *Store, version string) FetchStatus {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		status, err := store.FetchStatus(version)
		if err != nil {
			t.Fatal(err)
		}
		if status.State != FetchRunning {
			return status
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("fetch did not finish")
	return FetchStatus{}
}

func TestFetchPublishesVerifiedBundle(t *testing.T) {
	store, _ := New(t.TempDir())
	server := serveBytes(t, fakeBundle)
	sum := sha256.Sum256(fakeBundle)

	started, err := store.Fetch("1.4.0", FetchRequest{
		URL:     server.URL + "/pointy-onprem-1.4.0.zip?X-Signature=secret",
		SHA256:  "sha256:" + strings.ToUpper(hex.EncodeToString(sum[:])),
		Headers: map[string]string{"Authorization": "Bearer asset-token"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(started.URL, "secret") {
		t.Fatalf("status leaks the signed query: %q", started.URL)
	}
	status := waitFetch(t, store, "1.4.0")
	if status.State != FetchDone || status.Artifact == nil {
		t.Fatalf("status = %+v", status)
	}
	if status.Artifact.SHA256 != hex.EncodeToString(sum[:]) || status.BytesReceived != int64(len(fakeBundle)) {
		t.Fatalf("status = %+v", status)
	}
	if !store.Has("1.4.0") {
		t.Fatal("fetched bundle should be published")
	}
}

func TestFetchFailuresPublishNothing(t *testing.T) {
	cases := map[string]struct {
		content []byte
		sha     string
		headers map[string]string
		want    string
	}{
		"checksum mismatch": {fakeBundle, strings.Repeat("0", 64), map[string]string{"Authorization": "Bearer asset-token"}, "sha256 mismatch"},
		"web page not zip":  {[]byte("<html>login</html>"), "", map[string]string{"Authorization": "Bearer asset-token"}, "not a zip"},
		"http error":        {fakeBundle, "", nil, "HTTP 404"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			store, _ := New(t.TempDir())
			server := serveBytes(t, tc.content)
			if _, err := store.Fetch("1.4.0", FetchRequest{URL: server.URL, SHA256: tc.sha, Headers: tc.headers}); err != nil {
				t.Fatal(err)
			}
			status := waitFetch(t, store, "1.4.0")
			if status.State != FetchFailed || !strings.Contains(status.Error, tc.want) {
				t.Fatalf("status = %+v, want error containing %q", status, tc.want)
			}
			if store.Has("1.4.0") {
				t.Fatal("a failed fetch must not publish a bundle")
			}
			if metas, _ := store.List(); len(metas) != 0 {
				t.Fatalf("a failed fetch left artifacts behind: %+v", metas)
			}
			if _, err := os.Stat(filepath.Join(store.dir, "1.4.0")); !os.IsNotExist(err) {
				t.Fatalf("a failed fetch left its version dir behind (err=%v)", err)
			}
		})
	}
}

func TestFetchRejectsBadInputAndConcurrentFetch(t *testing.T) {
	store, _ := New(t.TempDir())
	for _, bad := range []FetchRequest{
		{URL: "file:///etc/passwd"},
		{URL: "relative/path.zip"},
		{URL: "https://host/x.zip", SHA256: "abc"},
	} {
		if _, err := store.Fetch("1.4.0", bad); err == nil {
			t.Fatalf("Fetch(%+v) should fail", bad)
		}
	}
	if _, err := store.FetchStatus("1.4.0"); !errors.Is(err, ErrNoFetch) {
		t.Fatalf("FetchStatus err = %v, want ErrNoFetch", err)
	}

	release := make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-release
		_, _ = w.Write(fakeBundle)
	}))
	defer slow.Close()
	if _, err := store.Fetch("1.4.0", FetchRequest{URL: slow.URL}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Fetch("1.4.0", FetchRequest{URL: slow.URL}); !errors.Is(err, ErrFetchInProgress) {
		t.Fatalf("second fetch err = %v, want ErrFetchInProgress", err)
	}
	close(release)
	if status := waitFetch(t, store, "1.4.0"); status.State != FetchDone {
		t.Fatalf("status = %+v", status)
	}
}

// fastRetries shrinks the stall watchdog and backoff so resume paths run in
// milliseconds.
func fastRetries(t *testing.T) {
	t.Helper()
	stall, delay, maxDelay := fetchStallTimeout, fetchRetryDelay, fetchMaxRetryDelay
	fetchStallTimeout, fetchRetryDelay, fetchMaxRetryDelay = 100*time.Millisecond, time.Millisecond, 5*time.Millisecond
	t.Cleanup(func() { fetchStallTimeout, fetchRetryDelay, fetchMaxRetryDelay = stall, delay, maxDelay })
}

// freezingServer serves content with Range support but sends at most perConn
// bytes on each connection and then goes silent with the socket still open —
// the relay egress's behaviour that froze every GitHub fetch at ~128 MB.
func freezingServer(t *testing.T, content []byte, perConn int, honorRange bool) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("ETag", `"v1"`)
		start := 0
		if spec, ok := strings.CutPrefix(r.Header.Get("Range"), "bytes="); ok && honorRange {
			if r.Header.Get("If-Range") != `"v1"` {
				t.Errorf("resume sent If-Range %q", r.Header.Get("If-Range"))
			}
			start, _ = strconv.Atoi(strings.TrimSuffix(spec, "-"))
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, len(content)-1, len(content)))
			w.Header().Set("Content-Length", strconv.Itoa(len(content)-start))
			w.WriteHeader(http.StatusPartialContent)
		} else {
			w.Header().Set("Content-Length", strconv.Itoa(len(content)))
		}
		end := min(start+perConn, len(content))
		_, _ = w.Write(content[start:end])
		w.(http.Flusher).Flush()
		if end < len(content) {
			<-r.Context().Done() // frozen: no bytes, no close
		}
	}))
	t.Cleanup(server.Close)
	return server, &requests
}

func bigBundle() []byte {
	content := make([]byte, 64<<10)
	copy(content, zipMagic)
	for i := len(zipMagic); i < len(content); i++ {
		content[i] = byte(i * 7)
	}
	return content
}

func TestFetchResumesAFrozenDownload(t *testing.T) {
	fastRetries(t)
	content := bigBundle()
	sum := sha256.Sum256(content)
	server, requests := freezingServer(t, content, 10_000, true)
	store, _ := New(t.TempDir())

	if _, err := store.Fetch("1.4.0", FetchRequest{URL: server.URL, SHA256: hex.EncodeToString(sum[:])}); err != nil {
		t.Fatal(err)
	}
	status := waitFetch(t, store, "1.4.0")
	if status.State != FetchDone || status.Artifact == nil || status.Artifact.SHA256 != hex.EncodeToString(sum[:]) {
		t.Fatalf("status = %+v", status)
	}
	if status.BytesReceived != int64(len(content)) || status.BytesTotal != int64(len(content)) {
		t.Fatalf("progress = %d/%d, want %d", status.BytesReceived, status.BytesTotal, len(content))
	}
	if got := requests.Load(); got != 7 || status.Retries != 6 {
		t.Fatalf("requests = %d, retries = %d; want 7 connections of 10 KB", got, status.Retries)
	}
	if !strings.Contains(status.RetryReason, "no data received") {
		t.Fatalf("retry reason = %q", status.RetryReason)
	}
}

func TestFetchGivesUpWhenNoAttemptMakesProgress(t *testing.T) {
	fastRetries(t)
	content := bigBundle()
	// Ignoring Range means every attempt restarts at zero and freezes at the same
	// spot: bytes arrive each time, yet the download never gets further.
	server, requests := freezingServer(t, content, 10_000, false)
	store, _ := New(t.TempDir())

	if _, err := store.Fetch("1.4.0", FetchRequest{URL: server.URL}); err != nil {
		t.Fatal(err)
	}
	status := waitFetch(t, store, "1.4.0")
	if status.State != FetchFailed || !strings.Contains(status.Error, "no progress") {
		t.Fatalf("status = %+v", status)
	}
	if got := requests.Load(); got != fetchMaxIdleAttempts+1 {
		t.Fatalf("requests = %d, want %d", got, fetchMaxIdleAttempts+1)
	}
	if store.Has("1.4.0") {
		t.Fatal("an incomplete download must not publish a bundle")
	}
}

func TestFetchStartsOverWhenTheServerIgnoresRange(t *testing.T) {
	fastRetries(t)
	content := bigBundle()
	sum := sha256.Sum256(content)
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", strconv.Itoa(len(content)))
		if requests.Add(1) == 1 {
			_, _ = w.Write(content[:20_000])
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			return
		}
		_, _ = w.Write(content) // full 200 despite the Range header
	}))
	t.Cleanup(server.Close)
	store, _ := New(t.TempDir())

	if _, err := store.Fetch("1.4.0", FetchRequest{URL: server.URL, SHA256: hex.EncodeToString(sum[:])}); err != nil {
		t.Fatal(err)
	}
	status := waitFetch(t, store, "1.4.0")
	if status.State != FetchDone || status.Artifact.Size != int64(len(content)) || status.BytesReceived != int64(len(content)) {
		t.Fatalf("status = %+v", status)
	}
}

func TestFetchRetriesServerErrors(t *testing.T) {
	fastRetries(t)
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) < 3 {
			http.Error(w, "busy", http.StatusBadGateway)
			return
		}
		_, _ = w.Write(fakeBundle)
	}))
	t.Cleanup(server.Close)
	store, _ := New(t.TempDir())

	if _, err := store.Fetch("1.4.0", FetchRequest{URL: server.URL}); err != nil {
		t.Fatal(err)
	}
	if status := waitFetch(t, store, "1.4.0"); status.State != FetchDone || status.Retries != 2 {
		t.Fatalf("status = %+v", status)
	}
}

func TestFetchRefusesToSpliceAChangedFile(t *testing.T) {
	fastRetries(t)
	content := bigBundle()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") == "" {
			w.Header().Set("ETag", `"v1"`)
			w.Header().Set("Content-Length", strconv.Itoa(len(content)))
			_, _ = w.Write(content[:20_000])
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			return
		}
		// Re-uploaded meanwhile, and (like Azure) If-Range is ignored.
		w.Header().Set("ETag", `"v2"`)
		w.Header().Set("Content-Range", fmt.Sprintf("bytes 20000-%d/%d", len(content)-1, len(content)))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write(content[20_000:])
	}))
	t.Cleanup(server.Close)
	store, _ := New(t.TempDir())

	if _, err := store.Fetch("1.4.0", FetchRequest{URL: server.URL}); err != nil {
		t.Fatal(err)
	}
	status := waitFetch(t, store, "1.4.0")
	if status.State != FetchFailed || !strings.Contains(status.Error, "changed on the server") {
		t.Fatalf("status = %+v", status)
	}
	if store.Has("1.4.0") {
		t.Fatal("a spliced download must not publish a bundle")
	}
}
