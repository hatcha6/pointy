package services

import (
	"math/big"
	"strings"

	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
)

// How an amount is ordered from Reloadly, and so what it costs the company.
//
// The customer always picks an amount in the recipient's own currency (5,000 CFA
// francs). Reloadly pays its commission on an order placed in dollars and
// forfeits it on one placed in the local currency, so the company decides, per the
// pricing settings (vouchers.Settings: order_mode, usd_buffer_percent), what to
// order:
//
//   - airtime, usd (the default): the order goes out in dollars, rounded UP from
//     the local amount at Reloadly's own rate plus a small buffer, so the
//     recipient receives at least what was asked. A fixed operator is ordered
//     with the dollar plan aligned with the local plan the customer picked. An
//     amount whose dollar order falls outside the operator's dollar limits is
//     ordered in the local currency instead, never refused for it.
//   - airtime, local: the exact local amount, no commission.
//   - bills, auto (the default): dollars only for a prepaid RANGE biller without
//     an invoice, where the payment need not be exact, and only when that is
//     cheaper than the exact order. Everything that must be exact stays in the
//     local currency: an invoice is paid to the unit, a fixed plan is a package
//     whose dollar price Reloadly does not tie to its rate, a postponed bill is
//     somebody's debt.
//   - bills, local: always the exact local amount.
//
// An operator or biller whose customers pay in dollars (it takes no local
// amounts) is ordered in dollars, as asked, in every mode.

// orderPlan is how one amount is ordered and what Reloadly then debits.
type orderPlan struct {
	// Amount, Currency and Local describe the order as Reloadly receives it.
	Amount   *big.Rat
	Currency string
	Local    bool
	// Cost is what Reloadly debits the company's account for it, in dollars.
	Cost *big.Rat
	// Buffer is the percentage a dollar order of a local amount was rounded up
	// by; nil when the order is the amount itself.
	Buffer *big.Rat
}

// mode names the currency of the order for the ledger: "usd" or "local".
func (p orderPlan) mode() string {
	if p.Local {
		return vouchers.OrderModeLocal
	}
	return vouchers.OrderModeUSD
}

// dollarPlaces is how many decimals a dollar order carries: Reloadly's own
// precision, beyond which a debit drifts from its formula.
const dollarPlaces = 5

// dollarsFor is the dollar order for a local amount: the amount at Reloadly's
// rate, plus the buffer, rounded UP to dollarPlaces so the recipient never gets
// less. rate is local units per dollar; buffer a percentage.
func dollarsFor(local, rate, bufferPercent *big.Rat) *big.Rat {
	factor := new(big.Rat).Add(big.NewRat(1, 1), new(big.Rat).Quo(bufferPercent, big.NewRat(100, 1)))
	dollars := new(big.Rat).Quo(local, rate)
	dollars.Mul(dollars, factor)
	return ceilDecimals(dollars, dollarPlaces)
}

// plan decides how an amount of the operator is ordered.
func (e *operatorEntry) plan(settings vouchers.Settings, amount *big.Rat) (orderPlan, bool) {
	if !e.local {
		cost, ok := reloadly.AirtimeCost(e.raw, amount, false)
		return orderPlan{Amount: amount, Currency: e.currency, Cost: cost}, ok
	}
	if settings.OrderMode(vouchers.ServiceKindAirtime) == vouchers.OrderModeUSD {
		if plan, ok := e.dollarPlan(settings, amount); ok {
			return plan, true
		}
	}
	cost, ok := reloadly.AirtimeCost(e.raw, amount, true)
	return orderPlan{Amount: amount, Currency: e.currency, Local: true, Cost: cost}, ok
}

// dollarPlan is the order in dollars for a local amount, when there is one.
func (e *operatorEntry) dollarPlan(settings vouchers.Settings, amount *big.Rat) (orderPlan, bool) {
	var dollars, buffer *big.Rat
	if e.fixed {
		for _, t := range e.tiles {
			if sameAmount(t.amount, amount) {
				dollars = t.usd
			}
		}
	} else if rate, percent := positiveRat(e.raw.FX.Rate), settings.USDBufferPercent(vouchers.ServiceKindAirtime); rate != nil && percent != nil {
		buffer = percent
		dollars = dollarsFor(amount, rate, percent)
	}
	if dollars == nil {
		return orderPlan{}, false
	}
	cost, ok := reloadly.AirtimeCost(e.raw, dollars, false)
	if !ok || cost.Sign() <= 0 {
		return orderPlan{}, false
	}
	return orderPlan{Amount: dollars, Currency: e.senderCurrency(), Cost: cost, Buffer: buffer}, true
}

// senderCurrency is the currency of the company's account: dollars.
func (e *operatorEntry) senderCurrency() string {
	if code := strings.ToUpper(strings.TrimSpace(e.raw.SenderCurrencyCode)); code != "" {
		return code
	}
	return "USD"
}

// plan decides how an amount of the biller is ordered.
func (b *billerEntry) plan(settings vouchers.Settings, amount *big.Rat) (orderPlan, bool) {
	if !b.local {
		cost, ok := reloadly.BillCost(b.raw, amount, false)
		return orderPlan{Amount: amount, Currency: b.currency, Cost: cost}, ok
	}
	exact, ok := reloadly.BillCost(b.raw, amount, true)
	local := orderPlan{Amount: amount, Currency: b.currency, Local: true, Cost: exact}
	if !ok {
		return local, false
	}
	if settings.OrderMode(vouchers.ServiceKindBill) == vouchers.OrderModeAuto && b.dollarOrderAllowed() {
		rate, percent := positiveRat(b.raw.FX.Rate), settings.USDBufferPercent(vouchers.ServiceKindBill)
		if rate != nil && percent != nil {
			dollars := dollarsFor(amount, rate, percent)
			if cost, ok := reloadly.BillCost(b.raw, dollars, false); ok && cost.Sign() > 0 && cost.Cmp(exact) < 0 {
				return orderPlan{Amount: dollars, Currency: b.dollarCurrency(), Cost: cost, Buffer: percent}, true
			}
		}
	}
	return local, true
}

// dollarOrderAllowed is the rule of bills in auto mode: a payment that need not
// be exact (prepaid credit on a range biller, no invoice) and that Reloadly takes
// in dollars.
func (b *billerEntry) dollarOrderAllowed() bool {
	return b.service == ServicePrepaid && !b.fixed && !b.requiresInvoice && b.raw.InternationalAmountSupported
}

func (b *billerEntry) dollarCurrency() string {
	if code := strings.ToUpper(strings.TrimSpace(b.raw.InternationalTransactionCurrencyCode)); code != "" {
		return code
	}
	return "USD"
}
