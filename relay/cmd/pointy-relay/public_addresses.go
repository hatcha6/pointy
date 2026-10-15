package main

import (
	"fmt"
	"net/url"
	"strings"

	"pointy/relay/internal/connector"
	"pointy/relay/internal/protocol"
	relayserver "pointy/relay/internal/relay"
)

// buildPublicAddresses is what the relay tells every shop its public origins
// are. Only https origins are advertised: a shop would put the address on
// phones and on links its customers open.
func buildPublicAddresses(apiURL, pagesURL string) (relayserver.PublicAddresses, error) {
	api, err := httpsOrigin("POINTY_RELAY_PUBLIC_URL", apiURL, false)
	if err != nil {
		return relayserver.PublicAddresses{}, err
	}
	pages, err := httpsOrigin("POINTY_RELAY_PUBLIC_PAGES_URL", pagesURL, true)
	if err != nil {
		return relayserver.PublicAddresses{}, err
	}
	return relayserver.PublicAddresses{API: api, Pages: pages}, nil
}

// httpsOrigin normalizes raw to scheme://host. A plain-http value is not
// advertised (strict refuses it instead: nothing else reads that setting).
func httpsOrigin(name, raw string, strict bool) (string, error) {
	raw = strings.TrimRight(strings.TrimSpace(raw), "/")
	if raw == "" {
		return "", nil
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" || (parsed.Path != "" && parsed.Path != "/") ||
		parsed.RawQuery != "" || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return "", fmt.Errorf("%s must be a public origin, e.g. https://relay.example.com, got %q", name, raw)
	}
	if parsed.Scheme != "https" {
		if strict {
			return "", fmt.Errorf("%s must be https, got %q", name, raw)
		}
		return "", nil
	}
	return "https://" + strings.ToLower(parsed.Host), nil
}

// buildConnectorEndpoints is the tunnel address list the relay hands every
// connector in its HelloAck. Unset, it is the tunnel over HTTPS on the public
// API origin: the balancer spreads those across the nodes, which is the point.
// "none" advertises an empty list, which also clears what connectors saved.
func buildConnectorEndpoints(raw, apiOrigin string) ([]string, error) {
	raw = strings.TrimSpace(raw)
	if strings.EqualFold(raw, "none") {
		return []string{}, nil
	}
	if raw == "" {
		if apiOrigin == "" {
			return []string{}, nil
		}
		raw = "wss://" + strings.TrimPrefix(apiOrigin, "https://") + protocol.TunnelPath
	}
	endpoints, err := connector.ParseEndpoints(raw)
	if err != nil {
		return nil, fmt.Errorf("POINTY_RELAY_CONNECTOR_ENDPOINTS: %w", err)
	}
	if len(endpoints) > protocol.MaxAdvertisedEndpoints {
		return nil, fmt.Errorf("POINTY_RELAY_CONNECTOR_ENDPOINTS: at most %d addresses", protocol.MaxAdvertisedEndpoints)
	}
	out := make([]string, 0, len(endpoints))
	for _, endpoint := range endpoints {
		out = append(out, endpoint.String())
	}
	return out, nil
}
