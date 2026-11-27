package segments

import (
	"math/big"
	"sort"
)

// Insight is one thing worth doing, and the numbers behind it. Code names
// it (the console words it); Segments are who it is about; Impact is the
// monthly revenue it puts in play, for ordering. Values are its figures, by
// name, as decimals ("0.25" for a quarter).
type Insight struct {
	Code     string            `json:"code"`
	Segments []string          `json:"segments"`
	Impact   string            `json:"impact"`
	Values   map[string]string `json:"values"`
}

// What the insights look at.
const (
	// lowReach is the share of a segment reachable by notification below
	// which reaching them is the first problem.
	lowReach = 0.5
	// thinMargin is how far below the whole's margin a segment's must fall
	// to be called out (a quarter of it).
	thinMargin = 0.75
	// concentration is the revenue share of champions and loyal customers
	// above which the business leans on too few.
	concentration = 0.6
	// minCustomers is the size below which a segment is not worth an action.
	minCustomers = 5
)

// Insights reads the statistics into actions, the largest first.
func Insights(stats []Stats, overview Overview) []Insight {
	by := map[string]Stats{}
	for _, s := range stats {
		by[s.Key] = s
	}
	var out []Insight
	add := func(code string, impact *big.Rat, values map[string]string, keys ...string) {
		if impact == nil {
			impact = new(big.Rat)
		}
		out = append(out, Insight{Code: code, Segments: keys, Impact: impact.FloatString(3), Values: values})
	}
	monthly := func(s Stats) *big.Rat {
		// What a segment brought a month, on average, over the recent window.
		return new(big.Rat).Quo(s.RecentRevenue, big.NewRat(3, 1))
	}
	// A typical customer's month, for a segment that does not buy now.
	averageBuyerMonth := new(big.Rat)
	if overview.Buyers > 0 {
		averageBuyerMonth.Quo(overview.RecentRevenue, big.NewRat(int64(overview.Buyers)*3, 1))
	}
	worth := func(customers int, share float64) *big.Rat {
		value := new(big.Rat).Mul(averageBuyerMonth, big.NewRat(int64(customers), 1))
		share64 := new(big.Rat).SetFloat64(share)
		if share64 == nil {
			return value
		}
		return value.Mul(value, share64)
	}

	if s := by[FirstPurchase]; s.Customers >= minCustomers {
		// The second order is where a habit starts: a buyer who comes back
		// once is many times likelier to keep coming.
		add("second_purchase", worth(s.Customers, 0.25), map[string]string{
			"customers":         itoa(s.Customers),
			"reachable":         itoa(s.Reachable),
			"repeat_rate":       ftoa(overview.RepeatRate),
			"second_within_30":  ftoa(overview.SecondWithin30),
			"days_to_second":    ftoa(overview.MedianDaysToSecond),
			"average_order":     s.AverageOrder().FloatString(3),
			"suggested_percent": "10",
			"suggested_days":    "7",
		}, FirstPurchase)
	}
	if s := by[CantLose]; s.Customers >= 1 {
		at := new(big.Rat).Quo(s.Revenue, big.NewRat(6, 1))
		add("win_back_valuable", at, map[string]string{
			"customers":       itoa(s.Customers),
			"reachable":       itoa(s.Reachable),
			"revenue":         s.Revenue.FloatString(3),
			"days_since":      ftoa(s.DaysSinceLast),
			"cycle_days":      ftoa(s.CycleDays),
			"revenue_at_risk": at.FloatString(3),
		}, CantLose)
	}
	if s := by[AtRisk]; s.Customers >= minCustomers {
		add("remind_at_risk", worth(s.Customers, 0.5), map[string]string{
			"customers":  itoa(s.Customers),
			"reachable":  itoa(s.Reachable),
			"days_since": ftoa(s.DaysSinceLast),
			"cycle_days": ftoa(s.CycleDays),
		}, AtRisk)
	}
	if s := by[Champions]; s.Customers >= 1 {
		add("protect_champions", monthly(s), map[string]string{
			"customers":     itoa(s.Customers),
			"revenue_share": ftoa(s.RevenueShare),
			"profit_share":  ftoa(s.ProfitShare),
			"share":         ftoa(s.Share),
			"discounts":     s.Discounts.FloatString(3),
		}, Champions)
	}
	if s := by[Loyal]; s.Customers >= minCustomers {
		// A larger basket from those who already come: a threshold a little
		// above what they spend now, so the discount buys more, not the same.
		average := s.AverageOrder()
		threshold := new(big.Rat).Mul(average, big.NewRat(13, 10))
		add("grow_basket", new(big.Rat).Quo(monthly(s), big.NewRat(10, 1)), map[string]string{
			"customers":     itoa(s.Customers),
			"average_order": average.FloatString(3),
			"min_order":     roundUp(threshold, 5).FloatString(0),
		}, Loyal, Promising)
	}
	if n, r := by[New].Customers+by[Browsers].Customers, by[New].Reachable+by[Browsers].Reachable; n >= minCustomers {
		add("first_order", worth(n, 0.1), map[string]string{
			"customers": itoa(n),
			"new":       itoa(by[New].Customers),
			"browsers":  itoa(by[Browsers].Customers),
			"reachable": itoa(r),
		}, New, Browsers)
	}
	if n := by[Hibernating].Customers + by[OneTimeLapsed].Customers; n >= minCustomers {
		add("cheap_wake_up", worth(n, 0.05), map[string]string{
			"customers": itoa(n),
			"reachable": itoa(by[Hibernating].Reachable + by[OneTimeLapsed].Reachable),
		}, Hibernating, OneTimeLapsed)
	}
	if share := by[Champions].RevenueShare + by[Loyal].RevenueShare; share >= concentration && overview.Buyers >= minCustomers {
		add("concentration", new(big.Rat), map[string]string{
			"revenue_share": ftoa(share),
			"customers":     itoa(by[Champions].Customers + by[Loyal].Customers),
		}, Champions, Loyal)
	}
	whole := ratio(overview.Profit, overview.PricedRevenue)
	for _, s := range stats {
		if s.Orders >= minCustomers && whole > 0 && s.PricedRevenue.Sign() > 0 && s.Margin() < whole*thinMargin {
			add("thin_margin", new(big.Rat).Quo(s.Discounts, big.NewRat(3, 1)), map[string]string{
				"margin":       ftoa(s.Margin()),
				"whole_margin": ftoa(whole),
				"discounts":    s.Discounts.FloatString(3),
			}, s.Key)
		}
	}
	for _, s := range stats {
		if s.Customers >= minCustomers*2 && float64(s.Reachable) < float64(s.Customers)*lowReach {
			add("low_reach", new(big.Rat), map[string]string{
				"customers": itoa(s.Customers),
				"reachable": itoa(s.Reachable),
			}, s.Key)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, _ := new(big.Rat).SetString(out[i].Impact)
		b, _ := new(big.Rat).SetString(out[j].Impact)
		return a.Cmp(b) > 0
	})
	return out
}

// roundUp is value rounded up to a multiple of step.
func roundUp(value *big.Rat, step int64) *big.Rat {
	steps := new(big.Rat).Quo(value, big.NewRat(step, 1))
	whole := new(big.Int).Quo(steps.Num(), steps.Denom())
	if new(big.Rat).SetInt(whole).Cmp(steps) < 0 {
		whole.Add(whole, big.NewInt(1))
	}
	return new(big.Rat).SetInt(whole.Mul(whole, big.NewInt(step)))
}

func itoa(n int) string { return big.NewInt(int64(n)).String() }

func ftoa(f float64) string { return new(big.Rat).SetFloat64(f).FloatString(3) }
