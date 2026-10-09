package relay

import (
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

func usdRate(instrument, bank, rate string, at time.Time) control.ExchangeRate {
	return control.ExchangeRate{FromCode: "USD", ToCode: "LYD", Instrument: instrument, BankCode: bank, Rate: rate, EffectiveAt: at}
}

func TestPickUSDRateFreshStaleAndSeries(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	settings := vouchers.Settings{}.Normalized()
	rates := []control.ExchangeRate{
		usdRate("cash", "", "7.00", now.Add(-5*time.Hour)),
		usdRate("cash", "", "7.20", now.Add(-time.Hour)), // newest cash wins
		usdRate("bank", "nbc", "5.10", now.Add(-time.Minute)),
		{FromCode: "EUR", ToCode: "LYD", Instrument: "cash", Rate: "9", EffectiveAt: now},
	}
	if rate, _, problem := pickUSDRate(rates, settings, now); problem != "" || rate.FloatString(2) != "7.20" {
		t.Fatalf("fresh cash: %v %q", rate, problem)
	}
	bank := vouchers.Settings{USDRateSeries: "bank", USDRateBankCode: "NBC"}.Normalized()
	if rate, _, problem := pickUSDRate(rates, bank, now); problem != "" || rate.FloatString(2) != "5.10" {
		t.Fatalf("bank series: %v %q", rate, problem)
	}
	if rate, _, problem := pickUSDRate(rates, vouchers.Settings{USDRateSeries: "bank", USDRateBankCode: "other"}.Normalized(), now); rate != nil || problem == "" {
		t.Fatal("another bank has no rate")
	}

	// Stale: older than usd_rate_max_age. The manual rate is the fallback, else Reloadly is unpriced with a reason.
	old := []control.ExchangeRate{usdRate("cash", "", "7.20", now.Add(-72*time.Hour))}
	rate, _, problem := pickUSDRate(old, settings, now)
	if rate != nil || !strings.Contains(problem, "stale") {
		t.Fatalf("stale rate must not be used: %v %q", rate, problem)
	}
	if settings.WithRateProblem(problem).Priced() {
		t.Fatal("stale and no manual rate: nothing may be priced")
	}
	manual := vouchers.Settings{USDRate: "9.5"}.Normalized().WithRateProblem(problem)
	if got, source := manual.EffectiveUSDRate(); source != vouchers.RateSourceManual || got.FloatString(1) != "9.5" {
		t.Fatalf("manual fallback: %v %s", got, source)
	}
	longer := vouchers.Settings{USDRateMaxAge: "100h"}.Normalized()
	if rate, _, _ := pickUSDRate(old, longer, now); rate == nil {
		t.Fatal("a longer max age accepts the same rate")
	}
}
