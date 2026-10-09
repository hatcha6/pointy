package services

import (
	"math"
	"math/big"
	"sort"
)

// A range operator or biller takes any amount between a minimum and a maximum.
// The till does not make a cashier type one: it offers a few round tiles, the
// amounts customers actually buy. Suggest picks them.
//
// A tile is a "round" number, one, two or five of a power of ten (1,000, 2,000,
// 5,000, 10,000 …), whose worth lies roughly between a dollar and a quarter and
// sixty dollars: smaller tiles are not worth the call, larger ones are rare.
// Whatever the currency, the same worth is wanted, which is why the worth in
// dollars is what decides, not the number of zeros.

// SuggestInput describes a range to pick tiles from.
type SuggestInput struct {
	// Min and Max are the limits of the range, in the currency of the amounts.
	Min, Max *big.Rat
	// PerUSD is how many units of that currency one US dollar buys. Nil means the
	// amounts are dollars.
	PerUSD *big.Rat
	// Popular is the amount customers buy most, when the operator says. It is
	// always one of the tiles when it lies inside the range.
	Popular *big.Rat
	// Limit is the most tiles to return; zero means the default of six.
	Limit int
}

const (
	defaultSuggestions = 6
	// suggestAtLeast is how many tiles are wanted when the range allows.
	suggestAtLeast = 3
	// suggestWidenSteps bounds how far the dollar window is opened to find
	// enough tiles; past it every round amount of the range is taken.
	suggestWidenSteps = 8
)

var (
	suggestLowUSD  = big.NewRat(5, 4)
	suggestHighUSD = big.NewRat(60, 1)
	suggestWiden   = big.NewRat(3, 2)
	// suggestMinFloorUSD is the least the minimum of a range may be worth for it
	// to be offered as a tile of its own when it is round: below the window, but
	// not so far below that it is a token amount.
	suggestMinFloorUSD = big.NewRat(2, 5)
	suggestMantissas   = []int64{1, 2, 5}
)

// Suggest returns the round tiles for a range, smallest first: at most Limit
// (six by default), at least three when the range holds that many round amounts,
// each inside [Min, Max]. The popular amount is always among them when it is
// valid, and so is the minimum when it is a round number of its own (the
// smallest thing a customer can buy is worth showing even where it is below the
// usual window). An unusable range gives none.
func Suggest(in SuggestInput) []*big.Rat {
	low, high := in.Min, in.Max
	if low == nil || high == nil || low.Sign() <= 0 || high.Cmp(low) < 0 {
		return nil
	}
	limit := in.Limit
	if limit <= 0 {
		limit = defaultSuggestions
	}
	perUSD := in.PerUSD
	if perUSD == nil || perUSD.Sign() <= 0 {
		perUSD = big.NewRat(1, 1)
	}

	candidates := roundCandidates(low, high)
	windowLow, windowHigh := new(big.Rat).Set(suggestLowUSD), new(big.Rat).Set(suggestHighUSD)
	chosen := inDollarWindow(candidates, perUSD, windowLow, windowHigh)
	for step := 0; len(chosen) < suggestAtLeast && step < suggestWidenSteps; step++ {
		windowLow.Quo(windowLow, suggestWiden)
		windowHigh.Mul(windowHigh, suggestWiden)
		chosen = inDollarWindow(candidates, perUSD, windowLow, windowHigh)
	}
	if len(chosen) < suggestAtLeast {
		chosen = candidates
	}
	chosen = spread(chosen, limit)

	protected := map[string]bool{}
	add := func(value *big.Rat) {
		for _, existing := range chosen {
			if existing.Cmp(value) == 0 {
				return
			}
		}
		chosen = append(chosen, value)
	}
	if low.Cmp(high) == 0 || (isRoundish(low) && worthAtLeast(low, perUSD, suggestMinFloorUSD)) {
		add(low)
		protected[low.RatString()] = true
	}
	if in.Popular != nil && in.Popular.Sign() > 0 && in.Popular.Cmp(low) >= 0 && in.Popular.Cmp(high) <= 0 {
		add(in.Popular)
		protected[in.Popular.RatString()] = true
	}
	if len(candidates) == 0 {
		// Nothing round fits: the ends of the range are all there is to offer.
		add(low)
		add(high)
	}
	for _, end := range []*big.Rat{high, low} {
		if len(chosen) >= suggestAtLeast {
			break
		}
		add(end)
	}
	sort.Slice(chosen, func(i, j int) bool { return chosen[i].Cmp(chosen[j]) < 0 })
	for len(chosen) > limit {
		drop := mostRedundant(chosen, protected)
		if drop < 0 {
			break
		}
		chosen = append(chosen[:drop], chosen[drop+1:]...)
	}
	out := make([]*big.Rat, len(chosen))
	for i, value := range chosen {
		out[i] = new(big.Rat).Set(value)
	}
	return out
}

// worthAtLeast reports whether an amount is worth at least floor dollars.
func worthAtLeast(value, perUSD, floor *big.Rat) bool {
	return new(big.Rat).Quo(value, perUSD).Cmp(floor) >= 0
}

// roundCandidates lists every 1, 2 or 5 times a power of ten inside [low, high],
// smallest first.
func roundCandidates(low, high *big.Rat) []*big.Rat {
	lowFloat, _ := low.Float64()
	highFloat, _ := high.Float64()
	if lowFloat <= 0 || highFloat <= 0 || math.IsInf(highFloat, 0) {
		return nil
	}
	first := int(math.Floor(math.Log10(lowFloat))) - 1
	last := int(math.Ceil(math.Log10(highFloat))) + 1
	var out []*big.Rat
	for exponent := first; exponent <= last; exponent++ {
		power := powerOfTen(exponent)
		for _, mantissa := range suggestMantissas {
			value := new(big.Rat).Mul(big.NewRat(mantissa, 1), power)
			if value.Cmp(low) >= 0 && value.Cmp(high) <= 0 {
				out = append(out, value)
			}
		}
	}
	return out
}

func powerOfTen(exponent int) *big.Rat {
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(absInt(exponent))), nil)
	if exponent >= 0 {
		return new(big.Rat).SetInt(scale)
	}
	return new(big.Rat).SetFrac(big.NewInt(1), scale)
}

func absInt(value int) int {
	if value < 0 {
		return -value
	}
	return value
}

func inDollarWindow(candidates []*big.Rat, perUSD, low, high *big.Rat) []*big.Rat {
	var out []*big.Rat
	for _, candidate := range candidates {
		dollars := new(big.Rat).Quo(candidate, perUSD)
		if dollars.Cmp(low) >= 0 && dollars.Cmp(high) <= 0 {
			out = append(out, candidate)
		}
	}
	return out
}

// spread keeps at most limit of the values, evenly across the list.
func spread(values []*big.Rat, limit int) []*big.Rat {
	if len(values) <= limit || limit < 1 {
		return append([]*big.Rat(nil), values...)
	}
	if limit == 1 {
		return []*big.Rat{values[len(values)/2]}
	}
	out := make([]*big.Rat, 0, limit)
	for i := 0; i < limit; i++ {
		index := (i*(len(values)-1) + (limit-1)/2) / (limit - 1)
		out = append(out, values[index])
	}
	return out
}

// isRoundish reports whether a number is one a person calls round: one of
// 1, 1.5, 2, 2.5, 3, 4, 5, 6, 7, 7.5, 8 or 9 times a power of ten (1,000, 250,
// 15, 0.5), not 88 or 1,967.
func isRoundish(value *big.Rat) bool {
	if value == nil || value.Sign() <= 0 {
		return false
	}
	scaled := new(big.Rat).Set(value)
	ten, hundred := big.NewRat(10, 1), big.NewRat(100, 1)
	for scaled.Cmp(hundred) >= 0 {
		scaled.Quo(scaled, ten)
	}
	for scaled.Cmp(ten) < 0 {
		scaled.Mul(scaled, ten)
	}
	if !scaled.IsInt() {
		return false
	}
	switch scaled.Num().Int64() {
	case 10, 15, 20, 25, 30, 40, 50, 60, 70, 75, 80, 90:
		return true
	}
	return false
}

// mostRedundant picks the unprotected tile whose removal loses the least: the
// one nearest to its neighbours on a logarithmic scale. -1 when nothing may go.
func mostRedundant(values []*big.Rat, protected map[string]bool) int {
	best, bestCost := -1, math.Inf(1)
	for i, value := range values {
		if protected[value.RatString()] {
			continue
		}
		// An end of the list goes only when nothing between can: the largest
		// first, because the small amounts are the ones customers buy.
		cost := 2e300
		if i > 0 && i < len(values)-1 {
			previous, _ := values[i-1].Float64()
			next, _ := values[i+1].Float64()
			cost = math.Log(next / previous)
		} else if i == len(values)-1 {
			cost = 1e300
		}
		if cost < bestCost {
			best, bestCost = i, cost
		}
	}
	return best
}
