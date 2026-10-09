package vouchers

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"strings"
	"time"
)

// The company sells more than cards: credit sent straight to a phone number
// abroad ("airtime") and bill payments ("bill"), both bought from Reloadly in
// dollars. What one costs a shop and what the shop's customer is asked to pay
// are dinar prices worked out from Reloadly's dollar cost by the knobs below:
//
//	cost_lyd     = cost_usd * usd_rate * (1 + funding_percent/100)
//	shop price   = round UP to 0.01 of cost_lyd * (1 + shop_markup_percent/100)
//	retail price = round UP to retail_step of cost_lyd * (1 + retail_markup_percent/100),
//	               never below shop price + min_shop_margin
//
// The knobs are the operator's. They are published like a catalog (every
// version kept, the newest current; `pointy-relay vouchers settings`) and the
// code decides none of them: the values DefaultSettings fills in are
// DEMONSTRATION numbers, not decisions, and everything that shows settings says
// which of them are still those. Only usd_rate has no default — without it
// Reloadly cannot be priced, and nothing is ever priced by guess.
//
// Money is *big.Rat throughout: a price is exact, never a float.

// Service kinds priced from the settings. Anything else is priced like airtime.
const (
	ServiceKindAirtime = "airtime"
	ServiceKindBill    = "bill"
)

// The demonstration defaults. They only make the relay usable before the owner
// has decided; the card shelf's own markups (ops/catalog) start from the same
// numbers.
const (
	DefaultFundingPercent      = "0"
	DefaultShopMarkupPercent   = "2"
	DefaultRetailMarkupPercent = "5.5"
	DefaultRetailStep          = "0.25"
	DefaultMinShopMargin       = "0.10"
)

// In which currency the company orders from Reloadly. Reloadly pays its commission
// (a discount of about 5 % on a typical operator) on an order placed in US dollars
// and forfeits it on one placed in the recipient's own currency (Orange Mali: 4
// dollars cost 3.80, while 2,000 CFA francs cost exactly their dollar value). So
// the customer always picks a local amount, and the company decides what it
// orders:
//
//	usd    airtime: the order goes out in dollars, rounded UP from the local amount
//	       plus a small buffer (the recipient receives at least what was asked)
//	auto   bills: dollars only where they are cheaper and the payment need not be
//	       exact (a prepaid meter on a range biller, no invoice); everything else
//	       exact, in the local currency
//	local  the exact local amount, no commission
//
// The default keeps the commission. Like every knob, it is the owner's to confirm.
const (
	OrderModeUSD   = "usd"
	OrderModeAuto  = "auto"
	OrderModeLocal = "local"

	DefaultAirtimeOrderMode = OrderModeUSD
	DefaultBillsOrderMode   = OrderModeAuto
	DefaultUSDBufferPercent = "0.5"
)

// maxUSDBufferPercent bounds the buffer: it absorbs a rate that moved a hair, it
// is not a surcharge.
const maxUSDBufferPercent = 25

// maxPopularCountries bounds the popular list: it is a grid on the till, not a
// second country list.
const maxPopularCountries = 60

// defaultPopular is the countries a Libyan shop's customers send credit to most
// often, in the order the till shows them.
var defaultPopular = []string{
	"NE", "ML", "NG", "EG", "GH", "SN", "TN", "BD", "PK", "IN",
	"PH", "TR", "MA", "DZ", "CM", "BF", "CI", "GN", "GM", "ET",
}

var (
	// A rate or a percentage: digits and at most nine decimals. No sign and no
	// exponent — a settings value is typed and read by people.
	settingsNumberPattern = regexp.MustCompile(`^\d{1,12}(\.\d{1,9})?$`)
	// A dinar amount the till shows: at most two decimals.
	settingsDinarPattern   = regexp.MustCompile(`^\d{1,12}(\.\d{1,2})?$`)
	settingsCountryPattern = regexp.MustCompile(`^[A-Z]{2}$`)
	// One cent of a dinar: shop prices are rounded up to it.
	settingsCent    = big.NewRat(1, 100)
	settingsOne     = big.NewRat(1, 1)
	settingsHundred = big.NewRat(100, 1)
)

// Settings are the pricing knobs of the services. Every number is a decimal
// string. A blank field means "the default" (usd_rate: unset); Normalized
// writes the defaults out.
type Settings struct {
	// USDRate is how many dinars the company really pays for a dollar. Empty:
	// unset, and Reloadly cannot be priced.
	USDRate string `json:"usd_rate,omitempty"`
	// FundingPercent is the fee of filling the Reloadly account (card, bank or
	// crypto), as a percentage of the dollars bought. Default "0".
	FundingPercent string         `json:"funding_percent,omitempty"`
	Airtime        ServicePricing `json:"airtime"`
	Bills          ServicePricing `json:"bills"`
	// Margin is the company's margin policy (see margin.go); Airtime.Margin,
	// Bills.Margin and CardMargin override single fields of it per kind.
	Margin     Margin  `json:"margin"`
	CardMargin *Margin `json:"card_margin,omitempty"`
	// USDRateSource is "fulus" (default: the relay's live fulus.ly rate, the
	// manual USDRate being the fallback) or "manual". USDRateSeries is "cash"
	// (default) or "bank" with USDRateBankCode; USDRateBufferPercent is added on
	// top of the live rate; a live rate older than USDRateMaxAge (default 48h) is
	// not believed.
	USDRateSource        string `json:"usd_rate_source,omitempty"`
	USDRateSeries        string `json:"usd_rate_series,omitempty"`
	USDRateBankCode      string `json:"usd_rate_bank_code,omitempty"`
	USDRateBufferPercent string `json:"usd_rate_buffer_percent,omitempty"`
	USDRateMaxAge        string `json:"usd_rate_max_age,omitempty"`
	// Legacy fields of settings published before the margin policy: read, turned
	// into Margin by Normalized, never written back.
	RetailStep    string `json:"retail_step,omitempty"`
	MinShopMargin string `json:"min_shop_margin,omitempty"`
	// Popular is the countries shown first on the till, in order (ISO 3166-1
	// alpha-2). Empty: the default list.
	Popular []string `json:"popular,omitempty"`

	// Set by the relay at load time, never stored: the live rate priced by and
	// why there is none.
	liveRate    *big.Rat
	RateProblem string `json:"-"`
}

// ServicePricing is the margin on one kind of service, as percentages of the
// dinar cost (defaults "2" and "5.5"), and how its orders are placed.
type ServicePricing struct {
	// Margin overrides fields of the global margin for this kind.
	Margin *Margin `json:"margin,omitempty"`
	// Legacy percentage pair, read and turned into Margin by Normalized.
	ShopMarkupPercent   string `json:"shop_markup_percent,omitempty"`
	RetailMarkupPercent string `json:"retail_markup_percent,omitempty"`
	// OrderMode is the currency orders are placed with Reloadly in: "usd" (the
	// default) or "local" for airtime, "auto" (the default) or "local" for bills.
	// See OrderModeUSD.
	OrderMode string `json:"order_mode,omitempty"`
	// USDBufferPercent is what a dollar order is rounded up by, as a percentage of
	// the local amount's dollar value, so the recipient never receives less than
	// the amount asked when Reloadly's rate moved a hair since the directory was
	// read. Default "0.5".
	USDBufferPercent string `json:"usd_buffer_percent,omitempty"`
	// ServiceFeeLYD is a flat fee in dinars added on top of the margin to BOTH
	// what the shop pays and the suggested retail. The company keeps all of it
	// (it is not split with the shop). Default "2" for airtime, "0" for bills.
	ServiceFeeLYD string `json:"service_fee_lyd,omitempty"`
}

// Default flat service fees, in dinars.
const (
	DefaultAirtimeServiceFee = "2"
	DefaultBillsServiceFee   = "0"
)

func defaultServiceFee(kind string) string {
	if strings.ToLower(strings.TrimSpace(kind)) == ServiceKindBill {
		return DefaultBillsServiceFee
	}
	return DefaultAirtimeServiceFee
}

// DefaultSettings are the demonstration settings: every knob at its default and
// no dollar rate. Nothing is sold from Reloadly at these until a rate is set.
func DefaultSettings() Settings { return Settings{}.Normalized() }

// DefaultPopularCountries is the default popular list, a copy to keep.
func DefaultPopularCountries() []string { return append([]string(nil), defaultPopular...) }

// Normalized writes the defaults out, trims every field and upper-cases and
// de-duplicates the popular codes (an empty list becomes the default one). It
// does not judge values: Validate does, and ParseSettings runs both.
func (s Settings) Normalized() Settings {
	margin := s.Margin.trimmed()
	if margin.RoundStep == "" {
		margin.RoundStep = strings.TrimSpace(s.RetailStep)
	}
	if margin.MinShopMargin == "" {
		margin.MinShopMargin = strings.TrimSpace(s.MinShopMargin)
	}
	out := Settings{
		USDRate:              strings.TrimSpace(s.USDRate),
		FundingPercent:       settingsOr(s.FundingPercent, DefaultFundingPercent),
		Airtime:              s.Airtime.normalized(ServiceKindAirtime),
		Bills:                s.Bills.normalized(ServiceKindBill),
		Margin:               margin.withDefaults(),
		USDRateSource:        strings.ToLower(settingsOr(s.USDRateSource, RateSourceFulus)),
		USDRateSeries:        strings.ToLower(settingsOr(s.USDRateSeries, RateSeriesCash)),
		USDRateBankCode:      strings.ToLower(strings.TrimSpace(s.USDRateBankCode)),
		USDRateBufferPercent: settingsOr(s.USDRateBufferPercent, DefaultRateBufferPercent),
		USDRateMaxAge:        settingsOr(s.USDRateMaxAge, DefaultRateMaxAge),
		Popular:              settingsNormalizedPopular(s.Popular),
		liveRate:             s.liveRate,
		RateProblem:          s.RateProblem,
	}
	if s.CardMargin != nil && !s.CardMargin.isZero() {
		card := s.CardMargin.trimmed()
		out.CardMargin = &card
	}
	return out
}

func (p ServicePricing) normalized(kind string) ServicePricing {
	out := ServicePricing{
		OrderMode:        strings.ToLower(settingsOr(p.OrderMode, defaultOrderMode(kind))),
		USDBufferPercent: settingsOr(p.USDBufferPercent, DefaultUSDBufferPercent),
		ServiceFeeLYD:    settingsOr(p.ServiceFeeLYD, defaultServiceFee(kind)),
	}
	if p.Margin != nil && !p.Margin.isZero() {
		margin := p.Margin.trimmed()
		out.Margin = &margin
	} else if legacyShop, legacyRetail := strings.TrimSpace(p.ShopMarkupPercent), strings.TrimSpace(p.RetailMarkupPercent); legacyShop != "" || legacyRetail != "" {
		// A pair published before the margin policy. The old demo pair (2, 5.5)
		// was never a decision; anything else keeps its meaning.
		shop, retail := settingsOr(legacyShop, "2"), settingsOr(legacyRetail, "5.5")
		if !settingsSameNumber(shop, "2") || !settingsSameNumber(retail, "5.5") {
			out.Margin = legacyMargin(shop, retail)
		}
	}
	return out
}

// defaultOrderMode is the order mode of a kind of service nobody chose.
func defaultOrderMode(kind string) string {
	if strings.ToLower(strings.TrimSpace(kind)) == ServiceKindBill {
		return DefaultBillsOrderMode
	}
	return DefaultAirtimeOrderMode
}

// orderModes are the order modes a kind of service accepts, default first.
func orderModes(kind string) []string {
	if strings.ToLower(strings.TrimSpace(kind)) == ServiceKindBill {
		return []string{OrderModeAuto, OrderModeLocal}
	}
	return []string{OrderModeUSD, OrderModeLocal}
}

func settingsOr(value, fallback string) string {
	if value = strings.TrimSpace(value); value != "" {
		return value
	}
	return fallback
}

func settingsNormalizedPopular(codes []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(codes))
	for _, code := range codes {
		code = strings.ToUpper(strings.TrimSpace(code))
		if code == "" || seen[code] {
			continue
		}
		seen[code] = true
		out = append(out, code)
	}
	if len(out) == 0 {
		return DefaultPopularCountries()
	}
	return out
}

// Clone is a copy that shares no slice with the original.
func (s Settings) Clone() Settings {
	s.Popular = append([]string(nil), s.Popular...)
	s.Margin = s.Margin.clone()
	for _, m := range []**Margin{&s.CardMargin, &s.Airtime.Margin, &s.Bills.Margin} {
		if *m != nil {
			c := (*m).clone()
			*m = &c
		}
	}
	return s
}

// Pricing is the margin block of a service kind.
func (s Settings) Pricing(kind string) ServicePricing {
	if strings.ToLower(strings.TrimSpace(kind)) == ServiceKindBill {
		return s.Bills.normalized(ServiceKindBill)
	}
	return s.Airtime.normalized(ServiceKindAirtime)
}

// OrderMode is how orders of a kind are placed with Reloadly: OrderModeUSD,
// OrderModeAuto or OrderModeLocal (the default of the kind when unset or unknown).
func (s Settings) OrderMode(kind string) string {
	mode := s.Pricing(kind).OrderMode
	for _, allowed := range orderModes(kind) {
		if mode == allowed {
			return mode
		}
	}
	return defaultOrderMode(kind)
}

// USDBufferPercent is the buffer dollar orders of a kind are rounded up by, as
// the percentage itself (0.5 is half a percent). nil when it does not read.
func (s Settings) USDBufferPercent(kind string) *big.Rat {
	value, ok := settingsRat(s.Pricing(kind).USDBufferPercent, settingsNumberPattern)
	if !ok {
		return nil
	}
	return value
}

// Priced reports whether Reloadly can be priced at all: a dollar rate is set.
func (s Settings) Priced() bool {
	rate, _ := s.EffectiveUSDRate()
	return rate != nil && rate.Sign() > 0
}

// SettingsProblems is every problem a settings document has; valid settings
// have none. It is the error ParseSettings returns for a document it can read
// but not accept.
type SettingsProblems []Problem

func (p SettingsProblems) Error() string {
	if len(p) == 0 {
		return "no problems"
	}
	parts := make([]string, 0, len(p))
	for _, problem := range p {
		parts = append(parts, problem.Path+": "+problem.Message)
	}
	return "invalid voucher settings: " + strings.Join(parts, "; ")
}

// Validate returns every problem with the settings; none means they can be
// published. A blank field is fine (it is the default).
func (s Settings) Validate() SettingsProblems {
	var problems SettingsProblems
	add := func(path, format string, args ...any) {
		problems = append(problems, Problem{Path: path, Message: fmt.Sprintf(format, args...)})
	}
	number := func(path, raw, example string, aboveZero bool) {
		value, ok := settingsRat(raw, settingsNumberPattern)
		switch {
		case !ok:
			add(path, "must be a number without a sign and with at most nine decimals, such as %s", example)
		case aboveZero && value.Sign() <= 0:
			add(path, "must be above zero")
		}
	}
	dinars := func(path, raw, example string, aboveZero bool) {
		value, ok := settingsRat(raw, settingsDinarPattern)
		switch {
		case !ok:
			add(path, "must be dinars with at most two decimals, such as %s", example)
		case aboveZero && value.Sign() <= 0:
			add(path, "must be above zero")
		}
	}

	if rate := strings.TrimSpace(s.USDRate); rate != "" {
		number("usd_rate", rate, "9.71", true)
	}
	number("funding_percent", settingsOr(s.FundingPercent, DefaultFundingPercent), "0", false)
	number("airtime.shop_markup_percent", settingsOr(s.Airtime.ShopMarkupPercent, DefaultShopMarkupPercent), "2", false)
	number("airtime.retail_markup_percent", settingsOr(s.Airtime.RetailMarkupPercent, DefaultRetailMarkupPercent), "5.5", false)
	number("bills.shop_markup_percent", settingsOr(s.Bills.ShopMarkupPercent, DefaultShopMarkupPercent), "2", false)
	number("bills.retail_markup_percent", settingsOr(s.Bills.RetailMarkupPercent, DefaultRetailMarkupPercent), "5.5", false)
	s.Margin.validate("margin.", add)
	for _, o := range []struct {
		prefix string
		m      *Margin
	}{{"card_margin.", s.CardMargin}, {"airtime.margin.", s.Airtime.Margin}, {"bills.margin.", s.Bills.Margin}} {
		if o.m != nil {
			o.m.validate(o.prefix, add)
		}
	}
	if src := strings.ToLower(settingsOr(s.USDRateSource, RateSourceFulus)); src != RateSourceFulus && src != RateSourceManual {
		add("usd_rate_source", "must be fulus or manual")
	}
	switch series := strings.ToLower(settingsOr(s.USDRateSeries, RateSeriesCash)); {
	case series != RateSeriesCash && series != RateSeriesBank:
		add("usd_rate_series", "must be cash or bank")
	case series == RateSeriesBank && strings.TrimSpace(s.USDRateBankCode) == "":
		add("usd_rate_bank_code", "a bank series needs the bank's code")
	}
	number("usd_rate_buffer_percent", settingsOr(s.USDRateBufferPercent, DefaultRateBufferPercent), "0.5", false)
	if age, err := time.ParseDuration(settingsOr(s.USDRateMaxAge, DefaultRateMaxAge)); err != nil || age <= 0 {
		add("usd_rate_max_age", "must be a duration such as 48h")
	}
	for _, service := range []struct {
		prefix, kind string
		pricing      ServicePricing
	}{
		{"airtime", ServiceKindAirtime, s.Airtime},
		{"bills", ServiceKindBill, s.Bills},
	} {
		mode := strings.ToLower(settingsOr(service.pricing.OrderMode, defaultOrderMode(service.kind)))
		if allowed := orderModes(service.kind); !settingsContains(allowed, mode) {
			add(service.prefix+".order_mode", "must be one of %s", strings.Join(allowed, ", "))
		}
		path, raw := service.prefix+".usd_buffer_percent", settingsOr(service.pricing.USDBufferPercent, DefaultUSDBufferPercent)
		number(path, raw, "0.5", false)
		if value, ok := settingsRat(raw, settingsNumberPattern); ok && value.Cmp(big.NewRat(maxUSDBufferPercent, 1)) > 0 {
			add(path, "must be at most %d: it absorbs a moved rate, it is not a surcharge", maxUSDBufferPercent)
		}
		number(service.prefix+".service_fee_lyd", settingsOr(service.pricing.ServiceFeeLYD, defaultServiceFee(service.kind)), "2", false)
	}
	if strings.TrimSpace(s.RetailStep) != "" {
		dinars("retail_step", s.RetailStep, "0.25", true)
	}
	if strings.TrimSpace(s.MinShopMargin) != "" {
		dinars("min_shop_margin", s.MinShopMargin, "0.10", false)
	}

	if len(s.Popular) > maxPopularCountries {
		add("popular", "at most %d countries", maxPopularCountries)
	}
	for i, raw := range s.Popular {
		path := fmt.Sprintf("popular[%d]", i)
		code := strings.ToUpper(strings.TrimSpace(raw))
		switch {
		case !settingsCountryPattern.MatchString(code):
			add(path, "%q is not a two-letter country code", raw)
		case code == CountryWorldwide || code == CountryEurope:
			add(path, "%q is a region, not a country", code)
		case CountryName(code) == "":
			add(path, "%q is not a country code the relay knows", code)
		}
	}
	return problems
}

// ParseSettings reads a settings document. Unknown fields are refused, so a
// misspelt "retial_step" is an error instead of a knob that silently did
// nothing, and every problem is reported at once. What it returns is
// Normalized: defaults written out, so a caller never sees a half-filled
// document.
func ParseSettings(raw []byte) (Settings, error) {
	if !bytes.HasPrefix(bytes.TrimSpace(raw), []byte("{")) {
		return Settings{}, errors.New("voucher settings must be a JSON object")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var settings Settings
	if err := decoder.Decode(&settings); err != nil {
		var typeErr *json.UnmarshalTypeError
		if errors.As(err, &typeErr) {
			return Settings{}, fmt.Errorf(
				"voucher settings: %s must be %s (numbers are written as strings, like \"9.71\")",
				typeErr.Field, typeErr.Type)
		}
		return Settings{}, fmt.Errorf("voucher settings are not valid JSON: %w", err)
	}
	if decoder.More() {
		return Settings{}, errors.New("voucher settings have trailing content")
	}
	if problems := settings.Validate(); len(problems) > 0 {
		return Settings{}, problems
	}
	return settings.Normalized(), nil
}

// EncodeSettings is the stored form of settings — normalized and compact — and
// its SHA-256 fingerprint: the same settings published twice have the same
// one.
func EncodeSettings(settings Settings) ([]byte, string, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(settings.Normalized()); err != nil {
		return nil, "", err
	}
	raw := bytes.TrimRight(buffer.Bytes(), "\n")
	sum := sha256.Sum256(raw)
	return raw, hex.EncodeToString(sum[:]), nil
}

// DemoDefaults lists the knobs still at their demonstration value, by their
// JSON path. Such a value may have been chosen on purpose, but nothing says it
// was, so everything that shows settings points at these.
func (s Settings) DemoDefaults() []string {
	have, want := s.Normalized(), DefaultSettings()
	out := []string{}
	if settingsSameNumber(have.FundingPercent, want.FundingPercent) {
		out = append(out, "funding_percent")
	}
	if have.Margin.same(want.Margin) {
		out = append(out, "margin")
	}
	if have.Airtime.OrderMode == want.Airtime.OrderMode {
		out = append(out, "airtime.order_mode")
	}
	if settingsSameNumber(have.Airtime.USDBufferPercent, want.Airtime.USDBufferPercent) {
		out = append(out, "airtime.usd_buffer_percent")
	}
	if settingsSameNumber(have.Airtime.ServiceFeeLYD, want.Airtime.ServiceFeeLYD) {
		out = append(out, "airtime.service_fee_lyd")
	}
	if have.Bills.OrderMode == want.Bills.OrderMode {
		out = append(out, "bills.order_mode")
	}
	if settingsSameNumber(have.Bills.USDBufferPercent, want.Bills.USDBufferPercent) {
		out = append(out, "bills.usd_buffer_percent")
	}
	if strings.Join(have.Popular, ",") == strings.Join(want.Popular, ",") {
		out = append(out, "popular")
	}
	return out
}

// Equal reports whether two settings price everything alike: every knob has the
// same value (numbers compare as numbers, so "0.50" is "0.5"), the same rate or
// none, and the same popular countries in the same order. Settings published
// again that are Equal to the current ones change nothing, so they are not a
// new version.
func (s Settings) Equal(other Settings) bool {
	a, b := s.Normalized(), other.Normalized()
	if (a.USDRate == "") != (b.USDRate == "") || (a.USDRate != "" && !settingsSameNumber(a.USDRate, b.USDRate)) {
		return false
	}
	for _, pair := range [][2]string{
		{a.FundingPercent, b.FundingPercent},
		{a.USDRateBufferPercent, b.USDRateBufferPercent},
		{a.Airtime.USDBufferPercent, b.Airtime.USDBufferPercent},
		{a.Bills.USDBufferPercent, b.Bills.USDBufferPercent},
		{a.Airtime.ServiceFeeLYD, b.Airtime.ServiceFeeLYD},
		{a.Bills.ServiceFeeLYD, b.Bills.ServiceFeeLYD},
	} {
		if !settingsSameNumber(pair[0], pair[1]) {
			return false
		}
	}
	if a.Airtime.OrderMode != b.Airtime.OrderMode || a.Bills.OrderMode != b.Bills.OrderMode ||
		a.USDRateSource != b.USDRateSource || a.USDRateSeries != b.USDRateSeries ||
		a.USDRateBankCode != b.USDRateBankCode || a.USDRateMaxAge != b.USDRateMaxAge {
		return false
	}
	if !a.Margin.same(b.Margin) {
		return false
	}
	for _, pair := range [][2]*Margin{{a.CardMargin, b.CardMargin}, {a.Airtime.Margin, b.Airtime.Margin}, {a.Bills.Margin, b.Bills.Margin}} {
		if (pair[0] == nil) != (pair[1] == nil) || (pair[0] != nil && !pair[0].same(*pair[1])) {
			return false
		}
	}
	return strings.Join(a.Popular, ",") == strings.Join(b.Popular, ",")
}

func settingsContains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

func settingsSameNumber(a, b string) bool {
	x, xOK := new(big.Rat).SetString(strings.TrimSpace(a))
	y, yOK := new(big.Rat).SetString(strings.TrimSpace(b))
	if xOK && yOK {
		return x.Cmp(y) == 0
	}
	return strings.TrimSpace(a) == strings.TrimSpace(b)
}

func settingsRat(raw string, pattern *regexp.Regexp) (*big.Rat, bool) {
	raw = strings.TrimSpace(raw)
	if !pattern.MatchString(raw) {
		return nil, false
	}
	return new(big.Rat).SetString(raw)
}

// settingsMarkedUp is cost * (1 + percent/100), exactly.
func settingsMarkedUp(cost, percent *big.Rat) *big.Rat {
	factor := new(big.Rat).Add(settingsOne, new(big.Rat).Quo(percent, settingsHundred))
	return new(big.Rat).Mul(cost, factor)
}

// settingsCeil rounds x (>= 0) up to a multiple of step (> 0). A value already
// on a multiple stays where it is.
func settingsCeil(x, step *big.Rat) *big.Rat {
	quotient := new(big.Rat).Quo(x, step)
	whole := new(big.Int).Div(quotient.Num(), quotient.Denom())
	if !quotient.IsInt() {
		whole.Add(whole, big.NewInt(1))
	}
	return new(big.Rat).Mul(new(big.Rat).SetInt(whole), step)
}

// USDToLYD is what dollars cost the company in dinars: the dollar rate with the
// funding fee on top. It is exact — rounding happens only in the prices — and
// false when there is no rate (or no amount, or the settings do not read):
// nothing is converted by guess.
func (s Settings) USDToLYD(usd *big.Rat) (*big.Rat, bool) {
	if usd == nil || usd.Sign() < 0 {
		return nil, false
	}
	rate, _ := s.EffectiveUSDRate()
	if rate == nil || rate.Sign() <= 0 {
		return nil, false
	}
	funding, ok := settingsRat(settingsOr(s.FundingPercent, DefaultFundingPercent), settingsNumberPattern)
	if !ok {
		return nil, false
	}
	return settingsMarkedUp(new(big.Rat).Mul(usd, rate), funding), true
}

// ServiceFee is the flat fee of a kind of service in dinars; zero when it does
// not read.
func (s Settings) ServiceFee(kind string) *big.Rat {
	fee, ok := settingsRat(s.Pricing(kind).ServiceFeeLYD, settingsNumberPattern)
	if !ok {
		return new(big.Rat)
	}
	return fee
}

// ServicePrices works a service's cost out with its margin and flat fee.
func (s Settings) ServicePrices(kind string, costLYD *big.Rat) (MarginPrices, bool) {
	return s.MarginFor(kind).PricesWithFee(costLYD, s.ServiceFee(kind))
}

// ShopPrice is what a shop pays for a thing of the given kind that costs the
// company costLYD: the cost plus the shop-paid part of the margin, rounded UP to
// a cent of a dinar. nil when the cost is missing or negative, or a knob does
// not read.
func (s Settings) ShopPrice(kind string, costLYD *big.Rat) *big.Rat {
	prices, ok := s.ServicePrices(kind, costLYD)
	if !ok {
		return nil
	}
	return prices.ShopPays
}

// RetailPrice is what the shop's customer is asked to pay: the cost plus the
// whole margin, rounded UP to the round step, never below the shop price plus
// the minimum shop margin. nil when the cost is missing or negative, or a knob
// does not read.
func (s Settings) RetailPrice(kind string, costLYD *big.Rat) *big.Rat {
	prices, ok := s.ServicePrices(kind, costLYD)
	if !ok {
		return nil
	}
	return prices.Retail
}

// FormatDinars writes an amount of dinars the way every price crosses the wire:
// two decimals, trailing zeros kept ("91.30"). Prices from ShopPrice and
// RetailPrice are already on two decimals; any other value is rounded to the
// nearest hundredth. "" for nil.
func FormatDinars(value *big.Rat) string {
	if value == nil {
		return ""
	}
	return value.FloatString(2)
}
