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

type customerCampaignTestStore interface {
	customerAdminTestStore
	CustomerCampaignStore
}

func TestNormalizeCampaignCode(t *testing.T) {
	for typed, want := range map[string]string{
		" misrata5 ": "MISRATA5", "Lawha-1": "LAWHA-1", "a_b": "A_B",
		"ab": "", "مصراتة": "", "TOO-LONG-FOR-A-CODE-12345": "", "has space": "",
	} {
		got, ok := NormalizeCampaignCode(typed)
		if got != want || ok != (want != "") {
			t.Errorf("%q = %q %v, want %q", typed, got, ok, want)
		}
	}
	for landing, ok := range map[string]bool{"": true, "/brand/pubg": true, "//evil.example": false,
		"https://evil.example": false, "/go/X": false, "/a b": false} {
		if _, got := NormalizeCampaignLanding(landing); got != ok {
			t.Errorf("landing %q ok=%v", landing, got)
		}
	}
}

func TestFileStoreCustomerCampaigns(t *testing.T) {
	clock := &customerClock{now: time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	exerciseCustomerCampaigns(t, store, clock)

	// Campaigns, clicks and attributions survive a restart.
	reloaded, err := NewFileStore(store.path, clock)
	if err != nil {
		t.Fatal(err)
	}
	report, err := reloaded.CustomerCampaignReport(context.Background())
	if err != nil || len(report.Campaigns) != 2 || report.Campaigns[1].Clicks["ios"] != 2 || report.Campaigns[1].Rewarded != 2 {
		t.Fatalf("reloaded report = %+v, %v", report, err)
	}
}

func TestPostgresStoreCustomerCampaigns(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_customer_campaign_clicks; DELETE FROM relay_customer_campaigns;
		DELETE FROM relay_customer_notifications; DELETE FROM relay_customer_credit_entries;
		DELETE FROM relay_customer_orders; DELETE FROM relay_customer_sessions; DELETE FROM relay_customer_otps;
		DELETE FROM relay_customers`); err != nil {
		t.Fatal(err)
	}
	clock := &customerClock{now: time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)}
	exerciseCustomerCampaigns(t, &PostgresStore{pool: pool, clock: clock}, clock)
}

func exerciseCustomerCampaigns(t *testing.T, store customerCampaignTestStore, clock *customerClock) {
	ctx := context.Background()
	in30Days := clock.now.Add(30 * 24 * time.Hour)
	billboard, err := store.CreateCustomerCampaign(ctx, CustomerCampaign{
		Code: "lawha1", Name: "لوحة طريق الساحل", DisplayName: "لوحة الساحل", Kind: CampaignKindBillboard,
		Reward: "5", RewardLimit: 2, RewardUntil: &in30Days, CreatedBy: "ops",
	})
	if err != nil || billboard.Code != "LAWHA1" || billboard.Landing != "/" || !billboard.Active || billboard.Reward != "5.000" {
		t.Fatalf("billboard = %+v, %v", billboard, err)
	}
	if _, err := store.CreateCustomerCampaign(ctx, CustomerCampaign{Code: "LAWHA1", Name: "again", Kind: CampaignKindAd}); !errors.Is(err, ErrCustomerCampaignCodeTaken) {
		t.Fatalf("duplicate code: %v", err)
	}
	for _, bad := range []CustomerCampaign{
		{Code: "OK1", Name: "x", Kind: "tv"},
		{Code: "OK2", Name: "x", Kind: CampaignKindAd, Reward: "150"},
		{Code: "OK3", Name: "x", Kind: CampaignKindAd, Reward: "-1"},
		{Code: "OK4", Name: "x", Kind: CampaignKindAd, RewardLimit: -1},
	} {
		if _, err := store.CreateCustomerCampaign(ctx, bad); !errors.Is(err, ErrCustomerCampaignInvalid) {
			t.Fatalf("%+v: %v", bad, err)
		}
	}
	clock.advance(time.Minute)
	creator, err := store.CreateCustomerCampaign(ctx, CustomerCampaign{
		Code: "AHMED", Name: "أحمد على تيك توك", Kind: CampaignKindCreator, Landing: "/brand/pubg",
	})
	if err != nil || creator.Reward != "0.000" || creator.RewardDue(clock.now) {
		t.Fatalf("creator = %+v, %v", creator, err)
	}
	if found, err := store.CustomerCampaignByCode(ctx, " ahmed "); err != nil || found.ID != creator.ID {
		t.Fatalf("by code = %+v, %v", found, err)
	}
	if _, err := store.CustomerCampaignByCode(ctx, "NOPE"); !errors.Is(err, ErrCustomerCampaignNotFound) {
		t.Fatalf("unknown code: %v", err)
	}
	for range 2 {
		if err := store.RecordCustomerCampaignClick(ctx, billboard.ID, "ios"); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.RecordCustomerCampaignClick(ctx, billboard.ID, "android"); err != nil {
		t.Fatal(err)
	}
	if err := store.RecordCustomerCampaignClick(ctx, "missing", "ios"); !errors.Is(err, ErrCustomerCampaignNotFound) {
		t.Fatalf("click on no campaign: %v", err)
	}

	// The first campaign and the first answer stay; the campaign's reward
	// lands once, in the customer's credit.
	buyer, err := adminSignIn(t, store, "218912345678", "111111")
	if err != nil {
		t.Fatal(err)
	}
	got, err := store.AttributeCustomer(ctx, buyer.ID, CustomerAttributionChange{CampaignCode: "lawha1", CampaignVia: "link"})
	if err != nil || !got.Accepted || got.Attribution.CampaignCode != "LAWHA1" || got.Attribution.CampaignVia != "link" ||
		got.Attribution.CampaignAt == nil || got.Attribution.HeardFrom != "" {
		t.Fatalf("first = %+v, %v", got, err)
	}
	if got.Reward == nil || got.Reward.Amount != "5.000" || got.Reward.Kind != CampaignKindBillboard ||
		got.Reward.DisplayName != "لوحة الساحل" || got.Reward.Via != "link" {
		t.Fatalf("reward = %+v", got.Reward)
	}
	got, err = store.AttributeCustomer(ctx, buyer.ID, CustomerAttributionChange{
		CampaignCode: "AHMED", CampaignVia: "code", HeardFrom: "billboard",
	})
	if err != nil || got.Accepted || got.Reward != nil || got.Attribution.CampaignCode != "LAWHA1" || got.Attribution.HeardFrom != "billboard" {
		t.Fatalf("second = %+v, %v", got, err)
	}
	if again, _ := store.AttributeCustomer(ctx, buyer.ID, CustomerAttributionChange{CampaignCode: "LAWHA1"}); again.Reward != nil {
		t.Fatalf("the same campaign paid twice: %+v", again)
	}
	if got, _ := store.AttributeCustomer(ctx, buyer.ID, CustomerAttributionChange{HeardFrom: "friend"}); got.Attribution.HeardFrom != "billboard" {
		t.Fatalf("answer changed: %+v", got)
	}
	if read, err := store.CustomerAttribution(ctx, buyer.ID); err != nil || read.CampaignCode != "LAWHA1" || read.HeardFrom != "billboard" {
		t.Fatalf("read = %+v, %v", read, err)
	}
	if balance, entries, err := store.CustomerCredit(ctx, buyer.ID, 10); err != nil || balance != "5.000" ||
		len(entries) != 1 || entries[0].Kind != CustomerCreditCampaign || entries[0].Note != "LAWHA1" {
		t.Fatalf("credit = %s %+v %v", balance, entries, err)
	}

	// An unknown answer and via are dropped, not stored; no reward, no credit.
	browser, err := adminSignIn(t, store, "218923456789", "222222")
	if err != nil {
		t.Fatal(err)
	}
	got, err = store.AttributeCustomer(ctx, browser.ID, CustomerAttributionChange{
		CampaignCode: "ahmed", CampaignVia: "sms", HeardFrom: "tv",
	})
	if err != nil || !got.Accepted || got.Reward != nil || got.Attribution.CampaignCode != "AHMED" ||
		got.Attribution.CampaignVia != "code" || got.Attribution.HeardFrom != "" {
		t.Fatalf("browser = %+v, %v", got, err)
	}

	// The billboard's second customer is paid; its third is counted but
	// past the limit.
	second, err := adminSignIn(t, store, "218945678901", "444444")
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := store.AttributeCustomer(ctx, second.ID, CustomerAttributionChange{CampaignCode: "LAWHA1"}); got.Reward == nil {
		t.Fatalf("second customer unpaid: %+v", got)
	}
	third, err := adminSignIn(t, store, "218956789012", "555555")
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := store.AttributeCustomer(ctx, third.ID, CustomerAttributionChange{CampaignCode: "LAWHA1"}); !got.Accepted || got.Reward != nil {
		t.Fatalf("past the limit: %+v", got)
	}
	if found, _ := store.CustomerCampaignByCode(ctx, "LAWHA1"); found.Rewarded != 2 || found.RewardDue(clock.now) {
		t.Fatalf("billboard after the limit %+v", found)
	}

	// A reward that has ended pays no one, and the campaign still counts.
	ended := clock.now.Add(-time.Minute)
	reward, unlimited := "3", 0
	if _, err := store.UpdateCustomerCampaign(ctx, creator.ID, CustomerCampaignUpdate{
		Reward: &reward, RewardLimit: &unlimited, RewardUntil: &ended,
	}); err != nil {
		t.Fatal(err)
	}
	late, err := adminSignIn(t, store, "218967890123", "666666")
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := store.AttributeCustomer(ctx, late.ID, CustomerAttributionChange{CampaignCode: "AHMED"}); !got.Accepted || got.Reward != nil {
		t.Fatalf("ended reward: %+v", got)
	}
	updated, err := store.UpdateCustomerCampaign(ctx, creator.ID, CustomerCampaignUpdate{ClearRewardUntil: true})
	if err != nil || updated.RewardUntil != nil || !updated.RewardDue(clock.now) {
		t.Fatalf("reward reopened = %+v, %v", updated, err)
	}

	// A customer past their first week is no campaign's win; their answer
	// still counts.
	old, err := adminSignIn(t, store, "218934567890", "333333")
	if err != nil {
		t.Fatal(err)
	}
	clock.advance(CustomerCampaignNewFor + time.Hour)
	got, err = store.AttributeCustomer(ctx, old.ID, CustomerAttributionChange{CampaignCode: "AHMED", HeardFrom: "friend"})
	if err != nil || got.Accepted || got.Reward != nil || got.Attribution.CampaignCode != "" || got.Attribution.HeardFrom != "friend" {
		t.Fatalf("old = %+v, %v", got, err)
	}
	if _, err := store.AttributeCustomer(ctx, "missing", CustomerAttributionChange{HeardFrom: "friend"}); !errors.Is(err, ErrCustomerNotFound) {
		t.Fatalf("missing customer: %v", err)
	}

	// The billboard's first customer buys: 2 × 10, delivered.
	order, _, err := store.BeginCustomerOrder(ctx, CustomerOrder{
		CustomerID: buyer.ID, IdempotencyKey: "o-1", Channel: "ios", ItemKey: "libyana-10", BrandKey: "libyana",
		Quantity: 2, UnitPrice: "10", Method: "dafa_sadad",
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

	deactivate := false
	name := "لوحة الساحل"
	updated, err = store.UpdateCustomerCampaign(ctx, billboard.ID, CustomerCampaignUpdate{Active: &deactivate, Name: &name})
	if err != nil || updated.Active || updated.Name != name || updated.Code != "LAWHA1" || updated.Rewarded != 2 {
		t.Fatalf("update = %+v, %v", updated, err)
	}
	blank, tooMuch := " ", "101"
	if _, err := store.UpdateCustomerCampaign(ctx, billboard.ID, CustomerCampaignUpdate{Name: &blank}); !errors.Is(err, ErrCustomerCampaignInvalid) {
		t.Fatalf("blank name: %v", err)
	}
	if _, err := store.UpdateCustomerCampaign(ctx, billboard.ID, CustomerCampaignUpdate{Reward: &tooMuch}); !errors.Is(err, ErrCustomerCampaignInvalid) {
		t.Fatalf("reward too large: %v", err)
	}
	if _, err := store.UpdateCustomerCampaign(ctx, "missing", CustomerCampaignUpdate{Active: &deactivate}); !errors.Is(err, ErrCustomerCampaignNotFound) {
		t.Fatalf("missing campaign: %v", err)
	}

	report, err := store.CustomerCampaignReport(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Campaigns) != 2 || report.Campaigns[0].Code != "AHMED" || report.Campaigns[1].Code != "LAWHA1" {
		t.Fatalf("campaigns newest first: %+v", report.Campaigns)
	}
	board, ahmed := report.Campaigns[1], report.Campaigns[0]
	if board.Clicks["ios"] != 2 || board.Clicks["android"] != 1 || board.Customers != 3 || board.Buyers != 1 ||
		board.Spent != "20.000" || board.Active || board.Rewarded != 2 || board.RewardsGiven != "10.000" {
		t.Fatalf("billboard stats %+v", board)
	}
	if ahmed.Customers != 2 || ahmed.Buyers != 0 || ahmed.Spent != "0.000" || len(ahmed.Clicks) != 0 ||
		ahmed.Rewarded != 0 || ahmed.RewardsGiven != "0.000" {
		t.Fatalf("creator stats %+v", ahmed)
	}
	if report.NoCampaign.Customers != 1 || report.Unanswered.Customers != 4 {
		t.Fatalf("no campaign %+v, unanswered %+v", report.NoCampaign, report.Unanswered)
	}
	answers := map[string]CustomerHeardFromStats{}
	for _, answer := range report.HeardFrom {
		answers[answer.Answer] = answer
	}
	if len(report.HeardFrom) != len(CustomerHeardFromAnswers) || answers["billboard"].Buyers != 1 ||
		answers["billboard"].Spent != "20.000" || answers["friend"].Customers != 1 || answers["tiktok"].Customers != 0 {
		t.Fatalf("heard from %+v", report.HeardFrom)
	}
}

// Credit that exactly covers an order pays it alone: nothing goes to Dafa,
// so no gateway fee. Credit short of it leaves the fee on the rest only.
func TestCreditCoveringTheOrderPaysNoGatewayFee(t *testing.T) {
	now := time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)
	order := CustomerOrder{ID: "o-1", CustomerID: "c-1", Method: "dafa_sadad", FeePercent: "2"}
	ten := big.NewRat(10, 1)

	placed, spent := placeCustomerOrder(order, ten, big.NewRat(10, 1), true, now)
	if placed.AmountDue != "0.000" || placed.Fee != "0.000" || placed.Status != CustomerOrderPaid ||
		placed.Method != "" || CustomerOrderCharge(placed) != "0.000" || spent == nil || spent.Amount != "-10.000" {
		t.Fatalf("exactly covered: %+v %+v", placed, spent)
	}

	placed, _ = placeCustomerOrder(order, ten, big.NewRat(4, 1), true, now)
	if placed.AmountDue != "6.000" || placed.Fee != "0.130" || placed.Status != CustomerOrderAwaitingPayment ||
		CustomerOrderCharge(placed) != "6.130" {
		t.Fatalf("partly covered: %+v", placed)
	}
}
