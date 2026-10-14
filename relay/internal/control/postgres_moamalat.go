package control

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// Every time in the keepalive is Postgres's now(): several relay instances
// share the queue, and the only clock they all agree on is the database's
// (TOKEN_CUSTODY_DESIGN.md — a holder compares only against its own clock).

const selectMoamalatLinkColumns = `installation_id, mid, token_id, sealed_token, state,
	last_ok_at, last_attempt_at, last_error, failures, next_poke_at,
	died_at, death_source, linked_at, updated_at`

func scanMoamalatLink(row pgx.Row, extra ...any) (MoamalatLink, error) {
	var link MoamalatLink
	var lastOK, lastAttempt, died pgtype.Timestamptz
	dest := []any{
		&link.InstallationID, &link.MID, &link.TokenID, &link.SealedToken, &link.State,
		&lastOK, &lastAttempt, &link.LastError, &link.Failures, &link.NextPokeAt,
		&died, &link.DeathSource, &link.LinkedAt, &link.UpdatedAt,
	}
	if err := row.Scan(append(dest, extra...)...); err != nil {
		return MoamalatLink{}, err
	}
	if lastOK.Valid {
		link.LastOKAt = lastOK.Time.UTC()
	}
	if lastAttempt.Valid {
		link.LastAttemptAt = lastAttempt.Time.UTC()
	}
	if died.Valid {
		link.DiedAt = died.Time.UTC()
	}
	link.NextPokeAt = link.NextPokeAt.UTC()
	link.LinkedAt = link.LinkedAt.UTC()
	link.UpdatedAt = link.UpdatedAt.UTC()
	return link, nil
}

func (s *PostgresStore) PutMoamalatLink(ctx context.Context, link MoamalatLink) (MoamalatLink, error) {
	link, err := normalizeMoamalatLink(link)
	if err != nil {
		return MoamalatLink{}, err
	}
	return scanMoamalatLink(s.pool.QueryRow(ctx,
		`INSERT INTO relay_moamalat_links (installation_id, mid, token_id, sealed_token, state,
			last_ok_at, last_attempt_at, last_error, failures, next_poke_at,
			died_at, death_source, linked_at, updated_at)
		VALUES ($1, $2, $3, $4, 'alive', NULL, NULL, '', 0, now(), NULL, '', now(), now())
		ON CONFLICT (installation_id) DO UPDATE SET
			mid = EXCLUDED.mid,
			token_id = EXCLUDED.token_id,
			sealed_token = EXCLUDED.sealed_token,
			state = 'alive',
			last_ok_at = NULL,
			last_attempt_at = NULL,
			last_error = '',
			failures = 0,
			next_poke_at = now(),
			died_at = NULL,
			death_source = '',
			linked_at = now(),
			updated_at = now()
		RETURNING `+selectMoamalatLinkColumns,
		link.InstallationID, link.MID, link.TokenID, link.SealedToken,
	))
}

func (s *PostgresStore) GetMoamalatLink(ctx context.Context, installationID string) (MoamalatLink, error) {
	link, err := scanMoamalatLink(s.pool.QueryRow(ctx,
		`SELECT `+selectMoamalatLinkColumns+` FROM relay_moamalat_links WHERE installation_id = $1`,
		installationID,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return MoamalatLink{}, ErrNotFound
	}
	return link, err
}

func (s *PostgresStore) DeleteMoamalatLink(ctx context.Context, installationID string) (bool, error) {
	tag, err := s.pool.Exec(ctx, `DELETE FROM relay_moamalat_links WHERE installation_id = $1`, installationID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (s *PostgresStore) DeleteAllMoamalatLinks(ctx context.Context) (int, error) {
	tag, err := s.pool.Exec(ctx, `DELETE FROM relay_moamalat_links`)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

func (s *PostgresStore) ListMoamalatLinks(ctx context.Context) ([]MoamalatLink, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT `+selectMoamalatLinkColumns+` FROM relay_moamalat_links ORDER BY installation_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	links := []MoamalatLink{}
	for rows.Next() {
		link, err := scanMoamalatLink(rows)
		if err != nil {
			return nil, err
		}
		links = append(links, link)
	}
	return links, rows.Err()
}

// ClaimMoamalatPokes is the queue: FOR UPDATE SKIP LOCKED hands each due row
// to exactly one instance, and the lease (next_poke_at pushed out) keeps it
// from the others until the poke is written back — or the lease runs out
// because the instance died.
func (s *PostgresStore) ClaimMoamalatPokes(ctx context.Context, limit int, lease time.Duration) ([]MoamalatClaim, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := s.pool.Query(ctx,
		`UPDATE relay_moamalat_links AS l
		SET next_poke_at = now() + make_interval(secs => $2::double precision)
		FROM (
			SELECT installation_id FROM relay_moamalat_links
			WHERE state = 'alive' AND sealed_token <> '' AND next_poke_at <= now()
			ORDER BY next_poke_at
			LIMIT $1
			FOR UPDATE SKIP LOCKED
		) AS due
		WHERE l.installation_id = due.installation_id
		RETURNING `+prefixed("l.", selectMoamalatLinkColumns)+`,
			EXTRACT(EPOCH FROM now() - COALESCE(l.last_ok_at, l.linked_at))`,
		limit, lease.Seconds(),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	claims := []MoamalatClaim{}
	for rows.Next() {
		var ageSeconds float64
		link, err := scanMoamalatLink(rows, &ageSeconds)
		if err != nil {
			return nil, err
		}
		claims = append(claims, MoamalatClaim{Link: link, Age: time.Duration(ageSeconds * float64(time.Second))})
	}
	return claims, rows.Err()
}

func (s *PostgresStore) RecordMoamalatPoke(ctx context.Context, poke MoamalatPoke) (MoamalatLink, bool, error) {
	alive := poke.Outcome == "alive"
	link, err := scanMoamalatLink(s.pool.QueryRow(ctx,
		`UPDATE relay_moamalat_links SET
			last_attempt_at = now(),
			next_poke_at = now() + make_interval(secs => $3::double precision),
			last_ok_at = CASE WHEN $4::boolean THEN now() ELSE last_ok_at END,
			failures = CASE WHEN $4::boolean THEN 0 ELSE failures + 1 END,
			last_error = CASE WHEN $4::boolean THEN '' ELSE $5::text END,
			updated_at = now()
		WHERE installation_id = $1 AND token_id = $2 AND state = 'alive'
		RETURNING `+selectMoamalatLinkColumns,
		poke.InstallationID, poke.TokenID, poke.NextIn.Seconds(), alive, truncateRunes(poke.Error, 300),
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return MoamalatLink{}, false, nil
	}
	if err != nil {
		return MoamalatLink{}, false, err
	}
	return link, true, nil
}

func (s *PostgresStore) MarkMoamalatDead(ctx context.Context, installationID, tokenID, source string) (MoamalatLink, bool, error) {
	link, err := scanMoamalatLink(s.pool.QueryRow(ctx,
		`UPDATE relay_moamalat_links SET
			state = 'needs_reauth',
			sealed_token = '',
			died_at = now(),
			death_source = $3,
			updated_at = now()
		WHERE installation_id = $1 AND token_id = $2 AND state = 'alive'
		RETURNING `+selectMoamalatLinkColumns,
		installationID, tokenID, source,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return MoamalatLink{}, false, nil
	}
	if err != nil {
		return MoamalatLink{}, false, err
	}
	return link, true, nil
}

// prefixed qualifies a comma-separated column list with a table alias.
func prefixed(alias, columns string) string {
	out := []byte{}
	start := true
	for i := 0; i < len(columns); i++ {
		c := columns[i]
		if start && c != ' ' && c != '\n' && c != '\t' {
			out = append(out, alias...)
			start = false
		}
		out = append(out, c)
		if c == ',' {
			start = true
		}
	}
	return string(out)
}
