package services

import (
	"context"
	"encoding/json"
	"math/big"
	"testing"

	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
)

// pricingJSON is the pricing input of a settings document.
func pricingJSON(t *testing.T, document string) PricingInput {
	t.Helper()
	settings, err := vouchers.ParseSettings([]byte(document))
	if err != nil {
		t.Fatal(err)
	}
	_, key, err := vouchers.EncodeSettings(settings)
	if err != nil {
		t.Fatal(err)
	}
	return PricingInput{Settings: settings, SettingsKey: key}
}

func airtimeOrder(t *testing.T, service *Service, in PricingInput, operator int64, phone, amount, currency string) *PreparedOrder {
	t.Helper()
	prepared, refusal := service.PrepareOrder(context.Background(), in, OrderRequest{
		Kind: "airtime", OperatorID: operator, Phone: phone, Amount: amount, AmountCurrency: currency,
	})
	if refusal != nil {
		t.Fatalf("operator %d %s %s: %v", operator, amount, currency, refusal)
	}
	return prepared
}

func billOrder(t *testing.T, service *Service, in PricingInput, biller int64, account, invoice, amount, currency string) *PreparedOrder {
	t.Helper()
	prepared, refusal := service.PrepareOrder(context.Background(), in, OrderRequest{
		Kind: "bill", BillerID: biller, Account: account, InvoiceID: invoice, Amount: amount, AmountCurrency: currency,
	})
	if refusal != nil {
		t.Fatalf("biller %d %s %s: %v", biller, amount, currency, refusal)
	}
	return prepared
}

func detailsOf(t *testing.T, prepared *PreparedOrder) map[string]any {
	t.Helper()
	var details map[string]any
	if err := json.Unmarshal(prepared.Details, &details); err != nil {
		t.Fatal(err)
	}
	return details
}

func TestAirtimeIsOrderedInDollarsByDefaultAndExactlyInLocalMode(t *testing.T) {
	service := fixtureService(t)
	dollars := pricing(t, "9.71")
	local := pricingJSON(t, `{"usd_rate": "9.71", "airtime": {"order_mode": "local"}}`)

	usd := airtimeOrder(t, service, dollars, 289, "70123456", "5000", "XOF")
	exact := airtimeOrder(t, service, local, 289, "70123456", "5000", "XOF")

	// Orange Mali at 505 CFA francs to the dollar: 5,000 is 9.90099 dollars; with
	// the half-percent buffer, rounded up, 9.9505 are ordered.
	if usd.Airtime.Local || usd.Airtime.Currency != "USD" || usd.Airtime.Amount.Cmp(rn("9.9505")) != 0 {
		t.Fatalf("usd mode orders dollars: %+v", usd.Airtime)
	}
	if !exact.Airtime.Local || exact.Airtime.Currency != "XOF" || exact.Airtime.Amount.Cmp(rn("5000")) != 0 {
		t.Fatalf("local mode orders the exact amount: %+v", exact.Airtime)
	}
	// The customer is promised the same either way, and not marked approximate.
	if usd.Receive != exact.Receive || usd.Receive != (Money{Amount: "5000", Currency: "XOF"}) || usd.Approximate || exact.Approximate {
		t.Fatalf("receive: %+v / %+v", usd.Receive, exact.Receive)
	}
	// The commission is the whole point: 5 % off the dollars, so a cheaper price.
	if usd.Prices.Unit.Cmp(exact.Prices.Unit) >= 0 || usd.Prices.CostLYD.Cmp(exact.Prices.CostLYD) >= 0 {
		t.Fatalf("a dollar order must cost less: %s vs %s", usd.Prices.UnitString(), exact.Prices.UnitString())
	}
	// 9.9505 x 0.95 = 9.452975, rounded by Reloadly to five decimals.
	wantCost, _ := reloadly.AirtimeCost(service.mustOperator(t, 289).raw, rn("9.9505"), false)
	if wantCost.Cmp(rn("9.45298")) != 0 {
		t.Fatalf("cost %s", wantCost.FloatString(5))
	}
	if got := detailsOf(t, usd); got["order_mode"] != "usd" || got["order_currency"] != "USD" || got["order_amount"] != "9.9505" || got["buffer_percent"] != "0.5" {
		t.Fatalf("details: %v", got)
	}
	if got := detailsOf(t, exact); got["order_mode"] != "local" || got["order_currency"] != "XOF" || got["order_amount"] != "5000" {
		t.Fatalf("details: %v", got)
	} else if _, has := got["buffer_percent"]; has {
		t.Fatalf("an exact order has no buffer: %v", got)
	}
	// The item the shop is charged for is the same: the ledger key, the name.
	if usd.ItemKey != exact.ItemKey || usd.Name != exact.Name {
		t.Fatalf("%s %s / %s %s", usd.ItemKey, usd.Name, exact.ItemKey, exact.Name)
	}
	// The quote and the directory price what the order is charged.
	quoted, refusal := quote(t, service, dollars, QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "5000", AmountCurrency: "XOF"})
	if refusal != nil || quoted.Quote.UnitPrice != usd.Prices.UnitString() {
		t.Fatalf("quote %+v vs order %s", quoted, usd.Prices.UnitString())
	}
}

func (s *Service) mustOperator(t *testing.T, id int64) *operatorEntry {
	t.Helper()
	snap, err := s.current(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	entry, ok := snap.operators[id]
	if !ok {
		t.Fatalf("operator %d", id)
	}
	return entry
}

func (s *Service) mustBiller(t *testing.T, id int64) *billerEntry {
	t.Helper()
	snap, err := s.current(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	entry, ok := snap.billers[id]
	if !ok {
		t.Fatalf("biller %d", id)
	}
	return entry
}

func TestTheBufferIsTheOwnersToSet(t *testing.T) {
	service := fixtureService(t)
	none := pricingJSON(t, `{"usd_rate": "9.71", "airtime": {"usd_buffer_percent": "0"}}`)
	big := pricingJSON(t, `{"usd_rate": "9.71", "airtime": {"usd_buffer_percent": "2"}}`)
	// 5,000 CFA francs at 505: 9.900990099…, rounded UP to five decimals.
	if got := airtimeOrder(t, service, none, 289, "70123456", "5000", "XOF").Airtime.Amount; got.Cmp(rn("9.90100")) != 0 {
		t.Fatalf("no buffer still rounds up: %s", got.FloatString(5))
	}
	// 9.900990099 x 1.02 = 10.0990099…
	if got := airtimeOrder(t, service, big, 289, "70123456", "5000", "XOF").Airtime.Amount; got.Cmp(rn("10.09901")) != 0 {
		t.Fatalf("a 2 %% buffer: %s", got.FloatString(5))
	}
}

func TestADollarOrderNeverDeliversLessThanAsked(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	rendered, err := service.Directory(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	checked, dollars := 0, 0
	for _, country := range rendered.View.Countries {
		if country.Airtime == nil {
			continue
		}
		for _, operator := range country.Airtime.Operators {
			entry := service.mustOperator(t, operator.ID)
			if !entry.local || entry.fixed {
				continue
			}
			// The tiles, the limits and a few amounts between.
			amounts := []string{operator.Min, operator.Max}
			for _, amount := range operator.Amounts {
				amounts = append(amounts, amount.Amount)
			}
			for _, text := range amounts {
				amount := rn(text)
				plan, ok := entry.plan(in.Settings, amount)
				if !ok {
					t.Fatalf("%s %s must be orderable", operator.NameEN, text)
				}
				checked++
				if plan.Local {
					continue
				}
				dollars++
				delivered := new(big.Rat).Mul(plan.Amount, positiveRat(entry.raw.FX.Rate))
				if delivered.Cmp(amount) < 0 {
					t.Fatalf("%s: %s %s ordered as %s dollars delivers only %s", operator.NameEN, text, operator.AmountCurrency,
						plan.Amount.FloatString(5), delivered.FloatString(2))
				}
				if !reloadly.AirtimeAmountAllowed(entry.raw, plan.Amount, false) {
					t.Fatalf("%s: %s dollars is outside the dollar limits", operator.NameEN, plan.Amount.FloatString(5))
				}
				if len(plan.Amount.FloatString(8)) > 0 && ceilDecimals(plan.Amount, 5).Cmp(plan.Amount) != 0 {
					t.Fatalf("a dollar order has at most five decimals: %s", plan.Amount)
				}
			}
		}
	}
	if checked < 100 || dollars < checked/2 {
		t.Fatalf("most amounts are ordered in dollars: %d of %d", dollars, checked)
	}
}

func TestADollarOrderOutsideTheDollarLimitsIsOrderedLocally(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	// Orange Mali takes 3.90 to 64.95 dollars: 32,500 CFA francs is 64.68 dollars
	// with the buffer, 32,700 is 65.08.
	inside := airtimeOrder(t, service, in, 289, "70123456", "32500", "XOF")
	if inside.Airtime.Local || inside.Airtime.Currency != "USD" {
		t.Fatalf("32,500 fits the dollar limits: %+v", inside.Airtime)
	}
	outside := airtimeOrder(t, service, in, 289, "70123456", "32700", "XOF")
	if !outside.Airtime.Local || outside.Airtime.Currency != "XOF" || outside.Airtime.Amount.Cmp(rn("32700")) != 0 {
		t.Fatalf("32,700 does not: it is still sold, ordered locally: %+v", outside.Airtime)
	}
	if got := detailsOf(t, outside); got["order_mode"] != "local" {
		t.Fatalf("details: %v", got)
	}
	// The local minimum is 1,967 (3.895 dollars, below the dollar minimum of 3.90
	// before the buffer, above it after).
	atMinimum := airtimeOrder(t, service, in, 289, "70123456", "1967", "XOF")
	if atMinimum.Airtime.Local {
		t.Fatalf("the buffer lifts the minimum over the dollar limit: %+v", atMinimum.Airtime)
	}
}

func TestAFixedOperatorOrdersTheAlignedDollarPlan(t *testing.T) {
	service := fixtureService(t)
	dollars := pricing(t, "9.71")
	local := pricingJSON(t, `{"usd_rate": "9.71", "airtime": {"order_mode": "local"}}`)
	// Etisalat Egypt: the 5 pound plan is the 0.17 dollar plan.
	usd := airtimeOrder(t, service, dollars, 120, "010 1234 5678", "5", "EGP")
	exact := airtimeOrder(t, service, local, 120, "010 1234 5678", "5", "EGP")
	if usd.Airtime.Local || usd.Airtime.Currency != "USD" || usd.Airtime.Amount.Cmp(rn("0.17")) != 0 ||
		usd.Receive != (Money{Amount: "5", Currency: "EGP"}) {
		t.Fatalf("the dollar plan: %+v", usd.Airtime)
	}
	if !exact.Airtime.Local || exact.Airtime.Currency != "EGP" || exact.Airtime.Amount.Cmp(rn("5")) != 0 {
		t.Fatalf("the local plan: %+v", exact.Airtime)
	}
	// 0.17 dollars cost 0.1615 after the 5 % commission, 5 pounds cost 0.16668.
	if usd.Prices.CostLYD.Cmp(exact.Prices.CostLYD) >= 0 {
		t.Fatalf("the dollar plan is cheaper: %s vs %s", usd.Prices.CostLYD.FloatString(4), exact.Prices.CostLYD.FloatString(4))
	}
	if got := detailsOf(t, usd); got["order_amount"] != "0.17" || got["order_currency"] != "USD" {
		t.Fatalf("details: %v", got)
	}
	if _, has := detailsOf(t, usd)["buffer_percent"]; has {
		t.Fatal("a plan is not buffered")
	}
}

func TestAnOperatorWithoutLocalAmountsIsOrderedInDollarsAsAsked(t *testing.T) {
	service := fixtureService(t)
	for _, mode := range []string{"usd", "local"} {
		in := pricingJSON(t, `{"usd_rate": "9.71", "airtime": {"order_mode": "`+mode+`"}}`)
		// Ooredoo Tunisia takes dollar plans only.
		rendered, _ := service.Directory(context.Background(), in)
		operator := operatorOf(t, rendered.View, "TN", 508)
		if operator.AmountCurrency != "USD" || !operator.Approximate || operator.ReceiveCurrency != "TND" {
			t.Fatalf("%s: %+v", mode, operator)
		}
		order := airtimeOrder(t, service, in, 508, "20 123 456", operator.Amounts[0].Amount, "USD")
		if order.Airtime.Local || order.Airtime.Currency != "USD" || FormatAmount(order.Airtime.Amount) != operator.Amounts[0].Amount {
			t.Fatalf("%s: %+v", mode, order.Airtime)
		}
	}
}

func TestBillsInAutoModeUseDollarsOnlyWhereThePaymentNeedNotBeExact(t *testing.T) {
	service := fixtureService(t)
	auto := pricing(t, "9.71")
	local := pricingJSON(t, `{"usd_rate": "9.71", "bills": {"order_mode": "local"}}`)

	// Woyofal (Senegal): prepaid, a range, no invoice, 8 % off in dollars.
	woyofal := billOrder(t, service, auto, 26, "14500000001", "", "5000", "XOF")
	if woyofal.Bill.Local || woyofal.Bill.Currency != "USD" || woyofal.Bill.Receive != (Money{Amount: "5000", Currency: "XOF"}) {
		t.Fatalf("woyofal in auto mode: %+v", woyofal.Bill)
	}
	// 5,000 CFA francs at 583.684448242 and the buffer, rounded up.
	if got := FormatAmount(woyofal.Bill.Amount); got != "8.60911" {
		t.Fatalf("dollars: %s", got)
	}
	exact := billOrder(t, service, local, 26, "14500000001", "", "5000", "XOF")
	if !exact.Bill.Local || exact.Bill.Currency != "XOF" || exact.Bill.Amount.Cmp(rn("5000")) != 0 {
		t.Fatalf("woyofal in local mode: %+v", exact.Bill)
	}
	if woyofal.Prices.CostLYD.Cmp(exact.Prices.CostLYD) >= 0 {
		t.Fatalf("the dollar order is the cheaper one: %s vs %s", woyofal.Prices.CostLYD.FloatString(3), exact.Prices.CostLYD.FloatString(3))
	}
	if got := detailsOf(t, woyofal); got["order_mode"] != "usd" || got["order_currency"] != "USD" || got["order_amount"] != "8.60911" {
		t.Fatalf("details: %v", got)
	}

	// A small payment whose dollars fall under the biller's dollar minimum (2.00)
	// is still taken, in the local currency.
	small := billOrder(t, service, auto, 26, "14500000001", "", "1000", "XOF")
	if !small.Bill.Local {
		t.Fatalf("1,000 CFA francs is under the dollar minimum: %+v", small.Bill)
	}

	// An invoice is paid exactly, whatever the dollars would save.
	invoice := billOrder(t, service, auto, 23, "123456789", "2024-118833", "5000", "XOF")
	if !invoice.Bill.Local || invoice.Bill.Amount.Cmp(rn("5000")) != 0 {
		t.Fatalf("an invoice is paid in the local currency: %+v", invoice.Bill)
	}
	// A fixed plan is a package, ordered as listed.
	rendered, _ := service.Directory(context.Background(), auto)
	plan := billerOf(t, rendered.View, "ML", 27).Plans[0]
	canal := billOrder(t, service, auto, 27, "12345678", "", plan.Amount, "XOF")
	if !canal.Bill.Local || canal.Bill.AmountID != plan.ID || FormatAmount(canal.Bill.Amount) != plan.Amount {
		t.Fatalf("a fixed plan stays local: %+v", canal.Bill)
	}
	// Where dollars save nothing the exact order stays: Ikeja has no discount.
	ikeja := billOrder(t, service, auto, 5, "04223568280", "", "5000", "NGN")
	if !ikeja.Bill.Local || ikeja.Bill.Currency != "NGN" {
		t.Fatalf("no saving, no dollars: %+v", ikeja.Bill)
	}
	// Customers who pay in dollars are ordered in dollars, as asked.
	rendered, _ = service.Directory(context.Background(), auto)
	south := billerOf(t, rendered.View, "ZA", 30)
	if south.AmountCurrency != "USD" || !south.Approximate {
		t.Fatalf("south africa: %+v", south)
	}
	order := billOrder(t, service, auto, 30, "12345678901", "", "10", "USD")
	if order.Bill.Local || order.Bill.Currency != "USD" || order.Bill.Amount.Cmp(rn("10")) != 0 {
		t.Fatalf("a dollar biller: %+v", order.Bill)
	}
}

func TestEveryDirectoryPriceIsWhatTheOrderIsCharged(t *testing.T) {
	// Whatever the modes, the price a shop reads in the directory, the quote and the
	// order are one and the same.
	service := fixtureService(t)
	for _, document := range []string{
		`{"usd_rate": "9.71"}`,
		`{"usd_rate": "9.71", "airtime": {"order_mode": "local"}, "bills": {"order_mode": "local"}}`,
		`{"usd_rate": "9.71", "airtime": {"usd_buffer_percent": "3"}}`,
	} {
		in := pricingJSON(t, document)
		rendered, err := service.Directory(context.Background(), in)
		if err != nil {
			t.Fatal(err)
		}
		checked := 0
		for _, country := range rendered.View.Countries {
			if country.Airtime == nil {
				continue
			}
			for _, operator := range country.Airtime.Operators {
				for _, amount := range operator.Amounts {
					phone := "5" + "1234567890"
					prepared, refusal := service.PrepareOrder(context.Background(), in, OrderRequest{
						Kind: "airtime", OperatorID: operator.ID, Phone: "+" + dialOf(country) + phone[:8], Amount: amount.Amount, AmountCurrency: operator.AmountCurrency,
					})
					if refusal != nil {
						// Not every invented number fits every country's length.
						continue
					}
					if prepared.Prices.UnitString() != amount.UnitPrice {
						t.Fatalf("%s %s: order %s, directory %s", operator.NameEN, amount.Amount, prepared.Prices.UnitString(), amount.UnitPrice)
					}
					checked++
				}
			}
		}
		if checked < 50 {
			t.Fatalf("%s: only %d orders checked", document, checked)
		}
	}
}

func dialOf(country Country) string {
	if len(country.Dial) == 0 {
		return ""
	}
	return country.Dial[0]
}
