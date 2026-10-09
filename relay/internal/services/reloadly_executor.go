package services

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
)

// ReloadlyExecutor places and reads orders at Reloadly. An order is ONE call,
// never retried: Reloadly's duplicate check on the identifier is not atomic, so
// a retry that overlaps a slow first attempt would pay twice. What the call
// leaves open is read back by the order's identifier (the purchase's id), which
// Reloadly records on every accepted request.
type ReloadlyExecutor struct {
	Client *reloadly.Client
	// SettleWait is how long an accepted order is waited for before it is left
	// held for the reconciler; zero is DefaultSettleWait. Top-ups answer their
	// final state on the call itself; a bill is accepted first and settles within
	// seconds to a day.
	SettleWait time.Duration
	// PollEvery is the first pause between two reads while waiting; it doubles up
	// to a few seconds. Zero is one second.
	PollEvery time.Duration
	// Sleep pauses between reads; nil is a timer. Tests replace it.
	Sleep func(ctx context.Context, d time.Duration) error
}

func (e *ReloadlyExecutor) settleWait() time.Duration {
	if e.SettleWait > 0 {
		return e.SettleWait
	}
	return DefaultSettleWait
}

func (e *ReloadlyExecutor) pause(ctx context.Context, d time.Duration) error {
	if e.Sleep != nil {
		return e.Sleep(ctx, d)
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// Airtime implements Executor.
func (e *ReloadlyExecutor) Airtime(ctx context.Context, order AirtimeOrder) (Result, error) {
	topup, err := e.Client.Topup(ctx, reloadly.TopupRequest{
		OperatorID:       order.OperatorID,
		Amount:           reloadly.NumFromRat(order.Amount, maxAmountDecimals),
		UseLocalAmount:   order.Local,
		CustomIdentifier: order.ClientRef,
		RecipientPhone:   reloadly.Phone{CountryCode: order.Phone.Country, Number: order.Phone.Digits()},
	})
	if err != nil {
		return Result{}, supplierFailure(err, order.Phone.Digits(), order.Phone.National, order.Phone.E164())
	}
	result := topupResult(topup)
	if result.Status != vouchers.StatusPending {
		return result, nil
	}
	return e.settleTopup(ctx, topup.TransactionID, result), nil
}

// settleTopup waits for an accepted top-up to finish; a top-up still open when
// the wait ends stays pending.
func (e *ReloadlyExecutor) settleTopup(ctx context.Context, id int64, pending Result) Result {
	return e.settle(ctx, pending, func() (Result, error) {
		status, err := e.Client.TopupStatus(ctx, id)
		if err != nil {
			return Result{}, err
		}
		if status.Transaction != nil {
			return topupResult(*status.Transaction), nil
		}
		return statusOnly(strconv.FormatInt(id, 10), status.Status, status.Message), nil
	})
}

// Bill implements Executor.
func (e *ReloadlyExecutor) Bill(ctx context.Context, order BillOrder) (Result, error) {
	accepted, err := e.Client.Pay(ctx, reloadly.PayRequest{
		BillerID:                order.BillerID,
		SubscriberAccountNumber: order.Account,
		Amount:                  reloadly.NumFromRat(order.Amount, maxAmountDecimals),
		UseLocalAmount:          order.Local,
		AmountID:                order.AmountID,
		ReferenceID:             order.ClientRef,
		InvoiceID:               order.InvoiceID,
	})
	if err != nil {
		return Result{}, supplierFailure(err, order.Account, order.InvoiceID)
	}
	pending := statusOnly(strconv.FormatInt(accepted.ID, 10), accepted.Status, accepted.Message)
	if pending.Status == vouchers.StatusFailed {
		return pending, nil
	}
	// Accepted is not paid: the payment is read until it settles, which is also
	// how the token of a prepaid meter is fetched. The accepted answer carries no
	// receipt of its own.
	return e.settle(ctx, pending, func() (Result, error) {
		payment, err := e.Client.Payment(ctx, accepted.ID)
		if err != nil {
			return Result{}, err
		}
		return paymentResult(payment), nil
	}), nil
}

// settle reads an accepted order until it has a final status or the wait ends.
// A read that fails is not a failure of the order: Reloadly has it, so the order
// stays pending and is read again by the reconciler.
func (e *ReloadlyExecutor) settle(ctx context.Context, pending Result, read func() (Result, error)) Result {
	deadline := time.Now().Add(e.settleWait())
	delay := e.PollEvery
	if delay <= 0 {
		delay = time.Second
	}
	last := pending
	for {
		if result, err := read(); err == nil {
			// Reloadly named the order when it accepted it; a read that does not
			// say so again is still about that order.
			result = withOrderID(result, pending.OrderID)
			if result.Status != vouchers.StatusPending {
				return result
			}
			last = result
		}
		if time.Now().Add(delay).After(deadline) || e.pause(ctx, delay) != nil {
			return last
		}
		delay = min(delay*2, 4*time.Second)
	}
}

// Lookup implements Executor.
func (e *ReloadlyExecutor) Lookup(ctx context.Context, kind, orderID string) (Result, error) {
	id, err := strconv.ParseInt(strings.TrimSpace(orderID), 10, 64)
	if err != nil || id <= 0 {
		return Result{}, fmt.Errorf("%q is not a Reloadly transaction id", orderID)
	}
	switch kind {
	case KindAirtime:
		status, err := e.Client.TopupStatus(ctx, id)
		if err != nil {
			return Result{}, err
		}
		if status.Transaction != nil {
			return withOrderID(topupResult(*status.Transaction), orderID), nil
		}
		result := statusOnly(orderID, status.Status, status.Message)
		if result.Status == vouchers.StatusSucceeded {
			// A status without its transaction: the report has the receipt.
			topup, err := e.Client.TopupTransaction(ctx, id)
			if err != nil {
				return Result{}, err
			}
			return withOrderID(topupResult(topup), orderID), nil
		}
		return result, nil
	case KindBill:
		payment, err := e.Client.Payment(ctx, id)
		if err != nil {
			return Result{}, err
		}
		return withOrderID(paymentResult(payment), orderID), nil
	}
	return Result{}, fmt.Errorf("unknown service kind %q", kind)
}

// FindByClientRef implements Executor.
func (e *ReloadlyExecutor) FindByClientRef(ctx context.Context, kind, clientRef string, from, to time.Time) ([]Result, error) {
	clientRef = strings.TrimSpace(clientRef)
	if clientRef == "" {
		return nil, errors.New("a client reference is required")
	}
	var out []Result
	switch kind {
	case KindAirtime:
		rows, err := e.Client.FindTopups(ctx, clientRef, from, to)
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			if strings.EqualFold(strings.TrimSpace(row.CustomIdentifier), clientRef) {
				out = append(out, topupResult(row))
			}
		}
	case KindBill:
		rows, err := e.Client.FindPayments(ctx, clientRef, from, to)
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			if strings.EqualFold(strings.TrimSpace(row.Transaction.ReferenceID), clientRef) {
				out = append(out, paymentResult(row))
			}
		}
	default:
		return nil, fmt.Errorf("unknown service kind %q", kind)
	}
	return out, nil
}

// withOrderID gives a result the order's id when the supplier's answer did not
// carry one (a PROCESSING payment may be described without its transaction): an
// answer about an order is about the order that was asked about, and the ledger
// must keep the name Reloadly gave it, never "0".
func withOrderID(result Result, id string) Result {
	if named(result.OrderID) || !named(id) {
		return result
	}
	result.OrderID = id
	if result.Receipt != nil && !named(result.Receipt[ReceiptTransactionID]) {
		result.Receipt[ReceiptTransactionID] = id
	}
	return result
}

// named reports whether an order id is one: a positive number.
func named(id string) bool {
	n, err := strconv.ParseInt(strings.TrimSpace(id), 10, 64)
	return err == nil && n > 0
}

// supplierStatus is a Reloadly status as the ledger understands it: only
// SUCCESSFUL delivered; REFUNDED and FAILED cost nothing and delivered nothing;
// anything else, an unknown or empty status included, is still open.
func supplierStatus(status reloadly.Status) vouchers.Status {
	switch {
	case status.Succeeded():
		return vouchers.StatusSucceeded
	case status.Unsuccessful():
		return vouchers.StatusFailed
	}
	return vouchers.StatusPending
}

// statusOnly is an order known by its id and status alone.
func statusOnly(orderID string, status reloadly.Status, message string) Result {
	return Result{OrderID: orderID, Status: supplierStatus(status), Message: scrubDigits(message), At: time.Now().UTC()}
}

// topupResult is a top-up as the executor reports it, with its slip.
func topupResult(topup reloadly.TopupResult) Result {
	result := Result{
		OrderID: strconv.FormatInt(topup.TransactionID, 10),
		Status:  supplierStatus(topup.Status),
		At:      topup.TransactionDate.Time,
	}
	if result.At.IsZero() {
		result.At = time.Now().UTC()
	}
	if result.Status != vouchers.StatusSucceeded {
		result.Message = "Reloadly: top-up " + strings.ToLower(string(topup.Status))
		return result
	}
	result.CostUSD = amountText(topup.Balance.Cost)
	receipt := map[string]string{
		ReceiptTransactionID:     result.OrderID,
		ReceiptOperator:          strings.TrimSpace(topup.OperatorName),
		ReceiptDeliveredAmount:   rawAmount(topup.DeliveredAmount),
		ReceiptDeliveredCurrency: strings.ToUpper(strings.TrimSpace(topup.DeliveredAmountCurrencyCode)),
		ReceiptOperatorReference: strings.TrimSpace(string(topup.OperatorTransactionID)),
		ReceiptOrderAmount:       rawAmount(topup.RequestedAmount),
		ReceiptOrderCurrency:     strings.ToUpper(strings.TrimSpace(topup.RequestedAmountCurrencyCode)),
	}
	if digits := onlyDigits(string(topup.RecipientPhone)); digits != "" {
		receipt[ReceiptPhone] = "+" + digits
	}
	result.Receipt = compactReceipt(receipt)
	return result
}

// paymentResult is a bill payment as the executor reports it, with the token
// of a prepaid meter once there is one.
func paymentResult(payment reloadly.Payment) Result {
	transaction := payment.Transaction
	result := Result{
		OrderID: strconv.FormatInt(transaction.ID, 10),
		Status:  supplierStatus(transaction.Status),
		Message: scrubDigits(strings.TrimSpace(payment.Message)),
		At:      transaction.SubmittedAt.Time,
	}
	if result.At.IsZero() {
		result.At = time.Now().UTC()
	}
	if result.Status != vouchers.StatusSucceeded {
		return result
	}
	result.CostUSD = amountText(transaction.Balance.Cost)
	pin := transaction.Bill.PinDetails
	units, other := splitUnits(string(pin.Info1), string(pin.Info2), string(pin.Info3))
	// What the slip says was paid is what the biller received, in its own
	// currency; what was ordered (dollars, usually) is kept beside it.
	paid, currency := rawAmount(transaction.DeliveryAmount), strings.ToUpper(strings.TrimSpace(transaction.DeliveryAmountCurrencyCode))
	if paid == "" || currency == "" {
		paid, currency = rawAmount(transaction.Amount), strings.ToUpper(strings.TrimSpace(transaction.AmountCurrencyCode))
	}
	result.Receipt = compactReceipt(map[string]string{
		ReceiptTransactionID:   result.OrderID,
		ReceiptBiller:          strings.TrimSpace(transaction.Bill.BillerName),
		ReceiptAccount:         strings.TrimSpace(string(transaction.Bill.Subscriber.AccountNumber)),
		ReceiptAmount:          paid,
		ReceiptCurrency:        currency,
		ReceiptOrderAmount:     rawAmount(transaction.Amount),
		ReceiptOrderCurrency:   strings.ToUpper(strings.TrimSpace(transaction.AmountCurrencyCode)),
		ReceiptToken:           strings.TrimSpace(string(pin.Token)),
		ReceiptUnits:           units,
		ReceiptBillerReference: strings.TrimSpace(string(transaction.Bill.BillerReferenceID)),
		ReceiptInfo:            other,
	})
	return result
}

// rawAmount is an amount of Reloadly's exactly as it wrote it, for a receipt: the
// relay does not round, trim or pad what the supplier says it delivered (the shop
// formats it for the currency it is in). Empty when it is not a number. A number
// written with an exponent is spelled out, so no shop meets "2.01E3".
func rawAmount(n reloadly.Num) string {
	if _, ok := n.Rat(); !ok {
		return ""
	}
	text := strings.TrimSpace(string(n))
	if strings.ContainsAny(text, "eE") {
		return amountText(n)
	}
	return text
}

// amountText writes one of Reloadly's amounts the way the wire does: a clean
// decimal of at most five places. It is for the ledger's own figures (the cost),
// never for a receipt's (rawAmount).
func amountText(n reloadly.Num) string {
	if value := rat(n); value != nil {
		return FormatAmount(value)
	}
	return ""
}

func compactReceipt(receipt map[string]string) map[string]string {
	for key, value := range receipt {
		if strings.TrimSpace(value) == "" {
			delete(receipt, key)
		}
	}
	return receipt
}

var unitsPattern = regexp.MustCompile(`(?i)\d\s*(kwh|kw|units?|m3|m³|litres?|liters?)\b|\bunits?\b.*\d`)

func onlyDigits(value string) string {
	return strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, value)
}

// splitUnits finds, among the lines a prepaid biller prints beside the token, the
// one that states what was bought ("10.7 kWh"); the others are kept as notes.
func splitUnits(lines ...string) (units, other string) {
	var rest []string
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if units == "" && unitsPattern.MatchString(line) {
			units = line
			continue
		}
		rest = append(rest, line)
	}
	return units, strings.Join(rest, " | ")
}

// supplierFailure turns a Reloadly error into the ledger's failure. Definite
// means Reloadly provably did nothing (the shop's money comes back at once);
// anything else is held until Reloadly's own records say.
//
// The sentence is redacted: Reloadly may echo the number or the account of the
// order, which the relay does not keep.
func supplierFailure(err error, secrets ...string) *vouchers.Failure {
	failure := &vouchers.Failure{Detail: RedactError(err, secrets...), Definite: reloadly.Definite(err)}
	var api *reloadly.APIError
	switch {
	case reloadly.IsDuplicateIdentifier(err):
		// An earlier order with this identifier exists: it is read back, never
		// treated as a refusal.
		failure.Code, failure.Definite = vouchers.FailureUnknown, false
	case !failure.Definite:
		failure.Code = vouchers.FailureUnknown
	case reloadly.IsInsufficientBalance(err):
		failure.Code = vouchers.FailureCredit
	case reloadly.IsUnauthorized(err):
		failure.Code = vouchers.FailureUnauthorized
	case errors.Is(err, reloadly.ErrOperatorUnavailable):
		failure.Code = vouchers.FailureOutOfStock
	case errors.Is(err, reloadly.ErrRateLimited):
		failure.Code = vouchers.FailureUnreachable
	case errors.As(err, &api) && api.Status >= 400 && api.Status < 500:
		failure.Code = vouchers.FailureRefused
	case errors.Is(err, reloadly.ErrInvalidRequest):
		failure.Code = vouchers.FailureRefused
	default:
		// Provably unsent: a connection that never opened, no token.
		failure.Code = vouchers.FailureUnreachable
	}
	return failure
}
