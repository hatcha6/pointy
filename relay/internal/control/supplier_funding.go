package control

import (
	"context"
	"errors"
	"math/big"
	"sort"
	"strings"
	"time"
)

// SupplierFunding is one top-up of the company's balance at a dollar supplier
// (FazerCards, Reloadly, eSIM Access): what was paid in dinars and how many
// dollars actually arrived. It is the only record of what the dollars a
// supplier holds cost us, which the dollar rate cards are priced at reads
// (vouchers/fx.go, FX_FUNDING_PLAN.md). Rows are never edited: a mistake is
// voided (with a reason) and recorded again.
type SupplierFunding struct {
	ID       string `json:"id"`
	Supplier string `json:"supplier"`
	// USD is the dollars that arrived (after any fee the route took); LYD what
	// was paid for them, every fee included.
	USD string `json:"usd"`
	LYD string `json:"lyd"`
	// Method is how the dollars were bought: bnplus_usdt (Binance USDT codes
	// bought from BN Plus), bank_transfer, card, cash_exchange or other.
	Method string `json:"method"`
	// Reference ties the row to what paid for it (company purchase ids, a bank
	// reference); free text.
	Reference string `json:"reference,omitempty"`
	// MarketRate is the bank rate priced by when the dollars were bought: the
	// refill premium is LYD/USD against it.
	MarketRate string     `json:"market_rate,omitempty"`
	Note       string     `json:"note,omitempty"`
	Actor      string     `json:"actor,omitempty"`
	FundedAt   time.Time  `json:"funded_at"`
	CreatedAt  time.Time  `json:"created_at"`
	VoidedAt   *time.Time `json:"voided_at,omitempty"`
	VoidReason string     `json:"void_reason,omitempty"`
	VoidActor  string     `json:"void_actor,omitempty"`
}

// Funding methods.
var SupplierFundingMethods = []string{"bnplus_usdt", "bank_transfer", "card", "cash_exchange", "other"}

// SupplierFundingStore is an optional store capability for the funding ledger.
type SupplierFundingStore interface {
	// ListSupplierFundings returns every row, voided ones included, newest first.
	ListSupplierFundings(ctx context.Context) ([]SupplierFunding, error)
	CreateSupplierFunding(ctx context.Context, funding SupplierFunding) (SupplierFunding, error)
	VoidSupplierFunding(ctx context.Context, id, reason, actor string) (SupplierFunding, error)
}

// ExchangeRateSeriesStore reads one rate series over a window, oldest first:
// what the fading peak and the momentum of the dollar rate are judged on.
type ExchangeRateSeriesStore interface {
	ListExchangeRateSeries(ctx context.Context, from, to, instrument, bankCode string, since time.Time) ([]ExchangeRate, error)
}

var (
	ErrSupplierFundingNotFound = errors.New("supplier funding not found")
	ErrSupplierFundingVoided   = errors.New("supplier funding is already voided")
	ErrInvalidSupplierFunding  = errors.New("invalid supplier funding")
)

// maxFundingSeriesRows bounds a series read: a fortnight of a busy feed.
const maxFundingSeriesRows = 5000

// SupplierFundingProblem names the field a funding was refused for.
type SupplierFundingProblem struct {
	Field   string
	Message string
}

func (p SupplierFundingProblem) Error() string { return p.Field + ": " + p.Message }
func (p SupplierFundingProblem) Unwrap() error { return ErrInvalidSupplierFunding }

func positiveDecimal(raw string) (*big.Rat, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" || strings.ContainsAny(raw, "eE/+-") {
		return nil, false
	}
	r, ok := new(big.Rat).SetString(raw)
	return r, ok && r.Sign() > 0
}

// NormalizeSupplierFunding validates and trims a funding before it is stored.
func NormalizeSupplierFunding(f SupplierFunding, now time.Time) (SupplierFunding, error) {
	f.Supplier, _ = NormalizeIntegrationKey(f.Supplier)
	if !integrationKeyPattern.MatchString(f.Supplier) {
		return SupplierFunding{}, SupplierFundingProblem{"supplier", "must name a supplier"}
	}
	usd, ok := positiveDecimal(f.USD)
	if !ok {
		return SupplierFunding{}, SupplierFundingProblem{"usd", "must be a positive amount"}
	}
	lyd, ok := positiveDecimal(f.LYD)
	if !ok {
		return SupplierFunding{}, SupplierFundingProblem{"lyd", "must be a positive amount"}
	}
	// A rate outside 1..100 dinars a dollar is a typo, not a purchase.
	if rate := new(big.Rat).Quo(lyd, usd); rate.Cmp(big.NewRat(1, 1)) < 0 || rate.Cmp(big.NewRat(100, 1)) > 0 {
		return SupplierFunding{}, SupplierFundingProblem{"lyd", "dinars per dollar must be between 1 and 100"}
	}
	f.USD, f.LYD = usd.FloatString(4), lyd.FloatString(3)
	if strings.TrimSpace(f.MarketRate) != "" {
		market, ok := positiveDecimal(f.MarketRate)
		if !ok {
			return SupplierFunding{}, SupplierFundingProblem{"market_rate", "must be a positive rate"}
		}
		f.MarketRate = market.FloatString(4)
	}
	f.Method = strings.ToLower(strings.TrimSpace(f.Method))
	if f.Method == "" {
		f.Method = "other"
	}
	known := false
	for _, m := range SupplierFundingMethods {
		known = known || m == f.Method
	}
	if !known {
		return SupplierFunding{}, SupplierFundingProblem{"method", "must be one of " + strings.Join(SupplierFundingMethods, ", ")}
	}
	f.Reference = truncateRunes(strings.TrimSpace(f.Reference), maxIntegrationSwitchText)
	f.Note = truncateRunes(strings.TrimSpace(f.Note), maxIntegrationSwitchText)
	f.Actor = truncateRunes(strings.TrimSpace(f.Actor), maxIntegrationSwitchText)
	if f.FundedAt.IsZero() {
		f.FundedAt = now
	}
	if f.FundedAt.After(now.Add(5 * time.Minute)) {
		return SupplierFunding{}, SupplierFundingProblem{"funded_at", "cannot be in the future"}
	}
	f.FundedAt = f.FundedAt.UTC()
	f.CreatedAt = now
	f.VoidedAt, f.VoidReason, f.VoidActor = nil, "", ""
	return f, nil
}

func sortSupplierFundings(rows []SupplierFunding) {
	sort.Slice(rows, func(i, j int) bool {
		if !rows[i].FundedAt.Equal(rows[j].FundedAt) {
			return rows[i].FundedAt.After(rows[j].FundedAt)
		}
		return rows[i].ID > rows[j].ID
	})
}

// --- file store ------------------------------------------------------------

func (s *FileStore) ListSupplierFundings(_ context.Context) ([]SupplierFunding, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows := make([]SupplierFunding, 0, len(s.data.SupplierFundings))
	for _, f := range s.data.SupplierFundings {
		rows = append(rows, f)
	}
	sortSupplierFundings(rows)
	return rows, nil
}

func (s *FileStore) CreateSupplierFunding(_ context.Context, f SupplierFunding) (SupplierFunding, error) {
	f, err := NormalizeSupplierFunding(f, s.clock.Now())
	if err != nil {
		return SupplierFunding{}, err
	}
	id, err := NewInstallationID()
	if err != nil {
		return SupplierFunding{}, err
	}
	f.ID = id
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.SupplierFundings == nil {
		s.data.SupplierFundings = map[string]SupplierFunding{}
	}
	s.data.SupplierFundings[f.ID] = f
	if err := s.saveLocked(); err != nil {
		delete(s.data.SupplierFundings, f.ID)
		return SupplierFunding{}, err
	}
	return f, nil
}

func (s *FileStore) VoidSupplierFunding(_ context.Context, id, reason, actor string) (SupplierFunding, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f, ok := s.data.SupplierFundings[id]
	if !ok {
		return SupplierFunding{}, ErrSupplierFundingNotFound
	}
	if f.VoidedAt != nil {
		return SupplierFunding{}, ErrSupplierFundingVoided
	}
	before := f
	now := s.clock.Now()
	f.VoidedAt = &now
	f.VoidReason = truncateRunes(strings.TrimSpace(reason), maxIntegrationSwitchText)
	f.VoidActor = truncateRunes(strings.TrimSpace(actor), maxIntegrationSwitchText)
	s.data.SupplierFundings[id] = f
	if err := s.saveLocked(); err != nil {
		s.data.SupplierFundings[id] = before
		return SupplierFunding{}, err
	}
	return f, nil
}

func (s *FileStore) ListExchangeRateSeries(_ context.Context, from, to, instrument, bankCode string, since time.Time) ([]ExchangeRate, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows := []ExchangeRate{}
	for _, r := range s.data.ExchangeRates {
		if !strings.EqualFold(r.FromCode, from) || !strings.EqualFold(r.ToCode, to) || !strings.EqualFold(r.Instrument, instrument) ||
			!strings.EqualFold(strings.TrimSpace(r.BankCode), strings.TrimSpace(bankCode)) || r.EffectiveAt.Before(since) {
			continue
		}
		rows = append(rows, r)
	}
	sortExchangeRates(rows)
	if len(rows) > maxFundingSeriesRows {
		rows = rows[len(rows)-maxFundingSeriesRows:]
	}
	return rows, nil
}

// --- cache wrapper -----------------------------------------------------------

func (s *CachedInstallationStore) ListSupplierFundings(ctx context.Context) ([]SupplierFunding, error) {
	store, ok := s.store.(SupplierFundingStore)
	if !ok {
		return nil, errors.New("supplier funding store is unavailable")
	}
	return store.ListSupplierFundings(ctx)
}

func (s *CachedInstallationStore) CreateSupplierFunding(ctx context.Context, f SupplierFunding) (SupplierFunding, error) {
	store, ok := s.store.(SupplierFundingStore)
	if !ok {
		return SupplierFunding{}, errors.New("supplier funding store is unavailable")
	}
	return store.CreateSupplierFunding(ctx, f)
}

func (s *CachedInstallationStore) VoidSupplierFunding(ctx context.Context, id, reason, actor string) (SupplierFunding, error) {
	store, ok := s.store.(SupplierFundingStore)
	if !ok {
		return SupplierFunding{}, errors.New("supplier funding store is unavailable")
	}
	return store.VoidSupplierFunding(ctx, id, reason, actor)
}

func (s *CachedInstallationStore) ListExchangeRateSeries(ctx context.Context, from, to, instrument, bankCode string, since time.Time) ([]ExchangeRate, error) {
	store, ok := s.store.(ExchangeRateSeriesStore)
	if !ok {
		return nil, errExchangeRatesUnsupported
	}
	return store.ListExchangeRateSeries(ctx, from, to, instrument, bankCode, since)
}
