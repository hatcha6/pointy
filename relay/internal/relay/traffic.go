package relay

import (
	"net/http"
	"strings"
)

// countRequest counts r in the node's live traffic for the console's system
// view: every request the relay serves, on the node it reached first (one
// forwarded from another node is that node's). Probes and the system view's
// own polling are left out, so an idle relay reads zero.
func (s HTTPServer) countRequest(w http.ResponseWriter, r *http.Request, next http.HandlerFunc) {
	if !countsAsTraffic(r) {
		next(w, r)
		return
	}
	done := s.metrics().RequestStarted()
	recorder := &trafficRecorder{ResponseWriter: w}
	// A handler that panics leaves the status at 0, counted as failed.
	defer func() { done(recorder.status) }()
	next(recorder, r)
	if recorder.status == 0 {
		recorder.status = http.StatusOK
	}
}

func countsAsTraffic(r *http.Request) bool {
	if strings.TrimSpace(r.Header.Get(NodeProxyMarkerHeader)) != "" {
		return false
	}
	switch r.URL.Path {
	case "/healthz", "/readyz", "/v1/system", "/v1/metrics":
		return false
	}
	return true
}

// trafficRecorder notes the status a handler answered with.
type trafficRecorder struct {
	http.ResponseWriter
	status int
}

func (r *trafficRecorder) WriteHeader(status int) {
	if r.status == 0 && status >= http.StatusOK {
		r.status = status
	}
	r.ResponseWriter.WriteHeader(status)
}

func (r *trafficRecorder) Write(content []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	return r.ResponseWriter.Write(content)
}

// Flush keeps streamed answers (the AI chat's events) flowing.
func (r *trafficRecorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

// Unwrap lets http.ResponseController reach the connection underneath.
func (r *trafficRecorder) Unwrap() http.ResponseWriter {
	return r.ResponseWriter
}
