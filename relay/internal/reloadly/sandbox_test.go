package reloadly

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"os"
	"strings"
	"testing"
	"time"
)

// The sandbox tests talk to Reloadly's SANDBOX hosts (fake money) with a real key
// pair. They are skipped unless both variables are set:
//
//	RELOADLY_SANDBOX_CLIENT_ID
//	RELOADLY_SANDBOX_CLIENT_SECRET
//
// Run them with `go test ./internal/reloadly -run Sandbox -v`; the findings are
// printed with t.Logf. They spend a few dollars of the sandbox balance per run
// (see the package comment for what each purchase costs). They never target a
// live host: sandboxClient refuses to run unless every host is a sandbox one.

func sandboxClient(t *testing.T) *Client {
	t.Helper()
	id := strings.TrimSpace(os.Getenv("RELOADLY_SANDBOX_CLIENT_ID"))
	secret := strings.TrimSpace(os.Getenv("RELOADLY_SANDBOX_CLIENT_SECRET"))
	if id == "" || secret == "" {
		t.Skip("set RELOADLY_SANDBOX_CLIENT_ID and RELOADLY_SANDBOX_CLIENT_SECRET to run the sandbox tests")
	}
	client, err := New(Config{ClientID: id, ClientSecret: secret, Sandbox: true})
	if err != nil {
		t.Fatal(err)
	}
	gift, topups, utilities := client.BaseURLs()
	for _, host := range []string{gift, topups, utilities} {
		if !strings.Contains(host, "-sandbox.reloadly.com") {
			t.Fatalf("refusing to run: %s is not a sandbox host", host)
		}
	}
	return client
}

// uniqueID is a customIdentifier / referenceId that no earlier run used.
func uniqueID(tag string) string { return fmt.Sprintf("ptest-%d-%s", time.Now().UnixNano(), tag) }

// eventually polls until done reports true or the budget ends; it returns the
// time it took.
func eventually(t *testing.T, budget, every time.Duration, what string, done func() bool) time.Duration {
	t.Helper()
	start := time.Now()
	for {
		if done() {
			return time.Since(start)
		}
		if time.Since(start) > budget {
			t.Fatalf("%s did not settle within %v", what, budget)
		}
		time.Sleep(every)
	}
}

func costOf(t *testing.T, n Num) *big.Rat {
	t.Helper()
	value, ok := n.Rat()
	if !ok {
		t.Fatalf("%q is not a number", string(n))
	}
	return value
}

// sameWithin fails when two amounts differ by more than tolerance.
func sameWithin(t *testing.T, what string, got, want *big.Rat, tolerance string) {
	t.Helper()
	diff := new(big.Rat).Sub(got, want)
	if diff.Abs(diff).Cmp(mustRat(t, tolerance)) > 0 {
		t.Errorf("%s: %s, expected %s (tolerance %s)", what, got.FloatString(5), want.FloatString(5), tolerance)
	}
}

func TestSandboxBalancesAndCatalogs(t *testing.T) {
	c := sandboxClient(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	gift, err := c.GiftBalance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	topups, err := c.TopupBalance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	utilities, err := c.UtilityBalance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("balance: gift cards %s %s (updatedAt %q), top-ups %s (updatedAt %q), utilities %s (updatedAt %q): one account, "+
		"updatedAt is written in different zones per service",
		gift.Balance, gift.CurrencyCode, gift.UpdatedAt, topups.Balance, topups.UpdatedAt, utilities.Balance, utilities.UpdatedAt)
	if gift.CurrencyCode != "USD" || topups.CurrencyCode != "USD" || utilities.CurrencyCode != "USD" {
		t.Fatalf("the account is not USD: %s %s %s", gift.CurrencyCode, topups.CurrencyCode, utilities.CurrencyCode)
	}
	// The gift card and utility services write the balance with six decimals, the
	// top-up service with five: the same number, rounded.
	if a, b, d := RoundCost(costOf(t, gift.Balance)), RoundCost(costOf(t, topups.Balance)), RoundCost(costOf(t, utilities.Balance)); a.Cmp(b) != 0 || b.Cmp(d) != 0 {
		t.Errorf("the three services disagree about the balance: %v %v %v", a.FloatString(5), b.FloatString(5), d.FloatString(5))
	}

	t.Run("catalogs", func(t *testing.T) {
		start := time.Now()
		products, err := c.Products(ctx)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("gift products: %d rows in %v", len(products), time.Since(start).Round(time.Second))
		start = time.Now()
		operators, err := c.Operators(ctx)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("operators: %d rows in %v", len(operators), time.Since(start).Round(time.Second))
		billers, err := c.Billers(ctx)
		if err != nil {
			t.Fatal(err)
		}
		countries, err := c.TopupCountries(ctx)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("billers: %d rows, top-up countries: %d", len(billers), len(countries))

		// The paged lists must be complete: compare with the totals Reloadly states.
		for _, check := range []struct {
			what string
			got  int
			p    *productState
			path string
		}{
			{"gift products", len(products), c.gift, "/products"},
			{"operators", len(operators), c.topups, "/operators"},
			{"billers", len(billers), c.utilities, "/billers"},
		} {
			r := c.get(check.p, "count", check.path, map[string][]string{"size": {"1"}, "page": {"1"}})
			raw, err := c.do(ctx, r)
			if err != nil {
				t.Fatal(err)
			}
			var head pageOf[struct{}]
			if err := decode(r, raw, &head); err != nil {
				t.Fatal(err)
			}
			if head.TotalElements != check.got {
				t.Errorf("%s: read %d rows but Reloadly says %d", check.what, check.got, head.TotalElements)
			}
		}
		seen := map[int64]bool{}
		for _, p := range products {
			if p.ID == 0 || seen[p.ID] {
				t.Fatalf("product id %d is missing or repeated", p.ID)
			}
			seen[p.ID] = true
			if p.DenominationType != Fixed && p.DenominationType != Range {
				t.Fatalf("product %d has denomination %q", p.ID, p.DenominationType)
			}
		}
		// A product / operator read on its own is the same row as in the list.
		one, err := c.Product(ctx, products[len(products)/2].ID)
		if err != nil {
			t.Fatal(err)
		}
		if listed := products[len(products)/2]; one.ID != listed.ID || one.Name != listed.Name || one.DenominationType != listed.DenominationType ||
			len(one.FixedRecipientDenominations) != len(listed.FixedRecipientDenominations) {
			t.Errorf("Product(%d) = %+v, the list has %+v", listed.ID, one, listed)
		}
		single, err := c.Operator(ctx, operators[len(operators)/2].Key())
		if err != nil {
			t.Fatal(err)
		}
		if listed := operators[len(operators)/2]; single.Key() != listed.Key() || single.Name != listed.Name ||
			single.FX.Rate != listed.FX.Rate || len(single.FixedAmounts) != len(listed.FixedAmounts) {
			t.Errorf("Operator(%d) = %+v, the list has %+v", listed.Key(), single, listed)
		}
		if _, err := c.Product(ctx, 99999999); !IsNotFound(err) {
			t.Errorf("an unknown product must be a 404: %v", err)
		}
		if _, err := c.Operator(ctx, 99999999); !IsNotFound(err) {
			t.Errorf("an unknown operator must be a 404: %v", err)
		}
		kinds := map[string]int{}
		for _, o := range operators {
			switch {
			case o.Pin:
				kinds["pin"]++
			case o.ComboProduct:
				kinds["combo"]++
			case o.Bundle || o.Data:
				kinds["bundle/data"]++
			default:
				kinds["airtime"]++
			}
		}
		t.Logf("operator kinds: %v", kinds)
		for _, country := range countries {
			if country.ISOName == "LY" {
				t.Errorf("Libya unexpectedly supported: %+v", country)
			}
		}
	})
}

func TestSandboxGiftCard(t *testing.T) {
	c := sandboxClient(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	products, err := c.Products(ctx)
	if err != nil {
		t.Fatal(err)
	}
	byName := func(name string) (GiftProduct, bool) {
		for _, p := range products {
			if p.Name == name {
				return p, true
			}
		}
		return GiftProduct{}, false
	}
	before, err := c.GiftBalance(ctx)
	if err != nil {
		t.Fatal(err)
	}

	// 1. A cheap FIXED product: order, price check, codes, read-backs, duplicate.
	target, ok := byName("Target US")
	if !ok {
		t.Skip("Target US is not in the sandbox catalog")
	}
	face := mustRat(t, "1")
	expected, ok := GiftCost(target, face)
	if !ok {
		t.Fatalf("Target US $1 is not priced: %+v", target)
	}
	identifier := uniqueID("gift")
	order, err := c.OrderGiftCard(ctx, GiftOrderRequest{
		ProductID: target.ID, Quantity: 1, UnitPrice: "1", CustomIdentifier: identifier, SenderName: "Pointy",
	})
	if err != nil {
		t.Fatalf("order: %v", err)
	}
	t.Logf("gift order %d: status %s, amount %s, fee %s, discount %s, cost %s, created %s; GiftCost predicted %s",
		order.TransactionID, order.Status, order.Amount, order.Fee, order.Discount, order.Balance.Cost,
		order.CreatedAt.Format(time.RFC3339), expected.FloatString(5))
	if !order.Status.Succeeded() {
		t.Errorf("status = %s", order.Status)
	}
	sameWithin(t, "Target US $1 cost", costOf(t, order.Balance.Cost), expected, "0.00001")
	if drift := time.Since(order.CreatedAt.Time); drift < -2*time.Minute || drift > 2*time.Minute {
		t.Errorf("the order time %v is %v from now: timestamps are not UTC", order.CreatedAt.Time, drift)
	}

	codes, err := c.GiftRedeemCodes(ctx, order.TransactionID)
	if err != nil || len(codes) != 1 {
		t.Fatalf("codes = %+v, err = %v", codes, err)
	}
	t.Logf("redeem codes (v2): card number %q, pin set %t, url %q", codes[0].CardNumber, codes[0].PinCode != "", codes[0].RedemptionURL)

	again, err := c.GiftTransaction(ctx, order.TransactionID)
	if err != nil || again.CustomIdentifier != identifier || again.Balance.Cost != order.Balance.Cost {
		t.Fatalf("read back = %+v, err = %v", again, err)
	}
	found, err := c.FindGiftTransactions(ctx, identifier, order.CreatedAt.Add(-time.Minute), order.CreatedAt.Add(time.Minute))
	if err != nil || len(found) != 1 || found[0].TransactionID != order.TransactionID {
		t.Fatalf("find by identifier = %+v, err = %v", found, err)
	}
	// Reloadly's search is case-insensitive.
	upper, err := c.FindGiftTransactions(ctx, strings.ToUpper(identifier), time.Time{}, time.Time{})
	t.Logf("find by the upper-cased identifier: %d match(es), err %v", len(upper), err)
	window, err := c.FindGiftTransactions(ctx, "", order.CreatedAt.Add(-time.Second), order.CreatedAt.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("orders in a 2 s window around the order, without an identifier: %d", len(window))
	if len(window) == 0 {
		t.Error("the window search lost the order")
	}

	_, err = c.OrderGiftCard(ctx, GiftOrderRequest{
		ProductID: target.ID, Quantity: 1, UnitPrice: "1", CustomIdentifier: identifier, SenderName: "Pointy",
	})
	var api *APIError
	if !IsDuplicateIdentifier(err) || !errors.As(err, &api) {
		t.Fatalf("a reused identifier must be a duplicate: %v", err)
	}
	t.Logf("duplicate customIdentifier: HTTP %d %s %q, definite=%t", api.Status, api.Code, api.Message, Definite(err))

	// 2. Refusals cost nothing and are definite.
	_, err = c.OrderGiftCard(ctx, GiftOrderRequest{ProductID: target.ID, Quantity: 1, UnitPrice: "7", CustomIdentifier: uniqueID("g"), SenderName: "Pointy"})
	if !errors.As(err, &api) || !Definite(err) {
		t.Fatalf("an invalid price must be a definite refusal: %v", err)
	}
	t.Logf("invalid price: HTTP %d %s %q", api.Status, api.Code, api.Message)
	_, err = c.OrderGiftCard(ctx, GiftOrderRequest{ProductID: 99999999, Quantity: 1, UnitPrice: "1", CustomIdentifier: uniqueID("g"), SenderName: "Pointy"})
	if !errors.As(err, &api) || !Definite(err) {
		t.Fatalf("an unknown product must be a definite refusal: %v", err)
	}
	t.Logf("unknown product: HTTP %d %s %q", api.Status, api.Code, api.Message)
	if amazon, ok := byName("Amazon US"); ok {
		_, err = c.OrderGiftCard(ctx, GiftOrderRequest{ProductID: amazon.ID, Quantity: 2, UnitPrice: "60", CustomIdentifier: uniqueID("g"), SenderName: "Pointy"})
		if errors.As(err, &api) {
			t.Logf("an order worth more than 100 USD: HTTP %d code %q %q, definite=%t", api.Status, api.Code, api.Message, Definite(err))
		}
	}
	_, err = c.FindGiftTransactions(ctx, uniqueID("none"), time.Time{}, time.Time{})
	if err != nil {
		t.Fatalf("an identifier nobody used is an empty answer, not an error: %v", err)
	}
	if _, err := c.GiftTransaction(ctx, 99999999); !IsNotFound(err) {
		t.Fatalf("an unknown transaction is a 404: %v", err)
	}

	// 3. A RANGE product in a foreign currency: the estimate against the debit.
	if ksa, ok := byName("Amazon - KSA"); ok {
		face := mustRat(t, "10")
		if low, high, ok := GiftCostBounds(ksa, face, 1); ok {
			spent, err := c.OrderGiftCard(ctx, GiftOrderRequest{ProductID: ksa.ID, Quantity: 1, UnitPrice: "10", CustomIdentifier: uniqueID("gift"), SenderName: "Pointy"})
			if err != nil {
				t.Fatal(err)
			}
			debited := costOf(t, spent.Balance.Cost)
			t.Logf("%s SAR 10: debited %s, estimated within [%s, %s] (published rate %s)",
				ksa.Name, debited.FloatString(5), low.FloatString(5), high.FloatString(5), ksa.RecipientToSenderRate)
			if debited.Cmp(low) < 0 || debited.Cmp(high) > 0 {
				t.Errorf("the debit is outside the estimate")
			}
		}
	}

	// 4. A card that settles later (virtual prepaid card): PROCESSING, then final.
	if card, ok := byName("Mastercard (Virtual) 1$ to $100 US"); ok {
		order, err := c.OrderGiftCard(ctx, GiftOrderRequest{ProductID: card.ID, Quantity: 1, UnitPrice: "1.234", CustomIdentifier: uniqueID("gift"), SenderName: "Pointy"})
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("virtual card order: status %s (final=%t), cost %s", order.Status, order.Status.Final(), order.Balance.Cost)
		took := eventually(t, 3*time.Minute, 3*time.Second, "the virtual card order", func() bool {
			tx, err := c.GiftTransaction(ctx, order.TransactionID)
			return err == nil && tx.Status.Final()
		})
		t.Logf("virtual card order settled after %v", took.Round(time.Second))
	}

	after, err := c.GiftBalance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("gift card spending this run: %s USD", new(big.Rat).Sub(costOf(t, before.Balance), costOf(t, after.Balance)).FloatString(5))
}
