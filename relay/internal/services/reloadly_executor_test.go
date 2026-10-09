package services

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
)

// fakeReloadly is the token service and the three Reloadly products, each on its
// own server, answering from handlers keyed by "METHOD /path".
type fakeReloadly struct {
	t        *testing.T
	mu       sync.Mutex
	handlers map[string]http.HandlerFunc
	calls    []string
	bodies   map[string][]byte
	servers  map[string]*httptest.Server
}

func newFakeReloadly(t *testing.T) *fakeReloadly {
	t.Helper()
	f := &fakeReloadly{t: t, handlers: map[string]http.HandlerFunc{}, bodies: map[string][]byte{}, servers: map[string]*httptest.Server{}}
	for _, name := range []string{"auth", "giftcards", "topups", "utilities"} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			body, _ := io.ReadAll(r.Body)
			key := r.Method + " " + r.URL.Path
			f.mu.Lock()
			f.calls = append(f.calls, key)
			f.bodies[key] = body
			handler := f.handlers[key]
			f.mu.Unlock()
			if name == "auth" {
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"access_token":"token-` + name + `","expires_in":3600,"token_type":"Bearer"}`))
				return
			}
			if handler == nil {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte(`{"timestamp":"2026-10-08T01:41:31.693+00:00","status":404,"error":"Not Found","path":"` + r.URL.Path + `"}`))
				return
			}
			handler(w, r)
		}))
		t.Cleanup(server.Close)
		f.servers[name] = server
	}
	return f
}

func (f *fakeReloadly) on(key string, handler http.HandlerFunc) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.handlers[key] = handler
}

// answer replies with a fixed body.
func answer(status int, body string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}
}

// sequence replies with each body in turn, then the last one for ever.
func sequence(status int, bodies ...string) http.HandlerFunc {
	var mu sync.Mutex
	next := 0
	return func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		body := bodies[min(next, len(bodies)-1)]
		next++
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}
}

func (f *fakeReloadly) client() *reloadly.Client {
	f.t.Helper()
	client, err := reloadly.New(reloadly.Config{
		ClientID: "id", ClientSecret: "secret",
		AuthURL: f.servers["auth"].URL, GiftcardsURL: f.servers["giftcards"].URL,
		TopupsURL: f.servers["topups"].URL, UtilitiesURL: f.servers["utilities"].URL,
		RetryBackoff: time.Millisecond, Timeout: 2 * time.Second, PurchaseTimeout: 2 * time.Second,
	})
	if err != nil {
		f.t.Fatal(err)
	}
	return client
}

func (f *fakeReloadly) executor(client *reloadly.Client) *ReloadlyExecutor {
	return &ReloadlyExecutor{Client: client, SettleWait: 400 * time.Millisecond, PollEvery: time.Millisecond}
}

func (f *fakeReloadly) called(key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, call := range f.calls {
		if call == key {
			n++
		}
	}
	return n
}

func (f *fakeReloadly) body(key string) map[string]any {
	f.mu.Lock()
	raw := f.bodies[key]
	f.mu.Unlock()
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		f.t.Fatalf("%s: body %q: %v", key, raw, err)
	}
	return decoded
}

const topupSuccess = `{"transactionId":181341,"status":"SUCCESSFUL","operatorTransactionId":"7297929551:OrderConfirmed","customIdentifier":"order-1","recipientPhone":"22370123456","recipientEmail":null,"senderPhone":null,"countryCode":"ML","operatorId":289,"operatorName":"Orange Mali ","discount":0.49752,"discountCurrencyCode":"USD","requestedAmount":9.9505,"requestedAmountCurrencyCode":"USD","deliveredAmount":5025,"deliveredAmountCurrencyCode":"XOF","transactionDate":"2026-10-08 01:45:35","pinDetail":null,"fee":0,"balanceInfo":{"oldBalance":993.81000,"newBalance":984.35702,"cost":9.45298,"currencyCode":"USD","currencyName":"US Dollar","updatedAt":"2026-10-08 01:42:10"}}`

func testAirtimeOrder() AirtimeOrder {
	phone, _ := ParsePhone("70123456", "ML", []string{"223"})
	return AirtimeOrder{
		ClientRef: "order-1", OperatorID: 289, OperatorName: "Orange Mali", Phone: phone,
		Amount: big.NewRat(19901, 2000), Currency: "USD", Local: false,
		Receive: Money{Amount: "5000", Currency: "XOF"},
	}
}

func testBillOrder() BillOrder {
	return BillOrder{
		ClientRef: "order-2", BillerID: 26, BillerName: "Woyofal Senegal", Account: "14500000001",
		Amount: big.NewRat(860911, 100000), Currency: "USD", Local: false,
		Receive: Money{Amount: "5000", Currency: "XOF"}, Type: BillElectricity, Service: ServicePrepaid,
	}
}

func TestAnAirtimeOrderIsOneCallInDollarsAndItsReceiptComesFromReloadly(t *testing.T) {
	f := newFakeReloadly(t)
	f.on("POST /topups", answer(200, topupSuccess))
	executor := f.executor(f.client())

	result, err := executor.Airtime(context.Background(), testAirtimeOrder())
	if err != nil {
		t.Fatal(err)
	}
	// Exactly what Reloadly was sent: dollars, the purchase's id, the number as
	// country code plus national digits.
	body := f.body("POST /topups")
	phone := body["recipientPhone"].(map[string]any)
	if body["operatorId"] != float64(289) || body["amount"] != 9.9505 || body["useLocalAmount"] != false ||
		body["customIdentifier"] != "order-1" || phone["countryCode"] != "ML" || phone["number"] != "22370123456" {
		t.Fatalf("the order Reloadly was sent: %v", body)
	}
	if f.called("POST /topups") != 1 {
		t.Fatal("an order is one call")
	}
	if result.OrderID != "181341" || result.Status != vouchers.StatusSucceeded || result.CostUSD != "9.45298" {
		t.Fatalf("result: %+v", result)
	}
	want := map[string]string{
		ReceiptTransactionID: "181341", ReceiptOperator: "Orange Mali", ReceiptPhone: "+22370123456",
		ReceiptDeliveredAmount: "5025", ReceiptDeliveredCurrency: "XOF", ReceiptOperatorReference: "7297929551:OrderConfirmed",
		ReceiptOrderAmount: "9.9505", ReceiptOrderCurrency: "USD",
	}
	for key, value := range want {
		if result.Receipt[key] != value {
			t.Errorf("receipt[%s] = %q, want %q (%v)", key, result.Receipt[key], value, result.Receipt)
		}
	}
}

func TestALocalAirtimeOrderSaysSo(t *testing.T) {
	f := newFakeReloadly(t)
	f.on("POST /topups", answer(200, strings.Replace(topupSuccess, `"requestedAmount":9.9505,"requestedAmountCurrencyCode":"USD"`, `"requestedAmount":5000,"requestedAmountCurrencyCode":"XOF"`, 1)))
	order := testAirtimeOrder()
	order.Amount, order.Currency, order.Local = big.NewRat(5000, 1), "XOF", true
	result, err := f.executor(f.client()).Airtime(context.Background(), order)
	if err != nil {
		t.Fatal(err)
	}
	body := f.body("POST /topups")
	if body["amount"] != float64(5000) || body["useLocalAmount"] != true {
		t.Fatalf("local order: %v", body)
	}
	if result.Receipt[ReceiptOrderAmount] != "5000" || result.Receipt[ReceiptOrderCurrency] != "XOF" {
		t.Fatalf("receipt: %v", result.Receipt)
	}
}

func TestATopupStillProcessingIsWaitedForThenLeftPending(t *testing.T) {
	processing := strings.Replace(topupSuccess, `"status":"SUCCESSFUL"`, `"status":"PROCESSING"`, 1)
	f := newFakeReloadly(t)
	f.on("POST /topups", answer(200, processing))
	f.on("GET /topups/181341/status", sequence(200,
		`{"code":null,"message":null,"status":"PROCESSING","transaction":null}`,
		`{"code":null,"message":null,"status":"PROCESSING","transaction":null}`,
		`{"code":null,"message":null,"status":"SUCCESSFUL","transaction":`+topupSuccess+`}`))
	result, err := f.executor(f.client()).Airtime(context.Background(), testAirtimeOrder())
	if err != nil || result.Status != vouchers.StatusSucceeded || result.Receipt[ReceiptDeliveredAmount] != "5025" {
		t.Fatalf("settled: %+v %v", result, err)
	}
	if f.called("POST /topups") != 1 || f.called("GET /topups/181341/status") != 3 {
		t.Fatalf("one order, three looks: %v", f.calls)
	}

	// Never finishing: the order Reloadly named stays pending, never failed.
	stuck := newFakeReloadly(t)
	stuck.on("POST /topups", answer(200, processing))
	stuck.on("GET /topups/181341/status", answer(200, `{"code":null,"message":null,"status":"PROCESSING","transaction":null}`))
	result, err = stuck.executor(stuck.client()).Airtime(context.Background(), testAirtimeOrder())
	if err != nil || result.Status != vouchers.StatusPending || result.OrderID != "181341" || len(result.Receipt) != 0 {
		t.Fatalf("still open: %+v %v", result, err)
	}
	// A status that cannot be read does not fail an order Reloadly accepted.
	broken := newFakeReloadly(t)
	broken.on("POST /topups", answer(200, processing))
	broken.on("GET /topups/181341/status", answer(500, `{"message":"boom"}`))
	result, err = broken.executor(broken.client()).Airtime(context.Background(), testAirtimeOrder())
	if err != nil || result.Status != vouchers.StatusPending || result.OrderID != "181341" {
		t.Fatalf("unreadable status: %+v %v", result, err)
	}
}

func TestATopupRefundedOrFailedIsAFailureThatCostNothing(t *testing.T) {
	for _, status := range []string{"REFUNDED", "FAILED"} {
		f := newFakeReloadly(t)
		f.on("POST /topups", answer(200, strings.Replace(topupSuccess, `"status":"SUCCESSFUL"`, `"status":"`+status+`"`, 1)))
		result, err := f.executor(f.client()).Airtime(context.Background(), testAirtimeOrder())
		if err != nil || result.Status != vouchers.StatusFailed || result.OrderID != "181341" || result.CostUSD != "" || len(result.Receipt) != 0 {
			t.Fatalf("%s: %+v %v", status, result, err)
		}
	}
}

const paymentAccepted = `{"id":36,"status":"PROCESSING","referenceId":"order-2","code":"PAYMENT_PROCESSING_IN_PROGRESS","message":"The payment is being processed, status will be updated when biller processes the payment.","submittedAt":"2026-10-08 01:56:04","finalStatusAvailabilityAt":"2026-10-09 01:56:03"}`

const paymentSuccess = `{"code":"PAYMENT_PROCESSED_SUCCESSFULLY","message":"The payment was processed successfully","transaction":{"id":36,"status":"SUCCESSFUL","referenceId":"order-2","amount":8.60911,"amountCurrencyCode":"USD","deliveryAmount":5025,"deliveryAmountCurrencyCode":"XOF","fee":0,"feeCurrencyCode":"USD","discount":0.68873,"discountCurrencyCode":"USD","submittedAt":"2026-10-08 01:56:47","balanceInfo":{"oldBalance":935.33344,"newBalance":927.41336,"cost":7.92008,"currencyCode":"USD","currencyName":"US Dollar","updatedAt":"2026-10-08 05:56:42"},"billDetails":{"type":"ELECTRICITY_BILL_PAYMENT","billerId":26,"billerName":"Woyofal Senegal","billerCountryCode":"SN","billerReferenceId":"bvclYh62nn5a","serviceType":"PREPAID","completedAt":"2026-10-08 01:56:47","subscriberDetails":{"invoiceId":null,"accountNumber":"14500000001"},"pinDetails":{"token":"2737-6032-5315-7183-0856","info1":"10.7 kWh","info2":"DIAL *555#","info3":null}}}}`

func TestABillIsAcceptedThenReadUntilItSettlesAndYieldsItsToken(t *testing.T) {
	f := newFakeReloadly(t)
	f.on("POST /pay", answer(200, paymentAccepted))
	f.on("GET /transactions/36", sequence(200,
		strings.Replace(paymentSuccess, `"status":"SUCCESSFUL"`, `"status":"PROCESSING"`, 1),
		paymentSuccess))
	result, err := f.executor(f.client()).Bill(context.Background(), testBillOrder())
	if err != nil {
		t.Fatal(err)
	}
	body := f.body("POST /pay")
	if body["billerId"] != float64(26) || body["subscriberAccountNumber"] != "14500000001" || body["amount"] != 8.60911 ||
		body["useLocalAmount"] != false || body["referenceId"] != "order-2" {
		t.Fatalf("the payment Reloadly was sent: %v", body)
	}
	if _, has := body["amountId"]; has {
		t.Fatalf("a range biller has no plan: %v", body)
	}
	if _, has := body["additionalInfo"]; has {
		t.Fatalf("no invoice, no additional info: %v", body)
	}
	if f.called("POST /pay") != 1 {
		t.Fatal("a payment is one call")
	}
	if result.Status != vouchers.StatusSucceeded || result.OrderID != "36" || result.CostUSD != "7.92008" {
		t.Fatalf("result: %+v", result)
	}
	want := map[string]string{
		ReceiptTransactionID: "36", ReceiptBiller: "Woyofal Senegal", ReceiptAccount: "14500000001",
		// What the biller received, in its own currency; what was ordered beside it.
		ReceiptAmount: "5025", ReceiptCurrency: "XOF", ReceiptOrderAmount: "8.60911", ReceiptOrderCurrency: "USD",
		ReceiptToken: "2737-6032-5315-7183-0856", ReceiptUnits: "10.7 kWh", ReceiptBillerReference: "bvclYh62nn5a",
		ReceiptInfo: "DIAL *555#",
	}
	for key, value := range want {
		if result.Receipt[key] != value {
			t.Errorf("receipt[%s] = %q, want %q (%v)", key, result.Receipt[key], value, result.Receipt)
		}
	}
}

func TestABillWithAnInvoiceAndAPlanCarriesBoth(t *testing.T) {
	f := newFakeReloadly(t)
	f.on("POST /pay", answer(200, paymentAccepted))
	f.on("GET /transactions/36", answer(200, paymentSuccess))
	order := testBillOrder()
	order.Amount, order.Currency, order.Local = big.NewRat(10000, 1), "XOF", true
	order.InvoiceID, order.AmountID = "2024-118833", 3
	if _, err := f.executor(f.client()).Bill(context.Background(), order); err != nil {
		t.Fatal(err)
	}
	body := f.body("POST /pay")
	info, _ := body["additionalInfo"].(map[string]any)
	if body["amountId"] != float64(3) || body["useLocalAmount"] != true || body["amount"] != float64(10000) || info["invoiceId"] != "2024-118833" {
		t.Fatalf("payment: %v", body)
	}
}

func TestABillStillProcessingStaysPendingAndAFailedOneIsAFailure(t *testing.T) {
	f := newFakeReloadly(t)
	f.on("POST /pay", answer(200, paymentAccepted))
	f.on("GET /transactions/36", answer(200, strings.Replace(paymentSuccess, `"status":"SUCCESSFUL"`, `"status":"PROCESSING"`, 1)))
	result, err := f.executor(f.client()).Bill(context.Background(), testBillOrder())
	if err != nil || result.Status != vouchers.StatusPending || result.OrderID != "36" {
		t.Fatalf("processing: %+v %v", result, err)
	}
	for _, status := range []string{"FAILED", "REFUNDED"} {
		g := newFakeReloadly(t)
		g.on("POST /pay", answer(200, paymentAccepted))
		g.on("GET /transactions/36", answer(200, strings.Replace(paymentSuccess, `"status":"SUCCESSFUL"`, `"status":"`+status+`"`, 1)))
		result, err := g.executor(g.client()).Bill(context.Background(), testBillOrder())
		if err != nil || result.Status != vouchers.StatusFailed || result.OrderID != "36" || result.CostUSD != "" {
			t.Fatalf("%s: %+v %v", status, result, err)
		}
	}
}

func TestReloadlysErrorsBecomeTheLedgersFailures(t *testing.T) {
	order := testAirtimeOrder()
	cases := []struct {
		name       string
		status     int
		body       string
		code       string
		definite   bool
		redactedIn string
	}{
		{"no money at Reloadly", 400, `{"timeStamp":"2026-10-08 01:41:29","message":"Insufficient balance","errorCode":"INSUFFICIENT_BALANCE","path":"/topups"}`, vouchers.FailureCredit, true, ""},
		{"no money for a bill", 409, `{"message":"Insufficient wallet balance","errorCode":"INSUFFICIENT_WALLET_BALANCE"}`, vouchers.FailureCredit, true, ""},
		{"the credentials are refused", 401, `{"message":"Invalid token","errorCode":"INVALID_TOKEN"}`, vouchers.FailureUnauthorized, true, ""},
		{"the operator is off", 503, `{"message":"Operator unavailable","errorCode":"OPERATOR_UNAVAILABLE_OR_CURRENTLY_INACTIVE"}`, vouchers.FailureOutOfStock, true, ""},
		{"a number Reloadly refuses", 400, `{"message":"Invalid recipient phone 22370123456","errorCode":"INVALID_RECIPIENT_PHONE"}`, vouchers.FailureRefused, true, "22370123456"},
		{"an amount Reloadly refuses", 400, `{"message":"Invalid amount provided","errorCode":"INVALID_INPUT_PROVIDED"}`, vouchers.FailureRefused, true, ""},
		{"too many calls", 429, `{"message":"slow down"}`, vouchers.FailureUnreachable, true, ""},
		{"Reloadly breaks", 500, `{"message":"boom","errorCode":"INTERNAL"}`, vouchers.FailureUnknown, false, ""},
		{"a proxy's page", 502, `<html>bad gateway</html>`, vouchers.FailureUnknown, false, ""},
		{"a 400 that is not Reloadly's", 400, `<html>nope</html>`, vouchers.FailureUnknown, false, ""},
		{"an identifier already used", 400, `{"message":"The customIdentifier has already been used","errorCode":"CUSTOM_IDENTIFIER_ALREADY_USED"}`, vouchers.FailureUnknown, false, ""},
		{"the cannot-process-now answer", 500, `{"message":"try later","errorCode":"TRANSACTION_CANNOT_BE_PROCESSED_AT_THE_MOMENT"}`, vouchers.FailureUnknown, false, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFakeReloadly(t)
			f.on("POST /topups", answer(c.status, c.body))
			_, err := f.executor(f.client()).Airtime(context.Background(), order)
			var failure *vouchers.Failure
			if !errors.As(err, &failure) {
				t.Fatalf("want a *vouchers.Failure, got %v", err)
			}
			if failure.Code != c.code || failure.Definite != c.definite {
				t.Fatalf("got %s definite=%v, want %s definite=%v (%v)", failure.Code, failure.Definite, c.code, c.definite, failure)
			}
			if c.redactedIn != "" && strings.Contains(failure.Detail, c.redactedIn) {
				t.Fatalf("the number is echoed: %q", failure.Detail)
			}
			if c.status != 401 && f.called("POST /topups") != 1 {
				t.Fatalf("one call, never a retry: %d", f.called("POST /topups"))
			}
		})
	}
}

func TestABillRefusalIsRedactedToo(t *testing.T) {
	f := newFakeReloadly(t)
	f.on("POST /pay", answer(400, `{"message":"Unknown meter AB-77-1234x for this biller","errorCode":"INVALID_INPUT_PROVIDED"}`))
	order := testBillOrder()
	order.Account = "AB-77-1234x"
	_, err := f.executor(f.client()).Bill(context.Background(), order)
	var failure *vouchers.Failure
	if !errors.As(err, &failure) || !failure.Definite || strings.Contains(strings.ToLower(failure.Detail), "1234x") {
		t.Fatalf("%v", err)
	}
}

func TestAnAnswerThatNeverComesIsUncertainAndAServerThatIsGoneIsNot(t *testing.T) {
	f := newFakeReloadly(t)
	release := make(chan struct{})
	defer close(release)
	f.on("POST /topups", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	})
	client, err := reloadly.New(reloadly.Config{
		ClientID: "id", ClientSecret: "secret", AuthURL: f.servers["auth"].URL, GiftcardsURL: f.servers["giftcards"].URL,
		TopupsURL: f.servers["topups"].URL, UtilitiesURL: f.servers["utilities"].URL,
		RetryBackoff: time.Millisecond, Timeout: time.Second, PurchaseTimeout: 100 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = (&ReloadlyExecutor{Client: client}).Airtime(context.Background(), testAirtimeOrder())
	var failure *vouchers.Failure
	if !errors.As(err, &failure) || failure.Code != vouchers.FailureUnknown || failure.Definite {
		t.Fatalf("a timeout after sending may have bought it: %v", err)
	}

	// Nothing listening at all: the request never left.
	gone := newFakeReloadly(t)
	gone.servers["topups"].Close()
	_, err = gone.executor(gone.client()).Airtime(context.Background(), testAirtimeOrder())
	if !errors.As(err, &failure) || failure.Code != vouchers.FailureUnreachable || !failure.Definite {
		t.Fatalf("a refused connection bought nothing: %v", err)
	}
}

func TestOrdersAreReadBackByIdAndFoundByTheirIdentifier(t *testing.T) {
	f := newFakeReloadly(t)
	f.on("GET /topups/181341/status", answer(200, `{"code":null,"message":null,"status":"SUCCESSFUL","transaction":`+topupSuccess+`}`))
	f.on("GET /topups/181342/status", answer(200, `{"code":null,"message":null,"status":"PROCESSING","transaction":null}`))
	f.on("GET /topups/reports/transactions", answer(200, `{"content":[`+topupSuccess+`,`+
		strings.Replace(strings.Replace(topupSuccess, `"customIdentifier":"order-1"`, `"customIdentifier":"order-1-other"`, 1), `181341`, `181399`, 1)+
		`],"totalPages":1,"last":true}`))
	f.on("GET /transactions/36", answer(200, paymentSuccess))
	f.on("GET /transactions", answer(200, `{"content":[`+paymentSuccess+`],"totalPages":1,"last":true}`))
	executor := f.executor(f.client())
	ctx := context.Background()

	done, err := executor.Lookup(ctx, KindAirtime, "181341")
	if err != nil || done.Status != vouchers.StatusSucceeded || done.Receipt[ReceiptDeliveredAmount] != "5025" || done.CostUSD != "9.45298" {
		t.Fatalf("lookup: %+v %v", done, err)
	}
	open, err := executor.Lookup(ctx, KindAirtime, "181342")
	if err != nil || open.Status != vouchers.StatusPending || open.OrderID != "181342" {
		t.Fatalf("a top-up still processing: %+v %v", open, err)
	}
	bill, err := executor.Lookup(ctx, KindBill, "36")
	if err != nil || bill.Status != vouchers.StatusSucceeded || bill.Receipt[ReceiptToken] != "2737-6032-5315-7183-0856" {
		t.Fatalf("bill lookup: %+v %v", bill, err)
	}
	for _, bad := range []string{"", "abc", "-4", "0"} {
		if _, err := executor.Lookup(ctx, KindAirtime, bad); err == nil {
			t.Errorf("%q is not a transaction id", bad)
		}
	}
	if _, err := executor.Lookup(ctx, "gift", "1"); err == nil {
		t.Error("an unknown kind is refused")
	}
	if _, err := executor.Lookup(ctx, KindAirtime, "99"); err == nil {
		t.Error("a transaction Reloadly does not know is unreadable, not a verdict")
	}

	// Found by the identifier it was placed with; a near match is not it.
	found, err := executor.FindByClientRef(ctx, KindAirtime, "order-1", time.Time{}, time.Time{})
	if err != nil || len(found) != 1 || found[0].OrderID != "181341" || found[0].Status != vouchers.StatusSucceeded {
		t.Fatalf("find: %+v %v", found, err)
	}
	foundBills, err := executor.FindByClientRef(ctx, KindBill, "order-2", time.Time{}, time.Time{})
	if err != nil || len(foundBills) != 1 || foundBills[0].OrderID != "36" {
		t.Fatalf("find bills: %+v %v", foundBills, err)
	}
	if none, err := executor.FindByClientRef(ctx, KindAirtime, "order-3", time.Time{}, time.Time{}); err != nil || len(none) != 0 {
		t.Fatalf("an identifier nobody used: %+v %v", none, err)
	}
	if _, err := executor.FindByClientRef(ctx, KindAirtime, " ", time.Time{}, time.Time{}); err == nil {
		t.Error("a blank identifier would find everything")
	}
	f.on("GET /topups/reports/transactions", answer(500, `{"message":"boom"}`))
	if _, err := executor.FindByClientRef(ctx, KindAirtime, "order-1", time.Time{}, time.Time{}); err == nil {
		t.Error("an unreadable history is an error, never an empty answer")
	}
}

func TestTheDirectoryIsReadFromReloadlyAndOperatorsAreDetected(t *testing.T) {
	f := newFakeReloadly(t)
	f.on("GET /countries", answer(200, `[{"isoName":"ML","name":"Mali","currencyCode":"XOF","currencyName":"CFA Franc BCEAO","callingCodes":["+223"]}]`))
	operator := `{"id":289,"operatorId":289,"name":"Orange Mali","bundle":false,"data":false,"pin":false,"comboProduct":false,"supportsLocalAmounts":true,"denominationType":"RANGE","senderCurrencyCode":"USD","destinationCurrencyCode":"XOF","internationalDiscount":5.0,"localDiscount":0.0,"minAmount":3.9,"maxAmount":64.95,"localMinAmount":1967.0,"localMaxAmount":32800.0,"country":{"isoName":"ML","name":"Mali"},"fx":{"rate":505.0,"currencyCode":"XOF"},"logoUrls":[],"fixedAmounts":[],"localFixedAmounts":[],"fees":{},"status":"ACTIVE"}`
	f.on("GET /operators", answer(200, `{"content":[`+operator+`],"totalPages":1,"last":true}`))
	f.on("GET /billers", answer(200, `{"content":[{"id":26,"name":"Woyofal Senegal","countryCode":"SN","countryName":"Senegal","type":"ELECTRICITY_BILL_PAYMENT","serviceType":"PREPAID","denominationType":"RANGE","requiresInvoice":false,"localAmountSupported":true,"localTransactionCurrencyCode":"XOF","minLocalTransactionAmount":1000,"maxLocalTransactionAmount":310000,"internationalAmountSupported":true,"internationalTransactionCurrencyCode":"USD","minInternationalTransactionAmount":2,"maxInternationalTransactionAmount":500,"internationalDiscountPercentage":8,"fx":{"rate":583.684448242,"currencyCode":"USD"}}],"totalPages":1,"last":true}`))
	client := f.client()
	raw, err := ReloadlySource{Client: client}.Load(context.Background())
	if err != nil || len(raw.Countries) != 1 || len(raw.Operators) != 1 || len(raw.Billers) != 1 {
		t.Fatalf("load: %+v %v", raw, err)
	}
	snap := buildSnapshot(raw, TableNamer{}, time.Now())
	if len(snap.operators) != 1 || len(snap.billers) != 1 || snap.countries["ML"] == nil || snap.countries["SN"] == nil {
		t.Fatalf("snapshot: %+v", snap.stats)
	}
	// One failing read fails the whole reading.
	f.on("GET /billers", answer(500, `{"message":"boom"}`))
	if _, err := (ReloadlySource{Client: client}).Load(context.Background()); err == nil {
		t.Fatal("the directory is never half new")
	}

	// Detection.
	phone, _ := ParsePhone("70123456", "ML", []string{"223"})
	detector := ReloadlyDetector{Client: client}
	f.on("GET /operators/auto-detect/phone/22370123456/countries/ML", answer(200, operator))
	if id, err := detector.Detect(context.Background(), "ML", phone); err != nil || id != 289 {
		t.Fatalf("detect: %d %v", id, err)
	}
	for _, c := range []struct {
		status int
		body   string
		want   error
	}{
		{404, `{"message":"Could not auto detect operator","errorCode":"COULD_NOT_AUTO_DETECT_OPERATOR"}`, ErrNotDetected},
		{409, `{"message":"Country not supported","errorCode":"COUNTRY_NOT_SUPPORTED"}`, ErrNotDetected},
		{400, `{"message":"Invalid phone","errorCode":"INVALID_RECIPIENT_PHONE"}`, ErrNotDetected},
	} {
		f.on("GET /operators/auto-detect/phone/22370123456/countries/ML", answer(c.status, c.body))
		if _, err := detector.Detect(context.Background(), "ML", phone); !errors.Is(err, c.want) {
			t.Errorf("%d: %v", c.status, err)
		}
	}
	f.on("GET /operators/auto-detect/phone/22370123456/countries/ML", answer(500, `{"message":"boom"}`))
	if _, err := detector.Detect(context.Background(), "ML", phone); err == nil || errors.Is(err, ErrNotDetected) {
		t.Errorf("Reloadly being down is not 'not detected': %v", err)
	}
	f.on("GET /operators/auto-detect/phone/22370123456/countries/ML", answer(401, `{"message":"Invalid token","errorCode":"INVALID_TOKEN"}`))
	if _, err := detector.Detect(context.Background(), "ML", phone); err == nil || errors.Is(err, ErrNotDetected) {
		t.Errorf("refused credentials are not 'not detected': %v", err)
	}
}

func TestTheBalanceIsReadThroughEachProduct(t *testing.T) {
	f := newFakeReloadly(t)
	balance := `{"balance":932.95578,"frozenBalance":0,"currencyCode":"USD","currencyName":"US Dollar","lowBalanceThreshold":100}`
	f.on("GET /accounts/balance", answer(200, balance))
	got := ReloadlyBalances{Client: f.client()}.Balances(context.Background())
	if len(got) != 3 || got[0].Product != "giftcards" || got[2].Product != "utilities" {
		t.Fatalf("balances: %+v", got)
	}
	for _, line := range got {
		if line.Balance != "932.95578" || line.Currency != "USD" || line.Error != "" {
			t.Fatalf("%+v", line)
		}
	}
	// One product down does not hide the others.
	f.servers["topups"].Close()
	got = ReloadlyBalances{Client: f.client()}.Balances(context.Background())
	if got[1].Error == "" || got[0].Error != "" || got[2].Error != "" {
		t.Fatalf("balances with topups down: %+v", got)
	}
}

func TestPaymentAndTopupReceiptsDropWhatReloadlyDidNotSay(t *testing.T) {
	var payment reloadly.Payment
	if err := json.Unmarshal([]byte(strings.Replace(paymentSuccess, `"pinDetails":{"token":"2737-6032-5315-7183-0856","info1":"10.7 kWh","info2":"DIAL *555#","info3":null}`, `"pinDetails":{"token":null,"info1":null,"info2":null,"info3":null}`, 1)), &payment); err != nil {
		t.Fatal(err)
	}
	result := paymentResult(payment)
	for _, key := range []string{ReceiptToken, ReceiptUnits, ReceiptInfo} {
		if _, has := result.Receipt[key]; has {
			t.Errorf("an empty %s must not appear: %v", key, result.Receipt)
		}
	}
	if result.Receipt[ReceiptTransactionID] != "36" {
		t.Fatalf("receipt: %v", result.Receipt)
	}
	for text, want := range map[string]string{
		"10.7 kWh": "10.7 kWh", "Units: 25": "Units: 25", "Token valid for 30 days": "",
	} {
		if units, _ := splitUnits(text); units != want {
			t.Errorf("splitUnits(%q) = %q, want %q", text, units, want)
		}
	}
}

func TestAnAcceptedOrderKeepsItsIdWhateverTheStatusReadSays(t *testing.T) {
	// Reloadly named the order when it accepted it. A later read of a PROCESSING
	// order that carries no transaction, or one without its id, must not make the
	// ledger forget the name: the reconciler finds the order by it.
	t.Run("a bill whose status read has no transaction", func(t *testing.T) {
		f := newFakeReloadly(t)
		f.on("POST /pay", answer(200, paymentAccepted))
		f.on("GET /transactions/36", answer(200, `{"code":"PAYMENT_PROCESSING_IN_PROGRESS","message":"The payment is being processed"}`))
		result, err := f.executor(f.client()).Bill(context.Background(), testBillOrder())
		if err != nil || result.Status != vouchers.StatusPending || result.OrderID != "36" {
			t.Fatalf("still open, still order 36: %+v %v", result, err)
		}
		if f.called("GET /transactions/36") == 0 {
			t.Fatal("the payment was read")
		}
	})
	t.Run("a bill whose status read has a transaction without its id", func(t *testing.T) {
		f := newFakeReloadly(t)
		f.on("POST /pay", answer(200, paymentAccepted))
		f.on("GET /transactions/36", answer(200, `{"message":"processing","transaction":{"status":"PROCESSING","referenceId":"order-2"}}`))
		result, err := f.executor(f.client()).Bill(context.Background(), testBillOrder())
		if err != nil || result.Status != vouchers.StatusPending || result.OrderID != "36" {
			t.Fatalf("still order 36: %+v %v", result, err)
		}
	})
	t.Run("a top-up whose status read has a transaction without its id", func(t *testing.T) {
		processing := strings.Replace(topupSuccess, `"status":"SUCCESSFUL"`, `"status":"PROCESSING"`, 1)
		f := newFakeReloadly(t)
		f.on("POST /topups", answer(200, processing))
		f.on("GET /topups/181341/status", answer(200, `{"code":null,"message":null,"status":"PROCESSING","transaction":{"status":"PROCESSING"}}`))
		result, err := f.executor(f.client()).Airtime(context.Background(), testAirtimeOrder())
		if err != nil || result.Status != vouchers.StatusPending || result.OrderID != "181341" {
			t.Fatalf("still order 181341: %+v %v", result, err)
		}
	})
	t.Run("a payment that settles without saying its id", func(t *testing.T) {
		f := newFakeReloadly(t)
		f.on("POST /pay", answer(200, paymentAccepted))
		f.on("GET /transactions/36", answer(200, strings.Replace(paymentSuccess, `"id":36,`, ``, 1)))
		result, err := f.executor(f.client()).Bill(context.Background(), testBillOrder())
		if err != nil || result.Status != vouchers.StatusSucceeded || result.OrderID != "36" || result.Receipt[ReceiptTransactionID] != "36" {
			t.Fatalf("paid, as order 36 on the slip too: %+v %v", result, err)
		}
	})
	t.Run("reading a payment back by its id", func(t *testing.T) {
		f := newFakeReloadly(t)
		f.on("GET /transactions/36", answer(200, `{"message":"processing"}`))
		result, err := f.executor(f.client()).Lookup(context.Background(), KindBill, "36")
		if err != nil || result.Status != vouchers.StatusPending || result.OrderID != "36" {
			t.Fatalf("lookup: %+v %v", result, err)
		}
	})
}

func TestTheReceiptKeepsTheAmountsAsReloadlyWroteThem(t *testing.T) {
	// The relay does not round, trim or pad what the supplier says was delivered:
	// the shop formats it for the currency. A top-up credited 2010.0020 (Reloadly's
	// conversion of the dollars ordered), a payment 5025.0003 and so on.
	t.Run("a top-up", func(t *testing.T) {
		f := newFakeReloadly(t)
		body := strings.Replace(topupSuccess, `"deliveredAmount":5025`, `"deliveredAmount":2010.0020`, 1)
		body = strings.Replace(body, `"requestedAmount":9.9505`, `"requestedAmount":3.98020`, 1)
		f.on("POST /topups", answer(200, body))
		result, err := f.executor(f.client()).Airtime(context.Background(), testAirtimeOrder())
		if err != nil {
			t.Fatal(err)
		}
		if got := result.Receipt[ReceiptDeliveredAmount]; got != "2010.0020" {
			t.Fatalf("delivered_amount %q, as Reloadly wrote it", got)
		}
		if got := result.Receipt[ReceiptOrderAmount]; got != "3.98020" {
			t.Fatalf("order_amount %q", got)
		}
		// The ledger's own figures are clean decimals.
		if result.CostUSD != "9.45298" {
			t.Fatalf("cost %q", result.CostUSD)
		}
	})
	t.Run("a long float", func(t *testing.T) {
		f := newFakeReloadly(t)
		f.on("POST /topups", answer(200, strings.Replace(topupSuccess, `"deliveredAmount":5025`, `"deliveredAmount":2010.00200000000040745`, 1)))
		result, err := f.executor(f.client()).Airtime(context.Background(), testAirtimeOrder())
		if err != nil || result.Receipt[ReceiptDeliveredAmount] != "2010.00200000000040745" {
			t.Fatalf("%v %q", err, result.Receipt[ReceiptDeliveredAmount])
		}
	})
	t.Run("a number written with an exponent is spelled out", func(t *testing.T) {
		f := newFakeReloadly(t)
		f.on("POST /topups", answer(200, strings.Replace(topupSuccess, `"deliveredAmount":5025`, `"deliveredAmount":2.01E3`, 1)))
		result, err := f.executor(f.client()).Airtime(context.Background(), testAirtimeOrder())
		if err != nil || result.Receipt[ReceiptDeliveredAmount] != "2010" {
			t.Fatalf("%v %q", err, result.Receipt[ReceiptDeliveredAmount])
		}
	})
	t.Run("a payment", func(t *testing.T) {
		f := newFakeReloadly(t)
		f.on("POST /pay", answer(200, paymentAccepted))
		body := strings.Replace(paymentSuccess, `"deliveryAmount":5025`, `"deliveryAmount":5025.0003`, 1)
		body = strings.Replace(body, `"amount":8.60911`, `"amount":8.609110`, 1)
		f.on("GET /transactions/36", answer(200, body))
		result, err := f.executor(f.client()).Bill(context.Background(), testBillOrder())
		if err != nil {
			t.Fatal(err)
		}
		if result.Receipt[ReceiptAmount] != "5025.0003" || result.Receipt[ReceiptOrderAmount] != "8.609110" {
			t.Fatalf("receipt: %v", result.Receipt)
		}
	})
	t.Run("an amount that is no number is left out", func(t *testing.T) {
		f := newFakeReloadly(t)
		f.on("POST /topups", answer(200, strings.Replace(topupSuccess, `"deliveredAmount":5025`, `"deliveredAmount":"n/a"`, 1)))
		result, err := f.executor(f.client()).Airtime(context.Background(), testAirtimeOrder())
		if err != nil {
			t.Fatal(err)
		}
		if _, has := result.Receipt[ReceiptDeliveredAmount]; has {
			t.Fatalf("receipt: %v", result.Receipt)
		}
	})
}
