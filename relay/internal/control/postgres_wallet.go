package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
)

// walletEntryColumns is the canonical column order for scanWalletEntry. Every
// query aliases relay_wallet_entries as e.
const walletEntryColumns = `e.id,
	e.installation_id,
	e.account,
	e.kind,
	e.service,
	e.amount::text,
	e.balance_after::text,
	e.reference,
	e.description,
	e.idempotency_key,
	e.actor,
	e.test_mode,
	e.created_at`

// walletTopUpColumns is the canonical column order for scanWalletTopUp. Every
// query aliases relay_wallet_topups as t.
const walletTopUpColumns = `t.id,
	t.installation_id,
	t.method,
	t.amount::text,
	t.status,
	t.invoice_no,
	t.provider_transaction_id,
	t.checkout_url,
	t.idempotency_key,
	t.requested_by,
	t.payer_hint,
	t.otp_attempts,
	t.test_mode,
	t.error_code,
	t.error_detail,
	t.entry_id,
	t.confirmed_by,
	t.created_at,
	t.updated_at,
	t.paid_at,
	t.transfer`

const selectWalletEntryWithShopSQL = `SELECT ` + walletEntryColumns + `, COALESCE(i.shop_name, '')
FROM relay_wallet_entries e
LEFT JOIN relay_installations i ON i.id = e.installation_id`

const selectWalletTopUpWithShopSQL = `SELECT ` + walletTopUpColumns + `, COALESCE(i.shop_name, '')
FROM relay_wallet_topups t
LEFT JOIN relay_installations i ON i.id = t.installation_id`

// Postgres error codes the wallet turns into its own answers.
const (
	pgForeignKeyViolation = "23503"
	pgUniqueViolation     = "23505"
)

func pgErrorCode(err error) (string, string) {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code, pgErr.ConstraintName
	}
	return "", ""
}

// The main wallet's running balance is relay_wallets (migration 15); every
// other account's is a row of relay_wallet_accounts (migration 17). These
// three statements per table are the only place that difference shows.
const (
	selectMainWalletBalanceSQL = `SELECT balance::text, updated_at FROM relay_wallets WHERE installation_id = $1`
	selectAccountBalanceSQL    = `SELECT balance::text, updated_at FROM relay_wallet_accounts
		WHERE installation_id = $1 AND account = $2`
	ensureMainWalletSQL = `INSERT INTO relay_wallets (installation_id, balance, created_at, updated_at)
		VALUES ($1, 0, $2::timestamptz, $2::timestamptz)
		ON CONFLICT (installation_id) DO NOTHING`
	ensureAccountSQL = `INSERT INTO relay_wallet_accounts (installation_id, account, balance, created_at, updated_at)
		VALUES ($1, $3, 0, $2::timestamptz, $2::timestamptz)
		ON CONFLICT (installation_id, account) DO NOTHING`
	lockMainWalletSQL = `SELECT balance::text FROM relay_wallets WHERE installation_id = $1 FOR UPDATE`
	lockAccountSQL    = `SELECT balance::text FROM relay_wallet_accounts
		WHERE installation_id = $1 AND account = $2 FOR UPDATE`
	setMainWalletSQL = `UPDATE relay_wallets SET balance = $2::text::numeric, updated_at = $3::timestamptz
		WHERE installation_id = $1`
	setAccountSQL = `UPDATE relay_wallet_accounts SET balance = $2::text::numeric, updated_at = $3::timestamptz
		WHERE installation_id = $1 AND account = $4`
)

func (s *PostgresStore) GetWallet(ctx context.Context, installationID string) (Wallet, error) {
	return s.GetWalletAccount(ctx, installationID, WalletAccountMain)
}

func (s *PostgresStore) GetWalletAccount(ctx context.Context, installationID, account string) (Wallet, error) {
	installationID = strings.TrimSpace(installationID)
	account = NormalizeWalletAccount(account)
	if !ValidWalletAccount(account) {
		return Wallet{}, fmt.Errorf("unknown wallet account %q", account)
	}
	var balance string
	var updatedAt time.Time
	var err error
	if account == WalletAccountMain {
		err = s.pool.QueryRow(ctx, selectMainWalletBalanceSQL, installationID).Scan(&balance, &updatedAt)
	} else {
		err = s.pool.QueryRow(ctx, selectAccountBalanceSQL, installationID, account).Scan(&balance, &updatedAt)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return Wallet{InstallationID: installationID, Account: account, Balance: FormatWalletAmount(nil)}, nil
	}
	if err != nil {
		return Wallet{}, err
	}
	updated := updatedAt.UTC()
	return Wallet{InstallationID: installationID, Account: account, Balance: NormalizeWalletAmount(balance), UpdatedAt: &updated}, nil
}

func (s *PostgresStore) ListWallets(ctx context.Context, account string, limit int) ([]Wallet, error) {
	account = NormalizeWalletAccount(account)
	if !ValidWalletAccount(account) {
		return nil, fmt.Errorf("unknown wallet account %q", account)
	}
	var rows pgx.Rows
	var err error
	if account == WalletAccountMain {
		rows, err = s.pool.Query(
			ctx,
			`SELECT w.installation_id, COALESCE(i.shop_name, ''), w.balance::text, w.updated_at
			FROM relay_wallets w
			LEFT JOIN relay_installations i ON i.id = w.installation_id
			ORDER BY w.balance DESC, w.installation_id
			LIMIT $1`,
			normalizedWalletListLimit(limit),
		)
	} else {
		rows, err = s.pool.Query(
			ctx,
			`SELECT w.installation_id, COALESCE(i.shop_name, ''), w.balance::text, w.updated_at
			FROM relay_wallet_accounts w
			LEFT JOIN relay_installations i ON i.id = w.installation_id
			WHERE w.account = $2
			ORDER BY w.balance DESC, w.installation_id
			LIMIT $1`,
			normalizedWalletListLimit(limit),
			account,
		)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	wallets := []Wallet{}
	for rows.Next() {
		wallet := Wallet{Account: account}
		var updatedAt time.Time
		if err := rows.Scan(&wallet.InstallationID, &wallet.ShopName, &wallet.Balance, &updatedAt); err != nil {
			return nil, err
		}
		wallet.Balance = NormalizeWalletAmount(wallet.Balance)
		updated := updatedAt.UTC()
		wallet.UpdatedAt = &updated
		wallets = append(wallets, wallet)
	}
	return wallets, rows.Err()
}

// lockWalletBalanceTx makes sure the account's balance row exists and locks it
// for the rest of the transaction, returning the balance.
func lockWalletBalanceTx(ctx context.Context, tx pgx.Tx, installationID, account string, now time.Time) (*big.Rat, error) {
	var err error
	if account == WalletAccountMain {
		_, err = tx.Exec(ctx, ensureMainWalletSQL, installationID, now)
	} else {
		_, err = tx.Exec(ctx, ensureAccountSQL, installationID, now, account)
	}
	if err != nil {
		if code, _ := pgErrorCode(err); code == pgForeignKeyViolation {
			return nil, ErrNotFound
		}
		return nil, err
	}
	var balanceText string
	if account == WalletAccountMain {
		err = tx.QueryRow(ctx, lockMainWalletSQL, installationID).Scan(&balanceText)
	} else {
		err = tx.QueryRow(ctx, lockAccountSQL, installationID, account).Scan(&balanceText)
	}
	if err != nil {
		return nil, err
	}
	balance, ok := new(big.Rat).SetString(balanceText)
	if !ok {
		return nil, fmt.Errorf("stored %s balance %q is not a decimal", account, balanceText)
	}
	return balance, nil
}

func setWalletBalanceTx(ctx context.Context, tx pgx.Tx, installationID, account string, balance *big.Rat, now time.Time) error {
	var err error
	if account == WalletAccountMain {
		_, err = tx.Exec(ctx, setMainWalletSQL, installationID, FormatWalletAmount(balance), now)
	} else {
		_, err = tx.Exec(ctx, setAccountSQL, installationID, FormatWalletAmount(balance), now, account)
	}
	return err
}

func (s *PostgresStore) PostWalletEntry(ctx context.Context, posting WalletPosting) (WalletEntry, bool, error) {
	prepared, err := prepareWalletPosting(posting)
	if err != nil {
		return WalletEntry{}, false, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return WalletEntry{}, false, err
	}
	defer tx.Rollback(ctx)

	entry, created, err := s.postWalletEntryTx(ctx, tx, prepared)
	if err != nil {
		return WalletEntry{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return WalletEntry{}, false, err
	}
	return entry, created, nil
}

// postWalletEntryTx records a prepared posting inside the caller's
// transaction. It locks the account's balance row first, so the idempotency
// check, the balance check and the insert are one step: two debits racing for
// the last dinar cannot both get it, and a retried key cannot slip between.
// Locking a row the transaction already holds is a no-op, so callers that
// locked it themselves can still post through here.
func (s *PostgresStore) postWalletEntryTx(
	ctx context.Context,
	tx pgx.Tx,
	posting preparedWalletPosting,
) (WalletEntry, bool, error) {
	now := s.clock.Now().UTC()
	balance, err := lockWalletBalanceTx(ctx, tx, posting.InstallationID, posting.Account, now)
	if err != nil {
		return WalletEntry{}, false, err
	}
	existing, err := scanWalletEntry(tx.QueryRow(
		ctx,
		`SELECT `+walletEntryColumns+` FROM relay_wallet_entries e
		WHERE e.installation_id = $1 AND e.idempotency_key = $2`,
		posting.InstallationID,
		posting.IdempotencyKey,
	), false)
	if err == nil {
		return existing, false, nil
	}
	if !errors.Is(err, ErrWalletEntryNotFound) {
		return WalletEntry{}, false, err
	}
	next, err := nextWalletBalance(balance, posting)
	if err != nil {
		return WalletEntry{}, false, err
	}
	entry, err := newWalletEntry(posting, next, now)
	if err != nil {
		return WalletEntry{}, false, err
	}
	inserted, err := scanWalletEntry(tx.QueryRow(
		ctx,
		`INSERT INTO relay_wallet_entries AS e (
			id, installation_id, account, kind, service, amount, balance_after, reference,
			description, idempotency_key, actor, test_mode, created_at
		) VALUES (
			$1, $2, $3, $4, $5, $6::text::numeric, $7::text::numeric, $8,
			$9, $10, $11, $12, $13::timestamptz
		) RETURNING `+walletEntryColumns,
		entry.ID,
		entry.InstallationID,
		entry.Account,
		entry.Kind,
		entry.Service,
		entry.Amount,
		entry.BalanceAfter,
		entry.Reference,
		entry.Description,
		entry.IdempotencyKey,
		entry.Actor,
		entry.TestMode,
		entry.CreatedAt,
	), false)
	if err != nil {
		return WalletEntry{}, false, err
	}
	if err := setWalletBalanceTx(ctx, tx, posting.InstallationID, posting.Account, next, now); err != nil {
		return WalletEntry{}, false, err
	}
	return inserted, true, nil
}

func (s *PostgresStore) ListWalletEntries(ctx context.Context, filter WalletEntryFilter) ([]WalletEntry, error) {
	var conditions []string
	var args []any
	if id := strings.TrimSpace(filter.InstallationID); id != "" {
		args = append(args, id)
		conditions = append(conditions, fmt.Sprintf("e.installation_id = $%d", len(args)))
	}
	if account := strings.TrimSpace(filter.Account); account != "" {
		args = append(args, NormalizeWalletAccount(account))
		conditions = append(conditions, fmt.Sprintf("e.account = $%d", len(args)))
	}
	if kind := strings.TrimSpace(filter.Kind); kind != "" {
		args = append(args, kind)
		conditions = append(conditions, fmt.Sprintf("e.kind = $%d", len(args)))
	}
	if beforeID := strings.TrimSpace(filter.BeforeID); beforeID != "" {
		var cursorAt time.Time
		err := s.pool.QueryRow(ctx, `SELECT created_at FROM relay_wallet_entries WHERE id = $1`, beforeID).Scan(&cursorAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrWalletEntryNotFound
		}
		if err != nil {
			return nil, err
		}
		args = append(args, cursorAt, beforeID)
		conditions = append(conditions, fmt.Sprintf("(e.created_at, e.id) < ($%d::timestamptz, $%d)", len(args)-1, len(args)))
	}
	query := selectWalletEntryWithShopSQL
	if len(conditions) > 0 {
		query += " WHERE " + strings.Join(conditions, " AND ")
	}
	args = append(args, normalizedWalletListLimit(filter.Limit))
	query += fmt.Sprintf(" ORDER BY e.created_at DESC, e.id DESC LIMIT $%d", len(args))
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	entries := []WalletEntry{}
	for rows.Next() {
		entry, err := scanWalletEntry(rows, true)
		if err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	return entries, rows.Err()
}

func (s *PostgresStore) findWalletEntryByKeyTx(ctx context.Context, tx pgx.Tx, installationID, key string) (WalletEntry, error) {
	return scanWalletEntry(tx.QueryRow(
		ctx,
		`SELECT `+walletEntryColumns+` FROM relay_wallet_entries e
		WHERE e.installation_id = $1 AND e.idempotency_key = $2`,
		installationID,
		key,
	), false)
}

func (s *PostgresStore) TransferWalletFunds(ctx context.Context, transfer WalletTransfer) (WalletTransferResult, bool, error) {
	out, in, err := walletTransferPostings(transfer)
	if err != nil {
		return WalletTransferResult{}, false, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return WalletTransferResult{}, false, err
	}
	defer tx.Rollback(ctx)

	// Both rows are locked in one fixed order (main before any other account,
	// then by name), so two transfers in opposite directions can never each
	// hold the row the other is waiting for.
	now := s.clock.Now().UTC()
	first, second := out.Account, in.Account
	if second == WalletAccountMain || (first != WalletAccountMain && second < first) {
		first, second = second, first
	}
	for _, account := range []string{first, second} {
		if _, err := lockWalletBalanceTx(ctx, tx, out.InstallationID, account, now); err != nil {
			return WalletTransferResult{}, false, err
		}
	}
	if existing, err := s.findWalletEntryByKeyTx(ctx, tx, out.InstallationID, out.IdempotencyKey); err == nil {
		incoming, err := s.findWalletEntryByKeyTx(ctx, tx, in.InstallationID, in.IdempotencyKey)
		if err != nil {
			return WalletTransferResult{}, false, err
		}
		if err := tx.Commit(ctx); err != nil {
			return WalletTransferResult{}, false, err
		}
		return WalletTransferResult{Out: existing, In: incoming}, false, nil
	} else if !errors.Is(err, ErrWalletEntryNotFound) {
		return WalletTransferResult{}, false, err
	}
	outEntry, _, err := s.postWalletEntryTx(ctx, tx, out)
	if err != nil {
		return WalletTransferResult{}, false, err
	}
	inEntry, _, err := s.postWalletEntryTx(ctx, tx, in)
	if err != nil {
		return WalletTransferResult{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return WalletTransferResult{}, false, err
	}
	return WalletTransferResult{Out: outEntry, In: inEntry}, true, nil
}

func (s *PostgresStore) PurchaseWalletPlan(ctx context.Context, purchase WalletPlanPurchase) (WalletPlanPurchaseResult, bool, error) {
	purchase, _, err := prepareWalletPlanPurchase(purchase)
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	defer tx.Rollback(ctx)

	// Lock order is wallet, then installation. The installation row is taken
	// FOR NO KEY UPDATE, which never waits on the key-share locks every ledger
	// insert takes on it through its foreign key.
	now := s.clock.Now().UTC()
	if _, err := lockWalletBalanceTx(ctx, tx, purchase.InstallationID, WalletAccountMain, now); err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	installation, err := scanInstallation(tx.QueryRow(
		ctx,
		selectInstallationSQL+" WHERE id = $1 FOR NO KEY UPDATE",
		purchase.InstallationID,
	))
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	if existing, err := s.findWalletEntryByKeyTx(ctx, tx, purchase.InstallationID, walletPlanPurchaseKey(purchase.IdempotencyKey)); err == nil {
		if err := tx.Commit(ctx); err != nil {
			return WalletPlanPurchaseResult{}, false, err
		}
		return WalletPlanPurchaseResult{Entry: existing, Installation: installation}, false, nil
	} else if !errors.Is(err, ErrWalletEntryNotFound) {
		return WalletPlanPurchaseResult{}, false, err
	}
	from, until, err := walletPlanPeriod(installation, purchase, now)
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	posting, err := prepareWalletPosting(walletPlanCharge(purchase, until))
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	entry, _, err := s.postWalletEntryTx(ctx, tx, posting)
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	column := "remote_access_paid_until"
	if purchase.Plan == WalletPlanAI {
		column = "ai_paid_until"
	}
	updated, err := scanInstallation(tx.QueryRow(
		ctx,
		`UPDATE relay_installations SET `+column+` = $2::timestamptz, updated_at = $3::timestamptz
		WHERE id = $1
		RETURNING `+installationColumns,
		purchase.InstallationID,
		until,
		now,
	))
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	event, err := newAdminAuditEvent(
		installation.ID,
		walletPlanAuditMetadata(purchase, entry),
		InstallationSubscriptionAuditState(installation, now),
		InstallationSubscriptionAuditState(updated, now),
		now,
	)
	if err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	if err := insertAdminAuditEventTx(ctx, tx, event); err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return WalletPlanPurchaseResult{}, false, err
	}
	return WalletPlanPurchaseResult{Entry: entry, Installation: updated, From: from, Until: until}, true, nil
}

func (s *PostgresStore) BeginWalletTopUp(ctx context.Context, topUp WalletTopUp) (WalletTopUp, bool, error) {
	// An invoice number clash is 1 in 32^10 per pair; a fresh draw settles it.
	for attempt := 0; attempt < 3; attempt++ {
		prepared, err := prepareWalletTopUp(topUp, s.clock.Now())
		if err != nil {
			return WalletTopUp{}, false, err
		}
		transfer, err := transferJSON(prepared.Transfer)
		if err != nil {
			return WalletTopUp{}, false, err
		}
		inserted, err := scanWalletTopUp(s.pool.QueryRow(
			ctx,
			`INSERT INTO relay_wallet_topups AS t (
				id, installation_id, method, amount, status, invoice_no,
				provider_transaction_id, checkout_url, idempotency_key, requested_by,
				payer_hint, otp_attempts,
				test_mode, error_code, error_detail, entry_id, confirmed_by,
				created_at, updated_at, paid_at, transfer
			) VALUES (
				$1, $2, $3, $4::text::numeric, $5, $6,
				'', '', $7, $8,
				$9, 0,
				$10, '', '', '', '',
				$11::timestamptz, $11::timestamptz, NULL, $12::jsonb
			)
			ON CONFLICT (installation_id, idempotency_key) DO NOTHING
			RETURNING `+walletTopUpColumns,
			prepared.ID,
			prepared.InstallationID,
			prepared.Method,
			prepared.Amount,
			prepared.Status,
			prepared.InvoiceNo,
			prepared.IdempotencyKey,
			prepared.RequestedBy,
			prepared.PayerHint,
			prepared.TestMode,
			prepared.CreatedAt,
			transfer,
		), false)
		switch code, constraint := pgErrorCode(err); {
		case err == nil:
			return inserted, true, nil
		case errors.Is(err, ErrWalletTopUpNotFound):
			// The key was already claimed: RETURNING gave no row.
			existing, err := scanWalletTopUp(s.pool.QueryRow(
				ctx,
				`SELECT `+walletTopUpColumns+` FROM relay_wallet_topups t
				WHERE t.installation_id = $1 AND t.idempotency_key = $2`,
				prepared.InstallationID,
				prepared.IdempotencyKey,
			), false)
			if err != nil {
				return WalletTopUp{}, false, err
			}
			return existing, false, nil
		case code == pgForeignKeyViolation:
			return WalletTopUp{}, false, ErrNotFound
		case code == pgUniqueViolation && constraint == "relay_wallet_topups_invoice_no_key":
			continue
		default:
			return WalletTopUp{}, false, err
		}
	}
	return WalletTopUp{}, false, errors.New("could not mint a unique top-up invoice number")
}

func (s *PostgresStore) AttachWalletTopUpPayment(
	ctx context.Context,
	id, providerTransactionID, checkoutURL string,
) (WalletTopUp, error) {
	updated, err := scanWalletTopUp(s.pool.QueryRow(
		ctx,
		`UPDATE relay_wallet_topups AS t
		SET provider_transaction_id = $2, checkout_url = $3, updated_at = $4::timestamptz
		WHERE t.id = $1 AND t.status = 'pending' AND t.provider_transaction_id = ''
		RETURNING `+walletTopUpColumns,
		id,
		strings.TrimSpace(providerTransactionID),
		strings.TrimSpace(checkoutURL),
		s.clock.Now().UTC(),
	), false)
	if err == nil {
		return updated, nil
	}
	if !errors.Is(err, ErrWalletTopUpNotFound) {
		return WalletTopUp{}, err
	}
	return s.GetWalletTopUp(ctx, id)
}

// RecordWalletTopUpOTPAttempt counts the attempt in the same statement that
// checks the cap, so codes sent in parallel cannot slip past it.
func (s *PostgresStore) RecordWalletTopUpOTPAttempt(ctx context.Context, id string, limit int) (WalletTopUp, bool, error) {
	updated, err := scanWalletTopUp(s.pool.QueryRow(
		ctx,
		`UPDATE relay_wallet_topups AS t
		SET otp_attempts = t.otp_attempts + 1, updated_at = $3::timestamptz
		WHERE t.id = $1 AND t.status = 'pending' AND t.otp_attempts < $2
		RETURNING `+walletTopUpColumns,
		id,
		limit,
		s.clock.Now().UTC(),
	), false)
	if err == nil {
		return updated, true, nil
	}
	if !errors.Is(err, ErrWalletTopUpNotFound) {
		return WalletTopUp{}, false, err
	}
	existing, err := s.GetWalletTopUp(ctx, id)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	return existing, false, nil
}

func (s *PostgresStore) ListOpenWalletTopUps(ctx context.Context, createdAfter time.Time, limit int) ([]WalletTopUp, error) {
	rows, err := s.pool.Query(
		ctx,
		selectWalletTopUpWithShopSQL+`
		WHERE t.status IN ('pending', 'expired')
			AND t.created_at >= $1::timestamptz
			AND t.provider_transaction_id <> ''
		ORDER BY t.created_at DESC, t.id DESC
		LIMIT $2`,
		createdAfter.UTC(),
		normalizedWalletListLimit(limit),
	)
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

func (s *PostgresStore) GetWalletTopUp(ctx context.Context, id string) (WalletTopUp, error) {
	return scanWalletTopUp(s.pool.QueryRow(
		ctx,
		selectWalletTopUpWithShopSQL+` WHERE t.id = $1`,
		strings.TrimSpace(id),
	), true)
}

func (s *PostgresStore) FindWalletTopUpByInvoice(ctx context.Context, invoiceNo string) (WalletTopUp, error) {
	return scanWalletTopUp(s.pool.QueryRow(
		ctx,
		selectWalletTopUpWithShopSQL+` WHERE t.invoice_no = $1`,
		strings.TrimSpace(invoiceNo),
	), true)
}

func (s *PostgresStore) ListWalletTopUps(ctx context.Context, filter WalletTopUpFilter) ([]WalletTopUp, error) {
	var conditions []string
	var args []any
	if id := strings.TrimSpace(filter.InstallationID); id != "" {
		args = append(args, id)
		conditions = append(conditions, fmt.Sprintf("t.installation_id = $%d", len(args)))
	}
	if status := strings.TrimSpace(filter.Status); status != "" {
		args = append(args, status)
		conditions = append(conditions, fmt.Sprintf("t.status = $%d", len(args)))
	}
	if beforeID := strings.TrimSpace(filter.BeforeID); beforeID != "" {
		var cursorAt time.Time
		err := s.pool.QueryRow(ctx, `SELECT created_at FROM relay_wallet_topups WHERE id = $1`, beforeID).Scan(&cursorAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrWalletTopUpNotFound
		}
		if err != nil {
			return nil, err
		}
		args = append(args, cursorAt, beforeID)
		conditions = append(conditions, fmt.Sprintf("(t.created_at, t.id) < ($%d::timestamptz, $%d)", len(args)-1, len(args)))
	}
	query := selectWalletTopUpWithShopSQL
	if len(conditions) > 0 {
		query += " WHERE " + strings.Join(conditions, " AND ")
	}
	args = append(args, normalizedWalletListLimit(filter.Limit))
	query += fmt.Sprintf(" ORDER BY t.created_at DESC, t.id DESC LIMIT $%d", len(args))
	rows, err := s.pool.Query(ctx, query, args...)
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

func (s *PostgresStore) SettleWalletTopUp(
	ctx context.Context,
	id string,
	settlement WalletTopUpSettlement,
) (WalletTopUp, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	defer tx.Rollback(ctx)

	// Lock order is always top-up, then wallet (inside postWalletEntryTx); a
	// plain posting locks only the wallet, so the two never wait on each other
	// in a cycle.
	existing, err := scanWalletTopUp(tx.QueryRow(
		ctx,
		`SELECT `+walletTopUpColumns+` FROM relay_wallet_topups t WHERE t.id = $1 FOR UPDATE`,
		id,
	), false)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	if existing.Status == WalletTopUpPaid {
		if err := tx.Commit(ctx); err != nil {
			return WalletTopUp{}, false, err
		}
		return existing, false, nil
	}
	posting, err := prepareWalletPosting(walletTopUpCredit(existing, settlement))
	if err != nil {
		return WalletTopUp{}, false, err
	}
	entry, _, err := s.postWalletEntryTx(ctx, tx, posting)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	now := s.clock.Now().UTC()
	settled := applySettledAmount(existing, settlement)
	transfer, err := transferJSON(settled.Transfer)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	updated, err := scanWalletTopUp(tx.QueryRow(
		ctx,
		`UPDATE relay_wallet_topups AS t
		SET
			status = 'paid',
			amount = $6::text::numeric,
			transfer = $7::jsonb,
			provider_transaction_id = COALESCE(NULLIF($2, ''), t.provider_transaction_id),
			confirmed_by = $3,
			entry_id = $4,
			error_code = '',
			error_detail = '',
			paid_at = $5::timestamptz,
			updated_at = $5::timestamptz
		WHERE t.id = $1
		RETURNING `+walletTopUpColumns,
		id,
		strings.TrimSpace(settlement.ProviderTransactionID),
		strings.TrimSpace(settlement.ConfirmedBy),
		entry.ID,
		now,
		settled.Amount,
		transfer,
	), false)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return WalletTopUp{}, false, err
	}
	return updated, true, nil
}

func (s *PostgresStore) CloseWalletTopUp(
	ctx context.Context,
	id, status, code, detail string,
) (WalletTopUp, bool, error) {
	if err := validateWalletTopUpClosure(status); err != nil {
		return WalletTopUp{}, false, err
	}
	closed, err := scanWalletTopUp(s.pool.QueryRow(
		ctx,
		`UPDATE relay_wallet_topups AS t
		SET status = $2, error_code = $3, error_detail = $4, updated_at = $5::timestamptz
		WHERE t.id = $1 AND t.status IN ('pending', 'expired')
		RETURNING `+walletTopUpColumns,
		id,
		status,
		strings.TrimSpace(code),
		strings.TrimSpace(detail),
		s.clock.Now().UTC(),
	), false)
	if err == nil {
		return closed, true, nil
	}
	if !errors.Is(err, ErrWalletTopUpNotFound) {
		return WalletTopUp{}, false, err
	}
	// Already paid or closed (or not there at all): the first verdict stands.
	existing, err := s.GetWalletTopUp(ctx, id)
	if err != nil {
		return WalletTopUp{}, false, err
	}
	return existing, false, nil
}

func (s *PostgresStore) ExpireWalletTopUps(ctx context.Context, createdBefore time.Time) (int, error) {
	tag, err := s.pool.Exec(
		ctx,
		`UPDATE relay_wallet_topups
		SET status = 'expired', updated_at = $2::timestamptz
		WHERE status = 'pending' AND created_at < $1::timestamptz`,
		createdBefore.UTC(),
		s.clock.Now().UTC(),
	)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

func scanWalletEntry(row pgx.Row, withShop bool) (WalletEntry, error) {
	var entry WalletEntry
	dest := []any{
		&entry.ID,
		&entry.InstallationID,
		&entry.Account,
		&entry.Kind,
		&entry.Service,
		&entry.Amount,
		&entry.BalanceAfter,
		&entry.Reference,
		&entry.Description,
		&entry.IdempotencyKey,
		&entry.Actor,
		&entry.TestMode,
		&entry.CreatedAt,
	}
	if withShop {
		dest = append(dest, &entry.ShopName)
	}
	if err := row.Scan(dest...); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return WalletEntry{}, ErrWalletEntryNotFound
		}
		return WalletEntry{}, err
	}
	entry.Amount = NormalizeWalletAmount(entry.Amount)
	entry.BalanceAfter = NormalizeWalletAmount(entry.BalanceAfter)
	entry.CreatedAt = entry.CreatedAt.UTC()
	return entry, nil
}

func scanWalletTopUp(row pgx.Row, withShop bool) (WalletTopUp, error) {
	var topUp WalletTopUp
	var paidAt pgtype.Timestamptz
	var transfer []byte
	dest := []any{
		&topUp.ID,
		&topUp.InstallationID,
		&topUp.Method,
		&topUp.Amount,
		&topUp.Status,
		&topUp.InvoiceNo,
		&topUp.ProviderTransactionID,
		&topUp.CheckoutURL,
		&topUp.IdempotencyKey,
		&topUp.RequestedBy,
		&topUp.PayerHint,
		&topUp.OTPAttempts,
		&topUp.TestMode,
		&topUp.ErrorCode,
		&topUp.ErrorDetail,
		&topUp.EntryID,
		&topUp.ConfirmedBy,
		&topUp.CreatedAt,
		&topUp.UpdatedAt,
		&paidAt,
		&transfer,
	}
	if withShop {
		dest = append(dest, &topUp.ShopName)
	}
	if err := row.Scan(dest...); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return WalletTopUp{}, ErrWalletTopUpNotFound
		}
		return WalletTopUp{}, err
	}
	topUp.Amount = NormalizeWalletAmount(topUp.Amount)
	topUp.CreatedAt = topUp.CreatedAt.UTC()
	topUp.UpdatedAt = topUp.UpdatedAt.UTC()
	if paidAt.Valid {
		value := paidAt.Time.UTC()
		topUp.PaidAt = &value
	}
	if len(transfer) > 0 && string(transfer) != "null" {
		var details WalletBankTransfer
		if err := json.Unmarshal(transfer, &details); err != nil {
			return WalletTopUp{}, err
		}
		topUp.Transfer = &details
	}
	return topUp, nil
}
