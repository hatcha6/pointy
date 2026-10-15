package vouchers

import (
	"math/big"
	"strings"
	"testing"
	"time"
)

func rat(s string) *big.Rat { r, _ := new(big.Rat).SetString(s); return r }

func cardMargin() Margin { return DefaultSettings().MarginFor(ServiceKindCard) }

func TestMarketNowScalesByRateAndExpires(t *testing.T) {
	m := cardMargin()
	mk := &Market{PriceLYD: "100", USDRate: "10", Captured: "2026-10-08", Competitors: 2}
	now := time.Date(2026, 10, 10, 0, 0, 0, 0, time.UTC)
	if got := m.MarketNow(mk, rat("9"), now); got == nil || got.Cmp(rat("90")) != 0 {
		t.Fatalf("market_now = %v, want 90", got)
	}
	if got := m.MarketNow(mk, rat("9"), now.AddDate(0, 0, 40)); got != nil {
		t.Fatalf("a 40-day-old market must be ignored, got %v", got)
	}
}

func TestMarketPriceGapRoundDownAndShopShare(t *testing.T) {
	m := cardMargin()
	// cost 1000, market 1200: target = 1200 x 0.97 = 1164; pool 164, shop 35 % = 57.40.
	p, ok := m.MarketPrices(rat("1000"), rat("1200"))
	if !ok || p.Retail.Cmp(rat("1164")) != 0 {
		t.Fatalf("retail = %v ok=%v, want 1164", p.Retail, ok)
	}
	if p.ShopCut.Cmp(rat("57.4")) != 0 || p.ShopPays.Cmp(rat("1106.6")) != 0 {
		t.Fatalf("shop cut %v pays %v", p.ShopCut, p.ShopPays)
	}
	// Round DOWN to the step: 1200.6 x 0.97 = 1164.582 -> 1164.50.
	if p, _ := m.MarketPrices(rat("1000"), rat("1200.6")); p.Retail.Cmp(rat("1164.5")) != 0 {
		t.Fatalf("retail = %v, want 1164.5", p.Retail)
	}
}

func TestMarketFloorsBindOnThinItems(t *testing.T) {
	m := cardMargin()
	// A PUBG-like card: cost 100, market 100.5. the formula retail (107.50) is above the floor (105.75) and the market.
	p, _ := m.MarketPrices(rat("100"), rat("100.5"))
	if !p.FloorAboveMarket || p.Retail.Cmp(p.Floor) != 0 || p.Retail.Cmp(rat("107.5")) != 0 {
		t.Fatalf("the floor must bind: %+v", p)
	}
	if p.CompanyCut.Cmp(rat("3")) < 0 || p.ShopCut.Cmp(rat("0.5")) < 0 {
		t.Fatalf("both sides must keep their floor: company %v shop %v", p.CompanyCut, p.ShopCut)
	}
}

func TestCompanyFloorRaisesRetail(t *testing.T) {
	m := cardMargin()
	m.CompanyMinPct = "30"
	m.ShopSharePercent = "50"
	p, _ := m.MarketPrices(rat("100"), rat("120"))
	if p.CompanyCut.Cmp(rat("30")) < 0 {
		t.Fatalf("company keeps %v, floor 30", p.CompanyCut)
	}
}

// Samples that ops/catalog/tools/market_report.py reproduces
// (`python3 tools/market_report.py --selftest` checks the same triples).
func TestMarketPricesAgreeWithPythonReport(t *testing.T) {
	m := cardMargin()
	for _, c := range []struct{ cost, market, retail, shop string }{
		{"1000", "1200", "1164.00", "1106.60"},
		{"100", "100.5", "107.50", "104.82"},
		{"250", "400", "388.00", "339.70"},
	} {
		p, _ := m.MarketPrices(rat(c.cost), rat(c.market))
		if p.Retail.FloatString(2) != c.retail || p.ShopPays.FloatString(2) != c.shop {
			t.Errorf("cost %s market %s: retail %s shop %s, want %s/%s", c.cost, c.market, p.Retail.FloatString(2), p.ShopPays.FloatString(2), c.retail, c.shop)
		}
	}
}

func TestLocalCardsSellAtFaceWithAFlatShopPercent(t *testing.T) {
	m := cardMargin()
	for _, c := range []struct{ cost, face, shop string }{
		{"9.70", "10", "9.80"},   // 3 % discount: the shop earns 2 %, the company 1 %
		{"9.75", "10", "9.80"},   // 2.5 %: the company keeps 0.5 %
		{"4.85", "5", "4.90"},    // 3 % on a 5-dinar card
		{"9.85", "10", "9.85"},   // 1.5 %: thinner than the shop's 2 %, all of it is the shop's
		{"24.26", "25", "24.50"}, // rounded up to a cent: the shop never earns over 2 %
	} {
		shop, retail, ok := m.LocalPrices(rat(c.cost), rat(c.face))
		if !ok || retail.Cmp(rat(c.face)) != 0 || shop.Cmp(rat(c.shop)) != 0 {
			t.Errorf("cost %s face %s: shop %v retail %v, want %s", c.cost, c.face, shop, retail, c.shop)
		}
	}
	// Never above face, even when the cost is.
	if shop, retail, _ := m.LocalPrices(rat("5.10"), rat("5")); shop.Cmp(rat("5")) != 0 || retail.Cmp(rat("5")) != 0 {
		t.Fatalf("cost over face: %v %v", shop, retail)
	}
}

func TestNormalizeKeepsMarket(t *testing.T) {
	document := Document{Brands: []Brand{{Key: "apple", Items: []Item{{
		Key:    "apple-us-10usd",
		Market: &Market{PriceLYD: " 120.00 ", USDRate: "9.76", Captured: "2026-10-11", Competitors: 3},
	}}}}}
	got := Normalize(document).Brands[0].Items[0].Market
	if got == nil || got.PriceLYD != "120.00" || got.USDRate != "9.76" || got.Captured != "2026-10-11" || got.Competitors != 3 {
		t.Fatalf("market lost in Normalize: %+v", got)
	}
	_, before, _ := Encode(Normalize(Document{Brands: []Brand{{Key: "apple", Items: []Item{{Key: "apple-us-10usd"}}}}}))
	_, after, _ := Encode(Normalize(document))
	if before == after {
		t.Fatal("a competitor price must change the catalog hash, or a push of new market data reads as unchanged")
	}
}

func TestSavedSettingsWithTheRetiredLocalShareStillLoad(t *testing.T) {
	saved := []byte(`{"margin":{"local_company_share_percent":"20"},"card_margin":{"local_company_share_percent":"20"}}`)
	settings, err := ParseSettings(saved)
	if err != nil {
		t.Fatalf("saved settings refused: %v", err)
	}
	encoded, _, _ := EncodeSettings(settings)
	if strings.Contains(string(encoded), "local_company_share_percent") || !strings.Contains(string(encoded), `"local_shop_percent":"2"`) {
		t.Fatalf("encoded %s", encoded)
	}
}
