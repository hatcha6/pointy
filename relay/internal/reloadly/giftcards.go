package reloadly

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

// MaxIdentifierLength is the longest customIdentifier / referenceId Reloadly
// accepts (a longer one is refused with INVALID_INPUT_PROVIDED).
const MaxIdentifierLength = 150

// giftCodesAccept is the v2 form of the redeem-code answer, which splits the
// redemption URL from the card number; v1 puts either in cardNumber.
const giftCodesAccept = "application/com.reloadly.giftcards-v2+json"

// GiftProduct is one row of Reloadly's gift card catalog: a brand's card in one
// country, with how it is priced for the company's USD account.
//
// A card is ordered by its RECIPIENT denomination (the face value, in
// RecipientCurrencyCode) and charged to the account in USD: see GiftCost for the
// formula and cost.go for the limits of the published rate.
type GiftProduct struct {
	ID               int64  `json:"productId"`
	Name             string `json:"productName"`
	Global           bool   `json:"global"`
	Status           string `json:"status"`
	SupportsPreOrder bool   `json:"supportsPreOrder"`

	// SenderFee is a flat fee per card, in the account currency.
	SenderFee Num `json:"senderFee"`
	// SenderFeePercentage and DiscountPercentage are percentages of the card's
	// price in the account currency.
	SenderFeePercentage Num `json:"senderFeePercentage"`
	DiscountPercentage  Num `json:"discountPercentage"`

	DenominationType      DenominationType `json:"denominationType"`
	RecipientCurrencyCode string           `json:"recipientCurrencyCode"`
	SenderCurrencyCode    string           `json:"senderCurrencyCode"`
	// RecipientToSenderRate is how many units of the account currency one unit of
	// the recipient currency costs, rounded to six decimals by Reloadly.
	RecipientToSenderRate Num `json:"recipientCurrencyToSenderCurrencyExchangeRate"`

	// RANGE products: any amount between the recipient bounds.
	MinRecipientDenomination Num `json:"minRecipientDenomination"`
	MaxRecipientDenomination Num `json:"maxRecipientDenomination"`
	MinSenderDenomination    Num `json:"minSenderDenomination"`
	MaxSenderDenomination    Num `json:"maxSenderDenomination"`

	// FIXED products: the face values, and what each costs in the account
	// currency rounded to cents (FixedRecipientToSender is keyed by the face
	// value as Reloadly writes it, "25.0").
	FixedRecipientDenominations []Num          `json:"fixedRecipientDenominations"`
	FixedSenderDenominations    []Num          `json:"fixedSenderDenominations"`
	FixedRecipientToSender      map[string]Num `json:"fixedRecipientToSenderDenominationsMap"`

	// Metadata names some fixed denominations ({"0.99": "55 Diamonds"}).
	Metadata Labels `json:"metadata"`

	LogoURLs          []string          `json:"logoUrls"`
	Brand             GiftBrand         `json:"brand"`
	Category          GiftCategory      `json:"category"`
	Country           Country           `json:"country"`
	RedeemInstruction RedeemInstruction `json:"redeemInstruction"`
	// AdditionalRequirements.UserIDRequired products need a user id on the order.
	AdditionalRequirements struct {
		UserIDRequired bool `json:"userIdRequired"`
	} `json:"additionalRequirements"`
}

// GiftBrand is a gift card brand (Amazon, PlayStation…).
type GiftBrand struct {
	ID      int64  `json:"brandId"`
	Name    string `json:"brandName"`
	LogoURL string `json:"logoUrl,omitempty"`
}

// GiftCategory is a catalog category (Gaming, Shopping…).
type GiftCategory struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// RedeemInstruction is how the customer redeems the card.
type RedeemInstruction struct {
	Concise string `json:"concise"`
	Verbose string `json:"verbose"`
}

// GiftPhone is a recipient phone for a gift card order. Sending one makes
// Reloadly charge an SMS fee (about $0.008 in the sandbox), so the relay does
// not.
type GiftPhone struct {
	CountryCode string `json:"countryCode"`
	PhoneNumber string `json:"phoneNumber"`
}

// GiftOrderRequest is one gift card order.
type GiftOrderRequest struct {
	ProductID int64
	// Quantity is the number of cards; the fee and discount apply to each.
	Quantity int
	// UnitPrice is the face value of ONE card in the product's recipient
	// currency: one of FixedRecipientDenominations, or an amount within the
	// RANGE bounds (cents and more decimals are accepted).
	UnitPrice Num
	// CustomIdentifier is unique to the purchase, at most MaxIdentifierLength
	// characters. Reloadly records it on every accepted order and answers
	// CUSTOM_IDENTIFIER_ALREADY_USED to a second one — but only to a second
	// one that comes after the first has been accepted.
	CustomIdentifier string
	// SenderName is printed on the receipt. The sandbox does not enforce it;
	// the documentation says it is required, so it is.
	SenderName string
	// RecipientEmail makes Reloadly email the code to the customer. Empty: no
	// email.
	RecipientEmail string
	RecipientPhone *GiftPhone
	// ProductUserID is the account id some products (userIdRequired) need.
	ProductUserID string
	PreOrder      bool
}

type giftOrderWire struct {
	ProductID                     int64            `json:"productId"`
	Quantity                      int              `json:"quantity"`
	UnitPrice                     Num              `json:"unitPrice"`
	CustomIdentifier              string           `json:"customIdentifier"`
	SenderName                    string           `json:"senderName"`
	RecipientEmail                string           `json:"recipientEmail,omitempty"`
	RecipientPhoneDetails         *GiftPhone       `json:"recipientPhoneDetails,omitempty"`
	ProductAdditionalRequirements *giftRequirement `json:"productAdditionalRequirements,omitempty"`
	PreOrder                      bool             `json:"preOrder,omitempty"`
}

type giftRequirement struct {
	UserID string `json:"userId"`
}

func (r GiftOrderRequest) wire() (giftOrderWire, error) {
	if r.ProductID <= 0 {
		return giftOrderWire{}, fmt.Errorf("%w: a product id is required", ErrInvalidRequest)
	}
	if r.Quantity < 1 {
		return giftOrderWire{}, fmt.Errorf("%w: quantity must be at least 1", ErrInvalidRequest)
	}
	if err := requirePositive("unit price", r.UnitPrice); err != nil {
		return giftOrderWire{}, err
	}
	if err := requireIdentifier("customIdentifier", r.CustomIdentifier); err != nil {
		return giftOrderWire{}, err
	}
	if strings.TrimSpace(r.SenderName) == "" {
		return giftOrderWire{}, fmt.Errorf("%w: a sender name is required", ErrInvalidRequest)
	}
	wire := giftOrderWire{
		ProductID:             r.ProductID,
		Quantity:              r.Quantity,
		UnitPrice:             r.UnitPrice,
		CustomIdentifier:      r.CustomIdentifier,
		SenderName:            strings.TrimSpace(r.SenderName),
		RecipientEmail:        strings.TrimSpace(r.RecipientEmail),
		RecipientPhoneDetails: r.RecipientPhone,
		PreOrder:              r.PreOrder,
	}
	if id := strings.TrimSpace(r.ProductUserID); id != "" {
		wire.ProductAdditionalRequirements = &giftRequirement{UserID: id}
	}
	return wire, nil
}

// GiftTransaction is a gift card order as Reloadly records it: the answer to an
// order, a row of the transaction report, or one transaction read back.
type GiftTransaction struct {
	TransactionID int64 `json:"transactionId"`
	// Amount is what the order cost the account in CurrencyCode, fees included
	// and discount taken off, rounded to five decimals: the same number as
	// Balance.Cost on a completed order.
	Amount Num `json:"amount"`
	// Discount, Fee, SMSFee and TotalFee are in CurrencyCode and rounded to
	// cents by Reloadly: informational. Fee is the flat fee plus the percentage
	// fee; TotalFee adds the SMS fee.
	Discount         Num    `json:"discount"`
	Fee              Num    `json:"fee"`
	SMSFee           Num    `json:"smsFee"`
	TotalFee         Num    `json:"totalFee"`
	CurrencyCode     string `json:"currencyCode"`
	PreOrdered       bool   `json:"preOrdered"`
	RecipientEmail   string `json:"recipientEmail"`
	RecipientPhone   Text   `json:"recipientPhone"`
	CustomIdentifier string `json:"customIdentifier"`
	// Status: SUCCESSFUL, or PROCESSING for products that are issued on demand
	// (sandbox: virtual prepaid cards settle within ~20 s).
	Status Status `json:"status"`
	// CreatedAt is the order time (UTC).
	CreatedAt Time             `json:"transactionCreatedTime"`
	Product   GiftOrderProduct `json:"product"`
	Balance   BalanceInfo      `json:"balanceInfo"`
}

// GiftOrder is the answer to OrderGiftCard: the same record the reports return.
type GiftOrder = GiftTransaction

// GiftOrderProduct is the product block of an order. UnitPrice and TotalPrice
// are in the recipient currency (CurrencyCode).
type GiftOrderProduct struct {
	ProductID    int64     `json:"productId"`
	ProductName  string    `json:"productName"`
	CountryCode  string    `json:"countryCode"`
	Quantity     int       `json:"quantity"`
	UnitPrice    Num       `json:"unitPrice"`
	TotalPrice   Num       `json:"totalPrice"`
	CurrencyCode string    `json:"currencyCode"`
	Brand        GiftBrand `json:"brand"`
}

// UnmarshalJSON also reads the balance block under "balaneInfo", the spelling
// in Reloadly's published schema (the sandbox writes "balanceInfo").
func (t *GiftTransaction) UnmarshalJSON(data []byte) error {
	type plain GiftTransaction
	aux := struct {
		*plain
		Misspelled *BalanceInfo `json:"balaneInfo"`
	}{plain: (*plain)(t)}
	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}
	if aux.Misspelled != nil && t.Balance == (BalanceInfo{}) {
		t.Balance = *aux.Misspelled
	}
	return nil
}

// GiftCode is one purchased card, as the v2 redeem-code answer gives it.
// CardNumber and RedemptionURL are alternatives: a card is a code or a link.
type GiftCode struct {
	CardNumber    Text `json:"cardNumber"`
	PinCode       Text `json:"pinCode"`
	RedemptionURL Text `json:"redemptionUrl"`
}

// Products reads the whole gift card catalog (all pages).
func (c *Client) Products(ctx context.Context) ([]GiftProduct, error) {
	r := c.get(c.gift, "list gift products", "/products", nil)
	return listAll(ctx, c, r, func(p *GiftProduct) string { return idKey(p.ID) })
}

// Product reads one product.
func (c *Client) Product(ctx context.Context, id int64) (GiftProduct, error) {
	if id <= 0 {
		return GiftProduct{}, fmt.Errorf("%w: a product id is required", ErrInvalidRequest)
	}
	r := c.get(c.gift, "read gift product", "/products/"+strconv.FormatInt(id, 10), nil)
	raw, err := c.do(ctx, r)
	if err != nil {
		return GiftProduct{}, err
	}
	var product GiftProduct
	if err := decode(r, raw, &product); err != nil {
		return GiftProduct{}, err
	}
	return product, nil
}

// OrderGiftCard buys gift cards from the company's balance.
//
// It makes exactly ONE attempt and never retries: a retry after a lost answer
// could buy the cards twice, because Reloadly's duplicate check on
// CustomIdentifier is not atomic. A failure is returned as it is; Definite says
// whether nothing can have been bought, and anything else must be read back with
// FindGiftTransactions before the money is given back. A PROCESSING order is a
// success so far: poll GiftTransaction until it is Final. A returned FAILED or
// REFUNDED status is an answer, not an error: nothing was delivered and nothing
// was charged (Status.Unsuccessful).
func (c *Client) OrderGiftCard(ctx context.Context, req GiftOrderRequest) (GiftOrder, error) {
	wire, err := req.wire()
	if err != nil {
		return GiftOrder{}, err
	}
	r := c.post(c.gift, "order gift card", "/orders", wire)
	raw, err := c.do(ctx, r)
	if err != nil {
		return GiftOrder{}, err
	}
	var order GiftOrder
	if err := decode(r, raw, &order); err != nil {
		return GiftOrder{}, err
	}
	if order.TransactionID == 0 {
		// Accepted but unreadable: the cards were probably bought.
		return GiftOrder{}, &TransportError{
			Product: r.product.name, Op: r.op, Err: errors.New("answer without a transactionId"), Sent: true,
		}
	}
	return order, nil
}

// GiftRedeemCodes reads the codes of a completed order. An order that is still
// PROCESSING may answer 404 or an empty list until its cards exist.
func (c *Client) GiftRedeemCodes(ctx context.Context, transactionID int64) ([]GiftCode, error) {
	if transactionID <= 0 {
		return nil, fmt.Errorf("%w: a transaction id is required", ErrInvalidRequest)
	}
	r := c.get(c.gift, "read gift card codes", "/orders/transactions/"+strconv.FormatInt(transactionID, 10)+"/cards", nil)
	r.accept = giftCodesAccept
	raw, err := c.do(ctx, r)
	if err != nil {
		return nil, err
	}
	var codes []GiftCode
	if trimmed := bytes.TrimSpace(raw); len(trimmed) > 0 && trimmed[0] == '{' {
		var single GiftCode
		if err := decode(r, raw, &single); err != nil {
			return nil, err
		}
		return []GiftCode{single}, nil
	}
	if err := decode(r, raw, &codes); err != nil {
		return nil, err
	}
	return codes, nil
}

// GiftTransaction reads one order back by its Reloadly transaction id.
func (c *Client) GiftTransaction(ctx context.Context, id int64) (GiftTransaction, error) {
	if id <= 0 {
		return GiftTransaction{}, fmt.Errorf("%w: a transaction id is required", ErrInvalidRequest)
	}
	r := c.get(c.gift, "read gift transaction", "/reports/transactions/"+strconv.FormatInt(id, 10), nil)
	raw, err := c.do(ctx, r)
	if err != nil {
		return GiftTransaction{}, err
	}
	var transaction GiftTransaction
	if err := decode(r, raw, &transaction); err != nil {
		return GiftTransaction{}, err
	}
	return transaction, nil
}

// FindGiftTransactions looks an order up by the customIdentifier it was placed
// with, which is how a purchase whose answer was lost is found. It returns every
// match, oldest first: normally none or one, but Reloadly's duplicate check is
// not atomic, so two concurrent orders with one identifier both exist. The
// search is case-insensitive (compare CustomIdentifier yourself if case matters).
//
// from and to bound the search and may be zero. They are sent widened by a day
// and a half (Reloadly reads them in UTC-4); with an identifier they only narrow
// the search, without one the rows are clipped to [from, to]. With neither an
// identifier nor a window this reads the whole history.
func (c *Client) FindGiftTransactions(ctx context.Context, customIdentifier string, from, to time.Time) ([]GiftTransaction, error) {
	query := url.Values{}
	customIdentifier = strings.TrimSpace(customIdentifier)
	if customIdentifier != "" {
		query.Set("customIdentifier", customIdentifier)
	}
	addWindow(query, from, to)
	r := c.get(c.gift, "find gift transactions", "/reports/transactions", query)
	rows, err := listAll(ctx, c, r, func(t *GiftTransaction) string { return idKey(t.TransactionID) })
	if err != nil {
		return nil, err
	}
	if customIdentifier != "" {
		return rows, nil
	}
	kept := rows[:0]
	for _, row := range rows {
		if inWindow(row.CreatedAt.Time, from, to) {
			kept = append(kept, row)
		}
	}
	return kept, nil
}

// GiftBalance reads the company's balance as the gift card service sees it. It
// is the same USD account the other two services use.
func (c *Client) GiftBalance(ctx context.Context) (Balance, error) {
	return c.balance(ctx, c.gift)
}

func requirePositive(what string, n Num) error {
	value, ok := n.Rat()
	if !ok || value.Sign() <= 0 {
		return fmt.Errorf("%w: %s must be a positive number, got %q", ErrInvalidRequest, what, string(n))
	}
	return nil
}

func requireIdentifier(what, value string) error {
	if strings.TrimSpace(value) == "" {
		return fmt.Errorf("%w: %s is required", ErrInvalidRequest, what)
	}
	if len([]rune(value)) > MaxIdentifierLength {
		return fmt.Errorf("%w: %s is longer than %d characters", ErrInvalidRequest, what, MaxIdentifierLength)
	}
	return nil
}
