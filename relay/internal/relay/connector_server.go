package relay

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"strings"
	"syscall"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/protocol"
	"pointy/relay/internal/security"
)

type ConnectorServer struct {
	Store                     control.InstallationStore
	Hub                       *Hub
	Logger                    *slog.Logger
	Metrics                   *observability.Metrics
	HandshakeTimeout          time.Duration
	Presence                  ConnectorPresence
	NodeID                    string
	NodeRelayURL              string
	Draining                  bool
	PresenceTTL               time.Duration
	PresenceHeartbeatInterval time.Duration
}

func (s ConnectorServer) Serve(ctx context.Context, listener net.Listener) error {
	if s.HandshakeTimeout == 0 {
		s.HandshakeTimeout = 10 * time.Second
	}
	logger := s.logger()
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go s.handleConn(ctx, conn, logger)
	}
}

func (s ConnectorServer) handleConn(ctx context.Context, raw net.Conn, logger *slog.Logger) {
	conn := protocol.NewConn(raw)
	_ = conn.SetDeadline(time.Now().Add(s.HandshakeTimeout))
	frame, err := conn.ReadFrame()
	if err != nil {
		reason, couldBeConnector := classifyHandshakeFailure(err)
		s.metrics().RecordConnectorHandshakeRejected(reason)
		// The connector port is reachable from the internet, so health checks
		// and vulnerability scanners probe it continuously. A probe that could
		// never have been one of our connectors is counted, not warned about —
		// otherwise the noise buries the handshake of a shop that really is
		// misconfigured.
		if couldBeConnector {
			logger.Warn(
				"relay connector handshake failed",
				"reason", reason,
				"remote_addr", remoteAddr(raw),
				"error", err,
			)
		} else {
			logger.Debug(
				"relay connector handshake probe ignored",
				"reason", reason,
				"remote_addr", remoteAddr(raw),
				"error", err,
			)
		}
		_ = conn.Close()
		return
	}
	if frame.Type != protocol.FrameHello {
		_ = protocol.WriteError(conn, "expected connector hello")
		_ = conn.Close()
		return
	}
	if s.Draining {
		_ = protocol.WriteError(conn, "relay node is draining")
		logger.Info("relay connector rejected because node is draining")
		_ = conn.Close()
		return
	}
	installation, err := s.Store.ValidateConnectorToken(ctx, string(frame.Payload))
	if err != nil {
		_ = protocol.WriteError(conn, "connector token rejected")
		logger.Warn("relay connector token rejected", "error", err)
		_ = conn.Close()
		return
	}
	if err := validateConnectorCertificate(ctx, raw, installation, time.Now().UTC(), s.Store); err != nil {
		_ = protocol.WriteError(conn, "connector certificate rejected")
		logger.Warn(
			"relay connector certificate rejected",
			"installation_id",
			installation.ID,
			"error",
			err,
		)
		_ = conn.Close()
		return
	}
	if err := conn.WriteFrame(protocol.Frame{Type: protocol.FrameHelloAck}); err != nil {
		logger.Warn("relay connector handshake ack failed", "installation_id", installation.ID, "error", err)
		_ = conn.Close()
		return
	}
	_ = conn.SetDeadline(time.Time{})

	session := protocol.NewSession(conn)
	unregister := s.Hub.Register(installation.ID, session)
	defer unregister()
	releaseMetrics := s.metrics().ConnectorConnected()
	defer releaseMetrics()
	stopPresence := s.startPresence(ctx, installation.ID, logger)
	defer stopPresence()
	if err := s.Store.MarkConnectorConnected(ctx, installation.ID, time.Now().UTC()); err != nil {
		logger.Warn("relay connector heartbeat update failed", "installation_id", installation.ID, "error", err)
	}
	logger.Info("relay connector connected", "installation_id", installation.ID)
	if err := session.Run(); err != nil {
		logger.Warn("relay connector disconnected with error", "installation_id", installation.ID, "error", err)
		return
	}
	logger.Info("relay connector disconnected", "installation_id", installation.ID)
}

// classifyHandshakeFailure names why a connector handshake never happened, and
// reports whether the peer could plausibly have been one of our connectors.
//
// Our connector is a Go client that speaks TLS 1.2+ and presents a client
// certificate, so a peer that hangs up without a byte, speaks something that
// isn't TLS, or offers only TLS 1.0/1.1 is definitionally not a connector — it
// is a probe. A missing or rejected client certificate is the ambiguous case: a
// scanner completing a handshake looks exactly like a shop whose certificate
// expired, so that one stays a warning.
func classifyHandshakeFailure(err error) (reason string, couldBeConnector bool) {
	switch {
	case errors.Is(err, io.EOF):
		// io.ReadFull returns a bare io.EOF only when it read nothing at all;
		// a truncated handshake surfaces as io.ErrUnexpectedEOF below.
		return "closed_before_handshake", false
	case errors.Is(err, syscall.ECONNRESET), errors.Is(err, syscall.EPIPE):
		return "reset_before_handshake", false
	case errors.As(err, new(tls.RecordHeaderError)):
		return "not_tls", false
	case strings.Contains(err.Error(), "unsupported versions"):
		// Go exposes no typed error for this; the scanners that trip it offer
		// SSLv3/TLS 1.0/1.1 against a listener with a TLS 1.2 floor.
		return "obsolete_tls_version", false
	case strings.Contains(err.Error(), "didn't provide a certificate"):
		return "missing_client_certificate", true
	case errors.Is(err, os.ErrDeadlineExceeded):
		return "handshake_timeout", true
	case errors.Is(err, io.ErrUnexpectedEOF):
		return "truncated_handshake", true
	default:
		return "handshake_error", true
	}
}

// remoteAddr is best-effort: under an L4 passthrough every connector shares the
// proxy's address, so this identifies the hop, not the shop.
func remoteAddr(conn net.Conn) string {
	addr := conn.RemoteAddr()
	if addr == nil {
		return ""
	}
	return addr.String()
}

func validateConnectorCertificate(
	ctx context.Context,
	raw net.Conn,
	installation control.Installation,
	now time.Time,
	revocations control.InstallationStore,
) error {
	if installation.ConnectorCertificateFingerprint == "" {
		return nil
	}
	tlsConn, ok := raw.(*tls.Conn)
	if !ok {
		return errors.New("connector certificate binding requires TLS")
	}
	state := tlsConn.ConnectionState()
	if len(state.PeerCertificates) == 0 {
		return errors.New("connector certificate is missing")
	}
	return validateConnectorCertificateState(ctx, state, installation, now, revocations)
}

func validateConnectorCertificateState(
	ctx context.Context,
	state tls.ConnectionState,
	installation control.Installation,
	now time.Time,
	revocations control.InstallationStore,
) error {
	if len(state.PeerCertificates) == 0 {
		return errors.New("connector certificate is missing")
	}
	certificate := state.PeerCertificates[0]
	fingerprint := security.CertificateFingerprintSHA256(certificate.Raw)
	if fingerprint != installation.ConnectorCertificateFingerprint {
		return errors.New("connector certificate fingerprint does not match installation")
	}
	if revoked, err := revocations.IsConnectorCertificateFingerprintRevoked(ctx, fingerprint); err != nil {
		return fmt.Errorf("connector certificate revocation check failed: %w", err)
	} else if revoked {
		return control.ErrConnectorCertificateRevoked
	}
	if control.ConnectorCertificateExpired(installation.ConnectorCertificateExpiresAt, now) {
		return errors.New("connector certificate binding is expired")
	}
	return nil
}

func (s ConnectorServer) startPresence(
	ctx context.Context,
	installationID string,
	logger *slog.Logger,
) func() {
	if s.Presence == nil {
		return func() {}
	}

	ttl := s.PresenceTTL
	if ttl == 0 {
		ttl = 45 * time.Second
	}
	interval := s.PresenceHeartbeatInterval
	if interval == 0 {
		interval = ttl / 3
	}
	if interval <= 0 {
		interval = 15 * time.Second
	}

	connectionID, err := newConnectionID()
	if err != nil {
		logger.Warn("relay connector presence id failed", "installation_id", installationID, "error", err)
		return func() {}
	}
	record := ConnectorPresenceRecord{
		InstallationID: installationID,
		NodeID:         s.NodeID,
		ConnectionID:   connectionID,
		RelayHTTPURL:   s.NodeRelayURL,
		ConnectedAt:    time.Now().UTC(),
	}
	lease, err := s.Presence.MarkOnline(ctx, record, ttl)
	if err != nil {
		logger.Warn("relay connector presence update failed", "installation_id", installationID, "error", err)
		return func() {}
	}

	presenceCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-presenceCtx.Done():
				return
			case <-ticker.C:
				if err := lease.Refresh(presenceCtx); err != nil {
					logger.Warn(
						"relay connector presence refresh failed",
						"installation_id",
						installationID,
						"error",
						err,
					)
				}
			}
		}
	}()

	return func() {
		cancel()
		<-done
		closeCtx, closeCancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer closeCancel()
		if err := lease.Close(closeCtx); err != nil {
			logger.Warn("relay connector presence cleanup failed", "installation_id", installationID, "error", err)
		}
	}
}

func (s ConnectorServer) logger() *slog.Logger {
	if s.Logger != nil {
		return s.Logger
	}
	return slog.Default()
}

func (s ConnectorServer) metrics() *observability.Metrics {
	if s.Metrics != nil {
		return s.Metrics
	}
	return nil
}
