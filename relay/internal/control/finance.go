package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The company's own books: what the company earns and spends, beside the
// shops' wallets it keeps.
//
// Two kinds of numbers meet here. Tracked ones the relay already records —
// a shop's charge for a service, what a supplier charged for its cards, what
// Resala charged for a text, a paid top-up — are read from their own tables
// and never copied. Manual ones are what the relay cannot see: the server
// bill, a salary, a subscription a shop paid in cash at the office. Those are
// finance entries.
//
// An entry is never edited or deleted. A mistake is voided (with a reason, by
// a named operator) and entered again, so the books an owner reads back are
// the books everyone wrote.

// Directions of a finance entry.
const (
	FinanceIncome  = "income"
	FinanceExpense = "expense"
)

// FinanceCurrency is the books' currency: every entry is booked in dinars,
// whatever it was paid in.
const FinanceCurrency = "LYD"

// financeZone is Libya's clock (UTC+2 all year, no daylight saving): a month
// in the books is a Libyan calendar month. A fixed zone needs no tzdata in
// the container.
var financeZone = time.FixedZone("LY", 2*60*60)

// FinanceMonth names the month a moment falls in, on Libya's clock: "2026-10".
func FinanceMonth(at time.Time) string {
	return at.In(financeZone).Format("2006-01")
}

// FinanceDayStart is the first moment of a Libyan calendar day.
func FinanceDayStart(day time.Time) time.Time {
	y, m, d := day.In(financeZone).Date()
	return time.Date(y, m, d, 0, 0, 0, 0, financeZone)
}

// ParseFinanceDate reads a "2006-01-02" day on Libya's clock.
func ParseFinanceDate(raw string) (time.Time, error) {
	return time.ParseInLocation("2006-01-02", strings.TrimSpace(raw), financeZone)
}

// FinanceEntry is one line the operator wrote in the company's books.
type FinanceEntry struct {
	ID        string `json:"id"`
	Direction string `json:"direction"`
	// Category is a short slug ("hosting", "salaries"); the console names it.
	Category string `json:"category"`
	// Amount is what the books count, in dinars with three places.
	Amount string `json:"amount"`
	// Currency, OriginalAmount and Rate are what was actually paid: 120 USD
	// at 7.2 is booked as 864 LYD. A dinar entry has rate 1.
	Currency       string `json:"currency"`
	OriginalAmount string `json:"original_amount"`
	Rate           string `json:"rate"`
	// OccurredOn is the day the money moved, on Libya's clock: "2026-10-09".
	OccurredOn string `json:"occurred_on"`
	// Counterparty is who was paid or who paid: "Azure", "محل النسيم".
	Counterparty string `json:"counterparty,omitempty"`
	Note         string `json:"note,omitempty"`
	// InstallationID ties the line to a shop (a cash subscription, a device
	// sold to it). Optional, and not a foreign key: the books outlive a shop.
	InstallationID string `json:"installation_id,omitempty"`
	ShopName       string `json:"shop_name,omitempty"`
	// Reference is the paper trail: an invoice or transfer number.
	Reference      string     `json:"reference,omitempty"`
	IdempotencyKey string     `json:"idempotency_key"`
	Actor          string     `json:"actor,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	VoidedAt       *time.Time `json:"voided_at,omitempty"`
	VoidedBy       string     `json:"voided_by,omitempty"`
	VoidReason     string     `json:"void_reason,omitempty"`
	// Attachments are the invoice or receipt behind the line: photos or PDFs
	// in the receipt store, by hash. One can be added after the line is
	// written; none is ever taken away.
	Attachments []WalletReceiptRef `json:"attachments"`
	// RecurringID and RecurringMonth tie a line to the monthly expense that
	// wrote it, for the month it stands for ("2026-10").
	RecurringID    string `json:"recurring_id,omitempty"`
	RecurringMonth string `json:"recurring_month,omitempty"`
}

// FinanceEntryFilter narrows a listing. From and To are inclusive days.
type FinanceEntryFilter struct {
	From           string
	To             string
	Direction      string
	Category       string
	InstallationID string
	IncludeVoided  bool
	Limit          int
}

// FinanceTrackedMonth is one month of what the relay recorded on its own, in
// dinars unless a map is keyed by currency.
type FinanceTrackedMonth struct {
	Month string `json:"month"`
	// Revenue is what shops paid for each service (charges less refunds).
	Revenue map[string]string `json:"revenue"`
	// SMSCost is what Resala charged for the texts that went out.
	SMSCost string `json:"sms_cost"`
	// SupplierCost is what card, airtime and bill suppliers charged, by the
	// currency they charged in.
	SupplierCost map[string]string `json:"supplier_cost"`
	// TopUps is money shops paid into their wallets, by method. It is the
	// shops' money, held, not income.
	TopUps map[string]string `json:"topups"`
}

// FinanceStore is an optional store capability (type-asserted, like
// AlertStore) for the company's books.
type FinanceStore interface {
	FinanceRecurringStore
	// CreateFinanceEntry records an entry. A repeated idempotency key returns
	// the first entry and true.
	CreateFinanceEntry(ctx context.Context, entry FinanceEntry) (FinanceEntry, bool, error)
	ListFinanceEntries(ctx context.Context, filter FinanceEntryFilter) ([]FinanceEntry, error)
	// VoidFinanceEntry takes an entry out of the books, keeping it on file.
	VoidFinanceEntry(ctx context.Context, id, actor, reason string) (FinanceEntry, error)
	// AddFinanceAttachment adds a stored receipt to an entry (a no-op when it
	// is already there).
	AddFinanceAttachment(ctx context.Context, id string, ref WalletReceiptRef) (FinanceEntry, error)
	// FinanceTracked rolls up the relay's own records in [from, to), oldest
	// month first.
	FinanceTracked(ctx context.Context, from, to time.Time) ([]FinanceTrackedMonth, error)
}

var (
	// ErrInvalidFinanceEntry wraps what is wrong with an entry.
	ErrInvalidFinanceEntry = errors.New("invalid finance entry")
	// ErrFinanceEntryVoided is a second void of the same entry.
	ErrFinanceEntryVoided = errors.New("finance entry already voided")
	// ErrFinanceAttachmentLimit is one receipt too many on an entry.
	ErrFinanceAttachmentLimit = errors.New("finance entry has too many attachments")
)

const (
	maxFinanceText       = 200
	maxFinanceNote       = 1000
	defaultFinanceLimit  = 500
	maxFinanceLimit      = 5000
	financeRateDecimals  = 6
	financeEarliestYear  = 2020
	financeMaxDaysFuture = 1
	// MaxFinanceAttachments bounds the receipts behind one line.
	MaxFinanceAttachments = 10
)

var (
	financeCategoryPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,39}$`)
	financeCurrencyPattern = regexp.MustCompile(`^[A-Z]{3}$`)
	financeRatePattern     = regexp.MustCompile(`^\d{1,8}(\.\d{1,6})?$`)
	financeMonthPattern    = regexp.MustCompile(`^20\d\d-(0[1-9]|1[0-2])$`)
)

// FinanceAttachmentTypes are what a receipt may be.
var FinanceAttachmentTypes = map[string]bool{"image/jpeg": true, "image/png": true, "image/webp": true, "application/pdf": true}

func normalizeFinanceAttachment(ref WalletReceiptRef) (WalletReceiptRef, error) {
	ref.SHA256 = strings.ToLower(strings.TrimSpace(ref.SHA256))
	if !ValidWalletReceiptHash(ref.SHA256) || !FinanceAttachmentTypes[ref.ContentType] || ref.Size <= 0 {
		return WalletReceiptRef{}, invalidFinance("an attachment must be a stored photo or PDF")
	}
	ref.Name = truncateRunes(strings.TrimSpace(ref.Name), 120)
	return ref, nil
}

// mergeFinanceAttachments adds refs not already on the list, by hash.
func mergeFinanceAttachments(list []WalletReceiptRef, refs ...WalletReceiptRef) ([]WalletReceiptRef, error) {
	out := append([]WalletReceiptRef{}, list...)
	for _, ref := range refs {
		ref, err := normalizeFinanceAttachment(ref)
		if err != nil {
			return nil, err
		}
		seen := false
		for _, have := range out {
			seen = seen || have.SHA256 == ref.SHA256
		}
		if !seen {
			out = append(out, ref)
		}
	}
	if len(out) > MaxFinanceAttachments {
		return nil, ErrFinanceAttachmentLimit
	}
	return out, nil
}

func invalidFinance(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalidFinanceEntry, fmt.Sprintf(format, args...))
}

// prepareFinanceEntry checks an entry and fills what the store derives: the
// dinar amount, the id, the time.
func prepareFinanceEntry(entry FinanceEntry, now time.Time) (FinanceEntry, error) {
	entry.Direction = strings.ToLower(strings.TrimSpace(entry.Direction))
	if entry.Direction != FinanceIncome && entry.Direction != FinanceExpense {
		return FinanceEntry{}, invalidFinance("direction must be income or expense")
	}
	entry.Category = strings.ToLower(strings.TrimSpace(entry.Category))
	if !financeCategoryPattern.MatchString(entry.Category) {
		return FinanceEntry{}, invalidFinance("category %q is not a slug", entry.Category)
	}
	entry.Currency = strings.ToUpper(strings.TrimSpace(entry.Currency))
	if entry.Currency == "" {
		entry.Currency = FinanceCurrency
	}
	if !financeCurrencyPattern.MatchString(entry.Currency) {
		return FinanceEntry{}, invalidFinance("currency %q is not an ISO code", entry.Currency)
	}
	original, err := ParseWalletAmount(entry.OriginalAmount)
	if err != nil || original.Sign() <= 0 {
		return FinanceEntry{}, invalidFinance("amount must be a positive number with at most three decimals")
	}
	rate := big.NewRat(1, 1)
	if entry.Currency != FinanceCurrency {
		text := strings.TrimSpace(entry.Rate)
		parsed, ok := new(big.Rat).SetString(text)
		if !financeRatePattern.MatchString(text) || !ok || parsed.Sign() <= 0 {
			return FinanceEntry{}, invalidFinance("a %s amount needs its dinar rate", entry.Currency)
		}
		rate = parsed
	}
	entry.OriginalAmount = FormatWalletAmount(original)
	entry.Rate = rate.FloatString(financeRateDecimals)
	entry.Amount = FormatWalletAmount(new(big.Rat).Mul(original, rate))
	if entry.Amount == "0.000" {
		return FinanceEntry{}, invalidFinance("the dinar amount rounds to zero")
	}

	day, err := ParseFinanceDate(entry.OccurredOn)
	if err != nil {
		return FinanceEntry{}, invalidFinance("occurred_on must be a date (2006-01-02)")
	}
	if day.Year() < financeEarliestYear || day.After(FinanceDayStart(now).AddDate(0, 0, financeMaxDaysFuture)) {
		return FinanceEntry{}, invalidFinance("occurred_on %s is out of range", entry.OccurredOn)
	}
	entry.OccurredOn = day.Format("2006-01-02")

	entry.Counterparty = truncateRunes(strings.TrimSpace(entry.Counterparty), maxFinanceText)
	entry.Note = truncateRunes(strings.TrimSpace(entry.Note), maxFinanceNote)
	entry.InstallationID = truncateRunes(strings.TrimSpace(entry.InstallationID), maxFinanceText)
	entry.Reference = truncateRunes(strings.TrimSpace(entry.Reference), maxFinanceText)
	entry.Actor = truncateRunes(strings.TrimSpace(entry.Actor), maxFinanceText)
	entry.IdempotencyKey = strings.TrimSpace(entry.IdempotencyKey)
	if entry.IdempotencyKey == "" || len(entry.IdempotencyKey) > maxFinanceText {
		return FinanceEntry{}, invalidFinance("idempotency_key is required")
	}
	entry.ShopName = ""
	entry.VoidedAt, entry.VoidedBy, entry.VoidReason = nil, "", ""
	if entry.Attachments, err = mergeFinanceAttachments(nil, entry.Attachments...); err != nil {
		return FinanceEntry{}, err
	}
	entry.RecurringID = strings.TrimSpace(entry.RecurringID)
	entry.RecurringMonth = strings.TrimSpace(entry.RecurringMonth)
	if (entry.RecurringID == "") != (entry.RecurringMonth == "") ||
		(entry.RecurringMonth != "" && !financeMonthPattern.MatchString(entry.RecurringMonth)) {
		return FinanceEntry{}, invalidFinance("a recurring line names its recurring expense and month (2006-01)")
	}
	id, err := NewInstallationID()
	if err != nil {
		return FinanceEntry{}, err
	}
	entry.ID = "fin_" + id
	entry.CreatedAt = now.UTC()
	return entry, nil
}

func prepareFinanceVoid(actor, reason string) (string, string, error) {
	reason = truncateRunes(strings.TrimSpace(reason), maxFinanceNote)
	if reason == "" {
		return "", "", invalidFinance("a void needs its reason")
	}
	return truncateRunes(strings.TrimSpace(actor), maxFinanceText), reason, nil
}

func normalizeFinanceFilter(filter FinanceEntryFilter) (FinanceEntryFilter, error) {
	for _, day := range []*string{&filter.From, &filter.To} {
		*day = strings.TrimSpace(*day)
		if *day == "" {
			continue
		}
		parsed, err := ParseFinanceDate(*day)
		if err != nil {
			return FinanceEntryFilter{}, invalidFinance("dates are written 2006-01-02")
		}
		*day = parsed.Format("2006-01-02")
	}
	filter.Direction = strings.ToLower(strings.TrimSpace(filter.Direction))
	filter.Category = strings.ToLower(strings.TrimSpace(filter.Category))
	filter.InstallationID = strings.TrimSpace(filter.InstallationID)
	switch {
	case filter.Limit <= 0:
		filter.Limit = defaultFinanceLimit
	case filter.Limit > maxFinanceLimit:
		filter.Limit = maxFinanceLimit
	}
	return filter, nil
}

func (filter FinanceEntryFilter) matches(entry FinanceEntry) bool {
	// Dates written 2006-01-02 compare as strings.
	return (filter.From == "" || entry.OccurredOn >= filter.From) &&
		(filter.To == "" || entry.OccurredOn <= filter.To) &&
		(filter.Direction == "" || entry.Direction == filter.Direction) &&
		(filter.Category == "" || entry.Category == filter.Category) &&
		(filter.InstallationID == "" || entry.InstallationID == filter.InstallationID) &&
		(filter.IncludeVoided || entry.VoidedAt == nil)
}

// sortFinanceEntriesNewestFirst orders by the day the money moved, then by
// when it was written.
func sortFinanceEntriesNewestFirst(entries []FinanceEntry) {
	sort.SliceStable(entries, func(i, j int) bool {
		if entries[i].OccurredOn != entries[j].OccurredOn {
			return entries[i].OccurredOn > entries[j].OccurredOn
		}
		if !entries[i].CreatedAt.Equal(entries[j].CreatedAt) {
			return entries[i].CreatedAt.After(entries[j].CreatedAt)
		}
		return entries[i].ID > entries[j].ID
	})
}

// financeRollup gathers tracked amounts into months.
type financeRollup struct {
	months map[string]*financeRollupMonth
}

type financeRollupMonth struct {
	revenue      map[string]*big.Rat
	smsCost      *big.Rat
	supplierCost map[string]*big.Rat
	topUps       map[string]*big.Rat
}

func newFinanceRollup() *financeRollup {
	return &financeRollup{months: map[string]*financeRollupMonth{}}
}

func (r *financeRollup) month(name string) *financeRollupMonth {
	m, ok := r.months[name]
	if !ok {
		m = &financeRollupMonth{
			revenue:      map[string]*big.Rat{},
			smsCost:      new(big.Rat),
			supplierCost: map[string]*big.Rat{},
			topUps:       map[string]*big.Rat{},
		}
		r.months[name] = m
	}
	return m
}

func addRat(into map[string]*big.Rat, key string, raw string) {
	value, ok := new(big.Rat).SetString(strings.TrimSpace(raw))
	if !ok || value.Sign() == 0 {
		return
	}
	if into[key] == nil {
		into[key] = new(big.Rat)
	}
	into[key].Add(into[key], value)
}

func (r *financeRollup) addRevenue(month, service, amount string) {
	addRat(r.month(month).revenue, service, amount)
}

func (r *financeRollup) addSMSCost(month, cost string) {
	if value, ok := new(big.Rat).SetString(strings.TrimSpace(cost)); ok {
		m := r.month(month)
		m.smsCost.Add(m.smsCost, value)
	}
}

func (r *financeRollup) addSupplierCost(month, currency, cost string) {
	addRat(r.month(month).supplierCost, strings.ToUpper(strings.TrimSpace(currency)), cost)
}

func (r *financeRollup) addTopUp(month, method, amount string) {
	addRat(r.month(month).topUps, method, amount)
}

func formatRats(values map[string]*big.Rat) map[string]string {
	out := make(map[string]string, len(values))
	for key, value := range values {
		if value.Sign() != 0 {
			out[key] = FormatWalletAmount(value)
		}
	}
	return out
}

func (r *financeRollup) result() []FinanceTrackedMonth {
	names := make([]string, 0, len(r.months))
	for name := range r.months {
		names = append(names, name)
	}
	sort.Strings(names)
	out := make([]FinanceTrackedMonth, 0, len(names))
	for _, name := range names {
		m := r.months[name]
		out = append(out, FinanceTrackedMonth{
			Month:        name,
			Revenue:      formatRats(m.revenue),
			SMSCost:      FormatWalletAmount(m.smsCost),
			SupplierCost: formatRats(m.supplierCost),
			TopUps:       formatRats(m.topUps),
		})
	}
	return out
}

func within(at, from, to time.Time) bool {
	return !at.Before(from) && at.Before(to)
}

// smsCostCounts says whether a text's cost is the company's: it went out and
// was real.
func smsCostCounts(status string, testMode bool) bool {
	if testMode {
		return false
	}
	switch status {
	case SMSStatusSent, SMSStatusDelivered, SMSStatusUndelivered:
		return true
	}
	return false
}

// --- file store ------------------------------------------------------------

func (s *FileStore) CreateFinanceEntry(_ context.Context, entry FinanceEntry) (FinanceEntry, bool, error) {
	entry, err := prepareFinanceEntry(entry, s.clock.Now())
	if err != nil {
		return FinanceEntry{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, existing := range s.data.FinanceEntries {
		if existing.IdempotencyKey == entry.IdempotencyKey {
			return existing, true, nil
		}
	}
	if s.data.FinanceEntries == nil {
		s.data.FinanceEntries = map[string]FinanceEntry{}
	}
	s.data.FinanceEntries[entry.ID] = entry
	if err := s.saveLocked(); err != nil {
		delete(s.data.FinanceEntries, entry.ID)
		return FinanceEntry{}, false, err
	}
	return entry, false, nil
}

func (s *FileStore) ListFinanceEntries(_ context.Context, filter FinanceEntryFilter) ([]FinanceEntry, error) {
	filter, err := normalizeFinanceFilter(filter)
	if err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	entries := []FinanceEntry{}
	for _, entry := range s.data.FinanceEntries {
		if filter.matches(entry) {
			if shop, ok := s.data.Installations[entry.InstallationID]; ok {
				entry.ShopName = shop.ShopName
			}
			entries = append(entries, entry)
		}
	}
	sortFinanceEntriesNewestFirst(entries)
	if len(entries) > filter.Limit {
		entries = entries[:filter.Limit]
	}
	return entries, nil
}

func (s *FileStore) VoidFinanceEntry(_ context.Context, id, actor, reason string) (FinanceEntry, error) {
	actor, reason, err := prepareFinanceVoid(actor, reason)
	if err != nil {
		return FinanceEntry{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.data.FinanceEntries[id]
	if !ok {
		return FinanceEntry{}, ErrNotFound
	}
	if entry.VoidedAt != nil {
		return entry, ErrFinanceEntryVoided
	}
	before := entry
	now := s.clock.Now().UTC()
	entry.VoidedAt, entry.VoidedBy, entry.VoidReason = &now, actor, reason
	s.data.FinanceEntries[id] = entry
	if err := s.saveLocked(); err != nil {
		s.data.FinanceEntries[id] = before
		return FinanceEntry{}, err
	}
	return entry, nil
}

func (s *FileStore) AddFinanceAttachment(_ context.Context, id string, ref WalletReceiptRef) (FinanceEntry, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.data.FinanceEntries[id]
	if !ok {
		return FinanceEntry{}, ErrNotFound
	}
	before := entry
	attachments, err := mergeFinanceAttachments(entry.Attachments, ref)
	if err != nil {
		return FinanceEntry{}, err
	}
	entry.Attachments = attachments
	s.data.FinanceEntries[id] = entry
	if err := s.saveLocked(); err != nil {
		s.data.FinanceEntries[id] = before
		return FinanceEntry{}, err
	}
	return entry, nil
}

func (s *FileStore) FinanceTracked(_ context.Context, from, to time.Time) ([]FinanceTrackedMonth, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rollup := newFinanceRollup()
	for _, entry := range s.data.WalletEntries {
		if entry.TestMode || entry.Service == "" || !within(entry.CreatedAt, from, to) {
			continue
		}
		if entry.Kind == WalletEntryCharge || entry.Kind == WalletEntryRefund {
			// A charge is negative on the shop's statement: positive revenue.
			amount, ok := new(big.Rat).SetString(entry.Amount)
			if ok {
				rollup.addRevenue(FinanceMonth(entry.CreatedAt), entry.Service, amount.Neg(amount).RatString())
			}
		}
	}
	for _, message := range s.data.SMSMessages {
		at := message.CreatedAt
		if message.SentAt != nil {
			at = *message.SentAt
		}
		if smsCostCounts(message.Status, message.TestMode) && within(at, from, to) {
			rollup.addSMSCost(FinanceMonth(at), message.Cost)
		}
	}
	for _, purchase := range s.data.VoucherPurchases {
		at := purchase.CreatedAt
		if purchase.CompletedAt != nil {
			at = *purchase.CompletedAt
		}
		if purchase.Status == VoucherPurchaseSucceeded && !purchase.TestMode && within(at, from, to) {
			rollup.addSupplierCost(FinanceMonth(at), purchase.SupplierCurrency, purchase.SupplierCost)
		}
	}
	for _, topUp := range s.data.WalletTopUps {
		if topUp.Status != WalletTopUpPaid || topUp.TestMode || topUp.PaidAt == nil || !within(*topUp.PaidAt, from, to) {
			continue
		}
		rollup.addTopUp(FinanceMonth(*topUp.PaidAt), topUp.Method, topUp.Amount)
	}
	return rollup.result(), nil
}

// --- postgres store --------------------------------------------------------

const financeEntryColumns = `e.id, e.direction, e.category, e.amount::text, e.currency, e.original_amount::text,
	e.rate::text, to_char(e.occurred_on, 'YYYY-MM-DD'), e.counterparty, e.note, e.installation_id,
	COALESCE(i.shop_name, ''), e.reference, e.idempotency_key, e.actor, e.created_at, e.voided_at,
	e.voided_by, e.void_reason, e.attachments, e.recurring_id, e.recurring_month`

const financeEntryFrom = ` FROM relay_finance_entries e LEFT JOIN relay_installations i ON i.id = e.installation_id`

func scanFinanceEntry(row pgx.Row) (FinanceEntry, error) {
	var entry FinanceEntry
	err := row.Scan(&entry.ID, &entry.Direction, &entry.Category, &entry.Amount, &entry.Currency,
		&entry.OriginalAmount, &entry.Rate, &entry.OccurredOn, &entry.Counterparty, &entry.Note,
		&entry.InstallationID, &entry.ShopName, &entry.Reference, &entry.IdempotencyKey, &entry.Actor,
		&entry.CreatedAt, &entry.VoidedAt, &entry.VoidedBy, &entry.VoidReason, &entry.Attachments,
		&entry.RecurringID, &entry.RecurringMonth)
	if err != nil {
		return FinanceEntry{}, err
	}
	if entry.Attachments == nil {
		entry.Attachments = []WalletReceiptRef{}
	}
	entry.Amount = NormalizeWalletAmount(entry.Amount)
	entry.OriginalAmount = NormalizeWalletAmount(entry.OriginalAmount)
	if rate, ok := new(big.Rat).SetString(entry.Rate); ok {
		entry.Rate = rate.FloatString(financeRateDecimals)
	}
	return entry, nil
}

func (s *PostgresStore) financeEntry(ctx context.Context, where string, arg any) (FinanceEntry, error) {
	entry, err := scanFinanceEntry(s.pool.QueryRow(ctx, `SELECT `+financeEntryColumns+financeEntryFrom+` WHERE `+where, arg))
	if errors.Is(err, pgx.ErrNoRows) {
		return FinanceEntry{}, ErrNotFound
	}
	return entry, err
}

func (s *PostgresStore) CreateFinanceEntry(ctx context.Context, entry FinanceEntry) (FinanceEntry, bool, error) {
	entry, err := prepareFinanceEntry(entry, s.clock.Now())
	if err != nil {
		return FinanceEntry{}, false, err
	}
	attachments, err := json.Marshal(entry.Attachments)
	if err != nil {
		return FinanceEntry{}, false, err
	}
	tag, err := s.pool.Exec(ctx,
		`INSERT INTO relay_finance_entries (id, direction, category, amount, currency, original_amount, rate,
			occurred_on, counterparty, note, installation_id, reference, idempotency_key, actor, created_at,
			attachments, recurring_id, recurring_month)
		VALUES ($1, $2, $3, $4::numeric, $5, $6::numeric, $7::numeric, $8::date, $9, $10, $11, $12, $13, $14, $15::timestamptz,
			$16::jsonb, $17, $18)
		ON CONFLICT (idempotency_key) DO NOTHING`,
		entry.ID, entry.Direction, entry.Category, entry.Amount, entry.Currency, entry.OriginalAmount, entry.Rate,
		entry.OccurredOn, entry.Counterparty, entry.Note, entry.InstallationID, entry.Reference,
		entry.IdempotencyKey, entry.Actor, entry.CreatedAt, attachments, entry.RecurringID, entry.RecurringMonth,
	)
	if err != nil {
		return FinanceEntry{}, false, err
	}
	if tag.RowsAffected() == 0 {
		existing, err := s.financeEntry(ctx, `e.idempotency_key = $1`, entry.IdempotencyKey)
		return existing, err == nil, err
	}
	stored, err := s.financeEntry(ctx, `e.id = $1`, entry.ID)
	return stored, false, err
}

func (s *PostgresStore) ListFinanceEntries(ctx context.Context, filter FinanceEntryFilter) ([]FinanceEntry, error) {
	filter, err := normalizeFinanceFilter(filter)
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx,
		`SELECT `+financeEntryColumns+financeEntryFrom+`
		WHERE ($1 = '' OR e.occurred_on >= NULLIF($1, '')::date)
			AND ($2 = '' OR e.occurred_on <= NULLIF($2, '')::date)
			AND ($3 = '' OR e.direction = $3)
			AND ($4 = '' OR e.category = $4)
			AND ($5 = '' OR e.installation_id = $5)
			AND ($6 OR e.voided_at IS NULL)
		ORDER BY e.occurred_on DESC, e.created_at DESC, e.id DESC
		LIMIT $7`,
		filter.From, filter.To, filter.Direction, filter.Category, filter.InstallationID, filter.IncludeVoided, filter.Limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	entries := []FinanceEntry{}
	for rows.Next() {
		entry, err := scanFinanceEntry(rows)
		if err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	return entries, rows.Err()
}

func (s *PostgresStore) VoidFinanceEntry(ctx context.Context, id, actor, reason string) (FinanceEntry, error) {
	actor, reason, err := prepareFinanceVoid(actor, reason)
	if err != nil {
		return FinanceEntry{}, err
	}
	tag, err := s.pool.Exec(ctx,
		`UPDATE relay_finance_entries SET voided_at = $2::timestamptz, voided_by = $3, void_reason = $4
		WHERE id = $1 AND voided_at IS NULL`,
		id, s.clock.Now().UTC(), actor, reason,
	)
	if err != nil {
		return FinanceEntry{}, err
	}
	entry, err := s.financeEntry(ctx, `e.id = $1`, id)
	if err != nil {
		return FinanceEntry{}, err
	}
	if tag.RowsAffected() == 0 {
		return entry, ErrFinanceEntryVoided
	}
	return entry, nil
}

func (s *PostgresStore) AddFinanceAttachment(ctx context.Context, id string, ref WalletReceiptRef) (FinanceEntry, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return FinanceEntry{}, err
	}
	defer tx.Rollback(ctx)
	var current []WalletReceiptRef
	err = tx.QueryRow(ctx, `SELECT attachments FROM relay_finance_entries WHERE id = $1 FOR UPDATE`, id).Scan(&current)
	if errors.Is(err, pgx.ErrNoRows) {
		return FinanceEntry{}, ErrNotFound
	}
	if err != nil {
		return FinanceEntry{}, err
	}
	merged, err := mergeFinanceAttachments(current, ref)
	if err != nil {
		return FinanceEntry{}, err
	}
	encoded, err := json.Marshal(merged)
	if err != nil {
		return FinanceEntry{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE relay_finance_entries SET attachments = $2::jsonb WHERE id = $1`, id, encoded); err != nil {
		return FinanceEntry{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return FinanceEntry{}, err
	}
	return s.financeEntry(ctx, `e.id = $1`, id)
}

// financeMonthSQL buckets a timestamp into a Libyan month (UTC+2).
func financeMonthSQL(column string) string {
	return `to_char((` + column + ` AT TIME ZONE 'UTC') + interval '2 hours', 'YYYY-MM')`
}

func (s *PostgresStore) FinanceTracked(ctx context.Context, from, to time.Time) ([]FinanceTrackedMonth, error) {
	rollup := newFinanceRollup()
	queries := []struct {
		sql string
		add func(month, key, amount string)
	}{
		{
			// A charge is negative on the shop's statement: positive revenue.
			`SELECT ` + financeMonthSQL("created_at") + `, service, SUM(-amount)::text
			FROM relay_wallet_entries
			WHERE kind IN ('charge', 'refund') AND service <> '' AND NOT test_mode
				AND created_at >= $1 AND created_at < $2
			GROUP BY 1, 2`,
			rollup.addRevenue,
		},
		{
			`SELECT ` + financeMonthSQL("COALESCE(sent_at, created_at)") + `, '', SUM(cost)::text
			FROM relay_sms_messages
			WHERE status IN ('sent', 'delivered', 'undelivered') AND NOT test_mode
				AND COALESCE(sent_at, created_at) >= $1 AND COALESCE(sent_at, created_at) < $2
			GROUP BY 1`,
			func(month, _, amount string) { rollup.addSMSCost(month, amount) },
		},
		{
			// supplier_cost is text as the supplier wrote it; anything that
			// does not read as a number is left out rather than failing the
			// whole report.
			`SELECT ` + financeMonthSQL("COALESCE(completed_at, created_at)") + `, upper(supplier_currency),
				SUM(CASE WHEN supplier_cost ~ '^\s*[0-9]+(\.[0-9]+)?\s*$' THEN trim(supplier_cost)::numeric ELSE 0 END)::text
			FROM relay_voucher_purchases
			WHERE status = 'succeeded' AND NOT test_mode
				AND COALESCE(completed_at, created_at) >= $1 AND COALESCE(completed_at, created_at) < $2
			GROUP BY 1, 2`,
			rollup.addSupplierCost,
		},
		{
			`SELECT ` + financeMonthSQL("paid_at") + `, method, SUM(amount)::text
			FROM relay_wallet_topups
			WHERE status = 'paid' AND NOT test_mode AND paid_at >= $1 AND paid_at < $2
			GROUP BY 1, 2`,
			rollup.addTopUp,
		},
	}
	for _, query := range queries {
		rows, err := s.pool.Query(ctx, query.sql, from.UTC(), to.UTC())
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var month, key, amount string
			if err := rows.Scan(&month, &key, &amount); err != nil {
				rows.Close()
				return nil, err
			}
			query.add(month, key, amount)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	return rollup.result(), nil
}

// --- cache wrapper -----------------------------------------------------------

func (s *CachedInstallationStore) financeStore() (FinanceStore, error) {
	store, ok := s.store.(FinanceStore)
	if !ok {
		return nil, errors.New("finance store is unavailable")
	}
	return store, nil
}

func (s *CachedInstallationStore) CreateFinanceEntry(ctx context.Context, entry FinanceEntry) (FinanceEntry, bool, error) {
	store, err := s.financeStore()
	if err != nil {
		return FinanceEntry{}, false, err
	}
	return store.CreateFinanceEntry(ctx, entry)
}

func (s *CachedInstallationStore) ListFinanceEntries(ctx context.Context, filter FinanceEntryFilter) ([]FinanceEntry, error) {
	store, err := s.financeStore()
	if err != nil {
		return nil, err
	}
	return store.ListFinanceEntries(ctx, filter)
}

func (s *CachedInstallationStore) VoidFinanceEntry(ctx context.Context, id, actor, reason string) (FinanceEntry, error) {
	store, err := s.financeStore()
	if err != nil {
		return FinanceEntry{}, err
	}
	return store.VoidFinanceEntry(ctx, id, actor, reason)
}

func (s *CachedInstallationStore) AddFinanceAttachment(ctx context.Context, id string, ref WalletReceiptRef) (FinanceEntry, error) {
	store, err := s.financeStore()
	if err != nil {
		return FinanceEntry{}, err
	}
	return store.AddFinanceAttachment(ctx, id, ref)
}

func (s *CachedInstallationStore) FinanceTracked(ctx context.Context, from, to time.Time) ([]FinanceTrackedMonth, error) {
	store, err := s.financeStore()
	if err != nil {
		return nil, err
	}
	return store.FinanceTracked(ctx, from, to)
}
