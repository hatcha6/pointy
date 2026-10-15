package relay

import (
	"context"
	"net"
	"testing"
	"time"

	"pointy/relay/internal/protocol"
)

// pipeSession is a relay-side session whose shop end accepts streams and
// leaves them open, so the session's stream count is what the test opened.
func pipeSession(t *testing.T) (*protocol.Session, *protocol.Session) {
	t.Helper()
	relayRaw, shopRaw := net.Pipe()
	relay := protocol.NewSession(protocol.NewConn(relayRaw))
	shop := protocol.NewSession(protocol.NewConn(shopRaw))
	go func() { _ = relay.Run() }()
	go func() { _ = shop.Run() }()
	go func() {
		for {
			if _, err := shop.Accept(context.Background()); err != nil {
				return
			}
		}
	}()
	t.Cleanup(func() {
		_ = relay.Close()
		_ = shop.Close()
	})
	return relay, shop
}

func TestHubKeepsEveryTunnelOfAShopAndPicksTheLeastBusy(t *testing.T) {
	hub := NewHub()
	first, _ := pipeSession(t)
	second, _ := pipeSession(t)
	hub.RegisterTunnel("shop", 1, first)
	hub.RegisterTunnel("shop", 2, second)
	if got := hub.TunnelCount(); got != 2 {
		t.Fatalf("expected both tunnels kept, got %d", got)
	}

	// Two streams busy on the first tunnel: new ones go to the second.
	for range 2 {
		if _, err := first.OpenStream(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	stream, err := hub.OpenStream(context.Background(), "shop")
	if err != nil {
		t.Fatal(err)
	}
	if second.OpenStreams() != 1 || first.OpenStreams() != 2 {
		t.Fatalf("expected the stream on the idle tunnel, got first=%d second=%d (stream %d)",
			first.OpenStreams(), second.OpenStreams(), stream.ID())
	}
}

func TestHubSkipsAClosedTunnel(t *testing.T) {
	hub := NewHub()
	dead, _ := pipeSession(t)
	live, _ := pipeSession(t)
	hub.RegisterTunnel("shop", 1, dead)
	hub.RegisterTunnel("shop", 2, live)
	_ = dead.Close()

	if _, err := hub.OpenStream(context.Background(), "shop"); err != nil {
		t.Fatalf("expected the live tunnel to take the stream, got %v", err)
	}
	if live.OpenStreams() != 1 {
		t.Fatalf("expected the stream on the live tunnel")
	}
}

func TestHubReplacesATunnelOnlyByItsOwnNumber(t *testing.T) {
	hub := NewHub()
	old, _ := pipeSession(t)
	other, _ := pipeSession(t)
	hub.RegisterTunnel("shop", 1, old)
	hub.RegisterTunnel("shop", 2, other)
	busy, err := old.OpenStream(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	replacement, _ := pipeSession(t)
	hub.RegisterTunnel("shop", 1, replacement)
	if got := hub.TunnelCount(); got != 2 {
		t.Fatalf("expected tunnel 1 replaced and tunnel 2 kept, got %d tunnels", got)
	}
	select {
	case <-other.Done():
		t.Fatal("a different tunnel number must not be closed")
	case <-old.Done():
		t.Fatal("the replaced tunnel was closed under its open stream")
	case <-time.After(300 * time.Millisecond):
	}
	// Once its stream finishes, the replaced tunnel goes.
	_ = busy.Close()
	select {
	case <-old.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("replaced tunnel never closed")
	}
}

func TestHubClosesAnOldConnectorsTunnelAtOnce(t *testing.T) {
	hub := NewHub()
	old, _ := pipeSession(t)
	hub.Register("shop", old)
	if _, err := old.OpenStream(context.Background()); err != nil {
		t.Fatal(err)
	}
	replacement, _ := pipeSession(t)
	hub.Register("shop", replacement)
	select {
	case <-old.Done():
	case <-time.After(time.Second):
		t.Fatal("an old connector's previous tunnel must close at once, as before")
	}
	if got := hub.TunnelCount(); got != 1 {
		t.Fatalf("expected one tunnel, got %d", got)
	}
}

func TestHubIdleReplacedTunnelClosesWithoutWaitingOutTheGrace(t *testing.T) {
	hub := NewHub()
	old, _ := pipeSession(t)
	hub.RegisterTunnel("shop", 1, old)
	replacement, _ := pipeSession(t)
	unregister := hub.RegisterTunnel("shop", 1, replacement)
	select {
	case <-old.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("an idle replaced tunnel should close promptly")
	}
	unregister()
	if hub.IsOnline("shop") {
		t.Fatal("expected the shop offline after its last tunnel left")
	}
}
