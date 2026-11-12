package relay

import (
	"net/http"
	"strings"
	"testing"
)

// The stores' review account walks the whole eSIM flow for show: nothing it
// does on a live relay reaches a supplier.

func (h *orderHarness) reviewBuy(token, item, price, key string) map[string]any {
	h.t.Helper()
	status, placed := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder(item, price, key, 1))
	if status != http.StatusCreated {
		h.t.Fatalf("create: %d %v", status, placed)
	}
	_, paid := h.do(http.MethodPost, "/v1/customers/orders/"+orderOf(h.t, placed)["id"].(string)+"/confirm", token, map[string]any{"otp": "246810"})
	return orderOf(h.t, paid)
}

func (h *orderHarness) readESIM(token, iccid string) map[string]any {
	h.t.Helper()
	status, body := h.do(http.MethodGet, "/v1/customers/esims/"+iccid, token, nil)
	if status != http.StatusOK {
		h.t.Fatalf("eSIM read: %d %v", status, body)
	}
	return body["esim"].(map[string]any)
}

func simulatedInstall(esim map[string]any) bool {
	install, ok := esim["install"].(map[string]any)
	return ok && strings.Contains(install["qr"].(string), "test.dftr.ly")
}

func TestReviewAccountWalksTheWholeESIMFlowForShow(t *testing.T) {
	h := newESIMHarness(t)
	token := h.reviewer()
	item, price := h.plan("turkey", "merhaba-7days-1gb")
	order := h.reviewBuy(token, item, price, "r-1")
	if order["status"] != "delivered" || order["delivery"] != "esim" || order["test_mode"] != false {
		t.Fatalf("order: %v", order)
	}
	iccid := h.issued(token, order["id"].(string))["iccid"].(string)

	// Its page: installs, and shows the plan that was bought, untouched.
	esim := h.readESIM(token, iccid)
	if !simulatedInstall(esim) || esim["test_mode"] != false {
		t.Fatalf("eSIM: %v", esim)
	}
	usage := esim["usage"].(map[string]any)
	if usage["status"] != "NOT_ACTIVE" || usage["total_mb"] != float64(1024) || usage["remaining_mb"] != float64(1024) {
		t.Fatalf("usage: %v", usage)
	}
	if status, body := h.do(http.MethodPut, "/v1/customers/esims/"+iccid, token, map[string]any{"label": "هاتفي"}); status != http.StatusOK {
		t.Fatalf("rename: %d %v", status, body)
	}

	// A top-up is offered, bought for show, and adds its data.
	_, body := h.do(http.MethodGet, "/v1/customers/esims/"+iccid+"/topups", token, nil)
	plans := body["plans"].([]any)
	if len(plans) == 0 {
		t.Fatalf("no top-ups: %v", body)
	}
	plan := plans[len(plans)-1].(map[string]any)
	topped := h.reviewBuy(token, plan["item"].(string), plan["price"].(string), "r-2")
	if topped["status"] != "delivered" {
		t.Fatalf("top-up: %v", topped)
	}
	want := float64(1024) + plan["amount_mb"].(float64)
	if usage := h.readESIM(token, iccid)["usage"].(map[string]any); usage["total_mb"] != want || usage["remaining_mb"] != want {
		t.Fatalf("usage after a top-up: %v, want %v", usage, want)
	}
	if _, body := h.do(http.MethodGet, "/v1/customers/esims", token, nil); len(body["esims"].([]any)) != 1 {
		t.Fatalf("eSIMs: %v", body)
	}
	if h.fake.OrderRequests != 0 || h.fake.TopUpRequests != 0 {
		t.Fatalf("a review reached Airalo: %d orders, %d top-ups", h.fake.OrderRequests, h.fake.TopUpRequests)
	}
}

// An eSIM the review account bought in Airalo's Sandbox is unknown to the live
// account: once the relay goes live it is one for show, like any it buys then.
func TestReviewAccountsSandboxESIMIsForShowOnceLive(t *testing.T) {
	h := newESIMHarness(t)
	h.server.ESIM.Sandbox = true
	token := h.reviewer()
	_, destination := h.do(http.MethodGet, "/v1/customers/esim/destinations/turkey", token, nil)
	var item, price string
	for _, raw := range destination["plans"].([]any) {
		if plan := raw.(map[string]any); plan["id"] == "merhaba-7days-1gb" {
			item, price = plan["item"].(string), plan["price"].(string)
		}
	}
	order := h.reviewBuy(token, item, price, "r-1")
	if order["status"] != "delivered" || h.fake.OrderRequests != 1 {
		t.Fatalf("Sandbox order: %v, %d Airalo orders", order, h.fake.OrderRequests)
	}
	iccid := h.issued(token, order["id"].(string))["iccid"].(string)
	if simulatedInstall(h.readESIM(token, iccid)) {
		t.Fatal("a Sandbox eSIM was simulated while in Sandbox")
	}

	h.server.ESIM.Sandbox = false
	h.clock.advance(esimUsageFresh + esimTopUpsTTL)
	esim := h.readESIM(token, iccid)
	if !simulatedInstall(esim) || esim["test_mode"] != false || esim["usage"].(map[string]any)["status"] != "NOT_ACTIVE" {
		t.Fatalf("the Sandbox eSIM once live: %v", esim)
	}
	if _, body := h.do(http.MethodGet, "/v1/customers/esims", token, nil); body["esims"].([]any)[0].(map[string]any)["test_mode"] != false {
		t.Fatalf("the list: %v", body)
	}
	_, body := h.do(http.MethodGet, "/v1/customers/esims/"+iccid+"/topups", token, nil)
	plan := body["plans"].([]any)[0].(map[string]any)
	if !strings.HasPrefix(plan["id"].(string), "test-topup-") {
		t.Fatalf("top-ups read from the live account: %v", body)
	}
	if topped := h.reviewBuy(token, plan["item"].(string), plan["price"].(string), "r-2"); topped["status"] != "delivered" || h.fake.TopUpRequests != 0 {
		t.Fatalf("top-up: %v, %d Airalo top-ups", topped, h.fake.TopUpRequests)
	}

	// A customer's own eSIM is still read from Airalo.
	customer := h.customer("0911111111")
	item, price = h.plan("turkey", "merhaba-7days-1gb")
	real := h.buy(customer, item, price, "c-1", nil)
	if simulatedInstall(h.readESIM(customer, h.issued(customer, real["id"].(string))["iccid"].(string))) {
		t.Fatal("a customer's eSIM was simulated")
	}
}

// Beside a Sandbox Airalo the review account's eSIM is a simulated one: its
// top-up is for show too, and never sent to the Sandbox.
func TestReviewAccountsSimulatedESIMIsNeverToppedUpInSandbox(t *testing.T) {
	h := newESIMAccessHarness(t, true, func(h *esimAccessHarness) { h.server.ESIM.Sandbox = true })
	token := h.reviewer()
	plan := h.plan("tunisia", 1024, 7)
	order := h.reviewBuy(token, plan["item"].(string), plan["price"].(string), "r-1")
	iccid := h.issued(token, order["id"].(string))["iccid"].(string)
	_, body := h.do(http.MethodGet, "/v1/customers/esims/"+iccid+"/topups", token, nil)
	topUp := body["plans"].([]any)[0].(map[string]any)
	topped := h.reviewBuy(token, topUp["item"].(string), topUp["price"].(string), "r-2")
	if topped["status"] != "delivered" || h.airalo.TopUpRequests != 0 || h.airalo.OrderRequests != 0 || h.access.Orders != 0 {
		t.Fatalf("top-up: %v, Airalo %d top-ups", topped, h.airalo.TopUpRequests)
	}
}
