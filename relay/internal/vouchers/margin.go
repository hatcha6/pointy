package vouchers

import (
	"fmt"
	"math/big"
	"strings"
	"time"
)

// The company's margin on one thing it sells (PRICING_V2_CONTRACT.md):
//
//	margin   = max(fixed_lyd + sum of the marginal bracket percentages of cost, min_margin_lyd)
//	shop pays = round UP to 0.01 of cost + margin * (1 - shop_share_percent/100)
//	retail    = round UP to round_step of cost + margin, never below shop pays + min_shop_margin
//
// Brackets work like tax brackets: each percentage applies only to the slice of
// cost inside its bracket, so the margin is continuous and never falls when the
// cost rises. The company keeps the rest of the margin; the shop's share of it
// is what retail leaves above the price the shop pays.

// ServiceKindCard prices a card from its cheapest supplier cost.
const ServiceKindCard = "card"

// Where the dollar rate comes from, and which fulus.ly series.
const (
	RateSourceFulus  = "fulus"
	RateSourceManual = "manual"
	RateSeriesCash   = "cash"
	RateSeriesBank   = "bank"

	DefaultRateMaxAge        = "48h"
	DefaultRateBufferPercent = "0"
)

// The demonstration margin. They are the owner's to tune.
const (
	DefaultMarginFixed      = "0.50"
	DefaultMarginMin        = "0.50"
	DefaultShopSharePercent = "35"
)

// Bracket is one slice of cost and the percentage earned on it. UpToLYD is the
// slice's upper bound in dinars; empty is open-ended (the last bracket only).
type Bracket struct {
	UpToLYD string `json:"up_to_lyd"`
	Percent string `json:"percent"`
}

// Margin is a margin policy. In a per-kind override a blank field means "the
// global value".
type Margin struct {
	FixedLYD         string    `json:"fixed_lyd,omitempty"`
	MinMarginLYD     string    `json:"min_margin_lyd,omitempty"`
	Brackets         []Bracket `json:"brackets,omitempty"`
	ShopSharePercent string    `json:"shop_share_percent,omitempty"`
	RoundStep        string    `json:"round_step,omitempty"`
	MinShopMargin    string    `json:"min_shop_margin,omitempty"`
	// Market anchoring of cards (market.go).
	MarketGapPercent string `json:"market_gap_percent,omitempty"`
	MarketMaxAgeDays string `json:"market_max_age_days,omitempty"`
	CompanyMinPct    string `json:"company_min_percent,omitempty"`
	CompanyMinLYD    string `json:"company_min_lyd,omitempty"`
	ShopMinPct       string `json:"shop_min_percent,omitempty"`
	ShopMinLYD       string `json:"shop_min_lyd,omitempty"`
	// LocalCompanyShare is the percent of a LYD-face card's discount (face - cost)
	// the company keeps; the card is always sold at face value.
	LocalCompanyShare string `json:"local_company_share_percent,omitempty"`
}

func defaultBrackets() []Bracket {
	return []Bracket{{"50", "8"}, {"200", "6"}, {"1000", "5"}, {"", "4"}}
}

func (m Margin) clone() Margin {
	m.Brackets = append([]Bracket(nil), m.Brackets...)
	return m
}

func (m Margin) trimmed() Margin {
	m.FixedLYD, m.MinMarginLYD = strings.TrimSpace(m.FixedLYD), strings.TrimSpace(m.MinMarginLYD)
	m.ShopSharePercent, m.RoundStep = strings.TrimSpace(m.ShopSharePercent), strings.TrimSpace(m.RoundStep)
	m.MinShopMargin = strings.TrimSpace(m.MinShopMargin)
	for _, f := range m.marketFields() {
		*f = strings.TrimSpace(*f)
	}
	brackets := make([]Bracket, 0, len(m.Brackets))
	for _, b := range m.Brackets {
		brackets = append(brackets, Bracket{strings.TrimSpace(b.UpToLYD), strings.TrimSpace(b.Percent)})
	}
	m.Brackets = brackets
	return m
}

// withDefaults fills every blank field.
func (m Margin) withDefaults() Margin {
	m = m.trimmed()
	m.FixedLYD = settingsOr(m.FixedLYD, DefaultMarginFixed)
	m.MinMarginLYD = settingsOr(m.MinMarginLYD, DefaultMarginMin)
	m.ShopSharePercent = settingsOr(m.ShopSharePercent, DefaultShopSharePercent)
	m.RoundStep = settingsOr(m.RoundStep, DefaultRetailStep)
	m.MinShopMargin = settingsOr(m.MinShopMargin, DefaultMinShopMargin)
	for i, f := range m.marketFields() {
		*f = settingsOr(*f, marketDefaults[i])
	}
	if len(m.Brackets) == 0 {
		m.Brackets = defaultBrackets()
	}
	return m
}

// over is m with the non-blank fields of o laid on top.
func (m Margin) over(o *Margin) Margin {
	m = m.clone()
	if o == nil {
		return m
	}
	o2 := o.trimmed()
	pick := func(dst *string, v string) {
		if v != "" {
			*dst = v
		}
	}
	pick(&m.FixedLYD, o2.FixedLYD)
	pick(&m.MinMarginLYD, o2.MinMarginLYD)
	pick(&m.ShopSharePercent, o2.ShopSharePercent)
	pick(&m.RoundStep, o2.RoundStep)
	pick(&m.MinShopMargin, o2.MinShopMargin)
	mine, theirs := m.marketFields(), o2.marketFields()
	for i := range mine {
		pick(mine[i], *theirs[i])
	}
	if len(o2.Brackets) > 0 {
		m.Brackets = o2.Brackets
	}
	return m
}

func (m Margin) same(o Margin) bool {
	a, b := m.trimmed(), o.trimmed()
	for _, pair := range [][2]string{
		{a.FixedLYD, b.FixedLYD}, {a.MinMarginLYD, b.MinMarginLYD}, {a.ShopSharePercent, b.ShopSharePercent},
		{a.RoundStep, b.RoundStep}, {a.MinShopMargin, b.MinShopMargin},
	} {
		if !settingsSameNumber(pair[0], pair[1]) {
			return false
		}
	}
	fa, fb := a.marketFields(), b.marketFields()
	for i := range fa {
		if !settingsSameNumber(*fa[i], *fb[i]) {
			return false
		}
	}
	if len(a.Brackets) != len(b.Brackets) {
		return false
	}
	for i := range a.Brackets {
		if !settingsSameNumber(a.Brackets[i].UpToLYD, b.Brackets[i].UpToLYD) ||
			!settingsSameNumber(a.Brackets[i].Percent, b.Brackets[i].Percent) {
			return false
		}
	}
	return true
}

func (m Margin) isZero() bool {
	m = m.trimmed()
	return m.FixedLYD == "" && m.MinMarginLYD == "" && len(m.Brackets) == 0 &&
		m.ShopSharePercent == "" && m.RoundStep == "" && m.MinShopMargin == "" && m.marketBlank()
}

// validate lists the problems of a margin; blank scalar fields are fine (they
// are the default or the global value).
func (m Margin) validate(prefix string, add func(path, format string, args ...any)) {
	m = m.trimmed()
	check := func(name, raw string, dinars, aboveZero bool) {
		if raw == "" {
			return
		}
		pattern, what := settingsNumberPattern, "a number without a sign"
		if dinars {
			pattern, what = settingsDinarPattern, "dinars with at most two decimals"
		}
		value, ok := settingsRat(raw, pattern)
		switch {
		case !ok:
			add(prefix+name, "must be %s, such as 0.50", what)
		case aboveZero && value.Sign() <= 0:
			add(prefix+name, "must be above zero")
		}
	}
	check("fixed_lyd", m.FixedLYD, false, false)
	check("min_margin_lyd", m.MinMarginLYD, false, false)
	check("round_step", m.RoundStep, true, true)
	check("min_shop_margin", m.MinShopMargin, true, false)
	check("shop_share_percent", m.ShopSharePercent, false, false)
	m.validateMarket(prefix, check)
	if share, ok := settingsRat(m.ShopSharePercent, settingsNumberPattern); ok && share.Cmp(settingsHundred) > 0 {
		add(prefix+"shop_share_percent", "must be between 0 and 100")
	}
	var last *big.Rat
	for i, b := range m.Brackets {
		path := fmt.Sprintf("%sbrackets[%d]", prefix, i)
		if percent, ok := settingsRat(b.Percent, settingsNumberPattern); !ok {
			add(path+".percent", "must be a number without a sign, such as 8")
		} else if percent.Cmp(settingsHundred) > 0 {
			add(path+".percent", "must be at most 100")
		}
		if b.UpToLYD == "" {
			if i != len(m.Brackets)-1 {
				add(path+".up_to_lyd", "only the last bracket may be open-ended")
			}
			continue
		}
		upTo, ok := settingsRat(b.UpToLYD, settingsNumberPattern)
		switch {
		case !ok || upTo.Sign() <= 0:
			add(path+".up_to_lyd", "must be a number above zero (leave it empty for the last, open bracket)")
		case last != nil && upTo.Cmp(last) <= 0:
			add(path+".up_to_lyd", "must be above the previous bracket's limit")
		default:
			last = upTo
		}
	}
}

// parsedMargin is a Margin read into numbers.
type parsedMargin struct {
	fixed, min, share, step, minShop *big.Rat
	limits                           []*big.Rat // nil: open
	percents                         []*big.Rat
}

func (m Margin) parse() (parsedMargin, bool) {
	m = m.withDefaults()
	var p parsedMargin
	var ok1, ok2, ok3, ok4, ok5 bool
	p.fixed, ok1 = settingsRat(m.FixedLYD, settingsNumberPattern)
	p.min, ok2 = settingsRat(m.MinMarginLYD, settingsNumberPattern)
	p.share, ok3 = settingsRat(m.ShopSharePercent, settingsNumberPattern)
	p.step, ok4 = settingsRat(m.RoundStep, settingsDinarPattern)
	p.minShop, ok5 = settingsRat(m.MinShopMargin, settingsDinarPattern)
	if !(ok1 && ok2 && ok3 && ok4 && ok5) || p.step.Sign() <= 0 || p.share.Cmp(settingsHundred) > 0 {
		return p, false
	}
	for _, b := range m.Brackets {
		percent, ok := settingsRat(b.Percent, settingsNumberPattern)
		if !ok {
			return p, false
		}
		var limit *big.Rat
		if b.UpToLYD != "" {
			if limit, ok = settingsRat(b.UpToLYD, settingsNumberPattern); !ok {
				return p, false
			}
		}
		p.limits, p.percents = append(p.limits, limit), append(p.percents, percent)
	}
	return p, true
}

// Amount is the company's total margin on something that costs it cost dinars.
func (m Margin) Amount(cost *big.Rat) (*big.Rat, bool) {
	p, ok := m.parse()
	if !ok || cost == nil || cost.Sign() < 0 {
		return nil, false
	}
	return p.amount(cost), true
}

func (p parsedMargin) amount(cost *big.Rat) *big.Rat {
	total := new(big.Rat).Set(p.fixed)
	lower := new(big.Rat)
	for i, limit := range p.limits {
		top := cost
		if limit != nil && limit.Cmp(cost) < 0 {
			top = limit
		}
		if slice := new(big.Rat).Sub(top, lower); slice.Sign() > 0 {
			total.Add(total, slice.Mul(slice, new(big.Rat).Quo(p.percents[i], settingsHundred)))
		}
		if limit == nil || limit.Cmp(cost) >= 0 {
			break
		}
		lower = limit
	}
	if total.Cmp(p.min) < 0 {
		total = new(big.Rat).Set(p.min)
	}
	return total
}

// MarginPrices are the three numbers a cost becomes.
type MarginPrices struct {
	Margin, ShopPays, Retail *big.Rat
	// Fee is the flat service fee in both prices (nil: none).
	Fee *big.Rat
}

// Prices works a cost out. ok is false when the cost is missing or negative or
// a knob does not read.
func (m Margin) Prices(cost *big.Rat) (MarginPrices, bool) {
	return m.PricesWithFee(cost, nil)
}

// PricesWithFee is Prices with a flat service fee added on top of the margin to
// both what the shop pays and the suggested retail: the company keeps all of it,
// it is not split with the shop.
func (m Margin) PricesWithFee(cost, fee *big.Rat) (MarginPrices, bool) {
	p, ok := m.parse()
	if !ok || cost == nil || cost.Sign() < 0 || (fee != nil && fee.Sign() < 0) {
		return MarginPrices{}, false
	}
	if fee == nil {
		fee = new(big.Rat)
	}
	margin := p.amount(cost)
	shopPart := new(big.Rat).Sub(settingsOne, new(big.Rat).Quo(p.share, settingsHundred))
	shopRaw := new(big.Rat).Add(cost, new(big.Rat).Mul(margin, shopPart))
	shop := settingsCeil(shopRaw.Add(shopRaw, fee), settingsCent)
	retail := new(big.Rat).Add(cost, margin)
	retail.Add(retail, fee)
	if floor := new(big.Rat).Add(shop, p.minShop); retail.Cmp(floor) < 0 {
		retail = floor
	}
	return MarginPrices{Margin: margin, ShopPays: shop, Retail: settingsCeil(retail, p.step), Fee: fee}, true
}

// MarginFor is the margin policy of a kind of service: the global one with the
// kind's own overrides laid on top.
func (s Settings) MarginFor(kind string) Margin {
	global := s.Margin.withDefaults()
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case ServiceKindCard:
		return global.over(s.CardMargin)
	case ServiceKindBill:
		return global.over(s.Bills.Margin)
	default:
		return global.over(s.Airtime.Margin)
	}
}

// legacyMargin is the margin that reproduces an old percentage pair: the whole
// retail markup is the margin, and the shop's share is what its markup took.
func legacyMargin(shopPercent, retailPercent string) *Margin {
	shop, ok1 := settingsRat(shopPercent, settingsNumberPattern)
	retail, ok2 := settingsRat(retailPercent, settingsNumberPattern)
	if !ok1 || !ok2 || retail.Sign() <= 0 {
		return nil
	}
	share := new(big.Rat).Sub(settingsOne, new(big.Rat).Quo(shop, retail))
	if share.Sign() < 0 {
		share = new(big.Rat)
	}
	text := strings.TrimRight(strings.TrimRight(new(big.Rat).Mul(share, settingsHundred).FloatString(6), "0"), ".")
	return &Margin{
		FixedLYD: "0", MinMarginLYD: "0", ShopSharePercent: text,
		Brackets: []Bracket{{"", strings.TrimRight(strings.TrimRight(retail.FloatString(6), "0"), ".")}},
	}
}

// The knobs that decide which dollar rate prices Reloadly.

// EffectiveUSDRate is the dinars-per-dollar rate Reloadly is priced at (the
// live fulus.ly rate with its buffer, else the manual rate) and where it came
// from; nil when there is none.
func (s Settings) EffectiveUSDRate() (*big.Rat, string) {
	if s.liveRate != nil && s.rateSource() != RateSourceManual {
		buffer, ok := settingsRat(settingsOr(s.USDRateBufferPercent, DefaultRateBufferPercent), settingsNumberPattern)
		if ok {
			return settingsMarkedUp(s.liveRate, buffer), RateSourceFulus
		}
	}
	if rate, ok := settingsRat(s.USDRate, settingsNumberPattern); ok && rate.Sign() > 0 {
		return rate, RateSourceManual
	}
	return nil, ""
}

func (s Settings) rateSource() string {
	if strings.ToLower(strings.TrimSpace(s.USDRateSource)) == RateSourceManual {
		return RateSourceManual
	}
	return RateSourceFulus
}

// UsesLiveRate reports whether the relay should look for a fulus.ly rate.
func (s Settings) UsesLiveRate() bool { return s.rateSource() == RateSourceFulus }

// RateSeries is the fulus.ly series (cash or bank) and, for a bank, its code.
func (s Settings) RateSeries() (series, bank string) {
	if strings.ToLower(strings.TrimSpace(s.USDRateSeries)) == RateSeriesBank {
		return RateSeriesBank, strings.ToLower(strings.TrimSpace(s.USDRateBankCode))
	}
	return RateSeriesCash, ""
}

// RateMaxAge is how old a fulus.ly rate may be before it is not believed.
func (s Settings) RateMaxAge() time.Duration {
	if d, err := time.ParseDuration(settingsOr(s.USDRateMaxAge, DefaultRateMaxAge)); err == nil && d > 0 {
		return d
	}
	d, _ := time.ParseDuration(DefaultRateMaxAge)
	return d
}

// WithLiveRate is the settings with a fresh fulus.ly rate to price by.
func (s Settings) WithLiveRate(rate *big.Rat) Settings {
	s.liveRate = rate
	return s
}

// WithRateProblem is the settings with the reason no live rate could be used.
func (s Settings) WithRateProblem(problem string) Settings {
	s.RateProblem = problem
	return s
}
