package artifacts

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"
)

// Fetch lets an operator on a slow line publish a bundle without pushing its
// bytes through that line: the relay downloads the zip from a URL (a GitHub
// release asset, any file host) on its own fast connection and publishes it
// exactly as if it had been uploaded. Downloads run in the background because
// a bundle is 1-2 GB and would outlive any proxy's request timeout; callers poll
// FetchStatus.

var (
	// ErrChecksumMismatch means the downloaded bytes are not the expected bundle.
	ErrChecksumMismatch = errors.New("sha256 mismatch")
	// ErrFetchInProgress means a download for that version is already running.
	ErrFetchInProgress = errors.New("a fetch for this version is already in progress")
	// ErrNoFetch means no download was started for that version since the relay started.
	ErrNoFetch = errors.New("no fetch for this version")
)

// Fetch states.
const (
	FetchRunning = "fetching"
	FetchDone    = "done"
	FetchFailed  = "failed"
)

// fetchTimeout bounds a whole download so a stalled host can't pin a version's
// fetch slot forever.
const fetchTimeout = 3 * time.Hour

// zipMagic is a zip's local-file-header signature. Checking it catches the
// common wrong-link failure: a share page or login form served as 200 HTML.
var zipMagic = []byte("PK\x03\x04")

// FetchRequest says where to download a bundle from.
type FetchRequest struct {
	URL string
	// SHA256 is optional; when set, a mismatching download is discarded.
	// Accepts a bare hex digest or GitHub's "sha256:<hex>" form.
	SHA256 string
	// Headers are sent with the download (e.g. Authorization for a private
	// GitHub release asset). They are never stored or echoed back, and Go's
	// client drops Authorization when a redirect leaves the original host.
	Headers map[string]string
}

// FetchStatus is a snapshot of a background download.
type FetchStatus struct {
	Version       string     `json:"version"`
	URL           string     `json:"url"`
	State         string     `json:"state"`
	BytesReceived int64      `json:"bytes_received"`
	BytesTotal    int64      `json:"bytes_total"`
	Error         string     `json:"error,omitempty"`
	StartedAt     time.Time  `json:"started_at"`
	FinishedAt    *time.Time `json:"finished_at,omitempty"`
	Artifact      *Meta      `json:"artifact,omitempty"`
}

type fetchJob struct {
	received atomic.Int64
	status   FetchStatus // guarded by Store.mu
}

// Fetch validates req and starts downloading it into version in the
// background. It returns the initial status; poll FetchStatus for progress.
func (s *Store) Fetch(version string, req FetchRequest) (FetchStatus, error) {
	clean, err := safeVersion(version)
	if err != nil {
		return FetchStatus{}, err
	}
	source, err := parseFetchURL(req.URL)
	if err != nil {
		return FetchStatus{}, err
	}
	expected, err := normalizeSHA256(req.SHA256)
	if err != nil {
		return FetchStatus{}, err
	}

	s.mu.Lock()
	if s.fetches == nil {
		s.fetches = map[string]*fetchJob{}
	}
	if existing, ok := s.fetches[clean]; ok && existing.status.State == FetchRunning {
		s.mu.Unlock()
		return FetchStatus{}, ErrFetchInProgress
	}
	job := &fetchJob{status: FetchStatus{
		Version:    clean,
		URL:        redactURL(source),
		State:      FetchRunning,
		BytesTotal: -1,
		StartedAt:  time.Now().UTC(),
	}}
	s.fetches[clean] = job
	snapshot := job.snapshot()
	s.mu.Unlock()

	go s.runFetch(job, clean, source.String(), expected, req.Headers)
	return snapshot, nil
}

// FetchStatus reports the latest download for version since the relay started.
func (s *Store) FetchStatus(version string) (FetchStatus, error) {
	clean, err := safeVersion(version)
	if err != nil {
		return FetchStatus{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	job, ok := s.fetches[clean]
	if !ok {
		return FetchStatus{}, ErrNoFetch
	}
	return job.snapshot(), nil
}

func (j *fetchJob) snapshot() FetchStatus {
	status := j.status
	status.BytesReceived = j.received.Load()
	return status
}

func (s *Store) runFetch(job *fetchJob, version, source, expected string, headers map[string]string) {
	meta, err := s.download(job, version, source, expected, headers)

	s.mu.Lock()
	defer s.mu.Unlock()
	finished := time.Now().UTC()
	job.status.FinishedAt = &finished
	if err != nil {
		job.status.State = FetchFailed
		job.status.Error = err.Error()
		return
	}
	job.status.State = FetchDone
	job.status.Artifact = &meta
}

func (s *Store) download(job *fetchJob, version, source, expected string, headers map[string]string) (Meta, error) {
	ctx, cancel := context.WithTimeout(context.Background(), fetchTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return Meta{}, err
	}
	// GitHub's release-asset API returns the bytes only for octet-stream.
	request.Header.Set("Accept", "application/octet-stream")
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response, err := s.fetchClient().Do(request)
	if err != nil {
		return Meta{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return Meta{}, fmt.Errorf("download returned HTTP %d", response.StatusCode)
	}
	if response.ContentLength >= 0 {
		s.mu.Lock()
		job.status.BytesTotal = response.ContentLength
		s.mu.Unlock()
	}

	body := bufio.NewReaderSize(&countingReader{r: response.Body, n: &job.received}, 64<<10)
	head, err := body.Peek(len(zipMagic))
	if err != nil || !bytes.Equal(head, zipMagic) {
		return Meta{}, errors.New("download is not a zip file (check the URL points at the bundle itself, not a web page)")
	}
	return s.put(version, body, expected)
}

func (s *Store) fetchClient() *http.Client {
	if s.FetchClient != nil {
		return s.FetchClient
	}
	return &http.Client{Transport: &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           (&net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		TLSHandshakeTimeout:   30 * time.Second,
		ResponseHeaderTimeout: 2 * time.Minute,
	}}
}

type countingReader struct {
	r io.Reader
	n *atomic.Int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n.Add(int64(n))
	return n, err
}

func parseFetchURL(raw string) (*url.URL, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Host == "" {
		return nil, errors.New("url must be an absolute http(s) URL")
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return nil, errors.New("url must be an absolute http(s) URL")
	}
	return parsed, nil
}

// redactURL drops credentials and the query (signed URLs carry their secret
// there) so the status is safe to show.
func redactURL(u *url.URL) string {
	return (&url.URL{Scheme: u.Scheme, Host: u.Host, Path: u.Path}).String()
}

func normalizeSHA256(value string) (string, error) {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.TrimPrefix(value, "sha256:")
	if value == "" {
		return "", nil
	}
	if len(value) != 64 || strings.Trim(value, "0123456789abcdef") != "" {
		return "", errors.New("sha256 must be 64 hex characters")
	}
	return value, nil
}
