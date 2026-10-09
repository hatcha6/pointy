package services

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
)

func TestParsePhoneAcrossCountries(t *testing.T) {
	cases := []struct {
		name     string
		input    string
		country  string
		dial     []string
		national string
		e164     string
	}{
		// Mali: 8 digits, no trunk zero.
		{"mali national", "70123456", "ML", []string{"+223"}, "70123456", "+22370123456"},
		{"mali spaced", "70 12 34 56", "ML", []string{"+223"}, "70123456", "+22370123456"},
		{"mali plus", "+223 70 12 34 56", "ML", []string{"+223"}, "70123456", "+22370123456"},
		{"mali double zero", "00223 70123456", "ML", []string{"+223"}, "70123456", "+22370123456"},
		{"mali country code only", "22370123456", "ML", []string{"+223"}, "70123456", "+22370123456"},
		{"mali stray trunk zero", "070123456", "ML", []string{"+223"}, "70123456", "+22370123456"},
		{"mali arabic digits", "٧٠١٢٣٤٥٦", "ML", []string{"+223"}, "70123456", "+22370123456"},
		{"mali dashes", "70-12-34-56", "ML", []string{"+223"}, "70123456", "+22370123456"},
		// Niger: 8 digits starting with 9.
		{"niger national", "96123456", "NE", []string{"+227"}, "96123456", "+22796123456"},
		{"niger international", "+227 96 12 34 56", "NE", []string{"+227"}, "96123456", "+22796123456"},
		{"niger bare code", "22796123456", "NE", []string{"+227"}, "96123456", "+22796123456"},
		// Nigeria: trunk zero, 10 digits.
		{"nigeria trunk", "0803 123 4567", "NG", []string{"+234"}, "8031234567", "+2348031234567"},
		{"nigeria no trunk", "8031234567", "NG", []string{"+234"}, "8031234567", "+2348031234567"},
		{"nigeria plus", "+2348031234567", "NG", []string{"+234"}, "8031234567", "+2348031234567"},
		{"nigeria plus with trunk", "+234 (0)803 123 4567", "NG", []string{"+234"}, "8031234567", "+2348031234567"},
		{"nigeria bare code", "2348031234567", "NG", []string{"+234"}, "8031234567", "+2348031234567"},
		{"nigeria 00", "002348031234567", "NG", []string{"+234"}, "8031234567", "+2348031234567"},
		// Egypt.
		{"egypt trunk", "010 1234 5678", "EG", []string{"+20"}, "1012345678", "+201012345678"},
		{"egypt bare code", "201012345678", "EG", []string{"+20"}, "1012345678", "+201012345678"},
		{"egypt plus", "+20 10 1234 5678", "EG", []string{"+20"}, "1012345678", "+201012345678"},
		{"egypt arabic digits", "٠١٠١٢٣٤٥٦٧٨", "EG", []string{"+20"}, "1012345678", "+201012345678"},
		// Turkey.
		{"turkey trunk", "0532 123 45 67", "TR", []string{"+90"}, "5321234567", "+905321234567"},
		{"turkey bare code", "905321234567", "TR", []string{"+90"}, "5321234567", "+905321234567"},
		// Pakistan.
		{"pakistan trunk", "0300-1234567", "PK", []string{"+92"}, "3001234567", "+923001234567"},
		{"pakistan plus", "+92 300 1234567", "PK", []string{"+92"}, "3001234567", "+923001234567"},
		// India: a national number can start with the country code's digits.
		{"india starts with 91", "9198765432", "IN", []string{"+91"}, "9198765432", "+919198765432"},
		{"india bare code", "919876543210", "IN", []string{"+91"}, "9876543210", "+919876543210"},
		{"india trunk", "09876543210", "IN", []string{"+91"}, "9876543210", "+919876543210"},
		// Ghana, Senegal, Tunisia, Morocco, Algeria, Philippines, Bangladesh.
		{"ghana trunk", "024 123 4567", "GH", []string{"+233"}, "241234567", "+233241234567"},
		{"senegal", "77 123 45 67", "SN", []string{"+221"}, "771234567", "+221771234567"},
		{"senegal bare code", "221771234567", "SN", []string{"+221"}, "771234567", "+221771234567"},
		{"tunisia", "20 123 456", "TN", []string{"+216"}, "20123456", "+21620123456"},
		{"tunisia bare code", "21620123456", "TN", []string{"+216"}, "20123456", "+21620123456"},
		{"morocco trunk", "0612345678", "MA", []string{"+212"}, "612345678", "+212612345678"},
		{"algeria trunk", "0551234567", "DZ", []string{"+213"}, "551234567", "+213551234567"},
		{"philippines trunk", "0917 123 4567", "PH", []string{"+63"}, "9171234567", "+639171234567"},
		{"philippines plus", "+63 917 123 4567", "PH", []string{"+63"}, "9171234567", "+639171234567"},
		{"bangladesh trunk", "01712-345678", "BD", []string{"+880"}, "1712345678", "+8801712345678"},
		{"bangladesh bare code", "8801712345678", "BD", []string{"+880"}, "1712345678", "+8801712345678"},
		// Cameroon, Burkina, Côte d'Ivoire, Guinea, Gambia.
		{"cameroon", "6 71 23 45 67", "CM", []string{"+237"}, "671234567", "+237671234567"},
		{"burkina", "70 12 34 56", "BF", []string{"+226"}, "70123456", "+22670123456"},
		{"ivory coast ten digits", "07 12 34 56 78", "CI", []string{"+225"}, "0712345678", "+2250712345678"},
		{"ivory coast bare code", "2250712345678", "CI", []string{"+225"}, "0712345678", "+2250712345678"},
		{"gambia short", "301 2345", "GM", []string{"+220"}, "3012345", "+2203012345"},
		// The North American plan: the area code stays in the national part.
		{"usa", "(212) 555-1234", "US", []string{"+1"}, "2125551234", "+12125551234"},
		{"usa bare code", "12125551234", "US", []string{"+1"}, "2125551234", "+12125551234"},
		{"usa plus", "+1 212 555 1234", "US", []string{"+1"}, "2125551234", "+12125551234"},
		{"dominican republic", "809 555 1234", "DO", []string{"+1849", "+1829", "+1809"}, "8095551234", "+18095551234"},
		{"trinidad", "868-555-1234", "TT", []string{"+1868"}, "8685551234", "+18685551234"},
		{"kyrgyzstan", "555123456", "KG", []string{"+996"}, "555123456", "+996555123456"},
		{"kyrgyzstan bare code", "996555123456", "KG", []string{"+996"}, "555123456", "+996555123456"},
		{"kyrgyzstan trunk", "0555123456", "KG", []string{"+996"}, "555123456", "+996555123456"},
		// The leading zero that belongs to the number, where it does.
		{"ivory coast mobile", "0707123456", "CI", []string{"+225"}, "0707123456", "+2250707123456"},
		{"ivory coast fixed line", "2721123456", "CI", []string{"+225"}, "2721123456", "+2252721123456"},
		{"benin", "0197123456", "BJ", []string{"+229"}, "0197123456", "+2290197123456"},
		{"congo", "061234567", "CG", []string{"+242"}, "061234567", "+242061234567"},
		// A country the table does not know: the generic rule (5 to 15 digits in all).
		{"unknown national", "71234567", "ZZ", []string{"+999"}, "71234567", "+99971234567"},
		{"unknown bare code", "99971234567", "ZZ", []string{"+999"}, "71234567", "+99971234567"},
		{"unknown trunk", "071234567", "ZZ", []string{"+999"}, "71234567", "+99971234567"},
		{"unknown short but plausible", "71234", "ZZ", []string{"+999"}, "71234", "+99971234"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			phone, err := ParsePhone(c.input, c.country, c.dial)
			if err != nil {
				t.Fatalf("%q: %v", c.input, err)
			}
			if phone.National != c.national || phone.E164() != c.e164 || phone.Country != c.country {
				t.Fatalf("%q: got %+v (%s), want national %s e164 %s", c.input, phone, phone.E164(), c.national, c.e164)
			}
			if phone.Digits() != c.e164[1:] {
				t.Fatalf("digits %s", phone.Digits())
			}
		})
	}
}

func TestParsePhoneRefusesWhatIsNotANumber(t *testing.T) {
	for _, c := range []struct {
		name, input, country string
		dial                 []string
	}{
		{"empty", "", "ML", []string{"223"}},
		{"letters", "70ab3456", "ML", []string{"223"}},
		{"too short", "7012", "ML", []string{"223"}},
		{"too long", "7012345678901234567", "ML", []string{"223"}},
		{"another country code", "+234 8031234567", "ML", []string{"223"}},
		{"double zero of another country", "00234 8031234567", "ML", []string{"223"}},
		{"plus in the middle", "223+70123456", "ML", []string{"223"}},
		{"two pluses", "++22370123456", "ML", []string{"223"}},
		{"no calling code", "70123456", "ML", nil},
		{"no country", "70123456", "", []string{"223"}},
		{"only the country code", "+223", "ML", []string{"223"}},
		{"only a plus", "+", "ML", []string{"223"}},
		// A number outside the lengths of its country is a typing mistake: Reloadly
		// would refuse it, so it is refused before anything is charged.
		{"mali one digit short", "6123456", "ML", []string{"223"}},
		{"mali one digit short, international", "+223 6123456", "ML", []string{"223"}},
		{"mali one digit too many", "701234567", "ML", []string{"223"}},
		{"nigeria one digit too many", "80123456789", "NG", []string{"234"}},
		{"nigeria one digit too many with the trunk zero", "080123456789", "NG", []string{"234"}},
		{"nigeria one digit short", "803123456", "NG", []string{"234"}},
		{"nigeria one digit short, international", "+234 803 123 456", "NG", []string{"234"}},
		{"nigeria trunk zero but a digit short", "0803123456", "NG", []string{"234"}},
		{"ivory coast without the zero", "707123456", "CI", []string{"225"}},
		{"ivory coast the old eight digits", "07123456", "CI", []string{"225"}},
		{"ivory coast international without the zero", "+225 707123456", "CI", []string{"225"}},
		{"benin the old eight digits", "97123456", "BJ", []string{"229"}},
		{"benin without the zero", "197123456", "BJ", []string{"229"}},
		{"egypt a digit short", "100123456", "EG", []string{"20"}},
		{"turkey a digit too many", "53212345678", "TR", []string{"90"}},
		{"pakistan a digit short", "300123456", "PK", []string{"92"}},
		{"usa without the area code", "5551234", "US", []string{"1"}},
		{"niger nine digits", "961234567", "NE", []string{"227"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			if phone, err := ParsePhone(c.input, c.country, c.dial); err == nil || !errors.Is(err, ErrInvalidPhone) {
				t.Fatalf("%q must be refused, got %+v %v", c.input, phone, err)
			}
		})
	}
}

func TestMaskingNeverShowsTheWholeNumber(t *testing.T) {
	phone, err := ParsePhone("70123456", "ML", []string{"223"})
	if err != nil {
		t.Fatal(err)
	}
	if got := phone.Masked(); got != "+223•••••456" {
		t.Fatalf("mask %q", got)
	}
	for _, c := range []struct{ in, want string }{
		{"04223568280", "••••••••280"},
		{"1234567", "•••••67"},
		{"1234", "•••4"},
		{"7", "•"},
		{"", ""},
	} {
		if got := MaskAccount(c.in); got != c.want {
			t.Errorf("MaskAccount(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	short, err := ParsePhone("3012345", "GM", []string{"220"})
	if err != nil {
		t.Fatal(err)
	}
	if got := short.Masked(); got != "+220•••••45" {
		t.Fatalf("a short number shows less: %q", got)
	}
}

func TestTheDetectedPhoneCarriesTheThreeForms(t *testing.T) {
	phone, _ := ParsePhone("70123456", "ML", []string{"223"})
	got := phone.Detected()
	if got.E164 != "+22370123456" || got.National != "70123456" || got.Country != "ML" {
		t.Fatalf("%+v", got)
	}
}

func TestEveryLiveCountryCanParseANumber(t *testing.T) {
	// A smoke test over the whole country list: a number of an invented but
	// plausible length parses for every country, with and without its code.
	for _, country := range loadLiveCountries(t) {
		shape, known := shapeOf(country.ISOName)
		length := 9
		if known {
			length = shape.min
		}
		national := "5123456789012"[:length]
		if _, err := ParsePhone(national, country.ISOName, country.CallingCodes); err != nil {
			t.Errorf("%s: national %s: %v", country.ISOName, national, err)
			continue
		}
		dial := effectiveDials(country.CallingCodes)[0]
		withCode, err := ParsePhone("+"+dial+national, country.ISOName, country.CallingCodes)
		if err != nil || withCode.National != national {
			t.Errorf("%s: +%s%s -> %+v %v", country.ISOName, dial, national, withCode, err)
		}
	}
}

func TestAnUnknownCountryKeepsTheGenericRule(t *testing.T) {
	for _, c := range []struct {
		name, input string
		ok          bool
	}{
		{"five digits", "71234", true},
		{"four digits", "7123", false},
		{"twelve digits", "712345678901", true},
		{"too long in all", "7123456789012", false}, // 3 (dial) + 13 > 15
	} {
		_, err := ParsePhone(c.input, "ZZ", []string{"999"})
		if (err == nil) != c.ok {
			t.Errorf("%s: %q: %v", c.name, c.input, err)
		}
	}
}

// shapeSample is a national number of the given length for a country that is
// typed the way a person types it: no leading zero (unless the country keeps
// one), and not beginning with the country's calling code.
func shapeSample(country string, length int, dial string) string {
	first := byte('7')
	if dial != "" && dial[0] == '7' {
		first = '5'
	}
	digits := []byte{first}
	for i := 1; len(digits) < length; i++ {
		digits = append(digits, byte('1'+i%8))
	}
	sample := string(digits)
	if zeroLeading[country] && length == 10 && (country == "CI" || country == "BJ") {
		sample = "0" + sample[1:]
	}
	return sample
}

func TestEveryCountryOfTheTableTakesItsLengthsAndRefusesTheOthers(t *testing.T) {
	for country, shape := range nationalShapes {
		dial := "99" // a calling code of nobody's, for the countries the fixture lacks
		if codes := dialOfFixtureCountry(t, country); codes != "" {
			dial = codes
		}
		dials := []string{dial}
		for _, length := range []int{shape.min, shape.max} {
			national := shapeSample(country, length, dial)
			forms := []string{national, "+" + dial + national, "00" + dial + national}
			// The country code written without a plus or a 00 is told from a long
			// national number only by the lengths: where both fit, a number is
			// taken as national (a pre-existing, documented ambiguity).
			if !shape.has(len(dial) + length) {
				forms = append(forms, dial+national)
			}
			for _, typed := range forms {
				phone, err := ParsePhone(typed, country, dials)
				if err != nil || phone.National != national || phone.Dial != dial {
					t.Errorf("%s: %q (%d digits): %+v %v", country, typed, length, phone, err)
				}
			}
		}
		for _, length := range []int{shape.min - 1, shape.max + 1} {
			if length < 1 || length+len(dial) > maxPhoneDigits {
				continue
			}
			national := shapeSample(country, length, dial)
			for _, typed := range []string{national, "+" + dial + national, "00" + dial + national} {
				if phone, err := ParsePhone(typed, country, dials); err == nil {
					t.Errorf("%s: %q has %d digits, the country takes %d to %d: accepted as %+v", country, typed, length, shape.min, shape.max, phone)
				}
			}
		}
		// A number that begins with 0 once the trunk zero is gone is not one of the
		// country, unless its numbers do.
		if !zeroLeading[country] && shape.min >= 6 {
			typed := "00" + shapeSample(country, shape.min, dial)[1:]
			if _, err := ParsePhone(typed, country, dials); err == nil && shape.min > 0 {
				// "00..." reads as an international prefix: never a national number.
				t.Errorf("%s: %q accepted", country, typed)
			}
			national := "0" + shapeSample(country, shape.max, dial)[1:]
			if phone, err := ParsePhone(national, country, dials); err == nil && phone.National[0] == '0' {
				t.Errorf("%s: %q kept a leading zero: %+v", country, national, phone)
			}
		}
	}
}

// dialOfFixtureCountry is the calling code the fixture gives a country, "" when
// it is not in it.
func dialOfFixtureCountry(t *testing.T, country string) string {
	t.Helper()
	for _, c := range mustFixture(t).Countries {
		if c.ISOName == country && len(c.CallingCodes) > 0 {
			return effectiveDials(c.CallingCodes)[0]
		}
	}
	return ""
}

func TestEveryCountryOfTheFixtureHasLengthsToCheckItsNumbersBy(t *testing.T) {
	for _, c := range mustFixture(t).Countries {
		if _, ok := nationalShapes[c.ISOName]; !ok {
			t.Errorf("%s (%s) has no national lengths: any number of 5 to 12 digits would be sold", c.ISOName, c.Name)
		}
	}
}

func TestAStoredOrderIsStillRecognisedWhateverTheLengthRulesAreNow(t *testing.T) {
	// Numbers were once accepted at any plausible length. An order placed then is
	// replayed and compared by what it was, not refused for what a number must be
	// today: identifying is not validating.
	service := keyedService(t, "key-a")
	if _, err := ParsePhone("6123456", "ML", []string{"223"}); err == nil {
		t.Fatal("seven digits is not a Mali number")
	}
	legacy := OrderRequest{Kind: "airtime", OperatorID: 289, Phone: "6123456", Amount: "5000", AmountCurrency: "XOF"}
	details := json.RawMessage(`{"country":"ML","dial":["223"],"target_kid":"` + service.targetKeyID() + `","target_digest":"` +
		service.targetDigest("shop-1", KindAirtime, "2236123456", "", "XOF") + `"}`)
	if same, known := service.SameTarget("shop-1", details, legacy); !same || !known {
		t.Fatalf("the same legacy number: %v %v", same, known)
	}
	other := legacy
	other.Phone = "6123457"
	if same, known := service.SameTarget("shop-1", details, other); same || !known {
		t.Fatalf("another legacy number: %v %v", same, known)
	}
	// And its mask is still told, once the directory is loaded.
	loaded := fixtureService(t)
	if _, err := loaded.Directory(context.Background(), pricing(t, "9.71")); err != nil {
		t.Fatal(err)
	}
	if mask, ok := loaded.MaskedTarget(legacy); !ok || mask != "+223•••••56" {
		t.Fatalf("mask %q %v", mask, ok)
	}
}
