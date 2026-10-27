package relay

import (
	"context"
	"net/http"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/fcm"
)

type fakePusher struct {
	mu     sync.Mutex
	topics []string
	tokens []string
	last   fcm.Message
	dead   map[string]bool
}

func (p *fakePusher) SendTopic(_ context.Context, topic string, message fcm.Message) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.topics = append(p.topics, topic)
	p.last = message
	return nil
}

func (p *fakePusher) SendToken(_ context.Context, token string, message fcm.Message) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.dead[token] {
		return fcm.ErrUnregistered
	}
	p.tokens = append(p.tokens, token)
	p.last = message
	return nil
}

func customerIDOf(t *testing.T, h *orderHarness, token string) string {
	t.Helper()
	_, me := h.do(http.MethodGet, "/v1/customers/me", token, nil)
	return me["customer"].(map[string]any)["id"].(string)
}

func TestTheConsoleSeesCustomersAndTheirOrders(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	id := customerIDOf(t, h, token)
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 1)); status != http.StatusCreated {
		t.Fatalf("order: %d %v", status, body)
	}

	// Only the admin token reads them.
	if status, _ := h.do(http.MethodGet, "/v1/customers/admin/customers", token, nil); status != http.StatusUnauthorized {
		t.Fatalf("a customer's token read the list: %d", status)
	}
	status, list := h.do(http.MethodGet, "/v1/customers/admin/customers?q=091-111", "admin-token", nil)
	customers := list["customers"].([]any)
	if status != http.StatusOK || list["total"] != float64(1) || customers[0].(map[string]any)["id"] != id {
		t.Fatalf("list: %d %v", status, list)
	}
	status, detail := h.do(http.MethodGet, "/v1/customers/admin/customers/"+id, "admin-token", nil)
	if status != http.StatusOK || len(detail["orders"].([]any)) != 1 || len(detail["sessions"].([]any)) != 1 {
		t.Fatalf("detail: %d %v", status, detail)
	}
	session := detail["sessions"].([]any)[0].(map[string]any)
	if session["push"] != false || session["access_hash"] != nil {
		t.Fatalf("session view: %v", session)
	}
	status, orders := h.do(http.MethodGet, "/v1/customers/admin/orders?status=open&q=libyana", "admin-token", nil)
	rows := orders["orders"].([]any)
	if status != http.StatusOK || len(rows) != 1 || rows[0].(map[string]any)["customer_phone"] != "218911111111" {
		t.Fatalf("orders: %d %v", status, orders)
	}
	orderID := rows[0].(map[string]any)["id"].(string)
	if status, one := h.do(http.MethodGet, "/v1/customers/admin/orders/"+orderID, "admin-token", nil); status != http.StatusOK ||
		one["order"].(map[string]any)["customer_phone"] != "218911111111" {
		t.Fatalf("order: %d %v", status, one)
	}
	if status, summary := h.do(http.MethodGet, "/v1/customers/admin/summary", "admin-token", nil); status != http.StatusOK ||
		summary["stats"].(map[string]any)["customers"] != float64(1) || summary["push_configured"] != false {
		t.Fatalf("summary: %d %v", status, summary)
	}
}

func TestCreditAndStoppingAnAccount(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	id := customerIDOf(t, h, token)

	adjust := map[string]any{"amount": "7.5", "note": "تعويض عن طلب", "key": "k-1"}
	status, body := h.do(http.MethodPost, "/v1/customers/admin/customers/"+id+"/credit", "admin-token", adjust)
	if status != http.StatusOK || body["balance"] != "7.500" || body["created"] != true {
		t.Fatalf("grant: %d %v", status, body)
	}
	if status, body := h.do(http.MethodPost, "/v1/customers/admin/customers/"+id+"/credit", "admin-token",
		map[string]any{"amount": "-10", "note": "خطأ", "key": "k-2"}); status != http.StatusConflict || body["code"] != "insufficient_credit" {
		t.Fatalf("overdraw: %d %v", status, body)
	}
	if status, body := h.do(http.MethodGet, "/v1/customers/credit", token, nil); status != http.StatusOK || body["balance"] != "7.500" {
		t.Fatalf("the customer's own credit: %d %v", status, body)
	}

	if status, _ := h.do(http.MethodPost, "/v1/customers/admin/customers/"+id+"/block", "admin-token",
		map[string]any{"blocked": true}); status != http.StatusBadRequest {
		t.Fatalf("a stop without a reason: %d", status)
	}
	if status, body := h.do(http.MethodPost, "/v1/customers/admin/customers/"+id+"/block", "admin-token",
		map[string]any{"blocked": true, "reason": "احتيال"}); status != http.StatusOK {
		t.Fatalf("block: %d %v", status, body)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/me", token, nil); status != http.StatusUnauthorized {
		t.Fatalf("a stopped account kept its session: %d", status)
	}
	h.clock.advance(2 * time.Minute)
	_, otp := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0911111111"})
	status, refused := h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{"phone": "0911111111", "code": otp["test_code"]})
	if status != http.StatusForbidden || refused["code"] != "account_blocked" {
		t.Fatalf("blocked sign-in: %d %v", status, refused)
	}
	h.do(http.MethodPost, "/v1/customers/admin/customers/"+id+"/block", "admin-token", map[string]any{"blocked": false})
	h.clock.advance(2 * time.Minute)
	h.customer("0911111111")

	if status, _ := h.do(http.MethodDelete, "/v1/customers/admin/customers/"+id, "admin-token", nil); status != http.StatusNoContent {
		t.Fatalf("delete: %d", status)
	}
	if status, body := h.do(http.MethodGet, "/v1/customers/admin/customers/"+id, "admin-token", nil); status != http.StatusOK ||
		body["customer"].(map[string]any)["deleted_at"] == nil {
		t.Fatalf("deleted: %d %v", status, body)
	}
}

func TestNotificationsReachEveryoneOrOneCustomer(t *testing.T) {
	h := newOrderHarness(t)
	if status, body := h.do(http.MethodPost, "/v1/customers/admin/notifications", "admin-token",
		map[string]any{"audience": "all", "title": "t", "body": "b"}); status != http.StatusServiceUnavailable || body["code"] != "push_unconfigured" {
		t.Fatalf("unconfigured: %d %v", status, body)
	}
	pusher := &fakePusher{dead: map[string]bool{"old-phone": true}}
	h.server.CustomerPush = pusher

	token := h.customer("0911111111")
	id := customerIDOf(t, h, token)
	if status, _ := h.do(http.MethodPut, "/v1/customers/me/push", token, map[string]any{"token": "new-phone"}); status != http.StatusNoContent {
		t.Fatalf("register: %d", status)
	}
	h.clock.advance(2 * time.Minute)
	second := h.customer("0911111111")
	h.do(http.MethodPut, "/v1/customers/me/push", second, map[string]any{"token": "old-phone"})

	notify := map[string]any{"audience": "customer", "customer_id": id, "title": "رصيدك جاهز", "body": "أضفنا ٥ دنانير",
		"link": "https://cards.dftr.ly/my-cards", "campaign": "credit"}
	status, body := h.do(http.MethodPost, "/v1/customers/admin/notifications", "admin-token", notify)
	sent := body["notification"].(map[string]any)
	if status != http.StatusOK || sent["devices"] != float64(2) || sent["sent"] != float64(1) || sent["failed"] != float64(1) {
		t.Fatalf("customer send: %d %v", status, body)
	}
	if len(pusher.tokens) != 1 || pusher.tokens[0] != "new-phone" || pusher.last.Link != "https://cards.dftr.ly/my-cards" {
		t.Fatalf("pushed = %+v", pusher)
	}
	// The dead phone's token was forgotten.
	_, detail := h.do(http.MethodGet, "/v1/customers/admin/customers/"+id, "admin-token", nil)
	if detail["customer"].(map[string]any)["push_devices"] != float64(1) {
		t.Fatalf("dead token kept: %v", detail["customer"])
	}

	if status, body := h.do(http.MethodPost, "/v1/customers/admin/notifications", "admin-token",
		map[string]any{"audience": "apk", "title": "عرض", "body": "خصم على الألعاب"}); status != http.StatusOK ||
		len(pusher.topics) != 1 || pusher.topics[0] != "apk" {
		t.Fatalf("topic send: %d %v %v", status, body, pusher.topics)
	}
	for _, bad := range []map[string]any{
		{"audience": "everyone", "title": "t", "body": "b"},
		{"audience": "all", "title": "", "body": "b"},
		{"audience": "all", "title": "t", "body": "b", "link": "https://evil.example/x"},
		{"audience": "all", "title": "t", "body": "b", "link": "http://cards.dftr.ly/x"},
	} {
		if status, _ := h.do(http.MethodPost, "/v1/customers/admin/notifications", "admin-token", bad); status != http.StatusBadRequest {
			t.Fatalf("%v: %d", bad, status)
		}
	}
	other := h.customer("0922222222")
	if status, body := h.do(http.MethodPost, "/v1/customers/admin/notifications", "admin-token",
		map[string]any{"audience": "customer", "customer_id": customerIDOf(t, h, other), "title": "t", "body": "b"}); status != http.StatusConflict ||
		body["code"] != "no_devices" {
		t.Fatalf("no devices: %d %v", status, body)
	}

	_, log := h.do(http.MethodGet, "/v1/customers/admin/notifications", "admin-token", nil)
	if notes := log["notifications"].([]any); len(notes) != 2 || log["push_configured"] != true {
		t.Fatalf("log = %v", log)
	}
	_, mine := h.do(http.MethodGet, "/v1/customers/admin/notifications?customer="+id, "admin-token", nil)
	if notes := mine["notifications"].([]any); len(notes) != 1 || notes[0].(map[string]any)["campaign"] != "credit" {
		t.Fatalf("customer's log = %v", mine)
	}
}
