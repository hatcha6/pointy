package e2e

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"testing"
	"time"

	"pointy/relay/internal/protocol"
)

// failedRequests is the requests that failed, described.
func failedRequests(requests []phoneRequest, since time.Time) []string {
	var failures []string
	for _, request := range requests {
		if request.err != "" {
			failures = append(failures, fmt.Sprintf("%s in: %s",
				request.started.Sub(since).Round(time.Millisecond), request.err))
		}
	}
	return failures
}

// waitEven waits until every live node holds the fleet average ±within, and
// returns how long that took.
func (h *fleetHarness) waitEven(within float64, timeout time.Duration) time.Duration {
	h.t.Helper()
	started := time.Now()
	for {
		counts, low, high := h.spreadOver()
		if low >= 1-within && high <= 1+within {
			return time.Since(started)
		}
		if time.Since(started) > timeout {
			h.t.Fatalf("nodes not within %.0f%% of the average after %s: %v", 100*within, timeout, counts)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// Plan test 2: drain a node under traffic. Its tunnels move to the other node
// before it stops, requests it carries finish, and not one request fails.
func TestTunnelFleetDrainsANodeWithoutFailingARequest(t *testing.T) {
	requireFleetE2E(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	h := newFleetHarness(t, ctx, 60)
	limited := fleetNodeOptions{handshakeRate: 50, handshakeBurst: 100}
	a := h.startNode("node-a", limited)
	b := h.startNode("node-b", limited)
	for _, shop := range h.shops {
		h.startConnector(shop, nil)
	}
	h.waitForTunnels(h.shops, 2, 2, 30*time.Second)
	onA := a.hub.TunnelCount()

	watch := h.watchTunnels(h.shops)
	startedAt := time.Now()
	traffic := h.startTraffic(h.shops, 8)
	time.Sleep(time.Second)

	// Slow requests in flight through both nodes when the drain begins.
	slow := make(chan string, 20)
	client := &http.Client{Timeout: 15 * time.Second}
	for i := range cap(slow) {
		shop := h.shops[i%len(h.shops)]
		go func() {
			body, status, err := h.ask(client, shop, "/api/slow/?for=1500ms")
			switch {
			case err != nil:
				slow <- err.Error()
			case status != http.StatusOK || body != "slow":
				slow <- fmt.Sprintf("HTTP %d %q", status, body)
			default:
				slow <- ""
			}
		}()
	}
	time.Sleep(300 * time.Millisecond)

	drainStarted := time.Now()
	result := a.drain(h, 20*time.Second)
	drained := time.Since(drainStarted)
	h.waitForTunnels(h.shops, 2, 1, 10*time.Second)
	time.Sleep(time.Second)
	requests := traffic.finish()
	without, samples := watch.finish()
	var slowFailures []string
	for range cap(slow) {
		if failure := <-slow; failure != "" {
			slowFailures = append(slowFailures, failure)
		}
	}

	duringDrain := 0
	for _, request := range requests {
		if !request.started.Before(drainStarted) && request.started.Before(drainStarted.Add(drained)) {
			duringDrain++
		}
	}
	t.Logf("node-a drained in %s: %d of its %d tunnels asked to move, %d left; node-b now holds %d; %d requests, %d during the drain; slow requests in flight: %d",
		drained.Round(time.Millisecond), result.Moved, onA, result.Left, b.hub.TunnelCount(),
		len(requests), duringDrain, cap(slow))
	if result.Moved != onA || result.Left != 0 || result.TimedOut {
		t.Fatalf("expected every tunnel moved and none left, got %+v", result)
	}
	if failures := failedRequests(requests, startedAt); len(failures) > 0 {
		t.Fatalf("%d of %d requests failed, e.g. %v", len(failures), len(requests), failures[:min(5, len(failures))])
	}
	if len(slowFailures) > 0 {
		t.Fatalf("%d slow requests in flight at the drain failed, e.g. %v", len(slowFailures), slowFailures[0])
	}
	if len(without) > 0 {
		t.Fatalf("%d shops were without a tunnel at some point (%d samples): %v", len(without), samples, without)
	}
	if duringDrain == 0 {
		t.Fatal("no traffic during the drain to judge")
	}
}

// Plan test 6: scale out from two nodes to three with hundreds of tunnels.
// The new node fills up to the average ±15% by rebalancing alone, no shop is
// ever without a tunnel and no request fails; then the same after a node is
// restarted (drained, and started again under the same id).
//
// Rounds run every second instead of every 30 s, and a tunnel is moved once
// it is 3 s old instead of 5 minutes: the same rule, 30 times faster.
func TestTunnelFleetScalesOutAndEvensOut(t *testing.T) {
	requireFleetE2E(t)
	shops := 300
	if raw := os.Getenv("POINTY_RELAY_E2E_SCALE_SHOPS"); raw != "" {
		shops, _ = strconv.Atoi(raw)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	h := newFleetHarness(t, ctx, shops)
	options := fleetNodeOptions{
		handshakeRate:   50,
		handshakeBurst:  100,
		rebalanceEvery:  time.Second,
		rebalanceMinAge: 3 * time.Second,
	}
	a := h.startNode("node-a", options)
	b := h.startNode("node-b", options)
	for _, shop := range h.shops {
		h.startConnector(shop, nil)
	}
	h.waitForTunnels(h.shops, 2, 2, 2*time.Minute)
	t.Logf("%d shops up: node-a %d tunnels, node-b %d", shops, a.hub.TunnelCount(), b.hub.TunnelCount())

	watch := h.watchTunnels(h.shops)
	startedAt := time.Now()
	traffic := h.startTraffic(h.shops, 8)
	time.Sleep(time.Second)

	c := h.startNode("node-c", options)
	evened := h.waitEven(0.15, 2*time.Minute)
	counts, low, high := h.spreadOver()
	t.Logf("node-c joined: within 15%% of the average after %s (≈%s at 30 s rounds): %v (%.2f–%.2f of the average)",
		evened.Round(time.Millisecond), (30 * evened).Round(time.Second), counts, low, high)

	result := b.drain(h, 20*time.Second)
	t.Logf("node-b drained: %d tunnels asked to move, %d left, timed out %v", result.Moved, result.Left, result.TimedOut)
	if result.Left != 0 || result.TimedOut {
		t.Fatalf("expected node-b to drain completely, got %+v", result)
	}
	b2 := h.startNode("node-b", options)
	evenedAgain := h.waitEven(0.15, 2*time.Minute)
	h.waitForTunnels(h.shops, 2, 2, 30*time.Second)
	counts, low, high = h.spreadOver()
	t.Logf("node-b restarted: within 15%% of the average after %s (≈%s at 30 s rounds): %v (%.2f–%.2f)",
		evenedAgain.Round(time.Millisecond), (30 * evenedAgain).Round(time.Second), counts, low, high)

	time.Sleep(5 * time.Second)
	counts, low, high = h.spreadOver()
	t.Logf("5 s later: %v (%.2f–%.2f)", counts, low, high)
	requests := traffic.finish()
	without, samples := watch.finish()
	moved := 0
	for _, node := range []*fleetNode{a, b, c, b2} {
		moved += int(node.metrics.Snapshot().TunnelMoves[protocol.GoAwayRebalance])
	}
	t.Logf("%d requests; %d tunnels moved by rebalancing; %d watch samples", len(requests), moved, samples)
	if failures := failedRequests(requests, startedAt); len(failures) > 0 {
		t.Fatalf("%d of %d requests failed, e.g. %v", len(failures), len(requests), failures[:min(5, len(failures))])
	}
	if len(without) > 0 {
		t.Fatalf("%d shops were without a tunnel at some point: %v", len(without), without)
	}
}
