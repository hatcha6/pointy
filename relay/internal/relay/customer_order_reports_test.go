package relay

import (
	"context"
	"net/http"
	"testing"

	"pointy/relay/internal/control"
)

func TestACustomerReportsAnOrderAndHearsTheReply(t *testing.T) {
	h := newOrderHarness(t)
	pusher := &fakePusher{}
	h.server.CustomerPush = pusher
	token := h.customer("0911111111")
	if status, _ := h.do(http.MethodPut, "/v1/customers/me/push", token, map[string]any{"token": "phone-1"}); status != http.StatusNoContent {
		t.Fatalf("register: %d", status)
	}
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 1))
	id := orderOf(t, body)["id"].(string)

	// Not paid yet: nothing to report.
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/report", token,
		map[string]any{"reason": "not_arrived"})
	if status != http.StatusConflict || body["code"] != "nothing_to_report" {
		t.Fatalf("unpaid: %d %v", status, body)
	}
	_, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	if order := orderOf(t, body); order["status"] != "delivered" {
		t.Fatalf("paid: %v", body)
	}
	if _, has := orderOf(t, body)["report"]; has {
		t.Fatal("an order no one reported carries a report")
	}

	if status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/report", token,
		map[string]any{"reason": "made_up"}); status != http.StatusBadRequest {
		t.Fatalf("unknown reason: %d %v", status, body)
	}
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/report", token,
		map[string]any{"reason": "not_arrived", "note": "  لم يظهر في اللعبة  "})
	report, _ := body["report"].(map[string]any)
	if status != http.StatusCreated || report["status"] != "open" || report["note"] != "لم يظهر في اللعبة" {
		t.Fatalf("report: %d %v", status, body)
	}
	// A second tap files nothing new.
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/report", token,
		map[string]any{"reason": "other"})
	if again, _ := body["report"].(map[string]any); status != http.StatusOK || again["id"] != report["id"] ||
		again["reason"] != "not_arrived" {
		t.Fatalf("again: %d %v", status, body)
	}
	// Someone else's order is not theirs to report.
	other := h.customer("0922222222")
	if status, _ := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/report", other,
		map[string]any{"reason": "other"}); status != http.StatusNotFound {
		t.Fatalf("another customer: %d", status)
	}

	// The order the customer reads carries it.
	_, body = h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	if shown, _ := orderOf(t, body)["report"].(map[string]any); shown["id"] != report["id"] || shown["reply"] != nil {
		t.Fatalf("read: %v", body)
	}

	// The operator sees it beside its order, and answers.
	status, body = h.do(http.MethodGet, "/v1/customers/admin/reports?status=open", "admin-token", nil)
	list, _ := body["reports"].([]any)
	if status != http.StatusOK || len(list) != 1 {
		t.Fatalf("admin list: %d %v", status, body)
	}
	first := list[0].(map[string]any)
	if first["order"] == nil || first["report"].(map[string]any)["id"] != report["id"] {
		t.Fatalf("admin view: %v", first)
	}
	status, body = h.do(http.MethodPost, "/v1/customers/admin/reports/"+report["id"].(string)+"/resolve", "admin-token",
		map[string]any{"reply": "أعدنا الشحن، تحقق الآن.", "actor": "Hatem"})
	if resolved, _ := body["report"].(map[string]any); status != http.StatusOK || resolved["status"] != "resolved" ||
		resolved["resolved_by"] != "Hatem" {
		t.Fatalf("resolve: %d %v", status, body)
	}
	pusher.mu.Lock()
	last, count := pusher.last, len(pusher.tokens)
	pusher.mu.Unlock()
	if count != 1 || last.Title != "ردّنا على بلاغك" || last.Body != "أعدنا الشحن، تحقق الآن." || last.Order != id {
		t.Fatalf("told %d: %+v", count, last)
	}
	// Resolving again tells no one twice.
	h.do(http.MethodPost, "/v1/customers/admin/reports/"+report["id"].(string)+"/resolve", "admin-token",
		map[string]any{"reply": "x"})
	pusher.mu.Lock()
	count = len(pusher.tokens)
	pusher.mu.Unlock()
	if count != 1 {
		t.Fatalf("told again: %d", count)
	}

	// The customer sees the reply, never who wrote it.
	_, body = h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	shown, _ := orderOf(t, body)["report"].(map[string]any)
	if shown["status"] != "resolved" || shown["reply"] != "أعدنا الشحن، تحقق الآن." || shown["resolved_by"] != nil {
		t.Fatalf("read after: %v", shown)
	}
	// Resolved, a new problem may be reported.
	if status, _ := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/report", token,
		map[string]any{"reason": "wrong_amount"}); status != http.StatusCreated {
		t.Fatalf("report again: %d", status)
	}

	// A deleted account takes its reports with it.
	if status, _ := h.do(http.MethodDelete, "/v1/customers/me", token, nil); status != http.StatusNoContent {
		t.Fatalf("delete: %d", status)
	}
	if left, _ := h.store.CustomerOrderReports(context.Background(), id); len(left) != 0 {
		t.Fatalf("reports kept: %+v", left)
	}
}

func TestReportStoreKeepsOneOpenReportPerOrder(t *testing.T) {
	h := newOrderHarness(t)
	ctx := context.Background()
	first, created, err := h.store.ReportCustomerOrder(ctx, control.CustomerOrderReport{
		OrderID: "o-1", CustomerID: "c-1", Reason: control.CustomerReportWrongAccount})
	if err != nil || !created {
		t.Fatalf("first: %v %v", created, err)
	}
	second, created, err := h.store.ReportCustomerOrder(ctx, control.CustomerOrderReport{
		OrderID: "o-1", CustomerID: "c-1", Reason: control.CustomerReportOther})
	if err != nil || created || second.ID != first.ID {
		t.Fatalf("second: %+v %v %v", second, created, err)
	}
	if _, _, err := h.store.ReportCustomerOrder(ctx, control.CustomerOrderReport{
		OrderID: "o-2", CustomerID: "c-1", Reason: "nope"}); err == nil {
		t.Fatal("an unknown reason was filed")
	}
}
