package reloadly

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

func validTopup() TopupRequest {
	return TopupRequest{
		OperatorID: 640, Amount: "100", UseLocalAmount: true, CustomIdentifier: "ptest-2",
		RecipientPhone: Phone{CountryCode: "NE", Number: "96123456"},
	}
}

func operatorByID(t *testing.T, id int64) Operator {
	t.Helper()
	for _, op := range fixtureRows[Operator](t, "operators.json") {
		if op.Key() == id {
			return op
		}
	}
	t.Fatalf("operator %d is not in the fixture", id)
	return Operator{}
}

func TestOperatorsDecodeEveryKind(t *testing.T) {
	f := newFake(t)
	f.always("topups", ok(fixture(t, "operators.json")))
	operators, err := f.client().Operators(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(operators) != 16 {
		t.Fatalf("operators = %d", len(operators))
	}
	byID := map[int64]Operator{}
	for _, op := range operators {
		byID[op.Key()] = op
	}

	mali := byID[289]
	if mali.Name != "Orange Mali" || mali.DenominationType != Range || !mali.SupportsLocalAmounts || mali.Pin || mali.Bundle ||
		mali.SenderCurrencyCode != "USD" || mali.DestinationCurrencyCode != "XOF" || mali.Country.ISOName != "ML" ||
		mali.Commission != "5.0" || mali.InternationalDiscount != "5.0" || mali.LocalDiscount != "0.0" ||
		mali.MinAmount != "3.90" || mali.MaxAmount != "64.95" || mali.LocalMinAmount != "1967.00" || mali.LocalMaxAmount != "32800.00" ||
		mali.FX.Rate != "505.00000000000" || mali.FX.CurrencyCode != "XOF" || len(mali.LogoURLs) != 3 ||
		len(mali.SuggestedAmounts) != 13 || mali.SuggestedAmountsMap["4"] != "2020.00" || mali.Status != "ACTIVE" {
		t.Fatalf("Orange Mali = %+v", mali)
	}
	if mali.ID != 289 || mali.OperatorID != 289 {
		t.Fatal("the id is written twice and both are kept")
	}

	egypt := byID[120]
	if egypt.DenominationType != Fixed || len(egypt.FixedAmounts) != len(egypt.LocalFixedAmounts) || len(egypt.FixedAmounts) < 10 ||
		egypt.FixedAmounts[0] != "0.17" || egypt.LocalFixedAmounts[0] != "5.00" ||
		egypt.FixedAmountsDescriptions["0.17"] != "Package EGP 5.00" || egypt.LocalFixedAmountsDescriptions["5.00"] != "Package EGP 5.00" {
		t.Fatalf("Etisalat Egypt = %+v", egypt)
	}
	if fees := byID[472].Fees; fees.LocalPercentage != "10.0" || fees.InternationalPercentage != "0.0" {
		t.Fatalf("Dialog fees = %+v", fees)
	}
	if fees := byID[475].Fees; fees.Local != "10.0" {
		t.Fatalf("Hutchison fees = %+v", fees)
	}
	if !byID[369].Pin || !byID[1230].Pin {
		t.Fatal("PIN operators lost their flag")
	}
	if !byID[346].Bundle || byID[1213].SupportsLocalAmounts {
		t.Fatal("bundle / local-amount flags lost")
	}
	if len(byID[110].Promotions) == 0 || byID[110].Promotions[0].Title == "" || byID[110].Promotions[0].StartDate == "" {
		t.Fatalf("promotions = %+v", byID[110].Promotions)
	}
	if plans := byID[200].GeographicalRechargePlans; len(plans) != 1 || plans[0].LocationCode == "" || len(plans[0].FixedAmounts) == 0 {
		t.Fatalf("geographical plans = %+v", plans)
	}
	if byID[289].Fees.International != "0.0" {
		t.Fatalf("fees = %+v", byID[289].Fees)
	}
}

func TestOperatorsAcceptNullsAndNumbersAsStrings(t *testing.T) {
	f := newFake(t)
	f.always("topups", ok(`{"content":[{"id":7,"operatorId":7,"name":"x","logoUrls":null,"minAmount":null,"localMinAmount":"12.50",
	"localFixedAmountsDescriptions":null,"fixedAmounts":[1,2.5,"3.0"],"fixedAmountsDescriptions":{},"fx":{"rate":1,"currencyCode":"USD"}}],"last":true}`))
	operators, err := f.client().Operators(context.Background())
	if err != nil || len(operators) != 1 {
		t.Fatalf("operators = %+v, err = %v", operators, err)
	}
	op := operators[0]
	if !op.MinAmount.Empty() || op.LocalMinAmount != "12.50" || op.LogoURLs != nil || op.LocalFixedAmountsDescriptions != nil ||
		len(op.FixedAmounts) != 3 || op.FixedAmounts[2] != "3.0" {
		t.Fatalf("op = %+v", op)
	}
}

func TestOperatorAndDetectOperatorPaths(t *testing.T) {
	f := newFake(t)
	var page pageOf[json.RawMessage]
	if err := json.Unmarshal([]byte(fixture(t, "operators.json")), &page); err != nil {
		t.Fatal(err)
	}
	f.always("topups", ok(string(page.Content[0])))
	c := f.client()
	op, err := c.Operator(context.Background(), 289)
	if err != nil || op.Key() != 289 {
		t.Fatalf("op = %+v, err = %v", op, err)
	}
	if calls := f.callsTo("topups"); calls[0].path != "/operators/289" ||
		parseQueryDecoded(t, calls[0].query)["suggestedAmountsMap"] != "true" {
		t.Fatalf("call = %+v", calls[0])
	}
	for _, test := range []struct {
		iso, phone, path string
	}{
		{"NE", "96123456", "/operators/auto-detect/phone/96123456/countries/NE"},
		{" ne ", "+22796123456", "/operators/auto-detect/phone/%2B22796123456/countries/NE"},
		{"EG", "010 1234 5678", "/operators/auto-detect/phone/010%201234%205678/countries/EG"},
	} {
		if _, err := c.DetectOperator(context.Background(), test.iso, test.phone); err != nil {
			t.Fatal(err)
		}
		calls := f.callsTo("topups")
		if got := calls[len(calls)-1].path; got != test.path {
			t.Errorf("path = %q, want %q", got, test.path)
		}
	}
	for _, bad := range [][2]string{{"", "123"}, {"NE", ""}, {"NIG", "123"}} {
		if _, err := c.DetectOperator(context.Background(), bad[0], bad[1]); !errors.Is(err, ErrInvalidRequest) {
			t.Errorf("DetectOperator(%q, %q) = %v", bad[0], bad[1], err)
		}
	}
	if _, err := c.Operator(context.Background(), 0); !errors.Is(err, ErrInvalidRequest) {
		t.Fatal("no id")
	}
}

func TestDetectOperatorErrors(t *testing.T) {
	f := newFake(t)
	f.always("topups", fail(404, `{"timeStamp":"2026-10-08 01:55:00","message":"Could not auto detect operator for given phone number","path":"/x","errorCode":"COULD_NOT_AUTO_DETECT_OPERATOR","infoLink":null,"details":[]}`))
	_, err := f.client().DetectOperator(context.Background(), "ML", "076123456")
	var api *APIError
	if !errors.As(err, &api) || api.Code != CodeCouldNotAutoDetect || !IsNotFound(err) {
		t.Fatalf("err = %#v", err)
	}
	g := newFake(t)
	g.always("topups", fail(409, `{"message":"The country selected is currently not supported","errorCode":"COUNTRY_NOT_SUPPORTED"}`))
	_, err = g.client().DetectOperator(context.Background(), "LY", "912345678")
	if !errors.As(err, &api) || api.Code != CodeCountryNotSupported || api.Status != 409 {
		t.Fatalf("err = %#v", err)
	}
}

func TestTopupCountries(t *testing.T) {
	f := newFake(t)
	f.always("topups", ok(fixture(t, "countries.json")))
	countries, err := f.client().TopupCountries(context.Background())
	if err != nil || len(countries) != 5 {
		t.Fatalf("countries = %+v, err = %v", countries, err)
	}
	for _, country := range countries {
		if country.ISOName == "ML" && (country.CurrencyCode != "XOF" || len(country.CallingCodes) != 1 || country.CallingCodes[0] != "+223") {
			t.Fatalf("Mali = %+v", country)
		}
	}
}

func TestTopupSendsTheDocumentedBody(t *testing.T) {
	f := newFake(t)
	f.always("topups", ok(fixture(t, "topup_local_niger.json")))
	c := f.client()
	request := TopupRequest{
		OperatorID: 640, Amount: "0.19786", UseLocalAmount: false, CustomIdentifier: "pointy-xyz",
		RecipientPhone: Phone{CountryCode: " ne ", Number: " +227 96 12 34 56 "},
		SenderPhone:    &Phone{CountryCode: "ly", Number: "912345678"}, RecipientEmail: " x@y.z ",
	}
	result, err := c.Topup(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	sent := f.callsTo("topups")[0]
	if sent.method != http.MethodPost || sent.path != "/topups" {
		t.Fatalf("request = %+v", sent)
	}
	body := string(sent.body)
	for _, part := range []string{`"operatorId":640`, `"amount":0.19786`, `"useLocalAmount":false`, `"customIdentifier":"pointy-xyz"`,
		`"recipientPhone":{"countryCode":"NE","number":"+227 96 12 34 56"}`, `"senderPhone":{"countryCode":"LY","number":"912345678"}`,
		`"recipientEmail":"x@y.z"`} {
		if !strings.Contains(body, part) {
			t.Errorf("body %s lacks %s", body, part)
		}
	}
	// The local top-up of the fixture.
	if result.TransactionID != 181341 || result.Status != StatusSuccessful || result.CustomIdentifier != "ptest-1791423932919599000" ||
		result.RecipientPhone != "22796123456" || result.CountryCode != "NE" || result.OperatorID != 640 ||
		result.OperatorName != "Airtel Niger" || result.RequestedAmount != "100" || result.RequestedAmountCurrencyCode != "XOF" ||
		result.DeliveredAmount != "100" || result.DeliveredAmountCurrencyCode != "XOF" || result.Discount != "0" ||
		result.DiscountCurrencyCode != "USD" || result.Fee != "0" || result.PinDetail != nil || result.SenderPhone != "" ||
		result.Balance.Cost != "0.19785" || result.Balance.OldBalance != "993.81000" || result.Balance.NewBalance != "993.61215" ||
		result.TransactionDate.Time != time.Date(2026, 10, 8, 1, 45, 35, 0, time.UTC) {
		t.Fatalf("result = %+v", result)
	}
	minimal := validTopup()
	minimal.RecipientPhone = Phone{CountryCode: "NE", Number: "96123456"}
	if _, err := c.Topup(context.Background(), minimal); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"senderPhone", "recipientEmail"} {
		if strings.Contains(string(f.callsTo("topups")[1].body), key) {
			t.Errorf("minimal body carries %s", key)
		}
	}
}

func TestTopupValidatesBeforeSending(t *testing.T) {
	for name, change := range map[string]func(*TopupRequest){
		"no operator":       func(r *TopupRequest) { r.OperatorID = 0 },
		"no amount":         func(r *TopupRequest) { r.Amount = "" },
		"zero amount":       func(r *TopupRequest) { r.Amount = "0" },
		"no identifier":     func(r *TopupRequest) { r.CustomIdentifier = "" },
		"long identifier":   func(r *TopupRequest) { r.CustomIdentifier = strings.Repeat("a", 151) },
		"no country":        func(r *TopupRequest) { r.RecipientPhone.CountryCode = "" },
		"long country":      func(r *TopupRequest) { r.RecipientPhone.CountryCode = "NER" },
		"no number":         func(r *TopupRequest) { r.RecipientPhone.Number = "  " },
		"bad sender phone":  func(r *TopupRequest) { r.SenderPhone = &Phone{CountryCode: "L", Number: "1"} },
		"amount is garbage": func(r *TopupRequest) { r.Amount = "1e5000000" },
	} {
		t.Run(name, func(t *testing.T) {
			f := newFake(t)
			f.always("topups", ok("{}"))
			request := validTopup()
			change(&request)
			c := f.client()
			_, err := c.Topup(context.Background(), request)
			_, asyncErr := c.TopupAsync(context.Background(), request)
			for _, err := range []error{err, asyncErr} {
				if !errors.Is(err, ErrInvalidRequest) || !Definite(err) {
					t.Fatalf("err = %v", err)
				}
			}
			if len(f.callsTo("auth"))+len(f.callsTo("topups")) != 0 {
				t.Fatal("an invalid top-up reached the network")
			}
		})
	}
}

func TestTopupAsyncAndStatus(t *testing.T) {
	f := newFake(t)
	f.on("topups", func(c call) reply {
		switch {
		case c.path == "/topups-async":
			return ok(fixture(t, "topup_async_accepted.json"))
		case c.path == "/topups/181396/status":
			return ok(fixture(t, "topup_status_processing.json"))
		case c.path == "/topups/181385/status":
			return ok(fixture(t, "topup_status_successful.json"))
		case c.path == "/topups/99/status":
			return fail(404, `{"timeStamp":"2026-10-08 01:55:01","message":"Transaction not found for given id","path":"/topups/99999999/status","errorCode":"TRANSACTION_NOT_FOUND","infoLink":null,"details":[]}`)
		}
		return fail(404, "")
	})
	c := f.client()
	id, err := c.TopupAsync(context.Background(), validTopup())
	if err != nil || id != 181396 {
		t.Fatalf("id = %d, err = %v", id, err)
	}
	if got := f.callsTo("topups")[0].path; got != "/topups-async" {
		t.Fatalf("path = %q", got)
	}
	processing, err := c.TopupStatus(context.Background(), id)
	if err != nil || processing.Status != StatusProcessing || processing.Transaction != nil || processing.Status.Final() {
		t.Fatalf("processing = %+v, err = %v", processing, err)
	}
	done, err := c.TopupStatus(context.Background(), 181385)
	if err != nil || !done.Status.Succeeded() || done.Transaction == nil || done.Transaction.Balance.Cost != "0.19785" ||
		done.Transaction.SenderPhone != "218912345678" || done.Transaction.TransactionID != 181385 {
		t.Fatalf("done = %+v, err = %v", done, err)
	}
	_, err = c.TopupStatus(context.Background(), 99)
	var api *APIError
	if !errors.As(err, &api) || api.Code != CodeTransactionNotFound || !IsNotFound(err) {
		t.Fatalf("err = %#v", err)
	}
}

func TestTopupDecodesAPinVoucher(t *testing.T) {
	f := newFake(t)
	f.always("topups", ok(fixture(t, "topup_pin_philippines.json")))
	result, err := f.client().Topup(context.Background(), validTopup())
	if err != nil || result.PinDetail == nil {
		t.Fatalf("result = %+v, err = %v", result, err)
	}
	pin := result.PinDetail
	if pin.Serial != "564312" || pin.Code != "773709732991756" || pin.Info3 != "Dial *233* and PIN #" || pin.Validity != "60 days" ||
		pin.IVR != "1-888-888-8888" || pin.Empty() {
		t.Fatalf("pin = %+v", pin)
	}
	if result.RequestedAmountCurrencyCode != "USD" || result.DeliveredAmountCurrencyCode != "PHP" || result.Balance.Cost != "0.08550" {
		t.Fatalf("result = %+v", result)
	}
}

func TestFindTopupsByIdentifier(t *testing.T) {
	f := newFake(t)
	f.always("topups", ok(fixture(t, "topup_report_page.json")))
	rows, err := f.client().FindTopups(context.Background(), "ptest-1791423932919599000", time.Time{}, time.Time{})
	if err != nil || len(rows) != 1 || rows[0].TransactionID != 181341 {
		t.Fatalf("rows = %+v, err = %v", rows, err)
	}
	call := f.callsTo("topups")[0]
	query := parseQueryDecoded(t, call.query)
	if call.path != "/topups/reports/transactions" || query["customIdentifier"] != "ptest-1791423932919599000" ||
		query["startDate"] != "" || query["endDate"] != "" {
		t.Fatalf("call = %+v", call)
	}
	// Special characters are encoded, not dropped.
	g := newFake(t)
	g.always("topups", ok(`{"content":[],"last":true}`))
	if _, err := g.client().FindTopups(context.Background(), "a b/c?d&e=é+", time.Time{}, time.Time{}); err != nil {
		t.Fatal(err)
	}
	if got := parseQueryDecoded(t, g.callsTo("topups")[0].query)["customIdentifier"]; got != "a b/c?d&e=é+" {
		t.Fatalf("identifier arrived as %q", got)
	}
}

func TestTopupTransactionAndBalance(t *testing.T) {
	f := newFake(t)
	f.on("topups", func(c call) reply {
		if c.path == "/accounts/balance" {
			return ok(balanceBody)
		}
		return ok(fixture(t, "topup_usd_niger.json"))
	})
	c := f.client()
	result, err := c.TopupTransaction(context.Background(), 181342)
	if err != nil || result.TransactionID != 181342 || result.Balance.Cost != "0.95000" || result.DeliveredAmount != "505.43" {
		t.Fatalf("result = %+v, err = %v", result, err)
	}
	if got := f.callsTo("topups")[0].path; got != "/topups/reports/transactions/181342" {
		t.Fatalf("path = %q", got)
	}
	if balance, err := c.TopupBalance(context.Background()); err != nil || balance.CurrencyCode != "USD" {
		t.Fatalf("balance = %+v, err = %v", balance, err)
	}
}

func TestTopupErrors(t *testing.T) {
	for _, test := range []struct {
		status int
		body   string
		code   string
		check  func(error) bool
	}{
		{400, `{"timeStamp":"x","message":"The custom identifier provided has already been used. Please provide a new, unique custom identifier","path":"/topups","errorCode":"CUSTOM_IDENTIFIER_ALREADY_USED","infoLink":null,"details":[]}`, CodeDuplicateCustomIdentifier, IsDuplicateIdentifier},
		{400, `{"timeStamp":"x","message":"Insufficient funds in the wallet to complete this transaction","path":"/topups","errorCode":"INSUFFICIENT_BALANCE","infoLink":null,"details":[]}`, CodeInsufficientBalance, IsInsufficientBalance},
		{400, `{"timeStamp":"x","message":"Recipient phone number is not valid","path":"/topups","errorCode":"INVALID_RECIPIENT_PHONE","infoLink":null,"details":[]}`, CodeInvalidRecipientPhone, nil},
		{400, `{"timeStamp":"x","message":"Min and max (local) amounts for operator id 640 (Airtel Niger) are : 100.00 XOF and 50000.00 XOF","path":"/topups","errorCode":"INVALID_LOCAL_AMOUNT_FOR_OPERATOR","infoLink":null,"details":[]}`, CodeInvalidLocalAmount, nil},
		{503, `{"timeStamp":"x","message":"The topup operator is currently unavailable or inactive, please try again later or contact support","path":"/topups","errorCode":"OPERATOR_UNAVAILABLE_OR_CURRENTLY_INACTIVE","infoLink":null,"details":[]}`, CodeOperatorUnavailable, func(err error) bool { return errors.Is(err, ErrOperatorUnavailable) }},
	} {
		f := newFake(t)
		f.always("topups", fail(test.status, test.body))
		_, err := f.client().Topup(context.Background(), validTopup())
		var api *APIError
		if !errors.As(err, &api) || api.Code != test.code || api.Status != test.status {
			t.Fatalf("err = %#v", err)
		}
		if test.check != nil && !test.check(err) {
			t.Fatalf("classification failed for %s", test.code)
		}
		if !Definite(err) {
			t.Fatalf("%s must be a definite refusal", test.code)
		}
		if n := len(f.callsTo("topups")); n != 1 {
			t.Fatalf("calls = %d", n)
		}
	}
}
