// Package plutu is the relay's client for Plutu (plutu.ly), the Libyan payment
// gateway shops top up their Daftar wallet through. The API key, the access
// token and the secret key live only on the relay, like the Resala token: the
// company owns the merchant account and every shop's money lands in it, so a
// shop never holds a credential it could charge or forge a payment with.
//
// Only local bank cards are wired. That gateway is a hosted checkout: the
// relay asks for a checkout page, the shop owner pays on it, and Plutu sends
// the owner's browser back to the relay's return URL with the outcome in a
// signed query string. There is no server-to-server callback and no status
// API, so the signed return is the only proof of payment the relay ever gets.
package plutu

import (
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

// DefaultBaseURL is Plutu's API. Test and live share it: the access token
// decides which mode a request runs in.
const DefaultBaseURL = "https://api.plutus.ly/api/v1"

// GatewayLocalBankCards is the local bank card gateway (the Numo network).
const GatewayLocalBankCards = "localbankcards"

const (
	defaultTimeout = 20 * time.Second
	// Bodies are small JSON documents; the cap only stops a misbehaving proxy
	// from streaming something unbounded into memory.
	maxResponseBytes = 1 << 20
	maxErrorMessage  = 500
)

// Config is how the relay reaches Plutu.
type Config struct {
	BaseURL     string
	APIKey      string
	AccessToken string
	// SecretKey signs the return query string. It never leaves the relay and
	// is not sent to Plutu; it only verifies what Plutu sends back.
	SecretKey string
	// HTTPClient is shared so connections are reused. Nil builds a private
	// client. Timeout applies per call either way.
	HTTPClient *http.Client
	Timeout    time.Duration
}

// Client talks to the Plutu API.
type Client struct {
	baseURL     string
	apiKey      string
	accessToken string
	http        *http.Client
	timeout     time.Duration
}

// New builds a client. It never fails: missing credentials surface as Plutu's
// UNAUTHORIZED on the first call, the same way revoked ones would.
func New(config Config) *Client {
	baseURL := strings.TrimRight(strings.TrimSpace(config.BaseURL), "/")
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	timeout := config.Timeout
	if timeout <= 0 {
		timeout = defaultTimeout
	}
	httpClient := config.HTTPClient
	if httpClient == nil {
		httpClient = &http.Client{Timeout: timeout}
	}
	return &Client{
		baseURL:     baseURL,
		apiKey:      strings.TrimSpace(config.APIKey),
		accessToken: strings.TrimSpace(config.AccessToken),
		http:        httpClient,
		timeout:     timeout,
	}
}

// CheckoutRequest asks for a hosted local-bank-card checkout.
type CheckoutRequest struct {
	// Amount is in dinars with at most two decimals ("25", "25.5", "25.50").
	Amount string
	// InvoiceNo must be unique across the merchant account, test and live.
	InvoiceNo string
	// ReturnURL is where Plutu sends the payer's browser when the payment
	// completes or is cancelled.
	ReturnURL  string
	CustomerIP string
	// Lang is "ar" or "en"; Plutu defaults to Arabic.
	Lang string
}

// Checkout is the page the payer is sent to.
type Checkout struct {
	Code        string
	RedirectURL string
}

// APIError is Plutu answering with an error. Code is Plutu's machine code
// (UNAUTHORIZED, AMOUNT_EXCEEDED_MAXIMUM, ...), empty when the body had none.
type APIError struct {
	Status  int
	Code    string
	Message string
}

func (e *APIError) Error() string {
	if e.Code != "" {
		return fmt.Sprintf("plutu: %d %s: %s", e.Status, e.Code, e.Message)
	}
	return fmt.Sprintf("plutu: %d: %s", e.Status, e.Message)
}

// TransportError means the request never got a readable answer. For a
// checkout that is harmless: nobody saw the page, so nobody can have paid.
type TransportError struct {
	Err error
}

func (e *TransportError) Error() string { return "plutu: " + e.Err.Error() }
func (e *TransportError) Unwrap() error { return e.Err }

// Timeout reports whether the call ran out of time rather than failing fast.
func (e *TransportError) Timeout() bool {
	var timeout interface{ Timeout() bool }
	return errors.As(e.Err, &timeout) && timeout.Timeout() || errors.Is(e.Err, context.DeadlineExceeded)
}

// ConfirmLocalBankCards creates a local-bank-card checkout and returns the page
// to send the payer to. It is never retried: a retry would reuse the invoice
// number, which Plutu refuses, and a checkout nobody opened costs nothing.
func (c *Client) ConfirmLocalBankCards(ctx context.Context, request CheckoutRequest) (Checkout, error) {
	form := url.Values{}
	form.Set("amount", strings.TrimSpace(request.Amount))
	form.Set("invoice_no", strings.TrimSpace(request.InvoiceNo))
	form.Set("return_url", strings.TrimSpace(request.ReturnURL))
	if ip := strings.TrimSpace(request.CustomerIP); ip != "" {
		form.Set("customer_ip", ip)
	}
	if lang := strings.TrimSpace(request.Lang); lang != "" {
		form.Set("lang", lang)
	}
	body, err := c.post(ctx, "/transaction/"+GatewayLocalBankCards+"/confirm", form)
	if err != nil {
		return Checkout{}, err
	}
	var decoded struct {
		Result struct {
			Code        string `json:"code"`
			RedirectURL string `json:"redirect_url"`
		} `json:"result"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		return Checkout{}, &APIError{Status: http.StatusOK, Message: "unreadable checkout response"}
	}
	checkout := Checkout{
		Code:        strings.TrimSpace(decoded.Result.Code),
		RedirectURL: strings.TrimSpace(decoded.Result.RedirectURL),
	}
	if !usableRedirect(checkout.RedirectURL) {
		return Checkout{}, &APIError{Status: http.StatusOK, Code: checkout.Code, Message: "checkout response carried no usable redirect_url"}
	}
	return checkout, nil
}

// usableRedirect accepts only an absolute https page: the shop's app opens it
// in a browser, and anything else is either broken or not Plutu's.
func usableRedirect(raw string) bool {
	parsed, err := url.Parse(raw)
	return err == nil && parsed.Scheme == "https" && parsed.Host != ""
}

func (c *Client) post(ctx context.Context, path string, form url.Values) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, &TransportError{Err: err}
	}
	// The same form encoding Plutu's own SDK sends (Guzzle form_params).
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("X-API-KEY", c.apiKey)
	request.Header.Set("Authorization", "Bearer "+c.accessToken)
	response, err := c.http.Do(request)
	if err != nil {
		return nil, &TransportError{Err: err}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return nil, &TransportError{Err: err}
	}
	if response.StatusCode >= 200 && response.StatusCode < 300 {
		// Plutu reports some failures inside a 200 body.
		if apiErr := decodeAPIError(response.StatusCode, body); apiErr != nil && apiErr.Code != "" {
			return nil, apiErr
		}
		return body, nil
	}
	if apiErr := decodeAPIError(response.StatusCode, body); apiErr != nil {
		return nil, apiErr
	}
	return nil, &APIError{Status: response.StatusCode, Message: truncate(strings.TrimSpace(string(body)), maxErrorMessage)}
}

// decodeAPIError reads Plutu's error envelope, {"error":{"status","code",
// "message"}}, and Laravel's validation shape, {"message","errors"}. It
// returns nil when the body is neither.
func decodeAPIError(status int, body []byte) *APIError {
	var envelope struct {
		Error *struct {
			Status  json.Number `json:"status"`
			Code    string      `json:"code"`
			Message string      `json:"message"`
		} `json:"error"`
		Message string              `json:"message"`
		Errors  map[string][]string `json:"errors"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return nil
	}
	if envelope.Error != nil {
		code := strings.TrimSpace(envelope.Error.Code)
		reported := status
		if parsed, err := envelope.Error.Status.Int64(); err == nil && parsed > 0 {
			reported = int(parsed)
		}
		return &APIError{
			Status:  reported,
			Code:    code,
			Message: truncate(strings.TrimSpace(envelope.Error.Message), maxErrorMessage),
		}
	}
	if status >= 400 && (envelope.Message != "" || len(envelope.Errors) > 0) {
		message := strings.TrimSpace(envelope.Message)
		for field, problems := range envelope.Errors {
			if len(problems) > 0 {
				message = strings.TrimSpace(message + " " + field + ": " + problems[0])
			}
		}
		code := ""
		if status == http.StatusUnprocessableEntity {
			code = "INVALID_INPUTS"
		}
		return &APIError{Status: status, Code: code, Message: truncate(message, maxErrorMessage)}
	}
	return nil
}

func truncate(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}
