package control

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"
	"time"
)

// SMS ledger statuses. A row is born pending — claimed BEFORE the provider is
// called, so a relay that dies mid-send leaves evidence instead of a message
// nobody can account for — and leaves pending exactly once.
const (
	SMSStatusPending     = "pending"
	SMSStatusSent        = "sent"
	SMSStatusFailed      = "failed"
	SMSStatusDelivered   = "delivered"
	SMSStatusUndelivered = "undelivered"
)

var (
	ErrSMSNotFound = errors.New("sms message not found")
	// ErrSMSMonthlyLimit is returned (as *SMSLimitError) when a claim would
	// take a shop past its monthly allowance.
	ErrSMSMonthlyLimit = errors.New("sms monthly limit reached")
	errSMSUnsupported  = errors.New("sms ledger is not supported by the underlying store")
)

// SMSLimitError is ErrSMSMonthlyLimit carrying the numbers the shop is shown.
type SMSLimitError struct {
	Limit int
	Used  int
}

func (e *SMSLimitError) Error() string {
	return fmt.Sprintf("sms monthly limit reached (%d of %d used)", e.Used, e.Limit)
}

func (e *SMSLimitError) Is(target error) bool { return target == ErrSMSMonthlyLimit }

// SMSMessage is one ledger row: one send of one message to one recipient.
//
// It deliberately holds no message content. The rendered text carries customer
// data (names, amounts owed, balances) and the relay has no business keeping
// it. ContentSHA256 is enough to recognise the message again in the provider's
// delivery log, and TemplateBody — the approved text with its "$n" placeholders,
// no customer data in it — lets a replay hand back the exact content when the
// caller repeats the same variables.
type SMSMessage struct {
	ID             string `json:"id"`
	InstallationID string `json:"installation_id"`
	// ShopName is filled by listings for the operator; it is not stored.
	ShopName       string `json:"shop_name,omitempty"`
	IdempotencyKey string `json:"idempotency_key"`
	Kind           string `json:"kind"`
	ConsentClass   string `json:"consent_class"`
	Recipient      string `json:"recipient"`
	ContentSHA256  string `json:"content_sha256,omitempty"`
	TemplateID     string `json:"template_id"`
	TemplateBody   string `json:"template_body,omitempty"`
	TestMode       bool   `json:"test_mode"`
	Status         string `json:"status"`
	ErrorCode      string `json:"error_code,omitempty"`
	ErrorDetail    string `json:"error_detail,omitempty"`
	// Cost is what the provider says the send cost the company.
	Cost string `json:"cost"`
	// Parts is how many SMS the message goes out as. A text longer than one
	// SMS (70 Arabic letters) is sent, and billed by the provider, as several;
	// the claim holds the count the relay expects and the provider's answer
	// settles it.
	Parts int `json:"parts"`
	// Price is what the shop pays for it from its SMS balance: Parts times the
	// price of one part. It is taken when the message is claimed and settled
	// to the parts it really went out as; a message that never went out —
	// failed, or a test after all — is refunded, so only billable rows keep
	// what they cost the shop.
	Price             string     `json:"price"`
	ProviderMessageID string     `json:"provider_message_id,omitempty"`
	CreatedAt         time.Time  `json:"created_at"`
	UpdatedAt         time.Time  `json:"updated_at"`
	SentAt            *time.Time `json:"sent_at,omitempty"`
	DeliveredAt       *time.Time `json:"delivered_at,omitempty"`
	// HeldSince is set while a failed message's refund waits on Resala's sent
	// log. The send failed in a way that leaves it unknown whether the SMS
	// went out — Resala timed out or erred after taking the request, or the
	// relay died mid-call — so its price is kept until the log shows it (it
	// stays paid for) or shows it never went out (it is refunded).
	HeldSince *time.Time `json:"held_since,omitempty"`
}

// SMSClaimTerms is what a new claim is checked and charged against. Both run
// under the same lock as the insert, so two sends racing for a shop's last
// message — or its last 0.150 — cannot both get it.
type SMSClaimTerms struct {
	// Limit is the operator's monthly brake; 0 means none.
	Limit int
	Since time.Time
	// Price is what one SMS part costs the shop, and Parts how many parts the
	// message is held for (at least one). Their product is taken from the
	// shop's SMS balance for a real (non-test) message; a price of "" or zero
	// charges nothing. A balance that cannot cover it refuses the claim with
	// *WalletBalanceError.
	Price string
	Parts int
	// ChargeDescription is the line the charge prints on the shop's statement.
	ChargeDescription string
}

// smsChargeKey, smsSettleKey and smsRefundKey tie a message's charge, its
// settlement and its refund to the ledger row, so none can ever be posted
// twice.
func smsChargeKey(messageID string) string { return "sms:" + messageID }
func smsSettleKey(messageID string) string { return "sms-settle:" + messageID }
func smsRefundKey(messageID string) string { return "sms-refund:" + messageID }

// smsClaimCharge records on the claim the parts it is held for and, for a
// real message, their price, and returns the amount to take from the SMS
// balance: nil for a test, or when there is no price. A malformed price
// charges nothing rather than guessing.
func smsClaimCharge(claim *SMSMessage, terms SMSClaimTerms) *big.Rat {
	claim.Parts = max(terms.Parts, 1)
	if claim.TestMode {
		return nil
	}
	price, err := ParseWalletAmount(terms.Price)
	if err != nil || price.Sign() <= 0 {
		return nil
	}
	charge := new(big.Rat).Mul(price, big.NewRat(int64(claim.Parts), 1))
	claim.Price = FormatWalletAmount(charge)
	return charge
}

func smsChargePosting(claim SMSMessage, price *big.Rat, description string) WalletPosting {
	return WalletPosting{
		InstallationID: claim.InstallationID,
		Account:        WalletAccountSMS,
		Kind:           WalletEntryCharge,
		Service:        WalletServiceSMS,
		Amount:         "-" + FormatWalletAmount(price),
		Reference:      claim.ID,
		Description:    smsDescription(description),
		IdempotencyKey: smsChargeKey(claim.ID),
	}
}

func smsDescription(description string) string {
	if description = strings.TrimSpace(description); description != "" {
		return description
	}
	return "رسالة نصية"
}

// smsRefundDue reports whether finishing a message this way gives its price
// back: it was charged, and it never reached a phone — it failed, or the
// provider ran it as a test.
func smsRefundDue(message SMSMessage) bool {
	price, ok := new(big.Rat).SetString(strings.TrimSpace(message.Price))
	if !ok || price.Sign() <= 0 {
		return false
	}
	return message.Status == SMSStatusFailed || message.TestMode
}

func smsRefundPosting(message SMSMessage) WalletPosting {
	return WalletPosting{
		InstallationID: message.InstallationID,
		Account:        WalletAccountSMS,
		Kind:           WalletEntryRefund,
		Service:        WalletServiceSMS,
		Amount:         NormalizeWalletAmount(message.Price),
		Reference:      message.ID,
		Description:    "استرداد رسالة لم تُرسل",
		IdempotencyKey: smsRefundKey(message.ID),
	}
}

// smsFinishPosting decides what finishing a message moves on the SMS balance,
// and records on finished the parts and the price it settles at. held is the
// row as it was claimed.
//
//   - It never reached a phone (failed, or a test after all): all of it comes
//     back.
//   - It went out as a different number of parts than it was held for: the
//     difference is charged or given back at the price per part it was held
//     at. A message that turned out longer is charged even past an empty
//     balance — it has gone out, and the provider bills the company for every
//     part — so the balance goes below zero and the next transfer into it
//     settles the debt. Holding the right count up front is what keeps that
//     rare.
//
// A failure that may still have gone out (outcome.Uncertain) is not refunded
// yet when the relay can recognise the message in Resala's sent log: its price
// is held (HeldSince = now) until the log has been checked.
//
// It returns nil when nothing moves.
func smsFinishPosting(
	held SMSMessage,
	finished *SMSMessage,
	outcome SMSOutcome,
	now time.Time,
) (*preparedWalletPosting, error) {
	if outcome.Parts > 0 {
		finished.Parts = outcome.Parts
	}
	if smsRefundDue(*finished) {
		if outcome.Uncertain && smsCheckable(*finished) {
			heldSince := now.UTC()
			finished.HeldSince = &heldSince
			return nil, nil
		}
		posting, err := prepareWalletPosting(smsRefundPosting(*finished))
		if err != nil {
			return nil, err
		}
		return &posting, nil
	}
	charged, ok := new(big.Rat).SetString(strings.TrimSpace(held.Price))
	if finished.Parts == held.Parts || !ok || charged.Sign() <= 0 || !smsWentOut(finished.Status) {
		return nil, nil
	}
	perPart := new(big.Rat).Quo(charged, big.NewRat(int64(max(held.Parts, 1)), 1))
	settled := new(big.Rat).Mul(perPart, big.NewRat(int64(finished.Parts), 1))
	finished.Price = FormatWalletAmount(settled)
	owed := new(big.Rat).Sub(settled, charged)
	posting, err := prepareWalletPosting(smsSettlePosting(*finished, owed, outcome.SettleDescription))
	if err != nil {
		return nil, err
	}
	posting.AllowOverdraft = owed.Sign() > 0
	return &posting, nil
}

// smsCheckable reports whether a failed message can wait for the sent-log
// check: it was charged for real, and the relay knows what it said, so its row
// in the log can be told apart from any other message to the same phone.
func smsCheckable(message SMSMessage) bool {
	price, ok := new(big.Rat).SetString(strings.TrimSpace(message.Price))
	return ok && price.Sign() > 0 && !message.TestMode && message.Status == SMSStatusFailed &&
		message.ContentSHA256 != ""
}

// smsWentOut reports whether a status means the message left Resala.
func smsWentOut(status string) bool {
	switch status {
	case SMSStatusSent, SMSStatusDelivered, SMSStatusUndelivered:
		return true
	}
	return false
}

// resolveSMSCheck applies what the sent log said to a held message: the row
// it becomes and what moves on the SMS balance (nil when nothing does).
func resolveSMSCheck(
	held SMSMessage,
	resolution SMSCheckResolution,
	now time.Time,
) (SMSMessage, *preparedWalletPosting, error) {
	resolved := held
	resolved.HeldSince = nil
	resolved.UpdatedAt = now.UTC()
	if detail := strings.TrimSpace(resolution.Detail); detail != "" {
		resolved.ErrorDetail = detail
	}
	if !resolution.WentOut {
		posting, err := prepareWalletPosting(smsRefundPosting(held))
		if err != nil {
			return SMSMessage{}, nil, err
		}
		return resolved, &posting, nil
	}
	status := resolution.Status
	if !smsWentOut(status) {
		status = SMSStatusSent
	}
	resolved.Status = status
	resolved.ErrorCode = ""
	if cost := strings.TrimSpace(resolution.Cost); cost != "" {
		resolved.Cost = NormalizeSMSCost(cost)
	}
	if id := strings.TrimSpace(resolution.ProviderMessageID); id != "" {
		resolved.ProviderMessageID = id
	}
	sentAt := resolution.SentAt
	if sentAt.IsZero() {
		sentAt = now
	}
	sentAt = sentAt.UTC()
	resolved.SentAt = &sentAt
	if status == SMSStatusDelivered {
		deliveredAt := now.UTC()
		if resolution.DeliveredAt != nil {
			deliveredAt = resolution.DeliveredAt.UTC()
		}
		resolved.DeliveredAt = &deliveredAt
	}
	posting, err := smsFinishPosting(held, &resolved, SMSOutcome{
		Parts:             resolution.Parts,
		SettleDescription: resolution.SettleDescription,
	}, now)
	if err != nil {
		return SMSMessage{}, nil, err
	}
	return resolved, posting, nil
}

// smsSettlePosting charges what a longer message still owes, or gives back
// what a shorter one was held for beyond its parts.
func smsSettlePosting(message SMSMessage, owed *big.Rat, description string) WalletPosting {
	posting := WalletPosting{
		InstallationID: message.InstallationID,
		Account:        WalletAccountSMS,
		Service:        WalletServiceSMS,
		Reference:      message.ID,
		IdempotencyKey: smsSettleKey(message.ID),
	}
	if owed.Sign() > 0 {
		posting.Kind = WalletEntryCharge
		posting.Amount = "-" + FormatWalletAmount(owed)
		posting.Description = "فرق عدد الرسائل: " + smsDescription(description)
		return posting
	}
	posting.Kind = WalletEntryRefund
	posting.Amount = FormatWalletAmount(new(big.Rat).Neg(owed))
	posting.Description = "استرداد فرق عدد الرسائل: " + smsDescription(description)
	return posting
}

// SMSOutcome is what a finished send records on its pending row.
type SMSOutcome struct {
	Status        string
	ErrorCode     string
	ErrorDetail   string
	Cost          string
	ContentSHA256 string
	TemplateBody  string
	// TestMode is restated because the provider has the last word: a send it
	// reports as not production reached no phone and must not be billed.
	TestMode bool
	SentAt   *time.Time
	// Parts is how many SMS the message went out as; 0 keeps what it was held
	// for. SettleDescription is the statement line of the difference, when
	// there is one to charge or give back.
	Parts             int
	SettleDescription string
	// Uncertain marks a failure that may still have gone out. A charged
	// message whose text the relay knows (ContentSHA256) is then held for the
	// sent-log check instead of refunded; one it could not recognise in the
	// log is refunded at once, as before.
	Uncertain bool
}

// SMSCheckResolution is what Resala's sent log said about a held message.
type SMSCheckResolution struct {
	// WentOut: the log shows the message, so it stays paid for — settled to
	// Parts when that is known — and takes Status (sent, delivered or
	// undelivered) and the log's id and times. Otherwise its price comes back.
	WentOut           bool
	Status            string
	ProviderMessageID string
	SentAt            time.Time
	DeliveredAt       *time.Time
	Parts             int
	SettleDescription string
	// Cost is what the message cost the company, when it went out. Resala's
	// answer — which carries the cost — was lost, so the check estimates it
	// from what Resala charged per part on the latest send (SMSPartCost).
	Cost string
	// Detail replaces the row's error detail: how the hold ended.
	Detail string
}

// SMSMessageFilter narrows the operator's ledger listing.
type SMSMessageFilter struct {
	InstallationID string
	Status         string
	Limit          int
}

// SMSInstallationUsage is one shop's line in the fleet usage report. Counts
// other than Test cover real (non-test) messages only.
type SMSInstallationUsage struct {
	InstallationID string `json:"installation_id"`
	ShopName       string `json:"shop_name"`
	Messages       int    `json:"messages"`
	Sent           int    `json:"sent"`
	Failed         int    `json:"failed"`
	Delivered      int    `json:"delivered"`
	Undelivered    int    `json:"undelivered"`
	Test           int    `json:"test"`
	// Parts is how many SMS the billable messages went out as. Cost is what
	// the provider charged the company; Charged is what the shop paid for the
	// same messages from its SMS balance.
	Parts      int            `json:"parts"`
	Cost       string         `json:"cost"`
	Charged    string         `json:"charged"`
	LastSentAt *time.Time     `json:"last_sent_at"`
	Kinds      map[string]int `json:"kinds"`
}

// SMSStore is the optional ledger capability, type-asserted by the HTTP layer
// and the delivery poller exactly like ExchangeRateStore.
type SMSStore interface {
	// BeginSMS claims (installation, idempotency key). A new claim is stored
	// as a pending row and returned with created=true; a key that was already
	// claimed returns the stored row with created=false, so two racing requests
	// for the same message can never both reach the provider. A new, non-test
	// claim is refused with *SMSLimitError once the limit is used up, and with
	// *WalletBalanceError when the SMS balance cannot cover its price, which
	// is otherwise charged in the same step.
	BeginSMS(ctx context.Context, message SMSMessage, terms SMSClaimTerms) (SMSMessage, bool, error)
	// FindSMSByKey returns the row an idempotency key already claimed.
	FindSMSByKey(ctx context.Context, installationID, idempotencyKey string) (SMSMessage, bool, error)
	// SMSTemplateBody is the approved text a template was last sent with, ""
	// when it never was. It is what lets a new message's parts be counted
	// before it is sent.
	SMSTemplateBody(ctx context.Context, templateID string) (string, error)
	// FinishSMS moves a pending row to its outcome. A row that already left
	// pending is returned untouched with applied=false: the first recorded
	// outcome wins, so a late finisher cannot overwrite a replay's verdict. In
	// the same step a charged message that did not go out is refunded, and one
	// that went out as more or fewer parts than it was held for is settled.
	FinishSMS(ctx context.Context, id string, outcome SMSOutcome) (SMSMessage, bool, error)
	// ListSMSAwaitingCheck returns failed messages whose refund is held for
	// the sent-log check (HeldSince set), oldest hold first.
	ListSMSAwaitingCheck(ctx context.Context, limit int) ([]SMSMessage, error)
	// ResolveSMSCheck ends a hold with what the sent log said, moving the money
	// in the same step. A message no longer held is returned untouched with
	// applied=false, so a hold is settled exactly once.
	ResolveSMSCheck(ctx context.Context, id string, resolution SMSCheckResolution) (SMSMessage, bool, error)
	// SMSClaimedProviderIDs reports which of these delivery-log ids are already
	// recorded on a ledger row: a log row another message owns is never
	// mistaken for a held one.
	SMSClaimedProviderIDs(ctx context.Context, ids []string) (map[string]bool, error)
	// SMSPartCost is what Resala charged per SMS part on the latest real send
	// that reported a cost, "" when none has. It prices a message whose own
	// answer was lost.
	SMSPartCost(ctx context.Context) (string, error)
	// CountBillableSMSSince counts real messages that were, or may have been,
	// sent: pending, sent, delivered and undelivered. Test sends and failures
	// are free.
	CountBillableSMSSince(ctx context.Context, installationID string, since time.Time) (int, error)
	// GetSMSByIDs returns the installation's own rows among ids; another
	// installation's ids are silently absent.
	GetSMSByIDs(ctx context.Context, installationID string, ids []string) ([]SMSMessage, error)
	// ListSMSMessages is the operator's view, newest first.
	ListSMSMessages(ctx context.Context, filter SMSMessageFilter) ([]SMSMessage, error)
	// SMSUsage aggregates [from, to) per installation, busiest first.
	SMSUsage(ctx context.Context, from, to time.Time) ([]SMSInstallationUsage, error)
	// ListSMSAwaitingDelivery returns real sends still at "sent" created since
	// the cutoff, newest first — the rows the delivery sync tries to resolve.
	ListSMSAwaitingDelivery(ctx context.Context, since time.Time, limit int) ([]SMSMessage, error)
	// UpdateSMSDelivery records a delivery report on a row still at "sent".
	// A row that already moved on is left alone.
	UpdateSMSDelivery(ctx context.Context, id, status, providerMessageID string, at time.Time) error
}

// Both real stores keep the ledger; the cached wrapper forwards it (see
// cache_capabilities.go).
var (
	_ SMSStore = (*FileStore)(nil)
	_ SMSStore = (*PostgresStore)(nil)
)

const (
	defaultSMSListLimit     = 50
	maxSMSListLimit         = 500
	defaultSMSAwaitingLimit = 500
	maxSMSAwaitingLimit     = 1000
)

// smsPeriodZone is the monthly allowance's calendar: Libya, UTC+2, the same
// business-day zone as the FX allowance. A calendar month rather than a rolling
// 30 days, so "used 480 of 500 this month" is something a shopkeeper can reason
// about.
var smsPeriodZone = time.FixedZone("UTC+2", 2*60*60)

// SMSMonthlyPeriod returns the calendar month (UTC+2) containing now, as the
// instant it started and the instant the allowance renews. Both are expressed
// in UTC+2 so they read as local midnights.
func SMSMonthlyPeriod(now time.Time) (start time.Time, resetsAt time.Time) {
	local := now.In(smsPeriodZone)
	start = time.Date(local.Year(), local.Month(), 1, 0, 0, 0, 0, smsPeriodZone)
	return start, start.AddDate(0, 1, 0)
}

// SMSDay returns midnight (UTC+2) of the given calendar date, for reports that
// take plain dates.
func SMSDay(year int, month time.Month, day int) time.Time {
	return time.Date(year, month, day, 0, 0, 0, 0, smsPeriodZone)
}

// ValidSMSStatus reports whether status is a ledger status.
func ValidSMSStatus(status string) bool {
	switch status {
	case SMSStatusPending, SMSStatusSent, SMSStatusFailed, SMSStatusDelivered, SMSStatusUndelivered:
		return true
	}
	return false
}

func smsBillable(status string) bool {
	switch status {
	case SMSStatusPending, SMSStatusSent, SMSStatusDelivered, SMSStatusUndelivered:
		return true
	}
	return false
}

// NormalizeSMSCost writes a decimal charge with at least two decimals and no
// trailing zeros beyond them: "0.1" -> "0.10", "0.125" -> "0.125". The dinar
// has three decimal places, so rounding to two would lose real money. Anything
// that is not a decimal becomes "0.00".
func NormalizeSMSCost(raw string) string {
	value, ok := new(big.Rat).SetString(strings.TrimSpace(raw))
	if !ok {
		return "0.00"
	}
	return formatSMSCost(value)
}

// SumSMSCosts adds decimal charges exactly.
func SumSMSCosts(costs []string) string {
	total := new(big.Rat)
	for _, cost := range costs {
		if value, ok := new(big.Rat).SetString(strings.TrimSpace(cost)); ok {
			total.Add(total, value)
		}
	}
	return formatSMSCost(total)
}

func formatSMSCost(value *big.Rat) string {
	text := strings.TrimRight(value.FloatString(6), "0")
	whole, fraction, _ := strings.Cut(text, ".")
	for len(fraction) < 2 {
		fraction += "0"
	}
	return whole + "." + fraction
}

// prepareSMSClaim fills what a claim needs before it is stored.
func prepareSMSClaim(message SMSMessage, now time.Time) (SMSMessage, error) {
	message.InstallationID = strings.TrimSpace(message.InstallationID)
	message.IdempotencyKey = strings.TrimSpace(message.IdempotencyKey)
	if message.InstallationID == "" || message.IdempotencyKey == "" {
		return SMSMessage{}, errors.New("sms claim needs an installation and an idempotency key")
	}
	if strings.TrimSpace(message.ID) == "" {
		id, err := NewInstallationID()
		if err != nil {
			return SMSMessage{}, err
		}
		message.ID = id
	}
	if message.CreatedAt.IsZero() {
		message.CreatedAt = now
	}
	message.CreatedAt = message.CreatedAt.UTC()
	message.UpdatedAt = message.CreatedAt
	message.Status = SMSStatusPending
	message.ErrorCode = ""
	message.ErrorDetail = ""
	message.Cost = NormalizeSMSCost(message.Cost)
	message.Parts = 1
	message.Price = FormatWalletAmount(nil)
	message.ShopName = ""
	message.SentAt = nil
	message.DeliveredAt = nil
	message.HeldSince = nil
	return message, nil
}

func applySMSOutcome(message SMSMessage, outcome SMSOutcome, now time.Time) SMSMessage {
	message.Status = outcome.Status
	message.ErrorCode = strings.TrimSpace(outcome.ErrorCode)
	message.ErrorDetail = strings.TrimSpace(outcome.ErrorDetail)
	message.Cost = NormalizeSMSCost(outcome.Cost)
	if outcome.ContentSHA256 != "" {
		message.ContentSHA256 = outcome.ContentSHA256
	}
	if outcome.TemplateBody != "" {
		message.TemplateBody = outcome.TemplateBody
	}
	message.TestMode = outcome.TestMode
	if outcome.SentAt != nil {
		sentAt := outcome.SentAt.UTC()
		message.SentAt = &sentAt
	}
	message.UpdatedAt = now.UTC()
	return message
}

func validateSMSOutcome(outcome SMSOutcome) error {
	switch outcome.Status {
	case SMSStatusSent, SMSStatusFailed:
		return nil
	}
	return fmt.Errorf("sms outcome must be sent or failed, got %q", outcome.Status)
}

func validateSMSDelivery(status string) error {
	switch status {
	case SMSStatusSent, SMSStatusDelivered, SMSStatusUndelivered:
		return nil
	}
	return fmt.Errorf("sms delivery status must be sent, delivered or undelivered, got %q", status)
}

func normalizedSMSListLimit(limit int) int {
	if limit <= 0 {
		return defaultSMSListLimit
	}
	return min(limit, maxSMSListLimit)
}

func normalizedSMSAwaitingLimit(limit int) int {
	if limit <= 0 {
		return defaultSMSAwaitingLimit
	}
	return min(limit, maxSMSAwaitingLimit)
}

func sortSMSUsage(rows []SMSInstallationUsage) {
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Messages != rows[j].Messages {
			return rows[i].Messages > rows[j].Messages
		}
		if rows[i].Test != rows[j].Test {
			return rows[i].Test > rows[j].Test
		}
		return rows[i].InstallationID < rows[j].InstallationID
	})
}

// sortSMSNewestFirst orders rows newest first with the id as a stable tiebreak.
func sortSMSNewestFirst(rows []SMSMessage) {
	sort.Slice(rows, func(i, j int) bool {
		if !rows[i].CreatedAt.Equal(rows[j].CreatedAt) {
			return rows[i].CreatedAt.After(rows[j].CreatedAt)
		}
		return rows[i].ID > rows[j].ID
	})
}

// --- FileStore ---

func (s *FileStore) findSMSByKeyLocked(installationID, key string) (SMSMessage, bool) {
	for _, message := range s.data.SMSMessages {
		if message.InstallationID == installationID && message.IdempotencyKey == key {
			return message, true
		}
	}
	return SMSMessage{}, false
}

func (s *FileStore) countBillableSMSLocked(installationID string, since time.Time) int {
	count := 0
	for _, message := range s.data.SMSMessages {
		if message.InstallationID != installationID || message.TestMode || !smsBillable(message.Status) {
			continue
		}
		if message.CreatedAt.Before(since) {
			continue
		}
		count++
	}
	return count
}

func (s *FileStore) BeginSMS(
	_ context.Context,
	message SMSMessage,
	terms SMSClaimTerms,
) (SMSMessage, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	claim, err := prepareSMSClaim(message, s.clock.Now())
	if err != nil {
		return SMSMessage{}, false, err
	}
	if existing, ok := s.findSMSByKeyLocked(claim.InstallationID, claim.IdempotencyKey); ok {
		return existing, false, nil
	}
	if terms.Limit > 0 && !claim.TestMode {
		if used := s.countBillableSMSLocked(claim.InstallationID, terms.Since); used >= terms.Limit {
			return SMSMessage{}, false, &SMSLimitError{Limit: terms.Limit, Used: used}
		}
	}
	var charge WalletEntry
	if price := smsClaimCharge(&claim, terms); price != nil {
		posting, err := prepareWalletPosting(smsChargePosting(claim, price, terms.ChargeDescription))
		if err != nil {
			return SMSMessage{}, false, err
		}
		if charge, _, err = s.postWalletEntryLocked(posting); err != nil {
			return SMSMessage{}, false, err
		}
	}
	if s.data.SMSMessages == nil {
		s.data.SMSMessages = map[string]SMSMessage{}
	}
	s.data.SMSMessages[claim.ID] = claim
	if err := s.saveLocked(); err != nil {
		delete(s.data.SMSMessages, claim.ID)
		if charge.ID != "" {
			delete(s.data.WalletEntries, charge.ID)
		}
		return SMSMessage{}, false, err
	}
	return claim, true, nil
}

func (s *FileStore) FindSMSByKey(
	_ context.Context,
	installationID, idempotencyKey string,
) (SMSMessage, bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	message, ok := s.findSMSByKeyLocked(strings.TrimSpace(installationID), strings.TrimSpace(idempotencyKey))
	return message, ok, nil
}

func (s *FileStore) FinishSMS(
	_ context.Context,
	id string,
	outcome SMSOutcome,
) (SMSMessage, bool, error) {
	if err := validateSMSOutcome(outcome); err != nil {
		return SMSMessage{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.SMSMessages[id]
	if !ok {
		return SMSMessage{}, false, ErrSMSNotFound
	}
	if existing.Status != SMSStatusPending {
		return existing, false, nil
	}
	now := s.clock.Now()
	finished := applySMSOutcome(existing, outcome, now)
	posting, err := smsFinishPosting(existing, &finished, outcome, now)
	if err != nil {
		return SMSMessage{}, false, err
	}
	var moved WalletEntry
	if posting != nil {
		if moved, _, err = s.postWalletEntryLocked(*posting); err != nil {
			return SMSMessage{}, false, err
		}
	}
	s.data.SMSMessages[id] = finished
	if err := s.saveLocked(); err != nil {
		s.data.SMSMessages[id] = existing
		if moved.ID != "" {
			delete(s.data.WalletEntries, moved.ID)
		}
		return SMSMessage{}, false, err
	}
	return finished, true, nil
}

func (s *FileStore) SMSTemplateBody(_ context.Context, templateID string) (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	templateID = strings.TrimSpace(templateID)
	var latest SMSMessage
	for _, message := range s.data.SMSMessages {
		if message.TemplateID != templateID || message.TemplateBody == "" {
			continue
		}
		if latest.ID == "" || message.CreatedAt.After(latest.CreatedAt) ||
			(message.CreatedAt.Equal(latest.CreatedAt) && message.ID > latest.ID) {
			latest = message
		}
	}
	return latest.TemplateBody, nil
}

func (s *FileStore) ListSMSAwaitingCheck(_ context.Context, limit int) ([]SMSMessage, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	held := make([]SMSMessage, 0)
	for _, message := range s.data.SMSMessages {
		if message.HeldSince != nil {
			held = append(held, message)
		}
	}
	sort.Slice(held, func(i, j int) bool {
		if !held[i].HeldSince.Equal(*held[j].HeldSince) {
			return held[i].HeldSince.Before(*held[j].HeldSince)
		}
		return held[i].ID < held[j].ID
	})
	if limit = normalizedSMSAwaitingLimit(limit); len(held) > limit {
		held = held[:limit]
	}
	return held, nil
}

func (s *FileStore) ResolveSMSCheck(
	_ context.Context,
	id string,
	resolution SMSCheckResolution,
) (SMSMessage, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.SMSMessages[id]
	if !ok {
		return SMSMessage{}, false, ErrSMSNotFound
	}
	if existing.HeldSince == nil {
		return existing, false, nil
	}
	resolved, posting, err := resolveSMSCheck(existing, resolution, s.clock.Now())
	if err != nil {
		return SMSMessage{}, false, err
	}
	var moved WalletEntry
	if posting != nil {
		if moved, _, err = s.postWalletEntryLocked(*posting); err != nil {
			return SMSMessage{}, false, err
		}
	}
	s.data.SMSMessages[id] = resolved
	if err := s.saveLocked(); err != nil {
		s.data.SMSMessages[id] = existing
		if moved.ID != "" {
			delete(s.data.WalletEntries, moved.ID)
		}
		return SMSMessage{}, false, err
	}
	return resolved, true, nil
}

func (s *FileStore) SMSPartCost(_ context.Context) (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var latest SMSMessage
	for _, message := range s.data.SMSMessages {
		cost, ok := new(big.Rat).SetString(strings.TrimSpace(message.Cost))
		if message.TestMode || !smsWentOut(message.Status) || !ok || cost.Sign() <= 0 {
			continue
		}
		if latest.ID == "" || message.CreatedAt.After(latest.CreatedAt) ||
			(message.CreatedAt.Equal(latest.CreatedAt) && message.ID > latest.ID) {
			latest = message
		}
	}
	if latest.ID == "" {
		return "", nil
	}
	return smsPerPart(latest.Cost, latest.Parts), nil
}

// SMSCostOfParts prices parts at a per-part cost, exactly; "" for a cost
// that is not a number.
func SMSCostOfParts(perPart string, parts int) string {
	value, ok := new(big.Rat).SetString(strings.TrimSpace(perPart))
	if !ok {
		return ""
	}
	return formatSMSCost(value.Mul(value, big.NewRat(int64(max(parts, 1)), 1)))
}

// smsPerPart divides a message's cost by its parts, exactly.
func smsPerPart(cost string, parts int) string {
	value, ok := new(big.Rat).SetString(strings.TrimSpace(cost))
	if !ok {
		return ""
	}
	return formatSMSCost(value.Quo(value, big.NewRat(int64(max(parts, 1)), 1)))
}

func (s *FileStore) SMSClaimedProviderIDs(_ context.Context, ids []string) (map[string]bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	wanted := map[string]bool{}
	for _, id := range ids {
		if id = strings.TrimSpace(id); id != "" {
			wanted[id] = true
		}
	}
	claimed := map[string]bool{}
	for _, message := range s.data.SMSMessages {
		if wanted[message.ProviderMessageID] {
			claimed[message.ProviderMessageID] = true
		}
	}
	return claimed, nil
}

func (s *FileStore) CountBillableSMSSince(
	_ context.Context,
	installationID string,
	since time.Time,
) (int, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.countBillableSMSLocked(installationID, since), nil
}

func (s *FileStore) GetSMSByIDs(
	_ context.Context,
	installationID string,
	ids []string,
) ([]SMSMessage, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	messages := make([]SMSMessage, 0, len(ids))
	seen := map[string]bool{}
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		message, ok := s.data.SMSMessages[id]
		if !ok || message.InstallationID != installationID {
			continue
		}
		messages = append(messages, message)
	}
	return messages, nil
}

func (s *FileStore) ListSMSMessages(
	_ context.Context,
	filter SMSMessageFilter,
) ([]SMSMessage, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	installationID := strings.TrimSpace(filter.InstallationID)
	status := strings.TrimSpace(filter.Status)
	messages := make([]SMSMessage, 0)
	for _, message := range s.data.SMSMessages {
		if installationID != "" && message.InstallationID != installationID {
			continue
		}
		if status != "" && message.Status != status {
			continue
		}
		message.ShopName = s.data.Installations[message.InstallationID].ShopName
		messages = append(messages, message)
	}
	sortSMSNewestFirst(messages)
	if limit := normalizedSMSListLimit(filter.Limit); len(messages) > limit {
		messages = messages[:limit]
	}
	return messages, nil
}

func (s *FileStore) SMSUsage(_ context.Context, from, to time.Time) ([]SMSInstallationUsage, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	byInstallation := map[string]*SMSInstallationUsage{}
	costs := map[string][]string{}
	charges := map[string][]string{}
	for _, message := range s.data.SMSMessages {
		if message.CreatedAt.Before(from) || !message.CreatedAt.Before(to) {
			continue
		}
		usage, ok := byInstallation[message.InstallationID]
		if !ok {
			usage = &SMSInstallationUsage{
				InstallationID: message.InstallationID,
				ShopName:       s.data.Installations[message.InstallationID].ShopName,
				Kinds:          map[string]int{},
			}
			byInstallation[message.InstallationID] = usage
		}
		if message.TestMode {
			usage.Test++
			continue
		}
		usage.Messages++
		usage.Kinds[message.Kind]++
		costs[message.InstallationID] = append(costs[message.InstallationID], message.Cost)
		if smsBillable(message.Status) {
			usage.Parts += max(message.Parts, 1)
			charges[message.InstallationID] = append(charges[message.InstallationID], message.Price)
		}
		switch message.Status {
		case SMSStatusFailed:
			usage.Failed++
		case SMSStatusSent:
			usage.Sent++
		case SMSStatusDelivered:
			usage.Sent++
			usage.Delivered++
		case SMSStatusUndelivered:
			usage.Sent++
			usage.Undelivered++
		}
		if message.SentAt != nil && (usage.LastSentAt == nil || message.SentAt.After(*usage.LastSentAt)) {
			sentAt := *message.SentAt
			usage.LastSentAt = &sentAt
		}
	}
	rows := make([]SMSInstallationUsage, 0, len(byInstallation))
	for id, usage := range byInstallation {
		usage.Cost = SumSMSCosts(costs[id])
		usage.Charged = SumWalletAmounts(charges[id])
		rows = append(rows, *usage)
	}
	sortSMSUsage(rows)
	return rows, nil
}

func (s *FileStore) ListSMSAwaitingDelivery(
	_ context.Context,
	since time.Time,
	limit int,
) ([]SMSMessage, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	messages := make([]SMSMessage, 0)
	for _, message := range s.data.SMSMessages {
		if message.Status != SMSStatusSent || message.TestMode || message.CreatedAt.Before(since) {
			continue
		}
		messages = append(messages, message)
	}
	sortSMSNewestFirst(messages)
	if limit = normalizedSMSAwaitingLimit(limit); len(messages) > limit {
		messages = messages[:limit]
	}
	return messages, nil
}

func (s *FileStore) UpdateSMSDelivery(
	_ context.Context,
	id, status, providerMessageID string,
	at time.Time,
) error {
	if err := validateSMSDelivery(status); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.SMSMessages[id]
	if !ok {
		return ErrSMSNotFound
	}
	if existing.Status != SMSStatusSent {
		return nil
	}
	updated := existing
	updated.Status = status
	if providerMessageID = strings.TrimSpace(providerMessageID); providerMessageID != "" {
		updated.ProviderMessageID = providerMessageID
	}
	if status == SMSStatusDelivered {
		deliveredAt := at.UTC()
		updated.DeliveredAt = &deliveredAt
	}
	updated.UpdatedAt = s.clock.Now().UTC()
	s.data.SMSMessages[id] = updated
	if err := s.saveLocked(); err != nil {
		s.data.SMSMessages[id] = existing
		return err
	}
	return nil
}

// --- CachedInstallationStore forwarding ---
//
// The ledger never touches installation rows, so nothing here needs to drop a
// cached installation.

func (s *CachedInstallationStore) smsStore() (SMSStore, error) {
	store, ok := s.store.(SMSStore)
	if !ok {
		return nil, errSMSUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) BeginSMS(
	ctx context.Context,
	message SMSMessage,
	terms SMSClaimTerms,
) (SMSMessage, bool, error) {
	store, err := s.smsStore()
	if err != nil {
		return SMSMessage{}, false, err
	}
	return store.BeginSMS(ctx, message, terms)
}

func (s *CachedInstallationStore) FindSMSByKey(
	ctx context.Context,
	installationID, idempotencyKey string,
) (SMSMessage, bool, error) {
	store, err := s.smsStore()
	if err != nil {
		return SMSMessage{}, false, err
	}
	return store.FindSMSByKey(ctx, installationID, idempotencyKey)
}

func (s *CachedInstallationStore) SMSTemplateBody(ctx context.Context, templateID string) (string, error) {
	store, err := s.smsStore()
	if err != nil {
		return "", err
	}
	return store.SMSTemplateBody(ctx, templateID)
}

func (s *CachedInstallationStore) FinishSMS(
	ctx context.Context,
	id string,
	outcome SMSOutcome,
) (SMSMessage, bool, error) {
	store, err := s.smsStore()
	if err != nil {
		return SMSMessage{}, false, err
	}
	return store.FinishSMS(ctx, id, outcome)
}

func (s *CachedInstallationStore) ListSMSAwaitingCheck(ctx context.Context, limit int) ([]SMSMessage, error) {
	store, err := s.smsStore()
	if err != nil {
		return nil, err
	}
	return store.ListSMSAwaitingCheck(ctx, limit)
}

func (s *CachedInstallationStore) ResolveSMSCheck(
	ctx context.Context,
	id string,
	resolution SMSCheckResolution,
) (SMSMessage, bool, error) {
	store, err := s.smsStore()
	if err != nil {
		return SMSMessage{}, false, err
	}
	return store.ResolveSMSCheck(ctx, id, resolution)
}

func (s *CachedInstallationStore) SMSPartCost(ctx context.Context) (string, error) {
	store, err := s.smsStore()
	if err != nil {
		return "", err
	}
	return store.SMSPartCost(ctx)
}

func (s *CachedInstallationStore) SMSClaimedProviderIDs(ctx context.Context, ids []string) (map[string]bool, error) {
	store, err := s.smsStore()
	if err != nil {
		return nil, err
	}
	return store.SMSClaimedProviderIDs(ctx, ids)
}

func (s *CachedInstallationStore) CountBillableSMSSince(
	ctx context.Context,
	installationID string,
	since time.Time,
) (int, error) {
	store, err := s.smsStore()
	if err != nil {
		return 0, err
	}
	return store.CountBillableSMSSince(ctx, installationID, since)
}

func (s *CachedInstallationStore) GetSMSByIDs(
	ctx context.Context,
	installationID string,
	ids []string,
) ([]SMSMessage, error) {
	store, err := s.smsStore()
	if err != nil {
		return nil, err
	}
	return store.GetSMSByIDs(ctx, installationID, ids)
}

func (s *CachedInstallationStore) ListSMSMessages(
	ctx context.Context,
	filter SMSMessageFilter,
) ([]SMSMessage, error) {
	store, err := s.smsStore()
	if err != nil {
		return nil, err
	}
	return store.ListSMSMessages(ctx, filter)
}

func (s *CachedInstallationStore) SMSUsage(
	ctx context.Context,
	from, to time.Time,
) ([]SMSInstallationUsage, error) {
	store, err := s.smsStore()
	if err != nil {
		return nil, err
	}
	return store.SMSUsage(ctx, from, to)
}

func (s *CachedInstallationStore) ListSMSAwaitingDelivery(
	ctx context.Context,
	since time.Time,
	limit int,
) ([]SMSMessage, error) {
	store, err := s.smsStore()
	if err != nil {
		return nil, err
	}
	return store.ListSMSAwaitingDelivery(ctx, since, limit)
}

func (s *CachedInstallationStore) UpdateSMSDelivery(
	ctx context.Context,
	id, status, providerMessageID string,
	at time.Time,
) error {
	store, err := s.smsStore()
	if err != nil {
		return err
	}
	return store.UpdateSMSDelivery(ctx, id, status, providerMessageID, at)
}
