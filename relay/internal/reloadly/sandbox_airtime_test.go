package reloadly

import (
	"context"
	"errors"
	"math/big"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// Phone numbers the sandbox accepts, by country. The sandbox checks the country
// and the number's shape, not that it belongs to the operator.
var sandboxPhones = map[string]string{
	"NE": "96123456", "ML": "76123456", "NG": "8031234567", "EG": "1112345678", "LK": "771234567",
	"PE": "951234567", "TN": "98123456", "CV": "9912345", "PH": "9171234567", "KH": "12345678",
}

// cheapTopup is the cheapest plain-airtime top-up in local currency among the
// operators the sandbox has numbers for.
type cheapTopup struct {
	operator Operator
	amount   *big.Rat
	cost     *big.Rat
}

func cheapestLocalTopup(operators []Operator, denomination DenominationType) (cheapTopup, bool) {
	var best cheapTopup
	found := false
	for _, op := range operators {
		if op.DenominationType != denomination || !op.SupportsLocalAmounts || op.Pin || op.Bundle || op.ComboProduct || op.Data {
			continue
		}
		if op.Status != "" && op.Status != "ACTIVE" {
			continue
		}
		if _, known := sandboxPhones[op.Country.ISOName]; !known {
			continue
		}
		amounts := []*big.Rat{}
		if denomination == Range {
			lo, _ := AirtimeLimits(op, true)
			if lo != nil {
				amounts = append(amounts, lo)
			}
		} else {
			for _, plan := range op.LocalFixedAmounts {
				if value, ok := plan.Rat(); ok {
					amounts = append(amounts, value)
				}
			}
		}
		for _, amount := range amounts {
			cost, ok := AirtimeCost(op, amount, true)
			if ok && cost.Sign() > 0 && (!found || cost.Cmp(best.cost) < 0) {
				best, found = cheapTopup{operator: op, amount: amount, cost: cost}, true
			}
		}
	}
	return best, found
}

func topupRequest(op Operator, amount *big.Rat, local bool, number string) TopupRequest {
	return TopupRequest{
		OperatorID:       op.Key(),
		Amount:           NumFromRat(amount, 5),
		UseLocalAmount:   local,
		CustomIdentifier: uniqueID("topup"),
		RecipientPhone:   Phone{CountryCode: op.Country.ISOName, Number: number},
	}
}

func TestSandboxTopups(t *testing.T) {
	c := sandboxClient(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	var api *APIError
	operators, err := c.Operators(ctx)
	if err != nil {
		t.Fatal(err)
	}
	before, err := c.TopupBalance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if costOf(t, before.Balance).Cmp(mustRat(t, "50")) < 0 {
		t.Skipf("the sandbox balance is only %s", before.Balance)
	}

	// 1. A RANGE operator ordered in local currency, and a FIXED one.
	for _, denomination := range []DenominationType{Range, Fixed} {
		pick, ok := cheapestLocalTopup(operators, denomination)
		if !ok {
			t.Logf("no %s operator with a sandbox phone number", denomination)
			continue
		}
		op := pick.operator
		request := topupRequest(op, pick.amount, true, sandboxPhones[op.Country.ISOName])
		start := time.Now()
		result, err := c.Topup(ctx, request)
		if err != nil {
			t.Fatalf("%s %s: %v", denomination, op.Name, err)
		}
		debited := costOf(t, result.Balance.Cost)
		t.Logf("%s local top-up of %s %s on %s (%d): %s in %v, requested %s %s, delivered %s %s, discount %s, fee %s, debited %s, AirtimeCost predicted %s",
			denomination, NumFromRat(pick.amount, 5), op.DestinationCurrencyCode, op.Name, op.Key(), result.Status,
			time.Since(start).Round(time.Millisecond), result.RequestedAmount, result.RequestedAmountCurrencyCode,
			result.DeliveredAmount, result.DeliveredAmountCurrencyCode, result.Discount, result.Fee, debited.FloatString(5), pick.cost.FloatString(5))
		if result.Status.Succeeded() {
			sameWithin(t, op.Name+" local cost", debited, pick.cost, "0.00001")
		}
		if drift := time.Since(result.TransactionDate.Time); drift < -2*time.Minute || drift > 2*time.Minute {
			t.Errorf("transactionDate %v is %v from now: not UTC", result.TransactionDate.Time, drift)
		}
		status, err := c.TopupStatus(ctx, result.TransactionID)
		if err != nil || !status.Status.Succeeded() || status.Transaction == nil || status.Transaction.Balance.Cost != result.Balance.Cost {
			t.Fatalf("status = %+v, err = %v", status, err)
		}
		report, err := c.TopupTransaction(ctx, result.TransactionID)
		if err != nil || report.CustomIdentifier != request.CustomIdentifier {
			t.Fatalf("report = %+v, err = %v", report, err)
		}
		found, err := c.FindTopups(ctx, request.CustomIdentifier, result.TransactionDate.Add(-time.Minute), result.TransactionDate.Add(time.Minute))
		if err != nil || len(found) != 1 || found[0].TransactionID != result.TransactionID {
			t.Fatalf("find = %+v, err = %v", found, err)
		}
		_, err = c.Topup(ctx, request)
		if !IsDuplicateIdentifier(err) || !errors.As(err, &api) {
			t.Fatalf("a reused identifier must be a duplicate: %v", err)
		}
		t.Logf("duplicate customIdentifier on a top-up: HTTP %d %s, definite=%t", api.Status, api.Code, Definite(err))
	}

	// 2. The same operator in USD, and the discount ordering in local currency forfeits.
	pick, ok := cheapestLocalTopup(operators, Range)
	if ok {
		op := pick.operator
		usd := mustRat(t, "0.5")
		if lo, hi := AirtimeLimits(op, false); lo != nil && hi != nil && usd.Cmp(lo) >= 0 && usd.Cmp(hi) <= 0 {
			expected, _ := AirtimeCost(op, usd, false)
			result, err := c.Topup(ctx, topupRequest(op, usd, false, sandboxPhones[op.Country.ISOName]))
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("USD top-up of 0.5 on %s: debited %s, predicted %s, delivered %s %s, discount %s (commission %s%%)",
				op.Name, result.Balance.Cost, expected.FloatString(5), result.DeliveredAmount, result.DeliveredAmountCurrencyCode, result.Discount, op.Commission)
			sameWithin(t, op.Name+" USD cost", costOf(t, result.Balance.Cost), expected, "0.00001")
		}
	}

	// 3. Phone number forms.
	if pick, ok := cheapestLocalTopup(operators, Range); ok {
		op := pick.operator
		national := sandboxPhones[op.Country.ISOName]
		calling := ""
		countries, err := c.TopupCountries(ctx)
		if err != nil {
			t.Fatal(err)
		}
		for _, country := range countries {
			if country.ISOName == op.Country.ISOName && len(country.CallingCodes) > 0 {
				calling = strings.TrimPrefix(country.CallingCodes[0], "+")
			}
		}
		forms := []struct{ label, number string }{
			{"national, no trunk zero", national},
			{"with the country code", calling + national},
			{"with + and the country code", "+" + calling + national},
			{"with 00 and the country code", "00" + calling + national},
			{"national with spaces", national[:2] + " " + national[2:]},
			{"with a trunk zero", "0" + national},
			{"too short", national[:3]},
			{"with letters", "ab" + national[2:]},
		}
		for _, form := range forms {
			request := topupRequest(op, pick.amount, true, form.number)
			result, err := c.Topup(ctx, request)
			switch {
			case err == nil:
				t.Logf("phone %-30q accepted -> recipientPhone %q", form.label+": "+form.number, string(result.RecipientPhone))
			case errors.As(err, &api):
				t.Logf("phone %-30q REFUSED HTTP %d %s (definite=%t)", form.label+": "+form.number, api.Status, api.Code, Definite(err))
			default:
				t.Fatalf("%s: %v", form.label, err)
			}
		}
		for _, form := range []struct{ label, number string }{
			{"national", national}, {"with +", "+" + calling + national}, {"with a trunk zero", "0" + national},
			{"with spaces", national[:2] + " " + national[2:]},
		} {
			detected, err := c.DetectOperator(ctx, op.Country.ISOName, form.number)
			switch {
			case err == nil:
				t.Logf("auto-detect %-20q -> %s (%d)", form.label+": "+form.number, detected.Name, detected.Key())
			case errors.As(err, &api):
				t.Logf("auto-detect %-20q REFUSED HTTP %d %s", form.label+": "+form.number, api.Status, api.Code)
			default:
				t.Fatalf("%v", err)
			}
		}
		// Refusals.
		below := new(big.Rat).Sub(pick.amount, big.NewRat(1, 100))
		_, err = c.Topup(ctx, topupRequest(op, below, true, national))
		if !errors.As(err, &api) || !Definite(err) {
			t.Fatalf("an amount below the minimum must be a definite refusal: %v", err)
		}
		t.Logf("amount below the local minimum: HTTP %d %s %q", api.Status, api.Code, api.Message)
		if _, err := c.Topup(ctx, topupRequest(Operator{ID: 99999999, Country: Country{ISOName: op.Country.ISOName}}, pick.amount, true, national)); errors.As(err, &api) {
			t.Logf("unknown operator: HTTP %d %s, definite=%t", api.Status, api.Code, Definite(err))
		}
	}

	// 4. Not enough balance.
	for _, op := range operators {
		hi := rat(op.MaxAmount)
		phone, known := sandboxPhones[op.Country.ISOName]
		if op.DenominationType != Range || hi == nil || !known || hi.Cmp(mustRat(t, "1000")) < 0 {
			continue
		}
		balance, err := c.TopupBalance(ctx)
		if err != nil {
			t.Fatal(err)
		}
		over := new(big.Rat).Add(costOf(t, balance.Balance), big.NewRat(10, 1))
		if over.Cmp(hi) > 0 {
			continue
		}
		_, err = c.Topup(ctx, topupRequest(op, over, false, phone))
		if !errors.As(err, &api) {
			t.Fatalf("err = %v", err)
		}
		t.Logf("top-up of %s USD with a balance of %s: HTTP %d %s %q, insufficient=%t, definite=%t",
			NumFromRat(over, 2), balance.Balance, api.Status, api.Code, api.Message, IsInsufficientBalance(err), Definite(err))
		if !IsInsufficientBalance(err) || !Definite(err) {
			t.Error("an unaffordable top-up must be a definite insufficient-balance refusal")
		}
		break
	}

	// 5. The asynchronous endpoint.
	if pick, ok := cheapestLocalTopup(operators, Range); ok {
		request := topupRequest(pick.operator, pick.amount, true, sandboxPhones[pick.operator.Country.ISOName])
		start := time.Now()
		id, err := c.TopupAsync(ctx, request)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("async top-up accepted as %d after %v", id, time.Since(start).Round(time.Millisecond))
		var polls int
		var seen []string
		took := eventually(t, 3*time.Minute, 2*time.Second, "the async top-up", func() bool {
			polls++
			status, err := c.TopupStatus(ctx, id)
			if err != nil {
				return false
			}
			if len(seen) == 0 || seen[len(seen)-1] != string(status.Status) {
				seen = append(seen, string(status.Status))
			}
			return status.Status.Final()
		})
		t.Logf("async top-up went through %v in %v (%d polls)", seen, took.Round(time.Second), polls)
	}

	after, err := c.TopupBalance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("top-up spending this run: %s USD", new(big.Rat).Sub(costOf(t, before.Balance), costOf(t, after.Balance)).FloatString(5))
}

// A concurrent duplicate is not stopped by Reloadly; this documents it and
// spends a dollar, so it only runs on request.
func TestSandboxConcurrentDuplicatesAreNotStopped(t *testing.T) {
	c := sandboxClient(t)
	if os.Getenv("RELOADLY_SANDBOX_RACE") == "" {
		t.Skip("set RELOADLY_SANDBOX_RACE=1 to run (spends about one dollar)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	operators, err := c.Operators(ctx)
	if err != nil {
		t.Fatal(err)
	}
	pick, ok := cheapestLocalTopup(operators, Range)
	if !ok {
		t.Skip("no cheap operator")
	}
	request := topupRequest(pick.operator, pick.amount, true, sandboxPhones[pick.operator.Country.ISOName])
	var wg sync.WaitGroup
	var mu sync.Mutex
	outcomes := []string{}
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := c.Topup(ctx, request)
			mu.Lock()
			defer mu.Unlock()
			if err == nil {
				outcomes = append(outcomes, "executed")
			} else if IsDuplicateIdentifier(err) {
				outcomes = append(outcomes, "duplicate")
			} else {
				outcomes = append(outcomes, err.Error())
			}
		}()
	}
	wg.Wait()
	sort.Strings(outcomes)
	found, err := c.FindTopups(ctx, request.CustomIdentifier, time.Time{}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("4 concurrent top-ups with one customIdentifier: %v; Reloadly recorded %d", outcomes, len(found))
}

func TestSandboxUtilityPayments(t *testing.T) {
	c := sandboxClient(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	billers, err := c.Billers(ctx)
	if err != nil {
		t.Fatal(err)
	}
	before, err := c.UtilityBalance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if costOf(t, before.Balance).Cmp(mustRat(t, "50")) < 0 {
		t.Skipf("the sandbox balance is only %s", before.Balance)
	}
	type plan struct {
		biller   Biller
		amount   *big.Rat
		amountID int64
		cost     *big.Rat
	}
	cheapest := func(denomination DenominationType) (plan, bool) {
		var best plan
		found := false
		for _, b := range billers {
			// The sandbox refunds every Nigerian payment, so those are tried apart.
			if b.DenominationType != denomination || !b.LocalAmountSupported || b.RequiresInvoice || b.CountryCode == "NG" {
				continue
			}
			candidates := map[int64]*big.Rat{}
			if denomination == Range {
				if lo, _ := BillLimits(b, true); lo != nil {
					candidates[0] = lo
				}
			} else {
				for _, p := range b.LocalFixedAmounts {
					if value, ok := p.Amount.Rat(); ok {
						candidates[p.ID] = value
					}
				}
			}
			for id, amount := range candidates {
				cost, ok := BillCost(b, amount, true)
				if ok && (!found || cost.Cmp(best.cost) < 0) {
					best, found = plan{biller: b, amount: amount, amountID: id, cost: cost}, true
				}
			}
		}
		return best, found
	}

	pay := func(t *testing.T, p plan, local bool, amount *big.Rat) (PayResult, PayRequest, Payment) {
		t.Helper()
		request := PayRequest{
			BillerID: p.biller.ID, SubscriberAccountNumber: "1234567890", Amount: NumFromRat(amount, 5),
			UseLocalAmount: local, AmountID: p.amountID, ReferenceID: uniqueID("bill"),
		}
		start := time.Now()
		accepted, err := c.Pay(ctx, request)
		if err != nil {
			t.Fatalf("%s: %v", p.biller.Name, err)
		}
		t.Logf("payment %d to %s accepted in %v: status %s, code %s, final status promised by %s",
			accepted.ID, p.biller.Name, time.Since(start).Round(time.Millisecond), accepted.Status, accepted.Code,
			accepted.FinalStatusAvailabilityAt.Format(time.RFC3339))
		if drift := time.Since(accepted.SubmittedAt.Time); drift < -2*time.Minute || drift > 2*time.Minute {
			t.Errorf("submittedAt %v is %v from now: not UTC", accepted.SubmittedAt.Time, drift)
		}
		var final Payment
		took := eventually(t, 5*time.Minute, 2*time.Second, "the payment", func() bool {
			payment, err := c.Payment(ctx, accepted.ID)
			final = payment
			return err == nil && payment.Transaction.Status.Final()
		})
		t.Logf("payment %d settled as %s (%s) after %v: amount %s %s, fee %s %s, discount %s, debited %s, token %q",
			accepted.ID, final.Transaction.Status, final.Code, took.Round(time.Second), final.Transaction.Amount,
			final.Transaction.AmountCurrencyCode, final.Transaction.Fee, final.Transaction.FeeCurrencyCode, final.Transaction.Discount,
			final.Transaction.Balance.Cost, string(final.Transaction.Bill.PinDetails.Token))
		return accepted, request, final
	}

	if p, ok := cheapest(Range); ok {
		t.Run("range biller in local currency", func(t *testing.T) {
			accepted, request, final := pay(t, p, true, p.amount)
			if final.Transaction.Status.Succeeded() {
				sameWithin(t, p.biller.Name+" local cost", costOf(t, final.Transaction.Balance.Cost), p.cost, "0.00001")
			}
			found, err := c.FindPayments(ctx, request.ReferenceID, accepted.SubmittedAt.Add(-time.Minute), accepted.SubmittedAt.Add(time.Minute))
			if err != nil || len(found) != 1 || found[0].Transaction.ID != accepted.ID {
				t.Fatalf("find = %+v, err = %v", found, err)
			}
			_, err = c.Pay(ctx, request)
			var api *APIError
			if !IsDuplicateIdentifier(err) || !errors.As(err, &api) {
				t.Fatalf("a reused reference must be a duplicate: %v", err)
			}
			t.Logf("duplicate referenceId: HTTP %d %s, definite=%t", api.Status, api.Code, Definite(err))
			below := p
			below.amount = new(big.Rat).Sub(p.amount, big.NewRat(1, 1))
			_, err = c.Pay(ctx, PayRequest{BillerID: p.biller.ID, SubscriberAccountNumber: "1234567890", Amount: NumFromRat(below.amount, 2), UseLocalAmount: true, ReferenceID: uniqueID("bill")})
			if !errors.As(err, &api) || !Definite(err) {
				t.Fatalf("an amount below the minimum must be a definite refusal: %v", err)
			}
			t.Logf("amount below the minimum: HTTP %d %s %q", api.Status, api.Code, api.Message)
		})
		t.Run("range biller in USD", func(t *testing.T) {
			lo, _ := BillLimits(p.biller, false)
			if lo == nil {
				t.Skip("no USD limits")
			}
			usd := new(big.Rat).Add(lo, big.NewRat(13, 100))
			expected, ok := BillCost(p.biller, usd, false)
			if !ok {
				t.Skip("not priced in USD")
			}
			_, _, final := pay(t, p, false, usd)
			if final.Transaction.Status.Succeeded() {
				sameWithin(t, p.biller.Name+" USD cost", costOf(t, final.Transaction.Balance.Cost), expected, "0.00001")
			}
		})
	} else {
		t.Log("no cheap RANGE biller")
	}
	if p, ok := cheapest(Fixed); ok {
		t.Run("fixed biller", func(t *testing.T) {
			_, _, final := pay(t, p, true, p.amount)
			if final.Transaction.Status.Succeeded() {
				sameWithin(t, p.biller.Name+" plan cost", costOf(t, final.Transaction.Balance.Cost), p.cost, "0.00001")
			}
			_, err := c.Pay(ctx, PayRequest{BillerID: p.biller.ID, SubscriberAccountNumber: "1234567890", Amount: NumFromRat(p.amount, 2), UseLocalAmount: true, ReferenceID: uniqueID("bill")})
			var api *APIError
			if errors.As(err, &api) {
				t.Logf("a FIXED biller without amountId: HTTP %d %s %q", api.Status, api.Code, api.Message)
			}
		})
	}
	// A Nigerian biller: the sandbox refunds these payments.
	for _, b := range billers {
		if b.CountryCode == "NG" && b.DenominationType == Range && b.LocalAmountSupported {
			lo, _ := BillLimits(b, true)
			cost, _ := BillCost(b, lo, true)
			t.Run("nigerian biller", func(t *testing.T) {
				_, _, final := pay(t, plan{biller: b, amount: lo, cost: cost}, true, lo)
				t.Logf("Nigerian biller %s ended %s, cost %s (the formula says %s if it had succeeded)",
					b.Name, final.Transaction.Status, final.Transaction.Balance.Cost, cost.FloatString(5))
			})
			break
		}
	}
	after, err := c.UtilityBalance(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("utility spending this run: %s USD", new(big.Rat).Sub(costOf(t, before.Balance), costOf(t, after.Balance)).FloatString(5))
}
