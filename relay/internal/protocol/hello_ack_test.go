package protocol

import (
	"slices"
	"strings"
	"testing"
)

func TestHelloAckRoundTrip(t *testing.T) {
	payload := EncodeHelloAck(HelloAckInfo{NodeID: "node-a", Endpoints: []string{"wss://a/x", "tls://b:1"}})
	info, ok := DecodeHelloAck(payload)
	if !ok || info.NodeID != "node-a" || !slices.Equal(info.Endpoints, []string{"wss://a/x", "tls://b:1"}) {
		t.Fatalf("round trip lost data: %+v ok=%v from %s", info, ok, payload)
	}
}

func TestHelloAckWithNoEndpointsStillSaysSo(t *testing.T) {
	info, ok := DecodeHelloAck(EncodeHelloAck(HelloAckInfo{NodeID: "node-a"}))
	if !ok || info.Endpoints == nil || len(info.Endpoints) != 0 {
		t.Fatalf("an empty list must read as an empty list, got %+v ok=%v", info, ok)
	}
}

func TestHelloAckFromAnOldRelay(t *testing.T) {
	for _, payload := range []string{"", "  ", "not json", `{"node_id":"x"}`} {
		if _, ok := DecodeHelloAck([]byte(payload)); ok {
			t.Fatalf("payload %q must read as an old relay", payload)
		}
	}
}

func TestHelloAckCapsWhatItAccepts(t *testing.T) {
	var endpoints []string
	for range MaxAdvertisedEndpoints + 3 {
		endpoints = append(endpoints, "wss://a/x")
	}
	endpoints = append([]string{"", "wss://" + strings.Repeat("a", MaxEndpointLength)}, endpoints...)
	info, ok := DecodeHelloAck(EncodeHelloAck(HelloAckInfo{Endpoints: endpoints}))
	if !ok || len(info.Endpoints) != MaxAdvertisedEndpoints || slices.Contains(info.Endpoints, "") {
		t.Fatalf("expected %d sane endpoints, got %d: ok=%v", MaxAdvertisedEndpoints, len(info.Endpoints), ok)
	}
}

func TestHelloAckSaysWhetherTheRelayMovesTunnels(t *testing.T) {
	info, ok := DecodeHelloAck(EncodeHelloAck(HelloAckInfo{Tunnels: 2, Moves: true}))
	if !ok || !info.Moves {
		t.Fatalf("expected moves, got %+v ok=%v", info, ok)
	}
	info, _ = DecodeHelloAck([]byte(`{"endpoints":[],"tunnels":2}`))
	if info.Moves {
		t.Fatal("a relay that doesn't say so doesn't move tunnels")
	}
}
