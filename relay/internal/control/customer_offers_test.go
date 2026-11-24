package control

import (
	"context"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestOfferDiscountRules(t *testing.T) {
	percent := CustomerOffer{Kind: CustomerOfferPercent, Value: "15", MaxDiscount: "5", MinOrder: "20"}
	for subtotal, want := range map[int64]string{10: "0.000", 20: "3.000", 30: "4.500", 100: "5.000"} {
		if got := FormatWalletAmount(CustomerOfferDiscount(percent, big.NewRat(subtotal, 1))); got != want {
			t.Errorf("15%% of %d: %s, want %s", subtotal, got, want)
		}
	}
	amount := CustomerOffer{Kind: CustomerOfferAmount, Value: "7", MaxDiscount: "0", MinOrder: "0"}
	if got := FormatWalletAmount(CustomerOfferDiscount(amount, big.NewRat(5, 1))); got != "5.000" {
		t.Fatalf("an amount larger than the order: %s", got)
	}
	// Down to the dirham: 33.335% of 10 is 3.3335, never 3.334.
	third := CustomerOffer{Kind: CustomerOfferPercent, Value: "33.335", MaxDiscount: "0", MinOrder: "0"}
	if got := FormatWalletAmount(CustomerOfferDiscount(third, big.NewRat(10, 1))); got != "3.333" {
		t.Fatalf("rounding: %s", got)
	}
	now := time.Date(2026, 11, 24, 9, 0, 0, 0, time.UTC)
	for name, offer := range map[string]CustomerOffer{
		"no title":        {Name: "n", Kind: "percent", Value: "10", Segments: []string{"loyal"}},
		"no segment":      {Name: "n", Title: "t", Kind: "percent", Value: "10"},
		"too deep":        {Name: "n", Title: "t", Kind: "percent", Value: "95", Segments: []string{"loyal"}},
		"unknown kind":    {Name: "n", Title: "t", Kind: "gift", Value: "10", Segments: []string{"loyal"}},
		"ends at start":   {Name: "n", Title: "t", Kind: "amount", Value: "1", Segments: []string{"loyal"}, StartsAt: now, EndsAt: &now},
		"holdout too big": {Name: "n", Title: "t", Kind: "amount", Value: "1", Segments: []string{"loyal"}, HoldoutPercent: 60},
	} {
		if _, err := normalizeCustomerOffer(offer, now); !errors.Is(err, ErrCustomerOfferInvalid) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestFileStoreCustomerOffers(t *testing.T) {
	clock := &customerClock{now: time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "store.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	exerciseCustomerOffers(t, store, store, store, store, clock)
}

func TestPostgresStoreCustomerOffers(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_customer_offers; DELETE FROM relay_customer_credit_entries;
		DELETE FROM relay_customer_orders; DELETE FROM relay_customer_sessions; DELETE FROM relay_customer_otps;
		DELETE FROM relay_customers`); err != nil {
		t.Fatal(err)
	}
	clock := &customerClock{now: time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)}
	store := &PostgresStore{pool: pool, clock: clock}
	exerciseCustomerOffers(t, store, store, store, store, clock)
}

func signIn(t *testing.T, customers CustomerStore, phone string) Customer {
	t.Helper()
	ctx := context.Background()
	if _, err := customers.IssueCustomerOTP(ctx, CustomerOTPRequest{Phone: phone, CodeHash: CustomerOTPCodeHash(phone, "246810"), TTL: time.Minute}); err != nil {
		t.Fatal(err)
	}
	customer, _, err := customers.VerifyCustomerOTP(ctx, phone, CustomerOTPCodeHash(phone, "246810"), 5)
	if err != nil {
		t.Fatal(err)
	}
	return customer
}

func exerciseCustomerOffers(t *testing.T, customers CustomerStore, orders CustomerOrderStore, offers CustomerOfferStore, insights CustomerInsightStore, clock *customerClock) {
	t.Helper()
	ctx := context.Background()
	given := signIn(t, customers, "218910000011")
	held := signIn(t, customers, "218910000012")
	other := signIn(t, customers, "218910000013")
	if _, err := customers.CreateCustomerSession(ctx, CustomerSession{
		ID: "s-1", CustomerID: given.ID, AccessHash: "a1", RefreshHash: "r1",
		CreatedAt: clock.Now(), LastSeenAt: clock.Now(), AccessExpiresAt: clock.Now().Add(time.Hour), ExpiresAt: clock.Now().Add(24 * time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if err := customers.(CustomerAdminStore).SetCustomerPushToken(ctx, given.ID, "s-1", "phone-1"); err != nil {
		t.Fatal(err)
	}

	ends := clock.Now().Add(48 * time.Hour)
	offer, err := offers.CreateCustomerOffer(ctx, CustomerOffer{
		Name: "back", Title: "خصم 10٪", Kind: CustomerOfferPercent, Value: "10", MaxDiscount: "3",
		Segments: []string{"at_risk"}, EndsAt: &ends, HoldoutPercent: 50, CreatedBy: "Hatem",
	}, []CustomerOfferRecipient{
		{CustomerID: given.ID, Segment: "at_risk"},
		{CustomerID: held.ID, Segment: "at_risk", Holdout: true},
		{CustomerID: given.ID, Segment: "at_risk"},
	})
	if err != nil || offer.Recipients != 1 || offer.Holdouts != 1 || offer.UsesPerCustomer != 1 || !offer.Active {
		t.Fatalf("created %+v %v", offer, err)
	}
	if read, err := offers.GetCustomerOffer(ctx, offer.ID); err != nil || read.Value != "10.000" || read.MaxDiscount != "3.000" ||
		read.HoldoutPercent != 50 || read.EndsAt == nil || !read.EndsAt.Equal(ends) {
		t.Fatalf("read back %+v %v", read, err)
	}
	if people, err := offers.CustomerOfferRecipients(ctx, offer.ID); err != nil || len(people) != 2 {
		t.Fatalf("recipients %+v %v", people, err)
	}

	for _, who := range []Customer{held, other} {
		if mine, err := offers.CustomerOffersFor(ctx, who.ID, clock.Now()); err != nil || len(mine) != 0 {
			t.Fatalf("%s sees %+v %v", who.ID, mine, err)
		}
		if _, _, err := orders.BeginCustomerOrder(ctx, CustomerOrder{CustomerID: who.ID, IdempotencyKey: "try", Channel: "apk",
			ItemKey: "libyana-10", Quantity: 1, UnitPrice: "10", Method: "dafa_sadad", OfferID: offer.ID}, false); !errors.Is(err, ErrCustomerOfferUnavailable) {
			t.Fatalf("%s used it: %v", who.ID, err)
		}
	}
	if mine, err := offers.CustomerOffersFor(ctx, given.ID, clock.Now()); err != nil || len(mine) != 1 || mine[0].UsesLeft != 1 {
		t.Fatalf("given sees %+v %v", mine, err)
	}

	// 10% of 50, capped at 3.
	order, created, err := orders.BeginCustomerOrder(ctx, CustomerOrder{CustomerID: given.ID, IdempotencyKey: "o-1", Channel: "apk",
		ItemKey: "libyana-50", Quantity: 1, UnitPrice: "50", Method: "dafa_sadad", OfferID: offer.ID}, false)
	if err != nil || !created || order.Total != "47.000" || order.Discount != "3.000" || order.AmountDue != "47.000" {
		t.Fatalf("order %+v %v", order, err)
	}
	if again, _ := orders.GetCustomerOrder(ctx, order.ID); again.OfferID != offer.ID || again.Discount != "3.000" {
		t.Fatalf("read back %+v", again)
	}
	if _, _, err := orders.BeginCustomerOrder(ctx, CustomerOrder{CustomerID: given.ID, IdempotencyKey: "o-2", Channel: "apk",
		ItemKey: "libyana-50", Quantity: 1, UnitPrice: "50", Method: "dafa_sadad", OfferID: offer.ID}, false); !errors.Is(err, ErrCustomerOfferUnavailable) {
		t.Fatalf("a second use: %v", err)
	}
	// Called off, the use comes back.
	if _, _, err := orders.CloseCustomerOrder(ctx, order.ID, CustomerOrderCancelled, "", ""); err != nil {
		t.Fatal(err)
	}
	if mine, _ := offers.CustomerOffersFor(ctx, given.ID, clock.Now()); len(mine) != 1 {
		t.Fatalf("after a cancelled order: %+v", mine)
	}

	// Stopped, or past its end: gone.
	stop := false
	if updated, err := offers.UpdateCustomerOffer(ctx, offer.ID, CustomerOfferUpdate{Active: &stop}); err != nil || updated.Active {
		t.Fatalf("stopped %+v %v", updated, err)
	}
	if mine, _ := offers.CustomerOffersFor(ctx, given.ID, clock.Now()); len(mine) != 0 {
		t.Fatalf("a stopped offer: %+v", mine)
	}
	if listed, err := offers.ListCustomerOffers(ctx); err != nil || len(listed) != 1 {
		t.Fatalf("listed %+v %v", listed, err)
	}
	if _, err := offers.UpdateCustomerOffer(ctx, "missing", CustomerOfferUpdate{Active: &stop}); !errors.Is(err, ErrCustomerOfferNotFound) {
		t.Fatalf("missing offer: %v", err)
	}

	// What the segmentation reads.
	facts, err := insights.CustomerFacts(ctx)
	if err != nil || len(facts) != 3 {
		t.Fatalf("facts %+v %v", facts, err)
	}
	for _, fact := range facts {
		if want := map[string]int{given.ID: 1}[fact.ID]; fact.PushDevices != want {
			t.Fatalf("push devices %+v", fact)
		}
	}
	tokens, err := insights.CustomerPushTokens(ctx, []string{given.ID, held.ID})
	if err != nil || len(tokens) != 1 || len(tokens[given.ID]) != 1 || tokens[given.ID][0] != "phone-1" {
		t.Fatalf("tokens %v %v", tokens, err)
	}
	// A delivered order is read, with no cost when there is no purchase.
	sold, _, err := orders.BeginCustomerOrder(ctx, CustomerOrder{CustomerID: other.ID, IdempotencyKey: "sold", Channel: "ios",
		BrandKey: "libyana", ItemKey: "libyana-10", Quantity: 2, UnitPrice: "10", Method: "dafa_sadad"}, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := orders.PayCustomerOrder(ctx, sold.ID, "pay-sold"); err != nil {
		t.Fatal(err)
	}
	if _, err := orders.StartCustomerOrderFulfilment(ctx, sold.ID, "no-such-purchase"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := orders.FinishCustomerOrder(ctx, sold.ID, true, "", ""); err != nil {
		t.Fatal(err)
	}
	if facts, err := insights.CustomerOrderFacts(ctx); err != nil || len(facts) != 1 || facts[0].CustomerID != other.ID ||
		facts[0].Total != "20.000" || facts[0].Discount != "0.000" || facts[0].Channel != "ios" || facts[0].SupplierCost != "" {
		t.Fatalf("order facts %+v %v", facts, err)
	}
	only, total, err := customers.(CustomerAdminStore).ListCustomers(ctx, CustomerListFilter{OnlyIDs: true, IDs: []string{held.ID}})
	if err != nil || total != 1 || len(only) != 1 || only[0].ID != held.ID {
		t.Fatalf("list by ids %+v %d %v", only, total, err)
	}
	if none, total, _ := customers.(CustomerAdminStore).ListCustomers(ctx, CustomerListFilter{OnlyIDs: true}); total != 0 || len(none) != 0 {
		t.Fatalf("an empty id list keeps none: %d", total)
	}
}
