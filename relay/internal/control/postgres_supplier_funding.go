package control

import (
	"context"
	"errors"
	"math/big"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

const supplierFundingColumns = `id, supplier, usd::text, lyd::text, method, reference, market_rate::text, note, actor,
	funded_at, created_at, voided_at, void_reason, void_actor`

func (s *PostgresStore) ListSupplierFundings(ctx context.Context) ([]SupplierFunding, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+supplierFundingColumns+` FROM relay_supplier_fundings ORDER BY funded_at DESC, id DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SupplierFunding{}
	for rows.Next() {
		f, err := scanSupplierFunding(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

func (s *PostgresStore) CreateSupplierFunding(ctx context.Context, f SupplierFunding) (SupplierFunding, error) {
	f, err := NormalizeSupplierFunding(f, s.clock.Now())
	if err != nil {
		return SupplierFunding{}, err
	}
	id, err := NewInstallationID()
	if err != nil {
		return SupplierFunding{}, err
	}
	return scanSupplierFunding(s.pool.QueryRow(ctx,
		`INSERT INTO relay_supplier_fundings (id, supplier, usd, lyd, method, reference, market_rate, note, actor, funded_at, created_at)
		VALUES ($1, $2, $3::numeric, $4::numeric, $5, $6, NULLIF($7, '')::numeric, $8, $9, $10, $11)
		RETURNING `+supplierFundingColumns,
		id, f.Supplier, f.USD, f.LYD, f.Method, f.Reference, f.MarketRate, f.Note, f.Actor, f.FundedAt, f.CreatedAt))
}

func (s *PostgresStore) VoidSupplierFunding(ctx context.Context, id, reason, actor string) (SupplierFunding, error) {
	f, err := scanSupplierFunding(s.pool.QueryRow(ctx,
		`UPDATE relay_supplier_fundings SET voided_at = $2, void_reason = $3, void_actor = $4
		WHERE id = $1 AND voided_at IS NULL
		RETURNING `+supplierFundingColumns,
		id, s.clock.Now(), truncateRunes(reason, maxIntegrationSwitchText), truncateRunes(actor, maxIntegrationSwitchText)))
	if errors.Is(err, pgx.ErrNoRows) {
		var voided bool
		if qerr := s.pool.QueryRow(ctx, `SELECT voided_at IS NOT NULL FROM relay_supplier_fundings WHERE id = $1`, id).Scan(&voided); qerr != nil {
			return SupplierFunding{}, ErrSupplierFundingNotFound
		}
		return SupplierFunding{}, ErrSupplierFundingVoided
	}
	return f, err
}

func (s *PostgresStore) ListExchangeRateSeries(ctx context.Context, from, to, instrument, bankCode string, since time.Time) ([]ExchangeRate, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT `+exchangeRateColumns+` FROM (
			SELECT `+exchangeRateColumns+` FROM relay_exchange_rates
			WHERE from_code = upper($1) AND to_code = upper($2)
				AND instrument = lower($3) AND bank_code = lower($4)
				AND effective_at >= $5
			ORDER BY effective_at DESC LIMIT $6
		) newest ORDER BY effective_at ASC, id ASC`,
		from, to, instrument, bankCode, since, maxFundingSeriesRows)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ExchangeRate{}
	for rows.Next() {
		r, err := scanExchangeRate(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func scanSupplierFunding(row pgx.Row) (SupplierFunding, error) {
	var f SupplierFunding
	var market *string
	var funded, created, voided pgtype.Timestamptz
	if err := row.Scan(&f.ID, &f.Supplier, &f.USD, &f.LYD, &f.Method, &f.Reference, &market, &f.Note, &f.Actor,
		&funded, &created, &voided, &f.VoidReason, &f.VoidActor); err != nil {
		return SupplierFunding{}, err
	}
	f.USD, f.LYD = fixedDecimal(f.USD, 4), fixedDecimal(f.LYD, 3)
	if market != nil {
		f.MarketRate = fixedDecimal(*market, 4)
	}
	if funded.Valid {
		f.FundedAt = funded.Time.UTC()
	}
	if created.Valid {
		f.CreatedAt = created.Time.UTC()
	}
	if voided.Valid {
		t := voided.Time.UTC()
		f.VoidedAt = &t
	}
	return f, nil
}

// fixedDecimal is a numeric column's text with a fixed number of places.
func fixedDecimal(text string, places int) string {
	if r, ok := new(big.Rat).SetString(text); ok {
		return r.FloatString(places)
	}
	return text
}
