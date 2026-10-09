package vouchers

import (
	"math/big"
	"strings"
	"time"
)

// Market-anchored card pricing. A card that carries a fresh competitor price is
// sold just under it, with the cost formula (margin.go) and two floors as the
// lower bound, so each sale is worth it for both the company and the shop.
//
//	market_now = market.price_lyd x (current usd rate / market.usd_rate)
//	target     = round DOWN to round_step of market_now x (1 - market_gap_percent/100)
//	floor      = round UP to round_step of cost + company_floor + shop_floor, never below the formula retail
//	  company_floor = max(company_min_lyd, cost x company_min_percent/100)
//	  shop_floor    = max(shop_min_lyd, retail x shop_min_percent/100)
//	retail     = max(target, floor); the pool (retail - cost) is split:
//	  shop cut = max(shop_floor, pool x shop_share); the company keeps the rest.

// Defaults of the market knobs, in the order of marketFields.
var marketDefaults = [7]string{"3", "30", "3", "0.50", "2.5", "0.50", "20"}

func (m *Margin) marketFields() []*string {
	return []*string{&m.MarketGapPercent, &m.MarketMaxAgeDays, &m.CompanyMinPct, &m.CompanyMinLYD, &m.ShopMinPct, &m.ShopMinLYD, &m.LocalCompanyShare}
}

func (m Margin) marketBlank() bool {
	for _, f := range m.marketFields() {
		if *f != "" {
			return false
		}
	}
	return true
}

func (m Margin) validateMarket(prefix string, check func(name, raw string, dinars, aboveZero bool)) {
	check("market_gap_percent", m.MarketGapPercent, false, false)
	check("market_max_age_days", m.MarketMaxAgeDays, false, true)
	check("company_min_percent", m.CompanyMinPct, false, false)
	check("company_min_lyd", m.CompanyMinLYD, false, false)
	check("shop_min_percent", m.ShopMinPct, false, false)
	check("shop_min_lyd", m.ShopMinLYD, false, false)
	check("local_company_share_percent", m.LocalCompanyShare, false, false)
}

// Market is a competitor price captured for a card: the cheapest known, in
// dinars at the dollar rate of that day.
type Market struct {
	PriceLYD    string `json:"price_lyd"`
	USDRate     string `json:"usd_rate"`
	Captured    string `json:"captured"` // YYYY-MM-DD
	Competitors int    `json:"competitors,omitempty"`
}

// MarketPricing is the full working of one market-anchored price.
type MarketPricing struct {
	Cost, MarketNow, Target, Floor, Retail *big.Rat // MarketNow and Target nil without fresh market data
	ShopPays, ShopCut, CompanyCut          *big.Rat
	CompanyFloor, ShopFloor                *big.Rat
	// Market is true when the price follows a fresh competitor price.
	Market bool
	// FloorAboveMarket: the floor is above market_now, so we are not the cheapest.
	FloorAboveMarket bool
}

// MarketNow is the competitor price brought to today's dollar rate; nil when
// there is no market data, it is older than market_max_age_days, or it does not
// read.
func (m Margin) MarketNow(mk *Market, rate *big.Rat, now time.Time) *big.Rat {
	if mk == nil || rate == nil || rate.Sign() <= 0 {
		return nil
	}
	price, ok1 := settingsRat(mk.PriceLYD, settingsNumberPattern)
	then, ok2 := settingsRat(mk.USDRate, settingsNumberPattern)
	days, ok3 := settingsRat(settingsOr(m.MarketMaxAgeDays, marketDefaults[1]), settingsNumberPattern)
	captured, err := time.Parse("2006-01-02", strings.TrimSpace(mk.Captured))
	if !ok1 || !ok2 || !ok3 || err != nil || price.Sign() <= 0 || then.Sign() <= 0 {
		return nil
	}
	maxAge, _ := new(big.Rat).Mul(days, big.NewRat(24, 1)).Float64()
	if now.Sub(captured).Hours() > maxAge {
		return nil
	}
	out := new(big.Rat).Mul(price, rate)
	return out.Quo(out, then)
}

func settingsFloor(x, step *big.Rat) *big.Rat {
	q := new(big.Rat).Quo(x, step)
	whole := new(big.Int).Div(q.Num(), q.Denom())
	return new(big.Rat).Mul(new(big.Rat).SetInt(whole), step)
}

func ratMax(a, b *big.Rat) *big.Rat {
	if a.Cmp(b) >= 0 {
		return a
	}
	return b
}

// MarketPrices prices a card of the given cost. With marketNow nil nothing is
// anchored: the result is the floor (used by reports); callers sell such a card
// at Margin.Prices, the plain formula, which is also the retail it never goes below.
func (m Margin) MarketPrices(cost, marketNow *big.Rat) (MarketPricing, bool) {
	p, ok := m.parse()
	formula, ok2 := m.Prices(cost)
	m = m.withDefaults()
	gap, g1 := settingsRat(m.MarketGapPercent, settingsNumberPattern)
	cPct, g2 := settingsRat(m.CompanyMinPct, settingsNumberPattern)
	cMin, g3 := settingsRat(m.CompanyMinLYD, settingsNumberPattern)
	sPct, g4 := settingsRat(m.ShopMinPct, settingsNumberPattern)
	sMin, g5 := settingsRat(m.ShopMinLYD, settingsNumberPattern)
	if !ok || !ok2 || !(g1 && g2 && g3 && g4 && g5) || sPct.Cmp(settingsHundred) >= 0 {
		return MarketPricing{}, false
	}
	out := MarketPricing{Cost: cost, MarketNow: marketNow}
	out.CompanyFloor = ratMax(cMin, new(big.Rat).Quo(new(big.Rat).Mul(cost, cPct), settingsHundred))
	sPctF := new(big.Rat).Quo(sPct, settingsHundred)
	shopFloor := func(retail *big.Rat) *big.Rat {
		return ratMax(sMin, new(big.Rat).Mul(retail, sPctF))
	}
	// Smallest retail with cost + company_floor + shop_floor(retail) <= retail.
	base := new(big.Rat).Add(cost, out.CompanyFloor)
	floor := ratMax(new(big.Rat).Add(base, sMin), new(big.Rat).Quo(base, new(big.Rat).Sub(settingsOne, sPctF)))
	out.Floor = settingsCeil(ratMax(floor, formula.Retail), p.step)
	retail := out.Floor
	if marketNow != nil {
		keep := new(big.Rat).Sub(settingsOne, new(big.Rat).Quo(gap, settingsHundred))
		out.Target = settingsFloor(new(big.Rat).Mul(marketNow, keep), p.step)
		out.Market = true
		out.FloorAboveMarket = out.Floor.Cmp(marketNow) > 0
		retail = ratMax(out.Target, out.Floor)
	}
	shareF := new(big.Rat).Quo(p.share, settingsHundred)
	for i := 0; i < 100000; i++ {
		pool := new(big.Rat).Sub(retail, cost)
		cut := ratMax(shopFloor(retail), new(big.Rat).Mul(pool, shareF))
		shop := settingsCeil(new(big.Rat).Sub(retail, cut), settingsCent)
		out.ShopPays, out.ShopCut = shop, new(big.Rat).Sub(retail, shop)
		out.CompanyCut = new(big.Rat).Sub(shop, cost)
		if out.CompanyCut.Cmp(out.CompanyFloor) >= 0 && out.ShopCut.Cmp(sMin) >= 0 {
			break
		}
		retail = new(big.Rat).Add(retail, p.step)
	}
	out.Retail = retail
	return out, true
}

// LocalPrices prices a LYD-face card: retail is exactly the face value, never
// market-anchored, and the discount (face - cost) is split with the company
// keeping local_company_share_percent: shop pays = cost + gap x company share,
// rounded up to a cent, never above the face.
func (m Margin) LocalPrices(cost, face *big.Rat) (shop, retail *big.Rat, ok bool) {
	m = m.withDefaults()
	share, good := settingsRat(m.LocalCompanyShare, settingsNumberPattern)
	if !good || share.Cmp(settingsHundred) > 0 || cost == nil || face == nil || face.Sign() <= 0 {
		return nil, nil, false
	}
	gap := new(big.Rat).Sub(face, cost)
	if gap.Sign() < 0 {
		return new(big.Rat).Set(face), new(big.Rat).Set(face), true
	}
	raw := new(big.Rat).Add(cost, gap.Mul(gap, new(big.Rat).Quo(share, settingsHundred)))
	shop = settingsCeil(raw, settingsCent)
	if shop.Cmp(face) > 0 {
		shop = new(big.Rat).Set(face)
	}
	return shop, new(big.Rat).Set(face), true
}
