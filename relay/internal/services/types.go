package services

import (
	"fmt"
	"net/http"
	"time"

	"pointy/relay/internal/vouchers"
)

// The company sells two services besides cards, both bought from Reloadly in
// dollars: credit sent straight to a phone number abroad ("airtime") and bill
// payments ("bill"). This file is their wire form, exactly as
// DIRECT_TOPUP_PLAN.md section 2.3 writes it; every type below is what a shop's
// backend reads, so a tag changes only together with that document.

// Kinds of service, as the purchase ledger and the wire name them.
const (
	KindAirtime = "airtime"
	KindBill    = "bill"
)

// Modes of an operator or a biller: any amount between a minimum and a maximum,
// or one of a list.
const (
	ModeRange = "range"
	ModeFixed = "fixed"
)

// Bill types. The till sells one card per type that has at least one biller.
const (
	BillElectricity = "electricity"
	BillWater       = "water"
	BillTV          = "tv"
	BillInternet    = "internet"
	BillToll        = "toll"
	BillOther       = "other"
)

// Bill services: a prepaid biller hands back a token to load into the meter; a
// postpaid one settles an invoice already issued.
const (
	ServicePrepaid  = "prepaid"
	ServicePostpaid = "postpaid"
)

// Directory is GET /v1/services/directory: everything the till can sell as
// direct top-up or bill payment, priced for now.
type Directory struct {
	// Version identifies the PRICED view: it moves when a price, a name, an
	// operator or a country changes, and it is the ETag. It is a hash of the body
	// with Version and GeneratedAt left out.
	Version string `json:"version"`
	// GeneratedAt is when the directory was last read from Reloadly with a change
	// in it; a read that found nothing new keeps the earlier moment, so a quiet
	// directory has a stable body.
	GeneratedAt time.Time `json:"generated_at"`
	Currency    string    `json:"currency"`
	TestMode    bool      `json:"test_mode"`
	Configured  bool      `json:"configured"`
	// Priced is false while no dollar rate is published: amounts then carry no
	// prices and nothing can be sold.
	Priced bool `json:"priced"`
	// Pricing is the company's margin policy, for the shop to show.
	Pricing *PricingPolicy `json:"pricing,omitempty"`
	// Popular is the popular countries that have a service, in order.
	Popular     []string      `json:"popular"`
	Countries   []Country     `json:"countries"`
	Unsupported []Unsupported `json:"unsupported"`
}

// Country is a country with at least one operator or biller.
type Country struct {
	Code string `json:"code"`
	// Name is the Arabic display name; NameEN is Reloadly's spelling, there for
	// the search box and for an operator reading the data. Clients never show it.
	Name         string   `json:"name"`
	NameEN       string   `json:"name_en"`
	Dial         []string `json:"dial"`
	Currency     string   `json:"currency"`
	CurrencyName string   `json:"currency_name"`
	// Flag is a catalog image reference ("sha256:<hex>"), "" when the catalog
	// has no flag for the country.
	Flag string `json:"flag"`
	// Popular is the 1-based rank in the directory's popular list, 0 when the
	// country is not in it.
	Popular int           `json:"popular"`
	Airtime *AirtimeBlock `json:"airtime,omitempty"`
	Bills   *BillsBlock   `json:"bills,omitempty"`
}

// AirtimeBlock holds a country's operators.
type AirtimeBlock struct {
	Operators []Operator `json:"operators"`
}

// BillsBlock holds a country's billers.
type BillsBlock struct {
	Billers []Biller `json:"billers"`
}

// Unsupported is a country the relay knows by name that no service reaches, so
// the till can say so instead of finding nothing.
type Unsupported struct {
	Code string `json:"code"`
	Name string `json:"name"`
}

// Operator is a mobile network that takes plain airtime.
type Operator struct {
	ID     int64  `json:"id"`
	Name   string `json:"name"`
	NameEN string `json:"name_en"`
	Logo   string `json:"logo"`
	// Mode is range (any amount between Min and Max) or fixed (one of Amounts).
	Mode string `json:"mode"`
	// AmountCurrency is the currency of Amount, Min and Max: the local one when
	// the operator takes local amounts, else US dollars.
	AmountCurrency string `json:"amount_currency"`
	// ReceiveCurrency is what the recipient is credited in.
	ReceiveCurrency string `json:"receive_currency"`
	// Approximate is true when the recipient's amount is converted at
	// Reloadly's rate, so what arrives is only close to what Receive says.
	Approximate bool   `json:"approximate"`
	Min         string `json:"min,omitempty"`
	Max         string `json:"max,omitempty"`
	// Amounts are every denomination of a fixed operator, and a few round
	// suggestions inside [Min, Max] for a range one.
	Amounts       []Amount `json:"amounts"`
	PopularAmount *string  `json:"popular_amount"`
}

// Amount is one amount an operator sells, with what it costs.
type Amount struct {
	Amount          string `json:"amount"`
	Receive         string `json:"receive"`
	ReceiveCurrency string `json:"receive_currency"`
	// UnitPrice is what the shop pays, RetailPrice what its customer is asked
	// to pay; both are dinars with two decimals and are left out while the
	// directory is not priced.
	UnitPrice   string `json:"unit_price,omitempty"`
	RetailPrice string `json:"retail_price,omitempty"`
}

// Biller is a utility or subscription provider that takes payments.
type Biller struct {
	ID     int64  `json:"id"`
	Name   string `json:"name"`
	NameEN string `json:"name_en"`
	// Type is electricity, water, tv, internet, toll or other.
	Type string `json:"type"`
	// Service is prepaid or postpaid.
	Service string `json:"service"`
	// Mode is range or fixed.
	Mode string `json:"mode"`
	// RequiresInvoice is true when an order must carry the invoice number.
	RequiresInvoice bool   `json:"requires_invoice"`
	AmountCurrency  string `json:"amount_currency"`
	// Approximate is true when amounts are dollars that Reloadly converts into
	// the biller's currency (a biller that takes no local amounts).
	Approximate bool         `json:"approximate,omitempty"`
	Min         string       `json:"min,omitempty"`
	Max         string       `json:"max,omitempty"`
	Suggested   []Suggestion `json:"suggested,omitempty"`
	Plans       []Plan       `json:"plans,omitempty"`
}

// Suggestion is a round amount offered for a range biller.
type Suggestion struct {
	Amount      string `json:"amount"`
	UnitPrice   string `json:"unit_price,omitempty"`
	RetailPrice string `json:"retail_price,omitempty"`
}

// Plan is one package of a fixed biller (a TV subscription).
type Plan struct {
	ID            int64  `json:"id"`
	Amount        string `json:"amount"`
	Description   string `json:"description"`
	DescriptionEN string `json:"description_en"`
	UnitPrice     string `json:"unit_price,omitempty"`
	RetailPrice   string `json:"retail_price,omitempty"`
}

// Money is an amount of a foreign currency.
type Money struct {
	Amount   string `json:"amount"`
	Currency string `json:"currency"`
}

// Quote is the exact price of one thing: POST /v1/services/quote answers
// {"quote": Quote}.
type Quote struct {
	Kind        string `json:"kind"`
	Name        string `json:"name"`
	UnitPrice   string `json:"unit_price"`
	RetailPrice string `json:"retail_price"`
	Receive     Money  `json:"receive"`
	Approximate bool   `json:"approximate"`
}

// DetectedPhone is a number as the relay understood it.
type DetectedPhone struct {
	E164     string `json:"e164"`
	National string `json:"national"`
	Country  string `json:"country"`
}

// Detection is GET /v1/services/detect: the operator a number belongs to.
type Detection struct {
	Operator Operator      `json:"operator"`
	Phone    DetectedPhone `json:"phone"`
}

// Codes of the services API, the words the shop's backend maps to the till's.
const (
	CodeInvalidRequest         = "invalid_request"
	CodeInvalidPhone           = "invalid_phone"
	CodeInvalidAccount         = "invalid_account"
	CodeInvalidInvoice         = "invalid_invoice"
	CodeInvoiceRequired        = "invoice_required"
	CodeInvalidAmount          = "invalid_amount"
	CodeAmountOutOfRange       = "amount_out_of_range"
	CodeAmountNotOffered       = "amount_not_offered"
	CodeUnknownOperator        = "unknown_operator"
	CodeUnknownBiller          = "unknown_biller"
	CodeServiceUnavailable     = "service_unavailable"
	CodeOperatorNotDetected    = "operator_not_detected"
	CodeServicesUnconfigured   = "services_unconfigured"
	CodeServicesUnpriced       = "services_unpriced"
	CodeServicesUnavailable    = "services_unavailable"
	CodePriceChanged           = "price_changed"
	CodeKeyReused              = "idempotency_key_reused"
	CodeMissingCountry         = "missing_country"
	ReasonRateUnset            = "rate_unset"
	ReasonDirectoryUnavailable = "directory_unavailable"
	ReasonCostUnknown          = "cost_unknown"
	// ReasonStale: the supplier has not been read successfully for too long to
	// trust the directory's prices (see Service.staleAfter).
	ReasonStale = "stale"
)

// Refusal is a request the relay turns down: the HTTP status, the stable code
// the shop's backend maps, and the fields that code carries (the limits of an
// amount, say). Its message is for logs and operators, never for a till.
type Refusal struct {
	Status  int
	Code    string
	Message string
	Extra   map[string]any
}

func (r *Refusal) Error() string {
	if r.Message == "" {
		return r.Code
	}
	return r.Code + ": " + r.Message
}

func refuse(status int, code, message string, extra map[string]any) *Refusal {
	return &Refusal{Status: status, Code: code, Message: message, Extra: extra}
}

func refuseUnprocessable(code, message string) *Refusal {
	return refuse(http.StatusUnprocessableEntity, code, message, nil)
}

func refuseUnavailable(reason string) *Refusal {
	return refuse(http.StatusConflict, CodeServiceUnavailable,
		fmt.Sprintf("this service cannot be sold right now (%s)", reason), map[string]any{"reason": reason})
}

// PricingPolicy is the part of the company's margin policy a shop shows its
// owner: what the company earns and how the margin is split.
type PricingPolicy struct {
	FixedLYD         string             `json:"fixed_lyd"`
	Brackets         []vouchers.Bracket `json:"brackets"`
	ShopSharePercent string             `json:"shop_share_percent"`
	RoundStep        string             `json:"round_step"`
}
