package services

import (
	"context"
	"testing"
	"time"

	"pointy/relay/internal/reloadly"
)

// A directory is read again every fifteen minutes. What Reloadly changes in its
// commissions, fees, rates and limits must reach the quotes: a price built from
// last week's commission is a price the company loses money on.

func editOperator(id int64, edit func(*reloadly.Operator)) func(*Raw) {
	return func(raw *Raw) {
		for i := range raw.Operators {
			if raw.Operators[i].Key() == id {
				edit(&raw.Operators[i])
			}
		}
	}
}

func editBiller(id int64, edit func(*reloadly.Biller)) func(*Raw) {
	return func(raw *Raw) {
		for i := range raw.Billers {
			if raw.Billers[i].ID == id {
				edit(&raw.Billers[i])
			}
		}
	}
}

func TestWhatTheSupplierChangesReachesTheQuotesAndTheVersion(t *testing.T) {
	airtime := QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "5000", AmountCurrency: "XOF"}
	bill := QuoteRequest{Kind: "bill", BillerID: 26, Amount: "5000", AmountCurrency: "XOF"}
	cases := []struct {
		name  string
		edit  func(*Raw)
		quote QuoteRequest
		// moves is whether the quoted price must move; a change of limits moves
		// the directory and the refusals instead.
		moves bool
	}{
		{"the commission falls from 5 to 1 percent", editOperator(289, func(op *reloadly.Operator) {
			op.Commission, op.InternationalDiscount = "1.0", "1.0"
		}), airtime, true},
		{"a flat fee of 0.10 dollars appears", editOperator(289, func(op *reloadly.Operator) {
			op.Fees.International = "0.10"
		}), airtime, true},
		{"the rate moves from 505 to 490", editOperator(289, func(op *reloadly.Operator) {
			op.FX.Rate = "490.0"
		}), airtime, true},
		{"the limits shrink", editOperator(289, func(op *reloadly.Operator) {
			op.LocalMaxAmount = "20000.0"
		}), airtime, false},
		{"a biller's discount falls", editBiller(26, func(b *reloadly.Biller) {
			b.InternationalDiscountPercentage = "1.0"
		}), bill, true},
		{"a biller's rate moves", editBiller(26, func(b *reloadly.Biller) {
			b.FX.Rate = "440.0"
		}), bill, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			source := &flakySource{}
			clock := &movingClock{now: time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)}
			service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}, Now: clock.Now})
			in := pricing(t, "9.71")
			before, err := service.Directory(context.Background(), in)
			if err != nil {
				t.Fatal(err)
			}
			quotedBefore, refusal := quote(t, service, in, c.quote)
			if refusal != nil {
				t.Fatal(refusal)
			}

			source.set(nil, c.edit)
			clock.advance(15 * time.Minute)
			if err := service.Refresh(context.Background()); err != nil {
				t.Fatal(err)
			}
			after, err := service.Directory(context.Background(), in)
			if err != nil {
				t.Fatal(err)
			}
			if after.Version == before.Version {
				t.Fatalf("the directory's version (its ETag) must move: %s", after.Version)
			}
			quotedAfter, refusal := quote(t, service, in, c.quote)
			if refusal != nil {
				t.Fatal(refusal)
			}
			if c.moves && quotedAfter.Quote.UnitPrice == quotedBefore.Quote.UnitPrice {
				t.Fatalf("the quote still says %s", quotedAfter.Quote.UnitPrice)
			}
			if c.moves && quotedAfter.Prices.CostLYD.Cmp(quotedBefore.Prices.CostLYD) == 0 {
				t.Fatalf("the cost the order is priced from did not move: %s", quotedAfter.Prices.CostLYD.FloatString(5))
			}
			// An order is prepared from the same data.
			if c.moves {
				order := OrderRequest{Kind: c.quote.Kind, OperatorID: c.quote.OperatorID, BillerID: c.quote.BillerID,
					Phone: "70123456", Account: "14500000001", Amount: c.quote.Amount, AmountCurrency: c.quote.AmountCurrency}
				prepared, refusal := service.PrepareOrder(context.Background(), in, order)
				if refusal != nil {
					t.Fatal(refusal)
				}
				if prepared.Prices.Unit.Cmp(quotedAfter.Prices.Unit) != 0 || prepared.Prices.Unit.Cmp(quotedBefore.Prices.Unit) == 0 {
					t.Fatalf("an order is priced from the new data: %s (was %s)", prepared.Prices.Unit.FloatString(3), quotedBefore.Prices.Unit.FloatString(3))
				}
			}
		})
	}
}

func TestTheLimitsAChangeSetAreEnforcedAndShown(t *testing.T) {
	source := &flakySource{}
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}})
	in := pricing(t, "9.71")
	if _, refusal := quote(t, service, in, QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "30000", AmountCurrency: "XOF"}); refusal != nil {
		t.Fatalf("30000 is inside the limits to begin with: %v", refusal)
	}
	source.set(nil, editOperator(289, func(op *reloadly.Operator) { op.LocalMaxAmount = "20000.0" }))
	if err := service.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, refusal := quote(t, service, in, QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "30000", AmountCurrency: "XOF"}); refusal == nil || refusal.Code != "amount_out_of_range" {
		t.Fatalf("30000 is above the new limit: %v", refusal)
	}
	rendered, err := service.Directory(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	if operator := operatorOf(t, rendered.View, "ML", 289); operator.Max != "20000" {
		t.Fatalf("the directory shows the new limit: %+v", operator)
	}
}

func TestAReadingThatChangedNothingKeepsTheDirectoryAndItsMoment(t *testing.T) {
	// The other half of the rule: a quiet supplier is not a new directory.
	source := &flakySource{}
	clock := &movingClock{now: time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)}
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}, Now: clock.Now})
	in := pricing(t, "9.71")
	first, err := service.Directory(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		clock.advance(15 * time.Minute)
		if err := service.Refresh(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	again, err := service.Directory(context.Background(), in)
	if err != nil || again != first || !again.View.GeneratedAt.Equal(first.View.GeneratedAt) {
		t.Fatalf("a quiet supplier changes nothing, not even the moment: %v", err)
	}
}
