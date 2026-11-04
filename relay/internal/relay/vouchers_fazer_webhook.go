package relay

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// FazerCards fulfils an order after charging for it, sometimes minutes later
// (a 1 EGP Amazon code took 2m43s on 2026-11-03). Its webhook is how the relay
// hears at once that one finished, instead of on the reconciler's next round.
//
// A delivery is only a nudge. Its payload is not documented, so the relay
// believes nothing in it: it reads every held FazerCards purchase back over
// the API, the same way the reconciler does. A forged delivery can only make
// the relay ask FazerCards a little early.
const (
	fazerWebhookPath = "/v1/vouchers/fazer/webhook"
	// fazerWebhookBudget bounds the read-backs one delivery starts; anything
	// left over is the reconciler's. Webhook senders give up on a slow answer.
	fazerWebhookBudget = 8 * time.Second
	// fazerWebhookChecks is the most held purchases one delivery reads back.
	fazerWebhookChecks  = 20
	maxFazerWebhookBody = 64 << 10
)

// FazerWebhookToken is the secret in the webhook URL that FazerCards is given,
// derived from the company's API key, so it needs no setting of its own.
// Rotating the key changes it: register the webhook again after.
func FazerWebhookToken(apiKey string) string {
	apiKey = strings.TrimSpace(apiKey)
	if apiKey == "" {
		return ""
	}
	mac := hmac.New(sha256.New, []byte(apiKey))
	mac.Write([]byte("pointy-fazer-webhook/v1"))
	return hex.EncodeToString(mac.Sum(nil))[:32]
}

// fazerWebhookURL is where FazerCards should post: the relay's public https
// origin, or "" when it has none FazerCards could reach.
func (s HTTPServer) fazerWebhookURL(r *http.Request) string {
	base := s.walletWebhookBase(r)
	parsed, err := url.Parse(base)
	if err != nil || parsed.Scheme != "https" || !publicWebhookHost(parsed.Hostname()) || s.Vouchers.FazerWebhookToken == "" {
		return ""
	}
	return base + fazerWebhookPath + "?token=" + s.Vouchers.FazerWebhookToken
}

// maskWebhookToken shows a webhook URL without its secret.
func maskWebhookToken(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	query := parsed.Query()
	if query.Get("token") != "" {
		query.Set("token", "…")
		parsed.RawQuery = query.Encode()
	}
	return parsed.String()
}

// handleFazerWebhook serves POST /v1/vouchers/fazer/webhook?token=…:
// FazerCards saying something changed on the account.
func (s HTTPServer) handleFazerWebhook(w http.ResponseWriter, r *http.Request) {
	token := s.Vouchers.FazerWebhookToken
	if s.Vouchers.Fazer == nil || token == "" {
		writeNotFound(w)
		return
	}
	if !hmac.Equal([]byte(r.URL.Query().Get("token")), []byte(token)) {
		s.metrics().RecordCredentialRejected()
		s.logger().Warn("fazercards webhook with a wrong token ignored")
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid token"})
		return
	}
	body, _ := io.ReadAll(io.LimitReader(r.Body, maxFazerWebhookBody))
	event, orderID := fazerWebhookSummary(body)
	// The headers' names (never their values) say how FazerCards signs, which
	// its spec does not.
	names := make([]string, 0, len(r.Header))
	for name := range r.Header {
		names = append(names, name)
	}
	sort.Strings(names)
	signature := s.checkFazerSignature(r.Context(), r.Header, body)
	switch {
	case signature.Scheme != "":
	case signature.Enforced:
		// FazerCards has been seen to sign: this one is not FazerCards.
		s.metrics().RecordCredentialRejected()
		s.logger().Warn("fazercards webhook with a bad signature refused", "signature", signature.Shape, "headers", names)
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid signature"})
		return
	case !signature.NoSecret:
		s.logger().Warn("fazercards webhook signature not recognised; taken as a nudge until one verifies",
			"signature", signature.Shape, "headers", names)
	}
	s.logger().Info("fazercards webhook received", "event", event, "order_id", orderID, "headers", names,
		"verified", signature.Scheme)

	store, ok := s.voucherStore()
	if !ok {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ignored", "reason": "this relay keeps no purchases"})
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), fazerWebhookBudget)
	defer cancel()
	checked, settled := s.checkHeldFazerPurchases(ctx, store, orderID)
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "checked": checked, "settled": settled})
}

// checkHeldFazerPurchases reads back the held FazerCards purchases that have
// an order there, the one named first. A purchase with no order id yet is
// still in its own request, or lost before FazerCards answered: the
// reconciler sees to those.
func (s HTTPServer) checkHeldFazerPurchases(ctx context.Context, store control.VoucherStore, first string) (checked, settled int) {
	// The zero time lists only held purchases.
	held, err := store.ListVoucherPurchasesAwaitingCheck(ctx, time.Time{}, voucherAwaitingBatch)
	if err != nil {
		s.logger().Error("fazercards webhook: listing held purchases failed", "error", err)
		return 0, 0
	}
	var ours []control.VoucherPurchase
	for _, purchase := range held {
		if purchase.Supplier == vouchers.SupplierFazer && purchase.SupplierOrderID != "" {
			ours = append(ours, purchase)
		}
	}
	sort.SliceStable(ours, func(i, j int) bool {
		return ours[i].SupplierOrderID == first && ours[j].SupplierOrderID != first
	})
	for _, purchase := range ours {
		if checked == fazerWebhookChecks || ctx.Err() != nil {
			break
		}
		checked++
		after, _, err := s.checkVoucherPurchase(ctx, store, purchase)
		if err == nil && after.Status != control.VoucherPurchasePending {
			settled++
			s.advanceOrderOf(ctx, store, after)
		}
	}
	return checked, settled
}

// advanceOrderOf takes a customer's order on as soon as its purchase settles,
// so the customer hears now rather than on the next sweep.
func (s HTTPServer) advanceOrderOf(ctx context.Context, cards control.VoucherStore, purchase control.VoucherPurchase) {
	orders, ok := s.Store.(control.CustomerOrderStore)
	if !ok || !purchase.ForCustomer() || purchase.Note == "" {
		return
	}
	order, err := orders.GetCustomerOrder(ctx, purchase.Note)
	if err != nil {
		s.logger().Warn("fazercards webhook: reading the purchase's customer order failed",
			"purchase_id", purchase.ID, "order_id", purchase.Note, "error", err)
		return
	}
	if order.Status == control.CustomerOrderFulfilling {
		s.advanceCustomerOrder(ctx, orders, cards, order, false)
	}
}

// fazerWebhookSummary reads, for the log, the event a delivery names and the
// order it is about, under the spellings such payloads use.
func fazerWebhookSummary(body []byte) (event, orderID string) {
	var payload map[string]any
	if json.Unmarshal(body, &payload) != nil {
		return "", ""
	}
	text := func(object map[string]any, keys ...string) string {
		for _, key := range keys {
			if value, ok := object[key].(string); ok && strings.TrimSpace(value) != "" {
				return strings.TrimSpace(value)
			}
		}
		return ""
	}
	event = text(payload, "event", "type", "event_type")
	orderID = text(payload, "order_id", "orderId")
	for _, key := range []string{"order", "data"} {
		nested, _ := payload[key].(map[string]any)
		if nested == nil || orderID != "" {
			continue
		}
		orderID = text(nested, "order_id", "orderId", "id")
		if inner, _ := nested["order"].(map[string]any); inner != nil && orderID == "" {
			orderID = text(inner, "id", "order_id")
		}
	}
	if len(event) > 64 {
		event = event[:64]
	}
	if len(orderID) > 64 {
		orderID = orderID[:64]
	}
	return event, orderID
}

// handleVoucherAdminFazerWebhook is the operator's view of FazerCards' webhook
// (GET), and pointing it at this relay (POST), which also has FazerCards send
// its test event. The secret FazerCards signs with is never shown.
func (s HTTPServer) handleVoucherAdminFazerWebhook(w http.ResponseWriter, r *http.Request) {
	client := s.Vouchers.Fazer
	if client == nil {
		writeSMSError(w, http.StatusServiceUnavailable, "supplier_unconfigured", "FazerCards is not configured on this relay", nil)
		return
	}
	ctx := r.Context()
	expected := s.fazerWebhookURL(r)
	answer := map[string]any{"expected_url": maskWebhookToken(expected)}
	if r.Method == http.MethodPost {
		if expected == "" {
			writeSMSError(w, http.StatusConflict, "no_public_url",
				"this relay has no public https address FazerCards could post to", nil)
			return
		}
		if err := client.SetWebhook(ctx, expected, true); err != nil {
			writeSMSError(w, http.StatusBadGateway, "supplier_error", err.Error(), nil)
			return
		}
		test, err := client.TestWebhook(ctx)
		if err != nil {
			writeSMSError(w, http.StatusBadGateway, "supplier_error", err.Error(), nil)
			return
		}
		answer["test"] = map[string]any{"delivered": test.Delivered, "status": test.Status, "error": test.Error}
		s.logger().Info("operator pointed the fazercards webhook at this relay",
			"actor", adminActor(r, ""), "test_delivered", test.Delivered, "test_status", test.Status)
	}
	hook, set, err := client.Webhook(ctx)
	if err != nil {
		writeSMSError(w, http.StatusBadGateway, "supplier_error", err.Error(), nil)
		return
	}
	answer["set"] = set
	if set {
		answer["url"] = maskWebhookToken(hook.URL)
		answer["ours"] = expected != "" && hook.URL == expected
		answer["enabled"] = hook.Enabled
		answer["consecutive_failures"] = hook.ConsecutiveFailures
		answer["last_success_at"] = hook.LastSuccessAt
		answer["last_failure_at"] = hook.LastFailureAt
		answer["last_failure_reason"] = hook.LastFailureReason
	}
	writeJSON(w, http.StatusOK, answer)
}
