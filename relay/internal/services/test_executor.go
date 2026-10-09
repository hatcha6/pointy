package services

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/vouchers"
)

// SupplierTest is the supplier key of service orders bought in test mode.
const SupplierTest = vouchers.SupplierTest

// maxTestOrdersKept bounds the memory of the fake: it is a development tool.
const maxTestOrdersKept = 20000

// TestExecutor is test mode's supplier: every order succeeds with a fake
// transaction id and a receipt derived from the order's client reference, so a
// replay reads back the same one, and nothing leaves the process. Tokens start
// with TEST so nobody can mistake one for a real payment.
//
// The receipt fields that come from the order (the number, the operator) are
// remembered in memory only; after a restart a read-back still answers with the
// fields the transaction id determines (the id, the reference, a bill's token).
type TestExecutor struct {
	mu    sync.Mutex
	byID  map[string]Result
	byRef map[string]Result
}

// NewTestExecutor builds the fake supplier of test mode.
func NewTestExecutor() *TestExecutor {
	return &TestExecutor{byID: map[string]Result{}, byRef: map[string]Result{}}
}

// Airtime implements Executor.
func (t *TestExecutor) Airtime(_ context.Context, order AirtimeOrder) (Result, error) {
	if strings.TrimSpace(order.ClientRef) == "" {
		return Result{}, &vouchers.Failure{Code: vouchers.FailureRefused, Detail: "a test order needs a reference", Definite: true}
	}
	id := testOrderID(KindAirtime, order.ClientRef)
	result := testResult(KindAirtime, id, map[string]string{
		ReceiptOperator:          order.OperatorName,
		ReceiptPhone:             order.Phone.E164(),
		ReceiptDeliveredAmount:   order.Receive.Amount,
		ReceiptDeliveredCurrency: order.Receive.Currency,
		ReceiptOrderAmount:       FormatAmount(order.Amount),
		ReceiptOrderCurrency:     order.Currency,
	}, "")
	t.remember(KindAirtime, order.ClientRef, result)
	return result, nil
}

// Bill implements Executor.
func (t *TestExecutor) Bill(_ context.Context, order BillOrder) (Result, error) {
	if strings.TrimSpace(order.ClientRef) == "" {
		return Result{}, &vouchers.Failure{Code: vouchers.FailureRefused, Detail: "a test order needs a reference", Definite: true}
	}
	id := testOrderID(KindBill, order.ClientRef)
	token := ""
	if order.Type == BillElectricity && order.Service == ServicePrepaid {
		token = "x"
	}
	paid, currency := order.Receive.Amount, order.Receive.Currency
	if paid == "" || currency == "" {
		paid, currency = FormatAmount(order.Amount), order.Currency
	}
	result := testResult(KindBill, id, map[string]string{
		ReceiptBiller:        order.BillerName,
		ReceiptAccount:       order.Account,
		ReceiptAmount:        paid,
		ReceiptCurrency:      currency,
		ReceiptOrderAmount:   FormatAmount(order.Amount),
		ReceiptOrderCurrency: order.Currency,
	}, token)
	t.remember(KindBill, order.ClientRef, result)
	return result, nil
}

// Lookup implements Executor.
func (t *TestExecutor) Lookup(_ context.Context, kind, orderID string) (Result, error) {
	orderID = strings.TrimSpace(orderID)
	t.mu.Lock()
	known, ok := t.byID[kind+":"+orderID]
	t.mu.Unlock()
	if ok {
		return known, nil
	}
	if _, err := strconv.ParseUint(orderID, 10, 64); err != nil || len(orderID) != 10 {
		return Result{}, fmt.Errorf("%q is not a test order", orderID)
	}
	// Forgotten (the relay restarted): what the id alone determines.
	return testResult(kind, orderID, nil, ""), nil
}

// FindByClientRef implements Executor.
func (t *TestExecutor) FindByClientRef(_ context.Context, kind, clientRef string, _, _ time.Time) ([]Result, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if result, ok := t.byRef[kind+":"+strings.TrimSpace(clientRef)]; ok {
		return []Result{result}, nil
	}
	return nil, nil
}

func (t *TestExecutor) remember(kind, clientRef string, result Result) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.byID) >= maxTestOrdersKept {
		t.byID, t.byRef = map[string]Result{}, map[string]Result{}
	}
	t.byID[kind+":"+result.OrderID] = result
	t.byRef[kind+":"+strings.TrimSpace(clientRef)] = result
}

// testOrderID is the fake transaction id of an order: ten digits derived from
// its kind and client reference.
func testOrderID(kind, clientRef string) string {
	sum := sha256.Sum256([]byte("pointy-relay-test-service:" + kind + ":" + strings.TrimSpace(clientRef)))
	number := binary.BigEndian.Uint64(sum[:8])%9_000_000_000 + 1_000_000_000
	return strconv.FormatUint(number, 10)
}

func testDigits(seed string, count int) string {
	sum := sha256.Sum256([]byte("pointy-relay-test-digits:" + seed))
	var out strings.Builder
	for _, b := range sum {
		out.WriteByte('0' + b%10)
		if out.Len() == count {
			break
		}
	}
	return out.String()
}

// testResult builds the fake outcome of an order from its id. A non-empty
// token asks for a bill token (the value is ignored).
func testResult(kind, id string, fields map[string]string, token string) Result {
	receipt := map[string]string{ReceiptTransactionID: id}
	for key, value := range fields {
		if value != "" {
			receipt[key] = value
		}
	}
	switch kind {
	case KindAirtime:
		receipt[ReceiptOperatorReference] = "TEST-" + testDigits("ref:"+id, 10) + ":OrderConfirmed"
	case KindBill:
		sum := sha256.Sum256([]byte("pointy-relay-test-bill:" + id))
		receipt[ReceiptBillerReference] = "T_" + strings.ToUpper(hex.EncodeToString(sum[:5]))
		if token != "" {
			digits := testDigits("token:"+id, 16)
			receipt[ReceiptToken] = "TEST-" + digits[0:4] + "-" + digits[4:8] + "-" + digits[8:12] + "-" + digits[12:16]
			receipt[ReceiptUnits] = fmt.Sprintf("%s.%s kWh", testDigits("units:"+id, 2), testDigits("tenths:"+id, 1))
		}
	}
	return Result{
		OrderID: id,
		Status:  vouchers.StatusSucceeded,
		CostUSD: "0",
		Receipt: receipt,
		At:      time.Now().UTC(),
	}
}
