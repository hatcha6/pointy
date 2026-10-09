package relay

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/services"
	"pointy/relay/internal/vouchers"
)

// brief is a purchase as a failing test prints it: its state, not its payload.
func brief(p control.VoucherPurchase) string {
	return fmt.Sprintf("status=%s held=%v supplier_order=%q error=%q detail=%q", p.Status, p.HeldSince != nil, p.SupplierOrderID, p.ErrorCode, p.ErrorDetail)
}

// The cases a review of the services found: each is written against the HTTP
// routes and the ledger, as a shop sees them.

func TestTheQuoteReadsTheNumberTheTillTypedAndSaysHowItWasRead(t *testing.T) {
	h := readyServicesHarness(t)
	quoteBody := func(extra map[string]any) map[string]any {
		body := map[string]any{"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"}
		for key, value := range extra {
			body[key] = value
		}
		return body
	}
	for _, typed := range []string{"70123456", "070123456", "+223 70 12 34 56", "0022370123456", "٧٠١٢٣٤٥٦"} {
		status, answer := h.call(http.MethodPost, "/v1/services/quote", quoteBody(map[string]any{"country": "ML", "phone": typed}))
		phone, _ := answer["phone"].(map[string]any)
		if status != http.StatusOK || phone["e164"] != "+22370123456" || phone["national"] != "70123456" || phone["country"] != "ML" {
			t.Fatalf("%q: %d %v", typed, status, answer)
		}
		if svcObject(t, answer["quote"])["unit_price"] == "" {
			t.Fatalf("the quote is still there: %v", answer)
		}
	}
	// The e164 it answers is one every route reads back.
	status, back := h.call(http.MethodPost, "/v1/services/quote", quoteBody(map[string]any{"phone": "+22370123456"}))
	if status != http.StatusOK || svcObject(t, back["phone"])["national"] != "70123456" {
		t.Fatalf("the operator's country is the default: %d %v", status, back)
	}

	// Without a number, the answer is what it always was.
	status, plain := h.call(http.MethodPost, "/v1/services/quote", quoteBody(nil))
	if _, has := plain["phone"]; status != http.StatusOK || has || plain["quote"] == nil {
		t.Fatalf("no number, no phone: %d %v", status, plain)
	}
	status, blank := h.call(http.MethodPost, "/v1/services/quote", quoteBody(map[string]any{"phone": "  "}))
	if _, has := blank["phone"]; status != http.StatusOK || has {
		t.Fatalf("a blank number is no number: %d %v", status, blank)
	}

	// An unreadable one is refused as the order would refuse it.
	for _, typed := range []string{"12", "70-12-ab-56", "+2348031234567"} {
		status, refused := h.call(http.MethodPost, "/v1/services/quote", quoteBody(map[string]any{"phone": typed}))
		if status != http.StatusUnprocessableEntity || refused["code"] != "invalid_phone" {
			t.Fatalf("%q: %d %v", typed, status, refused)
		}
	}
	if status, refused := h.call(http.MethodPost, "/v1/services/quote", quoteBody(map[string]any{"country": "NE", "phone": "96123456"})); status != http.StatusUnprocessableEntity || refused["code"] != "invalid_phone" {
		t.Fatalf("another country's number: %d %v", status, refused)
	}
	if strings.Contains(h.logs.String(), "70123456") {
		t.Fatalf("a customer's number never reaches the log:\n%s", h.logs)
	}
}

func TestAFixedPlanOrderedByItsAmountReplaysLikeOneOrderedById(t *testing.T) {
	for _, c := range []struct {
		name  string
		extra map[string]any
	}{
		{"by amount alone", nil},
		{"by amount and plan id", map[string]any{"amount_id": 3}},
	} {
		t.Run(c.name, func(t *testing.T) {
			h := readyServicesHarness(t)
			order := map[string]any{
				"kind": "bill", "biller_id": 27, "country": "ML", "account": "12345678",
				"amount": "10000", "amount_currency": "XOF", "idempotency_key": "canal-replay", "requested_by": "cashier",
			}
			for key, value := range c.extra {
				order[key] = value
			}
			status, first := h.call(http.MethodPost, "/v1/services/orders", order)
			if status != http.StatusCreated {
				t.Fatalf("first: %d %v", status, first)
			}
			if row := h.purchase("canal-replay"); row.ItemKey != "bill:27:10000:XOF:3" {
				t.Fatalf("the ledger names the plan the amount resolved to: %s", row.ItemKey)
			}
			balance := h.balance()
			// The same request again: the first answer, nothing placed or charged again.
			status, replay := h.call(http.MethodPost, "/v1/services/orders", order)
			if status != http.StatusOK || replay["replayed"] != true ||
				svcObject(t, replay["purchase"])["id"] != svcObject(t, first["purchase"])["id"] {
				t.Fatalf("replay: %d %v", status, replay)
			}
			if h.exec.calls() != 1 || h.balance() != balance {
				t.Fatalf("one order, one charge: %d calls, balance %s -> %s", h.exec.calls(), balance, h.balance())
			}
			// The other way of naming it is the same order too.
			other := map[string]any{}
			for key, value := range order {
				other[key] = value
			}
			if _, named := c.extra["amount_id"]; named {
				delete(other, "amount_id")
			} else {
				other["amount_id"] = 3
			}
			if status, again := h.call(http.MethodPost, "/v1/services/orders", other); status != http.StatusOK || again["replayed"] != true {
				t.Fatalf("named the other way: %d %v", status, again)
			}
			// Another plan under the same key is a key reused.
			different := map[string]any{}
			for key, value := range order {
				different[key] = value
			}
			different["amount"], different["amount_id"] = "15000", 9
			if status, reused := h.call(http.MethodPost, "/v1/services/orders", different); status != http.StatusConflict || reused["code"] != "idempotency_key_reused" {
				t.Fatalf("another plan: %d %v", status, reused)
			}
			if h.exec.calls() != 1 {
				t.Fatal("and nothing was placed")
			}
		})
	}
}

// ---- reconciling what the supplier did not answer ----

// heldOrder places an order whose answer is lost (the supplier may or may not
// have it), and returns the purchase's id.
func heldOrder(t *testing.T, h *servicesHarness, kind, key string) string {
	t.Helper()
	lost := &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "connection reset"}
	body := svcAirtimeBody(key)
	if kind == "bill" {
		body = svcBillBody(key)
		h.exec.onBill = func(services.BillOrder) (services.Result, error) { return services.Result{}, lost }
	} else {
		h.exec.onAirtime = func(services.AirtimeOrder) (services.Result, error) { return services.Result{}, lost }
	}
	status, answer := h.call(http.MethodPost, "/v1/services/orders", body)
	if status != http.StatusAccepted {
		t.Fatalf("held: %d %v", status, answer)
	}
	return svcObject(t, answer["purchase"])["id"].(string)
}

func TestABillTheSupplierDoesNotListIsWaitedForADay(t *testing.T) {
	h := readyServicesHarness(t)
	before := h.balance()
	heldOrder(t, h, "bill", "lost-bill")
	held := h.balance()
	if held == before {
		t.Fatal("the price is held")
	}
	reconciler := &VoucherReconciler{Server: h.server, Store: h.store}
	const warning = "does not list yet"
	warnings := func() int { return strings.Count(h.logs.String(), warning) }

	// A payment can stay PROCESSING at the biller for a day, and Reloadly's
	// history may not show one whose answer was lost: nothing is refunded by the
	// quarter-hour that is enough for a top-up.
	h.clock.advance(16 * time.Minute)
	reconciler.Round(context.Background())
	if purchase := h.purchase("lost-bill"); purchase.Status != "pending" || purchase.HeldSince == nil || h.balance() != held {
		t.Fatalf("16 minutes: %s balance %s", brief(purchase), h.balance())
	}
	if warnings() != 1 {
		t.Fatalf("it is said, once:\n%s", h.logs)
	}
	// Every minute the reconciler looks again; the line is hourly.
	h.clock.advance(time.Minute)
	reconciler.Round(context.Background())
	if warnings() != 1 {
		t.Fatalf("not again within the hour: %d\n%s", warnings(), h.logs)
	}
	h.clock.advance(time.Hour)
	reconciler.Round(context.Background())
	if warnings() != 2 {
		t.Fatalf("an hour later it is said again: %d", warnings())
	}
	if !strings.Contains(h.logs.String(), "level=WARN") {
		t.Fatalf("it is a warning:\n%s", h.logs)
	}
	for _, age := range []time.Duration{6 * time.Hour, 24*time.Hour + 59*time.Minute} {
		h.clock.advance(age - h.clock.Now().Sub(h.purchase("lost-bill").CreatedAt))
		reconciler.Round(context.Background())
		if purchase := h.purchase("lost-bill"); purchase.Status != "pending" || h.balance() != held {
			t.Fatalf("%s: still held: %s", age, brief(purchase))
		}
	}
	// Past a day and an hour it cannot still be processing: the price comes back.
	h.clock.advance(3 * time.Minute)
	reconciler.Round(context.Background())
	purchase := h.purchase("lost-bill")
	if purchase.Status != "failed" || purchase.HeldSince != nil || h.balance() != before {
		t.Fatalf("after the day: %s balance %s want %s", brief(purchase), h.balance(), before)
	}
}

func TestSeveralOrdersForOneIdentifierNeverRefundAPaidOne(t *testing.T) {
	failed := func(id string) services.Result {
		return services.Result{OrderID: id, Status: vouchers.StatusFailed, Message: "REFUNDED"}
	}
	paid := func(id string) services.Result {
		return services.Result{OrderID: id, Status: vouchers.StatusSucceeded, CostUSD: "9.45298",
			Receipt: map[string]string{services.ReceiptTransactionID: id, services.ReceiptDeliveredAmount: "5000"}}
	}
	open := func(id string) services.Result { return services.Result{OrderID: id, Status: vouchers.StatusPending} }

	for _, c := range []struct {
		name    string
		found   []services.Result
		status  string // the purchase afterwards
		orderID string // the supplier order it ends up with
		refund  bool
		error   bool
	}{
		{"a failed one listed before the paid one", []services.Result{failed("8101"), paid("8102")}, "succeeded", "airtime:8102", false, false},
		{"the paid one listed first", []services.Result{paid("8102"), failed("8101")}, "succeeded", "airtime:8102", false, false},
		{"failed, open, paid", []services.Result{failed("8101"), open("8103"), paid("8102")}, "succeeded", "airtime:8102", false, false},
		{"only failed ones", []services.Result{failed("8101"), failed("8104")}, "failed", "airtime:8101", true, false},
		{"a failed one and one still open", []services.Result{failed("8101"), open("8103")}, "pending", "", false, false},
		{"two paid ones", []services.Result{paid("8102"), paid("8105")}, "pending", "", false, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			h := readyServicesHarness(t)
			before := h.balance()
			id := heldOrder(t, h, "airtime", "dup-1")
			held := h.balance()
			h.exec.found["airtime:"+id] = c.found
			for _, result := range c.found {
				h.exec.lookups["airtime:"+result.OrderID] = result
			}
			(&VoucherReconciler{Server: h.server, Store: h.store}).Round(context.Background())
			purchase := h.purchase("dup-1")
			wantBalance := held
			if c.refund {
				wantBalance = before
			}
			if purchase.Status != c.status || h.balance() != wantBalance || (c.orderID != "" && purchase.SupplierOrderID != c.orderID) {
				t.Fatalf("%s balance %s want %s", brief(purchase), h.balance(), wantBalance)
			}
			if c.status == "pending" && purchase.HeldSince == nil {
				t.Fatalf("still held: %s", brief(purchase))
			}
			if got := strings.Contains(h.logs.String(), "several SUCCESSFUL"); got != c.error {
				t.Fatalf("the operator is told of two paid orders: %v\n%s", got, h.logs)
			}
		})
	}
}

func TestAnOrderFoundButStillOpenAsksForAPersonAfterTwoDays(t *testing.T) {
	for _, kind := range []string{"airtime", "bill"} {
		t.Run(kind, func(t *testing.T) {
			h := readyServicesHarness(t)
			id := heldOrder(t, h, kind, "open-1")
			h.exec.found[kind+":"+id] = []services.Result{{OrderID: "8123", Status: vouchers.StatusPending}}
			reconciler := &VoucherReconciler{Server: h.server, Store: h.store}

			h.clock.advance(3 * time.Hour)
			reconciler.Round(context.Background())
			if strings.Contains(h.logs.String(), "still unresolved") {
				t.Fatalf("three hours is not yet a reason to call anyone:\n%s", h.logs)
			}
			h.clock.advance(46 * time.Hour)
			reconciler.Round(context.Background())
			if !strings.Contains(h.logs.String(), "still unresolved") || !strings.Contains(h.logs.String(), "level=ERROR") {
				t.Fatalf("after two days it asks for a person:\n%s", h.logs)
			}
			// Said every hour, not every minute.
			lines := strings.Count(h.logs.String(), "still unresolved")
			h.clock.advance(time.Minute)
			reconciler.Round(context.Background())
			if strings.Count(h.logs.String(), "still unresolved") != lines {
				t.Fatalf("not again within the hour:\n%s", h.logs)
			}
			if purchase := h.purchase("open-1"); purchase.Status != "pending" {
				t.Fatalf("and it stays held: %s", brief(purchase))
			}
		})
	}
}

// ---- the sandbox is not real money ----

func TestASandboxOrderIsMarkedTestEverywhereButStillPlacedWithReloadly(t *testing.T) {
	h := readyServicesHarness(t, func(cfg *services.Config) { cfg.Sandbox = true })

	// The directory a shop reads says it is a test.
	_, directory := h.call(http.MethodGet, "/v1/services/directory", nil)
	if directory["test_mode"] != true || directory["configured"] != true {
		t.Fatalf("directory: test_mode=%v configured=%v", directory["test_mode"], directory["configured"])
	}

	status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("sandbox-1"))
	purchase := svcObject(t, body["purchase"])
	receipt := svcObject(t, purchase["receipt"])
	if status != http.StatusCreated || purchase["test_mode"] != true || receipt["test_mode"] != "true" {
		t.Fatalf("a sandbox order is a test order: %d %v", status, body)
	}
	// It was really placed, with Reloadly (the sandbox), not with the fake supplier.
	if h.exec.calls() != 1 {
		t.Fatalf("the executor of Reloadly was called %d times", h.exec.calls())
	}
	row := h.purchase("sandbox-1")
	if row.Supplier != "reloadly" || !row.TestMode || !strings.HasPrefix(row.SupplierOrderID, "airtime:") {
		t.Fatalf("row: supplier %s test %v order %s", row.Supplier, row.TestMode, row.SupplierOrderID)
	}
	// The statement entry of the charge is marked too.
	entries, err := h.store.(control.WalletStore).ListWalletEntries(context.Background(), control.WalletEntryFilter{
		InstallationID: h.shop.Installation.ID, Account: control.WalletAccountVouchers, Limit: 50})
	if err != nil {
		t.Fatal(err)
	}
	charges := 0
	for _, entry := range entries {
		if entry.Kind == control.WalletEntryCharge && strings.HasPrefix(entry.IdempotencyKey, "voucher:") {
			charges++
			if !entry.TestMode {
				t.Fatalf("the charge for a sandbox order is a test entry: %+v", entry)
			}
		}
	}
	if charges == 0 {
		t.Fatalf("no charge found among %d entries", len(entries))
	}

	// Read back later, replayed, the receipt still says so.
	status, read := h.call(http.MethodGet, "/v1/services/orders/sandbox-1", nil)
	if status != http.StatusOK || svcObject(t, svcObject(t, read["purchase"])["receipt"])["test_mode"] != "true" {
		t.Fatalf("read back: %d %v", status, read)
	}
	status, replay := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("sandbox-1"))
	if status != http.StatusOK || svcObject(t, svcObject(t, replay["purchase"])["receipt"])["test_mode"] != "true" {
		t.Fatalf("replay: %d %v", status, replay)
	}
	// A bill too.
	status, bill := h.call(http.MethodPost, "/v1/services/orders", svcBillBody("sandbox-2"))
	if status != http.StatusCreated || svcObject(t, svcObject(t, bill["purchase"])["receipt"])["test_mode"] != "true" {
		t.Fatalf("bill: %d %v", status, bill)
	}
	// A refused order is refunded, and the refund is a test entry too.
	h.exec.onAirtime = func(services.AirtimeOrder) (services.Result, error) {
		return services.Result{}, &vouchers.Failure{Code: vouchers.FailureRefused, Detail: "invalid recipient", Definite: true}
	}
	if status, refused := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("sandbox-3")); status != http.StatusBadGateway || svcObject(t, refused["purchase"])["test_mode"] != true {
		t.Fatalf("refused: %d %v", status, refused)
	}
	entries, err = h.store.(control.WalletStore).ListWalletEntries(context.Background(), control.WalletEntryFilter{
		InstallationID: h.shop.Installation.ID, Account: control.WalletAccountVouchers, Limit: 50})
	if err != nil {
		t.Fatal(err)
	}
	refunds := 0
	for _, entry := range entries {
		if entry.Kind == control.WalletEntryRefund {
			refunds++
			if !entry.TestMode {
				t.Fatalf("the refund of a sandbox order is a test entry: %+v", entry)
			}
		}
	}
	if refunds != 1 {
		t.Fatalf("one refund, found %d", refunds)
	}
	// The operator sees which kind of test it is.
	_, config := h.admin(http.MethodGet, "/v1/services/admin/config", "")
	stats := svcObject(t, config["stats"])
	if stats["sandbox"] != true || stats["test_mode"] != false || stats["supplier"] != "reloadly" {
		t.Fatalf("stats: %v", stats)
	}
}

func TestALiveOrderCarriesNoTestMarkAnywhere(t *testing.T) {
	h := readyServicesHarness(t)
	_, directory := h.call(http.MethodGet, "/v1/services/directory", nil)
	if directory["test_mode"] != false {
		t.Fatalf("directory: %v", directory["test_mode"])
	}
	status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("live-1"))
	purchase := svcObject(t, body["purchase"])
	if _, marked := svcObject(t, purchase["receipt"])["test_mode"]; status != http.StatusCreated || purchase["test_mode"] != false || marked {
		t.Fatalf("a live order is not marked: %d %v", status, body)
	}
}

func TestTheFakeSupplierMarksItsReceiptsToo(t *testing.T) {
	h := newServicesHarness(t, func(cfg *services.Config) {
		cfg.TestMode = true
		cfg.Reloadly = nil
	})
	h.publishSettings(`{"usd_rate": "9.71"}`)
	h.fund("200")
	status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("fake-1"))
	if status != http.StatusCreated || svcObject(t, svcObject(t, body["purchase"])["receipt"])["test_mode"] != "true" {
		t.Fatalf("%d %v", status, body)
	}
}

// ---- a directory nobody has been able to refresh ----

func TestQuotesAndOrdersAreRefusedWhenTheDirectoryIsStale(t *testing.T) {
	h := readyServicesHarness(t, func(cfg *services.Config) { cfg.Interval = 15 * time.Minute })
	read := func() (int, map[string]any) {
		return h.call(http.MethodGet, "/v1/services/directory", nil)
	}
	if status, _ := read(); status != http.StatusOK {
		t.Fatalf("directory: %d", status)
	}
	quoteBody := map[string]any{"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"}

	h.clock.advance(44 * time.Minute)
	if status, body := h.call(http.MethodPost, "/v1/services/quote", quoteBody); status != http.StatusOK {
		t.Fatalf("44 minutes: %d %v", status, body)
	}

	h.clock.advance(2 * time.Minute)
	before := h.balance()
	status, body := h.call(http.MethodPost, "/v1/services/quote", quoteBody)
	if status != http.StatusConflict || body["code"] != "service_unavailable" || body["reason"] != "stale" {
		t.Fatalf("a stale quote: %d %v", status, body)
	}
	status, body = h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("stale-1"))
	if status != http.StatusConflict || body["code"] != "service_unavailable" || body["reason"] != "stale" {
		t.Fatalf("a stale order: %d %v", status, body)
	}
	if h.exec.calls() != 0 || h.balance() != before {
		t.Fatal("nothing is placed or charged from a stale directory")
	}
	if _, found, _ := h.store.FindVoucherPurchaseByKey(context.Background(), h.shop.Installation.ID, "stale-1"); found {
		t.Fatal("and no purchase is claimed")
	}
	// The directory can still be looked at.
	if status, _ := read(); status != http.StatusOK {
		t.Fatalf("directory: %d", status)
	}
	// The operator is told.
	_, config := h.admin(http.MethodGet, "/v1/services/admin/config", "")
	stats := svcObject(t, config["stats"])
	if stats["stale"] != true || stats["stale_after"] != "45m0s" {
		t.Fatalf("stats: %v", stats)
	}
	// Reloadly is read again: sold again.
	if err := h.service.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	if status, body := h.call(http.MethodPost, "/v1/services/quote", quoteBody); status != http.StatusOK {
		t.Fatalf("fresh again: %d %v", status, body)
	}
	if status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("stale-1")); status != http.StatusCreated {
		t.Fatalf("an order again: %d %v", status, body)
	}
}

func TestAReplayIsAnsweredEvenWhenTheDirectoryIsStale(t *testing.T) {
	h := readyServicesHarness(t, func(cfg *services.Config) { cfg.Interval = 15 * time.Minute })
	if status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("replay-stale")); status != http.StatusCreated {
		t.Fatalf("first: %d %v", status, body)
	}
	h.clock.advance(3 * time.Hour)
	// The shop lost the answer: asking again must still give it (the money is spent).
	status, replay := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("replay-stale"))
	if status != http.StatusOK || replay["replayed"] != true {
		t.Fatalf("replay: %d %v", status, replay)
	}
	if status, _ := h.call(http.MethodGet, "/v1/services/orders/replay-stale", nil); status != http.StatusOK {
		t.Fatalf("read: %d", status)
	}
}

// ---- a supplier that changes its terms ----

// editableServiceSource is the fixture with edits applied, which can change
// between two readings.
type editableServiceSource struct {
	mu   sync.Mutex
	edit func(*services.Raw)
}

func (s *editableServiceSource) Load(ctx context.Context) (services.Raw, error) {
	raw, err := services.FixtureSource{}.Load(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	if err == nil && s.edit != nil {
		s.edit(&raw)
	}
	return raw, err
}

func (s *editableServiceSource) set(edit func(*services.Raw)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.edit = edit
}

func TestACommissionChangeAtTheSupplierMovesTheETagAndTheQuote(t *testing.T) {
	source := &editableServiceSource{}
	h := readyServicesHarness(t, func(cfg *services.Config) { cfg.Source = source })
	quoteBody := map[string]any{"kind": "airtime", "operator_id": 289, "amount": "5000", "amount_currency": "XOF"}

	directory := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken}, nil)
	oldTag := directory.Header().Get("ETag")
	_, quoted := h.call(http.MethodPost, "/v1/services/quote", quoteBody)
	oldPrice := svcObject(t, quoted["quote"])["unit_price"]
	if oldTag == "" || oldPrice == nil {
		t.Fatalf("etag %q price %v", oldTag, oldPrice)
	}
	// Nothing changed: the shop's copy is current.
	same := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken, "If-None-Match": oldTag}, nil)
	if same.Code != http.StatusNotModified {
		t.Fatalf("not modified: %d", same.Code)
	}

	// Reloadly cuts Orange Mali's commission from 5 to 1 percent.
	source.set(func(raw *services.Raw) {
		for i := range raw.Operators {
			if raw.Operators[i].Key() == 289 {
				raw.Operators[i].Commission, raw.Operators[i].InternationalDiscount = "1.0", "1.0"
			}
		}
	})
	h.clock.advance(15 * time.Minute)
	if err := h.service.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	changed := h.serve(http.MethodGet, "/v1/services/directory", map[string]string{AccessTokenHeader: h.shop.AccessToken, "If-None-Match": oldTag}, nil)
	if changed.Code != http.StatusOK || changed.Header().Get("ETag") == oldTag {
		t.Fatalf("the shop's copy is out of date: %d %q (was %q)", changed.Code, changed.Header().Get("ETag"), oldTag)
	}
	_, requoted := h.call(http.MethodPost, "/v1/services/quote", quoteBody)
	if newPrice := svcObject(t, requoted["quote"])["unit_price"]; newPrice == oldPrice {
		t.Fatalf("the quote follows the supplier: still %v", newPrice)
	}
	// An order quoted at the old price is refused, to be quoted again.
	order := svcAirtimeBody("repriced-1")
	order["max_unit_price"] = oldPrice
	status, refused := h.call(http.MethodPost, "/v1/services/orders", order)
	if status != http.StatusConflict || refused["code"] != "price_changed" {
		t.Fatalf("an order at the old price: %d %v", status, refused)
	}
}

// ---- a key reused for another number is not a replay ----

// The ledger keeps only the masked number, so two numbers that end alike share a
// mask. A replay must still be told from a different order: by a keyed digest of
// the full target, which is all the ledger holds of it.
func TestAKeyReusedForAnotherTargetWithTheSameMaskIsNotAReplay(t *testing.T) {
	order := func(key string, edit map[string]any) map[string]any {
		body := map[string]any{
			"kind": "airtime", "operator_id": 289, "country": "ML", "phone": "70123456",
			"amount": "5000", "amount_currency": "XOF", "idempotency_key": key, "requested_by": "cashier",
		}
		for field, value := range edit {
			body[field] = value
		}
		return body
	}
	bill := func(key string, edit map[string]any) map[string]any {
		body := svcBillBody(key)
		for field, value := range edit {
			body[field] = value
		}
		return body
	}
	invoiceBill := func(key string, edit map[string]any) map[string]any {
		body := map[string]any{
			"kind": "bill", "biller_id": 23, "country": "SN", "account": "123456789", "invoice_id": "2024-118833",
			"amount": "5000", "amount_currency": "XOF", "idempotency_key": key, "requested_by": "cashier",
		}
		for field, value := range edit {
			body[field] = value
		}
		return body
	}
	for _, c := range []struct {
		name   string
		first  map[string]any
		replay map[string]any
		status int // of the second request
	}{
		{"the same top-up again", order("k", nil), order("k", nil), http.StatusOK},
		{"the same number written another way", order("k", nil), order("k", map[string]any{"phone": "+223 70 12 34 56"}), http.StatusOK},
		{"with the trunk zero and the 00 prefix", order("k", nil), order("k", map[string]any{"phone": "0022370123456"}), http.StatusOK},
		{"another number with the same mask", order("k", nil), order("k", map[string]any{"phone": "71123456"}), http.StatusConflict},
		{"another number ending the same", order("k", nil), order("k", map[string]any{"phone": "60123456"}), http.StatusConflict},
		{"a number that is no number", order("k", nil), order("k", map[string]any{"phone": "abc"}), http.StatusConflict},
		{"the same bill again", bill("k", nil), bill("k", nil), http.StatusOK},
		{"the same account with spaces", bill("k", nil), bill("k", map[string]any{"account": "145 000 000 01"}), http.StatusOK},
		{"another account with the same last digits", bill("k", nil), bill("k", map[string]any{"account": "14599999001"}), http.StatusConflict},
		{"the same bill with a stray invoice (this biller has none)", bill("k", nil), bill("k", map[string]any{"invoice_id": "X-1"}), http.StatusOK},
		{"the same invoice bill again", invoiceBill("k", nil), invoiceBill("k", nil), http.StatusOK},
		{"another invoice", invoiceBill("k", nil), invoiceBill("k", map[string]any{"invoice_id": "2024-118834"}), http.StatusConflict},
		{"no invoice at all", invoiceBill("k", nil), invoiceBill("k", map[string]any{"invoice_id": nil}), http.StatusConflict},
		{"another account on an invoice bill", invoiceBill("k", nil), invoiceBill("k", map[string]any{"account": "923456789"}), http.StatusConflict},
	} {
		t.Run(c.name, func(t *testing.T) {
			h := readyServicesHarness(t)
			status, first := h.call(http.MethodPost, "/v1/services/orders", c.first)
			if status != http.StatusCreated {
				t.Fatalf("first: %d %v", status, first)
			}
			status, second := h.call(http.MethodPost, "/v1/services/orders", c.replay)
			if status != c.status {
				t.Fatalf("second: %d %v, want %d", status, second, c.status)
			}
			if c.status == http.StatusOK && (second["replayed"] != true ||
				svcObject(t, second["purchase"])["id"] != svcObject(t, first["purchase"])["id"]) {
				t.Fatalf("a true replay is the first answer: %v", second)
			}
			if c.status == http.StatusConflict && second["code"] != "idempotency_key_reused" {
				t.Fatalf("a different order under the key: %v", second)
			}
			if h.exec.calls() != 1 {
				t.Fatalf("one order placed, not %d", h.exec.calls())
			}
			// The ledger keeps a digest of the target, never the target.
			row := h.purchase("k")
			details := string(row.Details)
			for _, secret := range []string{"70123456", "145000000", "14500000001", "123456789", "2024-118833"} {
				if strings.Contains(details, secret) || strings.Contains(h.logs.String(), secret) {
					t.Fatalf("%q must be neither stored nor logged:\n%s\n%s", secret, details, h.logs)
				}
			}
			if !strings.Contains(details, `"target_digest":"`) {
				t.Fatalf("the digest is kept: %s", details)
			}
		})
	}
}

// An order whose digest cannot be checked (placed before digests existed, or
// with a key that has since been replaced) is judged by its mask, as it always
// was: never refused as a different order on the strength of a digest nobody can
// read.
func TestAReplayOfARowWithoutAUsableDigestIsJudgedByItsMask(t *testing.T) {
	for _, c := range []struct {
		name  string
		first []byte // the key the order was placed under; nil, none
		later []byte // the key now
	}{
		{"placed without a key", nil, []byte("key-now")},
		{"the key was replaced", []byte("key-before"), []byte("key-now")},
		{"the key was removed", []byte("key-before"), nil},
	} {
		t.Run(c.name, func(t *testing.T) {
			h := readyServicesHarness(t, func(cfg *services.Config) { cfg.TargetKey = c.first })
			status, first := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("rotated"))
			if status != http.StatusCreated {
				t.Fatalf("first: %d %v", status, first)
			}
			later := services.New(services.Config{
				Source: services.FixtureSource{}, Reloadly: h.exec, Namer: testServiceNames{}, Now: h.clock.Now,
				RequestTimeout: 5 * time.Second, SettleWait: time.Second, TargetKey: c.later,
			})
			if err := later.Refresh(context.Background()); err != nil {
				t.Fatal(err)
			}
			h.server.Services = later
			// The same order is a replay.
			if status, replay := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("rotated")); status != http.StatusOK || replay["replayed"] != true {
				t.Fatalf("replay: %d %v", status, replay)
			}
			// A number whose mask differs is another order, digest or not.
			other := svcAirtimeBody("rotated")
			other["phone"] = "70123999"
			if status, reused := h.call(http.MethodPost, "/v1/services/orders", other); status != http.StatusConflict || reused["code"] != "idempotency_key_reused" {
				t.Fatalf("another mask: %d %v", status, reused)
			}
			if h.exec.calls() != 1 {
				t.Fatalf("one order placed, not %d", h.exec.calls())
			}
		})
	}
}

// ---- amounts ----

func TestAFractionalAmountOfAWholeCurrencyIsRefusedAtTheDoor(t *testing.T) {
	h := readyServicesHarness(t)
	for _, body := range []map[string]any{
		{"kind": "airtime", "operator_id": 289, "amount": "5000.5", "amount_currency": "XOF"},
		{"kind": "bill", "biller_id": 26, "amount": "5000.25", "amount_currency": "XOF"},
	} {
		status, refused := h.call(http.MethodPost, "/v1/services/quote", body)
		if status != http.StatusUnprocessableEntity || refused["code"] != "invalid_amount" {
			t.Fatalf("quote %v: %d %v", body["kind"], status, refused)
		}
	}
	before := h.balance()
	order := svcAirtimeBody("fraction-1")
	order["amount"] = "5000.5"
	status, refused := h.call(http.MethodPost, "/v1/services/orders", order)
	if status != http.StatusUnprocessableEntity || refused["code"] != "invalid_amount" {
		t.Fatalf("order: %d %v", status, refused)
	}
	bill := svcBillBody("fraction-2")
	bill["amount"] = "5000.25"
	if status, refused := h.call(http.MethodPost, "/v1/services/orders", bill); status != http.StatusUnprocessableEntity || refused["code"] != "invalid_amount" {
		t.Fatalf("bill order: %d %v", status, refused)
	}
	if h.exec.calls() != 0 || h.balance() != before {
		t.Fatal("nothing is placed or charged for it")
	}
	for _, key := range []string{"fraction-1", "fraction-2"} {
		if _, found, _ := h.store.FindVoucherPurchaseByKey(context.Background(), h.shop.Installation.ID, key); found {
			t.Fatalf("%s: no purchase is claimed", key)
		}
	}
	// A whole amount written with decimals is still the same amount.
	whole := svcAirtimeBody("fraction-3")
	whole["amount"] = "5000.00"
	if status, body := h.call(http.MethodPost, "/v1/services/orders", whole); status != http.StatusCreated {
		t.Fatalf("5000.00: %d %v", status, body)
	}
}

func TestAShortDeliveryIsCountedWhateverDecimalsTheSupplierWrites(t *testing.T) {
	h := readyServicesHarness(t)
	h.exec.onAirtime = func(order services.AirtimeOrder) (services.Result, error) {
		return services.Result{OrderID: "7101", Status: vouchers.StatusSucceeded, CostUSD: "9.45298", Receipt: map[string]string{
			services.ReceiptTransactionID: "7101", services.ReceiptDeliveredAmount: "4999.99999999999", services.ReceiptDeliveredCurrency: "XOF",
		}}, nil
	}
	status, body := h.call(http.MethodPost, "/v1/services/orders", svcAirtimeBody("short-1"))
	receipt := svcObject(t, svcObject(t, body["purchase"])["receipt"])
	if status != http.StatusCreated || receipt["delivered_amount"] != "4999.99999999999" {
		t.Fatalf("the shop gets the supplier's figure as written: %d %v", status, body)
	}
	if got := h.service.Stats().ShortDeliveries; got != 1 {
		t.Fatalf("a delivery that fell short is counted: %d", got)
	}
	// More than quoted (the buffer) is not short.
	h.exec.onAirtime = func(order services.AirtimeOrder) (services.Result, error) {
		return services.Result{OrderID: "7102", Status: vouchers.StatusSucceeded, CostUSD: "9.45298", Receipt: map[string]string{
			services.ReceiptTransactionID: "7102", services.ReceiptDeliveredAmount: "5025.0003", services.ReceiptDeliveredCurrency: "XOF",
		}}, nil
	}
	order := svcAirtimeBody("short-2")
	order["phone"] = "71123456"
	if status, body := h.call(http.MethodPost, "/v1/services/orders", order); status != http.StatusCreated {
		t.Fatalf("%d %v", status, body)
	}
	if got := h.service.Stats().ShortDeliveries; got != 1 {
		t.Fatalf("not counted again: %d", got)
	}
}

// ---- the log names what it is about ----

func TestTheReconcilerCallsAServiceOrderAServiceOrderAndNeverPrintsItsNumber(t *testing.T) {
	h := readyServicesHarness(t)
	heldOrder(t, h, "airtime", "log-1")
	// Reloadly's history cannot be read, and the sentence it gives back echoes a number.
	h.exec.findErr = fmt.Errorf("reloadly: the history of recipient 22370123456 is unavailable")
	(&VoucherReconciler{Server: h.server, Store: h.store, Logger: h.server.Logger}).Round(context.Background())
	logs := h.logs.String()
	if !strings.Contains(logs, "checking a held service order failed") || !strings.Contains(logs, "kind=airtime") {
		t.Fatalf("a service order is named as one:\n%s", logs)
	}
	if strings.Contains(logs, "card purchase") {
		t.Fatalf("it is not a card:\n%s", logs)
	}
	if strings.Contains(logs, "22370123456") {
		t.Fatalf("a customer's number never reaches the log:\n%s", logs)
	}

	// A card keeps its own words.
	if got := heldNoun(control.VoucherPurchase{Kind: "card"}); got != "card purchase" {
		t.Fatalf("card: %s", got)
	}
	if got := heldNoun(control.VoucherPurchase{}); got != "card purchase" {
		t.Fatalf("a row from before kinds existed is a card: %s", got)
	}
	if got := heldNoun(control.VoucherPurchase{Kind: "bill"}); got != "service order" {
		t.Fatalf("bill: %s", got)
	}
}

// ---- a number of the wrong length is refused before anything is charged ----

func TestANumberOutsideTheLengthsOfItsCountryIsRefusedEverywhere(t *testing.T) {
	h := readyServicesHarness(t)
	_, directory := h.call(http.MethodGet, "/v1/services/directory", nil)
	firstAmount := func(code string, id float64) string {
		for _, entry := range directory["countries"].([]any) {
			country := svcObject(t, entry)
			if country["code"] != code {
				continue
			}
			for _, raw := range svcObject(t, country["airtime"])["operators"].([]any) {
				operator := svcObject(t, raw)
				if operator["id"] == id {
					return svcObject(t, operator["amounts"].([]any)[0])["amount"].(string)
				}
			}
		}
		t.Fatalf("operator %v of %s is not in the directory", id, code)
		return ""
	}
	for _, c := range []struct {
		country  string
		operator int
		good     []string // real numbers, in the forms people type them
		bad      []string // the mistakes: a digit short, a digit too many, a zero too few
	}{
		{"ML", 289, []string{"70123456", "+223 70 12 34 56", "0022370123456"}, []string{"6123456", "701234567", "+223 6123456"}},
		{"NG", 341, []string{"8031234567", "08031234567", "+234 803 123 4567"}, []string{"80123456789", "803123456", "0803123456"}},
		{"CI", 252, []string{"0707123456", "07 07 12 34 56", "+225 07 07 12 34 56"}, []string{"707123456", "07123456", "+225 707123456"}},
	} {
		amount := firstAmount(c.country, float64(c.operator))
		quote := func(phone string) map[string]any {
			return map[string]any{"kind": "airtime", "operator_id": c.operator, "country": c.country, "phone": phone, "amount": amount, "amount_currency": svcCurrency(t, directory, c.country)}
		}
		for _, bad := range c.bad {
			status, refused := h.call(http.MethodPost, "/v1/services/quote", quote(bad))
			if status != http.StatusUnprocessableEntity || refused["code"] != "invalid_phone" {
				t.Errorf("%s quote of %q: %d %v", c.country, bad, status, refused)
			}
			order := quote(bad)
			order["idempotency_key"], order["requested_by"] = "bad-"+c.country+"-"+bad, "cashier"
			before := h.balance()
			status, refused = h.call(http.MethodPost, "/v1/services/orders", order)
			if status != http.StatusUnprocessableEntity || refused["code"] != "invalid_phone" || h.balance() != before {
				t.Errorf("%s order of %q: %d %v (balance %s -> %s)", c.country, bad, status, refused, before, h.balance())
			}
			status, refused = h.call(http.MethodPost, "/v1/services/detect", map[string]any{"country": c.country, "phone": bad})
			if status != http.StatusUnprocessableEntity || refused["code"] != "invalid_phone" {
				t.Errorf("%s detect of %q: %d %v", c.country, bad, status, refused)
			}
		}
		for i, good := range c.good {
			status, quoted := h.call(http.MethodPost, "/v1/services/quote", quote(good))
			if status != http.StatusOK || quoted["phone"] == nil {
				t.Errorf("%s quote of %q: %d %v", c.country, good, status, quoted)
				continue
			}
			order := quote(good)
			order["idempotency_key"], order["requested_by"] = "good-"+c.country+"-"+string(rune('a'+i)), "cashier"
			if status, body := h.call(http.MethodPost, "/v1/services/orders", order); status != http.StatusCreated {
				t.Errorf("%s order of %q: %d %v", c.country, good, status, body)
			}
		}
	}
	// Nothing bad was ever placed: the supplier only saw the good numbers.
	if h.exec.calls() != 9 {
		t.Fatalf("nine good orders, %d calls", h.exec.calls())
	}
}

// svcCurrency is the currency a country's operators are sold in.
func svcCurrency(t *testing.T, directory map[string]any, code string) string {
	t.Helper()
	for _, entry := range directory["countries"].([]any) {
		if country := svcObject(t, entry); country["code"] == code {
			return country["currency"].(string)
		}
	}
	t.Fatalf("%s is not in the directory", code)
	return ""
}
