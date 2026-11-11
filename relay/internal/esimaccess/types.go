package esimaccess

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"
)

// flexString reads a JSON string or number as text: the API writes codes both ways.
type flexString string

func (s *flexString) UnmarshalJSON(raw []byte) error {
	text := strings.TrimSpace(string(raw))
	if text == "null" {
		*s = ""
		return nil
	}
	var value string
	if err := json.Unmarshal(raw, &value); err == nil {
		*s = flexString(value)
		return nil
	}
	*s = flexString(text)
	return nil
}

// Int is a whole number the API may write as a number, a decimal or a string.
type Int int64

func (n *Int) UnmarshalJSON(raw []byte) error {
	text := strings.Trim(strings.TrimSpace(string(raw)), `"`)
	if text == "" || text == "null" {
		*n = 0
		return nil
	}
	if value, err := strconv.ParseInt(text, 10, 64); err == nil {
		*n = Int(value)
		return nil
	}
	value, err := strconv.ParseFloat(text, 64)
	if err != nil {
		*n = 0
		return nil
	}
	*n = Int(value)
	return nil
}

// Dollars is a money amount in dollars, as text ("0.46").
func Dollars(units int64) string {
	sign := ""
	if units < 0 {
		sign, units = "-", -units
	}
	text := strconv.FormatInt(units/Units, 10) + "." + leftPad(strconv.FormatInt(units%Units, 10), 4)
	text = strings.TrimRight(text, "0")
	if strings.HasSuffix(text, ".") {
		text += "0"
	}
	return sign + text
}

func leftPad(text string, width int) string {
	for len(text) < width {
		text = "0" + text
	}
	return text
}

// Package data types.
const (
	// DataTotal is a plan with one amount of data for its whole life.
	DataTotal = 1
	// Day passes: an amount each day, then slowed, cut off, or never limited.
	DataDailySlowed    = 2
	DataDailyCutOff    = 3
	DataDailyUnlimited = 4
)

// Top-up support of a package.
const (
	TopUpNone   = 1
	TopUpYes    = 2
	TopUpPeriod = 3
)

// Activation types: when a plan's days start counting.
const (
	ActiveOnInstall = 1
	ActiveOnNetwork = 2
)

// Operator is a network a plan uses in one country.
type Operator struct {
	Name        string `json:"operatorName"`
	NetworkType string `json:"networkType"`
}

// Location is one country a plan covers.
type Location struct {
	Name      string     `json:"locationName"`
	Logo      string     `json:"locationLogo"`
	Code      string     `json:"locationCode"`
	Operators []Operator `json:"operatorList"`
}

// Package is one plan of the catalog, or one top-up of an eSIM.
type Package struct {
	Code string `json:"packageCode"`
	Slug string `json:"slug"`
	Name string `json:"name"`
	// Price is what the company pays, in Units.
	Price    Int    `json:"price"`
	Currency string `json:"currencyCode"`
	// Volume is the data in bytes: of the whole plan, or of each day.
	Volume   Int `json:"volume"`
	SMS      Int `json:"smsStatus"`
	DataType Int `json:"dataType"`
	// UnusedValidTime: an eSIM not installed in this many days is gone.
	UnusedValidTime Int    `json:"unusedValidTime"`
	Duration        Int    `json:"duration"`
	DurationUnit    string `json:"durationUnit"`
	// Location is the covered countries' codes, comma-separated.
	Location    string `json:"location"`
	Description string `json:"description"`
	ActiveType  Int    `json:"activeType"`
	// RetailPrice is the suggested retail price, in Units.
	RetailPrice      Int        `json:"retailPrice"`
	Speed            string     `json:"speed"`
	IPExport         string     `json:"ipExport"`
	SupportTopUpType Int        `json:"supportTopUpType"`
	FUPPolicy        string     `json:"fupPolicy"`
	Locations        []Location `json:"locationNetworkList"`
}

// Days is the plan's validity in days.
func (p Package) Days() int {
	days := int(p.Duration)
	switch strings.ToUpper(strings.TrimSpace(p.DurationUnit)) {
	case "MONTH":
		return days * 30
	case "YEAR":
		return days * 365
	}
	return days
}

// Megabytes is the plan's data.
func (p Package) Megabytes() int { return int(int64(p.Volume) / (1 << 20)) }

// Codes is the covered countries' ISO codes.
func (p Package) Codes() []string {
	codes := []string{}
	for _, code := range strings.Split(p.Location, ",") {
		if code = strings.ToUpper(strings.TrimSpace(code)); code != "" {
			codes = append(codes, code)
		}
	}
	return codes
}

// ProfilePackage is a plan loaded on an eSIM: its first one, then its top-ups.
type ProfilePackage struct {
	Name       string `json:"packageName"`
	Code       string `json:"packageCode"`
	Slug       string `json:"slug"`
	Duration   Int    `json:"duration"`
	Volume     Int    `json:"volume"`
	Location   string `json:"locationCode"`
	CreateTime string `json:"createTime"`
}

// eSIM statuses.
const (
	StatusGotResource   = "GOT_RESOURCE"
	StatusInUse         = "IN_USE"
	StatusUsedUp        = "USED_UP"
	StatusUsedExpired   = "USED_EXPIRED"
	StatusUnusedExpired = "UNUSED_EXPIRED"
	StatusCancel        = "CANCEL"
	StatusRevoke        = "REVOKE"
	StatusRevoked       = "REVOKED"
	StatusSuspended     = "SUSPENDED"
)

// Profile is one eSIM of the account.
type Profile struct {
	// TranNo names the eSIM for good. An ICCID does not: the API reuses them.
	TranNo        string `json:"esimTranNo"`
	OrderNo       string `json:"orderNo"`
	TransactionID string `json:"transactionId"`
	ICCID         string `json:"iccid"`
	// AC is the activation code: LPA:1$<SM-DP+ address>$<matching id>.
	AC               string           `json:"ac"`
	QRCodeURL        string           `json:"qrCodeUrl"`
	ShortURL         string           `json:"shortUrl"`
	SMDPStatus       string           `json:"smdpStatus"`
	EID              string           `json:"eid"`
	ActiveType       Int              `json:"activeType"`
	DataType         Int              `json:"dataType"`
	ActivateTime     string           `json:"activateTime"`
	ExpiredTime      string           `json:"expiredTime"`
	TotalVolume      Int              `json:"totalVolume"`
	TotalDuration    Int              `json:"totalDuration"`
	OrderUsage       Int              `json:"orderUsage"`
	Status           string           `json:"esimStatus"`
	APN              string           `json:"apn"`
	SupportTopUpType Int              `json:"supportTopUpType"`
	Packages         []ProfilePackage `json:"packageList"`
}

// SMDP is the SM-DP+ address and the matching id of the activation code.
func (p Profile) SMDP() (address, matchingID string) {
	parts := strings.Split(strings.TrimSpace(p.AC), "$")
	if len(parts) < 3 {
		return "", ""
	}
	return parts[1], parts[2]
}

// Ended reports an eSIM that can never be used or topped up again.
func (p Profile) Ended() bool {
	switch strings.ToUpper(strings.TrimSpace(p.Status)) {
	case StatusUsedExpired, StatusUnusedExpired, StatusCancel, StatusRevoke, StatusRevoked:
		return true
	}
	return false
}

// ParseTime reads the API's times ("2023-03-03T06:20:00+0000", RFC 3339). Nil
// when empty or unreadable.
func ParseTime(text string) *time.Time {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil
	}
	for _, layout := range []string{"2006-01-02T15:04:05-0700", time.RFC3339, "2006-01-02T15:04-07:00", "2006-01-02 15:04:05"} {
		if at, err := time.Parse(layout, text); err == nil {
			at = at.UTC()
			return &at
		}
	}
	return nil
}

// TopUpResult is what a top-up answers: the eSIM's new totals.
type TopUpResult struct {
	TransactionID string `json:"transactionId"`
	ICCID         string `json:"iccid"`
	ExpiredTime   string `json:"expiredTime"`
	TotalVolume   Int    `json:"totalVolume"`
	TotalDuration Int    `json:"totalDuration"`
	OrderUsage    Int    `json:"orderUsage"`
	TopUpTranNo   string `json:"topUpEsimTranNo"`
}
