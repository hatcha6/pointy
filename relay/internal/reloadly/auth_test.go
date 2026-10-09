package reloadly

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestTokensAreCachedPerAudience(t *testing.T) {
	f := newFake(t)
	f.always("giftcards", ok(balanceBody))
	f.always("topups", ok(balanceBody))
	c := f.client()
	ctx := context.Background()
	for i := 0; i < 3; i++ {
		if _, err := c.GiftBalance(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := c.TopupBalance(ctx); err != nil {
		t.Fatal(err)
	}
	auth := f.callsTo("auth")
	if len(auth) != 2 {
		t.Fatalf("token requests = %d, want one per product used", len(auth))
	}
	audiences := map[any]bool{}
	for _, request := range auth {
		if request.method != http.MethodPost || request.path != "/oauth/token" ||
			request.header.Get("Content-Type") != "application/json" ||
			request.payload["client_id"] != "test-id" || request.payload["client_secret"] != "test-secret" ||
			request.payload["grant_type"] != "client_credentials" {
			t.Fatalf("token request = %+v", request)
		}
		audiences[request.payload["audience"]] = true
	}
	if !audiences[f.url("giftcards")] || !audiences[f.url("topups")] {
		t.Fatalf("audiences = %v, want each product's own URL", audiences)
	}
	first := f.callsTo("giftcards")[0]
	if first.method != http.MethodGet || first.path != "/accounts/balance" ||
		first.header.Get("Authorization") != "Bearer tok-1" ||
		first.header.Get("Accept") != "application/com.reloadly.giftcards-v1+json" ||
		!strings.HasPrefix(first.header.Get("User-Agent"), "pointy-relay") {
		t.Fatalf("product request headers = %v", first.header)
	}
	if got := f.callsTo("topups")[0].header.Get("Accept"); got != "application/com.reloadly.topups-v1+json" {
		t.Fatalf("topups Accept = %q", got)
	}
}

// fakeClock is a settable clock.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func TestATokenIsRefreshedBeforeItExpires(t *testing.T) {
	for _, test := range []struct {
		name      string
		expiresIn string
		fresh     time.Duration // still cached
		stale     time.Duration // refreshed
	}{
		{"sandbox hour: 5 minute margin", "3600", 54 * time.Minute, 56 * time.Minute},
		{"60 days", "5184000", 59 * 24 * time.Hour, 60*24*time.Hour - 4*time.Minute},
		{"short token: a quarter of it", "60", 44 * time.Second, 46 * time.Second},
		{"no lifetime: an hour is assumed", `"soon"`, 54 * time.Minute, 56 * time.Minute},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newFake(t)
			f.expiresIn = test.expiresIn
			f.always("giftcards", ok(balanceBody))
			clock := &fakeClock{now: time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC)}
			c := f.client(func(cfg *Config) { cfg.Clock = clock.Now })
			ctx := context.Background()
			read := func() {
				t.Helper()
				if _, err := c.GiftBalance(ctx); err != nil {
					t.Fatal(err)
				}
			}
			read()
			clock.advance(test.fresh)
			read()
			if n := len(f.callsTo("auth")); n != 1 {
				t.Fatalf("token requested %d times before the margin", n)
			}
			clock.advance(test.stale - test.fresh)
			read()
			if n := len(f.callsTo("auth")); n != 2 {
				t.Fatalf("token requested %d times after the margin, want 2", n)
			}
			if got := f.callsTo("giftcards")[2].header.Get("Authorization"); got != "Bearer tok-2" {
				t.Fatalf("the refreshed token was not used: %q", got)
			}
		})
	}
}

func TestConcurrentCallsShareOneTokenRequest(t *testing.T) {
	f := newFake(t)
	f.authDelay = 300 * time.Millisecond
	f.always("giftcards", ok(balanceBody))
	c := f.client()
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := c.GiftBalance(context.Background()); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if n := len(f.callsTo("auth")); n != 1 {
		t.Fatalf("token requests = %d, want 1 shared by 20 callers", n)
	}
}

func TestAWaitingCallerGivingUpDoesNotFailTheOthers(t *testing.T) {
	f := newFake(t)
	f.authDelay = 150 * time.Millisecond
	f.always("giftcards", ok(balanceBody))
	c := f.client()
	quick, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	leaderDone := make(chan error, 1)
	go func() {
		_, err := c.GiftBalance(quick)
		leaderDone <- err
	}()
	time.Sleep(5 * time.Millisecond)
	if _, err := c.GiftBalance(context.Background()); err != nil {
		t.Fatalf("the patient caller failed: %v", err)
	}
	err := <-leaderDone
	var transport *TransportError
	if !errors.As(err, &transport) || transport.Sent || !Definite(err) {
		t.Fatalf("the impatient caller got %#v, want a definite transport error", err)
	}
	if n := len(f.callsTo("auth")); n != 1 {
		t.Fatalf("token requests = %d, want 1", n)
	}
}

func TestInvalidateKeepsANewerToken(t *testing.T) {
	f := newFake(t)
	c := f.client()
	source := c.gift.tokens
	source.token, source.refreshAt = "new", c.clock().Add(time.Hour)
	source.invalidate("old")
	if source.token != "new" {
		t.Fatal("a stale invalidation dropped the newer token")
	}
	source.invalidate("new")
	if source.token != "" {
		t.Fatal("the refused token was kept")
	}
}

func TestATokenRefusalIsDefiniteAndNothingIsSent(t *testing.T) {
	f := newFake(t)
	f.authReplies = []reply{fail(401, `{"timeStamp":"2026-10-08 01:41:16","message":"Access Denied","path":"/oauth/token","errorCode":"INVALID_CREDENTIALS","infoLink":null,"details":[]}`)}
	f.always("giftcards", ok("{}"))
	c := f.client()
	_, err := c.OrderGiftCard(context.Background(), validGiftOrder())
	var api *APIError
	if !errors.As(err, &api) || api.Product != "auth" || api.Code != CodeInvalidCredentials || api.RequestSent {
		t.Fatalf("err = %#v", err)
	}
	if !errors.Is(err, ErrUnauthorized) || !Definite(err) {
		t.Fatalf("a refused token must be unauthorized and definite: %v", err)
	}
	if len(f.callsTo("auth")) != 1 || len(f.callsTo("giftcards")) != 0 {
		t.Fatal("a refused token must stop the purchase before it is sent")
	}
	if strings.Contains(err.Error(), "test-secret") {
		t.Fatal("the error leaks the secret")
	}
}

func TestTokenRequestsSurviveServerHiccups(t *testing.T) {
	f := newFake(t)
	f.authReplies = []reply{fail(503, "<html>down</html>"), fail(502, ""), ok("")}
	f.always("topups", ok(balanceBody))
	if _, err := f.client().TopupBalance(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := len(f.callsTo("auth")); n != 3 {
		t.Fatalf("token requests = %d, want 3", n)
	}
	// A token answer without a token is an error that was never Sent.
	g := newFake(t)
	g.authReplies = []reply{ok(`{"expires_in":3600}`)}
	_, err := g.client().TopupBalance(context.Background())
	var transport *TransportError
	if !errors.As(err, &transport) || transport.Sent || transport.Product != "auth" || !Definite(err) {
		t.Fatalf("err = %#v", err)
	}
}

func TestAReadDoesNotRepeatTheTokenRetries(t *testing.T) {
	f := newFake(t)
	f.authReplies = []reply{fail(503, "down")}
	f.always("giftcards", ok(balanceBody))
	if _, err := f.client().GiftBalance(context.Background()); err == nil {
		t.Fatal("a token service that is down must fail the read")
	}
	if n := len(f.callsTo("auth")); n != maxTokenAttempts {
		t.Fatalf("token requests = %d, want %d: the read must not multiply them", n, maxTokenAttempts)
	}
	if len(f.callsTo("giftcards")) != 0 {
		t.Fatal("the read reached the product without a token")
	}
}

func TestA401RefreshesTheTokenAndRepeatsOnce(t *testing.T) {
	f := newFake(t)
	var executed atomic.Int32
	f.on("topups", func(c call) reply {
		if c.method == http.MethodPost {
			executed.Add(1)
			return ok(fixture(t, "topup_local_niger.json"))
		}
		return ok(balanceBody)
	})
	c := f.client()
	ctx := context.Background()
	if _, err := c.TopupBalance(ctx); err != nil {
		t.Fatal(err)
	}
	f.revoke("tok-1")
	// A read repeats with the fresh token...
	if _, err := c.TopupBalance(ctx); err != nil {
		t.Fatalf("the read was not repeated: %v", err)
	}
	calls := f.callsTo("topups")
	if len(calls) != 3 || calls[1].header.Get("Authorization") != "Bearer tok-1" || calls[2].header.Get("Authorization") != "Bearer tok-2" {
		t.Fatalf("calls = %d, headers %v", len(calls), calls[len(calls)-1].header)
	}
	// ...and so does a purchase: a 401 proves it was not executed.
	f.revoke("tok-2")
	if _, err := c.Topup(ctx, validTopup()); err != nil {
		t.Fatalf("the purchase was not repeated: %v", err)
	}
	if executed.Load() != 1 {
		t.Fatalf("the purchase ran %d times, want once", executed.Load())
	}
	if n := len(f.callsTo("auth")); n != 3 {
		t.Fatalf("token requests = %d, want 3", n)
	}
}

func TestASecond401IsReturned(t *testing.T) {
	f := newFake(t)
	f.always("giftcards", fail(401, `{"message":"Invalid token","errorCode":"INVALID_TOKEN"}`))
	c := f.client()
	// The default handler never runs for a revoked token; make every token bad.
	_, err := c.GiftBalance(context.Background())
	if !IsUnauthorized(err) || !Definite(err) {
		t.Fatalf("err = %v", err)
	}
	if n := len(f.callsTo("giftcards")); n != 2 {
		t.Fatalf("product calls = %d, want the call and exactly one repeat", n)
	}
	if n := len(f.callsTo("auth")); n != 2 {
		t.Fatalf("token requests = %d, want 2", n)
	}
}
