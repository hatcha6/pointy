package services

import (
	"regexp"
	"sort"
	"strings"
)

// A phone number or an account is the customer's, and the relay keeps only its
// masked form ("+223•••••456"). A supplier's sentence may echo the full value
// ("Invalid recipient phone 22370123456"), so every sentence that is logged,
// stored on a ledger row or handed back to a shop goes through Redact first.

var longDigits = regexp.MustCompile(`\+?\d{6,}`)

// Redact hides in text every occurrence of the given secrets (a number as typed,
// its digits, an account) behind their masked form, and then any run of six or
// more digits, whatever it was.
func Redact(text string, secrets ...string) string {
	text = strings.TrimSpace(text)
	// The longest first: a national number is inside the same number with its
	// country code, and must not be cut out of it.
	ordered := make([]string, 0, len(secrets))
	for _, secret := range secrets {
		if secret = strings.TrimSpace(secret); len([]rune(secret)) >= 4 {
			ordered = append(ordered, secret)
		}
	}
	sort.SliceStable(ordered, func(i, j int) bool { return len(ordered[i]) > len(ordered[j]) })
	for _, secret := range ordered {
		text = regexp.MustCompile(`(?i)\+?`+regexp.QuoteMeta(strings.TrimPrefix(secret, "+"))).ReplaceAllString(text, maskTail(secret))
	}
	return longDigits.ReplaceAllString(text, "•••")
}

// scrubDigits is Redact with no known secret: only digit runs go.
func scrubDigits(text string) string { return Redact(text) }

// RedactError is an error's text, redacted.
func RedactError(err error, secrets ...string) string {
	if err == nil {
		return ""
	}
	return Redact(err.Error(), secrets...)
}
