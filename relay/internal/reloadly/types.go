package reloadly

import (
	"context"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// DenominationType says how a product, operator or biller is priced.
type DenominationType string

const (
	// Fixed products sell only the listed amounts.
	Fixed DenominationType = "FIXED"
	// Range products sell any amount between a minimum and a maximum.
	Range DenominationType = "RANGE"
)

// Status is the state of a gift card order, a top-up or a utility payment.
//
// Reloadly documents SUCCESSFUL, PROCESSING, REFUNDED and FAILED, and gift
// cards add PENDING. Only SUCCESSFUL delivers the value. REFUNDED and FAILED
// deliver nothing and leave the account whole (balanceInfo.cost is 0), though a
// REFUNDED payment still lists the fee it would have charged. An unknown or
// empty status is never final: keep asking.
type Status string

const (
	StatusSuccessful Status = "SUCCESSFUL"
	StatusProcessing Status = "PROCESSING"
	StatusPending    Status = "PENDING"
	StatusRefunded   Status = "REFUNDED"
	StatusFailed     Status = "FAILED"
)

// Final is whether the status can no longer change.
func (s Status) Final() bool {
	return s == StatusSuccessful || s == StatusRefunded || s == StatusFailed
}

// Succeeded is whether the value was delivered.
func (s Status) Succeeded() bool { return s == StatusSuccessful }

// Unsuccessful is whether the transaction ended without delivering anything and
// without costing anything (REFUNDED or FAILED).
func (s Status) Unsuccessful() bool { return s == StatusRefunded || s == StatusFailed }

// InProgress is whether the outcome is still open.
func (s Status) InProgress() bool { return !s.Final() }

// UnmarshalJSON reads the status in upper case, whatever case it came in.
func (s *Status) UnmarshalJSON(data []byte) error {
	var text Text
	if err := text.UnmarshalJSON(data); err != nil {
		return err
	}
	*s = Status(strings.ToUpper(strings.TrimSpace(string(text))))
	return nil
}

// Country is a country as products and operators name it.
type Country struct {
	ISOName string `json:"isoName"`
	Name    string `json:"name"`
	FlagURL string `json:"flagUrl,omitempty"`
}

// FX is a rate. For operators and billers Rate is how many units of
// CurrencyCode (the destination currency) one unit of the account currency
// buys: 505 for XOF against USD.
type FX struct {
	Rate         Num    `json:"rate"`
	CurrencyCode string `json:"currencyCode"`
}

// Phone is a phone number and the ISO country it belongs to.
type Phone struct {
	CountryCode string `json:"countryCode"`
	Number      string `json:"number"`
}

// BalanceInfo is how a transaction moved the company's balance. Cost is what
// the transaction finally cost: 0 for a REFUNDED or FAILED one.
//
// UpdatedAt is kept as written and is NOT reliable: the gift card and utility
// services write it four hours ahead of UTC, the top-up service in UTC, and on
// an order it is the stamp from before the order.
type BalanceInfo struct {
	OldBalance   Num    `json:"oldBalance"`
	NewBalance   Num    `json:"newBalance"`
	Cost         Num    `json:"cost"`
	CurrencyCode string `json:"currencyCode"`
	CurrencyName string `json:"currencyName"`
	UpdatedAt    string `json:"updatedAt"`
}

// Balance is the company's balance at Reloadly: one USD account shared by the
// three products.
type Balance struct {
	Balance                Num    `json:"balance"`
	FrozenBalance          Num    `json:"frozenBalance"`
	CurrencyCode           string `json:"currencyCode"`
	CurrencyName           string `json:"currencyName"`
	LowBalanceThreshold    Num    `json:"lowBalanceThreshold"`
	MaxLowBalanceThreshold Num    `json:"maxLowBalanceThreshold"`
	// UpdatedAt is unreliable, see BalanceInfo.
	UpdatedAt string `json:"updatedAt"`
}

// PinDetail is the voucher a PIN top-up hands back: dial info and the code to
// load. Reloadly writes info as "info" in some answers and "info1".."info3" in
// others; serial and code are strings in some and numbers in others.
type PinDetail struct {
	Serial   Text `json:"serial"`
	Code     Text `json:"code"`
	Info     Text `json:"info"`
	Info1    Text `json:"info1"`
	Info2    Text `json:"info2"`
	Info3    Text `json:"info3"`
	Value    Text `json:"value"`
	IVR      Text `json:"ivr"`
	Validity Text `json:"validity"`
}

// Empty is whether no field holds anything.
func (p PinDetail) Empty() bool { return p == PinDetail{} }

func (c *Client) balance(ctx context.Context, p *productState) (Balance, error) {
	r := c.get(p, "read balance", "/accounts/balance", nil)
	raw, err := c.do(ctx, r)
	if err != nil {
		return Balance{}, err
	}
	var balance Balance
	if err := decode(r, raw, &balance); err != nil {
		return Balance{}, err
	}
	return balance, nil
}

// searchWindowPad widens a time window sent to a report endpoint. Reloadly
// reads startDate and endDate as UTC-4 wall-clock time (observed on all three
// products) while writing every timestamp in UTC; a day and a half of padding
// absorbs that whatever the zone turns out to be, and the rows are clipped to
// the exact window here.
const searchWindowPad = 36 * time.Hour

func addWindow(query url.Values, from, to time.Time) {
	if !from.IsZero() {
		query.Set("startDate", FormatTime(from.Add(-searchWindowPad)))
	}
	if !to.IsZero() {
		query.Set("endDate", FormatTime(to.Add(searchWindowPad)))
	}
}

// inWindow is whether an instant lies in [from, to]; a zero bound is open. An
// instant that could not be read is kept.
func inWindow(at, from, to time.Time) bool {
	if at.IsZero() {
		return true
	}
	return (from.IsZero() || !at.Before(from)) && (to.IsZero() || !at.After(to))
}

// idKey is the dedupe key of a row: its id, or "" for a row without one (such
// rows are all kept).
func idKey(id int64) string {
	if id == 0 {
		return ""
	}
	return strconv.FormatInt(id, 10)
}
