package services

import (
	"errors"
	"math/big"
	"testing"

	"pointy/relay/internal/vouchers"
)

func settingsWithRate(t *testing.T, rate string) vouchers.Settings {
	t.Helper()
	settings, err := vouchers.ParseSettings([]byte(`{"usd_rate": "` + rate + `"}`))
	if err != nil {
		t.Fatal(err)
	}
	return settings
}

func TestPriceCostFollowsTheSettings(t *testing.T) {
	settings := settingsWithRate(t, "9.71")
	// 10 dollars cost 97.10 dinars; the demo margin is 0.50 + 8 % of 50 + 6 % of
	// 47.10 = 7.326, plus the airtime service fee of 2 dinars; the shop pays 65 % of
	// the margin and the fee (102.763 -> 102.77), the customer all of it (106.426 ->
	// 106.50).
	prices, err := PriceCost(settings, KindAirtime, big.NewRat(10, 1))
	if err != nil {
		t.Fatal(err)
	}
	if prices.UnitString() != "103.87" || prices.RetailString() != "106.50" {
		t.Fatalf("prices %s / %s", prices.UnitString(), prices.RetailString())
	}
	if prices.CostLYD.Cmp(big.NewRat(9710, 100)) != 0 {
		t.Fatalf("cost %s", prices.CostLYD)
	}
	bill, err := PriceCost(settings, KindBill, big.NewRat(10, 1))
	if err != nil || bill.UnitString() != "101.87" || bill.RetailString() != "104.50" {
		t.Fatalf("bills carry no service fee by default: %v %v", bill, err)
	}
}

func TestPriceCostKeepsTheShopsMinimumMargin(t *testing.T) {
	settings, err := vouchers.ParseSettings([]byte(`{"usd_rate": "1", "margin": {"fixed_lyd": "0", "min_margin_lyd": "0", "brackets": [{"up_to_lyd": "", "percent": "0"}], "round_step": "0.01", "min_shop_margin": "0.10"}, "airtime": {"service_fee_lyd": "0"}}`))
	if err != nil {
		t.Fatal(err)
	}
	prices, err := PriceCost(settings, KindAirtime, big.NewRat(5, 1))
	if err != nil || prices.UnitString() != "5.00" || prices.RetailString() != "5.10" {
		t.Fatalf("a retail price never sits below the shop price plus the margin: %v %v", prices, err)
	}
}

func TestNothingIsPricedWithoutADollarRate(t *testing.T) {
	if _, err := PriceCost(vouchers.DefaultSettings(), KindAirtime, big.NewRat(10, 1)); !errors.Is(err, ErrRateUnset) {
		t.Fatalf("no rate must refuse to price, got %v", err)
	}
	settings := settingsWithRate(t, "9.71")
	for _, cost := range []*big.Rat{nil, new(big.Rat), big.NewRat(-1, 1)} {
		if _, err := PriceCost(settings, KindAirtime, cost); !errors.Is(err, ErrUnpriceable) {
			t.Fatalf("%v: %v", cost, err)
		}
	}
}

func TestTheAirtimeServiceFeeRidesOnBothPricesAndIsTheCompanysAlone(t *testing.T) {
	cost := big.NewRat(10, 1)
	with := settingsWithRate(t, "9.71")
	none, err := vouchers.ParseSettings([]byte(`{"usd_rate": "9.71", "airtime": {"service_fee_lyd": "0"}}`))
	if err != nil {
		t.Fatal(err)
	}
	three, err := vouchers.ParseSettings([]byte(`{"usd_rate": "9.71", "airtime": {"service_fee_lyd": "3"}}`))
	if err != nil {
		t.Fatal(err)
	}
	base, _ := PriceCost(none, KindAirtime, cost)
	if base.UnitString() != "101.87" || base.RetailString() != "104.50" {
		t.Fatalf("no fee: %s / %s", base.UnitString(), base.RetailString())
	}
	two, _ := PriceCost(with, KindAirtime, cost)
	if two.UnitString() != "103.87" || two.RetailString() != "106.50" {
		t.Fatalf("the default fee of 2: %s / %s", two.UnitString(), two.RetailString())
	}
	// Not split with the shop: the whole fee is added to what the shop pays.
	more, _ := PriceCost(three, KindAirtime, cost)
	if more.UnitString() != "104.87" || more.RetailString() != "107.50" {
		t.Fatalf("a fee of 3: %s / %s", more.UnitString(), more.RetailString())
	}
	if _, err := vouchers.ParseSettings([]byte(`{"airtime": {"service_fee_lyd": "-1"}}`)); err == nil {
		t.Fatal("a negative fee is refused")
	}
}
