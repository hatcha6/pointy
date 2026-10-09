package control

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// The company's own card shop keeps four things here: the catalog the
// operator publishes (every version, the newest one current), the images it
// references (content-addressed), what each supplier sells and at what price
// (read by the offer sync), and one ledger row per purchase.
//
// A purchase is the SMS ledger's shape again. Its row is claimed — and its
// price taken from the shop's voucher balance — in one step BEFORE the
// supplier is called, so a relay that dies mid-call leaves evidence rather
// than a card nobody paid for. The supplier's answer then settles it:
// succeeded keeps the charge; a refusal gives it back; an answer that leaves
// it open whether the card was bought keeps it held until the supplier's own
// records say. The relay keeps no codes: the shop's backend does, and the
// supplier can always hand them back again for an order it names.

// The same ledger carries what else the company sells from its own supplier
// accounts: credit sent straight to a phone number abroad and bill payments
// (a purchase's Kind). Those are one row each, bought from one supplier, with
// the masked recipient in Target and a small JSON object of what was ordered in
// Details. The pricing knobs that turn the supplier's dollars into dinars are
// published like catalogs (VoucherSettingsRecord): every version kept, the
// newest current.

// Voucher purchase statuses. A row leaves pending exactly once.
const (
	VoucherPurchasePending   = "pending"
	VoucherPurchaseSucceeded = "succeeded"
	VoucherPurchaseFailed    = "failed"
)

// Voucher purchase kinds. A row written before purchases had a kind is a card,
// and an empty kind means card everywhere.
const (
	VoucherKindCard    = "card"
	VoucherKindAirtime = "airtime"
	VoucherKindBill    = "bill"
)

// maxVoucherDetailsBytes bounds a purchase's Details: a ledger row is not a
// document store.
const maxVoucherDetailsBytes = 4 << 10

var (
	ErrVoucherCatalogNotFound  = errors.New("no voucher catalog has been published")
	ErrVoucherSettingsNotFound = errors.New("no voucher settings have been published")
	ErrVoucherImageNotFound    = errors.New("voucher image not found")
	ErrVoucherPurchaseNotFound = errors.New("voucher purchase not found")
	// ErrVoucherOrderClaimed refuses to settle a purchase on a supplier order
	// another purchase already holds: one order is one customer's cards.
	ErrVoucherOrderClaimed = errors.New("the supplier order already settles another purchase")
	errVouchersUnsupported = errors.New("vouchers are not supported by the underlying store")
)

// VoucherCatalog is one published version of the catalog. Document is the
// normalized JSON the vouchers package reads; SHA256 fingerprints it.
type VoucherCatalog struct {
	ID        string          `json:"id"`
	SHA256    string          `json:"sha256"`
	Document  json.RawMessage `json:"document,omitempty"`
	Actor     string          `json:"actor,omitempty"`
	Note      string          `json:"note,omitempty"`
	CreatedAt time.Time       `json:"created_at"`
}

// VoucherSettingsRecord is one published version of the pricing settings, kept
// like a catalog: every version stays, the newest is current. Document is the
// normalized JSON the vouchers package reads (control never looks inside it);
// SHA256 fingerprints it.
type VoucherSettingsRecord struct {
	ID        string          `json:"id"`
	SHA256    string          `json:"sha256"`
	Document  json.RawMessage `json:"document,omitempty"`
	Actor     string          `json:"actor,omitempty"`
	Note      string          `json:"note,omitempty"`
	CreatedAt time.Time       `json:"created_at"`
}

// VoucherImage is an uploaded logo or flag, named by its SHA-256.
type VoucherImage struct {
	SHA256      string    `json:"sha256"`
	ContentType string    `json:"content_type"`
	Data        []byte    `json:"data,omitempty"`
	Width       int       `json:"width"`
	Height      int       `json:"height"`
	CreatedAt   time.Time `json:"created_at"`
}

// VoucherOffer is one card a supplier sells the company, as last read.
type VoucherOffer struct {
	Supplier string    `json:"supplier"`
	Ref      string    `json:"ref"`
	Name     string    `json:"name"`
	Group    string    `json:"group,omitempty"`
	Price    string    `json:"price"`
	Currency string    `json:"currency"`
	InStock  bool      `json:"in_stock"`
	SyncedAt time.Time `json:"synced_at"`
}

// VoucherPurchase is one ledger row: one shop buying cards of one item.
type VoucherPurchase struct {
	ID             string `json:"id"`
	InstallationID string `json:"installation_id"`
	// ShopName is filled by listings for the operator; it is not stored.
	ShopName       string `json:"shop_name,omitempty"`
	IdempotencyKey string `json:"idempotency_key"`
	// Kind is what was bought: a card, direct airtime or a bill payment. Empty
	// means card (a row written before purchases had a kind); stores normalize
	// it on write and on read.
	Kind     string `json:"kind"`
	ItemKey  string `json:"item"`
	BrandKey string `json:"brand"`
	// ItemName is the item as the statement names it, frozen at purchase.
	ItemName string `json:"name"`
	Quantity int    `json:"quantity"`
	// Target is who the purchase was for, MASKED by the caller (a phone number
	// or an account: "+223•••••456"). The full value is never stored here.
	Target string `json:"target,omitempty"`
	// Details is a small JSON object of what was ordered (an airtime order's
	// operator and amount, say), filled once when the purchase is claimed.
	Details json.RawMessage `json:"details,omitempty"`
	// UnitPrice and Amount are what the shop pays, in dinars.
	UnitPrice string `json:"unit_price"`
	Amount    string `json:"amount"`
	// Supplier and SupplierRef are where the cards come from; SupplierOrderID
	// is the supplier's order once known, and SupplierCost what it charged
	// the company, in SupplierCurrency.
	Supplier         string     `json:"supplier"`
	SupplierRef      string     `json:"supplier_ref"`
	SupplierOrderID  string     `json:"supplier_order_id,omitempty"`
	SupplierCost     string     `json:"supplier_cost,omitempty"`
	SupplierCurrency string     `json:"supplier_currency,omitempty"`
	Status           string     `json:"status"`
	ErrorCode        string     `json:"error_code,omitempty"`
	ErrorDetail      string     `json:"error_detail,omitempty"`
	TestMode         bool       `json:"test_mode"`
	RequestedBy      string     `json:"requested_by,omitempty"`
	HeldSince        *time.Time `json:"held_since,omitempty"`
	CreatedAt        time.Time  `json:"created_at"`
	UpdatedAt        time.Time  `json:"updated_at"`
	CompletedAt      *time.Time `json:"completed_at,omitempty"`
}

// VoucherPurchaseOutcome is what a supplier call ended with.
type VoucherPurchaseOutcome struct {
	// Status is succeeded or failed.
	Status           string
	SupplierOrderID  string
	SupplierCost     string
	SupplierCurrency string
	ErrorCode        string
	ErrorDetail      string
	// Uncertain marks a failure that may still have bought the cards: the
	// price stays held (HeldSince) until the supplier's records settle it.
	Uncertain bool
}

// VoucherPurchaseResolution ends a held purchase with what the supplier's
// records said — or what the operator decided.
type VoucherPurchaseResolution struct {
	// Found: the supplier has the order, so the cards were bought and the
	// charge stands. Otherwise the price comes back.
	Found            bool
	SupplierOrderID  string
	SupplierCost     string
	SupplierCurrency string
	// Detail replaces the row's error detail: how the hold ended.
	Detail string
}

// VoucherPurchaseFilter narrows the operator's listing.
type VoucherPurchaseFilter struct {
	InstallationID string
	Status         string
	// Kind lists only this kind of purchase (card, airtime, bill); empty lists
	// every kind.
	Kind string
	// HeldOnly lists purchases whose outcome is still being found out.
	HeldOnly bool
	Limit    int
}

// VoucherStore is the optional voucher capability, type-asserted by the HTTP
// layer and the background workers like SMSStore.
type VoucherStore interface {
	// CurrentVoucherCatalog is the newest published version, with its
	// document; ErrVoucherCatalogNotFound before the first.
	CurrentVoucherCatalog(ctx context.Context) (VoucherCatalog, error)
	// VoucherCatalogHead is the newest version without its document: cheap
	// enough to ask on every request.
	VoucherCatalogHead(ctx context.Context) (VoucherCatalog, error)
	GetVoucherCatalog(ctx context.Context, id string) (VoucherCatalog, error)
	// ListVoucherCatalogs is the history, newest first, without documents.
	ListVoucherCatalogs(ctx context.Context, limit int) ([]VoucherCatalog, error)
	// PublishVoucherCatalog stores a new version, which becomes current.
	PublishVoucherCatalog(ctx context.Context, catalog VoucherCatalog) (VoucherCatalog, error)

	// CurrentVoucherSettings is the newest published pricing settings, with
	// their document; ErrVoucherSettingsNotFound before the first.
	CurrentVoucherSettings(ctx context.Context) (VoucherSettingsRecord, error)
	// PublishVoucherSettings stores a new version, which becomes current. The
	// history is append-only: nothing is overwritten, and a version always sorts
	// after the one it replaces (its CreatedAt is moved just past it if the
	// clock says otherwise), so the last one published is the current one.
	PublishVoucherSettings(ctx context.Context, record VoucherSettingsRecord) (VoucherSettingsRecord, error)
	// ListVoucherSettings is the history, newest first, without documents.
	ListVoucherSettings(ctx context.Context, limit int) ([]VoucherSettingsRecord, error)

	// PutVoucherImage stores an image under its SHA-256; one already stored
	// is returned with created=false.
	PutVoucherImage(ctx context.Context, image VoucherImage) (VoucherImage, bool, error)
	GetVoucherImage(ctx context.Context, sha256 string) (VoucherImage, error)
	// MissingVoucherImages returns which of these SHA-256s are not stored.
	MissingVoucherImages(ctx context.Context, sha256s []string) ([]string, error)

	// ReplaceVoucherOffers stores a supplier's whole offer list as read now.
	ReplaceVoucherOffers(ctx context.Context, supplier string, offers []VoucherOffer) error
	ListVoucherOffers(ctx context.Context, supplier string) ([]VoucherOffer, error)

	// BeginVoucherPurchase claims (installation, idempotency key) and takes
	// the purchase's Amount from the shop's voucher balance in the same step.
	// A key already claimed returns its row with created=false; a balance
	// that cannot cover it refuses with *WalletBalanceError.
	BeginVoucherPurchase(ctx context.Context, purchase VoucherPurchase) (VoucherPurchase, bool, error)
	FindVoucherPurchaseByKey(ctx context.Context, installationID, idempotencyKey string) (VoucherPurchase, bool, error)
	GetVoucherPurchase(ctx context.Context, id string) (VoucherPurchase, error)
	// RedirectVoucherPurchase points a purchase at another supplier (and that
	// supplier's own reference for the item) after the first one DEFINITELY
	// bought nothing, so the next can be tried. It changes Supplier and
	// SupplierRef only while the row is pending, not held and names no supplier
	// order yet — otherwise something may already have been bought, and the row
	// is returned untouched with applied=false. An unknown id is
	// ErrVoucherPurchaseNotFound.
	RedirectVoucherPurchase(ctx context.Context, id, supplier, supplierRef string) (VoucherPurchase, bool, error)
	// FinishVoucherPurchase records the supplier's answer on a pending row
	// that is not held yet. Any other row is returned untouched with
	// applied=false: the first outcome wins. A definite failure is refunded
	// in the same step; an uncertain one is held.
	FinishVoucherPurchase(ctx context.Context, id string, outcome VoucherPurchaseOutcome) (VoucherPurchase, bool, error)
	// ResolveVoucherPurchase settles a pending row — held, or abandoned by a
	// relay that died mid-call — with what the supplier's records said.
	// Anything already settled is returned untouched with applied=false. An
	// order another purchase holds is refused with ErrVoucherOrderClaimed.
	ResolveVoucherPurchase(ctx context.Context, id string, resolution VoucherPurchaseResolution) (VoucherPurchase, bool, error)
	ListVoucherPurchases(ctx context.Context, filter VoucherPurchaseFilter) ([]VoucherPurchase, error)
	// ListVoucherPurchasesAwaitingCheck returns pending rows that are held,
	// or older than staleBefore (their relay never finished them), oldest
	// first.
	ListVoucherPurchasesAwaitingCheck(ctx context.Context, staleBefore time.Time, limit int) ([]VoucherPurchase, error)
	// VoucherClaimedSupplierOrders reports which of these supplier orders a
	// purchase already holds.
	VoucherClaimedSupplierOrders(ctx context.Context, supplier string, orderIDs []string) (map[string]bool, error)
}

// Both real stores keep vouchers; the cached wrapper forwards them (see
// cache_capabilities.go).
var (
	_ VoucherStore = (*FileStore)(nil)
	_ VoucherStore = (*PostgresStore)(nil)
)

const (
	defaultVoucherListLimit     = 50
	maxVoucherListLimit         = 500
	defaultVoucherAwaitingLimit = 100
	maxVoucherAwaitingLimit     = 500
	maxVoucherKeyRunes          = 128
	maxVoucherTextRunes         = 500
)

func voucherChargeKey(id string) string { return "voucher:" + id }
func voucherRefundKey(id string) string { return "voucher-refund:" + id }

// ValidVoucherPurchaseStatus reports whether status is a purchase status.
func ValidVoucherPurchaseStatus(status string) bool {
	switch status {
	case VoucherPurchasePending, VoucherPurchaseSucceeded, VoucherPurchaseFailed:
		return true
	}
	return false
}

// NormalizeVoucherKind is the kind a stored or requested value stands for: the
// lower-case name, with an empty one meaning card.
func NormalizeVoucherKind(kind string) string {
	if kind = strings.ToLower(strings.TrimSpace(kind)); kind != "" {
		return kind
	}
	return VoucherKindCard
}

// ValidVoucherKind reports whether kind is a purchase kind (an empty one is
// card, so it is valid).
func ValidVoucherKind(kind string) bool {
	switch NormalizeVoucherKind(kind) {
	case VoucherKindCard, VoucherKindAirtime, VoucherKindBill:
		return true
	}
	return false
}

// withVoucherKind fills the kind of a row read from a store that predates
// kinds.
func withVoucherKind(purchase VoucherPurchase) VoucherPurchase {
	purchase.Kind = NormalizeVoucherKind(purchase.Kind)
	return purchase
}

// prepareVoucherDetails checks a purchase's details: nothing, or one JSON
// object of at most maxVoucherDetailsBytes once compacted. It returns the
// compact form (nil for nothing).
func prepareVoucherDetails(raw json.RawMessage) (json.RawMessage, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil, nil
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &object); err != nil || object == nil {
		return nil, errors.New("voucher purchase details must be a JSON object")
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, trimmed); err != nil {
		return nil, errors.New("voucher purchase details must be a JSON object")
	}
	if compact.Len() > maxVoucherDetailsBytes {
		return nil, fmt.Errorf("voucher purchase details must be at most %d bytes", maxVoucherDetailsBytes)
	}
	// Postgres' jsonb cannot hold a NUL, so neither may the ledger: the file
	// store and the database must accept the same documents.
	if bytes.Contains(compact.Bytes(), []byte(`\u0000`)) {
		return nil, errors.New("voucher purchase details must not contain a NUL character")
	}
	return json.RawMessage(compact.Bytes()), nil
}

// voucherRedirectable reports whether nothing can have been bought yet: the row
// is still pending, no outcome is being found out, and no supplier order exists.
func voucherRedirectable(purchase VoucherPurchase) bool {
	return purchase.Status == VoucherPurchasePending && purchase.HeldSince == nil && purchase.SupplierOrderID == ""
}

// prepareVoucherPurchase fills what a claim needs before it is stored.
func prepareVoucherPurchase(purchase VoucherPurchase, now time.Time) (VoucherPurchase, *big.Rat, error) {
	purchase.InstallationID = strings.TrimSpace(purchase.InstallationID)
	purchase.IdempotencyKey = strings.TrimSpace(purchase.IdempotencyKey)
	purchase.ItemKey = strings.TrimSpace(purchase.ItemKey)
	purchase.BrandKey = strings.TrimSpace(purchase.BrandKey)
	purchase.ItemName = truncateRunes(strings.TrimSpace(purchase.ItemName), maxVoucherTextRunes)
	purchase.Supplier = strings.TrimSpace(purchase.Supplier)
	purchase.SupplierRef = strings.TrimSpace(purchase.SupplierRef)
	purchase.RequestedBy = truncateRunes(strings.TrimSpace(purchase.RequestedBy), maxVoucherKeyRunes)
	purchase.Target = truncateRunes(strings.TrimSpace(purchase.Target), maxVoucherKeyRunes)
	if !ValidVoucherKind(purchase.Kind) {
		return VoucherPurchase{}, nil, fmt.Errorf("unknown voucher purchase kind %q", purchase.Kind)
	}
	purchase.Kind = NormalizeVoucherKind(purchase.Kind)
	details, err := prepareVoucherDetails(purchase.Details)
	if err != nil {
		return VoucherPurchase{}, nil, err
	}
	purchase.Details = details
	if purchase.InstallationID == "" || purchase.IdempotencyKey == "" {
		return VoucherPurchase{}, nil, errors.New("a voucher purchase needs an installation and an idempotency key")
	}
	if utf8.RuneCountInString(purchase.IdempotencyKey) > maxVoucherKeyRunes {
		return VoucherPurchase{}, nil, fmt.Errorf("idempotency key longer than %d characters", maxVoucherKeyRunes)
	}
	if purchase.ItemKey == "" || purchase.Supplier == "" {
		return VoucherPurchase{}, nil, errors.New("a voucher purchase needs an item and a supplier")
	}
	if purchase.Quantity < 1 {
		return VoucherPurchase{}, nil, errors.New("a voucher purchase buys at least one card")
	}
	unit, err := ParseWalletAmount(purchase.UnitPrice)
	if err != nil {
		return VoucherPurchase{}, nil, err
	}
	if unit.Sign() <= 0 {
		return VoucherPurchase{}, nil, errors.New("a voucher purchase must cost something")
	}
	amount := new(big.Rat).Mul(unit, big.NewRat(int64(purchase.Quantity), 1))
	if strings.TrimSpace(purchase.ID) == "" {
		id, err := NewInstallationID()
		if err != nil {
			return VoucherPurchase{}, nil, err
		}
		purchase.ID = id
	}
	purchase.UnitPrice = FormatWalletAmount(unit)
	purchase.Amount = FormatWalletAmount(amount)
	purchase.Status = VoucherPurchasePending
	purchase.SupplierOrderID = ""
	purchase.SupplierCost = ""
	purchase.SupplierCurrency = ""
	purchase.ErrorCode = ""
	purchase.ErrorDetail = ""
	purchase.ShopName = ""
	purchase.HeldSince = nil
	purchase.CompletedAt = nil
	purchase.CreatedAt = now.UTC()
	purchase.UpdatedAt = purchase.CreatedAt
	return purchase, amount, nil
}

func voucherChargePosting(purchase VoucherPurchase) WalletPosting {
	return WalletPosting{
		InstallationID: purchase.InstallationID,
		Account:        WalletAccountVouchers,
		Kind:           WalletEntryCharge,
		Service:        WalletServiceVouchers,
		Amount:         "-" + purchase.Amount,
		Reference:      purchase.ID,
		Description:    voucherDescription(purchase),
		IdempotencyKey: voucherChargeKey(purchase.ID),
		Actor:          purchase.RequestedBy,
		TestMode:       purchase.TestMode,
	}
}

func voucherRefundPosting(purchase VoucherPurchase) WalletPosting {
	return WalletPosting{
		InstallationID: purchase.InstallationID,
		Account:        WalletAccountVouchers,
		Kind:           WalletEntryRefund,
		Service:        WalletServiceVouchers,
		Amount:         NormalizeWalletAmount(purchase.Amount),
		Reference:      purchase.ID,
		Description:    voucherRefundDescription(purchase),
		IdempotencyKey: voucherRefundKey(purchase.ID),
		TestMode:       purchase.TestMode,
	}
}

// voucherDescription is the purchase as the shop's statement prints it: the
// item's name (the full Arabic name frozen at purchase), with the quantity when
// more than one card was bought.
func voucherDescription(purchase VoucherPurchase) string {
	name := purchase.ItemName
	if name == "" {
		name = purchase.ItemKey
	}
	if purchase.Quantity > 1 {
		name = fmt.Sprintf("%s × %d", name, purchase.Quantity)
	}
	return truncateRunes(name, maxWalletTextRunes)
}

// voucherRefundDescription is how the statement says a price came back. A card
// that was never issued, or an operation (a top-up or a bill payment) that was
// never carried out. A long name is cut so the posting always fits the
// statement: a refund must never fail on its own wording.
func voucherRefundDescription(purchase VoucherPurchase) string {
	prefix := "استرداد كرت لم يُصدر: "
	if NormalizeVoucherKind(purchase.Kind) != VoucherKindCard {
		prefix = "استرداد عملية لم تُنفَّذ: "
	}
	return truncateRunes(prefix+voucherDescription(purchase), maxWalletTextRunes)
}

// applyVoucherOutcome is what finishing a pending row this way makes of it,
// and what moves on the voucher balance (nil when nothing does).
func applyVoucherOutcome(
	existing VoucherPurchase,
	outcome VoucherPurchaseOutcome,
	now time.Time,
) (VoucherPurchase, *preparedWalletPosting, error) {
	finished := existing
	finished.UpdatedAt = now.UTC()
	if id := strings.TrimSpace(outcome.SupplierOrderID); id != "" {
		finished.SupplierOrderID = id
	}
	if cost := strings.TrimSpace(outcome.SupplierCost); cost != "" {
		finished.SupplierCost = cost
		finished.SupplierCurrency = strings.ToUpper(strings.TrimSpace(outcome.SupplierCurrency))
	}
	switch outcome.Status {
	case VoucherPurchaseSucceeded:
		finished.Status = VoucherPurchaseSucceeded
		finished.ErrorCode = ""
		finished.ErrorDetail = ""
		finished.HeldSince = nil
		completed := now.UTC()
		finished.CompletedAt = &completed
		return finished, nil, nil
	case VoucherPurchaseFailed:
		finished.ErrorCode = truncateRunes(strings.TrimSpace(outcome.ErrorCode), 64)
		finished.ErrorDetail = truncateRunes(strings.TrimSpace(outcome.ErrorDetail), maxVoucherTextRunes)
		if outcome.Uncertain {
			// Bought or not, nobody knows yet: the money stays where it is.
			held := now.UTC()
			finished.HeldSince = &held
			return finished, nil, nil
		}
		finished.Status = VoucherPurchaseFailed
		finished.HeldSince = nil
		completed := now.UTC()
		finished.CompletedAt = &completed
		posting, err := prepareWalletPosting(voucherRefundPosting(finished))
		if err != nil {
			return VoucherPurchase{}, nil, err
		}
		return finished, &posting, nil
	}
	return VoucherPurchase{}, nil, fmt.Errorf("a voucher purchase finishes succeeded or failed, got %q", outcome.Status)
}

// resolveVoucherPurchase is what ending a hold this way makes of the row.
func resolveVoucherPurchase(
	existing VoucherPurchase,
	resolution VoucherPurchaseResolution,
	now time.Time,
) (VoucherPurchase, *preparedWalletPosting, error) {
	resolved := existing
	resolved.HeldSince = nil
	resolved.UpdatedAt = now.UTC()
	completed := now.UTC()
	resolved.CompletedAt = &completed
	if detail := strings.TrimSpace(resolution.Detail); detail != "" {
		resolved.ErrorDetail = truncateRunes(detail, maxVoucherTextRunes)
	}
	if id := strings.TrimSpace(resolution.SupplierOrderID); id != "" {
		resolved.SupplierOrderID = id
	}
	if cost := strings.TrimSpace(resolution.SupplierCost); cost != "" {
		resolved.SupplierCost = cost
		resolved.SupplierCurrency = strings.ToUpper(strings.TrimSpace(resolution.SupplierCurrency))
	}
	if resolution.Found {
		resolved.Status = VoucherPurchaseSucceeded
		resolved.ErrorCode = ""
		return resolved, nil, nil
	}
	resolved.Status = VoucherPurchaseFailed
	if resolved.ErrorCode == "" {
		resolved.ErrorCode = "not_bought"
	}
	posting, err := prepareWalletPosting(voucherRefundPosting(resolved))
	if err != nil {
		return VoucherPurchase{}, nil, err
	}
	return resolved, &posting, nil
}

// voucherKindFilter is the kind a listing is narrowed to: "" lists every kind.
func voucherKindFilter(kind string) string {
	if strings.TrimSpace(kind) == "" {
		return ""
	}
	return NormalizeVoucherKind(kind)
}

func normalizedVoucherListLimit(limit int) int {
	if limit <= 0 {
		return defaultVoucherListLimit
	}
	return min(limit, maxVoucherListLimit)
}

func normalizedVoucherAwaitingLimit(limit int) int {
	if limit <= 0 {
		return defaultVoucherAwaitingLimit
	}
	return min(limit, maxVoucherAwaitingLimit)
}

func voucherAwaitingCheck(purchase VoucherPurchase, staleBefore time.Time) bool {
	if purchase.Status != VoucherPurchasePending {
		return false
	}
	return purchase.HeldSince != nil || purchase.CreatedAt.Before(staleBefore)
}

func voucherOfferKey(supplier, ref string) string { return supplier + "/" + ref }

func sortVoucherPurchasesNewestFirst(rows []VoucherPurchase) {
	sort.Slice(rows, func(i, j int) bool {
		if !rows[i].CreatedAt.Equal(rows[j].CreatedAt) {
			return rows[i].CreatedAt.After(rows[j].CreatedAt)
		}
		return rows[i].ID > rows[j].ID
	})
}

// --- FileStore ---

func (s *FileStore) newestVoucherCatalogLocked() (VoucherCatalog, bool) {
	var newest VoucherCatalog
	found := false
	for _, catalog := range s.data.VoucherCatalogs {
		if !found || catalog.CreatedAt.After(newest.CreatedAt) ||
			(catalog.CreatedAt.Equal(newest.CreatedAt) && catalog.ID > newest.ID) {
			newest = catalog
			found = true
		}
	}
	return newest, found
}

func (s *FileStore) CurrentVoucherCatalog(_ context.Context) (VoucherCatalog, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	catalog, ok := s.newestVoucherCatalogLocked()
	if !ok {
		return VoucherCatalog{}, ErrVoucherCatalogNotFound
	}
	return catalog, nil
}

func (s *FileStore) VoucherCatalogHead(ctx context.Context) (VoucherCatalog, error) {
	catalog, err := s.CurrentVoucherCatalog(ctx)
	catalog.Document = nil
	return catalog, err
}

func (s *FileStore) GetVoucherCatalog(_ context.Context, id string) (VoucherCatalog, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	catalog, ok := s.data.VoucherCatalogs[strings.TrimSpace(id)]
	if !ok {
		return VoucherCatalog{}, ErrVoucherCatalogNotFound
	}
	return catalog, nil
}

func (s *FileStore) ListVoucherCatalogs(_ context.Context, limit int) ([]VoucherCatalog, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	catalogs := make([]VoucherCatalog, 0, len(s.data.VoucherCatalogs))
	for _, catalog := range s.data.VoucherCatalogs {
		catalog.Document = nil
		catalogs = append(catalogs, catalog)
	}
	sort.Slice(catalogs, func(i, j int) bool {
		if !catalogs[i].CreatedAt.Equal(catalogs[j].CreatedAt) {
			return catalogs[i].CreatedAt.After(catalogs[j].CreatedAt)
		}
		return catalogs[i].ID > catalogs[j].ID
	})
	if limit = normalizedVoucherListLimit(limit); len(catalogs) > limit {
		catalogs = catalogs[:limit]
	}
	return catalogs, nil
}

func (s *FileStore) PublishVoucherCatalog(_ context.Context, catalog VoucherCatalog) (VoucherCatalog, error) {
	catalog, err := prepareVoucherCatalog(catalog, s.clock.Now())
	if err != nil {
		return VoucherCatalog{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.data.VoucherCatalogs == nil {
		s.data.VoucherCatalogs = map[string]VoucherCatalog{}
	}
	s.data.VoucherCatalogs[catalog.ID] = catalog
	if err := s.saveLocked(); err != nil {
		delete(s.data.VoucherCatalogs, catalog.ID)
		return VoucherCatalog{}, err
	}
	return catalog, nil
}

func (s *FileStore) newestVoucherSettingsLocked() (VoucherSettingsRecord, bool) {
	var newest VoucherSettingsRecord
	found := false
	for _, record := range s.data.VoucherSettings {
		if !found || record.CreatedAt.After(newest.CreatedAt) ||
			(record.CreatedAt.Equal(newest.CreatedAt) && record.ID > newest.ID) {
			newest = record
			found = true
		}
	}
	return newest, found
}

func (s *FileStore) CurrentVoucherSettings(_ context.Context) (VoucherSettingsRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	record, ok := s.newestVoucherSettingsLocked()
	if !ok {
		return VoucherSettingsRecord{}, ErrVoucherSettingsNotFound
	}
	return record, nil
}

func (s *FileStore) PublishVoucherSettings(_ context.Context, record VoucherSettingsRecord) (VoucherSettingsRecord, error) {
	record, err := prepareVoucherSettings(record, s.clock.Now())
	if err != nil {
		return VoucherSettingsRecord{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	// The last version published is the current one, whatever the clock says:
	// a version never sorts before the one it replaces.
	if newest, ok := s.newestVoucherSettingsLocked(); ok && !record.CreatedAt.After(newest.CreatedAt) {
		record.CreatedAt = newest.CreatedAt.Add(time.Microsecond)
	}
	if s.data.VoucherSettings == nil {
		s.data.VoucherSettings = map[string]VoucherSettingsRecord{}
	}
	s.data.VoucherSettings[record.ID] = record
	if err := s.saveLocked(); err != nil {
		delete(s.data.VoucherSettings, record.ID)
		return VoucherSettingsRecord{}, err
	}
	return record, nil
}

func (s *FileStore) ListVoucherSettings(_ context.Context, limit int) ([]VoucherSettingsRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]VoucherSettingsRecord, 0, len(s.data.VoucherSettings))
	for _, record := range s.data.VoucherSettings {
		record.Document = nil
		records = append(records, record)
	}
	sort.Slice(records, func(i, j int) bool {
		if !records[i].CreatedAt.Equal(records[j].CreatedAt) {
			return records[i].CreatedAt.After(records[j].CreatedAt)
		}
		return records[i].ID > records[j].ID
	})
	if limit = normalizedVoucherListLimit(limit); len(records) > limit {
		records = records[:limit]
	}
	return records, nil
}

// prepareVoucherSettings fills what a new version needs before it is stored.
// The document stays opaque to the store apart from being one JSON object: the
// vouchers package reads and judges it.
func prepareVoucherSettings(record VoucherSettingsRecord, now time.Time) (VoucherSettingsRecord, error) {
	record.SHA256 = strings.TrimSpace(record.SHA256)
	if len(bytes.TrimSpace(record.Document)) == 0 || record.SHA256 == "" {
		return VoucherSettingsRecord{}, errors.New("voucher settings need their document and fingerprint")
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(record.Document, &object); err != nil || object == nil {
		return VoucherSettingsRecord{}, errors.New("voucher settings must be a JSON object")
	}
	if strings.TrimSpace(record.ID) == "" {
		id, err := NewInstallationID()
		if err != nil {
			return VoucherSettingsRecord{}, err
		}
		record.ID = id
	}
	record.Actor = truncateRunes(strings.TrimSpace(record.Actor), maxVoucherKeyRunes)
	record.Note = truncateRunes(strings.TrimSpace(record.Note), maxVoucherTextRunes)
	record.CreatedAt = now.UTC()
	return record, nil
}

func prepareVoucherCatalog(catalog VoucherCatalog, now time.Time) (VoucherCatalog, error) {
	if len(catalog.Document) == 0 || strings.TrimSpace(catalog.SHA256) == "" {
		return VoucherCatalog{}, errors.New("a voucher catalog needs its document and fingerprint")
	}
	if strings.TrimSpace(catalog.ID) == "" {
		id, err := NewInstallationID()
		if err != nil {
			return VoucherCatalog{}, err
		}
		catalog.ID = id
	}
	catalog.Actor = truncateRunes(strings.TrimSpace(catalog.Actor), maxVoucherKeyRunes)
	catalog.Note = truncateRunes(strings.TrimSpace(catalog.Note), maxVoucherTextRunes)
	catalog.CreatedAt = now.UTC()
	return catalog, nil
}

func (s *FileStore) PutVoucherImage(_ context.Context, image VoucherImage) (VoucherImage, bool, error) {
	image.SHA256 = strings.ToLower(strings.TrimSpace(image.SHA256))
	if image.SHA256 == "" || len(image.Data) == 0 {
		return VoucherImage{}, false, errors.New("a voucher image needs its bytes and their SHA-256")
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	if existing, ok := s.data.VoucherImages[image.SHA256]; ok {
		return existing, false, nil
	}
	image.CreatedAt = s.clock.Now().UTC()
	if s.data.VoucherImages == nil {
		s.data.VoucherImages = map[string]VoucherImage{}
	}
	s.data.VoucherImages[image.SHA256] = image
	if err := s.saveLocked(); err != nil {
		delete(s.data.VoucherImages, image.SHA256)
		return VoucherImage{}, false, err
	}
	return image, true, nil
}

func (s *FileStore) GetVoucherImage(_ context.Context, sha256 string) (VoucherImage, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	image, ok := s.data.VoucherImages[strings.ToLower(strings.TrimSpace(sha256))]
	if !ok {
		return VoucherImage{}, ErrVoucherImageNotFound
	}
	return image, nil
}

func (s *FileStore) MissingVoucherImages(_ context.Context, sha256s []string) ([]string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	missing := []string{}
	for _, sum := range sha256s {
		sum = strings.ToLower(strings.TrimSpace(sum))
		if _, ok := s.data.VoucherImages[sum]; !ok {
			missing = append(missing, sum)
		}
	}
	return missing, nil
}

func (s *FileStore) ReplaceVoucherOffers(_ context.Context, supplier string, offers []VoucherOffer) error {
	supplier = strings.TrimSpace(supplier)
	s.mu.Lock()
	defer s.mu.Unlock()

	before := map[string]VoucherOffer{}
	for key, offer := range s.data.VoucherOffers {
		if offer.Supplier == supplier {
			before[key] = offer
			delete(s.data.VoucherOffers, key)
		}
	}
	if s.data.VoucherOffers == nil {
		s.data.VoucherOffers = map[string]VoucherOffer{}
	}
	for _, offer := range offers {
		offer.Supplier = supplier
		offer.SyncedAt = offer.SyncedAt.UTC()
		s.data.VoucherOffers[voucherOfferKey(supplier, offer.Ref)] = offer
	}
	if err := s.saveLocked(); err != nil {
		for _, offer := range offers {
			delete(s.data.VoucherOffers, voucherOfferKey(supplier, offer.Ref))
		}
		for key, offer := range before {
			s.data.VoucherOffers[key] = offer
		}
		return err
	}
	return nil
}

func (s *FileStore) ListVoucherOffers(_ context.Context, supplier string) ([]VoucherOffer, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	supplier = strings.TrimSpace(supplier)
	offers := []VoucherOffer{}
	for _, offer := range s.data.VoucherOffers {
		if supplier == "" || offer.Supplier == supplier {
			offers = append(offers, offer)
		}
	}
	sort.Slice(offers, func(i, j int) bool {
		if offers[i].Supplier != offers[j].Supplier {
			return offers[i].Supplier < offers[j].Supplier
		}
		if offers[i].Group != offers[j].Group {
			return offers[i].Group < offers[j].Group
		}
		return offers[i].Name < offers[j].Name
	})
	return offers, nil
}

func (s *FileStore) findVoucherPurchaseByKeyLocked(installationID, key string) (VoucherPurchase, bool) {
	for _, purchase := range s.data.VoucherPurchases {
		if purchase.InstallationID == installationID && purchase.IdempotencyKey == key {
			return withVoucherKind(purchase), true
		}
	}
	return VoucherPurchase{}, false
}

func (s *FileStore) BeginVoucherPurchase(_ context.Context, purchase VoucherPurchase) (VoucherPurchase, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	claim, _, err := prepareVoucherPurchase(purchase, s.clock.Now())
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	if _, ok := s.data.Installations[claim.InstallationID]; !ok {
		return VoucherPurchase{}, false, ErrNotFound
	}
	if existing, ok := s.findVoucherPurchaseByKeyLocked(claim.InstallationID, claim.IdempotencyKey); ok {
		return existing, false, nil
	}
	posting, err := prepareWalletPosting(voucherChargePosting(claim))
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	charge, _, err := s.postWalletEntryLocked(posting)
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	if s.data.VoucherPurchases == nil {
		s.data.VoucherPurchases = map[string]VoucherPurchase{}
	}
	s.data.VoucherPurchases[claim.ID] = claim
	if err := s.saveLocked(); err != nil {
		delete(s.data.VoucherPurchases, claim.ID)
		delete(s.data.WalletEntries, charge.ID)
		return VoucherPurchase{}, false, err
	}
	return claim, true, nil
}

func (s *FileStore) FindVoucherPurchaseByKey(
	_ context.Context,
	installationID, idempotencyKey string,
) (VoucherPurchase, bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	purchase, ok := s.findVoucherPurchaseByKeyLocked(strings.TrimSpace(installationID), strings.TrimSpace(idempotencyKey))
	return purchase, ok, nil
}

func (s *FileStore) GetVoucherPurchase(_ context.Context, id string) (VoucherPurchase, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	purchase, ok := s.data.VoucherPurchases[strings.TrimSpace(id)]
	if !ok {
		return VoucherPurchase{}, ErrVoucherPurchaseNotFound
	}
	return withVoucherKind(purchase), nil
}

func (s *FileStore) RedirectVoucherPurchase(
	_ context.Context,
	id, supplier, supplierRef string,
) (VoucherPurchase, bool, error) {
	id = strings.TrimSpace(id)
	supplier = strings.TrimSpace(supplier)
	supplierRef = strings.TrimSpace(supplierRef)
	if supplier == "" {
		return VoucherPurchase{}, false, errors.New("a redirected voucher purchase needs a supplier")
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	stored, ok := s.data.VoucherPurchases[id]
	if !ok {
		return VoucherPurchase{}, false, ErrVoucherPurchaseNotFound
	}
	existing := withVoucherKind(stored)
	if !voucherRedirectable(existing) {
		return existing, false, nil
	}
	redirected := existing
	redirected.Supplier = supplier
	redirected.SupplierRef = supplierRef
	redirected.UpdatedAt = s.clock.Now().UTC()
	s.data.VoucherPurchases[id] = redirected
	if err := s.saveLocked(); err != nil {
		s.data.VoucherPurchases[id] = stored
		return VoucherPurchase{}, false, err
	}
	return redirected, true, nil
}

func (s *FileStore) voucherOrderClaimedLocked(purchase VoucherPurchase, orderID string) bool {
	if orderID == "" {
		return false
	}
	for _, other := range s.data.VoucherPurchases {
		if other.ID != purchase.ID && other.Supplier == purchase.Supplier && other.SupplierOrderID == orderID {
			return true
		}
	}
	return false
}

func (s *FileStore) FinishVoucherPurchase(
	_ context.Context,
	id string,
	outcome VoucherPurchaseOutcome,
) (VoucherPurchase, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.VoucherPurchases[id]
	if !ok {
		return VoucherPurchase{}, false, ErrVoucherPurchaseNotFound
	}
	existing = withVoucherKind(existing)
	if existing.Status != VoucherPurchasePending || existing.HeldSince != nil {
		return existing, false, nil
	}
	finished, posting, err := applyVoucherOutcome(existing, outcome, s.clock.Now())
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	if s.voucherOrderClaimedLocked(finished, finished.SupplierOrderID) {
		return VoucherPurchase{}, false, ErrVoucherOrderClaimed
	}
	return s.storeVoucherPurchaseLocked(existing, finished, posting)
}

func (s *FileStore) ResolveVoucherPurchase(
	_ context.Context,
	id string,
	resolution VoucherPurchaseResolution,
) (VoucherPurchase, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.VoucherPurchases[id]
	if !ok {
		return VoucherPurchase{}, false, ErrVoucherPurchaseNotFound
	}
	existing = withVoucherKind(existing)
	if existing.Status != VoucherPurchasePending {
		return existing, false, nil
	}
	resolved, posting, err := resolveVoucherPurchase(existing, resolution, s.clock.Now())
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	if s.voucherOrderClaimedLocked(resolved, resolved.SupplierOrderID) {
		return VoucherPurchase{}, false, ErrVoucherOrderClaimed
	}
	return s.storeVoucherPurchaseLocked(existing, resolved, posting)
}

func (s *FileStore) storeVoucherPurchaseLocked(
	existing, updated VoucherPurchase,
	posting *preparedWalletPosting,
) (VoucherPurchase, bool, error) {
	var moved WalletEntry
	if posting != nil {
		var err error
		if moved, _, err = s.postWalletEntryLocked(*posting); err != nil {
			return VoucherPurchase{}, false, err
		}
	}
	s.data.VoucherPurchases[updated.ID] = updated
	if err := s.saveLocked(); err != nil {
		s.data.VoucherPurchases[updated.ID] = existing
		if moved.ID != "" {
			delete(s.data.WalletEntries, moved.ID)
		}
		return VoucherPurchase{}, false, err
	}
	return updated, true, nil
}

func (s *FileStore) ListVoucherPurchases(_ context.Context, filter VoucherPurchaseFilter) ([]VoucherPurchase, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	installationID := strings.TrimSpace(filter.InstallationID)
	status := strings.TrimSpace(filter.Status)
	kind := voucherKindFilter(filter.Kind)
	rows := []VoucherPurchase{}
	for _, purchase := range s.data.VoucherPurchases {
		purchase = withVoucherKind(purchase)
		if installationID != "" && purchase.InstallationID != installationID {
			continue
		}
		if status != "" && purchase.Status != status {
			continue
		}
		if kind != "" && purchase.Kind != kind {
			continue
		}
		if filter.HeldOnly && purchase.HeldSince == nil {
			continue
		}
		purchase.ShopName = s.data.Installations[purchase.InstallationID].ShopName
		rows = append(rows, purchase)
	}
	sortVoucherPurchasesNewestFirst(rows)
	if limit := normalizedVoucherListLimit(filter.Limit); len(rows) > limit {
		rows = rows[:limit]
	}
	return rows, nil
}

func (s *FileStore) ListVoucherPurchasesAwaitingCheck(
	_ context.Context,
	staleBefore time.Time,
	limit int,
) ([]VoucherPurchase, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rows := []VoucherPurchase{}
	for _, purchase := range s.data.VoucherPurchases {
		if voucherAwaitingCheck(purchase, staleBefore) {
			rows = append(rows, withVoucherKind(purchase))
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if !rows[i].CreatedAt.Equal(rows[j].CreatedAt) {
			return rows[i].CreatedAt.Before(rows[j].CreatedAt)
		}
		return rows[i].ID < rows[j].ID
	})
	if limit = normalizedVoucherAwaitingLimit(limit); len(rows) > limit {
		rows = rows[:limit]
	}
	return rows, nil
}

func (s *FileStore) VoucherClaimedSupplierOrders(
	_ context.Context,
	supplier string,
	orderIDs []string,
) (map[string]bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	wanted := map[string]bool{}
	for _, id := range orderIDs {
		if id = strings.TrimSpace(id); id != "" {
			wanted[id] = true
		}
	}
	claimed := map[string]bool{}
	for _, purchase := range s.data.VoucherPurchases {
		if purchase.Supplier == supplier && wanted[purchase.SupplierOrderID] {
			claimed[purchase.SupplierOrderID] = true
		}
	}
	return claimed, nil
}

// --- CachedInstallationStore forwarding ---

func (s *CachedInstallationStore) voucherStore() (VoucherStore, error) {
	store, ok := s.store.(VoucherStore)
	if !ok {
		return nil, errVouchersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) CurrentVoucherCatalog(ctx context.Context) (VoucherCatalog, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherCatalog{}, err
	}
	return store.CurrentVoucherCatalog(ctx)
}

func (s *CachedInstallationStore) VoucherCatalogHead(ctx context.Context) (VoucherCatalog, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherCatalog{}, err
	}
	return store.VoucherCatalogHead(ctx)
}

func (s *CachedInstallationStore) GetVoucherCatalog(ctx context.Context, id string) (VoucherCatalog, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherCatalog{}, err
	}
	return store.GetVoucherCatalog(ctx, id)
}

func (s *CachedInstallationStore) ListVoucherCatalogs(ctx context.Context, limit int) ([]VoucherCatalog, error) {
	store, err := s.voucherStore()
	if err != nil {
		return nil, err
	}
	return store.ListVoucherCatalogs(ctx, limit)
}

func (s *CachedInstallationStore) PublishVoucherCatalog(ctx context.Context, catalog VoucherCatalog) (VoucherCatalog, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherCatalog{}, err
	}
	return store.PublishVoucherCatalog(ctx, catalog)
}

func (s *CachedInstallationStore) CurrentVoucherSettings(ctx context.Context) (VoucherSettingsRecord, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherSettingsRecord{}, err
	}
	return store.CurrentVoucherSettings(ctx)
}

func (s *CachedInstallationStore) PublishVoucherSettings(
	ctx context.Context,
	record VoucherSettingsRecord,
) (VoucherSettingsRecord, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherSettingsRecord{}, err
	}
	return store.PublishVoucherSettings(ctx, record)
}

func (s *CachedInstallationStore) ListVoucherSettings(ctx context.Context, limit int) ([]VoucherSettingsRecord, error) {
	store, err := s.voucherStore()
	if err != nil {
		return nil, err
	}
	return store.ListVoucherSettings(ctx, limit)
}

func (s *CachedInstallationStore) RedirectVoucherPurchase(
	ctx context.Context,
	id, supplier, supplierRef string,
) (VoucherPurchase, bool, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	return store.RedirectVoucherPurchase(ctx, id, supplier, supplierRef)
}

func (s *CachedInstallationStore) PutVoucherImage(ctx context.Context, image VoucherImage) (VoucherImage, bool, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherImage{}, false, err
	}
	return store.PutVoucherImage(ctx, image)
}

func (s *CachedInstallationStore) GetVoucherImage(ctx context.Context, sha256 string) (VoucherImage, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherImage{}, err
	}
	return store.GetVoucherImage(ctx, sha256)
}

func (s *CachedInstallationStore) MissingVoucherImages(ctx context.Context, sha256s []string) ([]string, error) {
	store, err := s.voucherStore()
	if err != nil {
		return nil, err
	}
	return store.MissingVoucherImages(ctx, sha256s)
}

func (s *CachedInstallationStore) ReplaceVoucherOffers(ctx context.Context, supplier string, offers []VoucherOffer) error {
	store, err := s.voucherStore()
	if err != nil {
		return err
	}
	return store.ReplaceVoucherOffers(ctx, supplier, offers)
}

func (s *CachedInstallationStore) ListVoucherOffers(ctx context.Context, supplier string) ([]VoucherOffer, error) {
	store, err := s.voucherStore()
	if err != nil {
		return nil, err
	}
	return store.ListVoucherOffers(ctx, supplier)
}

func (s *CachedInstallationStore) BeginVoucherPurchase(ctx context.Context, purchase VoucherPurchase) (VoucherPurchase, bool, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	return store.BeginVoucherPurchase(ctx, purchase)
}

func (s *CachedInstallationStore) FindVoucherPurchaseByKey(
	ctx context.Context,
	installationID, idempotencyKey string,
) (VoucherPurchase, bool, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	return store.FindVoucherPurchaseByKey(ctx, installationID, idempotencyKey)
}

func (s *CachedInstallationStore) GetVoucherPurchase(ctx context.Context, id string) (VoucherPurchase, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherPurchase{}, err
	}
	return store.GetVoucherPurchase(ctx, id)
}

func (s *CachedInstallationStore) FinishVoucherPurchase(
	ctx context.Context,
	id string,
	outcome VoucherPurchaseOutcome,
) (VoucherPurchase, bool, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	return store.FinishVoucherPurchase(ctx, id, outcome)
}

func (s *CachedInstallationStore) ResolveVoucherPurchase(
	ctx context.Context,
	id string,
	resolution VoucherPurchaseResolution,
) (VoucherPurchase, bool, error) {
	store, err := s.voucherStore()
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	return store.ResolveVoucherPurchase(ctx, id, resolution)
}

func (s *CachedInstallationStore) ListVoucherPurchases(
	ctx context.Context,
	filter VoucherPurchaseFilter,
) ([]VoucherPurchase, error) {
	store, err := s.voucherStore()
	if err != nil {
		return nil, err
	}
	return store.ListVoucherPurchases(ctx, filter)
}

func (s *CachedInstallationStore) ListVoucherPurchasesAwaitingCheck(
	ctx context.Context,
	staleBefore time.Time,
	limit int,
) ([]VoucherPurchase, error) {
	store, err := s.voucherStore()
	if err != nil {
		return nil, err
	}
	return store.ListVoucherPurchasesAwaitingCheck(ctx, staleBefore, limit)
}

func (s *CachedInstallationStore) VoucherClaimedSupplierOrders(
	ctx context.Context,
	supplier string,
	orderIDs []string,
) (map[string]bool, error) {
	store, err := s.voucherStore()
	if err != nil {
		return nil, err
	}
	return store.VoucherClaimedSupplierOrders(ctx, supplier, orderIDs)
}
