package vouchers

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"time"
)

// TestSupplier is test mode's supplier: every purchase succeeds with fake
// codes, derived from the purchase so a replay reads back the same ones, and
// nothing is bought from anyone. Codes start with TEST so nobody can mistake
// one for a card.
type TestSupplier struct{}

func (TestSupplier) Key() string { return SupplierTest }

func (TestSupplier) Buy(_ context.Context, ref Ref, quantity int, clientRef string) (Purchase, error) {
	if strings.TrimSpace(clientRef) == "" {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: "a test purchase needs a reference", Definite: true}
	}
	// The quantity rides in the id, so a read-back hands back as many codes.
	orderID := fmt.Sprintf("test-%sx%d", testDigest(clientRef)[:12], max(quantity, 1))
	return testPurchase(orderID, quantity), nil
}

func (TestSupplier) Lookup(_ context.Context, _ Ref, orderID string) (Purchase, error) {
	orderID = strings.TrimSpace(orderID)
	if !strings.HasPrefix(orderID, "test-") {
		return Purchase{}, fmt.Errorf("%q is not a test order", orderID)
	}
	quantity := 1
	if _, after, ok := strings.Cut(orderID, "x"); ok {
		if _, err := fmt.Sscanf(after, "%d", &quantity); err != nil || quantity < 1 {
			quantity = 1
		}
	}
	return testPurchase(orderID, quantity), nil
}

func (TestSupplier) Find(context.Context, Ref, int, time.Time, time.Time) ([]Purchase, error) {
	// A test purchase always answers, so none is ever lost.
	return nil, nil
}

func (TestSupplier) Offers(context.Context) ([]Offer, error) { return nil, nil }

func testPurchase(orderID string, quantity int) Purchase {
	purchase := Purchase{
		OrderID:  orderID,
		Status:   StatusSucceeded,
		Cost:     "0",
		Currency: Currency,
		At:       time.Now().UTC(),
	}
	for i := 0; i < max(quantity, 1); i++ {
		digest := strings.ToUpper(testDigest(fmt.Sprintf("%s/%d", orderID, i)))
		purchase.Codes = append(purchase.Codes, Code{
			Code:   "TEST-" + digest[0:4] + "-" + digest[4:8] + "-" + digest[8:12],
			Serial: "T" + digest[12:22],
		})
	}
	return purchase
}

func testDigest(value string) string {
	sum := sha256.Sum256([]byte("pointy-relay-test-voucher:" + value))
	return hex.EncodeToString(sum[:])
}
