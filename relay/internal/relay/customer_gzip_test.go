package relay

import (
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
)

func TestCustomerCatalogIsGzippedForACallerThatTakesIt(t *testing.T) {
	h := newOrderHarness(t)
	get := func(encoding string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodGet, "http://relay.test/v1/customers/catalog?channel=apk", nil)
		if encoding != "" {
			request.Header.Set("Accept-Encoding", encoding)
		}
		recorder := httptest.NewRecorder()
		h.server.ServeHTTP(recorder, request)
		return recorder
	}

	plain := get("")
	if plain.Code != http.StatusOK || plain.Header().Get("Content-Encoding") != "" {
		t.Fatalf("plain: %d %q", plain.Code, plain.Header().Get("Content-Encoding"))
	}
	var plainBody map[string]any
	if err := json.Unmarshal(plain.Body.Bytes(), &plainBody); err != nil {
		t.Fatalf("plain body: %v", err)
	}

	// Twice: the second answer comes from the encoded copy.
	for range 2 {
		packed := get("gzip, deflate, br")
		if packed.Code != http.StatusOK || packed.Header().Get("Content-Encoding") != "gzip" ||
			packed.Header().Get("Vary") != "Accept-Encoding" {
			t.Fatalf("gzip: %d %v", packed.Code, packed.Header())
		}
		if packed.Header().Get("ETag") != plain.Header().Get("ETag") {
			t.Fatal("the encoding moved the ETag: every saved copy would be downloaded again")
		}
		reader, err := gzip.NewReader(packed.Body)
		if err != nil {
			t.Fatalf("not gzip: %v", err)
		}
		raw, _ := io.ReadAll(reader)
		if string(raw) != plain.Body.String() {
			t.Fatal("the gzipped catalog is not the plain one")
		}
	}

	if refused := get("gzip;q=0"); refused.Header().Get("Content-Encoding") != "" {
		t.Fatal("gzip sent to a caller that refused it")
	}
}

func TestCustomerGzipLeavesSmallAndNonJSONAnswersAlone(t *testing.T) {
	serve := func(contentType string, body []byte, length bool) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodGet, "http://relay.test/x", nil)
		request.Header.Set("Accept-Encoding", "gzip")
		recorder := httptest.NewRecorder()
		w, finish := withCustomerGzip(recorder, request)
		w.Header().Set("Content-Type", contentType)
		if length {
			w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
		finish()
		return recorder
	}
	big := make([]byte, 4096)
	for i := range big {
		big[i] = 'a'
	}
	if r := serve("application/json", []byte(`{"ok":true}`), true); r.Header().Get("Content-Encoding") != "" || r.Body.String() != `{"ok":true}` {
		t.Fatalf("small answer gzipped: %v", r.Header())
	}
	if r := serve("image/png", big, true); r.Header().Get("Content-Encoding") != "" || r.Body.Len() != len(big) {
		t.Fatal("an image was gzipped")
	}
	r := serve("application/json", big, true)
	if r.Header().Get("Content-Encoding") != "gzip" || r.Header().Get("Content-Length") != "" {
		t.Fatalf("large json: %v", r.Header())
	}
	reader, _ := gzip.NewReader(r.Body)
	raw, _ := io.ReadAll(reader)
	if len(raw) != len(big) {
		t.Fatalf("round trip: %d", len(raw))
	}
}
