package services

import (
	"context"
	"testing"

	"pointy/relay/internal/reloadly"
)

// An amount cannot have more decimals than its currency has minor units: a
// fractional CFA franc is not an amount anybody can be credited, and Reloadly
// would round it where it pleases.

var (
	wantZeroDecimal = []string{"XOF", "XAF", "XPF", "JPY", "KRW", "VND", "UGX", "RWF", "GNF", "PYG", "CLP", "ISK", "KMF", "DJF", "BIF", "VUV"}
	wantTwoDecimal  = []string{"USD", "EUR", "NGN", "EGP", "PKR", "LYD", "KWD", "TND", "GHS"}
)

func TestCurrencyDecimals(t *testing.T) {
	for _, code := range wantZeroDecimal {
		if got := CurrencyDecimals(code); got != 0 {
			t.Errorf("%s has %d decimals, want 0", code, got)
		}
		if got := CurrencyDecimals(" " + lower(code) + " "); got != 0 {
			t.Errorf("%s in lower case with spaces has %d decimals", code, got)
		}
	}
	for _, code := range wantTwoDecimal {
		if got := CurrencyDecimals(code); got != 2 {
			t.Errorf("%s has %d decimals, want 2", code, got)
		}
	}
	if CurrencyDecimals("") != 2 || CurrencyDecimals("???") != 2 {
		t.Error("anything else is two")
	}
}

func lower(s string) string {
	out := []byte(s)
	for i, b := range out {
		if b >= 'A' && b <= 'Z' {
			out[i] = b + 32
		}
	}
	return string(out)
}

// currencyService sells, in each currency, an operator and a biller made out of
// Orange Mali and Woyofal.
func currencyService(t *testing.T, currencies []string) (service *Service, operators, billers map[string]int64) {
	t.Helper()
	fixture := mustFixture(t)
	var baseOperator reloadly.Operator
	for _, operator := range fixture.Operators {
		if operator.Key() == 289 {
			baseOperator = operator
		}
	}
	var baseBiller reloadly.Biller
	for _, biller := range fixture.Billers {
		if biller.ID == 26 {
			baseBiller = biller
		}
	}
	raw := Raw{Countries: fixture.Countries}
	operators, billers = map[string]int64{}, map[string]int64{}
	for i, code := range currencies {
		operator := baseOperator
		operator.ID, operator.OperatorID = int64(9600+i), int64(9600+i)
		operator.Name = "Operator " + code
		operator.DestinationCurrencyCode, operator.FX.CurrencyCode = code, code
		raw.Operators = append(raw.Operators, operator)
		operators[code] = operator.ID

		biller := baseBiller
		biller.ID = int64(9700 + i)
		biller.Name = "Biller " + code
		biller.LocalTransactionCurrencyCode = code
		raw.Billers = append(raw.Billers, biller)
		billers[code] = biller.ID
	}
	return New(Config{Source: staticSource{raw}, TestMode: true, Namer: fakeNames{}}), operators, billers
}

func TestAnAmountIsRefusedWithMoreDecimalsThanItsCurrencyHas(t *testing.T) {
	// Dollars are sold as dollar tiles (a few to some sixty-five dollars), a
	// different amount range from the local currencies this table crafts.
	all := append([]string{}, wantZeroDecimal...)
	for _, code := range wantTwoDecimal {
		if code != "USD" {
			all = append(all, code)
		}
	}
	service, operators, billers := currencyService(t, all)
	in := pricing(t, "9.71")
	ctx := context.Background()
	for _, code := range all {
		decimals := CurrencyDecimals(code)
		for _, c := range []struct {
			amount string
			okFor  int // the most decimals the amount may have for it to be sold
		}{
			{"5000", 0}, {"5000.00", 0}, {"5000.0", 0},
			{"5000.5", 1}, {"5000.50", 1}, {"5000.55", 2}, {"5000.555", 3}, {"5000.00001", 5},
		} {
			// The decimals an amount really has: 5000.50 has one, 5000.00 none.
			wantOK := c.okFor <= decimals
			t.Run(code+" "+c.amount, func(t *testing.T) {
				requests := map[string]func() *Refusal{
					"airtime quote": func() *Refusal {
						_, refusal := service.Quote(ctx, in, QuoteRequest{Kind: "airtime", OperatorID: operators[code], Amount: c.amount, AmountCurrency: code})
						return refusal
					},
					"airtime order": func() *Refusal {
						_, refusal := service.PrepareOrder(ctx, in, OrderRequest{Kind: "airtime", OperatorID: operators[code], Phone: "70123456", Amount: c.amount, AmountCurrency: code})
						return refusal
					},
					"bill quote": func() *Refusal {
						_, refusal := service.Quote(ctx, in, QuoteRequest{Kind: "bill", BillerID: billers[code], Amount: c.amount, AmountCurrency: code})
						return refusal
					},
					"bill order": func() *Refusal {
						_, refusal := service.PrepareOrder(ctx, in, OrderRequest{Kind: "bill", BillerID: billers[code], Account: "14500000001", Amount: c.amount, AmountCurrency: code})
						return refusal
					},
				}
				for name, request := range requests {
					refusal := request()
					switch {
					case wantOK && refusal != nil:
						t.Errorf("%s: refused: %v", name, refusal)
					case !wantOK && (refusal == nil || refusal.Status != 422 || refusal.Code != "invalid_amount"):
						t.Errorf("%s: want 422 invalid_amount, got %v", name, refusal)
					}
				}
			})
		}
	}
}

func TestTheFixtureRefusesAFractionalCFAFrancAtTheDoor(t *testing.T) {
	service := fixtureService(t)
	in := pricing(t, "9.71")
	for _, request := range []QuoteRequest{
		{Kind: "airtime", OperatorID: 289, Amount: "5000.5", AmountCurrency: "XOF"},
		{Kind: "bill", BillerID: 26, Amount: "5000.25", AmountCurrency: "XOF"},
	} {
		_, refusal := service.Quote(context.Background(), in, request)
		requireRefusal(t, refusal, 422, "invalid_amount", "")
	}
	// The dollar amount the relay computes to place an order is five decimals and
	// is not an amount anybody types: it is untouched.
	quoted, refusal := service.Quote(context.Background(), in, QuoteRequest{Kind: "airtime", OperatorID: 289, Amount: "5000", AmountCurrency: "XOF"})
	if refusal != nil || FormatAmount(quoted.Order.Amount) != "9.9505" || quoted.Order.Currency != "USD" {
		t.Fatalf("%v %+v", refusal, quoted.Order)
	}
}

func TestTheDirectoryOffersNoAmountItsOwnRulesRefuse(t *testing.T) {
	// Reloadly's own popular amounts are not always whole: an operator of a whole
	// currency with a popular amount of 2500.5.
	source := &flakySource{}
	source.set(nil, func(raw *Raw) {
		for i := range raw.Operators {
			if raw.Operators[i].Key() == 289 {
				fractional := raw.Operators[i]
				fractional.ID, fractional.OperatorID = 9801, 9801
				fractional.Name = "Fractional Mali"
				fractional.MostPopularLocalAmount = "2500.5"
				raw.Operators = append(raw.Operators, fractional)
				break
			}
		}
	})
	service := New(Config{Source: source, TestMode: true, Namer: fakeNames{}})
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
					checked++
					value, _ := ParseAmount(amount.Amount)
					if operator.Mode == "range" && !amountFitsCurrency(value, operator.AmountCurrency) {
						t.Errorf("%s offers %s %s", operator.NameEN, amount.Amount, operator.AmountCurrency)
					}
					if _, refusal := service.Quote(context.Background(), in, QuoteRequest{Kind: "airtime", OperatorID: operator.ID, Amount: amount.Amount, AmountCurrency: operator.AmountCurrency}); refusal != nil {
						t.Errorf("%s: its own tile %s is refused: %v", operator.NameEN, amount.Amount, refusal)
					}
				}
				if operator.PopularAmount != nil && operator.Mode == "range" {
					value, _ := ParseAmount(*operator.PopularAmount)
					if !amountFitsCurrency(value, operator.AmountCurrency) {
						t.Errorf("%s: the popular amount %s", operator.NameEN, *operator.PopularAmount)
					}
				}
			}
		}
		if country.Bills != nil {
			for _, biller := range country.Bills.Billers {
				for _, amount := range biller.Suggested {
					checked++
					value, _ := ParseAmount(amount.Amount)
					if !amountFitsCurrency(value, biller.AmountCurrency) {
						t.Errorf("%s offers %s %s", biller.NameEN, amount.Amount, biller.AmountCurrency)
					}
				}
			}
		}
	}
	if checked < 100 {
		t.Fatalf("only %d amounts checked", checked)
	}
	if operator := operatorOf(t, rendered.View, "ML", 9801); operator.PopularAmount != nil {
		t.Fatalf("a popular amount nobody can order is not offered: %s", *operator.PopularAmount)
	}
}
