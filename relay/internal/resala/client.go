// Package resala is the relay's client for Resala (resala.ly), the Libyan SMS
// provider every shop's messages go out through. The API token and the approved
// template ids live only on the relay, for the same reason as the OpenRouter
// key: the company owns the account and pays for every message, so a shop never
// holds a credential it could spend from.
//
// Resala is one-way. There is no inbound SMS and no delivery webhook; delivery
// is learned by reading the sent log back (ListSent).
package resala

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// DefaultBaseURL is Resala's API. The "dev" in the host is their naming; it is
// the production API.
const DefaultBaseURL = "https://dev.resala.ly/api/v1"

const (
	defaultTimeout      = 20 * time.Second
	defaultRetryBackoff = 300 * time.Millisecond
	// maxReadAttempts is 1 initial + 2 retries, and only reads are retried.
	maxReadAttempts = 3
	// Bodies are small JSON documents; the caps only stop a misbehaving proxy
	// from streaming something unbounded into memory.
	maxResponseBytes = 4 << 20
	maxErrorMessage  = 500
)

var (
	// ErrUnauthorized is a 401: Resala does not accept the relay's token.
	ErrUnauthorized = errors.New("resala: unauthorized")
	// ErrForbidden is a 403: the token is valid but the account lacks the
	// permission (for instance template sending is not enabled on it).
	ErrForbidden = errors.New("resala: forbidden")
	// ErrInsufficientCredit is the company's wallet running dry. Resala answers
	// it as a plain 400 whose message mentions the wallet, so it is recognised
	// by that message rather than by a status of its own.
	ErrInsufficientCredit = errors.New("resala: insufficient credit")
)

// Config is how the relay reaches Resala.
type Config struct {
	BaseURL string
	Token   string
	// HTTPClient is shared so connections are reused across sends. Nil builds
	// a private client. Timeout applies per call either way.
	HTTPClient *http.Client
	Timeout    time.Duration
	// RetryBackoff is the delay before the first read retry; each further
	// retry doubles it. Zero uses the default.
	RetryBackoff time.Duration
}

// Client talks to the Resala API.
type Client struct {
	baseURL      string
	token        string
	http         *http.Client
	timeout      time.Duration
	retryBackoff time.Duration
}

// New builds a client. It never fails: a missing token surfaces as
// ErrUnauthorized on the first call, the same way a revoked one would.
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
	backoff := config.RetryBackoff
	if backoff <= 0 {
		backoff = defaultRetryBackoff
	}
	return &Client{
		baseURL:      baseURL,
		token:        strings.TrimSpace(config.Token),
		http:         httpClient,
		timeout:      timeout,
		retryBackoff: backoff,
	}
}

// Record is one recipient of a template send. Values are positional: Values[0]
// fills "$1", Values[1] fills "$2", and so on.
type Record struct {
	Phone  string
	Values []string
}

// MarshalJSON writes the record the way Resala reads it:
// {"phone":"218910024433","$1":"...","$2":"..."}, variables in numeric order.
func (r Record) MarshalJSON() ([]byte, error) {
	var buf bytes.Buffer
	buf.WriteString(`{"phone":`)
	if err := writeJSONString(&buf, r.Phone); err != nil {
		return nil, err
	}
	for i, value := range r.Values {
		fmt.Fprintf(&buf, `,"$%d":`, i+1)
		if err := writeJSONString(&buf, value); err != nil {
			return nil, err
		}
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

// encodeRecords is the "records" field: a JSON array of records. It goes
// through an encoder with HTML escaping off, because json.Marshal re-escapes a
// Marshaler's output and would undo writeJSONString.
func encodeRecords(records []Record) ([]byte, error) {
	var buf bytes.Buffer
	encoder := json.NewEncoder(&buf)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(records); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// writeJSONString encodes without HTML escaping, so a link in a variable
// reaches Resala as "a&b" rather than "a&b". Both are valid JSON; the
// literal form is simply what their logs and dashboard should show.
func writeJSONString(buf *bytes.Buffer, value string) error {
	var encoded bytes.Buffer
	encoder := json.NewEncoder(&encoded)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return err
	}
	buf.Write(bytes.TrimRight(encoded.Bytes(), "\n"))
	return nil
}

// TemplateVersion is the approved template Resala actually sent from.
type TemplateVersion struct {
	ID            string
	VersionNumber int
	// Body is the approved text with its "$n" placeholders.
	Body   string
	Status string
	// Variables are the placeholder keys, e.g. "$1", "$2".
	Variables []string
}

// SendResult is Resala's answer to a template send. It carries no per-message
// id: a sent message is matched back to the delivery log by number, time and
// content instead.
type SendResult struct {
	Failed        int
	FailedNumbers []string
	IsProd        bool
	Succeeded     int
	TotalCost     float64
	// TotalCostText is total_cost exactly as Resala wrote it ("0.1"), so the
	// ledger records the charge without a float round trip.
	TotalCostText string
	TotalMessages int
	Template      TemplateVersion
}

// SendTemplate sends one approved template to the given records. test asks
// Resala for test mode: nothing reaches a phone and nothing is charged.
//
// It makes exactly ONE attempt. A send that timed out may still have gone out,
// and a retry would text the customer twice and charge the company twice, so a
// failure is reported to the caller as it is and never retried here.
func (c *Client) SendTemplate(
	ctx context.Context,
	templateID string,
	records []Record,
	test bool,
) (SendResult, error) {
	templateID = strings.TrimSpace(templateID)
	if templateID == "" {
		return SendResult{}, errors.New("resala: template id is required")
	}
	if len(records) == 0 {
		return SendResult{}, errors.New("resala: at least one record is required")
	}
	payload, err := encodeRecords(records)
	if err != nil {
		return SendResult{}, fmt.Errorf("resala: encode records: %w", err)
	}
	var body bytes.Buffer
	form := multipart.NewWriter(&body)
	if err := form.WriteField("records", string(payload)); err != nil {
		return SendResult{}, fmt.Errorf("resala: build form: %w", err)
	}
	if err := form.Close(); err != nil {
		return SendResult{}, fmt.Errorf("resala: build form: %w", err)
	}

	// The test flag is a bare key ("&test"), exactly as their docs show it,
	// rather than "test=" or "test=true".
	query := "sms_template_id=" + url.QueryEscape(templateID)
	if test {
		query += "&test"
	}

	callCtx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(
		callCtx,
		http.MethodPost,
		c.baseURL+"/messages/send-template?"+query,
		&body,
	)
	if err != nil {
		return SendResult{}, fmt.Errorf("resala: build request: %w", err)
	}
	request.Header.Set("Content-Type", form.FormDataContentType())
	c.authorize(request)

	response, err := c.http.Do(request)
	if err != nil {
		return SendResult{}, &TransportError{Op: "send template", Err: err}
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return SendResult{}, &TransportError{Op: "read send response", Err: err}
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return SendResult{}, decodeError(response.StatusCode, raw)
	}
	result, err := decodeSendResult(raw, test)
	if err != nil {
		// Resala accepted the send but the answer is unreadable: the message
		// probably went out, so this is an unknown outcome, not a rejection.
		return SendResult{}, &TransportError{Op: "decode send response", Err: err}
	}
	return result, nil
}

type wireSendResult struct {
	Failed          flexNumber   `json:"failed"`
	FailedNumbers   []flexString `json:"failed_numbers"`
	IsProd          *bool        `json:"is_prod"`
	Succeeded       flexNumber   `json:"succeeded"`
	TotalCost       flexNumber   `json:"total_cost"`
	TotalMessages   flexNumber   `json:"total_messages"`
	TemplateVersion *struct {
		ID            flexString `json:"id"`
		VersionNumber flexNumber `json:"version_number"`
		Body          string     `json:"body"`
		Status        string     `json:"status"`
		Variables     []struct {
			Key string `json:"key"`
		} `json:"variables"`
	} `json:"sms_template_version"`
}

func decodeSendResult(raw []byte, test bool) (SendResult, error) {
	var wire wireSendResult
	if err := json.Unmarshal(raw, &wire); err != nil {
		return SendResult{}, err
	}
	result := SendResult{
		Failed:        wire.Failed.Int(),
		Succeeded:     wire.Succeeded.Int(),
		TotalCost:     wire.TotalCost.Float(),
		TotalCostText: string(wire.TotalCost),
		TotalMessages: wire.TotalMessages.Int(),
		// Absent is read as "what we asked for", never as test: a response
		// that simply omits the flag must not make a real send look free.
		IsProd: !test,
	}
	if wire.IsProd != nil {
		result.IsProd = *wire.IsProd
	}
	for _, number := range wire.FailedNumbers {
		if value := strings.TrimSpace(string(number)); value != "" {
			result.FailedNumbers = append(result.FailedNumbers, value)
		}
	}
	if source := wire.TemplateVersion; source != nil {
		result.Template = TemplateVersion{
			ID:            string(source.ID),
			VersionNumber: source.VersionNumber.Int(),
			Body:          source.Body,
			Status:        source.Status,
		}
		for _, variable := range source.Variables {
			if key := strings.TrimSpace(variable.Key); key != "" {
				result.Template.Variables = append(result.Template.Variables, key)
			}
		}
	}
	return result, nil
}

// SentQuery pages through the delivery log.
type SentQuery struct {
	// Source filters by origin; "message" (template sends) when empty. OTP
	// codes live under another source and are not used by Pointy.
	Source string
	// Page is 1-based.
	Page int
	// PerPage is Resala's "paginate" parameter.
	PerPage int
}

// SentMessage is one row of the delivery log.
type SentMessage struct {
	ID string
	// Code is the country calling code ("218"); Number is the national
	// number without it ("9XXXXXXXX").
	Code    string
	Region  string
	Number  string
	Content string
	Source  string
	// Env is "production" or "development" (test sends).
	Env string
	// Status is Resala's delivery state as written ("sent", "Delivered", ...),
	// or "" while the carrier has not reported yet.
	Status    string
	CreatedAt time.Time
	UpdatedAt time.Time
}

// SentPage is one page of the delivery log, newest first.
type SentPage struct {
	Messages    []SentMessage
	CurrentPage int
	LastPage    int
	Total       int
}

// ListSent reads one page of the delivery log, newest first. Reads are safe to
// repeat, so network failures and 5xx answers are retried (twice, backing off).
func (c *Client) ListSent(ctx context.Context, query SentQuery) (SentPage, error) {
	source := strings.TrimSpace(query.Source)
	if source == "" {
		source = "message"
	}
	page := query.Page
	if page < 1 {
		page = 1
	}
	perPage := query.PerPage
	if perPage < 1 {
		perPage = 100
	}
	// Built by hand so the filter reads "source:message" as their docs show,
	// with the colon unescaped.
	rawQuery := "filters=source:" + url.QueryEscape(source) +
		"&page=" + strconv.Itoa(page) +
		"&paginate=" + strconv.Itoa(perPage) +
		"&sorts=-created_at"

	raw, err := c.getWithRetry(ctx, "list sent", c.baseURL+"/sent-view?"+rawQuery)
	if err != nil {
		return SentPage{}, err
	}
	var wire struct {
		Data []struct {
			ID        flexString `json:"id"`
			Code      flexString `json:"code"`
			Region    string     `json:"region"`
			Number    flexString `json:"number"`
			Content   string     `json:"content"`
			Source    string     `json:"source"`
			Env       string     `json:"env"`
			Status    flexString `json:"status"`
			CreatedAt string     `json:"created_at"`
			UpdatedAt string     `json:"updated_at"`
		} `json:"data"`
		Meta struct {
			CurrentPage flexNumber `json:"current_page"`
			LastPage    flexNumber `json:"last_page"`
			Total       flexNumber `json:"total"`
		} `json:"meta"`
	}
	if err := json.Unmarshal(raw, &wire); err != nil {
		return SentPage{}, fmt.Errorf("resala: decode sent-view: %w", err)
	}
	result := SentPage{
		CurrentPage: wire.Meta.CurrentPage.Int(),
		LastPage:    wire.Meta.LastPage.Int(),
		Total:       wire.Meta.Total.Int(),
		Messages:    make([]SentMessage, 0, len(wire.Data)),
	}
	if result.CurrentPage == 0 {
		result.CurrentPage = page
	}
	for _, row := range wire.Data {
		result.Messages = append(result.Messages, SentMessage{
			ID:        strings.TrimSpace(string(row.ID)),
			Code:      strings.TrimSpace(string(row.Code)),
			Region:    strings.TrimSpace(row.Region),
			Number:    strings.TrimSpace(string(row.Number)),
			Content:   row.Content,
			Source:    strings.TrimSpace(row.Source),
			Env:       strings.TrimSpace(row.Env),
			Status:    strings.TrimSpace(string(row.Status)),
			CreatedAt: parseTime(row.CreatedAt),
			UpdatedAt: parseTime(row.UpdatedAt),
		})
	}
	return result, nil
}

func (c *Client) getWithRetry(ctx context.Context, op string, endpoint string) ([]byte, error) {
	backoff := c.retryBackoff
	var lastErr error
	for attempt := 1; attempt <= maxReadAttempts; attempt++ {
		raw, err := c.getOnce(ctx, op, endpoint)
		if err == nil {
			return raw, nil
		}
		lastErr = err
		if attempt == maxReadAttempts || ctx.Err() != nil || !retryableRead(err) {
			break
		}
		timer := time.NewTimer(backoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, lastErr
		case <-timer.C:
		}
		backoff *= 2
	}
	return nil, lastErr
}

func (c *Client) getOnce(ctx context.Context, op string, endpoint string) ([]byte, error) {
	callCtx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(callCtx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("resala: build request: %w", err)
	}
	c.authorize(request)
	response, err := c.http.Do(request)
	if err != nil {
		return nil, &TransportError{Op: op, Err: err}
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return nil, &TransportError{Op: op, Err: err}
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return nil, decodeError(response.StatusCode, raw)
	}
	return raw, nil
}

// retryableRead is whether another attempt at a READ could go differently:
// the network, a 5xx, or a 429. Anything else (a bad token, a bad query) will
// fail the same way again.
func retryableRead(err error) bool {
	var transport *TransportError
	if errors.As(err, &transport) {
		return !errors.Is(transport.Err, context.Canceled)
	}
	var provider *ProviderError
	if errors.As(err, &provider) {
		return provider.Status >= 500 || provider.Status == http.StatusTooManyRequests
	}
	return false
}

func (c *Client) authorize(request *http.Request) {
	request.Header.Set("Authorization", "Bearer "+c.token)
	request.Header.Set("Accept", "application/json")
}

// ProviderError is any non-2xx answer other than a 422. It unwraps to
// ErrUnauthorized, ErrForbidden or ErrInsufficientCredit when it is one of
// those, so callers can errors.Is the cause and still read the details.
type ProviderError struct {
	Status    int
	Type      string
	Message   string
	RequestID string
	cause     error
}

func (e *ProviderError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "resala: HTTP %d", e.Status)
	if e.Type != "" {
		b.WriteString(" " + e.Type)
	}
	if e.Message != "" {
		b.WriteString(": " + e.Message)
	}
	if e.RequestID != "" {
		b.WriteString(" (request_id " + e.RequestID + ")")
	}
	return b.String()
}

func (e *ProviderError) Unwrap() error { return e.cause }

// ValidationError is a 422: Resala refused the input. Errors maps each field to
// its messages, e.g. {"phone": ["LY phones must be made of 9 numbers"]}.
type ValidationError struct {
	Message   string
	Errors    map[string][]string
	RequestID string
}

func (e *ValidationError) Error() string {
	return "resala: HTTP 422: " + e.Detail()
}

// Detail is the message with its field errors, which is where the useful part
// of a 422 is ("input validation error." on its own says nothing).
func (e *ValidationError) Detail() string {
	message := strings.TrimSpace(e.Message)
	if len(e.Errors) == 0 {
		if message == "" {
			return "input validation error"
		}
		return message
	}
	fields := make([]string, 0, len(e.Errors))
	for field := range e.Errors {
		fields = append(fields, field)
	}
	sort.Strings(fields)
	parts := make([]string, 0, len(fields))
	for _, field := range fields {
		parts = append(parts, field+": "+strings.Join(e.Errors[field], "; "))
	}
	if message == "" {
		return strings.Join(parts, ", ")
	}
	return message + " (" + strings.Join(parts, ", ") + ")"
}

// TransportError is a call that never produced a usable answer: a network
// failure, a timeout, or an unreadable body. For a send it means the outcome
// is unknown — the message may or may not have gone out.
type TransportError struct {
	Op  string
	Err error
}

func (e *TransportError) Error() string {
	return "resala: " + e.Op + ": " + e.Err.Error()
}

func (e *TransportError) Unwrap() error { return e.Err }

// Timeout reports whether the call ran out of time.
func (e *TransportError) Timeout() bool {
	if errors.Is(e.Err, context.DeadlineExceeded) {
		return true
	}
	var timeout interface{ Timeout() bool }
	return errors.As(e.Err, &timeout) && timeout.Timeout()
}

func decodeError(status int, raw []byte) error {
	var wire struct {
		Type      string                     `json:"type"`
		Message   string                     `json:"message"`
		RequestID flexString                 `json:"request_id"`
		Errors    map[string]json.RawMessage `json:"errors"`
	}
	message := ""
	if err := json.Unmarshal(raw, &wire); err == nil {
		message = strings.TrimSpace(wire.Message)
	} else {
		// Not their JSON (a proxy's HTML page, say): keep a slice of the text
		// so the operator sees what actually came back.
		message = strings.TrimSpace(string(raw))
	}
	if message == "" {
		message = http.StatusText(status)
	}
	message = truncate(message, maxErrorMessage)
	requestID := strings.TrimSpace(string(wire.RequestID))

	if status == http.StatusUnprocessableEntity {
		return &ValidationError{
			Message:   message,
			Errors:    fieldErrors(wire.Errors),
			RequestID: requestID,
		}
	}
	providerErr := &ProviderError{
		Status:    status,
		Type:      strings.TrimSpace(wire.Type),
		Message:   message,
		RequestID: requestID,
	}
	switch {
	case status == http.StatusUnauthorized:
		providerErr.cause = ErrUnauthorized
	case status == http.StatusForbidden:
		providerErr.cause = ErrForbidden
	case status == http.StatusPaymentRequired,
		status == http.StatusBadRequest && mentionsCredit(message):
		providerErr.cause = ErrInsufficientCredit
	}
	return providerErr
}

// mentionsCredit recognises the empty-wallet 400 ("wallet must have at least
// 0.15 LYD to send an sms"). Arabic spellings are included in case the account
// is switched to Arabic messages.
func mentionsCredit(message string) bool {
	lowered := strings.ToLower(message)
	for _, marker := range []string{"credit", "wallet", "balance", "رصيد", "المحفظة"} {
		if strings.Contains(lowered, marker) {
			return true
		}
	}
	return false
}

// fieldErrors accepts both {"phone": ["..."]} and {"phone": "..."}.
func fieldErrors(raw map[string]json.RawMessage) map[string][]string {
	if len(raw) == 0 {
		return nil
	}
	out := make(map[string][]string, len(raw))
	for field, value := range raw {
		var list []string
		if err := json.Unmarshal(value, &list); err == nil {
			out[field] = list
			continue
		}
		var single string
		if err := json.Unmarshal(value, &single); err == nil {
			out[field] = []string{single}
			continue
		}
		out[field] = []string{strings.TrimSpace(string(value))}
	}
	return out
}

// flexNumber is a JSON number that may arrive as a number or a numeric string,
// kept as its decimal text so nothing is lost to float conversion.
type flexNumber string

func (n *flexNumber) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		*n = ""
		return nil
	}
	if trimmed[0] == '"' {
		var text string
		if err := json.Unmarshal(trimmed, &text); err != nil {
			return err
		}
		text = strings.TrimSpace(text)
		if text == "" {
			*n = ""
			return nil
		}
		if _, err := strconv.ParseFloat(text, 64); err != nil {
			return fmt.Errorf("resala: %q is not a number", text)
		}
		*n = flexNumber(text)
		return nil
	}
	var number json.Number
	if err := json.Unmarshal(trimmed, &number); err != nil {
		return err
	}
	*n = flexNumber(number.String())
	return nil
}

func (n flexNumber) Float() float64 {
	value, err := strconv.ParseFloat(string(n), 64)
	if err != nil {
		return 0
	}
	return value
}

func (n flexNumber) Int() int {
	if value, err := strconv.Atoi(string(n)); err == nil {
		return value
	}
	return int(n.Float())
}

// flexString is an identifier that may arrive as a string or a number.
type flexString string

func (s *flexString) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		*s = ""
		return nil
	}
	if trimmed[0] == '"' {
		var text string
		if err := json.Unmarshal(trimmed, &text); err != nil {
			return err
		}
		*s = flexString(text)
		return nil
	}
	*s = flexString(trimmed)
	return nil
}

// parseTime reads Resala's timestamps. A zone-less timestamp is taken as UTC.
func parseTime(raw string) time.Time {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return time.Time{}
	}
	for _, layout := range []string{
		time.RFC3339Nano,
		"2006-01-02T15:04:05.999999999Z0700",
		"2006-01-02 15:04:05.999999999Z07:00",
		"2006-01-02 15:04:05.999999999Z0700",
		"2006-01-02 15:04:05.999999999 -0700 MST",
	} {
		if parsed, err := time.Parse(layout, raw); err == nil {
			return parsed.UTC()
		}
	}
	for _, layout := range []string{
		"2006-01-02T15:04:05.999999999",
		"2006-01-02 15:04:05.999999999",
	} {
		if parsed, err := time.ParseInLocation(layout, raw, time.UTC); err == nil {
			return parsed.UTC()
		}
	}
	return time.Time{}
}

func truncate(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit]) + "…"
}

// RenderBody substitutes positional values into an approved template body:
// values[0] for "$1", values[1] for "$2", and so on.
//
// Keys are matched longest first, so with ten values "$10" is the tenth value
// rather than the first followed by a literal "0", while with only one value
// "$10" stays "value-one" + "0". It is a single pass, so a value that itself
// contains "$2" is never substituted a second time.
func RenderBody(body string, values []string) string {
	if len(values) == 0 || !strings.Contains(body, "$") {
		return body
	}
	var out strings.Builder
	out.Grow(len(body))
	for i := 0; i < len(body); {
		if body[i] != '$' {
			out.WriteByte(body[i])
			i++
			continue
		}
		end := i + 1
		for end < len(body) && body[end] >= '0' && body[end] <= '9' {
			end++
		}
		matched := false
		for candidate := end; candidate > i+1; candidate-- {
			digits := body[i+1 : candidate]
			n, err := strconv.Atoi(digits)
			// "$01" is not the key "$1": only canonical keys match.
			if err != nil || n < 1 || n > len(values) || strconv.Itoa(n) != digits {
				continue
			}
			out.WriteString(values[n-1])
			i = candidate
			matched = true
			break
		}
		if !matched {
			out.WriteByte('$')
			i++
		}
	}
	return out.String()
}

// NormalizeLibyanMobile turns a Libyan mobile number into the form Resala
// wants: "218" followed by the 9-digit national number, which starts with 9.
//
// Accepted spellings: +218 9X…, 00218 9X…, 218 9X…, 09X… and 9X…, with
// spaces, dashes, dots and brackets ignored and Arabic-Indic digits read as
// digits. Anything else — a landline, a foreign number, a short code — is not
// a number the company can text, and reports false.
func NormalizeLibyanMobile(raw string) (string, bool) {
	var digits strings.Builder
	plus := false
	seen := false
	for _, r := range raw {
		switch {
		case r >= '0' && r <= '9':
			digits.WriteRune(r)
		case r >= '٠' && r <= '٩': // Arabic-Indic
			digits.WriteRune('0' + (r - '٠'))
		case r >= '۰' && r <= '۹': // Extended Arabic-Indic (Persian)
			digits.WriteRune('0' + (r - '۰'))
		case r == '+':
			if seen || plus {
				return "", false
			}
			plus = true
			continue
		case isPhoneSeparator(r):
			continue
		default:
			return "", false
		}
		seen = true
	}
	number := digits.String()
	var national string
	switch {
	case plus:
		if len(number) != 12 || !strings.HasPrefix(number, "218") {
			return "", false
		}
		national = number[3:]
	case len(number) == 14 && strings.HasPrefix(number, "00218"):
		national = number[5:]
	case len(number) == 12 && strings.HasPrefix(number, "218"):
		national = number[3:]
	case len(number) == 10 && strings.HasPrefix(number, "0"):
		national = number[1:]
	case len(number) == 9:
		national = number
	default:
		return "", false
	}
	if national[0] != '9' {
		return "", false
	}
	return "218" + national, true
}

// isPhoneSeparator is formatting a person or a form puts inside a number,
// including the invisible direction marks Arabic text wraps around digits.
func isPhoneSeparator(r rune) bool {
	switch r {
	case ' ', '\t', '-', '.', '(', ')', '/', '\u00a0', '\u200e', '\u200f',
		'\u202a', '\u202b', '\u202c', '\u202d', '\u202e',
		'\u2066', '\u2067', '\u2068', '\u2069':
		return true
	}
	return false
}
