package reloadly

import (
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestRetryAfterIsRead(t *testing.T) {
	h := http.Header{"Retry-After": {"7"}}
	if got := newAPIError("topups", "x", 429, h, nil, true).RetryAfter; got != 7*time.Second {
		t.Fatalf("RetryAfter = %v", got)
	}
	if got := newAPIError("topups", "x", 429, http.Header{}, nil, true).RetryAfter; got != 0 {
		t.Fatalf("RetryAfter = %v", got)
	}
}

func TestErrorsAreClassified(t *testing.T) {
	spring404 := `{"timestamp":"2026-10-08T01:41:31.693+00:00","status":404,"error":"Not Found","path":"/nonexistent"}`
	for _, test := range []struct {
		name       string
		status     int
		body       string
		sent       bool
		definite   bool
		structured bool
		is         error
		code       string
	}{
		{"duplicate custom identifier", 400, `{"timeStamp":"2026-10-08 01:42:29","message":"The custom identifier provided has already been used. Please provide a new, unique custom identifier","path":"/orders","errorCode":"CUSTOM_IDENTIFIER_ALREADY_USED","infoLink":null,"details":[]}`, true, true, true, ErrDuplicateIdentifier, CodeDuplicateCustomIdentifier},
		{"duplicate reference", 400, `{"message":"The provided reference ID has already been used. Please provide another one.","errorCode":"REFERENCE_ID_ALREADY_USED"}`, true, true, true, ErrDuplicateIdentifier, CodeDuplicateReference},
		{"duplicate without a code", 400, `{"message":"The custom identifier provided has already been used."}`, true, true, true, ErrDuplicateIdentifier, ""},
		{"top-up balance", 400, `{"message":"Insufficient funds in the wallet to complete this transaction","errorCode":"INSUFFICIENT_BALANCE"}`, true, true, true, ErrInsufficientBalance, CodeInsufficientBalance},
		{"utility balance", 409, `{"message":"Your wallet balance is insufficient to process this payment.","errorCode":"INSUFFICIENT_WALLET_BALANCE"}`, true, true, true, ErrInsufficientBalance, CodeInsufficientWalletBalance},
		{"gift balance without a code", 400, `{"message":"Insufficient balance","errorCode":null}`, true, true, true, ErrInsufficientBalance, ""},
		{"gift limit, no code", 400, `{"timeStamp":"2026-10-08 02:04:45","message":"Sorry, you cannot order products valued more than 100 USD at a go.","path":"/orders","errorCode":null,"infoLink":null,"details":[]}`, true, true, true, nil, ""},
		{"unknown product", 404, `{"message":"Invalid product id","errorCode":"INVALID_PRODUCT"}`, true, true, true, ErrNotFound, CodeInvalidProduct},
		{"unknown path", 404, spring404, true, true, true, ErrNotFound, ""},
		{"bad token", 401, `{"message":"Invalid token","errorCode":"INVALID_TOKEN"}`, true, true, true, ErrUnauthorized, CodeInvalidToken},
		{"401 from a proxy", 401, `<html>nope</html>`, true, true, false, ErrUnauthorized, ""},
		{"credentials", 401, `{"message":"Access Denied","errorCode":"INVALID_CREDENTIALS"}`, false, true, true, ErrUnauthorized, CodeInvalidCredentials},
		{"token service form", 403, `{"error":"access_denied","error_description":"Unauthorized"}`, false, true, true, ErrUnauthorized, "ACCESS_DENIED"},
		{"validation", 400, `{"message":"Missing required field amount","errorCode":"INVALID_INPUT_PROVIDED"}`, true, true, true, nil, CodeInvalidInput},
		{"validation without a code", 400, `{"message":"x"}`, true, true, true, nil, ""},
		{"operator off", 503, `{"message":"The topup operator is currently unavailable","errorCode":"OPERATOR_UNAVAILABLE_OR_CURRENTLY_INACTIVE"}`, true, true, true, ErrOperatorUnavailable, CodeOperatorUnavailable},
		{"cannot process, 400", 400, `{"message":"try again later","errorCode":"TRANSACTION_CANNOT_BE_PROCESSED_AT_THE_MOMENT"}`, true, true, true, nil, CodeCannotProcessNow},
		{"cannot process, 500", 500, `{"message":"try again later","errorCode":"TRANSACTION_CANNOT_BE_PROCESSED_AT_THE_MOMENT"}`, true, false, true, nil, CodeCannotProcessNow},
		{"500", 500, `{"timestamp":"x","status":500,"error":"Internal Server Error","path":"/pay"}`, true, false, true, nil, ""},
		{"502 page", 502, `<html>bad gateway</html>`, true, false, false, nil, ""},
		{"400 page", 400, `<html>bad request</html>`, true, false, false, nil, ""},
		{"empty 400", 400, ``, true, false, false, nil, ""},
		{"429 page", 429, `slow down`, true, true, false, ErrRateLimited, ""},
		{"408", 408, `{"message":"timeout"}`, true, false, true, nil, ""},
		{"redirect", 302, ``, true, false, false, nil, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := error(newAPIError("giftcards", "order gift card", test.status, http.Header{}, []byte(test.body), test.sent))
			var api *APIError
			errors.As(err, &api)
			if Definite(err) != test.definite {
				t.Errorf("Definite = %t, want %t", Definite(err), test.definite)
			}
			if api.Structured() != test.structured {
				t.Errorf("Structured = %t, want %t", api.Structured(), test.structured)
			}
			if api.Code != test.code {
				t.Errorf("Code = %q, want %q", api.Code, test.code)
			}
			if test.is != nil && !errors.Is(err, test.is) {
				t.Errorf("err does not unwrap to %v", test.is)
			}
			if test.is == nil && errors.Unwrap(err) != nil {
				t.Errorf("err unwraps to %v", errors.Unwrap(err))
			}
			if (test.is == ErrDuplicateIdentifier) != IsDuplicateIdentifier(err) {
				t.Errorf("IsDuplicateIdentifier = %t", IsDuplicateIdentifier(err))
			}
			if (test.is == ErrInsufficientBalance) != IsInsufficientBalance(err) {
				t.Errorf("IsInsufficientBalance = %t", IsInsufficientBalance(err))
			}
			if (test.is == ErrNotFound) != IsNotFound(err) {
				t.Errorf("IsNotFound = %t", IsNotFound(err))
			}
			if api.Message == "" {
				t.Error("no message")
			}
		})
	}
	if Definite(nil) {
		t.Fatal("no error is not a definite failure")
	}
	if !Definite(errors.New("local")) || !Definite(fmt.Errorf("%w: x", ErrInvalidRequest)) {
		t.Fatal("errors raised before any request are definite")
	}
}

func TestAnErrorBodyKeepsReloadlysWords(t *testing.T) {
	body := `{"timeStamp":"2026-10-08 01:45:03","message":"Min and max (local) amounts for operator id 640 (Airtel Niger) are : 100.00 XOF and 50000.00 XOF","path":"/topups","errorCode":"INVALID_LOCAL_AMOUNT_FOR_OPERATOR","infoLink":null,"details":["a",{"b":1}]}`
	err := newAPIError("topups", "make top-up", 400, http.Header{}, []byte(body), true)
	if err.Code != CodeInvalidLocalAmount || !strings.Contains(err.Message, "Airtel Niger") || len(err.Details) != 2 ||
		err.Details[0] != "a" {
		t.Fatalf("err = %+v", err)
	}
	text := err.Error()
	for _, part := range []string{"topups", "make top-up", "HTTP 400", "INVALID_LOCAL_AMOUNT_FOR_OPERATOR", "Airtel Niger"} {
		if !strings.Contains(text, part) {
			t.Errorf("Error() = %q lacks %q", text, part)
		}
	}
	long := newAPIError("topups", "x", 500, http.Header{}, []byte(strings.Repeat("é", 5000)), true)
	if n := len([]rune(long.Body)); n > maxBodyKept+1 {
		t.Fatalf("the kept body has %d characters", n)
	}
}
