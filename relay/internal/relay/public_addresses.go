package relay

import "net/http"

// PublicAddresses are the relay's stable public origins. Every shop's backend
// syncs from the installation status read, so carrying them there moves the
// whole fleet when the relay moves to a new domain: the shop hands phones the
// new API origin at pairing and prints the new pages origin on invoice links,
// without anyone editing a shop's settings.
//
// Empty leaves the field out, and the shop keeps the address it is
// configured with. Only https origins are set (main validates them).
type PublicAddresses struct {
	// API is the origin phones and shops reach the relay's API on.
	API string
	// Pages is the origin of customer-facing pages (public invoices). Kept
	// apart from the console's host so public pages never share its origin.
	Pages string
}

func (s HTTPServer) withPublicAddresses(_ *http.Request, payload map[string]any) map[string]any {
	if s.Public.API != "" {
		payload["public_api_url"] = s.Public.API
	}
	if s.Public.Pages != "" {
		payload["public_pages_url"] = s.Public.Pages
	}
	return payload
}
