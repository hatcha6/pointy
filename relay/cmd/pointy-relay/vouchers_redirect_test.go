package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"pointy/relay/internal/bnplus"
	relayserver "pointy/relay/internal/relay"
	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
)

// redirector is a supplier that answers every call with a 307 to another host,
// as a moved API does, and the host it points at, which counts what reaches it.
type redirector struct {
	origin     *httptest.Server
	target     *httptest.Server
	targetHits atomic.Int32
	// credentials is what reached the target in a header a supplier uses.
	credentials atomic.Value
}

func newRedirector(t *testing.T) *redirector {
	t.Helper()
	r := &redirector{}
	r.target = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		r.targetHits.Add(1)
		r.credentials.Store(req.Header.Get("Api-Password") + req.Header.Get("Authorization"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"success":true}`))
	}))
	r.origin = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path == "/oauth/token" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"access_token":"tok","expires_in":3600}`))
			return
		}
		http.Redirect(w, req, r.target.URL+req.URL.Path, http.StatusTemporaryRedirect)
	}))
	t.Cleanup(r.origin.Close)
	t.Cleanup(r.target.Close)
	return r
}

func TestAPurchaseIsNeverSentAgainByARedirect(t *testing.T) {
	r := newRedirector(t)
	ctx := context.Background()

	// BN Plus: the buy is a POST that carries the company's password.
	config := relayserver.VoucherConfig{}
	attachVoucherSuppliers(&config, bnplus.Config{
		BaseURL: r.origin.URL, Email: "ops@example.ly", Password: "secret-password", Token: "token",
	}, http.DefaultClient)
	supplier := config.Suppliers[vouchers.SupplierBNPlus]
	if _, err := supplier.Buy(ctx, vouchers.Ref{Supplier: vouchers.SupplierBNPlus, ID: "12"}, 1, "purchase-1"); err == nil {
		t.Fatal("a redirect is not a sale")
	}
	if _, err := supplier.Offers(ctx); err == nil {
		t.Fatal("a redirect is not a catalog either")
	}
	if hits := r.targetHits.Load(); hits != 0 {
		t.Fatalf("the redirect was followed %d times: the purchase would have been sent again, with the company's password", hits)
	}

	// Reloadly: the same, for the order and for the token that rides with it.
	config = relayserver.VoucherConfig{}
	if err := attachReloadlySupplier(&config, reloadly.Config{
		ClientID: "id", ClientSecret: "secret", AuthURL: r.origin.URL, GiftcardsURL: r.origin.URL, RetryBackoff: time.Millisecond,
	}, http.DefaultClient); err != nil {
		t.Fatal(err)
	}
	_, err := config.Suppliers[vouchers.SupplierReloadly].Buy(ctx, vouchers.Ref{Supplier: vouchers.SupplierReloadly, ID: "7/5"}, 1, "purchase-2")
	if err == nil {
		t.Fatal("a redirect is not a sale")
	}
	if hits := r.targetHits.Load(); hits != 0 {
		t.Fatalf("the redirect was followed %d times: %v", hits, r.credentials.Load())
	}
}

// The test above only means something if a client that follows redirects does
// reach the target: this is the trap the wiring closes.
func TestAClientThatFollowsRedirectsDoesReachTheTarget(t *testing.T) {
	r := newRedirector(t)
	client := bnplus.New(bnplus.Config{
		BaseURL: r.origin.URL, Email: "ops@example.ly", Password: "secret-password", Token: "token", HTTPClient: http.DefaultClient,
	})
	_, _ = client.Cards(context.Background(), 1)
	if r.targetHits.Load() == 0 {
		t.Fatal("the stand-in must redirect")
	}
	if got, _ := r.credentials.Load().(string); !strings.Contains(got, "secret-password") {
		t.Fatalf("a custom header travels with the redirect to another host: %q", got)
	}
}

func TestWithoutRedirectsKeepsTheRestOfTheClient(t *testing.T) {
	original := &http.Client{Timeout: 3 * time.Second}
	copied := withoutRedirects(original)
	if copied == original || copied.Timeout != 3*time.Second || original.CheckRedirect != nil {
		t.Fatalf("a copy with the same timeout, the original untouched: %+v", copied)
	}
	if err := copied.CheckRedirect(nil, nil); err != http.ErrUseLastResponse {
		t.Fatalf("redirects are returned as the answer: %v", err)
	}
	if withoutRedirects(nil).CheckRedirect == nil {
		t.Fatal("a nil client becomes one that never follows")
	}
}

func TestTheRealRelayRemembersWhichSuppliersJustFailed(t *testing.T) {
	config, _, _, err := buildVoucherConfig(voucherSettings{RateLimit: "30/minute"})
	if err != nil || config.Breaker == nil {
		t.Fatalf("a relay without a breaker keeps asking a supplier whose account is empty: %+v %v", config, err)
	}
}
