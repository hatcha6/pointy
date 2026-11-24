package segments

import (
	"math/big"
	"sort"
	"time"
)

// Recent is the window "recent" money is read over in the statistics.
const Recent = 90 * 24 * time.Hour

// Money is an amount in dinars, kept exact.
type Money = *big.Rat

// Stats is what one segment is and brings.
type Stats struct {
	Key       string `json:"key"`
	Customers int    `json:"customers"`
	// Share is the segment's part of every live customer (0–1).
	Share float64 `json:"share"`
	// Reachable have a phone that takes notifications.
	Reachable int `json:"reachable"`
	// Buyers bought at least once; RepeatBuyers at least twice.
	Buyers       int `json:"buyers"`
	RepeatBuyers int `json:"repeat_buyers"`
	Orders       int `json:"orders"`
	RecentOrders int `json:"recent_orders"`
	// Revenue is what they paid (after discounts); Profit is revenue less
	// the cost of the orders whose cost is known (UnpricedOrders are not).
	Revenue        Money `json:"-"`
	RecentRevenue  Money `json:"-"`
	Profit         Money `json:"-"`
	RecentProfit   Money `json:"-"`
	Discounts      Money `json:"-"`
	UnpricedOrders int   `json:"unpriced_orders"`
	// PricedRevenue is the revenue of the orders whose cost is known: what
	// Margin is read against.
	PricedRevenue Money `json:"-"`
	// RevenueShare and ProfitShare are the segment's part of all of them.
	RevenueShare float64 `json:"revenue_share"`
	ProfitShare  float64 `json:"profit_share"`
	// CycleDays is the segment's median usual gap; DaysSinceLast its
	// median days since the last order (buyers only).
	CycleDays     float64 `json:"cycle_days"`
	DaysSinceLast float64 `json:"days_since_last"`
}

// AverageOrder is revenue per order.
func (s Stats) AverageOrder() Money { return per(s.Revenue, s.Orders) }

// RevenuePerCustomer is revenue per customer in the segment.
func (s Stats) RevenuePerCustomer() Money { return per(s.Revenue, s.Customers) }

// Margin is profit over the revenue of priced orders (0–1); 0 with none.
func (s Stats) Margin() float64 { return ratio(s.Profit, s.PricedRevenue) }

// Overview is the whole customer base.
type Overview struct {
	Customers    int `json:"customers"`
	Reachable    int `json:"reachable"`
	Buyers       int `json:"buyers"`
	RepeatBuyers int `json:"repeat_buyers"`
	// RepeatRate is repeat buyers over buyers: how many came back for a
	// second order. ActiveBuyers ordered in the last 30 days.
	RepeatRate    float64 `json:"repeat_rate"`
	ActiveBuyers  int     `json:"active_buyers"`
	Orders        int     `json:"orders"`
	Revenue       Money   `json:"-"`
	RecentRevenue Money   `json:"-"`
	Profit        Money   `json:"-"`
	RecentProfit  Money   `json:"-"`
	Discounts     Money   `json:"-"`
	// PricedRevenue is the revenue of orders whose cost is known: what the
	// margin is read against.
	PricedRevenue Money `json:"-"`
	// MedianDaysToSecond is how long buyers who came back took to.
	MedianDaysToSecond float64 `json:"median_days_to_second"`
	// SecondWithin30 is the share of buyers whose first order is at least
	// 30 days old who ordered again within those 30 days.
	SecondWithin30 float64 `json:"second_within_30"`
}

// Summarize is each segment's statistics, in Keys order, and the whole.
func Summarize(profiles map[string]*Profile, orders []Order, now time.Time) ([]Stats, Overview) {
	byKey := map[string]*Stats{}
	for _, key := range Keys {
		byKey[key] = &Stats{Key: key, Revenue: new(big.Rat), RecentRevenue: new(big.Rat), Profit: new(big.Rat),
			RecentProfit: new(big.Rat), Discounts: new(big.Rat), PricedRevenue: new(big.Rat)}
	}
	overview := Overview{Revenue: new(big.Rat), RecentRevenue: new(big.Rat), Profit: new(big.Rat),
		RecentProfit: new(big.Rat), Discounts: new(big.Rat), PricedRevenue: new(big.Rat)}
	cycles := map[string][]float64{}
	since := map[string][]float64{}
	for _, profile := range profiles {
		stats := byKey[profile.Segment]
		if stats == nil {
			continue
		}
		stats.Customers++
		overview.Customers++
		if profile.Reachable {
			stats.Reachable++
			overview.Reachable++
		}
		if profile.Orders > 0 {
			stats.Buyers++
			overview.Buyers++
			days := now.Sub(*profile.LastOrderAt).Hours() / 24
			since[profile.Segment] = append(since[profile.Segment], days)
			if days <= 30 {
				overview.ActiveBuyers++
			}
		}
		if profile.Orders >= 2 {
			stats.RepeatBuyers++
			overview.RepeatBuyers++
			cycles[profile.Segment] = append(cycles[profile.Segment], profile.Cycle.Hours()/24)
		}
	}
	for _, order := range orders {
		profile, ok := profiles[order.CustomerID]
		if !ok {
			continue
		}
		stats := byKey[profile.Segment]
		if stats == nil {
			continue
		}
		recent := now.Sub(order.At) <= Recent
		revenue := ratOrZero(order.Revenue)
		stats.Orders++
		overview.Orders++
		stats.Revenue.Add(stats.Revenue, revenue)
		overview.Revenue.Add(overview.Revenue, revenue)
		stats.Discounts.Add(stats.Discounts, ratOrZero(order.Discount))
		overview.Discounts.Add(overview.Discounts, ratOrZero(order.Discount))
		if recent {
			stats.RecentOrders++
			stats.RecentRevenue.Add(stats.RecentRevenue, revenue)
			overview.RecentRevenue.Add(overview.RecentRevenue, revenue)
		}
		if order.Cost == nil {
			stats.UnpricedOrders++
			continue
		}
		profit := new(big.Rat).Sub(revenue, order.Cost)
		stats.Profit.Add(stats.Profit, profit)
		overview.Profit.Add(overview.Profit, profit)
		overview.PricedRevenue.Add(overview.PricedRevenue, revenue)
		stats.PricedRevenue.Add(stats.PricedRevenue, revenue)
		if recent {
			stats.RecentProfit.Add(stats.RecentProfit, profit)
			overview.RecentProfit.Add(overview.RecentProfit, profit)
		}
	}
	out := make([]Stats, 0, len(Keys))
	for _, key := range Keys {
		stats := byKey[key]
		if overview.Customers > 0 {
			stats.Share = float64(stats.Customers) / float64(overview.Customers)
		}
		stats.RevenueShare = ratio(stats.Revenue, overview.Revenue)
		stats.ProfitShare = ratio(stats.Profit, overview.Profit)
		stats.CycleDays = median(cycles[key])
		stats.DaysSinceLast = median(since[key])
		out = append(out, *stats)
	}
	if overview.Buyers > 0 {
		overview.RepeatRate = float64(overview.RepeatBuyers) / float64(overview.Buyers)
	}
	overview.MedianDaysToSecond, overview.SecondWithin30 = secondPurchase(orders, profiles, now)
	return out, overview
}

// secondPurchase reads how buyers come back: the median days from a first
// order to a second, and the share of buyers (whose first order is 30 days
// old or more) who ordered again within 30 days of it.
func secondPurchase(orders []Order, profiles map[string]*Profile, now time.Time) (float64, float64) {
	byCustomer := map[string][]time.Time{}
	for _, order := range orders {
		if _, ok := profiles[order.CustomerID]; ok {
			byCustomer[order.CustomerID] = append(byCustomer[order.CustomerID], order.At)
		}
	}
	var gaps []float64
	eligible, within := 0, 0
	for _, times := range byCustomer {
		sort.Slice(times, func(i, j int) bool { return times[i].Before(times[j]) })
		first := times[0]
		var second *time.Time
		for _, at := range times[1:] {
			if at.Sub(first) >= time.Hour {
				second = &at
				break
			}
		}
		if second != nil {
			gaps = append(gaps, second.Sub(first).Hours()/24)
		}
		if now.Sub(first) >= 30*24*time.Hour {
			eligible++
			if second != nil && second.Sub(first) <= 30*24*time.Hour {
				within++
			}
		}
	}
	share := 0.0
	if eligible > 0 {
		share = float64(within) / float64(eligible)
	}
	return median(gaps), share
}

// OfferResult is what an offer did.
type OfferResult struct {
	// Redeemers used it; Orders and Revenue are the orders that took it,
	// Discounts what it gave, Profit what those orders made after cost.
	Redeemers int   `json:"redeemers"`
	Orders    int   `json:"orders"`
	Revenue   Money `json:"-"`
	Discounts Money `json:"-"`
	Profit    Money `json:"-"`
	// RecipientsBought and HoldoutsBought are the recipients and holdouts
	// who ordered anything while it ran; their rates over their counts, and
	// Lift the difference (what the offer added, when it had a holdout).
	RecipientsBought int     `json:"recipients_bought"`
	HoldoutsBought   int     `json:"holdouts_bought"`
	RecipientRate    float64 `json:"recipient_rate"`
	HoldoutRate      float64 `json:"holdout_rate"`
	Lift             float64 `json:"lift"`
	// RevenuePerRecipient and RevenuePerHoldout are everything each group
	// spent while it ran, per member: the money the offer moved, net of its
	// discounts.
	RevenuePerRecipient Money `json:"-"`
	RevenuePerHoldout   Money `json:"-"`
}

// MeasureOffer reads what offerID did between from and to (to nil: now) for
// recipients and holdouts (customer ids).
func MeasureOffer(offerID string, recipients, holdouts map[string]bool, orders []Order, from time.Time, to *time.Time, now time.Time) OfferResult {
	end := now
	if to != nil && to.Before(now) {
		end = *to
	}
	result := OfferResult{Revenue: new(big.Rat), Discounts: new(big.Rat), Profit: new(big.Rat)}
	redeemers := map[string]bool{}
	recipientBuyers, holdoutBuyers := map[string]bool{}, map[string]bool{}
	recipientRevenue, holdoutRevenue := new(big.Rat), new(big.Rat)
	for _, order := range orders {
		if order.OfferID == offerID {
			result.Orders++
			redeemers[order.CustomerID] = true
			result.Revenue.Add(result.Revenue, ratOrZero(order.Revenue))
			result.Discounts.Add(result.Discounts, ratOrZero(order.Discount))
			if order.Cost != nil {
				result.Profit.Add(result.Profit, new(big.Rat).Sub(ratOrZero(order.Revenue), order.Cost))
			}
		}
		if order.At.Before(from) || order.At.After(end) {
			continue
		}
		switch {
		case recipients[order.CustomerID]:
			recipientBuyers[order.CustomerID] = true
			recipientRevenue.Add(recipientRevenue, ratOrZero(order.Revenue))
		case holdouts[order.CustomerID]:
			holdoutBuyers[order.CustomerID] = true
			holdoutRevenue.Add(holdoutRevenue, ratOrZero(order.Revenue))
		}
	}
	result.Redeemers = len(redeemers)
	result.RecipientsBought, result.HoldoutsBought = len(recipientBuyers), len(holdoutBuyers)
	if len(recipients) > 0 {
		result.RecipientRate = float64(result.RecipientsBought) / float64(len(recipients))
	}
	if len(holdouts) > 0 {
		result.HoldoutRate = float64(result.HoldoutsBought) / float64(len(holdouts))
		result.Lift = result.RecipientRate - result.HoldoutRate
	}
	result.RevenuePerRecipient = per(recipientRevenue, len(recipients))
	result.RevenuePerHoldout = per(holdoutRevenue, len(holdouts))
	return result
}

func per(total Money, count int) Money {
	if count == 0 || total == nil {
		return new(big.Rat)
	}
	return new(big.Rat).Quo(total, big.NewRat(int64(count), 1))
}

func ratio(part, whole Money) float64 {
	if part == nil || whole == nil || whole.Sign() == 0 {
		return 0
	}
	value, _ := new(big.Rat).Quo(part, whole).Float64()
	return value
}

func median(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	middle := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[middle]
	}
	return (sorted[middle-1] + sorted[middle]) / 2
}
