package services

import (
	"fmt"
	"math/big"
	"strings"
	"testing"

	"pointy/relay/internal/reloadly"
)

func rn(s string) *big.Rat {
	v, ok := new(big.Rat).SetString(s)
	if !ok {
		panic("bad number " + s)
	}
	return v
}

func formatRats(list []*big.Rat) string {
	out := make([]string, len(list))
	for i, v := range list {
		out[i] = FormatAmount(v)
	}
	return strings.Join(out, " ")
}

func TestSuggestForRealisticRanges(t *testing.T) {
	cases := []struct {
		name     string
		in       SuggestInput
		want     string
		popular  string
		atLeast3 bool
	}{
		// Nigeria: a biller from 1,000 to 300,000 naira at 1528 per dollar. The
		// minimum is round and below the usual window, so it is offered too.
		{"NGN biller", SuggestInput{Min: rn("1000"), Max: rn("300000"), PerUSD: rn("1528")}, "1000 2000 5000 10000 20000 50000", "", true},
		// Mali: Orange, 1,967 to 32,800 CFA francs at 505 per dollar.
		{"XOF operator", SuggestInput{Min: rn("1967"), Max: rn("32800"), PerUSD: rn("505"), Popular: rn("5000")}, "2000 5000 10000 20000", "5000", true},
		// Egypt: pounds at about 48 per dollar.
		{"EGP operator", SuggestInput{Min: rn("5"), Max: rn("1000"), PerUSD: rn("48")}, "100 200 500 1000", "", true},
		// Ghana: cedis at about 11 per dollar.
		{"GHS operator", SuggestInput{Min: rn("1"), Max: rn("500"), PerUSD: rn("11")}, "20 50 100 200 500", "", true},
		// Tunisia: dinars at about 3.1 per dollar.
		{"TND operator", SuggestInput{Min: rn("1"), Max: rn("100"), PerUSD: rn("3.1")}, "5 10 20 50 100", "", true},
		// Pakistan: rupees at about 280 per dollar.
		{"PKR operator", SuggestInput{Min: rn("100"), Max: rn("10000"), PerUSD: rn("280")}, "500 1000 2000 5000 10000", "", true},
		// Bangladesh: taka at about 120 per dollar.
		{"BDT operator", SuggestInput{Min: rn("20"), Max: rn("5000"), PerUSD: rn("120")}, "200 500 1000 2000 5000", "", true},
		// Dollars: no rate.
		{"USD operator", SuggestInput{Min: rn("0.2"), Max: rn("98.93"), Popular: rn("15")}, "2 5 10 15 20 50", "15", true},
		// An odd minimum is not offered.
		{"odd minimum", SuggestInput{Min: rn("1967"), Max: rn("32800"), PerUSD: rn("505")}, "2000 5000 10000 20000", "", true},
		// Only two round amounts fit: the largest allowed is the third tile.
		{"two round amounts", SuggestInput{Min: rn("20"), Max: rn("65")}, "20 50 65", "", false},
		// A range of one amount is that amount.
		{"one amount", SuggestInput{Min: rn("1234"), Max: rn("1234"), PerUSD: rn("505")}, "1234", "", false},
		// A tiny range with no round amount offers its ends.
		{"tiny range", SuggestInput{Min: rn("3"), Max: rn("4")}, "3 4", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Suggest(c.in)
			if text := formatRats(got); text != c.want {
				t.Fatalf("got %s want %s", text, c.want)
			}
			checkTiles(t, c.in, got)
			if c.popular != "" {
				found := false
				for _, v := range got {
					found = found || v.Cmp(rn(c.popular)) == 0
				}
				if !found {
					t.Fatalf("the popular amount %s must be a tile: %s", c.popular, formatRats(got))
				}
			}
		})
	}
}

func checkTiles(t *testing.T, in SuggestInput, got []*big.Rat) {
	t.Helper()
	if len(got) == 0 || len(got) > 6 {
		t.Fatalf("1 to 6 tiles, got %s", formatRats(got))
	}
	for i, v := range got {
		if v.Cmp(in.Min) < 0 || v.Cmp(in.Max) > 0 {
			t.Fatalf("%s is outside [%s, %s]", FormatAmount(v), FormatAmount(in.Min), FormatAmount(in.Max))
		}
		if i > 0 && got[i-1].Cmp(v) >= 0 {
			t.Fatalf("tiles must ascend without repeats: %s", formatRats(got))
		}
	}
}

func TestSuggestAlwaysKeepsTheMostPopularAmount(t *testing.T) {
	// More round amounts than room, and a popular amount that is not round:
	// it is one of the six, and the six still span the range.
	in := SuggestInput{Min: rn("100"), Max: rn("100000"), PerUSD: rn("100"), Popular: rn("750")}
	got := Suggest(in)
	checkTiles(t, in, got)
	if !strings.Contains(" "+formatRats(got)+" ", " 750 ") {
		t.Fatalf("popular 750 missing: %s", formatRats(got))
	}
	// A popular amount outside the range is ignored.
	outside := SuggestInput{Min: rn("100"), Max: rn("1000"), PerUSD: rn("100"), Popular: rn("5000")}
	if strings.Contains(formatRats(Suggest(outside)), "5000") {
		t.Fatalf("an invalid popular amount must not appear: %s", formatRats(Suggest(outside)))
	}
}

func TestSuggestRefusesAnUnusableRange(t *testing.T) {
	for _, in := range []SuggestInput{
		{},
		{Min: rn("10"), Max: rn("5")},
		{Min: rn("0"), Max: rn("5")},
		{Min: rn("10")},
	} {
		if got := Suggest(in); got != nil {
			t.Errorf("%+v must give none, got %s", in, formatRats(got))
		}
	}
}

func TestSuggestOverEveryRangeInTheFixtures(t *testing.T) {
	raw, err := FixtureSource{}.Load(nil)
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, op := range raw.Operators {
		if !plainAirtime(op) || op.DenominationType != reloadly.Range {
			continue
		}
		local := op.SupportsLocalAmounts && hasAirtimeAmounts(op, true)
		lo, hi := reloadly.AirtimeLimits(op, local)
		if lo == nil || hi == nil {
			continue
		}
		in := SuggestInput{Min: lo, Max: hi}
		if local {
			in.PerUSD = rat(op.FX.Rate)
			in.Popular = rat(op.MostPopularLocalAmount)
		} else {
			in.Popular = rat(op.MostPopularAmount)
		}
		got := Suggest(in)
		checkTiles(t, in, got)
		checked++
		if testing.Verbose() {
			t.Log(fmt.Sprintf("%-32s %s..%s (%s) -> %s", op.Name, FormatAmount(lo), FormatAmount(hi), map[bool]string{true: op.DestinationCurrencyCode, false: "USD"}[local], formatRats(got)))
		}
	}
	if checked < 40 {
		t.Fatalf("expected many range operators in the fixture, checked %d", checked)
	}
}
