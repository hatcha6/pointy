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

// lineOf is quantity cards of unit dinars, of category, brand and item.
func lineOf(unit int64, quantity int, scope ...string) CustomerOfferLine {
	line := CustomerOfferLine{UnitPrice: big.NewRat(unit, 1), Quantity: quantity}
	if len(scope) == 3 {
		line.Category, line.Brand, line.Item = scope[0], scope[1], scope[2]
	}
	return line
}

func TestOfferDiscountRules(t *testing.T) {
	percent := CustomerOffer{Kind: CustomerOfferPercent, Value: "15", MaxDiscount: "5", MinOrder: "20"}
	for subtotal, want := range map[int64]string{10: "0.000", 20: "3.000", 30: "4.500", 100: "5.000"} {
		if got := FormatWalletAmount(CustomerOfferDiscount(percent, lineOf(subtotal, 1))); got != want {
			t.Errorf("15%% of %d: %s, want %s", subtotal, got, want)
		}
	}
	amount := CustomerOffer{Kind: CustomerOfferAmount, Value: "7", MaxDiscount: "0", MinOrder: "0"}
	if got := FormatWalletAmount(CustomerOfferDiscount(amount, lineOf(5, 1))); got != "5.000" {
		t.Fatalf("an amount larger than the order: %s", got)
	}
	// Down to the dirham: 33.335% of 10 is 3.3335, never 3.334.
	third := CustomerOffer{Kind: CustomerOfferPercent, Value: "33.335", MaxDiscount: "0", MinOrder: "0"}
	if got := FormatWalletAmount(CustomerOfferDiscount(third, lineOf(10, 1))); got != "3.333" {
		t.Fatalf("rounding: %s", got)
	}

	// 5% from 20, 10% from 50, 15% from 100, capped at 12.
	tiered := CustomerOffer{Kind: CustomerOfferTiered, TierUnit: CustomerOfferPercent, MaxDiscount: "12", MinOrder: "20",
		Tiers: []CustomerOfferTier{{MinOrder: "20", Value: "5"}, {MinOrder: "50", Value: "10"}, {MinOrder: "100", Value: "15"}}}
	for subtotal, want := range map[int64]string{10: "0.000", 20: "1.000", 49: "2.450", 50: "5.000", 100: "12.000"} {
		if got := FormatWalletAmount(CustomerOfferDiscount(tiered, lineOf(subtotal, 1))); got != want {
			t.Errorf("tiered on %d: %s, want %s", subtotal, got, want)
		}
	}
	tieredAmount := CustomerOffer{Kind: CustomerOfferTiered, TierUnit: CustomerOfferAmount, MaxDiscount: "1",
		Tiers: []CustomerOfferTier{{MinOrder: "30", Value: "3"}, {MinOrder: "60", Value: "8"}}}
	if got := FormatWalletAmount(CustomerOfferDiscount(tieredAmount, lineOf(70, 1))); got != "8.000" {
		t.Fatalf("an amount tier is not capped by max_discount: %s", got)
	}

	// Buy 2, get 1 free: the third card of every three.
	bogo := CustomerOffer{Kind: CustomerOfferBundle, BuyQuantity: 2, GetQuantity: 1, GetPercent: "100"}
	for quantity, want := range map[int]string{1: "0.000", 2: "0.000", 3: "10.000", 5: "10.000", 6: "20.000"} {
		if got := FormatWalletAmount(CustomerOfferDiscount(bogo, lineOf(10, quantity))); got != want {
			t.Errorf("buy 2 get 1 on %d cards: %s, want %s", quantity, got, want)
		}
	}
	half := CustomerOffer{Kind: CustomerOfferBundle, BuyQuantity: 1, GetQuantity: 1, GetPercent: "50", MaxDiscount: "6"}
	if got := FormatWalletAmount(CustomerOfferDiscount(half, lineOf(10, 4))); got != "6.000" {
		t.Fatalf("buy 1 get 1 half price, capped: %s", got)
	}

	// Scope: any list naming the card covers it.
	scoped := CustomerOffer{Kind: CustomerOfferPercent, Value: "10",
		Scope: CustomerOfferScope{Categories: []string{"games"}, Brands: []string{"libyana"}, Items: []string{"itunes-us-10"}}}
	for name, line := range map[string]CustomerOfferLine{
		"its category": lineOf(10, 1, "games", "pubg", "pubg-60"),
		"its brand":    lineOf(10, 1, "telecom", "libyana", "libyana-10"),
		"its item":     lineOf(10, 1, "gift_cards", "itunes", "itunes-us-10"),
	} {
		if CustomerOfferDiscount(scoped, line).Sign() == 0 {
			t.Errorf("%s: not covered", name)
		}
	}
	if CustomerOfferDiscount(scoped, lineOf(10, 1, "gift_cards", "itunes", "itunes-us-25")).Sign() != 0 {
		t.Fatal("a card outside the scope is discounted")
	}
	esim := CustomerOffer{Kind: CustomerOfferPercent, Value: "10", Scope: CustomerOfferScope{Categories: []string{CustomerOfferESIM}}}
	if CustomerOfferDiscount(esim, lineOf(30, 1, CustomerOfferESIM, "esim-tr", "plan-1")).Sign() == 0 {
		t.Fatal("an eSIM offer does not cover an eSIM")
	}

	now := time.Date(2026, 11, 24, 9, 0, 0, 0, time.UTC)
	for name, offer := range map[string]CustomerOffer{
		"no title":        {Name: "n", Kind: "percent", Value: "10", Segments: []string{"loyal"}},
		"no segment":      {Name: "n", Title: "t", Kind: "percent", Value: "10"},
		"too deep":        {Name: "n", Title: "t", Kind: "percent", Value: "95", Segments: []string{"loyal"}},
		"unknown kind":    {Name: "n", Title: "t", Kind: "gift", Value: "10", Segments: []string{"loyal"}},
		"ends at start":   {Name: "n", Title: "t", Kind: "amount", Value: "1", Segments: []string{"loyal"}, StartsAt: now, EndsAt: &now},
		"holdout too big": {Name: "n", Title: "t", Kind: "amount", Value: "1", Segments: []string{"loyal"}, HoldoutPercent: 60},
		"tiers not rising": {Name: "n", Title: "t", Kind: "tiered", Segments: []string{"loyal"},
			Tiers: []CustomerOfferTier{{MinOrder: "20", Value: "10"}, {MinOrder: "50", Value: "5"}}},
		"no tiers":               {Name: "n", Title: "t", Kind: "tiered", Segments: []string{"loyal"}},
		"bundle of none":         {Name: "n", Title: "t", Kind: "bundle", Segments: []string{"loyal"}, BuyQuantity: 0, GetQuantity: 1},
		"bundle above 100":       {Name: "n", Title: "t", Kind: "bundle", Segments: []string{"loyal"}, BuyQuantity: 1, GetQuantity: 1, GetPercent: "150"},
		"badge too long":         {Name: "n", Title: "t", Kind: "amount", Value: "1", Segments: []string{"loyal"}, Badge: "خصم كبير جداً على كل شيء اليوم فقط"},
		"everyone with segments": {Name: "n", Title: "t", Kind: "amount", Value: "1", Audience: "everyone", Segments: []string{"loyal"}},
		"everyone held out":      {Name: "n", Title: "t", Kind: "amount", Value: "1", Audience: "everyone", HoldoutPercent: 10},
	} {
		if _, err := normalizeCustomerOffer(offer, now); !errors.Is(err, ErrCustomerOfferInvalid) {
			t.Errorf("%s: %v", name, err)
		}
	}

	// Tiers are put in order and written the one way; a tiered offer's
	// value is its best tier, and its minimum its first.
	made, err := normalizeCustomerOffer(CustomerOffer{Name: "n", Title: "t", Kind: "tiered", Segments: []string{"loyal"},
		Tiers: []CustomerOfferTier{{MinOrder: "100", Value: "15"}, {MinOrder: "20", Value: "5"}},
		Scope: CustomerOfferScope{Brands: []string{" pubg ", "pubg", "freefire"}}}, now)
	if err != nil || made.Tiers[0].MinOrder != "20.000" || made.Value != "15.000" || made.MinOrder != "20.000" ||
		made.TierUnit != "percent" || len(made.Scope.Brands) != 2 || made.Scope.Brands[0] != "freefire" || made.Audience != "segments" {
		t.Fatalf("tiered %+v %v", made, err)
	}
	bundle, err := normalizeCustomerOffer(CustomerOffer{Name: "n", Title: "t", Kind: "bundle", Audience: "everyone",
		BuyQuantity: 2, GetQuantity: 1}, now)
	if err != nil || bundle.GetPercent != "100.000" || bundle.Segments == nil || len(bundle.Segments) != 0 {
		t.Fatalf("bundle %+v %v", bundle, err)
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

	// An offer for everyone, on one brand: buy 2 get 1 free. No recipients;
	// any customer may use it, on that brand only.
	everyone, err := offers.CreateCustomerOffer(ctx, CustomerOffer{
		Name: "bogo", Title: "اشترِ 2 واحصل على 1", Kind: CustomerOfferBundle, Audience: CustomerOfferForEveryone,
		BuyQuantity: 2, GetQuantity: 1, Scope: CustomerOfferScope{Brands: []string{"libyana"}}, Badge: "2+1",
	}, nil)
	if err != nil || everyone.Audience != "everyone" || everyone.Recipients != 0 {
		t.Fatalf("everyone offer %+v %v", everyone, err)
	}
	if read, _ := offers.GetCustomerOffer(ctx, everyone.ID); read.BuyQuantity != 2 || read.GetQuantity != 1 ||
		read.Badge != "2+1" || len(read.Scope.Brands) != 1 || read.GetPercent != "100.000" {
		t.Fatalf("everyone offer read back %+v", read)
	}
	if public, err := offers.PublicCustomerOffers(ctx, clock.Now()); err != nil || len(public) != 1 || public[0].ID != everyone.ID {
		t.Fatalf("public offers %+v %v", public, err)
	}
	if mine, _ := offers.CustomerOffersFor(ctx, held.ID, clock.Now()); len(mine) != 1 || mine[0].ID != everyone.ID {
		t.Fatalf("a held-out customer still sees an offer for everyone: %+v", mine)
	}
	if _, _, err := orders.BeginCustomerOrder(ctx, CustomerOrder{CustomerID: held.ID, IdempotencyKey: "other-brand", Channel: "apk",
		BrandKey: "almadar", ItemKey: "almadar-10", Quantity: 3, UnitPrice: "10", Method: "dafa_sadad", OfferID: everyone.ID}, false); !errors.Is(err, ErrCustomerOfferUnavailable) {
		t.Fatalf("another brand took it: %v", err)
	}
	three, _, err := orders.BeginCustomerOrder(ctx, CustomerOrder{CustomerID: held.ID, IdempotencyKey: "three", Channel: "apk",
		BrandKey: "libyana", ItemKey: "libyana-10", Category: "telecom", Quantity: 3, UnitPrice: "10", Method: "dafa_sadad", OfferID: everyone.ID}, false)
	if err != nil || three.Total != "20.000" || three.Discount != "10.000" {
		t.Fatalf("buy 2 get 1: %+v %v", three, err)
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
