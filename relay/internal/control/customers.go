package control

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// Customers of «دفتر كروت», the company's own card app (DAFTAR_CARDS_APP_PLAN.md).
// A customer is a person, not a shop: they sign in with their Libyan mobile
// number and a code the relay texts them, and hold sessions on their devices.
//
// Nothing here stores a raw secret. A sign-in code is kept as the hash of
// phone + code, and a session as the hashes of its access and refresh tokens.

// Customer is one phone number that has signed in at least once.
type Customer struct {
	ID string `json:"id"`
	// Phone is "218" + the 9-digit national number; empty once deleted.
	Phone        string     `json:"phone"`
	CreatedAt    time.Time  `json:"created_at"`
	LastSignInAt time.Time  `json:"last_sign_in_at"`
	DeletedAt    *time.Time `json:"deleted_at,omitempty"`
	// BlockedAt is when an operator stopped the account: it cannot sign in
	// again until unblocked. BlockedReason is the operator's note.
	BlockedAt     *time.Time `json:"blocked_at,omitempty"`
	BlockedReason string     `json:"blocked_reason,omitempty"`
}

// CustomerOTPRequest asks the store for a new sign-in code for a phone.
type CustomerOTPRequest struct {
	Phone    string
	CodeHash string
	// TTL is how long the code is good for.
	TTL time.Duration
	// ResendAfter is the shortest gap between two codes to one phone.
	ResendAfter time.Duration
	// DailyLimit caps the codes one phone gets per Libyan calendar day: every
	// one is an SMS the company pays for. 0 means no cap.
	DailyLimit int
}

// CustomerOTPChallenge is the code the store accepted.
type CustomerOTPChallenge struct {
	Phone     string    `json:"phone"`
	ExpiresAt time.Time `json:"expires_at"`
	ResendAt  time.Time `json:"resend_at"`
	// SendsToday counts this code.
	SendsToday int `json:"sends_today"`
}

// CustomerOTPRefusal is a code the store would not issue.
type CustomerOTPRefusal struct {
	// Reason is CustomerOTPTooSoon or CustomerOTPDailyLimit.
	Reason  string
	RetryAt time.Time
}

const (
	CustomerOTPTooSoon    = "too_soon"
	CustomerOTPDailyLimit = "daily_limit"
)

func (e *CustomerOTPRefusal) Error() string {
	return fmt.Sprintf("customer otp refused: %s until %s", e.Reason, e.RetryAt.Format(time.RFC3339))
}

// CustomerOTPWrong is a code that did not match; the code stays usable until
// AttemptsLeft reaches 0.
type CustomerOTPWrong struct {
	AttemptsLeft int
}

func (e *CustomerOTPWrong) Error() string {
	return fmt.Sprintf("customer otp wrong, %d attempts left", e.AttemptsLeft)
}

var (
	// ErrCustomerOTPExpired: no code is waiting for the phone, or it expired
	// or was used.
	ErrCustomerOTPExpired = errors.New("customer otp expired")
	// ErrCustomerOTPLocked: the code took too many wrong guesses; only a new
	// code signs in.
	ErrCustomerOTPLocked       = errors.New("customer otp locked")
	ErrCustomerNotFound        = errors.New("customer not found")
	ErrCustomerSessionNotFound = errors.New("customer session not found")
	// ErrCustomerRefreshReused: a refresh token that was already rotated came
	// back after the grace window. Someone else holds a copy, so the session
	// is ended.
	ErrCustomerRefreshReused = errors.New("customer refresh token reused")
	// ErrCustomerBlocked refuses a sign-in to an account an operator stopped.
	ErrCustomerBlocked = errors.New("customer blocked")
)

// CustomerSession is one signed-in device.
type CustomerSession struct {
	ID         string `json:"id"`
	CustomerID string `json:"customer_id"`
	AccessHash string `json:"access_hash"`
	// RefreshHash is the current refresh token; PreviousRefreshHash the one it
	// replaced at RotatedAt, honoured for CustomerRefreshGrace so a client
	// that lost the answer to its refresh can retry.
	RefreshHash         string    `json:"refresh_hash"`
	PreviousRefreshHash string    `json:"previous_refresh_hash,omitempty"`
	RotatedAt           time.Time `json:"rotated_at,omitempty"`
	DeviceID            string    `json:"device_id,omitempty"`
	DeviceName          string    `json:"device_name,omitempty"`
	Platform            string    `json:"platform,omitempty"`
	CreatedAt           time.Time `json:"created_at"`
	// LastSeenAt moves on each refresh, not on each request.
	LastSeenAt      time.Time `json:"last_seen_at"`
	AccessExpiresAt time.Time `json:"access_expires_at"`
	ExpiresAt       time.Time `json:"expires_at"`
	// PushToken is the device's Firebase Cloud Messaging token, when the
	// app registered one: how a notification reaches this customer here.
	PushToken string `json:"push_token,omitempty"`
}

// CustomerTokens are the hashes and lifetimes of a fresh token pair.
type CustomerTokens struct {
	AccessHash      string
	RefreshHash     string
	AccessExpiresAt time.Time
	ExpiresAt       time.Time
}

const (
	// CustomerRefreshGrace is how long a rotated refresh token still rotates.
	CustomerRefreshGrace = time.Minute
	// MaxCustomerSessions is how many devices one customer keeps; the least
	// recently seen is signed out to make room.
	MaxCustomerSessions   = 10
	maxCustomerDeviceText = 120
)

// customerDayZone is the Libyan day the daily code cap counts in.
var customerDayZone = time.FixedZone("UTC+2", 2*60*60)

func customerDay(at time.Time) string {
	return at.In(customerDayZone).Format("2006-01-02")
}

// CustomerOTPCodeHash is how a sign-in code is stored: bound to its phone, so
// one leaked hash cannot be tried against another number.
func CustomerOTPCodeHash(phone, code string) string {
	return TokenHash("customer-otp:" + phone + ":" + code)
}

// CustomerStore is an optional store capability.
type CustomerStore interface {
	// IssueCustomerOTP replaces any code waiting for the phone. A
	// *CustomerOTPRefusal when the phone asked too recently or too often.
	IssueCustomerOTP(ctx context.Context, request CustomerOTPRequest) (CustomerOTPChallenge, error)
	// CancelCustomerOTP drops a code the SMS never carried and gives its send
	// back, only while that code is still the waiting one.
	CancelCustomerOTP(ctx context.Context, phone, codeHash string) error
	// VerifyCustomerOTP spends the waiting code. A match signs the phone in,
	// creating its customer on first sign-in (created=true). A miss is a
	// *CustomerOTPWrong, or ErrCustomerOTPLocked on the last attempt.
	VerifyCustomerOTP(ctx context.Context, phone, codeHash string, maxAttempts int) (Customer, bool, error)
	GetCustomer(ctx context.Context, id string) (Customer, error)
	// CreateCustomerSession stores a new device, signing out the oldest beyond
	// MaxCustomerSessions.
	CreateCustomerSession(ctx context.Context, session CustomerSession) (CustomerSession, error)
	// CustomerByAccessToken resolves a live access token.
	CustomerByAccessToken(ctx context.Context, accessHash string) (Customer, CustomerSession, error)
	// RefreshCustomerSession rotates a session's tokens by its refresh token.
	RefreshCustomerSession(ctx context.Context, refreshHash string, next CustomerTokens) (CustomerSession, error)
	CustomerSessions(ctx context.Context, customerID string) ([]CustomerSession, error)
	DeleteCustomerSession(ctx context.Context, customerID, sessionID string) (bool, error)
	DeleteCustomerSessions(ctx context.Context, customerID string) (int, error)
	// DeleteCustomer forgets the phone and every session. The id stays, so
	// the customer's orders keep pointing at someone.
	DeleteCustomer(ctx context.Context, customerID string) error
}

var _ CustomerStore = (*FileStore)(nil)

func normalizeCustomerSession(session CustomerSession) (CustomerSession, error) {
	session.CustomerID = strings.TrimSpace(session.CustomerID)
	if session.CustomerID == "" || session.AccessHash == "" || session.RefreshHash == "" {
		return CustomerSession{}, errors.New("customer session needs a customer and both token hashes")
	}
	session.DeviceID = truncateRunes(strings.TrimSpace(session.DeviceID), maxCustomerDeviceText)
	session.DeviceName = truncateRunes(strings.TrimSpace(session.DeviceName), maxCustomerDeviceText)
	session.Platform = truncateRunes(strings.ToLower(strings.TrimSpace(session.Platform)), 20)
	if session.ID == "" {
		id, err := NewInstallationID()
		if err != nil {
			return CustomerSession{}, err
		}
		session.ID = id
	}
	return session, nil
}

// customerOTP is the waiting code of one phone, kept after use so the daily
// count survives a sign-in.
type customerOTP struct {
	Phone     string    `json:"phone"`
	CodeHash  string    `json:"code_hash"`
	Attempts  int       `json:"attempts"`
	SentAt    time.Time `json:"sent_at"`
	ExpiresAt time.Time `json:"expires_at"`
	Day       string    `json:"day"`
	Sends     int       `json:"sends"`
}

// issue applies a request to the phone's previous state.
func (o customerOTP) issue(request CustomerOTPRequest, now time.Time) (customerOTP, error) {
	day := customerDay(now)
	if o.Day != day {
		o.Sends = 0
	}
	if !o.SentAt.IsZero() && request.ResendAfter > 0 && now.Before(o.SentAt.Add(request.ResendAfter)) {
		return o, &CustomerOTPRefusal{Reason: CustomerOTPTooSoon, RetryAt: o.SentAt.Add(request.ResendAfter)}
	}
	if request.DailyLimit > 0 && o.Sends >= request.DailyLimit {
		midnight := now.In(customerDayZone)
		midnight = time.Date(midnight.Year(), midnight.Month(), midnight.Day(), 0, 0, 0, 0, customerDayZone)
		return o, &CustomerOTPRefusal{Reason: CustomerOTPDailyLimit, RetryAt: midnight.Add(24 * time.Hour).UTC()}
	}
	return customerOTP{
		Phone:     request.Phone,
		CodeHash:  request.CodeHash,
		SentAt:    now,
		ExpiresAt: now.Add(request.TTL),
		Day:       day,
		Sends:     o.Sends + 1,
	}, nil
}

func (o customerOTP) challenge(request CustomerOTPRequest) CustomerOTPChallenge {
	return CustomerOTPChallenge{
		Phone:      o.Phone,
		ExpiresAt:  o.ExpiresAt,
		ResendAt:   o.SentAt.Add(request.ResendAfter),
		SendsToday: o.Sends,
	}
}

// verify checks a guess. It returns the state to keep and whether it matched.
func (o customerOTP) verify(codeHash string, maxAttempts int, now time.Time) (customerOTP, error) {
	if o.CodeHash == "" || !now.Before(o.ExpiresAt) {
		return o, ErrCustomerOTPExpired
	}
	if maxAttempts > 0 && o.Attempts >= maxAttempts {
		return o, ErrCustomerOTPLocked
	}
	if subtle.ConstantTimeCompare([]byte(o.CodeHash), []byte(codeHash)) == 1 {
		o.CodeHash = ""
		o.Attempts = 0
		return o, nil
	}
	o.Attempts++
	if maxAttempts > 0 && o.Attempts >= maxAttempts {
		return o, ErrCustomerOTPLocked
	}
	left := 0
	if maxAttempts > 0 {
		left = maxAttempts - o.Attempts
	}
	return o, &CustomerOTPWrong{AttemptsLeft: left}
}

// refreshVerdict decides what a presented refresh token may do to a session.
func refreshVerdict(session CustomerSession, refreshHash string, now time.Time) error {
	if !now.Before(session.ExpiresAt) {
		return ErrCustomerSessionNotFound
	}
	if subtle.ConstantTimeCompare([]byte(session.RefreshHash), []byte(refreshHash)) == 1 {
		return nil
	}
	if session.PreviousRefreshHash != "" &&
		subtle.ConstantTimeCompare([]byte(session.PreviousRefreshHash), []byte(refreshHash)) == 1 {
		if now.Before(session.RotatedAt.Add(CustomerRefreshGrace)) {
			return nil
		}
		return ErrCustomerRefreshReused
	}
	return ErrCustomerSessionNotFound
}

func rotateCustomerSession(session CustomerSession, next CustomerTokens, now time.Time) CustomerSession {
	// A retry inside the grace window rotates again but keeps the original
	// previous hash, so the window never slides.
	if session.RefreshHash != "" && !(session.PreviousRefreshHash != "" && now.Before(session.RotatedAt.Add(CustomerRefreshGrace))) {
		session.PreviousRefreshHash = session.RefreshHash
		session.RotatedAt = now
	}
	session.AccessHash = next.AccessHash
	session.RefreshHash = next.RefreshHash
	session.AccessExpiresAt = next.AccessExpiresAt
	session.ExpiresAt = next.ExpiresAt
	session.LastSeenAt = now
	return session
}

// --- file store ------------------------------------------------------------

type fileCustomerData struct {
	Customers map[string]Customer        `json:"customers,omitempty"`
	OTPs      map[string]customerOTP     `json:"otps,omitempty"`
	Sessions  map[string]CustomerSession `json:"sessions,omitempty"`
	// Notifications are the operator's sends, newest last.
	Notifications []CustomerNotification `json:"notifications,omitempty"`
}

func (s *FileStore) customersLocked() *fileCustomerData {
	if s.data.Customers == nil {
		s.data.Customers = &fileCustomerData{}
	}
	c := s.data.Customers
	if c.Customers == nil {
		c.Customers = map[string]Customer{}
	}
	if c.OTPs == nil {
		c.OTPs = map[string]customerOTP{}
	}
	if c.Sessions == nil {
		c.Sessions = map[string]CustomerSession{}
	}
	return c
}

func (s *FileStore) IssueCustomerOTP(_ context.Context, request CustomerOTPRequest) (CustomerOTPChallenge, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	next, err := c.OTPs[request.Phone].issue(request, s.clock.Now().UTC())
	if err != nil {
		return CustomerOTPChallenge{}, err
	}
	c.OTPs[request.Phone] = next
	if err := s.saveLocked(); err != nil {
		return CustomerOTPChallenge{}, err
	}
	return next.challenge(request), nil
}

func (s *FileStore) CancelCustomerOTP(_ context.Context, phone, codeHash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	otp, ok := c.OTPs[phone]
	if !ok || otp.CodeHash != codeHash {
		return nil
	}
	otp.CodeHash = ""
	otp.SentAt = time.Time{}
	if otp.Sends > 0 {
		otp.Sends--
	}
	c.OTPs[phone] = otp
	return s.saveLocked()
}

func (s *FileStore) VerifyCustomerOTP(_ context.Context, phone, codeHash string, maxAttempts int) (Customer, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	now := s.clock.Now().UTC()
	otp, ok := c.OTPs[phone]
	if !ok {
		return Customer{}, false, ErrCustomerOTPExpired
	}
	next, verdict := otp.verify(codeHash, maxAttempts, now)
	c.OTPs[phone] = next
	if verdict != nil {
		if err := s.saveLocked(); err != nil {
			return Customer{}, false, err
		}
		return Customer{}, false, verdict
	}
	customer, created := Customer{}, true
	for _, existing := range c.Customers {
		if existing.Phone == phone && existing.DeletedAt == nil {
			customer, created = existing, false
			break
		}
	}
	if created {
		id, err := NewInstallationID()
		if err != nil {
			return Customer{}, false, err
		}
		customer = Customer{ID: id, Phone: phone, CreatedAt: now}
	}
	if customer.BlockedAt != nil {
		// The code is spent all the same.
		if err := s.saveLocked(); err != nil {
			return Customer{}, false, err
		}
		return Customer{}, false, ErrCustomerBlocked
	}
	customer.LastSignInAt = now
	c.Customers[customer.ID] = customer
	if err := s.saveLocked(); err != nil {
		return Customer{}, false, err
	}
	return customer, created, nil
}

func (s *FileStore) GetCustomer(_ context.Context, id string) (Customer, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.Customers == nil {
		return Customer{}, ErrCustomerNotFound
	}
	customer, ok := s.data.Customers.Customers[id]
	if !ok {
		return Customer{}, ErrCustomerNotFound
	}
	return customer, nil
}

func (s *FileStore) CreateCustomerSession(_ context.Context, session CustomerSession) (CustomerSession, error) {
	session, err := normalizeCustomerSession(session)
	if err != nil {
		return CustomerSession{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	customer, ok := c.Customers[session.CustomerID]
	if !ok || customer.DeletedAt != nil {
		return CustomerSession{}, ErrCustomerNotFound
	}
	now := s.clock.Now().UTC()
	session.CreatedAt = now
	session.LastSeenAt = now
	mine := []CustomerSession{}
	for id, existing := range c.Sessions {
		if !now.Before(existing.ExpiresAt) {
			delete(c.Sessions, id)
			continue
		}
		if existing.CustomerID == session.CustomerID {
			mine = append(mine, existing)
		}
	}
	sortSessionsBySeen(mine)
	for len(mine) >= MaxCustomerSessions {
		delete(c.Sessions, mine[len(mine)-1].ID)
		mine = mine[:len(mine)-1]
	}
	c.Sessions[session.ID] = session
	if err := s.saveLocked(); err != nil {
		return CustomerSession{}, err
	}
	return session, nil
}

// sortSessionsBySeen orders the most recently seen first.
func sortSessionsBySeen(sessions []CustomerSession) {
	sort.Slice(sessions, func(i, j int) bool {
		if !sessions[i].LastSeenAt.Equal(sessions[j].LastSeenAt) {
			return sessions[i].LastSeenAt.After(sessions[j].LastSeenAt)
		}
		return sessions[i].ID < sessions[j].ID
	})
}

func (s *FileStore) CustomerByAccessToken(_ context.Context, accessHash string) (Customer, CustomerSession, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data.Customers == nil || accessHash == "" {
		return Customer{}, CustomerSession{}, ErrCustomerSessionNotFound
	}
	now := s.clock.Now().UTC()
	for _, session := range s.data.Customers.Sessions {
		if subtle.ConstantTimeCompare([]byte(session.AccessHash), []byte(accessHash)) != 1 {
			continue
		}
		customer, ok := s.data.Customers.Customers[session.CustomerID]
		if !now.Before(session.AccessExpiresAt) || !ok || customer.DeletedAt != nil {
			break
		}
		return customer, session, nil
	}
	return Customer{}, CustomerSession{}, ErrCustomerSessionNotFound
}

func (s *FileStore) RefreshCustomerSession(_ context.Context, refreshHash string, next CustomerTokens) (CustomerSession, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	now := s.clock.Now().UTC()
	for id, session := range c.Sessions {
		verdict := refreshVerdict(session, refreshHash, now)
		if errors.Is(verdict, ErrCustomerSessionNotFound) {
			continue
		}
		if verdict != nil {
			delete(c.Sessions, id)
			if err := s.saveLocked(); err != nil {
				return CustomerSession{}, err
			}
			return CustomerSession{}, verdict
		}
		if customer, ok := c.Customers[session.CustomerID]; !ok || customer.DeletedAt != nil {
			return CustomerSession{}, ErrCustomerSessionNotFound
		}
		session = rotateCustomerSession(session, next, now)
		c.Sessions[id] = session
		if err := s.saveLocked(); err != nil {
			return CustomerSession{}, err
		}
		return session, nil
	}
	return CustomerSession{}, ErrCustomerSessionNotFound
}

func (s *FileStore) CustomerSessions(_ context.Context, customerID string) ([]CustomerSession, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sessions := []CustomerSession{}
	if s.data.Customers == nil {
		return sessions, nil
	}
	now := s.clock.Now().UTC()
	for _, session := range s.data.Customers.Sessions {
		if session.CustomerID == customerID && now.Before(session.ExpiresAt) {
			sessions = append(sessions, session)
		}
	}
	sortSessionsBySeen(sessions)
	return sessions, nil
}

func (s *FileStore) DeleteCustomerSession(_ context.Context, customerID, sessionID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	session, ok := c.Sessions[sessionID]
	if !ok || session.CustomerID != customerID {
		return false, nil
	}
	delete(c.Sessions, sessionID)
	return true, s.saveLocked()
}

func (s *FileStore) DeleteCustomerSessions(_ context.Context, customerID string) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	count := 0
	for id, session := range c.Sessions {
		if session.CustomerID == customerID {
			delete(c.Sessions, id)
			count++
		}
	}
	return count, s.saveLocked()
}

func (s *FileStore) DeleteCustomer(_ context.Context, customerID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.customersLocked()
	customer, ok := c.Customers[customerID]
	if !ok || customer.DeletedAt != nil {
		return ErrCustomerNotFound
	}
	now := s.clock.Now().UTC()
	if otp, ok := c.OTPs[customer.Phone]; ok {
		// Keep the row: its daily count still guards the number.
		otp.CodeHash = ""
		c.OTPs[customer.Phone] = otp
	}
	customer.Phone = ""
	customer.DeletedAt = &now
	c.Customers[customerID] = customer
	for id, session := range c.Sessions {
		if session.CustomerID == customerID {
			delete(c.Sessions, id)
		}
	}
	return s.saveLocked()
}

// --- cached store forwarding ---------------------------------------------

var _ CustomerStore = (*CachedInstallationStore)(nil)

var errCustomersUnsupported = errors.New("customer store is unavailable")

func (s *CachedInstallationStore) customerStore() (CustomerStore, error) {
	store, ok := s.store.(CustomerStore)
	if !ok {
		return nil, errCustomersUnsupported
	}
	return store, nil
}

func (s *CachedInstallationStore) IssueCustomerOTP(ctx context.Context, request CustomerOTPRequest) (CustomerOTPChallenge, error) {
	store, err := s.customerStore()
	if err != nil {
		return CustomerOTPChallenge{}, err
	}
	return store.IssueCustomerOTP(ctx, request)
}

func (s *CachedInstallationStore) CancelCustomerOTP(ctx context.Context, phone, codeHash string) error {
	store, err := s.customerStore()
	if err != nil {
		return err
	}
	return store.CancelCustomerOTP(ctx, phone, codeHash)
}

func (s *CachedInstallationStore) VerifyCustomerOTP(ctx context.Context, phone, codeHash string, maxAttempts int) (Customer, bool, error) {
	store, err := s.customerStore()
	if err != nil {
		return Customer{}, false, err
	}
	return store.VerifyCustomerOTP(ctx, phone, codeHash, maxAttempts)
}

func (s *CachedInstallationStore) GetCustomer(ctx context.Context, id string) (Customer, error) {
	store, err := s.customerStore()
	if err != nil {
		return Customer{}, err
	}
	return store.GetCustomer(ctx, id)
}

func (s *CachedInstallationStore) CreateCustomerSession(ctx context.Context, session CustomerSession) (CustomerSession, error) {
	store, err := s.customerStore()
	if err != nil {
		return CustomerSession{}, err
	}
	return store.CreateCustomerSession(ctx, session)
}

func (s *CachedInstallationStore) CustomerByAccessToken(ctx context.Context, accessHash string) (Customer, CustomerSession, error) {
	store, err := s.customerStore()
	if err != nil {
		return Customer{}, CustomerSession{}, err
	}
	return store.CustomerByAccessToken(ctx, accessHash)
}

func (s *CachedInstallationStore) RefreshCustomerSession(ctx context.Context, refreshHash string, next CustomerTokens) (CustomerSession, error) {
	store, err := s.customerStore()
	if err != nil {
		return CustomerSession{}, err
	}
	return store.RefreshCustomerSession(ctx, refreshHash, next)
}

func (s *CachedInstallationStore) CustomerSessions(ctx context.Context, customerID string) ([]CustomerSession, error) {
	store, err := s.customerStore()
	if err != nil {
		return nil, err
	}
	return store.CustomerSessions(ctx, customerID)
}

func (s *CachedInstallationStore) DeleteCustomerSession(ctx context.Context, customerID, sessionID string) (bool, error) {
	store, err := s.customerStore()
	if err != nil {
		return false, err
	}
	return store.DeleteCustomerSession(ctx, customerID, sessionID)
}

func (s *CachedInstallationStore) DeleteCustomerSessions(ctx context.Context, customerID string) (int, error) {
	store, err := s.customerStore()
	if err != nil {
		return 0, err
	}
	return store.DeleteCustomerSessions(ctx, customerID)
}

func (s *CachedInstallationStore) DeleteCustomer(ctx context.Context, customerID string) error {
	store, err := s.customerStore()
	if err != nil {
		return err
	}
	return store.DeleteCustomer(ctx, customerID)
}
