package reloadly

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const balanceBody = `{"balance":993.81000,"frozenBalance":null,"currencyCode":"USD","currencyName":"US Dollar","updatedAt":"2026-10-08 05:42:10","lowBalanceThreshold":0.000000,"maxLowBalanceThreshold":0.000000}`

func TestNewValidatesConfig(t *testing.T) {
	for _, cfg := range []Config{
		{},
		{ClientID: "id"},
		{ClientSecret: "secret"},
		{ClientID: " ", ClientSecret: "secret"},
		{ClientID: "id", ClientSecret: "secret", TopupsURL: "ftp://example.com"},
		{ClientID: "id", ClientSecret: "secret", AuthURL: "not a url"},
	} {
		if _, err := New(cfg); err == nil {
			t.Errorf("New(%v) must fail", cfg)
		}
	}
	live, err := New(Config{ClientID: " id ", ClientSecret: " secret\n"})
	if err != nil {
		t.Fatal(err)
	}
	gift, topups, utilities := live.BaseURLs()
	if live.Sandbox() || gift != "https://giftcards.reloadly.com" || topups != "https://topups.reloadly.com" ||
		utilities != "https://utilities.reloadly.com" || live.authURL != "https://auth.reloadly.com" {
		t.Fatalf("live hosts: %v %v %v %v", gift, topups, utilities, live.authURL)
	}
	sandbox, err := New(Config{ClientID: "id", ClientSecret: "secret", Sandbox: true, UtilitiesURL: "http://127.0.0.1:1234/"})
	if err != nil {
		t.Fatal(err)
	}
	gift, topups, utilities = sandbox.BaseURLs()
	if !sandbox.Sandbox() || gift != "https://giftcards-sandbox.reloadly.com" ||
		topups != "https://topups-sandbox.reloadly.com" || utilities != "http://127.0.0.1:1234" ||
		sandbox.authURL != "https://auth.reloadly.com" {
		t.Fatalf("sandbox hosts: %v %v %v %v", gift, topups, utilities, sandbox.authURL)
	}
}

func TestConfigNeverPrintsTheSecret(t *testing.T) {
	cfg := Config{ClientID: "the-id", ClientSecret: "very-secret-value"}
	for _, text := range []string{fmt.Sprint(cfg), fmt.Sprintf("%v %+v %#v %s", cfg, cfg, cfg, cfg)} {
		if strings.Contains(text, "very-secret-value") || !strings.Contains(text, "the-id") {
			t.Fatalf("config printed as %q", text)
		}
	}
}

func TestListsArePagedFromOne(t *testing.T) {
	const total = 450
	f := newFake(t)
	var pages []int
	var mu sync.Mutex
	f.on("topups", func(c call) reply {
		values := parseQuery(c.query)
		page, _ := strconv.Atoi(values["page"])
		mu.Lock()
		pages = append(pages, page)
		mu.Unlock()
		if values["size"] != "200" {
			t.Errorf("size = %q", values["size"])
		}
		// Like Reloadly: page 0 is the first page, the same as page 1.
		number := max(page, 1) - 1
		var rows []string
		for i := number * 200; i < min((number+1)*200, total); i++ {
			rows = append(rows, fmt.Sprintf(`{"id":%d,"operatorId":%d,"name":"op %d"}`, i+1, i+1, i+1))
		}
		return ok(pageBody(rows, number, 3, true))
	})
	operators, err := f.client().Operators(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(operators) != total || operators[0].Key() != 1 || operators[total-1].Key() != total {
		t.Fatalf("got %d operators", len(operators))
	}
	if fmt.Sprint(pages) != "[1 2 3]" {
		t.Fatalf("pages asked = %v, want [1 2 3] (a loop from 0 reads page 1 twice and misses the last page)", pages)
	}
	query := parseQuery(f.callsTo("topups")[0].query)
	for _, flag := range []string{"includeBundles", "includeData", "includeCombo", "suggestedAmounts", "suggestedAmountsMap"} {
		if query[flag] != "true" {
			t.Errorf("operators query lacks %s=true: %v", flag, query)
		}
	}
}

func TestAListStopsWithoutLastAndOnRepeatedPages(t *testing.T) {
	f := newFake(t)
	// No "last", no "totalPages", and the server ignores "page": the same two
	// rows come back for ever.
	f.always("utilities", ok(`{"content":[{"id":1,"name":"a"},{"id":2,"name":"b"}]}`))
	billers, err := f.client().Billers(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(billers) != 2 {
		t.Fatalf("billers = %+v", billers)
	}
	if n := len(f.callsTo("utilities")); n != 2 {
		t.Fatalf("calls = %d, want the page and one page of repeats", n)
	}
	empty := newFake(t)
	empty.always("utilities", ok(`{"content":[],"totalPages":0,"last":true}`))
	billers, err = empty.client().Billers(context.Background())
	if err != nil || len(billers) != 0 || len(empty.callsTo("utilities")) != 1 {
		t.Fatalf("billers = %v, err = %v", billers, err)
	}
}

func TestPurchasesAreNeverRetried(t *testing.T) {
	purchases := map[string]struct {
		server string
		run    func(*Client) error
	}{
		"gift card": {"giftcards", func(c *Client) error {
			_, err := c.OrderGiftCard(context.Background(), validGiftOrder())
			return err
		}},
		"top-up": {"topups", func(c *Client) error {
			_, err := c.Topup(context.Background(), validTopup())
			return err
		}},
		"async top-up": {"topups", func(c *Client) error {
			_, err := c.TopupAsync(context.Background(), validTopup())
			return err
		}},
		"bill": {"utilities", func(c *Client) error {
			_, err := c.Pay(context.Background(), validPay())
			return err
		}},
	}
	for name, purchase := range purchases {
		for _, status := range []int{http.StatusBadGateway, http.StatusInternalServerError, http.StatusServiceUnavailable, http.StatusTooManyRequests} {
			t.Run(fmt.Sprintf("%s %d", name, status), func(t *testing.T) {
				f := newFake(t)
				f.always(purchase.server, fail(status, `<html>bad gateway</html>`))
				err := purchase.run(f.client())
				if err == nil {
					t.Fatal("a failing purchase must fail")
				}
				if n := len(f.callsTo(purchase.server)); n != 1 {
					t.Fatalf("the purchase was sent %d times", n)
				}
				var api *APIError
				if !errors.As(err, &api) || api.Status != status || !strings.Contains(api.Body, "bad gateway") {
					t.Fatalf("err = %#v", err)
				}
				if status != http.StatusTooManyRequests && Definite(err) {
					t.Fatal("a 5xx after the purchase was sent may have bought it")
				}
				if status == http.StatusTooManyRequests && (!Definite(err) || !errors.Is(err, ErrRateLimited)) {
					t.Fatal("a 429 is a refusal")
				}
			})
		}
	}
}

func TestReadsAreRetriedOnTransientFailures(t *testing.T) {
	f := newFake(t)
	var n atomic.Int32
	f.on("utilities", func(call) reply {
		switch n.Add(1) {
		case 1:
			return fail(http.StatusServiceUnavailable, "")
		case 2:
			return reply{status: http.StatusTooManyRequests, header: map[string]string{"Retry-After": "0"}}
		}
		return ok(fixture(t, "payment_successful.json"))
	})
	payment, err := f.client().Payment(context.Background(), 7507)
	if err != nil || payment.Transaction.ID != 7507 {
		t.Fatalf("payment = %+v, err = %v", payment, err)
	}
	if n.Load() != 3 {
		t.Fatalf("calls = %d, want 3", n.Load())
	}
	for _, status := range []int{http.StatusBadRequest, http.StatusNotFound, http.StatusConflict} {
		g := newFake(t)
		g.always("utilities", fail(status, `{"message":"no","errorCode":"X"}`))
		if _, err := g.client().Payment(context.Background(), 1); err == nil || len(g.callsTo("utilities")) != 1 {
			t.Fatalf("a %d was retried (%d calls)", status, len(g.callsTo("utilities")))
		}
	}
}

func TestATimeoutAfterSendingIsAnUnknownOutcome(t *testing.T) {
	f := newFake(t)
	f.always("giftcards", reply{status: 200, body: "{}", delay: 400 * time.Millisecond})
	c := f.client(func(cfg *Config) { cfg.PurchaseTimeout = 60 * time.Millisecond })
	_, err := c.OrderGiftCard(context.Background(), validGiftOrder())
	var transport *TransportError
	if !errors.As(err, &transport) || !transport.Sent || Definite(err) {
		t.Fatalf("err = %#v", err)
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("the timeout is not visible: %v", err)
	}
	if n := len(f.callsTo("giftcards")); n != 1 {
		t.Fatalf("the purchase was sent %d times", n)
	}
}

func TestAPurchaseThatNeverConnectedIsDefinite(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dead := "http://" + listener.Addr().String()
	_ = listener.Close()
	f := newFake(t)
	c := f.client(func(cfg *Config) { cfg.TopupsURL = dead; cfg.Timeout = time.Second })
	// The token service answers (for the dead host's audience too); the product
	// refuses the connection, so the request never left.
	_, err = c.Topup(context.Background(), validTopup())
	var transport *TransportError
	if !errors.As(err, &transport) || transport.Sent || transport.Product != "topups" {
		t.Fatalf("err = %#v", err)
	}
	if !Definite(err) {
		t.Fatal("a refused connection cannot have topped anything up")
	}
}

func TestACancelledContextIsDefinite(t *testing.T) {
	f := newFake(t)
	f.always("giftcards", ok("{}"))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := f.client().OrderGiftCard(ctx, validGiftOrder())
	if err == nil || !Definite(err) {
		t.Fatalf("err = %v", err)
	}
	if len(f.callsTo("giftcards")) != 0 {
		t.Fatal("a cancelled purchase reached Reloadly")
	}
}

func TestAnUnreadableSuccessIsAnUnknownOutcome(t *testing.T) {
	for name, body := range map[string]string{
		"truncated":        `{"transactionId": 79`,
		"html":             `<html>ok</html>`,
		"no transactionId": `{"status":"SUCCESSFUL"}`,
		"wrong type":       `{"transactionId":"abc"}`,
	} {
		t.Run(name, func(t *testing.T) {
			f := newFake(t)
			f.always("giftcards", ok(body))
			f.always("topups", ok(body))
			f.always("utilities", ok(body))
			c := f.client()
			ctx := context.Background()
			_, orderErr := c.OrderGiftCard(ctx, validGiftOrder())
			_, topupErr := c.Topup(ctx, validTopup())
			_, asyncErr := c.TopupAsync(ctx, validTopup())
			_, payErr := c.Pay(ctx, validPay())
			for label, err := range map[string]error{"order": orderErr, "top-up": topupErr, "async": asyncErr, "pay": payErr} {
				var transport *TransportError
				if !errors.As(err, &transport) || !transport.Sent || Definite(err) {
					t.Errorf("%s: err = %#v, want an unknown outcome", label, err)
				}
			}
		})
	}
}

func TestMaxConcurrentLimitsCallsInFlight(t *testing.T) {
	f := newFake(t)
	var inFlight, peak atomic.Int32
	f.on("giftcards", func(call) reply {
		now := inFlight.Add(1)
		for {
			seen := peak.Load()
			if now <= seen || peak.CompareAndSwap(seen, now) {
				break
			}
		}
		time.Sleep(30 * time.Millisecond)
		inFlight.Add(-1)
		return ok(balanceBody)
	})
	c := f.client(func(cfg *Config) { cfg.MaxConcurrent = 2 })
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := c.GiftBalance(context.Background()); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if peak.Load() > 2 {
		t.Fatalf("%d calls were in flight, the limit is 2", peak.Load())
	}
}

func parseQuery(raw string) map[string]string {
	out := map[string]string{}
	for _, part := range strings.Split(raw, "&") {
		if part == "" {
			continue
		}
		key, value, _ := strings.Cut(part, "=")
		out[key] = value
	}
	return out
}
