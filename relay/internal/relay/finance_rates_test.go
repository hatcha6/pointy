package relay

import (
	"math/big"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

func TestADollarCostIsAtTheRateOfItsHour(t *testing.T) {
	day := time.Date(2026, 11, 20, 0, 0, 0, 0, time.UTC)
	point := func(at time.Time, rate int64) financeRatePoint {
		return financeRatePoint{at: at, rate: big.NewRat(rate, 1)}
	}
	rates := &financeRates{
		settings: vouchers.Settings{}.Normalized(),
		series:   []financeRatePoint{point(day.Add(9*time.Hour+30*time.Minute), 10), point(day.Add(48*time.Hour), 11)},
		current:  big.NewRat(11, 1),
	}
	for name, c := range map[string]struct {
		hour time.Time
		want string
	}{
		"before any rate, the first one":      {day, "10"},
		"published within the hour, in force": {day.Add(9 * time.Hour), "10"},
		"a day later, still the one then":     {day.Add(30 * time.Hour), "10"},
		"once the dollar rose, the new one":   {day.Add(48 * time.Hour), "11"},
		"long after, the latest one":          {day.Add(30 * 24 * time.Hour), "11"},
	} {
		if got := rates.usdAt(c.hour); got == nil || got.RatString() != c.want {
			t.Errorf("%s: %v, want %s", name, got, c.want)
		}
	}

	// The settings' buffer is laid on, as it was when the sale was priced.
	buffered := *rates
	buffered.settings.USDRateBufferPercent = "5"
	if got := buffered.usdAt(day.Add(30 * time.Hour)); got.FloatString(2) != "10.50" {
		t.Fatalf("buffered %v", got)
	}

	// With the funding-aware rate on, a past cost is at that hour's
	// replacement rate: the market then plus the learned refill premium.
	// Never the bare market rate (understated costs), never today's peak or
	// cushion (overstated ones).
	withFX := *rates
	withFX.settings = vouchers.Settings{USDRateBufferPercent: "5"}.Normalized().WithFX(vouchers.FXQuote{
		Live: big.NewRat(11, 1), Premium: big.NewRat(7, 100), Replacement: big.NewRat(1177, 100),
		Peak: big.NewRat(12, 1), Cushion: big.NewRat(2, 100), Market: big.NewRat(1224, 100),
	})
	if got := withFX.usdAt(day.Add(30 * time.Hour)); got == nil || got.FloatString(2) != "10.70" {
		t.Fatalf("with the funding-aware rate on: %v, want 10.70", got)
	}

	// With no history (a manual rate), it is today's.
	manual := &financeRates{current: big.NewRat(7, 1)}
	if got := manual.usdAt(day); got.RatString() != "7" {
		t.Fatalf("manual %v", got)
	}
	if (*financeRates)(nil).usdAt(day) != nil {
		t.Fatal("no rates at all prices nothing")
	}
}

func TestTheBooksDoNotMoveWithTodaysDollar(t *testing.T) {
	day := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	month := []control.FinanceTrackedMonth{{
		Month:        "2026-11",
		Revenue:      map[string]string{control.FinanceServiceCardsApp: "220"},
		SupplierCost: map[string]string{"LYD": "5"},
		ForeignCosts: []control.FinanceForeignCost{
			{Hour: day, Cost: control.FinanceCostCardsApp, Currency: "USD", Amount: "10"},
			{Hour: day.Add(24 * time.Hour), Cost: control.FinanceCostCardsApp, Currency: "USD", Amount: "10"},
			{Hour: day, Cost: control.FinanceCostSupplier, Currency: "EUR", Amount: "3"},
		},
	}}
	// Ten dinars a dollar on the 20th, eleven from the 21st.
	history := []financeRatePoint{
		{at: day.Add(-time.Hour), rate: big.NewRat(10, 1)},
		{at: day.Add(23 * time.Hour), rate: big.NewRat(11, 1)},
	}
	for _, today := range []int64{11, 15} {
		rates := &financeRates{settings: vouchers.Settings{}.Normalized(), series: history, current: big.NewRat(today, 1)}
		book := newFinanceBook(rates)
		book.addTracked(month)
		// 100 + 110 for the app's cards, 5 for the shops', whatever today's is.
		if totals := book.totals(); totals.Expense != "215.000" || totals.Net != "5.000" {
			t.Fatalf("at %d today: %+v", today, totals)
		}
		if book.unpriced["EUR"].RatString() != "3" {
			t.Fatalf("a euro cost is not guessed: %v", book.unpriced)
		}
	}
}
