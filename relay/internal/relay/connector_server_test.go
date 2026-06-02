package relay

import (
	"context"
	"io"
	"log/slog"
	"net"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/observability"
	"pointy/relay/internal/protocol"
)

func TestConnectorServerMetricsTrackActiveConnector(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	store, provisioned := provisionRelayInstallation(t)
	hub := NewHub()
	metrics := observability.NewMetrics()
	presence := &recordingPresence{}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := ConnectorServer{
		Store:            store,
		Hub:              hub,
		Logger:           logger,
		Metrics:          metrics,
		Presence:         presence,
		NodeID:           "relay-node-a",
		NodeRelayURL:     "https://relay-a.internal",
		HandshakeTimeout: time.Second,
	}
	serverRaw, clientRaw := net.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		server.handleConn(ctx, serverRaw, logger)
	}()

	conn := protocol.NewConn(clientRaw)
	if err := conn.WriteFrame(protocol.Frame{
		Type:    protocol.FrameHello,
		Payload: []byte(provisioned.ConnectorToken),
	}); err != nil {
		t.Fatal(err)
	}
	frame, err := conn.ReadFrame()
	if err != nil {
		t.Fatal(err)
	}
	if frame.Type != protocol.FrameHelloAck {
		t.Fatalf("expected hello ack, got %d", frame.Type)
	}
	waitUntil(t, time.Second, func() bool {
		snapshot := metrics.Snapshot()
		return snapshot.ActiveConnectors == 1 &&
			snapshot.ConnectorConnectionsTotal == 1 &&
			hub.IsOnline(provisioned.Installation.ID) &&
			presence.relayHTTPURL() == "https://relay-a.internal"
	})

	_ = conn.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("connector server did not exit after client close")
	}
	snapshot := metrics.Snapshot()
	if snapshot.ActiveConnectors != 0 ||
		snapshot.ConnectorConnectionsTotal != 1 ||
		snapshot.ConnectorDisconnectsTotal != 1 {
		t.Fatalf("unexpected connector metrics %#v", snapshot)
	}
}

type recordingPresence struct {
	mu     sync.Mutex
	record ConnectorPresenceRecord
}

func (p *recordingPresence) MarkOnline(
	_ context.Context,
	record ConnectorPresenceRecord,
	_ time.Duration,
) (ConnectorPresenceLease, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.record = record
	return noopPresenceLease{}, nil
}

func (p *recordingPresence) Get(
	context.Context,
	string,
) (ConnectorPresenceRecord, bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.record, p.record.InstallationID != "", nil
}

func (p *recordingPresence) relayHTTPURL() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.record.RelayHTTPURL
}

type noopPresenceLease struct{}

func (noopPresenceLease) Refresh(context.Context) error {
	return nil
}

func (noopPresenceLease) Close(context.Context) error {
	return nil
}
