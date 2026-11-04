package control

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Campaigns, their clicks and rewards, and each customer's attribution
// (migration 39).

const campaignColumns = `id, code, name, display_name, kind, note, landing, active,
	reward, reward_limit, reward_until, created_by, created_at, updated_at`

// selectCampaignSQL reads campaigns (as c) with how many their reward reached.
const selectCampaignSQL = `SELECT c.id, c.code, c.name, c.display_name, c.kind, c.note, c.landing, c.active,
	c.reward::text, c.reward_limit, c.reward_until, c.created_by, c.created_at, c.updated_at,
	(SELECT count(*) FROM relay_customer_credit_entries e
		WHERE e.kind = 'campaign' AND e.reference = 'campaign:' || c.id)
FROM relay_customer_campaigns c`

func scanCampaign(row pgx.Row) (CustomerCampaign, error) {
	var campaign CustomerCampaign
	err := row.Scan(&campaign.ID, &campaign.Code, &campaign.Name, &campaign.DisplayName, &campaign.Kind,
		&campaign.Note, &campaign.Landing, &campaign.Active, &campaign.Reward, &campaign.RewardLimit,
		&campaign.RewardUntil, &campaign.CreatedBy, &campaign.CreatedAt, &campaign.UpdatedAt, &campaign.Rewarded)
	if errors.Is(err, pgx.ErrNoRows) {
		return CustomerCampaign{}, ErrCustomerCampaignNotFound
	}
	campaign.Reward = NormalizeWalletAmount(campaign.Reward)
	return campaign, err
}

func (s *PostgresStore) CreateCustomerCampaign(ctx context.Context, campaign CustomerCampaign) (CustomerCampaign, error) {
	campaign, err := normalizeNewCampaign(campaign, s.clock.Now().UTC())
	if err != nil {
		return CustomerCampaign{}, err
	}
	_, err = s.pool.Exec(ctx, `
INSERT INTO relay_customer_campaigns (`+campaignColumns+`)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)`,
		campaign.ID, campaign.Code, campaign.Name, campaign.DisplayName, campaign.Kind, campaign.Note,
		campaign.Landing, campaign.Active, campaign.Reward, campaign.RewardLimit, campaign.RewardUntil,
		campaign.CreatedBy, campaign.CreatedAt, campaign.UpdatedAt)
	if code, _ := pgErrorCode(err); code == pgUniqueViolation {
		return CustomerCampaign{}, ErrCustomerCampaignCodeTaken
	}
	if err != nil {
		return CustomerCampaign{}, err
	}
	return campaign, nil
}

func (s *PostgresStore) UpdateCustomerCampaign(ctx context.Context, id string, update CustomerCampaignUpdate) (CustomerCampaign, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerCampaign{}, err
	}
	defer tx.Rollback(ctx)
	campaign, err := scanCampaign(tx.QueryRow(ctx, selectCampaignSQL+` WHERE c.id = $1 FOR UPDATE OF c`, id))
	if err != nil {
		return CustomerCampaign{}, err
	}
	campaign, err = applyCampaignUpdate(campaign, update, s.clock.Now().UTC())
	if err != nil {
		return CustomerCampaign{}, err
	}
	if _, err := tx.Exec(ctx, `
UPDATE relay_customer_campaigns SET name = $2, display_name = $3, note = $4, landing = $5, active = $6,
	reward = $7, reward_limit = $8, reward_until = $9, updated_at = $10
WHERE id = $1`, id, campaign.Name, campaign.DisplayName, campaign.Note, campaign.Landing, campaign.Active,
		campaign.Reward, campaign.RewardLimit, campaign.RewardUntil, campaign.UpdatedAt); err != nil {
		return CustomerCampaign{}, err
	}
	return campaign, tx.Commit(ctx)
}

func (s *PostgresStore) CustomerCampaignByCode(ctx context.Context, code string) (CustomerCampaign, error) {
	code, ok := NormalizeCampaignCode(code)
	if !ok {
		return CustomerCampaign{}, ErrCustomerCampaignNotFound
	}
	return scanCampaign(s.pool.QueryRow(ctx, selectCampaignSQL+` WHERE c.code = $1`, code))
}

func (s *PostgresStore) RecordCustomerCampaignClick(ctx context.Context, campaignID, platform string) error {
	if !customerCampaignClickPlatforms[platform] {
		platform = "web"
	}
	day := s.clock.Now().In(customerDayZone).Format(time.DateOnly)
	_, err := s.pool.Exec(ctx, `
INSERT INTO relay_customer_campaign_clicks (campaign_id, day, platform, clicks)
VALUES ($1, $2::date, $3, 1)
ON CONFLICT (campaign_id, day, platform) DO UPDATE SET clicks = relay_customer_campaign_clicks.clicks + 1`,
		campaignID, day, platform)
	if code, _ := pgErrorCode(err); code == pgForeignKeyViolation {
		return ErrCustomerCampaignNotFound
	}
	return err
}

const selectAttributionColumns = `campaign_code, campaign_via, campaign_at, heard_from, heard_from_at, created_at`

func scanAttribution(row pgx.Row) (CustomerAttribution, time.Time, error) {
	var attribution CustomerAttribution
	var created time.Time
	err := row.Scan(&attribution.CampaignCode, &attribution.CampaignVia, &attribution.CampaignAt,
		&attribution.HeardFrom, &attribution.HeardFromAt, &created)
	if errors.Is(err, pgx.ErrNoRows) {
		return CustomerAttribution{}, time.Time{}, ErrCustomerNotFound
	}
	return attribution, created, err
}

func (s *PostgresStore) CustomerAttribution(ctx context.Context, customerID string) (CustomerAttribution, error) {
	attribution, _, err := scanAttribution(s.pool.QueryRow(ctx,
		`SELECT `+selectAttributionColumns+` FROM relay_customers WHERE id = $1`, customerID))
	return attribution, err
}

func (s *PostgresStore) AttributeCustomer(ctx context.Context, customerID string, change CustomerAttributionChange) (CustomerAttributionResult, error) {
	change = normalizeAttributionChange(change)
	now := s.clock.Now().UTC()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerAttributionResult{}, err
	}
	defer tx.Rollback(ctx)
	// The customer row is the lock every credit change of theirs waits on.
	current, created, err := scanAttribution(tx.QueryRow(ctx,
		`SELECT `+selectAttributionColumns+` FROM relay_customers
		WHERE id = $1 AND deleted_at IS NULL FOR UPDATE`, customerID))
	if err != nil {
		return CustomerAttributionResult{}, err
	}
	var campaign *CustomerCampaign
	if change.CampaignCode != "" && takesCampaign(current, created, now) {
		// Locked, so two customers cannot both take a reward's last place.
		found, err := scanCampaign(tx.QueryRow(ctx,
			selectCampaignSQL+` WHERE c.code = $1 FOR UPDATE OF c`, change.CampaignCode))
		switch {
		case err == nil && found.Active:
			campaign = &found
		case err != nil && !errors.Is(err, ErrCustomerCampaignNotFound):
			return CustomerAttributionResult{}, err
		}
	}
	next := attribute(current, change, campaign, created, now)
	result := CustomerAttributionResult{Attribution: next}
	if next == current {
		return result, nil
	}
	if _, err := tx.Exec(ctx, `
UPDATE relay_customers SET campaign_code = $2, campaign_via = $3, campaign_at = $4,
	heard_from = $5, heard_from_at = $6
WHERE id = $1`, customerID, next.CampaignCode, next.CampaignVia, next.CampaignAt,
		next.HeardFrom, next.HeardFromAt); err != nil {
		return CustomerAttributionResult{}, err
	}
	if campaign != nil && next.CampaignCode != current.CampaignCode {
		result.Accepted = true
		if entry := campaignRewardEntry(*campaign, customerID, now); entry != nil {
			id, err := NewInstallationID()
			if err != nil {
				return CustomerAttributionResult{}, err
			}
			if _, err := tx.Exec(ctx, `
INSERT INTO relay_customer_credit_entries
	(id, customer_id, kind, amount, order_id, test_mode, created_at, note, actor, reference)
VALUES ($1, $2, $3, $4, '', false, $5, $6, '', $7)`,
				id, entry.CustomerID, entry.Kind, entry.Amount, entry.CreatedAt, entry.Note, entry.Reference); err != nil {
				return CustomerAttributionResult{}, err
			}
			result.Reward = campaignReward(*campaign, next.CampaignVia)
		}
	}
	return result, tx.Commit(ctx)
}

func (s *PostgresStore) CustomerCampaignReport(ctx context.Context) (CustomerCampaignReport, error) {
	now := s.clock.Now().UTC()
	rows, err := s.pool.Query(ctx, selectCampaignSQL)
	if err != nil {
		return CustomerCampaignReport{}, err
	}
	campaigns, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (CustomerCampaign, error) {
		return scanCampaign(row)
	})
	if err != nil {
		return CustomerCampaignReport{}, err
	}
	clicks := map[string]map[string]int{}
	if err := s.eachRow(ctx, `
SELECT campaign_id, platform, sum(clicks) FROM relay_customer_campaign_clicks GROUP BY campaign_id, platform`,
		func(rows pgx.Rows) error {
			var id, platform string
			var n int
			if err := rows.Scan(&id, &platform, &n); err != nil {
				return err
			}
			if clicks[id] == nil {
				clicks[id] = map[string]int{}
			}
			clicks[id][platform] = n
			return nil
		}); err != nil {
		return CustomerCampaignReport{}, err
	}
	rewards := campaignRewards{}
	if err := s.eachRow(ctx, `
SELECT reference, amount::text FROM relay_customer_credit_entries WHERE kind = 'campaign'`,
		func(rows pgx.Rows) error {
			var reference, amount string
			if err := rows.Scan(&reference, &amount); err != nil {
				return err
			}
			rewards.add(reference, amount)
			return nil
		}); err != nil {
		return CustomerCampaignReport{}, err
	}
	// One row per customer: deleted ones too, since a campaign did bring
	// them and their orders count.
	byCode, byAnswer := map[string]*acquisitionTally{}, map[string]*acquisitionTally{}
	if err := s.eachRow(ctx, `
SELECT c.campaign_code, c.heard_from, coalesce(o.delivered, 0) > 0, coalesce(o.spent, 0)::text
FROM relay_customers c
LEFT JOIN LATERAL (
	SELECT count(*) FILTER (WHERE status = 'delivered') AS delivered,
		sum(total) FILTER (WHERE status = 'delivered' AND NOT test_mode AND NOT review) AS spent
	FROM relay_customer_orders WHERE customer_id = c.id
) o ON true`,
		func(rows pgx.Rows) error {
			var code, answer, spent string
			var delivered bool
			if err := rows.Scan(&code, &answer, &delivered, &spent); err != nil {
				return err
			}
			tallyInto(byCode, code, delivered, spent)
			tallyInto(byAnswer, answer, delivered, spent)
			return nil
		}); err != nil {
		return CustomerCampaignReport{}, err
	}
	return buildCampaignReport(campaigns, clicks, rewards, byCode, byAnswer, now), nil
}

// eachRow runs query and hands each row to read.
func (s *PostgresStore) eachRow(ctx context.Context, query string, read func(pgx.Rows) error) error {
	rows, err := s.pool.Query(ctx, query)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		if err := read(rows); err != nil {
			return err
		}
	}
	return rows.Err()
}
