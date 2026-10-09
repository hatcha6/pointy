package relay

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"pointy/relay/internal/control"
)

// A real Libyan IBAN shape with valid check digits (not anyone's account).
const (
	bankTestIBAN    = "LY83002048000020100120361"
	bankTestAccount = "000020100120361"
	companyTestIBAN = "LY09007009009011214872016"
)

var pngReceipt = append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, 64)...)

func (h *walletHarness) setUpBankAccount(t *testing.T) control.WalletBankSettings {
	t.Helper()
	code, body, raw := h.do(t, http.MethodPut, "/v1/wallet/admin/bank-accounts", "", `{"actor":"omar","accounts":[{
		"bank":"nab","bank_name":"مصرف شمال أفريقيا","holder":"الشركة","account_number":"009011214872016",
		"iban":"LY09 0070 0900 9011 2148 72016","enabled":true}]}`, map[string]string{"Authorization": "Bearer admin-token"})
	if code != http.StatusOK {
		t.Fatalf("saving the receiving account: %d %s", code, raw)
	}
	var settings control.WalletBankSettings
	encoded, _ := json.Marshal(body)
	_ = json.Unmarshal(encoded, &settings)
	return settings
}

// sendTransfer posts a bank transfer as the shop's backend does.
func (h *walletHarness) sendTransfer(t *testing.T, fields map[string]string, receipt []byte) (int, map[string]any) {
	t.Helper()
	values := map[string]string{
		"amount": "150", "idempotency_key": "bt-1", "requested_by": "hatem", "channel": "lypay",
		"payer_bank": "ncb", "payer_account": bankTestAccount, "payer_iban": bankTestIBAN,
	}
	for name, value := range fields {
		values[name] = value
	}
	var body bytes.Buffer
	form := multipart.NewWriter(&body)
	for name, value := range values {
		_ = form.WriteField(name, value)
	}
	if receipt != nil {
		part, _ := form.CreateFormFile("receipt", "receipt.png")
		_, _ = part.Write(receipt)
	}
	_ = form.Close()
	request := httptest.NewRequest(http.MethodPost, "http://relay.test/v1/wallet/topups/bank-transfer", &body)
	request.Header.Set("Content-Type", form.FormDataContentType())
	request.Header.Set(AccessTokenHeader, h.shop.AccessToken)
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	var decoded map[string]any
	_ = json.Unmarshal(recorder.Body.Bytes(), &decoded)
	return recorder.Code, decoded
}

func (h *walletHarness) admin(t *testing.T, method, target, body string) (int, map[string]any, string) {
	t.Helper()
	return h.do(t, method, target, "", body, map[string]string{"Authorization": "Bearer admin-token"})
}

func TestBankTransferIsOfferedOnlyOnceAnAccountIsSet(t *testing.T) {
	h := newWalletHarness(t)
	_, wallet, _ := h.do(t, http.MethodGet, "/v1/wallet", h.shop.AccessToken, "", nil)
	if offer := wallet["topups"].(map[string]any)["bank_transfer"].(map[string]any); offer["available"] != false {
		t.Fatalf("offered with no account: %v", offer)
	}
	if code, _ := h.sendTransfer(t, nil, pngReceipt); code != http.StatusServiceUnavailable {
		t.Fatalf("a transfer with no account to receive it: %d", code)
	}

	settings := h.setUpBankAccount(t)
	if len(settings.Accounts) != 1 || settings.Accounts[0].IBAN != companyTestIBAN || settings.Accounts[0].ID == "" {
		t.Fatalf("saved %+v", settings)
	}
	_, wallet, _ = h.do(t, http.MethodGet, "/v1/wallet", h.shop.AccessToken, "", nil)
	offer := wallet["topups"].(map[string]any)["bank_transfer"].(map[string]any)
	accounts := offer["accounts"].([]any)
	if offer["available"] != true || len(accounts) != 1 || accounts[0].(map[string]any)["iban"] != companyTestIBAN {
		t.Fatalf("offer: %v", offer)
	}

	if code, _, _ := h.admin(t, http.MethodPut, "/v1/wallet/admin/bank-accounts",
		`{"accounts":[{"bank":"nab","bank_name":"x","holder":"y","account_number":"1234567","iban":"LY10007009009011214872016","enabled":true}]}`); code != http.StatusUnprocessableEntity {
		t.Fatalf("an IBAN with wrong check digits was saved: %d", code)
	}
}

func TestBankTransferWaitsForAnOperatorThenCreditsOnce(t *testing.T) {
	h := newWalletHarness(t)
	h.setUpBankAccount(t)

	code, body := h.sendTransfer(t, nil, pngReceipt)
	if code != http.StatusCreated || body["next_action"] != "bank_transfer" {
		t.Fatalf("submit: %d %v", code, body)
	}
	topUp := body["top_up"].(map[string]any)
	id := topUp["id"].(string)
	transfer := topUp["transfer"].(map[string]any)
	if topUp["status"] != "review" || topUp["kind"] != "bank_transfer" || transfer["payer_iban"] != bankTestIBAN ||
		transfer["receipt_type"] != "image/png" || topUp["payer_hint"] != "LY•••0361" {
		t.Fatalf("top-up: %v", topUp)
	}
	if h.balance(t) != "0.000" {
		t.Fatal("a receipt credited the wallet")
	}
	// The app retrying a slow upload makes no second top-up.
	if code, again := h.sendTransfer(t, nil, pngReceipt); code != http.StatusOK || again["top_up"].(map[string]any)["id"] != id {
		t.Fatalf("replay: %d %v", code, again)
	}

	// The operator sees the receipt and the account it went to.
	code, detail, _ := h.admin(t, http.MethodGet, "/v1/wallet/admin/topups/"+id, "")
	if code != http.StatusOK || detail["account"].(map[string]any)["iban"] != companyTestIBAN || len(detail["duplicates"].([]any)) != 0 {
		t.Fatalf("detail: %d %v", code, detail)
	}
	request := httptest.NewRequest(http.MethodGet, "http://relay.test/v1/wallet/admin/topups/"+id+"/receipt", nil)
	request.Header.Set("Authorization", "Bearer admin-token")
	recorder := httptest.NewRecorder()
	h.server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK || recorder.Header().Get("Content-Type") != "image/png" ||
		!bytes.Equal(recorder.Body.Bytes(), pngReceipt) || !strings.Contains(recorder.Header().Get("Content-Security-Policy"), "sandbox") {
		t.Fatalf("receipt: %d %v", recorder.Code, recorder.Header())
	}

	// 140 arrived, not 150: the operator credits what landed.
	code, confirmed, raw := h.admin(t, http.MethodPost, "/v1/wallet/admin/topups/"+id+"/confirm", `{"actor":"omar","amount":"140"}`)
	if code != http.StatusOK || confirmed["applied"] != true {
		t.Fatalf("confirm: %d %s", code, raw)
	}
	if h.balance(t) != "140.000" {
		t.Fatalf("balance %s", h.balance(t))
	}
	stored := h.topUp(t, id)
	if stored.Status != control.WalletTopUpPaid || stored.Amount != "140.000" || stored.Transfer.DeclaredAmount != "150.000" ||
		stored.ConfirmedBy != "operator:omar" {
		t.Fatalf("stored %+v %+v", stored, stored.Transfer)
	}
	if code, again, _ := h.admin(t, http.MethodPost, "/v1/wallet/admin/topups/"+id+"/confirm", `{"actor":"omar"}`); code != http.StatusOK || again["applied"] != false {
		t.Fatalf("second confirm: %d %v", code, again)
	}
	if h.balance(t) != "140.000" {
		t.Fatal("credited twice")
	}
	// A paid transfer is not rejected after the fact.
	if code, _, _ := h.admin(t, http.MethodPost, "/v1/wallet/admin/topups/"+id+"/reject", `{"actor":"omar","reason":"لم يصل"}`); code != http.StatusConflict {
		t.Fatalf("rejecting a paid transfer: %d", code)
	}

	// The account it paid from is offered next time.
	_, wallet, _ := h.do(t, http.MethodGet, "/v1/wallet", h.shop.AccessToken, "", nil)
	saved := wallet["topups"].(map[string]any)["bank_transfer"].(map[string]any)["saved_payers"].([]any)
	if len(saved) != 1 || saved[0].(map[string]any)["payer_iban"] != bankTestIBAN {
		t.Fatalf("saved payers: %v", saved)
	}
}

func TestBankTransferRejectionCarriesItsReasonAndFlagsAReusedReceipt(t *testing.T) {
	h := newWalletHarness(t)
	h.setUpBankAccount(t)
	_, first := h.sendTransfer(t, nil, pngReceipt)
	_, second := h.sendTransfer(t, map[string]string{"idempotency_key": "bt-2"}, pngReceipt)
	firstID := first["top_up"].(map[string]any)["id"].(string)
	secondID := second["top_up"].(map[string]any)["id"].(string)

	_, detail, _ := h.admin(t, http.MethodGet, "/v1/wallet/admin/topups/"+secondID, "")
	if duplicates := detail["duplicates"].([]any); len(duplicates) != 1 || duplicates[0].(map[string]any)["id"] != firstID {
		t.Fatalf("one receipt behind two top-ups was not flagged: %v", detail["duplicates"])
	}
	if code, _, _ := h.admin(t, http.MethodPost, "/v1/wallet/admin/topups/"+secondID+"/reject", `{"actor":"omar","reason":""}`); code != http.StatusBadRequest {
		t.Fatalf("a rejection with no reason: %d", code)
	}
	code, _, raw := h.admin(t, http.MethodPost, "/v1/wallet/admin/topups/"+secondID+"/reject", `{"actor":"omar","reason":"الإيصال نفسه أُرسل من قبل"}`)
	if code != http.StatusOK {
		t.Fatalf("reject: %d %s", code, raw)
	}
	_, shop, _ := h.do(t, http.MethodGet, "/v1/wallet/topups/"+secondID, h.shop.AccessToken, "", nil)
	topUp := shop["top_up"].(map[string]any)
	if topUp["status"] != "rejected" || topUp["error_detail"] != "الإيصال نفسه أُرسل من قبل" {
		t.Fatalf("the shop must read the reason: %v", topUp)
	}
	if h.balance(t) != "0.000" {
		t.Fatal("a rejection moved money")
	}
}

func TestBankTransferRefusesWhatCannotBeChecked(t *testing.T) {
	h := newWalletHarness(t)
	h.setUpBankAccount(t)
	cases := []struct {
		name    string
		fields  map[string]string
		receipt []byte
		code    string
	}{
		{"bad iban", map[string]string{"payer_iban": "LY00002048000020100120361"}, pngReceipt, walletCodeInvalidIBAN},
		{"no channel", map[string]string{"channel": "cash"}, pngReceipt, walletCodeInvalidChannel},
		{"letters in the account", map[string]string{"payer_account": "12ab"}, pngReceipt, walletCodeInvalidPayerAccount},
		{"no receipt", nil, nil, walletCodeInvalidReceipt},
		{"not a photo or a pdf", nil, []byte("<html><script>alert(1)</script>"), walletCodeInvalidReceipt},
		{"amount", map[string]string{"amount": "1"}, pngReceipt, walletCodeInvalidAmount},
	}
	for i, c := range cases {
		c.fields = mergeFields(c.fields, map[string]string{"idempotency_key": "bad-" + string(rune('a'+i))})
		code, body := h.sendTransfer(t, c.fields, c.receipt)
		if code < 400 || body["code"] != c.code {
			t.Fatalf("%s: %d %v", c.name, code, body)
		}
	}
	pdf := append([]byte("%PDF-1.7\n"), bytes.Repeat([]byte("x"), 32)...)
	if code, body := h.sendTransfer(t, map[string]string{"idempotency_key": "pdf"}, pdf); code != http.StatusCreated ||
		body["top_up"].(map[string]any)["transfer"].(map[string]any)["receipt_type"] != "application/pdf" {
		t.Fatalf("a PDF receipt: %d %v", code, body)
	}
}

func TestBankTransferAlertOpensItsReviewPage(t *testing.T) {
	topUp := control.WalletTopUp{
		ID: "tu-1", Amount: "150.000", InvoiceNo: "DF-1", ShopName: "محل النور", Method: control.WalletTopUpMethodBankTransfer,
		Transfer: &control.WalletBankTransfer{Channel: "onepay", PayerBank: "ncb", PayerAccount: bankTestAccount, PayerIBAN: bankTestIBAN},
	}
	message, ok := walletTopUpAlert(topUp, "bank_transfer_submitted", "")
	if !ok || message.Click != "/topups/tu-1" || !strings.Contains(message.Title, "verify") || !strings.Contains(message.Body, bankTestIBAN) {
		t.Fatalf("alert: %+v", message)
	}
}

func mergeFields(base, extra map[string]string) map[string]string {
	merged := map[string]string{}
	for k, v := range base {
		merged[k] = v
	}
	for k, v := range extra {
		merged[k] = v
	}
	return merged
}
