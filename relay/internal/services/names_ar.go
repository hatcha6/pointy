// names_ar.go: the Arabic display names of airtime operators, bill providers
// and bill plans.
//
// The owner's rule (DIRECT_TOPUP_PLAN.md, 2.3) is that everything a cashier or
// a customer reads is Arabic. Reloadly publishes operator, biller and plan names
// in English and French only ("Orange Mali", "Ikeja Electricity Prepaid",
// "Canalplus Acces English Basic (10000/1MOIS)"), so the relay carries its own
// table, embedded from names_ar.json, and the directory sends the Arabic spelling
// as `name` and Reloadly's spelling as `name_en`.
//
// Nothing here is ever invented at run time. A name is either found in the table
// (directly, or assembled from table entries by a documented rule) or the
// function says so with ok == false and the caller keeps the Latin spelling and
// logs it (`pointy-relay services names --missing`).

package services

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"unicode"

	"pointy/relay/internal/vouchers"
)

//go:embed names_ar.json
var arNamesJSON []byte

// NameRef identifies one operator or biller the way Reloadly spells it. It is
// what the tooling hands to MissingOperatorNames and MissingBillerNames.
type NameRef struct {
	Name        string // Reloadly's own spelling, e.g. "Orange Mali"
	CountryISO  string // ISO 3166-1 alpha-2, e.g. "ML"
	CountryName string // Reloadly's English country name, e.g. "Mali" (billers: unused)
}

// OperatorNameAR is the Arabic display name of an airtime operator, e.g.
// ("Orange Mali", "ML", "Mali") -> "أورنج مالي".
//
// How the name is found, in order:
//
//  1. An exact override keyed "<ISO>|<Reloadly name>" (names_ar.json "operators"):
//     the irregular names, whose Latin spelling does not follow
//     "<brand> <country>" ("Uganda Telecom", "Amigo Sin Límite", the US plan
//     variants, the Netherlands Antilles islands, ...). An override writes its
//     country as {country}, filled from vouchers.CountryName.
//  2. Otherwise the regular shape "<brand> <country> [qualifier ...]": the
//     qualifiers after the country ("USD", "Retail", "Promo", "RTR", "mobile")
//     are peeled off, then the trailing country (Reloadly's English name, or one
//     of the spellings it uses in operator names such as "DRC", "DR", "USA",
//     "Ivory Coast", "St Lucia"; failing those, its first word when the rest is
//     a known brand), and the brand left over is looked up in the
//     "brands" table (parentheses such as "(Mobinil)" are noise unless the table
//     keeps them on purpose). The result is "<Arabic brand> <Arabic country>"
//     with the country taken from vouchers.CountryName, plus "(<Arabic
//     qualifier>)" when a qualifier is spoken ("AT&T Mexico USD" ->
//     "إيه تي آند تي المكسيك (بالدولار)"). The country is not repeated when the
//     Arabic brand already says it ("Maroc Telecom" -> "اتصالات المغرب").
//
// countryNameEN is Reloadly's English name of the country ("Mali", "Côte
// d'Ivoire", "The Democratic Republic Of Congo"): the operator's name ends with
// it and it is how the brand is found. Matching ignores case, accents and
// repeated whitespace. An operator whose
// brand is not in the table, or whose country has no Arabic name
// (vouchers.CountryName returns "": Israel is deliberately absent), yields
// ("", false): the caller keeps the Latin spelling and logs it.
func OperatorNameAR(name, countryISO, countryNameEN string) (string, bool) {
	return arNames.operator(name, countryISO, countryNameEN)
}

// BillerNameAR is the Arabic display name of a bill provider, e.g.
// ("Ikeja Electricity Prepaid", "NG") -> "كهرباء إيكيجا (مسبقة الدفع)". Billers
// are few and irregular, so every one is listed under "<ISO>|<Reloadly name>" in
// names_ar.json (the country in it comes from vouchers.CountryName); an unlisted
// biller yields ("", false).
func BillerNameAR(name, countryISO string) (string, bool) {
	return arNames.biller(name, countryISO)
}

// PlanDescriptionAR is the Arabic text of a fixed bill plan, e.g.
// "Canalplus Acces English Basic (10000/1MOIS)" -> "كانال بلس أكسيس إنجليش بيسك – شهر".
//
// The description is "<words> (<amount>/<duration>)", the duration being months
// ("1MOIS") or days ("7JOUR", "30JOURS"). Every word is translated through
// names_ar.json "plan_words" (a word that is not there makes the whole
// description unknown: ("", false)), the duration becomes the text after the
// dash, and the amount is dropped on purpose: the till shows the price
// separately and the plan must not state a second, possibly different, number.
func PlanDescriptionAR(description string) (string, bool) {
	return arNames.plan(description)
}

// BillTypeAR is the Arabic name of a bill type: "electricity" -> "كهرباء",
// "water" -> "مياه", "tv" -> "تلفزيون", "internet" -> "إنترنت", "toll" ->
// "رسوم الطرق". It accepts the wire type and Reloadly's own constant
// ("ELECTRICITY_BILL_PAYMENT", "TOLL_HIGHWAY_BILL_PAYMENT"); anything else is
// "أخرى" ("other"), never an error.
func BillTypeAR(billType string) string {
	return arNames.billType(billType)
}

// ServiceAR is the Arabic name of a bill's payment service: "prepaid" ->
// "مسبق الدفع", "postpaid" -> "لاحق الدفع". An unknown value gives "".
func ServiceAR(service string) string {
	return arNames.service(service)
}

// MissingOperatorNames lists, in input order and without repeats, the operators
// for which OperatorNameAR has no Arabic name. It is the tooling behind
// `pointy-relay services names --missing`: the directory falls back to the Latin
// spelling for exactly these.
func MissingOperatorNames(operators []NameRef) []NameRef {
	return arNamesMissing(operators, func(r NameRef) bool {
		_, ok := OperatorNameAR(r.Name, r.CountryISO, r.CountryName)
		return ok
	})
}

// MissingBillerNames is MissingOperatorNames for bill providers.
func MissingBillerNames(billers []NameRef) []NameRef {
	return arNamesMissing(billers, func(r NameRef) bool {
		_, ok := BillerNameAR(r.Name, r.CountryISO)
		return ok
	})
}

// MissingPlanDescriptions lists, in input order and without repeats, the plan
// descriptions for which PlanDescriptionAR has no Arabic text.
func MissingPlanDescriptions(descriptions []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, d := range descriptions {
		if _, ok := PlanDescriptionAR(d); ok || seen[d] {
			continue
		}
		seen[d] = true
		out = append(out, d)
	}
	return out
}

func arNamesMissing(refs []NameRef, named func(NameRef) bool) []NameRef {
	var out []NameRef
	seen := map[NameRef]bool{}
	for _, r := range refs {
		if named(r) || seen[r] {
			continue
		}
		seen[r] = true
		out = append(out, r)
	}
	return out
}

// arNamesFile mirrors names_ar.json. Every map key is a Reloadly spelling
// (operators and billers are prefixed with the ISO code and a bar); lookups fold
// both sides, so the file is written the way the strings are spelled upstream.
type arNamesFile struct {
	Doc string `json:"doc"`
	// Brands: operator brand once the country is removed -> Arabic brand.
	Brands map[string]string `json:"brands"`
	// Qualifiers: words after the country in an operator name -> the Arabic
	// qualifier shown in parentheses, "" when the word is jargon the cashier
	// must not see ("RTR").
	Qualifiers map[string]string `json:"qualifiers"`
	// CountryAliases: ISO -> the other spellings of the country that Reloadly
	// puts at the end of an operator name ("DRC", "USA", "Ivory Coast").
	CountryAliases map[string][]string `json:"country_aliases"`
	// Operators: "<ISO>|<Reloadly name>" -> the finished Arabic name, with the
	// country written {country}.
	Operators map[string]string `json:"operators"`
	// Billers: "<ISO>|<Reloadly name>" -> the finished Arabic name, with the
	// country written {country}.
	Billers map[string]string `json:"billers"`
	// PlanWords: one word (or "+", or a duration such as "1mois") of a plan
	// description -> Arabic.
	PlanWords map[string]string `json:"plan_words"`
	// BillTypes: electricity, water, tv, internet, toll, other -> Arabic.
	BillTypes map[string]string `json:"bill_types"`
	// Services: prepaid, postpaid -> Arabic.
	Services map[string]string `json:"services"`
	// Review: brand -> where its Arabic spelling comes from, for the owner's
	// review (the review file written by the tests). Never read at run time.
	Review map[string]string `json:"review"`
}

// arNamesTable is names_ar.json with every key folded, built once at start-up.
type arNamesTable struct {
	brands         map[string]string
	qualifiers     map[string]string
	qualifierOrder []string // folded qualifier phrases, longest first
	aliases        map[string][]string
	operators      map[string]string
	billers        map[string]string
	planWords      map[string]string
	billTypes      map[string]string
	services       map[string]string
	review         map[string]string
}

// arNames is the embedded table. A malformed file is a programming error caught
// by the package tests, so loading panics rather than limping on.
var arNames = mustLoadArNames(arNamesJSON)

func mustLoadArNames(raw []byte) *arNamesTable {
	t, err := loadArNames(raw)
	if err != nil {
		panic("services: names_ar.json: " + err.Error())
	}
	return t
}

func loadArNames(raw []byte) (*arNamesTable, error) {
	var f arNamesFile
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&f); err != nil {
		return nil, err
	}
	t := &arNamesTable{aliases: map[string][]string{}}
	var err error
	if t.review, err = arNamesFoldKeys("review", f.Review, ""); err != nil {
		return nil, err
	}
	if t.brands, err = arNamesFoldKeys("brands", f.Brands, ""); err != nil {
		return nil, err
	}
	if t.qualifiers, err = arNamesFoldKeys("qualifiers", f.Qualifiers, ""); err != nil {
		return nil, err
	}
	for phrase := range t.qualifiers {
		t.qualifierOrder = append(t.qualifierOrder, phrase)
	}
	sort.Slice(t.qualifierOrder, func(i, j int) bool {
		a, b := t.qualifierOrder[i], t.qualifierOrder[j]
		if len(a) != len(b) {
			return len(a) > len(b)
		}
		return a < b
	})
	for iso, spellings := range f.CountryAliases {
		for _, s := range spellings {
			t.aliases[strings.ToUpper(iso)] = append(t.aliases[strings.ToUpper(iso)], arNamesFold(s))
		}
	}
	if t.operators, err = arNamesFoldKeys("operators", f.Operators, "iso|name"); err != nil {
		return nil, err
	}
	if t.billers, err = arNamesFoldKeys("billers", f.Billers, "iso|name"); err != nil {
		return nil, err
	}
	if t.planWords, err = arNamesFoldKeys("plan_words", f.PlanWords, ""); err != nil {
		return nil, err
	}
	if t.billTypes, err = arNamesFoldKeys("bill_types", f.BillTypes, ""); err != nil {
		return nil, err
	}
	if t.services, err = arNamesFoldKeys("services", f.Services, ""); err != nil {
		return nil, err
	}
	return t, nil
}

// arNamesFoldKeys folds every key of one section and refuses two keys that fold to the
// same string (two spellings of one thing with, possibly, two different
// answers). With shape "iso|name" the part before the bar is the ISO code and is
// upper-cased, the rest is folded.
func arNamesFoldKeys(section string, in map[string]string, shape string) (map[string]string, error) {
	out := make(map[string]string, len(in))
	for key, value := range in {
		folded := arNamesFold(key)
		if shape == "iso|name" {
			iso, name, ok := strings.Cut(key, "|")
			if !ok {
				return nil, fmt.Errorf("%s: key %q is not <ISO>|<name>", section, key)
			}
			folded = strings.ToUpper(strings.TrimSpace(iso)) + "|" + arNamesFold(name)
		}
		if folded == "" || folded == "|" {
			return nil, fmt.Errorf("%s: empty key", section)
		}
		if _, dup := out[folded]; dup {
			return nil, fmt.Errorf("%s: %q repeats another key once case and spacing are ignored", section, key)
		}
		out[folded] = value
	}
	return out, nil
}

var arNamesAccents = strings.NewReplacer(
	"á", "a", "à", "a", "â", "a", "ä", "a", "ã", "a", "å", "a",
	"é", "e", "è", "e", "ê", "e", "ë", "e",
	"í", "i", "ì", "i", "î", "i", "ï", "i",
	"ó", "o", "ò", "o", "ô", "o", "ö", "o", "õ", "o",
	"ú", "u", "ù", "u", "û", "u", "ü", "u",
	"ç", "c", "ñ", "n",
	"’", "'", "‘", "'", "–", "-", "—", "-",
)

// arNamesFold is the lookup form of a Reloadly spelling: lower case, accents
// and typographic quotes and dashes flattened, whitespace of any kind (tabs and
// non-breaking spaces occur upstream) collapsed to single spaces.
func arNamesFold(s string) string {
	s = arNamesAccents.Replace(strings.ToLower(s))
	return strings.Join(strings.Fields(s), " ")
}

var arNamesParens = regexp.MustCompile(`\([^)]*\)`)

// brand finds the Arabic brand for what is left of an operator name once the
// country is gone, and the table key that matched. A parenthesis the table does
// not keep is noise.
func (t *arNamesTable) brand(folded string) (ar, key string, ok bool) {
	if ar, ok := t.brands[folded]; ok {
		return ar, folded, true
	}
	if bare := arNamesFold(arNamesParens.ReplaceAllString(folded, " ")); bare != folded && bare != "" {
		if ar, ok := t.brands[bare]; ok {
			return ar, bare, true
		}
	}
	return "", "", false
}

// peelQualifier removes the longest qualifier phrase that ends s and returns it.
func (t *arNamesTable) peelQualifier(s string) (rest, phrase string, ok bool) {
	for _, q := range t.qualifierOrder {
		if strings.HasSuffix(s, " "+q) {
			return strings.TrimSpace(strings.TrimSuffix(s, q)), q, true
		}
	}
	return s, "", false
}

// countrySpellings are the ways a country can end an operator name: Reloadly's
// English name, without a leading "The", and the aliases the table lists for the
// ISO code. Longest first, so "Saint Kitts And Nevis" wins over "Nevis".
func (t *arNamesTable) countrySpellings(iso, countryEN string) []string {
	var out []string
	seen := map[string]bool{}
	add := func(s string) {
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	name := arNamesFold(countryEN)
	add(name)
	add(strings.TrimPrefix(name, "the "))
	for _, a := range t.aliases[iso] {
		add(a)
	}
	sort.SliceStable(out, func(i, j int) bool { return len(out[i]) > len(out[j]) })
	return out
}

// arNamesFirstWord is the first word of a country's name, folded, for the names
// of two or more words ("Trinidad and Tobago" -> "trinidad"); "" for the rest.
func arNamesFirstWord(countryEN string) string {
	words := strings.Fields(strings.TrimPrefix(arNamesFold(countryEN), "the "))
	if len(words) < 2 || len(words[0]) < 4 {
		return ""
	}
	return words[0]
}

// arOperatorParts is how an operator name was put together; the tests read it to
// know which table entry produced a name.
type arOperatorParts struct {
	override bool     // the name came straight from the "operators" section
	brandKey string   // the folded brand that was looked up, "" for an override
	spoken   []string // the Arabic qualifiers, in reading order
	name     string   // the finished Arabic name
}

func (t *arNamesTable) operator(name, countryISO, countryNameEN string) (string, bool) {
	parts, ok := t.parseOperator(name, countryISO, countryNameEN)
	return parts.name, ok
}

func (t *arNamesTable) parseOperator(name, countryISO, countryNameEN string) (arOperatorParts, bool) {
	iso := strings.ToUpper(strings.TrimSpace(countryISO))
	folded := arNamesFold(name)
	if folded == "" {
		return arOperatorParts{}, false
	}
	countryAR := vouchers.CountryName(iso)
	if ar, ok := t.operators[iso+"|"+folded]; ok {
		if ar, ok = arNamesWithCountry(ar, countryAR); ok {
			return arOperatorParts{override: true, name: ar}, true
		}
		return arOperatorParts{}, false
	}
	if countryAR == "" {
		return arOperatorParts{}, false
	}

	rest := folded
	var spoken []string // Arabic qualifiers, in reading order
	for {
		var phrase string
		var peeled bool
		rest, phrase, peeled = t.peelQualifier(rest)
		if !peeled {
			break
		}
		if ar := t.qualifiers[phrase]; ar != "" {
			spoken = append([]string{ar}, spoken...)
		}
	}

	stripped := false
	for _, c := range t.countrySpellings(iso, countryNameEN) {
		if strings.HasSuffix(rest, " "+c) {
			rest = strings.TrimSpace(strings.TrimSuffix(rest, c))
			stripped = true
			break
		}
	}
	if !stripped {
		// Last resort: only the first word of the country ("Trinidad" for
		// "Trinidad and Tobago"). It is trusted only when what is left is a
		// brand the table knows, so a stray word is never taken for a country.
		first := arNamesFirstWord(countryNameEN)
		if first != "" && strings.HasSuffix(rest, " "+first) {
			if left := strings.TrimSpace(strings.TrimSuffix(rest, first)); left != "" {
				if _, _, known := t.brand(left); known {
					rest, stripped = left, true
				}
			}
		}
	}
	if !stripped {
		return arOperatorParts{}, false
	}
	brandAR, brandKey, ok := t.brand(rest)
	if !ok {
		return arOperatorParts{}, false
	}

	out := brandAR
	if !arNamesMentions(brandAR, countryAR) {
		out += " " + countryAR
	}
	if len(spoken) > 0 {
		out += " (" + strings.Join(spoken, "، ") + ")"
	}
	return arOperatorParts{brandKey: brandKey, spoken: spoken, name: out}, true
}

// arNamesMentions reports whether an Arabic text already names the country
// (ignoring the definite article), so "اتصالات المغرب" is not followed by
// "المغرب" again.
func arNamesMentions(text, country string) bool {
	stems := func(s string) string {
		var words []string
		for _, w := range strings.FieldsFunc(s, func(r rune) bool {
			return !unicode.IsLetter(r) && !unicode.IsMark(r) && !unicode.IsDigit(r)
		}) {
			if strings.HasPrefix(w, "ال") && len([]rune(w)) > 4 {
				w = strings.TrimPrefix(w, "ال")
			}
			words = append(words, w)
		}
		return " " + strings.Join(words, " ") + " "
	}
	c := stems(country)
	return strings.TrimSpace(c) != "" && strings.Contains(stems(text), c)
}

func (t *arNamesTable) biller(name, countryISO string) (string, bool) {
	iso := strings.ToUpper(strings.TrimSpace(countryISO))
	ar, ok := t.billers[iso+"|"+arNamesFold(name)]
	if !ok {
		return "", false
	}
	return arNamesWithCountry(ar, vouchers.CountryName(iso))
}

// arNamesCountryToken stands for the country's Arabic name in a finished name of
// names_ar.json, so a country is spelled in one place only (vouchers.CountryName).
const arNamesCountryToken = "{country}"

// arNamesWithCountry fills the country token of a finished name. A name that
// wants a country the countries table cannot name is unusable: ("", false).
func arNamesWithCountry(name, countryAR string) (string, bool) {
	if !strings.Contains(name, arNamesCountryToken) {
		return name, true
	}
	if countryAR == "" {
		return "", false
	}
	return strings.ReplaceAll(name, arNamesCountryToken, countryAR), true
}

// arNamesPlanTail is the "(<amount>/<duration>)" that ends a plan description.
var arNamesPlanTail = regexp.MustCompile(`\(\s*[0-9][0-9.,]*\s*/\s*([a-z0-9]+)\s*\)$`)

func (t *arNamesTable) plan(description string) (string, bool) {
	s := arNamesFold(description)
	duration := ""
	if m := arNamesPlanTail.FindStringSubmatch(s); m != nil {
		duration = m[1]
		s = strings.TrimSpace(strings.TrimSuffix(s, m[0]))
	}
	if s == "" || strings.ContainsAny(s, "()/") {
		return "", false
	}
	words := strings.Fields(strings.ReplaceAll(s, "+", " + "))
	out := make([]string, 0, len(words)+2)
	for _, w := range words {
		ar, ok := t.planWords[w]
		if !ok {
			return "", false
		}
		out = append(out, ar)
	}
	text := strings.Join(out, " ")
	if duration != "" {
		d, ok := t.planWords[duration]
		if !ok {
			return "", false
		}
		text += " – " + d
	}
	return text, true
}

func (t *arNamesTable) billType(billType string) string {
	k := arNamesFold(billType)
	k = strings.TrimSuffix(k, "_bill_payment")
	if strings.HasPrefix(k, "toll") {
		k = "toll"
	}
	if ar, ok := t.billTypes[k]; ok {
		return ar
	}
	return t.billTypes["other"]
}

func (t *arNamesTable) service(service string) string {
	return t.services[arNamesFold(service)]
}
