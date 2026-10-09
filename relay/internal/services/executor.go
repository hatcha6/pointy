package services

import (
	"context"
	"math/big"
	"strings"
	"time"

	"pointy/relay/internal/vouchers"
)

// Executor is how an order reaches the supplier. The HTTP layer prepares and
// charges an order, calls one of Airtime or Bill exactly once, and settles the
// ledger from what comes back; Lookup and FindByClientRef are how an order whose
// answer was lost, or that is still open, is read again. Reloadly implements it
// (ReloadlyExecutor); so does the fake of test mode (TestExecutor), which lets the
// whole path be exercised without a supplier and without money.
//
// An order is never retried. A failure is a *vouchers.Failure whose Definite says
// whether nothing can have been bought (the shop's money comes back at once) or
// whether the supplier may have acted (the order is held until its own records
// say), exactly as for cards.
type Executor interface {
	// Airtime sends credit to a phone number.
	Airtime(ctx context.Context, order AirtimeOrder) (Result, error)
	// Bill pays a bill.
	Bill(ctx context.Context, order BillOrder) (Result, error)
	// Lookup reads an order the supplier named (its id, without the ledger's
	// kind prefix). The receipt is re-read every time and kept nowhere.
	Lookup(ctx context.Context, kind, orderID string) (Result, error)
	// FindByClientRef looks for the order a purchase placed when its answer was
	// lost: every order carrying clientRef (the purchase's id), oldest first.
	// An empty answer means the supplier's records, read completely, hold none.
	FindByClientRef(ctx context.Context, kind, clientRef string, from, to time.Time) ([]Result, error)
}

// AirtimeOrder is one top-up to place.
type AirtimeOrder struct {
	// ClientRef is unique to the purchase (its id). The supplier records it with
	// the order, which is how a lost answer is found again.
	ClientRef  string
	OperatorID int64
	// OperatorName is the supplier's own name for the operator; the fake of test
	// mode puts it on its receipts.
	OperatorName string
	Phone        Phone
	// Amount, Currency and Local are the order as the supplier receives it: the
	// currency of Amount, and whether that is the operator's own (destination)
	// currency rather than dollars. An order for a local amount is usually placed
	// in dollars, to keep the supplier's commission (see ordering.go).
	Amount   *big.Rat
	Currency string
	Local    bool
	// Receive is what the recipient should be credited, as the directory said.
	Receive Money
}

// BillOrder is one bill to pay.
type BillOrder struct {
	ClientRef  string
	BillerID   int64
	BillerName string
	Account    string
	// InvoiceID is the invoice number of a biller that requires one.
	InvoiceID string
	// Amount, Currency and Local are the order as the supplier receives it
	// (dollars when the company orders in dollars); Receive is what the biller
	// is to be paid, in its own currency.
	Amount   *big.Rat
	Currency string
	Local    bool
	Receive  Money
	// AmountID names the plan of a fixed biller; zero for a range one.
	AmountID int64
	// Type and Service (electricity, prepaid…) only tell the fake of test mode
	// whether the bill hands back a token; the supplier is told neither.
	Type    string
	Service string
}

// Result is what a supplier says about one order.
type Result struct {
	// OrderID is the supplier's id for the order, as the supplier writes it.
	OrderID string
	// Status: succeeded delivered it, failed did not and cost nothing, pending
	// is accepted and not finished (a bill can stay so for a day).
	Status vouchers.Status
	// CostUSD is what the supplier debited the company, in dollars.
	CostUSD string
	// Receipt is what the recipient's slip prints; the keys are the Receipt*
	// constants. It is read from the supplier and never stored.
	Receipt map[string]string
	// Message is the supplier's own word, on a failure or while pending.
	Message string
	At      time.Time
}

// The keys of a receipt. An airtime receipt has TransactionID, Operator, Phone,
// DeliveredAmount, DeliveredCurrency and OperatorReference; a bill receipt has
// TransactionID, Biller, Account, Amount, Currency, Token, Units and
// BillerReference (Info carries any other line the biller printed).
const (
	ReceiptTransactionID     = "transaction_id"
	ReceiptOperator          = "operator"
	ReceiptPhone             = "phone"
	ReceiptDeliveredAmount   = "delivered_amount"
	ReceiptDeliveredCurrency = "delivered_currency"
	ReceiptOperatorReference = "operator_reference"
	ReceiptOrderAmount       = "order_amount"
	ReceiptOrderCurrency     = "order_currency"
	ReceiptBiller            = "biller"
	ReceiptAccount           = "account"
	ReceiptAmount            = "amount"
	ReceiptCurrency          = "currency"
	ReceiptToken             = "token"
	ReceiptUnits             = "units"
	ReceiptBillerReference   = "biller_reference"
	ReceiptInfo              = "info"
	// ReceiptTestMode is added by the relay (never by a supplier) to the receipt
	// of an order that is not real money: a fake supplier's, or Reloadly's
	// sandbox's. Its value is the text "true"; a live receipt has no such key.
	ReceiptTestMode = "test_mode"
)

// SupplierReloadly is the supplier key of service orders bought from Reloadly.
const SupplierReloadly = "reloadly"

// OrderRef is a supplier order id as the ledger keeps it: the kind in front
// ("airtime:4602843", "bill:36"). Reloadly numbers top-ups, payments and gift
// cards separately, and the ledger allows one purchase per (supplier, order id),
// so a bare id would let a bill paid as number 36 collide with a card bought as
// number 36.
func OrderRef(kind, orderID string) string {
	orderID = strings.TrimSpace(orderID)
	if orderID == "" || orderID == "0" {
		// "0" is what a missing number reads as: an order with no name, never an
		// order named 0 (two of them would claim the same ledger id).
		return ""
	}
	return kind + ":" + orderID
}

// SplitOrderRef is the supplier's own id out of a ledger order id. An id
// without the kind in front (one an operator typed by hand) is returned as it is.
func SplitOrderRef(kind, ref string) string {
	ref = strings.TrimSpace(ref)
	return strings.TrimPrefix(ref, kind+":")
}
