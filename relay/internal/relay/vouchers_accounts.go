package relay

import (
	"context"
	"encoding/json"
	"errors"

	"net/http"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
	"pointy/relay/internal/vouchers"
)

// Cards sent to an account (vouchers/target.go): a game topped up by its
// player ID, Telegram Stars sent to a username, a Steam wallet topped up by its
// login. The buyer types the account; the purchase carries it to the supplier
// and keeps it masked; it succeeds with no code.
//
// A shop's catalog lists such brands only when its backend says it can ask
// for an account (?accounts=1): an older one would offer a card it cannot sell.

const (
	voucherCodeAccountRequired = "account_required"
	voucherCodeInvalidAccount  = "invalid_account"
	voucherCodeNotAnAccount    = "not_an_account_card"
	voucherCodeCheckFailed     = "check_failed"

	// accountChecksPerWindow bounds the account checks one shop or customer
	// makes: each one asks the supplier, and none of them spends anything.
	accountChecksPerWindow = 30
	accountCheckWindow     = time.Minute
	accountCheckBudget     = 20 * time.Second
)

var accountCheckPolicy = ratelimit.Policy{Limit: accountChecksPerWindow, Window: accountCheckWindow}

// accountPurchase reports whether a purchase sent credit to an account (a card
// row with a target) rather than handing over codes.
func accountPurchase(purchase control.VoucherPurchase) bool {
	return control.NormalizeVoucherKind(purchase.Kind) == control.VoucherKindCard && purchase.Target != ""
}

// purchaseDelivery is how a card purchase is delivered, as its payload says it.
func purchaseDelivery(purchase control.VoucherPurchase) string {
	if accountPurchase(purchase) {
		return "account"
	}
	return "codes"
}

// purchaseRefusal is a purchase request refused for its account.
type purchaseRefusal struct {
	status  int
	code    string
	message string
	extra   map[string]any
}

func (r *purchaseRefusal) write(w http.ResponseWriter) {
	writeSMSError(w, r.status, r.code, r.message, r.extra)
}

func (r *purchaseRefusal) writeCustomer(w http.ResponseWriter) {
	writeCustomerError(w, r.status, r.code, r.message, r.extra)
}

// readPurchaseAccount checks the account a purchase carries against its
// brand: a brand sent to an account needs one (and one card at a time), any
// other brand takes none.
func readPurchaseAccount(located vouchers.Located, values map[string]string, quantity int) (vouchers.Account, *purchaseRefusal) {
	target := located.Brand.Target
	if target == nil {
		for _, value := range values {
			if strings.TrimSpace(value) != "" {
				return nil, &purchaseRefusal{status: http.StatusBadRequest, code: voucherCodeNotAnAccount,
					message: "this card is a code: it takes no account"}
			}
		}
		return nil, nil
	}
	if quantity != 1 {
		return nil, &purchaseRefusal{status: http.StatusBadRequest, code: voucherCodeInvalidQuantity,
			message: "a card sent to an account is bought one at a time", extra: map[string]any{"max_quantity": 1}}
	}
	account, err := target.ReadAccount(values)
	var problem *vouchers.AccountProblem
	switch {
	case errors.Is(err, vouchers.ErrAccountRequired):
		return nil, &purchaseRefusal{status: http.StatusBadRequest, code: voucherCodeAccountRequired,
			message: "this card is sent to an account: the account is required",
			extra:   map[string]any{"target": target}}
	case errors.As(err, &problem):
		return nil, &purchaseRefusal{status: http.StatusBadRequest, code: voucherCodeInvalidAccount,
			message: problem.Error(), extra: map[string]any{"field": problem.Field}}
	case err != nil:
		return nil, &purchaseRefusal{status: http.StatusBadRequest, code: voucherCodeInvalidAccount, message: err.Error()}
	}
	return account, nil
}

// maskedAccount is the account as the purchase row keeps it.
func maskedAccount(located vouchers.Located, account vouchers.Account) string {
	if located.Brand.Target == nil || !account.Present() {
		return ""
	}
	return located.Brand.Target.MaskAccount(account)
}

// accountDetails is what the purchase row says about whose account it was:
// its kind (the account itself is in Target, masked).
func accountDetails(located vouchers.Located) json.RawMessage {
	if located.Brand.Target == nil {
		return nil
	}
	details, _ := json.Marshal(map[string]string{"account_kind": located.Brand.Target.Kind})
	return details
}

// withoutAccountBrands is the shop view for a backend that cannot ask for an
// account: brands sent to one are left out, and the version says so.
func withoutAccountBrands(view vouchers.ShopView) vouchers.ShopView {
	brands := make([]vouchers.ShopBrand, 0, len(view.Brands))
	used := map[string]bool{}
	for _, brand := range view.Brands {
		if brand.Target != nil {
			continue
		}
		brands = append(brands, brand)
		used[brand.Category] = true
	}
	if len(brands) == len(view.Brands) {
		return view
	}
	categories := make([]vouchers.ShopCategory, 0, len(view.Categories))
	for _, category := range view.Categories {
		if used[category.Key] {
			categories = append(categories, category)
		}
	}
	view.Brands, view.Categories = brands, categories
	view.Version += "-c"
	return view
}

// wantsAccountBrands reports whether a catalog request says its backend can
// ask for an account.
func wantsAccountBrands(r *http.Request) bool {
	switch strings.ToLower(strings.TrimSpace(r.URL.Query().Get("accounts"))) {
	case "1", "true", "yes":
		return true
	}
	return false
}

// accountCheckRequest is what a check is asked for: one card, and the account
// typed for it.
type accountCheckRequest struct {
	Item    string            `json:"item"`
	Account map[string]string `json:"account"`
}

// accountCheckAnswer is what a check found.
type accountCheckAnswer struct {
	vouchers.AccountCheck
	// Account is the account as read (a username's @ dropped), on one line.
	Account string `json:"account"`
}

// checkAccount runs one account check for a card: read the account against
// its brand, then ask the first of its suppliers that can look it up. A
// refusal is written by the caller.
func (s HTTPServer) checkAccount(ctx context.Context, store control.VoucherStore, request accountCheckRequest, review bool) (accountCheckAnswer, *purchaseRefusal, error) {
	loaded, err := s.currentVoucherCatalog(ctx, store)
	if err != nil {
		return accountCheckAnswer{}, nil, err
	}
	located, found := vouchers.Find(loaded.document, strings.TrimSpace(request.Item))
	if loaded.empty || !found {
		return accountCheckAnswer{}, &purchaseRefusal{status: http.StatusNotFound, code: voucherCodeUnknownItem,
			message: "no such card in the catalog"}, nil
	}
	if located.Brand.Target == nil {
		return accountCheckAnswer{}, &purchaseRefusal{status: http.StatusBadRequest, code: voucherCodeNotAnAccount,
			message: "this card is a code: it takes no account"}, nil
	}
	account, refusal := readPurchaseAccount(located, request.Account, 1)
	if refusal != nil {
		return accountCheckAnswer{}, refusal, nil
	}
	target := *located.Brand.Target
	answer := accountCheckAnswer{AccountCheck: vouchers.AccountCheck{Status: vouchers.AccountUnchecked}, Account: target.Line(account)}
	checker, ref, ok := s.accountChecker(located, review)
	if !ok {
		return answer, nil, nil
	}
	callCtx, cancel := context.WithTimeout(ctx, accountCheckBudget)
	defer cancel()
	result, err := checker.CheckAccount(callCtx, ref, target, account)
	if err != nil {
		s.logger().Warn("an account check failed", "item", located.Item.Key, "supplier", ref.Supplier, "error", err)
		return accountCheckAnswer{}, &purchaseRefusal{status: http.StatusBadGateway, code: voucherCodeCheckFailed,
			message: "the account could not be checked right now; try again or buy without checking"}, nil
	}
	answer.AccountCheck = result
	return answer, nil, nil
}

// accountChecker is the supplier that looks a card's accounts up: in test mode
// (or for the stores' review account) the test supplier, otherwise the first of
// the item's suppliers that can.
func (s HTTPServer) accountChecker(located vouchers.Located, review bool) (vouchers.TargetChecker, vouchers.Ref, bool) {
	if s.Vouchers.TestMode || review {
		return vouchers.TestSupplier{Plain: review}, vouchers.Ref{Supplier: vouchers.SupplierTest}, true
	}
	refs, err := vouchers.ParseRefs(located.Item)
	if err != nil {
		return nil, vouchers.Ref{}, false
	}
	for _, ref := range refs {
		supplier, ok := s.Vouchers.Suppliers[ref.Supplier]
		if !ok {
			continue
		}
		if checker, ok := supplier.(vouchers.TargetChecker); ok {
			return checker, ref, true
		}
	}
	return nil, vouchers.Ref{}, false
}

// limitAccountChecks is the per-buyer guard on checks. It fails open: a check
// spends nothing.
func (s HTTPServer) limitAccountChecks(ctx context.Context, key string) (time.Time, bool) {
	if s.RateLimiter == nil {
		return time.Time{}, false
	}
	decision, err := s.RateLimiter.Allow(ctx, "account-check:"+key, accountCheckPolicy)
	if err != nil || decision.Allowed {
		return time.Time{}, false
	}
	return decision.ResetAt, true
}

// handleVoucherAccountCheck serves POST /v1/vouchers/accounts/check: a shop
// looking up the account a customer typed before selling the card.
func (s HTTPServer) handleVoucherAccountCheck(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireVouchers(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	var request accountCheckRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxVoucherRequestBytes)).Decode(&request); err != nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "invalid request body", nil)
		return
	}
	if resetAt, limited := s.limitAccountChecks(r.Context(), "shop:"+installation.ID); limited {
		w.Header().Set("Retry-After", retryAfterSeconds(resetAt, s.clock().Now()))
		writeSMSError(w, http.StatusTooManyRequests, voucherCodeRateLimited, "too many account checks; retry shortly", nil)
		return
	}
	answer, refusal, err := s.checkAccount(r.Context(), store, request, false)
	switch {
	case err != nil:
		s.writeVoucherInternalError(w, installation.ID, "account check failed", err)
	case refusal != nil:
		refusal.write(w)
	default:
		writeJSON(w, http.StatusOK, answer)
	}
}

// handleVoucherAdminAccountCheck serves POST /v1/vouchers/admin/accounts/check:
// the operator looking up the account a card for the company is sent to.
func (s HTTPServer) handleVoucherAdminAccountCheck(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	var request accountCheckRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxVoucherRequestBytes)).Decode(&request); err != nil {
		writeSMSError(w, http.StatusBadRequest, voucherCodeInvalidRequest, "invalid request body", nil)
		return
	}
	answer, refusal, err := s.checkAccount(r.Context(), store, request, false)
	switch {
	case err != nil:
		s.writeVoucherInternalError(w, "", "account check failed", err)
	case refusal != nil:
		refusal.write(w)
	default:
		writeJSON(w, http.StatusOK, answer)
	}
}

// handleCustomerAccountCheck serves POST /v1/customers/accounts/check.
func (s HTTPServer) handleCustomerAccountCheck(w http.ResponseWriter, r *http.Request, customer control.Customer) {
	_, cards, ok := s.customerOrderStores(w)
	if !ok {
		return
	}
	var request accountCheckRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	if resetAt, limited := s.limitAccountChecks(r.Context(), "customer:"+customer.ID); limited {
		w.Header().Set("Retry-After", retryAfterSeconds(resetAt, s.clock().Now()))
		writeCustomerError(w, http.StatusTooManyRequests, "rate_limited", "too many account checks; retry shortly", nil)
		return
	}
	answer, refusal, err := s.checkAccount(r.Context(), cards, request, s.Customers.isReviewPhone(customer.Phone))
	switch {
	case err != nil:
		s.customerInternalError(w, "account check failed", err)
	case refusal != nil:
		refusal.writeCustomer(w)
	default:
		writeJSON(w, http.StatusOK, answer)
	}
}

// sameAccountTyped reports whether a replayed order names the account the
// first one did.
func sameAccountTyped(stored, requested map[string]string) bool {
	clean := func(account map[string]string) map[string]string {
		out := map[string]string{}
		for key, value := range account {
			if key, value = strings.TrimSpace(key), strings.TrimSpace(value); key != "" && value != "" {
				out[key] = strings.TrimPrefix(value, "@")
			}
		}
		return out
	}
	a, b := clean(stored), clean(requested)
	if len(a) != len(b) {
		return false
	}
	for key, value := range a {
		if b[key] != value {
			return false
		}
	}
	return true
}

// customerAccountLine is an order's account on one line, for the customer.
func customerAccountLine(account map[string]string) string {
	if len(account) == 0 {
		return ""
	}
	return vouchers.Target{}.Line(vouchers.Account(account))
}

// customerAccountValues is an order's account by field, for the customer; an
// empty object for an order that went to none.
func customerAccountValues(account map[string]string) map[string]string {
	if account == nil {
		return map[string]string{}
	}
	return account
}

// customerOrderDelivery is how an order is delivered, as its payload says it.
func customerOrderDelivery(order control.CustomerOrder) string {
	if len(order.Account) > 0 {
		return "account"
	}
	return "codes"
}
