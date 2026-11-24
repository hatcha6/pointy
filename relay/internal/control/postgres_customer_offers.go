package control

import (
	"context"
	"errors"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const selectCustomerOfferColumns = `id, name, title, description, kind, value::text, max_discount::text,
	min_order::text, segments, recipients, uses_per_customer, max_redemptions, starts_at, ends_at, active,
	created_by, created_at, updated_at, holdout_percent, holdouts`

func scanCustomerOffer(row pgx.Row) (CustomerOffer, error) {
	var offer CustomerOffer
	err := row.Scan(&offer.ID, &offer.Name, &offer.Title, &offer.Description, &offer.Kind, &offer.Value,
		&offer.MaxDiscount, &offer.MinOrder, &offer.Segments, &offer.Recipients, &offer.UsesPerCustomer,
		&offer.MaxRedemptions, &offer.StartsAt, &offer.EndsAt, &offer.Active, &offer.CreatedBy,
		&offer.CreatedAt, &offer.UpdatedAt, &offer.HoldoutPercent, &offer.Holdouts)
	if errors.Is(err, pgx.ErrNoRows) {
		return CustomerOffer{}, ErrCustomerOfferNotFound
	}
	if err != nil {
		return CustomerOffer{}, err
	}
	offer.Value = NormalizeWalletAmount(offer.Value)
	offer.MaxDiscount = NormalizeWalletAmount(offer.MaxDiscount)
	offer.MinOrder = NormalizeWalletAmount(offer.MinOrder)
	offer.StartsAt, offer.CreatedAt, offer.UpdatedAt = offer.StartsAt.UTC(), offer.CreatedAt.UTC(), offer.UpdatedAt.UTC()
	if offer.EndsAt != nil {
		ends := offer.EndsAt.UTC()
		offer.EndsAt = &ends
	}
	if offer.Segments == nil {
		offer.Segments = []string{}
	}
	return offer, nil
}

// applyCustomerOfferTx prices order by its offer, the customer's row locked.
// The offer's row is locked too when it caps its redemptions, so two
// customers cannot both take its last one.
func applyCustomerOfferTx(ctx context.Context, tx pgx.Tx, order CustomerOrder, subtotal *big.Rat, now time.Time) (CustomerOrder, *big.Rat, error) {
	offer, err := scanCustomerOffer(tx.QueryRow(ctx,
		`SELECT `+selectCustomerOfferColumns+` FROM relay_customer_offers WHERE id = $1 FOR UPDATE`, order.OfferID))
	if errors.Is(err, ErrCustomerOfferNotFound) {
		return CustomerOrder{}, nil, ErrCustomerOfferUnavailable
	}
	if err != nil {
		return CustomerOrder{}, nil, err
	}
	var recipient bool
	var used, redeemed int
	if err := tx.QueryRow(ctx, `
SELECT EXISTS (SELECT 1 FROM relay_customer_offer_recipients WHERE offer_id = $1 AND customer_id = $2 AND NOT holdout),
	count(*) FILTER (WHERE customer_id = $2),
	count(*)
FROM relay_customer_orders
WHERE offer_id = $1 AND status IN ('awaiting_payment', 'paid', 'fulfilling', 'delivered')`,
		offer.ID, order.CustomerID).Scan(&recipient, &used, &redeemed); err != nil {
		return CustomerOrder{}, nil, err
	}
	total, discount, err := customerOfferTerms(offer, recipient, used, redeemed, subtotal, now)
	if err != nil {
		return CustomerOrder{}, nil, err
	}
	return withOfferApplied(order, total, discount), total, nil
}

func (s *PostgresStore) CreateCustomerOffer(ctx context.Context, offer CustomerOffer, recipients []CustomerOfferRecipient) (CustomerOffer, error) {
	offer, err := normalizeCustomerOffer(offer, s.clock.Now())
	if err != nil {
		return CustomerOffer{}, err
	}
	recipients = uniqueOfferRecipients(recipients)
	if offer.Recipients, offer.Holdouts, err = countOfferRecipients(recipients); err != nil {
		return CustomerOffer{}, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerOffer{}, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
INSERT INTO relay_customer_offers (id, name, title, description, kind, value, max_discount, min_order, segments,
	recipients, uses_per_customer, max_redemptions, starts_at, ends_at, active, created_by, created_at, updated_at,
	holdout_percent, holdouts)
VALUES ($1, $2, $3, $4, $5, $6::numeric, $7::numeric, $8::numeric, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18,
	$19, $20)`,
		offer.ID, offer.Name, offer.Title, offer.Description, offer.Kind, offer.Value, offer.MaxDiscount,
		offer.MinOrder, offer.Segments, offer.Recipients, offer.UsesPerCustomer, offer.MaxRedemptions,
		offer.StartsAt, offer.EndsAt, offer.Active, offer.CreatedBy, offer.CreatedAt, offer.UpdatedAt,
		offer.HoldoutPercent, offer.Holdouts); err != nil {
		return CustomerOffer{}, err
	}
	rows := make([][]any, 0, len(recipients))
	for _, recipient := range recipients {
		rows = append(rows, []any{offer.ID, recipient.CustomerID, recipient.Segment, recipient.Holdout})
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"relay_customer_offer_recipients"},
		[]string{"offer_id", "customer_id", "segment", "holdout"}, pgx.CopyFromRows(rows)); err != nil {
		return CustomerOffer{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return CustomerOffer{}, err
	}
	return offer, nil
}

func (s *PostgresStore) UpdateCustomerOffer(ctx context.Context, id string, update CustomerOfferUpdate) (CustomerOffer, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerOffer{}, err
	}
	defer tx.Rollback(ctx)
	offer, err := scanCustomerOffer(tx.QueryRow(ctx,
		`SELECT `+selectCustomerOfferColumns+` FROM relay_customer_offers WHERE id = $1 FOR UPDATE`, id))
	if err != nil {
		return CustomerOffer{}, err
	}
	updated, err := applyCustomerOfferUpdate(offer, update, s.clock.Now())
	if err != nil {
		return CustomerOffer{}, err
	}
	if _, err := tx.Exec(ctx, `
UPDATE relay_customer_offers SET name = $2, title = $3, description = $4, ends_at = $5, active = $6, updated_at = $7
WHERE id = $1`, id, updated.Name, updated.Title, updated.Description, updated.EndsAt, updated.Active, updated.UpdatedAt); err != nil {
		return CustomerOffer{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return CustomerOffer{}, err
	}
	return updated, nil
}

func (s *PostgresStore) GetCustomerOffer(ctx context.Context, id string) (CustomerOffer, error) {
	return scanCustomerOffer(s.pool.QueryRow(ctx,
		`SELECT `+selectCustomerOfferColumns+` FROM relay_customer_offers WHERE id = $1`, id))
}

func (s *PostgresStore) ListCustomerOffers(ctx context.Context) ([]CustomerOffer, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT `+selectCustomerOfferColumns+` FROM relay_customer_offers ORDER BY created_at DESC, id DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	offers := []CustomerOffer{}
	for rows.Next() {
		offer, err := scanCustomerOffer(rows)
		if err != nil {
			return nil, err
		}
		offers = append(offers, offer)
	}
	return offers, rows.Err()
}

func (s *PostgresStore) CustomerOfferRecipients(ctx context.Context, id string) ([]CustomerOfferRecipient, error) {
	if _, err := s.GetCustomerOffer(ctx, id); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx,
		`SELECT customer_id, segment, holdout FROM relay_customer_offer_recipients WHERE offer_id = $1 ORDER BY customer_id`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	recipients := []CustomerOfferRecipient{}
	for rows.Next() {
		var recipient CustomerOfferRecipient
		if err := rows.Scan(&recipient.CustomerID, &recipient.Segment, &recipient.Holdout); err != nil {
			return nil, err
		}
		recipients = append(recipients, recipient)
	}
	return recipients, rows.Err()
}

func (s *PostgresStore) CustomerOffersFor(ctx context.Context, customerID string, now time.Time) ([]CustomerOfferFor, error) {
	rows, err := s.pool.Query(ctx, `
SELECT `+prefixColumns("f.", selectCustomerOfferColumns)+`, u.used, u.redeemed
FROM relay_customer_offer_recipients r
JOIN relay_customer_offers f ON f.id = r.offer_id
LEFT JOIN LATERAL (
	SELECT count(*) FILTER (WHERE customer_id = $1) AS used, count(*) AS redeemed
	FROM relay_customer_orders
	WHERE offer_id = f.id AND status IN ('awaiting_payment', 'paid', 'fulfilling', 'delivered')
) u ON true
WHERE r.customer_id = $1 AND NOT r.holdout AND f.active AND f.starts_at <= $2 AND (f.ends_at IS NULL OR f.ends_at > $2)`,
		customerID, now.UTC())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []CustomerOfferFor{}
	for rows.Next() {
		var offer CustomerOffer
		var used, redeemed int
		if err := rows.Scan(&offer.ID, &offer.Name, &offer.Title, &offer.Description, &offer.Kind, &offer.Value,
			&offer.MaxDiscount, &offer.MinOrder, &offer.Segments, &offer.Recipients, &offer.UsesPerCustomer,
			&offer.MaxRedemptions, &offer.StartsAt, &offer.EndsAt, &offer.Active, &offer.CreatedBy,
			&offer.CreatedAt, &offer.UpdatedAt, &offer.HoldoutPercent, &offer.Holdouts, &used, &redeemed); err != nil {
			return nil, err
		}
		offer.Value = NormalizeWalletAmount(offer.Value)
		offer.MaxDiscount = NormalizeWalletAmount(offer.MaxDiscount)
		offer.MinOrder = NormalizeWalletAmount(offer.MinOrder)
		if left := offerUsesLeft(offer, used, redeemed); left > 0 {
			out = append(out, CustomerOfferFor{CustomerOffer: offer, UsesLeft: left})
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sortCustomerOffersFor(out)
	return out, nil
}

// --- what the segmentation reads ---------------------------------------------

func (s *PostgresStore) CustomerFacts(ctx context.Context) ([]CustomerFact, error) {
	rows, err := s.pool.Query(ctx, `
SELECT c.id, c.created_at, c.deleted_at, c.blocked_at, coalesce(p.push, 0)
FROM relay_customers c
LEFT JOIN (
	SELECT customer_id, count(*) AS push FROM relay_customer_sessions
	WHERE push_token <> '' AND expires_at > $1 GROUP BY customer_id
) p ON p.customer_id = c.id
ORDER BY c.id`, s.clock.Now().UTC())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	facts := []CustomerFact{}
	for rows.Next() {
		var fact CustomerFact
		if err := rows.Scan(&fact.ID, &fact.CreatedAt, &fact.DeletedAt, &fact.BlockedAt, &fact.PushDevices); err != nil {
			return nil, err
		}
		fact.CreatedAt = fact.CreatedAt.UTC()
		facts = append(facts, fact)
	}
	return facts, rows.Err()
}

func (s *PostgresStore) CustomerOrderFacts(ctx context.Context) ([]CustomerOrderFact, error) {
	rows, err := s.pool.Query(ctx, `
SELECT o.id, o.customer_id, o.completed_at, o.channel, o.brand_key, o.total::text, o.discount::text, o.offer_id,
	coalesce(p.supplier_cost, ''), coalesce(p.supplier_currency, ''),
	coalesce(p.completed_at, p.created_at, o.completed_at)
FROM relay_customer_orders o
LEFT JOIN relay_voucher_purchases p ON p.id = o.purchase_id AND o.purchase_id <> ''
WHERE o.status = 'delivered' AND NOT o.test_mode AND NOT o.review AND o.completed_at IS NOT NULL
ORDER BY o.completed_at, o.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	facts := []CustomerOrderFact{}
	for rows.Next() {
		var fact CustomerOrderFact
		if err := rows.Scan(&fact.ID, &fact.CustomerID, &fact.CompletedAt, &fact.Channel, &fact.BrandKey,
			&fact.Total, &fact.Discount, &fact.OfferID, &fact.SupplierCost, &fact.SupplierCurrency,
			&fact.PurchaseAt); err != nil {
			return nil, err
		}
		fact.CompletedAt, fact.PurchaseAt = fact.CompletedAt.UTC(), fact.PurchaseAt.UTC()
		fact.Total, fact.Discount = NormalizeWalletAmount(fact.Total), NormalizeWalletAmount(fact.Discount)
		facts = append(facts, fact)
	}
	return facts, rows.Err()
}

func (s *PostgresStore) CustomerPushTokens(ctx context.Context, customerIDs []string) (map[string][]string, error) {
	tokens := map[string][]string{}
	if len(customerIDs) == 0 {
		return tokens, nil
	}
	rows, err := s.pool.Query(ctx, `
SELECT customer_id, push_token FROM relay_customer_sessions
WHERE customer_id = ANY($1) AND push_token <> '' AND expires_at > $2
ORDER BY customer_id, push_token`, customerIDs, s.clock.Now().UTC())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id, token string
		if err := rows.Scan(&id, &token); err != nil {
			return nil, err
		}
		tokens[id] = append(tokens[id], token)
	}
	return tokens, rows.Err()
}

// prefixColumns qualifies each of a comma-separated column list (which may
// carry ::casts) with prefix.
func prefixColumns(prefix, columns string) string {
	parts := strings.Split(columns, ",")
	for i, part := range parts {
		parts[i] = prefix + strings.TrimSpace(part)
	}
	return strings.Join(parts, ", ")
}
