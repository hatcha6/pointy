package vouchers

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/reloadly"
)

const (
	// DefaultReloadlySenderName is what Reloadly prints on the receipt of an
	// order as its sender.
	DefaultReloadlySenderName = "Daftar"
	// DefaultReloadlyProductTTL is how long the gift card catalog read for the
	// offer sync is reused.
	DefaultReloadlyProductTTL = 10 * time.Minute
	// reloadlyRefreshAfter is how soon a catalog that lacks a wanted product is
	// read again: the product may be new, and reading the catalog is not free.
	reloadlyRefreshAfter = time.Minute
	// reloadlyCurrency is the currency of the company's account at Reloadly.
	reloadlyCurrency = "USD"
)

// ReloadlySupplier buys gift cards from Reloadly with the company's account
// there, which is held in dollars. An item names a Reloadly product and the
// face value to order from it ("<product_id>/<amount>"); the card's price is
// worked out from the product's own numbers (reloadly.GiftCost), never guessed.
//
// Reloadly records the customIdentifier of every order it accepts, and the relay
// passes the purchase's id as that, so an order whose answer was lost is found
// again exactly (FindByClientRef). It implements RefFinder and WantedOffers.
type ReloadlySupplier struct {
	Client *reloadly.Client
	// SenderName is printed on the order; DefaultReloadlySenderName when empty.
	SenderName string
	// ProductTTL is how long the gift card catalog is reused between offer
	// syncs; DefaultReloadlyProductTTL when zero.
	ProductTTL time.Duration

	mu      sync.Mutex
	index   map[int64]reloadly.GiftProduct
	readAt  time.Time
	nowFunc func() time.Time

	// The company's balance at Reloadly as the offer sync last read it.
	balance         *big.Rat
	balanceCurrency string
	balanceAt       time.Time
}

var (
	_ Supplier      = (*ReloadlySupplier)(nil)
	_ RefFinder     = (*ReloadlySupplier)(nil)
	_ WantedOffers  = (*ReloadlySupplier)(nil)
	_ BalanceReader = (*ReloadlySupplier)(nil)
)

func (s *ReloadlySupplier) Key() string { return SupplierReloadly }

func (s *ReloadlySupplier) now() time.Time {
	if s.nowFunc != nil {
		return s.nowFunc()
	}
	return time.Now()
}

func (s *ReloadlySupplier) senderName() string {
	if name := strings.TrimSpace(s.SenderName); name != "" {
		return name
	}
	return DefaultReloadlySenderName
}

func (s *ReloadlySupplier) productTTL() time.Duration {
	if s.ProductTTL > 0 {
		return s.ProductTTL
	}
	return DefaultReloadlyProductTTL
}

// Buy orders quantity cards of the ref's face value, passing clientRef as the
// order's customIdentifier. It makes ONE attempt (the client never retries a
// purchase). The answer is a success only when the order is SUCCESSFUL and its
// codes were read back: an order Reloadly is still processing, or whose codes
// cannot be read yet, comes back StatusPending with its id, and the relay reads
// it again until it settles.
func (s *ReloadlySupplier) Buy(ctx context.Context, ref Ref, quantity int, clientRef string) (Purchase, error) {
	productID, amount, err := ParseReloadlyRefID(ref.ID)
	if err != nil {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: err.Error(), Definite: true}
	}
	order, err := s.Client.OrderGiftCard(ctx, reloadly.GiftOrderRequest{
		ProductID:        productID,
		Quantity:         quantity,
		UnitPrice:        reloadly.NumFromRat(amount, 3),
		CustomIdentifier: clientRef,
		SenderName:       s.senderName(),
	})
	if err != nil {
		return Purchase{}, reloadlyFailure(err)
	}
	purchase := reloadlyPurchase(order)
	switch purchase.Status {
	case StatusFailed:
		// FAILED and REFUNDED deliver nothing and leave the account whole.
		return Purchase{}, &Failure{
			Code:     FailureRefused,
			Detail:   fmt.Sprintf("Reloadly order %s ended %s", purchase.OrderID, order.Status),
			Definite: true,
			OrderID:  purchase.OrderID,
		}
	case StatusSucceeded:
		codes, err := s.Client.GiftRedeemCodes(ctx, order.TransactionID)
		purchase.Codes = reloadlyCodes(codes)
		if err != nil || len(purchase.Codes) < quantity {
			// Never claim success without the codes in hand: the order is
			// real, so it is read back until they can be.
			purchase.Status = StatusPending
		}
	}
	return purchase, nil
}

// Lookup reads an order back by Reloadly's transaction id, with its codes when
// it is complete.
func (s *ReloadlySupplier) Lookup(ctx context.Context, _ Ref, orderID string) (Purchase, error) {
	id, err := strconv.ParseInt(strings.TrimSpace(orderID), 10, 64)
	if err != nil || id <= 0 {
		return Purchase{}, fmt.Errorf("reloadly order id %q is not a number", orderID)
	}
	transaction, err := s.Client.GiftTransaction(ctx, id)
	if err != nil {
		return Purchase{}, err
	}
	purchase := reloadlyPurchase(transaction)
	if purchase.Status == StatusSucceeded {
		codes, err := s.Client.GiftRedeemCodes(ctx, id)
		if err != nil {
			return Purchase{}, fmt.Errorf("reading the codes of Reloadly order %d: %w", id, err)
		}
		purchase.Codes = reloadlyCodes(codes)
	}
	return purchase, nil
}

// Find is not how a Reloadly order is found again: FindByClientRef is exact,
// and the reconciler prefers it. Guessing by card, quantity and time is
// refused rather than answered with an emptiness that would read as "no such
// order" and give the shop's money back.
func (s *ReloadlySupplier) Find(context.Context, Ref, int, time.Time, time.Time) ([]Purchase, error) {
	return nil, errors.New("a Reloadly order is found by the reference it was placed with (FindByClientRef), not by card and time")
}

// FindByClientRef looks the order up by its customIdentifier. The codes are
// not read: Lookup reads them for an order whose id is known.
func (s *ReloadlySupplier) FindByClientRef(
	ctx context.Context,
	_ Ref,
	clientRef string,
	from, to time.Time,
) ([]Purchase, error) {
	clientRef = strings.TrimSpace(clientRef)
	if clientRef == "" {
		return nil, errors.New("a client reference is required to find a Reloadly order")
	}
	rows, err := s.Client.FindGiftTransactions(ctx, clientRef, from, to)
	if err != nil {
		return nil, err
	}
	var purchases []Purchase
	for _, row := range rows {
		// The search is not exact (it ignores case, and may match a part): only
		// an order placed with this very reference is this purchase's.
		if strings.EqualFold(strings.TrimSpace(row.CustomIdentifier), clientRef) {
			purchases = append(purchases, reloadlyPurchase(row))
		}
	}
	sort.SliceStable(purchases, func(i, j int) bool {
		if !purchases[i].At.Equal(purchases[j].At) {
			return purchases[i].At.Before(purchases[j].At)
		}
		return purchases[i].OrderID < purchases[j].OrderID
	})
	return purchases, nil
}

// Offers lists nothing: a Reloadly card's price depends on the amount ordered,
// so the offer sync asks OffersFor for the cards the catalog names. Nothing is
// ever ordered through here.
func (s *ReloadlySupplier) Offers(context.Context) ([]Offer, error) { return nil, nil }

// OffersFor prices exactly the wanted refs from the gift card catalog, in
// dollars with every fee and discount in (the upper end of the price when a
// product's exchange rate is only known to within its rounding, so a guard on
// the margin is never fooled). A ref whose product is gone, or whose amount the
// product does not sell, is absent from the answer. A product Reloadly marks
// inactive, or that needs a player id the till cannot give, is listed out of stock.
func (s *ReloadlySupplier) OffersFor(ctx context.Context, wanted []Ref) ([]Offer, error) {
	// The balance rides along: a card the account cannot pay for is not offered.
	// A read that fails leaves the last one, which the relay stops believing
	// after a while.
	s.readBalance(ctx)
	index, readAt, err := s.catalog(ctx, false)
	if err != nil {
		return nil, err
	}
	missing := func(index map[int64]reloadly.GiftProduct) bool {
		for _, ref := range wanted {
			if productID, _, err := ParseReloadlyRefID(ref.ID); err == nil {
				if _, ok := index[productID]; !ok {
					return true
				}
			}
		}
		return false
	}
	if missing(index) && s.now().Sub(readAt) > reloadlyRefreshAfter {
		// A product the cached catalog lacks may be new: look once more.
		if index, _, err = s.catalog(ctx, true); err != nil {
			return nil, err
		}
	}

	now := s.now().UTC()
	seen := map[string]bool{}
	offers := make([]Offer, 0, len(wanted))
	for _, ref := range wanted {
		if ref.Supplier != "" && ref.Supplier != SupplierReloadly || seen[ref.ID] {
			continue
		}
		seen[ref.ID] = true
		productID, amount, err := ParseReloadlyRefID(ref.ID)
		if err != nil {
			continue
		}
		product, ok := index[productID]
		if !ok {
			continue
		}
		_, cost, ok := reloadly.GiftCostBounds(product, amount, 1)
		if !ok {
			continue
		}
		currency := strings.ToUpper(strings.TrimSpace(product.SenderCurrencyCode))
		if currency == "" {
			currency = reloadlyCurrency
		}
		offers = append(offers, Offer{
			Ref:      ref.ID,
			Name:     product.Name,
			Group:    product.Brand.Name,
			Price:    cost.FloatString(reloadly.CostPlaces),
			Currency: currency,
			InStock:  reloadlyProductActive(product),
			SyncedAt: now,
		})
	}
	return offers, nil
}

// reloadlyProductActive reports whether Reloadly sells the product and the relay
// can order it: it is ACTIVE, and it needs no player or account id (a product
// that does cannot be bought without asking the customer for one, which a card
// sold at a till has no place for).
// readBalance reads the company's gift card balance and keeps it with the time
// it was read.
func (s *ReloadlySupplier) readBalance(ctx context.Context) {
	balance, err := s.Client.GiftBalance(ctx)
	if err != nil {
		return
	}
	amount, ok := balance.Balance.Rat()
	if !ok {
		return
	}
	currency := strings.ToUpper(strings.TrimSpace(balance.CurrencyCode))
	if currency == "" {
		currency = reloadlyCurrency
	}
	s.mu.Lock()
	s.balance, s.balanceCurrency, s.balanceAt = amount, currency, s.now()
	s.mu.Unlock()
}

// LastBalance is the company's balance at Reloadly as the offer sync last read
// it: the account is held in dollars.
func (s *ReloadlySupplier) LastBalance() (*big.Rat, string, time.Time, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.balance == nil {
		return nil, "", time.Time{}, false
	}
	return new(big.Rat).Set(s.balance), s.balanceCurrency, s.balanceAt, true
}

func reloadlyProductActive(product reloadly.GiftProduct) bool {
	status := strings.TrimSpace(product.Status)
	return (status == "" || strings.EqualFold(status, "ACTIVE")) && !product.AdditionalRequirements.UserIDRequired
}

// catalog is the gift card catalog by product id, reused for ProductTTL unless
// force asks for a fresh read, and when it was read.
func (s *ReloadlySupplier) catalog(ctx context.Context, force bool) (map[int64]reloadly.GiftProduct, time.Time, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !force && s.index != nil && s.now().Sub(s.readAt) < s.productTTL() {
		return s.index, s.readAt, nil
	}
	products, err := s.Client.Products(ctx)
	if err != nil {
		return nil, time.Time{}, err
	}
	index := make(map[int64]reloadly.GiftProduct, len(products))
	for _, product := range products {
		// What a price needs is kept; the long texts are not.
		product.RedeemInstruction = reloadly.RedeemInstruction{}
		product.LogoURLs = nil
		index[product.ID] = product
	}
	s.index, s.readAt = index, s.now()
	return s.index, s.readAt, nil
}

// reloadlyPurchase reads Reloadly's record of an order. Its codes are not part
// of it: they are read separately, for a SUCCESSFUL order.
func reloadlyPurchase(order reloadly.GiftTransaction) Purchase {
	purchase := Purchase{
		OrderID:  strconv.FormatInt(order.TransactionID, 10),
		Cost:     order.Amount.String(),
		Currency: strings.ToUpper(strings.TrimSpace(order.CurrencyCode)),
		At:       order.CreatedAt.Time,
	}
	if purchase.Cost == "" {
		purchase.Cost = order.Balance.Cost.String()
	}
	if order.TransactionID == 0 {
		purchase.OrderID = ""
	}
	switch {
	case order.Status.Succeeded():
		purchase.Status = StatusSucceeded
	case order.Status.Unsuccessful():
		// REFUNDED and FAILED cost nothing: the account was left whole.
		purchase.Status = StatusFailed
		purchase.Cost, purchase.Currency = "", ""
		purchase.Message = "Reloadly ended the order " + string(order.Status)
	default:
		// PENDING, PROCESSING, or a status this relay does not know: still open.
		purchase.Status = StatusPending
	}
	return purchase
}

// reloadlyCodes turns Reloadly's cards into codes. A card is a number, a PIN
// or a link to redeem at; the secret to redeem is the Code and, when the card
// has a second part the customer needs, it rides in Serial:
//
//	card number (+ PIN)         Code = number,  Serial = PIN
//	PIN + redemption link       Code = PIN,     Serial = link
//	redemption link alone       Code = link
//
// A card with nothing in it is dropped, so the count never claims a code that
// is not there.
func reloadlyCodes(cards []reloadly.GiftCode) []Code {
	codes := make([]Code, 0, len(cards))
	for _, card := range cards {
		number := strings.TrimSpace(card.CardNumber.String())
		pin := strings.TrimSpace(card.PinCode.String())
		link := strings.TrimSpace(card.RedemptionURL.String())
		switch {
		case number != "":
			codes = append(codes, Code{Code: number, Serial: pin})
		case pin != "":
			codes = append(codes, Code{Code: pin, Serial: link})
		case link != "":
			codes = append(codes, Code{Code: link})
		}
	}
	return codes
}

// reloadlyFailure reads a failed order. Only what proves nothing was bought is
// definite (reloadly.Definite); the rest waits for Reloadly's own records, found
// by the order's customIdentifier.
func reloadlyFailure(err error) *Failure {
	failure := &Failure{Detail: err.Error(), Definite: reloadly.Definite(err)}
	var transport *reloadly.TransportError
	switch {
	case reloadly.IsDuplicateIdentifier(err):
		// An accepted order already carries this reference: the card may well
		// have been bought, so this is never a refusal.
		failure.Definite = false
		failure.Code = FailureUnknown
	case !failure.Definite:
		failure.Code = FailureUnknown
	case reloadly.IsInsufficientBalance(err):
		failure.Code = FailureCredit
	case reloadly.IsUnauthorized(err):
		failure.Code = FailureUnauthorized
	case errors.As(err, &transport), errors.Is(err, reloadly.ErrRateLimited), errors.Is(err, reloadly.ErrOperatorUnavailable):
		failure.Code = FailureUnreachable
	default:
		failure.Code = FailureRefused
	}
	return failure
}
