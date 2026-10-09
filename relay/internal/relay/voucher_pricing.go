package relay

import (
	"context"
	"fmt"
	"math/big"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// The live dollar rate (PRICING_V2_CONTRACT.md): Reloadly's dollar costs are
// turned into dinars at the relay's own fulus.ly rate, read from the stored
// exchange rates, not at a typed constant. A rate older than the settings'
// usd_rate_max_age is not believed: the manual usd_rate is the fallback and,
// without one, Reloadly is unpriced with a reason that says so.

const (
	liveRateWindow = 14 * 24 * time.Hour
	liveRateLimit  = 500
	liveRateTTL    = 20 * time.Second
)

// pickUSDRate is the newest USD/LYD rate of the series the settings name. rate
// is nil when there is none usable; problem then says why. at is the rate's
// publication time.
func pickUSDRate(rates []control.ExchangeRate, settings vouchers.Settings, now time.Time) (rate *big.Rat, at time.Time, problem string) {
	series, bank := settings.RateSeries()
	var best *control.ExchangeRate
	for i := range rates {
		r := &rates[i]
		if !strings.EqualFold(r.FromCode, "USD") || !strings.EqualFold(r.ToCode, "LYD") || !strings.EqualFold(r.Instrument, series) {
			continue
		}
		if series == vouchers.RateSeriesBank && !strings.EqualFold(strings.TrimSpace(r.BankCode), bank) {
			continue
		}
		if best == nil || r.EffectiveAt.After(best.EffectiveAt) {
			best = r
		}
	}
	if best == nil {
		return nil, time.Time{}, "no fulus.ly dollar rate (" + series + ") has been received"
	}
	if age, limit := now.Sub(best.EffectiveAt), settings.RateMaxAge(); age > limit {
		return nil, best.EffectiveAt, fmt.Sprintf("the fulus.ly dollar rate is stale: published %s ago, more than %s",
			age.Round(time.Minute), limit)
	}
	value, ok := new(big.Rat).SetString(strings.TrimSpace(best.Rate))
	if !ok || value.Sign() <= 0 {
		return nil, best.EffectiveAt, "the fulus.ly dollar rate does not read"
	}
	return value, best.EffectiveAt, ""
}

// withLiveRate lays the live dollar rate on settings (when they ask for it).
func (s HTTPServer) withLiveRate(ctx context.Context, settings vouchers.Settings) vouchers.Settings {
	if !settings.UsesLiveRate() {
		return settings
	}
	store, ok := s.Store.(control.ExchangeRateStore)
	if !ok {
		return settings
	}
	now := s.clock().Now()
	rates, fresh := s.VoucherSettingsCache.cachedRates(now)
	if !fresh {
		var err error
		if rates, err = store.ListExchangeRates(ctx, now.Add(-liveRateWindow), liveRateLimit); err != nil {
			s.logger().Warn("the exchange rates could not be read; the manual dollar rate is used if set", "error", err)
			return settings.WithRateProblem("the fulus.ly dollar rate could not be read")
		}
		s.VoucherSettingsCache.rememberRates(rates, now)
	}
	rate, _, problem := pickUSDRate(rates, settings, now)
	if rate == nil {
		return settings.WithRateProblem(problem)
	}
	return settings.WithLiveRate(rate)
}

func (c *VoucherSettingsCache) cachedRates(now time.Time) ([]control.ExchangeRate, bool) {
	if c == nil {
		return nil, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ratesOK && now.Sub(c.ratesAt) < liveRateTTL {
		return c.rates, true
	}
	return nil, false
}

func (c *VoucherSettingsCache) rememberRates(rates []control.ExchangeRate, now time.Time) {
	if c == nil {
		return
	}
	c.mu.Lock()
	c.rates, c.ratesAt, c.ratesOK = rates, now, true
	c.mu.Unlock()
}

// autoPricedDocument is the catalog with every price_mode=auto card priced from
// its cheapest supplier's cost by the card margin policy. A card with no known
// supplier cost keeps its written prices.
func (s HTTPServer) autoPricedDocument(document vouchers.Document, offers voucherOffers, settings vouchers.Settings) vouchers.Document {
	margin := settings.MarginFor(vouchers.ServiceKindCard)
	rate, _ := settings.EffectiveUSDRate()
	now := s.clock().Now()
	return document.WithPrices(func(item vouchers.Item) (string, string, bool) {
		if !document.AutoPriced(item) {
			return "", "", false
		}
		located, found := vouchers.Find(document, item.Key)
		if !found {
			return "", "", false
		}
		var cost *big.Rat
		for _, candidate := range s.Vouchers.rankSuppliers(located, offers, settings).Candidates {
			if candidate.Cost != nil && (cost == nil || candidate.Cost.Cmp(cost) < 0) {
				cost = candidate.Cost
			}
		}
		if cost == nil {
			return "", "", false
		}
		if strings.EqualFold(item.FaceCurrency, "LYD") {
			// A local card is sold at exactly its face value; the discount is split 80/20.
			face, _ := new(big.Rat).SetString(strings.TrimSpace(item.FaceValue))
			shop, retail, ok := margin.LocalPrices(cost, face)
			if !ok {
				return "", "", false
			}
			return vouchers.FormatDinars(shop), vouchers.FormatDinars(retail), true
		}
		shop, retail := big.NewRat(0, 1), big.NewRat(0, 1)
		if marketNow := margin.MarketNow(item.Market, rate, now); marketNow != nil {
			priced, ok := margin.MarketPrices(cost, marketNow)
			if !ok {
				return "", "", false
			}
			shop, retail = priced.ShopPays, priced.Retail
		} else {
			prices, ok := margin.Prices(cost)
			if !ok {
				return "", "", false
			}
			shop, retail = prices.ShopPays, prices.Retail
		}
		return vouchers.FormatDinars(shop), vouchers.FormatDinars(retail), true
	})
}
