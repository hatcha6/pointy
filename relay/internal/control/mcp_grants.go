package control

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// An MCP grant is one Claude connector's read-only access to the business
// tools at /mcp (internal/agentmcp). It is NEVER the fleet admin token: an
// operator signed in to the console approves it (OAuth) or the CLI mints it
// (a static token), and it can be revoked on its own.
//
// Only hashes are stored. An OAuth grant starts as an authorization code; the
// token request takes the code (once) and sets the access and refresh tokens.
// Every refresh rotates the refresh token; presenting the one it replaced
// revokes the grant, as a stolen copy would.
type MCPGrant struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Kind is MCPGrantOAuth or MCPGrantToken.
	Kind        string `json:"kind"`
	ClientID    string `json:"client_id,omitempty"`
	RedirectURI string `json:"redirect_uri,omitempty"`
	Scope       string `json:"scope"`
	GrantedByID string `json:"granted_by_id"`
	GrantedBy   string `json:"granted_by"`

	CodeHash      string     `json:"-"`
	CodeChallenge string     `json:"-"`
	CodeExpiresAt *time.Time `json:"-"`

	AccessHash       string     `json:"-"`
	AccessExpiresAt  *time.Time `json:"access_expires_at,omitempty"`
	RefreshHash      string     `json:"-"`
	RefreshExpiresAt *time.Time `json:"refresh_expires_at,omitempty"`

	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty"`
	RevokedBy  string     `json:"revoked_by,omitempty"`
}

const (
	MCPGrantOAuth = "oauth"
	MCPGrantToken = "token"
)

// MCPGrantTokens is what a token request sets on a grant (hashes only).
type MCPGrantTokens struct {
	AccessHash       string
	AccessExpiresAt  time.Time
	RefreshHash      string
	RefreshExpiresAt time.Time
}

// MCPGrantStore is an optional store capability (type-asserted, like
// ConsoleStore). Grants are never cached: a revocation holds at once.
type MCPGrantStore interface {
	CreateMCPGrant(ctx context.Context, grant MCPGrant) (MCPGrant, error)
	// TakeMCPGrantCode clears a live, unrevoked code and returns its grant;
	// a code works once. ErrMCPGrantNotFound otherwise.
	TakeMCPGrantCode(ctx context.Context, codeHash string) (MCPGrant, error)
	// SetMCPGrantTokens gives an unrevoked grant its tokens.
	SetMCPGrantTokens(ctx context.Context, id string, tokens MCPGrantTokens) (MCPGrant, error)
	// RotateMCPGrantRefresh swaps a live refresh token for new tokens.
	// The refresh token it replaced revokes the grant: ErrMCPGrantReused.
	RotateMCPGrantRefresh(ctx context.Context, refreshHash string, tokens MCPGrantTokens) (MCPGrant, error)
	// MCPGrantByAccess returns the grant of a live access token and notes
	// the use.
	MCPGrantByAccess(ctx context.Context, accessHash string) (MCPGrant, error)
	// MCPGrants lists every grant that got past its code, newest first.
	MCPGrants(ctx context.Context) ([]MCPGrant, error)
	RevokeMCPGrant(ctx context.Context, id string, by string) (MCPGrant, error)
}

var (
	ErrMCPGrantNotFound = errors.New("mcp grant not found, expired or revoked")
	ErrMCPGrantReused   = errors.New("mcp refresh token reused; the grant is revoked")
)

// mcpTouchEvery limits last_used_at writes.
const mcpTouchEvery = time.Minute

// --- postgres ----------------------------------------------------------------

const selectMCPGrantSQL = `SELECT id, name, kind, client_id, redirect_uri, scope, granted_by_id, granted_by,
	COALESCE(code_hash, ''), code_challenge, code_expires_at,
	COALESCE(access_hash, ''), access_expires_at, COALESCE(refresh_hash, ''), refresh_expires_at,
	created_at, last_used_at, revoked_at, revoked_by
	FROM relay_mcp_grants`

const returningMCPGrantSQL = ` RETURNING id, name, kind, client_id, redirect_uri, scope, granted_by_id, granted_by,
	COALESCE(code_hash, ''), code_challenge, code_expires_at,
	COALESCE(access_hash, ''), access_expires_at, COALESCE(refresh_hash, ''), refresh_expires_at,
	created_at, last_used_at, revoked_at, revoked_by`

func scanMCPGrant(row pgx.Row) (MCPGrant, error) {
	var g MCPGrant
	err := row.Scan(&g.ID, &g.Name, &g.Kind, &g.ClientID, &g.RedirectURI, &g.Scope, &g.GrantedByID, &g.GrantedBy,
		&g.CodeHash, &g.CodeChallenge, &g.CodeExpiresAt,
		&g.AccessHash, &g.AccessExpiresAt, &g.RefreshHash, &g.RefreshExpiresAt,
		&g.CreatedAt, &g.LastUsedAt, &g.RevokedAt, &g.RevokedBy)
	if errors.Is(err, pgx.ErrNoRows) {
		return MCPGrant{}, ErrMCPGrantNotFound
	}
	return g, err
}

func mcpNullText(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func (s *PostgresStore) CreateMCPGrant(ctx context.Context, grant MCPGrant) (MCPGrant, error) {
	if grant.ID == "" {
		id, err := NewInstallationID()
		if err != nil {
			return MCPGrant{}, err
		}
		grant.ID = id
	}
	grant.Name = truncateRunes(strings.TrimSpace(grant.Name), 120)
	grant.RedirectURI = truncateRunes(grant.RedirectURI, 500)
	if grant.CreatedAt.IsZero() {
		grant.CreatedAt = s.clock.Now()
	}
	return scanMCPGrant(s.pool.QueryRow(ctx, `INSERT INTO relay_mcp_grants
		(id, name, kind, client_id, redirect_uri, scope, granted_by_id, granted_by,
		 code_hash, code_challenge, code_expires_at, access_hash, access_expires_at,
		 refresh_hash, refresh_expires_at, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)`+returningMCPGrantSQL,
		grant.ID, grant.Name, grant.Kind, grant.ClientID, grant.RedirectURI, grant.Scope, grant.GrantedByID, grant.GrantedBy,
		mcpNullText(grant.CodeHash), grant.CodeChallenge, grant.CodeExpiresAt, mcpNullText(grant.AccessHash), grant.AccessExpiresAt,
		mcpNullText(grant.RefreshHash), grant.RefreshExpiresAt, grant.CreatedAt))
}

func (s *PostgresStore) TakeMCPGrantCode(ctx context.Context, codeHash string) (MCPGrant, error) {
	if codeHash == "" {
		return MCPGrant{}, ErrMCPGrantNotFound
	}
	// The returned row still carries the challenge: only the code is cleared.
	return scanMCPGrant(s.pool.QueryRow(ctx, `WITH taken AS (
			UPDATE relay_mcp_grants SET code_hash = NULL
			WHERE code_hash = $1 AND code_expires_at > $2 AND revoked_at IS NULL
			RETURNING id)
		`+selectMCPGrantSQL+` WHERE id = (SELECT id FROM taken)`, codeHash, s.clock.Now()))
}

func (s *PostgresStore) SetMCPGrantTokens(ctx context.Context, id string, tokens MCPGrantTokens) (MCPGrant, error) {
	return scanMCPGrant(s.pool.QueryRow(ctx, `UPDATE relay_mcp_grants SET
			access_hash = $2, access_expires_at = $3, refresh_hash = $4, refresh_expires_at = $5,
			code_expires_at = NULL, last_used_at = $6
		WHERE id = $1 AND revoked_at IS NULL AND access_hash IS NULL`+returningMCPGrantSQL,
		id, tokens.AccessHash, tokens.AccessExpiresAt, mcpNullText(tokens.RefreshHash), mcpNullTime(tokens.RefreshExpiresAt), s.clock.Now()))
}

func mcpNullTime(at time.Time) any {
	if at.IsZero() {
		return nil
	}
	return at
}

func (s *PostgresStore) RotateMCPGrantRefresh(ctx context.Context, refreshHash string, tokens MCPGrantTokens) (MCPGrant, error) {
	if refreshHash == "" {
		return MCPGrant{}, ErrMCPGrantNotFound
	}
	now := s.clock.Now()
	grant, err := scanMCPGrant(s.pool.QueryRow(ctx, `UPDATE relay_mcp_grants SET
			previous_refresh_hash = refresh_hash,
			access_hash = $2, access_expires_at = $3, refresh_hash = $4, refresh_expires_at = $5, last_used_at = $6
		WHERE refresh_hash = $1 AND refresh_expires_at > $6 AND revoked_at IS NULL`+returningMCPGrantSQL,
		refreshHash, tokens.AccessHash, tokens.AccessExpiresAt, tokens.RefreshHash, tokens.RefreshExpiresAt, now))
	if !errors.Is(err, ErrMCPGrantNotFound) {
		return grant, err
	}
	// A refresh token already swapped: someone else holds a copy.
	tag, err := s.pool.Exec(ctx, `UPDATE relay_mcp_grants SET revoked_at = $2, revoked_by = 'refresh token reused'
		WHERE previous_refresh_hash = $1 AND revoked_at IS NULL`, refreshHash, now)
	if err != nil {
		return MCPGrant{}, err
	}
	if tag.RowsAffected() > 0 {
		return MCPGrant{}, ErrMCPGrantReused
	}
	return MCPGrant{}, ErrMCPGrantNotFound
}

func (s *PostgresStore) MCPGrantByAccess(ctx context.Context, accessHash string) (MCPGrant, error) {
	if accessHash == "" {
		return MCPGrant{}, ErrMCPGrantNotFound
	}
	now := s.clock.Now()
	grant, err := scanMCPGrant(s.pool.QueryRow(ctx, selectMCPGrantSQL+`
		WHERE access_hash = $1 AND access_expires_at > $2 AND revoked_at IS NULL`, accessHash, now))
	if err != nil {
		return grant, err
	}
	if grant.LastUsedAt == nil || now.Sub(*grant.LastUsedAt) >= mcpTouchEvery {
		if _, err := s.pool.Exec(ctx, `UPDATE relay_mcp_grants SET last_used_at = $2 WHERE id = $1`, grant.ID, now); err == nil {
			grant.LastUsedAt = &now
		}
	}
	return grant, nil
}

func (s *PostgresStore) MCPGrants(ctx context.Context) ([]MCPGrant, error) {
	rows, err := s.pool.Query(ctx, selectMCPGrantSQL+` WHERE access_hash IS NOT NULL OR revoked_at IS NOT NULL
		ORDER BY created_at DESC, id DESC LIMIT 200`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	grants := []MCPGrant{}
	for rows.Next() {
		grant, err := scanMCPGrant(rows)
		if err != nil {
			return nil, err
		}
		grants = append(grants, grant)
	}
	return grants, rows.Err()
}

func (s *PostgresStore) RevokeMCPGrant(ctx context.Context, id string, by string) (MCPGrant, error) {
	return scanMCPGrant(s.pool.QueryRow(ctx, `UPDATE relay_mcp_grants SET revoked_at = $2, revoked_by = $3
		WHERE id = $1 AND revoked_at IS NULL`+returningMCPGrantSQL, id, s.clock.Now(), truncateRunes(by, 120)))
}

// --- cached store ------------------------------------------------------------

func (s *CachedInstallationStore) mcpGrantStore() (MCPGrantStore, error) {
	store, ok := s.store.(MCPGrantStore)
	if !ok {
		return nil, errors.New("store does not support MCP grants")
	}
	return store, nil
}

func (s *CachedInstallationStore) CreateMCPGrant(ctx context.Context, grant MCPGrant) (MCPGrant, error) {
	store, err := s.mcpGrantStore()
	if err != nil {
		return MCPGrant{}, err
	}
	return store.CreateMCPGrant(ctx, grant)
}

func (s *CachedInstallationStore) TakeMCPGrantCode(ctx context.Context, codeHash string) (MCPGrant, error) {
	store, err := s.mcpGrantStore()
	if err != nil {
		return MCPGrant{}, err
	}
	return store.TakeMCPGrantCode(ctx, codeHash)
}

func (s *CachedInstallationStore) SetMCPGrantTokens(ctx context.Context, id string, tokens MCPGrantTokens) (MCPGrant, error) {
	store, err := s.mcpGrantStore()
	if err != nil {
		return MCPGrant{}, err
	}
	return store.SetMCPGrantTokens(ctx, id, tokens)
}

func (s *CachedInstallationStore) RotateMCPGrantRefresh(ctx context.Context, refreshHash string, tokens MCPGrantTokens) (MCPGrant, error) {
	store, err := s.mcpGrantStore()
	if err != nil {
		return MCPGrant{}, err
	}
	return store.RotateMCPGrantRefresh(ctx, refreshHash, tokens)
}

func (s *CachedInstallationStore) MCPGrantByAccess(ctx context.Context, accessHash string) (MCPGrant, error) {
	store, err := s.mcpGrantStore()
	if err != nil {
		return MCPGrant{}, err
	}
	return store.MCPGrantByAccess(ctx, accessHash)
}

func (s *CachedInstallationStore) MCPGrants(ctx context.Context) ([]MCPGrant, error) {
	store, err := s.mcpGrantStore()
	if err != nil {
		return nil, err
	}
	return store.MCPGrants(ctx)
}

func (s *CachedInstallationStore) RevokeMCPGrant(ctx context.Context, id string, by string) (MCPGrant, error) {
	store, err := s.mcpGrantStore()
	if err != nil {
		return MCPGrant{}, err
	}
	return store.RevokeMCPGrant(ctx, id, by)
}

var (
	_ MCPGrantStore = (*PostgresStore)(nil)
	_ MCPGrantStore = (*CachedInstallationStore)(nil)
)
