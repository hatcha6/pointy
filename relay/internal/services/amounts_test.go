package services

import (
	"math/big"
	"testing"
)

func TestParseAndFormatAmounts(t *testing.T) {
	for _, c := range []struct{ in, out string }{
		{"5000", "5000"}, {"5000.00", "5000"}, {" 0.17 ", "0.17"}, {"10.50", "10.5"}, {"1.23456", "1.23456"}, {"0.00001", "0.00001"},
	} {
		value, ok := ParseAmount(c.in)
		if !ok {
			t.Fatalf("%q must parse", c.in)
		}
		if got := FormatAmount(value); got != c.out {
			t.Errorf("%q -> %q, want %q", c.in, got, c.out)
		}
	}
	for _, bad := range []string{"", "0", "0.0", "-5", "+5", "5e3", "1.234567", "abc", "5,000", ".5", "5.", "1 000", "9999999999999"} {
		if value, ok := ParseAmount(bad); ok {
			t.Errorf("%q must be refused, got %s", bad, value)
		}
	}
}

func TestGroupedAmounts(t *testing.T) {
	for _, c := range []struct{ in, out string }{
		{"5000", "5,000"}, {"500", "500"}, {"1250000", "1,250,000"}, {"0.17", "0.17"}, {"12345.5", "12,345.5"}, {"999", "999"}, {"1000", "1,000"},
	} {
		value, _ := ParseAmount(c.in)
		if got := FormatAmountGrouped(value); got != c.out {
			t.Errorf("%q -> %q, want %q", c.in, got, c.out)
		}
	}
}

func TestRoundDecimalsRoundsHalfUp(t *testing.T) {
	for _, c := range []struct {
		in     *big.Rat
		places int
		want   string
	}{
		{big.NewRat(505427002, 1000000), 2, "505.43"},
		{big.NewRat(1, 3), 2, "0.33"},
		{big.NewRat(5, 1000), 2, "0.01"},
		{big.NewRat(4, 1000), 2, "0.00"},
	} {
		if got := roundDecimals(c.in, c.places).FloatString(c.places); got != c.want {
			t.Errorf("%s: %s want %s", c.in, got, c.want)
		}
	}
}
