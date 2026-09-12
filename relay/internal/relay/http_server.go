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
	"sync"
	"time"

	"pointy/relay/internal/artifacts"
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
	EnrollmentTokenHeader = "X-Pointy-Enrollment-Token"
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
    <label>Exchange rates
      <select name="fx_enabled">
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
	Store control.InstallationStore
	Hub   *Hub
	// Artifacts stores on-prem update bundles the relay serves to the fleet.
	// Nil disables the remote-update endpoints.
	Artifacts                     *artifacts.Store
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
	// Fulus (exchange rates). The subscription token lives only here, for the
	// same reason as the OpenRouter key: the fleet buys one and fans it out.
	Fulus FulusConfig
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
	// AIExtractModel reads a document (a photographed supplier invoice) into a
	// fixed JSON schema. Empty falls back to the vision model. Kept separate
	// because extraction wants accuracy and structured-output support, which is
	// a different trade-off from conversational vision.
	AIExtractModel string
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
	case strings.HasPrefix(r.URL.Path, "/v1/node/installations/"):
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withNodeProxy(w, r, s.handleNodeInstallationDiagnosticsAnalytics)
	case r.URL.Path == "/v1/agent/manifest" && r.Method == http.MethodGet:
		// On-prem update agent (connector-token authed) asks what to run.
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.withConnectorToken(w, r, s.handleAgentManifest)
	case strings.HasPrefix(r.URL.Path, "/v1/agent/artifacts/") && r.Method == http.MethodGet:
		// On-prem update agent pulls the bundle bytes (supports Range/resume).
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.withConnectorToken(w, r, s.handleAgentArtifact)
	case r.URL.Path == "/v1/agent/status" && r.Method == http.MethodPost:
		// On-prem update agent reports its current version + last result.
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.withConnectorToken(w, r, s.handleAgentStatus)
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
	case r.URL.Path == "/v1/enrollment/tokens" && r.Method == http.MethodPost:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleMintEnrollmentTokens)
	case r.URL.Path == "/v1/enroll" && r.Method == http.MethodPost:
		if !(s.RouteMode.allowsPublic() || s.RouteMode.allowsAdmin()) {
			writeNotFound(w)
			return
		}
		s.handleEnroll(w, r)
	case strings.HasPrefix(r.URL.Path, "/v1/installations/"):
		s.handleInstallationRoutes(w, r)
	case r.URL.Path == "/v1/fleet" && r.Method == http.MethodGet:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleFleetStatus)
	case strings.HasPrefix(r.URL.Path, "/v1/fleet/channels/") && r.Method == http.MethodPut:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleSetChannelTarget)
	case strings.HasPrefix(r.URL.Path, "/v1/artifacts/"):
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleAdminArtifact)
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
	case r.URL.Path == "/v1/exchange-rates" && r.Method == http.MethodGet:
		// Shops pull published rates with an installation token, gated on the
		// FX entitlement.
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handleListExchangeRates(w, r)
	case r.URL.Path == "/v1/exchange-rates/webhook" && r.Method == http.MethodPost:
		// Fulus pushes new rates here. Authenticated by HMAC over the body, not
		// by a relay token — the caller is the provider, not an installation.
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handleFulusWebhook(w, r)
	case r.URL.Path == "/v1/exchange-rates" && r.Method == http.MethodPost:
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleAdminUpsertExchangeRate)
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

// handleMintEnrollmentTokens (admin) mints N single-use enrollment ("license")
// tokens and returns the raw values once. The operator ships one token per shop;
// the on-prem backend redeems it at /v1/enroll.
func (s HTTPServer) handleMintEnrollmentTokens(w http.ResponseWriter, r *http.Request) {
	store, ok := s.Store.(control.EnrollmentStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "enrollment is not supported"})
		return
	}
	var request struct {
		Count     int    `json:"count"`
		ExpiresIn string `json:"expires_in,omitempty"`
		// Subscription, when present, is baked into every key in the batch: the
		// installation a key creates is activated on redemption (subscription
		// clock starting then) instead of staying inert. Omit it for a plain
		// license that the operator activates later.
		Subscription *struct {
			RelayEnabled bool   `json:"relay_enabled,omitempty"`
			AIEnabled    bool   `json:"ai_enabled,omitempty"`
			Duration     string `json:"duration,omitempty"`
		} `json:"subscription,omitempty"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&request); err != nil && !errors.Is(err, io.EOF) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if request.Count > 1000 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "count must be between 1 and 1000"})
		return
	}
	mintRequest := control.MintEnrollmentTokensRequest{Count: request.Count}
	if expiresIn := strings.TrimSpace(request.ExpiresIn); expiresIn != "" {
		duration, err := time.ParseDuration(expiresIn)
		if err != nil || duration <= 0 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "expires_in must be a positive Go duration (e.g. 720h)"})
			return
		}
		expiresAt := s.clock().Now().Add(duration)
		mintRequest.ExpiresAt = &expiresAt
	}
	if request.Subscription != nil {
		duration, err := control.ParseLicenseDuration(request.Subscription.Duration)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		mintRequest.Entitlement = control.EnrollmentEntitlement{
			SubscriptionActive: true,
			RelayEnabled:       request.Subscription.RelayEnabled,
			AIEnabled:          request.Subscription.AIEnabled,
			Duration:           duration,
		}
	}
	tokens, err := store.MintEnrollmentTokens(r.Context(), mintRequest)
	if err != nil {
		s.logger().Error("enrollment mint failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "enrollment mint failed"})
		return
	}
	response := map[string]any{
		"tokens":     tokens,
		"count":      len(tokens),
		"expires_at": mintRequest.ExpiresAt,
	}
	if mintRequest.Entitlement.SubscriptionActive {
		response["subscription"] = map[string]any{
			"relay_enabled":    mintRequest.Entitlement.RelayEnabled,
			"ai_enabled":       mintRequest.Entitlement.AIEnabled,
			"duration_seconds": int64(mintRequest.Entitlement.Duration / time.Second),
		}
	}
	writeJSON(w, http.StatusCreated, response)
}

// handleEnroll (public) redeems a single-use enrollment token for a brand-new
// installation + its scoped credentials. The token is consumed atomically, and
// the created installation starts inert (relay/AI/subscription OFF) — the
// operator activates it later. Authenticated solely by the enrollment token in
// the X-Pointy-Enrollment-Token header, so an on-prem backend self-enrolls
// without the company admin token.
func (s HTTPServer) handleEnroll(w http.ResponseWriter, r *http.Request) {
	store, ok := s.Store.(control.EnrollmentStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "enrollment is not supported"})
		return
	}
	rawToken := strings.TrimSpace(r.Header.Get(EnrollmentTokenHeader))
	if rawToken == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "enrollment token required"})
		return
	}
	// Defence-in-depth rate limit (tokens are 256-bit, so this is DoS hygiene,
	// not the primary guard); reuses the ticket-issue policy, keyed per token.
	if limited, _, _ := s.enforceRateLimit(
		w, r, "enroll", "enroll:"+control.TokenHash(rawToken), s.TicketIssueRateLimit,
	); limited {
		return
	}
	var request struct {
		BusinessID string `json:"business_id,omitempty"`
		ShopName   string `json:"shop_name,omitempty"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&request); err != nil && !errors.Is(err, io.EOF) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	provisioned, err := store.RedeemEnrollmentToken(r.Context(), rawToken, control.ProvisionInstallationRequest{
		BusinessID: strings.TrimSpace(request.BusinessID),
		ShopName:   strings.TrimSpace(request.ShopName),
	})
	if err != nil {
		switch {
		case errors.Is(err, control.ErrEnrollmentTokenInvalid),
			errors.Is(err, control.ErrEnrollmentTokenConsumed),
			errors.Is(err, control.ErrEnrollmentTokenExpired):
			s.metrics().RecordCredentialRejected()
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "enrollment token rejected"})
			return
		default:
			s.logger().Error("enrollment redeem failed", "error", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "enrollment failed"})
			return
		}
	}
	writeJSON(w, http.StatusCreated, provisionedInstallationPayload(provisioned, s.clock().Now()))
}

// handleInstallationRoutes gates every /v1/installations/{id}/... route. Three of
// them are "self-serviceable": an installation may authorize them with its OWN
// access token (X-Pointy-Relay-Token) instead of the company-wide admin token,
// so an on-prem backend never needs the fleet admin key. Those three are the
// status read (GET {id}), connector-certificate issuance/renewal
// (POST {id}/connector-certificate), and shop-owned metadata updates
// (PATCH {id}/metadata, e.g. the display name). Every other sub-route —
// subscription, audit-events, config update, etc. — stays admin-only, unchanged.
func (s HTTPServer) handleInstallationRoutes(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/installations/"), "/")
	id := ""
	if len(parts) > 0 {
		id = parts[0]
	}
	selfServiceable := id != "" &&
		((len(parts) == 1 && r.Method == http.MethodGet) ||
			(len(parts) == 2 && parts[1] == "connector-certificate" && r.Method == http.MethodPost) ||
			(len(parts) == 2 && parts[1] == "metadata" && r.Method == http.MethodPatch))

	// When a self-serviceable route is called with the installation's access
	// token (and no admin Authorization header), authorize against that token
	// and require it to belong to the {id} in the path. Identity is validated
	// WITHOUT the subscription gate: reading own status and bootstrapping the
	// connector certificate must work for a freshly enrolled, inert install
	// before its subscription is switched on (enroll-inert-then-activate). The
	// paid remote-access feature — per-device relay tickets — stays
	// subscription-gated elsewhere. Anything else falls through to the
	// unchanged admin path below.
	if selfServiceable && r.Header.Get("Authorization") == "" {
		if rawToken := strings.TrimSpace(r.Header.Get(AccessTokenHeader)); rawToken != "" {
			if !(s.RouteMode.allowsPublic() || s.RouteMode.allowsAdmin()) {
				writeNotFound(w)
				return
			}
			installation, err := s.Store.ValidateAccessTokenIdentity(r.Context(), rawToken)
			if err != nil {
				s.recordCredentialError(err)
				writeRelayCredentialError(w, err)
				return
			}
			if installation.ID != id {
				s.recordCredentialError(control.ErrInvalidToken)
				writeRelayCredentialError(w, control.ErrInvalidToken)
				return
			}
			s.handleInstallation(w, r)
			return
		}
	}

	if !s.RouteMode.allowsAdmin() {
		writeNotFound(w)
		return
	}
	s.withAdmin(w, r, s.handleInstallation)
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
	if len(parts) == 2 && parts[1] == "diagnostics-analytics" && r.Method == http.MethodGet {
		s.handleInstallationDiagnosticsAnalytics(w, r, id)
		return
	}
	if len(parts) == 2 && parts[1] == "update" && r.Method == http.MethodPatch {
		s.handleInstallationUpdateConfig(w, r, id)
		return
	}
	if len(parts) == 2 && parts[1] == "connector-certificate" && r.Method == http.MethodPost {
		s.handleIssueConnectorCertificate(w, r, id)
		return
	}
	if len(parts) == 2 && parts[1] == "metadata" && r.Method == http.MethodPatch {
		s.handleInstallationUpdateMetadata(w, r, id)
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

// handleInstallationUpdateMetadata lets an installation update its own
// shop-owned descriptive fields — currently the display name the merchant edits
// in Shop Settings. It is self-serviceable with the installation's access token
// (no subscription gate), so an inert / unsubscribed shop still keeps its name
// current on the relay. The merchant's local backend is the source of truth for
// the name; this route is how a rename reaches the operator's fleet console.
func (s HTTPServer) handleInstallationUpdateMetadata(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.Store.(control.MetadataStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "metadata store unavailable"})
		return
	}
	var req struct {
		ShopName *string `json:"shop_name,omitempty"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if req.ShopName == nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "nothing to update"})
		return
	}
	installation, err := store.UpdateInstallationMetadata(
		r.Context(),
		id,
		control.MetadataUpdate{ShopName: req.ShopName},
	)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, adminInstallationPayload(installation, s.clock().Now()))
}

const (
	// diagnosticsAnalyticsBackendPath is the reserved tunnel path the connector
	// rewrites to the on-prem backend's connector-token-authed export endpoint.
	// It is unreachable from the public relay proxy: relayTarget only routes
	// /api/ paths reached via an access ticket, never the /__pointy_support__
	// prefix.
	diagnosticsAnalyticsBackendPath = "/__pointy_support__/api/relay/diagnostics/analytics-export/"
	diagOnlineHeader                = "X-Pointy-Diag-Online"
	diagLastConnectedHeader         = "X-Pointy-Diag-Last-Connected-At"
)

// handleInstallationDiagnosticsAnalytics streams an installation's
// tracking/usage/error export (the same data the Shop Settings "Export Tracking"
// screen produces) back to the relay operator for remote support. The request is
// proxied over the connector tunnel to the on-prem backend; the connector
// injects its token so the backend can authenticate the operator. The incoming
// admin query string is forwarded verbatim so CLI filters reach the backend.
// Routing already passes through withAdmin, so this is gated by the admin token.
func (s HTTPServer) handleInstallationDiagnosticsAnalytics(w http.ResponseWriter, r *http.Request, id string) {
	s.serveInstallationDiagnosticsAnalytics(w, r, id, true)
}

// handleNodeInstallationDiagnosticsAnalytics serves a diagnostics pull that
// another relay node forwarded here because this node holds the connector. It is
// gated by withNodeProxy (node token) and never proxies onward (avoids loops).
func (s HTTPServer) handleNodeInstallationDiagnosticsAnalytics(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/node/installations/"), "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] != "diagnostics-analytics" || r.Method != http.MethodGet {
		writeNotFound(w)
		return
	}
	s.serveInstallationDiagnosticsAnalytics(w, r, parts[0], false)
}

func (s HTTPServer) serveInstallationDiagnosticsAnalytics(
	w http.ResponseWriter,
	r *http.Request,
	id string,
	allowNodeProxy bool,
) {
	installation, err := s.Store.GetInstallation(r.Context(), id)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if s.Hub == nil || !s.Hub.IsOnline(installation.ID) {
		// In a multi-node mesh the connector may be attached to another node;
		// transparently forward the pull to whichever node holds it.
		if allowNodeProxy {
			if proxied, _, _ := s.tryProxyDiagnosticsToRemoteNode(w, r, installation.ID); proxied {
				return
			}
		}
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "connector offline"})
		return
	}

	requestCtx, requestCancel := context.WithTimeout(r.Context(), s.relayRequestTimeout())
	defer requestCancel()
	openCtx, openCancel := context.WithTimeout(requestCtx, s.streamOpenTimeout())
	stream, err := s.Hub.OpenStream(openCtx, installation.ID)
	openCancel()
	if err != nil {
		if errors.Is(err, ErrConnectorOffline) {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "connector offline"})
			return
		}
		s.logger().Warn("diagnostics stream open failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "relay stream failed"})
		return
	}
	defer stream.Close()
	stopDeadlineCloser := closeStreamOnContextDone(requestCtx, stream)
	defer stopDeadlineCloser()

	// Build a clean request rather than cloning the admin request, so the admin
	// bearer token never travels down the tunnel.
	proxyReq, err := http.NewRequestWithContext(
		requestCtx,
		http.MethodGet,
		"http://connector"+diagnosticsAnalyticsBackendPath,
		nil,
	)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "diagnostics request build failed"})
		return
	}
	proxyReq.URL.RawQuery = r.URL.RawQuery
	proxyReq.Close = true
	proxyReq.Header.Set("Connection", "close")
	// State the preference, but keep the */* fallback: the on-prem backend
	// negotiates content before its handler runs, and a shop that has not yet
	// taken the update that declares a zip renderer answers a bare
	// "application/zip" with 406 instead of the export.
	proxyReq.Header.Set("Accept", "application/zip, */*")

	if err := proxyReq.Write(stream); err != nil {
		s.logger().Warn("diagnostics request write failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "relay request failed"})
		return
	}

	response, err := http.ReadResponse(bufio.NewReader(stream), proxyReq)
	if err != nil {
		s.logger().Warn("diagnostics response read failed", "installation_id", installation.ID, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "relay response failed"})
		return
	}
	defer response.Body.Close()

	// Pass through the backend export headers (event count, app/connector
	// version) and add the relay-known health headers the backend cannot see.
	copyHeader(w.Header(), response.Header)
	w.Header().Set(diagOnlineHeader, "true")
	if installation.LastConnectorConnectedAt != nil {
		w.Header().Set(diagLastConnectedHeader, installation.LastConnectorConnectedAt.UTC().Format(time.RFC3339))
	}
	w.WriteHeader(response.StatusCode)
	// Idle watchdog instead of the total deadline for the body: a large
	// diagnostics zip over a slow shop uplink legitimately outlives the
	// request timeout while bytes are still flowing.
	stopDeadlineCloser()
	touch, stopIdleCloser := closeStreamOnIdle(stream, s.relayRequestTimeout())
	defer stopIdleCloser()
	if _, _, err := flushingCopy(
		w,
		activityReader{reader: response.Body, touch: touch},
		0,
	); err != nil {
		s.logger().Warn("diagnostics response copy failed", "installation_id", installation.ID, "error", err)
	}
}

// tryProxyDiagnosticsToRemoteNode forwards a diagnostics pull to the relay node
// that currently holds the installation's connector, mirroring the public relay
// node proxy. It returns ok=false (caller falls back to 503) when no other node
// advertises the connector or node proxying is not configured.
func (s HTTPServer) tryProxyDiagnosticsToRemoteNode(
	w http.ResponseWriter,
	r *http.Request,
	installationID string,
) (bool, int, string) {
	if strings.TrimSpace(s.NodeProxyToken) == "" ||
		s.Presence == nil ||
		strings.TrimSpace(r.Header.Get(NodeProxyMarkerHeader)) != "" {
		return false, 0, ""
	}

	record, ok, err := s.Presence.Get(r.Context(), installationID)
	if err != nil {
		s.logger().Warn("diagnostics connector presence lookup failed", "installation_id", installationID, "error", err)
		return false, 0, ""
	}
	if !ok ||
		strings.TrimSpace(record.NodeID) == "" ||
		record.NodeID == s.NodeID ||
		strings.TrimSpace(record.RelayHTTPURL) == "" {
		return false, 0, ""
	}

	endpoint, err := nodeDiagnosticsEndpoint(
		record.RelayHTTPURL,
		installationID,
		r.URL.RawQuery,
		s.AllowInsecureNodeProxy,
	)
	if err != nil {
		s.logger().Warn(
			"diagnostics remote node URL rejected",
			"installation_id", installationID,
			"connector_node_id", record.NodeID,
			"error", err,
		)
		return false, 0, ""
	}

	request := r.Clone(r.Context())
	request.URL = endpoint
	request.RequestURI = ""
	request.Host = endpoint.Host
	request.Header = r.Header.Clone()
	removeHopHeaders(request.Header)
	// The receiving node authorizes with the node token, so the operator's admin
	// bearer token must not travel across the internal hop.
	request.Header.Del("Authorization")
	request.Header.Set(NodeProxyMarkerHeader, "1")
	request.Header.Set(NodeProxyTokenHeader, strings.TrimSpace(s.NodeProxyToken))

	response, err := s.nodeProxyHTTPClient().Do(request)
	if err != nil {
		s.logger().Warn(
			"diagnostics remote node proxy failed",
			"installation_id", installationID,
			"connector_node_id", record.NodeID,
			"error", err,
		)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "connector offline"})
		return true, http.StatusServiceUnavailable, "node_proxy_failed"
	}
	defer response.Body.Close()

	copyHeader(w.Header(), response.Header)
	w.WriteHeader(response.StatusCode)
	if _, _, err := flushingCopy(w, response.Body, 0); err != nil {
		s.logger().Warn(
			"diagnostics remote node proxy response copy failed",
			"installation_id", installationID,
			"connector_node_id", record.NodeID,
			"error", err,
		)
	}
	return true, response.StatusCode, "node_proxied"
}

func nodeDiagnosticsEndpoint(
	rawBaseURL string,
	installationID string,
	rawQuery string,
	allowInsecure bool,
) (*url.URL, error) {
	parsed, err := url.Parse(strings.TrimSpace(rawBaseURL))
	if err != nil {
		return nil, err
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return nil, errors.New("node diagnostics URL must include scheme and host")
	}
	if parsed.Scheme == "http" && !allowInsecure {
		return nil, errors.New("node diagnostics URL must use https unless insecure node proxy is enabled")
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return nil, errors.New("node diagnostics URL must use http or https")
	}
	parsed.Path = joinHTTPPath(
		parsed.Path,
		"/v1/node/installations/"+url.PathEscape(installationID)+"/diagnostics-analytics",
	)
	parsed.RawQuery = rawQuery
	return parsed, nil
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
		update.FXEnabled != nil ||
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
		"fx_enabled":                        installation.FXEnabled,
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
	if value, set, err := optionalBoolFormValue(r, "fx_enabled"); err != nil {
		return control.SubscriptionUpdate{}, err
	} else if set {
		update.FXEnabled = &value
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
	statusCode = response.StatusCode
	outcome = "relayed"
	if response.StatusCode >= 500 {
		s.metrics().RecordBackendFailure()
	}
	copyHeader(w.Header(), response.Header)
	w.WriteHeader(response.StatusCode)

	// Headers are on the wire: the total deadline has done its job. Buffering
	// the body here (the old readResponseBodyWithinLimit path) froze AI chat
	// SSE — no token reached the app until the whole turn finished — and the
	// 60s total deadline killed long turns and large exports mid-body. Stream
	// the body with per-chunk flushes under an idle watchdog instead: only a
	// stalled tunnel gets cut, a live stream never does.
	stopDeadlineCloser()
	touch, stopIdleCloser := closeStreamOnIdle(stream, s.relayRequestTimeout())
	defer stopIdleCloser()

	written, tooLarge, err := flushingCopy(
		w,
		activityReader{reader: response.Body, touch: touch},
		s.relayedBodyByteLimit(response.Header),
	)
	if tooLarge {
		outcome = "response_body_too_large"
		s.metrics().RecordResponseBodyLimitFailed()
		s.logger().Warn(
			"relay backend response exceeded body limit mid-stream; transfer aborted",
			"installation_id", installation.ID,
			"limit_bytes", s.MaxRelayedResponseBodyBytes,
			"written_bytes", written,
		)
		// The status line already went out; aborting the connection is the
		// only way left to signal failure instead of a silently-truncated body.
		panic(http.ErrAbortHandler)
	}
	if err != nil {
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
	// Flush per chunk so SSE relayed via a peer node still streams; the byte
	// limit is enforced by the node that owns the connector tunnel.
	if _, _, err := flushingCopy(w, response.Body, 0); err != nil {
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
	var once sync.Once
	// Idempotent: callers stop the deadline closer explicitly when handing
	// the stream to the idle watchdog, and their deferred stop still runs.
	return func() {
		once.Do(func() { close(done) })
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

// relayedBodyByteLimit is the byte cap to enforce while relaying a backend
// response body. Streamed/bulk media are exempt: the AI chat SSE stream is
// open-ended by design (buffering it froze token streaming entirely), and
// zip exports (tracking/diagnostics pulls) legitimately exceed any fixed cap
// on large shops. The flushing copy holds only one chunk in memory whatever
// the body size, so the cap's original memory rationale no longer applies to
// them; it remains as an abuse guard on ordinary (JSON) bodies.
func (s HTTPServer) relayedBodyByteLimit(header http.Header) int64 {
	contentType := header.Get("Content-Type")
	if strings.HasPrefix(contentType, "text/event-stream") ||
		strings.HasPrefix(contentType, "application/zip") {
		return 0
	}
	return s.MaxRelayedResponseBodyBytes
}

// flushingCopy copies body to w in bounded chunks, flushing after each so a
// streamed response (SSE chat tokens, a zip being generated row by row)
// reaches the client as it is produced instead of pooling in the HTTP write
// buffer. maxBytes > 0 is enforced DURING the copy; on breach the copy stops
// and reports tooLarge — the status line is already on the wire by then, so
// the caller must abort the connection rather than write a clean error.
func flushingCopy(w http.ResponseWriter, body io.Reader, maxBytes int64) (int64, bool, error) {
	flusher, _ := w.(http.Flusher)
	buffer := make([]byte, 32*1024)
	var written int64
	for {
		n, readErr := body.Read(buffer)
		if n > 0 {
			if maxBytes > 0 && written+int64(n) > maxBytes {
				return written, true, nil
			}
			if _, writeErr := w.Write(buffer[:n]); writeErr != nil {
				return written, false, writeErr
			}
			written += int64(n)
			if flusher != nil {
				flusher.Flush()
			}
		}
		if readErr == io.EOF {
			return written, false, nil
		}
		if readErr != nil {
			return written, false, readErr
		}
	}
}

// closeStreamOnIdle guards the response-body copy: the total request deadline
// (closeStreamOnContextDone) is right for opening the tunnel and reading
// headers, but it kills an actively-flowing long stream — an AI chat turn or
// a large export — mid-body. Once headers have arrived the caller switches to
// this watchdog, which closes the stream only when NO bytes have moved for
// idleTimeout: a stalled backend still gets cut, a live stream never does.
// touch marks activity; stop dismisses the watchdog.
func closeStreamOnIdle(stream closeableStream, idleTimeout time.Duration) (touch func(), stop func()) {
	var mu sync.Mutex
	lastActivity := time.Now()
	done := make(chan struct{})
	touch = func() {
		mu.Lock()
		lastActivity = time.Now()
		mu.Unlock()
	}
	go func() {
		timer := time.NewTimer(idleTimeout)
		defer timer.Stop()
		for {
			select {
			case <-done:
				return
			case <-timer.C:
				mu.Lock()
				idle := time.Since(lastActivity)
				mu.Unlock()
				if idle >= idleTimeout {
					_ = stream.Close()
					return
				}
				timer.Reset(idleTimeout - idle)
			}
		}
	}()
	var once sync.Once
	return touch, func() {
		once.Do(func() { close(done) })
	}
}

// activityReader marks watchdog activity on every read from the tunnel.
type activityReader struct {
	reader io.Reader
	touch  func()
}

func (r activityReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	if n > 0 {
		r.touch()
	}
	return n, err
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
	// No Client.Timeout: it covers the ENTIRE body read, so it would cut
	// long streams (AI chat SSE, large exports) at the deadline on the
	// node-proxy hop — the exact mid-body kill the idle watchdog replaces on
	// the direct path. Connection setup and waiting for headers stay bounded;
	// the peer node enforces its own idle watchdog on the tunnel body.
	return &http.Client{
		Transport: &http.Transport{
			DialContext: (&net.Dialer{
				Timeout: s.streamOpenTimeout(),
			}).DialContext,
			TLSHandshakeTimeout:   s.streamOpenTimeout(),
			ResponseHeaderTimeout: s.relayRequestTimeout(),
		},
	}
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

// --- Exchange rates ---------------------------------------------------------

func (s HTTPServer) exchangeRateStore(w http.ResponseWriter) (control.ExchangeRateStore, bool) {
	store, ok := s.Store.(control.ExchangeRateStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "exchange rate store unavailable"})
		return nil, false
	}
	return store, true
}

// handleListExchangeRates serves a shop's rate sync. Gated on the FX
// entitlement (subscription + fx_enabled), independent of remote access — an
// importer can buy the feed without buying the tunnel.
func (s HTTPServer) handleListExchangeRates(w http.ResponseWriter, r *http.Request) {
	store, ok := s.exchangeRateStore(w)
	if !ok {
		return
	}
	rawToken := strings.TrimSpace(r.Header.Get(AccessTokenHeader))
	if rawToken == "" {
		s.metrics().RecordCredentialRejected()
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "relay token required"})
		return
	}
	// Identity only. The entitlement decides how MUCH of the feed this shop
	// gets, not whether it may ask — an unentitled shop still has a goodwill
	// allowance of one fetch a day, so nobody ends up pricing off a rate from
	// six months ago.
	installation, err := s.Store.ValidateAccessTokenIdentity(r.Context(), rawToken)
	if err != nil {
		s.recordCredentialError(err)
		writeRelayCredentialError(w, err)
		return
	}

	now := s.clock().Now()
	access := installation.FXAccessAt(now)
	if access == control.FXAccessNone {
		resetsAt := control.FXAllowanceResetsAt(now)
		w.Header().Set(
			"Retry-After",
			strconv.Itoa(int(resetsAt.Sub(now).Seconds())),
		)
		writeJSON(w, http.StatusTooManyRequests, map[string]any{
			"error":     "daily exchange rate allowance already used",
			"access":    access.String(),
			"resets_at": resetsAt,
			"entitled":  false,
		})
		return
	}

	var since time.Time
	if raw := strings.TrimSpace(r.URL.Query().Get("since")); raw != "" {
		parsed, err := time.Parse(time.RFC3339, raw)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid since"})
			return
		}
		since = parsed
	}

	rates, err := store.ListExchangeRates(r.Context(), since, 0)
	if err != nil {
		s.logger().Error(
			"list exchange rates failed",
			"installation_id", installation.ID,
			"error", err,
		)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "exchange rate store failed"})
		return
	}
	if rates == nil {
		rates = []control.ExchangeRate{}
	}

	// Spend the allowance only on a successful read, and only for a shop that
	// is on it — an entitled shop never pays for a write here, and a failed
	// fetch never costs a shop its one chance for the day.
	if access == control.FXAccessDaily {
		if err := store.TouchFXFetch(r.Context(), installation.ID, now); err != nil {
			// Non-fatal: the shop has its rates. Failing to stamp means it may
			// get a second fetch today, which is the harmless direction.
			s.logger().Warn(
				"stamping the fx daily allowance failed",
				"installation_id", installation.ID,
				"error", err,
			)
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"rates": rates,
		// The shop's own client shows "rates update once a day on your plan"
		// off this, rather than guessing from how stale they look.
		"access":    access.String(),
		"entitled":  access == control.FXAccessFull,
		"resets_at": control.FXAllowanceResetsAt(now),
	})
}

// handleFulusWebhook accepts a push from the provider. The body is verified
// against the shared secret before anything is parsed, and an unconfigured
// secret disables the endpoint entirely rather than accepting unverified
// writes — anyone who could write here could reprice every shop in the fleet.
func (s HTTPServer) handleFulusWebhook(w http.ResponseWriter, r *http.Request) {
	store, ok := s.exchangeRateStore(w)
	if !ok {
		return
	}
	if strings.TrimSpace(s.Fulus.WebhookSecret) == "" {
		writeNotFound(w)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 64<<10))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unreadable body"})
		return
	}
	if !VerifyFulusWebhook(s.Fulus.WebhookSecret, body, r.Header.Get("X-Webhook-Signature")) {
		s.metrics().RecordCredentialRejected()
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid signature"})
		return
	}
	rate, err := ParseFulusWebhook(body)
	if err != nil {
		// The signature verified, so this body really is theirs: log a slice of
		// it. A rejection that says only "unusable payload" cannot tell an
		// operator whether the provider renamed a field or sent an empty row,
		// and their delivery log shows nothing but the status code.
		s.logger().Warn(
			"fulus webhook payload rejected",
			"error", err,
			"payload", truncateForLog(body),
		)
		// 200, not 400. We could not use this push, but no retry will change
		// that, and a 4xx tells the provider the ENDPOINT is broken: theirs
		// retries three times within two seconds and counts every attempt
		// against us, which is how 223 consecutive failures accumulated over a
		// feed whose only real fault was an event name we did not recognise.
		// Providers disable an endpoint that keeps failing, and a disabled
		// webhook is a far worse outcome than a push we declined to store.
		// The reason rides in the body so it reaches their delivery log too.
		writeJSON(w, http.StatusOK, map[string]string{
			"status": "ignored",
			"reason": err.Error(),
		})
		return
	}
	stored, err := store.UpsertExchangeRate(r.Context(), rate)
	if err != nil {
		s.logger().Error("store fulus rate failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "exchange rate store failed"})
		return
	}
	s.logger().Info(
		"fulus rate stored",
		"from", stored.FromCode,
		"instrument", stored.Instrument,
		"bank", stored.BankCode,
		"effective_at", stored.EffectiveAt,
	)
	writeJSON(w, http.StatusAccepted, map[string]any{"stored": stored.ID})
}

// handleAdminUpsertExchangeRate lets an operator publish or correct a rate by
// hand — the escape hatch for when the provider is wrong or unreachable.
func (s HTTPServer) handleAdminUpsertExchangeRate(w http.ResponseWriter, r *http.Request) {
	store, ok := s.exchangeRateStore(w)
	if !ok {
		return
	}
	var payload control.ExchangeRate
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&payload); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	if strings.TrimSpace(payload.FromCode) == "" || strings.TrimSpace(payload.Rate) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "from and rate are required"})
		return
	}
	if strings.TrimSpace(payload.ToCode) == "" {
		payload.ToCode = fulusQuoteCurrency
	}
	if strings.TrimSpace(payload.Instrument) == "" {
		payload.Instrument = fulusInstrumentCash
	}
	if payload.EffectiveAt.IsZero() {
		payload.EffectiveAt = s.clock().Now()
	}
	if strings.TrimSpace(payload.Source) == "" {
		payload.Source = "admin"
	}
	stored, err := store.UpsertExchangeRate(r.Context(), payload)
	if err != nil {
		s.logger().Error("admin upsert exchange rate failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "exchange rate store failed"})
		return
	}
	writeJSON(w, http.StatusCreated, stored)
}
