package control

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// The company's own card stock: codes the operator bought outside the
// suppliers' APIs (a cheaper wholesaler, a bulk deal) and typed or uploaded in
// the console. A card purchase draws from this stock FIRST, before any
// supplier is called; only when the item has no code left does the purchase go
// on to BN Plus or Reloadly. Unlike supplier purchases, the relay keeps these
// codes: it is the only place they exist until a shop buys one.
//
// The store never sees a code in the clear: the relay seals it first
// (vouchers.StockSealer) and hands over the sealed text, a keyed fingerprint
// (what makes "the same code twice" refusable) and the masked last four
// characters for the operator's listings.
//
// A code is available, sold (to exactly one purchase) or void (taken off the
// shelf by an operator: a typo, a code that would not redeem). A sold code
// comes back only when the operator refunds its sale: onto the shelf again, or
// void, as the operator chooses (RefundVoucherStockSale). A code whose expiry
// date has passed is not sold, though it stays available on paper so the
// operator sees it.

// Voucher stock statuses.
const (
	VoucherStockAvailable = "available"
	VoucherStockSold      = "sold"
	VoucherStockVoid      = "void"
)

const (
	// MaxVoucherStockBatch bounds one upload: a CSV of a few thousand codes is
	// a normal bulk deal, a hundred thousand is a mistake.
	MaxVoucherStockBatch     = 5000
	maxVoucherStockCodeRunes = 200
	maxVoucherStockSerial    = 100
	maxVoucherStockText      = 300
	defaultVoucherStockList  = 100
	maxVoucherStockList      = 1000
)

var (
	// ErrVoucherStockShort: the item has fewer usable codes than the purchase
	// asks for. Nothing was taken.
	ErrVoucherStockShort = errors.New("not enough codes of this card in stock")
	// ErrVoucherStockNotFound: no code with that id.
	ErrVoucherStockNotFound = errors.New("stock code not found")
	// ErrVoucherStockNotAvailable: only an available code can be voided.
	ErrVoucherStockNotAvailable = errors.New("the code is no longer available")
	// ErrVoucherNotStockSale: the purchase was not sold from the stock.
	ErrVoucherNotStockSale = errors.New("the purchase was not sold from the company's stock")
	// ErrVoucherStockSalePending: a purchase still being settled is refunded by
	// settling it (resolve), not here.
	ErrVoucherStockSalePending = errors.New("the purchase is still being settled")
	// ErrVoucherStockReturned: the purchase holds no sold code any more — its
	// codes were already given back.
	ErrVoucherStockReturned = errors.New("the purchase's codes were already given back")

	voucherStockDatePattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
)

// VoucherStockCode is one card code the company holds.
type VoucherStockCode struct {
	ID      string `json:"id"`
	ItemKey string `json:"item"`
	// Sealed is the code as the relay sealed it for this item; only the relay's
	// stock key opens it. Fingerprint identifies the code (the same code always
	// has the same one) and Mask is its last four characters, all the operator
	// ever sees.
	Sealed      string `json:"sealed"`
	Fingerprint string `json:"fingerprint"`
	Mask        string `json:"mask"`
	Serial      string `json:"serial,omitempty"`
	// Cost is what the company paid for this one code, in dinars.
	Cost string `json:"cost"`
	// ExpiresOn is the last day the code redeems (YYYY-MM-DD); empty: never.
	ExpiresOn  string     `json:"expires_on,omitempty"`
	BatchID    string     `json:"batch_id"`
	Source     string     `json:"source,omitempty"`
	Note       string     `json:"note,omitempty"`
	Status     string     `json:"status"`
	PurchaseID string     `json:"purchase_id,omitempty"`
	Actor      string     `json:"actor,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	SoldAt     *time.Time `json:"sold_at,omitempty"`
	VoidedAt   *time.Time `json:"voided_at,omitempty"`
	VoidedBy   string     `json:"voided_by,omitempty"`
	VoidReason string     `json:"void_reason,omitempty"`
	// ReturnedFrom is the purchase whose refund gave this code back (to the
	// shelf or void), with when, by whom and why. Empty: never sold back.
	ReturnedFrom string     `json:"returned_from,omitempty"`
	ReturnedAt   *time.Time `json:"returned_at,omitempty"`
	ReturnedBy   string     `json:"returned_by,omitempty"`
	ReturnReason string     `json:"return_reason,omitempty"`
}

// VoucherStockReturn is the operator's decision when a sale from stock is
// refunded: put its codes back on the shelf (the customer never used them) or
// void them (they were handed out, or do not work).
type VoucherStockReturn struct {
	Restock bool
	Actor   string
	Reason  string
}

// VoucherStockRefund is what refunding a stock sale did.
type VoucherStockRefund struct {
	Purchase VoucherPurchase
	Codes    []VoucherStockCode
	// Refunded is true when the shop's money went back now; false when the
	// purchase had already been refunded (it failed) and only its codes moved.
	Refunded bool
}

// VoucherStockBatch is one save from the console: codes typed one by one or a
// CSV, with where they were bought. Every code is added, or none.
type VoucherStockBatch struct {
	ID     string             `json:"id"`
	Source string             `json:"source,omitempty"`
	Note   string             `json:"note,omitempty"`
	Actor  string             `json:"actor,omitempty"`
	Codes  []VoucherStockCode `json:"codes"`
}

// VoucherStockLevel is one item's stock as the operator reads it.
type VoucherStockLevel struct {
	ItemKey   string `json:"item"`
	Available int    `json:"available"`
	// Expired counts available codes past their date: on the shelf, never sold.
	Expired int `json:"expired"`
	Sold    int `json:"sold"`
	Voided  int `json:"voided"`
	// AvailableCost is what the usable codes cost the company, in dinars.
	AvailableCost string `json:"available_cost"`
	// NextExpiry is the soonest date among the usable codes; empty when none
	// expires.
	NextExpiry  string     `json:"next_expiry,omitempty"`
	LastAddedAt *time.Time `json:"last_added_at,omitempty"`
}

// VoucherStockFilter narrows the operator's code listing.
type VoucherStockFilter struct {
	ItemKey string
	Status  string
	BatchID string
	Limit   int
}

// VoucherStockProblem is one thing wrong with a batch: the row (0-based) and
// the field.
type VoucherStockProblem struct {
	Row     int    `json:"row"`
	Field   string `json:"field"`
	Message string `json:"message"`
}

// VoucherStockInvalidError refuses a batch, listing every problem at once so
// the operator fixes a CSV in one pass.
type VoucherStockInvalidError struct {
	Problems []VoucherStockProblem
}

func (e *VoucherStockInvalidError) Error() string {
	if len(e.Problems) == 0 {
		return "invalid stock batch"
	}
	first := e.Problems[0]
	return fmt.Sprintf("row %d %s: %s (%d problems)", first.Row+1, first.Field, first.Message, len(e.Problems))
}

// VoucherStockStore is the optional stock capability.
type VoucherStockStore interface {
	// AddVoucherStock stores a batch, all or nothing. A code already held (in
	// any status, for any item) refuses the batch with *VoucherStockInvalidError.
	// With dryRun every check runs and nothing is stored.
	AddVoucherStock(ctx context.Context, batch VoucherStockBatch, dryRun bool) (VoucherStockBatch, error)
	// VoucherStockAvailable counts the codes a purchase could take now, per
	// item: available and not expired. It is read on every catalog request.
	VoucherStockAvailable(ctx context.Context) (map[string]int, error)
	// VoucherStockLevels is every item's stock, for the operator.
	VoucherStockLevels(ctx context.Context) ([]VoucherStockLevel, error)
	// ListVoucherStock lists codes, newest first.
	ListVoucherStock(ctx context.Context, filter VoucherStockFilter) ([]VoucherStockCode, error)
	// ClaimVoucherStock sells quantity codes of an item to a purchase in one
	// step, soonest expiry first, then oldest. Asked again for the same
	// purchase it returns the codes already sold to it. With too few usable
	// codes nothing is taken: ErrVoucherStockShort.
	ClaimVoucherStock(ctx context.Context, itemKey string, quantity int, purchaseID string) ([]VoucherStockCode, error)
	// VoucherStockForPurchase is the codes sold to a purchase (none: empty).
	VoucherStockForPurchase(ctx context.Context, purchaseID string) ([]VoucherStockCode, error)
	// VoidVoucherStock takes an available code off the shelf for good.
	VoidVoucherStock(ctx context.Context, id, actor, reason string) (VoucherStockCode, error)
	// RefundVoucherStockSale gives back a sale from stock, in one step. A
	// succeeded purchase has its price returned to the shop's voucher balance
	// (once: the ledger's refund key); one that already failed (and was
	// refunded) only has its codes moved. Its codes then go back on the shelf
	// or void, as ret says. A purchase still pending is refused
	// (ErrVoucherStockSalePending), one not sold from stock too
	// (ErrVoucherNotStockSale), and one whose codes already came back
	// (ErrVoucherStockReturned).
	RefundVoucherStockSale(ctx context.Context, purchaseID string, ret VoucherStockReturn) (VoucherStockRefund, error)
}

var (
	_ VoucherStockStore = (*FileStore)(nil)
	_ VoucherStockStore = (*PostgresStore)(nil)
	_ VoucherStockStore = (*CachedInstallationStore)(nil)
)

// prepareVoucherStockBatch checks and normalizes a batch before it is stored:
// ids, the batch's source and note on every code, costs to three places, and no
// code twice (by fingerprint). The relay has already checked each code's text
// and sealed it. The store then checks the codes it already holds.
func prepareVoucherStockBatch(batch VoucherStockBatch, now time.Time) (VoucherStockBatch, error) {
	batch.Source = truncateRunes(strings.TrimSpace(batch.Source), maxVoucherStockText)
	batch.Note = truncateRunes(strings.TrimSpace(batch.Note), maxVoucherStockText)
	batch.Actor = truncateRunes(strings.TrimSpace(batch.Actor), maxVoucherStockText)
	var problems []VoucherStockProblem
	add := func(row int, field, message string) {
		problems = append(problems, VoucherStockProblem{Row: row, Field: field, Message: message})
	}
	switch {
	case len(batch.Codes) == 0:
		add(0, "codes", "add at least one code")
	case len(batch.Codes) > MaxVoucherStockBatch:
		add(0, "codes", fmt.Sprintf("at most %d codes in one save", MaxVoucherStockBatch))
	}
	if len(problems) > 0 {
		return VoucherStockBatch{}, &VoucherStockInvalidError{Problems: problems}
	}
	batchID, err := NewInstallationID()
	if err != nil {
		return VoucherStockBatch{}, err
	}
	batch.ID = "stb_" + batchID
	seen := map[string]int{}
	for i := range batch.Codes {
		code := &batch.Codes[i]
		code.ItemKey = strings.TrimSpace(code.ItemKey)
		code.Serial = strings.TrimSpace(code.Serial)
		code.ExpiresOn = strings.TrimSpace(code.ExpiresOn)
		if code.ItemKey == "" {
			add(i, "item", "choose the card")
		}
		switch {
		case code.Sealed == "" || code.Fingerprint == "":
			add(i, "code", "the code is empty")
		default:
			if first, dup := seen[code.Fingerprint]; dup {
				add(i, "code", fmt.Sprintf("the same code as row %d", first+1))
			} else {
				seen[code.Fingerprint] = i
			}
		}
		if utf8.RuneCountInString(code.Serial) > maxVoucherStockSerial {
			add(i, "serial", fmt.Sprintf("longer than %d characters", maxVoucherStockSerial))
		}
		cost, err := ParseWalletAmount(code.Cost)
		if err != nil || cost.Sign() <= 0 {
			add(i, "cost", "a positive number of dinars, at most three decimals")
		} else {
			code.Cost = FormatWalletAmount(cost)
		}
		if code.ExpiresOn != "" {
			day, err := time.Parse("2006-01-02", code.ExpiresOn)
			switch {
			case !voucherStockDatePattern.MatchString(code.ExpiresOn) || err != nil:
				add(i, "expires_on", "a date written YYYY-MM-DD")
			case day.Before(voucherStockToday(now)):
				add(i, "expires_on", "this date has already passed")
			}
		}
		id, err := NewInstallationID()
		if err != nil {
			return VoucherStockBatch{}, err
		}
		code.ID = "stk_" + id
		code.BatchID = batch.ID
		code.Source, code.Note, code.Actor = batch.Source, batch.Note, batch.Actor
		code.Status = VoucherStockAvailable
		code.PurchaseID = ""
		// A microsecond apart, so codes added together sell in the order they
		// were listed (Postgres keeps microseconds).
		code.CreatedAt = now.UTC().Truncate(time.Microsecond).Add(time.Duration(i) * time.Microsecond)
		code.SoldAt, code.VoidedAt, code.VoidedBy, code.VoidReason = nil, nil, "", ""
		code.ReturnedFrom, code.ReturnedAt, code.ReturnedBy, code.ReturnReason = "", nil, "", ""
	}
	if len(problems) > 0 {
		return VoucherStockBatch{}, &VoucherStockInvalidError{Problems: problems}
	}
	return batch, nil
}

// duplicateStockProblems names the rows whose code the store already holds.
func duplicateStockProblems(batch VoucherStockBatch, held map[string]VoucherStockCode) error {
	var problems []VoucherStockProblem
	for i, code := range batch.Codes {
		if existing, dup := held[code.Fingerprint]; dup {
			problems = append(problems, VoucherStockProblem{Row: i, Field: "code",
				Message: fmt.Sprintf("already in stock (%s, %s, added %s)", existing.ItemKey, existing.Status, existing.CreatedAt.UTC().Format("2006-01-02"))})
		}
	}
	if len(problems) > 0 {
		return &VoucherStockInvalidError{Problems: problems}
	}
	return nil
}

// voucherStockToday is the date expiries are judged against: a code is sold up
// to and including its last day, in Libya's time.
func voucherStockToday(now time.Time) time.Time {
	local := now.In(voucherStockZone)
	return time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.UTC)
}

// voucherStockZone is Libya's clock (UTC+2, no daylight saving).
var voucherStockZone = time.FixedZone("Africa/Tripoli", 2*60*60)

func voucherStockUsable(code VoucherStockCode, today time.Time) bool {
	if code.Status != VoucherStockAvailable {
		return false
	}
	if code.ExpiresOn == "" {
		return true
	}
	day, err := time.Parse("2006-01-02", code.ExpiresOn)
	return err == nil && !day.Before(today)
}

func normalizedVoucherStockLimit(limit int) int {
	if limit <= 0 {
		return defaultVoucherStockList
	}
	return min(limit, maxVoucherStockList)
}

// voucherStockClaimOrder sorts usable codes the way a purchase takes them:
// soonest expiry first (a code that never expires last), then oldest.
func voucherStockClaimOrder(codes []VoucherStockCode) {
	sort.SliceStable(codes, func(i, j int) bool {
		a, b := codes[i], codes[j]
		if a.ExpiresOn != b.ExpiresOn {
			switch {
			case a.ExpiresOn == "":
				return false
			case b.ExpiresOn == "":
				return true
			}
			return a.ExpiresOn < b.ExpiresOn
		}
		if !a.CreatedAt.Equal(b.CreatedAt) {
			return a.CreatedAt.Before(b.CreatedAt)
		}
		return a.ID < b.ID
	})
}

// MaxVoucherStockCodeRunes bounds one code's text, checked by the relay before
// it seals the code.
const MaxVoucherStockCodeRunes = maxVoucherStockCodeRunes

// prepareVoucherStockReturn normalizes the operator's decision.
func prepareVoucherStockReturn(ret VoucherStockReturn) VoucherStockReturn {
	ret.Actor = truncateRunes(strings.TrimSpace(ret.Actor), maxVoucherStockText)
	ret.Reason = truncateRunes(strings.TrimSpace(ret.Reason), maxVoucherStockText)
	return ret
}

// checkVoucherStockSale says whether a purchase can be refunded as a stock sale.
func checkVoucherStockSale(purchase VoucherPurchase) error {
	if NormalizeVoucherKind(purchase.Kind) != VoucherKindCard || purchase.Supplier != voucherStockSupplier {
		return ErrVoucherNotStockSale
	}
	if purchase.Status == VoucherPurchasePending {
		return ErrVoucherStockSalePending
	}
	return nil
}

// voucherStockSupplier is the stock's supplier key (vouchers.SupplierStock;
// control does not import vouchers).
const voucherStockSupplier = "stock"

// voucherStockRefundPosting returns a succeeded stock sale's price to the shop.
// It shares the ledger's refund key, so a purchase is refunded once, however.
func voucherStockRefundPosting(purchase VoucherPurchase) WalletPosting {
	posting := voucherRefundPosting(purchase)
	posting.Description = truncateRunes("استرداد كرت أُعيد: "+voucherDescription(purchase), maxWalletTextRunes)
	return posting
}

// refundedVoucherStockSale is the purchase row after its refund: a succeeded
// sale stays succeeded (the shop already holds its codes) and says in its
// detail, which shops never read on a success, that it was given back.
func refundedVoucherStockSale(purchase VoucherPurchase, ret VoucherStockReturn, now time.Time) VoucherPurchase {
	note := "refunded by operator " + ret.Actor + ": " + ret.Reason
	if ret.Restock {
		note += " (codes back in stock)"
	} else {
		note += " (codes voided)"
	}
	if purchase.ErrorDetail != "" {
		note = purchase.ErrorDetail + "; " + note
	}
	purchase.ErrorDetail = truncateRunes(note, maxVoucherTextRunes)
	purchase.UpdatedAt = now.UTC()
	return purchase
}

// returnVoucherStockCode is a sold code after its sale is refunded.
func returnVoucherStockCode(code VoucherStockCode, purchaseID string, ret VoucherStockReturn, now time.Time) VoucherStockCode {
	at := now.UTC()
	code.PurchaseID, code.SoldAt = "", nil
	code.ReturnedFrom, code.ReturnedAt, code.ReturnedBy, code.ReturnReason = purchaseID, &at, ret.Actor, ret.Reason
	if ret.Restock {
		code.Status = VoucherStockAvailable
	} else {
		code.Status = VoucherStockVoid
		code.VoidedAt, code.VoidedBy = &at, ret.Actor
		code.VoidReason = truncateRunes("refunded, kept off the shelf: "+ret.Reason, maxVoucherStockText)
	}
	return code
}

// --- FileStore ---

func (s *FileStore) AddVoucherStock(_ context.Context, batch VoucherStockBatch, dryRun bool) (VoucherStockBatch, error) {
	prepared, err := prepareVoucherStockBatch(batch, s.clock.Now())
	if err != nil {
		return VoucherStockBatch{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	held := map[string]VoucherStockCode{}
	for _, code := range s.data.VoucherStock {
		held[code.Fingerprint] = code
	}
	if err := duplicateStockProblems(prepared, held); err != nil || dryRun {
		return prepared, err
	}
	if s.data.VoucherStock == nil {
		s.data.VoucherStock = map[string]VoucherStockCode{}
	}
	for _, code := range prepared.Codes {
		s.data.VoucherStock[code.ID] = code
	}
	if err := s.saveLocked(); err != nil {
		for _, code := range prepared.Codes {
			delete(s.data.VoucherStock, code.ID)
		}
		return VoucherStockBatch{}, err
	}
	return prepared, nil
}

func (s *FileStore) VoucherStockAvailable(_ context.Context) (map[string]int, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	today := voucherStockToday(s.clock.Now())
	counts := map[string]int{}
	for _, code := range s.data.VoucherStock {
		if voucherStockUsable(code, today) {
			counts[code.ItemKey]++
		}
	}
	return counts, nil
}

func (s *FileStore) VoucherStockLevels(_ context.Context) ([]VoucherStockLevel, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	today := voucherStockToday(s.clock.Now())
	levels := map[string]*VoucherStockLevel{}
	costs := map[string]*big.Rat{}
	for _, code := range s.data.VoucherStock {
		level, ok := levels[code.ItemKey]
		if !ok {
			level = &VoucherStockLevel{ItemKey: code.ItemKey}
			levels[code.ItemKey] = level
			costs[code.ItemKey] = new(big.Rat)
		}
		switch {
		case voucherStockUsable(code, today):
			level.Available++
			if cost, ok := new(big.Rat).SetString(code.Cost); ok {
				costs[code.ItemKey].Add(costs[code.ItemKey], cost)
			}
			if code.ExpiresOn != "" && (level.NextExpiry == "" || code.ExpiresOn < level.NextExpiry) {
				level.NextExpiry = code.ExpiresOn
			}
		case code.Status == VoucherStockAvailable:
			level.Expired++
		case code.Status == VoucherStockSold:
			level.Sold++
		case code.Status == VoucherStockVoid:
			level.Voided++
		}
		if level.LastAddedAt == nil || code.CreatedAt.After(*level.LastAddedAt) {
			at := code.CreatedAt
			level.LastAddedAt = &at
		}
	}
	out := make([]VoucherStockLevel, 0, len(levels))
	for key, level := range levels {
		level.AvailableCost = FormatWalletAmount(costs[key])
		out = append(out, *level)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ItemKey < out[j].ItemKey })
	return out, nil
}

func (s *FileStore) ListVoucherStock(_ context.Context, filter VoucherStockFilter) ([]VoucherStockCode, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows := []VoucherStockCode{}
	for _, code := range s.data.VoucherStock {
		if (filter.ItemKey == "" || code.ItemKey == filter.ItemKey) &&
			(filter.Status == "" || code.Status == filter.Status) &&
			(filter.BatchID == "" || code.BatchID == filter.BatchID) {
			rows = append(rows, code)
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if !rows[i].CreatedAt.Equal(rows[j].CreatedAt) {
			return rows[i].CreatedAt.After(rows[j].CreatedAt)
		}
		return rows[i].ID > rows[j].ID
	})
	if limit := normalizedVoucherStockLimit(filter.Limit); len(rows) > limit {
		rows = rows[:limit]
	}
	return rows, nil
}

func (s *FileStore) ClaimVoucherStock(_ context.Context, itemKey string, quantity int, purchaseID string) ([]VoucherStockCode, error) {
	itemKey, purchaseID = strings.TrimSpace(itemKey), strings.TrimSpace(purchaseID)
	if quantity < 1 || itemKey == "" || purchaseID == "" {
		return nil, errors.New("a stock claim needs an item, a quantity and a purchase")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if sold := s.voucherStockForPurchaseLocked(purchaseID); len(sold) > 0 {
		return sold, nil
	}
	today := voucherStockToday(s.clock.Now())
	var usable []VoucherStockCode
	for _, code := range s.data.VoucherStock {
		if code.ItemKey == itemKey && voucherStockUsable(code, today) {
			usable = append(usable, code)
		}
	}
	if len(usable) < quantity {
		return nil, ErrVoucherStockShort
	}
	voucherStockClaimOrder(usable)
	now := s.clock.Now().UTC()
	claimed := usable[:quantity]
	for i := range claimed {
		claimed[i].Status = VoucherStockSold
		claimed[i].PurchaseID = purchaseID
		claimed[i].SoldAt = &now
		s.data.VoucherStock[claimed[i].ID] = claimed[i]
	}
	if err := s.saveLocked(); err != nil {
		for _, code := range claimed {
			code.Status, code.PurchaseID, code.SoldAt = VoucherStockAvailable, "", nil
			s.data.VoucherStock[code.ID] = code
		}
		return nil, err
	}
	return claimed, nil
}

func (s *FileStore) voucherStockForPurchaseLocked(purchaseID string) []VoucherStockCode {
	var sold []VoucherStockCode
	for _, code := range s.data.VoucherStock {
		if code.PurchaseID == purchaseID && code.Status == VoucherStockSold {
			sold = append(sold, code)
		}
	}
	voucherStockClaimOrder(sold)
	return sold
}

func (s *FileStore) VoucherStockForPurchase(_ context.Context, purchaseID string) ([]VoucherStockCode, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.voucherStockForPurchaseLocked(strings.TrimSpace(purchaseID)), nil
}

func (s *FileStore) VoidVoucherStock(_ context.Context, id, actor, reason string) (VoucherStockCode, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	code, ok := s.data.VoucherStock[strings.TrimSpace(id)]
	if !ok {
		return VoucherStockCode{}, ErrVoucherStockNotFound
	}
	if code.Status != VoucherStockAvailable {
		return code, ErrVoucherStockNotAvailable
	}
	before := code
	now := s.clock.Now().UTC()
	code.Status = VoucherStockVoid
	code.VoidedAt = &now
	code.VoidedBy = truncateRunes(strings.TrimSpace(actor), maxVoucherStockText)
	code.VoidReason = truncateRunes(strings.TrimSpace(reason), maxVoucherStockText)
	s.data.VoucherStock[code.ID] = code
	if err := s.saveLocked(); err != nil {
		s.data.VoucherStock[code.ID] = before
		return VoucherStockCode{}, err
	}
	return code, nil
}

func (s *FileStore) RefundVoucherStockSale(_ context.Context, purchaseID string, ret VoucherStockReturn) (VoucherStockRefund, error) {
	purchaseID = strings.TrimSpace(purchaseID)
	ret = prepareVoucherStockReturn(ret)
	s.mu.Lock()
	defer s.mu.Unlock()
	existing, ok := s.data.VoucherPurchases[purchaseID]
	if !ok {
		return VoucherStockRefund{}, ErrVoucherPurchaseNotFound
	}
	existing = withVoucherKind(existing)
	if err := checkVoucherStockSale(existing); err != nil {
		return VoucherStockRefund{}, err
	}
	sold := s.voucherStockForPurchaseLocked(purchaseID)
	if len(sold) == 0 {
		return VoucherStockRefund{}, ErrVoucherStockReturned
	}
	now := s.clock.Now()
	result := VoucherStockRefund{Purchase: existing}
	var moved WalletEntry
	if existing.Status == VoucherPurchaseSucceeded {
		posting, err := prepareWalletPosting(voucherStockRefundPosting(existing))
		if err != nil {
			return VoucherStockRefund{}, err
		}
		entry, created, err := s.postWalletEntryLocked(posting)
		if err != nil {
			return VoucherStockRefund{}, err
		}
		if created {
			moved = entry
		}
		result.Refunded = created
		result.Purchase = refundedVoucherStockSale(existing, ret, now)
		s.data.VoucherPurchases[purchaseID] = result.Purchase
	}
	for _, code := range sold {
		returned := returnVoucherStockCode(code, purchaseID, ret, now)
		s.data.VoucherStock[code.ID] = returned
		result.Codes = append(result.Codes, returned)
	}
	if err := s.saveLocked(); err != nil {
		s.data.VoucherPurchases[purchaseID] = existing
		for _, code := range sold {
			s.data.VoucherStock[code.ID] = code
		}
		if moved.ID != "" {
			delete(s.data.WalletEntries, moved.ID)
		}
		return VoucherStockRefund{}, err
	}
	return result, nil
}

// --- CachedInstallationStore forwarding ---

func (s *CachedInstallationStore) voucherStockStore() (VoucherStockStore, error) {
	store, ok := s.store.(VoucherStockStore)
	if !ok {
		return nil, errors.New("voucher stock is not supported by the underlying store")
	}
	return store, nil
}

func (s *CachedInstallationStore) AddVoucherStock(ctx context.Context, batch VoucherStockBatch, dryRun bool) (VoucherStockBatch, error) {
	store, err := s.voucherStockStore()
	if err != nil {
		return VoucherStockBatch{}, err
	}
	return store.AddVoucherStock(ctx, batch, dryRun)
}

func (s *CachedInstallationStore) VoucherStockAvailable(ctx context.Context) (map[string]int, error) {
	store, err := s.voucherStockStore()
	if err != nil {
		return nil, err
	}
	return store.VoucherStockAvailable(ctx)
}

func (s *CachedInstallationStore) VoucherStockLevels(ctx context.Context) ([]VoucherStockLevel, error) {
	store, err := s.voucherStockStore()
	if err != nil {
		return nil, err
	}
	return store.VoucherStockLevels(ctx)
}

func (s *CachedInstallationStore) ListVoucherStock(ctx context.Context, filter VoucherStockFilter) ([]VoucherStockCode, error) {
	store, err := s.voucherStockStore()
	if err != nil {
		return nil, err
	}
	return store.ListVoucherStock(ctx, filter)
}

func (s *CachedInstallationStore) ClaimVoucherStock(ctx context.Context, itemKey string, quantity int, purchaseID string) ([]VoucherStockCode, error) {
	store, err := s.voucherStockStore()
	if err != nil {
		return nil, err
	}
	return store.ClaimVoucherStock(ctx, itemKey, quantity, purchaseID)
}

func (s *CachedInstallationStore) VoucherStockForPurchase(ctx context.Context, purchaseID string) ([]VoucherStockCode, error) {
	store, err := s.voucherStockStore()
	if err != nil {
		return nil, err
	}
	return store.VoucherStockForPurchase(ctx, purchaseID)
}

func (s *CachedInstallationStore) VoidVoucherStock(ctx context.Context, id, actor, reason string) (VoucherStockCode, error) {
	store, err := s.voucherStockStore()
	if err != nil {
		return VoucherStockCode{}, err
	}
	return store.VoidVoucherStock(ctx, id, actor, reason)
}

func (s *CachedInstallationStore) RefundVoucherStockSale(ctx context.Context, purchaseID string, ret VoucherStockReturn) (VoucherStockRefund, error) {
	store, err := s.voucherStockStore()
	if err != nil {
		return VoucherStockRefund{}, err
	}
	return store.RefundVoucherStockSale(ctx, purchaseID, ret)
}
