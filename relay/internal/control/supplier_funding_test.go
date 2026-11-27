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

type fundingStores interface {
	SupplierFundingStore
	ExchangeRateStore
	ExchangeRateSeriesStore
}

func exerciseSupplierFundingStore(t *testing.T, store fundingStores) {
	t.Helper()
	ctx := context.Background()
	funded := time.Now().UTC().Add(-time.Hour).Truncate(time.Second)

	for _, bad := range []struct {
		f     SupplierFunding
		field string
	}{
		{SupplierFunding{Supplier: "", USD: "1", LYD: "12"}, "supplier"},
		{SupplierFunding{Supplier: "fazer", USD: "0", LYD: "12"}, "usd"},
		{SupplierFunding{Supplier: "fazer", USD: "-5", LYD: "12"}, "usd"},
		{SupplierFunding{Supplier: "fazer", USD: "120", LYD: "12"}, "lyd"}, // 0.1 dinar a dollar: a typo
		{SupplierFunding{Supplier: "fazer", USD: "120", LYD: "1296", Method: "magic"}, "method"},
		{SupplierFunding{Supplier: "fazer", USD: "1", LYD: "12", FundedAt: time.Now().Add(time.Hour)}, "funded_at"},
	} {
		_, err := store.CreateSupplierFunding(ctx, bad.f)
		var problem SupplierFundingProblem
		if !errors.As(err, &problem) || problem.Field != bad.field || !errors.Is(err, ErrInvalidSupplierFunding) {
			t.Fatalf("%+v: want a %s problem, got %v", bad.f, bad.field, err)
		}
	}

	created, err := store.CreateSupplierFunding(ctx, SupplierFunding{
		Supplier: " Fazer ", USD: "120", LYD: "1296.18", Method: "BNPLUS_USDT", Reference: " d2e7121b ",
		MarketRate: "10.05", Note: " بايننس 2×60 ", Actor: "hatem", FundedAt: funded,
	})
	if err != nil {
		t.Fatal(err)
	}
	if created.ID == "" || created.Supplier != "fazer" || created.Method != "bnplus_usdt" || created.USD != "120.0000" ||
		created.LYD != "1296.180" || created.MarketRate != "10.0500" || created.Reference != "d2e7121b" || created.Note != "بايننس 2×60" {
		t.Fatalf("created %+v", created)
	}
	second, err := store.CreateSupplierFunding(ctx, SupplierFunding{Supplier: "reloadly", USD: "50", LYD: "600", FundedAt: funded.Add(time.Minute)})
	if err != nil || second.MarketRate != "" || second.Method != "other" {
		t.Fatalf("second %+v %v", second, err)
	}

	rows, err := store.ListSupplierFundings(ctx)
	if err != nil || len(rows) != 2 || rows[0].ID != second.ID || !rows[1].FundedAt.Equal(funded) {
		t.Fatalf("newest first: %+v %v", rows, err)
	}

	voided, err := store.VoidSupplierFunding(ctx, second.ID, "typed twice", "hatem")
	if err != nil || voided.VoidedAt == nil || voided.VoidReason != "typed twice" || voided.VoidActor != "hatem" {
		t.Fatalf("voided %+v %v", voided, err)
	}
	if _, err := store.VoidSupplierFunding(ctx, second.ID, "again", ""); !errors.Is(err, ErrSupplierFundingVoided) {
		t.Fatalf("void twice: %v", err)
	}
	if _, err := store.VoidSupplierFunding(ctx, "nope", "x", ""); !errors.Is(err, ErrSupplierFundingNotFound) {
		t.Fatalf("void unknown: %v", err)
	}
	if rows, _ := store.ListSupplierFundings(ctx); len(rows) != 2 || rows[0].VoidedAt == nil {
		t.Fatalf("a voided row stays listed: %+v", rows)
	}

	// The series: one instrument and bank, oldest first, from since.
	base := time.Now().UTC().Add(-48 * time.Hour).Truncate(time.Second)
	for i, r := range []ExchangeRate{
		{FromCode: "USD", ToCode: "LYD", Instrument: "bank", BankCode: "nab", Rate: "11.40", EffectiveAt: base},
		{FromCode: "USD", ToCode: "LYD", Instrument: "bank", BankCode: "nab", Rate: "11.61", EffectiveAt: base.Add(24 * time.Hour)},
		{FromCode: "USD", ToCode: "LYD", Instrument: "bank", BankCode: "other", Rate: "11.90", EffectiveAt: base.Add(time.Hour)},
		{FromCode: "USD", ToCode: "LYD", Instrument: "cash", Rate: "11.42", EffectiveAt: base.Add(time.Hour)},
		{FromCode: "EUR", ToCode: "LYD", Instrument: "bank", BankCode: "nab", Rate: "13.1", EffectiveAt: base.Add(time.Hour)},
		{FromCode: "USD", ToCode: "LYD", Instrument: "bank", BankCode: "nab", Rate: "10.00", EffectiveAt: base.Add(-30 * 24 * time.Hour)},
	} {
		r.Source = "test"
		if _, err := store.UpsertExchangeRate(ctx, r); err != nil {
			t.Fatalf("rate %d: %v", i, err)
		}
	}
	series, err := store.ListExchangeRateSeries(ctx, "USD", "LYD", "bank", "nab", base.Add(-time.Hour))
	same := func(a, b string) bool {
		x, _ := new(big.Rat).SetString(a)
		y, _ := new(big.Rat).SetString(b)
		return x != nil && y != nil && x.Cmp(y) == 0
	}
	if err != nil || len(series) != 2 || !same(series[0].Rate, "11.40") || !same(series[1].Rate, "11.61") {
		t.Fatalf("series %+v %v", series, err)
	}
}

func TestFileStoreSupplierFundings(t *testing.T) {
	store, err := NewFileStore(filepath.Join(t.TempDir(), "relay.json"), nil)
	if err != nil {
		t.Fatal(err)
	}
	exerciseSupplierFundingStore(t, store)
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// throwaway database.
func TestPostgresStoreSupplierFundings(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_supplier_fundings; DELETE FROM relay_exchange_rates WHERE source = 'test'`); err != nil {
		t.Fatal(err)
	}
	exerciseSupplierFundingStore(t, &PostgresStore{pool: pool, clock: RealClock{}})
}
