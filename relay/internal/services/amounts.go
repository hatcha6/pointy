package services

import (
	"math/big"
	"regexp"
	"strings"
)

// Amounts of foreign currency cross the wire as plain decimal strings. They are
// *big.Rat inside the relay and never a float: an amount that is off by a
// rounding error is a different order.

// amountPattern is a positive decimal a person or a program can write: digits,
// at most five decimals (Reloadly's own precision: beyond it a debit drifts from
// its formula), no sign and no exponent.
var amountPattern = regexp.MustCompile(`^\d{1,12}(\.\d{1,5})?$`)

// maxAmountDecimals is how many decimals an amount keeps on the wire.
const maxAmountDecimals = 5

// ParseAmount reads a decimal amount. It refuses zero, anything signed, in
// exponent form or with more than five decimals.
func ParseAmount(raw string) (*big.Rat, bool) {
	raw = strings.TrimSpace(raw)
	if !amountPattern.MatchString(raw) {
		return nil, false
	}
	value, ok := new(big.Rat).SetString(raw)
	if !ok || value.Sign() <= 0 {
		return nil, false
	}
	return value, true
}

// zeroDecimalCurrencies are the currencies with no minor unit (ISO 4217 gives
// them none): an amount of them is whole, and a fractional one is not something
// anybody can be credited.
var zeroDecimalCurrencies = map[string]bool{
	"XOF": true, "XAF": true, "XPF": true, "JPY": true, "KRW": true, "VND": true, "UGX": true, "RWF": true,
	"GNF": true, "PYG": true, "CLP": true, "ISK": true, "KMF": true, "DJF": true, "BIF": true, "VUV": true,
}

// CurrencyDecimals is how many decimals an amount in a currency may have: none
// for the currencies without a minor unit, two for every other (the three-decimal
// dinars are sold in whole units and cents all the same). It limits what a shop
// may ask for, never the five-decimal dollar amount the relay works out to place
// an order.
func CurrencyDecimals(currency string) int {
	if zeroDecimalCurrencies[strings.ToUpper(strings.TrimSpace(currency))] {
		return 0
	}
	return 2
}

// amountFitsCurrency reports whether an amount has no more decimals than its
// currency has (5000.00 is 5000: only the value counts).
func amountFitsCurrency(amount *big.Rat, currency string) bool {
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(CurrencyDecimals(currency))), nil)
	return new(big.Rat).Mul(amount, new(big.Rat).SetInt(scale)).IsInt()
}

// refuseDecimals is the refusal of an amount with more decimals than its
// currency has.
func refuseDecimals(currency string) *Refusal {
	if CurrencyDecimals(currency) == 0 {
		return refuseUnprocessable(CodeInvalidAmount, "an amount in "+strings.ToUpper(currency)+" is a whole number")
	}
	return refuseUnprocessable(CodeInvalidAmount, "an amount in "+strings.ToUpper(currency)+" has at most two decimals")
}

// FormatAmount writes an amount the way it crosses the wire: no trailing
// zeros ("5000", "0.17", "10.5"), at most five decimals.
func FormatAmount(value *big.Rat) string {
	if value == nil {
		return ""
	}
	text := value.FloatString(maxAmountDecimals)
	if strings.Contains(text, ".") {
		text = strings.TrimRight(text, "0")
		text = strings.TrimSuffix(text, ".")
	}
	if text == "" || text == "-0" {
		return "0"
	}
	return text
}

// FormatAmountGrouped writes an amount for a statement line: thousands
// separated by a comma ("5,000", "1,250,000", "0.17").
func FormatAmountGrouped(value *big.Rat) string {
	text := FormatAmount(value)
	whole, fraction, hasFraction := strings.Cut(text, ".")
	negative := strings.HasPrefix(whole, "-")
	whole = strings.TrimPrefix(whole, "-")
	var grouped strings.Builder
	for i, digit := range whole {
		if i > 0 && (len(whole)-i)%3 == 0 {
			grouped.WriteByte(',')
		}
		grouped.WriteRune(digit)
	}
	out := grouped.String()
	if negative {
		out = "-" + out
	}
	if hasFraction {
		out += "." + fraction
	}
	return out
}

// sameAmount reports whether two amounts are equal as numbers.
func sameAmount(a, b *big.Rat) bool {
	return a != nil && b != nil && a.Cmp(b) == 0
}

// roundDecimals rounds a value to the given number of decimals, half away from
// zero.
func roundDecimals(value *big.Rat, places int) *big.Rat {
	if value == nil {
		return nil
	}
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(places)), nil)
	scaled := new(big.Rat).Mul(value, new(big.Rat).SetInt(scale))
	quotient, remainder := new(big.Int).QuoRem(scaled.Num(), scaled.Denom(), new(big.Int))
	twice := new(big.Int).Abs(remainder)
	twice.Lsh(twice, 1)
	if twice.Cmp(scaled.Denom()) >= 0 {
		if scaled.Sign() < 0 {
			quotient.Sub(quotient, big.NewInt(1))
		} else {
			quotient.Add(quotient, big.NewInt(1))
		}
	}
	return new(big.Rat).SetFrac(quotient, scale)
}

// ceilDecimals rounds a value UP to the given number of decimals.
func ceilDecimals(value *big.Rat, places int) *big.Rat {
	if value == nil {
		return nil
	}
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(places)), nil)
	scaled := new(big.Rat).Mul(value, new(big.Rat).SetInt(scale))
	quotient := new(big.Int).Div(scaled.Num(), scaled.Denom())
	if !scaled.IsInt() {
		quotient.Add(quotient, big.NewInt(1))
	}
	return new(big.Rat).SetFrac(quotient, scale)
}
