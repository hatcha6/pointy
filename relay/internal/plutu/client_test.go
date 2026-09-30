package plutu

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// The vector from Plutu's own SDK tests (plutu-php
// tests/Unit/Services/PlutuLocalBankCards/expected_data), so this checks the
// relay against Plutu's arithmetic rather than against itself.
const (
	sdkSecret = "sk_ac63978fe4bc6defb55045fe84492021d1e87555"
	sdkQuery  = "gateway=localbankcards&approved=1&invoice_no=14022023&amount=5.00&transaction_id=100900" +
		"&hashed=79CA9C64A7DF0BB5E634CFA67A90219F5A6C7197265B8732CC5372EF519F761F"
)

func mustParse(t *testing.T, raw string) []Param {
	t.Helper()
	params, err := ParseQuery(raw)
	if err != nil {
		t.Fatal(err)
	}
	return params
}

func TestVerifyCallbackAcceptsPlutusOwnVector(t *testing.T) {
	params := mustParse(t, sdkQuery)
	if !VerifyCallback(sdkSecret, params, LocalBankCardsSignedFields) {
		t.Fatal("the SDK's own signed return must verify")
	}
	callback := ReadCallback(params)
	if !callback.Approved || callback.Canceled || callback.InvoiceNo != "14022023" ||
		callback.Amount != "5.00" || callback.TransactionID != "100900" || callback.Gateway != GatewayLocalBankCards {
		t.Fatalf("unexpected callback %+v", callback)
	}
}

func TestVerifyCallbackRejectsAnyChangeToTheSignedMessage(t *testing.T) {
	for name, query := range map[string]string{
		"amount raised":     strings.Replace(sdkQuery, "amount=5.00", "amount=500.00", 1),
		"invoice swapped":   strings.Replace(sdkQuery, "invoice_no=14022023", "invoice_no=14022024", 1),
		"approval injected": strings.Replace(sdkQuery, "approved=1", "approved=1&canceled=0", 1),
		"reordered":         "approved=1&gateway=localbankcards&invoice_no=14022023&amount=5.00&transaction_id=100900&hashed=79CA9C64A7DF0BB5E634CFA67A90219F5A6C7197265B8732CC5372EF519F761F",
		"no signature":      strings.Split(sdkQuery, "&hashed=")[0],
		"empty signature":   strings.Split(sdkQuery, "&hashed=")[0] + "&hashed=",
	} {
		if VerifyCallback(sdkSecret, mustParse(t, query), LocalBankCardsSignedFields) {
			t.Errorf("%s: a changed return must not verify", name)
		}
	}
	if VerifyCallback("sk_wrong", mustParse(t, sdkQuery), LocalBankCardsSignedFields) {
		t.Error("the wrong secret must not verify")
	}
	if VerifyCallback("", mustParse(t, sdkQuery), LocalBankCardsSignedFields) {
		t.Error("an unconfigured secret must never verify")
	}
}

func TestVerifyCallbackIgnoresParametersPlutuDoesNotSign(t *testing.T) {
	// A return URL that carries its own parameter: the SDK's reading signs only
	// the gateway's fields, so the extra one must not break verification.
	query := "topup=abc&" + sdkQuery
	if !VerifyCallback(sdkSecret, mustParse(t, query), LocalBankCardsSignedFields) {
		t.Fatal("an unsigned extra parameter must not break verification")
	}
}

func TestVerifyCallbackAlsoAcceptsTheDocumentedEverythingReading(t *testing.T) {
	// The docs say every parameter but "hashed" is signed. A return signed
	// that way, with a field outside the SDK's list, must verify too.
	params := []Param{
		{Key: "gateway", Value: "localbankcards"},
		{Key: "approved", Value: "1"},
		{Key: "invoice_no", Value: "DFW-1"},
		{Key: "amount", Value: "25.00"},
		{Key: "transaction_id", Value: "77"},
		{Key: "payment_ref", Value: "x y~z"},
	}
	signed := append(params, Param{Key: SignatureParam, Value: strings.ToLower(Sign(sdkSecret, params))})
	if !VerifyCallback(sdkSecret, signed, LocalBankCardsSignedFields) {
		t.Fatal("a return signed over every parameter must verify (lower-case hex too)")
	}
}

func TestParseQueryKeepsOrderAndPHPsRepeatedKeyRule(t *testing.T) {
	params := mustParse(t, "b=1&a=x+y&b=2&c=%7E")
	want := []Param{{"b", "2"}, {"a", "x y"}, {"c", "~"}}
	if len(params) != len(want) {
		t.Fatalf("got %+v", params)
	}
	for i := range want {
		if params[i] != want[i] {
			t.Fatalf("param %d: got %+v want %+v", i, params[i], want[i])
		}
	}
	if got := BuildQuery(params); got != "b=2&a=x+y&c=%7E" {
		t.Fatalf("http_build_query mismatch: %s", got)
	}
}

func TestConfirmLocalBankCardsSendsTheSDKsRequest(t *testing.T) {
	var gotForm url.Values
	var gotHeaders http.Header
	var gotPath string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotHeaders = r.Header.Clone()
		body, _ := io.ReadAll(r.Body)
		gotForm, _ = url.ParseQuery(string(body))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":200,"result":{"code":"CHECKOUT_REDIRECT","redirect_url":"https://checkout.plutus.ly/p/abc"}}`))
	}))
	defer server.Close()

	client := New(Config{BaseURL: server.URL, APIKey: "key-1", AccessToken: "token-1", SecretKey: "sk_x"})
	checkout, err := client.ConfirmLocalBankCards(context.Background(), CheckoutRequest{
		Amount:    "25.00",
		InvoiceNo: "DFW-ABC",
		ReturnURL: "https://relay.example/v1/wallet/plutu/return",
		Lang:      "ar",
	})
	if err != nil {
		t.Fatal(err)
	}
	if checkout.RedirectURL != "https://checkout.plutus.ly/p/abc" || checkout.Code != "CHECKOUT_REDIRECT" {
		t.Fatalf("unexpected checkout %+v", checkout)
	}
	if gotPath != "/transaction/localbankcards/confirm" {
		t.Fatalf("path %q", gotPath)
	}
	if gotHeaders.Get("X-API-KEY") != "key-1" || gotHeaders.Get("Authorization") != "Bearer token-1" {
		t.Fatalf("credentials not sent as the docs require: %v", gotHeaders)
	}
	if gotForm.Get("amount") != "25.00" || gotForm.Get("invoice_no") != "DFW-ABC" ||
		gotForm.Get("return_url") != "https://relay.example/v1/wallet/plutu/return" || gotForm.Get("lang") != "ar" {
		t.Fatalf("form %v", gotForm)
	}
	if gotForm.Has("secret_key") || strings.Contains(gotForm.Encode(), "sk_x") {
		t.Fatal("the secret key must never be sent to Plutu")
	}
}

func TestConfirmLocalBankCardsReadsPlutusErrorShapes(t *testing.T) {
	for name, tc := range map[string]struct {
		status int
		body   string
		code   string
	}{
		"envelope":         {http.StatusUnauthorized, `{"error":{"status":401,"code":"UNAUTHORIZED","message":"Invalid access token"}}`, "UNAUTHORIZED"},
		"sandbox ceiling":  {http.StatusBadRequest, `{"error":{"status":400,"code":"AMOUNT_EXCEEDED_MAXIMUM","message":"max 500"}}`, "AMOUNT_EXCEEDED_MAXIMUM"},
		"laravel":          {http.StatusUnprocessableEntity, `{"message":"The given data was invalid.","errors":{"amount":["bad"]}}`, "INVALID_INPUTS"},
		"error inside 200": {http.StatusOK, `{"error":{"status":403,"code":"DENIED_ACCESS_GATEWAY","message":"denied"}}`, "DENIED_ACCESS_GATEWAY"},
		"not https":        {http.StatusOK, `{"status":200,"result":{"code":"CHECKOUT_REDIRECT","redirect_url":"http://evil.example/p"}}`, "CHECKOUT_REDIRECT"},
		"html 502":         {http.StatusBadGateway, `<html>bad gateway</html>`, ""},
	} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer server.Close()
			_, err := New(Config{BaseURL: server.URL}).ConfirmLocalBankCards(context.Background(), CheckoutRequest{Amount: "5"})
			var apiErr *APIError
			if !errors.As(err, &apiErr) {
				t.Fatalf("want *APIError, got %v", err)
			}
			if apiErr.Code != tc.code {
				t.Fatalf("code %q want %q (%v)", apiErr.Code, tc.code, apiErr)
			}
		})
	}
}

func TestConfirmLocalBankCardsTimeoutIsATransportError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(300 * time.Millisecond):
		}
	}))
	defer server.Close()
	_, err := New(Config{BaseURL: server.URL, Timeout: 50 * time.Millisecond}).
		ConfirmLocalBankCards(context.Background(), CheckoutRequest{Amount: "5"})
	var transport *TransportError
	if !errors.As(err, &transport) || !transport.Timeout() {
		t.Fatalf("want a timed-out *TransportError, got %v", err)
	}
}
