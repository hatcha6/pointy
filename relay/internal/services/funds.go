package services

import (
	"context"
	"math/big"
	"strings"
	"sync"
	"time"
)

// The company's balance at the supplier keeps an airtime top-up or a bill
// payment it cannot pay for from being sold: the quote and the order are refused
// as unavailable, instead of the shop's money being held for an order the
// supplier will turn down. Like the cards' (see the relay's balanceReason), a
// balance never read, read too long ago, or in another currency than the order's
// cost is not believed, and the sale goes ahead.

const (
	// FundsInterval is how often RunFunds reads the balance again.
	FundsInterval = 2 * time.Minute
	// fundsMaxAge is how old a balance may be and still stop a sale.
	fundsMaxAge = 2 * time.Hour
	// ReasonSupplierFunds: the company's balance at the supplier cannot pay for
	// this. The shop is told only "unavailable", never whose balance.
	ReasonSupplierFunds = "supplier_funds"
)

// fundsProduct is the supplier product whose balance pays for a kind.
func fundsProduct(kind string) string {
	if kind == KindBill {
		return "utilities"
	}
	return "topups"
}

type fundsReading struct {
	amount   *big.Rat
	currency string
	at       time.Time
}

type funds struct {
	mu       sync.Mutex
	products map[string]fundsReading
}

// RunFunds reads the company's balance at the supplier until ctx ends: at once,
// then every FundsInterval. Test mode buys from nobody and reads nothing.
func (s *Service) RunFunds(ctx context.Context) {
	if !s.Configured() || s.cfg.TestMode || s.cfg.Balances == nil {
		return
	}
	ticker := time.NewTicker(FundsInterval)
	defer ticker.Stop()
	for {
		s.RefreshFunds(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// RefreshFunds reads the balance once. A product whose read fails keeps its last
// reading, which stops being believed after fundsMaxAge.
func (s *Service) RefreshFunds(ctx context.Context) {
	if s == nil || s.cfg.Balances == nil {
		return
	}
	readCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	lines := s.cfg.Balances.Balances(readCtx)
	now := s.now()
	s.funds.mu.Lock()
	defer s.funds.mu.Unlock()
	if s.funds.products == nil {
		s.funds.products = map[string]fundsReading{}
	}
	for _, line := range lines {
		if line.Error != "" {
			continue
		}
		amount, ok := new(big.Rat).SetString(strings.TrimSpace(line.Balance))
		if !ok {
			continue
		}
		s.funds.products[line.Product] = fundsReading{
			amount:   amount,
			currency: strings.ToUpper(strings.TrimSpace(line.Currency)),
			at:       now,
		}
	}
}

// affordable refuses a sale whose cost, in dollars, the last believed balance
// cannot pay for; nil when it can or nothing believable is known.
func (s *Service) affordable(kind string, costUSD *big.Rat) *Refusal {
	if s.cfg.TestMode || costUSD == nil {
		return nil
	}
	s.funds.mu.Lock()
	reading, known := s.funds.products[fundsProduct(kind)]
	s.funds.mu.Unlock()
	if !known || s.now().Sub(reading.at) >= fundsMaxAge || (reading.currency != "" && reading.currency != "USD") {
		return nil
	}
	if costUSD.Cmp(reading.amount) > 0 {
		return refuseUnavailable(ReasonSupplierFunds)
	}
	return nil
}

// Spent takes an order the supplier may have carried out off the balance at
// once, so the next sale is judged by what is left before the next read.
func (s *Service) Spent(kind string, costUSD *big.Rat) {
	if s == nil || costUSD == nil {
		return
	}
	s.funds.mu.Lock()
	defer s.funds.mu.Unlock()
	product := fundsProduct(kind)
	if reading, known := s.funds.products[product]; known {
		reading.amount = new(big.Rat).Sub(reading.amount, costUSD)
		s.funds.products[product] = reading
	}
}
