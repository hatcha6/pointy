package services

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"testing"

	"pointy/relay/internal/reloadly"
)

func quote(t *testing.T, service *Service, in PricingInput, request QuoteRequest) (Quoted, *Refusal) {
	t.Helper()
	return service.Quote(context.Background(), in, request)
}

func TestQuotingAnAirtimeAmount(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	got, refusal := quote(t, service, in, QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "5000", AmountCurrency: "XOF"})
	if refusal != nil {
		t.Fatal(refusal)
	}
	if got.Quote.Kind != "airtime" || got.Quote.Name != "شحن مباشر · أورنج مالي · 5,000 فرنك أفريقي" ||
		got.Quote.Receive != (Money{Amount: "5000", Currency: "XOF"}) || got.Quote.Approximate {
		t.Fatalf("quote: %+v", got.Quote)
	}
	// 5,000 CFA francs at Reloadly's rate, in dinars with the demo markups.
	if got.Quote.UnitPrice == "" || got.Quote.RetailPrice == "" || got.Prices.Unit.Cmp(got.Prices.CostLYD) <= 0 ||
		got.Prices.Retail.Cmp(got.Prices.Unit) <= 0 {
		t.Fatalf("prices: %+v", got)
	}
	// An amount that is not on a tile is as good as one that is.
	odd, refusal := quote(t, service, in, QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "3500.00", AmountCurrency: "xof"})
	if refusal != nil || odd.Quote.Name != "شحن مباشر · أورنج مالي · 3,500 فرنك أفريقي" {
		t.Fatalf("a range operator takes any amount inside its limits: %v %+v", refusal, odd)
	}
	// The same quote, twice, is the same price.
	again, _ := quote(t, service, in, QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "5000", AmountCurrency: "XOF"})
	if again.Quote != got.Quote {
		t.Fatal("a quote is deterministic")
	}
}

func TestQuoteRefusals(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	cases := []struct {
		name     string
		request  QuoteRequest
		in       PricingInput
		status   int
		code     string
		extraKey string
		extra    string
	}{
		{"below the minimum", QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "100", AmountCurrency: "XOF"}, in, 422, "amount_out_of_range", "min", "1967"},
		{"above the maximum", QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "40000", AmountCurrency: "XOF"}, in, 422, "amount_out_of_range", "max", "32800"},
		{"not a number", QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "five", AmountCurrency: "XOF"}, in, 422, "invalid_amount", "", ""},
		{"zero", QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "0", AmountCurrency: "XOF"}, in, 422, "invalid_amount", "", ""},
		{"a negative", QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "-5000", AmountCurrency: "XOF"}, in, 422, "invalid_amount", "", ""},
		{"another currency", QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "5000", AmountCurrency: "USD"}, in, 422, "invalid_amount", "", ""},
		{"unknown operator", QuoteRequest{Kind: "airtime", OperatorID: 99999, Amount: "5000", AmountCurrency: "XOF"}, in, 404, "unknown_operator", "", ""},
		{"unknown biller", QuoteRequest{Kind: "bill", BillerID: 99999, Amount: "5000", AmountCurrency: "NGN"}, in, 404, "unknown_biller", "", ""},
		{"no rate", QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "5000", AmountCurrency: "XOF"}, pricing(t, ""), 409, "service_unavailable", "reason", "rate_unset"},
		{"no kind", QuoteRequest{OperatorID: 289, Amount: "5000"}, in, 400, "invalid_request", "", ""},
		{"a bill below its minimum", QuoteRequest{Kind: "bill", BillerID: 5, Amount: "10", AmountCurrency: "NGN"}, in, 422, "amount_out_of_range", "min", "1000"},
		{"a plan that does not exist", QuoteRequest{Kind: "bill", BillerID: 27, Amount: "123", AmountCurrency: "XOF"}, in, 422, "amount_not_offered", "", ""},
		{"a blank invoice", QuoteRequest{Kind: "bill", BillerID: 23, Amount: "5000", AmountCurrency: "XOF", InvoiceID: ptr("")}, in, 422, "invoice_required", "", ""},
		{"a bad invoice", QuoteRequest{Kind: "bill", BillerID: 23, Amount: "5000", AmountCurrency: "XOF", InvoiceID: ptr("a b!")}, in, 422, "invalid_invoice", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, refusal := quote(t, service, c.in, c.request)
			if refusal == nil || refusal.Status != c.status || refusal.Code != c.code {
				t.Fatalf("got %+v, want %d %s", refusal, c.status, c.code)
			}
			if c.extraKey != "" && refusal.Extra[c.extraKey] != c.extra {
				t.Fatalf("%s: got %v want %s", c.extraKey, refusal.Extra, c.extra)
			}
		})
	}
}

func ptr(s string) *string { return &s }

func TestQuotingABillAndAFixedPlan(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	// Ikeja prepaid electricity (a range biller).
	electricity, refusal := quote(t, service, in, QuoteRequest{Kind: "bill", BillerID: 5, Amount: "5000", AmountCurrency: "NGN"})
	if refusal != nil {
		t.Fatal(refusal)
	}
	if electricity.Quote.Name != "دفع فاتورة كهرباء · كهرباء إيكيجا (مسبقة الدفع) · 5,000 نيرة نيجيرية" ||
		electricity.Quote.Receive != (Money{Amount: "5000", Currency: "NGN"}) {
		t.Fatalf("electricity: %+v", electricity.Quote)
	}
	// Canal+ Mali (a fixed biller): the plan is named by its amount, or by its id.
	rendered, _ := service.Directory(context.Background(), in)
	canal := billerOf(t, rendered.View, "ML", 27)
	if canal.Mode != "fixed" || len(canal.Plans) == 0 || canal.Plans[0].UnitPrice == "" || canal.Min != "" {
		t.Fatalf("canal: %+v", canal)
	}
	plan := canal.Plans[0]
	byAmount, refusal := quote(t, service, in, QuoteRequest{Kind: "bill", BillerID: 27, Amount: plan.Amount, AmountCurrency: "XOF"})
	if refusal != nil {
		t.Fatal(refusal)
	}
	byID, refusal := quote(t, service, in, QuoteRequest{Kind: "bill", BillerID: 27, Amount: plan.Amount, AmountCurrency: "XOF", AmountID: plan.ID})
	if refusal != nil || byID.Quote != byAmount.Quote {
		t.Fatalf("the plan by amount or by id is the same quote: %v %+v %+v", refusal, byID.Quote, byAmount.Quote)
	}
	if byID.Quote.UnitPrice != plan.UnitPrice || byID.Quote.RetailPrice != plan.RetailPrice {
		t.Fatalf("the quote is the directory's price: %+v vs %+v", byID.Quote, plan)
	}
	if !strings.HasPrefix(byID.Quote.Name, "دفع فاتورة تلفزيون · كانال بلس مالي") {
		t.Fatalf("name: %s", byID.Quote.Name)
	}
	if _, refusal := quote(t, service, in, QuoteRequest{Kind: "bill", BillerID: 27, Amount: plan.Amount, AmountCurrency: "XOF", AmountID: plan.ID + 9999}); refusal == nil || refusal.Code != "amount_not_offered" {
		t.Fatalf("another plan's id with this amount: %v", refusal)
	}
}

func TestEveryAmountOfTheDirectoryCanBeQuotedAtItsListedPrice(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	rendered, err := service.Directory(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, country := range rendered.View.Countries {
		if country.Airtime != nil {
			for _, operator := range country.Airtime.Operators {
				for _, amount := range operator.Amounts {
					got, refusal := quote(t, service, in, QuoteRequest{Kind: "airtime", OperatorID: operator.ID, Amount: amount.Amount, AmountCurrency: operator.AmountCurrency})
					if refusal != nil {
						t.Fatalf("%s %s: %v", operator.NameEN, amount.Amount, refusal)
					}
					if got.Quote.UnitPrice != amount.UnitPrice || got.Quote.RetailPrice != amount.RetailPrice ||
						got.Quote.Receive.Amount != amount.Receive || got.Quote.Receive.Currency != amount.ReceiveCurrency {
						t.Fatalf("%s %s: quote %+v differs from the listing %+v", operator.NameEN, amount.Amount, got.Quote, amount)
					}
					checked++
				}
			}
		}
		if country.Bills != nil {
			for _, biller := range country.Bills.Billers {
				var amounts []Suggestion
				for _, plan := range biller.Plans {
					amounts = append(amounts, Suggestion{Amount: plan.Amount, UnitPrice: plan.UnitPrice, RetailPrice: plan.RetailPrice})
				}
				amounts = append(amounts, biller.Suggested...)
				for _, amount := range amounts {
					got, refusal := quote(t, service, in, QuoteRequest{Kind: "bill", BillerID: biller.ID, Amount: amount.Amount, AmountCurrency: biller.AmountCurrency})
					if refusal != nil {
						t.Fatalf("%s %s: %v", biller.NameEN, amount.Amount, refusal)
					}
					if got.Quote.UnitPrice != amount.UnitPrice || got.Quote.RetailPrice != amount.RetailPrice {
						t.Fatalf("%s %s: quote %+v differs from the listing %+v", biller.NameEN, amount.Amount, got.Quote, amount)
					}
					checked++
				}
			}
		}
	}
	if checked < 300 {
		t.Fatalf("the fixture should hold hundreds of amounts, checked %d", checked)
	}
}

func TestPreparingAnAirtimeOrder(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	prepared, refusal := service.PrepareOrder(context.Background(), in, OrderRequest{
		Kind: "airtime", OperatorID: 289, Country: "ML", Phone: "+223 70 12 34 56", Amount: "5000", AmountCurrency: "XOF",
	})
	if refusal != nil {
		t.Fatal(refusal)
	}
	if prepared.ItemKey != "airtime:289:5000:XOF" || prepared.BrandKey != "airtime" || prepared.Target != "+223•••••456" ||
		prepared.SupplierRef != "289" || prepared.Name != "شحن مباشر · أورنج مالي · 5,000 فرنك أفريقي" {
		t.Fatalf("prepared: %+v", prepared)
	}
	// The customer pays for 5,000 CFA francs; the company orders them in dollars,
	// rounded up with the buffer, to keep Reloadly's commission.
	order := prepared.Airtime
	if order == nil || prepared.Bill != nil || order.OperatorID != 289 || order.Phone.E164() != "+22370123456" || order.Local ||
		order.Amount.Cmp(rn("9.9505")) != 0 || order.OperatorName != "Orange Mali" || order.Currency != "USD" ||
		order.Receive != (Money{Amount: "5000", Currency: "XOF"}) {
		t.Fatalf("order: %+v", order)
	}
	var details map[string]any
	if err := json.Unmarshal(prepared.Details, &details); err != nil {
		t.Fatal(err)
	}
	if details["operator_id"] != float64(289) || details["country"] != "ML" || details["amount"] != "5000" || details["local"] != true ||
		details["order_mode"] != "usd" || details["order_amount"] != "9.9505" || details["order_currency"] != "USD" ||
		details["buffer_percent"] != "0.5" {
		t.Fatalf("details: %v", details)
	}
	if strings.Contains(string(prepared.Details), "70123456") || strings.Contains(string(prepared.Details), "+223") {
		t.Fatalf("the details must never hold the number: %s", prepared.Details)
	}
}

func TestPreparingABillOrder(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	prepared, refusal := service.PrepareOrder(context.Background(), in, OrderRequest{
		Kind: "bill", BillerID: 5, Country: "NG", Account: "0422 356 8280", Amount: "5000", AmountCurrency: "NGN",
	})
	if refusal != nil {
		t.Fatal(refusal)
	}
	if prepared.ItemKey != "bill:5:5000:NGN" || prepared.BrandKey != "bill" || prepared.Target != "••••••••280" ||
		prepared.Bill == nil || prepared.Bill.Account != "04223568280" || !prepared.Bill.Local || prepared.Bill.AmountID != 0 {
		t.Fatalf("prepared: %+v", prepared)
	}
	if strings.Contains(string(prepared.Details), "04223568280") {
		t.Fatalf("the details must never hold the account: %s", prepared.Details)
	}

	// A biller that needs the invoice number.
	missing, refusal := service.PrepareOrder(context.Background(), in, OrderRequest{
		Kind: "bill", BillerID: 23, Country: "SN", Account: "123456789", Amount: "5000", AmountCurrency: "XOF",
	})
	if refusal == nil || refusal.Code != "invoice_required" || missing != nil {
		t.Fatalf("an invoice is required: %v", refusal)
	}
	withInvoice, refusal := service.PrepareOrder(context.Background(), in, OrderRequest{
		Kind: "bill", BillerID: 23, Country: "SN", Account: "123456789", InvoiceID: "2024-118833", Amount: "5000", AmountCurrency: "XOF",
	})
	if refusal != nil || withInvoice.Bill.InvoiceID != "2024-118833" || !strings.Contains(string(withInvoice.Details), `"has_invoice":true`) ||
		strings.Contains(string(withInvoice.Details), "118833") {
		t.Fatalf("invoice: %v %+v", refusal, withInvoice)
	}

	// A fixed plan keeps its id in the item key.
	rendered, _ := service.Directory(context.Background(), in)
	plan := billerOf(t, rendered.View, "ML", 27).Plans[0]
	fixed, refusal := service.PrepareOrder(context.Background(), in, OrderRequest{
		Kind: "bill", BillerID: 27, Country: "ML", Account: "12345678", Amount: plan.Amount, AmountCurrency: "XOF", AmountID: plan.ID,
	})
	if refusal != nil || fixed.Bill.AmountID != plan.ID || !strings.HasSuffix(fixed.ItemKey, ":"+itoa(plan.ID)) {
		t.Fatalf("fixed: %v %+v", refusal, fixed)
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func TestOrderRefusals(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	cases := []struct {
		name    string
		request OrderRequest
		in      PricingInput
		status  int
		code    string
	}{
		{"no rate", OrderRequest{Kind: "airtime", OperatorID: 289, Phone: "70123456", Amount: "5000", AmountCurrency: "XOF"}, pricing(t, ""), 503, "services_unpriced"},
		{"unknown operator", OrderRequest{Kind: "airtime", OperatorID: 1, Phone: "70123456", Amount: "5000", AmountCurrency: "XOF"}, in, 404, "unknown_operator"},
		{"unknown biller", OrderRequest{Kind: "bill", BillerID: 1000, Account: "123456", Amount: "5000", AmountCurrency: "NGN"}, in, 404, "unknown_biller"},
		{"bad phone", OrderRequest{Kind: "airtime", OperatorID: 289, Phone: "12", Amount: "5000", AmountCurrency: "XOF"}, in, 422, "invalid_phone"},
		{"another country's phone", OrderRequest{Kind: "airtime", OperatorID: 289, Phone: "+234 803 123 4567", Amount: "5000", AmountCurrency: "XOF"}, in, 422, "invalid_phone"},
		{"another country", OrderRequest{Kind: "airtime", OperatorID: 289, Country: "NG", Phone: "70123456", Amount: "5000", AmountCurrency: "XOF"}, in, 422, "invalid_phone"},
		{"bad amount", OrderRequest{Kind: "airtime", OperatorID: 289, Phone: "70123456", Amount: "-1", AmountCurrency: "XOF"}, in, 422, "invalid_amount"},
		{"out of range", OrderRequest{Kind: "airtime", OperatorID: 289, Phone: "70123456", Amount: "50", AmountCurrency: "XOF"}, in, 422, "amount_out_of_range"},
		{"bad account", OrderRequest{Kind: "bill", BillerID: 5, Account: "12", Amount: "5000", AmountCurrency: "NGN"}, in, 422, "invalid_account"},
		{"account with symbols", OrderRequest{Kind: "bill", BillerID: 5, Account: "123<script>", Amount: "5000", AmountCurrency: "NGN"}, in, 422, "invalid_account"},
		{"bad invoice", OrderRequest{Kind: "bill", BillerID: 23, Account: "123456789", InvoiceID: "no way!", Amount: "5000", AmountCurrency: "XOF"}, in, 422, "invalid_invoice"},
		{"no kind", OrderRequest{OperatorID: 289}, in, 400, "invalid_request"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			prepared, refusal := service.PrepareOrder(context.Background(), c.in, c.request)
			if prepared != nil || refusal == nil || refusal.Status != c.status || refusal.Code != c.code {
				t.Fatalf("got %+v %+v, want %d %s", prepared, refusal, c.status, c.code)
			}
		})
	}
}

func TestItemKeysAndMaskedTargetsOfARequest(t *testing.T) {
	key, refusal := ItemKeyOf(OrderRequest{Kind: "airtime", OperatorID: 289, Amount: "5000.00", AmountCurrency: "xof"})
	if refusal != nil || key != "airtime:289:5000:XOF" {
		t.Fatalf("%q %v", key, refusal)
	}
	key, refusal = ItemKeyOf(OrderRequest{Kind: "bill", BillerID: 27, Amount: "10000", AmountCurrency: "XOF", AmountID: 3})
	if refusal != nil || key != "bill:27:10000:XOF:3" {
		t.Fatalf("%q %v", key, refusal)
	}
	for _, request := range []OrderRequest{
		{Kind: "airtime", OperatorID: 289, Amount: "x", AmountCurrency: "XOF"},
		{Kind: "airtime", OperatorID: 289, Amount: "5"},
		{Kind: "airtime", Amount: "5", AmountCurrency: "XOF"},
		{Kind: "bill", Amount: "5", AmountCurrency: "XOF"},
		{Kind: "gift", Amount: "5", AmountCurrency: "XOF"},
	} {
		if _, refusal := ItemKeyOf(request); refusal == nil {
			t.Errorf("%+v must be refused", request)
		}
	}

	service := fixtureService(t)
	if _, ok := service.MaskedTarget(OrderRequest{Kind: "airtime", OperatorID: 289, Phone: "70123456"}); ok {
		t.Fatal("before the directory is read nothing can be told")
	}
	if _, err := service.Directory(context.Background(), pricing(t, "9.71")); err != nil {
		t.Fatal(err)
	}
	if masked, ok := service.MaskedTarget(OrderRequest{Kind: "airtime", OperatorID: 289, Phone: "+223 70 12 34 56"}); !ok || masked != "+223•••••456" {
		t.Fatalf("masked %q %v", masked, ok)
	}
	if masked, ok := service.MaskedTarget(OrderRequest{Kind: "bill", Account: "0422 356 8280"}); !ok || masked != "••••••••280" {
		t.Fatalf("masked %q %v", masked, ok)
	}
	if _, ok := service.MaskedTarget(OrderRequest{Kind: "airtime", OperatorID: 1, Phone: "70123456"}); ok {
		t.Fatal("an operator no longer listed cannot be told")
	}
}

func TestDetectingAnOperatorOffline(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	got, refusal := service.Detect(context.Background(), in, "ML", "70123456")
	if refusal != nil {
		t.Fatal(refusal)
	}
	if got.Phone.E164 != "+22370123456" || got.Phone.National != "70123456" || got.Phone.Country != "ML" || got.Operator.ID == 0 ||
		len(got.Operator.Amounts) == 0 || got.Operator.Amounts[0].UnitPrice == "" {
		t.Fatalf("detection: %+v", got)
	}
	again, _ := service.Detect(context.Background(), in, "ml", "+223 70 12 34 56")
	if again.Operator.ID != got.Operator.ID {
		t.Fatal("the same number is the same operator")
	}
	if _, refusal := service.Detect(context.Background(), in, "ML", "12"); refusal == nil || refusal.Code != "invalid_phone" || refusal.Status != 422 {
		t.Fatalf("a bad number: %v", refusal)
	}
	if _, refusal := service.Detect(context.Background(), in, "SD", "912345678"); refusal == nil || refusal.Code != "operator_not_detected" || refusal.Status != 404 {
		t.Fatalf("a country with no operator: %v", refusal)
	}
	if _, refusal := service.Detect(context.Background(), in, "Mali", "70123456"); refusal == nil || refusal.Status != 400 {
		t.Fatalf("a bad country: %v", refusal)
	}
}

// staticSource serves crafted data.
type staticSource struct{ raw Raw }

func (s staticSource) Load(context.Context) (Raw, error) { return s.raw, nil }

func TestADollarOnlyRangeOperatorIsApproximateAndOrderedAsAsked(t *testing.T) {
	var operator reloadly.Operator
	if err := json.Unmarshal([]byte(`{"id":9100,"operatorId":9100,"name":"Dollar Telecom","bundle":false,"data":false,"pin":false,"comboProduct":false,
		"supportsLocalAmounts":false,"denominationType":"RANGE","senderCurrencyCode":"USD","destinationCurrencyCode":"XOF",
		"internationalDiscount":4.0,"commission":4.0,"localDiscount":0,"minAmount":1.0,"maxAmount":100.0,"mostPopularAmount":5,
		"country":{"isoName":"ML","name":"Mali"},"fx":{"rate":505.0,"currencyCode":"XOF"},
		"suggestedAmountsMap":{"5":2527.0,"10":5054.0},"fees":{},"status":"ACTIVE","logoUrls":[],"fixedAmounts":[],"localFixedAmounts":[]}`), &operator); err != nil {
		t.Fatal(err)
	}
	var country reloadly.TopupCountry
	if err := json.Unmarshal([]byte(`{"isoName":"ML","name":"Mali","currencyCode":"XOF","currencyName":"CFA Franc BCEAO","callingCodes":["+223"]}`), &country); err != nil {
		t.Fatal(err)
	}
	service := New(Config{Source: staticSource{Raw{Countries: []reloadly.TopupCountry{country}, Operators: []reloadly.Operator{operator}}}, TestMode: true, Namer: fakeNames{}})
	in := pricing(t, "9.71")
	rendered, err := service.Directory(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	view := operatorOf(t, rendered.View, "ML", 9100)
	if view.AmountCurrency != "USD" || view.ReceiveCurrency != "XOF" || !view.Approximate || view.Min != "1" || view.Max != "100" ||
		view.PopularAmount == nil || *view.PopularAmount != "5" {
		t.Fatalf("operator: %+v", view)
	}
	byAmount := map[string]Amount{}
	for _, amount := range view.Amounts {
		byAmount[amount.Amount] = amount
	}
	// Reloadly's own conversion where it lists one, the rate where it does not.
	if byAmount["5"].Receive != "2527" || byAmount["10"].Receive != "5054" || byAmount["2"].Receive != "1010" {
		t.Fatalf("receive: %+v", view.Amounts)
	}
	quoted, refusal := quote(t, service, in, QuoteRequest{Kind: "airtime", OperatorID: 9100, Amount: "7.5", AmountCurrency: "USD"})
	if refusal != nil || quoted.Quote.Receive != (Money{Amount: "3787.5", Currency: "XOF"}) || !quoted.Quote.Approximate {
		t.Fatalf("quote: %v %+v", refusal, quoted.Quote)
	}
	if quoted.Order.Currency != "USD" || quoted.Order.Local {
		t.Fatalf("a dollar tile is ordered in dollars as asked: %+v", quoted.Order)
	}
	prepared, refusal := service.PrepareOrder(context.Background(), in, OrderRequest{Kind: "airtime", OperatorID: 9100, Phone: "70123456", Amount: "7.5", AmountCurrency: "USD"})
	if refusal != nil || prepared.Airtime.Local || prepared.Airtime.Currency != "USD" || prepared.Airtime.Amount.Cmp(rn("7.5")) != 0 ||
		prepared.Receive != (Money{Amount: "3787.5", Currency: "XOF"}) || !prepared.Approximate {
		t.Fatalf("order: %v %+v", refusal, prepared)
	}
	// 7.5 dollars at 4 % off.
	if want := rn("7.2"); quoted.Order.Cost.Cmp(want) != 0 {
		t.Fatalf("cost %s want 7.2", quoted.Order.Cost.FloatString(5))
	}
}
