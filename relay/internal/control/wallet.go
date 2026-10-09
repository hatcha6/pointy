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
//
// The money sits in accounts. The main wallet is what top-ups credit and the
// subscriptions draw on; the SMS balance is money the shop set aside for text
// messages, which each message draws on; the voucher balance is money set aside
// for the company's cards, which each card the till sells draws on. Moving
// money from one to another is the shop's own transfer, never a sale.

// Accounts of a shop's wallet.
const (
	WalletAccountMain     = "main"
	WalletAccountSMS      = "sms"
	WalletAccountVouchers = "vouchers"
)

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
	// WalletEntryTransfer moves the shop's own money between its accounts: one
	// entry out of one account and one into the other.
	WalletEntryTransfer = "transfer"
)

// Services a charge or refund is for. The list is open — a new service needs
// only a new name — but these are the ones the company sells today.
const (
	WalletServiceSubscription = "subscription"
	WalletServiceSMS          = "sms"
	WalletServiceAI           = "ai"
	WalletServiceVouchers     = "vouchers"
	// WalletServiceRemoteAccess is the remote-access plan, paid from the wallet.
	WalletServiceRemoteAccess = "remote_access"
)

// Plans a shop pays for from its main wallet. Each runs on its own clock:
// paying for remote access never moves the assistant's end date. A plan's
// name is also the service its charge is for.
const (
	WalletPlanRemoteAccess = WalletServiceRemoteAccess
	WalletPlanAI           = WalletServiceAI
)

// walletAccountTitles name the accounts on the shop's Arabic statement.
var walletAccountTitles = map[string]string{
	WalletAccountMain:     "المحفظة",
	WalletAccountSMS:      "رصيد الرسائل",
	WalletAccountVouchers: "رصيد الكروت",
}

// walletPlanTitles name the plans on the shop's Arabic statement.
var walletPlanTitles = map[string]string{
	WalletPlanRemoteAccess: "الوصول عن بُعد",
	WalletPlanAI:           "المساعد الذكي",
}

// Top-up statuses. A top-up is born pending, before the gateway is asked to
// start the payment, and is paid exactly once.
const (
	WalletTopUpPending  = "pending"
	WalletTopUpPaid     = "paid"
	WalletTopUpCanceled = "canceled"
	WalletTopUpFailed   = "failed"
	// WalletTopUpExpired is a payment nobody finished in time. It is not
	// final: a payment the gateway proves later still credits the wallet,
	// because the payer's money has left their account either way.
	WalletTopUpExpired = "expired"
	// WalletTopUpReview is a bank transfer the shop says it made, waiting for
	// the company to find the money on its own statement. Only an operator
	// moves it on: to paid, or to rejected with the reason the shop is shown.
	WalletTopUpReview   = "review"
	WalletTopUpRejected = "rejected"
)

// Top-up methods name the gateway and the way the payer pays: "dafa_sadad" is
// Sadad through Dafa. The relay's method table maps each to its provider; the
// store only keeps the name.
const (
	WalletTopUpMethodDafaSadad      = "dafa_sadad"
	WalletTopUpMethodDafaEdfali     = "dafa_edfali"
	WalletTopUpMethodDafaMobiCash   = "dafa_mobicash"
	WalletTopUpMethodDafaMoamalat   = "dafa_moamalat"
	WalletTopUpMethodDafaYussorPay  = "dafa_yussor_pay"
	WalletTopUpMethodDafaMasrafiPay = "dafa_masrafi_pay"
	WalletTopUpMethodDafaSaharaPay  = "dafa_sahara_pay"
	// WalletTopUpMethodPlutuLocalBankCards is Plutu's hosted checkout, which
	// Dafa replaced. Old top-ups keep the name.
	WalletTopUpMethodPlutuLocalBankCards = "plutu_localbankcards"
	// WalletTopUpMethodBankTransfer is a transfer to the company's own bank
	// account (LYPay to its IBAN, or OnePay to its bank and account number),
	// proven by an operator who sees it land, never by the receipt.
	WalletTopUpMethodBankTransfer = "bank_transfer"
)

// maxWalletPayerHintRunes bounds the masked payer shown beside a top-up.
const maxWalletPayerHintRunes = 32

var (
	ErrWalletEntryNotFound = errors.New("wallet entry not found")
	ErrWalletTopUpNotFound = errors.New("wallet top-up not found")
	// ErrWalletInsufficientBalance is returned (as *WalletBalanceError) when
	// a debit would take a balance below zero.
	ErrWalletInsufficientBalance = errors.New("wallet balance is insufficient")
	// ErrWalletPlanIncluded refuses to sell a plan the shop's subscription
	// already includes with no end date: the money would buy nothing.
	ErrWalletPlanIncluded = errors.New("the plan is already included in the subscription")
	errWalletUnsupported  = errors.New("wallets are not supported by the underlying store")
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

// Wallet is one shop's balance in one account.
type Wallet struct {
	InstallationID string `json:"installation_id"`
	Account        string `json:"account"`
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
	// Account is where the money moved: the main wallet or the SMS balance.
	Account string `json:"account"`
	Kind    string `json:"kind"`
	Service string `json:"service,omitempty"`
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
	// Account defaults to the main wallet.
	Account string
	Kind    string
	Service string
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
	// Charges never may — save the settlement of an SMS that went out longer
	// than it was held for, which the SMS ledger sets on the prepared posting
	// itself (smsFinishPosting), out of reach of any caller.
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
	// InvoiceNo is the company's own reference, unique across every shop. It
	// is what the owner reads to support, so it is short and readable.
	InvoiceNo string `json:"invoice_no"`
	// ProviderTransactionID is the gateway's id for the payment — Dafa's
	// payment id, known from the moment the payment is started. It is what the
	// relay confirms and reads back, and what support finds on Dafa's
	// dashboard.
	ProviderTransactionID string `json:"provider_transaction_id,omitempty"`
	// CheckoutURL is the gateway's page a bank-card payer pays on; empty for
	// the methods confirmed with a code.
	CheckoutURL    string `json:"checkout_url,omitempty"`
	IdempotencyKey string `json:"idempotency_key"`
	// RequestedBy is the shop user who started it, as the shop named them.
	RequestedBy string `json:"requested_by,omitempty"`
	// PayerHint is the payer's phone or card, masked ("091•••678"): enough to
	// recognise, never enough to reuse. The full number goes to the gateway
	// and nowhere else.
	PayerHint string `json:"payer_hint,omitempty"`
	// OTPAttempts counts the codes sent to confirm it, capped so nobody can
	// guess a code for someone else's wallet.
	OTPAttempts int    `json:"otp_attempts,omitempty"`
	TestMode    bool   `json:"test_mode"`
	ErrorCode   string `json:"error_code,omitempty"`
	ErrorDetail string `json:"error_detail,omitempty"`
	// EntryID is the ledger entry a paid top-up credited.
	EntryID string `json:"entry_id,omitempty"`
	// ConfirmedBy is what proved the payment: "dafa" for the gateway's own
	// answer to the relay, or "operator:<name>" for a hand reconciliation.
	ConfirmedBy string `json:"confirmed_by,omitempty"`
	// Transfer is what the payer told us about a bank transfer; nil for every
	// gateway method.
	Transfer  *WalletBankTransfer `json:"transfer,omitempty"`
	CreatedAt time.Time           `json:"created_at"`
	UpdatedAt time.Time           `json:"updated_at"`
	PaidAt    *time.Time          `json:"paid_at,omitempty"`
}

// WalletTopUpSettlement is the proof a top-up was paid.
type WalletTopUpSettlement struct {
	// ProviderTransactionID replaces the stored gateway id when it is set; an
	// empty one keeps the id the top-up already has.
	ProviderTransactionID string
	ConfirmedBy           string
	Description           string
	// Amount, when set, is what actually arrived: an operator crediting a
	// bank transfer for less (or more) than the shop declared. The declared
	// amount is kept on the transfer.
	Amount string
}

// WalletEntryFilter narrows a ledger listing. BeforeID pages: entries older
// than that one. An empty Account lists every account.
type WalletEntryFilter struct {
	InstallationID string
	Account        string
	Kind           string
	Limit          int
	BeforeID       string
}

// WalletTransfer moves the shop's own money from one of its accounts to
// another — from the main wallet into the SMS balance, say. Nothing is sold,
// so it is never a charge, and it can never overdraw.
type WalletTransfer struct {
	InstallationID string
	From           string
	To             string
	// Amount is a positive decimal of dinars with at most three places.
	Amount string
	// IdempotencyKey makes a retried transfer return the first one.
	IdempotencyKey string
	Actor          string
}

// WalletTransferResult is what a transfer recorded: the entry out of one
// account and the entry into the other.
type WalletTransferResult struct {
	Out WalletEntry `json:"out"`
	In  WalletEntry `json:"in"`
}

// WalletPlanPurchase pays for a plan from the main wallet: the charge and the
// longer paid-through date are one step.
type WalletPlanPurchase struct {
	InstallationID string
	Plan           string
	// Amount is the positive price of the whole purchase.
	Amount string
	// Days is how long it buys. They are added after whatever the shop
	// already has, so renewing early loses nothing.
	Days           int
	IdempotencyKey string
	// RequestedBy is the shop user who paid, as the shop named them.
	RequestedBy string
}

// WalletPlanPurchaseResult is a purchase as recorded. From and Until bound the
// period it paid for; both are zero when the purchase was a replay.
type WalletPlanPurchaseResult struct {
	Entry        WalletEntry  `json:"entry"`
	Installation Installation `json:"installation"`
	From         time.Time    `json:"from"`
	Until        time.Time    `json:"until"`
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
	// GetWallet returns the main wallet's balance; a shop that never had an
	// entry has 0.
	GetWallet(ctx context.Context, installationID string) (Wallet, error)
	// GetWalletAccount returns one account's balance.
	GetWalletAccount(ctx context.Context, installationID, account string) (Wallet, error)
	// ListWallets is the operator's view of one account, largest balance first.
	ListWallets(ctx context.Context, account string, limit int) ([]Wallet, error)
	// PostWalletEntry records a movement. A repeated idempotency key returns
	// the first entry with created=false. A debit that would take the balance
	// below zero is refused with *WalletBalanceError unless AllowOverdraft.
	PostWalletEntry(ctx context.Context, posting WalletPosting) (WalletEntry, bool, error)
	ListWalletEntries(ctx context.Context, filter WalletEntryFilter) ([]WalletEntry, error)
	// TransferWalletFunds moves money between two of a shop's accounts in one
	// step: both entries or neither. A repeated idempotency key returns the
	// first transfer with created=false; a transfer the source cannot cover is
	// refused with *WalletBalanceError.
	TransferWalletFunds(ctx context.Context, transfer WalletTransfer) (WalletTransferResult, bool, error)
	// PurchaseWalletPlan charges the main wallet for a plan and moves the
	// plan's paid-through date in one step, with an audit event. A repeated
	// idempotency key returns the first purchase with created=false. A plan
	// the subscription includes with no end date is refused with
	// ErrWalletPlanIncluded, one the wallet cannot cover with
	// *WalletBalanceError.
	PurchaseWalletPlan(ctx context.Context, purchase WalletPlanPurchase) (WalletPlanPurchaseResult, bool, error)
	// BeginWalletTopUp stores a pending top-up with a fresh invoice number. A
	// repeated idempotency key returns the first with created=false.
	BeginWalletTopUp(ctx context.Context, topUp WalletTopUp) (WalletTopUp, bool, error)
	// AttachWalletTopUpPayment records the gateway's payment — its id and, for
	// bank cards, the page to pay on — on a pending top-up that has none yet.
	// Anything else is returned untouched.
	AttachWalletTopUpPayment(ctx context.Context, id, providerTransactionID, checkoutURL string) (WalletTopUp, error)
	// RecordWalletTopUpOTPAttempt counts one code sent to confirm a pending
	// top-up, unless it already had limit of them (or is no longer pending):
	// then it is returned untouched with recorded=false.
	RecordWalletTopUpOTPAttempt(ctx context.Context, id string, limit int) (WalletTopUp, bool, error)
	GetWalletTopUp(ctx context.Context, id string) (WalletTopUp, error)
	FindWalletTopUpByInvoice(ctx context.Context, invoiceNo string) (WalletTopUp, error)
	ListWalletTopUps(ctx context.Context, filter WalletTopUpFilter) ([]WalletTopUp, error)
	// ListOpenWalletTopUps returns the pending and expired top-ups created at
	// or after createdAfter that have a gateway payment — the ones a payment
	// may still land on — newest first.
	ListOpenWalletTopUps(ctx context.Context, createdAfter time.Time, limit int) ([]WalletTopUp, error)
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
	// walletAmountDecimals is the dinar's three places (the dirham), which
	// Dafa takes as well.
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

// SumWalletAmounts adds decimal amounts exactly, skipping anything that is not
// one, and writes the total with three places.
func SumWalletAmounts(amounts []string) string {
	total := new(big.Rat)
	for _, amount := range amounts {
		if value, ok := new(big.Rat).SetString(strings.TrimSpace(amount)); ok {
			total.Add(total, value)
		}
	}
	return FormatWalletAmount(total)
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
	case WalletTopUpPending, WalletTopUpPaid, WalletTopUpCanceled, WalletTopUpFailed, WalletTopUpExpired,
		WalletTopUpReview, WalletTopUpRejected:
		return true
	}
	return false
}

// ValidWalletEntryKind reports whether kind is a ledger entry kind.
func ValidWalletEntryKind(kind string) bool {
	switch kind {
	case WalletEntryTopUp, WalletEntryCharge, WalletEntryRefund, WalletEntryAdjustment, WalletEntryTransfer:
		return true
	}
	return false
}

// ValidWalletAccount reports whether account is one of a shop's accounts.
func ValidWalletAccount(account string) bool {
	_, ok := walletAccountTitles[account]
	return ok
}

// NormalizeWalletAccount reads an account name; empty means the main wallet,
// which is also what every entry written before accounts existed belongs to.
func NormalizeWalletAccount(account string) string {
	account = strings.ToLower(strings.TrimSpace(account))
	if account == "" {
		return WalletAccountMain
	}
	return account
}

// ValidWalletPlan reports whether plan is one a shop can pay for.
func ValidWalletPlan(plan string) bool {
	_, ok := walletPlanTitles[plan]
	return ok
}

// WalletPlanCoverage is how long one plan's service runs for a shop.
type WalletPlanCoverage struct {
	Active bool
	// Until is when it stops, nil when it is not active or never ends.
	Until *time.Time
	// Indefinite is a subscription that includes the plan with no end date.
	Indefinite bool
}

// PlanCoverage reads a plan's service off the installation: the operator's
// subscription (the feature flag, active, until its end date) and the period
// the shop paid for from its wallet, whichever runs longer.
func (i Installation) PlanCoverage(plan string, now time.Time) WalletPlanCoverage {
	var flag bool
	var paidUntil *time.Time
	switch plan {
	case WalletPlanRemoteAccess:
		flag, paidUntil = i.RelayEnabled, i.RemoteAccessPaidUntil
	case WalletPlanAI:
		flag, paidUntil = i.AIEnabled, i.AIPaidUntil
	default:
		return WalletPlanCoverage{}
	}
	var coverage WalletPlanCoverage
	if flag && i.SubscriptionActive {
		if i.SubscriptionEndsAt == nil {
			return WalletPlanCoverage{Active: true, Indefinite: true}
		}
		if now.Before(*i.SubscriptionEndsAt) {
			until := i.SubscriptionEndsAt.UTC()
			coverage = WalletPlanCoverage{Active: true, Until: &until}
		}
	}
	if paidUntil != nil && now.Before(*paidUntil) && (coverage.Until == nil || paidUntil.After(*coverage.Until)) {
		until := paidUntil.UTC()
		coverage = WalletPlanCoverage{Active: true, Until: &until}
	}
	return coverage
}

// walletPlanPeriod is the period a purchase pays for: it starts where the
// shop's current coverage ends, or now.
func walletPlanPeriod(installation Installation, purchase WalletPlanPurchase, now time.Time) (time.Time, time.Time, error) {
	coverage := installation.PlanCoverage(purchase.Plan, now)
	if coverage.Indefinite {
		return time.Time{}, time.Time{}, ErrWalletPlanIncluded
	}
	from := now.UTC()
	if coverage.Until != nil && coverage.Until.After(from) {
		from = *coverage.Until
	}
	return from, from.AddDate(0, 0, purchase.Days), nil
}

// setPlanPaidUntil moves the plan's paid-through date on the installation.
func setPlanPaidUntil(installation Installation, plan string, until time.Time, now time.Time) Installation {
	until = until.UTC()
	switch plan {
	case WalletPlanRemoteAccess:
		installation.RemoteAccessPaidUntil = &until
	case WalletPlanAI:
		installation.AIPaidUntil = &until
	}
	installation.UpdatedAt = now.UTC()
	return installation
}

func prepareWalletPlanPurchase(purchase WalletPlanPurchase) (WalletPlanPurchase, *big.Rat, error) {
	purchase.InstallationID = strings.TrimSpace(purchase.InstallationID)
	purchase.Plan = strings.ToLower(strings.TrimSpace(purchase.Plan))
	purchase.IdempotencyKey = strings.TrimSpace(purchase.IdempotencyKey)
	purchase.RequestedBy = strings.TrimSpace(purchase.RequestedBy)
	if purchase.InstallationID == "" || purchase.IdempotencyKey == "" {
		return WalletPlanPurchase{}, nil, errors.New("a plan purchase needs an installation and an idempotency key")
	}
	if !ValidWalletPlan(purchase.Plan) {
		return WalletPlanPurchase{}, nil, fmt.Errorf("unknown plan %q", purchase.Plan)
	}
	if purchase.Days <= 0 {
		return WalletPlanPurchase{}, nil, errors.New("a plan purchase must buy at least one day")
	}
	amount, err := ParseWalletAmount(purchase.Amount)
	if err != nil {
		return WalletPlanPurchase{}, nil, err
	}
	if amount.Sign() <= 0 {
		return WalletPlanPurchase{}, nil, errors.New("a plan purchase must cost something")
	}
	if utf8.RuneCountInString(purchase.RequestedBy) > maxWalletKeyRunes {
		purchase.RequestedBy = string([]rune(purchase.RequestedBy)[:maxWalletKeyRunes])
	}
	purchase.Amount = FormatWalletAmount(amount)
	return purchase, amount, nil
}

// walletPlanCharge is the main-wallet charge a purchase makes; the statement
// says what it paid for and until when, in the shop's own calendar.
func walletPlanCharge(purchase WalletPlanPurchase, until time.Time) WalletPosting {
	return WalletPosting{
		InstallationID: purchase.InstallationID,
		Account:        WalletAccountMain,
		Kind:           WalletEntryCharge,
		Service:        purchase.Plan,
		Amount:         "-" + purchase.Amount,
		Reference:      purchase.Plan,
		Description: fmt.Sprintf(
			"اشتراك %s حتى %s", walletPlanTitles[purchase.Plan], until.In(smsPeriodZone).Format("2006-01-02"),
		),
		IdempotencyKey: walletPlanPurchaseKey(purchase.IdempotencyKey),
		Actor:          purchase.RequestedBy,
	}
}

func walletPlanPurchaseKey(key string) string { return "plan:" + key }

// walletPlanAuditMetadata is the history line a purchase leaves on the
// installation, beside the operator's own changes.
func walletPlanAuditMetadata(purchase WalletPlanPurchase, entry WalletEntry) AdminAuditMetadata {
	actor := AuditActorWallet
	if purchase.RequestedBy != "" {
		actor += ":" + purchase.RequestedBy
	}
	return AdminAuditMetadata{
		Action: AuditActionSubscriptionPurchased,
		Actor:  actor,
		Reason: fmt.Sprintf("%s for %d days, %s LYD from the wallet (entry %s)",
			purchase.Plan, purchase.Days, purchase.Amount, entry.ID),
	}
}

// walletTransferPostings are the two entries a transfer makes. Both carry the
// same reference, so either leads to the other.
func walletTransferPostings(transfer WalletTransfer) (preparedWalletPosting, preparedWalletPosting, error) {
	transfer.InstallationID = strings.TrimSpace(transfer.InstallationID)
	transfer.IdempotencyKey = strings.TrimSpace(transfer.IdempotencyKey)
	from := NormalizeWalletAccount(transfer.From)
	to := NormalizeWalletAccount(transfer.To)
	if !ValidWalletAccount(from) || !ValidWalletAccount(to) || from == to {
		return preparedWalletPosting{}, preparedWalletPosting{}, fmt.Errorf("a transfer moves money between two different accounts, got %q to %q", transfer.From, transfer.To)
	}
	if transfer.IdempotencyKey == "" {
		return preparedWalletPosting{}, preparedWalletPosting{}, errors.New("a transfer needs an idempotency key")
	}
	amount, err := ParseWalletAmount(transfer.Amount)
	if err != nil {
		return preparedWalletPosting{}, preparedWalletPosting{}, err
	}
	if amount.Sign() <= 0 {
		return preparedWalletPosting{}, preparedWalletPosting{}, errors.New("a transfer amount must be positive")
	}
	key := walletTransferKey(transfer.IdempotencyKey)
	out, err := prepareWalletPosting(WalletPosting{
		InstallationID: transfer.InstallationID,
		Account:        from,
		Kind:           WalletEntryTransfer,
		Amount:         "-" + FormatWalletAmount(amount),
		Reference:      key,
		Description:    "تحويل إلى " + walletAccountTitles[to],
		IdempotencyKey: key,
		Actor:          transfer.Actor,
	})
	if err != nil {
		return preparedWalletPosting{}, preparedWalletPosting{}, err
	}
	in, err := prepareWalletPosting(WalletPosting{
		InstallationID: transfer.InstallationID,
		Account:        to,
		Kind:           WalletEntryTransfer,
		Amount:         FormatWalletAmount(amount),
		Reference:      key,
		Description:    "تحويل من " + walletAccountTitles[from],
		IdempotencyKey: key + ":in",
		Actor:          transfer.Actor,
	})
	if err != nil {
		return preparedWalletPosting{}, preparedWalletPosting{}, err
	}
	return out, in, nil
}

func walletTransferKey(key string) string { return "transfer:" + key }

// walletTopUpClosable reports whether a top-up may still be cancelled or
// failed: only while nobody has proved or refuted the payment.
func walletTopUpClosable(status string) bool {
	return status == WalletTopUpPending || status == WalletTopUpExpired
}

// WalletTopUpOpen reports whether a payment may still land on a top-up with
// this status — what the relay keeps asking the gateway about. A bank
// transfer in review is not: no gateway knows of it.
func WalletTopUpOpen(status string) bool {
	return walletTopUpClosable(status)
}

// settledProviderTransactionID is the gateway id a settlement leaves on a
// top-up: the proof's own when it names one, else the id already stored.
func settledProviderTransactionID(stored string, settlement WalletTopUpSettlement) string {
	if id := strings.TrimSpace(settlement.ProviderTransactionID); id != "" {
		return id
	}
	return stored
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
	posting.Account = NormalizeWalletAccount(posting.Account)
	posting.Kind = strings.ToLower(strings.TrimSpace(posting.Kind))
	posting.Service = strings.ToLower(strings.TrimSpace(posting.Service))
	posting.Reference = strings.TrimSpace(posting.Reference)
	posting.Description = strings.TrimSpace(posting.Description)
	posting.Actor = strings.TrimSpace(posting.Actor)
	if posting.InstallationID == "" || posting.IdempotencyKey == "" {
		return preparedWalletPosting{}, errors.New("a wallet posting needs an installation and an idempotency key")
	}
	if !ValidWalletAccount(posting.Account) {
		return preparedWalletPosting{}, fmt.Errorf("unknown wallet account %q", posting.Account)
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
	case posting.Kind == WalletEntryTopUp && posting.Account != WalletAccountMain:
		return preparedWalletPosting{}, errors.New("a top-up credits the main wallet only")
	}
	if posting.Kind == WalletEntryCharge || posting.Kind == WalletEntryRefund {
		if !walletServicePattern.MatchString(posting.Service) {
			return preparedWalletPosting{}, fmt.Errorf("a %s must name the service it is for", posting.Kind)
		}
	} else if posting.Service != "" && !walletServicePattern.MatchString(posting.Service) {
		return preparedWalletPosting{}, fmt.Errorf("invalid service %q", posting.Service)
	}
	// A charge is the company taking money for something it sold, and a
	// transfer only moves money the shop has; neither can ever be the thing
	// that puts a shop in debt. The one exception — an SMS that went out as
	// more parts than it was held for — is granted after this, by the SMS
	// ledger itself.
	if posting.Kind == WalletEntryCharge || posting.Kind == WalletEntryTransfer {
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
		Account:        posting.Account,
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

// NewWalletInvoiceNo mints a top-up reference: "DFW-" and ten random
// characters, 32^10 of them, in a character set any gateway would accept.
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
	topUp.PayerHint = strings.TrimSpace(topUp.PayerHint)
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
	if utf8.RuneCountInString(topUp.PayerHint) > maxWalletPayerHintRunes {
		topUp.PayerHint = string([]rune(topUp.PayerHint)[:maxWalletPayerHintRunes])
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
	if topUp.Method == WalletTopUpMethodBankTransfer {
		if topUp.Transfer == nil {
			return WalletTopUp{}, errors.New("a bank transfer top-up needs the transfer's details")
		}
		// Nothing to start at a gateway: it waits for the company's eyes.
		topUp.Status = WalletTopUpReview
		transfer := *topUp.Transfer
		transfer.DeclaredAmount = topUp.Amount
		topUp.Transfer = &transfer
	} else {
		topUp.Transfer = nil
	}
	topUp.ProviderTransactionID = ""
	topUp.CheckoutURL = ""
	topUp.OTPAttempts = 0
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
		// The shop reads this on its Arabic statement.
		description = "شحن المحفظة " + topUp.InvoiceNo
	}
	amount := topUp.Amount
	if credited := strings.TrimSpace(settlement.Amount); credited != "" {
		amount = credited
	}
	return WalletPosting{
		InstallationID: topUp.InstallationID,
		Kind:           WalletEntryTopUp,
		Amount:         amount,
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

func (s *FileStore) walletBalanceLocked(installationID, account string) (*big.Rat, *time.Time) {
	balance := new(big.Rat)
	var updatedAt *time.Time
	for _, entry := range s.data.WalletEntries {
		if entry.InstallationID != installationID || NormalizeWalletAccount(entry.Account) != account {
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

func (s *FileStore) GetWallet(ctx context.Context, installationID string) (Wallet, error) {
	return s.GetWalletAccount(ctx, installationID, WalletAccountMain)
}

func (s *FileStore) GetWalletAccount(_ context.Context, installationID, account string) (Wallet, error) {
	account = NormalizeWalletAccount(account)
	if !ValidWalletAccount(account) {
		return Wallet{}, fmt.Errorf("unknown wallet account %q", account)
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	installationID = strings.TrimSpace(installationID)
	balance, updatedAt := s.walletBalanceLocked(installationID, account)
	return Wallet{InstallationID: installationID, Account: account, Balance: FormatWalletAmount(balance), UpdatedAt: updatedAt}, nil
}

func (s *FileStore) ListWallets(_ context.Context, account string, limit int) ([]Wallet, error) {
	account = NormalizeWalletAccount(account)
	if !ValidWalletAccount(account) {
		return nil, fmt.Errorf("unknown wallet account %q", account)
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	seen := map[string]bool{}
	wallets := []Wallet{}
	for _, entry := range s.data.WalletEntries {
		if seen[entry.InstallationID] || NormalizeWalletAccount(entry.Account) != account {
			continue
		}
		seen[entry.InstallationID] = true
		balance, updatedAt := s.walletBalanceLocked(entry.InstallationID, account)
		wallets = append(wallets, Wallet{
			InstallationID: entry.InstallationID,
			Account:        account,
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
			entry.Account = NormalizeWalletAccount(entry.Account)
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
	balance, _ := s.walletBalanceLocked(posting.InstallationID, posting.Account)
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
	account := strings.TrimSpace(filter.Account)
	if account != "" {
		account = NormalizeWalletAccount(account)
	}
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
		entry.Account = NormalizeWalletAccount(entry.Account)
		if installationID != "" && entry.InstallationID != installationID {
			continue
		}
		if account != "" && entry.Account != account {
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

func (s *FileStore) TransferWalletFunds(_ context.Context, transfer WalletTransfer) (WalletTransferResult, bool, error) {
	out, in, err := walletTransferPostings(transfer)
	if err != nil {
		return WalletTransferResult{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	if existing, ok := s.findWalletEntryByKeyLocked(out.InstallationID, out.IdempotencyKey); ok {
		incoming, _ := s.findWalletEntryByKeyLocked(in.InstallationID, in.IdempotencyKey)
		return WalletTransferResult{Out: existing, In: incoming}, false, nil
	}
	outEntry, _, err := s.postWalletEntryLocked(out)
	if err != nil {
		return WalletTransferResult{}, false, err
	}
	inEntry, _, err := s.postWalletEntryLocked(in)
	if err != nil {
		delete(s.data.WalletEntries, outEntry.ID)
		return WalletTransferResult{}, false, err
	}
	if err := s.saveLocked(); err != nil {
		delete(s.data.WalletEntries, outEntry.ID)
		delete(s.data.WalletEntries, inEntry.ID)
		return WalletTransferResult{}, false, err
	}
	return WalletTransferResult{Out: outEntry, In: inEntry}, true, nil
}

func (s *FileStore) PurchaseWalletPlan(_ context.Context, purchase WalletPlanPurchase) (WalletPlanPurchaseResult, bool, error) {
	purchase, _, err := prepareWalletPlanPurchase(purchase)
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	installation, ok := s.data.Installations[purchase.InstallationID]
	if !ok {
		return WalletPlanPurchaseResult{}, false, ErrNotFound
	}
	if existing, ok := s.findWalletEntryByKeyLocked(purchase.InstallationID, walletPlanPurchaseKey(purchase.IdempotencyKey)); ok {
		return WalletPlanPurchaseResult{Entry: existing, Installation: installation}, false, nil
	}
	now := s.clock.Now().UTC()
	from, until, err := walletPlanPeriod(installation, purchase, now)
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	posting, err := prepareWalletPosting(walletPlanCharge(purchase, until))
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	entry, _, err := s.postWalletEntryLocked(posting)
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	updated := setPlanPaidUntil(installation, purchase.Plan, until, now)
	event, err := newAdminAuditEvent(
		installation.ID,
		walletPlanAuditMetadata(purchase, entry),
		InstallationSubscriptionAuditState(installation, now),
		InstallationSubscriptionAuditState(updated, now),
		now,
	)
	if err != nil {
		delete(s.data.WalletEntries, entry.ID)
		return WalletPlanPurchaseResult{}, false, err
	}
	s.data.Installations[installation.ID] = updated
	if s.data.AdminAuditEvents == nil {
		s.data.AdminAuditEvents = map[string][]AdminAuditEvent{}
	}
	previousEvents := s.data.AdminAuditEvents[installation.ID]
	s.data.AdminAuditEvents[installation.ID] = append([]AdminAuditEvent{event}, previousEvents...)
	if err := s.saveLocked(); err != nil {
		delete(s.data.WalletEntries, entry.ID)
		s.data.Installations[installation.ID] = installation
		s.data.AdminAuditEvents[installation.ID] = previousEvents
		return WalletPlanPurchaseResult{}, false, err
	}
	return WalletPlanPurchaseResult{Entry: entry, Installation: updated, From: from, Until: until}, true, nil
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

func (s *FileStore) AttachWalletTopUpPayment(_ context.Context, id, providerTransactionID, checkoutURL string) (WalletTopUp, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.WalletTopUps[id]
	if !ok {
		return WalletTopUp{}, ErrWalletTopUpNotFound
	}
	if existing.Status != WalletTopUpPending || existing.ProviderTransactionID != "" {
		return existing, nil
	}
	updated := existing
	updated.ProviderTransactionID = strings.TrimSpace(providerTransactionID)
	updated.CheckoutURL = strings.TrimSpace(checkoutURL)
	updated.UpdatedAt = s.clock.Now().UTC()
	return s.updateWalletTopUpLocked(existing, updated)
}

func (s *FileStore) RecordWalletTopUpOTPAttempt(_ context.Context, id string, limit int) (WalletTopUp, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	existing, ok := s.data.WalletTopUps[id]
	if !ok {
		return WalletTopUp{}, false, ErrWalletTopUpNotFound
	}
	if existing.Status != WalletTopUpPending || existing.OTPAttempts >= limit {
		return existing, false, nil
	}
	updated := existing
	updated.OTPAttempts++
	updated.UpdatedAt = s.clock.Now().UTC()
	stored, err := s.updateWalletTopUpLocked(existing, updated)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	return stored, true, nil
}

func (s *FileStore) ListOpenWalletTopUps(_ context.Context, createdAfter time.Time, limit int) ([]WalletTopUp, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	topUps := []WalletTopUp{}
	for _, topUp := range s.data.WalletTopUps {
		if !WalletTopUpOpen(topUp.Status) || topUp.ProviderTransactionID == "" || topUp.CreatedAt.Before(createdAfter) {
			continue
		}
		topUp.ShopName = s.data.Installations[topUp.InstallationID].ShopName
		topUps = append(topUps, topUp)
	}
	sortWalletTopUpsNewestFirst(topUps)
	if limit = normalizedWalletListLimit(limit); len(topUps) > limit {
		topUps = topUps[:limit]
	}
	return topUps, nil
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
	updated = applySettledAmount(updated, settlement)
	updated.Status = WalletTopUpPaid
	updated.ProviderTransactionID = settledProviderTransactionID(existing.ProviderTransactionID, settlement)
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
// Only a plan purchase touches an installation row; it re-caches the row it
// wrote. Everything else is forwarded as it is.

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

func (s *CachedInstallationStore) GetWalletAccount(ctx context.Context, installationID, account string) (Wallet, error) {
	store, err := s.walletStore()
	if err != nil {
		return Wallet{}, err
	}
	return store.GetWalletAccount(ctx, installationID, account)
}

func (s *CachedInstallationStore) ListWallets(ctx context.Context, account string, limit int) ([]Wallet, error) {
	store, err := s.walletStore()
	if err != nil {
		return nil, err
	}
	return store.ListWallets(ctx, account, limit)
}

func (s *CachedInstallationStore) TransferWalletFunds(ctx context.Context, transfer WalletTransfer) (WalletTransferResult, bool, error) {
	store, err := s.walletStore()
	if err != nil {
		return WalletTransferResult{}, false, err
	}
	return store.TransferWalletFunds(ctx, transfer)
}

// PurchaseWalletPlan is the one wallet write that changes an installation
// row, so the cached copy is replaced: the entitlement it paid for must be
// what the next ticket or AI request sees.
func (s *CachedInstallationStore) PurchaseWalletPlan(
	ctx context.Context,
	purchase WalletPlanPurchase,
) (WalletPlanPurchaseResult, bool, error) {
	store, err := s.walletStore()
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	result, created, err := store.PurchaseWalletPlan(ctx, purchase)
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	_ = s.cacheInstallation(ctx, result.Installation)
	return result, created, nil
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

func (s *CachedInstallationStore) AttachWalletTopUpPayment(
	ctx context.Context,
	id, providerTransactionID, checkoutURL string,
) (WalletTopUp, error) {
	store, err := s.walletStore()
	if err != nil {
		return WalletTopUp{}, err
	}
	return store.AttachWalletTopUpPayment(ctx, id, providerTransactionID, checkoutURL)
}

func (s *CachedInstallationStore) RecordWalletTopUpOTPAttempt(ctx context.Context, id string, limit int) (WalletTopUp, bool, error) {
	store, err := s.walletStore()
	if err != nil {
		return WalletTopUp{}, false, err
	}
	return store.RecordWalletTopUpOTPAttempt(ctx, id, limit)
}

func (s *CachedInstallationStore) ListOpenWalletTopUps(ctx context.Context, createdAfter time.Time, limit int) ([]WalletTopUp, error) {
	store, err := s.walletStore()
	if err != nil {
		return nil, err
	}
	return store.ListOpenWalletTopUps(ctx, createdAfter, limit)
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
