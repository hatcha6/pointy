package vouchers

import (
	"math/big"
	"sort"
	"strings"
	"time"
)

// What a dollar costs the company (FX_FUNDING_PLAN.md).
//
// A dollar a supplier holds for us was bought in dinars, usually as USDT codes
// from BN Plus, at a premium over any quoted rate. Pricing a card at a market
// quote alone sold cards under what the dollars behind them cost (November 2026:
// priced at ~10.0 while every dollar had cost 10.80). The rate cards are priced
// at is therefore the HIGHER of:
//
//	replacement = live rate x (1 + refill premium)
//	              the premium is the median of the latest fx.premium_top_ups
//	              recorded top-ups (what we paid per dollar against the bank
//	              rate that day); with none, usd_rate_buffer_percent
//	peak        = the highest replacement of the last fx.peak_days, fading by
//	              fx.fall_percent_per_day in whole hours. A rise is passed on at
//	              once; a fall is only held back while it is younger than
//	              fx.release_hours ("a one-day dip"): once the lower rate has
//	              held that long the peak is let go. The central bank's April
//	              2026 injection took the street dollar from ~10 to ~8 in weeks,
//	              so a fall can be sharp and must not keep us dear for days.
//
// and while the dollar is climbing, a cushion on top:
//
//	cushion     = min(fx.cushion_cap_percent,
//	                  fx.momentum_share_percent of the rise over fx.momentum_days)
//
// covering the next refill being dearer than this one. Neither the peak nor the
// cushion ever makes a card with competitor data dearer than that competitor:
// the card pricer falls back to the replacement rate (AtReplacement).
//
// The FIFO cost of the dollars each supplier still holds is reported as the FX
// gain or loss. Pricing at it (fx.book_floor) is OFF by default: when the dollar
// falls the loss on held dollars has already happened, and holding prices at
// their old cost only adds lost sales to it ("lower of cost or market").
//
// Everything here is exact (*big.Rat) and pure: the relay gathers the inputs.

// FXPolicy holds the knobs of the funding-aware dollar rate. A blank field is
// its default.
type FXPolicy struct {
	// Enabled is "on" (default) or "off": off prices at the live rate plus
	// usd_rate_buffer_percent, as before.
	Enabled string `json:"enabled,omitempty"`
	// PremiumSource is "learned" (default: from the latest top-ups) or
	// "setting" (always usd_rate_buffer_percent).
	PremiumSource string `json:"premium_source,omitempty"`
	// PremiumMaxAgeDays: a top-up older than this teaches no premium (default
	// 60). PremiumTopUps: how many of the latest top-ups the premium is the
	// median of (default 3), so one odd top-up cannot reprice everything.
	PremiumMaxAgeDays string `json:"premium_max_age_days,omitempty"`
	PremiumTopUps     string `json:"premium_top_ups,omitempty"`
	// PeakDays is how long a high rate is remembered (default 7);
	// FallPercentPerDay how fast it fades (default 2); ReleaseHours how long a
	// lower rate must hold before the peak is let go (default 24).
	PeakDays          string `json:"peak_days,omitempty"`
	FallPercentPerDay string `json:"fall_percent_per_day,omitempty"`
	ReleaseHours      string `json:"release_hours,omitempty"`
	// MomentumDays, MomentumSharePercent and CushionCapPercent size the cushion
	// (defaults 7, 50, 5).
	MomentumDays         string `json:"momentum_days,omitempty"`
	MomentumSharePercent string `json:"momentum_share_percent,omitempty"`
	CushionCapPercent    string `json:"cushion_cap_percent,omitempty"`
	// BookFloor is "off" (default) or "on": on prices a supplier's held
	// dollars at no less than they cost, even when the market has fallen
	// below that (and the cards stop selling against competitors).
	BookFloor string `json:"book_floor,omitempty"`
	// ShockPercent: a move this large within a day is a shock the console
	// raises (default 3).
	ShockPercent string `json:"shock_percent,omitempty"`
}

// FX policy defaults: the owner's to tune.
const (
	FXPremiumLearned = "learned"
	FXPremiumSetting = "setting"

	DefaultFXPremiumMaxAgeDays    = "60"
	DefaultFXPremiumTopUps        = "3"
	DefaultFXPeakDays             = "7"
	DefaultFXFallPercentPerDay    = "2"
	DefaultFXReleaseHours         = "24"
	DefaultFXMomentumDays         = "7"
	DefaultFXMomentumSharePercent = "50"
	DefaultFXCushionCapPercent    = "5"
	DefaultFXShockPercent         = "3"

	// FXSeriesDays is how much of the rate series the relay reads; the peak
	// and momentum windows may not reach past it.
	FXSeriesDays = 30
	// FXPremiumWarnPercent: a learned premium above this is raised on the
	// console as probably a typo or an emergency buy.
	FXPremiumWarnPercent = 15
)

func (p FXPolicy) normalized() FXPolicy {
	onOff := func(v, fallback string) string {
		switch strings.ToLower(strings.TrimSpace(v)) {
		case "on", "off":
			return strings.ToLower(strings.TrimSpace(v))
		}
		return fallback
	}
	source := strings.ToLower(strings.TrimSpace(p.PremiumSource))
	if source != FXPremiumSetting {
		source = FXPremiumLearned
	}
	return FXPolicy{
		Enabled:              onOff(p.Enabled, "on"),
		PremiumSource:        source,
		PremiumMaxAgeDays:    settingsOr(p.PremiumMaxAgeDays, DefaultFXPremiumMaxAgeDays),
		PremiumTopUps:        settingsOr(p.PremiumTopUps, DefaultFXPremiumTopUps),
		PeakDays:             settingsOr(p.PeakDays, DefaultFXPeakDays),
		FallPercentPerDay:    settingsOr(p.FallPercentPerDay, DefaultFXFallPercentPerDay),
		ReleaseHours:         settingsOr(p.ReleaseHours, DefaultFXReleaseHours),
		MomentumDays:         settingsOr(p.MomentumDays, DefaultFXMomentumDays),
		MomentumSharePercent: settingsOr(p.MomentumSharePercent, DefaultFXMomentumSharePercent),
		CushionCapPercent:    settingsOr(p.CushionCapPercent, DefaultFXCushionCapPercent),
		BookFloor:            onOff(p.BookFloor, "off"),
		ShockPercent:         settingsOr(p.ShockPercent, DefaultFXShockPercent),
	}
}

func (p FXPolicy) validate(add func(path, format string, args ...any)) {
	for _, v := range []struct{ name, value string }{{"fx.enabled", p.Enabled}, {"fx.book_floor", p.BookFloor}} {
		if t := strings.ToLower(strings.TrimSpace(v.value)); t != "" && t != "on" && t != "off" {
			add(v.name, "must be on or off")
		}
	}
	if t := strings.ToLower(strings.TrimSpace(p.PremiumSource)); t != "" && t != FXPremiumLearned && t != FXPremiumSetting {
		add("fx.premium_source", "must be learned or setting")
	}
	n := p.normalized()
	for _, v := range []struct {
		name, value string
		max         int64
		positive    bool
		whole       bool
	}{
		{"fx.premium_max_age_days", n.PremiumMaxAgeDays, 365, true, false},
		{"fx.premium_top_ups", n.PremiumTopUps, 10, true, true},
		{"fx.peak_days", n.PeakDays, FXSeriesDays, false, false},
		{"fx.fall_percent_per_day", n.FallPercentPerDay, 100, false, false},
		{"fx.release_hours", n.ReleaseHours, 168, true, false},
		{"fx.momentum_days", n.MomentumDays, FXSeriesDays, true, false},
		{"fx.momentum_share_percent", n.MomentumSharePercent, 200, false, false},
		{"fx.cushion_cap_percent", n.CushionCapPercent, 50, false, false},
		{"fx.shock_percent", n.ShockPercent, 100, true, false},
	} {
		r, ok := settingsRat(v.value, settingsNumberPattern)
		switch {
		case !ok:
			add(v.name, "must be a number")
		case r.Cmp(big.NewRat(v.max, 1)) > 0:
			add(v.name, "must be at most %d", v.max)
		case v.positive && r.Sign() <= 0:
			add(v.name, "must be above zero")
		case v.whole && !r.IsInt():
			add(v.name, "must be a whole number")
		}
	}
}

func (p FXPolicy) same(o FXPolicy) bool {
	a, b := p.normalized(), o.normalized()
	if a.Enabled != b.Enabled || a.PremiumSource != b.PremiumSource || a.BookFloor != b.BookFloor {
		return false
	}
	for _, pair := range [][2]string{
		{a.PremiumMaxAgeDays, b.PremiumMaxAgeDays}, {a.PremiumTopUps, b.PremiumTopUps},
		{a.PeakDays, b.PeakDays}, {a.FallPercentPerDay, b.FallPercentPerDay}, {a.ReleaseHours, b.ReleaseHours},
		{a.MomentumDays, b.MomentumDays}, {a.MomentumSharePercent, b.MomentumSharePercent},
		{a.CushionCapPercent, b.CushionCapPercent}, {a.ShockPercent, b.ShockPercent},
	} {
		if !settingsSameNumber(pair[0], pair[1]) {
			return false
		}
	}
	return true
}

// FXRules is the settings' fx policy with every default written out.
func (s Settings) FXRules() FXPolicy {
	if s.FX == nil {
		return FXPolicy{}.normalized()
	}
	return s.FX.normalized()
}

// trimmedOrNil is the policy as stored: its fields trimmed, nil when none is set.
func (p *FXPolicy) trimmedOrNil() *FXPolicy {
	if p == nil {
		return nil
	}
	t := FXPolicy{}
	for _, f := range []struct {
		dst *string
		src string
	}{
		{&t.Enabled, p.Enabled}, {&t.PremiumSource, p.PremiumSource}, {&t.PremiumMaxAgeDays, p.PremiumMaxAgeDays},
		{&t.PremiumTopUps, p.PremiumTopUps}, {&t.PeakDays, p.PeakDays}, {&t.FallPercentPerDay, p.FallPercentPerDay},
		{&t.ReleaseHours, p.ReleaseHours}, {&t.MomentumDays, p.MomentumDays},
		{&t.MomentumSharePercent, p.MomentumSharePercent}, {&t.CushionCapPercent, p.CushionCapPercent},
		{&t.BookFloor, p.BookFloor}, {&t.ShockPercent, p.ShockPercent},
	} {
		*f.dst = strings.ToLower(strings.TrimSpace(f.src))
	}
	if t == (FXPolicy{}) {
		return nil
	}
	return &t
}

// Normalized is the policy with every default written out.
func (p FXPolicy) Normalized() FXPolicy { return p.normalized() }

// On reports whether the funding-aware rate prices.
func (p FXPolicy) On() bool { return p.normalized().Enabled == "on" }

func (p FXPolicy) rat(value string) *big.Rat {
	r, _ := settingsRat(value, settingsNumberPattern)
	if r == nil {
		return new(big.Rat)
	}
	return r
}

func (p FXPolicy) duration(value string, unit time.Duration) time.Duration {
	f, _ := p.rat(value).Float64()
	return time.Duration(f * float64(unit))
}

// RatePoint is one published rate of the series priced by.
type RatePoint struct {
	At   time.Time
	Rate *big.Rat
}

// Funding is one recorded top-up of a supplier: LYD paid, USD that arrived.
type Funding struct {
	ID       string
	Supplier string
	USD      *big.Rat
	LYD      *big.Rat
	// MarketRate is the bank rate when it was bought; nil when unknown.
	MarketRate *big.Rat
	At         time.Time
}

// Balance is a supplier's dollar balance as last read.
type Balance struct {
	USD    *big.Rat
	ReadAt time.Time
}

// FXInputs is everything the quote is worked out from.
type FXInputs struct {
	Policy FXPolicy
	// Buffer is usd_rate_buffer_percent: the premium when none is learned.
	Buffer *big.Rat
	// Live is the newest rate of the series; Series its history (any order).
	Live     *big.Rat
	LiveAt   time.Time
	Series   []RatePoint
	Fundings []Funding
	Balances map[string]Balance
	Now      time.Time
}

// FXQuote is the dollar rate cards are priced at, and every step to it.
type FXQuote struct {
	Live          *big.Rat
	LiveAt        time.Time
	Premium       *big.Rat // fraction, e.g. 0.07
	PremiumSource string   // "learned" | "setting"
	PremiumFrom   []string // the funding ids it is the median of
	PremiumHigh   bool     // above FXPremiumWarnPercent
	Replacement   *big.Rat
	Peak          *big.Rat // faded peak, >= Replacement
	PeakRaw       *big.Rat // the remembered replacement before fading
	PeakAt        time.Time
	Momentum      *big.Rat // rise over momentum_days, fraction (may be negative)
	Cushion       *big.Rat // fraction added on top
	Market        *big.Rat // max(Replacement, Peak) x (1 + Cushion)
	Binding       string   // "replacement" | "peak" (which set Market before the cushion)
	// Shock is the largest move within the last day, as a fraction of the lower
	// rate; Shocked when it reaches shock_percent.
	Shock   *big.Rat
	Shocked bool
	// Fallback: no fresh live rate; priced from the last known rate and the
	// latest top-up with the full cushion (FallbackFX).
	Fallback bool
	Books    map[string]FXBook
	// bookFloor is the policy's book_floor, kept for AtReplacement.
	bookFloor bool
}

// FXBook is the capital one supplier holds for us, valued FIFO.
type FXBook struct {
	Supplier string
	Held     *big.Rat // live balance in USD plus top-ups recorded after it was read; nil when never read
	ReadAt   time.Time
	Covered  *big.Rat // held dollars matched to recorded top-ups
	Cost     *big.Rat // what those dollars cost, LYD
	Average  *big.Rat // Cost / Covered; nil when nothing is covered
	// Uncovered is held dollars no recorded top-up explains (older funding,
	// refunds): priced at market, flagged for the operator.
	Uncovered *big.Rat
	Rate      *big.Rat // the rate this supplier's dollars are priced at
	Binding   string   // "market" | "book"
	// Value is Held at replacement; Gain is Value - (Cost + Uncovered at
	// replacement): the FX gain or loss on the capital held.
	Value *big.Rat
	Gain  *big.Rat
}

var (
	fxOne     = big.NewRat(1, 1)
	fxHundred = big.NewRat(100, 1)
)

func fxPercent(r *big.Rat) *big.Rat { return new(big.Rat).Quo(r, fxHundred) }

// learnPremium is the median premium of the latest top-ups: what was paid per
// dollar over the bank rate that day, never below zero.
func learnPremium(p FXPolicy, fundings []Funding, now time.Time) (*big.Rat, []string) {
	maxAge := p.duration(p.PremiumMaxAgeDays, 24*time.Hour)
	eligible := []Funding{}
	for _, f := range fundings {
		if f.MarketRate == nil || f.MarketRate.Sign() <= 0 || f.USD == nil || f.USD.Sign() <= 0 || f.LYD == nil {
			continue
		}
		if now.Sub(f.At) > maxAge || f.At.After(now) {
			continue
		}
		eligible = append(eligible, f)
	}
	if len(eligible) == 0 {
		return nil, nil
	}
	sort.Slice(eligible, func(i, j int) bool { return eligible[i].At.After(eligible[j].At) })
	n, _ := p.rat(p.PremiumTopUps).Float64()
	if count := int(n); count >= 1 && len(eligible) > count {
		eligible = eligible[:count]
	}
	premiums := make([]*big.Rat, 0, len(eligible))
	ids := make([]string, 0, len(eligible))
	for _, f := range eligible {
		paid := new(big.Rat).Quo(f.LYD, f.USD)
		premium := new(big.Rat).Sub(new(big.Rat).Quo(paid, f.MarketRate), fxOne)
		if premium.Sign() < 0 {
			// Dollars came cheaper than the bank quote: never price under the bank.
			premium = new(big.Rat)
		}
		premiums = append(premiums, premium)
		ids = append(ids, f.ID)
	}
	sort.Slice(premiums, func(i, j int) bool { return premiums[i].Cmp(premiums[j]) < 0 })
	mid := len(premiums) / 2
	if len(premiums)%2 == 1 {
		return premiums[mid], ids
	}
	sum := new(big.Rat).Add(premiums[mid-1], premiums[mid])
	return sum.Quo(sum, big.NewRat(2, 1)), ids
}

// ComputeFX works the quote out. ok is false without a live rate.
func ComputeFX(in FXInputs) (FXQuote, bool) {
	if in.Live == nil || in.Live.Sign() <= 0 {
		return FXQuote{}, false
	}
	p := in.Policy.normalized()
	q := FXQuote{Live: in.Live, LiveAt: in.LiveAt, Books: map[string]FXBook{}, bookFloor: p.BookFloor == "on"}

	// The refill premium.
	buffer := in.Buffer
	if buffer == nil {
		buffer = new(big.Rat)
	}
	q.Premium, q.PremiumSource = fxPercent(buffer), FXPremiumSetting
	if p.PremiumSource == FXPremiumLearned {
		if premium, ids := learnPremium(p, in.Fundings, in.Now); premium != nil {
			q.Premium, q.PremiumSource, q.PremiumFrom = premium, FXPremiumLearned, ids
		}
	}
	q.PremiumHigh = q.Premium.Cmp(fxPercent(big.NewRat(FXPremiumWarnPercent, 1))) > 0
	factor := new(big.Rat).Add(fxOne, q.Premium)
	q.Replacement = new(big.Rat).Mul(in.Live, factor)

	series := append([]RatePoint(nil), in.Series...)
	sort.Slice(series, func(i, j int) bool { return series[i].At.Before(series[j].At) })

	// The remembered peak, fading by whole hours (a price that moved every
	// second would defeat every cache keyed on it).
	q.Peak, q.PeakRaw, q.PeakAt, q.Binding = q.Replacement, q.Replacement, in.LiveAt, "replacement"
	peakWindow := p.duration(p.PeakDays, 24*time.Hour)
	release := p.duration(p.ReleaseHours, time.Hour)
	fall := fxPercent(p.rat(p.FallPercentPerDay))
	// The highest rate seen within release_hours: a peak older than a lower
	// rate that has held that long is let go.
	recentHigh := q.Replacement
	for _, point := range series {
		age := in.Now.Sub(point.At)
		if point.Rate == nil || point.Rate.Sign() <= 0 || age < 0 || age > release {
			continue
		}
		if raw := new(big.Rat).Mul(point.Rate, factor); raw.Cmp(recentHigh) > 0 {
			recentHigh = raw
		}
	}
	for _, point := range series {
		age := in.Now.Sub(point.At)
		if point.Rate == nil || point.Rate.Sign() <= 0 || age < 0 || age > peakWindow {
			continue
		}
		raw := new(big.Rat).Mul(point.Rate, factor)
		hours := new(big.Rat).SetFrac64(int64(age/time.Hour), 24)
		keep := new(big.Rat).Sub(fxOne, new(big.Rat).Mul(fall, hours))
		if keep.Sign() <= 0 {
			continue
		}
		faded := new(big.Rat).Mul(raw, keep)
		if faded.Cmp(recentHigh) > 0 {
			faded = recentHigh
		}
		if faded.Cmp(q.Peak) > 0 {
			q.Peak, q.PeakRaw, q.PeakAt, q.Binding = faded, raw, point.At, "peak"
		}
	}

	// Momentum and the cushion.
	q.Momentum, q.Cushion = new(big.Rat), new(big.Rat)
	start := in.Now.Add(-p.duration(p.MomentumDays, 24*time.Hour))
	// The rate at the start: the last one published at or before it, else (a
	// young series) the first one after it.
	var then *big.Rat
	for _, point := range series {
		if point.Rate == nil || point.Rate.Sign() <= 0 {
			continue
		}
		if point.At.After(start) {
			if then == nil {
				then = point.Rate
			}
			break
		}
		then = point.Rate
	}
	if then != nil && then.Sign() > 0 {
		q.Momentum = new(big.Rat).Sub(new(big.Rat).Quo(in.Live, then), fxOne)
		if q.Momentum.Sign() > 0 {
			cushion := new(big.Rat).Mul(q.Momentum, fxPercent(p.rat(p.MomentumSharePercent)))
			if limit := fxPercent(p.rat(p.CushionCapPercent)); cushion.Cmp(limit) > 0 {
				cushion = limit
			}
			q.Cushion = cushion
		}
	}
	q.Market = new(big.Rat).Mul(q.Peak, new(big.Rat).Add(fxOne, q.Cushion))

	// A shock: the widest swing within the last day.
	q.Shock = new(big.Rat)
	var low, high *big.Rat
	for _, point := range append(series, RatePoint{At: in.LiveAt, Rate: in.Live}) {
		if point.Rate == nil || point.Rate.Sign() <= 0 || in.Now.Sub(point.At) > 24*time.Hour || point.At.After(in.Now) {
			continue
		}
		if low == nil || point.Rate.Cmp(low) < 0 {
			low = point.Rate
		}
		if high == nil || point.Rate.Cmp(high) > 0 {
			high = point.Rate
		}
	}
	if low != nil && low.Sign() > 0 {
		q.Shock = new(big.Rat).Sub(new(big.Rat).Quo(high, low), fxOne)
		q.Shocked = q.Shock.Cmp(fxPercent(p.rat(p.ShockPercent))) >= 0
	}

	q.Books = books(in, q)
	return q, true
}

// books values each supplier's held capital FIFO: the dollars still held are
// the newest bought. A top-up recorded after the balance was read is taken to
// have arrived since, so it is added to what the balance said.
func books(in FXInputs, q FXQuote) map[string]FXBook {
	out := map[string]FXBook{}
	bySupplier := map[string][]Funding{}
	for _, f := range in.Fundings {
		if f.USD == nil || f.USD.Sign() <= 0 || f.LYD == nil || f.LYD.Sign() < 0 {
			continue
		}
		bySupplier[f.Supplier] = append(bySupplier[f.Supplier], f)
	}
	names := map[string]bool{}
	for name := range bySupplier {
		names[name] = true
	}
	for name := range in.Balances {
		names[name] = true
	}
	for name := range names {
		book := FXBook{Supplier: name, Covered: new(big.Rat), Cost: new(big.Rat), Uncovered: new(big.Rat), Rate: q.Market, Binding: "market"}
		balance, read := in.Balances[name]
		if read && balance.USD != nil {
			held := new(big.Rat).Set(balance.USD)
			if held.Sign() < 0 {
				held = new(big.Rat)
			}
			fundings := append([]Funding(nil), bySupplier[name]...)
			for _, f := range fundings {
				if f.At.After(balance.ReadAt) {
					held.Add(held, f.USD)
				}
			}
			book.Held, book.ReadAt = held, balance.ReadAt
			sort.Slice(fundings, func(i, j int) bool { return fundings[i].At.After(fundings[j].At) })
			left := new(big.Rat).Set(held)
			for _, f := range fundings {
				if left.Sign() <= 0 {
					break
				}
				take := f.USD
				if take.Cmp(left) > 0 {
					take = left
				}
				book.Covered.Add(book.Covered, take)
				book.Cost.Add(book.Cost, new(big.Rat).Mul(f.LYD, new(big.Rat).Quo(take, f.USD)))
				left = new(big.Rat).Sub(left, take)
			}
			book.Uncovered = left
			if book.Covered.Sign() > 0 {
				book.Average = new(big.Rat).Quo(book.Cost, book.Covered)
				if q.bookFloor && book.Average.Cmp(q.Market) > 0 {
					book.Rate, book.Binding = book.Average, "book"
				}
			}
			book.Value = new(big.Rat).Mul(book.Held, q.Replacement)
			basis := new(big.Rat).Add(book.Cost, new(big.Rat).Mul(book.Uncovered, q.Replacement))
			book.Gain = new(big.Rat).Sub(book.Value, basis)
		}
		out[name] = book
	}
	return out
}

// FallbackFX prices when the live rate is missing or stale (fulus.ly down, its
// subscription lapsed): from the last rate the series holds, however old, and
// never under what the latest top-up actually paid per dollar, with the full
// cushion on top because nobody knows where the dollar went meanwhile. ok is
// false when there is neither a rate nor a top-up to go on.
func FallbackFX(in FXInputs) (FXQuote, bool) {
	p := in.Policy.normalized()
	var last *RatePoint
	for i := range in.Series {
		point := &in.Series[i]
		if point.Rate != nil && point.Rate.Sign() > 0 && (last == nil || point.At.After(last.At)) {
			last = point
		}
	}
	var paid *big.Rat
	var paidAt time.Time
	for _, f := range in.Fundings {
		if f.USD == nil || f.USD.Sign() <= 0 || f.LYD == nil || f.At.After(in.Now) {
			continue
		}
		if paid == nil || f.At.After(paidAt) {
			paid, paidAt = new(big.Rat).Quo(f.LYD, f.USD), f.At
		}
	}
	var q FXQuote
	switch {
	case last != nil:
		in.Live, in.LiveAt = last.Rate, last.At
		q, _ = ComputeFX(in)
	case paid != nil:
		in.Live, in.LiveAt = paid, paidAt
		in.Buffer, in.Fundings = new(big.Rat), nil
		in.Policy.PremiumSource = FXPremiumSetting
		q, _ = ComputeFX(in)
	default:
		return FXQuote{}, false
	}
	if paid != nil && paid.Cmp(q.Replacement) > 0 {
		q.Replacement = paid
		if q.Peak.Cmp(paid) < 0 {
			q.Peak, q.Binding = paid, "replacement"
		}
	}
	q.Cushion = fxPercent(p.rat(p.CushionCapPercent))
	q.Market = new(big.Rat).Mul(q.Peak, new(big.Rat).Add(fxOne, q.Cushion))
	q.Fallback = true
	q.Books = books(in, q)
	return q, true
}

// AtReplacement is the quote at the replacement rate: no peak, no cushion,
// each book still floored when the policy says so.
func (q FXQuote) AtReplacement() FXQuote {
	out := q
	out.Peak, out.PeakRaw, out.PeakAt, out.Binding = q.Replacement, q.Replacement, q.LiveAt, "replacement"
	out.Cushion = new(big.Rat)
	out.Market = q.Replacement
	out.Books = map[string]FXBook{}
	for name, b := range q.Books {
		b.Rate, b.Binding = out.Market, "market"
		if q.bookFloor && b.Average != nil && b.Average.Cmp(out.Market) > 0 {
			b.Rate, b.Binding = b.Average, "book"
		}
		out.Books[name] = b
	}
	return out
}

// RateFor is the rate a supplier's dollars are priced at: its book's, else the market.
func (q FXQuote) RateFor(supplier string) *big.Rat {
	if book, ok := q.Books[supplier]; ok && book.Rate != nil {
		return book.Rate
	}
	return q.Market
}

// WithFX lays a quote on the settings: the market rate prices everything in
// dollars (it already holds the refill premium, so usd_rate_buffer_percent is
// not added again), each supplier's own rate its offers.
func (s Settings) WithFX(q FXQuote) Settings {
	s.liveRate = q.Market
	s.fxApplied = true
	quote := q
	s.fxQuote = &quote
	s.supplierRates = map[string]*big.Rat{}
	for name, book := range q.Books {
		if book.Rate != nil {
			s.supplierRates[name] = book.Rate
		}
	}
	return s
}

// USDToLYDFrom is USDToLYD at the rate of one supplier's dollars.
func (s Settings) USDToLYDFrom(supplier string, usd *big.Rat) (*big.Rat, bool) {
	rate, ok := s.supplierRates[strings.ToLower(strings.TrimSpace(supplier))]
	if !ok || rate == nil || rate.Sign() <= 0 {
		return s.USDToLYD(usd)
	}
	if usd == nil || usd.Sign() < 0 {
		return nil, false
	}
	funding, ok := settingsRat(settingsOr(s.FundingPercent, DefaultFundingPercent), settingsNumberPattern)
	if !ok {
		return nil, false
	}
	return settingsMarkedUp(new(big.Rat).Mul(usd, rate), funding), true
}

// AboveReplacement reports whether the peak or the cushion lifts the rate over
// the replacement rate now: the card pricer then checks the competitor price.
func (s Settings) AboveReplacement() bool {
	return s.fxQuote != nil && s.fxQuote.Market.Cmp(s.fxQuote.Replacement) > 0
}

// AtReplacement is the settings priced at the replacement rate (see FXQuote.AtReplacement).
func (s Settings) AtReplacement() Settings {
	if s.fxQuote == nil {
		return s
	}
	return s.WithFX(s.fxQuote.AtReplacement())
}

// FXQuote is the quote laid on the settings; nil without one.
func (s Settings) FXQuote() *FXQuote { return s.fxQuote }

// MarketScaleRate is the rate competitor prices captured at another rate are
// moved by: the plain live rate, which is what competitors' own costs follow,
// without our refill premium, peak or cushion. The manual rate when there is
// no live one.
func (s Settings) MarketScaleRate() *big.Rat {
	if s.fxQuote != nil && s.fxQuote.Live != nil {
		return s.fxQuote.Live
	}
	if s.liveRate != nil && s.rateSource() != RateSourceManual {
		return s.liveRate
	}
	rate, _ := s.EffectiveUSDRate()
	return rate
}

// ReplacementFrom is the replacement rate a market rate stood for: what a
// dollar cost to buy again when the market was at raw. With the funding-aware
// rate on, raw plus the refill premium the quote learned (the plain market
// rate would understate every dollar cost); otherwise raw as Reloadly was
// priced by it then (the buffer on top). The finance books value a past
// dollar cost at the rate of its own hour through this.
func (s Settings) ReplacementFrom(raw *big.Rat) *big.Rat {
	if raw == nil || raw.Sign() <= 0 {
		return nil
	}
	if s.fxApplied && s.fxQuote != nil && s.fxQuote.Premium != nil {
		return new(big.Rat).Mul(raw, new(big.Rat).Add(fxOne, s.fxQuote.Premium))
	}
	rate, _ := s.WithLiveRate(raw).EffectiveUSDRate()
	return rate
}

// BookRate is the rate the company's dollars are valued at in its books: the
// replacement rate (what it costs to buy one now), never our peak or cushion.
func (s Settings) BookRate() (*big.Rat, string) {
	if s.fxQuote != nil && s.fxQuote.Replacement != nil {
		return s.fxQuote.Replacement, RateSourceFulus
	}
	return s.EffectiveUSDRate()
}
