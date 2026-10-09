package relay

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// VoucherReconciler settles card purchases whose outcome was left open: the
// supplier timed out or erred after taking the order, or the relay making
// the call died. Each is read back from the supplier — the order it named, or
// its order history — and either kept (the cards were bought) or refunded
// (they were not). One that cannot be told stays held, and after two days
// asks for the operator.
//
// A purchase that cannot be checked at all right now (its supplier is not
// configured here, its records cannot be read) is not asked about again every
// round: it is left alone for a minute, then two, four, up to half an hour, so
// the rows that can be settled are never starved by the ones that cannot.
type VoucherReconciler struct {
	Server   HTTPServer
	Store    control.VoucherStore
	Interval time.Duration
	Logger   *slog.Logger

	mu      sync.Mutex
	backoff map[string]rowBackoff
}

const (
	// voucherAwaitingBatch is how many held purchases one round reads, oldest
	// first.
	voucherAwaitingBatch = 500
	// The pause between two checks of a purchase that cannot be checked: it
	// doubles from the first up to the last.
	voucherBackoffFirst = time.Minute
	voucherBackoffMax   = 30 * time.Minute
)

// rowBackoff is what the reconciler remembers about a purchase it could not
// check: the verdict it got, how long it now leaves the purchase alone, until
// when, and the state of the row it saw (a row that changed is asked about again
// at once).
type rowBackoff struct {
	verdict   string
	delay     time.Duration
	next      time.Time
	updatedAt time.Time
}

func (r *VoucherReconciler) Run(ctx context.Context) {
	interval := r.Interval
	if interval <= 0 {
		interval = time.Minute
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		r.Round(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Round checks every purchase waiting for a verdict once, except those it is
// leaving alone for a while.
func (r *VoucherReconciler) Round(ctx context.Context) {
	logger := r.Logger
	if logger == nil {
		logger = slog.Default()
	}
	now := r.Server.clock().Now()
	staleBefore := now.Add(-r.Server.Vouchers.staleAfter())
	pending, err := r.Store.ListVoucherPurchasesAwaitingCheck(ctx, staleBefore, voucherAwaitingBatch)
	if err != nil {
		logger.Error("listing held purchases failed", "error", err)
		return
	}
	if len(pending) >= voucherAwaitingBatch {
		logger.Warn("as many held purchases await a check as one round reads; the oldest come first",
			"read", len(pending))
	}
	r.forgetSettled(pending)
	for _, purchase := range pending {
		if ctx.Err() != nil {
			return
		}
		if r.leftAlone(purchase, now) {
			continue
		}
		_, verdict, err := r.Server.checkVoucherPurchase(ctx, r.Store, purchase)
		r.learn(purchase, verdict, err, now)
		if err != nil && !errors.Is(err, vouchers.ErrNameUnknown) {
			// A held purchase is a card or a service order: the line says which.
			logger.Warn("checking a held "+heldNoun(purchase)+" failed",
				"purchase_id", purchase.ID, "kind", purchase.Kind, "verdict", verdict, "error", err)
		}
	}
}

// stuckVerdict reports whether a verdict says the purchase cannot be checked
// now and will not be by asking again at once. Waiting for the window, a
// supplier order still open and the supplier's name for the card still being
// read are ordinary: the next round may well settle them.
func stuckVerdict(verdict string, err error) bool {
	switch verdict {
	case "supplier_unconfigured", "unrecorded", "duplicate":
		return true
	case "unreadable":
		return !errors.Is(err, vouchers.ErrNameUnknown)
	}
	return false
}

// leftAlone reports whether a purchase is still in its pause. A row that
// changed since the verdict (its state moved) is not.
func (r *VoucherReconciler) leftAlone(purchase control.VoucherPurchase, now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	state, known := r.backoff[purchase.ID]
	if !known {
		return false
	}
	if !state.updatedAt.Equal(purchase.UpdatedAt) {
		delete(r.backoff, purchase.ID)
		return false
	}
	return now.Before(state.next)
}

// learn records a check's verdict: a stuck purchase is left alone for twice as
// long as last time (a minute the first), anything else forgets the pause.
func (r *VoucherReconciler) learn(purchase control.VoucherPurchase, verdict string, err error, now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !stuckVerdict(verdict, err) {
		delete(r.backoff, purchase.ID)
		return
	}
	delay := voucherBackoffFirst
	if previous, known := r.backoff[purchase.ID]; known && previous.verdict == verdict && previous.updatedAt.Equal(purchase.UpdatedAt) {
		delay = min(previous.delay*2, voucherBackoffMax)
	}
	if r.backoff == nil {
		r.backoff = map[string]rowBackoff{}
	}
	r.backoff[purchase.ID] = rowBackoff{verdict: verdict, delay: delay, next: now.Add(delay), updatedAt: purchase.UpdatedAt}
}

// forgetSettled drops the pauses of purchases that no longer await a check, so
// the memory holds only the rows still stuck.
func (r *VoucherReconciler) forgetSettled(pending []control.VoucherPurchase) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.backoff) == 0 {
		return
	}
	waiting := make(map[string]bool, len(pending))
	for _, purchase := range pending {
		waiting[purchase.ID] = true
	}
	for id := range r.backoff {
		if !waiting[id] {
			delete(r.backoff, id)
		}
	}
}

// VoucherOfferSync reads what every configured supplier sells the company,
// at what price and whether in stock, so the catalog can say which cards are
// available and keep each item above its cost.
type VoucherOfferSync struct {
	Config   VoucherConfig
	Store    control.VoucherStore
	Interval time.Duration
	Logger   *slog.Logger
}

func (w *VoucherOfferSync) Run(ctx context.Context) {
	if w.Interval <= 0 {
		return
	}
	ticker := time.NewTicker(w.Interval)
	defer ticker.Stop()
	for {
		w.Round(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Round reads every supplier's offers once and says what became of it: a WARN
// for each supplier that could not be read (its last offers stand), and an ERROR
// when those last offers are by now older than the relay believes.
func (w *VoucherOfferSync) Round(ctx context.Context) {
	logger := w.Logger
	if logger == nil {
		logger = slog.Default()
	}
	result := syncVoucherOffers(ctx, w.Config, w.Store, logger)
	if len(result.Failures) == 0 {
		logger.Info("supplier offers read", "synced", result.Counts)
		return
	}
	logger.Warn("reading supplier offers failed; the last ones stand", "synced", result.Counts, "error", result.err())
	for _, key := range result.failedSuppliers() {
		logger.Warn("reading a supplier's offers failed; its last ones stand", "supplier", key, "error", result.Failures[key])
		w.reportOldOffers(ctx, logger, key)
	}
}

// reportOldOffers makes noise when a supplier whose sync keeps failing has
// offers older than the relay believes: its cards then count as unknown (and
// Reloadly's are not sold), which is not what the shops' catalog was built on.
func (w *VoucherOfferSync) reportOldOffers(ctx context.Context, logger *slog.Logger, supplier string) {
	limit := w.Config.offersMaxAge()
	if limit <= 0 {
		return
	}
	stored, err := w.Store.ListVoucherOffers(ctx, supplier)
	if err != nil {
		return
	}
	var newest time.Time
	for _, offer := range stored {
		if offer.SyncedAt.After(newest) {
			newest = offer.SyncedAt
		}
	}
	if newest.IsZero() {
		return
	}
	if age := time.Since(newest); age > limit {
		logger.Error("a supplier's offers are older than the relay believes; its cards count as unknown (Reloadly's are not sold) until they are read again",
			"supplier", supplier, "last_read", newest, "age", age.Round(time.Minute).String(), "limit", limit.String())
	}
}

// wantedVoucherRefs is every card the current catalog asks each supplier for,
// by supplier key: what a supplier that prices only what it is asked for
// (vouchers.WantedOffers) is handed. Nothing is wanted before the first catalog.
func wantedVoucherRefs(ctx context.Context, store control.VoucherStore) (map[string][]vouchers.Ref, error) {
	record, err := store.CurrentVoucherCatalog(ctx)
	if errors.Is(err, control.ErrVoucherCatalogNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	document, err := vouchers.ParseDocument(record.Document)
	if err != nil {
		return nil, fmt.Errorf("stored voucher catalog %s does not parse: %w", record.ID, err)
	}
	wanted := map[string][]vouchers.Ref{}
	seen := map[string]bool{}
	for _, brand := range document.Brands {
		for _, item := range brand.Items {
			refs, err := vouchers.ParseRefs(item)
			if err != nil {
				continue
			}
			for _, ref := range refs {
				if id := ref.Supplier + "/" + ref.ID; !seen[id] {
					seen[id] = true
					wanted[ref.Supplier] = append(wanted[ref.Supplier], ref)
				}
			}
		}
	}
	return wanted, nil
}

// voucherEmptyOffersDoubt is how many offers a supplier must have stored for an
// empty answer to be doubted: a supplier that sold a hundred cards a moment ago
// and now lists none has not stopped selling them, it has failed to say.
const voucherEmptyOffersDoubt = 10

// voucherSyncResult is what one read of every supplier's offers came to.
type voucherSyncResult struct {
	// Counts is how many offers each supplier that was read now has stored.
	Counts map[string]int
	// Failures are the suppliers that could not be read (or whose answer was not
	// believed), with why. Their last offers stand.
	Failures map[string]error
}

// failedSuppliers lists the suppliers that failed, by key.
func (r voucherSyncResult) failedSuppliers() []string {
	keys := make([]string, 0, len(r.Failures))
	for key := range r.Failures {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// err is the failures as one error, nil when there were none.
func (r voucherSyncResult) err() error {
	keys := r.failedSuppliers()
	if len(keys) == 0 {
		return nil
	}
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, key+": "+r.Failures[key].Error())
	}
	return errors.New(strings.Join(parts, "; "))
}

// SyncVoucherOffers reads every configured supplier's offers and stores them.
// A supplier that lists everything it sells (BN Plus) is asked for it all; one
// that prices only the card asked for (Reloadly, whose price depends on the
// amount) is asked for the cards the current catalog names. A supplier that
// cannot be read keeps the offers it had.
func SyncVoucherOffers(ctx context.Context, config VoucherConfig, store control.VoucherStore) (map[string]int, error) {
	result := syncVoucherOffers(ctx, config, store, slog.Default())
	return result.Counts, result.err()
}

func syncVoucherOffers(ctx context.Context, config VoucherConfig, store control.VoucherStore, logger *slog.Logger) voucherSyncResult {
	result := voucherSyncResult{Counts: map[string]int{}, Failures: map[string]error{}}
	var wanted map[string][]vouchers.Ref
	wantedRead := false
	keys := make([]string, 0, len(config.Suppliers))
	for key := range config.Suppliers {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		supplier := config.Suppliers[key]
		callCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
		var offers []vouchers.Offer
		var err error
		// expectEmpty: nothing was asked for, so nothing is the right answer.
		expectEmpty := false
		if asked, ok := supplier.(vouchers.WantedOffers); ok {
			if !wantedRead {
				wanted, err = wantedVoucherRefs(callCtx, store)
				wantedRead = err == nil
			}
			if err == nil {
				// Nothing wanted is nothing to read (and nothing to keep).
				if refs := wanted[key]; len(refs) > 0 {
					offers, err = asked.OffersFor(callCtx, refs)
				} else {
					expectEmpty = true
				}
			}
		} else {
			offers, err = supplier.Offers(callCtx)
		}
		cancel()
		if err != nil {
			result.Failures[key] = err
			continue
		}
		now := time.Now().UTC()
		rows := make([]control.VoucherOffer, 0, len(offers))
		for _, offer := range offers {
			if offer.SyncedAt.IsZero() {
				offer.SyncedAt = now
			}
			rows = append(rows, control.VoucherOffer{
				Supplier: key,
				Ref:      offer.Ref,
				Name:     offer.Name,
				Group:    offer.Group,
				Price:    offer.Price,
				Currency: offer.Currency,
				InStock:  offer.InStock,
				SyncedAt: offer.SyncedAt,
			})
		}
		if len(rows) == 0 && !expectEmpty {
			// An empty answer from a supplier that had many offers a moment ago
			// is a failure to answer, not a sold-out shelf: replacing them would
			// forget every price, stock and guard at once.
			if stored, err := store.ListVoucherOffers(ctx, key); err == nil && len(stored) >= voucherEmptyOffersDoubt {
				result.Failures[key] = fmt.Errorf("%s answered with no offers although %d are stored; the stored ones are kept", key, len(stored))
				logger.Error("a supplier answered with no offers although it had many; they are kept, not replaced",
					"supplier", key, "stored", len(stored))
				continue
			}
		}
		if err := store.ReplaceVoucherOffers(ctx, key, rows); err != nil {
			result.Failures[key] = err
			continue
		}
		result.Counts[key] = len(rows)
	}
	return result
}
