package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pointy/relay/internal/bnplus"
	"pointy/relay/internal/control"
	relayserver "pointy/relay/internal/relay"
	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
)

func TestBuildReloadlyConfig(t *testing.T) {
	if config, warnings := buildReloadlyConfig(voucherSettings{}); config.ClientID != "" || len(warnings) != 0 {
		t.Fatalf("nothing set: %+v %v", config, warnings)
	}
	for _, partial := range []voucherSettings{
		{ReloadlyClientID: "id"},
		{ReloadlyClientSecret: "s3cret-value"},
		{ReloadlyClientID: "  ", ReloadlyClientSecret: "s3cret-value"},
	} {
		config, warnings := buildReloadlyConfig(partial)
		if config.ClientID != "" || config.ClientSecret != "" || len(warnings) != 1 || !strings.Contains(warnings[0], "part of its credentials") {
			t.Fatalf("half a set warns and stays off: %+v %v", config, warnings)
		}
		if strings.Contains(warnings[0], "s3cret-value") {
			t.Fatalf("a secret must never reach a log line: %v", warnings)
		}
	}

	config, warnings := buildReloadlyConfig(voucherSettings{ReloadlyClientID: " id ", ReloadlyClientSecret: " secret "})
	if config.ClientID != "id" || config.ClientSecret != "secret" || config.Sandbox || len(warnings) != 0 ||
		config.PurchaseTimeout != 45*time.Second {
		t.Fatalf("a full set: %+v %v", config, warnings)
	}
	config, warnings = buildReloadlyConfig(voucherSettings{
		ReloadlyClientID: "id", ReloadlyClientSecret: "secret", ReloadlySandbox: true, ReloadlyTimeout: 2 * time.Minute,
	})
	if !config.Sandbox || config.PurchaseTimeout != 2*time.Minute || len(warnings) != 1 ||
		!strings.Contains(warnings[0], "SANDBOX") || strings.Contains(warnings[0], "secret") {
		t.Fatalf("the sandbox is announced loudly: %+v %v", config, warnings)
	}
}

func TestAttachReloadlySupplier(t *testing.T) {
	config, _, _, err := buildVoucherConfig(voucherSettings{RateLimit: "30/minute", BNPlusEmail: "ops@example.ly", BNPlusPassword: "p", BNPlusToken: "t"})
	if err != nil {
		t.Fatal(err)
	}
	attachVoucherSuppliers(&config, bnplusCredentialsFor(), http.DefaultClient)

	// Without credentials nothing changes.
	if err := attachReloadlySupplier(&config, reloadly.Config{}, http.DefaultClient); err != nil || config.Reloadly != nil ||
		config.Suppliers[vouchers.SupplierReloadly] != nil {
		t.Fatalf("not configured: %+v %v", config, err)
	}
	before := config.RequestTimeout

	credentials, _ := buildReloadlyConfig(voucherSettings{
		ReloadlyClientID: "id", ReloadlyClientSecret: "secret", ReloadlySandbox: true, ReloadlyTimeout: 2 * time.Minute,
	})
	if err := attachReloadlySupplier(&config, credentials, http.DefaultClient); err != nil {
		t.Fatal(err)
	}
	if config.Reloadly == nil || !config.Reloadly.Sandbox() {
		t.Fatalf("the client is kept for the operator's reads and for services: %+v", config.Reloadly)
	}
	supplier, ok := config.Suppliers[vouchers.SupplierReloadly]
	if !ok || supplier.Key() != vouchers.SupplierReloadly {
		t.Fatalf("Reloadly is a card supplier: %+v", config.Suppliers)
	}
	if _, ok := supplier.(vouchers.RefFinder); !ok {
		t.Fatal("the reconciler needs the exact lookup")
	}
	if _, ok := config.Suppliers[vouchers.SupplierBNPlus]; !ok {
		t.Fatal("BN Plus stays")
	}
	if config.RequestTimeout != 2*time.Minute || config.RequestTimeout <= before {
		t.Fatalf("a call may take as long as Reloadly's purchase does: %v (was %v)", config.RequestTimeout, before)
	}
	if !config.Configured() {
		t.Fatal("configured")
	}

	// Only Reloadly configured is a shop too.
	only := relayserver.VoucherConfig{}
	if err := attachReloadlySupplier(&only, credentials, http.DefaultClient); err != nil || !only.Configured() {
		t.Fatalf("Reloadly alone: %+v %v", only, err)
	}
}

func bnplusCredentialsFor() bnplus.Config {
	_, credentials, _, _ := buildVoucherConfig(voucherSettings{RateLimit: "30/minute", BNPlusEmail: "ops@example.ly", BNPlusPassword: "p", BNPlusToken: "t"})
	return credentials
}

func TestReloadlyStartupModeShoutsTheSandbox(t *testing.T) {
	if reloadlyStartupMode(nil) != "off" {
		t.Fatal("off")
	}
	live, _ := reloadly.New(reloadly.Config{ClientID: "i", ClientSecret: "s"})
	sandbox, _ := reloadly.New(reloadly.Config{ClientID: "i", ClientSecret: "s", Sandbox: true})
	if reloadlyStartupMode(live) != "live" || !strings.Contains(reloadlyStartupMode(sandbox), "SANDBOX") {
		t.Fatalf("%q %q", reloadlyStartupMode(live), reloadlyStartupMode(sandbox))
	}
}

func TestDescribeOfferSyncNamesEverySupplier(t *testing.T) {
	cases := map[string]string{
		`{"synced": {"reloadly": 38, "bnplus": 451}}`: "bnplus 451 offers, reloadly 38 offers",
		`{"synced": {}}`: "no supplier is configured on this relay",
		`not json`:       "not json",
	}
	for in, want := range cases {
		if got := describeOfferSync([]byte(in)); got != want {
			t.Errorf("%s: %q, want %q", in, got, want)
		}
	}
}

// stubSupplier is a supplier the relay can be configured with, answering nothing.
type stubSupplier struct{ key string }

func (s stubSupplier) Key() string { return s.key }
func (s stubSupplier) Buy(context.Context, vouchers.Ref, int, string) (vouchers.Purchase, error) {
	return vouchers.Purchase{}, errors.New("not for sale in this test")
}
func (s stubSupplier) Lookup(context.Context, vouchers.Ref, string) (vouchers.Purchase, error) {
	return vouchers.Purchase{}, errors.New("no orders")
}
func (s stubSupplier) Find(context.Context, vouchers.Ref, int, time.Time, time.Time) ([]vouchers.Purchase, error) {
	return nil, nil
}
func (s stubSupplier) Offers(context.Context) ([]vouchers.Offer, error) { return nil, nil }

// compareRelay is a real relay with two suppliers and a catalog of cards some of
// which list both, with the offers and the dollar rate already stored.
func compareRelay(t *testing.T) *control.FileStore {
	t.Helper()
	store, err := control.NewFileStore(filepath.Join(t.TempDir(), "installations.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	relay := httptest.NewServer(relayserver.HTTPServer{
		Store:      store,
		Hub:        relayserver.NewHub(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		AdminToken: "admin-token",
		Vouchers: relayserver.VoucherConfig{Suppliers: map[string]vouchers.Supplier{
			vouchers.SupplierBNPlus:   stubSupplier{vouchers.SupplierBNPlus},
			vouchers.SupplierReloadly: stubSupplier{vouchers.SupplierReloadly},
		}},
		VoucherCache:         &relayserver.VoucherCatalogCache{},
		VoucherSettingsCache: &relayserver.VoucherSettingsCache{},
	})
	t.Cleanup(relay.Close)
	t.Setenv("POINTY_RELAY_CONTROL_URL", relay.URL)
	t.Setenv("POINTY_RELAY_ADMIN_TOKEN", "admin-token")
	t.Setenv("POINTY_RELAY_ALLOW_INSECURE_CONTROL", "true")

	document, err := vouchers.ParseDocument([]byte(`{
	  "categories": [{"key": "gaming", "name": "ألعاب"}],
	  "brands": [
	    {"key": "psn", "name": "بلايستيشن", "category": "gaming", "logo": {}, "items": [
	      {"key": "psn-20", "face_value": "20", "face_currency": "USD", "price": "110.00", "retail_price": "120.00",
	       "suppliers": [{"key": "bnplus", "card_id": 1}, {"key": "reloadly", "product_id": 9, "amount": "20"}]},
	      {"key": "psn-50", "face_value": "50", "face_currency": "USD", "price": "260.00", "retail_price": "280.00",
	       "suppliers": [{"key": "bnplus", "card_id": 2}, {"key": "reloadly", "product_id": 9, "amount": "50"}]},
	      {"key": "psn-5", "face_value": "5", "face_currency": "USD", "price": "30.00", "retail_price": "33.00",
	       "supplier": {"key": "bnplus", "card_id": 3}}
	    ]},
	    {"key": "xbox", "name": "إكس بوكس", "category": "gaming", "logo": {}, "items": [
	      {"key": "xbox-10", "face_value": "10", "face_currency": "USD", "price": "70.00", "retail_price": "75.00",
	       "suppliers": [{"key": "reloadly", "product_id": 7, "amount": "10"}, {"key": "bnplus", "card_id": 4}]}
	    ]}
	  ]}`))
	if err != nil {
		t.Fatal(err)
	}
	if problems := vouchers.Validate(document, vouchers.ValidateOptions{}); len(problems) > 0 {
		t.Fatal(problems)
	}
	raw, sum, err := vouchers.Encode(vouchers.Normalize(document))
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err := store.PublishVoucherCatalog(ctx, control.VoucherCatalog{SHA256: sum, Document: raw, Actor: "test"}); err != nil {
		t.Fatal(err)
	}
	settings := vouchers.DefaultSettings()
	settings.USDRate = "10"
	settingsRaw, settingsSum, _ := vouchers.EncodeSettings(settings)
	if _, err := store.PublishVoucherSettings(ctx, control.VoucherSettingsRecord{SHA256: settingsSum, Document: settingsRaw}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if err := store.ReplaceVoucherOffers(ctx, vouchers.SupplierBNPlus, []control.VoucherOffer{
		{Ref: "1", Name: "PS 20", Price: "104.50", Currency: "LYD", InStock: true, SyncedAt: now},
		{Ref: "2", Name: "PS 50", Price: "250.00", Currency: "LYD", InStock: true, SyncedAt: now},
		{Ref: "3", Name: "PS 5", Price: "28.00", Currency: "LYD", InStock: true, SyncedAt: now},
		{Ref: "4", Name: "Xbox 10", Price: "60.00", Currency: "LYD", InStock: false, SyncedAt: now},
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.ReplaceVoucherOffers(ctx, vouchers.SupplierReloadly, []control.VoucherOffer{
		{Ref: "9/20", Name: "PlayStation US", Price: "10.30", Currency: "USD", InStock: true, SyncedAt: now},
		{Ref: "9/50", Name: "PlayStation US", Price: "26.00", Currency: "USD", InStock: true, SyncedAt: now},
		{Ref: "7/10", Name: "Xbox US", Price: "5.50", Currency: "USD", InStock: true, SyncedAt: now},
	}); err != nil {
		t.Fatal(err)
	}
	return store
}

func TestCompareLaysOutEveryItemWithSeveralSuppliers(t *testing.T) {
	compareRelay(t)
	out, err := captureStdout(t, func() error { return runVoucherCompare(nil) })
	if err != nil {
		t.Fatalf("compare: %v\n%s", err, out)
	}
	for _, want := range []string{
		"1 USD = 10 LYD", "psn-20", "psn-50", "xbox-10",
		"BNPLUS", "RELOADLY", "BUY FROM", "SAVING", "SHOP PAYS", "MARGIN",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("the table should show %q:\n%s", want, out)
		}
	}
	lines := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		if fields := strings.Fields(line); len(fields) > 0 {
			lines[fields[0]] = line
		}
	}
	if strings.Contains(out, "psn-5 ") || strings.Contains(out, "psn-5\t") {
		t.Fatalf("an item with one supplier is not compared:\n%s", out)
	}
	// psn-20: BN Plus 104.50, Reloadly 103.00 -> Reloadly wins by 1.50 (1.4 %),
	// the shop pays 110.00, margin 7.00 on 103.00.
	for _, want := range []string{"104.50", "103.00", "reloadly", "1.50 (1.4 %)", "110.00", "+7.00 (6.8 %)"} {
		if !strings.Contains(lines["psn-20"], want) {
			t.Errorf("psn-20 should show %q:\n%s", want, lines["psn-20"])
		}
	}
	// psn-50: BN Plus 250.00, Reloadly 260.00 -> BN Plus wins by 10.00.
	for _, want := range []string{"250.00", "260.00", "bnplus", "10.00 (3.8 %)", "260.00", "+10.00 (4.0 %)"} {
		if !strings.Contains(lines["psn-50"], want) {
			t.Errorf("psn-50 should show %q:\n%s", want, lines["psn-50"])
		}
	}
	// xbox-10: BN Plus is out of stock; Reloadly 55.00 is the only choice.
	if !strings.Contains(lines["xbox-10"], "60.00 !") || !strings.Contains(lines["xbox-10"], "55.00") || !strings.Contains(lines["xbox-10"], "reloadly") {
		t.Errorf("xbox-10:\n%s", lines["xbox-10"])
	}
	for _, want := range []string{
		"! = that supplier cannot sell the card now:",
		"bnplus: the supplier is out of stock (1: xbox-10)",
		"3 items list two or more suppliers.",
		"bnplus is bought from first on 1",
		"reloadly is bought from first on 2, saving a median of 1.50 LYD (1.4 %) a card against the next supplier (1.50 LYD in all, one of each)",
		"1 have only one supplier able to sell them now",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("the totals should say %q:\n%s", want, out)
		}
	}

	// One brand only.
	out, err = captureStdout(t, func() error { return runVoucherCompare([]string{"--brand", "xbox"}) })
	if err != nil || strings.Contains(out, "psn-20") || !strings.Contains(out, "xbox-10") || !strings.Contains(out, "1 items list two or more suppliers.") {
		t.Fatalf("--brand: %v\n%s", err, out)
	}
	out, err = captureStdout(t, func() error { return runVoucherCompare([]string{"--brand", "nope"}) })
	if err != nil || !strings.Contains(out, "No catalog item lists two or more suppliers") {
		t.Fatalf("an unknown brand: %v\n%s", err, out)
	}
}

func TestCompareSaysWhenTheDollarRateIsMissing(t *testing.T) {
	store := compareRelay(t)
	settings := vouchers.DefaultSettings()
	raw, sum, _ := vouchers.EncodeSettings(settings)
	if _, err := store.PublishVoucherSettings(context.Background(), control.VoucherSettingsRecord{SHA256: sum, Document: raw}); err != nil {
		t.Fatal(err)
	}
	out, err := captureStdout(t, func() error { return runVoucherCompare(nil) })
	if err != nil || !strings.Contains(out, "usd_rate is NOT SET") || !strings.Contains(out, "rate_unset") {
		t.Fatalf("%v\n%s", err, out)
	}
}

func TestCatalogShowAndOffersListBothSuppliers(t *testing.T) {
	compareRelay(t)
	out, err := captureStdout(t, func() error { return runVoucherCatalogShow(nil) })
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "bnplus:1 | reloadly:9/20") || !strings.Contains(out, "104.50 LYD | 10.30 USD = 103.00 LYD") {
		t.Fatalf("catalog show lists every supplier of an item:\n%s", out)
	}
	if !strings.Contains(out, "bnplus:3") {
		t.Fatalf("a single supplier reads as it always did:\n%s", out)
	}
	out, err = captureStdout(t, func() error { return runVoucherOffers(nil) })
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"IN LYD", "reloadly", "bnplus", "9/20", "10.30 USD", "103.00", "104.50 LYD", "OUT"} {
		if !strings.Contains(out, want) {
			t.Errorf("offers should show %q:\n%s", want, out)
		}
	}
	if out, err = captureStdout(t, func() error { return runVoucherOffers([]string{"--supplier", "reloadly"}) }); err != nil ||
		strings.Contains(out, "bnplus") || !strings.Contains(out, "reloadly") {
		t.Fatalf("--supplier reloadly: %v\n%s", err, out)
	}
}

func TestReloadlyBalanceSaysWhenItIsNotConfigured(t *testing.T) {
	compareRelay(t)
	_, err := captureStdout(t, func() error { return runVoucherReloadlyBalance(nil) })
	if err == nil || !strings.Contains(err.Error(), "Reloadly is not configured on this relay") || !strings.Contains(err.Error(), "POINTY_RELAY_RELOADLY_CLIENT_ID") {
		t.Fatalf("a clear message: %v", err)
	}
	if err := runVoucherReloadly(nil); err == nil {
		t.Fatal("a command is required")
	}
	if err := runVoucherReloadly([]string{"nope"}); err == nil {
		t.Fatal("an unknown command is refused")
	}
}

func TestRenderComparisonWithoutItemsAndHelpers(t *testing.T) {
	var out bytes.Buffer
	renderVoucherComparison(&out, voucherComparison{}, nil)
	if !strings.Contains(out.String(), "No catalog item lists two or more suppliers") {
		t.Fatalf("%q", out.String())
	}
	if median(nil) != nil || dinars(nil) != "-" || signedDinars(nil) != "-" || percent(nil) != "" {
		t.Fatal("empty values")
	}
	one, two, three := ratFrom("1"), ratFrom("2"), ratFrom("4")
	if median([]*big.Rat{three, one, two}).FloatString(1) != "2.0" || median([]*big.Rat{one, three}).FloatString(1) != "2.5" {
		t.Fatal("medians")
	}
	if ratFrom("nope") != nil || ratFrom("") != nil {
		t.Fatal("unreadable numbers are nil")
	}
	if trimDinars("103.0000") != "103.00" || trimDinars("x") != "x" {
		t.Fatal("trimDinars")
	}
}

func TestCompareFlagsAnItemSoldBelowItsCost(t *testing.T) {
	var response voucherAdminCatalog
	err := json.Unmarshal([]byte(`{
	  "catalog": {"id": "c"},
	  "view": {"brands": [{"key": "psn", "items": [{"key": "psn-20", "unit_price": "100.00"}]}]},
	  "supply": [{"item": "psn-20", "brand": "psn", "name": "PlayStation 20", "suppliers": [
	    {"supplier": "bnplus", "ref": "1", "cost_lyd": "104.5000", "candidate": true, "rank": 2},
	    {"supplier": "reloadly", "ref": "9/20", "cost_lyd": "103.0000", "candidate": true, "rank": 1}
	  ]}]}`), &response)
	if err != nil {
		t.Fatal(err)
	}
	comparison := compareSuppliers(response, "")
	if len(comparison.Items) != 1 || comparison.BelowCost != 1 || comparison.Items[0].Margin.FloatString(2) != "-3.00" {
		t.Fatalf("%+v", comparison)
	}
	var out bytes.Buffer
	renderVoucherComparison(&out, comparison, nil)
	for _, want := range []string{"-3.00 (-2.9 %) LOSS", "1 sell below the cost of the supplier they are bought from (LOSS): reprice them."} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("should say %q:\n%s", want, out.String())
		}
	}
}
