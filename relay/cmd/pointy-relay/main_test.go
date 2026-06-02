package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
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
					"installation_id":         "installation-1",
					"shop_name":               "متجر الاختبار",
					"relay_connector_address": "relay.example:443",
					"connector_token":         "ptc1.installation-1.secret",
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

	if _, err := fetchBackendConnectorConfig(context.Background(), backendURL, "", ""); err == nil {
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

	if _, err := fetchBackendConnectorConfig(context.Background(), backendURL, "", "setup-secret"); err == nil {
		t.Fatal("expected backend bootstrap HTTP error")
	}
}
