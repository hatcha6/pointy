package relay

import (
	"context"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"strconv"
	"testing"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// fxStubSupplier is a dollar supplier whose balance is known.
type fxStubSupplier struct {
	key     string
	balance *big.Rat
	at      time.Time
}

func (s fxStubSupplier) Key() string { return s.key }
func (s fxStubSupplier) Buy(context.Context, vouchers.Ref, int, string) (vouchers.Purchase, error) {
	return vouchers.Purchase{}, nil
}
func (s fxStubSupplier) Lookup(context.Context, vouchers.Ref, string) (vouchers.Purchase, error) {
	return vouchers.Purchase{}, nil
}
func (s fxStubSupplier) Find(context.Context, vouchers.Ref, int, time.Time, time.Time) ([]vouchers.Purchase, error) {
	return nil, nil
}
func (s fxStubSupplier) Offers(context.Context) ([]vouchers.Offer, error) { return nil, nil }
func (s fxStubSupplier) LastBalance() (*big.Rat, string, time.Time, bool) {
	return s.balance, "USD", s.at, s.balance != nil
}

func newFXHarness(t *testing.T, held string) *settingsHarness {
	t.Helper()
	h := newSettingsHarness(t)
	balance, _ := new(big.Rat).SetString(held)
	h.server.Vouchers.Suppliers = map[string]vouchers.Supplier{"fazer": fxStubSupplier{key: "fazer", balance: balance, at: h.clock.now}}
	ctx := context.Background()
	for _, r := range []control.ExchangeRate{
		usdRate("bank", "nab", "10.00", h.clock.now.AddDate(0, 0, -8)),
		usdRate("bank", "nab", "11.61", h.clock.now.Add(-time.Hour)),
		usdRate("cash", "", "11.42", h.clock.now.Add(-time.Hour)),
	} {
		if _, err := h.store.FileStore.UpsertExchangeRate(ctx, r); err != nil {
			t.Fatal(err)
		}
	}
	if status, body := h.admin(t, http.MethodPut, "/settings",
		`{"usd_rate_source":"fulus","usd_rate_series":"bank","usd_rate_bank_code":"nab","usd_rate_buffer_percent":"7"}`); status != http.StatusOK && status != http.StatusCreated {
		t.Fatalf("publish: %d %v", status, body)
	}
	return h
}

func TestFXAdminShowsEveryStep(t *testing.T) {
	h := newFXHarness(t, "3.80")
	status, body := h.admin(t, http.MethodGet, "/fx", ``)
	if status != http.StatusOK || body["enabled"] != true {
		t.Fatalf("GET /fx: %d %v", status, body)
	}
	q := asMap(t, body["quote"])
	// No top-up recorded: the 7 % buffer is the premium; 11.61 x 1.07 = 12.4227.
	// The dollar rose 16.1 % in the week: half of it, capped at 5 %.
	if q["live"] != "11.6100" || q["premium_source"] != "setting" || q["replacement"] != "12.4227" ||
		q["cushion_percent"] != "5.00" || q["market"] != "13.0438" {
		t.Fatalf("quote: %v", q)
	}
	if len(body["history"].([]any)) != 2 {
		t.Fatalf("history is the bank nab series: %v", body["history"])
	}
}

func TestFXFundingDryRunThenRecordReprices(t *testing.T) {
	h := newFXHarness(t, "120")
	// What 120 USDT at 10.80 a dollar (bank 10.00 that day) would make of the rate.
	status, body := h.admin(t, http.MethodPost, "/fx/fundings",
		`{"supplier":"fazer","usd":"120","lyd":"1296","method":"bnplus_usdt","market_rate":"10","dry_run":true}`)
	if status != http.StatusOK || body["after"] == nil {
		t.Fatalf("dry run: %d %v", status, body)
	}
	if rows, _ := h.store.FileStore.ListSupplierFundings(context.Background()); len(rows) != 0 {
		t.Fatal("a dry run stores nothing")
	}
	after := asMap(t, body["after"])
	if after["premium_source"] != "learned" || after["premium_percent"] != "8.00" {
		t.Fatalf("learned premium: %v", after)
	}

	// Recorded: the supplier now holds 120 dollars that cost 10.80; the market
	// (11.61 x 1.08 x 1.05) is above that, so the market binds.
	status, created := h.admin(t, http.MethodPost, "/fx/fundings",
		`{"supplier":"fazer","usd":"120","lyd":"1296","method":"bnplus_usdt","market_rate":"10","reference":"d2e7121b"}`)
	if status != http.StatusCreated || created["id"] == "" {
		t.Fatalf("record: %d %v", status, created)
	}
	settings, _, err := h.server.currentVoucherSettings(context.Background(), h.store)
	if err != nil {
		t.Fatal(err)
	}
	rate, _ := settings.EffectiveUSDRate()
	if got := rate.FloatString(4); got != "13.1657" { // 11.61 x 1.08 x 1.05
		t.Fatalf("priced at %s", got)
	}
	one, _ := settings.USDToLYDFrom("fazer", big.NewRat(1, 1))
	if got := one.FloatString(4); got != "13.1657" {
		t.Fatalf("a fazer dollar: %s", got)
	}

	// Voided: the premium falls back to the 7 % setting.
	if status, body := h.admin(t, http.MethodPost, "/fx/fundings/"+created["id"].(string)+"/void", `{}`); status != http.StatusBadRequest {
		t.Fatalf("a void needs a reason: %d %v", status, body)
	}
	if status, body := h.admin(t, http.MethodPost, "/fx/fundings/"+created["id"].(string)+"/void", `{"reason":"typed twice"}`); status != http.StatusOK {
		t.Fatalf("void: %d %v", status, body)
	}
	settings, _, _ = h.server.currentVoucherSettings(context.Background(), h.store)
	if rate, _ := settings.EffectiveUSDRate(); rate.FloatString(4) != "13.0438" {
		t.Fatalf("after the void: %s", rate.FloatString(4))
	}
}

// Dollars bought dear are priced at the market once it falls (the loss is
// reported); with fx.book_floor on, at what they cost.
func TestFXBookFloorIsTheOwnersChoice(t *testing.T) {
	h := newFXHarness(t, "100")
	// Bought at 14.00 when the bank said 12.50 (a 12 % premium); the bank is at
	// 11.61 now, so the market is 11.61 x 1.12 x 1.05 = 13.65, under the 14.00
	// those dollars cost.
	if status, body := h.admin(t, http.MethodPost, "/fx/fundings",
		`{"supplier":"fazer","usd":"100","lyd":"1400","method":"bnplus_usdt","market_rate":"12.50"}`); status != http.StatusCreated {
		t.Fatalf("record: %d %v", status, body)
	}
	settings, _, _ := h.server.currentVoucherSettings(context.Background(), h.store)
	one, _ := settings.USDToLYDFrom("fazer", big.NewRat(1, 1))
	if got := one.FloatString(2); got != "13.65" {
		t.Fatalf("priced at the market by default: %s", got)
	}
	status, body := h.admin(t, http.MethodGet, "/fx", ``)
	book := asMap(t, asMap(t, body["quote"])["books"].([]any)[0])
	if status != http.StatusOK || book["binding"] != "market" || book["gain_lyd"] != "-99.68" /* 100 x 11.61 x 1.12 vs 1,400 */ {
		t.Fatalf("the loss is reported, not priced in: %v", book)
	}

	if status, body := h.admin(t, http.MethodPut, "/settings",
		`{"usd_rate_source":"fulus","usd_rate_series":"bank","usd_rate_bank_code":"nab","usd_rate_buffer_percent":"7","fx":{"book_floor":"on"}}`); status != http.StatusOK && status != http.StatusCreated {
		t.Fatalf("publish: %d %v", status, body)
	}
	settings, _, _ = h.server.currentVoucherSettings(context.Background(), h.store)
	one, _ = settings.USDToLYDFrom("fazer", big.NewRat(1, 1))
	if got := one.FloatString(2); got != "14.00" {
		t.Fatalf("book floor on: %s", got)
	}
}

// After a fall the fading peak brings prices down gently, but never holds a
// card above its competitor: past that point it is priced without the peak.
func TestFXPeakStopsAtTheCompetitorPrice(t *testing.T) {
	now := time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	rl := vouchers.Ref{Supplier: vouchers.SupplierReloadly, ID: "9/100"}
	offer := control.VoucherOffer{Supplier: "reloadly", Ref: "9/100", Price: "100", Currency: "USD", InStock: true, SyncedAt: now}
	located, config, offers := cardRankInputs([]vouchers.Ref{rl}, []string{vouchers.SupplierReloadly}, offer)
	located.Item.FaceCurrency, located.Item.FaceValue = "USD", "100"
	server := HTTPServer{Vouchers: config, Clock: &settingsClock{now: now}, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}

	// The bank was 11 six hours ago and is 10 now: the peak is 11 x (1 - 2 % x 6/24) = 10.945.
	quote, _ := vouchers.ComputeFX(vouchers.FXInputs{
		Policy: vouchers.FXPolicy{MomentumSharePercent: "0"}, Live: big.NewRat(10, 1), LiveAt: now, Now: now,
		Series: []vouchers.RatePoint{{At: now.Add(-6 * time.Hour), Rate: big.NewRat(11, 1)}},
	})
	settings := vouchers.DefaultSettings().WithFX(quote)
	price := func(market *vouchers.Market) float64 {
		located.Item.Market = market
		_, retail, ok := server.cardPricer(offers, settings)(located)
		if !ok {
			t.Fatal("not priced")
		}
		f, _ := strconv.ParseFloat(retail, 64)
		return f
	}

	// No competitor data: the peak prices it (cost 1,094.50 plus the margin).
	if got := price(nil); got < 1140 {
		t.Fatalf("no competitor: priced at the peak, got %.2f", got)
	}
	// A competitor at 1,250: the peak-priced card fits under it, so the peak stays.
	if got := price(&vouchers.Market{PriceLYD: "1250", USDRate: "10", Captured: "2026-11-25"}); got < 1140 || got > 1250 {
		t.Fatalf("under the competitor the peak stays: %.2f", got)
	}
	// A competitor at 1,100: with the peak the card would cost ~1,150, above it,
	// so the peak goes and the card is priced from the 1,000 replacement cost.
	if got := price(&vouchers.Market{PriceLYD: "1100", USDRate: "10", Captured: "2026-11-25"}); got > 1100 {
		t.Fatalf("never above the competitor because of the peak: %.2f", got)
	}

	// The cushion is held to the competitor the same way.
	cushioned, _ := vouchers.ComputeFX(vouchers.FXInputs{Live: big.NewRat(10, 1), LiveAt: now, Now: now,
		Series: []vouchers.RatePoint{{At: now.AddDate(0, 0, -8), Rate: big.NewRat(9, 1)}}})
	settings = vouchers.DefaultSettings().WithFX(cushioned) // +11 % in a week: a 5 % cushion
	if got := price(&vouchers.Market{PriceLYD: "1080", USDRate: "10", Captured: "2026-11-25"}); got > 1080 {
		t.Fatalf("never above the competitor because of the cushion: %.2f", got)
	}
}

// The fallback to the replacement rate never prices from a supplier the card
// will not be bought from.
func TestFXCompetitorFallbackKeepsTheSupplierBoughtFrom(t *testing.T) {
	now := time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	bn := vouchers.Ref{Supplier: vouchers.SupplierBNPlus, ID: "1"}
	rl := vouchers.Ref{Supplier: vouchers.SupplierReloadly, ID: "9/10"}
	// BN Plus sells it for 108 dinars; Reloadly for $10 (110 at the cushioned rate, 104.76 without).
	located, config, offers := cardRankInputs([]vouchers.Ref{bn, rl}, []string{vouchers.SupplierBNPlus, vouchers.SupplierReloadly},
		control.VoucherOffer{Supplier: "bnplus", Ref: "1", Price: "108", Currency: "LYD", InStock: true, SyncedAt: now},
		control.VoucherOffer{Supplier: "reloadly", Ref: "9/10", Price: "10", Currency: "USD", InStock: true, SyncedAt: now})
	located.Item.FaceCurrency, located.Item.FaceValue = "USD", "10"
	server := HTTPServer{Vouchers: config, Clock: &settingsClock{now: now}, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	quote, _ := vouchers.ComputeFX(vouchers.FXInputs{Live: fxRat("10.476190476"), LiveAt: now, Now: now,
		Series: []vouchers.RatePoint{{At: now.AddDate(0, 0, -8), Rate: fxRat("9")}}})
	settings := vouchers.DefaultSettings().WithFX(quote)
	if bought, cost := pricedFrom(server.Vouchers.rankSuppliers(located, offers, settings)); bought != bn || cost.FloatString(0) != "108" {
		t.Fatalf("BN Plus is bought from: %v %v", bought, cost)
	}
	located.Item.Market = &vouchers.Market{PriceLYD: "110", USDRate: "10.476190476", Captured: "2026-11-25"}
	shop, _, ok := server.cardPricer(offers, settings)(located)
	got, _ := strconv.ParseFloat(shop, 64)
	if !ok || got < 108*1.03 {
		t.Fatalf("the shop must pay at least the 108 it is bought at plus the company's floor: %s", shop)
	}
}

func fxRat(s string) *big.Rat {
	r, _ := new(big.Rat).SetString(s)
	return r
}

func TestFXFundingRefusesNonsense(t *testing.T) {
	h := newFXHarness(t, "1")
	status, body := h.admin(t, http.MethodPost, "/fx/fundings", `{"supplier":"fazer","usd":"120","lyd":"12"}`)
	if status != http.StatusBadRequest || body["field"] != "lyd" {
		t.Fatalf("0.1 dinar a dollar: %d %v", status, body)
	}
	// The bank rate is filled in from the series when not given.
	status, body = h.admin(t, http.MethodPost, "/fx/fundings", `{"supplier":"fazer","usd":"10","lyd":"124.2","dry_run":true}`)
	if status != http.StatusOK || asMap(t, body["funding"])["market_rate"] != "11.6100" {
		t.Fatalf("market rate filled in: %d %v", status, body)
	}
}

func TestFXFundingRefusesTheSameReferenceTwice(t *testing.T) {
	h := newFXHarness(t, "1")
	body := `{"supplier":"fazer","usd":"60","lyd":"648","method":"bnplus_usdt","reference":"d2e7121b"}`
	if status, created := h.admin(t, http.MethodPost, "/fx/fundings", body); status != http.StatusCreated {
		t.Fatalf("first: %d %v", status, created)
	}
	status, refused := h.admin(t, http.MethodPost, "/fx/fundings", `{"supplier":"fazer","usd":"60","lyd":"648","reference":"x1, D2E7121B"}`)
	if status != http.StatusBadRequest || refused["field"] != "reference" {
		t.Fatalf("the same purchase recorded twice: %d %v", status, refused)
	}
	// The preview refuses it too, so the dialog says so before the tap.
	if status, _ := h.admin(t, http.MethodPost, "/fx/preview", body); status != http.StatusBadRequest {
		t.Fatalf("preview: %d", status)
	}
}

func TestFXFundingNeedsABankRateForItsDate(t *testing.T) {
	h := newFXHarness(t, "1")
	old := h.clock.now.AddDate(0, 0, -20).Format(time.RFC3339)
	status, body := h.admin(t, http.MethodPost, "/fx/fundings", `{"supplier":"fazer","usd":"5","lyd":"54","funded_at":"`+old+`"}`)
	if status != http.StatusBadRequest || body["field"] != "market_rate" {
		t.Fatalf("no bank rate stored that day: %d %v", status, body)
	}
	if status, body := h.admin(t, http.MethodPost, "/fx/fundings",
		`{"supplier":"fazer","usd":"5","lyd":"54","funded_at":"`+old+`","market_rate":"9.95"}`); status != http.StatusCreated {
		t.Fatalf("typed: %d %v", status, body)
	}
}

// fulus.ly silent for days: the cards keep selling, from the last rate and
// top-up with the full cushion, instead of going off the shelf.
func TestFXFallbackWhenTheRateIsStale(t *testing.T) {
	h := newFXHarness(t, "1")
	h.clock.mu.Lock()
	h.clock.now = h.clock.now.Add(72 * time.Hour) // the last rate is now 73 h old: stale at 48 h
	h.clock.mu.Unlock()
	h.server.VoucherSettingsCache.invalidate()
	settings, _, err := h.server.currentVoucherSettings(context.Background(), h.store)
	if err != nil {
		t.Fatal(err)
	}
	if !settings.Priced() {
		t.Fatalf("still priced: %q", settings.RateProblem)
	}
	q := settings.FXQuote()
	if q == nil || !q.Fallback || q.Cushion.FloatString(2) != "0.05" {
		t.Fatalf("priced by the fallback with the full cushion: %+v", q)
	}
	// 11.61 x 1.07 x 1.05
	if rate, _ := settings.EffectiveUSDRate(); rate.FloatString(4) != "13.0438" {
		t.Fatalf("fallback rate %s", rate.FloatString(4))
	}
	// A manual rate, when the operator set one, wins over the fallback.
	if status, body := h.admin(t, http.MethodPut, "/settings",
		`{"usd_rate":"12","usd_rate_source":"fulus","usd_rate_series":"bank","usd_rate_bank_code":"nab","usd_rate_buffer_percent":"7"}`); status != http.StatusOK && status != http.StatusCreated {
		t.Fatalf("publish: %d %v", status, body)
	}
	settings, _, _ = h.server.currentVoucherSettings(context.Background(), h.store)
	if rate, source := settings.EffectiveUSDRate(); rate.FloatString(2) != "12.00" || source != vouchers.RateSourceManual {
		t.Fatalf("manual fallback: %s %s", rate.FloatString(2), source)
	}
}
