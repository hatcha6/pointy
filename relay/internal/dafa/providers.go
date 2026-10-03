package dafa

import (
	"strings"
	"unicode"
)

// Provider identifiers, as initiate takes them.
const (
	ProviderSadad      = "sadad"
	ProviderEdfali     = "edfali"
	ProviderMobiCash   = "mobicash"
	ProviderMoamalat   = "moamalat"
	ProviderYussorPay  = "yussor-pay"
	ProviderMasrafiPay = "masrafi-pay"
	ProviderSaharaPay  = "sahara-pay"
)

// Payer is what a provider needs to know about who is paying.
type Payer string

const (
	// PayerNone: bank cards. The payer types the card on Dafa's own page.
	PayerNone Payer = ""
	// PayerPhone: the mobile number the payer's wallet is registered to.
	PayerPhone Payer = "phone"
	// PayerCard: the payer's wallet card number.
	PayerCard Payer = "card"
)

// Provider is one way to pay through Dafa.
type Provider struct {
	ID    string
	Payer Payer
	// BirthYear is Sadad's second factor, asked alongside the phone.
	BirthYear bool
	// HostedPage means no OTP: the answer to initiate carries the page the
	// payer pays on, and the payment confirms itself there.
	HostedPage bool
}

// providers is every method the docs list, in the docs' order.
var providers = []Provider{
	{ID: ProviderSadad, Payer: PayerPhone, BirthYear: true},
	{ID: ProviderEdfali, Payer: PayerPhone},
	{ID: ProviderMobiCash, Payer: PayerCard},
	{ID: ProviderMoamalat, HostedPage: true},
	{ID: ProviderYussorPay, Payer: PayerCard},
	{ID: ProviderMasrafiPay, Payer: PayerCard},
	{ID: ProviderSaharaPay, Payer: PayerCard},
}

// Providers returns every payment method Dafa offers.
func Providers() []Provider {
	return append([]Provider(nil), providers...)
}

// LookupProvider finds a provider by its identifier.
func LookupProvider(id string) (Provider, bool) {
	for _, provider := range providers {
		if provider.ID == id {
			return provider, true
		}
	}
	return Provider{}, false
}

// Digits returns raw with Arabic-Indic digits made ASCII and spaces, dashes,
// dots and parentheses dropped — how a number typed on an Arabic keyboard, or
// copied from a contact card, reaches the relay. ok is false if anything else
// is left that is not a digit (a leading + is kept for the caller to read).
func Digits(raw string) (string, bool) {
	var builder strings.Builder
	for index, r := range strings.TrimSpace(raw) {
		switch {
		case r >= '0' && r <= '9':
			builder.WriteRune(r)
		case r >= '٠' && r <= '٩':
			builder.WriteRune('0' + (r - '٠'))
		case r >= '۰' && r <= '۹':
			builder.WriteRune('0' + (r - '۰'))
		case r == '+' && index == 0:
			builder.WriteRune(r)
		case unicode.IsSpace(r) || r == '-' || r == '.' || r == '(' || r == ')' || r == '‏' || r == '‎':
		default:
			return "", false
		}
	}
	return builder.String(), true
}

// NormalizePhone turns a Libyan mobile number as people write it — 0912345678,
// 091-234-5678, +218 91 234 5678, 00218912345678 — into the nine digits the
// docs' own example sends (912345678). ok is false for anything that is not a
// Libyan mobile (9X and seven more digits).
func NormalizePhone(raw string) (string, bool) {
	digits, ok := Digits(raw)
	if !ok {
		return "", false
	}
	digits = strings.TrimPrefix(digits, "+")
	switch {
	case strings.HasPrefix(digits, "00218"):
		digits = digits[5:]
	case strings.HasPrefix(digits, "218") && len(digits) == 12:
		digits = digits[3:]
	case strings.HasPrefix(digits, "0") && len(digits) == 10:
		digits = digits[1:]
	}
	if len(digits) != 9 || digits[0] != '9' {
		return "", false
	}
	return digits, true
}

// NormalizeCardNumber keeps the digits of a wallet card number: 6 to 19 of
// them once spaces and dashes are gone. The providers do not publish their
// formats, so the relay checks only that it is a number; Dafa judges the rest.
func NormalizeCardNumber(raw string) (string, bool) {
	digits, ok := Digits(raw)
	if !ok || strings.HasPrefix(digits, "+") || len(digits) < 6 || len(digits) > 19 {
		return "", false
	}
	return digits, true
}

// NormalizeOTP keeps the digits of a one-time code: 4 to 8 of them.
func NormalizeOTP(raw string) (string, bool) {
	digits, ok := Digits(raw)
	if !ok || strings.HasPrefix(digits, "+") || len(digits) < 4 || len(digits) > 8 {
		return "", false
	}
	return digits, true
}
