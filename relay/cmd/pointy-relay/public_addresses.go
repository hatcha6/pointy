package main

import (
	"fmt"
	"net/url"
	"strings"

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
