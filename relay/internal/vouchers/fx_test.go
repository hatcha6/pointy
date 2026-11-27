package vouchers

import (
	"math/big"
	"strings"
	"testing"
	"time"
)

func fxr(s string) *big.Rat {
	r, ok := new(big.Rat).SetString(s)
	if !ok {
		panic(s)
	}
	return r
}

func fxEq(t *testing.T, what string, got *big.Rat, want string) {
	t.Helper()
	if got == nil {
		t.Fatalf("%s: nil, want %s", what, want)
	}
	if got.FloatString(4) != fxr(want).FloatString(4) {
		t.Fatalf("%s: %s, want %s", what, got.FloatString(4), fxr(want).FloatString(4))
	}
}

var fxNow = time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)

func TestFXWithoutFundingUsesTheBufferAsPremium(t *testing.T) {
	q, ok := ComputeFX(FXInputs{Buffer: fxr("7"), Live: fxr("11.61"), LiveAt: fxNow, Now: fxNow})
	if !ok {
		t.Fatal("a live rate prices")
	}
	if q.PremiumSource != FXPremiumSetting {
		t.Fatalf("premium source %q", q.PremiumSource)
	}
	fxEq(t, "replacement", q.Replacement, "12.4227")
	fxEq(t, "market", q.Market, "12.4227")
	if _, ok := ComputeFX(FXInputs{Now: fxNow}); ok {
		t.Fatal("no live rate, no quote")
	}
}

// November 2026 as it happened: 120 USDT bought at 10.80 when the bank said
// 10.00 (8 %). The premium is the median of the latest three top-ups.
func TestFXLearnsThePremiumFromTheLatestTopUps(t *testing.T) {
	q, _ := ComputeFX(FXInputs{
		Buffer: fxr("7"), Live: fxr("11.61"), LiveAt: fxNow, Now: fxNow,
		Fundings: []Funding{
			{ID: "old", Supplier: "fazer", USD: fxr("50"), LYD: fxr("500"), MarketRate: fxr("10"), At: fxNow.AddDate(0, 0, -21)},     // 0 %
			{ID: "nov10", Supplier: "fazer", USD: fxr("120"), LYD: fxr("1296"), MarketRate: fxr("10"), At: fxNow.AddDate(0, 0, -16)}, // 8 %
			{ID: "too-old", Supplier: "fazer", USD: fxr("1"), LYD: fxr("50"), MarketRate: fxr("10"), At: fxNow.AddDate(0, 0, -90)},
		},
	})
	// Two eligible: 0 % and 8 %, median 4 %.
	if q.PremiumSource != FXPremiumLearned || len(q.PremiumFrom) != 2 || q.PremiumFrom[0] != "nov10" {
		t.Fatalf("learned from %v (%s)", q.PremiumFrom, q.PremiumSource)
	}
	fxEq(t, "premium", q.Premium, "0.04")

	// One odd emergency buy at 30 % over the bank does not reprice everything.
	q, _ = ComputeFX(FXInputs{Live: fxr("11.61"), LiveAt: fxNow, Now: fxNow, Fundings: []Funding{
		{ID: "a", Supplier: "fazer", USD: fxr("100"), LYD: fxr("1070"), MarketRate: fxr("10"), At: fxNow.AddDate(0, 0, -10)},
		{ID: "b", Supplier: "fazer", USD: fxr("100"), LYD: fxr("1080"), MarketRate: fxr("10"), At: fxNow.AddDate(0, 0, -5)},
		{ID: "odd", Supplier: "fazer", USD: fxr("10"), LYD: fxr("130"), MarketRate: fxr("10"), At: fxNow.AddDate(0, 0, -1)},
	}})
	fxEq(t, "median premium", q.Premium, "0.08")
	if q.PremiumHigh {
		t.Fatal("8 % is not a high premium")
	}
	q, _ = ComputeFX(FXInputs{Live: fxr("11.61"), LiveAt: fxNow, Now: fxNow, Policy: FXPolicy{PremiumTopUps: "1"}, Fundings: []Funding{
		{ID: "odd", Supplier: "fazer", USD: fxr("10"), LYD: fxr("130"), MarketRate: fxr("10"), At: fxNow.AddDate(0, 0, -1)},
	}})
	if !q.PremiumHigh {
		t.Fatal("30 % is raised as high")
	}
	fxEq(t, "replacement", q.Replacement, "15.093")
}

func TestFXCheaperDollarsNeverPriceUnderTheBank(t *testing.T) {
	q, _ := ComputeFX(FXInputs{Live: fxr("11"), LiveAt: fxNow, Now: fxNow,
		Fundings: []Funding{{ID: "a", Supplier: "fazer", USD: fxr("100"), LYD: fxr("1000"), MarketRate: fxr("11"), At: fxNow.Add(-time.Hour)}}})
	fxEq(t, "premium", q.Premium, "0")
	fxEq(t, "replacement", q.Replacement, "11")
}

func TestFXRisesPassAtOnceFallsFadeSlowly(t *testing.T) {
	// A one-day dip: 12 six hours ago, 11 now. 12 faded by 6 h at 2 %/day = 11.94.
	dip := []RatePoint{{At: fxNow.Add(-6 * time.Hour), Rate: fxr("12")}}
	q, _ := ComputeFX(FXInputs{Live: fxr("11"), LiveAt: fxNow.Add(-time.Hour), Series: dip, Now: fxNow,
		Policy: FXPolicy{MomentumSharePercent: "0"}})
	if q.Binding != "peak" {
		t.Fatalf("binding %q", q.Binding)
	}
	fxEq(t, "peak", q.Peak, "11.94")
	fxEq(t, "market", q.Market, "11.94")

	// The fade steps by whole hours: half an hour later nothing moved.
	later, _ := ComputeFX(FXInputs{Live: fxr("11"), LiveAt: fxNow.Add(-time.Hour), Series: dip, Now: fxNow.Add(30 * time.Minute),
		Policy: FXPolicy{MomentumSharePercent: "0"}})
	fxEq(t, "same hour, same rate", later.Market, "11.94")

	// At the replacement rate the peak is gone.
	at := q.AtReplacement()
	fxEq(t, "replacement market", at.Market, "11")
	settings := demoRate(nil).WithFX(q)
	if !settings.AboveReplacement() {
		t.Fatal("the peak lifts the rate")
	}
	fxEq(t, "competitors scale by the plain live rate", settings.MarketScaleRate(), "11")
	if settings.AtReplacement().AboveReplacement() {
		t.Fatal("nothing above replacement left")
	}
	if rate, _ := settings.BookRate(); rate.FloatString(2) != "11.00" {
		t.Fatalf("the books value dollars at replacement: %s", rate.FloatString(2))
	}

	// A sharp fall that has held a day is let go: 12 two days ago, 10 since
	// yesterday (the April 2026 shape: ~10 to ~8 in weeks).
	fall := []RatePoint{
		{At: fxNow.AddDate(0, 0, -2), Rate: fxr("12")},
		{At: fxNow.Add(-26 * time.Hour), Rate: fxr("10")},
		{At: fxNow.Add(-2 * time.Hour), Rate: fxr("10")},
	}
	q, _ = ComputeFX(FXInputs{Live: fxr("10"), LiveAt: fxNow.Add(-2 * time.Hour), Series: fall, Now: fxNow,
		Policy: FXPolicy{MomentumSharePercent: "0"}})
	fxEq(t, "released", q.Market, "10")

	// Past the window the spike is forgotten too.
	q, _ = ComputeFX(FXInputs{Live: fxr("11"), LiveAt: fxNow, Now: fxNow, Policy: FXPolicy{PeakDays: "0.1", MomentumSharePercent: "0"},
		Series: dip})
	fxEq(t, "market", q.Market, "11")
}

func TestFXCushionFollowsTheClimbAndIsCapped(t *testing.T) {
	series := []RatePoint{
		{At: fxNow.AddDate(0, 0, -8), Rate: fxr("10")},
		{At: fxNow.AddDate(0, 0, -3), Rate: fxr("10.5")},
	}
	// +4 % in a week, half of it: a 2 % cushion.
	q, _ := ComputeFX(FXInputs{Live: fxr("10.4"), LiveAt: fxNow, Series: series, Now: fxNow, Policy: FXPolicy{FallPercentPerDay: "100"}})
	fxEq(t, "momentum", q.Momentum, "0.04")
	fxEq(t, "cushion", q.Cushion, "0.02")
	fxEq(t, "market", q.Market, "10.608")

	// +15 % (10 -> 11.5): half is 7.5 %, capped at 5 %.
	q, _ = ComputeFX(FXInputs{Live: fxr("11.5"), LiveAt: fxNow, Series: series[:1], Now: fxNow})
	fxEq(t, "cushion", q.Cushion, "0.05")
	fxEq(t, "market", q.Market, "12.075")

	// A falling dollar adds nothing.
	q, _ = ComputeFX(FXInputs{Live: fxr("9.5"), LiveAt: fxNow, Series: series[:1], Now: fxNow})
	fxEq(t, "cushion", q.Cushion, "0")
}

func TestFXShock(t *testing.T) {
	q, _ := ComputeFX(FXInputs{Live: fxr("11.5"), LiveAt: fxNow, Now: fxNow,
		Series: []RatePoint{{At: fxNow.Add(-6 * time.Hour), Rate: fxr("11")}}})
	if !q.Shocked {
		t.Fatalf("a 4.5 %% move in a day is a shock: %s", q.Shock.FloatString(4))
	}
	q, _ = ComputeFX(FXInputs{Live: fxr("11.1"), LiveAt: fxNow, Now: fxNow,
		Series: []RatePoint{{At: fxNow.Add(-6 * time.Hour), Rate: fxr("11")}}})
	if q.Shocked {
		t.Fatal("under 1 % is no shock")
	}
}

// The capital held is valued FIFO: the dollars still at the supplier are the
// newest ones bought. By default a fall is priced at the market (the loss is
// reported, not passed on); with book_floor on, held dollars keep their cost.
func TestFXBookFloorKeepsCapital(t *testing.T) {
	in := FXInputs{
		Live: fxr("10"), LiveAt: fxNow, Now: fxNow, Policy: FXPolicy{PremiumSource: "setting", BookFloor: "on"},
		Fundings: []Funding{
			{ID: "a", Supplier: "fazer", USD: fxr("100"), LYD: fxr("1100"), At: fxNow.AddDate(0, 0, -10)},
			{ID: "b", Supplier: "fazer", USD: fxr("50"), LYD: fxr("625"), At: fxNow.AddDate(0, 0, -2)},
		},
		Balances: map[string]Balance{"fazer": {USD: fxr("80"), ReadAt: fxNow}, "reloadly": {USD: fxr("5"), ReadAt: fxNow}},
	}
	q, _ := ComputeFX(in)
	fazer := q.Books["fazer"]
	// 80 held = all 50 of b (12.50) + 30 of a (11.00): 625 + 330 = 955 -> 11.9375.
	fxEq(t, "covered", fazer.Covered, "80")
	fxEq(t, "cost", fazer.Cost, "955")
	fxEq(t, "average", fazer.Average, "11.9375")
	if fazer.Binding != "book" {
		t.Fatalf("binding %q", fazer.Binding)
	}
	fxEq(t, "rate", q.RateFor("fazer"), "11.9375")
	fxEq(t, "gain", fazer.Gain, "-155") // 80 x 10 = 800 vs 955
	reloadly := q.Books["reloadly"]
	fxEq(t, "uncovered", reloadly.Uncovered, "5")
	fxEq(t, "reloadly rate", q.RateFor("reloadly"), "10")
	fxEq(t, "unknown supplier", q.RateFor("esimaccess"), "10")

	in.Policy.BookFloor = "off"
	q, _ = ComputeFX(in)
	fxEq(t, "floor off", q.RateFor("fazer"), "10")
	fxEq(t, "the loss is still reported", q.Books["fazer"].Gain, "-155")

	in.Policy.BookFloor = ""
	q, _ = ComputeFX(in)
	fxEq(t, "off by default", q.RateFor("fazer"), "10")

	// More held than recorded: the rest is uncovered, priced at market.
	in.Balances = map[string]Balance{"fazer": {USD: fxr("200"), ReadAt: fxNow}}
	q, _ = ComputeFX(in)
	fxEq(t, "uncovered", q.Books["fazer"].Uncovered, "50")
	fxEq(t, "average of covered", q.Books["fazer"].Average, "11.5")
}

func TestFXOnSettings(t *testing.T) {
	settings := demoRate(func(s *Settings) { s.USDRateBufferPercent = "7"; s.FundingPercent = "2" })
	q, _ := ComputeFX(FXInputs{Buffer: fxr("7"), Live: fxr("10"), LiveAt: fxNow, Now: fxNow, Policy: FXPolicy{BookFloor: "on"},
		Fundings: []Funding{{ID: "a", Supplier: "fazer", USD: fxr("10"), LYD: fxr("120"), At: fxNow}},
		Balances: map[string]Balance{"fazer": {USD: fxr("10"), ReadAt: fxNow}}})
	priced := settings.WithFX(q)
	rate, source := priced.EffectiveUSDRate()
	// The buffer is the premium inside the market rate, not added twice.
	fxEq(t, "effective", rate, "10.7")
	if source != RateSourceFulus {
		t.Fatalf("source %q", source)
	}
	got, _ := priced.USDToLYD(fxr("1"))
	fxEq(t, "one dollar with the 2 % funding fee", got, "10.914")
	got, _ = priced.USDToLYDFrom("fazer", fxr("1"))
	fxEq(t, "one fazer dollar at its book", got, "12.24")
	got, _ = priced.USDToLYDFrom("reloadly", fxr("1"))
	fxEq(t, "a supplier with no book", got, "10.914")
	if got := priced.Normalized(); !got.fxApplied || got.supplierRates["fazer"] == nil {
		t.Fatal("Normalized keeps the quote")
	}
}

func TestFXPolicyValidation(t *testing.T) {
	bad := demoRate(func(s *Settings) {
		s.FX = &FXPolicy{Enabled: "maybe", PremiumSource: "guess", CushionCapPercent: "80", MomentumDays: "0",
			PeakDays: "45", PremiumTopUps: "2.5"}
	})
	paths := map[string]bool{}
	for _, p := range bad.Validate() {
		paths[p.Path] = true
	}
	for _, want := range []string{"fx.enabled", "fx.premium_source", "fx.cushion_cap_percent", "fx.momentum_days",
		"fx.peak_days", "fx.premium_top_ups"} {
		if !paths[want] {
			t.Fatalf("%s not refused: %v", want, paths)
		}
	}
	a := demoRate(nil)
	b := demoRate(func(s *Settings) { s.FX = &FXPolicy{CushionCapPercent: "5.0"} })
	if !a.Equal(b) {
		t.Fatal("the default written out is the same settings")
	}
	b.FX.CushionCapPercent = "4"
	if a.Equal(b) {
		t.Fatal("a changed knob is new settings")
	}
	// Untouched, the policy is not written: a relay from before it refuses unknown fields.
	raw, _, err := EncodeSettings(demoRate(nil))
	if err != nil || strings.Contains(string(raw), `"fx"`) {
		t.Fatalf("default settings carry no fx block: %s %v", raw, err)
	}
	raw, _, _ = EncodeSettings(b)
	if !strings.Contains(string(raw), `"cushion_cap_percent":"4"`) {
		t.Fatalf("a set knob is stored: %s", raw)
	}
}

// A top-up recorded after the balance was read is counted on top of it: the
// dollars it brought are not in that reading yet.
func TestFXBookCountsTopUpsAfterTheBalanceRead(t *testing.T) {
	read := fxNow.Add(-time.Hour)
	q, _ := ComputeFX(FXInputs{Live: fxr("10"), LiveAt: fxNow, Now: fxNow,
		Fundings: []Funding{
			{ID: "old", Supplier: "fazer", USD: fxr("100"), LYD: fxr("1000"), At: fxNow.AddDate(0, 0, -5)},
			{ID: "new", Supplier: "fazer", USD: fxr("100"), LYD: fxr("1250"), At: fxNow.Add(-10 * time.Minute)},
		},
		Balances: map[string]Balance{"fazer": {USD: fxr("20"), ReadAt: read}}})
	book := q.Books["fazer"]
	// 20 left of the old + the 100 that came after the read = 120: 100 at 12.50 + 20 at 10.
	fxEq(t, "held", book.Held, "120")
	fxEq(t, "cost", book.Cost, "1450")
}

// No fresh rate: the last rate the series holds and the latest top-up price
// the cards, with the full cushion.
func TestFXFallbackWhenTheFeedIsDown(t *testing.T) {
	stale := []RatePoint{{At: fxNow.AddDate(0, 0, -4), Rate: fxr("11")}}
	q, ok := FallbackFX(FXInputs{Buffer: fxr("7"), Series: stale, Now: fxNow})
	if !ok || !q.Fallback {
		t.Fatal("the last rate prices")
	}
	// 11 x 1.07 = 11.77, with the full 5 % cushion: 12.3585.
	fxEq(t, "fallback market", q.Market, "12.3585")

	// A top-up dearer than that is the floor of the replacement.
	q, _ = FallbackFX(FXInputs{Buffer: fxr("7"), Series: stale, Now: fxNow, Fundings: []Funding{
		{ID: "a", Supplier: "fazer", USD: fxr("100"), LYD: fxr("1300"), At: fxNow.AddDate(0, 0, -1)}}})
	fxEq(t, "never under the latest top-up", q.Market, "13.65")

	// Only a top-up, no series at all.
	q, ok = FallbackFX(FXInputs{Now: fxNow, Fundings: []Funding{
		{ID: "a", Supplier: "fazer", USD: fxr("100"), LYD: fxr("1200"), At: fxNow.AddDate(0, 0, -1)}}})
	if !ok {
		t.Fatal("a top-up alone prices")
	}
	fxEq(t, "from the top-up", q.Market, "12.6")

	if _, ok := FallbackFX(FXInputs{Now: fxNow}); ok {
		t.Fatal("nothing to go on: unpriced")
	}
}
