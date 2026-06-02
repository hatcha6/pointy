package discovery

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	ProbeMessage   = "POINTY_DISCOVERY_V1"
	DefaultUDPPort = 47777
)

type BackendOptions struct {
	Candidates []string
	UDPPort    int
	Timeout    time.Duration
	HTTPClient *http.Client
}

type BackendService struct {
	Service    string `json:"service"`
	Version    int    `json:"version"`
	BackendURL string `json:"backend_url"`
	APIBaseURL string `json:"api_base_url"`
	ShopName   string `json:"shop_name"`
}

func DiscoverBackend(ctx context.Context, options BackendOptions) (*url.URL, error) {
	timeout := options.Timeout
	if timeout == 0 {
		timeout = 2 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	client := options.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 500 * time.Millisecond}
	}
	candidates := append([]string{}, options.Candidates...)
	candidates = append(candidates, "http://127.0.0.1:8000", "http://localhost:8000")
	for _, candidate := range candidates {
		backendURL, err := probeHTTP(ctx, client, candidate)
		if err == nil {
			return backendURL, nil
		}
	}

	return discoverBackendUDP(ctx, client, options)
}

func probeHTTP(ctx context.Context, client *http.Client, raw string) (*url.URL, error) {
	origin, err := parseOrigin(raw)
	if err != nil {
		return nil, err
	}
	endpoint := *origin
	endpoint.Path = joinPath(endpoint.Path, "/api/discovery/service/")
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, err
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("discovery returned %d", response.StatusCode)
	}
	var service BackendService
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&service); err != nil {
		return nil, err
	}
	return backendURLFromService(origin, service)
}

func discoverBackendUDP(
	ctx context.Context,
	client *http.Client,
	options BackendOptions,
) (*url.URL, error) {
	port := options.UDPPort
	if port == 0 {
		port = DefaultUDPPort
	}
	conn, err := net.ListenPacket("udp4", "0.0.0.0:0")
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))

	broadcast := &net.UDPAddr{IP: net.IPv4bcast, Port: port}
	if _, err := conn.WriteTo([]byte(ProbeMessage), broadcast); err != nil {
		return nil, err
	}

	buffer := make([]byte, 4096)
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
		n, address, err := conn.ReadFrom(buffer)
		if err != nil {
			return nil, err
		}
		var service BackendService
		if err := json.Unmarshal(buffer[:n], &service); err != nil {
			continue
		}
		if service.Service != "pointy-backend" {
			continue
		}
		backendURL, err := backendURLFromServiceAddress(service, address)
		if err != nil {
			continue
		}
		if verified, err := probeHTTP(ctx, client, backendURL.String()); err == nil {
			return verified, nil
		}
	}
}

func backendURLFromService(fallback *url.URL, service BackendService) (*url.URL, error) {
	if service.Service != "pointy-backend" {
		return nil, errors.New("not a Pointy backend")
	}
	if strings.TrimSpace(service.BackendURL) != "" {
		return parseOrigin(service.BackendURL)
	}
	if strings.TrimSpace(service.APIBaseURL) != "" {
		apiURL, err := parseOrigin(service.APIBaseURL)
		if err != nil {
			return nil, err
		}
		apiURL.Path = strings.TrimSuffix(strings.TrimSuffix(apiURL.Path, "/api"), "/")
		return apiURL, nil
	}
	return fallback, nil
}

func backendURLFromServiceAddress(service BackendService, address net.Addr) (*url.URL, error) {
	if strings.TrimSpace(service.BackendURL) != "" {
		return parseOrigin(service.BackendURL)
	}
	if strings.TrimSpace(service.APIBaseURL) != "" {
		return backendURLFromService(nil, service)
	}
	host, _, err := net.SplitHostPort(address.String())
	if err != nil {
		return nil, err
	}
	return parseOrigin("http://" + host + ":8000")
}

func parseOrigin(raw string) (*url.URL, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, errors.New("backend URL is empty")
	}
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

func joinPath(basePath string, childPath string) string {
	basePath = strings.TrimRight(basePath, "/")
	childPath = strings.TrimLeft(childPath, "/")
	if basePath == "" {
		return "/" + childPath
	}
	if childPath == "" {
		return basePath
	}
	return basePath + "/" + childPath
}
