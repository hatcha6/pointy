package services

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/reloadly"
	"pointy/relay/internal/vouchers"
)

// This file makes the directory out of what the supplier lists. v1 scope
// (DIRECT_TOPUP_PLAN.md 2.3): plain airtime operators only (no bundle, data,
// combo or PIN product, and ACTIVE), and every biller. What it builds is the
// STRUCTURE of the directory; prices depend on the operator's pricing settings
// and are put on at render time (directory.go), so the same snapshot serves every
// settings version without being read from Reloadly again.

// snapshot is one reading of the supplier, normalized. It is immutable once
// built: readers share it without a lock.
type snapshot struct {
	at        time.Time
	hash      string
	countries map[string]*countryEntry
	operators map[int64]*operatorEntry
	billers   map[int64]*billerEntry
	// unsupported are the countries the relay names that no service reaches.
	unsupported []Unsupported
	// untranslated are the names the Arabic tables do not have.
	untranslated []MissingName
	stats        buildStats
}

// buildStats say what a build kept and what it left out, for the logs and the
// operator.
type buildStats struct {
	Countries int            `json:"countries"`
	Operators int            `json:"operators"`
	Billers   int            `json:"billers"`
	Skipped   map[string]int `json:"skipped,omitempty"`
	// HiddenPlans counts the bill plans kept out by hiddenPlanWords.
	HiddenPlans int `json:"hidden_plans,omitempty"`
	// Dropped are the countries the supplier lists that have no Arabic name here.
	Dropped []DroppedCountry `json:"dropped_countries,omitempty"`
}

// DroppedCountry is a country the supplier sells in that the directory leaves
// out because the relay has no Arabic name to show for it (the till is Arabic
// only). What it would have offered is counted.
type DroppedCountry struct {
	Code string `json:"code"`
	// Name is the supplier's English name, for the operator's log only.
	Name      string `json:"name"`
	Operators int    `json:"operators"`
	Billers   int    `json:"billers"`
}

// String is the line the log and the status command print: "IL (Israel): 3
// operators, 0 billers".
func (d DroppedCountry) String() string {
	return fmt.Sprintf("%s (%s): %d operators, %d billers", d.Code, d.Name, d.Operators, d.Billers)
}

type countryEntry struct {
	code      string
	nameAR    string
	nameEN    string
	dial      []string
	currency  string
	operators []*operatorEntry
	billers   []*billerEntry
}

// tile is one amount an operator sells and what the recipient is credited for it.
type tile struct {
	amount  *big.Rat
	receive *big.Rat
	// usd is the dollar plan that delivers the same as a plan listed in the
	// operator's own currency (a fixed operator's aligned lists); nil when there
	// is none.
	usd *big.Rat
}

type operatorEntry struct {
	id      int64
	raw     reloadly.Operator
	country string
	// local: amounts are in the operator's own currency and the order says so
	// (useLocalAmount); otherwise they are dollars.
	local           bool
	fixed           bool
	currency        string
	receiveCurrency string
	approximate     bool
	min, max        *big.Rat
	tiles           []tile
	popular         *big.Rat
	nameAR          string
	nameEN          string
	logo            string
}

type billerEntry struct {
	id              int64
	raw             reloadly.Biller
	country         string
	local           bool
	fixed           bool
	currency        string
	approximate     bool
	typ             string
	service         string
	requiresInvoice bool
	min, max        *big.Rat
	tiles           []*big.Rat
	plans           []planEntry
	// hiddenPlans is how many of the supplier's plans hiddenPlanWords kept out.
	hiddenPlans int
	nameAR      string
	nameEN      string
}

type planEntry struct {
	id     int64
	amount *big.Rat
	desc   string
	descAR string
}

// Skip reasons counted in buildStats.
const (
	skipNoCountry      = "no_country"
	skipNoCountryName  = "no_arabic_country_name"
	skipNoAmounts      = "no_amounts"
	skipNoRate         = "no_rate"
	skipNoCost         = "no_priceable_amount"
	skipAllPlansHidden = "all_plans_hidden"
)

// hiddenPlanWords keep a fixed bill plan out of the directory: a plan whose
// English description contains one of these words (any letter case) is not
// offered, so it can be neither listed nor quoted nor ordered. It is a default
// for a conservative market, not a rule of the supplier: Canal+ names its
// adult-content plans "... Charme ..." (8 of the 28 plans of Canal+ Mali).
// Change this one list to change what is hidden; nothing else knows about it.
var hiddenPlanWords = []string{"Charme"}

// planHidden reports whether a plan's English description names a hidden word.
func planHidden(description string) bool {
	text := strings.ToLower(description)
	for _, word := range hiddenPlanWords {
		if word = strings.ToLower(strings.TrimSpace(word)); word != "" && strings.Contains(text, word) {
			return true
		}
	}
	return false
}

// buildSnapshot normalizes raw supplier data. A row that cannot be sold
// (an amount model it cannot price, a rate it lacks) is left out and counted,
// never guessed.
func buildSnapshot(raw Raw, namer Namer, now time.Time) *snapshot {
	missing := &missingTracker{}
	snap := &snapshot{
		at:        now.UTC().Truncate(time.Second),
		countries: map[string]*countryEntry{},
		operators: map[int64]*operatorEntry{},
		billers:   map[int64]*billerEntry{},
		stats:     buildStats{Skipped: map[string]int{}},
	}
	infos := map[string]reloadly.TopupCountry{}
	for _, country := range raw.Countries {
		if iso := strings.ToUpper(strings.TrimSpace(country.ISOName)); iso != "" {
			infos[iso] = country
		}
	}
	skip := func(reason string) { snap.stats.Skipped[reason]++ }
	dropped := droppedTally{}

	for _, op := range raw.Operators {
		if !plainAirtime(op) {
			continue
		}
		// The till is Arabic only: a country the relay cannot name in Arabic is
		// not offered at all, and the build says so once.
		if iso := strings.ToUpper(strings.TrimSpace(op.Country.ISOName)); iso != "" && CountryNameAR(iso) == "" {
			skip(skipNoCountryName)
			dropped.note(iso, firstNonEmpty(op.Country.Name, infos[iso].Name), true)
			continue
		}
		entry, reason := buildOperator(op, infos, namer, missing)
		if entry == nil {
			skip(reason)
			continue
		}
		if _, dup := snap.operators[entry.id]; dup {
			continue
		}
		snap.operators[entry.id] = entry
		country := snap.country(entry.country, infos, op.Country.Name, op.DestinationCurrencyCode)
		country.operators = append(country.operators, entry)
	}
	for _, biller := range raw.Billers {
		if iso := strings.ToUpper(strings.TrimSpace(biller.CountryCode)); iso != "" && CountryNameAR(iso) == "" {
			skip(skipNoCountryName)
			dropped.note(iso, firstNonEmpty(biller.CountryName, infos[iso].Name), false)
			continue
		}
		entry, reason := buildBiller(biller, infos, namer, missing)
		if entry == nil {
			skip(reason)
			continue
		}
		if _, dup := snap.billers[entry.id]; dup {
			continue
		}
		snap.billers[entry.id] = entry
		snap.stats.HiddenPlans += entry.hiddenPlans
		country := snap.country(entry.country, infos, biller.CountryName, biller.LocalTransactionCurrencyCode)
		country.billers = append(country.billers, entry)
	}
	if len(snap.stats.Skipped) == 0 {
		snap.stats.Skipped = nil
	}
	snap.stats.Dropped = dropped.list()
	for _, country := range snap.countries {
		sort.SliceStable(country.operators, func(i, j int) bool {
			a, b := country.operators[i], country.operators[j]
			if ka, kb := arabicSortKey(a.nameAR), arabicSortKey(b.nameAR); ka != kb {
				return ka < kb
			}
			return a.id < b.id
		})
		sort.SliceStable(country.billers, func(i, j int) bool {
			a, b := country.billers[i], country.billers[j]
			if ra, rb := billTypeRank(a.typ), billTypeRank(b.typ); ra != rb {
				return ra < rb
			}
			if ka, kb := arabicSortKey(a.nameAR), arabicSortKey(b.nameAR); ka != kb {
				return ka < kb
			}
			return a.id < b.id
		})
	}
	snap.stats.Countries = len(snap.countries)
	snap.stats.Operators = len(snap.operators)
	snap.stats.Billers = len(snap.billers)
	snap.unsupported = unsupportedCountries(snap.countries)
	snap.untranslated = missing.list()
	snap.hash = snap.fingerprint()
	return snap
}

// country returns the entry of a country, making it from the supplier's country
// list (or, failing that, from what the operator or biller itself says). Only a
// country with an Arabic name gets here (buildSnapshot drops the others).
func (s *snapshot) country(
	code string,
	infos map[string]reloadly.TopupCountry,
	fallbackName, fallbackCurrency string,
) *countryEntry {
	if entry, ok := s.countries[code]; ok {
		return entry
	}
	info := infos[code]
	entry := &countryEntry{code: code, nameEN: firstNonEmpty(info.Name, fallbackName)}
	entry.dial = dialDigits(info.CallingCodes)
	entry.currency = strings.ToUpper(firstNonEmpty(info.CurrencyCode, fallbackCurrency))
	entry.nameAR = CountryNameAR(code)
	s.countries[code] = entry
	return entry
}

// droppedTally counts, per country, the operators and billers a build left out
// because the country has no Arabic name.
type droppedTally map[string]*DroppedCountry

func (d droppedTally) note(code, name string, operator bool) {
	entry := d[code]
	if entry == nil {
		entry = &DroppedCountry{Code: code, Name: name}
		d[code] = entry
	}
	if operator {
		entry.Operators++
	} else {
		entry.Billers++
	}
}

// list is the tally in country-code order, nil when nothing was dropped.
func (d droppedTally) list() []DroppedCountry {
	if len(d) == 0 {
		return nil
	}
	out := make([]DroppedCountry, 0, len(d))
	for _, entry := range d {
		out = append(out, *entry)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Code < out[j].Code })
	return out
}

func dialDigits(codes []string) []string {
	out := make([]string, 0, len(codes))
	seen := map[string]bool{}
	for _, code := range codes {
		code = strings.TrimLeft(strings.TrimSpace(code), "+")
		if code != "" && !seen[code] {
			seen[code] = true
			out = append(out, code)
		}
	}
	return out
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

// plainAirtime is v1's operator scope: credit, nothing else, and on sale.
func plainAirtime(op reloadly.Operator) bool {
	return !op.Bundle && !op.Data && !op.ComboProduct && !op.Pin &&
		strings.EqualFold(strings.TrimSpace(op.Status), "ACTIVE")
}

func buildOperator(
	op reloadly.Operator,
	infos map[string]reloadly.TopupCountry,
	namer Namer,
	missing *missingTracker,
) (*operatorEntry, string) {
	iso := strings.ToUpper(strings.TrimSpace(op.Country.ISOName))
	if iso == "" || op.Key() == 0 {
		return nil, skipNoCountry
	}
	sender := strings.ToUpper(strings.TrimSpace(op.SenderCurrencyCode))
	if sender == "" {
		sender = "USD"
	}
	dest := strings.ToUpper(strings.TrimSpace(op.DestinationCurrencyCode))
	rate := positiveRat(op.FX.Rate)
	fixed := op.DenominationType == reloadly.Fixed

	entry := &operatorEntry{id: op.Key(), raw: op, country: iso, fixed: fixed}
	entry.local = op.SupportsLocalAmounts && dest != "" && dest != sender && hasAirtimeAmounts(op, true)
	if !entry.local && !hasAirtimeAmounts(op, false) {
		return nil, skipNoAmounts
	}
	aligned := fixed && len(op.LocalFixedAmounts) > 0 && len(op.LocalFixedAmounts) == len(op.FixedAmounts)
	entry.approximate = !entry.local && dest != "" && dest != sender && !aligned
	if (entry.local || entry.approximate) && rate == nil {
		return nil, skipNoRate
	}
	if entry.local {
		entry.currency = dest
	} else {
		entry.currency = sender
	}
	entry.receiveCurrency = firstNonEmpty(dest, sender)
	entry.min, entry.max = reloadly.AirtimeLimits(op, entry.local)

	if entry.local {
		entry.popular = rat(op.MostPopularLocalAmount)
	} else {
		entry.popular = rat(op.MostPopularAmount)
	}
	receive := func(index int, amount *big.Rat) *big.Rat {
		switch {
		case entry.local || (!entry.approximate && !aligned):
			return amount
		case aligned:
			if index >= 0 {
				if value := rat(op.LocalFixedAmounts[index]); value != nil {
					return value
				}
			}
			return amount
		}
		if mapped, ok := mappedReceive(op, amount); ok {
			return mapped
		}
		return roundDecimals(new(big.Rat).Mul(amount, rate), 2)
	}

	var tiles []tile
	switch {
	case fixed && entry.local:
		for index, listed := range op.LocalFixedAmounts {
			amount := rat(listed)
			if amount == nil || amount.Sign() <= 0 || tileListed(tiles, amount) {
				continue
			}
			t := tile{amount: amount, receive: amount}
			if aligned {
				if dollars := rat(op.FixedAmounts[index]); dollars != nil && dollars.Sign() > 0 {
					t.usd = dollars
				}
			}
			tiles = append(tiles, t)
		}
	case fixed:
		for index, amount := range op.FixedAmounts {
			value := rat(amount)
			if value == nil || value.Sign() <= 0 {
				continue
			}
			tiles = append(tiles, tile{amount: value, receive: receive(indexIf(aligned, index), value)})
		}
	default:
		if entry.min == nil || entry.max == nil || entry.min.Sign() <= 0 || entry.max.Cmp(entry.min) < 0 {
			return nil, skipNoAmounts
		}
		var perUSD *big.Rat
		if entry.local {
			perUSD = rate
		}
		for _, amount := range Suggest(SuggestInput{Min: entry.min, Max: entry.max, PerUSD: perUSD, Popular: entry.popular}) {
			tiles = append(tiles, tile{amount: amount, receive: receive(-1, amount)})
		}
	}
	// Only amounts that can be priced are offered, and (of a range operator's)
	// only the ones an order would not refuse for their decimals.
	kept := tiles[:0]
	for _, t := range tiles {
		if !fixed && !amountFitsCurrency(t.amount, entry.currency) {
			continue
		}
		if cost, ok := reloadly.AirtimeCost(op, t.amount, entry.local); ok && cost.Sign() > 0 {
			kept = append(kept, t)
		}
	}
	entry.tiles = kept
	if len(entry.tiles) == 0 {
		return nil, skipNoCost
	}
	sort.SliceStable(entry.tiles, func(i, j int) bool { return entry.tiles[i].amount.Cmp(entry.tiles[j].amount) < 0 })
	if entry.popular != nil && (!entry.accepts(entry.popular) || (!fixed && !amountFitsCurrency(entry.popular, entry.currency))) {
		entry.popular = nil
	}

	entry.nameEN = strings.TrimSpace(op.Name)
	countryEN := firstNonEmpty(op.Country.Name, infos[iso].Name)
	if name, ok := namer.Operator(entry.nameEN, iso, countryEN); ok && strings.TrimSpace(name) != "" {
		entry.nameAR = strings.TrimSpace(name)
	} else {
		entry.nameAR = entry.nameEN
		missing.add("operator", entry.nameEN, iso)
	}
	if len(op.LogoURLs) > 0 {
		entry.logo = strings.TrimSpace(op.LogoURLs[0])
	}
	return entry, ""
}

func tileListed(tiles []tile, amount *big.Rat) bool {
	for _, t := range tiles {
		if t.amount.Cmp(amount) == 0 {
			return true
		}
	}
	return false
}

func indexIf(condition bool, index int) int {
	if condition {
		return index
	}
	return -1
}

// accepts reports whether an amount is one the operator sells (inside its
// limits for a range operator, in its list for a fixed one).
func (e *operatorEntry) accepts(amount *big.Rat) bool {
	return reloadly.AirtimeAmountAllowed(e.raw, amount, e.local)
}

func hasAirtimeAmounts(op reloadly.Operator, local bool) bool {
	if op.DenominationType == reloadly.Fixed {
		lo, hi := reloadly.AirtimeLimits(op, local)
		return lo != nil && hi != nil
	}
	lo, hi := reloadly.AirtimeLimits(op, local)
	return lo != nil && hi != nil && lo.Sign() > 0 && hi.Cmp(lo) >= 0
}

// mappedReceive is the destination amount Reloadly lists for a sender amount
// (suggestedAmountsMap), when it lists one.
func mappedReceive(op reloadly.Operator, amount *big.Rat) (*big.Rat, bool) {
	for key, value := range op.SuggestedAmountsMap {
		listed, ok := new(big.Rat).SetString(strings.TrimSpace(key))
		if !ok || listed.Cmp(amount) != 0 {
			continue
		}
		if received := rat(value); received != nil && received.Sign() > 0 {
			return received, true
		}
	}
	return nil, false
}

func rat(n reloadly.Num) *big.Rat {
	value, ok := n.Rat()
	if !ok {
		return nil
	}
	return value
}

func positiveRat(n reloadly.Num) *big.Rat {
	if value := rat(n); value != nil && value.Sign() > 0 {
		return value
	}
	return nil
}

func buildBiller(
	b reloadly.Biller,
	infos map[string]reloadly.TopupCountry,
	namer Namer,
	missing *missingTracker,
) (*billerEntry, string) {
	iso := strings.ToUpper(strings.TrimSpace(b.CountryCode))
	if iso == "" || b.ID == 0 {
		return nil, skipNoCountry
	}
	fixed := b.DenominationType == reloadly.Fixed
	entry := &billerEntry{
		id:              b.ID,
		raw:             b,
		country:         iso,
		fixed:           fixed,
		typ:             billTypeOf(b.Type),
		service:         billServiceOf(b),
		requiresInvoice: b.RequiresInvoice,
	}
	entry.local = b.LocalAmountSupported && strings.TrimSpace(b.LocalTransactionCurrencyCode) != "" && hasBillAmounts(b, true)
	switch {
	case entry.local:
		entry.currency = strings.ToUpper(strings.TrimSpace(b.LocalTransactionCurrencyCode))
	case b.InternationalAmountSupported && hasBillAmounts(b, false):
		entry.currency = strings.ToUpper(firstNonEmpty(b.InternationalTransactionCurrencyCode, "USD"))
		entry.approximate = true
	default:
		return nil, skipNoAmounts
	}
	rate := positiveRat(b.FX.Rate)
	if entry.local && rate == nil {
		return nil, skipNoRate
	}
	entry.min, entry.max = reloadly.BillLimits(b, entry.local)

	if fixed {
		list := b.InternationalFixedAmounts
		if entry.local {
			list = b.LocalFixedAmounts
		}
		for _, plan := range list {
			amount := rat(plan.Amount)
			if amount == nil || amount.Sign() <= 0 {
				continue
			}
			if cost, ok := reloadly.BillCost(b, amount, entry.local); !ok || cost.Sign() <= 0 {
				continue
			}
			description := strings.TrimSpace(plan.Description)
			if planHidden(description) {
				entry.hiddenPlans++
				continue
			}
			entry.plans = append(entry.plans, planEntry{id: plan.ID, amount: amount, desc: description})
		}
		if len(entry.plans) == 0 {
			if entry.hiddenPlans > 0 {
				return nil, skipAllPlansHidden
			}
			return nil, skipNoCost
		}
		sort.SliceStable(entry.plans, func(i, j int) bool {
			if c := entry.plans[i].amount.Cmp(entry.plans[j].amount); c != 0 {
				return c < 0
			}
			return entry.plans[i].id < entry.plans[j].id
		})
		for i := range entry.plans {
			if ar, ok := namer.Plan(entry.plans[i].desc); ok && strings.TrimSpace(ar) != "" {
				entry.plans[i].descAR = strings.TrimSpace(ar)
			} else {
				entry.plans[i].descAR = entry.plans[i].desc
				missing.add("plan", entry.plans[i].desc, "")
			}
		}
	} else {
		if entry.min == nil || entry.max == nil || entry.min.Sign() <= 0 || entry.max.Cmp(entry.min) < 0 {
			return nil, skipNoAmounts
		}
		var perUSD *big.Rat
		if entry.local {
			perUSD = rate
		}
		for _, amount := range Suggest(SuggestInput{Min: entry.min, Max: entry.max, PerUSD: perUSD}) {
			if !amountFitsCurrency(amount, entry.currency) {
				continue
			}
			if cost, ok := reloadly.BillCost(b, amount, entry.local); ok && cost.Sign() > 0 {
				entry.tiles = append(entry.tiles, amount)
			}
		}
		if len(entry.tiles) == 0 {
			return nil, skipNoCost
		}
	}

	entry.nameEN = strings.TrimSpace(b.Name)
	if name, ok := namer.Biller(entry.nameEN, iso); ok && strings.TrimSpace(name) != "" {
		entry.nameAR = strings.TrimSpace(name)
	} else {
		entry.nameAR = entry.nameEN
		missing.add("biller", entry.nameEN, iso)
	}
	return entry, ""
}

func hasBillAmounts(b reloadly.Biller, local bool) bool {
	lo, hi := reloadly.BillLimits(b, local)
	if b.DenominationType == reloadly.Fixed {
		return lo != nil && hi != nil
	}
	return lo != nil && hi != nil && lo.Sign() > 0 && hi.Cmp(lo) >= 0
}

func billTypeOf(raw string) string {
	switch strings.ToUpper(strings.TrimSpace(raw)) {
	case reloadly.BillerElectricity:
		return BillElectricity
	case reloadly.BillerWater:
		return BillWater
	case reloadly.BillerTV:
		return BillTV
	case reloadly.BillerInternet:
		return BillInternet
	case reloadly.BillerToll:
		return BillToll
	}
	return BillOther
}

func billServiceOf(b reloadly.Biller) string {
	switch strings.ToUpper(strings.TrimSpace(b.ServiceType)) {
	case "PREPAID":
		return ServicePrepaid
	case "POSTPAID":
		return ServicePostpaid
	}
	if b.RequiresInvoice {
		return ServicePostpaid
	}
	return ServicePrepaid
}

// billTypeRank orders the types the way the till lists them.
func billTypeRank(typ string) int {
	switch typ {
	case BillElectricity:
		return 0
	case BillWater:
		return 1
	case BillTV:
		return 2
	case BillInternet:
		return 3
	case BillToll:
		return 4
	}
	return 5
}

// unsupportedCountries lists every country the relay knows by name that has no
// service. The relay's country table has no list of its own, so every code is
// asked for.
func unsupportedCountries(served map[string]*countryEntry) []Unsupported {
	var out []Unsupported
	for first := 'A'; first <= 'Z'; first++ {
		for second := 'A'; second <= 'Z'; second++ {
			code := string([]rune{first, second})
			if code == vouchers.CountryWorldwide || code == vouchers.CountryEurope {
				continue
			}
			if _, ok := served[code]; ok {
				continue
			}
			if name := CountryNameAR(code); name != "" {
				out = append(out, Unsupported{Code: code, Name: name})
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if a, b := arabicSortKey(out[i].Name), arabicSortKey(out[j].Name); a != b {
			return a < b
		}
		return out[i].Code < out[j].Code
	})
	return out
}

// fingerprint identifies everything this snapshot sells from: the structure the
// shops see, AND every row of the supplier's own data that a price, a limit or a
// tile is computed from (commissions and discounts, fees, rates, plan lists).
// A reading with the fingerprint of the one in use is the same directory in
// every respect and changes nothing; one that differs in any of them must
// replace it, or a change of commission at the supplier would never reach a
// quote. Rows are hashed in id order, so the order Reloadly lists them in does
// not matter.
func (s *snapshot) fingerprint() string {
	hash := sha256.New()
	encoder := json.NewEncoder(hash)
	view := struct {
		Countries   []Country        `json:"countries"`
		Unsupported []Unsupported    `json:"unsupported"`
		Dropped     []DroppedCountry `json:"dropped"`
		HiddenPlans int              `json:"hidden_plans"`
	}{Countries: s.structure(), Unsupported: s.unsupported, Dropped: s.stats.Dropped, HiddenPlans: s.stats.HiddenPlans}
	if err := encoder.Encode(view); err != nil {
		return s.unhashable()
	}
	operators := make([]int64, 0, len(s.operators))
	for id := range s.operators {
		operators = append(operators, id)
	}
	sort.Slice(operators, func(i, j int) bool { return operators[i] < operators[j] })
	for _, id := range operators {
		if err := encoder.Encode(s.operators[id].raw); err != nil {
			return s.unhashable()
		}
	}
	billers := make([]int64, 0, len(s.billers))
	for id := range s.billers {
		billers = append(billers, id)
	}
	sort.Slice(billers, func(i, j int) bool { return billers[i] < billers[j] })
	for _, id := range billers {
		if err := encoder.Encode(s.billers[id].raw); err != nil {
			return s.unhashable()
		}
	}
	return hex.EncodeToString(hash.Sum(nil)[:8])
}

// unhashable is the fingerprint of a snapshot that could not be hashed (it
// cannot happen with the types involved): unique to the moment it was read, so
// it is never mistaken for the one in use.
func (s *snapshot) unhashable() string {
	return "u" + strconv.FormatInt(s.at.UnixNano(), 36)
}
