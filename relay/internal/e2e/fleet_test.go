package e2e

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"slices"
	"strconv"
	"testing"
	"time"

	"pointy/relay/internal/connector"
)

// Plan test 1: kill a node under steady phone traffic. Every shop keeps a
// tunnel on the surviving node, so requests that start after the kill are all
// served, and every shop is back to two tunnels within 30 s.
func TestTunnelFleetSurvivesANodeKilledUnderTraffic(t *testing.T) {
	requireFleetE2E(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	h := newFleetHarness(t, ctx, 20)
	h.startNode("node-a", fleetNodeOptions{})
	b := h.startNode("node-b", fleetNodeOptions{})
	for _, shop := range h.shops {
		h.startConnector(shop, nil)
	}
	h.waitForTunnels(h.shops, 2, 2, 30*time.Second)

	traffic := h.startTraffic(h.shops, 8)
	time.Sleep(time.Second)
	killedAt := time.Now()
	b.kill(h)
	recovered := h.waitForTunnels(h.shops, 2, 1, 30*time.Second)
	time.Sleep(time.Second)
	requests := traffic.finish()

	// A request already on its way to the node when it died dies with it, as
	// it would behind NGINX. Anything sent afterwards must be served.
	const settle = 250 * time.Millisecond
	var before, during, after, failedDuring int
	var failures []string
	for _, request := range requests {
		switch {
		case request.finished.Before(killedAt):
			before++
			if request.err != "" {
				failures = append(failures, "before the kill: "+request.err)
			}
		case request.started.Before(killedAt.Add(settle)):
			during++
			if request.err != "" {
				failedDuring++
			}
		default:
			after++
			if request.err != "" {
				failures = append(failures, fmt.Sprintf("%s after the kill: %s",
					request.started.Sub(killedAt).Round(time.Millisecond), request.err))
			}
		}
	}
	t.Logf("requests: %d done before the kill, %d in flight at it or within %s (%d failed), %d after; shops back to two tunnels %s after the kill",
		before, during, settle, failedDuring, after, recovered.Round(time.Millisecond))
	if after == 0 {
		t.Fatal("no traffic after the kill to judge")
	}
	if len(failures) > 0 {
		t.Fatalf("%d requests failed, e.g. %v", len(failures), failures[:min(5, len(failures))])
	}
}

// Plan test 3: restart a node holding hundreds of tunnels. Every node keeps
// to its handshake limit while the herd comes back, and every shop is back to
// two tunnels within the reconnect backoff cap plus the time the limit itself
// takes to let them all in.
func TestTunnelFleetRestartedNodeIsHeldToTheHandshakeLimit(t *testing.T) {
	requireFleetE2E(t)
	shops := 500
	if raw := os.Getenv("POINTY_RELAY_E2E_SHOPS"); raw != "" {
		shops, _ = strconv.Atoi(raw)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	h := newFleetHarness(t, ctx, shops)
	const rate, burst = 50, 100
	limited := fleetNodeOptions{handshakeRate: rate, handshakeBurst: burst}
	a := h.startNode("node-a", limited)
	b := h.startNode("node-b", limited)
	for _, shop := range h.shops {
		h.startConnector(shop, nil)
	}
	setup := h.waitForTunnels(h.shops, 2, 2, 2*time.Minute)
	t.Logf("%d shops up with two tunnels each in %s; node-b holds %d tunnels",
		shops, setup.Round(time.Millisecond), b.hub.TunnelCount())

	refusedBefore := a.metrics.Snapshot().ConnectorHandshakeRejections["rate_limited"]
	sampler := newHandshakeSampler(h)
	b.kill(h)
	b2 := h.startNode("node-b2", limited)
	// The cap on one tunnel's redial is 30 s; letting the whole herd through
	// the limit takes its own time on top.
	budget := 30*time.Second + time.Duration(2*shops/rate)*time.Second
	recovered := h.waitForTunnels(h.shops, 2, 1, budget)
	samples := sampler.stop()

	t.Logf("every shop back to two tunnels %s after the restart (budget %s); node-a %d tunnels, node-b2 %d; refused by the limit since the restart: node-a %d, node-b2 %d",
		recovered.Round(time.Millisecond), budget, a.hub.TunnelCount(), b2.hub.TunnelCount(),
		a.metrics.Snapshot().ConnectorHandshakeRejections["rate_limited"]-refusedBefore,
		b2.metrics.Snapshot().ConnectorHandshakeRejections["rate_limited"])
	for node, series := range samples {
		peak := peakPerWindow(series, time.Second)
		t.Logf("%s: at most %d new tunnels in any one second", node, peak)
		// Sampled every 100 ms, a "second" may span 1.1 s of refill.
		if limit := burst + rate + rate/10; peak > limit {
			t.Fatalf("%s took %d tunnels in one second, over its limit of %d", node, peak, limit)
		}
	}
}

// Plan test 4: an old connector (one tunnel over TCP, no numbering, never
// told to move) beside new ones. Its shop is reachable through every node, it
// is never disconnected, and the new shops' tunnels moving around it don't
// touch it.
func TestTunnelFleetOldConnectorAlongsideNewOnes(t *testing.T) {
	requireFleetE2E(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	h := newFleetHarness(t, ctx, 11)
	a := h.startNode("node-a", fleetNodeOptions{})
	b := h.startNode("node-b", fleetNodeOptions{})
	old, current := h.shops[0], h.shops[1:]
	legacy := h.startLegacyConnector(old, a.tcp.Addr().String())
	for _, shop := range current {
		h.startConnector(shop, nil)
	}
	h.waitForTunnels(current, 2, 2, 30*time.Second)
	h.waitForTunnels([]fleetShop{old}, 1, 1, 10*time.Second)

	client := &http.Client{Timeout: 10 * time.Second}
	askOld := func(label string, n int) {
		t.Helper()
		for i := range n {
			body, status, err := h.ask(client, old, "/api/echo/"+old.id)
			if err != nil || status != http.StatusOK || body != old.id {
				t.Fatalf("%s: request %d for the old connector's shop failed: %v %d %q", label, i, err, status, body)
			}
		}
	}
	askOld("both nodes up", 40)
	if forwarded := b.metrics.Snapshot().NodeHops["forwarded"]; forwarded == 0 {
		t.Fatal("expected node-b to forward the old shop's requests to node-a")
	}
	records, err := h.presenceOf(old.id)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].TunnelID != 0 || records[0].Transport != "tcp" || records[0].NodeID != "node-a" {
		t.Fatalf("unexpected presence for the old connector: %+v", records)
	}

	// The new shops' node dies and they all move; the old shop never notices.
	b.kill(h)
	h.waitForTunnels(current, 2, 1, 30*time.Second)
	askOld("after node-b died", 20)
	if dials := legacy.dials.Load(); dials != 1 {
		t.Fatalf("the old connector was disconnected: %d dials", dials)
	}
}

// Plan test 5: what the tunnel over WebSocket (through the balancer, the
// tunnel's own TLS inside) costs against raw TCP, and how small requests fare
// beside a large export.
func TestTunnelFleetWebSocketThroughputAgainstTCP(t *testing.T) {
	requireFleetE2E(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	h := newFleetHarness(t, ctx, 3)
	a := h.startNode("node-a", fleetNodeOptions{})
	wsShop, tcpShop, busyShop := h.shops[0], h.shops[1], h.shops[2]
	h.startConnector(wsShop, func(c *connector.Client) { c.MaxTunnels = 1 })
	h.startConnector(tcpShop, func(c *connector.Client) {
		c.MaxTunnels = 1
		c.Endpoints = nil
		c.RelayAddress = a.tcp.Addr().String()
	})
	h.startConnector(busyShop, nil)
	h.waitForTunnels([]fleetShop{wsShop, tcpShop}, 1, 1, 10*time.Second)
	h.waitForTunnels([]fleetShop{busyShop}, 2, 1, 10*time.Second)

	client := &http.Client{Timeout: time.Minute}
	const size = 64 << 20
	throughput := func(shop fleetShop) float64 {
		best := 0.0
		for range 3 {
			started := time.Now()
			body, status, err := h.ask(client, shop, "/api/export/?bytes="+strconv.Itoa(size))
			if err != nil || status != http.StatusOK || len(body) != size {
				t.Fatalf("export failed: %v %d (%d bytes)", err, status, len(body))
			}
			best = max(best, float64(size)/(1<<20)/time.Since(started).Seconds())
		}
		return best
	}
	ws, tcp := throughput(wsShop), throughput(tcpShop)
	t.Logf("64 MB export: WebSocket %.0f MB/s, TCP %.0f MB/s (%.0f%%)", ws, tcp, 100*ws/tcp)
	if ws < 0.4*tcp && !raceEnabled {
		t.Fatalf("the tunnel over WebSocket runs at %.0f%% of TCP", 100*ws/tcp)
	}

	// Small requests beside a large export on the same shop: the hub sends
	// them to the tunnel that isn't carrying it. The export is sized to run
	// for a few seconds, longer than the small requests take.
	exportBytes := int(ws * 4 * (1 << 20))
	exportDone := make(chan error, 1)
	go func() {
		_, status, err := h.ask(client, busyShop, "/api/export/?bytes="+strconv.Itoa(exportBytes))
		if err == nil && status != http.StatusOK {
			err = fmt.Errorf("HTTP %d", status)
		}
		exportDone <- err
	}()
	time.Sleep(200 * time.Millisecond)
	var latencies []time.Duration
	for range 30 {
		started := time.Now()
		body, status, err := h.ask(client, busyShop, "/api/echo/"+busyShop.id)
		if err != nil || status != http.StatusOK || body != busyShop.id {
			t.Fatalf("small request beside the export failed: %v %d %q", err, status, body)
		}
		latencies = append(latencies, time.Since(started))
		time.Sleep(20 * time.Millisecond)
	}
	select {
	case err := <-exportDone:
		t.Fatalf("the export ended before the small requests did (%v): nothing was measured beside it", err)
	default:
	}
	if err := <-exportDone; err != nil {
		t.Fatalf("export failed: %v", err)
	}
	slices.Sort(latencies)
	p50, worst := latencies[len(latencies)/2], latencies[len(latencies)-1]
	t.Logf("small requests beside a %d MB export: p50 %s, worst %s",
		exportBytes>>20, p50.Round(time.Microsecond), worst.Round(time.Microsecond))
	if worst > time.Second && !raceEnabled {
		t.Fatalf("a small request waited %s behind the export", worst)
	}
}

// handshakeSampler records each node's tunnel count total every 100 ms.
type handshakeSampler struct {
	stopCh chan struct{}
	done   chan map[string][]handshakeSample
}

type handshakeSample struct {
	at    time.Time
	total uint64
}

func newHandshakeSampler(h *fleetHarness) *handshakeSampler {
	s := &handshakeSampler{stopCh: make(chan struct{}), done: make(chan map[string][]handshakeSample, 1)}
	go func() {
		series := map[string][]handshakeSample{}
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()
		for {
			for _, node := range h.liveNodes() {
				series[node.id] = append(series[node.id], handshakeSample{
					at:    time.Now(),
					total: node.metrics.Snapshot().ConnectorConnectionsTotal,
				})
			}
			select {
			case <-s.stopCh:
				s.done <- series
				return
			case <-ticker.C:
			}
		}
	}()
	return s
}

func (s *handshakeSampler) stop() map[string][]handshakeSample {
	close(s.stopCh)
	return <-s.done
}

// peakPerWindow is the most tunnels taken within any window.
func peakPerWindow(series []handshakeSample, window time.Duration) int {
	peak := 0
	for i := range series {
		for j := i; j < len(series) && series[j].at.Sub(series[i].at) <= window; j++ {
			peak = max(peak, int(series[j].total-series[i].total))
		}
	}
	return peak
}
