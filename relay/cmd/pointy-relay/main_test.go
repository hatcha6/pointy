package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"

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
