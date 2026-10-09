package services

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"sort"
	"strings"
	"time"
	"unicode"

	"pointy/relay/internal/vouchers"
)

// PricingInput is everything a directory depends on besides the supplier's own
// data: the operator's pricing settings and the flags the catalog carries. The
// two keys fingerprint them, so a rendered directory is reused until one moves.
type PricingInput struct {
	Settings    vouchers.Settings
	SettingsKey string
	// Flags maps a country code to its catalog image reference.
	Flags    map[string]string
	FlagsKey string
	// Logos maps a supplier's operator logo URL to the relay's own copy of it
	// (an image reference, "sha256:<hex>"). A shop is never handed a supplier
	// URL: an operator whose logo is not copied yet carries no logo.
	Logos    map[string]string
	LogosKey string
}

// Rendered is a directory ready to serve: the structure, the priced body as
// JSON, and its version (the ETag).
type Rendered struct {
	Version string
	Body    []byte
	View    *Directory
}

// viewContext carries what a render needs down to the amounts.
type viewContext struct {
	settings vouchers.Settings
	priced   bool
	flags    map[string]string
	logos    map[string]string
	rank     map[string]int
	// rawLogos keeps the supplier's URL: only the snapshot's own fingerprint
	// is made that way, never anything a shop reads.
	rawLogos bool
}

// logoFor is the logo a shop is shown for a supplier's logo URL.
func (vc *viewContext) logoFor(url string) string {
	if vc.rawLogos {
		return url
	}
	return vc.logos[url]
}

// render makes the directory a shop reads from a snapshot: priced by the
// settings, flagged from the catalog, ordered popular countries first.
func (s *snapshot) render(in PricingInput, test, configured bool) *Rendered {
	vc := &viewContext{
		settings: in.Settings,
		priced:   in.Settings.Priced(),
		flags:    in.Flags,
		logos:    in.Logos,
		rank:     map[string]int{},
	}
	popular := []string{}
	for _, code := range in.Settings.Popular {
		code = strings.ToUpper(strings.TrimSpace(code))
		if _, served := s.countries[code]; served && vc.rank[code] == 0 {
			popular = append(popular, code)
			vc.rank[code] = len(popular)
		}
	}
	directory := &Directory{
		GeneratedAt: s.at,
		Currency:    vouchers.Currency,
		TestMode:    test,
		Configured:  configured,
		Priced:      vc.priced,
		Pricing:     pricingPolicy(in.Settings),
		Popular:     popular,
		Countries:   s.views(vc),
		Unsupported: append([]Unsupported{}, s.unsupported...),
	}
	// The version is the hash of what a shop reads, less the version itself and
	// the moment the supplier was read.
	directory.GeneratedAt = time.Time{}
	body, err := json.Marshal(directory)
	if err != nil {
		return &Rendered{View: directory}
	}
	sum := sha256.Sum256(body)
	directory.Version = hex.EncodeToString(sum[:8])
	directory.GeneratedAt = s.at
	body, err = json.Marshal(directory)
	if err != nil {
		return &Rendered{Version: directory.Version, View: directory}
	}
	return &Rendered{Version: directory.Version, Body: body, View: directory}
}

// structure is the directory with no prices, flags or popularity: what the
// snapshot's own fingerprint is made of.
func (s *snapshot) structure() []Country {
	return s.views(&viewContext{rank: map[string]int{}, rawLogos: true})
}

// viewContextFor is the context of a single operator's view: priced by the
// settings, with no flags or popularity.
func viewContextFor(in PricingInput) *viewContext {
	return &viewContext{settings: in.Settings, priced: in.Settings.Priced(), flags: in.Flags, logos: in.Logos, rank: map[string]int{}}
}

// views makes every country that has something to sell, in display order.
func (s *snapshot) views(vc *viewContext) []Country {
	out := make([]Country, 0, len(s.countries))
	for _, entry := range s.countries {
		if view, ok := entry.view(vc); ok {
			out = append(out, view)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if (a.Popular > 0) != (b.Popular > 0) {
			return a.Popular > 0
		}
		if a.Popular != b.Popular {
			return a.Popular < b.Popular
		}
		if ka, kb := arabicSortKey(a.Name), arabicSortKey(b.Name); ka != kb {
			return ka < kb
		}
		return a.Code < b.Code
	})
	return out
}

func (c *countryEntry) view(vc *viewContext) (Country, bool) {
	view := Country{
		Code:         c.code,
		Name:         c.nameAR,
		NameEN:       c.nameEN,
		Dial:         append([]string{}, c.dial...),
		Currency:     c.currency,
		CurrencyName: CurrencyName(c.currency),
		Flag:         vc.flags[c.code],
		Popular:      vc.rank[c.code],
	}
	operators := make([]Operator, 0, len(c.operators))
	for _, operator := range c.operators {
		if v, ok := operator.view(vc); ok {
			operators = append(operators, v)
		}
	}
	billers := make([]Biller, 0, len(c.billers))
	for _, biller := range c.billers {
		if v, ok := biller.view(vc); ok {
			billers = append(billers, v)
		}
	}
	if len(operators) > 0 {
		view.Airtime = &AirtimeBlock{Operators: operators}
	}
	if len(billers) > 0 {
		view.Bills = &BillsBlock{Billers: billers}
	}
	return view, view.Airtime != nil || view.Bills != nil
}

func (e *operatorEntry) view(vc *viewContext) (Operator, bool) {
	view := Operator{
		ID:              e.id,
		Name:            e.nameAR,
		NameEN:          e.nameEN,
		Logo:            vc.logoFor(e.logo),
		Mode:            ModeRange,
		AmountCurrency:  e.currency,
		ReceiveCurrency: e.receiveCurrency,
		Approximate:     e.approximate,
		Amounts:         make([]Amount, 0, len(e.tiles)),
	}
	if e.fixed {
		view.Mode = ModeFixed
	} else {
		view.Min, view.Max = FormatAmount(e.min), FormatAmount(e.max)
	}
	for _, t := range e.tiles {
		amount := Amount{
			Amount:          FormatAmount(t.amount),
			Receive:         FormatAmount(t.receive),
			ReceiveCurrency: e.receiveCurrency,
		}
		if vc.priced {
			prices, ok := e.priceOf(vc, t)
			if !ok {
				continue
			}
			amount.UnitPrice, amount.RetailPrice = prices.UnitString(), prices.RetailString()
		}
		view.Amounts = append(view.Amounts, amount)
	}
	if len(view.Amounts) == 0 {
		return Operator{}, false
	}
	if e.popular != nil {
		popular := FormatAmount(e.popular)
		view.PopularAmount = &popular
	}
	return view, true
}

func (e *operatorEntry) priceOf(vc *viewContext, t tile) (Prices, bool) {
	plan, ok := e.plan(vc.settings, t.amount)
	if !ok {
		return Prices{}, false
	}
	prices, err := PriceCost(vc.settings, KindAirtime, plan.Cost)
	return prices, err == nil
}

func (b *billerEntry) priceOf(vc *viewContext, amount *big.Rat) (Prices, bool) {
	plan, ok := b.plan(vc.settings, amount)
	if !ok {
		return Prices{}, false
	}
	prices, err := PriceCost(vc.settings, KindBill, plan.Cost)
	return prices, err == nil
}

func (b *billerEntry) view(vc *viewContext) (Biller, bool) {
	view := Biller{
		ID:              b.id,
		Name:            b.nameAR,
		NameEN:          b.nameEN,
		Type:            b.typ,
		Service:         b.service,
		Mode:            ModeRange,
		RequiresInvoice: b.requiresInvoice,
		AmountCurrency:  b.currency,
		Approximate:     b.approximate,
	}
	if b.fixed {
		view.Mode = ModeFixed
		for _, plan := range b.plans {
			entry := Plan{
				ID:            plan.id,
				Amount:        FormatAmount(plan.amount),
				Description:   plan.descAR,
				DescriptionEN: plan.desc,
			}
			if vc.priced {
				prices, ok := b.priceOf(vc, plan.amount)
				if !ok {
					continue
				}
				entry.UnitPrice, entry.RetailPrice = prices.UnitString(), prices.RetailString()
			}
			view.Plans = append(view.Plans, entry)
		}
		return view, len(view.Plans) > 0
	}
	view.Min, view.Max = FormatAmount(b.min), FormatAmount(b.max)
	for _, amount := range b.tiles {
		entry := Suggestion{Amount: FormatAmount(amount)}
		if vc.priced {
			prices, ok := b.priceOf(vc, amount)
			if !ok {
				continue
			}
			entry.UnitPrice, entry.RetailPrice = prices.UnitString(), prices.RetailString()
		}
		view.Suggested = append(view.Suggested, entry)
	}
	return view, len(view.Suggested) > 0
}

// arabicSortKey folds a name for ordering: no vowel marks, the hamza forms of
// alef as one letter, ta marbuta as ha, alef maqsura as ya, no leading definite
// article.
func arabicSortKey(name string) string {
	var out strings.Builder
	for _, r := range strings.TrimSpace(name) {
		switch {
		case r >= 0x064b && r <= 0x065f, r == 0x0670, r == 0x0640:
			continue
		case r == 0x0623, r == 0x0625, r == 0x0622, r == 0x0671:
			out.WriteRune(0x0627)
		case r == 0x0629:
			out.WriteRune(0x0647)
		case r == 0x0649:
			out.WriteRune(0x064a)
		default:
			out.WriteRune(unicode.ToLower(r))
		}
	}
	key := out.String()
	if strings.HasPrefix(key, "ال") && len([]rune(key)) > 3 {
		key = string([]rune(key)[2:])
	}
	return key
}

// pricingPolicy is the global margin policy as the directory publishes it.
func pricingPolicy(settings vouchers.Settings) *PricingPolicy {
	margin := settings.Normalized().Margin
	return &PricingPolicy{
		FixedLYD:         margin.FixedLYD,
		Brackets:         margin.Brackets,
		ShopSharePercent: margin.ShopSharePercent,
		RoundStep:        margin.RoundStep,
	}
}
