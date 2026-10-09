package services

import (
	"errors"
	"fmt"
	"sort"
	"strings"
)

// A cashier types a phone number the way the customer says it: national digits,
// with or without the trunk zero ("0803 123 4567"), or international ("+234 803
// 123 4567", "00234…", "234803…"), in Latin or Arabic-Indic digits. ParsePhone
// turns any of those into one Phone, which knows how to write itself as E.164, as
// the digits Reloadly takes and as the masked form the ledger keeps. Nothing here
// calls anyone: whether the number really exists is Reloadly's to say.

// ErrInvalidPhone is a number that cannot be a phone number of the country.
var ErrInvalidPhone = errors.New("not a plausible phone number")

// Phone is a phone number split the way the rest of the relay needs it.
type Phone struct {
	// Country is the ISO 3166-1 alpha-2 code the number was read for.
	Country string
	// Dial is the country code, digits only ("223"). The countries of the North
	// American plan all dial "1"; their area code is part of National.
	Dial string
	// National is what follows the country code, without a trunk zero.
	National string
}

// E164 is the number as "+<country code><national digits>".
func (p Phone) E164() string { return "+" + p.Dial + p.National }

// Digits is the international form without the plus: "22370123456".
func (p Phone) Digits() string { return p.Dial + p.National }

// Masked is the number as the ledger keeps it: country code and the last few
// digits, the rest hidden ("+223•••••456").
func (p Phone) Masked() string {
	return "+" + p.Dial + maskTail(p.National)
}

// Detected is the number as the detect endpoint answers it.
func (p Phone) Detected() DetectedPhone {
	return DetectedPhone{E164: p.E164(), National: p.National, Country: p.Country}
}

// maskBullet hides a digit in a masked value.
const maskBullet = "•"

// maskTail hides all but the last few characters of a value; the shorter the
// value the fewer it shows, so a short number is never given away.
func maskTail(value string) string {
	runes := []rune(value)
	keep := 3
	switch {
	case len(runes) <= 4:
		keep = 1
	case len(runes) <= 7:
		keep = 2
	}
	if keep >= len(runes) {
		keep = 0
	}
	return strings.Repeat(maskBullet, len(runes)-keep) + string(runes[len(runes)-keep:])
}

// MaskAccount is a bill account (a meter, a subscriber number) as the ledger keeps
// it: the last few characters only.
func MaskAccount(account string) string { return maskTail(strings.TrimSpace(account)) }

// nationalShape is how many digits follow the country code (trunk zero not
// counted). It only helps to tell "22370123456" (a number with its country code)
// from "70123456" (a national one); a country it does not know is read by a
// generic rule, and Reloadly has the last word either way.
//
// keepZeroAt is the length at which a leading zero is a digit of the number and
// not a trunk prefix (Ivory Coast and Benin renumbered with a leading 0 and
// write their numbers with ten digits, zero included).
type nationalShape struct{ min, max, keepZeroAt int }

var nationalShapes = map[string]nationalShape{
	"AE": {9, 9, 0}, "AF": {9, 9, 0}, "AL": {9, 9, 0}, "AM": {8, 8, 0}, "AO": {9, 9, 0}, "AR": {10, 11, 0},
	"AT": {10, 11, 0}, "AU": {9, 9, 0}, "AZ": {9, 9, 0}, "BD": {10, 10, 0}, "BE": {8, 9, 0}, "BF": {8, 8, 0},
	"BH": {8, 8, 0}, "BI": {8, 8, 0}, "BJ": {10, 10, 10}, "BO": {8, 8, 0}, "BR": {10, 11, 0}, "BY": {9, 9, 0},
	"CA": {10, 10, 0}, "CD": {9, 9, 0}, "CG": {9, 9, 0}, "CH": {9, 9, 0}, "CI": {10, 10, 10}, "CL": {9, 9, 0},
	"CM": {9, 9, 0}, "CN": {11, 11, 0}, "CO": {10, 10, 0}, "CU": {8, 8, 0}, "CV": {7, 7, 0}, "CY": {8, 8, 0},
	"DE": {10, 11, 0}, "DK": {8, 8, 0}, "DO": {10, 10, 0}, "DZ": {9, 9, 0}, "EC": {9, 9, 0}, "EG": {10, 10, 0},
	"ES": {9, 9, 0}, "ET": {9, 9, 0}, "FR": {9, 9, 0}, "GA": {7, 8, 0}, "GB": {10, 10, 0}, "GE": {9, 9, 0},
	"GH": {9, 9, 0}, "GM": {7, 7, 0}, "GN": {9, 9, 0}, "GR": {10, 10, 0}, "GW": {7, 9, 0}, "GY": {7, 7, 0},
	"HN": {8, 8, 0}, "HT": {8, 8, 0}, "ID": {9, 12, 0}, "IE": {9, 9, 0}, "IL": {9, 9, 0}, "IN": {10, 10, 0},
	"IQ": {10, 10, 0}, "IR": {10, 10, 0}, "IT": {9, 10, 0}, "JM": {10, 10, 0}, "JO": {9, 9, 0}, "KE": {9, 9, 0},
	"KG": {9, 9, 0}, "KH": {8, 9, 0}, "KM": {7, 7, 0}, "KR": {9, 10, 0}, "KW": {8, 8, 0}, "KZ": {10, 10, 0},
	"LA": {8, 10, 0}, "LB": {7, 8, 0}, "LK": {9, 9, 0}, "LR": {7, 9, 0}, "LU": {8, 9, 0}, "LY": {9, 9, 0},
	"MA": {9, 9, 0}, "MD": {8, 8, 0}, "MG": {9, 9, 0}, "MK": {8, 8, 0}, "ML": {8, 8, 0}, "MM": {8, 10, 0},
	"MR": {8, 8, 0}, "MW": {9, 9, 0}, "MX": {10, 10, 0}, "MY": {9, 10, 0}, "MZ": {9, 9, 0}, "NA": {9, 9, 0},
	"NE": {8, 8, 0}, "NG": {10, 10, 0}, "NI": {8, 8, 0}, "NL": {9, 9, 0}, "NP": {10, 10, 0}, "OM": {8, 8, 0},
	"PA": {8, 8, 0}, "PE": {9, 9, 0}, "PH": {10, 10, 0}, "PK": {10, 10, 0}, "PL": {9, 9, 0}, "PR": {10, 10, 0},
	"PS": {9, 9, 0}, "PT": {9, 9, 0}, "PY": {9, 9, 0}, "QA": {8, 8, 0}, "RO": {9, 9, 0}, "RU": {10, 10, 0},
	"RW": {9, 9, 0}, "SA": {9, 9, 0}, "SD": {9, 9, 0}, "SE": {9, 9, 0}, "SL": {8, 8, 0}, "SN": {9, 9, 0},
	"SO": {7, 9, 0}, "SV": {8, 8, 0}, "SY": {9, 9, 0}, "TD": {8, 8, 0}, "TG": {8, 8, 0}, "TH": {9, 9, 0},
	"TN": {8, 8, 0}, "TR": {10, 10, 0}, "TT": {10, 10, 0}, "TZ": {9, 9, 0}, "UA": {9, 9, 0}, "UG": {9, 9, 0},
	"US": {10, 10, 0}, "UY": {8, 9, 0}, "UZ": {9, 9, 0}, "VE": {10, 10, 0}, "VN": {9, 10, 0}, "YE": {9, 9, 0},
	"ZA": {9, 9, 0}, "ZM": {9, 9, 0}, "ZW": {9, 9, 0},
	// The rest of the North American plan: an area code and seven digits.
	"AG": {10, 10, 0}, "AI": {10, 10, 0}, "AS": {10, 10, 0}, "BB": {10, 10, 0}, "BM": {10, 10, 0}, "BS": {10, 10, 0},
	"DM": {10, 10, 0}, "GD": {10, 10, 0}, "KN": {10, 10, 0}, "KY": {10, 10, 0}, "LC": {10, 10, 0}, "MS": {10, 10, 0},
	"TC": {10, 10, 0}, "VC": {10, 10, 0}, "VG": {10, 10, 0},
	// The other countries Reloadly serves (small territories get the range their
	// mobile and fixed lines span).
	"AN": {7, 8, 0}, "AW": {7, 7, 0}, "BW": {7, 8, 0}, "BZ": {7, 7, 0}, "CF": {8, 8, 0}, "CR": {8, 8, 0},
	"FJ": {7, 7, 0}, "GT": {8, 8, 0}, "LT": {8, 8, 0}, "MQ": {9, 9, 0}, "NR": {7, 7, 0}, "PG": {7, 8, 0},
	"SG": {8, 8, 0}, "SR": {6, 7, 0}, "SZ": {8, 8, 0}, "TJ": {9, 9, 0}, "TM": {8, 8, 0}, "TO": {5, 7, 0},
	"VU": {5, 7, 0}, "WS": {5, 7, 0},
}

// zeroLeading are the countries whose numbers can begin with a 0 that belongs to
// the number and is not a trunk prefix (Côte d'Ivoire and Benin renumbered that
// way, Congo and Gabon always had, Italian fixed lines do). Everywhere else a
// number of the table that still begins with 0 once the trunk zero is gone is a
// mistake.
var zeroLeading = map[string]bool{"CI": true, "BJ": true, "CG": true, "GA": true, "IT": true}

// Plausible national lengths when a country is not in the table above, and the
// bounds of any number: E.164 allows 15 digits in all.
const (
	minNationalDigits = 5
	maxPhoneDigits    = 15
	// unknownInternationalLength is how long a number must be before one that
	// starts with a country's own code is taken to carry it, for a country
	// whose national length is not known.
	unknownInternationalLength = 11
	unknownRestLength          = 6
)

func shapeOf(country string) (nationalShape, bool) {
	shape, ok := nationalShapes[country]
	return shape, ok
}

func (s nationalShape) has(length int) bool { return length >= s.min && length <= s.max }

// phoneMarker says how a typed number announced that it is international.
type phoneMarker int

const (
	markerNone phoneMarker = iota
	markerPlus
	markerDoubleZero
)

// ParsePhone reads a number typed for a country. dialCodes are the country's
// calling codes as Reloadly lists them ("223", "+223", or "1809" for the Dominican
// Republic, whose number plan is the North American one).
//
// The rules, in short: Arabic-Indic digits, spaces, dashes, dots and brackets are
// accepted; a leading "+" or "00" means the country code follows and must be the
// country's; a number without either is taken as national, unless it starts with
// the country code and has the length of a country-code number, not of a
// national one; a trunk zero is dropped when what remains is a plausible number.
// The result is ErrInvalidPhone-wrapped when it cannot be a number of the
// country.
func ParsePhone(input, country string, dialCodes []string) (Phone, error) {
	return parsePhone(input, country, dialCodes, true)
}

// parsePhone is ParsePhone, strictly (a number must have the lengths of its
// country) or not. The lenient reading is for recognising a number an order was
// once placed for, not for accepting one: numbers were taken at any plausible
// length once, and an order placed then is still compared by what it was.
func parsePhone(input, country string, dialCodes []string, strict bool) (Phone, error) {
	country = strings.ToUpper(strings.TrimSpace(country))
	dials := effectiveDials(dialCodes)
	if country == "" || len(dials) == 0 {
		return Phone{}, fmt.Errorf("%w: the country has no calling code", ErrInvalidPhone)
	}
	digits, marker, ok := cleanPhoneInput(input)
	if !ok || digits == "" {
		return Phone{}, fmt.Errorf("%w: digits only", ErrInvalidPhone)
	}
	if marker != markerNone {
		dial, rest, ok := cutDial(digits, dials)
		if !ok {
			return Phone{}, fmt.Errorf("%w: it does not start with the calling code of %s", ErrInvalidPhone, country)
		}
		return finishPhone(country, dial, trimTrunk(country, rest), strict)
	}
	if dial, rest, ok := cutDial(digits, dials); ok && carriesCountryCode(country, digits, rest) {
		return finishPhone(country, dial, trimTrunk(country, rest), strict)
	}
	return finishPhone(country, dials[0], trimTrunk(country, digits), strict)
}

// finishPhone checks the length of a number that has been told from its country
// code and its trunk zero. A country in the table has the lengths of its numbers
// (and, unless its numbers begin with a 0 of their own, no leading zero left); any
// other has the generic rule, a plausible length for any number. The refusal
// says how many digits, never which.
func finishPhone(country, dial, national string, strict bool) (Phone, error) {
	if len(national) < minNationalDigits || len(dial)+len(national) > maxPhoneDigits {
		return Phone{}, fmt.Errorf("%w: %d digits is not a plausible length", ErrInvalidPhone, len(national))
	}
	if shape, known := shapeOf(country); known && strict {
		if !shape.has(len(national)) {
			return Phone{}, fmt.Errorf("%w: a number of %s has %s, this one has %d", ErrInvalidPhone, country, shape.describe(), len(national))
		}
		if national[0] == '0' && !zeroLeading[country] {
			return Phone{}, fmt.Errorf("%w: a number of %s does not begin with 0 once the trunk zero is dropped", ErrInvalidPhone, country)
		}
	}
	return Phone{Country: country, Dial: dial, National: national}, nil
}

// describe says how many digits the numbers of a country have.
func (s nationalShape) describe() string {
	if s.min == s.max {
		return fmt.Sprintf("%d digits", s.min)
	}
	return fmt.Sprintf("%d to %d digits", s.min, s.max)
}

// carriesCountryCode decides that digits (which start with the country code)
// are an international number and not a national one that happens to begin with
// the same digits.
func carriesCountryCode(country, digits, rest string) bool {
	if shape, known := shapeOf(country); known {
		if !shape.has(len(rest)) && !(strings.HasPrefix(rest, "0") && shape.has(len(rest)-1)) {
			return false
		}
		// The whole string is itself a plausible national number: typed locally.
		if shape.has(len(digits)) || (strings.HasPrefix(digits, "0") && shape.has(len(digits)-1)) {
			return false
		}
		return true
	}
	return len(digits) >= unknownInternationalLength && len(rest) >= unknownRestLength
}

// trimTrunk drops a leading trunk zero when the rest is a plausible number.
func trimTrunk(country, digits string) string {
	if len(digits) < 2 || digits[0] != '0' {
		return digits
	}
	rest := digits[1:]
	if shape, known := shapeOf(country); known {
		if shape.keepZeroAt == len(digits) {
			return digits
		}
		if shape.has(len(rest)) {
			return rest
		}
		return digits
	}
	if len(rest) >= minNationalDigits {
		return rest
	}
	return digits
}

// effectiveDials normalizes a country's calling codes to bare digits. The
// countries of the North American plan are listed by Reloadly with their area
// codes ("1868"): they all dial "1", and the area code stays in the national part.
func effectiveDials(codes []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, code := range codes {
		code = strings.TrimLeft(strings.TrimSpace(code), "+")
		if code == "" || strings.Trim(code, "0123456789") != "" {
			continue
		}
		if strings.HasPrefix(code, "1") && len(code) == 4 {
			code = "1"
		}
		if !seen[code] {
			seen[code] = true
			out = append(out, code)
		}
	}
	return out
}

// cutDial splits digits after the longest of the country's calling codes it
// starts with.
func cutDial(digits string, dials []string) (dial, rest string, ok bool) {
	candidates := append([]string(nil), dials...)
	sort.SliceStable(candidates, func(i, j int) bool { return len(candidates[i]) > len(candidates[j]) })
	for _, candidate := range candidates {
		if strings.HasPrefix(digits, candidate) && len(digits) > len(candidate) {
			return candidate, digits[len(candidate):], true
		}
	}
	return "", "", false
}

// cleanPhoneInput reads what was typed: ASCII digits, Arabic-Indic and
// Persian digits, a leading plus, and the separators people put in numbers.
// Anything else (a letter, a second plus) is not a phone number. A leading "00"
// is reported as a marker and removed.
func cleanPhoneInput(input string) (digits string, marker phoneMarker, ok bool) {
	var out strings.Builder
	for _, r := range input {
		switch {
		case r >= '0' && r <= '9':
			out.WriteRune(r)
		case r >= '٠' && r <= '٩':
			out.WriteRune('0' + (r - '٠'))
		case r >= '۰' && r <= '۹':
			out.WriteRune('0' + (r - '۰'))
		case r == '+' || r == '＋':
			if out.Len() > 0 || marker != markerNone {
				return "", markerNone, false
			}
			marker = markerPlus
		case isPhoneSeparator(r):
		default:
			return "", markerNone, false
		}
	}
	digits = out.String()
	if marker == markerNone && strings.HasPrefix(digits, "00") && len(digits) > 2 {
		digits, marker = digits[2:], markerDoubleZero
	}
	return digits, marker, true
}

func isPhoneSeparator(r rune) bool {
	switch r {
	case ' ', '\t', '-', '.', '(', ')', '/',
		0x00a0, 0x2009, 0x202f, // no-break and thin spaces
		0x2010, 0x2013, 0x2014, // hyphen, en dash, em dash
		0x200b, 0x200c, 0x200d, 0xfeff, // zero-width marks
		0x200e, 0x200f, 0x061c, // direction marks (left-to-right, right-to-left, Arabic letter mark)
		0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069: // embeddings and isolates
		return true
	}
	return false
}
