package control

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

// The Redis ticket store against a real Redis, when one answers. Its keys
// live under a prefix of their own and are removed after.
func newTestTicketService(t *testing.T, clock Clock) (*RedisRelayTicketService, redis.Cmdable) {
	t.Helper()
	url := os.Getenv("POINTY_RELAY_TEST_REDIS_URL")
	if url == "" {
		url = "redis://127.0.0.1:6379/0"
	}
	options, err := redis.ParseURL(url)
	if err != nil {
		t.Fatal(err)
	}
	client := redis.NewClient(options)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := client.Ping(ctx).Err(); err != nil {
		client.Close()
		t.Skipf("no Redis at %s: %v", url, err)
	}
	prefix := fmt.Sprintf("pointy:relay:test:%d", time.Now().UnixNano())
	t.Cleanup(func() {
		keys, _ := client.Keys(context.Background(), prefix+":*").Result()
		if len(keys) > 0 {
			client.Del(context.Background(), keys...)
		}
		client.Close()
	})
	return NewRedisRelayTicketService(client, prefix, clock), client
}

type ticketClock struct{ now time.Time }

func (c *ticketClock) Now() time.Time { return c.now }

func TestRedisTicketsEndWithTheirSignIn(t *testing.T) {
	clock := &ticketClock{now: time.Now().UTC().Truncate(time.Second)}
	service, _ := newTestTicketService(t, clock)
	ctx := context.Background()
	notAfter := clock.now.Add(10 * time.Minute)
	issued, err := service.IssueTicket(ctx, Installation{ID: "shop-1"},
		RelayTicketRequest{DeviceID: "iphone-1", NotAfter: &notAfter}, 15*time.Minute, 7*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if !issued.ExpiresAt.Equal(notAfter) || !issued.RefreshExpiresAt.Equal(notAfter) {
		t.Fatalf("expected both cut to %v, got %v / %v", notAfter, issued.ExpiresAt, issued.RefreshExpiresAt)
	}
	refresh, err := service.ConsumeRefreshToken(ctx, issued.RefreshToken, clock.now)
	if err != nil {
		t.Fatal(err)
	}
	next := refresh.NextRequest()
	if next.NotAfter == nil || !next.NotAfter.Equal(notAfter) || !next.ChainStartedAt.Equal(clock.now) {
		t.Fatalf("a refresh carries the bound and the chain, got %+v", next)
	}
	past := clock.now.Add(-time.Second)
	if _, err := service.IssueTicket(ctx, Installation{ID: "shop-1"},
		RelayTicketRequest{DeviceID: "iphone-1", NotAfter: &past}, time.Minute, time.Hour); !errors.Is(err, ErrTicketNotAfterPassed) {
		t.Fatalf("expected ErrTicketNotAfterPassed, got %v", err)
	}
}

func TestRedisRevokeDropsADevicesTokensAndItsChain(t *testing.T) {
	clock := &ticketClock{now: time.Now().UTC().Truncate(time.Millisecond)}
	service, client := newTestTicketService(t, clock)
	ctx := context.Background()
	shop := Installation{ID: "shop-1"}
	first, err := service.IssueTicket(ctx, shop, RelayTicketRequest{DeviceID: "iphone-1"}, 15*time.Minute, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	other, err := service.IssueTicket(ctx, shop, RelayTicketRequest{DeviceID: "till-1"}, 15*time.Minute, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	// A refresh taken mid-revoke: its token is spent, its successor not yet
	// indexed when the index is read.
	clock.now = clock.now.Add(time.Second)
	spent, err := service.ConsumeRefreshToken(ctx, first.RefreshToken, clock.now)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.RevokeDevice(ctx, shop.ID, "iphone-1", clock.now, time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := service.IssueTicket(ctx, shop, spent.NextRequest(), 15*time.Minute, time.Hour); !errors.Is(err, ErrRelayRefreshTokenNotFound) {
		t.Fatalf("a refresh of a revoked chain mints nothing, got %v", err)
	}

	if _, err := service.ValidateTicket(ctx, first.Token, clock.now); err == nil {
		t.Fatal("the revoked device's ticket must be gone")
	}
	if _, err := service.ValidateTicket(ctx, other.Token, clock.now); err != nil {
		t.Fatalf("another device keeps its ticket: %v", err)
	}
	clock.now = clock.now.Add(time.Second)
	again, err := service.IssueTicket(ctx, shop, RelayTicketRequest{DeviceID: "iphone-1"}, 15*time.Minute, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.PeekRefreshToken(ctx, again.RefreshToken, clock.now); err != nil {
		t.Fatalf("pairing again after a revoke works: %v", err)
	}
	if n, _ := client.ZCard(ctx, service.deviceIndexKey(shop.ID, "iphone-1")).Result(); n != 2 {
		t.Fatalf("the index holds the live pair only, got %d", n)
	}
}

func TestRedisDeviceIndexForgetsWhatExpired(t *testing.T) {
	clock := &ticketClock{now: time.Now().UTC()}
	service, client := newTestTicketService(t, clock)
	ctx := context.Background()
	for range 5 {
		if _, err := service.IssueTicket(ctx, Installation{ID: "shop-1"},
			RelayTicketRequest{DeviceID: "till-1"}, time.Minute, 2*time.Minute); err != nil {
			t.Fatal(err)
		}
		clock.now = clock.now.Add(3 * time.Minute)
	}
	if n, _ := client.ZCard(ctx, service.deviceIndexKey("shop-1", "till-1")).Result(); n != 2 {
		t.Fatalf("expired members are pruned as new ones come, got %d", n)
	}
}
