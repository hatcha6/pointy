// Package dafa is the relay's client for Dafa (dafa.ly), the payment gateway
// shops top up their Daftar wallet through. One API covers every Libyan
// payment method: the relay starts a payment, and the payer either confirms it
// with the code their provider texted them or, for local bank cards, pays on
// Dafa's hosted page. The API key lives only on the relay, like the Resala
// token: the company owns the Dafa workspace and every shop's money lands in
// it, so a shop never holds a credential it could charge or forge a payment
// with.
//
// What the relay believes. A payment Dafa reports as paid in answer to a call
// the relay made with its own key is proof: the confirm it sent, or the
// payment read back. Dafa's webhook is not — it carries no signature — so it
// is only ever a reason to read the payment back.
//
// Read against the live test API (2026-10-01), where it differs from the docs:
//   - Bodies are JSON. The documented form encoding is refused
//     ("[user_identifier] required"); multipart fails to decode.
//   - amount is a string with at most three decimals (the dinar's dirhams);
//     answers carry it again as amount_str ("10.000"). birthyear must be a
//     JSON string, not a number.
//   - GET /payments/{id} reads a payment back. It is not in the docs, but the
//     key is scoped to /payments, so it is the API, not an accident.
//   - Confirming a payment that is already paid answers 200 is_paid again, so
//     a confirm retried after a lost answer cannot pay twice.
//   - A decline is not final there: a payment declined with a non-retryable
//     code still took a later confirm. The relay treats its own verdict as
//     the record and credits a proven payment whatever it believed before.
package dafa

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// DefaultBaseURL is the API the docs and the test keys use. The Integration
// page of the company's Dafa project names the one to use; it is configurable.
const DefaultBaseURL = "https://dev.dafa.ly/api/v1"

// Keys carry their environment in their prefix. A test key only ever creates
// simulated payments, and cannot read or confirm a live one.
const (
	TestKeyPrefix = "dafa_test_"
	LiveKeyPrefix = "dafa_live_"
)

const (
	defaultTimeout = 20 * time.Second
	// Bodies are small JSON documents; the cap only stops a misbehaving proxy
	// from streaming something unbounded into memory.
	maxResponseBytes = 1 << 20
	maxErrorMessage  = 500
)

// KeyEnvironment reads a key's environment from its prefix. known is false
// for a key with neither prefix: the relay will not guess whether its money
// is real.
func KeyEnvironment(apiKey string) (test bool, known bool) {
	key := strings.TrimSpace(apiKey)
	switch {
	case strings.HasPrefix(key, TestKeyPrefix):
		return true, true
	case strings.HasPrefix(key, LiveKeyPrefix):
		return false, true
	}
	return false, false
}

// Config is how the relay reaches Dafa.
type Config struct {
	BaseURL string
	APIKey  string
	// HTTPClient is shared so connections are reused. Nil builds a private
	// client. Timeout applies per call either way.
	HTTPClient *http.Client
	Timeout    time.Duration
}

// Client talks to the Dafa API.
type Client struct {
	baseURL string
	apiKey  string
	http    *http.Client
	timeout time.Duration
}

// New builds a client. It never fails: a missing key surfaces as Dafa's 401
// on the first call, the same way a revoked one would.
func New(config Config) *Client {
	baseURL := strings.TrimRight(strings.TrimSpace(config.BaseURL), "/")
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	timeout := config.Timeout
	if timeout <= 0 {
		timeout = defaultTimeout
	}
	var httpClient http.Client
	if config.HTTPClient != nil {
		httpClient = *config.HTTPClient
	} else {
		httpClient = http.Client{Timeout: timeout}
	}
	// Never follow a redirect: Go forwards custom headers across hosts, and
	// X-API-Key is the company's money. Dafa's API has no reason to redirect.
	httpClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &Client{
		baseURL: baseURL,
		apiKey:  strings.TrimSpace(config.APIKey),
		http:    &httpClient,
		timeout: timeout,
	}
}

// InitiateRequest starts a payment.
type InitiateRequest struct {
	// Provider is the payment method, e.g. "sadad" (see Providers).
	Provider string
	// Amount is in dinars with at most three decimals ("25", "25.5", "25.500").
	Amount string
	// UserIdentifier is the payer's phone or wallet card number; bank cards
	// take none.
	UserIdentifier string
	// BirthYear is Sadad's second factor.
	BirthYear string
	// CallbackURL receives Dafa's webhook when the payment completes.
	CallbackURL string
}

// Payment is Dafa's view of one payment.
type Payment struct {
	ID string
	// Amount is the decimal Dafa wrote, amount_str when it sent one.
	Amount string
	IsPaid bool
	// PaymentPageURL is where a bank-card payer pays; empty for OTP methods.
	PaymentPageURL string
	CallbackURL    string
	CreatedAt      time.Time
	// Gateway is the channel the payment went through ("sadad", "moamalat").
	Gateway string
	// TestWorkspace is the answer's workspace.is_test; WorkspaceKnown says
	// whether the answer carried it at all.
	TestWorkspace  bool
	WorkspaceKnown bool
	// LastError is the latest failed attempt on this payment, if any.
	LastError *PaymentError
}

// PaymentError is a failed attempt recorded on a payment.
type PaymentError struct {
	Code            string
	Fault           string
	ProviderMessage string
	OccurredAt      time.Time
}

// APIError is Dafa answering with an error.
type APIError struct {
	// Status is the HTTP status.
	Status int
	// Type is Dafa's class of error: BadRequest, InputValidation, NotFound...
	Type string
	// Message is Dafa's sentence. For a payer's failure it is Arabic and
	// written for the payer ("رمز التحقق غير صحيح، يرجى إعادة إدخاله.").
	Message string
	// Code is the machine code of a failed payment: PAYER_OTP_WRONG,
	// PAYER_INSUFFICIENT_FUNDS, ... Empty for errors that are not about the
	// payment (validation, authentication).
	Code string
	// Fault says whose problem it is: "payer" for the payer's data or bank.
	Fault string
	// Retryable says the same payment may still succeed: a wrong code can be
	// typed again, a decline cannot.
	Retryable       bool
	Hint            string
	MerchantMessage string
	ProviderMessage string
	// Fields is the per-field validation answer: {"user_identifier": ["required"]}.
	Fields map[string][]string
}

func (e *APIError) Error() string {
	if e.Code != "" {
		return fmt.Sprintf("dafa: %d %s: %s", e.Status, e.Code, e.Message)
	}
	return fmt.Sprintf("dafa: %d: %s", e.Status, e.Message)
}

// TransportError means the request never got a readable answer. For a confirm
// the outcome is unknown: Dafa may have taken the payment before the answer
// was lost, so the caller reads the payment back before deciding anything.
type TransportError struct {
	Err error
}

func (e *TransportError) Error() string { return "dafa: " + e.Err.Error() }
func (e *TransportError) Unwrap() error { return e.Err }

// Timeout reports whether the call ran out of time rather than failing fast.
func (e *TransportError) Timeout() bool {
	var timeout interface{ Timeout() bool }
	return errors.As(e.Err, &timeout) && timeout.Timeout() || errors.Is(e.Err, context.DeadlineExceeded)
}

type initiateBody struct {
	Provider       string `json:"provider"`
	Amount         string `json:"amount"`
	UserIdentifier string `json:"user_identifier,omitempty"`
	BirthYear      string `json:"birthyear,omitempty"`
	CallbackURL    string `json:"callback_url,omitempty"`
}

// Initiate starts a payment. For an OTP method the provider texts the payer a
// code; for bank cards the answer carries the page the payer pays on. It is
// never retried: a second call would start a second payment.
func (c *Client) Initiate(ctx context.Context, request InitiateRequest) (Payment, error) {
	body := initiateBody{
		Provider:       strings.TrimSpace(request.Provider),
		Amount:         strings.TrimSpace(request.Amount),
		UserIdentifier: strings.TrimSpace(request.UserIdentifier),
		BirthYear:      strings.TrimSpace(request.BirthYear),
		CallbackURL:    strings.TrimSpace(request.CallbackURL),
	}
	return c.call(ctx, http.MethodPost, "/payments/initiate", body)
}

// Confirm sends the code the payer received. Confirming a paid payment
// answers paid again, so a retry after a lost answer is safe.
func (c *Client) Confirm(ctx context.Context, paymentID, otp string) (Payment, error) {
	id := strings.TrimSpace(paymentID)
	if id == "" {
		return Payment{}, &APIError{Status: http.StatusBadRequest, Message: "no payment id to confirm"}
	}
	return c.call(ctx, http.MethodPost, "/payments/"+url.PathEscape(id)+"/confirm",
		map[string]string{"otp": strings.TrimSpace(otp)})
}

// Payment reads a payment back: the relay's proof that a bank-card payment
// (or a confirm whose answer was lost) went through.
func (c *Client) Payment(ctx context.Context, paymentID string) (Payment, error) {
	id := strings.TrimSpace(paymentID)
	if id == "" {
		return Payment{}, &APIError{Status: http.StatusBadRequest, Message: "no payment id to read"}
	}
	return c.call(ctx, http.MethodGet, "/payments/"+url.PathEscape(id), nil)
}

func (c *Client) call(ctx context.Context, method, path string, payload any) (Payment, error) {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	var reader io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return Payment{}, &TransportError{Err: err}
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, reader)
	if err != nil {
		return Payment{}, &TransportError{Err: err}
	}
	if payload != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("X-API-Key", c.apiKey)
	response, err := c.http.Do(request)
	if err != nil {
		return Payment{}, &TransportError{Err: err}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return Payment{}, &TransportError{Err: err}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return Payment{}, decodeAPIError(response.StatusCode, body)
	}
	payment, err := ParsePayment(body)
	if err != nil {
		return Payment{}, &APIError{Status: response.StatusCode, Message: "unreadable payment: " + err.Error()}
	}
	return payment, nil
}

type paymentBody struct {
	ID             string          `json:"id"`
	Amount         json.RawMessage `json:"amount"`
	AmountStr      string          `json:"amount_str"`
	IsPaid         bool            `json:"is_paid"`
	PaymentPageURL *string         `json:"payment_page_url"`
	CallbackURL    *string         `json:"callback_url"`
	CreatedAt      string          `json:"created_at"`
	Gateway        *struct {
		Name string `json:"name"`
	} `json:"gateway"`
	Workspace *struct {
		IsTest *bool `json:"is_test"`
	} `json:"workspace"`
	LastError *struct {
		Code            string `json:"code"`
		Fault           string `json:"fault"`
		ProviderMessage string `json:"provider_message"`
		OccurredAt      string `json:"occurred_at"`
	} `json:"last_error"`
}

// ParsePayment reads a payment as Dafa writes it — in answers, and in the
// webhook it posts, which has the same shape.
func ParsePayment(body []byte) (Payment, error) {
	var decoded paymentBody
	if err := json.Unmarshal(body, &decoded); err != nil {
		return Payment{}, err
	}
	payment := Payment{
		ID:     strings.TrimSpace(decoded.ID),
		Amount: strings.TrimSpace(decoded.AmountStr),
		IsPaid: decoded.IsPaid,
	}
	if payment.ID == "" {
		return Payment{}, errors.New("payment has no id")
	}
	if payment.Amount == "" {
		payment.Amount = strings.Trim(strings.TrimSpace(string(decoded.Amount)), `"`)
	}
	if decoded.PaymentPageURL != nil {
		payment.PaymentPageURL = strings.TrimSpace(*decoded.PaymentPageURL)
	}
	if decoded.CallbackURL != nil {
		payment.CallbackURL = strings.TrimSpace(*decoded.CallbackURL)
	}
	if at, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(decoded.CreatedAt)); err == nil {
		payment.CreatedAt = at.UTC()
	}
	if decoded.Gateway != nil {
		payment.Gateway = strings.TrimSpace(decoded.Gateway.Name)
	}
	if decoded.Workspace != nil && decoded.Workspace.IsTest != nil {
		payment.TestWorkspace = *decoded.Workspace.IsTest
		payment.WorkspaceKnown = true
	}
	if decoded.LastError != nil && strings.TrimSpace(decoded.LastError.Code) != "" {
		lastError := &PaymentError{
			Code:            strings.TrimSpace(decoded.LastError.Code),
			Fault:           strings.TrimSpace(decoded.LastError.Fault),
			ProviderMessage: truncate(strings.TrimSpace(decoded.LastError.ProviderMessage), maxErrorMessage),
		}
		if at, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(decoded.LastError.OccurredAt)); err == nil {
			lastError.OccurredAt = at.UTC()
		}
		payment.LastError = lastError
	}
	return payment, nil
}

// UsablePaymentPage accepts only an absolute https page: the shop's app opens
// it in a browser, and anything else is either broken or not Dafa's. The host
// is not pinned — the test checkout lives on another domain than the docs show.
func UsablePaymentPage(raw string) bool {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	return err == nil && parsed.Scheme == "https" && parsed.Host != "" && parsed.User == nil
}

// decodeAPIError reads Dafa's error envelope:
//
//	{"status":400,"type":"BadRequest","message":"…",
//	 "data":{"code":"PAYER_OTP_WRONG","fault":"payer","retryable":true,…},
//	 "errors":{"user_identifier":["required"]}}
func decodeAPIError(status int, body []byte) *APIError {
	var envelope struct {
		Type    string              `json:"type"`
		Message string              `json:"message"`
		Errors  map[string][]string `json:"errors"`
		Data    *struct {
			Code            string `json:"code"`
			Fault           string `json:"fault"`
			Retryable       bool   `json:"retryable"`
			MerchantMessage string `json:"merchant_message"`
			Hint            string `json:"hint"`
			ProviderMessage string `json:"provider_message"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return &APIError{Status: status, Message: truncate(strings.TrimSpace(string(body)), maxErrorMessage)}
	}
	apiErr := &APIError{
		Status:  status,
		Type:    strings.TrimSpace(envelope.Type),
		Message: truncate(strings.TrimSpace(envelope.Message), maxErrorMessage),
		Fields:  envelope.Errors,
	}
	if data := envelope.Data; data != nil {
		apiErr.Code = strings.TrimSpace(data.Code)
		apiErr.Fault = strings.TrimSpace(data.Fault)
		apiErr.Retryable = data.Retryable
		apiErr.MerchantMessage = truncate(strings.TrimSpace(data.MerchantMessage), maxErrorMessage)
		apiErr.Hint = truncate(strings.TrimSpace(data.Hint), maxErrorMessage)
		apiErr.ProviderMessage = truncate(strings.TrimSpace(data.ProviderMessage), maxErrorMessage)
	}
	return apiErr
}

// FieldProblem returns the first problem Dafa reported with field, if any.
func (e *APIError) FieldProblem(field string) (string, bool) {
	problems, ok := e.Fields[field]
	if !ok {
		return "", false
	}
	if len(problems) == 0 {
		return "", true
	}
	return problems[0], true
}

func truncate(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}
