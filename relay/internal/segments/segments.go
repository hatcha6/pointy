// Package segments sorts «دفتر كروت» customers into segments by how they buy,
// and says what each segment is worth.
//
// The model is RFM (recency, frequency, monetary), the standard for retail
// customer segmentation, with recency measured against each customer's own
// rhythm instead of one fixed clock. A card app is bought from on a cycle
// (a top-up every week, a game card every month): ten days without an order
// is nothing for a monthly buyer and a warning for a weekly one. So a repeat
// buyer's recency is how many of their own usual gaps have passed since their
// last order (their "due ratio"), the individualized churn timing that
// practitioners (Optimove's churn factor, RFMTC) prefer to one cutoff for all.
//
// Fixed, documented thresholds are used rather than quintiles: the customer
// base is young and growing, and quintile cutoffs would move every customer
// as it grows. Only "high value" is relative (the top fifth of repeat buyers
// by spend), because what counts as a big spender is a matter of this
// customer base. Segments are mutually exclusive and checked in the order of
// Keys; every live customer is in exactly one.
package segments

import (
	"math/big"
	"sort"
	"time"
)

// The segments, in the order they are shown.
const (
	// Champions buy often, recently and the most: protect, do not discount.
	Champions = "champions"
	// Loyal buy often and are on their rhythm.
	Loyal = "loyal"
	// Promising have bought twice or three times and are on their rhythm.
	Promising = "promising"
	// FirstPurchase bought once, recently: the second order is the habit.
	FirstPurchase = "first_purchase"
	// CantLose spent the most and have stopped: win them back first.
	CantLose = "cant_lose"
	// AtRisk are past their usual gap and slipping.
	AtRisk = "at_risk"
	// OneTimeLapsed bought once, a while ago, and not again.
	OneTimeLapsed = "one_time_lapsed"
	// Hibernating are well past their rhythm, though not gone yet.
	Hibernating = "hibernating"
	// New signed in lately and have not bought yet.
	New = "new"
	// Browsers signed in long ago and never bought.
	Browsers = "browsers"
	// Lost have not bought for LostAfter.
	Lost = "lost"
)

// Keys are every segment, in order.
var Keys = []string{Champions, Loyal, Promising, FirstPurchase, CantLose, AtRisk, OneTimeLapsed, Hibernating, New, Browsers, Lost}

// Known reports whether key names a segment.
func Known(key string) bool {
	for _, known := range Keys {
		if known == key {
			return true
		}
	}
	return false
}

// The thresholds.
const (
	// NewFor is how long a customer who has not bought counts as new.
	NewFor = 14 * 24 * time.Hour
	// FirstPurchaseFor is how long a one-time buyer is a first purchase,
	// before they count as lapsed.
	FirstPurchaseFor = 30 * 24 * time.Hour
	// LostAfter is how long without an order makes any buyer lost.
	LostAfter = 120 * 24 * time.Hour
	// Window is the recent window frequency and value are read over.
	Window = 180 * 24 * time.Hour
	// OnRhythm is the due ratio up to which a repeat buyer is on their
	// rhythm (half a gap of slack); past SlippingTo they hibernate.
	OnRhythm   = 1.5
	SlippingTo = 3.0
	// ChampionOrders and LoyalOrders are the orders in Window that make a
	// champion (with high value) and a loyal customer.
	ChampionOrders = 6
	LoyalOrders    = 4
	// HighValueShare is the top share of repeat buyers counted high value.
	HighValueShare = 0.2
	// MinCycle and MaxCycle bound a customer's usual gap: two orders a day
	// apart are not a daily habit, and a buyer whose gaps are months long is
	// judged as a monthly one at worst.
	MinCycle = 2 * 24 * time.Hour
	MaxCycle = 45 * 24 * time.Hour
)

// Customer is one customer to place.
type Customer struct {
	ID        string
	CreatedAt time.Time
	// Reachable customers have a phone that takes notifications.
	Reachable bool
}

// Order is one delivered order. Cost is nil when it is not known.
type Order struct {
	ID         string
	CustomerID string
	At         time.Time
	Revenue    *big.Rat
	Cost       *big.Rat
	Discount   *big.Rat
	OfferID    string
}

// Profile is one customer, placed.
type Profile struct {
	CustomerID string `json:"customer_id"`
	Segment    string `json:"segment"`
	Reachable  bool   `json:"reachable"`
	Orders     int    `json:"orders"`
	// RecentOrders and RecentRevenue are within Window.
	RecentOrders  int        `json:"recent_orders"`
	Revenue       *big.Rat   `json:"-"`
	RecentRevenue *big.Rat   `json:"-"`
	FirstOrderAt  *time.Time `json:"first_order_at,omitempty"`
	LastOrderAt   *time.Time `json:"last_order_at,omitempty"`
	// Cycle is the customer's usual gap between purchase days (repeat
	// buyers); DueRatio how many of them have passed since the last order.
	Cycle    time.Duration `json:"-"`
	DueRatio float64       `json:"due_ratio"`
	// HighValue marks the top HighValueShare of repeat buyers by spend.
	HighValue bool `json:"high_value"`
}

// Assign places every customer. Orders of customers not listed are ignored.
func Assign(customers []Customer, orders []Order, now time.Time) map[string]*Profile {
	profiles := make(map[string]*Profile, len(customers))
	created := make(map[string]time.Time, len(customers))
	for _, customer := range customers {
		profiles[customer.ID] = &Profile{
			CustomerID: customer.ID, Reachable: customer.Reachable,
			Revenue: new(big.Rat), RecentRevenue: new(big.Rat),
		}
		created[customer.ID] = customer.CreatedAt
	}
	days := map[string][]time.Time{}
	for _, order := range orders {
		profile, ok := profiles[order.CustomerID]
		if !ok {
			continue
		}
		at := order.At
		profile.Orders++
		profile.Revenue.Add(profile.Revenue, ratOrZero(order.Revenue))
		if now.Sub(at) <= Window {
			profile.RecentOrders++
			profile.RecentRevenue.Add(profile.RecentRevenue, ratOrZero(order.Revenue))
		}
		if profile.FirstOrderAt == nil || at.Before(*profile.FirstOrderAt) {
			first := at
			profile.FirstOrderAt = &first
		}
		if profile.LastOrderAt == nil || at.After(*profile.LastOrderAt) {
			last := at
			profile.LastOrderAt = &last
		}
		days[order.CustomerID] = append(days[order.CustomerID], at)
	}

	// High value: the top share of repeat buyers, by recent spend (who is
	// worth most now) or, for one who stopped, by all they ever spent.
	var recent, lifetime []*big.Rat
	for _, profile := range profiles {
		if profile.Orders >= 2 {
			recent = append(recent, profile.RecentRevenue)
			lifetime = append(lifetime, profile.Revenue)
		}
	}
	recentBar, lifetimeBar := topShareBar(recent), topShareBar(lifetime)

	for id, profile := range profiles {
		if profile.Orders >= 2 {
			profile.Cycle = usualGap(days[id])
			profile.DueRatio = float64(now.Sub(*profile.LastOrderAt)) / float64(profile.Cycle)
			profile.HighValue = atOrAbove(profile.RecentRevenue, recentBar) || atOrAbove(profile.Revenue, lifetimeBar)
		}
		profile.Segment = place(profile, created[id], now, recentBar)
	}
	return profiles
}

func place(p *Profile, createdAt time.Time, now time.Time, recentBar *big.Rat) string {
	if p.Orders == 0 {
		if now.Sub(createdAt) <= NewFor {
			return New
		}
		return Browsers
	}
	since := now.Sub(*p.LastOrderAt)
	if since > LostAfter {
		return Lost
	}
	if p.Orders == 1 {
		if since <= FirstPurchaseFor {
			return FirstPurchase
		}
		return OneTimeLapsed
	}
	switch {
	case p.DueRatio <= OnRhythm:
		switch {
		case p.RecentOrders >= ChampionOrders && atOrAbove(p.RecentRevenue, recentBar):
			return Champions
		case p.RecentOrders >= LoyalOrders:
			return Loyal
		default:
			return Promising
		}
	case p.HighValue:
		return CantLose
	case p.DueRatio <= SlippingTo:
		return AtRisk
	default:
		return Hibernating
	}
}

// usualGap is the median gap between a customer's purchase days, bounded.
// Days, not orders: three cards bought in one sitting are one visit.
func usualGap(times []time.Time) time.Duration {
	sort.Slice(times, func(i, j int) bool { return times[i].Before(times[j]) })
	var visits []time.Time
	for _, at := range times {
		if len(visits) == 0 || at.Sub(visits[len(visits)-1]) >= 24*time.Hour {
			visits = append(visits, at)
		}
	}
	if len(visits) < 2 {
		return MinCycle
	}
	gaps := make([]time.Duration, 0, len(visits)-1)
	for i := 1; i < len(visits); i++ {
		gaps = append(gaps, visits[i].Sub(visits[i-1]))
	}
	gap := medianDuration(gaps)
	return min(max(gap, MinCycle), MaxCycle)
}

func medianDuration(values []time.Duration) time.Duration {
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	middle := len(values) / 2
	if len(values)%2 == 1 {
		return values[middle]
	}
	return (values[middle-1] + values[middle]) / 2
}

// topShareBar is the smallest value in the top HighValueShare of values; nil
// when there are none above zero.
func topShareBar(values []*big.Rat) *big.Rat {
	positive := make([]*big.Rat, 0, len(values))
	for _, value := range values {
		if value.Sign() > 0 {
			positive = append(positive, value)
		}
	}
	if len(positive) == 0 {
		return nil
	}
	sort.Slice(positive, func(i, j int) bool { return positive[i].Cmp(positive[j]) > 0 })
	top := int(float64(len(positive))*HighValueShare + 0.999999)
	top = max(1, min(top, len(positive)))
	return positive[top-1]
}

func atOrAbove(value, bar *big.Rat) bool {
	return bar != nil && value.Sign() > 0 && value.Cmp(bar) >= 0
}

func ratOrZero(value *big.Rat) *big.Rat {
	if value == nil {
		return new(big.Rat)
	}
	return value
}
