package relay

import (
	"context"
	"net/http"
	"testing"
	"time"

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
	// later moves the clock past the app's waiting page.
	later := func() {
		h.clock.mu.Lock()
		h.clock.now = h.clock.now.Add(customerOrderWaitWindow + time.Second)
		h.clock.mu.Unlock()
	}
	delivered := func(supplierOrder string) {
		h.supplier.mu.Lock()
		h.supplier.lookups[supplierOrder] = vouchers.Purchase{OrderID: supplierOrder, Status: vouchers.StatusSucceeded,
			Cost: "9.70", Currency: "USD", Codes: []vouchers.Code{{Code: "1234-5678-9012"}}}
		h.supplier.mu.Unlock()
	}

	// Done in seconds, by the sweep or a supplier's webhook rather than the
	// app's own read: the waiting page shows it, and the phone stays quiet.
	quick := slowOrder("o-quick", "900")
	delivered("900")
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	if order, _ := h.store.GetCustomerOrder(context.Background(), quick); order.Status != control.CustomerOrderDelivered {
		t.Fatalf("after the sweep: %+v", order)
	}
	if sent() != 0 {
		t.Fatal("an order done within the wait was pushed")
	}

	// The customer walked away: the sweep finds the code past the wait, and
	// the phone hears.
	away := slowOrder("o-away", "901")
	if sent() != 0 {
		t.Fatal("told before the code came")
	}
	later()
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
	later()
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
	order := control.CustomerOrder{ID: "ord-1", ItemName: "شدّات ببجي 60", BrandKey: "tu-pubg", Status: control.CustomerOrderDelivered}
	if message, _ := customerOrderMessage(order, true); message.Title != "تمّ الشحن" || message.Body != "شدّات ببجي 60 وصل إلى حساب اللاعب." {
		t.Fatalf("game: %+v", message)
	}
	// Each top-up names the account as the customer knows it.
	cases := []struct{ brand, item, title, body string }{
		{"tg-stars", "100 نجمة", "تمّ الشحن", "100 نجمة وصل إلى حساب تيليجرام."},
		{"steam-wallet", "رصيد ستيم 10$", "أُضيف الرصيد", "رصيد ستيم 10$ أُضيف إلى محفظة ستيم."},
		{"sg-palworld", "Palworld", "أُرسلت الهدية", "اقبل طلب الصداقة في ستيم لتصلك Palworld."},
	}
	for _, c := range cases {
		order := control.CustomerOrder{ID: "ord-2", ItemName: c.item, BrandKey: c.brand, Status: control.CustomerOrderDelivered}
		if message, _ := customerOrderMessage(order, true); message.Title != c.title || message.Body != c.body {
			t.Errorf("%s delivered: %+v", c.brand, message)
		}
	}
	// A top-up that failed is never «a card that could not be delivered».
	failed := control.CustomerOrder{ID: "ord-3", ItemName: "100 نجمة", BrandKey: "tg-stars",
		Account: map[string]string{"username": "someone"}, Status: control.CustomerOrderRefunded}
	if message, _ := customerOrderMessage(failed, false); message.Title != "تعذّر الشحن" ||
		message.Body != "لم يصل 100 نجمة إلى حساب تيليجرام، وأعدنا المبلغ إلى رصيدك." {
		t.Fatalf("telegram refund: %+v", message)
	}
	failed.BrandKey, failed.ItemName = "sg-palworld", "Palworld"
	if message, _ := customerOrderMessage(failed, false); message.Title != "تعذّر إرسال الهدية" {
		t.Fatalf("gift refund: %+v", message)
	}
	card := control.CustomerOrder{ID: "ord-4", ItemName: "ليبيانا 10", BrandKey: "libyana", Status: control.CustomerOrderRefunded}
	if message, _ := customerOrderMessage(card, false); message.Title != "تعذّر تسليم بطاقتك" {
		t.Fatalf("card refund: %+v", message)
	}
	order.Status = control.CustomerOrderFulfilling
	if _, ok := customerOrderMessage(order, false); ok {
		t.Fatal("an order still on its way has nothing to tell")
	}
}

func TestOnlyAnOrderThatOutlastedTheWaitIsPushed(t *testing.T) {
	placed := time.Date(2026, 11, 7, 10, 0, 0, 0, time.UTC)
	at := func(d time.Duration) *time.Time { moment := placed.Add(d); return &moment }
	cases := []struct {
		name  string
		order control.CustomerOrder
		now   time.Time
		quiet bool
	}{
		{"a top-up done in seconds", control.CustomerOrder{CreatedAt: placed, PaidAt: at(20 * time.Second),
			CompletedAt: at(25 * time.Second)}, placed.Add(time.Minute), true},
		{"just inside the wait", control.CustomerOrder{CreatedAt: placed, PaidAt: at(0),
			CompletedAt: at(customerOrderWaitWindow - time.Second)}, placed.Add(time.Hour), true},
		{"past the wait", control.CustomerOrder{CreatedAt: placed, PaidAt: at(0),
			CompletedAt: at(customerOrderWaitWindow + time.Second)}, placed.Add(time.Hour), false},
		// Counted from payment: a slow payment does not eat the wait.
		{"paid late, done at once", control.CustomerOrder{CreatedAt: placed, PaidAt: at(10 * time.Minute),
			CompletedAt: at(10*time.Minute + 30*time.Second)}, placed.Add(time.Hour), true},
		// The customer's credit paid: counted from the order.
		{"credit, past the wait", control.CustomerOrder{CreatedAt: placed,
			CompletedAt: at(5 * time.Minute)}, placed.Add(time.Hour), false},
	}
	for _, c := range cases {
		if got := endedWithinTheWait(c.order, c.now); got != c.quiet {
			t.Errorf("%s: quiet = %v, want %v", c.name, got, c.quiet)
		}
	}
}

// The app's waiting page takes its wait from every order, so the relay's
// push rule and the page can never disagree.
func TestEveryOrderTellsTheAppHowLongToWait(t *testing.T) {
	payload := customerOrderPayload(control.CustomerOrder{ID: "ord-1"}, nil, false)
	if payload["wait_seconds"] != int(customerOrderWaitWindow/time.Second) {
		t.Fatalf("wait_seconds = %v", payload["wait_seconds"])
	}
}
