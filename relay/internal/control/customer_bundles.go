package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Bundles of «دفتر كروت»: two or more cards sold together for less (a PUBG
// top-up with phone credit for the buyer's own network). The company fixes
// every amount: a tier names each part, a part is one card or several of the
// same value the buyer picks one of (one per network), and the tier's saving
// comes off the cards' own shelf prices added up. There is no switch: no
// bundle stored is no bundle in the catalog, and composing one in the console
// is what turns them on.

// CustomerBundle is one bundle as the operator composed it.
type CustomerBundle struct {
	Key     string `json:"key"`
	Name    string `json:"name"`
	Tagline string `json:"tagline"`
	Rank    int    `json:"rank"`
	// Art is the bundle's artwork by choice: the brand keys picked in the
	// parts the buyer picks in, joined by commas ("libyana"), to an uploaded
	// image ("sha256:…"). "" is the one shown when none fits.
	Art       map[string]string    `json:"art"`
	Tiers     []CustomerBundleTier `json:"tiers"`
	Actor     string               `json:"actor,omitempty"`
	UpdatedAt time.Time            `json:"updated_at"`
}

// CustomerBundleTier is one size of a bundle.
type CustomerBundleTier struct {
	// Key is what an order names as its item: unique across every bundle.
	Key string `json:"key"`
	// Saving is taken off the cards' prices added up, in dinars.
	Saving string `json:"saving"`
	// Parts are the item keys of each part: one for a part the company
	// fixed, several for one the buyer picks in.
	Parts [][]string `json:"parts"`
}

// CustomerBundleStore is an optional store capability (type-asserted, like
// CustomerShelfStore) for the bundles.
type CustomerBundleStore interface {
	// CustomerBundles is every bundle, by rank then key.
	CustomerBundles(ctx context.Context) ([]CustomerBundle, error)
	// SaveCustomerBundle writes a bundle, new or changed, by its key.
	SaveCustomerBundle(ctx context.Context, bundle CustomerBundle) (CustomerBundle, error)
	// DeleteCustomerBundle removes one; ErrCustomerBundleNotFound when there
	// is none.
	DeleteCustomerBundle(ctx context.Context, key string) error
	// RecordCustomerBundlePurchases ties a bundle order's cards to their
	// supplier purchases (by part; "" leaves a part as it was).
	RecordCustomerBundlePurchases(ctx context.Context, id string, purchaseIDs []string) (CustomerOrder, error)
	// RefundCustomerBundleCard gives the customer back, as credit, the share
	// of a paid bundle order that one card that could not be bought came
	// to, and takes it off what the order made. Once per card:
	// applied=false otherwise.
	RefundCustomerBundleCard(ctx context.Context, id string, part int, code, detail string) (CustomerOrder, bool, error)
}

var (
	_ CustomerBundleStore = (*FileStore)(nil)
	_ CustomerBundleStore = (*PostgresStore)(nil)
	_ CustomerBundleStore = (*CachedInstallationStore)(nil)
)

// CustomerBundleCard is one card of a bundle order, as it was sold.
type CustomerBundleCard struct {
	Item  string `json:"item"`
	Brand string `json:"brand"`
	// Label is the card's own label ("60 UC"), for the order's name.
	Label string `json:"label"`
	// Price is the card's shelf price when the order was placed; Booked is
	// what the order books for it: the price, less the saving on the
	// card that carries it.
	Price      string `json:"price"`
	Booked     string `json:"booked"`
	PurchaseID string `json:"purchase_id,omitempty"`
	// Refunded marks a card that could not be bought: its booked share went
	// back to the customer as credit.
	Refunded bool `json:"refunded,omitempty"`
}

// ErrCustomerBundleNotFound is a bundle key no bundle has.
var ErrCustomerBundleNotFound = errors.New("customer bundle not found")

// ErrInvalidCustomerBundle is a bundle the rules refuse; its message says why.
var ErrInvalidCustomerBundle = errors.New("invalid customer bundle")

func invalidBundle(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalidCustomerBundle, fmt.Sprintf(format, args...))
}

var (
	customerBundleKeyPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,63}$`)
	customerBundleArtPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
)

// The most a bundle may have of each; the console's evaluate route bounds a
// draft by the first three too.
const (
	MaxCustomerBundleTiers   = 8
	MaxCustomerBundleParts   = 4
	MaxCustomerBundleOptions = 6
	maxCustomerBundleArt     = 16
	maxCustomerBundles       = 50
)

// NormalizeCustomerBundle checks a bundle against the rules every store
// keeps, and writes it in its canonical form.
func NormalizeCustomerBundle(bundle CustomerBundle) (CustomerBundle, error) {
	bundle.Key = strings.TrimSpace(bundle.Key)
	bundle.Name = strings.TrimSpace(bundle.Name)
	bundle.Tagline = strings.TrimSpace(bundle.Tagline)
	bundle.Actor = truncateRunes(strings.TrimSpace(bundle.Actor), maxIntegrationSwitchText)
	switch {
	case !customerBundleKeyPattern.MatchString(bundle.Key):
		return CustomerBundle{}, invalidBundle("key must be lowercase letters, digits, - or _ (at most 64)")
	case bundle.Name == "" || len([]rune(bundle.Name)) > 60:
		return CustomerBundle{}, invalidBundle("name is required (at most 60 characters)")
	case len([]rune(bundle.Tagline)) > 120:
		return CustomerBundle{}, invalidBundle("tagline is at most 120 characters")
	case len(bundle.Tiers) == 0 || len(bundle.Tiers) > MaxCustomerBundleTiers:
		return CustomerBundle{}, invalidBundle("a bundle has 1 to %d sizes", MaxCustomerBundleTiers)
	case len(bundle.Art) > maxCustomerBundleArt:
		return CustomerBundle{}, invalidBundle("at most %d artworks", maxCustomerBundleArt)
	}
	art := map[string]string{}
	for choice, ref := range bundle.Art {
		choice, ref = strings.TrimSpace(choice), strings.ToLower(strings.TrimSpace(ref))
		if ref == "" {
			continue
		}
		if !customerBundleArtPattern.MatchString(ref) {
			return CustomerBundle{}, invalidBundle("artwork %q is not an uploaded image", choice)
		}
		art[choice] = ref
	}
	bundle.Art = art
	seen := map[string]bool{}
	for i, tier := range bundle.Tiers {
		tier.Key = strings.TrimSpace(tier.Key)
		if !customerBundleKeyPattern.MatchString(tier.Key) {
			return CustomerBundle{}, invalidBundle("size %d: key must be lowercase letters, digits, - or _", i+1)
		}
		if seen[tier.Key] {
			return CustomerBundle{}, invalidBundle("size key %q is used twice", tier.Key)
		}
		seen[tier.Key] = true
		saving, err := ParseWalletAmount(tier.Saving)
		if err != nil || saving.Sign() < 0 {
			return CustomerBundle{}, invalidBundle("size %q: the saving is not an amount", tier.Key)
		}
		tier.Saving = FormatWalletAmount(saving)
		if len(tier.Parts) < 2 || len(tier.Parts) > MaxCustomerBundleParts {
			return CustomerBundle{}, invalidBundle("size %q: a bundle is 2 to %d cards", tier.Key, MaxCustomerBundleParts)
		}
		parts := make([][]string, 0, len(tier.Parts))
		for p, part := range tier.Parts {
			options := []string{}
			inPart := map[string]bool{}
			for _, item := range part {
				item = strings.TrimSpace(item)
				if item == "" || inPart[item] {
					continue
				}
				inPart[item] = true
				options = append(options, item)
			}
			if len(options) == 0 || len(options) > MaxCustomerBundleOptions {
				return CustomerBundle{}, invalidBundle("size %q, card %d: 1 to %d choices", tier.Key, p+1, MaxCustomerBundleOptions)
			}
			parts = append(parts, options)
		}
		tier.Parts = parts
		bundle.Tiers[i] = tier
	}
	return bundle, nil
}

// checkCustomerBundleTiers refuses a tier key another bundle already uses:
// an order names a tier by its key alone.
func checkCustomerBundleTiers(bundle CustomerBundle, others []CustomerBundle) error {
	if len(others) >= maxCustomerBundles {
		exists := false
		for _, other := range others {
			exists = exists || other.Key == bundle.Key
		}
		if !exists {
			return invalidBundle("at most %d bundles", maxCustomerBundles)
		}
	}
	for _, other := range others {
		if other.Key == bundle.Key {
			continue
		}
		for _, theirs := range other.Tiers {
			for _, ours := range bundle.Tiers {
				if theirs.Key == ours.Key {
					return invalidBundle("size key %q is already used by bundle %q", ours.Key, other.Key)
				}
			}
		}
	}
	return nil
}

func sortCustomerBundles(bundles []CustomerBundle) {
	sort.SliceStable(bundles, func(a, b int) bool {
		if bundles[a].Rank != bundles[b].Rank {
			return bundles[a].Rank < bundles[b].Rank
		}
		return bundles[a].Key < bundles[b].Key
	})
}

// --- the bundle order's own transitions ------------------------------------

// customerBundleRefundOrderID keys a card's refund on its order and place, so
// each card is refunded once and never collides with the whole order's.
func customerBundleRefundOrderID(orderID string, part int) string {
	return fmt.Sprintf("%s#%d", orderID, part)
}

func recordCustomerBundlePurchases(order CustomerOrder, purchaseIDs []string, now time.Time) (CustomerOrder, bool) {
	changed := false
	cards := append([]CustomerBundleCard(nil), order.Bundle...)
	for i := range cards {
		if i < len(purchaseIDs) && purchaseIDs[i] != "" && cards[i].PurchaseID == "" {
			cards[i].PurchaseID = purchaseIDs[i]
			changed = true
		}
	}
	if changed {
		order.Bundle = cards
		order.UpdatedAt = now
	}
	return order, changed
}

func refundCustomerBundleCard(order CustomerOrder, part int, code, detail string, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool) {
	if order.Status != CustomerOrderPaid && order.Status != CustomerOrderFulfilling {
		return order, nil, false
	}
	if part < 0 || part >= len(order.Bundle) || order.Bundle[part].Refunded {
		return order, nil, false
	}
	share, err := ParseWalletAmount(order.Bundle[part].Booked)
	if err != nil || share.Sign() <= 0 {
		return order, nil, false
	}
	cards := append([]CustomerBundleCard(nil), order.Bundle...)
	cards[part].Refunded = true
	order.Bundle = cards
	refunded, _ := new(big.Rat).SetString(NormalizeWalletAmount(order.Refunded))
	order.Refunded = FormatWalletAmount(refunded.Add(refunded, share))
	order.ErrorCode = truncateRunes(code, 64)
	order.ErrorDetail = truncateRunes(detail, 500)
	order.UpdatedAt = now
	entry := order.creditEntry(CustomerCreditRefund, FormatWalletAmount(share), now)
	if entry != nil {
		entry.OrderID = customerBundleRefundOrderID(order.ID, part)
	}
	return order, entry, true
}

// --- file store ------------------------------------------------------------

func (s *FileStore) CustomerBundles(_ context.Context) ([]CustomerBundle, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.customerBundlesLocked(), nil
}

func (s *FileStore) customerBundlesLocked() []CustomerBundle {
	out := make([]CustomerBundle, 0, len(s.data.CustomerBundles))
	for _, bundle := range s.data.CustomerBundles {
		out = append(out, bundle)
	}
	sortCustomerBundles(out)
	return out
}

func (s *FileStore) SaveCustomerBundle(_ context.Context, bundle CustomerBundle) (CustomerBundle, error) {
	bundle, err := NormalizeCustomerBundle(bundle)
	if err != nil {
		return CustomerBundle{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := checkCustomerBundleTiers(bundle, s.customerBundlesLocked()); err != nil {
		return CustomerBundle{}, err
	}
	bundle.UpdatedAt = s.clock.Now().UTC()
	if s.data.CustomerBundles == nil {
		s.data.CustomerBundles = map[string]CustomerBundle{}
	}
	previous, had := s.data.CustomerBundles[bundle.Key]
	s.data.CustomerBundles[bundle.Key] = bundle
	if err := s.saveLocked(); err != nil {
		if had {
			s.data.CustomerBundles[bundle.Key] = previous
		} else {
			delete(s.data.CustomerBundles, bundle.Key)
		}
		return CustomerBundle{}, err
	}
	return bundle, nil
}

func (s *FileStore) DeleteCustomerBundle(_ context.Context, key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	previous, ok := s.data.CustomerBundles[key]
	if !ok {
		return ErrCustomerBundleNotFound
	}
	delete(s.data.CustomerBundles, key)
	if err := s.saveLocked(); err != nil {
		s.data.CustomerBundles[key] = previous
		return err
	}
	return nil
}

func (s *FileStore) RecordCustomerBundlePurchases(_ context.Context, id string, purchaseIDs []string) (CustomerOrder, error) {
	order, _, err := s.mutateCustomerOrder(id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		next, changed := recordCustomerBundlePurchases(order, purchaseIDs, now)
		return next, nil, changed, nil
	})
	return order, err
}

func (s *FileStore) RefundCustomerBundleCard(_ context.Context, id string, part int, code, detail string) (CustomerOrder, bool, error) {
	return s.mutateCustomerOrder(id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		next, entry, applied := refundCustomerBundleCard(order, part, code, detail, now)
		return next, entry, applied, nil
	})
}

// --- postgres store --------------------------------------------------------

func (s *PostgresStore) CustomerBundles(ctx context.Context) ([]CustomerBundle, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT key, name, tagline, rank, art, tiers, actor, updated_at FROM relay_customer_bundles`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []CustomerBundle{}
	for rows.Next() {
		var bundle CustomerBundle
		var art, tiers []byte
		if err := rows.Scan(&bundle.Key, &bundle.Name, &bundle.Tagline, &bundle.Rank, &art, &tiers,
			&bundle.Actor, &bundle.UpdatedAt); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(art, &bundle.Art); err != nil {
			return nil, fmt.Errorf("customer bundle %s art: %w", bundle.Key, err)
		}
		if err := json.Unmarshal(tiers, &bundle.Tiers); err != nil {
			return nil, fmt.Errorf("customer bundle %s tiers: %w", bundle.Key, err)
		}
		if bundle.Art == nil {
			bundle.Art = map[string]string{}
		}
		bundle.UpdatedAt = bundle.UpdatedAt.UTC()
		out = append(out, bundle)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sortCustomerBundles(out)
	return out, nil
}

func (s *PostgresStore) SaveCustomerBundle(ctx context.Context, bundle CustomerBundle) (CustomerBundle, error) {
	bundle, err := NormalizeCustomerBundle(bundle)
	if err != nil {
		return CustomerBundle{}, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerBundle{}, err
	}
	defer tx.Rollback(ctx)
	// One writer at a time, so two saves cannot both take a tier key.
	if _, err := tx.Exec(ctx, `LOCK TABLE relay_customer_bundles IN SHARE ROW EXCLUSIVE MODE`); err != nil {
		return CustomerBundle{}, err
	}
	rows, err := tx.Query(ctx, `SELECT key, tiers FROM relay_customer_bundles`)
	if err != nil {
		return CustomerBundle{}, err
	}
	others := []CustomerBundle{}
	for rows.Next() {
		var other CustomerBundle
		var tiers []byte
		if err := rows.Scan(&other.Key, &tiers); err != nil {
			rows.Close()
			return CustomerBundle{}, err
		}
		if err := json.Unmarshal(tiers, &other.Tiers); err != nil {
			rows.Close()
			return CustomerBundle{}, err
		}
		others = append(others, other)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return CustomerBundle{}, err
	}
	if err := checkCustomerBundleTiers(bundle, others); err != nil {
		return CustomerBundle{}, err
	}
	bundle.UpdatedAt = s.clock.Now().UTC()
	art, _ := json.Marshal(bundle.Art)
	tiers, _ := json.Marshal(bundle.Tiers)
	if _, err := tx.Exec(ctx,
		`INSERT INTO relay_customer_bundles (key, name, tagline, rank, art, tiers, actor, updated_at)
		VALUES ($1, $2, $3, $4, $5::jsonb, $6::jsonb, $7, $8)
		ON CONFLICT (key) DO UPDATE SET name = EXCLUDED.name, tagline = EXCLUDED.tagline, rank = EXCLUDED.rank,
			art = EXCLUDED.art, tiers = EXCLUDED.tiers, actor = EXCLUDED.actor, updated_at = EXCLUDED.updated_at`,
		bundle.Key, bundle.Name, bundle.Tagline, bundle.Rank, string(art), string(tiers), bundle.Actor, bundle.UpdatedAt,
	); err != nil {
		return CustomerBundle{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return CustomerBundle{}, err
	}
	return bundle, nil
}

func (s *PostgresStore) DeleteCustomerBundle(ctx context.Context, key string) error {
	tag, err := s.pool.Exec(ctx, `DELETE FROM relay_customer_bundles WHERE key = $1`, key)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrCustomerBundleNotFound
	}
	return nil
}

func (s *PostgresStore) RecordCustomerBundlePurchases(ctx context.Context, id string, purchaseIDs []string) (CustomerOrder, error) {
	order, _, err := s.mutateCustomerBundleOrder(ctx, id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool) {
		next, changed := recordCustomerBundlePurchases(order, purchaseIDs, now)
		return next, nil, changed
	})
	return order, err
}

func (s *PostgresStore) RefundCustomerBundleCard(ctx context.Context, id string, part int, code, detail string) (CustomerOrder, bool, error) {
	return s.mutateCustomerBundleOrder(ctx, id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool) {
		return refundCustomerBundleCard(order, part, code, detail, now)
	})
}

// mutateCustomerBundleOrder runs one change to a bundle order's cards on the
// locked row: its cards, what was refunded, and the transition fields.
func (s *PostgresStore) mutateCustomerBundleOrder(
	ctx context.Context,
	id string,
	change func(CustomerOrder, time.Time) (CustomerOrder, *CustomerCreditEntry, bool),
) (CustomerOrder, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerOrder{}, false, err
	}
	defer tx.Rollback(ctx)
	order, err := scanCustomerOrder(tx.QueryRow(ctx,
		`SELECT `+selectCustomerOrderColumns+` FROM relay_customer_orders WHERE id = $1 FOR UPDATE`, id))
	if err != nil {
		return CustomerOrder{}, false, err
	}
	next, entry, applied := change(order, s.clock.Now().UTC())
	if !applied {
		return order, false, nil
	}
	if err := writeCustomerOrderTx(ctx, tx, next, false); err != nil {
		return CustomerOrder{}, false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE relay_customer_orders SET bundle = $2::jsonb, refunded = $3::numeric WHERE id = $1`,
		next.ID, customerBundleJSON(next.Bundle), NormalizeWalletAmount(next.Refunded)); err != nil {
		return CustomerOrder{}, false, err
	}
	if err := insertCustomerCreditTx(ctx, tx, entry); err != nil {
		return CustomerOrder{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return CustomerOrder{}, false, err
	}
	return next, true, nil
}

func customerBundleJSON(cards []CustomerBundleCard) string {
	if len(cards) == 0 {
		return "null"
	}
	raw, _ := json.Marshal(cards)
	return string(raw)
}

// --- cached store ------------------------------------------------------------

func (s *CachedInstallationStore) customerBundleStore() (CustomerBundleStore, error) {
	store, ok := s.store.(CustomerBundleStore)
	if !ok {
		return nil, errCustomersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) CustomerBundles(ctx context.Context) ([]CustomerBundle, error) {
	store, err := s.customerBundleStore()
	if err != nil {
		return nil, err
	}
	return store.CustomerBundles(ctx)
}

func (s *CachedInstallationStore) SaveCustomerBundle(ctx context.Context, bundle CustomerBundle) (CustomerBundle, error) {
	store, err := s.customerBundleStore()
	if err != nil {
		return CustomerBundle{}, err
	}
	return store.SaveCustomerBundle(ctx, bundle)
}

func (s *CachedInstallationStore) DeleteCustomerBundle(ctx context.Context, key string) error {
	store, err := s.customerBundleStore()
	if err != nil {
		return err
	}
	return store.DeleteCustomerBundle(ctx, key)
}

func (s *CachedInstallationStore) RecordCustomerBundlePurchases(ctx context.Context, id string, purchaseIDs []string) (CustomerOrder, error) {
	store, err := s.customerBundleStore()
	if err != nil {
		return CustomerOrder{}, err
	}
	return store.RecordCustomerBundlePurchases(ctx, id, purchaseIDs)
}

func (s *CachedInstallationStore) RefundCustomerBundleCard(ctx context.Context, id string, part int, code, detail string) (CustomerOrder, bool, error) {
	store, err := s.customerBundleStore()
	if err != nil {
		return CustomerOrder{}, false, err
	}
	return store.RefundCustomerBundleCard(ctx, id, part, code, detail)
}
