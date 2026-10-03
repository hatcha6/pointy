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
	"pointy/relay/internal/dafa"
)

// Starting a top-up, confirming it with the payer's code, and calling it off.

type walletTopUpRequest struct {
	Amount         json.RawMessage `json:"amount"`
	Method         string          `json:"method"`
	IdempotencyKey string          `json:"idempotency_key"`
	RequestedBy    string          `json:"requested_by"`
	// UserIdentifier is the payer's phone or wallet card number, as typed.
	UserIdentifier string `json:"user_identifier"`
	// BirthYear is Sadad's second factor.
	BirthYear string `json:"birth_year"`
}

// walletPayer is the payer's details, checked and normalized for Dafa.
type walletPayer struct {
	identifier string
	birthYear  string
	hint       string
}

// handleWalletTopUpCreate serves POST /v1/wallet/topups. The top-up is stored
// pending BEFORE Dafa is asked to start the payment, so a relay that dies in
// between leaves a row that says so. The answer says what the payer does
// next: type the code their provider texted them, or pay on the page it
// carries. Nothing is credited here.
func (s HTTPServer) handleWalletTopUpCreate(w http.ResponseWriter, r *http.Request) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	if !s.Wallet.TopUpsConfigured() {
		writeWalletError(w, http.StatusServiceUnavailable, walletCodeTopUpsUnconfigured,
			"wallet top-ups are not configured on this relay", nil)
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	var request walletTopUpRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxWalletRequestBytes)).Decode(&request); err != nil {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "invalid request body", nil)
		return
	}
	request.Method = strings.ToLower(strings.TrimSpace(request.Method))
	request.IdempotencyKey = strings.TrimSpace(request.IdempotencyKey)
	request.RequestedBy = strings.TrimSpace(request.RequestedBy)
	method, ok := s.Wallet.enabledMethod(request.Method)
	if !ok {
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodeUnsupportedMethod,
			fmt.Sprintf("unsupported top-up method %q", request.Method), nil)
		return
	}
	if request.IdempotencyKey == "" || utf8.RuneCountInString(request.IdempotencyKey) > 128 {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest,
			"idempotency_key is required (at most 128 characters)", nil)
		return
	}
	if utf8.RuneCountInString(request.RequestedBy) > maxWalletRequestedByRunes {
		request.RequestedBy = string([]rune(request.RequestedBy)[:maxWalletRequestedByRunes])
	}
	amount, rejection := s.validateTopUpAmount(request.Amount)
	if rejection != "" {
		minimum, maximum := s.Wallet.topUpBounds()
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodeInvalidAmount, rejection, map[string]any{
			"min_amount":   minimum.FloatString(walletTopUpDecimals),
			"max_amount":   maximum.FloatString(walletTopUpDecimals),
			"max_decimals": walletTopUpDecimals,
		})
		return
	}
	payer, code, rejection := s.validateWalletPayer(method, request)
	if code != "" {
		writeWalletError(w, http.StatusUnprocessableEntity, code, rejection, nil)
		return
	}
	if s.enforceWalletTopUpRateLimit(w, r, installation.ID) {
		return
	}

	ctx := r.Context()
	topUp, created, err := store.BeginWalletTopUp(ctx, control.WalletTopUp{
		InstallationID: installation.ID,
		Method:         method.Key,
		Amount:         control.FormatWalletAmount(amount),
		IdempotencyKey: request.IdempotencyKey,
		RequestedBy:    request.RequestedBy,
		PayerHint:      payer.hint,
		TestMode:       s.Wallet.TestMode,
	})
	if err != nil {
		s.writeWalletInternalError(w, "wallet top-up claim failed", installation.ID, err)
		return
	}
	if !created {
		s.replayWalletTopUp(w, r, store, topUp)
		return
	}

	// Detached from the caller: if the shop's backend hangs up mid-call, Dafa's
	// answer is still recorded, so the retry replays the truth.
	detached := context.WithoutCancel(ctx)
	callCtx, cancel := context.WithTimeout(detached, s.Wallet.requestTimeout())
	payment, err := s.Wallet.dafaClient().Initiate(callCtx, dafa.InitiateRequest{
		Provider:       method.Provider.ID,
		Amount:         control.FormatWalletAmount(amount),
		UserIdentifier: payer.identifier,
		BirthYear:      payer.birthYear,
		CallbackURL:    s.walletWebhookURL(r, topUp.ID),
	})
	cancel()
	if err == nil {
		err = checkStartedPayment(method, topUp, payment)
	}
	if err != nil {
		failure := s.classifyInitiateError(method, err)
		closed, _, closeErr := store.CloseWalletTopUp(detached, topUp.ID, control.WalletTopUpFailed, failure.code, failure.detail)
		if closeErr != nil {
			s.logger().Error("recording a failed top-up failed", "installation_id", installation.ID,
				"top_up_id", topUp.ID, "error", closeErr)
			closed = topUp
			closed.Status = control.WalletTopUpFailed
			closed.ErrorCode = failure.code
			closed.ErrorDetail = failure.detail
		}
		s.logWalletTopUp(installation.ID, closed, "start_failed", failure.detail)
		writeWalletError(w, failure.status, failure.code, failure.message(), failure.extra(map[string]any{
			"top_up": walletTopUpPayload(closed),
		}))
		return
	}
	checkoutURL := ""
	if method.Provider.HostedPage {
		checkoutURL = payment.PaymentPageURL
	}
	attached, err := store.AttachWalletTopUpPayment(detached, topUp.ID, payment.ID, checkoutURL)
	if err != nil {
		// The payment exists at Dafa. Without its id stored the relay cannot
		// confirm it or read it back, so the payer must not be sent on.
		s.logger().Error("recording a started payment failed", "installation_id", installation.ID,
			"top_up_id", topUp.ID, "payment_id", payment.ID, "error", err)
		closed, _, _ := store.CloseWalletTopUp(detached, topUp.ID, control.WalletTopUpFailed, walletCodeOutcomeUnknown,
			"dafa payment "+payment.ID+" started but could not be recorded")
		writeWalletError(w, http.StatusInternalServerError, walletCodeInternalError, "relay store failed",
			map[string]any{"top_up": walletTopUpPayload(closed)})
		return
	}
	s.logWalletTopUp(installation.ID, attached, "payment_started", "")
	writeJSON(w, http.StatusCreated, walletStartPayload(attached, false))
}

// walletStartPayload is the answer to a started top-up: what the payer does
// next, and for a bank card the page to do it on.
func walletStartPayload(topUp control.WalletTopUp, replayed bool) map[string]any {
	payload := map[string]any{
		"top_up":   walletTopUpPayload(topUp),
		"replayed": replayed,
	}
	if method, ok := lookupWalletMethod(topUp.Method); ok {
		payload["next_action"] = method.kind()
	}
	if topUp.Status == control.WalletTopUpPending && topUp.CheckoutURL != "" {
		payload["checkout_url"] = topUp.CheckoutURL
	}
	return payload
}

// checkStartedPayment refuses an answer the relay could not act on: a bank-card
// payment without a page, or one for another amount than was asked.
func checkStartedPayment(method walletMethod, topUp control.WalletTopUp, payment dafa.Payment) error {
	if method.Provider.HostedPage && !dafa.UsablePaymentPage(payment.PaymentPageURL) {
		return &dafa.APIError{Status: http.StatusOK, Message: "the bank-card payment came back without a usable payment page"}
	}
	if !walletAmountsEqual(payment.Amount, topUp.Amount) {
		return &dafa.APIError{Status: http.StatusOK,
			Message: fmt.Sprintf("dafa started a payment of %s for a %s top-up", truncateRunes(payment.Amount, 32), topUp.Amount)}
	}
	return nil
}

// replayWalletTopUp answers a create whose idempotency key already has a
// top-up: the same next step, or the same failure.
func (s HTTPServer) replayWalletTopUp(
	w http.ResponseWriter,
	r *http.Request,
	store control.WalletStore,
	topUp control.WalletTopUp,
) {
	now := s.clock().Now()
	if topUp.Status == control.WalletTopUpPending && topUp.ProviderTransactionID == "" {
		staleAfter := max(walletMinimumStaleAfter, s.Wallet.requestTimeout()+30*time.Second)
		if now.Sub(topUp.CreatedAt) < staleAfter {
			w.Header().Set("Retry-After", retryAfterSeconds(topUp.CreatedAt.Add(s.Wallet.requestTimeout()), now))
			writeWalletError(w, http.StatusConflict, walletCodeInFlight,
				"this top-up is being set up right now; retry shortly", map[string]any{"top_up": walletTopUpPayload(topUp)})
			return
		}
		// The request that claimed this key never finished. The payer was
		// never told what to do next, so nobody can have paid: failed.
		closed, _, err := store.CloseWalletTopUp(context.WithoutCancel(r.Context()), topUp.ID, control.WalletTopUpFailed,
			walletCodeOutcomeUnknown, "the payment request never finished; start a new top-up")
		if err != nil {
			s.writeWalletInternalError(w, "recording an unfinished top-up failed", topUp.InstallationID, err)
			return
		}
		topUp = closed
	}
	if topUp.Status == control.WalletTopUpFailed {
		code := topUp.ErrorCode
		if code == "" {
			code = walletCodeGatewayError
		}
		writeWalletError(w, http.StatusBadGateway, code, walletFailureMessage(code), map[string]any{
			"detail":   topUp.ErrorDetail,
			"top_up":   walletTopUpPayload(topUp),
			"replayed": true,
		})
		return
	}
	writeJSON(w, http.StatusOK, walletStartPayload(topUp, true))
}

// validateTopUpAmount accepts a JSON string or number of dinars with at most
// two places, inside the configured bounds. It returns the reason for a
// refusal, or "".
func (s HTTPServer) validateTopUpAmount(raw json.RawMessage) (*big.Rat, string) {
	text := strings.TrimSpace(string(raw))
	if unquoted, err := strconv.Unquote(text); err == nil {
		text = strings.TrimSpace(unquoted)
	}
	amount, err := control.ParseWalletAmount(text)
	if err != nil || amount.Sign() <= 0 {
		return nil, "amount must be a positive number of dinars"
	}
	if control.WalletAmountDecimals(text) > walletTopUpDecimals {
		return nil, fmt.Sprintf("amount may have at most %d decimal places", walletTopUpDecimals)
	}
	minimum, maximum := s.Wallet.topUpBounds()
	if amount.Cmp(minimum) < 0 {
		return nil, "amount is below the smallest top-up"
	}
	if amount.Cmp(maximum) > 0 {
		return nil, "amount is above the largest top-up"
	}
	return amount, ""
}

// validateWalletPayer checks what the method asks of the payer and returns it
// the way Dafa takes it, or the code and reason for refusing it.
func (s HTTPServer) validateWalletPayer(method walletMethod, request walletTopUpRequest) (walletPayer, string, string) {
	var payer walletPayer
	switch method.Provider.Payer {
	case dafa.PayerPhone:
		phone, ok := dafa.NormalizePhone(request.UserIdentifier)
		if !ok {
			return walletPayer{}, walletCodeInvalidPhone, "user_identifier must be a Libyan mobile number (09XXXXXXXX)"
		}
		payer.identifier = phone
	case dafa.PayerCard:
		card, ok := dafa.NormalizeCardNumber(request.UserIdentifier)
		if !ok {
			return walletPayer{}, walletCodeInvalidCardNumber, "user_identifier must be the wallet card number (6 to 19 digits)"
		}
		payer.identifier = card
	}
	payer.hint = maskWalletPayer(method.Provider.Payer, payer.identifier)
	if method.Provider.BirthYear {
		year, ok := dafa.Digits(request.BirthYear)
		parsed, err := strconv.Atoi(year)
		thisYear := s.clock().Now().Year()
		if !ok || len(year) != 4 || err != nil || parsed < 1900 || parsed > thisYear {
			return walletPayer{}, walletCodeInvalidBirthYear, "birth_year must be the payer's four-digit year of birth"
		}
		payer.birthYear = year
	}
	return payer, "", ""
}

// walletFailure is how a refused gateway call reaches the shop.
type walletFailure struct {
	code   string
	status int
	// detail is for the operator and the logs; never the payer's number.
	detail string
	// gatewayCode and gatewayMessage are Dafa's own, when it gave them: its
	// message is Arabic and written for the payer.
	gatewayCode    string
	gatewayMessage string
	retryable      bool
}

func (f walletFailure) message() string { return walletFailureMessage(f.code) }

func (f walletFailure) extra(extra map[string]any) map[string]any {
	if extra == nil {
		extra = map[string]any{}
	}
	extra["detail"] = f.detail
	if f.gatewayCode != "" {
		extra["gateway_code"] = f.gatewayCode
	}
	if f.gatewayMessage != "" {
		extra["gateway_message"] = f.gatewayMessage
	}
	extra["retryable"] = f.retryable
	return extra
}

// classifyInitiateError maps a refused start to the wallet's code.
func (s HTTPServer) classifyInitiateError(method walletMethod, err error) walletFailure {
	var apiErr *dafa.APIError
	var transport *dafa.TransportError
	switch {
	case errors.As(err, &apiErr):
		failure := walletFailure{
			code:           walletCodeGatewayRejected,
			status:         http.StatusBadGateway,
			detail:         apiErrorDetail(apiErr),
			gatewayCode:    apiErr.Code,
			gatewayMessage: apiErr.Message,
		}
		if _, ok := apiErr.FieldProblem("user_identifier"); ok {
			failure.code, failure.status = walletCodeInvalidCardNumber, http.StatusUnprocessableEntity
			if method.Provider.Payer == dafa.PayerPhone {
				failure.code = walletCodeInvalidPhone
			}
			return failure
		}
		if _, ok := apiErr.FieldProblem("birthyear"); ok {
			failure.code, failure.status = walletCodeInvalidBirthYear, http.StatusUnprocessableEntity
			return failure
		}
		if _, ok := apiErr.FieldProblem("provider"); ok {
			// "بوابة الدفع غير متاحة": the method is off in this Dafa workspace.
			failure.code, failure.status = walletCodeMethodUnavailable, http.StatusUnprocessableEntity
			return failure
		}
		if _, ok := apiErr.FieldProblem("amount"); ok {
			failure.code, failure.status = walletCodeAmountNotAllowed, http.StatusUnprocessableEntity
			return failure
		}
		switch {
		case apiErr.Status == http.StatusUnauthorized || apiErr.Status == http.StatusForbidden:
			failure.code = walletCodeGatewayUnauthorized
			failure.gatewayMessage = ""
		case apiErr.Status == http.StatusTooManyRequests:
			failure.code, failure.status, failure.retryable = walletCodeGatewayBusy, http.StatusServiceUnavailable, true
		case apiErr.Code != "" && apiErr.Fault == "payer":
			// The payer's provider turned them away at the start: an unknown
			// number, a wrong birth year. Dafa's sentence says which.
			failure.code, failure.status = walletCodePayerRejected, http.StatusUnprocessableEntity
		case apiErr.Status >= 500:
			failure.code, failure.retryable = walletCodeGatewayError, true
			failure.gatewayMessage = ""
		}
		return failure
	case errors.As(err, &transport):
		detail := "dafa could not be reached"
		if transport.Timeout() {
			detail = fmt.Sprintf("dafa did not answer within %s", s.Wallet.requestTimeout())
		}
		return walletFailure{code: walletCodeGatewayError, status: http.StatusBadGateway, detail: detail, retryable: true}
	default:
		return walletFailure{code: walletCodeGatewayError, status: http.StatusBadGateway, detail: "the payment request failed"}
	}
}

func apiErrorDetail(apiErr *dafa.APIError) string {
	parts := []string{strconv.Itoa(apiErr.Status)}
	if apiErr.Code != "" {
		parts = append(parts, apiErr.Code)
	}
	if apiErr.ProviderMessage != "" {
		parts = append(parts, apiErr.ProviderMessage)
	} else if apiErr.Message != "" {
		parts = append(parts, apiErr.Message)
	}
	for field, problems := range apiErr.Fields {
		if len(problems) > 0 {
			parts = append(parts, field+": "+problems[0])
		}
	}
	return truncateRunes(strings.Join(parts, " "), 500)
}

type walletConfirmRequest struct {
	OTP string `json:"otp"`
}

// handleWalletTopUpConfirm serves POST /v1/wallet/topups/{id}/confirm: the code
// the payer's provider texted them. Dafa's answer to the relay is the proof of
// payment for every method but bank cards. A wrong code may be typed again,
// up to a cap; a decline ends the top-up; a lost answer is settled by reading
// the payment back, so a payer who retries can never pay twice.
func (s HTTPServer) handleWalletTopUpConfirm(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	if !s.Wallet.TopUpsConfigured() {
		writeWalletError(w, http.StatusServiceUnavailable, walletCodeTopUpsUnconfigured,
			"wallet top-ups are not configured on this relay", nil)
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	var request walletConfirmRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxWalletRequestBytes)).Decode(&request); err != nil {
		writeWalletError(w, http.StatusBadRequest, walletCodeInvalidRequest, "invalid request body", nil)
		return
	}
	otp, valid := dafa.NormalizeOTP(request.OTP)
	topUp, ok := s.ownWalletTopUp(w, r, store, installation.ID, id)
	if !ok {
		return
	}
	method, known := lookupWalletMethod(topUp.Method)
	if !known || method.kind() != walletKindOTP {
		writeWalletError(w, http.StatusConflict, walletCodeNotOTPMethod,
			"this top-up is paid on the gateway's page, not with a code", map[string]any{"top_up": walletTopUpPayload(topUp)})
		return
	}
	switch {
	case topUp.Status == control.WalletTopUpPaid:
		writeJSON(w, http.StatusOK, map[string]any{"top_up": walletTopUpPayload(topUp)})
		return
	case topUp.Status != control.WalletTopUpPending:
		writeWalletError(w, http.StatusConflict, walletCodeTopUpClosed, "this top-up is closed; start a new one",
			map[string]any{"top_up": walletTopUpPayload(topUp)})
		return
	case topUp.ProviderTransactionID == "":
		writeWalletError(w, http.StatusConflict, walletCodeInFlight, "this top-up is being set up right now; retry shortly",
			map[string]any{"top_up": walletTopUpPayload(topUp)})
		return
	case !valid:
		writeWalletError(w, http.StatusUnprocessableEntity, walletCodeInvalidOTP, "otp must be the 4 to 8 digit code the payer received",
			map[string]any{"top_up": walletTopUpPayload(topUp)})
		return
	}

	ctx := context.WithoutCancel(r.Context())
	counted, recorded, err := store.RecordWalletTopUpOTPAttempt(ctx, topUp.ID, maxWalletOTPAttempts)
	if err != nil {
		s.writeWalletInternalError(w, "counting a wallet code failed", installation.ID, err)
		return
	}
	if !recorded {
		switch counted.Status {
		case control.WalletTopUpPaid:
			writeJSON(w, http.StatusOK, map[string]any{"top_up": walletTopUpPayload(counted)})
		case control.WalletTopUpPending:
			s.closeWalletOTPExhausted(w, ctx, store, counted)
		default:
			writeWalletError(w, http.StatusConflict, walletCodeTopUpClosed, "this top-up is closed; start a new one",
				map[string]any{"top_up": walletTopUpPayload(counted)})
		}
		return
	}
	topUp = counted

	gateway := s.walletGateway(store)
	callCtx, cancel := context.WithTimeout(ctx, s.Wallet.requestTimeout())
	payment, err := s.Wallet.dafaClient().Confirm(callCtx, topUp.ProviderTransactionID, otp)
	cancel()
	if err == nil {
		settled, _, settleErr := gateway.settleFromPayment(ctx, topUp, payment, "confirm")
		if settleErr != nil {
			s.writeWalletInternalError(w, "crediting a confirmed top-up failed", installation.ID, settleErr)
			return
		}
		if settled.Status == control.WalletTopUpPending {
			// Dafa took the code without calling it paid. The app watches the
			// top-up like a bank card until a verdict comes.
			writeJSON(w, http.StatusAccepted, map[string]any{
				"top_up": walletTopUpPayload(settled),
				"code":   walletCodeAwaitingGateway,
			})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"top_up": walletTopUpPayload(settled)})
		return
	}
	s.answerRefusedConfirm(w, ctx, store, gateway, topUp, err)
}

// answerRefusedConfirm turns a confirm Dafa did not answer with a payment into
// the shop's answer and, when it is final, the top-up's verdict.
func (s HTTPServer) answerRefusedConfirm(
	w http.ResponseWriter,
	ctx context.Context,
	store control.WalletStore,
	gateway walletGateway,
	topUp control.WalletTopUp,
	err error,
) {
	var apiErr *dafa.APIError
	if errors.As(err, &apiErr) && apiErr.Status < 500 && apiErr.Status != http.StatusTooManyRequests {
		failure := walletFailure{
			detail:         apiErrorDetail(apiErr),
			gatewayCode:    apiErr.Code,
			gatewayMessage: apiErr.Message,
			retryable:      apiErr.Retryable,
		}
		attemptsLeft := max(0, maxWalletOTPAttempts-topUp.OTPAttempts)
		switch {
		case apiErr.Status == http.StatusUnauthorized || apiErr.Status == http.StatusForbidden:
			failure.code, failure.status, failure.gatewayMessage = walletCodeGatewayUnauthorized, http.StatusBadGateway, ""
			s.logWalletTopUp(topUp.InstallationID, topUp, "confirm_unauthorized", failure.detail)
			writeWalletError(w, failure.status, failure.code, failure.message(), failure.extra(map[string]any{
				"top_up": walletTopUpPayload(topUp),
			}))
			return
		case apiErr.Code == "" && apiErr.Status == http.StatusUnprocessableEntity:
			// Dafa's validation refused the code's shape.
			failure.code, failure.status, failure.retryable = walletCodeInvalidOTP, http.StatusUnprocessableEntity, true
			writeWalletError(w, failure.status, failure.code, failure.message(), failure.extra(map[string]any{
				"top_up":        walletTopUpPayload(topUp),
				"attempts_left": attemptsLeft,
			}))
			return
		case apiErr.Retryable && apiErr.Fault == "payer":
			if attemptsLeft == 0 {
				s.closeWalletOTPExhausted(w, ctx, store, topUp)
				return
			}
			failure.code, failure.status = walletCodeOTPRejected, http.StatusUnprocessableEntity
			s.logWalletTopUp(topUp.InstallationID, topUp, "otp_rejected", failure.detail)
			writeWalletError(w, failure.status, failure.code, failure.message(), failure.extra(map[string]any{
				"top_up":        walletTopUpPayload(topUp),
				"attempts_left": attemptsLeft,
			}))
			return
		case apiErr.Retryable:
			// Not the payer's doing, and worth another try: the provider
			// was busy, say. The code is still good.
			failure.code, failure.status = walletCodeGatewayBusy, http.StatusServiceUnavailable
			writeWalletError(w, failure.status, failure.code, failure.message(), failure.extra(map[string]any{
				"top_up":        walletTopUpPayload(topUp),
				"attempts_left": attemptsLeft,
			}))
			return
		case apiErr.Code == "" && apiErr.Status != http.StatusNotFound:
			// Dafa refused the request itself, not the payment: no verdict,
			// so the top-up stays open and nothing is said about the money.
			failure.code, failure.status, failure.gatewayMessage = walletCodeGatewayRejected, http.StatusBadGateway, ""
			s.logWalletTopUp(topUp.InstallationID, topUp, "confirm_refused", failure.detail)
			writeWalletError(w, failure.status, failure.code, failure.message(), failure.extra(map[string]any{
				"top_up":        walletTopUpPayload(topUp),
				"attempts_left": attemptsLeft,
			}))
			return
		default:
			// A decline (insufficient funds, a blocked wallet) or a payment
			// Dafa no longer has. The top-up ends here; the payer starts a new
			// one. A payment Dafa still proves later credits it anyway.
			failure.code, failure.status = walletCodeDeclined, http.StatusUnprocessableEntity
			if apiErr.Code == "" || (apiErr.Fault != "" && apiErr.Fault != "payer") {
				failure.code, failure.status = walletCodeGatewayRejected, http.StatusBadGateway
			}
			closed, _, closeErr := store.CloseWalletTopUp(ctx, topUp.ID, control.WalletTopUpFailed, failure.code, failure.detail)
			if closeErr != nil {
				s.writeWalletInternalError(w, "recording a declined top-up failed", topUp.InstallationID, closeErr)
				return
			}
			s.logWalletTopUp(topUp.InstallationID, closed, "confirm_declined", failure.detail)
			writeWalletError(w, failure.status, failure.code, failure.message(), failure.extra(map[string]any{
				"top_up": walletTopUpPayload(closed),
			}))
			return
		}
	}

	// No usable answer: Dafa's server failed, it was busy, or the answer was
	// lost. The payment may have gone through, so read it back before saying
	// anything. Sending the same code again is safe either way.
	readCtx, cancel := context.WithTimeout(ctx, s.Wallet.requestTimeout())
	verified, _, verifyErr := gateway.verify(readCtx, topUp, "confirm_recovery")
	cancel()
	if verifyErr == nil && verified.Status != control.WalletTopUpPending {
		writeJSON(w, http.StatusOK, map[string]any{"top_up": walletTopUpPayload(verified)})
		return
	}
	if verifyErr == nil {
		topUp = verified
	}
	code, status := walletCodeConfirmUnknown, http.StatusBadGateway
	if errors.As(err, &apiErr) && apiErr.Status == http.StatusTooManyRequests {
		code, status = walletCodeGatewayBusy, http.StatusServiceUnavailable
	}
	s.logWalletTopUp(topUp.InstallationID, topUp, "confirm_unknown", err.Error())
	writeWalletError(w, status, code, walletFailureMessage(code), map[string]any{
		"top_up":        walletTopUpPayload(topUp),
		"attempts_left": max(0, maxWalletOTPAttempts-topUp.OTPAttempts),
		"retryable":     true,
	})
}

func (s HTTPServer) closeWalletOTPExhausted(
	w http.ResponseWriter,
	ctx context.Context,
	store control.WalletStore,
	topUp control.WalletTopUp,
) {
	closed, _, err := store.CloseWalletTopUp(ctx, topUp.ID, control.WalletTopUpFailed, walletCodeOTPAttemptsExceeded,
		fmt.Sprintf("%d codes refused", topUp.OTPAttempts))
	if err != nil {
		s.writeWalletInternalError(w, "recording an exhausted top-up failed", topUp.InstallationID, err)
		return
	}
	s.logWalletTopUp(topUp.InstallationID, closed, "otp_attempts_exceeded", "")
	writeWalletError(w, http.StatusUnprocessableEntity, walletCodeOTPAttemptsExceeded, walletFailureMessage(walletCodeOTPAttemptsExceeded),
		map[string]any{"top_up": walletTopUpPayload(closed), "attempts_left": 0})
}

// handleWalletTopUpCancel serves POST /v1/wallet/topups/{id}/cancel: the owner
// backing out before sending the code (a wrong number, a change of mind).
// Only the relay can confirm an OTP payment, so a cancelled one can never be
// paid behind its back. A bank-card payment cannot be called off: the payer
// may be paying on Dafa's page this minute.
func (s HTTPServer) handleWalletTopUpCancel(w http.ResponseWriter, r *http.Request, id string) {
	store, ok := s.requireWalletStore(w)
	if !ok {
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	topUp, ok := s.ownWalletTopUp(w, r, store, installation.ID, id)
	if !ok {
		return
	}
	method, known := lookupWalletMethod(topUp.Method)
	if !known || method.kind() != walletKindOTP {
		writeWalletError(w, http.StatusConflict, walletCodeNotOTPMethod,
			"a payment on the gateway's page cannot be called off from here", map[string]any{"top_up": walletTopUpPayload(topUp)})
		return
	}
	closed, applied, err := store.CloseWalletTopUp(context.WithoutCancel(r.Context()), topUp.ID, control.WalletTopUpCanceled,
		walletCodeCanceled, "the owner backed out before confirming")
	if err != nil {
		s.writeWalletInternalError(w, "cancelling a top-up failed", installation.ID, err)
		return
	}
	if applied {
		s.logWalletTopUp(installation.ID, closed, "canceled", "")
	}
	writeJSON(w, http.StatusOK, map[string]any{"top_up": walletTopUpPayload(closed), "applied": applied})
}

// enforceWalletTopUpRateLimit fails OPEN like the SMS burst guard: a limiter
// outage must not stop a shop paying in.
func (s HTTPServer) enforceWalletTopUpRateLimit(w http.ResponseWriter, r *http.Request, installationID string) bool {
	policy := s.Wallet.TopUpRateLimit
	if !policy.Enabled() || s.RateLimiter == nil {
		return false
	}
	decision, err := s.RateLimiter.Allow(r.Context(), "wallet-topup:"+installationID, policy)
	if err != nil {
		s.logger().Error("wallet rate limiter failed; allowing the top-up", "installation_id", installationID, "error", err)
		return false
	}
	if decision.Allowed {
		return false
	}
	w.Header().Set("Retry-After", retryAfterSeconds(decision.ResetAt, s.clock().Now()))
	writeWalletError(w, http.StatusTooManyRequests, walletCodeRateLimited, "too many top-ups started; retry shortly", nil)
	return true
}

func walletAmountsEqual(raw, stored string) bool {
	left, ok := new(big.Rat).SetString(strings.TrimSpace(raw))
	if !ok || strings.TrimSpace(raw) == "" {
		return false
	}
	right, ok := new(big.Rat).SetString(strings.TrimSpace(stored))
	return ok && left.Cmp(right) == 0
}

func walletFailureMessage(code string) string {
	switch code {
	case walletCodeGatewayUnauthorized:
		return "the payment gateway refused the company's credentials; the company must fix its account"
	case walletCodeAmountNotAllowed:
		return "the payment gateway does not accept this amount"
	case walletCodeGatewayBusy:
		return "the payment gateway is busy; retry in a few minutes"
	case walletCodeOutcomeUnknown:
		return "an earlier attempt with this key never finished; start a new top-up"
	case walletCodeGatewayRejected:
		return "the payment gateway rejected the top-up"
	case walletCodeInvalidPhone:
		return "the payment gateway does not accept this phone number"
	case walletCodeInvalidCardNumber:
		return "the payment gateway does not accept this card number"
	case walletCodeInvalidBirthYear:
		return "the payment gateway does not accept this birth year"
	case walletCodeMethodUnavailable:
		return "this payment method is not available right now"
	case walletCodePayerRejected:
		return "the payer's provider refused the payment"
	case walletCodeInvalidOTP:
		return "the code must be the digits the payer received"
	case walletCodeOTPRejected:
		return "the code is wrong; type it again"
	case walletCodeOTPAttemptsExceeded:
		return "too many wrong codes; start a new top-up"
	case walletCodeDeclined:
		return "the payer's bank or wallet declined the payment"
	case walletCodeConfirmUnknown:
		return "the payment gateway did not answer; send the code again"
	default:
		return "the payment gateway could not start the top-up"
	}
}
