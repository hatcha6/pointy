package relay

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
)

type fakeDatabase struct{}

func (fakeDatabase) Health(context.Context) control.DatabaseHealth {
	return control.DatabaseHealth{OK: true, LatencyMS: 1.5, Version: "16.4"}
}

func TestSystemViewShowsTheWholeFleet(t *testing.T) {
	ctx := context.Background()
	store, _ := provisionRelayInstallation(t)
	hub := NewHub()
	session, _ := pipeSession(t)
	hub.RegisterTunnel("shop", 1, session)
	metrics := observability.NewMetrics()
	done := metrics.PhoneRequestStarted()
	defer done(200)

	registry := &memoryRegistry{}
	_ = registry.Publish(ctx, NodeInfo{
		NodeID:  "node-b",
		Tunnels: 7,
		Stats:   &NodeStats{Version: "v0.9.0", Shops: 7},
	}, time.Minute)
	fleet := &Fleet{Registry: registry, NodeID: "node-a", Hub: hub, Stats: NodeStatsOf(hub, metrics, "v0.9.1")}
	fleet.Refresh(ctx)

	server := HTTPServer{
		Store:      store,
		Hub:        hub,
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		Metrics:    metrics,
		Fleet:      fleet,
		NodeID:     "node-a",
		Version:    "v0.9.1",
		Database:   fakeDatabase{},
		AdminToken: "admin-token-0123456789abcdef0123456789",
	}
	request := httptest.NewRequest(http.MethodGet, "/v1/system", nil)
	request.Header.Set("Authorization", "Bearer admin-token-0123456789abcdef0123456789")
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}
	var payload struct {
		ServedBy string `json:"served_by"`
		Fleet    struct {
			Nodes []struct {
				NodeID  string     `json:"node_id"`
				Tunnels int        `json:"tunnels"`
				Self    bool       `json:"self"`
				Stats   *NodeStats `json:"stats"`
			} `json:"nodes"`
		} `json:"fleet"`
		Shops    struct{ Connected int } `json:"shops"`
		Services struct {
			Postgres *control.DatabaseHealth `json:"postgres"`
			Redis    *RedisHealth            `json:"redis"`
		} `json:"services"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.ServedBy != "node-a" || len(payload.Fleet.Nodes) != 2 {
		t.Fatalf("expected both nodes from node-a, got %+v", payload)
	}
	for _, node := range payload.Fleet.Nodes {
		switch node.NodeID {
		case "node-a":
			if !node.Self || node.Stats == nil || node.Stats.Traffic.InFlight != 1 || node.Stats.Shops != 1 || node.Stats.Version != "v0.9.1" {
				t.Fatalf("this node's figures must be live: %+v %+v", node, node.Stats)
			}
		case "node-b":
			if node.Self || node.Stats == nil || node.Stats.Version != "v0.9.0" || node.Tunnels != 7 {
				t.Fatalf("the other node's published figures went missing: %+v", node)
			}
		}
	}
	if payload.Shops.Connected != 1 || payload.Services.Postgres == nil || !payload.Services.Postgres.OK || payload.Services.Redis != nil {
		t.Fatalf("unexpected shops/services: %+v %+v", payload.Shops, payload.Services)
	}

	unauthorised := httptest.NewRecorder()
	server.ServeHTTP(unauthorised, httptest.NewRequest(http.MethodGet, "/v1/system", nil))
	if unauthorised.Code == http.StatusOK {
		t.Fatal("the system view is for operators only")
	}
}
