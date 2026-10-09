package reloadly

import (
	"math/big"
	"testing"
)

func mustRat(t *testing.T, text string) *big.Rat {
	t.Helper()
	r, ok := new(big.Rat).SetString(text)
	if !ok {
		t.Fatalf("%q is not a number", text)
	}
	return r
}

func sameCost(t *testing.T, label string, got *big.Rat, ok bool, want string) {
	t.Helper()
	if !ok || got == nil {
		t.Errorf("%s: not priced, want %s", label, want)
		return
	}
	if text := got.FloatString(5); text != want {
		t.Errorf("%s: cost = %s, want %s", label, text, want)
	}
}

// Every want below is the balanceInfo.cost the sandbox debited for a real order
// of exactly this (2026-10-08, rows frozen in testdata).

func TestAirtimeCostMatchesWhatTheSandboxDebited(t *testing.T) {
	for _, test := range []struct {
		label    string
		operator int64
		amount   string
		local    bool
		want     string
	}{
		// USD orders: the international discount (Commission).
		{"Orange Mali 4 USD, 5%", 289, "4", false, "3.80000"},
		{"Airtel Niger 1 USD", 640, "1", false, "0.95000"},
		{"Airtel Niger 0.2 USD", 640, "0.2", false, "0.19000"},
		{"Airtel Niger 0.198 USD", 640, "0.198", false, "0.18810"},
		{"Airtel Niger 0.19786 USD (5 decimals)", 640, "0.19786", false, "0.18797"},
		{"Airtel Niger 0.25 USD", 640, "0.25", false, "0.23750"},
		{"Claro Peru 1 USD, 4%", 367, "1", false, "0.96000"},
		{"Mobitel LK 0.5 USD: no commission, no international fee", 471, "0.5", false, "0.50000"},
		{"Hutchison LK 0.7 USD: its flat fee is local only", 475, "0.7", false, "0.70000"},
		{"Dialog LK FIXED 0.4 USD, 5%", 472, "0.4", false, "0.38000"},
		{"MTN Nigeria bundle FIXED 0.4 USD, 3%", 346, "0.4", false, "0.38800"},
		{"Etisalat Egypt FIXED 0.17 USD, 5%", 120, "0.17", false, "0.16150"},
		{"Sun Philippines PIN 0.09 USD", 369, "0.09", false, "0.08550"},
		{"T-Mobile USA PIN 10 USD: 3% off and a 0.20 flat fee", 1230, "10", false, "9.90000"},
		{"CellCard Cambodia 1 USD: the 10% fee replaces the 4% discount", 52, "1", false, "1.10000"},
		{"CellCard Cambodia 2 USD", 52, "2", false, "2.20000"},
		// Local orders: S = amount / rate, the LOCAL discount, local fees.
		{"Airtel Niger 100 XOF at 505.427002", 640, "100", true, "0.19785"},
		{"Orange Mali 2000 XOF at 505: no discount in local currency", 289, "2000", true, "3.96040"},
		{"Claro Peru 3.25 PEN at 3.2468801, local 1%", 367, "3.25", true, "0.99095"},
		{"Mobitel LK 135 LKR at 270, 10% local fee", 471, "135", true, "0.55000"},
		{"Hutchison LK 100 LKR at 158.3999939, 10 LKR flat fee", 475, "100", true, "0.69444"},
		{"Dialog LK FIXED 100 LKR, 10% local fee", 472, "100", true, "0.44000"},
		{"Etisalat Egypt FIXED 5 EGP is 5/29.9969997, not the 0.17 plan", 120, "5", true, "0.16668"},
		{"MTN Nigeria bundle FIXED 500 NGN is 500/1244", 346, "500", true, "0.40193"},
		{"Orange Mali Data FIXED 279 XOF is 279/505", 1132, "279", true, "0.55248"},
	} {
		got, ok := AirtimeCost(operatorByID(t, test.operator), mustRat(t, test.amount), test.local)
		sameCost(t, test.label, got, ok, test.want)
	}
}

func TestAirtimeCostRefusesWhatTheOperatorDoesNotSell(t *testing.T) {
	for _, test := range []struct {
		label    string
		operator int64
		amount   string
		local    bool
	}{
		{"below the local minimum", 640, "99", true},
		{"above the local maximum", 640, "50001", true},
		{"below the USD minimum", 289, "3.8", false},
		{"above the USD maximum", 289, "65", false},
		{"a FIXED plan that is not listed (USD)", 120, "0.18", false},
		{"a FIXED plan that is not listed (local)", 120, "5.5", true},
		{"local amounts the operator does not support", 1213, "5", true},
		{"zero", 640, "0", false},
		{"negative", 640, "-1", false},
	} {
		if got, ok := AirtimeCost(operatorByID(t, test.operator), mustRat(t, test.amount), test.local); ok {
			t.Errorf("%s: priced at %s", test.label, got.FloatString(5))
		}
	}
	if _, ok := AirtimeCost(operatorByID(t, 640), nil, false); ok {
		t.Error("no amount")
	}
	broken := operatorByID(t, 640)
	broken.FX.Rate = ""
	if _, ok := AirtimeCost(broken, mustRat(t, "100"), true); ok {
		t.Error("a local order without a rate must not be priced")
	}
	if _, ok := AirtimeCost(broken, mustRat(t, "1"), false); !ok {
		t.Error("a USD order does not need the rate")
	}
	broken = operatorByID(t, 640)
	broken.InternationalDiscount = "oops"
	if _, ok := AirtimeCost(broken, mustRat(t, "1"), false); ok {
		t.Error("an unreadable discount must not be priced as zero")
	}
}

func TestAirtimeCostFallsBackToTheCommission(t *testing.T) {
	op := operatorByID(t, 289)
	op.InternationalDiscount = ""
	got, ok := AirtimeCost(op, mustRat(t, "4"), false)
	sameCost(t, "commission fallback", got, ok, "3.80000")
}

func TestAirtimeLimits(t *testing.T) {
	lo, hi := AirtimeLimits(operatorByID(t, 640), true)
	if lo.FloatString(2) != "100.00" || hi.FloatString(2) != "50000.00" {
		t.Fatalf("local limits = %v..%v", lo, hi)
	}
	// The catalog says 0.20..98.93 USD; the 100 XOF minimum at 505.427002 is 0.19785.
	lo, hi = AirtimeLimits(operatorByID(t, 640), false)
	if lo.FloatString(5) != "0.19785" || hi.FloatString(2) != "98.93" {
		t.Fatalf("USD limits = %v..%v", lo.FloatString(5), hi.FloatString(5))
	}
	lo, hi = AirtimeLimits(operatorByID(t, 120), true)
	if lo.FloatString(1) != "5.0" || hi.Sign() <= 0 {
		t.Fatalf("FIXED local limits = %v..%v", lo, hi)
	}
	if lo, hi = AirtimeLimits(operatorByID(t, 1213), true); lo != nil || hi != nil {
		t.Fatalf("an operator without local plans has no local limits: %v..%v", lo, hi)
	}
}

func TestGiftCostMatchesWhatTheSandboxDebited(t *testing.T) {
	for _, test := range []struct {
		label    string
		product  int64
		amount   string
		quantity int
		want     string
	}{
		{"Red Lobster $5, $1 flat fee", 10316, "5", 1, "6.00000"},
		{"Xbox Live US $5, 5% off, $1 fee", 13948, "5", 1, "5.75000"},
		{"Xbox Live US $5 x2: per-card fee and discount", 13948, "5", 2, "11.50000"},
		{"Razer Gold US $5: 1% off, 1% fee, $1 fee", 10296, "5", 1, "6.00000"},
		{"Xbox US $10: 1.5% off, 1% fee, $1 fee", 16061, "10", 1, "10.95000"},
		{"Target US $1: $1 fee and 1% fee", 12740, "1", 1, "2.01000"},
		{"Amazon US RANGE $5.25: no fee, no discount", 5, "5.25", 1, "5.25000"},
		{"Mastercard virtual 1.234 (3 decimals)", 20316, "1.234", 1, "2.20932"},
		{"Mastercard virtual 1.20014", 20316, "1.20014", 1, "2.17614"},
		{"Mastercard virtual 1.20013 x2: rounded once, not 2 x 2.17613", 20316, "1.20013", 2, "4.35225"},
		{"App Store France EUR 5 at 1.176776, not the 5.88 of the map", 15, "5", 1, "6.88388"},
		{"Amazon UAE AED 5 at 0.272294, 1.2% off, $1 fee", 9, "5", 1, "2.34513"},
		{"Google Play KSA SAR 20 at 0.272148", 3943, "20", 1, "6.44296"},
	} {
		got, ok := GiftOrderCost(giftByID(t, test.product), mustRat(t, test.amount), test.quantity)
		sameCost(t, test.label, got, ok, test.want)
	}
	one, ok := GiftCost(giftByID(t, 10316), mustRat(t, "5"))
	sameCost(t, "GiftCost is one card", one, ok, "6.00000")
}

func TestGiftCostBoundsContainTheRealRate(t *testing.T) {
	// Reloadly publishes 1.176776 for EUR but charges with a rate nearer
	// 1.1767764: the sandbox debited 30.41941 for 25 EUR and 12.17938 for 10 EUR.
	for _, test := range []struct {
		label   string
		product int64
		amount  string
		debited string
	}{
		{"Netflix Spain EUR 25, $1 fee", 15363, "25", "30.41941"},
		{"Roblox FI EUR 10, 5% off, $1 fee", 11518, "10", "12.17938"},
	} {
		lo, hi, ok := GiftCostBounds(giftByID(t, test.product), mustRat(t, test.amount), 1)
		if !ok {
			t.Fatalf("%s: not priced", test.label)
		}
		actual := mustRat(t, test.debited)
		if actual.Cmp(lo) < 0 || actual.Cmp(hi) > 0 {
			t.Errorf("%s: debited %s is outside [%s, %s]", test.label, test.debited, lo.FloatString(5), hi.FloatString(5))
		}
		mid, _ := GiftOrderCost(giftByID(t, test.product), mustRat(t, test.amount), 1)
		diff := new(big.Rat).Sub(mid, actual)
		if diff.Abs(diff).Cmp(mustRat(t, "0.00002")) > 0 {
			t.Errorf("%s: the estimate %s is more than 2e-5 from %s", test.label, mid.FloatString(5), test.debited)
		}
	}
	// A product priced in the account currency has no uncertainty.
	lo, hi, ok := GiftCostBounds(giftByID(t, 10296), mustRat(t, "5"), 1)
	if !ok || lo.Cmp(hi) != 0 {
		t.Fatalf("USD bounds = %v..%v", lo, hi)
	}
}

func TestGiftRateIsRefinedByTheDenominationsForLowRateCurrencies(t *testing.T) {
	products := fixtureRows[GiftProduct](t, "giftcards_live_lowrate.json")
	byID := map[int64]GiftProduct{}
	for _, p := range products {
		byID[p.ID] = p
	}
	steam := byID[15791] // VND, published rate 0.000038 but really about 0.0000385
	lo, hi, ok := GiftRateBounds(steam)
	if !ok {
		t.Fatal("no rate bounds")
	}
	shown := mustRat(t, "0.000038")
	half := mustRat(t, "0.0000005")
	if lo.Cmp(new(big.Rat).Sub(shown, half)) <= 0 {
		t.Fatalf("the published rate alone allows %s; the denominations must narrow it", lo.FloatString(9))
	}
	if relative := new(big.Rat).Quo(new(big.Rat).Sub(hi, lo), lo); relative.Cmp(mustRat(t, "0.001")) > 0 {
		t.Fatalf("the refined rate is still %s wide", relative.FloatString(5))
	}
	// 200000 VND is listed at 7.70 USD with a 2% fee: about 7.854, not the
	// 7.752 the published rate alone gives.
	cost, ok := GiftCost(steam, mustRat(t, "200000"))
	if !ok {
		t.Fatal("not priced")
	}
	if cost.Cmp(mustRat(t, "7.84")) < 0 || cost.Cmp(mustRat(t, "7.87")) > 0 {
		t.Fatalf("Steam VN 200000 VND = %s, want about 7.854", cost.FloatString(5))
	}
	lowCost, highCost, _ := GiftCostBounds(steam, mustRat(t, "200000"), 1)
	if width := new(big.Rat).Sub(highCost, lowCost); width.Cmp(mustRat(t, "0.01")) > 0 {
		t.Fatalf("the cost is only known within %s", width.FloatString(5))
	}
	for id, p := range byID {
		if _, _, ok := GiftRateBounds(p); !ok {
			t.Errorf("product %d has no rate bounds", id)
		}
	}
}

func TestGiftRateBoundsFallBackWhenTheDenominationsContradictTheRate(t *testing.T) {
	p := giftByID(t, 15)
	p.RecipientToSenderRate = "2"
	lo, hi, ok := GiftRateBounds(p)
	if !ok || lo.Cmp(mustRat(t, "1.9999995")) != 0 || hi.Cmp(mustRat(t, "2.0000005")) != 0 {
		t.Fatalf("bounds = %v..%v, want the published rate alone", lo, hi)
	}
	p.RecipientToSenderRate = ""
	if _, _, ok := GiftRateBounds(p); ok {
		t.Fatal("no rate, no price")
	}
	p = giftByID(t, 15)
	p.RecipientToSenderRate = "0"
	if _, _, ok := GiftRateBounds(p); ok {
		t.Fatal("a zero rate is unusable")
	}
}

func TestGiftCostRefusesWhatTheProductDoesNotSell(t *testing.T) {
	for _, test := range []struct {
		label   string
		product int64
		amount  string
		qty     int
	}{
		{"an unlisted denomination", 10316, "7", 1},
		{"below the RANGE minimum", 5, "4.99", 1},
		{"above the RANGE maximum", 5, "100.01", 1},
		{"no card", 10316, "5", 0},
		{"zero", 10316, "0", 1},
	} {
		if got, ok := GiftOrderCost(giftByID(t, test.product), mustRat(t, test.amount), test.qty); ok {
			t.Errorf("%s: priced at %s", test.label, got.FloatString(5))
		}
	}
	if _, ok := GiftCost(giftByID(t, 10316), nil); ok {
		t.Error("no amount")
	}
	broken := giftByID(t, 10316)
	broken.DiscountPercentage = "x"
	if _, ok := GiftCost(broken, mustRat(t, "5")); ok {
		t.Error("an unreadable discount must not be priced as zero")
	}
	broken = giftByID(t, 10316)
	broken.DiscountPercentage = "150"
	if _, ok := GiftCost(broken, mustRat(t, "5")); ok {
		t.Error("a discount over 100% must not be priced")
	}
	broken = giftByID(t, 5)
	broken.MaxRecipientDenomination = ""
	if _, ok := GiftCost(broken, mustRat(t, "5")); ok {
		t.Error("a RANGE product without bounds cannot validate an amount")
	}
}

func TestGiftLimits(t *testing.T) {
	lo, hi := GiftLimits(giftByID(t, 10316))
	if lo.FloatString(1) != "5.0" || hi.FloatString(1) != "100.0" {
		t.Fatalf("FIXED limits = %v..%v", lo, hi)
	}
	lo, hi = GiftLimits(giftByID(t, 5))
	if lo.FloatString(1) != "5.0" || hi.FloatString(1) != "100.0" {
		t.Fatalf("RANGE limits = %v..%v", lo, hi)
	}
}

func TestBillCostMatchesWhatTheSandboxDebited(t *testing.T) {
	for _, test := range []struct {
		label  string
		biller int64
		amount string
		local  bool
		want   string
	}{
		{"Woyofal 1000 XOF at 470 + 117.5 XOF fee; the 8% is not given in local", 26, "1000", true, "2.37766"},
		{"Woyofal 2.13 USD, 8% off, no fee", 26, "2.13", false, "1.95960"},
		{"StarTimes FIXED plan 400 XOF", 28, "400", true, "1.10106"},
		{"StarTimes FIXED plan 0.66 USD, 8% off", 28, "0.66", false, "0.60720"},
		{"Eko prepaid 400 NGN at 450 + 225 NGN fee", 3, "400", true, "1.38889"},
	} {
		got, ok := BillCost(billerByID(t, test.biller), mustRat(t, test.amount), test.local)
		sameCost(t, test.label, got, ok, test.want)
	}
	// Not observed in the sandbox: South Africa's 8% international fee, no discount.
	got, ok := BillCost(billerByID(t, 30), mustRat(t, "10"), false)
	sameCost(t, "South Africa 10 USD (assumed additive 8% fee)", got, ok, "10.80000")
}

func TestBillCostRefusesWhatTheBillerDoesNotSell(t *testing.T) {
	for _, test := range []struct {
		label  string
		biller int64
		amount string
		local  bool
	}{
		{"below the local minimum", 26, "999", true},
		{"above the local maximum", 26, "310001", true},
		{"below the USD minimum", 26, "1.99", false},
		{"a FIXED plan that is not listed", 28, "401", true},
		{"local amounts the biller does not support", 30, "10", true},
		{"zero", 26, "0", true},
	} {
		if got, ok := BillCost(billerByID(t, test.biller), mustRat(t, test.amount), test.local); ok {
			t.Errorf("%s: priced at %s", test.label, got.FloatString(5))
		}
	}
	broken := billerByID(t, 26)
	broken.FX.Rate = "0"
	if _, ok := BillCost(broken, mustRat(t, "1000"), true); ok {
		t.Error("a zero rate cannot price a local order")
	}
}

func TestBillLimits(t *testing.T) {
	lo, hi := BillLimits(billerByID(t, 26), true)
	if lo.FloatString(0) != "1000" || hi.FloatString(0) != "310000" {
		t.Fatalf("local limits = %v..%v", lo, hi)
	}
	lo, hi = BillLimits(billerByID(t, 28), true)
	if lo.FloatString(0) != "400" || hi.FloatString(0) != "13500" {
		t.Fatalf("FIXED local limits = %v..%v", lo, hi)
	}
	lo, hi = BillLimits(billerByID(t, 30), true)
	if lo != nil || hi != nil {
		t.Fatalf("a biller without local amounts has no local limits: %v..%v", lo, hi)
	}
}
