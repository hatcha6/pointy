package control

import (
	"context"
	"encoding/json"
	"errors"
	"math/big"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// Bank-transfer top-ups: the shop pays the company's own bank account with
// LYPay (to its IBAN) or OnePay (to its bank and account number) and sends the
// receipt. Nothing credits the wallet but an operator who has seen the money
// land on the company's statement; the receipt and the payer's account are
// what let them find it quickly. The store keeps three things for it:
//   - the company's receiving accounts, which the operator sets in the console
//     (never in the code: the repository is public);
//   - each receipt, by the SHA-256 of its bytes, so a receipt sent twice is
//     noticed;
//   - the transfer's details on the top-up itself (WalletTopUp.Transfer).

// Transfer channels: the app the payer sent the money with.
const (
	WalletTransferLYPay  = "lypay"
	WalletTransferOnePay = "onepay"
)

// ValidWalletTransferChannel reports whether channel is a known transfer app.
func ValidWalletTransferChannel(channel string) bool {
	return channel == WalletTransferLYPay || channel == WalletTransferOnePay
}

// MaxWalletReceiptBytes bounds one receipt: a phone photo or a bank's PDF.
const MaxWalletReceiptBytes = 10 << 20

// WalletReceiptRef names a stored receipt from a top-up.
type WalletReceiptRef struct {
	SHA256      string `json:"sha256"`
	ContentType string `json:"content_type"`
	Name        string `json:"name,omitempty"`
	Size        int    `json:"size"`
}

// WalletBankTransfer is what the payer told us about one bank transfer.
type WalletBankTransfer struct {
	Channel string `json:"channel"`
	// The payer's own account: the bank (the Central Bank's slug, "nab"),
	// the account number and the IBAN, as the operator will see them on the
	// company's statement.
	PayerBank    string `json:"payer_bank"`
	PayerAccount string `json:"payer_account"`
	PayerIBAN    string `json:"payer_iban"`
	// ToAccount is the receiving account's id the shop was shown.
	ToAccount string           `json:"to_account,omitempty"`
	Receipt   WalletReceiptRef `json:"receipt"`
	// DeclaredAmount is what the shop said it sent; the top-up's Amount is
	// what was credited when an operator found a different sum.
	DeclaredAmount string `json:"declared_amount,omitempty"`
	// RejectedBy is the operator who turned it down; the reason is the
	// top-up's ErrorDetail.
	RejectedBy string     `json:"rejected_by,omitempty"`
	RejectedAt *time.Time `json:"rejected_at,omitempty"`
}

// WalletBankAccount is one of the company's accounts a shop may pay into.
type WalletBankAccount struct {
	ID string `json:"id"`
	// Bank is the Central Bank's slug ("nab"); BankName is how the app and
	// the console write it.
	Bank          string `json:"bank"`
	BankName      string `json:"bank_name"`
	Holder        string `json:"holder"`
	AccountNumber string `json:"account_number"`
	IBAN          string `json:"iban"`
	Enabled       bool   `json:"enabled"`
}

// WalletBankSettings is the company's receiving accounts.
type WalletBankSettings struct {
	Accounts  []WalletBankAccount `json:"accounts"`
	UpdatedAt *time.Time          `json:"updated_at,omitempty"`
	UpdatedBy string              `json:"updated_by,omitempty"`
}

// EnabledAccounts are the accounts a shop is shown.
func (s WalletBankSettings) EnabledAccounts() []WalletBankAccount {
	accounts := []WalletBankAccount{}
	for _, account := range s.Accounts {
		if account.Enabled {
			accounts = append(accounts, account)
		}
	}
	return accounts
}

// Account finds an enabled receiving account by id.
func (s WalletBankSettings) Account(id string) (WalletBankAccount, bool) {
	for _, account := range s.EnabledAccounts() {
		if account.ID == id {
			return account, true
		}
	}
	return WalletBankAccount{}, false
}

// WalletReceipt is one stored receipt.
type WalletReceipt struct {
	SHA256      string    `json:"sha256"`
	ContentType string    `json:"content_type"`
	Data        []byte    `json:"data"`
	CreatedAt   time.Time `json:"created_at"`
}

// WalletBankStore is an optional store capability (type-asserted, like
// AlertStore) for bank-transfer top-ups.
type WalletBankStore interface {
	WalletBankSettings(ctx context.Context) (WalletBankSettings, error)
	SaveWalletBankSettings(ctx context.Context, settings WalletBankSettings) (WalletBankSettings, error)
	// PutWalletReceipt stores a receipt under its hash; storing the same
	// bytes again is a no-op.
	PutWalletReceipt(ctx context.Context, receipt WalletReceipt) error
	WalletReceipt(ctx context.Context, sha256 string) (WalletReceipt, error)
	// WalletTopUpsByReceipt lists the top-ups that sent this receipt, newest
	// first: one receipt behind two top-ups is the operator's first question.
	WalletTopUpsByReceipt(ctx context.Context, sha256 string) ([]WalletTopUp, error)
	// RejectWalletTopUp turns down a bank transfer still in review, with the
	// reason the shop is shown. Anything else is returned untouched with
	// applied=false.
	RejectWalletTopUp(ctx context.Context, id, by, reason string) (WalletTopUp, bool, error)
}

var (
	_ WalletBankStore = (*FileStore)(nil)
	_ WalletBankStore = (*PostgresStore)(nil)
	_ WalletBankStore = (*CachedInstallationStore)(nil)
)

var (
	ErrWalletReceiptNotFound = errors.New("wallet receipt not found")
	ErrInvalidBankAccount    = errors.New("invalid bank account")
)

const (
	maxWalletBankAccounts = 8
	maxWalletBankText     = 120
)

var (
	libyanIBANPattern    = regexp.MustCompile(`^LY\d{23}$`)
	bankAccountPattern   = regexp.MustCompile(`^\d{6,20}$`)
	bankSlugPattern      = regexp.MustCompile(`^[a-z0-9_-]{1,32}$`)
	walletReceiptPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// NormalizeIBAN drops the spaces people copy an IBAN with and upper-cases it.
func NormalizeIBAN(raw string) string {
	return strings.ToUpper(strings.Join(strings.Fields(raw), ""))
}

// ValidLibyanIBAN checks a Libyan IBAN's shape and its ISO 13616 check digits:
// LY, two check digits, then the bank (3), branch (3) and account (15).
func ValidLibyanIBAN(iban string) bool {
	if !libyanIBANPattern.MatchString(iban) {
		return false
	}
	rearranged := iban[4:] + iban[:4]
	var digits strings.Builder
	for _, r := range rearranged {
		switch {
		case r >= '0' && r <= '9':
			digits.WriteRune(r)
		case r >= 'A' && r <= 'Z':
			digits.WriteString(big.NewInt(int64(r - 'A' + 10)).String())
		default:
			return false
		}
	}
	value, ok := new(big.Int).SetString(digits.String(), 10)
	return ok && new(big.Int).Mod(value, big.NewInt(97)).Int64() == 1
}

// NormalizeBankAccountNumber keeps the digits of an account number.
func NormalizeBankAccountNumber(raw string) string {
	return strings.Join(strings.Fields(strings.ReplaceAll(raw, "-", " ")), "")
}

// ValidBankAccountNumber is a plain account number: digits only.
func ValidBankAccountNumber(number string) bool {
	return bankAccountPattern.MatchString(number)
}

// ValidBankSlug is the shape of a Central Bank slug.
func ValidBankSlug(slug string) bool {
	return bankSlugPattern.MatchString(slug)
}

// ValidWalletReceiptHash is a receipt's SHA-256, lower-case hex.
func ValidWalletReceiptHash(sha string) bool {
	return walletReceiptPattern.MatchString(sha)
}

// NormalizeWalletBankSettings checks the operator's accounts and gives each
// one an id.
func NormalizeWalletBankSettings(settings WalletBankSettings, now time.Time) (WalletBankSettings, error) {
	if len(settings.Accounts) > maxWalletBankAccounts {
		return WalletBankSettings{}, ErrInvalidBankAccount
	}
	seen := map[string]bool{}
	accounts := make([]WalletBankAccount, 0, len(settings.Accounts))
	for _, account := range settings.Accounts {
		account.ID = strings.TrimSpace(account.ID)
		if account.ID == "" {
			id, err := NewInstallationID()
			if err != nil {
				return WalletBankSettings{}, err
			}
			account.ID = id[:12]
		}
		account.Bank = strings.ToLower(strings.TrimSpace(account.Bank))
		account.BankName = strings.TrimSpace(account.BankName)
		account.Holder = strings.TrimSpace(account.Holder)
		account.AccountNumber = NormalizeBankAccountNumber(account.AccountNumber)
		account.IBAN = NormalizeIBAN(account.IBAN)
		if seen[account.ID] || !ValidBankSlug(account.Bank) || account.BankName == "" || account.Holder == "" ||
			utf8.RuneCountInString(account.BankName) > maxWalletBankText ||
			utf8.RuneCountInString(account.Holder) > maxWalletBankText ||
			!ValidBankAccountNumber(account.AccountNumber) || !ValidLibyanIBAN(account.IBAN) {
			return WalletBankSettings{}, ErrInvalidBankAccount
		}
		seen[account.ID] = true
		accounts = append(accounts, account)
	}
	at := now.UTC()
	settings.Accounts = accounts
	settings.UpdatedAt = &at
	settings.UpdatedBy = truncateRunes(strings.TrimSpace(settings.UpdatedBy), maxWalletBankText)
	return settings, nil
}

// applySettledAmount books what an operator credited when it is not what the
// shop declared.
func applySettledAmount(topUp WalletTopUp, settlement WalletTopUpSettlement) WalletTopUp {
	credited := strings.TrimSpace(settlement.Amount)
	if credited == "" {
		return topUp
	}
	if topUp.Transfer != nil {
		transfer := *topUp.Transfer
		if transfer.DeclaredAmount == "" {
			transfer.DeclaredAmount = topUp.Amount
		}
		topUp.Transfer = &transfer
	}
	topUp.Amount = NormalizeWalletAmount(credited)
	return topUp
}

func rejectedTransfer(topUp WalletTopUp, by string, at time.Time) *WalletBankTransfer {
	transfer := WalletBankTransfer{}
	if topUp.Transfer != nil {
		transfer = *topUp.Transfer
	}
	transfer.RejectedBy = truncateRunes(strings.TrimSpace(by), maxWalletBankText)
	transfer.RejectedAt = &at
	return &transfer
}

func normalizedRejectReason(reason string) string {
	return truncateRunes(strings.TrimSpace(reason), maxWalletTextRunes)
}

// --- file store ------------------------------------------------------------

type fileWalletBankData struct {
	Settings WalletBankSettings       `json:"settings"`
	Receipts map[string]WalletReceipt `json:"receipts,omitempty"`
}

func (s *FileStore) WalletBankSettings(_ context.Context) (WalletBankSettings, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.WalletBank == nil {
		return WalletBankSettings{Accounts: []WalletBankAccount{}}, nil
	}
	settings := s.data.WalletBank.Settings
	settings.Accounts = append([]WalletBankAccount{}, settings.Accounts...)
	return settings, nil
}

func (s *FileStore) SaveWalletBankSettings(_ context.Context, settings WalletBankSettings) (WalletBankSettings, error) {
	normalized, err := NormalizeWalletBankSettings(settings, s.clock.Now())
	if err != nil {
		return WalletBankSettings{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := s.data.WalletBank
	next := &fileWalletBankData{Settings: normalized}
	if previous != nil {
		next.Receipts = previous.Receipts
	}
	s.data.WalletBank = next
	if err := s.saveLocked(); err != nil {
		s.data.WalletBank = previous
		return WalletBankSettings{}, err
	}
	return normalized, nil
}

func (s *FileStore) PutWalletReceipt(_ context.Context, receipt WalletReceipt) error {
	if !ValidWalletReceiptHash(receipt.SHA256) || len(receipt.Data) == 0 {
		return errors.New("invalid receipt")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.WalletBank == nil {
		s.data.WalletBank = &fileWalletBankData{Settings: WalletBankSettings{Accounts: []WalletBankAccount{}}}
	}
	if s.data.WalletBank.Receipts == nil {
		s.data.WalletBank.Receipts = map[string]WalletReceipt{}
	}
	if _, ok := s.data.WalletBank.Receipts[receipt.SHA256]; ok {
		return nil
	}
	receipt.CreatedAt = s.clock.Now().UTC()
	s.data.WalletBank.Receipts[receipt.SHA256] = receipt
	if err := s.saveLocked(); err != nil {
		delete(s.data.WalletBank.Receipts, receipt.SHA256)
		return err
	}
	return nil
}

func (s *FileStore) WalletReceipt(_ context.Context, sha string) (WalletReceipt, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.WalletBank != nil {
		if receipt, ok := s.data.WalletBank.Receipts[strings.TrimSpace(sha)]; ok {
			return receipt, nil
		}
	}
	return WalletReceipt{}, ErrWalletReceiptNotFound
}

func (s *FileStore) WalletTopUpsByReceipt(_ context.Context, sha string) ([]WalletTopUp, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	topUps := []WalletTopUp{}
	for _, topUp := range s.data.WalletTopUps {
		if topUp.Transfer != nil && topUp.Transfer.Receipt.SHA256 == sha {
			topUp.ShopName = s.data.Installations[topUp.InstallationID].ShopName
			topUps = append(topUps, topUp)
		}
	}
	sortWalletTopUpsNewestFirst(topUps)
	return topUps, nil
}

func (s *FileStore) RejectWalletTopUp(_ context.Context, id, by, reason string) (WalletTopUp, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	existing, ok := s.data.WalletTopUps[strings.TrimSpace(id)]
	if !ok {
		return WalletTopUp{}, false, ErrWalletTopUpNotFound
	}
	if existing.Status != WalletTopUpReview {
		return existing, false, nil
	}
	now := s.clock.Now().UTC()
	updated := existing
	updated.Status = WalletTopUpRejected
	updated.ErrorCode = WalletTopUpRejected
	updated.ErrorDetail = normalizedRejectReason(reason)
	updated.Transfer = rejectedTransfer(existing, by, now)
	updated.UpdatedAt = now
	stored, err := s.updateWalletTopUpLocked(existing, updated)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	stored.ShopName = s.data.Installations[stored.InstallationID].ShopName
	return stored, true, nil
}

// --- postgres store ----------------------------------------------------------

func (s *PostgresStore) WalletBankSettings(ctx context.Context) (WalletBankSettings, error) {
	var raw []byte
	var updatedAt *time.Time
	var updatedBy string
	err := s.pool.QueryRow(ctx,
		`SELECT accounts, updated_at, updated_by FROM relay_wallet_bank_settings WHERE id = 1`,
	).Scan(&raw, &updatedAt, &updatedBy)
	if errors.Is(err, pgx.ErrNoRows) {
		return WalletBankSettings{Accounts: []WalletBankAccount{}}, nil
	}
	if err != nil {
		return WalletBankSettings{}, err
	}
	settings := WalletBankSettings{Accounts: []WalletBankAccount{}, UpdatedBy: updatedBy}
	if updatedAt != nil {
		at := updatedAt.UTC()
		settings.UpdatedAt = &at
	}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &settings.Accounts); err != nil {
			return WalletBankSettings{}, err
		}
	}
	return settings, nil
}

func (s *PostgresStore) SaveWalletBankSettings(ctx context.Context, settings WalletBankSettings) (WalletBankSettings, error) {
	normalized, err := NormalizeWalletBankSettings(settings, s.clock.Now())
	if err != nil {
		return WalletBankSettings{}, err
	}
	accounts, err := json.Marshal(normalized.Accounts)
	if err != nil {
		return WalletBankSettings{}, err
	}
	_, err = s.pool.Exec(ctx, `INSERT INTO relay_wallet_bank_settings (id, accounts, updated_at, updated_by)
		VALUES (1, $1::jsonb, $2::timestamptz, $3)
		ON CONFLICT (id) DO UPDATE SET accounts = EXCLUDED.accounts,
			updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by`,
		string(accounts), *normalized.UpdatedAt, normalized.UpdatedBy)
	if err != nil {
		return WalletBankSettings{}, err
	}
	return normalized, nil
}

func (s *PostgresStore) PutWalletReceipt(ctx context.Context, receipt WalletReceipt) error {
	if !ValidWalletReceiptHash(receipt.SHA256) || len(receipt.Data) == 0 {
		return errors.New("invalid receipt")
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO relay_wallet_receipts (sha256, content_type, data, created_at)
		VALUES ($1, $2, $3, $4::timestamptz)
		ON CONFLICT (sha256) DO NOTHING`,
		receipt.SHA256, receipt.ContentType, receipt.Data, s.clock.Now().UTC())
	return err
}

func (s *PostgresStore) WalletReceipt(ctx context.Context, sha string) (WalletReceipt, error) {
	receipt := WalletReceipt{SHA256: strings.TrimSpace(sha)}
	err := s.pool.QueryRow(ctx,
		`SELECT content_type, data, created_at FROM relay_wallet_receipts WHERE sha256 = $1`,
		receipt.SHA256,
	).Scan(&receipt.ContentType, &receipt.Data, &receipt.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return WalletReceipt{}, ErrWalletReceiptNotFound
	}
	if err != nil {
		return WalletReceipt{}, err
	}
	receipt.CreatedAt = receipt.CreatedAt.UTC()
	return receipt, nil
}

func (s *PostgresStore) WalletTopUpsByReceipt(ctx context.Context, sha string) ([]WalletTopUp, error) {
	rows, err := s.pool.Query(ctx, selectWalletTopUpWithShopSQL+`
		WHERE t.transfer->'receipt'->>'sha256' = $1
		ORDER BY t.created_at DESC, t.id DESC
		LIMIT 20`, strings.TrimSpace(sha))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	topUps := []WalletTopUp{}
	for rows.Next() {
		topUp, err := scanWalletTopUp(rows, true)
		if err != nil {
			return nil, err
		}
		topUps = append(topUps, topUp)
	}
	return topUps, rows.Err()
}

func (s *PostgresStore) RejectWalletTopUp(ctx context.Context, id, by, reason string) (WalletTopUp, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	defer tx.Rollback(ctx)
	existing, err := scanWalletTopUp(tx.QueryRow(ctx,
		`SELECT `+walletTopUpColumns+` FROM relay_wallet_topups t WHERE t.id = $1 FOR UPDATE`,
		strings.TrimSpace(id),
	), false)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	if existing.Status != WalletTopUpReview {
		if err := tx.Commit(ctx); err != nil {
			return WalletTopUp{}, false, err
		}
		return existing, false, nil
	}
	now := s.clock.Now().UTC()
	transfer, err := json.Marshal(rejectedTransfer(existing, by, now))
	if err != nil {
		return WalletTopUp{}, false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE relay_wallet_topups
		SET status = 'rejected', error_code = 'rejected', error_detail = $2,
			transfer = $3::jsonb, updated_at = $4::timestamptz
		WHERE id = $1`,
		existing.ID, normalizedRejectReason(reason), string(transfer), now,
	); err != nil {
		return WalletTopUp{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return WalletTopUp{}, false, err
	}
	rejected, err := s.GetWalletTopUp(ctx, existing.ID)
	return rejected, err == nil, err
}

// transferJSON is a top-up's transfer as the jsonb column holds it.
func transferJSON(transfer *WalletBankTransfer) (string, error) {
	if transfer == nil {
		return "null", nil
	}
	encoded, err := json.Marshal(transfer)
	return string(encoded), err
}

// --- cached store ----------------------------------------------------------

// Bank settings and receipts are read rarely and must be fresh; they forward
// to the wrapped store.

func (s *CachedInstallationStore) walletBankStore() (WalletBankStore, error) {
	store, ok := s.store.(WalletBankStore)
	if !ok {
		return nil, errors.New("store does not support bank-transfer top-ups")
	}
	return store, nil
}

func (s *CachedInstallationStore) WalletBankSettings(ctx context.Context) (WalletBankSettings, error) {
	store, err := s.walletBankStore()
	if err != nil {
		return WalletBankSettings{}, err
	}
	return store.WalletBankSettings(ctx)
}

func (s *CachedInstallationStore) SaveWalletBankSettings(ctx context.Context, settings WalletBankSettings) (WalletBankSettings, error) {
	store, err := s.walletBankStore()
	if err != nil {
		return WalletBankSettings{}, err
	}
	return store.SaveWalletBankSettings(ctx, settings)
}

func (s *CachedInstallationStore) PutWalletReceipt(ctx context.Context, receipt WalletReceipt) error {
	store, err := s.walletBankStore()
	if err != nil {
		return err
	}
	return store.PutWalletReceipt(ctx, receipt)
}

func (s *CachedInstallationStore) WalletReceipt(ctx context.Context, sha string) (WalletReceipt, error) {
	store, err := s.walletBankStore()
	if err != nil {
		return WalletReceipt{}, err
	}
	return store.WalletReceipt(ctx, sha)
}

func (s *CachedInstallationStore) WalletTopUpsByReceipt(ctx context.Context, sha string) ([]WalletTopUp, error) {
	store, err := s.walletBankStore()
	if err != nil {
		return nil, err
	}
	return store.WalletTopUpsByReceipt(ctx, sha)
}

func (s *CachedInstallationStore) RejectWalletTopUp(ctx context.Context, id, by, reason string) (WalletTopUp, bool, error) {
	store, err := s.walletBankStore()
	if err != nil {
		return WalletTopUp{}, false, err
	}
	return store.RejectWalletTopUp(ctx, id, by, reason)
}

// SavedWalletPayers are the distinct payer accounts in a shop's bank
// transfers, newest first: what the app offers so a second top-up from the
// same account is one tap.
func SavedWalletPayers(topUps []WalletTopUp, limit int) []WalletBankTransfer {
	sorted := append([]WalletTopUp{}, topUps...)
	sortWalletTopUpsNewestFirst(sorted)
	seen := map[string]bool{}
	payers := []WalletBankTransfer{}
	for _, topUp := range sorted {
		if topUp.Transfer == nil || topUp.Transfer.PayerIBAN == "" {
			continue
		}
		key := topUp.Transfer.PayerIBAN + "|" + topUp.Transfer.PayerAccount + "|" + topUp.Transfer.PayerBank
		if seen[key] {
			continue
		}
		seen[key] = true
		payers = append(payers, WalletBankTransfer{
			Channel:      topUp.Transfer.Channel,
			PayerBank:    topUp.Transfer.PayerBank,
			PayerAccount: topUp.Transfer.PayerAccount,
			PayerIBAN:    topUp.Transfer.PayerIBAN,
		})
		if len(payers) >= limit {
			break
		}
	}
	return payers
}
