package reloadly

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Error codes Reloadly answers in the "errorCode" field. Only codes seen
// against the sandbox are listed (see the package comment); a code not listed
// here is still carried verbatim in APIError.Code. Gift card answers often have
// a null code and are told apart by Message instead.
const (
	CodeInvalidToken       = "INVALID_TOKEN"
	CodeMissingToken       = "MISSING_TOKEN"
	CodeInvalidCredentials = "INVALID_CREDENTIALS"
	CodeInvalidAudience    = "INVALID_AUDIENCE"
	// CodeInvalidInput is the catch-all 400 ("Missing required field amount",
	// "Maximum length allowed for field customIdentifier is 150").
	CodeInvalidInput = "INVALID_INPUT_PROVIDED"

	// CodeDuplicateCustomIdentifier answers a gift card order or a top-up whose
	// customIdentifier was already used by an accepted request (HTTP 400).
	CodeDuplicateCustomIdentifier = "CUSTOM_IDENTIFIER_ALREADY_USED"
	// CodeDuplicateReference answers a utility payment whose referenceId was
	// already used by an accepted request, even a refunded one (HTTP 400).
	CodeDuplicateReference = "REFERENCE_ID_ALREADY_USED"

	// CodeInsufficientBalance is a top-up the company's balance cannot pay
	// (HTTP 400); utilities answer CodeInsufficientWalletBalance with HTTP 409.
	CodeInsufficientBalance       = "INSUFFICIENT_BALANCE"
	CodeInsufficientWalletBalance = "INSUFFICIENT_WALLET_BALANCE"

	CodeWrongProductPrice        = "WRONG_PRODUCT_PRICE"
	CodeInvalidProduct           = "INVALID_PRODUCT"
	CodeInvalidLocalAmount       = "INVALID_LOCAL_AMOUNT_FOR_OPERATOR"
	CodeLocalAmountsNotSupported = "LOCAL_AMOUNTS_NOT_SUPPORTED_BY_OPERATOR"
	CodeInvalidRecipientPhone    = "INVALID_RECIPIENT_PHONE"
	CodeOperatorPhoneMismatch    = "OPERATOR_AND_RECIPIENT_PHONE_MISMATCH"
	CodeCouldNotAutoDetect       = "COULD_NOT_AUTO_DETECT_OPERATOR"
	CodeCountryNotSupported      = "COUNTRY_NOT_SUPPORTED"
	CodeInvalidAmount            = "INVALID_AMOUNT"
	CodeInvalidBillerID          = "INVALID_BILLER_ID"
	CodeMissingAmountID          = "MISSING_REQUIRED_AMOUNT_ID"
	CodeAmountIDNotFound         = "AMOUNT_ID_NOT_FOUND"
	CodeTransactionNotFound      = "TRANSACTION_NOT_FOUND"

	// CodeOperatorUnavailable is HTTP 503 and is raised before anything is
	// attempted: see Definite.
	CodeOperatorUnavailable = "OPERATOR_UNAVAILABLE_OR_CURRENTLY_INACTIVE"
	// CodeCannotProcessNow is "try again later". Reloadly answers it as HTTP 400
	// (after a slow operator attempt, ~50 s) and as HTTP 500 (a concurrent
	// duplicate of a utility payment). No transaction is recorded in either case.
	CodeCannotProcessNow = "TRANSACTION_CANNOT_BE_PROCESSED_AT_THE_MOMENT"
)

var (
	// ErrInvalidRequest wraps arguments rejected before any request was made;
	// the error is always Definite.
	ErrInvalidRequest = errors.New("reloadly: invalid request")
	// ErrUnauthorized is Reloadly refusing the credentials or the token (HTTP
	// 401/403, INVALID_TOKEN, INVALID_CREDENTIALS). Sandbox keys are refused by
	// live hosts and live keys by sandbox hosts.
	ErrUnauthorized = errors.New("reloadly: unauthorized")
	// ErrInsufficientBalance is the company's USD balance at Reloadly not
	// covering the purchase.
	ErrInsufficientBalance = errors.New("reloadly: insufficient balance")
	// ErrDuplicateIdentifier is a customIdentifier or referenceId that an
	// earlier accepted request already used. The earlier transaction exists:
	// read it back with the Find* method of the product.
	ErrDuplicateIdentifier = errors.New("reloadly: identifier already used")
	// ErrNotFound is HTTP 404: an unknown transaction, operator or path.
	ErrNotFound = errors.New("reloadly: not found")
	// ErrRateLimited is HTTP 429.
	ErrRateLimited = errors.New("reloadly: rate limited")
	// ErrOperatorUnavailable is an operator Reloadly has switched off.
	ErrOperatorUnavailable = errors.New("reloadly: operator unavailable")
)

// maxBodyKept bounds the response text an error carries into logs.
const maxBodyKept = 1000

// APIError is Reloadly (or the token service) answering with an HTTP error.
//
// Message and Code come from Reloadly's JSON error body
// ({"timeStamp","message","path","errorCode","infoLink","details"}); the Spring
// 404/500 form ({"timestamp","status","error","path"}) and the token service's
// {"error","error_description"} form are read too. When the body is not JSON at
// all (a proxy's HTML page) Message is a slice of the text and Structured is
// false.
type APIError struct {
	// Product is "giftcards", "topups", "utilities" or "auth" (the token
	// service, which is asked before any product call).
	Product string
	// Op names the operation in words ("make top-up").
	Op string
	// Status is the HTTP status.
	Status int
	// Code is Reloadly's errorCode, empty when the answer had none.
	Code string
	// Message is Reloadly's sentence.
	Message string
	// Details are the entries of the "details" array, as text.
	Details []string
	// Body is the response text, truncated.
	Body string
	// RequestSent is whether the product request had been written when this
	// answer came. It is false for token failures: nothing was asked yet.
	RequestSent bool
	// RetryAfter is the Retry-After header (429/503), zero when absent.
	RetryAfter time.Duration

	structured bool
	cause      error
}

// Structured is whether the body was Reloadly's JSON error, which is what makes
// a 4xx a proof that the request was refused.
func (e *APIError) Structured() bool { return e.structured }

// Error implements error. It never includes credentials or the request body.
func (e *APIError) Error() string {
	var b strings.Builder
	b.WriteString("reloadly: ")
	if e.Product != "" {
		b.WriteString(e.Product + ": ")
	}
	if e.Op != "" {
		b.WriteString(e.Op + ": ")
	}
	fmt.Fprintf(&b, "HTTP %d", e.Status)
	if e.Code != "" {
		b.WriteString(" " + e.Code)
	}
	if e.Message != "" {
		b.WriteString(": " + e.Message)
	}
	return b.String()
}

// Unwrap exposes the sentinel that matches the answer (ErrUnauthorized,
// ErrInsufficientBalance, ErrDuplicateIdentifier, ErrNotFound, ErrRateLimited,
// ErrOperatorUnavailable), if any.
func (e *APIError) Unwrap() error { return e.cause }

// TransportError is a call that never produced an HTTP answer, or whose answer
// could not be read: a network failure, a timeout, a cancelled context, a body
// that is cut off or not the JSON the endpoint documents.
type TransportError struct {
	Product string
	Op      string
	Err     error
	// Sent is whether the whole product request had been written before the
	// failure. A request that was never sent cannot have done anything; one that
	// was sent may have, whatever the error says. An unreadable 2xx answer is
	// always Sent.
	Sent bool
}

// Error implements error.
func (e *TransportError) Error() string {
	where := e.Op
	if e.Product != "" {
		where = e.Product + ": " + e.Op
	}
	return "reloadly: " + where + ": " + e.Err.Error()
}

// Unwrap returns the underlying error (net/url.Error, context.DeadlineExceeded…).
func (e *TransportError) Unwrap() error { return e.Err }

// definiteServerCodes are the few 5xx answers Reloadly raises before it
// attempts anything. Every other 5xx may have happened after the money moved.
var definiteServerCodes = map[string]bool{
	CodeOperatorUnavailable: true,
}

// Definite is whether a failed purchase (OrderGiftCard, Topup, TopupAsync, Pay)
// proves that nothing was bought, so the shop's money can be returned at once.
//
// It is true when the request provably never left (bad arguments, no token, a
// refused connection, a context ended before the request was written), and when
// Reloadly answered that it refuses the request: a 401 (the token was refused
// before anything ran), a 429, or a 4xx whose body is Reloadly's JSON error. A
// 5xx is not definite, except the few codes listed in definiteServerCodes.
//
// It is false for everything that leaves it open: a timeout or a dropped
// connection after the request was written, a 5xx, a 4xx that is not Reloadly's
// JSON (a proxy's page), and an unreadable 2xx. Those must be read back with the
// product's Find* method (by the customIdentifier / referenceId, which Reloadly
// records for every accepted request) before the money is given back.
//
// A reused identifier after a lost answer is not a retry: Reloadly's duplicate
// check is not atomic, see the package comment.
func Definite(err error) bool {
	if err == nil {
		return false
	}
	var transport *TransportError
	if errors.As(err, &transport) {
		return !transport.Sent
	}
	var api *APIError
	if errors.As(err, &api) {
		return api.definite()
	}
	// Anything else was raised locally before a request was made.
	return true
}

func (e *APIError) definite() bool {
	if !e.RequestSent {
		return true
	}
	switch {
	case e.Status == http.StatusUnauthorized, e.Status == http.StatusTooManyRequests:
		return true
	case e.Status == http.StatusRequestTimeout:
		return false
	case e.Status >= 400 && e.Status < 500:
		return e.structured
	case e.Status >= 500:
		return e.structured && definiteServerCodes[e.Code]
	}
	return false
}

// IsDuplicateIdentifier is whether Reloadly refused a request because its
// customIdentifier (gift cards, top-ups) or referenceId (utilities) was already
// used by an accepted request: the earlier transaction exists.
func IsDuplicateIdentifier(err error) bool { return errors.Is(err, ErrDuplicateIdentifier) }

// IsInsufficientBalance is whether the company's balance at Reloadly could not
// pay the purchase.
func IsInsufficientBalance(err error) bool { return errors.Is(err, ErrInsufficientBalance) }

// IsNotFound is whether Reloadly answered 404 (an unknown transaction id, for
// instance).
func IsNotFound(err error) bool { return errors.Is(err, ErrNotFound) }

// IsUnauthorized is whether Reloadly refused the credentials or the token.
func IsUnauthorized(err error) bool { return errors.Is(err, ErrUnauthorized) }

// classify picks the sentinel an answer unwraps to.
func classify(status int, code, message string) error {
	upper := strings.ToUpper(code)
	switch {
	case status == http.StatusUnauthorized, status == http.StatusForbidden,
		upper == CodeInvalidToken, upper == CodeMissingToken, upper == CodeInvalidCredentials:
		return ErrUnauthorized
	case upper == CodeDuplicateCustomIdentifier, upper == CodeDuplicateReference,
		status == http.StatusBadRequest && strings.Contains(strings.ToLower(message), "has already been used"):
		return ErrDuplicateIdentifier
	case upper == CodeInsufficientBalance, upper == CodeInsufficientWalletBalance, looksInsufficient(message):
		return ErrInsufficientBalance
	case upper == CodeOperatorUnavailable:
		return ErrOperatorUnavailable
	case status == http.StatusNotFound:
		return ErrNotFound
	case status == http.StatusTooManyRequests:
		return ErrRateLimited
	}
	return nil
}

func looksInsufficient(message string) bool {
	lowered := strings.ToLower(message)
	if !strings.Contains(lowered, "insufficient") {
		return false
	}
	return strings.Contains(lowered, "balance") || strings.Contains(lowered, "fund") || strings.Contains(lowered, "wallet")
}

// newAPIError reads an error response.
func newAPIError(product, op string, status int, header http.Header, body []byte, sent bool) *APIError {
	apiErr := &APIError{
		Product:     product,
		Op:          op,
		Status:      status,
		Body:        truncate(strings.TrimSpace(string(body)), maxBodyKept),
		RequestSent: sent,
		RetryAfter:  parseRetryAfter(header.Get("Retry-After")),
	}
	var wire struct {
		Message          string          `json:"message"`
		ErrorCode        string          `json:"errorCode"`
		Error            json.RawMessage `json:"error"`
		ErrorDescription string          `json:"error_description"`
		Details          json.RawMessage `json:"details"`
	}
	if err := json.Unmarshal(body, &wire); err == nil {
		apiErr.Code = strings.TrimSpace(wire.ErrorCode)
		apiErr.Message = strings.TrimSpace(wire.Message)
		spring := rawText(wire.Error)
		if apiErr.Message == "" {
			apiErr.Message = strings.TrimSpace(wire.ErrorDescription)
		}
		if apiErr.Message == "" {
			apiErr.Message = spring
		}
		if apiErr.Code == "" && wire.ErrorDescription != "" {
			// The token service's {"error": "access_denied", ...} form.
			apiErr.Code = strings.ToUpper(spring)
		}
		apiErr.Details = detailTexts(wire.Details)
		apiErr.structured = apiErr.Code != "" || apiErr.Message != "" || spring != ""
	}
	if apiErr.Message == "" {
		apiErr.Message = truncate(strings.TrimSpace(string(body)), 200)
	}
	if apiErr.Message == "" {
		apiErr.Message = http.StatusText(status)
	}
	apiErr.cause = classify(status, apiErr.Code, apiErr.Message)
	return apiErr
}

func rawText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return strings.TrimSpace(text)
	}
	if string(raw) == "null" {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

func detailTexts(raw json.RawMessage) []string {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var list []json.RawMessage
	if err := json.Unmarshal(raw, &list); err != nil {
		if text := rawText(raw); text != "" {
			return []string{text}
		}
		return nil
	}
	out := make([]string, 0, len(list))
	for _, item := range list {
		if text := rawText(item); text != "" {
			out = append(out, text)
		}
	}
	return out
}

func parseRetryAfter(value string) time.Duration {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	if seconds, err := strconv.Atoi(value); err == nil && seconds >= 0 {
		return time.Duration(seconds) * time.Second
	}
	if at, err := http.ParseTime(value); err == nil {
		if wait := time.Until(at); wait > 0 {
			return wait
		}
	}
	return 0
}
