package control

import (
	"context"
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
	t.test_mode,
	t.error_code,
	t.error_detail,
	t.entry_id,
	t.confirmed_by,
	t.created_at,
	t.updated_at,
	t.paid_at`

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

func (s *PostgresStore) GetWallet(ctx context.Context, installationID string) (Wallet, error) {
	installationID = strings.TrimSpace(installationID)
	var balance string
	var updatedAt time.Time
	err := s.pool.QueryRow(
		ctx,
		`SELECT balance::text, updated_at FROM relay_wallets WHERE installation_id = $1`,
		installationID,
	).Scan(&balance, &updatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Wallet{InstallationID: installationID, Balance: FormatWalletAmount(nil)}, nil
	}
	if err != nil {
		return Wallet{}, err
	}
	updated := updatedAt.UTC()
	return Wallet{InstallationID: installationID, Balance: NormalizeWalletAmount(balance), UpdatedAt: &updated}, nil
}

func (s *PostgresStore) ListWallets(ctx context.Context, limit int) ([]Wallet, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT w.installation_id, COALESCE(i.shop_name, ''), w.balance::text, w.updated_at
		FROM relay_wallets w
		LEFT JOIN relay_installations i ON i.id = w.installation_id
		ORDER BY w.balance DESC, w.installation_id
		LIMIT $1`,
		normalizedWalletListLimit(limit),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	wallets := []Wallet{}
	for rows.Next() {
		var wallet Wallet
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
// transaction. It locks the shop's wallet row first, so the idempotency
// check, the balance check and the insert are one step: two debits racing for
// the last dinar cannot both get it, and a retried key cannot slip between.
func (s *PostgresStore) postWalletEntryTx(
	ctx context.Context,
	tx pgx.Tx,
	posting preparedWalletPosting,
) (WalletEntry, bool, error) {
	now := s.clock.Now().UTC()
	if _, err := tx.Exec(
		ctx,
		`INSERT INTO relay_wallets (installation_id, balance, created_at, updated_at)
		VALUES ($1, 0, $2::timestamptz, $2::timestamptz)
		ON CONFLICT (installation_id) DO NOTHING`,
		posting.InstallationID,
		now,
	); err != nil {
		if code, _ := pgErrorCode(err); code == pgForeignKeyViolation {
			return WalletEntry{}, false, ErrNotFound
		}
		return WalletEntry{}, false, err
	}
	var balanceText string
	if err := tx.QueryRow(
		ctx,
		`SELECT balance::text FROM relay_wallets WHERE installation_id = $1 FOR UPDATE`,
		posting.InstallationID,
	).Scan(&balanceText); err != nil {
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
	balance, ok := new(big.Rat).SetString(balanceText)
	if !ok {
		return WalletEntry{}, false, fmt.Errorf("stored wallet balance %q is not a decimal", balanceText)
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
			id, installation_id, kind, service, amount, balance_after, reference,
			description, idempotency_key, actor, test_mode, created_at
		) VALUES (
			$1, $2, $3, $4, $5::text::numeric, $6::text::numeric, $7,
			$8, $9, $10, $11, $12::timestamptz
		) RETURNING `+walletEntryColumns,
		entry.ID,
		entry.InstallationID,
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
	if _, err := tx.Exec(
		ctx,
		`UPDATE relay_wallets SET balance = $2::text::numeric, updated_at = $3::timestamptz
		WHERE installation_id = $1`,
		posting.InstallationID,
		FormatWalletAmount(next),
		now,
	); err != nil {
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

func (s *PostgresStore) BeginWalletTopUp(ctx context.Context, topUp WalletTopUp) (WalletTopUp, bool, error) {
	// An invoice number clash is 1 in 32^10 per pair; a fresh draw settles it.
	for attempt := 0; attempt < 3; attempt++ {
		prepared, err := prepareWalletTopUp(topUp, s.clock.Now())
		if err != nil {
			return WalletTopUp{}, false, err
		}
		inserted, err := scanWalletTopUp(s.pool.QueryRow(
			ctx,
			`INSERT INTO relay_wallet_topups AS t (
				id, installation_id, method, amount, status, invoice_no,
				provider_transaction_id, checkout_url, idempotency_key, requested_by,
				test_mode, error_code, error_detail, entry_id, confirmed_by,
				created_at, updated_at, paid_at
			) VALUES (
				$1, $2, $3, $4::text::numeric, $5, $6,
				'', '', $7, $8,
				$9, '', '', '', '',
				$10::timestamptz, $10::timestamptz, NULL
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
			prepared.TestMode,
			prepared.CreatedAt,
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

func (s *PostgresStore) AttachWalletTopUpCheckout(ctx context.Context, id, checkoutURL string) (WalletTopUp, error) {
	updated, err := scanWalletTopUp(s.pool.QueryRow(
		ctx,
		`UPDATE relay_wallet_topups AS t
		SET checkout_url = $2, updated_at = $3::timestamptz
		WHERE t.id = $1 AND t.status = 'pending' AND t.checkout_url = ''
		RETURNING `+walletTopUpColumns,
		id,
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
	updated, err := scanWalletTopUp(tx.QueryRow(
		ctx,
		`UPDATE relay_wallet_topups AS t
		SET
			status = 'paid',
			provider_transaction_id = $2,
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
		&topUp.TestMode,
		&topUp.ErrorCode,
		&topUp.ErrorDetail,
		&topUp.EntryID,
		&topUp.ConfirmedBy,
		&topUp.CreatedAt,
		&topUp.UpdatedAt,
		&paidAt,
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
	return topUp, nil
}
