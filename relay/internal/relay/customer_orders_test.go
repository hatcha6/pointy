package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/vouchers"
)

type orderHarness struct {
	t        *testing.T
	clock    *settingsClock
	store    *control.FileStore
	supplier *fakeSupplier
	dafa     *fakeDafa
	cards    *voucherHarness
	server   HTTPServer
}

func newOrderHarness(t *testing.T) *orderHarness {
	t.Helper()
	clock := &settingsClock{now: time.Date(2026, 10, 7, 10, 0, 0, 0, time.UTC)}
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	supplier := newFakeSupplier()
	fake := newFakeDafa(t)
	h := &orderHarness{t: t, clock: clock, store: store, supplier: supplier, dafa: fake}
	h.server = HTTPServer{
		Store:      store,
		Hub:        NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:    observability.NewMetrics(),
		Clock:      clock,
		RouteMode:  RouteAll,
		AdminToken: "admin-token",
		Vouchers: VoucherConfig{
			Suppliers:      map[string]vouchers.Supplier{vouchers.SupplierBNPlus: supplier},
			RequestTimeout: 5 * time.Second,
		},
		VoucherCache: &VoucherCatalogCache{},
		Wallet: WalletConfig{
			DafaBaseURL:    fake.server.URL,
			DafaAPIKey:     walletTestKey,
			TestMode:       true,
			PublicURL:      walletTestPublic,
			RequestTimeout: 2 * time.Second,
		},
		Customers: CustomerConfig{TestMode: true},
	}
	h.cards = &voucherHarness{server: h.server, store: store, supplier: supplier, now: clock.now}
	h.cards.publish(t)
	return h
}

func (h *orderHarness) do(method, target, bearer string, body any) (int, map[string]any) {
	h.t.Helper()
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	request := httptest.NewRequest(method, "http://relay.test"+target, bytes.NewReader(raw))
	request.RemoteAddr = "203.0.113.9:4000"
	if bearer != "" {
		request.Header.Set("Authorization", "Bearer "+bearer)
	}
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	return recorder.Code, decodeBody(h.t, recorder)
}

// customer signs a phone in and returns its access token.
func (h *orderHarness) customer(phone string) string {
	h.t.Helper()
	_, otp := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": phone})
	status, signed := h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{"phone": phone, "code": otp["test_code"]})
	if status != http.StatusOK {
		h.t.Fatalf("sign-in: %d %v", status, signed)
	}
	return signed["access_token"].(string)
}

func sadadOrder(item, price, key string, quantity int) map[string]any {
	return map[string]any{
		"item": item, "quantity": quantity, "unit_price": price, "idempotency_key": key, "channel": "apk",
		"method": "dafa_sadad", "user_identifier": "0912345678", "birth_year": "1990",
	}
}

func orderOf(t *testing.T, body map[string]any) map[string]any {
	t.Helper()
	order, ok := body["order"].(map[string]any)
	if !ok {
		t.Fatalf("no order in %v", body)
	}
	return order
}

func (h *orderHarness) credit(token string) string {
	h.t.Helper()
	_, body := h.do(http.MethodGet, "/v1/customers/credit", token, nil)
	return body["balance"].(string)
}

func TestCustomerCatalogIsPublicRetailAndNarrowedForIOS(t *testing.T) {
	h := newOrderHarness(t)
	status, apk := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk", "", nil)
	if status != http.StatusOK || len(apk["brands"].([]any)) != 2 {
		t.Fatalf("apk catalog: %d %v", status, apk)
	}
	raw, _ := json.Marshal(apk)
	if strings.Contains(string(raw), "unit_price") || strings.Contains(string(raw), "52.00") {
		t.Fatalf("the catalog leaks what a shop pays: %s", raw)
	}
	itunes := apk["brands"].([]any)[0].(map[string]any)
	if itunes["key"] != "itunes" || itunes["items"].([]any)[0].(map[string]any)["price"] != "60.00" {
		t.Fatalf("itunes = %v", itunes)
	}

	_, ios := h.do(http.MethodGet, "/v1/customers/catalog?channel=ios", "", nil)
	brands := ios["brands"].([]any)
	if len(brands) != 1 || brands[0].(map[string]any)["key"] != "libyana" || len(ios["categories"].([]any)) != 1 {
		t.Fatalf("ios must see the telecom shelf only: %v", ios)
	}
	if ios["version"] == apk["version"] {
		t.Fatal("two channels share a version")
	}

	request := httptest.NewRequest(http.MethodGet, "http://relay.test/v1/customers/catalog?channel=ios", nil)
	request.Header.Set("If-None-Match", `"`+ios["version"].(string)+`"`)
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNotModified {
		t.Fatalf("etag: %d", recorder.Code)
	}
	if status, _ := h.do(http.MethodGet, "/v1/customers/catalog?channel=windows", "", nil); status != http.StatusBadRequest {
		t.Fatalf("unknown channel: %d", status)
	}
	logo := strings.TrimPrefix(itunes["logo"].(string), vouchers.ImagePrefix)
	request = httptest.NewRequest(http.MethodGet, "http://relay.test/v1/customers/images/"+logo, nil)
	recorder = httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK || recorder.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("public logo: %d %s", recorder.Code, recorder.Header().Get("Content-Type"))
	}
}

func TestCustomerOrderPaidWithSadadIsDelivered(t *testing.T) {
	h := newOrderHarness(t)
	h.supplier.buyResult.Codes = append(h.supplier.buyResult.Codes, vouchers.Code{Code: "2222-3333-4444", Serial: "SN-2"})
	// A live gateway, so the sale reaches the books.
	h.server.Wallet.TestMode, h.dafa.testWorkspace = false, false
	token := h.customer("0911111111")

	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 2))
	order := orderOf(t, body)
	if status != http.StatusCreated || order["status"] != "awaiting_payment" || order["next_action"] != "otp" ||
		order["amount_due"] != "20.000" || order["payer_hint"] == "" {
		t.Fatalf("create: %d %v", status, body)
	}
	if initiated := h.dafa.initiated(0); initiated["amount"] != "20.000" ||
		!strings.Contains(initiated["callback_url"].(string), "/v1/customers/dafa/webhook/") {
		t.Fatalf("dafa was asked for %v", initiated)
	}
	if len(h.supplier.calls()) != 0 {
		t.Fatal("a card was bought before the payment")
	}
	id := order["id"].(string)

	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "999999"})
	if status != http.StatusUnprocessableEntity || body["code"] != walletCodeOTPRejected || body["attempts_left"] != float64(maxWalletOTPAttempts-1) {
		t.Fatalf("wrong code: %d %v", status, body)
	}
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	order = orderOf(t, body)
	codes := order["codes"].([]any)
	if status != http.StatusOK || order["status"] != "delivered" || len(codes) != 2 {
		t.Fatalf("confirm: %d %v", status, body)
	}
	if calls := h.supplier.calls(); len(calls) != 1 || calls[0].Quantity != 2 {
		t.Fatalf("supplier calls = %+v", calls)
	}
	purchases, _ := h.store.ListVoucherPurchases(context.Background(), control.VoucherPurchaseFilter{Buyer: control.VoucherBuyerCustomers})
	if len(purchases) != 1 || purchases[0].Note != id || purchases[0].UnitPrice != "10.000" {
		t.Fatalf("customer purchases = %+v", purchases)
	}
	if company, _ := h.store.ListVoucherPurchases(context.Background(), control.VoucherPurchaseFilter{Buyer: control.VoucherBuyerCompany}); len(company) != 0 {
		t.Fatal("a customer's card is listed as the company's own")
	}

	// Reading the order back re-reads its codes; the list does not.
	_, body = h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	if got := orderOf(t, body)["codes"].([]any); len(got) != 2 {
		t.Fatalf("read back: %v", body)
	}
	_, list := h.do(http.MethodGet, "/v1/customers/orders", token, nil)
	if orders := list["orders"].([]any); len(orders) != 1 || len(orders[0].(map[string]any)["codes"].([]any)) != 0 {
		t.Fatalf("list: %v", list)
	}

	// Another customer cannot see it.
	other := h.customer("0922222222")
	if status, _ := h.do(http.MethodGet, "/v1/customers/orders/"+id, other, nil); status != http.StatusNotFound {
		t.Fatalf("another customer read the order: %d", status)
	}

	// It is a sale on the books, at the customer's price and the supplier's cost.
	h.clock.advance(time.Hour)
	months, err := h.store.FinanceTracked(context.Background(), time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC))
	if err != nil || len(months) != 1 {
		t.Fatalf("books = %+v %v", months, err)
	}
	month := months[0]
	if month.Revenue[control.FinanceServiceCardsApp] != "20.000" || len(month.CompanyCost) != 0 || month.SupplierCost["USD"] != "9.700" {
		t.Fatalf("books month = %+v", month)
	}
}

func TestCustomerOrderReplaysAndRefusals(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	status, first := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 1))
	if status != http.StatusCreated {
		t.Fatalf("create: %d %v", status, first)
	}
	status, replay := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 1))
	if status != http.StatusOK || orderOf(t, replay)["id"] != orderOf(t, first)["id"] || h.dafa.count("POST /payments/initiate") != 1 {
		t.Fatalf("replay: %d %v", status, replay)
	}
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 3)); status != http.StatusConflict ||
		body["code"] != "idempotency_key_reused" {
		t.Fatalf("reused key: %d %v", status, body)
	}
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "9.70", "o-2", 1)); status != http.StatusConflict ||
		body["code"] != "price_changed" || body["unit_price"] != "10.000" {
		t.Fatalf("shop price shown to a customer: %d %v", status, body)
	}
	ios := sadadOrder("itunes-us-10", "60.00", "o-3", 1)
	ios["channel"] = "ios"
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, ios); status != http.StatusNotFound || body["code"] != "unknown_item" {
		t.Fatalf("a gift card sold on ios: %d %v", status, body)
	}
	noMethod := sadadOrder("libyana-10", "10.00", "o-4", 1)
	delete(noMethod, "method")
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, noMethod); status != http.StatusUnprocessableEntity {
		t.Fatalf("no method: %d %v", status, body)
	}
	if status, _ := h.do(http.MethodPost, "/v1/customers/orders", "", sadadOrder("libyana-10", "10.00", "o-5", 1)); status != http.StatusUnauthorized {
		t.Fatalf("anonymous order: %d", status)
	}
}

func TestCustomerOrderThatCannotBeBoughtIsRefundedToCreditAndTheCreditPays(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	h.supplier.buyErr = &vouchers.Failure{Code: vouchers.FailureOutOfStock, Detail: "no cards", Definite: true}

	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 2))
	id := orderOf(t, body)["id"].(string)
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	if order := orderOf(t, body); status != http.StatusOK || order["status"] != "refunded" {
		t.Fatalf("failed card: %d %v", status, body)
	}
	if got := h.credit(token); got != "20.000" {
		t.Fatalf("credit after refund = %s", got)
	}

	// The credit pays a whole order on its own: no Dafa at all.
	h.supplier.buyErr = nil
	order := sadadOrder("libyana-10", "10.00", "o-2", 1)
	order["use_credit"] = true
	delete(order, "method")
	status, body = h.do(http.MethodPost, "/v1/customers/orders", token, order)
	paid := orderOf(t, body)
	if status != http.StatusCreated || paid["status"] != "delivered" || paid["credit_used"] != "10.000" || paid["amount_due"] != "0.000" {
		t.Fatalf("credit order: %d %v", status, body)
	}
	if h.dafa.count("POST /payments/initiate") != 1 || h.credit(token) != "10.000" {
		t.Fatalf("credit order touched Dafa or the wrong credit: %s", h.credit(token))
	}

	// Credit and Dafa together; backing out gives the held credit back.
	mixed := sadadOrder("itunes-us-10", "60.00", "o-3", 1)
	mixed["use_credit"] = true
	_, body = h.do(http.MethodPost, "/v1/customers/orders", token, mixed)
	held := orderOf(t, body)
	if held["credit_used"] != "10.000" || held["amount_due"] != "50.000" || h.credit(token) != "0.000" {
		t.Fatalf("mixed order: %v, credit %s", held, h.credit(token))
	}
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+held["id"].(string)+"/cancel", token, nil)
	if status != http.StatusOK || orderOf(t, body)["status"] != "cancelled" || h.credit(token) != "10.000" {
		t.Fatalf("cancel: %d %v, credit %s", status, body, h.credit(token))
	}
}

func TestCustomerOrderDeclinedPaymentReleasesTheCredit(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 1))
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+orderOf(t, body)["id"].(string)+"/confirm", token, map[string]any{"otp": "222222"})
	if status != http.StatusUnprocessableEntity || body["code"] != walletCodeDeclined || orderOf(t, body)["status"] != "failed" {
		t.Fatalf("declined: %d %v", status, body)
	}
	if len(h.supplier.calls()) != 0 {
		t.Fatal("a card was bought on a declined payment")
	}
}

func TestCustomerBankCardOrderIsDeliveredByTheWebhook(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	request := map[string]any{"item": "libyana-10", "unit_price": "10.00", "idempotency_key": "card-1", "channel": "ios", "method": "dafa_moamalat"}
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, request)
	order := orderOf(t, body)
	if status != http.StatusCreated || order["next_action"] != "hosted_page" || order["checkout_url"] == nil {
		t.Fatalf("card order: %d %v", status, body)
	}
	id := order["id"].(string)
	callback, _ := url.Parse(h.dafa.initiated(0)["callback_url"].(string))
	if status, _ := h.do(http.MethodPost, callback.Path+"?token=wrong", "", nil); status != http.StatusNotFound {
		t.Fatalf("webhook with a wrong token: %d", status)
	}
	// Dafa says nothing is paid yet: still waiting.
	if _, body := h.do(http.MethodPost, callback.RequestURI(), "", nil); body["status"] != "awaiting_payment" {
		t.Fatalf("unpaid webhook: %v", body)
	}
	h.dafa.markPaid("pay-1")
	if _, body := h.do(http.MethodPost, callback.RequestURI(), "", nil); body["status"] != "delivered" {
		t.Fatalf("paid webhook: %v", body)
	}
	// A second nudge buys nothing more.
	h.do(http.MethodPost, callback.RequestURI(), "", nil)
	if len(h.supplier.calls()) != 1 {
		t.Fatalf("supplier called %d times", len(h.supplier.calls()))
	}
	_, body = h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	if orderOf(t, body)["status"] != "delivered" {
		t.Fatalf("read: %v", body)
	}
}

func TestCustomerOrderSweepExpiresAndKeepsALatePaymentAsCredit(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	request := map[string]any{"item": "libyana-10", "unit_price": "10.00", "idempotency_key": "card-1", "channel": "apk", "method": "dafa_moamalat"}
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, request)
	id := orderOf(t, body)["id"].(string)
	sweeper := &CustomerOrderReconciler{Server: h.server}

	h.clock.advance(31 * time.Minute)
	sweeper.Round(context.Background())
	expired, _ := h.store.GetCustomerOrder(context.Background(), id)
	if expired.Status != control.CustomerOrderExpired {
		t.Fatalf("after the ttl: %+v", expired)
	}

	// The payer finished on Dafa's page after all: the money is theirs.
	h.dafa.markPaid("pay-1")
	sweeper.Round(context.Background())
	late, _ := h.store.GetCustomerOrder(context.Background(), id)
	if !late.LatePaid || late.Status != control.CustomerOrderExpired || h.credit(token) != "10.000" {
		t.Fatalf("late payment: %+v, credit %s", late, h.credit(token))
	}
	sweeper.Round(context.Background())
	if h.credit(token) != "10.000" || len(h.supplier.calls()) != 0 {
		t.Fatalf("a second sweep moved money again: %s", h.credit(token))
	}
}

func TestCustomerOrderSweepFinishesAPaidOrderNobodyFinished(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 1))
	id := orderOf(t, body)["id"].(string)
	// The relay died right after recording the payment.
	if _, applied, err := h.store.PayCustomerOrder(context.Background(), id, "pay-1"); err != nil || !applied {
		t.Fatal(err)
	}
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	order, _ := h.store.GetCustomerOrder(context.Background(), id)
	if order.Status != control.CustomerOrderDelivered || len(h.supplier.calls()) != 1 {
		t.Fatalf("after the sweep: %+v", order)
	}
}

func TestCustomerOrderHeldPurchaseWaitsThenRefunds(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	// The supplier took the order but its answer was lost.
	h.supplier.buyErr = errors.New("connection reset")
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 1))
	id := orderOf(t, body)["id"].(string)
	_, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	if order := orderOf(t, body); order["status"] != "fulfilling" || order["codes_pending"] != true {
		t.Fatalf("held: %v", body)
	}
	if h.credit(token) != "0.000" {
		t.Fatal("a held card was refunded before anyone knew")
	}
	stored, _ := h.store.GetCustomerOrder(context.Background(), id)
	// The supplier's records show no such order: the purchase settles failed.
	purchase, _ := h.store.GetVoucherPurchase(context.Background(), stored.PurchaseID)
	if _, _, err := h.store.ResolveVoucherPurchase(context.Background(), purchase.ID, control.VoucherPurchaseResolution{Found: false, Detail: "not at the supplier"}); err != nil {
		t.Fatal(err)
	}
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	if order, _ := h.store.GetCustomerOrder(context.Background(), id); order.Status != control.CustomerOrderRefunded || h.credit(token) != "10.000" {
		t.Fatalf("after the hold settled: %+v, credit %s", order, h.credit(token))
	}
}

func TestCustomerPaymentMethodsArePublic(t *testing.T) {
	h := newOrderHarness(t)
	status, body := h.do(http.MethodGet, "/v1/customers/payment-methods", "", nil)
	methods := body["methods"].([]any)
	if status != http.StatusOK || len(methods) != len(walletMethods) || methods[1].(map[string]any)["name"] != "سداد" {
		t.Fatalf("methods: %d %v", status, body)
	}
}

func TestCustomerOrderChargesTheGatewayFeeOnTop(t *testing.T) {
	h := newOrderHarness(t)
	h.server.Wallet.FeePercent = "2"
	h.server.Wallet.TestMode, h.dafa.testWorkspace = false, false
	h.supplier.buyResult.Codes = append(h.supplier.buyResult.Codes, vouchers.Code{Code: "2222-3333-4444", Serial: "SN-2"})
	token := h.customer("0911111111")

	_, methods := h.do(http.MethodGet, "/v1/customers/payment-methods", "", nil)
	if methods["fee_percent"] != "2.00" {
		t.Fatalf("the checkout cannot show the fee: %v", methods)
	}
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 2))
	order := orderOf(t, body)
	if status != http.StatusCreated || order["total"] != "20.000" || order["fee"] != "0.410" || order["amount_to_pay"] != "20.410" {
		t.Fatalf("create: %d %v", status, body)
	}
	if amount := h.dafa.initiated(0)["amount"]; amount != "20.410" {
		t.Fatalf("dafa was asked for %v", amount)
	}
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+order["id"].(string)+"/confirm", token, map[string]any{"otp": "111111"})
	if status != http.StatusOK || orderOf(t, body)["status"] != "delivered" {
		t.Fatalf("confirm: %d %v", status, body)
	}
	h.clock.advance(time.Hour)
	months, _ := h.store.FinanceTracked(context.Background(), time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC))
	if len(months) != 1 || months[0].Revenue[control.FinanceServiceCardsApp] != "20.000" || months[0].TopUpFees != "0.410" {
		t.Fatalf("books = %+v", months)
	}
}

func TestCustomerPaymentWithoutTheFeeIsNotServed(t *testing.T) {
	h := newOrderHarness(t)
	h.server.Wallet.FeePercent = "2"
	token := h.customer("0911111111")
	request := map[string]any{"item": "libyana-10", "unit_price": "10.00", "idempotency_key": "card-1", "channel": "apk", "method": "dafa_moamalat"}
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, request)
	id := orderOf(t, body)["id"].(string)
	// Dafa reports the price paid without the fee: not what was asked.
	h.dafa.setAmount("pay-1", "10.000")
	h.dafa.markPaid("pay-1")
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	order, _ := h.store.GetCustomerOrder(context.Background(), id)
	if order.Status != control.CustomerOrderFailed || order.ErrorCode != control.CustomerOrderPaymentMismatch || len(h.supplier.calls()) != 0 {
		t.Fatalf("a short payment was served or not held: %+v", order)
	}
}

func TestCustomerOrdersFinishWithoutTheSMSSender(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	request := map[string]any{"item": "libyana-10", "unit_price": "10.00", "idempotency_key": "card-1", "channel": "apk", "method": "dafa_moamalat"}
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, request)
	id := orderOf(t, body)["id"].(string)
	callback, _ := url.Parse(h.dafa.initiated(0)["callback_url"].(string))

	// The sign-in SMS settings go away while the payer is on Dafa's page.
	h.server.Customers = CustomerConfig{}
	h.dafa.markPaid("pay-1")
	if _, body := h.do(http.MethodPost, callback.RequestURI(), "", nil); body["status"] != "delivered" {
		t.Fatalf("webhook without a sender: %v", body)
	}
	if order, _ := h.store.GetCustomerOrder(context.Background(), id); order.Status != control.CustomerOrderDelivered {
		t.Fatalf("order = %+v", order)
	}
}

func TestCustomerPaymentWithTheWrongAmountIsHeldOnce(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	credit := sadadOrder("libyana-10", "10.00", "o-0", 1)
	// Give the customer credit to hold, via a refunded order.
	h.supplier.buyErr = &vouchers.Failure{Code: vouchers.FailureOutOfStock, Detail: "none", Definite: true}
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, credit)
	h.do(http.MethodPost, "/v1/customers/orders/"+orderOf(t, body)["id"].(string)+"/confirm", token, map[string]any{"otp": "111111"})
	h.supplier.buyErr = nil

	request := map[string]any{"item": "itunes-us-10", "unit_price": "60.00", "idempotency_key": "card-1", "channel": "apk",
		"method": "dafa_moamalat", "use_credit": true}
	_, body = h.do(http.MethodPost, "/v1/customers/orders", token, request)
	id := orderOf(t, body)["id"].(string)
	if h.credit(token) != "0.000" {
		t.Fatalf("credit not held: %s", h.credit(token))
	}
	h.dafa.setAmount("pay-2", "1.000")
	h.dafa.markPaid("pay-2")
	sweeper := &CustomerOrderReconciler{Server: h.server}
	sweeper.Round(context.Background())

	held, _ := h.store.GetCustomerOrder(context.Background(), id)
	if held.Status != control.CustomerOrderFailed || held.ErrorCode != control.CustomerOrderPaymentMismatch || held.ErrorDetail == "" {
		t.Fatalf("held = %+v", held)
	}
	if h.credit(token) != "10.000" || len(h.supplier.calls()) != 1 {
		t.Fatalf("a mismatched payment was served or the held credit kept: %s", h.credit(token))
	}
	reads := h.dafa.count("GET /payments/pay-2")
	sweeper.Round(context.Background())
	sweeper.Round(context.Background())
	if again := h.dafa.count("GET /payments/pay-2"); again != reads {
		t.Fatalf("a held payment was read again: %d -> %d", reads, again)
	}
	_, body = h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	if orderOf(t, body)["error_code"] != control.CustomerOrderPaymentMismatch {
		t.Fatalf("the app is not told: %v", body)
	}
}

func TestCustomerOrderSweepLeavesAClosedWalletPaymentAlone(t *testing.T) {
	h := newOrderHarness(t)
	token := h.customer("0911111111")
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 1))
	h.do(http.MethodPost, "/v1/customers/orders/"+orderOf(t, body)["id"].(string)+"/confirm", token, map[string]any{"otp": "222222"})
	before := h.dafa.count("GET /payments/")
	sweeper := &CustomerOrderReconciler{Server: h.server}
	for i := 0; i < 3; i++ {
		sweeper.Round(context.Background())
	}
	if after := h.dafa.count("GET /payments/"); after != before {
		t.Fatalf("a declined wallet payment was read from Dafa %d more times", after-before)
	}
}

// reviewer signs the app stores' review account in with its fixed code: no
// SMS, no code handed back.
func (h *orderHarness) reviewer() string {
	h.t.Helper()
	h.server.Customers.ReviewPhone, h.server.Customers.ReviewCode = "0910000001", "246810"
	_, otp := h.do(http.MethodPost, "/v1/customers/auth/otp", "", map[string]any{"phone": "0910000001"})
	if otp["test_code"] != nil {
		h.t.Fatalf("the review code was handed out: %v", otp)
	}
	status, signed := h.do(http.MethodPost, "/v1/customers/auth/verify", "", map[string]any{"phone": "0910000001", "code": "246810"})
	if status != http.StatusOK {
		h.t.Fatalf("review sign-in: %d %v", status, signed)
	}
	return signed["access_token"].(string)
}

func TestReviewAccountBuysWithNothingReal(t *testing.T) {
	h := newOrderHarness(t)
	// A live gateway: a real customer's sale would reach the books.
	h.server.Wallet.TestMode, h.dafa.testWorkspace = false, false
	token := h.reviewer()

	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "r-1", 2))
	order := orderOf(t, body)
	if status != http.StatusCreated || order["status"] != "awaiting_payment" || order["next_action"] != "otp" {
		t.Fatalf("create: %d %v", status, body)
	}
	id := order["id"].(string)

	// A wrong wallet code is refused the way a wallet refuses it.
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "999999"})
	if status != http.StatusUnprocessableEntity || body["code"] != walletCodeOTPRejected || body["attempts_left"] != float64(maxWalletOTPAttempts-1) {
		t.Fatalf("wrong code: %d %v", status, body)
	}
	// The review code pays it, and two cards come back that look like cards.
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "246810"})
	order = orderOf(t, body)
	codes := order["codes"].([]any)
	if status != http.StatusOK || order["status"] != "delivered" || len(codes) != 2 {
		t.Fatalf("confirm: %d %v", status, body)
	}
	plain := regexp.MustCompile(`^\d{4} \d{4} \d{4} \d{4}$`)
	for _, code := range codes {
		if text := code.(map[string]any)["code"].(string); !plain.MatchString(text) {
			t.Fatalf("a review code gives itself away: %q", text)
		}
	}
	// Nothing tells the app: no review flag, no test mode.
	if _, ok := order["review"]; ok || order["test_mode"] != false {
		t.Fatalf("the order tells: %v", order)
	}

	// Neither Dafa nor any supplier was asked anything.
	if n := h.dafa.count(""); n != 0 {
		t.Fatalf("dafa was called %d times", n)
	}
	if calls := h.supplier.calls(); len(calls) != 0 {
		t.Fatalf("a card was bought: %+v", calls)
	}
	// The same codes read back.
	_, body = h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	if again := orderOf(t, body)["codes"].([]any); len(again) != 2 || again[0].(map[string]any)["code"] != codes[0].(map[string]any)["code"] {
		t.Fatalf("read back: %v", body)
	}

	// A bank card has no page to show: paid at once, the card follows.
	status, body = h.do(http.MethodPost, "/v1/customers/orders", token, map[string]any{
		"item": "libyana-10", "unit_price": "10.00", "idempotency_key": "r-2", "channel": "ios", "method": "dafa_moamalat",
	})
	if order := orderOf(t, body); status != http.StatusCreated || order["status"] != "delivered" || order["checkout_url"] != nil {
		t.Fatalf("bank card: %d %v", status, body)
	}

	// None of it is a sale on the books.
	h.clock.advance(time.Hour)
	months, err := h.store.FinanceTracked(context.Background(), time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	for _, month := range months {
		if revenue := month.Revenue[control.FinanceServiceCardsApp]; revenue != "" && revenue != "0.000" {
			t.Fatalf("review orders reached the books: %+v", month)
		}
	}
}

func TestReviewOrderStaysSimulatedWhenTheAccountChanges(t *testing.T) {
	h := newOrderHarness(t)
	token := h.reviewer()
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "r-1", 1))
	id := orderOf(t, body)["id"].(string)
	// The review account is moved to another number mid-review.
	h.server.Customers.ReviewPhone = "0910000002"
	status, body := h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "246810"})
	if status != http.StatusOK || orderOf(t, body)["status"] != "delivered" {
		t.Fatalf("confirm: %d %v", status, body)
	}
	if h.dafa.count("") != 0 || len(h.supplier.calls()) != 0 {
		t.Fatal("the order turned real")
	}
}

func TestOrdinaryCustomerStillPaysForReal(t *testing.T) {
	h := newOrderHarness(t)
	h.reviewer()
	token := h.customer("0911111111")
	_, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder("libyana-10", "10.00", "o-1", 1))
	if orderOf(t, body)["status"] != "awaiting_payment" || h.dafa.count("") == 0 {
		t.Fatalf("an ordinary order skipped Dafa: %v", body)
	}
	// The review code is no wallet code for anyone else.
	id := orderOf(t, body)["id"].(string)
	h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "246810"})
	if len(h.supplier.calls()) != 0 {
		t.Fatal("the review code paid an ordinary order")
	}
}
