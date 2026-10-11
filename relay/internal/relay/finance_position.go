package relay

import (
	"math/big"
	"net/http"
	"sort"
	"strings"
	"time"

	"pointy/relay/internal/control"
)

// GET /v1/finance/position: the money that is the owners' to take, as of now.
//
// It starts from everything the company ever earned: what each service sold
// for, less what it cost (supplier and Resala costs), plus the hand-written
// income, less the hand-written expenses and what the company bought from its
// suppliers for itself. Then it takes out what was earned
// on paper but never came in as money — shops' debts, charges that can still
// come back, credits given away — and what the owners already took. What is
// left is money the company holds that no shop and no supplier can claim.
// Every subtraction errs the cautious way: the answer may be a little low,
// never high.

// financeServiceCosts says which tracked cost belongs to which service.
var financeServiceCosts = map[string]string{
	"vouchers": "supplier_cost",
	"sms":      "sms_cost",
}

type financeServiceLine struct {
	Key    string `json:"key"`
	Sales  string `json:"sales"`
	Cost   string `json:"cost"`
	Profit string `json:"profit"`
	// MarginPercent is profit over sales, one decimal; empty without sales.
	MarginPercent string `json:"margin_percent"`
}

func marginPercent(profit, sales *big.Rat) string {
	if sales.Sign() <= 0 {
		return ""
	}
	margin := new(big.Rat).Quo(profit, sales)
	return margin.Mul(margin, big.NewRat(100, 1)).FloatString(1)
}

func (s HTTPServer) handleFinancePosition(w http.ResponseWriter, r *http.Request) {
	store, ok := s.financeStore(w)
	if !ok {
		return
	}
	s.postDueFinanceRecurring(r.Context(), store)
	usdRate, rateInfo := s.financeUSDRate(r)
	now := s.clock().Now()
	tracked, err := store.FinanceTracked(r.Context(),
		time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC), now.Add(24*time.Hour))
	if err != nil {
		s.writeFinanceStoreError(w, "finance position failed", err)
		return
	}
	position, err := store.FinancePosition(r.Context())
	if err != nil {
		s.writeFinanceStoreError(w, "finance position failed", err)
		return
	}

	book := newFinanceBook(usdRate)
	book.addTracked(tracked)

	// Sales, cost and profit by service.
	sales, costs, profit := new(big.Rat), new(big.Rat), new(big.Rat)
	// The book holds only tracked numbers here: "tracked:<service>" sales
	// and "tracked:<cost>" costs.
	services := map[string]bool{}
	for key := range book.income {
		services[strings.TrimPrefix(key, "tracked:")] = true
	}
	for service, costKey := range financeServiceCosts {
		if book.expense["tracked:"+costKey] != nil {
			services[service] = true
		}
	}
	lines := []financeServiceLine{}
	for service := range services {
		sold, cost := new(big.Rat), new(big.Rat)
		if value := book.income["tracked:"+service]; value != nil {
			sold.Set(value)
		}
		if costKey, ok := financeServiceCosts[service]; ok && book.expense["tracked:"+costKey] != nil {
			cost.Set(book.expense["tracked:"+costKey])
		}
		earned := new(big.Rat).Sub(sold, cost)
		sales.Add(sales, sold)
		costs.Add(costs, cost)
		profit.Add(profit, earned)
		lines = append(lines, financeServiceLine{
			Key:           service,
			Sales:         control.FormatWalletAmount(sold),
			Cost:          control.FormatWalletAmount(cost),
			Profit:        control.FormatWalletAmount(earned),
			MarginPercent: marginPercent(earned, sold),
		})
	}
	sort.Slice(lines, func(i, j int) bool {
		if c := ratOf(lines[i].Profit).Cmp(ratOf(lines[j].Profit)); c != 0 {
			return c > 0
		}
		return lines[i].Key < lines[j].Key
	})

	manualIncome := ratOf(position.Manual[control.FinanceIncome])
	manualExpense := ratOf(position.Manual[control.FinanceExpense])
	withdrawn := ratOf(position.Manual[control.FinanceWithdrawal])
	companyPurchases := new(big.Rat)
	if value := book.expense["tracked:"+financeCompanyPurchases]; value != nil {
		companyPurchases.Set(value)
	}
	netProfit := new(big.Rat).Add(profit, manualIncome)
	netProfit.Sub(netProfit, manualExpense)
	netProfit.Sub(netProfit, companyPurchases)

	owe, inFlight, goodwill := ratOf(position.ShopsOwe), ratOf(position.InFlight), ratOf(position.Goodwill)
	available := new(big.Rat).Set(netProfit)
	for _, less := range []*big.Rat{owe, inFlight, goodwill, withdrawn} {
		available.Sub(available, less)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"as_of":    now.UTC(),
		"currency": control.FinanceCurrency,
		"usd_rate": rateInfo,
		"services": lines,
		"gross": map[string]string{
			"sales":          control.FormatWalletAmount(sales),
			"cost":           control.FormatWalletAmount(costs),
			"profit":         control.FormatWalletAmount(profit),
			"margin_percent": marginPercent(profit, sales),
		},
		"manual_income":     control.FormatWalletAmount(manualIncome),
		"manual_expense":    control.FormatWalletAmount(manualExpense),
		"company_purchases": control.FormatWalletAmount(companyPurchases),
		"net_profit":        control.FormatWalletAmount(netProfit),
		"shops_owe":         position.ShopsOwe,
		"owing_shops":       position.OwingShops,
		"in_flight":         position.InFlight,
		"goodwill":          position.Goodwill,
		"withdrawn":         control.FormatWalletAmount(withdrawn),
		"available":         control.FormatWalletAmount(available),
		"shops_hold":        position.ShopsHold,
		"stock_cost":        position.StockCost,
		"unpriced":          formatRatMap(book.unpriced),
	})
}
