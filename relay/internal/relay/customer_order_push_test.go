package relay

import (
	"context"
	"net/http"
	"testing"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

func TestAnOrderThatEndsUnwatchedIsToldToThePhones(t *testing.T) {
	h := newOrderHarness(t)
	pusher := &fakePusher{}
	h.server.CustomerPush = pusher
	token := h.customer("0911111111")
	if status, _ := h.do(http.MethodPut, "/v1/customers/me/push", token, map[string]any{"token": "phone-1"}); status != http.StatusNoContent {
		t.Fatalf("register: %d", status)
	}
	sent := func() int {
		pusher.mu.Lock()
		defer pusher.mu.Unlock()
		return len(pusher.tokens)
	}
	// slowOrder pays for an order whose supplier takes it and has no code yet.
	slowOrder := func(key, supplierOrder string) string {
		t.Helper()
		h.supplier.buyResult = vouchers.Purchase{OrderID: supplierOrder, Status: vouchers.StatusPending}
		_, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", key, 1))
		id := orderOf(t, body)["id"].(string)
		_, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
		if order := orderOf(t, body); order["status"] != "fulfilling" || order["codes_pending"] != true {
			t.Fatalf("waiting: %v", body)
		}
		return id
	}
	delivered := func(supplierOrder string) {
		h.supplier.mu.Lock()
		h.supplier.lookups[supplierOrder] = vouchers.Purchase{OrderID: supplierOrder, Status: vouchers.StatusSucceeded,
			Cost: "9.70", Currency: "USD", Codes: []vouchers.Code{{Code: "1234-5678-9012"}}}
		h.supplier.mu.Unlock()
	}

	// The customer walked away: the sweep finds the code, and the phone hears.
	away := slowOrder("o-away", "901")
	if sent() != 0 {
		t.Fatal("told before the code came")
	}
	delivered("901")
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	if order, _ := h.store.GetCustomerOrder(context.Background(), away); order.Status != control.CustomerOrderDelivered {
		t.Fatalf("after the sweep: %+v", order)
	}
	pusher.mu.Lock()
	last := pusher.last
	pusher.mu.Unlock()
	if sent() != 1 || last.Title != "رمز بطاقتك جاهز" || last.Order != away || last.Link != "https://cards.dftr.ly/my-cards/"+away {
		t.Fatalf("told %d: %+v", sent(), last)
	}

	// Still on the waiting screen: the app's own read brings the code, and
	// nothing else is sent.
	watched := slowOrder("o-watched", "902")
	delivered("902")
	_, body := h.do(http.MethodGet, "/v1/customers/orders/"+watched, token, nil)
	if order := orderOf(t, body); order["status"] != "delivered" || len(order["codes"].([]any)) != 1 {
		t.Fatalf("read: %v", body)
	}
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	if sent() != 1 {
		t.Fatalf("a watched order was told to the phone too: %d", sent())
	}

	// A card that could not be had goes back to credit, and the phone hears.
	refunded := slowOrder("o-refund", "903")
	stored, _ := h.store.GetCustomerOrder(context.Background(), refunded)
	if _, _, err := h.store.ResolveVoucherPurchase(context.Background(), stored.PurchaseID,
		control.VoucherPurchaseResolution{Found: false, Detail: "not at the supplier"}); err != nil {
		t.Fatal(err)
	}
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	pusher.mu.Lock()
	last = pusher.last
	pusher.mu.Unlock()
	if sent() != 2 || last.Title != "تعذّر تسليم بطاقتك" || last.Order != refunded {
		t.Fatalf("refund told %d: %+v", sent(), last)
	}
	// Each ending is told once.
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	if sent() != 2 {
		t.Fatalf("told again: %d", sent())
	}
}

func TestTheOrderMessageNamesTheCardOrTheAccount(t *testing.T) {
	order := control.CustomerOrder{ID: "ord-1", ItemName: "شدّات ببجي 60", Status: control.CustomerOrderDelivered}
	if message, _ := customerOrderMessage(order, true); message.Title != "تمّ الشحن" || message.Body != "شدّات ببجي 60 وصل إلى حسابك." {
		t.Fatalf("account: %+v", message)
	}
	order.Status = control.CustomerOrderFulfilling
	if _, ok := customerOrderMessage(order, false); ok {
		t.Fatal("an order still on its way has nothing to tell")
	}
}
