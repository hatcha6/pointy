package airalo

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
)

// Number reads a JSON value Airalo sends as a number on one endpoint and as a
// string on another, keeping the text as written. Null and "" are empty.
type Number string

func (n *Number) UnmarshalJSON(raw []byte) error {
	text := strings.TrimSpace(string(raw))
	if text == "null" {
		*n = ""
		return nil
	}
	*n = Number(strings.Trim(text, `"`))
	return nil
}

func (n Number) String() string { return string(n) }

// Int reads the value as a whole number; anything else is 0.
func (n Number) Int() int {
	value, err := strconv.ParseFloat(strings.TrimSpace(string(n)), 64)
	if err != nil {
		return 0
	}
	return int(value)
}

// Float reads the value as a number; anything else is 0.
func (n Number) Float() float64 {
	value, err := strconv.ParseFloat(strings.TrimSpace(string(n)), 64)
	if err != nil {
		return 0
	}
	return value
}

// Image is a picture Airalo hosts.
type Image struct {
	URL string `json:"url"`
}

// Prices is a package's prices by currency.
type Prices struct {
	Net         map[string]float64 `json:"net_price"`
	Recommended map[string]float64 `json:"recommended_retail_price"`
}

// Pricing is how the account pays: "net_pricing" names a net price on each
// package, "discount_pricing" takes a percentage off each package's price.
type Pricing struct {
	Model    string `json:"model"`
	Discount Number `json:"discount_percentage"`
}

// CostUSD is what a package costs the account in dollars; 0 when it cannot be told.
func (p Pricing) CostUSD(source Package) float64 {
	if cost := source.Prices.Net["USD"]; cost > 0 {
		return cost
	}
	if cost := source.NetPrice.Float(); cost > 0 {
		return cost
	}
	price := source.Price.Float()
	if price <= 0 {
		return 0
	}
	return price * (100 - p.Discount.Float()) / 100
}

// Package is one plan: a first eSIM (type "sim") or a top-up ("topup").
type Package struct {
	ID        string `json:"id"`
	Type      string `json:"type"`
	Title     string `json:"title"`
	Data      string `json:"data"`
	AmountMB  Number `json:"amount"`
	Days      Number `json:"day"`
	Unlimited bool   `json:"is_unlimited"`
	Voice     Number `json:"voice"`
	Text      Number `json:"text"`
	ShortInfo string `json:"short_info"`
	Price     Number `json:"price"`
	NetPrice  Number `json:"net_price"`
	Prices    Prices `json:"prices"`
	QRInstall string `json:"qr_installation"`
	Manual    string `json:"manual_installation"`
}

// Network is a carrier a plan connects through in a country.
type Network struct {
	Name string   `json:"name"`
	Type []string `json:"types"`
}

// Coverage is one country a plan works in.
type Coverage struct {
	Name     string    `json:"name"`
	Code     string    `json:"code"`
	Networks []Network `json:"networks"`
}

// Operator is who carries a set of packages.
type Operator struct {
	ID               Number     `json:"id"`
	Title            string     `json:"title"`
	Type             string     `json:"type"`
	PlanType         string     `json:"plan_type"`
	ESIMType         string     `json:"esim_type"`
	IsPrepaid        bool       `json:"is_prepaid"`
	Rechargeable     bool       `json:"rechargeability"`
	ActivationPolicy string     `json:"activation_policy"`
	KYC              bool       `json:"is_kyc_verify"`
	Roaming          bool       `json:"is_roaming"`
	APNType          string     `json:"apn_type"`
	APNValue         string     `json:"apn_value"`
	InstallWindow    Number     `json:"install_window_days"`
	TopUpGrace       Number     `json:"topup_grace_window_days"`
	OtherInfo        string     `json:"other_info"`
	Info             []string   `json:"info"`
	Image            Image      `json:"image"`
	Coverages        []Coverage `json:"coverages"`
	Packages         []Package  `json:"packages"`
}

// Destination is one entry of the catalog: a country, a region or the world.
type Destination struct {
	Slug        string     `json:"slug"`
	CountryCode string     `json:"country_code"`
	Title       string     `json:"title"`
	Image       Image      `json:"image"`
	Operators   []Operator `json:"operators"`
}

// APNSettings is an eSIM's APN on one operating system.
type APNSettings struct {
	Type  string `json:"apn_type"`
	Value string `json:"apn_value"`
}

// Sharing is the eSIMs Cloud page of an eSIM: the way to hand it to someone.
type Sharing struct {
	Link       string `json:"link"`
	AccessCode string `json:"access_code"`
}

// SIM is one issued eSIM. Everything in it installs the eSIM: never log it.
type SIM struct {
	ICCID        string `json:"iccid"`
	LPA          string `json:"lpa"`
	MatchingID   string `json:"matching_id"`
	QRCode       string `json:"qrcode"`
	QRCodeURL    string `json:"qrcode_url"`
	AppleURL     string `json:"direct_apple_installation_url"`
	AndroidURL   string `json:"direct_android_installation_url"`
	APNType      string `json:"apn_type"`
	APNValue     string `json:"apn_value"`
	Roaming      bool   `json:"is_roaming"`
	Confirmation string `json:"confirmation_code"`
	MSISDN       string `json:"msisdn"`
	Recycled     bool   `json:"recycled"`
	APN          *struct {
		IOS     APNSettings `json:"ios"`
		Android APNSettings `json:"android"`
	} `json:"apn"`
	Sharing *Sharing `json:"sharing"`
	Simable *Order   `json:"simable"`
}

// OrderStatus is an order's state: {"slug": "completed"}, or just the word.
type OrderStatus struct {
	Slug string
}

func (s *OrderStatus) UnmarshalJSON(raw []byte) error {
	raw = bytes.TrimSpace(raw)
	if len(raw) > 0 && raw[0] == '{' {
		var object struct {
			Slug string `json:"slug"`
			Name string `json:"name"`
		}
		if err := json.Unmarshal(raw, &object); err != nil {
			return err
		}
		s.Slug = object.Slug
		if s.Slug == "" {
			s.Slug = object.Name
		}
	} else {
		s.Slug = strings.Trim(string(raw), `"`)
		if s.Slug == "null" {
			s.Slug = ""
		}
	}
	s.Slug = strings.ToLower(strings.TrimSpace(s.Slug))
	return nil
}

// Order is an order of eSIMs or a top-up.
type Order struct {
	ID          Number       `json:"id"`
	Code        string       `json:"code"`
	PackageID   string       `json:"package_id"`
	Type        string       `json:"type"`
	Description string       `json:"description"`
	Quantity    Number       `json:"quantity"`
	Package     string       `json:"package"`
	Data        string       `json:"data"`
	Validity    Number       `json:"validity"`
	Price       Number       `json:"price"`
	NetPrice    Number       `json:"net_price"`
	PaidPrice   Number       `json:"total_amount_paid"`
	Currency    string       `json:"currency"`
	CreatedAt   string       `json:"created_at"`
	Status      *OrderStatus `json:"status"`
	SIMs        []SIM        `json:"sims"`
}

// Usage is what is left on an eSIM. Totals mean nothing on an unlimited plan.
type Usage struct {
	RemainingMB    Number `json:"remaining"`
	TotalMB        Number `json:"total"`
	ExpiredAt      string `json:"expired_at"`
	Unlimited      bool   `json:"is_unlimited"`
	Status         string `json:"status"`
	RemainingVoice Number `json:"remaining_voice"`
	RemainingText  Number `json:"remaining_text"`
	TotalVoice     Number `json:"total_voice"`
	TotalText      Number `json:"total_text"`
}

// Usage statuses.
const (
	UsageNotActive = "NOT_ACTIVE"
	UsageActive    = "ACTIVE"
	UsageFinished  = "FINISHED"
	UsageExpired   = "EXPIRED"
	UsageUnknown   = "UNKNOWN"
)

// DeviceCheck is whether a model supports eSIM. Reason ReasonNotInList means
// the model is not on Airalo's list, not that it cannot: ask, never block.
type DeviceCheck struct {
	Supported bool   `json:"supported"`
	Reason    string `json:"reason"`
	Device    *struct {
		OS    string `json:"os"`
		Brand string `json:"brand"`
		Name  string `json:"name"`
	} `json:"device"`
}

// ReasonNotInList is a device check's answer for a model Airalo does not list.
const ReasonNotInList = "not_in_compatible_list"

// Notification types.
const (
	NotifyLowData     = "webhook_low_data"
	NotifyCreditLimit = "webhook_credit_limit"
)

// Notification is one opted-in notification.
type Notification struct {
	Type         string `json:"type"`
	ContactPoint string `json:"contact_point"`
}

// Balance is the account's Airalo credit.
type Balance struct {
	Amount   float64
	Currency string
}
