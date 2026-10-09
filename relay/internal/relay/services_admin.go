package relay

import (
	"encoding/json"
	"net/http"
	"strings"

	"pointy/relay/internal/control"
	"pointy/relay/internal/services"
)

// The operator's side of the services (admin token):
//
//	GET  /v1/services/admin/config                         what the services are, and when the directory was read
//	GET  /v1/services/admin/directory?country=ML,NE&refresh=1   the directory as a shop reads it (filtered);
//	                                                       &accept=1 with refresh believes a far smaller directory
//	POST /v1/services/admin/quote                          the quote route, without a shop
//	GET  /v1/services/admin/names?missing=1                names the Arabic tables do not have
//	GET  /v1/services/admin/balance                        the company's balance at Reloadly, per product

func (s HTTPServer) handleServiceAdminRoutes(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/v1/services/admin")
	store, ok := s.voucherStore()
	if !ok {
		writeSMSError(w, http.StatusNotImplemented, voucherCodeUnavailable, "vouchers are not supported by this relay's store", nil)
		return
	}
	switch {
	case path == "/config" && r.Method == http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{"stats": s.Services.Stats()})
	case path == "/directory" && r.Method == http.MethodGet:
		s.handleServiceAdminDirectory(w, r, store)
	case path == "/quote" && r.Method == http.MethodPost:
		s.handleServiceAdminQuote(w, r, store)
	case path == "/names" && r.Method == http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{
			"missing": nonNilNames(s.Services.MissingNames()),
			"stats":   s.Services.Stats(),
		})
	case path == "/balance" && r.Method == http.MethodGet:
		balances, ok := s.Services.Balances(r.Context())
		if !ok {
			writeSMSError(w, http.StatusServiceUnavailable, serviceCodeUnconfigured,
				"Reloadly is not configured on this relay (POINTY_RELAY_RELOADLY_CLIENT_ID and _CLIENT_SECRET)", nil)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"balances": balances})
	default:
		writeNotFound(w)
	}
}

func nonNilNames(names []services.MissingName) []services.MissingName {
	if names == nil {
		return []services.MissingName{}
	}
	return names
}

// handleServiceAdminDirectory shows the directory as shops read it, optionally
// reading the supplier again first and keeping only some countries.
func (s HTTPServer) handleServiceAdminDirectory(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	ctx := r.Context()
	query := r.URL.Query()
	if refresh := strings.ToLower(query.Get("refresh")); refresh == "1" || refresh == "true" {
		read := s.Services.Refresh
		if accept := strings.ToLower(query.Get("accept")); accept == "1" || accept == "true" {
			// The operator knows the supplier really dropped that much (see
			// services.Rejection): believe it, this once.
			read = s.Services.RefreshAccepting
		}
		if err := read(ctx); err != nil {
			writeSMSError(w, http.StatusBadGateway, serviceCodeUnavailable, "reading the supplier failed: "+services.RedactError(err), nil)
			return
		}
	}
	in, err := s.servicePricing(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "services pricing read failed", err)
		return
	}
	rendered, err := s.Services.Directory(ctx, in)
	if err != nil {
		writeSMSError(w, http.StatusServiceUnavailable, serviceCodeUnavailable, "the services directory could not be read: "+services.RedactError(err), nil)
		return
	}
	view := *rendered.View
	if filter := strings.TrimSpace(query.Get("country")); filter != "" {
		wanted := map[string]bool{}
		for _, code := range strings.FieldsFunc(filter, func(r rune) bool { return r == ',' || r == ' ' || r == ';' }) {
			wanted[strings.ToUpper(strings.TrimSpace(code))] = true
		}
		view.Countries = nil
		for _, country := range rendered.View.Countries {
			if wanted[country.Code] {
				view.Countries = append(view.Countries, country)
			}
		}
		if view.Countries == nil {
			view.Countries = []services.Country{}
		}
		view.Unsupported = nil
		for _, country := range rendered.View.Unsupported {
			if wanted[country.Code] {
				view.Unsupported = append(view.Unsupported, country)
			}
		}
		if view.Unsupported == nil {
			view.Unsupported = []services.Unsupported{}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"directory": view, "stats": s.Services.Stats()})
}

// handleServiceAdminQuote is the quote route for the operator: the same checks,
// the same prices, no shop.
func (s HTTPServer) handleServiceAdminQuote(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	var request serviceQuoteRequest
	if err := decodeServiceBody(w, r, maxServiceRequestBytes, &request); err != nil {
		return
	}
	in, err := s.servicePricing(r.Context(), store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "services pricing read failed", err)
		return
	}
	quoted, refusal := s.Services.Quote(r.Context(), in, request.request())
	if refusal != nil {
		writeRefusal(w, refusal)
		return
	}
	body, _ := json.Marshal(map[string]any{
		"quote":            quoted.Quote,
		"cost_lyd":         quoted.Prices.CostLYD.FloatString(3),
		"order_in_dollars": !quoted.Order.Local,
		"order_amount":     services.FormatAmount(quoted.Order.Amount),
		"order_currency":   quoted.Order.Currency,
		"order_cost_usd":   services.FormatAmount(quoted.Order.Cost),
	})
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(append(body, '\n'))
}
