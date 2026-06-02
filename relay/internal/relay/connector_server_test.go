package relay

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"log/slog"
	"net"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/protocol"
	"pointy/relay/internal/security"
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

func TestConnectorServerRejectsNewConnectorWhileDraining(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := ConnectorServer{
		Hub:              NewHub(),
		Logger:           logger,
		Draining:         true,
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
		Payload: []byte("connector-token"),
	}); err != nil {
		t.Fatal(err)
	}
	frame, err := conn.ReadFrame()
	if err != nil {
		t.Fatal(err)
	}
	if frame.Type != protocol.FrameError ||
		string(frame.Payload) != "relay node is draining" {
		t.Fatalf("expected draining error frame, got type=%d payload=%q", frame.Type, string(frame.Payload))
	}
	_ = conn.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("connector server did not exit after draining rejection")
	}
}

func TestConnectorServerReplacesStaleSessionOnReconnect(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	store, provisioned := provisionRelayInstallation(t)
	hub := NewHub()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := ConnectorServer{
		Store:            store,
		Hub:              hub,
		Logger:           logger,
		Metrics:          observability.NewMetrics(),
		HandshakeTimeout: time.Second,
	}

	firstConn, firstServerDone := connectConnectorRaw(
		t,
		ctx,
		server,
		logger,
		provisioned.ConnectorToken,
	)
	defer firstConn.Close()
	waitUntil(t, time.Second, func() bool {
		return hub.IsOnline(provisioned.Installation.ID)
	})

	staleClosed := make(chan error, 1)
	go func() {
		_, err := firstConn.ReadFrame()
		staleClosed <- err
	}()

	secondConn, secondServerDone := connectConnectorRaw(
		t,
		ctx,
		server,
		logger,
		provisioned.ConnectorToken,
	)
	secondSession := protocol.NewSession(secondConn)
	secondClientDone := make(chan error, 1)
	go func() {
		secondClientDone <- secondSession.Run()
	}()
	defer secondSession.Close()

	select {
	case err := <-staleClosed:
		if err == nil {
			t.Fatal("expected stale connector session to close")
		}
	case <-time.After(time.Second):
		t.Fatal("stale connector session was not closed by replacement")
	}
	select {
	case <-firstServerDone:
	case <-time.After(time.Second):
		t.Fatal("first connector server session did not exit")
	}
	if !hub.IsOnline(provisioned.Installation.ID) {
		t.Fatal("replacement connector was removed when stale connector exited")
	}

	openCtx, openCancel := context.WithTimeout(ctx, time.Second)
	defer openCancel()
	relayStream, err := hub.OpenStream(openCtx, provisioned.Installation.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer relayStream.Close()

	acceptCtx, acceptCancel := context.WithTimeout(ctx, time.Second)
	defer acceptCancel()
	connectorStream, err := secondSession.Accept(acceptCtx)
	if err != nil {
		t.Fatal(err)
	}
	defer connectorStream.Close()
	if connectorStream.ID() != relayStream.ID() {
		t.Fatalf(
			"expected replacement connector stream %d, got %d",
			relayStream.ID(),
			connectorStream.ID(),
		)
	}

	_ = secondSession.Close()
	select {
	case <-secondClientDone:
	case <-time.After(time.Second):
		t.Fatal("second connector client session did not exit")
	}
	select {
	case <-secondServerDone:
	case <-time.After(time.Second):
		t.Fatal("second connector server session did not exit")
	}
}

func TestValidateConnectorCertificateRejectsRevokedFingerprint(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	rawCertificate := []byte("certificate-der")
	fingerprint := security.CertificateFingerprintSHA256(rawCertificate)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RevokeConnectorCertificateFingerprint(
		context.Background(),
		control.ConnectorCertificateRevocation{
			FingerprintSHA256: fingerprint,
			InstallationID:    "installation-1",
			Reason:            "compromised",
		},
	); err != nil {
		t.Fatal(err)
	}

	err = validateConnectorCertificateState(
		context.Background(),
		tls.ConnectionState{
			PeerCertificates: []*x509.Certificate{{Raw: rawCertificate}},
		},
		control.Installation{
			ID:                              "installation-1",
			ConnectorCertificateFingerprint: fingerprint,
		},
		now,
		store,
	)
	if !errors.Is(err, control.ErrConnectorCertificateRevoked) {
		t.Fatalf("expected revoked connector certificate error, got %v", err)
	}
}

func TestValidateConnectorCertificateAcceptsMatchingUnrevokedFingerprint(t *testing.T) {
	now := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	rawCertificate := []byte("certificate-der")
	fingerprint := security.CertificateFingerprintSHA256(rawCertificate)
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), testClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	expiresAt := now.Add(time.Hour)

	err = validateConnectorCertificateState(
		context.Background(),
		tls.ConnectionState{
			PeerCertificates: []*x509.Certificate{{Raw: rawCertificate}},
		},
		control.Installation{
			ID:                              "installation-1",
			ConnectorCertificateFingerprint: fingerprint,
			ConnectorCertificateExpiresAt:   &expiresAt,
		},
		now,
		store,
	)
	if err != nil {
		t.Fatalf("expected matching unrevoked connector certificate to validate: %v", err)
	}
}

func connectConnectorRaw(
	t *testing.T,
	ctx context.Context,
	server ConnectorServer,
	logger *slog.Logger,
	token string,
) (*protocol.Conn, <-chan struct{}) {
	t.Helper()
	serverRaw, clientRaw := net.Pipe()
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		server.handleConn(ctx, serverRaw, logger)
	}()

	if err := clientRaw.SetDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	conn := protocol.NewConn(clientRaw)
	if err := conn.WriteFrame(protocol.Frame{
		Type:    protocol.FrameHello,
		Payload: []byte(token),
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
	if err := clientRaw.SetDeadline(time.Time{}); err != nil {
		t.Fatal(err)
	}
	return conn, serverDone
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
