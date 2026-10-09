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

func validPay() PayRequest {
	return PayRequest{
		BillerID: 26, SubscriberAccountNumber: "14500000001", Amount: "1000", UseLocalAmount: true, ReferenceID: "ptest-3",
	}
}

func billerByID(t *testing.T, id int64) Biller {
	t.Helper()
	for _, biller := range fixtureRows[Biller](t, "billers.json") {
		if biller.ID == id {
			return biller
		}
	}
	t.Fatalf("biller %d is not in the fixture", id)
	return Biller{}
}

func TestBillersDecodeFixedAndRange(t *testing.T) {
	f := newFake(t)
	f.always("utilities", ok(fixture(t, "billers.json")))
	billers, err := f.client().Billers(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(billers) != 7 {
		t.Fatalf("billers = %d", len(billers))
	}
	byID := map[int64]Biller{}
	for _, biller := range billers {
		byID[biller.ID] = biller
	}
	woyofal := byID[26]
	if woyofal.Name != "Woyofal Senegal" || woyofal.CountryCode != "SN" || woyofal.Type != BillerElectricity || woyofal.ServiceType != "PREPAID" ||
		woyofal.DenominationType != Range || !woyofal.LocalAmountSupported || woyofal.LocalTransactionCurrencyCode != "XOF" ||
		woyofal.MinLocalTransactionAmount != "1000.0" || woyofal.MaxLocalTransactionAmount != "310000.0" ||
		woyofal.LocalTransactionFee != "117.50000" || woyofal.LocalTransactionFeeCurrencyCode != "XOF" ||
		!woyofal.InternationalAmountSupported || woyofal.InternationalTransactionCurrencyCode != "USD" ||
		woyofal.InternationalDiscountPercentage != "8.00000" || woyofal.FX.Rate != "470.000000000" || woyofal.FX.CurrencyCode != "USD" ||
		woyofal.RequiresInvoice {
		t.Fatalf("Woyofal = %+v", woyofal)
	}
	starTimes := byID[28]
	if starTimes.DenominationType != Fixed || len(starTimes.LocalFixedAmounts) != 6 || len(starTimes.InternationalFixedAmounts) != 6 ||
		starTimes.LocalFixedAmounts[0].ID != 39 || starTimes.LocalFixedAmounts[0].Amount != "400.0" ||
		starTimes.InternationalFixedAmounts[0].ID != 39 || starTimes.InternationalFixedAmounts[0].Amount != "0.66" ||
		starTimes.LocalFixedAmounts[0].Description == "" || !starTimes.MinLocalTransactionAmount.Empty() {
		t.Fatalf("StarTimes = %+v", starTimes)
	}
	southAfrica := byID[30]
	if southAfrica.LocalAmountSupported || !southAfrica.LocalTransactionFee.Empty() || southAfrica.InternationalTransactionFeePercentage != "8.0" ||
		southAfrica.LocalTransactionCurrencyCode != "" {
		t.Fatalf("South Africa = %+v", southAfrica)
	}
}

func TestABillerReadsTheMisspelledLocalCurrency(t *testing.T) {
	var biller Biller
	if err := json.Unmarshal([]byte(`{"id":1,"localTransactionCurencyCode":"NGN"}`), &biller); err != nil || biller.LocalTransactionCurrencyCode != "NGN" {
		t.Fatalf("biller = %+v, %v", biller, err)
	}
	if err := json.Unmarshal([]byte(`{"id":1,"localTransactionCurrencyCode":"XOF","localTransactionCurencyCode":"NGN"}`), &biller); err != nil ||
		biller.LocalTransactionCurrencyCode != "XOF" {
		t.Fatalf("the correct spelling must win: %+v, %v", biller, err)
	}
}

func TestPaySendsTheDocumentedBody(t *testing.T) {
	f := newFake(t)
	f.always("utilities", ok(fixture(t, "pay_accepted.json")))
	c := f.client()
	result, err := c.Pay(context.Background(), PayRequest{
		BillerID: 28, SubscriberAccountNumber: " 1234567890 ", Amount: "400", UseLocalAmount: true, AmountID: 39,
		ReferenceID: "pointy-r1", InvoiceID: " INV-9 ",
	})
	if err != nil {
		t.Fatal(err)
	}
	sent := f.callsTo("utilities")[0]
	if sent.method != http.MethodPost || sent.path != "/pay" {
		t.Fatalf("request = %+v", sent)
	}
	body := string(sent.body)
	for _, part := range []string{`"subscriberAccountNumber":"1234567890"`, `"amount":400`, `"amountId":39`, `"billerId":28`,
		`"useLocalAmount":true`, `"referenceId":"pointy-r1"`, `"additionalInfo":{"invoiceId":"INV-9"}`} {
		if !strings.Contains(body, part) {
			t.Errorf("body %s lacks %s", body, part)
		}
	}
	if result.ID != 7502 || result.Status != StatusProcessing || result.ReferenceID != "ptest-1791424561800772000" ||
		result.Code != "PAYMENT_PROCESSING_IN_PROGRESS" || result.Message == "" ||
		result.SubmittedAt.Time != time.Date(2026, 10, 8, 1, 56, 4, 0, time.UTC) ||
		result.FinalStatusAvailabilityAt.Time != time.Date(2026, 10, 9, 1, 56, 3, 0, time.UTC) {
		t.Fatalf("result = %+v", result)
	}
	if _, err := c.Pay(context.Background(), validPay()); err != nil {
		t.Fatal(err)
	}
	minimal := string(f.callsTo("utilities")[1].body)
	for _, key := range []string{"amountId", "additionalInfo"} {
		if strings.Contains(minimal, key) {
			t.Errorf("minimal body %s carries %s", minimal, key)
		}
	}
}

func TestPayValidatesBeforeSending(t *testing.T) {
	for name, change := range map[string]func(*PayRequest){
		"no biller":       func(r *PayRequest) { r.BillerID = 0 },
		"no account":      func(r *PayRequest) { r.SubscriberAccountNumber = " " },
		"no amount":       func(r *PayRequest) { r.Amount = "" },
		"negative amount": func(r *PayRequest) { r.Amount = "-1" },
		"no reference":    func(r *PayRequest) { r.ReferenceID = "" },
		"long reference":  func(r *PayRequest) { r.ReferenceID = strings.Repeat("r", 151) },
	} {
		t.Run(name, func(t *testing.T) {
			f := newFake(t)
			f.always("utilities", ok("{}"))
			request := validPay()
			change(&request)
			_, err := f.client().Pay(context.Background(), request)
			if !errors.Is(err, ErrInvalidRequest) || !Definite(err) {
				t.Fatalf("err = %v", err)
			}
			if len(f.callsTo("auth"))+len(f.callsTo("utilities")) != 0 {
				t.Fatal("an invalid payment reached the network")
			}
		})
	}
}

func TestPaymentReadsEveryOutcome(t *testing.T) {
	f := newFake(t)
	f.on("utilities", func(c call) reply {
		switch c.path {
		case "/transactions/7507":
			return ok(fixture(t, "payment_successful.json"))
		case "/transactions/7502":
			return ok(fixture(t, "payment_refunded.json"))
		}
		return fail(404, `{"timeStamp":"2026-10-08 01:57:59","message":"The transaction was not found.","path":"/transactions/99999999","errorCode":"TRANSACTION_NOT_FOUND","infoLink":null,"details":[]}`)
	})
	c := f.client()
	paid, err := c.Payment(context.Background(), 7507)
	if err != nil {
		t.Fatal(err)
	}
	tx := paid.Transaction
	if paid.Code != "PAYMENT_PROCESSED_SUCCESSFULLY" || tx.ID != 7507 || !tx.Status.Succeeded() || tx.Amount != "1000.00000" ||
		tx.AmountCurrencyCode != "XOF" || tx.DeliveryAmount != "1000.00000" || tx.Fee != "0.25000" || tx.FeeCurrencyCode != "USD" ||
		tx.Discount != "0.00000" || tx.Balance.Cost != "2.37766" || tx.Balance.OldBalance != "935.33344" ||
		tx.Bill.Type != BillerElectricity || tx.Bill.BillerID != 26 || tx.Bill.BillerName != "Woyofal Senegal" ||
		tx.Bill.BillerReferenceID != "bvclYh62nn5a" || tx.Bill.Subscriber.AccountNumber != "14500000001" ||
		tx.Bill.CompletedAt.Time != time.Date(2026, 10, 8, 1, 56, 47, 0, time.UTC) || tx.Bill.PinDetails.Token != "" ||
		tx.SubmittedAt.IsZero() {
		t.Fatalf("payment = %+v", paid)
	}
	refunded, err := c.Payment(context.Background(), 7502)
	if err != nil {
		t.Fatal(err)
	}
	if refunded.Code != "UNABLE_TO_PROCESS_PAYMENT" || refunded.Transaction.Status != StatusRefunded ||
		!refunded.Transaction.Status.Final() || !refunded.Transaction.Status.Unsuccessful() ||
		refunded.Transaction.Balance.Cost != "0.00000" || refunded.Transaction.Fee != "0.50000" ||
		!refunded.Transaction.Bill.CompletedAt.IsZero() {
		t.Fatalf("refunded = %+v", refunded)
	}
	if _, err := c.Payment(context.Background(), 99999999); !IsNotFound(err) {
		t.Fatalf("err = %v", err)
	}
	if _, err := c.Payment(context.Background(), 0); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("err = %v", err)
	}
}

func TestAPrepaidTokenIsKeptAsWritten(t *testing.T) {
	var payment Payment
	raw := `{"code":"PAYMENT_PROCESSED_SUCCESSFULLY","transaction":{"id":1,"status":"SUCCESSFUL","billDetails":{"pinDetails":{"token":"0123-4567-8901","info1":"DIAL *555#"},"subscriberDetails":{"accountNumber":4223568280}}}}`
	if err := json.Unmarshal([]byte(raw), &payment); err != nil {
		t.Fatal(err)
	}
	bill := payment.Transaction.Bill
	if bill.PinDetails.Token != "0123-4567-8901" || bill.PinDetails.Info1 != "DIAL *555#" || bill.Subscriber.AccountNumber != "4223568280" {
		t.Fatalf("bill = %+v", bill)
	}
}

func TestFindPaymentsByReference(t *testing.T) {
	f := newFake(t)
	f.always("utilities", ok(fixture(t, "payments_page.json")))
	rows, err := f.client().FindPayments(context.Background(), "ptest-1791424605917748000", time.Time{}, time.Time{})
	if err != nil || len(rows) != 1 || rows[0].Transaction.ID != 7507 || rows[0].Transaction.Balance.Cost != "2.37766" {
		t.Fatalf("rows = %+v, err = %v", rows, err)
	}
	call := f.callsTo("utilities")[0]
	query := parseQueryDecoded(t, call.query)
	if call.path != "/transactions" || query["referenceId"] != "ptest-1791424605917748000" || query["page"] != "1" {
		t.Fatalf("call = %+v", call)
	}
	// Without a reference the window clips the rows.
	g := newFake(t)
	g.always("utilities", ok(fixture(t, "payments_page.json")))
	rows, err = g.client().FindPayments(context.Background(), "", time.Date(2026, 10, 8, 2, 0, 0, 0, time.UTC), time.Time{})
	if err != nil || len(rows) != 0 {
		t.Fatalf("rows = %+v, err = %v", rows, err)
	}
}

func TestUtilityErrors(t *testing.T) {
	for _, test := range []struct {
		status int
		body   string
		code   string
		check  func(error) bool
	}{
		{400, `{"timeStamp":"x","message":"The provided reference ID has already been used. Please provide another one.","path":"/pay","errorCode":"REFERENCE_ID_ALREADY_USED","infoLink":null,"details":[]}`, CodeDuplicateReference, IsDuplicateIdentifier},
		{409, `{"timeStamp":"x","message":"Your wallet balance is insufficient to process this payment. Please add funds to your wallet and try again.","path":"/pay","errorCode":"INSUFFICIENT_WALLET_BALANCE","infoLink":null,"details":[]}`, CodeInsufficientWalletBalance, IsInsufficientBalance},
		{400, `{"timeStamp":"x","message":"Submitted amount is less than the minimum accepted by this biller.","path":"/pay","errorCode":"INVALID_AMOUNT","infoLink":null,"details":[]}`, CodeInvalidAmount, nil},
		{400, `{"timeStamp":"x","message":"Amount id is required for the given biller","path":"/pay","errorCode":"MISSING_REQUIRED_AMOUNT_ID","infoLink":null,"details":[]}`, CodeMissingAmountID, nil},
	} {
		f := newFake(t)
		f.always("utilities", fail(test.status, test.body))
		_, err := f.client().Pay(context.Background(), validPay())
		var api *APIError
		if !errors.As(err, &api) || api.Code != test.code || api.Status != test.status || !Definite(err) {
			t.Fatalf("err = %#v", err)
		}
		if test.check != nil && !test.check(err) {
			t.Fatalf("classification failed for %s", test.code)
		}
	}
	// The concurrent duplicate of a payment is a 500 that recorded nothing; it is
	// not provably so, which is why it is not definite.
	f := newFake(t)
	f.always("utilities", fail(500, `{"timeStamp":"x","message":"Transaction could not be processed at the moment, try again later or contact support.","path":"/pay","errorCode":"TRANSACTION_CANNOT_BE_PROCESSED_AT_THE_MOMENT","infoLink":null,"details":[]}`))
	if _, err := f.client().Pay(context.Background(), validPay()); err == nil || Definite(err) {
		t.Fatalf("err = %v", err)
	}
}

func TestUtilityBalance(t *testing.T) {
	f := newFake(t)
	f.always("utilities", ok(balanceBody))
	balance, err := f.client().UtilityBalance(context.Background())
	if err != nil || balance.CurrencyCode != "USD" {
		t.Fatalf("balance = %+v, err = %v", balance, err)
	}
	if got := f.callsTo("utilities")[0].header.Get("Accept"); got != "application/com.reloadly.utilities-v1+json" {
		t.Fatalf("Accept = %q", got)
	}
}
