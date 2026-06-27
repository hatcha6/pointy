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
	"strconv"
	"strings"
	"sync"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/redis/go-redis/v9"

	"pointy/relay/internal/artifacts"
	"pointy/relay/internal/connector"
	"pointy/relay/internal/control"
	"pointy/relay/internal/discovery"
	"pointy/relay/internal/limit"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/ratelimit"
	relayserver "pointy/relay/internal/relay"
	"pointy/relay/internal/security"
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
	switch args[0] {
	case "server":
		return runServer(args[1:])
	case "connector":
		return runConnector(args[1:])
	case "provision":
		return runProvision(args[1:])
	case "installations":
		return runInstallations(args[1:])
	case "subscription":
		return runSubscription(args[1:])
	case "fleet":
		return runFleet(args[1:])
	case "artifacts":
		return runArtifacts(args[1:])
	case "migrate":
		return runMigrate(args[1:])
	case "gen-token":
		return runGenToken(args[1:])
	case "version", "-v", "--version":
		fmt.Println(version)
		return nil
	case "help", "-h", "--help":
		printUsage()
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
	serperAPIKey := flags.String(
		"serper-api-key",
		envString("POINTY_RELAY_SERPER_API_KEY", ""),
		"Serper.dev API key for relay-hosted product image search; empty disables image search",
	)
	serperBaseURL := flags.String(
		"serper-base-url",
		envString("POINTY_RELAY_SERPER_BASE_URL", "https://google.serper.dev/images"),
		"Serper.dev images endpoint",
	)
	serperImageLanguage := flags.String(
		"serper-image-language",
		envString("POINTY_RELAY_SERPER_IMAGE_LANGUAGE", "ar"),
		"Serper image search language code (hl)",
	)
	serperImageCountry := flags.String(
		"serper-image-country",
		envString("POINTY_RELAY_SERPER_IMAGE_COUNTRY", "us"),
		"Serper image search country code (gl)",
	)
	imageSearchRequestTimeout := flags.Duration(
		"image-search-request-timeout",
		envDuration("POINTY_RELAY_IMAGE_SEARCH_REQUEST_TIMEOUT", 8*time.Second),
		"total timeout for a relay-hosted product image search request",
	)
	if err := flags.Parse(args); err != nil {
		return err
	}
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

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
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
	secureConnector, err := secureConnectorListener(
		connectorListener,
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
	connectorListener = secureConnector
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

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	connectorServer := relayserver.ConnectorServer{
		Store:        store,
		Hub:          hub,
		Logger:       logger,
		Metrics:      metrics,
		Presence:     presence,
		NodeID:       nodeID,
		NodeRelayURL: strings.TrimSpace(*nodeInternalURL),
		Draining:     *draining,
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
		TicketRefreshRateLimit:        ratelimit.Policy{Limit: *ticketRefreshRateLimit, Window: *rateLimitWindow},
		Metrics:                       metrics,
		Presence:                      presence,
		NodeID:                        nodeID,
		Draining:                      *draining,
		NodeProxyToken:                strings.TrimSpace(*nodeProxyToken),
		AllowInsecureNodeProxy:        *allowInsecureNodeProxy,
		Tickets:                       tickets,
		TicketTTL:                     *ticketTTL,
		TicketRefreshTTL:              *ticketRefreshTTL,
		ConnectorCertificateIssuer:    connectorCertificateIssuer,
		ConnectorCertificateTTL:       *connectorClientCertTTL,
		OpenRouterAPIKey:              strings.TrimSpace(*openRouterAPIKey),
		OpenRouterBaseURL:             strings.TrimSpace(*openRouterBaseURL),
		AIModelTiers: map[string]string{
			"fast":     strings.TrimSpace(*aiModelFast),
			"smart":    strings.TrimSpace(*aiModelSmart),
			"frontier": strings.TrimSpace(*aiModelFrontier),
		},
		AIDefaultTier:             strings.TrimSpace(*aiDefaultTier),
		AIRouterModel:             strings.TrimSpace(*aiRouterModel),
		AIVisionModel:             strings.TrimSpace(*aiVisionModel),
		AIAudioModel:              strings.TrimSpace(*aiAudioModel),
		AIWebSearchEnabled:        *aiWebSearchEnabled,
		AIWebSearchMaxResults:     *aiWebSearchMaxResults,
		AILimit5H:                 ratelimit.Policy{Limit: *aiLimit5H, Window: *aiLimit5HWindow},
		AILimitWeekly:             ratelimit.Policy{Limit: *aiLimitWeekly, Window: *aiLimitWeeklyWindow},
		AIMaxImagesPerPrompt:      *aiMaxImages,
		AIMaxRequestBytes:         *aiMaxRequestBytes,
		AIRequestTimeout:          *aiRequestTimeout,
		AIChatRateLimit:           ratelimit.Policy{Limit: *aiChatRateLimit, Window: *rateLimitWindow},
		SerperAPIKey:              strings.TrimSpace(*serperAPIKey),
		SerperBaseURL:             strings.TrimSpace(*serperBaseURL),
		SerperImageLanguage:       strings.TrimSpace(*serperImageLanguage),
		SerperImageCountry:        strings.TrimSpace(*serperImageCountry),
		ImageSearchRequestTimeout: *imageSearchRequestTimeout,
	}
	publicHTTPHandler := baseHTTPHandler
	publicHTTPHandler.RouteMode = relayserver.RouteAll
	if adminHTTPListener != nil {
		publicHTTPHandler.RouteMode = relayserver.RoutePublic
	}
	httpServer := &http.Server{
		Handler:           publicHTTPHandler,
		ReadHeaderTimeout: 5 * time.Second,
	}
	var adminHTTPServer *http.Server
	if adminHTTPListener != nil {
		adminHTTPHandler := baseHTTPHandler
		adminHTTPHandler.RouteMode = relayserver.RouteAdmin
		adminHTTPServer = &http.Server{
			Handler:           adminHTTPHandler,
			ReadHeaderTimeout: 5 * time.Second,
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

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
		if adminHTTPServer != nil {
			_ = adminHTTPServer.Shutdown(shutdownCtx)
		}
		_ = connectorListener.Close()
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
		"relay connector TCP address",
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
	if relayAddress == "" {
		return fmt.Errorf("relay connector address is required")
	}

	var tlsConfig *tls.Config
	if !*allowInsecureRelay {
		if tlsServerNameValue == "" {
			tlsServerNameValue = relayTLSServerName(relayAddress)
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
		RelayAddress:          relayAddress,
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

// requestBinary performs an authenticated admin API call and streams the
// response body into dst. Unlike requestJSON it neither caps nor buffers the
// body, so it suits large export downloads.
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
	request, err := http.NewRequest(method, endpoint.String(), nil)
	if err != nil {
		return nil, 0, err
	}
	request.Header.Set("Accept", "application/zip")
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(*a.adminToken))
	response, err := client.Do(request)
	if err != nil {
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
	n, err := io.Copy(dst, response.Body)
	if err != nil {
		return response.Header, n, err
	}
	return response.Header, n, nil
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
		{"last connector seen", formatTimeField(status.LastConnectorConnectedAt)},
		{"connector cert expires", formatTimeField(status.CertificateExpiresAt)},
	}
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

func secureConnectorListener(
	listener net.Listener,
	certFile string,
	keyFile string,
	certPEM string,
	keyPEM string,
	clientCAFile string,
	clientCAPEM string,
	allowInsecure bool,
) (net.Listener, error) {
	if allowInsecure {
		return listener, nil
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
	return tls.NewListener(listener, config), nil
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

func usageError(format string, args ...any) error {
	printUsage()
	return fmt.Errorf(format, args...)
}

func printUsage() {
	fmt.Fprintln(os.Stderr, `Usage:
  pointy-relay server [flags]
  pointy-relay connector [flags]
  pointy-relay installations <list|show|status|diagnostics|audit|provision> [args]
  pointy-relay subscription <set|update|enable|disable|extend|audit> <id> [flags]
  pointy-relay fleet <status|set-version|rollout|pause|pin|unpin|channel> [args]
  pointy-relay artifacts upload --version X --bundle pointy-onprem-X.zip
  pointy-relay provision [flags]
  pointy-relay migrate [flags]
  pointy-relay gen-token [flags]

Commands:
  server         Run relay control, remote HTTP, and connector listeners.
  connector      Run the on-prem connector beside a Pointy backend.
  installations  Fleet management over the admin API:
                   list [--query q] [--active|--inactive] [--limit n] [--json]
                   show <id> [--json]        full subscription + connector state
                   status <id> [--json]      live connector / certificate health
                   diagnostics <id> [--out f]    pull tracking/usage/error export
                   diagnostics --all [--out-dir d]   pull from every reachable shop
                   audit <id> [--json]       recent subscription change history
                   provision [--shop-name .. --relay-enabled ..]   create remotely
  subscription   Fast subscription changes over the admin API (audited):
                   set <id> --months N [--ai|--no-ai] [--remote|--no-remote]
                                             give an N-month subscription + add-ons
                   enable <id>               turn relay + subscription on
                   disable <id>              turn relay + subscription off
                   extend <id> --days N      set the end date N days out, active
                   update <id> [flags]       explicit field-by-field control
                   audit <id>                change history (alias)
  fleet          Remote on-prem update control plane (admin API):
                   status [--query q] [--json]   versions across the fleet
                   set-version <v> [--channel stable] [--rollout canary|all|N%]
                   rollout <canary|all|N%> [--channel]   advance the rollout
                   pause [--channel]         kill switch: stop the rollout
                   pin <id> <v> / unpin <id> / channel <id> <channel>
  artifacts      upload --version X --bundle pointy-onprem-X.zip   serve a bundle
  provision      Create an installation directly against the database (host-side).
  migrate        Apply relay PostgreSQL migrations.
  gen-token      Print a strong random admin token for POINTY_RELAY_ADMIN_TOKEN.
  version        Print the build version.

Admin API commands read POINTY_RELAY_CONTROL_URL and POINTY_RELAY_ADMIN_TOKEN
from the environment; export them once for terse, repeatable management.

Deployment profiles (server --platform / POINTY_RELAY_PLATFORM):
  paas          Single public endpoint behind a TLS-terminating load balancer,
                bearer-token admin, auto-bind 0.0.0.0, edge TLS, auto-migrate.
                Requires a strong POINTY_RELAY_ADMIN_TOKEN.
  (empty)       Self-hosted private-network deployment (set --production to
                enforce split admin listener + mTLS).`)
}
