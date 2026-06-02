package discovery

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestDiscoverBackendProbesHTTPDiscoveryEndpoint(t *testing.T) {
	client := &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			if r.URL.String() != "http://pointy.test/api/discovery/service/" {
				t.Fatalf("unexpected discovery URL %q", r.URL.String())
			}
			content, err := json.Marshal(BackendService{
				Service:    "pointy-backend",
				Version:    1,
				BackendURL: "http://pointy.test",
				APIBaseURL: "http://pointy.test/api",
				ShopName:   "متجر آمن",
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

	backendURL, err := DiscoverBackend(context.Background(), BackendOptions{
		Candidates: []string{"http://pointy.test"},
		HTTPClient: client,
	})
	if err != nil {
		t.Fatal(err)
	}

	if backendURL.String() != "http://pointy.test" {
		t.Fatalf("unexpected backend URL %q", backendURL.String())
	}
}

func TestBackendURLFromServiceFallsBackFromAPIBaseURL(t *testing.T) {
	backendURL, err := backendURLFromService(nil, BackendService{
		Service:    "pointy-backend",
		APIBaseURL: "https://relay.example/api",
	})
	if err != nil {
		t.Fatal(err)
	}

	if backendURL.String() != "https://relay.example" {
		t.Fatalf("unexpected backend URL %q", backendURL.String())
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}
