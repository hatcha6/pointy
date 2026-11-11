package relay

import (
	"context"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/airalo"
	"pointy/relay/internal/airalo/airalofake"
	"pointy/relay/internal/esimaccess"
	"pointy/relay/internal/esimaccess/esimaccessfake"
	"pointy/relay/internal/vouchers"
)

type esimAccessHarness struct {
	*orderHarness
	access *esimaccessfake.Server
	airalo *airalofake.Server
	pusher *fakePusher
}

// newESIMAccessHarness is a relay whose shelf is eSIM Access's, with Airalo
// beside it when withAiralo. The dollar is at 10 dinars.
func newESIMAccessHarness(t *testing.T, withAiralo bool, prepare func(*esimAccessHarness)) *esimAccessHarness {
	t.Helper()
	h := &esimAccessHarness{orderHarness: newOrderHarness(t), access: esimaccessfake.New(), pusher: &fakePusher{}}
	h.cards.setRate(t, "10.00")
	h.access.Now = func() time.Time { return h.server.clock().Now() }
	upstream := httptest.NewServer(h.access.Handler())
	t.Cleanup(upstream.Close)
	client := esimaccess.New(esimaccess.Config{BaseURL: upstream.URL, AccessCode: "access", RetryDelay: time.Millisecond})
	h.server.Vouchers.Suppliers[vouchers.SupplierESIMAccess] = &vouchers.ESIMAccessSupplier{Client: client, Wait: 300 * time.Millisecond, Poll: time.Millisecond}
	config := ESIMConfig{
		Access: client, AccessWebhookToken: "tok", AccessWebhookURL: "https://relay.test/v1/customers/esim/webhook/access",
		Retail: vouchers.ESIMRetail{Step: big.NewRat(1, 1)},
	}
	if withAiralo {
		h.airalo = airalofake.New()
		airaloUpstream := httptest.NewServer(h.airalo.Handler())
		t.Cleanup(airaloUpstream.Close)
		airaloClient := airalo.New(airalo.Config{BaseURL: airaloUpstream.URL, ClientID: "id", ClientSecret: "secret", RetryDelay: time.Millisecond})
		h.server.Vouchers.Suppliers[vouchers.SupplierAiralo] = &vouchers.AiraloSupplier{Client: airaloClient}
		config.Client = airaloClient
	}
	h.server.ESIM = NewESIMConfig(config)
	h.server.CustomerPush = h.pusher
	if prepare != nil {
		prepare(h)
	}
	if err := h.server.syncESIMCatalog(context.Background(), h.store); err != nil {
		t.Fatal(err)
	}
	return h
}

func (h *esimAccessHarness) plans(destination string) []map[string]any {
	h.t.Helper()
	status, body := h.do(http.MethodGet, "/v1/customers/esim/destinations/"+destination, "", nil)
	if status != http.StatusOK {
		h.t.Fatalf("destination %s: %d %v", destination, status, body)
	}
	plans := []map[string]any{}
	for _, raw := range body["plans"].([]any) {
		plans = append(plans, raw.(map[string]any))
	}
	return plans
}

// plan finds the plan of a size at a destination.
func (h *esimAccessHarness) plan(destination string, megabytes, days int) map[string]any {
	h.t.Helper()
	var found map[string]any
	for _, plan := range h.plans(destination) {
		if plan["amount_mb"] == float64(megabytes) && plan["days"] == float64(days) {
			if found != nil {
				h.t.Fatalf("%s lists %d MB for %d days twice", destination, megabytes, days)
			}
			found = plan
		}
	}
	if found == nil {
		h.t.Fatalf("%s has no %d MB plan for %d days: %v", destination, megabytes, days, h.plans(destination))
	}
	return found
}

func (h *esimAccessHarness) buy(token string, plan map[string]any, key string) map[string]any {
	h.t.Helper()
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder(plan["item"].(string), plan["price"].(string), key, 1))
	if status != http.StatusCreated {
		h.t.Fatalf("create: %d %v", status, body)
	}
	id := orderOf(h.t, body)["id"].(string)
	_, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	return orderOf(h.t, body)
}

func (h *esimAccessHarness) issued(token, orderID string) map[string]any {
	h.t.Helper()
	_, body := h.do(http.MethodGet, "/v1/customers/esims?order="+orderID, token, nil)
	list := body["esims"].([]any)
	if len(list) != 1 {
		h.t.Fatalf("eSIMs of the order: %v", body)
	}
	return list[0].(map[string]any)
}

func (h *esimAccessHarness) event(token, kind, iccid string) int {
	h.t.Helper()
	body := `{"notifyType":"` + kind + `","notifyId":"n","content":{"iccid":"` + iccid + `","esimTranNo":"` + h.access.TranNo(iccid) + `","remain":1,"remainThreshold":0.1}}`
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/customers/esim/webhook/access/"+token, strings.NewReader(body))
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	return recorder.Code
}

// The price is the suggested retail price set at eSIM Access (157% of the cost
// here), at the dollar rate, rounded up to a dinar: 0.95 USD costs 15 dinars.
func TestESIMAccessShelfSellsAtTheSuggestedRetailPriceAndFollowsTheDollar(t *testing.T) {
	h := newESIMAccessHarness(t, false, nil)
	status, body := h.do(http.MethodGet, "/v1/customers/esim/destinations", "", nil)
	if status != http.StatusOK || body["available"] != true || body["test_mode"] != false {
		t.Fatalf("shelf: %d %v", status, body)
	}
	rows := map[string]map[string]any{}
	for _, raw := range body["destinations"].([]any) {
		row := raw.(map[string]any)
		rows[row["key"].(string)] = row
	}
	if rows["tunisia"]["name"] != "تونس" || rows["tunisia"]["country"] != "TN" || rows["tunisia"]["from_price"] != "15.000" {
		t.Fatalf("Tunisia: %v", rows["tunisia"])
	}
	if europe := rows["ea-eu-33"]; europe["kind"] != esimKindRegional || europe["name"] != "أوروبا" || europe["countries"] != float64(3) {
		t.Fatalf("Europe: %v", europe)
	}
	if price := h.plan("tunisia", 1024, 7)["price"]; price != "15.000" {
		t.Fatalf("Tunisia 1 GB = %v, want 15", price)
	}
	// Turkey's gigabyte is sold twice by eSIM Access; the shelf lists the
	// cheaper once (0.46 USD x 1.57 x 10 = 7.22, so 8), and no day pass.
	turkey := h.plan("turkey", 1024, 7)
	if turkey["price"] != "8.000" || turkey["id"] != "ea.PTR1G7" || turkey["rechargeable"] != true || turkey["operator"] != "Vodafone" {
		t.Fatalf("Turkey 1 GB: %v", turkey)
	}
	if len(h.plans("turkey")) != 3 {
		t.Fatalf("Turkey's plans: %v", h.plans("turkey"))
	}
	for _, plan := range h.plans("turkey") {
		if _, leaked := plan["net_usd"]; leaked || plan["cost_units"] != nil || plan["supplier"] != nil {
			t.Fatalf("the cost or the supplier leaked: %v", plan)
		}
	}
	// The dollar goes to 12: the same plan is 1.4915 x 12 = 17.9, so 18.
	h.cards.setRate(t, "12.00")
	if price := h.plan("tunisia", 1024, 7)["price"]; price != "18.000" {
		t.Fatalf("Tunisia 1 GB at a dearer dollar = %v, want 18", price)
	}
	h.cards.setRate(t, "")
	if _, body := h.do(http.MethodGet, "/v1/customers/esim/destinations", "", nil); body["available"] != false {
		t.Fatalf("no dollar rate should close the shelf: %v", body)
	}
}

func TestESIMRetailPriceNeverSellsUnderCost(t *testing.T) {
	margin := vouchers.Settings{}.Normalized().MarginFor(vouchers.ServiceKindCard)
	rate := big.NewRat(10, 1)
	// A suggested price set under the cost: 1 USD for a plan that costs 2.
	price, ok := vouchers.ESIMRetailPrice(big.NewRat(2, 1), big.NewRat(1, 1), rate, margin, vouchers.ESIMRetail{Step: big.NewRat(1, 1)})
	if !ok || price.Cmp(big.NewRat(20, 1)) <= 0 {
		t.Fatalf("sold at %v for a cost of 20 dinars", price)
	}
	// No suggested price: 157% of the cost.
	price, ok = vouchers.ESIMRetailPrice(big.NewRat(95, 100), nil, rate, margin, vouchers.ESIMRetail{Step: big.NewRat(1, 1)})
	if !ok || price.Cmp(big.NewRat(15, 1)) != 0 {
		t.Fatalf("fallback price = %v, want 15", price)
	}
	price, _ = vouchers.ESIMRetailPrice(big.NewRat(46, 100), nil, rate, margin, vouchers.ESIMRetail{MinPrice: big.NewRat(15, 1)})
	if price.Cmp(big.NewRat(15, 1)) != 0 {
		t.Fatalf("lowest price = %v, want 15", price)
	}
}

func TestESIMAccessBoughtInstallsReadsUsageAndIsToppedUp(t *testing.T) {
	h := newESIMAccessHarness(t, false, nil)
	token := h.customer("0911111111")
	order := h.buy(token, h.plan("tunisia", 1024, 7), "e-1")
	if order["status"] != "delivered" || order["delivery"] != "esim" || h.access.Orders != 1 {
		t.Fatalf("order: %v, %d orders", order, h.access.Orders)
	}
	row := h.issued(token, order["id"].(string))
	iccid := row["iccid"].(string)
	if row["destination_name"] != "تونس" || row["country"] != "TN" || row["rechargeable"] != true {
		t.Fatalf("eSIM row: %v", row)
	}
	stored, err := h.store.GetCustomerESIM(context.Background(), iccid)
	if err != nil || stored.Supplier != vouchers.SupplierESIMAccess || stored.SupplierRef != h.access.TranNo(iccid) {
		t.Fatalf("stored eSIM: %+v %v", stored, err)
	}

	_, body := h.do(http.MethodGet, "/v1/customers/esims/"+iccid, token, nil)
	esim := body["esim"].(map[string]any)
	install := esim["install"].(map[string]any)
	if !strings.HasPrefix(install["qr"].(string), "LPA:1$rsp.fake.test$") || install["smdp"] != "rsp.fake.test" ||
		install["activation_code"] == "" ||
		!strings.HasPrefix(install["apple_url"].(string), "https://esimsetup.apple.com/") ||
		!strings.HasPrefix(install["android_url"].(string), "https://esimsetup.android.com/") ||
		install["apn_value"] != "fake.apn" || !strings.HasPrefix(install["share_link"].(string), "https://") {
		t.Fatalf("install: %v", install)
	}
	if usage := esim["usage"].(map[string]any); usage["status"] != "NOT_ACTIVE" || usage["total_mb"] != float64(1024) || usage["expires_at"] != nil {
		t.Fatalf("usage of a new eSIM: %v", usage)
	}

	// Another customer cannot see it, or top it up.
	stranger := h.customer("0922222222")
	if status, _ := h.do(http.MethodGet, "/v1/customers/esims/"+iccid, stranger, nil); status != http.StatusNotFound {
		t.Fatalf("a stranger read an eSIM: %d", status)
	}
	if status, _ := h.do(http.MethodPost, "/v1/customers/orders", stranger,
		sadadOrder(esimTopUpItemPrefix+iccid+":ea.TOPUP_PTR1G7", "8.000", "s-1", 1)); status != http.StatusNotFound {
		t.Fatalf("a stranger topped up an eSIM: %d", status)
	}

	_, body = h.do(http.MethodGet, "/v1/customers/esims/"+iccid+"/topups", token, nil)
	topUps := body["plans"].([]any)
	if len(topUps) != 2 {
		t.Fatalf("top-ups: %v", body)
	}
	topUp := topUps[0].(map[string]any)
	if topUp["price"] != "8.000" || !strings.HasPrefix(topUp["item"].(string), esimTopUpItemPrefix+iccid+":ea.TOPUP_") {
		t.Fatalf("top-up plan: %v", topUp)
	}
	topped := h.buy(token, topUp, "t-1")
	if topped["status"] != "delivered" || h.access.TopUps != 1 || h.access.Orders != 1 {
		t.Fatalf("top-up: %v, %d top-ups, %d orders", topped, h.access.TopUps, h.access.Orders)
	}
	if _, body := h.do(http.MethodGet, "/v1/customers/esims", token, nil); len(body["esims"].([]any)) != 1 {
		t.Fatalf("a top-up made a second eSIM: %v", body)
	}
}

// eSIM Access makes the eSIM after it takes the order. One that is slow is
// delivered when it is ready, and never ordered again.
func TestESIMAccessSlowESIMIsDeliveredWhenReadyAndNeverOrderedTwice(t *testing.T) {
	h := newESIMAccessHarness(t, false, nil)
	token := h.customer("0911111111")
	h.access.Set(func(s *esimaccessfake.Server) { s.AllocatingReads = 2 })
	quick := h.buy(token, h.plan("tunisia", 1024, 7), "e-1")
	if quick["status"] != "delivered" {
		t.Fatalf("an eSIM made within the wait: %v", quick)
	}

	h.access.Set(func(s *esimaccessfake.Server) { s.AllocatingReads = 1 << 20 })
	slow := h.buy(token, h.plan("turkey", 1024, 7), "e-2")
	id := slow["id"].(string)
	if slow["status"] == "delivered" || slow["status"] == "refunded" {
		t.Fatalf("an eSIM still being made: %v", slow)
	}
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	if _, body := h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil); orderOf(t, body)["status"] == "refunded" {
		t.Fatalf("refunded while the eSIM was being made: %v", body)
	}
	h.access.Allocate()
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	_, body := h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	if orderOf(t, body)["status"] != "delivered" || h.access.Orders != 2 {
		t.Fatalf("the slow order: %v, %d orders at eSIM Access", body, h.access.Orders)
	}
	if row := h.issued(token, id); row["iccid"] == "" {
		t.Fatalf("eSIM: %v", row)
	}
}

func TestESIMAccessLostAnswerIsFoundAndNeverOrderedTwice(t *testing.T) {
	h := newESIMAccessHarness(t, false, nil)
	token := h.customer("0911111111")
	h.access.Set(func(s *esimaccessfake.Server) { s.LoseOrderAnswer = true })
	order := h.buy(token, h.plan("tunisia", 1024, 7), "e-1")
	id := order["id"].(string)
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	_, body := h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	if orderOf(t, body)["status"] != "delivered" || h.access.Orders != 1 {
		t.Fatalf("the lost order should be found: %v, %d orders", body, h.access.Orders)
	}
}

// A package that costs more than the catalog said is refused by eSIM Access
// (the order carries the price), and the customer gets the money back.
func TestESIMAccessRefusedOrderGoesBackToCredit(t *testing.T) {
	for _, code := range []string{esimaccess.CodePriceChanged, esimaccess.CodeInsufficientFunds, esimaccess.CodeOutOfStock} {
		h := newESIMAccessHarness(t, false, nil)
		token := h.customer("0911111111")
		h.access.Set(func(s *esimaccessfake.Server) { s.FailOrderCode = code })
		order := h.buy(token, h.plan("tunisia", 1024, 7), "e-1")
		if order["status"] != "refunded" || h.credit(token) != order["total"] || h.access.Orders != 0 {
			t.Fatalf("code %s: %v, credit %s", code, order, h.credit(token))
		}
	}
}

// The alerts that drive top-ups: eSIM Access only says which eSIM to look at,
// the relay reads the usage itself and tells each level once.
func TestESIMAccessEventsTellTheBuyerOncePerLevel(t *testing.T) {
	h := newESIMAccessHarness(t, false, nil)
	token := h.customer("0911111111")
	order := h.buy(token, h.plan("tunisia", 1024, 7), "e-1")
	iccid := h.issued(token, order["id"].(string))["iccid"].(string)
	if status, _ := h.do(http.MethodPut, "/v1/customers/me/push", token, map[string]any{"token": "phone-1"}); status >= 300 {
		t.Fatalf("register: %d", status)
	}
	const megabyte = int64(1) << 20

	if status := h.event("wrong", esimaccess.NotifyDataUsage, iccid); status != http.StatusNotFound {
		t.Fatalf("a wrong token: %d", status)
	}
	// Half used: nothing to say yet, whatever the delivery claims.
	h.access.Use(iccid, 512*megabyte, esimaccess.StatusInUse)
	if status := h.event("tok", esimaccess.NotifyDataUsage, iccid); status != http.StatusOK || h.pusher.count() != 0 {
		t.Fatalf("half used: %d, %d pushes", status, h.pusher.count())
	}
	h.access.Use(iccid, 800*megabyte, esimaccess.StatusInUse)
	for range 3 {
		h.event("tok", esimaccess.NotifyDataUsage, iccid)
	}
	if h.pusher.count() != 1 || h.pusher.lastMessage().Campaign != "esim_low_data_75" ||
		h.pusher.lastMessage().Link != "https://cards.dftr.ly/esims/"+iccid {
		t.Fatalf("75%%: %d pushes, %+v", h.pusher.count(), h.pusher.lastMessage())
	}
	h.access.Use(iccid, 950*megabyte, esimaccess.StatusInUse)
	h.event("tok", esimaccess.NotifyDataUsage, iccid)
	h.event("tok", esimaccess.NotifyESIMStatus, iccid)
	if h.pusher.count() != 2 || h.pusher.lastMessage().Campaign != "esim_low_data_90" ||
		!strings.Contains(h.pusher.lastMessage().Body, "اشحنها الآن") {
		t.Fatalf("90%%: %d pushes, %+v", h.pusher.count(), h.pusher.lastMessage())
	}
	// A day left.
	h.access.Expire(iccid, h.server.clock().Now().Add(20*time.Hour))
	h.event("tok", esimaccess.NotifyValidityUsage, iccid)
	if h.pusher.count() != 3 || h.pusher.lastMessage().Campaign != "esim_low_data_1day" {
		t.Fatalf("a day left: %d pushes, %+v", h.pusher.count(), h.pusher.lastMessage())
	}
	// Used up.
	h.access.Use(iccid, 1024*megabyte, esimaccess.StatusUsedUp)
	h.event("tok", esimaccess.NotifyESIMStatus, iccid)
	h.event("tok", esimaccess.NotifyESIMStatus, iccid)
	if h.pusher.count() != 4 || h.pusher.lastMessage().Campaign != "esim_low_data_used_up" {
		t.Fatalf("used up: %d pushes, %+v", h.pusher.count(), h.pusher.lastMessage())
	}
	_, body := h.do(http.MethodGet, "/v1/customers/esims/"+iccid, token, nil)
	if usage := body["esim"].(map[string]any)["usage"].(map[string]any); usage["status"] != "FINISHED" || usage["remaining_mb"] != float64(0) {
		t.Fatalf("usage: %v", usage)
	}

	// A top-up: the eSIM is in use again, and its levels are new.
	_, body = h.do(http.MethodGet, "/v1/customers/esims/"+iccid+"/topups", token, nil)
	if topped := h.buy(token, body["plans"].([]any)[0].(map[string]any), "t-1"); topped["status"] != "delivered" {
		t.Fatalf("top-up: %v", topped)
	}
	h.access.Expire(iccid, h.server.clock().Now().Add(240*time.Hour))
	h.access.Use(iccid, 1950*megabyte, esimaccess.StatusInUse)
	h.event("tok", esimaccess.NotifyDataUsage, iccid)
	if h.pusher.count() != 5 || h.pusher.lastMessage().Campaign != "esim_low_data_90" {
		t.Fatalf("after a top-up: %d pushes, %+v", h.pusher.count(), h.pusher.lastMessage())
	}
	// An eSIM this relay never sold is acknowledged and ignored.
	if status := h.event("tok", esimaccess.NotifyDataUsage, "8900000000000000001"); status != http.StatusOK || h.pusher.count() != 5 {
		t.Fatalf("a stranger's eSIM: %d, %d pushes", status, h.pusher.count())
	}
}

// Two suppliers, one shelf: a country both sell is one destination, and a size
// both sell is listed once, from whoever charges the company less.
func TestESIMShelfMergesSuppliersAndBuysEachPlanFromItsOwn(t *testing.T) {
	h := newESIMAccessHarness(t, true, nil)
	token := h.customer("0911111111")
	// Airalo's 1 GB for 7 days costs it 2.50 USD, eSIM Access's 0.46.
	cheap := h.plan("turkey", 1024, 7)
	if cheap["id"] != "ea.PTR1G7" || cheap["price"] != "8.000" {
		t.Fatalf("Turkey 1 GB: %v", cheap)
	}
	var airaloOnly map[string]any
	for _, plan := range h.plans("turkey") {
		if !strings.HasPrefix(plan["id"].(string), esimAccessPlanPrefix) {
			airaloOnly = plan
		}
	}
	if airaloOnly == nil {
		t.Fatalf("Airalo's other sizes left the shelf: %v", h.plans("turkey"))
	}
	if order := h.buy(token, cheap, "e-1"); order["status"] != "delivered" || h.access.Orders != 1 || h.airalo.OrderRequests != 0 {
		t.Fatalf("the cheap plan: %v, eSIM Access %d, Airalo %d", order, h.access.Orders, h.airalo.OrderRequests)
	}
	order := h.buy(token, airaloOnly, "e-2")
	if order["status"] != "delivered" || h.access.Orders != 1 || h.airalo.OrderRequests != 1 {
		t.Fatalf("Airalo's plan: %v, eSIM Access %d, Airalo %d", order, h.access.Orders, h.airalo.OrderRequests)
	}
	stored, err := h.store.GetCustomerESIM(context.Background(), h.issued(token, order["id"].(string))["iccid"].(string))
	if err != nil || stored.Supplier != vouchers.SupplierAiralo {
		t.Fatalf("Airalo's eSIM: %+v %v", stored, err)
	}
	// Airalo's regions and eSIM Access's stay apart.
	_, body := h.do(http.MethodGet, "/v1/customers/esim/destinations", "", nil)
	keys := map[string]bool{}
	for _, raw := range body["destinations"].([]any) {
		keys[raw.(map[string]any)["key"].(string)] = true
	}
	if !keys["europe"] || !keys["ea-eu-33"] || !keys["world"] || !keys["tunisia"] {
		t.Fatalf("destinations: %v", keys)
	}

	// eSIM Access goes down at the next sync: its plans stay on the shelf.
	h.access.Set(func(s *esimaccessfake.Server) { s.AccessCode = "rotated" })
	_ = h.server.syncESIMCatalog(context.Background(), h.store)
	h.server.ESIM.state.checkedAt = time.Time{}
	if kept := h.plan("turkey", 1024, 7); kept["id"] != "ea.PTR1G7" {
		t.Fatalf("an outage emptied a supplier's plans: %v", kept)
	}
}

// With a live supplier beside a Sandbox Airalo the shelf is everyone's, sells
// nothing of Airalo's, and the stores' review account still buys for show.
func TestESIMAccessOpensTheShelfBesideASandboxAiralo(t *testing.T) {
	h := newESIMAccessHarness(t, true, func(h *esimAccessHarness) { h.server.ESIM.Sandbox = true })
	status, body := h.do(http.MethodGet, "/v1/customers/esim/destinations", "", nil)
	if status != http.StatusOK || body["available"] != true || body["test_mode"] != false {
		t.Fatalf("shelf: %d %v", status, body)
	}
	for _, raw := range body["destinations"].([]any) {
		if key := raw.(map[string]any)["key"]; key == "europe" || key == "world" {
			t.Fatalf("a Sandbox destination is on the shelf: %v", key)
		}
	}
	for _, plan := range h.plans("turkey") {
		if !strings.HasPrefix(plan["id"].(string), esimAccessPlanPrefix) {
			t.Fatalf("a Sandbox plan is on the shelf: %v", plan)
		}
	}
	reviewer := h.reviewer()
	plan := h.plan("tunisia", 1024, 7)
	_, placed := h.do(http.MethodPost, "/v1/customers/orders", reviewer, sadadOrder(plan["item"].(string), plan["price"].(string), "r-1", 1))
	_, paid := h.do(http.MethodPost, "/v1/customers/orders/"+orderOf(t, placed)["id"].(string)+"/confirm", reviewer, map[string]any{"otp": "246810"})
	order := orderOf(t, paid)
	if order["status"] != "delivered" || h.access.Orders != 0 || h.airalo.OrderRequests != 0 {
		t.Fatalf("review: %v, eSIM Access %d, Airalo %d", order, h.access.Orders, h.airalo.OrderRequests)
	}
	row := h.issued(reviewer, order["id"].(string))
	_, read := h.do(http.MethodGet, "/v1/customers/esims/"+row["iccid"].(string), reviewer, nil)
	if install := read["esim"].(map[string]any)["install"].(map[string]any); !strings.Contains(install["qr"].(string), "test.dftr.ly") {
		t.Fatalf("install: %v", install)
	}
	// A customer buys a real one.
	if order := h.buy(h.customer("0911111111"), plan, "e-1"); order["status"] != "delivered" || h.access.Orders != 1 {
		t.Fatalf("a customer's order: %v", order)
	}
}

func TestESIMAccessWebhookIsRegisteredWithItsSecret(t *testing.T) {
	h := newESIMAccessHarness(t, false, nil)
	h.server.ensureESIMWebhooks(context.Background())
	want := "https://relay.test/v1/customers/esim/webhook/access/tok"
	if h.access.Webhook != want {
		t.Fatalf("webhook = %q, want %q", h.access.Webhook, want)
	}
	if ESIMAccessWebhookToken("code") == "" || ESIMAccessWebhookToken("code") == ESIMAccessWebhookToken("other") || ESIMAccessWebhookToken("") != "" {
		t.Fatal("the webhook token must follow the access code")
	}
}
