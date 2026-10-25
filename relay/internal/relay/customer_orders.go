package relay

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/alerts"
	"pointy/relay/internal/control"
	"pointy/relay/internal/dafa"
	"pointy/relay/internal/vouchers"
)

// Orders of «دفتر كروت» customers (see control/customer_orders.go):
//
//	GET  /v1/customers/payment-methods          what the checkout offers (public)
//	POST /v1/customers/orders                   place an order and start paying (Bearer)
//	GET  /v1/customers/orders                   the customer's orders (Bearer)
//	GET  /v1/customers/orders/{id}              one order, with its codes once delivered (Bearer)
//	POST /v1/customers/orders/{id}/confirm      {otp}: the payer's wallet code (Bearer)
//	POST /v1/customers/orders/{id}/cancel       back out before paying (Bearer)
//	GET  /v1/customers/credit                   the customer's credit (Bearer)
//	POST /v1/customers/dafa/webhook/{id}?token= Dafa's nudge (signed URL)
//
// The card is bought only once Dafa itself says the order is paid, through
// the same supplier path shops use. Every way it can then fail lands as the
// customer's credit, never as lost money.

const (
	customerOrderKeyPrefix   = "corder:"
	customerWebhookPrefix    = "/v1/customers/dafa/webhook/"
	defaultCustomerOrderTTL  = 30 * time.Minute
	maxCustomerOrderListSize = 100
)

func (c CustomerConfig) orderTTL() time.Duration {
	if c.OrderTTL > 0 {
		return c.OrderTTL
	}
	return defaultCustomerOrderTTL
}

func (s HTTPServer) customerOrderStores(w http.ResponseWriter) (control.CustomerOrderStore, control.VoucherStore, bool) {
	orders, ok := s.Store.(control.CustomerOrderStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "orders_unavailable", "this relay takes no orders", nil)
		return nil, nil, false
	}
	cards, ok := s.customerVoucherStore(w)
	if !ok {
		return nil, nil, false
	}
	return orders, cards, true
}

type customerOrderRequest struct {
	Item           string `json:"item"`
	Quantity       int    `json:"quantity"`
	IdempotencyKey string `json:"idempotency_key"`
	// UnitPrice is the price the customer was shown; a different current
	// price is refused so nobody pays what they did not see.
	UnitPrice string `json:"unit_price"`
	Channel   string `json:"channel"`
	UseCredit bool   `json:"use_credit"`
	Method    string `json:"method"`
	// UserIdentifier and BirthYear are the payer's, as the wallet's top-up
	// takes them.
	UserIdentifier string `json:"user_identifier"`
	BirthYear      string `json:"birth_year"`
}

// handleCustomerOrderCreate serves POST /v1/customers/orders.
func (s HTTPServer) handleCustomerOrderCreate(w http.ResponseWriter, r *http.Request, customer control.Customer) {
	orders, cards, ok := s.customerOrderStores(w)
	if !ok {
		return
	}
	var request customerOrderRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	request.Item = strings.TrimSpace(request.Item)
	request.IdempotencyKey = strings.TrimSpace(request.IdempotencyKey)
	request.Channel = strings.TrimSpace(request.Channel)
	request.Method = strings.ToLower(strings.TrimSpace(request.Method))
	if request.Quantity == 0 {
		request.Quantity = 1
	}
	switch {
	case request.Item == "":
		writeCustomerError(w, http.StatusBadRequest, "invalid_request", "item is required", nil)
		return
	case request.IdempotencyKey == "" || len(request.IdempotencyKey) > 128:
		writeCustomerError(w, http.StatusBadRequest, "invalid_request", "idempotency_key is required (at most 128 characters)", nil)
		return
	case request.Quantity < 1 || request.Quantity > maxVoucherQuantity:
		writeCustomerError(w, http.StatusBadRequest, "invalid_quantity",
			fmt.Sprintf("quantity must be 1 to %d", maxVoucherQuantity), map[string]any{"max_quantity": maxVoucherQuantity})
		return
	case !validCustomerChannel(request.Channel):
		writeCustomerError(w, http.StatusBadRequest, "invalid_channel",
			"channel must be one of "+strings.Join(customerChannels, ", "), nil)
		return
	}
	ctx := r.Context()
	// The stores' review account buys for show: see customer_review.go.
	review := s.Customers.isReviewPhone(customer.Phone)

	// A replay answers with the order as it stands, whatever the catalog says now.
	if existing, found := s.findCustomerOrderByKey(ctx, orders, customer.ID, request.IdempotencyKey); found {
		if existing.ItemKey != request.Item || existing.Quantity != request.Quantity {
			writeCustomerError(w, http.StatusConflict, "idempotency_key_reused", "this key was used for another order", nil)
			return
		}
		s.answerCustomerOrder(w, r, orders, existing, http.StatusOK)
		return
	}
	if s.limitCustomerOrders(w, r, customer.ID) {
		return
	}

	located, ranking, failure := s.locateCustomerCard(ctx, cards, request.Item, review)
	if failure != "" {
		status := http.StatusConflict
		if failure == "unknown_item" {
			status = http.StatusNotFound
		}
		writeCustomerError(w, status, failure, "this card cannot be bought right now", nil)
		return
	}
	if !s.Customers.channelSells(request.Channel, located.Brand.Category) {
		writeCustomerError(w, http.StatusNotFound, "unknown_item", "this card is not sold in this app", nil)
		return
	}
	if reason, _ := ranking.unavailable(); reason != "" {
		writeCustomerError(w, http.StatusConflict, "item_unavailable", "this card cannot be bought right now", nil)
		return
	}
	now := s.clock().Now()
	price, err := control.ParseWalletAmount(vouchers.PriceAt(located.Item, now).RetailPrice)
	if err != nil || price.Sign() <= 0 {
		writeCustomerError(w, http.StatusConflict, "item_unavailable", "this card has no price right now", nil)
		return
	}
	if shown, err := control.ParseWalletAmount(request.UnitPrice); err != nil || shown.Cmp(price) != 0 {
		writeCustomerError(w, http.StatusConflict, "price_changed", "the price changed; check it and try again",
			map[string]any{"unit_price": control.FormatWalletAmount(price)})
		return
	}

	// The payer is checked before anything is stored, unless the credit
	// will clearly cover everything.
	total := new(big.Rat).Mul(price, big.NewRat(int64(request.Quantity), 1))
	needsPayment := true
	if request.UseCredit {
		balance, _, err := orders.CustomerCredit(ctx, customer.ID, 1)
		if err != nil {
			s.customerInternalError(w, "customer credit read failed", err)
			return
		}
		if value, err := control.ParseWalletAmount(balance); err == nil && value.Cmp(total) >= 0 {
			needsPayment = false
		}
	}
	var method walletMethod
	var payer walletPayer
	if needsPayment {
		if !s.Wallet.TopUpsConfigured() {
			writeCustomerError(w, http.StatusServiceUnavailable, "payments_unavailable", "payments are not available right now", nil)
			return
		}
		// An empty method would fall back to the wallet's default: the
		// customer must have chosen one.
		method, ok = s.Wallet.enabledMethod(request.Method)
		if !ok || request.Method == "" {
			writeCustomerError(w, http.StatusUnprocessableEntity, walletCodeUnsupportedMethod, "choose a payment method", nil)
			return
		}
		var code, rejection string
		payer, code, rejection = s.validateWalletPayer(method, walletTopUpRequest{
			UserIdentifier: request.UserIdentifier, BirthYear: request.BirthYear,
		})
		if code != "" {
			writeCustomerError(w, http.StatusUnprocessableEntity, code, rejection, nil)
			return
		}
	}

	order, created, err := orders.BeginCustomerOrder(ctx, control.CustomerOrder{
		CustomerID:     customer.ID,
		IdempotencyKey: request.IdempotencyKey,
		Channel:        request.Channel,
		ItemKey:        located.Item.Key,
		BrandKey:       located.Brand.Key,
		ItemName:       located.Name(),
		Quantity:       request.Quantity,
		UnitPrice:      control.FormatWalletAmount(price),
		Method:         method.Key,
		PayerHint:      payer.hint,
		// The gateway's fee goes on top of what Dafa collects, as the
		// checkout showed before the customer paid.
		FeePercent: s.Wallet.FeePercent,
		TestMode:   s.Vouchers.MarksTest() || s.Wallet.TestMode || review,
		Review:     review,
	}, request.UseCredit)
	switch {
	case errors.Is(err, control.ErrCustomerOrderKeyReused):
		writeCustomerError(w, http.StatusConflict, "idempotency_key_reused", "this key was used for another order", nil)
		return
	case err != nil:
		s.customerInternalError(w, "customer order claim failed", err)
		return
	case !created:
		s.answerCustomerOrder(w, r, orders, order, http.StatusOK)
		return
	}
	detached := context.WithoutCancel(ctx)
	s.logger().Info("customer order placed", "order_id", order.ID, "customer_id", customer.ID,
		"item", order.ItemKey, "total", order.Total, "credit_used", order.CreditUsed, "channel", order.Channel)

	if order.Status == control.CustomerOrderAwaitingPayment {
		if method.Key == "" {
			// The credit moved under us and no longer covers it.
			closed, _, _ := orders.CloseCustomerOrder(detached, order.ID, control.CustomerOrderFailed, "method_required",
				"the credit no longer covers the order")
			writeCustomerError(w, http.StatusUnprocessableEntity, walletCodeUnsupportedMethod, "choose a payment method",
				map[string]any{"order": customerOrderPayload(closed, nil, false)})
			return
		}
		order, ok = s.startCustomerPayment(w, r, orders, order, method, payer)
		if !ok {
			return
		}
		s.answerCustomerOrder(w, r, orders, order, http.StatusCreated)
		return
	}
	// The credit paid for everything: buy the card now.
	order, codes, pending := s.advanceCustomerOrder(detached, orders, cards, order)
	writeJSON(w, http.StatusCreated, map[string]any{"order": customerOrderPayload(order, codes, pending)})
}

// startCustomerPayment asks Dafa to start collecting what the order owes.
func (s HTTPServer) startCustomerPayment(
	w http.ResponseWriter,
	r *http.Request,
	orders control.CustomerOrderStore,
	order control.CustomerOrder,
	method walletMethod,
	payer walletPayer,
) (control.CustomerOrder, bool) {
	detached := context.WithoutCancel(r.Context())
	if order.Review {
		started, err := s.startReviewPayment(detached, orders, order, method)
		if err != nil {
			s.customerInternalError(w, "starting a review payment failed", err)
			return order, false
		}
		return started, true
	}
	callCtx, cancel := context.WithTimeout(detached, s.Wallet.requestTimeout())
	charge := control.CustomerOrderCharge(order)
	payment, err := s.Wallet.dafaClient().Initiate(callCtx, dafa.InitiateRequest{
		Provider:       method.Provider.ID,
		Amount:         charge,
		UserIdentifier: payer.identifier,
		BirthYear:      payer.birthYear,
		CallbackURL:    s.customerWebhookURL(r, order.ID),
	})
	cancel()
	if err == nil {
		err = checkStartedPayment(method, control.WalletTopUp{Amount: charge}, payment)
	}
	if err != nil {
		failure := s.classifyInitiateError(method, err)
		closed, _, closeErr := orders.CloseCustomerOrder(detached, order.ID, control.CustomerOrderFailed, failure.code, failure.detail)
		if closeErr != nil {
			s.logger().Error("recording a failed customer payment failed", "order_id", order.ID, "error", closeErr)
			closed = order
		}
		s.logger().Warn("customer payment did not start", "order_id", order.ID, "code", failure.code, "detail", failure.detail)
		writeCustomerError(w, failure.status, failure.code, failure.message(), failure.extra(map[string]any{
			"order": customerOrderPayload(closed, nil, false),
		}))
		return order, false
	}
	checkoutURL := ""
	if method.Provider.HostedPage {
		checkoutURL = payment.PaymentPageURL
	}
	attached, err := orders.AttachCustomerOrderPayment(detached, order.ID, payment.ID, checkoutURL)
	if err != nil {
		s.logger().Error("recording a started customer payment failed", "order_id", order.ID, "payment_id", payment.ID, "error", err)
		closed, _, _ := orders.CloseCustomerOrder(detached, order.ID, control.CustomerOrderFailed, walletCodeOutcomeUnknown,
			"dafa payment "+payment.ID+" started but could not be recorded")
		writeCustomerError(w, http.StatusInternalServerError, "internal_error", "relay store failed",
			map[string]any{"order": customerOrderPayload(closed, nil, false)})
		return order, false
	}
	return attached, true
}

// locateCustomerCard finds an item in the priced catalog and ranks its
// suppliers. failure is "unknown_item" or "" .
func (s HTTPServer) locateCustomerCard(ctx context.Context, cards control.VoucherStore, itemKey string, review bool) (vouchers.Located, supplierRanking, string) {
	loaded, err := s.currentVoucherCatalog(ctx, cards)
	if err != nil || loaded.empty {
		return vouchers.Located{}, supplierRanking{}, "unknown_item"
	}
	offers, err := s.loadVoucherOffers(ctx, cards)
	if err != nil {
		return vouchers.Located{}, supplierRanking{}, "item_unavailable"
	}
	settings, err := s.voucherSettingsForCards(ctx, cards)
	if err != nil {
		return vouchers.Located{}, supplierRanking{}, "item_unavailable"
	}
	located, found := vouchers.Find(s.autoPricedDocument(loaded.document, offers, settings), itemKey)
	if !found {
		return vouchers.Located{}, supplierRanking{}, "unknown_item"
	}
	suppliers := s.Vouchers
	if review {
		suppliers = suppliers.reviewSuppliers()
	}
	return located, suppliers.rankSuppliers(located, offers, settings), ""
}

func (s HTTPServer) findCustomerOrderByKey(ctx context.Context, orders control.CustomerOrderStore, customerID, key string) (control.CustomerOrder, bool) {
	order, err := orders.FindCustomerOrderByKey(ctx, customerID, key)
	return order, err == nil
}

// --- moving an order along ------------------------------------------------

// advanceCustomerOrder takes a paid order as far as it can go now: claims and
// buys its card, or reads how its purchase ended. The codes come back for a
// delivered order (pending when the supplier cannot be read right now).
func (s HTTPServer) advanceCustomerOrder(
	ctx context.Context,
	orders control.CustomerOrderStore,
	cards control.VoucherStore,
	order control.CustomerOrder,
) (control.CustomerOrder, []vouchers.Code, bool) {
	var codes []vouchers.Code
	if order.Status == control.CustomerOrderPaid {
		purchase, bought, ok := s.claimCustomerPurchase(ctx, orders, cards, order)
		if !ok {
			refreshed, err := orders.GetCustomerOrder(ctx, order.ID)
			if err == nil {
				order = refreshed
			}
			return order, nil, false
		}
		codes = bought
		started, err := orders.StartCustomerOrderFulfilment(ctx, order.ID, purchase.ID)
		if err != nil {
			s.logger().Error("tying a customer order to its purchase failed", "order_id", order.ID, "purchase_id", purchase.ID, "error", err)
			return order, nil, false
		}
		order = started
	}
	if order.Status != control.CustomerOrderFulfilling {
		if order.Status == control.CustomerOrderDelivered {
			return s.customerOrderCodes(ctx, cards, order)
		}
		return order, nil, false
	}
	purchase, err := cards.GetVoucherPurchase(ctx, order.PurchaseID)
	if err != nil {
		s.logger().Error("reading a customer order's purchase failed", "order_id", order.ID, "purchase_id", order.PurchaseID, "error", err)
		return order, nil, false
	}
	if purchase.Status == control.VoucherPurchasePending &&
		(purchase.HeldSince != nil || s.clock().Now().Sub(purchase.CreatedAt) >= s.Vouchers.staleAfter()) {
		if checked, _, err := s.checkVoucherPurchase(ctx, cards, purchase); err == nil {
			purchase = checked
		}
	}
	switch purchase.Status {
	case control.VoucherPurchaseSucceeded:
		finished, applied, err := orders.FinishCustomerOrder(ctx, order.ID, true, "", "")
		if err != nil {
			s.logger().Error("recording a delivered customer order failed", "order_id", order.ID, "error", err)
			return order, nil, false
		}
		if applied {
			s.logger().Info("customer order delivered", "order_id", order.ID, "purchase_id", purchase.ID)
		}
		if len(codes) > 0 {
			return finished, codes, false
		}
		return s.customerOrderCodes(ctx, cards, finished)
	case control.VoucherPurchaseFailed:
		finished, applied, err := orders.FinishCustomerOrder(ctx, order.ID, false, shopFailureCode(purchase.ErrorCode),
			shopFailureDetail(purchase.ErrorCode, purchase.ErrorDetail))
		if err != nil {
			s.logger().Error("refunding a customer order failed", "order_id", order.ID, "error", err)
			return order, nil, false
		}
		if applied {
			s.logger().Warn("customer order refunded to credit", "order_id", order.ID, "total", finished.Total,
				"code", purchase.ErrorCode)
		}
		return finished, nil, false
	}
	return order, nil, true
}

// claimCustomerPurchase claims the order's purchase (or finds the one claimed
// before) and, when this call claimed it, buys the cards. ok=false: the order
// was refunded instead, or the store failed.
func (s HTTPServer) claimCustomerPurchase(
	ctx context.Context,
	orders control.CustomerOrderStore,
	cards control.VoucherStore,
	order control.CustomerOrder,
) (control.VoucherPurchase, []vouchers.Code, bool) {
	key := customerOrderKeyPrefix + order.ID
	if existing, found, err := cards.FindVoucherPurchaseByKey(ctx, "", key); err != nil {
		s.logger().Error("customer purchase lookup failed", "order_id", order.ID, "error", err)
		return control.VoucherPurchase{}, nil, false
	} else if found {
		return existing, nil, true
	}
	refund := func(code, detail string) {
		if _, _, err := orders.FinishCustomerOrder(ctx, order.ID, false, code, detail); err != nil {
			s.logger().Error("refunding a customer order failed", "order_id", order.ID, "error", err)
			return
		}
		s.logger().Warn("customer order refunded to credit before buying", "order_id", order.ID, "code", code)
	}
	located, ranking, failure := s.locateCustomerCard(ctx, cards, order.ItemKey, order.Review)
	if failure != "" {
		refund("item_unavailable", "the card left the catalog before it could be bought")
		return control.VoucherPurchase{}, nil, false
	}
	if reason, _ := ranking.unavailable(); reason != "" {
		refund("item_unavailable", reason)
		return control.VoucherPurchase{}, nil, false
	}
	first := ranking.Candidates[0]
	claim, created, err := cards.BeginVoucherPurchase(ctx, control.VoucherPurchase{
		IdempotencyKey: key,
		ItemKey:        located.Item.Key,
		BrandKey:       located.Brand.Key,
		ItemName:       located.Name(),
		Quantity:       order.Quantity,
		UnitPrice:      order.UnitPrice,
		Supplier:       first.Supplier.Key(),
		SupplierRef:    first.Ref.ID,
		// A test payment buys a test card on the books, whatever the
		// supplier is: revenue and cost are left out together.
		TestMode: s.Vouchers.MarksTest() || order.TestMode,
		Purpose:  control.VoucherPurposeCustomer,
		Note:     order.ID,
	})
	if err != nil {
		s.logger().Error("customer purchase claim failed", "order_id", order.ID, "error", err)
		return control.VoucherPurchase{}, nil, false
	}
	if !created {
		return claim, nil, true
	}
	finished, codes := s.buyClaimedCards(ctx, cards, claim, ranking, order.Quantity)
	return finished, codes, true
}

func (s HTTPServer) customerOrderCodes(ctx context.Context, cards control.VoucherStore, order control.CustomerOrder) (control.CustomerOrder, []vouchers.Code, bool) {
	purchase, err := cards.GetVoucherPurchase(ctx, order.PurchaseID)
	if err != nil {
		return order, nil, true
	}
	codes, pending := s.voucherCodes(ctx, purchase)
	return order, codes, pending
}

// verifyCustomerPayment reads the order's payment back from Dafa and, when it
// is paid, records it: only Dafa's own answer is proof.
func (s HTTPServer) verifyCustomerPayment(ctx context.Context, orders control.CustomerOrderStore, order control.CustomerOrder, source string) (control.CustomerOrder, error) {
	// A review order's payment is simulated: there is nothing at Dafa to read.
	if order.Review || order.PaymentID == "" || order.LatePaid || order.ErrorCode == control.CustomerOrderPaymentMismatch ||
		order.Status == control.CustomerOrderPaid ||
		order.Status == control.CustomerOrderFulfilling || order.Status == control.CustomerOrderDelivered ||
		order.Status == control.CustomerOrderRefunded {
		return order, nil
	}
	callCtx, cancel := context.WithTimeout(ctx, s.Wallet.requestTimeout())
	payment, err := s.Wallet.dafaClient().Payment(callCtx, order.PaymentID)
	cancel()
	if err != nil {
		return order, err
	}
	return s.settleCustomerPayment(ctx, orders, order, payment, source)
}

func (s HTTPServer) settleCustomerPayment(
	ctx context.Context,
	orders control.CustomerOrderStore,
	order control.CustomerOrder,
	payment dafa.Payment,
	source string,
) (control.CustomerOrder, error) {
	if payment.ID != order.PaymentID {
		s.logger().Error("dafa answered about another payment than the order started; ignored",
			"order_id", order.ID, "payment_id", order.PaymentID, "answered_id", truncateRunes(payment.ID, 64))
		return order, errWalletPaymentMismatch
	}
	if !payment.IsPaid || order.ErrorCode == control.CustomerOrderPaymentMismatch {
		return order, nil
	}
	charge := control.CustomerOrderCharge(order)
	if !walletAmountsEqual(payment.Amount, charge) ||
		(payment.WorkspaceKnown && payment.TestWorkspace != s.Wallet.TestMode) {
		// Paid, but not what the order asked for: nobody is served on a wrong
		// figure. The order records it once and the operator is told; the
		// money is reconciled by hand.
		detail := fmt.Sprintf("dafa reports %s paid (test=%v) for %s due (payment %s); reconcile by hand",
			truncateRunes(payment.Amount, 32), payment.TestWorkspace, charge, payment.ID)
		held, applied, err := orders.HoldCustomerOrderPayment(ctx, order.ID, detail)
		if err != nil {
			return order, err
		}
		if applied {
			s.logger().Error("a customer payment does not match its order; held for the operator",
				"order_id", order.ID, "payment_id", payment.ID, "paid", truncateRunes(payment.Amount, 32), "due", charge)
			if s.Alerts != nil {
				s.Alerts.Send(alerts.Message{
					Title:    "Card app paid with a mismatch, reconcile: " + truncateRunes(payment.Amount, 32) + " LYD",
					Body:     "Order: " + order.ID + "\nPayment: " + payment.ID + "\nDue: " + charge + " LYD\nPayer: " + order.PayerHint,
					Priority: alerts.PriorityUrgent,
					Tags:     []string{"rotating_light"},
				})
			}
		}
		return held, nil
	}
	paid, applied, err := orders.PayCustomerOrder(ctx, order.ID, payment.ID)
	if err != nil {
		return order, err
	}
	if applied {
		if paid.LatePaid {
			s.logger().Warn("a customer payment landed after its order closed; kept as credit",
				"order_id", order.ID, "amount", order.AmountDue, "source", source)
		} else {
			s.logger().Info("customer order paid", "order_id", order.ID, "source", source)
		}
	}
	return paid, nil
}

// --- answers ---------------------------------------------------------------

// answerCustomerOrder answers with the order, moving it along first.
func (s HTTPServer) answerCustomerOrder(w http.ResponseWriter, r *http.Request, orders control.CustomerOrderStore, order control.CustomerOrder, status int) {
	ctx := context.WithoutCancel(r.Context())
	var codes []vouchers.Code
	pending := false
	if cards, ok := s.voucherStore(); ok {
		if order.Status == control.CustomerOrderAwaitingPayment && order.PaymentID != "" && s.allowWalletVerify(ctx, customerOrderKeyPrefix+order.ID) {
			if verified, err := s.verifyCustomerPayment(ctx, orders, order, "read"); err == nil {
				order = verified
			}
		}
		if order.Status == control.CustomerOrderPaid || order.Status == control.CustomerOrderFulfilling || order.Status == control.CustomerOrderDelivered {
			order, codes, pending = s.advanceCustomerOrder(ctx, orders, cards, order)
		}
	}
	writeJSON(w, status, map[string]any{"order": customerOrderPayload(order, codes, pending)})
}

func customerOrderPayload(order control.CustomerOrder, codes []vouchers.Code, codesPending bool) map[string]any {
	if codes == nil {
		codes = []vouchers.Code{}
	}
	payload := map[string]any{
		"id":              order.ID,
		"idempotency_key": order.IdempotencyKey,
		"status":          order.Status,
		"item":            order.ItemKey,
		"brand":           order.BrandKey,
		"name":            order.ItemName,
		"quantity":        order.Quantity,
		"unit_price":      order.UnitPrice,
		"total":           order.Total,
		"credit_used":     order.CreditUsed,
		"amount_due":      order.AmountDue,
		"fee":             order.Fee,
		// amount_to_pay is what the payer is charged through Dafa: the
		// amount due plus the gateway's fee.
		"amount_to_pay": control.CustomerOrderCharge(order),
		"method":        order.Method,
		"payer_hint":    order.PayerHint,
		"otp_attempts":  order.OTPAttempts,
		"error_code":    order.ErrorCode,
		"late_paid":     order.LatePaid,
		// A review order is test money too, but the app is never told it is
		// being reviewed.
		"test_mode":     order.TestMode && !order.Review,
		"codes":         codes,
		"codes_pending": codesPending,
		"created_at":    order.CreatedAt,
		"paid_at":       order.PaidAt,
		"completed_at":  order.CompletedAt,
	}
	if order.Status == control.CustomerOrderAwaitingPayment {
		if method, ok := lookupWalletMethod(order.Method); ok {
			payload["next_action"] = method.kind()
		}
		if order.CheckoutURL != "" {
			payload["checkout_url"] = order.CheckoutURL
		}
	}
	return payload
}

// --- the other routes ------------------------------------------------------

func (s HTTPServer) handleCustomerOrderList(w http.ResponseWriter, r *http.Request, customer control.Customer) {
	orders, ok := s.Store.(control.CustomerOrderStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "orders_unavailable", "this relay takes no orders", nil)
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > maxCustomerOrderListSize {
		limit = maxCustomerOrderListSize
	}
	list, err := orders.ListCustomerOrders(r.Context(), control.CustomerOrderFilter{CustomerID: customer.ID, Limit: limit})
	if err != nil {
		s.customerInternalError(w, "customer orders read failed", err)
		return
	}
	payloads := make([]map[string]any, 0, len(list))
	for _, order := range list {
		// The list never re-reads codes: one order's read does.
		payloads = append(payloads, customerOrderPayload(order, nil, order.Status == control.CustomerOrderDelivered))
	}
	writeJSON(w, http.StatusOK, map[string]any{"orders": payloads})
}

// ownCustomerOrder reads an order of the signed-in customer; any other's is
// "not found".
func (s HTTPServer) ownCustomerOrder(w http.ResponseWriter, r *http.Request, orders control.CustomerOrderStore, customer control.Customer, id string) (control.CustomerOrder, bool) {
	order, err := orders.GetCustomerOrder(r.Context(), id)
	if errors.Is(err, control.ErrCustomerOrderNotFound) || (err == nil && order.CustomerID != customer.ID) {
		writeCustomerError(w, http.StatusNotFound, "order_not_found", "no such order", nil)
		return control.CustomerOrder{}, false
	}
	if err != nil {
		s.customerInternalError(w, "customer order read failed", err)
		return control.CustomerOrder{}, false
	}
	return order, true
}

func (s HTTPServer) handleCustomerOrderRead(w http.ResponseWriter, r *http.Request, customer control.Customer, id string) {
	orders, ok := s.Store.(control.CustomerOrderStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "orders_unavailable", "this relay takes no orders", nil)
		return
	}
	order, ok := s.ownCustomerOrder(w, r, orders, customer, id)
	if !ok {
		return
	}
	s.answerCustomerOrder(w, r, orders, order, http.StatusOK)
}

type customerConfirmRequest struct {
	OTP string `json:"otp"`
}

// handleCustomerOrderConfirm serves POST /v1/customers/orders/{id}/confirm:
// the code the payer's wallet texted them.
func (s HTTPServer) handleCustomerOrderConfirm(w http.ResponseWriter, r *http.Request, customer control.Customer, id string) {
	orders, cards, ok := s.customerOrderStores(w)
	if !ok {
		return
	}
	var request customerConfirmRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	order, ok := s.ownCustomerOrder(w, r, orders, customer, id)
	if !ok {
		return
	}
	otp, valid := dafa.NormalizeOTP(request.OTP)
	method, known := lookupWalletMethod(order.Method)
	switch {
	case order.Status != control.CustomerOrderAwaitingPayment:
		s.answerCustomerOrder(w, r, orders, order, http.StatusOK)
		return
	case !known || method.kind() != walletKindOTP:
		writeCustomerError(w, http.StatusConflict, walletCodeNotOTPMethod, "this order is paid on the gateway's page",
			map[string]any{"order": customerOrderPayload(order, nil, false)})
		return
	case order.PaymentID == "":
		writeCustomerError(w, http.StatusConflict, walletCodeInFlight, "the payment is being set up; retry shortly", nil)
		return
	case !valid:
		writeCustomerError(w, http.StatusUnprocessableEntity, walletCodeInvalidOTP, "type the code your wallet sent you",
			map[string]any{"order": customerOrderPayload(order, nil, false)})
		return
	}
	ctx := context.WithoutCancel(r.Context())
	counted, recorded, err := orders.RecordCustomerOrderOTPAttempt(ctx, order.ID, maxWalletOTPAttempts)
	if err != nil {
		s.customerInternalError(w, "counting a customer payment code failed", err)
		return
	}
	if !recorded {
		if counted.Status == control.CustomerOrderAwaitingPayment {
			s.closeCustomerOrderAnswer(w, ctx, orders, counted, walletCodeOTPAttemptsExceeded, "too many wrong codes")
			return
		}
		s.answerCustomerOrder(w, r, orders, counted, http.StatusOK)
		return
	}
	order = counted
	if order.Review {
		s.confirmReviewPayment(w, ctx, orders, cards, order, otp)
		return
	}
	callCtx, cancel := context.WithTimeout(ctx, s.Wallet.requestTimeout())
	payment, err := s.Wallet.dafaClient().Confirm(callCtx, order.PaymentID, otp)
	cancel()
	if err == nil {
		paid, settleErr := s.settleCustomerPayment(ctx, orders, order, payment, "confirm")
		if settleErr != nil {
			s.customerInternalError(w, "recording a customer payment failed", settleErr)
			return
		}
		if paid.Status == control.CustomerOrderAwaitingPayment {
			writeJSON(w, http.StatusAccepted, map[string]any{
				"order": customerOrderPayload(paid, nil, false), "code": walletCodeAwaitingGateway,
			})
			return
		}
		paid, codes, pending := s.advanceCustomerOrder(ctx, orders, cards, paid)
		writeJSON(w, http.StatusOK, map[string]any{"order": customerOrderPayload(paid, codes, pending)})
		return
	}
	attemptsLeft := max(0, maxWalletOTPAttempts-order.OTPAttempts)
	var apiErr *dafa.APIError
	if errors.As(err, &apiErr) && apiErr.Status < 500 && apiErr.Status != http.StatusTooManyRequests {
		extra := map[string]any{"order": customerOrderPayload(order, nil, false), "attempts_left": attemptsLeft,
			"gateway_message": apiErr.Message}
		switch {
		case apiErr.Status == http.StatusUnauthorized || apiErr.Status == http.StatusForbidden:
			delete(extra, "gateway_message")
			writeCustomerError(w, http.StatusBadGateway, walletCodeGatewayUnauthorized, walletFailureMessage(walletCodeGatewayUnauthorized), extra)
		case apiErr.Code == "" && apiErr.Status == http.StatusUnprocessableEntity:
			writeCustomerError(w, http.StatusUnprocessableEntity, walletCodeInvalidOTP, walletFailureMessage(walletCodeInvalidOTP), extra)
		case apiErr.Retryable && apiErr.Fault == "payer":
			if attemptsLeft == 0 {
				s.closeCustomerOrderAnswer(w, ctx, orders, order, walletCodeOTPAttemptsExceeded, apiErrorDetail(apiErr))
				return
			}
			writeCustomerError(w, http.StatusUnprocessableEntity, walletCodeOTPRejected, walletFailureMessage(walletCodeOTPRejected), extra)
		case apiErr.Retryable:
			writeCustomerError(w, http.StatusServiceUnavailable, walletCodeGatewayBusy, walletFailureMessage(walletCodeGatewayBusy), extra)
		case apiErr.Code == "" && apiErr.Status != http.StatusNotFound:
			delete(extra, "gateway_message")
			writeCustomerError(w, http.StatusBadGateway, walletCodeGatewayRejected, walletFailureMessage(walletCodeGatewayRejected), extra)
		default:
			code := walletCodeDeclined
			if apiErr.Code == "" || (apiErr.Fault != "" && apiErr.Fault != "payer") {
				code = walletCodeGatewayRejected
			}
			s.closeCustomerOrderAnswer(w, ctx, orders, order, code, apiErrorDetail(apiErr))
		}
		return
	}
	// No usable answer: the payment may have gone through. Read it back.
	verified, verifyErr := s.verifyCustomerPayment(ctx, orders, order, "confirm_recovery")
	if verifyErr == nil && verified.Status != control.CustomerOrderAwaitingPayment {
		verified, codes, pending := s.advanceCustomerOrder(ctx, orders, cards, verified)
		writeJSON(w, http.StatusOK, map[string]any{"order": customerOrderPayload(verified, codes, pending)})
		return
	}
	writeCustomerError(w, http.StatusBadGateway, walletCodeConfirmUnknown, walletFailureMessage(walletCodeConfirmUnknown),
		map[string]any{"order": customerOrderPayload(order, nil, false), "attempts_left": attemptsLeft, "retryable": true})
}

func (s HTTPServer) closeCustomerOrderAnswer(w http.ResponseWriter, ctx context.Context, orders control.CustomerOrderStore, order control.CustomerOrder, code, detail string) {
	closed, _, err := orders.CloseCustomerOrder(ctx, order.ID, control.CustomerOrderFailed, code, detail)
	if err != nil {
		s.customerInternalError(w, "closing a customer order failed", err)
		return
	}
	writeCustomerError(w, http.StatusUnprocessableEntity, code, walletFailureMessage(code),
		map[string]any{"order": customerOrderPayload(closed, nil, false), "attempts_left": 0})
}

// handleCustomerOrderCancel serves POST /v1/customers/orders/{id}/cancel. Only
// a wallet payment waiting for its code can be called off: a bank card may be
// on Dafa's page this minute.
func (s HTTPServer) handleCustomerOrderCancel(w http.ResponseWriter, r *http.Request, customer control.Customer, id string) {
	orders, ok := s.Store.(control.CustomerOrderStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "orders_unavailable", "this relay takes no orders", nil)
		return
	}
	order, ok := s.ownCustomerOrder(w, r, orders, customer, id)
	if !ok {
		return
	}
	// A bank-card payer may have paid on a page the relay does not see:
	// Dafa is asked first, and a paid order is answered as it now stands,
	// never cancelled. A payment that lands after the cancel is still found
	// by the sweep, which reads cancelled bank-card orders back for a day,
	// and kept as credit.
	if method, known := lookupWalletMethod(order.Method); known && method.kind() != walletKindOTP &&
		order.PaymentID != "" && order.Status == control.CustomerOrderAwaitingPayment && !order.Review {
		verified, err := s.verifyCustomerPayment(r.Context(), orders, order, "cancel")
		if err != nil {
			writeCustomerError(w, http.StatusServiceUnavailable, "payment_check_failed",
				"could not check the card payment; retry", map[string]any{"order": customerOrderPayload(order, nil, false)})
			return
		}
		if verified.Status != control.CustomerOrderAwaitingPayment {
			s.answerCustomerOrder(w, r, orders, verified, http.StatusOK)
			return
		}
		order = verified
	}
	closed, applied, err := orders.CloseCustomerOrder(context.WithoutCancel(r.Context()), order.ID,
		control.CustomerOrderCancelled, walletCodeCanceled, "the customer backed out before paying")
	if err != nil {
		s.customerInternalError(w, "cancelling a customer order failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"order": customerOrderPayload(closed, nil, false), "applied": applied})
}

func (s HTTPServer) handleCustomerCredit(w http.ResponseWriter, r *http.Request, customer control.Customer) {
	orders, ok := s.Store.(control.CustomerOrderStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "orders_unavailable", "this relay takes no orders", nil)
		return
	}
	balance, entries, err := orders.CustomerCredit(r.Context(), customer.ID, 50)
	if err != nil {
		s.customerInternalError(w, "customer credit read failed", err)
		return
	}
	views := make([]map[string]any, 0, len(entries))
	for _, entry := range entries {
		views = append(views, map[string]any{
			"kind": entry.Kind, "amount": entry.Amount, "order_id": entry.OrderID, "created_at": entry.CreatedAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"balance": balance, "entries": views})
}

func (s HTTPServer) limitCustomerOrders(w http.ResponseWriter, r *http.Request, customerID string) bool {
	policy := s.Customers.OrderRateLimit
	if !policy.Enabled() || s.RateLimiter == nil {
		return false
	}
	decision, err := s.RateLimiter.Allow(r.Context(), "customer-order:"+customerID, policy)
	if err != nil {
		s.logger().Error("customer order rate limiter failed; allowing", "error", err)
		return false
	}
	if decision.Allowed {
		return false
	}
	w.Header().Set("Retry-After", retryAfterSeconds(decision.ResetAt, s.clock().Now()))
	writeCustomerError(w, http.StatusTooManyRequests, "rate_limited", "too many orders; retry shortly", nil)
	return true
}

// --- Dafa's webhook --------------------------------------------------------

// customerWebhookToken keys the webhook URL to one order, like a top-up's.
func (c WalletConfig) customerWebhookToken(orderID string) string {
	mac := hmac.New(sha256.New, []byte(strings.TrimSpace(c.DafaAPIKey)))
	mac.Write([]byte("pointy-customer-order-webhook/v1:" + orderID))
	return hex.EncodeToString(mac.Sum(nil))[:32]
}

func (s HTTPServer) customerWebhookURL(r *http.Request, orderID string) string {
	base := s.walletWebhookBase(r)
	parsed, err := url.Parse(base)
	if err != nil || parsed.Scheme != "https" || !publicWebhookHost(parsed.Hostname()) {
		return ""
	}
	return base + customerWebhookPrefix + url.PathEscape(orderID) + "?token=" + s.Wallet.customerWebhookToken(orderID)
}

// handleCustomerDafaWebhook serves POST /v1/customers/dafa/webhook/{order id}:
// a nudge. The relay reads the payment back itself and acts on that.
func (s HTTPServer) handleCustomerDafaWebhook(w http.ResponseWriter, r *http.Request, rawID string) {
	orders, hasOrders := s.Store.(control.CustomerOrderStore)
	id, err := url.PathUnescape(strings.Trim(rawID, "/"))
	if !hasOrders || !s.Wallet.TopUpsConfigured() || err != nil || id == "" || strings.Contains(id, "/") {
		writeNotFound(w)
		return
	}
	token := strings.TrimSpace(r.URL.Query().Get("token"))
	if !hmac.Equal([]byte(token), []byte(s.Wallet.customerWebhookToken(id))) {
		s.metrics().RecordCredentialRejected()
		writeNotFound(w)
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 2*s.Wallet.requestTimeout())
	defer cancel()
	order, err := orders.GetCustomerOrder(ctx, id)
	if errors.Is(err, control.ErrCustomerOrderNotFound) {
		writeNotFound(w)
		return
	}
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "retry later"})
		return
	}
	verified, err := s.verifyCustomerPayment(ctx, orders, order, "webhook")
	if err != nil {
		w.Header().Set("Retry-After", "30")
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "retry later"})
		return
	}
	if cards, ok := s.voucherStore(); ok && verified.Status == control.CustomerOrderPaid {
		verified, _, _ = s.advanceCustomerOrder(ctx, orders, cards, verified)
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": verified.Status})
}
