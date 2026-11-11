package relay

import (
	"context"
	"math/big"
	"strings"

	"pointy/relay/internal/control"
)

// What one sale made the company, for the console's listings: every row of
// «البطاقات والخدمات» (a shop bought) and of «طلبات دفتر كروت» (a customer
// bought) carries its own cost and profit, so the operator reads what each
// one earned without opening the books.
//
// The figures follow the finance book's rule (addSupplierCosts) so the rows
// add up to its totals: a cost in dinars is taken as it is, one in dollars is
// turned at the dollar rate in force now, and any other currency is not
// guessed. Only a sale that went through and was not a test has a profit.

// saleProfit is the cost and profit of one sale, in dinars. Both are empty
// when they cannot be told.
type saleProfit struct {
	CostLYD string `json:"cost_lyd,omitempty"`
	Profit  string `json:"profit,omitempty"`
}

// costInDinars turns what a supplier charged into dinars; false when the
// figure is unreadable or its currency has no rate.
func costInDinars(cost, currency string, usdRate *big.Rat) (*big.Rat, bool) {
	value, ok := new(big.Rat).SetString(strings.TrimSpace(cost))
	if !ok {
		return nil, false
	}
	switch strings.ToUpper(strings.TrimSpace(currency)) {
	case control.FinanceCurrency:
		return value, true
	case "USD":
		if usdRate != nil {
			return value.Mul(value, usdRate), true
		}
	}
	return nil, false
}

// saleProfitOf is what the company kept of `sold` dinars once the purchase
// that supplied it is paid for.
func saleProfitOf(sold string, purchase control.VoucherPurchase, usdRate *big.Rat) saleProfit {
	if purchase.Status != control.VoucherPurchaseSucceeded || purchase.TestMode {
		return saleProfit{}
	}
	cost, ok := costInDinars(purchase.SupplierCost, purchase.SupplierCurrency, usdRate)
	if !ok {
		return saleProfit{}
	}
	out := saleProfit{CostLYD: control.FormatWalletAmount(cost)}
	if revenue, ok := new(big.Rat).SetString(strings.TrimSpace(sold)); ok {
		out.Profit = control.FormatWalletAmount(revenue.Sub(revenue, cost))
	}
	return out
}

// voucherPurchaseAdminView is a purchase with what it made the company.
type voucherPurchaseAdminView struct {
	control.VoucherPurchase
	saleProfit
}

// withPurchaseProfit prices each listed purchase. A shop's purchase earns its
// amount less its cost. The company's own purchase earns nothing (it is
// spending), and a customer's is earned by its order, so both carry the cost
// alone.
func withPurchaseProfit(purchases []control.VoucherPurchase, usdRate *big.Rat) []voucherPurchaseAdminView {
	views := make([]voucherPurchaseAdminView, 0, len(purchases))
	for _, purchase := range purchases {
		profit := saleProfitOf(purchase.Amount, purchase, usdRate)
		if purchase.ForCompany() {
			profit.Profit = ""
		}
		views = append(views, voucherPurchaseAdminView{VoucherPurchase: purchase, saleProfit: profit})
	}
	return views
}

// orderPurchases reads the supplier purchases behind customer orders: the
// recent ones in one listing, and any older one by itself.
func orderPurchases(ctx context.Context, store control.VoucherStore, orders []control.CustomerOrder) map[string]control.VoucherPurchase {
	wanted := map[string]bool{}
	for _, order := range orders {
		if order.PurchaseID != "" && order.Status == control.CustomerOrderDelivered && !order.TestMode {
			wanted[order.PurchaseID] = true
		}
	}
	found := map[string]control.VoucherPurchase{}
	if len(wanted) == 0 {
		return found
	}
	if len(wanted) > 1 {
		recent, err := store.ListVoucherPurchases(ctx, control.VoucherPurchaseFilter{
			Buyer:  control.VoucherBuyerCustomers,
			Status: control.VoucherPurchaseSucceeded,
			Limit:  500,
		})
		if err == nil {
			for _, purchase := range recent {
				if wanted[purchase.ID] {
					found[purchase.ID] = purchase
				}
			}
		}
	}
	for id := range wanted {
		if _, ok := found[id]; ok {
			continue
		}
		if purchase, err := store.GetVoucherPurchase(ctx, id); err == nil {
			found[id] = purchase
		}
	}
	return found
}

// orderProfit is what a delivered order made: its total less what its cards
// cost. The gateway fee the customer paid on top is Dafa's, in and out, and
// is no part of it.
func orderProfit(order control.CustomerOrder, purchases map[string]control.VoucherPurchase, usdRate *big.Rat) saleProfit {
	purchase, ok := purchases[order.PurchaseID]
	if !ok || order.Status != control.CustomerOrderDelivered || order.TestMode {
		return saleProfit{}
	}
	return saleProfitOf(order.Total, purchase, usdRate)
}
