package relay

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"

	"pointy/relay/internal/webbuild"
)

// The card app's customers are often on slow mobile data: an answer that is
// sent compressed is the difference between a shelf that opens and one that
// times out (the catalog is ~1.9 MB of JSON and ~0.2 MB gzipped). Every JSON
// answer of /v1/customers/* is gzipped for a caller that takes gzip; an
// answer under gzipMinBytes, or one already encoded, goes as it is.
const gzipMinBytes = 1024

var gzipWriters = sync.Pool{New: func() any {
	zw, _ := gzip.NewWriterLevel(nil, gzip.DefaultCompression)
	return zw
}}

// withCustomerGzip wraps w so JSON answers are gzipped when r takes gzip.
// The returned finish must run once the handler is done.
func withCustomerGzip(w http.ResponseWriter, r *http.Request) (http.ResponseWriter, func()) {
	if !webbuild.Accepts(r.Header.Get("Accept-Encoding"), "gzip") {
		return w, func() {}
	}
	gw := &gzipResponseWriter{ResponseWriter: w}
	return gw, gw.finish
}

type gzipResponseWriter struct {
	http.ResponseWriter
	zw      *gzip.Writer
	decided bool
}

func (g *gzipResponseWriter) WriteHeader(status int) {
	if !g.decided {
		g.decided = true
		g.decide(status)
	}
	g.ResponseWriter.WriteHeader(status)
}

func (g *gzipResponseWriter) decide(status int) {
	header := g.ResponseWriter.Header()
	if !strings.HasPrefix(header.Get("Content-Type"), "application/json") {
		return
	}
	addVary(header, "Accept-Encoding")
	if status < 200 || status == http.StatusNoContent || status == http.StatusNotModified ||
		header.Get("Content-Encoding") != "" {
		return
	}
	if size, err := strconv.Atoi(header.Get("Content-Length")); err == nil && size < gzipMinBytes {
		return
	}
	header.Del("Content-Length")
	header.Set("Content-Encoding", "gzip")
	g.zw = gzipWriters.Get().(*gzip.Writer)
	g.zw.Reset(g.ResponseWriter)
}

func (g *gzipResponseWriter) Write(body []byte) (int, error) {
	if !g.decided {
		g.WriteHeader(http.StatusOK)
	}
	if g.zw != nil {
		return g.zw.Write(body)
	}
	return g.ResponseWriter.Write(body)
}

func (g *gzipResponseWriter) Flush() {
	if g.zw != nil {
		_ = g.zw.Flush()
	}
	if flusher, ok := g.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (g *gzipResponseWriter) Unwrap() http.ResponseWriter { return g.ResponseWriter }

func (g *gzipResponseWriter) finish() {
	if g.zw == nil {
		return
	}
	_ = g.zw.Close()
	g.zw.Reset(nil)
	gzipWriters.Put(g.zw)
	g.zw = nil
}

// encodedCatalogs keeps the last few catalog answers ready to send, by their
// ETag: the catalog is the same for every caller of a channel until it
// changes, so it is encoded and gzipped once, not at every request.
var encodedCatalogs = encodedAnswerCache{limit: 16}

type encodedAnswer struct {
	plain   []byte
	gzipped []byte
}

type encodedAnswerCache struct {
	mu      sync.Mutex
	limit   int
	order   []string
	answers map[string]*encodedAnswer
}

func (c *encodedAnswerCache) get(key string, value func() any) (*encodedAnswer, error) {
	c.mu.Lock()
	if answer, ok := c.answers[key]; ok {
		c.mu.Unlock()
		return answer, nil
	}
	c.mu.Unlock()
	plain, err := json.Marshal(value())
	if err != nil {
		return nil, err
	}
	plain = append(plain, '\n')
	var packed bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&packed, gzip.BestCompression)
	_, _ = zw.Write(plain)
	_ = zw.Close()
	answer := &encodedAnswer{plain: plain, gzipped: packed.Bytes()}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.answers == nil {
		c.answers = map[string]*encodedAnswer{}
	}
	if _, ok := c.answers[key]; !ok {
		c.order = append(c.order, key)
		if len(c.order) > c.limit {
			delete(c.answers, c.order[0])
			c.order = c.order[1:]
		}
	}
	c.answers[key] = answer
	return answer, nil
}

// writeEncodedJSON sends a ready answer, gzipped when r takes gzip.
func writeEncodedJSON(w http.ResponseWriter, r *http.Request, answer *encodedAnswer) {
	header := w.Header()
	header.Set("Content-Type", "application/json")
	addVary(header, "Accept-Encoding")
	body := answer.plain
	if webbuild.Accepts(r.Header.Get("Accept-Encoding"), "gzip") {
		body = answer.gzipped
		header.Set("Content-Encoding", "gzip")
	}
	header.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func addVary(header http.Header, name string) {
	for _, value := range header.Values("Vary") {
		for _, part := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(part), name) {
				return
			}
		}
	}
	header.Add("Vary", name)
}
