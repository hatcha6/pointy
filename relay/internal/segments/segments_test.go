package segments

import (
	"math/big"
	"testing"
	"time"
)

var now = time.Date(2026, 11, 24, 12, 0, 0, 0, time.UTC)

func daysAgo(d float64) time.Time { return now.Add(-time.Duration(d * 24 * float64(time.Hour))) }

func dinars(v int64) *big.Rat { return big.NewRat(v, 1) }

// buys is a customer's orders, each `amount` dinars costing 90% of it, on the
// given days ago.
func buys(customer string, amount int64, days ...float64) []Order {
	var out []Order
	for i, d := range days {
		out = append(out, Order{
			ID: customer + "-" + itoa(i), CustomerID: customer, At: daysAgo(d),
			Revenue: dinars(amount), Cost: big.NewRat(amount*9, 10), Discount: new(big.Rat),
		})
	}
	return out
}

func TestEveryCustomerHasTheSegmentTheirBuyingEarns(t *testing.T) {
	customers := []Customer{}
	var orders []Order
	add := func(id string, signedUp float64, reachable bool, o []Order) {
		customers = append(customers, Customer{ID: id, CreatedAt: daysAgo(signedUp), Reachable: reachable})
		orders = append(orders, o...)
	}
	// Weekly buyers, big spenders, last order 3 days ago.
	add("champ", 400, true, buys("champ", 200, 3, 10, 17, 24, 31, 38, 45, 52))
	// Weekly, small orders: often but not big.
	add("loyal", 400, true, buys("loyal", 10, 2, 9, 16, 23, 30))
	// Twice, on rhythm.
	add("promising", 100, true, buys("promising", 10, 5, 15))
	add("first", 20, true, buys("first", 10, 10))
	add("lapsed", 200, false, buys("lapsed", 10, 60))
	// A big spender, weekly, silent for 4 weeks (ratio 4).
	add("cantlose", 400, true, buys("cantlose", 300, 28, 35, 42, 49, 56))
	// Weekly small buyer, 15 days quiet (ratio ~2.1).
	add("atrisk", 400, true, buys("atrisk", 10, 15, 22, 29))
	// Weekly small buyer, 40 days quiet (ratio ~5.7).
	add("hibernating", 400, true, buys("hibernating", 10, 40, 47, 54))
	add("new", 3, true, nil)
	add("browser", 90, false, nil)
	add("lost", 400, true, buys("lost", 50, 130, 140, 150))

	profiles := Assign(customers, orders, now)
	for id, want := range map[string]string{
		"champ": Champions, "loyal": Loyal, "promising": Promising, "first": FirstPurchase, "lapsed": OneTimeLapsed,
		"cantlose": CantLose, "atrisk": AtRisk, "hibernating": Hibernating, "new": New, "browser": Browsers, "lost": Lost,
	} {
		if got := profiles[id].Segment; got != want {
			t.Errorf("%s: %s, want %s (orders %d, recent %d, ratio %.2f, high %v)", id, got, want,
				profiles[id].Orders, profiles[id].RecentOrders, profiles[id].DueRatio, profiles[id].HighValue)
		}
	}
	// Their own rhythm: a week, read from their days.
	if cycle := profiles["champ"].Cycle; cycle != 7*24*time.Hour {
		t.Fatalf("champion's cycle %v", cycle)
	}

	stats, overview := Summarize(profiles, orders, now)
	if len(stats) != len(Keys) || overview.Customers != len(customers) || overview.Buyers != 9 || overview.RepeatBuyers != 7 {
		t.Fatalf("overview %+v", overview)
	}
	by := map[string]Stats{}
	for _, s := range stats {
		by[s.Key] = s
	}
	champ := by[Champions]
	if champ.Customers != 1 || champ.Orders != 8 || champ.Revenue.Cmp(dinars(1600)) != 0 || champ.Profit.Cmp(dinars(160)) != 0 {
		t.Fatalf("champions %+v", champ)
	}
	if champ.Margin() < 0.099 || champ.Margin() > 0.101 || champ.CycleDays != 7 {
		t.Fatalf("champion margin %v cycle %v", champ.Margin(), champ.CycleDays)
	}
	if by[Browsers].Reachable != 0 || by[New].Reachable != 1 {
		t.Fatalf("reach %+v %+v", by[Browsers], by[New])
	}

	insights := Insights(stats, overview)
	codes := map[string]bool{}
	for _, insight := range insights {
		codes[insight.Code] = true
	}
	for _, code := range []string{"win_back_valuable", "protect_champions"} {
		if !codes[code] {
			t.Errorf("no %s insight in %+v", code, insights)
		}
	}
}

func TestOrdersOnOneDayAreOneVisit(t *testing.T) {
	// Three cards in one sitting, then one a month later: a monthly buyer.
	times := []time.Time{daysAgo(40), daysAgo(40).Add(time.Minute), daysAgo(40).Add(2 * time.Minute), daysAgo(10)}
	if gap := usualGap(times); gap != 30*24*time.Hour {
		t.Fatalf("gap %v", gap)
	}
	// Gaps of a day are not a daily habit, and months are judged as 45 days.
	if gap := usualGap([]time.Time{daysAgo(3), daysAgo(2), daysAgo(1)}); gap != MinCycle {
		t.Fatalf("short gap %v", gap)
	}
	if gap := usualGap([]time.Time{daysAgo(200), daysAgo(100)}); gap != MaxCycle {
		t.Fatalf("long gap %v", gap)
	}
}

func TestAnOfferIsMeasuredAgainstItsHoldout(t *testing.T) {
	start := daysAgo(10)
	orders := []Order{
		{CustomerID: "a", At: daysAgo(5), Revenue: dinars(90), Cost: dinars(80), Discount: dinars(10), OfferID: "o"},
		{CustomerID: "b", At: daysAgo(4), Revenue: dinars(50), Cost: dinars(45)},
		{CustomerID: "h1", At: daysAgo(3), Revenue: dinars(50), Cost: dinars(45)},
		// Before it started: not counted for the groups.
		{CustomerID: "c", At: daysAgo(20), Revenue: dinars(50), Cost: dinars(45)},
	}
	recipients := map[string]bool{"a": true, "b": true, "c": true, "d": true}
	holdouts := map[string]bool{"h1": true, "h2": true, "h3": true, "h4": true}
	result := MeasureOffer("o", recipients, holdouts, orders, start, nil, now)
	if result.Redeemers != 1 || result.Orders != 1 || result.Discounts.Cmp(dinars(10)) != 0 || result.Profit.Cmp(dinars(10)) != 0 {
		t.Fatalf("redemptions %+v", result)
	}
	if result.RecipientRate != 0.5 || result.HoldoutRate != 0.25 || result.Lift != 0.25 {
		t.Fatalf("rates %+v", result)
	}
	if result.RevenuePerRecipient.Cmp(big.NewRat(140, 4)) != 0 || result.RevenuePerHoldout.Cmp(big.NewRat(50, 4)) != 0 {
		t.Fatalf("revenue per member %v %v", result.RevenuePerRecipient, result.RevenuePerHoldout)
	}
}
