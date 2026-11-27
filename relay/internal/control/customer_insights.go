package control

import (
	"context"
	"sort"
	"time"
)

// What the relay's customer segmentation (relay/customer_segments.go) reads:
// every customer, and every order that gave cards for real money. Both are
// small rows, read whole: the segmentation looks at each customer's whole
// history (their own rhythm of buying), not at a page of it.

// CustomerFact is one customer as the segmentation sees them.
type CustomerFact struct {
	ID        string     `json:"id"`
	CreatedAt time.Time  `json:"created_at"`
	DeletedAt *time.Time `json:"deleted_at,omitempty"`
	BlockedAt *time.Time `json:"blocked_at,omitempty"`
	// PushDevices counts the live sessions that take notifications.
	PushDevices int `json:"push_devices"`
}

// CustomerOrderFact is one delivered order (not test, not review), with the
// supplier purchase behind it for its cost.
type CustomerOrderFact struct {
	ID          string    `json:"id"`
	CustomerID  string    `json:"customer_id"`
	CompletedAt time.Time `json:"completed_at"`
	Channel     string    `json:"channel"`
	BrandKey    string    `json:"brand"`
	Total       string    `json:"total"`
	Discount    string    `json:"discount"`
	OfferID     string    `json:"offer_id,omitempty"`
	// SupplierCost and SupplierCurrency are what the purchase cost, and
	// PurchaseAt when it was bought (for the dollar rate then). Empty when
	// the order has no purchase, or its cost is not known.
	SupplierCost     string    `json:"supplier_cost,omitempty"`
	SupplierCurrency string    `json:"supplier_currency,omitempty"`
	PurchaseAt       time.Time `json:"purchase_at"`
}

// CustomerInsightStore is an optional store capability (type-asserted).
type CustomerInsightStore interface {
	CustomerFacts(ctx context.Context) ([]CustomerFact, error)
	// CustomerOrderFacts is every delivered real order, oldest first.
	CustomerOrderFacts(ctx context.Context) ([]CustomerOrderFact, error)
	// CustomerPushTokens is each listed customer's live push tokens.
	CustomerPushTokens(ctx context.Context, customerIDs []string) (map[string][]string, error)
}

var (
	_ CustomerInsightStore = (*FileStore)(nil)
	_ CustomerInsightStore = (*PostgresStore)(nil)
	_ CustomerInsightStore = (*CachedInstallationStore)(nil)
)

func sortOrderFacts(facts []CustomerOrderFact) {
	sort.Slice(facts, func(i, j int) bool {
		if !facts[i].CompletedAt.Equal(facts[j].CompletedAt) {
			return facts[i].CompletedAt.Before(facts[j].CompletedAt)
		}
		return facts[i].ID < facts[j].ID
	})
}

// --- file store ------------------------------------------------------------

func (s *FileStore) CustomerFacts(_ context.Context) ([]CustomerFact, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	facts := []CustomerFact{}
	if s.data.Customers == nil {
		return facts, nil
	}
	now := s.clock.Now().UTC()
	push := map[string]int{}
	for _, session := range s.data.Customers.Sessions {
		if session.PushToken != "" && now.Before(session.ExpiresAt) {
			push[session.CustomerID]++
		}
	}
	for _, customer := range s.data.Customers.Customers {
		facts = append(facts, CustomerFact{
			ID: customer.ID, CreatedAt: customer.CreatedAt, DeletedAt: customer.DeletedAt,
			BlockedAt: customer.BlockedAt, PushDevices: push[customer.ID],
		})
	}
	sort.Slice(facts, func(i, j int) bool { return facts[i].ID < facts[j].ID })
	return facts, nil
}

func (s *FileStore) CustomerOrderFacts(_ context.Context) ([]CustomerOrderFact, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	facts := []CustomerOrderFact{}
	if s.data.CustomerOrders == nil {
		return facts, nil
	}
	for _, order := range s.data.CustomerOrders.Orders {
		if order.Status != CustomerOrderDelivered || order.TestMode || order.Review || order.CompletedAt == nil {
			continue
		}
		fact := CustomerOrderFact{
			ID: order.ID, CustomerID: order.CustomerID, CompletedAt: order.CompletedAt.UTC(), Channel: order.Channel,
			BrandKey: order.BrandKey, Total: CustomerOrderEarned(order),
			Discount: NormalizeWalletAmount(orDefault(order.Discount, "0")), OfferID: order.OfferID,
		}
		if purchase, ok := s.data.VoucherPurchases[order.PurchaseID]; ok && order.PurchaseID != "" {
			fact.SupplierCost, fact.SupplierCurrency = purchase.SupplierCost, purchase.SupplierCurrency
			fact.PurchaseAt = purchase.CreatedAt
			if purchase.CompletedAt != nil {
				fact.PurchaseAt = *purchase.CompletedAt
			}
		}
		facts = append(facts, fact)
	}
	sortOrderFacts(facts)
	return facts, nil
}

func (s *FileStore) CustomerPushTokens(_ context.Context, customerIDs []string) (map[string][]string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	tokens := map[string][]string{}
	if s.data.Customers == nil {
		return tokens, nil
	}
	wanted := make(map[string]bool, len(customerIDs))
	for _, id := range customerIDs {
		wanted[id] = true
	}
	now := s.clock.Now().UTC()
	for _, session := range s.data.Customers.Sessions {
		if wanted[session.CustomerID] && session.PushToken != "" && now.Before(session.ExpiresAt) {
			tokens[session.CustomerID] = append(tokens[session.CustomerID], session.PushToken)
		}
	}
	for id := range tokens {
		sort.Strings(tokens[id])
	}
	return tokens, nil
}

func orDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

// --- cache wrapper -----------------------------------------------------------

func (s *CachedInstallationStore) customerInsightStore() (CustomerInsightStore, error) {
	store, ok := s.store.(CustomerInsightStore)
	if !ok {
		return nil, errCustomersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) CustomerFacts(ctx context.Context) ([]CustomerFact, error) {
	store, err := s.customerInsightStore()
	if err != nil {
		return nil, err
	}
	return store.CustomerFacts(ctx)
}

func (s *CachedInstallationStore) CustomerOrderFacts(ctx context.Context) ([]CustomerOrderFact, error) {
	store, err := s.customerInsightStore()
	if err != nil {
		return nil, err
	}
	return store.CustomerOrderFacts(ctx)
}

func (s *CachedInstallationStore) CustomerPushTokens(ctx context.Context, customerIDs []string) (map[string][]string, error) {
	store, err := s.customerInsightStore()
	if err != nil {
		return nil, err
	}
	return store.CustomerPushTokens(ctx, customerIDs)
}
