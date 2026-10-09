package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"pointy/relay/internal/bnplus"
	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
)

// The company's own card shop. A shop's backend reads the catalog the operator
// published, and buys a card the moment its invoice is issued: the relay takes
// the price from the shop's voucher balance, buys the card from the supplier
// with the company's account, and hands back the code. Nothing here holds a
// code after the answer: the shop keeps it, and the supplier can hand it back
// again for an order it names.
//
//	GET  /v1/vouchers/catalog              the catalog, priced for now (ETag)
//	GET  /v1/vouchers/images/{sha256}      a logo or flag
//	POST /v1/vouchers/purchases            buy {item, quantity, idempotency_key, max_unit_price}
//	GET  /v1/vouchers/purchases/{key}      read a purchase back by its key

const (
	defaultVoucherRequestTimeout = 45 * time.Second
	voucherMinimumStaleAfter     = 2 * time.Minute
	// voucherOffersMinimumAge is the least age that makes a supplier's offers
	// untrustworthy, however often they are meant to be read.
	voucherOffersMinimumAge = 2 * time.Hour
	// voucherSearchBefore and voucherSearchAfter widen the window a lost
	// purchase is looked for in, around the moment it was claimed: clock
	// skew before, the supplier's own slowness after.
	voucherSearchBefore = 2 * time.Minute
	voucherSearchAfter  = 5 * time.Minute
	// voucherAbsentAfter is how long a lost purchase is looked for before its
	// absence from the supplier's history is believed and the money returned.
	voucherAbsentAfter = 15 * time.Minute
	// voucherOperatorAfter: a purchase still unresolved this long needs a
	// person (pointy-relay vouchers resolve).
	voucherOperatorAfter = 48 * time.Hour
	// voucherCatalogHeadTTL is how long a node trusts its idea of which
	// catalog is current before asking the store again.
	voucherCatalogHeadTTL    = 5 * time.Second
	maxVoucherRequestBytes   = 16 << 10
	maxVoucherKeyRunes       = 100
	maxVoucherQuantity       = 10
	voucherCodesLookupBudget = 10 * time.Second
)

// Error codes of the voucher API. The shop's backend maps them to the till's
// words.
const (
	voucherCodeUnconfigured        = "vouchers_unconfigured"
	voucherCodeUnavailable         = "vouchers_unavailable"
	voucherCodeInvalidRequest      = "invalid_request"
	voucherCodeInvalidQuantity     = "invalid_quantity"
	voucherCodeUnknownItem         = "unknown_item"
	voucherCodeItemUnavailable     = "item_unavailable"
	voucherCodePriceChanged        = "price_changed"
	voucherCodeInsufficientBalance = "insufficient_balance"
	voucherCodeInFlight            = "in_flight"
	voucherCodeRateLimited         = "rate_limited"
	voucherCodeNotFound            = "not_found"
	voucherCodeInternalError       = "internal_error"
)

// VoucherConfig is the company's card shop: which suppliers the relay buys
// from with the company's own accounts. BN Plus's e-mail, password and token
// and Reloadly's client id and secret live only here, like the Resala and Dafa
// keys.
type VoucherConfig struct {
	// Suppliers the relay can buy from, by key. BN Plus is here when the
	// company's credentials are configured, and Reloadly likewise.
	Suppliers map[string]vouchers.Supplier
	// BNPlus is BN Plus's client, for the operator's discovery reads; nil
	// when BN Plus is not configured.
	BNPlus *bnplus.Client
	// Reloadly is Reloadly's client: the card supplier's, and the one direct
	// top-up and bill payments are bought with. Nil when Reloadly is not
	// configured.
	Reloadly *reloadly.Client
	// TestMode sends every purchase to the built-in test supplier: fake codes,
	// nothing bought from anyone, the voucher balance still charged.
	TestMode bool
	// RateLimit is the per-shop guard on purchases.
	RateLimit ratelimit.Policy
	// RequestTimeout bounds one supplier call.
	RequestTimeout time.Duration
	// SyncInterval is how often supplier offers are read; 0 is never.
	SyncInterval time.Duration
	// Breaker remembers which suppliers just failed in a way that will repeat, so
	// they are skipped for a few minutes while another can sell. Nil: never.
	Breaker *SupplierBreaker
}

// Configured reports whether the relay can sell cards at all.
func (c VoucherConfig) Configured() bool {
	return c.TestMode || len(c.Suppliers) > 0
}

// SandboxMode reports whether the relay is wired to Reloadly's SANDBOX: fake
// money and a catalog that is not the live one. Such a relay still executes
// against the sandbox, but it must not pass for production, so everything it
// sells is marked as test (MarksTest). Direct top-up and bill payments ask it
// too.
func (c VoucherConfig) SandboxMode() bool {
	return c.Reloadly != nil && c.Reloadly.Sandbox()
}

// MarksTest reports whether what the relay sells is marked as test: the shop
// view says test_mode, every purchase row is a test purchase (its statement
// entries are marked test, its payload says so). That is test mode (the
// built-in supplier, nothing bought) and also the Reloadly sandbox (something
// bought, with fake money).
func (c VoucherConfig) MarksTest() bool {
	return c.TestMode || c.SandboxMode()
}

// supplierByKey is who a stored purchase was bought from, to read it back.
// A test purchase is always readable, even after test mode is switched off.
func (c VoucherConfig) supplierByKey(key string) (vouchers.Supplier, bool) {
	if key == vouchers.SupplierTest {
		return vouchers.TestSupplier{}, true
	}
	supplier, ok := c.Suppliers[key]
	return supplier, ok
}

// offersMaxAge is how old a supplier's offers may be before the relay stops
// believing them: three sync intervals, and never under two hours. A relay that
// does not read offers on a schedule (SyncInterval 0) keeps whatever the
// operator last read by hand, however old.
func (c VoucherConfig) offersMaxAge() time.Duration {
	if c.SyncInterval <= 0 {
		return 0
	}
	return max(3*c.SyncInterval, voucherOffersMinimumAge)
}

func (c VoucherConfig) requestTimeout() time.Duration {
	if c.RequestTimeout > 0 {
		return c.RequestTimeout
	}
	return defaultVoucherRequestTimeout
}

// staleAfter is when a pending purchase nobody finished is taken for one
// whose relay died mid-call.
func (c VoucherConfig) staleAfter() time.Duration {
	return max(voucherMinimumStaleAfter, c.requestTimeout()+30*time.Second)
}

// VoucherCatalogCache keeps the parsed current catalog between requests: a
// document is parsed once per version, and which version is current is asked
// of the store at most every few seconds. Shared by every copy of the server.
type VoucherCatalogCache struct {
	mu      sync.Mutex
	checked time.Time
	head    control.VoucherCatalog
	parsed  *vouchers.Document
	sha     string
}

// loadedCatalog is the current catalog, parsed.
type loadedCatalog struct {
	record   control.VoucherCatalog
	document vouchers.Document
	empty    bool
}

func (s HTTPServer) voucherStore() (control.VoucherStore, bool) {
	store, ok := s.Store.(control.VoucherStore)
	return store, ok
}

// currentVoucherCatalog reads the published catalog. Before the first one is
// published it is empty, not an error: a shop then simply sells nothing.
func (s HTTPServer) currentVoucherCatalog(ctx context.Context, store control.VoucherStore) (loadedCatalog, error) {
	cache := s.VoucherCache
	now := s.clock().Now()
	if cache != nil {
		cache.mu.Lock()
		if cache.parsed != nil && now.Sub(cache.checked) < voucherCatalogHeadTTL {
			loaded := loadedCatalog{record: cache.head, document: *cache.parsed}
			cache.mu.Unlock()
			return loaded, nil
		}
		cache.mu.Unlock()
		head, err := store.VoucherCatalogHead(ctx)
		if errors.Is(err, control.ErrVoucherCatalogNotFound) {
			return loadedCatalog{empty: true}, nil
		}
		if err != nil {
			return loadedCatalog{}, err
		}
		cache.mu.Lock()
		if cache.parsed != nil && cache.sha == head.SHA256 {
			cache.checked = now
			cache.head = head
			loaded := loadedCatalog{record: head, document: *cache.parsed}
			cache.mu.Unlock()
			return loaded, nil
		}
		cache.mu.Unlock()
	}
	record, err := store.CurrentVoucherCatalog(ctx)
	if errors.Is(err, control.ErrVoucherCatalogNotFound) {
		return loadedCatalog{empty: true}, nil
	}
	if err != nil {
		return loadedCatalog{}, err
	}
	document, err := vouchers.ParseDocument(record.Document)
	if err != nil {
		return loadedCatalog{}, fmt.Errorf("stored voucher catalog %s does not parse: %w", record.ID, err)
	}
	if cache != nil {
		cache.mu.Lock()
		cache.checked = now
		cache.head = record
		cache.head.Document = nil
		cache.parsed = &document
		cache.sha = record.SHA256
		cache.mu.Unlock()
	}
	return loadedCatalog{record: record, document: document}, nil
}

// voucherOffers indexes every supplier offer by supplier and card.
type voucherOffers struct {
	byKey map[string]control.VoucherOffer
	// listed: suppliers with at least one offer stored. A card such a
	// supplier no longer lists is not sold; one whose supplier was never read
	// is not judged.
	listed map[string]bool
	// newest is when each supplier's offers were last read (the newest SyncedAt
	// it has); a supplier with no time on its offers is not in it.
	newest map[string]time.Time
	// now is when the relay judges them, and maxAge how old a supplier's offers
	// may be before they stop being believed (0: they never do).
	now    time.Time
	maxAge time.Duration
}

func (s HTTPServer) loadVoucherOffers(ctx context.Context, store control.VoucherStore) (voucherOffers, error) {
	offers, err := store.ListVoucherOffers(ctx, "")
	if err != nil {
		return voucherOffers{}, err
	}
	index := voucherOffers{
		byKey:  map[string]control.VoucherOffer{},
		listed: map[string]bool{},
		newest: map[string]time.Time{},
		now:    s.clock().Now(),
		maxAge: s.Vouchers.offersMaxAge(),
	}
	for _, offer := range offers {
		index.byKey[offer.Supplier+"/"+offer.Ref] = offer
		index.listed[offer.Supplier] = true
		if offer.SyncedAt.After(index.newest[offer.Supplier]) {
			index.newest[offer.Supplier] = offer.SyncedAt
		}
	}
	return index, nil
}

// at is the moment the offers are judged at.
func (o voucherOffers) at() time.Time {
	if o.now.IsZero() {
		return time.Now()
	}
	return o.now
}

// stale reports whether a supplier's offers are too old to believe, and how old
// they are. A supplier whose offers carry no time, or a relay that never reads
// them on a schedule, is never judged stale.
func (o voucherOffers) stale(supplier string) (time.Duration, bool) {
	read, known := o.newest[supplier]
	if o.maxAge <= 0 || !known || o.now.IsZero() {
		return 0, false
	}
	age := o.now.Sub(read)
	return age, age > o.maxAge
}

func (o voucherOffers) offer(ref vouchers.Ref) (control.VoucherOffer, bool) {
	offer, ok := o.byKey[ref.Supplier+"/"+ref.ID]
	return offer, ok
}

// Whether a listed item can be bought now, and from whom, is decided by
// rankSuppliers (vouchers_suppliers.go) from what the relay knows of the item's
// suppliers: configured, still selling the card, in stock, and each one's price
// in dinars within its max_cost. Test mode sells everything.

// handleVoucherRoutes serves everything under /v1/vouchers.
func (s HTTPServer) handleVoucherRoutes(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if strings.HasPrefix(path, "/v1/vouchers/admin/") {
		if !s.RouteMode.allowsAdmin() {
			writeNotFound(w)
			return
		}
		s.withAdmin(w, r, s.handleVoucherAdminRoutes)
		return
	}
	if !s.RouteMode.allowsPublic() {
		writeNotFound(w)
		return
	}
	switch {
	case path == "/v1/vouchers/catalog" && r.Method == http.MethodGet:
		s.handleVoucherCatalog(w, r)
	case strings.HasPrefix(path, "/v1/vouchers/images/") && r.Method == http.MethodGet:
		s.handleVoucherImage(w, r, strings.TrimPrefix(path, "/v1/vouchers/images/"))
	case path == "/v1/vouchers/purchases" && r.Method == http.MethodPost:
		s.handleVoucherPurchase(w, r)
	case strings.HasPrefix(path, "/v1/vouchers/purchases/") && r.Method == http.MethodGet:
		s.handleVoucherPurchaseRead(w, r, strings.TrimPrefix(path, "/v1/vouchers/purchases/"))
	default:
		writeNotFound(w)
	}
}

// requireVouchers answers for a relay that cannot sell cards, and returns the
// store when it can.
func (s HTTPServer) requireVouchers(w http.ResponseWriter) (control.VoucherStore, bool) {
	store, ok := s.voucherStore()
	if !ok {
		writeSMSError(w, http.StatusServiceUnavailable, voucherCodeUnavailable, "vouchers are not supported by this relay's store", nil)
		return nil, false
	}
	if !s.Vouchers.Configured() {
		writeSMSError(w, http.StatusServiceUnavailable, voucherCodeUnconfigured, "this relay sells no cards", nil)
		return nil, false
	}
	return store, true
}

// handleVoucherCatalog serves GET /v1/vouchers/catalog.
func (s HTTPServer) handleVoucherCatalog(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireVouchers(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	view, err := s.voucherShopView(ctx, store)
	if err != nil {
		s.logger().Error("voucher catalog read failed", "installation_id", installation.ID, "error", err)
		writeSMSError(w, http.StatusInternalServerError, voucherCodeInternalError, "relay store failed", nil)
		return
	}
	etag := `"` + view.Version + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, no-cache")
	if match := strings.TrimSpace(r.Header.Get("If-None-Match")); match != "" && match == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	writeJSON(w, http.StatusOK, view)
}

func (s HTTPServer) voucherShopView(ctx context.Context, store control.VoucherStore) (vouchers.ShopView, error) {
	loaded, err := s.currentVoucherCatalog(ctx, store)
	if err != nil {
		return vouchers.ShopView{}, err
	}
	now := s.clock().Now()
	if loaded.empty {
		return vouchers.Shop(vouchers.Document{}, "", now, s.Vouchers.MarksTest(), nil), nil
	}
	offers, err := s.loadVoucherOffers(ctx, store)
	if err != nil {
		return vouchers.ShopView{}, err
	}
	settings, err := s.voucherSettingsForCards(ctx, store)
	if err != nil {
		return vouchers.ShopView{}, err
	}
	document := s.autoPricedDocument(loaded.document, offers, settings)
	return vouchers.Shop(document, loaded.record.SHA256, now, s.Vouchers.MarksTest(), s.voucherAvailability(offers, settings)), nil
}

// handleVoucherImage serves GET /v1/vouchers/images/{sha256}.
func (s HTTPServer) handleVoucherImage(w http.ResponseWriter, r *http.Request, sum string) {
	store, ok := s.voucherStore()
	if !ok {
		writeNotFound(w)
		return
	}
	if _, _, ok := s.authenticateInstallation(w, r); !ok {
		return
	}
	s.writeVoucherImage(w, r, store, sum)
}

// writeVoucherImage answers with one stored logo or flag; the caller has
// authorized the request (a shop's token, or the admin's).
func (s HTTPServer) writeVoucherImage(w http.ResponseWriter, r *http.Request, store control.VoucherStore, sum string) {
	sum = strings.TrimPrefix(strings.ToLower(strings.TrimSpace(sum)), vouchers.ImagePrefix)
	image, err := store.GetVoucherImage(r.Context(), sum)
	if errors.Is(err, control.ErrVoucherImageNotFound) {
		writeNotFound(w)
		return
	}
	if err != nil {
		s.logger().Error("voucher image read failed", "sha256", sum, "error", err)
		writeSMSError(w, http.StatusInternalServerError, voucherCodeInternalError, "relay store failed", nil)
		return
	}
	w.Header().Set("Content-Type", image.ContentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(image.Data)))
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Header().Set("ETag", `"`+image.SHA256+`"`)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(image.Data)
}

type voucherPurchaseRequest struct {
	Item           string          `json:"item"`
	Quantity       int             `json:"quantity"`
	IdempotencyKey string          `json:"idempotency_key"`
	MaxUnitPrice   json.RawMessage `json:"max_unit_price"`
	RequestedBy    string          `json:"requested_by"`
	maxUnitPrice   *big.Rat
}

func decodeVoucherPurchase(w http.ResponseWriter, r *http.Request) (voucherPurchaseRequest, bool) {
	var request voucherPurchaseRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxVoucherRequestBytes)).Decode(&request); err != nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "invalid request body", nil)
		return voucherPurchaseRequest{}, false
	}
	request.Item = strings.TrimSpace(request.Item)
	request.IdempotencyKey = strings.TrimSpace(request.IdempotencyKey)
	request.RequestedBy = strings.TrimSpace(request.RequestedBy)
	if utf8.RuneCountInString(request.RequestedBy) > maxWalletRequestedByRunes {
		request.RequestedBy = string([]rune(request.RequestedBy)[:maxWalletRequestedByRunes])
	}
	if request.Item == "" {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "item is required", nil)
		return voucherPurchaseRequest{}, false
	}
	if request.IdempotencyKey == "" || utf8.RuneCountInString(request.IdempotencyKey) > maxVoucherKeyRunes {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest,
			fmt.Sprintf("idempotency_key is required (at most %d characters)", maxVoucherKeyRunes), nil)
		return voucherPurchaseRequest{}, false
	}
	if request.Quantity == 0 {
		request.Quantity = 1
	}
	if request.Quantity < 1 || request.Quantity > maxVoucherQuantity {
		writeSMSError(w, http.StatusUnprocessableEntity, voucherCodeInvalidQuantity,
			fmt.Sprintf("quantity must be 1 to %d", maxVoucherQuantity), map[string]any{"max_quantity": maxVoucherQuantity})
		return voucherPurchaseRequest{}, false
	}
	if raw := strings.TrimSpace(string(request.MaxUnitPrice)); raw != "" && raw != "null" {
		if unquoted, err := strconv.Unquote(raw); err == nil {
			raw = strings.TrimSpace(unquoted)
		}
		value, err := control.ParseWalletAmount(raw)
		if err != nil || value.Sign() <= 0 {
			writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "max_unit_price must be a positive amount", nil)
			return voucherPurchaseRequest{}, false
		}
		request.maxUnitPrice = value
	}
	return request, true
}

// enforceVoucherRateLimit is the per-shop burst guard. It fails open, like
// SMS: the balance is what limits spending, not Redis.
func (s HTTPServer) enforceVoucherRateLimit(w http.ResponseWriter, r *http.Request, installationID string) bool {
	policy := s.Vouchers.RateLimit
	if !policy.Enabled() || s.RateLimiter == nil {
		return false
	}
	decision, err := s.RateLimiter.Allow(r.Context(), "voucher-purchase:"+installationID, policy)
	if err != nil {
		s.metrics().RecordRateLimitFailed()
		s.logger().Error("voucher rate limiter failed; allowing the purchase", "installation_id", installationID, "error", err)
		return false
	}
	if decision.Allowed {
		return false
	}
	s.metrics().RecordRateLimitRejected()
	w.Header().Set("Retry-After", retryAfterSeconds(decision.ResetAt, s.clock().Now()))
	writeSMSError(w, http.StatusTooManyRequests, voucherCodeRateLimited, "too many card purchases; retry shortly", nil)
	return true
}

// handleVoucherPurchase serves POST /v1/vouchers/purchases: one shop buys
// cards of one item. The price is held from its voucher balance in the same
// step as the claim, then the cheapest supplier is called once; only when it
// definitely sold nothing is the next one tried (see buyFromSuppliers).
func (s HTTPServer) handleVoucherPurchase(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireVouchers(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	request, ok := decodeVoucherPurchase(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	if existing, found, err := store.FindVoucherPurchaseByKey(ctx, installation.ID, request.IdempotencyKey); err != nil {
		s.writeVoucherInternalError(w, installation.ID, "voucher purchase lookup failed", err)
		return
	} else if found {
		s.replayVoucherPurchase(w, r, store, existing)
		return
	}
	if s.enforceVoucherRateLimit(w, r, installation.ID) {
		return
	}

	loaded, err := s.currentVoucherCatalog(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, installation.ID, "voucher catalog read failed", err)
		return
	}
	located, found := vouchers.Find(loaded.document, request.Item)
	if loaded.empty || !found {
		writeSMSError(w, http.StatusNotFound, voucherCodeUnknownItem, "no such card in the catalog", nil)
		return
	}
	offers, err := s.loadVoucherOffers(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, installation.ID, "voucher offers read failed", err)
		return
	}
	settings, err := s.voucherSettingsForCards(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, installation.ID, "voucher settings read failed", err)
		return
	}
	// An auto-priced card is charged at the price the shop was listed.
	if priced, ok := vouchers.Find(s.autoPricedDocument(loaded.document, offers, settings), request.Item); ok {
		located = priced
	}
	ranking := s.Vouchers.rankSuppliers(located, offers, settings)
	if reason, notify := ranking.unavailable(); reason != "" {
		if notify {
			s.logger().Warn("a card was refused for its supplier", "item", located.Item.Key, "reason", reason)
		}
		writeSMSError(w, http.StatusConflict, voucherCodeItemUnavailable, reason, nil)
		return
	}
	first := ranking.Candidates[0]
	now := s.clock().Now()
	unitPrice, priced := vouchers.ChargePrice(located.Item, now, request.maxUnitPrice)
	if !priced {
		current := vouchers.PriceAt(located.Item, now).UnitPrice
		writeSMSError(w, http.StatusConflict, voucherCodePriceChanged,
			"the card costs more than the shop was quoted", map[string]any{"unit_price": control.NormalizeWalletAmount(current)})
		return
	}

	claim, created, err := store.BeginVoucherPurchase(ctx, control.VoucherPurchase{
		InstallationID: installation.ID,
		IdempotencyKey: request.IdempotencyKey,
		ItemKey:        located.Item.Key,
		BrandKey:       located.Brand.Key,
		ItemName:       located.Name(),
		Quantity:       request.Quantity,
		UnitPrice:      control.FormatWalletAmount(unitPrice),
		Supplier:       first.Supplier.Key(),
		SupplierRef:    first.Ref.ID,
		TestMode:       s.Vouchers.MarksTest(),
		RequestedBy:    request.RequestedBy,
	})
	var balanceErr *control.WalletBalanceError
	switch {
	case errors.As(err, &balanceErr):
		writeSMSError(w, http.StatusPaymentRequired, voucherCodeInsufficientBalance,
			"the voucher balance cannot pay for this card", map[string]any{
				"balance": control.NormalizeWalletAmount(balanceErr.Balance),
				"amount":  control.NormalizeWalletAmount(balanceErr.Amount),
			})
		return
	case errors.Is(err, control.ErrNotFound):
		writeSMSError(w, http.StatusNotFound, voucherCodeNotFound, "installation not found", nil)
		return
	case err != nil:
		s.writeVoucherInternalError(w, installation.ID, "voucher purchase claim failed", err)
		return
	case !created:
		s.replayVoucherPurchase(w, r, store, claim)
		return
	}

	// --- past this line the supplier may sell the cards, whatever happens ---
	detached := context.WithoutCancel(ctx)
	attempt := s.buyFromSuppliers(detached, store, claim, ranking.Candidates, request.Quantity)
	claim, buyErr := attempt.Claim, attempt.Err
	outcome, codes := voucherOutcome(attempt.Bought, buyErr, request.Quantity)
	outcome = attempt.withAttempts(outcome)
	finished, applied, err := store.FinishVoucherPurchase(detached, claim.ID, outcome)
	if err != nil {
		// The supplier's answer is in hand but could not be written down. The
		// row stays pending, so the reconciler finds the order again; the
		// shop gets the codes now either way.
		s.logger().Error("recording a voucher purchase failed",
			"installation_id", installation.ID, "purchase_id", claim.ID,
			"supplier_order_id", outcome.SupplierOrderID, "status", outcome.Status, "error", err)
		finished = claim
		if outcome.Status == control.VoucherPurchaseSucceeded {
			finished.Status = control.VoucherPurchaseSucceeded
		}
	} else if !applied {
		s.logger().Warn("a voucher purchase was settled before its own answer was recorded",
			"purchase_id", claim.ID, "status", finished.Status)
	}
	s.logVoucherPurchase(installation.ID, finished, outcome, buyErr,
		"suppliers_tried", attempt.summary(), "suppliers_skipped", ranking.skipped())
	balance := s.voucherBalance(detached, installation.ID)
	switch {
	case finished.Status == control.VoucherPurchaseSucceeded && len(codes) > 0:
		writeJSON(w, http.StatusCreated, s.voucherPurchaseBody(finished, codes, false, balance, false))
	case finished.Status == control.VoucherPurchaseFailed:
		writeJSON(w, http.StatusBadGateway, s.voucherFailureBody(finished, balance, false))
	default:
		// Bought or not, nobody knows yet: the price stays held.
		writeJSON(w, http.StatusAccepted, s.voucherPurchaseBody(finished, codes, len(codes) == 0, balance, false))
	}
}

// voucherOutcome turns a supplier's answer into the ledger's outcome, and the
// codes to hand the shop.
func voucherOutcome(bought vouchers.Purchase, err error, quantity int) (control.VoucherPurchaseOutcome, []vouchers.Code) {
	if err == nil {
		outcome := control.VoucherPurchaseOutcome{
			SupplierOrderID:  bought.OrderID,
			SupplierCost:     bought.Cost,
			SupplierCurrency: bought.Currency,
		}
		if bought.Status == vouchers.StatusSucceeded && len(bought.Codes) >= quantity {
			outcome.Status = control.VoucherPurchaseSucceeded
			return outcome, bought.Codes
		}
		// Taken, but not every code came back: the order is read back until
		// it settles.
		outcome.Status = control.VoucherPurchaseFailed
		outcome.Uncertain = true
		outcome.ErrorCode = vouchers.FailureUnknown
		outcome.ErrorDetail = "the supplier took the order without handing back every code"
		return outcome, nil
	}
	var failure *vouchers.Failure
	if !errors.As(err, &failure) {
		failure = &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: err.Error()}
	}
	return control.VoucherPurchaseOutcome{
		Status:          control.VoucherPurchaseFailed,
		SupplierOrderID: failure.OrderID,
		ErrorCode:       failure.Code,
		ErrorDetail:     failure.Detail,
		Uncertain:       !failure.Definite,
	}, nil
}

// replayVoucherPurchase answers a request whose key already has a row.
func (s HTTPServer) replayVoucherPurchase(
	w http.ResponseWriter,
	r *http.Request,
	store control.VoucherStore,
	purchase control.VoucherPurchase,
) {
	if control.NormalizeVoucherKind(purchase.Kind) != control.VoucherKindCard {
		// The key names a top-up or a bill payment, not a card: it was used for
		// something else.
		writeSMSError(w, http.StatusConflict, "idempotency_key_reused",
			"this idempotency key was used for a different purchase", map[string]any{"id": purchase.ID})
		return
	}
	now := s.clock().Now()
	ctx := context.WithoutCancel(r.Context())
	if purchase.Status == control.VoucherPurchasePending && purchase.HeldSince == nil &&
		now.Sub(purchase.CreatedAt) < s.Vouchers.staleAfter() {
		w.Header().Set("Retry-After", retryAfterSeconds(purchase.CreatedAt.Add(s.Vouchers.requestTimeout()), now))
		writeSMSError(w, http.StatusConflict, voucherCodeInFlight,
			"this purchase is being made right now; retry shortly", map[string]any{"id": purchase.ID})
		return
	}
	if purchase.Status == control.VoucherPurchasePending {
		if checked, _, err := s.checkVoucherPurchase(ctx, store, purchase); err == nil {
			purchase = checked
		}
	}
	s.answerStoredVoucherPurchase(w, ctx, purchase, true)
}

// handleVoucherPurchaseRead serves GET /v1/vouchers/purchases/{key}: the shop
// reading back a purchase whose answer it lost or that was still open.
func (s HTTPServer) handleVoucherPurchaseRead(w http.ResponseWriter, r *http.Request, key string) {
	store, ok := s.voucherStore()
	if !ok {
		writeSMSError(w, http.StatusServiceUnavailable, voucherCodeUnavailable, "vouchers are not supported by this relay's store", nil)
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	purchase, found, err := store.FindVoucherPurchaseByKey(r.Context(), installation.ID, strings.TrimSpace(key))
	if err != nil {
		s.writeVoucherInternalError(w, installation.ID, "voucher purchase lookup failed", err)
		return
	}
	if !found {
		writeSMSError(w, http.StatusNotFound, voucherCodeNotFound, "no purchase with this key", nil)
		return
	}
	if control.NormalizeVoucherKind(purchase.Kind) != control.VoucherKindCard {
		// A top-up or a bill payment: read back with its receipt, not its codes.
		s.readServiceOrder(w, r, store, purchase)
		return
	}
	ctx := context.WithoutCancel(r.Context())
	if purchase.Status == control.VoucherPurchasePending &&
		(purchase.HeldSince != nil || s.clock().Now().Sub(purchase.CreatedAt) >= s.Vouchers.staleAfter()) {
		if checked, _, err := s.checkVoucherPurchase(ctx, store, purchase); err == nil {
			purchase = checked
		}
	}
	balance := s.voucherBalance(ctx, installation.ID)
	codes, pending := s.voucherCodes(ctx, purchase)
	writeJSON(w, http.StatusOK, s.voucherPurchaseBody(purchase, codes, pending, balance, false))
}

// answerStoredVoucherPurchase answers a replay with the row as it stands.
func (s HTTPServer) answerStoredVoucherPurchase(w http.ResponseWriter, ctx context.Context, purchase control.VoucherPurchase, replayed bool) {
	balance := s.voucherBalance(ctx, purchase.InstallationID)
	switch purchase.Status {
	case control.VoucherPurchaseFailed:
		writeJSON(w, http.StatusBadGateway, s.voucherFailureBody(purchase, balance, replayed))
	case control.VoucherPurchaseSucceeded:
		codes, pending := s.voucherCodes(ctx, purchase)
		status := http.StatusOK
		if pending {
			status = http.StatusAccepted
		}
		writeJSON(w, status, s.voucherPurchaseBody(purchase, codes, pending, balance, replayed))
	default:
		writeJSON(w, http.StatusAccepted, s.voucherPurchaseBody(purchase, nil, true, balance, replayed))
	}
}

// voucherCodes reads a succeeded purchase's codes back from its supplier.
// pending is true when they could not be read right now.
func (s HTTPServer) voucherCodes(ctx context.Context, purchase control.VoucherPurchase) ([]vouchers.Code, bool) {
	if purchase.Status != control.VoucherPurchaseSucceeded {
		return nil, purchase.Status == control.VoucherPurchasePending
	}
	supplier, ok := s.Vouchers.supplierByKey(purchase.Supplier)
	if !ok || purchase.SupplierOrderID == "" {
		return nil, true
	}
	lookupCtx, cancel := context.WithTimeout(ctx, voucherCodesLookupBudget)
	defer cancel()
	order, err := supplier.Lookup(lookupCtx, vouchers.Ref{Supplier: purchase.Supplier, ID: purchase.SupplierRef}, purchase.SupplierOrderID)
	if err != nil || len(order.Codes) == 0 {
		if err != nil {
			s.logger().Warn("reading a voucher purchase's codes back failed",
				"purchase_id", purchase.ID, "supplier_order_id", purchase.SupplierOrderID, "error", err)
		}
		return nil, true
	}
	return order.Codes, false
}

// voucherPurchaseBody is a purchase as the shop reads it.
func (s HTTPServer) voucherPurchaseBody(
	purchase control.VoucherPurchase,
	codes []vouchers.Code,
	codesPending bool,
	balance string,
	replayed bool,
) map[string]any {
	return map[string]any{
		"purchase": voucherPurchasePayload(purchase, codes, codesPending),
		"balance":  balance,
		"replayed": replayed,
	}
}

func (s HTTPServer) voucherFailureBody(purchase control.VoucherPurchase, balance string, replayed bool) map[string]any {
	code := purchase.ErrorCode
	if code == "" {
		code = vouchers.FailureRefused
	}
	return map[string]any{
		"error":    "the card could not be bought",
		"code":     shopFailureCode(code),
		"detail":   shopFailureDetail(code, purchase.ErrorDetail),
		"purchase": voucherPurchasePayload(purchase, nil, false),
		"balance":  balance,
		"replayed": replayed,
	}
}

func voucherPurchasePayload(purchase control.VoucherPurchase, codes []vouchers.Code, codesPending bool) map[string]any {
	if codes == nil {
		codes = []vouchers.Code{}
	}
	detail := shopFailureDetail(purchase.ErrorCode, purchase.ErrorDetail)
	if purchase.Status == control.VoucherPurchaseSucceeded {
		// How the reconciler settled it is the relay's business, not a shop's.
		detail = ""
	}
	return map[string]any{
		"id":              purchase.ID,
		"idempotency_key": purchase.IdempotencyKey,
		"kind":            control.NormalizeVoucherKind(purchase.Kind),
		"target":          purchase.Target,
		"item":            purchase.ItemKey,
		"brand":           purchase.BrandKey,
		"name":            purchase.ItemName,
		"quantity":        purchase.Quantity,
		"unit_price":      purchase.UnitPrice,
		"amount":          purchase.Amount,
		"status":          purchase.Status,
		"held":            purchase.HeldSince != nil,
		"error_code":      shopFailureCode(purchase.ErrorCode),
		"error_detail":    detail,
		"codes":           codes,
		"codes_pending":   codesPending,
		"test_mode":       purchase.TestMode,
		"created_at":      purchase.CreatedAt,
		"completed_at":    purchase.CompletedAt,
	}
}

// voucherBalance reads the shop's voucher balance for an answer; a failed
// read leaves it out rather than failing a purchase already made.
func (s HTTPServer) voucherBalance(ctx context.Context, installationID string) string {
	store, ok := s.walletStore()
	if !ok {
		return ""
	}
	wallet, err := store.GetWalletAccount(ctx, installationID, control.WalletAccountVouchers)
	if err != nil {
		s.logger().Warn("voucher balance read failed", "installation_id", installationID, "error", err)
		return ""
	}
	return wallet.Balance
}

// voucherWalletPayload is the voucher balance on the wallet summary.
func (s HTTPServer) voucherWalletPayload(balance string) map[string]any {
	return map[string]any{
		"balance":    control.NormalizeWalletAmount(balance),
		"configured": s.Vouchers.Configured(),
		"test_mode":  s.Vouchers.MarksTest(),
	}
}

func (s HTTPServer) writeVoucherInternalError(w http.ResponseWriter, installationID, message string, err error) {
	s.logger().Error(message, "installation_id", installationID, "error", err)
	writeSMSError(w, http.StatusInternalServerError, voucherCodeInternalError, "relay store failed", nil)
}

// logVoucherPurchase writes the one line a card purchase leaves in the log.
// supplier is the one that served it, or answered last; extra adds key/value
// pairs (the suppliers tried and the ones skipped).
func (s HTTPServer) logVoucherPurchase(
	installationID string,
	purchase control.VoucherPurchase,
	outcome control.VoucherPurchaseOutcome,
	buyErr error,
	extra ...any,
) {
	attrs := []any{
		"installation_id", installationID,
		"purchase_id", purchase.ID,
		"item", purchase.ItemKey,
		"quantity", purchase.Quantity,
		"amount", purchase.Amount,
		"supplier", purchase.Supplier,
		"supplier_order_id", outcome.SupplierOrderID,
		"status", purchase.Status,
		"held", purchase.HeldSince != nil,
		"test_mode", purchase.TestMode,
	}
	attrs = append(attrs, extra...)
	if buyErr != nil {
		attrs = append(attrs, "error", buyErr.Error())
	}
	switch {
	case outcome.ErrorCode == vouchers.FailureCredit || outcome.ErrorCode == vouchers.FailureUnauthorized:
		// The company's own account is the problem: every shop is refused
		// until somebody tops BN Plus up or fixes the credentials.
		s.logger().Error("a card purchase failed on the company's supplier account", attrs...)
	case purchase.Status == control.VoucherPurchaseFailed:
		s.logger().Warn("a card purchase failed and was refunded", attrs...)
	case purchase.Status == control.VoucherPurchasePending:
		s.logger().Warn("a card purchase has no clear outcome; its price is held", attrs...)
	default:
		s.logger().Info("a card was bought", attrs...)
	}
}

// checkVoucherPurchase asks the supplier what became of a pending purchase
// and settles it when the answer is clear. It returns the row as it now
// stands and a word on what happened.
func (s HTTPServer) checkVoucherPurchase(
	ctx context.Context,
	store control.VoucherStore,
	purchase control.VoucherPurchase,
) (control.VoucherPurchase, string, error) {
	if purchase.Status != control.VoucherPurchasePending {
		return purchase, "settled", nil
	}
	if control.NormalizeVoucherKind(purchase.Kind) != control.VoucherKindCard {
		return s.checkServiceOrder(ctx, store, purchase)
	}
	supplier, ok := s.Vouchers.supplierByKey(purchase.Supplier)
	if !ok {
		return purchase, "supplier_unconfigured", nil
	}
	now := s.clock().Now()
	age := now.Sub(purchase.CreatedAt)
	ref := vouchers.Ref{Supplier: purchase.Supplier, ID: purchase.SupplierRef}
	if offers, err := store.ListVoucherOffers(ctx, purchase.Supplier); err == nil {
		for _, offer := range offers {
			if offer.Ref == purchase.SupplierRef {
				ref.Name = offer.Name
				break
			}
		}
	}
	callCtx, cancel := context.WithTimeout(ctx, s.Vouchers.requestTimeout())
	defer cancel()

	needsPerson := func(reason string) {
		if age >= voucherOperatorAfter {
			s.logger().Error("a card purchase is still unresolved; settle it with pointy-relay vouchers resolve",
				"purchase_id", purchase.ID, "installation_id", purchase.InstallationID,
				"supplier_order_id", purchase.SupplierOrderID, "age", age.Round(time.Minute).String(), "reason", reason)
		}
	}

	if purchase.SupplierOrderID != "" {
		order, err := supplier.Lookup(callCtx, ref, purchase.SupplierOrderID)
		if err != nil {
			needsPerson("the supplier could not be read: " + err.Error())
			return purchase, "unreadable", err
		}
		switch {
		case order.Status == vouchers.StatusSucceeded && len(order.Codes) >= purchase.Quantity:
			return s.resolveVoucherPurchase(ctx, store, purchase, control.VoucherPurchaseResolution{
				Found:            true,
				SupplierOrderID:  purchase.SupplierOrderID,
				SupplierCost:     order.Cost,
				SupplierCurrency: order.Currency,
				Detail:           "the supplier's order shows it was bought",
			})
		case order.Status == vouchers.StatusFailed:
			return s.resolveVoucherPurchase(ctx, store, purchase, control.VoucherPurchaseResolution{
				Found:           false,
				SupplierOrderID: purchase.SupplierOrderID,
				Detail:          strings.TrimSpace("the supplier failed the order " + order.Message),
			})
		}
		needsPerson("the supplier's order is still open")
		return purchase, "open", nil
	}

	from := purchase.CreatedAt.Add(-voucherSearchBefore)
	to := purchase.CreatedAt.Add(s.Vouchers.requestTimeout() + voucherSearchAfter)
	var candidates []vouchers.Purchase
	var err error
	finder, exact := supplier.(vouchers.RefFinder)
	if exact {
		// The supplier records the reference the purchase was placed with (its
		// id), so ask for exactly that order instead of guessing by card,
		// quantity and time.
		candidates, err = finder.FindByClientRef(callCtx, ref, purchase.ID, from, to)
	} else {
		candidates, err = supplier.Find(callCtx, ref, purchase.Quantity, from, to)
	}
	if err != nil {
		needsPerson("the supplier's history could not be read: " + err.Error())
		return purchase, "unreadable", err
	}
	ids := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		ids = append(ids, candidate.OrderID)
	}
	claimed, err := store.VoucherClaimedSupplierOrders(ctx, purchase.Supplier, ids)
	if err != nil {
		return purchase, "unreadable", err
	}
	if exact {
		// Every order under the purchase's own reference is this purchase's, so
		// they are weighed together: a FAILED one listed first must not refund a
		// card another, paid, order delivered.
		var orders []vouchers.Purchase
		for _, candidate := range candidates {
			if candidate.OrderID != "" && !claimed[candidate.OrderID] {
				orders = append(orders, candidate)
			}
		}
		if len(orders) > 0 {
			return s.settleByReference(ctx, store, purchase, orders, needsPerson)
		}
	} else {
		for _, candidate := range candidates {
			if candidate.OrderID == "" || claimed[candidate.OrderID] {
				continue
			}
			switch candidate.Status {
			case vouchers.StatusSucceeded:
				return s.resolveVoucherPurchase(ctx, store, purchase, control.VoucherPurchaseResolution{
					Found:            true,
					SupplierOrderID:  candidate.OrderID,
					SupplierCost:     candidate.Cost,
					SupplierCurrency: candidate.Currency,
					Detail:           "found in the supplier's order history",
				})
			case vouchers.StatusFailed:
				return s.resolveVoucherPurchase(ctx, store, purchase, control.VoucherPurchaseResolution{
					Found:           false,
					SupplierOrderID: candidate.OrderID,
					Detail:          strings.TrimSpace("the supplier failed the order " + candidate.Message),
				})
			}
			// Found but still open at the supplier: ask again next time.
			needsPerson("the supplier's order is still open")
			return purchase, "open", nil
		}
	}
	if age < voucherAbsentAfter {
		return purchase, "waiting", nil
	}
	return s.resolveVoucherPurchase(ctx, store, purchase, control.VoucherPurchaseResolution{
		Found:  false,
		Detail: "not in the supplier's order history",
	})
}

// settleByReference decides a purchase from the orders a supplier holds under
// its own reference (normally one):
//
//   - exactly one PAID order: the card was bought, whatever else is listed;
//   - two or more PAID orders: the company bought the card twice. Nothing is
//     settled by guess: the purchase stays held and an ERROR asks for the
//     operator, who keeps one (vouchers resolve --found) and recovers the other;
//   - none paid but one still open: ask again next time;
//   - every order ended without delivering anything: refunded.
func (s HTTPServer) settleByReference(
	ctx context.Context,
	store control.VoucherStore,
	purchase control.VoucherPurchase,
	orders []vouchers.Purchase,
	needsPerson func(string),
) (control.VoucherPurchase, string, error) {
	var paid, open, failed []vouchers.Purchase
	for _, order := range orders {
		switch order.Status {
		case vouchers.StatusSucceeded:
			paid = append(paid, order)
		case vouchers.StatusFailed:
			failed = append(failed, order)
		default:
			open = append(open, order)
		}
	}
	if len(orders) > 1 {
		ids := make([]string, 0, len(orders))
		for _, order := range orders {
			ids = append(ids, order.OrderID+"="+string(order.Status))
		}
		level := s.logger().Warn
		if len(paid) > 1 {
			level = s.logger().Error
		}
		level("a supplier holds several orders for one card purchase",
			"purchase_id", purchase.ID, "supplier", purchase.Supplier, "orders", strings.Join(ids, ","))
	}
	switch {
	case len(paid) > 1:
		needsPerson("the supplier holds several paid orders for it")
		s.logger().Error("a card was bought more than once for one purchase; the purchase stays held: keep one order "+
			"(pointy-relay vouchers resolve <purchase> --found <order id> --reason ...) and recover the others from the supplier",
			"purchase_id", purchase.ID, "installation_id", purchase.InstallationID, "supplier", purchase.Supplier, "paid_orders", len(paid))
		return purchase, "duplicate", nil
	case len(paid) == 1:
		return s.resolveVoucherPurchase(ctx, store, purchase, control.VoucherPurchaseResolution{
			Found:            true,
			SupplierOrderID:  paid[0].OrderID,
			SupplierCost:     paid[0].Cost,
			SupplierCurrency: paid[0].Currency,
			Detail:           "found in the supplier's order history",
		})
	case len(open) > 0:
		// Found but still open at the supplier: ask again next time.
		needsPerson("the supplier's order is still open")
		return purchase, "open", nil
	}
	return s.resolveVoucherPurchase(ctx, store, purchase, control.VoucherPurchaseResolution{
		Found:           false,
		SupplierOrderID: failed[0].OrderID,
		Detail:          strings.TrimSpace("the supplier failed the order " + failed[0].Message),
	})
}

func (s HTTPServer) resolveVoucherPurchase(
	ctx context.Context,
	store control.VoucherStore,
	purchase control.VoucherPurchase,
	resolution control.VoucherPurchaseResolution,
) (control.VoucherPurchase, string, error) {
	resolved, applied, err := store.ResolveVoucherPurchase(ctx, purchase.ID, resolution)
	if err != nil {
		if errors.Is(err, control.ErrVoucherOrderClaimed) {
			s.logger().Error("a supplier order matched two card purchases; settle by hand",
				"purchase_id", purchase.ID, "supplier_order_id", resolution.SupplierOrderID)
		}
		return purchase, "unrecorded", err
	}
	if !applied {
		return resolved, "settled", nil
	}
	verdict := "refunded"
	if resolved.Status == control.VoucherPurchaseSucceeded {
		verdict = "bought"
	}
	s.logger().Info("a held card purchase was settled",
		"purchase_id", resolved.ID, "installation_id", resolved.InstallationID,
		"verdict", verdict, "supplier_order_id", resolved.SupplierOrderID, "detail", resolution.Detail)
	return resolved, verdict, nil
}
