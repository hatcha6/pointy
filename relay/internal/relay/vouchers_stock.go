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
	"time"
	"unicode/utf8"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// The company's own card stock (control/voucher_stock.go): codes the operator
// added in the console, sold before any supplier is called. To the purchase
// path it is one more supplier, always ranked first while the item has a code
// left; when it has too few it definitely sold nothing, and the purchase goes on
// to the next supplier as usual.
//
// Codes are sealed here, before the store sees them, with the relay's stock key
// (VoucherConfig.StockSealer, POINTY_RELAY_VOUCHER_STOCK_KEY). A relay without
// the key neither adds stock nor sells it: the codes would not open.
//
//	GET  /v1/vouchers/admin/stock                  stock per item, with the catalog's names
//	GET  /v1/vouchers/admin/stock/codes?item=&status=&batch=&limit=   codes, masked
//	POST /v1/vouchers/admin/stock/validate         check a batch, store nothing
//	POST /v1/vouchers/admin/stock                  add a batch {source, note, actor, codes: [{item, code, serial, cost, expires_on}]}
//	POST /v1/vouchers/admin/stock/{id}/void        take an available code off the shelf {reason, actor}
//	POST /v1/vouchers/admin/purchases/{id}/refund  refund a sale from stock {restock, reason, actor}

const maxVoucherStockRequestBytes = 4 << 20

// voucherCodeStockKeyUnset: the relay has no stock key, so it keeps no stock.
const voucherCodeStockKeyUnset = "stock_key_unset"

// StockSupplier sells codes from the company's own stock.
type StockSupplier struct {
	Store  control.VoucherStockStore
	Sealer *vouchers.StockSealer
}

func (StockSupplier) Key() string { return vouchers.SupplierStock }

// Buy takes quantity codes of the item (ref.ID) for the purchase clientRef. Too
// few codes is a definite failure: nothing was taken. Any other error leaves it
// open — the claim may have committed — and the reconciler reads the stock
// back by the purchase's id.
func (s StockSupplier) Buy(ctx context.Context, ref vouchers.Ref, quantity int, clientRef string) (vouchers.Purchase, error) {
	codes, err := s.Store.ClaimVoucherStock(ctx, ref.ID, quantity, clientRef)
	switch {
	case errors.Is(err, control.ErrVoucherStockShort):
		return vouchers.Purchase{}, &vouchers.Failure{Code: vouchers.FailureOutOfStock, Detail: "the company's stock has too few codes", Definite: true}
	case err != nil:
		return vouchers.Purchase{}, &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: "stock claim: " + err.Error()}
	}
	bought, err := s.purchase(clientRef, codes)
	if err != nil {
		// The codes are this purchase's now but do not open: it stays held
		// until the right key is back, and the reconciler reads them again.
		return vouchers.Purchase{}, &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: err.Error()}
	}
	return bought, nil
}

// Lookup reads the codes a purchase took; the order id is the purchase's id.
func (s StockSupplier) Lookup(ctx context.Context, _ vouchers.Ref, orderID string) (vouchers.Purchase, error) {
	codes, err := s.Store.VoucherStockForPurchase(ctx, orderID)
	if err != nil {
		return vouchers.Purchase{}, err
	}
	if len(codes) == 0 {
		return vouchers.Purchase{OrderID: orderID, Status: vouchers.StatusFailed, Message: "no stock code was taken"}, nil
	}
	return s.purchase(orderID, codes)
}

// Find is never needed: FindByClientRef answers exactly.
func (StockSupplier) Find(context.Context, vouchers.Ref, int, time.Time, time.Time) ([]vouchers.Purchase, error) {
	return nil, nil
}

// FindByClientRef is the codes the purchase took, as one order, or none.
func (s StockSupplier) FindByClientRef(ctx context.Context, _ vouchers.Ref, clientRef string, _, _ time.Time) ([]vouchers.Purchase, error) {
	codes, err := s.Store.VoucherStockForPurchase(ctx, clientRef)
	if err != nil || len(codes) == 0 {
		return nil, err
	}
	bought, err := s.purchase(clientRef, codes)
	if err != nil {
		return nil, err
	}
	return []vouchers.Purchase{bought}, nil
}

// Offers: the stock is counted per request, not synced.
func (StockSupplier) Offers(context.Context) ([]vouchers.Offer, error) { return nil, nil }

var _ vouchers.RefFinder = StockSupplier{}

// purchase opens the codes a purchase took. A code that does not open fails the
// whole read: half a set of codes is never handed out.
func (s StockSupplier) purchase(orderID string, codes []control.VoucherStockCode) (vouchers.Purchase, error) {
	if s.Sealer == nil {
		return vouchers.Purchase{}, errors.New("this relay has no stock key (POINTY_RELAY_VOUCHER_STOCK_KEY), so its stock codes cannot be opened")
	}
	total := new(big.Rat)
	out := make([]vouchers.Code, 0, len(codes))
	var at time.Time
	for _, code := range codes {
		if cost, ok := new(big.Rat).SetString(code.Cost); ok {
			total.Add(total, cost)
		}
		if code.SoldAt != nil && code.SoldAt.After(at) {
			at = *code.SoldAt
		}
		plain, err := s.Sealer.Open(code.ItemKey, code.Sealed)
		if err != nil {
			return vouchers.Purchase{}, fmt.Errorf("stock code %s: %w", code.ID, err)
		}
		out = append(out, vouchers.Code{Code: plain, Serial: code.Serial})
	}
	return vouchers.Purchase{
		OrderID:  orderID,
		Status:   vouchers.StatusSucceeded,
		Cost:     control.FormatWalletAmount(total),
		Currency: vouchers.Currency,
		Codes:    out,
		At:       at,
	}, nil
}

func (s HTTPServer) voucherStockStore() (control.VoucherStockStore, bool) {
	store, ok := s.Store.(control.VoucherStockStore)
	return store, ok
}

// voucherSupplierByKey is who a stored purchase was bought from, the stock
// included, to read it back.
func (s HTTPServer) voucherSupplierByKey(key string) (vouchers.Supplier, bool) {
	if key == vouchers.SupplierStock {
		store, ok := s.voucherStockStore()
		if !ok {
			return nil, false
		}
		return StockSupplier{Store: store, Sealer: s.Vouchers.StockSealer}, true
	}
	return s.Vouchers.supplierByKey(key)
}

// withStock adds what the stock holds to the offers a ranking reads. A relay
// whose store keeps no stock, that has no stock key, or in test mode, sells
// none.
func (s HTTPServer) withStock(ctx context.Context, offers voucherOffers) (voucherOffers, error) {
	store, ok := s.voucherStockStore()
	if !ok || s.Vouchers.TestMode || s.Vouchers.StockSealer == nil {
		return offers, nil
	}
	counts, err := store.VoucherStockAvailable(ctx)
	if err != nil {
		return offers, err
	}
	offers.stock = counts
	offers.stockSupplier = StockSupplier{Store: store, Sealer: s.Vouchers.StockSealer}
	return offers, nil
}

// stockEvaluation judges the company's own stock of an item.
func stockEvaluation(item string, offers voucherOffers) supplierEvaluation {
	evaluation := supplierEvaluation{Index: -1, Ref: vouchers.Ref{Supplier: vouchers.SupplierStock, ID: item}}
	if offers.stockSupplier == nil {
		evaluation.Reason = "this relay keeps no stock"
		return evaluation
	}
	evaluation.Supplier = offers.stockSupplier
	if offers.stock[item] < 1 {
		evaluation.Reason = "no code left in the company's stock"
		return evaluation
	}
	evaluation.Candidate = true
	evaluation.Note = fmt.Sprintf("%d in stock", offers.stock[item])
	return evaluation
}

// --- the operator's side ---

func (s HTTPServer) handleVoucherAdminStock(w http.ResponseWriter, r *http.Request, store control.VoucherStore, path string) {
	stock, ok := s.voucherStockStore()
	if !ok {
		writeSMSError(w, http.StatusNotImplemented, voucherCodeUnavailable, "card stock is not supported by this relay's store", nil)
		return
	}
	switch {
	case path == "" && r.Method == http.MethodGet:
		s.handleVoucherStockLevels(w, r, store, stock)
	case path == "/codes" && r.Method == http.MethodGet:
		s.handleVoucherStockCodes(w, r, stock)
	case path == "" && r.Method == http.MethodPost:
		s.handleVoucherStockAdd(w, r, store, stock, false)
	case path == "/validate" && r.Method == http.MethodPost:
		s.handleVoucherStockAdd(w, r, store, stock, true)
	case strings.HasSuffix(path, "/void") && r.Method == http.MethodPost:
		s.handleVoucherStockVoid(w, r, stock, strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/void"))
	default:
		writeNotFound(w)
	}
}

type voucherStockItem struct {
	control.VoucherStockLevel
	Name  string `json:"name"`
	Brand string `json:"brand"`
	// InCatalog is false for stock of an item the current catalog no longer
	// has: it cannot be sold until the item comes back.
	InCatalog bool `json:"in_catalog"`
}

func (s HTTPServer) handleVoucherStockLevels(w http.ResponseWriter, r *http.Request, store control.VoucherStore, stock control.VoucherStockStore) {
	ctx := r.Context()
	levels, err := stock.VoucherStockLevels(ctx)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher stock read failed", err)
		return
	}
	loaded, err := s.currentVoucherCatalog(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher catalog read failed", err)
		return
	}
	items := make([]voucherStockItem, 0, len(levels))
	for _, level := range levels {
		item := voucherStockItem{VoucherStockLevel: level}
		if located, found := vouchers.Find(loaded.document, level.ItemKey); found && !loaded.empty {
			item.Name, item.Brand, item.InCatalog = located.Name(), located.Brand.Key, true
		}
		items = append(items, item)
	}
	recent, err := stock.ListVoucherStock(ctx, control.VoucherStockFilter{Limit: 500})
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher stock read failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"items":     items,
		"batches":   voucherStockBatches(recent),
		"test_mode": s.Vouchers.TestMode,
		"max_batch": control.MaxVoucherStockBatch,
		// key_set is false when the relay has no stock key: nothing can be
		// added, and what is stored is not sold.
		"key_set": s.Vouchers.StockSealer != nil,
	})
}

// voucherStockBatchSummary is one save as the operator's history shows it.
type voucherStockBatchSummary struct {
	ID        string    `json:"id"`
	Source    string    `json:"source,omitempty"`
	Note      string    `json:"note,omitempty"`
	Actor     string    `json:"actor,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	Codes     int       `json:"codes"`
	Items     []string  `json:"items"`
	Cost      string    `json:"cost"`
}

// voucherStockBatches groups the newest codes by the save that added them.
func voucherStockBatches(codes []control.VoucherStockCode) []voucherStockBatchSummary {
	index := map[string]int{}
	var out []voucherStockBatchSummary
	costs := []*big.Rat{}
	for _, code := range codes {
		at, ok := index[code.BatchID]
		if !ok {
			at = len(out)
			index[code.BatchID] = at
			out = append(out, voucherStockBatchSummary{ID: code.BatchID, Source: code.Source, Note: code.Note,
				Actor: code.Actor, CreatedAt: code.CreatedAt})
			costs = append(costs, new(big.Rat))
		}
		batch := &out[at]
		batch.Codes++
		if !containsString(batch.Items, code.ItemKey) {
			batch.Items = append(batch.Items, code.ItemKey)
		}
		if cost, ok := new(big.Rat).SetString(code.Cost); ok {
			costs[at].Add(costs[at], cost)
		}
	}
	for i := range out {
		out[i].Cost = control.FormatWalletAmount(costs[i])
	}
	if out == nil {
		out = []voucherStockBatchSummary{}
	}
	return out
}

func containsString(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

// voucherStockView is a code as the operator's listing shows it: its last four
// characters, never the sealed text or the fingerprint.
type voucherStockView struct {
	control.VoucherStockCode
	Sealed      string `json:"sealed,omitempty"`
	Fingerprint string `json:"fingerprint,omitempty"`
	Code        string `json:"code"`
}

func maskedStockCode(code control.VoucherStockCode) voucherStockView {
	return voucherStockView{VoucherStockCode: code, Code: code.Mask}
}

func maskedStockCodes(codes []control.VoucherStockCode) []voucherStockView {
	out := make([]voucherStockView, 0, len(codes))
	for _, code := range codes {
		out = append(out, maskedStockCode(code))
	}
	return out
}

func (s HTTPServer) handleVoucherStockCodes(w http.ResponseWriter, r *http.Request, stock control.VoucherStockStore) {
	query := r.URL.Query()
	limit, _ := strconv.Atoi(query.Get("limit"))
	codes, err := stock.ListVoucherStock(r.Context(), control.VoucherStockFilter{
		ItemKey: query.Get("item"),
		Status:  query.Get("status"),
		BatchID: query.Get("batch"),
		Limit:   limit,
	})
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher stock read failed", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"codes": maskedStockCodes(codes)})
}

type voucherStockRequest struct {
	Source string `json:"source"`
	Note   string `json:"note"`
	Actor  string `json:"actor"`
	Codes  []struct {
		Item      string          `json:"item"`
		Code      string          `json:"code"`
		Serial    string          `json:"serial"`
		Cost      json.RawMessage `json:"cost"`
		ExpiresOn string          `json:"expires_on"`
	} `json:"codes"`
}

// handleVoucherStockAdd checks a batch and, unless dryRun, stores it. Every
// problem comes back at once, by row, so a CSV is fixed in one pass.
func (s HTTPServer) handleVoucherStockAdd(
	w http.ResponseWriter,
	r *http.Request,
	store control.VoucherStore,
	stock control.VoucherStockStore,
	dryRun bool,
) {
	sealer := s.Vouchers.StockSealer
	if sealer == nil {
		writeSMSError(w, http.StatusServiceUnavailable, voucherCodeStockKeyUnset,
			"this relay has no stock key: set POINTY_RELAY_VOUCHER_STOCK_KEY (pointy-relay gen-stock-key) and restart it", nil)
		return
	}
	var request voucherStockRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxVoucherStockRequestBytes)).Decode(&request); err != nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "invalid request body", nil)
		return
	}
	ctx := r.Context()
	loaded, err := s.currentVoucherCatalog(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher catalog read failed", err)
		return
	}
	batch := control.VoucherStockBatch{Source: request.Source, Note: request.Note, Actor: request.Actor}
	var problems []control.VoucherStockProblem
	for i, row := range request.Codes {
		item := strings.TrimSpace(row.Item)
		if item != "" {
			if _, found := vouchers.Find(loaded.document, item); loaded.empty || !found {
				problems = append(problems, control.VoucherStockProblem{Row: i, Field: "item", Message: "no such card in the catalog"})
			}
		}
		cost := strings.TrimSpace(string(row.Cost))
		if unquoted, err := strconv.Unquote(cost); err == nil {
			cost = strings.TrimSpace(unquoted)
		}
		code := strings.TrimSpace(row.Code)
		entry := control.VoucherStockCode{ItemKey: item, Serial: row.Serial, Cost: cost, ExpiresOn: row.ExpiresOn}
		switch {
		case code == "":
			// Left unsealed: the store reports the empty code with the rest.
		case utf8.RuneCountInString(code) > control.MaxVoucherStockCodeRunes:
			problems = append(problems, control.VoucherStockProblem{Row: i, Field: "code",
				Message: fmt.Sprintf("longer than %d characters", control.MaxVoucherStockCodeRunes)})
			entry.Sealed, entry.Fingerprint = "-", fmt.Sprintf("too-long-%d", i)
		default:
			sealed, err := sealer.Seal(item, code)
			if err != nil {
				s.writeVoucherInternalError(w, "", "sealing a stock code failed", err)
				return
			}
			entry.Sealed, entry.Fingerprint, entry.Mask = sealed, sealer.Fingerprint(code), vouchers.MaskCode(code)
		}
		batch.Codes = append(batch.Codes, entry)
	}
	// With a problem already found here the store only checks: it must not
	// save a batch the operator is about to be told was refused.
	added, err := stock.AddVoucherStock(ctx, batch, dryRun || len(problems) > 0)
	var invalid *control.VoucherStockInvalidError
	switch {
	case errors.As(err, &invalid):
		problems = append(problems, invalid.Problems...)
	case err != nil:
		s.writeVoucherInternalError(w, "", "voucher stock save failed", err)
		return
	}
	if len(problems) > 0 {
		sortStockProblems(problems)
		writeSMSError(w, http.StatusUnprocessableEntity, voucherCodeInvalidRequest,
			fmt.Sprintf("%d problems; nothing was saved", len(problems)), map[string]any{"problems": problems})
		return
	}
	perItem := map[string]int{}
	for _, code := range added.Codes {
		perItem[code.ItemKey]++
	}
	if dryRun {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "codes": len(added.Codes), "per_item": perItem})
		return
	}
	s.logger().Info("card codes added to the company's stock",
		"batch_id", added.ID, "codes", len(added.Codes), "actor", added.Actor, "source", added.Source)
	// The shop view's availability may have changed: the catalog's next read
	// says so through its version.
	writeJSON(w, http.StatusCreated, map[string]any{
		"batch_id": added.ID,
		"codes":    len(added.Codes),
		"per_item": perItem,
	})
}

func sortStockProblems(problems []control.VoucherStockProblem) {
	for i := 1; i < len(problems); i++ {
		for j := i; j > 0 && problems[j].Row < problems[j-1].Row; j-- {
			problems[j], problems[j-1] = problems[j-1], problems[j]
		}
	}
}

func (s HTTPServer) handleVoucherStockVoid(w http.ResponseWriter, r *http.Request, stock control.VoucherStockStore, id string) {
	var request struct {
		Reason string `json:"reason"`
		Actor  string `json:"actor"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxVoucherRequestBytes)).Decode(&request); err != nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "invalid request body", nil)
		return
	}
	if strings.TrimSpace(request.Reason) == "" {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "reason is required", nil)
		return
	}
	code, err := stock.VoidVoucherStock(r.Context(), id, request.Actor, request.Reason)
	switch {
	case errors.Is(err, control.ErrVoucherStockNotFound):
		writeSMSError(w, http.StatusNotFound, voucherCodeNotFound, "no such stock code", nil)
	case errors.Is(err, control.ErrVoucherStockNotAvailable):
		writeSMSError(w, http.StatusConflict, "not_available", "only an available code can be voided",
			map[string]any{"status": code.Status})
	case err != nil:
		s.writeVoucherInternalError(w, "", "voucher stock void failed", err)
	default:
		s.logger().Info("a stock code was voided", "id", code.ID, "item", code.ItemKey, "actor", code.VoidedBy, "reason", code.VoidReason)
		writeJSON(w, http.StatusOK, map[string]any{"code": maskedStockCode(code)})
	}
}

type voucherStockRefundRequest struct {
	// Restock is the operator's choice: true puts the sale's codes back on the
	// shelf, false voids them. It must be said, never guessed.
	Restock *bool `json:"restock"`
	// VerifiedUnused is the operator saying they checked the card was never
	// redeemed (no supplier lets the relay ask). Putting a code back on the
	// shelf needs it: a redeemed code resold is a customer with a dead card.
	VerifiedUnused bool   `json:"verified_unused"`
	Reason         string `json:"reason"`
	Actor          string `json:"actor"`
}

// restockReason is the return reason as the code keeps it: with who confirmed
// the card unused when it went back on the shelf.
func restockReason(reason, actor string, restock bool) string {
	reason = strings.TrimSpace(reason)
	if !restock {
		return reason
	}
	who := strings.TrimSpace(actor)
	if who == "" {
		who = "the operator"
	}
	return reason + " (confirmed unused by " + who + ")"
}

const verifiedUnusedRequired = "verified_unused is required to put codes back on the shelf: check with the card's issuer that it was never redeemed"

// handleVoucherAdminStockRefund serves POST /v1/vouchers/admin/purchases/{id}/refund:
// the operator gives back a sale from stock — the shop's price returns to its
// voucher balance and the codes go back on the shelf or void, as the operator
// chose. A purchase that failed (and was refunded) only has its codes moved.
func (s HTTPServer) handleVoucherAdminStockRefund(w http.ResponseWriter, r *http.Request, id string) {
	stock, ok := s.voucherStockStore()
	if !ok {
		writeSMSError(w, http.StatusNotImplemented, voucherCodeUnavailable, "card stock is not supported by this relay's store", nil)
		return
	}
	var request voucherStockRefundRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxVoucherRequestBytes)).Decode(&request); err != nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "invalid request body", nil)
		return
	}
	if request.Restock == nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "restock is required: true puts the codes back on the shelf, false voids them", nil)
		return
	}
	if strings.TrimSpace(request.Reason) == "" {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "reason is required", nil)
		return
	}
	if *request.Restock && !request.VerifiedUnused {
		writeSMSError(w, http.StatusBadRequest, "verify_unused", verifiedUnusedRequired, nil)
		return
	}
	refund, err := stock.RefundVoucherStockSale(r.Context(), strings.TrimSpace(id), control.VoucherStockReturn{
		Restock: *request.Restock, Actor: request.Actor, Reason: restockReason(request.Reason, request.Actor, *request.Restock),
	})
	if s.writeStockRefundError(w, err) {
		return
	}
	s.logger().Info("a sale from stock was refunded by the operator",
		"purchase_id", refund.Purchase.ID, "installation_id", refund.Purchase.InstallationID,
		"refunded", refund.Refunded, "restock", *request.Restock, "codes", len(refund.Codes),
		"actor", request.Actor, "reason", request.Reason)
	writeJSON(w, http.StatusOK, map[string]any{
		"purchase": refund.Purchase,
		"refunded": refund.Refunded,
		"restock":  *request.Restock,
		"codes":    maskedStockCodes(refund.Codes),
	})
}

// writeStockRefundError answers a refused stock refund; false when err is nil.
func (s HTTPServer) writeStockRefundError(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, control.ErrVoucherPurchaseNotFound):
		writeSMSError(w, http.StatusNotFound, voucherCodeNotFound, "no such purchase", nil)
	case errors.Is(err, control.ErrVoucherNotStockSale):
		writeSMSError(w, http.StatusConflict, "not_stock_sale", "this purchase was not sold from the company's stock", nil)
	case errors.Is(err, control.ErrVoucherStockSalePending):
		writeSMSError(w, http.StatusConflict, "purchase_pending", "the purchase is still being settled: resolve it instead", nil)
	case errors.Is(err, control.ErrVoucherStockReturned):
		writeSMSError(w, http.StatusConflict, "already_returned", "this purchase's codes were already given back", nil)
	default:
		s.writeVoucherInternalError(w, "", "stock refund failed", err)
	}
	return true
}

// returnStockOfRefundedPurchase gives back the codes of a held stock purchase
// the operator just refunded (resolve), as the operator chose; by default they
// are voided, since nobody knows whether the shop handed them out. A purchase
// that never took a code has nothing to give back.
func (s HTTPServer) returnStockOfRefundedPurchase(ctx context.Context, purchase control.VoucherPurchase, restock *bool, actor, reason string) (map[string]any, error) {
	stock, ok := s.voucherStockStore()
	if !ok || purchase.Supplier != vouchers.SupplierStock || purchase.Status != control.VoucherPurchaseFailed {
		return nil, nil
	}
	back := restock != nil && *restock
	refund, err := stock.RefundVoucherStockSale(ctx, purchase.ID, control.VoucherStockReturn{
		Restock: back, Actor: actor, Reason: restockReason(reason, actor, back),
	})
	if errors.Is(err, control.ErrVoucherStockReturned) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return map[string]any{"restock": back, "codes": maskedStockCodes(refund.Codes)}, nil
}
