package control

import (
	"context"
	"errors"
	"math/big"
	"sort"
	"strings"
	"time"
	"unicode"
)

// What the operator console sees and does about «دفتر كروت» customers: who
// they are and what they bought, their credit, their devices and the
// notifications sent to them; stopping an account, adjusting its credit.

// CustomerSummary is a customer as the console lists them.
type CustomerSummary struct {
	Customer
	// Orders counts every order; Delivered those that gave cards. Spent sums
	// the delivered ones paid with real money (not test, not review).
	Orders      int        `json:"orders"`
	Delivered   int        `json:"delivered"`
	Spent       string     `json:"spent"`
	LastOrderAt *time.Time `json:"last_order_at,omitempty"`
	Credit      string     `json:"credit"`
	// Devices are the signed-in sessions; PushDevices those that can be sent
	// a notification. Platforms names them ("ios,android").
	Devices     int        `json:"devices"`
	PushDevices int        `json:"push_devices"`
	Platforms   string     `json:"platforms,omitempty"`
	LastSeenAt  *time.Time `json:"last_seen_at,omitempty"`
}

// CustomerListFilter narrows the console's list.
type CustomerListFilter struct {
	// Query matches a phone (as typed: 091…, 21891…) or a customer id.
	Query string
	// Segment: "" (live accounts), "buyers", "blocked", "deleted", "all".
	Segment string
	Limit   int
	Offset  int
}

// CustomerStats is the console's headline about the app's customers.
type CustomerStats struct {
	Customers   int       `json:"customers"`
	New7d       int       `json:"new_7d"`
	Active30d   int       `json:"active_30d"`
	Buyers      int       `json:"buyers"`
	Blocked     int       `json:"blocked"`
	WithPush    int       `json:"with_push"`
	Spent       string    `json:"spent"`
	OpenOrders  int       `json:"open_orders"`
	Orders30d   int       `json:"orders_30d"`
	CreditOwed  string    `json:"credit_owed"`
	GeneratedAt time.Time `json:"generated_at"`
}

// CustomerCreditChange is an operator's adjustment of a customer's credit.
type CustomerCreditChange struct {
	CustomerID string
	// Amount is signed dinars, at most three places: positive gives credit.
	Amount string
	Note   string
	Actor  string
	// Reference makes the adjustment idempotent (the console's request key).
	Reference string
}

// CustomerNotification is one notification an operator sent, as logged.
type CustomerNotification struct {
	ID string `json:"id"`
	// Audience is "all", a channel ("ios", "play", "apk") or "customer".
	Audience   string `json:"audience"`
	CustomerID string `json:"customer_id,omitempty"`
	Title      string `json:"title"`
	Body       string `json:"body"`
	Link       string `json:"link,omitempty"`
	Campaign   string `json:"campaign,omitempty"`
	SentBy     string `json:"sent_by,omitempty"`
	// Devices is how many phones a customer notification was addressed to
	// (zero for a topic); Sent and Failed what Firebase answered.
	Devices   int       `json:"devices"`
	Sent      int       `json:"sent"`
	Failed    int       `json:"failed"`
	Error     string    `json:"error,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// CustomerNotificationFilter narrows the notification log.
type CustomerNotificationFilter struct {
	CustomerID string
	Limit      int
}

var (
	ErrCustomerCreditInvalid      = errors.New("customer credit adjustment invalid")
	ErrCustomerCreditInsufficient = errors.New("customer credit would go below zero")
)

// CustomerAdminStore is the console's side of the customers.
type CustomerAdminStore interface {
	ListCustomers(ctx context.Context, filter CustomerListFilter) ([]CustomerSummary, int, error)
	CustomerSummaryByID(ctx context.Context, id string) (CustomerSummary, error)
	CustomerStats(ctx context.Context) (CustomerStats, error)
	// SetCustomerBlocked stops (or restarts) an account. Stopping signs it
	// out everywhere; its phone cannot sign in until restarted.
	SetCustomerBlocked(ctx context.Context, id string, blocked bool, reason string) (Customer, error)
	// AdjustCustomerCredit records an operator's grant or charge; a repeated
	// reference returns the first entry with created=false.
	AdjustCustomerCredit(ctx context.Context, change CustomerCreditChange) (CustomerCreditEntry, string, bool, error)
	// SetCustomerPushToken stores the device's notification token on its
	// session ("" forgets it); the same token leaves any other session.
	SetCustomerPushToken(ctx context.Context, customerID, sessionID, token string) error
	// ForgetCustomerPushToken drops a token Firebase no longer knows.
	ForgetCustomerPushToken(ctx context.Context, token string) error
	RecordCustomerNotification(ctx context.Context, notification CustomerNotification) (CustomerNotification, error)
	ListCustomerNotifications(ctx context.Context, filter CustomerNotificationFilter) ([]CustomerNotification, error)
}

var (
	_ CustomerAdminStore = (*FileStore)(nil)
	_ CustomerAdminStore = (*CachedInstallationStore)(nil)
)

// customerPhoneQuery reads a typed phone the way it is stored: digits only,
// without the leading zero of a national number ("0912…" finds "218912…").
func customerPhoneQuery(query string) string {
	digits := strings.Map(func(r rune) rune {
		if unicode.IsDigit(r) {
			return r
		}
		return -1
	}, query)
	return strings.TrimLeft(digits, "0")
}

// customerAdjustment checks an operator's change and turns it into an entry.
func customerAdjustment(change CustomerCreditChange, balance *big.Rat, now time.Time) (CustomerCreditEntry, error) {
	amount, err := ParseWalletAmount(change.Amount)
	if err != nil || amount.Sign() == 0 || strings.TrimSpace(change.Note) == "" ||
		strings.TrimSpace(change.Reference) == "" {
		return CustomerCreditEntry{}, ErrCustomerCreditInvalid
	}
	if new(big.Rat).Add(balance, amount).Sign() < 0 {
		return CustomerCreditEntry{}, ErrCustomerCreditInsufficient
	}
	return CustomerCreditEntry{
		CustomerID: change.CustomerID,
		Kind:       CustomerCreditAdjustment,
		Amount:     FormatWalletAmount(amount),
		Note:       truncateRunes(strings.TrimSpace(change.Note), 300),
		Actor:      truncateRunes(strings.TrimSpace(change.Actor), 120),
		Reference:  truncateRunes(strings.TrimSpace(change.Reference), 128),
		CreatedAt:  now,
	}, nil
}

func normalizeCustomerNotification(n CustomerNotification) (CustomerNotification, error) {
	n.Title = truncateRunes(strings.TrimSpace(n.Title), 120)
	n.Body = truncateRunes(strings.TrimSpace(n.Body), 500)
	n.Link = truncateRunes(strings.TrimSpace(n.Link), 500)
	n.Campaign = truncateRunes(strings.TrimSpace(n.Campaign), 80)
	n.SentBy = truncateRunes(strings.TrimSpace(n.SentBy), 120)
	n.Error = truncateRunes(strings.TrimSpace(n.Error), 500)
	if n.Title == "" || n.Body == "" || n.Audience == "" {
		return CustomerNotification{}, errors.New("a notification needs an audience, a title and words")
	}
	if n.ID == "" {
		id, err := NewInstallationID()
		if err != nil {
			return CustomerNotification{}, err
		}
		n.ID = id
	}
	return n, nil
}

// --- file store ------------------------------------------------------------

func (s *FileStore) customerSummaryLocked(customer Customer, now time.Time) CustomerSummary {
	summary := CustomerSummary{Customer: customer, Spent: "0.000"}
	spent := new(big.Rat)
	if orders := s.data.CustomerOrders; orders != nil {
		for _, order := range orders.Orders {
			if order.CustomerID != customer.ID {
				continue
			}
			summary.Orders++
			created := order.CreatedAt
			if summary.LastOrderAt == nil || created.After(*summary.LastOrderAt) {
				summary.LastOrderAt = &created
			}
			if order.Status == CustomerOrderDelivered {
				summary.Delivered++
				if !order.TestMode && !order.Review {
					if total, ok := new(big.Rat).SetString(order.Total); ok {
						spent.Add(spent, total)
					}
				}
			}
		}
	}
	summary.Spent = FormatWalletAmount(spent)
	summary.Credit = FormatWalletAmount(sumCustomerCredit(s.customerCreditLocked(customer.ID)))
	platforms := map[string]bool{}
	if s.data.Customers != nil {
		for _, session := range s.data.Customers.Sessions {
			if session.CustomerID != customer.ID || !now.Before(session.ExpiresAt) {
				continue
			}
			summary.Devices++
			if session.PushToken != "" {
				summary.PushDevices++
			}
			if session.Platform != "" {
				platforms[session.Platform] = true
			}
			seen := session.LastSeenAt
			if summary.LastSeenAt == nil || seen.After(*summary.LastSeenAt) {
				summary.LastSeenAt = &seen
			}
		}
	}
	names := make([]string, 0, len(platforms))
	for name := range platforms {
		names = append(names, name)
	}
	sort.Strings(names)
	summary.Platforms = strings.Join(names, ",")
	return summary
}

func customerInSegment(summary CustomerSummary, segment string) bool {
	switch segment {
	case "all":
		return true
	case "buyers":
		return summary.DeletedAt == nil && summary.Delivered > 0
	case "blocked":
		return summary.BlockedAt != nil
	case "deleted":
		return summary.DeletedAt != nil
	}
	return summary.DeletedAt == nil
}

func (s *FileStore) ListCustomers(_ context.Context, filter CustomerListFilter) ([]CustomerSummary, int, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	list := []CustomerSummary{}
	if s.data.Customers == nil {
		return list, 0, nil
	}
	now := s.clock.Now().UTC()
	query := strings.TrimSpace(filter.Query)
	phone := customerPhoneQuery(query)
	for _, customer := range s.data.Customers.Customers {
		if query != "" && customer.ID != query && (phone == "" || !strings.Contains(customer.Phone, phone)) {
			continue
		}
		summary := s.customerSummaryLocked(customer, now)
		if customerInSegment(summary, filter.Segment) {
			list = append(list, summary)
		}
	}
	sort.Slice(list, func(i, j int) bool {
		if !list[i].LastSignInAt.Equal(list[j].LastSignInAt) {
			return list[i].LastSignInAt.After(list[j].LastSignInAt)
		}
		return list[i].ID < list[j].ID
	})
	total := len(list)
	if filter.Offset > 0 {
		list = list[min(filter.Offset, len(list)):]
	}
	if filter.Limit > 0 && len(list) > filter.Limit {
		list = list[:filter.Limit]
	}
	return list, total, nil
}

func (s *FileStore) CustomerSummaryByID(_ context.Context, id string) (CustomerSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.Customers == nil {
		return CustomerSummary{}, ErrCustomerNotFound
	}
	customer, ok := s.data.Customers.Customers[id]
	if !ok {
		return CustomerSummary{}, ErrCustomerNotFound
	}
	return s.customerSummaryLocked(customer, s.clock.Now().UTC()), nil
}

func (s *FileStore) CustomerStats(_ context.Context) (CustomerStats, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	now := s.clock.Now().UTC()
	stats := CustomerStats{Spent: "0.000", CreditOwed: "0.000", GeneratedAt: now}
	if s.data.Customers == nil {
		return stats, nil
	}
	spent, owed := new(big.Rat), new(big.Rat)
	for _, customer := range s.data.Customers.Customers {
		if customer.DeletedAt != nil {
			continue
		}
		summary := s.customerSummaryLocked(customer, now)
		stats.Customers++
		if now.Sub(customer.CreatedAt) <= 7*24*time.Hour {
			stats.New7d++
		}
		last := customer.LastSignInAt
		if summary.LastSeenAt != nil && summary.LastSeenAt.After(last) {
			last = *summary.LastSeenAt
		}
		if now.Sub(last) <= 30*24*time.Hour {
			stats.Active30d++
		}
		if summary.Delivered > 0 {
			stats.Buyers++
		}
		if customer.BlockedAt != nil {
			stats.Blocked++
		}
		if summary.PushDevices > 0 {
			stats.WithPush++
		}
		if value, ok := new(big.Rat).SetString(summary.Spent); ok {
			spent.Add(spent, value)
		}
		if value, ok := new(big.Rat).SetString(summary.Credit); ok {
			owed.Add(owed, value)
		}
	}
	if orders := s.data.CustomerOrders; orders != nil {
		for _, order := range orders.Orders {
			if CustomerOrderOpen(order.Status) {
				stats.OpenOrders++
			}
			if now.Sub(order.CreatedAt) <= 30*24*time.Hour {
				stats.Orders30d++
			}
		}
	}
	stats.Spent = FormatWalletAmount(spent)
	stats.CreditOwed = FormatWalletAmount(owed)
	return stats, nil
}

func (s *FileStore) SetCustomerBlocked(_ context.Context, id string, blocked bool, reason string) (Customer, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	customer, ok := c.Customers[id]
	if !ok || customer.DeletedAt != nil {
		return Customer{}, ErrCustomerNotFound
	}
	if blocked {
		now := s.clock.Now().UTC()
		if customer.BlockedAt == nil {
			customer.BlockedAt = &now
		}
		customer.BlockedReason = truncateRunes(strings.TrimSpace(reason), 300)
		for sessionID, session := range c.Sessions {
			if session.CustomerID == id {
				delete(c.Sessions, sessionID)
			}
		}
	} else {
		customer.BlockedAt = nil
		customer.BlockedReason = ""
	}
	c.Customers[id] = customer
	return customer, s.saveLocked()
}

func (s *FileStore) AdjustCustomerCredit(_ context.Context, change CustomerCreditChange) (CustomerCreditEntry, string, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	customer, ok := c.Customers[change.CustomerID]
	if !ok || customer.DeletedAt != nil {
		return CustomerCreditEntry{}, "", false, ErrCustomerNotFound
	}
	data := s.customerOrdersLocked()
	reference := strings.TrimSpace(change.Reference)
	for _, existing := range data.Credits {
		if reference != "" && existing.CustomerID == change.CustomerID && existing.Reference == reference {
			return existing, FormatWalletAmount(sumCustomerCredit(s.customerCreditLocked(change.CustomerID))), false, nil
		}
	}
	balance := sumCustomerCredit(s.customerCreditLocked(change.CustomerID))
	entry, err := customerAdjustment(change, balance, s.clock.Now().UTC())
	if err != nil {
		return CustomerCreditEntry{}, "", false, err
	}
	if err := s.appendCustomerCreditLocked(&entry); err != nil {
		return CustomerCreditEntry{}, "", false, err
	}
	if err := s.saveLocked(); err != nil {
		return CustomerCreditEntry{}, "", false, err
	}
	amount, _ := new(big.Rat).SetString(entry.Amount)
	return entry, FormatWalletAmount(balance.Add(balance, amount)), true, nil
}

func (s *FileStore) SetCustomerPushToken(_ context.Context, customerID, sessionID, token string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	session, ok := c.Sessions[sessionID]
	if !ok || session.CustomerID != customerID {
		return ErrCustomerSessionNotFound
	}
	token = strings.TrimSpace(token)
	if token != "" {
		for id, other := range c.Sessions {
			if id != sessionID && other.PushToken == token {
				other.PushToken = ""
				c.Sessions[id] = other
			}
		}
	}
	session.PushToken = token
	c.Sessions[sessionID] = session
	return s.saveLocked()
}

func (s *FileStore) ForgetCustomerPushToken(_ context.Context, token string) error {
	if token == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	changed := false
	for id, session := range c.Sessions {
		if session.PushToken == token {
			session.PushToken = ""
			c.Sessions[id] = session
			changed = true
		}
	}
	if !changed {
		return nil
	}
	return s.saveLocked()
}

func (s *FileStore) RecordCustomerNotification(_ context.Context, notification CustomerNotification) (CustomerNotification, error) {
	notification, err := normalizeCustomerNotification(notification)
	if err != nil {
		return CustomerNotification{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	if notification.CreatedAt.IsZero() {
		notification.CreatedAt = s.clock.Now().UTC()
	}
	c.Notifications = append(c.Notifications, notification)
	return notification, s.saveLocked()
}

func (s *FileStore) ListCustomerNotifications(_ context.Context, filter CustomerNotificationFilter) ([]CustomerNotification, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	list := []CustomerNotification{}
	if s.data.Customers == nil {
		return list, nil
	}
	for _, n := range s.data.Customers.Notifications {
		if filter.CustomerID != "" && n.CustomerID != filter.CustomerID {
			continue
		}
		list = append(list, n)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].CreatedAt.After(list[j].CreatedAt) })
	if filter.Limit > 0 && len(list) > filter.Limit {
		list = list[:filter.Limit]
	}
	return list, nil
}

// --- cached store forwarding ---------------------------------------------

func (s *CachedInstallationStore) customerAdminStore() (CustomerAdminStore, error) {
	store, ok := s.store.(CustomerAdminStore)
	if !ok {
		return nil, errCustomersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) ListCustomers(ctx context.Context, filter CustomerListFilter) ([]CustomerSummary, int, error) {
	store, err := s.customerAdminStore()
	if err != nil {
		return nil, 0, err
	}
	return store.ListCustomers(ctx, filter)
}

func (s *CachedInstallationStore) CustomerSummaryByID(ctx context.Context, id string) (CustomerSummary, error) {
	store, err := s.customerAdminStore()
	if err != nil {
		return CustomerSummary{}, err
	}
	return store.CustomerSummaryByID(ctx, id)
}

func (s *CachedInstallationStore) CustomerStats(ctx context.Context) (CustomerStats, error) {
	store, err := s.customerAdminStore()
	if err != nil {
		return CustomerStats{}, err
	}
	return store.CustomerStats(ctx)
}

func (s *CachedInstallationStore) SetCustomerBlocked(ctx context.Context, id string, blocked bool, reason string) (Customer, error) {
	store, err := s.customerAdminStore()
	if err != nil {
		return Customer{}, err
	}
	return store.SetCustomerBlocked(ctx, id, blocked, reason)
}

func (s *CachedInstallationStore) AdjustCustomerCredit(ctx context.Context, change CustomerCreditChange) (CustomerCreditEntry, string, bool, error) {
	store, err := s.customerAdminStore()
	if err != nil {
		return CustomerCreditEntry{}, "", false, err
	}
	return store.AdjustCustomerCredit(ctx, change)
}

func (s *CachedInstallationStore) SetCustomerPushToken(ctx context.Context, customerID, sessionID, token string) error {
	store, err := s.customerAdminStore()
	if err != nil {
		return err
	}
	return store.SetCustomerPushToken(ctx, customerID, sessionID, token)
}

func (s *CachedInstallationStore) ForgetCustomerPushToken(ctx context.Context, token string) error {
	store, err := s.customerAdminStore()
	if err != nil {
		return err
	}
	return store.ForgetCustomerPushToken(ctx, token)
}

func (s *CachedInstallationStore) RecordCustomerNotification(ctx context.Context, notification CustomerNotification) (CustomerNotification, error) {
	store, err := s.customerAdminStore()
	if err != nil {
		return CustomerNotification{}, err
	}
	return store.RecordCustomerNotification(ctx, notification)
}

func (s *CachedInstallationStore) ListCustomerNotifications(ctx context.Context, filter CustomerNotificationFilter) ([]CustomerNotification, error) {
	store, err := s.customerAdminStore()
	if err != nil {
		return nil, err
	}
	return store.ListCustomerNotifications(ctx, filter)
}
