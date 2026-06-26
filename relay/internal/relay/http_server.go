package relay

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/limit"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/ratelimit"
	"pointy/relay/internal/security"
)

const (
	AccessTokenHeader     = "X-Pointy-Relay-Token"
	RefreshTokenHeader    = "X-Pointy-Relay-Refresh-Token"
	RelayedRequestHeader  = "X-Pointy-Relayed-Request"
	NodeProxyTokenHeader  = "X-Pointy-Relay-Node-Token"
	NodeProxyMarkerHeader = "X-Pointy-Relay-Node-Proxy"
)

var adminConsoleTemplate = template.Must(template.New("relay-admin").Parse(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Pointy Relay Admin</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; background: #f6f7f9; color: #17202a; }
    main { max-width: 920px; margin: 0 auto; padding: 32px 20px 48px; }
    h1 { font-size: 28px; margin: 0 0 24px; }
    h2 { font-size: 18px; margin: 28px 0 12px; }
    form { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; background: #fff; border: 1px solid #d8dde4; padding: 20px; }
    label { display: grid; gap: 6px; font-size: 13px; font-weight: 600; }
    input, select, textarea { box-sizing: border-box; width: 100%; border: 1px solid #b8c0cc; border-radius: 6px; padding: 10px 12px; font: inherit; background: #fff; }
    textarea { min-height: 92px; resize: vertical; }
    button { border: 0; border-radius: 6px; padding: 11px 16px; font: inherit; font-weight: 700; background: #155eef; color: #fff; cursor: pointer; }
    pre { overflow: auto; background: #111827; color: #f9fafb; padding: 16px; border-radius: 6px; }
    .wide { grid-column: 1 / -1; }
    .actions { display: flex; justify-content: flex-end; align-items: center; }
    .notice { border-radius: 6px; padding: 12px 14px; margin-bottom: 16px; background: #e7f8ef; color: #11613a; }
    .error { border-radius: 6px; padding: 12px 14px; margin-bottom: 16px; background: #fdecec; color: #9f1c1c; }
    .meta { color: #5f6b7a; font-size: 13px; margin-top: 20px; }
    @media (max-width: 720px) { form { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
<main>
  <h1>Pointy Relay Admin</h1>
  {{if .Message}}<div class="notice">{{.Message}}</div>{{end}}
  {{if .Error}}<div class="error">{{.Error}}</div>{{end}}
  <form method="post" action="/admin/subscription">
    <input type="hidden" name="csrf_token" value="{{.CSRFToken}}">
    <label>Installation ID
      <input name="installation_id" autocomplete="off" required>
    </label>
    <label>Actor
      <input name="actor" autocomplete="off" required>
    </label>
    <label>Remote relay
      <select name="relay_enabled">
        <option value="keep">Keep current</option>
        <option value="true">Enabled</option>
        <option value="false">Disabled</option>
      </select>
    </label>
    <label>Subscription
      <select name="subscription_active">
        <option value="keep">Keep current</option>
        <option value="true">Active</option>
        <option value="false">Inactive</option>
      </select>
    </label>
    <label>AI entitlement
      <select name="ai_enabled">
        <option value="keep">Keep current</option>
        <option value="true">Enabled</option>
        <option value="false">Disabled</option>
      </select>
    </label>
    <label>Subscription end mode
      <select name="subscription_end_mode">
        <option value="keep">Keep current</option>
        <option value="clear">Clear end date</option>
      </select>
    </label>
    <label class="wide">Subscription ends at
      <input name="subscription_ends_at" placeholder="2026-12-31T23:59:59Z" autocomplete="off">
    </label>
    <label class="wide">Reason
      <textarea name="reason" required></textarea>
    </label>
    <div class="wide actions"><button type="submit">Save Subscription</button></div>
  </form>
  {{if .Installation}}
    <h2>Installation</h2>
    <pre>{{printf "%#v" .Installation}}</pre>
  {{end}}
  {{if .AuditEvent}}
    <h2>Audit Event</h2>
    <pre>{{printf "%#v" .AuditEvent}}</pre>
  {{end}}
  <p class="meta">Generated at {{.GeneratedAt}}</p>
</main>
</body>
</html>`))

var publicInvoiceTemplate = template.Must(template.New("public-invoice").Parse(`<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{.ShopName}} - {{.ReceiptNumber}}</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Tahoma, Arial, sans-serif; }
    body { margin: 0; background: #f5f7fa; color: #111827; }
    main { max-width: 760px; margin: 0 auto; padding: 28px 16px 44px; }
    .invoice { background: #fff; border: 1px solid #d8dee9; border-radius: 8px; overflow: hidden; }
    header { padding: 24px; border-bottom: 1px solid #e5e7eb; display: flex; align-items: center; gap: 16px; }
    header .heading { flex: 1; }
    .logo { width: 64px; height: 64px; object-fit: contain; border: 1px solid #e5e7eb; border-radius: 8px; background: #fff; padding: 4px; }
    h1 { margin: 0; font-size: 26px; }
    .muted { color: #5f6b7a; }
    .meta { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; padding: 18px 24px; border-bottom: 1px solid #e5e7eb; }
    .meta div { display: grid; gap: 4px; }
    .label { color: #6b7280; font-size: 12px; font-weight: 700; }
    .value { font-weight: 700; }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 12px 16px; border-bottom: 1px solid #eef1f5; text-align: right; }
    th { color: #4b5563; font-size: 12px; }
    .num { text-align: left; direction: ltr; white-space: nowrap; }
    .totals { display: grid; gap: 10px; padding: 18px 24px; margin-inline-start: auto; max-width: 340px; }
    .total-row { display: flex; justify-content: space-between; gap: 16px; }
    .grand { font-size: 20px; font-weight: 800; }
    footer { padding: 18px 24px 24px; border-top: 1px solid #e5e7eb; }
    .actions { display: flex; justify-content: flex-end; margin-top: 18px; }
    button { border: 0; border-radius: 6px; padding: 12px 18px; font: inherit; font-weight: 800; background: #0b6b64; color: #fff; cursor: pointer; }
    .credit { text-align: center; color: #6b7280; font-size: 12px; margin-top: 20px; }
    .credit strong { color: #0b6b64; }
    @media (max-width: 560px) {
      main { padding: 12px; }
      header, .meta, footer { padding-inline: 16px; }
      .meta { grid-template-columns: 1fr; }
      th, td { padding: 10px 12px; font-size: 13px; }
    }
    @media print {
      body { background: #fff; }
      main { padding: 0; max-width: none; }
      .invoice { border: 0; border-radius: 0; }
      .actions { display: none; }
    }
  </style>
</head>
<body>
<main>
  <section class="invoice">
    <header>
      {{if .ShopLogoSrc}}<img class="logo" src="{{.ShopLogoSrc}}" alt="">{{end}}
      <div class="heading">
        <h1>{{.ShopName}}</h1>
        {{if .ReceiptHeader}}<p class="muted">{{.ReceiptHeader}}</p>{{end}}
      </div>
    </header>
    <section class="meta">
      <div><span class="label">رقم الفاتورة</span><span class="value">{{.ReceiptNumber}}</span></div>
      <div><span class="label">الحالة</span><span class="value">{{.StatusLabel}}</span></div>
      <div><span class="label">تاريخ الإصدار</span><span class="value">{{.CreatedAt}}</span></div>
      {{if .CustomerName}}<div><span class="label">العميل</span><span class="value">{{.CustomerName}}</span></div>{{end}}
    </section>
    <table>
      <thead>
        <tr>
          <th>الصنف</th>
          <th class="num">الكمية</th>
          <th class="num">السعر</th>
          <th class="num">الإجمالي</th>
        </tr>
      </thead>
      <tbody>
        {{range .Lines}}
          <tr>
            <td>{{.DisplayName}}</td>
            <td class="num">{{.Quantity}}</td>
            <td class="num">{{.UnitPrice}}</td>
            <td class="num">{{.LineTotal}}</td>
          </tr>
        {{end}}
      </tbody>
    </table>
    <section class="totals">
      <div class="total-row"><span>المجموع الفرعي</span><span class="num">{{.Subtotal}}</span></div>
      <div class="total-row"><span>الخصم</span><span class="num">{{.DiscountTotal}}</span></div>
      <div class="total-row grand"><span>الإجمالي</span><span class="num">{{.Total}}</span></div>
    </section>
    {{if .ReceiptFooter}}<footer class="muted">{{.ReceiptFooter}}</footer>{{end}}
  </section>
  <div class="actions">
    <button type="button" id="save-pdf">حفظ كملف PDF</button>
  </div>
  <p class="credit">صُنع بحب بواسطة <strong>سمات</strong> · نظام Pointy</p>
</main>
<script>
document.getElementById('save-pdf').addEventListener('click', function () { window.print(); });
</script>
</body>
</html>`))

var publicInvoiceErrorTemplate = template.Must(template.New("public-invoice-error").Parse(`<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>الفاتورة غير متاحة</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Tahoma, Arial, sans-serif; }
    body { margin: 0; background: #f5f7fa; color: #111827; }
    main { max-width: 560px; margin: 0 auto; padding: 48px 16px; }
    section { background: #fff; border: 1px solid #d8dee9; border-radius: 8px; padding: 24px; }
    h1 { margin: 0 0 10px; font-size: 24px; }
    p { margin: 0; color: #5f6b7a; }
  </style>
</head>
<body>
<main>
  <section>
    <h1>الفاتورة غير متاحة</h1>
    <p>{{.Message}}</p>
  </section>
</main>
</body>
</html>`))

type HTTPServer struct {
	Store                         control.InstallationStore
	Hub                           *Hub
	Logger                        *slog.Logger
	RouteMode                     RouteMode
	AdminToken                    string
	AllowOpenAdmin                bool
	RequireAdminClientCertificate bool
	StreamOpenTimeout             time.Duration
	RelayRequestTimeout           time.Duration
	MaxRelayedRequestBodyBytes    int64
	MaxRelayedResponseBodyBytes   int64
	RelayLimiter                  *limit.Limiter
	RateLimiter                   ratelimit.Limiter
	RelayRequestRateLimit         ratelimit.Policy
	TicketIssueRateLimit          ratelimit.Policy
	TicketRefreshRateLimit        ratelimit.Policy
	Metrics                       *observability.Metrics
	Presence                      ConnectorPresence
	NodeID                        string
	Draining                      bool
	NodeProxyToken                string
	NodeProxyHTTPClient           *http.Client
	AllowInsecureNodeProxy        bool
	Tickets                       control.RelayTicketService
	TicketTTL                     time.Duration
	TicketRefreshTTL              time.Duration
	Clock                         control.Clock
	ConnectorCertificateIssuer    ConnectorCertificateIssuer
	ConnectorCertificateTTL       time.Duration
	// Relay-hosted AI (OpenRouter). The key and tier->model catalog live only
	// here so AI billing and model routing stay company-controlled.
	OpenRouterAPIKey  string
	OpenRouterBaseURL string
	AIModelTiers      map[string]string
	AIDefaultTier     string
	// AIRouterModel classifies prompt difficulty to auto-pick a tier; empty
	// falls back to the fast-tier model.
	AIRouterModel    string
	AIRequestTimeout time.Duration
	AIChatRateLimit  ratelimit.Policy
	AIHTTPClient     *http.Client
	// Vision/multimodal model used when a prompt carries attachments.
	AIVisionModel string
	// AIAudioModel handles turns carrying a recorded voice clip; empty falls back
	// to the vision model (which for Gemini-class multimodal models already
	// accepts audio).
	AIAudioModel string
	// AIWebSearchEnabled turns on OpenRouter's web-search plugin for user turns
	// whose query needs current/external info (decided by a cheap classifier, so it
	// fires only when necessary — never on the shop's own-data questions).
	// AIWebSearchMaxResults caps results per search (cost).
	AIWebSearchEnabled    bool
	AIWebSearchMaxResults int
	// Per-shop usage limits (fixed window, TTL-reset) + the image cap. Surfaced
	// to the app for the usage ring and enforced here.
	AILimit5H            ratelimit.Policy
	AILimitWeekly        ratelimit.Policy
	AIMaxImagesPerPrompt int
	AIMaxRequestBytes    int64
	// Relay-hosted product image search (Serper.dev). The key lives only here so
	// shops never manage one; gated on the remote-access entitlement
	// (subscription + relay_enabled) via ValidateAccessToken. Empty key disables
	// the endpoint.
	SerperAPIKey              string
	SerperBaseURL             string
	SerperImageLanguage       string
	SerperImageCountry        string
	ImageSearchRequestTimeout time.Duration
	ImageSearchHTTPClient     *http.Client
}

type RouteMode int

const (
	RouteAll RouteMode = iota
	RoutePublic
	RouteAdmin
)

func (m RouteMode) allowsPublic() bool {
	return m == RouteAll || m == RoutePublic
}

func (m RouteMode) allowsAdmin() bool {
	return m == RouteAll || m == RouteAdmin
}

type ConnectorCertificateIssuer interface {
	IssueClientCertificateFromCSR(csrPEM string, commonName string, ttl time.Duration, now time.Time) (security.IssuedCertificate, error)
}

type connectorCertificateRequest struct {
	CSRPem string `json:"csr_pem"`
}

type adminSubscriptionUpdateRequest struct {
	control.SubscriptionUpdate
	Actor  string `json:"actor,omitempty"`
	Reason string `json:"reason,omitempty"`
}

type adminSubscriptionResponse struct {
	Installation map[string]any          `json:"installation"`
	AuditEvent   control.AdminAuditEvent `json:"audit_event"`
}

type adminConsoleData struct {
	Message      string
	Error        string
	Installation map[string]any
	AuditEvent   *control.AdminAuditEvent
	GeneratedAt  time.Time
	CSRFToken    string
}

type publicInvoicePayload struct {
	ShopName        string                     `json:"shop_name"`
	ReceiptHeader   string                     `json:"receipt_header"`
	ReceiptFooter   string                     `json:"receipt_footer"`
	ShopLogoDataURI string                     `json:"shop_logo_data_uri"`
	ReceiptNumber   string                     `json:"receipt_number"`
	Status          string                     `json:"status"`
	CustomerName    string                     `json:"customer_name"`
	Lines           []publicInvoiceLinePayload `json:"lines"`
	Subtotal        string                     `json:"subtotal"`
	DiscountTotal   string                     `json:"discount_total"`
	Total           string                     `json:"total"`
	CreatedAt       string                     `json:"created_at"`
}

type publicInvoiceLinePayload struct {
	ProductName   string `json:"product_name"`
	VariantName   string `json:"variant_name"`
	Quantity      int    `json:"quantity"`
	UnitPrice     string `json:"unit_price"`
	LineSubtotal  string `json:"line_subtotal"`
	DiscountTotal string `json:"discount_total"`
	LineTotal     string `json:"line_total"`
}

type publicInvoiceViewData struct {
	publicInvoicePayload
	StatusLabel string
	Lines       []publicInvoiceLineViewData
	// Typed template.URL so html/template renders the validated data URI
	// instead of sanitizing it.
	ShopLogoSrc template.URL
}

type publicInvoiceLineViewData struct {
	publicInvoiceLinePayload
	DisplayName string
}

type publicInvoiceErrorData struct {
	Message string
}

func (s HTTPServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/healthz":
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	case r.URL.Path == "/readyz":
		if s.Draining {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "draining"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
	case r.URL.Path == "/v1/relay-tickets" && r.Method == http.MethodPost:
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handleIssueRelayTicket(w, r)
	case r.URL.Path == "/v1/relay-ticket-refresh" && r.Method == http.MethodPost:
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handleRefreshRelayTicket(w, r)
	case r.URL.Path == "/v1/ai/chat" && r.Method == http.MethodPost:
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handleAIChat(w, r)
	case r.URL.Path == "/v1/ai/usage" && r.Method == http.MethodGet:
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handleAIUsage(w, r)
	case r.URL.Path == "/v1/image-search" && r.Method == http.MethodPost:
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handleImageSearch(w, r)
	case r.URL.Path == "/v1/status" && r.Method == http.MethodGet:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleStatus)
	case r.URL.Path == "/v1/metrics" && r.Method == http.MethodGet:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleMetrics)
	case strings.HasPrefix(r.URL.Path, "/v1/node/relay/"):
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withNodeProxy(w, r, s.handleNodeRelay)
	case strings.HasPrefix(r.URL.Path, "/v1/node/public-invoices/"):
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withNodeProxy(w, r, s.handleNodePublicInvoice)
	case strings.HasPrefix(r.URL.Path, "/invoices/") && r.Method == http.MethodGet:
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handlePublicInvoice(w, r)
	case r.URL.Path == "/v1/installations" && r.Method == http.MethodGet:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleListInstallations)
	case r.URL.Path == "/v1/installations" && r.Method == http.MethodPost:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleProvisionInstallation)
	case strings.HasPrefix(r.URL.Path, "/v1/installations/"):
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleInstallation)
	case (r.URL.Path == "/admin" || r.URL.Path == "/admin/") && r.Method == http.MethodGet:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleAdminConsole)
	case r.URL.Path == "/admin/subscription" && r.Method == http.MethodPost:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleAdminSubscriptionForm)
	case r.URL.Path == "/v1/holidays" && r.Method == http.MethodGet:
		// Shops pull their calendar (globals + own) with an installation token.
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handleListHolidays(w, r)
	case r.URL.Path == "/v1/holidays" && r.Method == http.MethodPost:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleCreateHoliday)
	case strings.HasPrefix(r.URL.Path, "/v1/holidays/"):
		// Admin management: GET /v1/holidays/ (list all), PATCH/DELETE /v1/holidays/{id}.
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleHolidayByID)
	default:
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		token, targetPath, ok := relayTarget(r)
		if !ok {
			writeNotFound(w)
			return
		}
		s.handleRelay(w, r, token, targetPath)
	}
}

func (s HTTPServer) handleIssueRelayTicket(w http.ResponseWriter, r *http.Request) {
	if s.Tickets == nil {
		s.metrics().RecordTicketIssueFailed()
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "relay ticket service unavailable"})
		return
	}

	rawToken := strings.TrimSpace(r.Header.Get(AccessTokenHeader))
	if rawToken == "" {
		s.metrics().RecordCredentialRejected()
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token required"})
		return
	}

	var request control.RelayTicketRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil && !errors.Is(err, io.EOF) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	installation, err := s.Store.ValidateAccessToken(r.Context(), rawToken)
	if err != nil {
		s.recordCredentialError(err)
		writeRelayCredentialError(w, err)
		return
	}
	if limited, _, _ := s.enforceRateLimit(
		w,
		r,
		"ticket_issue",
		ticketIssueRateLimitKey(installation.ID, request.DeviceID),
		s.TicketIssueRateLimit,
	); limited {
		return
	}

	issued, err := s.Tickets.IssueTicket(
		r.Context(),
		installation,
		request,
		s.relayTicketTTL(),
		s.relayRefreshTTL(),
	)
	if err != nil {
		s.metrics().RecordTicketIssueFailed()
		s.logger().Error("relay ticket issue failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "relay ticket issue failed"})
		return
	}
	s.metrics().RecordTicketIssued()
	writeJSON(w, http.StatusCreated, issued)
}

func (s HTTPServer) handleRefreshRelayTicket(w http.ResponseWriter, r *http.Request) {
	if s.Tickets == nil {
		s.metrics().RecordTicketIssueFailed()
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "relay ticket service unavailable"})
		return
	}

	rawToken := strings.TrimSpace(r.Header.Get(RefreshTokenHeader))
	if rawToken == "" {
		s.metrics().RecordCredentialRejected()
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay refresh token required"})
		return
	}
	parsed, err := control.ParseToken(rawToken)
	if err != nil {
		s.recordCredentialError(err)
		writeRelayCredentialError(w, err)
		return
	}
	if parsed.Purpose != control.TokenPurposeRefresh {
		s.recordCredentialError(control.ErrWrongPurpose)
		writeRelayCredentialError(w, control.ErrWrongPurpose)
		return
	}
	var request control.RelayTicketRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil && !errors.Is(err, io.EOF) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if limited, _, _ := s.enforceRateLimit(
		w,
		r,
		"ticket_refresh",
		ticketRefreshRateLimitKey(rawToken),
		s.TicketRefreshRateLimit,
	); limited {
		return
	}

	refresh, err := s.Tickets.ConsumeRefreshToken(r.Context(), rawToken, s.clock().Now())
	if err != nil {
		s.recordCredentialError(err)
		writeRelayCredentialError(w, err)
		return
	}
	requestDeviceID := strings.TrimSpace(request.DeviceID)
	if refresh.DeviceID != "" && requestDeviceID != "" && requestDeviceID != refresh.DeviceID {
		s.recordCredentialError(control.ErrInvalidToken)
		writeRelayCredentialError(w, control.ErrInvalidToken)
		return
	}

	installation, err := s.Store.GetInstallation(r.Context(), refresh.InstallationID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if !installation.RelayActive(s.clock().Now()) {
		s.recordCredentialError(control.ErrSubscriptionInactive)
		writeRelayCredentialError(w, control.ErrSubscriptionInactive)
		return
	}

	issueRequest := control.RelayTicketRequest{
		DeviceID:   refresh.DeviceID,
		DeviceName: refresh.DeviceName,
	}
	if issueRequest.DeviceID == "" {
		issueRequest.DeviceID = requestDeviceID
	}
	if strings.TrimSpace(request.DeviceName) != "" {
		issueRequest.DeviceName = request.DeviceName
	}
	issued, err := s.Tickets.IssueTicket(
		r.Context(),
		installation,
		issueRequest,
		s.relayTicketTTL(),
		s.relayRefreshTTL(),
	)
	if err != nil {
		s.metrics().RecordTicketIssueFailed()
		s.logger().Error("relay ticket refresh failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "relay ticket refresh failed"})
		return
	}
	s.metrics().RecordTicketIssued()
	s.metrics().RecordTicketRefreshed()
	writeJSON(w, http.StatusCreated, issued)
}

func (s HTTPServer) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":       "ok",
		"node_id":      s.NodeID,
		"draining":     s.Draining,
		"generated_at": s.clock().Now(),
		"metrics":      s.metrics().Snapshot(),
		"limits": map[string]any{
			"stream_open_timeout":             s.streamOpenTimeout().String(),
			"relay_request_timeout":           s.relayRequestTimeout().String(),
			"max_relayed_request_body_bytes":  s.MaxRelayedRequestBodyBytes,
			"max_relayed_response_body_bytes": s.MaxRelayedResponseBodyBytes,
			"relay_request_rate_limit":        rateLimitStatus(s.RelayRequestRateLimit, s.RateLimiter != nil),
			"ticket_issue_rate_limit":         rateLimitStatus(s.TicketIssueRateLimit, s.RateLimiter != nil),
			"ticket_refresh_rate_limit":       rateLimitStatus(s.TicketRefreshRateLimit, s.RateLimiter != nil),
		},
	})
}

func (s HTTPServer) handleMetrics(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.metrics().Snapshot())
}

func (s HTTPServer) handleNodeRelay(w http.ResponseWriter, r *http.Request) {
	rawToken := strings.TrimSpace(r.Header.Get(AccessTokenHeader))
	if rawToken == "" {
		s.metrics().RecordCredentialRejected()
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token required"})
		return
	}
	targetPath := "/" + strings.TrimPrefix(r.URL.Path, "/v1/node/relay/")
	if !strings.HasPrefix(targetPath, "/api/") {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}
	s.handleRelayWithOptions(w, r, rawToken, targetPath, relayOptions{
		AllowNodeProxy: false,
	})
}

func (s HTTPServer) handlePublicInvoice(w http.ResponseWriter, r *http.Request) {
	installationID, invoiceToken, ok := publicInvoiceTarget(r.URL.Path, "/invoices/")
	if !ok {
		writeNotFound(w)
		return
	}
	s.handlePublicInvoiceTarget(w, r, installationID, invoiceToken, true)
}

func (s HTTPServer) handleNodePublicInvoice(w http.ResponseWriter, r *http.Request) {
	installationID, invoiceToken, ok := publicInvoiceTarget(
		r.URL.Path,
		"/v1/node/public-invoices/",
	)
	if !ok {
		writeNotFound(w)
		return
	}
	s.handlePublicInvoiceTarget(w, r, installationID, invoiceToken, false)
}

func (s HTTPServer) handlePublicInvoiceTarget(
	w http.ResponseWriter,
	r *http.Request,
	installationID string,
	invoiceToken string,
	allowNodeProxy bool,
) {
	startedAt := time.Now()
	statusCode := 0
	outcome := "unknown"
	defer func() {
		s.metrics().RecordRelayRequest(observability.RelayRequestObservation{
			Outcome:    outcome,
			StatusCode: statusCode,
			Duration:   time.Since(startedAt),
		})
	}()

	installation, err := s.Store.GetInstallation(r.Context(), installationID)
	if err != nil {
		statusCode = http.StatusNotFound
		outcome = "public_invoice_not_found"
		s.renderPublicInvoiceError(
			w,
			http.StatusNotFound,
			"تحقق من رابط الفاتورة أو اطلب نسخة جديدة من المتجر.",
		)
		return
	}
	if !installation.RelayActive(s.clock().Now()) {
		statusCode = http.StatusNotFound
		outcome = "subscription_rejected"
		s.metrics().RecordSubscriptionRejected()
		s.renderPublicInvoiceError(
			w,
			http.StatusNotFound,
			"هذه الفاتورة غير متاحة عبر الإنترنت حاليًا.",
		)
		return
	}
	if limited, limitStatus, limitOutcome := s.enforceRateLimit(
		w,
		r,
		"public_invoice",
		relayRequestRateLimitKey(installation.ID),
		s.RelayRequestRateLimit,
	); limited {
		statusCode = limitStatus
		outcome = limitOutcome
		return
	}

	release, ok := limit.TryAcquire(s.RelayLimiter)
	if !ok {
		statusCode = http.StatusTooManyRequests
		outcome = "request_limited"
		s.metrics().RecordRequestLimitRejected()
		s.renderPublicInvoiceError(
			w,
			http.StatusTooManyRequests,
			"الخدمة مشغولة الآن. حاول مرة أخرى بعد قليل.",
		)
		return
	}
	defer release()

	requestCtx, requestCancel := context.WithTimeout(r.Context(), s.relayRequestTimeout())
	defer requestCancel()
	openCtx, openCancel := context.WithTimeout(requestCtx, s.streamOpenTimeout())
	stream, err := s.Hub.OpenStream(openCtx, installation.ID)
	openCancel()
	if err != nil {
		if errors.Is(err, ErrConnectorOffline) {
			if allowNodeProxy {
				if proxied, proxyStatus, proxyOutcome := s.tryProxyPublicInvoiceToRemoteNode(
					w,
					r.WithContext(requestCtx),
					installation.ID,
					invoiceToken,
				); proxied {
					statusCode = proxyStatus
					outcome = proxyOutcome
					return
				}
			}
			statusCode = http.StatusServiceUnavailable
			outcome = "connector_offline"
			s.metrics().RecordOfflineInstallation()
			s.renderPublicInvoiceError(
				w,
				http.StatusServiceUnavailable,
				"تعذر الوصول إلى المتجر الآن. حاول مرة أخرى لاحقًا.",
			)
			return
		}
		statusCode = http.StatusBadGateway
		outcome = "stream_open_failed"
		s.logger().Warn("public invoice stream open failed", "installation_id", installation.ID, "error", err)
		s.renderPublicInvoiceError(
			w,
			http.StatusBadGateway,
			"تعذر تحميل الفاتورة الآن.",
		)
		return
	}
	defer stream.Close()
	stopDeadlineCloser := closeStreamOnContextDone(requestCtx, stream)
	defer stopDeadlineCloser()

	targetPath := "/api/public-invoices/" + url.PathEscape(invoiceToken) + "/"
	request := outboundRequest(r.WithContext(requestCtx), targetPath)
	request.URL.RawQuery = ""
	request.Header.Del("Authorization")
	request.Header.Del("Cookie")
	request.Header.Del("X-CSRFToken")
	request.Header.Set("Accept", "application/json")
	if err := request.Write(stream); err != nil {
		if requestCtx.Err() != nil {
			statusCode = http.StatusGatewayTimeout
			outcome = "request_timeout"
			s.renderPublicInvoiceError(
				w,
				http.StatusGatewayTimeout,
				"استغرق تحميل الفاتورة وقتًا أطول من المتوقع.",
			)
			return
		}
		statusCode = http.StatusBadGateway
		outcome = "request_write_failed"
		s.logger().Warn("public invoice request write failed", "installation_id", installation.ID, "error", err)
		s.renderPublicInvoiceError(
			w,
			http.StatusBadGateway,
			"تعذر طلب الفاتورة من المتجر.",
		)
		return
	}

	response, err := http.ReadResponse(bufio.NewReader(stream), request)
	if err != nil {
		if requestCtx.Err() != nil {
			statusCode = http.StatusGatewayTimeout
			outcome = "response_timeout"
			s.renderPublicInvoiceError(
				w,
				http.StatusGatewayTimeout,
				"استغرق تحميل الفاتورة وقتًا أطول من المتوقع.",
			)
			return
		}
		statusCode = http.StatusBadGateway
		outcome = "backend_failure"
		s.metrics().RecordBackendFailure()
		s.logger().Warn("public invoice response read failed", "installation_id", installation.ID, "error", err)
		s.renderPublicInvoiceError(
			w,
			http.StatusBadGateway,
			"تعذر قراءة استجابة المتجر.",
		)
		return
	}
	defer response.Body.Close()

	content, tooLarge, err := readResponseBodyWithinLimit(
		response.Body,
		s.MaxRelayedResponseBodyBytes,
	)
	if err != nil {
		if requestCtx.Err() != nil {
			statusCode = http.StatusGatewayTimeout
			outcome = "response_timeout"
			s.renderPublicInvoiceError(
				w,
				http.StatusGatewayTimeout,
				"استغرق تحميل الفاتورة وقتًا أطول من المتوقع.",
			)
			return
		}
		statusCode = http.StatusBadGateway
		outcome = "backend_failure"
		s.metrics().RecordBackendFailure()
		s.logger().Warn("public invoice response body read failed", "installation_id", installation.ID, "error", err)
		s.renderPublicInvoiceError(
			w,
			http.StatusBadGateway,
			"تعذر تحميل بيانات الفاتورة.",
		)
		return
	}
	if tooLarge {
		statusCode = http.StatusBadGateway
		outcome = "response_body_too_large"
		s.metrics().RecordResponseBodyLimitFailed()
		s.renderPublicInvoiceError(
			w,
			http.StatusBadGateway,
			"بيانات الفاتورة أكبر من الحد المسموح.",
		)
		return
	}
	if response.StatusCode != http.StatusOK {
		statusCode = response.StatusCode
		outcome = "public_invoice_unavailable"
		if response.StatusCode >= 500 {
			s.metrics().RecordBackendFailure()
		}
		renderStatus := http.StatusNotFound
		if response.StatusCode >= 500 {
			renderStatus = http.StatusBadGateway
		}
		s.renderPublicInvoiceError(
			w,
			renderStatus,
			"تحقق من رابط الفاتورة أو اطلب نسخة جديدة من المتجر.",
		)
		return
	}

	var invoice publicInvoicePayload
	if err := json.Unmarshal(content, &invoice); err != nil {
		statusCode = http.StatusBadGateway
		outcome = "backend_failure"
		s.metrics().RecordBackendFailure()
		s.logger().Warn("public invoice JSON decode failed", "installation_id", installation.ID, "error", err)
		s.renderPublicInvoiceError(
			w,
			http.StatusBadGateway,
			"تعذر قراءة بيانات الفاتورة.",
		)
		return
	}
	statusCode = http.StatusOK
	outcome = "public_invoice_rendered"
	s.renderPublicInvoice(w, invoice)
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
	writeJSON(w, http.StatusCreated, provisionedInstallationPayload(provisioned, s.clock().Now()))
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
		writeJSON(w, http.StatusOK, adminInstallationPayload(installation, s.clock().Now()))
		return
	}
	if len(parts) == 2 && parts[1] == "status" && r.Method == http.MethodGet {
		s.handleInstallationStatus(w, r, id)
		return
	}
	if len(parts) == 2 && parts[1] == "connector-certificate" && r.Method == http.MethodPost {
		s.handleIssueConnectorCertificate(w, r, id)
		return
	}
	if len(parts) == 2 && parts[1] == "audit-events" && r.Method == http.MethodGet {
		s.handleInstallationAuditEvents(w, r, id)
		return
	}
	if len(parts) == 2 && parts[1] == "subscription" && r.Method == http.MethodPatch {
		var request adminSubscriptionUpdateRequest
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&request); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}
		installation, event, err := s.updateAdminSubscription(
			r.Context(),
			id,
			request.SubscriptionUpdate,
			adminActor(r, request.Actor),
			adminReason(r, request.Reason),
		)
		if err != nil {
			writeAdminSubscriptionError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, adminSubscriptionResponse{
			Installation: adminInstallationPayload(installation, s.clock().Now()),
			AuditEvent:   event,
		})
		return
	}
	writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
}

func (s HTTPServer) holidayStore(w http.ResponseWriter) (control.HolidayStore, bool) {
	store, ok := s.Store.(control.HolidayStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "holiday store unavailable"})
		return nil, false
	}
	return store, true
}

// handleListHolidays serves a shop's calendar (global rows + that installation's
// own), authenticated with the installation access token like the other public
// endpoints.
func (s HTTPServer) handleListHolidays(w http.ResponseWriter, r *http.Request) {
	store, ok := s.holidayStore(w)
	if !ok {
		return
	}
	rawToken := strings.TrimSpace(r.Header.Get(AccessTokenHeader))
	if rawToken == "" {
		s.metrics().RecordCredentialRejected()
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token required"})
		return
	}
	installation, err := s.Store.ValidateAccessToken(r.Context(), rawToken)
	if err != nil {
		s.recordCredentialError(err)
		writeRelayCredentialError(w, err)
		return
	}
	holidays, err := store.ListHolidays(r.Context(), installation.ID)
	if err != nil {
		s.logger().Error("list holidays failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "holiday store failed"})
		return
	}
	writeJSON(w, http.StatusOK, holidayListResponse(holidays))
}

func (s HTTPServer) handleCreateHoliday(w http.ResponseWriter, r *http.Request) {
	store, ok := s.holidayStore(w)
	if !ok {
		return
	}
	holiday, err := decodeHolidayBody(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	holiday.ID = "" // server-assigned on create
	created, err := store.CreateHoliday(r.Context(), holiday)
	if err != nil {
		s.logger().Error("create holiday failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "holiday store failed"})
		return
	}
	writeJSON(w, http.StatusCreated, created)
}

// handleHolidayByID dispatches the admin-only operations under /v1/holidays/:
// GET /v1/holidays/ lists every row, PATCH/DELETE /v1/holidays/{id} edits one.
func (s HTTPServer) handleHolidayByID(w http.ResponseWriter, r *http.Request) {
	store, ok := s.holidayStore(w)
	if !ok {
		return
	}
	id := strings.Trim(strings.TrimPrefix(r.URL.Path, "/v1/holidays/"), "/")
	if id == "" {
		if r.Method == http.MethodGet {
			holidays, err := store.ListAllHolidays(r.Context())
			if err != nil {
				s.logger().Error("list all holidays failed", "error", err)
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "holiday store failed"})
				return
			}
			writeJSON(w, http.StatusOK, holidayListResponse(holidays))
			return
		}
		writeNotFound(w)
		return
	}
	switch r.Method {
	case http.MethodPatch:
		holiday, err := decodeHolidayBody(r)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		holiday.ID = id
		updated, err := store.UpdateHoliday(r.Context(), holiday)
		if err != nil {
			writeHolidayStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, updated)
	case http.MethodDelete:
		if err := store.DeleteHoliday(r.Context(), id); err != nil {
			writeHolidayStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
	default:
		writeNotFound(w)
	}
}

func decodeHolidayBody(r *http.Request) (control.Holiday, error) {
	// Defaults applied before decode so an omitted flag means "on".
	holiday := control.Holiday{ShowInDashboard: true, Active: true, SpanDays: 1}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&holiday); err != nil {
		return control.Holiday{}, fmt.Errorf("invalid request body")
	}
	holiday.Key = strings.TrimSpace(holiday.Key)
	holiday.RuleType = strings.TrimSpace(holiday.RuleType)
	if holiday.Key == "" {
		return control.Holiday{}, fmt.Errorf("key is required")
	}
	switch holiday.RuleType {
	case "fixed", "nth_weekday", "range":
	default:
		return control.Holiday{}, fmt.Errorf("rule_type must be fixed, nth_weekday, or range")
	}
	if holiday.RuleType == "range" {
		if holiday.StartDate == nil || holiday.EndDate == nil {
			return control.Holiday{}, fmt.Errorf("range holidays require start_date and end_date")
		}
		start, err := time.Parse("2006-01-02", *holiday.StartDate)
		if err != nil {
			return control.Holiday{}, fmt.Errorf("start_date must be YYYY-MM-DD")
		}
		end, err := time.Parse("2006-01-02", *holiday.EndDate)
		if err != nil {
			return control.Holiday{}, fmt.Errorf("end_date must be YYYY-MM-DD")
		}
		if end.Before(start) {
			return control.Holiday{}, fmt.Errorf("end_date must be on or after start_date")
		}
	}
	if holiday.SpanDays <= 0 {
		holiday.SpanDays = 1
	}
	return holiday, nil
}

func writeHolidayStoreError(w http.ResponseWriter, err error) {
	if errors.Is(err, control.ErrHolidayNotFound) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "holiday not found"})
		return
	}
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "holiday store failed"})
}

func holidayListResponse(holidays []control.Holiday) map[string]any {
	if holidays == nil {
		holidays = []control.Holiday{}
	}
	return map[string]any{"holidays": holidays}
}

func (s HTTPServer) handleListInstallations(w http.ResponseWriter, r *http.Request) {
	adminStore, ok := s.Store.(control.AdminSubscriptionStore)
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "relay admin installation store unavailable"})
		return
	}
	filter := control.InstallationFilter{Query: strings.TrimSpace(r.URL.Query().Get("query"))}
	if rawLimit := strings.TrimSpace(r.URL.Query().Get("limit")); rawLimit != "" {
		parsed, err := strconv.Atoi(rawLimit)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid limit"})
			return
		}
		filter.Limit = parsed
	}
	if rawActive := strings.TrimSpace(r.URL.Query().Get("subscription_active")); rawActive != "" {
		active, err := strconv.ParseBool(rawActive)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid subscription_active"})
			return
		}
		filter.SubscriptionActive = &active
	}
	installations, err := adminStore.ListInstallations(r.Context(), filter)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	now := s.clock().Now()
	payloads := make([]map[string]any, 0, len(installations))
	for _, installation := range installations {
		payloads = append(payloads, adminInstallationPayload(installation, now))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"installations": payloads,
		"count":         len(payloads),
	})
}

func (s HTTPServer) handleInstallationAuditEvents(
	w http.ResponseWriter,
	r *http.Request,
	id string,
) {
	adminStore, ok := s.Store.(control.AdminSubscriptionStore)
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "relay admin audit store unavailable"})
		return
	}
	limit := 50
	if rawLimit := strings.TrimSpace(r.URL.Query().Get("limit")); rawLimit != "" {
		parsed, err := strconv.Atoi(rawLimit)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid limit"})
			return
		}
		limit = parsed
	}
	events, err := adminStore.ListAdminAuditEvents(r.Context(), id, limit)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"installation_id": id,
		"events":          events,
	})
}

func (s HTTPServer) handleAdminConsole(w http.ResponseWriter, r *http.Request) {
	setAdminConsoleHeaders(w.Header())
	w.WriteHeader(http.StatusOK)
	_ = adminConsoleTemplate.Execute(w, adminConsoleData{
		GeneratedAt: s.clock().Now(),
		CSRFToken:   s.adminCSRFToken(s.clock().Now()),
	})
}

func (s HTTPServer) handleAdminSubscriptionForm(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		s.renderAdminConsole(w, http.StatusBadRequest, adminConsoleData{
			Error:       "Invalid form submission.",
			GeneratedAt: s.clock().Now(),
		})
		return
	}
	if !s.validAdminCSRFToken(r.FormValue("csrf_token"), s.clock().Now()) {
		s.renderAdminConsole(w, http.StatusForbidden, adminConsoleData{
			Error:       "Invalid admin form token.",
			GeneratedAt: s.clock().Now(),
		})
		return
	}
	id := strings.TrimSpace(r.FormValue("installation_id"))
	update, err := subscriptionUpdateFromForm(r)
	if err != nil {
		s.renderAdminConsole(w, http.StatusBadRequest, adminConsoleData{
			Error:       err.Error(),
			GeneratedAt: s.clock().Now(),
		})
		return
	}
	installation, event, err := s.updateAdminSubscription(
		r.Context(),
		id,
		update,
		r.FormValue("actor"),
		r.FormValue("reason"),
	)
	if err != nil {
		s.renderAdminConsole(w, adminSubscriptionErrorStatus(err), adminConsoleData{
			Error:       err.Error(),
			GeneratedAt: s.clock().Now(),
		})
		return
	}
	s.renderAdminConsole(w, http.StatusOK, adminConsoleData{
		Message:      "Subscription update saved.",
		Installation: adminInstallationPayload(installation, s.clock().Now()),
		AuditEvent:   &event,
		GeneratedAt:  s.clock().Now(),
	})
}

func (s HTTPServer) renderAdminConsole(
	w http.ResponseWriter,
	statusCode int,
	data adminConsoleData,
) {
	if data.GeneratedAt.IsZero() {
		data.GeneratedAt = s.clock().Now()
	}
	if data.CSRFToken == "" {
		data.CSRFToken = s.adminCSRFToken(data.GeneratedAt)
	}
	setAdminConsoleHeaders(w.Header())
	w.WriteHeader(statusCode)
	_ = adminConsoleTemplate.Execute(w, data)
}

func setAdminConsoleHeaders(header http.Header) {
	header.Set("Content-Type", "text/html; charset=utf-8")
	header.Set("Cache-Control", "no-store")
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set(
		"Content-Security-Policy",
		"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
	)
}

func publicInvoiceTarget(path string, prefix string) (string, string, bool) {
	if !strings.HasPrefix(path, prefix) {
		return "", "", false
	}
	trimmed := strings.Trim(strings.TrimPrefix(path, prefix), "/")
	parts := strings.Split(trimmed, "/")
	if len(parts) != 2 {
		return "", "", false
	}
	installationID, err := url.PathUnescape(parts[0])
	if err != nil {
		return "", "", false
	}
	invoiceToken, err := url.PathUnescape(parts[1])
	if err != nil {
		return "", "", false
	}
	installationID = strings.TrimSpace(installationID)
	invoiceToken = strings.TrimSpace(invoiceToken)
	if installationID == "" || invoiceToken == "" {
		return "", "", false
	}
	if strings.Contains(installationID, "/") || strings.Contains(invoiceToken, "/") {
		return "", "", false
	}
	return installationID, invoiceToken, true
}

// publicInvoiceLogoSrc only trusts embedded raster image data URIs; anything
// else renders no logo at all.
func publicInvoiceLogoSrc(dataURI string) template.URL {
	if strings.HasPrefix(dataURI, "data:image/png;base64,") ||
		strings.HasPrefix(dataURI, "data:image/jpeg;base64,") ||
		strings.HasPrefix(dataURI, "data:image/webp;base64,") {
		return template.URL(dataURI)
	}
	return ""
}

func (s HTTPServer) renderPublicInvoice(
	w http.ResponseWriter,
	payload publicInvoicePayload,
) {
	data := publicInvoiceViewData{
		publicInvoicePayload: payload,
		StatusLabel:          publicInvoiceStatusLabel(payload.Status),
		Lines:                publicInvoiceLineViewDataList(payload.Lines),
		ShopLogoSrc:          publicInvoiceLogoSrc(payload.ShopLogoDataURI),
	}
	setPublicInvoiceHeaders(w.Header(), true)
	w.WriteHeader(http.StatusOK)
	_ = publicInvoiceTemplate.Execute(w, data)
}

func (s HTTPServer) renderPublicInvoiceError(
	w http.ResponseWriter,
	statusCode int,
	message string,
) {
	setPublicInvoiceHeaders(w.Header(), false)
	w.WriteHeader(statusCode)
	_ = publicInvoiceErrorTemplate.Execute(w, publicInvoiceErrorData{
		Message: message,
	})
}

func setPublicInvoiceHeaders(header http.Header, allowScript bool) {
	header.Set("Content-Type", "text/html; charset=utf-8")
	header.Set("Cache-Control", "no-store")
	header.Set("X-Content-Type-Options", "nosniff")
	csp := "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"
	if allowScript {
		csp = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"
	}
	header.Set("Content-Security-Policy", csp)
}

func publicInvoiceStatusLabel(status string) string {
	switch strings.TrimSpace(status) {
	case "paid":
		return "مدفوعة"
	case "void":
		return "ملغاة"
	case "open":
		return "مفتوحة"
	default:
		return status
	}
}

func publicInvoiceLineViewDataList(
	lines []publicInvoiceLinePayload,
) []publicInvoiceLineViewData {
	rendered := make([]publicInvoiceLineViewData, 0, len(lines))
	for _, line := range lines {
		name := strings.TrimSpace(line.VariantName)
		if name == "" {
			name = strings.TrimSpace(line.ProductName)
		}
		rendered = append(rendered, publicInvoiceLineViewData{
			publicInvoiceLinePayload: line,
			DisplayName:              name,
		})
	}
	return rendered
}

func (s HTTPServer) updateAdminSubscription(
	ctx context.Context,
	id string,
	update control.SubscriptionUpdate,
	actor string,
	reason string,
) (control.Installation, control.AdminAuditEvent, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return control.Installation{}, control.AdminAuditEvent{}, adminValidationError("installation id is required")
	}
	actor = truncateAdminText(strings.TrimSpace(actor), 120)
	if actor == "" {
		return control.Installation{}, control.AdminAuditEvent{}, adminValidationError("actor is required")
	}
	reason = truncateAdminText(strings.TrimSpace(reason), 500)
	if reason == "" {
		return control.Installation{}, control.AdminAuditEvent{}, adminValidationError("reason is required")
	}
	if !subscriptionUpdateHasChange(update) {
		return control.Installation{}, control.AdminAuditEvent{}, adminValidationError("at least one subscription field is required")
	}
	if update.ClearEnd && update.SubscriptionEndsAt != nil {
		return control.Installation{}, control.AdminAuditEvent{}, adminValidationError("clear_subscription_end cannot be combined with subscription_ends_at")
	}
	adminStore, ok := s.Store.(control.AdminSubscriptionStore)
	if !ok {
		return control.Installation{}, control.AdminAuditEvent{}, errAdminAuditUnavailable
	}
	return adminStore.UpdateSubscriptionWithAudit(
		ctx,
		id,
		update,
		control.AdminAuditMetadata{
			Action: "subscription.updated",
			Actor:  actor,
			Reason: reason,
		},
	)
}

func adminActor(r *http.Request, bodyActor string) string {
	if strings.TrimSpace(bodyActor) != "" {
		return bodyActor
	}
	return r.Header.Get("X-Pointy-Admin-Actor")
}

func adminReason(r *http.Request, bodyReason string) string {
	if strings.TrimSpace(bodyReason) != "" {
		return bodyReason
	}
	return r.Header.Get("X-Pointy-Admin-Reason")
}

func subscriptionUpdateHasChange(update control.SubscriptionUpdate) bool {
	return update.RelayEnabled != nil ||
		update.AIEnabled != nil ||
		update.SubscriptionActive != nil ||
		update.SubscriptionEndsAt != nil ||
		update.ClearEnd
}

func adminInstallationPayload(
	installation control.Installation,
	now time.Time,
) map[string]any {
	return map[string]any{
		"id":                                installation.ID,
		"business_id":                       installation.BusinessID,
		"shop_name":                         installation.ShopName,
		"relay_enabled":                     installation.RelayEnabled,
		"subscription_active":               installation.SubscriptionActive,
		"subscription_ends_at":              installation.SubscriptionEndsAt,
		"ai_enabled":                        installation.AIEnabled,
		"relay_active":                      installation.RelayActive(now),
		"created_at":                        installation.CreatedAt,
		"updated_at":                        installation.UpdatedAt,
		"last_connector_connected_at":       installation.LastConnectorConnectedAt,
		"connector_certificate_fingerprint": installation.ConnectorCertificateFingerprint,
		"connector_certificate_serial":      installation.ConnectorCertificateSerial,
		"connector_certificate_expires_at":  installation.ConnectorCertificateExpiresAt,
	}
}

func provisionedInstallationPayload(
	provisioned control.ProvisionedInstallation,
	now time.Time,
) map[string]any {
	return map[string]any{
		"installation":    adminInstallationPayload(provisioned.Installation, now),
		"connector_token": provisioned.ConnectorToken,
		"access_token":    provisioned.AccessToken,
	}
}

func subscriptionUpdateFromForm(r *http.Request) (control.SubscriptionUpdate, error) {
	var update control.SubscriptionUpdate
	if value, set, err := optionalBoolFormValue(r, "relay_enabled"); err != nil {
		return control.SubscriptionUpdate{}, err
	} else if set {
		update.RelayEnabled = &value
	}
	if value, set, err := optionalBoolFormValue(r, "subscription_active"); err != nil {
		return control.SubscriptionUpdate{}, err
	} else if set {
		update.SubscriptionActive = &value
	}
	if value, set, err := optionalBoolFormValue(r, "ai_enabled"); err != nil {
		return control.SubscriptionUpdate{}, err
	} else if set {
		update.AIEnabled = &value
	}
	update.ClearEnd = r.FormValue("subscription_end_mode") == "clear"
	if rawEndsAt := strings.TrimSpace(r.FormValue("subscription_ends_at")); rawEndsAt != "" {
		endsAt, err := time.Parse(time.RFC3339, rawEndsAt)
		if err != nil {
			return control.SubscriptionUpdate{}, adminValidationError("subscription end must be RFC3339")
		}
		endsAt = endsAt.UTC()
		update.SubscriptionEndsAt = &endsAt
	}
	return update, nil
}

func optionalBoolFormValue(
	r *http.Request,
	name string,
) (bool, bool, error) {
	raw := strings.TrimSpace(r.FormValue(name))
	if raw == "" || raw == "keep" {
		return false, false, nil
	}
	switch raw {
	case "true":
		return true, true, nil
	case "false":
		return false, true, nil
	default:
		return false, false, adminValidationError(name + " must be true, false, or keep")
	}
}

func truncateAdminText(value string, limit int) string {
	if limit <= 0 {
		return ""
	}
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}

func (s HTTPServer) adminCSRFToken(now time.Time) string {
	return adminCSRFTokenForSecret(adminCSRFSecret(s.AdminToken), now)
}

func (s HTTPServer) validAdminCSRFToken(rawToken string, now time.Time) bool {
	token := strings.TrimSpace(rawToken)
	if token == "" {
		return false
	}
	secret := adminCSRFSecret(s.AdminToken)
	for _, candidateTime := range []time.Time{now, now.Add(-time.Hour)} {
		expected := adminCSRFTokenForSecret(secret, candidateTime)
		if subtle.ConstantTimeCompare([]byte(token), []byte(expected)) == 1 {
			return true
		}
	}
	return false
}

func adminCSRFSecret(adminToken string) string {
	adminToken = strings.TrimSpace(adminToken)
	if adminToken == "" {
		return "pointy-relay-open-admin-development"
	}
	return adminToken
}

func adminCSRFTokenForSecret(secret string, now time.Time) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte("pointy-relay-admin-form:"))
	_, _ = mac.Write([]byte(now.UTC().Format("2006010215")))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (s HTTPServer) handleInstallationStatus(w http.ResponseWriter, r *http.Request, id string) {
	installation, err := s.Store.GetInstallation(r.Context(), id)
	if err != nil {
		writeStoreError(w, err)
		return
	}

	var presence map[string]any
	if s.Presence != nil {
		record, ok, err := s.Presence.Get(r.Context(), id)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "connector presence lookup failed"})
			return
		}
		if ok {
			presence = map[string]any{
				"online":         true,
				"node_id":        record.NodeID,
				"connection_id":  record.ConnectionID,
				"relay_http_url": record.RelayHTTPURL,
				"connected_at":   record.ConnectedAt,
				"refreshed_at":   record.RefreshedAt,
				"expires_at":     record.ExpiresAt,
			}
		}
	}
	if presence == nil {
		presence = map[string]any{"online": false}
	}

	var certificateExpiresInSeconds any
	if installation.ConnectorCertificateExpiresAt != nil {
		certificateExpiresInSeconds = int64(installation.ConnectorCertificateExpiresAt.Sub(s.clock().Now()).Seconds())
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"installation_id":                          installation.ID,
		"shop_name":                                installation.ShopName,
		"relay_active":                             installation.RelayActive(s.clock().Now()),
		"relay_enabled":                            installation.RelayEnabled,
		"subscription_active":                      installation.SubscriptionActive,
		"subscription_ends_at":                     installation.SubscriptionEndsAt,
		"connector_online_local":                   s.Hub != nil && s.Hub.IsOnline(installation.ID),
		"connector_presence":                       presence,
		"last_connector_connected_at":              installation.LastConnectorConnectedAt,
		"connector_certificate_fingerprint_sha256": installation.ConnectorCertificateFingerprint,
		"connector_certificate_serial":             installation.ConnectorCertificateSerial,
		"connector_certificate_expires_at":         installation.ConnectorCertificateExpiresAt,
		"connector_certificate_expires_in_seconds": certificateExpiresInSeconds,
	})
}

func (s HTTPServer) handleIssueConnectorCertificate(
	w http.ResponseWriter,
	r *http.Request,
	id string,
) {
	installation, err := s.Store.GetInstallation(r.Context(), id)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if s.ConnectorCertificateIssuer == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "connector certificate issuer unavailable"})
		return
	}
	var request connectorCertificateRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if strings.TrimSpace(request.CSRPem) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "connector CSR is required"})
		return
	}
	issued, err := s.ConnectorCertificateIssuer.IssueClientCertificateFromCSR(
		request.CSRPem,
		"pointy-connector-"+installation.ID,
		s.connectorCertificateTTL(),
		s.clock().Now(),
	)
	if err != nil {
		s.logger().Error("connector certificate issue failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "connector certificate issue failed"})
		return
	}
	installation, err = s.Store.SetConnectorCertificate(r.Context(), installation.ID, control.ConnectorCertificateMetadata{
		FingerprintSHA256: issued.FingerprintSHA256,
		SerialNumber:      issued.SerialNumber,
		ExpiresAt:         issued.ExpiresAt,
	})
	if err != nil {
		s.logger().Error("connector certificate metadata save failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "connector certificate save failed"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"installation_id":    installation.ID,
		"certificate_pem":    issued.CertificatePEM,
		"ca_certificate_pem": issued.CACertificatePEM,
		"fingerprint_sha256": issued.FingerprintSHA256,
		"serial_number":      issued.SerialNumber,
		"expires_at":         issued.ExpiresAt,
	})
}

type relayOptions struct {
	AllowNodeProxy bool
}

func (s HTTPServer) handleRelay(
	w http.ResponseWriter,
	r *http.Request,
	rawToken string,
	targetPath string,
) {
	s.handleRelayWithOptions(w, r, rawToken, targetPath, relayOptions{
		AllowNodeProxy: true,
	})
}

func (s HTTPServer) handleRelayWithOptions(
	w http.ResponseWriter,
	r *http.Request,
	rawToken string,
	targetPath string,
	options relayOptions,
) {
	startedAt := time.Now()
	statusCode := 0
	outcome := "unknown"
	defer func() {
		s.metrics().RecordRelayRequest(observability.RelayRequestObservation{
			Outcome:    outcome,
			StatusCode: statusCode,
			Duration:   time.Since(startedAt),
		})
	}()

	installation, err := s.validateRelayCredential(r.Context(), rawToken)
	if err != nil {
		statusCode = relayCredentialStatusCode(err)
		outcome = relayCredentialOutcome(err)
		s.recordCredentialError(err)
		writeRelayCredentialError(w, err)
		return
	}
	if limited, limitStatus, limitOutcome := s.enforceRateLimit(
		w,
		r,
		"relay_request",
		relayRequestRateLimitKey(installation.ID),
		s.RelayRequestRateLimit,
	); limited {
		statusCode = limitStatus
		outcome = limitOutcome
		return
	}

	release, ok := limit.TryAcquire(s.RelayLimiter)
	if !ok {
		statusCode = http.StatusTooManyRequests
		outcome = "request_limited"
		s.metrics().RecordRequestLimitRejected()
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "relay request limit reached"})
		return
	}
	defer release()

	if s.relayedRequestBodyTooLarge(w, r) {
		statusCode = http.StatusRequestEntityTooLarge
		outcome = "request_body_too_large"
		return
	}

	requestCtx, requestCancel := context.WithTimeout(r.Context(), s.relayRequestTimeout())
	defer requestCancel()
	openCtx, openCancel := context.WithTimeout(requestCtx, s.streamOpenTimeout())
	stream, err := s.Hub.OpenStream(openCtx, installation.ID)
	openCancel()
	if err != nil {
		if errors.Is(err, ErrConnectorOffline) {
			if options.AllowNodeProxy {
				if proxied, proxyStatus, proxyOutcome := s.tryProxyRelayToRemoteNode(
					w,
					r.WithContext(requestCtx),
					installation.ID,
					targetPath,
				); proxied {
					statusCode = proxyStatus
					outcome = proxyOutcome
					return
				}
			}
			statusCode = http.StatusServiceUnavailable
			outcome = "connector_offline"
			s.writeConnectorOffline(w, r, installation.ID)
			return
		}
		statusCode = http.StatusBadGateway
		outcome = "stream_open_failed"
		s.logger().Warn("relay stream open failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "relay stream failed"})
		return
	}
	defer stream.Close()
	stopDeadlineCloser := closeStreamOnContextDone(requestCtx, stream)
	defer stopDeadlineCloser()

	request := outboundRequest(r.WithContext(requestCtx), targetPath)
	if maxBytes := s.MaxRelayedRequestBodyBytes; maxBytes > 0 && request.Body != nil {
		request.Body = http.MaxBytesReader(w, request.Body, maxBytes)
	}
	if err := request.Write(stream); err != nil {
		if requestCtx.Err() != nil {
			statusCode = http.StatusGatewayTimeout
			outcome = "request_timeout"
			s.logger().Warn("relay request timed out while writing", "installation_id", installation.ID, "error", requestCtx.Err())
			writeJSON(w, http.StatusGatewayTimeout, map[string]string{"error": "relay request timed out"})
			return
		}
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			statusCode = http.StatusRequestEntityTooLarge
			outcome = "request_body_too_large"
			s.metrics().RecordRequestBodyLimitRejected()
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "relay request body too large"})
			return
		}
		statusCode = http.StatusBadGateway
		outcome = "request_write_failed"
		s.logger().Warn("relay request write failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "relay request failed"})
		return
	}

	response, err := http.ReadResponse(bufio.NewReader(stream), request)
	if err != nil {
		if requestCtx.Err() != nil {
			statusCode = http.StatusGatewayTimeout
			outcome = "response_timeout"
			s.logger().Warn("relay response timed out", "installation_id", installation.ID, "error", requestCtx.Err())
			writeJSON(w, http.StatusGatewayTimeout, map[string]string{"error": "relay response timed out"})
			return
		}
		statusCode = http.StatusBadGateway
		outcome = "backend_failure"
		s.metrics().RecordBackendFailure()
		s.logger().Warn("relay response read failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "relay response failed"})
		return
	}
	defer response.Body.Close()
	if maxBytes := s.MaxRelayedResponseBodyBytes; maxBytes > 0 {
		content, tooLarge, err := readResponseBodyWithinLimit(response.Body, maxBytes)
		if err != nil {
			if requestCtx.Err() != nil {
				statusCode = http.StatusGatewayTimeout
				outcome = "response_timeout"
				s.logger().Warn("relay response timed out while reading body", "installation_id", installation.ID, "error", requestCtx.Err())
				writeJSON(w, http.StatusGatewayTimeout, map[string]string{"error": "relay response timed out"})
				return
			}
			statusCode = http.StatusBadGateway
			outcome = "backend_failure"
			s.metrics().RecordBackendFailure()
			s.logger().Warn("relay response body read failed", "installation_id", installation.ID, "error", err)
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "relay response failed"})
			return
		}
		if tooLarge {
			statusCode = http.StatusBadGateway
			outcome = "response_body_too_large"
			s.metrics().RecordResponseBodyLimitFailed()
			s.logger().Warn("relay backend response exceeded body limit", "installation_id", installation.ID, "limit_bytes", maxBytes)
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "relay response body too large"})
			return
		}
		statusCode = response.StatusCode
		outcome = "relayed"
		if response.StatusCode >= 500 {
			s.metrics().RecordBackendFailure()
		}
		copyHeader(w.Header(), response.Header)
		w.WriteHeader(response.StatusCode)
		if _, err := w.Write(content); err != nil {
			s.logger().Warn("relay response copy failed", "installation_id", installation.ID, "error", err)
		}
		return
	}
	statusCode = response.StatusCode
	outcome = "relayed"
	if response.StatusCode >= 500 {
		s.metrics().RecordBackendFailure()
	}
	copyHeader(w.Header(), response.Header)
	w.WriteHeader(response.StatusCode)
	if _, err := io.Copy(w, response.Body); err != nil {
		s.logger().Warn("relay response copy failed", "installation_id", installation.ID, "error", err)
	}
}

func (s HTTPServer) relayedRequestBodyTooLarge(w http.ResponseWriter, r *http.Request) bool {
	limitBytes := s.MaxRelayedRequestBodyBytes
	if limitBytes <= 0 || r.ContentLength < 0 {
		return false
	}
	if r.ContentLength <= limitBytes {
		return false
	}
	s.metrics().RecordRequestBodyLimitRejected()
	writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "relay request body too large"})
	return true
}

func (s HTTPServer) writeConnectorOffline(
	w http.ResponseWriter,
	r *http.Request,
	installationID string,
) {
	s.metrics().RecordOfflineInstallation()
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

func (s HTTPServer) tryProxyRelayToRemoteNode(
	w http.ResponseWriter,
	r *http.Request,
	installationID string,
	targetPath string,
) (bool, int, string) {
	if strings.TrimSpace(s.NodeProxyToken) == "" ||
		s.Presence == nil ||
		strings.TrimSpace(r.Header.Get(NodeProxyMarkerHeader)) != "" {
		return false, 0, ""
	}

	record, ok, err := s.Presence.Get(r.Context(), installationID)
	if err != nil {
		s.logger().Warn("relay connector presence lookup failed", "installation_id", installationID, "error", err)
		return false, 0, ""
	}
	if !ok ||
		strings.TrimSpace(record.NodeID) == "" ||
		record.NodeID == s.NodeID ||
		strings.TrimSpace(record.RelayHTTPURL) == "" {
		return false, 0, ""
	}

	endpoint, err := nodeRelayEndpoint(
		record.RelayHTTPURL,
		targetPath,
		r.URL.RawQuery,
		s.AllowInsecureNodeProxy,
	)
	if err != nil {
		s.logger().Warn(
			"relay connector remote node URL rejected",
			"installation_id",
			installationID,
			"connector_node_id",
			record.NodeID,
			"error",
			err,
		)
		return false, 0, ""
	}

	request := r.Clone(r.Context())
	request.URL = endpoint
	request.RequestURI = ""
	request.Host = endpoint.Host
	request.Header = r.Header.Clone()
	removeHopHeaders(request.Header)
	request.Header.Set(NodeProxyMarkerHeader, "1")
	request.Header.Set(NodeProxyTokenHeader, strings.TrimSpace(s.NodeProxyToken))

	response, err := s.nodeProxyHTTPClient().Do(request)
	if err != nil {
		s.logger().Warn(
			"relay remote node proxy failed",
			"installation_id",
			installationID,
			"connector_node_id",
			record.NodeID,
			"error",
			err,
		)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "installation connector offline"})
		return true, http.StatusServiceUnavailable, "node_proxy_failed"
	}
	defer response.Body.Close()

	copyHeader(w.Header(), response.Header)
	w.WriteHeader(response.StatusCode)
	if _, err := io.Copy(w, response.Body); err != nil {
		s.logger().Warn(
			"relay remote node proxy response copy failed",
			"installation_id",
			installationID,
			"connector_node_id",
			record.NodeID,
			"error",
			err,
		)
	}
	return true, response.StatusCode, "node_proxied"
}

func (s HTTPServer) tryProxyPublicInvoiceToRemoteNode(
	w http.ResponseWriter,
	r *http.Request,
	installationID string,
	invoiceToken string,
) (bool, int, string) {
	if strings.TrimSpace(s.NodeProxyToken) == "" ||
		s.Presence == nil ||
		strings.TrimSpace(r.Header.Get(NodeProxyMarkerHeader)) != "" {
		return false, 0, ""
	}

	record, ok, err := s.Presence.Get(r.Context(), installationID)
	if err != nil {
		s.logger().Warn("public invoice connector presence lookup failed", "installation_id", installationID, "error", err)
		return false, 0, ""
	}
	if !ok ||
		strings.TrimSpace(record.NodeID) == "" ||
		record.NodeID == s.NodeID ||
		strings.TrimSpace(record.RelayHTTPURL) == "" {
		return false, 0, ""
	}

	endpoint, err := nodePublicInvoiceEndpoint(
		record.RelayHTTPURL,
		installationID,
		invoiceToken,
		s.AllowInsecureNodeProxy,
	)
	if err != nil {
		s.logger().Warn(
			"public invoice remote node URL rejected",
			"installation_id",
			installationID,
			"connector_node_id",
			record.NodeID,
			"error",
			err,
		)
		return false, 0, ""
	}

	request := r.Clone(r.Context())
	request.URL = endpoint
	request.RequestURI = ""
	request.Host = endpoint.Host
	request.Header = r.Header.Clone()
	removeHopHeaders(request.Header)
	request.Header.Set(NodeProxyMarkerHeader, "1")
	request.Header.Set(NodeProxyTokenHeader, strings.TrimSpace(s.NodeProxyToken))

	response, err := s.nodeProxyHTTPClient().Do(request)
	if err != nil {
		s.logger().Warn(
			"public invoice remote node proxy failed",
			"installation_id",
			installationID,
			"connector_node_id",
			record.NodeID,
			"error",
			err,
		)
		s.renderPublicInvoiceError(
			w,
			http.StatusServiceUnavailable,
			"تعذر الوصول إلى المتجر الآن. حاول مرة أخرى لاحقًا.",
		)
		return true, http.StatusServiceUnavailable, "node_proxy_failed"
	}
	defer response.Body.Close()

	copyHeader(w.Header(), response.Header)
	w.WriteHeader(response.StatusCode)
	if _, err := io.Copy(w, response.Body); err != nil {
		s.logger().Warn(
			"public invoice remote node proxy response copy failed",
			"installation_id",
			installationID,
			"connector_node_id",
			record.NodeID,
			"error",
			err,
		)
	}
	return true, response.StatusCode, "node_proxied"
}

func nodeRelayEndpoint(
	rawBaseURL string,
	targetPath string,
	rawQuery string,
	allowInsecure bool,
) (*url.URL, error) {
	targetPath = strings.TrimSpace(targetPath)
	if !strings.HasPrefix(targetPath, "/api/") {
		return nil, errors.New("node relay target path must be an API path")
	}
	parsed, err := url.Parse(strings.TrimSpace(rawBaseURL))
	if err != nil {
		return nil, err
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return nil, errors.New("node relay URL must include scheme and host")
	}
	if parsed.Scheme == "http" && !allowInsecure {
		return nil, errors.New("node relay URL must use https unless insecure node proxy is enabled")
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return nil, errors.New("node relay URL must use http or https")
	}
	parsed.Path = joinHTTPPath(parsed.Path, "/v1/node/relay"+targetPath)
	parsed.RawQuery = rawQuery
	return parsed, nil
}

func nodePublicInvoiceEndpoint(
	rawBaseURL string,
	installationID string,
	invoiceToken string,
	allowInsecure bool,
) (*url.URL, error) {
	parsed, err := url.Parse(strings.TrimSpace(rawBaseURL))
	if err != nil {
		return nil, err
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return nil, errors.New("node public invoice URL must include scheme and host")
	}
	if parsed.Scheme == "http" && !allowInsecure {
		return nil, errors.New("node public invoice URL must use https unless insecure node proxy is enabled")
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return nil, errors.New("node public invoice URL must use http or https")
	}
	parsed.Path = joinHTTPPath(
		parsed.Path,
		"/v1/node/public-invoices/"+
			url.PathEscape(installationID)+
			"/"+
			url.PathEscape(invoiceToken),
	)
	parsed.RawQuery = ""
	return parsed, nil
}

func joinHTTPPath(basePath string, childPath string) string {
	basePath = strings.TrimRight(basePath, "/")
	childPath = strings.TrimLeft(childPath, "/")
	if childPath == "" {
		if basePath == "" {
			return "/"
		}
		return basePath
	}
	if basePath == "" {
		return "/" + childPath
	}
	return basePath + "/" + childPath
}

func (s HTTPServer) enforceRateLimit(
	w http.ResponseWriter,
	r *http.Request,
	scope string,
	key string,
	policy ratelimit.Policy,
) (bool, int, string) {
	if !policy.Enabled() || s.RateLimiter == nil {
		return false, 0, ""
	}
	decision, err := s.RateLimiter.Allow(r.Context(), key, policy)
	if err != nil {
		s.metrics().RecordRateLimitFailed()
		s.logger().Error("relay rate limiter failed", "scope", scope, "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "relay rate limiter unavailable"})
		return true, http.StatusServiceUnavailable, "rate_limit_failed"
	}
	if decision.Allowed {
		return false, 0, ""
	}
	s.metrics().RecordRateLimitRejected()
	w.Header().Set("Retry-After", retryAfterSeconds(decision.ResetAt, s.clock().Now()))
	writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "relay rate limit exceeded"})
	return true, http.StatusTooManyRequests, "rate_limited"
}

func relayRequestRateLimitKey(installationID string) string {
	return "relay-request:" + strings.TrimSpace(installationID)
}

func ticketIssueRateLimitKey(installationID string, deviceID string) string {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		deviceID = "unknown"
	} else {
		deviceID = control.TokenHash(deviceID)
	}
	return "ticket-issue:" + strings.TrimSpace(installationID) + ":device:" + deviceID
}

func ticketRefreshRateLimitKey(rawToken string) string {
	return "ticket-refresh:" + control.TokenHash(rawToken)
}

func rateLimitStatus(policy ratelimit.Policy, limiterConfigured bool) map[string]any {
	return map[string]any{
		"limit":              policy.Limit,
		"window":             policy.Window.String(),
		"policy_enabled":     policy.Enabled(),
		"limiter_configured": limiterConfigured,
		"enabled":            policy.Enabled() && limiterConfigured,
	}
}

func retryAfterSeconds(resetAt time.Time, now time.Time) string {
	wait := resetAt.Sub(now)
	if wait <= 0 {
		return "1"
	}
	seconds := int64(wait.Round(time.Second).Seconds())
	if seconds < 1 {
		seconds = 1
	}
	return strconv.FormatInt(seconds, 10)
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

func (s HTTPServer) withNodeProxy(
	w http.ResponseWriter,
	r *http.Request,
	handler func(http.ResponseWriter, *http.Request),
) {
	if strings.TrimSpace(s.NodeProxyToken) == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}
	if subtle.ConstantTimeCompare(
		[]byte(strings.TrimSpace(r.Header.Get(NodeProxyTokenHeader))),
		[]byte(strings.TrimSpace(s.NodeProxyToken)),
	) != 1 {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "node relay token required"})
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
	request.Header.Del(NodeProxyTokenHeader)
	request.Header.Del(NodeProxyMarkerHeader)
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

type closeableStream interface {
	Close() error
}

func closeStreamOnContextDone(ctx context.Context, stream closeableStream) func() {
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = stream.Close()
		case <-done:
		}
	}()
	return func() {
		close(done)
	}
}

func readResponseBodyWithinLimit(body io.Reader, maxBytes int64) ([]byte, bool, error) {
	if maxBytes <= 0 {
		content, err := io.ReadAll(body)
		return content, false, err
	}
	content, err := io.ReadAll(io.LimitReader(body, maxBytes+1))
	if err != nil {
		return nil, false, err
	}
	if int64(len(content)) > maxBytes {
		return nil, true, nil
	}
	return content, false, nil
}

type adminValidationError string

func (e adminValidationError) Error() string {
	return string(e)
}

var errAdminAuditUnavailable = errors.New("relay admin audit store unavailable")

func writeAdminSubscriptionError(w http.ResponseWriter, err error) {
	statusCode := adminSubscriptionErrorStatus(err)
	var validation adminValidationError
	switch {
	case errors.As(err, &validation):
		writeJSON(w, statusCode, map[string]string{"error": err.Error()})
	case errors.Is(err, errAdminAuditUnavailable):
		writeJSON(w, statusCode, map[string]string{"error": "relay admin audit store unavailable"})
	default:
		writeStoreError(w, err)
	}
}

func adminSubscriptionErrorStatus(err error) int {
	var validation adminValidationError
	if errors.As(err, &validation) {
		return http.StatusBadRequest
	}
	if errors.Is(err, errAdminAuditUnavailable) {
		return http.StatusServiceUnavailable
	}
	if errors.Is(err, control.ErrNotFound) {
		return http.StatusNotFound
	}
	return http.StatusInternalServerError
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
		errors.Is(err, control.ErrRelayTicketNotFound),
		errors.Is(err, control.ErrRelayRefreshTokenNotFound):
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token rejected"})
	default:
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token rejected"})
	}
}

func relayCredentialStatusCode(err error) int {
	if errors.Is(err, control.ErrSubscriptionInactive) {
		return http.StatusPaymentRequired
	}
	return http.StatusUnauthorized
}

func relayCredentialOutcome(err error) string {
	if errors.Is(err, control.ErrSubscriptionInactive) {
		return "subscription_rejected"
	}
	return "credential_rejected"
}

func writeJSON(w http.ResponseWriter, statusCode int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(jsonSize(value)))
	w.WriteHeader(statusCode)
	_ = json.NewEncoder(w).Encode(value)
}

func writeNotFound(w http.ResponseWriter) {
	writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
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

func (s HTTPServer) metrics() *observability.Metrics {
	if s.Metrics != nil {
		return s.Metrics
	}
	return nil
}

func (s HTTPServer) recordCredentialError(err error) {
	if errors.Is(err, control.ErrSubscriptionInactive) {
		s.metrics().RecordSubscriptionRejected()
		return
	}
	s.metrics().RecordCredentialRejected()
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

func (s HTTPServer) streamOpenTimeout() time.Duration {
	if s.StreamOpenTimeout > 0 {
		return s.StreamOpenTimeout
	}
	return 5 * time.Second
}

func (s HTTPServer) relayRequestTimeout() time.Duration {
	if s.RelayRequestTimeout > 0 {
		return s.RelayRequestTimeout
	}
	return 60 * time.Second
}

func (s HTTPServer) nodeProxyHTTPClient() *http.Client {
	if s.NodeProxyHTTPClient != nil {
		return s.NodeProxyHTTPClient
	}
	return &http.Client{Timeout: s.relayRequestTimeout()}
}

func (s HTTPServer) relayRefreshTTL() time.Duration {
	if s.TicketRefreshTTL > 0 {
		return s.TicketRefreshTTL
	}
	return 7 * 24 * time.Hour
}

func (s HTTPServer) connectorCertificateTTL() time.Duration {
	if s.ConnectorCertificateTTL > 0 {
		return s.ConnectorCertificateTTL
	}
	return 90 * 24 * time.Hour
}
