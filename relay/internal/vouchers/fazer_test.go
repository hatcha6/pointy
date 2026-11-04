package vouchers

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/fazer"
)

// fakeFazer answers like FazerCards' public API.
type fakeFazer struct {
	mu       sync.Mutex
	orders   map[string]map[string]any
	posted   []map[string]any
	keys     []string
	reads    int
	settleAt int // completed after this many reads
	refund   bool
	checks   int // player checks asked
	balances int // balance reads
}

func newFakeFazer(t *testing.T) (*fakeFazer, *fazer.Client) {
	t.Helper()
	fake := &fakeFazer{orders: map[string]map[string]any{}}
	server := httptest.NewServer(http.HandlerFunc(fake.serve))
	t.Cleanup(server.Close)
	return fake, fazer.New(fazer.Config{BaseURL: server.URL, APIKey: "fc_test", RetryBackoff: time.Millisecond})
}

func (f *fakeFazer) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	write := func(body any) { _ = json.NewEncoder(w).Encode(body) }
	path := strings.TrimPrefix(r.URL.Path, "/api/v2")
	switch {
	case r.Method == http.MethodPost && (path == "/giftcards/order" || path == "/topups/order" || path == "/telegram/stars/buy" ||
		path == "/steam-gifts/order"):
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.posted = append(f.posted, body)
		f.keys = append(f.keys, r.Header.Get("Idempotency-Key"))
		id := "ord-" + string(rune('0'+len(f.posted)))
		order := map[string]any{"id": id, "status": "processing", "price_usd": "9.8648",
			"idempotency_key": r.Header.Get("Idempotency-Key"), "createdAt": "2026-11-02T10:00:00.000Z"}
		f.orders[id] = order
		w.WriteHeader(http.StatusCreated)
		write(map[string]any{"ok": true, "order": order})
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/orders/"):
		f.reads++
		order := f.orders[strings.TrimPrefix(path, "/orders/")]
		if order == nil {
			w.WriteHeader(http.StatusNotFound)
			write(map[string]any{"ok": false, "error": "Order not found"})
			return
		}
		if f.reads >= f.settleAt {
			if f.refund {
				order["status"] = "refunded"
			} else {
				order["status"] = "completed"
				if _, gift := order["giftcard"]; gift || order["price_usd"] != nil {
					order["cards"] = []map[string]string{{"code": "AAAA-BBBB", "pin": "1234"}}
				}
			}
		}
		write(map[string]any{"ok": true, "order": order})
	case r.Method == http.MethodGet && path == "/orders":
		items := []map[string]any{}
		for _, order := range f.orders {
			items = append(items, order)
		}
		write(map[string]any{"ok": true, "items": items, "total": len(items), "page": 1, "limit": 100})
	case r.Method == http.MethodGet && path == "/giftcards/cards":
		write(map[string]any{"ok": true, "kind": "gift_card", "category_id": r.URL.Query().Get("category_id"), "name": "App Store (US)",
			"offers": []map[string]any{
				{"card_id": "c10", "name": "10 USD", "price_usd": "9.8648", "stock": 12},
				{"card_id": "c25", "name": "25 USD", "price_usd": "24.1", "stock": 0},
			}})
	case r.Method == http.MethodGet && path == "/steam-gifts/games/1245620":
		write(map[string]any{"ok": true, "appid": 1245620, "offers": []map[string]any{
			{"sub_id": 440408, "name": "ELDEN RING", "regions": []map[string]any{
				{"region": "MENA", "price": "38.1441"}, {"region": "US", "price": "53.4776"}}},
			{"sub_id": 440410, "name": "ELDEN RING", "regions": []map[string]any{{"region": "JP", "price": "59.7302"}}},
		}})
	case r.Method == http.MethodGet && path == "/telegram/stars":
		write(map[string]any{"ok": true, "price_per_star": "0.0152625", "min_amount": 50, "max_amount": 100000})
	case r.Method == http.MethodGet && path == "/telegram/premium":
		write(map[string]any{"ok": true, "plans": []map[string]any{{"months": 3, "price_usd": "12.1999"}}})
	case r.Method == http.MethodGet && path == "/balance":
		f.balances++
		write(map[string]any{"ok": true, "balance": "250.5000", "currency": "USD"})
	case r.Method == http.MethodPost && path == "/topups/validate-id":
		f.checks++
		var body struct {
			Fields map[string]string `json:"fields"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Fields["player_id"] == "0" {
			w.WriteHeader(http.StatusUnprocessableEntity)
			write(map[string]any{"ok": false, "error": "could not confirm"})
			return
		}
		write(map[string]any{"ok": true, "valid": body.Fields["player_id"] != "404", "player_name": "Sniper", "region": "EUROPE"})
	default:
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"ok":false,"error":"no route"}`)
	}
}

func instantSupplier(client *fazer.Client) *FazerSupplier {
	return &FazerSupplier{Client: client, sleep: func(context.Context, time.Duration) bool { return true }}
}

func fazerRefOf(t *testing.T, block string) Ref {
	t.Helper()
	ref, err := ParseRef(json.RawMessage(block))
	if err != nil {
		t.Fatalf("%s: %v", block, err)
	}
	return ref
}

func TestFazerRefs(t *testing.T) {
	cases := map[string]string{
		`{"key": "fazer", "product": "giftcard", "category": "app_store_itunes_us", "offer": "c10"}`:      "giftcard/app_store_itunes_us/c10",
		`{"key": "fazer", "product": "topup", "category": "pubg_mobile_auto", "offer": "60 UC/x"}`:        "topup/pubg_mobile_auto/60%20UC%2Fx",
		`{"key": "fazer", "product": "stars", "quantity": 500}`:                                           "stars/500",
		`{"key": "fazer", "product": "premium", "months": 6}`:                                             "premium/6",
		`{"key": "fazer", "product": "steam", "currency": "usd", "amount": "10.50"}`:                      "steam/USD/10.5",
		`{"key": "fazer", "product": "steamgift", "app_id": 1245620, "sub_id": 440408, "region": "mena"}`: "steamgift/1245620/440408/MENA",
	}
	for block, want := range cases {
		ref := fazerRefOf(t, block)
		if ref.ID != want {
			t.Errorf("%s: ID = %q, want %q", block, ref.ID, want)
		}
		parsed, err := parseFazerRefID(ref.ID)
		if err != nil || parsed.id() != ref.ID {
			t.Errorf("%s: round trip %+v %v", block, parsed, err)
		}
	}
	for _, bad := range []string{
		`{"key": "fazer", "product": "stars", "quantity": 10}`,
		`{"key": "fazer", "product": "premium", "months": 2}`,
		`{"key": "fazer", "product": "steam", "currency": "RUB", "amount": "100"}`,
		`{"key": "fazer", "product": "topup", "category": "pubg"}`,
		`{"key": "fazer", "product": "vpn"}`,
		`{"key": "fazer", "product": "steamgift", "app_id": 1245620, "region": "MENA"}`,
		`{"key": "fazer", "product": "steamgift", "app_id": 1245620, "sub_id": 440408, "region": "Middle East"}`,
	} {
		if _, err := ParseRef(json.RawMessage(bad)); err == nil {
			t.Errorf("%s was accepted", bad)
		}
	}
	if !RefNeedsAccount(fazerRefOf(t, `{"key": "fazer", "product": "stars", "quantity": 50}`)) ||
		!RefNeedsAccount(fazerRefOf(t, `{"key": "fazer", "product": "steamgift", "app_id": 1, "sub_id": 2, "region": "MENA"}`)) ||
		RefNeedsAccount(fazerRefOf(t, `{"key": "fazer", "product": "giftcard", "category": "a", "offer": "b"}`)) {
		t.Fatal("RefNeedsAccount")
	}
}

func TestFazerBuysCodesWithItsKeyAndWaitsForThem(t *testing.T) {
	fake, client := newFakeFazer(t)
	fake.settleAt = 2
	supplier := instantSupplier(client)
	ref := fazerRefOf(t, `{"key": "fazer", "product": "giftcard", "category": "app_store_itunes_us", "offer": "c10"}`)
	purchase, err := supplier.Buy(context.Background(), ref, 1, "vp_1")
	if err != nil {
		t.Fatal(err)
	}
	if purchase.Status != StatusSucceeded || len(purchase.Codes) != 1 || purchase.Codes[0] != (Code{Code: "AAAA-BBBB", Serial: "1234"}) ||
		purchase.Cost != "9.8648" || purchase.Currency != "USD" {
		t.Fatalf("purchase = %+v", purchase)
	}
	if fake.keys[0] != "vp_1" || fake.posted[0]["card_id"] != "c10" || fake.posted[0]["quantity"] != float64(1) {
		t.Fatalf("posted %v with keys %v", fake.posted, fake.keys)
	}
	// An account card is never bought as a code.
	stars := fazerRefOf(t, `{"key": "fazer", "product": "stars", "quantity": 100}`)
	var failure *Failure
	if _, err := supplier.Buy(context.Background(), stars, 1, "vp_2"); !errors.As(err, &failure) || !failure.Definite {
		t.Fatalf("stars bought as a code: %v", err)
	}
	if len(fake.posted) != 1 {
		t.Fatal("something was sent")
	}
}

func TestFazerTopsUpAnAccount(t *testing.T) {
	fake, client := newFakeFazer(t)
	supplier := instantSupplier(client)
	ref := fazerRefOf(t, `{"key": "fazer", "product": "topup", "category": "pubg_mobile_auto", "offer": "60"}`)
	purchase, err := supplier.BuyFor(context.Background(), ref, Account{"player_id": "5123456789"}, "vp_3")
	if err != nil {
		t.Fatal(err)
	}
	if purchase.Status != StatusSucceeded || len(purchase.Codes) != 0 || purchase.OrderID == "" {
		t.Fatalf("top-up = %+v", purchase)
	}
	fields := fake.posted[0]["fields"].(map[string]any)
	if fake.posted[0]["category_id"] != "pubg_mobile_auto" || fake.posted[0]["offer_id"] != "60" || fields["player_id"] != "5123456789" {
		t.Fatalf("posted %v", fake.posted[0])
	}
	stars := fazerRefOf(t, `{"key": "fazer", "product": "stars", "quantity": 100}`)
	if _, err := supplier.BuyFor(context.Background(), stars, Account{"username": "daftar_ly"}, "vp_4"); err != nil {
		t.Fatal(err)
	}
	if fake.posted[1]["telegram_username"] != "daftar_ly" || fake.posted[1]["quantity"] != float64(100) || fake.keys[1] != "vp_4" {
		t.Fatalf("stars posted %v", fake.posted[1])
	}
}

func TestFazerRefundIsADefiniteFailure(t *testing.T) {
	fake, client := newFakeFazer(t)
	fake.refund = true
	supplier := instantSupplier(client)
	ref := fazerRefOf(t, `{"key": "fazer", "product": "topup", "category": "pubg_mobile_auto", "offer": "60"}`)
	_, err := supplier.BuyFor(context.Background(), ref, Account{"player_id": "1"}, "vp_5")
	var failure *Failure
	if !errors.As(err, &failure) || !failure.Definite || failure.OrderID == "" {
		t.Fatalf("refunded: %v", err)
	}
}

func TestFazerStillProcessingIsPendingWithItsOrder(t *testing.T) {
	fake, client := newFakeFazer(t)
	fake.settleAt = 1000
	now := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	supplier := &FazerSupplier{Client: client, nowFunc: func() time.Time { return now },
		sleep: func(context.Context, time.Duration) bool { now = now.Add(fazerSettlePause); return true }}
	ref := fazerRefOf(t, `{"key": "fazer", "product": "giftcard", "category": "app_store_itunes_us", "offer": "c10"}`)
	purchase, err := supplier.Buy(context.Background(), ref, 1, "vp_6")
	if err != nil || purchase.Status != StatusPending || purchase.OrderID == "" {
		t.Fatalf("purchase = %+v err=%v", purchase, err)
	}
	found, err := supplier.FindByClientRef(context.Background(), ref, "vp_6", time.Time{}, time.Time{})
	if err != nil || len(found) != 1 || found[0].OrderID != purchase.OrderID {
		t.Fatalf("found = %+v err=%v", found, err)
	}
	if none, err := supplier.FindByClientRef(context.Background(), ref, "vp_other", time.Time{}, time.Time{}); err != nil || len(none) != 0 {
		t.Fatalf("an unknown key: %+v %v", none, err)
	}
}

func TestFazerSendsASteamGift(t *testing.T) {
	fake, client := newFakeFazer(t)
	supplier := instantSupplier(client)
	ref := fazerRefOf(t, `{"key": "fazer", "product": "steamgift", "app_id": 1245620, "sub_id": 440408, "region": "MENA"}`)
	purchase, err := supplier.BuyFor(context.Background(), ref, Account{"invite_url": "https://s.team/p/gkcp-mvn/CWQDTMJF"}, "vp_9")
	if err != nil {
		t.Fatal(err)
	}
	if purchase.Status != StatusSucceeded || len(purchase.Codes) != 0 || fake.keys[0] != "vp_9" {
		t.Fatalf("gift = %+v", purchase)
	}
	posted := fake.posted[0]
	if posted["invite_url"] != "https://s.team/p/gkcp-mvn/CWQDTMJF" || posted["app_id"] != float64(1245620) ||
		posted["sub_id"] != float64(440408) || posted["region"] != "MENA" {
		t.Fatalf("posted %v", posted)
	}
	if _, err := supplier.Buy(context.Background(), ref, 1, "vp_10"); err == nil || len(fake.posted) != 1 {
		t.Fatal("a gift is sent to an account, never bought as a code")
	}

	offers, err := supplier.OffersFor(context.Background(), []Ref{
		ref,
		fazerRefOf(t, `{"key": "fazer", "product": "steamgift", "app_id": 1245620, "sub_id": 440410, "region": "MENA"}`),
		fazerRefOf(t, `{"key": "fazer", "product": "steamgift", "app_id": 1245620, "sub_id": 1, "region": "MENA"}`),
		fazerRefOf(t, `{"key": "fazer", "product": "steamgift", "app_id": 7, "sub_id": 1, "region": "MENA"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(offers) != 2 || offers[0].Price != "38.1441" || !offers[0].InStock || offers[0].Name != "ELDEN RING" ||
		offers[1].Ref != "steamgift/1245620/440410/MENA" || offers[1].InStock {
		// The Japanese edition is not sold in MENA; an edition or a game no
		// longer listed is no offer at all.
		t.Fatalf("gift offers = %+v", offers)
	}
}

func TestFazerOffers(t *testing.T) {
	_, client := newFakeFazer(t)
	supplier := instantSupplier(client)
	refs := []Ref{
		fazerRefOf(t, `{"key": "fazer", "product": "giftcard", "category": "app_store_itunes_us", "offer": "c10"}`),
		fazerRefOf(t, `{"key": "fazer", "product": "giftcard", "category": "app_store_itunes_us", "offer": "c25"}`),
		fazerRefOf(t, `{"key": "fazer", "product": "giftcard", "category": "app_store_itunes_us", "offer": "gone"}`),
		fazerRefOf(t, `{"key": "fazer", "product": "stars", "quantity": 100}`),
		fazerRefOf(t, `{"key": "fazer", "product": "premium", "months": 3}`),
		fazerRefOf(t, `{"key": "fazer", "product": "steam", "currency": "USD", "amount": "10"}`),
	}
	offers, err := supplier.OffersFor(context.Background(), refs)
	if err != nil {
		t.Fatal(err)
	}
	byRef := map[string]Offer{}
	for _, offer := range offers {
		byRef[offer.Ref] = offer
	}
	check := func(ref, price string, inStock bool) {
		t.Helper()
		offer, ok := byRef[ref]
		if !ok || offer.Price != price || offer.InStock != inStock || offer.Currency != "USD" {
			t.Errorf("%s = %+v (present %v), want %s in stock %v", ref, offer, ok, price, inStock)
		}
	}
	check("giftcard/app_store_itunes_us/c10", "9.8648", true)
	check("giftcard/app_store_itunes_us/c25", "24.1000", false)
	check("stars/100", "1.53", true)
	check("premium/3", "12.1999", true)
	check("steam/USD/10", "0", false) // the plan's Steam fee is not known
	if _, ok := byRef["giftcard/app_store_itunes_us/gone"]; ok {
		t.Error("an offer FazerCards no longer lists is not an offer")
	}
	if balance, currency, _, ok := supplier.LastBalance(); !ok || currency != "USD" || balance.FloatString(2) != "250.50" {
		t.Errorf("balance = %v %s %v", balance, currency, ok)
	}

	supplier.SteamFeePercent = "3"
	supplier.mu.Lock()
	supplier.giftcards = nil
	supplier.mu.Unlock()
	offers, _ = supplier.OffersFor(context.Background(), refs[5:])
	if len(offers) != 1 || offers[0].Price != "10.30" || !offers[0].InStock {
		t.Fatalf("steam with its fee = %+v", offers)
	}
}

func TestFazerChecksAPlayer(t *testing.T) {
	_, client := newFakeFazer(t)
	supplier := instantSupplier(client)
	ref := fazerRefOf(t, `{"key": "fazer", "product": "topup", "category": "pubg_mobile_auto", "offer": "60"}`)
	target := Target{Kind: TargetGameAccount, Check: "pubg_mobile", Fields: []TargetField{{Key: "player_id", Label: "ID"}}}
	for id, want := range map[string]string{"5123": AccountValid, "404": AccountInvalid, "0": AccountUnconfirmed} {
		check, err := supplier.CheckAccount(context.Background(), ref, target, Account{"player_id": id})
		if err != nil || check.Status != want {
			t.Errorf("%s: %+v %v, want %s", id, check, err, want)
		}
	}
	if check, _ := supplier.CheckAccount(context.Background(), ref, Target{Kind: TargetGameAccount}, Account{"player_id": "1"}); check.Status != AccountUnchecked {
		t.Errorf("a game with no check: %+v", check)
	}
}

func TestTargetReadsAndMasksAccounts(t *testing.T) {
	game := Target{Kind: TargetGameAccount, Fields: []TargetField{
		{Key: "user_id", Label: "ID"},
		{Key: "server", Label: "Server", Type: "select", Options: []TargetOption{{Value: "1001", Label: "Asia"}}},
	}}
	account, err := game.ReadAccount(map[string]string{"user_id": " 5123456789 ", "server": "1001"})
	if err != nil || game.Line(account) != "5123456789 · 1001" || game.MaskAccount(account) != "51•••••789 · 1•••" {
		t.Fatalf("game account %v %v %q %q", account, err, game.Line(account), game.MaskAccount(account))
	}
	var problem *AccountProblem
	if _, err := game.ReadAccount(map[string]string{"user_id": "1", "server": "9"}); !errors.As(err, &problem) || problem.Field != "server" {
		t.Fatalf("a choice not offered: %v", err)
	}
	if _, err := game.ReadAccount(nil); !errors.Is(err, ErrAccountRequired) {
		t.Fatalf("nothing typed: %v", err)
	}
	steam := Target{Kind: TargetSteam, Fields: []TargetField{{Key: "login", Label: "Login"}}}
	if _, err := steam.ReadAccount(map[string]string{"login": "name@mail.com"}); err == nil {
		t.Fatal("an e-mail is not a Steam login")
	}
	invite := Target{Kind: TargetSteamInvite, Fields: []TargetField{{Key: "invite_url", Label: "Link"}}}
	for typed, want := range map[string]string{
		"https://s.team/p/gkcp-mvn/CWQDTMJF": "https://s.team/p/gkcp-mvn/CWQDTMJF",
		" s.team/p/GKCP-MVN/CWQDTMJF/ ":      "https://s.team/p/gkcp-mvn/CWQDTMJF",
		"http://S.TEAM/p/gkcp-mvn/CWQDTMJF":  "https://s.team/p/gkcp-mvn/CWQDTMJF",
	} {
		account, err := invite.ReadAccount(map[string]string{"invite_url": typed})
		if err != nil || account["invite_url"] != want || invite.MaskAccount(account) != "s.team/p/gk••••vn" {
			t.Errorf("%q: %v %v %q", typed, account, err, invite.MaskAccount(account))
		}
	}
	for _, bad := range []string{"gkcp-mvn", "https://steamcommunity.com/id/someone", "https://s.team.evil.com/p/gkcp-mvn/X"} {
		if _, err := invite.ReadAccount(map[string]string{"invite_url": bad}); err == nil {
			t.Errorf("%q is not an invite link", bad)
		}
	}
}

func TestCatalogValidatesTargets(t *testing.T) {
	problems := Problems{}
	add := func(path, format string, args ...any) { problems = append(problems, Problem{Path: path}) }
	Target{Kind: "phone"}.validate(add, "target")
	Target{Kind: TargetTelegram, Fields: []TargetField{{Key: "a", Label: "A"}, {Key: "b", Label: "B"}}}.validate(add, "target")
	Target{Kind: TargetGameAccount, Fields: []TargetField{{Key: "Player ID", Label: "x"}}}.validate(add, "target")
	Target{Kind: TargetGameAccount, Fields: []TargetField{{Key: "zone", Label: "Zone", Type: "select"}}}.validate(add, "target")
	Target{Kind: TargetSteamInvite, Fields: []TargetField{{Key: "invite_url", Label: "Link"}}}.validate(add, "target")
	if len(problems) != 4 {
		t.Fatalf("problems = %+v", problems)
	}
}

func TestFazerAnAppOrderIsNotWaitedFor(t *testing.T) {
	fake, client := newFakeFazer(t)
	fake.settleAt = 1000
	waited := 0
	supplier := &FazerSupplier{Client: client,
		sleep: func(context.Context, time.Duration) bool { waited++; return true }}
	ref := fazerRefOf(t, `{"key": "fazer", "product": "topup", "category": "pubg_mobile_auto", "offer": "60"}`)
	purchase, err := supplier.BuyFor(WithoutSettling(context.Background()), ref, Account{"player_id": "5123"}, "vp_9")
	if err != nil || purchase.Status != StatusPending || purchase.OrderID == "" {
		t.Fatalf("purchase = %+v err=%v", purchase, err)
	}
	if waited != 0 || fake.reads != 0 {
		t.Fatalf("an order the app follows was waited for: %d pauses, %d reads", waited, fake.reads)
	}
	// A shop's purchase still waits for its codes as before.
	if _, err := supplier.Buy(context.Background(), fazerRefOf(t,
		`{"key": "fazer", "product": "giftcard", "category": "app_store_itunes_us", "offer": "c10"}`), 1, "vp_10"); err != nil {
		t.Fatal(err)
	}
	if waited == 0 || fake.reads == 0 {
		t.Fatalf("a shop's purchase was not waited for: %d pauses, %d reads", waited, fake.reads)
	}
}

func TestFazerAccountChecksAreReused(t *testing.T) {
	fake, client := newFakeFazer(t)
	now := time.Date(2026, 11, 3, 10, 0, 0, 0, time.UTC)
	supplier := &FazerSupplier{Client: client, nowFunc: func() time.Time { return now },
		sleep: func(context.Context, time.Duration) bool { return true }}
	ref := fazerRefOf(t, `{"key": "fazer", "product": "topup", "category": "pubg_mobile_auto", "offer": "60"}`)
	target := Target{Kind: TargetGameAccount, Check: "pubg_mobile", Fields: []TargetField{{Key: "player_id", Label: "ID"}}}
	check := func(id string) AccountCheck {
		t.Helper()
		answer, err := supplier.CheckAccount(context.Background(), ref, target, Account{"player_id": id})
		if err != nil {
			t.Fatal(err)
		}
		return answer
	}

	// Found: the brand page and the checkout ask once between them.
	if first, again := check("5123"), check("5123"); first.Name != "Sniper" || again.Name != "Sniper" || fake.checks != 1 {
		t.Fatalf("%+v %+v after %d checks", first, again, fake.checks)
	}
	// Not found: reused for a short while only.
	check("404")
	check("404")
	if fake.checks != 2 {
		t.Fatalf("a missing player was asked about %d times", fake.checks)
	}
	now = now.Add(fazerNotFoundTTL)
	if check("404").Status != AccountInvalid || fake.checks != 3 {
		t.Fatalf("a missing player was not asked about again after %s", fazerNotFoundTTL)
	}
	// Could not tell: never reused.
	check("0")
	check("0")
	if fake.checks != 5 {
		t.Fatalf("an unconfirmed check was reused (%d checks)", fake.checks)
	}
	// A found player is asked about again once its answer is old.
	now = now.Add(fazerFoundTTL)
	check("5123")
	if fake.checks != 6 {
		t.Fatalf("a found player's answer outlived %s", fazerFoundTTL)
	}
}

func TestFazerKeepsItsConnectionWarm(t *testing.T) {
	fake, client := newFakeFazer(t)
	ctx, cancel := context.WithCancel(context.Background())
	pauses := 0
	supplier := &FazerSupplier{Client: client, sleep: func(_ context.Context, every time.Duration) bool {
		if every != fazerWarmInterval {
			t.Errorf("warmed every %s", every)
		}
		pauses++
		if pauses == 3 {
			cancel()
			return false
		}
		return true
	}}
	supplier.KeepWarm(ctx, 0)
	if fake.balances != 3 {
		t.Fatalf("read the balance %d times", fake.balances)
	}
	if balance, _, _, ok := supplier.LastBalance(); !ok || balance.FloatString(2) != "250.50" {
		t.Fatalf("balance = %v %v", balance, ok)
	}
}
