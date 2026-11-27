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
)

const selectCustomerOfferColumns = `id, name, title, description, kind, value::text, max_discount::text,
	min_order::text, segments, recipients, uses_per_customer, max_redemptions, starts_at, ends_at, active,
	created_by, created_at, updated_at, holdout_percent, holdouts, terms, audience, notice`

// customerOfferTermsJSON is the part of an offer kept as one JSON column:
// what only some kinds have, and its scope and badge.
type customerOfferTermsJSON struct {
	Tiers       []CustomerOfferTier `json:"tiers,omitempty"`
	TierUnit    string              `json:"tier_unit,omitempty"`
	BuyQuantity int                 `json:"buy_quantity,omitempty"`
	GetQuantity int                 `json:"get_quantity,omitempty"`
	GetPercent  string              `json:"get_percent,omitempty"`
	Scope       CustomerOfferScope  `json:"scope"`
	Badge       string              `json:"badge,omitempty"`
	Budget      string              `json:"budget,omitempty"`
}

func customerOfferTermsOf(offer CustomerOffer) ([]byte, error) {
	return json.Marshal(customerOfferTermsJSON{
		Tiers: offer.Tiers, TierUnit: offer.TierUnit, BuyQuantity: offer.BuyQuantity, GetQuantity: offer.GetQuantity,
		GetPercent: offer.GetPercent, Scope: offer.Scope, Badge: offer.Badge, Budget: offer.Budget,
	})
}

func scanCustomerOffer(row pgx.Row, extra ...any) (CustomerOffer, error) {
	var offer CustomerOffer
	var terms, notice []byte
	dest := []any{&offer.ID, &offer.Name, &offer.Title, &offer.Description, &offer.Kind, &offer.Value,
		&offer.MaxDiscount, &offer.MinOrder, &offer.Segments, &offer.Recipients, &offer.UsesPerCustomer,
		&offer.MaxRedemptions, &offer.StartsAt, &offer.EndsAt, &offer.Active, &offer.CreatedBy,
		&offer.CreatedAt, &offer.UpdatedAt, &offer.HoldoutPercent, &offer.Holdouts, &terms, &offer.Audience, &notice}
	err := row.Scan(append(dest, extra...)...)
	if errors.Is(err, pgx.ErrNoRows) {
		return CustomerOffer{}, ErrCustomerOfferNotFound
	}
	if err != nil {
		return CustomerOffer{}, err
	}
	var kept customerOfferTermsJSON
	if len(terms) > 0 {
		if err := json.Unmarshal(terms, &kept); err != nil {
			return CustomerOffer{}, fmt.Errorf("customer offer %s terms: %w", offer.ID, err)
		}
	}
	offer.Tiers, offer.TierUnit, offer.BuyQuantity, offer.GetQuantity = kept.Tiers, kept.TierUnit, kept.BuyQuantity, kept.GetQuantity
	offer.GetPercent, offer.Scope, offer.Badge = kept.GetPercent, kept.Scope, kept.Badge
	if offer.Budget = kept.Budget; offer.Budget == "" {
		offer.Budget = "0"
	}
	offer.Budget = NormalizeWalletAmount(offer.Budget)
	if len(notice) > 0 {
		if err := json.Unmarshal(notice, &offer.Notice); err != nil {
			return CustomerOffer{}, fmt.Errorf("customer offer %s notice: %w", offer.ID, err)
		}
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
func applyCustomerOfferTx(ctx context.Context, tx pgx.Tx, order CustomerOrder, _ *big.Rat, now time.Time) (CustomerOrder, *big.Rat, error) {
	offer, err := scanCustomerOffer(tx.QueryRow(ctx,
		`SELECT `+selectCustomerOfferColumns+` FROM relay_customer_offers WHERE id = $1 FOR UPDATE`, order.OfferID))
	if errors.Is(err, ErrCustomerOfferNotFound) {
		return CustomerOrder{}, nil, ErrCustomerOfferUnavailable
	}
	if err != nil {
		return CustomerOrder{}, nil, err
	}
	var recipient bool
	var use CustomerOfferUse
	var spent string
	if err := tx.QueryRow(ctx, `
SELECT EXISTS (SELECT 1 FROM relay_customer_offer_recipients WHERE offer_id = $1 AND customer_id = $2 AND NOT holdout),
	count(*) FILTER (WHERE customer_id = $2),
	count(*),
	coalesce(sum(discount), 0)::text
FROM relay_customer_orders
WHERE offer_id = $1 AND status IN ('awaiting_payment', 'paid', 'fulfilling', 'delivered')`,
		offer.ID, order.CustomerID).Scan(&recipient, &use.Used, &use.Redeemed, &spent); err != nil {
		return CustomerOrder{}, nil, err
	}
	if use.Spent, err = ParseWalletAmount(spent); err != nil {
		return CustomerOrder{}, nil, err
	}
	total, discount, err := customerOfferTerms(offer, recipient, use, orderOfferLine(order), now)
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
	if offer.Recipients, offer.Holdouts, err = countOfferRecipients(offer, recipients); err != nil {
		return CustomerOffer{}, err
	}
	terms, err := customerOfferTermsOf(offer)
	if err != nil {
		return CustomerOffer{}, err
	}
	notice, err := json.Marshal(offer.Notice)
	if err != nil {
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
	holdout_percent, holdouts, terms, audience, notice)
VALUES ($1, $2, $3, $4, $5, $6::numeric, $7::numeric, $8::numeric, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18,
	$19, $20, $21::jsonb, $22, $23::jsonb)`,
		offer.ID, offer.Name, offer.Title, offer.Description, offer.Kind, offer.Value, offer.MaxDiscount,
		offer.MinOrder, offer.Segments, offer.Recipients, offer.UsesPerCustomer, offer.MaxRedemptions,
		offer.StartsAt, offer.EndsAt, offer.Active, offer.CreatedBy, offer.CreatedAt, offer.UpdatedAt,
		offer.HoldoutPercent, offer.Holdouts, terms, offer.Audience, notice); err != nil {
		return CustomerOffer{}, err
	}
	if len(recipients) == 0 {
		if err := tx.Commit(ctx); err != nil {
			return CustomerOffer{}, err
		}
		return offer, nil
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
	terms, err := customerOfferTermsOf(updated)
	if err != nil {
		return CustomerOffer{}, err
	}
	notice, err := json.Marshal(updated.Notice)
	if err != nil {
		return CustomerOffer{}, err
	}
	if _, err := tx.Exec(ctx, `
UPDATE relay_customer_offers SET name = $2, title = $3, description = $4, ends_at = $5, active = $6, updated_at = $7,
	terms = $8::jsonb, notice = $9::jsonb
WHERE id = $1`, id, updated.Name, updated.Title, updated.Description, updated.EndsAt, updated.Active, updated.UpdatedAt,
		terms, notice); err != nil {
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

// customerOfferUsesSQL counts an offer's live uses: one customer's ($1) and
// everyone's.
const customerOfferUsesSQL = `LEFT JOIN LATERAL (
	SELECT count(*) FILTER (WHERE customer_id = $1) AS used, count(*) AS redeemed,
		coalesce(sum(discount), 0)::text AS spent
	FROM relay_customer_orders
	WHERE offer_id = f.id AND status IN ('awaiting_payment', 'paid', 'fulfilling', 'delivered')
) u ON true`

func (s *PostgresStore) CustomerOffersFor(ctx context.Context, customerID string, now time.Time) ([]CustomerOfferFor, error) {
	rows, err := s.pool.Query(ctx, `
SELECT `+prefixColumns("f.", selectCustomerOfferColumns)+`, u.used, u.redeemed, u.spent
FROM relay_customer_offers f
`+customerOfferUsesSQL+`
WHERE f.active AND f.starts_at <= $2 AND (f.ends_at IS NULL OR f.ends_at > $2)
	AND (f.audience = 'everyone' OR EXISTS (
		SELECT 1 FROM relay_customer_offer_recipients r
		WHERE r.offer_id = f.id AND r.customer_id = $1 AND NOT r.holdout))`,
		customerID, now.UTC())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []CustomerOfferFor{}
	for rows.Next() {
		var use CustomerOfferUse
		var spent string
		offer, err := scanCustomerOffer(rows, &use.Used, &use.Redeemed, &spent)
		if err != nil {
			return nil, err
		}
		if use.Spent, err = ParseWalletAmount(spent); err != nil {
			return nil, err
		}
		if left := offerUsesLeft(offer, use); left > 0 {
			out = append(out, CustomerOfferFor{CustomerOffer: offer, UsesLeft: left})
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sortCustomerOffersFor(out)
	return out, nil
}

func (s *PostgresStore) PublicCustomerOffers(ctx context.Context, now time.Time) ([]CustomerOffer, error) {
	rows, err := s.pool.Query(ctx, `
SELECT `+prefixColumns("f.", selectCustomerOfferColumns)+`, u.redeemed, u.spent
FROM relay_customer_offers f
`+customerOfferUsesSQL+`
WHERE f.audience = 'everyone' AND f.active AND f.starts_at <= $2 AND (f.ends_at IS NULL OR f.ends_at > $2)
ORDER BY f.created_at DESC, f.id DESC`, "", now.UTC())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []CustomerOffer{}
	for rows.Next() {
		var use CustomerOfferUse
		var spent string
		offer, err := scanCustomerOffer(rows, &use.Redeemed, &spent)
		if err != nil {
			return nil, err
		}
		if use.Spent, err = ParseWalletAmount(spent); err != nil {
			return nil, err
		}
		if offerUsesLeft(offer, use) > 0 {
			out = append(out, offer)
		}
	}
	return out, rows.Err()
}

func (s *PostgresStore) ClaimCustomerOfferNotice(ctx context.Context, id, notice string, now time.Time) (bool, error) {
	field := map[string]string{CustomerOfferLaunchNotice: "sent_at", CustomerOfferReminderNotice: "reminded_at"}[notice]
	if field == "" {
		return false, errors.Join(ErrCustomerOfferInvalid, errors.New("an offer's notice is launch or reminder"))
	}
	stamp, err := json.Marshal(now.UTC())
	if err != nil {
		return false, err
	}
	// One statement: of two nodes claiming at once, one updates the row.
	tag, err := s.pool.Exec(ctx, `
UPDATE relay_customer_offers SET notice = jsonb_set(notice, ARRAY[$2::text], $3::jsonb)
WHERE id = $1 AND coalesce(notice->>$2, '') = ''`, id, field, stamp)
	if err != nil {
		return false, err
	}
	if tag.RowsAffected() == 0 {
		if _, err := s.GetCustomerOffer(ctx, id); err != nil {
			return false, err
		}
		return false, nil
	}
	return true, nil
}

func (s *PostgresStore) CustomerOfferUses(ctx context.Context, id string) (map[string]int, CustomerOfferUse, error) {
	if _, err := s.GetCustomerOffer(ctx, id); err != nil {
		return nil, CustomerOfferUse{}, err
	}
	rows, err := s.pool.Query(ctx, `
SELECT customer_id, count(*), coalesce(sum(discount), 0)::text
FROM relay_customer_orders
WHERE offer_id = $1 AND status IN ('awaiting_payment', 'paid', 'fulfilling', 'delivered')
GROUP BY customer_id`, id)
	if err != nil {
		return nil, CustomerOfferUse{}, err
	}
	defer rows.Close()
	each := map[string]int{}
	all := CustomerOfferUse{Spent: new(big.Rat)}
	for rows.Next() {
		var customer, spent string
		var count int
		if err := rows.Scan(&customer, &count, &spent); err != nil {
			return nil, CustomerOfferUse{}, err
		}
		amount, err := ParseWalletAmount(spent)
		if err != nil {
			return nil, CustomerOfferUse{}, err
		}
		each[customer] = count
		all.Redeemed += count
		all.Spent.Add(all.Spent, amount)
	}
	return each, all, rows.Err()
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
