package observability

import (
	"strconv"
	"sync"
	"time"
)

type Metrics struct {
	mu sync.Mutex

	activeConnectors          int64
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
}

type Snapshot struct {
	ActiveConnectors           int64             `json:"active_connectors"`
	ConnectorConnectionsTotal  uint64            `json:"connector_connections_total"`
	ConnectorDisconnectsTotal  uint64            `json:"connector_disconnects_total"`
	RelayRequestsTotal         uint64            `json:"relay_requests_total"`
	RelayRequestLatencyTotalMS uint64            `json:"relay_request_latency_total_ms"`
	RelayRequestLatencyMaxMS   uint64            `json:"relay_request_latency_max_ms"`
	RelayRequestsByOutcome     map[string]uint64 `json:"relay_requests_by_outcome"`
	RelayRequestsByStatus      map[string]uint64 `json:"relay_requests_by_status"`
	TicketIssuanceTotal        uint64            `json:"ticket_issuance_total"`
	TicketRefreshTotal         uint64            `json:"ticket_refresh_total"`
	TicketIssuanceFailures     uint64            `json:"ticket_issuance_failures"`
	SubscriptionRejections     uint64            `json:"subscription_rejections"`
	OfflineInstallations       uint64            `json:"offline_installations"`
	BackendFailures            uint64            `json:"backend_failures"`
	RequestLimitRejections     uint64            `json:"request_limit_rejections"`
	RateLimitRejections        uint64            `json:"rate_limit_rejections"`
	RateLimitFailures          uint64            `json:"rate_limit_failures"`
	RequestBodyLimitRejections uint64            `json:"request_body_limit_rejections"`
	ResponseBodyLimitFailures  uint64            `json:"response_body_limit_failures"`
	CredentialRejections       uint64            `json:"credential_rejections"`
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
	if m == nil {
		return func() {}
	}
	m.mu.Lock()
	m.activeConnectors++
	m.connectorConnectionsTotal++
	m.mu.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			m.mu.Lock()
			if m.activeConnectors > 0 {
				m.activeConnectors--
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
		ActiveConnectors:           m.activeConnectors,
		ConnectorConnectionsTotal:  m.connectorConnectionsTotal,
		ConnectorDisconnectsTotal:  m.connectorDisconnectsTotal,
		RelayRequestsTotal:         m.relayRequestsTotal,
		RelayRequestLatencyTotalMS: m.relayRequestLatencyTotalMS,
		RelayRequestLatencyMaxMS:   m.relayRequestLatencyMaxMS,
		RelayRequestsByOutcome:     copyStringMap(m.relayRequestsByOutcome),
		RelayRequestsByStatus:      statuses,
		TicketIssuanceTotal:        m.ticketIssuanceTotal,
		TicketRefreshTotal:         m.ticketRefreshTotal,
		TicketIssuanceFailures:     m.ticketIssuanceFailures,
		SubscriptionRejections:     m.subscriptionRejections,
		OfflineInstallations:       m.offlineInstallations,
		BackendFailures:            m.backendFailures,
		RequestLimitRejections:     m.requestLimitRejections,
		RateLimitRejections:        m.rateLimitRejections,
		RateLimitFailures:          m.rateLimitFailures,
		RequestBodyLimitRejections: m.requestBodyLimitRejections,
		ResponseBodyLimitFailures:  m.responseBodyLimitFailures,
		CredentialRejections:       m.credentialRejections,
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
