package fazer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
)

var timeAfter = time.After

// Status is where an order stands.
type Status string

const (
	// StatusProcessing: charged, not fulfilled yet. Read it again.
	StatusProcessing Status = "processing"
	// StatusCompleted: fulfilled; a code order carries its codes.
	StatusCompleted Status = "completed"
	// StatusRefunded: it failed and the balance was given back.
	StatusRefunded Status = "refunded"
)

// ParseStatus reads the API's word for an order's state. The spec documents
// only "processing", "completed" and "refund"; a real order also starts as
// "created". Anything not plainly finished is taken as still processing, so
// nothing is refunded on a word this client does not know.
func ParseStatus(raw string) Status {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "completed", "complete", "success", "succeeded", "done", "delivered", "fulfilled":
		return StatusCompleted
	case "refund", "refunded", "cancelled", "canceled", "failed", "rejected", "error":
		return StatusRefunded
	}
	return StatusProcessing
}

// Code is one delivered secret: a gift card code, a game key.
type Code struct {
	Code string
	// Serial is a second part the customer needs (a PIN), or a link to redeem at.
	Serial string
}

// Order is the API's record of one order. The spec leaves it untyped, so it is
// read field by field under every spelling seen in the API's own vocabulary,
// and kept whole in Raw.
type Order struct {
	ID     string
	Status Status
	// RawStatus is the status as the API wrote it.
	RawStatus string
	// CostUSD is what the order charged, when the API says (dollars).
	CostUSD string
	// IdempotencyKey is the key the order was placed with, when the API
	// echoes it.
	IdempotencyKey string
	Codes          []Code
	Message        string
	CreatedAt      time.Time
	Raw            json.RawMessage
}

// ParseOrder reads one order object.
func ParseOrder(raw json.RawMessage) (Order, error) {
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err != nil || object == nil {
		return Order{}, errors.New("fazer: an order is not a JSON object")
	}
	order := Order{Raw: append(json.RawMessage(nil), raw...)}
	order.ID = textOf(object, "id", "order_id", "orderId", "public_id", "publicId")
	order.RawStatus = textOf(object, "status", "state")
	order.Status = ParseStatus(order.RawStatus)
	// A real order (2026-11-03) carries total_usd and price_usd_per_unit: the
	// total comes first, so an order of several codes is costed whole.
	order.CostUSD = textOf(object, "total_usd", "totalUsd", "charged_usd", "chargedUsd", "amount_usd", "amountUsd",
		"cost_usd", "costUsd", "price_usd", "priceUsd", "total", "price")
	// Neither an order nor the history echoes the key it was placed with (seen
	// 2026-11-03); the spellings stay in case it ever does.
	order.IdempotencyKey = textOf(object, "idempotency_key", "idempotencyKey", "client_ref", "clientRef")
	order.Message = textOf(object, "fail_reason", "failReason", "error", "message", "refund_reason", "refundReason",
		"reason", "note")
	if at := textOf(object, "created_at", "createdAt"); at != "" {
		if parsed, err := time.Parse(time.RFC3339Nano, at); err == nil {
			order.CreatedAt = parsed
		}
	}
	for _, key := range []string{"cards", "codes", "keys", "items", "gamekeys", "game_keys", "giftcards", "gift_cards"} {
		if codes := codesOf(object[key]); len(codes) > 0 {
			order.Codes = codes
			break
		}
	}
	return order, nil
}

// textOf is the first of keys present as non-empty text.
func textOf(object map[string]json.RawMessage, keys ...string) string {
	for _, key := range keys {
		raw, ok := object[key]
		if !ok {
			continue
		}
		var t Text
		if err := t.UnmarshalJSON(raw); err != nil {
			continue
		}
		if value := strings.TrimSpace(t.String()); value != "" && value != "true" && value != "false" {
			return value
		}
	}
	return ""
}

// codesOf reads a list of codes: plain strings, or objects naming the code
// and maybe a PIN or a link.
func codesOf(raw json.RawMessage) []Code {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || raw[0] != '[' {
		return nil
	}
	var entries []json.RawMessage
	if err := json.Unmarshal(raw, &entries); err != nil {
		return nil
	}
	var codes []Code
	for _, entry := range entries {
		entry = bytes.TrimSpace(entry)
		if len(entry) == 0 {
			continue
		}
		if entry[0] == '"' {
			var s string
			if json.Unmarshal(entry, &s) == nil && strings.TrimSpace(s) != "" {
				codes = append(codes, Code{Code: strings.TrimSpace(s)})
			}
			continue
		}
		var object map[string]json.RawMessage
		if json.Unmarshal(entry, &object) != nil {
			continue
		}
		code := textOf(object, "code", "key", "card_number", "cardNumber", "activation_key", "activationKey",
			"cdk", "value", "serial_number", "serialNumber")
		pin := textOf(object, "pin", "pin_code", "pinCode", "password", "secret")
		link := textOf(object, "redeem_url", "redeemUrl", "redemption_url", "redemptionUrl", "url", "link")
		switch {
		case code != "":
			second := pin
			if second == "" {
				second = link
			}
			codes = append(codes, Code{Code: code, Serial: second})
		case pin != "":
			codes = append(codes, Code{Code: pin, Serial: link})
		case link != "":
			codes = append(codes, Code{Code: link})
		}
	}
	return codes
}

func (c *Client) placeOrder(ctx context.Context, op, path string, body any, key string) (Order, error) {
	if err := checkKey(key); err != nil {
		return Order{}, err
	}
	var answer struct {
		Order json.RawMessage `json:"order"`
	}
	if err := c.post(ctx, op, path, body, strings.TrimSpace(key), &answer); err != nil {
		return Order{}, err
	}
	order, err := ParseOrder(answer.Order)
	if err != nil {
		// Charged, perhaps: the answer came but cannot be read.
		return Order{}, &TransportError{Op: op, Err: err, Sent: true}
	}
	return order, nil
}

// OrderTopup tops up an account: categoryID and offerID name one offer of
// TopupOffers, values the buyer's fields by key.
func (c *Client) OrderTopup(ctx context.Context, categoryID, offerID string, values map[string]string, key string) (Order, error) {
	if strings.TrimSpace(categoryID) == "" || strings.TrimSpace(offerID) == "" {
		return Order{}, errors.New("fazer: a top-up needs a category and an offer")
	}
	return c.placeOrder(ctx, "order a top-up", "/topups/order", map[string]any{
		"category_id": strings.TrimSpace(categoryID), "offer_id": strings.TrimSpace(offerID), "fields": values,
	}, key)
}

// OrderGiftCards buys quantity codes of one gift card offer.
func (c *Client) OrderGiftCards(ctx context.Context, categoryID, cardID string, quantity int, key string) (Order, error) {
	if strings.TrimSpace(categoryID) == "" || strings.TrimSpace(cardID) == "" {
		return Order{}, errors.New("fazer: a gift card order needs a category and a card")
	}
	if quantity < 1 || quantity > MaxQuantity {
		return Order{}, fmt.Errorf("fazer: quantity must be 1 to %d", MaxQuantity)
	}
	return c.placeOrder(ctx, "order gift cards", "/giftcards/order", map[string]any{
		"category_id": strings.TrimSpace(categoryID), "card_id": strings.TrimSpace(cardID), "quantity": quantity,
	}, key)
}

// OrderGameKeys buys quantity keys of one game key offer.
func (c *Client) OrderGameKeys(ctx context.Context, gameID, keyID string, quantity int, key string) (Order, error) {
	if strings.TrimSpace(gameID) == "" || strings.TrimSpace(keyID) == "" {
		return Order{}, errors.New("fazer: a game key order needs a game and a key")
	}
	if quantity < 1 || quantity > MaxQuantity {
		return Order{}, fmt.Errorf("fazer: quantity must be 1 to %d", MaxQuantity)
	}
	return c.placeOrder(ctx, "order game keys", "/gamekeys/order", map[string]any{
		"game_id": strings.TrimSpace(gameID), "key_id": strings.TrimSpace(keyID), "quantity": quantity,
	}, key)
}

// BuyTelegramStars sends quantity stars (50 to 100000) to a username.
func (c *Client) BuyTelegramStars(ctx context.Context, username string, quantity int, key string) (Order, error) {
	username = strings.TrimSpace(username)
	if username == "" {
		return Order{}, errors.New("fazer: a Telegram username is required")
	}
	if quantity < 50 || quantity > 100000 {
		return Order{}, errors.New("fazer: Telegram Stars are sold 50 to 100000 at a time")
	}
	return c.placeOrder(ctx, "buy Telegram Stars", "/telegram/stars/buy", map[string]any{
		"telegram_username": username, "quantity": quantity,
	}, key)
}

// BuyTelegramPremium gives a username Telegram Premium for 3, 6 or 12 months.
func (c *Client) BuyTelegramPremium(ctx context.Context, username string, months int, key string) (Order, error) {
	username = strings.TrimSpace(username)
	if username == "" {
		return Order{}, errors.New("fazer: a Telegram username is required")
	}
	if months != 3 && months != 6 && months != 12 {
		return Order{}, errors.New("fazer: Telegram Premium is sold for 3, 6 or 12 months")
	}
	return c.placeOrder(ctx, "buy Telegram Premium", "/telegram/premium/buy", map[string]any{
		"telegram_username": username, "months": months,
	}, key)
}

// OrderSteamTopup tops up a Steam wallet: amount in currency (USD with at
// most two decimals; RUB, UAH or KZT with at most four).
func (c *Client) OrderSteamTopup(ctx context.Context, login, currency, amount, key string) (Order, error) {
	login = strings.TrimSpace(login)
	currency = strings.ToUpper(strings.TrimSpace(currency))
	amount = strings.TrimSpace(amount)
	switch {
	case login == "":
		return Order{}, errors.New("fazer: a Steam login is required")
	case currency != "USD" && currency != "RUB" && currency != "UAH" && currency != "KZT":
		return Order{}, errors.New("fazer: a Steam top-up is ordered in USD, RUB, UAH or KZT")
	case amount == "":
		return Order{}, errors.New("fazer: a Steam top-up needs an amount")
	}
	return c.placeOrder(ctx, "order a Steam top-up", "/steam-topup/order", map[string]any{
		"steamLogin": login, "currency": currency, "amount": amount,
	}, key)
}

// OrderSteamGift sends edition subID of Steam app appID, bought in region
// ("MENA"), as a gift to the account behind a friend invite link
// (https://s.team/p/…).
func (c *Client) OrderSteamGift(ctx context.Context, inviteURL string, appID, subID int64, region, key string) (Order, error) {
	inviteURL = strings.TrimSpace(inviteURL)
	region = strings.ToUpper(strings.TrimSpace(region))
	switch {
	case inviteURL == "":
		return Order{}, errors.New("fazer: a Steam friend invite link is required")
	case appID <= 0 || subID <= 0:
		return Order{}, errors.New("fazer: a Steam gift needs the game's app id and the edition's sub id")
	case region == "":
		return Order{}, errors.New("fazer: a Steam gift needs a region")
	}
	return c.placeOrder(ctx, "order a Steam gift", "/steam-gifts/order", map[string]any{
		"invite_url": inviteURL, "app_id": appID, "sub_id": subID, "region": region,
	}, key)
}

// Order reads one order by its public id ("ord-1").
func (c *Client) Order(ctx context.Context, orderID string) (Order, error) {
	orderID = strings.TrimSpace(orderID)
	if orderID == "" {
		return Order{}, errors.New("fazer: an order id is required")
	}
	var answer struct {
		Order json.RawMessage `json:"order"`
	}
	if err := c.get(ctx, "read an order", "/orders/"+url.PathEscape(orderID), nil, &answer); err != nil {
		return Order{}, err
	}
	order, err := ParseOrder(answer.Order)
	if err != nil {
		return Order{}, &TransportError{Op: "read an order", Err: err, Sent: true}
	}
	if order.ID == "" {
		order.ID = orderID
	}
	return order, nil
}

// Orders reads one page of the order history (newest first, as the API lists
// it), limit at most 100, and the total count.
func (c *Client) Orders(ctx context.Context, page, limit int) ([]Order, int, error) {
	if page < 1 {
		page = 1
	}
	if limit < 1 || limit > 100 {
		limit = 100
	}
	var answer struct {
		Items []json.RawMessage `json:"items"`
		Total Count             `json:"total"`
	}
	query := url.Values{"page": {strconv.Itoa(page)}, "limit": {strconv.Itoa(limit)}}
	if err := c.get(ctx, "list orders", "/orders", query, &answer); err != nil {
		return nil, 0, err
	}
	orders := make([]Order, 0, len(answer.Items))
	for _, raw := range answer.Items {
		if order, err := ParseOrder(raw); err == nil {
			orders = append(orders, order)
		}
	}
	return orders, int(answer.Total), nil
}
