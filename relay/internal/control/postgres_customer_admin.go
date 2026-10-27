package control

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

var _ CustomerAdminStore = (*PostgresStore)(nil)

// likePattern is a case-insensitive LIKE pattern finding query anywhere,
// its own wildcards taken literally; "" for no query.
func likePattern(query string) string {
	query = strings.ToLower(strings.TrimSpace(query))
	if query == "" {
		return ""
	}
	escaped := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(query)
	return "%" + escaped + "%"
}

// customerSummarySQL is every customer with their orders, credit and devices
// folded in. $1 is now (for live sessions).
const customerSummarySQL = `
SELECT c.id, coalesce(c.phone, ''), c.created_at, c.last_sign_in_at, c.deleted_at, c.blocked_at, c.blocked_reason,
	coalesce(o.orders, 0), coalesce(o.delivered, 0), coalesce(o.spent, 0)::text, o.last_order_at,
	coalesce(cr.balance, 0)::text,
	coalesce(s.devices, 0), coalesce(s.push, 0), coalesce(s.platforms, ''), s.last_seen_at
FROM relay_customers c
LEFT JOIN LATERAL (
	SELECT count(*) AS orders,
		count(*) FILTER (WHERE status = 'delivered') AS delivered,
		sum(total) FILTER (WHERE status = 'delivered' AND NOT test_mode AND NOT review) AS spent,
		max(created_at) AS last_order_at
	FROM relay_customer_orders WHERE customer_id = c.id
) o ON true
LEFT JOIN LATERAL (
	SELECT sum(amount) AS balance FROM relay_customer_credit_entries WHERE customer_id = c.id
) cr ON true
LEFT JOIN LATERAL (
	SELECT count(*) AS devices,
		count(*) FILTER (WHERE push_token <> '') AS push,
		string_agg(DISTINCT nullif(platform, ''), ',' ORDER BY nullif(platform, '')) AS platforms,
		max(last_seen_at) AS last_seen_at
	FROM relay_customer_sessions WHERE customer_id = c.id AND expires_at > $1
) s ON true`

func scanCustomerSummary(row pgx.Row) (CustomerSummary, error) {
	var summary CustomerSummary
	c := &summary.Customer
	if err := row.Scan(&c.ID, &c.Phone, &c.CreatedAt, &c.LastSignInAt, &c.DeletedAt, &c.BlockedAt, &c.BlockedReason,
		&summary.Orders, &summary.Delivered, &summary.Spent, &summary.LastOrderAt, &summary.Credit,
		&summary.Devices, &summary.PushDevices, &summary.Platforms, &summary.LastSeenAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return CustomerSummary{}, ErrCustomerNotFound
		}
		return CustomerSummary{}, err
	}
	c.CreatedAt = c.CreatedAt.UTC()
	c.LastSignInAt = c.LastSignInAt.UTC()
	for _, at := range []**time.Time{&c.DeletedAt, &c.BlockedAt, &summary.LastOrderAt, &summary.LastSeenAt} {
		if *at != nil {
			utc := (**at).UTC()
			*at = &utc
		}
	}
	summary.Spent = NormalizeWalletAmount(summary.Spent)
	summary.Credit = NormalizeWalletAmount(summary.Credit)
	return summary, nil
}

// customerSegmentSQL keeps one segment of the summary (CustomerListFilter).
const customerSegmentSQL = `
	($4 = 'all'
	OR ($4 = 'buyers' AND c.deleted_at IS NULL AND coalesce(o.delivered, 0) > 0)
	OR ($4 = 'blocked' AND c.blocked_at IS NOT NULL)
	OR ($4 = 'deleted' AND c.deleted_at IS NOT NULL)
	OR ($4 NOT IN ('all', 'buyers', 'blocked', 'deleted') AND c.deleted_at IS NULL))`

func (s *PostgresStore) ListCustomers(ctx context.Context, filter CustomerListFilter) ([]CustomerSummary, int, error) {
	limit := filter.Limit
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	query := strings.TrimSpace(filter.Query)
	phone := customerPhoneQuery(query)
	where := `
WHERE ($2 = '' OR c.id = $2 OR ($3 <> '' AND c.phone LIKE '%' || $3 || '%')) AND` + customerSegmentSQL
	now := s.clock.Now().UTC()
	var total int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM (`+customerSummarySQL+where+`) counted`,
		now, query, phone, filter.Segment).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := s.pool.Query(ctx, customerSummarySQL+where+`
ORDER BY c.last_sign_in_at DESC, c.id LIMIT $5 OFFSET $6`,
		now, query, phone, filter.Segment, limit, max(filter.Offset, 0))
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	list := []CustomerSummary{}
	for rows.Next() {
		summary, err := scanCustomerSummary(rows)
		if err != nil {
			return nil, 0, err
		}
		list = append(list, summary)
	}
	return list, total, rows.Err()
}

func (s *PostgresStore) CustomerSummaryByID(ctx context.Context, id string) (CustomerSummary, error) {
	return scanCustomerSummary(s.pool.QueryRow(ctx, customerSummarySQL+` WHERE c.id = $2`, s.clock.Now().UTC(), id))
}

func (s *PostgresStore) CustomerStats(ctx context.Context) (CustomerStats, error) {
	now := s.clock.Now().UTC()
	stats := CustomerStats{GeneratedAt: now}
	err := s.pool.QueryRow(ctx, `
SELECT count(*),
	count(*) FILTER (WHERE created_at >= $2),
	count(*) FILTER (WHERE greatest(last_sign_in_at, coalesce(last_seen_at, last_sign_in_at)) >= $3),
	count(*) FILTER (WHERE delivered > 0),
	count(*) FILTER (WHERE blocked_at IS NOT NULL),
	count(*) FILTER (WHERE push > 0),
	coalesce(sum(spent), 0)::text,
	coalesce(sum(balance), 0)::text
FROM (
	SELECT c.created_at, c.last_sign_in_at, c.blocked_at, s.last_seen_at, s.push,
		coalesce(o.delivered, 0) AS delivered, o.spent, cr.balance
	FROM relay_customers c
	LEFT JOIN LATERAL (
		SELECT count(*) FILTER (WHERE status = 'delivered') AS delivered,
			sum(total) FILTER (WHERE status = 'delivered' AND NOT test_mode AND NOT review) AS spent
		FROM relay_customer_orders WHERE customer_id = c.id
	) o ON true
	LEFT JOIN LATERAL (
		SELECT sum(amount) AS balance FROM relay_customer_credit_entries WHERE customer_id = c.id
	) cr ON true
	LEFT JOIN LATERAL (
		SELECT max(last_seen_at) AS last_seen_at, count(*) FILTER (WHERE push_token <> '') AS push
		FROM relay_customer_sessions WHERE customer_id = c.id AND expires_at > $1
	) s ON true
	WHERE c.deleted_at IS NULL
) live`, now, now.Add(-7*24*time.Hour), now.Add(-30*24*time.Hour)).Scan(
		&stats.Customers, &stats.New7d, &stats.Active30d, &stats.Buyers, &stats.Blocked, &stats.WithPush,
		&stats.Spent, &stats.CreditOwed)
	if err != nil {
		return CustomerStats{}, err
	}
	if err := s.pool.QueryRow(ctx, `
SELECT count(*) FILTER (WHERE status IN ('awaiting_payment', 'paid', 'fulfilling')),
	count(*) FILTER (WHERE created_at >= $1)
FROM relay_customer_orders`, now.Add(-30*24*time.Hour)).Scan(&stats.OpenOrders, &stats.Orders30d); err != nil {
		return CustomerStats{}, err
	}
	stats.Spent = NormalizeWalletAmount(stats.Spent)
	stats.CreditOwed = NormalizeWalletAmount(stats.CreditOwed)
	return stats, nil
}

func (s *PostgresStore) SetCustomerBlocked(ctx context.Context, id string, blocked bool, reason string) (Customer, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Customer{}, err
	}
	defer tx.Rollback(ctx)
	var customer Customer
	if blocked {
		customer, err = scanCustomer(tx.QueryRow(ctx,
			`UPDATE relay_customers SET blocked_at = coalesce(blocked_at, $2), blocked_reason = $3
			WHERE id = $1 AND deleted_at IS NULL RETURNING `+selectCustomerColumns,
			id, s.clock.Now().UTC(), truncateRunes(strings.TrimSpace(reason), 300)))
		if err == nil {
			_, err = tx.Exec(ctx, `DELETE FROM relay_customer_sessions WHERE customer_id = $1`, id)
		}
	} else {
		customer, err = scanCustomer(tx.QueryRow(ctx,
			`UPDATE relay_customers SET blocked_at = NULL, blocked_reason = ''
			WHERE id = $1 AND deleted_at IS NULL RETURNING `+selectCustomerColumns, id))
	}
	if err != nil {
		return Customer{}, err
	}
	return customer, tx.Commit(ctx)
}

func (s *PostgresStore) AdjustCustomerCredit(ctx context.Context, change CustomerCreditChange) (CustomerCreditEntry, string, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerCreditEntry{}, "", false, err
	}
	defer tx.Rollback(ctx)
	// The customer row is the lock every credit change of theirs waits on.
	var live bool
	err = tx.QueryRow(ctx,
		`SELECT deleted_at IS NULL FROM relay_customers WHERE id = $1 FOR UPDATE`, change.CustomerID).Scan(&live)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !live) {
		return CustomerCreditEntry{}, "", false, ErrCustomerNotFound
	}
	if err != nil {
		return CustomerCreditEntry{}, "", false, err
	}
	reference := strings.TrimSpace(change.Reference)
	var existing CustomerCreditEntry
	err = tx.QueryRow(ctx,
		`SELECT id, customer_id, kind, amount::text, order_id, test_mode, created_at, note, actor, reference
		FROM relay_customer_credit_entries WHERE customer_id = $1 AND reference = $2 AND reference <> ''`,
		change.CustomerID, reference).Scan(&existing.ID, &existing.CustomerID, &existing.Kind, &existing.Amount,
		&existing.OrderID, &existing.TestMode, &existing.CreatedAt, &existing.Note, &existing.Actor, &existing.Reference)
	balance, balanceErr := customerCreditBalanceTx(ctx, tx, change.CustomerID)
	if balanceErr != nil {
		return CustomerCreditEntry{}, "", false, balanceErr
	}
	if err == nil {
		existing.Amount = NormalizeWalletAmount(existing.Amount)
		existing.CreatedAt = existing.CreatedAt.UTC()
		return existing, FormatWalletAmount(balance), false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return CustomerCreditEntry{}, "", false, err
	}
	entry, err := customerAdjustment(change, balance, s.clock.Now().UTC())
	if err != nil {
		return CustomerCreditEntry{}, "", false, err
	}
	id, err := NewInstallationID()
	if err != nil {
		return CustomerCreditEntry{}, "", false, err
	}
	entry.ID = id
	if _, err := tx.Exec(ctx,
		`INSERT INTO relay_customer_credit_entries
		(id, customer_id, kind, amount, order_id, test_mode, created_at, note, actor, reference)
		VALUES ($1, $2, $3, $4, '', false, $5, $6, $7, $8)`,
		entry.ID, entry.CustomerID, entry.Kind, entry.Amount, entry.CreatedAt, entry.Note, entry.Actor, entry.Reference,
	); err != nil {
		return CustomerCreditEntry{}, "", false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return CustomerCreditEntry{}, "", false, err
	}
	amount, _ := ParseWalletAmount(entry.Amount)
	return entry, FormatWalletAmount(balance.Add(balance, amount)), true, nil
}

func (s *PostgresStore) SetCustomerPushToken(ctx context.Context, customerID, sessionID, token string) error {
	token = strings.TrimSpace(token)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if token != "" {
		if _, err := tx.Exec(ctx,
			`UPDATE relay_customer_sessions SET push_token = '' WHERE push_token = $1 AND id <> $2`,
			token, sessionID); err != nil {
			return err
		}
	}
	tag, err := tx.Exec(ctx,
		`UPDATE relay_customer_sessions SET push_token = $3 WHERE id = $1 AND customer_id = $2`,
		sessionID, customerID, token)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrCustomerSessionNotFound
	}
	return tx.Commit(ctx)
}

func (s *PostgresStore) ForgetCustomerPushToken(ctx context.Context, token string) error {
	if token == "" {
		return nil
	}
	_, err := s.pool.Exec(ctx, `UPDATE relay_customer_sessions SET push_token = '' WHERE push_token = $1`, token)
	return err
}

const selectCustomerNotificationColumns = `id, audience, customer_id, title, body, link, campaign, sent_by,
	devices, sent, failed, error, created_at`

func (s *PostgresStore) RecordCustomerNotification(ctx context.Context, notification CustomerNotification) (CustomerNotification, error) {
	notification, err := normalizeCustomerNotification(notification)
	if err != nil {
		return CustomerNotification{}, err
	}
	if notification.CreatedAt.IsZero() {
		notification.CreatedAt = s.clock.Now().UTC()
	}
	_, err = s.pool.Exec(ctx, `INSERT INTO relay_customer_notifications (`+selectCustomerNotificationColumns+`)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
		notification.ID, notification.Audience, notification.CustomerID, notification.Title, notification.Body,
		notification.Link, notification.Campaign, notification.SentBy, notification.Devices, notification.Sent,
		notification.Failed, notification.Error, notification.CreatedAt)
	return notification, err
}

func (s *PostgresStore) ListCustomerNotifications(ctx context.Context, filter CustomerNotificationFilter) ([]CustomerNotification, error) {
	limit := filter.Limit
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.pool.Query(ctx, `SELECT `+selectCustomerNotificationColumns+` FROM relay_customer_notifications
		WHERE ($1 = '' OR customer_id = $1) ORDER BY created_at DESC, id DESC LIMIT $2`, filter.CustomerID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := []CustomerNotification{}
	for rows.Next() {
		var n CustomerNotification
		if err := rows.Scan(&n.ID, &n.Audience, &n.CustomerID, &n.Title, &n.Body, &n.Link, &n.Campaign, &n.SentBy,
			&n.Devices, &n.Sent, &n.Failed, &n.Error, &n.CreatedAt); err != nil {
			return nil, err
		}
		n.CreatedAt = n.CreatedAt.UTC()
		list = append(list, n)
	}
	return list, rows.Err()
}
