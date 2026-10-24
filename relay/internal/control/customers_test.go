package control

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type customerClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *customerClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *customerClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func TestFileStoreCustomers(t *testing.T) {
	clock := &customerClock{now: time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	exerciseCustomerStore(t, store, clock)

	// Everything survives a restart of the file store.
	reloaded, err := NewFileStore(store.path, clock)
	if err != nil {
		t.Fatal(err)
	}
	sessions, err := reloaded.CustomerSessions(context.Background(), customerUnderTest)
	if err != nil || len(sessions) != 1 {
		t.Fatalf("reloaded sessions = %v, %v", sessions, err)
	}
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// scratch database (the tables are created by the migrations and emptied).
func TestPostgresStoreCustomers(t *testing.T) {
	url := os.Getenv("POINTY_RELAY_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("POINTY_RELAY_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := MigratePostgres(ctx, pool); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM relay_customer_credit_entries; DELETE FROM relay_customer_orders;
		DELETE FROM relay_customer_sessions; DELETE FROM relay_customer_otps; DELETE FROM relay_customers`); err != nil {
		t.Fatal(err)
	}
	clock := &customerClock{now: time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)}
	store := &PostgresStore{pool: pool, clock: clock}
	exerciseCustomerStore(t, store, clock)

	// Racing first requests for a never-seen number: one code, the rest wait.
	var wait sync.WaitGroup
	results := make(chan error, 12)
	for i := 0; i < 12; i++ {
		wait.Add(1)
		go func(i int) {
			defer wait.Done()
			_, err := store.IssueCustomerOTP(ctx, CustomerOTPRequest{
				Phone: "218955555555", CodeHash: CustomerOTPCodeHash("218955555555", fmt.Sprint(i)),
				TTL: time.Minute, ResendAfter: 30 * time.Second, DailyLimit: 6,
			})
			results <- err
		}(i)
	}
	wait.Wait()
	close(results)
	issued, refused := 0, 0
	for err := range results {
		var refusal *CustomerOTPRefusal
		switch {
		case err == nil:
			issued++
		case errors.As(err, &refusal) && refusal.Reason == CustomerOTPTooSoon:
			refused++
		default:
			t.Fatalf("racing first code: %v", err)
		}
	}
	if issued != 1 || refused != 11 {
		t.Fatalf("racing first codes: %d issued, %d refused", issued, refused)
	}
}

// customerUnderTest is the id of the customer exerciseCustomerStore leaves
// signed in on one device.
var customerUnderTest string

func exerciseCustomerStore(t *testing.T, store CustomerStore, clock *customerClock) {
	t.Helper()
	ctx := context.Background()
	phone := "218912345678"
	issue := func(code string) (CustomerOTPChallenge, error) {
		return store.IssueCustomerOTP(ctx, CustomerOTPRequest{
			Phone: phone, CodeHash: CustomerOTPCodeHash(phone, code),
			TTL: 5 * time.Minute, ResendAfter: 30 * time.Second, DailyLimit: 3,
		})
	}

	// Codes: resend gap, daily cap, cancel gives a send back.
	challenge, err := issue("111111")
	if err != nil || challenge.SendsToday != 1 || !challenge.ResendAt.Equal(clock.Now().Add(30*time.Second)) {
		t.Fatalf("first code = %+v, %v", challenge, err)
	}
	var refusal *CustomerOTPRefusal
	if _, err := issue("222222"); !errors.As(err, &refusal) || refusal.Reason != CustomerOTPTooSoon {
		t.Fatalf("too soon = %v", err)
	}
	if err := store.CancelCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, "111111")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.VerifyCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, "111111"), 5); !errors.Is(err, ErrCustomerOTPExpired) {
		t.Fatalf("cancelled code verified: %v", err)
	}
	for i, code := range []string{"333333", "444444", "555555"} {
		if i > 0 {
			clock.advance(31 * time.Second)
		}
		if _, err := issue(code); err != nil {
			t.Fatalf("code %s: %v", code, err)
		}
	}
	clock.advance(31 * time.Second)
	if _, err := issue("666666"); !errors.As(err, &refusal) || refusal.Reason != CustomerOTPDailyLimit {
		t.Fatalf("daily cap = %v", err)
	}

	// Guesses: wrong, then right; an older code no longer works.
	var wrong *CustomerOTPWrong
	if _, _, err := store.VerifyCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, "444444"), 5); !errors.As(err, &wrong) || wrong.AttemptsLeft != 4 {
		t.Fatalf("old code = %v", err)
	}
	customer, created, err := store.VerifyCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, "555555"), 5)
	if err != nil || !created || customer.Phone != phone {
		t.Fatalf("sign-in = %+v %v %v", customer, created, err)
	}
	if _, _, err := store.VerifyCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, "555555"), 5); !errors.Is(err, ErrCustomerOTPExpired) {
		t.Fatalf("spent code = %v", err)
	}
	// The daily count survives the sign-in.
	clock.advance(31 * time.Second)
	if _, err := issue("777777"); !errors.As(err, &refusal) || refusal.Reason != CustomerOTPDailyLimit {
		t.Fatalf("daily cap after sign-in = %v", err)
	}

	// Lock after the last wrong guess, on a fresh number.
	other := "218921112233"
	if _, err := store.IssueCustomerOTP(ctx, CustomerOTPRequest{Phone: other, CodeHash: CustomerOTPCodeHash(other, "123123"), TTL: time.Minute}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		_, _, err = store.VerifyCustomerOTP(ctx, other, CustomerOTPCodeHash(other, "000000"), 2)
	}
	if !errors.Is(err, ErrCustomerOTPLocked) {
		t.Fatalf("lock = %v", err)
	}
	if _, _, err := store.VerifyCustomerOTP(ctx, other, CustomerOTPCodeHash(other, "123123"), 2); !errors.Is(err, ErrCustomerOTPLocked) {
		t.Fatalf("right code after lock = %v", err)
	}

	// Sessions: create, resolve, rotate, grace, reuse.
	now := clock.Now()
	session, err := store.CreateCustomerSession(ctx, CustomerSession{
		CustomerID: customer.ID, AccessHash: "a1", RefreshHash: "r1", DeviceName: "Galaxy", Platform: "Android",
		AccessExpiresAt: now.Add(time.Hour), ExpiresAt: now.Add(24 * time.Hour),
	})
	if err != nil || session.Platform != "android" || session.ID == "" {
		t.Fatalf("session = %+v, %v", session, err)
	}
	got, gotSession, err := store.CustomerByAccessToken(ctx, "a1")
	if err != nil || got.ID != customer.ID || gotSession.ID != session.ID {
		t.Fatalf("by access = %+v %+v %v", got, gotSession, err)
	}
	next := func(n string) CustomerTokens {
		now := clock.Now()
		return CustomerTokens{AccessHash: "a" + n, RefreshHash: "r" + n, AccessExpiresAt: now.Add(time.Hour), ExpiresAt: now.Add(24 * time.Hour)}
	}
	if _, err := store.RefreshCustomerSession(ctx, "r1", next("2")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.CustomerByAccessToken(ctx, "a1"); !errors.Is(err, ErrCustomerSessionNotFound) {
		t.Fatalf("replaced access = %v", err)
	}
	clock.advance(10 * time.Second)
	if _, err := store.RefreshCustomerSession(ctx, "r1", next("3")); err != nil {
		t.Fatalf("grace retry = %v", err)
	}
	if _, err := store.RefreshCustomerSession(ctx, "r2", next("4")); !errors.Is(err, ErrCustomerSessionNotFound) {
		t.Fatalf("the pair the retry replaced = %v", err)
	}
	clock.advance(2 * time.Minute)
	if _, err := store.RefreshCustomerSession(ctx, "r1", next("5")); !errors.Is(err, ErrCustomerRefreshReused) {
		t.Fatalf("reuse = %v", err)
	}
	if _, err := store.RefreshCustomerSession(ctx, "r3", next("6")); !errors.Is(err, ErrCustomerSessionNotFound) {
		t.Fatalf("session after reuse = %v", err)
	}

	// Device cap: the least recently seen goes.
	var oldest CustomerSession
	for i := 0; i < MaxCustomerSessions+1; i++ {
		clock.advance(time.Second)
		now := clock.Now()
		created, err := store.CreateCustomerSession(ctx, CustomerSession{
			CustomerID: customer.ID, AccessHash: "cap-a" + string(rune('a'+i)), RefreshHash: "cap-r" + string(rune('a'+i)),
			AccessExpiresAt: now.Add(time.Hour), ExpiresAt: now.Add(24 * time.Hour),
		})
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			oldest = created
		}
	}
	sessions, err := store.CustomerSessions(ctx, customer.ID)
	if err != nil || len(sessions) != MaxCustomerSessions {
		t.Fatalf("sessions = %d, %v", len(sessions), err)
	}
	for _, s := range sessions {
		if s.ID == oldest.ID {
			t.Fatal("the oldest device was kept")
		}
	}
	if deleted, err := store.DeleteCustomerSession(ctx, "someone-else", sessions[0].ID); err != nil || deleted {
		t.Fatalf("deleted another customer's session: %v %v", deleted, err)
	}
	if count, err := store.DeleteCustomerSessions(ctx, customer.ID); err != nil || count != MaxCustomerSessions {
		t.Fatalf("delete all = %d, %v", count, err)
	}

	// Delete the account: the phone is forgotten, its daily count is not.
	now = clock.Now()
	if _, err := store.CreateCustomerSession(ctx, CustomerSession{
		CustomerID: customer.ID, AccessHash: "del-a", RefreshHash: "del-r",
		AccessExpiresAt: now.Add(time.Hour), ExpiresAt: now.Add(24 * time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteCustomer(ctx, customer.ID); err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteCustomer(ctx, customer.ID); !errors.Is(err, ErrCustomerNotFound) {
		t.Fatalf("second delete = %v", err)
	}
	if _, _, err := store.CustomerByAccessToken(ctx, "del-a"); !errors.Is(err, ErrCustomerSessionNotFound) {
		t.Fatalf("deleted customer's access = %v", err)
	}
	if _, err := store.CreateCustomerSession(ctx, CustomerSession{
		CustomerID: customer.ID, AccessHash: "x", RefreshHash: "y", AccessExpiresAt: now, ExpiresAt: now,
	}); !errors.Is(err, ErrCustomerNotFound) {
		t.Fatalf("session for a deleted customer = %v", err)
	}
	deleted, err := store.GetCustomer(ctx, customer.ID)
	if err != nil || deleted.Phone != "" || deleted.DeletedAt == nil {
		t.Fatalf("deleted = %+v, %v", deleted, err)
	}
	if _, err := issue("888888"); !errors.As(err, &refusal) || refusal.Reason != CustomerOTPDailyLimit {
		t.Fatalf("daily cap after delete = %v", err)
	}

	// The next Libyan day the number signs up again as someone new.
	clock.advance(24 * time.Hour)
	if _, err := issue("999999"); err != nil {
		t.Fatal(err)
	}
	again, created, err := store.VerifyCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, "999999"), 5)
	if err != nil || !created || again.ID == customer.ID {
		t.Fatalf("sign-up after delete = %+v %v %v", again, created, err)
	}
	now = clock.Now()
	if _, err := store.CreateCustomerSession(ctx, CustomerSession{
		CustomerID: again.ID, AccessHash: "keep-a", RefreshHash: "keep-r",
		AccessExpiresAt: now.Add(time.Hour), ExpiresAt: now.Add(24 * time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	customerUnderTest = again.ID
}

// The relay's HTTP layer holds the Redis-cached wrapper whenever Redis is
// configured; customer sign-in must reach the real store through it.
func TestCachedStoreKeepsCustomerCapability(t *testing.T) {
	clock := &customerClock{now: time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)}
	inner, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	var cached InstallationStore = NewCachedInstallationStore(inner, newMemoryInstallationCache(), clock, time.Minute)
	customers, ok := cached.(CustomerStore)
	if !ok {
		t.Fatal("cached store must expose the customer capability")
	}
	exerciseCustomerStore(t, customers, clock)
}
