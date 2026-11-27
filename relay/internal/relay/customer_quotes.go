package relay

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// Price quotes of «دفتر كروت»:
//
//	POST /v1/customers/me/quote   {item, channel}: the price an order placed now is charged (Bearer)
//
// Dollar cards follow a moving exchange rate, so the price on the shelf can be
// minutes or hours old by the time a customer taps «ادفع». The checkout asks
// for a quote when it opens and shows that price; the order carries the quote
// back and is charged it, whatever the live price did since, within bounds:
//
//   - A quote lives customerQuoteTTL. Past that the order falls back to the
//     shown price having to match the live one.
//   - The live price may have risen up to customerQuoteMaxRise above the
//     quote; beyond that (a shock) the quote is void and the customer is
//     asked again, with a fresh quote in the refusal.
//   - A price that fell is charged at the lower live price: a quote never
//     makes anyone pay more than the card costs now.
//
// A quote is an HMAC-signed token, not a stored row: any relay node can check
// it, and a forged or edited one is refused like a missing one. It names its
// customer and item, so it cannot be shared or moved to another card. The
// worst a leaked signing key could buy is customerQuoteMaxRise off one card.
//
// This is the pattern of Stripe's FX Quotes (a rate locked for a set time,
// voided by a move above 3.5%) and of crypto on-ramps' expiring quotes.

const (
	customerQuoteTTL = 10 * time.Minute
	// customerQuoteSkew forgives a quote that expired a moment before the
	// order reached the relay (a slow network, another node's clock).
	customerQuoteSkew = 30 * time.Second
	customerQuoteKind = "pointy-relay-customer-quote-v1"
)

// customerQuoteMaxRise is how far above a quote the live price may be and the
// quote still be honoured: 3%, under the cards' 8–10% margin.
var customerQuoteMaxRise = big.NewRat(3, 100)

// customerQuoteClaims is what a quote says, signed.
type customerQuoteClaims struct {
	Customer string `json:"c"`
	Item     string `json:"i"`
	Price    string `json:"p"`
	Issued   int64  `json:"t"`
	Expires  int64  `json:"e"`
}

var (
	ephemeralQuoteKeyOnce sync.Once
	ephemeralQuoteKey     []byte
)

// customerQuoteKey signs quotes: derived from the admin token every node of a
// relay shares. A relay with no admin token (development) signs with a key of
// its own process.
func (s HTTPServer) customerQuoteKey() []byte {
	secret := strings.TrimSpace(s.AdminToken)
	if secret == "" {
		ephemeralQuoteKeyOnce.Do(func() {
			ephemeralQuoteKey = make([]byte, 32)
			_, _ = rand.Read(ephemeralQuoteKey)
		})
		return ephemeralQuoteKey
	}
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(customerQuoteKind))
	return mac.Sum(nil)
}

// issueCustomerQuote signs price for this customer and item, from now.
func (s HTTPServer) issueCustomerQuote(customerID, item string, price *big.Rat, now time.Time) (string, time.Time) {
	expires := now.Add(customerQuoteTTL)
	payload, _ := json.Marshal(customerQuoteClaims{
		Customer: customerID,
		Item:     item,
		Price:    control.FormatWalletAmount(price),
		Issued:   now.Unix(),
		Expires:  expires.Unix(),
	})
	mac := hmac.New(sha256.New, s.customerQuoteKey())
	_, _ = mac.Write(payload)
	return base64.RawURLEncoding.EncodeToString(payload) + "." +
		base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), expires
}

// readCustomerQuote is the price a quote token holds, when it is this
// customer's, for this item, signed by this relay and still alive.
func (s HTTPServer) readCustomerQuote(token, customerID, item string, now time.Time) (*big.Rat, bool) {
	payloadPart, macPart, found := strings.Cut(strings.TrimSpace(token), ".")
	if !found || payloadPart == "" || macPart == "" {
		return nil, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(payloadPart)
	if err != nil {
		return nil, false
	}
	signature, err := base64.RawURLEncoding.DecodeString(macPart)
	if err != nil {
		return nil, false
	}
	mac := hmac.New(sha256.New, s.customerQuoteKey())
	_, _ = mac.Write(payload)
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return nil, false
	}
	var claims customerQuoteClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil, false
	}
	if claims.Customer != customerID || claims.Item != item ||
		now.After(time.Unix(claims.Expires, 0).Add(customerQuoteSkew)) {
		return nil, false
	}
	price, err := control.ParseWalletAmount(claims.Price)
	if err != nil || price.Sign() <= 0 {
		return nil, false
	}
	return price, true
}

// customerOrderPrice is the unit price an order is charged, given the live
// price now and what the app sent: a live quote (honoured within bounds),
// else the price it showed, which must not be below the live one. ok is
// false when the price went up past what the customer agreed to.
func (s HTTPServer) customerOrderPrice(customerID, item, quote, shown string, live *big.Rat, now time.Time) (*big.Rat, bool) {
	if quoted, ok := s.readCustomerQuote(quote, customerID, item, now); ok {
		if live.Cmp(quoted) <= 0 {
			return live, true
		}
		limit := new(big.Rat).Mul(quoted, new(big.Rat).Add(big.NewRat(1, 1), customerQuoteMaxRise))
		if live.Cmp(limit) <= 0 {
			return quoted, true
		}
		return nil, false
	}
	// No live quote (an app from before quotes, or one kept too long): the
	// price shown stands when the card costs that or less now.
	if agreed, err := control.ParseWalletAmount(shown); err == nil && live.Cmp(agreed) <= 0 {
		return live, true
	}
	return nil, false
}

// writeCustomerPriceChanged refuses an order whose price went up, with the
// new price and a fresh quote for it: the app shows it, and the customer's
// next tap places the order at that price.
func (s HTTPServer) writeCustomerPriceChanged(w http.ResponseWriter, customerID, item string, live *big.Rat, now time.Time) {
	quote, expires := s.issueCustomerQuote(customerID, item, live, now)
	writeCustomerError(w, http.StatusConflict, "price_changed", "the price changed; check it and try again",
		map[string]any{
			"unit_price":       control.FormatWalletAmount(live),
			"quote":            quote,
			"quote_expires_at": expires.UTC(),
		})
}

type customerQuoteRequest struct {
	Item    string `json:"item"`
	Channel string `json:"channel"`
}

// handleCustomerQuote serves POST /v1/customers/me/quote.
func (s HTTPServer) handleCustomerQuote(w http.ResponseWriter, r *http.Request, customer control.Customer) {
	cards, ok := s.customerVoucherStore(w)
	if !ok {
		return
	}
	var request customerQuoteRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	request.Item = strings.TrimSpace(request.Item)
	request.Channel = strings.TrimSpace(request.Channel)
	switch {
	case request.Item == "":
		writeCustomerError(w, http.StatusBadRequest, "invalid_request", "item is required", nil)
		return
	case !validCustomerChannel(request.Channel):
		writeCustomerError(w, http.StatusBadRequest, "invalid_channel",
			"channel must be one of "+strings.Join(customerChannels, ", "), nil)
		return
	}
	priced, refusal := s.priceCustomerItem(r.Context(), customer, cards, request.Item, 1, request.Channel)
	if refusal != nil {
		writeCustomerError(w, refusal.status, refusal.code, refusal.message, refusal.extra)
		return
	}
	now := s.clock().Now()
	quote, expires := s.issueCustomerQuote(customer.ID, priced.itemKey, priced.price, now)
	writeJSON(w, http.StatusOK, map[string]any{
		"item":        priced.itemKey,
		"unit_price":  control.FormatWalletAmount(priced.price),
		"quote":       quote,
		"expires_at":  expires.UTC(),
		"ttl_seconds": int(customerQuoteTTL / time.Second),
	})
}

// customerPricedItem is what an order or a quote is for, and its live price.
type customerPricedItem struct {
	itemKey, brandKey, itemName string
	// category scopes an offer: the card's, or "esim".
	category string
	price    *big.Rat
	sandbox  bool
	esim     bool
	// located is the card, for reading the account it is sent to.
	located vouchers.Located
}

type customerRefusal struct {
	status        int
	code, message string
	extra         map[string]any
}

// priceCustomerItem finds what item is (a card of the shelf, or an eSIM
// plan) and what it costs now, or why it cannot be bought.
func (s HTTPServer) priceCustomerItem(
	ctx context.Context,
	customer control.Customer,
	cards control.VoucherStore,
	item string,
	quantity int,
	channel string,
) (customerPricedItem, *customerRefusal) {
	// The stores' review account buys for show: see customer_review.go.
	review := s.Customers.isReviewPhone(customer.Phone)
	if parsed, isESIM := parseESIMItem(item); isESIM {
		if quantity != 1 {
			return customerPricedItem{}, &customerRefusal{http.StatusBadRequest, "invalid_quantity",
				"an eSIM is ordered one at a time", map[string]any{"max_quantity": 1}}
		}
		if !s.esimOpenTo(customer) {
			return customerPricedItem{}, &customerRefusal{http.StatusConflict, "item_unavailable",
				"this eSIM cannot be bought right now", nil}
		}
		quote, status, failure := s.quoteESIMOrder(ctx, customer, parsed)
		if failure != "" {
			return customerPricedItem{}, &customerRefusal{status, failure, "this eSIM cannot be bought right now", nil}
		}
		return customerPricedItem{
			itemKey: item, brandKey: esimOrderBrand(quote.Details.Country), itemName: quote.Name,
			category: control.CustomerOfferESIM, price: quote.Price, esim: true,
			// Only Airalo has a Sandbox; a plan bought from eSIM Access is real.
			sandbox: s.ESIM.Sandbox && (quote.Details.Supplier == "" || quote.Details.Supplier == vouchers.SupplierAiralo),
		}, nil
	}
	located, ranking, failure := s.locateCustomerCard(ctx, cards, item, review)
	if failure != "" {
		status := http.StatusConflict
		if failure == "unknown_item" {
			status = http.StatusNotFound
		}
		return customerPricedItem{}, &customerRefusal{status, failure, "this card cannot be bought right now", nil}
	}
	brand := shelfBrand{Key: located.Brand.Key, Category: located.Brand.Category, Target: located.Brand.Target}
	if _, sell := s.Customers.shelf(channel, brand, s.mobileGiftCards(ctx)); !sell {
		return customerPricedItem{}, &customerRefusal{http.StatusNotFound, "unknown_item", "this card is not sold in this app", nil}
	}
	if reason, _ := ranking.unavailable(); reason != "" {
		return customerPricedItem{}, &customerRefusal{http.StatusConflict, "item_unavailable", "this card cannot be bought right now", nil}
	}
	price, err := control.ParseWalletAmount(vouchers.PriceAt(located.Item, s.clock().Now()).RetailPrice)
	if err != nil || price.Sign() <= 0 {
		return customerPricedItem{}, &customerRefusal{http.StatusConflict, "item_unavailable", "this card has no price right now", nil}
	}
	return customerPricedItem{
		itemKey: located.Item.Key, brandKey: located.Brand.Key, itemName: located.Name(),
		category: located.Brand.Category, price: price, located: located,
	}, nil
}
