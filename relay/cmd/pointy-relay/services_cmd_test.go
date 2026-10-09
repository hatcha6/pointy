package main

import (
	"context"
	"io"
	"log/slog"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/control"
	relayserver "pointy/relay/internal/relay"
	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/services"
)

// servicesRelay is a real relay server selling services from the fixture in test
// mode, and the environment the CLI reads to reach it.
func servicesRelay(t *testing.T) (*control.FileStore, *services.Service) {
	t.Helper()
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	service := services.New(services.Config{
		Source:   services.FixtureSource{},
		TestMode: true,
		Logger:   slog.New(slog.NewTextHandler(io.Discard, nil)),
		Now:      func() time.Time { return time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC) },
	})
	relay := httptest.NewServer(relayserver.HTTPServer{
		Store:                store,
		Hub:                  relayserver.NewHub(),
		Logger:               slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken:           "admin-token",
		Vouchers:             relayserver.VoucherConfig{TestMode: true},
		VoucherSettingsCache: &relayserver.VoucherSettingsCache{},
		Services:             service,
	})
	t.Cleanup(relay.Close)
	t.Setenv("POINTY_RELAY_CONTROL_URL", relay.URL)
	t.Setenv("POINTY_RELAY_ADMIN_TOKEN", "admin-token")
	t.Setenv("POINTY_RELAY_ALLOW_INSECURE_CONTROL", "true")
	return store, service
}

func TestServicesCommandsShowTheDirectoryAQuoteAndTheState(t *testing.T) {
	servicesRelay(t)
	if _, err := captureStdout(t, func() error { return runVoucherSettingsSet([]string{"--usd-rate", "9.71"}) }); err != nil {
		t.Fatal(err)
	}

	out, err := captureStdout(t, func() error { return runServicesDirectory([]string{"--country", "ml,sd"}) })
	if err != nil {
		t.Fatalf("directory: %v\n%s", err, out)
	}
	for _, want := range []string{
		"TEST MODE", "priced", "ML  ", "Mali", "+223", "XOF", "Orange Mali", "289", "range", "1967..32800 XOF",
		"5000 XOF", "Canal+ Mali", "No service: SD",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("the directory output should contain %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "Niger") && !strings.Contains(out, "No service") {
		t.Errorf("the filter keeps only Mali:\n%s", out)
	}

	raw, err := captureStdout(t, func() error { return runServicesDirectory([]string{"--country", "ML", "--json"}) })
	if err != nil || !strings.Contains(raw, `"directory"`) || !strings.Contains(raw, `"version"`) {
		t.Fatalf("directory --json: %v\n%s", err, raw)
	}

	out, err = captureStdout(t, func() error {
		return runServicesQuote([]string{"--kind", "airtime", "--operator", "289", "--amount", "5000"})
	})
	if err != nil {
		t.Fatalf("quote: %v\n%s", err, out)
	}
	for _, want := range []string{"5,000 فرنك أفريقي", "the shop pays", "the customer is asked", "it costs the company", "in dollars, keeping Reloadly's commission", "9.9505 USD"} {
		if !strings.Contains(out, want) {
			t.Errorf("the quote output should contain %q:\n%s", want, out)
		}
	}
	// Local mode says so.
	if _, err := captureStdout(t, func() error { return runVoucherSettingsSet([]string{"--airtime-order-mode", "local"}) }); err != nil {
		t.Fatal(err)
	}
	out, err = captureStdout(t, func() error {
		return runServicesQuote([]string{"--kind", "airtime", "--operator", "289", "--amount", "5000", "--currency", "xof"})
	})
	if err != nil || !strings.Contains(out, "in the local currency, no commission") || !strings.Contains(out, "5000 XOF") {
		t.Fatalf("local quote: %v\n%s", err, out)
	}
	// A refusal is reported with the relay's code.
	if _, err := captureStdout(t, func() error {
		return runServicesQuote([]string{"--kind", "airtime", "--operator", "289", "--amount", "50"})
	}); err == nil || !strings.Contains(err.Error(), "amount_out_of_range") {
		t.Fatalf("an amount out of range: %v", err)
	}
	if err := runServicesQuote([]string{"--kind", "airtime"}); err == nil {
		t.Fatal("a quote needs an operator and an amount")
	}

	out, err = captureStdout(t, func() error { return runServicesNames([]string{"--missing"}) })
	if err != nil {
		t.Fatalf("names: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Every name in the directory has an Arabic spelling.") && !strings.Contains(out, "names_ar.json") {
		t.Fatalf("names output:\n%s", out)
	}
	if err := runServicesNames(nil); err == nil {
		t.Fatal("names needs --missing")
	}

	out, err = captureStdout(t, func() error { return runServicesStatus(nil) })
	if err != nil || !strings.Contains(out, "configured: true") || !strings.Contains(out, "test mode: true") || !strings.Contains(out, "operators:") {
		t.Fatalf("status: %v\n%s", err, out)
	}

	// There is no Reloadly behind a test-mode fixture: the balance says so.
	if _, err := captureStdout(t, func() error { return runServicesBalance(nil) }); err == nil || !strings.Contains(err.Error(), "Reloadly is not configured") {
		t.Fatalf("balance without Reloadly: %v", err)
	}
	if err := runServices(nil); err == nil {
		t.Fatal("a command is required")
	}
	if err := runServices([]string{"nope"}); err == nil {
		t.Fatal("an unknown command is refused")
	}
}

func TestSettingsSetTakesTheOrderModes(t *testing.T) {
	store, _ := servicesRelay(t)
	out, err := captureStdout(t, func() error {
		return runVoucherSettingsSet([]string{"--usd-rate", "9.71", "--airtime-order-mode", "local", "--airtime-usd-buffer", "1", "--bills-order-mode", "local"})
	})
	if err != nil {
		t.Fatalf("set: %v\n%s", err, out)
	}
	settings, _ := currentSettings(t, store)
	if settings.Airtime.OrderMode != "local" || settings.Airtime.USDBufferPercent != "1" || settings.Bills.OrderMode != "local" {
		t.Fatalf("published: %+v", settings)
	}
	for _, want := range []string{"airtime.order_mode", "airtime.usd_buffer_percent", "bills.order_mode", "local"} {
		if !strings.Contains(out, want) {
			t.Errorf("the output should show %q:\n%s", want, out)
		}
	}
	// A mode the kind does not take is refused, and nothing is published.
	before := versions(t, store)
	if _, err := captureStdout(t, func() error { return runVoucherSettingsSet([]string{"--airtime-order-mode", "auto"}) }); err == nil {
		t.Fatal("auto is a bills mode")
	}
	if _, err := captureStdout(t, func() error { return runVoucherSettingsSet([]string{"--bills-usd-buffer", "30"}) }); err == nil {
		t.Fatal("a 30 % buffer is a surcharge")
	}
	if versions(t, store) != before {
		t.Fatal("a refused set published something")
	}
	// A blank value is the default again.
	if _, err := captureStdout(t, func() error { return runVoucherSettingsSet([]string{"--airtime-order-mode", ""}) }); err != nil {
		t.Fatal(err)
	}
	settings, _ = currentSettings(t, store)
	if settings.Airtime.OrderMode != "usd" {
		t.Fatalf("blank is the default: %+v", settings.Airtime)
	}
}

// shrinkingSource is the fixture, which can be told to list far less.
type shrinkingSource struct {
	mu     sync.Mutex
	shrunk bool
}

func (s *shrinkingSource) Load(ctx context.Context) (services.Raw, error) {
	raw, err := services.FixtureSource{}.Load(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	if err == nil && s.shrunk {
		raw.Operators = raw.Operators[:len(raw.Operators)/10]
	}
	return raw, err
}

func (s *shrinkingSource) shrink(shrunk bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.shrunk = shrunk
}

func TestServicesStatusTellsStaleRejectedAndSandbox(t *testing.T) {
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	clock := func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		return now
	}
	source := &shrinkingSource{}
	service := services.New(services.Config{
		Source: source, Reloadly: services.NewTestExecutor(), Sandbox: true, Interval: 15 * time.Minute,
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)), Now: clock,
	})
	relay := httptest.NewServer(relayserver.HTTPServer{
		Store: store, Hub: relayserver.NewHub(), Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token", VoucherSettingsCache: &relayserver.VoucherSettingsCache{}, Services: service,
	})
	t.Cleanup(relay.Close)
	t.Setenv("POINTY_RELAY_CONTROL_URL", relay.URL)
	t.Setenv("POINTY_RELAY_ADMIN_TOKEN", "admin-token")
	t.Setenv("POINTY_RELAY_ALLOW_INSECURE_CONTROL", "true")
	if _, err := captureStdout(t, func() error { return runVoucherSettingsSet([]string{"--usd-rate", "9.71"}) }); err != nil {
		t.Fatal(err)
	}

	out, err := captureStdout(t, func() error { return runServicesDirectory([]string{"--country", "ML"}) })
	if err != nil || !strings.Contains(out, "SANDBOX") || strings.Contains(out, "TEST MODE") {
		t.Fatalf("a sandbox is not the fake supplier: %v\n%s", err, out)
	}
	out, err = captureStdout(t, func() error { return runServicesStatus(nil) })
	if err != nil || !strings.Contains(out, "sandbox: true") || strings.Contains(out, "STALE") || strings.Contains(out, "REJECTED") {
		t.Fatalf("status: %v\n%s", err, out)
	}

	// An hour with no reading: stale.
	mu.Lock()
	now = now.Add(time.Hour)
	mu.Unlock()
	out, err = captureStdout(t, func() error { return runServicesStatus(nil) })
	if err != nil || !strings.Contains(out, "STALE") || !strings.Contains(out, "45m0s") {
		t.Fatalf("stale: %v\n%s", err, out)
	}

	// A reading that lists a tenth of the operators is not believed.
	source.shrink(true)
	if _, err := captureStdout(t, func() error { return runServicesDirectory([]string{"--refresh", "--country", "ML"}) }); err != nil {
		t.Fatal(err)
	}
	out, err = captureStdout(t, func() error { return runServicesStatus(nil) })
	if err != nil || !strings.Contains(out, "LAST READING REJECTED") || !strings.Contains(out, "--refresh --accept") || !strings.Contains(out, "STALE") {
		t.Fatalf("rejected: %v\n%s", err, out)
	}
	// The operator says it is real.
	if err := runServicesDirectory([]string{"--accept"}); err == nil {
		t.Fatal("--accept goes with --refresh")
	}
	if _, err := captureStdout(t, func() error { return runServicesDirectory([]string{"--refresh", "--accept", "--country", "ML"}) }); err != nil {
		t.Fatal(err)
	}
	out, err = captureStdout(t, func() error { return runServicesStatus(nil) })
	if err != nil || strings.Contains(out, "REJECTED") || strings.Contains(out, "STALE") {
		t.Fatalf("accepted: %v\n%s", err, out)
	}
}

func TestTheServicesAreSandboxedWhenReloadlyIs(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	sandboxed, err := reloadly.New(reloadly.Config{ClientID: "id", ClientSecret: "secret", Sandbox: true})
	if err != nil {
		t.Fatal(err)
	}
	live, err := reloadly.New(reloadly.Config{ClientID: "id", ClientSecret: "secret"})
	if err != nil {
		t.Fatal(err)
	}
	service := buildServices(relayserver.VoucherConfig{Reloadly: sandboxed}, servicesSettings{}, logger)
	if !service.Sandbox() || service.TestMode() || !service.TestOrSandbox() || service.Supplier() != services.SupplierReloadly {
		t.Fatalf("sandbox %v test %v supplier %s", service.Sandbox(), service.TestMode(), service.Supplier())
	}
	service = buildServices(relayserver.VoucherConfig{Reloadly: live}, servicesSettings{}, logger)
	if service.Sandbox() || service.TestOrSandbox() {
		t.Fatal("live is live")
	}
	service = buildServices(relayserver.VoucherConfig{TestMode: true}, servicesSettings{}, logger)
	if service.Sandbox() || !service.TestMode() || !service.TestOrSandbox() {
		t.Fatal("test mode is test mode")
	}
}

func TestTheTargetKeyComesFromTheAdminTokenAndIsNotIt(t *testing.T) {
	key := deriveServicesTargetKey("a-long-admin-token")
	if len(key) != 32 || string(key) == "a-long-admin-token" {
		t.Fatalf("key: %x", key)
	}
	// Every instance holding the admin token derives the same key, whatever
	// whitespace the environment put around it.
	if string(deriveServicesTargetKey("  a-long-admin-token\n")) != string(key) || string(deriveServicesTargetKey("a-long-admin-token")) != string(key) {
		t.Fatal("stable")
	}
	if string(deriveServicesTargetKey("another-admin-token")) == string(key) {
		t.Fatal("another token, another key")
	}
	// It is a value of its own: not the node-to-node secret derived from the same token.
	if nodeProxy := deriveNodeProxyToken("a-long-admin-token"); strings.Contains(nodeProxy, string(key)) || nodeProxy == string(key) {
		t.Fatal("distinct from the node proxy token")
	}
	// The services are built with it.
	service := buildServices(relayserver.VoucherConfig{TestMode: true}, servicesSettings{TargetKey: key}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if service == nil {
		t.Fatal("services")
	}
}
