package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

	"pointy/relay/internal/connector"
	"pointy/relay/internal/control"
	relayserver "pointy/relay/internal/relay"
)

const (
	defaultRelayDatabaseURL = "postgres://postgres:postgres@127.0.0.1:5432/pointy?sslmode=disable"
	defaultRelayRedisURL    = "redis://127.0.0.1:6379/0"
	relayRedisKeyPrefix     = "pointy:relay"
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
		"HTTP address for control and remote client traffic",
	)
	connectorAddr := flags.String(
		"connector",
		envString("POINTY_RELAY_CONNECTOR_ADDR", "127.0.0.1:8092"),
		"TCP address for on-prem connector tunnels",
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
	ticketTTL := flags.Duration(
		"ticket-ttl",
		envDuration("POINTY_RELAY_TICKET_TTL", 15*time.Minute),
		"short-lived relay ticket TTL",
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
	if err := flags.Parse(args); err != nil {
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

	store := control.InstallationStore(postgresStore)
	var presence relayserver.ConnectorPresence
	var tickets control.RelayTicketService
	if redisClient != nil {
		store = control.NewCachedInstallationStore(
			postgresStore,
			control.NewRedisInstallationCache(redisClient, relayRedisKeyPrefix),
			control.RealClock{},
			30*time.Second,
		)
		presence = relayserver.NewRedisConnectorPresence(redisClient, relayRedisKeyPrefix)
		tickets = control.NewRedisRelayTicketService(redisClient, relayRedisKeyPrefix, control.RealClock{})
	}

	nodeID := strings.TrimSpace(*nodeIDFlag)
	if nodeID == "" {
		nodeID, err = relayserver.NewNodeID()
		if err != nil {
			return err
		}
	}
	hub := relayserver.NewHub()

	connectorListener, err := net.Listen("tcp", *connectorAddr)
	if err != nil {
		return err
	}
	httpListener, err := net.Listen("tcp", *httpAddr)
	if err != nil {
		_ = connectorListener.Close()
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	connectorServer := relayserver.ConnectorServer{
		Store:    store,
		Hub:      hub,
		Logger:   logger,
		Presence: presence,
		NodeID:   nodeID,
	}
	httpServer := &http.Server{
		Handler: relayserver.HTTPServer{
			Store:          store,
			Hub:            hub,
			Logger:         logger,
			AdminToken:     *adminToken,
			AllowOpenAdmin: *allowOpenAdmin,
			Presence:       presence,
			NodeID:         nodeID,
			Tickets:        tickets,
			TicketTTL:      *ticketTTL,
		},
		ReadHeaderTimeout: 5 * time.Second,
	}

	errs := make(chan error, 2)
	go func() {
		logger.Info("relay connector listener started", "addr", connectorListener.Addr().String())
		errs <- connectorServer.Serve(ctx, connectorListener)
	}()
	go func() {
		logger.Info("relay HTTP listener started", "addr", httpListener.Addr().String())
		if err := httpServer.Serve(httpListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- err
			return
		}
		errs <- nil
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
		_ = connectorListener.Close()
		return nil
	case err := <-errs:
		if err != nil {
			return err
		}
		return nil
	}
}

func runConnector(args []string) error {
	flags := flag.NewFlagSet("connector", flag.ExitOnError)
	relayAddr := flags.String(
		"relay",
		envString("POINTY_RELAY_CONNECTOR_ADDR", "127.0.0.1:8092"),
		"relay connector TCP address",
	)
	token := flags.String(
		"token",
		envString("POINTY_RELAY_CONNECTOR_TOKEN", ""),
		"connector token generated for this on-prem installation",
	)
	backendRaw := flags.String(
		"backend",
		envString("POINTY_RELAY_BACKEND_URL", "http://127.0.0.1:8000"),
		"local Pointy backend origin",
	)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*token) == "" {
		return fmt.Errorf("connector token is required")
	}
	backendURL, err := parseOrigin(*backendRaw)
	if err != nil {
		return err
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return connector.Client{
		RelayAddress: *relayAddr,
		Token:        *token,
		BackendURL:   backendURL,
		Logger:       logger,
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
	relayEnabled := flags.Bool("relay-enabled", true, "enable remote relay access")
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
		RelayEnabled:       relayEnabled,
		AIEnabled:          *aiEnabled,
		SubscriptionEndsAt: endsAt,
	})
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(provisioned)
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

func usageError(format string, args ...any) error {
	printUsage()
	return fmt.Errorf(format, args...)
}

func printUsage() {
	fmt.Fprintln(os.Stderr, `Usage:
  pointy-relay server [flags]
  pointy-relay connector [flags]
  pointy-relay provision [flags]
  pointy-relay migrate [flags]

Commands:
  server     Run relay control, remote HTTP, and connector listeners.
  connector  Run the on-prem connector beside a Pointy backend.
  provision  Create an installation with connector and access tokens.
  migrate    Apply relay PostgreSQL migrations.`)
}
