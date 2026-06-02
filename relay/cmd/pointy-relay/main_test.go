package main

import (
	"context"
	"encoding/json"
	"io"
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

	if _, err := fetchBackendConnectorConfig(context.Background(), backendURL, "", "", ""); err == nil {
		t.Fatal("expected setup token requirement")
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

	if _, err := fetchBackendConnectorConfig(context.Background(), backendURL, "", "setup-secret", ""); err == nil {
		t.Fatal("expected backend bootstrap HTTP error")
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
			message: "connector mTLS",
		},
		{
			name:    "missing connector issuer key",
			mutate:  func(config *serverSecurityConfig) { config.ConnectorClientCAKey = "" },
			message: "automatic certificate issuance",
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

func validProductionServerSecurityConfig() serverSecurityConfig {
	return serverSecurityConfig{
		Production:             true,
		AdminHTTPAddr:          "127.0.0.1:8093",
		AdminToken:             "admin-secret",
		HTTPTLSCert:            "/etc/pointy/relay-http.crt",
		HTTPTLSKey:             "/etc/pointy/relay-http.key",
		HTTPClientCA:           "/etc/pointy/admin-ca.crt",
		RequireAdminClientCert: true,
		ConnectorTLSCert:       "/etc/pointy/relay-connector.crt",
		ConnectorTLSKey:        "/etc/pointy/relay-connector.key",
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
