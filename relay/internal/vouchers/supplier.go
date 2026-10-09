package vouchers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Supplier keys the catalog accepts. A supplier the relay cannot buy from yet
// (DingConnect) gets its key here together with its adapter.
const (
	SupplierBNPlus = "bnplus"
	// SupplierReloadly is Reloadly's gift card service, paid in dollars from the
	// company's account there. Its price is never known without the dollar rate.
	SupplierReloadly = "reloadly"
	// SupplierTest is the built-in supplier of test mode: fake codes, no money.
	SupplierTest = "test"
)

// maxSuppliersPerItem bounds an item's supplier list: one entry per supplier
// the relay can buy from, with room for the next.
const maxSuppliersPerItem = 4

// Ref is one supplier of an item once read: which supplier, which of its
// cards, and the most the company will pay it for one.
type Ref struct {
	Supplier string `json:"supplier"`
	// ID is the supplier's card: BN Plus's card id, or Reloadly's
	// "<product_id>/<amount>" (the product and the face value ordered from it).
	ID string `json:"id"`
	// MaxCost guards the margin, in dinars whoever the supplier is: when the
	// supplier's price for the card, converted to dinars, is above it, that
	// supplier is not bought from. Empty: no guard.
	MaxCost string `json:"max_cost,omitempty"`
	// Name is the supplier's own name for the card, filled from its offers at
	// run time. BN Plus's order history names cards rather than numbering
	// them, so this is how a lost purchase is found again.
	Name string `json:"-"`
}

type refParser func(raw json.RawMessage) (Ref, error)

var refParsers = map[string]refParser{
	SupplierBNPlus:   parseBNPlusRef,
	SupplierReloadly: parseReloadlyRef,
	SupplierTest:     parseTestRef,
}

// SupplierKeys lists the suppliers a catalog may name.
func SupplierKeys() []string {
	keys := make([]string, 0, len(refParsers))
	for key := range refParsers {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// ParseRef reads an item's supplier block.
func ParseRef(raw json.RawMessage) (Ref, error) {
	if absentJSON(raw) {
		return Ref{}, errors.New(`is required, e.g. {"key": "bnplus", "card_id": 12}`)
	}
	var head struct {
		Key string `json:"key"`
	}
	if err := json.Unmarshal(raw, &head); err != nil {
		return Ref{}, errors.New("must be an object with a key")
	}
	key := strings.ToLower(strings.TrimSpace(head.Key))
	parse, ok := refParsers[key]
	if !ok {
		return Ref{}, fmt.Errorf("supplier %q is not one this relay buys from (%s)", head.Key, strings.Join(SupplierKeys(), ", "))
	}
	return parse(raw)
}

// absentJSON reports whether a raw JSON value was left out (or written null).
func absentJSON(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	return len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null"))
}

// refProblem is one thing wrong with an item's supplier blocks; Field says
// where, relative to the item ("supplier", "suppliers", "suppliers[1]").
type refProblem struct {
	Field   string
	Message string
}

// itemRefs reads an item's suppliers: the single "supplier" block or the
// "suppliers" list, exactly one of them, in listing order. Every problem is
// returned, so a validation reports them all at once.
func itemRefs(item Item) ([]Ref, []refProblem) {
	single := !absentJSON(item.Supplier)
	list := item.Suppliers != nil
	switch {
	case single && list:
		return nil, []refProblem{{"suppliers", `use either "supplier" or "suppliers", not both`}}
	case !single && !list:
		return nil, []refProblem{{"supplier", `is required, e.g. {"key": "bnplus", "card_id": 12}, or a "suppliers" list`}}
	case single:
		ref, err := ParseRef(item.Supplier)
		if err != nil {
			return nil, []refProblem{{"supplier", err.Error()}}
		}
		return []Ref{ref}, nil
	}
	if len(item.Suppliers) == 0 || len(item.Suppliers) > maxSuppliersPerItem {
		return nil, []refProblem{{"suppliers", fmt.Sprintf("must list 1 to %d suppliers", maxSuppliersPerItem)}}
	}
	var problems []refProblem
	refs := make([]Ref, 0, len(item.Suppliers))
	listed := map[string]int{}
	for i, raw := range item.Suppliers {
		field := fmt.Sprintf("suppliers[%d]", i)
		ref, err := ParseRef(raw)
		if err != nil {
			problems = append(problems, refProblem{field, err.Error()})
			continue
		}
		if first, dup := listed[ref.Supplier]; dup {
			problems = append(problems, refProblem{field,
				fmt.Sprintf("%s is already listed at suppliers[%d]: one entry per supplier", ref.Supplier, first)})
			continue
		}
		listed[ref.Supplier] = i
		refs = append(refs, ref)
	}
	if len(problems) > 0 {
		return nil, problems
	}
	return refs, nil
}

// ParseRefs reads an item's suppliers in listing order: the "supplier" block
// as a list of one, or the "suppliers" list (1 to 4 entries, one per supplier).
// Exactly one of the two may be present.
func ParseRefs(item Item) ([]Ref, error) {
	refs, problems := itemRefs(item)
	if len(problems) > 0 {
		return nil, fmt.Errorf("%s: %s", problems[0].Field, problems[0].Message)
	}
	return refs, nil
}

func parseBNPlusRef(raw json.RawMessage) (Ref, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var block struct {
		Key     string `json:"key"`
		CardID  int64  `json:"card_id"`
		MaxCost string `json:"max_cost"`
	}
	if err := decoder.Decode(&block); err != nil {
		return Ref{}, fmt.Errorf("bnplus takes key, card_id and max_cost: %v", err)
	}
	if block.CardID <= 0 {
		return Ref{}, errors.New("bnplus needs card_id, the card's id at BN Plus")
	}
	ref := Ref{Supplier: SupplierBNPlus, ID: strconv.FormatInt(block.CardID, 10)}
	maxCost, err := parseMaxCost(block.MaxCost)
	if err != nil {
		return Ref{}, err
	}
	ref.MaxCost = maxCost
	return ref, nil
}

// parseMaxCost reads a supplier block's optional max_cost: dinars, positive,
// at most three decimals. "" is no guard.
func parseMaxCost(raw string) (string, error) {
	cost := strings.TrimSpace(raw)
	if cost == "" {
		return "", nil
	}
	value, ok := new(big.Rat).SetString(cost)
	if !ok || value.Sign() <= 0 || !facePattern.MatchString(cost) {
		return "", errors.New("max_cost must be a positive number of dinars with at most three decimals")
	}
	return cost, nil
}

// parseReloadlyRef reads {"key": "reloadly", "product_id": 13441, "amount": "50",
// "max_cost": "515.00"}: a Reloadly gift card product and the face value ordered
// from it, in the product's own currency. A RANGE product sells any amount in
// its bounds, so the amount belongs to the item and not to the product.
func parseReloadlyRef(raw json.RawMessage) (Ref, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var block struct {
		Key       string      `json:"key"`
		ProductID int64       `json:"product_id"`
		Amount    json.Number `json:"amount"`
		MaxCost   string      `json:"max_cost"`
	}
	if err := decoder.Decode(&block); err != nil {
		return Ref{}, fmt.Errorf("reloadly takes key, product_id, amount and max_cost: %v", err)
	}
	if block.ProductID <= 0 {
		return Ref{}, errors.New("reloadly needs product_id, the gift card product's id at Reloadly")
	}
	amount, err := ParseReloadlyAmount(string(block.Amount))
	if err != nil {
		return Ref{}, err
	}
	maxCost, err := parseMaxCost(block.MaxCost)
	if err != nil {
		return Ref{}, err
	}
	return Ref{
		Supplier: SupplierReloadly,
		ID:       ReloadlyRefID(block.ProductID, amount),
		MaxCost:  maxCost,
	}, nil
}

// ParseReloadlyAmount reads a Reloadly face value: a positive decimal with at
// most three decimals, the unit price of one card in the product's own currency.
func ParseReloadlyAmount(text string) (*big.Rat, error) {
	text = strings.TrimSpace(text)
	value, ok := new(big.Rat).SetString(text)
	if !ok || !facePattern.MatchString(text) || value.Sign() <= 0 {
		return nil, errors.New("reloadly needs amount, the card's face value in the product's currency: a positive number with at most three decimals")
	}
	return value, nil
}

// ReloadlyRefID is a Reloadly ref's ID: "<product_id>/<amount>", the amount as a
// plain decimal without trailing zeros ("50", "7.5").
func ReloadlyRefID(productID int64, amount *big.Rat) string {
	text := amount.FloatString(3)
	if strings.Contains(text, ".") {
		text = strings.TrimRight(text, "0")
		text = strings.TrimSuffix(text, ".")
	}
	return strconv.FormatInt(productID, 10) + "/" + text
}

// ParseReloadlyRefID is the inverse of ReloadlyRefID: the product and the face
// value of one card.
func ParseReloadlyRefID(id string) (int64, *big.Rat, error) {
	product, amountText, ok := strings.Cut(strings.TrimSpace(id), "/")
	if !ok {
		return 0, nil, fmt.Errorf("reloadly ref %q is not <product_id>/<amount>", id)
	}
	productID, err := strconv.ParseInt(strings.TrimSpace(product), 10, 64)
	if err != nil || productID <= 0 {
		return 0, nil, fmt.Errorf("reloadly ref %q has no product id", id)
	}
	amount, err := ParseReloadlyAmount(amountText)
	if err != nil {
		return 0, nil, fmt.Errorf("reloadly ref %q: %v", id, err)
	}
	return productID, amount, nil
}

func parseTestRef(raw json.RawMessage) (Ref, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var block struct {
		Key string `json:"key"`
		ID  string `json:"id"`
	}
	if err := decoder.Decode(&block); err != nil {
		return Ref{}, fmt.Errorf("test takes key and id: %v", err)
	}
	return Ref{Supplier: SupplierTest, ID: strings.TrimSpace(block.ID)}, nil
}

// Status of a supplier purchase.
type Status string

const (
	StatusSucceeded Status = "succeeded"
	StatusFailed    Status = "failed"
	// StatusPending is a purchase the supplier took and has not finished:
	// its codes may still come.
	StatusPending Status = "pending"
)

// Code is one bought card: the secret the customer redeems, and its serial.
type Code struct {
	Code   string `json:"code"`
	Serial string `json:"serial,omitempty"`
}

// Purchase is what a supplier says about one order.
type Purchase struct {
	OrderID string
	Status  Status
	// Cost is what the supplier charged the company for the whole order, in
	// Currency, as it wrote it.
	Cost     string
	Currency string
	Codes    []Code
	// Message is the supplier's own word, on a failure.
	Message string
	At      time.Time
}

// Offer is one card a supplier sells, at the company's price, read by the
// offer sync. It is what says whether an item is in stock and within its
// MaxCost, and what a card is called at the supplier. Price is in the
// supplier's own Currency: BN Plus quotes dinars (LYD), Reloadly dollars (USD,
// every fee and discount in); the relay converts to dinars to compare them.
type Offer struct {
	Ref      string    `json:"ref"`
	Name     string    `json:"name"`
	Group    string    `json:"group,omitempty"`
	Price    string    `json:"price"`
	Currency string    `json:"currency"`
	InStock  bool      `json:"in_stock"`
	SyncedAt time.Time `json:"synced_at"`
}

// Failure codes a purchase can end with. The shop's backend maps them to the
// till's words.
const (
	FailureOutOfStock   = "supplier_out_of_stock"
	FailureCredit       = "supplier_credit"
	FailureUnauthorized = "supplier_unauthorized"
	FailureRefused      = "supplier_refused"
	FailureUnreachable  = "supplier_unreachable"
	// FailureUnknown is an answer that leaves it open whether the card was
	// bought: never refunded until the supplier's own records say so.
	FailureUnknown = "supplier_unknown"
)

// Failure is a purchase that did not hand back codes.
type Failure struct {
	Code   string
	Detail string
	// Definite: nothing was bought, so the shop's money can come back now.
	Definite bool
	// OrderID is set when the supplier named an order despite failing.
	OrderID string
}

func (f *Failure) Error() string {
	if f.Detail == "" {
		return f.Code
	}
	return f.Code + ": " + f.Detail
}

// Supplier is a wholesaler the company buys cards from with its own account.
type Supplier interface {
	Key() string
	// Buy places one order. clientRef is unique to the purchase; a supplier
	// that takes an idempotency key sends it, BN Plus does not. A failure is
	// a *Failure.
	Buy(ctx context.Context, ref Ref, quantity int, clientRef string) (Purchase, error)
	// Lookup reads an order the supplier named.
	Lookup(ctx context.Context, ref Ref, orderID string) (Purchase, error)
	// Find looks for the order a purchase placed when its answer was lost:
	// every order for this card and quantity placed in [from, to], earliest
	// first. An empty answer means the supplier's records — read completely —
	// hold none; the caller skips the orders other purchases already hold.
	Find(ctx context.Context, ref Ref, quantity int, from, to time.Time) ([]Purchase, error)
	// Offers lists every card the supplier sells the company.
	Offers(ctx context.Context) ([]Offer, error)
}

// RefFinder is a supplier that records the reference a purchase was placed with
// and can look an order up by it — exactly, without guessing by card, quantity
// and time the way Supplier.Find has to. The reconciler prefers it, for an order
// whose answer was lost and that has no supplier order id yet.
type RefFinder interface {
	// FindByClientRef returns the orders the supplier holds for clientRef (the
	// purchase's id, as it was passed to Buy), earliest first. Normally none or
	// one. from and to bound the search and may be zero; the reference is what
	// identifies the order. Codes are not read: Lookup reads them.
	FindByClientRef(ctx context.Context, ref Ref, clientRef string, from, to time.Time) ([]Purchase, error)
}

// WantedOffers is a supplier whose price depends on the card asked for — a
// Reloadly product that takes any amount in a range prices each amount
// differently — so it cannot list "every card" the way BN Plus does. The offer
// sync hands it the refs the current catalog names and stores what it answers.
// It must never be a way to order anything.
type WantedOffers interface {
	// OffersFor prices exactly the wanted refs (all of this supplier's). A ref
	// the supplier no longer sells, or not in that amount, is simply absent from
	// the answer: that is how "no longer sold" reads.
	OffersFor(ctx context.Context, wanted []Ref) ([]Offer, error)
}

// BalanceReader is a supplier that knows how much the company has left with it,
// as last read (the offer sync reads it). The relay stops offering a card the
// account cannot pay for, instead of letting every purchase of it fail there.
type BalanceReader interface {
	// LastBalance is the company's balance at the supplier as last read, in
	// currency, and when it was read. ok is false when it never was.
	LastBalance() (amount *big.Rat, currency string, readAt time.Time, ok bool)
}

// ErrNameUnknown is Find without the supplier's name for the card: the offers
// have not been read yet, so a lost purchase cannot be told apart.
var ErrNameUnknown = errors.New("the supplier's name for this card is not known yet")
