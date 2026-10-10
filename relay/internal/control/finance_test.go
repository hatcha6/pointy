package control

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func financeEntry(direction, category, amount, day, key string) FinanceEntry {
	return FinanceEntry{
		Direction:      direction,
		Category:       category,
		OriginalAmount: amount,
		OccurredOn:     day,
		IdempotencyKey: key,
		Actor:          "Hatem",
	}
}

func TestPrepareFinanceEntryBooksForeignMoneyInDinars(t *testing.T) {
	now := time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)
	entry := financeEntry(FinanceExpense, "hosting", "120", "2026-10-01", "k1")
	entry.Currency, entry.Rate = "usd", "7.25"
	got, err := prepareFinanceEntry(entry, now)
	if err != nil {
		t.Fatal(err)
	}
	if got.Amount != "870.000" || got.Currency != "USD" || got.OriginalAmount != "120.000" || got.Rate != "7.250000" {
		t.Fatalf("booked %+v", got)
	}
	plain, err := prepareFinanceEntry(financeEntry(FinanceIncome, "cash_subscription", "300.5", "2026-10-09", "k2"), now)
	if err != nil || plain.Amount != "300.500" || plain.Rate != "1.000000" || plain.Currency != FinanceCurrency {
		t.Fatalf("dinar entry %+v %v", plain, err)
	}
}

func TestPrepareFinanceEntryRefusesWhatTheBooksCannotHold(t *testing.T) {
	now := time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)
	foreignWithoutRate := financeEntry(FinanceExpense, "hosting", "10", "2026-10-01", "k")
	foreignWithoutRate.Currency = "USD"
	for name, entry := range map[string]FinanceEntry{
		"direction": financeEntry("transfer", "hosting", "10", "2026-10-01", "k"),
		"category":  financeEntry(FinanceExpense, "Hosting Bill", "10", "2026-10-01", "k"),
		"zero":      financeEntry(FinanceExpense, "hosting", "0", "2026-10-01", "k"),
		"negative":  financeEntry(FinanceExpense, "hosting", "-5", "2026-10-01", "k"),
		"fraction":  financeEntry(FinanceExpense, "hosting", "1.2345", "2026-10-01", "k"),
		"date":      financeEntry(FinanceExpense, "hosting", "10", "1/10/2026", "k"),
		"future":    financeEntry(FinanceExpense, "hosting", "10", "2026-10-20", "k"),
		"ancient":   financeEntry(FinanceExpense, "hosting", "10", "2019-12-31", "k"),
		"no key":    financeEntry(FinanceExpense, "hosting", "10", "2026-10-01", ""),
		"no rate":   foreignWithoutRate,
		"bad currency": func() FinanceEntry {
			e := financeEntry(FinanceExpense, "hosting", "10", "2026-10-01", "k")
			e.Currency, e.Rate = "dollars", "7"
			return e
		}(),
	} {
		if _, err := prepareFinanceEntry(entry, now); !errors.Is(err, ErrInvalidFinanceEntry) {
			t.Errorf("%s: accepted (%v)", name, err)
		}
	}
	// Tomorrow is allowed: Libya is ahead of UTC late in the evening.
	if _, err := prepareFinanceEntry(financeEntry(FinanceExpense, "hosting", "10", "2026-10-10", "k"), now); err != nil {
		t.Fatalf("tomorrow refused: %v", err)
	}
}

func TestFileStoreFinanceEntries(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	first, existing, err := store.CreateFinanceEntry(ctx, financeEntry(FinanceExpense, "hosting", "50", "2026-10-02", "a"))
	if err != nil || existing {
		t.Fatalf("create %v %v", existing, err)
	}
	again, existing, err := store.CreateFinanceEntry(ctx, financeEntry(FinanceExpense, "hosting", "999", "2026-10-02", "a"))
	if err != nil || !existing || again.ID != first.ID || again.Amount != "50.000" {
		t.Fatalf("a retried key must return the first entry: %+v %v %v", again, existing, err)
	}
	if _, _, err := store.CreateFinanceEntry(ctx, financeEntry(FinanceIncome, "cash_subscription", "300", "2026-10-05", "b")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.CreateFinanceEntry(ctx, financeEntry(FinanceExpense, "salaries", "1000", "2026-09-30", "c")); err != nil {
		t.Fatal(err)
	}

	october, err := store.ListFinanceEntries(ctx, FinanceEntryFilter{From: "2026-10-01", To: "2026-10-31"})
	if err != nil || len(october) != 2 || october[0].Category != "cash_subscription" {
		t.Fatalf("october newest first: %+v %v", october, err)
	}
	expenses, _ := store.ListFinanceEntries(ctx, FinanceEntryFilter{Direction: FinanceExpense})
	if len(expenses) != 2 {
		t.Fatalf("expenses %+v", expenses)
	}

	if _, err := store.VoidFinanceEntry(ctx, first.ID, "Hatem", ""); !errors.Is(err, ErrInvalidFinanceEntry) {
		t.Fatalf("a void without a reason: %v", err)
	}
	voided, err := store.VoidFinanceEntry(ctx, first.ID, "Hatem", "entered twice")
	if err != nil || voided.VoidedAt == nil || voided.VoidReason != "entered twice" {
		t.Fatalf("void %+v %v", voided, err)
	}
	if _, err := store.VoidFinanceEntry(ctx, first.ID, "Hatem", "again"); !errors.Is(err, ErrFinanceEntryVoided) {
		t.Fatalf("second void %v", err)
	}
	if _, err := store.VoidFinanceEntry(ctx, "fin_missing", "Hatem", "x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing void %v", err)
	}
	live, _ := store.ListFinanceEntries(ctx, FinanceEntryFilter{From: "2026-10-01"})
	all, _ := store.ListFinanceEntries(ctx, FinanceEntryFilter{From: "2026-10-01", IncludeVoided: true})
	if len(live) != 1 || len(all) != 2 {
		t.Fatalf("voided lines leave the books but stay on file: %d %d", len(live), len(all))
	}

	// The books survive a restart.
	reopened, err := NewFileStore(store.path, fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	if kept, _ := reopened.ListFinanceEntries(ctx, FinanceEntryFilter{IncludeVoided: true}); len(kept) != 3 {
		t.Fatalf("reopened %d entries", len(kept))
	}
}

func TestFileStoreFinanceTrackedRollsUpLibyanMonths(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	// 23:30 UTC on 30 September is already October in Tripoli.
	lateSeptemberUTC := time.Date(2026, 9, 30, 23, 30, 0, 0, time.UTC)
	october := time.Date(2026, 10, 3, 9, 0, 0, 0, time.UTC)
	store.data.WalletEntries = map[string]WalletEntry{
		"1": {ID: "1", Kind: WalletEntryCharge, Service: WalletServiceSMS, Amount: "-3.000", CreatedAt: october},
		"2": {ID: "2", Kind: WalletEntryCharge, Service: WalletServiceSMS, Amount: "-1.500", CreatedAt: lateSeptemberUTC},
		"3": {ID: "3", Kind: WalletEntryRefund, Service: WalletServiceSMS, Amount: "0.500", CreatedAt: october},
		"4": {ID: "4", Kind: WalletEntryCharge, Service: WalletServiceAI, Amount: "-50", CreatedAt: october},
		// Test charges, top-up credits and hand adjustments are not revenue.
		"5": {ID: "5", Kind: WalletEntryCharge, Service: WalletServiceAI, Amount: "-50", CreatedAt: october, TestMode: true},
		"6": {ID: "6", Kind: WalletEntryTopUp, Amount: "100", CreatedAt: october},
		"7": {ID: "7", Kind: WalletEntryAdjustment, Service: WalletServiceAI, Amount: "20", CreatedAt: october},
		"8": {ID: "8", Kind: WalletEntryCharge, Service: WalletServiceAI, Amount: "-7", CreatedAt: time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC)},
	}
	sent := october
	store.data.SMSMessages = map[string]SMSMessage{
		"a": {ID: "a", Status: SMSStatusDelivered, Cost: "0.0800", CreatedAt: october, SentAt: &sent},
		"b": {ID: "b", Status: SMSStatusFailed, Cost: "0.0800", CreatedAt: october},
		"c": {ID: "c", Status: SMSStatusSent, Cost: "0.0800", CreatedAt: october, TestMode: true},
	}
	store.data.VoucherPurchases = map[string]VoucherPurchase{
		"p1": {ID: "p1", Status: VoucherPurchaseSucceeded, SupplierCost: "10.5", SupplierCurrency: "usd", CreatedAt: october},
		"p2": {ID: "p2", Status: VoucherPurchaseSucceeded, SupplierCost: "40", SupplierCurrency: "LYD", CreatedAt: october},
		"p3": {ID: "p3", Status: VoucherPurchaseFailed, SupplierCost: "99", SupplierCurrency: "LYD", CreatedAt: october},
	}
	store.data.WalletTopUps = map[string]WalletTopUp{
		"t1": {ID: "t1", Status: WalletTopUpPaid, Method: WalletTopUpMethodBankTransfer, Amount: "200", PaidAt: &october},
		"t2": {ID: "t2", Status: WalletTopUpReview, Method: WalletTopUpMethodBankTransfer, Amount: "500"},
	}

	from := time.Date(2026, 10, 1, 0, 0, 0, 0, financeZone)
	months, err := store.FinanceTracked(ctx, from, from.AddDate(0, 1, 0))
	if err != nil {
		t.Fatal(err)
	}
	if len(months) != 1 || months[0].Month != "2026-10" {
		t.Fatalf("months %+v", months)
	}
	m := months[0]
	if m.Revenue[WalletServiceSMS] != "4.000" || m.Revenue[WalletServiceAI] != "50.000" || len(m.Revenue) != 2 {
		t.Fatalf("revenue %+v", m.Revenue)
	}
	if m.SMSCost != "0.080" {
		t.Fatalf("sms cost %s", m.SMSCost)
	}
	if m.SupplierCost["USD"] != "10.500" || m.SupplierCost["LYD"] != "40.000" {
		t.Fatalf("supplier cost %+v", m.SupplierCost)
	}
	if m.TopUps[WalletTopUpMethodBankTransfer] != "200.000" || len(m.TopUps) != 1 {
		t.Fatalf("top-ups %+v", m.TopUps)
	}
}

// Runs against a real PostgreSQL when POINTY_RELAY_TEST_DATABASE_URL names a
// scratch database (the tables are created by the migrations and emptied).
func TestPostgresStoreFinance(t *testing.T) {
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
	if _, err := pool.Exec(ctx, `DELETE FROM relay_finance_entries`); err != nil {
		t.Fatal(err)
	}
	clock := &fixedClock{now: time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)}
	store := &PostgresStore{pool: pool, clock: clock}

	first, existing, err := store.CreateFinanceEntry(ctx, financeEntry(FinanceExpense, "hosting", "50", "2026-10-02", "pg-a"))
	if err != nil || existing || first.Amount != "50.000" || first.OccurredOn != "2026-10-02" || first.Rate != "1.000000" {
		t.Fatalf("create %+v %v %v", first, existing, err)
	}
	again, existing, err := store.CreateFinanceEntry(ctx, financeEntry(FinanceExpense, "hosting", "999", "2026-10-02", "pg-a"))
	if err != nil || !existing || again.ID != first.ID {
		t.Fatalf("retry %+v %v %v", again, existing, err)
	}
	usd := financeEntry(FinanceExpense, "hosting", "20", "2026-10-03", "pg-b")
	usd.Currency, usd.Rate = "USD", "7.1"
	if got, _, err := store.CreateFinanceEntry(ctx, usd); err != nil || got.Amount != "142.000" || got.Rate != "7.100000" {
		t.Fatalf("usd %+v %v", got, err)
	}
	if _, _, err := store.CreateFinanceEntry(ctx, financeEntry(FinanceIncome, "cash_subscription", "300", "2026-09-30", "pg-c")); err != nil {
		t.Fatal(err)
	}
	october, err := store.ListFinanceEntries(ctx, FinanceEntryFilter{From: "2026-10-01", To: "2026-10-31"})
	if err != nil || len(october) != 2 || october[0].Amount != "142.000" {
		t.Fatalf("october %+v %v", october, err)
	}
	if _, err := store.VoidFinanceEntry(ctx, first.ID, "Hatem", "twice"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.VoidFinanceEntry(ctx, first.ID, "Hatem", "twice"); !errors.Is(err, ErrFinanceEntryVoided) {
		t.Fatalf("second void %v", err)
	}
	if _, err := store.VoidFinanceEntry(ctx, "fin_missing", "Hatem", "x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing %v", err)
	}
	if live, _ := store.ListFinanceEntries(ctx, FinanceEntryFilter{From: "2026-10-01"}); len(live) != 1 {
		t.Fatalf("live %+v", live)
	}

	if _, err := pool.Exec(ctx, `DELETE FROM relay_finance_recurring`); err != nil {
		t.Fatal(err)
	}
	usdRecurring, err := store.CreateFinanceRecurring(ctx, FinanceRecurring{Direction: FinanceExpense, Category: "hosting", Amount: "120", Currency: "USD", Rate: "7.2", DayOfMonth: 3, Mode: FinanceRecurringConfirm, Actor: "Hatem"})
	if err != nil || usdRecurring.Rate != "7.200000" {
		t.Fatalf("recurring %+v %v", usdRecurring, err)
	}
	amount := "130"
	changed, err := store.UpdateFinanceRecurring(ctx, usdRecurring.ID, FinanceRecurringChange{Amount: &amount, Skip: "2026-09"})
	if err != nil || changed.Amount != "130.000" || len(changed.Skipped) != 1 {
		t.Fatalf("update %+v %v", changed, err)
	}
	listed, err := store.ListFinanceRecurring(ctx)
	if err != nil || len(listed) != 1 || listed[0].Skipped[0] != "2026-09" || listed[0].Rate != "7.200000" {
		t.Fatalf("list %+v %v", listed, err)
	}
	monthly := financeEntry(FinanceExpense, "hosting", "130", "2026-10-03", FinanceRecurringKey(usdRecurring.ID, "2026-10"))
	monthly.RecurringID, monthly.RecurringMonth = usdRecurring.ID, "2026-10"
	monthly.Attachments = []WalletReceiptRef{{SHA256: strings.Repeat("d", 64), ContentType: "application/pdf", Name: "inv.pdf", Size: 5}}
	written, _, err := store.CreateFinanceEntry(ctx, monthly)
	if err != nil || len(written.Attachments) != 1 || written.RecurringMonth != "2026-10" {
		t.Fatalf("monthly entry %+v %v", written, err)
	}
	withTwo, err := store.AddFinanceAttachment(ctx, written.ID, WalletReceiptRef{SHA256: strings.Repeat("e", 64), ContentType: "image/png", Size: 3})
	if err != nil || len(withTwo.Attachments) != 2 {
		t.Fatalf("attach %+v %v", withTwo, err)
	}
	if posted, _ := store.FinanceRecurringPosted(ctx); !posted[usdRecurring.ID]["2026-10"] {
		t.Fatalf("posted %v", posted)
	}

	// The roll-up's SQL runs (whatever else this scratch database holds).
	from := time.Date(2026, 10, 1, 0, 0, 0, 0, financeZone)
	if _, err := store.FinanceTracked(ctx, from, from.AddDate(0, 1, 0)); err != nil {
		t.Fatal(err)
	}
}

func TestFinanceRecurringDueMonths(t *testing.T) {
	now := time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)
	r := FinanceRecurring{Active: true, DayOfMonth: 5, StartMonth: "2026-07", Skipped: []string{"2026-08"}}
	posted := map[string]bool{"2026-07": true}
	if got := r.DueMonths(posted, now); len(got) != 2 || got[0] != "2026-09" || got[1] != "2026-10" {
		t.Fatalf("due %v", got)
	}
	// The 20th has not come yet this month.
	r.DayOfMonth = 20
	if got := r.DueMonths(posted, now); len(got) != 1 || got[0] != "2026-09" {
		t.Fatalf("due before the day %v", got)
	}
	r.EndMonth = "2026-08"
	if got := r.DueMonths(posted, now); len(got) != 0 {
		t.Fatalf("ended %v", got)
	}
	r.EndMonth, r.Active = "", false
	if got := r.DueMonths(posted, now); len(got) != 0 {
		t.Fatalf("stopped %v", got)
	}
	// Backfill is bounded.
	old := FinanceRecurring{Active: true, DayOfMonth: 1, StartMonth: "2020-01"}
	if got := old.DueMonths(nil, now); len(got) != maxFinanceBackfillMonths || got[0] != "2024-11" {
		t.Fatalf("backfill %d from %v", len(got), got[0])
	}
}

func TestFileStoreFinanceRecurringAndAttachments(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), fixedClock{now: now})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateFinanceRecurring(ctx, FinanceRecurring{Direction: FinanceExpense, Category: "rent", Amount: "800", DayOfMonth: 31}); !errors.Is(err, ErrInvalidFinanceEntry) {
		t.Fatalf("day 31 accepted: %v", err)
	}
	r, err := store.CreateFinanceRecurring(ctx, FinanceRecurring{Direction: FinanceExpense, Category: "rent", Amount: "800", DayOfMonth: 1, Mode: FinanceRecurringConfirm, Actor: "Hatem"})
	if err != nil || r.StartMonth != "2026-10" || !r.Active || r.Rate != "" {
		t.Fatalf("create %+v %v", r, err)
	}
	month := "2026-10"
	skip := month
	r, err = store.UpdateFinanceRecurring(ctx, r.ID, FinanceRecurringChange{Skip: skip})
	if err != nil || len(r.Skipped) != 1 {
		t.Fatalf("skip %+v %v", r, err)
	}
	stop := false
	r, err = store.UpdateFinanceRecurring(ctx, r.ID, FinanceRecurringChange{Active: &stop, Actor: "Hatem"})
	if err != nil || r.Active || r.StoppedAt == nil || r.StoppedBy != "Hatem" {
		t.Fatalf("stop %+v %v", r, err)
	}

	ref := WalletReceiptRef{SHA256: strings.Repeat("a", 64), ContentType: "image/png", Name: "bill.png", Size: 10}
	entry := financeEntry(FinanceExpense, "rent", "800", "2026-10-01", FinanceRecurringKey(r.ID, month))
	entry.RecurringID, entry.RecurringMonth, entry.Attachments = r.ID, month, []WalletReceiptRef{ref, ref}
	created, _, err := store.CreateFinanceEntry(ctx, entry)
	if err != nil || len(created.Attachments) != 1 {
		t.Fatalf("entry %+v %v", created, err)
	}
	posted, _ := store.FinanceRecurringPosted(ctx)
	if !posted[r.ID][month] {
		t.Fatalf("posted %v", posted)
	}
	second := ref
	second.SHA256 = strings.Repeat("b", 64)
	updated, err := store.AddFinanceAttachment(ctx, created.ID, second)
	if err != nil || len(updated.Attachments) != 2 {
		t.Fatalf("add %+v %v", updated, err)
	}
	if again, _ := store.AddFinanceAttachment(ctx, created.ID, second); len(again.Attachments) != 2 {
		t.Fatal("the same receipt twice")
	}
	bad := ref
	bad.ContentType = "text/html"
	if _, err := store.AddFinanceAttachment(ctx, created.ID, bad); !errors.Is(err, ErrInvalidFinanceEntry) {
		t.Fatalf("html receipt %v", err)
	}
}

func TestFileStoreVoucherOffersRememberTheirLastPriceChange(t *testing.T) {
	ctx := context.Background()
	clock := &fixedClock{now: time.Date(2026, 10, 9, 10, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	read := func(price string) VoucherOffer {
		if err := store.ReplaceVoucherOffers(ctx, "bnplus", []VoucherOffer{{Ref: "1", Name: "Libyana 5", Price: price, Currency: "LYD", InStock: true, SyncedAt: clock.now}}); err != nil {
			t.Fatal(err)
		}
		offers, _ := store.ListVoucherOffers(ctx, "bnplus")
		return offers[0]
	}
	if first := read("4.85"); first.PreviousPrice != "" || first.PriceChangedAt != nil {
		t.Fatalf("a first read has no history: %+v", first)
	}
	if same := read("4.850"); same.PreviousPrice != "" {
		t.Fatalf("4.85 and 4.850 are one price: %+v", same)
	}
	moved := read("4.95")
	if moved.PreviousPrice != "4.850" || moved.PriceChangedAt == nil {
		t.Fatalf("a moved price remembers the old one: %+v", moved)
	}
	if kept := read("4.95"); kept.PreviousPrice != "4.850" || kept.PriceChangedAt == nil {
		t.Fatalf("history is kept until the price moves again: %+v", kept)
	}
}
