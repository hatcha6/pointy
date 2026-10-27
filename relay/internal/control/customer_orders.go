package control

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"slices"
	"sort"
	"strings"
	"time"
)

// Orders of «دفتر كروت» customers (DAFTAR_CARDS_APP_PLAN.md) and their in-app
// credit.
//
// An order is one card item bought by one customer. It is paid from the
// customer's credit first, when they ask, and the rest through Dafa. Only once
// the payment is proven is the card bought, through the same supplier path a
// shop's purchase takes (a no-shop purchase row with purpose "customer"). From
// then on the customer's money is never lost to a failure: a card that cannot
// be bought refunds the whole order to their credit, and a payment that lands
// after the order was written off becomes credit too.
//
// The credit is a ledger of signed entries; the balance is their sum. Entries
// are written in the same step as the order change that causes them, keyed on
// (order, kind), so no transition can move the money twice.

const (
	// CustomerOrderAwaitingPayment: some of the price is due through Dafa.
	CustomerOrderAwaitingPayment = "awaiting_payment"
	// CustomerOrderPaid: the price is covered; the card is not yet claimed.
	CustomerOrderPaid = "paid"
	// CustomerOrderFulfilling: a supplier purchase is claimed (PurchaseID).
	CustomerOrderFulfilling = "fulfilling"
	CustomerOrderDelivered  = "delivered"
	// CustomerOrderRefunded: paid, but no card could be bought; the total is
	// back in the customer's credit.
	CustomerOrderRefunded = "refunded"
	// CustomerOrderCancelled, Failed and Expired never got paid; the credit
	// the order held is released.
	CustomerOrderCancelled = "cancelled"
	CustomerOrderFailed    = "failed"
	CustomerOrderExpired   = "expired"
)

// Credit entry kinds.
const (
	// CustomerCreditOrder (negative) is credit an order spends, taken when
	// the order is placed.
	CustomerCreditOrder = "order"
	// CustomerCreditRelease gives back what an unpaid order held.
	CustomerCreditRelease = "release"
	// CustomerCreditRefund returns a paid order's total when no card came.
	CustomerCreditRefund = "refund"
	// CustomerCreditLatePayment is a Dafa payment proven after its order was
	// written off: the customer's money, kept for them.
	CustomerCreditLatePayment = "late_payment"
	// CustomerCreditAdjustment is an operator's grant (positive) or charge
	// (negative), with their note.
	CustomerCreditAdjustment = "adjustment"
)

// CustomerOrderPaymentMismatch is the error code of an order whose payment
// Dafa proved but for another amount (or the other environment): held for
// the operator, never served and never credited automatically.
const CustomerOrderPaymentMismatch = "payment_mismatch"

// CustomerOrderOpen reports whether an order can still change on its own.
func CustomerOrderOpen(status string) bool {
	switch status {
	case CustomerOrderAwaitingPayment, CustomerOrderPaid, CustomerOrderFulfilling:
		return true
	}
	return false
}

// CustomerOrder is one card purchase by a customer.
type CustomerOrder struct {
	ID             string `json:"id"`
	CustomerID     string `json:"customer_id"`
	IdempotencyKey string `json:"idempotency_key"`
	// Channel is the app build that placed it: ios, play, apk or web.
	Channel  string `json:"channel"`
	ItemKey  string `json:"item"`
	BrandKey string `json:"brand"`
	ItemName string `json:"name"`
	Quantity int    `json:"quantity"`
	// UnitPrice and Total are what the customer pays, in dinars. CreditUsed
	// is the part their credit paid; AmountDue the part Dafa collects.
	UnitPrice  string `json:"unit_price"`
	Total      string `json:"total"`
	CreditUsed string `json:"credit_used"`
	AmountDue  string `json:"amount_due"`
	// Fee is the payment gateway's fee, added on top of AmountDue: Dafa
	// collects AmountDue + Fee. Zero when the credit paid everything.
	Fee string `json:"fee"`
	// FeePercent is the gateway's share of a payment, used to work Fee out
	// when the order is placed; it is not stored.
	FeePercent string `json:"-"`
	// Method is the wallet method key ("dafa_sadad"…); empty when credit paid
	// everything. PayerHint is the payer, masked.
	Method      string `json:"method,omitempty"`
	PayerHint   string `json:"payer_hint,omitempty"`
	PaymentID   string `json:"payment_id,omitempty"`
	CheckoutURL string `json:"checkout_url,omitempty"`
	OTPAttempts int    `json:"otp_attempts"`
	Status      string `json:"status"`
	ErrorCode   string `json:"error_code,omitempty"`
	ErrorDetail string `json:"error_detail,omitempty"`
	// PurchaseID is the supplier purchase claimed for it.
	PurchaseID string `json:"purchase_id,omitempty"`
	// LatePaid marks a payment proven after the order was written off and
	// kept as credit.
	LatePaid bool `json:"late_paid,omitempty"`
	TestMode bool `json:"test_mode"`
	// Review marks an order placed by the app stores' review account: its
	// payment and its cards are simulated (no Dafa, no supplier) and it is
	// test money on the books. Never shown to the app.
	Review      bool       `json:"review,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
	PaidAt      *time.Time `json:"paid_at,omitempty"`
	CompletedAt *time.Time `json:"completed_at,omitempty"`
}

// CustomerCreditEntry is one movement of a customer's credit.
type CustomerCreditEntry struct {
	ID         string    `json:"id"`
	CustomerID string    `json:"customer_id"`
	Kind       string    `json:"kind"`
	Amount     string    `json:"amount"`
	OrderID    string    `json:"order_id,omitempty"`
	TestMode   bool      `json:"test_mode"`
	CreatedAt  time.Time `json:"created_at"`
	// Note and Actor are an adjustment's reason and the operator who made
	// it; Reference keeps one adjustment from being made twice.
	Note      string `json:"note,omitempty"`
	Actor     string `json:"actor,omitempty"`
	Reference string `json:"reference,omitempty"`
}

// CustomerOrderFilter narrows a listing.
type CustomerOrderFilter struct {
	CustomerID string
	// Status and Channel, when set, keep only orders with that status (or,
	// for "open", any that can still change) and from that app build.
	Status  string
	Channel string
	// Query matches an order's id, item, brand, name or payment.
	Query string
	// Open lists only orders that can still change.
	Open bool
	// Sweep lists what the reconciler acts on: open orders, and bank-card
	// orders written off before their payment was proven, which Dafa's page
	// may still complete. A wallet payment closed here can never be paid
	// (only the relay confirms it), and a held or late-paid one is settled.
	Sweep bool
	// CreatedAfter, when set, leaves older orders out.
	CreatedAfter time.Time
	Limit        int
}

var (
	ErrCustomerOrderNotFound = errors.New("customer order not found")
	// ErrCustomerOrderKeyReused: the idempotency key names another order's
	// item or quantity.
	ErrCustomerOrderKeyReused = errors.New("customer order idempotency key reused")
)

// CustomerOrderStore is an optional store capability.
type CustomerOrderStore interface {
	// BeginCustomerOrder places an order and, when useCredit, spends as much
	// of the customer's credit on it as it covers. An order fully covered is
	// paid at once. A repeated idempotency key returns the first order with
	// created=false.
	BeginCustomerOrder(ctx context.Context, order CustomerOrder, useCredit bool) (CustomerOrder, bool, error)
	// AttachCustomerOrderPayment records the Dafa payment on an order
	// awaiting one that has none yet; anything else is returned untouched.
	AttachCustomerOrderPayment(ctx context.Context, id, paymentID, checkoutURL string) (CustomerOrder, error)
	// RecordCustomerOrderOTPAttempt counts one payer code, unless the order
	// had limit of them or no longer awaits payment (recorded=false).
	RecordCustomerOrderOTPAttempt(ctx context.Context, id string, limit int) (CustomerOrder, bool, error)
	// PayCustomerOrder records a proven payment. An order awaiting it becomes
	// paid; one already written off keeps its status and the payment becomes
	// the customer's credit (LatePaid). Exactly once: applied=false otherwise.
	PayCustomerOrder(ctx context.Context, id, paymentID string) (CustomerOrder, bool, error)
	// HoldCustomerOrderPayment records, once, that the order's payment was
	// proven for the wrong figure: an order awaiting payment fails with
	// CustomerOrderPaymentMismatch (its held credit released); an order
	// already written off keeps its status and gains the code. applied=false
	// when it was recorded before or the order is past that.
	HoldCustomerOrderPayment(ctx context.Context, id, detail string) (CustomerOrder, bool, error)
	// CloseCustomerOrder ends an order awaiting payment as cancelled, failed
	// or expired, releasing the credit it held.
	CloseCustomerOrder(ctx context.Context, id, status, code, detail string) (CustomerOrder, bool, error)
	// StartCustomerOrderFulfilment ties a paid order to its purchase.
	StartCustomerOrderFulfilment(ctx context.Context, id, purchaseID string) (CustomerOrder, error)
	// FinishCustomerOrder ends a paid or fulfilling order: delivered, or
	// refunded to the customer's credit.
	FinishCustomerOrder(ctx context.Context, id string, delivered bool, code, detail string) (CustomerOrder, bool, error)
	GetCustomerOrder(ctx context.Context, id string) (CustomerOrder, error)
	// FindCustomerOrderByKey is the customer's order with that idempotency
	// key; ErrCustomerOrderNotFound when there is none.
	FindCustomerOrderByKey(ctx context.Context, customerID, key string) (CustomerOrder, error)
	ListCustomerOrders(ctx context.Context, filter CustomerOrderFilter) ([]CustomerOrder, error)
	// ExpireCustomerOrders writes off orders awaiting payment created before
	// the cutoff, releasing their credit, and returns how many.
	ExpireCustomerOrders(ctx context.Context, createdBefore time.Time) (int, error)
	// CustomerCredit is the customer's balance and their newest entries.
	CustomerCredit(ctx context.Context, customerID string, limit int) (string, []CustomerCreditEntry, error)
}

var (
	_ CustomerOrderStore = (*FileStore)(nil)
	_ CustomerOrderStore = (*PostgresStore)(nil)
)

const maxCustomerOrderKey = 128

// --- the rules, shared by both stores --------------------------------------

func normalizeCustomerOrder(order CustomerOrder) (CustomerOrder, *big.Rat, error) {
	order.CustomerID = strings.TrimSpace(order.CustomerID)
	order.IdempotencyKey = strings.TrimSpace(order.IdempotencyKey)
	order.ItemKey = strings.TrimSpace(order.ItemKey)
	order.Method = strings.TrimSpace(order.Method)
	if order.CustomerID == "" || order.ItemKey == "" || order.IdempotencyKey == "" ||
		len(order.IdempotencyKey) > maxCustomerOrderKey || order.Quantity < 1 {
		return CustomerOrder{}, nil, errors.New("customer order needs a customer, an item, a quantity and an idempotency key")
	}
	unit, err := ParseWalletAmount(order.UnitPrice)
	if err != nil || unit.Sign() <= 0 {
		return CustomerOrder{}, nil, fmt.Errorf("customer order unit price %q is not a positive amount", order.UnitPrice)
	}
	total := new(big.Rat).Mul(unit, big.NewRat(int64(order.Quantity), 1))
	order.UnitPrice = FormatWalletAmount(unit)
	order.Total = FormatWalletAmount(total)
	if order.ID == "" {
		id, err := NewInstallationID()
		if err != nil {
			return CustomerOrder{}, nil, err
		}
		order.ID = id
	}
	return order, total, nil
}

// sameCustomerOrder reports whether a replayed request asks for the order the
// key already names.
func sameCustomerOrder(existing, requested CustomerOrder) bool {
	return existing.ItemKey == requested.ItemKey && existing.Quantity == requested.Quantity
}

// placeCustomerOrder fills in what the customer's credit pays. It returns the
// entry spending that credit, or nil.
func placeCustomerOrder(order CustomerOrder, total, balance *big.Rat, useCredit bool, now time.Time) (CustomerOrder, *CustomerCreditEntry) {
	credit := new(big.Rat)
	if useCredit && balance.Sign() > 0 {
		credit.Set(balance)
		if credit.Cmp(total) > 0 {
			credit.Set(total)
		}
	}
	due := new(big.Rat).Sub(total, credit)
	order.CreditUsed = FormatWalletAmount(credit)
	order.AmountDue = FormatWalletAmount(due)
	order.Fee = FormatWalletAmount(customerPaymentFee(due, order.FeePercent))
	order.Status = CustomerOrderAwaitingPayment
	order.CreatedAt, order.UpdatedAt = now, now
	if due.Sign() == 0 {
		order.Status = CustomerOrderPaid
		order.Method, order.PayerHint = "", ""
		order.PaidAt = &now
	}
	if credit.Sign() == 0 {
		return order, nil
	}
	return order, &CustomerCreditEntry{
		CustomerID: order.CustomerID,
		Kind:       CustomerCreditOrder,
		Amount:     FormatWalletAmount(new(big.Rat).Neg(credit)),
		OrderID:    order.ID,
		TestMode:   order.TestMode,
		CreatedAt:  now,
	}
}

// CustomerOrderCharge is what Dafa collects for an order: the part of the
// price its credit did not pay, plus the gateway fee.
func CustomerOrderCharge(order CustomerOrder) string {
	due, err := ParseWalletAmount(order.AmountDue)
	if err != nil {
		return order.AmountDue
	}
	if fee, err := ParseWalletAmount(order.Fee); err == nil {
		due.Add(due, fee)
	}
	return FormatWalletAmount(due)
}

// customerPaymentFee is the fee added on top of due so that the gateway's
// share of the WHOLE payment is covered: the company still receives due.
// The payment is rounded up to the dirham-cent, the finest amount Dafa
// takes, so a rounding never leaves the company paying part of the cut.
func customerPaymentFee(due *big.Rat, percent string) *big.Rat {
	share, err := ParseWalletAmount(percent)
	if err != nil || share.Sign() <= 0 || share.Cmp(big.NewRat(100, 1)) >= 0 || due.Sign() <= 0 {
		return new(big.Rat)
	}
	kept := new(big.Rat).Sub(big.NewRat(100, 1), share)
	charge := new(big.Rat).Quo(new(big.Rat).Mul(due, big.NewRat(100, 1)), kept)
	cents := new(big.Rat).Mul(charge, big.NewRat(100, 1))
	quotient, remainder := new(big.Int).QuoRem(cents.Num(), cents.Denom(), new(big.Int))
	if remainder.Sign() > 0 {
		quotient.Add(quotient, big.NewInt(1))
	}
	charge.SetFrac(quotient, big.NewInt(100))
	return charge.Sub(charge, due)
}

func (o CustomerOrder) creditEntry(kind, amount string, now time.Time) *CustomerCreditEntry {
	value, err := ParseWalletAmount(amount)
	if err != nil || value.Sign() == 0 {
		return nil
	}
	return &CustomerCreditEntry{
		CustomerID: o.CustomerID, Kind: kind, Amount: FormatWalletAmount(value),
		OrderID: o.ID, TestMode: o.TestMode, CreatedAt: now,
	}
}

// payCustomerOrder applies a proven payment.
func payCustomerOrder(order CustomerOrder, paymentID string, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool) {
	if paymentID != "" && order.PaymentID != "" && paymentID != order.PaymentID {
		return order, nil, false
	}
	switch order.Status {
	case CustomerOrderAwaitingPayment:
		order.Status = CustomerOrderPaid
		order.PaidAt = &now
		order.UpdatedAt = now
		order.ErrorCode, order.ErrorDetail = "", ""
		return order, nil, true
	case CustomerOrderCancelled, CustomerOrderFailed, CustomerOrderExpired:
		if order.LatePaid || order.PaymentID == "" {
			return order, nil, false
		}
		order.LatePaid = true
		order.PaidAt = &now
		order.UpdatedAt = now
		return order, order.creditEntry(CustomerCreditLatePayment, order.AmountDue, now), true
	}
	return order, nil, false
}

func closeCustomerOrder(order CustomerOrder, status, code, detail string, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
	switch status {
	case CustomerOrderCancelled, CustomerOrderFailed, CustomerOrderExpired:
	default:
		return order, nil, false, fmt.Errorf("an unpaid order cannot close as %q", status)
	}
	if order.Status != CustomerOrderAwaitingPayment {
		return order, nil, false, nil
	}
	order.Status = status
	order.ErrorCode = truncateRunes(code, 64)
	order.ErrorDetail = truncateRunes(detail, 500)
	order.UpdatedAt = now
	order.CompletedAt = &now
	return order, order.creditEntry(CustomerCreditRelease, order.CreditUsed, now), true, nil
}

func holdCustomerOrderPayment(order CustomerOrder, detail string, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool) {
	if order.ErrorCode == CustomerOrderPaymentMismatch || order.LatePaid {
		return order, nil, false
	}
	switch order.Status {
	case CustomerOrderAwaitingPayment:
		next, entry, applied, _ := closeCustomerOrder(order, CustomerOrderFailed, CustomerOrderPaymentMismatch, detail, now)
		return next, entry, applied
	case CustomerOrderCancelled, CustomerOrderFailed, CustomerOrderExpired:
		order.ErrorCode = CustomerOrderPaymentMismatch
		order.ErrorDetail = truncateRunes(detail, 500)
		order.UpdatedAt = now
		return order, nil, true
	}
	return order, nil, false
}

func startCustomerOrderFulfilment(order CustomerOrder, purchaseID string, now time.Time) CustomerOrder {
	if order.Status == CustomerOrderPaid || (order.Status == CustomerOrderFulfilling && order.PurchaseID == "") {
		order.Status = CustomerOrderFulfilling
		order.PurchaseID = purchaseID
		order.UpdatedAt = now
	}
	return order
}

func finishCustomerOrder(order CustomerOrder, delivered bool, code, detail string, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool) {
	if order.Status != CustomerOrderPaid && order.Status != CustomerOrderFulfilling {
		return order, nil, false
	}
	order.UpdatedAt = now
	order.CompletedAt = &now
	if delivered {
		order.Status = CustomerOrderDelivered
		order.ErrorCode, order.ErrorDetail = "", ""
		return order, nil, true
	}
	order.Status = CustomerOrderRefunded
	order.ErrorCode = truncateRunes(code, 64)
	order.ErrorDetail = truncateRunes(detail, 500)
	return order, order.creditEntry(CustomerCreditRefund, order.Total, now), true
}

// customerOrderSwept is CustomerOrderFilter.Sweep for one order.
func customerOrderSwept(order CustomerOrder) bool {
	if CustomerOrderOpen(order.Status) {
		return true
	}
	switch order.Status {
	case CustomerOrderCancelled, CustomerOrderFailed, CustomerOrderExpired:
		return order.PaymentID != "" && order.CheckoutURL != "" && !order.LatePaid &&
			order.ErrorCode != CustomerOrderPaymentMismatch
	}
	return false
}

// customerOrderMatches applies a listing's status, channel and query.
func customerOrderMatches(order CustomerOrder, filter CustomerOrderFilter) bool {
	switch {
	case filter.Status == "open" && !CustomerOrderOpen(order.Status):
		return false
	case filter.Status != "" && filter.Status != "open" && order.Status != filter.Status:
		return false
	case filter.Channel != "" && order.Channel != filter.Channel:
		return false
	}
	query := strings.ToLower(strings.TrimSpace(filter.Query))
	if query == "" {
		return true
	}
	for _, field := range []string{order.ID, order.ItemKey, order.BrandKey, order.ItemName, order.PaymentID, order.PurchaseID} {
		if strings.Contains(strings.ToLower(field), query) {
			return true
		}
	}
	return false
}

func sumCustomerCredit(entries []CustomerCreditEntry) *big.Rat {
	balance := new(big.Rat)
	for _, entry := range entries {
		if value, ok := new(big.Rat).SetString(entry.Amount); ok {
			balance.Add(balance, value)
		}
	}
	return balance
}

func sortCustomerOrders(orders []CustomerOrder) {
	sort.Slice(orders, func(i, j int) bool {
		if !orders[i].CreatedAt.Equal(orders[j].CreatedAt) {
			return orders[i].CreatedAt.After(orders[j].CreatedAt)
		}
		return orders[i].ID > orders[j].ID
	})
}

// --- file store ------------------------------------------------------------

type fileCustomerOrderData struct {
	Orders  map[string]CustomerOrder `json:"orders,omitempty"`
	Credits []CustomerCreditEntry    `json:"credits,omitempty"`
}

func (s *FileStore) customerOrdersLocked() *fileCustomerOrderData {
	if s.data.CustomerOrders == nil {
		s.data.CustomerOrders = &fileCustomerOrderData{}
	}
	if s.data.CustomerOrders.Orders == nil {
		s.data.CustomerOrders.Orders = map[string]CustomerOrder{}
	}
	return s.data.CustomerOrders
}

func (s *FileStore) appendCustomerCreditLocked(entry *CustomerCreditEntry) error {
	if entry == nil {
		return nil
	}
	data := s.customerOrdersLocked()
	for _, existing := range data.Credits {
		if entry.OrderID != "" && existing.OrderID == entry.OrderID && existing.Kind == entry.Kind {
			return nil
		}
	}
	id, err := NewInstallationID()
	if err != nil {
		return err
	}
	entry.ID = id
	data.Credits = append(data.Credits, *entry)
	return nil
}

func (s *FileStore) customerCreditLocked(customerID string) []CustomerCreditEntry {
	entries := []CustomerCreditEntry{}
	if s.data.CustomerOrders == nil {
		return entries
	}
	for _, entry := range s.data.CustomerOrders.Credits {
		if entry.CustomerID == customerID {
			entries = append(entries, entry)
		}
	}
	return entries
}

func (s *FileStore) BeginCustomerOrder(_ context.Context, order CustomerOrder, useCredit bool) (CustomerOrder, bool, error) {
	order, total, err := normalizeCustomerOrder(order)
	if err != nil {
		return CustomerOrder{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	data := s.customerOrdersLocked()
	for _, existing := range data.Orders {
		if existing.CustomerID == order.CustomerID && existing.IdempotencyKey == order.IdempotencyKey {
			if !sameCustomerOrder(existing, order) {
				return existing, false, ErrCustomerOrderKeyReused
			}
			return existing, false, nil
		}
	}
	if customers := s.data.Customers; customers == nil {
		return CustomerOrder{}, false, ErrCustomerNotFound
	} else if customer, ok := customers.Customers[order.CustomerID]; !ok || customer.DeletedAt != nil {
		return CustomerOrder{}, false, ErrCustomerNotFound
	}
	balance := sumCustomerCredit(s.customerCreditLocked(order.CustomerID))
	placed, entry := placeCustomerOrder(order, total, balance, useCredit, s.clock.Now().UTC())
	if err := s.appendCustomerCreditLocked(entry); err != nil {
		return CustomerOrder{}, false, err
	}
	data.Orders[placed.ID] = placed
	if err := s.saveLocked(); err != nil {
		return CustomerOrder{}, false, err
	}
	return placed, true, nil
}

// mutateCustomerOrder runs one transition under the lock and saves.
func (s *FileStore) mutateCustomerOrder(id string, change func(CustomerOrder, time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error)) (CustomerOrder, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data := s.customerOrdersLocked()
	order, ok := data.Orders[id]
	if !ok {
		return CustomerOrder{}, false, ErrCustomerOrderNotFound
	}
	next, entry, applied, err := change(order, s.clock.Now().UTC())
	if err != nil || !applied {
		return order, false, err
	}
	if err := s.appendCustomerCreditLocked(entry); err != nil {
		return CustomerOrder{}, false, err
	}
	data.Orders[id] = next
	if err := s.saveLocked(); err != nil {
		return CustomerOrder{}, false, err
	}
	return next, true, nil
}

func (s *FileStore) AttachCustomerOrderPayment(_ context.Context, id, paymentID, checkoutURL string) (CustomerOrder, error) {
	order, _, err := s.mutateCustomerOrder(id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		if order.Status != CustomerOrderAwaitingPayment || order.PaymentID != "" {
			return order, nil, false, nil
		}
		order.PaymentID, order.CheckoutURL, order.UpdatedAt = paymentID, checkoutURL, now
		return order, nil, true, nil
	})
	return order, err
}

func (s *FileStore) RecordCustomerOrderOTPAttempt(_ context.Context, id string, limit int) (CustomerOrder, bool, error) {
	return s.mutateCustomerOrder(id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		if order.Status != CustomerOrderAwaitingPayment || order.OTPAttempts >= limit {
			return order, nil, false, nil
		}
		order.OTPAttempts++
		order.UpdatedAt = now
		return order, nil, true, nil
	})
}

func (s *FileStore) PayCustomerOrder(_ context.Context, id, paymentID string) (CustomerOrder, bool, error) {
	return s.mutateCustomerOrder(id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		next, entry, applied := payCustomerOrder(order, paymentID, now)
		return next, entry, applied, nil
	})
}

func (s *FileStore) HoldCustomerOrderPayment(_ context.Context, id, detail string) (CustomerOrder, bool, error) {
	return s.mutateCustomerOrder(id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		next, entry, applied := holdCustomerOrderPayment(order, detail, now)
		return next, entry, applied, nil
	})
}

func (s *FileStore) CloseCustomerOrder(_ context.Context, id, status, code, detail string) (CustomerOrder, bool, error) {
	return s.mutateCustomerOrder(id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		return closeCustomerOrder(order, status, code, detail, now)
	})
}

func (s *FileStore) StartCustomerOrderFulfilment(_ context.Context, id, purchaseID string) (CustomerOrder, error) {
	order, _, err := s.mutateCustomerOrder(id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		next := startCustomerOrderFulfilment(order, purchaseID, now)
		return next, nil, next.Status != order.Status || next.PurchaseID != order.PurchaseID, nil
	})
	return order, err
}

func (s *FileStore) FinishCustomerOrder(_ context.Context, id string, delivered bool, code, detail string) (CustomerOrder, bool, error) {
	return s.mutateCustomerOrder(id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		next, entry, applied := finishCustomerOrder(order, delivered, code, detail, now)
		return next, entry, applied, nil
	})
}

func (s *FileStore) GetCustomerOrder(_ context.Context, id string) (CustomerOrder, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.CustomerOrders == nil {
		return CustomerOrder{}, ErrCustomerOrderNotFound
	}
	order, ok := s.data.CustomerOrders.Orders[id]
	if !ok {
		return CustomerOrder{}, ErrCustomerOrderNotFound
	}
	return order, nil
}

func (s *FileStore) FindCustomerOrderByKey(_ context.Context, customerID, key string) (CustomerOrder, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.CustomerOrders != nil {
		for _, order := range s.data.CustomerOrders.Orders {
			if order.CustomerID == customerID && order.IdempotencyKey == strings.TrimSpace(key) {
				return order, nil
			}
		}
	}
	return CustomerOrder{}, ErrCustomerOrderNotFound
}

func (s *FileStore) ListCustomerOrders(_ context.Context, filter CustomerOrderFilter) ([]CustomerOrder, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	orders := []CustomerOrder{}
	if s.data.CustomerOrders == nil {
		return orders, nil
	}
	for _, order := range s.data.CustomerOrders.Orders {
		if filter.CustomerID != "" && order.CustomerID != filter.CustomerID {
			continue
		}
		if filter.Open && !CustomerOrderOpen(order.Status) {
			continue
		}
		if filter.Sweep && !customerOrderSwept(order) {
			continue
		}
		if !filter.CreatedAfter.IsZero() && order.CreatedAt.Before(filter.CreatedAfter) {
			continue
		}
		if !customerOrderMatches(order, filter) {
			continue
		}
		orders = append(orders, order)
	}
	sortCustomerOrders(orders)
	if filter.Limit > 0 && len(orders) > filter.Limit {
		orders = orders[:filter.Limit]
	}
	return orders, nil
}

func (s *FileStore) ExpireCustomerOrders(_ context.Context, createdBefore time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data := s.customerOrdersLocked()
	now := s.clock.Now().UTC()
	count := 0
	for id, order := range data.Orders {
		if order.Status != CustomerOrderAwaitingPayment || !order.CreatedAt.Before(createdBefore) {
			continue
		}
		next, entry, applied, err := closeCustomerOrder(order, CustomerOrderExpired, "expired", "the payment was not completed in time", now)
		if err != nil || !applied {
			continue
		}
		if err := s.appendCustomerCreditLocked(entry); err != nil {
			return count, err
		}
		data.Orders[id] = next
		count++
	}
	if count == 0 {
		return 0, nil
	}
	return count, s.saveLocked()
}

func (s *FileStore) CustomerCredit(_ context.Context, customerID string, limit int) (string, []CustomerCreditEntry, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	entries := s.customerCreditLocked(customerID)
	balance := sumCustomerCredit(entries)
	// Newest first; entries of the same moment in the reverse of their order.
	slices.Reverse(entries)
	sort.SliceStable(entries, func(i, j int) bool { return entries[i].CreatedAt.After(entries[j].CreatedAt) })
	if limit > 0 && len(entries) > limit {
		entries = entries[:limit]
	}
	return FormatWalletAmount(balance), entries, nil
}

// --- cached store forwarding ---------------------------------------------

var _ CustomerOrderStore = (*CachedInstallationStore)(nil)

var errCustomerOrdersUnsupported = errors.New("customer order store is unavailable")

func (s *CachedInstallationStore) customerOrderStore() (CustomerOrderStore, error) {
	store, ok := s.store.(CustomerOrderStore)
	if !ok {
		return nil, errCustomerOrdersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) BeginCustomerOrder(ctx context.Context, order CustomerOrder, useCredit bool) (CustomerOrder, bool, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return CustomerOrder{}, false, err
	}
	return store.BeginCustomerOrder(ctx, order, useCredit)
}

func (s *CachedInstallationStore) AttachCustomerOrderPayment(ctx context.Context, id, paymentID, checkoutURL string) (CustomerOrder, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return CustomerOrder{}, err
	}
	return store.AttachCustomerOrderPayment(ctx, id, paymentID, checkoutURL)
}

func (s *CachedInstallationStore) RecordCustomerOrderOTPAttempt(ctx context.Context, id string, limit int) (CustomerOrder, bool, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return CustomerOrder{}, false, err
	}
	return store.RecordCustomerOrderOTPAttempt(ctx, id, limit)
}

func (s *CachedInstallationStore) PayCustomerOrder(ctx context.Context, id, paymentID string) (CustomerOrder, bool, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return CustomerOrder{}, false, err
	}
	return store.PayCustomerOrder(ctx, id, paymentID)
}

func (s *CachedInstallationStore) HoldCustomerOrderPayment(ctx context.Context, id, detail string) (CustomerOrder, bool, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return CustomerOrder{}, false, err
	}
	return store.HoldCustomerOrderPayment(ctx, id, detail)
}

func (s *CachedInstallationStore) CloseCustomerOrder(ctx context.Context, id, status, code, detail string) (CustomerOrder, bool, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return CustomerOrder{}, false, err
	}
	return store.CloseCustomerOrder(ctx, id, status, code, detail)
}

func (s *CachedInstallationStore) StartCustomerOrderFulfilment(ctx context.Context, id, purchaseID string) (CustomerOrder, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return CustomerOrder{}, err
	}
	return store.StartCustomerOrderFulfilment(ctx, id, purchaseID)
}

func (s *CachedInstallationStore) FinishCustomerOrder(ctx context.Context, id string, delivered bool, code, detail string) (CustomerOrder, bool, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return CustomerOrder{}, false, err
	}
	return store.FinishCustomerOrder(ctx, id, delivered, code, detail)
}

func (s *CachedInstallationStore) GetCustomerOrder(ctx context.Context, id string) (CustomerOrder, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return CustomerOrder{}, err
	}
	return store.GetCustomerOrder(ctx, id)
}

func (s *CachedInstallationStore) FindCustomerOrderByKey(ctx context.Context, customerID, key string) (CustomerOrder, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return CustomerOrder{}, err
	}
	return store.FindCustomerOrderByKey(ctx, customerID, key)
}

func (s *CachedInstallationStore) ListCustomerOrders(ctx context.Context, filter CustomerOrderFilter) ([]CustomerOrder, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return nil, err
	}
	return store.ListCustomerOrders(ctx, filter)
}

func (s *CachedInstallationStore) ExpireCustomerOrders(ctx context.Context, createdBefore time.Time) (int, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return 0, err
	}
	return store.ExpireCustomerOrders(ctx, createdBefore)
}

func (s *CachedInstallationStore) CustomerCredit(ctx context.Context, customerID string, limit int) (string, []CustomerCreditEntry, error) {
	store, err := s.customerOrderStore()
	if err != nil {
		return "", nil, err
	}
	return store.CustomerCredit(ctx, customerID, limit)
}
