package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"pointy/relay/internal/control"
	"pointy/relay/internal/plutu"
	"pointy/relay/internal/ratelimit"
)

// The shop wallet over HTTP. A shop's backend reads its balance and history
// and starts top-ups with its installation token. The payer's browser comes
// back from Plutu to a public page, which verifies the signed outcome and
// credits the wallet. The operator reads every wallet and corrects one by
// hand, under their own name.
//
// Payment verification is the whole difficulty. Plutu's local-card gateway
// has no status API and no server-to-server callback: the only proof of a
// payment is the signed query string on the payer's redirect. So the relay
// never believes an unsigned or unmatched return, credits a matching one
// exactly once however often it is replayed, lets a late approval win over a
// checkout it had written off as expired, and leaves a return it cannot prove
// untouched for the operator rather than guessing either way.

const (
	walletReturnPath = "/v1/wallet/plutu/return"
	walletCurrency   = "LYD"
	// walletConfirmedByGateway marks a top-up the gateway's signed return
	// proved; an operator's reconciliation is "operator:<name>".
	walletConfirmedByGateway = "plutu"
	// plutuSandboxMaximum is Plutu's per-transaction ceiling in test mode.
	plutuSandboxMaximum = "500"
	// plutuAmountDecimals is the gateway's own rule: dinars with at most two
	// places, although the dinar has three.
	plutuAmountDecimals = 2

	defaultWalletTopUpTTL        = 30 * time.Minute
	defaultWalletRequestTimeout  = 20 * time.Second
	defaultWalletMinTopUp        = "10"
	defaultWalletMaxTopUp        = "5000"
	maxWalletRequestBytes        = 16 << 10
	maxWalletRequestedByRunes    = 128
	walletRecentTopUps           = 10
	walletRecentEntries          = 10
	walletMinimumStaleAfter      = time.Minute
	walletCheckoutLanguageArabic = "ar"
)

var defaultWalletQuickAmounts = []string{"50", "100", "200", "500"}

// Error codes of the wallet API. Django maps each to its own Arabic message.
const (
	walletCodeUnavailable         = "wallet_unavailable"
	walletCodeTopUpsUnconfigured  = "topups_unconfigured"
	walletCodeInvalidRequest      = "invalid_request"
	walletCodeInvalidAmount       = "invalid_amount"
	walletCodeUnsupportedMethod   = "unsupported_method"
	walletCodeRateLimited         = "rate_limited"
	walletCodeInFlight            = "in_flight"
	walletCodeNotFound            = "not_found"
	walletCodeInsufficientBalance = "insufficient_balance"
	walletCodeGatewayUnauthorized = "gateway_unauthorized"
	walletCodeGatewayRejected     = "gateway_rejected"
	walletCodeAmountNotAllowed    = "amount_not_allowed"
	walletCodeGatewayBusy         = "gateway_busy"
	walletCodeGatewayError        = "gateway_error"
	walletCodeOutcomeUnknown      = "outcome_unknown"
	walletCodeAmountMismatch      = "amount_mismatch"
	walletCodeCanceled            = "canceled"
	walletCodeDeclined            = "declined"
	walletCodeInternalError       = "internal_error"
)

// WalletConfig is the company's payment gateway account and the top-up rules.
// The Plutu credentials live only here, like the Resala token.
type WalletConfig struct {
	PlutuBaseURL     string
	PlutuAPIKey      string
	PlutuAccessToken string
	// PlutuSecretKey verifies the signed return; it is never sent anywhere.
	PlutuSecretKey string
	// TestMode says the access token is Plutu's test token. It marks every
	// top-up and its credit as test money and holds amounts to the sandbox
	// ceiling. The relay cannot tell the tokens apart, so it is stated.
	TestMode bool
	// PublicURL is the relay's public origin, where the payer's browser comes
	// back to. Empty derives it from the request that starts the top-up.
	PublicURL string
	// MinTopUp and MaxTopUp bound one top-up, in dinars.
	MinTopUp     string
	MaxTopUp     string
	QuickAmounts []string
	// TopUpTTL is how long a checkout stays pending before the expiry sweep
	// writes it off (a later signed approval still credits it).
	TopUpTTL time.Duration
	// TopUpRateLimit is the per-shop guard on starting checkouts.
	TopUpRateLimit ratelimit.Policy
	RequestTimeout time.Duration
	HTTPClient     *http.Client
}

// TopUpsConfigured reports whether top-ups can run: all three Plutu values.
func (c WalletConfig) TopUpsConfigured() bool {
	return strings.TrimSpace(c.PlutuAPIKey) != "" &&
		strings.TrimSpace(c.PlutuAccessToken) != "" &&
		strings.TrimSpace(c.PlutuSecretKey) != ""
}

func (c WalletConfig) topUpTTL() time.Duration {
	if c.TopUpTTL > 0 {
		return c.TopUpTTL
	}
	return defaultWalletTopUpTTL
}

func (c WalletConfig) requestTimeout() time.Duration {
	if c.RequestTimeout > 0 {
		return c.RequestTimeout
	}
	return defaultWalletRequestTimeout
}

func (c WalletConfig) quickAmounts() []string {
	if len(c.QuickAmounts) > 0 {
		return c.QuickAmounts
	}
	return defaultWalletQuickAmounts
}

// topUpBounds returns the smallest and largest top-up accepted right now.
func (c WalletConfig) topUpBounds() (*big.Rat, *big.Rat) {
	minimum, err := control.ParseWalletAmount(c.MinTopUp)
	if err != nil || minimum.Sign() <= 0 {
		minimum, _ = control.ParseWalletAmount(defaultWalletMinTopUp)
	}
	maximum, err := control.ParseWalletAmount(c.MaxTopUp)
	if err != nil || maximum.Sign() <= 0 {
		maximum, _ = control.ParseWalletAmount(defaultWalletMaxTopUp)
	}
	if c.TestMode {
		sandbox, _ := control.ParseWalletAmount(plutuSandboxMaximum)
		if maximum.Cmp(sandbox) > 0 {
			maximum = sandbox
		}
	}
	return minimum, maximum
}

func (s HTTPServer) walletStore() (control.WalletStore, bool) {
	store, ok := s.Store.(control.WalletStore)
	return store, ok
}

func (s HTTPServer) plutuClient() *plutu.Client {
	return plutu.New(plutu.Config{
		BaseURL:     s.Wallet.PlutuBaseURL,
		APIKey:      s.Wallet.PlutuAPIKey,
		AccessToken: s.Wallet.PlutuAccessToken,
		SecretKey:   s.Wallet.PlutuSecretKey,
		HTTPClient:  s.Wallet.HTTPClient,
		Timeout:     s.Wallet.requestTimeout(),
	})
}

// handleWalletRoutes serves everything under /v1/wallet.
func (s HTTPServer) handleWalletRoutes(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == walletReturnPath && (r.Method == http.MethodGet || r.Method == http.MethodPost):
		// The payer's browser, back from the gateway. No token: the signature
		// is the credential.
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handlePlutuReturn(w, r)
	case strings.HasPrefix(path, "/v1/wallet/admin/"):
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleWalletAdminRoutes)
	default:
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handleWalletShopRoutes(w, r)
	}
}

// handleWalletShopRoutes serves a shop's own wallet, authenticated by its
// installation token for identity only: a shop with a lapsed subscription can
// still see its balance and pay in — paying in may be how it renews.
func (s HTTPServer) handleWalletShopRoutes(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == "/v1/wallet" && r.Method == http.MethodGet:
		s.handleWalletSelf(w, r)
	case path == "/v1/wallet/entries" && r.Method == http.MethodGet:
		s.handleWalletEntriesSelf(w, r)
	case path == "/v1/wallet/topups" && r.Method == http.MethodGet:
		s.handleWalletTopUpsSelf(w, r)
	case path == "/v1/wallet/topups" && r.Method == http.MethodPost:
		s.handleWalletTopUpCreate(w, r)
	case strings.HasPrefix(path, "/v1/wallet/topups/") && r.Method == http.MethodGet:
		s.handleWalletTopUpSelf(w, r, strings.TrimPrefix(path, "/v1/wallet/topups/"))
	default:
		writeNotFound(w)
	}
}

func (s HTTPServer) handleWalletAdminRoutes(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == "/v1/wallet/admin/wallets" && r.Method == http.MethodGet:
		s.handleWalletAdminWallets(w, r)
	case path == "/v1/wallet/admin/entries" && r.Method == http.MethodGet:
		s.handleWalletAdminEntries(w, r)
	case path == "/v1/wallet/admin/entries" && r.Method == http.MethodPost:
		s.handleWalletAdminPostEntry(w, r)
	case path == "/v1/wallet/admin/topups" && r.Method == http.MethodGet:
		s.handleWalletAdminTopUps(w, r)
	case strings.HasPrefix(path, "/v1/wallet/admin/topups/") && strings.HasSuffix(path, "/confirm") &&
		r.Method == http.MethodPost:
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/v1/wallet/admin/topups/"), "/confirm")
		s.handleWalletAdminConfirmTopUp(w, r, id)
	case path == "/v1/wallet/admin/config" && r.Method == http.MethodGet:
		s.handleWalletAdminConfig(w, r)
	default:
		writeNotFound(w)
	}
}

// --- a shop's own wallet ---

// handleWalletSelf serves GET /v1/wallet: the balance, what a top-up may be,
// and the latest movements, in one call so the app's wallet card needs no
// second round trip.
func (s HTTPServer) handleWalletSelf(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	wallet, err := store.GetWallet(ctx, installation.ID)
	if err != nil {
		s.writeWalletInternalError(w, "wallet read failed", installation.ID, err)
		return
	}
	topUps, err := store.ListWalletTopUps(ctx, control.WalletTopUpFilter{InstallationID: installation.ID, Limit: walletRecentTopUps})
	if err != nil {
		s.writeWalletInternalError(w, "wallet top-up listing failed", installation.ID, err)
		return
	}
	entries, err := store.ListWalletEntries(ctx, control.WalletEntryFilter{InstallationID: installation.ID, Limit: walletRecentEntries})
	if err != nil {
		s.writeWalletInternalError(w, "wallet ledger listing failed", installation.ID, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"balance":        wallet.Balance,
		"currency":       walletCurrency,
		"updated_at":     wallet.UpdatedAt,
		"test_mode":      s.Wallet.TestMode,
		"topups":         s.walletTopUpOptions(),
		"recent_topups":  walletTopUpPayloads(topUps),
		"recent_entries": walletEntryPayloads(entries),
	})
}

// walletTopUpOptions is what the app needs to draw its top-up sheet.
func (s HTTPServer) walletTopUpOptions() map[string]any {
	minimum, maximum := s.Wallet.topUpBounds()
	methods := []map[string]any{}
	if s.Wallet.TopUpsConfigured() {
		methods = append(methods, map[string]any{
			"key":     control.WalletTopUpMethodPlutuLocalBankCards,
			"gateway": "plutu",
			"kind":    "hosted_checkout",
		})
	}
	return map[string]any{
		"available":     s.Wallet.TopUpsConfigured(),
		"methods":       methods,
		"min_amount":    minimum.FloatString(plutuAmountDecimals),
		"max_amount":    maximum.FloatString(plutuAmountDecimals),
		"max_decimals":  plutuAmountDecimals,
		"quick_amounts": s.Wallet.quickAmounts(),
		"pending_ttl":   int(s.Wallet.topUpTTL().Seconds()),
	}
}

// handleWalletEntriesSelf serves GET /v1/wallet/entries: the shop's statement,
// newest first, paged by ?before=<entry id>.
func (s HTTPServer) handleWalletEntriesSelf(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	query := r.URL.Query()
	limit, ok := walletListLimit(w, query)
	if !ok {
		return
	}
	kind := strings.ToLower(strings.TrimSpace(query.Get("kind")))
	if kind != "" && !control.ValidWalletEntryKind(kind) {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "kind must be topup, charge, refund or adjustment", nil)
		return
	}
	entries, err := store.ListWalletEntries(r.Context(), control.WalletEntryFilter{
		InstallationID: installation.ID,
		Kind:           kind,
		Limit:          limit,
		BeforeID:       strings.TrimSpace(query.Get("before")),
	})
	if errors.Is(err, control.ErrWalletEntryNotFound) {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "unknown cursor", nil)
		return
	}
	if err != nil {
		s.writeWalletInternalError(w, "wallet ledger listing failed", installation.ID, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"entries":  walletEntryPayloads(entries),
		"has_more": len(entries) == limit,
	})
}

// handleWalletTopUpsSelf serves GET /v1/wallet/topups.
func (s HTTPServer) handleWalletTopUpsSelf(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	query := r.URL.Query()
	limit, ok := walletListLimit(w, query)
	if !ok {
		return
	}
	status := strings.ToLower(strings.TrimSpace(query.Get("status")))
	if status != "" && !control.ValidWalletTopUpStatus(status) {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"status must be pending, paid, canceled, failed or expired", nil)
		return
	}
	topUps, err := store.ListWalletTopUps(r.Context(), control.WalletTopUpFilter{
		InstallationID: installation.ID,
		Status:         status,
		Limit:          limit,
		BeforeID:       strings.TrimSpace(query.Get("before")),
	})
	if errors.Is(err, control.ErrWalletTopUpNotFound) {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "unknown cursor", nil)
		return
	}
	if err != nil {
		s.writeWalletInternalError(w, "wallet top-up listing failed", installation.ID, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"topups":   walletTopUpPayloads(topUps),
		"has_more": len(topUps) == limit,
	})
}

// handleWalletTopUpSelf serves GET /v1/wallet/topups/{id} — what the app polls
// while the payer is on the checkout page. Another shop's top-up is simply not
// found.
func (s HTTPServer) handleWalletTopUpSelf(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	topUp, err := store.GetWalletTopUp(r.Context(), strings.Trim(id, "/"))
	if errors.Is(err, control.ErrWalletTopUpNotFound) || (err == nil && topUp.InstallationID != installation.ID) {
		writeWalletError(w, http.StatusNotFound, walletCodeNotFound, "top-up not found", nil)
		return
	}
	if err != nil {
		s.writeWalletInternalError(w, "wallet top-up read failed", installation.ID, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"top_up": walletTopUpPayload(topUp)})
}

type walletTopUpRequest struct {
	Amount         json.RawMessage `json:"amount"`
	Method         string          `json:"method"`
	IdempotencyKey string          `json:"idempotency_key"`
	RequestedBy    string          `json:"requested_by"`
}

// handleWalletTopUpCreate serves POST /v1/wallet/topups. The top-up is stored
// pending BEFORE the gateway is asked for a checkout, so a relay that dies in
// between leaves a row that says so. The response carries the checkout page;
// the wallet is credited only when the payer's browser brings back a signed
// approval (handlePlutuReturn).
func (s HTTPServer) handleWalletTopUpCreate(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	if !s.Wallet.TopUpsConfigured() {
		writeWalletError(w, http.StatusServiceUnavailable, walletCodeTopUpsUnconfigured,
			"wallet top-ups are not configured on this relay", nil)
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	var request walletTopUpRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxWalletRequestBytes)).Decode(&request); err != nil {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "invalid request body", nil)
		return
	}
	request.Method = strings.ToLower(strings.TrimSpace(request.Method))
	request.IdempotencyKey = strings.TrimSpace(request.IdempotencyKey)
	request.RequestedBy = strings.TrimSpace(request.RequestedBy)
	if request.Method == "" {
		request.Method = control.WalletTopUpMethodPlutuLocalBankCards
	}
	if request.Method != control.WalletTopUpMethodPlutuLocalBankCards {
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodeUnsupportedMethod,
			fmt.Sprintf("unsupported top-up method %q", request.Method), nil)
		return
	}
	if request.IdempotencyKey == "" || utf8.RuneCountInString(request.IdempotencyKey) > 128 {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"idempotency_key is required (at most 128 characters)", nil)
		return
	}
	if utf8.RuneCountInString(request.RequestedBy) > maxWalletRequestedByRunes {
		request.RequestedBy = string([]rune(request.RequestedBy)[:maxWalletRequestedByRunes])
	}
	amount, rejection := s.validateTopUpAmount(request.Amount)
	if rejection != "" {
		minimum, maximum := s.Wallet.topUpBounds()
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodeInvalidAmount, rejection, map[string]any{
			"min_amount":   minimum.FloatString(plutuAmountDecimals),
			"max_amount":   maximum.FloatString(plutuAmountDecimals),
			"max_decimals": plutuAmountDecimals,
		})
		return
	}
	if s.enforceWalletTopUpRateLimit(w, r, installation.ID) {
		return
	}

	ctx := r.Context()
	topUp, created, err := store.BeginWalletTopUp(ctx, control.WalletTopUp{
		InstallationID: installation.ID,
		Method:         request.Method,
		Amount:         control.FormatWalletAmount(amount),
		IdempotencyKey: request.IdempotencyKey,
		RequestedBy:    request.RequestedBy,
		TestMode:       s.Wallet.TestMode,
	})
	if err != nil {
		s.writeWalletInternalError(w, "wallet top-up claim failed", installation.ID, err)
		return
	}
	if !created {
		s.replayWalletTopUp(w, r, store, topUp)
		return
	}

	// Detached from the caller: if the shop's backend hangs up mid-call, the
	// gateway's answer is still recorded, so the retry replays the truth.
	detached := context.WithoutCancel(ctx)
	callCtx, cancel := context.WithTimeout(detached, s.Wallet.requestTimeout())
	returnURL := s.walletReturnURL(r)
	checkout, err := s.plutuClient().ConfirmLocalBankCards(callCtx, plutu.CheckoutRequest{
		Amount:    amount.FloatString(plutuAmountDecimals),
		InvoiceNo: topUp.InvoiceNo,
		ReturnURL: returnURL,
		Lang:      walletCheckoutLanguageArabic,
	})
	cancel()
	if err != nil {
		code, status, detail := s.classifyPlutuError(err)
		closed, _, closeErr := store.CloseWalletTopUp(detached, topUp.ID, control.WalletTopUpFailed, code, detail)
		if closeErr != nil {
			s.logger().Error("recording a failed top-up failed", "installation_id", installation.ID,
				"top_up_id", topUp.ID, "error", closeErr)
			closed = topUp
			closed.Status = control.WalletTopUpFailed
			closed.ErrorCode = code
			closed.ErrorDetail = detail
		}
		s.logWalletTopUp(installation.ID, closed, "checkout_failed", detail)
		writeWalletError(w, status, code, walletFailureMessage(code), map[string]any{
			"detail": detail,
			"top_up": walletTopUpPayload(closed),
		})
		return
	}
	attached, err := store.AttachWalletTopUpCheckout(detached, topUp.ID, checkout.RedirectURL)
	if err != nil {
		// The checkout exists and the payer can still use it: the signed return
		// finds the top-up by invoice number, not by this URL. So hand it out.
		s.logger().Error("recording a top-up checkout failed", "installation_id", installation.ID,
			"top_up_id", topUp.ID, "error", err)
		attached = topUp
		attached.CheckoutURL = checkout.RedirectURL
	}
	s.logWalletTopUp(installation.ID, attached, "checkout_created", "")
	writeJSON(w, http.StatusCreated, map[string]any{
		"top_up":       walletTopUpPayload(attached),
		"checkout_url": checkout.RedirectURL,
		"replayed":     false,
	})
}

// replayWalletTopUp answers a create whose idempotency key already has a
// top-up: the same checkout page, or the same failure.
func (s HTTPServer) replayWalletTopUp(
	w http.ResponseWriter,
	r *http.Request,
	store control.WalletStore,
	topUp control.WalletTopUp,
) {
	now := s.clock().Now()
	switch {
	case topUp.Status == control.WalletTopUpPending && topUp.CheckoutURL == "":
		staleAfter := max(walletMinimumStaleAfter, s.Wallet.requestTimeout()+30*time.Second)
		if now.Sub(topUp.CreatedAt) < staleAfter {
			w.Header().Set("Retry-After", retryAfterSeconds(topUp.CreatedAt.Add(s.Wallet.requestTimeout()), now))
			writeWalletError(w, http.StatusConflict, walletCodeInFlight,
				"this top-up is being set up right now; retry shortly", map[string]any{"top_up": walletTopUpPayload(topUp)})
			return
		}
		// The request that claimed this key never finished. Nobody was given a
		// checkout page, so nobody can have paid: the safe verdict is failed.
		closed, _, err := store.CloseWalletTopUp(context.WithoutCancel(r.Context()), topUp.ID, control.WalletTopUpFailed,
			walletCodeOutcomeUnknown, "the checkout request never finished; start a new top-up")
		if err != nil {
			s.writeWalletInternalError(w, "recording an unfinished top-up failed", topUp.InstallationID, err)
			return
		}
		topUp = closed
	case topUp.Status == control.WalletTopUpPending:
		writeJSON(w, http.StatusOK, map[string]any{
			"top_up":       walletTopUpPayload(topUp),
			"checkout_url": topUp.CheckoutURL,
			"replayed":     true,
		})
		return
	}
	if topUp.Status == control.WalletTopUpFailed {
		code := topUp.ErrorCode
		if code == "" {
			code = walletCodeGatewayError
		}
		writeWalletError(w, http.StatusBadGateway, code, walletFailureMessage(code), map[string]any{
			"detail":   topUp.ErrorDetail,
			"top_up":   walletTopUpPayload(topUp),
			"replayed": true,
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"top_up": walletTopUpPayload(topUp), "replayed": true})
}

// validateTopUpAmount accepts a JSON string or number of dinars with at most
// the gateway's two places, inside the configured bounds. It returns the
// reason for a refusal, or "".
func (s HTTPServer) validateTopUpAmount(raw json.RawMessage) (*big.Rat, string) {
	text := strings.TrimSpace(string(raw))
	if unquoted, err := strconv.Unquote(text); err == nil {
		text = strings.TrimSpace(unquoted)
	}
	amount, err := control.ParseWalletAmount(text)
	if err != nil || amount.Sign() <= 0 {
		return nil, "amount must be a positive number of dinars"
	}
	if control.WalletAmountDecimals(text) > plutuAmountDecimals {
		return nil, fmt.Sprintf("amount may have at most %d decimal places", plutuAmountDecimals)
	}
	minimum, maximum := s.Wallet.topUpBounds()
	if amount.Cmp(minimum) < 0 {
		return nil, "amount is below the smallest top-up"
	}
	if amount.Cmp(maximum) > 0 {
		return nil, "amount is above the largest top-up"
	}
	return amount, ""
}

// classifyPlutuError maps a failed checkout request to the wallet's code, the
// status the shop gets and the detail it is shown.
func (s HTTPServer) classifyPlutuError(err error) (string, int, string) {
	var apiErr *plutu.APIError
	var transport *plutu.TransportError
	switch {
	case errors.As(err, &apiErr):
		detail := strings.TrimSpace(apiErr.Code + " " + apiErr.Message)
		// The live API is not consistent about case: its docs list
		// "UNAUTHORIZED", the sandbox answers "Unauthorized".
		switch strings.ToUpper(apiErr.Code) {
		case "UNAUTHORIZED", "DENIED_ACCESS_GATEWAY", "FORBIDDEN_IP_ADDRESS", "MISSING_PARAMETER", "TEST_MODE_NOT_SUPPORTED":
			return walletCodeGatewayUnauthorized, http.StatusBadGateway, detail
		case "AMOUNT_EXCEEDED_MAXIMUM", "AMOUNT_NOT_ALLOWED", "INVALID_AMOUNT_FORMAT",
			"SANDBOX_TRANSACTION_LIMIT_EXCEEDED", "CURRENCY_NOT_SUPPORTED":
			return walletCodeAmountNotAllowed, http.StatusUnprocessableEntity, detail
		case "TOO_MAY_REQUESTS", "TOO_MANY_REQUESTS", "MAINTENANCE_MODE":
			return walletCodeGatewayBusy, http.StatusServiceUnavailable, detail
		}
		if apiErr.Status == http.StatusTooManyRequests {
			return walletCodeGatewayBusy, http.StatusServiceUnavailable, detail
		}
		if apiErr.Status == http.StatusUnauthorized || apiErr.Status == http.StatusForbidden {
			return walletCodeGatewayUnauthorized, http.StatusBadGateway, detail
		}
		if apiErr.Status >= 500 || apiErr.Code == "BACKEND_ERROR" {
			return walletCodeGatewayError, http.StatusBadGateway, detail
		}
		return walletCodeGatewayRejected, http.StatusBadGateway, detail
	case errors.As(err, &transport):
		if transport.Timeout() {
			return walletCodeGatewayError, http.StatusBadGateway,
				fmt.Sprintf("plutu did not answer within %s", s.Wallet.requestTimeout())
		}
		return walletCodeGatewayError, http.StatusBadGateway, "plutu could not be reached"
	default:
		return walletCodeGatewayError, http.StatusBadGateway, "the checkout request failed"
	}
}

// walletReturnURL is where the gateway sends the payer back to. The operator's
// PublicURL wins; without one it is derived from the request that started the
// top-up, which already came to the relay's public address.
func (s HTTPServer) walletReturnURL(r *http.Request) string {
	base := strings.TrimRight(strings.TrimSpace(s.Wallet.PublicURL), "/")
	if base == "" {
		scheme := "http"
		if r.TLS != nil || strings.EqualFold(firstForwardedValue(r.Header.Get("X-Forwarded-Proto")), "https") {
			scheme = "https"
		}
		host := firstForwardedValue(r.Header.Get("X-Forwarded-Host"))
		if host == "" {
			host = r.Host
		}
		base = scheme + "://" + host
	}
	return base + walletReturnPath
}

func firstForwardedValue(value string) string {
	first, _, _ := strings.Cut(value, ",")
	return strings.TrimSpace(first)
}

// enforceWalletTopUpRateLimit fails OPEN like the SMS burst guard: a limiter
// outage must not stop a shop paying in.
func (s HTTPServer) enforceWalletTopUpRateLimit(w http.ResponseWriter, r *http.Request, installationID string) bool {
	policy := s.Wallet.TopUpRateLimit
	if !policy.Enabled() || s.RateLimiter == nil {
		return false
	}
	decision, err := s.RateLimiter.Allow(r.Context(), "wallet-topup:"+installationID, policy)
	if err != nil {
		s.logger().Error("wallet rate limiter failed; allowing the top-up", "installation_id", installationID, "error", err)
		return false
	}
	if decision.Allowed {
		return false
	}
	w.Header().Set("Retry-After", retryAfterSeconds(decision.ResetAt, s.clock().Now()))
	writeWalletError(w, http.StatusTooManyRequests, walletCodeRateLimited, "too many top-ups started; retry shortly", nil)
	return true
}

// --- the payer's return from the gateway ---

// handlePlutuReturn serves the page Plutu sends the payer's browser back to.
// It acts only on a return whose signature verifies against the secret AND
// whose invoice matches a top-up the relay created, and then only in the
// direction the signed fields say. Whatever it decides, it draws the page from
// the stored top-up, so a refreshed or replayed return shows the same truth
// and moves no money twice.
func (s HTTPServer) handlePlutuReturn(w http.ResponseWriter, r *http.Request) {
	store, hasStore := s.walletStore()
	if !hasStore || strings.TrimSpace(s.Wallet.PlutuSecretKey) == "" {
		writeWalletReturnPage(w, http.StatusNotFound, walletReturnUnavailable())
		return
	}
	params, err := plutuReturnParams(r)
	if err != nil || len(params) == 0 {
		writeWalletReturnPage(w, http.StatusBadRequest, walletReturnUnverified(""))
		return
	}
	callback := plutu.ReadCallback(params)
	if !plutu.VerifyCallback(s.Wallet.PlutuSecretKey, params, plutu.LocalBankCardsSignedFields) {
		// Never acted on. If it was a real payment whose signature we cannot
		// check, the operator reconciles it from the gateway's dashboard; the
		// top-up stays as it was so a genuine return can still settle it.
		s.metrics().RecordCredentialRejected()
		s.logger().Warn("plutu return signature rejected",
			"invoice_no", truncateRunes(callback.InvoiceNo, 64),
			"approved", callback.Approved,
			"canceled", callback.Canceled)
		writeWalletReturnPage(w, http.StatusBadRequest, walletReturnUnverified(callback.InvoiceNo))
		return
	}
	ctx := context.WithoutCancel(r.Context())
	topUp, err := store.FindWalletTopUpByInvoice(ctx, callback.InvoiceNo)
	if errors.Is(err, control.ErrWalletTopUpNotFound) {
		s.logger().Warn("plutu return for an unknown invoice", "invoice_no", truncateRunes(callback.InvoiceNo, 64),
			"transaction_id", truncateRunes(callback.TransactionID, 64))
		writeWalletReturnPage(w, http.StatusNotFound, walletReturnUnverified(callback.InvoiceNo))
		return
	}
	if err != nil {
		s.logger().Error("plutu return lookup failed", "invoice_no", callback.InvoiceNo, "error", err)
		writeWalletReturnPage(w, http.StatusInternalServerError, walletReturnRetry(callback.InvoiceNo))
		return
	}
	if callback.Gateway != "" && callback.Gateway != plutu.GatewayLocalBankCards {
		s.logger().Warn("plutu return names another gateway", "invoice_no", topUp.InvoiceNo, "gateway", callback.Gateway)
	}

	switch {
	case topUp.Status == control.WalletTopUpPaid:
		// A refresh, a back button, a replay: already credited.
	case callback.Approved:
		topUp, err = s.settleApprovedReturn(ctx, store, topUp, callback)
	case callback.Canceled:
		topUp, _, err = store.CloseWalletTopUp(ctx, topUp.ID, control.WalletTopUpCanceled, walletCodeCanceled,
			"the payer cancelled on the checkout page")
	default:
		topUp, _, err = store.CloseWalletTopUp(ctx, topUp.ID, control.WalletTopUpFailed, walletCodeDeclined,
			"the gateway returned without an approval")
	}
	if err != nil {
		// Nothing was decided; the payer reloading this page retries it.
		s.logger().Error("recording a plutu return failed", "invoice_no", callback.InvoiceNo, "error", err)
		writeWalletReturnPage(w, http.StatusInternalServerError, walletReturnRetry(callback.InvoiceNo))
		return
	}
	s.logWalletTopUp(topUp.InstallationID, topUp, "return_"+topUp.Status, callback.TransactionID)
	writeWalletReturnPage(w, http.StatusOK, walletReturnFor(topUp))
}

// settleApprovedReturn credits a signed approval, unless the gateway approved
// a different amount than the top-up asked for — then nothing is credited and
// the operator reconciles by hand. A mismatch should be impossible, and
// silently crediting either figure would be wrong one way or the other.
func (s HTTPServer) settleApprovedReturn(
	ctx context.Context,
	store control.WalletStore,
	topUp control.WalletTopUp,
	callback plutu.Callback,
) (control.WalletTopUp, error) {
	if !walletAmountsEqual(callback.Amount, topUp.Amount) {
		s.logger().Error("plutu approved a different amount than the top-up; not credited",
			"installation_id", topUp.InstallationID,
			"invoice_no", topUp.InvoiceNo,
			"top_up_amount", topUp.Amount,
			"approved_amount", truncateRunes(callback.Amount, 32),
			"transaction_id", truncateRunes(callback.TransactionID, 64))
		closed, _, err := store.CloseWalletTopUp(ctx, topUp.ID, control.WalletTopUpFailed, walletCodeAmountMismatch,
			fmt.Sprintf("plutu approved %s for a %s top-up (transaction %s); reconcile by hand",
				truncateRunes(callback.Amount, 32), topUp.Amount, truncateRunes(callback.TransactionID, 64)))
		return closed, err
	}
	settled, _, err := store.SettleWalletTopUp(ctx, topUp.ID, control.WalletTopUpSettlement{
		ProviderTransactionID: truncateRunes(callback.TransactionID, 128),
		ConfirmedBy:           walletConfirmedByGateway,
		Description:           "Plutu local bank card " + topUp.InvoiceNo,
	})
	return settled, err
}

// plutuReturnParams reads the return's parameters in the order they arrived:
// the query string, plus a form body if the gateway ever posts one.
func plutuReturnParams(r *http.Request) ([]plutu.Param, error) {
	params, err := plutu.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return nil, err
	}
	if r.Method == http.MethodPost &&
		strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "application/x-www-form-urlencoded") {
		body, err := io.ReadAll(io.LimitReader(r.Body, maxWalletRequestBytes))
		if err != nil {
			return nil, err
		}
		formParams, err := plutu.ParseQuery(string(body))
		if err != nil {
			return nil, err
		}
		params = append(params, formParams...)
	}
	return params, nil
}

func walletAmountsEqual(raw, stored string) bool {
	left, ok := new(big.Rat).SetString(strings.TrimSpace(raw))
	if !ok || strings.TrimSpace(raw) == "" {
		return false
	}
	right, ok := new(big.Rat).SetString(strings.TrimSpace(stored))
	return ok && left.Cmp(right) == 0
}

// --- operator ---

// handleWalletAdminWallets serves GET /v1/wallet/admin/wallets.
func (s HTTPServer) handleWalletAdminWallets(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	limit, ok := walletListLimit(w, r.URL.Query())
	if !ok {
		return
	}
	wallets, err := store.ListWallets(r.Context(), limit)
	if err != nil {
		s.writeWalletInternalError(w, "wallet listing failed", "", err)
		return
	}
	balances := make([]string, 0, len(wallets))
	for _, wallet := range wallets {
		balances = append(balances, wallet.Balance)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"wallets": wallets,
		"count":   len(wallets),
		"total":   sumWalletAmounts(balances),
	})
}

// handleWalletAdminEntries serves GET /v1/wallet/admin/entries.
func (s HTTPServer) handleWalletAdminEntries(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	query := r.URL.Query()
	limit, ok := walletListLimit(w, query)
	if !ok {
		return
	}
	entries, err := store.ListWalletEntries(r.Context(), control.WalletEntryFilter{
		InstallationID: strings.TrimSpace(query.Get("installation_id")),
		Kind:           strings.ToLower(strings.TrimSpace(query.Get("kind"))),
		Limit:          limit,
		BeforeID:       strings.TrimSpace(query.Get("before")),
	})
	if errors.Is(err, control.ErrWalletEntryNotFound) {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "unknown cursor", nil)
		return
	}
	if err != nil {
		s.writeWalletInternalError(w, "wallet ledger listing failed", "", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries, "count": len(entries)})
}

type walletAdminEntryRequest struct {
	InstallationID string `json:"installation_id"`
	Kind           string `json:"kind"`
	Service        string `json:"service"`
	Amount         string `json:"amount"`
	Reference      string `json:"reference"`
	Description    string `json:"description"`
	IdempotencyKey string `json:"idempotency_key"`
	Actor          string `json:"actor"`
	AllowOverdraft bool   `json:"allow_overdraft"`
}

// handleWalletAdminPostEntry serves POST /v1/wallet/admin/entries: an
// operator's adjustment, or a charge or refund made by hand until the service
// charges on its own. Every one names who made it and why; the entry is the
// audit record.
func (s HTTPServer) handleWalletAdminPostEntry(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	var request walletAdminEntryRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxWalletRequestBytes)).Decode(&request); err != nil {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "invalid request body", nil)
		return
	}
	if strings.TrimSpace(request.Actor) == "" || strings.TrimSpace(request.Description) == "" {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"actor and description are required: a hand-made movement must say who and why", nil)
		return
	}
	kind := strings.ToLower(strings.TrimSpace(request.Kind))
	if kind == control.WalletEntryTopUp {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"a top-up credit comes only from a paid top-up; use confirm, or an adjustment", nil)
		return
	}
	key := strings.TrimSpace(request.IdempotencyKey)
	if key == "" {
		id, err := control.NewInstallationID()
		if err != nil {
			s.writeWalletInternalError(w, "wallet key mint failed", request.InstallationID, err)
			return
		}
		key = "operator:" + id
	}
	entry, created, err := store.PostWalletEntry(r.Context(), control.WalletPosting{
		InstallationID: request.InstallationID,
		Kind:           kind,
		Service:        request.Service,
		Amount:         request.Amount,
		Reference:      request.Reference,
		Description:    request.Description,
		IdempotencyKey: key,
		Actor:          request.Actor,
		TestMode:       false,
		AllowOverdraft: request.AllowOverdraft,
	})
	var balanceErr *control.WalletBalanceError
	switch {
	case errors.As(err, &balanceErr):
		writeWalletError(w, http.StatusConflict, walletCodeInsufficientBalance, "the wallet cannot cover this", map[string]any{
			"balance": balanceErr.Balance,
			"amount":  balanceErr.Amount,
		})
		return
	case errors.Is(err, control.ErrNotFound):
		writeWalletError(w, http.StatusNotFound, walletCodeNotFound, "installation not found", nil)
		return
	case err != nil:
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, err.Error(), nil)
		return
	}
	status := http.StatusCreated
	if !created {
		status = http.StatusOK
	}
	s.logger().Info("wallet entry posted by the operator",
		"installation_id", entry.InstallationID,
		"kind", entry.Kind,
		"service", entry.Service,
		"amount", entry.Amount,
		"actor", entry.Actor,
		"replayed", !created)
	writeJSON(w, status, map[string]any{"entry": entry, "created": created})
}

// handleWalletAdminTopUps serves GET /v1/wallet/admin/topups.
func (s HTTPServer) handleWalletAdminTopUps(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	query := r.URL.Query()
	limit, ok := walletListLimit(w, query)
	if !ok {
		return
	}
	status := strings.ToLower(strings.TrimSpace(query.Get("status")))
	if status != "" && !control.ValidWalletTopUpStatus(status) {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"status must be pending, paid, canceled, failed or expired", nil)
		return
	}
	topUps, err := store.ListWalletTopUps(r.Context(), control.WalletTopUpFilter{
		InstallationID: strings.TrimSpace(query.Get("installation_id")),
		Status:         status,
		Limit:          limit,
		BeforeID:       strings.TrimSpace(query.Get("before")),
	})
	if errors.Is(err, control.ErrWalletTopUpNotFound) {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "unknown cursor", nil)
		return
	}
	if err != nil {
		s.writeWalletInternalError(w, "wallet top-up listing failed", "", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"topups": topUps, "count": len(topUps)})
}

type walletAdminConfirmRequest struct {
	ProviderTransactionID string `json:"provider_transaction_id"`
	Actor                 string `json:"actor"`
	Reason                string `json:"reason"`
}

// handleWalletAdminConfirmTopUp serves POST /v1/wallet/admin/topups/{id}/confirm:
// the operator's answer to a payer who paid but never made it back to the
// return page (closed the tab, lost the network, the relay was down). The
// operator checks the gateway's dashboard first; this credits the top-up the
// same way a signed return would, once.
func (s HTTPServer) handleWalletAdminConfirmTopUp(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	var request walletAdminConfirmRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxWalletRequestBytes)).Decode(&request); err != nil {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "invalid request body", nil)
		return
	}
	actor := strings.TrimSpace(request.Actor)
	reason := strings.TrimSpace(request.Reason)
	transactionID := strings.TrimSpace(request.ProviderTransactionID)
	if actor == "" || reason == "" || transactionID == "" {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"provider_transaction_id, actor and reason are required: check the gateway's dashboard first", nil)
		return
	}
	topUp, applied, err := store.SettleWalletTopUp(r.Context(), strings.Trim(id, "/"), control.WalletTopUpSettlement{
		ProviderTransactionID: transactionID,
		ConfirmedBy:           "operator:" + actor,
		Description:           reason,
	})
	if errors.Is(err, control.ErrWalletTopUpNotFound) {
		writeWalletError(w, http.StatusNotFound, walletCodeNotFound, "top-up not found", nil)
		return
	}
	if err != nil {
		s.writeWalletInternalError(w, "confirming a top-up failed", "", err)
		return
	}
	s.logWalletTopUp(topUp.InstallationID, topUp, "operator_confirmed", actor)
	writeJSON(w, http.StatusOK, map[string]any{"top_up": topUp, "applied": applied})
}

// handleWalletAdminConfig serves GET /v1/wallet/admin/config: what the relay
// is set up to do. It never includes a credential.
func (s HTTPServer) handleWalletAdminConfig(w http.ResponseWriter, r *http.Request) {
	options := s.walletTopUpOptions()
	options["test_mode"] = s.Wallet.TestMode
	options["public_url"] = strings.TrimSpace(s.Wallet.PublicURL)
	options["return_url"] = s.walletReturnURL(r)
	options["plutu_base_url"] = plutuBaseURL(s.Wallet.PlutuBaseURL)
	options["api_key_set"] = strings.TrimSpace(s.Wallet.PlutuAPIKey) != ""
	options["access_token_set"] = strings.TrimSpace(s.Wallet.PlutuAccessToken) != ""
	options["secret_key_set"] = strings.TrimSpace(s.Wallet.PlutuSecretKey) != ""
	options["request_timeout"] = s.Wallet.requestTimeout().String()
	options["rate_limit"] = s.Wallet.TopUpRateLimit.String()
	_, hasStore := s.walletStore()
	options["store_supports_wallets"] = hasStore
	writeJSON(w, http.StatusOK, options)
}

func plutuBaseURL(configured string) string {
	if trimmed := strings.TrimRight(strings.TrimSpace(configured), "/"); trimmed != "" {
		return trimmed
	}
	return plutu.DefaultBaseURL
}

// --- shared ---

func (s HTTPServer) requireWalletStore(w http.ResponseWriter) (control.WalletStore, bool) {
	store, ok := s.walletStore()
	if !ok {
		writeWalletError(w, http.StatusServiceUnavailable, walletCodeUnavailable, "wallets are unavailable on this relay", nil)
		return nil, false
	}
	return store, true
}

func walletListLimit(w http.ResponseWriter, query url.Values) (int, bool) {
	limit := 50
	if raw := strings.TrimSpace(query.Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed <= 0 {
			writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "invalid limit", nil)
			return 0, false
		}
		limit = min(parsed, 200)
	}
	return limit, true
}

func sumWalletAmounts(amounts []string) string {
	total := new(big.Rat)
	for _, amount := range amounts {
		if value, ok := new(big.Rat).SetString(amount); ok {
			total.Add(total, value)
		}
	}
	return control.FormatWalletAmount(total)
}

// walletTopUpPayload is a top-up as the shop sees it. The checkout page is
// only handed out while it can still be paid.
func walletTopUpPayload(topUp control.WalletTopUp) map[string]any {
	payload := map[string]any{
		"id":                      topUp.ID,
		"method":                  topUp.Method,
		"amount":                  topUp.Amount,
		"status":                  topUp.Status,
		"invoice_no":              topUp.InvoiceNo,
		"provider_transaction_id": topUp.ProviderTransactionID,
		"requested_by":            topUp.RequestedBy,
		"test_mode":               topUp.TestMode,
		"error_code":              topUp.ErrorCode,
		"error_detail":            topUp.ErrorDetail,
		"entry_id":                topUp.EntryID,
		"confirmed_by":            topUp.ConfirmedBy,
		"created_at":              topUp.CreatedAt,
		"updated_at":              topUp.UpdatedAt,
		"paid_at":                 topUp.PaidAt,
	}
	if topUp.Status == control.WalletTopUpPending {
		payload["checkout_url"] = topUp.CheckoutURL
	}
	return payload
}

func walletTopUpPayloads(topUps []control.WalletTopUp) []map[string]any {
	payloads := make([]map[string]any, 0, len(topUps))
	for _, topUp := range topUps {
		payloads = append(payloads, walletTopUpPayload(topUp))
	}
	return payloads
}

func walletEntryPayload(entry control.WalletEntry) map[string]any {
	return map[string]any{
		"id":            entry.ID,
		"kind":          entry.Kind,
		"service":       entry.Service,
		"amount":        entry.Amount,
		"balance_after": entry.BalanceAfter,
		"reference":     entry.Reference,
		"description":   entry.Description,
		"test_mode":     entry.TestMode,
		"created_at":    entry.CreatedAt,
	}
}

func walletEntryPayloads(entries []control.WalletEntry) []map[string]any {
	payloads := make([]map[string]any, 0, len(entries))
	for _, entry := range entries {
		payloads = append(payloads, walletEntryPayload(entry))
	}
	return payloads
}

func walletFailureMessage(code string) string {
	switch code {
	case walletCodeGatewayUnauthorized:
		return "the payment gateway refused the company's credentials; the company must fix its account"
	case walletCodeAmountNotAllowed:
		return "the payment gateway does not accept this amount"
	case walletCodeGatewayBusy:
		return "the payment gateway is busy; retry in a few minutes"
	case walletCodeOutcomeUnknown:
		return "an earlier attempt with this key never finished; start a new top-up"
	case walletCodeGatewayRejected:
		return "the payment gateway rejected the top-up"
	default:
		return "the payment gateway could not start the top-up"
	}
}

func writeWalletError(w http.ResponseWriter, status int, code, message string, extra map[string]any) {
	body := map[string]any{"error": message, "code": code}
	for key, value := range extra {
		body[key] = value
	}
	writeJSON(w, status, body)
}

func (s HTTPServer) writeWalletInternalError(w http.ResponseWriter, message, installationID string, err error) {
	s.logger().Error(message, "installation_id", installationID, "error", err)
	writeWalletError(w, http.StatusInternalServerError, walletCodeInternalError, "relay store failed", nil)
}

// logWalletTopUp writes one line per top-up event. It never logs the
// checkout URL or the signature.
func (s HTTPServer) logWalletTopUp(installationID string, topUp control.WalletTopUp, event, detail string) {
	level := slog.LevelInfo
	switch {
	case topUp.ErrorCode == walletCodeGatewayUnauthorized:
		level = slog.LevelError
	case topUp.ErrorCode == walletCodeAmountMismatch:
		level = slog.LevelError
	case topUp.Status == control.WalletTopUpFailed:
		level = slog.LevelWarn
	}
	attrs := []any{
		"event", event,
		"installation_id", installationID,
		"top_up_id", topUp.ID,
		"invoice_no", topUp.InvoiceNo,
		"amount", topUp.Amount,
		"status", topUp.Status,
		"test_mode", topUp.TestMode,
	}
	if topUp.ErrorCode != "" {
		attrs = append(attrs, "error_code", topUp.ErrorCode)
	}
	if detail != "" {
		attrs = append(attrs, "detail", truncateRunes(detail, 200))
	}
	s.logger().Log(context.Background(), level, "relay wallet top-up", attrs...)
}

// --- expiry ---

// WalletTopUpExpirer writes off checkouts nobody came back from, so a shop's
// history stops saying "pending" about a payment that is not happening. It
// moves money nowhere: a signed approval arriving after the write-off still
// credits the top-up.
type WalletTopUpExpirer struct {
	Store    control.WalletStore
	TTL      time.Duration
	Interval time.Duration
	Clock    control.Clock
	Logger   *slog.Logger
}

// Sweep runs one pass and returns how many top-ups it expired.
func (e *WalletTopUpExpirer) Sweep(ctx context.Context) (int, error) {
	clock := e.Clock
	if clock == nil {
		clock = control.RealClock{}
	}
	ttl := e.TTL
	if ttl <= 0 {
		ttl = defaultWalletTopUpTTL
	}
	return e.Store.ExpireWalletTopUps(ctx, clock.Now().UTC().Add(-ttl))
}

// Run sweeps on every interval until ctx ends. Several relay nodes may run it
// at once; the update is idempotent.
func (e *WalletTopUpExpirer) Run(ctx context.Context) {
	interval := e.Interval
	if interval <= 0 {
		interval = time.Minute
	}
	logger := e.Logger
	if logger == nil {
		logger = slog.Default()
	}
	sweep := func() {
		expired, err := e.Sweep(ctx)
		if err != nil {
			logger.Warn("wallet top-up expiry sweep failed", "error", err)
			return
		}
		if expired > 0 {
			logger.Info("expired unfinished wallet top-ups", "count", expired)
		}
	}
	sweep()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			sweep()
		}
	}
}
