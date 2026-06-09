package main

import (
	"bytes"
	"context"
	"crypto/tls"
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
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

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

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "pointy-relay: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
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
	case "subscription":
		return runSubscription(args[1:])
	case "migrate":
		return runMigrate(args[1:])
	case "help", "-h", "--help":
		printUsage()
		return nil
	default:
		return usageError("unknown command %q", args[0])
	}
}

func runServer(args []string) error {
	flags := flag.NewFlagSet("server", flag.ExitOnError)
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
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := validateServerSecurityConfig(serverSecurityConfig{
		Production:             *production,
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
	setupCtx, setupCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer setupCancel()

	postgresStore, err := control.NewPostgresStore(setupCtx, *databaseURL, control.RealClock{})
	if err != nil {
		return err
	}
	defer postgresStore.Close()

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
	baseHTTPHandler := relayserver.HTTPServer{
		Store:                         store,
		Hub:                           hub,
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
		return usageError("missing subscription command")
	}
	switch args[0] {
	case "update":
		return runSubscriptionUpdate(args[1:])
	default:
		return usageError("unknown subscription command %q", args[0])
	}
}

func runSubscriptionUpdate(args []string) error {
	flags := flag.NewFlagSet("subscription update", flag.ExitOnError)
	controlURL := flags.String(
		"control-url",
		envString("POINTY_RELAY_CONTROL_URL", "http://127.0.0.1:8091"),
		"relay admin control URL",
	)
	adminToken := flags.String(
		"admin-token",
		envString("POINTY_RELAY_ADMIN_TOKEN", ""),
		"relay admin bearer token",
	)
	allowInsecureControl := flags.Bool(
		"allow-insecure-control",
		envBool("POINTY_RELAY_ALLOW_INSECURE_CONTROL", false),
		"allow cleartext relay admin control URL for local development",
	)
	controlCA := flags.String(
		"control-ca",
		envString("POINTY_RELAY_CONTROL_CA_FILE", ""),
		"CA bundle for relay admin control TLS",
	)
	controlClientCert := flags.String(
		"control-client-cert",
		envString("POINTY_RELAY_CONTROL_CLIENT_CERT_FILE", ""),
		"client certificate for relay admin control mTLS",
	)
	controlClientKey := flags.String(
		"control-client-key",
		envString("POINTY_RELAY_CONTROL_CLIENT_KEY_FILE", ""),
		"client key for relay admin control mTLS",
	)
	controlTLSServerName := flags.String(
		"control-tls-server-name",
		envString("POINTY_RELAY_CONTROL_TLS_SERVER_NAME", ""),
		"expected relay admin control TLS server name",
	)
	installationID := flags.String("installation-id", "", "installation id to update")
	actor := flags.String("actor", "", "company operator or automation id")
	reason := flags.String("reason", "", "audit reason for the subscription change")
	relayEnabled := flags.String("relay-enabled", "", "optional true/false relay entitlement")
	subscriptionActive := flags.String("subscription-active", "", "optional true/false subscription state")
	aiEnabled := flags.String("ai-enabled", "", "optional true/false AI entitlement")
	subscriptionEndsAt := flags.String("subscription-ends-at", "", "optional RFC3339 subscription end time")
	clearEnd := flags.Bool("clear-subscription-end", false, "clear subscription end time")
	if err := flags.Parse(args); err != nil {
		return err
	}

	body, err := subscriptionUpdateBody(subscriptionUpdateOptions{
		InstallationID:       *installationID,
		Actor:                *actor,
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
	endpoint, err := relayAdminEndpoint(*controlURL, "/v1/installations/"+url.PathEscape(strings.TrimSpace(*installationID))+"/subscription")
	if err != nil {
		return err
	}
	client, err := newRelayAdminHTTPClient(relayAdminHTTPClientOptions{
		ControlURL:     *controlURL,
		AllowInsecure:  *allowInsecureControl,
		CAFile:         *controlCA,
		ClientCertFile: *controlClientCert,
		ClientKeyFile:  *controlClientKey,
		TLSServerName:  *controlTLSServerName,
	})
	if err != nil {
		return err
	}
	content, err := json.Marshal(body)
	if err != nil {
		return err
	}
	request, err := http.NewRequest(http.MethodPatch, endpoint.String(), bytes.NewReader(content))
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json")
	if strings.TrimSpace(*adminToken) == "" {
		return fmt.Errorf("admin token is required")
	}
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(*adminToken))
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		detail, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf(
			"subscription update returned %d: %s",
			response.StatusCode,
			strings.TrimSpace(string(detail)),
		)
	}
	var payload any
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&payload); err != nil {
		return fmt.Errorf("subscription update returned invalid JSON: %w", err)
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(payload)
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
	body := strings.NewReader(`{"version":"pointy-relay"}`)
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
  pointy-relay provision [flags]
  pointy-relay subscription update [flags]
  pointy-relay migrate [flags]

Commands:
  server        Run relay control, remote HTTP, and connector listeners.
  connector     Run the on-prem connector beside a Pointy backend.
  provision     Create an installation with connector and access tokens.
  subscription  Manage company-owned relay subscription state.
  migrate       Apply relay PostgreSQL migrations.`)
}
