package relay

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
	"pointy/relay/internal/vouchers/reloadlyfake"
)

// --- the company's balance at a supplier ---------------------------------------

// realReloadlyHarness is the card shop with the real Reloadly adapter over a
// stand-in for Reloadly's API, beside the fake BN Plus.
type realReloadlyHarness struct {
	*dualHarness
	fake *reloadlyfake.Fake
}

func newRealReloadlyHarness(t *testing.T) *realReloadlyHarness {
	t.Helper()
	h := &realReloadlyHarness{dualHarness: newDualHarness(t), fake: reloadlyfake.New(t)}
	// PlayStation US at Reloadly, 48.5 % off: a 20 card costs 10.30 dollars,
	// 103 dinars at a rate of 10, against BN Plus's 104.50.
	h.fake.AddProduct(reloadlyfake.Product{
		ID: 13441, Name: "PlayStation US", Brand: "PlayStation", Denomination: "FIXED",
		Fixed: []string{"10", "20", "25", "50"}, Discount: "48.5",
	})
	h.server.Vouchers.Suppliers[vouchers.SupplierReloadly] = &vouchers.ReloadlySupplier{Client: h.fake.Client()}
	// The adapter stamps what it reads with the real time, so the relay judges
	// by it too.
	h.server.Clock = testClock{now: time.Now()}
	// BN Plus is read in full by the sync: say what the harness stored.
	now := time.Now()
	h.supplier.offers = []vouchers.Offer{
		{Ref: "201", Name: "PlayStation 20 USD", Price: "104.50", Currency: "LYD", InStock: true, SyncedAt: now},
		{Ref: "202", Name: "PlayStation 10 USD", Price: "55.00", Currency: "LYD", InStock: true, SyncedAt: now},
		{Ref: "203", Name: "PlayStation 25 USD", Price: "130.00", Currency: "LYD", InStock: true, SyncedAt: now},
		{Ref: "204", Name: "PlayStation 5 USD", Price: "28.00", Currency: "LYD", InStock: true, SyncedAt: now},
	}
	return h
}

// sync reads every supplier's offers, the Reloadly balance with them.
func (h *realReloadlyHarness) sync(t *testing.T) {
	t.Helper()
	counts, err := SyncVoucherOffers(context.Background(), h.server.Vouchers, h.store)
	if err != nil || counts[vouchers.SupplierReloadly] != 4 || counts[vouchers.SupplierBNPlus] != 4 {
		t.Fatalf("sync: %v %v", counts, err)
	}
}

func (h *realReloadlyHarness) ordersPlaced() int { return h.fake.CallsTo(http.MethodPost, "/orders") }

func (h *dualHarness) adminSupply(t *testing.T, item string) map[string]any {
	t.Helper()
	status, body := h.admin(t, http.MethodGet, "/v1/vouchers/admin/catalog", "", nil)
	if status != http.StatusOK {
		t.Fatalf("admin catalog: %d %v", status, body)
	}
	for _, row := range body["supply"].([]any) {
		if entry := row.(map[string]any); entry["item"] == item {
			return entry
		}
	}
	t.Fatalf("no supply for %s", item)
	return nil
}

func (h *dualHarness) shopViewItem(t *testing.T, server HTTPServer, key string) vouchers.ShopItem {
	t.Helper()
	recorder := h.request(t, server, http.MethodGet, "/v1/vouchers/catalog", map[string]string{AccessTokenHeader: h.shopper.AccessToken}, nil)
	var view vouchers.ShopView
	if err := json.Unmarshal(recorder.Body.Bytes(), &view); err != nil || recorder.Code != http.StatusOK {
		t.Fatalf("catalog: %d %s", recorder.Code, recorder.Body)
	}
	for _, brand := range view.Brands {
		for _, item := range brand.Items {
			if item.Key == key {
				return item
			}
		}
	}
	t.Fatalf("no item %s in %+v", key, view)
	return vouchers.ShopItem{}
}

// nextBNPlusOrder makes BN Plus's next order a different one: the ledger refuses
// two purchases on one order.
func (h *dualHarness) nextBNPlusOrder(id string) { h.supplier.buyResult.OrderID = id }

func TestAZeroDollarReloadlyNeverGetsARequestWhenBNPlusIsListed(t *testing.T) {
	h := newRealReloadlyHarness(t)
	h.fake.SetBalance("0")
	h.sync(t)

	// psn-20 is cheaper at Reloadly (103 dinars against 104.50), but the account
	// cannot pay for it: BN Plus sells it, and Reloadly is never asked.
	status, body := h.buy(t, "psn-20", "empty-1")
	if status != http.StatusCreated || h.row(t, "empty-1").Supplier != vouchers.SupplierBNPlus {
		t.Fatalf("%d %v", status, body)
	}
	if h.ordersPlaced() != 0 {
		t.Fatalf("a request reached an account with nothing in it: %v", h.fake.Calls())
	}
	// A card only Reloadly sells is not on the shelf, and the reason says why.
	status, body = h.buy(t, "psn-50", "empty-2")
	reason, _ := body["error"].(string)
	if status != http.StatusConflict || body["code"] != "item_unavailable" || !strings.Contains(reason, "balance at reloadly is 0.00 USD") {
		t.Fatalf("%d %v", status, body)
	}
	if item := h.shopViewItem(t, h.server, "psn-50"); item.Available {
		t.Fatalf("psn-50 must show as unavailable: %+v", item)
	}
	if item := h.shopViewItem(t, h.server, "psn-20"); !item.Available {
		t.Fatalf("psn-20 sells from BN Plus: %+v", item)
	}
	supply := h.adminSupply(t, "psn-20")
	reloadlyEntry := supply["suppliers"].([]any)[1].(map[string]any)
	if supply["winner"] != "bnplus" || reloadlyEntry["candidate"] != false || !strings.Contains(reloadlyEntry["reason"].(string), "balance") {
		t.Fatalf("the operator sees why: %v", supply)
	}
	if h.ordersPlaced() != 0 {
		t.Fatal("still no request")
	}

	// The account is filled and the offers are read again: Reloadly sells.
	h.fake.SetBalance("1000")
	h.sync(t)
	h.nextBNPlusOrder("452")
	if status, body := h.buy(t, "psn-20", "empty-3"); status != http.StatusCreated || h.row(t, "empty-3").Supplier != vouchers.SupplierReloadly {
		t.Fatalf("%d %v", status, body)
	}
	if h.ordersPlaced() != 1 {
		t.Fatalf("one order: %d", h.ordersPlaced())
	}
}

func TestABalanceReadLongAgoIsNotBelieved(t *testing.T) {
	h := newRealReloadlyHarness(t)
	h.fake.SetBalance("0")
	h.sync(t)

	// Two hours on, with the sync silent, "nothing left" is not known any more:
	// Reloadly is asked, refuses for want of money (a definite failure), and
	// BN Plus sells.
	late := h.at(time.Now().Add(3 * time.Hour))
	if status, body := h.buyAt(t, late, "psn-20", "late-1"); status != http.StatusCreated || h.row(t, "late-1").Supplier != vouchers.SupplierBNPlus {
		t.Fatalf("%d %v", status, body)
	}
	if h.ordersPlaced() != 1 {
		t.Fatalf("Reloadly is asked once the balance is too old to believe: %d", h.ordersPlaced())
	}
	// Within the two hours the empty account still keeps the card off.
	h.nextBNPlusOrder("453")
	soon := h.at(time.Now().Add(time.Hour))
	if status, body := h.buyAt(t, soon, "psn-20", "soon-1"); status != http.StatusCreated || h.ordersPlaced() != 1 {
		t.Fatalf("%d %v, orders %d", status, body, h.ordersPlaced())
	}
}

// balanceSupplier is a supplier that knows its balance.
type balanceSupplier struct {
	*fakeSupplier
	amount, currency string
	readAt           time.Time
	known            bool
}

func (b *balanceSupplier) Key() string { return vouchers.SupplierReloadly }

func (b *balanceSupplier) LastBalance() (*big.Rat, string, time.Time, bool) {
	if !b.known {
		return nil, "", time.Time{}, false
	}
	amount, _ := new(big.Rat).SetString(b.amount)
	return amount, b.currency, b.readAt, true
}

func TestTheBalanceKeepsOnlyCardsItCanPayForOffTheShelf(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	bn := vouchers.Ref{Supplier: vouchers.SupplierBNPlus, ID: "1"}
	rl := vouchers.Ref{Supplier: vouchers.SupplierReloadly, ID: "9/20"}
	bnOffer := control.VoucherOffer{Supplier: "bnplus", Ref: "1", Price: "105", Currency: "LYD", InStock: true}
	rlOffer := control.VoucherOffer{Supplier: "reloadly", Ref: "9/20", Price: "10.40", Currency: "USD", InStock: true}
	rate10 := vouchers.DefaultSettings()
	rate10.USDRate = "10"
	funded := rate10
	funded.FundingPercent = "5"

	cases := []struct {
		name     string
		balance  balanceSupplier
		refs     []vouchers.Ref
		settings vouchers.Settings
		want     string
	}{
		{"less than the price", balanceSupplier{amount: "5", currency: "USD", readAt: now.Add(-time.Hour), known: true}, []vouchers.Ref{bn, rl}, rate10, "bnplus"},
		{"just under the price", balanceSupplier{amount: "10.39", currency: "USD", readAt: now.Add(-time.Minute), known: true}, []vouchers.Ref{bn, rl}, rate10, "bnplus"},
		{"exactly the price", balanceSupplier{amount: "10.40", currency: "USD", readAt: now.Add(-time.Minute), known: true}, []vouchers.Ref{bn, rl}, rate10, "reloadly,bnplus"},
		{"plenty", balanceSupplier{amount: "812.5", currency: "USD", readAt: now.Add(-time.Minute), known: true}, []vouchers.Ref{bn, rl}, rate10, "reloadly,bnplus"},
		{"an empty account", balanceSupplier{amount: "0", currency: "USD", readAt: now.Add(-time.Minute), known: true}, []vouchers.Ref{bn, rl}, rate10, "bnplus"},
		{"read a minute under the limit", balanceSupplier{amount: "0", currency: "USD", readAt: now.Add(-voucherBalanceMaxAge + time.Minute), known: true}, []vouchers.Ref{bn, rl}, rate10, "bnplus"},
		{"read exactly at the limit", balanceSupplier{amount: "0", currency: "USD", readAt: now.Add(-voucherBalanceMaxAge), known: true}, []vouchers.Ref{bn, rl}, rate10, "reloadly,bnplus"},
		{"read long ago", balanceSupplier{amount: "0", currency: "USD", readAt: now.Add(-24 * time.Hour), known: true}, []vouchers.Ref{bn, rl}, rate10, "reloadly,bnplus"},
		{"never read", balanceSupplier{known: false}, []vouchers.Ref{bn, rl}, rate10, "reloadly,bnplus"},
		{"in another currency", balanceSupplier{amount: "0", currency: "EUR", readAt: now, known: true}, []vouchers.Ref{bn, rl}, rate10, "reloadly,bnplus"},
		{"the funding fee changes nothing", balanceSupplier{amount: "10.39", currency: "USD", readAt: now, known: true}, []vouchers.Ref{bn, rl}, funded, "bnplus"},
		{"the only supplier", balanceSupplier{amount: "1", currency: "USD", readAt: now, known: true}, []vouchers.Ref{rl}, rate10, ""},
	}
	for _, tc := range cases {
		reloadlySupplier := tc.balance
		reloadlySupplier.fakeSupplier = newFakeSupplier()
		located, config, offers := cardRankInputs(tc.refs, []string{vouchers.SupplierBNPlus}, bnOffer, rlOffer)
		config.Suppliers[vouchers.SupplierReloadly] = &reloadlySupplier
		offers.now = now
		ranking := config.rankSuppliers(located, offers, tc.settings)
		if got := rankedCardSuppliers(ranking); got != tc.want {
			t.Errorf("%s: ranked %q, want %q (%+v)", tc.name, got, tc.want, ranking.Evaluations)
		}
		if tc.want == "" {
			if reason, attention := ranking.unavailable(); !strings.Contains(reason, "the company's balance at reloadly is 1.00 USD") ||
				!strings.Contains(reason, "below this card's price of 10.40 USD") || !attention {
				t.Errorf("%s: reason %q (%v)", tc.name, reason, attention)
			}
		}
	}
}

// --- a supplier that keeps failing ---------------------------------------------

func breakerOpenings(logs *voucherLogBuffer) int {
	return strings.Count(logs.String(), "the breaker opens")
}

// addVoucherFunds puts more money in the shop's voucher balance.
func (h *dualHarness) addVoucherFunds(t *testing.T, amount string) {
	t.Helper()
	if _, _, err := h.store.PostWalletEntry(context.Background(), control.WalletPosting{
		InstallationID: h.shopper.Installation.ID, Account: control.WalletAccountVouchers, Kind: control.WalletEntryAdjustment,
		Amount: amount, IdempotencyKey: "more-" + amount + "-" + t.Name(),
	}); err != nil {
		t.Fatal(err)
	}
}

func newBreakerHarness(t *testing.T) (*dualHarness, *voucherLogBuffer) {
	t.Helper()
	h := newDualHarness(t)
	h.addVoucherFunds(t, "1000")
	logs := &voucherLogBuffer{}
	h.server.Logger = slog.New(slog.NewTextHandler(logs, nil))
	h.server.Vouchers.Breaker = NewSupplierBreaker()
	return h, logs
}

func TestASupplierThatKeepsFailingIsSkippedForAWhile(t *testing.T) {
	h, logs := newBreakerHarness(t)
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureCredit, Detail: "insufficient balance", Definite: true}

	// The first purchase finds out: Reloadly refuses (its account is empty), BN
	// Plus sells, and the breaker opens, once, with an ERROR.
	if status, body := h.buy(t, "psn-20", "br-1"); status != http.StatusCreated || h.row(t, "br-1").Supplier != vouchers.SupplierBNPlus {
		t.Fatalf("%d %v", status, body)
	}
	if len(h.reloadly.calls()) != 1 || breakerOpenings(logs) != 1 || !strings.Contains(logs.String(), "level=ERROR") {
		t.Fatalf("calls %d, openings %d\n%s", len(h.reloadly.calls()), breakerOpenings(logs), logs.String())
	}

	// For the next minutes Reloadly is not asked while BN Plus can sell.
	h.nextBNPlusOrder("452")
	if status, body := h.buy(t, "psn-20", "br-2"); status != http.StatusCreated || h.row(t, "br-2").Supplier != vouchers.SupplierBNPlus {
		t.Fatalf("%d %v", status, body)
	}
	if len(h.reloadly.calls()) != 1 || breakerOpenings(logs) != 1 {
		t.Fatalf("the paused supplier must not be asked: calls %d, openings %d", len(h.reloadly.calls()), breakerOpenings(logs))
	}
	supply := h.adminSupply(t, "psn-20")
	entry := supply["suppliers"].([]any)[1].(map[string]any)
	if entry["candidate"] != false || !strings.Contains(entry["reason"].(string), "skipped for now") || supply["winner"] != "bnplus" {
		t.Fatalf("the operator sees it is paused: %v", supply)
	}
	if item := h.shopViewItem(t, h.server, "psn-20"); !item.Available {
		t.Fatal("a paused supplier never takes a card off the shelf while another sells it")
	}

	// A card only Reloadly sells is still asked: it is the only candidate.
	if status, body := h.buy(t, "psn-50", "br-3"); status != http.StatusBadGateway || body["code"] != "unavailable" {
		t.Fatalf("%d %v", status, body)
	}
	if len(h.reloadly.calls()) != 2 || breakerOpenings(logs) != 1 {
		t.Fatalf("the only candidate is tried, and the breaker stays open without a new alarm: calls %d, openings %d", len(h.reloadly.calls()), breakerOpenings(logs))
	}

	// Six minutes on the pause is over: Reloadly is tried again, fails the same
	// way, and the breaker opens again (a second alarm, not a hundred).
	h.nextBNPlusOrder("453")
	later := h.at(h.now.Add(6 * time.Minute))
	if status, body := h.buyAt(t, later, "psn-20", "br-4"); status != http.StatusCreated {
		t.Fatalf("%d %v", status, body)
	}
	if len(h.reloadly.calls()) != 3 || breakerOpenings(logs) != 2 {
		t.Fatalf("calls %d, openings %d", len(h.reloadly.calls()), breakerOpenings(logs))
	}

	// A sale closes it: after the next pause Reloadly works again, and the
	// purchase it serves leaves no pause behind.
	h.reloadly.buyErr = nil
	later = h.at(h.now.Add(12 * time.Minute))
	if status, body := h.buyAt(t, later, "psn-20", "br-5"); status != http.StatusCreated || h.row(t, "br-5").Supplier != vouchers.SupplierReloadly {
		t.Fatalf("%d %v", status, body)
	}
	if _, _, open := h.server.Vouchers.Breaker.paused(vouchers.SupplierReloadly, h.now.Add(12*time.Minute)); open {
		t.Fatal("a sale closes the breaker")
	}
	h.nextBNPlusOrder("454")
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureCredit, Detail: "insufficient balance", Definite: true}
	if status, _ := h.buyAt(t, later, "psn-20", "br-6"); status != http.StatusCreated || breakerOpenings(logs) != 3 {
		t.Fatalf("it opens again after having been closed: %d\n%s", breakerOpenings(logs), logs.String())
	}
}

func TestASaleClosesTheBreakerAtOnce(t *testing.T) {
	h, logs := newBreakerHarness(t)
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureCredit, Detail: "insufficient balance", Definite: true}
	if status, _ := h.buy(t, "psn-20", "close-1"); status != http.StatusCreated || breakerOpenings(logs) != 1 {
		t.Fatalf("it opens: %d", breakerOpenings(logs))
	}
	if _, _, open := h.server.Vouchers.Breaker.paused(vouchers.SupplierReloadly, h.now); !open {
		t.Fatal("open")
	}

	// The account is filled. A card only Reloadly sells is still asked while the
	// breaker is open, it sells, and the breaker closes: the very next purchase of
	// a card both sell goes to Reloadly again, without waiting out the pause.
	h.reloadly.buyErr = nil
	h.reloadly.buyResult.OrderID = "79002"
	if status, body := h.buy(t, "psn-50", "close-2"); status != http.StatusCreated {
		t.Fatalf("%d %v", status, body)
	}
	if _, _, open := h.server.Vouchers.Breaker.paused(vouchers.SupplierReloadly, h.now); open {
		t.Fatal("a sale closes the breaker")
	}
	h.reloadly.buyResult.OrderID = "79003"
	if status, body := h.buy(t, "psn-20", "close-3"); status != http.StatusCreated || h.row(t, "close-3").Supplier != vouchers.SupplierReloadly {
		t.Fatalf("%d %v", status, body)
	}
}

func TestAnUncertainFailureAlsoOpensTheBreaker(t *testing.T) {
	for name, failure := range map[string]*vouchers.Failure{
		"a timeout after sending": {Code: vouchers.FailureUnknown, Detail: "context deadline exceeded"},
		"a 5xx":                   {Code: vouchers.FailureUnknown, Detail: "HTTP 502"},
	} {
		h, logs := newBreakerHarness(t)
		h.reloadly.buyErr = failure
		// The purchase is held, as ever: nobody knows whether Reloadly sold the card.
		if status, body := h.buy(t, "psn-20", "unc-1"); status != http.StatusAccepted {
			t.Fatalf("%s: %d %v", name, status, body)
		}
		if len(h.supplier.calls()) != 0 || breakerOpenings(logs) != 1 {
			t.Fatalf("%s: no fall-back, but the breaker opens: BN Plus %d, openings %d", name, len(h.supplier.calls()), breakerOpenings(logs))
		}
		// The next shop's purchase of the same card is not left waiting on Reloadly.
		if status, body := h.buy(t, "psn-20", "unc-2"); status != http.StatusCreated || h.row(t, "unc-2").Supplier != vouchers.SupplierBNPlus {
			t.Fatalf("%s: %d %v", name, status, body)
		}
		if len(h.reloadly.calls()) != 1 {
			t.Fatalf("%s: Reloadly was asked again: %d", name, len(h.reloadly.calls()))
		}
	}
}

func TestOnlyAFailureThatWillRepeatOpensTheBreaker(t *testing.T) {
	for name, failure := range map[string]*vouchers.Failure{
		"out of stock":      {Code: vouchers.FailureOutOfStock, Detail: "no codes", Definite: true},
		"a refused product": {Code: vouchers.FailureRefused, Detail: "product inactive", Definite: true},
	} {
		h, logs := newBreakerHarness(t)
		h.reloadly.buyErr = failure
		if status, body := h.buy(t, "psn-20", "one-1"); status != http.StatusCreated {
			t.Fatalf("%s: %d %v", name, status, body)
		}
		h.nextBNPlusOrder("452")
		if status, body := h.buy(t, "psn-20", "one-2"); status != http.StatusCreated {
			t.Fatalf("%s: %d %v", name, status, body)
		}
		if len(h.reloadly.calls()) != 2 || breakerOpenings(logs) != 0 {
			t.Fatalf("%s is about one card, not the supplier: Reloadly asked %d times, openings %d", name, len(h.reloadly.calls()), breakerOpenings(logs))
		}
	}
}

func TestWhenEverySupplierIsPausedTheCheapestIsStillTried(t *testing.T) {
	h, _ := newBreakerHarness(t)
	breaker := h.server.Vouchers.Breaker
	breaker.trip(vouchers.SupplierReloadly, "supplier_credit: x", h.now)
	breaker.trip(vouchers.SupplierBNPlus, "supplier_unreachable: y", h.now)
	if status, body := h.buy(t, "psn-20", "all-1"); status != http.StatusCreated || h.row(t, "all-1").Supplier != vouchers.SupplierReloadly {
		t.Fatalf("something has to be tried, cheapest first: %d %v", status, body)
	}
}

func TestWithoutABreakerNothingIsPaused(t *testing.T) {
	h := newDualHarness(t) // no Breaker: how every hand-built server behaves
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureCredit, Detail: "insufficient balance", Definite: true}
	for i, key := range []string{"nb-1", "nb-2"} {
		h.nextBNPlusOrder("45" + string(rune('2'+i)))
		if status, body := h.buy(t, "psn-20", key); status != http.StatusCreated {
			t.Fatalf("%d %v", status, body)
		}
	}
	if len(h.reloadly.calls()) != 2 {
		t.Fatalf("every purchase tries the cheaper one first: %d", len(h.reloadly.calls()))
	}
}

// --- a relay wired to Reloadly's sandbox must not pass for production -------------

func TestARelayOnTheReloadlySandboxMarksEverythingAsTest(t *testing.T) {
	h := newDualHarness(t)
	if h.server.Vouchers.SandboxMode() || h.server.Vouchers.MarksTest() {
		t.Fatal("a live relay is not in the sandbox")
	}
	if item := h.shopViewItem(t, h.server, "psn-20"); item.Key == "" {
		t.Fatal("catalog")
	}
	status, view := h.voucherHarness.shop(t, h.server, http.MethodGet, "/v1/vouchers/catalog", h.shopper.AccessToken, nil)
	if status != http.StatusOK || view["test_mode"] != false {
		t.Fatalf("live: %d test_mode=%v", status, view["test_mode"])
	}

	cfg := reloadlyfake.New(t).Config()
	cfg.Sandbox = true
	client, err := reloadly.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	h.server.Vouchers.Reloadly = client
	if !h.server.Vouchers.SandboxMode() || !h.server.Vouchers.MarksTest() || h.server.Vouchers.TestMode {
		t.Fatal("the sandbox flag is a mode of its own: the suppliers are still called")
	}

	// The shop is told it is a test relay...
	status, view = h.voucherHarness.shop(t, h.server, http.MethodGet, "/v1/vouchers/catalog", h.shopper.AccessToken, nil)
	if status != http.StatusOK || view["test_mode"] != true {
		t.Fatalf("sandbox: %d test_mode=%v", status, view["test_mode"])
	}
	if _, wallet := h.voucherHarness.shop(t, h.server, http.MethodGet, "/v1/wallet", h.shopper.AccessToken, nil); wallet["vouchers"].(map[string]any)["test_mode"] != true {
		t.Fatalf("the wallet summary says so too: %v", wallet["vouchers"])
	}
	// ...and a purchase is executed (the supplier is asked) but is a test
	// purchase: its row, its payload and the statement entries it makes.
	status, body := h.buy(t, "psn-20", "sb-1")
	if status != http.StatusCreated || body["purchase"].(map[string]any)["test_mode"] != true {
		t.Fatalf("%d %v", status, body)
	}
	if len(h.reloadly.calls()) != 1 {
		t.Fatal("the sandbox is still executed against")
	}
	if row := h.row(t, "sb-1"); !row.TestMode {
		t.Fatalf("row: %+v", row)
	}
	// A refused purchase is refunded, and the refund is marked too.
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureRefused, Detail: "no", Definite: true}
	if status, body := h.buy(t, "psn-50", "sb-2"); status != http.StatusBadGateway || body["purchase"].(map[string]any)["test_mode"] != true {
		t.Fatalf("%d %v", status, body)
	}
	_, entries := h.voucherHarness.shop(t, h.server, http.MethodGet, "/v1/wallet/entries?account=vouchers", h.shopper.AccessToken, nil)
	rows := entries["entries"].([]any)
	if len(rows) < 3 {
		t.Fatalf("the allocation, the charge, the second charge and its refund: %v", rows)
	}
	marked := 0
	for _, row := range rows {
		entry := row.(map[string]any)
		// The allocation into the voucher balance was made before the sandbox flag
		// existed; what the purchases make afterwards is marked.
		if kind := entry["kind"]; kind == "charge" || kind == "refund" {
			marked++
			if entry["test_mode"] != true {
				t.Fatalf("every entry a sandbox purchase makes is marked test: %v", entry)
			}
		}
	}
	if marked != 3 {
		t.Fatalf("two charges and a refund: %d in %v", marked, rows)
	}
	// The operator's config says it.
	if _, config := h.admin(t, http.MethodGet, "/v1/vouchers/admin/config", "", nil); config["sandbox"] != true {
		t.Fatalf("config: %v", config)
	}
}

// --- the reconciler -----------------------------------------------------------

// awaitingSpy is a store that notes how many held purchases a round asks for,
// and can answer with rows of its own.
type awaitingSpy struct {
	*control.FileStore
	mu     sync.Mutex
	limits []int
	rows   []control.VoucherPurchase
}

func (s *awaitingSpy) ListVoucherPurchasesAwaitingCheck(ctx context.Context, staleBefore time.Time, limit int) ([]control.VoucherPurchase, error) {
	s.mu.Lock()
	s.limits = append(s.limits, limit)
	rows := append([]control.VoucherPurchase(nil), s.rows...)
	s.mu.Unlock()
	if rows != nil {
		return rows, nil
	}
	return s.FileStore.ListVoucherPurchasesAwaitingCheck(ctx, staleBefore, limit)
}

func (s *awaitingSpy) setRows(rows ...control.VoucherPurchase) {
	s.mu.Lock()
	s.rows = rows
	s.mu.Unlock()
}

// lookupCounter is a supplier that counts the orders it is asked about, and
// knows none of them.
type lookupCounter struct {
	*fakeSupplier
	mu      sync.Mutex
	lookups int
}

func (c *lookupCounter) Lookup(ctx context.Context, ref vouchers.Ref, orderID string) (vouchers.Purchase, error) {
	c.mu.Lock()
	c.lookups++
	c.mu.Unlock()
	return c.fakeSupplier.Lookup(ctx, ref, orderID)
}

func (c *lookupCounter) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lookups
}

func heldRow(h *dualHarness, id, orderID string) control.VoucherPurchase {
	held := h.now
	return control.VoucherPurchase{
		ID: id, InstallationID: h.shopper.Installation.ID, IdempotencyKey: "key-" + id, Kind: control.VoucherKindCard,
		ItemKey: "psn-20", Quantity: 1, Supplier: vouchers.SupplierBNPlus, SupplierRef: "201", SupplierOrderID: orderID,
		Status: control.VoucherPurchasePending, HeldSince: &held, CreatedAt: h.now, UpdatedAt: h.now,
	}
}

func TestTheReconcilerReadsFiveHundredRowsAWeek(t *testing.T) {
	h := newDualHarness(t)
	spy := &awaitingSpy{FileStore: h.store}
	h.server.Store = spy
	(&VoucherReconciler{Server: h.server, Store: spy}).Round(context.Background())
	if len(spy.limits) != 1 || spy.limits[0] != 500 {
		t.Fatalf("a round reads up to 500 rows, not the store's default of 100: %v", spy.limits)
	}
}

func TestAPurchaseThatCannotBeCheckedIsLeftAloneLongerEachTime(t *testing.T) {
	h := newDualHarness(t)
	counter := &lookupCounter{fakeSupplier: h.supplier}
	h.server.Vouchers.Suppliers[vouchers.SupplierBNPlus] = counter
	spy := &awaitingSpy{FileStore: h.store}
	h.server.Store = spy
	spy.setRows(heldRow(h, "stuck-1", "900")) // BN Plus knows no order 900: unreadable
	reconciler := &VoucherReconciler{Store: spy}
	at := func(offset time.Duration) int {
		reconciler.Server = h.at(h.now.Add(offset))
		reconciler.Round(context.Background())
		return counter.count()
	}

	if got := at(0); got != 1 {
		t.Fatalf("the first round asks: %d", got)
	}
	if got := at(30 * time.Second); got != 1 {
		t.Fatalf("it is left alone for a minute: %d", got)
	}
	// 1, 2, 4, 8, 16 minutes, then half an hour for ever: the n-th check is due
	// that long after the one before.
	due, checks := time.Duration(0), 1
	for _, wait := range []time.Duration{1, 2, 4, 8, 16, 30, 30} {
		wait *= time.Minute
		if got := at(due + wait - time.Second); got != checks {
			t.Fatalf("not due yet after %v: %d checks, want %d", wait, got, checks)
		}
		due += wait
		checks++
		if got := at(due); got != checks {
			t.Fatalf("due after %v: %d checks, want %d", wait, got, checks)
		}
	}
}

func TestAStuckPurchaseIsAskedAboutAgainWhenItsStateChanges(t *testing.T) {
	h := newDualHarness(t)
	counter := &lookupCounter{fakeSupplier: h.supplier}
	h.server.Vouchers.Suppliers[vouchers.SupplierBNPlus] = counter
	spy := &awaitingSpy{FileStore: h.store}
	h.server.Store = spy
	row := heldRow(h, "stuck-2", "901")
	spy.setRows(row)
	reconciler := &VoucherReconciler{Server: h.server, Store: spy}
	reconciler.Round(context.Background())
	reconciler.Round(context.Background())
	if counter.count() != 1 {
		t.Fatalf("left alone: %d", counter.count())
	}
	// The row moved (someone touched it): asked at once, and the pauses start over.
	row.UpdatedAt = row.UpdatedAt.Add(time.Second)
	spy.setRows(row)
	reconciler.Round(context.Background())
	if counter.count() != 2 {
		t.Fatalf("a changed row is checked at once: %d", counter.count())
	}
	reconciler.Round(context.Background())
	if counter.count() != 2 {
		t.Fatalf("and left alone again: %d", counter.count())
	}
	// The order becomes readable (still open at the supplier): not stuck any more,
	// so it is asked about every round, and a purchase settled drops out.
	h.supplier.lookups["901"] = vouchers.Purchase{OrderID: "901", Status: vouchers.StatusPending}
	reconciler.Server = h.at(h.now.Add(time.Hour))
	reconciler.Round(context.Background())
	reconciler.Round(context.Background())
	reconciler.Round(context.Background())
	if counter.count() != 5 {
		t.Fatalf("an open order is asked about each round: %d", counter.count())
	}
	spy.setRows()
	spy.mu.Lock()
	spy.rows = []control.VoucherPurchase{}
	spy.mu.Unlock()
	reconciler.Round(context.Background())
	reconciler.mu.Lock()
	remembered := len(reconciler.backoff)
	reconciler.mu.Unlock()
	if remembered != 0 {
		t.Fatalf("a purchase that no longer waits is forgotten: %d", remembered)
	}
}

func TestWaitingForTheOffersAndTheWindowIsNotBeingStuck(t *testing.T) {
	h := newDualHarness(t)
	h.supplier.found = nil
	// A lost purchase with no order id: while BN Plus's name for the card is not
	// known it cannot be told, and until the window has passed it is waiting.
	// Neither is a reason to leave it alone.
	h.reloadly.buyErr = nil
	h.supplier.buyErr = &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "timeout after sending"}
	h.storeOffers(t, vouchers.SupplierReloadly) // Reloadly unread: BN Plus is the only candidate
	if err := h.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierBNPlus, nil); err != nil {
		t.Fatal(err)
	}
	if status, body := h.buy(t, "psn-5", "wait-1"); status != http.StatusAccepted {
		t.Fatalf("%d %v", status, body)
	}
	reconciler := &VoucherReconciler{Server: h.server, Store: h.store}
	reconciler.Round(context.Background())
	reconciler.Round(context.Background())
	if h.supplier.findCalls != 2 {
		t.Fatalf("the supplier's name for the card is not known yet; each round asks again: %d", h.supplier.findCalls)
	}
	h.storeOffers(t, vouchers.SupplierBNPlus, control.VoucherOffer{Ref: "204", Name: "PlayStation 5 USD", Price: "28", Currency: "LYD", InStock: true})
	reconciler.Round(context.Background())
	reconciler.Round(context.Background())
	if h.supplier.findCalls != 4 {
		t.Fatalf("waiting for the window is not a pause: %d", h.supplier.findCalls)
	}
}

func TestAnOrderFoundButStillOpenAsksForAPersonLikeTheOthers(t *testing.T) {
	h := newDualHarness(t)
	var logs voucherLogBuffer
	h.server.Logger = slog.New(slog.NewTextHandler(&logs, nil))
	h.storeOffers(t, vouchers.SupplierBNPlus, control.VoucherOffer{Ref: "201", Name: "PlayStation 20 USD", Price: "104.5", Currency: "LYD", InStock: true})
	h.supplier.found = []vouchers.Purchase{{OrderID: "700", Status: vouchers.StatusPending}}
	row := heldRow(h, "old-1", "")
	row.CreatedAt = h.now.Add(-49 * time.Hour)
	row.UpdatedAt = row.CreatedAt
	spy := &awaitingSpy{FileStore: h.store}
	spy.setRows(row)

	if _, verdict, err := h.server.checkVoucherPurchase(context.Background(), spy, row); verdict != "open" || err != nil {
		t.Fatalf("%s %v", verdict, err)
	}
	if !strings.Contains(logs.String(), "level=ERROR") || !strings.Contains(logs.String(), "still unresolved") {
		t.Fatalf("after two days it asks for a person:\n%s", logs.String())
	}
	// Younger, it only waits.
	logs = voucherLogBuffer{}
	h.server.Logger = slog.New(slog.NewTextHandler(&logs, nil))
	row.CreatedAt = h.now.Add(-time.Hour)
	if _, verdict, _ := h.server.checkVoucherPurchase(context.Background(), spy, row); verdict != "open" || strings.Contains(logs.String(), "still unresolved") {
		t.Fatalf("%s\n%s", verdict, logs.String())
	}
}

// --- several orders under one reference ----------------------------------------

// heldReloadlyPurchase makes a Reloadly purchase whose outcome is held.
func heldReloadlyPurchase(t *testing.T) (*dualHarness, control.VoucherPurchase) {
	t.Helper()
	h := newDualHarness(t)
	h.reloadly.buyErr = &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "timeout after sending"}
	if status, body := h.buy(t, "psn-20", "held-ref"); status != http.StatusAccepted {
		t.Fatalf("%d %v", status, body)
	}
	return h, h.row(t, "held-ref")
}

func TestSeveralOrdersUnderOneReferenceAreWeighedTogether(t *testing.T) {
	failed := func(id string) vouchers.Purchase {
		return vouchers.Purchase{OrderID: id, Status: vouchers.StatusFailed, Message: "Reloadly ended the order FAILED"}
	}
	paid := func(id string) vouchers.Purchase {
		return vouchers.Purchase{OrderID: id, Status: vouchers.StatusSucceeded, Cost: "10.30000", Currency: "USD"}
	}
	open := func(id string) vouchers.Purchase {
		return vouchers.Purchase{OrderID: id, Status: vouchers.StatusPending}
	}

	cases := []struct {
		name       string
		orders     []vouchers.Purchase
		wantStatus string
		wantOrder  string
		refunded   bool
	}{
		{"a failed order listed first must not refund a paid card", []vouchers.Purchase{failed("79600"), paid("79601")}, control.VoucherPurchaseSucceeded, "79601", false},
		{"paid first", []vouchers.Purchase{paid("79601"), failed("79600")}, control.VoucherPurchaseSucceeded, "79601", false},
		{"open first, paid second", []vouchers.Purchase{open("79600"), paid("79601")}, control.VoucherPurchaseSucceeded, "79601", false},
		{"failed and still open: wait", []vouchers.Purchase{failed("79600"), open("79601")}, control.VoucherPurchasePending, "", false},
		{"only failed: refunded", []vouchers.Purchase{failed("79600"), failed("79601")}, control.VoucherPurchaseFailed, "79600", true},
		{"a single failed order: refunded", []vouchers.Purchase{failed("79600")}, control.VoucherPurchaseFailed, "79600", true},
	}
	for _, tc := range cases {
		h, row := heldReloadlyPurchase(t)
		h.reloadly.byRef[row.ID] = tc.orders
		(&VoucherReconciler{Server: h.server, Store: h.store}).Round(context.Background())
		got := h.row(t, "held-ref")
		if got.Status != tc.wantStatus || got.SupplierOrderID != tc.wantOrder {
			t.Errorf("%s: %+v", tc.name, got)
		}
		wantBalance := "390.000"
		if tc.refunded {
			wantBalance = "500.000"
		}
		if h.balance(t) != wantBalance {
			t.Errorf("%s: balance %s, want %s", tc.name, h.balance(t), wantBalance)
		}
	}
}

func TestTwoPaidOrdersUnderOneReferenceHoldThePurchaseAndAskForAPerson(t *testing.T) {
	h, row := heldReloadlyPurchase(t)
	var logs voucherLogBuffer
	h.server.Logger = slog.New(slog.NewTextHandler(&logs, nil))
	paid := func(id string) vouchers.Purchase {
		return vouchers.Purchase{OrderID: id, Status: vouchers.StatusSucceeded, Cost: "10.30000", Currency: "USD"}
	}
	h.reloadly.byRef[row.ID] = []vouchers.Purchase{paid("79601"), paid("79602")}
	reconciler := &VoucherReconciler{Server: h.server, Store: h.store}
	reconciler.Round(context.Background())

	got := h.row(t, "held-ref")
	if got.Status != control.VoucherPurchasePending || got.HeldSince == nil || got.SupplierOrderID != "" || h.balance(t) != "390.000" {
		t.Fatalf("nothing is settled by guess: %+v balance %s", got, h.balance(t))
	}
	if !strings.Contains(logs.String(), "level=ERROR") || !strings.Contains(logs.String(), "bought more than once") ||
		!strings.Contains(logs.String(), "79601=succeeded,79602=succeeded") {
		t.Fatalf("an ERROR names the orders:\n%s", logs.String())
	}
	// The next round leaves it alone (a stuck purchase), so the log is not flooded.
	reconciler.Round(context.Background())
	if strings.Count(logs.String(), "bought more than once") != 1 {
		t.Fatalf("one alarm, not one a minute:\n%s", logs.String())
	}
	// The operator keeps one order and the purchase is settled.
	status, resolved := h.admin(t, http.MethodPost, "/v1/vouchers/admin/purchases/"+row.ID+"/resolve", "application/json",
		[]byte(`{"outcome": "found", "supplier_order_id": "79601", "reason": "kept the first order, asked Reloadly to refund the second", "actor": "ops"}`))
	if status != http.StatusOK || resolved["applied"] != true || h.row(t, "held-ref").Status != control.VoucherPurchaseSucceeded {
		t.Fatalf("%d %v", status, resolved)
	}
}

// --- offers have an age --------------------------------------------------------

func TestOffersAreBelievedForThreeSyncIntervalsAndAtLeastTwoHours(t *testing.T) {
	cases := map[time.Duration]time.Duration{
		0:                0, // no schedule: whatever was read by hand stands
		-time.Minute:     0,
		10 * time.Minute: 2 * time.Hour,
		30 * time.Minute: 2 * time.Hour,
		40 * time.Minute: 2 * time.Hour,
		time.Hour:        3 * time.Hour,
		2 * time.Hour:    6 * time.Hour,
	}
	for interval, want := range cases {
		if got := (VoucherConfig{SyncInterval: interval}).offersMaxAge(); got != want {
			t.Errorf("sync every %v: offers believed for %v, want %v", interval, got, want)
		}
	}
}

func TestOffersTooOldAreNoMoreKnownThanOffersNeverRead(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	bn := vouchers.Ref{Supplier: vouchers.SupplierBNPlus, ID: "1"}
	rl := vouchers.Ref{Supplier: vouchers.SupplierReloadly, ID: "9/20"}
	both := []string{vouchers.SupplierBNPlus, vouchers.SupplierReloadly}
	// BN Plus says "out of stock"; Reloadly says 10.40 dollars.
	bnOutOfStock := control.VoucherOffer{Supplier: "bnplus", Ref: "1", Price: "90", Currency: "LYD", InStock: false}
	rlOffer := control.VoucherOffer{Supplier: "reloadly", Ref: "9/20", Price: "10.40", Currency: "USD", InStock: true}
	rate10 := vouchers.DefaultSettings()
	rate10.USDRate = "10"
	maxAge := 2 * time.Hour

	rank := func(refs []vouchers.Ref, bnRead, rlRead time.Duration, limit time.Duration) (supplierRanking, voucherOffers) {
		located, config, offers := cardRankInputs(refs, both, bnOutOfStock, rlOffer)
		offers.now, offers.maxAge = now, limit
		offers.newest = map[string]time.Time{"bnplus": now.Add(-bnRead), "reloadly": now.Add(-rlRead)}
		return config.rankSuppliers(located, offers, rate10), offers
	}

	// Fresh: BN Plus is out of stock, so only Reloadly.
	if ranking, _ := rank([]vouchers.Ref{bn, rl}, time.Hour, time.Hour, maxAge); rankedCardSuppliers(ranking) != "reloadly" {
		t.Fatalf("fresh offers are believed: %q", rankedCardSuppliers(ranking))
	}
	// BN Plus's offers are three hours old: its "out of stock" says nothing, it
	// is unknown (allowed, after Reloadly, whose price is known and fresh).
	ranking, _ := rank([]vouchers.Ref{bn, rl}, 3*time.Hour, time.Hour, maxAge)
	if rankedCardSuppliers(ranking) != "reloadly,bnplus" {
		t.Fatalf("old offers are unknown: %q", rankedCardSuppliers(ranking))
	}
	if note := ranking.Evaluations[0].Note; !strings.Contains(note, "last read 3h0m0s ago") || !strings.Contains(note, "price and stock unknown") {
		t.Fatalf("the operator is told: %q", note)
	}
	// Reloadly's offers are old: never priced blind, so it is out.
	ranking, _ = rank([]vouchers.Ref{bn, rl}, time.Hour, 5*time.Hour, maxAge)
	if rankedCardSuppliers(ranking) != "" {
		t.Fatalf("Reloadly is not sold on old offers (and BN Plus is out of stock): %q", rankedCardSuppliers(ranking))
	}
	if reason, attention := ranking.unavailable(); !strings.Contains(reason, "reloadly: the price at Reloadly is not known: its offers were last read 5h0m0s ago") || !attention {
		t.Fatalf("%q (%v)", reason, attention)
	}
	// Exactly at the limit is still believed; no limit never judges.
	if ranking, _ := rank([]vouchers.Ref{bn, rl}, time.Hour, maxAge, maxAge); rankedCardSuppliers(ranking) != "reloadly" {
		t.Fatalf("at the limit: %q", rankedCardSuppliers(ranking))
	}
	if ranking, _ := rank([]vouchers.Ref{bn, rl}, 100*time.Hour, 100*time.Hour, 0); rankedCardSuppliers(ranking) != "reloadly" {
		t.Fatalf("a relay without a schedule keeps what was read by hand: %q", rankedCardSuppliers(ranking))
	}
	// Offers with no time on them are never judged old.
	located, config, offers := cardRankInputs([]vouchers.Ref{bn, rl}, both, bnOutOfStock, rlOffer)
	offers.now, offers.maxAge = now, maxAge
	if ranking := config.rankSuppliers(located, offers, rate10); rankedCardSuppliers(ranking) != "reloadly" {
		t.Fatalf("unknown age: %q", rankedCardSuppliers(ranking))
	}
}

func TestACardIsSoldOnOldOffersOnlyWhereTheyAreAllowedToBeUnknown(t *testing.T) {
	h := newDualHarness(t)
	h.server.Vouchers.SyncInterval = 30 * time.Minute // offers are believed for two hours
	h.storeOffers(t, vouchers.SupplierBNPlus,
		control.VoucherOffer{Ref: "201", Name: "PS 20", Price: "104.50", Currency: "LYD", InStock: true},
		control.VoucherOffer{Ref: "204", Name: "PS 5", Price: "28", Currency: "LYD", InStock: false})
	h.reloadlyOffers(t, "10.30", "25.50", "5.00", "13.00")

	// An hour on, the offers are believed: Reloadly is cheaper, psn-5 is out of stock.
	soon := h.at(h.now.Add(time.Hour))
	if item := h.shopViewItem(t, soon, "psn-5"); item.Available {
		t.Fatal("fresh offers say psn-5 is out of stock")
	}
	if status, body := h.buyAt(t, soon, "psn-20", "old-1"); status != http.StatusCreated || h.row(t, "old-1").Supplier != vouchers.SupplierReloadly {
		t.Fatalf("%d %v", status, body)
	}

	// Three hours on and nothing re-read: BN Plus's old "out of stock" is no more
	// known than silence, so psn-5 sells (unknown is allowed); Reloadly is not
	// sold on old prices.
	late := h.at(h.now.Add(3 * time.Hour))
	if item := h.shopViewItem(t, late, "psn-5"); !item.Available {
		t.Fatal("old offers are unknown, and unknown is allowed")
	}
	if item := h.shopViewItem(t, late, "psn-50"); item.Available {
		t.Fatal("Reloadly's price is not known any more")
	}
	h.nextBNPlusOrder("452")
	calls := len(h.reloadly.calls())
	if status, body := h.buyAt(t, late, "psn-20", "old-2"); status != http.StatusCreated || h.row(t, "old-2").Supplier != vouchers.SupplierBNPlus {
		t.Fatalf("%d %v", status, body)
	}
	if len(h.reloadly.calls()) != calls {
		t.Fatal("Reloadly must not be asked on old prices")
	}
	status, body := h.buyAt(t, late, "psn-50", "old-3")
	if reason, _ := body["error"].(string); status != http.StatusConflict || !strings.Contains(reason, "last read 3h0m0s ago") {
		t.Fatalf("%d %v", status, body)
	}
	supply := h.adminSupply(t, "psn-20")
	_ = supply // the admin view is read at the server's own clock; the notes are covered above
}

// failingOffers is a supplier whose offers cannot be read.
type failingOffers struct {
	*fakeSupplier
	err error
}

func (f *failingOffers) Offers(context.Context) ([]vouchers.Offer, error) { return nil, f.err }

func TestAFailingOfferSyncIsAWarningAndOldOffersAnError(t *testing.T) {
	for name, tc := range map[string]struct {
		read      time.Duration // how long ago the stored offers were read
		wantError bool
	}{
		"fresh offers stand": {read: 10 * time.Minute},
		"offers too old":     {read: 3 * time.Hour, wantError: true},
	} {
		h := newDualHarness(t)
		var logs voucherLogBuffer
		logger := slog.New(slog.NewTextHandler(&logs, nil))
		h.server.Vouchers.SyncInterval = 30 * time.Minute
		h.server.Vouchers.Suppliers[vouchers.SupplierBNPlus] = &failingOffers{fakeSupplier: h.supplier, err: errors.New("bnplus: HTTP 502")}
		if err := h.store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierBNPlus, []control.VoucherOffer{
			{Supplier: "bnplus", Ref: "201", Name: "PS 20", Price: "104.5", Currency: "LYD", InStock: true, SyncedAt: time.Now().Add(-tc.read)},
		}); err != nil {
			t.Fatal(err)
		}
		(&VoucherOfferSync{Config: h.server.Vouchers, Store: h.store, Interval: time.Minute, Logger: logger}).Round(context.Background())
		text := logs.String()
		if !strings.Contains(text, "level=WARN") || !strings.Contains(text, "supplier=bnplus") || !strings.Contains(text, "HTTP 502") {
			t.Fatalf("%s: a failed read is a warning naming the supplier:\n%s", name, text)
		}
		if has := strings.Contains(text, "level=ERROR"); has != tc.wantError {
			t.Fatalf("%s: error logged %v, want %v:\n%s", name, has, tc.wantError, text)
		}
		if tc.wantError && !strings.Contains(text, "older than the relay believes") {
			t.Fatalf("%s:\n%s", name, text)
		}
		if stored, _ := h.store.ListVoucherOffers(context.Background(), vouchers.SupplierBNPlus); len(stored) != 1 {
			t.Fatalf("%s: the last offers stand: %v", name, stored)
		}
	}
}

func manyOffers(n int) []vouchers.Offer {
	offers := make([]vouchers.Offer, 0, n)
	for i := 0; i < n; i++ {
		offers = append(offers, vouchers.Offer{Ref: "c" + string(rune('a'+i)), Name: "card", Price: "10", Currency: "LYD", InStock: true})
	}
	return offers
}

func TestAnEmptyAnswerFromASupplierThatHadManyOffersDoesNotReplaceThem(t *testing.T) {
	h := newDualHarness(t)
	var logs voucherLogBuffer
	logger := slog.New(slog.NewTextHandler(&logs, nil))
	config := h.server.Vouchers
	delete(config.Suppliers, vouchers.SupplierReloadly) // BN Plus alone
	ctx := context.Background()

	h.supplier.offers = manyOffers(12)
	result := syncVoucherOffers(ctx, config, h.store, logger)
	if result.err() != nil || result.Counts[vouchers.SupplierBNPlus] != 12 {
		t.Fatalf("%v %v", result.Counts, result.err())
	}
	// The next answer is empty: a failure to say, not a sold-out shelf.
	h.supplier.offers = nil
	result = syncVoucherOffers(ctx, config, h.store, logger)
	if err := result.err(); err == nil || !strings.Contains(err.Error(), "no offers although 12 are stored") {
		t.Fatalf("error: %v", err)
	}
	if _, replaced := result.Counts[vouchers.SupplierBNPlus]; replaced {
		t.Fatalf("not replaced: %v", result.Counts)
	}
	if stored, _ := h.store.ListVoucherOffers(ctx, vouchers.SupplierBNPlus); len(stored) != 12 {
		t.Fatalf("the twelve stand: %d", len(stored))
	}
	if !strings.Contains(logs.String(), "level=ERROR") || !strings.Contains(logs.String(), "answered with no offers although it had many") {
		t.Fatalf("log:\n%s", logs.String())
	}
	// The admin route says so too.
	h.server.Vouchers = config
	if status, body := h.admin(t, http.MethodPost, "/v1/vouchers/admin/offers/sync", "application/json", []byte("{}")); status != http.StatusBadGateway ||
		!strings.Contains(body["error"].(string), "the stored ones are kept") {
		t.Fatalf("%d %v", status, body)
	}

	// A supplier with few offers may genuinely have none left.
	if err := h.store.ReplaceVoucherOffers(ctx, vouchers.SupplierBNPlus, []control.VoucherOffer{
		{Supplier: "bnplus", Ref: "a", Name: "x", Price: "1", Currency: "LYD", InStock: true, SyncedAt: time.Now()},
	}); err != nil {
		t.Fatal(err)
	}
	if result = syncVoucherOffers(ctx, config, h.store, logger); result.err() != nil || result.Counts[vouchers.SupplierBNPlus] != 0 {
		t.Fatalf("%v %v", result.Counts, result.err())
	}
}

func TestReloadlyOffersAreDoubtedWhenAskedForCardsAndNoneComeBut(t *testing.T) {
	h := newDualHarness(t)
	logs := voucherLogBuffer{}
	logger := slog.New(slog.NewTextHandler(&logs, nil))
	ctx := context.Background()
	twelve := make([]control.VoucherOffer, 0, 12)
	for i := 0; i < 12; i++ {
		twelve = append(twelve, control.VoucherOffer{Ref: "13441/" + string(rune('a'+i)), Name: "x", Price: "1", Currency: "USD", InStock: true})
	}
	h.storeOffers(t, vouchers.SupplierReloadly, twelve...)

	// The catalog names Reloadly cards, Reloadly prices none of them: kept.
	h.reloadly.wantedOffer = nil
	result := syncVoucherOffers(ctx, h.server.Vouchers, h.store, logger)
	if result.Failures[vouchers.SupplierReloadly] == nil {
		t.Fatalf("an empty answer to a question: %v", result.Counts)
	}
	if stored, _ := h.store.ListVoucherOffers(ctx, vouchers.SupplierReloadly); len(stored) != 12 {
		t.Fatalf("kept: %d", len(stored))
	}

	// When the catalog names no Reloadly card, nothing is the right answer, and
	// the stale offers go.
	other := newVoucherHarness(t)
	reloadly := newFakeCardReloadly()
	other.server.Vouchers.Suppliers[vouchers.SupplierReloadly] = reloadly
	other.storeOffers(t, vouchers.SupplierReloadly, twelve...)
	other.publish(t) // BN Plus cards only
	result = syncVoucherOffers(ctx, other.server.Vouchers, other.store, logger)
	if result.Failures[vouchers.SupplierReloadly] != nil || result.Counts[vouchers.SupplierReloadly] != 0 || len(reloadly.wanted) != 0 {
		t.Fatalf("%v %v", result.Counts, result.Failures)
	}
	if stored, _ := other.store.ListVoucherOffers(ctx, vouchers.SupplierReloadly); len(stored) != 0 {
		t.Fatalf("cleared: %d", len(stored))
	}
}

// --- the settings document -----------------------------------------------------

func publishRawSettings(t *testing.T, h *dualHarness, document string) control.VoucherSettingsRecord {
	t.Helper()
	sum := sha256.Sum256([]byte(document))
	record, err := h.store.PublishVoucherSettings(context.Background(), control.VoucherSettingsRecord{
		SHA256: hex.EncodeToString(sum[:]), Document: json.RawMessage(document), Actor: "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	return record
}

func TestCardSalesGoOnWhenTheStoredSettingsCannotBeRead(t *testing.T) {
	h := newDualHarness(t)
	logs := &voucherLogBuffer{}
	h.server.Logger = slog.New(slog.NewTextHandler(logs, nil))
	h.server.VoucherSettingsCache = &VoucherSettingsCache{}
	// A rolling update added a settings field this node's code does not know.
	broken := publishRawSettings(t, h, `{"usd_rate": "10", "a_field_from_the_next_release": "x"}`)
	unreadable := func() int {
		return strings.Count(logs.String(), "so Reloadly is unpriced and card sales go on without it")
	}

	// The shop's catalog is served. No dollar rate means Reloadly is unpriced:
	// the item both suppliers sell sells from BN Plus, the one only Reloadly sells is off.
	if item := h.shopViewItem(t, h.server, "psn-20"); !item.Available {
		t.Fatalf("psn-20: %+v", item)
	}
	if item := h.shopViewItem(t, h.server, "psn-5"); !item.Available {
		t.Fatalf("psn-5: %+v", item)
	}
	if item := h.shopViewItem(t, h.server, "psn-50"); item.Available {
		t.Fatalf("psn-50 needs Reloadly: %+v", item)
	}
	// Purchases go on, from BN Plus.
	if status, body := h.buy(t, "psn-5", "set-1"); status != http.StatusCreated {
		t.Fatalf("a BN Plus card must sell: %d %v", status, body)
	}
	h.nextBNPlusOrder("452")
	if status, body := h.buy(t, "psn-20", "set-2"); status != http.StatusCreated || h.row(t, "set-2").Supplier != vouchers.SupplierBNPlus {
		t.Fatalf("%d %v", status, body)
	}
	status, body := h.buy(t, "psn-50", "set-3")
	if reason, _ := body["error"].(string); status != http.StatusConflict || !strings.Contains(reason, "rate_unset") {
		t.Fatalf("%d %v", status, body)
	}
	if len(h.reloadly.calls()) != 0 {
		t.Fatal("Reloadly is unpriced")
	}
	// The log says it once for this version, not once a request.
	if unreadable() != 1 || !strings.Contains(logs.String(), "level=ERROR") || !strings.Contains(logs.String(), broken.ID) {
		t.Fatalf("log:\n%s", logs.String())
	}
	// The operator's views are served too.
	if status, _ := h.admin(t, http.MethodGet, "/v1/vouchers/admin/catalog", "", nil); status != http.StatusOK {
		t.Fatalf("admin catalog: %d", status)
	}
	if status, _ := h.admin(t, http.MethodGet, "/v1/vouchers/admin/offers", "", nil); status != http.StatusOK {
		t.Fatalf("admin offers: %d", status)
	}

	// The settings route is where it is said loudly, with the document.
	status, answer := h.admin(t, http.MethodGet, "/v1/vouchers/admin/settings", "", nil)
	message, _ := answer["error"].(string)
	if status != http.StatusInternalServerError || answer["code"] != "settings_unreadable" ||
		!strings.Contains(message, "CANNOT BE READ") || !strings.Contains(message, broken.ID) ||
		!strings.Contains(message, "a_field_from_the_next_release") || !strings.Contains(message, "settings set --file") {
		t.Fatalf("%d %v", status, answer)
	}
	if document, _ := answer["document"].(map[string]any); document["usd_rate"] != "10" {
		t.Fatalf("the stored document is shown: %v", answer["document"])
	}

	// A different broken document is a change: reported again. Publishing a good
	// one repairs everything, and Reloadly is priced again.
	publishRawSettings(t, h, `{"usd_rate": "10", "another_field": 1}`)
	h.buy(t, "psn-5", "set-4")
	if unreadable() != 2 {
		t.Fatalf("a new broken version is reported: %d", unreadable())
	}
	good := vouchers.DefaultSettings()
	good.USDRate = "10"
	goodDocument, _, _ := vouchers.EncodeSettings(good)
	publishRawSettings(t, h, string(goodDocument))
	h.nextBNPlusOrder("453")
	if status, body := h.buy(t, "psn-20", "set-5"); status != http.StatusCreated || h.row(t, "set-5").Supplier != vouchers.SupplierReloadly {
		t.Fatalf("with a readable document Reloadly is priced again: %d %v", status, body)
	}
	if status, _ := h.admin(t, http.MethodGet, "/v1/vouchers/admin/settings", "", nil); status != http.StatusOK {
		t.Fatalf("settings: %d", status)
	}
}

// brokenSettingsStore cannot even read the settings.
type brokenSettingsStore struct{ *control.FileStore }

func (brokenSettingsStore) CurrentVoucherSettings(context.Context) (control.VoucherSettingsRecord, error) {
	return control.VoucherSettingsRecord{}, errors.New("database unreachable")
}

func TestAStoreThatCannotBeReadStillFailsTheRequest(t *testing.T) {
	h := newDualHarness(t)
	h.server.Store = brokenSettingsStore{h.store}
	recorder := h.request(t, h.server, http.MethodGet, "/v1/vouchers/catalog", map[string]string{AccessTokenHeader: h.shopper.AccessToken}, nil)
	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("only an unparseable document is tolerated, not a dead store: %d", recorder.Code)
	}
}
