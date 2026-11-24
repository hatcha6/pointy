package control

import (
	"context"
	"errors"
	"math/big"
	"sort"
	"strings"
	"time"
)

// Segment offers: a discount the operator gives the «دفتر كروت» customers of
// one or more segments (the relay's segmentation, relay/customer_segments.go)
// to bring them back, to win a second purchase, to thank the best. Who may use
// an offer is fixed when it is made: the customers in those segments then are
// its recipients. A customer the offer brings back leaves "at risk" with that
// very order; the offer must not vanish under them, and what it did can be
// measured against exactly who was given it.
//
// An offer takes a percentage (capped by MaxDiscount) or a fixed amount off an
// order of at least MinOrder, for as long as it runs, UsesPerCustomer times
// per recipient and MaxRedemptions times in all. A use is an order that took
// it and is not called off: a cancelled, failed, expired or refunded order
// gives its use back. The store applies it when the order is placed, under
// the same lock that spends the customer's credit, so two orders at once
// cannot both take the last use.

// Offer kinds.
const (
	CustomerOfferPercent = "percent"
	CustomerOfferAmount  = "amount"
)

// Limits against a slipped digit.
var (
	maxCustomerOfferPercent = big.NewRat(90, 1)
	maxCustomerOfferAmount  = big.NewRat(500, 1)
)

const (
	maxCustomerOfferText     = 120
	maxCustomerOfferNotes    = 400
	maxCustomerOfferSegments = 20
	// MaxCustomerOfferRecipients bounds one offer's recipients.
	MaxCustomerOfferRecipients = 200_000
)

var (
	ErrCustomerOfferInvalid  = errors.New("customer offer invalid")
	ErrCustomerOfferNotFound = errors.New("customer offer not found")
	// ErrCustomerOfferUnavailable is an order naming an offer this customer
	// cannot use now: not theirs, not running, used up, or the order too
	// small for it.
	ErrCustomerOfferUnavailable = errors.New("customer offer unavailable")
)

// CustomerOffer is one discount for chosen segments.
type CustomerOffer struct {
	ID string `json:"id"`
	// Name is the operator's; Title and Description are what the app shows.
	Name        string `json:"name"`
	Title       string `json:"title"`
	Description string `json:"description,omitempty"`
	// Kind is percent, amount, tiered or bundle (customer_offer_terms.go).
	Kind string `json:"kind"`
	// Value is the percentage (percent) or the dinars (amount) off; for a
	// tiered offer its highest tier's, for a bundle GetPercent.
	Value string `json:"value"`
	// MaxDiscount caps a percentage's discount per order ("0.000": no cap);
	// MinOrder is the smallest order it applies to.
	MaxDiscount string `json:"max_discount"`
	MinOrder    string `json:"min_order"`
	// Tiers, in TierUnit, are a tiered offer's steps.
	Tiers    []CustomerOfferTier `json:"tiers,omitempty"`
	TierUnit string              `json:"tier_unit,omitempty"`
	// A bundle: buy BuyQuantity, get GetQuantity more at GetPercent off.
	BuyQuantity int    `json:"buy_quantity,omitempty"`
	GetQuantity int    `json:"get_quantity,omitempty"`
	GetPercent  string `json:"get_percent,omitempty"`
	// Scope is what it applies to; empty, everything.
	Scope CustomerOfferScope `json:"scope"`
	// Badge is what the app writes on what it covers ("خصم الشتاء"); empty,
	// the app words it from the terms.
	Badge string `json:"badge,omitempty"`
	// Audience is segments (Segments' customers when it was made) or
	// everyone (every customer, and visitors are shown it).
	Audience string `json:"audience"`
	// Segments are the segments it was made for; Recipients how many
	// customers were in them then and were given it.
	Segments   []string `json:"segments"`
	Recipients int      `json:"recipients"`
	// HoldoutPercent of those customers, drawn at random, were held out:
	// not given it, and watched all the same (Holdouts of them). What they
	// bought without it is what the offer is measured against: an offer whose
	// recipients buy no more than its holdout only gave margin away.
	HoldoutPercent int `json:"holdout_percent"`
	Holdouts       int `json:"holdouts"`
	// UsesPerCustomer is how many orders one recipient may take it on;
	// MaxRedemptions caps all of them together (0: no cap).
	UsesPerCustomer int        `json:"uses_per_customer"`
	MaxRedemptions  int        `json:"max_redemptions"`
	StartsAt        time.Time  `json:"starts_at"`
	EndsAt          *time.Time `json:"ends_at,omitempty"`
	Active          bool       `json:"active"`
	CreatedBy       string     `json:"created_by,omitempty"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

// CustomerOfferRecipient is one customer an offer was made for, and the
// segment they were in then. A holdout was not given it (see HoldoutPercent).
type CustomerOfferRecipient struct {
	CustomerID string `json:"customer_id"`
	Segment    string `json:"segment"`
	Holdout    bool   `json:"holdout,omitempty"`
}

// CustomerOfferUpdate changes an offer; nil leaves a field as it is. Who it
// is for and what it gives never change: a customer told "20% off" keeps it.
type CustomerOfferUpdate struct {
	Name        *string
	Title       *string
	Description *string
	Badge       *string
	EndsAt      **time.Time
	Active      *bool
}

// LiveAt reports whether the offer runs at now.
func (o CustomerOffer) LiveAt(now time.Time) bool {
	return o.Active && !now.Before(o.StartsAt) && (o.EndsAt == nil || now.Before(*o.EndsAt))
}

func roundDownToDirham(value *big.Rat) *big.Rat {
	scaled := new(big.Rat).Mul(value, big.NewRat(1000, 1))
	whole := new(big.Int).Quo(scaled.Num(), scaled.Denom())
	return new(big.Rat).SetFrac(whole, big.NewInt(1000))
}

// customerOfferUses reports whether an order in status holds a use of its
// offer: it can still be paid, or it gave its cards.
func customerOfferUses(status string) bool {
	switch status {
	case CustomerOrderAwaitingPayment, CustomerOrderPaid, CustomerOrderFulfilling, CustomerOrderDelivered:
		return true
	}
	return false
}

// customerOfferTerms checks that the offer may be used now by a recipient
// with used uses of their own, the offer having redeemed uses in all, and
// prices the order: its total less the discount, and the discount.
func customerOfferTerms(offer CustomerOffer, recipient bool, used, redeemed int, line CustomerOfferLine, now time.Time) (*big.Rat, *big.Rat, error) {
	if offer.Audience == CustomerOfferForEveryone {
		recipient = true
	}
	if !recipient || !offer.LiveAt(now) || used >= max(offer.UsesPerCustomer, 1) ||
		(offer.MaxRedemptions > 0 && redeemed >= offer.MaxRedemptions) {
		return nil, nil, ErrCustomerOfferUnavailable
	}
	discount := CustomerOfferDiscount(offer, line)
	if discount.Sign() <= 0 {
		return nil, nil, ErrCustomerOfferUnavailable
	}
	return new(big.Rat).Sub(line.Subtotal(), discount), discount, nil
}

// orderOfferLine is order as its offer prices it.
func orderOfferLine(order CustomerOrder) CustomerOfferLine {
	unit, _ := ParseWalletAmount(order.UnitPrice)
	return CustomerOfferLine{UnitPrice: unit, Quantity: order.Quantity, Category: order.Category, Brand: order.BrandKey, Item: order.ItemKey}
}

// withOfferApplied is order priced by its offer.
func withOfferApplied(order CustomerOrder, total, discount *big.Rat) CustomerOrder {
	order.Total = FormatWalletAmount(total)
	order.Discount = FormatWalletAmount(discount)
	return order
}

// normalizeCustomerOffer checks a new offer and fills in its defaults.
func normalizeCustomerOffer(offer CustomerOffer, now time.Time) (CustomerOffer, error) {
	invalid := func(why string) (CustomerOffer, error) {
		return CustomerOffer{}, errors.Join(ErrCustomerOfferInvalid, errors.New(why))
	}
	offer.Name = strings.TrimSpace(offer.Name)
	offer.Title = strings.TrimSpace(offer.Title)
	offer.Description = strings.TrimSpace(offer.Description)
	offer.CreatedBy = strings.TrimSpace(offer.CreatedBy)
	if offer.Name == "" || offer.Title == "" {
		return invalid("an offer needs a name and a title")
	}
	if len([]rune(offer.Name)) > maxCustomerOfferText || len([]rune(offer.Title)) > maxCustomerOfferText ||
		len([]rune(offer.Description)) > maxCustomerOfferNotes {
		return invalid("an offer's words are too long")
	}
	for _, field := range []*string{&offer.MaxDiscount, &offer.MinOrder} {
		if strings.TrimSpace(*field) == "" {
			*field = "0"
		}
		amount, err := ParseWalletAmount(*field)
		if err != nil || amount.Sign() < 0 {
			return invalid("max_discount and min_order are amounts")
		}
		*field = FormatWalletAmount(amount)
	}
	terms, err := normalizeCustomerOfferTerms(offer)
	if err != nil {
		return CustomerOffer{}, err
	}
	offer = terms
	if offer.Audience != CustomerOfferForEveryone {
		offer.Audience = CustomerOfferForSegments
	}
	segments := map[string]bool{}
	cleaned := []string{}
	for _, segment := range offer.Segments {
		segment = strings.TrimSpace(segment)
		if segment != "" && !segments[segment] {
			segments[segment] = true
			cleaned = append(cleaned, segment)
		}
	}
	switch {
	case offer.Audience == CustomerOfferForEveryone && (len(cleaned) > 0 || offer.HoldoutPercent != 0):
		return invalid("an offer for everyone names no segments and holds no one out")
	case offer.Audience == CustomerOfferForSegments && (len(cleaned) == 0 || len(cleaned) > maxCustomerOfferSegments):
		return invalid("an offer is for one segment or more")
	}
	sort.Strings(cleaned)
	offer.Segments = cleaned
	if offer.UsesPerCustomer <= 0 {
		offer.UsesPerCustomer = 1
	}
	if offer.UsesPerCustomer > 20 || offer.MaxRedemptions < 0 {
		return invalid("uses_per_customer is 1 to 20, max_redemptions 0 or more")
	}
	if offer.HoldoutPercent < 0 || offer.HoldoutPercent > 50 {
		return invalid("holdout_percent is 0 to 50")
	}
	now = now.UTC()
	if offer.StartsAt.IsZero() {
		offer.StartsAt = now
	}
	offer.StartsAt = offer.StartsAt.UTC()
	if offer.EndsAt != nil {
		ends := offer.EndsAt.UTC()
		if !ends.After(offer.StartsAt) {
			return invalid("an offer ends after it starts")
		}
		offer.EndsAt = &ends
	}
	if offer.ID == "" {
		id, err := NewInstallationID()
		if err != nil {
			return CustomerOffer{}, err
		}
		offer.ID = id
	}
	offer.Active = true
	offer.CreatedAt, offer.UpdatedAt = now, now
	return offer, nil
}

// applyCustomerOfferUpdate changes offer by update.
func applyCustomerOfferUpdate(offer CustomerOffer, update CustomerOfferUpdate, now time.Time) (CustomerOffer, error) {
	if update.Name != nil {
		offer.Name = *update.Name
	}
	if update.Title != nil {
		offer.Title = *update.Title
	}
	if update.Description != nil {
		offer.Description = *update.Description
	}
	if update.Badge != nil {
		offer.Badge = *update.Badge
	}
	if update.Active != nil {
		offer.Active = *update.Active
	}
	if update.EndsAt != nil {
		offer.EndsAt = *update.EndsAt
	}
	checked, err := normalizeCustomerOffer(CustomerOffer{
		ID: offer.ID, Name: offer.Name, Title: offer.Title, Description: offer.Description, Kind: offer.Kind,
		Value: offer.Value, MaxDiscount: offer.MaxDiscount, MinOrder: offer.MinOrder, Segments: offer.Segments,
		Tiers: offer.Tiers, TierUnit: offer.TierUnit, BuyQuantity: offer.BuyQuantity, GetQuantity: offer.GetQuantity,
		GetPercent: offer.GetPercent, Scope: offer.Scope, Badge: offer.Badge, Audience: offer.Audience,
		UsesPerCustomer: offer.UsesPerCustomer, MaxRedemptions: offer.MaxRedemptions,
		HoldoutPercent: offer.HoldoutPercent, StartsAt: offer.StartsAt, EndsAt: offer.EndsAt,
	}, now)
	if err != nil {
		return CustomerOffer{}, err
	}
	offer.Name, offer.Title, offer.Description, offer.EndsAt = checked.Name, checked.Title, checked.Description, checked.EndsAt
	offer.Badge = checked.Badge
	offer.UpdatedAt = now.UTC()
	return offer, nil
}

// CustomerOfferStore is an optional store capability (type-asserted).
type CustomerOfferStore interface {
	// CreateCustomerOffer stores offer for recipients (at least one).
	CreateCustomerOffer(ctx context.Context, offer CustomerOffer, recipients []CustomerOfferRecipient) (CustomerOffer, error)
	UpdateCustomerOffer(ctx context.Context, id string, update CustomerOfferUpdate) (CustomerOffer, error)
	GetCustomerOffer(ctx context.Context, id string) (CustomerOffer, error)
	// ListCustomerOffers is every offer, newest first.
	ListCustomerOffers(ctx context.Context) ([]CustomerOffer, error)
	// CustomerOfferRecipients is who offer id was made for.
	CustomerOfferRecipients(ctx context.Context, id string) ([]CustomerOfferRecipient, error)
	// CustomerOffersFor is the offers customerID can use at now, and how many
	// uses of each they have left.
	CustomerOffersFor(ctx context.Context, customerID string, now time.Time) ([]CustomerOfferFor, error)
	// PublicCustomerOffers is the offers for everyone running at now and not
	// used up: what a visitor who has not signed in is shown.
	PublicCustomerOffers(ctx context.Context, now time.Time) ([]CustomerOffer, error)
}

// CustomerOfferFor is an offer one customer can use, with their uses left.
type CustomerOfferFor struct {
	CustomerOffer
	UsesLeft int `json:"uses_left"`
}

var (
	_ CustomerOfferStore = (*FileStore)(nil)
	_ CustomerOfferStore = (*PostgresStore)(nil)
	_ CustomerOfferStore = (*CachedInstallationStore)(nil)
)

// offerUseCounts counts, among orders, the uses of offerID: the customer's
// own and everyone's.
func offerUseCounts(orders map[string]CustomerOrder, offerID, customerID string) (used, redeemed int) {
	for _, order := range orders {
		if order.OfferID != offerID || !customerOfferUses(order.Status) {
			continue
		}
		redeemed++
		if order.CustomerID == customerID {
			used++
		}
	}
	return used, redeemed
}

// --- file store ------------------------------------------------------------

type fileCustomerOfferData struct {
	Offers     map[string]CustomerOffer            `json:"offers,omitempty"`
	Recipients map[string][]CustomerOfferRecipient `json:"recipients,omitempty"`
}

func (s *FileStore) customerOffersLocked() *fileCustomerOfferData {
	if s.data.CustomerOffers == nil {
		s.data.CustomerOffers = &fileCustomerOfferData{}
	}
	data := s.data.CustomerOffers
	if data.Offers == nil {
		data.Offers = map[string]CustomerOffer{}
	}
	if data.Recipients == nil {
		data.Recipients = map[string][]CustomerOfferRecipient{}
	}
	return data
}

func (s *FileStore) isOfferRecipientLocked(offerID, customerID string) bool {
	for _, recipient := range s.customerOffersLocked().Recipients[offerID] {
		if recipient.CustomerID == customerID {
			return !recipient.Holdout
		}
	}
	return false
}

// applyCustomerOfferLocked prices order by its offer (the store's lock held).
func (s *FileStore) applyCustomerOfferLocked(order CustomerOrder, _ *big.Rat, now time.Time) (CustomerOrder, *big.Rat, error) {
	offer, ok := s.customerOffersLocked().Offers[order.OfferID]
	if !ok {
		return CustomerOrder{}, nil, ErrCustomerOfferUnavailable
	}
	used, redeemed := offerUseCounts(s.customerOrdersLocked().Orders, offer.ID, order.CustomerID)
	total, discount, err := customerOfferTerms(offer, s.isOfferRecipientLocked(offer.ID, order.CustomerID), used, redeemed, orderOfferLine(order), now)
	if err != nil {
		return CustomerOrder{}, nil, err
	}
	return withOfferApplied(order, total, discount), total, nil
}

func (s *FileStore) CreateCustomerOffer(_ context.Context, offer CustomerOffer, recipients []CustomerOfferRecipient) (CustomerOffer, error) {
	offer, err := normalizeCustomerOffer(offer, s.clock.Now())
	if err != nil {
		return CustomerOffer{}, err
	}
	recipients = uniqueOfferRecipients(recipients)
	if offer.Recipients, offer.Holdouts, err = countOfferRecipients(offer, recipients); err != nil {
		return CustomerOffer{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	data := s.customerOffersLocked()
	data.Offers[offer.ID] = offer
	data.Recipients[offer.ID] = recipients
	if err := s.saveLocked(); err != nil {
		delete(data.Offers, offer.ID)
		delete(data.Recipients, offer.ID)
		return CustomerOffer{}, err
	}
	return offer, nil
}

func (s *FileStore) UpdateCustomerOffer(_ context.Context, id string, update CustomerOfferUpdate) (CustomerOffer, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data := s.customerOffersLocked()
	offer, ok := data.Offers[id]
	if !ok {
		return CustomerOffer{}, ErrCustomerOfferNotFound
	}
	updated, err := applyCustomerOfferUpdate(offer, update, s.clock.Now())
	if err != nil {
		return CustomerOffer{}, err
	}
	data.Offers[id] = updated
	if err := s.saveLocked(); err != nil {
		data.Offers[id] = offer
		return CustomerOffer{}, err
	}
	return updated, nil
}

func (s *FileStore) GetCustomerOffer(_ context.Context, id string) (CustomerOffer, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	offer, ok := s.customerOffersLocked().Offers[id]
	if !ok {
		return CustomerOffer{}, ErrCustomerOfferNotFound
	}
	return offer, nil
}

func (s *FileStore) ListCustomerOffers(_ context.Context) ([]CustomerOffer, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	offers := []CustomerOffer{}
	for _, offer := range s.customerOffersLocked().Offers {
		offers = append(offers, offer)
	}
	sortCustomerOffers(offers)
	return offers, nil
}

func (s *FileStore) CustomerOfferRecipients(_ context.Context, id string) ([]CustomerOfferRecipient, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data := s.customerOffersLocked()
	if _, ok := data.Offers[id]; !ok {
		return nil, ErrCustomerOfferNotFound
	}
	return append([]CustomerOfferRecipient{}, data.Recipients[id]...), nil
}

func (s *FileStore) PublicCustomerOffers(_ context.Context, now time.Time) ([]CustomerOffer, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	orders := s.customerOrdersLocked().Orders
	out := []CustomerOffer{}
	for _, offer := range s.customerOffersLocked().Offers {
		if offer.Audience != CustomerOfferForEveryone || !offer.LiveAt(now) {
			continue
		}
		if _, redeemed := offerUseCounts(orders, offer.ID, ""); offer.MaxRedemptions == 0 || redeemed < offer.MaxRedemptions {
			out = append(out, offer)
		}
	}
	sortCustomerOffers(out)
	return out, nil
}

func (s *FileStore) CustomerOffersFor(_ context.Context, customerID string, now time.Time) ([]CustomerOfferFor, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data := s.customerOffersLocked()
	orders := s.customerOrdersLocked().Orders
	out := []CustomerOfferFor{}
	for _, offer := range data.Offers {
		if !offer.LiveAt(now) || (offer.Audience != CustomerOfferForEveryone && !s.isOfferRecipientLocked(offer.ID, customerID)) {
			continue
		}
		used, redeemed := offerUseCounts(orders, offer.ID, customerID)
		if left := offerUsesLeft(offer, used, redeemed); left > 0 {
			out = append(out, CustomerOfferFor{CustomerOffer: offer, UsesLeft: left})
		}
	}
	sortCustomerOffersFor(out)
	return out, nil
}

// offerUsesLeft is how many more orders a recipient may take offer on.
func offerUsesLeft(offer CustomerOffer, used, redeemed int) int {
	left := max(offer.UsesPerCustomer, 1) - used
	if offer.MaxRedemptions > 0 {
		left = min(left, offer.MaxRedemptions-redeemed)
	}
	return max(left, 0)
}

// countOfferRecipients counts those given an offer and those held out; an
// offer is given to one customer at least.
func countOfferRecipients(offer CustomerOffer, recipients []CustomerOfferRecipient) (given, held int, err error) {
	if offer.Audience == CustomerOfferForEveryone {
		if len(recipients) > 0 {
			return 0, 0, errors.Join(ErrCustomerOfferInvalid, errors.New("an offer for everyone lists no recipients"))
		}
		return 0, 0, nil
	}
	for _, recipient := range recipients {
		if recipient.Holdout {
			held++
		} else {
			given++
		}
	}
	if given == 0 || len(recipients) > MaxCustomerOfferRecipients {
		return 0, 0, errors.Join(ErrCustomerOfferInvalid, errors.New("an offer is given to one customer or more"))
	}
	return given, held, nil
}

func uniqueOfferRecipients(recipients []CustomerOfferRecipient) []CustomerOfferRecipient {
	seen := map[string]bool{}
	out := make([]CustomerOfferRecipient, 0, len(recipients))
	for _, recipient := range recipients {
		recipient.CustomerID = strings.TrimSpace(recipient.CustomerID)
		if recipient.CustomerID == "" || seen[recipient.CustomerID] {
			continue
		}
		seen[recipient.CustomerID] = true
		out = append(out, recipient)
	}
	return out
}

func sortCustomerOffers(offers []CustomerOffer) {
	sort.Slice(offers, func(i, j int) bool {
		if !offers[i].CreatedAt.Equal(offers[j].CreatedAt) {
			return offers[i].CreatedAt.After(offers[j].CreatedAt)
		}
		return offers[i].ID > offers[j].ID
	})
}

// sortCustomerOffersFor puts the offer ending soonest first: the one to use
// before it goes.
func sortCustomerOffersFor(offers []CustomerOfferFor) {
	sort.Slice(offers, func(i, j int) bool {
		a, b := offers[i].EndsAt, offers[j].EndsAt
		switch {
		case a != nil && b != nil && !a.Equal(*b):
			return a.Before(*b)
		case a != nil && b == nil:
			return true
		case a == nil && b != nil:
			return false
		}
		return offers[i].ID < offers[j].ID
	})
}

// --- cache wrapper -----------------------------------------------------------

func (s *CachedInstallationStore) customerOfferStore() (CustomerOfferStore, error) {
	store, ok := s.store.(CustomerOfferStore)
	if !ok {
		return nil, errCustomersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) CreateCustomerOffer(ctx context.Context, offer CustomerOffer, recipients []CustomerOfferRecipient) (CustomerOffer, error) {
	store, err := s.customerOfferStore()
	if err != nil {
		return CustomerOffer{}, err
	}
	return store.CreateCustomerOffer(ctx, offer, recipients)
}

func (s *CachedInstallationStore) UpdateCustomerOffer(ctx context.Context, id string, update CustomerOfferUpdate) (CustomerOffer, error) {
	store, err := s.customerOfferStore()
	if err != nil {
		return CustomerOffer{}, err
	}
	return store.UpdateCustomerOffer(ctx, id, update)
}

func (s *CachedInstallationStore) GetCustomerOffer(ctx context.Context, id string) (CustomerOffer, error) {
	store, err := s.customerOfferStore()
	if err != nil {
		return CustomerOffer{}, err
	}
	return store.GetCustomerOffer(ctx, id)
}

func (s *CachedInstallationStore) ListCustomerOffers(ctx context.Context) ([]CustomerOffer, error) {
	store, err := s.customerOfferStore()
	if err != nil {
		return nil, err
	}
	return store.ListCustomerOffers(ctx)
}

func (s *CachedInstallationStore) CustomerOfferRecipients(ctx context.Context, id string) ([]CustomerOfferRecipient, error) {
	store, err := s.customerOfferStore()
	if err != nil {
		return nil, err
	}
	return store.CustomerOfferRecipients(ctx, id)
}

func (s *CachedInstallationStore) PublicCustomerOffers(ctx context.Context, now time.Time) ([]CustomerOffer, error) {
	store, err := s.customerOfferStore()
	if err != nil {
		return nil, err
	}
	return store.PublicCustomerOffers(ctx, now)
}

func (s *CachedInstallationStore) CustomerOffersFor(ctx context.Context, customerID string, now time.Time) ([]CustomerOfferFor, error) {
	store, err := s.customerOfferStore()
	if err != nil {
		return nil, err
	}
	return store.CustomerOffersFor(ctx, customerID, now)
}
