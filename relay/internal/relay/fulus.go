package relay

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
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

	fulusInstrumentCash = "cash"
	fulusInstrumentBank = "bank"
)

var errFulusNotConfigured = errors.New("fulus feed is not configured")

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

// fulusRate is one rate as the provider states it. Their webhook payload is
// documented and verified; the polling envelope is accepted in several shapes
// because the published docs do not pin the field names down, and a feed that
// silently stopped parsing would be worse than one that tolerated a synonym.
type fulusRate struct {
	Currency  string `json:"currency"`
	Code      string `json:"code"`
	Rate      any    `json:"rate"`
	RateType  string `json:"rate_type"`
	Bank      string `json:"bank_name"`
	BankCode  string `json:"bank_code"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

type fulusListResponse struct {
	Data  []fulusRate `json:"data"`
	Rates []fulusRate `json:"rates"`
}

type fulusWebhookEnvelope struct {
	Event string    `json:"event"`
	Data  fulusRate `json:"data"`
}

// FetchCurrentRates reads the provider's current published rates.
func (c *FulusClient) FetchCurrentRates(ctx context.Context) ([]control.ExchangeRate, error) {
	return c.fetch(ctx, "/rates/current")
}

// FetchBankRates reads the per-bank series.
func (c *FulusClient) FetchBankRates(ctx context.Context) ([]control.ExchangeRate, error) {
	return c.fetch(ctx, "/rates/banks")
}

func (c *FulusClient) fetch(ctx context.Context, path string) ([]control.ExchangeRate, error) {
	if !c.config.configured() {
		return nil, errFulusNotConfigured
	}
	request, err := http.NewRequestWithContext(
		ctx, http.MethodGet, c.config.baseURL()+path, nil,
	)
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
		// Their own subscription lapsed. Distinct from a transport error: the
		// fleet keeps serving the rates it already holds, and this is an
		// operator problem rather than a shop problem.
		return nil, fmt.Errorf("fulus subscription inactive (403): %s", truncateForLog(body))
	}
	if response.StatusCode == http.StatusTooManyRequests {
		return nil, fmt.Errorf("fulus daily quota exhausted (429): %s", truncateForLog(body))
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("fulus returned %d: %s", response.StatusCode, truncateForLog(body))
	}

	var envelope fulusListResponse
	if err := json.Unmarshal(body, &envelope); err != nil {
		// Some endpoints return a bare array rather than an envelope.
		var bare []fulusRate
		if bareErr := json.Unmarshal(body, &bare); bareErr != nil {
			return nil, fmt.Errorf("fulus returned unparseable JSON: %w", err)
		}
		envelope.Data = bare
	}
	rows := envelope.Data
	if len(rows) == 0 {
		rows = envelope.Rates
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
	if envelope.Event != "" && envelope.Event != "rate.created" {
		return control.ExchangeRate{}, fmt.Errorf("unsupported fulus event %q", envelope.Event)
	}
	rate, ok := envelope.Data.toExchangeRate()
	if !ok {
		return control.ExchangeRate{}, errors.New("fulus webhook carried no usable rate")
	}
	return rate, nil
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
		bank = strings.ToLower(strings.TrimSpace(firstNonEmpty(r.BankCode, r.Bank)))
	}

	effectiveAt, ok := parseFulusTime(firstNonEmpty(r.CreatedAt, r.UpdatedAt))
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
