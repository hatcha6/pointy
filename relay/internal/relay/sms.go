package relay

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
	"pointy/relay/internal/resala"
)

// Relay-hosted SMS. A shop's backend asks the relay to send one templated
// message; the relay checks the entitlement and the shop's allowance, records
// the attempt in its ledger, and sends through the company's Resala account.
// The ledger is what tells the company which shop sends the most, what it
// costs, what fails and what arrives.

const (
	defaultSMSRequestTimeout   = 20 * time.Second
	defaultSMSMaxVariableRunes = 320
	maxSMSVariables            = 10
	maxSMSIdempotencyKeyRunes  = 128
	maxSMSStatusIDs            = 100
	maxSMSRequestBytes         = 64 << 10
	maxSMSErrorDetailRunes     = 500
	// smsMinimumStaleAfter is how old a pending row must be before a replay
	// declares its outcome unknown. Comfortably longer than a send can take,
	// so a send that is merely slow is never judged while still in flight.
	smsMinimumStaleAfter = 2 * time.Minute
)

// Error codes of the SMS API. Django maps each to its own Arabic message and
// to whether a retry can help.
const (
	smsCodeUnconfigured          = "sms_unconfigured"
	smsCodeUnauthorized          = "unauthorized"
	smsCodeNotEntitled           = "not_entitled"
	smsCodeInvalidRequest        = "invalid_request"
	smsCodeInvalidPhone          = "invalid_phone"
	smsCodeUnknownKind           = "unknown_kind"
	smsCodeTemplateNotConfigured = "template_not_configured"
	smsCodeRateLimited           = "rate_limited"
	smsCodeMonthlyLimit          = "monthly_limit"
	smsCodeInFlight              = "in_flight"
	smsCodeProviderCredit        = "provider_credit"
	smsCodeProviderUnauthorized  = "provider_unauthorized"
	smsCodeProviderRejected      = "provider_rejected"
	smsCodeProviderError         = "provider_error"
	smsCodeOutcomeUnknown        = "outcome_unknown"
	// smsCodeInternalError is the relay's own storage failing. Nothing was
	// sent, so it is safe to retry.
	smsCodeInternalError = "internal_error"
)

// SMSConfig is the relay's Resala account plus the per-shop limits. The token
// and the template ids live only here, like the OpenRouter key.
type SMSConfig struct {
	BaseURL string
	// Token is the Resala API token. Empty disables SMS (503 sms_unconfigured).
	Token string
	// Templates maps a message kind to the id of its APPROVED Resala template.
	Templates map[string]string
	// TestMode forces Resala's test flag on every send: nothing reaches a phone
	// and nothing is charged.
	TestMode bool
	// MonthlyLimit is the per-shop cap for shops whose own sms_monthly_limit is
	// 0. Zero here means unlimited.
	MonthlyLimit int
	// RateLimit is the per-shop burst guard, separate from the monthly cap.
	RateLimit        ratelimit.Policy
	RequestTimeout   time.Duration
	MaxVariableRunes int
	// DeliverySyncInterval is reported by the config endpoint; the poller
	// itself is started by the server command.
	DeliverySyncInterval time.Duration
	HTTPClient           *http.Client
}

func (c SMSConfig) configured() bool {
	return strings.TrimSpace(c.Token) != ""
}

func (c SMSConfig) baseURL() string {
	if trimmed := strings.TrimRight(strings.TrimSpace(c.BaseURL), "/"); trimmed != "" {
		return trimmed
	}
	return resala.DefaultBaseURL
}

func (s HTTPServer) smsRequestTimeout() time.Duration {
	if s.SMS.RequestTimeout > 0 {
		return s.SMS.RequestTimeout
	}
	return defaultSMSRequestTimeout
}

func (s HTTPServer) smsMaxVariableRunes() int {
	if s.SMS.MaxVariableRunes > 0 {
		return s.SMS.MaxVariableRunes
	}
	return defaultSMSMaxVariableRunes
}

func (s HTTPServer) smsStaleAfter() time.Duration {
	return max(smsMinimumStaleAfter, s.smsRequestTimeout()+30*time.Second)
}

// smsMonthlyLimit is the shop's own cap when set, else the relay default.
// Zero means unlimited.
func (s HTTPServer) smsMonthlyLimit(installation control.Installation) int {
	if installation.SMSMonthlyLimit > 0 {
		return installation.SMSMonthlyLimit
	}
	return max(s.SMS.MonthlyLimit, 0)
}

func (s HTTPServer) smsStore() (control.SMSStore, bool) {
	store, ok := s.Store.(control.SMSStore)
	return store, ok
}

func (s HTTPServer) smsClient() *resala.Client {
	return resala.New(resala.Config{
		BaseURL:    s.SMS.baseURL(),
		Token:      s.SMS.Token,
		HTTPClient: s.SMS.HTTPClient,
		Timeout:    s.smsRequestTimeout(),
	})
}

// smsConfiguredKinds are the kinds a shop can actually send right now.
func (s HTTPServer) smsConfiguredKinds() []string {
	kinds := []string{}
	for kind, templateID := range s.SMS.Templates {
		if strings.TrimSpace(templateID) != "" {
			kinds = append(kinds, kind)
		}
	}
	sort.Strings(kinds)
	return kinds
}

// smsTemplateFor resolves a kind to its approved template, or names why not.
func (s HTTPServer) smsTemplateFor(kind string) (string, string) {
	if templateID := strings.TrimSpace(s.SMS.Templates[kind]); templateID != "" {
		return templateID, ""
	}
	if _, known := lookupSMSKind(kind); known {
		return "", smsCodeTemplateNotConfigured
	}
	return "", smsCodeUnknownKind
}

type smsSendRequest struct {
	Kind           string   `json:"kind"`
	To             string   `json:"to"`
	Variables      []string `json:"variables"`
	IdempotencyKey string   `json:"idempotency_key"`
	ConsentClass   string   `json:"consent_class"`
	Test           bool     `json:"test"`

	recipient string
}

type smsRejection struct {
	status  int
	code    string
	message string
}

// smsSendTrace is what the one log line per send reports. It never holds the
// phone number or the message text.
type smsSendTrace struct {
	outcome        string
	installationID string
	kind           string
	ledgerID       string
	testMode       bool
	cost           string
	detail         string
	// providerRequestID is Resala's id for a failed call — what their support
	// asks for.
	providerRequestID string
}

// handleSMSSend serves POST /v1/sms/send. The checks run in the contract's
// order — configured, identity, entitlement, body, burst limit, idempotency,
// monthly cap, template — and only then is a ledger row claimed and Resala
// called. A retry of a key that was already claimed never reaches Resala
// again: it replays what the ledger recorded.
func (s HTTPServer) handleSMSSend(w http.ResponseWriter, r *http.Request) {
	startedAt := time.Now()
	trace := &smsSendTrace{outcome: "unknown"}
	defer func() {
		s.metrics().RecordSMSSend(trace.outcome)
		s.logSMSSend(trace, time.Since(startedAt))
	}()

	store, hasStore := s.smsStore()
	if !s.SMS.configured() || !hasStore {
		trace.outcome = smsCodeUnconfigured
		writeSMSError(w, http.StatusServiceUnavailable, smsCodeUnconfigured, "relay SMS is not configured", nil)
		return
	}
	installation, authOutcome, ok := s.authenticateInstallation(w, r)
	if !ok {
		trace.outcome = authOutcome
		return
	}
	trace.installationID = installation.ID
	now := s.clock().Now()
	if !installation.SMSActive(now) {
		trace.outcome = smsCodeNotEntitled
		s.metrics().RecordSubscriptionRejected()
		writeSMSError(w, http.StatusPaymentRequired, smsCodeNotEntitled, "relay SMS is not entitled for this installation", nil)
		return
	}
	request, rejection := s.decodeSMSSendRequest(w, r)
	trace.kind = truncateRunes(request.Kind, 64)
	if rejection != nil {
		trace.outcome = rejection.code
		writeSMSError(w, rejection.status, rejection.code, rejection.message, nil)
		return
	}
	testMode := request.Test || s.SMS.TestMode
	trace.testMode = testMode
	if s.enforceSMSRateLimit(w, r, installation.ID) {
		trace.outcome = smsCodeRateLimited
		return
	}

	ctx := r.Context()
	periodStart, resetsAt := control.SMSMonthlyPeriod(now)
	limit := s.smsMonthlyLimit(installation)

	existing, found, err := store.FindSMSByKey(ctx, installation.ID, request.IdempotencyKey)
	if err != nil {
		s.writeSMSInternalError(w, trace, "sms idempotency lookup failed", err)
		return
	}
	if found {
		s.replaySMS(w, r, store, trace, existing, request, installation, now)
		return
	}

	used, err := store.CountBillableSMSSince(ctx, installation.ID, periodStart)
	if err != nil {
		s.writeSMSInternalError(w, trace, "sms usage count failed", err)
		return
	}
	if !testMode && limit > 0 && used >= limit {
		trace.outcome = smsCodeMonthlyLimit
		writeSMSMonthlyLimit(w, limit, used, resetsAt)
		return
	}
	templateID, templateProblem := s.smsTemplateFor(request.Kind)
	if templateProblem != "" {
		trace.outcome = templateProblem
		message := fmt.Sprintf("no approved template is configured for kind %q", request.Kind)
		if templateProblem == smsCodeUnknownKind {
			message = fmt.Sprintf("unknown message kind %q", request.Kind)
		}
		writeSMSError(w, http.StatusUnprocessableEntity, templateProblem, message, nil)
		return
	}

	claimLimit := control.SMSClaimLimit{Since: periodStart}
	if !testMode {
		claimLimit.Limit = limit
	}
	claim, created, err := store.BeginSMS(ctx, control.SMSMessage{
		InstallationID: installation.ID,
		IdempotencyKey: request.IdempotencyKey,
		Kind:           request.Kind,
		ConsentClass:   request.ConsentClass,
		Recipient:      request.recipient,
		TemplateID:     templateID,
		TestMode:       testMode,
		CreatedAt:      now,
	}, claimLimit)
	var limitErr *control.SMSLimitError
	switch {
	case errors.As(err, &limitErr):
		// Another send took the last message of the month between the count
		// above and this claim.
		trace.outcome = smsCodeMonthlyLimit
		writeSMSMonthlyLimit(w, limitErr.Limit, limitErr.Used, resetsAt)
		return
	case err != nil:
		s.writeSMSInternalError(w, trace, "sms ledger claim failed", err)
		return
	case !created:
		// The same key was claimed between the lookup and here.
		s.replaySMS(w, r, store, trace, claim, request, installation, now)
		return
	}
	trace.ledgerID = claim.ID

	// Detached from the caller: if the shop's backend hangs up mid-send, the
	// provider call still finishes and the ledger records what really happened,
	// so the retry replays the truth instead of meeting a row stuck at pending.
	detached := context.WithoutCancel(ctx)
	sendCtx, cancel := context.WithTimeout(detached, s.smsRequestTimeout())
	result, sendErr := s.smsClient().SendTemplate(
		sendCtx,
		templateID,
		[]resala.Record{{Phone: request.recipient, Values: request.Variables}},
		testMode,
	)
	cancel()
	outcome, content := s.smsOutcomeFromSend(result, sendErr, testMode, request.Variables)
	trace.detail = outcome.ErrorDetail
	trace.providerRequestID = resalaRequestID(sendErr)

	finished, applied, err := store.FinishSMS(detached, claim.ID, outcome)
	if err != nil {
		// Resala has answered; only our record of it failed. Answer with what
		// really happened, so the shop neither resends a message that went out
		// nor believes a failed one did. The row stays pending, which keeps it
		// counted against the allowance — the safe side when we cannot record.
		s.logger().Error(
			"recording an sms outcome failed",
			"installation_id", installation.ID,
			"ledger_id", claim.ID,
			"status", outcome.Status,
			"error", err,
		)
		finished = smsMessageWithOutcome(claim, outcome)
		applied = true
	}
	if !applied {
		// Someone else finished this row first; the ledger's verdict stands.
		content = smsReplayContent(finished, request.Variables)
	}
	trace.testMode = finished.TestMode
	trace.cost = finished.Cost

	if finished.Status == control.SMSStatusFailed {
		trace.outcome = finished.ErrorCode
		writeSMSStoredFailure(w, finished, !applied)
		return
	}
	trace.outcome = "sent"
	if smsCountsAgainstAllowance(finished) {
		used++
	}
	status := http.StatusCreated
	if !applied {
		trace.outcome = "replayed"
		status = http.StatusOK
	}
	writeJSON(w, status, smsSuccessBody(finished, content, smsUsageBlock(used, limit, periodStart, resetsAt), !applied))
}

// replaySMS answers a request whose idempotency key already has a ledger row.
func (s HTTPServer) replaySMS(
	w http.ResponseWriter,
	r *http.Request,
	store control.SMSStore,
	trace *smsSendTrace,
	message control.SMSMessage,
	request smsSendRequest,
	installation control.Installation,
	now time.Time,
) {
	trace.ledgerID = message.ID
	trace.testMode = message.TestMode
	if message.Kind != request.Kind || message.Recipient != request.recipient {
		// A reused key is a caller bug; the first send is what the key means.
		s.logger().Warn(
			"sms idempotency key reused for a different message; replaying the first",
			"installation_id", installation.ID,
			"ledger_id", message.ID,
			"stored_kind", message.Kind,
			"requested_kind", request.Kind,
		)
	}
	if message.Status == control.SMSStatusPending {
		if now.Sub(message.CreatedAt) < s.smsStaleAfter() {
			trace.outcome = smsCodeInFlight
			w.Header().Set("Retry-After", retryAfterSeconds(message.CreatedAt.Add(s.smsRequestTimeout()), now))
			writeSMSError(w, http.StatusConflict, smsCodeInFlight,
				"this message is being sent right now; retry shortly", map[string]any{"id": message.ID})
			return
		}
		// The send that claimed this key never finished — the relay making it
		// died mid-call. Whether the SMS went out is unknowable, and sending
		// again could text the customer twice, so the verdict is recorded once
		// and replayed from then on.
		finished, applied, err := store.FinishSMS(context.WithoutCancel(r.Context()), message.ID, control.SMSOutcome{
			Status:      control.SMSStatusFailed,
			ErrorCode:   smsCodeOutcomeUnknown,
			ErrorDetail: "the earlier send with this idempotency key never finished; it may or may not have been delivered",
			Cost:        message.Cost,
			TestMode:    message.TestMode,
		})
		if err != nil {
			s.writeSMSInternalError(w, trace, "recording an unknown sms outcome failed", err)
			return
		}
		message = finished
		if applied {
			trace.outcome = smsCodeOutcomeUnknown
			trace.detail = message.ErrorDetail
			writeSMSStoredFailure(w, message, true)
			return
		}
	}
	trace.outcome = "replayed"
	trace.cost = message.Cost
	if message.Status == control.SMSStatusFailed {
		trace.detail = message.ErrorCode
		writeSMSStoredFailure(w, message, true)
		return
	}
	periodStart, resetsAt := control.SMSMonthlyPeriod(now)
	limit := s.smsMonthlyLimit(installation)
	used, err := store.CountBillableSMSSince(r.Context(), installation.ID, periodStart)
	if err != nil {
		s.writeSMSInternalError(w, trace, "sms usage count failed", err)
		return
	}
	writeJSON(w, http.StatusOK, smsSuccessBody(
		message,
		smsReplayContent(message, request.Variables),
		smsUsageBlock(used, limit, periodStart, resetsAt),
		true,
	))
}

// smsOutcomeFromSend turns Resala's answer into the ledger's outcome and the
// rendered content returned to the shop.
func (s HTTPServer) smsOutcomeFromSend(
	result resala.SendResult,
	sendErr error,
	testMode bool,
	variables []string,
) (control.SMSOutcome, string) {
	if sendErr != nil {
		code, detail := s.classifyResalaError(sendErr)
		return control.SMSOutcome{
			Status:      control.SMSStatusFailed,
			ErrorCode:   code,
			ErrorDetail: truncateRunes(detail, maxSMSErrorDetailRunes),
			TestMode:    testMode,
		}, ""
	}
	// Resala has the last word on whether a phone was reached: a send it
	// reports as not production was a test, whatever was asked for, and must
	// not count against the shop's allowance.
	effectiveTest := testMode || !result.IsProd
	cost := result.TotalCostText
	if strings.TrimSpace(cost) == "" {
		cost = "0"
	}
	if result.Failed > 0 {
		return control.SMSOutcome{
			Status:    control.SMSStatusFailed,
			ErrorCode: smsCodeProviderRejected,
			ErrorDetail: fmt.Sprintf(
				"resala refused the recipient (%d of %d failed)",
				result.Failed, result.Failed+result.Succeeded,
			),
			Cost:         cost,
			TemplateBody: result.Template.Body,
			TestMode:     effectiveTest,
		}, ""
	}
	sentAt := s.clock().Now().UTC()
	content := ""
	contentHash := ""
	if result.Template.Body != "" {
		content = resala.RenderBody(result.Template.Body, variables)
		contentHash = smsContentSHA256(content)
	}
	return control.SMSOutcome{
		Status:        control.SMSStatusSent,
		Cost:          cost,
		ContentSHA256: contentHash,
		TemplateBody:  result.Template.Body,
		TestMode:      effectiveTest,
		SentAt:        &sentAt,
	}, content
}

// classifyResalaError maps a failed send to the contract's error code and the
// detail the shop is shown.
func (s HTTPServer) classifyResalaError(err error) (string, string) {
	var provider *resala.ProviderError
	var validation *resala.ValidationError
	var transport *resala.TransportError
	switch {
	case errors.Is(err, resala.ErrInsufficientCredit):
		return smsCodeProviderCredit, providerMessage(err)
	case errors.Is(err, resala.ErrUnauthorized), errors.Is(err, resala.ErrForbidden):
		return smsCodeProviderUnauthorized, providerMessage(err)
	case errors.As(err, &validation):
		return smsCodeProviderRejected, validation.Detail()
	case errors.As(err, &provider):
		if provider.Status >= 500 {
			return smsCodeProviderError, fmt.Sprintf(
				"resala answered %d; the message may or may not have been sent", provider.Status,
			)
		}
		return smsCodeProviderRejected, provider.Message
	case errors.As(err, &transport):
		if transport.Timeout() {
			return smsCodeProviderError, fmt.Sprintf(
				"resala did not answer within %s; the message may or may not have been sent",
				s.smsRequestTimeout(),
			)
		}
		return smsCodeProviderError, "resala could not be reached; the message may or may not have been sent"
	default:
		return smsCodeProviderError, "the send failed before resala answered"
	}
}

func resalaRequestID(err error) string {
	var provider *resala.ProviderError
	if errors.As(err, &provider) {
		return provider.RequestID
	}
	var validation *resala.ValidationError
	if errors.As(err, &validation) {
		return validation.RequestID
	}
	return ""
}

func providerMessage(err error) string {
	var provider *resala.ProviderError
	if errors.As(err, &provider) {
		return provider.Message
	}
	return err.Error()
}

// handleSMSUsageSelf serves GET /v1/sms/usage/self. Identity only, no
// entitlement gate: an unentitled shop asks precisely so the app can say why
// it cannot send.
func (s HTTPServer) handleSMSUsageSelf(w http.ResponseWriter, r *http.Request) {
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	now := s.clock().Now()
	periodStart, resetsAt := control.SMSMonthlyPeriod(now)
	limit := s.smsMonthlyLimit(installation)
	used := 0
	if store, ok := s.smsStore(); ok {
		count, err := store.CountBillableSMSSince(r.Context(), installation.ID, periodStart)
		if err != nil {
			s.logger().Error("sms usage count failed", "installation_id", installation.ID, "error", err)
			writeSMSError(w, http.StatusInternalServerError, smsCodeInternalError, "relay store failed", nil)
			return
		}
		used = count
	}
	body := smsUsageBlock(used, limit, periodStart, resetsAt)
	body["entitled"] = installation.SMSActive(now)
	body["sms_enabled"] = installation.SMSEnabled
	body["test_mode"] = s.SMS.TestMode
	body["configured"] = s.SMS.configured()
	body["kinds"] = s.smsConfiguredKinds()
	writeJSON(w, http.StatusOK, body)
}

// handleSMSStatus serves GET /v1/sms/status?ids=a,b. A shop only ever sees
// its own rows; someone else's id is simply absent from the answer.
func (s HTTPServer) handleSMSStatus(w http.ResponseWriter, r *http.Request) {
	store, ok := s.smsStore()
	if !ok {
		writeSMSError(w, http.StatusServiceUnavailable, smsCodeUnconfigured, "relay SMS ledger unavailable", nil)
		return
	}
	installation, _, ok := s.authenticateInstallation(w, r)
	if !ok {
		return
	}
	ids := splitSMSIDs(r.URL.Query()["ids"])
	if len(ids) == 0 {
		writeSMSError(w, http.StatusBadRequest, smsCodeInvalidRequest, "ids is required", nil)
		return
	}
	if len(ids) > maxSMSStatusIDs {
		writeSMSError(w, http.StatusBadRequest, smsCodeInvalidRequest,
			fmt.Sprintf("at most %d ids per request", maxSMSStatusIDs), nil)
		return
	}
	messages, err := store.GetSMSByIDs(r.Context(), installation.ID, ids)
	if err != nil {
		s.logger().Error("sms status lookup failed", "installation_id", installation.ID, "error", err)
		writeSMSError(w, http.StatusInternalServerError, smsCodeInternalError, "relay store failed", nil)
		return
	}
	statuses := make([]map[string]any, 0, len(messages))
	for _, message := range messages {
		statuses = append(statuses, map[string]any{
			"id":           message.ID,
			"status":       message.Status,
			"updated_at":   message.UpdatedAt,
			"delivered_at": message.DeliveredAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": statuses})
}

// handleSMSAdminUsage serves GET /v1/sms/usage (admin): per-shop counts and
// cost over a period, busiest shop first. The default period is the current
// Libyan calendar month.
func (s HTTPServer) handleSMSAdminUsage(w http.ResponseWriter, r *http.Request) {
	store, ok := s.smsStore()
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "sms ledger unavailable"})
		return
	}
	from, to := control.SMSMonthlyPeriod(s.clock().Now())
	if raw := strings.TrimSpace(r.URL.Query().Get("from")); raw != "" {
		parsed, err := parseSMSReportTime(raw)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "from must be RFC3339 or YYYY-MM-DD"})
			return
		}
		from = parsed
	}
	if raw := strings.TrimSpace(r.URL.Query().Get("to")); raw != "" {
		parsed, err := parseSMSReportTime(raw)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "to must be RFC3339 or YYYY-MM-DD"})
			return
		}
		to = parsed
	}
	if !from.Before(to) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "from must be before to"})
		return
	}
	usage, err := store.SMSUsage(r.Context(), from, to)
	if err != nil {
		s.logger().Error("sms usage report failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "sms ledger failed"})
		return
	}
	totals := map[string]any{"installations": len(usage)}
	var messages, sent, failed, delivered, undelivered, test int
	costs := make([]string, 0, len(usage))
	for _, row := range usage {
		messages += row.Messages
		sent += row.Sent
		failed += row.Failed
		delivered += row.Delivered
		undelivered += row.Undelivered
		test += row.Test
		costs = append(costs, row.Cost)
	}
	totals["messages"] = messages
	totals["sent"] = sent
	totals["failed"] = failed
	totals["delivered"] = delivered
	totals["undelivered"] = undelivered
	totals["test"] = test
	totals["cost"] = control.SumSMSCosts(costs)
	writeJSON(w, http.StatusOK, map[string]any{
		"from":          from,
		"to":            to,
		"totals":        totals,
		"installations": usage,
	})
}

// handleSMSAdminMessages serves GET /v1/sms/messages (admin): recent ledger
// rows, newest first.
func (s HTTPServer) handleSMSAdminMessages(w http.ResponseWriter, r *http.Request) {
	store, ok := s.smsStore()
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "sms ledger unavailable"})
		return
	}
	query := r.URL.Query()
	filter := control.SMSMessageFilter{
		InstallationID: strings.TrimSpace(query.Get("installation_id")),
		Status:         strings.ToLower(strings.TrimSpace(query.Get("status"))),
		Limit:          50,
	}
	if filter.Status != "" && !control.ValidSMSStatus(filter.Status) {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "status must be pending, sent, failed, delivered or undelivered",
		})
		return
	}
	if raw := strings.TrimSpace(query.Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed <= 0 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid limit"})
			return
		}
		filter.Limit = parsed
	}
	messages, err := store.ListSMSMessages(r.Context(), filter)
	if err != nil {
		s.logger().Error("sms ledger listing failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "sms ledger failed"})
		return
	}
	if messages == nil {
		messages = []control.SMSMessage{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": messages, "count": len(messages)})
}

// handleSMSAdminConfig serves GET /v1/sms/config (admin): what the relay is
// configured to do, for the operator. It never includes the token.
func (s HTTPServer) handleSMSAdminConfig(w http.ResponseWriter, _ *http.Request) {
	templates := map[string]string{}
	for kind, templateID := range s.SMS.Templates {
		if templateID = strings.TrimSpace(templateID); templateID != "" {
			templates[kind] = templateID
		}
	}
	catalog := make([]map[string]any, 0, len(smsKindCatalog))
	for _, kind := range smsKindCatalog {
		_, configured := templates[kind.Kind]
		catalog = append(catalog, map[string]any{
			"kind":          kind.Kind,
			"consent_class": kind.ConsentClass,
			"variables":     kind.Variables,
			"configured":    configured,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"configured":             s.SMS.configured(),
		"test_mode":              s.SMS.TestMode,
		"base_url":               s.SMS.baseURL(),
		"templates":              templates,
		"monthly_limit_default":  max(s.SMS.MonthlyLimit, 0),
		"rate_limit":             s.SMS.RateLimit.String(),
		"request_timeout":        s.smsRequestTimeout().String(),
		"max_variable_runes":     s.smsMaxVariableRunes(),
		"delivery_sync_interval": s.SMS.DeliverySyncInterval.String(),
		"catalog":                catalog,
	})
}

// authenticateInstallation validates the installation's access token for identity only;
// callers apply the entitlement they need. A store outage is reported as such
// rather than as a rejected token, so a shop is never told its credentials are
// wrong because the relay's database blinked.
func (s HTTPServer) authenticateInstallation(w http.ResponseWriter, r *http.Request) (control.Installation, string, bool) {
	rawToken := strings.TrimSpace(r.Header.Get(AccessTokenHeader))
	if rawToken == "" {
		s.metrics().RecordCredentialRejected()
		writeSMSError(w, http.StatusUnauthorized, smsCodeUnauthorized, "relay token required", nil)
		return control.Installation{}, smsCodeUnauthorized, false
	}
	installation, err := s.Store.ValidateAccessTokenIdentity(r.Context(), rawToken)
	if err == nil {
		return installation, "", true
	}
	if errors.Is(err, control.ErrInvalidToken) ||
		errors.Is(err, control.ErrWrongPurpose) ||
		errors.Is(err, control.ErrNotFound) {
		s.metrics().RecordCredentialRejected()
		writeSMSError(w, http.StatusUnauthorized, smsCodeUnauthorized, "relay token rejected", nil)
		return control.Installation{}, smsCodeUnauthorized, false
	}
	s.logger().Error("installation token validation failed", "error", err)
	writeSMSError(w, http.StatusInternalServerError, smsCodeInternalError, "relay store failed", nil)
	return control.Installation{}, smsCodeInternalError, false
}

func (s HTTPServer) decodeSMSSendRequest(w http.ResponseWriter, r *http.Request) (smsSendRequest, *smsRejection) {
	invalid := func(message string) *smsRejection {
		return &smsRejection{status: http.StatusBadRequest, code: smsCodeInvalidRequest, message: message}
	}
	// A rejected request still returns what was decoded, so the log line can
	// say which kind was refused.
	var request smsSendRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxSMSRequestBytes)).Decode(&request); err != nil {
		return smsSendRequest{}, invalid("invalid request body")
	}
	request.Kind = strings.ToLower(strings.TrimSpace(request.Kind))
	request.IdempotencyKey = strings.TrimSpace(request.IdempotencyKey)
	request.ConsentClass = strings.ToLower(strings.TrimSpace(request.ConsentClass))
	if request.Kind == "" {
		return request, invalid("kind is required")
	}
	if request.IdempotencyKey == "" {
		return request, invalid("idempotency_key is required")
	}
	if utf8.RuneCountInString(request.IdempotencyKey) > maxSMSIdempotencyKeyRunes {
		return request, invalid(fmt.Sprintf(
			"idempotency_key must be at most %d characters", maxSMSIdempotencyKeyRunes,
		))
	}
	if len(request.Variables) < 1 || len(request.Variables) > maxSMSVariables {
		return request, invalid(fmt.Sprintf("variables must hold 1 to %d values", maxSMSVariables))
	}
	maxRunes := s.smsMaxVariableRunes()
	for i, value := range request.Variables {
		if utf8.RuneCountInString(value) > maxRunes {
			return request, invalid(fmt.Sprintf(
				"variable $%d is longer than %d characters", i+1, maxRunes,
			))
		}
	}
	known, isKnown := lookupSMSKind(request.Kind)
	switch request.ConsentClass {
	case "":
		request.ConsentClass = smsConsentTransactional
		if isKnown {
			request.ConsentClass = known.ConsentClass
		}
	case smsConsentTransactional, smsConsentMarketing:
	default:
		return request, invalid("consent_class must be transactional or marketing")
	}
	if isKnown {
		// Consent is a property of the kind, not a choice per message: a
		// promotion sent as "transactional" would skip the marketing opt-out.
		if request.ConsentClass != known.ConsentClass {
			return request, invalid(fmt.Sprintf(
				"kind %q is sent as %s, not %s", request.Kind, known.ConsentClass, request.ConsentClass,
			))
		}
		// A short list would go out with a literal "$3" in a customer's SMS.
		if len(request.Variables) != known.Variables {
			return request, invalid(fmt.Sprintf(
				"kind %q takes %d variables, got %d", request.Kind, known.Variables, len(request.Variables),
			))
		}
	}
	recipient, ok := resala.NormalizeLibyanMobile(request.To)
	if !ok {
		return request, &smsRejection{
			status:  http.StatusUnprocessableEntity,
			code:    smsCodeInvalidPhone,
			message: "not a Libyan mobile number",
		}
	}
	request.recipient = recipient
	return request, nil
}

// enforceSMSRateLimit is the per-shop burst guard. It fails OPEN on a limiter
// error: the monthly cap is enforced by the ledger, not by Redis, so a limiter
// outage loosens only the burst guard and never lets a shop past its allowance.
func (s HTTPServer) enforceSMSRateLimit(w http.ResponseWriter, r *http.Request, installationID string) bool {
	policy := s.SMS.RateLimit
	if !policy.Enabled() || s.RateLimiter == nil {
		return false
	}
	decision, err := s.RateLimiter.Allow(r.Context(), smsRateLimitKey(installationID), policy)
	if err != nil {
		s.metrics().RecordRateLimitFailed()
		s.logger().Error("sms rate limiter failed; allowing the send", "installation_id", installationID, "error", err)
		return false
	}
	if decision.Allowed {
		return false
	}
	s.metrics().RecordRateLimitRejected()
	w.Header().Set("Retry-After", retryAfterSeconds(decision.ResetAt, s.clock().Now()))
	writeSMSError(w, http.StatusTooManyRequests, smsCodeRateLimited, "relay SMS rate limit exceeded", nil)
	return true
}

func smsRateLimitKey(installationID string) string {
	return "sms-send:" + strings.TrimSpace(installationID)
}

func (s HTTPServer) writeSMSInternalError(w http.ResponseWriter, trace *smsSendTrace, message string, err error) {
	trace.outcome = smsCodeInternalError
	s.logger().Error(message, "installation_id", trace.installationID, "ledger_id", trace.ledgerID, "error", err)
	writeSMSError(w, http.StatusInternalServerError, smsCodeInternalError, "relay store failed", nil)
}

// logSMSSend writes the one line per send. It carries who, what kind and what
// happened — never the phone number or the text.
func (s HTTPServer) logSMSSend(trace *smsSendTrace, elapsed time.Duration) {
	level := slog.LevelInfo
	message := "relay sms send"
	switch trace.outcome {
	case smsCodeProviderCredit:
		level = slog.LevelError
		message = "resala wallet is empty: top up the company account; every shop's SMS fails until then"
	case smsCodeProviderUnauthorized:
		level = slog.LevelError
		message = "resala rejected the relay's API token; check POINTY_RELAY_RESALA_API_TOKEN"
	case smsCodeInternalError:
		level = slog.LevelError
	case smsCodeProviderRejected, smsCodeProviderError, smsCodeOutcomeUnknown:
		level = slog.LevelWarn
	}
	attrs := []any{
		"outcome", trace.outcome,
		"installation_id", trace.installationID,
		"kind", trace.kind,
		"ledger_id", trace.ledgerID,
		"test_mode", trace.testMode,
		"duration_ms", elapsed.Milliseconds(),
	}
	if trace.cost != "" {
		attrs = append(attrs, "cost", trace.cost)
	}
	if trace.detail != "" {
		attrs = append(attrs, "detail", scrubPhoneNumbers(trace.detail))
	}
	if trace.providerRequestID != "" {
		attrs = append(attrs, "resala_request_id", trace.providerRequestID)
	}
	s.logger().Log(context.Background(), level, message, attrs...)
}

var digitRun = regexp.MustCompile(`\+?\d[\d \-]*\d`)

// scrubPhoneNumbers masks anything that looks like a phone number (nine or
// more digits, however spaced) in provider text before it reaches a log line.
// Shorter runs — amounts, dates, status codes — are left readable.
func scrubPhoneNumbers(text string) string {
	return digitRun.ReplaceAllStringFunc(text, func(run string) string {
		digits := 0
		for _, r := range run {
			if r >= '0' && r <= '9' {
				digits++
			}
		}
		if digits >= 9 {
			return "[number]"
		}
		return run
	})
}

func writeSMSError(w http.ResponseWriter, status int, code, message string, extra map[string]any) {
	body := map[string]any{"error": message, "code": code}
	for key, value := range extra {
		body[key] = value
	}
	writeJSON(w, status, body)
}

func writeSMSMonthlyLimit(w http.ResponseWriter, limit, used int, resetsAt time.Time) {
	writeSMSError(w, http.StatusTooManyRequests, smsCodeMonthlyLimit, "monthly SMS limit reached", map[string]any{
		"limit":     limit,
		"used":      used,
		"resets_at": resetsAt,
	})
}

// writeSMSStoredFailure answers with a failure the ledger recorded. A replay
// gets exactly the response the first attempt got.
func writeSMSStoredFailure(w http.ResponseWriter, message control.SMSMessage, replayed bool) {
	code := message.ErrorCode
	if code == "" {
		code = smsCodeProviderError
	}
	writeSMSError(w, http.StatusBadGateway, code, smsFailureMessage(code), map[string]any{
		"detail":   message.ErrorDetail,
		"id":       message.ID,
		"replayed": replayed,
	})
}

func smsFailureMessage(code string) string {
	switch code {
	case smsCodeProviderCredit:
		return "the SMS provider wallet is empty; the company must top it up"
	case smsCodeProviderUnauthorized:
		return "the SMS provider rejected the relay's credentials"
	case smsCodeProviderRejected:
		return "the SMS provider rejected the message"
	case smsCodeOutcomeUnknown:
		return "an earlier send with this idempotency key never finished; its outcome is unknown"
	default:
		return "the SMS provider failed; the outcome is unknown"
	}
}

func smsSuccessBody(message control.SMSMessage, content string, usage map[string]any, replayed bool) map[string]any {
	return map[string]any{
		"id":        message.ID,
		"status":    message.Status,
		"test_mode": message.TestMode,
		"content":   content,
		"cost":      message.Cost,
		"replayed":  replayed,
		"usage":     usage,
	}
}

// smsUsageBlock is the allowance as the app shows it. A limit of 0 means
// unlimited, reported as remaining -1.
func smsUsageBlock(used, limit int, periodStart, resetsAt time.Time) map[string]any {
	remaining := -1
	if limit > 0 {
		remaining = max(limit-used, 0)
	}
	return map[string]any{
		"used":         used,
		"limit":        limit,
		"remaining":    remaining,
		"period_start": periodStart,
		"resets_at":    resetsAt,
	}
}

func smsCountsAgainstAllowance(message control.SMSMessage) bool {
	if message.TestMode {
		return false
	}
	switch message.Status {
	case control.SMSStatusPending, control.SMSStatusSent, control.SMSStatusDelivered, control.SMSStatusUndelivered:
		return true
	}
	return false
}

// smsReplayContent re-renders the stored template with the replay's variables
// and returns it only when it hashes to what was actually sent. The ledger keeps
// no content, so this is how a replay hands back the exact text — and a replay
// that changed its variables gets no text rather than a wrong one.
func smsReplayContent(message control.SMSMessage, variables []string) string {
	if message.TemplateBody == "" || message.ContentSHA256 == "" {
		return ""
	}
	content := resala.RenderBody(message.TemplateBody, variables)
	if smsContentSHA256(content) != message.ContentSHA256 {
		return ""
	}
	return content
}

func smsMessageWithOutcome(message control.SMSMessage, outcome control.SMSOutcome) control.SMSMessage {
	message.Status = outcome.Status
	message.ErrorCode = outcome.ErrorCode
	message.ErrorDetail = outcome.ErrorDetail
	message.Cost = control.NormalizeSMSCost(outcome.Cost)
	message.ContentSHA256 = outcome.ContentSHA256
	message.TemplateBody = outcome.TemplateBody
	message.TestMode = outcome.TestMode
	message.SentAt = outcome.SentAt
	return message
}

func smsContentSHA256(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}

func splitSMSIDs(values []string) []string {
	seen := map[string]bool{}
	var ids []string
	for _, value := range values {
		for _, id := range strings.Split(value, ",") {
			id = strings.TrimSpace(id)
			if id == "" || seen[id] {
				continue
			}
			seen[id] = true
			ids = append(ids, id)
		}
	}
	return ids
}

// parseSMSReportTime accepts an RFC3339 instant or a plain date, which means
// that day's midnight in Libya (UTC+2).
func parseSMSReportTime(raw string) (time.Time, error) {
	if parsed, err := time.Parse(time.RFC3339, raw); err == nil {
		return parsed, nil
	}
	day, err := time.Parse("2006-01-02", raw)
	if err != nil {
		return time.Time{}, err
	}
	return control.SMSDay(day.Year(), day.Month(), day.Day()), nil
}

func truncateRunes(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}
