package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// The company buys for itself what it sells the shops — a card to pay for a
// subscription, a top-up, a bill, cards to sell on for cash or to give away —
// through the operator console (admin token):
//
//	POST /v1/vouchers/admin/company/cards     {item, quantity, idempotency_key, purpose, note, actor}
//	POST /v1/vouchers/admin/company/services  a service order (as POST /v1/services/orders) + purpose, note, actor
//	GET  /v1/vouchers/admin/purchases?buyer=company   the listing, narrowed to them
//	POST /v1/vouchers/admin/company/purchases/{id}/reveal   its codes (a card) or receipt (a top-up, a bill)
//
// It is the shops' purchase path with no shop: the same ledger row, the same
// cheapest-supplier choice and fall-back, the same holds and reconciler. What
// differs: no wallet is charged or refunded, the company's own card stock is
// never sold to it (those codes are its own already), and the row says why it
// was bought (purpose) and carries what it is expected to cost in dinars. On
// the company's books its cost is its own spending («مشتريات الشركة»), apart
// from what the services cost to sell; cash it gets back selling one on is
// written in the ledger as income.
//
// The codes are shown to the operator who bought them, and later only on a
// passkey tap (reveal). A shop's codes are never shown to an operator: reveal
// refuses a shop's purchase.

const maxCompanyNoteRunes = 200

type companyPurchaseFields struct {
	Purpose string `json:"purpose"`
	Note    string `json:"note"`
	Actor   string `json:"actor"`
}

// companyBuyer reads why the company buys and who asked, refusing a purpose
// it does not know.
func companyBuyer(w http.ResponseWriter, fields companyPurchaseFields) (voucherBuyer, string, bool) {
	purpose := strings.TrimSpace(fields.Purpose)
	if !control.ValidVoucherPurpose(purpose) {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest,
			"purpose must be own_use, resale, gift or other", nil)
		return voucherBuyer{}, "", false
	}
	note := strings.TrimSpace(fields.Note)
	if utf8.RuneCountInString(note) > maxCompanyNoteRunes {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "note is too long", nil)
		return voucherBuyer{}, "", false
	}
	actor := strings.TrimSpace(fields.Actor)
	if utf8.RuneCountInString(actor) > maxWalletRequestedByRunes {
		actor = string([]rune(actor)[:maxWalletRequestedByRunes])
	}
	return voucherBuyer{Purpose: purpose, Note: note}, actor, true
}

// handleCompanyRoutes serves /v1/vouchers/admin/company/...
func (s HTTPServer) handleCompanyRoutes(w http.ResponseWriter, r *http.Request, store control.VoucherStore, path string) {
	switch {
	case path == "/cards" && r.Method == http.MethodPost:
		s.handleCompanyCards(w, r, store)
	case path == "/services" && r.Method == http.MethodPost:
		s.handleCompanyServices(w, r, store)
	case strings.HasPrefix(path, "/purchases/") && strings.HasSuffix(path, "/reveal") && r.Method == http.MethodPost:
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/purchases/"), "/reveal")
		s.handleCompanyReveal(w, r, store, id)
	default:
		writeNotFound(w)
	}
}

func (s HTTPServer) handleCompanyCards(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	if !s.Vouchers.Configured() {
		writeSMSError(w, http.StatusServiceUnavailable, voucherCodeUnavailable, "cards are not configured on this relay", nil)
		return
	}
	body, ok := readCompanyBody(w, r)
	if !ok {
		return
	}
	var fields companyPurchaseFields
	_ = json.Unmarshal(body, &fields)
	buyer, actor, ok := companyBuyer(w, fields)
	if !ok {
		return
	}
	request, ok := decodeVoucherPurchase(w, withBody(r, body))
	if !ok {
		return
	}
	request.RequestedBy = actor
	request.maxUnitPrice = nil
	s.placeCardPurchase(w, r, store, buyer, request)
}

func (s HTTPServer) handleCompanyServices(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	if _, ok := s.requireServices(w); !ok {
		return
	}
	body, ok := readCompanyBody(w, r)
	if !ok {
		return
	}
	var fields companyPurchaseFields
	_ = json.Unmarshal(body, &fields)
	buyer, actor, ok := companyBuyer(w, fields)
	if !ok {
		return
	}
	request, ok := decodeServiceOrder(w, withBody(r, body))
	if !ok {
		return
	}
	request.RequestedBy = actor
	request.maxUnitPrice = nil
	s.placeServiceOrder(w, r, store, buyer, request)
}

// readCompanyBody reads the request once: the purpose fields and the order
// are two views of the same JSON object.
func readCompanyBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	limit := max(int64(maxVoucherRequestBytes), int64(maxServiceRequestBytes))
	var raw json.RawMessage
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, limit)).Decode(&raw); err != nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "invalid request body", nil)
		return nil, false
	}
	return raw, true
}

func withBody(r *http.Request, body []byte) *http.Request {
	clone := r.Clone(r.Context())
	clone.Body = io.NopCloser(bytes.NewReader(body))
	clone.ContentLength = int64(len(body))
	return clone
}

// handleCompanyReveal shows the codes of a card, or the receipt of a top-up or
// a bill, the company bought for itself, read back from the supplier.
func (s HTTPServer) handleCompanyReveal(w http.ResponseWriter, r *http.Request, store control.VoucherStore, id string) {
	purchase, err := store.GetVoucherPurchase(r.Context(), strings.TrimSpace(id))
	switch {
	case errors.Is(err, control.ErrVoucherPurchaseNotFound):
		writeSMSError(w, http.StatusNotFound, voucherCodeNotFound, "no such purchase", nil)
		return
	case err != nil:
		s.writeVoucherInternalError(w, "", "voucher purchase read failed", err)
		return
	case !purchase.ForCompany():
		// A shop's codes are the shop's: no operator reads them.
		writeSMSError(w, http.StatusForbidden, "not_company", "only the company's own purchases can be revealed", nil)
		return
	}
	ctx := context.WithoutCancel(r.Context())
	if control.NormalizeVoucherKind(purchase.Kind) != control.VoucherKindCard {
		receipt, pending := s.serviceReceipt(ctx, purchase)
		writeJSON(w, http.StatusOK, map[string]any{
			"purchase": companyPurchasePayload(purchase, nil, false),
			"receipt":  nonNilReceipt(receipt), "receipt_pending": pending,
		})
		return
	}
	codes, pending := s.voucherCodes(ctx, purchase)
	writeJSON(w, http.StatusOK, map[string]any{"purchase": companyPurchasePayload(purchase, codes, pending)})
}

func nonNilReceipt(receipt map[string]string) map[string]string {
	if receipt == nil {
		return map[string]string{}
	}
	return receipt
}

// companyPurchasePayload is the shop's view of a purchase with what only the
// company's own carries.
func companyPurchasePayload(purchase control.VoucherPurchase, codes []vouchers.Code, codesPending bool) map[string]any {
	payload := voucherPurchasePayload(purchase, codes, codesPending)
	payload["purpose"] = purchase.Purpose
	payload["note"] = purchase.Note
	payload["requested_by"] = purchase.RequestedBy
	payload["supplier_cost"] = purchase.SupplierCost
	payload["supplier_currency"] = purchase.SupplierCurrency
	return payload
}

// withoutStock leaves the company's own stock out of a ranking.
func (r supplierRanking) withoutStock() supplierRanking {
	kept := r.Candidates[:0:0]
	for _, candidate := range r.Candidates {
		if candidate.Ref.Supplier != vouchers.SupplierStock {
			kept = append(kept, candidate)
		}
	}
	r.Candidates = kept
	return r
}

// companyCardCost is what one card should cost the company: the cheapest
// supplier's price in dinars when known, else what shops pay for it.
func companyCardCost(first supplierEvaluation, item vouchers.Item, now time.Time) *big.Rat {
	if first.Cost != nil && first.Cost.Sign() > 0 {
		return companyDinars(first.Cost)
	}
	price, ok := new(big.Rat).SetString(strings.TrimSpace(vouchers.PriceAt(item, now).UnitPrice))
	if !ok {
		price = new(big.Rat)
	}
	return companyDinars(price)
}

// companyDinars rounds a cost up to the ledger's thousandth of a dinar, never
// to nothing: an estimate of spending errs high.
func companyDinars(value *big.Rat) *big.Rat {
	thousandths := new(big.Rat).Mul(value, big.NewRat(1000, 1))
	n := new(big.Int).Quo(thousandths.Num(), thousandths.Denom())
	if new(big.Rat).SetInt(n).Cmp(thousandths) < 0 {
		n.Add(n, big.NewInt(1))
	}
	if n.Sign() <= 0 {
		n.SetInt64(1)
	}
	return new(big.Rat).SetFrac(n, big.NewInt(1000))
}
