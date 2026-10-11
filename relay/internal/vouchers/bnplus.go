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

	"pointy/relay/internal/bnplus"
)

// BNPlusSupplier buys from BN Plus with the company's merchant account.
type BNPlusSupplier struct {
	Client *bnplus.Client

	// The company's dinar balance at BN Plus as the offer sync last read it,
	// less what was bought since.
	mu        sync.Mutex
	balance   *big.Rat
	balanceAt time.Time
}

var (
	_ Supplier      = (*BNPlusSupplier)(nil)
	_ BalanceReader = (*BNPlusSupplier)(nil)
)

func (s *BNPlusSupplier) Key() string { return SupplierBNPlus }

func (s *BNPlusSupplier) Buy(ctx context.Context, ref Ref, quantity int, _ string) (Purchase, error) {
	cardID, err := bnplusCardID(ref)
	if err != nil {
		return Purchase{}, &Failure{Code: FailureRefused, Detail: err.Error(), Definite: true}
	}
	order, err := s.Client.BuyCard(ctx, cardID, quantity)
	if err != nil {
		return Purchase{}, bnplusFailure(err)
	}
	purchase := bnplusPurchase(order)
	s.spent(purchase)
	if len(purchase.Codes) < quantity {
		// BN Plus took the order but handed back fewer codes than bought.
		// The rest may still come; the order is read back until it settles.
		purchase.Status = StatusPending
	}
	return purchase, nil
}

func (s *BNPlusSupplier) Lookup(ctx context.Context, _ Ref, orderID string) (Purchase, error) {
	id, err := strconv.ParseInt(strings.TrimSpace(orderID), 10, 64)
	if err != nil || id <= 0 {
		return Purchase{}, fmt.Errorf("bnplus order id %q is not a number", orderID)
	}
	order, err := s.Client.OrderStatus(ctx, id)
	if err != nil {
		return Purchase{}, err
	}
	return bnplusPurchase(order), nil
}

func (s *BNPlusSupplier) Find(
	ctx context.Context,
	ref Ref,
	quantity int,
	from, to time.Time,
) ([]Purchase, error) {
	name := strings.TrimSpace(ref.Name)
	if name == "" {
		return nil, ErrNameUnknown
	}
	orders, err := s.Client.Orders(ctx)
	if err != nil {
		return nil, err
	}
	var matches []bnplus.Order
	for _, order := range orders {
		if order.ID == 0 || order.Quantity != quantity {
			continue
		}
		if !strings.EqualFold(strings.TrimSpace(order.CardName), name) {
			continue
		}
		if order.Date.IsZero() || order.Date.Before(from) || order.Date.After(to) {
			continue
		}
		matches = append(matches, order)
	}
	// Earliest first: two lost purchases of the same card are told apart only
	// by order, and each order is claimed once.
	sort.Slice(matches, func(i, j int) bool {
		if !matches[i].Date.Equal(matches[j].Date) {
			return matches[i].Date.Before(matches[j].Date)
		}
		return matches[i].ID < matches[j].ID
	})
	purchases := make([]Purchase, 0, len(matches))
	for _, order := range matches {
		purchases = append(purchases, bnplusPurchase(order))
	}
	return purchases, nil
}

func (s *BNPlusSupplier) Offers(ctx context.Context) ([]Offer, error) {
	// The balance rides along: a card the account cannot pay for is not offered.
	// A read that fails leaves the last one, which the relay stops believing
	// after a while.
	s.readBalance(ctx)
	companies, err := s.Client.Companies(ctx, 0)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	var offers []Offer
	for _, company := range companies {
		cards, err := s.Client.Cards(ctx, company.BranchID)
		if err != nil {
			return nil, fmt.Errorf("cards of %s (%d): %w", company.Name, company.BranchID, err)
		}
		for _, card := range cards {
			offers = append(offers, Offer{
				Ref:      strconv.FormatInt(card.ID, 10),
				Name:     card.Name,
				Group:    company.Name,
				Price:    card.MerchantPrice,
				Currency: card.Currency,
				InStock:  card.InStock,
				SyncedAt: now,
			})
		}
	}
	return offers, nil
}

// readBalance reads the company's dinar wallet (every BN Plus card is priced in
// dinars) and keeps it with the time it was read.
func (s *BNPlusSupplier) readBalance(ctx context.Context) {
	wallets, err := s.Client.Wallets(ctx)
	if err != nil {
		return
	}
	for _, wallet := range wallets {
		if wallet.Currency != "LYD" {
			continue
		}
		amount, ok := new(big.Rat).SetString(strings.TrimSpace(wallet.Balance))
		if !ok {
			return
		}
		s.mu.Lock()
		s.balance, s.balanceAt = amount, time.Now()
		s.mu.Unlock()
		return
	}
}

// spent takes a card just bought off the last read balance, so the cards the
// rest of it cannot pay for leave the shelf before the next read.
func (s *BNPlusSupplier) spent(purchase Purchase) {
	cost, ok := new(big.Rat).SetString(strings.TrimSpace(purchase.Cost))
	currency := strings.ToUpper(strings.TrimSpace(purchase.Currency))
	if !ok || purchase.Status == StatusFailed || (currency != "" && currency != "LYD") {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.balance != nil {
		s.balance = new(big.Rat).Sub(s.balance, cost)
	}
}

// LastBalance is the company's dinar balance at BN Plus as last read.
func (s *BNPlusSupplier) LastBalance() (*big.Rat, string, time.Time, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.balance == nil {
		return nil, "", time.Time{}, false
	}
	return new(big.Rat).Set(s.balance), "LYD", s.balanceAt, true
}

func bnplusCardID(ref Ref) (int64, error) {
	id, err := strconv.ParseInt(strings.TrimSpace(ref.ID), 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("bnplus card id %q is not a number", ref.ID)
	}
	return id, nil
}

func bnplusPurchase(order bnplus.Order) Purchase {
	purchase := Purchase{
		OrderID:  strconv.FormatInt(order.ID, 10),
		Cost:     order.TotalPrice,
		Currency: order.Currency,
		Message:  order.FailedMessage,
		At:       order.Date,
	}
	if order.ID == 0 {
		purchase.OrderID = ""
	}
	for _, code := range order.Codes {
		purchase.Codes = append(purchase.Codes, Code{Code: code.Code, Serial: code.Serial})
	}
	switch order.Status {
	case bnplus.StatusSucceeded:
		purchase.Status = StatusSucceeded
	case bnplus.StatusFailed:
		purchase.Status = StatusFailed
	default:
		purchase.Status = StatusPending
	}
	return purchase
}

// bnplusFailure reads a failed purchase. Only what proves nothing was bought
// is definite (see bnplus.Definite); the rest waits for BN Plus's own records.
func bnplusFailure(err error) *Failure {
	failure := &Failure{Detail: err.Error(), Definite: bnplus.Definite(err)}
	var provider *bnplus.ProviderError
	if errors.As(err, &provider) && provider.OrderID != 0 {
		failure.OrderID = strconv.FormatInt(provider.OrderID, 10)
	}
	switch {
	case !failure.Definite:
		failure.Code = FailureUnknown
	case errors.Is(err, bnplus.ErrOutOfStock):
		failure.Code = FailureOutOfStock
	case errors.Is(err, bnplus.ErrInsufficientBalance):
		failure.Code = FailureCredit
	case errors.Is(err, bnplus.ErrUnauthorized):
		failure.Code = FailureUnauthorized
	default:
		var transport *bnplus.TransportError
		if errors.As(err, &transport) {
			failure.Code = FailureUnreachable
		} else {
			failure.Code = FailureRefused
		}
	}
	return failure
}
