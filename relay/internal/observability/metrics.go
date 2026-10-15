package observability

import (
	"strconv"
	"sync"
	"time"
)

type Metrics struct {
	mu sync.Mutex

	activeConnectors          int64
	activeConnectorsBy        map[string]int64
	connectorConnectionsTotal uint64
	connectorDisconnectsTotal uint64

	relayRequestsTotal         uint64
	relayRequestLatencyTotalMS uint64
	relayRequestLatencyMaxMS   uint64
	relayRequestsByOutcome     map[string]uint64
	relayRequestsByStatus      map[int]uint64

	ticketIssuanceTotal        uint64
	ticketRefreshTotal         uint64
	ticketIssuanceFailures     uint64
	subscriptionRejections     uint64
	offlineInstallations       uint64
	backendFailures            uint64
	requestLimitRejections     uint64
	rateLimitRejections        uint64
	rateLimitFailures          uint64
	requestBodyLimitRejections uint64
	responseBodyLimitFailures  uint64
	credentialRejections       uint64

	connectorHandshakeRejections map[string]uint64
	tunnelPlacements             map[string]uint64
	nodeHops                     map[string]uint64
	tunnelMoves                  map[string]uint64
	heldRequests                 map[string]uint64
	heldWaitTotalMS              uint64
	heldWaitMaxMS                uint64

	traffic traffic

	// SMS counters are labelled by outcome only. Which shop sends what lives
	// in the relay's SMS ledger; a per-installation label here would grow
	// with the fleet and duplicate it.
	smsSendsByOutcome      map[string]uint64
	smsDeliveriesByOutcome map[string]uint64
	smsChecksByOutcome     map[string]uint64
}

type Snapshot struct {
	ActiveConnectors int64 `json:"active_connectors"`
	// ActiveConnectorsByTransport splits ActiveConnectors by how the tunnel
	// arrived: "tcp" (the raw mTLS listener) or "websocket" (port 443 through
	// the balancer). The TCP count reaching zero is what tells us the legacy
	// listener can be retired.
	ActiveConnectorsByTransport map[string]int64  `json:"active_connectors_by_transport"`
	ConnectorConnectionsTotal   uint64            `json:"connector_connections_total"`
	ConnectorDisconnectsTotal   uint64            `json:"connector_disconnects_total"`
	RelayRequestsTotal          uint64            `json:"relay_requests_total"`
	RelayRequestLatencyTotalMS  uint64            `json:"relay_request_latency_total_ms"`
	RelayRequestLatencyMaxMS    uint64            `json:"relay_request_latency_max_ms"`
	RelayRequestsByOutcome      map[string]uint64 `json:"relay_requests_by_outcome"`
	RelayRequestsByStatus       map[string]uint64 `json:"relay_requests_by_status"`
	TicketIssuanceTotal         uint64            `json:"ticket_issuance_total"`
	TicketRefreshTotal          uint64            `json:"ticket_refresh_total"`
	TicketIssuanceFailures      uint64            `json:"ticket_issuance_failures"`
	SubscriptionRejections      uint64            `json:"subscription_rejections"`
	OfflineInstallations        uint64            `json:"offline_installations"`
	BackendFailures             uint64            `json:"backend_failures"`
	RequestLimitRejections      uint64            `json:"request_limit_rejections"`
	RateLimitRejections         uint64            `json:"rate_limit_rejections"`
	RateLimitFailures           uint64            `json:"rate_limit_failures"`
	RequestBodyLimitRejections  uint64            `json:"request_body_limit_rejections"`
	ResponseBodyLimitFailures   uint64            `json:"response_body_limit_failures"`
	CredentialRejections        uint64            `json:"credential_rejections"`
	// ConnectorHandshakeRejections counts failed connector handshakes by
	// reason. The connector port is internet-reachable, so scanners probe it
	// constantly; counting them here keeps the burst measurable without
	// putting a line per probe in the log.
	ConnectorHandshakeRejections map[string]uint64 `json:"connector_handshake_rejections"`
	// TunnelPlacements counts where this node sent arriving tunnels:
	// "stay", "redirect" (to a lighter node's own address) or "turn_away".
	TunnelPlacements map[string]uint64 `json:"tunnel_placements"`
	// NodeHops counts requests forwarded to the node holding the shop's
	// tunnel: "forwarded", "next_node" (the first node couldn't be reached
	// and the next was tried) and "unreachable" (no node could be).
	NodeHops map[string]uint64 `json:"node_hops"`
	// TunnelMoves counts the tunnels this node asked to move (GoAway), by
	// reason: "drain" (the node is shutting down) or "rebalance" (it held
	// more than its share).
	TunnelMoves map[string]uint64 `json:"tunnel_moves"`
	// HeldRequests counts requests that found no tunnel and waited for the
	// shop to reconnect, by how the wait ended: "served" (a tunnel came
	// back) or "offline" (answered 503 after the wait).
	HeldRequests    map[string]uint64 `json:"held_requests"`
	HeldWaitTotalMS uint64            `json:"held_wait_total_ms"`
	HeldWaitMaxMS   uint64            `json:"held_wait_max_ms"`
	// SMSSendsByOutcome counts POST /v1/sms/send answers by outcome ("sent",
	// "replayed", "insufficient_balance", "provider_credit", ...).
	SMSSendsByOutcome map[string]uint64 `json:"sms_sends_by_outcome"`
	// SMSDeliveriesByOutcome counts delivery reports the sent-log sync applied
	// ("delivered", "undelivered", "sent").
	SMSDeliveriesByOutcome map[string]uint64 `json:"sms_deliveries_by_outcome"`
	// SMSChecksByOutcome counts held messages the sent-log check settled:
	// "kept" (it went out after all), "refunded" (it never did) and "expired"
	// (refunded unchecked after the log could not be read for too long).
	SMSChecksByOutcome map[string]uint64 `json:"sms_checks_by_outcome"`
}

type RelayRequestObservation struct {
	Outcome    string
	StatusCode int
	Duration   time.Duration
}

func NewMetrics() *Metrics {
	return &Metrics{
		relayRequestsByOutcome: map[string]uint64{},
		relayRequestsByStatus:  map[int]uint64{},
	}
}

func (m *Metrics) ConnectorConnected() func() {
	return m.ConnectorConnectedVia("tcp")
}

// ConnectorConnectedVia counts a live tunnel under its transport and returns
// the release that uncounts it, once.
func (m *Metrics) ConnectorConnectedVia(transport string) func() {
	if m == nil {
		return func() {}
	}
	m.mu.Lock()
	m.activeConnectors++
	if m.activeConnectorsBy == nil {
		m.activeConnectorsBy = make(map[string]int64)
	}
	m.activeConnectorsBy[transport]++
	m.connectorConnectionsTotal++
	m.mu.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			m.mu.Lock()
			if m.activeConnectors > 0 {
				m.activeConnectors--
			}
			if m.activeConnectorsBy[transport] > 0 {
				m.activeConnectorsBy[transport]--
			}
			m.connectorDisconnectsTotal++
			m.mu.Unlock()
		})
	}
}

func (m *Metrics) RecordRelayRequest(observation RelayRequestObservation) {
	if m == nil {
		return
	}
	outcome := observation.Outcome
	if outcome == "" {
		outcome = "unknown"
	}
	statusCode := observation.StatusCode
	if statusCode == 0 {
		statusCode = 599
	}
	durationMS := uint64(observation.Duration.Milliseconds())

	m.mu.Lock()
	m.relayRequestsTotal++
	m.relayRequestLatencyTotalMS += durationMS
	if durationMS > m.relayRequestLatencyMaxMS {
		m.relayRequestLatencyMaxMS = durationMS
	}
	m.relayRequestsByOutcome[outcome]++
	m.relayRequestsByStatus[statusCode]++
	m.mu.Unlock()
}

func (m *Metrics) RecordTicketIssued() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.ticketIssuanceTotal++
	m.mu.Unlock()
}

func (m *Metrics) RecordTicketRefreshed() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.ticketRefreshTotal++
	m.mu.Unlock()
}

func (m *Metrics) RecordTicketIssueFailed() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.ticketIssuanceFailures++
	m.mu.Unlock()
}

func (m *Metrics) RecordSubscriptionRejected() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.subscriptionRejections++
	m.mu.Unlock()
}

func (m *Metrics) RecordOfflineInstallation() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.offlineInstallations++
	m.mu.Unlock()
}

func (m *Metrics) RecordBackendFailure() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.backendFailures++
	m.mu.Unlock()
}

func (m *Metrics) RecordRequestLimitRejected() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.requestLimitRejections++
	m.mu.Unlock()
}

func (m *Metrics) RecordRateLimitRejected() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.rateLimitRejections++
	m.mu.Unlock()
}

func (m *Metrics) RecordRateLimitFailed() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.rateLimitFailures++
	m.mu.Unlock()
}

func (m *Metrics) RecordRequestBodyLimitRejected() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.requestBodyLimitRejections++
	m.mu.Unlock()
}

func (m *Metrics) RecordResponseBodyLimitFailed() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.responseBodyLimitFailures++
	m.mu.Unlock()
}

func (m *Metrics) RecordCredentialRejected() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.credentialRejections++
	m.mu.Unlock()
}

func (m *Metrics) RecordConnectorHandshakeRejected(reason string) {
	if m == nil {
		return
	}
	m.mu.Lock()
	if m.connectorHandshakeRejections == nil {
		m.connectorHandshakeRejections = make(map[string]uint64)
	}
	m.connectorHandshakeRejections[reason]++
	m.mu.Unlock()
}

func (m *Metrics) RecordTunnelPlacement(outcome string) {
	if m != nil {
		m.countLabel(&m.tunnelPlacements, outcome)
	}
}

func (m *Metrics) RecordNodeHop(outcome string) {
	if m != nil {
		m.countLabel(&m.nodeHops, outcome)
	}
}

func (m *Metrics) RecordTunnelMove(reason string) {
	if m != nil {
		m.countLabel(&m.tunnelMoves, reason)
	}
}

// RecordHeldRequest counts a request that waited for the shop to reconnect.
func (m *Metrics) RecordHeldRequest(outcome string, waited time.Duration) {
	if m == nil {
		return
	}
	m.countLabel(&m.heldRequests, outcome)
	waitedMS := uint64(max(waited.Milliseconds(), 0))
	m.mu.Lock()
	m.heldWaitTotalMS += waitedMS
	m.heldWaitMaxMS = max(m.heldWaitMaxMS, waitedMS)
	m.mu.Unlock()
}

func (m *Metrics) countLabel(counters *map[string]uint64, label string) {
	m.mu.Lock()
	if *counters == nil {
		*counters = make(map[string]uint64)
	}
	(*counters)[label]++
	m.mu.Unlock()
}

func (m *Metrics) RecordSMSSend(outcome string) {
	if m == nil {
		return
	}
	if outcome == "" {
		outcome = "unknown"
	}
	m.mu.Lock()
	if m.smsSendsByOutcome == nil {
		m.smsSendsByOutcome = make(map[string]uint64)
	}
	m.smsSendsByOutcome[outcome]++
	m.mu.Unlock()
}

func (m *Metrics) RecordSMSDelivery(outcome string) {
	if m == nil {
		return
	}
	if outcome == "" {
		outcome = "unknown"
	}
	m.mu.Lock()
	if m.smsDeliveriesByOutcome == nil {
		m.smsDeliveriesByOutcome = make(map[string]uint64)
	}
	m.smsDeliveriesByOutcome[outcome]++
	m.mu.Unlock()
}

func (m *Metrics) RecordSMSCheck(outcome string) {
	if m == nil {
		return
	}
	if outcome == "" {
		outcome = "unknown"
	}
	m.mu.Lock()
	if m.smsChecksByOutcome == nil {
		m.smsChecksByOutcome = make(map[string]uint64)
	}
	m.smsChecksByOutcome[outcome]++
	m.mu.Unlock()
}

func (m *Metrics) Snapshot() Snapshot {
	if m == nil {
		return NewMetrics().Snapshot()
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	statuses := make(map[string]uint64, len(m.relayRequestsByStatus))
	for status, count := range m.relayRequestsByStatus {
		statuses[statusText(status)] = count
	}

	return Snapshot{
		ActiveConnectors:             m.activeConnectors,
		ActiveConnectorsByTransport:  copyInt64Map(m.activeConnectorsBy),
		ConnectorConnectionsTotal:    m.connectorConnectionsTotal,
		ConnectorDisconnectsTotal:    m.connectorDisconnectsTotal,
		RelayRequestsTotal:           m.relayRequestsTotal,
		RelayRequestLatencyTotalMS:   m.relayRequestLatencyTotalMS,
		RelayRequestLatencyMaxMS:     m.relayRequestLatencyMaxMS,
		RelayRequestsByOutcome:       copyStringMap(m.relayRequestsByOutcome),
		RelayRequestsByStatus:        statuses,
		TicketIssuanceTotal:          m.ticketIssuanceTotal,
		TicketRefreshTotal:           m.ticketRefreshTotal,
		TicketIssuanceFailures:       m.ticketIssuanceFailures,
		SubscriptionRejections:       m.subscriptionRejections,
		OfflineInstallations:         m.offlineInstallations,
		BackendFailures:              m.backendFailures,
		RequestLimitRejections:       m.requestLimitRejections,
		RateLimitRejections:          m.rateLimitRejections,
		RateLimitFailures:            m.rateLimitFailures,
		RequestBodyLimitRejections:   m.requestBodyLimitRejections,
		ResponseBodyLimitFailures:    m.responseBodyLimitFailures,
		CredentialRejections:         m.credentialRejections,
		ConnectorHandshakeRejections: copyStringMap(m.connectorHandshakeRejections),
		TunnelPlacements:             copyStringMap(m.tunnelPlacements),
		NodeHops:                     copyStringMap(m.nodeHops),
		TunnelMoves:                  copyStringMap(m.tunnelMoves),
		HeldRequests:                 copyStringMap(m.heldRequests),
		HeldWaitTotalMS:              m.heldWaitTotalMS,
		HeldWaitMaxMS:                m.heldWaitMaxMS,
		SMSSendsByOutcome:            copyStringMap(m.smsSendsByOutcome),
		SMSDeliveriesByOutcome:       copyStringMap(m.smsDeliveriesByOutcome),
		SMSChecksByOutcome:           copyStringMap(m.smsChecksByOutcome),
	}
}

func copyStringMap(source map[string]uint64) map[string]uint64 {
	copied := make(map[string]uint64, len(source))
	for key, value := range source {
		copied[key] = value
	}
	return copied
}

func statusText(status int) string {
	if status <= 0 {
		return "599"
	}
	return strconv.Itoa(status)
}

func copyInt64Map(source map[string]int64) map[string]int64 {
	copied := make(map[string]int64, len(source))
	for key, value := range source {
		copied[key] = value
	}
	return copied
}
