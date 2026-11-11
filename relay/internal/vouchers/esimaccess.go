package vouchers

import (
	"context"
	"errors"
	"math/big"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/esimaccess"
)

// SupplierESIMAccess is eSIM Access: eSIMs and their top-ups, paid in dollars
// from the company's prepaid balance there. Like Airalo it is not in the card
// catalog: the relay's eSIM shelf reads its packages directly, and no card item
// can name it. It has no sandbox; every order is a real eSIM.
const SupplierESIMAccess = "esimaccess"

const (
	esimAccessRefSIM   = "sim/"
	esimAccessRefTopUp = "topup/"
	// esimAccessTopUpOrder prefixes the order id of a top-up, which eSIM Access
	// gives no order number of its own: it is the purchase's reference.
	esimAccessTopUpOrder = "topup-"
)

// ESIMAccessSIMRef is the ref of a first eSIM on a package. priceUnits is what
// the catalog said the package costs (ten-thousandths of a dollar): the order
// carries it, and eSIM Access refuses the order if the package costs something
// else by then, so a price that rose is never paid unseen.
func ESIMAccessSIMRef(packageCode string, priceUnits int64) Ref {
	return Ref{Supplier: SupplierESIMAccess, ID: esimAccessRefSIM + packageCode + "/" + strconv.FormatInt(priceUnits, 10)}
}

// ESIMAccessTopUpRef is the ref of a top-up package for an issued eSIM, named
// by its transaction number (and its ICCID, for one that has none recorded).
func ESIMAccessTopUpRef(tranNo, iccid, packageCode string, priceUnits int64) Ref {
	return Ref{Supplier: SupplierESIMAccess, ID: esimAccessRefTopUp + tranNo + "/" + iccid + "/" + packageCode + "/" + strconv.FormatInt(priceUnits, 10)}
}

type esimAccessRef struct {
	topUp               bool
	tranNo, iccid, code string
	price               int64
}

func parseESIMAccessRef(ref Ref) (esimAccessRef, bool) {
	if rest, ok := strings.CutPrefix(ref.ID, esimAccessRefSIM); ok {
		parts := strings.Split(rest, "/")
		if len(parts) != 2 || parts[0] == "" {
			return esimAccessRef{}, false
		}
		price, _ := strconv.ParseInt(parts[1], 10, 64)
		return esimAccessRef{code: parts[0], price: price}, true
	}
	if rest, ok := strings.CutPrefix(ref.ID, esimAccessRefTopUp); ok {
		parts := strings.Split(rest, "/")
		if len(parts) != 4 || parts[2] == "" || (parts[0] == "" && parts[1] == "") {
			return esimAccessRef{}, false
		}
		price, _ := strconv.ParseInt(parts[3], 10, 64)
		return esimAccessRef{topUp: true, tranNo: parts[0], iccid: parts[1], code: parts[2], price: price}, true
	}
	return esimAccessRef{}, false
}

// ESIMAccessSupplier buys through the Partner API. Each purchase is one eSIM.
type ESIMAccessSupplier struct {
	Client *esimaccess.Client
	// Wait is how long Buy waits for a new order's eSIM before leaving the
	// purchase open for the reconciler (eSIM Access makes it in the background,
	// in up to half a minute). Zero: 12 seconds.
	Wait time.Duration
	// Poll is the pause between reads while waiting. Zero: 1.5 seconds.
	Poll time.Duration
}

func (s *ESIMAccessSupplier) Key() string { return SupplierESIMAccess }

func (s *ESIMAccessSupplier) wait() (time.Duration, time.Duration) {
	wait, poll := s.Wait, s.Poll
	if wait <= 0 {
		wait = 12 * time.Second
	}
	if poll <= 0 {
		poll = 1500 * time.Millisecond
	}
	return wait, poll
}

// Buy places the order once, under clientRef as its transaction id. An answer
// that proves nothing (a timeout, a server error) leaves the purchase open for
// the reconciler, which finds the order by that id before anything else
// happens. An order that was taken but whose eSIM is not made yet comes back
// pending, with its order number: the reconciler reads it again.
func (s *ESIMAccessSupplier) Buy(ctx context.Context, ref Ref, quantity int, clientRef string) (Purchase, error) {
	if quantity != 1 {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: "an eSIM purchase is for one eSIM", Definite: true}
	}
	parsed, ok := parseESIMAccessRef(ref)
	if !ok {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: "a malformed eSIM ref", Definite: true}
	}
	if parsed.topUp {
		if _, err := s.Client.TopUp(ctx, parsed.tranNo, parsed.iccid, parsed.code, clientRef, parsed.price); err != nil {
			return Purchase{}, esimAccessFailure(err)
		}
		return esimAccessTopUpPurchase(parsed, clientRef), nil
	}
	orderNo, err := s.Client.Order(ctx, clientRef, parsed.code, parsed.price)
	if err != nil {
		return Purchase{}, esimAccessFailure(err)
	}
	pending := Purchase{OrderID: orderNo, Status: StatusPending, Cost: esimAccessCost(parsed.price), Currency: "USD", Codes: []Code{}}
	wait, poll := s.wait()
	deadline := time.Now().Add(wait)
	for {
		purchase, err := s.Lookup(ctx, ref, orderNo)
		if err == nil && purchase.Status != StatusPending {
			return purchase, nil
		}
		if time.Now().Add(poll).After(deadline) {
			return pending, nil
		}
		select {
		case <-ctx.Done():
			return pending, nil
		case <-time.After(poll):
		}
	}
}

func esimAccessCost(priceUnits int64) string {
	if priceUnits <= 0 {
		return ""
	}
	return esimaccess.Dollars(priceUnits)
}

// esimAccessFailure sorts the API's errors into what the ledger needs: whether
// the money can come back now.
func esimAccessFailure(err error) error {
	code := FailureUnknown
	var apiErr *esimaccess.APIError
	if errors.As(err, &apiErr) {
		switch {
		case apiErr.Code == esimaccess.CodeInsufficientFunds:
			code = FailureCredit
		case apiErr.Code == esimaccess.CodeOutOfStock:
			code = FailureOutOfStock
		case apiErr.Status == 401 || apiErr.Status == 403 || strings.HasPrefix(apiErr.Code, "101"):
			code = FailureUnauthorized
		case esimaccess.DefinitelyNotOrdered(err):
			code = FailureRefused
		}
	}
	return &Failure{Code: code, Detail: err.Error(), Definite: esimaccess.DefinitelyNotOrdered(err)}
}

func esimAccessTopUpPurchase(parsed esimAccessRef, clientRef string) Purchase {
	return Purchase{
		OrderID: esimAccessTopUpOrder + clientRef, Status: StatusSucceeded,
		Cost: esimAccessCost(parsed.price), Currency: "USD",
		Codes: []Code{{Code: "topup", Serial: parsed.iccid}},
	}
}

// esimAccessPurchase turns an eSIM into the ledger's words: its activation
// string is the code, its ICCID the serial.
func esimAccessPurchase(parsed esimAccessRef, profile esimaccess.Profile) Purchase {
	purchase := Purchase{
		OrderID: profile.OrderNo, Status: StatusPending,
		Cost: esimAccessCost(parsed.price), Currency: "USD", Codes: []Code{},
	}
	for _, loaded := range profile.Packages {
		if at := esimaccess.ParseTime(loaded.CreateTime); at != nil {
			purchase.At = *at
			break
		}
	}
	switch strings.ToUpper(strings.TrimSpace(profile.Status)) {
	case esimaccess.StatusCancel, esimaccess.StatusRevoke, esimaccess.StatusRevoked:
		purchase.Status = StatusFailed
		purchase.Message = "esimaccess reports the eSIM " + strings.ToLower(profile.Status)
		return purchase
	}
	if profile.ICCID != "" && profile.AC != "" {
		purchase.Status = StatusSucceeded
		purchase.Codes = []Code{{Code: profile.AC, Serial: profile.ICCID}}
	}
	return purchase
}

// Lookup reads an order by its number. One whose eSIM is still being made is
// pending, not an error.
func (s *ESIMAccessSupplier) Lookup(ctx context.Context, ref Ref, orderID string) (Purchase, error) {
	parsed, ok := parseESIMAccessRef(ref)
	if !ok {
		return Purchase{}, errors.New("a malformed eSIM ref")
	}
	if parsed.topUp {
		clientRef := strings.TrimPrefix(orderID, esimAccessTopUpOrder)
		loaded, err := s.topUpLoaded(ctx, parsed, time.Time{}, time.Time{})
		if err != nil {
			return Purchase{}, err
		}
		purchase := esimAccessTopUpPurchase(parsed, clientRef)
		if !loaded {
			purchase.Status, purchase.Codes = StatusPending, []Code{}
		}
		return purchase, nil
	}
	profiles, _, err := s.Client.Profiles(ctx, esimaccess.ProfileQuery{OrderNo: orderID, Size: 5})
	if esimaccess.IsCode(err, esimaccess.CodeAllocating) {
		return Purchase{OrderID: orderID, Status: StatusPending, Cost: esimAccessCost(parsed.price), Currency: "USD", Codes: []Code{}}, nil
	}
	if err != nil {
		return Purchase{}, err
	}
	for _, profile := range profiles {
		if profile.OrderNo == orderID {
			return esimAccessPurchase(parsed, profile), nil
		}
	}
	return Purchase{OrderID: orderID, Status: StatusPending, Cost: esimAccessCost(parsed.price), Currency: "USD", Codes: []Code{}}, nil
}

// topUpLoaded reports whether the eSIM carries the top-up package, loaded in
// [from, to] when those are set.
func (s *ESIMAccessSupplier) topUpLoaded(ctx context.Context, parsed esimAccessRef, from, to time.Time) (bool, error) {
	profile, err := s.Client.Profile(ctx, parsed.tranNo, parsed.iccid)
	if errors.Is(err, esimaccess.ErrNoProfile) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	for _, loaded := range profile.Packages {
		if loaded.Code != parsed.code && loaded.Slug != parsed.code {
			continue
		}
		at := esimaccess.ParseTime(loaded.CreateTime)
		if from.IsZero() && to.IsZero() {
			return true, nil
		}
		if at == nil || (!from.IsZero() && at.Before(from)) || (!to.IsZero() && at.After(to)) {
			continue
		}
		return true, nil
	}
	return false, nil
}

const (
	esimAccessFindPage  = 500
	esimAccessFindPages = 10
	// esimAccessSettle is how long after the search window an order may still
	// be on its way into the records: until then "none found" proves nothing.
	esimAccessSettle = 2 * time.Minute
)

// FindByClientRef finds the order a purchase placed, by the transaction id it
// was placed under. eSIM Access cannot be asked by that id, so the orders of
// the purchase's time are read and matched exactly. While the order could
// still be on its way in, finding none is an error, not an answer: the
// reconciler asks again instead of refunding an eSIM that is being made.
func (s *ESIMAccessSupplier) FindByClientRef(ctx context.Context, ref Ref, clientRef string, from, to time.Time) ([]Purchase, error) {
	parsed, ok := parseESIMAccessRef(ref)
	if !ok {
		return nil, errors.New("a malformed eSIM ref")
	}
	early := to.IsZero() || time.Now().Before(to.Add(esimAccessSettle))
	if parsed.topUp {
		if from.IsZero() {
			return nil, errors.New("a top-up is found by when it was bought")
		}
		loaded, err := s.topUpLoaded(ctx, parsed, from, to.Add(esimAccessSettle))
		if err != nil {
			return nil, err
		}
		if loaded {
			return []Purchase{esimAccessTopUpPurchase(parsed, clientRef)}, nil
		}
		if early {
			return nil, errors.New("too early to say the top-up was not loaded")
		}
		return []Purchase{}, nil
	}
	found := []Purchase{}
	for page := 1; page <= esimAccessFindPages; page++ {
		profiles, total, err := s.Client.Profiles(ctx, esimaccess.ProfileQuery{From: from, To: to, Page: page, Size: esimAccessFindPage})
		if err != nil {
			return nil, err
		}
		for _, profile := range profiles {
			if profile.TransactionID == clientRef {
				found = append(found, esimAccessPurchase(parsed, profile))
			}
		}
		if len(profiles) < esimAccessFindPage || page*esimAccessFindPage >= total {
			break
		}
		if page == esimAccessFindPages {
			return nil, errors.New("too many eSIM orders in the window to read them all")
		}
	}
	if len(found) == 0 && early {
		return nil, errors.New("too early to say no order was placed")
	}
	return found, nil
}

// Find is never the way an eSIM Access order is found (FindByClientRef is exact).
func (s *ESIMAccessSupplier) Find(context.Context, Ref, int, time.Time, time.Time) ([]Purchase, error) {
	return nil, errors.New("esimaccess orders are found by their reference")
}

// Offers is empty: the eSIM shelf has its own catalog sync.
func (s *ESIMAccessSupplier) Offers(context.Context) ([]Offer, error) { return []Offer{}, nil }

var _ RefFinder = (*ESIMAccessSupplier)(nil)

// ESIMRetail is how the shelf prices an eSIM Access plan. The company sets the
// suggested retail price of every package in eSIM Access's own dashboard (a
// percentage of the cost), in dollars; the shelf sells at that price at today's
// dollar rate (the one the cards are priced with, from fulus.ly), so the markup
// is tuned there and the dinar price follows the dollar by itself.
type ESIMRetail struct {
	// FallbackPercent is the retail price as a percentage of the cost, for a
	// package the API gives no suggested price for. Nil: 157.
	FallbackPercent *big.Rat
	// MinPrice is the lowest price of any plan, in dinars. Nil: none.
	MinPrice *big.Rat
	// Step is what a price is rounded up to, in dinars. Nil: the margin's step.
	Step *big.Rat
}

// ESIMRetailPrice is what a customer pays for an eSIM Access plan: its suggested
// retail price at the dollar rate, rounded up, never under the lowest price, and never
// under what the operator's margin asks on the real cost at the real dollar
// rate, so a suggested price set too low or a dear dollar cannot sell at a
// loss. ok is false without a cost, a rate or a readable margin.
func ESIMRetailPrice(netUSD, retailUSD, rate *big.Rat, margin Margin, retail ESIMRetail) (*big.Rat, bool) {
	if netUSD == nil || rate == nil || netUSD.Sign() <= 0 || rate.Sign() <= 0 {
		return nil, false
	}
	floor, ok := margin.Prices(new(big.Rat).Mul(netUSD, rate))
	parsed, parsedOK := margin.parse()
	if !ok || !parsedOK || floor.Retail == nil {
		return nil, false
	}
	dollars := retailUSD
	if dollars == nil || dollars.Sign() <= 0 {
		percent := retail.FallbackPercent
		if percent == nil || percent.Sign() <= 0 {
			percent = big.NewRat(157, 1)
		}
		dollars = new(big.Rat).Quo(new(big.Rat).Mul(netUSD, percent), big.NewRat(100, 1))
	}
	price := new(big.Rat).Mul(dollars, rate)
	if retail.MinPrice != nil && price.Cmp(retail.MinPrice) < 0 {
		price.Set(retail.MinPrice)
	}
	step := parsed.step
	if retail.Step != nil && retail.Step.Sign() > 0 {
		step = retail.Step
	}
	price = settingsCeil(price, step)
	if price.Cmp(floor.Retail) < 0 {
		price = floor.Retail
	}
	return price, true
}
