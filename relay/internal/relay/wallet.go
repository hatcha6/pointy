package relay

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/alerts"
	"pointy/relay/internal/control"
	"pointy/relay/internal/dafa"
	"pointy/relay/internal/ratelimit"
)

// The shop wallet over HTTP. A shop's backend reads its balance and history,
// starts top-ups and sends the payer's code with its installation token. Dafa
// posts a webhook when a payment completes. The operator reads every wallet
// and corrects one by hand, under their own name.
//
// Payment verification is the whole difficulty, and it has two shapes:
//   - OTP methods (Sadad, Edfali, MobiCash, Yussor/Masrafi/Sahara Pay): only
//     the relay can confirm, with the code the payer was texted, so Dafa's
//     answer to that confirm is the proof.
//   - Bank cards: the payer pays on Dafa's page and nothing comes back through
//     the relay. The relay reads the payment back from Dafa — when the app
//     polls, when Dafa's webhook nudges it, and on a background sweep for the
//     payer who closed everything — and only that read is believed. The
//     webhook itself carries no signature.
//
// Either way a proven payment credits the wallet exactly once, a late one
// still credits a top-up the relay had written off, and a payment that does
// not match what was asked for (another amount, the other environment) is
// held for the operator rather than guessed at.

const (
	walletWebhookPrefix = "/v1/wallet/dafa/webhook/"
	walletCurrency      = "LYD"
	// walletConfirmedByGateway marks a top-up Dafa itself proved; an
	// operator's reconciliation is "operator:<name>".
	walletConfirmedByGateway = "dafa"
	// walletTopUpDecimals is two places, although Dafa (and the dinar) take
	// three: the shop's books keep two, and a top-up its expense could not
	// record exactly would leave them a dirham off what left the account.
	walletTopUpDecimals = 2
	// maxWalletOTPAttempts caps the codes tried on one top-up. A wrong code
	// can be typed again; guessing someone else's cannot be ground out.
	maxWalletOTPAttempts = 5

	defaultWalletTopUpTTL       = 30 * time.Minute
	defaultWalletRequestTimeout = 20 * time.Second
	defaultWalletMinTopUp       = "10"
	defaultWalletMaxTopUp       = "5000"
	maxWalletRequestBytes       = 16 << 10
	maxWalletWebhookBytes       = 64 << 10
	maxWalletRequestedByRunes   = 128
	walletRecentTopUps          = 10
	walletRecentEntries         = 10
	walletMinimumStaleAfter     = time.Minute
	// walletVerifyEvery spaces the relay's reads of one payment when the
	// app polls it, so several screens watching one top-up cost one call.
	walletVerifyEvery = 3 * time.Second
)

var defaultWalletQuickAmounts = []string{"50", "100", "200", "500"}

// Error codes of the wallet API. Django maps each to its own Arabic message.
const (
	walletCodeUnavailable          = "wallet_unavailable"
	walletCodeTopUpsUnconfigured   = "topups_unconfigured"
	walletCodeInvalidRequest       = "invalid_request"
	walletCodeInvalidAmount        = "invalid_amount"
	walletCodeUnsupportedMethod    = "unsupported_method"
	walletCodeMethodUnavailable    = "method_unavailable"
	walletCodeInvalidPhone         = "invalid_phone"
	walletCodeInvalidCardNumber    = "invalid_card_number"
	walletCodeInvalidBirthYear     = "invalid_birth_year"
	walletCodePayerRejected        = "payer_rejected"
	walletCodeRateLimited          = "rate_limited"
	walletCodeInFlight             = "in_flight"
	walletCodeNotFound             = "not_found"
	walletCodeInsufficientBalance  = "insufficient_balance"
	walletCodeGatewayUnauthorized  = "gateway_unauthorized"
	walletCodeGatewayRejected      = "gateway_rejected"
	walletCodeAmountNotAllowed     = "amount_not_allowed"
	walletCodeGatewayBusy          = "gateway_busy"
	walletCodeGatewayError         = "gateway_error"
	walletCodeOutcomeUnknown       = "outcome_unknown"
	walletCodeAmountMismatch       = "amount_mismatch"
	walletCodeEnvironmentMismatch  = "environment_mismatch"
	walletCodeCanceled             = "canceled"
	walletCodeDeclined             = "declined"
	walletCodeInvalidOTP           = "invalid_otp"
	walletCodeOTPRejected          = "otp_rejected"
	walletCodeOTPAttemptsExceeded  = "otp_attempts_exceeded"
	walletCodeNotOTPMethod         = "not_otp_method"
	walletCodeTopUpClosed          = "topup_closed"
	walletCodeConfirmUnknown       = "confirm_unknown"
	walletCodeAwaitingGateway      = "awaiting_gateway"
	walletCodeInternalError        = "internal_error"
	walletCodePaymentNotStartedYet = "payment_not_started"
)

// WalletConfig is the company's payment gateway account and the top-up rules.
// The Dafa key lives only here, like the Resala token.
type WalletConfig struct {
	DafaBaseURL string
	DafaAPIKey  string
	// TestMode is the key's environment: a dafa_test_ key only ever makes
	// simulated payments, so every top-up and its credit is marked test money.
	TestMode bool
	// Methods are the method keys offered, in order; empty offers them all.
	Methods []string
	// PublicURL is the relay's public origin, where Dafa's webhook is sent.
	// Empty derives it from the request that starts the top-up.
	PublicURL string
	// MinTopUp and MaxTopUp bound one top-up, in dinars.
	MinTopUp     string
	MaxTopUp     string
	QuickAmounts []string
	// TopUpTTL is how long a top-up stays pending before the expiry sweep
	// writes it off (a payment proven later still credits it).
	TopUpTTL time.Duration
	// TopUpRateLimit is the per-shop guard on starting top-ups.
	TopUpRateLimit ratelimit.Policy
	RequestTimeout time.Duration
	HTTPClient     *http.Client
	// Plans are what the shop pays for from its main wallet, by plan key
	// (control.WalletPlanRemoteAccess, control.WalletPlanAI). A plan missing
	// here, or without a price, is not sold through the wallet.
	Plans map[string]WalletPlan
	// Alerts tells the company's phones about each top-up; nil sends nothing.
	Alerts *alerts.Ntfy
}

// TopUpsConfigured reports whether top-ups can run: a Dafa key whose
// environment the relay can read.
func (c WalletConfig) TopUpsConfigured() bool {
	_, known := dafa.KeyEnvironment(c.DafaAPIKey)
	return known
}

// enabledMethods is what the shop is offered, in order.
func (c WalletConfig) enabledMethods() []walletMethod {
	if !c.TopUpsConfigured() {
		return nil
	}
	if len(c.Methods) == 0 {
		return append([]walletMethod(nil), walletMethods...)
	}
	methods := make([]walletMethod, 0, len(c.Methods))
	for _, key := range c.Methods {
		if method, ok := lookupWalletMethod(key); ok {
			methods = append(methods, method)
		}
	}
	return methods
}

// enabledMethod finds a method the shop may use right now. The retired Plutu
// key — what an app from before Dafa still sends — is served as Dafa's bank
// cards: the same hosted page and the same polling, through another gateway.
func (c WalletConfig) enabledMethod(key string) (walletMethod, bool) {
	if key == "" || key == control.WalletTopUpMethodPlutuLocalBankCards {
		key = control.WalletTopUpMethodDafaMoamalat
	}
	for _, method := range c.enabledMethods() {
		if method.Key == key {
			return method, true
		}
	}
	return walletMethod{}, false
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
	return minimum, maximum
}

func (c WalletConfig) dafaClient() *dafa.Client {
	return dafa.New(dafa.Config{
		BaseURL:    c.DafaBaseURL,
		APIKey:     c.DafaAPIKey,
		HTTPClient: c.HTTPClient,
		Timeout:    c.requestTimeout(),
	})
}

func (s HTTPServer) walletStore() (control.WalletStore, bool) {
	store, ok := s.Store.(control.WalletStore)
	return store, ok
}

// handleWalletRoutes serves everything under /v1/wallet.
func (s HTTPServer) handleWalletRoutes(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case strings.HasPrefix(path, walletWebhookPrefix) && r.Method == http.MethodPost:
		// Dafa's server, about a payment. No token: the webhook URL carries a
		// per-top-up token, and the relay believes only what it reads back.
		if !s.RouteMode.allowsPublic() {
			writeNotFound(w)
			return
		}
		s.handleDafaWebhook(w, r, strings.TrimPrefix(path, walletWebhookPrefix))
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
	topUpID, action := walletTopUpSubpath(path, "/v1/wallet/topups/")
	switch {
	case path == "/v1/wallet" && r.Method == http.MethodGet:
		s.handleWalletSelf(w, r)
	case path == "/v1/wallet/entries" && r.Method == http.MethodGet:
		s.handleWalletEntriesSelf(w, r)
	case path == "/v1/wallet/topups" && r.Method == http.MethodGet:
		s.handleWalletTopUpsSelf(w, r)
	case path == "/v1/wallet/topups" && r.Method == http.MethodPost:
		s.handleWalletTopUpCreate(w, r)
	case path == "/v1/wallet/topups/bank-transfer" && r.Method == http.MethodPost:
		s.handleWalletBankTransferCreate(w, r)
	case path == "/v1/wallet/sms/allocations" && r.Method == http.MethodPost:
		s.handleWalletSMSAllocate(w, r)
	case path == "/v1/wallet/vouchers/allocations" && r.Method == http.MethodPost:
		s.handleWalletVouchersAllocate(w, r)
	case path == "/v1/wallet/subscriptions" && r.Method == http.MethodPost:
		s.handleWalletPlanPurchase(w, r)
	case topUpID != "" && action == "" && r.Method == http.MethodGet:
		s.handleWalletTopUpSelf(w, r, topUpID)
	case topUpID != "" && action == "confirm" && r.Method == http.MethodPost:
		s.handleWalletTopUpConfirm(w, r, topUpID)
	case topUpID != "" && action == "cancel" && r.Method == http.MethodPost:
		s.handleWalletTopUpCancel(w, r, topUpID)
	default:
		writeNotFound(w)
	}
}

// walletTopUpSubpath splits "<prefix><id>[/<action>]".
func walletTopUpSubpath(path, prefix string) (string, string) {
	if !strings.HasPrefix(path, prefix) {
		return "", ""
	}
	rest := strings.Trim(strings.TrimPrefix(path, prefix), "/")
	id, action, _ := strings.Cut(rest, "/")
	if strings.Contains(action, "/") {
		return "", ""
	}
	return id, action
}

func (s HTTPServer) handleWalletAdminRoutes(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	topUpID, action := walletTopUpSubpath(path, "/v1/wallet/admin/topups/")
	switch {
	case path == "/v1/wallet/admin/wallets" && r.Method == http.MethodGet:
		s.handleWalletAdminWallets(w, r)
	case path == "/v1/wallet/admin/entries" && r.Method == http.MethodGet:
		s.handleWalletAdminEntries(w, r)
	case path == "/v1/wallet/admin/entries" && r.Method == http.MethodPost:
		s.handleWalletAdminPostEntry(w, r)
	case path == "/v1/wallet/admin/topups" && r.Method == http.MethodGet:
		s.handleWalletAdminTopUps(w, r)
	case topUpID != "" && action == "" && r.Method == http.MethodGet:
		s.handleWalletAdminTopUp(w, r, topUpID)
	case topUpID != "" && action == "receipt" && r.Method == http.MethodGet:
		s.handleWalletAdminReceipt(w, r, topUpID)
	case topUpID != "" && action == "confirm" && r.Method == http.MethodPost:
		s.handleWalletAdminConfirmTopUp(w, r, topUpID)
	case topUpID != "" && action == "reject" && r.Method == http.MethodPost:
		s.handleWalletAdminRejectTopUp(w, r, topUpID)
	case path == "/v1/wallet/admin/bank-accounts" && (r.Method == http.MethodGet || r.Method == http.MethodPut):
		s.handleWalletAdminBankAccounts(w, r)
	case topUpID != "" && action == "check" && r.Method == http.MethodPost:
		s.handleWalletAdminCheckTopUp(w, r, topUpID)
	case path == "/v1/wallet/admin/config" && r.Method == http.MethodGet:
		s.handleWalletAdminConfig(w, r)
	default:
		writeNotFound(w)
	}
}

// --- a shop's own wallet ---

// handleWalletSelf serves GET /v1/wallet: the balance, the SMS and voucher
// balances, the plans the wallet pays for, what a top-up may be, and the main wallet's latest
// movements, in one call so the app's wallet card needs no second round trip.
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
	sms, err := store.GetWalletAccount(ctx, installation.ID, control.WalletAccountSMS)
	if err != nil {
		s.writeWalletInternalError(w, "sms balance read failed", installation.ID, err)
		return
	}
	cards, err := store.GetWalletAccount(ctx, installation.ID, control.WalletAccountVouchers)
	if err != nil {
		s.writeWalletInternalError(w, "voucher balance read failed", installation.ID, err)
		return
	}
	topUps, err := store.ListWalletTopUps(ctx, control.WalletTopUpFilter{InstallationID: installation.ID, Limit: walletRecentTopUps})
	if err != nil {
		s.writeWalletInternalError(w, "wallet top-up listing failed", installation.ID, err)
		return
	}
	entries, err := store.ListWalletEntries(ctx, control.WalletEntryFilter{
		InstallationID: installation.ID,
		Account:        control.WalletAccountMain,
		Limit:          walletRecentEntries,
	})
	if err != nil {
		s.writeWalletInternalError(w, "wallet ledger listing failed", installation.ID, err)
		return
	}
	options := s.walletTopUpOptions()
	bankOffer := s.walletBankOffer(ctx, installation.ID, topUps)
	options["bank_transfer"] = bankOffer
	if bankOffer["available"] == true {
		// A bank transfer needs no gateway: the wallet can be filled even
		// where Dafa is not set up.
		options["available"] = true
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"balance":        wallet.Balance,
		"currency":       walletCurrency,
		"updated_at":     wallet.UpdatedAt,
		"test_mode":      s.Wallet.TestMode,
		"topups":         options,
		"sms":            s.smsWalletPayload(sms.Balance),
		"vouchers":       s.voucherWalletPayload(cards.Balance),
		"plans":          s.walletPlansPayload(installation, s.clock().Now()),
		"recent_topups":  walletTopUpPayloads(topUps),
		"recent_entries": walletEntryPayloads(entries),
	})
}

// walletTopUpOptions is what the app needs to draw its top-up sheet: each
// method with what it asks of the payer, and the amount rules.
func (s HTTPServer) walletTopUpOptions() map[string]any {
	minimum, maximum := s.Wallet.topUpBounds()
	methods := []map[string]any{}
	for _, method := range s.Wallet.enabledMethods() {
		methods = append(methods, map[string]any{
			"key":        method.Key,
			"gateway":    "dafa",
			"provider":   method.Provider.ID,
			"kind":       method.kind(),
			"payer":      string(method.Provider.Payer),
			"birth_year": method.Provider.BirthYear,
		})
	}
	return map[string]any{
		"available":        len(methods) > 0,
		"methods":          methods,
		"min_amount":       minimum.FloatString(walletTopUpDecimals),
		"max_amount":       maximum.FloatString(walletTopUpDecimals),
		"max_decimals":     walletTopUpDecimals,
		"quick_amounts":    s.Wallet.quickAmounts(),
		"pending_ttl":      int(s.Wallet.topUpTTL().Seconds()),
		"max_otp_attempts": maxWalletOTPAttempts,
		"test_mode":        s.Wallet.TestMode && len(methods) > 0,
	}
}

// handleWalletEntriesSelf serves GET /v1/wallet/entries: one account's
// statement (?account=main, the default, sms or vouchers), newest first, paged by
// ?before=<entry id>.
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
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"kind must be topup, charge, refund, adjustment or transfer", nil)
		return
	}
	account, ok := walletAccountParam(w, query)
	if !ok {
		return
	}
	if account == "" {
		account = control.WalletAccountMain
	}
	entries, err := store.ListWalletEntries(r.Context(), control.WalletEntryFilter{
		InstallationID: installation.ID,
		Account:        account,
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
			"status must be pending, review, paid, rejected, canceled, failed or expired", nil)
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
// while the payer is paying. For a payment that can complete without the
// relay (a bank card on Dafa's page) the poll is also the moment to read it
// back from Dafa. Another shop's top-up is simply not found.
func (s HTTPServer) handleWalletTopUpSelf(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	topUp, ok := s.ownWalletTopUp(w, r, store, installation.ID, id)
	if !ok {
		return
	}
	if s.Wallet.TopUpsConfigured() && walletTopUpWorthChecking(topUp) && s.allowWalletVerify(r.Context(), topUp.ID) {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), s.Wallet.requestTimeout())
		verified, _, err := s.walletGateway(store).verify(ctx, topUp, "poll")
		cancel()
		if err != nil {
			// A blip at Dafa is not a verdict: show what the relay knows.
			s.logger().Warn("reading a wallet payment back failed", "installation_id", installation.ID,
				"top_up_id", topUp.ID, "error", err)
		} else {
			topUp = verified
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"top_up": walletTopUpPayload(topUp)})
}

// ownWalletTopUp loads a top-up the installation owns, or answers 404.
func (s HTTPServer) ownWalletTopUp(
	w http.ResponseWriter,
	r *http.Request,
	store control.WalletStore,
	installationID, id string,
) (control.WalletTopUp, bool) {
	topUp, err := store.GetWalletTopUp(r.Context(), strings.Trim(id, "/"))
	if errors.Is(err, control.ErrWalletTopUpNotFound) || (err == nil && topUp.InstallationID != installationID) {
		writeWalletError(w, http.StatusNotFound, walletCodeNotFound, "top-up not found", nil)
		return control.WalletTopUp{}, false
	}
	if err != nil {
		s.writeWalletInternalError(w, "wallet top-up read failed", installationID, err)
		return control.WalletTopUp{}, false
	}
	return topUp, true
}

// allowWalletVerify spaces the relay's reads of one payment. It fails open:
// a limiter outage must not stop a payment being noticed.
func (s HTTPServer) allowWalletVerify(ctx context.Context, topUpID string) bool {
	if s.RateLimiter == nil {
		return true
	}
	decision, err := s.RateLimiter.Allow(ctx, "wallet-verify:"+topUpID, ratelimit.Policy{Limit: 1, Window: walletVerifyEvery})
	return err != nil || decision.Allowed
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
	account, ok := walletAccountParam(w, r.URL.Query())
	if !ok {
		return
	}
	wallets, err := store.ListWallets(r.Context(), account, limit)
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
		"total":   control.SumWalletAmounts(balances),
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
	account, ok := walletAccountParam(w, query)
	if !ok {
		return
	}
	entries, err := store.ListWalletEntries(r.Context(), control.WalletEntryFilter{
		InstallationID: strings.TrimSpace(query.Get("installation_id")),
		Account:        account,
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
	Account        string `json:"account"`
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
	if kind == control.WalletEntryTransfer {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"a transfer has two sides and comes only from the shop moving its money; use an adjustment", nil)
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
		Account:        request.Account,
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
		"account", entry.Account,
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
			"status must be pending, review, paid, rejected, canceled, failed or expired", nil)
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
	// Amount is what actually arrived, for a bank transfer whose sum differs
	// from what the shop declared. Empty credits the declared amount.
	Amount string `json:"amount"`
}

// handleWalletAdminConfirmTopUp serves POST /v1/wallet/admin/topups/{id}/confirm:
// the operator crediting by hand a payment Dafa will not report as paid — the
// payer's bank statement shows it, say. The operator checks Dafa's dashboard
// first (wallet check reads it for them); this credits the top-up once.
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
	if existing, err := store.GetWalletTopUp(r.Context(), id); err == nil &&
		existing.Method == control.WalletTopUpMethodBankTransfer {
		s.confirmBankTransfer(w, r, store, existing, request, actor)
		return
	}
	if actor == "" || reason == "" || transactionID == "" {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"provider_transaction_id, actor and reason are required: check the gateway's dashboard first", nil)
		return
	}
	topUp, applied, err := store.SettleWalletTopUp(r.Context(), id, control.WalletTopUpSettlement{
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
	keyTest, keyKnown := dafa.KeyEnvironment(s.Wallet.DafaAPIKey)
	environment := ""
	if keyKnown {
		environment = "live"
		if keyTest {
			environment = "test"
		}
	}
	options["test_mode"] = s.Wallet.TestMode
	options["dafa_base_url"] = dafaBaseURL(s.Wallet.DafaBaseURL)
	options["api_key_set"] = strings.TrimSpace(s.Wallet.DafaAPIKey) != ""
	options["key_environment"] = environment
	options["public_url"] = strings.TrimSpace(s.Wallet.PublicURL)
	options["webhook_base"] = s.walletWebhookBase(r)
	options["request_timeout"] = s.Wallet.requestTimeout().String()
	options["rate_limit"] = s.Wallet.TopUpRateLimit.String()
	_, hasStore := s.walletStore()
	options["store_supports_wallets"] = hasStore
	options["sms_price"] = control.FormatWalletAmount(s.SMS.price())
	options["plans"] = s.walletPlansConfig()
	writeJSON(w, http.StatusOK, options)
}

func dafaBaseURL(configured string) string {
	if trimmed := strings.TrimRight(strings.TrimSpace(configured), "/"); trimmed != "" {
		return trimmed
	}
	return dafa.DefaultBaseURL
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

// walletAccountParam reads ?account=; empty is left for the caller to read.
func walletAccountParam(w http.ResponseWriter, query url.Values) (string, bool) {
	raw := strings.TrimSpace(query.Get("account"))
	if raw == "" {
		return "", true
	}
	account := control.NormalizeWalletAccount(raw)
	if !control.ValidWalletAccount(account) {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "account must be main, sms or vouchers", nil)
		return "", false
	}
	return account, true
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

// walletTopUpPayload is a top-up as the shop sees it. The payment page is
// only handed out while it can still be paid, and the code count only while a
// code can still be sent.
func walletTopUpPayload(topUp control.WalletTopUp) map[string]any {
	payload := map[string]any{
		"id":                      topUp.ID,
		"method":                  topUp.Method,
		"amount":                  topUp.Amount,
		"status":                  topUp.Status,
		"invoice_no":              topUp.InvoiceNo,
		"provider_transaction_id": topUp.ProviderTransactionID,
		"requested_by":            topUp.RequestedBy,
		"payer_hint":              topUp.PayerHint,
		"test_mode":               topUp.TestMode,
		"error_code":              topUp.ErrorCode,
		"error_detail":            topUp.ErrorDetail,
		"entry_id":                topUp.EntryID,
		"confirmed_by":            topUp.ConfirmedBy,
		"created_at":              topUp.CreatedAt,
		"updated_at":              topUp.UpdatedAt,
		"paid_at":                 topUp.PaidAt,
	}
	method, known := lookupWalletMethod(topUp.Method)
	if transfer := topUp.Transfer; transfer != nil {
		payload["kind"] = walletKindBankTransfer
		payload["transfer"] = map[string]any{
			"channel":         transfer.Channel,
			"payer_bank":      transfer.PayerBank,
			"payer_account":   transfer.PayerAccount,
			"payer_iban":      transfer.PayerIBAN,
			"to_account":      transfer.ToAccount,
			"declared_amount": transfer.DeclaredAmount,
			"receipt_name":    transfer.Receipt.Name,
			"receipt_type":    transfer.Receipt.ContentType,
		}
	} else if known {
		payload["kind"] = method.kind()
	} else if topUp.Method == control.WalletTopUpMethodPlutuLocalBankCards {
		payload["kind"] = walletKindHostedPage
	}
	if topUp.Status == control.WalletTopUpPending {
		if topUp.CheckoutURL != "" {
			payload["checkout_url"] = topUp.CheckoutURL
		}
		if known && method.kind() == walletKindOTP {
			payload["otp_attempts_left"] = max(0, maxWalletOTPAttempts-topUp.OTPAttempts)
		}
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
		"account":       control.NormalizeWalletAccount(entry.Account),
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

// logWalletTopUp writes one line per top-up event. It never logs the payment
// page, the payer's number, a code or a webhook token.
func (s HTTPServer) logWalletTopUp(installationID string, topUp control.WalletTopUp, event, detail string) {
	logWalletTopUpEvent(s.logger(), installationID, topUp, event, detail)
	alertWalletTopUp(s.Wallet.Alerts, topUp, event, detail)
}

func logWalletTopUpEvent(logger *slog.Logger, installationID string, topUp control.WalletTopUp, event, detail string) {
	level := slog.LevelInfo
	switch topUp.ErrorCode {
	case walletCodeGatewayUnauthorized, walletCodeAmountMismatch, walletCodeEnvironmentMismatch:
		level = slog.LevelError
	default:
		if topUp.Status == control.WalletTopUpFailed {
			level = slog.LevelWarn
		}
	}
	attrs := []any{
		"event", event,
		"installation_id", installationID,
		"top_up_id", topUp.ID,
		"invoice_no", topUp.InvoiceNo,
		"method", topUp.Method,
		"payment_id", topUp.ProviderTransactionID,
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
	logger.Log(context.Background(), level, "relay wallet top-up", attrs...)
}

// --- expiry ---

// WalletTopUpExpirer writes off top-ups nobody finished, so a shop's history
// stops saying "pending" about a payment that is not happening. It moves
// money nowhere: a payment Dafa proves after the write-off still credits it.
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
