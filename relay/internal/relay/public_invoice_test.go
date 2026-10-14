package relay

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

// The invoice exactly as the backend's JSON renderer sends it: decimals as
// floats, the time in the shop's own offset.
const publicInvoiceBackendJSON = `{
	"shop_name": "متجر",
	"receipt_number": "INV-1",
	"status": "paid",
	"created_at": "2026-10-12T14:32:05.123456+02:00",
	"subtotal": "1046.00",
	"discount_total": "8.00",
	"extra_discount_amount": "3.00",
	"total": "1038.00",
	"lines": [
		{"product_name": "جبنة", "variant_name": "", "quantity": 1.25, "unit_label": "كغ",
		 "unit_price": "32.00", "line_subtotal": "40.00", "discount_total": "0.00", "line_total": "40.00",
		 "modifiers": [], "identifiers": []},
		{"product_name": "هاتف", "variant_name": "هاتف - 128GB", "quantity": 1.0, "unit_label": "قطعة",
		 "unit_price": "850.00", "line_subtotal": "850.00", "discount_total": "0.00", "line_total": "850.00",
		 "modifiers": [],
		 "identifiers": [{"kind": "unit", "code": "356938035643809", "expiry_date": "", "warranty_expires_on": "2027-10-12"}]},
		{"product_name": "دواء", "variant_name": "", "quantity": 2.0, "unit_label": "علبة",
		 "unit_price": "40.00", "line_subtotal": "80.00", "discount_total": "0.00", "line_total": "80.00",
		 "modifiers": [],
		 "identifiers": [{"kind": "batch", "code": "L-77", "expiry_date": "2027-08-31"}]},
		{"product_name": "شاورما", "variant_name": "", "quantity": 2.0, "unit_label": "",
		 "unit_price": "14.50", "line_subtotal": "29.00", "discount_total": "0.00", "line_total": "29.00",
		 "modifiers": [{"group_name": "إضافات", "name": "جبنة", "quantity": 2, "price_delta": "1.00"},
		               {"group_name": "", "name": "بدون بصل", "quantity": 1, "price_delta": "0.00"}],
		 "identifiers": []}
	]
}`

func renderBackendInvoice(t *testing.T, raw string) (string, string) {
	t.Helper()
	var payload publicInvoicePayload
	if err := json.Unmarshal([]byte(raw), &payload); err != nil {
		t.Fatalf("the backend's own invoice JSON must decode: %v", err)
	}
	recorder := httptest.NewRecorder()
	HTTPServer{}.renderPublicInvoice(recorder, payload)
	return recorder.Body.String(), recorder.Header().Get("Content-Security-Policy")
}

func TestPublicInvoiceRendersWhatTheReceiptPrints(t *testing.T) {
	body, csp := renderBackendInvoice(t, publicInvoiceBackendJSON)
	for _, expected := range []string{
		`<bdi dir="ltr">1.25</bdi> <span class="unit">كغ</span>`,
		`<bdi dir="ltr">1</bdi> <span class="unit">قطعة</span>`,
		// On a phone a line reads "1 قطعة × 850.00" under its name.
		`<div class="mqty"><bdi dir="ltr">1</bdi> قطعة × <bdi dir="ltr">850.00</bdi></div>`,
		`<span class="pill ok">مدفوعة</span>`,
		`<bdi dir="ltr" class="code">356938035643809</bdi>`,
		`ضمان حتى <bdi dir="ltr" class="code">2027/10/12</bdi>`,
		`دفعة: <bdi dir="ltr" class="code">L-77</bdi> — صلاحية حتى 08/2027`,
		"إضافات: جبنة ×2 (1.00)، بدون بصل",
		"2026/10/12 14:32",
		`<span>الخصم</span><span class="num">5.00</span>`,
		`<span>خصم إضافي</span><span class="num">3.00</span>`,
		"دُوّن في",
		`<img src="data:image/png;base64,`,
	} {
		if !strings.Contains(body, expected) {
			t.Errorf("expected invoice to contain %q", expected)
		}
	}
	for _, unexpected := range []string{">1.0<", ">2.0<", "صُنع بحب", "Pointy"} {
		if strings.Contains(body, unexpected) {
			t.Errorf("invoice must not contain %q", unexpected)
		}
	}
	if !strings.Contains(csp, "img-src data:") {
		t.Errorf("the page's own data: images must be allowed, got CSP %q", csp)
	}
}

func TestKeepNumbersWholeOnlyJoinsDigitRuns(t *testing.T) {
	got := keepNumbersWhole("طرابلس - شارع 1 · 091-1234567")
	if want := "طرابلس - شارع 1 · 091\u20111234567"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestPublicInvoiceHidesDiscountRowsWhenThereIsNone(t *testing.T) {
	body, _ := renderBackendInvoice(t, `{
		"shop_name": "متجر", "receipt_number": "INV-2", "status": "paid",
		"created_at": "not a date", "subtotal": "5.00", "discount_total": "0.00",
		"total": "5.00", "lines": [{"product_name": "ماء", "quantity": 5,
		"unit_price": "1.00", "line_subtotal": "5.00", "discount_total": "0.00", "line_total": "5.00"}]
	}`)
	if strings.Contains(body, "الخصم") || strings.Contains(body, "خصم إضافي") {
		t.Error("an invoice with no discount must not print a discount row")
	}
	// An older backend sends no extras, identifiers or unit: still renders.
	if !strings.Contains(body, `<bdi dir="ltr">5</bdi></td>`) || !strings.Contains(body, "not a date") {
		t.Errorf("expected the plain line and the raw date, got %s", body)
	}
}
