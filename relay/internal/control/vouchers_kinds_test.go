package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// steppingClock moves one second on every reading, so versions published in a
// row have different times — "the newest is current" is only decidable then.
type steppingClock struct {
	mu   sync.Mutex
	next time.Time
}

func (c *steppingClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.next
	c.next = c.next.Add(time.Second)
	return now
}

const (
	cardRefundText      = "استرداد كرت لم يُصدر: "
	operationRefundText = "استرداد عملية لم تُنفَّذ: "
)

func kindsPurchase(installationID, key, kind string) VoucherPurchase {
	return VoucherPurchase{
		InstallationID: installationID,
		IdempotencyKey: key,
		Kind:           kind,
		ItemKey:        "itunes-us-10",
		BrandKey:       "itunes",
		ItemName:       "آيتونز · الولايات المتحدة · 10 دولار",
		Quantity:       1,
		UnitPrice:      "1.00",
		Supplier:       "bnplus",
		SupplierRef:    "101",
		RequestedBy:    "cashier",
	}
}

// sameJSON reports whether got is the JSON document want says, whatever the
// spacing and key order (Postgres stores jsonb, which reorders both).
func sameJSON(t *testing.T, got json.RawMessage, want string) bool {
	t.Helper()
	var a, b any
	if err := json.Unmarshal(got, &a); err != nil {
		t.Errorf("%q is not JSON: %v", got, err)
		return false
	}
	if err := json.Unmarshal([]byte(want), &b); err != nil {
		t.Fatalf("test JSON %q: %v", want, err)
	}
	return reflect.DeepEqual(a, b)
}

// voucherKindsHooks reach behind the store for the states only a crash or the
// previous release can leave.
type voucherKindsHooks struct {
	// forceOrder gives a purchase a supplier order without touching its status.
	forceOrder func(t *testing.T, id, order string)
}

// voucherKindsContract covers what the services added to the card ledger: the
// kind of a purchase, its masked target and its details, the kind-aware
// statement, the listing by kind, and re-pointing a pending purchase at another
// supplier.
func voucherKindsContract(t *testing.T, store voucherStoreUnderTest, installationID string, hooks voucherKindsHooks) {
	t.Helper()
	ctx := context.Background()
	balance := func() string {
		t.Helper()
		wallet, err := store.GetWalletAccount(ctx, installationID, WalletAccountVouchers)
		if err != nil {
			t.Fatal(err)
		}
		return wallet.Balance
	}
	if _, _, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: installationID, Kind: WalletEntryAdjustment, Amount: "500", IdempotencyKey: "kinds-fund",
	}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.TransferWalletFunds(ctx, WalletTransfer{
		InstallationID: installationID, From: WalletAccountMain, To: WalletAccountVouchers, Amount: "300", IdempotencyKey: "kinds-fill",
	}); err != nil {
		t.Fatal(err)
	}
	taken := 0 // dinars (each purchase here costs one) taken from the balance so far
	expectBalance := func(context string) {
		t.Helper()
		if want, got := fmt.Sprintf("%d.000", 300-taken), balance(); got != want {
			t.Fatalf("%s: balance = %s, want %s", context, got, want)
		}
	}
	expectBalance("funded")

	// An empty kind is a card, on write and on read.
	card, created, err := store.BeginVoucherPurchase(ctx, kindsPurchase(installationID, "k-card", ""))
	if err != nil || !created {
		t.Fatalf("card: %+v created=%v err=%v", card, created, err)
	}
	taken++
	if card.Kind != VoucherKindCard || card.Target != "" || len(card.Details) != 0 {
		t.Fatalf("an empty kind is a card with no target and no details: %+v", card)
	}
	byKey, found, err := store.FindVoucherPurchaseByKey(ctx, installationID, "k-card")
	if err != nil || !found || byKey.Kind != VoucherKindCard {
		t.Fatalf("by key: %+v found=%v err=%v", byKey, found, err)
	}
	byID, err := store.GetVoucherPurchase(ctx, card.ID)
	if err != nil || byID.Kind != VoucherKindCard {
		t.Fatalf("by id: %+v err=%v", byID, err)
	}

	// Airtime keeps what the services layer put on it. The kind is normalized,
	// the details are compacted, the target is the masked one.
	const airDetails = `{"operator":"Orange Mali","amount":"5000","nested":{"a":[1,2]}}`
	air := kindsPurchase(installationID, "k-air", " Airtime ")
	air.ItemKey = "airtime:289:5000:XOF"
	air.BrandKey = "airtime"
	air.ItemName = "شحن مباشر · Orange Mali · 5,000 XOF"
	air.Supplier = "reloadly"
	air.SupplierRef = "289"
	air.Target = "+223•••••456"
	air.Details = json.RawMessage("{\n  \"operator\": \"Orange Mali\",\n  \"amount\": \"5000\",\n  \"nested\": {\"a\": [1, 2]}\n}")
	airtime, created, err := store.BeginVoucherPurchase(ctx, air)
	if err != nil || !created {
		t.Fatalf("airtime: %+v created=%v err=%v", airtime, created, err)
	}
	taken++
	if airtime.Kind != VoucherKindAirtime || airtime.Target != "+223•••••456" || !sameJSON(t, airtime.Details, airDetails) {
		t.Fatalf("airtime row: %+v", airtime)
	}
	for _, read := range []func() (VoucherPurchase, error){
		func() (VoucherPurchase, error) { return store.GetVoucherPurchase(ctx, airtime.ID) },
		func() (VoucherPurchase, error) {
			row, _, err := store.FindVoucherPurchaseByKey(ctx, installationID, "k-air")
			return row, err
		},
	} {
		row, err := read()
		if err != nil || row.Kind != VoucherKindAirtime || row.Target != "+223•••••456" || !sameJSON(t, row.Details, airDetails) {
			t.Fatalf("read back: %+v err=%v", row, err)
		}
	}
	// A repeated key returns the first claim, with its kind.
	again, created, err := store.BeginVoucherPurchase(ctx, air)
	if err != nil || created || again.ID != airtime.ID || again.Kind != VoucherKindAirtime {
		t.Fatalf("replay: %+v created=%v err=%v", again, created, err)
	}

	bill := kindsPurchase(installationID, "k-bill", VoucherKindBill)
	bill.ItemKey = "bill:5:5000:NGN"
	bill.BrandKey = "bill"
	bill.ItemName = "دفع فاتورة · Ikeja Electricity Prepaid"
	bill.Supplier = "reloadly"
	bill.SupplierRef = "5"
	bill.Target = "0422•••280"
	billing, _, err := store.BeginVoucherPurchase(ctx, bill)
	if err != nil || billing.Kind != VoucherKindBill {
		t.Fatalf("bill: %+v err=%v", billing, err)
	}
	taken++
	if len(billing.Details) != 0 {
		t.Fatalf("a purchase without details has none: %q", billing.Details)
	}
	expectBalance("three purchases")

	// What is refused takes nothing and leaves no row.
	filler := func(size int) string { return `{"k":"` + strings.Repeat("a", size-len(`{"k":""}`)) + `"}` }
	for i, refused := range []struct {
		name   string
		mutate func(*VoucherPurchase)
	}{
		{"an unknown kind", func(p *VoucherPurchase) { p.Kind = "gift" }},
		{"details that are an array", func(p *VoucherPurchase) { p.Details = json.RawMessage(`[1,2]`) }},
		{"details that are a string", func(p *VoucherPurchase) { p.Details = json.RawMessage(`"x"`) }},
		{"details that are a number", func(p *VoucherPurchase) { p.Details = json.RawMessage(`7`) }},
		{"details that are broken JSON", func(p *VoucherPurchase) { p.Details = json.RawMessage(`{"a":`) }},
		{"details with a NUL (jsonb cannot hold one)", func(p *VoucherPurchase) { p.Details = json.RawMessage(`{"a":"x\u0000y"}`) }},
		{"details far over 4 KB", func(p *VoucherPurchase) { p.Details = json.RawMessage(filler(3 * maxVoucherDetailsBytes)) }},
		{"details one byte over 4 KB", func(p *VoucherPurchase) { p.Details = json.RawMessage(filler(maxVoucherDetailsBytes + 1)) }},
	} {
		key := "k-refused-" + strconv.Itoa(i)
		purchase := kindsPurchase(installationID, key, VoucherKindAirtime)
		refused.mutate(&purchase)
		if _, created, err := store.BeginVoucherPurchase(ctx, purchase); err == nil || created {
			t.Fatalf("%s must be refused: created=%v err=%v", refused.name, created, err)
		}
		if _, found, err := store.FindVoucherPurchaseByKey(ctx, installationID, key); err != nil || found {
			t.Fatalf("%s left a row: found=%v err=%v", refused.name, found, err)
		}
	}
	expectBalance("refused purchases take nothing")

	// Details of exactly 4 KB are fine, and so are null, nothing and a bare {}.
	for i, details := range []string{filler(maxVoucherDetailsBytes), `null`, `{}`, ``} {
		purchase := kindsPurchase(installationID, "k-details-"+strconv.Itoa(i), VoucherKindAirtime)
		purchase.Details = json.RawMessage(details)
		stored, _, err := store.BeginVoucherPurchase(ctx, purchase)
		if err != nil {
			t.Fatalf("details %.20q: %v", details, err)
		}
		taken++
		switch details {
		case "null", "":
			if len(stored.Details) != 0 {
				t.Fatalf("no details: %q", stored.Details)
			}
		default:
			if !sameJSON(t, stored.Details, details) {
				t.Fatalf("details %.20q came back as %.40q", details, stored.Details)
			}
		}
	}

	// A target is cut to a short length; it is a mask, not a document.
	long := kindsPurchase(installationID, "k-long-target", VoucherKindBill)
	long.Target = strings.Repeat("•", 300)
	storedLong, _, err := store.BeginVoucherPurchase(ctx, long)
	if err != nil || len([]rune(storedLong.Target)) != maxVoucherKeyRunes {
		t.Fatalf("long target: %d runes err=%v", len([]rune(storedLong.Target)), err)
	}
	taken++
	expectBalance("details, nulls and a long target")

	// The listing narrows by kind; empty lists them all.
	list := func(kind string) []VoucherPurchase {
		t.Helper()
		rows, err := store.ListVoucherPurchases(ctx, VoucherPurchaseFilter{InstallationID: installationID, Kind: kind, Limit: 500})
		if err != nil {
			t.Fatal(err)
		}
		return rows
	}
	all, cards, airtimes, bills := list(""), list("card"), list(" AIRTIME "), list(VoucherKindBill)
	// One card; the airtime and its four details cases; the bill and the long target.
	if len(all) != 8 || len(cards) != 1 || len(airtimes) != 5 || len(bills) != 2 {
		t.Fatalf("by kind: all=%d cards=%d airtime=%d bills=%d", len(all), len(cards), len(airtimes), len(bills))
	}
	if cards[0].Kind != VoucherKindCard || cards[0].ID != card.ID {
		t.Fatalf("card listing: %+v", cards[0])
	}
	for _, row := range airtimes {
		if row.Kind != VoucherKindAirtime {
			t.Fatalf("airtime listing: %+v", row)
		}
	}
	if none := list("nonsense"); len(none) != 0 {
		t.Fatalf("an unknown kind lists nothing: %d", len(none))
	}

	// The statement: a charge names the item; a price coming back says whether
	// a card never came or an operation was never carried out.
	statement := func(reference, kind string) WalletEntry {
		t.Helper()
		entries, err := store.ListWalletEntries(ctx, WalletEntryFilter{InstallationID: installationID, Account: WalletAccountVouchers, Limit: 200})
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			if entry.Reference == reference && entry.Kind == kind {
				return entry
			}
		}
		t.Fatalf("no %s entry for %s in %+v", kind, reference, entries)
		return WalletEntry{}
	}
	if got := statement(airtime.ID, WalletEntryCharge).Description; got != "شحن مباشر · Orange Mali · 5,000 XOF" {
		t.Fatalf("an airtime charge is named by the item: %q", got)
	}
	if _, applied, err := store.FinishVoucherPurchase(ctx, card.ID, VoucherPurchaseOutcome{
		Status: VoucherPurchaseFailed, ErrorCode: "supplier_out_of_stock",
	}); err != nil || !applied {
		t.Fatalf("card refund: applied=%v err=%v", applied, err)
	}
	if got := statement(card.ID, WalletEntryRefund).Description; got != cardRefundText+"آيتونز · الولايات المتحدة · 10 دولار" {
		t.Fatalf("a card that never came: %q", got)
	}
	if _, applied, err := store.FinishVoucherPurchase(ctx, airtime.ID, VoucherPurchaseOutcome{
		Status: VoucherPurchaseFailed, ErrorCode: "supplier_refused",
	}); err != nil || !applied {
		t.Fatalf("airtime refund: applied=%v err=%v", applied, err)
	}
	if got := statement(airtime.ID, WalletEntryRefund).Description; got != operationRefundText+"شحن مباشر · Orange Mali · 5,000 XOF" {
		t.Fatalf("an operation that was never carried out: %q", got)
	}
	// A bill that the supplier's records say never happened.
	if _, applied, err := store.ResolveVoucherPurchase(ctx, billing.ID, VoucherPurchaseResolution{Detail: "not in the history"}); err != nil || !applied {
		t.Fatalf("bill resolution: applied=%v err=%v", applied, err)
	}
	if got := statement(billing.ID, WalletEntryRefund).Description; got != operationRefundText+"دفع فاتورة · Ikeja Electricity Prepaid" {
		t.Fatalf("a bill resolved as never paid: %q", got)
	}
	taken -= 3 // the card, the airtime and the bill came back
	expectBalance("three refunds")
	// A settled row keeps what it was.
	refunded, err := store.GetVoucherPurchase(ctx, airtime.ID)
	if err != nil || refunded.Status != VoucherPurchaseFailed || refunded.Kind != VoucherKindAirtime ||
		refunded.Target != "+223•••••456" || !sameJSON(t, refunded.Details, airDetails) {
		t.Fatalf("a settled row keeps what it was: %+v err=%v", refunded, err)
	}

	// A name too long for the statement still refunds: the wording is cut, the
	// money comes back.
	wordy := kindsPurchase(installationID, "k-wordy", VoucherKindBill)
	wordy.ItemName = strings.Repeat("ب", 600)
	wordyRow, _, err := store.BeginVoucherPurchase(ctx, wordy)
	if err != nil {
		t.Fatal(err)
	}
	if charge := statement(wordyRow.ID, WalletEntryCharge); len([]rune(charge.Description)) > maxWalletTextRunes {
		t.Fatalf("charge description of %d runes", len([]rune(charge.Description)))
	}
	if _, applied, err := store.FinishVoucherPurchase(ctx, wordyRow.ID, VoucherPurchaseOutcome{
		Status: VoucherPurchaseFailed, ErrorCode: "supplier_refused",
	}); err != nil || !applied {
		t.Fatalf("a long name must not stop a refund: applied=%v err=%v", applied, err)
	}
	if refund := statement(wordyRow.ID, WalletEntryRefund); len([]rune(refund.Description)) > maxWalletTextRunes {
		t.Fatalf("refund description of %d runes", len([]rune(refund.Description)))
	}
	expectBalance("the long-named purchase and its refund")

	voucherRedirectContract(t, store, installationID, hooks, balance)
}

// voucherRedirectContract covers RedirectVoucherPurchase: the supplier of a
// purchase can change only while nothing can have been bought.
func voucherRedirectContract(
	t *testing.T,
	store voucherStoreUnderTest,
	installationID string,
	hooks voucherKindsHooks,
	balance func() string,
) {
	t.Helper()
	ctx := context.Background()

	pending, _, err := store.BeginVoucherPurchase(ctx, kindsPurchase(installationID, "r-1", ""))
	if err != nil {
		t.Fatal(err)
	}
	afterClaim := balance()
	redirected, applied, err := store.RedirectVoucherPurchase(ctx, pending.ID, " reloadly ", " 13441/50 ")
	if err != nil || !applied || redirected.Supplier != "reloadly" || redirected.SupplierRef != "13441/50" ||
		redirected.Status != VoucherPurchasePending || redirected.HeldSince != nil || redirected.ID != pending.ID {
		t.Fatalf("redirect: %+v applied=%v err=%v", redirected, applied, err)
	}
	if redirected.UnitPrice != pending.UnitPrice || redirected.Amount != pending.Amount || redirected.Kind != pending.Kind ||
		redirected.ItemKey != pending.ItemKey || redirected.IdempotencyKey != pending.IdempotencyKey {
		t.Fatalf("a redirect changes the supplier only: %+v vs %+v", redirected, pending)
	}
	if redirected.UpdatedAt.Before(pending.UpdatedAt) {
		t.Fatalf("a redirect is an update: %v < %v", redirected.UpdatedAt, pending.UpdatedAt)
	}
	if got := balance(); got != afterClaim {
		t.Fatalf("a redirect moves no money: %s -> %s", afterClaim, got)
	}
	read, err := store.GetVoucherPurchase(ctx, pending.ID)
	if err != nil || read.Supplier != "reloadly" || read.SupplierRef != "13441/50" {
		t.Fatalf("a redirect is stored: %+v err=%v", read, err)
	}
	byKey, _, err := store.FindVoucherPurchaseByKey(ctx, installationID, "r-1")
	if err != nil || byKey.Supplier != "reloadly" {
		t.Fatalf("a redirect is found by key: %+v err=%v", byKey, err)
	}
	// And again: the next supplier can fail definitely too. An empty reference
	// is allowed (the test supplier has none to give).
	if next, applied, err := store.RedirectVoucherPurchase(ctx, pending.ID, "bnplus", ""); err != nil || !applied ||
		next.Supplier != "bnplus" || next.SupplierRef != "" {
		t.Fatalf("second redirect: %+v applied=%v err=%v", next, applied, err)
	}

	// An unknown purchase and a missing supplier are errors, and change nothing.
	if _, _, err := store.RedirectVoucherPurchase(ctx, "nobody", "reloadly", "1"); !errors.Is(err, ErrVoucherPurchaseNotFound) {
		t.Fatalf("unknown id: %v", err)
	}
	if _, applied, err := store.RedirectVoucherPurchase(ctx, pending.ID, "  ", "1"); err == nil || applied {
		t.Fatalf("a redirect needs a supplier: applied=%v err=%v", applied, err)
	}
	if still, _ := store.GetVoucherPurchase(ctx, pending.ID); still.Supplier != "bnplus" || still.SupplierRef != "" {
		t.Fatalf("a refused redirect changed the row: %+v", still)
	}

	untouched := func(name, id string) {
		t.Helper()
		before, err := store.GetVoucherPurchase(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		got, applied, err := store.RedirectVoucherPurchase(ctx, id, "reloadly", "999")
		if err != nil || applied {
			t.Fatalf("%s must not be redirected: applied=%v err=%v", name, applied, err)
		}
		if got.Supplier != before.Supplier || got.SupplierRef != before.SupplierRef || got.Status != before.Status ||
			!got.UpdatedAt.Equal(before.UpdatedAt) {
			t.Fatalf("%s: the row must come back untouched: %+v vs %+v", name, got, before)
		}
		after, _ := store.GetVoucherPurchase(ctx, id)
		if after.Supplier != before.Supplier || after.SupplierRef != before.SupplierRef || !after.UpdatedAt.Equal(before.UpdatedAt) {
			t.Fatalf("%s: the stored row changed: %+v vs %+v", name, after, before)
		}
	}

	// Bought: past the point of redirecting.
	done, _, _ := store.BeginVoucherPurchase(ctx, kindsPurchase(installationID, "r-done", ""))
	if _, applied, err := store.FinishVoucherPurchase(ctx, done.ID, VoucherPurchaseOutcome{
		Status: VoucherPurchaseSucceeded, SupplierOrderID: "ord-redirect-1", SupplierCost: "1", SupplierCurrency: "USD",
	}); err != nil || !applied {
		t.Fatalf("finish: applied=%v err=%v", applied, err)
	}
	untouched("a succeeded purchase", done.ID)

	// Refused for good: the money is back and the row is closed.
	failed, _, _ := store.BeginVoucherPurchase(ctx, kindsPurchase(installationID, "r-failed", ""))
	if _, applied, err := store.FinishVoucherPurchase(ctx, failed.ID, VoucherPurchaseOutcome{
		Status: VoucherPurchaseFailed, ErrorCode: "supplier_out_of_stock",
	}); err != nil || !applied {
		t.Fatalf("finish: applied=%v err=%v", applied, err)
	}
	untouched("a failed purchase", failed.ID)

	// Held: the outcome is being found out, so something may have been bought.
	held, _, _ := store.BeginVoucherPurchase(ctx, kindsPurchase(installationID, "r-held", ""))
	if _, applied, err := store.FinishVoucherPurchase(ctx, held.ID, VoucherPurchaseOutcome{
		Status: VoucherPurchaseFailed, ErrorCode: "supplier_unknown", Uncertain: true,
	}); err != nil || !applied {
		t.Fatalf("finish: applied=%v err=%v", applied, err)
	}
	untouched("a held purchase", held.ID)

	// Pending and not held, but a supplier order exists: it was bought.
	if hooks.forceOrder != nil {
		ordered, _, _ := store.BeginVoucherPurchase(ctx, kindsPurchase(installationID, "r-ordered", ""))
		hooks.forceOrder(t, ordered.ID, "ord-redirect-2")
		untouched("a purchase with a supplier order", ordered.ID)
	}
}

// voucherRedirectRaceContract: a redirect racing the purchase's own outcome is
// either entirely before it (the supplier changed) or entirely after it (the
// row is closed and untouched) — never half of each.
func voucherRedirectRaceContract(t *testing.T, store voucherStoreUnderTest, installationID string) {
	t.Helper()
	ctx := context.Background()
	if _, _, err := store.PostWalletEntry(ctx, WalletPosting{
		InstallationID: installationID, Kind: WalletEntryAdjustment, Amount: "200", IdempotencyKey: "race-fund",
	}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.TransferWalletFunds(ctx, WalletTransfer{
		InstallationID: installationID, From: WalletAccountMain, To: WalletAccountVouchers, Amount: "100", IdempotencyKey: "race-fill",
	}); err != nil {
		t.Fatal(err)
	}
	won, lost := 0, 0
	for i := 0; i < 40; i++ {
		purchase, _, err := store.BeginVoucherPurchase(ctx, kindsPurchase(installationID, "race-"+strconv.Itoa(i), ""))
		if err != nil {
			t.Fatal(err)
		}
		order := "ord-race-" + strconv.Itoa(i)
		var wg sync.WaitGroup
		var redirectApplied, finishApplied bool
		var redirectErr, finishErr error
		start := make(chan struct{})
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			_, redirectApplied, redirectErr = store.RedirectVoucherPurchase(ctx, purchase.ID, "reloadly", "13441/50")
		}()
		go func() {
			defer wg.Done()
			<-start
			_, finishApplied, finishErr = store.FinishVoucherPurchase(ctx, purchase.ID, VoucherPurchaseOutcome{
				Status: VoucherPurchaseSucceeded, SupplierOrderID: order, SupplierCost: "1", SupplierCurrency: "USD",
			})
		}()
		close(start)
		wg.Wait()
		if redirectErr != nil || finishErr != nil {
			t.Fatalf("round %d: redirect=%v finish=%v", i, redirectErr, finishErr)
		}
		if !finishApplied {
			t.Fatalf("round %d: a redirect must never stop the purchase from finishing", i)
		}
		final, err := store.GetVoucherPurchase(ctx, purchase.ID)
		if err != nil {
			t.Fatal(err)
		}
		if final.Status != VoucherPurchaseSucceeded || final.SupplierOrderID != order {
			t.Fatalf("round %d: the outcome is lost: %+v", i, final)
		}
		switch {
		case redirectApplied && final.Supplier == "reloadly" && final.SupplierRef == "13441/50":
			won++
		case !redirectApplied && final.Supplier == "bnplus" && final.SupplierRef == "101":
			lost++
		default:
			t.Fatalf("round %d: redirect applied=%v but the row ends with supplier %s/%s", i, redirectApplied, final.Supplier, final.SupplierRef)
		}
	}
	t.Logf("the redirect came first in %d races and second in %d", won, lost)
}

// voucherSettingsContract runs the settings history against any store. The
// store must read time from a clock that moves on, or "the newest is current"
// cannot be told from "published in the same instant".
func voucherSettingsContract(t *testing.T, store VoucherStore, sha func(string) string) {
	t.Helper()
	ctx := context.Background()
	if existing, err := store.ListVoucherSettings(ctx, 1); err != nil {
		t.Fatal(err)
	} else if len(existing) == 0 {
		if _, err := store.CurrentVoucherSettings(ctx); !errors.Is(err, ErrVoucherSettingsNotFound) {
			t.Fatalf("no settings yet: %v", err)
		}
	}

	first, err := store.PublishVoucherSettings(ctx, VoucherSettingsRecord{
		SHA256: sha("one"), Document: json.RawMessage(`{"usd_rate": "9.71"}`), Actor: " ops ", Note: " first ",
	})
	if err != nil {
		t.Fatal(err)
	}
	if first.ID == "" || first.Actor != "ops" || first.Note != "first" || first.CreatedAt.IsZero() {
		t.Fatalf("published: %+v", first)
	}
	current, err := store.CurrentVoucherSettings(ctx)
	if err != nil || current.ID != first.ID || current.SHA256 != sha("one") || !sameJSON(t, current.Document, `{"usd_rate":"9.71"}`) {
		t.Fatalf("current: %+v err=%v", current, err)
	}

	second, err := store.PublishVoucherSettings(ctx, VoucherSettingsRecord{
		SHA256: sha("two"), Document: json.RawMessage(`{"usd_rate":"9.80","popular":["NE"]}`), Actor: "ops",
	})
	if err != nil {
		t.Fatal(err)
	}
	current, err = store.CurrentVoucherSettings(ctx)
	if err != nil || current.ID != second.ID || !sameJSON(t, current.Document, `{"usd_rate":"9.80","popular":["NE"]}`) {
		t.Fatalf("the newest version is current: %+v err=%v", current, err)
	}

	// The history is append-only, newest first, and carries no documents.
	history, err := store.ListVoucherSettings(ctx, 50)
	if err != nil || len(history) < 2 {
		t.Fatalf("history: %+v err=%v", history, err)
	}
	if history[0].ID != second.ID || history[1].ID != first.ID {
		t.Fatalf("newest first: %s then %s, want %s then %s", history[0].ID, history[1].ID, second.ID, first.ID)
	}
	for _, record := range history {
		if len(record.Document) != 0 {
			t.Fatalf("the history carries no documents: %+v", record)
		}
	}
	if limited, err := store.ListVoucherSettings(ctx, 1); err != nil || len(limited) != 1 || limited[0].ID != second.ID {
		t.Fatalf("limit: %+v err=%v", limited, err)
	}

	// Publishing an old document again makes it current again (a rollback), as
	// a version of its own.
	rollback, err := store.PublishVoucherSettings(ctx, VoucherSettingsRecord{
		SHA256: sha("one"), Document: json.RawMessage(`{"usd_rate":"9.71"}`), Note: "rolled back",
	})
	if err != nil || rollback.ID == first.ID {
		t.Fatalf("a rollback is a new version: %+v err=%v", rollback, err)
	}
	if current, _ = store.CurrentVoucherSettings(ctx); current.ID != rollback.ID || current.Note != "rolled back" {
		t.Fatalf("after a rollback: %+v", current)
	}

	// What cannot be a settings document is refused, and changes nothing.
	for name, record := range map[string]VoucherSettingsRecord{
		"no document":         {SHA256: sha("x")},
		"no fingerprint":      {Document: json.RawMessage(`{}`)},
		"a blank fingerprint": {SHA256: "  ", Document: json.RawMessage(`{}`)},
		"broken JSON":         {SHA256: sha("x"), Document: json.RawMessage(`{"a":`)},
		"an array":            {SHA256: sha("x"), Document: json.RawMessage(`[]`)},
		"null":                {SHA256: sha("x"), Document: json.RawMessage(`null`)},
		"a bare string":       {SHA256: sha("x"), Document: json.RawMessage(`"x"`)},
	} {
		if _, err := store.PublishVoucherSettings(ctx, record); err == nil {
			t.Fatalf("%s must be refused", name)
		}
	}
	if current, _ = store.CurrentVoucherSettings(ctx); current.ID != rollback.ID {
		t.Fatalf("a refused version changed the current one: %+v", current)
	}
}

// movableClock reads whatever it was last set to — forwards, backwards, or not
// at all.
type movableClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *movableClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *movableClock) set(now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = now
}

// voucherSettingsOrderContract: the version published last is the current one,
// however the clock behaves — frozen (as in tests) or running behind the node
// that took the previous version.
func voucherSettingsOrderContract(t *testing.T, store VoucherStore, clock *movableClock, sha func(string) string) {
	t.Helper()
	ctx := context.Background()
	start := clock.Now()
	var published []VoucherSettingsRecord
	publish := func(rate string) {
		t.Helper()
		record, err := store.PublishVoucherSettings(ctx, VoucherSettingsRecord{
			SHA256: sha(rate), Document: json.RawMessage(`{"usd_rate":"` + rate + `"}`),
		})
		if err != nil {
			t.Fatal(err)
		}
		if current, err := store.CurrentVoucherSettings(ctx); err != nil || current.ID != record.ID {
			t.Fatalf("after publishing %s the current version is %+v (err %v), want %s", rate, current, err, record.ID)
		}
		published = append(published, record)
	}

	// A frozen clock: three versions at the same instant.
	publish("9.71")
	publish("9.72")
	publish("9.73")
	// A clock that went back ten minutes (another node, or a correction).
	clock.set(start.Add(-10 * time.Minute))
	publish("9.74")
	publish("9.75")
	// And on again.
	clock.set(start.Add(time.Hour))
	publish("9.76")

	history, err := store.ListVoucherSettings(ctx, 50)
	if err != nil || len(history) < len(published) {
		t.Fatalf("history: %d err=%v", len(history), err)
	}
	for i, record := range published {
		got := history[len(published)-1-i]
		if got.ID != record.ID {
			t.Fatalf("the history is not in publishing order at %d: %s, want %s", i, got.ID, record.ID)
		}
	}
	for i := 1; i < len(published); i++ {
		if !published[i].CreatedAt.After(published[i-1].CreatedAt) {
			t.Fatalf("version %d (%v) does not sort after version %d (%v)", i, published[i].CreatedAt, i-1, published[i-1].CreatedAt)
		}
	}
	// What was returned is what is stored.
	for i, record := range published {
		got := history[len(published)-1-i]
		if !got.CreatedAt.Equal(record.CreatedAt) {
			t.Fatalf("version %d was returned with %v but is stored as %v", i, record.CreatedAt, got.CreatedAt)
		}
	}
}

func newSteppingFileStore(t *testing.T, path string) *FileStore {
	t.Helper()
	store, err := NewFileStore(path, &steppingClock{next: time.Date(2026, 10, 8, 9, 0, 0, 0, time.UTC)})
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func TestFileStoreVoucherKindsContract(t *testing.T) {
	path := filepath.Join(t.TempDir(), "installations.json")
	store := newSteppingFileStore(t, path)
	provisioned, err := store.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{ShopName: "Services Shop"})
	if err != nil {
		t.Fatal(err)
	}
	id := provisioned.Installation.ID
	voucherKindsContract(t, store, id, voucherKindsHooks{
		forceOrder: func(t *testing.T, purchaseID, order string) {
			t.Helper()
			store.mu.Lock()
			defer store.mu.Unlock()
			row := store.data.VoucherPurchases[purchaseID]
			row.SupplierOrderID = order
			store.data.VoucherPurchases[purchaseID] = row
		},
	})
	voucherRedirectRaceContract(t, store, id)

	// Everything survives a restart, kinds and details included.
	reloaded, err := NewFileStore(path, fixedClock{now: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	airtimes, err := reloaded.ListVoucherPurchases(context.Background(), VoucherPurchaseFilter{InstallationID: id, Kind: VoucherKindAirtime})
	if err != nil || len(airtimes) == 0 {
		t.Fatalf("reloaded airtime rows: %d err=%v", len(airtimes), err)
	}
	for _, row := range airtimes {
		if row.Kind != VoucherKindAirtime {
			t.Fatalf("reloaded kind: %+v", row)
		}
	}
}

// A row written before purchases had a kind (the file store of the previous
// release) is a card, however it is read.
func TestFileStoreReadsRowsWithoutAKindAsCards(t *testing.T) {
	store := newSteppingFileStore(t, filepath.Join(t.TempDir(), "installations.json"))
	ctx := context.Background()
	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: "Old Shop"})
	if err != nil {
		t.Fatal(err)
	}
	id := provisioned.Installation.ID
	if _, _, err := store.PostWalletEntry(ctx, WalletPosting{InstallationID: id, Kind: WalletEntryAdjustment, Amount: "100", IdempotencyKey: "f"}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.TransferWalletFunds(ctx, WalletTransfer{InstallationID: id, From: WalletAccountMain, To: WalletAccountVouchers, Amount: "50", IdempotencyKey: "t"}); err != nil {
		t.Fatal(err)
	}
	pending := map[string]VoucherPurchase{}
	for _, key := range []string{"old-1", "old-2", "old-3"} {
		row, _, err := store.BeginVoucherPurchase(ctx, kindsPurchase(id, key, ""))
		if err != nil {
			t.Fatal(err)
		}
		pending[key] = row
	}
	// Strip the kinds as the previous release's file would have them.
	store.mu.Lock()
	for key, row := range store.data.VoucherPurchases {
		row.Kind = ""
		store.data.VoucherPurchases[key] = row
	}
	store.mu.Unlock()

	if row, err := store.GetVoucherPurchase(ctx, pending["old-1"].ID); err != nil || row.Kind != VoucherKindCard {
		t.Fatalf("get: %+v err=%v", row, err)
	}
	if row, found, err := store.FindVoucherPurchaseByKey(ctx, id, "old-1"); err != nil || !found || row.Kind != VoucherKindCard {
		t.Fatalf("find: %+v err=%v", row, err)
	}
	rows, err := store.ListVoucherPurchases(ctx, VoucherPurchaseFilter{InstallationID: id, Kind: VoucherKindCard})
	if err != nil || len(rows) != 3 {
		t.Fatalf("a row without a kind is listed as a card: %d err=%v", len(rows), err)
	}
	if rows, _ := store.ListVoucherPurchases(ctx, VoucherPurchaseFilter{InstallationID: id, Kind: VoucherKindAirtime}); len(rows) != 0 {
		t.Fatalf("and not as airtime: %d", len(rows))
	}
	waiting, err := store.ListVoucherPurchasesAwaitingCheck(ctx, store.clock.Now().Add(time.Hour), 0)
	if err != nil || len(waiting) != 3 || waiting[0].Kind != VoucherKindCard {
		t.Fatalf("awaiting check: %+v err=%v", waiting, err)
	}
	finished, applied, err := store.FinishVoucherPurchase(ctx, pending["old-2"].ID, VoucherPurchaseOutcome{
		Status: VoucherPurchaseFailed, ErrorCode: "supplier_out_of_stock",
	})
	if err != nil || !applied || finished.Kind != VoucherKindCard {
		t.Fatalf("finish: %+v applied=%v err=%v", finished, applied, err)
	}
	if resolved, applied, err := store.ResolveVoucherPurchase(ctx, pending["old-3"].ID, VoucherPurchaseResolution{Found: true, SupplierOrderID: "o-3"}); err != nil || !applied || resolved.Kind != VoucherKindCard {
		t.Fatalf("resolve: %+v applied=%v err=%v", resolved, applied, err)
	}
	if redirected, applied, err := store.RedirectVoucherPurchase(ctx, pending["old-1"].ID, "reloadly", "1"); err != nil || !applied || redirected.Kind != VoucherKindCard {
		t.Fatalf("redirect: %+v applied=%v err=%v", redirected, applied, err)
	}
}

func TestFileStoreVoucherSettingsContract(t *testing.T) {
	path := filepath.Join(t.TempDir(), "installations.json")
	store := newSteppingFileStore(t, path)
	voucherSettingsContract(t, store, func(name string) string { return "settings-test-" + name })

	// The history survives a restart.
	reloaded, err := NewFileStore(path, fixedClock{now: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	history, err := reloaded.ListVoucherSettings(context.Background(), 10)
	if err != nil || len(history) != 3 {
		t.Fatalf("reloaded history: %d err=%v", len(history), err)
	}
	if current, err := reloaded.CurrentVoucherSettings(context.Background()); err != nil || current.Note != "rolled back" {
		t.Fatalf("reloaded current: %+v err=%v", current, err)
	}
}

func TestFileStoreVoucherSettingsOrderFollowsPublishing(t *testing.T) {
	clock := &movableClock{now: time.Date(2026, 10, 8, 9, 0, 0, 0, time.UTC)}
	store, err := NewFileStore(filepath.Join(t.TempDir(), "installations.json"), clock)
	if err != nil {
		t.Fatal(err)
	}
	voucherSettingsOrderContract(t, store, clock, func(name string) string { return "order-test-" + name })
}

// Redis-backed deployments wrap the store; the wrapper must carry the new
// capabilities through to the real one.
func TestCachedInstallationStoreForwardsVoucherServices(t *testing.T) {
	inner := newSteppingFileStore(t, filepath.Join(t.TempDir(), "installations.json"))
	cached := NewCachedInstallationStore(inner, newMemoryInstallationCache(), fixedClock{now: time.Now()}, time.Minute)
	provisioned, err := cached.ProvisionInstallation(context.Background(), ProvisionInstallationRequest{ShopName: "Cached Shop"})
	if err != nil {
		t.Fatal(err)
	}
	voucherSettingsContract(t, cached, func(name string) string { return "cached-settings-" + name })
	voucherKindsContract(t, cached, provisioned.Installation.ID, voucherKindsHooks{})
	if history, err := inner.ListVoucherSettings(context.Background(), 10); err != nil || len(history) != 3 {
		t.Fatalf("the settings went through to the inner store: %d err=%v", len(history), err)
	}
}

func TestVoucherPurchaseKindMigrationIsAdditive(t *testing.T) {
	var migration *postgresMigration
	for i := range postgresMigrations {
		if postgresMigrations[i].version == 21 {
			migration = &postgresMigrations[i]
		}
	}
	if migration == nil {
		t.Fatal("migration 21 is missing")
	}
	sql := migration.sql
	for _, want := range []string{
		"ALTER TABLE relay_voucher_purchases",
		"ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'card'",
		"ADD COLUMN IF NOT EXISTS target text NOT NULL DEFAULT ''",
		"ADD COLUMN IF NOT EXISTS details jsonb",
		"CREATE TABLE IF NOT EXISTS relay_voucher_settings",
		"document jsonb NOT NULL",
	} {
		if !strings.Contains(sql, want) {
			t.Errorf("migration 21 should contain %q", want)
		}
	}
	// A relay still on the previous release keeps working: nothing is dropped,
	// renamed or tightened.
	for _, forbidden := range []string{"DROP ", "RENAME ", "SET NOT NULL"} {
		if strings.Contains(strings.ToUpper(sql), forbidden) {
			t.Errorf("migration 21 must stay additive, found %q", forbidden)
		}
	}
}

// postgresVoucherTestStore connects to the dedicated test database, migrated.
// Point POINTY_RELAY_E2E_DATABASE_URL at a DEDICATED database, never a dev one.
func postgresVoucherTestStore(t *testing.T, clock Clock) *PostgresStore {
	t.Helper()
	databaseURL := os.Getenv("POINTY_RELAY_E2E_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set POINTY_RELAY_E2E_DATABASE_URL to run the Postgres voucher services tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	store, err := NewPostgresStore(ctx, databaseURL, clock)
	if err != nil {
		t.Fatalf("connect postgres: %v", err)
	}
	t.Cleanup(store.Close)
	if err := store.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return store
}

// TestPostgresVoucherKindsContract exercises migration 21 and the SQL behind
// kinds, targets, details and RedirectVoucherPurchase.
func TestPostgresVoucherKindsContract(t *testing.T) {
	store := postgresVoucherTestStore(t, fixedClock{now: time.Now().UTC().Truncate(time.Second)})
	ctx := context.Background()
	provisioned, err := store.ProvisionInstallation(ctx, ProvisionInstallationRequest{ShopName: "Services Shop"})
	if err != nil {
		t.Fatal(err)
	}
	id := provisioned.Installation.ID
	t.Cleanup(func() {
		cleanup := context.Background()
		for _, table := range []string{
			"relay_voucher_purchases", "relay_wallet_entries", "relay_wallet_accounts", "relay_wallets", "relay_admin_audit_events",
		} {
			_, _ = store.pool.Exec(cleanup, `DELETE FROM `+table+` WHERE installation_id = $1`, id)
		}
		_, _ = store.pool.Exec(cleanup, `DELETE FROM relay_installations WHERE id = $1`, id)
	})
	voucherKindsContract(t, store, id, voucherKindsHooks{
		forceOrder: func(t *testing.T, purchaseID, order string) {
			t.Helper()
			if _, err := store.pool.Exec(ctx, `UPDATE relay_voucher_purchases SET supplier_order_id = $2 WHERE id = $1`, purchaseID, order); err != nil {
				t.Fatal(err)
			}
		},
	})
	voucherRedirectRaceContract(t, store, id)

	// A row the previous release wrote — its INSERT names none of the new
	// columns — is a card with no target and no details, and works like any.
	legacyID := "legacy-" + id
	if _, err := store.pool.Exec(
		ctx,
		`INSERT INTO relay_voucher_purchases (
			id, installation_id, idempotency_key, item_key, quantity, unit_price, amount,
			supplier, status, created_at, updated_at
		) VALUES ($1, $2, 'legacy-key', 'itunes-us-10', 1, 5, 5, 'bnplus', 'pending', now(), now())`,
		legacyID, id,
	); err != nil {
		t.Fatalf("a row without the new columns must insert: %v", err)
	}
	legacy, err := store.GetVoucherPurchase(ctx, legacyID)
	if err != nil || legacy.Kind != VoucherKindCard || legacy.Target != "" || len(legacy.Details) != 0 {
		t.Fatalf("legacy row: %+v err=%v", legacy, err)
	}
	cards, err := store.ListVoucherPurchases(ctx, VoucherPurchaseFilter{InstallationID: id, Kind: VoucherKindCard, Limit: 500})
	listed := false
	for _, row := range cards {
		listed = listed || row.ID == legacyID
	}
	if err != nil || !listed {
		t.Fatalf("a legacy row is listed as a card: %v err=%v", listed, err)
	}
	if redirected, applied, err := store.RedirectVoucherPurchase(ctx, legacyID, "reloadly", "1"); err != nil || !applied || redirected.Kind != VoucherKindCard {
		t.Fatalf("redirect: %+v applied=%v err=%v", redirected, applied, err)
	}
	if finished, applied, err := store.FinishVoucherPurchase(ctx, legacyID, VoucherPurchaseOutcome{
		Status: VoucherPurchaseSucceeded, SupplierOrderID: "legacy-order", SupplierCost: "1", SupplierCurrency: "USD",
	}); err != nil || !applied || finished.Kind != VoucherKindCard || finished.Status != VoucherPurchaseSucceeded {
		t.Fatalf("finish: %+v applied=%v err=%v", finished, applied, err)
	}
}

// TestPostgresVoucherSettingsContract exercises the settings table of
// migration 21.
func TestPostgresVoucherSettingsContract(t *testing.T) {
	store := postgresVoucherTestStore(t, &steppingClock{next: time.Now().UTC().Truncate(time.Second)})
	ctx := context.Background()
	clean := func() {
		_, _ = store.pool.Exec(context.Background(), `DELETE FROM relay_voucher_settings WHERE sha256 LIKE 'pg-settings-test-%'`)
	}
	clean()
	t.Cleanup(clean)
	voucherSettingsContract(t, store, func(name string) string { return "pg-settings-test-" + name })

	// Postgres keeps the document as jsonb and reads it back as the same
	// document: strings stay strings (a rate is never a float).
	record, err := store.PublishVoucherSettings(ctx, VoucherSettingsRecord{
		SHA256:   "pg-settings-test-precision",
		Document: json.RawMessage(`{"usd_rate":"9.710000","funding_percent":"0.10","popular":["NE","ML"]}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	current, err := store.CurrentVoucherSettings(ctx)
	if err != nil || current.ID != record.ID ||
		!sameJSON(t, current.Document, `{"usd_rate":"9.710000","funding_percent":"0.10","popular":["NE","ML"]}`) {
		t.Fatalf("precision: %+v err=%v", current, err)
	}
}

func TestPostgresVoucherSettingsOrderFollowsPublishing(t *testing.T) {
	clock := &movableClock{now: time.Now().UTC().Truncate(time.Second)}
	store := postgresVoucherTestStore(t, clock)
	clean := func() {
		_, _ = store.pool.Exec(context.Background(), `DELETE FROM relay_voucher_settings WHERE sha256 LIKE 'pg-order-test-%'`)
	}
	clean()
	t.Cleanup(clean)
	voucherSettingsOrderContract(t, store, clock, func(name string) string { return "pg-order-test-" + name })
}
