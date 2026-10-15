package relay

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

// testRedis connects to POINTY_RELAY_TEST_REDIS_URL under a key prefix of its
// own, removed afterwards, or skips.
func testRedis(t *testing.T) (*redis.Client, string) {
	t.Helper()
	raw := os.Getenv("POINTY_RELAY_TEST_REDIS_URL")
	if raw == "" {
		t.Skip("set POINTY_RELAY_TEST_REDIS_URL to run the Redis presence tests")
	}
	options, err := redis.ParseURL(raw)
	if err != nil {
		t.Fatal(err)
	}
	client := redis.NewClient(options)
	ctx := context.Background()
	if err := client.Ping(ctx).Err(); err != nil {
		t.Fatalf("redis: %v", err)
	}
	prefix := fmt.Sprintf("pointy:relay:test:%d", time.Now().UnixNano())
	t.Cleanup(func() {
		keys, _ := client.Keys(ctx, prefix+":*").Result()
		if len(keys) > 0 {
			_ = client.Del(ctx, keys...).Err()
		}
		_ = client.Close()
	})
	return client, prefix
}

func TestRedisPresenceKeepsEveryTunnelOfAShop(t *testing.T) {
	client, prefix := testRedis(t)
	ctx := context.Background()
	presence := NewRedisConnectorPresence(client, prefix)

	a, err := presence.MarkOnline(ctx, ConnectorPresenceRecord{
		InstallationID: "shop", NodeID: "node-a", ConnectionID: "conn-a", TunnelID: 1, Transport: "websocket",
	}, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	b, err := presence.MarkOnline(ctx, ConnectorPresenceRecord{
		InstallationID: "shop", NodeID: "node-b", ConnectionID: "conn-b", TunnelID: 2,
	}, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	records, err := presence.List(ctx, "shop")
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 2 || records[0].NodeID != "node-a" || records[1].NodeID != "node-b" ||
		records[0].TunnelID != 1 || records[0].Transport != "websocket" {
		t.Fatalf("expected both tunnels, got %+v", records)
	}

	// One tunnel closing leaves the other, and an older relay still finds
	// the shop under the single key it reads.
	if err := a.Close(ctx); err != nil {
		t.Fatal(err)
	}
	if err := b.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	records, _ = presence.List(ctx, "shop")
	if len(records) != 1 || records[0].ConnectionID != "conn-b" {
		t.Fatalf("expected only tunnel b left, got %+v", records)
	}
	legacy, err := client.Get(ctx, prefix+":presence:shop").Result()
	if err != nil {
		t.Fatalf("expected the single key kept for older relays: %v", err)
	}
	if want := `"connection_id":"conn-b"`; !strings.Contains(legacy, want) {
		t.Fatalf("expected the single key to name the live tunnel, got %s", legacy)
	}

	if err := b.Close(ctx); err != nil {
		t.Fatal(err)
	}
	records, _ = presence.List(ctx, "shop")
	if len(records) != 0 {
		t.Fatalf("expected no tunnels, got %+v", records)
	}
	if n, _ := client.Exists(ctx, prefix+":presence:shop").Result(); n != 0 {
		t.Fatal("expected the single key gone with the last tunnel")
	}
}

func TestRedisPresencePrunesExpiredTunnelsOnRead(t *testing.T) {
	client, prefix := testRedis(t)
	ctx := context.Background()
	presence := NewRedisConnectorPresence(client, prefix)
	if _, err := presence.MarkOnline(ctx, ConnectorPresenceRecord{
		InstallationID: "shop", NodeID: "node-a", ConnectionID: "short",
	}, 200*time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if _, err := presence.MarkOnline(ctx, ConnectorPresenceRecord{
		InstallationID: "shop", NodeID: "node-b", ConnectionID: "long",
	}, time.Minute); err != nil {
		t.Fatal(err)
	}
	time.Sleep(400 * time.Millisecond)
	records, err := presence.List(ctx, "shop")
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].ConnectionID != "long" {
		t.Fatalf("expected the expired tunnel gone, got %+v", records)
	}
	members, _ := client.SMembers(ctx, prefix+":presence-index:shop").Result()
	if len(members) != 1 || members[0] != "long" {
		t.Fatalf("expected the index pruned, got %v", members)
	}
}

func TestRedisPresenceOwnershipAndComeback(t *testing.T) {
	client, prefix := testRedis(t)
	ctx := context.Background()
	presence := NewRedisConnectorPresence(client, prefix)
	record := ConnectorPresenceRecord{InstallationID: "shop", NodeID: "node-a", ConnectionID: "conn-a"}
	lease, err := presence.MarkOnline(ctx, record, time.Minute)
	if err != nil {
		t.Fatal(err)
	}

	// A peer that drops a record by mistake (a node it couldn't reach for a
	// moment) is corrected by the owner's next refresh.
	if err := presence.Forget(ctx, record); err != nil {
		t.Fatal(err)
	}
	if records, _ := presence.List(ctx, "shop"); len(records) != 0 {
		t.Fatalf("expected the record dropped, got %+v", records)
	}
	if err := lease.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	if records, _ := presence.List(ctx, "shop"); len(records) != 1 {
		t.Fatalf("expected the owner to put its record back, got %+v", records)
	}

	// Forget only drops the record it names: a stale view of a tunnel on
	// another node leaves the current one alone.
	if err := presence.Forget(ctx, ConnectorPresenceRecord{
		InstallationID: "shop", NodeID: "node-z", ConnectionID: "conn-a",
	}); err != nil {
		t.Fatal(err)
	}
	if n, _ := client.Exists(ctx, prefix+":presence-tunnel:shop:conn-a").Result(); n != 1 {
		t.Fatal("a record owned by another node must not be deleted")
	}
}

func TestRedisPresenceReadsAnOlderRelaysRecord(t *testing.T) {
	client, prefix := testRedis(t)
	ctx := context.Background()
	// What a relay before the presence set writes.
	if err := client.Set(ctx, prefix+":presence:shop",
		`{"installation_id":"shop","node_id":"old-node","connection_id":"old","relay_http_url":"http://old"}`,
		time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	records, err := NewRedisConnectorPresence(client, prefix).List(ctx, "shop")
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].NodeID != "old-node" || records[0].RelayHTTPURL != "http://old" {
		t.Fatalf("expected the older relay's tunnel found, got %+v", records)
	}
}

func TestRedisNodeRegistry(t *testing.T) {
	client, prefix := testRedis(t)
	ctx := context.Background()
	registry := NewRedisNodeRegistry(client, prefix)
	if err := registry.Publish(ctx, NodeInfo{NodeID: "node-b", Tunnels: 4}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := registry.Publish(ctx, NodeInfo{NodeID: "node-a", Tunnels: 7, PublicTunnelURL: "wss://a"}, 200*time.Millisecond); err != nil {
		t.Fatal(err)
	}
	nodes, err := registry.Nodes(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(nodes) != 2 || nodes[0].NodeID != "node-a" || nodes[0].Tunnels != 7 || nodes[0].PublicTunnelURL != "wss://a" {
		t.Fatalf("unexpected nodes %+v", nodes)
	}
	// A node that stops refreshing drops out.
	time.Sleep(400 * time.Millisecond)
	nodes, _ = registry.Nodes(ctx)
	if len(nodes) != 1 || nodes[0].NodeID != "node-b" {
		t.Fatalf("expected node-a expired, got %+v", nodes)
	}
	if err := registry.Leave(ctx, "node-b"); err != nil {
		t.Fatal(err)
	}
	if nodes, _ = registry.Nodes(ctx); len(nodes) != 0 {
		t.Fatalf("expected an empty fleet, got %+v", nodes)
	}
}

func TestRedisHealthAndConnectedShops(t *testing.T) {
	client, prefix := testRedis(t)
	ctx := context.Background()
	health := checkRedis(ctx, client)
	if !health.OK || health.Version == "" || health.UsedMemoryBytes <= 0 || health.ConnectedClients < 1 {
		t.Fatalf("unexpected redis health %+v", health)
	}

	presence := NewRedisConnectorPresence(client, prefix)
	for _, record := range []ConnectorPresenceRecord{
		{InstallationID: "shop-1", NodeID: "a", ConnectionID: "c1"},
		{InstallationID: "shop-1", NodeID: "b", ConnectionID: "c2"},
		{InstallationID: "shop-2", NodeID: "a", ConnectionID: "c3"},
	} {
		if _, err := presence.MarkOnline(ctx, record, time.Minute); err != nil {
			t.Fatal(err)
		}
	}
	if shops, err := presence.ConnectedShops(ctx); err != nil || shops != 2 {
		t.Fatalf("expected 2 shops connected, got %d (%v)", shops, err)
	}
}
