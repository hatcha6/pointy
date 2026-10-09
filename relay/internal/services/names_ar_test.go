package services

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"unicode"

	"pointy/relay/internal/vouchers"
)

// The fixtures in testdata/ are Reloadly's live directory of 2026-10-08, reduced
// to what the naming tests need: the 411 plain airtime operators of 126 countries
// and the 34 billers of the live and the sandbox directory (with every fixed plan
// of Canal+ Mali and StarTimes Mali). The sandbox has 7 billers the live
// directory has not; they are marked "sandbox_only".
const (
	namesTestOperatorsFile = "testdata/names_operators.json"
	namesTestBillersFile   = "testdata/names_billers.json"
)

type namesTestOperator struct {
	ID      int    `json:"id"`
	Name    string `json:"name"`
	ISO     string `json:"iso"`
	Country string `json:"country"`
}

type namesTestPlan struct {
	ID          int    `json:"id"`
	Description string `json:"description"`
}

type namesTestBiller struct {
	ID              int             `json:"id"`
	Name            string          `json:"name"`
	ISO             string          `json:"iso"`
	Country         string          `json:"country"`
	Type            string          `json:"type"`
	Service         string          `json:"service"`
	RequiresInvoice bool            `json:"requires_invoice"`
	SandboxOnly     bool            `json:"sandbox_only"`
	Plans           []namesTestPlan `json:"plans"`
}

// namesTestNotSold lists the countries whose operators are deliberately left
// without an Arabic name: the countries table (vouchers.CountryName) has no
// entry for them, so the till never lists the country. Israel is absent from
// that table on purpose.
var namesTestNotSold = map[string]string{"IL": "Israel"}

func namesTestLoad(t *testing.T, path string, into any) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
}

func namesTestOperators(t *testing.T) []namesTestOperator {
	t.Helper()
	var ops []namesTestOperator
	namesTestLoad(t, namesTestOperatorsFile, &ops)
	if len(ops) < 400 {
		t.Fatalf("fixture has %d operators, want the full plain set (411)", len(ops))
	}
	return ops
}

func namesTestBillers(t *testing.T) []namesTestBiller {
	t.Helper()
	var billers []namesTestBiller
	namesTestLoad(t, namesTestBillersFile, &billers)
	if len(billers) != 34 {
		t.Fatalf("fixture has %d billers, want the 27 of the live directory plus the 7 only the sandbox has (34)", len(billers))
	}
	return billers
}

// namesTestProblem is "" for an Arabic display string a cashier can read, and
// otherwise what is wrong with it. There is no allow-list of Latin spellings:
// acronyms are spelled phonetically ("إم تي إن", "بي إس إن إل"), so no Latin
// letter of any kind may remain. Digits are fine ("تيلي 2").
func namesTestProblem(s string) string {
	if s == "" {
		return "empty"
	}
	if s != strings.TrimSpace(s) || strings.Contains(s, "  ") {
		return "stray whitespace"
	}
	if strings.Count(s, "(") != strings.Count(s, ")") {
		return "unbalanced parentheses"
	}
	arabic := false
	for _, r := range s {
		switch {
		case unicode.Is(unicode.Latin, r):
			return fmt.Sprintf("Latin letter %q", r)
		case unicode.Is(unicode.Arabic, r) && unicode.IsLetter(r):
			arabic = true
		case unicode.IsMark(r): // vowel signs such as the damma of "عُمان"
		case unicode.IsDigit(r), strings.ContainsRune(" ()،–!", r):
		default:
			return fmt.Sprintf("unexpected character %q", r)
		}
	}
	if !arabic {
		return "no Arabic letter"
	}
	return ""
}

func TestOperatorNameARRules(t *testing.T) {
	cases := []struct {
		name, iso, country string
		want               string
	}{
		// The brief's own examples.
		{"Orange Mali", "ML", "Mali", "أورنج مالي"},
		{"Orange (Mobinil) Egypt", "EG", "Egypt", "أورنج مصر"},
		{"Vodafone Cyprus Turkey", "TR", "Turkey", "فودافون قبرص التركية"},
		{"AT&T Mexico USD", "MX", "Mexico", "إيه تي آند تي المكسيك (بالدولار)"},
		{"AT&T Mexico Retail", "MX", "Mexico", "إيه تي آند تي المكسيك (تجزئة)"},
		{"Maroc Telecom Morocco", "MA", "Morocco", "اتصالات المغرب"},
		// The country is appended in Arabic from the countries table.
		{"Djezzy Algeria", "DZ", "Algeria", "جازي الجزائر"},
		{"Etisalat United Arab Emirates", "AE", "United Arab Emirates", "اتصالات الإمارات"},
		{"Ooredoo Oman", "OM", "Oman", "أوريدو عُمان"},
		{"Zain Kuwait", "KW", "Kuwait", "زين الكويت"},
		{"Ooredo Kuwait", "KW", "Kuwait", "أوريدو الكويت"}, // Reloadly's typo
		{"WE Telecom Egypt", "EG", "Egypt", "وي مصر"},
		{"Turkcell Turkey", "TR", "Turkey", "تركسل تركيا"},
		{"Safaricom Kenya", "KE", "Kenya", "سفاريكوم كينيا"},
		{"T2 Mobile Nigeria", "NG", "Nigeria", "تي 2 موبايل (ناين موبايل) نيجيريا"}, // 9mobile until 2025
		{"Reliance-Jio India", "IN", "India", "ريلاينس جيو الهند"},
		{"Africell Gambia", "GM", "Gambia", "أفريسل غامبيا"},
		{"Grameenphone Bangladesh", "BD", "Bangladesh", "جرامينفون بنغلاديش"},
		{"Vodacom South Africa", "ZA", "South Africa", "فوداكوم جنوب أفريقيا"},
		{"Tunisie Telecom Tunisia", "TN", "Tunisia", "اتصالات تونس"},
		// Country spellings Reloadly uses at the end of an operator name.
		{"Orange DRC", "CD", "The Democratic Republic Of Congo", "أورنج الكونغو الديمقراطية"},
		{"Claro DR", "DO", "Dominican Republic", "كلارو الدومينيكان"},
		{"MTN Ivory Coast", "CI", "Côte d'Ivoire", "إم تي إن ساحل العاج"},
		{"MTN Swaziland", "SZ", "Eswatini", "إم تي إن إسواتيني"},
		{"Digicel St Vincent Grenadines", "VC", "Saint Vincent And The Grenadines", "ديجيسل سانت فينسنت والغرينادين"},
		{"Flow St Kitts and Nevis", "KN", "Saint Kitts And Nevis", "فلو سانت كيتس ونيفيس"},
		{"Digicel Trinidad Tobago", "TT", "Trinidad and Tobago", "ديجيسل ترينيداد وتوباغو"},
		{"Verizon USA", "US", "United States", "فيرايزون الولايات المتحدة"},
		{"Digicel Trinidad", "TT", "Trinidad and Tobago", "ديجيسل ترينيداد وتوباغو"}, // the first word of the country, rest is a known brand
		// Qualifiers after the country; jargon ("RTR", "mobile") is dropped.
		{"Smart Philippines", "PH", "Philippines", "سمارت الفلبين"},
		{"Smart Philippines Promo", "PH", "Philippines", "سمارت الفلبين (عروض)"},
		{"Smile Uganda USD", "UG", "Uganda", "سمايل أوغندا (بالدولار)"},
		{"Koodo Canada RTR", "CA", "Canada", "كودو كندا"},
		{"T-Mobile USA RTR", "US", "United States", "تي موبايل الولايات المتحدة"},
		{"Digi Romania mobile", "RO", "Romania", "ديجي رومانيا"},
		{"Telekom (Digi) Romania Mobile", "RO", "Romania", "تيليكوم (ديجي) رومانيا"},
		// A parenthesis the table keeps on purpose, and one it drops.
		{"MTN (Atoma) Afghanistan", "AF", "Afghanistan", "إم تي إن (أتوما) أفغانستان"},
		{"Telecel (Vodafone) Ghana", "GH", "Ghana", "تيليسل (فودافون) غانا"},
		{"Orange (Cellcom) Liberia", "LR", "Liberia", "أورنج ليبيريا"},
		{"CellCard (CamGSM) Cambodia", "KH", "Cambodia", "سيل كارد كمبوديا"},
		// A brand that already says the country is not followed by it again.
		{"Eswatini Mobile Swaziland", "SZ", "Eswatini", "إسواتيني موبايل"},
		{"YemenMobile Yemen", "YE", "Yemen", "يمن موبايل"},
		{"VietnamMobile Vietnam", "VN", "Vietnam", "فيتنام موبايل"},
		// Exact overrides: names that do not follow "<brand> <country>".
		{"Uganda Telecom", "UG", "Uganda", "أوغندا تيليكوم"},
		{"Amigo Sin Límite", "MX", "Mexico", "أميغو سين ليميتي (تلسل) المكسيك"},
		{"Digicel Curacao", "AN", "Netherlands Antilles", "ديجيسل كوراساو"},
		{"Digicel Bonaire", "AN", "Netherlands Antilles", "ديجيسل بونير"},
		{"H2O PayGo RTR USA", "US", "United States", "إتش تو أو الولايات المتحدة (دفع حسب الاستخدام)"},
		{"H2o RTR US", "US", "United States", "إتش تو أو الولايات المتحدة"},
		{"Lyca Mobile USA", "US", "United States", "لايكاموبايل الولايات المتحدة"},
		{"Lyca Mobile RTR Unlimited US", "US", "United States", "لايكاموبايل الولايات المتحدة (غير محدود)"},
		// Matching ignores case, accents, and any kind of whitespace.
		{"  orange   MALI ", "ml", "mali", "أورنج مالي"},
		{"Orange\tMali", "ML", "Mali", "أورنج مالي"},
		{"Orange Mali", "ML", "Mali", "أورنج مالي"},
		{"Amigo Sin Limite", "MX", "Mexico", "أميغو سين ليميتي (تلسل) المكسيك"},
		{"Claro Paraguay  ", "PY", "Paraguay", "كلارو باراغواي"}, // trailing blanks, as Reloadly sends it
	}
	for _, c := range cases {
		got, ok := OperatorNameAR(c.name, c.iso, c.country)
		if !ok || got != c.want {
			t.Errorf("OperatorNameAR(%q, %q, %q) = %q, %v; want %q", c.name, c.iso, c.country, got, ok, c.want)
		}
	}
}

func TestOperatorNameARUnknown(t *testing.T) {
	cases := []struct{ name, iso, country, why string }{
		{"Zorblax Mali", "ML", "Mali", "a brand that is not in the table"},
		{"Orange", "ML", "Mali", "no country in the name, no override"},
		{"Orange Mali", "ML", "", "Reloadly's country name is needed to find the brand"},
		{"Orange Mali", "ML", "Niger", "the name does not end with the country it was given"},
		{"Orange Mali", "", "Mali", "no country code"},
		{"", "ML", "Mali", "empty name"},
		{"Cellcom Israel", "IL", "Israel", "Israel has no Arabic country name on purpose"},
		{"Orange Atlantis", "XX", "Atlantis", "an unknown country"},
		{"Zorblax Trinidad", "TT", "Trinidad and Tobago", "the first word of a country is trusted only before a known brand"},
		{"Trinidad", "TT", "Trinidad and Tobago", "a country alone is not an operator"},
		{"Orange Mali Data", "ML", "Mali", "data products are outside the v1 shelf"},
	}
	for _, c := range cases {
		if got, ok := OperatorNameAR(c.name, c.iso, c.country); ok || got != "" {
			t.Errorf("OperatorNameAR(%q, %q, %q) = %q, %v; want (\"\", false): %s", c.name, c.iso, c.country, got, ok, c.why)
		}
	}
}

func TestBillerNameAR(t *testing.T) {
	cases := []struct{ name, iso, want string }{
		{"Ikeja Electricity Prepaid", "NG", "كهرباء إيكيجا (مسبقة الدفع)"},
		{"Ikeja Electricity Postpaid", "NG", "كهرباء إيكيجا (لاحقة الدفع)"},
		{"Port Harcourt Electricity Prepaid", "NG", "كهرباء بورت هاركورت (مسبقة الدفع)"},
		{"Woyofal Senegal", "SN", "ووفال السنغال (كهرباء مسبقة الدفع)"},
		{"Facture Sen-Elec Senegal", "SN", "فاتورة كهرباء السنغال (سينيلك)"},
		{"Facture Sen-Eau Senegal", "SN", "فاتورة مياه السنغال (سين إيو)"},
		{"Rapido Senegal", "SN", "رابيدو السنغال (رسوم الطرق)"},
		{"Canal+ Mali", "ML", "كانال بلس مالي"},
		{"South Africa Electricity Prepaid", "ZA", "كهرباء جنوب أفريقيا (مسبقة الدفع)"},
		{"  canal+   mali ", "ml", "كانال بلس مالي"},
		// Only the sandbox has these.
		{"Kenya Electricity Prepaid", "KE", "كهرباء كينيا (مسبقة الدفع)"},
		{"Kenya Electricity Postpaid", "KE", "كهرباء كينيا (لاحقة الدفع)"},
		{"Kano Electricity Postpaid", "NG", "كهرباء كانو (لاحقة الدفع)"},
		{"Energie Du Mali (EDM)", "ML", "كهرباء مالي (إي دي إم)"},
		{"StarTimes Mali", "ML", "ستارتايمز مالي"},
		{"Uganda Umeme Prepaid", "UG", "كهرباء أوغندا أوميمي (مسبقة الدفع)"},
		{"Uganda Umeme Postpaid", "UG", "كهرباء أوغندا أوميمي (لاحقة الدفع)"},
	}
	for _, c := range cases {
		if got, ok := BillerNameAR(c.name, c.iso); !ok || got != c.want {
			t.Errorf("BillerNameAR(%q, %q) = %q, %v; want %q", c.name, c.iso, got, ok, c.want)
		}
	}
	for _, c := range []struct{ name, iso string }{
		{"Ikeja Electricity Prepaid", "GH"}, // a biller is known by its country too
		{"Lekki Electricity Prepaid", "NG"},
		{"", "NG"},
	} {
		if got, ok := BillerNameAR(c.name, c.iso); ok || got != "" {
			t.Errorf("BillerNameAR(%q, %q) = %q, %v; want (\"\", false)", c.name, c.iso, got, ok)
		}
	}
}

func TestPlanDescriptionAR(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Canalplus Acces English Basic (10000/1MOIS)", "كانال بلس أكسيس إنجليش بيسك – شهر"},
		{"Canalplus Acces English Plus (18000/1MOIS)", "كانال بلس أكسيس إنجليش بلس – شهر"},
		{"Canalplus Evasion Charme (16000/1MOIS)", "كانال بلس إيفازيون شارم (للبالغين) – شهر"},
		{"Canalplus Essentiel + Charme (19000/1MOIS)", "كانال بلس إيسنسيال بلس شارم (للبالغين) – شهر"},
		{"Canalplus Access + English Basic (60000/3MOIS)", "كانال بلس أكسيس بلس إنجليش بيسك – 3 أشهر"},
		{"Tout Canalplus English Plus (159000/3MOIS)", "تو كانال بلس إنجليش بلس – 3 أشهر"},
		// Case, spacing around "+", and the other durations.
		{"canalplus evasion+ english basic (1/6mois)", "كانال بلس إيفازيون بلس إنجليش بيسك – 6 أشهر"},
		{"  Canalplus   Acces   (5000.50 / 12MOIS) ", "كانال بلس أكسيس – سنة"},
		// StarTimes: a bouquet and a number of days ("1JOUR", "7JOUR" and "30JOURS" are Reloadly's own).
		{"Smart (400/1JOUR)", "سمارت – يوم"},
		{"Smart (1500/7JOUR)", "سمارت – 7 أيام"},
		{"Smart (4500/30JOURS)", "سمارت – 30 يوماً"},
		{"English (24000/60JOURS)", "إنجليش – 60 يوماً"},
		{"Max (45000/90JOURS)", "ماكس – 90 يوماً"},
		// No duration, no dash.
		{"Canalplus Acces", "كانال بلس أكسيس"},
	}
	for _, c := range cases {
		if got, ok := PlanDescriptionAR(c.in); !ok || got != c.want {
			t.Errorf("PlanDescriptionAR(%q) = %q, %v; want %q", c.in, got, ok, c.want)
		}
	}
	// A word or a duration the table does not know makes the whole text unknown:
	// half a translation would be worse than the Latin spelling.
	for _, in := range []string{
		"Canalplus Acces Sport (10000/1MOIS)",
		"Canalplus Acces English Basic (10000/2MOIS)",
		"Canalplus Acces (English Basic (10000/1MOIS)",
		"Canalplus Acces English Basic (10000/1MOIS) extra",
		"(10000/1MOIS)",
		"",
	} {
		if got, ok := PlanDescriptionAR(in); ok || got != "" {
			t.Errorf("PlanDescriptionAR(%q) = %q, %v; want (\"\", false)", in, got, ok)
		}
	}
}

func TestBillTypeARAndServiceAR(t *testing.T) {
	for in, want := range map[string]string{
		"electricity": "كهرباء",
		"water":       "مياه",
		"tv":          "تلفزيون",
		"internet":    "إنترنت",
		"toll":        "رسوم الطرق",
		"other":       "أخرى",
		// Reloadly's own constants.
		"ELECTRICITY_BILL_PAYMENT":  "كهرباء",
		"WATER_BILL_PAYMENT":        "مياه",
		"TV_BILL_PAYMENT":           "تلفزيون",
		"INTERNET_BILL_PAYMENT":     "إنترنت",
		"TOLL_HIGHWAY_BILL_PAYMENT": "رسوم الطرق",
		// Anything else is the generic bucket, never an error.
		"gas":  "أخرى",
		"":     "أخرى",
		" TV ": "تلفزيون",
	} {
		if got := BillTypeAR(in); got != want {
			t.Errorf("BillTypeAR(%q) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]string{
		"prepaid":   "مسبق الدفع",
		"PREPAID":   "مسبق الدفع",
		"postpaid":  "لاحق الدفع",
		" Postpaid": "لاحق الدفع",
		"":          "",
		"hybrid":    "",
	} {
		if got := ServiceAR(in); got != want {
			t.Errorf("ServiceAR(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestNamesTableIntegrity guards the embedded file itself: every Arabic string
// is clean, every key is in its folded form, and nothing in it is dead.
func TestNamesTableIntegrity(t *testing.T) {
	var f arNamesFile
	if err := json.Unmarshal(arNamesJSON, &f); err != nil {
		t.Fatal(err)
	}

	arabic := map[string]map[string]string{
		"brands": f.Brands, "operators": f.Operators, "billers": f.Billers,
		"plan_words": f.PlanWords, "bill_types": f.BillTypes, "services": f.Services,
	}
	for section, m := range arabic {
		if len(m) == 0 {
			t.Errorf("section %q is empty", section)
		}
		for key, value := range m {
			// {country} is filled from the countries table; check what it makes.
			if problem := namesTestProblem(strings.ReplaceAll(value, arNamesCountryToken, "مثال")); problem != "" {
				t.Errorf("%s[%q] = %q: %s", section, key, value, problem)
			}
			if strings.Contains(value, arNamesCountryToken) {
				iso, _, _ := strings.Cut(key, "|")
				if (section != "operators" && section != "billers") || vouchers.CountryName(iso) == "" {
					t.Errorf("%s[%q] uses %s, but %q has no Arabic country name", section, key, arNamesCountryToken, iso)
				}
			}
		}
	}
	// A country is spelled once: the Arabic name of the countries table must not
	// be copied into a finished name (it would drift from the table).
	for section, m := range map[string]map[string]string{"operators": f.Operators, "billers": f.Billers} {
		for key, value := range m {
			iso, _, _ := strings.Cut(key, "|")
			if name := vouchers.CountryName(iso); name != "" && strings.Contains(value, name) {
				t.Errorf("%s[%q] = %q spells the country %q out; write %s", section, key, value, name, arNamesCountryToken)
			}
		}
	}
	// A qualifier may be empty (jargon that is dropped) but never Latin.
	for key, value := range f.Qualifiers {
		if value != "" {
			if problem := namesTestProblem(value); problem != "" {
				t.Errorf("qualifiers[%q] = %q: %s", key, value, problem)
			}
		}
	}

	// Brand, qualifier and plan-word keys are written in their folded form, so
	// what a reviewer reads in the file is what is matched.
	for section, m := range map[string]map[string]string{"brands": f.Brands, "qualifiers": f.Qualifiers, "plan_words": f.PlanWords, "review": f.Review} {
		for key := range m {
			if key != arNamesFold(key) {
				t.Errorf("%s key %q is not in folded form (%q)", section, key, arNamesFold(key))
			}
		}
	}

	// Every brand says where its spelling comes from, and no review line is orphaned.
	for key := range f.Brands {
		switch f.Review[key] {
		case "w", "n", "l", "t", "?":
		default:
			t.Errorf("brand %q has review code %q; want one of w n l t ?", key, f.Review[key])
		}
	}
	for key := range f.Review {
		if _, ok := f.Brands[key]; !ok {
			t.Errorf("review entry %q has no brand", key)
		}
	}

	// Country aliases belong to countries the table can name.
	for iso, spellings := range f.CountryAliases {
		if iso != strings.ToUpper(iso) || vouchers.CountryName(iso) == "" {
			t.Errorf("country_aliases[%q]: not a country with an Arabic name", iso)
		}
		for _, s := range spellings {
			if strings.TrimSpace(s) == "" {
				t.Errorf("country_aliases[%q] has an empty spelling", iso)
			}
		}
	}

	// Every override and every biller names a real thing: a typo in a key would
	// otherwise sit there doing nothing while the operator fell back to Latin.
	ops := namesTestOperators(t)
	known := map[string]bool{}
	for _, o := range ops {
		known[strings.ToUpper(o.ISO)+"|"+arNamesFold(o.Name)] = true
	}
	for key := range arNames.operators {
		if !known[key] {
			t.Errorf("operators override %q matches no plain operator of the fixture", key)
		}
	}
	billers := namesTestBillers(t)
	knownBillers := map[string]bool{}
	for _, b := range billers {
		knownBillers[strings.ToUpper(b.ISO)+"|"+arNamesFold(b.Name)] = true
	}
	for key := range arNames.billers {
		if !knownBillers[key] {
			t.Errorf("billers entry %q matches no biller of the fixture", key)
		}
	}

	// Every brand is used by some operator of the fixture (or is a documented
	// spelling kept for operators outside the plain set).
	used := map[string]bool{}
	for _, o := range ops {
		if parts, ok := arNames.parseOperator(o.Name, o.ISO, o.Country); ok && parts.brandKey != "" {
			used[parts.brandKey] = true
		}
	}
	for key := range arNames.brands {
		if !used[key] && !namesTestSpareBrands[key] {
			t.Errorf("brand %q is used by no plain operator; delete it or add it to namesTestSpareBrands", key)
		}
	}
}

// namesTestSpareBrands are brands kept although no plain operator uses them
// today: the same company under the spelling Reloadly uses for its other
// products, so the day one becomes plain it is already named.
var namesTestSpareBrands = map[string]bool{}

// TestPlainOperatorsAllNamed is the coverage test: every plain airtime operator
// of Reloadly (the v1 shelf) has an Arabic name with no Latin letter, and two
// operators of one country never share a name.
func TestPlainOperatorsAllNamed(t *testing.T) {
	ops := namesTestOperators(t)
	byCountry := map[string]map[string]string{} // iso -> arabic -> english
	named, unsold := 0, 0
	for _, o := range ops {
		got, ok := OperatorNameAR(o.Name, o.ISO, o.Country)
		if _, notSold := namesTestNotSold[o.ISO]; notSold {
			unsold++
			if ok {
				t.Errorf("%s (%s) was named %q, but %s has no Arabic country name: the till never lists it", o.Name, o.ISO, got, o.ISO)
			}
			continue
		}
		if !ok {
			t.Errorf("no Arabic name for %q (%s, %q)", o.Name, o.ISO, o.Country)
			continue
		}
		named++
		if problem := namesTestProblem(got); problem != "" {
			t.Errorf("%s (%s) -> %q: %s", o.Name, o.ISO, got, problem)
		}
		if namesTestRunes(got) > 60 {
			t.Errorf("%s (%s) -> %q is too long for a chip (%d characters)", o.Name, o.ISO, got, namesTestRunes(got))
		}
		if byCountry[o.ISO] == nil {
			byCountry[o.ISO] = map[string]string{}
		}
		if other, dup := byCountry[o.ISO][got]; dup {
			t.Errorf("%s: %q and %q would both read %q", o.ISO, other, o.Name, got)
		}
		byCountry[o.ISO][got] = o.Name
	}
	for iso := range namesTestNotSold {
		if name := vouchers.CountryName(iso); name != "" {
			t.Errorf("%s now has the Arabic country name %q: name its operators and drop it from namesTestNotSold", iso, name)
		}
	}
	t.Logf("%d plain operators: %d named, %d left unnamed on purpose (%v)", len(ops), named, unsold, namesTestNotSold)

	var missing []NameRef
	for _, o := range ops {
		missing = append(missing, NameRef{Name: o.Name, CountryISO: o.ISO, CountryName: o.Country})
	}
	if got := MissingOperatorNames(missing); len(got) != unsold {
		t.Errorf("MissingOperatorNames lists %d operators, want only the %d unsold ones: %v", len(got), unsold, got)
	}
	for _, line := range namesTestOperatorLines(ops) {
		t.Log(line)
	}
}

func namesTestRunes(s string) int { return len([]rune(s)) }

func TestBillersAllNamed(t *testing.T) {
	billers := namesTestBillers(t)
	byCountry := map[string]map[string]string{}
	plans := 0
	plansOf := map[string]int{}
	for _, b := range billers {
		plansOf[b.Name] += len(b.Plans)
		got, ok := BillerNameAR(b.Name, b.ISO)
		if !ok {
			t.Errorf("no Arabic name for biller %q (%s)", b.Name, b.ISO)
			continue
		}
		if problem := namesTestProblem(got); problem != "" {
			t.Errorf("biller %s (%s) -> %q: %s", b.Name, b.ISO, got, problem)
		}
		if byCountry[b.ISO] == nil {
			byCountry[b.ISO] = map[string]string{}
		}
		if other, dup := byCountry[b.ISO][got]; dup {
			t.Errorf("%s: billers %q and %q would both read %q", b.ISO, other, b.Name, got)
		}
		byCountry[b.ISO][got] = b.Name

		// The pieces the till builds its groups from.
		if BillTypeAR(b.Type) == "أخرى" {
			t.Errorf("biller %s: type %q has no Arabic name", b.Name, b.Type)
		}
		if ServiceAR(b.Service) == "" {
			t.Errorf("biller %s: service %q has no Arabic name", b.Name, b.Service)
		}

		seen := map[string]string{}
		for _, p := range b.Plans {
			plans++
			text, ok := PlanDescriptionAR(p.Description)
			if !ok {
				t.Errorf("no Arabic text for plan %d %q of %s", p.ID, p.Description, b.Name)
				continue
			}
			if problem := namesTestProblem(text); problem != "" {
				t.Errorf("plan %q -> %q: %s", p.Description, text, problem)
			}
			// The amount is shown next to the plan, never inside it.
			if namesTestBigNumber.MatchString(text) {
				t.Errorf("plan %q -> %q leaks a number", p.Description, text)
			}
			if problem := namesTestAdultProblem(p.Description, text); problem != "" {
				t.Errorf("plan %q -> %q: %s", p.Description, text, problem)
			}
			if other, dup := seen[text]; dup {
				t.Errorf("%s: plans %q and %q would both read %q", b.Name, other, p.Description, text)
			}
			seen[text] = p.Description
		}
	}
	if plans != 39 || plansOf["Canal+ Mali"] != 28 || plansOf["StarTimes Mali"] != 11 {
		t.Errorf("the fixture should carry the 28 fixed plans of Canal+ Mali and the 11 of StarTimes Mali, got %v (%d)", plansOf, plans)
	}

	var refs []NameRef
	var descriptions []string
	for _, b := range billers {
		refs = append(refs, NameRef{Name: b.Name, CountryISO: b.ISO, CountryName: b.Country})
		for _, p := range b.Plans {
			descriptions = append(descriptions, p.Description)
		}
	}
	if got := MissingBillerNames(refs); len(got) != 0 {
		t.Errorf("MissingBillerNames = %v, want none", got)
	}
	if got := MissingPlanDescriptions(descriptions); len(got) != 0 {
		t.Errorf("MissingPlanDescriptions = %v, want none", got)
	}
	for _, line := range namesTestBillerLines(billers) {
		t.Log(line)
	}
}

func TestMissingHelpers(t *testing.T) {
	refs := []NameRef{
		{"Orange Mali", "ML", "Mali"},
		{"Zorblax Mali", "ML", "Mali"},
		{"Cellcom Israel", "IL", "Israel"},
		{"Zorblax Mali", "ML", "Mali"}, // listed once
		{"Zorblax Niger", "NE", "Niger"},
	}
	want := []NameRef{{"Zorblax Mali", "ML", "Mali"}, {"Cellcom Israel", "IL", "Israel"}, {"Zorblax Niger", "NE", "Niger"}}
	if got := MissingOperatorNames(refs); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("MissingOperatorNames = %v, want %v", got, want)
	}
	if got := MissingOperatorNames(nil); len(got) != 0 {
		t.Errorf("MissingOperatorNames(nil) = %v", got)
	}
	billers := MissingBillerNames([]NameRef{{"Canal+ Mali", "ML", "Mali"}, {"Lekki Electricity", "NG", "Nigeria"}})
	if len(billers) != 1 || billers[0].Name != "Lekki Electricity" {
		t.Errorf("MissingBillerNames = %v", billers)
	}
	plans := MissingPlanDescriptions([]string{"Canalplus Acces English Basic (10000/1MOIS)", "Sport (1/1MOIS)", "Sport (1/1MOIS)"})
	if len(plans) != 1 || plans[0] != "Sport (1/1MOIS)" {
		t.Errorf("MissingPlanDescriptions = %v", plans)
	}
}

// TestLoadRejectsAmbiguousTables: two keys that fold to the same string, or an
// override that is not <ISO>|<name>, must stop the relay from starting rather
// than pick one at random.
func TestLoadRejectsAmbiguousTables(t *testing.T) {
	for name, raw := range map[string]string{
		"duplicate brand":      `{"brands": {"orange": "أ", "Orange": "ب"}}`,
		"override without ISO": `{"operators": {"Orange Mali": "أ"}}`,
		"unknown section":      `{"colours": {}}`,
		"not JSON":             `[`,
	} {
		if _, err := loadArNames([]byte(raw)); err == nil {
			t.Errorf("%s: loadArNames accepted %s", name, raw)
		}
	}
	if _, err := loadArNames([]byte(`{}`)); err != nil {
		t.Errorf("an empty table should load: %v", err)
	}
}

// --- The review list ------------------------------------------------------

func namesTestOperatorLines(ops []namesTestOperator) []string {
	var lines []string
	for _, o := range ops {
		ar := "(no Arabic name)"
		if parts, ok := arNames.parseOperator(o.Name, o.ISO, o.Country); ok {
			ar = parts.name
		}
		lines = append(lines, fmt.Sprintf("%s | %s → %s", o.ISO, o.Name, ar))
	}
	sort.Strings(lines)
	return lines
}

func namesTestBillerLines(billers []namesTestBiller) []string {
	var lines []string
	for _, b := range billers {
		ar, _ := BillerNameAR(b.Name, b.ISO)
		lines = append(lines, fmt.Sprintf("%s | %s → %s", b.ISO, b.Name, ar))
		for _, p := range b.Plans {
			text, _ := PlanDescriptionAR(p.Description)
			lines = append(lines, fmt.Sprintf("%s | %s → %s", b.ISO, p.Description, text))
		}
	}
	return lines
}

// namesTestReviewRows is the owner's review sheet: one row per operator, biller,
// plan and brand with where its spelling comes from.
func namesTestReviewRows(ops []namesTestOperator, billers []namesTestBiller) [][]string {
	rows := [][]string{{"kind", "iso", "english", "arabic", "source"}}
	opRows := [][]string{}
	for _, o := range ops {
		ar, source := "", "unnamed"
		if parts, ok := arNames.parseOperator(o.Name, o.ISO, o.Country); ok {
			ar, source = parts.name, "override"
			if parts.brandKey != "" {
				source = "brand:" + arNames.review[parts.brandKey]
			}
		}
		opRows = append(opRows, []string{"operator", o.ISO, o.Name, ar, source})
	}
	sort.SliceStable(opRows, func(i, j int) bool {
		if opRows[i][1] != opRows[j][1] {
			return opRows[i][1] < opRows[j][1]
		}
		return opRows[i][2] < opRows[j][2]
	})
	rows = append(rows, opRows...)
	for _, b := range billers {
		ar, _ := BillerNameAR(b.Name, b.ISO)
		rows = append(rows, []string{"biller", b.ISO, b.Name, ar, "table"})
		for _, p := range b.Plans {
			text, _ := PlanDescriptionAR(p.Description)
			rows = append(rows, []string{"plan", b.ISO, p.Description, text, "plan_words"})
		}
	}
	// The brands, with the countries that use them, in the order a reviewer
	// wants: the ones nobody sourced first.
	countries := map[string][]string{}
	for _, o := range ops {
		if parts, ok := arNames.parseOperator(o.Name, o.ISO, o.Country); ok && parts.brandKey != "" {
			countries[parts.brandKey] = append(countries[parts.brandKey], o.ISO)
		}
	}
	var keys []string
	for k := range arNames.brands {
		keys = append(keys, k)
	}
	rank := map[string]int{"?": 0, "t": 1, "n": 2, "l": 3, "w": 4}
	sort.Slice(keys, func(i, j int) bool {
		ri, rj := rank[arNames.review[keys[i]]], rank[arNames.review[keys[j]]]
		if ri != rj {
			return ri < rj
		}
		return keys[i] < keys[j]
	})
	for _, k := range keys {
		isos := countries[k]
		sort.Strings(isos)
		rows = append(rows, []string{"brand", strings.Join(isos, " "), k, arNames.brands[k], arNames.review[k]})
	}
	return rows
}

func namesTestSnapshotDir() string {
	if d := os.Getenv("POINTY_RELOADLY_SNAPSHOT_DIR"); d != "" {
		return d
	}
	return "/private/tmp/claude-501/-Users-hatem-Develop-pointy/9d48eb8d-a142-48de-bcfa-af051c11dc17/scratchpad/rl"
}

// TestWriteNamesReview prints the review list and, on a machine that holds the
// Reloadly snapshot (or when POINTY_NAMES_REVIEW_TSV names a file), writes it as
// a sheet for the owner. Elsewhere it only logs.
func TestWriteNamesReview(t *testing.T) {
	rows := namesTestReviewRows(namesTestOperators(t), namesTestBillers(t))
	path := os.Getenv("POINTY_NAMES_REVIEW_TSV")
	if path == "" {
		dir := namesTestSnapshotDir()
		if st, err := os.Stat(dir); err == nil && st.IsDir() {
			path = filepath.Join(filepath.Dir(dir), "names_review.tsv")
		}
	}
	if path == "" {
		t.Log("no snapshot directory here: review sheet not written")
		return
	}
	var b strings.Builder
	for _, r := range rows {
		b.WriteString(strings.Join(r, "\t"))
		b.WriteByte('\n')
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Logf("could not write %s: %v", path, err)
		return
	}
	t.Logf("review sheet: %s (%d rows)", path, len(rows)-1)
}

// namesTestBigNumber finds an amount: a plan's text never carries one.
var namesTestBigNumber = regexp.MustCompile(`[0-9]{3,}`)

// namesTestAdult are the words that mark adult content in a plan description.
// Canal+ sells its "Charme" option, a group of adult channels; any other such
// word appearing in a description is a new decision for the owner, so it fails
// here until somebody has looked at it.
var namesTestAdult = regexp.MustCompile(`(?i)charme|adult|xxx|xxl|playboy|dorcel|penthouse|private|erot|sex|porn|nude|18\+`)

// namesTestAdultProblem checks the one adult word we know ("charme") is said
// plainly in Arabic ("للبالغين"), and that no other adult word slipped in.
func namesTestAdultProblem(english, arabic string) string {
	word := namesTestAdult.FindString(english)
	switch {
	case word == "":
		return ""
	case !strings.EqualFold(word, "charme"):
		return fmt.Sprintf("adult-content word %q is new: decide whether the plan may be sold, then teach this test", word)
	case !strings.Contains(arabic, "للبالغين"):
		return "the adult option must say so in Arabic (للبالغين)"
	}
	return ""
}

func TestPlanDescriptionsAdultContent(t *testing.T) {
	adultPlans := 0
	for _, b := range namesTestBillers(t) {
		for _, p := range b.Plans {
			text, _ := PlanDescriptionAR(p.Description)
			if problem := namesTestAdultProblem(p.Description, text); problem != "" {
				t.Errorf("%s: %q -> %q: %s", b.Name, p.Description, text, problem)
			}
			if namesTestAdult.MatchString(p.Description) {
				adultPlans++
			}
		}
	}
	// 8 of the 28 Canal+ Mali plans carry the Charme option; nothing else does.
	if adultPlans != 8 {
		t.Errorf("%d plan descriptions carry adult wording, want the 8 Charme plans of Canal+ Mali", adultPlans)
	}
	// The guard itself.
	if namesTestAdultProblem("Canalplus Evasion Playboy (1/1MOIS)", "كانال بلس إيفازيون – شهر") == "" {
		t.Error("an unknown adult word must be reported")
	}
	if namesTestAdultProblem("Canalplus Evasion Charme (1/1MOIS)", "كانال بلس إيفازيون شارم – شهر") == "" {
		t.Error("a Charme plan without the Arabic warning must be reported")
	}
}

// --- The raw Reloadly snapshots ------------------------------------------------

type namesTestRawOperator struct {
	ID      int    `json:"id"`
	Name    string `json:"name"`
	Bundle  bool   `json:"bundle"`
	Data    bool   `json:"data"`
	Combo   bool   `json:"comboProduct"`
	Pin     bool   `json:"pin"`
	Country struct {
		ISO  string `json:"isoName"`
		Name string `json:"name"`
	} `json:"country"`
}

type namesTestRawBiller struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	ISO   string `json:"countryCode"`
	Fixed []struct {
		Description string `json:"description"`
	} `json:"localFixedAmounts"`
}

func namesTestReadRaw(t *testing.T, path string, into any) bool {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	return true
}

// namesTestCheckRaw holds a raw directory to what the fixture holds: every plain
// operator, biller and plan of it has an Arabic name, every biller is in the
// fixture (so the repo tests cover it), and no plan carries unknown adult wording.
func namesTestCheckRaw(t *testing.T, label string, ops []namesTestRawOperator, billers []namesTestRawBiller) {
	t.Helper()
	plain := 0
	for _, o := range ops {
		if o.Bundle || o.Data || o.Combo || o.Pin {
			continue
		}
		plain++
		if _, ok := OperatorNameAR(o.Name, o.Country.ISO, o.Country.Name); !ok && namesTestNotSold[o.Country.ISO] == "" {
			t.Errorf("%s plain operator %q (%s) has no Arabic name", label, o.Name, o.Country.ISO)
		}
	}
	inFixture := map[string]namesTestBiller{}
	for _, b := range namesTestBillers(t) {
		inFixture[strings.ToUpper(b.ISO)+"|"+arNamesFold(b.Name)] = b
	}
	plans := 0
	for _, b := range billers {
		if _, ok := BillerNameAR(b.Name, b.ISO); !ok {
			t.Errorf("%s biller %q (%s) has no Arabic name", label, b.Name, b.ISO)
		}
		fx, ok := inFixture[strings.ToUpper(b.ISO)+"|"+arNamesFold(b.Name)]
		if !ok {
			t.Errorf("%s biller %q (%s) is not in %s", label, b.Name, b.ISO, namesTestBillersFile)
		}
		have := map[string]bool{}
		for _, p := range fx.Plans {
			have[p.Description] = true
		}
		for _, p := range b.Fixed {
			plans++
			text, ok := PlanDescriptionAR(p.Description)
			if !ok {
				t.Errorf("%s plan %q of %s has no Arabic text", label, p.Description, b.Name)
			}
			if !have[p.Description] {
				t.Errorf("%s plan %q of %s is not in %s", label, p.Description, b.Name, namesTestBillersFile)
			}
			if problem := namesTestAdultProblem(p.Description, text); problem != "" {
				t.Errorf("%s plan %q: %s", label, p.Description, problem)
			}
		}
	}
	t.Logf("%s: %d operators (%d plain), %d billers, %d fixed plans: all named", label, len(ops), plain, len(billers), plans)
}

// TestFixtureMatchesSnapshot keeps testdata honest: when the raw Reloadly
// snapshot is on this machine, every plain operator in it must be in the fixture
// with the same spelling, and every biller and plan must be named (and be in the
// fixture too).
func TestFixtureMatchesSnapshot(t *testing.T) {
	dir := namesTestSnapshotDir()
	var live []namesTestRawOperator
	if !namesTestReadRaw(t, filepath.Join(dir, "operators_live.json"), &live) {
		t.Skipf("no Reloadly snapshot at %s", dir)
	}
	fixture := map[int]namesTestOperator{}
	for _, o := range namesTestOperators(t) {
		fixture[o.ID] = o
	}
	plain := 0
	for _, o := range live {
		if o.Bundle || o.Data || o.Combo || o.Pin {
			continue
		}
		plain++
		f, ok := fixture[o.ID]
		if !ok {
			t.Errorf("plain operator %d %q (%s) is in the snapshot but not in %s", o.ID, o.Name, o.Country.ISO, namesTestOperatorsFile)
			continue
		}
		if f.Name != o.Name || f.ISO != o.Country.ISO || f.Country != o.Country.Name {
			t.Errorf("operator %d differs: fixture %+v, snapshot %q %s %q", o.ID, f, o.Name, o.Country.ISO, o.Country.Name)
		}
	}
	if plain != len(fixture) {
		t.Errorf("snapshot has %d plain operators, fixture %d", plain, len(fixture))
	}
	var liveBillers []namesTestRawBiller
	if !namesTestReadRaw(t, filepath.Join(dir, "billers_live.json"), &liveBillers) {
		t.Skipf("no biller snapshot at %s", dir)
	}
	namesTestCheckRaw(t, "live", live, liveBillers)
}

// TestSandboxSnapshotNamed is the same for the Reloadly sandbox directory, which
// has billers the live one has not (Kenya, Uganda, EDM Mali, StarTimes Mali, Kano
// postpaid): `pointy-relay services names --missing` against it must be empty.
func TestSandboxSnapshotNamed(t *testing.T) {
	dir := filepath.Join(namesTestSnapshotDir(), "sb")
	var ops []namesTestRawOperator
	if !namesTestReadRaw(t, filepath.Join(dir, "operators_sandbox.json"), &ops) {
		t.Skipf("no Reloadly sandbox snapshot at %s", dir)
	}
	var billers []namesTestRawBiller
	if !namesTestReadRaw(t, filepath.Join(dir, "billers_sandbox.json"), &billers) {
		t.Skipf("no sandbox biller snapshot at %s", dir)
	}
	namesTestCheckRaw(t, "sandbox", ops, billers)
}
