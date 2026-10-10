package control

import (
	"context"
	"encoding/json"
	"errors"
	"hash/fnv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// voucherPurchaseColumns is the canonical column order for scanVoucherPurchase.
// Every query aliases relay_voucher_purchases as p.
const voucherPurchaseColumns = `p.id,
	p.installation_id,
	p.idempotency_key,
	p.item_key,
	p.brand_key,
	p.item_name,
	p.quantity,
	p.unit_price::text,
	p.amount::text,
	p.supplier,
	p.supplier_ref,
	p.supplier_order_id,
	p.supplier_cost,
	p.supplier_currency,
	p.status,
	p.error_code,
	p.error_detail,
	p.test_mode,
	p.requested_by,
	p.held_since,
	p.created_at,
	p.updated_at,
	p.completed_at,
	p.kind,
	p.target,
	COALESCE(p.details::text, '')`

const selectVoucherPurchaseSQL = `SELECT ` + voucherPurchaseColumns + ` FROM relay_voucher_purchases p`

const selectVoucherPurchaseWithShopSQL = `SELECT ` + voucherPurchaseColumns + `, COALESCE(i.shop_name, '')
FROM relay_voucher_purchases p
LEFT JOIN relay_installations i ON i.id = p.installation_id`

const voucherCatalogHeadColumns = `id, sha256, actor, note, created_at`

// The settings history has the catalogs' shape: a head without the document
// for listings, the document on top for the current version.
const voucherSettingsHeadColumns = `id, sha256, actor, note, created_at`

// The supplier-order index of migration 20: a second purchase claiming an
// order one already holds.
const voucherSupplierOrderIndex = "relay_voucher_purchases_supplier_order_idx"

// voucherClaimLockKey maps an installation to the advisory lock that
// serializes its purchase claims, as smsClaimLockKey does for messages.
func voucherClaimLockKey(installationID string) int64 {
	hash := fnv.New64a()
	_, _ = hash.Write([]byte("pointy-relay-voucher-claim:" + installationID))
	return int64(hash.Sum64())
}

func (s *PostgresStore) CurrentVoucherCatalog(ctx context.Context) (VoucherCatalog, error) {
	var catalog VoucherCatalog
	var document string
	err := s.pool.QueryRow(
		ctx,
		`SELECT `+voucherCatalogHeadColumns+`, document::text FROM relay_voucher_catalogs
		ORDER BY created_at DESC, id DESC LIMIT 1`,
	).Scan(&catalog.ID, &catalog.SHA256, &catalog.Actor, &catalog.Note, &catalog.CreatedAt, &document)
	if errors.Is(err, pgx.ErrNoRows) {
		return VoucherCatalog{}, ErrVoucherCatalogNotFound
	}
	if err != nil {
		return VoucherCatalog{}, err
	}
	catalog.Document = []byte(document)
	catalog.CreatedAt = catalog.CreatedAt.UTC()
	return catalog, nil
}

func (s *PostgresStore) VoucherCatalogHead(ctx context.Context) (VoucherCatalog, error) {
	var catalog VoucherCatalog
	err := s.pool.QueryRow(
		ctx,
		`SELECT `+voucherCatalogHeadColumns+` FROM relay_voucher_catalogs
		ORDER BY created_at DESC, id DESC LIMIT 1`,
	).Scan(&catalog.ID, &catalog.SHA256, &catalog.Actor, &catalog.Note, &catalog.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return VoucherCatalog{}, ErrVoucherCatalogNotFound
	}
	if err != nil {
		return VoucherCatalog{}, err
	}
	catalog.CreatedAt = catalog.CreatedAt.UTC()
	return catalog, nil
}

func (s *PostgresStore) GetVoucherCatalog(ctx context.Context, id string) (VoucherCatalog, error) {
	var catalog VoucherCatalog
	var document string
	err := s.pool.QueryRow(
		ctx,
		`SELECT `+voucherCatalogHeadColumns+`, document::text FROM relay_voucher_catalogs WHERE id = $1`,
		strings.TrimSpace(id),
	).Scan(&catalog.ID, &catalog.SHA256, &catalog.Actor, &catalog.Note, &catalog.CreatedAt, &document)
	if errors.Is(err, pgx.ErrNoRows) {
		return VoucherCatalog{}, ErrVoucherCatalogNotFound
	}
	if err != nil {
		return VoucherCatalog{}, err
	}
	catalog.Document = []byte(document)
	catalog.CreatedAt = catalog.CreatedAt.UTC()
	return catalog, nil
}

func (s *PostgresStore) ListVoucherCatalogs(ctx context.Context, limit int) ([]VoucherCatalog, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT `+voucherCatalogHeadColumns+` FROM relay_voucher_catalogs
		ORDER BY created_at DESC, id DESC LIMIT $1`,
		normalizedVoucherListLimit(limit),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	catalogs := []VoucherCatalog{}
	for rows.Next() {
		var catalog VoucherCatalog
		if err := rows.Scan(&catalog.ID, &catalog.SHA256, &catalog.Actor, &catalog.Note, &catalog.CreatedAt); err != nil {
			return nil, err
		}
		catalog.CreatedAt = catalog.CreatedAt.UTC()
		catalogs = append(catalogs, catalog)
	}
	return catalogs, rows.Err()
}

func (s *PostgresStore) PublishVoucherCatalog(ctx context.Context, catalog VoucherCatalog) (VoucherCatalog, error) {
	catalog, err := prepareVoucherCatalog(catalog, s.clock.Now())
	if err != nil {
		return VoucherCatalog{}, err
	}
	if _, err := s.pool.Exec(
		ctx,
		`INSERT INTO relay_voucher_catalogs (id, sha256, document, actor, note, created_at)
		VALUES ($1, $2, $3::jsonb, $4, $5, $6::timestamptz)`,
		catalog.ID,
		catalog.SHA256,
		string(catalog.Document),
		catalog.Actor,
		catalog.Note,
		catalog.CreatedAt,
	); err != nil {
		return VoucherCatalog{}, err
	}
	return catalog, nil
}

func (s *PostgresStore) CurrentVoucherSettings(ctx context.Context) (VoucherSettingsRecord, error) {
	var record VoucherSettingsRecord
	var document string
	err := s.pool.QueryRow(
		ctx,
		`SELECT `+voucherSettingsHeadColumns+`, document::text FROM relay_voucher_settings
		ORDER BY created_at DESC, id DESC LIMIT 1`,
	).Scan(&record.ID, &record.SHA256, &record.Actor, &record.Note, &record.CreatedAt, &document)
	if errors.Is(err, pgx.ErrNoRows) {
		return VoucherSettingsRecord{}, ErrVoucherSettingsNotFound
	}
	if err != nil {
		return VoucherSettingsRecord{}, err
	}
	record.Document = []byte(document)
	record.CreatedAt = record.CreatedAt.UTC()
	return record, nil
}

func (s *PostgresStore) PublishVoucherSettings(ctx context.Context, record VoucherSettingsRecord) (VoucherSettingsRecord, error) {
	record, err := prepareVoucherSettings(record, s.clock.Now())
	if err != nil {
		return VoucherSettingsRecord{}, err
	}
	// The last version published is the current one, whatever the clocks say:
	// a version never sorts before the one it replaces, even when the relay
	// node that took it runs behind the one that took the last (GREATEST skips
	// the NULL of an empty table).
	if err := s.pool.QueryRow(
		ctx,
		`INSERT INTO relay_voucher_settings (id, sha256, document, actor, note, created_at)
		VALUES (
			$1, $2, $3::text::jsonb, $4, $5,
			GREATEST(
				$6::timestamptz,
				(SELECT max(created_at) FROM relay_voucher_settings) + interval '1 microsecond'
			)
		)
		RETURNING created_at`,
		record.ID,
		record.SHA256,
		string(record.Document),
		record.Actor,
		record.Note,
		record.CreatedAt,
	).Scan(&record.CreatedAt); err != nil {
		return VoucherSettingsRecord{}, err
	}
	record.CreatedAt = record.CreatedAt.UTC()
	return record, nil
}

func (s *PostgresStore) ListVoucherSettings(ctx context.Context, limit int) ([]VoucherSettingsRecord, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT `+voucherSettingsHeadColumns+` FROM relay_voucher_settings
		ORDER BY created_at DESC, id DESC LIMIT $1`,
		normalizedVoucherListLimit(limit),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	records := []VoucherSettingsRecord{}
	for rows.Next() {
		var record VoucherSettingsRecord
		if err := rows.Scan(&record.ID, &record.SHA256, &record.Actor, &record.Note, &record.CreatedAt); err != nil {
			return nil, err
		}
		record.CreatedAt = record.CreatedAt.UTC()
		records = append(records, record)
	}
	return records, rows.Err()
}

func (s *PostgresStore) PutVoucherImage(ctx context.Context, image VoucherImage) (VoucherImage, bool, error) {
	image.SHA256 = strings.ToLower(strings.TrimSpace(image.SHA256))
	if image.SHA256 == "" || len(image.Data) == 0 {
		return VoucherImage{}, false, errors.New("a voucher image needs its bytes and their SHA-256")
	}
	image.CreatedAt = s.clock.Now().UTC()
	tag, err := s.pool.Exec(
		ctx,
		`INSERT INTO relay_voucher_images (sha256, content_type, data, width, height, created_at)
		VALUES ($1, $2, $3, $4, $5, $6::timestamptz)
		ON CONFLICT (sha256) DO NOTHING`,
		image.SHA256,
		image.ContentType,
		image.Data,
		image.Width,
		image.Height,
		image.CreatedAt,
	)
	if err != nil {
		return VoucherImage{}, false, err
	}
	if tag.RowsAffected() == 1 {
		return image, true, nil
	}
	existing, err := s.GetVoucherImage(ctx, image.SHA256)
	return existing, false, err
}

func (s *PostgresStore) GetVoucherImage(ctx context.Context, sha256 string) (VoucherImage, error) {
	var image VoucherImage
	err := s.pool.QueryRow(
		ctx,
		`SELECT sha256, content_type, data, width, height, created_at FROM relay_voucher_images WHERE sha256 = $1`,
		strings.ToLower(strings.TrimSpace(sha256)),
	).Scan(&image.SHA256, &image.ContentType, &image.Data, &image.Width, &image.Height, &image.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return VoucherImage{}, ErrVoucherImageNotFound
	}
	if err != nil {
		return VoucherImage{}, err
	}
	image.CreatedAt = image.CreatedAt.UTC()
	return image, nil
}

func (s *PostgresStore) MissingVoucherImages(ctx context.Context, sha256s []string) ([]string, error) {
	wanted := make([]string, 0, len(sha256s))
	for _, sum := range sha256s {
		wanted = append(wanted, strings.ToLower(strings.TrimSpace(sum)))
	}
	rows, err := s.pool.Query(ctx, `SELECT sha256 FROM relay_voucher_images WHERE sha256 = ANY($1)`, wanted)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	stored := map[string]bool{}
	for rows.Next() {
		var sum string
		if err := rows.Scan(&sum); err != nil {
			return nil, err
		}
		stored[sum] = true
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	missing := []string{}
	for _, sum := range wanted {
		if !stored[sum] {
			missing = append(missing, sum)
		}
	}
	return missing, nil
}

func (s *PostgresStore) ReplaceVoucherOffers(ctx context.Context, supplier string, offers []VoucherOffer) error {
	supplier = strings.TrimSpace(supplier)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	// What was there, for each offer's price history.
	byRef := map[string]VoucherOffer{}
	rows, err := tx.Query(ctx, `SELECT ref, price, previous_price, price_changed_at FROM relay_voucher_offers WHERE supplier = $1`, supplier)
	if err != nil {
		return err
	}
	for rows.Next() {
		var offer VoucherOffer
		if err := rows.Scan(&offer.Ref, &offer.Price, &offer.PreviousPrice, &offer.PriceChangedAt); err != nil {
			rows.Close()
			return err
		}
		byRef[offer.Ref] = offer
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	offers = carryVoucherPriceHistory(byRef, offers, s.clock.Now())

	if _, err := tx.Exec(ctx, `DELETE FROM relay_voucher_offers WHERE supplier = $1`, supplier); err != nil {
		return err
	}
	batch := &pgx.Batch{}
	for _, offer := range offers {
		batch.Queue(
			`INSERT INTO relay_voucher_offers (supplier, ref, name, group_name, price, currency, in_stock, synced_at,
				previous_price, price_changed_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8::timestamptz, $9, $10)
			ON CONFLICT (supplier, ref) DO UPDATE SET
				name = EXCLUDED.name, group_name = EXCLUDED.group_name, price = EXCLUDED.price,
				currency = EXCLUDED.currency, in_stock = EXCLUDED.in_stock, synced_at = EXCLUDED.synced_at,
				previous_price = EXCLUDED.previous_price, price_changed_at = EXCLUDED.price_changed_at`,
			supplier,
			offer.Ref,
			offer.Name,
			offer.Group,
			offer.Price,
			offer.Currency,
			offer.InStock,
			offer.SyncedAt.UTC(),
			offer.PreviousPrice,
			offer.PriceChangedAt,
		)
	}
	if batch.Len() > 0 {
		if err := tx.SendBatch(ctx, batch).Close(); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func (s *PostgresStore) ListVoucherOffers(ctx context.Context, supplier string) ([]VoucherOffer, error) {
	supplier = strings.TrimSpace(supplier)
	rows, err := s.pool.Query(
		ctx,
		`SELECT supplier, ref, name, group_name, price, currency, in_stock, synced_at, previous_price, price_changed_at
		FROM relay_voucher_offers
		WHERE $1 = '' OR supplier = $1
		ORDER BY supplier, group_name, name`,
		supplier,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	offers := []VoucherOffer{}
	for rows.Next() {
		var offer VoucherOffer
		if err := rows.Scan(
			&offer.Supplier, &offer.Ref, &offer.Name, &offer.Group,
			&offer.Price, &offer.Currency, &offer.InStock, &offer.SyncedAt, &offer.PreviousPrice, &offer.PriceChangedAt,
		); err != nil {
			return nil, err
		}
		offer.SyncedAt = offer.SyncedAt.UTC()
		offers = append(offers, offer)
	}
	return offers, rows.Err()
}

func (s *PostgresStore) BeginVoucherPurchase(ctx context.Context, purchase VoucherPurchase) (VoucherPurchase, bool, error) {
	claim, _, err := prepareVoucherPurchase(purchase, s.clock.Now())
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	defer tx.Rollback(ctx)

	// One shop's claims go through one at a time, so the key check, the
	// charge and the insert are a single step. The charge also locks the
	// voucher balance row, which is what a transfer into it waits on.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, voucherClaimLockKey(claim.InstallationID)); err != nil {
		return VoucherPurchase{}, false, err
	}
	existing, err := scanVoucherPurchase(tx.QueryRow(
		ctx,
		selectVoucherPurchaseSQL+` WHERE p.installation_id = $1 AND p.idempotency_key = $2`,
		claim.InstallationID,
		claim.IdempotencyKey,
	), false)
	if err == nil {
		if err := tx.Commit(ctx); err != nil {
			return VoucherPurchase{}, false, err
		}
		return existing, false, nil
	}
	if !errors.Is(err, ErrVoucherPurchaseNotFound) {
		return VoucherPurchase{}, false, err
	}
	posting, err := prepareWalletPosting(voucherChargePosting(claim))
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	if _, _, err := s.postWalletEntryTx(ctx, tx, posting); err != nil {
		return VoucherPurchase{}, false, err
	}
	// No details is NULL, not an empty document.
	var details any
	if len(claim.Details) > 0 {
		details = string(claim.Details)
	}
	inserted, err := scanVoucherPurchase(tx.QueryRow(
		ctx,
		`INSERT INTO relay_voucher_purchases AS p (
			id, installation_id, idempotency_key, item_key, brand_key, item_name,
			quantity, unit_price, amount, supplier, supplier_ref, status,
			test_mode, requested_by, created_at, updated_at,
			kind, target, details
		) VALUES (
			$1, $2, $3, $4, $5, $6,
			$7, $8::text::numeric, $9::text::numeric, $10, $11, $12,
			$13, $14, $15::timestamptz, $16::timestamptz,
			$17, $18, $19::text::jsonb
		) RETURNING `+voucherPurchaseColumns,
		claim.ID,
		claim.InstallationID,
		claim.IdempotencyKey,
		claim.ItemKey,
		claim.BrandKey,
		claim.ItemName,
		claim.Quantity,
		claim.UnitPrice,
		claim.Amount,
		claim.Supplier,
		claim.SupplierRef,
		claim.Status,
		claim.TestMode,
		claim.RequestedBy,
		claim.CreatedAt,
		claim.UpdatedAt,
		claim.Kind,
		claim.Target,
		details,
	), false)
	if err != nil {
		if code, _ := pgErrorCode(err); code == pgForeignKeyViolation {
			return VoucherPurchase{}, false, ErrNotFound
		}
		return VoucherPurchase{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return VoucherPurchase{}, false, err
	}
	return inserted, true, nil
}

func (s *PostgresStore) FindVoucherPurchaseByKey(
	ctx context.Context,
	installationID, idempotencyKey string,
) (VoucherPurchase, bool, error) {
	purchase, err := scanVoucherPurchase(s.pool.QueryRow(
		ctx,
		selectVoucherPurchaseSQL+` WHERE p.installation_id = $1 AND p.idempotency_key = $2`,
		strings.TrimSpace(installationID),
		strings.TrimSpace(idempotencyKey),
	), false)
	if errors.Is(err, ErrVoucherPurchaseNotFound) {
		return VoucherPurchase{}, false, nil
	}
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	return purchase, true, nil
}

func (s *PostgresStore) GetVoucherPurchase(ctx context.Context, id string) (VoucherPurchase, error) {
	return scanVoucherPurchase(s.pool.QueryRow(ctx, selectVoucherPurchaseSQL+` WHERE p.id = $1`, strings.TrimSpace(id)), false)
}

// RedirectVoucherPurchase is one conditional UPDATE: the row changes only if it
// is still pending, not held and without a supplier order at the moment it is
// written. Under READ COMMITTED an UPDATE that meets a concurrent writer waits
// for it and then re-checks its WHERE against the new row, so a purchase that
// another request finished, held or gave an order a moment ago is never
// redirected.
func (s *PostgresStore) RedirectVoucherPurchase(
	ctx context.Context,
	id, supplier, supplierRef string,
) (VoucherPurchase, bool, error) {
	id = strings.TrimSpace(id)
	supplier = strings.TrimSpace(supplier)
	supplierRef = strings.TrimSpace(supplierRef)
	if supplier == "" {
		return VoucherPurchase{}, false, errors.New("a redirected voucher purchase needs a supplier")
	}
	redirected, err := scanVoucherPurchase(s.pool.QueryRow(
		ctx,
		`UPDATE relay_voucher_purchases AS p SET
			supplier = $2,
			supplier_ref = $3,
			updated_at = $4::timestamptz
		WHERE p.id = $1
			AND p.status = 'pending'
			AND p.held_since IS NULL
			AND p.supplier_order_id = ''
		RETURNING `+voucherPurchaseColumns,
		id,
		supplier,
		supplierRef,
		s.clock.Now().UTC(),
	), false)
	if err == nil {
		return redirected, true, nil
	}
	if !errors.Is(err, ErrVoucherPurchaseNotFound) {
		return VoucherPurchase{}, false, err
	}
	// Nothing was updated: there is no such purchase, or it is past the point
	// of being redirected. Say which, and hand back the row as it stands.
	existing, err := s.GetVoucherPurchase(ctx, id)
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	return existing, false, nil
}

func (s *PostgresStore) FinishVoucherPurchase(
	ctx context.Context,
	id string,
	outcome VoucherPurchaseOutcome,
) (VoucherPurchase, bool, error) {
	return s.settleVoucherPurchase(ctx, id, func(existing VoucherPurchase, now time.Time) (bool, VoucherPurchase, *preparedWalletPosting, error) {
		if existing.Status != VoucherPurchasePending || existing.HeldSince != nil {
			return false, existing, nil, nil
		}
		finished, posting, err := applyVoucherOutcome(existing, outcome, now)
		return true, finished, posting, err
	})
}

func (s *PostgresStore) ResolveVoucherPurchase(
	ctx context.Context,
	id string,
	resolution VoucherPurchaseResolution,
) (VoucherPurchase, bool, error) {
	return s.settleVoucherPurchase(ctx, id, func(existing VoucherPurchase, now time.Time) (bool, VoucherPurchase, *preparedWalletPosting, error) {
		if existing.Status != VoucherPurchasePending {
			return false, existing, nil, nil
		}
		resolved, posting, err := resolveVoucherPurchase(existing, resolution, now)
		return true, resolved, posting, err
	})
}

// settleVoucherPurchase locks a purchase row, lets decide say what it becomes,
// and writes that and its money movement in one transaction.
func (s *PostgresStore) settleVoucherPurchase(
	ctx context.Context,
	id string,
	decide func(existing VoucherPurchase, now time.Time) (bool, VoucherPurchase, *preparedWalletPosting, error),
) (VoucherPurchase, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	defer tx.Rollback(ctx)

	existing, err := scanVoucherPurchase(tx.QueryRow(
		ctx,
		selectVoucherPurchaseSQL+` WHERE p.id = $1 FOR UPDATE`,
		strings.TrimSpace(id),
	), false)
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	apply, updated, posting, err := decide(existing, s.clock.Now())
	if err != nil {
		return VoucherPurchase{}, false, err
	}
	if !apply {
		if err := tx.Commit(ctx); err != nil {
			return VoucherPurchase{}, false, err
		}
		return existing, false, nil
	}
	if posting != nil {
		if _, _, err := s.postWalletEntryTx(ctx, tx, *posting); err != nil {
			return VoucherPurchase{}, false, err
		}
	}
	var heldSince, completedAt any
	if updated.HeldSince != nil {
		heldSince = updated.HeldSince.UTC()
	}
	if updated.CompletedAt != nil {
		completedAt = updated.CompletedAt.UTC()
	}
	stored, err := scanVoucherPurchase(tx.QueryRow(
		ctx,
		`UPDATE relay_voucher_purchases AS p SET
			status = $2,
			supplier_order_id = $3,
			supplier_cost = $4,
			supplier_currency = $5,
			error_code = $6,
			error_detail = $7,
			held_since = $8::timestamptz,
			updated_at = $9::timestamptz,
			completed_at = $10::timestamptz
		WHERE p.id = $1
		RETURNING `+voucherPurchaseColumns,
		updated.ID,
		updated.Status,
		updated.SupplierOrderID,
		updated.SupplierCost,
		updated.SupplierCurrency,
		updated.ErrorCode,
		updated.ErrorDetail,
		heldSince,
		updated.UpdatedAt,
		completedAt,
	), false)
	if err != nil {
		if code, constraint := pgErrorCode(err); code == pgUniqueViolation && constraint == voucherSupplierOrderIndex {
			return VoucherPurchase{}, false, ErrVoucherOrderClaimed
		}
		return VoucherPurchase{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return VoucherPurchase{}, false, err
	}
	return stored, true, nil
}

func (s *PostgresStore) ListVoucherPurchases(ctx context.Context, filter VoucherPurchaseFilter) ([]VoucherPurchase, error) {
	return s.queryVoucherPurchases(
		ctx,
		true,
		selectVoucherPurchaseWithShopSQL+`
		WHERE ($1 = '' OR p.installation_id = $1)
			AND ($2 = '' OR p.status = $2)
			AND (NOT $3 OR p.held_since IS NOT NULL)
			AND ($4 = '' OR p.kind = $4)
		ORDER BY p.created_at DESC, p.id DESC
		LIMIT $5`,
		strings.TrimSpace(filter.InstallationID),
		strings.TrimSpace(filter.Status),
		filter.HeldOnly,
		voucherKindFilter(filter.Kind),
		normalizedVoucherListLimit(filter.Limit),
	)
}

func (s *PostgresStore) ListVoucherPurchasesAwaitingCheck(
	ctx context.Context,
	staleBefore time.Time,
	limit int,
) ([]VoucherPurchase, error) {
	return s.queryVoucherPurchases(
		ctx,
		false,
		selectVoucherPurchaseSQL+`
		WHERE p.status = 'pending' AND (p.held_since IS NOT NULL OR p.created_at < $1::timestamptz)
		ORDER BY p.created_at, p.id
		LIMIT $2`,
		staleBefore.UTC(),
		normalizedVoucherAwaitingLimit(limit),
	)
}

func (s *PostgresStore) VoucherClaimedSupplierOrders(
	ctx context.Context,
	supplier string,
	orderIDs []string,
) (map[string]bool, error) {
	ids := make([]string, 0, len(orderIDs))
	for _, id := range orderIDs {
		if id = strings.TrimSpace(id); id != "" {
			ids = append(ids, id)
		}
	}
	claimed := map[string]bool{}
	if len(ids) == 0 {
		return claimed, nil
	}
	rows, err := s.pool.Query(
		ctx,
		`SELECT supplier_order_id FROM relay_voucher_purchases WHERE supplier = $1 AND supplier_order_id = ANY($2)`,
		strings.TrimSpace(supplier),
		ids,
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

func (s *PostgresStore) queryVoucherPurchases(ctx context.Context, withShop bool, sql string, args ...any) ([]VoucherPurchase, error) {
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	purchases := []VoucherPurchase{}
	for rows.Next() {
		purchase, err := scanVoucherPurchase(rows, withShop)
		if err != nil {
			return nil, err
		}
		purchases = append(purchases, purchase)
	}
	return purchases, rows.Err()
}

func scanVoucherPurchase(row pgx.Row, withShop bool) (VoucherPurchase, error) {
	var purchase VoucherPurchase
	var heldSince, completedAt pgtype.Timestamptz
	var details string
	dest := []any{
		&purchase.ID,
		&purchase.InstallationID,
		&purchase.IdempotencyKey,
		&purchase.ItemKey,
		&purchase.BrandKey,
		&purchase.ItemName,
		&purchase.Quantity,
		&purchase.UnitPrice,
		&purchase.Amount,
		&purchase.Supplier,
		&purchase.SupplierRef,
		&purchase.SupplierOrderID,
		&purchase.SupplierCost,
		&purchase.SupplierCurrency,
		&purchase.Status,
		&purchase.ErrorCode,
		&purchase.ErrorDetail,
		&purchase.TestMode,
		&purchase.RequestedBy,
		&heldSince,
		&purchase.CreatedAt,
		&purchase.UpdatedAt,
		&completedAt,
		&purchase.Kind,
		&purchase.Target,
		&details,
	}
	if withShop {
		dest = append(dest, &purchase.ShopName)
	}
	if err := row.Scan(dest...); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return VoucherPurchase{}, ErrVoucherPurchaseNotFound
		}
		return VoucherPurchase{}, err
	}
	purchase.UnitPrice = NormalizeWalletAmount(purchase.UnitPrice)
	purchase.Amount = NormalizeWalletAmount(purchase.Amount)
	purchase.Kind = NormalizeVoucherKind(purchase.Kind)
	if details != "" {
		purchase.Details = json.RawMessage(details)
	}
	purchase.CreatedAt = purchase.CreatedAt.UTC()
	purchase.UpdatedAt = purchase.UpdatedAt.UTC()
	if heldSince.Valid {
		value := heldSince.Time.UTC()
		purchase.HeldSince = &value
	}
	if completedAt.Valid {
		value := completedAt.Time.UTC()
		purchase.CompletedAt = &value
	}
	return purchase, nil
}
