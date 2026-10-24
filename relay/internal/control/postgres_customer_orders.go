package control

import (
	"context"
	"errors"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const selectCustomerOrderColumns = `id, customer_id, idempotency_key, channel, item_key, brand_key, item_name,
	quantity, unit_price::text, total::text, credit_used::text, amount_due::text, fee::text, method, payer_hint,
	payment_id, checkout_url, otp_attempts, status, error_code, error_detail, purchase_id, late_paid,
	test_mode, created_at, updated_at, paid_at, completed_at, review`

func scanCustomerOrder(row pgx.Row) (CustomerOrder, error) {
	var order CustomerOrder
	if err := row.Scan(
		&order.ID, &order.CustomerID, &order.IdempotencyKey, &order.Channel, &order.ItemKey, &order.BrandKey,
		&order.ItemName, &order.Quantity, &order.UnitPrice, &order.Total, &order.CreditUsed, &order.AmountDue,
		&order.Fee, &order.Method, &order.PayerHint, &order.PaymentID, &order.CheckoutURL, &order.OTPAttempts, &order.Status,
		&order.ErrorCode, &order.ErrorDetail, &order.PurchaseID, &order.LatePaid, &order.TestMode,
		&order.CreatedAt, &order.UpdatedAt, &order.PaidAt, &order.CompletedAt, &order.Review,
	); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return CustomerOrder{}, ErrCustomerOrderNotFound
		}
		return CustomerOrder{}, err
	}
	order.UnitPrice = NormalizeWalletAmount(order.UnitPrice)
	order.Total = NormalizeWalletAmount(order.Total)
	order.CreditUsed = NormalizeWalletAmount(order.CreditUsed)
	order.AmountDue = NormalizeWalletAmount(order.AmountDue)
	order.Fee = NormalizeWalletAmount(order.Fee)
	order.CreatedAt = order.CreatedAt.UTC()
	order.UpdatedAt = order.UpdatedAt.UTC()
	if order.PaidAt != nil {
		paid := order.PaidAt.UTC()
		order.PaidAt = &paid
	}
	if order.CompletedAt != nil {
		completed := order.CompletedAt.UTC()
		order.CompletedAt = &completed
	}
	return order, nil
}

func insertCustomerCreditTx(ctx context.Context, tx pgx.Tx, entry *CustomerCreditEntry) error {
	if entry == nil {
		return nil
	}
	id, err := NewInstallationID()
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx,
		`INSERT INTO relay_customer_credit_entries (id, customer_id, kind, amount, order_id, test_mode, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (order_id, kind) WHERE order_id <> '' DO NOTHING`,
		id, entry.CustomerID, entry.Kind, entry.Amount, entry.OrderID, entry.TestMode, entry.CreatedAt,
	)
	return err
}

func customerCreditBalanceTx(ctx context.Context, tx pgx.Tx, customerID string) (*big.Rat, error) {
	var raw string
	if err := tx.QueryRow(ctx,
		`SELECT COALESCE(SUM(amount), 0)::text FROM relay_customer_credit_entries WHERE customer_id = $1`, customerID,
	).Scan(&raw); err != nil {
		return nil, err
	}
	balance, ok := new(big.Rat).SetString(raw)
	if !ok {
		return new(big.Rat), nil
	}
	return balance, nil
}

func (s *PostgresStore) BeginCustomerOrder(ctx context.Context, order CustomerOrder, useCredit bool) (CustomerOrder, bool, error) {
	order, total, err := normalizeCustomerOrder(order)
	if err != nil {
		return CustomerOrder{}, false, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerOrder{}, false, err
	}
	defer tx.Rollback(ctx)
	// The customer's row serializes their orders, so two at once cannot both
	// spend the same credit.
	var deleted *time.Time
	err = tx.QueryRow(ctx, `SELECT deleted_at FROM relay_customers WHERE id = $1 FOR UPDATE`, order.CustomerID).Scan(&deleted)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && deleted != nil) {
		return CustomerOrder{}, false, ErrCustomerNotFound
	}
	if err != nil {
		return CustomerOrder{}, false, err
	}
	existing, err := scanCustomerOrder(tx.QueryRow(ctx,
		`SELECT `+selectCustomerOrderColumns+` FROM relay_customer_orders WHERE customer_id = $1 AND idempotency_key = $2`,
		order.CustomerID, order.IdempotencyKey))
	if err == nil {
		if !sameCustomerOrder(existing, order) {
			return existing, false, ErrCustomerOrderKeyReused
		}
		return existing, false, nil
	}
	if !errors.Is(err, ErrCustomerOrderNotFound) {
		return CustomerOrder{}, false, err
	}
	balance, err := customerCreditBalanceTx(ctx, tx, order.CustomerID)
	if err != nil {
		return CustomerOrder{}, false, err
	}
	placed, entry := placeCustomerOrder(order, total, balance, useCredit, s.clock.Now().UTC())
	if err := writeCustomerOrderTx(ctx, tx, placed, true); err != nil {
		return CustomerOrder{}, false, err
	}
	if err := insertCustomerCreditTx(ctx, tx, entry); err != nil {
		return CustomerOrder{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return CustomerOrder{}, false, err
	}
	return placed, true, nil
}

func writeCustomerOrderTx(ctx context.Context, tx pgx.Tx, order CustomerOrder, insert bool) error {
	args := []any{
		order.ID, order.CustomerID, order.IdempotencyKey, order.Channel, order.ItemKey, order.BrandKey, order.ItemName,
		order.Quantity, order.UnitPrice, order.Total, order.CreditUsed, order.AmountDue, order.Method, order.PayerHint,
		order.PaymentID, order.CheckoutURL, order.OTPAttempts, order.Status, order.ErrorCode, order.ErrorDetail,
		order.PurchaseID, order.LatePaid, order.TestMode, order.CreatedAt, order.UpdatedAt, order.PaidAt, order.CompletedAt,
		order.Fee, order.Review,
	}
	if insert {
		_, err := tx.Exec(ctx,
			`INSERT INTO relay_customer_orders (id, customer_id, idempotency_key, channel, item_key, brand_key, item_name,
				quantity, unit_price, total, credit_used, amount_due, method, payer_hint, payment_id, checkout_url,
				otp_attempts, status, error_code, error_detail, purchase_id, late_paid, test_mode, created_at,
				updated_at, paid_at, completed_at, fee, review)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20,
				$21, $22, $23, $24, $25, $26, $27, $28, $29)`, args...)
		return err
	}
	// Only what a transition may change is written back.
	_, err := tx.Exec(ctx,
		`UPDATE relay_customer_orders SET payment_id = $2, checkout_url = $3, otp_attempts = $4, status = $5,
			error_code = $6, error_detail = $7, purchase_id = $8, late_paid = $9, updated_at = $10,
			paid_at = $11, completed_at = $12
		WHERE id = $1`,
		order.ID, order.PaymentID, order.CheckoutURL, order.OTPAttempts, order.Status, order.ErrorCode,
		order.ErrorDetail, order.PurchaseID, order.LatePaid, order.UpdatedAt, order.PaidAt, order.CompletedAt)
	return err
}

// mutateCustomerOrder runs one transition on the locked row.
func (s *PostgresStore) mutateCustomerOrder(
	ctx context.Context,
	id string,
	change func(CustomerOrder, time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error),
) (CustomerOrder, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerOrder{}, false, err
	}
	defer tx.Rollback(ctx)
	order, err := scanCustomerOrder(tx.QueryRow(ctx,
		`SELECT `+selectCustomerOrderColumns+` FROM relay_customer_orders WHERE id = $1 FOR UPDATE`, id))
	if err != nil {
		return CustomerOrder{}, false, err
	}
	next, entry, applied, err := change(order, s.clock.Now().UTC())
	if err != nil || !applied {
		return order, false, err
	}
	if err := writeCustomerOrderTx(ctx, tx, next, false); err != nil {
		return CustomerOrder{}, false, err
	}
	if err := insertCustomerCreditTx(ctx, tx, entry); err != nil {
		return CustomerOrder{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return CustomerOrder{}, false, err
	}
	return next, true, nil
}

func (s *PostgresStore) AttachCustomerOrderPayment(ctx context.Context, id, paymentID, checkoutURL string) (CustomerOrder, error) {
	order, _, err := s.mutateCustomerOrder(ctx, id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		if order.Status != CustomerOrderAwaitingPayment || order.PaymentID != "" {
			return order, nil, false, nil
		}
		order.PaymentID, order.CheckoutURL, order.UpdatedAt = paymentID, checkoutURL, now
		return order, nil, true, nil
	})
	return order, err
}

func (s *PostgresStore) RecordCustomerOrderOTPAttempt(ctx context.Context, id string, limit int) (CustomerOrder, bool, error) {
	return s.mutateCustomerOrder(ctx, id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		if order.Status != CustomerOrderAwaitingPayment || order.OTPAttempts >= limit {
			return order, nil, false, nil
		}
		order.OTPAttempts++
		order.UpdatedAt = now
		return order, nil, true, nil
	})
}

func (s *PostgresStore) PayCustomerOrder(ctx context.Context, id, paymentID string) (CustomerOrder, bool, error) {
	return s.mutateCustomerOrder(ctx, id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		next, entry, applied := payCustomerOrder(order, paymentID, now)
		return next, entry, applied, nil
	})
}

func (s *PostgresStore) HoldCustomerOrderPayment(ctx context.Context, id, detail string) (CustomerOrder, bool, error) {
	return s.mutateCustomerOrder(ctx, id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		next, entry, applied := holdCustomerOrderPayment(order, detail, now)
		return next, entry, applied, nil
	})
}

func (s *PostgresStore) CloseCustomerOrder(ctx context.Context, id, status, code, detail string) (CustomerOrder, bool, error) {
	return s.mutateCustomerOrder(ctx, id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		return closeCustomerOrder(order, status, code, detail, now)
	})
}

func (s *PostgresStore) StartCustomerOrderFulfilment(ctx context.Context, id, purchaseID string) (CustomerOrder, error) {
	order, _, err := s.mutateCustomerOrder(ctx, id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		next := startCustomerOrderFulfilment(order, purchaseID, now)
		return next, nil, next.Status != order.Status || next.PurchaseID != order.PurchaseID, nil
	})
	return order, err
}

func (s *PostgresStore) FinishCustomerOrder(ctx context.Context, id string, delivered bool, code, detail string) (CustomerOrder, bool, error) {
	return s.mutateCustomerOrder(ctx, id, func(order CustomerOrder, now time.Time) (CustomerOrder, *CustomerCreditEntry, bool, error) {
		next, entry, applied := finishCustomerOrder(order, delivered, code, detail, now)
		return next, entry, applied, nil
	})
}

func (s *PostgresStore) GetCustomerOrder(ctx context.Context, id string) (CustomerOrder, error) {
	return scanCustomerOrder(s.pool.QueryRow(ctx,
		`SELECT `+selectCustomerOrderColumns+` FROM relay_customer_orders WHERE id = $1`, id))
}

func (s *PostgresStore) FindCustomerOrderByKey(ctx context.Context, customerID, key string) (CustomerOrder, error) {
	return scanCustomerOrder(s.pool.QueryRow(ctx,
		`SELECT `+selectCustomerOrderColumns+` FROM relay_customer_orders WHERE customer_id = $1 AND idempotency_key = $2`,
		customerID, strings.TrimSpace(key)))
}

func (s *PostgresStore) ListCustomerOrders(ctx context.Context, filter CustomerOrderFilter) ([]CustomerOrder, error) {
	limit := filter.Limit
	if limit <= 0 {
		limit = 1000
	}
	var createdAfter *time.Time
	if !filter.CreatedAfter.IsZero() {
		createdAfter = &filter.CreatedAfter
	}
	rows, err := s.pool.Query(ctx,
		`SELECT `+selectCustomerOrderColumns+` FROM relay_customer_orders
		WHERE ($1 = '' OR customer_id = $1)
			AND (NOT $2 OR status IN ('awaiting_payment', 'paid', 'fulfilling'))
			AND ($3::timestamptz IS NULL OR created_at >= $3)
			AND (NOT $5 OR status IN ('awaiting_payment', 'paid', 'fulfilling')
				OR (status IN ('cancelled', 'failed', 'expired') AND payment_id <> '' AND checkout_url <> ''
					AND NOT late_paid AND error_code <> 'payment_mismatch'))
		ORDER BY created_at DESC, id DESC LIMIT $4`,
		filter.CustomerID, filter.Open, createdAfter, limit, filter.Sweep)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	orders := []CustomerOrder{}
	for rows.Next() {
		order, err := scanCustomerOrder(rows)
		if err != nil {
			return nil, err
		}
		orders = append(orders, order)
	}
	return orders, rows.Err()
}

func (s *PostgresStore) ExpireCustomerOrders(ctx context.Context, createdBefore time.Time) (int, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id FROM relay_customer_orders WHERE status = 'awaiting_payment' AND created_at < $1`, createdBefore)
	if err != nil {
		return 0, err
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	count := 0
	for _, id := range ids {
		_, applied, err := s.CloseCustomerOrder(ctx, id, CustomerOrderExpired, "expired", "the payment was not completed in time")
		if err != nil {
			return count, err
		}
		if applied {
			count++
		}
	}
	return count, nil
}

func (s *PostgresStore) CustomerCredit(ctx context.Context, customerID string, limit int) (string, []CustomerCreditEntry, error) {
	if limit <= 0 {
		limit = 50
	}
	var balance string
	if err := s.pool.QueryRow(ctx,
		`SELECT COALESCE(SUM(amount), 0)::text FROM relay_customer_credit_entries WHERE customer_id = $1`, customerID,
	).Scan(&balance); err != nil {
		return "", nil, err
	}
	rows, err := s.pool.Query(ctx,
		`SELECT id, customer_id, kind, amount::text, order_id, test_mode, created_at
		FROM relay_customer_credit_entries WHERE customer_id = $1
		ORDER BY created_at DESC, id DESC LIMIT $2`, customerID, limit)
	if err != nil {
		return "", nil, err
	}
	defer rows.Close()
	entries := []CustomerCreditEntry{}
	for rows.Next() {
		var entry CustomerCreditEntry
		if err := rows.Scan(&entry.ID, &entry.CustomerID, &entry.Kind, &entry.Amount, &entry.OrderID,
			&entry.TestMode, &entry.CreatedAt); err != nil {
			return "", nil, err
		}
		entry.Amount = NormalizeWalletAmount(entry.Amount)
		entry.CreatedAt = entry.CreatedAt.UTC()
		entries = append(entries, entry)
	}
	return NormalizeWalletAmount(balance), entries, rows.Err()
}
