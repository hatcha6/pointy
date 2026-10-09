package control

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// smsMessageColumns is the canonical column order for scanSMSMessage. Every
// query aliases relay_sms_messages as m.
const smsMessageColumns = `m.id,
	m.installation_id,
	m.idempotency_key,
	m.kind,
	m.consent_class,
	m.recipient,
	m.content_sha256,
	m.template_id,
	m.template_body,
	m.test_mode,
	m.status,
	m.error_code,
	m.error_detail,
	m.cost::text,
	m.price::text,
	m.parts,
	m.provider_message_id,
	m.created_at,
	m.updated_at,
	m.sent_at,
	m.delivered_at,
	m.held_since`

const selectSMSSQL = `SELECT ` + smsMessageColumns + ` FROM relay_sms_messages m`

const selectSMSWithShopSQL = `SELECT ` + smsMessageColumns + `, COALESCE(i.shop_name, '')
FROM relay_sms_messages m
LEFT JOIN relay_installations i ON i.id = m.installation_id`

const countBillableSMSSQL = `SELECT count(*) FROM relay_sms_messages
WHERE installation_id = $1
	AND NOT test_mode
	AND status IN ('pending', 'sent', 'delivered', 'undelivered')
	AND created_at >= $2::timestamptz`

// smsClaimLockKey maps an installation to the advisory lock that serializes
// its claims. FNV keeps it stable across relay nodes and releases.
func smsClaimLockKey(installationID string) int64 {
	hash := fnv.New64a()
	_, _ = hash.Write([]byte("pointy-relay-sms-claim:" + installationID))
	return int64(hash.Sum64())
}

func (s *PostgresStore) BeginSMS(
	ctx context.Context,
	message SMSMessage,
	terms SMSClaimTerms,
) (SMSMessage, bool, error) {
	claim, err := prepareSMSClaim(message, s.clock.Now())
	if err != nil {
		return SMSMessage{}, false, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return SMSMessage{}, false, err
	}
	defer tx.Rollback(ctx)

	// One shop's claims go through one at a time, so the key check, the cap
	// count, the charge and the insert are a single step: neither a same-key
	// race nor two sends racing for the month's last message can slip between
	// them. The charge also locks the SMS balance row, which is what a transfer
	// into it waits on.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, smsClaimLockKey(claim.InstallationID)); err != nil {
		return SMSMessage{}, false, err
	}
	existing, err := scanSMSMessage(tx.QueryRow(
		ctx,
		selectSMSSQL+` WHERE m.installation_id = $1 AND m.idempotency_key = $2`,
		claim.InstallationID,
		claim.IdempotencyKey,
	), false)
	if err == nil {
		if err := tx.Commit(ctx); err != nil {
			return SMSMessage{}, false, err
		}
		return existing, false, nil
	}
	if !errors.Is(err, ErrSMSNotFound) {
		return SMSMessage{}, false, err
	}
	if price := smsClaimCharge(&claim, terms); price != nil {
		posting, err := prepareWalletPosting(smsChargePosting(claim, price, terms.ChargeDescription))
		if err != nil {
			return SMSMessage{}, false, err
		}
		if _, _, err := s.postWalletEntryTx(ctx, tx, posting); err != nil {
			return SMSMessage{}, false, err
		}
	}
	inserted, err := scanSMSMessage(tx.QueryRow(
		ctx,
		`INSERT INTO relay_sms_messages AS m (
			id, installation_id, idempotency_key, kind, consent_class, recipient,
			content_sha256, template_id, template_body, test_mode, status,
			error_code, error_detail, cost, provider_message_id,
			created_at, updated_at, sent_at, delivered_at, price, parts
		) VALUES (
			$1, $2, $3, $4, $5, $6,
			$7, $8, $9, $10, $11,
			'', '', $12::text::numeric, $13,
			$14::timestamptz, $15::timestamptz, NULL, NULL, $16::text::numeric, $17
		) RETURNING `+smsMessageColumns,
		claim.ID,
		claim.InstallationID,
		claim.IdempotencyKey,
		claim.Kind,
		claim.ConsentClass,
		claim.Recipient,
		claim.ContentSHA256,
		claim.TemplateID,
		claim.TemplateBody,
		claim.TestMode,
		claim.Status,
		claim.Cost,
		claim.ProviderMessageID,
		claim.CreatedAt,
		claim.UpdatedAt,
		claim.Price,
		claim.Parts,
	), false)
	if err != nil {
		return SMSMessage{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SMSMessage{}, false, err
	}
	return inserted, true, nil
}

func (s *PostgresStore) FindSMSByKey(
	ctx context.Context,
	installationID, idempotencyKey string,
) (SMSMessage, bool, error) {
	message, err := scanSMSMessage(s.pool.QueryRow(
		ctx,
		selectSMSSQL+` WHERE m.installation_id = $1 AND m.idempotency_key = $2`,
		strings.TrimSpace(installationID),
		strings.TrimSpace(idempotencyKey),
	), false)
	if errors.Is(err, ErrSMSNotFound) {
		return SMSMessage{}, false, nil
	}
	if err != nil {
		return SMSMessage{}, false, err
	}
	return message, true, nil
}

func (s *PostgresStore) FinishSMS(
	ctx context.Context,
	id string,
	outcome SMSOutcome,
) (SMSMessage, bool, error) {
	if err := validateSMSOutcome(outcome); err != nil {
		return SMSMessage{}, false, err
	}
	var sentAt any
	if outcome.SentAt != nil {
		sentAt = outcome.SentAt.UTC()
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return SMSMessage{}, false, err
	}
	defer tx.Rollback(ctx)

	finished, err := scanSMSMessage(tx.QueryRow(
		ctx,
		`UPDATE relay_sms_messages AS m
		SET
			status = $2,
			error_code = $3,
			error_detail = $4,
			cost = $5::text::numeric,
			content_sha256 = CASE WHEN $6::text <> '' THEN $6::text ELSE m.content_sha256 END,
			template_body = CASE WHEN $7::text <> '' THEN $7::text ELSE m.template_body END,
			test_mode = $8,
			sent_at = COALESCE($9::timestamptz, m.sent_at),
			updated_at = $10::timestamptz
		WHERE m.id = $1 AND m.status = 'pending'
		RETURNING `+smsMessageColumns,
		id,
		outcome.Status,
		strings.TrimSpace(outcome.ErrorCode),
		strings.TrimSpace(outcome.ErrorDetail),
		NormalizeSMSCost(outcome.Cost),
		outcome.ContentSHA256,
		outcome.TemplateBody,
		outcome.TestMode,
		sentAt,
		s.clock.Now().UTC(),
	), false)
	if errors.Is(err, ErrSMSNotFound) {
		// Not pending any more (or not there at all): the first outcome stands.
		existing, err := scanSMSMessage(tx.QueryRow(ctx, selectSMSSQL+` WHERE m.id = $1`, id), false)
		if err != nil {
			return SMSMessage{}, false, err
		}
		if err := tx.Commit(ctx); err != nil {
			return SMSMessage{}, false, err
		}
		return existing, false, nil
	}
	if err != nil {
		return SMSMessage{}, false, err
	}
	// The update left parts and price alone: the row is still what was held.
	held := finished
	posting, err := smsFinishPosting(held, &finished, outcome, s.clock.Now())
	if err != nil {
		return SMSMessage{}, false, err
	}
	if posting != nil {
		if _, _, err := s.postWalletEntryTx(ctx, tx, *posting); err != nil {
			return SMSMessage{}, false, err
		}
	}
	if finished.Parts != held.Parts || finished.Price != held.Price || finished.HeldSince != nil {
		var heldSince any
		if finished.HeldSince != nil {
			heldSince = finished.HeldSince.UTC()
		}
		if _, err := tx.Exec(
			ctx,
			`UPDATE relay_sms_messages
			SET parts = $2, price = $3::text::numeric, held_since = $4::timestamptz
			WHERE id = $1`,
			id,
			finished.Parts,
			finished.Price,
			heldSince,
		); err != nil {
			return SMSMessage{}, false, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return SMSMessage{}, false, err
	}
	return finished, true, nil
}

func (s *PostgresStore) ListSMSAwaitingCheck(ctx context.Context, limit int) ([]SMSMessage, error) {
	return s.querySMS(
		ctx,
		false,
		selectSMSSQL+` WHERE m.held_since IS NOT NULL ORDER BY m.held_since, m.id LIMIT $1`,
		normalizedSMSAwaitingLimit(limit),
	)
}

func (s *PostgresStore) ResolveSMSCheck(
	ctx context.Context,
	id string,
	resolution SMSCheckResolution,
) (SMSMessage, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return SMSMessage{}, false, err
	}
	defer tx.Rollback(ctx)

	held, err := scanSMSMessage(tx.QueryRow(
		ctx,
		selectSMSSQL+` WHERE m.id = $1 FOR UPDATE`,
		id,
	), false)
	if err != nil {
		return SMSMessage{}, false, err
	}
	if held.HeldSince == nil {
		// Settled already, by this check or another relay node's.
		if err := tx.Commit(ctx); err != nil {
			return SMSMessage{}, false, err
		}
		return held, false, nil
	}
	resolved, posting, err := resolveSMSCheck(held, resolution, s.clock.Now())
	if err != nil {
		return SMSMessage{}, false, err
	}
	if posting != nil {
		if _, _, err := s.postWalletEntryTx(ctx, tx, *posting); err != nil {
			return SMSMessage{}, false, err
		}
	}
	var sentAt, deliveredAt any
	if resolved.SentAt != nil {
		sentAt = resolved.SentAt.UTC()
	}
	if resolved.DeliveredAt != nil {
		deliveredAt = resolved.DeliveredAt.UTC()
	}
	if _, err := tx.Exec(
		ctx,
		`UPDATE relay_sms_messages
		SET
			status = $2,
			error_code = $3,
			error_detail = $4,
			provider_message_id = $5,
			sent_at = $6::timestamptz,
			delivered_at = $7::timestamptz,
			parts = $8,
			price = $9::text::numeric,
			cost = $11::text::numeric,
			held_since = NULL,
			updated_at = $10::timestamptz
		WHERE id = $1`,
		id,
		resolved.Status,
		resolved.ErrorCode,
		resolved.ErrorDetail,
		resolved.ProviderMessageID,
		sentAt,
		deliveredAt,
		resolved.Parts,
		resolved.Price,
		resolved.UpdatedAt,
		resolved.Cost,
	); err != nil {
		return SMSMessage{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SMSMessage{}, false, err
	}
	return resolved, true, nil
}

func (s *PostgresStore) SMSPartCost(ctx context.Context) (string, error) {
	var cost string
	var parts int
	err := s.pool.QueryRow(
		ctx,
		`SELECT cost::text, parts FROM relay_sms_messages
		WHERE NOT test_mode AND cost > 0 AND status IN ('sent', 'delivered', 'undelivered')
		ORDER BY created_at DESC, id DESC
		LIMIT 1`,
	).Scan(&cost, &parts)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return smsPerPart(cost, parts), nil
}

func (s *PostgresStore) SMSClaimedProviderIDs(ctx context.Context, ids []string) (map[string]bool, error) {
	wanted := make([]string, 0, len(ids))
	for _, id := range ids {
		if id = strings.TrimSpace(id); id != "" {
			wanted = append(wanted, id)
		}
	}
	claimed := map[string]bool{}
	if len(wanted) == 0 {
		return claimed, nil
	}
	rows, err := s.pool.Query(
		ctx,
		`SELECT DISTINCT provider_message_id FROM relay_sms_messages
		WHERE provider_message_id = ANY($1::text[])`,
		wanted,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		claimed[id] = true
	}
	return claimed, rows.Err()
}

func (s *PostgresStore) SMSTemplateBody(ctx context.Context, templateID string) (string, error) {
	var body string
	err := s.pool.QueryRow(
		ctx,
		`SELECT template_body FROM relay_sms_messages
		WHERE template_id = $1 AND template_body <> ''
		ORDER BY created_at DESC, id DESC
		LIMIT 1`,
		strings.TrimSpace(templateID),
	).Scan(&body)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return body, err
}

func (s *PostgresStore) CountBillableSMSSince(
	ctx context.Context,
	installationID string,
	since time.Time,
) (int, error) {
	var count int
	if err := s.pool.QueryRow(ctx, countBillableSMSSQL, installationID, since).Scan(&count); err != nil {
		return 0, err
	}
	return count, nil
}

func (s *PostgresStore) GetSMSByIDs(
	ctx context.Context,
	installationID string,
	ids []string,
) ([]SMSMessage, error) {
	if len(ids) == 0 {
		return []SMSMessage{}, nil
	}
	return s.querySMS(
		ctx,
		false,
		selectSMSSQL+` WHERE m.installation_id = $1 AND m.id = ANY($2::text[]) ORDER BY m.created_at DESC, m.id DESC`,
		installationID,
		ids,
	)
}

func (s *PostgresStore) ListSMSMessages(
	ctx context.Context,
	filter SMSMessageFilter,
) ([]SMSMessage, error) {
	var conditions []string
	var args []any
	if id := strings.TrimSpace(filter.InstallationID); id != "" {
		args = append(args, id)
		conditions = append(conditions, fmt.Sprintf("m.installation_id = $%d", len(args)))
	}
	if status := strings.TrimSpace(filter.Status); status != "" {
		args = append(args, status)
		conditions = append(conditions, fmt.Sprintf("m.status = $%d", len(args)))
	}
	query := selectSMSWithShopSQL
	if len(conditions) > 0 {
		query += " WHERE " + strings.Join(conditions, " AND ")
	}
	args = append(args, normalizedSMSListLimit(filter.Limit))
	query += fmt.Sprintf(" ORDER BY m.created_at DESC, m.id DESC LIMIT $%d", len(args))
	return s.querySMS(ctx, true, query, args...)
}

func (s *PostgresStore) SMSUsage(ctx context.Context, from, to time.Time) ([]SMSInstallationUsage, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT
			m.installation_id,
			COALESCE(i.shop_name, ''),
			count(*) FILTER (WHERE NOT m.test_mode),
			count(*) FILTER (WHERE NOT m.test_mode AND m.status IN ('sent', 'delivered', 'undelivered')),
			count(*) FILTER (WHERE NOT m.test_mode AND m.status = 'failed'),
			count(*) FILTER (WHERE NOT m.test_mode AND m.status = 'delivered'),
			count(*) FILTER (WHERE NOT m.test_mode AND m.status = 'undelivered'),
			count(*) FILTER (WHERE m.test_mode),
			COALESCE(sum(m.parts) FILTER (
				WHERE NOT m.test_mode AND m.status IN ('pending', 'sent', 'delivered', 'undelivered')
			), 0),
			COALESCE(sum(m.cost) FILTER (WHERE NOT m.test_mode), 0)::text,
			COALESCE(sum(m.price) FILTER (
				WHERE NOT m.test_mode AND m.status IN ('pending', 'sent', 'delivered', 'undelivered')
			), 0)::text,
			max(m.sent_at) FILTER (WHERE NOT m.test_mode)
		FROM relay_sms_messages m
		LEFT JOIN relay_installations i ON i.id = m.installation_id
		WHERE m.created_at >= $1::timestamptz AND m.created_at < $2::timestamptz
		GROUP BY m.installation_id, i.shop_name`,
		from,
		to,
	)
	if err != nil {
		return nil, err
	}
	usage := []SMSInstallationUsage{}
	index := map[string]int{}
	for rows.Next() {
		var row SMSInstallationUsage
		var lastSentAt pgtype.Timestamptz
		if err := rows.Scan(
			&row.InstallationID,
			&row.ShopName,
			&row.Messages,
			&row.Sent,
			&row.Failed,
			&row.Delivered,
			&row.Undelivered,
			&row.Test,
			&row.Parts,
			&row.Cost,
			&row.Charged,
			&lastSentAt,
		); err != nil {
			rows.Close()
			return nil, err
		}
		row.Cost = NormalizeSMSCost(row.Cost)
		row.Charged = NormalizeWalletAmount(row.Charged)
		if lastSentAt.Valid {
			value := lastSentAt.Time.UTC()
			row.LastSentAt = &value
		}
		row.Kinds = map[string]int{}
		index[row.InstallationID] = len(usage)
		usage = append(usage, row)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	kindRows, err := s.pool.Query(
		ctx,
		`SELECT installation_id, kind, count(*)
		FROM relay_sms_messages
		WHERE NOT test_mode AND created_at >= $1::timestamptz AND created_at < $2::timestamptz
		GROUP BY installation_id, kind`,
		from,
		to,
	)
	if err != nil {
		return nil, err
	}
	defer kindRows.Close()
	for kindRows.Next() {
		var installationID, kind string
		var count int
		if err := kindRows.Scan(&installationID, &kind, &count); err != nil {
			return nil, err
		}
		if position, ok := index[installationID]; ok {
			usage[position].Kinds[kind] = count
		}
	}
	if err := kindRows.Err(); err != nil {
		return nil, err
	}
	sortSMSUsage(usage)
	return usage, nil
}

func (s *PostgresStore) ListSMSAwaitingDelivery(
	ctx context.Context,
	since time.Time,
	limit int,
) ([]SMSMessage, error) {
	return s.querySMS(
		ctx,
		false,
		selectSMSSQL+` WHERE m.status = 'sent' AND NOT m.test_mode AND m.created_at >= $1::timestamptz
		ORDER BY m.created_at DESC, m.id DESC LIMIT $2`,
		since,
		normalizedSMSAwaitingLimit(limit),
	)
}

func (s *PostgresStore) UpdateSMSDelivery(
	ctx context.Context,
	id, status, providerMessageID string,
	at time.Time,
) error {
	if err := validateSMSDelivery(status); err != nil {
		return err
	}
	tag, err := s.pool.Exec(
		ctx,
		`UPDATE relay_sms_messages
		SET
			status = $2::text,
			provider_message_id = CASE WHEN $3::text <> '' THEN $3::text ELSE provider_message_id END,
			delivered_at = CASE WHEN $2::text = 'delivered' THEN $4::timestamptz ELSE delivered_at END,
			updated_at = $5::timestamptz
		WHERE id = $1 AND status = 'sent'`,
		id,
		status,
		strings.TrimSpace(providerMessageID),
		at.UTC(),
		s.clock.Now().UTC(),
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() > 0 {
		return nil
	}
	var exists bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM relay_sms_messages WHERE id = $1)`, id).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return ErrSMSNotFound
	}
	// The row already moved past "sent"; a later report never walks it back.
	return nil
}

func (s *PostgresStore) querySMS(ctx context.Context, withShop bool, sql string, args ...any) ([]SMSMessage, error) {
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	messages := []SMSMessage{}
	for rows.Next() {
		message, err := scanSMSMessage(rows, withShop)
		if err != nil {
			return nil, err
		}
		messages = append(messages, message)
	}
	return messages, rows.Err()
}

func scanSMSMessage(row pgx.Row, withShop bool) (SMSMessage, error) {
	var message SMSMessage
	var sentAt, deliveredAt, heldSince pgtype.Timestamptz
	dest := []any{
		&message.ID,
		&message.InstallationID,
		&message.IdempotencyKey,
		&message.Kind,
		&message.ConsentClass,
		&message.Recipient,
		&message.ContentSHA256,
		&message.TemplateID,
		&message.TemplateBody,
		&message.TestMode,
		&message.Status,
		&message.ErrorCode,
		&message.ErrorDetail,
		&message.Cost,
		&message.Price,
		&message.Parts,
		&message.ProviderMessageID,
		&message.CreatedAt,
		&message.UpdatedAt,
		&sentAt,
		&deliveredAt,
		&heldSince,
	}
	if withShop {
		dest = append(dest, &message.ShopName)
	}
	if err := row.Scan(dest...); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return SMSMessage{}, ErrSMSNotFound
		}
		return SMSMessage{}, err
	}
	message.Cost = NormalizeSMSCost(message.Cost)
	message.Price = NormalizeWalletAmount(message.Price)
	message.CreatedAt = message.CreatedAt.UTC()
	message.UpdatedAt = message.UpdatedAt.UTC()
	if sentAt.Valid {
		value := sentAt.Time.UTC()
		message.SentAt = &value
	}
	if deliveredAt.Valid {
		value := deliveredAt.Time.UTC()
		message.DeliveredAt = &value
	}
	if heldSince.Valid {
		value := heldSince.Time.UTC()
		message.HeldSince = &value
	}
	return message, nil
}
