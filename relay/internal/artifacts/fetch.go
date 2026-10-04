package artifacts

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"hash"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
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

// fetchMaxIdleAttempts is how many attempts in a row may add no bytes before a
// download gives up; an attempt that makes any progress resets the count.
const fetchMaxIdleAttempts = 6

// Variables so tests can run the resume path in milliseconds.
var (
	// fetchStallTimeout drops a connection that has delivered nothing for this
	// long, so the next attempt can resume instead of waiting on the kernel.
	fetchStallTimeout = time.Minute
	// fetchRetryDelay is the first pause between attempts; it doubles with each
	// attempt that makes no progress, up to fetchMaxRetryDelay.
	fetchRetryDelay    = 2 * time.Second
	fetchMaxRetryDelay = 30 * time.Second
)

var errFetchStalled = errors.New("no data received")

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
	Version       string `json:"version"`
	URL           string `json:"url"`
	State         string `json:"state"`
	BytesReceived int64  `json:"bytes_received"`
	BytesTotal    int64  `json:"bytes_total"`
	// Retries counts resumed connections; RetryReason is why the last one dropped.
	Retries     int        `json:"retries,omitempty"`
	RetryReason string     `json:"retry_reason,omitempty"`
	Error       string     `json:"error,omitempty"`
	StartedAt   time.Time  `json:"started_at"`
	FinishedAt  *time.Time `json:"finished_at,omitempty"`
	Artifact    *Meta      `json:"artifact,omitempty"`
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
	return s.write(version, expected, func(tmp *os.File, hasher hash.Hash) (int64, error) {
		d := &resumableDownload{
			store: s, job: job, source: source, headers: headers,
			file: tmp, hasher: hasher, total: -1,
		}
		return d.run(ctx)
	})
}

// resumableDownload streams one bundle into the store's temp file across as
// many connections as it takes. The relay's egress has been seen to freeze a
// GitHub download at the same ~128 MB on every try, the socket left open until
// the kernel gave up minutes later; so each attempt is watched for stalls and
// the next one asks only for the rest with a Range request.
type resumableDownload struct {
	store   *Store
	job     *fetchJob
	source  string
	headers map[string]string
	file    *os.File
	hasher  hash.Hash

	written   int64  // bytes on disk, which are exactly the bytes hashed
	total     int64  // -1 until a full response gives a length
	validator string // the first response's ETag or Last-Modified, sent as If-Range
}

func (d *resumableDownload) run(ctx context.Context) (int64, error) {
	// Progress is the furthest point reached, not bytes received: a server
	// that ignores Range restarts from zero and must not count as advancing.
	idle, furthest := 0, int64(0)
	for {
		err := d.attempt(ctx)
		if err == nil {
			return d.written, nil
		}
		var final *permanentError
		if errors.As(err, &final) {
			return d.written, final.err
		}
		if ctx.Err() != nil {
			return d.written, err
		}
		if d.written > furthest {
			idle, furthest = 0, d.written
		} else {
			idle++
		}
		if idle >= fetchMaxIdleAttempts {
			return d.written, fmt.Errorf("gave up after %d attempts with no progress at %s: %w",
				idle, formatMB(d.written), err)
		}
		d.store.noteFetchRetry(d.job, err)
		select {
		case <-ctx.Done():
			return d.written, err
		case <-time.After(fetchBackoff(idle)):
		}
	}
}

// attempt makes one request for whatever is still missing. Errors wrapped in
// permanentError end the download; any other error is a dropped or stalled
// connection worth resuming.
func (d *resumableDownload) attempt(parent context.Context) error {
	ctx, cancel := context.WithCancelCause(parent)
	defer cancel(nil)
	stall := time.AfterFunc(fetchStallTimeout, func() { cancel(errFetchStalled) })
	defer stall.Stop()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, d.source, nil)
	if err != nil {
		return permanent(err)
	}
	// GitHub's release-asset API returns the bytes only for octet-stream.
	request.Header.Set("Accept", "application/octet-stream")
	for name, value := range d.headers {
		request.Header.Set(name, value)
	}
	resuming := d.written > 0
	if resuming {
		request.Header.Set("Range", fmt.Sprintf("bytes=%d-", d.written))
		if d.validator != "" {
			request.Header.Set("If-Range", d.validator)
		}
	}
	// The original URL is requested every time: GitHub answers it with a fresh
	// signed CDN redirect, so a long download never trips the link's expiry.
	response, err := d.store.fetchClient().Do(request)
	if err != nil {
		return stalledOr(ctx, err)
	}
	defer response.Body.Close()

	switch status := response.StatusCode; {
	case resuming && status == http.StatusPartialContent:
		start, total, ok := parseContentRange(response.Header.Get("Content-Range"))
		if !ok || start != d.written {
			return permanent(fmt.Errorf("server resumed at the wrong offset (Content-Range %q, want %d)",
				response.Header.Get("Content-Range"), d.written))
		}
		// GitHub's CDN (Azure Blob) ignores If-Range, so check the file is the
		// one the first connection started rather than splicing two versions.
		validator := rangeValidator(response.Header)
		if (total >= 0 && d.total >= 0 && total != d.total) ||
			(validator != "" && d.validator != "" && validator != d.validator) {
			return permanent(errors.New("the bundle changed on the server mid-download; run the command again"))
		}
	case status == http.StatusOK:
		// On a resume this means the server ignored the range or the file
		// changed under If-Range; either way only a fresh start is correct.
		if resuming {
			if err := d.restart(); err != nil {
				return permanent(err)
			}
		}
		d.total = response.ContentLength
		d.validator = rangeValidator(response.Header)
		d.store.setFetchTotal(d.job, d.total)
	case resuming && status == http.StatusRequestedRangeNotSatisfiable && d.written == d.total:
		return nil
	default:
		err := fmt.Errorf("download returned HTTP %d", status)
		if retryableStatus(status) {
			return err
		}
		return permanent(err)
	}

	var body io.Reader = response.Body
	if d.written == 0 {
		buffered := bufio.NewReaderSize(response.Body, 64<<10)
		head, err := buffered.Peek(len(zipMagic))
		if (len(head) == len(zipMagic) && !bytes.Equal(head, zipMagic)) || errors.Is(err, io.EOF) {
			return permanent(errors.New("download is not a zip file (check the URL points at the bundle itself, not a web page)"))
		}
		if err != nil {
			return stalledOr(ctx, err)
		}
		body = buffered
	}

	sink := &progressWriter{file: d.file, hasher: d.hasher, received: &d.job.received, stall: stall}
	n, err := io.Copy(sink, body)
	d.written += n
	if sink.err != nil {
		return permanent(sink.err) // the disk failed, not the network
	}
	if err != nil {
		return stalledOr(ctx, err)
	}
	if d.total >= 0 && d.written < d.total {
		return fmt.Errorf("connection closed at %s of %s", formatMB(d.written), formatMB(d.total))
	}
	return nil
}

// restart discards what was downloaded so far.
func (d *resumableDownload) restart() error {
	if _, err := d.file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	if err := d.file.Truncate(0); err != nil {
		return err
	}
	d.hasher.Reset()
	d.written = 0
	d.job.received.Store(0)
	return nil
}

func (s *Store) setFetchTotal(job *fetchJob, total int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	job.status.BytesTotal = total
}

func (s *Store) noteFetchRetry(job *fetchJob, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	job.status.Retries++
	job.status.RetryReason = err.Error()
}

// progressWriter writes to the temp file and hasher together, publishes
// progress, and holds off the stall timer while bytes keep arriving.
type progressWriter struct {
	file     *os.File
	hasher   hash.Hash
	received *atomic.Int64
	stall    *time.Timer
	err      error
}

func (w *progressWriter) Write(p []byte) (int, error) {
	n, err := w.file.Write(p)
	w.hasher.Write(p[:n])
	w.received.Add(int64(n))
	w.stall.Reset(fetchStallTimeout)
	if err != nil {
		w.err = err
	}
	return n, err
}

type permanentError struct{ err error }

func (e *permanentError) Error() string { return e.err.Error() }
func (e *permanentError) Unwrap() error { return e.err }

func permanent(err error) error { return &permanentError{err: err} }

// stalledOr names a stall instead of the bare "context canceled" it surfaces as.
func stalledOr(ctx context.Context, err error) error {
	if errors.Is(context.Cause(ctx), errFetchStalled) {
		return fmt.Errorf("%w for %s", errFetchStalled, fetchStallTimeout)
	}
	return err
}

func fetchBackoff(idle int) time.Duration {
	delay := fetchRetryDelay
	for i := 1; i < idle && delay < fetchMaxRetryDelay; i++ {
		delay *= 2
	}
	return min(delay, fetchMaxRetryDelay)
}

func retryableStatus(status int) bool {
	return status == http.StatusRequestTimeout || status == http.StatusTooManyRequests || status >= 500
}

// rangeValidator picks what If-Range may carry: a strong ETag, else Last-Modified.
func rangeValidator(header http.Header) string {
	if etag := header.Get("ETag"); etag != "" && !strings.HasPrefix(etag, "W/") {
		return etag
	}
	return header.Get("Last-Modified")
}

// parseContentRange reads "bytes 100-199/200" as start 100, total 200; an
// unknown total ("/*") is -1.
func parseContentRange(value string) (start, total int64, ok bool) {
	rest, found := strings.CutPrefix(value, "bytes ")
	if !found {
		return 0, 0, false
	}
	span, size, found := strings.Cut(rest, "/")
	first, _, found2 := strings.Cut(span, "-")
	if !found || !found2 {
		return 0, 0, false
	}
	start, err := strconv.ParseInt(first, 10, 64)
	if err != nil {
		return 0, 0, false
	}
	if size == "*" {
		return start, -1, true
	}
	total, err = strconv.ParseInt(size, 10, 64)
	return start, total, err == nil
}

func formatMB(n int64) string {
	return fmt.Sprintf("%.0f MB", float64(n)/(1<<20))
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
