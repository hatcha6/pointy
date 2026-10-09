package services

import (
	"errors"
	"fmt"
	"math/big"

	"pointy/relay/internal/vouchers"
)

// What a shop pays and what its customer is asked to pay are worked out from
// what Reloadly debits the company, in dollars, by the operator's pricing
// settings (vouchers.Settings, DIRECT_TOPUP_PLAN.md section 1). The arithmetic is
// the settings' own and is exact; this file only connects it to the services and
// refuses to price what has no dollar rate.

var (
	// ErrRateUnset is the dollar rate not being published: nothing from Reloadly
	// can be priced, so nothing is sold. It is never papered over with a guess.
	ErrRateUnset = errors.New("no dollar rate is published")
	// ErrUnpriceable is a cost that cannot be turned into a price (a settings
	// value that does not read, or a cost of nothing).
	ErrUnpriceable = errors.New("the cost cannot be priced")
)

// Prices are the two dinar prices of one thing and the cost they come from.
type Prices struct {
	// CostLYD is what the company really pays, in dinars.
	CostLYD *big.Rat
	// Unit is what the shop pays (the ledger's unit price); Retail is what the
	// shop's customer is asked to pay.
	Unit, Retail *big.Rat
}

// UnitString is the shop price on the wire: dinars with two decimals.
func (p Prices) UnitString() string { return vouchers.FormatDinars(p.Unit) }

// RetailString is the customer price on the wire.
func (p Prices) RetailString() string { return vouchers.FormatDinars(p.Retail) }

// PriceCost prices something that costs the company costUSD dollars. kind is
// KindAirtime or KindBill (they carry their own markups).
func PriceCost(settings vouchers.Settings, kind string, costUSD *big.Rat) (Prices, error) {
	if !settings.Priced() {
		if settings.RateProblem != "" {
			return Prices{}, fmt.Errorf("%w (%s)", ErrRateUnset, settings.RateProblem)
		}
		return Prices{}, ErrRateUnset
	}
	if costUSD == nil || costUSD.Sign() <= 0 {
		return Prices{}, ErrUnpriceable
	}
	cost, ok := settings.USDToLYD(costUSD)
	if !ok {
		return Prices{}, ErrUnpriceable
	}
	unit := settings.ShopPrice(kind, cost)
	retail := settings.RetailPrice(kind, cost)
	if unit == nil || retail == nil || unit.Sign() <= 0 || retail.Sign() <= 0 {
		return Prices{}, ErrUnpriceable
	}
	return Prices{CostLYD: cost, Unit: unit, Retail: retail}, nil
}
