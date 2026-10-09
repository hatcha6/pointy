package relay

import (
	"context"
	"math/big"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/services"
)

// The sandbox test runs the services end to end against Reloadly's SANDBOX (fake
// money): the directory is built from the sandbox's catalog, a number is detected,
// a top-up and a bill payment are quoted, ordered through the HTTP handlers and
// read back, and the account's balance is compared with what the order says it
// cost. It is skipped unless both variables are set, and it refuses to run against
// anything but sandbox hosts:
//
//	set -a; . ops/catalog/.reloadly.env; set +a      (the SANDBOX pair; never the live one)
//	RELOADLY_SANDBOX_CLIENT_ID=$RELOADLY_CLIENT_ID RELOADLY_SANDBOX_CLIENT_SECRET=$RELOADLY_CLIENT_SECRET \
//	  go test ./internal/relay -run TestSandboxServices -v -timeout 15m
//
// It spends about twelve dollars of fake money per run. Nigerian billers always
// end FAILED in the sandbox, so the bill it pays is Senegal's Woyofal (prepaid
// electricity; successful in the sandbox) and Mali's Canal+ (a fixed plan).
func sandboxReloadly(t *testing.T) *reloadly.Client {
	t.Helper()
	id := strings.TrimSpace(os.Getenv("RELOADLY_SANDBOX_CLIENT_ID"))
	secret := strings.TrimSpace(os.Getenv("RELOADLY_SANDBOX_CLIENT_SECRET"))
	if id == "" || secret == "" {
		t.Skip("set RELOADLY_SANDBOX_CLIENT_ID and RELOADLY_SANDBOX_CLIENT_SECRET to run the sandbox test")
	}
	client, err := reloadly.New(reloadly.Config{
		ClientID: id, ClientSecret: secret, Sandbox: true,
		PurchaseTimeout: 90 * time.Second, Timeout: 60 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	gift, topups, utilities := client.BaseURLs()
	for _, host := range []string{gift, topups, utilities} {
		if !strings.Contains(host, "-sandbox.reloadly.com") {
			t.Fatalf("refusing to run: %s is not a sandbox host", host)
		}
	}
	return client
}

func sandboxBalance(t *testing.T, client *reloadly.Client) *big.Rat {
	t.Helper()
	balance, err := client.TopupBalance(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	value, ok := balance.Balance.Rat()
	if !ok {
		t.Fatalf("unreadable balance %q", balance.Balance)
	}
	return value
}

func TestSandboxServicesEndToEnd(t *testing.T) {
	client := sandboxReloadly(t)
	h := newServicesHarness(t, func(cfg *services.Config) {
		cfg.Source = services.ReloadlySource{Client: client}
		cfg.Detector = services.ReloadlyDetector{Client: client}
		cfg.Reloadly = &services.ReloadlyExecutor{Client: client, SettleWait: 30 * time.Second, PollEvery: 500 * time.Millisecond}
		cfg.Balances = services.ReloadlyBalances{Client: client}
		cfg.Namer = nil
		cfg.RequestTimeout = 90 * time.Second
		cfg.SettleWait = 30 * time.Second
		cfg.LoadTimeout = 5 * time.Minute
	})
	h.publishSettings(`{"usd_rate": "9.71"}`)
	h.fund("500")

	// The directory, built from the sandbox's own catalog.
	started := time.Now()
	status, directory := h.call(http.MethodGet, "/v1/services/directory", nil)
	if status != http.StatusOK {
		t.Fatalf("directory: %d %v", status, directory)
	}
	countries := directory["countries"].([]any)
	operators, billers := 0, 0
	for _, entry := range countries {
		country := entry.(map[string]any)
		if airtime, ok := country["airtime"].(map[string]any); ok {
			operators += len(airtime["operators"].([]any))
		}
		if bills, ok := country["bills"].(map[string]any); ok {
			billers += len(bills["billers"].([]any))
		}
	}
	stats := h.service.Stats()
	t.Logf("sandbox directory built in %s: %d countries, %d operators, %d billers; skipped %v; %d names without Arabic",
		time.Since(started).Round(time.Millisecond), len(countries), operators, billers, stats.Build.Skipped, stats.Untranslated)
	if len(countries) < 20 || operators < 100 || billers < 5 {
		t.Fatalf("the sandbox directory looks too small: %d countries, %d operators, %d billers", len(countries), operators, billers)
	}

	// Detection by number: Reloadly knows the prefixes.
	status, detected := h.call(http.MethodPost, "/v1/services/detect", map[string]any{"country": "ML", "phone": "76123456"})
	if status != http.StatusOK {
		t.Fatalf("detect: %d %v", status, detected)
	}
	t.Logf("76123456 in Mali is %v (id %v), phone %v", svcObject(t, detected["operator"])["name_en"], svcObject(t, detected["operator"])["id"], detected["phone"])

	// --- a top-up: quote, order, read back, compare the balance ---
	operatorID := int64(289)
	quoteBody := map[string]any{"kind": "airtime", "operator_id": operatorID, "amount": "2000", "amount_currency": "XOF"}
	status, quoted := h.call(http.MethodPost, "/v1/services/quote", quoteBody)
	if status != http.StatusOK {
		t.Fatalf("quote: %d %v", status, quoted)
	}
	quote := svcObject(t, quoted["quote"])
	_, adminQuote := h.admin(http.MethodPost, "/v1/services/admin/quote", `{"kind":"airtime","operator_id":289,"amount":"2000","amount_currency":"XOF"}`)
	t.Logf("quote: %s -> the shop pays %v, the customer %v; ordered as %v %v (cost %v USD, %v LYD)",
		quote["name"], quote["unit_price"], quote["retail_price"], adminQuote["order_amount"], adminQuote["order_currency"],
		adminQuote["order_cost_usd"], adminQuote["cost_lyd"])

	before := sandboxBalance(t, client)
	shopBefore := h.balance()
	order := map[string]any{
		"kind": "airtime", "operator_id": operatorID, "country": "ML", "phone": "76123456",
		"amount": "2000", "amount_currency": "XOF", "idempotency_key": "sandbox-air-" + time.Now().Format("150405"),
		"max_unit_price": quote["unit_price"], "requested_by": "sandbox test",
	}
	status, placed := h.call(http.MethodPost, "/v1/services/orders", order)
	if status != http.StatusCreated {
		t.Fatalf("airtime order: %d %v", status, placed)
	}
	purchase := svcObject(t, placed["purchase"])
	receipt := svcObject(t, purchase["receipt"])
	after := sandboxBalance(t, client)
	moved := new(big.Rat).Sub(before, after)
	row := h.purchase(order["idempotency_key"].(string))
	t.Logf("airtime order %s: status %v, receipt %v", purchase["id"], purchase["status"], receipt)
	t.Logf("airtime balance movement: %s USD (supplier cost recorded: %s %s); the shop was charged %s LYD (quoted %v)",
		moved.FloatString(5), row.SupplierCost, row.SupplierCurrency, new(big.Rat).Sub(mustRat(t, shopBefore), mustRat(t, h.balance())).FloatString(3), quote["unit_price"])
	if cost := mustRat(t, row.SupplierCost); cost.Cmp(moved) != 0 {
		t.Errorf("the account moved %s but the order says it cost %s", moved.FloatString(5), cost.FloatString(5))
	}
	if expected := mustRat(t, adminQuote["order_cost_usd"].(string)); expected.Cmp(mustRat(t, row.SupplierCost)) != 0 {
		t.Errorf("the quote expected %s USD, Reloadly debited %s", expected.FloatString(5), row.SupplierCost)
	}
	deliveredText, _ := receipt["delivered_amount"].(string)
	delivered, ok := services.ParseAmount(deliveredText)
	if !ok || delivered.Cmp(big.NewRat(2000, 1)) < 0 || receipt["delivered_currency"] != "XOF" {
		t.Errorf("the recipient must receive at least what was quoted: %v", receipt)
	}

	// A replay places nothing: the same answer, the balance as it was.
	status, replay := h.call(http.MethodPost, "/v1/services/orders", order)
	if status != http.StatusOK || replay["replayed"] != true || sandboxBalance(t, client).Cmp(after) != 0 {
		t.Fatalf("replay: %d %v", status, replay)
	}
	status, read := h.call(http.MethodGet, "/v1/services/orders/"+order["idempotency_key"].(string), nil)
	if status != http.StatusOK || svcObject(t, svcObject(t, read["purchase"])["receipt"])["transaction_id"] != receipt["transaction_id"] {
		t.Fatalf("read back: %d %v", status, read)
	}

	// --- a bill: Woyofal Senegal (prepaid, a range: paid in dollars in auto mode) ---
	billQuote := map[string]any{"kind": "bill", "biller_id": 26, "amount": "5000", "amount_currency": "XOF"}
	status, quotedBill := h.call(http.MethodPost, "/v1/services/quote", billQuote)
	if status != http.StatusOK {
		t.Fatalf("bill quote: %d %v", status, quotedBill)
	}
	_, adminBill := h.admin(http.MethodPost, "/v1/services/admin/quote", `{"kind":"bill","biller_id":26,"amount":"5000","amount_currency":"XOF"}`)
	billUnit := svcObject(t, quotedBill["quote"])["unit_price"]
	t.Logf("bill quote: shop pays %v, customer %v; ordered as %v %v (cost %v USD)",
		billUnit, svcObject(t, quotedBill["quote"])["retail_price"], adminBill["order_amount"], adminBill["order_currency"], adminBill["order_cost_usd"])
	beforeBill := sandboxBalance(t, client)
	billOrder := map[string]any{
		"kind": "bill", "biller_id": 26, "country": "SN", "account": "14500000001", "amount": "5000", "amount_currency": "XOF",
		"idempotency_key": "sandbox-bill-" + time.Now().Format("150405"), "max_unit_price": billUnit, "requested_by": "sandbox test",
	}
	status, paid := h.call(http.MethodPost, "/v1/services/orders", billOrder)
	billPurchase := svcObject(t, paid["purchase"])
	t.Logf("bill order: HTTP %d, status %v, held %v, receipt %v", status, billPurchase["status"], billPurchase["held"], billPurchase["receipt"])
	if status != http.StatusCreated && status != http.StatusAccepted {
		t.Fatalf("bill order: %d %v", status, paid)
	}
	afterBill := sandboxBalance(t, client)
	billRow := h.purchase(billOrder["idempotency_key"].(string))
	t.Logf("bill balance movement: %s USD (supplier cost recorded: %q); the order is %s, supplier order %s",
		new(big.Rat).Sub(beforeBill, afterBill).FloatString(5), billRow.SupplierCost, billRow.Status, billRow.SupplierOrderID)
	if billRow.Status == "succeeded" {
		if cost := mustRat(t, billRow.SupplierCost); cost.Cmp(new(big.Rat).Sub(beforeBill, afterBill)) != 0 {
			t.Errorf("the account moved %s but the bill says it cost %s", new(big.Rat).Sub(beforeBill, afterBill).FloatString(5), cost.FloatString(5))
		}
		if expected := mustRat(t, adminBill["order_cost_usd"].(string)); expected.Cmp(mustRat(t, billRow.SupplierCost)) != 0 {
			t.Errorf("the quote expected %s USD, Reloadly debited %s", expected.FloatString(5), billRow.SupplierCost)
		}
	}

	// A fixed plan in the local currency: Canal+ Mali.
	if plan := firstPlan(t, directory, "ML", 27); plan != nil {
		planOrder := map[string]any{
			"kind": "bill", "biller_id": 27, "country": "ML", "account": "12345678", "amount": plan["amount"], "amount_currency": "XOF",
			"amount_id": plan["id"], "idempotency_key": "sandbox-plan-" + time.Now().Format("150405"), "max_unit_price": plan["unit_price"],
		}
		beforePlan := sandboxBalance(t, client)
		status, planPaid := h.call(http.MethodPost, "/v1/services/orders", planOrder)
		planRow := h.purchase(planOrder["idempotency_key"].(string))
		t.Logf("fixed plan %v (%v XOF): HTTP %d, status %s, moved %s USD, supplier cost %q, receipt %v", plan["description_en"], plan["amount"], status,
			planRow.Status, new(big.Rat).Sub(beforePlan, sandboxBalance(t, client)).FloatString(5), planRow.SupplierCost, svcObject(t, planPaid["purchase"])["receipt"])
	}

	// The sandbox ends every Nigerian payment REFUNDED: the shop's money must come
	// back, with Reloadly's own word as the reason.
	refundOrder := map[string]any{
		"kind": "bill", "biller_id": 3, "country": "NG", "account": "04223568280", "amount": "1000", "amount_currency": "NGN",
		"idempotency_key": "sandbox-ng-" + time.Now().Format("150405"),
	}
	shopBeforeRefund := h.balance()
	beforeRefund := sandboxBalance(t, client)
	status, refused := h.call(http.MethodPost, "/v1/services/orders", refundOrder)
	refundRow := h.purchase(refundOrder["idempotency_key"].(string))
	t.Logf("nigerian bill: HTTP %d code %v status %s held %v detail %q; shop balance %s -> %s; Reloadly balance moved %s USD",
		status, refused["code"], refundRow.Status, refundRow.HeldSince != nil, refundRow.ErrorDetail, shopBeforeRefund, h.balance(),
		new(big.Rat).Sub(beforeRefund, sandboxBalance(t, client)).FloatString(5))
	if status == http.StatusBadGateway {
		if h.balance() != shopBeforeRefund {
			t.Errorf("a refunded payment gives the shop its money back: %s -> %s", shopBeforeRefund, h.balance())
		}
	} else if status != http.StatusAccepted {
		t.Errorf("a Nigerian payment is refunded or held, got HTTP %d %v", status, refused)
	}

	// Whatever is still open settles through the reconciler.
	(&VoucherReconciler{Server: h.server, Store: h.store}).Round(context.Background())
	t.Logf("balances now: %+v", func() any { b, _ := h.service.Balances(context.Background()); return b }())
}

func mustRat(t *testing.T, text string) *big.Rat {
	t.Helper()
	value, ok := new(big.Rat).SetString(strings.TrimSpace(text))
	if !ok {
		t.Fatalf("%q is not a number", text)
	}
	return value
}

func firstPlan(t *testing.T, directory map[string]any, country string, biller float64) map[string]any {
	t.Helper()
	for _, entry := range directory["countries"].([]any) {
		c := entry.(map[string]any)
		if c["code"] != country {
			continue
		}
		bills, ok := c["bills"].(map[string]any)
		if !ok {
			return nil
		}
		for _, b := range bills["billers"].([]any) {
			item := b.(map[string]any)
			if item["id"] == biller {
				if plans, ok := item["plans"].([]any); ok && len(plans) > 0 {
					return plans[0].(map[string]any)
				}
			}
		}
	}
	return nil
}
