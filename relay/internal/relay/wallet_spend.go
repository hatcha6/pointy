package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"pointy/relay/internal/control"
)

// Spending the wallet. A shop moves money from its main wallet into its SMS
// balance, which every message is then paid from, and into its voucher
// balance, which every card its till sells is paid from; and pays for its plans —
// remote access, the assistant — from the main wallet, a period at a time.
// Nothing here talks to the payment gateway: the money is already the
// company's, held for the shop.

const (
	// maxWalletPlanPeriods bounds one purchase: a year of monthly periods.
	maxWalletPlanPeriods = 12
	// defaultWalletPlanDays is a period when the plan does not set one.
	defaultWalletPlanDays = 30
	// maxWalletSpendKeyRunes leaves room for the ledger's own prefixes on the
	// shop's key ("transfer:…:in").
	maxWalletSpendKeyRunes = 100
)

// Error codes of the spending endpoints, beside the wallet's own.
const (
	walletCodePlanUnavailable = "plan_unavailable"
	walletCodePlanIncluded    = "plan_included"
	walletCodeInvalidPeriods  = "invalid_periods"
)

// WalletPlan is what one period of a plan costs and how long it lasts.
type WalletPlan struct {
	// Price is in dinars, at most three places. A plan without a positive
	// price is not sold through the wallet.
	Price string
	// Days is the length of one period; 0 means defaultWalletPlanDays.
	Days int
}

func (p WalletPlan) price() (*big.Rat, bool) {
	price, err := control.ParseWalletAmount(p.Price)
	if err != nil || price.Sign() <= 0 {
		return nil, false
	}
	return price, true
}

func (p WalletPlan) days() int {
	if p.Days > 0 {
		return p.Days
	}
	return defaultWalletPlanDays
}

// walletPlanKeys are the plans the app shows, in the order it shows them.
var walletPlanKeys = []string{control.WalletPlanRemoteAccess, control.WalletPlanAI}

// soldPlan returns a plan the wallet sells right now.
func (c WalletConfig) soldPlan(key string) (WalletPlan, *big.Rat, bool) {
	plan, ok := c.Plans[key]
	if !ok || !control.ValidWalletPlan(key) {
		return WalletPlan{}, nil, false
	}
	price, ok := plan.price()
	return plan, price, ok
}

// walletPlansPayload is every plan as the shop sees it: whether it runs and
// until when, and — when the wallet sells it — what a period costs.
func (s HTTPServer) walletPlansPayload(installation control.Installation, now time.Time) []map[string]any {
	plans := make([]map[string]any, 0, len(walletPlanKeys))
	for _, key := range walletPlanKeys {
		coverage := installation.PlanCoverage(key, now)
		payload := map[string]any{
			"key":         key,
			"available":   false,
			"active":      coverage.Active,
			"until":       coverage.Until,
			"included":    coverage.Indefinite,
			"max_periods": maxWalletPlanPeriods,
		}
		if plan, price, ok := s.Wallet.soldPlan(key); ok {
			payload["available"] = !coverage.Indefinite
			payload["price"] = control.FormatWalletAmount(price)
			payload["period_days"] = plan.days()
		}
		plans = append(plans, payload)
	}
	return plans
}

// walletPlansConfig is the operator's view of what the wallet sells.
func (s HTTPServer) walletPlansConfig() map[string]any {
	keys := make([]string, 0, len(s.Wallet.Plans))
	for key := range s.Wallet.Plans {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	plans := map[string]any{}
	for _, key := range keys {
		plan, price, ok := s.Wallet.soldPlan(key)
		if !ok {
			continue
		}
		plans[key] = map[string]any{"price": control.FormatWalletAmount(price), "period_days": plan.days()}
	}
	return plans
}

type walletSpendRequest struct {
	Amount         json.RawMessage `json:"amount"`
	Plan           string          `json:"plan"`
	Periods        int             `json:"periods"`
	IdempotencyKey string          `json:"idempotency_key"`
	RequestedBy    string          `json:"requested_by"`
}

// decodeWalletSpend reads a spending request and checks the parts every one
// shares. It has already answered when ok is false.
func decodeWalletSpend(w http.ResponseWriter, r *http.Request) (walletSpendRequest, bool) {
	var request walletSpendRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxWalletRequestBytes)).Decode(&request); err != nil {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "invalid request body", nil)
		return walletSpendRequest{}, false
	}
	request.Plan = strings.ToLower(strings.TrimSpace(request.Plan))
	request.IdempotencyKey = strings.TrimSpace(request.IdempotencyKey)
	request.RequestedBy = strings.TrimSpace(request.RequestedBy)
	if request.IdempotencyKey == "" || utf8.RuneCountInString(request.IdempotencyKey) > maxWalletSpendKeyRunes {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			fmt.Sprintf("idempotency_key is required (at most %d characters)", maxWalletSpendKeyRunes), nil)
		return walletSpendRequest{}, false
	}
	if utf8.RuneCountInString(request.RequestedBy) > maxWalletRequestedByRunes {
		request.RequestedBy = string([]rune(request.RequestedBy)[:maxWalletRequestedByRunes])
	}
	return request, true
}

// handleWalletSMSAllocate serves POST /v1/wallet/sms/allocations: the shop
// moves money from its main wallet into its SMS balance. Both sides move in
// one step, and a retry with the same key returns the first transfer.
func (s HTTPServer) handleWalletSMSAllocate(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	request, ok := decodeWalletSpend(w, r)
	if !ok {
		return
	}
	amount, rejection := s.validateSMSAllocation(request.Amount)
	if rejection != "" {
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodeInvalidAmount, rejection, map[string]any{
			"min_amount":   control.FormatWalletAmount(s.SMS.price()),
			"max_decimals": 3,
		})
		return
	}
	ctx := r.Context()
	transfer, created, err := store.TransferWalletFunds(ctx, control.WalletTransfer{
		InstallationID: installation.ID,
		From:           control.WalletAccountMain,
		To:             control.WalletAccountSMS,
		Amount:         control.FormatWalletAmount(amount),
		IdempotencyKey: request.IdempotencyKey,
		Actor:          request.RequestedBy,
	})
	if !s.answerWalletSpendError(w, installation.ID, "sms allocation", err) {
		return
	}
	balances, ok := s.walletBalances(w, ctx, store, installation.ID)
	if !ok {
		return
	}
	s.logger().Info("wallet money moved to the sms balance",
		"installation_id", installation.ID,
		"amount", transfer.In.Amount,
		"requested_by", request.RequestedBy,
		"replayed", !created)
	status := http.StatusCreated
	if !created {
		status = http.StatusOK
	}
	writeJSON(w, status, map[string]any{
		"balance":  balances.main,
		"sms":      s.smsWalletPayload(balances.sms),
		"transfer": map[string]any{"out": walletEntryPayload(transfer.Out), "in": walletEntryPayload(transfer.In)},
		"replayed": !created,
	})
}

// validateSMSAllocation accepts a JSON string or number of dinars with at most
// three places, at least the price of one message. It returns the reason for
// a refusal, or "".
func (s HTTPServer) validateSMSAllocation(raw json.RawMessage) (*big.Rat, string) {
	text := strings.TrimSpace(string(raw))
	if unquoted, err := strconv.Unquote(text); err == nil {
		text = strings.TrimSpace(unquoted)
	}
	amount, err := control.ParseWalletAmount(text)
	if err != nil || amount.Sign() <= 0 {
		return nil, "amount must be a positive number of dinars with at most three places"
	}
	if amount.Cmp(s.SMS.price()) < 0 {
		return nil, "amount must pay for at least one message"
	}
	return amount, ""
}

// minVoucherAllocation is the smallest move into the voucher balance.
var minVoucherAllocation = big.NewRat(1, 1)

// handleWalletVouchersAllocate serves POST /v1/wallet/vouchers/allocations:
// the shop moves money from its main wallet into its voucher balance, which
// every card its till sells is then paid from — the SMS balance's twin. Both
// sides move in one step, and a retry with the same key returns the first
// transfer.
func (s HTTPServer) handleWalletVouchersAllocate(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	request, ok := decodeWalletSpend(w, r)
	if !ok {
		return
	}
	if !s.Vouchers.Configured() {
		writeWalletError(w, http.StatusServiceUnavailable, voucherCodeUnconfigured, "this relay sells no cards", nil)
		return
	}
	amount, rejection := validateVoucherAllocation(request.Amount)
	if rejection != "" {
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodeInvalidAmount, rejection, map[string]any{
			"min_amount":   control.FormatWalletAmount(minVoucherAllocation),
			"max_decimals": 2,
		})
		return
	}
	ctx := r.Context()
	transfer, created, err := store.TransferWalletFunds(ctx, control.WalletTransfer{
		InstallationID: installation.ID,
		From:           control.WalletAccountMain,
		To:             control.WalletAccountVouchers,
		Amount:         control.FormatWalletAmount(amount),
		IdempotencyKey: request.IdempotencyKey,
		Actor:          request.RequestedBy,
	})
	if !s.answerWalletSpendError(w, installation.ID, "voucher allocation", err) {
		return
	}
	balances, ok := s.walletBalances(w, ctx, store, installation.ID)
	if !ok {
		return
	}
	s.logger().Info("wallet money moved to the voucher balance",
		"installation_id", installation.ID,
		"amount", transfer.In.Amount,
		"requested_by", request.RequestedBy,
		"replayed", !created)
	status := http.StatusCreated
	if !created {
		status = http.StatusOK
	}
	writeJSON(w, status, map[string]any{
		"balance":  balances.main,
		"vouchers": s.voucherWalletPayload(balances.vouchers),
		"transfer": map[string]any{"out": walletEntryPayload(transfer.Out), "in": walletEntryPayload(transfer.In)},
		"replayed": !created,
	})
}

// validateVoucherAllocation accepts a JSON string or number of dinars with at
// most two places — the shop books the move, and its books keep two — and at
// least minVoucherAllocation. It returns the reason for a refusal, or "".
func validateVoucherAllocation(raw json.RawMessage) (*big.Rat, string) {
	text := strings.TrimSpace(string(raw))
	if unquoted, err := strconv.Unquote(text); err == nil {
		text = strings.TrimSpace(unquoted)
	}
	amount, err := control.ParseWalletAmount(text)
	if err != nil || amount.Sign() <= 0 || control.WalletAmountDecimals(text) > 2 {
		return nil, "amount must be a positive number of dinars with at most two places"
	}
	if amount.Cmp(minVoucherAllocation) < 0 {
		return nil, "amount must be at least one dinar"
	}
	return amount, ""
}

// handleWalletPlanPurchase serves POST /v1/wallet/subscriptions: the shop pays
// for one or more periods of a plan from its main wallet. The periods start
// where its current coverage ends, so renewing early loses nothing.
func (s HTTPServer) handleWalletPlanPurchase(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	request, ok := decodeWalletSpend(w, r)
	if !ok {
		return
	}
	plan, price, sold := s.Wallet.soldPlan(request.Plan)
	if !sold {
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodePlanUnavailable,
			fmt.Sprintf("plan %q is not sold through the wallet", request.Plan), nil)
		return
	}
	if request.Periods == 0 {
		request.Periods = 1
	}
	if request.Periods < 1 || request.Periods > maxWalletPlanPeriods {
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodeInvalidPeriods,
			fmt.Sprintf("periods must be 1 to %d", maxWalletPlanPeriods), map[string]any{"max_periods": maxWalletPlanPeriods})
		return
	}
	total := new(big.Rat).Mul(price, new(big.Rat).SetInt64(int64(request.Periods)))
	ctx := r.Context()
	result, created, err := store.PurchaseWalletPlan(ctx, control.WalletPlanPurchase{
		InstallationID: installation.ID,
		Plan:           request.Plan,
		Amount:         control.FormatWalletAmount(total),
		Days:           plan.days() * request.Periods,
		IdempotencyKey: request.IdempotencyKey,
		RequestedBy:    request.RequestedBy,
	})
	if errors.Is(err, control.ErrWalletPlanIncluded) {
		writeWalletError(w, http.StatusConflict, walletCodePlanIncluded,
			"the subscription already includes this plan with no end date", nil)
		return
	}
	if !s.answerWalletSpendError(w, installation.ID, "plan purchase", err) {
		return
	}
	balance, err := store.GetWallet(ctx, installation.ID)
	if err != nil {
		s.writeWalletInternalError(w, "wallet read failed", installation.ID, err)
		return
	}
	now := s.clock().Now()
	var bought map[string]any
	for _, payload := range s.walletPlansPayload(result.Installation, now) {
		if payload["key"] == request.Plan {
			bought = payload
		}
	}
	s.logger().Info("plan paid from the wallet",
		"installation_id", installation.ID,
		"plan", request.Plan,
		"periods", request.Periods,
		"amount", result.Entry.Amount,
		"until", bought["until"],
		"requested_by", request.RequestedBy,
		"replayed", !created)
	status := http.StatusCreated
	if !created {
		status = http.StatusOK
	}
	writeJSON(w, status, map[string]any{
		"plan":     bought,
		"balance":  balance.Balance,
		"entry":    walletEntryPayload(result.Entry),
		"replayed": !created,
	})
}

// answerWalletSpendError answers the refusals every spend shares and reports
// whether the caller may go on.
func (s HTTPServer) answerWalletSpendError(w http.ResponseWriter, installationID, what string, err error) bool {
	var balanceErr *control.WalletBalanceError
	switch {
	case err == nil:
		return true
	case errors.As(err, &balanceErr):
		writeWalletError(w, http.StatusConflict, walletCodeInsufficientBalance, "the wallet cannot cover this", map[string]any{
			"balance": balanceErr.Balance,
			"amount":  balanceErr.Amount,
		})
	case errors.Is(err, control.ErrNotFound):
		writeWalletError(w, http.StatusNotFound, walletCodeNotFound, "installation not found", nil)
	default:
		s.writeWalletInternalError(w, what+" failed", installationID, err)
	}
	return false
}

type walletBalances struct {
	main     string
	sms      string
	vouchers string
}

// walletBalances reads all of a shop's balances. It has already answered
// when ok is false.
func (s HTTPServer) walletBalances(
	w http.ResponseWriter,
	ctx context.Context,
	store control.WalletStore,
	installationID string,
) (walletBalances, bool) {
	main, err := store.GetWallet(ctx, installationID)
	if err != nil {
		s.writeWalletInternalError(w, "wallet read failed", installationID, err)
		return walletBalances{}, false
	}
	sms, err := store.GetWalletAccount(ctx, installationID, control.WalletAccountSMS)
	if err != nil {
		s.writeWalletInternalError(w, "sms balance read failed", installationID, err)
		return walletBalances{}, false
	}
	cards, err := store.GetWalletAccount(ctx, installationID, control.WalletAccountVouchers)
	if err != nil {
		s.writeWalletInternalError(w, "voucher balance read failed", installationID, err)
		return walletBalances{}, false
	}
	return walletBalances{main: main.Balance, sms: sms.Balance, vouchers: cards.Balance}, true
}
