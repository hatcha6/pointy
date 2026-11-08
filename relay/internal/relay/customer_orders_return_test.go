package relay

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Dafa's bank-card page shows «المتابعة» only with a return address. It is
// the relay's own payment-return page, never the web app: the app's payment
// page stops there and closes, and the checkout carries on under it.
func TestBankCardPageReturnsToTheRelaysOwnPage(t *testing.T) {
	h := newOrderHarness(t)
	h.server.Wallet.PublicURL = "https://relay.example"
	token := h.customer("0911111111")
	request := map[string]any{"item": "libyana-10", "unit_price": "10.00", "idempotency_key": "card-1",
		"channel": "web", "method": "dafa_moamalat"}
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, request); status != http.StatusCreated {
		t.Fatalf("card order: %d %v", status, body)
	}
	if got := h.dafa.initiated(0)["return_url"]; got != "https://relay.example"+customerPaymentReturnPath {
		t.Fatalf("return_url = %v", got)
	}

	// An OTP method has no page to come back from.
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "otp-1", 1)); status != http.StatusCreated {
		t.Fatalf("otp order: %d %v", status, body)
	}
	if _, ok := h.dafa.initiated(1)["return_url"]; ok {
		t.Fatal("an OTP method was given a return address")
	}

	// A relay with no public https address has nowhere Dafa could send them.
	local := newOrderHarness(t)
	local.server.Wallet.PublicURL = "http://127.0.0.1:8091"
	localToken := local.customer("0911111111")
	request["idempotency_key"] = "card-2"
	local.do(http.MethodPost, "/v1/customers/orders", localToken, request)
	if _, ok := local.dafa.initiated(0)["return_url"]; ok {
		t.Fatal("a private relay address was handed to Dafa")
	}
}

func TestPaymentReturnPageTellsTheAppAndNothingElse(t *testing.T) {
	h := newOrderHarness(t)
	request, _ := http.NewRequest(http.MethodGet, "http://relay.test"+customerPaymentReturnPath, nil)
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	body := recorder.Body.String()
	if recorder.Code != http.StatusOK || !strings.Contains(body, `postMessage("pointy-payment-return"`) ||
		!strings.Contains(body, "دفتر كروت") {
		t.Fatalf("payment-return page: %d %s", recorder.Code, body)
	}
	csp := recorder.Header().Get("Content-Security-Policy")
	if strings.Contains(csp, "frame-ancestors") || recorder.Header().Get("X-Frame-Options") != "" {
		t.Fatalf("the page must load inside Dafa's frame: %q", csp)
	}
}
