package relay

import (
	"math/big"
	"testing"

	"pointy/relay/internal/control"
)

func TestASaleCarriesItsCostAndProfit(t *testing.T) {
	rate := big.NewRat(10, 1)
	sold := func(cost, currency string) control.VoucherPurchase {
		return control.VoucherPurchase{
			InstallationID: "shop-1", Amount: "120.000", Status: control.VoucherPurchaseSucceeded,
			SupplierCost: cost, SupplierCurrency: currency,
		}
	}
	cases := []struct {
		name     string
		purchase control.VoucherPurchase
		rate     *big.Rat
		want     saleProfit
	}{
		{"dinars as they are", sold("100", "LYD"), rate, saleProfit{CostLYD: "100.000", Profit: "20.000"}},
		{"dollars at the rate in force", sold("11.5", "usd"), rate, saleProfit{CostLYD: "115.000", Profit: "5.000"}},
		{"a loss is a loss", sold("13", "USD"), rate, saleProfit{CostLYD: "130.000", Profit: "-10.000"}},
		{"dollars with no rate are not guessed", sold("11.5", "USD"), nil, saleProfit{}},
		{"another currency is not guessed", sold("11.5", "EUR"), rate, saleProfit{}},
		{"no cost recorded", sold("", ""), rate, saleProfit{}},
	}
	for _, c := range cases {
		if got := saleProfitOf(c.purchase.Amount, c.purchase, c.rate); got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}

	failed := sold("100", "LYD")
	failed.Status = control.VoucherPurchaseFailed
	test := sold("100", "LYD")
	test.TestMode = true
	company := sold("100", "LYD")
	company.InstallationID = ""
	views := withPurchaseProfit([]control.VoucherPurchase{sold("100", "LYD"), failed, test, company}, rate)
	if views[0].Profit != "20.000" || views[1].saleProfit != (saleProfit{}) || views[2].saleProfit != (saleProfit{}) {
		t.Fatalf("shop purchases: %+v %+v %+v", views[0].saleProfit, views[1].saleProfit, views[2].saleProfit)
	}
	// The company's own purchase is spending: its cost, and no profit.
	if views[3].CostLYD != "100.000" || views[3].Profit != "" {
		t.Fatalf("company purchase: %+v", views[3].saleProfit)
	}
}

func TestAnOrderEarnsItsTotalLessItsPurchase(t *testing.T) {
	purchases := map[string]control.VoucherPurchase{
		"p-1": {ID: "p-1", Status: control.VoucherPurchaseSucceeded, SupplierCost: "9", SupplierCurrency: "USD"},
	}
	order := control.CustomerOrder{PurchaseID: "p-1", Status: control.CustomerOrderDelivered, Total: "100.000", Fee: "2.000"}
	if got := orderProfit(order, purchases, big.NewRat(10, 1)); got != (saleProfit{CostLYD: "90.000", Profit: "10.000"}) {
		t.Fatalf("delivered: %+v", got)
	}
	refunded := order
	refunded.Status = control.CustomerOrderRefunded
	test := order
	test.TestMode = true
	unknown := order
	unknown.PurchaseID = "p-2"
	for name, o := range map[string]control.CustomerOrder{"refunded": refunded, "test": test, "unknown purchase": unknown} {
		if got := orderProfit(o, purchases, big.NewRat(10, 1)); got != (saleProfit{}) {
			t.Errorf("%s: %+v", name, got)
		}
	}
}
