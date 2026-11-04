package fazer

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptrace"
	"os"
	"strings"
	"testing"
	"time"
)

// The live tests talk to FazerCards' real API with the company's key. They are
// skipped unless it is set:
//
//	FAZER_LIVE_API_KEY=fc_… go test ./internal/fazer -run Live -v
//
// TestLiveReads only reads (catalog, balance, a Steam gift's prices, a player
// and a login check).
// TestLiveOrderRefusedWithoutBalance places one order of the cheapest code
// there is (an Amazon Egypt 1 EGP card, about $0.02) and runs only while the
// balance is zero, so it can never spend: it proves how a refusal reads.
// TestLiveOrderCompletes SPENDS: it buys that same card once, and runs only
// when FAZER_LIVE_SPEND=1 is set as well. It logs the order as the API writes
// it, codes masked, so the shapes ParseOrder reads can be checked.
// TestLiveReadOrder only reads: it reads back FAZER_LIVE_ORDER_ID and says how
// long it has taken.

func liveClient(t *testing.T) *Client {
	t.Helper()
	key := strings.TrimSpace(os.Getenv("FAZER_LIVE_API_KEY"))
	if key == "" {
		t.Skip("set FAZER_LIVE_API_KEY to run the live tests")
	}
	return New(Config{APIKey: key, Timeout: 30 * time.Second})
}

func TestLiveReads(t *testing.T) {
	client := liveClient(t)
	ctx := context.Background()

	account, err := client.Me(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("account plan %q active %v until %s", account.Plan, account.SubscriptionActive, account.PlanExpiresAt)
	balance, err := client.Balance(ctx)
	if err != nil || balance.Currency != "USD" {
		t.Fatalf("balance %+v %v", balance, err)
	}

	pubg, err := client.TopupOffers(ctx, "pubg_mobile_auto")
	if err != nil || len(pubg.Offers) == 0 || len(pubg.Fields) == 0 || pubg.Fields[0].Key != "player_id" {
		t.Fatalf("pubg offers %+v %v", pubg, err)
	}
	genshin, err := client.TopupOffers(ctx, "genshin_impact_global")
	if err != nil || len(genshin.Fields) < 2 || genshin.Fields[1].Type != "select" || len(genshin.Fields[1].Options) == 0 {
		t.Fatalf("a select field must read with its options: %+v %v", genshin.Fields, err)
	}
	cards, err := client.GiftCards(ctx, "app_store_itunes_us")
	if err != nil || len(cards.Offers) == 0 || cards.Offers[0].PriceUSD == "" {
		t.Fatalf("gift cards %+v %v", cards, err)
	}
	games, err := client.Games(ctx)
	if err != nil || len(games) == 0 {
		t.Fatalf("games %d %v", len(games), err)
	}
	stars, err := client.TelegramStars(ctx)
	if err != nil || stars.PricePerStar == "" || stars.Min != 50 {
		t.Fatalf("stars %+v %v", stars, err)
	}
	plans, err := client.TelegramPremium(ctx)
	if err != nil || len(plans) != 3 {
		t.Fatalf("premium %+v %v", plans, err)
	}
	gift, err := client.SteamGiftOffers(ctx, "1245620") // ELDEN RING
	if err != nil || len(gift.Editions) == 0 || gift.Editions[0].Prices["MENA"] == "" {
		t.Fatalf("a Steam gift must read with its MENA price: %+v %v", gift, err)
	}
	rates, err := client.SteamRates(ctx)
	if err != nil || rates.Rates["USD"] == "" {
		t.Fatalf("steam rates %+v %v", rates, err)
	}

	// A player ID nobody has: the game says invalid, or cannot confirm it.
	player, err := client.CheckPlayer(ctx, "pubg_mobile", map[string]string{"player_id": "1"})
	switch {
	case errors.Is(err, ErrUnconfirmed):
		t.Log("pubg player 1: unconfirmed (422)")
	case err != nil:
		t.Fatalf("player check: %v", err)
	default:
		t.Logf("pubg player 1: valid=%v name=%q region=%q", player.Valid, player.PlayerName, player.Region)
	}
	login, err := client.CheckSteamLogin(ctx, "pointy_no_such_login_42")
	if err != nil {
		t.Fatalf("steam login check: %v", err)
	}
	t.Logf("steam login check: can_refill=%v unverified=%v", login.CanRefill, login.Unverified)
}

func TestLiveOrderRefusedWithoutBalance(t *testing.T) {
	client := liveClient(t)
	ctx := context.Background()
	balance, err := client.Balance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Trim(strings.ReplaceAll(balance.Amount, ".", ""), "0") != "" {
		t.Skipf("the balance is %s: this test only runs while it is zero, so it never buys", balance.Amount)
	}
	_, err = client.OrderGiftCards(ctx, "amazon_eg", "1_egp", 1, "pointy-live-refusal-"+time.Now().UTC().Format("20060102"))
	var api *APIError
	if !errors.As(err, &api) || !IsInsufficientBalance(err) || !Definite(err) {
		t.Fatalf("an order without balance must be a definite insufficient balance: %v", err)
	}
	t.Logf("refusal: HTTP %d code=%q message=%q", api.Status, api.Code, api.Message)
	orders, total, err := client.Orders(ctx, 1, 5)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("order history after the refusal: %d orders (total %d)", len(orders), total)
}

func TestLiveOrderCompletes(t *testing.T) {
	client := liveClient(t)
	if os.Getenv("FAZER_LIVE_SPEND") != "1" {
		t.Skip("set FAZER_LIVE_SPEND=1 as well: this test buys one Amazon Egypt 1 EGP card (about $0.02)")
	}
	ctx := context.Background()
	before, err := client.Balance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("balance before: %s %s", before.Amount, before.Currency)

	key := "pointy-live-order-" + time.Now().UTC().Format("20060102T150405")
	order, err := client.OrderGiftCards(ctx, "amazon_eg", "1_egp", 1, key)
	if err != nil {
		t.Fatalf("order: %v", err)
	}
	t.Logf("placed: id=%q status=%q cost=%q key=%q codes=%d", order.ID, order.RawStatus, order.CostUSD, order.IdempotencyKey, len(order.Codes))
	t.Logf("placed, raw: %s", maskCodes(order.Raw))

	for deadline := time.Now().Add(4 * time.Minute); order.Status == StatusProcessing && order.ID != "" && time.Now().Before(deadline); {
		time.Sleep(3 * time.Second)
		if order, err = client.Order(ctx, order.ID); err != nil {
			t.Fatalf("read back: %v", err)
		}
	}
	t.Logf("settled: id=%q status=%q cost=%q key=%q codes=%d", order.ID, order.RawStatus, order.CostUSD, order.IdempotencyKey, len(order.Codes))
	t.Logf("settled, raw: %s", maskCodes(order.Raw))

	orders, total, err := client.Orders(ctx, 1, 5)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("history: %d orders (total %d)", len(orders), total)
	for _, listed := range orders {
		if listed.ID == order.ID {
			t.Logf("in history: status=%q cost=%q key=%q codes=%d", listed.RawStatus, listed.CostUSD, listed.IdempotencyKey, len(listed.Codes))
			t.Logf("in history, raw: %s", maskCodes(listed.Raw))
		}
	}
	after, err := client.Balance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("balance after: %s %s", after.Amount, after.Currency)

	if order.Status != StatusCompleted || len(order.Codes) != 1 || order.CostUSD == "" {
		t.Errorf("a completed code order must read as completed, with its one code and its cost: status %q, %d codes, cost %q",
			order.RawStatus, len(order.Codes), order.CostUSD)
	}
}

func TestLiveReadOrder(t *testing.T) {
	client := liveClient(t)
	id := strings.TrimSpace(os.Getenv("FAZER_LIVE_ORDER_ID"))
	if id == "" {
		t.Skip("set FAZER_LIVE_ORDER_ID to read one order back")
	}
	order, err := client.Order(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	var times struct {
		CompletedAt string `json:"completed_at"`
	}
	_ = json.Unmarshal(order.Raw, &times)
	end, finished := time.Now(), false
	if at, err := time.Parse(time.RFC3339Nano, times.CompletedAt); err == nil {
		end, finished = at, true
	}
	took := end.Sub(order.CreatedAt).Round(time.Second)
	if !finished {
		t.Logf("order %s: still %q after %s", order.ID, order.RawStatus, took)
	} else {
		t.Logf("order %s: %q after %s, cost %q, %d codes, reason %q", order.ID, order.RawStatus, took, order.CostUSD, len(order.Codes), order.Message)
	}
	t.Logf("raw: %s", maskCodes(order.Raw))
}

// maskCodes rewrites an order's JSON with every secret replaced by its length.
func maskCodes(raw json.RawMessage) string {
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return "<unreadable>"
	}
	secret := map[string]bool{"cards": true, "gamekeys": true, "game_keys": true, "giftcards": true, "gift_cards": true,
		"code": true, "codes": true, "key": true, "keys": true, "pin": true, "pin_code": true,
		"pincode": true, "password": true, "secret": true, "cdk": true, "card_number": true, "cardnumber": true,
		"activation_key": true, "activationkey": true, "serial": true, "serial_number": true, "serialnumber": true,
		"value": true, "redeem_url": true, "redeemurl": true, "redemption_url": true, "url": true, "link": true}
	var walk func(any, bool) any
	walk = func(node any, hide bool) any {
		switch v := node.(type) {
		case map[string]any:
			for k, child := range v {
				v[k] = walk(child, hide || secret[strings.ToLower(k)])
			}
		case []any:
			for i, child := range v {
				v[i] = walk(child, hide)
			}
		case string:
			if hide && v != "" {
				return fmt.Sprintf("<masked %d chars>", len(v))
			}
		}
		return node
	}
	masked, _ := json.Marshal(walk(value, false))
	return string(masked)
}

// TestLiveLatency only reads: it times the calls a top-up makes (the balance,
// a player check) on a fresh connection and again on the warm one, split into
// DNS, connect, TLS and the API's own wait, so the relay's side of the time
// can be told from FazerCards'.
func TestLiveLatency(t *testing.T) {
	client := liveClient(t)
	ctx := context.Background()
	timed := func(name string, call func(context.Context) error) {
		var start, dnsAt, connectAt, tlsAt, wroteAt, firstByte time.Time
		var reused bool
		var proto string
		trace := &httptrace.ClientTrace{
			DNSDone:              func(httptrace.DNSDoneInfo) { dnsAt = time.Now() },
			ConnectDone:          func(string, string, error) { connectAt = time.Now() },
			TLSHandshakeDone:     func(state tls.ConnectionState, _ error) { tlsAt, proto = time.Now(), state.NegotiatedProtocol },
			GotConn:              func(info httptrace.GotConnInfo) { reused = info.Reused },
			WroteRequest:         func(httptrace.WroteRequestInfo) { wroteAt = time.Now() },
			GotFirstResponseByte: func() { firstByte = time.Now() },
		}
		start = time.Now()
		err := call(httptrace.WithClientTrace(ctx, trace))
		since := func(at time.Time) string {
			if at.IsZero() {
				return "-"
			}
			return at.Sub(start).Round(time.Millisecond).String()
		}
		t.Logf("%-14s total %-7s reused %-5v proto %-8q dns %-6s connect %-6s tls %-6s api %-7s err %v",
			name, time.Since(start).Round(time.Millisecond), reused, proto, since(dnsAt), since(connectAt), since(tlsAt),
			firstByte.Sub(wroteAt).Round(time.Millisecond), err != nil)
	}
	for i := 1; i <= 3; i++ {
		timed(fmt.Sprintf("balance #%d", i), func(ctx context.Context) error { _, err := client.Balance(ctx); return err })
	}
	for i := 1; i <= 3; i++ {
		timed(fmt.Sprintf("check #%d", i), func(ctx context.Context) error {
			_, err := client.CheckPlayer(ctx, "pubg_mobile", map[string]string{"player_id": "5123456789"})
			if errors.Is(err, ErrUnconfirmed) {
				return nil
			}
			return err
		})
	}
}

// TestLiveWebhook only reads: the account's webhook as FazerCards keeps it,
// and the shape of its secret (never the secret).
func TestLiveWebhook(t *testing.T) {
	client := liveClient(t)
	hook, set, err := client.Webhook(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("set %v url %q enabled %v failures %d last ok %q last failure %q (%q)",
		set, hook.URL, hook.Enabled, hook.ConsecutiveFailures, hook.LastSuccessAt, hook.LastFailureAt, hook.LastFailureReason)
	secret, err := client.WebhookSecret(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	shape := "other"
	switch {
	case secret == "":
		shape = "none"
	case strings.Trim(strings.ToLower(secret), "0123456789abcdef") == "":
		shape = "hex"
	case strings.Trim(secret, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=-_") == "":
		shape = "base64 or token"
	}
	prefix := ""
	if i := strings.IndexAny(secret, "_-"); i > 0 && i < 8 {
		prefix = secret[:i+1]
	}
	t.Logf("secret: %d characters, %s, prefix %q", len(secret), shape, prefix)
}
