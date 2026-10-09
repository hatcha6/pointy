// Package bnplus is the relay's client for BN Plus (portal.bn-plusli.ly), the
// card wholesaler the company buys prepaid vouchers from: local cards (Libyana,
// Almadar, LTT, …) paid from the company's dinar wallet there, and
// international ones (iTunes, PlayStation, Google Play, …) from its dollar
// wallet.
//
// The merchant account is the company's, like the Resala and Dafa accounts:
// the e-mail, password and bearer token live only in relay env, and a shop
// never holds a credential it could spend from. Shops buy through the relay,
// which charges their voucher balance first (see the vouchers package).
//
// Every call carries all three credentials as headers. Reads are safe to repeat
// and are retried; a purchase (BuyCard) is made exactly once — BN Plus takes no
// client reference, so a retry would buy a second card.
package bnplus

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// DefaultBaseURL is the merchant portal; the API lives under /api/merchant.
const DefaultBaseURL = "https://portal.bn-plusli.ly"

const (
	defaultTimeout      = 30 * time.Second
	defaultRetryBackoff = 300 * time.Millisecond
	// maxReadAttempts is 1 initial + 2 retries, and only reads are retried.
	maxReadAttempts = 3
	// The order history is the largest answer; the cap only stops a
	// misbehaving proxy from streaming something unbounded into memory.
	maxResponseBytes = 16 << 20
	maxErrorMessage  = 500
	// MaxQuantity is the most cards one purchase asks for. BN Plus publishes
	// no limit; the relay never needs more than a till sells in one line.
	MaxQuantity = 50
)

var (
	// ErrUnauthorized is a 401/403: BN Plus does not accept the company's
	// e-mail, password or token.
	ErrUnauthorized = errors.New("bnplus: unauthorized")
	// ErrInsufficientBalance is the company's wallet at BN Plus (dinar for
	// local cards, dollar for international ones) not covering the purchase.
	// BN Plus answers it as a plain refusal whose message mentions the
	// balance, so it is recognised by that message.
	ErrInsufficientBalance = errors.New("bnplus: insufficient balance")
	// ErrOutOfStock is BN Plus having no code left for the card.
	ErrOutOfStock = errors.New("bnplus: out of stock")
)

// Config is how the relay reaches BN Plus.
type Config struct {
	BaseURL  string
	Email    string
	Password string
	Token    string
	// HTTPClient is shared so connections are reused. Nil builds a private
	// client. Timeout applies per call either way.
	HTTPClient *http.Client
	Timeout    time.Duration
	// RetryBackoff is the delay before the first read retry; each further
	// retry doubles it. Zero uses the default.
	RetryBackoff time.Duration
}

// Configured is whether all three credentials are present. Half a set is
// reported by the caller; the client itself never refuses to build.
func (c Config) Configured() bool {
	return strings.TrimSpace(c.Email) != "" &&
		strings.TrimSpace(c.Password) != "" &&
		strings.TrimSpace(c.Token) != ""
}

// Partial is whether some, but not all, credentials are present.
func (c Config) Partial() bool {
	set := 0
	for _, value := range []string{c.Email, c.Password, c.Token} {
		if strings.TrimSpace(value) != "" {
			set++
		}
	}
	return set > 0 && set < 3
}

// Client talks to the BN Plus merchant API.
type Client struct {
	baseURL      string
	email        string
	password     string
	token        string
	http         *http.Client
	timeout      time.Duration
	retryBackoff time.Duration
}

// New builds a client. It never fails: missing credentials surface as
// ErrUnauthorized on the first call, the same way revoked ones would.
func New(config Config) *Client {
	baseURL := strings.TrimRight(strings.TrimSpace(config.BaseURL), "/")
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	// The API root is accepted too, so either spelling of the setting works.
	baseURL = strings.TrimSuffix(baseURL, "/api/merchant")
	timeout := config.Timeout
	if timeout <= 0 {
		timeout = defaultTimeout
	}
	httpClient := config.HTTPClient
	if httpClient == nil {
		// A private client never follows a redirect: a purchase is a POST that
		// spends money, and every call carries the company's credentials.
		httpClient = &http.Client{
			Timeout:       timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
	}
	backoff := config.RetryBackoff
	if backoff <= 0 {
		backoff = defaultRetryBackoff
	}
	return &Client{
		baseURL:      baseURL,
		email:        strings.TrimSpace(config.Email),
		password:     config.Password,
		token:        strings.TrimSpace(config.Token),
		http:         httpClient,
		timeout:      timeout,
		retryBackoff: backoff,
	}
}

// GroupType filters groups: local cards are paid in dinars, international ones
// in dollars.
type GroupType int

const (
	AllGroups          GroupType = 0
	LocalGroups        GroupType = 1
	InternationalGroup GroupType = 2
)

// Group is BN Plus's own top-level grouping of companies. The relay's catalog
// does not follow it; it is listed only so the operator can find cards.
type Group struct {
	ID     int64  `json:"id"`
	NameAR string `json:"name_ar"`
	NameEN string `json:"name_en"`
	Image  string `json:"image"`
	// Type is "local" or "international".
	Type string `json:"type"`
}

// Wallet is one of the company's balances at BN Plus.
type Wallet struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Currency string `json:"currency"`
	Symbol   string `json:"symbol"`
	Decimals int    `json:"decimals"`
	// Balance is the decimal text exactly as BN Plus wrote it.
	Balance string `json:"balance"`
}

// Company is a "company branch" — a brand of cards (Madar, iTunes, …).
type Company struct {
	BranchID int64  `json:"branch_id"`
	Name     string `json:"name"`
	Image    string `json:"image"`
}

// Card is one denomination BN Plus sells, at the company's merchant price.
type Card struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	Image string `json:"image"`
	// MerchantPrice is what one card costs the company, as BN Plus wrote it,
	// in Currency (LYD for local cards, USD for international ones).
	MerchantPrice string `json:"merchant_price"`
	Currency      string `json:"currency"`
	InStock       bool   `json:"in_stock"`
}

// Code is one purchased card: the secret to redeem and its serial.
type Code struct {
	Code   string `json:"code"`
	Serial string `json:"serial"`
}

// Status is an order's state at BN Plus.
type Status string

const (
	StatusSubmitted Status = "submitted"
	StatusSucceeded Status = "succeeded"
	StatusFailed    Status = "failed"
	// StatusReceivingCodesFailed is an order BN Plus took but could not get
	// codes for from its own supplier. Its admins can resubmit it, so it is
	// not final for the relay.
	StatusReceivingCodesFailed Status = "receiving_codes_failed"
)

// Final is whether the status can no longer change on its own.
func (s Status) Final() bool {
	return s == StatusSucceeded || s == StatusFailed
}

// Order is a purchase: BuyCard's answer, one row of the history, or a status
// read.
type Order struct {
	ID       int64  `json:"order_id"`
	CardName string `json:"card_name,omitempty"`
	// CardType is "local" or "international" (history rows only).
	CardType   string `json:"card_type,omitempty"`
	Quantity   int    `json:"quantity,omitempty"`
	TotalPrice string `json:"total_price"`
	Currency   string `json:"currency,omitempty"`
	// Status is empty on BuyCard's answer, which is a success by definition.
	Status        Status    `json:"status,omitempty"`
	FailedMessage string    `json:"failed_message,omitempty"`
	Date          time.Time `json:"date,omitempty"`
	Codes         []Code    `json:"codes"`
	// Message is BN Plus's sentence on a purchase ("تم تنفيذ الطلب بنجاح.").
	Message string `json:"message,omitempty"`
}

// Groups lists the groups assigned to the company, optionally of one type.
func (c *Client) Groups(ctx context.Context, groupType GroupType) ([]Group, error) {
	query := url.Values{}
	if groupType == LocalGroups || groupType == InternationalGroup {
		query.Set("type", strconv.Itoa(int(groupType)))
	}
	raw, err := c.getWithRetry(ctx, "groups", "/groups", query)
	if err != nil {
		return nil, err
	}
	var wire struct {
		envelope
		Groups []struct {
			ID     flexString `json:"id"`
			NameAR string     `json:"name_ar"`
			NameEN string     `json:"name_en"`
			Image  string     `json:"image"`
			Type   flexString `json:"type"`
		} `json:"groups"`
	}
	if err := decode(raw, &wire, &wire.envelope); err != nil {
		return nil, err
	}
	groups := make([]Group, 0, len(wire.Groups))
	for _, row := range wire.Groups {
		groups = append(groups, Group{
			ID:     row.ID.Int64(),
			NameAR: strings.TrimSpace(row.NameAR),
			NameEN: strings.TrimSpace(row.NameEN),
			Image:  strings.TrimSpace(row.Image),
			Type:   groupTypeName(string(row.Type)),
		})
	}
	return groups, nil
}

// Wallets lists the company's balances (dinar and dollar).
func (c *Client) Wallets(ctx context.Context) ([]Wallet, error) {
	raw, err := c.getWithRetry(ctx, "wallets", "/wallets", nil)
	if err != nil {
		return nil, err
	}
	var wire struct {
		envelope
		Wallets []struct {
			ID       flexString `json:"id"`
			Name     string     `json:"name"`
			Currency string     `json:"currency"`
			Symbol   string     `json:"symbol"`
			Decimals flexNumber `json:"decimals"`
			Balance  flexNumber `json:"balance"`
		} `json:"wallets"`
	}
	if err := decode(raw, &wire, &wire.envelope); err != nil {
		return nil, err
	}
	wallets := make([]Wallet, 0, len(wire.Wallets))
	for _, row := range wire.Wallets {
		wallets = append(wallets, Wallet{
			ID:       row.ID.Int64(),
			Name:     strings.TrimSpace(row.Name),
			Currency: strings.ToUpper(strings.TrimSpace(row.Currency)),
			Symbol:   strings.TrimSpace(row.Symbol),
			Decimals: row.Decimals.Int(),
			Balance:  string(row.Balance),
		})
	}
	return wallets, nil
}

// Companies lists the company branches (card brands) assigned to the company,
// optionally within one group (0 = all).
func (c *Client) Companies(ctx context.Context, groupID int64) ([]Company, error) {
	query := url.Values{}
	if groupID > 0 {
		query.Set("group_id", strconv.FormatInt(groupID, 10))
	}
	raw, err := c.getWithRetry(ctx, "companies", "/companies", query)
	if err != nil {
		return nil, err
	}
	var wire struct {
		envelope
		Companies []struct {
			BranchID    flexString `json:"branch_id"`
			BranchName  string     `json:"branch_name"`
			BranchImage string     `json:"branch_image"`
		} `json:"companies"`
	}
	if err := decode(raw, &wire, &wire.envelope); err != nil {
		return nil, err
	}
	companies := make([]Company, 0, len(wire.Companies))
	for _, row := range wire.Companies {
		companies = append(companies, Company{
			BranchID: row.BranchID.Int64(),
			Name:     strings.TrimSpace(row.BranchName),
			Image:    strings.TrimSpace(row.BranchImage),
		})
	}
	return companies, nil
}

// Cards lists one branch's active cards at the company's merchant price.
func (c *Client) Cards(ctx context.Context, branchID int64) ([]Card, error) {
	if branchID <= 0 {
		return nil, errors.New("bnplus: a branch id is required")
	}
	raw, err := c.getWithRetry(ctx, "cards", "/company/"+strconv.FormatInt(branchID, 10)+"/cards", nil)
	if err != nil {
		return nil, err
	}
	var wire struct {
		envelope
		Cards []struct {
			ID            flexString `json:"id"`
			Name          string     `json:"name"`
			Image         string     `json:"image"`
			MerchantPrice flexNumber `json:"merchant_price"`
			Currency      string     `json:"currency"`
			InStock       flexBool   `json:"in_stock"`
		} `json:"cards"`
	}
	if err := decode(raw, &wire, &wire.envelope); err != nil {
		return nil, err
	}
	cards := make([]Card, 0, len(wire.Cards))
	for _, row := range wire.Cards {
		cards = append(cards, Card{
			ID:            row.ID.Int64(),
			Name:          strings.TrimSpace(row.Name),
			Image:         strings.TrimSpace(row.Image),
			MerchantPrice: string(row.MerchantPrice),
			Currency:      strings.ToUpper(strings.TrimSpace(row.Currency)),
			InStock:       bool(row.InStock),
		})
	}
	return cards, nil
}

// BuyCard buys quantity codes of one card, paid from the company's wallet at
// BN Plus, and answers them at once.
//
// It makes exactly ONE attempt: BN Plus takes no client reference, so a retry
// after a lost answer would buy the cards twice. A failure is returned as it
// is; Definite tells whether nothing can have been bought.
func (c *Client) BuyCard(ctx context.Context, cardID int64, quantity int) (Order, error) {
	if cardID <= 0 {
		return Order{}, errors.New("bnplus: a card id is required")
	}
	if quantity < 1 || quantity > MaxQuantity {
		return Order{}, fmt.Errorf("bnplus: quantity must be 1..%d", MaxQuantity)
	}
	body, err := json.Marshal(map[string]int64{"card_id": cardID, "quantity": int64(quantity)})
	if err != nil {
		return Order{}, fmt.Errorf("bnplus: encode purchase: %w", err)
	}
	raw, err := c.do(ctx, "buy card", http.MethodPost, "/buy-card", nil, body)
	if err != nil {
		return Order{}, err
	}
	var wire struct {
		envelope
		wireOrder
	}
	if err := json.Unmarshal(raw, &wire); err != nil {
		// BN Plus took the purchase but the answer is unreadable: the cards
		// were probably bought, so the outcome is unknown, not a refusal.
		return Order{}, &TransportError{Op: "decode purchase", Err: err, Sent: true}
	}
	order := wire.wireOrder.order()
	if !wire.ok() {
		return Order{}, refusal(http.StatusOK, wire.envelope, order.ID)
	}
	order.Message = strings.TrimSpace(wire.Message)
	if order.Status == "" {
		order.Status = StatusSucceeded
	}
	return order, nil
}

// Orders reads the company's whole purchase history, with codes.
func (c *Client) Orders(ctx context.Context) ([]Order, error) {
	raw, err := c.getWithRetry(ctx, "orders", "/orders", nil)
	if err != nil {
		return nil, err
	}
	var wire struct {
		envelope
		Orders []wireOrder `json:"orders"`
	}
	if err := decode(raw, &wire, &wire.envelope); err != nil {
		return nil, err
	}
	orders := make([]Order, 0, len(wire.Orders))
	for _, row := range wire.Orders {
		orders = append(orders, row.order())
	}
	return orders, nil
}

// OrderStatus reads one order: its state, price and codes.
func (c *Client) OrderStatus(ctx context.Context, orderID int64) (Order, error) {
	if orderID <= 0 {
		return Order{}, errors.New("bnplus: an order id is required")
	}
	raw, err := c.getWithRetry(ctx, "order status", "/order/"+strconv.FormatInt(orderID, 10)+"/status", nil)
	if err != nil {
		return Order{}, err
	}
	var wire struct {
		envelope
		wireOrder
	}
	if err := decode(raw, &wire, &wire.envelope); err != nil {
		return Order{}, err
	}
	order := wire.wireOrder.order()
	if order.ID == 0 {
		order.ID = orderID
	}
	return order, nil
}

// envelope is the "success"/"message" pair every BN Plus answer carries.
type envelope struct {
	Success *flexBool `json:"success"`
	Message string    `json:"message"`
}

// ok is whether the answer reports success. An answer without the flag is
// taken at its HTTP status (2xx), which is all a caller saw before it.
func (e envelope) ok() bool {
	return e.Success == nil || bool(*e.Success)
}

type wireOrder struct {
	OrderID       flexString `json:"order_id"`
	CardName      string     `json:"card_name"`
	CardType      flexString `json:"card_type"`
	Quantity      flexNumber `json:"quantity"`
	TotalPrice    flexNumber `json:"total_price"`
	Currency      string     `json:"currency"`
	Status        flexString `json:"status"`
	FailedMessage *string    `json:"failed_message"`
	Date          string     `json:"date"`
	// The order's "message" is read from the envelope: a field of the same
	// name here would make both invisible to encoding/json.
	Codes []struct {
		Code   flexString `json:"code"`
		Serial flexString `json:"serial"`
	} `json:"codes"`
}

func (w wireOrder) order() Order {
	order := Order{
		ID:         w.OrderID.Int64(),
		CardName:   strings.TrimSpace(w.CardName),
		CardType:   groupTypeName(string(w.CardType)),
		Quantity:   w.Quantity.Int(),
		TotalPrice: string(w.TotalPrice),
		Currency:   strings.ToUpper(strings.TrimSpace(w.Currency)),
		Status:     ParseStatus(string(w.Status)),
		Date:       parseTime(w.Date),
		Codes:      make([]Code, 0, len(w.Codes)),
	}
	if w.FailedMessage != nil {
		order.FailedMessage = strings.TrimSpace(*w.FailedMessage)
	}
	for _, code := range w.Codes {
		secret := strings.TrimSpace(string(code.Code))
		if secret == "" {
			continue
		}
		order.Codes = append(order.Codes, Code{Code: secret, Serial: strings.TrimSpace(string(code.Serial))})
	}
	return order
}

// ParseStatus reads an order status written as a word ("succeeded",
// "Receiving Codes Failed") or as BN Plus's number (0 submitted, 1 succeeded,
// 2 failed, 3 receiving codes failed). Anything else is kept, lower-cased.
func ParseStatus(raw string) Status {
	value := strings.ToLower(strings.TrimSpace(raw))
	value = strings.NewReplacer(" ", "_", "-", "_").Replace(value)
	switch value {
	case "0", "submitted", "pending":
		return StatusSubmitted
	case "1", "succeeded", "success", "successful", "completed":
		return StatusSucceeded
	case "2", "failed", "failure":
		return StatusFailed
	case "3", "receiving_codes_failed":
		return StatusReceivingCodesFailed
	}
	return Status(value)
}

func groupTypeName(raw string) string {
	value := strings.ToLower(strings.TrimSpace(raw))
	switch value {
	case "1":
		return "local"
	case "2":
		return "international"
	}
	return value
}

func decode(raw []byte, into any, env *envelope) error {
	if err := json.Unmarshal(raw, into); err != nil {
		return fmt.Errorf("bnplus: decode answer: %w", err)
	}
	if !env.ok() {
		return refusal(http.StatusOK, *env, 0)
	}
	return nil
}

func (c *Client) getWithRetry(ctx context.Context, op string, path string, query url.Values) ([]byte, error) {
	backoff := c.retryBackoff
	var lastErr error
	for attempt := 1; attempt <= maxReadAttempts; attempt++ {
		raw, err := c.do(ctx, op, http.MethodGet, path, query, nil)
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

func (c *Client) do(
	ctx context.Context,
	op string,
	method string,
	path string,
	query url.Values,
	body []byte,
) ([]byte, error) {
	callCtx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	// written turns true once the whole request has left: from then on BN
	// Plus may have acted on it, so a failure is an unknown outcome rather
	// than a refusal.
	var written atomic.Bool
	callCtx = httptrace.WithClientTrace(callCtx, &httptrace.ClientTrace{
		WroteRequest: func(info httptrace.WroteRequestInfo) {
			if info.Err == nil {
				written.Store(true)
			}
		},
	})
	endpoint := c.baseURL + "/api/merchant" + path
	if len(query) > 0 {
		endpoint += "?" + query.Encode()
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(callCtx, method, endpoint, reader)
	if err != nil {
		return nil, fmt.Errorf("bnplus: build request: %w", err)
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Bearer "+c.token)
	request.Header.Set("Api-Email", c.email)
	request.Header.Set("Api-Password", c.password)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := c.http.Do(request)
	if err != nil {
		return nil, &TransportError{Op: op, Err: err, Sent: written.Load()}
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return nil, &TransportError{Op: op, Err: err, Sent: true}
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return nil, decodeError(response.StatusCode, raw)
	}
	return raw, nil
}

// retryableRead is whether another attempt at a READ could go differently:
// the network, a 5xx, or a 429. Anything else will fail the same way again.
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

// ProviderError is BN Plus refusing a call: a non-2xx answer, or a 2xx whose
// body says "success": false. It unwraps to ErrUnauthorized,
// ErrInsufficientBalance or ErrOutOfStock when it is one of those.
type ProviderError struct {
	Status  int
	Message string
	// OrderID is set when the refusal still names an order: BN Plus created
	// one, so cards may yet be (or have been) bought on it.
	OrderID int64
	cause   error
}

func (e *ProviderError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "bnplus: HTTP %d", e.Status)
	if e.Message != "" {
		b.WriteString(": " + e.Message)
	}
	if e.OrderID != 0 {
		fmt.Fprintf(&b, " (order %d)", e.OrderID)
	}
	return b.String()
}

func (e *ProviderError) Unwrap() error { return e.cause }

// TransportError is a call that never produced a usable answer: a network
// failure, a timeout, or an unreadable body.
type TransportError struct {
	Op  string
	Err error
	// Sent is whether the whole request had left before the failure. A
	// purchase that was never sent cannot have bought anything.
	Sent bool
}

func (e *TransportError) Error() string {
	return "bnplus: " + e.Op + ": " + e.Err.Error()
}

func (e *TransportError) Unwrap() error { return e.Err }

// Definite is whether a failed BuyCard proves that nothing was bought: the
// request never left, or BN Plus refused it without creating an order. Every
// other failure — a timeout after sending, a 5xx, an unreadable answer, a
// refusal that names an order — may have bought the cards, and must be read
// back before the money is given back.
func Definite(err error) bool {
	if err == nil {
		return false
	}
	var transport *TransportError
	if errors.As(err, &transport) {
		return !transport.Sent
	}
	var provider *ProviderError
	if errors.As(err, &provider) {
		if provider.OrderID != 0 {
			return false
		}
		return provider.Status < 500
	}
	// Errors raised before any request (bad arguments) are definite too.
	return true
}

func decodeError(status int, raw []byte) error {
	var wire struct {
		envelope
		OrderID flexString                 `json:"order_id"`
		Errors  map[string]json.RawMessage `json:"errors"`
	}
	message := ""
	if err := json.Unmarshal(raw, &wire); err == nil {
		message = strings.TrimSpace(wire.Message)
		if detail := fieldErrors(wire.Errors); detail != "" {
			if message == "" {
				message = detail
			} else {
				message += " (" + detail + ")"
			}
		}
	} else {
		// Not their JSON (a proxy's HTML page, say): keep a slice of the text
		// so the operator sees what actually came back.
		message = strings.TrimSpace(string(raw))
	}
	if message == "" {
		message = http.StatusText(status)
	}
	wire.envelope.Message = message
	return refusal(status, wire.envelope, wire.OrderID.Int64())
}

func refusal(status int, env envelope, orderID int64) error {
	message := truncate(strings.TrimSpace(env.Message), maxErrorMessage)
	if message == "" {
		message = "refused"
	}
	err := &ProviderError{Status: status, Message: message, OrderID: orderID}
	switch {
	case status == http.StatusUnauthorized, status == http.StatusForbidden:
		err.cause = ErrUnauthorized
	case mentionsAny(message, "balance", "insufficient", "wallet", "رصيد", "المحفظة", "الرصيد"):
		err.cause = ErrInsufficientBalance
	case mentionsAny(message, "stock", "not available", "unavailable", "نفد", "نفذ", "غير متوفر", "غير متاح"):
		err.cause = ErrOutOfStock
	case mentionsAny(message, "unauthenticated", "unauthorized", "credentials", "بيانات الدخول"):
		err.cause = ErrUnauthorized
	}
	return err
}

func mentionsAny(message string, markers ...string) bool {
	lowered := strings.ToLower(message)
	for _, marker := range markers {
		if strings.Contains(lowered, marker) {
			return true
		}
	}
	return false
}

// fieldErrors flattens a Laravel validation answer's {"field": ["..."]}.
func fieldErrors(raw map[string]json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	parts := make([]string, 0, len(raw))
	for field, value := range raw {
		var list []string
		if err := json.Unmarshal(value, &list); err == nil {
			parts = append(parts, field+": "+strings.Join(list, "; "))
			continue
		}
		var single string
		if err := json.Unmarshal(value, &single); err == nil {
			parts = append(parts, field+": "+single)
			continue
		}
		parts = append(parts, field+": "+strings.TrimSpace(string(value)))
	}
	// Map order is random; sort so the same refusal reads the same in logs.
	sortStrings(parts)
	return strings.Join(parts, ", ")
}

func sortStrings(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
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
			return fmt.Errorf("bnplus: %q is not a number", text)
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

func (n flexNumber) Int() int {
	if value, err := strconv.Atoi(string(n)); err == nil {
		return value
	}
	value, err := strconv.ParseFloat(string(n), 64)
	if err != nil {
		return 0
	}
	return int(value)
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
		*s = flexString(strings.TrimSpace(text))
		return nil
	}
	*s = flexString(trimmed)
	return nil
}

func (s flexString) Int64() int64 {
	value, err := strconv.ParseInt(strings.TrimSpace(string(s)), 10, 64)
	if err != nil {
		return 0
	}
	return value
}

// flexBool reads true/false, 1/0 and "1"/"0" alike: BN Plus writes in_stock
// as a number.
type flexBool bool

func (b *flexBool) UnmarshalJSON(data []byte) error {
	value := strings.ToLower(strings.Trim(strings.TrimSpace(string(data)), `"`))
	switch value {
	case "true", "1", "yes":
		*b = true
	case "false", "0", "no", "", "null":
		*b = false
	default:
		if number, err := strconv.ParseFloat(value, 64); err == nil {
			*b = number != 0
			return nil
		}
		return fmt.Errorf("bnplus: %q is not a boolean", value)
	}
	return nil
}

// parseTime reads BN Plus's timestamps. A zone-less timestamp is taken as
// Libyan time (UTC+2, no daylight saving), which is how its portal shows them.
func parseTime(raw string) time.Time {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return time.Time{}
	}
	for _, layout := range []string{
		time.RFC3339Nano,
		"2006-01-02T15:04:05.999999999Z0700",
		"2006-01-02 15:04:05.999999999Z07:00",
	} {
		if parsed, err := time.Parse(layout, raw); err == nil {
			return parsed.UTC()
		}
	}
	for _, layout := range []string{
		"2006-01-02T15:04:05.999999999",
		"2006-01-02 15:04:05.999999999",
		"2006-01-02 15:04",
	} {
		if parsed, err := time.ParseInLocation(layout, raw, libya); err == nil {
			return parsed.UTC()
		}
	}
	return time.Time{}
}

var libya = time.FixedZone("EET", 2*60*60)

func truncate(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit]) + "…"
}
