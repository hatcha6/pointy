package services

import (
	"context"
	"strings"
	"testing"

	"pointy/relay/internal/reloadly"
)

// The shop must not re-implement the relay's phone rules (it got Côte d'Ivoire
// and Benin wrong, where the trunk zero is part of the number): it hands the
// number over as typed and reads back how the relay understood it. The E.164
// form the relay answers must be one the relay itself reads back as the same
// number, in quote, order and detection alike.

type phoneCase struct {
	country  string
	dial     []string
	national string
	e164     string
	// typed are the forms a cashier writes the number in, by name.
	typed map[string]string
}

var phoneCases = []phoneCase{
	{"CI", []string{"225"}, "0707123456", "+2250707123456", map[string]string{
		// The zero is part of the number since the 2021 renumbering: national and
		// national-with-trunk-0 are one form.
		"national":          "0707123456",
		"national spaced":   "07 07 12 34 56",
		"national brackets": "(07) 07-12-34-56",
		"+":                 "+2250707123456",
		"+ spaced":          "+225 07 07 12 34 56",
		"00":                "002250707123456",
		"digits only":       "2250707123456",
	}},
	{"BJ", []string{"229"}, "0197123456", "+2290197123456", map[string]string{
		"national":        "0197123456",
		"national spaced": "01 97 12 34 56",
		"+":               "+2290197123456",
		"00":              "002290197123456",
		"digits only":     "2290197123456",
	}},
	{"NG", []string{"234"}, "8031234567", "+2348031234567", map[string]string{
		"national":         "8031234567",
		"national trunk 0": "08031234567",
		"spaced":           "0803 123 4567",
		"+":                "+2348031234567",
		"+ spaced":         "+234 803 123 4567",
		"00":               "002348031234567",
		"digits only":      "2348031234567",
		"arabic digits":    "٠٨٠٣١٢٣٤٥٦٧",
	}},
	{"ML", []string{"223"}, "70123456", "+22370123456", map[string]string{
		"national":         "70123456",
		"national spaced":  "70 12 34 56",
		"national trunk 0": "070123456",
		"+":                "+22370123456",
		"00":               "0022370123456",
		"digits only":      "22370123456",
	}},
	{"NE", []string{"227"}, "96123456", "+22796123456", map[string]string{
		"national":         "96123456",
		"national spaced":  "96 12 34 56",
		"national trunk 0": "096123456",
		"+":                "+22796123456",
		"00":               "0022796123456",
		"digits only":      "22796123456",
	}},
	{"EG", []string{"20"}, "1001234567", "+201001234567", map[string]string{
		"national":         "1001234567",
		"national trunk 0": "01001234567",
		"spaced":           "0100 123 4567",
		"+":                "+201001234567",
		"00":               "00201001234567",
		"digits only":      "201001234567",
	}},
	{"TR", []string{"90"}, "5321234567", "+905321234567", map[string]string{
		"national":         "5321234567",
		"national trunk 0": "05321234567",
		"spaced":           "0532 123 45 67",
		"+":                "+905321234567",
		"00":               "00905321234567",
		"digits only":      "905321234567",
	}},
	{"PK", []string{"92"}, "3001234567", "+923001234567", map[string]string{
		"national":         "3001234567",
		"national trunk 0": "03001234567",
		"dashed":           "0300-1234567",
		"+":                "+923001234567",
		"00":               "00923001234567",
		"digits only":      "923001234567",
	}},
}

func TestEveryFormOfANumberReadsAsTheSameNumberAndItsE164RoundTrips(t *testing.T) {
	for _, c := range phoneCases {
		want := Phone{Country: c.country, Dial: c.dial[0], National: c.national}
		for name, typed := range c.typed {
			t.Run(c.country+" "+name, func(t *testing.T) {
				got, err := ParsePhone(typed, c.country, c.dial)
				if err != nil || got != want {
					t.Fatalf("%q: got %+v, %v; want %+v", typed, got, err, want)
				}
				if got.E164() != c.e164 {
					t.Fatalf("e164 %q, want %q", got.E164(), c.e164)
				}
				// The E.164 the relay answers is one it reads back as the same
				// number, with the plus, as 00, and as bare digits.
				for _, again := range []string{got.E164(), "00" + got.Digits(), got.Digits()} {
					back, err := ParsePhone(again, c.country, c.dial)
					if err != nil || back != want {
						t.Fatalf("round trip of %q: %+v, %v", again, back, err)
					}
				}
				if detected := got.Detected(); detected != (DetectedPhone{E164: c.e164, National: c.national, Country: c.country}) {
					t.Fatalf("detected: %+v", detected)
				}
			})
		}
	}
}

// phoneFixture is one crafted operator per country of the table, all copies of
// Orange Mali, so the quote, order and detect routes can be run on them.
func phoneFixture(t *testing.T) (*Service, map[string]int64) {
	t.Helper()
	var base reloadly.Operator
	for _, operator := range mustFixture(t).Operators {
		if operator.Key() == 289 {
			base = operator
		}
	}
	raw := Raw{}
	ids := map[string]int64{}
	for i, c := range phoneCases {
		id := int64(9500 + i)
		ids[c.country] = id
		operator := base
		operator.ID, operator.OperatorID = id, id
		operator.Name = "Operator " + c.country
		operator.Country.ISOName, operator.Country.Name = c.country, c.country
		raw.Operators = append(raw.Operators, operator)
		calling := make([]string, 0, len(c.dial))
		for _, dial := range c.dial {
			calling = append(calling, "+"+dial)
		}
		raw.Countries = append(raw.Countries, reloadly.TopupCountry{ISOName: c.country, Name: c.country, CurrencyCode: "XOF", CallingCodes: calling})
	}
	return New(Config{Source: staticSource{raw}, TestMode: true, Namer: fakeNames{}}), ids
}

func TestAnAirtimeQuoteReadsTheNumberItIsGivenAndAnswersHowItWasRead(t *testing.T) {
	service, ids := phoneFixture(t)
	in := pricing(t, "9.71")
	ctx := context.Background()
	for _, c := range phoneCases {
		want := DetectedPhone{E164: c.e164, National: c.national, Country: c.country}
		for name, typed := range c.typed {
			t.Run(c.country+" "+name, func(t *testing.T) {
				request := QuoteRequest{Kind: "airtime", OperatorID: ids[c.country], Amount: "5000", AmountCurrency: "XOF", Country: c.country, Phone: typed}
				quoted, refusal := service.Quote(ctx, in, request)
				if refusal != nil || quoted.Phone == nil || *quoted.Phone != want {
					t.Fatalf("quote of %q: %v %+v", typed, refusal, quoted.Phone)
				}
				// Feeding the answer back: quote, order and detection agree.
				request.Phone = quoted.Phone.E164
				again, refusal := service.Quote(ctx, in, request)
				if refusal != nil || again.Phone == nil || *again.Phone != want || again.Quote != quoted.Quote {
					t.Fatalf("quote of the e164: %v %+v", refusal, again.Phone)
				}
				prepared, refusal := service.PrepareOrder(ctx, in, OrderRequest{Kind: "airtime", OperatorID: ids[c.country], Country: c.country,
					Phone: quoted.Phone.E164, Amount: "5000", AmountCurrency: "XOF"})
				if refusal != nil || prepared.Airtime.Phone.E164() != c.e164 || prepared.Airtime.Phone.National != c.national {
					t.Fatalf("order of the e164: %v %+v", refusal, prepared)
				}
				detection, refusal := service.Detect(ctx, in, c.country, quoted.Phone.E164)
				if refusal != nil || detection.Phone != want {
					t.Fatalf("detection of the e164: %v %+v", refusal, detection.Phone)
				}
			})
		}
	}
}

func TestAnAirtimeQuoteWithoutANumberIsAsItWasAndABadNumberIsRefused(t *testing.T) {
	service, ids := phoneFixture(t)
	in := pricing(t, "9.71")
	ctx := context.Background()
	plain := QuoteRequest{Kind: "airtime", OperatorID: ids["ML"], Amount: "5000", AmountCurrency: "XOF"}
	quoted, refusal := service.Quote(ctx, in, plain)
	if refusal != nil || quoted.Phone != nil {
		t.Fatalf("no number, no phone in the answer: %v %+v", refusal, quoted.Phone)
	}
	for _, blank := range []string{"", "   "} {
		withBlank := plain
		withBlank.Phone = blank
		again, refusal := service.Quote(ctx, in, withBlank)
		if refusal != nil || again.Phone != nil || again.Quote != quoted.Quote {
			t.Fatalf("a blank number is no number: %v %+v", refusal, again.Phone)
		}
	}
	// A country alone changes nothing.
	withCountry := plain
	withCountry.Country = "ML"
	if again, refusal := service.Quote(ctx, in, withCountry); refusal != nil || again.Phone != nil {
		t.Fatalf("a country without a number: %v", refusal)
	}
	// The number defaults to the operator's country.
	noCountry := plain
	noCountry.Phone = "70123456"
	if again, refusal := service.Quote(ctx, in, noCountry); refusal != nil || again.Phone == nil || again.Phone.E164 != "+22370123456" {
		t.Fatalf("the operator's country is the number's: %v %+v", refusal, again.Phone)
	}
	for _, c := range []struct{ name, country, phone string }{
		{"letters", "ML", "70-12-ab-56"},
		{"too short", "ML", "123"},
		{"too long", "ML", "7012345678901234567"},
		{"another country's code", "ML", "+2348031234567"},
		{"the operator is not in that country", "NE", "96123456"},
	} {
		bad := plain
		bad.Country, bad.Phone = c.country, c.phone
		if _, refusal := service.Quote(ctx, in, bad); refusal == nil || refusal.Status != 422 || refusal.Code != "invalid_phone" {
			t.Fatalf("%s: %v", c.name, refusal)
		}
	}
	// A bill takes no number: whatever rides along is ignored.
	bill := QuoteRequest{Kind: "bill", BillerID: 5, Amount: "5000", AmountCurrency: "NGN", Country: "NG", Phone: "nonsense"}
	fixture := fixtureService(t)
	if quoted, refusal := fixture.Quote(ctx, in, bill); refusal != nil || quoted.Phone != nil {
		t.Fatalf("a bill quote has no phone: %v %+v", refusal, quoted.Phone)
	}
	// No refusal text repeats the number.
	_, refusal = service.Quote(ctx, in, QuoteRequest{Kind: "airtime", OperatorID: ids["ML"], Amount: "5000", AmountCurrency: "XOF", Phone: "70123456789012345678"})
	if refusal == nil || strings.Contains(refusal.Message, "7012345678") {
		t.Fatalf("the refusal does not echo the number: %+v", refusal)
	}
}
