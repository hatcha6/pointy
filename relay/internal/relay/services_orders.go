package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"pointy/relay/internal/control"
	"pointy/relay/internal/services"
	"pointy/relay/internal/vouchers"
)

// An order for direct top-up or a bill payment is a purchase on the same ledger as
// a card, with the same guarantees: the price is taken from the shop's voucher
// balance in the same step as the claim, BEFORE the supplier is called; the
// supplier is called exactly once; an answer that leaves it open whether the money
// was spent holds the price until the supplier's own records say (and a bill that
// Reloadly accepted and has not finished stays held, for as long as Reloadly says
// it is processing); a refusal gives the price back. See handleVoucherPurchase.

// serviceCallSlack is what a supplier call may overrun its budget by before its
// context ends.
const serviceCallSlack = 5 * time.Second

// serviceOrderRequest is POST /v1/services/orders.
type serviceOrderRequest struct {
	Kind           string          `json:"kind"`
	OperatorID     int64           `json:"operator_id"`
	BillerID       int64           `json:"biller_id"`
	Country        string          `json:"country"`
	Phone          string          `json:"phone"`
	Account        string          `json:"account"`
	InvoiceID      *string         `json:"invoice_id"`
	Amount         json.RawMessage `json:"amount"`
	AmountCurrency string          `json:"amount_currency"`
	AmountID       *int64          `json:"amount_id"`
	IdempotencyKey string          `json:"idempotency_key"`
	MaxUnitPrice   json.RawMessage `json:"max_unit_price"`
	RequestedBy    string          `json:"requested_by"`
	maxUnitPrice   *big.Rat
}

func (o serviceOrderRequest) order() services.OrderRequest {
	order := services.OrderRequest{
		Kind:           strings.ToLower(strings.TrimSpace(o.Kind)),
		OperatorID:     o.OperatorID,
		BillerID:       o.BillerID,
		Country:        o.Country,
		Phone:          o.Phone,
		Account:        o.Account,
		Amount:         jsonAmount(o.Amount),
		AmountCurrency: o.AmountCurrency,
	}
	if o.InvoiceID != nil {
		order.InvoiceID = *o.InvoiceID
	}
	if o.AmountID != nil && *o.AmountID > 0 {
		order.AmountID = *o.AmountID
	}
	return order
}

func decodeServiceOrder(w http.ResponseWriter, r *http.Request) (serviceOrderRequest, bool) {
	var request serviceOrderRequest
	if err := decodeServiceBody(w, r, maxServiceRequestBytes, &request); err != nil {
		return serviceOrderRequest{}, false
	}
	request.IdempotencyKey = strings.TrimSpace(request.IdempotencyKey)
	request.RequestedBy = strings.TrimSpace(request.RequestedBy)
	if utf8.RuneCountInString(request.RequestedBy) > maxWalletRequestedByRunes {
		request.RequestedBy = string([]rune(request.RequestedBy)[:maxWalletRequestedByRunes])
	}
	if request.IdempotencyKey == "" || utf8.RuneCountInString(request.IdempotencyKey) > maxVoucherKeyRunes {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest,
			fmt.Sprintf("idempotency_key is required (at most %d characters)", maxVoucherKeyRunes), nil)
		return serviceOrderRequest{}, false
	}
	if raw := jsonAmount(request.MaxUnitPrice); raw != "" {
		value, err := control.ParseWalletAmount(raw)
		if err != nil || value.Sign() <= 0 {
			writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "max_unit_price must be a positive amount", nil)
			return serviceOrderRequest{}, false
		}
		request.maxUnitPrice = value
	}
	return request, true
}

// serviceStaleAfter is when a pending order nobody finished is taken for one
// whose relay died mid-call: the supplier call and the wait for it to settle, and
// a margin.
func (s HTTPServer) serviceStaleAfter() time.Duration {
	return max(voucherMinimumStaleAfter, s.Services.RequestTimeout()+s.Services.SettleWait()+30*time.Second)
}

// handleServiceOrder serves POST /v1/services/orders: one shop places one order.
func (s HTTPServer) handleServiceOrder(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireServices(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	request, ok := decodeServiceOrder(w, r)
	if !ok {
		return
	}
	order := request.order()
	order.InstallationID = installation.ID
	ctx := r.Context()

	// What the request asks for, as the ledger would name it: a key that already
	// names something else is refused, one that names this is replayed.
	itemKey, refusal := services.ItemKeyOf(order)
	if refusal != nil {
		writeRefusal(w, refusal)
		return
	}
	if existing, found, err := store.FindVoucherPurchaseByKey(ctx, installation.ID, request.IdempotencyKey); err != nil {
		s.writeVoucherInternalError(w, installation.ID, "service order lookup failed", err)
		return
	} else if found {
		s.replayServiceRequest(w, r, store, existing, order, itemKey)
		return
	}
	if s.enforceVoucherRateLimit(w, r, installation.ID) {
		return
	}

	in, err := s.servicePricing(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, installation.ID, "services pricing read failed", err)
		return
	}
	prepared, refusal := s.Services.PrepareOrder(ctx, in, order)
	if refusal != nil {
		writeRefusal(w, refusal)
		return
	}
	if request.maxUnitPrice != nil && prepared.Prices.Unit.Cmp(request.maxUnitPrice) > 0 {
		writeSMSError(w, http.StatusConflict, services.CodePriceChanged,
			"this costs more than the shop was quoted", map[string]any{"unit_price": vouchers.FormatDinars(prepared.Prices.Unit)})
		return
	}

	claim, created, err := store.BeginVoucherPurchase(ctx, control.VoucherPurchase{
		InstallationID: installation.ID,
		IdempotencyKey: request.IdempotencyKey,
		Kind:           prepared.Kind,
		ItemKey:        prepared.ItemKey,
		BrandKey:       prepared.BrandKey,
		ItemName:       prepared.Name,
		Quantity:       1,
		Target:         prepared.Target,
		Details:        prepared.Details,
		UnitPrice:      control.FormatWalletAmount(prepared.Prices.Unit),
		Supplier:       s.Services.Supplier(),
		SupplierRef:    prepared.SupplierRef,
		// Not real money: the fake supplier's, or Reloadly's sandbox (which is
		// really called, with fake money).
		TestMode:    s.Services.TestOrSandbox(),
		RequestedBy: request.RequestedBy,
	})
	var balanceErr *control.WalletBalanceError
	switch {
	case errors.As(err, &balanceErr):
		writeSMSError(w, http.StatusPaymentRequired, voucherCodeInsufficientBalance,
			"the voucher balance cannot pay for this", map[string]any{
				"balance": control.NormalizeWalletAmount(balanceErr.Balance),
				"amount":  control.NormalizeWalletAmount(balanceErr.Amount),
			})
		return
	case errors.Is(err, control.ErrNotFound):
		writeSMSError(w, http.StatusNotFound, voucherCodeNotFound, "installation not found", nil)
		return
	case err != nil:
		s.writeVoucherInternalError(w, installation.ID, "service order claim failed", err)
		return
	case !created:
		s.replayServiceRequest(w, r, store, claim, order, itemKey)
		return
	}

	// --- past this line the supplier may carry the order out, whatever happens ---
	executor, ok := s.Services.ExecutorFor(claim.Supplier)
	if !ok {
		// Cannot happen for a configured service; the claim is left to the reconciler.
		s.logger().Error("no executor for a claimed service order", "purchase_id", claim.ID, "supplier", claim.Supplier)
		writeSMSError(w, http.StatusServiceUnavailable, serviceCodeUnavailable, "the order could not be placed", nil)
		return
	}
	detached := context.WithoutCancel(ctx)
	callCtx, cancel := context.WithTimeout(detached, s.Services.RequestTimeout()+s.Services.SettleWait()+serviceCallSlack)
	var (
		result  services.Result
		execErr error
	)
	switch prepared.Kind {
	case services.KindAirtime:
		call := *prepared.Airtime
		call.ClientRef = claim.ID
		result, execErr = executor.Airtime(callCtx, call)
	default:
		call := *prepared.Bill
		call.ClientRef = claim.ID
		result, execErr = executor.Bill(callCtx, call)
	}
	cancel()
	secrets := append(prepared.Secrets(), order.Phone, order.Account, order.InvoiceID)
	outcome := serviceOutcome(prepared.Kind, result, execErr, secrets)
	finished, applied, err := store.FinishVoucherPurchase(detached, claim.ID, outcome)
	if err != nil {
		// The supplier's answer is in hand but could not be written down. The
		// row stays pending, so the reconciler finds the order again; the shop
		// gets the receipt now either way.
		s.logger().Error("recording a service order failed",
			"installation_id", installation.ID, "purchase_id", claim.ID, "kind", prepared.Kind,
			"supplier_order_id", outcome.SupplierOrderID, "status", outcome.Status, "error", err)
		finished = claim
		if outcome.Status == control.VoucherPurchaseSucceeded {
			finished.Status = control.VoucherPurchaseSucceeded
		}
	} else if !applied {
		s.logger().Warn("a service order was settled before its own answer was recorded",
			"purchase_id", claim.ID, "status", finished.Status)
	}
	s.logServiceOrder(installation.ID, finished, outcome, execErr, secrets)
	if outcome.Status == control.VoucherPurchaseSucceeded {
		s.auditServiceDelivery(finished, prepared, result, in.Settings)
	}
	balance := s.voucherBalance(detached, installation.ID)
	var receipt map[string]string
	if result.Status == vouchers.StatusSucceeded {
		receipt = result.Receipt
	}
	switch {
	case finished.Status == control.VoucherPurchaseSucceeded && len(receipt) > 0:
		writeJSON(w, http.StatusCreated, serviceOrderBody(finished, receipt, false, balance, false))
	case finished.Status == control.VoucherPurchaseFailed:
		writeJSON(w, http.StatusBadGateway, serviceFailureBody(finished, balance, false))
	default:
		// Carried out or not, or carried out and not yet readable: the price stays
		// where it is.
		writeJSON(w, http.StatusAccepted, serviceOrderBody(finished, receipt, true, balance, false))
	}
}

// serviceOutcome turns a supplier's answer into the ledger's outcome. A failure
// is definite only when the supplier's own error says nothing was done; an order
// the supplier took and has not finished is held, with its id, for the reconciler.
//
// Whatever the supplier says is redacted of the order's secrets (secrets): the
// ledger, the log and the answer to the shop never hold the full number, however
// the supplier's sentence came to echo it.
func serviceOutcome(kind string, result services.Result, err error, secrets []string) control.VoucherPurchaseOutcome {
	if err != nil {
		var failure *vouchers.Failure
		if !errors.As(err, &failure) {
			failure = &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: err.Error()}
		}
		return control.VoucherPurchaseOutcome{
			Status:          control.VoucherPurchaseFailed,
			SupplierOrderID: services.OrderRef(kind, failure.OrderID),
			ErrorCode:       failure.Code,
			ErrorDetail:     services.Redact(failure.Detail, secrets...),
			Uncertain:       !failure.Definite,
		}
	}
	orderID := services.OrderRef(kind, result.OrderID)
	switch result.Status {
	case vouchers.StatusSucceeded:
		return control.VoucherPurchaseOutcome{
			Status:           control.VoucherPurchaseSucceeded,
			SupplierOrderID:  orderID,
			SupplierCost:     result.CostUSD,
			SupplierCurrency: "USD",
		}
	case vouchers.StatusFailed:
		detail := services.Redact(result.Message, secrets...)
		if detail == "" {
			detail = "the supplier did not carry out the order"
		}
		return control.VoucherPurchaseOutcome{
			Status:          control.VoucherPurchaseFailed,
			SupplierOrderID: orderID,
			ErrorCode:       vouchers.FailureRefused,
			ErrorDetail:     detail,
		}
	}
	return control.VoucherPurchaseOutcome{
		Status:          control.VoucherPurchaseFailed,
		SupplierOrderID: orderID,
		ErrorCode:       vouchers.FailureUnknown,
		ErrorDetail:     "the supplier accepted the order and has not finished it",
		Uncertain:       true,
	}
}

// auditServiceDelivery notes what a sale that went through says about its price
// and its promise: a top-up that credited less than the customer was quoted, or an
// order that cost the company more than the shop was charged. Neither stops the
// sale; both are counted and logged for the operator.
func (s HTTPServer) auditServiceDelivery(
	purchase control.VoucherPurchase,
	prepared *services.PreparedOrder,
	result services.Result,
	settings vouchers.Settings,
) {
	if prepared.Kind == services.KindAirtime && result.Receipt != nil {
		// The delivered figure is the supplier's own, as it wrote it (any number of
		// decimals): compared exactly, not through the wire's five-decimal parser.
		promised, okPromised := new(big.Rat).SetString(strings.TrimSpace(prepared.Receive.Amount))
		delivered, okDelivered := new(big.Rat).SetString(strings.TrimSpace(result.Receipt[services.ReceiptDeliveredAmount]))
		if okPromised && okDelivered &&
			strings.EqualFold(result.Receipt[services.ReceiptDeliveredCurrency], prepared.Receive.Currency) &&
			delivered.Cmp(promised) < 0 {
			s.Services.NoteShortDelivery()
			s.logger().Warn("a top-up credited less than the customer was quoted",
				"purchase_id", purchase.ID, "item", purchase.ItemKey, "quoted", prepared.Receive.Amount,
				"delivered", result.Receipt[services.ReceiptDeliveredAmount], "currency", prepared.Receive.Currency)
		}
	}
	if cost, ok := new(big.Rat).SetString(strings.TrimSpace(result.CostUSD)); ok && cost.Sign() > 0 {
		if actual, ok := settings.USDToLYD(cost); ok && actual.Cmp(prepared.Prices.Unit) > 0 {
			s.logger().Error("a service was sold below what it cost the company",
				"purchase_id", purchase.ID, "item", purchase.ItemKey,
				"charged", vouchers.FormatDinars(prepared.Prices.Unit), "cost", vouchers.FormatDinars(actual),
				"order_cost_usd", result.CostUSD)
		}
	}
}

// replayServiceRequest answers a request whose key already has a row: the row of
// the same thing is replayed, the row of anything else is a key reused.
func (s HTTPServer) replayServiceRequest(
	w http.ResponseWriter,
	r *http.Request,
	store control.VoucherStore,
	existing control.VoucherPurchase,
	order services.OrderRequest,
	itemKey string,
) {
	reused := control.NormalizeVoucherKind(existing.Kind) != order.Kind || !services.SameItem(existing.ItemKey, itemKey)
	if !reused {
		// The same item for the same number or account: the ledger holds a keyed
		// digest of the whole target (the mask is shared by many numbers). A row
		// that has no usable digest (older, or made with another key) is judged by
		// its mask, as it always was.
		if same, known := s.Services.SameTarget(existing.InstallationID, existing.Details, order); known {
			reused = !same
		} else if target, known := s.Services.MaskedTarget(order); known && existing.Target != "" && existing.Target != target {
			reused = true
		}
	}
	if reused {
		writeSMSError(w, http.StatusConflict, services.CodeKeyReused,
			"this idempotency key was used for a different order", map[string]any{"id": existing.ID})
		return
	}
	s.replayServiceOrder(w, r, store, existing)
}

// replayServiceOrder answers a request whose key already names this order.
func (s HTTPServer) replayServiceOrder(w http.ResponseWriter, r *http.Request, store control.VoucherStore, purchase control.VoucherPurchase) {
	now := s.clock().Now()
	ctx := context.WithoutCancel(r.Context())
	if purchase.Status == control.VoucherPurchasePending && purchase.HeldSince == nil &&
		now.Sub(purchase.CreatedAt) < s.serviceStaleAfter() {
		w.Header().Set("Retry-After", retryAfterSeconds(purchase.CreatedAt.Add(s.Services.RequestTimeout()), now))
		writeSMSError(w, http.StatusConflict, voucherCodeInFlight,
			"this order is being placed right now; retry shortly", map[string]any{"id": purchase.ID})
		return
	}
	if purchase.Status == control.VoucherPurchasePending {
		if checked, _, err := s.checkServiceOrder(ctx, store, purchase); err == nil {
			purchase = checked
		}
	}
	balance := s.voucherBalance(ctx, purchase.InstallationID)
	switch purchase.Status {
	case control.VoucherPurchaseFailed:
		writeJSON(w, http.StatusBadGateway, serviceFailureBody(purchase, balance, true))
	case control.VoucherPurchaseSucceeded:
		receipt, pending := s.serviceReceipt(ctx, purchase)
		status := http.StatusOK
		if pending {
			status = http.StatusAccepted
		}
		writeJSON(w, status, serviceOrderBody(purchase, receipt, pending, balance, true))
	default:
		writeJSON(w, http.StatusAccepted, serviceOrderBody(purchase, nil, true, balance, true))
	}
}

// handleServiceOrderRead serves GET /v1/services/orders/{key}, an alias of
// GET /v1/vouchers/purchases/{key}: either reads any kind of purchase.
func (s HTTPServer) handleServiceOrderRead(w http.ResponseWriter, r *http.Request, key string) {
	s.handleVoucherPurchaseRead(w, r, key)
}

// readServiceOrder answers a read of a service order: the row as it stands, a
// pending one checked with the supplier first, and the receipt read back from the
// supplier (the relay keeps none).
func (s HTTPServer) readServiceOrder(w http.ResponseWriter, r *http.Request, store control.VoucherStore, purchase control.VoucherPurchase) {
	ctx := context.WithoutCancel(r.Context())
	if purchase.Status == control.VoucherPurchasePending &&
		(purchase.HeldSince != nil || s.clock().Now().Sub(purchase.CreatedAt) >= s.serviceStaleAfter()) {
		if checked, _, err := s.checkServiceOrder(ctx, store, purchase); err == nil {
			purchase = checked
		}
	}
	balance := s.voucherBalance(ctx, purchase.InstallationID)
	receipt, pending := s.serviceReceipt(ctx, purchase)
	writeJSON(w, http.StatusOK, serviceOrderBody(purchase, receipt, pending, balance, false))
}

// serviceReceipt reads a succeeded order's receipt back from its supplier.
// pending is true when it could not be read right now (or the order is not
// finished): ask again.
func (s HTTPServer) serviceReceipt(ctx context.Context, purchase control.VoucherPurchase) (map[string]string, bool) {
	switch purchase.Status {
	case control.VoucherPurchaseFailed:
		return nil, false
	case control.VoucherPurchasePending:
		return nil, true
	}
	kind := control.NormalizeVoucherKind(purchase.Kind)
	executor, ok := s.Services.ExecutorFor(purchase.Supplier)
	orderID := services.SplitOrderRef(kind, purchase.SupplierOrderID)
	if !ok || orderID == "" {
		return nil, true
	}
	lookupCtx, cancel := context.WithTimeout(ctx, voucherCodesLookupBudget)
	defer cancel()
	result, err := executor.Lookup(lookupCtx, kind, orderID)
	if err != nil || result.Status != vouchers.StatusSucceeded || len(result.Receipt) == 0 {
		s.logger().Warn("reading a service order's receipt back failed",
			"purchase_id", purchase.ID, "supplier_order_id", purchase.SupplierOrderID,
			"status", result.Status, "error", services.RedactError(err))
		return nil, true
	}
	return result.Receipt, false
}

// serviceOrderBody is a service order as the shop reads it.
func serviceOrderBody(purchase control.VoucherPurchase, receipt map[string]string, receiptPending bool, balance string, replayed bool) map[string]any {
	return map[string]any{
		"purchase": servicePurchasePayload(purchase, receipt, receiptPending),
		"balance":  balance,
		"replayed": replayed,
	}
}

func serviceFailureBody(purchase control.VoucherPurchase, balance string, replayed bool) map[string]any {
	code := purchase.ErrorCode
	if code == "" {
		code = vouchers.FailureRefused
	}
	return map[string]any{
		"error":    "the order could not be carried out",
		"code":     shopFailureCode(code),
		"detail":   shopFailureDetail(code, purchase.ErrorDetail),
		"purchase": servicePurchasePayload(purchase, nil, false),
		"balance":  balance,
		"replayed": replayed,
	}
}

// servicePurchasePayload is the purchase payload of a card, with what a service
// order has instead of codes: a receipt (an object, empty while there is none)
// and whether it is still to come.
func servicePurchasePayload(purchase control.VoucherPurchase, receipt map[string]string, receiptPending bool) map[string]any {
	payload := voucherPurchasePayload(purchase, nil, false)
	payload["codes_pending"] = false
	if receipt == nil {
		receipt = map[string]string{}
	}
	if purchase.TestMode && len(receipt) > 0 {
		// A test order's slip says so, whoever prints it.
		marked := make(map[string]string, len(receipt)+1)
		for key, value := range receipt {
			marked[key] = value
		}
		marked[services.ReceiptTestMode] = "true"
		receipt = marked
	}
	payload["receipt"] = shopReceipt(purchase.ID, receipt)
	payload["receipt_pending"] = receiptPending
	return payload
}

// logServiceOrder writes the one line a service order leaves in the log. It names
// the masked target only: the full number and the supplier's sentences about it
// never reach the log.
func (s HTTPServer) logServiceOrder(
	installationID string,
	purchase control.VoucherPurchase,
	outcome control.VoucherPurchaseOutcome,
	execErr error,
	secrets []string,
) {
	attrs := []any{
		"installation_id", installationID,
		"purchase_id", purchase.ID,
		"kind", purchase.Kind,
		"item", purchase.ItemKey,
		"target", purchase.Target,
		"amount", purchase.Amount,
		"supplier", purchase.Supplier,
		"supplier_order_id", outcome.SupplierOrderID,
		"supplier_cost_usd", outcome.SupplierCost,
		"status", purchase.Status,
		"held", purchase.HeldSince != nil,
		"test_mode", purchase.TestMode,
	}
	if execErr != nil {
		attrs = append(attrs, "error", services.RedactError(execErr, secrets...))
	}
	switch {
	case outcome.ErrorCode == vouchers.FailureCredit || outcome.ErrorCode == vouchers.FailureUnauthorized:
		// The company's own Reloadly account is the problem: every shop is refused
		// until somebody tops it up or fixes the credentials.
		s.logger().Error("a service order failed on the company's supplier account", attrs...)
	case purchase.Status == control.VoucherPurchaseFailed:
		s.logger().Warn("a service order failed and was refunded", attrs...)
	case purchase.Status == control.VoucherPurchasePending:
		s.logger().Warn("a service order has no final outcome yet; its price is held", attrs...)
	default:
		s.logger().Info("a service order was carried out", attrs...)
	}
}
