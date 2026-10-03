package dafa

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Answers recorded from Dafa's test API (2026-10-01), trimmed of nothing that
// the client reads.
const (
	recordedSadadInitiate = `{
  "id": "0435addd-b785-47ff-b916-8b31d51e75c0",
  "amount": 10.000,
  "amount_str": "10.000",
  "is_paid": false,
  "payment_page_url": null,
  "callback_url": null,
  "created_at": "2026-10-01T12:40:39.108723Z",
  "gateway": {"id": "100e38b9-50fe-4ffe-9c35-00646bba4d0c", "name": "sadad"},
  "payment_method_details": {"id": "8bc02096-fb0f-47ab-b856-7353f88e2158", "name": {"ar": "سداد", "en": "sadad"}},
  "workspace": {"id": "1f5ba117-b2e4-48cc-b5a9-56d5e3cf2bd8", "name": "منظومة دفتر", "is_test": true},
  "last_error": null
}`
	recordedMoamalatInitiate = `{
  "id": "1e758fdb-1c6a-41fe-a8e1-25d19f58d4ce",
  "amount": 15.000,
  "amount_str": "15.000",
  "is_paid": false,
  "payment_page_url": "https://moamlat.testing.ly/1e758fdb-1c6a-41fe-a8e1-25d19f58d4ce",
  "callback_url": "https://relay.example/v1/wallet/dafa/webhook/abc?token=x",
  "created_at": "2026-10-01T12:41:49.856707Z",
  "gateway": {"id": "7b992f96-107d-4041-9f63-e83e2349faa5", "name": "moamalat"},
  "workspace": {"id": "1f5ba117", "name": "منظومة دفتر", "is_test": true},
  "last_error": null
}`
	recordedWrongOTP = `{
  "status": 400,
  "type": "BadRequest",
  "message": "رمز التحقق غير صحيح، يرجى إعادة إدخاله.",
  "data": {
    "code": "PAYER_OTP_WRONG",
    "fault": "payer",
    "retryable": true,
    "merchant_message": "سبب الفشل يعود إلى بيانات الزبون أو حسابه لدى المصرف.",
    "hint": "اطلب من الزبون التحقق من بياناته وإعادة المحاولة.",
    "provider_message": "simulated: wrong otp"
  }
}`
	recordedDeclinedRead = `{
  "id": "effc54eb-ee8a-4326-8a8b-1a6856631edc",
  "amount": 12.500,
  "amount_str": "12.500",
  "is_paid": false,
  "payment_page_url": null,
  "callback_url": null,
  "created_at": "2026-10-01T12:41:25.015897Z",
  "gateway": {"name": "sadad"},
  "workspace": {"is_test": true},
  "last_error": {"code": "PAYER_INSUFFICIENT_FUNDS", "fault": "payer", "provider_message": "simulated: declined by bank", "occurred_at": "2026-10-01T12:41:25.326186Z"}
}`
	recordedValidation = `{"status":422,"type":"InputValidation","message":"[birthyear] required","errors":{"birthyear":["required"]}}`
)

type recordedCall struct {
	method string
	path   string
	key    string
	ctype  string
	body   map[string]any
}

func fakeDafa(t *testing.T, status int, body string) (*httptest.Server, *[]recordedCall) {
	t.Helper()
	calls := &[]recordedCall{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var decoded map[string]any
		_ = json.Unmarshal(raw, &decoded)
		*calls = append(*calls, recordedCall{
			method: r.Method,
			path:   r.URL.EscapedPath(),
			key:    r.Header.Get("X-API-Key"),
			ctype:  r.Header.Get("Content-Type"),
			body:   decoded,
		})
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(server.Close)
	return server, calls
}

func TestInitiateSendsJSONWithTheKeyAndReadsThePayment(t *testing.T) {
	server, calls := fakeDafa(t, http.StatusOK, recordedSadadInitiate)
	client := New(Config{BaseURL: server.URL + "/", APIKey: " dafa_test_key "})
	payment, err := client.Initiate(context.Background(), InitiateRequest{
		Provider:       ProviderSadad,
		Amount:         "10.000",
		UserIdentifier: "912345678",
		BirthYear:      "1995",
		CallbackURL:    "https://relay.example/hook",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(*calls) != 1 {
		t.Fatalf("one call expected, got %d", len(*calls))
	}
	call := (*calls)[0]
	if call.method != http.MethodPost || call.path != "/payments/initiate" || call.key != "dafa_test_key" ||
		call.ctype != "application/json" {
		t.Fatalf("unexpected request %+v", call)
	}
	// birthyear must be a string: Dafa refuses a number.
	want := map[string]any{"provider": "sadad", "amount": "10.000", "user_identifier": "912345678",
		"birthyear": "1995", "callback_url": "https://relay.example/hook"}
	for key, value := range want {
		if call.body[key] != value {
			t.Errorf("body[%s] = %#v, want %#v", key, call.body[key], value)
		}
	}
	if payment.ID != "0435addd-b785-47ff-b916-8b31d51e75c0" || payment.Amount != "10.000" || payment.IsPaid ||
		payment.PaymentPageURL != "" || payment.Gateway != "sadad" || !payment.WorkspaceKnown || !payment.TestWorkspace ||
		payment.LastError != nil || payment.CreatedAt.IsZero() {
		t.Fatalf("unexpected payment %+v", payment)
	}
}

func TestInitiateOmitsWhatAMethodDoesNotTake(t *testing.T) {
	server, calls := fakeDafa(t, http.StatusOK, recordedMoamalatInitiate)
	payment, err := New(Config{BaseURL: server.URL, APIKey: "k"}).Initiate(context.Background(),
		InitiateRequest{Provider: ProviderMoamalat, Amount: "15"})
	if err != nil {
		t.Fatal(err)
	}
	body := (*calls)[0].body
	for _, absent := range []string{"user_identifier", "birthyear", "callback_url"} {
		if _, ok := body[absent]; ok {
			t.Errorf("%s must be left out when empty: %v", absent, body)
		}
	}
	if payment.PaymentPageURL != "https://moamlat.testing.ly/1e758fdb-1c6a-41fe-a8e1-25d19f58d4ce" ||
		!UsablePaymentPage(payment.PaymentPageURL) {
		t.Fatalf("payment page: %q", payment.PaymentPageURL)
	}
}

func TestConfirmAndReadBackUseThePaymentPath(t *testing.T) {
	server, calls := fakeDafa(t, http.StatusOK, recordedDeclinedRead)
	client := New(Config{BaseURL: server.URL, APIKey: "k"})
	if _, err := client.Confirm(context.Background(), "abc/../x", "111111"); err != nil {
		t.Fatal(err)
	}
	payment, err := client.Payment(context.Background(), "effc54eb")
	if err != nil {
		t.Fatal(err)
	}
	if (*calls)[0].path != "/payments/abc%2F..%2Fx/confirm" || (*calls)[0].body["otp"] != "111111" {
		t.Fatalf("confirm request: %+v", (*calls)[0])
	}
	if (*calls)[1].method != http.MethodGet || (*calls)[1].path != "/payments/effc54eb" || (*calls)[1].ctype != "" {
		t.Fatalf("read request: %+v", (*calls)[1])
	}
	if payment.LastError == nil || payment.LastError.Code != "PAYER_INSUFFICIENT_FUNDS" ||
		payment.LastError.Fault != "payer" || payment.LastError.OccurredAt.IsZero() {
		t.Fatalf("last error: %+v", payment.LastError)
	}
	if _, err := client.Confirm(context.Background(), " ", "111111"); err == nil {
		t.Fatal("an empty payment id must never reach Dafa")
	}
	if _, err := client.Payment(context.Background(), ""); err == nil {
		t.Fatal("an empty payment id must never reach Dafa")
	}
	if len(*calls) != 2 {
		t.Fatalf("nothing more may have been sent, got %d calls", len(*calls))
	}
}

func TestErrorsCarryDafasCodeAndArabicMessage(t *testing.T) {
	server, _ := fakeDafa(t, http.StatusBadRequest, recordedWrongOTP)
	_, err := New(Config{BaseURL: server.URL, APIKey: "k"}).Confirm(context.Background(), "p1", "123456")
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("want *APIError, got %T %v", err, err)
	}
	if apiErr.Status != 400 || apiErr.Type != "BadRequest" || apiErr.Code != "PAYER_OTP_WRONG" || apiErr.Fault != "payer" ||
		!apiErr.Retryable || apiErr.Message != "رمز التحقق غير صحيح، يرجى إعادة إدخاله." ||
		apiErr.ProviderMessage != "simulated: wrong otp" || apiErr.Hint == "" {
		t.Fatalf("unexpected error %+v", apiErr)
	}

	server, _ = fakeDafa(t, http.StatusUnprocessableEntity, recordedValidation)
	_, err = New(Config{BaseURL: server.URL, APIKey: "k"}).Initiate(context.Background(), InitiateRequest{Provider: "sadad", Amount: "1"})
	if !errors.As(err, &apiErr) || apiErr.Code != "" || apiErr.Type != "InputValidation" {
		t.Fatalf("validation error: %+v", err)
	}
	if problem, ok := apiErr.FieldProblem("birthyear"); !ok || problem != "required" {
		t.Fatalf("field problem: %q %v", problem, ok)
	}
	if _, ok := apiErr.FieldProblem("user_identifier"); ok {
		t.Fatal("a field Dafa did not mention has no problem")
	}

	server, _ = fakeDafa(t, http.StatusBadGateway, "<html>bad gateway</html>")
	_, err = New(Config{BaseURL: server.URL, APIKey: "k"}).Payment(context.Background(), "p1")
	if !errors.As(err, &apiErr) || apiErr.Status != http.StatusBadGateway || !strings.Contains(apiErr.Message, "bad gateway") {
		t.Fatalf("an HTML error page must still be an APIError: %+v", err)
	}
}

func TestA2xxWithoutAPaymentIsAnError(t *testing.T) {
	server, _ := fakeDafa(t, http.StatusOK, `{"ok":true}`)
	_, err := New(Config{BaseURL: server.URL, APIKey: "k"}).Payment(context.Background(), "p1")
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("a payment without an id must not pass: %v", err)
	}
}

func TestTheClientNeverFollowsARedirectWithTheKey(t *testing.T) {
	var leaked string
	elsewhere := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		leaked = r.Header.Get("X-API-Key")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, recordedSadadInitiate)
	}))
	defer elsewhere.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, elsewhere.URL+"/steal", http.StatusTemporaryRedirect)
	}))
	defer server.Close()
	_, err := New(Config{BaseURL: server.URL, APIKey: "dafa_live_secret", HTTPClient: &http.Client{}}).Payment(context.Background(), "p1")
	if err == nil {
		t.Fatal("a redirect must not be followed to a payment")
	}
	if leaked != "" {
		t.Fatalf("the key reached another host: %q", leaked)
	}
}

func TestTransportErrorsSayWhetherTheyTimedOut(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
	}))
	defer server.Close()
	_, err := New(Config{BaseURL: server.URL, APIKey: "k", Timeout: 20 * time.Millisecond}).Payment(context.Background(), "p1")
	var transport *TransportError
	if !errors.As(err, &transport) || !transport.Timeout() {
		t.Fatalf("want a timed-out TransportError, got %v", err)
	}
}

func TestKeyEnvironment(t *testing.T) {
	for key, want := range map[string][2]bool{
		"dafa_test_abc":   {true, true},
		" dafa_live_abc ": {false, true},
		"sk_live_abc":     {false, false},
		"":                {false, false},
	} {
		test, known := KeyEnvironment(key)
		if test != want[0] || known != want[1] {
			t.Errorf("%q: test=%v known=%v", key, test, known)
		}
	}
}

func TestParsePaymentReadsAWebhookBody(t *testing.T) {
	payment, err := ParsePayment([]byte(`{"id":"p9","amount":25.5,"is_paid":true,"gateway":{"name":"edfali"}}`))
	if err != nil || payment.ID != "p9" || payment.Amount != "25.5" || !payment.IsPaid || payment.WorkspaceKnown {
		t.Fatalf("webhook body: %+v %v", payment, err)
	}
	if _, err := ParsePayment([]byte(`{"is_paid":true}`)); err == nil {
		t.Fatal("a body without an id is not a payment")
	}
}

func TestUsablePaymentPage(t *testing.T) {
	for raw, want := range map[string]bool{
		"https://moamlat.testing.ly/abc":          true,
		"https://localbankcards.dafa.ly/abc":      true,
		"http://moamlat.testing.ly/abc":           false,
		"javascript:alert(1)":                     false,
		"https://user:pass@moamlat.testing.ly/ab": false,
		"/relative": false,
		"":          false,
	} {
		if got := UsablePaymentPage(raw); got != want {
			t.Errorf("%q: got %v", raw, got)
		}
	}
}

func TestProvidersAndTheirPayers(t *testing.T) {
	if len(Providers()) != 7 {
		t.Fatalf("the docs list seven methods, got %d", len(Providers()))
	}
	sadad, _ := LookupProvider(ProviderSadad)
	moamalat, _ := LookupProvider(ProviderMoamalat)
	sahara, _ := LookupProvider(ProviderSaharaPay)
	if sadad.Payer != PayerPhone || !sadad.BirthYear || sadad.HostedPage {
		t.Errorf("sadad: %+v", sadad)
	}
	if moamalat.Payer != PayerNone || !moamalat.HostedPage {
		t.Errorf("moamalat: %+v", moamalat)
	}
	if sahara.Payer != PayerCard || sahara.BirthYear {
		t.Errorf("sahara-pay: %+v", sahara)
	}
	if _, ok := LookupProvider("tlync"); ok {
		t.Error("an unknown provider must not be found")
	}
}

func TestNormalizePhone(t *testing.T) {
	for raw, want := range map[string]string{
		"912345678":        "912345678",
		"0912345678":       "912345678",
		"091-234-5678":     "912345678",
		"+218 91 234 5678": "912345678",
		"00218912345678":   "912345678",
		"218912345678":     "912345678",
		"٠٩٢٣٤٥٦٧٨٩":       "923456789",
		"۰۹۴۱۲۳۴۵۶۷":       "941234567",
		"(091) 234 5678":   "912345678",
		"812345678":        "",
		"91234567":         "",
		"0912345678 ext 1": "",
		"+1 202 555 0100":  "",
		"21891234567":      "",
		"0912345678912":    "",
		"‏0912345678":      "912345678",
		"abc":              "",
		"":                 "",
	} {
		got, ok := NormalizePhone(raw)
		if got != want || ok != (want != "") {
			t.Errorf("%q: got %q ok=%v, want %q", raw, got, ok, want)
		}
	}
}

func TestNormalizeCardNumberAndOTP(t *testing.T) {
	if got, ok := NormalizeCardNumber("1234 5678-9012 3456"); !ok || got != "1234567890123456" {
		t.Errorf("card: %q %v", got, ok)
	}
	for _, bad := range []string{"12345", "12345678901234567890", "+1234567", "1234x5678"} {
		if _, ok := NormalizeCardNumber(bad); ok {
			t.Errorf("card %q must be refused", bad)
		}
	}
	if got, ok := NormalizeOTP(" ١١١ ١١١ "); !ok || got != "111111" {
		t.Errorf("otp: %q %v", got, ok)
	}
	for _, bad := range []string{"123", "123456789", "12a456", "+123456"} {
		if _, ok := NormalizeOTP(bad); ok {
			t.Errorf("otp %q must be refused", bad)
		}
	}
}
