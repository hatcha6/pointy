package relay

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/dafa"
)

// Learning that a payment went through, and crediting it. Everything here
// ends in settleFromPayment, which credits only what Dafa itself said in
// answer to the relay — never a webhook body, never the app's word.

// errWalletPaymentMismatch is Dafa answering about another payment than the
// one the top-up started. It should be impossible; nothing is credited.
var errWalletPaymentMismatch = errors.New("dafa answered about another payment")

// walletGateway is the relay's side of a Dafa payment.
type walletGateway struct {
	config WalletConfig
	store  control.WalletStore
	logger *slog.Logger
}

func (s HTTPServer) walletGateway(store control.WalletStore) walletGateway {
	return walletGateway{config: s.Wallet, store: store, logger: s.logger()}
}

// verify reads the payment back from Dafa and credits it if it is paid. A
// top-up already paid, or one that never got as far as a payment, is
// returned as it is.
func (g walletGateway) verify(ctx context.Context, topUp control.WalletTopUp, source string) (control.WalletTopUp, bool, error) {
	if topUp.Status == control.WalletTopUpPaid || topUp.ProviderTransactionID == "" {
		return topUp, false, nil
	}
	payment, err := g.config.dafaClient().Payment(ctx, topUp.ProviderTransactionID)
	if err != nil {
		return topUp, false, err
	}
	return g.settleFromPayment(ctx, topUp, payment, source)
}

// settleFromPayment credits a top-up that Dafa's answer shows paid. An unpaid
// payment leaves it as it was. A paid one that does not match what the top-up
// asked for — another amount, the other environment — is closed for the
// operator and credits nothing: silently crediting either figure would be
// wrong one way or the other.
func (g walletGateway) settleFromPayment(
	ctx context.Context,
	topUp control.WalletTopUp,
	payment dafa.Payment,
	source string,
) (control.WalletTopUp, bool, error) {
	if topUp.ProviderTransactionID != "" && payment.ID != topUp.ProviderTransactionID {
		g.logger.Error("dafa answered about another payment than the top-up started; not credited",
			"top_up_id", topUp.ID, "payment_id", topUp.ProviderTransactionID, "answered_id", truncateRunes(payment.ID, 64))
		return topUp, false, errWalletPaymentMismatch
	}
	if !payment.IsPaid || topUp.Status == control.WalletTopUpPaid {
		return topUp, false, nil
	}
	if payment.WorkspaceKnown && payment.TestWorkspace != topUp.TestMode {
		detail := fmt.Sprintf("dafa reports payment %s as test=%v on a test=%v top-up; reconcile by hand",
			payment.ID, payment.TestWorkspace, topUp.TestMode)
		return g.hold(ctx, topUp, walletCodeEnvironmentMismatch, detail, source)
	}
	if !walletAmountsEqual(payment.Amount, topUp.Amount) {
		detail := fmt.Sprintf("dafa reports %s paid for a %s top-up (payment %s); reconcile by hand",
			truncateRunes(payment.Amount, 32), topUp.Amount, payment.ID)
		return g.hold(ctx, topUp, walletCodeAmountMismatch, detail, source)
	}
	description := "شحن المحفظة " + topUp.InvoiceNo
	if method, ok := lookupWalletMethod(topUp.Method); ok {
		description = "شحن عبر " + method.NameAr + " " + topUp.InvoiceNo
	}
	settled, applied, err := g.store.SettleWalletTopUp(ctx, topUp.ID, control.WalletTopUpSettlement{
		ProviderTransactionID: payment.ID,
		ConfirmedBy:           walletConfirmedByGateway,
		Description:           description,
	})
	if err != nil {
		return topUp, false, err
	}
	if applied {
		logWalletTopUpEvent(g.logger, settled.InstallationID, settled, "paid_"+source, "")
		alertWalletTopUp(g.config.Alerts, settled, "paid_"+source, "")
	}
	return settled, applied, nil
}

// hold closes a paid-but-wrong top-up for the operator. An already closed one
// keeps its first verdict but is reported all the same.
func (g walletGateway) hold(
	ctx context.Context,
	topUp control.WalletTopUp,
	code, detail, source string,
) (control.WalletTopUp, bool, error) {
	closed, _, err := g.store.CloseWalletTopUp(ctx, topUp.ID, control.WalletTopUpFailed, code, detail)
	if err != nil {
		return topUp, false, err
	}
	if closed.Status != control.WalletTopUpFailed || closed.ErrorCode != code {
		// Closed before as something else (cancelled, declined): the money is
		// in all the same, so say so loudly.
		g.logger.Error("a closed wallet top-up was paid at Dafa with a mismatch; reconcile by hand",
			"top_up_id", topUp.ID, "status", closed.Status, "reason", code, "detail", detail)
	}
	logWalletTopUpEvent(g.logger, closed.InstallationID, closed, "held_"+source, detail)
	alertWalletTopUp(g.config.Alerts, closed, "held_"+source, detail)
	return closed, false, nil
}

// walletTopUpWorthChecking reports whether reading the payment back can tell
// the relay anything: it is open, it has a payment, and that payment can
// complete without the relay — a bank card on Dafa's page, or a code whose
// answer may have been lost. An OTP payment nobody sent a code for can only
// be paid by the relay itself.
func walletTopUpWorthChecking(topUp control.WalletTopUp) bool {
	if !control.WalletTopUpOpen(topUp.Status) || topUp.ProviderTransactionID == "" {
		return false
	}
	method, ok := lookupWalletMethod(topUp.Method)
	if !ok {
		return false
	}
	return method.kind() == walletKindHostedPage || topUp.OTPAttempts > 0
}

// --- the webhook ---

// walletWebhookToken is the per-top-up secret in the webhook URL. Dafa does
// not sign its webhook, so the token is what keeps a stranger from making the
// relay call Dafa on a guessed id. It is keyed with the Dafa key itself, which
// only the relay holds; a key change voids the outstanding ones, and the sweep
// catches what their webhooks would have said.
func (c WalletConfig) walletWebhookToken(topUpID string) string {
	mac := hmac.New(sha256.New, []byte(strings.TrimSpace(c.DafaAPIKey)))
	mac.Write([]byte("pointy-wallet-webhook/v1:" + topUpID))
	return hex.EncodeToString(mac.Sum(nil))[:32]
}

// walletWebhookBase is the relay's public origin: the operator's PublicURL,
// else the address the shop's backend reached it at.
func (s HTTPServer) walletWebhookBase(r *http.Request) string {
	base := strings.TrimRight(strings.TrimSpace(s.Wallet.PublicURL), "/")
	if base == "" && r != nil {
		scheme := "http"
		if r.TLS != nil || strings.EqualFold(firstForwardedValue(r.Header.Get("X-Forwarded-Proto")), "https") {
			scheme = "https"
		}
		host := firstForwardedValue(r.Header.Get("X-Forwarded-Host"))
		if host == "" {
			host = r.Host
		}
		base = scheme + "://" + host
	}
	return base
}

// walletWebhookURL is where Dafa posts about this top-up's payment. Only a
// public https origin is handed out: Dafa cannot reach a loopback or private
// address — it would be posting to its own network — and the sweep covers a
// relay it cannot reach.
func (s HTTPServer) walletWebhookURL(r *http.Request, topUpID string) string {
	base := s.walletWebhookBase(r)
	parsed, err := url.Parse(base)
	if err != nil || parsed.Scheme != "https" || !publicWebhookHost(parsed.Hostname()) {
		return ""
	}
	return base + walletWebhookPrefix + url.PathEscape(topUpID) + "?token=" + s.Wallet.walletWebhookToken(topUpID)
}

func publicWebhookHost(host string) bool {
	host = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
	if host == "" || host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") ||
		strings.HasSuffix(host, ".internal") || !strings.Contains(host, ".") && net.ParseIP(host) == nil {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		return !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() || ip.IsMulticast())
	}
	return true
}

func firstForwardedValue(value string) string {
	first, _, _ := strings.Cut(value, ",")
	return strings.TrimSpace(first)
}

// handleDafaWebhook serves POST /v1/wallet/dafa/webhook/{top-up id}?token=…:
// Dafa saying a payment completed. The body is read only for the log; the
// relay reads the payment back itself and credits what that says. A refused
// read answers 503 so Dafa may try again; the sweep follows up regardless.
func (s HTTPServer) handleDafaWebhook(w http.ResponseWriter, r *http.Request, rawID string) {
	store, hasStore := s.walletStore()
	id, err := url.PathUnescape(strings.Trim(rawID, "/"))
	if !hasStore || !s.Wallet.TopUpsConfigured() || err != nil || id == "" || strings.Contains(id, "/") {
		writeNotFound(w)
		return
	}
	token := strings.TrimSpace(r.URL.Query().Get("token"))
	if !hmac.Equal([]byte(token), []byte(s.Wallet.walletWebhookToken(id))) {
		s.metrics().RecordCredentialRejected()
		s.logger().Warn("dafa webhook with a wrong token ignored", "top_up_id", truncateRunes(id, 64))
		writeNotFound(w)
		return
	}
	body, _ := io.ReadAll(io.LimitReader(r.Body, maxWalletWebhookBytes))
	attrs := []any{"top_up_id", id, "environment", truncateRunes(r.Header.Get("X-Dafa-Environment"), 16)}
	if reported, err := dafa.ParsePayment(body); err == nil {
		attrs = append(attrs, "payment_id", truncateRunes(reported.ID, 64), "reported_paid", reported.IsPaid)
	}
	if environment := strings.ToLower(strings.TrimSpace(r.Header.Get("X-Dafa-Environment"))); environment != "" &&
		(environment == "test") != s.Wallet.TestMode {
		s.logger().Warn("dafa webhook from the other environment; reading the payment back anyway", attrs...)
	} else {
		s.logger().Info("dafa webhook received", attrs...)
	}

	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), s.Wallet.requestTimeout())
	defer cancel()
	topUp, err := store.GetWalletTopUp(ctx, id)
	if errors.Is(err, control.ErrWalletTopUpNotFound) {
		writeNotFound(w)
		return
	}
	if err != nil {
		s.logger().Error("dafa webhook lookup failed", "top_up_id", id, "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "retry later"})
		return
	}
	// Any status but paid is read back: a payment Dafa completes after the
	// relay wrote the top-up off is still the payer's money.
	verified, _, err := s.walletGateway(store).verify(ctx, topUp, "webhook")
	if err != nil {
		s.logger().Warn("dafa webhook: reading the payment back failed", "top_up_id", id, "error", err)
		w.Header().Set("Retry-After", "30")
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "retry later"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": verified.Status})
}

// --- the operator's check ---

// handleWalletAdminCheckTopUp serves POST /v1/wallet/admin/topups/{id}/check:
// read the payment back from Dafa now, credit it if it is paid, and show what
// Dafa says — the first thing support does about "I paid and nothing came".
func (s HTTPServer) handleWalletAdminCheckTopUp(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	if !s.Wallet.TopUpsConfigured() {
		writeWalletError(w, http.StatusServiceUnavailable, walletCodeTopUpsUnconfigured,
			"wallet top-ups are not configured on this relay", nil)
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), s.Wallet.requestTimeout())
	defer cancel()
	topUp, err := store.GetWalletTopUp(ctx, id)
	if errors.Is(err, control.ErrWalletTopUpNotFound) {
		// Support is often read the reference, not the id.
		topUp, err = store.FindWalletTopUpByInvoice(ctx, strings.ToUpper(id))
	}
	if errors.Is(err, control.ErrWalletTopUpNotFound) {
		writeWalletError(w, http.StatusNotFound, walletCodeNotFound, "top-up not found", nil)
		return
	}
	if err != nil {
		s.writeWalletInternalError(w, "wallet top-up read failed", "", err)
		return
	}
	if topUp.ProviderTransactionID == "" {
		writeWalletError(w, http.StatusConflict, walletCodePaymentNotStartedYet,
			"this top-up never got a Dafa payment; there is nothing to check", map[string]any{"top_up": topUp})
		return
	}
	payment, err := s.Wallet.dafaClient().Payment(ctx, topUp.ProviderTransactionID)
	if err != nil {
		writeWalletError(w, http.StatusBadGateway, walletCodeGatewayError, err.Error(), map[string]any{"top_up": topUp})
		return
	}
	settled, applied, err := s.walletGateway(store).settleFromPayment(ctx, topUp, payment, "operator_check")
	if err != nil {
		s.writeWalletInternalError(w, "crediting a checked top-up failed", topUp.InstallationID, err)
		return
	}
	gateway := map[string]any{
		"payment_id": payment.ID,
		"is_paid":    payment.IsPaid,
		"amount":     payment.Amount,
		"gateway":    payment.Gateway,
	}
	if payment.WorkspaceKnown {
		gateway["test"] = payment.TestWorkspace
	}
	if payment.LastError != nil {
		gateway["last_error"] = map[string]any{
			"code":             payment.LastError.Code,
			"fault":            payment.LastError.Fault,
			"provider_message": payment.LastError.ProviderMessage,
			"occurred_at":      payment.LastError.OccurredAt,
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"top_up": settled, "applied": applied, "dafa": gateway})
}

// --- the sweep ---

// WalletTopUpReconciler reads back the payments that can complete without the
// relay hearing of it — a bank card paid after the owner closed the app, a
// code whose answer was lost, a webhook that never arrived — and credits the
// ones Dafa shows paid. Every minute for the first hour, then every fifteen
// for a day; past that a payment is the operator's to reconcile.
type WalletTopUpReconciler struct {
	Store    control.WalletStore
	Config   WalletConfig
	Interval time.Duration
	Clock    control.Clock
	Logger   *slog.Logger
	sweeps   int
}

const (
	walletReconcileFresh     = time.Hour
	walletReconcileHorizon   = 24 * time.Hour
	walletReconcileSlowEvery = 15
	walletReconcileBatch     = 200
)

// Sweep runs one pass: how many payments it read and how many it credited.
func (r *WalletTopUpReconciler) Sweep(ctx context.Context) (int, int, error) {
	clock := r.Clock
	if clock == nil {
		clock = control.RealClock{}
	}
	logger := r.Logger
	if logger == nil {
		logger = slog.Default()
	}
	now := clock.Now().UTC()
	slowTurn := r.sweeps%walletReconcileSlowEvery == 0
	r.sweeps++
	topUps, err := r.Store.ListOpenWalletTopUps(ctx, now.Add(-walletReconcileHorizon), walletReconcileBatch)
	if err != nil {
		return 0, 0, err
	}
	gateway := walletGateway{config: r.Config, store: r.Store, logger: logger}
	checked, credited := 0, 0
	for _, topUp := range topUps {
		if ctx.Err() != nil {
			break
		}
		if !walletTopUpWorthChecking(topUp) {
			continue
		}
		if now.Sub(topUp.CreatedAt) >= walletReconcileFresh && !slowTurn {
			continue
		}
		callCtx, cancel := context.WithTimeout(ctx, r.Config.requestTimeout())
		_, applied, err := gateway.verify(callCtx, topUp, "sweep")
		cancel()
		checked++
		if err != nil {
			logger.Warn("wallet sweep: reading a payment back failed", "top_up_id", topUp.ID, "error", err)
			continue
		}
		if applied {
			credited++
		}
	}
	return checked, credited, nil
}

// Run sweeps on every interval until ctx ends. Several relay nodes may run it
// at once: a settlement credits once however many prove it.
func (r *WalletTopUpReconciler) Run(ctx context.Context) {
	interval := r.Interval
	if interval <= 0 {
		interval = time.Minute
	}
	logger := r.Logger
	if logger == nil {
		logger = slog.Default()
	}
	sweep := func() {
		checked, credited, err := r.Sweep(ctx)
		if err != nil {
			logger.Warn("wallet payment sweep failed", "error", err)
			return
		}
		if credited > 0 {
			logger.Info("wallet payment sweep credited top-ups", "checked", checked, "credited", credited)
		}
	}
	sweep()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			sweep()
		}
	}
}
