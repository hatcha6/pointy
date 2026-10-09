package vouchers

import (
	"math/big"
	"math/rand"
	"testing"
)

func ladder(t *testing.T, cost string) MarginPrices {
	t.Helper()
	prices, ok := DefaultSettings().MarginFor(ServiceKindAirtime).Prices(settingsRatOf(t, cost))
	if !ok {
		t.Fatalf("no prices for %s", cost)
	}
	return prices
}

func TestMarginLadderDemoNumbers(t *testing.T) {
	// fixed 0.50 + 8% to 50, 6% to 200, 5% to 1000, 4% above; split 65-35; step 0.25.
	for cost, want := range map[string][3]string{
		"20":   {"2.10", "21.37", "22.25"},
		"100":  {"7.50", "104.88", "107.50"},
		"500":  {"28.50", "518.53", "528.50"},
		"1000": {"53.50", "1034.78", "1053.50"},
	} {
		got := ladder(t, cost)
		if FormatDinars(got.Margin) != want[0] || FormatDinars(got.ShopPays) != want[1] || FormatDinars(got.Retail) != want[2] {
			t.Errorf("cost %s: margin %s shop %s retail %s, want %v", cost, FormatDinars(got.Margin),
				FormatDinars(got.ShopPays), FormatDinars(got.Retail), want)
		}
	}
}

func TestMarginIsMonotoneAndContinuousAtEveryBracketEdge(t *testing.T) {
	margin := DefaultSettings().MarginFor("airtime")
	eps := big.NewRat(1, 1000)
	for _, edge := range []int64{50, 200, 1000} {
		at := big.NewRat(edge, 1)
		below, _ := margin.Amount(new(big.Rat).Sub(at, eps))
		on, _ := margin.Amount(at)
		above, _ := margin.Amount(new(big.Rat).Add(at, eps))
		if below.Cmp(on) > 0 || on.Cmp(above) > 0 {
			t.Fatalf("margin falls across %d", edge)
		}
		if new(big.Rat).Sub(above, below).Cmp(big.NewRat(1, 100)) > 0 {
			t.Fatalf("margin jumps across %d: %s -> %s", edge, below.FloatString(4), above.FloatString(4))
		}
	}
	random := rand.New(rand.NewSource(7))
	last := new(big.Rat)
	for cost := int64(0); cost < 5000; cost += 1 + random.Int63n(40) {
		m, ok := margin.Amount(big.NewRat(cost, 1))
		if !ok || m.Cmp(last) < 0 {
			t.Fatalf("margin fell at %d: %v < %v", cost, m, last)
		}
		last = m
	}
}

func TestMarginMinimumAndSplit(t *testing.T) {
	// A margin that would be tiny is lifted to the minimum.
	m := Margin{FixedLYD: "0", MinMarginLYD: "2", Brackets: []Bracket{{"", "1"}}, ShopSharePercent: "0"}
	got, _ := m.Prices(big.NewRat(10, 1))
	if FormatDinars(got.Margin) != "2.00" || FormatDinars(got.ShopPays) != "12.00" {
		t.Fatalf("the minimum margin must lift it, and a 0 share leaves all to the company: %+v", got)
	}
	// The shop keeping 100 % pays the bare cost.
	full := Margin{ShopSharePercent: "100"}
	got, _ = full.Prices(big.NewRat(40, 1))
	if FormatDinars(got.ShopPays) != "40.00" || got.Retail.Cmp(got.ShopPays) <= 0 {
		t.Fatalf("a 100 %% share: %+v", got)
	}
}

func TestMarginRoundingGuarantees(t *testing.T) {
	random := rand.New(rand.NewSource(20261008))
	margin := DefaultSettings().MarginFor("bill")
	hundred, step, floor := big.NewRat(100, 1), big.NewRat(1, 4), big.NewRat(1, 10)
	for i := 0; i < 2000; i++ {
		cost := big.NewRat(random.Int63n(300_000_000), 1000)
		p, _ := margin.Prices(cost)
		exact := new(big.Rat).Add(cost, new(big.Rat).Mul(p.Margin, big.NewRat(65, 100)))
		if p.ShopPays.Cmp(exact) < 0 || new(big.Rat).Sub(p.ShopPays, exact).Cmp(settingsCent) >= 0 {
			t.Fatalf("shop pays %s is not %s rounded up to a cent", p.ShopPays.FloatString(4), exact.FloatString(6))
		}
		if !new(big.Rat).Mul(p.ShopPays, hundred).IsInt() || !new(big.Rat).Quo(p.Retail, step).IsInt() {
			t.Fatalf("not on its grid: %s / %s", p.ShopPays.FloatString(4), p.Retail.FloatString(4))
		}
		if p.Retail.Cmp(new(big.Rat).Add(p.ShopPays, floor)) < 0 || p.Retail.Cmp(new(big.Rat).Add(cost, p.Margin)) < 0 {
			t.Fatalf("retail %s too low for cost %s", p.Retail.FloatString(2), cost.FloatString(3))
		}
	}
}

func TestMarginOverridesAndLegacy(t *testing.T) {
	s := Settings{Airtime: ServicePricing{Margin: &Margin{FixedLYD: "5"}}}.Normalized()
	if s.MarginFor("airtime").FixedLYD != "5" || s.MarginFor("bill").FixedLYD != "0.50" || len(s.MarginFor("airtime").Brackets) != 4 {
		t.Fatalf("overrides lay over the global margin: %+v", s.MarginFor("airtime"))
	}
	// An old document with the demo percentages decides nothing; others keep their meaning.
	old := Settings{Airtime: ServicePricing{ShopMarkupPercent: "3", RetailMarkupPercent: "6"}}.Normalized()
	if old.Airtime.Margin == nil || old.Airtime.ShopMarkupPercent != "" {
		t.Fatalf("legacy pair not migrated: %+v", old.Airtime)
	}
	p, _ := old.MarginFor("airtime").Prices(big.NewRat(100, 1))
	if FormatDinars(p.ShopPays) != "103.00" || FormatDinars(p.Retail) != "106.00" {
		t.Fatalf("legacy 3 %% / 6 %% on 100: %+v", p)
	}
	if demo := (Settings{Airtime: ServicePricing{ShopMarkupPercent: "2", RetailMarkupPercent: "5.50"}}).Normalized(); demo.Airtime.Margin != nil {
		t.Fatal("the old demo pair must fall to the new demo margin")
	}
	if problems := (Settings{Margin: Margin{Brackets: []Bracket{{"100", "5"}, {"50", "4"}}}}).Validate(); len(problems) == 0 {
		t.Fatal("descending brackets must be refused")
	}
}

func TestEffectiveRate(t *testing.T) {
	s := Settings{USDRate: "9.00", USDRateBufferPercent: "1"}.Normalized()
	if rate, src := s.EffectiveUSDRate(); src != RateSourceManual || rate.Cmp(big.NewRat(9, 1)) != 0 {
		t.Fatal("manual fallback")
	}
	live := s.WithLiveRate(big.NewRat(10, 1))
	if rate, src := live.EffectiveUSDRate(); src != RateSourceFulus || rate.Cmp(big.NewRat(101, 10)) != 0 {
		t.Fatalf("live + 1%% buffer: %v %s", rate, src)
	}
	manual := Settings{USDRate: "9.00", USDRateSource: "manual"}.Normalized().WithLiveRate(big.NewRat(10, 1))
	if _, src := manual.EffectiveUSDRate(); src != RateSourceManual {
		t.Fatal("manual source ignores the live rate")
	}
	if (Settings{}).Normalized().WithLiveRate(nil).Priced() {
		t.Fatal("no rate, no price")
	}
}

func TestCardAutoPriceMode(t *testing.T) {
	doc := Document{PriceMode: "auto", Brands: []Brand{{Items: []Item{
		{Key: "a", Price: "1.00", RetailPrice: "2.00"},
		{Key: "b", Price: "1.00", RetailPrice: "2.00", PriceMode: "static"},
	}}}}
	if !doc.AutoPriced(doc.Brands[0].Items[0]) || doc.AutoPriced(doc.Brands[0].Items[1]) {
		t.Fatal("the item's mode beats the catalog's default")
	}
	// A card margin override prices cards only.
	s := Settings{CardMargin: &Margin{FixedLYD: "3"}}.Normalized()
	cardPrices, _ := s.MarginFor(ServiceKindCard).Prices(big.NewRat(100, 1))
	airtimePrices, _ := s.MarginFor(ServiceKindAirtime).Prices(big.NewRat(100, 1))
	if cardPrices.Margin.Cmp(airtimePrices.Margin) <= 0 {
		t.Fatal("the card margin override must apply to cards only")
	}
	priced := doc.WithPrices(func(it Item) (string, string, bool) { return "9.00", "10.00", it.Key == "a" })
	if priced.Brands[0].Items[0].Price != "9.00" || doc.Brands[0].Items[0].Price != "1.00" || priced.Brands[0].Items[1].Price != "1.00" {
		t.Fatal("WithPrices must copy, and touch only the items it prices")
	}
	if problems := Validate(Document{PriceMode: "weird"}, ValidateOptions{}); len(problems) == 0 {
		t.Fatal("an unknown price mode must be refused")
	}
}
