package relay

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/airalo"
	"pointy/relay/internal/airalo/airalofake"
	"pointy/relay/internal/fcm"
	"pointy/relay/internal/vouchers"
)

type esimHarness struct {
	*orderHarness
	fake   *airalofake.Server
	pusher *fakePusher
}

func newESIMHarness(t *testing.T) *esimHarness {
	t.Helper()
	h := newOrderHarness(t)
	h.cards.setRate(t, "7.50")
	fake := airalofake.New()
	upstream := httptest.NewServer(fake.Handler())
	t.Cleanup(upstream.Close)
	client := airalo.New(airalo.Config{BaseURL: upstream.URL, ClientID: "id", ClientSecret: "secret", RetryDelay: time.Millisecond})
	h.server.Vouchers.Suppliers[vouchers.SupplierAiralo] = &vouchers.AiraloSupplier{Client: client}
	h.server.ESIM = NewESIMConfig(ESIMConfig{Client: client})
	pusher := &fakePusher{}
	h.server.CustomerPush = pusher
	if err := h.server.syncESIMCatalog(context.Background(), h.store); err != nil {
		t.Fatal(err)
	}
	return &esimHarness{orderHarness: h, fake: fake, pusher: pusher}
}

// plan finds a plan's price on the shelf.
func (h *esimHarness) plan(destination, id string) (string, string) {
	h.t.Helper()
	status, body := h.do(http.MethodGet, "/v1/customers/esim/destinations/"+destination, "", nil)
	if status != http.StatusOK {
		h.t.Fatalf("destination: %d %v", status, body)
	}
	for _, raw := range body["plans"].([]any) {
		plan := raw.(map[string]any)
		if plan["id"] == id {
			return plan["item"].(string), plan["price"].(string)
		}
	}
	h.t.Fatalf("no plan %s in %v", id, body)
	return "", ""
}

// buy places and pays an eSIM order with the wallet.
func (h *esimHarness) buy(token, item, price, key string, account map[string]string) map[string]any {
	h.t.Helper()
	request := sadadOrder(item, price, key, 1)
	if account != nil {
		request["account"] = account
	}
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, request)
	if status != http.StatusCreated {
		h.t.Fatalf("create: %d %v", status, body)
	}
	id := orderOf(h.t, body)["id"].(string)
	_, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	return orderOf(h.t, body)
}

func (h *esimHarness) issued(token, orderID string) map[string]any {
	h.t.Helper()
	_, body := h.do(http.MethodGet, "/v1/customers/esims?order="+orderID, token, nil)
	list := body["esims"].([]any)
	if len(list) != 1 {
		h.t.Fatalf("eSIMs of the order: %v", body)
	}
	return list[0].(map[string]any)
}

func (h *esimHarness) webhook(event string, signature string) int {
	h.t.Helper()
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/customers/esim/webhook", strings.NewReader(event))
	request.Header.Set(airalo.SignatureHeader, signature)
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	return recorder.Code
}

func TestESIMShelfIsPublicPricedAndOffWithoutARate(t *testing.T) {
	h := newESIMHarness(t)
	status, body := h.do(http.MethodGet, "/v1/customers/esim/destinations", "", nil)
	if status != http.StatusOK || body["available"] != true {
		t.Fatalf("shelf: %d %v", status, body)
	}
	kinds := map[string]string{}
	for _, raw := range body["destinations"].([]any) {
		row := raw.(map[string]any)
		kinds[row["key"].(string)] = row["kind"].(string)
		// Nothing about the company's cost reaches the app.
		if _, leaked := row["net_usd"]; leaked {
			t.Fatalf("the net cost leaked: %v", row)
		}
	}
	if kinds["turkey"] != esimKindLocal || kinds["europe"] != esimKindRegional || kinds["world"] != esimKindGlobal {
		t.Fatalf("kinds: %v", kinds)
	}
	// 1 GB, 7 days: recommended 4.50 USD × 7.50 = 33.75. The net price is 18.75.
	_, price := h.plan("turkey", "merhaba-7days-1gb")
	if price != "33.750" {
		t.Fatalf("price = %s", price)
	}
	h.cards.setRate(t, "")
	if status, body := h.do(http.MethodGet, "/v1/customers/esim/destinations", "", nil); status != http.StatusOK || body["available"] != false {
		t.Fatalf("no dollar rate should close the shelf: %d %v", status, body)
	}
}

func TestESIMPriceNeverBelowTheMarginFloor(t *testing.T) {
	margin := vouchers.Settings{}.Normalized().MarginFor(vouchers.ServiceKindCard)
	rate := vouchers.AiraloDollars(7.5)
	net, retail := vouchers.AiraloDollars(4), vouchers.AiraloDollars(4.1)
	cost := vouchers.AiraloDollars(30)
	price, ok := vouchers.ESIMPrice(net, retail, rate, margin, vouchers.AiraloDollars(50))
	if !ok || price.Cmp(cost) <= 0 {
		t.Fatalf("a 50%% RRP share must not sell under cost: %v", price)
	}
}

func TestESIMBoughtInstallsAndIsToppedUp(t *testing.T) {
	h := newESIMHarness(t)
	token := h.customer("0911111111")
	item, price := h.plan("turkey", "merhaba-7days-1gb")
	order := h.buy(token, item, price, "e-1", map[string]string{"label": "أمي", "gift": "1"})
	if order["status"] != "delivered" || order["delivery"] != "esim" || len(order["codes"].([]any)) != 0 {
		t.Fatalf("order: %v", order)
	}
	row := h.issued(token, order["id"].(string))
	iccid := row["iccid"].(string)
	if row["label"] != "أمي" || row["gift"] != true || row["operator"] != "Merhaba" {
		t.Fatalf("eSIM row: %v", row)
	}

	status, body := h.do(http.MethodGet, "/v1/customers/esims/"+iccid, token, nil)
	esim := body["esim"].(map[string]any)
	install := esim["install"].(map[string]any)
	if status != http.StatusOK ||
		!strings.HasPrefix(install["apple_url"].(string), "https://esimsetup.apple.com/") ||
		!strings.HasPrefix(install["android_url"].(string), "https://esimsetup.android.com/") ||
		!strings.HasPrefix(install["qr"].(string), "LPA:1$") || install["share_code"] != "1234" {
		t.Fatalf("install: %d %v", status, body)
	}
	if usage := esim["usage"].(map[string]any); usage["status"] != "ACTIVE" || usage["remaining_mb"] != float64(512) {
		t.Fatalf("usage: %v", usage)
	}

	// Another customer cannot see it, or top it up.
	stranger := h.customer("0922222222")
	if status, _ := h.do(http.MethodGet, "/v1/customers/esims/"+iccid, stranger, nil); status != http.StatusNotFound {
		t.Fatalf("a stranger read an eSIM: %d", status)
	}
	strangerTopUp := esimTopUpItemPrefix + iccid + ":merhaba-7days-1gb-topup"
	if status, _ := h.do(http.MethodPost, "/v1/customers/orders", stranger, sadadOrder(strangerTopUp, "33.750", "s-1", 1)); status != http.StatusNotFound {
		t.Fatalf("a stranger topped up an eSIM: %d", status)
	}

	// The alert: signed, once, and straight to the eSIM's page.
	event := `{"level":"90%","package_name":"merhaba-7days-1gb","remaining_percentage":10,"iccid":"` + iccid + `"}`
	if status := h.webhook(event, "00"); status != http.StatusUnauthorized {
		t.Fatalf("a bad signature: %d", status)
	}
	if status, _ := h.do(http.MethodPut, "/v1/customers/me/push", token, map[string]any{"token": "phone-1"}); status >= 300 {
		t.Fatalf("register: %d", status)
	}
	signature := airalo.Sign("secret", []byte(event))
	for range 3 {
		if status := h.webhook(event, signature); status != http.StatusOK {
			t.Fatalf("an alert: %d", status)
		}
	}
	if h.pusher.count() != 1 || h.pusher.lastMessage().Link != "https://cards.dftr.ly/esims/"+iccid ||
		!strings.Contains(h.pusher.lastMessage().Body, "أمي") {
		t.Fatalf("pushes: %d, %+v", h.pusher.count(), h.pusher.lastMessage())
	}

	// A top-up from the page; the same level may then be told again.
	_, body = h.do(http.MethodGet, "/v1/customers/esims/"+iccid+"/topups", token, nil)
	plan := body["plans"].([]any)[0].(map[string]any)
	topped := h.buy(token, plan["item"].(string), plan["price"].(string), "t-1", nil)
	if topped["status"] != "delivered" || h.fake.TopUpRequests != 1 {
		t.Fatalf("top-up: %v", topped)
	}
	if status := h.webhook(event, signature); status != http.StatusOK || h.pusher.count() != 2 {
		t.Fatalf("after a top-up the alert is new: %d, %d pushes", status, h.pusher.count())
	}
	// A second eSIM row did not appear for the top-up.
	if _, body := h.do(http.MethodGet, "/v1/customers/esims", token, nil); len(body["esims"].([]any)) != 1 {
		t.Fatalf("eSIMs: %v", body)
	}
}

func TestESIMThatCannotBeHadGoesBackToCredit(t *testing.T) {
	h := newESIMHarness(t)
	token := h.customer("0911111111")
	item, price := h.plan("turkey", "test-out-of-stock-7days-1gb")
	order := h.buy(token, item, price, "e-1", nil)
	if order["status"] != "refunded" || h.credit(token) != order["total"] {
		t.Fatalf("out of stock: %v, credit %s", order, h.credit(token))
	}
}

// The checklist's duplicate safeguard: an answer lost after Airalo took the order
// settles from Airalo's records, and never orders again.
func TestESIMLostAnswerIsFoundAndNeverOrderedTwice(t *testing.T) {
	h := newESIMHarness(t)
	token := h.customer("0911111111")
	item, price := h.plan("egypt", "nile-7days-1gb")
	h.fake.Set(func(s *airalofake.Server) { s.FailOrdersWith500 = true })
	order := h.buy(token, item, price, "e-1", nil)
	// The relay does not know yet, so it asks Airalo before anything else: it
	// finds the order under the purchase's reference and delivers it.
	if order["status"] != "delivered" {
		t.Fatalf("the lost order should be found: %v", order)
	}
	id := order["id"].(string)
	h.do(http.MethodGet, "/v1/customers/orders/"+id, token, nil)
	(&CustomerOrderReconciler{Server: h.server}).Round(context.Background())
	if h.fake.OrderRequests != 1 || h.fake.Orders() != 1 {
		t.Fatalf("orders sent %d, held %d: an eSIM was ordered twice", h.fake.OrderRequests, h.fake.Orders())
	}
	if row := h.issued(token, id); row["iccid"] == "" {
		t.Fatalf("eSIM: %v", row)
	}
	// A replayed key answers the same order.
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder(item, price, "e-1", 1))
	if status != http.StatusOK || orderOf(t, body)["id"] != id {
		t.Fatalf("replay: %d %v", status, body)
	}
}

func TestESIMDeviceCheckNeverSaysNoOnASlowOrUnknownAnswer(t *testing.T) {
	h := newESIMHarness(t)
	status, body := h.do(http.MethodPost, "/v1/customers/esim/device", "", map[string]any{"model": "iPhone13,2"})
	if status != http.StatusOK || body["known"] != true || body["supported"] != true {
		t.Fatalf("a listed phone: %d %v", status, body)
	}
	_, body = h.do(http.MethodPost, "/v1/customers/esim/device", "", map[string]any{"model": "Nokia 3310"})
	if body["known"] != true || body["supported"] != false || body["listed"] != false {
		t.Fatalf("a model off the list is not a verdict: %v", body)
	}
	// The relay's own list knows the codes Airalo's does not, and its noes are
	// verdicts.
	for model, supported := range map[string]bool{
		"iPhone17,1": true, "SM-S918B": true, "iPad13,17": true,
		"iPhone10,3": false, "iPad13,16": false, "SM-S9180": false,
	} {
		_, body = h.do(http.MethodPost, "/v1/customers/esim/device", "", map[string]any{"model": model})
		if body["known"] != true || body["supported"] != supported || body["listed"] != true || body["source"] != "relay" {
			t.Fatalf("%s from the relay's own list, supported=%v: %v", model, supported, body)
		}
	}
	if status, _ := h.do(http.MethodPost, "/v1/customers/esim/device", "", map[string]any{"model": "<script>"}); status != http.StatusBadRequest {
		t.Fatalf("a junk model: %d", status)
	}
	// With no Airalo account the relay's own list still answers; what it does
	// not know, nobody can tell.
	h.server.ESIM.Client = nil
	if _, body := h.do(http.MethodPost, "/v1/customers/esim/device", "", map[string]any{"model": "iPhone13,2"}); body["supported"] != true {
		t.Fatalf("no account, a model the relay knows: %v", body)
	}
	if _, body := h.do(http.MethodPost, "/v1/customers/esim/device", "", map[string]any{"model": "SM-A155F"}); body["known"] != false {
		t.Fatalf("no account: %v", body)
	}
}

func TestESIMWebhookAnswersHeadForTheOptInAndOptsIn(t *testing.T) {
	h := newESIMHarness(t)
	relay := httptest.NewServer(h.server)
	t.Cleanup(relay.Close)
	url := relay.URL + "/v1/customers/esim/webhook"
	head, err := http.Head(url)
	if err != nil || head.StatusCode != http.StatusOK {
		t.Fatalf("HEAD: %v, %v", head, err)
	}
	h.server.ESIM.WebhookURL = url
	h.server.ensureESIMWebhooks(context.Background())
	if h.fake.OptIns[airalo.NotifyLowData] != url || h.fake.OptIns[airalo.NotifyCreditLimit] != url {
		t.Fatalf("opt-ins: %v", h.fake.OptIns)
	}
}

func TestReviewAccountBuysASimulatedESIM(t *testing.T) {
	h := newESIMHarness(t)
	token := h.reviewer()
	item, price := h.plan("europe", "eurolink-7days-1gb")
	_, placed := h.do(http.MethodPost, "/v1/customers/orders", token, sadadOrder(item, price, "r-1", 1))
	_, paid := h.do(http.MethodPost, "/v1/customers/orders/"+orderOf(t, placed)["id"].(string)+"/confirm", token, map[string]any{"otp": "246810"})
	order := orderOf(t, paid)
	if order["status"] != "delivered" || h.fake.OrderRequests != 0 {
		t.Fatalf("review: %v, %d real orders", order, h.fake.OrderRequests)
	}
	row := h.issued(token, order["id"].(string))
	_, body := h.do(http.MethodGet, "/v1/customers/esims/"+row["iccid"].(string), token, nil)
	if install := body["esim"].(map[string]any)["install"].(map[string]any); !strings.Contains(install["qr"].(string), "test.dftr.ly") {
		t.Fatalf("install: %v", install)
	}
}

func TestSandboxShelfIsTheReviewAccountsAndBuysFromAiraloSandbox(t *testing.T) {
	h := newESIMHarness(t)
	h.server.ESIM.Sandbox = true
	customer := h.customer("0911111111")
	reviewer := h.reviewer()

	// Nobody but the review account sees a shelf, signed in or not.
	for who, token := range map[string]string{"anonymous": "", "customer": customer} {
		if status, body := h.do(http.MethodGet, "/v1/customers/esim/destinations", token, nil); status != http.StatusOK || body["available"] != false {
			t.Fatalf("%s saw the shelf: %d %v", who, status, body)
		}
		if status, _ := h.do(http.MethodGet, "/v1/customers/esim/destinations/europe", token, nil); status != http.StatusNotFound {
			t.Fatalf("%s read a destination: %d", who, status)
		}
		if _, body := h.do(http.MethodPost, "/v1/customers/esim/device", token, map[string]any{"model": "iPhone15,2"}); body["known"] != false {
			t.Fatalf("%s checked a device: %v", who, body)
		}
	}
	// Nor can a customer buy one by naming its item.
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", customer,
		sadadOrder("esim:eurolink-7days-1gb", "10.000", "c-1", 1)); status != http.StatusConflict {
		t.Fatalf("a customer ordered a Sandbox eSIM: %d %v", status, body)
	}
	// A stale session is told to refresh, not shown an empty shelf.
	if status, body := h.do(http.MethodGet, "/v1/customers/esim/destinations", "pca1.stale", nil); status != http.StatusUnauthorized || body["code"] != "token_expired" {
		t.Fatalf("stale token: %d %v", status, body)
	}

	status, shelf := h.do(http.MethodGet, "/v1/customers/esim/destinations", reviewer, nil)
	if status != http.StatusOK || shelf["available"] != true {
		t.Fatalf("the reviewer's shelf: %d %v", status, shelf)
	}
	_, destination := h.do(http.MethodGet, "/v1/customers/esim/destinations/europe", reviewer, nil)
	var item, price string
	for _, raw := range destination["plans"].([]any) {
		if plan := raw.(map[string]any); plan["id"] == "eurolink-7days-1gb" {
			item, price = plan["item"].(string), plan["price"].(string)
		}
	}
	_, placed := h.do(http.MethodPost, "/v1/customers/orders", reviewer, sadadOrder(item, price, "r-1", 1))
	_, paid := h.do(http.MethodPost, "/v1/customers/orders/"+orderOf(t, placed)["id"].(string)+"/confirm", reviewer, map[string]any{"otp": "246810"})
	order := orderOf(t, paid)
	// Paid for show, bought for real from Airalo's Sandbox: it is on their
	// dashboard, and installs with what Airalo issued.
	if order["status"] != "delivered" || h.fake.OrderRequests != 1 {
		t.Fatalf("review: %v, %d Airalo orders", order, h.fake.OrderRequests)
	}
	row := h.issued(reviewer, order["id"].(string))
	_, body := h.do(http.MethodGet, "/v1/customers/esims/"+row["iccid"].(string), reviewer, nil)
	if install := body["esim"].(map[string]any)["install"].(map[string]any); strings.Contains(install["qr"].(string), "test.dftr.ly") {
		t.Fatalf("a simulated eSIM: %v", install)
	}
	// And it stays out of the books.
	months, _ := h.store.FinanceTracked(context.Background(), time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC), time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC))
	for _, month := range months {
		if len(month.CardsAppCost) != 0 || month.Revenue["cards_app"] != "" {
			t.Fatalf("a review eSIM reached the books: %+v", month)
		}
	}
}

func TestForgetsESIMsWithTheAccount(t *testing.T) {
	h := newESIMHarness(t)
	token := h.customer("0911111111")
	item, price := h.plan("turkey", "merhaba-7days-1gb")
	order := h.buy(token, item, price, "e-1", nil)
	iccid := h.issued(token, order["id"].(string))["iccid"].(string)
	if status, _ := h.do(http.MethodDelete, "/v1/customers/me", token, nil); status != http.StatusNoContent {
		t.Fatalf("delete: %d", status)
	}
	if _, err := h.store.GetCustomerESIM(context.Background(), iccid); err == nil {
		t.Fatal("the eSIM outlived the account")
	}
}

func (p *fakePusher) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.tokens)
}

func (p *fakePusher) lastMessage() fcm.Message {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.last
}
