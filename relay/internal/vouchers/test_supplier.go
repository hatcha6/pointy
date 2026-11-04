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
//
// Plain is the app stores' review account's: its codes look like any card's
// (digits, grouped), since the reviewer must not be able to tell. Its orders
// are named "review-…", so reading one back needs no setting.
type TestSupplier struct {
	Plain bool
}

const (
	testOrderPrefix   = "test-"
	reviewOrderPrefix = "review-"
	// testAccountMark names an order that sent credit to an account: it has
	// no code to read back.
	testAccountMark = "acct-"
)

var (
	_ TargetBuyer   = TestSupplier{}
	_ TargetChecker = TestSupplier{}
)

func (TestSupplier) Key() string { return SupplierTest }

func (t TestSupplier) Buy(_ context.Context, ref Ref, quantity int, clientRef string) (Purchase, error) {
	if strings.TrimSpace(clientRef) == "" {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: "a test purchase needs a reference", Definite: true}
	}
	// The quantity rides in the id, so a read-back hands back as many codes.
	prefix := testOrderPrefix
	if t.Plain {
		prefix = reviewOrderPrefix
	}
	orderID := fmt.Sprintf("%s%sx%d", prefix, testDigest(clientRef)[:12], max(quantity, 1))
	return testPurchase(orderID, quantity), nil
}

// BuyFor "sends" a test top-up: it succeeds with no code, nothing sent.
func (t TestSupplier) BuyFor(_ context.Context, _ Ref, account Account, clientRef string) (Purchase, error) {
	if strings.TrimSpace(clientRef) == "" {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: "a test purchase needs a reference", Definite: true}
	}
	if !account.Present() {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: ErrAccountRequired.Error(), Definite: true}
	}
	prefix := testOrderPrefix
	if t.Plain {
		prefix = reviewOrderPrefix
	}
	return testAccountPurchase(prefix + testAccountMark + testDigest(clientRef)[:12]), nil
}

// CheckAccount answers every account as valid, under a name that says test
// (a plain one for the review account).
func (t TestSupplier) CheckAccount(_ context.Context, _ Ref, _ Target, account Account) (AccountCheck, error) {
	if !account.Present() {
		return AccountCheck{Status: AccountInvalid}, nil
	}
	if t.Plain {
		return AccountCheck{Status: AccountValid, Name: "Player"}, nil
	}
	return AccountCheck{Status: AccountValid, Name: "TEST PLAYER"}, nil
}

func (TestSupplier) Lookup(_ context.Context, _ Ref, orderID string) (Purchase, error) {
	orderID = strings.TrimSpace(orderID)
	if !strings.HasPrefix(orderID, testOrderPrefix) && !strings.HasPrefix(orderID, reviewOrderPrefix) {
		return Purchase{}, fmt.Errorf("%q is not a test order", orderID)
	}
	if strings.Contains(orderID, testAccountMark) {
		return testAccountPurchase(orderID), nil
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

func testAccountPurchase(orderID string) Purchase {
	return Purchase{OrderID: orderID, Status: StatusSucceeded, Cost: "0", Currency: Currency, At: time.Now().UTC()}
}

func testPurchase(orderID string, quantity int) Purchase {
	purchase := Purchase{
		OrderID:  orderID,
		Status:   StatusSucceeded,
		Cost:     "0",
		Currency: Currency,
		At:       time.Now().UTC(),
	}
	plain := strings.HasPrefix(orderID, reviewOrderPrefix)
	for i := 0; i < max(quantity, 1); i++ {
		digest := strings.ToUpper(testDigest(fmt.Sprintf("%s/%d", orderID, i)))
		code := Code{
			Code:   "TEST-" + digest[0:4] + "-" + digest[4:8] + "-" + digest[8:12],
			Serial: "T" + digest[12:22],
		}
		if plain {
			digits := testDigits(digest)
			code = Code{
				Code:   digits[0:4] + " " + digits[4:8] + " " + digits[8:12] + " " + digits[12:16],
				Serial: digits[16:26],
			}
		}
		purchase.Codes = append(purchase.Codes, code)
	}
	return purchase
}

// testDigits turns a hex digest into as many decimal digits.
func testDigits(digest string) string {
	var digits strings.Builder
	for _, c := range digest {
		value := c - '0'
		if c >= 'A' {
			value = c - 'A' + 10
		}
		digits.WriteRune('0' + value%10)
	}
	return digits.String()
}

func testDigest(value string) string {
	sum := sha256.Sum256([]byte("pointy-relay-test-voucher:" + value))
	return hex.EncodeToString(sum[:])
}
