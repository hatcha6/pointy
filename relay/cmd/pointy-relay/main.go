package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/redis/go-redis/v9"

	"pointy/relay/internal/alerts"
	"pointy/relay/internal/artifacts"
	"pointy/relay/internal/bnplus"
	"pointy/relay/internal/cardsweb"
	"pointy/relay/internal/connector"
	"pointy/relay/internal/control"
	"pointy/relay/internal/dafa"
	"pointy/relay/internal/discovery"
	"pointy/relay/internal/limit"
	"pointy/relay/internal/moamalat"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/protocol"
	"pointy/relay/internal/ratelimit"
	relayserver "pointy/relay/internal/relay"
	"pointy/relay/internal/resala"
	"pointy/relay/internal/security"
	"pointy/relay/internal/webbuild"
)

const (
	defaultRelayDatabaseURL = "postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable"
	defaultRelayRedisURL    = "redis://127.0.0.1:6379/0"
	relayRedisKeyPrefix     = "pointy:relay"

	defaultMaxRelayedRequestBodyBytes  = int64(10 << 20)
	defaultMaxRelayedResponseBodyBytes = int64(50 << 20)
	defaultRateLimitWindow             = time.Minute
)

// version is the build version, injected at link time from the git tag
// (-ldflags "-X main.version=<tag>"). It defaults to "dev" for local builds and
// is reported by the connector heartbeat so the fleet shows real versions.
var version = "dev"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "pointy-relay: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	// Load relay/.env for local development before any flag/env defaults are
	// resolved. Real env vars and Makefile-provided values take precedence.
	loadDotEnv(dotEnvPath())

	if len(args) == 0 {
		return usageError("missing command")
	}
	// Errors from here on print only this command's usage, not the whole tool's.
	usageTopic = args[0]
	if len(args) > 1 && wantsCommandHelp(args[0], args[1]) {
		printCommandUsage(args[0])
		return nil
	}
	switch args[0] {
	case "server":
		return runServer(args[1:])
	case "connector":
		return runConnector(args[1:])
	case "provision":
		return runProvision(args[1:])
	case "installations":
		return runInstallations(args[1:])
	case "enrollment":
		return runEnrollment(args[1:])
	case "subscription":
		return runSubscription(args[1:])
	case "fleet":
		return runFleet(args[1:])
	case "sms":
		return runSMS(args[1:])
	case "wallet":
		return runWallet(args[1:])
	case "vouchers":
		return runVouchers(args[1:])
	case "services":
		return runServices(args[1:])
	case "integrations":
		return runIntegrations(args[1:])
	case "alerts":
		return runAlerts(args[1:])
	case "console":
		return runConsole(args[1:])
	case "artifacts":
		return runArtifacts(args[1:])
	case "migrate":
		return runMigrate(args[1:])
	case "gen-token":
		return runGenToken(args[1:])
	case "gen-stock-key":
		return runGenStockKey()
	case "gen-moamalat-key":
		return runGenMoamalatKey()
	case "moamalat":
		return runMoamalat(args[1:])
	case "version", "-v", "--version":
		fmt.Println(version)
		return nil
	case "help", "-h", "--help":
		if len(args) > 1 && findUsageSection(args[1]) != nil {
			printCommandUsage(args[1])
		} else {
			printUsage()
		}
		return nil
	default:
		return usageError("unknown command %q", args[0])
	}
}

// defaultArtifactDir is the relay's auto-enabled store for on-prem update bundles.
// It matches the relay image WORKDIR (/var/lib/pointy, owned by uid 65532); mount a
// volume there to persist bundles across redeploys.
const defaultArtifactDir = "/var/lib/pointy/artifacts"

func runServer(args []string) error {
	flags := flag.NewFlagSet("server", flag.ExitOnError)
	platform := flags.String(
		"platform",
		envString("POINTY_RELAY_PLATFORM", ""),
		"deployment profile: \"paas\" for a single public endpoint behind a TLS-terminating load balancer with bearer-token admin (auto-binds 0.0.0.0, edge TLS, auto-migrate); empty for a self-hosted private-network deployment",
	)
	httpAddr := flags.String(
		"http",
		envString("POINTY_RELAY_HTTP_ADDR", "127.0.0.1:8091"),
		"HTTP address for public remote client traffic",
	)
	adminHTTPAddr := flags.String(
		"admin-http",
		envString("POINTY_RELAY_ADMIN_HTTP_ADDR", ""),
		"separate HTTP address for admin control and internal relay traffic",
	)
	connectorAddr := flags.String(
		"connector",
		envString("POINTY_RELAY_CONNECTOR_ADDR", "127.0.0.1:8092"),
		"TCP address for on-prem connector tunnels",
	)
	httpTLSCert := flags.String(
		"http-tls-cert",
		envString("POINTY_RELAY_HTTP_TLS_CERT", ""),
		"TLS certificate for HTTP remote/control listener",
	)
	httpTLSKey := flags.String(
		"http-tls-key",
		envString("POINTY_RELAY_HTTP_TLS_KEY", ""),
		"TLS key for HTTP remote/control listener",
	)
	httpTLSServerName := flags.String(
		"http-tls-server-name",
		envString("POINTY_RELAY_HTTP_TLS_SERVER_NAME", ""),
		"DNS name or IP to include when auto-generating HTTP listener TLS material",
	)
	httpClientCA := flags.String(
		"http-client-ca",
		envString("POINTY_RELAY_HTTP_CLIENT_CA", ""),
		"client CA bundle accepted by admin control endpoints",
	)
	requireAdminClientCert := flags.Bool(
		"require-admin-client-cert",
		envBool("POINTY_RELAY_REQUIRE_ADMIN_CLIENT_CERT", false),
		"require a verified client certificate for admin control endpoints",
	)
	allowInsecureHTTP := flags.Bool(
		"allow-insecure-http",
		envBool("POINTY_RELAY_ALLOW_INSECURE_HTTP", false),
		"allow cleartext HTTP listener for local development",
	)
	connectorTLSCert := flags.String(
		"connector-tls-cert",
		envString("POINTY_RELAY_CONNECTOR_TLS_CERT", ""),
		"TLS certificate for connector listener",
	)
	connectorTLSKey := flags.String(
		"connector-tls-key",
		envString("POINTY_RELAY_CONNECTOR_TLS_KEY", ""),
		"TLS key for connector listener",
	)
	connectorTLSServerName := flags.String(
		"connector-tls-server-name",
		envString("POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME", ""),
		"DNS name or IP to include when auto-generating connector listener TLS material",
	)
	connectorClientCA := flags.String(
		"connector-client-ca",
		envString("POINTY_RELAY_CONNECTOR_CLIENT_CA", ""),
		"client CA bundle required for connector mTLS",
	)
	connectorClientCAKey := flags.String(
		"connector-client-ca-key",
		envString("POINTY_RELAY_CONNECTOR_CLIENT_CA_KEY", ""),
		"client CA private key used to issue connector mTLS certificates",
	)
	connectorHandshakeRate := flags.Int(
		"connector-handshake-rate",
		envInt("POINTY_RELAY_CONNECTOR_HANDSHAKE_RATE", 50),
		"new connector tunnels this node takes per second, TCP and WebSocket together (0 = no limit)",
	)
	connectorHandshakeBurst := flags.Int(
		"connector-handshake-burst",
		envInt("POINTY_RELAY_CONNECTOR_HANDSHAKE_BURST", 100),
		"new connector tunnels this node takes at once before the per-second limit applies",
	)
	connectorTunnels := flags.Int(
		"connector-tunnels",
		envInt("POINTY_RELAY_CONNECTOR_TUNNELS", 2),
		"tunnels each shop keeps open, each on its own node where more than one is live (1-4)",
	)
	tunnelRedirect := flags.Bool(
		"tunnel-redirect",
		envBool("POINTY_RELAY_TUNNEL_REDIRECT", true),
		"let a node send an arriving tunnel straight to a lighter node's own address; off, it turns the tunnel away and the balancer picks again",
	)
	nodePublicURLTemplate := flags.String(
		"node-public-url-template",
		envString("POINTY_RELAY_NODE_PUBLIC_URL_TEMPLATE", ""),
		"this node's own public https origin, {hostname} for the container hostname; empty tries https://<hostname> then reverse DNS, \"none\" advertises no address",
	)
	drainTimeout := flags.Duration(
		"drain-timeout",
		envDuration("POINTY_RELAY_DRAIN_TIMEOUT", 20*time.Second),
		"on SIGTERM, how long this node waits for its tunnels to move to other nodes and its requests to finish before it closes the rest; keep it, plus 5s, below the platform's stop grace period",
	)
	connectorHold := flags.Duration(
		"connector-hold",
		envDuration("POINTY_RELAY_CONNECTOR_HOLD", 8*time.Second),
		"how long a request waits for a shop that is between tunnels before it is answered 503 (0: answer at once)",
	)
	rebalance := flags.Bool(
		"rebalance",
		envBool("POINTY_RELAY_REBALANCE", true),
		"let a node that holds more than its share of tunnels hand some to the lightest node",
	)
	connectorClientCertTTL := flags.Duration(
		"connector-client-cert-ttl",
		envDuration("POINTY_RELAY_CONNECTOR_CLIENT_CERT_TTL", 90*24*time.Hour),
		"connector client certificate TTL",
	)
	autoTLS := flags.Bool(
		"auto-tls",
		envBool("POINTY_RELAY_AUTO_TLS", true),
		"auto-generate missing relay TLS material in PostgreSQL",
	)
	generatedTLSCATTL := flags.Duration(
		"generated-tls-ca-ttl",
		envDuration("POINTY_RELAY_GENERATED_TLS_CA_TTL", defaultGeneratedTLSCATTL),
		"TTL for auto-generated relay TLS CA material",
	)
	generatedTLSServerCertTTL := flags.Duration(
		"generated-tls-server-cert-ttl",
		envDuration("POINTY_RELAY_GENERATED_TLS_SERVER_CERT_TTL", defaultGeneratedTLSServerCertTTL),
		"TTL for auto-generated relay server TLS certificates",
	)
	generatedTLSRotationWindow := flags.Duration(
		"generated-tls-rotation-window",
		envDuration("POINTY_RELAY_GENERATED_TLS_ROTATION_WINDOW", defaultGeneratedTLSRotationWindow),
		"rotation window for auto-generated relay server TLS certificates",
	)
	allowInsecureConnector := flags.Bool(
		"allow-insecure-connector",
		envBool("POINTY_RELAY_ALLOW_INSECURE_CONNECTOR", false),
		"allow cleartext connector listener for local development",
	)
	databaseURL := flags.String(
		"database-url",
		envString("POINTY_RELAY_DATABASE_URL", defaultRelayDatabaseURL),
		"PostgreSQL database URL for relay installations",
	)
	autoMigrate := flags.Bool(
		"auto-migrate",
		envBool("POINTY_RELAY_AUTO_MIGRATE", false),
		"apply pending PostgreSQL migrations on startup before serving (default on for the paas profile)",
	)
	redisURL := flags.String(
		"redis-url",
		envString("POINTY_RELAY_REDIS_URL", defaultRelayRedisURL),
		"Redis URL for relay cache and connector presence",
	)
	nodeIDFlag := flags.String(
		"node-id",
		envString("POINTY_RELAY_NODE_ID", ""),
		"stable relay node id for Redis connector ownership",
	)
	nodeInternalURL := flags.String(
		"node-internal-url",
		envString("POINTY_RELAY_NODE_INTERNAL_URL", ""),
		"direct HTTPS URL other relay nodes use for internal node relay",
	)
	nodeProxyToken := flags.String(
		"node-proxy-token",
		envString("POINTY_RELAY_NODE_PROXY_TOKEN", ""),
		"shared bearer secret required for relay node-to-node routing",
	)
	draining := flags.Bool(
		"draining",
		envBool("POINTY_RELAY_DRAINING", false),
		"mark this relay node as draining; readiness fails and new connector sessions are rejected",
	)
	allowInsecureNodeProxy := flags.Bool(
		"allow-insecure-node-proxy",
		envBool("POINTY_RELAY_ALLOW_INSECURE_NODE_PROXY", false),
		"allow HTTP node-to-node relay URLs for local development",
	)
	artifactDir := flags.String(
		"artifact-dir",
		envString("POINTY_RELAY_ARTIFACT_DIR", defaultArtifactDir),
		"directory for on-prem update bundles the relay serves to the fleet; mount a volume here to persist across redeploys",
	)
	ticketTTL := flags.Duration(
		"ticket-ttl",
		envDuration("POINTY_RELAY_TICKET_TTL", 15*time.Minute),
		"short-lived relay ticket TTL",
	)
	ticketRefreshTTL := flags.Duration(
		"ticket-refresh-ttl",
		envDuration("POINTY_RELAY_TICKET_REFRESH_TTL", 7*24*time.Hour),
		"rotating relay ticket refresh token TTL",
	)
	subscriptionSweepInterval := flags.Duration(
		"subscription-sweep-interval",
		envDuration("POINTY_RELAY_SUBSCRIPTION_SWEEP_INTERVAL", time.Hour),
		"how often to deactivate installations whose fixed-term subscription has expired (0 disables)",
	)
	streamOpenTimeout := flags.Duration(
		"stream-open-timeout",
		envDuration("POINTY_RELAY_STREAM_OPEN_TIMEOUT", 5*time.Second),
		"timeout for opening a stream to the connector",
	)
	relayRequestTimeout := flags.Duration(
		"relay-request-timeout",
		envDuration("POINTY_RELAY_REQUEST_TIMEOUT", 60*time.Second),
		"total timeout for a relayed HTTP request",
	)
	maxRelayedRequestBodyBytes := flags.Int64(
		"max-relayed-request-body-bytes",
		envInt64("POINTY_RELAY_MAX_REQUEST_BODY_BYTES", defaultMaxRelayedRequestBodyBytes),
		"maximum relayed client request body bytes; set 0 to disable",
	)
	maxRelayedResponseBodyBytes := flags.Int64(
		"max-relayed-response-body-bytes",
		envInt64("POINTY_RELAY_MAX_RESPONSE_BODY_BYTES", defaultMaxRelayedResponseBodyBytes),
		"maximum relayed backend response body bytes; set 0 to disable",
	)
	maxConcurrentRelayRequests := flags.Int(
		"max-concurrent-relay-requests",
		envInt("POINTY_RELAY_MAX_CONCURRENT_REQUESTS", 512),
		"maximum concurrent relayed HTTP requests; set 0 to disable",
	)
	rateLimitWindow := flags.Duration(
		"rate-limit-window",
		envDuration("POINTY_RELAY_RATE_LIMIT_WINDOW", defaultRateLimitWindow),
		"window used for Redis-backed relay rate limits",
	)
	relayRequestRateLimit := flags.Int(
		"relay-request-rate-limit",
		envInt("POINTY_RELAY_RATE_LIMIT_RELAY_REQUESTS", 600),
		"maximum relayed HTTP requests per installation per rate-limit window; set 0 to disable",
	)
	ticketIssueRateLimit := flags.Int(
		"ticket-issue-rate-limit",
		envInt("POINTY_RELAY_RATE_LIMIT_TICKET_ISSUE", 60),
		"maximum relay tickets issued per installation/device per rate-limit window; set 0 to disable",
	)
	remoteSignInRateLimit := flags.Int(
		"remote-sign-in-rate-limit",
		envInt("POINTY_RELAY_RATE_LIMIT_REMOTE_SIGN_IN", 60),
		"maximum sign-in route requests (installation ID, no ticket) per installation per rate-limit window; set 0 to disable",
	)
	remoteSignInClientRateLimit := flags.Int(
		"remote-sign-in-client-rate-limit",
		envInt("POINTY_RELAY_RATE_LIMIT_REMOTE_SIGN_IN_CLIENT", 20),
		"maximum sign-in route requests per installation and caller address per rate-limit window; set 0 to disable",
	)
	ticketRefreshRateLimit := flags.Int(
		"ticket-refresh-rate-limit",
		envInt("POINTY_RELAY_RATE_LIMIT_TICKET_REFRESH", 120),
		"maximum relay ticket refresh attempts per refresh token per rate-limit window; set 0 to disable",
	)
	adminToken := flags.String(
		"admin-token",
		envString("POINTY_RELAY_ADMIN_TOKEN", ""),
		"bearer token required for admin control endpoints",
	)
	allowOpenAdmin := flags.Bool(
		"allow-open-admin",
		envBool("POINTY_RELAY_ALLOW_OPEN_ADMIN", false),
		"allow unauthenticated admin control endpoints for local development",
	)
	production := flags.Bool(
		"production",
		envBool("POINTY_RELAY_PRODUCTION", false),
		"enforce production relay security configuration",
	)
	fulusToken := flags.String(
		"fulus-token",
		envString("POINTY_RELAY_FULUS_TOKEN", ""),
		"fulus.ly API token for the exchange-rate feed; empty disables polling",
	)
	fulusBaseURL := flags.String(
		"fulus-base-url",
		envString("POINTY_RELAY_FULUS_BASE_URL", "https://fulus.ly/api/v1"),
		"fulus.ly API base URL",
	)
	fulusPollInterval := flags.Duration(
		"fulus-poll-interval",
		envDuration("POINTY_RELAY_FULUS_POLL_INTERVAL", 30*time.Minute),
		"how often to sweep fulus.ly as a backstop behind the webhook; their quota is daily, so keep this modest",
	)
	fulusWebhookSecret := flags.String(
		"fulus-webhook-secret",
		envString("POINTY_RELAY_FULUS_WEBHOOK_SECRET", ""),
		"shared secret verifying fulus.ly rate webhooks; empty disables the webhook endpoint",
	)
	resalaAPIToken := flags.String(
		"resala-api-token",
		envString("POINTY_RELAY_RESALA_API_TOKEN", ""),
		"Resala (resala.ly) API token for relay-hosted SMS; empty disables SMS",
	)
	resalaBaseURL := flags.String(
		"resala-base-url",
		envString("POINTY_RELAY_RESALA_BASE_URL", "https://dev.resala.ly/api/v1"),
		"Resala API base URL",
	)
	smsTemplates := flags.String(
		"sms-templates",
		envString("POINTY_RELAY_SMS_TEMPLATES", ""),
		`JSON object mapping each SMS kind to its approved Resala template id, e.g. {"invoice":"<uuid>"}`,
	)
	smsTestMode := flags.Bool(
		"sms-test-mode",
		envBool("POINTY_RELAY_SMS_TEST_MODE", false),
		"send every SMS in Resala test mode (no message delivered, nothing charged)",
	)
	smsPrice := flags.String(
		"sms-price",
		envString("POINTY_RELAY_SMS_PRICE", "0.150"),
		"what one SMS part costs a shop, in dinars (up to three decimals), paid from its SMS balance; a message longer than one SMS (70 Arabic letters, 67 per part beyond) pays once per part, as Resala bills",
	)
	smsRateLimit := flags.String(
		"sms-rate-limit",
		envString("POINTY_RELAY_SMS_RATE_LIMIT", "60/minute"),
		"per-installation SMS burst limit, e.g. 60/minute; 0 disables",
	)
	smsRequestTimeout := flags.Duration(
		"sms-request-timeout",
		envDuration("POINTY_RELAY_SMS_REQUEST_TIMEOUT", 20*time.Second),
		"timeout for one Resala call",
	)
	smsMaxVariableRunes := flags.Int(
		"sms-max-variable-runes",
		envInt("POINTY_RELAY_SMS_MAX_VARIABLE_RUNES", 320),
		"maximum characters in one SMS template variable",
	)
	smsDeliverySyncInterval := flags.Duration(
		"sms-delivery-sync-interval",
		envDuration("POINTY_RELAY_SMS_DELIVERY_SYNC_INTERVAL", 5*time.Minute),
		"how often to read Resala's delivery log back into the SMS ledger; 0 disables",
	)
	customerOTPTemplate := flags.String(
		"customer-otp-template",
		envString("POINTY_RELAY_CUSTOMER_OTP_TEMPLATE", ""),
		"approved Resala template id the «دفتر كروت» sign-in codes go out with ($1 = the code, $2 = the Android app hash); empty turns customer sign-in off",
	)
	customerAndroidAppHash := flags.String(
		"customer-android-app-hash",
		envString("POINTY_RELAY_CUSTOMER_ANDROID_APP_HASH", ""),
		"the card app's 11-character Android SMS Retriever hash, sent as $2 so Android reads the code by itself",
	)
	customerOTPTestMode := flags.Bool(
		"customer-otp-test-mode",
		envBool("POINTY_RELAY_CUSTOMER_OTP_TEST_MODE", false),
		"development only: text no sign-in code and answer it in the response",
	)
	customerOTPTTL := flags.Duration(
		"customer-otp-ttl",
		envDuration("POINTY_RELAY_CUSTOMER_OTP_TTL", 5*time.Minute),
		"how long a sign-in code is good for",
	)
	customerOTPResendAfter := flags.Duration(
		"customer-otp-resend-after",
		envDuration("POINTY_RELAY_CUSTOMER_OTP_RESEND_AFTER", 30*time.Second),
		"shortest gap between two sign-in codes to one phone",
	)
	customerOTPDailyLimit := flags.Int(
		"customer-otp-daily-limit",
		envInt("POINTY_RELAY_CUSTOMER_OTP_DAILY_LIMIT", 6),
		"most sign-in codes one phone gets per Libyan day (each is an SMS the company pays for)",
	)
	customerOTPMaxAttempts := flags.Int(
		"customer-otp-max-attempts",
		envInt("POINTY_RELAY_CUSTOMER_OTP_MAX_ATTEMPTS", 5),
		"wrong guesses one sign-in code takes before it is spent",
	)
	customerAccessTTL := flags.Duration(
		"customer-access-ttl",
		envDuration("POINTY_RELAY_CUSTOMER_ACCESS_TTL", time.Hour),
		"lifetime of a customer access token",
	)
	customerSessionTTL := flags.Duration(
		"customer-session-ttl",
		envDuration("POINTY_RELAY_CUSTOMER_SESSION_TTL", 90*24*time.Hour),
		"how long a customer device stays signed in without opening the app; each refresh renews it",
	)
	customerOTPRateLimit := flags.String(
		"customer-otp-rate-limit",
		envString("POINTY_RELAY_CUSTOMER_OTP_RATE_LIMIT", "10/hour"),
		"sign-in codes one caller address may ask for, e.g. 10/hour; 0 disables",
	)
	customerVerifyRateLimit := flags.String(
		"customer-verify-rate-limit",
		envString("POINTY_RELAY_CUSTOMER_VERIFY_RATE_LIMIT", "30/10m"),
		"sign-in attempts one caller address may make, e.g. 30/10m; 0 disables",
	)
	customerReviewPhone := flags.String(
		"customer-review-phone",
		envString("POINTY_RELAY_CUSTOMER_REVIEW_PHONE", ""),
		"app store review account: this number is never texted and signs in with the review code",
	)
	customerChannelCategories := flags.String(
		"customer-channel-categories",
		envString("POINTY_RELAY_CUSTOMER_CHANNEL_CATEGORIES", ""),
		`JSON object of card-app channel (ios, play, apk, web) -> the catalog categories it may sell, e.g. {"ios":["telecom","internet"]}; a channel left out sells everything, except ios, which defaults to telecom, intl_topup and internet (App Store rule 3.1.1)`,
	)
	customerOrderTTL := flags.Duration(
		"customer-order-ttl",
		envDuration("POINTY_RELAY_CUSTOMER_ORDER_TTL", 30*time.Minute),
		"how long a card-app order waits for its payment before it is written off",
	)
	customerOrderRateLimit := flags.String(
		"customer-order-rate-limit",
		envString("POINTY_RELAY_CUSTOMER_ORDER_RATE_LIMIT", "20/hour"),
		"card-app orders one customer may place, e.g. 20/hour; 0 disables",
	)
	customerWebOrigins := flags.String(
		"customer-web-origins",
		envString("POINTY_RELAY_CUSTOMER_WEB_ORIGINS", ""),
		"comma-separated origins the card app's web build is served from (https://cards.dftr.ly); browsers on them may call the customer routes",
	)
	cardsWebHosts := flags.String(
		"cards-web-hosts",
		envString("POINTY_RELAY_CARDS_WEB_HOSTS", ""),
		"comma-separated hosts the card app's web build is served on (cards.dftr.ly); their https origins may call the customer routes. Empty serves no web app",
	)
	cardsWebDir := flags.String(
		"cards-web-dir",
		envString("POINTY_RELAY_CARDS_WEB_DIR", defaultCardsWebDir),
		"the card app's web build (index.html at its root); the relay image carries one here",
	)
	appWebHosts := flags.String(
		"app-web-hosts",
		envString("POINTY_RELAY_APP_WEB_HOSTS", ""),
		"comma-separated hosts the shop app's web build is served on (app.dftr.ly); its /api/ is this relay's own. Empty serves no web app",
	)
	appWebDir := flags.String(
		"app-web-dir",
		envString("POINTY_RELAY_APP_WEB_DIR", defaultAppWebDir),
		"the shop app's web build (index.html at its root); the relay image carries one here",
	)
	fcmServiceAccount := flags.String(
		"fcm-service-account",
		envString("POINTY_RELAY_FCM_SERVICE_ACCOUNT", ""),
		"the «دفتر كروت» Firebase project's service account key (the JSON itself, or a path to it); the console sends notifications through it. Empty sends none",
	)
	customerReviewCode := flags.String(
		"customer-review-code",
		envString("POINTY_RELAY_CUSTOMER_REVIEW_CODE", ""),
		"the review account's fixed 6-digit code",
	)
	dafaAPIKey := flags.String(
		"dafa-api-key",
		envString("POINTY_RELAY_DAFA_API_KEY", ""),
		"Dafa (dafa.ly) API key for shop wallet top-ups; a dafa_test_ key makes only simulated payments, dafa_live_ real ones",
	)
	dafaBaseURL := flags.String(
		"dafa-base-url",
		envString("POINTY_RELAY_DAFA_BASE_URL", "https://dev.dafa.ly/api/v1"),
		"Dafa API base URL, as the project's Integration page shows it",
	)
	dafaCardGatewayURL := flags.String(
		"dafa-card-gateway-url",
		envString("POINTY_RELAY_DAFA_CARD_GATEWAY_URL", dafa.DefaultCardGatewayURL),
		"where Dafa's card page reads its signed Moamalat sessions; the card app's own card form uses it, and off sends card payers to Dafa's page",
	)
	dafaRequestTimeout := flags.Duration(
		"dafa-request-timeout",
		envDuration("POINTY_RELAY_DAFA_REQUEST_TIMEOUT", 20*time.Second),
		"timeout for one Dafa call",
	)
	bnplusBaseURL := flags.String(
		"bnplus-base-url",
		envString("POINTY_RELAY_BNPLUS_BASE_URL", bnplus.DefaultBaseURL),
		"BN Plus merchant portal (portal.bn-plusli.ly); the API root /api/merchant is appended",
	)
	bnplusEmail := flags.String(
		"bnplus-email",
		envString("POINTY_RELAY_BNPLUS_EMAIL", ""),
		"the company's BN Plus merchant e-mail (Api-Email); with the password and token it turns BN Plus on",
	)
	bnplusPassword := flags.String(
		"bnplus-password",
		envString("POINTY_RELAY_BNPLUS_PASSWORD", ""),
		"the company's BN Plus merchant password (Api-Password)",
	)
	bnplusToken := flags.String(
		"bnplus-token",
		envString("POINTY_RELAY_BNPLUS_TOKEN", ""),
		"the company's BN Plus merchant bearer token",
	)
	bnplusRequestTimeout := flags.Duration(
		"bnplus-request-timeout",
		envDuration("POINTY_RELAY_BNPLUS_REQUEST_TIMEOUT", 45*time.Second),
		"timeout for one BN Plus call (a purchase waits on BN Plus's own suppliers for the codes)",
	)
	reloadlyClientID := flags.String(
		"reloadly-client-id",
		envString("POINTY_RELAY_RELOADLY_CLIENT_ID", ""),
		"the company's Reloadly API client id; with the secret it turns Reloadly on as a card supplier (and for direct top-up and bills)",
	)
	reloadlyClientSecret := flags.String(
		"reloadly-client-secret",
		envString("POINTY_RELAY_RELOADLY_CLIENT_SECRET", ""),
		"the company's Reloadly API client secret",
	)
	reloadlySandbox := flags.Bool(
		"reloadly-sandbox",
		envBool("POINTY_RELAY_RELOADLY_SANDBOX", false),
		"use Reloadly's SANDBOX hosts (fake money, a different catalog): sandbox keys only work there and live keys only on the live hosts",
	)
	reloadlyRequestTimeout := flags.Duration(
		"reloadly-request-timeout",
		envDuration("POINTY_RELAY_RELOADLY_REQUEST_TIMEOUT", 45*time.Second),
		"timeout for one Reloadly purchase call",
	)
	servicesDirectoryInterval := flags.Duration(
		"reloadly-directory-interval",
		envDuration("POINTY_RELAY_RELOADLY_DIRECTORY_INTERVAL", defaultServicesDirectoryInterval),
		"how often the countries, operators and billers of direct top-up and bill payments are read from Reloadly again; 0 reads them once",
	)
	servicesSettleWait := flags.Duration(
		"services-settle-wait",
		envDuration("POINTY_RELAY_SERVICES_SETTLE_WAIT", defaultServicesSettleWait),
		"how long a bill payment Reloadly accepted is waited for before it is left held for the reconciler",
	)
	vouchersTestMode := flags.Bool(
		"vouchers-test-mode",
		envBool("POINTY_RELAY_VOUCHERS_TEST_MODE", false),
		"sell every card from the built-in test supplier: fake TEST- codes, no supplier called, voucher balances still charged",
	)
	vouchersSyncInterval := flags.Duration(
		"vouchers-sync-interval",
		envDuration("POINTY_RELAY_VOUCHERS_SYNC_INTERVAL", 30*time.Minute),
		"how often supplier offers (price, stock) are read; 0 disables",
	)
	voucherStockKey := flags.String(
		"voucher-stock-key",
		envString("POINTY_RELAY_VOUCHER_STOCK_KEY", ""),
		"base64 key (32 bytes, pointy-relay gen-stock-key) that seals the company's own card stock codes; empty turns the stock off. Losing it loses every code in stock",
	)
	moamalatTokenKey := flags.String(
		"moamalat-token-key",
		envString("POINTY_RELAY_MOAMALAT_TOKEN_KEY", ""),
		"base64 key (32 bytes, pointy-relay gen-moamalat-key) that seals the shops' Moamalat tokens; empty turns the relay's keepalive off. Losing it costs each linked shop one re-link",
	)
	moamalatBaseURL := flags.String(
		"moamalat-base-url",
		envString("POINTY_RELAY_MOAMALAT_BASE_URL", ""),
		"Moamalat merchant portal API base (default https://merchant.moamalat.net/api)",
	)
	vouchersRateLimit := flags.String(
		"vouchers-rate-limit",
		envString("POINTY_RELAY_VOUCHERS_RATE_LIMIT", "30/minute"),
		"per-installation card purchase limit, e.g. 30/minute; 0 disables",
	)
	walletMethods := flags.String(
		"wallet-methods",
		envString("POINTY_RELAY_WALLET_METHODS", ""),
		"comma-separated top-up methods to offer, in order (e.g. moamalat,sadad,edfali); empty offers all seven",
	)
	publicURL := flags.String(
		"public-url",
		envString("POINTY_RELAY_PUBLIC_URL", ""),
		"the relay's public origin (https://...), where Dafa's payment webhook reaches it; empty derives it per request",
	)
	connectorEndpoints := flags.String(
		"connector-endpoints",
		envString("POINTY_RELAY_CONNECTOR_ENDPOINTS", ""),
		"tunnel addresses every connector is told to dial, best first (wss://host/v1/connector/tunnel, tls://host:port); empty derives the tunnel over HTTPS from --public-url, \"none\" advertises nothing",
	)
	publicPagesURL := flags.String(
		"public-pages-url",
		envString("POINTY_RELAY_PUBLIC_PAGES_URL", ""),
		"the https origin of customer-facing pages (public invoices), e.g. https://shop.dftr.ly; shops put it on their links. Empty keeps each shop's own setting",
	)
	consoleOrigin := flags.String(
		"console-origin",
		envString("POINTY_RELAY_CONSOLE_ORIGIN", ""),
		"the operator console's origin (https://relay.example.com); passkeys bind to its host name, so use the stable domain. Empty turns the console off",
	)
	consoleRPID := flags.String(
		"console-rp-id",
		envString("POINTY_RELAY_CONSOLE_RP_ID", ""),
		"the domain passkeys bind to: the console origin's host or a parent of it (dftr.ly for https://my.dftr.ly); empty uses the host",
	)
	consoleTrustForwardedFor := flags.Bool(
		"console-trust-forwarded-for",
		envBool("POINTY_RELAY_CONSOLE_TRUST_FORWARDED_FOR", false),
		"take the console caller's address from the load balancer's X-Forwarded-For hop (on by default in the paas profile)",
	)
	walletTopUpMin := flags.String(
		"wallet-topup-min",
		envString("POINTY_RELAY_WALLET_TOPUP_MIN", "10"),
		"smallest wallet top-up in dinars",
	)
	walletTopUpMax := flags.String(
		"wallet-topup-max",
		envString("POINTY_RELAY_WALLET_TOPUP_MAX", "5000"),
		"largest wallet top-up in dinars",
	)
	walletQuickAmounts := flags.String(
		"wallet-quick-amounts",
		envString("POINTY_RELAY_WALLET_QUICK_AMOUNTS", "50,100,200,500"),
		"comma-separated amounts the app offers as one-tap top-ups",
	)
	walletFeePercent := flags.String(
		"wallet-dafa-fee-percent",
		envString("POINTY_RELAY_WALLET_DAFA_FEE_PERCENT", "2"),
		"percent of every Dafa top-up kept out of the wallet credit to cover the gateway's fee (0 keeps nothing)",
	)
	walletTopUpTTL := flags.Duration(
		"wallet-topup-ttl",
		envDuration("POINTY_RELAY_WALLET_TOPUP_TTL", 30*time.Minute),
		"how long a top-up stays pending before it is written off as expired (a payment Dafa proves later still credits it)",
	)
	walletTopUpRateLimit := flags.String(
		"wallet-topup-rate-limit",
		envString("POINTY_RELAY_WALLET_TOPUP_RATE_LIMIT", "10/minute"),
		"per-installation limit on starting top-ups, e.g. 10/minute; 0 disables",
	)
	remoteAccessPrice := flags.String(
		"remote-access-price",
		envString("POINTY_RELAY_REMOTE_ACCESS_PRICE", ""),
		"what one period of remote access costs a shop, in dinars, paid from its wallet; empty: not sold through the wallet",
	)
	aiPrice := flags.String(
		"ai-price",
		envString("POINTY_RELAY_AI_PRICE", ""),
		"what one period of the AI assistant costs a shop, in dinars, paid from its wallet; empty: not sold through the wallet",
	)
	planDays := flags.Int(
		"plan-days",
		envInt("POINTY_RELAY_PLAN_DAYS", 30),
		"how many days one period of a wallet-paid plan lasts",
	)
	openRouterAPIKey := flags.String(
		"openrouter-api-key",
		envString("POINTY_RELAY_OPENROUTER_API_KEY", ""),
		"OpenRouter API key for relay-hosted AI chat; empty disables AI",
	)
	openRouterBaseURL := flags.String(
		"openrouter-base-url",
		envString("POINTY_RELAY_OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1"),
		"OpenRouter-compatible chat completions base URL",
	)
	aiModelFast := flags.String(
		"ai-model-fast",
		envString("POINTY_RELAY_AI_MODEL_FAST", "meta-llama/llama-3.1-8b-instruct"),
		"OpenRouter model id for the fast/cheap AI tier",
	)
	aiModelSmart := flags.String(
		"ai-model-smart",
		envString("POINTY_RELAY_AI_MODEL_SMART", "openai/gpt-4o-mini"),
		"OpenRouter model id for the smart/balanced AI tier",
	)
	aiModelFrontier := flags.String(
		"ai-model-frontier",
		envString("POINTY_RELAY_AI_MODEL_FRONTIER", "anthropic/claude-3.7-sonnet"),
		"OpenRouter model id for the frontier AI tier",
	)
	aiDefaultTier := flags.String(
		"ai-default-tier",
		envString("POINTY_RELAY_AI_DEFAULT_TIER", "smart"),
		"AI tier used as the router fallback (fast|smart|frontier)",
	)
	aiRouterModel := flags.String(
		"ai-router-model",
		envString("POINTY_RELAY_AI_ROUTER_MODEL", ""),
		"model that classifies prompt difficulty to auto-pick a tier; empty uses the fast-tier model",
	)
	aiRequestTimeout := flags.Duration(
		"ai-request-timeout",
		envDuration("POINTY_RELAY_AI_REQUEST_TIMEOUT", 120*time.Second),
		"total timeout for a relay-hosted AI streaming request",
	)
	aiChatRateLimit := flags.Int(
		"ai-chat-rate-limit",
		envInt("POINTY_RELAY_AI_RATE_LIMIT", 120),
		"maximum AI chat requests per installation per rate-limit window; set 0 to disable",
	)
	aiVisionModel := flags.String(
		"ai-vision-model",
		envString("POINTY_RELAY_AI_VISION_MODEL", "google/gemma-4-31b-it:free"),
		"OpenRouter model used when a prompt carries image/file attachments",
	)
	aiAudioModel := flags.String(
		"ai-audio-model",
		envString("POINTY_RELAY_AI_AUDIO_MODEL", ""),
		"OpenRouter model used when a prompt carries a recorded voice clip; empty falls back to the vision model",
	)
	aiExtractModel := flags.String(
		"ai-extract-model",
		envString("POINTY_RELAY_AI_EXTRACT_MODEL", ""),
		"OpenRouter model used to read a document into a fixed JSON schema; empty falls back to the vision model",
	)
	aiWebSearchEnabled := flags.Bool(
		"ai-web-search-enabled",
		envBool("POINTY_RELAY_AI_WEB_SEARCH_ENABLED", true),
		"let the assistant web-search for current info when a query needs it (gated by a cheap classifier)",
	)
	aiWebSearchMaxResults := flags.Int(
		"ai-web-search-max-results",
		envInt("POINTY_RELAY_AI_WEB_SEARCH_MAX_RESULTS", 3),
		"max web-search results per query (cost control)",
	)
	aiLimit5H := flags.Int(
		"ai-limit-5h",
		envInt("POINTY_RELAY_AI_LIMIT_5H", 30),
		"max AI messages per installation per 5-hour window; set 0 to disable",
	)
	aiLimit5HWindow := flags.Duration(
		"ai-limit-5h-window",
		envDuration("POINTY_RELAY_AI_LIMIT_5H_WINDOW", 5*time.Hour),
		"rolling window for the 5-hour AI message limit",
	)
	aiLimitWeekly := flags.Int(
		"ai-limit-weekly",
		envInt("POINTY_RELAY_AI_LIMIT_WEEKLY", 200),
		"max AI messages per installation per weekly window; set 0 to disable",
	)
	aiLimitWeeklyWindow := flags.Duration(
		"ai-limit-weekly-window",
		envDuration("POINTY_RELAY_AI_LIMIT_WEEKLY_WINDOW", 168*time.Hour),
		"rolling window for the weekly AI message limit",
	)
	aiMaxImages := flags.Int(
		"ai-max-images",
		envInt("POINTY_RELAY_AI_MAX_IMAGES", 5),
		"maximum images per AI prompt; set 0 to disable",
	)
	aiMaxRequestBytes := flags.Int64(
		"ai-max-request-bytes",
		envInt64("POINTY_RELAY_AI_MAX_REQUEST_BYTES", 16<<20),
		"maximum AI chat request body bytes (prompt + base64 attachments)",
	)
	openSERPBaseURL := flags.String(
		"openserp-base-url",
		envString("POINTY_RELAY_OPENSERP_BASE_URL", ""),
		"base URL of the self-hosted OpenSERP server for relay-hosted product image search, e.g. http://10.0.0.5:7000; empty disables image search",
	)
	openSERPEngines := flags.String(
		"openserp-engines",
		envString("POINTY_RELAY_OPENSERP_ENGINES", "bing,yandex,ecosia"),
		"comma-separated OpenSERP engines asked at once for image search, in merge order (bing, yandex, ecosia, google, duckduckgo, baidu)",
	)
	openSERPLanguage := flags.String(
		"openserp-language",
		envString("POINTY_RELAY_OPENSERP_LANGUAGE", "ar"),
		"OpenSERP image search language code (lang)",
	)
	openSERPRegion := flags.String(
		"openserp-region",
		envString("POINTY_RELAY_OPENSERP_REGION", ""),
		"OpenSERP image search region code (region); empty leaves it to the engine",
	)
	openRouterManagementKey := flags.String(
		"openrouter-management-key",
		envString("POINTY_RELAY_OPENROUTER_MANAGEMENT_KEY", ""),
		"OpenRouter management key, used ONLY to read the account's credits for the low-balance alert; empty reads what is left under the API key's own limit",
	)
	ntfyServer := flags.String(
		"ntfy-server",
		envString("POINTY_RELAY_NTFY_SERVER", alerts.DefaultServer),
		"ntfy server the company's alerts are published to (the topic is set with `pointy-relay alerts setup`)",
	)
	ntfyToken := flags.String(
		"ntfy-token",
		envString("POINTY_RELAY_NTFY_TOKEN", ""),
		"optional ntfy access token, for a self-hosted server or a reserved topic",
	)
	alertsPrefix := flags.String(
		"alerts-prefix",
		envString("POINTY_RELAY_ALERTS_PREFIX", ""),
		"text before every alert title, e.g. [staging], to tell two relays apart on one phone",
	)
	alertBalanceInterval := flags.Duration(
		"alert-balance-interval",
		envDuration("POINTY_RELAY_ALERT_BALANCE_INTERVAL", 15*time.Minute),
		"how often provider balances are read for the low-balance alerts",
	)
	alertReloadlyFloor := flags.String(
		"alert-reloadly-floor",
		envString("POINTY_RELAY_ALERT_RELOADLY_FLOOR", "50"),
		"alert when the Reloadly balance is at or under this many USD (empty: not watched)",
	)
	alertBNPlusFloor := flags.String(
		"alert-bnplus-floor",
		envString("POINTY_RELAY_ALERT_BNPLUS_FLOOR", "500"),
		"alert when the BN Plus dinar wallet is at or under this many LYD (empty: not watched)",
	)
	alertOpenRouterFloor := flags.String(
		"alert-openrouter-floor",
		envString("POINTY_RELAY_ALERT_OPENROUTER_FLOOR", "3"),
		"alert when OpenRouter credits are at or under this many USD (empty: not watched)",
	)
	imageSearchRequestTimeout := flags.Duration(
		"image-search-request-timeout",
		envDuration("POINTY_RELAY_IMAGE_SEARCH_REQUEST_TIMEOUT", 12*time.Second),
		"total timeout for a relay-hosted product image search request",
	)
	if err := flags.Parse(args); err != nil {
		return err
	}
	// Parsed before anything connects, so a malformed template map or rate
	// stops the relay at startup instead of failing every send later.
	smsConfig, smsWarnings, err := buildSMSConfig(smsSettings{
		Token:                *resalaAPIToken,
		BaseURL:              *resalaBaseURL,
		Templates:            *smsTemplates,
		TestMode:             *smsTestMode,
		Price:                *smsPrice,
		RateLimit:            *smsRateLimit,
		RequestTimeout:       *smsRequestTimeout,
		MaxVariableRunes:     *smsMaxVariableRunes,
		DeliverySyncInterval: *smsDeliverySyncInterval,
	})
	if err != nil {
		return err
	}
	customerConfig, customerWarnings, err := buildCustomerConfig(customerSettings{
		OTPTemplate:       *customerOTPTemplate,
		AndroidAppHash:    *customerAndroidAppHash,
		TestMode:          *customerOTPTestMode,
		CodeTTL:           *customerOTPTTL,
		ResendAfter:       *customerOTPResendAfter,
		DailyLimit:        *customerOTPDailyLimit,
		MaxAttempts:       *customerOTPMaxAttempts,
		AccessTTL:         *customerAccessTTL,
		SessionTTL:        *customerSessionTTL,
		OTPRateLimit:      *customerOTPRateLimit,
		VerifyLimit:       *customerVerifyRateLimit,
		ReviewPhone:       *customerReviewPhone,
		ReviewCode:        *customerReviewCode,
		ChannelCategories: *customerChannelCategories,
		OrderTTL:          *customerOrderTTL,
		OrderRateLimit:    *customerOrderRateLimit,
		WebOrigins:        withCardsWebOrigins(*customerWebOrigins, cardsweb.ParseHosts(*cardsWebHosts)),
		SMS:               smsConfig,
	})
	if err != nil {
		return err
	}
	walletConfig, walletWarnings, err := buildWalletConfig(walletSettings{
		DafaBaseURL:        *dafaBaseURL,
		DafaAPIKey:         *dafaAPIKey,
		DafaCardGatewayURL: *dafaCardGatewayURL,
		Methods:            *walletMethods,
		PublicURL:          *publicURL,
		MinTopUp:           *walletTopUpMin,
		MaxTopUp:           *walletTopUpMax,
		QuickAmounts:       *walletQuickAmounts,
		FeePercent:         *walletFeePercent,
		TopUpTTL:           *walletTopUpTTL,
		TopUpRateLimit:     *walletTopUpRateLimit,
		RequestTimeout:     *dafaRequestTimeout,
		RemoteAccessPrice:  *remoteAccessPrice,
		AIPrice:            *aiPrice,
		PlanDays:           *planDays,
		LegacyPlutu: os.Getenv("POINTY_RELAY_PLUTU_API_KEY") != "" ||
			os.Getenv("POINTY_RELAY_PLUTU_ACCESS_TOKEN") != "" ||
			os.Getenv("POINTY_RELAY_PLUTU_SECRET_KEY") != "",
	})
	if err != nil {
		return err
	}
	publicAddresses, err := buildPublicAddresses(*publicURL, *publicPagesURL)
	if err != nil {
		return err
	}
	advertisedConnectorEndpoints, err := buildConnectorEndpoints(*connectorEndpoints, publicAddresses.API)
	if err != nil {
		return err
	}
	voucherSettingValues := voucherSettings{
		BNPlusBaseURL:        *bnplusBaseURL,
		BNPlusEmail:          *bnplusEmail,
		BNPlusPassword:       *bnplusPassword,
		BNPlusToken:          *bnplusToken,
		ReloadlyClientID:     *reloadlyClientID,
		ReloadlyClientSecret: *reloadlyClientSecret,
		ReloadlySandbox:      *reloadlySandbox,
		ReloadlyTimeout:      *reloadlyRequestTimeout,
		RequestTimeout:       *bnplusRequestTimeout,
		TestMode:             *vouchersTestMode,
		SyncInterval:         *vouchersSyncInterval,
		RateLimit:            *vouchersRateLimit,
		StockKey:             *voucherStockKey,
	}
	voucherConfig, bnplusCredentials, voucherWarnings, err := buildVoucherConfig(voucherSettingValues)
	if err != nil {
		return err
	}
	reloadlyCredentials, reloadlyWarnings := buildReloadlyConfig(voucherSettingValues)
	voucherWarnings = append(voucherWarnings, reloadlyWarnings...)
	profile := strings.ToLower(strings.TrimSpace(*platform))
	if profile == "paas" {
		// A PaaS host (e.g. JPaaS) sits behind the platform load balancer,
		// exposes a single public HTTP endpoint, and is administered remotely
		// over a bearer token. Flip the defaults that only make sense for a
		// private-network deployment so a fresh deploy needs nothing beyond the
		// admin token and the datastore URLs. Each default still yields to an
		// explicit operator override (flag or environment variable).
		if !operatorProvided(flags, "http", "POINTY_RELAY_HTTP_ADDR") {
			*httpAddr = defaultPaaSHTTPAddr()
		}
		if !operatorProvided(flags, "connector", "POINTY_RELAY_CONNECTOR_ADDR") {
			*connectorAddr = "0.0.0.0:8092"
		}
		if !operatorProvided(flags, "console-trust-forwarded-for", "POINTY_RELAY_CONSOLE_TRUST_FORWARDED_FOR") {
			// Behind the platform load balancer every peer is the balancer.
			*consoleTrustForwardedFor = true
		}
		if !operatorProvided(flags, "allow-insecure-http", "POINTY_RELAY_ALLOW_INSECURE_HTTP") {
			// The load balancer terminates public HTTPS and forwards plain HTTP
			// over the platform's internal network. The connector port keeps its
			// end-to-end mTLS (auto-TLS) because the load balancer passes that
			// raw TCP stream through without decrypting it.
			*allowInsecureHTTP = true
		}
		if !operatorProvided(flags, "auto-migrate", "POINTY_RELAY_AUTO_MIGRATE") {
			*autoMigrate = true
		}
		// Auto-form the node-to-node mesh so horizontal autoscaling needs no
		// per-instance configuration. Every instance shares the admin token, so
		// we derive the inter-node secret from it (identical on every clone, never
		// distributed or stored), and each instance advertises its own LAN address
		// into Redis for peers to reach. Setting POINTY_RELAY_NODE_PROXY_TOKEN
		// (even to empty) opts out.
		if !operatorProvided(flags, "node-proxy-token", "POINTY_RELAY_NODE_PROXY_TOKEN") {
			*nodeProxyToken = deriveNodeProxyToken(*adminToken)
		}
		if strings.TrimSpace(*nodeProxyToken) != "" &&
			!operatorProvided(flags, "node-internal-url", "POINTY_RELAY_NODE_INTERNAL_URL") {
			// A bare-IP URL is only safe to advertise when the internal HTTP hop is
			// cleartext (the paas default). If the operator re-enabled relay-side
			// TLS, the LAN IP wouldn't match the certificate SAN, so we require an
			// explicit POINTY_RELAY_NODE_INTERNAL_URL instead of guessing.
			if *allowInsecureHTTP {
				if ip, ok := primaryPrivateIPv4(); ok {
					if url, ok := nodeURLFor(ip, *httpAddr); ok {
						*nodeInternalURL = url
						if !operatorProvided(flags, "allow-insecure-node-proxy", "POINTY_RELAY_ALLOW_INSECURE_NODE_PROXY") {
							*allowInsecureNodeProxy = true
						}
					}
				}
			}
		}
	}
	if err := validateServerSecurityConfig(serverSecurityConfig{
		Production:             *production,
		Platform:               profile,
		AdminHTTPAddr:          *adminHTTPAddr,
		AdminToken:             *adminToken,
		AllowOpenAdmin:         *allowOpenAdmin,
		AllowInsecureHTTP:      *allowInsecureHTTP,
		HTTPTLSCert:            *httpTLSCert,
		HTTPTLSKey:             *httpTLSKey,
		HTTPTLSServerName:      *httpTLSServerName,
		HTTPAddr:               *httpAddr,
		HTTPClientCA:           *httpClientCA,
		RequireAdminClientCert: *requireAdminClientCert,
		AllowInsecureConnector: *allowInsecureConnector,
		ConnectorTLSCert:       *connectorTLSCert,
		ConnectorTLSKey:        *connectorTLSKey,
		ConnectorTLSServerName: *connectorTLSServerName,
		ConnectorAddr:          *connectorAddr,
		ConnectorClientCA:      *connectorClientCA,
		ConnectorClientCAKey:   *connectorClientCAKey,
		AutoTLS:                *autoTLS,
		NodeInternalURL:        *nodeInternalURL,
		NodeProxyToken:         *nodeProxyToken,
		AllowInsecureNodeProxy: *allowInsecureNodeProxy,
	}); err != nil {
		return err
	}

	// Read here, after the deployment profile settled it.
	customerConfig.TrustForwardedFor = *consoleTrustForwardedFor
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	for _, warning := range smsWarnings {
		logger.Warn("relay sms templates: " + warning)
	}
	for _, warning := range walletWarnings {
		logger.Warn("relay wallet: " + warning)
	}
	for _, warning := range customerWarnings {
		logger.Warn("relay customers: " + warning)
	}
	for _, warning := range voucherWarnings {
		logger.Warn("relay vouchers: " + warning)
	}
	if profile == "paas" {
		logger.Info(
			"relay paas profile active",
			"http_addr", *httpAddr,
			"connector_addr", *connectorAddr,
			"node_internal_url", *nodeInternalURL,
			"node_mesh", strings.TrimSpace(*nodeProxyToken) != "",
			"auto_migrate", *autoMigrate,
		)
		if strings.TrimSpace(*nodeProxyToken) != "" && strings.TrimSpace(*nodeInternalURL) == "" {
			logger.Warn(
				"relay node mesh is enabled but no LAN address could be auto-detected to advertise; " +
					"connectors on this instance will be unreachable from peer nodes. Set " +
					"POINTY_RELAY_NODE_INTERNAL_URL explicitly when running multiple instances.",
			)
		}
	}
	setupCtx, setupCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer setupCancel()

	postgresStore, err := control.NewPostgresStore(setupCtx, *databaseURL, control.RealClock{})
	if err != nil {
		return err
	}
	defer postgresStore.Close()

	if *autoMigrate {
		// Migrations take a Postgres advisory lock, so concurrent autoscaled
		// instances applying them on startup serialize safely.
		if err := postgresStore.Migrate(setupCtx); err != nil {
			return fmt.Errorf("startup migration failed: %w", err)
		}
		logger.Info("relay startup migrations applied")
	}

	redisClient, err := newRedisClient(setupCtx, *redisURL)
	if err != nil {
		return err
	}
	if redisClient != nil {
		defer redisClient.Close()
	}
	autoTLSMaterial, err := prepareRelayAutoTLSMaterial(
		setupCtx,
		postgresStore,
		relayAutoTLSOptions{
			Enabled:           *autoTLS,
			HTTPAddr:          *httpAddr,
			HTTPSName:         *httpTLSServerName,
			HTTPCertFile:      *httpTLSCert,
			HTTPKeyFile:       *httpTLSKey,
			InsecureHTTP:      *allowInsecureHTTP,
			ConnectorAddr:     *connectorAddr,
			ConnectorName:     *connectorTLSServerName,
			ConnectorCert:     *connectorTLSCert,
			ConnectorKey:      *connectorTLSKey,
			ConnectorCA:       *connectorClientCA,
			ConnectorCAKey:    *connectorClientCAKey,
			InsecureConnector: *allowInsecureConnector,
			CATTL:             *generatedTLSCATTL,
			ServerCertTTL:     *generatedTLSServerCertTTL,
			RotationWindow:    *generatedTLSRotationWindow,
		},
		logger,
	)
	if err != nil {
		return err
	}

	store := control.InstallationStore(postgresStore)
	var presence relayserver.ConnectorPresence
	var tickets control.RelayTicketService
	var rateLimiter ratelimit.Limiter
	if redisClient != nil {
		store = control.NewCachedInstallationStore(
			postgresStore,
			control.NewRedisInstallationCache(redisClient, relayRedisKeyPrefix),
			control.RealClock{},
			30*time.Second,
		)
		presence = relayserver.NewRedisConnectorPresence(redisClient, relayRedisKeyPrefix)
		tickets = control.NewRedisRelayTicketService(redisClient, relayRedisKeyPrefix, control.RealClock{})
		rateLimiter = ratelimit.NewRedisLimiter(redisClient, relayRedisKeyPrefix)
		// A card one node found undeliverable is off every node's shelf.
		voucherConfig.Holds.Share(redisClient, relayRedisKeyPrefix)
	}

	nodeID := strings.TrimSpace(*nodeIDFlag)
	if nodeID == "" {
		nodeID, err = relayserver.NewNodeID()
		if err != nil {
			return err
		}
	}
	hub := relayserver.NewHub()
	metrics := observability.NewMetrics()
	var connectorCertificateIssuer relayserver.ConnectorCertificateIssuer
	if strings.TrimSpace(*connectorClientCAKey) != "" ||
		strings.TrimSpace(autoTLSMaterial.ConnectorCAKeyPEM) != "" {
		var issuer *security.CertificateAuthority
		if strings.TrimSpace(*connectorClientCAKey) != "" {
			issuer, err = security.LoadCertificateAuthority(
				*connectorClientCA,
				*connectorClientCAKey,
			)
		} else {
			issuer, err = security.LoadCertificateAuthorityPEM(
				autoTLSMaterial.ConnectorCAPEM,
				autoTLSMaterial.ConnectorCAKeyPEM,
			)
		}
		if err != nil {
			return fmt.Errorf("connector certificate issuer setup failed: %w", err)
		}
		connectorCertificateIssuer = issuer
	}

	connectorListener, err := net.Listen("tcp", *connectorAddr)
	if err != nil {
		return err
	}
	connectorTLSConfig, err := connectorServerTLSConfig(
		*connectorTLSCert,
		*connectorTLSKey,
		autoTLSMaterial.ConnectorServerCertPEM,
		autoTLSMaterial.ConnectorServerKeyPEM,
		*connectorClientCA,
		autoTLSMaterial.ConnectorCAPEM,
		*allowInsecureConnector,
	)
	if err != nil {
		_ = connectorListener.Close()
		return err
	}
	if connectorTLSConfig != nil {
		connectorListener = tls.NewListener(connectorListener, connectorTLSConfig)
	}
	httpListener, err := net.Listen("tcp", *httpAddr)
	if err != nil {
		_ = connectorListener.Close()
		return err
	}
	adminHTTPAddress := strings.TrimSpace(*adminHTTPAddr)
	httpClientCAFile := *httpClientCA
	httpRequiresAdminClientCert := *requireAdminClientCert
	if adminHTTPAddress != "" {
		httpClientCAFile = ""
		httpRequiresAdminClientCert = false
	}
	secureHTTP, err := secureHTTPListener(
		httpListener,
		*httpTLSCert,
		*httpTLSKey,
		autoTLSMaterial.HTTPServerCertPEM,
		autoTLSMaterial.HTTPServerKeyPEM,
		httpClientCAFile,
		"",
		httpRequiresAdminClientCert,
		*allowInsecureHTTP,
	)
	if err != nil {
		_ = connectorListener.Close()
		_ = httpListener.Close()
		return err
	}
	httpListener = secureHTTP
	var adminHTTPListener net.Listener
	if adminHTTPAddress != "" {
		adminHTTPListener, err = net.Listen("tcp", adminHTTPAddress)
		if err != nil {
			_ = connectorListener.Close()
			_ = httpListener.Close()
			return err
		}
		secureAdminHTTP, err := secureHTTPListener(
			adminHTTPListener,
			*httpTLSCert,
			*httpTLSKey,
			autoTLSMaterial.HTTPServerCertPEM,
			autoTLSMaterial.HTTPServerKeyPEM,
			*httpClientCA,
			"",
			*requireAdminClientCert,
			*allowInsecureHTTP,
		)
		if err != nil {
			_ = connectorListener.Close()
			_ = httpListener.Close()
			_ = adminHTTPListener.Close()
			return err
		}
		adminHTTPListener = secureAdminHTTP
	}

	// A stop signal drains the node first (see the end of this function);
	// everything else runs until the drain is over.
	signalCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancelRun := context.WithCancel(context.Background())
	defer cancelRun()
	drain := &relayserver.NodeDrain{}
	if *draining {
		drain.Begin()
	}

	if *connectorTunnels < 1 || *connectorTunnels > protocol.MaxTunnels {
		return fmt.Errorf("POINTY_RELAY_CONNECTOR_TUNNELS must be between 1 and %d", protocol.MaxTunnels)
	}
	// The node's own address, checked by calling it before it is handed out;
	// the registry, through which the nodes place tunnels among themselves.
	publicCandidate, publicSource, err := relayserver.NodePublicAddressCandidate(*nodePublicURLTemplate)
	if err != nil {
		return err
	}
	nodeAddress := &relayserver.NodeAddress{
		NodeID:    nodeID,
		Candidate: publicCandidate,
		Source:    publicSource,
		Logger:    logger,
	}
	var fleet *relayserver.Fleet
	if redisClient != nil {
		fleet = &relayserver.Fleet{
			Registry: relayserver.NewRedisNodeRegistry(redisClient, relayRedisKeyPrefix),
			NodeID:   nodeID,
			Hub:      hub,
			Drain:    drain,
			Stats:    relayserver.NodeStatsOf(hub, metrics, version),
			Address:  nodeAddress,
			Logger:   logger,
		}
	}
	logger.Info(
		"relay node placement",
		"node_id", nodeID,
		"node_internal_url", strings.TrimSpace(*nodeInternalURL),
		"public_address_candidate", publicCandidate,
		"public_address_source", publicSource,
		"registry", fleet != nil,
		"tunnel_redirect", *tunnelRedirect,
		"tunnels_per_shop", *connectorTunnels,
		"rebalance", *rebalance && fleet != nil && presence != nil,
		"drain_timeout", drainTimeout.String(),
		"connector_hold", connectorHold.String(),
	)

	connectorServer := relayserver.ConnectorServer{
		Store:        store,
		Hub:          hub,
		Logger:       logger,
		Metrics:      metrics,
		Presence:     presence,
		NodeID:       nodeID,
		NodeRelayURL: strings.TrimSpace(*nodeInternalURL),
		Drain:        drain,
		HandshakeLimiter: relayserver.NewHandshakeLimiter(
			float64(*connectorHandshakeRate),
			*connectorHandshakeBurst,
		),
		Endpoints:      advertisedConnectorEndpoints,
		TunnelsPerShop: *connectorTunnels,
		Fleet:          fleet,
		TunnelRedirect: *tunnelRedirect,
	}
	var artifactStore *artifacts.Store
	if dir := strings.TrimSpace(*artifactDir); dir != "" {
		as, artErr := artifacts.New(dir)
		switch {
		case artErr == nil:
			artifactStore = as
			logger.Info("relay artifact store ready", "dir", dir)
		case dir != defaultArtifactDir:
			// Operator chose this directory explicitly, so a failure to use it is a
			// misconfiguration worth stopping for.
			return fmt.Errorf("artifact store: %w", artErr)
		default:
			// The auto default isn't usable here (e.g. local dev without
			// /var/lib/pointy). Run without remote update rather than refusing to
			// start — the relay's core duties don't depend on it.
			logger.Warn(
				"relay artifact store disabled: default directory not usable (remote update off)",
				"dir", dir, "error", artErr,
			)
		}
	}

	// All AI traffic (chat stream, router, titles, web-search classifier) and
	// image search each fan out to ONE host; the default Transport keeps only
	// 2 idle connections per host, so overlapping calls paid a fresh TCP+TLS
	// handshake (~100-300ms) to openrouter.ai on nearly every request. One
	// shared, tuned transport lets the whole fleet's AI traffic reuse
	// connections. Timeouts mirror the handlers' own zero-value fallbacks.
	outboundTransport := &http.Transport{
		MaxIdleConns:        200,
		MaxIdleConnsPerHost: 100,
		IdleConnTimeout:     90 * time.Second,
		ForceAttemptHTTP2:   true,
	}
	aiClientTimeout := *aiRequestTimeout
	if aiClientTimeout <= 0 {
		aiClientTimeout = 120 * time.Second
	}
	imageSearchClientTimeout := *imageSearchRequestTimeout
	if imageSearchClientTimeout <= 0 {
		imageSearchClientTimeout = 12 * time.Second
	}
	// Resala shares the tuned transport; the per-call timeout is also applied
	// by the client itself, so this one is only a backstop.
	smsConfig.HTTPClient = &http.Client{Timeout: smsConfig.RequestTimeout + 5*time.Second, Transport: outboundTransport}
	// Dafa likewise; the client applies its own per-call timeout too.
	walletRequestTimeout := walletConfig.RequestTimeout
	if walletRequestTimeout <= 0 {
		walletRequestTimeout = 20 * time.Second
	}
	walletConfig.HTTPClient = &http.Client{Timeout: walletRequestTimeout + 5*time.Second, Transport: outboundTransport}
	// BN Plus likewise; a purchase can wait on BN Plus's own suppliers.
	attachVoucherSuppliers(&voucherConfig, bnplusCredentials,
		&http.Client{Timeout: voucherConfig.RequestTimeout + 10*time.Second, Transport: outboundTransport})
	// Reloadly likewise; its own purchase timeout is the same as the relay's.
	if err := attachReloadlySupplier(&voucherConfig, reloadlyCredentials,
		&http.Client{Timeout: max(voucherConfig.RequestTimeout, reloadlyCredentials.PurchaseTimeout) + 10*time.Second, Transport: outboundTransport}); err != nil {
		return err
	}

	// The company's alert channel; built after the suppliers so their clients
	// can be watched, and before the wallet config is handed out so every
	// top-up path (requests, webhook, reconciler) announces payments.
	alertNotifier, balanceWatcher, err := buildAlerts(alertSettings{
		Server:                  *ntfyServer,
		Token:                   *ntfyToken,
		Prefix:                  *alertsPrefix,
		ConsoleOrigin:           *consoleOrigin,
		BalanceInterval:         *alertBalanceInterval,
		ReloadlyFloor:           *alertReloadlyFloor,
		BNPlusFloor:             *alertBNPlusFloor,
		OpenRouterFloor:         *alertOpenRouterFloor,
		OpenRouterAPIKey:        *openRouterAPIKey,
		OpenRouterBaseURL:       *openRouterBaseURL,
		OpenRouterManagementKey: *openRouterManagementKey,
	}, store, voucherConfig, &http.Client{Timeout: 30 * time.Second, Transport: outboundTransport}, logger)
	if err != nil {
		return err
	}
	walletConfig.Alerts = alertNotifier
	if balanceWatcher.Enabled() {
		go balanceWatcher.Run(ctx)
	}

	// The relay's half of the Moamalat keepalive. A malformed key stops the
	// relay: starting without it would let every linked shop's token lapse.
	moamalatSealer, err := buildMoamalatSealer(*moamalatTokenKey, logger)
	if err != nil {
		return err
	}
	moamalatKeeper := &relayserver.MoamalatKeeper{
		Store:  store,
		Sealer: moamalatSealer,
		Client: &moamalat.Client{
			BaseURL:    strings.TrimSpace(*moamalatBaseURL),
			HTTPClient: &http.Client{Timeout: moamalat.RequestTimeout + 5*time.Second, Transport: outboundTransport},
		},
		Alerts: alertNotifier,
		Logger: logger,
	}
	if moamalatKeeper.Enabled() {
		go moamalatKeeper.Run(ctx)
	}

	servicesService := buildServices(voucherConfig, servicesSettings{
		DirectoryInterval: *servicesDirectoryInterval,
		RequestTimeout:    reloadlyCredentials.PurchaseTimeout,
		SettleWait:        *servicesSettleWait,
		TargetKey:         deriveServicesTargetKey(*adminToken),
	}, logger)

	customerPush, err := buildCustomerPush(*fcmServiceAccount, logger)
	if err != nil {
		return err
	}
	baseHTTPHandler := relayserver.HTTPServer{
		Store:                         store,
		Hub:                           hub,
		Artifacts:                     artifactStore,
		Logger:                        logger,
		AdminToken:                    *adminToken,
		AllowOpenAdmin:                *allowOpenAdmin,
		RequireAdminClientCertificate: *requireAdminClientCert,
		StreamOpenTimeout:             *streamOpenTimeout,
		RelayRequestTimeout:           *relayRequestTimeout,
		MaxRelayedRequestBodyBytes:    *maxRelayedRequestBodyBytes,
		MaxRelayedResponseBodyBytes:   *maxRelayedResponseBodyBytes,
		RelayLimiter:                  limit.New(*maxConcurrentRelayRequests),
		RateLimiter:                   rateLimiter,
		RelayRequestRateLimit:         ratelimit.Policy{Limit: *relayRequestRateLimit, Window: *rateLimitWindow},
		TicketIssueRateLimit:          ratelimit.Policy{Limit: *ticketIssueRateLimit, Window: *rateLimitWindow},
		RemoteSignInRateLimit:         ratelimit.Policy{Limit: *remoteSignInRateLimit, Window: *rateLimitWindow},
		RemoteSignInClientRateLimit:   ratelimit.Policy{Limit: *remoteSignInClientRateLimit, Window: *rateLimitWindow},
		TicketRefreshRateLimit:        ratelimit.Policy{Limit: *ticketRefreshRateLimit, Window: *rateLimitWindow},
		Metrics:                       metrics,
		Presence:                      presence,
		Fleet:                         fleet,
		NodeID:                        nodeID,
		Drain:                         drain,
		ConnectorHold:                 *connectorHold,
		Version:                       version,
		Database:                      postgresStore,
		NodeProxyToken:                strings.TrimSpace(*nodeProxyToken),
		AllowInsecureNodeProxy:        *allowInsecureNodeProxy,
		Tickets:                       tickets,
		TicketTTL:                     *ticketTTL,
		TicketRefreshTTL:              *ticketRefreshTTL,
		ConnectorCertificateIssuer:    connectorCertificateIssuer,
		ConnectorCertificateTTL:       *connectorClientCertTTL,
		Fulus: relayserver.FulusConfig{
			BaseURL:       strings.TrimSpace(*fulusBaseURL),
			Token:         strings.TrimSpace(*fulusToken),
			WebhookSecret: strings.TrimSpace(*fulusWebhookSecret),
		},
		SMS:                  smsConfig,
		Customers:            customerConfig,
		CustomerPush:         customerPush,
		Wallet:               walletConfig,
		Public:               publicAddresses,
		Alerts:               alertNotifier,
		MoamalatSealer:       moamalatSealer,
		Balances:             balanceWatcher,
		Vouchers:             voucherConfig,
		VoucherCache:         &relayserver.VoucherCatalogCache{},
		VoucherSettingsCache: &relayserver.VoucherSettingsCache{},
		Services:             servicesService,
		ServiceLogos:         relayserver.NewServiceLogos(),
		OpenRouterAPIKey:     strings.TrimSpace(*openRouterAPIKey),
		OpenRouterBaseURL:    strings.TrimSpace(*openRouterBaseURL),
		AIModelTiers: map[string]string{
			"fast":     strings.TrimSpace(*aiModelFast),
			"smart":    strings.TrimSpace(*aiModelSmart),
			"frontier": strings.TrimSpace(*aiModelFrontier),
		},
		AIDefaultTier:             strings.TrimSpace(*aiDefaultTier),
		AIRouterModel:             strings.TrimSpace(*aiRouterModel),
		AIVisionModel:             strings.TrimSpace(*aiVisionModel),
		AIAudioModel:              strings.TrimSpace(*aiAudioModel),
		AIExtractModel:            strings.TrimSpace(*aiExtractModel),
		AIWebSearchEnabled:        *aiWebSearchEnabled,
		AIWebSearchMaxResults:     *aiWebSearchMaxResults,
		AILimit5H:                 ratelimit.Policy{Limit: *aiLimit5H, Window: *aiLimit5HWindow},
		AILimitWeekly:             ratelimit.Policy{Limit: *aiLimitWeekly, Window: *aiLimitWeeklyWindow},
		AIMaxImagesPerPrompt:      *aiMaxImages,
		AIMaxRequestBytes:         *aiMaxRequestBytes,
		AIRequestTimeout:          *aiRequestTimeout,
		AIHTTPClient:              &http.Client{Timeout: aiClientTimeout, Transport: outboundTransport},
		ImageSearchHTTPClient:     &http.Client{Timeout: imageSearchClientTimeout, Transport: outboundTransport},
		AIChatRateLimit:           ratelimit.Policy{Limit: *aiChatRateLimit, Window: *rateLimitWindow},
		OpenSERPBaseURL:           strings.TrimSpace(*openSERPBaseURL),
		OpenSERPEngines:           strings.TrimSpace(*openSERPEngines),
		OpenSERPLanguage:          strings.TrimSpace(*openSERPLanguage),
		OpenSERPRegion:            strings.TrimSpace(*openSERPRegion),
		ImageSearchRequestTimeout: *imageSearchRequestTimeout,
	}
	if redisClient != nil {
		// Assigned only when set: a nil client in the interface would not
		// read as "no Redis".
		baseHTTPHandler.Redis = redisClient
	}
	publicHTTPHandler := baseHTTPHandler
	publicHTTPHandler.RouteMode = relayserver.RouteAll
	if adminHTTPListener != nil {
		publicHTTPHandler.RouteMode = relayserver.RoutePublic
	}
	var adminHTTPHandler http.Handler
	if adminHTTPListener != nil {
		adminOnly := baseHTTPHandler
		adminOnly.RouteMode = relayserver.RouteAdmin
		adminHTTPHandler = adminOnly
	}
	// The operator console lives wherever the admin routes are served.
	var publicHandler http.Handler = publicHTTPHandler
	if origin := strings.TrimSpace(*consoleOrigin); origin != "" {
		wrapped, err := buildConsole(consoleSettings{
			Origin:                        origin,
			RPID:                          *consoleRPID,
			AdminToken:                    *adminToken,
			Store:                         store,
			RateLimiter:                   rateLimiter,
			TrustForwardedFor:             *consoleTrustForwardedFor,
			RequireAdminClientCertificate: *requireAdminClientCert,
			Logger:                        logger,
		}, adminHTTPHandler, publicHandler)
		if err != nil {
			return err
		}
		if adminHTTPHandler != nil {
			adminHTTPHandler = wrapped
		} else {
			publicHandler = wrapped
		}
	}
	// cards.dftr.ly: the card app's web build, by host.
	publicHandler, err = buildCardsWeb(publicHandler, cardsweb.ParseHosts(*cardsWebHosts), *cardsWebDir, baseHTTPHandler, logger)
	if err != nil {
		return err
	}
	// app.dftr.ly: the shop app's web build, by host.
	publicHandler, err = buildAppWeb(publicHandler, webbuild.ParseHosts(*appWebHosts), *appWebDir, logger)
	if err != nil {
		return err
	}
	// Connectors can also reach any node over HTTPS (443) through the
	// balancer, with their mTLS inside a WebSocket; the TCP listener stays
	// for connectors that haven't updated.
	publicHandler = relayserver.WithConnectorTunnel(publicHandler, relayserver.ConnectorTunnel{
		Server:    connectorServer,
		TLSConfig: connectorTLSConfig,
		Context:   ctx,
	})
	publicHandler = relayserver.WithNodeWhoAmI(publicHandler, nodeAddress)
	httpServer := &http.Server{
		Handler:           publicHandler,
		ReadHeaderTimeout: 5 * time.Second,
	}
	var adminHTTPServer *http.Server
	if adminHTTPHandler != nil {
		adminHTTPServer = &http.Server{
			Handler:           adminHTTPHandler,
			ReadHeaderTimeout: 5 * time.Second,
		}
	}

	// The exchange-rate poller is the backstop behind the fulus webhook: a push
	// that never arrives (relay restart, transient 5xx, dropped retry) leaves a
	// gap nothing else would notice, and the fleet would keep pricing imports
	// off a stale rate. The store upserts on the publication's natural identity,
	// so a rate delivered both ways collapses to one row.
	if rateStore, ok := store.(control.ExchangeRateStore); ok {
		poller := &relayserver.FulusPoller{
			Client: relayserver.NewFulusClient(relayserver.FulusConfig{
				BaseURL: strings.TrimSpace(*fulusBaseURL),
				Token:   strings.TrimSpace(*fulusToken),
			}),
			Store:    rateStore,
			Interval: *fulusPollInterval,
			Logger:   logger,
		}
		if poller.Enabled() {
			go poller.Run(ctx)
		}
	}

	// Resala has no delivery webhook, so delivery is read back from its sent
	// log. Only worth doing with a token and a ledger to reconcile.
	if smsStore, ok := store.(control.SMSStore); ok && smsConfig.Token != "" && smsConfig.DeliverySyncInterval > 0 {
		poller := &relayserver.SMSDeliveryPoller{
			Client: resala.New(resala.Config{
				BaseURL:    smsConfig.BaseURL,
				Token:      smsConfig.Token,
				HTTPClient: smsConfig.HTTPClient,
				Timeout:    smsConfig.RequestTimeout,
			}),
			Store:    smsStore,
			Interval: smsConfig.DeliverySyncInterval,
			Logger:   logger,
			Metrics:  metrics,
		}
		go poller.Run(ctx)
	}
	if smsConfig.Token != "" {
		logger.Info(
			"relay sms configured",
			"templates", len(smsConfig.Templates),
			"test_mode", smsConfig.TestMode,
			"rate_limit", smsConfig.RateLimit.String(),
		)
	}

	if fleet != nil {
		go nodeAddress.Run(ctx)
		go fleet.Run(ctx)
		if *rebalance && presence != nil {
			go relayserver.Rebalancer{
				Hub:      hub,
				Fleet:    fleet,
				Presence: presence,
				Drain:    drain,
				NodeID:   nodeID,
				Logger:   logger,
				Metrics:  metrics,
			}.Run(ctx)
		}
	}

	errs := make(chan error, 3)
	go func() {
		logger.Info("relay connector listener started", "addr", connectorListener.Addr().String())
		errs <- connectorServer.Serve(ctx, connectorListener)
	}()
	go func() {
		logger.Info("relay public HTTP listener started", "addr", httpListener.Addr().String())
		if err := httpServer.Serve(httpListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- err
			return
		}
		errs <- nil
	}()
	if adminHTTPServer != nil {
		go func() {
			logger.Info("relay admin HTTP listener started", "addr", adminHTTPListener.Addr().String())
			if err := adminHTTPServer.Serve(adminHTTPListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
				errs <- err
				return
			}
			errs <- nil
		}()
	}

	// Periodically deactivate installations whose fixed-term subscription has
	// lapsed, so the fleet view (and the stored flag) reflects reality even
	// though access control already gates on the end date. Runs only when the
	// store supports audited subscription writes.
	if sweeper, ok := store.(control.AdminSubscriptionStore); ok && *subscriptionSweepInterval > 0 {
		go runSubscriptionExpirySweep(ctx, sweeper, logger, *subscriptionSweepInterval)
	}

	// Top-ups nobody finished stop reading as "pending" once their window has
	// passed; that moves no money. The sweep reads back from Dafa the payments
	// that can complete without the relay hearing of it (a bank card paid
	// after the owner closed the app) and credits the ones that went through.
	if walletStore, ok := store.(control.WalletStore); ok {
		expirer := &relayserver.WalletTopUpExpirer{
			Store:    walletStore,
			TTL:      walletConfig.TopUpTTL,
			Interval: time.Minute,
			Logger:   logger,
		}
		go expirer.Run(ctx)
		if walletConfig.TopUpsConfigured() {
			reconciler := &relayserver.WalletTopUpReconciler{
				Store:    walletStore,
				Config:   walletConfig,
				Interval: time.Minute,
				Logger:   logger,
			}
			go reconciler.Run(ctx)
		}
	}
	if walletConfig.TopUpsConfigured() {
		logger.Info(
			"relay wallet top-ups configured",
			"gateway", "dafa",
			"base_url", walletConfig.DafaBaseURL,
			"test_mode", walletConfig.TestMode,
			"methods", strings.Join(walletConfig.Methods, ","),
			"public_url", walletConfig.PublicURL,
			"min", walletConfig.MinTopUp,
			"max", walletConfig.MaxTopUp,
			"fee_percent", walletConfig.FeePercent,
		)
	}
	for _, plan := range []string{control.WalletPlanRemoteAccess, control.WalletPlanAI} {
		if sold, ok := walletConfig.Plans[plan]; ok {
			logger.Info("relay wallet sells a plan", "plan", plan, "price", sold.Price, "days", sold.Days)
		}
	}

	// The card shop: purchases whose outcome was left open are read back from
	// the supplier and settled, and what each supplier sells (price, stock) is
	// read on a schedule so the catalog never offers a card it cannot buy.
	if voucherStore, ok := store.(control.VoucherStore); ok && voucherConfig.Configured() {
		reconciler := &relayserver.VoucherReconciler{
			Server:   baseHTTPHandler,
			Store:    voucherStore,
			Interval: time.Minute,
			Logger:   logger,
		}
		go reconciler.Run(ctx)
		if _, ok := store.(control.CustomerOrderStore); ok {
			// «دفتر كروت» orders: unpaid ones expire, late payments become
			// credit, paid ones reach their card. Not tied to the sign-in SMS
			// settings: orders already paid must finish whatever they say.
			customerOrders := &relayserver.CustomerOrderReconciler{
				Server:   baseHTTPHandler,
				Interval: 30 * time.Second,
				Logger:   logger,
			}
			go customerOrders.Run(ctx)
		}
		if len(voucherConfig.Suppliers) > 0 && voucherConfig.SyncInterval > 0 {
			offerSync := &relayserver.VoucherOfferSync{
				Config:   voucherConfig,
				Store:    voucherStore,
				Interval: voucherConfig.SyncInterval,
				Logger:   logger,
			}
			go offerSync.Run(ctx)
		}
		suppliers := make([]string, 0, len(voucherConfig.Suppliers))
		for key := range voucherConfig.Suppliers {
			suppliers = append(suppliers, key)
		}
		logger.Info(
			"relay vouchers configured",
			"suppliers", strings.Join(suppliers, ","),
			"test_mode", voucherConfig.TestMode,
			"rate_limit", voucherConfig.RateLimit.String(),
			"sync_interval", voucherConfig.SyncInterval.String(),
			"reloadly", reloadlyStartupMode(voucherConfig.Reloadly),
		)
	}

	// Direct top-up and bill payments: the directory is read now and kept fresh;
	// their held orders are settled by the voucher reconciler above, which reads
	// every kind of purchase.
	if servicesService.Configured() {
		go servicesService.Run(ctx)
		go servicesService.RunFunds(ctx)
		logger.Info(
			"relay services configured",
			"mode", servicesStartupMode(voucherConfig),
			"directory_interval", servicesDirectoryInterval.String(),
			"settle_wait", servicesSettleWait.String(),
		)
	}

	select {
	case <-signalCtx.Done():
		// A second signal ends the process at once.
		stop()
		// Tunnels move to other nodes while this one still serves, so the
		// requests that arrive meanwhile are answered; then the listeners
		// stop, what is left closes, and the node leaves the registry.
		relayserver.Drainer{
			Hub:     hub,
			Drain:   drain,
			Fleet:   fleet,
			Timeout: *drainTimeout,
			Logger:  logger,
			Metrics: metrics,
		}.Run(context.Background())
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = connectorListener.Close()
		_ = httpServer.Shutdown(shutdownCtx)
		if adminHTTPServer != nil {
			_ = adminHTTPServer.Shutdown(shutdownCtx)
		}
		hub.CloseAll()
		cancelRun()
		// At once, rather than when the record expires: the other nodes
		// drop this one's presence records as soon as they see it gone.
		fleet.Leave()
		return nil
	case err := <-errs:
		if err != nil {
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = httpServer.Shutdown(shutdownCtx)
			if adminHTTPServer != nil {
				_ = adminHTTPServer.Shutdown(shutdownCtx)
			}
			_ = connectorListener.Close()
			return err
		}
		return nil
	}
}

// runSubscriptionExpirySweep deactivates lapsed fixed-term subscriptions on a
// timer until ctx is cancelled. It sweeps once at startup so a restart promptly
// reconciles anything that expired while the relay was down, then on the
// interval. Failures are logged and retried on the next tick — a transient DB
// blip never tears the server down.
func runSubscriptionExpirySweep(
	ctx context.Context,
	store control.AdminSubscriptionStore,
	logger *slog.Logger,
	interval time.Duration,
) {
	sweep := func() {
		events, err := store.ExpireDueSubscriptions(ctx, time.Now().UTC())
		if err != nil {
			logger.Warn("subscription expiry sweep failed", "error", err)
			return
		}
		if len(events) > 0 {
			logger.Info("expired lapsed subscriptions", "count", len(events))
		}
	}
	sweep()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			sweep()
		}
	}
}

type serverSecurityConfig struct {
	Production             bool
	Platform               string
	AdminHTTPAddr          string
	AdminToken             string
	AllowOpenAdmin         bool
	AllowInsecureHTTP      bool
	HTTPTLSCert            string
	HTTPTLSKey             string
	HTTPTLSServerName      string
	HTTPAddr               string
	HTTPClientCA           string
	RequireAdminClientCert bool
	AllowInsecureConnector bool
	ConnectorTLSCert       string
	ConnectorTLSKey        string
	ConnectorTLSServerName string
	ConnectorAddr          string
	ConnectorClientCA      string
	ConnectorClientCAKey   string
	AutoTLS                bool
	NodeInternalURL        string
	NodeProxyToken         string
	AllowInsecureNodeProxy bool
}

func validateServerSecurityConfig(config serverSecurityConfig) error {
	if certificatePairPartial(config.HTTPTLSCert, config.HTTPTLSKey) {
		return fmt.Errorf("HTTP TLS certificate and key must be provided together")
	}
	if certificatePairPartial(config.ConnectorTLSCert, config.ConnectorTLSKey) {
		return fmt.Errorf("connector TLS certificate and key must be provided together")
	}
	if (strings.TrimSpace(config.ConnectorClientCA) == "") !=
		(strings.TrimSpace(config.ConnectorClientCAKey) == "") {
		return fmt.Errorf("connector client CA certificate and key must be provided together or omitted for automatic generation")
	}
	if strings.ToLower(strings.TrimSpace(config.Platform)) == "paas" {
		return validatePaaSServerSecurityConfig(config)
	}
	if !config.Production {
		return nil
	}

	var problems []string
	if strings.TrimSpace(config.AdminHTTPAddr) == "" {
		problems = append(problems, "admin HTTP listener must be separate from the public listener")
	}
	if config.AllowOpenAdmin {
		problems = append(problems, "open admin endpoints are not allowed")
	}
	if strings.TrimSpace(config.AdminToken) == "" {
		problems = append(problems, "admin token is required")
	}
	if config.AllowInsecureHTTP {
		problems = append(problems, "cleartext HTTP listener is not allowed")
	}
	if !config.AutoTLS &&
		(strings.TrimSpace(config.HTTPTLSCert) == "" || strings.TrimSpace(config.HTTPTLSKey) == "") {
		problems = append(problems, "HTTP TLS certificate and key are required")
	}
	if config.AutoTLS &&
		strings.TrimSpace(config.HTTPTLSCert) == "" &&
		!hasUsableCertificateHost(config.HTTPTLSServerName, config.HTTPAddr) {
		problems = append(problems, "HTTP TLS server name is required for automatic certificate generation on a wildcard listener")
	}
	if !config.RequireAdminClientCert {
		problems = append(problems, "admin client certificates must be required")
	}
	if strings.TrimSpace(config.HTTPClientCA) == "" {
		problems = append(problems, "admin HTTP client CA is required")
	}
	if config.AllowInsecureConnector {
		problems = append(problems, "cleartext connector listener is not allowed")
	}
	if !config.AutoTLS && (strings.TrimSpace(config.ConnectorTLSCert) == "" ||
		strings.TrimSpace(config.ConnectorTLSKey) == "" ||
		strings.TrimSpace(config.ConnectorClientCA) == "") {
		problems = append(problems, "connector mTLS certificate, key, and client CA are required")
	}
	if !config.AutoTLS && strings.TrimSpace(config.ConnectorClientCAKey) == "" {
		problems = append(problems, "connector client CA key is required for automatic certificate issuance")
	}
	if config.AutoTLS &&
		strings.TrimSpace(config.ConnectorTLSCert) == "" &&
		!hasUsableCertificateHost(config.ConnectorTLSServerName, config.ConnectorAddr) {
		problems = append(problems, "connector TLS server name is required for automatic certificate generation on a wildcard listener")
	}
	if config.AllowInsecureNodeProxy {
		problems = append(problems, "insecure node proxy routing is not allowed")
	}
	if strings.TrimSpace(config.NodeInternalURL) != "" && strings.TrimSpace(config.NodeProxyToken) == "" {
		problems = append(problems, "node proxy token is required when node internal URL is configured")
	}
	if len(problems) > 0 {
		return fmt.Errorf("production relay configuration is unsafe: %s", strings.Join(problems, "; "))
	}
	return nil
}

// minAdminTokenLength is the shortest admin bearer token the paas profile will
// accept. The token is the sole gate on the admin/subscription API on an
// internet-facing endpoint, so it must be long enough to resist guessing.
// `pointy-relay gen-token` prints a 64-character value.
const minAdminTokenLength = 24

// wellKnownWeakAdminTokens are development placeholders that must never reach an
// internet-facing deployment, regardless of length.
var wellKnownWeakAdminTokens = map[string]bool{
	"local-admin": true,
	"admin":       true,
	"changeme":    true,
	"password":    true,
	"secret":      true,
	"token":       true,
}

func validateStrongAdminToken(token string) error {
	trimmed := strings.TrimSpace(token)
	if trimmed == "" {
		return errors.New("admin token is required (generate one with `pointy-relay gen-token`)")
	}
	if wellKnownWeakAdminTokens[strings.ToLower(trimmed)] {
		return errors.New("admin token is a well-known development value (generate one with `pointy-relay gen-token`)")
	}
	if len([]rune(trimmed)) < minAdminTokenLength {
		return fmt.Errorf(
			"admin token must be at least %d characters (generate one with `pointy-relay gen-token`)",
			minAdminTokenLength,
		)
	}
	return nil
}

// validatePaaSServerSecurityConfig enforces the safety floor for the paas
// profile: a single public endpoint, TLS terminated at the load balancer, and a
// strong bearer token as the only admin gate. The connector keeps its
// end-to-end mTLS untouched.
func validatePaaSServerSecurityConfig(config serverSecurityConfig) error {
	var problems []string
	if config.AllowOpenAdmin {
		problems = append(problems, "open admin endpoints are not allowed")
	}
	if err := validateStrongAdminToken(config.AdminToken); err != nil {
		problems = append(problems, err.Error())
	}
	if strings.TrimSpace(config.AdminHTTPAddr) != "" {
		problems = append(problems, "the paas profile serves admin on the single public endpoint; unset the separate admin listener (POINTY_RELAY_ADMIN_HTTP_ADDR)")
	}
	if config.RequireAdminClientCert {
		problems = append(problems, "the paas profile authenticates admin with the bearer token; do not require admin client certificates (POINTY_RELAY_REQUIRE_ADMIN_CLIENT_CERT)")
	}
	if config.AllowInsecureConnector {
		problems = append(problems, "cleartext connector listener is not allowed; the connector keeps end-to-end mTLS through the load balancer's TCP passthrough")
	}
	// When the connector relies on auto-generated TLS on a wildcard bind, its
	// server certificate needs an explicit hostname or connectors dialing the
	// public name can't verify it (the fallback SANs are localhost/127.0.0.1).
	if config.AutoTLS &&
		strings.TrimSpace(config.ConnectorTLSCert) == "" &&
		!hasUsableCertificateHost(config.ConnectorTLSServerName, config.ConnectorAddr) {
		problems = append(problems, "connector TLS server name is required (POINTY_RELAY_CONNECTOR_TLS_SERVER_NAME) so on-prem connectors can verify the relay on a wildcard bind")
	}
	// Only relevant if the operator opts the relay back into terminating HTTPS
	// itself (allow-insecure-http=false) instead of the default edge termination.
	if !config.AllowInsecureHTTP &&
		config.AutoTLS &&
		strings.TrimSpace(config.HTTPTLSCert) == "" &&
		!hasUsableCertificateHost(config.HTTPTLSServerName, config.HTTPAddr) {
		problems = append(problems, "HTTP TLS server name is required (POINTY_RELAY_HTTP_TLS_SERVER_NAME) when the relay terminates HTTPS itself on a wildcard bind")
	}
	if strings.TrimSpace(config.NodeInternalURL) != "" && strings.TrimSpace(config.NodeProxyToken) == "" {
		problems = append(problems, "node proxy token is required when node internal URL is configured")
	}
	if len(problems) > 0 {
		return fmt.Errorf("paas relay configuration is unsafe: %s", strings.Join(problems, "; "))
	}
	return nil
}

// operatorProvided reports whether the operator explicitly set a server flag,
// via either its command-line flag or its backing environment variable. It lets
// the paas profile supply defaults without clobbering deliberate overrides.
func operatorProvided(flags *flag.FlagSet, flagName, envName string) bool {
	provided := false
	flags.Visit(func(f *flag.Flag) {
		if f.Name == flagName {
			provided = true
		}
	})
	if provided {
		return true
	}
	_, ok := os.LookupEnv(envName)
	return ok
}

// defaultPaaSHTTPAddr binds all interfaces so the platform load balancer can
// reach the container, honoring an injected $PORT when the platform provides
// one (Heroku/Render/Railway style) and falling back to the conventional port.
func defaultPaaSHTTPAddr() string {
	if port := strings.TrimSpace(os.Getenv("PORT")); port != "" {
		return net.JoinHostPort("0.0.0.0", port)
	}
	return "0.0.0.0:8091"
}

// nodeProxyTokenDerivationLabel namespaces the HMAC so the node-proxy secret is
// a distinct value from the admin token, not the admin token itself. Bumping the
// suffix rotates every node's derived secret in lockstep on the next restart.
const nodeProxyTokenDerivationLabel = "pointy-relay-node-proxy/v1"

// deriveNodeProxyToken produces the shared node-to-node bearer secret from the
// admin token. Every autoscaled instance holds the same admin token, so they all
// derive the same proxy token without it ever being distributed or stored, and
// it inherits the admin token's (paas-enforced) strength.
func deriveNodeProxyToken(adminToken string) string {
	mac := hmac.New(sha256.New, []byte(strings.TrimSpace(adminToken)))
	mac.Write([]byte(nodeProxyTokenDerivationLabel))
	return hex.EncodeToString(mac.Sum(nil))
}

// nodeURLFor builds the address peers use to reach this instance's node-relay
// routes, reusing the public HTTP listener's port on the detected LAN IP. The
// scheme is http because the paas profile terminates public TLS upstream and
// speaks cleartext on the trusted internal network.
func nodeURLFor(ip string, httpAddr string) (string, bool) {
	ip = strings.TrimSpace(ip)
	if ip == "" {
		return "", false
	}
	_, port, err := net.SplitHostPort(strings.TrimSpace(httpAddr))
	if err != nil || strings.TrimSpace(port) == "" {
		return "", false
	}
	return "http://" + net.JoinHostPort(ip, port), true
}

// primaryPrivateIPv4 returns this container's first routable private IPv4
// address (RFC 1918), which is what sibling instances on the platform's internal
// network use to reach it. It deliberately returns only private addresses —
// never loopback, link-local, or public — so the auto-mesh never advertises a
// public IP that would carry token-bearing node-to-node traffic over the open
// internet. It returns false when no private address exists so the caller falls
// back to single-node behavior instead of advertising something unsafe.
func primaryPrivateIPv4() (string, bool) {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "", false
	}
	for _, addr := range addrs {
		var ip net.IP
		switch v := addr.(type) {
		case *net.IPNet:
			ip = v.IP
		case *net.IPAddr:
			ip = v.IP
		}
		ip4 := ip.To4()
		if ip4 == nil || !ip4.IsGlobalUnicast() {
			continue
		}
		if ip4.IsPrivate() {
			return ip4.String(), true
		}
	}
	return "", false
}

func runGenToken(args []string) error {
	flags := flag.NewFlagSet("gen-token", flag.ExitOnError)
	size := flags.Int("bytes", 32, "number of random bytes encoded into the token")
	if err := flags.Parse(args); err != nil {
		return err
	}
	token, err := generateAdminToken(*size)
	if err != nil {
		return err
	}
	fmt.Println(token)
	return nil
}

func generateAdminToken(size int) (string, error) {
	if size < 16 {
		return "", usageError("gen-token requires at least 16 bytes")
	}
	buf := make([]byte, size)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate admin token: %w", err)
	}
	return hex.EncodeToString(buf), nil
}

func runConnector(args []string) error {
	flags := flag.NewFlagSet("connector", flag.ExitOnError)
	relayAddr := flags.String(
		"relay",
		envString("POINTY_RELAY_CONNECTOR_ADDR", ""),
		"relay connector TCP address, tried after --urls",
	)
	tunnelURLs := flags.String(
		"urls",
		envString("POINTY_RELAY_CONNECTOR_URLS", ""),
		"tunnel addresses to try before --relay, best first (wss://host/v1/connector/tunnel, tls://host:port); empty uses the hosted relay's tunnel over HTTPS when --relay is the hosted relay",
	)
	token := flags.String(
		"token",
		envString("POINTY_RELAY_CONNECTOR_TOKEN", ""),
		"connector token generated for this on-prem installation",
	)
	backendRaw := flags.String(
		"backend",
		envString("POINTY_RELAY_BACKEND_URL", ""),
		"local Pointy backend origin; discovered automatically when omitted",
	)
	backendConfigURL := flags.String(
		"backend-config-url",
		envString("POINTY_RELAY_CONNECTOR_CONFIG_URL", ""),
		"optional backend connector bootstrap endpoint",
	)
	backendConfigToken := flags.String(
		"backend-config-token",
		envString("POINTY_RELAY_CONNECTOR_SETUP_TOKEN", ""),
		"setup token for backend connector bootstrap",
	)
	stateFile := flags.String(
		"state-file",
		envString("POINTY_RELAY_CONNECTOR_STATE_FILE", defaultConnectorStatePath()),
		"connector state file for bootstrap token and certificate material",
	)
	tlsCA := flags.String(
		"tls-ca",
		envString("POINTY_RELAY_TLS_CA", ""),
		"CA bundle for relay connector TLS",
	)
	tlsCert := flags.String(
		"tls-cert",
		envString("POINTY_RELAY_TLS_CERT", ""),
		"client certificate for relay connector mTLS",
	)
	tlsKey := flags.String(
		"tls-key",
		envString("POINTY_RELAY_TLS_KEY", ""),
		"client key for relay connector mTLS",
	)
	tlsServerName := flags.String(
		"tls-server-name",
		envString("POINTY_RELAY_TLS_SERVER_NAME", ""),
		"expected relay connector TLS server name",
	)
	allowInsecureRelay := flags.Bool(
		"allow-insecure-relay",
		envBool("POINTY_RELAY_ALLOW_INSECURE_CONNECTOR", false),
		"allow cleartext connector traffic for local development",
	)
	connectorRequestTimeout := flags.Duration(
		"request-timeout",
		envDuration("POINTY_RELAY_CONNECTOR_REQUEST_TIMEOUT", 30*time.Second),
		"timeout for each connector request to the local backend",
	)
	connectorMaxConcurrentRequests := flags.Int(
		"max-concurrent-requests",
		envInt("POINTY_RELAY_CONNECTOR_MAX_CONCURRENT_REQUESTS", 64),
		"maximum concurrent backend requests forwarded by this connector; set 0 to disable",
	)
	connectorCertRotationWindow := flags.Duration(
		"client-cert-rotation-window",
		envDuration("POINTY_RELAY_CONNECTOR_CLIENT_CERT_ROTATION_WINDOW", defaultConnectorCertRotationWindow),
		"renew managed connector client certificates inside this window before expiry",
	)
	if err := flags.Parse(args); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	backendURL, err := resolveConnectorBackend(ctx, *backendRaw)
	if err != nil {
		return err
	}
	state, err := loadConnectorState(*stateFile)
	if err != nil {
		return connectorStateError(*stateFile, err)
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	relayAddress := strings.TrimSpace(*relayAddr)
	connectorToken := strings.TrimSpace(*token)
	if connectorToken == "" {
		connectorToken = strings.TrimSpace(state.ConnectorToken)
	}
	if relayAddress == "" {
		relayAddress = strings.TrimSpace(state.RelayConnectorAddress)
	}
	tlsServerNameValue := strings.TrimSpace(*tlsServerName)
	if tlsServerNameValue == "" {
		tlsServerNameValue = strings.TrimSpace(state.TLSServerName)
	}
	managedTLS := !*allowInsecureRelay && strings.TrimSpace(*tlsCert) == ""
	needsBootstrap := connectorToken == "" ||
		(managedTLS && strings.TrimSpace(state.ConnectorCertificatePEM) == "")
	needsCertificateRenewal := !needsBootstrap &&
		managedTLS &&
		(state.ConnectorCertificateExpiresAt == nil ||
			control.ConnectorCertificateRotationDue(
				state.ConnectorCertificateExpiresAt,
				time.Now().UTC(),
				*connectorCertRotationWindow,
			))
	if needsBootstrap || needsCertificateRenewal {
		csrPEM := ""
		privateKeyPEM := ""
		if managedTLS {
			request, err := security.GenerateClientCertificateRequest("pointy-connector")
			if err != nil {
				return err
			}
			csrPEM = request.CSRPem
			privateKeyPEM = request.PrivateKeyPEM
		}
		bootstrap, err := fetchBackendConnectorConfig(
			ctx,
			backendURL,
			*backendConfigURL,
			*backendConfigToken,
			connectorToken,
			csrPEM,
		)
		if err != nil {
			if !needsCertificateRenewal || !connectorStateHasManagedTLS(state) {
				return err
			}
			logger.Warn("connector certificate renewal failed; using existing certificate", "error", err)
		} else {
			connectorToken = bootstrap.ConnectorToken
			if strings.TrimSpace(bootstrap.RelayConnectorAddress) != "" {
				relayAddress = strings.TrimSpace(bootstrap.RelayConnectorAddress)
			}
			if strings.TrimSpace(bootstrap.TLSServerName) != "" {
				tlsServerNameValue = strings.TrimSpace(bootstrap.TLSServerName)
			}
			state = connectorState{
				RelayEndpoints:                state.RelayEndpoints,
				LastGoodEndpoint:              state.LastGoodEndpoint,
				InstallationID:                bootstrap.InstallationID,
				ShopName:                      bootstrap.ShopName,
				BackendURL:                    backendURL.String(),
				RelayConnectorAddress:         relayAddress,
				ConnectorToken:                connectorToken,
				TLSServerName:                 tlsServerNameValue,
				ConnectorCertificatePEM:       bootstrap.ConnectorCertificatePEM,
				ConnectorPrivateKeyPEM:        privateKeyPEM,
				ConnectorCACertificatePEM:     bootstrap.ConnectorCACertificatePEM,
				ConnectorCertificateExpiresAt: bootstrap.ConnectorCertificateExpiresAt,
			}
			if err := saveConnectorState(*stateFile, state); err != nil {
				return connectorStateError(*stateFile, err)
			}
		}
	}
	if connectorToken == "" {
		return fmt.Errorf("connector token is required")
	}
	endpoints, err := connector.ParseEndpoints(*tunnelURLs)
	if err != nil {
		return fmt.Errorf("POINTY_RELAY_CONNECTOR_URLS: %w", err)
	}
	if strings.TrimSpace(*tunnelURLs) == "" {
		endpoints = connector.DefaultEndpoints(relayAddress)
	}
	if relayAddress == "" && len(endpoints) == 0 {
		return fmt.Errorf("relay connector address is required")
	}

	var tlsConfig *tls.Config
	if !*allowInsecureRelay {
		if tlsServerNameValue == "" && relayAddress != "" {
			tlsServerNameValue = relayTLSServerName(relayAddress)
		}
		if tlsServerNameValue == "" {
			tlsServerNameValue = endpoints[0].Host
		}
		if (strings.TrimSpace(*tlsCA) == "" &&
			strings.TrimSpace(state.ConnectorCACertificatePEM) == "") ||
			(strings.TrimSpace(*tlsCert) == "" &&
				strings.TrimSpace(state.ConnectorCertificatePEM) == "") ||
			(strings.TrimSpace(*tlsKey) == "" &&
				strings.TrimSpace(state.ConnectorPrivateKeyPEM) == "") {
			return fmt.Errorf("connector TLS CA, client certificate, and client key are required unless --allow-insecure-relay is set")
		}
		tlsConfig, err = security.ClientTLSConfig(security.ClientTLSOptions{
			CAFile:     *tlsCA,
			CAPEM:      state.ConnectorCACertificatePEM,
			CertFile:   *tlsCert,
			CertPEM:    state.ConnectorCertificatePEM,
			KeyFile:    *tlsKey,
			KeyPEM:     state.ConnectorPrivateKeyPEM,
			ServerName: tlsServerNameValue,
		})
		if err != nil {
			return err
		}
	}
	startBackendConnectorHeartbeat(ctx, backendURL, connectorToken, logger)
	return connector.Client{
		Endpoints:           endpoints,
		RelayAddress:        relayAddress,
		AdvertisedEndpoints: state.RelayEndpoints,
		LastGoodEndpoint:    state.LastGoodEndpoint,
		OnConnected: func(connected connector.Connected) {
			// Saved so the next start dials what the relay advertised, and
			// what last worked, before anything this install was configured
			// with: that is how shops follow the relay to a new address.
			if connected.Endpoint == state.LastGoodEndpoint &&
				slices.Equal(connected.Advertised, state.RelayEndpoints) {
				return
			}
			state.LastGoodEndpoint = connected.Endpoint
			state.RelayEndpoints = connected.Advertised
			if err := saveConnectorState(*stateFile, state); err != nil {
				logger.Warn("connector could not save the relay's tunnel addresses", "error", err)
			}
		},
		Token:                 connectorToken,
		BackendURL:            backendURL,
		Logger:                logger,
		RequestTimeout:        *connectorRequestTimeout,
		MaxConcurrentRequests: *connectorMaxConcurrentRequests,
		UseTLS:                !*allowInsecureRelay,
		TLSConfig:             tlsConfig,
	}.Run(ctx)
}

func runProvision(args []string) error {
	flags := flag.NewFlagSet("provision", flag.ExitOnError)
	databaseURL := flags.String(
		"database-url",
		envString("POINTY_RELAY_DATABASE_URL", defaultRelayDatabaseURL),
		"PostgreSQL database URL for relay installations",
	)
	businessID := flags.String("business-id", "", "business identifier to attach to the installation")
	shopName := flags.String("shop-name", "", "shop name to attach to the installation")
	relayEnabled := flags.Bool("relay-enabled", false, "enable remote relay access")
	subscriptionActive := flags.Bool("subscription-active", false, "mark the relay subscription active")
	aiEnabled := flags.Bool("ai-enabled", false, "enable AI entitlement for this installation")
	subscriptionEndsAt := flags.String(
		"subscription-ends-at",
		"",
		"optional RFC3339 subscription end time",
	)
	if err := flags.Parse(args); err != nil {
		return err
	}
	var endsAt *time.Time
	if strings.TrimSpace(*subscriptionEndsAt) != "" {
		parsed, err := time.Parse(time.RFC3339, *subscriptionEndsAt)
		if err != nil {
			return fmt.Errorf("subscription-ends-at must be RFC3339: %w", err)
		}
		parsed = parsed.UTC()
		endsAt = &parsed
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	store, err := control.NewPostgresStore(ctx, *databaseURL, control.RealClock{})
	if err != nil {
		return err
	}
	defer store.Close()
	provisioned, err := store.ProvisionInstallation(ctx, control.ProvisionInstallationRequest{
		BusinessID:         *businessID,
		ShopName:           *shopName,
		RelayEnabled:       relayEnabled,
		SubscriptionActive: subscriptionActive,
		AIEnabled:          *aiEnabled,
		SubscriptionEndsAt: endsAt,
	})
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(provisionedInstallationOutput(provisioned))
}

func runSubscription(args []string) error {
	if len(args) == 0 {
		return usageError("missing subscription command (set, update, enable, disable, extend, audit)")
	}
	switch args[0] {
	case "set":
		return runSubscriptionSet(args[1:])
	case "update":
		return runSubscriptionUpdate(args[1:])
	case "enable":
		return runSubscriptionToggle(args[1:], true)
	case "disable":
		return runSubscriptionToggle(args[1:], false)
	case "extend":
		return runSubscriptionExtend(args[1:])
	case "audit":
		return runInstallationsAudit(args[1:])
	default:
		return usageError("unknown subscription command %q", args[0])
	}
}

func runSubscriptionUpdate(args []string) error {
	flags := flag.NewFlagSet("subscription update", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	actor := flags.String("actor", "", "operator id for the audit trail (default: $POINTY_RELAY_OPERATOR or OS user)")
	reason := flags.String("reason", "", "audit reason for the subscription change")
	relayEnabled := flags.String("relay-enabled", "", "optional true/false relay entitlement")
	subscriptionActive := flags.String("subscription-active", "", "optional true/false subscription state")
	aiEnabled := flags.String("ai-enabled", "", "optional true/false AI entitlement")
	subscriptionEndsAt := flags.String("subscription-ends-at", "", "optional RFC3339 subscription end time")
	clearEnd := flags.Bool("clear-subscription-end", false, "clear subscription end time")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	installationIDFlag := flags.String("installation-id", "", "installation id (or pass it as the first argument)")
	id, err := idAndFlagsOptional(args, flags, installationIDFlag)
	if err != nil {
		return err
	}
	body, err := subscriptionUpdateBody(subscriptionUpdateOptions{
		InstallationID:       id,
		Actor:                resolveActor(*actor),
		Reason:               *reason,
		RelayEnabled:         *relayEnabled,
		SubscriptionActive:   *subscriptionActive,
		AIEnabled:            *aiEnabled,
		SubscriptionEndsAt:   *subscriptionEndsAt,
		ClearSubscriptionEnd: *clearEnd,
	})
	if err != nil {
		return err
	}
	return applySubscriptionChange(admin, id, body, *asJSON)
}

func runSubscriptionToggle(args []string, enable bool) error {
	verb := "enable"
	if !enable {
		verb = "disable"
	}
	flags := flag.NewFlagSet("subscription "+verb, flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	actor := flags.String("actor", "", "operator id for the audit trail (default: $POINTY_RELAY_OPERATOR or OS user)")
	reason := flags.String("reason", "", "audit reason (defaults to the action)")
	withAI := flags.Bool("ai", false, "also toggle the AI entitlement")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	state := strconv.FormatBool(enable)
	options := subscriptionUpdateOptions{
		InstallationID:     id,
		Actor:              resolveActor(*actor),
		Reason:             defaultReason(*reason, verb+"d relay subscription via operator CLI"),
		RelayEnabled:       state,
		SubscriptionActive: state,
	}
	if *withAI {
		options.AIEnabled = state
	}
	body, err := subscriptionUpdateBody(options)
	if err != nil {
		return err
	}
	return applySubscriptionChange(admin, id, body, *asJSON)
}

// runSubscriptionSet is the human one-liner: give an installation a subscription
// of N months (or days, or until a date) and, in the same audited change, turn
// the AI add-on and remote access on or off.
func runSubscriptionSet(args []string) error {
	flags := flag.NewFlagSet("subscription set", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	actor := flags.String("actor", "", "operator id for the audit trail (default: $POINTY_RELAY_OPERATOR or OS user)")
	reason := flags.String("reason", "", "audit reason (defaults to a summary of the change)")
	months := flags.Int("months", 0, "subscription length in months from now (e.g. 1, 3, 65)")
	days := flags.Int("days", 0, "subscription length in days from now (alternative to --months)")
	until := flags.String("until", "", "explicit RFC3339 subscription end (alternative to --months/--days)")
	aiOn := flags.Bool("ai", false, "enable the AI add-on")
	aiOff := flags.Bool("no-ai", false, "disable the AI add-on")
	remoteOn := flags.Bool("remote", false, "enable remote access (implied when a length is set)")
	remoteOff := flags.Bool("no-remote", false, "disable remote access")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	if *aiOn && *aiOff {
		return usageError("--ai and --no-ai are mutually exclusive")
	}
	if *remoteOn && *remoteOff {
		return usageError("--remote and --no-remote are mutually exclusive")
	}

	endsAt, err := subscriptionEndFromFlags(*months, *days, *until)
	if err != nil {
		return err
	}

	options := subscriptionUpdateOptions{
		InstallationID: id,
		Actor:          resolveActor(*actor),
	}
	if endsAt != "" {
		options.SubscriptionActive = "true"
		options.SubscriptionEndsAt = endsAt
	}
	switch {
	case *remoteOn:
		options.RelayEnabled = "true"
	case *remoteOff:
		options.RelayEnabled = "false"
	case endsAt != "":
		// A subscription length is only useful with remote access on.
		options.RelayEnabled = "true"
	}
	switch {
	case *aiOn:
		options.AIEnabled = "true"
	case *aiOff:
		options.AIEnabled = "false"
	}
	if endsAt == "" && options.RelayEnabled == "" && options.AIEnabled == "" {
		return usageError("nothing to set: pass a length (--months/--days/--until) and/or --ai/--no-ai/--remote/--no-remote")
	}
	options.Reason = defaultReason(*reason, subscriptionSetReason(*months, *days, *until, options))

	body, err := subscriptionUpdateBody(options)
	if err != nil {
		return err
	}
	return applySubscriptionChange(admin, id, body, *asJSON)
}

// subscriptionEndFromFlags turns the chosen length flag into an RFC3339 end time.
// At most one of months/days/until may be set; none returns "" (leave unchanged).
func subscriptionEndFromFlags(months, days int, until string) (string, error) {
	if months < 0 || days < 0 {
		return "", usageError("--months and --days must be 0 or positive")
	}
	count := 0
	endsAt := ""
	if months > 0 {
		count++
		endsAt = time.Now().UTC().AddDate(0, months, 0).Format(time.RFC3339)
	}
	if days > 0 {
		count++
		endsAt = time.Now().UTC().AddDate(0, 0, days).Format(time.RFC3339)
	}
	if trimmed := strings.TrimSpace(until); trimmed != "" {
		count++
		parsed, err := time.Parse(time.RFC3339, trimmed)
		if err != nil {
			return "", fmt.Errorf("--until must be RFC3339: %w", err)
		}
		endsAt = parsed.UTC().Format(time.RFC3339)
	}
	if count > 1 {
		return "", usageError("use only one of --months, --days, or --until")
	}
	return endsAt, nil
}

// subscriptionSetReason builds a readable default audit reason from the change.
func subscriptionSetReason(months, days int, until string, options subscriptionUpdateOptions) string {
	var parts []string
	switch {
	case months > 0:
		parts = append(parts, fmt.Sprintf("%d-month subscription", months))
	case days > 0:
		parts = append(parts, fmt.Sprintf("%d-day subscription", days))
	case strings.TrimSpace(until) != "":
		parts = append(parts, "subscription end "+strings.TrimSpace(until))
	}
	switch options.AIEnabled {
	case "true":
		parts = append(parts, "AI on")
	case "false":
		parts = append(parts, "AI off")
	}
	if options.RelayEnabled == "false" {
		parts = append(parts, "remote off")
	} else if options.RelayEnabled == "true" && len(parts) == 0 {
		parts = append(parts, "remote on")
	}
	summary := strings.Join(parts, ", ")
	if summary == "" {
		summary = "subscription update"
	}
	return "set " + summary + " via operator CLI"
}

func runSubscriptionExtend(args []string) error {
	flags := flag.NewFlagSet("subscription extend", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	actor := flags.String("actor", "", "operator id for the audit trail (default: $POINTY_RELAY_OPERATOR or OS user)")
	reason := flags.String("reason", "", "audit reason (defaults to the action)")
	days := flags.Int("days", 0, "number of days from now to set the subscription end")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	if *days <= 0 {
		return usageError("--days must be a positive number")
	}
	endsAt := time.Now().UTC().Add(time.Duration(*days) * 24 * time.Hour)
	body, err := subscriptionUpdateBody(subscriptionUpdateOptions{
		InstallationID:     id,
		Actor:              resolveActor(*actor),
		Reason:             defaultReason(*reason, fmt.Sprintf("extended subscription %d day(s) via operator CLI", *days)),
		SubscriptionActive: "true",
		SubscriptionEndsAt: endsAt.Format(time.RFC3339),
	})
	if err != nil {
		return err
	}
	return applySubscriptionChange(admin, id, body, *asJSON)
}

func applySubscriptionChange(admin *adminControlFlags, id string, body map[string]any, asJSON bool) error {
	raw, err := admin.requestJSON(http.MethodPatch, "/v1/installations/"+url.PathEscape(id)+"/subscription", nil, body)
	if err != nil {
		return err
	}
	if asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Installation installationView `json:"installation"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	fmt.Printf("Updated %s.\n\n", id)
	return renderInstallationDetail(response.Installation)
}

func runInstallations(args []string) error {
	if len(args) == 0 {
		return usageError("missing installations command (list, show, status, diagnostics, audit, provision)")
	}
	switch args[0] {
	case "list":
		return runInstallationsList(args[1:])
	case "show":
		return runInstallationsShow(args[1:])
	case "status":
		return runInstallationsStatus(args[1:])
	case "diagnostics":
		return runInstallationsDiagnostics(args[1:])
	case "audit":
		return runInstallationsAudit(args[1:])
	case "provision":
		return runInstallationsProvision(args[1:])
	default:
		return usageError("unknown installations command %q", args[0])
	}
}

func runInstallationsList(args []string) error {
	flags := flag.NewFlagSet("installations list", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	query := flags.String("query", "", "case-insensitive substring over id, business id, and shop name")
	limit := flags.Int("limit", 0, "maximum rows to return (default 200)")
	activeOnly := flags.Bool("active", false, "only installations with an active subscription")
	inactiveOnly := flags.Bool("inactive", false, "only installations with an inactive subscription")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *activeOnly && *inactiveOnly {
		return usageError("--active and --inactive are mutually exclusive")
	}
	params := url.Values{}
	if q := strings.TrimSpace(*query); q != "" {
		params.Set("query", q)
	}
	if *limit > 0 {
		params.Set("limit", strconv.Itoa(*limit))
	}
	if *activeOnly {
		params.Set("subscription_active", "true")
	}
	if *inactiveOnly {
		params.Set("subscription_active", "false")
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/installations", params, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response installationListResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	return renderInstallationTable(response)
}

func runInstallationsShow(args []string) error {
	flags := flag.NewFlagSet("installations show", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/installations/"+url.PathEscape(id), nil, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var installation installationView
	if err := json.Unmarshal(raw, &installation); err != nil {
		return err
	}
	return renderInstallationDetail(installation)
}

func runInstallationsStatus(args []string) error {
	flags := flag.NewFlagSet("installations status", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/installations/"+url.PathEscape(id)+"/status", nil, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var status installationStatusView
	if err := json.Unmarshal(raw, &status); err != nil {
		return err
	}
	return renderInstallationStatus(status)
}

func runInstallationsAudit(args []string) error {
	flags := flag.NewFlagSet("installations audit", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	limit := flags.Int("limit", 0, "maximum audit events to return")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	params := url.Values{}
	if *limit > 0 {
		params.Set("limit", strconv.Itoa(*limit))
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/installations/"+url.PathEscape(id)+"/audit-events", params, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response auditEventsResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	return renderAuditEvents(response)
}

func runInstallationsProvision(args []string) error {
	flags := flag.NewFlagSet("installations provision", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	businessID := flags.String("business-id", "", "business identifier to attach to the installation")
	shopName := flags.String("shop-name", "", "shop name to attach to the installation")
	relayEnabled := flags.Bool("relay-enabled", false, "enable remote relay access immediately")
	subscriptionActive := flags.Bool("subscription-active", false, "mark the relay subscription active immediately")
	aiEnabled := flags.Bool("ai-enabled", false, "enable the AI entitlement immediately")
	subscriptionEndsAt := flags.String("subscription-ends-at", "", "optional RFC3339 subscription end time")
	if err := flags.Parse(args); err != nil {
		return err
	}
	body := map[string]any{
		"business_id":         strings.TrimSpace(*businessID),
		"shop_name":           strings.TrimSpace(*shopName),
		"relay_enabled":       *relayEnabled,
		"subscription_active": *subscriptionActive,
		"ai_enabled":          *aiEnabled,
	}
	if ends := strings.TrimSpace(*subscriptionEndsAt); ends != "" {
		if _, err := time.Parse(time.RFC3339, ends); err != nil {
			return fmt.Errorf("subscription-ends-at must be RFC3339: %w", err)
		}
		body["subscription_ends_at"] = ends
	}
	raw, err := admin.requestJSON(http.MethodPost, "/v1/installations", nil, body)
	if err != nil {
		return err
	}
	// Always print the full JSON: the one-time connector and access tokens are
	// only returned here and the operator must capture them.
	return printRawJSON(raw)
}

func runEnrollment(args []string) error {
	if len(args) == 0 {
		return usageError("missing enrollment command (mint)")
	}
	switch args[0] {
	case "mint":
		return runEnrollmentMint(args[1:])
	default:
		return usageError("unknown enrollment command %q", args[0])
	}
}

// runEnrollmentMint mints single-use enrollment ("license") keys on the relay.
// Ship one key per shop; the on-prem backend redeems it on first boot. The raw
// keys are printed only here, so capture them.
func runEnrollmentMint(args []string) error {
	flags := flag.NewFlagSet("enrollment mint", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	count := flags.Int("count", 1, "number of license keys to mint (1-1000)")
	expiresIn := flags.String("expires-in", "", "optional expiry as a Go duration, e.g. 720h (default: never expires)")
	// Bake a subscription into the keys so a shop is activated the moment it
	// redeems the license — no separate operator activation step.
	relay := flags.Bool("relay", false, "bake the remote-access (relay) entitlement into the key")
	ai := flags.Bool("ai", false, "bake the AI entitlement into the key")
	subscription := flags.String(
		"subscription",
		"",
		"bake a subscription of this length, counted from when the key is redeemed: "+
			"e.g. 30d, 6mo, 1y, or a Go duration like 720h; 'perpetual' (or empty with "+
			"--relay/--ai) for no expiry",
	)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *count < 1 || *count > 1000 {
		return usageError("count must be between 1 and 1000")
	}
	body := map[string]any{"count": *count}
	if expires := strings.TrimSpace(*expiresIn); expires != "" {
		if _, err := time.ParseDuration(expires); err != nil {
			return fmt.Errorf("expires-in must be a Go duration (e.g. 720h): %w", err)
		}
		body["expires_in"] = expires
	}
	if *relay || *ai || strings.TrimSpace(*subscription) != "" {
		if _, err := control.ParseLicenseDuration(*subscription); err != nil {
			return err
		}
		if !*relay && !*ai {
			fmt.Fprintln(os.Stderr,
				"note: baking an active subscription with no features; pass --relay and/or --ai to grant access")
		}
		body["subscription"] = map[string]any{
			"relay_enabled": *relay,
			"ai_enabled":    *ai,
			"duration":      strings.TrimSpace(*subscription),
		}
	}
	raw, err := admin.requestJSON(http.MethodPost, "/v1/enrollment/tokens", nil, body)
	if err != nil {
		return err
	}
	return printRawJSON(raw)
}

// diagnosticsResult summarizes one installation's diagnostics pull for display.
type diagnosticsResult struct {
	InstallationID   string `json:"installation_id"`
	ShopName         string `json:"shop_name,omitempty"`
	Status           string `json:"status"` // ok, offline, error
	OutputPath       string `json:"output_path,omitempty"`
	Bytes            int64  `json:"bytes"`
	EventCount       string `json:"event_count,omitempty"`
	AppVersion       string `json:"app_version,omitempty"`
	ConnectorVersion string `json:"connector_version,omitempty"`
	Online           string `json:"online,omitempty"`
	LastConnectedAt  string `json:"last_connected_at,omitempty"`
	Error            string `json:"error,omitempty"`
}

// runInstallationsDiagnostics pulls an installation's tracking/usage/error export
// (the Shop Settings "Export Tracking" data) for one installation or every
// installation the relay can reach, for remote support.
func runInstallationsDiagnostics(args []string) error {
	flags := flag.NewFlagSet("installations diagnostics", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	all := flags.Bool("all", false, "pull from every installation the relay can reach")
	// Export filters (forwarded verbatim to the backend export query).
	format := flags.String("format", "", "export format: csv or json")
	from := flags.String("from", "", "only events at or after this time (RFC3339 or YYYY-MM-DD)")
	to := flags.String("to", "", "only events at or before this time (RFC3339 or YYYY-MM-DD)")
	eventType := flags.String("event-type", "", "filter by event type (usage, error, performance, security, fraud_signal, audit)")
	severity := flags.String("severity", "", "filter by severity (debug, info, warning, error, critical)")
	source := flags.String("source", "", "filter by source (frontend, backend, print_agent, integration)")
	search := flags.String("search", "", "free-text search over event name, trace id, entity, and request path")
	platform := flags.String("platform", "", "filter by platform")
	deviceID := flags.String("device-id", "", "filter by device id")
	sessionID := flags.String("session-id", "", "filter by register/app session id")
	// Single-installation output.
	out := flags.String("out", "", "output file for a single installation (default pointy-diagnostics-<id>-<ts>.zip)")
	// All-installations output.
	outDir := flags.String("out-dir", "", "output directory for --all (default pointy-diagnostics-<ts>)")
	onlineOnly := flags.Bool("online-only", true, "with --all, omit offline installations from the summary")
	concurrency := flags.Int("concurrency", 4, "with --all, number of installations to pull in parallel")
	query := flags.String("query", "", "with --all, filter installations by id/business/shop substring")
	asJSON := flags.Bool("json", false, "print a JSON summary instead of a table")

	// Accept both `diagnostics <id> [flags]` and `diagnostics --all [flags]`.
	id := ""
	rest := args
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		id = strings.TrimSpace(args[0])
		rest = args[1:]
	}
	if err := flags.Parse(rest); err != nil {
		return err
	}
	if *all && id != "" {
		return usageError("pass an installation id or --all, not both")
	}
	if !*all && id == "" {
		return usageError("provide an installation id as the first argument, or --all")
	}

	params := url.Values{}
	setParam := func(key, value string) {
		if v := strings.TrimSpace(value); v != "" {
			params.Set(key, v)
		}
	}
	setParam("format", *format)
	setParam("date_from", *from)
	setParam("date_to", *to)
	setParam("event_type", *eventType)
	setParam("severity", *severity)
	setParam("source", *source)
	setParam("search", *search)
	setParam("platform", *platform)
	setParam("device_id", *deviceID)
	setParam("session_id", *sessionID)

	if *all {
		return runDiagnosticsAll(admin, params, *outDir, *query, *onlineOnly, *concurrency, *asJSON)
	}
	return runDiagnosticsSingle(admin, id, params, *out, *asJSON)
}

func runDiagnosticsSingle(admin *adminControlFlags, id string, params url.Values, out string, asJSON bool) error {
	outPath := strings.TrimSpace(out)
	if outPath == "" {
		outPath = fmt.Sprintf(
			"pointy-diagnostics-%s-%s.zip",
			sanitizeFilename(id),
			time.Now().UTC().Format("20060102T150405Z"),
		)
	}
	header, n, err := admin.pullDiagnosticsToFile(id, params, outPath)
	if err != nil {
		return err
	}
	result := diagnosticsResultFromHeader(id, outPath, n, header)
	if asJSON {
		return printJSONValue([]diagnosticsResult{result})
	}
	return renderDiagnosticsResult(result)
}

func runDiagnosticsAll(
	admin *adminControlFlags,
	params url.Values,
	outDir, query string,
	onlineOnly bool,
	concurrency int,
	asJSON bool,
) error {
	listParams := url.Values{}
	if q := strings.TrimSpace(query); q != "" {
		listParams.Set("query", q)
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/installations", listParams, nil)
	if err != nil {
		return err
	}
	var list installationListResponse
	if err := json.Unmarshal(raw, &list); err != nil {
		return err
	}
	if len(list.Installations) == 0 {
		fmt.Println("No installations found.")
		return nil
	}

	dir := strings.TrimSpace(outDir)
	if dir == "" {
		dir = fmt.Sprintf("pointy-diagnostics-%s", time.Now().UTC().Format("20060102T150405Z"))
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	if concurrency < 1 {
		concurrency = 1
	}
	results := make([]diagnosticsResult, len(list.Installations))
	sem := make(chan struct{}, concurrency)
	var wg sync.WaitGroup
	for i, inst := range list.Installations {
		wg.Add(1)
		go func(i int, inst installationView) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			outPath := filepath.Join(dir, sanitizeFilename(inst.ID)+".zip")
			header, n, perr := admin.pullDiagnosticsToFile(inst.ID, params, outPath)
			if perr != nil {
				res := diagnosticsResult{InstallationID: inst.ID, ShopName: inst.ShopName}
				if isConnectorOfflineError(perr) {
					res.Status = "offline"
				} else {
					res.Status = "error"
					res.Error = perr.Error()
				}
				results[i] = res
				return
			}
			res := diagnosticsResultFromHeader(inst.ID, outPath, n, header)
			res.ShopName = inst.ShopName
			results[i] = res
		}(i, inst)
	}
	wg.Wait()

	return renderDiagnosticsResults(results, dir, onlineOnly, asJSON)
}

// pullDiagnosticsToFile pulls one installation's diagnostics ZIP to outPath via
// the relay admin API. It writes to a temp file first so a failed pull never
// leaves a partial or empty file behind.
func (a *adminControlFlags) pullDiagnosticsToFile(
	id string,
	params url.Values,
	outPath string,
) (http.Header, int64, error) {
	path := "/v1/installations/" + url.PathEscape(id) + "/diagnostics-analytics"
	tmp, err := os.CreateTemp(filepath.Dir(outPath), ".pointy-diagnostics-*.zip.tmp")
	if err != nil {
		return nil, 0, err
	}
	tmpName := tmp.Name()
	header, n, reqErr := a.requestBinary(http.MethodGet, path, params, tmp)
	closeErr := tmp.Close()
	if reqErr != nil {
		_ = os.Remove(tmpName)
		return header, 0, reqErr
	}
	if closeErr != nil {
		_ = os.Remove(tmpName)
		return header, 0, closeErr
	}
	if err := os.Rename(tmpName, outPath); err != nil {
		_ = os.Remove(tmpName)
		return header, 0, err
	}
	return header, n, nil
}

// Bounds for streaming a download (a diagnostics export) down through the
// relay. How long a download takes is the export's size divided by the SHOP's
// uplink, so the admin client's total deadline — the 10s every JSON call uses —
// failed every real pull with "Client.Timeout exceeded", and each abandoned
// pull left the export running on the shop's server. These bound the two
// things that do mean "stuck" instead: the wait for the relay to start
// answering (it gives up on a silent connector itself at 60s), and a body that
// stops moving.
var (
	downloadHeaderTimeout = 90 * time.Second
	downloadIdleTimeout   = 2 * time.Minute
)

// requestBinary performs an authenticated admin API call and streams the
// response body into dst. Unlike requestJSON it neither caps nor buffers the
// body, and it has no total deadline, so it suits large export downloads.
func (a *adminControlFlags) requestBinary(
	method, path string,
	query url.Values,
	dst io.Writer,
) (http.Header, int64, error) {
	if strings.TrimSpace(*a.adminToken) == "" {
		return nil, 0, fmt.Errorf("admin token is required (set --admin-token or POINTY_RELAY_ADMIN_TOKEN)")
	}
	endpoint, err := relayAdminEndpoint(*a.controlURL, path)
	if err != nil {
		return nil, 0, err
	}
	if len(query) > 0 {
		endpoint.RawQuery = query.Encode()
	}
	client, err := newRelayAdminHTTPClient(relayAdminHTTPClientOptions{
		ControlURL:     *a.controlURL,
		AllowInsecure:  *a.allowInsecure,
		CAFile:         *a.caFile,
		ClientCertFile: *a.clientCertFile,
		ClientKeyFile:  *a.clientKeyFile,
		TLSServerName:  *a.tlsServerName,
	})
	if err != nil {
		return nil, 0, err
	}
	// A copy, so the JSON client's total deadline never applies to a body
	// whose length is set by a shop's uplink. The watchdogs below replace it.
	download := *client
	download.Timeout = 0
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var headerExpired, bodyStalled atomic.Bool
	headerWatchdog := time.AfterFunc(downloadHeaderTimeout, func() {
		headerExpired.Store(true)
		cancel()
	})
	request, err := http.NewRequestWithContext(ctx, method, endpoint.String(), nil)
	if err != nil {
		headerWatchdog.Stop()
		return nil, 0, err
	}
	request.Header.Set("Accept", "application/zip")
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(*a.adminToken))
	response, err := download.Do(request)
	headerWatchdog.Stop()
	if err != nil {
		if headerExpired.Load() {
			return nil, 0, fmt.Errorf(
				"relay admin %s %s: no response within %s (the shop's server or its connector did not answer)",
				method, path, downloadHeaderTimeout,
			)
		}
		return nil, 0, err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		payload, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		return response.Header, 0, fmt.Errorf(
			"relay admin %s %s returned %d: %s",
			method, path, response.StatusCode, strings.TrimSpace(string(payload)),
		)
	}
	idleWatchdog := time.AfterFunc(downloadIdleTimeout, func() {
		bodyStalled.Store(true)
		cancel()
	})
	defer idleWatchdog.Stop()
	n, err := io.Copy(dst, idleResettingReader{
		reader: response.Body,
		timer:  idleWatchdog,
		window: downloadIdleTimeout,
	})
	if err != nil {
		if bodyStalled.Load() {
			return response.Header, n, fmt.Errorf(
				"relay admin %s %s: download stalled — no data for %s after %s",
				method, path, downloadIdleTimeout, humanBytes(n),
			)
		}
		return response.Header, n, err
	}
	return response.Header, n, nil
}

// idleResettingReader pushes an idle watchdog out every time bytes arrive, so
// only a body that stops moving trips it.
type idleResettingReader struct {
	reader io.Reader
	timer  *time.Timer
	window time.Duration
}

func (r idleResettingReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	if n > 0 {
		r.timer.Reset(r.window)
	}
	return n, err
}

func diagnosticsResultFromHeader(id, outPath string, n int64, header http.Header) diagnosticsResult {
	res := diagnosticsResult{
		InstallationID: id,
		Status:         "ok",
		OutputPath:     outPath,
		Bytes:          n,
	}
	if header != nil {
		res.EventCount = header.Get("X-Pointy-Analytics-Event-Count")
		res.AppVersion = header.Get("X-Pointy-App-Version")
		res.ConnectorVersion = header.Get("X-Pointy-Connector-Version")
		res.Online = header.Get(diagnosticsOnlineHeader)
		res.LastConnectedAt = header.Get(diagnosticsLastConnectedHeader)
	}
	return res
}

const (
	diagnosticsOnlineHeader        = "X-Pointy-Diag-Online"
	diagnosticsLastConnectedHeader = "X-Pointy-Diag-Last-Connected-At"
)

func isConnectorOfflineError(err error) bool {
	return err != nil && strings.Contains(err.Error(), "connector offline")
}

func sanitizeFilename(value string) string {
	cleaned := strings.Map(func(r rune) rune {
		switch r {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0:
			return '_'
		}
		return r
	}, value)
	if cleaned = strings.TrimSpace(cleaned); cleaned == "" {
		return "installation"
	}
	return cleaned
}

func printJSONValue(value any) error {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	if _, err := os.Stdout.Write(encoded); err != nil {
		return err
	}
	fmt.Println()
	return nil
}

func renderDiagnosticsResult(result diagnosticsResult) error {
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	rows := [][2]string{
		{"id", result.InstallationID},
		{"output", result.OutputPath},
		{"events", dashIfEmpty(result.EventCount)},
		{"size", humanBytes(result.Bytes)},
		{"app version", dashIfEmpty(result.AppVersion)},
		{"connector version", dashIfEmpty(result.ConnectorVersion)},
		{"last connector seen", dashIfEmpty(result.LastConnectedAt)},
	}
	for _, row := range rows {
		fmt.Fprintf(writer, "%s\t%s\n", row[0], row[1])
	}
	return writer.Flush()
}

func renderDiagnosticsResults(results []diagnosticsResult, dir string, onlineOnly, asJSON bool) error {
	shown := make([]diagnosticsResult, 0, len(results))
	pulled, offline, failed := 0, 0, 0
	for _, res := range results {
		switch res.Status {
		case "ok":
			pulled++
		case "offline":
			offline++
		default:
			failed++
		}
		if onlineOnly && res.Status == "offline" {
			continue
		}
		shown = append(shown, res)
	}
	if asJSON {
		if err := printJSONValue(shown); err != nil {
			return err
		}
	} else {
		writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
		fmt.Fprintln(writer, "ID\tSHOP\tSTATUS\tEVENTS\tSIZE\tDETAIL")
		for _, res := range shown {
			detail := res.OutputPath
			switch res.Status {
			case "error":
				detail = res.Error
			case "offline":
				detail = "-"
			}
			fmt.Fprintf(
				writer,
				"%s\t%s\t%s\t%s\t%s\t%s\n",
				res.InstallationID,
				dashIfEmpty(res.ShopName),
				res.Status,
				dashIfEmpty(res.EventCount),
				humanBytes(res.Bytes),
				dashIfEmpty(detail),
			)
		}
		if err := writer.Flush(); err != nil {
			return err
		}
	}
	fmt.Printf("\n%d pulled, %d offline, %d error(s). Saved to %s\n", pulled, offline, failed, dir)
	return nil
}

func humanBytes(n int64) string {
	if n <= 0 {
		return "-"
	}
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%dB", n)
	}
	div, exp := int64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f%cB", float64(n)/float64(div), "KMGTPE"[exp])
}

// adminControlFlags collects the connection settings every API-based operator
// command shares. Registering them once (and reading defaults from the
// environment) lets an operator export POINTY_RELAY_CONTROL_URL and
// POINTY_RELAY_ADMIN_TOKEN a single time and then run terse commands.
type adminControlFlags struct {
	controlURL     *string
	adminToken     *string
	allowInsecure  *bool
	caFile         *string
	clientCertFile *string
	clientKeyFile  *string
	tlsServerName  *string
}

func registerAdminControlFlags(flags *flag.FlagSet) *adminControlFlags {
	return &adminControlFlags{
		controlURL:     flags.String("control-url", envString("POINTY_RELAY_CONTROL_URL", "http://127.0.0.1:8091"), "relay admin control URL"),
		adminToken:     flags.String("admin-token", envString("POINTY_RELAY_ADMIN_TOKEN", ""), "relay admin bearer token"),
		allowInsecure:  flags.Bool("allow-insecure-control", envBool("POINTY_RELAY_ALLOW_INSECURE_CONTROL", false), "allow cleartext relay admin control URL for local development"),
		caFile:         flags.String("control-ca", envString("POINTY_RELAY_CONTROL_CA_FILE", ""), "CA bundle for relay admin control TLS"),
		clientCertFile: flags.String("control-client-cert", envString("POINTY_RELAY_CONTROL_CLIENT_CERT_FILE", ""), "client certificate for relay admin control mTLS"),
		clientKeyFile:  flags.String("control-client-key", envString("POINTY_RELAY_CONTROL_CLIENT_KEY_FILE", ""), "client key for relay admin control mTLS"),
		tlsServerName:  flags.String("control-tls-server-name", envString("POINTY_RELAY_CONTROL_TLS_SERVER_NAME", ""), "expected relay admin control TLS server name"),
	}
}

// requestJSON performs an authenticated admin API call and returns the raw JSON
// response body. body is nil for GET requests; query may be nil.
func (a *adminControlFlags) requestJSON(method, path string, query url.Values, body any) (json.RawMessage, error) {
	if strings.TrimSpace(*a.adminToken) == "" {
		return nil, fmt.Errorf("admin token is required (set --admin-token or POINTY_RELAY_ADMIN_TOKEN)")
	}
	endpoint, err := relayAdminEndpoint(*a.controlURL, path)
	if err != nil {
		return nil, err
	}
	if len(query) > 0 {
		endpoint.RawQuery = query.Encode()
	}
	client, err := newRelayAdminHTTPClient(relayAdminHTTPClientOptions{
		ControlURL:     *a.controlURL,
		AllowInsecure:  *a.allowInsecure,
		CAFile:         *a.caFile,
		ClientCertFile: *a.clientCertFile,
		ClientKeyFile:  *a.clientKeyFile,
		TLSServerName:  *a.tlsServerName,
	})
	if err != nil {
		return nil, err
	}
	var reader io.Reader
	if body != nil {
		content, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(content)
	}
	request, err := http.NewRequest(method, endpoint.String(), reader)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(*a.adminToken))
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	payload, _ := io.ReadAll(io.LimitReader(response.Body, 4<<20))
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("relay admin %s %s returned %d: %s", method, path, response.StatusCode, strings.TrimSpace(string(payload)))
	}
	return json.RawMessage(payload), nil
}

// idAndFlags treats the first argument as the installation id and parses the
// remaining arguments as flags, so commands read as `... <id> [flags]`.
func idAndFlags(args []string, flags *flag.FlagSet) (string, error) {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return "", usageError("missing installation id as the first argument")
	}
	id := strings.TrimSpace(args[0])
	if id == "" {
		return "", usageError("installation id must not be empty")
	}
	if err := flags.Parse(args[1:]); err != nil {
		return "", err
	}
	return id, nil
}

// idAndFlagsOptional accepts the installation id either as the first positional
// argument or via --installation-id, keeping the original subscription-update
// interface working while allowing the terser positional form.
func idAndFlagsOptional(args []string, flags *flag.FlagSet, idFlag *string) (string, error) {
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		return idAndFlags(args, flags)
	}
	if err := flags.Parse(args); err != nil {
		return "", err
	}
	id := strings.TrimSpace(*idFlag)
	if id == "" {
		return "", usageError("missing installation id (pass it as the first argument or via --installation-id)")
	}
	return id, nil
}

// resolveActor fills the audit actor from the flag, then the environment, then
// the OS user, so operators rarely need to type --actor.
func resolveActor(flagValue string) string {
	if v := strings.TrimSpace(flagValue); v != "" {
		return v
	}
	if v := strings.TrimSpace(os.Getenv("POINTY_RELAY_OPERATOR")); v != "" {
		return v
	}
	if v := strings.TrimSpace(os.Getenv("USER")); v != "" {
		return v
	}
	return "operator-cli"
}

func defaultReason(flagValue, fallback string) string {
	if v := strings.TrimSpace(flagValue); v != "" {
		return v
	}
	return fallback
}

func printRawJSON(raw json.RawMessage) error {
	var buf bytes.Buffer
	if err := json.Indent(&buf, raw, "", "  "); err != nil {
		// Not valid JSON to re-indent; print as-is.
		_, err = os.Stdout.Write(raw)
		fmt.Println()
		return err
	}
	_, err := os.Stdout.Write(buf.Bytes())
	fmt.Println()
	return err
}

type installationView struct {
	ID                       string  `json:"id"`
	BusinessID               string  `json:"business_id"`
	ShopName                 string  `json:"shop_name"`
	RelayEnabled             bool    `json:"relay_enabled"`
	SubscriptionActive       bool    `json:"subscription_active"`
	AIEnabled                bool    `json:"ai_enabled"`
	RelayActive              bool    `json:"relay_active"`
	SubscriptionEndsAt       *string `json:"subscription_ends_at"`
	LastConnectorConnectedAt *string `json:"last_connector_connected_at"`
	CreatedAt                *string `json:"created_at"`
	CertificateExpiresAt     *string `json:"connector_certificate_expires_at"`
}

type installationListResponse struct {
	Installations []installationView `json:"installations"`
	Count         int                `json:"count"`
}

type installationStatusView struct {
	InstallationID           string  `json:"installation_id"`
	ShopName                 string  `json:"shop_name"`
	RelayEnabled             bool    `json:"relay_enabled"`
	RelayActive              bool    `json:"relay_active"`
	SubscriptionActive       bool    `json:"subscription_active"`
	SubscriptionEndsAt       *string `json:"subscription_ends_at"`
	ConnectorOnlineLocal     bool    `json:"connector_online_local"`
	LastConnectorConnectedAt *string `json:"last_connector_connected_at"`
	CertificateExpiresAt     *string `json:"connector_certificate_expires_at"`
	ConnectorPresence        *struct {
		Online bool   `json:"online"`
		NodeID string `json:"node_id"`
	} `json:"connector_presence"`
	ConnectorTunnels []struct {
		NodeID    string `json:"node_id"`
		TunnelID  uint64 `json:"tunnel_id"`
		Transport string `json:"transport"`
	} `json:"connector_tunnels"`
}

type auditEventsResponse struct {
	InstallationID string `json:"installation_id"`
	Events         []struct {
		Action    string  `json:"action"`
		Actor     string  `json:"actor"`
		Reason    string  `json:"reason"`
		CreatedAt *string `json:"created_at"`
	} `json:"events"`
}

func renderInstallationTable(response installationListResponse) error {
	if len(response.Installations) == 0 {
		fmt.Println("No installations found.")
		return nil
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "ID\tSHOP\tRELAY\tSUB\tAI\tENDS\tLAST SEEN")
	for _, installation := range response.Installations {
		fmt.Fprintf(
			writer,
			"%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
			installation.ID,
			dashIfEmpty(installation.ShopName),
			onOff(installation.RelayEnabled),
			onOff(installation.SubscriptionActive),
			onOff(installation.AIEnabled),
			formatTimeField(installation.SubscriptionEndsAt),
			formatTimeField(installation.LastConnectorConnectedAt),
		)
	}
	if err := writer.Flush(); err != nil {
		return err
	}
	fmt.Printf("\n%d installation(s).\n", response.Count)
	return nil
}

func renderInstallationDetail(installation installationView) error {
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	rows := [][2]string{
		{"id", installation.ID},
		{"shop", dashIfEmpty(installation.ShopName)},
		{"business", dashIfEmpty(installation.BusinessID)},
		{"relay enabled", onOff(installation.RelayEnabled)},
		{"subscription", onOff(installation.SubscriptionActive)},
		{"relay active", onOff(installation.RelayActive)},
		{"ai enabled", onOff(installation.AIEnabled)},
		{"subscription ends", formatTimeField(installation.SubscriptionEndsAt)},
		{"last connector seen", formatTimeField(installation.LastConnectorConnectedAt)},
		{"connector cert expires", formatTimeField(installation.CertificateExpiresAt)},
		{"created", formatTimeField(installation.CreatedAt)},
	}
	for _, row := range rows {
		fmt.Fprintf(writer, "%s\t%s\n", row[0], row[1])
	}
	return writer.Flush()
}

func renderInstallationStatus(status installationStatusView) error {
	online := status.ConnectorOnlineLocal
	node := ""
	if status.ConnectorPresence != nil {
		online = online || status.ConnectorPresence.Online
		node = status.ConnectorPresence.NodeID
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	rows := [][2]string{
		{"id", status.InstallationID},
		{"shop", dashIfEmpty(status.ShopName)},
		{"relay enabled", onOff(status.RelayEnabled)},
		{"relay active", onOff(status.RelayActive)},
		{"subscription", onOff(status.SubscriptionActive)},
		{"subscription ends", formatTimeField(status.SubscriptionEndsAt)},
		{"connector online", onOff(online)},
		{"connector node", dashIfEmpty(node)},
	}
	// One row per tunnel: which node holds it and how it arrived. A relay
	// older than the tunnel list sends none, leaving the node row above.
	for _, tunnel := range status.ConnectorTunnels {
		label := "tunnel " + strconv.FormatUint(tunnel.TunnelID, 10)
		if tunnel.TunnelID == 0 {
			label = "tunnel (old connector)"
		}
		rows = append(rows, [2]string{label, tunnel.NodeID + " via " + dashIfEmpty(tunnel.Transport)})
	}
	rows = append(rows, [][2]string{
		{"last connector seen", formatTimeField(status.LastConnectorConnectedAt)},
		{"connector cert expires", formatTimeField(status.CertificateExpiresAt)},
	}...)
	for _, row := range rows {
		fmt.Fprintf(writer, "%s\t%s\n", row[0], row[1])
	}
	return writer.Flush()
}

func renderAuditEvents(response auditEventsResponse) error {
	if len(response.Events) == 0 {
		fmt.Printf("No audit events for %s.\n", response.InstallationID)
		return nil
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "TIME\tACTION\tACTOR\tREASON")
	for _, event := range response.Events {
		fmt.Fprintf(
			writer,
			"%s\t%s\t%s\t%s\n",
			formatTimeField(event.CreatedAt),
			dashIfEmpty(event.Action),
			dashIfEmpty(event.Actor),
			dashIfEmpty(event.Reason),
		)
	}
	return writer.Flush()
}

func formatTimeField(value *string) string {
	if value == nil || strings.TrimSpace(*value) == "" {
		return "—"
	}
	if parsed, err := time.Parse(time.RFC3339, *value); err == nil {
		return parsed.UTC().Format("2006-01-02 15:04 UTC")
	}
	return *value
}

func onOff(value bool) string {
	if value {
		return "on"
	}
	return "off"
}

func dashIfEmpty(value string) string {
	if strings.TrimSpace(value) == "" {
		return "—"
	}
	return value
}

func runMigrate(args []string) error {
	flags := flag.NewFlagSet("migrate", flag.ExitOnError)
	databaseURL := flags.String(
		"database-url",
		envString("POINTY_RELAY_DATABASE_URL", defaultRelayDatabaseURL),
		"PostgreSQL database URL for relay installations",
	)
	if err := flags.Parse(args); err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	store, err := control.NewPostgresStore(ctx, *databaseURL, control.RealClock{})
	if err != nil {
		return err
	}
	defer store.Close()
	if err := store.Migrate(ctx); err != nil {
		return err
	}
	fmt.Fprintln(os.Stdout, "relay PostgreSQL migrations applied")
	return nil
}

func parseOrigin(raw string) (*url.URL, error) {
	trimmed := strings.TrimSpace(raw)
	if !strings.Contains(trimmed, "://") {
		trimmed = "http://" + trimmed
	}
	parsed, err := url.Parse(trimmed)
	if err != nil {
		return nil, err
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, fmt.Errorf("backend URL must use http or https")
	}
	if parsed.Host == "" {
		return nil, fmt.Errorf("backend URL host is required")
	}
	return parsed, nil
}

func resolveConnectorBackend(ctx context.Context, raw string) (*url.URL, error) {
	if strings.TrimSpace(raw) != "" {
		return parseOrigin(raw)
	}
	backendURL, err := discovery.DiscoverBackend(ctx, discovery.BackendOptions{})
	if err != nil {
		return nil, fmt.Errorf("backend discovery failed: %w", err)
	}
	return backendURL, nil
}

type backendConnectorConfig struct {
	InstallationID                string     `json:"installation_id"`
	ShopName                      string     `json:"shop_name"`
	RelayConnectorAddress         string     `json:"relay_connector_address"`
	ConnectorToken                string     `json:"connector_token"`
	TLSServerName                 string     `json:"tls_server_name"`
	ConnectorCertificatePEM       string     `json:"connector_certificate_pem"`
	ConnectorCACertificatePEM     string     `json:"connector_ca_certificate_pem"`
	ConnectorCertificateExpiresAt *time.Time `json:"connector_certificate_expires_at"`
}

var newBackendConnectorHTTPClient = func() *http.Client {
	return &http.Client{Timeout: 10 * time.Second}
}

func fetchBackendConnectorConfig(
	ctx context.Context,
	backendURL *url.URL,
	rawEndpoint string,
	setupToken string,
	connectorToken string,
	csrPEM string,
) (backendConnectorConfig, error) {
	if strings.TrimSpace(setupToken) == "" && strings.TrimSpace(connectorToken) == "" {
		return backendConnectorConfig{}, fmt.Errorf("connector setup token or connector token is required for connector bootstrap")
	}
	endpoint, err := backendConnectorConfigEndpoint(backendURL, rawEndpoint)
	if err != nil {
		return backendConnectorConfig{}, err
	}

	var body io.Reader
	if strings.TrimSpace(csrPEM) != "" {
		content, err := json.Marshal(map[string]string{"csr_pem": csrPEM})
		if err != nil {
			return backendConnectorConfig{}, err
		}
		body = strings.NewReader(string(content))
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint.String(), body)
	if err != nil {
		return backendConnectorConfig{}, err
	}
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if strings.TrimSpace(setupToken) != "" {
		request.Header.Set("X-Pointy-Connector-Setup-Token", strings.TrimSpace(setupToken))
	}
	if strings.TrimSpace(connectorToken) != "" {
		request.Header.Set("X-Pointy-Connector-Token", strings.TrimSpace(connectorToken))
	}

	client := newBackendConnectorHTTPClient()
	response, err := client.Do(request)
	if err != nil {
		return backendConnectorConfig{}, fmt.Errorf("backend connector bootstrap failed: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		detail, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return backendConnectorConfig{}, fmt.Errorf(
			"backend connector bootstrap returned %d: %s",
			response.StatusCode,
			strings.TrimSpace(string(detail)),
		)
	}

	var config backendConnectorConfig
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&config); err != nil {
		return backendConnectorConfig{}, fmt.Errorf("backend connector bootstrap returned invalid JSON: %w", err)
	}
	if strings.TrimSpace(config.ConnectorToken) == "" {
		return backendConnectorConfig{}, fmt.Errorf("backend connector bootstrap did not return a connector token")
	}
	return config, nil
}

func startBackendConnectorHeartbeat(
	ctx context.Context,
	backendURL *url.URL,
	connectorToken string,
	logger *slog.Logger,
) {
	if backendURL == nil || strings.TrimSpace(connectorToken) == "" {
		return
	}
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			if err := postBackendConnectorHeartbeat(ctx, backendURL, connectorToken); err != nil {
				logger.Warn("backend connector heartbeat failed", "error", err)
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
}

func postBackendConnectorHeartbeat(
	ctx context.Context,
	backendURL *url.URL,
	connectorToken string,
) error {
	endpoint := *backendURL
	endpoint.Path = joinPath(endpoint.Path, "/api/relay/connector-heartbeat/")
	endpoint.RawQuery = ""
	body := strings.NewReader(fmt.Sprintf(`{"version":%q}`, "pointy-relay/"+version))
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint.String(), body)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Pointy-Connector-Token", strings.TrimSpace(connectorToken))
	client := newBackendConnectorHTTPClient()
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		detail, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf(
			"backend connector heartbeat returned %d: %s",
			response.StatusCode,
			strings.TrimSpace(string(detail)),
		)
	}
	return nil
}

func backendConnectorConfigEndpoint(backendURL *url.URL, rawEndpoint string) (*url.URL, error) {
	if backendURL == nil {
		return nil, fmt.Errorf("backend URL is required")
	}
	rawEndpoint = strings.TrimSpace(rawEndpoint)
	if rawEndpoint == "" {
		endpoint := *backendURL
		endpoint.Path = joinPath(endpoint.Path, "/api/relay/connector-config/")
		endpoint.RawQuery = ""
		return &endpoint, nil
	}

	parsed, err := url.Parse(rawEndpoint)
	if err != nil {
		return nil, err
	}
	if parsed.IsAbs() {
		if parsed.Scheme != "http" && parsed.Scheme != "https" {
			return nil, fmt.Errorf("backend connector config URL must use http or https")
		}
		return parsed, nil
	}

	endpoint := *backendURL
	if strings.HasPrefix(parsed.Path, "/") {
		endpoint.Path = parsed.Path
	} else {
		endpoint.Path = joinPath(endpoint.Path, parsed.Path)
	}
	endpoint.RawQuery = parsed.RawQuery
	return &endpoint, nil
}

func joinPath(basePath string, childPath string) string {
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

type subscriptionUpdateOptions struct {
	InstallationID       string
	Actor                string
	Reason               string
	RelayEnabled         string
	SubscriptionActive   string
	AIEnabled            string
	SubscriptionEndsAt   string
	ClearSubscriptionEnd bool
}

func subscriptionUpdateBody(options subscriptionUpdateOptions) (map[string]any, error) {
	if strings.TrimSpace(options.InstallationID) == "" {
		return nil, fmt.Errorf("installation id is required")
	}
	if strings.TrimSpace(options.Actor) == "" {
		return nil, fmt.Errorf("actor is required")
	}
	if strings.TrimSpace(options.Reason) == "" {
		return nil, fmt.Errorf("reason is required")
	}
	body := map[string]any{
		"actor":  strings.TrimSpace(options.Actor),
		"reason": strings.TrimSpace(options.Reason),
	}
	changeCount := 0
	if value, ok, err := optionalBoolFlag("relay-enabled", options.RelayEnabled); err != nil {
		return nil, err
	} else if ok {
		body["relay_enabled"] = value
		changeCount++
	}
	if value, ok, err := optionalBoolFlag("subscription-active", options.SubscriptionActive); err != nil {
		return nil, err
	} else if ok {
		body["subscription_active"] = value
		changeCount++
	}
	if value, ok, err := optionalBoolFlag("ai-enabled", options.AIEnabled); err != nil {
		return nil, err
	} else if ok {
		body["ai_enabled"] = value
		changeCount++
	}
	if strings.TrimSpace(options.SubscriptionEndsAt) != "" {
		if options.ClearSubscriptionEnd {
			return nil, fmt.Errorf("subscription-ends-at cannot be combined with clear-subscription-end")
		}
		endsAt, err := time.Parse(time.RFC3339, strings.TrimSpace(options.SubscriptionEndsAt))
		if err != nil {
			return nil, fmt.Errorf("subscription-ends-at must be RFC3339: %w", err)
		}
		body["subscription_ends_at"] = endsAt.UTC().Format(time.RFC3339)
		changeCount++
	}
	if options.ClearSubscriptionEnd {
		body["clear_subscription_end"] = true
		changeCount++
	}
	if changeCount == 0 {
		return nil, fmt.Errorf("at least one subscription field is required")
	}
	return body, nil
}

func provisionedInstallationOutput(provisioned control.ProvisionedInstallation) map[string]any {
	installation := provisioned.Installation
	return map[string]any{
		"installation": map[string]any{
			"id":                                installation.ID,
			"business_id":                       installation.BusinessID,
			"shop_name":                         installation.ShopName,
			"relay_enabled":                     installation.RelayEnabled,
			"subscription_active":               installation.SubscriptionActive,
			"subscription_ends_at":              installation.SubscriptionEndsAt,
			"ai_enabled":                        installation.AIEnabled,
			"created_at":                        installation.CreatedAt,
			"updated_at":                        installation.UpdatedAt,
			"last_connector_connected_at":       installation.LastConnectorConnectedAt,
			"connector_certificate_fingerprint": installation.ConnectorCertificateFingerprint,
			"connector_certificate_serial":      installation.ConnectorCertificateSerial,
			"connector_certificate_expires_at":  installation.ConnectorCertificateExpiresAt,
		},
		"connector_token": provisioned.ConnectorToken,
		"access_token":    provisioned.AccessToken,
	}
}

func optionalBoolFlag(name string, raw string) (bool, bool, error) {
	raw = strings.TrimSpace(strings.ToLower(raw))
	if raw == "" {
		return false, false, nil
	}
	switch raw {
	case "1", "true", "yes":
		return true, true, nil
	case "0", "false", "no":
		return false, true, nil
	default:
		return false, false, fmt.Errorf("%s must be true or false", name)
	}
}

type relayAdminHTTPClientOptions struct {
	ControlURL     string
	AllowInsecure  bool
	CAFile         string
	ClientCertFile string
	ClientKeyFile  string
	TLSServerName  string
}

var newRelayAdminHTTPClient = func(options relayAdminHTTPClientOptions) (*http.Client, error) {
	parsed, err := url.Parse(strings.TrimSpace(options.ControlURL))
	if err != nil {
		return nil, err
	}
	if parsed.Scheme == "http" {
		if !options.AllowInsecure {
			return nil, fmt.Errorf("relay admin control URL must use https unless allow-insecure-control is enabled for local development")
		}
		return &http.Client{Timeout: 10 * time.Second}, nil
	}
	if parsed.Scheme != "https" {
		return nil, fmt.Errorf("relay admin control URL must use http or https")
	}
	tlsConfig, err := security.ClientTLSConfig(security.ClientTLSOptions{
		CAFile:     options.CAFile,
		CertFile:   options.ClientCertFile,
		KeyFile:    options.ClientKeyFile,
		ServerName: options.TLSServerName,
	})
	if err != nil {
		return nil, err
	}
	return &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: tlsConfig,
		},
	}, nil
}

func relayAdminEndpoint(controlURL string, path string) (*url.URL, error) {
	parsed, err := url.Parse(strings.TrimSpace(controlURL))
	if err != nil {
		return nil, err
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return nil, fmt.Errorf("relay admin control URL is required")
	}
	parsed.Path = joinPath(parsed.Path, path)
	parsed.RawQuery = ""
	return parsed, nil
}

func relayTLSServerName(relayAddress string) string {
	host, _, err := net.SplitHostPort(strings.TrimSpace(relayAddress))
	if err != nil {
		return strings.Trim(strings.TrimSpace(relayAddress), "[]")
	}
	return strings.Trim(host, "[]")
}

func envString(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func envBool(key string, fallback bool) bool {
	value := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if value == "" {
		return fallback
	}
	return value == "1" || value == "true" || value == "yes"
}

func envDuration(key string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envInt(key string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envInt64(key string, fallback int64) int64 {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return fallback
	}
	return parsed
}

func newRedisClient(ctx context.Context, rawURL string) (*redis.Client, error) {
	rawURL = strings.TrimSpace(rawURL)
	if rawURL == "" {
		return nil, nil
	}
	options, err := redis.ParseURL(rawURL)
	if err != nil {
		return nil, err
	}
	client := redis.NewClient(options)
	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		return nil, err
	}
	return client, nil
}

// connectorServerTLSConfig is the connector mTLS configuration, shared by the
// TCP listener and the WebSocket tunnel route. Nil when the connector runs
// without TLS (local development only).
func connectorServerTLSConfig(
	certFile string,
	keyFile string,
	certPEM string,
	keyPEM string,
	clientCAFile string,
	clientCAPEM string,
	allowInsecure bool,
) (*tls.Config, error) {
	if allowInsecure {
		return nil, nil
	}
	config, err := security.ServerTLSConfig(security.ServerTLSOptions{
		CertFile:        certFile,
		CertPEM:         certPEM,
		KeyFile:         keyFile,
		KeyPEM:          keyPEM,
		ClientCAFile:    clientCAFile,
		ClientCAPEM:     clientCAPEM,
		RequireClientCA: true,
	})
	if err != nil {
		return nil, fmt.Errorf("connector mTLS setup failed: %w", err)
	}
	return config, nil
}

func secureHTTPListener(
	listener net.Listener,
	certFile string,
	keyFile string,
	certPEM string,
	keyPEM string,
	clientCAFile string,
	clientCAPEM string,
	requireAdminClientCert bool,
	allowInsecure bool,
) (net.Listener, error) {
	if allowInsecure {
		if requireAdminClientCert {
			return nil, fmt.Errorf("admin client certificates require HTTP TLS")
		}
		return listener, nil
	}
	options := security.ServerTLSOptions{
		CertFile: certFile,
		CertPEM:  certPEM,
		KeyFile:  keyFile,
		KeyPEM:   keyPEM,
	}
	if requireAdminClientCert {
		options.ClientCAFile = clientCAFile
		options.ClientCAPEM = clientCAPEM
		options.RequestClientCA = true
	}
	config, err := security.ServerTLSConfig(options)
	if err != nil {
		return nil, fmt.Errorf("HTTP TLS setup failed: %w", err)
	}
	return tls.NewListener(listener, config), nil
}
