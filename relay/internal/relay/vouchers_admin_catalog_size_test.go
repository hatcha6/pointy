package relay

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// bigCatalogDocument is a catalog of brands × items cards, each bought from
// BN Plus.
func bigCatalogDocument(brands, items int) []byte {
	var b strings.Builder
	b.WriteString(`{"categories":[{"key":"gift_cards","name":"بطاقات","sort":1}],"countries":[{"code":"US"}],"brands":[`)
	id := 1000
	for i := 0; i < brands; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, `{"key":"brand-%d","name":"Brand %d","category":"gift_cards","logo":{},"items":[`, i, i)
		for j := 0; j < items; j++ {
			if j > 0 {
				b.WriteString(",")
			}
			id++
			fmt.Fprintf(&b, `{"key":"brand-%d-%d","country":"US","face_value":"%d","face_currency":"USD","price":"%d.00","retail_price":"%d.00","supplier":{"key":"bnplus","card_id":%d}}`,
				i, j, j+1, (j+1)*6, (j+1)*7, id)
		}
		b.WriteString("]}")
	}
	b.WriteString("]}")
	return []byte(b.String())
}

func publishBigCatalog(tb testing.TB, h *voucherHarness, brands, items int) {
	tb.Helper()
	body, _ := json.Marshal(map[string]any{"document": json.RawMessage(bigCatalogDocument(brands, items)), "actor": "t"})
	if status, out := h.admin(tb, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json", body); status != http.StatusOK && status != http.StatusCreated {
		tb.Fatalf("publish %d %v", status, out)
	}
}

// The console's catalog page read several megabytes on every visit: the
// answer is now gzipped, and a browser that already holds it downloads
// nothing.
func TestTheConsoleCatalogIsCompressedAndRevalidated(t *testing.T) {
	h := newVoucherHarness(t)
	publishBigCatalog(t, h, 60, 20)
	get := func(headers map[string]string) *httptest.ResponseRecorder {
		headers["Authorization"] = "Bearer admin-token"
		return h.request(t, h.server, http.MethodGet, "/v1/vouchers/admin/catalog", headers, nil)
	}

	plain := get(map[string]string{})
	if plain.Code != http.StatusOK || plain.Header().Get("Content-Encoding") != "" || plain.Header().Get("ETag") == "" {
		t.Fatalf("plain: %d %v", plain.Code, plain.Header())
	}
	var answer map[string]any
	if err := json.Unmarshal(plain.Body.Bytes(), &answer); err != nil || len(answer["supply"].([]any)) != 1200 {
		t.Fatalf("plain body: %v", err)
	}

	zipped := get(map[string]string{"Accept-Encoding": "gzip, deflate, br"})
	if zipped.Header().Get("Content-Encoding") != "gzip" || zipped.Body.Len()*5 > plain.Body.Len() {
		t.Fatalf("gzip: %v, %d bytes of %d", zipped.Header(), zipped.Body.Len(), plain.Body.Len())
	}
	reader, err := gzip.NewReader(bytes.NewReader(zipped.Body.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	unzipped, _ := io.ReadAll(reader)
	if !bytes.Equal(unzipped, plain.Body.Bytes()) || zipped.Header().Get("ETag") != plain.Header().Get("ETag") {
		t.Fatal("the gzipped answer is not the same answer")
	}
	if get(map[string]string{"Accept-Encoding": "gzip;q=0"}).Header().Get("Content-Encoding") != "" {
		t.Fatal("gzip refused with q=0 was sent anyway")
	}

	again := get(map[string]string{"If-None-Match": plain.Header().Get("ETag"), "Accept-Encoding": "gzip"})
	if again.Code != http.StatusNotModified || again.Body.Len() != 0 {
		t.Fatalf("revalidation: %d, %d bytes", again.Code, again.Body.Len())
	}
	if changed := get(map[string]string{"If-None-Match": `"other"`}); changed.Code != http.StatusOK {
		t.Fatalf("another tag: %d", changed.Code)
	}
}

// BenchmarkConsoleCatalog is the console's catalog page at the size the
// company sells: 6,000 cards.
//
//	go test ./internal/relay -run '^$' -bench ConsoleCatalog
func BenchmarkConsoleCatalog(b *testing.B) {
	h := newVoucherHarness(b)
	publishBigCatalog(b, h, 300, 20)
	headers := map[string]string{"Authorization": "Bearer admin-token", "Accept-Encoding": "gzip"}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		h.request(b, h.server, http.MethodGet, "/v1/vouchers/admin/catalog", headers, nil)
	}
}
