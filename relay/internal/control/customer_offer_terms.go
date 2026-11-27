package control

import (
	"errors"
	"math/big"
	"sort"
	"strings"
	"unicode/utf8"
)

// What an offer gives, and on what (customer_offers.go). Four kinds:
//
//   - percent: a percentage off the order, capped by MaxDiscount.
//   - amount:  a fixed number of dinars off the order.
//   - tiered:  the more the order, the more off: Tiers, each from its own
//     minimum, in TierUnit (a percentage, capped, or dinars).
//   - bundle:  buy BuyQuantity, get GetQuantity more at GetPercent off
//     (100: free), in the same order of one card; capped by MaxDiscount.
//
// Scope narrows it to categories, brands or single items (empty: anything
// sold, eSIMs included under the category "esim"). An order the offer does
// not cover, or one below MinOrder, gets nothing off.

// More offer kinds.
const (
	CustomerOfferTiered = "tiered"
	CustomerOfferBundle = "bundle"
)

// CustomerOfferESIM is the category an eSIM order is scoped by.
const CustomerOfferESIM = "esim"

// Who an offer is for.
const (
	// CustomerOfferForSegments: the customers of Segments when it was made.
	CustomerOfferForSegments = "segments"
	// CustomerOfferForEveryone: every customer, those who join later too;
	// it is also shown to visitors who have not signed in.
	CustomerOfferForEveryone = "everyone"
)

const (
	maxCustomerOfferTiers = 5
	maxCustomerOfferScope = 300
	maxCustomerOfferBadge = 24
	maxBundleQuantity     = 10
)

// CustomerOfferTier is one step of a tiered offer: from MinOrder, Value off.
type CustomerOfferTier struct {
	MinOrder string `json:"min_order"`
	Value    string `json:"value"`
}

// CustomerOfferScope is what an offer applies to. Empty lists: anything.
type CustomerOfferScope struct {
	Categories []string `json:"categories,omitempty"`
	Brands     []string `json:"brands,omitempty"`
	Items      []string `json:"items,omitempty"`
}

// Empty reports whether the scope is everything.
func (s CustomerOfferScope) Empty() bool {
	return len(s.Categories) == 0 && len(s.Brands) == 0 && len(s.Items) == 0
}

// Covers reports whether a card of category, brand and item is in scope: it
// is when any of the lists names it.
func (s CustomerOfferScope) Covers(category, brand, item string) bool {
	if s.Empty() {
		return true
	}
	return contains(s.Categories, category) || contains(s.Brands, brand) || contains(s.Items, item)
}

func contains(list []string, value string) bool {
	if value == "" {
		return false
	}
	for _, entry := range list {
		if entry == value {
			return true
		}
	}
	return false
}

// CustomerOfferLine is one order as an offer prices it.
type CustomerOfferLine struct {
	UnitPrice *big.Rat
	Quantity  int
	Category  string
	Brand     string
	Item      string
}

// Subtotal is the line before any offer.
func (l CustomerOfferLine) Subtotal() *big.Rat {
	if l.UnitPrice == nil || l.Quantity <= 0 {
		return new(big.Rat)
	}
	return new(big.Rat).Mul(l.UnitPrice, big.NewRat(int64(l.Quantity), 1))
}

// CustomerOfferDiscount is what offer takes off line: nothing out of scope
// or below its minimum, never more than the line, down to the dirham.
func CustomerOfferDiscount(offer CustomerOffer, line CustomerOfferLine) *big.Rat {
	subtotal := line.Subtotal()
	discount := new(big.Rat)
	if subtotal.Sign() <= 0 || !offer.Scope.Covers(line.Category, line.Brand, line.Item) {
		return discount
	}
	if minimum, err := ParseWalletAmount(offer.MinOrder); err == nil && subtotal.Cmp(minimum) < 0 {
		return discount
	}
	switch offer.Kind {
	case CustomerOfferPercent:
		discount = percentOf(subtotal, offer.Value)
	case CustomerOfferAmount:
		discount = amountOrZero(offer.Value)
	case CustomerOfferTiered:
		tier, ok := offer.TierFor(subtotal)
		if !ok {
			return discount
		}
		if offer.TierUnit == CustomerOfferAmount {
			discount = amountOrZero(tier.Value)
		} else {
			discount = percentOf(subtotal, tier.Value)
		}
	case CustomerOfferBundle:
		group := offer.BuyQuantity + offer.GetQuantity
		if offer.BuyQuantity <= 0 || offer.GetQuantity <= 0 || line.UnitPrice == nil {
			return discount
		}
		discounted := line.Quantity / group * offer.GetQuantity
		off := new(big.Rat).Mul(line.UnitPrice, big.NewRat(int64(discounted), 1))
		discount = percentOf(off, orDefault(offer.GetPercent, "100"))
	}
	if offer.Kind != CustomerOfferAmount && !(offer.Kind == CustomerOfferTiered && offer.TierUnit == CustomerOfferAmount) {
		if cap, err := ParseWalletAmount(offer.MaxDiscount); err == nil && cap.Sign() > 0 && discount.Cmp(cap) > 0 {
			discount.Set(cap)
		}
	}
	if discount.Cmp(subtotal) > 0 {
		discount.Set(subtotal)
	}
	return roundDownToDirham(discount)
}

// TierFor is the highest tier subtotal reaches.
func (o CustomerOffer) TierFor(subtotal *big.Rat) (CustomerOfferTier, bool) {
	var best CustomerOfferTier
	found := false
	for _, tier := range o.Tiers {
		minimum, err := ParseWalletAmount(tier.MinOrder)
		if err == nil && subtotal.Cmp(minimum) >= 0 {
			best, found = tier, true
		}
	}
	return best, found
}

func percentOf(value *big.Rat, percent string) *big.Rat {
	share, err := ParseWalletAmount(percent)
	if err != nil || share.Sign() <= 0 {
		return new(big.Rat)
	}
	out := new(big.Rat).Mul(value, share)
	return out.Quo(out, big.NewRat(100, 1))
}

func amountOrZero(raw string) *big.Rat {
	value, err := ParseWalletAmount(raw)
	if err != nil || value.Sign() < 0 {
		return new(big.Rat)
	}
	return value
}

// normalizeCustomerOfferTerms checks what an offer gives and on what, and
// writes it the one way the stores keep it.
func normalizeCustomerOfferTerms(offer CustomerOffer) (CustomerOffer, error) {
	invalid := func(why string) (CustomerOffer, error) {
		return CustomerOffer{}, errors.Join(ErrCustomerOfferInvalid, errors.New(why))
	}
	positive := func(raw string, most *big.Rat) (string, bool) {
		value, err := ParseWalletAmount(raw)
		if err != nil || value.Sign() <= 0 || value.Cmp(most) > 0 {
			return "", false
		}
		return FormatWalletAmount(value), true
	}
	limitFor := func(unit string) *big.Rat {
		if unit == CustomerOfferAmount {
			return maxCustomerOfferAmount
		}
		return maxCustomerOfferPercent
	}
	given := offer.Tiers
	offer.Tiers, offer.TierUnit = nil, strings.TrimSpace(offer.TierUnit)
	if offer.Kind != CustomerOfferBundle {
		offer.BuyQuantity, offer.GetQuantity, offer.GetPercent = 0, 0, ""
	}
	switch offer.Kind {
	case CustomerOfferPercent, CustomerOfferAmount:
		value, ok := positive(offer.Value, limitFor(offer.Kind))
		if !ok {
			return invalid("value must be above 0, at most 90 percent or 500 dinars")
		}
		offer.Value, offer.TierUnit = value, ""
	case CustomerOfferTiered:
		if offer.TierUnit != CustomerOfferAmount {
			offer.TierUnit = CustomerOfferPercent
		}
		tiers := append([]CustomerOfferTier(nil), given...)
		if len(tiers) == 0 || len(tiers) > maxCustomerOfferTiers {
			return invalid("a tiered offer has 1 to 5 tiers")
		}
		sort.SliceStable(tiers, func(i, j int) bool {
			a, _ := ParseWalletAmount(tiers[i].MinOrder)
			b, _ := ParseWalletAmount(tiers[j].MinOrder)
			return a != nil && b != nil && a.Cmp(b) < 0
		})
		var lastMin, lastValue *big.Rat
		for i, tier := range tiers {
			minimum, err := ParseWalletAmount(tier.MinOrder)
			if err != nil || minimum.Sign() < 0 {
				return invalid("each tier needs a minimum order")
			}
			value, ok := positive(tier.Value, limitFor(offer.TierUnit))
			if !ok {
				return invalid("each tier needs a value above 0, at most 90 percent or 500 dinars")
			}
			parsed, _ := ParseWalletAmount(value)
			if lastMin != nil && (minimum.Cmp(lastMin) <= 0 || parsed.Cmp(lastValue) <= 0) {
				return invalid("each tier must start higher and give more than the one before")
			}
			lastMin, lastValue = minimum, parsed
			tiers[i] = CustomerOfferTier{MinOrder: FormatWalletAmount(minimum), Value: value}
		}
		offer.Tiers = tiers
		// The most it gives, for a listing; the tiers are the word.
		offer.Value = tiers[len(tiers)-1].Value
		if offer.MinOrder == "" || amountOrZero(offer.MinOrder).Sign() == 0 {
			offer.MinOrder = tiers[0].MinOrder
		}
	case CustomerOfferBundle:
		if offer.BuyQuantity < 1 || offer.BuyQuantity > maxBundleQuantity || offer.GetQuantity < 1 || offer.GetQuantity > maxBundleQuantity {
			return invalid("buy and get are 1 to 10 cards each")
		}
		percent, ok := positive(orDefault(strings.TrimSpace(offer.GetPercent), "100"), big.NewRat(100, 1))
		if !ok {
			return invalid("get_percent is above 0 and at most 100")
		}
		offer.GetPercent, offer.Value, offer.TierUnit = percent, percent, ""
	default:
		return invalid("kind is percent, amount, tiered or bundle")
	}
	scope, err := normalizeOfferScope(offer.Scope)
	if err != nil {
		return CustomerOffer{}, err
	}
	offer.Scope = scope
	offer.Badge = strings.TrimSpace(offer.Badge)
	if utf8.RuneCountInString(offer.Badge) > maxCustomerOfferBadge {
		return invalid("a badge is at most 24 letters")
	}
	return offer, nil
}

func normalizeOfferScope(scope CustomerOfferScope) (CustomerOfferScope, error) {
	clean := func(list []string) []string {
		seen := map[string]bool{}
		out := []string{}
		for _, entry := range list {
			entry = strings.TrimSpace(entry)
			if entry != "" && !seen[entry] {
				seen[entry] = true
				out = append(out, entry)
			}
		}
		sort.Strings(out)
		if len(out) == 0 {
			return nil
		}
		return out
	}
	out := CustomerOfferScope{Categories: clean(scope.Categories), Brands: clean(scope.Brands), Items: clean(scope.Items)}
	if len(out.Categories)+len(out.Brands)+len(out.Items) > maxCustomerOfferScope {
		return CustomerOfferScope{}, errors.Join(ErrCustomerOfferInvalid, errors.New("an offer names at most 300 categories, brands and items"))
	}
	return out, nil
}
