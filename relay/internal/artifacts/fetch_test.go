package artifacts

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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
