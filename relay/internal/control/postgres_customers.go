package control

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

var _ CustomerStore = (*PostgresStore)(nil)

const selectCustomerColumns = `id, coalesce(phone, ''), created_at, last_sign_in_at, deleted_at`

func scanCustomer(row pgx.Row) (Customer, error) {
	var customer Customer
	if err := row.Scan(&customer.ID, &customer.Phone, &customer.CreatedAt, &customer.LastSignInAt, &customer.DeletedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Customer{}, ErrCustomerNotFound
		}
		return Customer{}, err
	}
	customer.CreatedAt = customer.CreatedAt.UTC()
	customer.LastSignInAt = customer.LastSignInAt.UTC()
	if customer.DeletedAt != nil {
		deleted := customer.DeletedAt.UTC()
		customer.DeletedAt = &deleted
	}
	return customer, nil
}

const selectCustomerSessionColumns = `id, customer_id, access_hash, refresh_hash, previous_refresh_hash,
	rotated_at, device_id, device_name, platform, created_at, last_seen_at, access_expires_at, expires_at`

func scanCustomerSession(row pgx.Row) (CustomerSession, error) {
	var session CustomerSession
	var rotatedAt *time.Time
	if err := row.Scan(
		&session.ID, &session.CustomerID, &session.AccessHash, &session.RefreshHash, &session.PreviousRefreshHash,
		&rotatedAt, &session.DeviceID, &session.DeviceName, &session.Platform, &session.CreatedAt,
		&session.LastSeenAt, &session.AccessExpiresAt, &session.ExpiresAt,
	); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return CustomerSession{}, ErrCustomerSessionNotFound
		}
		return CustomerSession{}, err
	}
	if rotatedAt != nil {
		session.RotatedAt = rotatedAt.UTC()
	}
	session.CreatedAt = session.CreatedAt.UTC()
	session.LastSeenAt = session.LastSeenAt.UTC()
	session.AccessExpiresAt = session.AccessExpiresAt.UTC()
	session.ExpiresAt = session.ExpiresAt.UTC()
	return session, nil
}

// lockCustomerOTPTx reads (and row-locks) a phone's code state; a phone that
// never asked reads as the zero state.
func lockCustomerOTPTx(ctx context.Context, tx pgx.Tx, phone string) (customerOTP, bool, error) {
	otp := customerOTP{Phone: phone}
	var sentAt, expiresAt *time.Time
	err := tx.QueryRow(ctx,
		`SELECT code_hash, attempts, sent_at, expires_at, day, sends
		FROM relay_customer_otps WHERE phone = $1 FOR UPDATE`, phone,
	).Scan(&otp.CodeHash, &otp.Attempts, &sentAt, &expiresAt, &otp.Day, &otp.Sends)
	if errors.Is(err, pgx.ErrNoRows) {
		return otp, false, nil
	}
	if err != nil {
		return otp, false, err
	}
	if sentAt != nil {
		otp.SentAt = sentAt.UTC()
	}
	if expiresAt != nil {
		otp.ExpiresAt = expiresAt.UTC()
	}
	return otp, true, nil
}

func writeCustomerOTPTx(ctx context.Context, tx pgx.Tx, otp customerOTP) error {
	var sentAt, expiresAt *time.Time
	if !otp.SentAt.IsZero() {
		sentAt = &otp.SentAt
	}
	if !otp.ExpiresAt.IsZero() {
		expiresAt = &otp.ExpiresAt
	}
	_, err := tx.Exec(ctx,
		`INSERT INTO relay_customer_otps (phone, code_hash, attempts, sent_at, expires_at, day, sends)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (phone) DO UPDATE SET
			code_hash = EXCLUDED.code_hash,
			attempts = EXCLUDED.attempts,
			sent_at = EXCLUDED.sent_at,
			expires_at = EXCLUDED.expires_at,
			day = EXCLUDED.day,
			sends = EXCLUDED.sends`,
		otp.Phone, otp.CodeHash, otp.Attempts, sentAt, expiresAt, otp.Day, otp.Sends,
	)
	return err
}

func (s *PostgresStore) IssueCustomerOTP(ctx context.Context, request CustomerOTPRequest) (CustomerOTPChallenge, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerOTPChallenge{}, err
	}
	defer tx.Rollback(ctx)
	// A phone's first code has no row to lock, so one is made first: racing
	// first requests then queue on it like any later ones, and only one of
	// them passes the resend gap. Without this, N parallel first requests
	// would each text a paid SMS.
	if _, err := tx.Exec(ctx,
		`INSERT INTO relay_customer_otps (phone, day) VALUES ($1, $2) ON CONFLICT (phone) DO NOTHING`,
		request.Phone, customerDay(s.clock.Now().UTC()),
	); err != nil {
		return CustomerOTPChallenge{}, err
	}
	previous, _, err := lockCustomerOTPTx(ctx, tx, request.Phone)
	if err != nil {
		return CustomerOTPChallenge{}, err
	}
	next, err := previous.issue(request, s.clock.Now().UTC())
	if err != nil {
		return CustomerOTPChallenge{}, err
	}
	if err := writeCustomerOTPTx(ctx, tx, next); err != nil {
		return CustomerOTPChallenge{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return CustomerOTPChallenge{}, err
	}
	return next.challenge(request), nil
}

func (s *PostgresStore) CancelCustomerOTP(ctx context.Context, phone, codeHash string) error {
	_, err := s.pool.Exec(ctx,
		`UPDATE relay_customer_otps
		SET code_hash = '', sent_at = NULL, sends = greatest(sends - 1, 0)
		WHERE phone = $1 AND code_hash = $2 AND code_hash <> ''`,
		phone, codeHash,
	)
	return err
}

func (s *PostgresStore) VerifyCustomerOTP(ctx context.Context, phone, codeHash string, maxAttempts int) (Customer, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Customer{}, false, err
	}
	defer tx.Rollback(ctx)
	otp, found, err := lockCustomerOTPTx(ctx, tx, phone)
	if err != nil {
		return Customer{}, false, err
	}
	if !found {
		return Customer{}, false, ErrCustomerOTPExpired
	}
	now := s.clock.Now().UTC()
	next, verdict := otp.verify(codeHash, maxAttempts, now)
	if err := writeCustomerOTPTx(ctx, tx, next); err != nil {
		return Customer{}, false, err
	}
	if verdict != nil {
		// The wrong guess is counted even though the answer is a refusal.
		if err := tx.Commit(ctx); err != nil {
			return Customer{}, false, err
		}
		return Customer{}, false, verdict
	}
	customer, err := scanCustomer(tx.QueryRow(ctx,
		`UPDATE relay_customers SET last_sign_in_at = $2 WHERE phone = $1
		RETURNING `+selectCustomerColumns, phone, now))
	created := false
	if errors.Is(err, ErrCustomerNotFound) {
		id, idErr := NewInstallationID()
		if idErr != nil {
			return Customer{}, false, idErr
		}
		customer, err = scanCustomer(tx.QueryRow(ctx,
			`INSERT INTO relay_customers (id, phone, created_at, last_sign_in_at)
			VALUES ($1, $2, $3, $3) RETURNING `+selectCustomerColumns, id, phone, now))
		created = true
	}
	if err != nil {
		return Customer{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Customer{}, false, err
	}
	return customer, created, nil
}

func (s *PostgresStore) GetCustomer(ctx context.Context, id string) (Customer, error) {
	return scanCustomer(s.pool.QueryRow(ctx,
		`SELECT `+selectCustomerColumns+` FROM relay_customers WHERE id = $1`, id))
}

func (s *PostgresStore) CreateCustomerSession(ctx context.Context, session CustomerSession) (CustomerSession, error) {
	session, err := normalizeCustomerSession(session)
	if err != nil {
		return CustomerSession{}, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerSession{}, err
	}
	defer tx.Rollback(ctx)
	now := s.clock.Now().UTC()
	// Locking the customer serializes one customer's sign-ins, so the cap
	// below counts every session.
	var deleted *time.Time
	err = tx.QueryRow(ctx,
		`SELECT deleted_at FROM relay_customers WHERE id = $1 FOR UPDATE`, session.CustomerID,
	).Scan(&deleted)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && deleted != nil) {
		return CustomerSession{}, ErrCustomerNotFound
	}
	if err != nil {
		return CustomerSession{}, err
	}
	if _, err := tx.Exec(ctx,
		`DELETE FROM relay_customer_sessions WHERE customer_id = $1 AND expires_at <= $2`,
		session.CustomerID, now,
	); err != nil {
		return CustomerSession{}, err
	}
	if _, err := tx.Exec(ctx,
		`DELETE FROM relay_customer_sessions WHERE id IN (
			SELECT id FROM relay_customer_sessions WHERE customer_id = $1
			ORDER BY last_seen_at DESC, id OFFSET $2)`,
		session.CustomerID, MaxCustomerSessions-1,
	); err != nil {
		return CustomerSession{}, err
	}
	session.CreatedAt = now
	session.LastSeenAt = now
	stored, err := scanCustomerSession(tx.QueryRow(ctx,
		`INSERT INTO relay_customer_sessions (id, customer_id, access_hash, refresh_hash,
			device_id, device_name, platform, created_at, last_seen_at, access_expires_at, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8, $9, $10)
		RETURNING `+selectCustomerSessionColumns,
		session.ID, session.CustomerID, session.AccessHash, session.RefreshHash,
		session.DeviceID, session.DeviceName, session.Platform, now, session.AccessExpiresAt, session.ExpiresAt,
	))
	if err != nil {
		return CustomerSession{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return CustomerSession{}, err
	}
	return stored, nil
}

func (s *PostgresStore) CustomerByAccessToken(ctx context.Context, accessHash string) (Customer, CustomerSession, error) {
	if accessHash == "" {
		return Customer{}, CustomerSession{}, ErrCustomerSessionNotFound
	}
	session, err := scanCustomerSession(s.pool.QueryRow(ctx,
		`SELECT `+selectCustomerSessionColumns+` FROM relay_customer_sessions
		WHERE access_hash = $1 AND access_expires_at > $2`, accessHash, s.clock.Now().UTC()))
	if err != nil {
		return Customer{}, CustomerSession{}, err
	}
	customer, err := s.GetCustomer(ctx, session.CustomerID)
	if errors.Is(err, ErrCustomerNotFound) || (err == nil && customer.DeletedAt != nil) {
		return Customer{}, CustomerSession{}, ErrCustomerSessionNotFound
	}
	if err != nil {
		return Customer{}, CustomerSession{}, err
	}
	return customer, session, nil
}

func (s *PostgresStore) RefreshCustomerSession(ctx context.Context, refreshHash string, next CustomerTokens) (CustomerSession, error) {
	if refreshHash == "" {
		return CustomerSession{}, ErrCustomerSessionNotFound
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return CustomerSession{}, err
	}
	defer tx.Rollback(ctx)
	session, err := scanCustomerSession(tx.QueryRow(ctx,
		`SELECT `+selectCustomerSessionColumns+` FROM relay_customer_sessions
		WHERE refresh_hash = $1 OR previous_refresh_hash = $1
		LIMIT 1 FOR UPDATE`, refreshHash))
	if err != nil {
		return CustomerSession{}, err
	}
	now := s.clock.Now().UTC()
	if verdict := refreshVerdict(session, refreshHash, now); verdict != nil {
		if errors.Is(verdict, ErrCustomerRefreshReused) {
			if _, err := tx.Exec(ctx, `DELETE FROM relay_customer_sessions WHERE id = $1`, session.ID); err != nil {
				return CustomerSession{}, err
			}
			if err := tx.Commit(ctx); err != nil {
				return CustomerSession{}, err
			}
		}
		return CustomerSession{}, verdict
	}
	session = rotateCustomerSession(session, next, now)
	var rotatedAt *time.Time
	if !session.RotatedAt.IsZero() {
		rotatedAt = &session.RotatedAt
	}
	stored, err := scanCustomerSession(tx.QueryRow(ctx,
		`UPDATE relay_customer_sessions SET
			access_hash = $2, refresh_hash = $3, previous_refresh_hash = $4, rotated_at = $5,
			last_seen_at = $6, access_expires_at = $7, expires_at = $8
		WHERE id = $1 AND EXISTS (
			SELECT 1 FROM relay_customers c WHERE c.id = customer_id AND c.deleted_at IS NULL)
		RETURNING `+selectCustomerSessionColumns,
		session.ID, session.AccessHash, session.RefreshHash, session.PreviousRefreshHash, rotatedAt,
		session.LastSeenAt, session.AccessExpiresAt, session.ExpiresAt,
	))
	if err != nil {
		return CustomerSession{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return CustomerSession{}, err
	}
	return stored, nil
}

func (s *PostgresStore) CustomerSessions(ctx context.Context, customerID string) ([]CustomerSession, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT `+selectCustomerSessionColumns+` FROM relay_customer_sessions
		WHERE customer_id = $1 AND expires_at > $2
		ORDER BY last_seen_at DESC, id`, customerID, s.clock.Now().UTC())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	sessions := []CustomerSession{}
	for rows.Next() {
		session, err := scanCustomerSession(rows)
		if err != nil {
			return nil, err
		}
		sessions = append(sessions, session)
	}
	return sessions, rows.Err()
}

func (s *PostgresStore) DeleteCustomerSession(ctx context.Context, customerID, sessionID string) (bool, error) {
	tag, err := s.pool.Exec(ctx,
		`DELETE FROM relay_customer_sessions WHERE id = $1 AND customer_id = $2`, sessionID, customerID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

func (s *PostgresStore) DeleteCustomerSessions(ctx context.Context, customerID string) (int, error) {
	tag, err := s.pool.Exec(ctx, `DELETE FROM relay_customer_sessions WHERE customer_id = $1`, customerID)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

func (s *PostgresStore) DeleteCustomer(ctx context.Context, customerID string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var phone string
	err = tx.QueryRow(ctx,
		`SELECT phone FROM relay_customers WHERE id = $1 AND deleted_at IS NULL FOR UPDATE`, customerID,
	).Scan(&phone)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrCustomerNotFound
	}
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx,
		`UPDATE relay_customers SET deleted_at = $2, phone = NULL WHERE id = $1`,
		customerID, s.clock.Now().UTC(),
	); err != nil {
		return err
	}
	// Keep the code row: its daily count still guards the number.
	if _, err := tx.Exec(ctx, `UPDATE relay_customer_otps SET code_hash = '' WHERE phone = $1`, phone); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM relay_customer_sessions WHERE customer_id = $1`, customerID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
