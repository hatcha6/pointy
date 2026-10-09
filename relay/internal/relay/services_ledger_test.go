package relay

import (
	"context"
	"encoding/json"
	"math/big"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/services"
	"pointy/relay/internal/vouchers"
)

// The ledger scenario drives every way a service order can end through the HTTP
// handlers and checks the shop's balance and the ledger rows after each. It runs
// on the file store always, and on a real PostgreSQL when
// POINTY_RELAY_E2E_DATABASE_URL names a DEDICATED database (see relay/README.md):
// the SQL of kinds, targets, details and the supplier-order index is then the one
// the relay runs on.
func runServicesLedgerScenario(t *testing.T, h *servicesHarness) {
	t.Helper()
	// Reloadly's ids belong to nobody's run in particular: a shared database must
	// not meet last run's.
	seed := int(time.Now().UnixNano() % 100_000_000)
	h.exec.nextID = seed
	unique := strconv.FormatInt(time.Now().UnixNano(), 36)
	key := func(name string) string { return name + "-" + unique }
	installation := h.shop.Installation.ID
	h.fund("400") // eight orders at about a hundred dinars each
	startBalance := mustRat(t, h.balance())

	// 1. An airtime order is charged once, placed once, and replayed from the ledger.
	status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody(key("air")))
	if status != http.StatusCreated {
		t.Fatalf("airtime: %d %v", status, body)
	}
	if status, replay := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody(key("air"))); status != http.StatusOK || replay["replayed"] != true || h.exec.calls() != 1 {
		t.Fatalf("replay: %d %v", status, replay)
	}
	air := h.purchase(key("air"))
	var details map[string]any // PostgreSQL's jsonb rewrites the text: read it as JSON
	if err := json.Unmarshal(air.Details, &details); err != nil {
		t.Fatalf("details: %s %v", air.Details, err)
	}
	if air.Kind != "airtime" || air.Target != "+223•••••456" || air.ItemKey != "airtime:289:5000:XOF" || air.Supplier != "reloadly" ||
		!strings.HasPrefix(air.SupplierOrderID, "airtime:") || air.SupplierCurrency != "USD" || details["order_mode"] != "usd" ||
		details["order_currency"] != "USD" || details["operator_id"] != float64(289) {
		t.Fatalf("airtime row: %+v", air)
	}

	// 2. Reloadly numbers top-ups and payments separately: the same id for an
	// airtime order and a bill must both be recorded.
	same := strconv.Itoa(seed + 5000)
	h.exec.onAirtime = func(order services.AirtimeOrder) (services.Result, error) {
		return services.Result{OrderID: same, Status: vouchers.StatusSucceeded, CostUSD: "9.4",
			Receipt: map[string]string{"transaction_id": same, "delivered_amount": "5000", "delivered_currency": "XOF"}}, nil
	}
	h.exec.onBill = func(order services.BillOrder) (services.Result, error) {
		return services.Result{OrderID: same, Status: vouchers.StatusSucceeded, CostUSD: "7.9",
			Receipt: map[string]string{"transaction_id": same, "token": "1111-2222"}}, nil
	}
	if status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody(key("air2"))); status != http.StatusCreated {
		t.Fatalf("airtime with the shared id: %d %v", status, body)
	}
	if status, body := h.call(http.MethodPost, "/v1/services/orders", svcBillBody(key("bill2"))); status != http.StatusCreated {
		t.Fatalf("a bill with the same id must not collide with the airtime order: %d %v", status, body)
	}
	if a, b := h.purchase(key("air2")).SupplierOrderID, h.purchase(key("bill2")).SupplierOrderID; a != "airtime:"+same || b != "bill:"+same {
		t.Fatalf("namespaced ledger ids: %s %s", a, b)
	}

	// 3. A bill Reloadly accepted and has not finished stays held, then pays.
	pendingID := strconv.Itoa(seed + 6000)
	h.exec.onBill = func(order services.BillOrder) (services.Result, error) {
		return services.Result{OrderID: pendingID, Status: vouchers.StatusPending}, nil
	}
	if status, body := h.call(http.MethodPost, "/v1/services/orders", svcBillBody(key("bill3"))); status != http.StatusAccepted {
		t.Fatalf("pending bill: %d %v", status, body)
	}
	if row := h.purchase(key("bill3")); row.SupplierOrderID != "bill:"+pendingID || row.HeldSince == nil || row.Status != "pending" {
		t.Fatalf("held bill: %+v", row)
	}
	reconciler := &VoucherReconciler{Server: h.server, Store: h.store}
	h.exec.lookups["bill:"+pendingID] = services.Result{OrderID: pendingID, Status: vouchers.StatusPending}
	reconciler.Round(context.Background())
	if row := h.purchase(key("bill3")); row.Status != "pending" {
		t.Fatalf("still processing: %+v", row)
	}
	h.exec.lookups["bill:"+pendingID] = services.Result{OrderID: pendingID, Status: vouchers.StatusSucceeded, CostUSD: "7.8",
		Receipt: map[string]string{"transaction_id": pendingID, "token": "2737-6032"}}
	reconciler.Round(context.Background())
	if row := h.purchase(key("bill3")); row.Status != "succeeded" || row.SupplierCost != "7.8" || row.HeldSince != nil {
		t.Fatalf("paid: %+v", row)
	}
	if _, read := h.call(http.MethodGet, "/v1/services/orders/"+key("bill3"), nil); svcObject(t, svcObject(t, read["purchase"])["receipt"])["token"] != "2737-6032" {
		t.Fatalf("the token is read back: %v", read)
	}

	// 4. An uncertain top-up is found by the identifier it was placed with.
	h.exec.onAirtime = func(order services.AirtimeOrder) (services.Result, error) {
		return services.Result{}, &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "timeout"}
	}
	if status, _ := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody(key("found"))); status != http.StatusAccepted {
		t.Fatalf("uncertain: %d", status)
	}
	foundID := strconv.Itoa(seed + 7000)
	held := h.purchase(key("found"))
	h.exec.found["airtime:"+held.ID] = []services.Result{{OrderID: foundID, Status: vouchers.StatusSucceeded, CostUSD: "9.1"}}
	reconciler.Round(context.Background())
	if row := h.purchase(key("found")); row.Status != "succeeded" || row.SupplierOrderID != "airtime:"+foundID || row.SupplierCost != "9.1" {
		t.Fatalf("found: %+v", row)
	}

	// 5. One nobody ever saw is refunded once the window has passed.
	if status, _ := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody(key("lost"))); status != http.StatusAccepted {
		t.Fatalf("uncertain: %d", status)
	}
	h.clock.advance(20 * time.Minute)
	reconciler.Round(context.Background())
	if row := h.purchase(key("lost")); row.Status != "failed" || row.HeldSince != nil {
		t.Fatalf("lost: %+v", row)
	}

	// 6. A definite refusal is refunded at once.
	h.exec.onAirtime = func(order services.AirtimeOrder) (services.Result, error) {
		return services.Result{}, &vouchers.Failure{Code: vouchers.FailureRefused, Detail: "refused", Definite: true}
	}
	if status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody(key("refused"))); status != http.StatusBadGateway || body["code"] != "refused" {
		t.Fatalf("refused: %d %v", status, body)
	}

	// 7. The operator's list knows the kinds.
	status, list := h.admin(http.MethodGet, "/v1/vouchers/admin/purchases?kind=bill&installation_id="+installation, "")
	if status != http.StatusOK || len(list["purchases"].([]any)) != 2 {
		t.Fatalf("bills: %d %v", status, list)
	}
	status, list = h.admin(http.MethodGet, "/v1/vouchers/admin/purchases?kind=airtime&installation_id="+installation, "")
	if status != http.StatusOK || len(list["purchases"].([]any)) != 5 {
		t.Fatalf("top-ups: %d %v", status, list)
	}

	// 8. The money adds up: the shop paid for what was carried out, and only that.
	paid := new(big.Rat)
	for _, name := range []string{"air", "air2", "bill2", "bill3", "found"} {
		paid.Add(paid, mustRat(t, h.purchase(key(name)).Amount))
	}
	if want := new(big.Rat).Sub(startBalance, paid); mustRat(t, h.balance()).Cmp(want) != 0 {
		t.Fatalf("balance %s, want %s (started at %s, paid %s)", h.balance(), want.FloatString(3), startBalance.FloatString(3), paid.FloatString(3))
	}
}

func TestServicesLedgerScenarioOnTheFileStore(t *testing.T) {
	runServicesLedgerScenario(t, readyServicesHarness(t))
}

func TestServicesLedgerScenarioOnPostgres(t *testing.T) {
	databaseURL := os.Getenv("POINTY_RELAY_E2E_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set POINTY_RELAY_E2E_DATABASE_URL (a DEDICATED database) to run the services ledger on PostgreSQL")
	}
	clock := &settingsClock{now: time.Now().UTC().Truncate(time.Second)}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	store, err := control.NewPostgresStore(ctx, databaseURL, clock)
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	t.Cleanup(store.Close)
	if err := store.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	h := newServicesHarnessOn(t, store, clock)
	h.publishSettings(`{"usd_rate": "9.71"}`)
	h.fund("400")
	runServicesLedgerScenario(t, h)
}
