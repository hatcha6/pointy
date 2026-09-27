package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
)

func TestBackendConnectorConfigEndpointDefaultsToRelayPath(t *testing.T) {
	backendURL, err := parseOrigin("http://127.0.0.1:8000/base/")
	if err != nil {
		t.Fatal(err)
	}

	endpoint, err := backendConnectorConfigEndpoint(backendURL, "")
	if err != nil {
		t.Fatal(err)
	}

	if endpoint.String() != "http://127.0.0.1:8000/base/api/relay/connector-config/" {
		t.Fatalf("unexpected endpoint %q", endpoint.String())
	}
}

func TestFetchBackendConnectorConfigUsesSetupToken(t *testing.T) {
	originalClientFactory := newBackendConnectorHTTPClient
	defer func() {
		newBackendConnectorHTTPClient = originalClientFactory
	}()
	newBackendConnectorHTTPClient = func() *http.Client {
		return &http.Client{
			Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if r.Method != http.MethodPost {
					t.Fatalf("expected POST, got %s", r.Method)
				}
				if r.URL.String() != "http://pointy.test/api/relay/connector-config/" {
					t.Fatalf("unexpected URL %q", r.URL.String())
				}
				if got := r.Header.Get("X-Pointy-Connector-Setup-Token"); got != "setup-secret" {
					t.Fatalf("unexpected setup token %q", got)
				}
				if got := r.Header.Get("X-Pointy-Connector-Token"); got != "" {
					t.Fatalf("unexpected connector token %q", got)
				}
				content, err := json.Marshal(map[string]string{
					"installation_id":              "installation-1",
					"shop_name":                    "متجر الاختبار",
					"relay_connector_address":      "relay.example:443",
					"connector_token":              "ptc1.installation-1.secret",
					"tls_server_name":              "relay.example",
					"connector_certificate_pem":    "cert",
					"connector_ca_certificate_pem": "ca",
				})
				if err != nil {
					return nil, err
				}
				return &http.Response{
					StatusCode: http.StatusOK,
					Body:       io.NopCloser(strings.NewReader(string(content))),
					Header:     http.Header{"Content-Type": []string{"application/json"}},
				}, nil
			}),
		}
	}
	backendURL, err := parseOrigin("http://pointy.test")
	if err != nil {
		t.Fatal(err)
	}

	config, err := fetchBackendConnectorConfig(
		context.Background(),
		backendURL,
		"",
		"setup-secret",
		"",
		"csr",
	)
	if err != nil {
		t.Fatal(err)
	}

	if config.ConnectorToken != "ptc1.installation-1.secret" {
		t.Fatalf("unexpected connector token %q", config.ConnectorToken)
	}
	if config.RelayConnectorAddress != "relay.example:443" {
		t.Fatalf("unexpected relay connector address %q", config.RelayConnectorAddress)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func TestFetchBackendConnectorConfigRequiresSetupToken(t *testing.T) {
	backendURL, err := parseOrigin("http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}

	if _, err := fetchBackendConnectorConfig(context.Background(), backendURL, "", "", "", ""); err == nil {
		t.Fatal("expected connector credential requirement")
	}
}

func TestFetchBackendConnectorConfigHandlesBootstrapHTTPError(t *testing.T) {
	originalClientFactory := newBackendConnectorHTTPClient
	defer func() {
		newBackendConnectorHTTPClient = originalClientFactory
	}()
	newBackendConnectorHTTPClient = func() *http.Client {
		return &http.Client{
			Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				return &http.Response{
					StatusCode: http.StatusForbidden,
					Body:       io.NopCloser(strings.NewReader(`{"detail":"rejected"}`)),
					Header:     http.Header{"Content-Type": []string{"application/json"}},
				}, nil
			}),
		}
	}
	backendURL, err := parseOrigin("http://pointy.test")
	if err != nil {
		t.Fatal(err)
	}

	if _, err := fetchBackendConnectorConfig(context.Background(), backendURL, "", "setup-secret", "", ""); err == nil {
		t.Fatal("expected backend bootstrap HTTP error")
	}
}

func TestFetchBackendConnectorConfigCanUseConnectorTokenForRenewal(t *testing.T) {
	originalClientFactory := newBackendConnectorHTTPClient
	defer func() {
		newBackendConnectorHTTPClient = originalClientFactory
	}()
	newBackendConnectorHTTPClient = func() *http.Client {
		return &http.Client{
			Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if got := r.Header.Get("X-Pointy-Connector-Setup-Token"); got != "" {
					t.Fatalf("unexpected setup token %q", got)
				}
				if got := r.Header.Get("X-Pointy-Connector-Token"); got != "ptc1.installation-1.secret" {
					t.Fatalf("unexpected connector token %q", got)
				}
				content, err := json.Marshal(map[string]string{
					"installation_id":              "installation-1",
					"relay_connector_address":      "relay.example:443",
					"connector_token":              "ptc1.installation-1.secret",
					"connector_certificate_pem":    "cert",
					"connector_ca_certificate_pem": "ca",
				})
				if err != nil {
					return nil, err
				}
				return &http.Response{
					StatusCode: http.StatusOK,
					Body:       io.NopCloser(strings.NewReader(string(content))),
					Header:     http.Header{"Content-Type": []string{"application/json"}},
				}, nil
			}),
		}
	}
	backendURL, err := parseOrigin("http://pointy.test")
	if err != nil {
		t.Fatal(err)
	}

	config, err := fetchBackendConnectorConfig(
		context.Background(),
		backendURL,
		"",
		"",
		"ptc1.installation-1.secret",
		"csr",
	)
	if err != nil {
		t.Fatal(err)
	}
	if config.ConnectorCertificatePEM != "cert" {
		t.Fatalf("unexpected renewed certificate %q", config.ConnectorCertificatePEM)
	}
}

func TestValidateServerSecurityConfigAllowsDevelopmentDefaults(t *testing.T) {
	if err := validateServerSecurityConfig(serverSecurityConfig{
		AllowOpenAdmin:         true,
		AllowInsecureHTTP:      true,
		AllowInsecureConnector: true,
		AllowInsecureNodeProxy: true,
	}); err != nil {
		t.Fatalf("development config should allow explicit insecure settings: %v", err)
	}
}

func TestValidateServerSecurityConfigAcceptsProductionConfig(t *testing.T) {
	config := validProductionServerSecurityConfig()

	if err := validateServerSecurityConfig(config); err != nil {
		t.Fatalf("valid production config rejected: %v", err)
	}
}

func TestValidateServerSecurityConfigAcceptsProductionAutoTLS(t *testing.T) {
	config := validProductionServerSecurityConfig()
	config.AutoTLS = true
	config.HTTPTLSCert = ""
	config.HTTPTLSKey = ""
	config.HTTPTLSServerName = "relay.example.com"
	config.HTTPAddr = "0.0.0.0:443"
	config.ConnectorTLSCert = ""
	config.ConnectorTLSKey = ""
	config.ConnectorTLSServerName = "relay.example.com"
	config.ConnectorAddr = "0.0.0.0:8092"
	config.ConnectorClientCA = ""
	config.ConnectorClientCAKey = ""

	if err := validateServerSecurityConfig(config); err != nil {
		t.Fatalf("valid production auto-TLS config rejected: %v", err)
	}
}

func TestValidateServerSecurityConfigRejectsUnsafeProductionConfig(t *testing.T) {
	for _, tt := range []struct {
		name    string
		mutate  func(*serverSecurityConfig)
		message string
	}{
		{
			name:    "missing admin listener",
			mutate:  func(config *serverSecurityConfig) { config.AdminHTTPAddr = "" },
			message: "admin HTTP listener",
		},
		{
			name:    "open admin",
			mutate:  func(config *serverSecurityConfig) { config.AllowOpenAdmin = true },
			message: "open admin",
		},
		{
			name:    "missing admin token",
			mutate:  func(config *serverSecurityConfig) { config.AdminToken = "" },
			message: "admin token",
		},
		{
			name:    "insecure HTTP",
			mutate:  func(config *serverSecurityConfig) { config.AllowInsecureHTTP = true },
			message: "cleartext HTTP",
		},
		{
			name:    "missing HTTP TLS",
			mutate:  func(config *serverSecurityConfig) { config.HTTPTLSCert = "" },
			message: "HTTP TLS",
		},
		{
			name:    "admin client certs disabled",
			mutate:  func(config *serverSecurityConfig) { config.RequireAdminClientCert = false },
			message: "admin client certificates",
		},
		{
			name:    "missing admin client CA",
			mutate:  func(config *serverSecurityConfig) { config.HTTPClientCA = "" },
			message: "admin HTTP client CA",
		},
		{
			name:    "insecure connector",
			mutate:  func(config *serverSecurityConfig) { config.AllowInsecureConnector = true },
			message: "cleartext connector",
		},
		{
			name:    "missing connector mTLS",
			mutate:  func(config *serverSecurityConfig) { config.ConnectorClientCA = "" },
			message: "connector client CA",
		},
		{
			name:    "missing connector issuer key",
			mutate:  func(config *serverSecurityConfig) { config.ConnectorClientCAKey = "" },
			message: "connector client CA",
		},
		{
			name:    "insecure node proxy",
			mutate:  func(config *serverSecurityConfig) { config.AllowInsecureNodeProxy = true },
			message: "insecure node proxy",
		},
		{
			name: "node internal URL without proxy token",
			mutate: func(config *serverSecurityConfig) {
				config.NodeInternalURL = "https://relay-node-a.internal"
				config.NodeProxyToken = ""
			},
			message: "node proxy token",
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			config := validProductionServerSecurityConfig()
			tt.mutate(&config)

			err := validateServerSecurityConfig(config)
			if err == nil {
				t.Fatal("expected unsafe production config rejection")
			}
			if !strings.Contains(err.Error(), tt.message) {
				t.Fatalf("expected error containing %q, got %v", tt.message, err)
			}
		})
	}
}

func TestValidateServerSecurityConfigRejectsProductionAutoTLSWithoutServerName(t *testing.T) {
	config := validProductionServerSecurityConfig()
	config.AutoTLS = true
	config.HTTPTLSCert = ""
	config.HTTPTLSKey = ""
	config.HTTPAddr = "0.0.0.0:443"
	config.HTTPTLSServerName = ""
	config.ConnectorTLSCert = ""
	config.ConnectorTLSKey = ""
	config.ConnectorAddr = "0.0.0.0:8092"
	config.ConnectorTLSServerName = ""
	config.ConnectorClientCA = ""
	config.ConnectorClientCAKey = ""

	err := validateServerSecurityConfig(config)
	if err == nil {
		t.Fatal("expected unsafe auto-TLS config rejection")
	}
	if !strings.Contains(err.Error(), "server name") {
		t.Fatalf("expected server name error, got %v", err)
	}
}

func TestValidateServerSecurityConfigAcceptsPaaSProfile(t *testing.T) {
	if err := validateServerSecurityConfig(validPaaSServerSecurityConfig()); err != nil {
		t.Fatalf("valid paas config rejected: %v", err)
	}
}

func TestValidateServerSecurityConfigRejectsUnsafePaaSConfig(t *testing.T) {
	for _, tt := range []struct {
		name    string
		mutate  func(*serverSecurityConfig)
		message string
	}{
		{
			name:    "empty admin token",
			mutate:  func(config *serverSecurityConfig) { config.AdminToken = "" },
			message: "admin token is required",
		},
		{
			name:    "weak admin token",
			mutate:  func(config *serverSecurityConfig) { config.AdminToken = "local-admin" },
			message: "well-known development value",
		},
		{
			name:    "short admin token",
			mutate:  func(config *serverSecurityConfig) { config.AdminToken = "abc123" },
			message: "at least 24 characters",
		},
		{
			name:    "open admin",
			mutate:  func(config *serverSecurityConfig) { config.AllowOpenAdmin = true },
			message: "open admin",
		},
		{
			name:    "separate admin listener",
			mutate:  func(config *serverSecurityConfig) { config.AdminHTTPAddr = "127.0.0.1:8093" },
			message: "single public endpoint",
		},
		{
			name:    "admin client certs required",
			mutate:  func(config *serverSecurityConfig) { config.RequireAdminClientCert = true },
			message: "bearer token",
		},
		{
			name:    "insecure connector",
			mutate:  func(config *serverSecurityConfig) { config.AllowInsecureConnector = true },
			message: "end-to-end mTLS",
		},
		{
			name:    "auto-TLS connector without server name on wildcard bind",
			mutate:  func(config *serverSecurityConfig) { config.ConnectorTLSServerName = "" },
			message: "connector TLS server name",
		},
		{
			name: "node internal URL without proxy token",
			mutate: func(config *serverSecurityConfig) {
				config.NodeInternalURL = "https://relay-node-a.internal"
				config.NodeProxyToken = ""
			},
			message: "node proxy token",
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			config := validPaaSServerSecurityConfig()
			tt.mutate(&config)

			err := validateServerSecurityConfig(config)
			if err == nil {
				t.Fatal("expected unsafe paas config rejection")
			}
			if !strings.Contains(err.Error(), tt.message) {
				t.Fatalf("expected error containing %q, got %v", tt.message, err)
			}
		})
	}
}

func TestValidateStrongAdminToken(t *testing.T) {
	if err := validateStrongAdminToken("ZkQk9b2c5f8a1d4e7g0h3j6k9m2n5p8q"); err != nil {
		t.Fatalf("strong token rejected: %v", err)
	}
	for _, tt := range []struct {
		name  string
		token string
	}{
		{name: "empty", token: "   "},
		{name: "weak", token: "ChangeMe"},
		{name: "short", token: "tooshort"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if err := validateStrongAdminToken(tt.token); err == nil {
				t.Fatalf("expected %s token rejection", tt.name)
			}
		})
	}
}

func TestGenerateAdminTokenProducesDistinctStrongTokens(t *testing.T) {
	first, err := generateAdminToken(32)
	if err != nil {
		t.Fatal(err)
	}
	second, err := generateAdminToken(32)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("generated admin tokens must be unique")
	}
	if len(first) != 64 {
		t.Fatalf("expected 64 hex characters, got %d", len(first))
	}
	if err := validateStrongAdminToken(first); err != nil {
		t.Fatalf("generated token failed the strong-token gate: %v", err)
	}
	if _, err := generateAdminToken(8); err == nil {
		t.Fatal("expected rejection of an undersized token request")
	}
}

func TestResolveActorPrefersFlagThenEnv(t *testing.T) {
	t.Setenv("POINTY_RELAY_OPERATOR", "ops-team")
	t.Setenv("USER", "hatem")
	if got := resolveActor("explicit"); got != "explicit" {
		t.Fatalf("flag should win, got %q", got)
	}
	if got := resolveActor(""); got != "ops-team" {
		t.Fatalf("env operator should win, got %q", got)
	}
	t.Setenv("POINTY_RELAY_OPERATOR", "")
	if got := resolveActor("  "); got != "hatem" {
		t.Fatalf("OS user should be the fallback, got %q", got)
	}
}

func TestDefaultReasonAndFormatters(t *testing.T) {
	if defaultReason("  ", "fallback") != "fallback" {
		t.Fatal("blank reason should fall back")
	}
	if defaultReason("paid", "fallback") != "paid" {
		t.Fatal("explicit reason should win")
	}
	if onOff(true) != "on" || onOff(false) != "off" {
		t.Fatal("onOff mapping is wrong")
	}
	if dashIfEmpty("") != "—" || dashIfEmpty("x") != "x" {
		t.Fatal("dashIfEmpty mapping is wrong")
	}
	stamp := "2026-06-25T17:20:02Z"
	if got := formatTimeField(&stamp); got != "2026-06-25 17:20 UTC" {
		t.Fatalf("unexpected formatted time %q", got)
	}
	if formatTimeField(nil) != "—" {
		t.Fatal("nil time should render as a dash")
	}
}

func TestIdAndFlagsRequiresPositionalID(t *testing.T) {
	flags := flag.NewFlagSet("t", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	if _, err := idAndFlags(nil, flags); err == nil {
		t.Fatal("expected an error when no id is supplied")
	}

	flags = flag.NewFlagSet("t", flag.ContinueOnError)
	verbose := flags.Bool("json", false, "")
	id, err := idAndFlags([]string{"inst_1", "--json"}, flags)
	if err != nil {
		t.Fatal(err)
	}
	if id != "inst_1" || !*verbose {
		t.Fatalf("expected id and parsed flag, got id=%q json=%v", id, *verbose)
	}
}

func TestRunInstallationsListRendersTable(t *testing.T) {
	restore := newRelayAdminHTTPClient
	defer func() { newRelayAdminHTTPClient = restore }()
	var capturedPath, capturedQuery, capturedAuth string
	newRelayAdminHTTPClient = func(_ relayAdminHTTPClientOptions) (*http.Client, error) {
		return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			capturedPath = r.URL.Path
			capturedQuery = r.URL.RawQuery
			capturedAuth = r.Header.Get("Authorization")
			body := `{"count":1,"installations":[{"id":"inst_1","shop_name":"Alpha Market","relay_enabled":true,"subscription_active":true,"ai_enabled":false}]}`
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(body)),
				Header:     http.Header{"Content-Type": []string{"application/json"}},
			}, nil
		})}, nil
	}

	out, err := captureStdout(t, func() error {
		return runInstallationsList([]string{
			"--control-url", "https://relay.test",
			"--admin-token", "secret",
			"--query", "alpha",
			"--active",
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	if capturedPath != "/v1/installations" {
		t.Fatalf("unexpected path %q", capturedPath)
	}
	if !strings.Contains(capturedQuery, "query=alpha") || !strings.Contains(capturedQuery, "subscription_active=true") {
		t.Fatalf("unexpected query %q", capturedQuery)
	}
	if capturedAuth != "Bearer secret" {
		t.Fatalf("unexpected auth header %q", capturedAuth)
	}
	if !strings.Contains(out, "Alpha Market") || !strings.Contains(out, "1 installation(s).") {
		t.Fatalf("table output missing expected content:\n%s", out)
	}
}

func TestRunSubscriptionToggleSendsAuditedPatch(t *testing.T) {
	restore := newRelayAdminHTTPClient
	defer func() { newRelayAdminHTTPClient = restore }()
	t.Setenv("POINTY_RELAY_OPERATOR", "ops-team")
	var method, path string
	var sent map[string]any
	newRelayAdminHTTPClient = func(_ relayAdminHTTPClientOptions) (*http.Client, error) {
		return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			method = r.Method
			path = r.URL.Path
			_ = json.NewDecoder(r.Body).Decode(&sent)
			body := `{"installation":{"id":"inst_1","shop_name":"Alpha Market","relay_enabled":true,"subscription_active":true},"audit_event":{}}`
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(body)),
				Header:     http.Header{"Content-Type": []string{"application/json"}},
			}, nil
		})}, nil
	}

	out, err := captureStdout(t, func() error {
		return runSubscriptionToggle([]string{"inst_1", "--control-url", "https://relay.test", "--admin-token", "secret"}, true)
	})
	if err != nil {
		t.Fatal(err)
	}
	if method != http.MethodPatch || path != "/v1/installations/inst_1/subscription" {
		t.Fatalf("unexpected request %s %s", method, path)
	}
	if sent["relay_enabled"] != true || sent["subscription_active"] != true {
		t.Fatalf("enable must set both flags true, got %#v", sent)
	}
	if sent["actor"] != "ops-team" {
		t.Fatalf("actor should default from env, got %#v", sent["actor"])
	}
	if strings.TrimSpace(sent["reason"].(string)) == "" {
		t.Fatal("a default reason must be supplied for the audit trail")
	}
	if !strings.Contains(out, "Updated inst_1.") {
		t.Fatalf("expected a confirmation line, got:\n%s", out)
	}
}

func captureStdout(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	original := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = writer
	runErr := fn()
	_ = writer.Close()
	os.Stdout = original
	data, _ := io.ReadAll(reader)
	return string(data), runErr
}

func TestDeriveNodeProxyTokenIsDeterministicAndStrong(t *testing.T) {
	const admin = "Zk7Qx2b9c4f1a8d5e3g6h0j9k2m5n8p1"

	first := deriveNodeProxyToken(admin)
	if first != deriveNodeProxyToken(admin) {
		t.Fatal("same admin token must derive the same node proxy token across instances")
	}
	if first == deriveNodeProxyToken(admin+"x") {
		t.Fatal("different admin tokens must derive different node proxy tokens")
	}
	if first == admin {
		t.Fatal("derived token must not equal the admin token")
	}
	if len(first) != 64 {
		t.Fatalf("expected a 64-char hex secret, got %d chars", len(first))
	}
	// Whitespace around the admin token must not change the derived value, so a
	// stray newline in one instance's env can't desync the mesh.
	if deriveNodeProxyToken("  "+admin+"\n") != first {
		t.Fatal("admin token whitespace must not affect derivation")
	}
}

func TestNodeURLFor(t *testing.T) {
	for _, tt := range []struct {
		name     string
		ip       string
		httpAddr string
		want     string
		ok       bool
	}{
		{name: "wildcard bind", ip: "10.0.3.7", httpAddr: "0.0.0.0:8091", want: "http://10.0.3.7:8091", ok: true},
		{name: "explicit host", ip: "172.16.5.9", httpAddr: "0.0.0.0:443", want: "http://172.16.5.9:443", ok: true},
		{name: "empty ip", ip: "", httpAddr: "0.0.0.0:8091", ok: false},
		{name: "addr without port", ip: "10.0.3.7", httpAddr: "10.0.3.7", ok: false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := nodeURLFor(tt.ip, tt.httpAddr)
			if ok != tt.ok {
				t.Fatalf("ok = %v, want %v", ok, tt.ok)
			}
			if ok && got != tt.want {
				t.Fatalf("url = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestPrimaryPrivateIPv4ReturnsUsableOrNothing(t *testing.T) {
	// The host environment decides whether an address exists; assert only that
	// when one is returned it is a parseable, private IPv4 — never loopback,
	// link-local, or public — so the mesh can't advertise something unsafe.
	ip, ok := primaryPrivateIPv4()
	if !ok {
		return
	}
	parsed := net.ParseIP(ip)
	if parsed == nil || parsed.To4() == nil {
		t.Fatalf("expected a valid IPv4 address, got %q", ip)
	}
	if parsed.IsLoopback() || parsed.IsLinkLocalUnicast() {
		t.Fatalf("must not advertise a loopback or link-local address, got %q", ip)
	}
	if !parsed.IsPrivate() {
		t.Fatalf("must only advertise a private (RFC 1918) address, got %q", ip)
	}
}

func validPaaSServerSecurityConfig() serverSecurityConfig {
	return serverSecurityConfig{
		Platform:               "paas",
		AdminToken:             "Zk7Qx2b9c4f1a8d5e3g6h0j9k2m5n8p1",
		AllowInsecureHTTP:      true,
		HTTPAddr:               "0.0.0.0:8091",
		ConnectorAddr:          "0.0.0.0:8092",
		ConnectorTLSServerName: "relay.example.com",
		AutoTLS:                true,
	}
}

func validProductionServerSecurityConfig() serverSecurityConfig {
	return serverSecurityConfig{
		Production:             true,
		AdminHTTPAddr:          "127.0.0.1:8093",
		AdminToken:             "admin-secret",
		HTTPTLSCert:            "/etc/pointy/relay-http.crt",
		HTTPTLSKey:             "/etc/pointy/relay-http.key",
		HTTPAddr:               "127.0.0.1:8091",
		HTTPClientCA:           "/etc/pointy/admin-ca.crt",
		RequireAdminClientCert: true,
		ConnectorTLSCert:       "/etc/pointy/relay-connector.crt",
		ConnectorTLSKey:        "/etc/pointy/relay-connector.key",
		ConnectorAddr:          "127.0.0.1:8092",
		ConnectorClientCA:      "/etc/pointy/connector-ca.crt",
		ConnectorClientCAKey:   "/etc/pointy/connector-ca.key",
		NodeInternalURL:        "https://relay-node-a.internal",
		NodeProxyToken:         "node-secret",
	}
}

func TestSubscriptionUpdateBodyBuildsExplicitAuditedChanges(t *testing.T) {
	body, err := subscriptionUpdateBody(subscriptionUpdateOptions{
		InstallationID:     "installation-1",
		Actor:              "ops@example.com",
		Reason:             "customer paid",
		RelayEnabled:       "true",
		SubscriptionActive: "true",
		SubscriptionEndsAt: "2026-12-31T23:59:59Z",
	})
	if err != nil {
		t.Fatal(err)
	}

	if body["actor"] != "ops@example.com" ||
		body["reason"] != "customer paid" ||
		body["relay_enabled"] != true ||
		body["subscription_active"] != true ||
		body["subscription_ends_at"] != "2026-12-31T23:59:59Z" {
		t.Fatalf("unexpected subscription update body %#v", body)
	}
	if _, ok := body["ai_enabled"]; ok {
		t.Fatal("unset optional fields must not be sent")
	}
}

func TestSubscriptionUpdateBodyRequiresActorReasonAndChange(t *testing.T) {
	if _, err := subscriptionUpdateBody(subscriptionUpdateOptions{
		InstallationID: "installation-1",
		Actor:          "ops@example.com",
		Reason:         "customer paid",
	}); err == nil {
		t.Fatal("expected at least one change requirement")
	}
	if _, err := subscriptionUpdateBody(subscriptionUpdateOptions{
		InstallationID:     "installation-1",
		Reason:             "customer paid",
		SubscriptionActive: "true",
	}); err == nil {
		t.Fatal("expected actor requirement")
	}
	if _, err := subscriptionUpdateBody(subscriptionUpdateOptions{
		InstallationID:     "installation-1",
		Actor:              "ops@example.com",
		SubscriptionActive: "true",
	}); err == nil {
		t.Fatal("expected reason requirement")
	}
}

func TestProvisionedInstallationOutputRedactsTokenHashes(t *testing.T) {
	output := provisionedInstallationOutput(control.ProvisionedInstallation{
		Installation: control.Installation{
			ID:                 "installation-1",
			ConnectorTokenHash: "connector-hash",
			AccessTokenHash:    "access-hash",
			RelayEnabled:       true,
		},
		ConnectorToken: "ptc1.installation-1.secret",
		AccessToken:    "ptr1.installation-1.secret",
	})

	installation, ok := output["installation"].(map[string]any)
	if !ok {
		t.Fatalf("unexpected installation output %#v", output["installation"])
	}
	if _, ok := installation["connector_token_hash"]; ok {
		t.Fatal("provision output must not expose connector token hash")
	}
	if _, ok := installation["access_token_hash"]; ok {
		t.Fatal("provision output must not expose access token hash")
	}
	if output["connector_token"] != "ptc1.installation-1.secret" ||
		output["access_token"] != "ptr1.installation-1.secret" {
		t.Fatalf("expected one-time tokens to remain in provision output, got %#v", output)
	}
}

func TestRunInstallationsDiagnosticsSingleWritesZip(t *testing.T) {
	restore := newRelayAdminHTTPClient
	defer func() { newRelayAdminHTTPClient = restore }()
	var capturedPath, capturedQuery, capturedAuth, capturedAccept string
	newRelayAdminHTTPClient = func(_ relayAdminHTTPClientOptions) (*http.Client, error) {
		return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			capturedPath = r.URL.Path
			capturedQuery = r.URL.RawQuery
			capturedAuth = r.Header.Get("Authorization")
			capturedAccept = r.Header.Get("Accept")
			body := "PK-zip-bytes"
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(body)),
				Header: http.Header{
					"Content-Type":                   []string{"application/zip"},
					"X-Pointy-Analytics-Event-Count": []string{"7"},
					"X-Pointy-App-Version":           []string{"0.1.0"},
					"X-Pointy-Connector-Version":     []string{"pointy-relay/test"},
					"X-Pointy-Diag-Online":           []string{"true"},
				},
			}, nil
		})}, nil
	}

	outPath := filepath.Join(t.TempDir(), "diag.zip")
	out, err := captureStdout(t, func() error {
		return runInstallationsDiagnostics([]string{
			"inst_1",
			"--control-url", "https://relay.test",
			"--admin-token", "secret",
			"--event-type", "error",
			"--out", outPath,
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	if capturedPath != "/v1/installations/inst_1/diagnostics-analytics" {
		t.Fatalf("unexpected path %q", capturedPath)
	}
	if !strings.Contains(capturedQuery, "event_type=error") {
		t.Fatalf("unexpected query %q", capturedQuery)
	}
	if capturedAuth != "Bearer secret" {
		t.Fatalf("unexpected auth %q", capturedAuth)
	}
	if capturedAccept != "application/zip" {
		t.Fatalf("unexpected accept %q", capturedAccept)
	}
	content, readErr := os.ReadFile(outPath)
	if readErr != nil {
		t.Fatalf("expected output file: %v", readErr)
	}
	if string(content) != "PK-zip-bytes" {
		t.Fatalf("unexpected file content %q", content)
	}
	if !strings.Contains(out, "inst_1") || !strings.Contains(out, "7") {
		t.Fatalf("summary missing expected content:\n%s", out)
	}
}

func TestRunInstallationsDiagnosticsAllPullsEach(t *testing.T) {
	restore := newRelayAdminHTTPClient
	defer func() { newRelayAdminHTTPClient = restore }()
	newRelayAdminHTTPClient = func(_ relayAdminHTTPClientOptions) (*http.Client, error) {
		return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			if r.URL.Path == "/v1/installations" {
				body := `{"count":2,"installations":[{"id":"inst_1","shop_name":"Alpha"},{"id":"inst_2","shop_name":"Beta"}]}`
				return &http.Response{
					StatusCode: http.StatusOK,
					Body:       io.NopCloser(strings.NewReader(body)),
					Header:     http.Header{"Content-Type": []string{"application/json"}},
				}, nil
			}
			body := "PK-zip-bytes"
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(body)),
				Header: http.Header{
					"Content-Type":                   []string{"application/zip"},
					"X-Pointy-Analytics-Event-Count": []string{"2"},
				},
			}, nil
		})}, nil
	}

	dir := t.TempDir()
	out, err := captureStdout(t, func() error {
		return runInstallationsDiagnostics([]string{
			"--all",
			"--control-url", "https://relay.test",
			"--admin-token", "secret",
			"--out-dir", dir,
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"inst_1", "inst_2"} {
		content, readErr := os.ReadFile(filepath.Join(dir, id+".zip"))
		if readErr != nil {
			t.Fatalf("expected %s.zip: %v", id, readErr)
		}
		if string(content) != "PK-zip-bytes" {
			t.Fatalf("unexpected content for %s: %q", id, content)
		}
	}
	if !strings.Contains(out, "2 pulled") {
		t.Fatalf("summary missing totals:\n%s", out)
	}
}

func TestRunInstallationsDiagnosticsRequiresTarget(t *testing.T) {
	if err := runInstallationsDiagnostics([]string{"--admin-token", "secret"}); err == nil {
		t.Fatal("expected an error when neither an installation id nor --all is given")
	}
	if err := runInstallationsDiagnostics([]string{
		"inst_1", "--all", "--admin-token", "secret",
	}); err == nil {
		t.Fatal("expected an error when both an installation id and --all are given")
	}
}

func TestRunSubscriptionSetSendsAuditedPatch(t *testing.T) {
	restore := newRelayAdminHTTPClient
	defer func() { newRelayAdminHTTPClient = restore }()
	t.Setenv("POINTY_RELAY_OPERATOR", "ops-team")
	var method, path string
	var sent map[string]any
	newRelayAdminHTTPClient = func(_ relayAdminHTTPClientOptions) (*http.Client, error) {
		return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			method = r.Method
			path = r.URL.Path
			_ = json.NewDecoder(r.Body).Decode(&sent)
			body := `{"installation":{"id":"inst_1","shop_name":"Alpha","relay_enabled":true,"subscription_active":true,"ai_enabled":true},"audit_event":{}}`
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(body)),
				Header:     http.Header{"Content-Type": []string{"application/json"}},
			}, nil
		})}, nil
	}

	_, err := captureStdout(t, func() error {
		return runSubscriptionSet([]string{
			"inst_1",
			"--control-url", "https://relay.test",
			"--admin-token", "secret",
			"--months", "3",
			"--ai",
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	if method != http.MethodPatch {
		t.Fatalf("expected PATCH, got %s", method)
	}
	if path != "/v1/installations/inst_1/subscription" {
		t.Fatalf("unexpected path %q", path)
	}
	if sent["relay_enabled"] != true || sent["subscription_active"] != true || sent["ai_enabled"] != true {
		t.Fatalf("expected relay+subscription+ai enabled, got %#v", sent)
	}
	endsRaw, ok := sent["subscription_ends_at"].(string)
	if !ok || endsRaw == "" {
		t.Fatalf("expected subscription_ends_at, got %#v", sent["subscription_ends_at"])
	}
	endsAt, perr := time.Parse(time.RFC3339, endsRaw)
	if perr != nil {
		t.Fatalf("subscription_ends_at not RFC3339: %v", perr)
	}
	if !endsAt.After(time.Now().Add(80 * 24 * time.Hour)) {
		t.Fatalf("expected end ~3 months out, got %s", endsRaw)
	}
	if sent["actor"] != "ops-team" {
		t.Fatalf("expected actor from env, got %#v", sent["actor"])
	}
	if reason, ok := sent["reason"].(string); !ok || !strings.Contains(reason, "3-month") {
		t.Fatalf("expected a descriptive reason, got %#v", sent["reason"])
	}
}

func TestRunSubscriptionSetValidates(t *testing.T) {
	base := []string{"inst_1", "--admin-token", "secret"}
	cases := map[string][]string{
		"months and days":      {"--months", "3", "--days", "3"},
		"ai and no-ai":         {"--ai", "--no-ai"},
		"remote and no-remote": {"--remote", "--no-remote"},
		"nothing to set":       {},
	}
	for name, extra := range cases {
		args := append(append([]string{}, base...), extra...)
		if err := runSubscriptionSet(args); err == nil {
			t.Fatalf("%s: expected an error, got nil", name)
		}
	}
}

func TestSubscriptionEndFromFlags(t *testing.T) {
	endsAt, err := subscriptionEndFromFlags(3, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	parsed, perr := time.Parse(time.RFC3339, endsAt)
	if perr != nil || !parsed.After(time.Now()) {
		t.Fatalf("expected a future RFC3339 end from --months, got %q (%v)", endsAt, perr)
	}
	if got, err := subscriptionEndFromFlags(0, 0, ""); err != nil || got != "" {
		t.Fatalf("expected empty end with no flags, got %q (%v)", got, err)
	}
	if got, err := subscriptionEndFromFlags(0, 0, "2027-01-02T03:04:05Z"); err != nil || got != "2027-01-02T03:04:05Z" {
		t.Fatalf("expected normalized --until, got %q (%v)", got, err)
	}
	if _, err := subscriptionEndFromFlags(1, 1, ""); err == nil {
		t.Fatal("expected error when both --months and --days are set")
	}
	if _, err := subscriptionEndFromFlags(0, 0, "not-a-date"); err == nil {
		t.Fatal("expected error for a non-RFC3339 --until")
	}
	if _, err := subscriptionEndFromFlags(-1, 0, ""); err == nil {
		t.Fatal("expected error for negative --months")
	}
}

func TestDiagnosticsHelpers(t *testing.T) {
	if got := sanitizeFilename("inst/with:bad*chars"); got != "inst_with_bad_chars" {
		t.Fatalf("sanitizeFilename = %q", got)
	}
	if got := sanitizeFilename("   "); got != "installation" {
		t.Fatalf("sanitizeFilename blank = %q", got)
	}
	if got := humanBytes(0); got != "-" {
		t.Fatalf("humanBytes(0) = %q", got)
	}
	if got := humanBytes(512); got != "512B" {
		t.Fatalf("humanBytes(512) = %q", got)
	}
	if got := humanBytes(2048); got != "2.0KB" {
		t.Fatalf("humanBytes(2048) = %q", got)
	}
	if !isConnectorOfflineError(fmt.Errorf(`returned 503: {"error":"connector offline"}`)) {
		t.Fatal("expected connector-offline detection")
	}
	if isConnectorOfflineError(fmt.Errorf("some other error")) {
		t.Fatal("did not expect connector-offline detection")
	}
}

// fakeAdminAPI answers every admin call with body and records what was asked.
type fakeAdminAPI struct {
	method string
	path   string
	query  url.Values
	sent   map[string]any
}

func installFakeAdminAPI(t *testing.T, body string) *fakeAdminAPI {
	t.Helper()
	restore := newRelayAdminHTTPClient
	t.Cleanup(func() { newRelayAdminHTTPClient = restore })
	fake := &fakeAdminAPI{}
	newRelayAdminHTTPClient = func(_ relayAdminHTTPClientOptions) (*http.Client, error) {
		return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			fake.method = r.Method
			fake.path = r.URL.Path
			fake.query = r.URL.Query()
			if r.Body != nil {
				_ = json.NewDecoder(r.Body).Decode(&fake.sent)
			}
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(body)),
				Header:     http.Header{"Content-Type": []string{"application/json"}},
			}, nil
		})}, nil
	}
	return fake
}

var adminFlags = []string{"--control-url", "https://relay.test", "--admin-token", "secret"}

func TestSubscriptionUpdateBodyCarriesSMSFields(t *testing.T) {
	body, err := subscriptionUpdateBody(subscriptionUpdateOptions{
		InstallationID:  "installation-1",
		Actor:           "ops@example.com",
		Reason:          "sms add-on",
		SMSEnabled:      "true",
		SMSMonthlyLimit: "750",
	})
	if err != nil {
		t.Fatal(err)
	}
	if body["sms_enabled"] != true || body["sms_monthly_limit"] != 750 {
		t.Fatalf("unexpected body %#v", body)
	}
	if _, ok := body["relay_enabled"]; ok {
		t.Fatal("an SMS-only change must not touch remote access")
	}
	for _, bad := range []string{"-3", "lots", "1.5"} {
		if _, err := subscriptionUpdateBody(subscriptionUpdateOptions{
			InstallationID:  "installation-1",
			Actor:           "ops",
			Reason:          "typo",
			SMSMonthlyLimit: bad,
		}); err == nil {
			t.Fatalf("sms-monthly-limit %q should be rejected", bad)
		}
	}
	// "0" is a real value: back to the relay default.
	body, err = subscriptionUpdateBody(subscriptionUpdateOptions{
		InstallationID:  "installation-1",
		Actor:           "ops",
		Reason:          "reset",
		SMSMonthlyLimit: "0",
	})
	if err != nil || body["sms_monthly_limit"] != 0 {
		t.Fatalf("expected an explicit 0, got %#v %v", body, err)
	}
}

func TestRunSubscriptionUpdateSendsSMSFlags(t *testing.T) {
	t.Setenv("POINTY_RELAY_OPERATOR", "ops-team")
	fake := installFakeAdminAPI(t, `{"installation":{"id":"inst_1","sms_enabled":true,"sms_monthly_limit":750},"audit_event":{}}`)
	out, err := captureStdout(t, func() error {
		return runSubscriptionUpdate(append([]string{
			"inst_1", "--reason", "sms add-on", "--sms-enabled", "true", "--sms-monthly-limit", "750",
		}, adminFlags...))
	})
	if err != nil {
		t.Fatal(err)
	}
	if fake.method != http.MethodPatch || fake.path != "/v1/installations/inst_1/subscription" {
		t.Fatalf("unexpected request %s %s", fake.method, fake.path)
	}
	if fake.sent["sms_enabled"] != true || fake.sent["sms_monthly_limit"] != float64(750) {
		t.Fatalf("unexpected body %#v", fake.sent)
	}
	if !strings.Contains(out, "sms enabled") || !strings.Contains(out, "750/month") {
		t.Fatalf("the confirmation should show the SMS state:\n%s", out)
	}
}

func TestRunSubscriptionSetTogglesSMS(t *testing.T) {
	t.Setenv("POINTY_RELAY_OPERATOR", "ops-team")
	fake := installFakeAdminAPI(t, `{"installation":{"id":"inst_1","sms_enabled":true},"audit_event":{}}`)
	if _, err := captureStdout(t, func() error {
		return runSubscriptionSet(append([]string{"inst_1", "--sms", "--sms-monthly-limit", "900"}, adminFlags...))
	}); err != nil {
		t.Fatal(err)
	}
	if fake.sent["sms_enabled"] != true || fake.sent["sms_monthly_limit"] != float64(900) {
		t.Fatalf("unexpected body %#v", fake.sent)
	}
	if _, ok := fake.sent["relay_enabled"]; ok {
		t.Fatal("--sms alone must not change remote access")
	}
	if _, ok := fake.sent["subscription_active"]; ok {
		t.Fatal("--sms alone must not change the subscription")
	}
	reason, _ := fake.sent["reason"].(string)
	if !strings.Contains(reason, "SMS on") || !strings.Contains(reason, "SMS cap 900/month") {
		t.Fatalf("expected a descriptive reason, got %q", reason)
	}

	if _, err := captureStdout(t, func() error {
		return runSubscriptionSet(append([]string{"inst_1", "--no-sms"}, adminFlags...))
	}); err != nil {
		t.Fatal(err)
	}
	if fake.sent["sms_enabled"] != false {
		t.Fatalf("--no-sms must send false, got %#v", fake.sent)
	}
	if err := runSubscriptionSet(append([]string{"inst_1", "--sms", "--no-sms"}, adminFlags...)); err == nil {
		t.Fatal("--sms and --no-sms are mutually exclusive")
	}
	if err := runSubscriptionSet(append([]string{"inst_1", "--sms-monthly-limit", "-2"}, adminFlags...)); err == nil {
		t.Fatal("a negative SMS cap must be rejected")
	}
}

func TestInstallationViewsShowSMS(t *testing.T) {
	installFakeAdminAPI(t, `{"id":"inst_1","shop_name":"Alpha","sms_enabled":true,"sms_monthly_limit":0}`)
	out, err := captureStdout(t, func() error {
		return runInstallationsShow(append([]string{"inst_1"}, adminFlags...))
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "sms enabled") || !strings.Contains(out, "relay default") {
		t.Fatalf("show should include the SMS entitlement and cap:\n%s", out)
	}

	installFakeAdminAPI(t, `{"count":1,"installations":[{"id":"inst_1","shop_name":"Alpha","sms_enabled":true}]}`)
	out, err = captureStdout(t, func() error { return runInstallationsList(adminFlags) })
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "SMS") {
		t.Fatalf("list should have an SMS column:\n%s", out)
	}
}

func TestRunSMSUsageRendersTheBusiestShopFirst(t *testing.T) {
	fake := installFakeAdminAPI(t, `{"from":"2026-09-01T00:00:00+02:00","to":"2026-10-01T00:00:00+02:00",
		"totals":{"installations":2,"messages":15,"sent":13,"failed":2,"delivered":11,"test":4,"cost":"1.50"},
		"installations":[
			{"installation_id":"inst_quiet","shop_name":"Quiet Shop","messages":3,"sent":3,"failed":0,"delivered":3,"cost":"0.30"},
			{"installation_id":"inst_busy","shop_name":"Busy Shop","messages":12,"sent":10,"failed":2,"delivered":8,"cost":"1.20","last_sent_at":"2026-09-27T08:15:00Z"}
		]}`)
	out, err := captureStdout(t, func() error {
		return runSMSUsage(append([]string{"--from", "2026-09-01", "--to", "2026-09-30"}, adminFlags...))
	})
	if err != nil {
		t.Fatal(err)
	}
	if fake.method != http.MethodGet || fake.path != "/v1/sms/usage" {
		t.Fatalf("unexpected request %s %s", fake.method, fake.path)
	}
	// Days are Libyan days, and --to includes the whole day.
	if fake.query.Get("from") != "2026-09-01T00:00:00+02:00" || fake.query.Get("to") != "2026-10-01T00:00:00+02:00" {
		t.Fatalf("unexpected period %v", fake.query)
	}
	busy, quiet := strings.Index(out, "Busy Shop"), strings.Index(out, "Quiet Shop")
	if busy < 0 || quiet < 0 || busy > quiet {
		t.Fatalf("the busiest shop must come first:\n%s", out)
	}
	for _, want := range []string{
		"2026-09-01 00:00 +02:00 → 2026-10-01 00:00 +02:00",
		"MESSAGES", "COST", "LAST SENT", "1.20", "2026-09-27 08:15 UTC", "15 message(s)", "1.50 LYD",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("output missing %q:\n%s", want, out)
		}
	}
	if err := runSMSUsage(append([]string{"--from", "yesterday"}, adminFlags...)); err == nil {
		t.Fatal("a malformed date must be rejected")
	}
}

func TestRunSMSLogMasksNumbers(t *testing.T) {
	fake := installFakeAdminAPI(t, `{"count":1,"messages":[{"id":"m1","installation_id":"inst_1","shop_name":"Alpha",
		"kind":"invoice","recipient":"218912345678","status":"failed","test_mode":false,"cost":"0.00",
		"error_code":"provider_credit","created_at":"2026-09-27T08:00:00Z"}]}`)
	out, err := captureStdout(t, func() error {
		return runSMSLog(append([]string{"--installation", "inst_1", "--status", "failed", "--limit", "20"}, adminFlags...))
	})
	if err != nil {
		t.Fatal(err)
	}
	if fake.path != "/v1/sms/messages" || fake.query.Get("installation_id") != "inst_1" ||
		fake.query.Get("status") != "failed" || fake.query.Get("limit") != "20" {
		t.Fatalf("unexpected request %s %v", fake.path, fake.query)
	}
	if strings.Contains(out, "218912345678") || !strings.Contains(out, "218••••••678") {
		t.Fatalf("the table must mask the number:\n%s", out)
	}
	if !strings.Contains(out, "provider_credit") || !strings.Contains(out, "Alpha") {
		t.Fatalf("unexpected table:\n%s", out)
	}
	if err := runSMSLog(append([]string{"--status", "lost"}, adminFlags...)); err == nil {
		t.Fatal("an unknown status must be rejected")
	}
}

func TestRunSMSConfigListsMissingTemplates(t *testing.T) {
	fake := installFakeAdminAPI(t, `{"configured":true,"test_mode":true,"base_url":"https://dev.resala.ly/api/v1",
		"templates":{"invoice":"uuid-invoice","loyalty":"uuid-loyalty"},"monthly_limit_default":500,
		"rate_limit":"60/minute","request_timeout":"20s","max_variable_runes":320,"delivery_sync_interval":"5m0s",
		"catalog":[{"kind":"invoice","consent_class":"transactional","variables":3,"configured":true},
		           {"kind":"test","consent_class":"transactional","variables":1,"configured":false}]}`)
	out, err := captureStdout(t, func() error { return runSMSConfig(adminFlags) })
	if err != nil {
		t.Fatal(err)
	}
	if fake.path != "/v1/sms/config" {
		t.Fatalf("unexpected path %q", fake.path)
	}
	for _, want := range []string{"test mode", "60/minute", "uuid-invoice", "MISSING", "loyalty", "1 kind(s) have no template id"} {
		if !strings.Contains(out, want) {
			t.Fatalf("output missing %q:\n%s", want, out)
		}
	}
}

func TestBuildSMSConfig(t *testing.T) {
	config, warnings, err := buildSMSConfig(smsSettings{
		Token:                " resala-token ",
		BaseURL:              "https://dev.resala.ly/api/v1",
		Templates:            `{"invoice":"uuid-1","test":"uuid-2"}`,
		TestMode:             true,
		MonthlyLimit:         500,
		RateLimit:            "60/minute",
		RequestTimeout:       20 * time.Second,
		MaxVariableRunes:     320,
		DeliverySyncInterval: 5 * time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	if config.Token != "resala-token" || len(config.Templates) != 2 || config.Templates["test"] != "uuid-2" ||
		!config.TestMode || config.MonthlyLimit != 500 || config.RateLimit.Limit != 60 ||
		config.RateLimit.Window != time.Minute || config.DeliverySyncInterval != 5*time.Minute {
		t.Fatalf("unexpected config %+v", config)
	}
	if len(warnings) != 0 {
		t.Fatalf("unexpected warnings %v", warnings)
	}

	_, _, err = buildSMSConfig(smsSettings{Templates: `{"invoice":`, RateLimit: "60/minute"})
	if err == nil || !strings.Contains(err.Error(), "POINTY_RELAY_SMS_TEMPLATES") {
		t.Fatalf("invalid template JSON must fail startup clearly, got %v", err)
	}
	if _, _, err := buildSMSConfig(smsSettings{RateLimit: "sixty"}); err == nil ||
		!strings.Contains(err.Error(), "POINTY_RELAY_SMS_RATE_LIMIT") {
		t.Fatalf("an invalid rate must fail startup, got %v", err)
	}
	if _, _, err := buildSMSConfig(smsSettings{RateLimit: "60/minute", MonthlyLimit: -1}); err == nil {
		t.Fatal("a negative monthly limit must fail startup")
	}
	_, warnings, err = buildSMSConfig(smsSettings{Templates: `{"invoice":"uuid"}`, RateLimit: "0"})
	if err != nil || len(warnings) != 1 || !strings.Contains(warnings[0], "POINTY_RELAY_RESALA_API_TOKEN is empty") {
		t.Fatalf("templates without a token deserve a warning: %v %v", warnings, err)
	}
}
