package relay

import (
	"math/big"
	"net/http"
	"sort"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// financeRateHistoryLimit caps the stored rates a report reads: years of a
// few publications a day.
const financeRateHistoryLimit = 100_000

// financeRates turns a dollar cost into dinars at the rate the relay priced
// by when the cost was spent: the fulus.ly rate then in force (with the
// settings' buffer), read from the stored rate history. Revenue is in the
// dinars the sale was charged at, so its cost must be too. At today's rate,
// a rise in the dollar re-priced every past sale and the books showed a loss
// that never happened, one that grew each day the dollar did.
//
// With a manual rate, or no history, it is the one rate in force today: a
// manual rate's past values are not kept.
type financeRates struct {
	settings vouchers.Settings
	// series is the fulus.ly rates of the series priced by, oldest first.
	series []financeRatePoint
	// current is the rate priced by today.
	current *big.Rat
}

type financeRatePoint struct {
	at   time.Time
	rate *big.Rat
}

// usdAt is the rate in force during the hour starting at hour: the latest
// published before it ended (before the first one known, that first one).
func (f *financeRates) usdAt(hour time.Time) *big.Rat {
	if f == nil {
		return nil
	}
	if len(f.series) > 0 {
		end := hour.Add(time.Hour)
		i := sort.Search(len(f.series), func(i int) bool { return !f.series[i].at.Before(end) })
		point := f.series[0]
		if i > 0 {
			point = f.series[i-1]
		}
		if rate, _ := f.settings.WithLiveRate(point.rate).EffectiveUSDRate(); rate != nil {
			return rate
		}
	}
	return f.current
}

// financeRatesFor reads the dollar rates a report over costs spent since
// since needs, and what to say of them.
func (s HTTPServer) financeRatesFor(r *http.Request, since time.Time) (*financeRates, map[string]string) {
	rateInfo := map[string]string{}
	voucherStore, ok := s.Store.(control.VoucherStore)
	if !ok {
		return nil, rateInfo
	}
	settings, _, err := s.currentVoucherSettings(r.Context(), voucherStore)
	if err != nil {
		return nil, rateInfo
	}
	rates := &financeRates{settings: settings}
	current, source := settings.EffectiveUSDRate()
	rates.current = current
	if current != nil {
		rateInfo["rate"] = current.FloatString(4)
		rateInfo["source"] = source
	}
	if store, ok := s.Store.(control.ExchangeRateStore); ok && settings.UsesLiveRate() {
		// From a while before, for the rate already in force when the
		// period began.
		history, err := store.ListExchangeRates(r.Context(), since.Add(-liveRateWindow), financeRateHistoryLimit)
		if err != nil {
			s.logger().Warn("the dollar rate history could not be read; costs are at today's rate", "error", err)
		}
		for _, point := range history {
			if !inUSDSeries(point, settings) {
				continue
			}
			if value, ok := new(big.Rat).SetString(strings.TrimSpace(point.Rate)); ok && value.Sign() > 0 {
				rates.series = append(rates.series, financeRatePoint{at: point.EffectiveAt, rate: value})
			}
		}
		sort.SliceStable(rates.series, func(i, j int) bool { return rates.series[i].at.Before(rates.series[j].at) })
	}
	if len(rates.series) > 0 {
		rateInfo["basis"] = "at_spend"
	} else if current != nil {
		rateInfo["basis"] = "today"
	}
	if current == nil && len(rates.series) == 0 {
		return nil, rateInfo
	}
	return rates, rateInfo
}
