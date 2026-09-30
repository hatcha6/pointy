package control

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// A shop's wallet is its prepaid balance with the company: money the shop paid
// in through the payment gateway, spent on the company's services — the
// subscription, SMS, AI, vouchers. The relay keeps it as a ledger. Every
// movement is one signed entry that also records the balance it left, and an
// entry is never edited: a mistake is answered with another entry. So every
// dinar the balance claims is explained by rows anyone can read back.

// Ledger entry kinds.
const (
	// WalletEntryTopUp is money in through the payment gateway.
	WalletEntryTopUp = "topup"
	// WalletEntryCharge is money out for a service.
	WalletEntryCharge = "charge"
	// WalletEntryRefund gives a charge back.
	WalletEntryRefund = "refund"
	// WalletEntryAdjustment is an operator's correction, either sign.
	WalletEntryAdjustment = "adjustment"
)

// Services a charge or refund is for. The list is open — a new service needs
// only a new name — but these are the ones the company sells today.
const (
	WalletServiceSubscription = "subscription"
	WalletServiceSMS          = "sms"
	WalletServiceAI           = "ai"
	WalletServiceVouchers     = "vouchers"
)

// Top-up statuses. A top-up is born pending, before the gateway is asked for a
// checkout, and is paid exactly once.
const (
	WalletTopUpPending  = "pending"
	WalletTopUpPaid     = "paid"
	WalletTopUpCanceled = "canceled"
	WalletTopUpFailed   = "failed"
	// WalletTopUpExpired is a checkout nobody came back from in time. It is
	// not final: a signed approval arriving later still credits the wallet,
	// because the payer's money has left their bank either way.
	WalletTopUpExpired = "expired"
)

// WalletTopUpMethodPlutuLocalBankCards is Plutu's hosted local-bank-card
// checkout. Sadad and Adfali (OTP) and T-Lync will be methods of their own.
const WalletTopUpMethodPlutuLocalBankCards = "plutu_localbankcards"

var (
	ErrWalletEntryNotFound = errors.New("wallet entry not found")
	ErrWalletTopUpNotFound = errors.New("wallet top-up not found")
	// ErrWalletInsufficientBalance is returned (as *WalletBalanceError) when
	// a debit would take a balance below zero.
	ErrWalletInsufficientBalance = errors.New("wallet balance is insufficient")
	errWalletUnsupported         = errors.New("wallets are not supported by the underlying store")
)

// WalletBalanceError is ErrWalletInsufficientBalance carrying the numbers the
// shop is shown.
type WalletBalanceError struct {
	Balance string
	Amount  string
}

func (e *WalletBalanceError) Error() string {
	return fmt.Sprintf("wallet balance %s cannot cover %s", e.Balance, e.Amount)
}

func (e *WalletBalanceError) Is(target error) bool { return target == ErrWalletInsufficientBalance }

// Wallet is one shop's balance.
type Wallet struct {
	InstallationID string `json:"installation_id"`
	// ShopName is filled by listings for the operator; it is not stored.
	ShopName  string     `json:"shop_name,omitempty"`
	Balance   string     `json:"balance"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
}

// WalletEntry is one movement of a shop's balance.
type WalletEntry struct {
	ID             string `json:"id"`
	InstallationID string `json:"installation_id"`
	ShopName       string `json:"shop_name,omitempty"`
	Kind           string `json:"kind"`
	Service        string `json:"service,omitempty"`
	// Amount is signed: positive credits the wallet, negative debits it.
	Amount       string `json:"amount"`
	BalanceAfter string `json:"balance_after"`
	// Reference names what the movement is about: the top-up it credits, the
	// charge a refund answers, the order a voucher charge paid for.
	Reference      string    `json:"reference,omitempty"`
	Description    string    `json:"description,omitempty"`
	IdempotencyKey string    `json:"idempotency_key"`
	Actor          string    `json:"actor,omitempty"`
	TestMode       bool      `json:"test_mode"`
	CreatedAt      time.Time `json:"created_at"`
}

// WalletPosting is a movement to record.
type WalletPosting struct {
	InstallationID string
	Kind           string
	Service        string
	// Amount is a signed decimal of dinars with at most three places.
	Amount      string
	Reference   string
	Description string
	// IdempotencyKey makes a retried posting safe: a key the wallet has seen
	// returns that entry instead of moving the money twice.
	IdempotencyKey string
	Actor          string
	TestMode       bool
	// AllowOverdraft lets an operator's correction take a balance below zero.
	// Charges never may.
	AllowOverdraft bool
}

// WalletTopUp is one attempt to pay money into a wallet.
type WalletTopUp struct {
	ID             string `json:"id"`
	InstallationID string `json:"installation_id"`
	ShopName       string `json:"shop_name,omitempty"`
	Method         string `json:"method"`
	Amount         string `json:"amount"`
	Status         string `json:"status"`
	// InvoiceNo is the gateway's reference, unique across the company's
	// merchant account. It is what support matches against the gateway's
	// dashboard, so it is short and readable.
	InvoiceNo             string `json:"invoice_no"`
	ProviderTransactionID string `json:"provider_transaction_id,omitempty"`
	CheckoutURL           string `json:"checkout_url,omitempty"`
	IdempotencyKey        string `json:"idempotency_key"`
	// RequestedBy is the shop user who started it, as the shop named them.
	RequestedBy string `json:"requested_by,omitempty"`
	TestMode    bool   `json:"test_mode"`
	ErrorCode   string `json:"error_code,omitempty"`
	ErrorDetail string `json:"error_detail,omitempty"`
	// EntryID is the ledger entry a paid top-up credited.
	EntryID string `json:"entry_id,omitempty"`
	// ConfirmedBy is what proved the payment: the gateway's signed return, or
	// the operator who reconciled it by hand.
	ConfirmedBy string     `json:"confirmed_by,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
	PaidAt      *time.Time `json:"paid_at,omitempty"`
}

// WalletTopUpSettlement is the proof a top-up was paid.
type WalletTopUpSettlement struct {
	ProviderTransactionID string
	ConfirmedBy           string
	Description           string
}

// WalletEntryFilter narrows a ledger listing. BeforeID pages: entries older
// than that one.
type WalletEntryFilter struct {
	InstallationID string
	Kind           string
	Limit          int
	BeforeID       string
}

// WalletTopUpFilter narrows a top-up listing.
type WalletTopUpFilter struct {
	InstallationID string
	Status         string
	Limit          int
	BeforeID       string
}

// WalletStore is the optional wallet capability, type-asserted by the HTTP
// layer like SMSStore.
type WalletStore interface {
	// GetWallet returns the balance; a shop that never had an entry has 0.
	GetWallet(ctx context.Context, installationID string) (Wallet, error)
	// ListWallets is the operator's view, largest balance first.
	ListWallets(ctx context.Context, limit int) ([]Wallet, error)
	// PostWalletEntry records a movement. A repeated idempotency key returns
	// the first entry with created=false. A debit that would take the balance
	// below zero is refused with *WalletBalanceError unless AllowOverdraft.
	PostWalletEntry(ctx context.Context, posting WalletPosting) (WalletEntry, bool, error)
	ListWalletEntries(ctx context.Context, filter WalletEntryFilter) ([]WalletEntry, error)
	// BeginWalletTopUp stores a pending top-up with a fresh invoice number. A
	// repeated idempotency key returns the first with created=false.
	BeginWalletTopUp(ctx context.Context, topUp WalletTopUp) (WalletTopUp, bool, error)
	// AttachWalletTopUpCheckout records the checkout page on a pending top-up.
	AttachWalletTopUpCheckout(ctx context.Context, id, checkoutURL string) (WalletTopUp, error)
	GetWalletTopUp(ctx context.Context, id string) (WalletTopUp, error)
	FindWalletTopUpByInvoice(ctx context.Context, invoiceNo string) (WalletTopUp, error)
	ListWalletTopUps(ctx context.Context, filter WalletTopUpFilter) ([]WalletTopUp, error)
	// SettleWalletTopUp marks a top-up paid and credits the wallet, in one
	// step and exactly once: a top-up already paid is returned untouched with
	// applied=false. Any other status may be settled, because a proven payment
	// has taken the payer's money whatever the relay believed before.
	SettleWalletTopUp(ctx context.Context, id string, settlement WalletTopUpSettlement) (WalletTopUp, bool, error)
	// CloseWalletTopUp moves a pending or expired top-up to canceled or
	// failed. Anything else is returned untouched with applied=false.
	CloseWalletTopUp(ctx context.Context, id, status, code, detail string) (WalletTopUp, bool, error)
	// ExpireWalletTopUps marks pending top-ups created before the cutoff as
	// expired and returns how many it moved.
	ExpireWalletTopUps(ctx context.Context, createdBefore time.Time) (int, error)
}

// Both real stores keep wallets; the cached wrapper forwards them.
var (
	_ WalletStore = (*FileStore)(nil)
	_ WalletStore = (*PostgresStore)(nil)
)

const (
	defaultWalletListLimit = 50
	maxWalletListLimit     = 200
	maxWalletKeyRunes      = 128
	maxWalletTextRunes     = 500
	// walletAmountDecimals is the dinar's three places (the dirham). The
	// gateway takes two; that is its rule, checked where a top-up is made.
	walletAmountDecimals = 3
)

var (
	walletAmountPattern  = regexp.MustCompile(`^-?\d{1,11}(\.\d{1,3})?$`)
	walletServicePattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)
)

// ParseWalletAmount reads a decimal amount of dinars with at most three
// places. Fractions and exponents are refused: an amount is written the way a
// receipt writes it.
func ParseWalletAmount(raw string) (*big.Rat, error) {
	text := strings.TrimSpace(raw)
	if !walletAmountPattern.MatchString(text) {
		return nil, fmt.Errorf("invalid amount %q", raw)
	}
	value, ok := new(big.Rat).SetString(text)
	if !ok {
		return nil, fmt.Errorf("invalid amount %q", raw)
	}
	return value, nil
}

// FormatWalletAmount writes an amount with exactly three places, "-2.500".
func FormatWalletAmount(value *big.Rat) string {
	if value == nil {
		return "0.000"
	}
	return value.FloatString(walletAmountDecimals)
}

// NormalizeWalletAmount rewrites a stored decimal in the canonical form. A
// value that is not a decimal becomes "0.000".
func NormalizeWalletAmount(raw string) string {
	value, ok := new(big.Rat).SetString(strings.TrimSpace(raw))
	if !ok {
		return "0.000"
	}
	return FormatWalletAmount(value)
}

// WalletAmountDecimals counts the decimal places written in raw.
func WalletAmountDecimals(raw string) int {
	_, fraction, found := strings.Cut(strings.TrimSpace(raw), ".")
	if !found {
		return 0
	}
	return len(fraction)
}

// ValidWalletTopUpStatus reports whether status is a top-up status.
func ValidWalletTopUpStatus(status string) bool {
	switch status {
	case WalletTopUpPending, WalletTopUpPaid, WalletTopUpCanceled, WalletTopUpFailed, WalletTopUpExpired:
		return true
	}
	return false
}

// ValidWalletEntryKind reports whether kind is a ledger entry kind.
func ValidWalletEntryKind(kind string) bool {
	switch kind {
	case WalletEntryTopUp, WalletEntryCharge, WalletEntryRefund, WalletEntryAdjustment:
		return true
	}
	return false
}

// walletTopUpClosable reports whether a top-up may still be cancelled or
// failed: only while nobody has proved or refuted the payment.
func walletTopUpClosable(status string) bool {
	return status == WalletTopUpPending || status == WalletTopUpExpired
}

// preparedWalletPosting is a posting that passed validation, with its amount
// parsed.
type preparedWalletPosting struct {
	WalletPosting
	amount *big.Rat
}

func prepareWalletPosting(posting WalletPosting) (preparedWalletPosting, error) {
	posting.InstallationID = strings.TrimSpace(posting.InstallationID)
	posting.IdempotencyKey = strings.TrimSpace(posting.IdempotencyKey)
	posting.Kind = strings.ToLower(strings.TrimSpace(posting.Kind))
	posting.Service = strings.ToLower(strings.TrimSpace(posting.Service))
	posting.Reference = strings.TrimSpace(posting.Reference)
	posting.Description = strings.TrimSpace(posting.Description)
	posting.Actor = strings.TrimSpace(posting.Actor)
	if posting.InstallationID == "" || posting.IdempotencyKey == "" {
		return preparedWalletPosting{}, errors.New("a wallet posting needs an installation and an idempotency key")
	}
	if utf8.RuneCountInString(posting.IdempotencyKey) > maxWalletKeyRunes ||
		utf8.RuneCountInString(posting.Reference) > maxWalletKeyRunes {
		return preparedWalletPosting{}, fmt.Errorf("idempotency key and reference must be at most %d characters", maxWalletKeyRunes)
	}
	if utf8.RuneCountInString(posting.Description) > maxWalletTextRunes ||
		utf8.RuneCountInString(posting.Actor) > maxWalletTextRunes {
		return preparedWalletPosting{}, fmt.Errorf("description and actor must be at most %d characters", maxWalletTextRunes)
	}
	if !ValidWalletEntryKind(posting.Kind) {
		return preparedWalletPosting{}, fmt.Errorf("unknown wallet entry kind %q", posting.Kind)
	}
	amount, err := ParseWalletAmount(posting.Amount)
	if err != nil {
		return preparedWalletPosting{}, err
	}
	sign := amount.Sign()
	switch {
	case sign == 0:
		return preparedWalletPosting{}, errors.New("a wallet posting must move money")
	case (posting.Kind == WalletEntryTopUp || posting.Kind == WalletEntryRefund) && sign < 0:
		return preparedWalletPosting{}, fmt.Errorf("a %s credits the wallet; its amount must be positive", posting.Kind)
	case posting.Kind == WalletEntryCharge && sign > 0:
		return preparedWalletPosting{}, errors.New("a charge debits the wallet; its amount must be negative")
	}
	if posting.Kind == WalletEntryCharge || posting.Kind == WalletEntryRefund {
		if !walletServicePattern.MatchString(posting.Service) {
			return preparedWalletPosting{}, fmt.Errorf("a %s must name the service it is for", posting.Kind)
		}
	} else if posting.Service != "" && !walletServicePattern.MatchString(posting.Service) {
		return preparedWalletPosting{}, fmt.Errorf("invalid service %q", posting.Service)
	}
	// A charge is the company taking money for something it sold; it can never
	// be the thing that puts a shop in debt.
	if posting.Kind == WalletEntryCharge {
		posting.AllowOverdraft = false
	}
	posting.Amount = FormatWalletAmount(amount)
	return preparedWalletPosting{WalletPosting: posting, amount: amount}, nil
}

// nextWalletBalance applies a prepared posting to a balance, refusing an
// overdraft the posting does not allow.
func nextWalletBalance(balance *big.Rat, posting preparedWalletPosting) (*big.Rat, error) {
	next := new(big.Rat).Add(balance, posting.amount)
	if posting.amount.Sign() < 0 && next.Sign() < 0 && !posting.AllowOverdraft {
		return nil, &WalletBalanceError{
			Balance: FormatWalletAmount(balance),
			Amount:  FormatWalletAmount(new(big.Rat).Neg(posting.amount)),
		}
	}
	return next, nil
}

func newWalletEntry(posting preparedWalletPosting, balanceAfter *big.Rat, now time.Time) (WalletEntry, error) {
	id, err := NewInstallationID()
	if err != nil {
		return WalletEntry{}, err
	}
	return WalletEntry{
		ID:             id,
		InstallationID: posting.InstallationID,
		Kind:           posting.Kind,
		Service:        posting.Service,
		Amount:         posting.Amount,
		BalanceAfter:   FormatWalletAmount(balanceAfter),
		Reference:      posting.Reference,
		Description:    posting.Description,
		IdempotencyKey: posting.IdempotencyKey,
		Actor:          posting.Actor,
		TestMode:       posting.TestMode,
		CreatedAt:      now.UTC(),
	}, nil
}

// walletInvoiceAlphabet leaves out 0/O and 1/I so an invoice read aloud to
// support survives the phone call.
const walletInvoiceAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

// NewWalletInvoiceNo mints a gateway invoice number: "DFW-" and ten random
// characters, 32^10 of them, in the character set every gateway accepts.
func NewWalletInvoiceNo() (string, error) {
	var raw [10]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	var builder strings.Builder
	builder.WriteString("DFW-")
	for _, b := range raw {
		builder.WriteByte(walletInvoiceAlphabet[int(b)%len(walletInvoiceAlphabet)])
	}
	return builder.String(), nil
}

func prepareWalletTopUp(topUp WalletTopUp, now time.Time) (WalletTopUp, error) {
	topUp.InstallationID = strings.TrimSpace(topUp.InstallationID)
	topUp.IdempotencyKey = strings.TrimSpace(topUp.IdempotencyKey)
	topUp.Method = strings.TrimSpace(topUp.Method)
	topUp.RequestedBy = strings.TrimSpace(topUp.RequestedBy)
	if topUp.InstallationID == "" || topUp.IdempotencyKey == "" {
		return WalletTopUp{}, errors.New("a top-up needs an installation and an idempotency key")
	}
	if utf8.RuneCountInString(topUp.IdempotencyKey) > maxWalletKeyRunes {
		return WalletTopUp{}, fmt.Errorf("idempotency key must be at most %d characters", maxWalletKeyRunes)
	}
	if topUp.Method == "" {
		return WalletTopUp{}, errors.New("a top-up needs a payment method")
	}
	if utf8.RuneCountInString(topUp.RequestedBy) > maxWalletKeyRunes {
		topUp.RequestedBy = string([]rune(topUp.RequestedBy)[:maxWalletKeyRunes])
	}
	amount, err := ParseWalletAmount(topUp.Amount)
	if err != nil {
		return WalletTopUp{}, err
	}
	if amount.Sign() <= 0 {
		return WalletTopUp{}, errors.New("a top-up amount must be positive")
	}
	id, err := NewInstallationID()
	if err != nil {
		return WalletTopUp{}, err
	}
	invoiceNo, err := NewWalletInvoiceNo()
	if err != nil {
		return WalletTopUp{}, err
	}
	topUp.ID = id
	topUp.InvoiceNo = invoiceNo
	topUp.Amount = FormatWalletAmount(amount)
	topUp.Status = WalletTopUpPending
	topUp.ProviderTransactionID = ""
	topUp.CheckoutURL = ""
	topUp.ErrorCode = ""
	topUp.ErrorDetail = ""
	topUp.EntryID = ""
	topUp.ConfirmedBy = ""
	topUp.ShopName = ""
	topUp.CreatedAt = now.UTC()
	topUp.UpdatedAt = topUp.CreatedAt
	topUp.PaidAt = nil
	return topUp, nil
}

// walletTopUpCredit is the ledger posting a paid top-up makes. Its key is
// derived from the top-up, so however many paths prove the same payment the
// wallet is credited once.
func walletTopUpCredit(topUp WalletTopUp, settlement WalletTopUpSettlement) WalletPosting {
	description := strings.TrimSpace(settlement.Description)
	if description == "" {
		description = "top-up " + topUp.InvoiceNo
	}
	return WalletPosting{
		InstallationID: topUp.InstallationID,
		Kind:           WalletEntryTopUp,
		Amount:         topUp.Amount,
		Reference:      topUp.ID,
		Description:    description,
		IdempotencyKey: "topup:" + topUp.ID,
		Actor:          strings.TrimSpace(settlement.ConfirmedBy),
		TestMode:       topUp.TestMode,
	}
}

func validateWalletTopUpClosure(status string) error {
	switch status {
	case WalletTopUpCanceled, WalletTopUpFailed:
		return nil
	}
	return fmt.Errorf("a top-up can only be closed as canceled or failed, got %q", status)
}

func normalizedWalletListLimit(limit int) int {
	if limit <= 0 {
		return defaultWalletListLimit
	}
	return min(limit, maxWalletListLimit)
}

func sortWalletEntriesNewestFirst(entries []WalletEntry) {
	sort.Slice(entries, func(i, j int) bool {
		if !entries[i].CreatedAt.Equal(entries[j].CreatedAt) {
			return entries[i].CreatedAt.After(entries[j].CreatedAt)
		}
		return entries[i].ID > entries[j].ID
	})
}

func sortWalletTopUpsNewestFirst(topUps []WalletTopUp) {
	sort.Slice(topUps, func(i, j int) bool {
		if !topUps[i].CreatedAt.Equal(topUps[j].CreatedAt) {
			return topUps[i].CreatedAt.After(topUps[j].CreatedAt)
		}
		return topUps[i].ID > topUps[j].ID
	})
}

// olderThan reports whether (at, id) sorts after the cursor in a newest-first
// listing — the same comparison the Postgres queries make on the tuple.
func olderThan(at time.Time, id string, cursorAt time.Time, cursorID string) bool {
	if !at.Equal(cursorAt) {
		return at.Before(cursorAt)
	}
	return id < cursorID
}

// --- FileStore ---
//
// The file store keeps no balance column: it sums the shop's entries under the
// lock, which is exact and plenty fast for the development and test stores it
// backs.

func (s *FileStore) walletBalanceLocked(installationID string) (*big.Rat, *time.Time) {
	balance := new(big.Rat)
	var updatedAt *time.Time
	for _, entry := range s.data.WalletEntries {
		if entry.InstallationID != installationID {
			continue
		}
		if amount, ok := new(big.Rat).SetString(entry.Amount); ok {
			balance.Add(balance, amount)
		}
		if updatedAt == nil || entry.CreatedAt.After(*updatedAt) {
			at := entry.CreatedAt
			updatedAt = &at
		}
	}
	return balance, updatedAt
}

func (s *FileStore) GetWallet(_ context.Context, installationID string) (Wallet, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	installationID = strings.TrimSpace(installationID)
	balance, updatedAt := s.walletBalanceLocked(installationID)
	return Wallet{InstallationID: installationID, Balance: FormatWalletAmount(balance), UpdatedAt: updatedAt}, nil
}

func (s *FileStore) ListWallets(_ context.Context, limit int) ([]Wallet, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	seen := map[string]bool{}
	wallets := []Wallet{}
	for _, entry := range s.data.WalletEntries {
		if seen[entry.InstallationID] {
			continue
		}
		seen[entry.InstallationID] = true
		balance, updatedAt := s.walletBalanceLocked(entry.InstallationID)
		wallets = append(wallets, Wallet{
			InstallationID: entry.InstallationID,
			ShopName:       s.data.Installations[entry.InstallationID].ShopName,
			Balance:        FormatWalletAmount(balance),
			UpdatedAt:      updatedAt,
		})
	}
	sortWalletsLargestFirst(wallets)
	if limit = normalizedWalletListLimit(limit); len(wallets) > limit {
		wallets = wallets[:limit]
	}
	return wallets, nil
}

func sortWalletsLargestFirst(wallets []Wallet) {
	sort.Slice(wallets, func(i, j int) bool {
		left, _ := new(big.Rat).SetString(wallets[i].Balance)
		right, _ := new(big.Rat).SetString(wallets[j].Balance)
		if left != nil && right != nil {
			if cmp := left.Cmp(right); cmp != 0 {
				return cmp > 0
			}
		}
		return wallets[i].InstallationID < wallets[j].InstallationID
	})
}

func (s *FileStore) findWalletEntryByKeyLocked(installationID, key string) (WalletEntry, bool) {
	for _, entry := range s.data.WalletEntries {
		if entry.InstallationID == installationID && entry.IdempotencyKey == key {
			return entry, true
		}
	}
	return WalletEntry{}, false
}

// postWalletEntryLocked records a prepared posting. The caller holds the
// write lock and saves.
func (s *FileStore) postWalletEntryLocked(posting preparedWalletPosting) (WalletEntry, bool, error) {
	if _, ok := s.data.Installations[posting.InstallationID]; !ok {
		return WalletEntry{}, false, ErrNotFound
	}
	if existing, ok := s.findWalletEntryByKeyLocked(posting.InstallationID, posting.IdempotencyKey); ok {
		return existing, false, nil
	}
	balance, _ := s.walletBalanceLocked(posting.InstallationID)
	next, err := nextWalletBalance(balance, posting)
	if err != nil {
		return WalletEntry{}, false, err
	}
	entry, err := newWalletEntry(posting, next, s.clock.Now())
	if err != nil {
		return WalletEntry{}, false, err
	}
	if s.data.WalletEntries == nil {
		s.data.WalletEntries = map[string]WalletEntry{}
	}
	s.data.WalletEntries[entry.ID] = entry
	return entry, true, nil
}

func (s *FileStore) PostWalletEntry(_ context.Context, posting WalletPosting) (WalletEntry, bool, error) {
	prepared, err := prepareWalletPosting(posting)
	if err != nil {
		return WalletEntry{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	entry, created, err := s.postWalletEntryLocked(prepared)
	if err != nil || !created {
		return entry, created, err
	}
	if err := s.saveLocked(); err != nil {
		delete(s.data.WalletEntries, entry.ID)
		return WalletEntry{}, false, err
	}
	return entry, true, nil
}

func (s *FileStore) ListWalletEntries(_ context.Context, filter WalletEntryFilter) ([]WalletEntry, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	installationID := strings.TrimSpace(filter.InstallationID)
	kind := strings.TrimSpace(filter.Kind)
	var cursor *WalletEntry
	if beforeID := strings.TrimSpace(filter.BeforeID); beforeID != "" {
		entry, ok := s.data.WalletEntries[beforeID]
		if !ok {
			return nil, ErrWalletEntryNotFound
		}
		cursor = &entry
	}
	entries := []WalletEntry{}
	for _, entry := range s.data.WalletEntries {
		if installationID != "" && entry.InstallationID != installationID {
			continue
		}
		if kind != "" && entry.Kind != kind {
			continue
		}
		if cursor != nil && !olderThan(entry.CreatedAt, entry.ID, cursor.CreatedAt, cursor.ID) {
			continue
		}
		entry.ShopName = s.data.Installations[entry.InstallationID].ShopName
		entries = append(entries, entry)
	}
	sortWalletEntriesNewestFirst(entries)
	if limit := normalizedWalletListLimit(filter.Limit); len(entries) > limit {
		entries = entries[:limit]
	}
	return entries, nil
}

func (s *FileStore) findWalletTopUpByKeyLocked(installationID, key string) (WalletTopUp, bool) {
	for _, topUp := range s.data.WalletTopUps {
		if topUp.InstallationID == installationID && topUp.IdempotencyKey == key {
			return topUp, true
		}
	}
	return WalletTopUp{}, false
}

func (s *FileStore) walletInvoiceTakenLocked(invoiceNo string) bool {
	for _, topUp := range s.data.WalletTopUps {
		if topUp.InvoiceNo == invoiceNo {
			return true
		}
	}
	return false
}

func (s *FileStore) BeginWalletTopUp(_ context.Context, topUp WalletTopUp) (WalletTopUp, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	prepared, err := prepareWalletTopUp(topUp, s.clock.Now())
	if err != nil {
		return WalletTopUp{}, false, err
	}
	if _, ok := s.data.Installations[prepared.InstallationID]; !ok {
		return WalletTopUp{}, false, ErrNotFound
	}
	if existing, ok := s.findWalletTopUpByKeyLocked(prepared.InstallationID, prepared.IdempotencyKey); ok {
		return existing, false, nil
	}
	for s.walletInvoiceTakenLocked(prepared.InvoiceNo) {
		if prepared.InvoiceNo, err = NewWalletInvoiceNo(); err != nil {
			return WalletTopUp{}, false, err
		}
	}
	if s.data.WalletTopUps == nil {
		s.data.WalletTopUps = map[string]WalletTopUp{}
	}
	s.data.WalletTopUps[prepared.ID] = prepared
	if err := s.saveLocked(); err != nil {
		delete(s.data.WalletTopUps, prepared.ID)
		return WalletTopUp{}, false, err
	}
	return prepared, true, nil
}

// updateWalletTopUpLocked stores a changed top-up and rolls it back if the
// save fails.
func (s *FileStore) updateWalletTopUpLocked(before, after WalletTopUp) (WalletTopUp, error) {
	s.data.WalletTopUps[after.ID] = after
	if err := s.saveLocked(); err != nil {
		s.data.WalletTopUps[before.ID] = before
		return WalletTopUp{}, err
	}
	return after, nil
}

func (s *FileStore) AttachWalletTopUpCheckout(_ context.Context, id, checkoutURL string) (WalletTopUp, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.WalletTopUps[id]
	if !ok {
		return WalletTopUp{}, ErrWalletTopUpNotFound
	}
	if existing.Status != WalletTopUpPending || existing.CheckoutURL != "" {
		return existing, nil
	}
	updated := existing
	updated.CheckoutURL = strings.TrimSpace(checkoutURL)
	updated.UpdatedAt = s.clock.Now().UTC()
	return s.updateWalletTopUpLocked(existing, updated)
}

func (s *FileStore) GetWalletTopUp(_ context.Context, id string) (WalletTopUp, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	topUp, ok := s.data.WalletTopUps[strings.TrimSpace(id)]
	if !ok {
		return WalletTopUp{}, ErrWalletTopUpNotFound
	}
	topUp.ShopName = s.data.Installations[topUp.InstallationID].ShopName
	return topUp, nil
}

func (s *FileStore) FindWalletTopUpByInvoice(_ context.Context, invoiceNo string) (WalletTopUp, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	invoiceNo = strings.TrimSpace(invoiceNo)
	for _, topUp := range s.data.WalletTopUps {
		if topUp.InvoiceNo == invoiceNo {
			topUp.ShopName = s.data.Installations[topUp.InstallationID].ShopName
			return topUp, nil
		}
	}
	return WalletTopUp{}, ErrWalletTopUpNotFound
}

func (s *FileStore) ListWalletTopUps(_ context.Context, filter WalletTopUpFilter) ([]WalletTopUp, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	installationID := strings.TrimSpace(filter.InstallationID)
	status := strings.TrimSpace(filter.Status)
	var cursor *WalletTopUp
	if beforeID := strings.TrimSpace(filter.BeforeID); beforeID != "" {
		topUp, ok := s.data.WalletTopUps[beforeID]
		if !ok {
			return nil, ErrWalletTopUpNotFound
		}
		cursor = &topUp
	}
	topUps := []WalletTopUp{}
	for _, topUp := range s.data.WalletTopUps {
		if installationID != "" && topUp.InstallationID != installationID {
			continue
		}
		if status != "" && topUp.Status != status {
			continue
		}
		if cursor != nil && !olderThan(topUp.CreatedAt, topUp.ID, cursor.CreatedAt, cursor.ID) {
			continue
		}
		topUp.ShopName = s.data.Installations[topUp.InstallationID].ShopName
		topUps = append(topUps, topUp)
	}
	sortWalletTopUpsNewestFirst(topUps)
	if limit := normalizedWalletListLimit(filter.Limit); len(topUps) > limit {
		topUps = topUps[:limit]
	}
	return topUps, nil
}

func (s *FileStore) SettleWalletTopUp(
	_ context.Context,
	id string,
	settlement WalletTopUpSettlement,
) (WalletTopUp, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.WalletTopUps[id]
	if !ok {
		return WalletTopUp{}, false, ErrWalletTopUpNotFound
	}
	if existing.Status == WalletTopUpPaid {
		return existing, false, nil
	}
	posting, err := prepareWalletPosting(walletTopUpCredit(existing, settlement))
	if err != nil {
		return WalletTopUp{}, false, err
	}
	entry, created, err := s.postWalletEntryLocked(posting)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	now := s.clock.Now().UTC()
	updated := existing
	updated.Status = WalletTopUpPaid
	updated.ProviderTransactionID = strings.TrimSpace(settlement.ProviderTransactionID)
	updated.ConfirmedBy = strings.TrimSpace(settlement.ConfirmedBy)
	updated.EntryID = entry.ID
	updated.ErrorCode = ""
	updated.ErrorDetail = ""
	updated.PaidAt = &now
	updated.UpdatedAt = now
	s.data.WalletTopUps[id] = updated
	if err := s.saveLocked(); err != nil {
		s.data.WalletTopUps[id] = existing
		if created {
			delete(s.data.WalletEntries, entry.ID)
		}
		return WalletTopUp{}, false, err
	}
	return updated, true, nil
}

func (s *FileStore) CloseWalletTopUp(
	_ context.Context,
	id, status, code, detail string,
) (WalletTopUp, bool, error) {
	if err := validateWalletTopUpClosure(status); err != nil {
		return WalletTopUp{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.WalletTopUps[id]
	if !ok {
		return WalletTopUp{}, false, ErrWalletTopUpNotFound
	}
	if !walletTopUpClosable(existing.Status) {
		return existing, false, nil
	}
	updated := existing
	updated.Status = status
	updated.ErrorCode = strings.TrimSpace(code)
	updated.ErrorDetail = strings.TrimSpace(detail)
	updated.UpdatedAt = s.clock.Now().UTC()
	stored, err := s.updateWalletTopUpLocked(existing, updated)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	return stored, true, nil
}

func (s *FileStore) ExpireWalletTopUps(_ context.Context, createdBefore time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := s.clock.Now().UTC()
	previous := map[string]WalletTopUp{}
	for id, topUp := range s.data.WalletTopUps {
		if topUp.Status != WalletTopUpPending || !topUp.CreatedAt.Before(createdBefore) {
			continue
		}
		previous[id] = topUp
		topUp.Status = WalletTopUpExpired
		topUp.UpdatedAt = now
		s.data.WalletTopUps[id] = topUp
	}
	if len(previous) == 0 {
		return 0, nil
	}
	if err := s.saveLocked(); err != nil {
		for id, topUp := range previous {
			s.data.WalletTopUps[id] = topUp
		}
		return 0, err
	}
	return len(previous), nil
}

// --- CachedInstallationStore forwarding ---
//
// Wallets never touch installation rows, so nothing here drops a cached
// installation.

func (s *CachedInstallationStore) walletStore() (WalletStore, error) {
	store, ok := s.store.(WalletStore)
	if !ok {
		return nil, errWalletUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) GetWallet(ctx context.Context, installationID string) (Wallet, error) {
	store, err := s.walletStore()
	if err != nil {
		return Wallet{}, err
	}
	return store.GetWallet(ctx, installationID)
}

func (s *CachedInstallationStore) ListWallets(ctx context.Context, limit int) ([]Wallet, error) {
	store, err := s.walletStore()
	if err != nil {
		return nil, err
	}
	return store.ListWallets(ctx, limit)
}

func (s *CachedInstallationStore) PostWalletEntry(ctx context.Context, posting WalletPosting) (WalletEntry, bool, error) {
	store, err := s.walletStore()
	if err != nil {
		return WalletEntry{}, false, err
	}
	return store.PostWalletEntry(ctx, posting)
}

func (s *CachedInstallationStore) ListWalletEntries(ctx context.Context, filter WalletEntryFilter) ([]WalletEntry, error) {
	store, err := s.walletStore()
	if err != nil {
		return nil, err
	}
	return store.ListWalletEntries(ctx, filter)
}

func (s *CachedInstallationStore) BeginWalletTopUp(ctx context.Context, topUp WalletTopUp) (WalletTopUp, bool, error) {
	store, err := s.walletStore()
	if err != nil {
		return WalletTopUp{}, false, err
	}
	return store.BeginWalletTopUp(ctx, topUp)
}

func (s *CachedInstallationStore) AttachWalletTopUpCheckout(ctx context.Context, id, checkoutURL string) (WalletTopUp, error) {
	store, err := s.walletStore()
	if err != nil {
		return WalletTopUp{}, err
	}
	return store.AttachWalletTopUpCheckout(ctx, id, checkoutURL)
}

func (s *CachedInstallationStore) GetWalletTopUp(ctx context.Context, id string) (WalletTopUp, error) {
	store, err := s.walletStore()
	if err != nil {
		return WalletTopUp{}, err
	}
	return store.GetWalletTopUp(ctx, id)
}

func (s *CachedInstallationStore) FindWalletTopUpByInvoice(ctx context.Context, invoiceNo string) (WalletTopUp, error) {
	store, err := s.walletStore()
	if err != nil {
		return WalletTopUp{}, err
	}
	return store.FindWalletTopUpByInvoice(ctx, invoiceNo)
}

func (s *CachedInstallationStore) ListWalletTopUps(ctx context.Context, filter WalletTopUpFilter) ([]WalletTopUp, error) {
	store, err := s.walletStore()
	if err != nil {
		return nil, err
	}
	return store.ListWalletTopUps(ctx, filter)
}

func (s *CachedInstallationStore) SettleWalletTopUp(
	ctx context.Context,
	id string,
	settlement WalletTopUpSettlement,
) (WalletTopUp, bool, error) {
	store, err := s.walletStore()
	if err != nil {
		return WalletTopUp{}, false, err
	}
	return store.SettleWalletTopUp(ctx, id, settlement)
}

func (s *CachedInstallationStore) CloseWalletTopUp(
	ctx context.Context,
	id, status, code, detail string,
) (WalletTopUp, bool, error) {
	store, err := s.walletStore()
	if err != nil {
		return WalletTopUp{}, false, err
	}
	return store.CloseWalletTopUp(ctx, id, status, code, detail)
}

func (s *CachedInstallationStore) ExpireWalletTopUps(ctx context.Context, createdBefore time.Time) (int, error) {
	store, err := s.walletStore()
	if err != nil {
		return 0, err
	}
	return store.ExpireWalletTopUps(ctx, createdBefore)
}
