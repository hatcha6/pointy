package control

import (
	"context"
	"errors"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The operator console: the company's own people signing in to manage the
// relay from a browser. Each operator is named and signs in with passkeys
// only — there is no password to leak or guess — so every change the console
// makes is recorded under a real person instead of a shared admin token.
//
// The store keeps five things:
//   - operators and their passkeys (a passkey is a WebAuthn credential; its
//     public key and counters are kept as the library's own JSON);
//   - sessions, by the SHA-256 of the cookie, never the cookie itself;
//   - one-time tokens: invites, WebAuthn ceremony challenges and step-up
//     grants. A token is taken atomically, so with autoscaled instances a
//     ceremony begun on one instance finishes on another, and a grant
//     authorizes exactly one action;
//   - the console's audit log: every change, by whom, with its request.

// ConsoleOperator is one person allowed into the console.
type ConsoleOperator struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	CreatedAt  time.Time  `json:"created_at"`
	CreatedBy  string     `json:"created_by"`
	DisabledAt *time.Time `json:"disabled_at,omitempty"`
}

// Active is false once the operator was disabled.
func (o ConsoleOperator) Active() bool { return o.DisabledAt == nil }

// ConsolePasskey is one device's credential for an operator.
type ConsolePasskey struct {
	// ID is the WebAuthn credential id, base64url.
	ID         string     `json:"id"`
	OperatorID string     `json:"operator_id"`
	Label      string     `json:"label"`
	Credential []byte     `json:"credential"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
}

// ConsoleSession is a signed-in browser.
type ConsoleSession struct {
	IDHash     string    `json:"id_hash"`
	OperatorID string    `json:"operator_id"`
	CreatedAt  time.Time `json:"created_at"`
	LastSeenAt time.Time `json:"last_seen_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	IP         string    `json:"ip"`
	UserAgent  string    `json:"user_agent"`
}

// ConsoleToken is a one-time token: an invite, a ceremony challenge, a grant.
type ConsoleToken struct {
	Hash       string    `json:"hash"`
	Kind       string    `json:"kind"`
	OperatorID string    `json:"operator_id"`
	Subject    string    `json:"subject"`
	Payload    string    `json:"payload"`
	ExpiresAt  time.Time `json:"expires_at"`
}

// ConsoleAuditEvent is one change made through the console.
type ConsoleAuditEvent struct {
	ID           string    `json:"id"`
	At           time.Time `json:"at"`
	OperatorID   string    `json:"operator_id"`
	OperatorName string    `json:"operator_name"`
	Action       string    `json:"action"`
	Method       string    `json:"method"`
	Path         string    `json:"path"`
	Status       int       `json:"status"`
	Body         string    `json:"body,omitempty"`
	IP           string    `json:"ip"`
	SteppedUp    bool      `json:"stepped_up"`
}

// ConsoleAuditFilter narrows the audit listing; results are newest first.
type ConsoleAuditFilter struct {
	OperatorID string
	// PathPrefix matches the start of the path, e.g. "/v1/wallet/".
	PathPrefix string
	// Query matches anywhere in the path or body (an installation id, say).
	Query    string
	Limit    int
	BeforeID string
}

// ConsoleStore is an optional store capability (type-asserted, like
// AlertStore) backing the operator console.
type ConsoleStore interface {
	CreateConsoleOperator(ctx context.Context, name string, createdBy string) (ConsoleOperator, error)
	ConsoleOperators(ctx context.Context) ([]ConsoleOperator, error)
	ConsoleOperator(ctx context.Context, id string) (ConsoleOperator, error)
	ConsoleOperatorByName(ctx context.Context, name string) (ConsoleOperator, error)
	// SetConsoleOperatorDisabled disables (and signs out) or re-enables one.
	SetConsoleOperatorDisabled(ctx context.Context, id string, disabled bool) (ConsoleOperator, error)

	AddConsolePasskey(ctx context.Context, passkey ConsolePasskey) error
	// ConsolePasskeys lists one operator's passkeys; "" lists every one.
	ConsolePasskeys(ctx context.Context, operatorID string) ([]ConsolePasskey, error)
	ConsolePasskey(ctx context.Context, id string) (ConsolePasskey, error)
	// TouchConsolePasskey stores the credential's new counters after a use.
	TouchConsolePasskey(ctx context.Context, id string, credential []byte) error
	DeleteConsolePasskey(ctx context.Context, id string) error

	CreateConsoleSession(ctx context.Context, session ConsoleSession) error
	ConsoleSession(ctx context.Context, idHash string) (ConsoleSession, error)
	TouchConsoleSession(ctx context.Context, idHash string, expiresAt time.Time) error
	// ConsoleSessions lists live sessions; "" lists every operator's.
	ConsoleSessions(ctx context.Context, operatorID string) ([]ConsoleSession, error)
	DeleteConsoleSession(ctx context.Context, idHash string) error
	DeleteConsoleSessionsOf(ctx context.Context, operatorID string) error

	PutConsoleToken(ctx context.Context, token ConsoleToken) error
	// TakeConsoleToken removes and returns a live token of that kind;
	// ErrConsoleTokenNotFound when it is missing, used or expired.
	TakeConsoleToken(ctx context.Context, kind string, hash string) (ConsoleToken, error)

	AppendConsoleAudit(ctx context.Context, event ConsoleAuditEvent) (ConsoleAuditEvent, error)
	ConsoleAudit(ctx context.Context, filter ConsoleAuditFilter) ([]ConsoleAuditEvent, error)
}

var (
	ErrConsoleOperatorNotFound = errors.New("console operator not found")
	ErrConsoleOperatorExists   = errors.New("a console operator with that name exists")
	ErrConsoleOperatorName     = errors.New("console operator name must be 1-60 characters")
	ErrConsolePasskeyNotFound  = errors.New("console passkey not found")
	ErrConsoleSessionNotFound  = errors.New("console session not found")
	ErrConsoleTokenNotFound    = errors.New("console token not found or expired")
)

const (
	maxConsoleOperatorName = 60
	maxConsoleLabel        = 60
	maxConsoleUserAgent    = 300
	// MaxConsoleAuditBody bounds the request kept with an audit event.
	MaxConsoleAuditBody   = 4096
	defaultConsoleAudit   = 100
	maxConsoleAuditListed = 500
)

func normalizeConsoleOperatorName(name string) (string, error) {
	name = strings.Join(strings.Fields(name), " ")
	if name == "" || len([]rune(name)) > maxConsoleOperatorName {
		return "", ErrConsoleOperatorName
	}
	return name, nil
}

func consoleAuditLimit(limit int) int {
	if limit <= 0 {
		return defaultConsoleAudit
	}
	return min(limit, maxConsoleAuditListed)
}

func normalizeConsoleAudit(event ConsoleAuditEvent, now time.Time) ConsoleAuditEvent {
	if event.At.IsZero() {
		event.At = now
	}
	event.Body = truncateRunes(event.Body, MaxConsoleAuditBody)
	event.Action = truncateRunes(event.Action, 120)
	event.Path = truncateRunes(event.Path, 500)
	return event
}

func consoleAuditMatches(event ConsoleAuditEvent, filter ConsoleAuditFilter) bool {
	if filter.OperatorID != "" && event.OperatorID != filter.OperatorID {
		return false
	}
	if filter.PathPrefix != "" && !strings.HasPrefix(event.Path, filter.PathPrefix) {
		return false
	}
	if q := strings.TrimSpace(filter.Query); q != "" {
		if !strings.Contains(event.Path, q) && !strings.Contains(event.Body, q) {
			return false
		}
	}
	return true
}

// --- file store ------------------------------------------------------------

type fileConsoleData struct {
	Operators map[string]ConsoleOperator `json:"operators,omitempty"`
	Passkeys  map[string]ConsolePasskey  `json:"passkeys,omitempty"`
	Sessions  map[string]ConsoleSession  `json:"sessions,omitempty"`
	Audit     []ConsoleAuditEvent        `json:"audit,omitempty"`
	// Tokens are short-lived; a file store is one process, so they stay in
	// memory and a restart costs at most a retried sign-in or invite.
	tokens map[string]ConsoleToken
}

func (s *FileStore) consoleLocked() *fileConsoleData {
	if s.data.Console == nil {
		s.data.Console = &fileConsoleData{}
	}
	c := s.data.Console
	if c.Operators == nil {
		c.Operators = map[string]ConsoleOperator{}
	}
	if c.Passkeys == nil {
		c.Passkeys = map[string]ConsolePasskey{}
	}
	if c.Sessions == nil {
		c.Sessions = map[string]ConsoleSession{}
	}
	if c.tokens == nil {
		c.tokens = map[string]ConsoleToken{}
	}
	return c
}

func (s *FileStore) CreateConsoleOperator(_ context.Context, name string, createdBy string) (ConsoleOperator, error) {
	name, err := normalizeConsoleOperatorName(name)
	if err != nil {
		return ConsoleOperator{}, err
	}
	id, err := NewInstallationID()
	if err != nil {
		return ConsoleOperator{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.consoleLocked()
	for _, existing := range c.Operators {
		if strings.EqualFold(existing.Name, name) {
			return ConsoleOperator{}, ErrConsoleOperatorExists
		}
	}
	operator := ConsoleOperator{ID: id, Name: name, CreatedAt: s.clock.Now(), CreatedBy: truncateRunes(createdBy, maxConsoleOperatorName)}
	c.Operators[id] = operator
	if err := s.saveLocked(); err != nil {
		delete(c.Operators, id)
		return ConsoleOperator{}, err
	}
	return operator, nil
}

func (s *FileStore) ConsoleOperators(_ context.Context) ([]ConsoleOperator, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	operators := make([]ConsoleOperator, 0, len(s.consoleLocked().Operators))
	for _, operator := range s.consoleLocked().Operators {
		operators = append(operators, operator)
	}
	sort.Slice(operators, func(i, j int) bool { return operators[i].CreatedAt.Before(operators[j].CreatedAt) })
	return operators, nil
}

func (s *FileStore) ConsoleOperator(_ context.Context, id string) (ConsoleOperator, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	operator, ok := s.consoleLocked().Operators[id]
	if !ok {
		return ConsoleOperator{}, ErrConsoleOperatorNotFound
	}
	return operator, nil
}

func (s *FileStore) ConsoleOperatorByName(_ context.Context, name string) (ConsoleOperator, error) {
	name, err := normalizeConsoleOperatorName(name)
	if err != nil {
		return ConsoleOperator{}, ErrConsoleOperatorNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, operator := range s.consoleLocked().Operators {
		if strings.EqualFold(operator.Name, name) {
			return operator, nil
		}
	}
	return ConsoleOperator{}, ErrConsoleOperatorNotFound
}

func (s *FileStore) SetConsoleOperatorDisabled(_ context.Context, id string, disabled bool) (ConsoleOperator, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.consoleLocked()
	operator, ok := c.Operators[id]
	if !ok {
		return ConsoleOperator{}, ErrConsoleOperatorNotFound
	}
	if disabled {
		now := s.clock.Now()
		operator.DisabledAt = &now
		for hash, session := range c.Sessions {
			if session.OperatorID == id {
				delete(c.Sessions, hash)
			}
		}
	} else {
		operator.DisabledAt = nil
	}
	c.Operators[id] = operator
	return operator, s.saveLocked()
}

func (s *FileStore) AddConsolePasskey(_ context.Context, passkey ConsolePasskey) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.consoleLocked()
	if _, ok := c.Operators[passkey.OperatorID]; !ok {
		return ErrConsoleOperatorNotFound
	}
	passkey.Label = truncateRunes(strings.TrimSpace(passkey.Label), maxConsoleLabel)
	if passkey.CreatedAt.IsZero() {
		passkey.CreatedAt = s.clock.Now()
	}
	c.Passkeys[passkey.ID] = passkey
	return s.saveLocked()
}

func (s *FileStore) ConsolePasskeys(_ context.Context, operatorID string) ([]ConsolePasskey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	passkeys := []ConsolePasskey{}
	for _, passkey := range s.consoleLocked().Passkeys {
		if operatorID == "" || passkey.OperatorID == operatorID {
			passkeys = append(passkeys, passkey)
		}
	}
	sort.Slice(passkeys, func(i, j int) bool { return passkeys[i].CreatedAt.Before(passkeys[j].CreatedAt) })
	return passkeys, nil
}

func (s *FileStore) ConsolePasskey(_ context.Context, id string) (ConsolePasskey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	passkey, ok := s.consoleLocked().Passkeys[id]
	if !ok {
		return ConsolePasskey{}, ErrConsolePasskeyNotFound
	}
	return passkey, nil
}

func (s *FileStore) TouchConsolePasskey(_ context.Context, id string, credential []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.consoleLocked()
	passkey, ok := c.Passkeys[id]
	if !ok {
		return ErrConsolePasskeyNotFound
	}
	now := s.clock.Now()
	passkey.Credential = slices.Clone(credential)
	passkey.LastUsedAt = &now
	c.Passkeys[id] = passkey
	return s.saveLocked()
}

func (s *FileStore) DeleteConsolePasskey(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.consoleLocked()
	if _, ok := c.Passkeys[id]; !ok {
		return ErrConsolePasskeyNotFound
	}
	delete(c.Passkeys, id)
	return s.saveLocked()
}

func (s *FileStore) CreateConsoleSession(_ context.Context, session ConsoleSession) error {
	session.UserAgent = truncateRunes(session.UserAgent, maxConsoleUserAgent)
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.consoleLocked()
	now := s.clock.Now()
	for hash, existing := range c.Sessions {
		if !existing.ExpiresAt.After(now) {
			delete(c.Sessions, hash)
		}
	}
	c.Sessions[session.IDHash] = session
	return s.saveLocked()
}

func (s *FileStore) ConsoleSession(_ context.Context, idHash string) (ConsoleSession, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	session, ok := s.consoleLocked().Sessions[idHash]
	if !ok || !session.ExpiresAt.After(s.clock.Now()) {
		return ConsoleSession{}, ErrConsoleSessionNotFound
	}
	return session, nil
}

func (s *FileStore) TouchConsoleSession(_ context.Context, idHash string, expiresAt time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.consoleLocked()
	session, ok := c.Sessions[idHash]
	if !ok {
		return ErrConsoleSessionNotFound
	}
	session.LastSeenAt = s.clock.Now()
	session.ExpiresAt = expiresAt
	c.Sessions[idHash] = session
	return s.saveLocked()
}

func (s *FileStore) ConsoleSessions(_ context.Context, operatorID string) ([]ConsoleSession, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.clock.Now()
	sessions := []ConsoleSession{}
	for _, session := range s.consoleLocked().Sessions {
		if session.ExpiresAt.After(now) && (operatorID == "" || session.OperatorID == operatorID) {
			sessions = append(sessions, session)
		}
	}
	sort.Slice(sessions, func(i, j int) bool { return sessions[i].LastSeenAt.After(sessions[j].LastSeenAt) })
	return sessions, nil
}

func (s *FileStore) DeleteConsoleSession(_ context.Context, idHash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.consoleLocked().Sessions, idHash)
	return s.saveLocked()
}

func (s *FileStore) DeleteConsoleSessionsOf(_ context.Context, operatorID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.consoleLocked()
	for hash, session := range c.Sessions {
		if session.OperatorID == operatorID {
			delete(c.Sessions, hash)
		}
	}
	return s.saveLocked()
}

func (s *FileStore) PutConsoleToken(_ context.Context, token ConsoleToken) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.consoleLocked()
	now := s.clock.Now()
	for hash, existing := range c.tokens {
		if !existing.ExpiresAt.After(now) {
			delete(c.tokens, hash)
		}
	}
	c.tokens[token.Kind+":"+token.Hash] = token
	return nil
}

func (s *FileStore) TakeConsoleToken(_ context.Context, kind string, hash string) (ConsoleToken, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.consoleLocked()
	key := kind + ":" + hash
	token, ok := c.tokens[key]
	delete(c.tokens, key)
	if !ok || !token.ExpiresAt.After(s.clock.Now()) {
		return ConsoleToken{}, ErrConsoleTokenNotFound
	}
	return token, nil
}

// maxFileConsoleAudit keeps a dev file store from growing without bound.
const maxFileConsoleAudit = 5000

func (s *FileStore) AppendConsoleAudit(_ context.Context, event ConsoleAuditEvent) (ConsoleAuditEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.consoleLocked()
	event = normalizeConsoleAudit(event, s.clock.Now())
	next := 1
	if len(c.Audit) > 0 {
		last, _ := strconv.Atoi(c.Audit[len(c.Audit)-1].ID)
		next = last + 1
	}
	event.ID = strconv.Itoa(next)
	c.Audit = append(c.Audit, event)
	if len(c.Audit) > maxFileConsoleAudit {
		c.Audit = slices.Clone(c.Audit[len(c.Audit)-maxFileConsoleAudit:])
	}
	return event, s.saveLocked()
}

func (s *FileStore) ConsoleAudit(_ context.Context, filter ConsoleAuditFilter) ([]ConsoleAuditEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	limit := consoleAuditLimit(filter.Limit)
	before, _ := strconv.Atoi(filter.BeforeID)
	events := []ConsoleAuditEvent{}
	audit := s.consoleLocked().Audit
	for i := len(audit) - 1; i >= 0 && len(events) < limit; i-- {
		event := audit[i]
		if id, _ := strconv.Atoi(event.ID); before > 0 && id >= before {
			continue
		}
		if consoleAuditMatches(event, filter) {
			events = append(events, event)
		}
	}
	return events, nil
}

// --- postgres store --------------------------------------------------------

const consoleOperatorColumns = `id, name, created_at, created_by, disabled_at`

func scanConsoleOperator(row pgx.Row) (ConsoleOperator, error) {
	var operator ConsoleOperator
	err := row.Scan(&operator.ID, &operator.Name, &operator.CreatedAt, &operator.CreatedBy, &operator.DisabledAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return ConsoleOperator{}, ErrConsoleOperatorNotFound
	}
	return operator, err
}

func (s *PostgresStore) CreateConsoleOperator(ctx context.Context, name string, createdBy string) (ConsoleOperator, error) {
	name, err := normalizeConsoleOperatorName(name)
	if err != nil {
		return ConsoleOperator{}, err
	}
	id, err := NewInstallationID()
	if err != nil {
		return ConsoleOperator{}, err
	}
	operator, err := scanConsoleOperator(s.pool.QueryRow(ctx,
		`INSERT INTO relay_console_operators (id, name, created_at, created_by)
		VALUES ($1, $2, $3::timestamptz, $4)
		RETURNING `+consoleOperatorColumns,
		id, name, s.clock.Now(), truncateRunes(createdBy, maxConsoleOperatorName),
	))
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return ConsoleOperator{}, ErrConsoleOperatorExists
	}
	return operator, err
}

func (s *PostgresStore) ConsoleOperators(ctx context.Context) ([]ConsoleOperator, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+consoleOperatorColumns+` FROM relay_console_operators ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	operators := []ConsoleOperator{}
	for rows.Next() {
		operator, err := scanConsoleOperator(rows)
		if err != nil {
			return nil, err
		}
		operators = append(operators, operator)
	}
	return operators, rows.Err()
}

func (s *PostgresStore) ConsoleOperator(ctx context.Context, id string) (ConsoleOperator, error) {
	return scanConsoleOperator(s.pool.QueryRow(ctx,
		`SELECT `+consoleOperatorColumns+` FROM relay_console_operators WHERE id = $1`, id))
}

func (s *PostgresStore) ConsoleOperatorByName(ctx context.Context, name string) (ConsoleOperator, error) {
	name, err := normalizeConsoleOperatorName(name)
	if err != nil {
		return ConsoleOperator{}, ErrConsoleOperatorNotFound
	}
	return scanConsoleOperator(s.pool.QueryRow(ctx,
		`SELECT `+consoleOperatorColumns+` FROM relay_console_operators WHERE lower(name) = lower($1)`, name))
}

func (s *PostgresStore) SetConsoleOperatorDisabled(ctx context.Context, id string, disabled bool) (ConsoleOperator, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return ConsoleOperator{}, err
	}
	defer tx.Rollback(ctx)
	var disabledAt *time.Time
	if disabled {
		now := s.clock.Now()
		disabledAt = &now
		if _, err := tx.Exec(ctx, `DELETE FROM relay_console_sessions WHERE operator_id = $1`, id); err != nil {
			return ConsoleOperator{}, err
		}
	}
	operator, err := scanConsoleOperator(tx.QueryRow(ctx,
		`UPDATE relay_console_operators SET disabled_at = $2::timestamptz WHERE id = $1
		RETURNING `+consoleOperatorColumns, id, disabledAt))
	if err != nil {
		return ConsoleOperator{}, err
	}
	return operator, tx.Commit(ctx)
}

const consolePasskeyColumns = `id, operator_id, label, credential, created_at, last_used_at`

func scanConsolePasskey(row pgx.Row) (ConsolePasskey, error) {
	var passkey ConsolePasskey
	err := row.Scan(&passkey.ID, &passkey.OperatorID, &passkey.Label, &passkey.Credential, &passkey.CreatedAt, &passkey.LastUsedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return ConsolePasskey{}, ErrConsolePasskeyNotFound
	}
	return passkey, err
}

func (s *PostgresStore) AddConsolePasskey(ctx context.Context, passkey ConsolePasskey) error {
	if passkey.CreatedAt.IsZero() {
		passkey.CreatedAt = s.clock.Now()
	}
	_, err := s.pool.Exec(ctx,
		`INSERT INTO relay_console_passkeys (id, operator_id, label, credential, created_at)
		VALUES ($1, $2, $3, $4, $5::timestamptz)`,
		passkey.ID, passkey.OperatorID, truncateRunes(strings.TrimSpace(passkey.Label), maxConsoleLabel),
		passkey.Credential, passkey.CreatedAt,
	)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23503" {
		return ErrConsoleOperatorNotFound
	}
	return err
}

func (s *PostgresStore) ConsolePasskeys(ctx context.Context, operatorID string) ([]ConsolePasskey, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT `+consolePasskeyColumns+` FROM relay_console_passkeys
		WHERE ($1 = '' OR operator_id = $1) ORDER BY created_at`, operatorID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	passkeys := []ConsolePasskey{}
	for rows.Next() {
		passkey, err := scanConsolePasskey(rows)
		if err != nil {
			return nil, err
		}
		passkeys = append(passkeys, passkey)
	}
	return passkeys, rows.Err()
}

func (s *PostgresStore) ConsolePasskey(ctx context.Context, id string) (ConsolePasskey, error) {
	return scanConsolePasskey(s.pool.QueryRow(ctx,
		`SELECT `+consolePasskeyColumns+` FROM relay_console_passkeys WHERE id = $1`, id))
}

func (s *PostgresStore) TouchConsolePasskey(ctx context.Context, id string, credential []byte) error {
	tag, err := s.pool.Exec(ctx,
		`UPDATE relay_console_passkeys SET credential = $2, last_used_at = $3::timestamptz WHERE id = $1`,
		id, credential, s.clock.Now())
	if err == nil && tag.RowsAffected() == 0 {
		return ErrConsolePasskeyNotFound
	}
	return err
}

func (s *PostgresStore) DeleteConsolePasskey(ctx context.Context, id string) error {
	tag, err := s.pool.Exec(ctx, `DELETE FROM relay_console_passkeys WHERE id = $1`, id)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrConsolePasskeyNotFound
	}
	return err
}

const consoleSessionColumns = `id_hash, operator_id, created_at, last_seen_at, expires_at, ip, user_agent`

func scanConsoleSession(row pgx.Row) (ConsoleSession, error) {
	var session ConsoleSession
	err := row.Scan(&session.IDHash, &session.OperatorID, &session.CreatedAt, &session.LastSeenAt,
		&session.ExpiresAt, &session.IP, &session.UserAgent)
	if errors.Is(err, pgx.ErrNoRows) {
		return ConsoleSession{}, ErrConsoleSessionNotFound
	}
	return session, err
}

func (s *PostgresStore) CreateConsoleSession(ctx context.Context, session ConsoleSession) error {
	if _, err := s.pool.Exec(ctx, `DELETE FROM relay_console_sessions WHERE expires_at <= $1::timestamptz`, s.clock.Now()); err != nil {
		return err
	}
	_, err := s.pool.Exec(ctx,
		`INSERT INTO relay_console_sessions (`+consoleSessionColumns+`)
		VALUES ($1, $2, $3::timestamptz, $4::timestamptz, $5::timestamptz, $6, $7)`,
		session.IDHash, session.OperatorID, session.CreatedAt, session.LastSeenAt, session.ExpiresAt,
		session.IP, truncateRunes(session.UserAgent, maxConsoleUserAgent))
	return err
}

func (s *PostgresStore) ConsoleSession(ctx context.Context, idHash string) (ConsoleSession, error) {
	return scanConsoleSession(s.pool.QueryRow(ctx,
		`SELECT `+consoleSessionColumns+` FROM relay_console_sessions
		WHERE id_hash = $1 AND expires_at > $2::timestamptz`, idHash, s.clock.Now()))
}

func (s *PostgresStore) TouchConsoleSession(ctx context.Context, idHash string, expiresAt time.Time) error {
	tag, err := s.pool.Exec(ctx,
		`UPDATE relay_console_sessions SET last_seen_at = $2::timestamptz, expires_at = $3::timestamptz WHERE id_hash = $1`,
		idHash, s.clock.Now(), expiresAt)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrConsoleSessionNotFound
	}
	return err
}

func (s *PostgresStore) ConsoleSessions(ctx context.Context, operatorID string) ([]ConsoleSession, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT `+consoleSessionColumns+` FROM relay_console_sessions
		WHERE expires_at > $2::timestamptz AND ($1 = '' OR operator_id = $1)
		ORDER BY last_seen_at DESC`, operatorID, s.clock.Now())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	sessions := []ConsoleSession{}
	for rows.Next() {
		session, err := scanConsoleSession(rows)
		if err != nil {
			return nil, err
		}
		sessions = append(sessions, session)
	}
	return sessions, rows.Err()
}

func (s *PostgresStore) DeleteConsoleSession(ctx context.Context, idHash string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM relay_console_sessions WHERE id_hash = $1`, idHash)
	return err
}

func (s *PostgresStore) DeleteConsoleSessionsOf(ctx context.Context, operatorID string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM relay_console_sessions WHERE operator_id = $1`, operatorID)
	return err
}

func (s *PostgresStore) PutConsoleToken(ctx context.Context, token ConsoleToken) error {
	if _, err := s.pool.Exec(ctx, `DELETE FROM relay_console_tokens WHERE expires_at <= $1::timestamptz`, s.clock.Now()); err != nil {
		return err
	}
	_, err := s.pool.Exec(ctx,
		`INSERT INTO relay_console_tokens (kind, hash, operator_id, subject, payload, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6::timestamptz)`,
		token.Kind, token.Hash, token.OperatorID, token.Subject, token.Payload, token.ExpiresAt)
	return err
}

func (s *PostgresStore) TakeConsoleToken(ctx context.Context, kind string, hash string) (ConsoleToken, error) {
	var token ConsoleToken
	err := s.pool.QueryRow(ctx,
		`DELETE FROM relay_console_tokens WHERE kind = $1 AND hash = $2
		RETURNING kind, hash, operator_id, subject, payload, expires_at`, kind, hash,
	).Scan(&token.Kind, &token.Hash, &token.OperatorID, &token.Subject, &token.Payload, &token.ExpiresAt)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !token.ExpiresAt.After(s.clock.Now())) {
		return ConsoleToken{}, ErrConsoleTokenNotFound
	}
	return token, err
}

func (s *PostgresStore) AppendConsoleAudit(ctx context.Context, event ConsoleAuditEvent) (ConsoleAuditEvent, error) {
	event = normalizeConsoleAudit(event, s.clock.Now())
	var id int64
	err := s.pool.QueryRow(ctx,
		`INSERT INTO relay_console_audit
			(at, operator_id, operator_name, action, method, path, status, body, ip, stepped_up)
		VALUES ($1::timestamptz, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		RETURNING id`,
		event.At, event.OperatorID, event.OperatorName, event.Action, event.Method, event.Path,
		event.Status, event.Body, event.IP, event.SteppedUp,
	).Scan(&id)
	event.ID = strconv.FormatInt(id, 10)
	return event, err
}

func (s *PostgresStore) ConsoleAudit(ctx context.Context, filter ConsoleAuditFilter) ([]ConsoleAuditEvent, error) {
	before, _ := strconv.ParseInt(filter.BeforeID, 10, 64)
	query := strings.TrimSpace(filter.Query)
	rows, err := s.pool.Query(ctx,
		`SELECT id, at, operator_id, operator_name, action, method, path, status, body, ip, stepped_up
		FROM relay_console_audit
		WHERE ($1 = '' OR operator_id = $1)
			AND ($2 = '' OR starts_with(path, $2))
			AND ($3 = '' OR strpos(path, $3) > 0 OR strpos(body, $3) > 0)
			AND ($4 = 0 OR id < $4)
		ORDER BY id DESC
		LIMIT $5`,
		filter.OperatorID, filter.PathPrefix, query, before, consoleAuditLimit(filter.Limit))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	events := []ConsoleAuditEvent{}
	for rows.Next() {
		var event ConsoleAuditEvent
		var id int64
		if err := rows.Scan(&id, &event.At, &event.OperatorID, &event.OperatorName, &event.Action, &event.Method,
			&event.Path, &event.Status, &event.Body, &event.IP, &event.SteppedUp); err != nil {
			return nil, err
		}
		event.ID = strconv.FormatInt(id, 10)
		events = append(events, event)
	}
	return events, rows.Err()
}

// --- cached store ----------------------------------------------------------

// The console's records are never cached: sessions and grants must be read
// fresh on every request. These forward to the wrapped store.

func (s *CachedInstallationStore) consoleStore() (ConsoleStore, error) {
	store, ok := s.store.(ConsoleStore)
	if !ok {
		return nil, errors.New("store does not support the operator console")
	}
	return store, nil
}

func (s *CachedInstallationStore) CreateConsoleOperator(ctx context.Context, name string, createdBy string) (ConsoleOperator, error) {
	store, err := s.consoleStore()
	if err != nil {
		return ConsoleOperator{}, err
	}
	return store.CreateConsoleOperator(ctx, name, createdBy)
}

func (s *CachedInstallationStore) ConsoleOperators(ctx context.Context) ([]ConsoleOperator, error) {
	store, err := s.consoleStore()
	if err != nil {
		return nil, err
	}
	return store.ConsoleOperators(ctx)
}

func (s *CachedInstallationStore) ConsoleOperator(ctx context.Context, id string) (ConsoleOperator, error) {
	store, err := s.consoleStore()
	if err != nil {
		return ConsoleOperator{}, err
	}
	return store.ConsoleOperator(ctx, id)
}

func (s *CachedInstallationStore) ConsoleOperatorByName(ctx context.Context, name string) (ConsoleOperator, error) {
	store, err := s.consoleStore()
	if err != nil {
		return ConsoleOperator{}, err
	}
	return store.ConsoleOperatorByName(ctx, name)
}

func (s *CachedInstallationStore) SetConsoleOperatorDisabled(ctx context.Context, id string, disabled bool) (ConsoleOperator, error) {
	store, err := s.consoleStore()
	if err != nil {
		return ConsoleOperator{}, err
	}
	return store.SetConsoleOperatorDisabled(ctx, id, disabled)
}

func (s *CachedInstallationStore) AddConsolePasskey(ctx context.Context, passkey ConsolePasskey) error {
	store, err := s.consoleStore()
	if err != nil {
		return err
	}
	return store.AddConsolePasskey(ctx, passkey)
}

func (s *CachedInstallationStore) ConsolePasskeys(ctx context.Context, operatorID string) ([]ConsolePasskey, error) {
	store, err := s.consoleStore()
	if err != nil {
		return nil, err
	}
	return store.ConsolePasskeys(ctx, operatorID)
}

func (s *CachedInstallationStore) ConsolePasskey(ctx context.Context, id string) (ConsolePasskey, error) {
	store, err := s.consoleStore()
	if err != nil {
		return ConsolePasskey{}, err
	}
	return store.ConsolePasskey(ctx, id)
}

func (s *CachedInstallationStore) TouchConsolePasskey(ctx context.Context, id string, credential []byte) error {
	store, err := s.consoleStore()
	if err != nil {
		return err
	}
	return store.TouchConsolePasskey(ctx, id, credential)
}

func (s *CachedInstallationStore) DeleteConsolePasskey(ctx context.Context, id string) error {
	store, err := s.consoleStore()
	if err != nil {
		return err
	}
	return store.DeleteConsolePasskey(ctx, id)
}

func (s *CachedInstallationStore) CreateConsoleSession(ctx context.Context, session ConsoleSession) error {
	store, err := s.consoleStore()
	if err != nil {
		return err
	}
	return store.CreateConsoleSession(ctx, session)
}

func (s *CachedInstallationStore) ConsoleSession(ctx context.Context, idHash string) (ConsoleSession, error) {
	store, err := s.consoleStore()
	if err != nil {
		return ConsoleSession{}, err
	}
	return store.ConsoleSession(ctx, idHash)
}

func (s *CachedInstallationStore) TouchConsoleSession(ctx context.Context, idHash string, expiresAt time.Time) error {
	store, err := s.consoleStore()
	if err != nil {
		return err
	}
	return store.TouchConsoleSession(ctx, idHash, expiresAt)
}

func (s *CachedInstallationStore) ConsoleSessions(ctx context.Context, operatorID string) ([]ConsoleSession, error) {
	store, err := s.consoleStore()
	if err != nil {
		return nil, err
	}
	return store.ConsoleSessions(ctx, operatorID)
}

func (s *CachedInstallationStore) DeleteConsoleSession(ctx context.Context, idHash string) error {
	store, err := s.consoleStore()
	if err != nil {
		return err
	}
	return store.DeleteConsoleSession(ctx, idHash)
}

func (s *CachedInstallationStore) DeleteConsoleSessionsOf(ctx context.Context, operatorID string) error {
	store, err := s.consoleStore()
	if err != nil {
		return err
	}
	return store.DeleteConsoleSessionsOf(ctx, operatorID)
}

func (s *CachedInstallationStore) PutConsoleToken(ctx context.Context, token ConsoleToken) error {
	store, err := s.consoleStore()
	if err != nil {
		return err
	}
	return store.PutConsoleToken(ctx, token)
}

func (s *CachedInstallationStore) TakeConsoleToken(ctx context.Context, kind string, hash string) (ConsoleToken, error) {
	store, err := s.consoleStore()
	if err != nil {
		return ConsoleToken{}, err
	}
	return store.TakeConsoleToken(ctx, kind, hash)
}

func (s *CachedInstallationStore) AppendConsoleAudit(ctx context.Context, event ConsoleAuditEvent) (ConsoleAuditEvent, error) {
	store, err := s.consoleStore()
	if err != nil {
		return ConsoleAuditEvent{}, err
	}
	return store.AppendConsoleAudit(ctx, event)
}

func (s *CachedInstallationStore) ConsoleAudit(ctx context.Context, filter ConsoleAuditFilter) ([]ConsoleAuditEvent, error) {
	store, err := s.consoleStore()
	if err != nil {
		return nil, err
	}
	return store.ConsoleAudit(ctx, filter)
}

var (
	_ ConsoleStore = (*FileStore)(nil)
	_ ConsoleStore = (*PostgresStore)(nil)
	_ ConsoleStore = (*CachedInstallationStore)(nil)
)
