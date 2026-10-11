package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

func companyCardRequest(t *testing.T, fields map[string]any) []byte {
	t.Helper()
	request := map[string]any{"item": "itunes-us-10", "quantity": 1, "idempotency_key": "company-1",
		"purpose": "own_use", "note": "اشتراك", "actor": "هاتم"}
	for key, value := range fields {
		request[key] = value
	}
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestTheCompanyBuysACardForItself(t *testing.T) {
	h := newVoucherHarness(t)
	shop := h.provision(t)
	h.publish(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "100")

	if status, body := h.admin(t, http.MethodPost, "/v1/vouchers/admin/company/cards", "application/json",
		companyCardRequest(t, map[string]any{"purpose": ""})); status != http.StatusBadRequest {
		t.Fatalf("a purchase with no purpose is refused: %d %v", status, body)
	}

	status, body := h.admin(t, http.MethodPost, "/v1/vouchers/admin/company/cards", "application/json", companyCardRequest(t, nil))
	if status != http.StatusCreated {
		t.Fatalf("company purchase: %d %v", status, body)
	}
	purchase := body["purchase"].(map[string]any)
	codes := purchase["codes"].([]any)
	if purchase["status"] != "succeeded" || len(codes) != 1 || codes[0].(map[string]any)["code"] != "1234-5678-9012" {
		t.Fatalf("purchase: %v", purchase)
	}
	if body["balance"] != "" || h.voucherBalance(t, shop.Installation.ID) != "100.000" {
		t.Fatalf("no wallet pays for the company's card: %v, shop %s", body["balance"], h.voucherBalance(t, shop.Installation.ID))
	}
	id := purchase["id"].(string)

	// Asked again with the same key: nothing is bought twice.
	status, replay := h.admin(t, http.MethodPost, "/v1/vouchers/admin/company/cards", "application/json", companyCardRequest(t, nil))
	if status != http.StatusOK || replay["replayed"] != true || len(h.supplier.calls()) != 1 {
		t.Fatalf("replay: %d %v", status, replay)
	}

	status, listed := h.admin(t, http.MethodGet, "/v1/vouchers/admin/purchases?buyer=company", "", nil)
	rows, _ := listed["purchases"].([]any)
	if status != http.StatusOK || len(rows) != 1 {
		t.Fatalf("company listing: %d %v", status, listed)
	}
	if row := rows[0].(map[string]any); row["purpose"] != "own_use" || row["note"] != "اشتراك" ||
		row["requested_by"] != "هاتم" || row["installation_id"] != "" {
		t.Fatalf("company row: %v", row)
	}

	status, revealed := h.admin(t, http.MethodPost, "/v1/vouchers/admin/company/purchases/"+id+"/reveal", "application/json", nil)
	if status != http.StatusOK {
		t.Fatalf("reveal: %d %v", status, revealed)
	}
	if got := revealed["purchase"].(map[string]any)["codes"].([]any); len(got) != 1 {
		t.Fatalf("reveal reads the codes back: %v", revealed)
	}

	// A shop's codes are never shown to an operator.
	h.supplier.mu.Lock()
	h.supplier.buyResult.OrderID = "452"
	h.supplier.mu.Unlock()
	status, sale := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken,
		purchaseRequest("itunes-us-10", "sale-1", "50.00"))
	if status != http.StatusCreated {
		t.Fatalf("shop purchase: %d %v", status, sale)
	}
	shopID := sale["purchase"].(map[string]any)["id"].(string)
	if status, _ := h.admin(t, http.MethodPost, "/v1/vouchers/admin/company/purchases/"+shopID+"/reveal", "application/json", nil); status != http.StatusForbidden {
		t.Fatalf("a shop's purchase is not revealed: %d", status)
	}

	// On the books the company's card is its own spending, not the cards'
	// cost of sale.
	months, err := h.store.FinanceTracked(context.Background(), h.now.Add(-24*time.Hour), h.now.Add(24*time.Hour))
	if err != nil || len(months) != 1 {
		t.Fatalf("tracked: %+v err=%v", months, err)
	}
	if months[0].CompanyCost["USD"] != "9.700" || months[0].SupplierCost["USD"] != "9.700" {
		t.Fatalf("company %v, supplier %v", months[0].CompanyCost, months[0].SupplierCost)
	}
}
