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
	ShopName          string     `json:"shop_name,omitempty"`
	IdempotencyKey    string     `json:"idempotency_key"`
	Kind              string     `json:"kind"`
	ConsentClass      string     `json:"consent_class"`
	Recipient         string     `json:"recipient"`
	ContentSHA256     string     `json:"content_sha256,omitempty"`
	TemplateID        string     `json:"template_id"`
	TemplateBody      string     `json:"template_body,omitempty"`
	TestMode          bool       `json:"test_mode"`
	Status            string     `json:"status"`
	ErrorCode         string     `json:"error_code,omitempty"`
	ErrorDetail       string     `json:"error_detail,omitempty"`
	Cost              string     `json:"cost"`
	ProviderMessageID string     `json:"provider_message_id,omitempty"`
	CreatedAt         time.Time  `json:"created_at"`
	UpdatedAt         time.Time  `json:"updated_at"`
	SentAt            *time.Time `json:"sent_at,omitempty"`
	DeliveredAt       *time.Time `json:"delivered_at,omitempty"`
}

// SMSClaimLimit is the monthly allowance a new claim is checked against. The
// check runs under the same lock as the insert, so two sends racing for a
// shop's last message cannot both get it. Limit 0 means no cap.
type SMSClaimLimit struct {
	Limit int
	Since time.Time
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
	InstallationID string         `json:"installation_id"`
	ShopName       string         `json:"shop_name"`
	Messages       int            `json:"messages"`
	Sent           int            `json:"sent"`
	Failed         int            `json:"failed"`
	Delivered      int            `json:"delivered"`
	Undelivered    int            `json:"undelivered"`
	Test           int            `json:"test"`
	Cost           string         `json:"cost"`
	LastSentAt     *time.Time     `json:"last_sent_at"`
	Kinds          map[string]int `json:"kinds"`
}

// SMSStore is the optional ledger capability, type-asserted by the HTTP layer
// and the delivery poller exactly like ExchangeRateStore.
type SMSStore interface {
	// BeginSMS claims (installation, idempotency key). A new claim is stored
	// as a pending row and returned with created=true; a key that was already
	// claimed returns the stored row with created=false, so two racing requests
	// for the same message can never both reach the provider. A new, non-test
	// claim is refused with *SMSLimitError once the limit is used up.
	BeginSMS(ctx context.Context, message SMSMessage, limit SMSClaimLimit) (SMSMessage, bool, error)
	// FindSMSByKey returns the row an idempotency key already claimed.
	FindSMSByKey(ctx context.Context, installationID, idempotencyKey string) (SMSMessage, bool, error)
	// FinishSMS moves a pending row to its outcome. A row that already left
	// pending is returned untouched with applied=false: the first recorded
	// outcome wins, so a late finisher cannot overwrite a replay's verdict.
	FinishSMS(ctx context.Context, id string, outcome SMSOutcome) (SMSMessage, bool, error)
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
	message.ShopName = ""
	message.SentAt = nil
	message.DeliveredAt = nil
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
	limit SMSClaimLimit,
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
	if limit.Limit > 0 && !claim.TestMode {
		if used := s.countBillableSMSLocked(claim.InstallationID, limit.Since); used >= limit.Limit {
			return SMSMessage{}, false, &SMSLimitError{Limit: limit.Limit, Used: used}
		}
	}
	if s.data.SMSMessages == nil {
		s.data.SMSMessages = map[string]SMSMessage{}
	}
	s.data.SMSMessages[claim.ID] = claim
	if err := s.saveLocked(); err != nil {
		delete(s.data.SMSMessages, claim.ID)
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
	finished := applySMSOutcome(existing, outcome, s.clock.Now())
	s.data.SMSMessages[id] = finished
	if err := s.saveLocked(); err != nil {
		s.data.SMSMessages[id] = existing
		return SMSMessage{}, false, err
	}
	return finished, true, nil
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
	limit SMSClaimLimit,
) (SMSMessage, bool, error) {
	store, err := s.smsStore()
	if err != nil {
		return SMSMessage{}, false, err
	}
	return store.BeginSMS(ctx, message, limit)
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
