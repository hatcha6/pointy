package control

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
)

// voucherStockFields are the columns scanVoucherStock reads, in order, without
// a table alias.
var voucherStockFields = []string{
	"id", "item_key", "code_sealed", "code_fingerprint", "code_mask", "serial", "cost::text",
	"COALESCE(to_char(expires_on, 'YYYY-MM-DD'), '')", "batch_id", "source", "note", "status", "purchase_id",
	"actor", "created_at", "sold_at", "voided_at", "voided_by", "void_reason",
	"returned_from", "returned_at", "returned_by", "return_reason",
}

// voucherStockColumns is voucherStockFields for a plain SELECT.
var voucherStockColumns = strings.Join(voucherStockFields, ", ")

// prefixedStockColumns is voucherStockFields on a table alias, for RETURNING
// in an UPDATE ... FROM where bare names would be ambiguous.
func prefixedStockColumns(alias string) string {
	out := make([]string, len(voucherStockFields))
	for i, field := range voucherStockFields {
		switch {
		case strings.HasPrefix(field, "COALESCE(to_char("):
			out[i] = strings.Replace(field, "to_char(", "to_char("+alias+".", 1)
		default:
			out[i] = alias + "." + field
		}
	}
	return strings.Join(out, ", ")
}

func scanVoucherStock(row pgx.Row) (VoucherStockCode, error) {
	var code VoucherStockCode
	err := row.Scan(&code.ID, &code.ItemKey, &code.Sealed, &code.Fingerprint, &code.Mask, &code.Serial, &code.Cost,
		&code.ExpiresOn, &code.BatchID, &code.Source, &code.Note, &code.Status, &code.PurchaseID, &code.Actor,
		&code.CreatedAt, &code.SoldAt, &code.VoidedAt, &code.VoidedBy, &code.VoidReason,
		&code.ReturnedFrom, &code.ReturnedAt, &code.ReturnedBy, &code.ReturnReason)
	return code, err
}

func collectVoucherStock(rows pgx.Rows) ([]VoucherStockCode, error) {
	defer rows.Close()
	out := []VoucherStockCode{}
	for rows.Next() {
		code, err := scanVoucherStock(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, code)
	}
	return out, rows.Err()
}

func nullableDate(day string) any {
	if day == "" {
		return nil
	}
	return day
}

func (s *PostgresStore) AddVoucherStock(ctx context.Context, batch VoucherStockBatch, dryRun bool) (VoucherStockBatch, error) {
	prepared, err := prepareVoucherStockBatch(batch, s.clock.Now())
	if err != nil {
		return VoucherStockBatch{}, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return VoucherStockBatch{}, err
	}
	defer tx.Rollback(ctx)

	fingerprints := make([]string, 0, len(prepared.Codes))
	for _, code := range prepared.Codes {
		fingerprints = append(fingerprints, code.Fingerprint)
	}
	rows, err := tx.Query(ctx, `SELECT `+voucherStockColumns+` FROM relay_voucher_stock WHERE code_fingerprint = ANY($1)`, fingerprints)
	if err != nil {
		return VoucherStockBatch{}, err
	}
	existing, err := collectVoucherStock(rows)
	if err != nil {
		return VoucherStockBatch{}, err
	}
	held := map[string]VoucherStockCode{}
	for _, code := range existing {
		held[code.Fingerprint] = code
	}
	if err := duplicateStockProblems(prepared, held); err != nil || dryRun {
		return prepared, err
	}

	batchRows := make([][]any, 0, len(prepared.Codes))
	for _, code := range prepared.Codes {
		batchRows = append(batchRows, []any{code.ID, code.ItemKey, code.Sealed, code.Fingerprint, code.Mask, code.Serial, code.Cost,
			nullableDate(code.ExpiresOn), code.BatchID, code.Source, code.Note, code.Status, code.Actor, code.CreatedAt})
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"relay_voucher_stock"},
		[]string{"id", "item_key", "code_sealed", "code_fingerprint", "code_mask", "serial", "cost", "expires_on",
			"batch_id", "source", "note", "status", "actor", "created_at"},
		pgx.CopyFromRows(batchRows)); err != nil {
		if code, _ := pgErrorCode(err); code == pgUniqueViolation {
			// Another save added one of these codes a moment ago.
			return VoucherStockBatch{}, &VoucherStockInvalidError{Problems: []VoucherStockProblem{{
				Field: "codes", Message: "one of these codes was added by another save just now; reload and try again",
			}}}
		}
		return VoucherStockBatch{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return VoucherStockBatch{}, err
	}
	return prepared, nil
}

func (s *PostgresStore) VoucherStockAvailable(ctx context.Context) (map[string]int, error) {
	rows, err := s.pool.Query(ctx, `
SELECT item_key, count(*) FROM relay_voucher_stock
WHERE status = 'available' AND (expires_on IS NULL OR expires_on >= $1::date)
GROUP BY item_key`, voucherStockToday(s.clock.Now()).Format("2006-01-02"))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	counts := map[string]int{}
	for rows.Next() {
		var item string
		var count int
		if err := rows.Scan(&item, &count); err != nil {
			return nil, err
		}
		counts[item] = count
	}
	return counts, rows.Err()
}

func (s *PostgresStore) VoucherStockLevels(ctx context.Context) ([]VoucherStockLevel, error) {
	rows, err := s.pool.Query(ctx, `
WITH judged AS (
	SELECT *, status = 'available' AND (expires_on IS NULL OR expires_on >= $1::date) AS usable
	FROM relay_voucher_stock
)
SELECT item_key,
	count(*) FILTER (WHERE usable),
	count(*) FILTER (WHERE status = 'available' AND NOT usable),
	count(*) FILTER (WHERE status = 'sold'),
	count(*) FILTER (WHERE status = 'void'),
	COALESCE(sum(cost) FILTER (WHERE usable), 0)::text,
	COALESCE(to_char(min(expires_on) FILTER (WHERE usable), 'YYYY-MM-DD'), ''),
	max(created_at)
FROM judged GROUP BY item_key ORDER BY item_key`, voucherStockToday(s.clock.Now()).Format("2006-01-02"))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []VoucherStockLevel{}
	for rows.Next() {
		var level VoucherStockLevel
		var cost string
		if err := rows.Scan(&level.ItemKey, &level.Available, &level.Expired, &level.Sold, &level.Voided,
			&cost, &level.NextExpiry, &level.LastAddedAt); err != nil {
			return nil, err
		}
		level.AvailableCost = NormalizeWalletAmount(cost)
		out = append(out, level)
	}
	return out, rows.Err()
}

func (s *PostgresStore) ListVoucherStock(ctx context.Context, filter VoucherStockFilter) ([]VoucherStockCode, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+voucherStockColumns+` FROM relay_voucher_stock
WHERE ($1 = '' OR item_key = $1) AND ($2 = '' OR status = $2) AND ($3 = '' OR batch_id = $3)
ORDER BY created_at DESC, id DESC LIMIT $4`,
		strings.TrimSpace(filter.ItemKey), strings.TrimSpace(filter.Status), strings.TrimSpace(filter.BatchID),
		normalizedVoucherStockLimit(filter.Limit))
	if err != nil {
		return nil, err
	}
	return collectVoucherStock(rows)
}

const selectStockForPurchaseSQL = ` FROM relay_voucher_stock
WHERE purchase_id = $1 AND status = 'sold' ORDER BY expires_on ASC NULLS LAST, created_at, id`

func (s *PostgresStore) ClaimVoucherStock(ctx context.Context, itemKey string, quantity int, purchaseID string) ([]VoucherStockCode, error) {
	itemKey, purchaseID = strings.TrimSpace(itemKey), strings.TrimSpace(purchaseID)
	if quantity < 1 || itemKey == "" || purchaseID == "" {
		return nil, errors.New("a stock claim needs an item, a quantity and a purchase")
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	rows, err := tx.Query(ctx, `SELECT `+voucherStockColumns+selectStockForPurchaseSQL, purchaseID)
	if err != nil {
		return nil, err
	}
	sold, err := collectVoucherStock(rows)
	if err != nil {
		return nil, err
	}
	if len(sold) > 0 {
		return sold, nil
	}
	// SKIP LOCKED: two purchases of the same card at once take different
	// codes instead of waiting on each other.
	rows, err = tx.Query(ctx, `
WITH picked AS (
	SELECT id FROM relay_voucher_stock
	WHERE item_key = $1 AND status = 'available' AND (expires_on IS NULL OR expires_on >= $3::date)
	ORDER BY expires_on ASC NULLS LAST, created_at, id
	LIMIT $2
	FOR UPDATE SKIP LOCKED
)
UPDATE relay_voucher_stock AS s SET status = 'sold', purchase_id = $4, sold_at = $5
FROM picked WHERE s.id = picked.id
RETURNING `+prefixedStockColumns("s"),
		itemKey, quantity, voucherStockToday(s.clock.Now()).Format("2006-01-02"), purchaseID, s.clock.Now().UTC())
	if err != nil {
		return nil, err
	}
	claimed, err := collectVoucherStock(rows)
	if err != nil {
		return nil, err
	}
	if len(claimed) < quantity {
		return nil, ErrVoucherStockShort
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	voucherStockClaimOrder(claimed)
	return claimed, nil
}

func (s *PostgresStore) VoucherStockForPurchase(ctx context.Context, purchaseID string) ([]VoucherStockCode, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+voucherStockColumns+selectStockForPurchaseSQL, strings.TrimSpace(purchaseID))
	if err != nil {
		return nil, err
	}
	return collectVoucherStock(rows)
}

func (s *PostgresStore) VoidVoucherStock(ctx context.Context, id, actor, reason string) (VoucherStockCode, error) {
	id = strings.TrimSpace(id)
	code, err := scanVoucherStock(s.pool.QueryRow(ctx, `
UPDATE relay_voucher_stock SET status = 'void', voided_at = $2, voided_by = $3, void_reason = $4
WHERE id = $1 AND status = 'available'
RETURNING `+voucherStockColumns,
		id, s.clock.Now().UTC(),
		truncateRunes(strings.TrimSpace(actor), maxVoucherStockText),
		truncateRunes(strings.TrimSpace(reason), maxVoucherStockText)))
	if err == nil {
		return code, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return VoucherStockCode{}, err
	}
	current, err := scanVoucherStock(s.pool.QueryRow(ctx, `SELECT `+voucherStockColumns+` FROM relay_voucher_stock WHERE id = $1`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return VoucherStockCode{}, ErrVoucherStockNotFound
	}
	if err != nil {
		return VoucherStockCode{}, err
	}
	return current, ErrVoucherStockNotAvailable
}

func (s *PostgresStore) RefundVoucherStockSale(ctx context.Context, purchaseID string, ret VoucherStockReturn) (VoucherStockRefund, error) {
	purchaseID = strings.TrimSpace(purchaseID)
	ret = prepareVoucherStockReturn(ret)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return VoucherStockRefund{}, err
	}
	defer tx.Rollback(ctx)

	// The purchase first, then its codes: the order every refund takes, so two
	// refunds of one sale queue rather than deadlock.
	existing, err := scanVoucherPurchase(tx.QueryRow(ctx, selectVoucherPurchaseSQL+` WHERE p.id = $1 FOR UPDATE`, purchaseID), false)
	if errors.Is(err, pgx.ErrNoRows) {
		return VoucherStockRefund{}, ErrVoucherPurchaseNotFound
	}
	if err != nil {
		return VoucherStockRefund{}, err
	}
	if err := checkVoucherStockSale(existing); err != nil {
		return VoucherStockRefund{}, err
	}
	rows, err := tx.Query(ctx, `SELECT `+voucherStockColumns+selectStockForPurchaseSQL+` FOR UPDATE`, purchaseID)
	if err != nil {
		return VoucherStockRefund{}, err
	}
	sold, err := collectVoucherStock(rows)
	if err != nil {
		return VoucherStockRefund{}, err
	}
	if len(sold) == 0 {
		return VoucherStockRefund{}, ErrVoucherStockReturned
	}
	now := s.clock.Now()
	result := VoucherStockRefund{Purchase: existing}
	if existing.Status == VoucherPurchaseSucceeded {
		posting, err := prepareWalletPosting(voucherStockRefundPosting(existing))
		if err != nil {
			return VoucherStockRefund{}, err
		}
		_, created, err := s.postWalletEntryTx(ctx, tx, posting)
		if err != nil {
			return VoucherStockRefund{}, err
		}
		result.Refunded = created
		updated := refundedVoucherStockSale(existing, ret, now)
		result.Purchase, err = scanVoucherPurchase(tx.QueryRow(ctx,
			`UPDATE relay_voucher_purchases AS p SET error_detail = $2, updated_at = $3::timestamptz
			WHERE p.id = $1 RETURNING `+voucherPurchaseColumns,
			purchaseID, updated.ErrorDetail, updated.UpdatedAt), false)
		if err != nil {
			return VoucherStockRefund{}, err
		}
	}
	for _, code := range sold {
		returned := returnVoucherStockCode(code, purchaseID, ret, now)
		stored, err := scanVoucherStock(tx.QueryRow(ctx, `
UPDATE relay_voucher_stock SET status = $2, purchase_id = '', sold_at = NULL,
	voided_at = $3, voided_by = $4, void_reason = $5,
	returned_from = $6, returned_at = $7, returned_by = $8, return_reason = $9
WHERE id = $1
RETURNING `+voucherStockColumns,
			code.ID, returned.Status, returned.VoidedAt, returned.VoidedBy, returned.VoidReason,
			returned.ReturnedFrom, returned.ReturnedAt, returned.ReturnedBy, returned.ReturnReason))
		if err != nil {
			return VoucherStockRefund{}, err
		}
		result.Codes = append(result.Codes, stored)
	}
	if err := tx.Commit(ctx); err != nil {
		return VoucherStockRefund{}, err
	}
	return result, nil
}
