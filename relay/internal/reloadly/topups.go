package reloadly

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// TopupCountry is a country Reloadly can top up.
type TopupCountry struct {
	ISOName        string   `json:"isoName"`
	Name           string   `json:"name"`
	Continent      string   `json:"continent"`
	CurrencyCode   string   `json:"currencyCode"`
	CurrencyName   string   `json:"currencyName"`
	CurrencySymbol string   `json:"currencySymbol"`
	Flag           string   `json:"flag"`
	CallingCodes   []string `json:"callingCodes"`
}

// Operator is a mobile operator product: airtime, a data or bundle plan, a
// combo, or a PIN voucher (the flags say which; they are not exclusive).
//
// A RANGE operator sells any amount between the bounds; a FIXED one sells the
// listed plans. Amounts come in two currencies: the sender's (the company's USD
// account: MinAmount, MaxAmount, FixedAmounts) and the destination's
// (DestinationCurrencyCode: the Local* fields), related by FX.Rate. Ordering in
// the local currency (TopupRequest.UseLocalAmount) is only possible when
// SupportsLocalAmounts is true, and it earns the LOCAL discount, usually none:
// see AirtimeCost.
type Operator struct {
	ID         int64  `json:"id"`
	OperatorID int64  `json:"operatorId"`
	Name       string `json:"name"`
	// Bundle, Data, ComboProduct and Pin say what the operator sells; none of
	// them set is plain airtime.
	Bundle                            bool             `json:"bundle"`
	Data                              bool             `json:"data"`
	ComboProduct                      bool             `json:"comboProduct"`
	Pin                               bool             `json:"pin"`
	SupportsLocalAmounts              bool             `json:"supportsLocalAmounts"`
	SupportsGeographicalRechargePlans bool             `json:"supportsGeographicalRechargePlans"`
	DenominationType                  DenominationType `json:"denominationType"`
	SenderCurrencyCode                string           `json:"senderCurrencyCode"`
	SenderCurrencySymbol              string           `json:"senderCurrencySymbol"`
	DestinationCurrencyCode           string           `json:"destinationCurrencyCode"`
	DestinationCurrencySymbol         string           `json:"destinationCurrencySymbol"`

	// Commission equals InternationalDiscount in every operator seen. Both are
	// percentages off the sender amount for orders in the sender currency;
	// LocalDiscount is the (usually smaller) one for orders in the local currency.
	Commission            Num `json:"commission"`
	InternationalDiscount Num `json:"internationalDiscount"`
	LocalDiscount         Num `json:"localDiscount"`

	MostPopularAmount      Num `json:"mostPopularAmount"`
	MostPopularLocalAmount Num `json:"mostPopularLocalAmount"`
	// MinAmount and MaxAmount (RANGE) are in the sender currency, the Local*
	// pair in the destination currency; either pair may be absent.
	MinAmount      Num `json:"minAmount"`
	MaxAmount      Num `json:"maxAmount"`
	LocalMinAmount Num `json:"localMinAmount"`
	LocalMaxAmount Num `json:"localMaxAmount"`

	Country  Country  `json:"country"`
	FX       FX       `json:"fx"`
	LogoURLs []string `json:"logoUrls"`

	// FIXED plans: FixedAmounts (sender currency, cents) are aligned by index with
	// LocalFixedAmounts (destination currency). The descriptions are keyed by the
	// amount as Reloadly writes it ("0.17", "5.00").
	FixedAmounts                  []Num  `json:"fixedAmounts"`
	FixedAmountsDescriptions      Labels `json:"fixedAmountsDescriptions"`
	LocalFixedAmounts             []Num  `json:"localFixedAmounts"`
	LocalFixedAmountsDescriptions Labels `json:"localFixedAmountsDescriptions"`

	// SuggestedAmounts and SuggestedAmountsMap (sender amount -> destination
	// amount) are only filled when asked for; Operators and Operator ask.
	SuggestedAmounts    []Num          `json:"suggestedAmounts"`
	SuggestedAmountsMap map[string]Num `json:"suggestedAmountsMap"`

	Fees                      OperatorFees `json:"fees"`
	GeographicalRechargePlans []GeoPlan    `json:"geographicalRechargePlans"`
	Promotions                []Promotion  `json:"promotions"`
	Status                    string       `json:"status"`
}

// Key is the operator's id (Reloadly writes it as both id and operatorId).
func (o Operator) Key() int64 {
	if o.ID != 0 {
		return o.ID
	}
	return o.OperatorID
}

// OperatorFees are the fees an operator adds on top of the amount. The flat
// fees are in the currency of the order: International in the sender currency,
// Local in the destination currency. The percentages are of the amount.
type OperatorFees struct {
	International           Num `json:"international"`
	InternationalPercentage Num `json:"internationalPercentage"`
	Local                   Num `json:"local"`
	LocalPercentage         Num `json:"localPercentage"`
}

// GeoPlan is a per-region plan list (India's circles). The relay does not use it.
type GeoPlan struct {
	LocationCode                  string `json:"locationCode"`
	LocationName                  string `json:"locationName"`
	FixedAmounts                  []Num  `json:"fixedAmounts"`
	LocalAmounts                  []Num  `json:"localAmounts"`
	FixedAmountsPlanNames         Labels `json:"fixedAmountsPlanNames"`
	FixedAmountsDescriptions      Labels `json:"fixedAmountsDescriptions"`
	LocalFixedAmountsPlanNames    Labels `json:"localFixedAmountsPlanNames"`
	LocalFixedAmountsDescriptions Labels `json:"localFixedAmountsDescriptions"`
}

// Promotion is an operator promotion. Dates are ISO 8601 text as written.
type Promotion struct {
	ID                 int64  `json:"id"`
	PromotionID        int64  `json:"promotionId"`
	OperatorID         int64  `json:"operatorId"`
	Title              string `json:"title"`
	Title2             string `json:"title2"`
	Description        string `json:"description"`
	StartDate          string `json:"startDate"`
	EndDate            string `json:"endDate"`
	Denominations      string `json:"denominations"`
	LocalDenominations string `json:"localDenominations"`
}

// TopupRequest is one top-up.
type TopupRequest struct {
	OperatorID int64
	// Amount is in the sender currency (USD), or in the destination currency
	// when UseLocalAmount is set. A FIXED operator takes one of its listed plans
	// in the matching currency.
	Amount         Num
	UseLocalAmount bool
	// CustomIdentifier is unique to the purchase, at most MaxIdentifierLength
	// characters. Reloadly records it on every accepted top-up and answers
	// CUSTOM_IDENTIFIER_ALREADY_USED to a later one, but two requests in flight
	// together with one identifier are BOTH executed.
	CustomIdentifier string
	// RecipientPhone: see the package comment for the accepted number forms. The
	// country is the operator's.
	RecipientPhone Phone
	// SenderPhone is optional; Reloadly echoes it back.
	SenderPhone    *Phone
	RecipientEmail string
}

type topupWire struct {
	OperatorID       int64  `json:"operatorId"`
	Amount           Num    `json:"amount"`
	UseLocalAmount   bool   `json:"useLocalAmount"`
	CustomIdentifier string `json:"customIdentifier"`
	RecipientEmail   string `json:"recipientEmail,omitempty"`
	RecipientPhone   Phone  `json:"recipientPhone"`
	SenderPhone      *Phone `json:"senderPhone,omitempty"`
}

func (r TopupRequest) wire() (topupWire, error) {
	if r.OperatorID <= 0 {
		return topupWire{}, fmt.Errorf("%w: an operator id is required", ErrInvalidRequest)
	}
	if err := requirePositive("amount", r.Amount); err != nil {
		return topupWire{}, err
	}
	if err := requireIdentifier("customIdentifier", r.CustomIdentifier); err != nil {
		return topupWire{}, err
	}
	recipient, err := cleanPhone("recipient phone", r.RecipientPhone)
	if err != nil {
		return topupWire{}, err
	}
	wire := topupWire{
		OperatorID:       r.OperatorID,
		Amount:           r.Amount,
		UseLocalAmount:   r.UseLocalAmount,
		CustomIdentifier: r.CustomIdentifier,
		RecipientEmail:   strings.TrimSpace(r.RecipientEmail),
		RecipientPhone:   recipient,
	}
	if r.SenderPhone != nil {
		sender, err := cleanPhone("sender phone", *r.SenderPhone)
		if err != nil {
			return topupWire{}, err
		}
		wire.SenderPhone = &sender
	}
	return wire, nil
}

func cleanPhone(what string, phone Phone) (Phone, error) {
	country := strings.ToUpper(strings.TrimSpace(phone.CountryCode))
	number := strings.TrimSpace(phone.Number)
	if len(country) != 2 {
		return Phone{}, fmt.Errorf("%w: %s needs a two-letter ISO country code", ErrInvalidRequest, what)
	}
	if number == "" {
		return Phone{}, fmt.Errorf("%w: %s needs a number", ErrInvalidRequest, what)
	}
	return Phone{CountryCode: country, Number: number}, nil
}

// TopupResult is a top-up as Reloadly records it: the answer to Topup, the
// transaction inside a status read, or a row of the report.
//
// Amounts: RequestedAmount is in RequestedAmountCurrencyCode (the order's
// currency: USD, or the destination currency for a local order) and
// DeliveredAmount in DeliveredAmountCurrencyCode (what the phone received).
// Fee and Discount are in the account currency. What the account was debited is
// Balance.Cost.
type TopupResult struct {
	TransactionID         int64  `json:"transactionId"`
	Status                Status `json:"status"`
	OperatorTransactionID Text   `json:"operatorTransactionId"`
	CustomIdentifier      string `json:"customIdentifier"`
	// RecipientPhone and SenderPhone come back in international digits without
	// "+" ("22796123456"), however they were written.
	RecipientPhone              Text        `json:"recipientPhone"`
	RecipientEmail              string      `json:"recipientEmail"`
	SenderPhone                 Text        `json:"senderPhone"`
	CountryCode                 string      `json:"countryCode"`
	OperatorID                  int64       `json:"operatorId"`
	OperatorName                string      `json:"operatorName"`
	Discount                    Num         `json:"discount"`
	DiscountCurrencyCode        string      `json:"discountCurrencyCode"`
	RequestedAmount             Num         `json:"requestedAmount"`
	RequestedAmountCurrencyCode string      `json:"requestedAmountCurrencyCode"`
	DeliveredAmount             Num         `json:"deliveredAmount"`
	DeliveredAmountCurrencyCode string      `json:"deliveredAmountCurrencyCode"`
	TransactionDate             Time        `json:"transactionDate"`
	Fee                         Num         `json:"fee"`
	PinDetail                   *PinDetail  `json:"pinDetail"`
	Balance                     BalanceInfo `json:"balanceInfo"`
}

// TopupStatusResult is the answer to a status read. While the top-up is still
// PROCESSING there is no Transaction yet.
type TopupStatusResult struct {
	Code        string       `json:"code"`
	Message     string       `json:"message"`
	Status      Status       `json:"status"`
	Transaction *TopupResult `json:"transaction"`
}

// TopupCountries lists the countries Reloadly can top up.
func (c *Client) TopupCountries(ctx context.Context) ([]TopupCountry, error) {
	r := c.get(c.topups, "list top-up countries", "/countries", nil)
	raw, err := c.do(ctx, r)
	if err != nil {
		return nil, err
	}
	var countries []TopupCountry
	if err := decode(r, raw, &countries); err != nil {
		return nil, err
	}
	return countries, nil
}

// operatorQuery asks for everything the relay needs to price an operator.
func operatorQuery() url.Values {
	return url.Values{
		"includeBundles":      {"true"},
		"includeData":         {"true"},
		"includeCombo":        {"true"},
		"suggestedAmounts":    {"true"},
		"suggestedAmountsMap": {"true"},
	}
}

// Operators reads every operator product (all pages): airtime, bundles, data,
// combos and PIN vouchers. The caller filters by the flags.
func (c *Client) Operators(ctx context.Context) ([]Operator, error) {
	r := c.get(c.topups, "list operators", "/operators", operatorQuery())
	return listAll(ctx, c, r, func(o *Operator) string { return idKey(o.Key()) })
}

// Operator reads one operator.
func (c *Client) Operator(ctx context.Context, id int64) (Operator, error) {
	if id <= 0 {
		return Operator{}, fmt.Errorf("%w: an operator id is required", ErrInvalidRequest)
	}
	query := url.Values{"suggestedAmounts": {"true"}, "suggestedAmountsMap": {"true"}}
	return c.readOperator(ctx, "read operator", "/operators/"+strconv.FormatInt(id, 10), query)
}

// DetectOperator finds the operator a phone number belongs to, by prefix. iso is
// the country's ISO code. The number is matched leniently (national, with
// country code, with "+", with spaces) but not with a trunk zero where the
// country has none ("076123456" in Mali is NO operator, 404
// COULD_NOT_AUTO_DETECT_OPERATOR). Libya is not supported (409
// COUNTRY_NOT_SUPPORTED).
func (c *Client) DetectOperator(ctx context.Context, iso, phone string) (Operator, error) {
	iso = strings.ToUpper(strings.TrimSpace(iso))
	phone = strings.TrimSpace(phone)
	if len(iso) != 2 || phone == "" {
		return Operator{}, fmt.Errorf("%w: a two-letter country code and a phone number are required", ErrInvalidRequest)
	}
	path := "/operators/auto-detect/phone/" + pathSegment(phone) + "/countries/" + url.PathEscape(iso)
	query := url.Values{"suggestedAmounts": {"true"}, "suggestedAmountsMap": {"true"}}
	return c.readOperator(ctx, "detect operator", path, query)
}

func (c *Client) readOperator(ctx context.Context, op, path string, query url.Values) (Operator, error) {
	r := c.get(c.topups, op, path, query)
	raw, err := c.do(ctx, r)
	if err != nil {
		return Operator{}, err
	}
	var operator Operator
	if err := decode(r, raw, &operator); err != nil {
		return Operator{}, err
	}
	return operator, nil
}

// pathSegment escapes one URL path segment, "+" included.
func pathSegment(value string) string {
	return strings.ReplaceAll(url.PathEscape(value), "+", "%2B")
}

// Topup makes one top-up with the synchronous endpoint and waits for its
// answer. Reloadly usually answers within seconds, but a failing operator can
// hold the call for close to a minute (the purchase timeout is 90 s).
//
// It makes exactly ONE attempt and never retries: Reloadly's duplicate check on
// CustomIdentifier is not atomic, so a retry that overlaps the first attempt
// tops the phone up twice. A failure is returned as it is; Definite says whether
// nothing can have been sent, and anything else must be read back with
// FindTopups before the money is given back.
//
// A returned PROCESSING status is a success so far: poll TopupStatus. A returned
// FAILED or REFUNDED status is an answer, not an error: nothing was delivered and
// nothing was charged (Status.Unsuccessful).
func (c *Client) Topup(ctx context.Context, req TopupRequest) (TopupResult, error) {
	wire, err := req.wire()
	if err != nil {
		return TopupResult{}, err
	}
	r := c.post(c.topups, "make top-up", "/topups", wire)
	raw, err := c.do(ctx, r)
	if err != nil {
		return TopupResult{}, err
	}
	var result TopupResult
	if err := decode(r, raw, &result); err != nil {
		return TopupResult{}, err
	}
	if result.TransactionID == 0 {
		return TopupResult{}, &TransportError{
			Product: r.product.name, Op: r.op, Err: errors.New("answer without a transactionId"), Sent: true,
		}
	}
	return result, nil
}

// TopupAsync places a top-up and returns its transaction id at once; the outcome
// is read with TopupStatus (the sandbox shows PROCESSING for ~10 s). Same
// one-attempt rule as Topup.
func (c *Client) TopupAsync(ctx context.Context, req TopupRequest) (int64, error) {
	wire, err := req.wire()
	if err != nil {
		return 0, err
	}
	r := c.post(c.topups, "make async top-up", "/topups-async", wire)
	raw, err := c.do(ctx, r)
	if err != nil {
		return 0, err
	}
	var answer struct {
		TransactionID int64 `json:"transactionId"`
	}
	if err := decode(r, raw, &answer); err != nil {
		return 0, err
	}
	if answer.TransactionID == 0 {
		return 0, &TransportError{
			Product: r.product.name, Op: r.op, Err: errors.New("answer without a transactionId"), Sent: true,
		}
	}
	return answer.TransactionID, nil
}

// TopupStatus reads the live state of a top-up by its Reloadly transaction id.
func (c *Client) TopupStatus(ctx context.Context, transactionID int64) (TopupStatusResult, error) {
	if transactionID <= 0 {
		return TopupStatusResult{}, fmt.Errorf("%w: a transaction id is required", ErrInvalidRequest)
	}
	r := c.get(c.topups, "read top-up status", "/topups/"+strconv.FormatInt(transactionID, 10)+"/status", nil)
	raw, err := c.do(ctx, r)
	if err != nil {
		return TopupStatusResult{}, err
	}
	var status TopupStatusResult
	if err := decode(r, raw, &status); err != nil {
		return TopupStatusResult{}, err
	}
	return status, nil
}

// TopupTransaction reads a top-up from the report by its Reloadly transaction id.
func (c *Client) TopupTransaction(ctx context.Context, transactionID int64) (TopupResult, error) {
	if transactionID <= 0 {
		return TopupResult{}, fmt.Errorf("%w: a transaction id is required", ErrInvalidRequest)
	}
	r := c.get(c.topups, "read top-up", "/topups/reports/transactions/"+strconv.FormatInt(transactionID, 10), nil)
	raw, err := c.do(ctx, r)
	if err != nil {
		return TopupResult{}, err
	}
	var result TopupResult
	if err := decode(r, raw, &result); err != nil {
		return TopupResult{}, err
	}
	return result, nil
}

// FindTopups looks top-ups up by the customIdentifier they were placed with,
// which is how a top-up whose answer was lost is found. It returns every match,
// oldest first: normally none or one, but two concurrent top-ups with one
// identifier both exist. The search is case-insensitive. A top-up that Reloadly
// rejected leaves no record, so an empty answer means nothing was done — as long
// as the request is no longer in flight.
//
// from and to bound the search and may be zero; see FindGiftTransactions.
func (c *Client) FindTopups(ctx context.Context, customIdentifier string, from, to time.Time) ([]TopupResult, error) {
	query := url.Values{}
	customIdentifier = strings.TrimSpace(customIdentifier)
	if customIdentifier != "" {
		query.Set("customIdentifier", customIdentifier)
	}
	addWindow(query, from, to)
	r := c.get(c.topups, "find top-ups", "/topups/reports/transactions", query)
	rows, err := listAll(ctx, c, r, func(t *TopupResult) string { return idKey(t.TransactionID) })
	if err != nil {
		return nil, err
	}
	if customIdentifier != "" {
		return rows, nil
	}
	kept := rows[:0]
	for _, row := range rows {
		if inWindow(row.TransactionDate.Time, from, to) {
			kept = append(kept, row)
		}
	}
	return kept, nil
}

// TopupBalance reads the company's balance as the top-up service sees it (the
// same USD account as the other two).
func (c *Client) TopupBalance(ctx context.Context) (Balance, error) {
	return c.balance(ctx, c.topups)
}
