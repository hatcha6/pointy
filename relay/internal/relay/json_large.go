package relay

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strconv"
	"strings"
)

// largeJSONMin is the size from which an answer is worth compressing.
const largeJSONMin = 8 << 10

// writeLargeJSON writes a 200 the console reads often and that is large (the
// whole catalog, thousands of cards): with an ETag of its content, so a
// browser that holds the same answer is told 304 and downloads nothing, and
// gzipped for a browser that takes it. JSON of repeated keys shrinks about
// tenfold; at several megabytes, the transfer was most of the wait.
func writeLargeJSON(w http.ResponseWriter, r *http.Request, value any) {
	body := encodeJSON(value)
	sum := sha256.Sum256(body)
	tag := `"` + hex.EncodeToString(sum[:16]) + `"`
	header := w.Header()
	header.Set("ETag", tag)
	// Asked again each time (the books and prices move), never used unasked.
	header.Set("Cache-Control", "private, no-cache")
	header.Add("Vary", "Accept-Encoding")
	if etagMatches(r.Header.Get("If-None-Match"), tag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	header.Set("Content-Type", "application/json")
	if len(body) >= largeJSONMin && acceptsGzip(r.Header.Get("Accept-Encoding")) {
		var compressed bytes.Buffer
		zw, _ := gzip.NewWriterLevel(&compressed, gzip.BestSpeed)
		if _, err := zw.Write(body); err == nil && zw.Close() == nil {
			header.Set("Content-Encoding", "gzip")
			header.Set("Content-Length", strconv.Itoa(compressed.Len()))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(compressed.Bytes())
			return
		}
	}
	header.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

// acceptsGzip reports whether an Accept-Encoding header takes gzip (and does
// not refuse it with q=0).
func acceptsGzip(header string) bool {
	for _, part := range strings.Split(header, ",") {
		name, params, _ := strings.Cut(strings.TrimSpace(part), ";")
		if !strings.EqualFold(strings.TrimSpace(name), "gzip") {
			continue
		}
		if q, ok := strings.CutPrefix(strings.ReplaceAll(strings.TrimSpace(params), " ", ""), "q="); ok {
			if value, err := strconv.ParseFloat(q, 64); err == nil && value == 0 {
				return false
			}
		}
		return true
	}
	return false
}
