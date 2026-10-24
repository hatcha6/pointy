package control

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestFileStoreCustomerOrders(t *testing.T) {
	clock := &customerClock{now: time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	exerciseCustomerOrderStore(t, store, store, clock)
	exerciseReviewOrderFlag(t, store, store)
}

func TestCachedStoreKeepsCustomerOrderCapability(t *testing.T) {
	clock := &customerClock{now: time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)}
	inner, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	var cached InstallationStore = NewCachedInstallationStore(inner, newMemoryInstallationCache(), clock, time.Minute)
	orders, ok := cached.(CustomerOrderStore)
	if !ok {
		t.Fatal("cached store must expose the customer order capability")
	}
	exerciseCustomerOrderStore(t, cached.(CustomerStore), orders, clock)
}

func TestPostgresStoreCustomerOrders(t *testing.T) {
	url := os.Getenv("POINTY_RELAY_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("POINTY_RELAY_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := MigratePostgres(ctx, pool); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM relay_customer_credit_entries; DELETE FROM relay_customer_orders;
		DELETE FROM relay_customer_sessions; DELETE FROM relay_customer_otps; DELETE FROM relay_customers`); err != nil {
		t.Fatal(err)
	}
	clock := &customerClock{now: time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)}
	store := &PostgresStore{pool: pool, clock: clock}
	exerciseCustomerOrderStore(t, store, store, clock)
	exerciseReviewOrderFlag(t, store, store)
}

// exerciseReviewOrderFlag: a review order stays one when it is read back and
// as it moves on, so it never turns real if the review account changes.
func exerciseReviewOrderFlag(t *testing.T, customers CustomerStore, store CustomerOrderStore) {
	t.Helper()
	ctx := context.Background()
	phone := "218910000001"
	if _, err := customers.IssueCustomerOTP(ctx, CustomerOTPRequest{Phone: phone, CodeHash: CustomerOTPCodeHash(phone, "246810"), TTL: time.Minute}); err != nil {
		t.Fatal(err)
	}
	customer, _, err := customers.VerifyCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, "246810"), 5)
	if err != nil {
		t.Fatal(err)
	}
	order, created, err := store.BeginCustomerOrder(ctx, CustomerOrder{
		CustomerID: customer.ID, IdempotencyKey: "review-1", Channel: "ios", ItemKey: "libyana-10",
		Quantity: 1, UnitPrice: "10", Method: "dafa_sadad", TestMode: true, Review: true,
	}, false)
	if err != nil || !created || !order.Review {
		t.Fatalf("review order = %+v created=%v err=%v", order, created, err)
	}
	if _, err := store.AttachCustomerOrderPayment(ctx, order.ID, "review-"+order.ID, ""); err != nil {
		t.Fatal(err)
	}
	paid, _, err := store.PayCustomerOrder(ctx, order.ID, "review-"+order.ID)
	if err != nil || !paid.Review || paid.Status != CustomerOrderPaid {
		t.Fatalf("paid review order = %+v err=%v", paid, err)
	}
	read, err := store.GetCustomerOrder(ctx, order.ID)
	if err != nil || !read.Review || !read.TestMode {
		t.Fatalf("read back = %+v err=%v", read, err)
	}
}

func exerciseCustomerOrderStore(t *testing.T, customers CustomerStore, store CustomerOrderStore, clock *customerClock) {
	t.Helper()
	ctx := context.Background()
	phone := "218911234567"
	if _, err := customers.IssueCustomerOTP(ctx, CustomerOTPRequest{Phone: phone, CodeHash: CustomerOTPCodeHash(phone, "123456"), TTL: time.Minute}); err != nil {
		t.Fatal(err)
	}
	customer, _, err := customers.VerifyCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, "123456"), 5)
	if err != nil {
		t.Fatal(err)
	}
	place := func(key string, quantity int, useCredit bool) CustomerOrder {
		t.Helper()
		order, created, err := store.BeginCustomerOrder(ctx, CustomerOrder{
			CustomerID: customer.ID, IdempotencyKey: key, Channel: "apk", ItemKey: "libyana-10",
			Quantity: quantity, UnitPrice: "10", Method: "dafa_sadad",
		}, useCredit)
		if err != nil || !created {
			t.Fatalf("place %s: %+v %v %v", key, order, created, err)
		}
		return order
	}
	balance := func() string {
		t.Helper()
		value, _, err := store.CustomerCredit(ctx, customer.ID, 10)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}

	// An order Dafa pays, then a card that never comes: all of it is credit.
	first := place("k1", 3, false)
	if first.Total != "30.000" || first.AmountDue != "30.000" || first.Status != CustomerOrderAwaitingPayment {
		t.Fatalf("first = %+v", first)
	}
	if replay, created, err := store.BeginCustomerOrder(ctx, CustomerOrder{CustomerID: customer.ID, IdempotencyKey: "k1",
		ItemKey: "libyana-10", Quantity: 3, UnitPrice: "10"}, false); err != nil || created || replay.ID != first.ID {
		t.Fatalf("replay = %+v %v %v", replay, created, err)
	}
	if _, _, err := store.BeginCustomerOrder(ctx, CustomerOrder{CustomerID: customer.ID, IdempotencyKey: "k1",
		ItemKey: "libyana-10", Quantity: 1, UnitPrice: "10"}, false); !errors.Is(err, ErrCustomerOrderKeyReused) {
		t.Fatalf("reused key = %v", err)
	}
	if found, err := store.FindCustomerOrderByKey(ctx, customer.ID, "k1"); err != nil || found.ID != first.ID {
		t.Fatalf("by key = %+v %v", found, err)
	}
	if attached, err := store.AttachCustomerOrderPayment(ctx, first.ID, "pay-1", ""); err != nil || attached.PaymentID != "pay-1" {
		t.Fatalf("attach = %+v %v", attached, err)
	}
	for i := 0; i < 3; i++ {
		_, recorded, _ := store.RecordCustomerOrderOTPAttempt(ctx, first.ID, 2)
		if recorded != (i < 2) {
			t.Fatalf("attempt %d recorded = %v", i, recorded)
		}
	}
	if _, applied, err := store.PayCustomerOrder(ctx, first.ID, "pay-other"); err != nil || applied {
		t.Fatalf("another payment paid the order: %v %v", applied, err)
	}
	paid, applied, err := store.PayCustomerOrder(ctx, first.ID, "pay-1")
	if err != nil || !applied || paid.Status != CustomerOrderPaid || paid.PaidAt == nil {
		t.Fatalf("pay = %+v %v %v", paid, applied, err)
	}
	if _, applied, _ := store.PayCustomerOrder(ctx, first.ID, "pay-1"); applied {
		t.Fatal("paid twice")
	}
	if _, applied, _ := store.CloseCustomerOrder(ctx, first.ID, CustomerOrderCancelled, "x", "y"); applied {
		t.Fatal("a paid order was cancelled")
	}
	if started, err := store.StartCustomerOrderFulfilment(ctx, first.ID, "purchase-1"); err != nil || started.Status != CustomerOrderFulfilling {
		t.Fatalf("fulfil = %+v %v", started, err)
	}
	refunded, applied, err := store.FinishCustomerOrder(ctx, first.ID, false, "supplier_out_of_stock", "no cards")
	if err != nil || !applied || refunded.Status != CustomerOrderRefunded || balance() != "30.000" {
		t.Fatalf("refund = %+v %v %v, balance %s", refunded, applied, err, balance())
	}
	if _, applied, _ := store.FinishCustomerOrder(ctx, first.ID, false, "again", ""); applied || balance() != "30.000" {
		t.Fatal("refunded twice")
	}

	// Credit covers an order whole: paid at once, no method.
	clock.advance(time.Second)
	covered := place("k2", 2, true)
	if covered.Status != CustomerOrderPaid || covered.CreditUsed != "20.000" || covered.AmountDue != "0.000" ||
		covered.Method != "" || balance() != "10.000" {
		t.Fatalf("covered = %+v, balance %s", covered, balance())
	}
	if delivered, applied, err := store.FinishCustomerOrder(ctx, covered.ID, true, "", ""); err != nil || !applied ||
		delivered.Status != CustomerOrderDelivered || balance() != "10.000" {
		t.Fatalf("deliver = %+v %v %v", delivered, applied, err)
	}

	// Credit pays part; the order expires unpaid and gives it back; Dafa
	// proves the payment later and that becomes credit too.
	clock.advance(time.Second)
	partial := place("k3", 5, true)
	if partial.CreditUsed != "10.000" || partial.AmountDue != "40.000" || balance() != "0.000" {
		t.Fatalf("partial = %+v, balance %s", partial, balance())
	}
	store.AttachCustomerOrderPayment(ctx, partial.ID, "pay-3", "https://pay")
	clock.advance(time.Hour)
	if count, err := store.ExpireCustomerOrders(ctx, clock.Now().Add(-30*time.Minute)); err != nil || count != 1 || balance() != "10.000" {
		t.Fatalf("expire = %d %v, balance %s", count, err, balance())
	}
	late, applied, err := store.PayCustomerOrder(ctx, partial.ID, "pay-3")
	if err != nil || !applied || !late.LatePaid || late.Status != CustomerOrderExpired || balance() != "50.000" {
		t.Fatalf("late = %+v %v %v, balance %s", late, applied, err, balance())
	}
	if _, applied, _ := store.PayCustomerOrder(ctx, partial.ID, "pay-3"); applied || balance() != "50.000" {
		t.Fatal("a late payment was credited twice")
	}

	// An order cancelled before any payment started never late-pays.
	clock.advance(time.Second)
	cancelled := place("k4", 1, false)
	if _, applied, err := store.CloseCustomerOrder(ctx, cancelled.ID, CustomerOrderCancelled, "canceled", ""); err != nil || !applied {
		t.Fatal(err)
	}
	if _, applied, _ := store.PayCustomerOrder(ctx, cancelled.ID, ""); applied {
		t.Fatal("an order without a payment was paid late")
	}

	// The sweep sees the open order and nothing settled, held or unpayable:
	// k1 refunded, k2 delivered, k3 late-paid, k4 cancelled before paying.
	if swept, err := store.ListCustomerOrders(ctx, CustomerOrderFilter{Sweep: true}); err != nil || len(swept) != 0 {
		t.Fatalf("swept before k5 = %d %v", len(swept), err)
	}
	open, err := store.ListCustomerOrders(ctx, CustomerOrderFilter{Open: true})
	if err != nil || len(open) != 0 {
		t.Fatalf("open = %+v %v", open, err)
	}
	mine, err := store.ListCustomerOrders(ctx, CustomerOrderFilter{CustomerID: customer.ID, Limit: 2})
	if err != nil || len(mine) != 2 || mine[0].ID != cancelled.ID {
		t.Fatalf("mine = %d %v", len(mine), err)
	}
	_, entries, err := store.CustomerCredit(ctx, customer.ID, 100)
	if err != nil || len(entries) != 5 {
		t.Fatalf("entries = %+v %v", entries, err)
	}

	// The fee is stored and read back with the order.
	clock.advance(time.Second)
	withFee, _, err := store.BeginCustomerOrder(ctx, CustomerOrder{CustomerID: customer.ID, IdempotencyKey: "k5",
		ItemKey: "libyana-10", Quantity: 1, UnitPrice: "10", Method: "dafa_sadad", FeePercent: "2"}, false)
	if err != nil {
		t.Fatal(err)
	}
	if read, err := store.GetCustomerOrder(ctx, withFee.ID); err != nil || read.Fee != "0.210" || CustomerOrderCharge(read) != "10.210" {
		t.Fatalf("fee read back = %+v %v", read, err)
	}
	// Dafa collects it: the fee is booked beside the top-up fees.
	store.AttachCustomerOrderPayment(ctx, withFee.ID, "pay-5", "")
	if _, applied, err := store.PayCustomerOrder(ctx, withFee.ID, "pay-5"); err != nil || !applied {
		t.Fatal(err)
	}

	// Only the delivered order is a sale on the books.
	if finance, ok := store.(FinanceStore); ok {
		months, err := finance.FinanceTracked(ctx, time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC))
		if err != nil || len(months) != 1 || months[0].Revenue[FinanceServiceCardsApp] != "20.000" || months[0].TopUpFees != "0.210" {
			t.Fatalf("books = %+v %v", months, err)
		}
	}
}

func TestCustomerPaymentFeeCoversTheGatewayShare(t *testing.T) {
	for _, tc := range []struct{ due, percent, fee string }{
		{"10", "2", "0.210"},    // 10 / 0.98 = 10.2040… → 10.21
		{"20", "2", "0.410"},    // 20.4081… → 20.41
		{"49.99", "2", "1.030"}, // 51.0102… → 51.02
		{"98", "2", "2.000"},    // exactly 100.00
		{"10", "0", "0.000"},    // no fee configured
		{"10", "", "0.000"},     // unreadable: none
		{"0", "2", "0.000"},     // credit paid everything
		{"10", "100", "0.000"},  // nonsense share: none
	} {
		due, _ := ParseWalletAmount(tc.due)
		if got := FormatWalletAmount(customerPaymentFee(due, tc.percent)); got != tc.fee {
			t.Errorf("fee on %s at %s%% = %s, want %s", tc.due, tc.percent, got, tc.fee)
		}
	}
}

func TestCustomerOrderFeeIsOnlyOnWhatDafaCollects(t *testing.T) {
	clock := &customerClock{now: time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	phone := "218911234567"
	store.IssueCustomerOTP(ctx, CustomerOTPRequest{Phone: phone, CodeHash: CustomerOTPCodeHash(phone, "123456"), TTL: time.Minute})
	customer, _, _ := store.VerifyCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, "123456"), 5)
	place := func(key string, useCredit bool) CustomerOrder {
		order, _, err := store.BeginCustomerOrder(ctx, CustomerOrder{
			CustomerID: customer.ID, IdempotencyKey: key, ItemKey: "x", Quantity: 1, UnitPrice: "10", FeePercent: "2",
		}, useCredit)
		if err != nil {
			t.Fatal(err)
		}
		return order
	}
	first := place("k1", false)
	if first.Fee != "0.210" || CustomerOrderCharge(first) != "10.210" {
		t.Fatalf("first = %+v", first)
	}
	// Paid, then no card: the price comes back as credit, the fee does not
	// (Dafa kept it).
	store.AttachCustomerOrderPayment(ctx, first.ID, "pay-1", "")
	store.PayCustomerOrder(ctx, first.ID, "pay-1")
	store.FinishCustomerOrder(ctx, first.ID, false, "x", "")
	if balance, _, _ := store.CustomerCredit(ctx, customer.ID, 10); balance != "10.000" {
		t.Fatalf("credit after refund = %s", balance)
	}
	// The credit covers the next one: no Dafa, no fee.
	covered := place("k2", true)
	if covered.Fee != "0.000" || CustomerOrderCharge(covered) != "0.000" || covered.Status != CustomerOrderPaid {
		t.Fatalf("covered = %+v", covered)
	}
}
