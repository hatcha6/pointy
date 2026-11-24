package relay

import (
	"net/http"
	"testing"

	"pointy/relay/internal/vouchers"
)

// buy places and confirms one card order; extra lays more fields on it.
func (h *orderHarness) buy(token, key string, extra map[string]any) (int, map[string]any) {
	h.t.Helper()
	// Each purchase its own supplier order: the relay holds one that names
	// an order already delivered.
	h.supplier.mu.Lock()
	h.supplier.buyResult = vouchers.Purchase{
		OrderID: "order-" + key, Status: vouchers.StatusSucceeded, Cost: "9.70", Currency: "USD",
		Codes: []vouchers.Code{{Code: "code-" + key, Serial: "SN-" + key}},
	}
	h.supplier.mu.Unlock()
	request := sadadOrder("libyana-10", "10.00", key, 1)
	for field, value := range extra {
		request[field] = value
	}
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, request)
	if status != http.StatusCreated {
		return status, body
	}
	id := orderOf(h.t, body)["id"].(string)
	return h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
}

func segmentByKey(t *testing.T, body map[string]any, key string) map[string]any {
	t.Helper()
	for _, raw := range body["segments"].([]any) {
		if segment := raw.(map[string]any); segment["key"] == key {
			return segment
		}
	}
	t.Fatalf("no segment %s in %v", key, body)
	return nil
}

func TestASegmentIsOfferedADiscountItCanUseOnce(t *testing.T) {
	h := newOrderHarness(t)
	// A live gateway, so sales reach the books and the segments.
	h.server.Wallet.TestMode, h.dafa.testWorkspace = false, false
	pusher := &fakePusher{}
	h.server.CustomerPush = pusher
	h.server.CustomerSegments = &CustomerSegmentCache{}

	buyer := h.customer("0911111111")
	browser := h.customer("0922222222")
	h.do(http.MethodPut, "/v1/customers/me/push", buyer, map[string]any{"token": "buyer-phone"})
	if status, body := h.buy(buyer, "first", nil); status != http.StatusOK || orderOf(t, body)["status"] != "delivered" {
		t.Fatalf("first order: %d %v", status, body)
	}

	// One first purchase, one new account; the buyer can be reached.
	status, body := h.do(http.MethodGet, "/v1/customers/admin/segments?fresh=1", "admin-token", nil)
	if status != http.StatusOK {
		t.Fatalf("segments: %d %v", status, body)
	}
	first := segmentByKey(t, body, "first_purchase")
	if first["customers"] != float64(1) || first["reachable"] != float64(1) || first["revenue"] != "10.000" {
		t.Fatalf("first purchase segment: %v", first)
	}
	if newcomers := segmentByKey(t, body, "new"); newcomers["customers"] != float64(1) {
		t.Fatalf("new segment: %v", newcomers)
	}
	_, listed := h.do(http.MethodGet, "/v1/customers/admin/customers?rfm=first_purchase", "admin-token", nil)
	if rows := listed["customers"].([]any); len(rows) != 1 || rows[0].(map[string]any)["rfm"] != "first_purchase" {
		t.Fatalf("listed by segment: %v", listed)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/admin/customers?rfm=nope", "admin-token", nil); status != http.StatusBadRequest {
		t.Fatalf("an unknown segment: %d", status)
	}

	// 20% off the second order, told to the phone.
	status, made := h.do(http.MethodPost, "/v1/customers/admin/offers", "admin-token", map[string]any{
		"name": "second order", "title": "خصم 20٪ على طلبك القادم", "kind": "percent", "value": "20",
		"segments": []string{"first_purchase"}, "notify": map[string]any{"title": "هدية لك", "body": "خصم 20٪"},
	})
	offer, _ := made["offer"].(map[string]any)
	if status != http.StatusCreated || offer["recipients"] != float64(1) || len(pusher.tokens) != 1 || pusher.tokens[0] != "buyer-phone" {
		t.Fatalf("offer: %d %v (pushed %v)", status, made, pusher.tokens)
	}
	id := offer["id"].(string)

	if _, mine := h.do(http.MethodGet, "/v1/customers/me/offers", browser, nil); len(mine["offers"].([]any)) != 0 {
		t.Fatalf("another segment's customer sees it: %v", mine)
	}
	_, mine := h.do(http.MethodGet, "/v1/customers/me/offers", buyer, nil)
	if offers := mine["offers"].([]any); len(offers) != 1 || offers[0].(map[string]any)["uses_left"] != float64(1) {
		t.Fatalf("the buyer's offers: %v", mine)
	}
	if status, _ := h.buy(browser, "not-theirs", map[string]any{"offer_id": id}); status != http.StatusConflict {
		t.Fatalf("an offer used by someone it was not made for: %d", status)
	}

	status, body = h.buy(buyer, "second", map[string]any{"offer_id": id})
	order := orderOf(t, body)
	if status != http.StatusOK || order["total"] != "8.000" || order["discount"] != "2.000" || order["offer_id"] != id ||
		order["status"] != "delivered" {
		t.Fatalf("the order with the offer: %d %v", status, order)
	}
	if status, _ := h.buy(buyer, "third", map[string]any{"offer_id": id}); status != http.StatusConflict {
		t.Fatalf("a second use: %d", status)
	}
	if _, mine := h.do(http.MethodGet, "/v1/customers/me/offers", buyer, nil); len(mine["offers"].([]any)) != 0 {
		t.Fatalf("a used offer is still offered: %v", mine)
	}

	_, results := h.do(http.MethodGet, "/v1/customers/admin/offers", "admin-token", nil)
	result := results["offers"].([]any)[0].(map[string]any)["result"].(map[string]any)
	if result["redeemers"] != float64(1) || result["orders"] != float64(1) || result["discounts"] != "2.000" ||
		result["revenue"] != "8.000" || result["recipient_rate"] != float64(1) {
		t.Fatalf("offer results: %v", result)
	}

	// Two orders now: a repeat buyer on their rhythm, and a notification to
	// that segment reaches their phone.
	status, sent := h.do(http.MethodPost, "/v1/customers/admin/notifications", "admin-token", map[string]any{
		"audience": "segments", "segments": []string{"promising"}, "title": "شكراً", "body": "عرض جديد",
	})
	if status != http.StatusOK || sent["customers"] != float64(1) || len(pusher.tokens) != 2 {
		t.Fatalf("segment notification: %d %v (pushed %v)", status, sent, pusher.tokens)
	}
	if status, _ := h.do(http.MethodPost, "/v1/customers/admin/notifications", "admin-token", map[string]any{
		"audience": "segments", "segments": []string{"lost"}, "title": "t", "body": "b",
	}); status != http.StatusConflict {
		t.Fatalf("a segment nobody can be sent to: %d", status)
	}
}

func TestAnOffersHoldoutIsNotGivenIt(t *testing.T) {
	h := newOrderHarness(t)
	h.server.Wallet.TestMode, h.dafa.testWorkspace = false, false
	tokens := []string{}
	for _, phone := range []string{"0911111111", "0911111112", "0911111113", "0911111114"} {
		token := h.customer(phone)
		tokens = append(tokens, token)
		if status, _ := h.buy(token, "first-"+phone, nil); status != http.StatusOK {
			t.Fatalf("order for %s: %d", phone, status)
		}
	}
	status, made := h.do(http.MethodPost, "/v1/customers/admin/offers", "admin-token", map[string]any{
		"name": "held", "title": "خصم", "kind": "amount", "value": "1", "segments": []string{"first_purchase"},
		"holdout_percent": 50,
	})
	offer := made["offer"].(map[string]any)
	if status != http.StatusCreated || offer["recipients"] != float64(2) || offer["holdouts"] != float64(2) {
		t.Fatalf("offer with a holdout: %d %v", status, made)
	}
	given := 0
	for _, token := range tokens {
		_, mine := h.do(http.MethodGet, "/v1/customers/me/offers", token, nil)
		given += len(mine["offers"].([]any))
	}
	if given != 2 {
		t.Fatalf("the offer reached %d customers, not 2", given)
	}
	if status, _ := h.do(http.MethodPost, "/v1/customers/admin/offers", "admin-token", map[string]any{
		"name": "all held", "title": "x", "kind": "amount", "value": "1", "segments": []string{"lost"},
	}); status != http.StatusBadRequest {
		t.Fatalf("an offer for nobody: %d", status)
	}
}
