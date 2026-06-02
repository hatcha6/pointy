package relay

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/control"
)

const (
	AccessTokenHeader    = "X-Pointy-Relay-Token"
	RelayedRequestHeader = "X-Pointy-Relayed-Request"
)

type HTTPServer struct {
	Store                         control.InstallationStore
	Hub                           *Hub
	Logger                        *slog.Logger
	AdminToken                    string
	AllowOpenAdmin                bool
	RequireAdminClientCertificate bool
	StreamOpenTimeout             time.Duration
	Presence                      ConnectorPresence
	NodeID                        string
	Tickets                       control.RelayTicketService
	TicketTTL                     time.Duration
	Clock                         control.Clock
}

func (s HTTPServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if s.StreamOpenTimeout == 0 {
		s.StreamOpenTimeout = 5 * time.Second
	}
	switch {
	case r.URL.Path == "/healthz":
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	case r.URL.Path == "/readyz":
		writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
	case r.URL.Path == "/v1/relay-tickets" && r.Method == http.MethodPost:
		s.handleIssueRelayTicket(w, r)
	case r.URL.Path == "/v1/installations" && r.Method == http.MethodPost:
		s.withAdmin(w, r, s.handleProvisionInstallation)
	case strings.HasPrefix(r.URL.Path, "/v1/installations/"):
		s.withAdmin(w, r, s.handleInstallation)
	default:
		token, targetPath, ok := relayTarget(r)
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		s.handleRelay(w, r, token, targetPath)
	}
}

func (s HTTPServer) handleIssueRelayTicket(w http.ResponseWriter, r *http.Request) {
	if s.Tickets == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "relay ticket service unavailable"})
		return
	}

	rawToken := strings.TrimSpace(r.Header.Get(AccessTokenHeader))
	if rawToken == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token required"})
		return
	}
	installation, err := s.Store.ValidateAccessToken(r.Context(), rawToken)
	if err != nil {
		writeRelayCredentialError(w, err)
		return
	}

	var request control.RelayTicketRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil && !errors.Is(err, io.EOF) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	issued, err := s.Tickets.IssueTicket(r.Context(), installation, request, s.relayTicketTTL())
	if err != nil {
		s.logger().Error("relay ticket issue failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "relay ticket issue failed"})
		return
	}
	writeJSON(w, http.StatusCreated, issued)
}

func (s HTTPServer) handleProvisionInstallation(w http.ResponseWriter, r *http.Request) {
	var request control.ProvisionInstallationRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil && !errors.Is(err, io.EOF) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	provisioned, err := s.Store.ProvisionInstallation(r.Context(), request)
	if err != nil {
		s.logger().Error("relay installation provisioning failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "provisioning failed"})
		return
	}
	writeJSON(w, http.StatusCreated, provisioned)
}

func (s HTTPServer) handleInstallation(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/installations/"), "/")
	if len(parts) == 0 || parts[0] == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "installation not found"})
		return
	}
	id := parts[0]
	if len(parts) == 1 && r.Method == http.MethodGet {
		installation, err := s.Store.GetInstallation(r.Context(), id)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, installation)
		return
	}
	if len(parts) == 2 && parts[1] == "subscription" && r.Method == http.MethodPatch {
		var update control.SubscriptionUpdate
		if err := json.NewDecoder(r.Body).Decode(&update); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}
		installation, err := s.Store.UpdateSubscription(r.Context(), id, update)
		if err != nil {
			writeStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, installation)
		return
	}
	writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
}

func (s HTTPServer) handleRelay(
	w http.ResponseWriter,
	r *http.Request,
	rawToken string,
	targetPath string,
) {
	installation, err := s.validateRelayCredential(r.Context(), rawToken)
	if err != nil {
		writeRelayCredentialError(w, err)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), s.StreamOpenTimeout)
	defer cancel()
	stream, err := s.Hub.OpenStream(ctx, installation.ID)
	if err != nil {
		if errors.Is(err, ErrConnectorOffline) {
			s.writeConnectorOffline(w, r, installation.ID)
			return
		}
		s.logger().Warn("relay stream open failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "relay stream failed"})
		return
	}
	defer stream.Close()

	request := outboundRequest(r, targetPath)
	if err := request.Write(stream); err != nil {
		s.logger().Warn("relay request write failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "relay request failed"})
		return
	}

	response, err := http.ReadResponse(bufio.NewReader(stream), request)
	if err != nil {
		s.logger().Warn("relay response read failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "relay response failed"})
		return
	}
	defer response.Body.Close()
	copyHeader(w.Header(), response.Header)
	w.WriteHeader(response.StatusCode)
	if _, err := io.Copy(w, response.Body); err != nil {
		s.logger().Warn("relay response copy failed", "installation_id", installation.ID, "error", err)
	}
}

func (s HTTPServer) writeConnectorOffline(
	w http.ResponseWriter,
	r *http.Request,
	installationID string,
) {
	if s.Presence != nil {
		record, ok, err := s.Presence.Get(r.Context(), installationID)
		if err != nil {
			s.logger().Warn("relay connector presence lookup failed", "installation_id", installationID, "error", err)
		} else if ok && record.NodeID != "" && record.NodeID != s.NodeID {
			s.logger().Warn(
				"relay connector is attached to another relay node",
				"installation_id",
				installationID,
				"connector_node_id",
				record.NodeID,
				"relay_node_id",
				s.NodeID,
			)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "installation connector offline"})
			return
		}
	}
	writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "installation connector offline"})
}

func (s HTTPServer) validateRelayCredential(
	ctx context.Context,
	rawToken string,
) (control.Installation, error) {
	installation, err := s.Store.ValidateAccessToken(ctx, rawToken)
	if err == nil {
		return installation, nil
	}
	if s.Tickets == nil || !errors.Is(err, control.ErrWrongPurpose) {
		return control.Installation{}, err
	}

	ticket, ticketErr := s.Tickets.ValidateTicket(ctx, rawToken, s.clock().Now())
	if ticketErr != nil {
		return control.Installation{}, ticketErr
	}
	installation, err = s.Store.GetInstallation(ctx, ticket.InstallationID)
	if err != nil {
		return control.Installation{}, err
	}
	if !installation.RelayActive(s.clock().Now()) {
		return control.Installation{}, control.ErrSubscriptionInactive
	}
	return installation, nil
}

func (s HTTPServer) withAdmin(
	w http.ResponseWriter,
	r *http.Request,
	handler func(http.ResponseWriter, *http.Request),
) {
	if s.RequireAdminClientCertificate && !hasVerifiedClientCertificate(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "admin client certificate required"})
		return
	}
	if s.AdminToken == "" && !s.AllowOpenAdmin {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "admin token is not configured"})
		return
	}
	if s.AdminToken != "" && !constantTimeBearerTokenEqual(r.Header.Get("Authorization"), s.AdminToken) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "admin token required"})
		return
	}
	handler(w, r)
}

func hasVerifiedClientCertificate(r *http.Request) bool {
	return r.TLS != nil && len(r.TLS.PeerCertificates) > 0 && len(r.TLS.VerifiedChains) > 0
}

func outboundRequest(in *http.Request, targetPath string) *http.Request {
	request := in.Clone(in.Context())
	request.URL.Scheme = ""
	request.URL.Host = ""
	request.URL.Path = targetPath
	request.URL.RawPath = ""
	request.URL.RawQuery = in.URL.RawQuery
	request.RequestURI = ""
	request.Close = true
	request.Header = in.Header.Clone()
	request.Header.Del(AccessTokenHeader)
	request.Header.Del(RelayedRequestHeader)
	removeHopHeaders(request.Header)
	request.Header.Set("Connection", "close")
	request.Header.Set(RelayedRequestHeader, "1")
	request.Header.Set("X-Forwarded-Host", in.Host)
	if host, _, err := net.SplitHostPort(in.RemoteAddr); err == nil {
		appendForwardedFor(request.Header, host)
	}
	return request
}

func relayTarget(r *http.Request) (string, string, bool) {
	if token := strings.TrimSpace(r.Header.Get(AccessTokenHeader)); token != "" &&
		strings.HasPrefix(r.URL.Path, "/api/") {
		return token, r.URL.Path, true
	}

	trimmed := strings.TrimPrefix(r.URL.Path, "/")
	parts := strings.SplitN(trimmed, "/", 3)
	if len(parts) < 3 || parts[0] != "r" || parts[1] == "" {
		return "", "", false
	}
	parsed, err := control.ParseToken(parts[1])
	if err != nil || parsed.Purpose != control.TokenPurposeTicket {
		return "", "", false
	}
	if !strings.HasPrefix("/"+parts[2], "/api/") {
		return "", "", false
	}
	return parts[1], "/" + parts[2], true
}

func constantTimeBearerTokenEqual(headerValue string, expectedToken string) bool {
	const prefix = "Bearer "
	if !strings.HasPrefix(headerValue, prefix) {
		return false
	}
	candidate := strings.TrimPrefix(headerValue, prefix)
	return subtle.ConstantTimeCompare([]byte(candidate), []byte(expectedToken)) == 1
}

func copyHeader(dst, src http.Header) {
	for key, values := range src {
		for _, value := range values {
			dst.Add(key, value)
		}
	}
}

func removeHopHeaders(header http.Header) {
	for _, name := range strings.Split(header.Get("Connection"), ",") {
		if trimmed := strings.TrimSpace(name); trimmed != "" {
			header.Del(trimmed)
		}
	}
	for _, name := range []string{
		"Connection",
		"Keep-Alive",
		"Proxy-Authenticate",
		"Proxy-Authorization",
		"Te",
		"Trailer",
		"Transfer-Encoding",
		"Upgrade",
	} {
		header.Del(name)
	}
}

func appendForwardedFor(header http.Header, host string) {
	if prior := header.Get("X-Forwarded-For"); prior != "" {
		header.Set("X-Forwarded-For", prior+", "+host)
		return
	}
	header.Set("X-Forwarded-For", host)
}

func writeStoreError(w http.ResponseWriter, err error) {
	if errors.Is(err, control.ErrNotFound) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "installation not found"})
		return
	}
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "installation store failed"})
}

func writeRelayCredentialError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, control.ErrSubscriptionInactive):
		writeJSON(w, http.StatusPaymentRequired, map[string]string{"error": "relay subscription inactive"})
	case errors.Is(err, control.ErrInvalidToken),
		errors.Is(err, control.ErrWrongPurpose),
		errors.Is(err, control.ErrRelayTicketNotFound):
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token rejected"})
	default:
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token rejected"})
	}
}

func writeJSON(w http.ResponseWriter, statusCode int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(jsonSize(value)))
	w.WriteHeader(statusCode)
	_ = json.NewEncoder(w).Encode(value)
}

func jsonSize(value any) int {
	content, err := json.Marshal(value)
	if err != nil {
		return 0
	}
	return len(content) + 1
}

func (s HTTPServer) logger() *slog.Logger {
	if s.Logger != nil {
		return s.Logger
	}
	return slog.Default()
}

func (s HTTPServer) clock() control.Clock {
	if s.Clock != nil {
		return s.Clock
	}
	return control.RealClock{}
}

func (s HTTPServer) relayTicketTTL() time.Duration {
	if s.TicketTTL > 0 {
		return s.TicketTTL
	}
	return 15 * time.Minute
}
