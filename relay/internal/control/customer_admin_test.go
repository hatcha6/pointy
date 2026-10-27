package control

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type customerAdminTestStore interface {
	CustomerStore
	CustomerOrderStore
	CustomerAdminStore
}

func TestFileStoreCustomerAdmin(t *testing.T) {
	clock := &customerClock{now: time.Date(2026, 10, 27, 9, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	exerciseCustomerAdminStore(t, store, clock)

	// The console's changes survive a restart of the file store.
	reloaded, err := NewFileStore(store.path, clock)
	if err != nil {
		t.Fatal(err)
	}
	notes, err := reloaded.ListCustomerNotifications(context.Background(), CustomerNotificationFilter{})
	if err != nil || len(notes) != 2 {
		t.Fatalf("reloaded notifications = %v, %v", notes, err)
	}
}

func TestPostgresStoreCustomerAdmin(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_customer_notifications; DELETE FROM relay_customer_credit_entries;
		DELETE FROM relay_customer_orders; DELETE FROM relay_customer_sessions; DELETE FROM relay_customer_otps;
		DELETE FROM relay_customers`); err != nil {
		t.Fatal(err)
	}
	clock := &customerClock{now: time.Date(2026, 10, 27, 9, 0, 0, 0, time.UTC)}
	exerciseCustomerAdminStore(t, &PostgresStore{pool: pool, clock: clock}, clock)
}

func adminSignIn(t *testing.T, store customerAdminTestStore, phone, code string) (Customer, error) {
	t.Helper()
	ctx := context.Background()
	if _, err := store.IssueCustomerOTP(ctx, CustomerOTPRequest{
		Phone: phone, CodeHash: CustomerOTPCodeHash(phone, code),
		TTL: 5 * time.Minute, DailyLimit: 20,
	}); err != nil {
		t.Fatalf("otp for %s: %v", phone, err)
	}
	customer, _, err := store.VerifyCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, code), 5)
	return customer, err
}

func adminSession(t *testing.T, store customerAdminTestStore, customerID, name, platform string) CustomerSession {
	t.Helper()
	session, err := store.CreateCustomerSession(context.Background(), CustomerSession{
		CustomerID: customerID, AccessHash: "a-" + name, RefreshHash: "r-" + name,
		DeviceName: name, Platform: platform,
		AccessExpiresAt: time.Date(2026, 10, 27, 10, 0, 0, 0, time.UTC),
		ExpiresAt:       time.Date(2027, 1, 1, 0, 0, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatal(err)
	}
	return session
}

func exerciseCustomerAdminStore(t *testing.T, store customerAdminTestStore, clock *customerClock) {
	ctx := context.Background()
	buyer, err := adminSignIn(t, store, "218912345678", "111111")
	if err != nil {
		t.Fatal(err)
	}
	clock.advance(time.Minute)
	browser, err := adminSignIn(t, store, "218923456789", "222222")
	if err != nil {
		t.Fatal(err)
	}
	phone := adminSession(t, store, buyer.ID, "iPhone", "ios")
	tablet := adminSession(t, store, buyer.ID, "Galaxy", "android")
	other := adminSession(t, store, browser.ID, "Pixel", "android")

	// Push tokens: on their session; the same phone's token moves with it.
	if err := store.SetCustomerPushToken(ctx, buyer.ID, phone.ID, "tok-iphone"); err != nil {
		t.Fatal(err)
	}
	if err := store.SetCustomerPushToken(ctx, buyer.ID, tablet.ID, "tok-shared"); err != nil {
		t.Fatal(err)
	}
	if err := store.SetCustomerPushToken(ctx, browser.ID, other.ID, "tok-shared"); err != nil {
		t.Fatal(err)
	}
	if err := store.SetCustomerPushToken(ctx, browser.ID, phone.ID, "tok-x"); !errors.Is(err, ErrCustomerSessionNotFound) {
		t.Fatalf("someone else's session: %v", err)
	}

	// A delivered order (real money) and a review one (not counted as spent).
	order, _, err := store.BeginCustomerOrder(ctx, CustomerOrder{
		CustomerID: buyer.ID, IdempotencyKey: "o-1", Channel: "apk", ItemKey: "libyana-10", BrandKey: "libyana",
		ItemName: "ليبيانا 10", Quantity: 2, UnitPrice: "10", Method: "dafa_sadad",
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.AttachCustomerOrderPayment(ctx, order.ID, "pay-1", "https://pay.example/1"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.PayCustomerOrder(ctx, order.ID, "pay-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.StartCustomerOrderFulfilment(ctx, order.ID, "purchase-1"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.FinishCustomerOrder(ctx, order.ID, true, "", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.BeginCustomerOrder(ctx, CustomerOrder{
		CustomerID: buyer.ID, IdempotencyKey: "o-2", Channel: "ios", ItemKey: "almadar-5", BrandKey: "almadar",
		Quantity: 1, UnitPrice: "5", Method: "dafa_sadad",
	}, false); err != nil {
		t.Fatal(err)
	}

	// Credit: a grant, its repeat, a charge too large, a charge that fits.
	entry, balance, created, err := store.AdjustCustomerCredit(ctx, CustomerCreditChange{
		CustomerID: buyer.ID, Amount: "5", Note: "تعويض", Actor: "هاتم", Reference: "k-1",
	})
	if err != nil || !created || balance != "5.000" || entry.Kind != CustomerCreditAdjustment || entry.Actor != "هاتم" {
		t.Fatalf("grant = %+v %s %v %v", entry, balance, created, err)
	}
	if again, balance, created, err := store.AdjustCustomerCredit(ctx, CustomerCreditChange{
		CustomerID: buyer.ID, Amount: "5", Note: "تعويض", Reference: "k-1",
	}); err != nil || created || balance != "5.000" || again.ID != entry.ID {
		t.Fatalf("repeat = %+v %s %v %v", again, balance, created, err)
	}
	if _, _, _, err := store.AdjustCustomerCredit(ctx, CustomerCreditChange{
		CustomerID: buyer.ID, Amount: "-6", Note: "خطأ", Reference: "k-2",
	}); !errors.Is(err, ErrCustomerCreditInsufficient) {
		t.Fatalf("overdraw: %v", err)
	}
	for _, bad := range []CustomerCreditChange{
		{CustomerID: buyer.ID, Amount: "0", Note: "x", Reference: "k-3"},
		{CustomerID: buyer.ID, Amount: "1", Note: " ", Reference: "k-4"},
		{CustomerID: buyer.ID, Amount: "1.2345", Note: "x", Reference: "k-5"},
	} {
		if _, _, _, err := store.AdjustCustomerCredit(ctx, bad); !errors.Is(err, ErrCustomerCreditInvalid) {
			t.Fatalf("%+v: %v", bad, err)
		}
	}
	clock.advance(time.Second)
	if _, balance, _, err := store.AdjustCustomerCredit(ctx, CustomerCreditChange{
		CustomerID: buyer.ID, Amount: "-2", Note: "تصحيح", Reference: "k-6",
	}); err != nil || balance != "3.000" {
		t.Fatalf("charge: %s %v", balance, err)
	}
	if credit, entries, err := store.CustomerCredit(ctx, buyer.ID, 10); err != nil || credit != "3.000" ||
		len(entries) != 2 || entries[0].Note != "تصحيح" {
		t.Fatalf("credit = %s %+v %v", credit, entries, err)
	}

	// The list, searched as an operator types a phone.
	list, total, err := store.ListCustomers(ctx, CustomerListFilter{Query: "0912 345"})
	if err != nil || total != 1 || len(list) != 1 || list[0].ID != buyer.ID {
		t.Fatalf("search = %+v %d %v", list, total, err)
	}
	got := list[0]
	if got.Orders != 2 || got.Delivered != 1 || got.Spent != "20.000" || got.Credit != "3.000" ||
		got.Devices != 2 || got.PushDevices != 1 || got.Platforms != "android,ios" || got.LastOrderAt == nil {
		t.Fatalf("summary = %+v", got)
	}
	if list, total, _ := store.ListCustomers(ctx, CustomerListFilter{Segment: "buyers"}); total != 1 || list[0].ID != buyer.ID {
		t.Fatalf("buyers = %+v", list)
	}
	if list, total, _ := store.ListCustomers(ctx, CustomerListFilter{Limit: 1}); total != 2 || len(list) != 1 || list[0].ID != browser.ID {
		t.Fatalf("newest sign-in first, paged = %+v %d", list, total)
	}
	if one, err := store.CustomerSummaryByID(ctx, browser.ID); err != nil || one.PushDevices != 1 || one.Orders != 0 {
		t.Fatalf("by id = %+v %v", one, err)
	}

	// Orders across customers, filtered as the console asks.
	for _, c := range []struct {
		filter CustomerOrderFilter
		want   int
	}{
		{CustomerOrderFilter{}, 2},
		{CustomerOrderFilter{Status: CustomerOrderDelivered}, 1},
		{CustomerOrderFilter{Status: "open"}, 1},
		{CustomerOrderFilter{Channel: "ios"}, 1},
		{CustomerOrderFilter{Query: "ALMADAR"}, 1},
		{CustomerOrderFilter{Query: "pay-1"}, 1},
		{CustomerOrderFilter{Query: "100%"}, 0},
	} {
		if orders, err := store.ListCustomerOrders(ctx, c.filter); err != nil || len(orders) != c.want {
			t.Fatalf("%+v = %d orders %v", c.filter, len(orders), err)
		}
	}

	// Stopping an account signs it out everywhere and refuses its phone.
	blocked, err := store.SetCustomerBlocked(ctx, buyer.ID, true, "احتيال")
	if err != nil || blocked.BlockedAt == nil || blocked.BlockedReason != "احتيال" {
		t.Fatalf("block = %+v %v", blocked, err)
	}
	if sessions, _ := store.CustomerSessions(ctx, buyer.ID); len(sessions) != 0 {
		t.Fatalf("still signed in: %+v", sessions)
	}
	before := blocked.LastSignInAt
	clock.advance(time.Hour)
	if _, err := adminSignIn(t, store, "218912345678", "333333"); !errors.Is(err, ErrCustomerBlocked) {
		t.Fatalf("blocked sign-in: %v", err)
	}
	if still, _ := store.GetCustomer(ctx, buyer.ID); !still.LastSignInAt.Equal(before) {
		t.Fatalf("a refused sign-in moved the date: %v", still.LastSignInAt)
	}

	stats, err := store.CustomerStats(ctx)
	if err != nil || stats.Customers != 2 || stats.Buyers != 1 || stats.Blocked != 1 || stats.WithPush != 1 ||
		stats.Spent != "20.000" || stats.CreditOwed != "3.000" || stats.OpenOrders != 1 || stats.Orders30d != 2 ||
		stats.New7d != 2 || stats.Active30d != 2 {
		t.Fatalf("stats = %+v %v", stats, err)
	}

	if _, err := store.SetCustomerBlocked(ctx, buyer.ID, false, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := adminSignIn(t, store, "218912345678", "444444"); err != nil {
		t.Fatalf("restarted sign-in: %v", err)
	}

	// A token Firebase forgot leaves its session.
	if err := store.ForgetCustomerPushToken(ctx, "tok-shared"); err != nil {
		t.Fatal(err)
	}
	if one, _ := store.CustomerSummaryByID(ctx, browser.ID); one.PushDevices != 0 {
		t.Fatalf("forgotten token still counted: %+v", one)
	}

	// The notification log, everyone's and one customer's.
	if _, err := store.RecordCustomerNotification(ctx, CustomerNotification{
		Audience: "all", Title: "عرض", Body: "خصم على ليبيانا", Link: "https://cards.dftr.ly/brand/libyana", SentBy: "هاتم",
	}); err != nil {
		t.Fatal(err)
	}
	clock.advance(time.Minute)
	if _, err := store.RecordCustomerNotification(ctx, CustomerNotification{
		Audience: "customer", CustomerID: buyer.ID, Title: "مرحباً", Body: "رصيدك جاهز", Devices: 1, Sent: 1,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RecordCustomerNotification(ctx, CustomerNotification{Audience: "all", Title: "", Body: "x"}); err == nil {
		t.Fatal("a notification without a title was logged")
	}
	if all, _ := store.ListCustomerNotifications(ctx, CustomerNotificationFilter{}); len(all) != 2 || all[0].Title != "مرحباً" {
		t.Fatalf("log = %+v", all)
	}
	if mine, _ := store.ListCustomerNotifications(ctx, CustomerNotificationFilter{CustomerID: buyer.ID}); len(mine) != 1 || mine[0].Sent != 1 {
		t.Fatalf("customer's log = %+v", mine)
	}
}
