package relay

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/fazer"
	"pointy/relay/internal/vouchers"
)

// accountSupplier stands in for FazerCards: it sends credit to accounts.
type accountSupplier struct {
	fakeSupplier
	mu       sync.Mutex
	accounts []vouchers.Account
	checks   int
	// settled is, per purchase, whether the supplier was let wait for it.
	settled []bool
}

func newAccountSupplier() *accountSupplier {
	supplier := &accountSupplier{fakeSupplier: *newFakeSupplier()}
	supplier.buyResult = vouchers.Purchase{OrderID: "ord-1", Status: vouchers.StatusSucceeded, Cost: "0.85", Currency: "USD"}
	return supplier
}

func (a *accountSupplier) Key() string { return vouchers.SupplierFazer }

func (a *accountSupplier) BuyFor(ctx context.Context, ref vouchers.Ref, account vouchers.Account, clientRef string) (vouchers.Purchase, error) {
	a.mu.Lock()
	a.accounts = append(a.accounts, account)
	a.settled = append(a.settled, vouchers.Settles(ctx))
	a.mu.Unlock()
	return a.Buy(context.Background(), ref, 1, clientRef)
}

func (a *accountSupplier) CheckAccount(_ context.Context, _ vouchers.Ref, target vouchers.Target, account vouchers.Account) (vouchers.AccountCheck, error) {
	a.mu.Lock()
	a.checks++
	a.mu.Unlock()
	if target.Kind == vouchers.TargetTelegram {
		// As FazerCards: a username has no check.
		return vouchers.AccountCheck{Status: vouchers.AccountUnchecked}, nil
	}
	if account["player_id"] == "404" {
		return vouchers.AccountCheck{Status: vouchers.AccountInvalid}, nil
	}
	return vouchers.AccountCheck{Status: vouchers.AccountValid, Name: "Sniper_" + account["player_id"], Region: target.Check}, nil
}

func (a *accountSupplier) sent() []vouchers.Account {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]vouchers.Account(nil), a.accounts...)
}

const accountCatalog = `{
  "categories": [{"key": "telecom", "name": "اتصالات", "sort": 1}, {"key": "game_topup", "name": "شحن الألعاب", "sort": 2},
                 {"key": "telegram", "name": "تيليجرام", "sort": 3}],
  "brands": [
    {"key": "libyana", "name": "ليبيانا", "category": "telecom", "logo": {},
     "items": [{"key": "libyana-10", "face_value": "10", "face_currency": "LYD", "price": "9.70", "retail_price": "10.00",
                "supplier": {"key": "bnplus", "card_id": 12}}]},
    {"key": "pubg", "name": "ببجي موبايل", "category": "game_topup", "logo": {},
     "target": {"kind": "game_account", "check": "pubg_mobile", "hint": "من الملف الشخصي في اللعبة",
                "fields": [{"key": "player_id", "label": "معرّف اللاعب"}]},
     "items": [{"key": "pubg-60", "label": "60 UC", "price": "9.00", "retail_price": "11.00",
                "supplier": {"key": "fazer", "product": "topup", "category": "pubg_mobile_auto", "offer": "60"}}]},
    {"key": "tg-stars", "name": "نجوم تيليجرام", "category": "telegram", "logo": {},
     "target": {"kind": "telegram_username", "fields": [{"key": "username", "label": "اسم المستخدم"}]},
     "items": [{"key": "stars-100", "label": "100 نجمة", "price": "14.00", "retail_price": "16.00",
                "supplier": {"key": "fazer", "product": "stars", "quantity": 100}}]}
  ]
}`

func publishAccountCatalog(t *testing.T, h *voucherHarness) {
	t.Helper()
	body := []byte(`{"document": ` + accountCatalog + `, "actor": "ops", "note": "accounts"}`)
	if status, published := h.admin(t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json", body); status != http.StatusCreated {
		t.Fatalf("publish: %d %v", status, published)
	}
}

// pricedAccountOffers stores the account cards' offers (in dinars, so no rate
// is needed): a dollar supplier is never bought from blind.
func pricedAccountOffers(t *testing.T, store *control.FileStore, now time.Time) {
	t.Helper()
	if err := store.ReplaceVoucherOffers(context.Background(), vouchers.SupplierFazer, []control.VoucherOffer{
		{Ref: "topup/pubg_mobile_auto/60", Name: "60 UC", Price: "8.30", Currency: "LYD", InStock: true, SyncedAt: now},
		{Ref: "stars/100", Name: "100 Telegram Stars", Price: "14.90", Currency: "LYD", InStock: true, SyncedAt: now},
	}); err != nil {
		t.Fatal(err)
	}
}

func newAccountHarness(t *testing.T) (*voucherHarness, *accountSupplier) {
	t.Helper()
	h := newVoucherHarness(t)
	supplier := newAccountSupplier()
	h.server.Vouchers.Suppliers[vouchers.SupplierFazer] = supplier
	publishAccountCatalog(t, h)
	pricedAccountOffers(t, h.store, h.now)
	return h, supplier
}

func brandKeys(t *testing.T, view map[string]any) []string {
	t.Helper()
	var keys []string
	for _, raw := range view["brands"].([]any) {
		keys = append(keys, raw.(map[string]any)["key"].(string))
	}
	return keys
}

func TestShopsThatCannotAskForAnAccountAreNotShownAccountCards(t *testing.T) {
	h, _ := newAccountHarness(t)
	shop := h.provision(t)

	recorder := h.request(t, h.server, http.MethodGet, "/v1/vouchers/catalog", map[string]string{AccessTokenHeader: shop.AccessToken}, nil)
	old := decodeBody(t, recorder)
	if keys := brandKeys(t, old); len(keys) != 1 || keys[0] != "libyana" || len(old["categories"].([]any)) != 1 {
		t.Fatalf("an older backend is shown %v", old)
	}
	recorder = h.request(t, h.server, http.MethodGet, "/v1/vouchers/catalog?accounts=1", map[string]string{AccessTokenHeader: shop.AccessToken}, nil)
	current := decodeBody(t, recorder)
	if keys := brandKeys(t, current); len(keys) != 3 {
		t.Fatalf("a backend that asks is shown %v", keys)
	}
	if current["version"] == old["version"] {
		t.Fatal("both views share a version, so an ETag would serve one for the other")
	}
	for _, raw := range current["brands"].([]any) {
		brand := raw.(map[string]any)
		if brand["key"] == "pubg" {
			target := brand["target"].(map[string]any)
			if target["kind"] != vouchers.TargetGameAccount || target["fields"].([]any)[0].(map[string]any)["key"] != "player_id" {
				t.Fatalf("pubg target = %v", target)
			}
		}
		if brand["key"] == "libyana" && brand["target"] != nil {
			t.Fatal("a code brand has no target")
		}
	}
}

func TestAShopTopsUpAnAccount(t *testing.T) {
	h, supplier := newAccountHarness(t)
	shop := h.provision(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "100")
	buy := func(key string, account map[string]string, quantity int) (int, map[string]any) {
		request := purchaseRequest("pubg-60", key, "9.00")
		request["quantity"] = quantity
		if account != nil {
			request["account"] = account
		}
		return h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken, request)
	}

	if status, body := buy("p-0", nil, 1); status != http.StatusBadRequest || body["code"] != voucherCodeAccountRequired {
		t.Fatalf("no account: %d %v", status, body)
	}
	if status, body := buy("p-0", map[string]string{"player_id": "51 23"}, 1); status != http.StatusBadRequest ||
		body["code"] != voucherCodeInvalidAccount || body["field"] != "player_id" {
		t.Fatalf("a space in the ID: %d %v", status, body)
	}
	if status, body := buy("p-0", map[string]string{"player_id": "5123", "zone": "1"}, 1); status != http.StatusBadRequest ||
		body["code"] != voucherCodeInvalidAccount {
		t.Fatalf("a field the card does not have: %d %v", status, body)
	}
	if status, body := buy("p-0", map[string]string{"player_id": "5123"}, 2); status != http.StatusBadRequest ||
		body["code"] != voucherCodeInvalidQuantity {
		t.Fatalf("two at once: %d %v", status, body)
	}
	if len(supplier.calls()) != 0 || h.voucherBalance(t, shop.Installation.ID) != "100.000" {
		t.Fatal("a refused request bought or charged something")
	}

	status, body := buy("p-1", map[string]string{"player_id": " 5123456789 "}, 1)
	purchase := body["purchase"].(map[string]any)
	if status != http.StatusCreated || purchase["status"] != control.VoucherPurchaseSucceeded ||
		purchase["delivery"] != "account" || len(purchase["codes"].([]any)) != 0 || purchase["codes_pending"] != false {
		t.Fatalf("top-up: %d %v", status, body)
	}
	if purchase["target"] != "51•••••789" {
		t.Fatalf("the purchase keeps the account masked: %v", purchase["target"])
	}
	if sent := supplier.sent(); len(sent) != 1 || sent[0]["player_id"] != "5123456789" {
		t.Fatalf("the supplier was sent %v", sent)
	}
	if calls := supplier.calls(); len(calls) != 1 || calls[0].ClientRef == "" {
		t.Fatalf("supplier calls = %+v", calls)
	}
	if h.voucherBalance(t, shop.Installation.ID) != "91.000" {
		t.Fatalf("balance = %s", h.voucherBalance(t, shop.Installation.ID))
	}

	// A replay answers the same purchase, and so does a read back: no code
	// is waited for.
	status, replay := buy("p-1", map[string]string{"player_id": "5123456789"}, 1)
	if status != http.StatusOK || replay["replayed"] != true || replay["purchase"].(map[string]any)["codes_pending"] != false {
		t.Fatalf("replay: %d %v", status, replay)
	}
	status, read := h.shop(t, h.server, http.MethodGet, "/v1/vouchers/purchases/p-1", shop.AccessToken, nil)
	if status != http.StatusOK || read["purchase"].(map[string]any)["delivery"] != "account" {
		t.Fatalf("read back: %d %v", status, read)
	}
	if len(supplier.calls()) != 1 {
		t.Fatal("a replay bought again")
	}
}

func TestACodeCardTakesNoAccount(t *testing.T) {
	h, _ := newAccountHarness(t)
	shop := h.provision(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "100")
	request := purchaseRequest("libyana-10", "c-1", "9.70")
	request["account"] = map[string]string{"player_id": "1"}
	if status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken, request); status != http.StatusBadRequest ||
		body["code"] != voucherCodeNotAnAccount {
		t.Fatalf("a code card with an account: %d %v", status, body)
	}
}

func TestATelegramUsernameLosesItsAt(t *testing.T) {
	h, supplier := newAccountHarness(t)
	shop := h.provision(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "100")
	request := purchaseRequest("stars-100", "s-1", "14.00")
	request["account"] = map[string]string{"username": "@bad name"}
	if status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken, request); status != http.StatusBadRequest {
		t.Fatalf("not a username: %d %v", status, body)
	}
	request["account"] = map[string]string{"username": "@daftar_ly"}
	status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken, request)
	if status != http.StatusCreated {
		t.Fatalf("stars: %d %v", status, body)
	}
	if sent := supplier.sent(); len(sent) != 1 || sent[0]["username"] != "daftar_ly" {
		t.Fatalf("sent %v", sent)
	}
	if target := body["purchase"].(map[string]any)["target"]; target != "@da••••_ly" {
		t.Fatalf("masked username = %v", target)
	}
}

func TestAccountCheck(t *testing.T) {
	h, supplier := newAccountHarness(t)
	shop := h.provision(t)
	check := func(item string, account map[string]string) (int, map[string]any) {
		return h.shop(t, h.server, http.MethodPost, "/v1/vouchers/accounts/check", shop.AccessToken,
			map[string]any{"item": item, "account": account})
	}
	status, body := check("pubg-60", map[string]string{"player_id": "5123"})
	if status != http.StatusOK || body["status"] != vouchers.AccountValid || body["name"] != "Sniper_5123" || body["account"] != "5123" {
		t.Fatalf("check: %d %v", status, body)
	}
	if _, body := check("pubg-60", map[string]string{"player_id": "404"}); body["status"] != vouchers.AccountInvalid {
		t.Fatalf("unknown player: %v", body)
	}
	// Telegram has no check: what was typed comes back, read.
	if _, body := check("stars-100", map[string]string{"username": "@daftar_ly"}); body["status"] != vouchers.AccountUnchecked ||
		body["account"] != "@daftar_ly" {
		t.Fatalf("telegram: %v", body)
	}
	if status, body := check("libyana-10", map[string]string{"player_id": "1"}); status != http.StatusBadRequest ||
		body["code"] != voucherCodeNotAnAccount {
		t.Fatalf("code card: %d %v", status, body)
	}
	if supplier.checks != 3 || len(supplier.calls()) != 0 {
		t.Fatalf("checks = %d, buys = %d: a check never buys", supplier.checks, len(supplier.calls()))
	}
}

func TestTestModeTopsUpNobody(t *testing.T) {
	h := newVoucherHarness(t)
	h.server.Vouchers = VoucherConfig{TestMode: true, RequestTimeout: time.Second}
	publishAccountCatalog(t, h)
	shop := h.provision(t)
	h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "100")
	request := purchaseRequest("pubg-60", "t-1", "9.00")
	request["account"] = map[string]string{"player_id": "5123456789"}
	status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken, request)
	purchase := body["purchase"].(map[string]any)
	if status != http.StatusCreated || purchase["test_mode"] != true || purchase["delivery"] != "account" {
		t.Fatalf("test top-up: %d %v", status, body)
	}
	_, check := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/accounts/check", shop.AccessToken,
		map[string]any{"item": "pubg-60", "account": map[string]string{"player_id": "1"}})
	if check["name"] != "TEST PLAYER" {
		t.Fatalf("test check: %v", check)
	}
}

func TestACatalogKeepsABrandOneKindOfCard(t *testing.T) {
	h := newVoucherHarness(t)
	mixed := strings.Replace(accountCatalog, `"supplier": {"key": "fazer", "product": "stars", "quantity": 100}`,
		`"supplier": {"key": "bnplus", "card_id": 77}`, 1)
	body := []byte(`{"document": ` + mixed + `, "actor": "ops"}`)
	status, refused := h.admin(t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json", body)
	raw, _ := json.Marshal(refused)
	if status != http.StatusUnprocessableEntity || !strings.Contains(string(raw), "sends to an account") {
		t.Fatalf("a code supplier under an account brand: %d %s", status, raw)
	}
	codeBrand := strings.Replace(accountCatalog, `"target": {"kind": "telegram_username", "fields": [{"key": "username", "label": "اسم المستخدم"}]},`, "", 1)
	body = []byte(`{"document": ` + codeBrand + `, "actor": "ops"}`)
	status, refused = h.admin(t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json", body)
	raw, _ = json.Marshal(refused)
	if status != http.StatusUnprocessableEntity || !strings.Contains(string(raw), "needs a target") {
		t.Fatalf("an account card under a code brand: %d %s", status, raw)
	}
}

func TestCustomerOrderSentToAnAccount(t *testing.T) {
	h := newOrderHarness(t)
	supplier := newAccountSupplier()
	h.server.Vouchers.Suppliers[vouchers.SupplierFazer] = supplier
	// The harness published and read its own catalog already: this one comes a
	// minute later (two at one instant are told apart by their random ids), and
	// the cache starts afresh.
	h.clock.advance(time.Minute)
	h.server.VoucherCache = &VoucherCatalogCache{}
	publishAccountCatalog(t, &voucherHarness{server: h.server, store: h.store, now: h.clock.now})
	pricedAccountOffers(t, h.store, h.clock.now)
	token := h.customer("0911111111")

	// An app that cannot ask for an account is not shown the cards.
	_, old := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk", "", nil)
	if keys := brandKeys(t, old); len(keys) != 1 {
		t.Fatalf("an older app is shown %v", keys)
	}
	_, apk := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk&accounts=1", "", nil)
	if keys := brandKeys(t, apk); len(keys) != 3 {
		t.Fatalf("the APK is shown %v", keys)
	}

	order := sadadOrder("pubg-60", "11.00", "o-1", 1)
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, order); status != http.StatusBadRequest ||
		body["code"] != voucherCodeAccountRequired {
		t.Fatalf("no account: %d %v", status, body)
	}
	order["account"] = map[string]string{"player_id": "5123456789"}
	status, body := h.do(http.MethodPost, "/v1/customers/orders", token, order)
	created := orderOf(t, body)
	if status != http.StatusCreated || created["delivery"] != "account" || created["account"] != "5123456789" {
		t.Fatalf("create: %d %v", status, body)
	}
	if values, _ := created["account_values"].(map[string]any); len(values) != 1 || values["player_id"] != "5123456789" {
		t.Fatalf("account by field = %v", created["account_values"])
	}
	// The same key for another account is another order.
	other := sadadOrder("pubg-60", "11.00", "o-1", 1)
	other["account"] = map[string]string{"player_id": "999"}
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, other); status != http.StatusConflict {
		t.Fatalf("key reused for another account: %d %v", status, body)
	}
	id := created["id"].(string)
	status, body = h.do(http.MethodPost, "/v1/customers/orders/"+id+"/confirm", token, map[string]any{"otp": "111111"})
	confirmed := orderOf(t, body)
	if status != http.StatusOK || confirmed["status"] != "delivered" || len(confirmed["codes"].([]any)) != 0 ||
		confirmed["codes_pending"] != false {
		t.Fatalf("confirm: %d %v", status, body)
	}
	if sent := supplier.sent(); len(sent) != 1 || sent[0]["player_id"] != "5123456789" {
		t.Fatalf("sent %v", sent)
	}
	// The app follows its order itself: the supplier answers at once.
	if len(supplier.settled) != 1 || supplier.settled[0] {
		t.Fatalf("an app order let the supplier wait: %v", supplier.settled)
	}
	purchases, _ := h.store.ListVoucherPurchases(context.Background(), control.VoucherPurchaseFilter{Buyer: control.VoucherBuyerCustomers})
	if len(purchases) != 1 || purchases[0].Target != "51•••••789" {
		t.Fatalf("customer purchases = %+v", purchases)
	}

	status, check := h.do(http.MethodPost, "/v1/customers/accounts/check", token,
		map[string]any{"item": "pubg-60", "account": map[string]string{"player_id": "77"}})
	if status != http.StatusOK || check["name"] != "Sniper_77" {
		t.Fatalf("customer check: %d %v", status, check)
	}
}

func TestTheAppIsToldWhereAGameIsPlayed(t *testing.T) {
	h := newOrderHarness(t)
	h.clock.advance(time.Minute)
	h.server.VoucherCache = &VoucherCatalogCache{}
	steam := strings.Replace(accountCatalog, `"key": "pubg", "name": "ببجي موبايل", "category": "game_topup",`,
		`"key": "pubg", "name": "ببجي موبايل", "category": "game_topup", "platform": "steam",`, 1)
	body := []byte(`{"document": ` + steam + `, "actor": "ops", "note": "platform"}`)
	harness := &voucherHarness{server: h.server, store: h.store, now: h.clock.now}
	if status, published := harness.admin(t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json", body); status != http.StatusCreated {
		t.Fatalf("publish: %d %v", status, published)
	}
	pricedAccountOffers(t, h.store, h.clock.now)
	_, apk := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk&accounts=1", "", nil)
	for _, raw := range apk["brands"].([]any) {
		brand := raw.(map[string]any)
		if want := map[string]any{"pubg": "steam"}[brand["key"].(string)]; brand["platform"] != want {
			t.Errorf("%s platform = %v, want %v", brand["key"], brand["platform"], want)
		}
	}
}

func TestTheStoreBuildsSellOnlyWhatTheyMay(t *testing.T) {
	h := newOrderHarness(t)
	h.server.Vouchers.Suppliers[vouchers.SupplierFazer] = newAccountSupplier()
	h.clock.advance(time.Minute)
	h.server.VoucherCache = &VoucherCatalogCache{}
	publishAccountCatalog(t, &voucherHarness{server: h.server, store: h.store, now: h.clock.now})

	for _, channel := range []string{"ios", "play"} {
		_, catalog := h.do(http.MethodGet, "/v1/customers/catalog?channel="+channel+"&accounts=1", "", nil)
		if keys := brandKeys(t, catalog); len(keys) < 2 {
			t.Fatalf("%s is shown only %v: game top-ups are listed, bought on the website", channel, keys)
		}
		for _, raw := range catalog["brands"].([]any) {
			brand := raw.(map[string]any)
			if brand["key"] != "libyana" && brand["web_only"] != true {
				t.Fatalf("%s sells %v without the operator's choice", channel, brand["key"])
			}
		}
	}
	token := h.customer("0911111111")
	order := sadadOrder("pubg-60", "11.00", "o-play", 1)
	order["channel"] = "play"
	order["account"] = map[string]string{"player_id": "5123"}
	if status, body := h.do(http.MethodPost, "/v1/customers/orders", token, order); status != http.StatusNotFound {
		t.Fatalf("Play bought a game top-up: %d %v", status, body)
	}
}

func TestGooglePlaySellsWhatItsPolicyLeavesOpen(t *testing.T) {
	target := func(kind string) *vouchers.Target { return &vouchers.Target{Kind: kind} }
	cases := []struct {
		name string
		key  string
		cat  string
		kind string
		sell bool
	}{
		{name: "a phone recharge", key: "libyana", cat: "telecom", sell: true},
		{name: "a local TV card", key: "asaria", cat: "tv", sell: true},
		{name: "a learning card", key: "academia", cat: "services", sell: true},
		{name: "a gift card", key: "apple", cat: "gift_cards", sell: true},
		{name: "a console card", key: "playstation", cat: "gaming", sell: true},
		{name: "a game's prepaid code", key: "pubg", cat: "gaming", sell: true},
		{name: "a game key", key: "gta-v", cat: "game_keys", sell: true},
		{name: "a Steam gift", key: "palworld", cat: "steam_gifts", kind: vouchers.TargetSteamInvite, sell: true},
		{name: "a Steam wallet top-up", key: "steam-topup", cat: "game_topup", kind: vouchers.TargetSteam, sell: true},
		{name: "a top-up by player ID", key: "pubg-id", cat: "game_topup", kind: vouchers.TargetGameAccount},
		{name: "an app's coins", key: "bigo", cat: "apps_topup", kind: vouchers.TargetGameAccount},
		{name: "Telegram Stars", key: "tg-stars", cat: "apps_topup", kind: vouchers.TargetTelegram},
		{name: "a crypto exchange's card", key: "binance", cat: "gift_cards"},
		{name: "a prepaid payment card", key: "mastercard", cat: "gift_cards"},
	}
	config := CustomerConfig{}
	for _, tc := range cases {
		brand := shelfBrand{Key: tc.key, Category: tc.cat}
		if tc.kind != "" {
			brand.Target = target(tc.kind)
		}
		for mode, want := range map[string][2]bool{
			control.MobileGiftCardsWebOnly: {true, tc.sell},
			control.MobileGiftCardsHidden:  {tc.sell, tc.sell},
			control.MobileGiftCardsSell:    {true, true},
		} {
			if show, sell := config.shelf(CustomerChannelPlay, brand, mode); show != want[0] || sell != want[1] {
				t.Errorf("play, %s under %s: show %v sell %v, want %v", tc.name, mode, show, sell, want)
			}
		}
		// Apple's rule is its own: only the services sell there by default.
		wantIOS := tc.cat == "telecom"
		if _, sell := config.shelf(CustomerChannelIOS, brand, control.MobileGiftCardsWebOnly); sell != wantIOS {
			t.Errorf("ios, %s: sell %v, want %v", tc.name, sell, wantIOS)
		}
		for _, channel := range []string{CustomerChannelAPK, CustomerChannelWeb} {
			if show, sell := config.shelf(channel, brand, control.MobileGiftCardsHidden); !show || !sell {
				t.Errorf("%s, %s: show %v sell %v", channel, tc.name, show, sell)
			}
		}
	}

	// A list the operator gave for Play stands as written, both ways.
	listed := CustomerConfig{ChannelCategories: map[string][]string{CustomerChannelPlay: {"telecom", "game_topup"}}}
	byID := shelfBrand{Key: "pubg-id", Category: "game_topup", Target: target(vouchers.TargetGameAccount)}
	if _, sell := listed.shelf(CustomerChannelPlay, byID, control.MobileGiftCardsHidden); !sell {
		t.Error("a listed category did not sell on Play")
	}
	gift := shelfBrand{Key: "apple", Category: "gift_cards"}
	if show, sell := listed.shelf(CustomerChannelPlay, gift, control.MobileGiftCardsHidden); show || sell {
		t.Errorf("an unlisted category on Play: show %v sell %v", show, sell)
	}
}

func TestTheOperatorReadsTheFazerAccount(t *testing.T) {
	h := newVoucherHarness(t)
	if status, _ := h.admin(t, http.MethodGet, "/v1/vouchers/admin/fazer/account", "", nil); status != http.StatusServiceUnavailable {
		t.Fatalf("unconfigured: %d", status)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v2/balance":
			_, _ = io.WriteString(w, `{"ok":true,"balance":"12.5000","currency":"USD"}`)
		case "/api/v2/me":
			_, _ = io.WriteString(w, `{"ok":true,"login":"co","plan":"silver","planExpiresAt":"2026-12-02T00:00:00.000Z","subscriptionActive":true}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	h.server.Vouchers.Fazer = fazer.New(fazer.Config{BaseURL: server.URL, APIKey: "fc_test"})
	h.server.Vouchers.FazerSteamFeePercent = "3"
	status, body := h.admin(t, http.MethodGet, "/v1/vouchers/admin/fazer/account", "", nil)
	if status != http.StatusOK || body["balance"] != "12.5000" || body["plan"] != "silver" ||
		body["subscription_active"] != true || body["steam_fee_percent"] != "3" {
		t.Fatalf("account: %d %v", status, body)
	}
	if _, config := h.admin(t, http.MethodGet, "/v1/vouchers/admin/config", "", nil); config["fazer"] != true ||
		config["fazer_steam_fee_percent"] != "3" {
		t.Fatalf("config: %v", config)
	}
}

func TestTheOperatorChecksAnAccount(t *testing.T) {
	h, _ := newAccountHarness(t)
	status, body := h.admin(t, http.MethodPost, "/v1/vouchers/admin/accounts/check", "application/json",
		[]byte(`{"item": "pubg-60", "account": {"player_id": "88"}}`))
	if status != http.StatusOK || body["name"] != "Sniper_88" || body["status"] != vouchers.AccountValid {
		t.Fatalf("admin check: %d %v", status, body)
	}
}

// A till that follows the order by itself says so, and a slow supplier answers
// as soon as it has taken the order; any other shop still gets the short wait.
func TestAShopThatFollowsTheOrderIsNotWaitedFor(t *testing.T) {
	for _, follows := range []bool{true, false} {
		h, supplier := newAccountHarness(t)
		shop := h.provision(t)
		h.fundVouchers(t, shop.AccessToken, shop.Installation.ID, "100")
		request := purchaseRequest("pubg-60", "follow-1", "9.00")
		request["account"] = map[string]string{"player_id": "5123456789"}
		if follows {
			request["no_wait"] = true
		}
		if status, body := h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shop.AccessToken, request); status != http.StatusCreated {
			t.Fatalf("buy: %d %v", status, body)
		}
		if len(supplier.settled) != 1 || supplier.settled[0] == follows {
			t.Fatalf("no_wait %v: supplier may settle %v", follows, supplier.settled)
		}
	}
}
