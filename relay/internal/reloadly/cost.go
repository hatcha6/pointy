package reloadly

import (
	"math/big"
	"strings"
)

// This file prices a purchase without calling Reloadly: what the company's USD
// account will be debited for a gift card, a top-up or a bill. The formulas were
// checked against the sandbox with real orders (see the package comment for the
// numbers); every function rounds like Reloadly does, once, to CostPlaces
// decimals, half up, and reports ok=false instead of guessing when the amount is
// not one the product sells or the catalog row is unusable.
//
// All arithmetic is exact (math/big); nothing here touches a float.

// CostPlaces is the number of decimals Reloadly rounds a debit to.
const CostPlaces = 5

var (
	ratOne     = big.NewRat(1, 1)
	ratHundred = big.NewRat(100, 1)
	// halfCent is the rounding error of a sender amount Reloadly publishes in
	// cents.
	halfCent = big.NewRat(5, 1000)
)

// RoundCost rounds an amount to CostPlaces decimals, half away from zero, the way
// Reloadly rounds what it debits.
func RoundCost(r *big.Rat) *big.Rat { return roundRat(r, CostPlaces) }

// roundRat rounds r to places decimals, half away from zero.
func roundRat(r *big.Rat, places int) *big.Rat {
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(places)), nil)
	scaled := new(big.Rat).Mul(r, new(big.Rat).SetInt(scale))
	quotient, remainder := new(big.Int).QuoRem(scaled.Num(), scaled.Denom(), new(big.Int))
	twice := new(big.Int).Abs(remainder)
	twice.Lsh(twice, 1)
	if twice.Cmp(scaled.Denom()) >= 0 {
		if scaled.Sign() < 0 {
			quotient.Sub(quotient, big.NewInt(1))
		} else {
			quotient.Add(quotient, big.NewInt(1))
		}
	}
	return new(big.Rat).SetFrac(quotient, scale)
}

// optRat reads an optional number: absent is zero, unreadable text fails.
func optRat(n Num) (*big.Rat, bool) {
	if n.Empty() {
		return new(big.Rat), true
	}
	return n.Rat()
}

// rat reads a number that may be absent: nil when it is.
func rat(n Num) *big.Rat {
	value, ok := n.Rat()
	if !ok {
		return nil
	}
	return value
}

// decimalPlaces is how many decimals the exact value needs (at most 20).
func decimalPlaces(r *big.Rat) int {
	ten := big.NewRat(10, 1)
	scaled := new(big.Rat).Set(r)
	for places := 0; places < 20; places++ {
		if scaled.IsInt() {
			return places
		}
		scaled.Mul(scaled, ten)
	}
	return 20
}

// pow10neg is 10^-places.
func pow10neg(places int) *big.Rat {
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(places)), nil)
	return new(big.Rat).SetFrac(big.NewInt(1), scale)
}

// factor is 1 - discount/100 + fee/100, the multiplier of an amount; it must stay
// positive.
func factor(discount, feePercent *big.Rat) (*big.Rat, bool) {
	f := new(big.Rat).Sub(ratOne, new(big.Rat).Quo(discount, ratHundred))
	f.Add(f, new(big.Rat).Quo(feePercent, ratHundred))
	return f, f.Sign() > 0
}

func minMax(list []Num) (lo, hi *big.Rat) {
	for _, n := range list {
		value, ok := n.Rat()
		if !ok {
			continue
		}
		if lo == nil || value.Cmp(lo) < 0 {
			lo = value
		}
		if hi == nil || value.Cmp(hi) > 0 {
			hi = value
		}
	}
	return lo, hi
}

func listHas(list []Num, amount *big.Rat) bool {
	for _, n := range list {
		if value, ok := n.Rat(); ok && value.Cmp(amount) == 0 {
			return true
		}
	}
	return false
}

// withinBounds is whether amount lies in [lo, hi]; a nil bound is open.
func withinBounds(amount, lo, hi *big.Rat) bool {
	return (lo == nil || amount.Cmp(lo) >= 0) && (hi == nil || amount.Cmp(hi) <= 0)
}

// ---------------------------------------------------------------------------
// Gift cards

// GiftLimits are the smallest and largest face value (in the product's recipient
// currency) the product sells; nil when the row does not say.
func GiftLimits(p GiftProduct) (lo, hi *big.Rat) {
	if p.DenominationType == Fixed {
		return minMax(p.FixedRecipientDenominations)
	}
	return rat(p.MinRecipientDenomination), rat(p.MaxRecipientDenomination)
}

// GiftAmountAllowed is whether amount (a face value in the recipient currency) is
// one the product sells: a listed denomination of a FIXED product, or an amount
// within the bounds of a RANGE one.
func GiftAmountAllowed(p GiftProduct, amount *big.Rat) bool {
	if amount == nil || amount.Sign() <= 0 {
		return false
	}
	switch p.DenominationType {
	case Fixed:
		return listHas(p.FixedRecipientDenominations, amount)
	case Range:
		lo, hi := GiftLimits(p)
		return lo != nil && hi != nil && withinBounds(amount, lo, hi)
	}
	return false
}

// GiftRateBounds is the interval the real recipient-to-account exchange rate
// lies in.
//
// Reloadly publishes the rate rounded to six decimals ("1.176776" for EUR, but
// "0.000038" for VND, where that is two significant digits) while charging with
// the unrounded one, so the published rate alone can be off by up to 1.3%
// (VND), 0.9% (IDR), 0.16% (COP), and less than 0.0005% for every currency of
// more than 5 cents. The denominations the row also publishes narrow it: a
// sender amount is the recipient amount times the real rate, rounded to cents.
// The interval is the intersection of all of them; if they contradict each
// other the published rate and its rounding are used alone. A product whose
// recipient currency is the account currency has the exact rate 1.
func GiftRateBounds(p GiftProduct) (lo, hi *big.Rat, ok bool) {
	if p.RecipientCurrencyCode != "" && strings.EqualFold(p.RecipientCurrencyCode, p.SenderCurrencyCode) {
		return new(big.Rat).Set(ratOne), new(big.Rat).Set(ratOne), true
	}
	shown, ok := p.RecipientToSenderRate.Rat()
	if !ok || shown.Sign() <= 0 {
		return nil, nil, false
	}
	half := new(big.Rat).Mul(pow10neg(max(6, decimalPlaces(shown))), big.NewRat(1, 2))
	lo = new(big.Rat).Sub(shown, half)
	hi = new(big.Rat).Add(shown, half)
	narrowLo, narrowHi := new(big.Rat).Set(lo), new(big.Rat).Set(hi)
	narrow := func(recipient, sender *big.Rat) {
		if recipient == nil || sender == nil || recipient.Sign() <= 0 || sender.Sign() <= 0 {
			return
		}
		step := new(big.Rat).Mul(pow10neg(max(2, decimalPlaces(sender))), big.NewRat(1, 2))
		below := new(big.Rat).Quo(new(big.Rat).Sub(sender, step), recipient)
		above := new(big.Rat).Quo(new(big.Rat).Add(sender, step), recipient)
		if below.Cmp(narrowLo) > 0 {
			narrowLo = below
		}
		if above.Cmp(narrowHi) < 0 {
			narrowHi = above
		}
	}
	if p.DenominationType == Range {
		narrow(rat(p.MinRecipientDenomination), rat(p.MinSenderDenomination))
		narrow(rat(p.MaxRecipientDenomination), rat(p.MaxSenderDenomination))
	} else {
		for key, sender := range p.FixedRecipientToSender {
			recipient, parsed := new(big.Rat).SetString(strings.TrimSpace(key))
			if parsed {
				narrow(recipient, rat(sender))
			}
		}
		if len(p.FixedRecipientDenominations) == len(p.FixedSenderDenominations) {
			for i := range p.FixedRecipientDenominations {
				narrow(rat(p.FixedRecipientDenominations[i]), rat(p.FixedSenderDenominations[i]))
			}
		}
	}
	if narrowLo.Cmp(narrowHi) <= 0 {
		lo, hi = narrowLo, narrowHi
	}
	return lo, hi, true
}

// GiftCostBounds is the range, to CostPlaces decimals, the cost of quantity cards
// of the given face value lies in: the uncertainty of the exchange rate (see
// GiftRateBounds) carried through. For a product priced in the account currency
// the two ends are equal. Use hi to guard a margin.
func GiftCostBounds(p GiftProduct, amount *big.Rat, quantity int) (lo, hi *big.Rat, ok bool) {
	rateLo, rateHi, ok := GiftRateBounds(p)
	if !ok || quantity < 1 || !GiftAmountAllowed(p, amount) {
		return nil, nil, false
	}
	discount, ok1 := optRat(p.DiscountPercentage)
	feePercent, ok2 := optRat(p.SenderFeePercentage)
	flat, ok3 := optRat(p.SenderFee)
	if !ok1 || !ok2 || !ok3 {
		return nil, nil, false
	}
	multiplier, ok := factor(discount, feePercent)
	if !ok {
		return nil, nil, false
	}
	count := new(big.Rat).SetInt64(int64(quantity))
	price := func(rate *big.Rat) *big.Rat {
		unit := new(big.Rat).Mul(amount, rate)
		unit.Mul(unit, multiplier)
		unit.Add(unit, flat)
		return RoundCost(unit.Mul(unit, count))
	}
	return price(rateLo), price(rateHi), true
}

// GiftOrderCost is what an order of quantity cards of one face value (in the
// product's recipient currency) debits from the USD account, at the middle of
// GiftCostBounds:
//
//	unit  = faceValue x rate x (1 - discount/100 + feePercentage/100) + flatFee
//	total = round5(quantity x unit)
//
// The fee, the percentage fee and the discount are per card and all apply to the
// card's price in the account currency; the flat fee is in that currency too.
// Verified in the sandbox: Xbox Live US $5 (5% off, $1 fee) costs 5.75000, two of
// them 11.50000; Razer Gold $5 (1% off, 1% fee, $1 fee) 6.00000; App Store France
// 5 EUR (rate 1.176776, $1 fee) 6.88388. The total shown is rounded once: two
// cards at 1.20013 cost 4.35225, not twice the rounded 2.17613 (the gift card
// ledger itself keeps six decimals, see the package comment).
func GiftOrderCost(p GiftProduct, amount *big.Rat, quantity int) (*big.Rat, bool) {
	lo, hi, ok := GiftCostBounds(p, amount, quantity)
	if !ok {
		return nil, false
	}
	middle := new(big.Rat).Add(lo, hi)
	return RoundCost(middle.Quo(middle, big.NewRat(2, 1))), true
}

// GiftCost is GiftOrderCost for one card.
func GiftCost(p GiftProduct, amount *big.Rat) (*big.Rat, bool) {
	return GiftOrderCost(p, amount, 1)
}

// ---------------------------------------------------------------------------
// Airtime

// AirtimeLimits are the smallest and largest amount an operator takes, in the
// sender currency (USD) or, with local, in the destination currency: the plan
// list's extremes for a FIXED operator, the bounds for a RANGE one. nil when the
// row does not say.
//
// The catalog rounds a RANGE operator's USD bounds to cents, but Reloadly applies
// the local bounds converted at the rate (Airtel Niger lists a 0.20 USD minimum
// and accepted 0.19786 USD, which is its 100 XOF minimum); the USD limits
// returned are the wider of the two.
func AirtimeLimits(op Operator, local bool) (lo, hi *big.Rat) {
	if op.DenominationType == Fixed {
		if local {
			return minMax(op.LocalFixedAmounts)
		}
		return minMax(op.FixedAmounts)
	}
	if local {
		return rat(op.LocalMinAmount), rat(op.LocalMaxAmount)
	}
	lo, hi = rat(op.MinAmount), rat(op.MaxAmount)
	rate, ok := op.FX.Rate.Rat()
	if !ok || rate.Sign() <= 0 || !op.SupportsLocalAmounts {
		return lo, hi
	}
	if localLo := rat(op.LocalMinAmount); localLo != nil {
		if converted := new(big.Rat).Quo(localLo, rate); lo == nil || converted.Cmp(lo) < 0 {
			lo = converted
		}
	}
	if localHi := rat(op.LocalMaxAmount); localHi != nil {
		if converted := new(big.Rat).Quo(localHi, rate); hi == nil || converted.Cmp(hi) > 0 {
			hi = converted
		}
	}
	return lo, hi
}

// AirtimeAmountAllowed is whether the operator takes amount: a listed plan of a
// FIXED operator, an amount within the bounds of a RANGE one, and for local
// amounts only when the operator supports them.
//
// A FIXED operator's USD plans are enforced here although the sandbox accepted
// an unlisted amount (0.18 for the 0.17 plan); do not rely on that.
func AirtimeAmountAllowed(op Operator, amount *big.Rat, local bool) bool {
	if amount == nil || amount.Sign() <= 0 || (local && !op.SupportsLocalAmounts) {
		return false
	}
	switch op.DenominationType {
	case Fixed:
		if local {
			return listHas(op.LocalFixedAmounts, amount)
		}
		return listHas(op.FixedAmounts, amount)
	case Range:
		lo, hi := AirtimeLimits(op, local)
		return withinBounds(amount, lo, hi)
	}
	return false
}

// AirtimeCost is what a top-up of amount debits from the USD account.
//
// In USD (local false) the amount is the sender amount S. In the destination
// currency (local true) S = amount / FX.Rate, with the rate exactly as the
// catalog writes it (float32 artifacts like 505.427002 included). Then
//
//	cost = round5( S x (1 - discount/100 + feePercentage/100) + flatFee )
//
// with, for USD orders, the international discount (Commission) and fees, and
// for local orders the LOCAL discount (usually 0: ordering in the local currency
// forfeits the commission) and local fees, where the local flat fee is in the
// destination currency and is divided by the rate. When the percentage fee is
// non-zero the discount is not given — the only operator with both (CellCard
// Cambodia: 4% discount, 10% fee) charged S x 1.10.
//
// Verified in the sandbox, USD: Orange Mali 4 -> 3.80000 (5%); Peru Claro 1 ->
// 0.96000 (4%); T-Mobile USA PIN 10 -> 9.90000 (3% and a 0.20 flat fee).
// Local: Orange Mali 2000 XOF at 505 -> 3.96040 (no discount); Claro Peru 3.25
// PEN at 3.2468801 -> 0.99095 (local 1%); Mobitel LK 135 LKR at 270 -> 0.55000
// (10% local fee); Hutchison LK 100 LKR at 158.3999939 -> 0.69444 (10 LKR flat
// fee); a FIXED plan in local currency, Etisalat Egypt 5 EGP -> 0.16668, is
// 5/29.9969997 and NOT its aligned USD plan 0.17.
func AirtimeCost(op Operator, amount *big.Rat, local bool) (*big.Rat, bool) {
	if !AirtimeAmountAllowed(op, amount, local) {
		return nil, false
	}
	sender := amount
	var discountNum, feePercentNum, flatNum Num
	if local {
		discountNum, feePercentNum, flatNum = op.LocalDiscount, op.Fees.LocalPercentage, op.Fees.Local
	} else {
		discountNum, feePercentNum, flatNum = op.InternationalDiscount, op.Fees.InternationalPercentage, op.Fees.International
		if discountNum.Empty() {
			discountNum = op.Commission
		}
	}
	discount, ok1 := optRat(discountNum)
	feePercent, ok2 := optRat(feePercentNum)
	flat, ok3 := optRat(flatNum)
	if !ok1 || !ok2 || !ok3 {
		return nil, false
	}
	if local {
		rate, ok := op.FX.Rate.Rat()
		if !ok || rate.Sign() <= 0 {
			return nil, false
		}
		sender = new(big.Rat).Quo(amount, rate)
		flat = new(big.Rat).Quo(flat, rate)
	}
	if feePercent.Sign() > 0 {
		discount = new(big.Rat)
	}
	multiplier, ok := factor(discount, feePercent)
	if !ok {
		return nil, false
	}
	cost := new(big.Rat).Mul(sender, multiplier)
	cost.Add(cost, flat)
	return RoundCost(cost), true
}

// ---------------------------------------------------------------------------
// Utility bills

// BillLimits are the smallest and largest amount a biller takes, in the local
// currency (local) or the account currency: the plan list's extremes for a FIXED
// biller, the bounds for a RANGE one. nil when the row does not say.
func BillLimits(b Biller, local bool) (lo, hi *big.Rat) {
	if b.DenominationType == Fixed {
		return minMax(billAmounts(b, local))
	}
	if local {
		return rat(b.MinLocalTransactionAmount), rat(b.MaxLocalTransactionAmount)
	}
	return rat(b.MinInternationalTransactionAmount), rat(b.MaxInternationalTransactionAmount)
}

func billAmounts(b Biller, local bool) []Num {
	plans := b.InternationalFixedAmounts
	if local {
		plans = b.LocalFixedAmounts
	}
	out := make([]Num, 0, len(plans))
	for _, plan := range plans {
		out = append(out, plan.Amount)
	}
	return out
}

// BillAmountAllowed is whether the biller takes amount: a listed plan of a FIXED
// biller, an amount within the bounds of a RANGE one, in a currency the biller
// supports.
func BillAmountAllowed(b Biller, amount *big.Rat, local bool) bool {
	if amount == nil || amount.Sign() <= 0 {
		return false
	}
	if (local && !b.LocalAmountSupported) || (!local && !b.InternationalAmountSupported) {
		return false
	}
	switch b.DenominationType {
	case Fixed:
		return listHas(billAmounts(b, local), amount)
	case Range:
		lo, hi := BillLimits(b, local)
		return withinBounds(amount, lo, hi)
	}
	return false
}

// BillCost is what a utility payment of amount debits from the USD account.
//
// In USD (local false) the amount is the account amount S, with the
// international discount, percentage fee and flat fee. In the local currency
// (local true) S = amount / FX.Rate, with the LOCAL discount (0 so far), local
// percentage fee, and the local flat fee, which is in the local currency and is
// divided by the rate. Then
//
//	cost = round5( S x (1 - discount/100 + feePercentage/100) + flatFee )
//
// Verified in the sandbox: Woyofal SN 1000 XOF at 470 with a 117.5 XOF fee ->
// 2.37766 (the 8% international discount is not given on a local order); the
// same biller in USD, 2.13 -> 1.95960 (8%, no fee); StarTimes ML plan 400 XOF ->
// 1.10106. A percentage fee on a bill (South Africa's 8%) is assumed additive
// like a gift card's; the sandbox has no such biller.
//
// FIXED billers: the local plans are priced by the rate (Canal+ 10000 XOF at
// 545.05 is 18.35 USD) while the international plan list carries its own, much
// lower, USD prices (16.38 for the same plan) that the sandbox accepts without
// checking; ask Reloadly which one the live API wants before paying a FIXED
// biller in USD.
func BillCost(b Biller, amount *big.Rat, local bool) (*big.Rat, bool) {
	if !BillAmountAllowed(b, amount, local) {
		return nil, false
	}
	var discountNum, feePercentNum, flatNum Num
	var flatCurrency string
	sender := amount
	if local {
		discountNum, feePercentNum, flatNum = b.LocalDiscountPercentage, b.LocalTransactionFeePercentage, b.LocalTransactionFee
		flatCurrency = b.LocalTransactionFeeCurrencyCode
	} else {
		discountNum, feePercentNum, flatNum = b.InternationalDiscountPercentage, b.InternationalTransactionFeePercentage, b.InternationalTransactionFee
		flatCurrency = b.InternationalTransactionFeeCurrencyCode
	}
	discount, ok1 := optRat(discountNum)
	feePercent, ok2 := optRat(feePercentNum)
	flat, ok3 := optRat(flatNum)
	if !ok1 || !ok2 || !ok3 {
		return nil, false
	}
	rate, rateOK := b.FX.Rate.Rat()
	rateOK = rateOK && rate.Sign() > 0
	if local {
		if !rateOK {
			return nil, false
		}
		sender = new(big.Rat).Quo(amount, rate)
	}
	// A flat fee is in the currency its code names: the local one is divided by
	// the rate to reach the account currency.
	if flat.Sign() != 0 && isLocalCurrency(b, flatCurrency, local) {
		if !rateOK {
			return nil, false
		}
		flat = new(big.Rat).Quo(flat, rate)
	}
	multiplier, ok := factor(discount, feePercent)
	if !ok {
		return nil, false
	}
	cost := new(big.Rat).Mul(sender, multiplier)
	cost.Add(cost, flat)
	return RoundCost(cost), true
}

// isLocalCurrency is whether a fee currency code names the biller's local
// currency rather than the account's. An absent code follows the order's side.
func isLocalCurrency(b Biller, code string, local bool) bool {
	code = strings.TrimSpace(code)
	switch {
	case code == "":
		return local
	case strings.EqualFold(code, b.InternationalTransactionCurrencyCode):
		return false
	case b.LocalTransactionCurrencyCode != "":
		return strings.EqualFold(code, b.LocalTransactionCurrencyCode)
	}
	return local
}
