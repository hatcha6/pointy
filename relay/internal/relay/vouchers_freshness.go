package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// Two things keep a till from offering a card the supplier cannot hand over:
//
//   - When a till opens a brand, the shop asks for the catalog with ?fresh=<brand>
//     and the relay re-reads that brand's cards at their suppliers first
//     (refreshBrandOffers), unless they were read in the last minute — by any
//     node, since the time is on the stored offer.
//   - A supplier that took a purchase and then had no code to give (BN Plus's
//     "card codes receiving failed", while its own list still says in stock)
//     holds that card off the shelf for a while (CardHolds). A fresh read does
//     not lift it: the list was what was wrong. A later sale of it does.

// cardHoldPause is how long a card a supplier could not deliver stays off the
// shelf. When it ends, the next purchase tries again: a sale lifts the hold, the
// same failure puts it back.
const cardHoldPause = 30 * time.Minute

// brandOffersFreshFor is how long a brand's offers, once read, answer every till
// that opens it without asking the supplier again.
const brandOffersFreshFor = time.Minute

// brandRefreshTimeout bounds the supplier reads a till's open waits on; past it
// the shop gets the offers as they were.
const brandRefreshTimeout = 4 * time.Second

// CardHolds remembers which cards a supplier could not deliver, until when. With
// Redis it is shared by every node (one hash, read whole per shelf); without it,
// each node keeps its own. The zero pointer holds nothing.
type CardHolds struct {
	mu    sync.Mutex
	local map[string]cardHold
	redis redis.Cmdable
	key   string
}

type cardHold struct {
	Until time.Time `json:"until"`
	Why   string    `json:"why"`
}

// NewCardHolds holds nothing yet, in this node's memory.
func NewCardHolds() *CardHolds {
	return &CardHolds{local: map[string]cardHold{}}
}

// Share keeps the holds in Redis, under prefix, so every node sees them.
func (h *CardHolds) Share(client redis.Cmdable, prefix string) {
	if h == nil || client == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.redis, h.key = client, strings.TrimSuffix(prefix, ":")+":voucher:card-holds"
}

func cardHoldKey(supplier, ref string) string { return supplier + "/" + ref }

// hold takes a supplier's card off the shelf until now+cardHoldPause.
func (h *CardHolds) hold(ctx context.Context, supplier, ref, why string, now time.Time) error {
	if h == nil {
		return nil
	}
	entry := cardHold{Until: now.Add(cardHoldPause).UTC(), Why: why}
	key := cardHoldKey(supplier, ref)
	h.mu.Lock()
	h.local[key] = entry
	client, hash := h.redis, h.key
	h.mu.Unlock()
	if client == nil {
		return nil
	}
	raw, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	pipe := client.TxPipeline()
	pipe.HSet(ctx, hash, key, raw)
	// Every entry carries its own end; the hash only must not outlive the last.
	pipe.Expire(ctx, hash, cardHoldPause+time.Minute)
	_, err = pipe.Exec(ctx)
	return err
}

// release puts a supplier's card back, if it was held.
func (h *CardHolds) release(ctx context.Context, supplier, ref string) error {
	if h == nil {
		return nil
	}
	key := cardHoldKey(supplier, ref)
	h.mu.Lock()
	delete(h.local, key)
	client, hash := h.redis, h.key
	h.mu.Unlock()
	if client == nil {
		return nil
	}
	return client.HDel(ctx, hash, key).Err()
}

// current is every hold still running at now, by "supplier/ref". When Redis
// cannot be read, this node's own memory answers.
func (h *CardHolds) current(ctx context.Context, now time.Time) map[string]cardHold {
	if h == nil {
		return nil
	}
	h.mu.Lock()
	client, hash := h.redis, h.key
	local := make(map[string]cardHold, len(h.local))
	for key, entry := range h.local {
		if now.Before(entry.Until) {
			local[key] = entry
		} else {
			delete(h.local, key)
		}
	}
	h.mu.Unlock()
	if client == nil {
		return local
	}
	stored, err := client.HGetAll(ctx, hash).Result()
	if err != nil {
		return local
	}
	shared := map[string]cardHold{}
	for key, raw := range stored {
		var entry cardHold
		if json.Unmarshal([]byte(raw), &entry) == nil && now.Before(entry.Until) {
			shared[key] = entry
		}
	}
	return shared
}

// heldReason says why a held card is not sold, "" when it is not held.
func (o voucherOffers) heldReason(ref vouchers.Ref) string {
	entry, held := o.holds[cardHoldKey(ref.Supplier, ref.ID)]
	if !held {
		return ""
	}
	return fmt.Sprintf("the supplier could not deliver this card (%s); held off the shelf until %s",
		entry.Why, entry.Until.UTC().Format("15:04 MST"))
}

// noteCardDelivery learns from a purchase whether its card can be delivered: a
// sale lifts a hold, "no code to give" puts one on.
func (s HTTPServer) noteCardDelivery(ctx context.Context, purchaseID string, ref vouchers.Ref, err error) {
	holds := s.Vouchers.Holds
	if holds == nil {
		return
	}
	if err == nil {
		if releaseErr := holds.release(ctx, ref.Supplier, ref.ID); releaseErr != nil {
			s.logger().Warn("could not lift a card's hold after a sale", "supplier", ref.Supplier, "ref", ref.ID, "error", releaseErr)
		}
		return
	}
	failure := failureOf(err)
	if failure.Code != vouchers.FailureOutOfStock || !failure.Definite || ref.Supplier == vouchers.SupplierStock {
		return
	}
	if holdErr := holds.hold(ctx, ref.Supplier, ref.ID, failure.Detail, s.clock().Now()); holdErr != nil {
		s.logger().Warn("could not share a card's hold; this node holds it alone", "supplier", ref.Supplier, "ref", ref.ID, "error", holdErr)
	}
	s.logger().Warn("a supplier had no code for a card it lists as in stock; the card is off the shelf for a while",
		"purchase_id", purchaseID, "supplier", ref.Supplier, "ref", ref.ID, "detail", failure.Detail,
		"held_for", cardHoldPause.String())
}

// OfferRefreshes lets one read of a brand's cards answer every till that opens
// it at once on this node. The zero pointer reads every time.
type OfferRefreshes struct {
	mu       sync.Mutex
	inFlight map[string]chan struct{}
}

// NewOfferRefreshes has nothing in flight.
func NewOfferRefreshes() *OfferRefreshes {
	return &OfferRefreshes{inFlight: map[string]chan struct{}{}}
}

// do runs read unless the same key is being read already, in which case it
// waits for that one (or for ctx).
func (r *OfferRefreshes) do(ctx context.Context, key string, read func()) {
	if r == nil {
		read()
		return
	}
	r.mu.Lock()
	if done, busy := r.inFlight[key]; busy {
		r.mu.Unlock()
		select {
		case <-done:
		case <-ctx.Done():
		}
		return
	}
	done := make(chan struct{})
	r.inFlight[key] = done
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.inFlight, key)
		r.mu.Unlock()
		close(done)
	}()
	read()
}

// refreshBrandOffers re-reads, at the suppliers that can (vouchers.OfferRefresher),
// the cards of one brand whose offers are older than brandOffersFreshFor. It
// never fails the caller: a supplier that cannot be read leaves its offers as
// they were, which is what the till already shows.
func (s HTTPServer) refreshBrandOffers(ctx context.Context, store control.VoucherStore, document vouchers.Document, brandKey string) {
	if s.Vouchers.TestMode || brandKey == "" {
		return
	}
	var brand *vouchers.Brand
	for i := range document.Brands {
		if document.Brands[i].Key == brandKey {
			brand = &document.Brands[i]
			break
		}
	}
	if brand == nil {
		return
	}
	offers, err := s.loadVoucherOffers(ctx, store)
	if err != nil {
		return
	}
	now := s.clock().Now()
	stale := map[string][]vouchers.Ref{}
	for _, item := range brand.Items {
		refs, err := vouchers.ParseRefs(item)
		if err != nil {
			continue
		}
		for _, ref := range refs {
			if _, ok := s.Vouchers.Suppliers[ref.Supplier].(vouchers.OfferRefresher); !ok {
				continue
			}
			if offer, known := offers.offer(ref); known && now.Sub(offer.SyncedAt) < brandOffersFreshFor {
				continue
			}
			stale[ref.Supplier] = append(stale[ref.Supplier], ref)
		}
	}
	if len(stale) == 0 {
		return
	}
	readCtx, cancel := context.WithTimeout(ctx, brandRefreshTimeout)
	defer cancel()
	for supplierKey, refs := range stale {
		refresher := s.Vouchers.Suppliers[supplierKey].(vouchers.OfferRefresher)
		s.Vouchers.Refreshes.do(readCtx, supplierKey+"/"+brandKey, func() {
			fresh, err := refresher.RefreshOffers(readCtx, refs)
			if err != nil {
				s.logger().Warn("could not re-read a brand's cards for a till; it gets them as last read",
					"brand", brandKey, "supplier", supplierKey, "error", err)
				return
			}
			stored := storedVoucherOffers(supplierKey, fresh, s.clock().Now().UTC())
			if err := store.UpsertVoucherOffers(context.WithoutCancel(ctx), supplierKey, stored); err != nil {
				s.logger().Warn("could not store a brand's re-read cards", "brand", brandKey, "supplier", supplierKey, "error", err)
			}
		})
	}
}
