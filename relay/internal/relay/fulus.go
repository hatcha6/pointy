package relay

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"pointy/relay/internal/control"
)

// fulus.ly publishes Libyan parallel-market rates. The relay holds ONE
// subscription for the whole fleet and fans the published rates out to shops
// over the connector tunnel, because their quota is daily and per-account: N
// shops polling directly would be both expensive and rate-limit fragile. That
// arrangement is also the commercial reason the feed sits behind our own
// subscription rather than being something each shop configures.
//
// Every rate they publish is a PARALLEL-MARKET rate, including the per-bank
// series. "bank" is not the official CBL rate — it is the parallel rate for
// settling through a bank (transfer, letter of credit, certificate) instead of
// in physical cash, published per bank because that price differs between them.
// The relay therefore carries a settlement *instrument*, never a market.
const (
	fulusDefaultBaseURL = "https://fulus.ly/api/v1"
	// Everything fulus publishes is quoted against the dinar.
	fulusQuoteCurrency = "LYD"
	fulusSourceName    = "fulus"

	// fulusDefaultCurrency is what /rates/current answers with when asked for
	// nothing, and the one pair every plan includes.
	fulusDefaultCurrency = "USD"

	fulusInstrumentCash = "cash"
	fulusInstrumentBank = "bank"
)

var (
	errFulusNotConfigured = errors.New("fulus feed is not configured")
	// errFulusOutsidePlan is per-request: this currency or bank is not on the
	// relay's plan. Routine, and never a reason to stop polling the rest.
	errFulusOutsidePlan = errors.New("fulus resource is not on this plan")
	// errFulusSubscriptionInactive stops the whole feed until an operator acts.
	errFulusSubscriptionInactive = errors.New("fulus subscription inactive")
	errFulusQuotaExhausted       = errors.New("fulus daily quota exhausted")
	errFulusNoData               = errors.New("fulus has no data for this request")
)

// FulusConfig is the relay's credentials for the upstream feed.
type FulusConfig struct {
	BaseURL string
	Token   string
	// WebhookSecret verifies the HMAC on pushed rates. Empty disables the
	// webhook endpoint outright rather than accepting unverified pushes — an
	// unauthenticated writer to the fleet's rate table would be able to reprice
	// every shop that trusts it.
	WebhookSecret string
	Timeout       time.Duration
}

func (c FulusConfig) configured() bool {
	return strings.TrimSpace(c.Token) != ""
}

func (c FulusConfig) baseURL() string {
	if trimmed := strings.TrimSpace(c.BaseURL); trimmed != "" {
		return strings.TrimRight(trimmed, "/")
	}
	return fulusDefaultBaseURL
}

func (c FulusConfig) timeout() time.Duration {
	if c.Timeout > 0 {
		return c.Timeout
	}
	return 15 * time.Second
}

// FulusClient reads rates from the upstream provider.
type FulusClient struct {
	config FulusConfig
	http   *http.Client
}

func NewFulusClient(config FulusConfig) *FulusClient {
	return &FulusClient{
		config: config,
		http:   &http.Client{Timeout: config.timeout()},
	}
}

// fulusRate is one rate as the provider states it, across BOTH shapes they
// publish. Their OpenAPI spec (fulus.ly/fulus-openapi-en.yaml) and their
// webhook docs disagree on two fields, so both spellings are read here:
//
//   - the instant is "timestamp" over REST and "created_at" on the webhook;
//   - the bank is a slug in "bank" over REST, where "bank_name" is a display
//     name ("Bank of Commerce and Development"), while the webhook puts the
//     slug itself in "bank_name". So the slug fields win and the display name
//     is only a last resort.
//
// A cash row carries no rate_type at all, which is why cash is the default
// rather than something we require them to state.
type fulusRate struct {
	Currency  string `json:"currency"`
	Code      string `json:"code"`
	Rate      any    `json:"rate"`
	RateType  string `json:"rate_type"`
	Bank      string `json:"bank"`
	BankCode  string `json:"bank_code"`
	BankName  string `json:"bank_name"`
	Timestamp string `json:"timestamp"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

// fulusEnvelope holds the payload undecoded because the same "data" key is an
// object on /rates/current (one rate) and an array on /rates/history and
// /rates/banks. Decoding it eagerly into a slice is what made every poll of the
// current series fail outright.
type fulusEnvelope struct {
	Data       json.RawMessage `json:"data"`
	Rates      json.RawMessage `json:"rates"`
	Currencies json.RawMessage `json:"currencies"`
}

type fulusWebhookEnvelope struct {
	Event string    `json:"event"`
	Data  fulusRate `json:"data"`
}

// fulusCurrency is one entry of /currencies, which reports the currencies the
// relay's own plan may ask for. Asking for one outside the plan is a 403 per
// currency, so the poller reads this rather than guessing.
type fulusCurrency struct {
	Code string `json:"code"`
}

// FetchCurrencies reports which currencies the relay's plan may request.
// /rates/current serves ONE currency per call, so without this the poller
// either polls USD alone or burns requests on 403s.
func (c *FulusClient) FetchCurrencies(ctx context.Context) ([]string, error) {
	body, err := c.get(ctx, "/currencies", nil)
	if err != nil {
		return nil, err
	}
	var envelope fulusEnvelope
	if err := unmarshalFulusJSON(body, &envelope); err != nil {
		return nil, fmt.Errorf("fulus returned unparseable JSON: %w", err)
	}
	raw := envelope.Currencies
	if len(raw) == 0 {
		raw = envelope.Data
	}
	var entries []fulusCurrency
	if len(raw) > 0 {
		_ = unmarshalFulusJSON(raw, &entries)
	}
	codes := make([]string, 0, len(entries))
	for _, entry := range entries {
		code := strings.ToUpper(strings.TrimSpace(entry.Code))
		if code != "" && code != fulusQuoteCurrency {
			codes = append(codes, code)
		}
	}
	if len(codes) == 0 {
		return nil, errors.New("fulus reported no available currencies")
	}
	return codes, nil
}

// FetchCurrentRate reads the current cash rate for one currency. The endpoint
// takes a single currency (defaulting to USD) and answers with ONE rate object,
// not a list.
func (c *FulusClient) FetchCurrentRate(
	ctx context.Context,
	currency string,
) ([]control.ExchangeRate, error) {
	query := url.Values{}
	if trimmed := strings.ToUpper(strings.TrimSpace(currency)); trimmed != "" {
		query.Set("currency", trimmed)
	}
	query.Set("rate_type", fulusInstrumentCash)
	return c.fetchRates(ctx, "/rates/current", query)
}

// FetchBankRates reads the per-bank series. Bank rates exist for USD only, and
// this one call returns every bank the plan allows.
func (c *FulusClient) FetchBankRates(ctx context.Context) ([]control.ExchangeRate, error) {
	return c.fetchRates(ctx, "/rates/banks", nil)
}

func (c *FulusClient) fetchRates(
	ctx context.Context,
	path string,
	query url.Values,
) ([]control.ExchangeRate, error) {
	body, err := c.get(ctx, path, query)
	if err != nil {
		return nil, err
	}
	rows, err := decodeFulusRates(body)
	if err != nil {
		return nil, err
	}
	rates := make([]control.ExchangeRate, 0, len(rows))
	for _, row := range rows {
		converted, ok := row.toExchangeRate()
		if !ok {
			continue
		}
		rates = append(rates, converted)
	}
	return rates, nil
}

func (c *FulusClient) get(ctx context.Context, path string, query url.Values) ([]byte, error) {
	if !c.config.configured() {
		return nil, errFulusNotConfigured
	}
	endpoint := c.config.baseURL() + path
	if len(query) > 0 {
		endpoint += "?" + query.Encode()
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(c.config.Token))
	request.Header.Set("Accept", "application/json")

	response, err := c.http.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()

	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if response.StatusCode == http.StatusForbidden {
		// 403 means two different things. "This currency is not available on
		// your plan" is per-request and routine — the poller skips that
		// currency and carries on. Anything else is the relay's own
		// subscription having lapsed, which stops the whole feed and is an
		// operator problem rather than a shop problem.
		if strings.Contains(strings.ToLower(string(body)), "not available on your plan") {
			return nil, fmt.Errorf("%w: %s", errFulusOutsidePlan, truncateForLog(body))
		}
		return nil, fmt.Errorf("%w (403): %s", errFulusSubscriptionInactive, truncateForLog(body))
	}
	if response.StatusCode == http.StatusTooManyRequests {
		return nil, fmt.Errorf("%w (429): %s", errFulusQuotaExhausted, truncateForLog(body))
	}
	if response.StatusCode == http.StatusNotFound {
		// "No rate data found" for a date or a pair they simply have not
		// published. Nothing is wrong; there is just nothing to store.
		return nil, fmt.Errorf("%w: %s", errFulusNoData, truncateForLog(body))
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("fulus returned %d: %s", response.StatusCode, truncateForLog(body))
	}
	return body, nil
}

// decodeFulusRates accepts every shape the feed actually serves: an envelope
// whose "data" is one object (/rates/current) or a list (/rates/history,
// /rates/banks), a "rates" key, or a bare object or list with no envelope.
func decodeFulusRates(body []byte) ([]fulusRate, error) {
	var envelope fulusEnvelope
	if err := unmarshalFulusJSON(body, &envelope); err == nil {
		for _, raw := range []json.RawMessage{envelope.Data, envelope.Rates} {
			if rows, ok := decodeFulusRateNode(raw); ok {
				return rows, nil
			}
		}
	}
	if rows, ok := decodeFulusRateNode(body); ok {
		return rows, nil
	}
	return nil, fmt.Errorf("fulus returned unparseable JSON: %s", truncateForLog(body))
}

func decodeFulusRateNode(raw json.RawMessage) ([]fulusRate, bool) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || string(trimmed) == "null" {
		return nil, false
	}
	switch trimmed[0] {
	case '[':
		var rows []fulusRate
		if err := unmarshalFulusJSON(trimmed, &rows); err != nil {
			return nil, false
		}
		return rows, true
	case '{':
		var row fulusRate
		if err := unmarshalFulusJSON(trimmed, &row); err != nil {
			return nil, false
		}
		return []fulusRate{row}, true
	default:
		return nil, false
	}
}

// unmarshalFulusJSON keeps numbers as their published text. Plain
// json.Unmarshal turns a rate into a float64, and a published 0.20416667 must
// reach a shop as the digits fulus wrote, not as the nearest binary double.
func unmarshalFulusJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	return decoder.Decode(target)
}

// VerifyFulusWebhook checks the HMAC-SHA256 the provider sends in
// X-Webhook-Signature. Constant-time, and it refuses outright when no secret is
// configured rather than treating "no secret" as "any signature is fine".
func VerifyFulusWebhook(secret string, body []byte, signature string) bool {
	secret = strings.TrimSpace(secret)
	signature = strings.TrimSpace(signature)
	if secret == "" || signature == "" {
		return false
	}
	signature = strings.TrimPrefix(signature, "sha256=")
	expected := hmac.New(sha256.New, []byte(secret))
	expected.Write(body)
	want := hex.EncodeToString(expected.Sum(nil))
	return hmac.Equal([]byte(strings.ToLower(signature)), []byte(want))
}

// ParseFulusWebhook turns a verified push into a storable rate.
func ParseFulusWebhook(body []byte) (control.ExchangeRate, error) {
	var envelope fulusWebhookEnvelope
	if err := json.Unmarshal(body, &envelope); err != nil {
		return control.ExchangeRate{}, err
	}
	if envelope.Event != "" && !isFulusPublicationEvent(envelope.Event) {
		return control.ExchangeRate{}, fmt.Errorf("unsupported fulus event %q", envelope.Event)
	}
	rate, ok := envelope.Data.toExchangeRate()
	if !ok {
		return control.ExchangeRate{}, fmt.Errorf(
			"fulus webhook carried no usable rate: %s", envelope.Data.unusableReason(),
		)
	}
	return rate, nil
}

// isFulusPublicationEvent reports whether the event announces a rate that now
// stands. A correction is published as a new rate at a new instant, so an
// update is stored exactly like a creation; a deletion is not, because the
// document that froze that rate must still be able to resolve it.
func isFulusPublicationEvent(event string) bool {
	switch strings.ToLower(strings.TrimSpace(event)) {
	case "rate.created", "rate.updated", "rate.published":
		return true
	default:
		return false
	}
}

// unusableReason names the field that stopped a payload from becoming a rate.
// Without it a rejection is just "unusable payload", which says nothing about
// whether the provider changed a field name or sent a genuinely empty row.
func (r fulusRate) unusableReason() string {
	code := strings.ToUpper(strings.TrimSpace(firstNonEmpty(r.Currency, r.Code)))
	switch {
	case code == "":
		return "no currency"
	case code == fulusQuoteCurrency:
		return "quote currency only"
	case decimalString(r.Rate) == "":
		return "no rate"
	case decimalString(r.Rate) == "0":
		return "zero rate"
	}
	if _, ok := parseFulusTime(firstNonEmpty(r.Timestamp, r.CreatedAt, r.UpdatedAt)); !ok {
		return "no usable timestamp"
	}
	return "unknown"
}

func (r fulusRate) toExchangeRate() (control.ExchangeRate, bool) {
	code := strings.ToUpper(strings.TrimSpace(firstNonEmpty(r.Currency, r.Code)))
	if code == "" || code == fulusQuoteCurrency {
		return control.ExchangeRate{}, false
	}
	value := decimalString(r.Rate)
	if value == "" || value == "0" {
		return control.ExchangeRate{}, false
	}

	instrument := fulusInstrumentCash
	bank := ""
	if strings.EqualFold(strings.TrimSpace(r.RateType), fulusInstrumentBank) {
		instrument = fulusInstrumentBank
		// Slug first: over REST "bank_name" is the display name, and storing
		// "bank of commerce and development" as a bank code would neither match
		// the webhook's row nor anything a shop can be configured with.
		bank = strings.ToLower(strings.TrimSpace(firstNonEmpty(r.Bank, r.BankCode, r.BankName)))
	}

	effectiveAt, ok := parseFulusTime(firstNonEmpty(r.Timestamp, r.CreatedAt, r.UpdatedAt))
	if !ok {
		return control.ExchangeRate{}, false
	}

	return control.ExchangeRate{
		FromCode:    code,
		ToCode:      fulusQuoteCurrency,
		Instrument:  instrument,
		BankCode:    bank,
		Rate:        value,
		EffectiveAt: effectiveAt,
		Source:      fulusSourceName,
	}, true
}

func parseFulusTime(value string) (time.Time, bool) {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}, false
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02 15:04:05"} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed.UTC(), true
		}
	}
	return time.Time{}, false
}

// decimalString keeps a rate as text end to end. Passing it through float64
// would round a published rate before it ever reached a shop, and the whole
// point of the frozen-rate discipline is that the number a document used is the
// number that was published.
func decimalString(value any) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case json.Number:
		return typed.String()
	case float64:
		return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.8f", typed), "0"), ".")
	case nil:
		return ""
	default:
		return strings.TrimSpace(fmt.Sprintf("%v", typed))
	}
}

func truncateForLog(body []byte) string {
	const limit = 200
	if len(body) <= limit {
		return string(body)
	}
	return string(body[:limit]) + "…"
}
