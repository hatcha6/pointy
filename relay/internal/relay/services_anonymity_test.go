package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"pointy/relay/internal/services"
	"pointy/relay/internal/vouchers"
)

// Shops never learn which supplier the company buys from: nothing a shop reads
// may carry a supplier's name, host, order id or error code.
var supplierWords = []string{
	"reloadly", "bnplus", "bn plus", "bn-plus", "amazonaws", "rld-operator",
	"supplier_", "http://", "https://",
}

func assertAnonymous(t *testing.T, what string, raw []byte) {
	t.Helper()
	lowered := strings.ToLower(string(raw))
	for _, word := range supplierWords {
		if strings.Contains(lowered, word) {
			t.Fatalf("%s names the supplier (%q): %s", what, word, raw)
		}
	}
}

// logoRoundTripper answers every logo fetch with a small PNG.
type logoRoundTripper struct {
	t    *testing.T
	seen []string
}

func (r *logoRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	r.seen = append(r.seen, request.URL.String())
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"image/png"}},
		Body:       io.NopCloser(bytes.NewReader(testPNG(r.t, 90))),
		Request:    request,
	}, nil
}

func TestOperatorLogosAreCopiedAndTheDirectoryCarriesOnlyTheRelaysOwnReference(t *testing.T) {
	h := readyServicesHarness(t)
	transport := &logoRoundTripper{t: t}
	h.server.ServiceLogos = NewServiceLogos()
	h.server.ServiceLogos.Client = &http.Client{Transport: transport}

	// The first reading starts the copies and carries no logo yet.
	first := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil)
	assertAnonymous(t, "the first directory", first.Body.Bytes())

	urls := h.service.OperatorLogoURLs()
	if len(urls) == 0 {
		t.Fatal("the fixture has operators with logos")
	}
	h.server.ServiceLogos.Fill(context.Background(), h.store, urls)
	if len(transport.seen) < len(urls) {
		t.Fatalf("every logo is fetched once: %d of %d", len(transport.seen), len(urls))
	}

	second := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil)
	if second.Header().Get("ETag") == first.Header().Get("ETag") {
		t.Fatal("a copied logo changes the directory")
	}
	assertAnonymous(t, "the directory", second.Body.Bytes())
	var directory services.Directory
	if err := json.Unmarshal(second.Body.Bytes(), &directory); err != nil {
		t.Fatal(err)
	}
	var withLogo string
	for _, country := range directory.Countries {
		if country.Airtime == nil {
			continue
		}
		for _, operator := range country.Airtime.Operators {
			if operator.Logo != "" {
				withLogo = operator.Logo
			}
		}
	}
	if !strings.HasPrefix(withLogo, vouchers.ImagePrefix) {
		t.Fatalf("an operator carries the relay's reference, got %q", withLogo)
	}

	// The relay serves its copy from its own route.
	served := h.serve(http.MethodGet, "/v1/services/logos/"+withLogo, map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil)
	if served.Code != http.StatusOK || !strings.HasPrefix(served.Header().Get("Content-Type"), "image/") {
		t.Fatalf("the logo route: %d %s", served.Code, served.Header().Get("Content-Type"))
	}
}

func TestOnlyPublicHTTPSImagesAreCopiedAsLogos(t *testing.T) {
	h := readyServicesHarness(t)
	logos := NewServiceLogos()
	logos.Client = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("<html>not an image</html>")), Request: request}, nil
	})}
	logos.Fill(context.Background(), h.store, []string{"https://cdn.example/logo.png", "http://cdn.example/plain.png", "ftp://x/y.png"})
	if snapshot, _ := logos.Snapshot(); len(snapshot) != 0 {
		t.Fatalf("nothing but an https image is kept: %v", snapshot)
	}
}

func TestNothingAShopReadsNamesTheSupplier(t *testing.T) {
	h := readyServicesHarness(t)
	token := map[string]string{AccessTokenHeader: h.shop.AccessToken, "Content-Type": "application/json"}
	marshal := func(v any) []byte { raw, _ := json.Marshal(v); return raw }

	for name, recorder := range map[string][]byte{
		"detect": h.serve(http.MethodPost, "/v1/services/detect", token, marshal(map[string]any{"country": "ML", "phone": "+223 70 12 34 56"})).Body.Bytes(),
		"quote": h.serve(http.MethodPost, "/v1/services/quote", token, marshal(map[string]any{
			"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"})).Body.Bytes(),
		"bad quote": h.serve(http.MethodPost, "/v1/services/quote", token, marshal(map[string]any{"kind": "airtime", "operator_id": 1})).Body.Bytes(),
	} {
		assertAnonymous(t, name, recorder)
	}

	// A sold order, its replay and its read-back, for a top-up and a bill.
	for index, body := range []map[string]any{svcAirtimeBody("anon-1"), svcBillBody("anon-2")} {
		for range 2 {
			order := h.serve(http.MethodPost, "/v1/services/orders", token, marshal(body))
			assertAnonymous(t, "order", order.Body.Bytes())
		}
		read := h.serve(http.MethodGet, "/v1/services/orders/"+body["idempotency_key"].(string), token, nil)
		assertAnonymous(t, "order read-back", read.Body.Bytes())
		_ = index
	}

	// Every way the supplier can refuse.
	for i, code := range []string{
		vouchers.FailureCredit, vouchers.FailureUnauthorized, vouchers.FailureOutOfStock,
		vouchers.FailureUnreachable, vouchers.FailureRefused,
	} {
		failure := &vouchers.Failure{Code: code, Detail: "Reloadly said no at https://topups.reloadly.com", Definite: true}
		h.exec.onAirtime = func(services.AirtimeOrder) (services.Result, error) { return services.Result{}, failure }
		key := "anon-fail-" + string(rune('a'+i))
		for range 2 {
			order := h.serve(http.MethodPost, "/v1/services/orders", token, marshal(svcAirtimeBody(key)))
			if order.Code != http.StatusBadGateway {
				t.Fatalf("%s: %d %s", code, order.Code, order.Body.String())
			}
			assertAnonymous(t, "a refused order ("+code+")", order.Body.Bytes())
		}
		read := h.serve(http.MethodGet, "/v1/services/orders/"+key, token, nil)
		assertAnonymous(t, "a refused order read back", read.Body.Bytes())
	}
}

func TestACardPurchaseRefusedBySuppliersNamesNoneOfThem(t *testing.T) {
	h := newDualHarness(t)
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureCredit, Detail: "insufficient balance at reloadly", Definite: true}
	h.supplier.buyErr = &vouchers.Failure{Code: vouchers.FailureOutOfStock, Detail: "bnplus has no codes", Definite: true}
	status, body := h.buy(t, "psn-20", "anon-card-1")
	if status != http.StatusBadGateway {
		t.Fatalf("%d %v", status, body)
	}
	raw, _ := json.Marshal(body)
	assertAnonymous(t, "a refused card purchase", raw)

	token := map[string]string{AccessTokenHeader: h.shopper.AccessToken}
	read := h.voucherHarness.request(t, h.server, http.MethodGet, "/v1/vouchers/purchases/anon-card-1", token, nil)
	assertAnonymous(t, "a refused card purchase read back", read.Body.Bytes())
	catalog := h.voucherHarness.request(t, h.server, http.MethodGet, "/v1/vouchers/catalog", token, nil)
	assertAnonymous(t, "the card catalog", catalog.Body.Bytes())
}
