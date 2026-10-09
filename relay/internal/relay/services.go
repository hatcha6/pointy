package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"pointy/relay/internal/control"
	"pointy/relay/internal/services"
	"pointy/relay/internal/vouchers"
)

// Direct top-up and bill payments: credit sent straight to a phone number
// abroad, and utility and subscription bills paid abroad, both bought by the
// company from Reloadly in dollars and sold to a shop from its voucher balance.
// The directory says what can be sold and at what price; an order is charged to
// the voucher balance before Reloadly is called, exactly like a card.
//
//	GET  /v1/services/directory     countries, operators, billers, priced (ETag)
//	POST /v1/services/detect        {country, phone} -> the operator of a number
//	POST /v1/services/quote         the exact price of one thing (+ how a number was read)
//	POST /v1/services/orders        place an order {kind, ..., idempotency_key}
//	GET  /v1/services/orders/{key}  read an order back (also GET /v1/vouchers/purchases/{key})
//
// A phone number and an account are the customer's: they travel in request
// bodies only, never in a URL or a query string, and the relay writes down only
// their masked form ("+223•••••456").
//
// The operator's side (admin token): /v1/services/admin/{config,directory,quote,
// names,balance}.

// Error codes of the services API that the vouchers API does not already have.
const (
	serviceCodeUnconfigured = services.CodeServicesUnconfigured
	serviceCodeUnavailable  = services.CodeServicesUnavailable
	maxServiceRequestBytes  = 16 << 10
	maxServiceDetectBytes   = 2 << 10
)

// handleServiceRoutes serves everything under /v1/services.
func (s HTTPServer) handleServiceRoutes(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if strings.HasPrefix(path, "/v1/services/admin/") {
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleServiceAdminRoutes)
		return
	}
	if !s.RouteMode.allowsPublic() {
		writeNotFound(w)
		return
	}
	method := r.Method
	switch {
	case strings.HasPrefix(path, "/v1/services/logos/"):
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w, http.MethodGet)
			return
		}
		s.handleServiceLogo(w, r, strings.TrimPrefix(path, "/v1/services/logos/"))
	case path == "/v1/services/directory":
		if method != http.MethodGet {
			writeMethodNotAllowed(w, http.MethodGet)
			return
		}
		s.handleServiceDirectory(w, r)
	case path == "/v1/services/detect":
		if method != http.MethodPost {
			writeMethodNotAllowed(w, http.MethodPost)
			return
		}
		s.handleServiceDetect(w, r)
	case path == "/v1/services/quote":
		if method != http.MethodPost {
			writeMethodNotAllowed(w, http.MethodPost)
			return
		}
		s.handleServiceQuote(w, r)
	case path == "/v1/services/orders":
		if method != http.MethodPost {
			writeMethodNotAllowed(w, http.MethodPost)
			return
		}
		s.handleServiceOrder(w, r)
	case strings.HasPrefix(path, "/v1/services/orders/"):
		if method != http.MethodGet {
			writeMethodNotAllowed(w, http.MethodGet)
			return
		}
		s.handleServiceOrderRead(w, r, strings.TrimPrefix(path, "/v1/services/orders/"))
	default:
		writeNotFound(w)
	}
}

func writeMethodNotAllowed(w http.ResponseWriter, allowed string) {
	w.Header().Set("Allow", allowed)
	writeSMSError(w, http.StatusMethodNotAllowed, voucherCodeInvalidRequest, "use "+allowed+" for this route", nil)
}

// writeRefusal answers a request the services layer turned down.
func writeRefusal(w http.ResponseWriter, refusal *services.Refusal) {
	writeSMSError(w, refusal.Status, refusal.Code, refusal.Message, refusal.Extra)
}

// requireServices answers for a relay that sells no services, and returns the
// store when it does.
func (s HTTPServer) requireServices(w http.ResponseWriter) (control.VoucherStore, bool) {
	store, ok := s.voucherStore()
	if !ok {
		writeSMSError(w, http.StatusServiceUnavailable, voucherCodeUnavailable, "vouchers are not supported by this relay's store", nil)
		return nil, false
	}
	if !s.Services.Configured() {
		writeSMSError(w, http.StatusServiceUnavailable, serviceCodeUnconfigured, "this relay sells no top-up or bill payments", nil)
		return nil, false
	}
	return store, true
}

// servicePricing is what a directory, a quote or an order is priced with: the
// operator's pricing settings, and the flags the card catalog carries for the
// countries.
func (s HTTPServer) servicePricing(ctx context.Context, store control.VoucherStore) (services.PricingInput, error) {
	loaded, err := s.loadVoucherSettings(ctx, store)
	if err != nil {
		return services.PricingInput{}, err
	}
	key := "default"
	if loaded.stored {
		key = loaded.record.SHA256
	} else if _, sum, err := vouchers.EncodeSettings(loaded.settings); err == nil {
		key = "default:" + sum
	}
	if rate, source := loaded.settings.EffectiveUSDRate(); rate != nil {
		// The live rate moves without a new settings version: it is part of what a
		// cached directory was priced with.
		key += "|" + source + ":" + rate.RatString()
	}
	in := services.PricingInput{Settings: loaded.settings, SettingsKey: key}
	// Operator logos are the relay's own copies; the ones not copied yet are
	// fetched in the background and show on the next reading.
	s.ServiceLogos.Want(store, s.Services.OperatorLogoURLs())
	in.Logos, in.LogosKey = s.ServiceLogos.Snapshot()
	catalog, err := s.currentVoucherCatalog(ctx, store)
	if err != nil {
		return services.PricingInput{}, err
	}
	if !catalog.empty {
		in.FlagsKey = catalog.record.SHA256
		in.Flags = map[string]string{}
		for _, country := range catalog.document.Countries {
			if flag := strings.TrimSpace(country.Flag); flag != "" {
				in.Flags[strings.ToUpper(country.Code)] = flag
			}
		}
	}
	return in, nil
}

// handleServiceDirectory serves GET /v1/services/directory.
func (s HTTPServer) handleServiceDirectory(w http.ResponseWriter, r *http.Request) {
	store, ok := s.voucherStore()
	if !ok {
		writeSMSError(w, http.StatusServiceUnavailable, voucherCodeUnavailable, "vouchers are not supported by this relay's store", nil)
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	in, err := s.servicePricing(ctx, store)
	if err != nil {
		s.logger().Error("services pricing read failed", "installation_id", installation.ID, "error", err)
		writeSMSError(w, http.StatusInternalServerError, voucherCodeInternalError, "relay store failed", nil)
		return
	}
	rendered, err := s.Services.Directory(ctx, in)
	if err != nil {
		s.logger().Warn("the services directory is not available", "installation_id", installation.ID, "error", err)
		w.Header().Set("Retry-After", "30")
		writeSMSError(w, http.StatusServiceUnavailable, serviceCodeUnavailable, "the services directory could not be read yet", nil)
		return
	}
	etag := `"` + rendered.Version + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, no-cache")
	if etagMatches(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(rendered.Body)+1))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(rendered.Body)
	_, _ = w.Write([]byte("\n"))
}

// etagMatches reports whether an If-None-Match header names the entity tag.
func etagMatches(header, etag string) bool {
	for _, candidate := range strings.Split(header, ",") {
		candidate = strings.TrimPrefix(strings.TrimSpace(candidate), "W/")
		if candidate == "*" || candidate == etag {
			return true
		}
	}
	return false
}

type serviceDetectRequest struct {
	Country string `json:"country"`
	Phone   string `json:"phone"`
}

// handleServiceDetect serves POST /v1/services/detect: the operator of a number.
// The number is in the body, never in the URL.
func (s HTTPServer) handleServiceDetect(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireServices(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	var request serviceDetectRequest
	if err := decodeServiceBody(w, r, maxServiceDetectBytes, &request); err != nil {
		return
	}
	if strings.TrimSpace(request.Country) == "" || strings.TrimSpace(request.Phone) == "" {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "country and phone are required", nil)
		return
	}
	ctx := r.Context()
	in, err := s.servicePricing(ctx, store)
	if err != nil {
		s.logger().Error("services pricing read failed", "installation_id", installation.ID, "error", err)
		writeSMSError(w, http.StatusInternalServerError, voucherCodeInternalError, "relay store failed", nil)
		return
	}
	detection, refusal := s.Services.Detect(ctx, in, request.Country, request.Phone)
	if refusal != nil {
		writeRefusal(w, refusal)
		return
	}
	writeJSON(w, http.StatusOK, detection)
}

// serviceQuoteRequest is POST /v1/services/quote; amounts may be JSON strings or
// numbers.
type serviceQuoteRequest struct {
	Kind           string          `json:"kind"`
	OperatorID     int64           `json:"operator_id"`
	BillerID       int64           `json:"biller_id"`
	Amount         json.RawMessage `json:"amount"`
	AmountCurrency string          `json:"amount_currency"`
	AmountID       *int64          `json:"amount_id"`
	InvoiceID      *string         `json:"invoice_id"`
	// Country and Phone ride only on an airtime quote, and only when the cashier
	// has typed the number: the answer then says how the relay read it.
	Country string `json:"country"`
	Phone   string `json:"phone"`
}

func (q serviceQuoteRequest) request() services.QuoteRequest {
	request := services.QuoteRequest{
		Kind:           q.Kind,
		OperatorID:     q.OperatorID,
		BillerID:       q.BillerID,
		Amount:         jsonAmount(q.Amount),
		AmountCurrency: q.AmountCurrency,
		InvoiceID:      q.InvoiceID,
		Country:        q.Country,
		Phone:          q.Phone,
	}
	if q.AmountID != nil && *q.AmountID > 0 {
		request.AmountID = *q.AmountID
	}
	return request
}

// handleServiceQuote serves POST /v1/services/quote: the exact price of one
// thing. Nothing is charged and the supplier is not called.
func (s HTTPServer) handleServiceQuote(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireServices(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	var request serviceQuoteRequest
	if err := decodeServiceBody(w, r, maxServiceRequestBytes, &request); err != nil {
		return
	}
	ctx := r.Context()
	in, err := s.servicePricing(ctx, store)
	if err != nil {
		s.logger().Error("services pricing read failed", "installation_id", installation.ID, "error", err)
		writeSMSError(w, http.StatusInternalServerError, voucherCodeInternalError, "relay store failed", nil)
		return
	}
	quoted, refusal := s.Services.Quote(ctx, in, request.request())
	if refusal != nil {
		writeRefusal(w, refusal)
		return
	}
	answer := map[string]any{"quote": quoted.Quote}
	if quoted.Phone != nil {
		answer["phone"] = quoted.Phone
	}
	writeJSON(w, http.StatusOK, answer)
}

// decodeServiceBody reads a JSON request body of at most limit bytes into out.
// A body that is not that JSON is answered 400 and returned as an error.
func decodeServiceBody(w http.ResponseWriter, r *http.Request, limit int64, out any) error {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, limit))
	if err := decoder.Decode(out); err != nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "invalid request body", nil)
		return err
	}
	return nil
}

// jsonAmount reads an amount the caller wrote as a JSON string or number, as the
// text it was written in (no float is involved).
func jsonAmount(raw json.RawMessage) string {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return ""
	}
	if raw[0] == '"' {
		var text string
		if err := json.Unmarshal(raw, &text); err != nil {
			return ""
		}
		return strings.TrimSpace(text)
	}
	return string(raw)
}
