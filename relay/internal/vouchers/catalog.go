// Package vouchers is the company's own card shop: the catalog the operator
// writes (our categories, our order, our prices and promotions, two logos per
// brand), what each shop is shown of it, and the suppliers the cards are
// bought from (BN Plus and Reloadly; DingConnect later).
//
// A wholesaler's own grouping and naming is never shown to a shop. The operator
// maps each item to a supplier's card in the item's "supplier" block — or to
// the same card at several suppliers in its "suppliers" list, bought from the
// cheapest in dinars at the moment of purchase — and the relay buys that card
// with the company's account the moment a shop's invoice is paid, charging the
// shop's voucher balance.
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
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// ImagePrefix marks an uploaded image: "sha256:<64 hex>". Content addressing
// is what lets every cache downstream keep an image forever: a new logo is a
// new reference.
const ImagePrefix = "sha256:"

// Currency is what every price in the catalog is written in: what the shop
// pays and what its customer pays. A supplier's own currency (BN Plus sells
// international cards in dollars) stays behind the relay.
const Currency = "LYD"

// PromotionGrace is how long after a promotion ends its price is still
// honoured for a shop that read the catalog while it ran: the shop sold at the
// promotion's cost, and its catalog is up to a few minutes old.
const PromotionGrace = 30 * time.Minute

const (
	maxCategories        = 50
	maxBrands            = 500
	maxItemsPerBrand     = 100
	maxCountries         = 250
	maxAliases           = 10
	maxNameRunes         = 60
	maxCategoryNameRunes = 40
	maxLabelRunes        = 40
	maxBadgeRunes        = 24
	maxAliasRunes        = 40
	maxHintRunes         = 300
)

var (
	keyPattern      = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,47}$`)
	currencyPattern = regexp.MustCompile(`^[A-Z]{3}$`)
	imageRefPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
	// Prices carry at most two decimals: the shop's books (a card's cost, its
	// sale price, the float) keep two.
	pricePattern = regexp.MustCompile(`^\d{1,9}(\.\d{1,2})?$`)
	facePattern  = regexp.MustCompile(`^\d{1,9}(\.\d{1,3})?$`)
)

// Document is the catalog as the operator writes it. On the relay every image
// is an uploaded reference ("sha256:…"); in the file the CLI pushes, an image
// may still be a path next to the file, which the CLI uploads first.
type Document struct {
	// PriceMode is the default of every item's price_mode: "static" (the
	// written prices) or "auto" (the relay prices from the cheapest supplier).
	PriceMode  string     `json:"price_mode,omitempty"`
	Categories []Category `json:"categories"`
	Countries  []Country  `json:"countries,omitempty"`
	Brands     []Brand    `json:"brands"`
}

// Category is one of our own groupings, shown as a tab on the till.
type Category struct {
	Key    string `json:"key"`
	Name   string `json:"name"`
	Sort   int    `json:"sort,omitempty"`
	Active *bool  `json:"active,omitempty"`
}

// Country names a store region items are sold for, and its flag. The Arabic
// name comes from the relay's table unless the operator overrides it.
type Country struct {
	Code string `json:"code"`
	Name string `json:"name,omitempty"`
	Flag string `json:"flag,omitempty"`
}

// Brand is what the till shows as one card: iTunes, PlayStation, Libyana.
type Brand struct {
	Key     string   `json:"key"`
	Name    string   `json:"name"`
	Aliases []string `json:"aliases,omitempty"`
	// Category is a Category key.
	Category string `json:"category"`
	// Sort orders brands (smaller first) after Featured ones.
	Sort     int  `json:"sort,omitempty"`
	Featured bool `json:"featured,omitempty"`
	// Badge is a short line on the brand's card ("الأكثر مبيعاً").
	Badge string `json:"badge,omitempty"`
	// RedeemHint prints under the code on the receipt.
	RedeemHint string `json:"redeem_hint,omitempty"`
	Logo       Logo   `json:"logo"`
	Active     *bool  `json:"active,omitempty"`
	Items      []Item `json:"items"`
}

// Logo is the brand's two images: card art for the till, and a monochrome
// mark for thermal receipts.
type Logo struct {
	Display string `json:"display,omitempty"`
	Print   string `json:"print,omitempty"`
}

// Item is one sellable card: a brand, a store region, a denomination.
type Item struct {
	Key string `json:"key"`
	// Country is an ISO 3166-1 alpha-2 code, WW (worldwide) or EU; empty for
	// a card with no region, such as a local top-up card.
	Country      string `json:"country,omitempty"`
	FaceValue    string `json:"face_value,omitempty"`
	FaceCurrency string `json:"face_currency,omitempty"`
	// Label is the denomination as the till shows it; it defaults to the face
	// value in Arabic ("10 دولار").
	Label string `json:"label,omitempty"`
	// Price is what the shop pays for one card; RetailPrice what its customer
	// pays. Both in dinars, at most two decimals.
	Price       string `json:"price"`
	RetailPrice string `json:"retail_price"`
	// PriceMode "auto" has the relay price the card from its cheapest supplier's
	// cost with the card margin policy; Price and RetailPrice are then the
	// fallback used while no supplier cost is known. "static" (or empty, unless
	// the catalog says otherwise) sells at the written prices.
	PriceMode string `json:"price_mode,omitempty"`
	Sort      int    `json:"sort,omitempty"`
	Active    *bool  `json:"active,omitempty"`
	Promo     *Promo `json:"promo,omitempty"`
	// Market is the cheapest known competitor price (market.go); cards priced
	// "auto" are sold just under it.
	Market *Market `json:"market,omitempty"`
	// Supplier is the one supplier the card is bought from. Suppliers is the
	// same card at several (at most four, one entry each): the relay buys from
	// the cheapest in dinars at the moment of purchase and falls back to the
	// next when one definitely sells nothing. Exactly one of the two is given.
	Supplier  json.RawMessage   `json:"supplier,omitempty"`
	Suppliers []json.RawMessage `json:"suppliers,omitempty"`
}

// Promo is a time-boxed price: a lower Price is a better margin for the shop
// ("sell this one"), a lower RetailPrice a deal for its customer. Either may
// be left out.
type Promo struct {
	Price       string    `json:"price,omitempty"`
	RetailPrice string    `json:"retail_price,omitempty"`
	Badge       string    `json:"badge"`
	StartsAt    time.Time `json:"starts_at"`
	EndsAt      time.Time `json:"ends_at"`
}

// Problem is one thing wrong with a document, located by a JSON-ish path.
type Problem struct {
	Path    string `json:"path"`
	Message string `json:"message"`
}

// Problems is every problem a document has; a valid document has none.
type Problems []Problem

func (p Problems) Error() string {
	if len(p) == 0 {
		return "no problems"
	}
	parts := make([]string, 0, min(len(p), 5))
	for i, problem := range p {
		if i == 5 {
			parts = append(parts, fmt.Sprintf("and %d more", len(p)-5))
			break
		}
		parts = append(parts, problem.Path+": "+problem.Message)
	}
	return "invalid voucher catalog: " + strings.Join(parts, "; ")
}

// ParseDocument reads a catalog. Unknown fields are refused, so a misspelt
// "retial_price" is an error instead of a card sold at nothing.
func ParseDocument(raw []byte) (Document, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var document Document
	if err := decoder.Decode(&document); err != nil {
		return Document{}, fmt.Errorf("voucher catalog is not valid JSON: %w", err)
	}
	if decoder.More() {
		return Document{}, errors.New("voucher catalog has trailing content")
	}
	return document, nil
}

// ValidateOptions says what a validation may assume about images.
type ValidateOptions struct {
	// PathsAllowed accepts an image that is not yet an uploaded reference (a
	// file path, in the CLI's local check). The relay never allows it.
	PathsAllowed bool
	// KnownImage reports whether an uploaded image exists; nil skips the check.
	KnownImage func(ref string) bool
}

// Validate returns every problem with a document; none means it can be
// published.
func Validate(document Document, options ValidateOptions) Problems {
	var problems Problems
	add := func(path, format string, args ...any) {
		problems = append(problems, Problem{Path: path, Message: fmt.Sprintf(format, args...)})
	}
	if mode := strings.ToLower(strings.TrimSpace(document.PriceMode)); mode != "" && mode != PriceModeStatic && mode != PriceModeAuto {
		add("price_mode", "must be static or auto")
	}
	checkImage := func(path, ref string) {
		ref = strings.TrimSpace(ref)
		if ref == "" {
			return
		}
		if strings.HasPrefix(ref, ImagePrefix) {
			if !imageRefPattern.MatchString(ref) {
				add(path, "must be sha256: and 64 lower-case hex digits")
				return
			}
			if options.KnownImage != nil && !options.KnownImage(ref) {
				add(path, "image %s has not been uploaded", ref)
			}
			return
		}
		if !options.PathsAllowed {
			add(path, "must be an uploaded image (sha256:…); push the catalog with the CLI, which uploads it")
		}
	}

	if len(document.Categories) == 0 {
		add("categories", "at least one category is required")
	}
	if len(document.Categories) > maxCategories {
		add("categories", "at most %d categories", maxCategories)
	}
	categories := map[string]bool{}
	for i, category := range document.Categories {
		path := fmt.Sprintf("categories[%d]", i)
		key := strings.TrimSpace(category.Key)
		if !keyPattern.MatchString(key) {
			add(path+".key", "must be 1-48 lower-case letters, digits, _ or -, starting with a letter or digit")
		} else if categories[key] {
			add(path+".key", "%q is used twice", key)
		}
		categories[key] = true
		checkText(add, path+".name", category.Name, maxCategoryNameRunes, true)
	}

	countries := map[string]bool{}
	if len(document.Countries) > maxCountries {
		add("countries", "at most %d countries", maxCountries)
	}
	for i, country := range document.Countries {
		path := fmt.Sprintf("countries[%d]", i)
		code := strings.ToUpper(strings.TrimSpace(country.Code))
		if CountryName(code) == "" {
			add(path+".code", "%q is not a country code the catalog accepts", country.Code)
		} else if countries[code] {
			add(path+".code", "%q is listed twice", code)
		}
		countries[code] = true
		checkText(add, path+".name", country.Name, maxNameRunes, false)
		checkImage(path+".flag", country.Flag)
	}

	if len(document.Brands) == 0 {
		add("brands", "at least one brand is required")
	}
	if len(document.Brands) > maxBrands {
		add("brands", "at most %d brands", maxBrands)
	}
	brands := map[string]bool{}
	items := map[string]string{}
	for i, brand := range document.Brands {
		path := fmt.Sprintf("brands[%d]", i)
		key := strings.TrimSpace(brand.Key)
		if !keyPattern.MatchString(key) {
			add(path+".key", "must be 1-48 lower-case letters, digits, _ or -, starting with a letter or digit")
		} else if brands[key] {
			add(path+".key", "%q is used twice", key)
		}
		brands[key] = true
		checkText(add, path+".name", brand.Name, maxNameRunes, true)
		if !categories[strings.TrimSpace(brand.Category)] {
			add(path+".category", "%q is not one of the categories", brand.Category)
		}
		if len(brand.Aliases) > maxAliases {
			add(path+".aliases", "at most %d aliases", maxAliases)
		}
		for j, alias := range brand.Aliases {
			checkText(add, fmt.Sprintf("%s.aliases[%d]", path, j), alias, maxAliasRunes, true)
		}
		checkText(add, path+".badge", brand.Badge, maxBadgeRunes, false)
		checkText(add, path+".redeem_hint", brand.RedeemHint, maxHintRunes, false)
		checkImage(path+".logo.display", brand.Logo.Display)
		checkImage(path+".logo.print", brand.Logo.Print)
		if len(brand.Items) == 0 {
			add(path+".items", "a brand needs at least one item")
		}
		if len(brand.Items) > maxItemsPerBrand {
			add(path+".items", "at most %d items per brand", maxItemsPerBrand)
		}
		for j, item := range brand.Items {
			validateItem(add, fmt.Sprintf("%s.items[%d]", path, j), item, items, countries)
		}
	}
	return problems
}

func validateItem(
	add func(path, format string, args ...any),
	path string,
	item Item,
	seen map[string]string,
	countries map[string]bool,
) {
	key := strings.TrimSpace(item.Key)
	if !keyPattern.MatchString(key) {
		add(path+".key", "must be 1-48 lower-case letters, digits, _ or -, starting with a letter or digit")
	} else if first, ok := seen[key]; ok {
		add(path+".key", "%q is already used by %s", key, first)
	} else {
		seen[key] = path
	}
	if country := strings.ToUpper(strings.TrimSpace(item.Country)); country != "" {
		if CountryName(country) == "" {
			add(path+".country", "%q is not a country code the catalog accepts", item.Country)
		} else if len(countries) > 0 && !countries[country] {
			add(path+".country", "%q is not in the countries list", country)
		}
	}
	face := strings.TrimSpace(item.FaceValue)
	currency := strings.ToUpper(strings.TrimSpace(item.FaceCurrency))
	if face != "" && !facePattern.MatchString(face) {
		add(path+".face_value", "must be a number with at most three decimals")
	}
	if currency != "" && !currencyPattern.MatchString(currency) {
		add(path+".face_currency", "must be a three-letter currency code")
	}
	if (face == "") != (currency == "") {
		add(path+".face_value", "face_value and face_currency go together")
	}
	if strings.TrimSpace(item.Label) == "" && face == "" {
		add(path+".label", "an item needs a label or a face value")
	}
	checkText(add, path+".label", item.Label, maxLabelRunes, false)

	if mode := strings.ToLower(strings.TrimSpace(item.PriceMode)); mode != "" && mode != PriceModeStatic && mode != PriceModeAuto {
		add(path+".price_mode", "must be static or auto")
	}
	price, priceOK := parsePrice(add, path+".price", item.Price, true)
	retail, retailOK := parsePrice(add, path+".retail_price", item.RetailPrice, true)
	if priceOK && retailOK && retail.Cmp(price) < 0 {
		add(path+".retail_price", "is below price: the shop would sell at a loss")
	}
	if promo := item.Promo; promo != nil {
		promoPath := path + ".promo"
		checkText(add, promoPath+".badge", promo.Badge, maxBadgeRunes, true)
		if promo.StartsAt.IsZero() || promo.EndsAt.IsZero() {
			add(promoPath, "starts_at and ends_at are required")
		} else if !promo.EndsAt.After(promo.StartsAt) {
			add(promoPath+".ends_at", "must be after starts_at")
		}
		promoPrice, promoPriceOK := parsePrice(add, promoPath+".price", promo.Price, false)
		promoRetail, promoRetailOK := parsePrice(add, promoPath+".retail_price", promo.RetailPrice, false)
		if promoPrice == nil && promoRetail == nil {
			add(promoPath, "a promotion changes price, retail_price or both")
		}
		if promoPriceOK && promoPrice != nil && priceOK && promoPrice.Cmp(price) >= 0 {
			add(promoPath+".price", "must be below the regular price")
		}
		if promoRetailOK && promoRetail != nil && retailOK && promoRetail.Cmp(retail) >= 0 {
			add(promoPath+".retail_price", "must be below the regular retail price")
		}
		// During the promotion the shop must still sell above its cost.
		cost, sell := price, retail
		if promoPrice != nil {
			cost = promoPrice
		}
		if promoRetail != nil {
			sell = promoRetail
		}
		if cost != nil && sell != nil && sell.Cmp(cost) < 0 {
			add(promoPath, "the promotion sells below the shop's cost")
		}
	}
	if _, problems := itemRefs(item); len(problems) > 0 {
		for _, problem := range problems {
			add(path+"."+problem.Field, "%s", problem.Message)
		}
	}
}

func checkText(add func(path, format string, args ...any), path, value string, limit int, required bool) {
	value = strings.TrimSpace(value)
	if value == "" {
		if required {
			add(path, "is required")
		}
		return
	}
	if utf8.RuneCountInString(value) > limit {
		add(path, "must be at most %d characters", limit)
	}
}

func parsePrice(add func(path, format string, args ...any), path, raw string, required bool) (*big.Rat, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		if required {
			add(path, "is required")
			return nil, false
		}
		return nil, true
	}
	if !pricePattern.MatchString(raw) {
		add(path, "must be dinars with at most two decimals")
		return nil, false
	}
	value, _ := new(big.Rat).SetString(raw)
	if value.Sign() <= 0 {
		add(path, "must be above zero")
		return nil, false
	}
	return value, true
}

// Normalize returns the document as it is stored: text trimmed, codes in
// upper case, defaults filled in (labels, active flags). It assumes the
// document validated.
func Normalize(document Document) Document {
	out := Document{
		PriceMode:  strings.ToLower(strings.TrimSpace(document.PriceMode)),
		Categories: make([]Category, 0, len(document.Categories)),
		Countries:  make([]Country, 0, len(document.Countries)),
		Brands:     make([]Brand, 0, len(document.Brands)),
	}
	for _, category := range document.Categories {
		out.Categories = append(out.Categories, Category{
			Key:    strings.TrimSpace(category.Key),
			Name:   strings.TrimSpace(category.Name),
			Sort:   category.Sort,
			Active: boolPointer(isActive(category.Active)),
		})
	}
	for _, country := range document.Countries {
		out.Countries = append(out.Countries, Country{
			Code: strings.ToUpper(strings.TrimSpace(country.Code)),
			Name: strings.TrimSpace(country.Name),
			Flag: strings.TrimSpace(country.Flag),
		})
	}
	for _, brand := range document.Brands {
		normalized := Brand{
			Key:        strings.TrimSpace(brand.Key),
			Name:       strings.TrimSpace(brand.Name),
			Category:   strings.TrimSpace(brand.Category),
			Sort:       brand.Sort,
			Featured:   brand.Featured,
			Badge:      strings.TrimSpace(brand.Badge),
			RedeemHint: strings.TrimSpace(brand.RedeemHint),
			Logo: Logo{
				Display: strings.TrimSpace(brand.Logo.Display),
				Print:   strings.TrimSpace(brand.Logo.Print),
			},
			Active: boolPointer(isActive(brand.Active)),
			Items:  make([]Item, 0, len(brand.Items)),
		}
		for _, alias := range brand.Aliases {
			if alias = strings.TrimSpace(alias); alias != "" {
				normalized.Aliases = append(normalized.Aliases, alias)
			}
		}
		for _, item := range brand.Items {
			normalized.Items = append(normalized.Items, normalizeItem(item))
		}
		out.Brands = append(out.Brands, normalized)
	}
	return out
}

func normalizeItem(item Item) Item {
	normalized := Item{
		Key:          strings.TrimSpace(item.Key),
		Country:      strings.ToUpper(strings.TrimSpace(item.Country)),
		FaceValue:    strings.TrimSpace(item.FaceValue),
		FaceCurrency: strings.ToUpper(strings.TrimSpace(item.FaceCurrency)),
		Label:        strings.TrimSpace(item.Label),
		Price:        canonicalPrice(item.Price),
		RetailPrice:  canonicalPrice(item.RetailPrice),
		PriceMode:    strings.ToLower(strings.TrimSpace(item.PriceMode)),
		Sort:         item.Sort,
		Active:       boolPointer(isActive(item.Active)),
	}
	if !absentJSON(item.Supplier) {
		normalized.Supplier = compactJSON(item.Supplier)
	}
	for _, raw := range item.Suppliers {
		normalized.Suppliers = append(normalized.Suppliers, compactJSON(raw))
	}
	if normalized.Label == "" {
		normalized.Label = FaceLabel(normalized.FaceValue, normalized.FaceCurrency)
	}
	if promo := item.Promo; promo != nil {
		normalized.Promo = &Promo{
			Price:       canonicalPrice(promo.Price),
			RetailPrice: canonicalPrice(promo.RetailPrice),
			Badge:       strings.TrimSpace(promo.Badge),
			StartsAt:    promo.StartsAt.UTC(),
			EndsAt:      promo.EndsAt.UTC(),
		}
	}
	return normalized
}

// FaceLabel writes a denomination the way the till reads it: "10 دولار",
// "25 يورو", "5 دينار". Trailing zeros are dropped ("10.00" → "10").
func FaceLabel(value, currency string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if strings.Contains(value, ".") {
		value = strings.TrimRight(strings.TrimRight(value, "0"), ".")
	}
	if currency = strings.TrimSpace(currency); currency == "" {
		return value
	}
	return value + " " + CurrencyName(currency)
}

func canonicalPrice(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	value, ok := new(big.Rat).SetString(raw)
	if !ok {
		return raw
	}
	return value.FloatString(2)
}

func compactJSON(raw json.RawMessage) json.RawMessage {
	var buffer bytes.Buffer
	if err := json.Compact(&buffer, raw); err != nil {
		return raw
	}
	return buffer.Bytes()
}

func isActive(flag *bool) bool { return flag == nil || *flag }

func boolPointer(value bool) *bool { return &value }

// Encode is the stored form of a normalized document, and SHA256 its
// fingerprint: the same catalog pushed twice has the same one.
func Encode(document Document) ([]byte, string, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(document); err != nil {
		return nil, "", err
	}
	raw := bytes.TrimRight(buffer.Bytes(), "\n")
	sum := sha256.Sum256(raw)
	return raw, hex.EncodeToString(sum[:]), nil
}

// Images lists every image the document references, once each.
func Images(document Document) []string {
	seen := map[string]bool{}
	var refs []string
	addRef := func(ref string) {
		ref = strings.TrimSpace(ref)
		if ref != "" && !seen[ref] {
			seen[ref] = true
			refs = append(refs, ref)
		}
	}
	for _, country := range document.Countries {
		addRef(country.Flag)
	}
	for _, brand := range document.Brands {
		addRef(brand.Logo.Display)
		addRef(brand.Logo.Print)
	}
	return refs
}

// Located is an item found in a document, with what surrounds it.
type Located struct {
	Brand    Brand
	Category Category
	Item     Item
	// Ref is the item's first supplier, kept for callers that know only one.
	Ref Ref
	// Refs is every supplier the item lists, in listing order (Refs[0] is Ref).
	Refs []Ref
	// CountryName is the item's region in Arabic, "" for none.
	CountryName string
}

// Listed reports whether the item is on sale at all: it, its brand and its
// category are all active.
func (l Located) Listed() bool {
	return isActive(l.Item.Active) && isActive(l.Brand.Active) && isActive(l.Category.Active)
}

// Name is the item as a statement and a receipt name it: brand, region,
// denomination ("آيتونز · الولايات المتحدة · 10 دولار").
func (l Located) Name() string {
	parts := []string{l.Brand.Name}
	country := l.CountryName
	if country == "" {
		country = countryLabel(l.Item.Country, nil)
	}
	if country != "" {
		parts = append(parts, country)
	}
	if l.Item.Label != "" {
		parts = append(parts, l.Item.Label)
	}
	return strings.Join(parts, " · ")
}

// Find locates an item by key in a normalized document.
func Find(document Document, key string) (Located, bool) {
	key = strings.TrimSpace(key)
	categories := map[string]Category{}
	for _, category := range document.Categories {
		categories[category.Key] = category
	}
	for _, brand := range document.Brands {
		for _, item := range brand.Items {
			if item.Key != key {
				continue
			}
			refs, err := ParseRefs(item)
			if err != nil {
				return Located{}, false
			}
			located := Located{Brand: brand, Category: categories[brand.Category], Item: item, Ref: refs[0], Refs: refs}
			if item.Country != "" {
				for _, country := range document.Countries {
					if country.Code == item.Country {
						located.CountryName = countryLabel(country.Code, &country)
						break
					}
				}
				if located.CountryName == "" {
					located.CountryName = CountryName(item.Country)
				}
			}
			return located, true
		}
	}
	return Located{}, false
}

// Pricing is what an item costs at one moment.
type Pricing struct {
	UnitPrice          string
	RetailPrice        string
	RegularUnitPrice   string
	RegularRetailPrice string
	// Promo is the promotion running now, if any.
	Promo *Promo
}

// PriceAt is the item's price at now: a running promotion's, else its own.
func PriceAt(item Item, now time.Time) Pricing {
	pricing := Pricing{
		UnitPrice:          item.Price,
		RetailPrice:        item.RetailPrice,
		RegularUnitPrice:   item.Price,
		RegularRetailPrice: item.RetailPrice,
	}
	if promo := item.Promo; promo != nil && !now.Before(promo.StartsAt) && now.Before(promo.EndsAt) {
		pricing.Promo = promo
		if promo.Price != "" {
			pricing.UnitPrice = promo.Price
		}
		if promo.RetailPrice != "" {
			pricing.RetailPrice = promo.RetailPrice
		}
	}
	return pricing
}

// ChargePrice is what one card costs a purchase made at now by a shop that
// will pay no more than maxUnitPrice (nil: whatever it costs now). The current
// price, when that is within the limit. Above it, a promotion that ended
// within PromotionGrace is honoured at the price the shop saw, as long as that
// is within the limit. Otherwise ok is false: the price went up.
func ChargePrice(item Item, now time.Time, maxUnitPrice *big.Rat) (*big.Rat, bool) {
	current, _ := new(big.Rat).SetString(PriceAt(item, now).UnitPrice)
	if current == nil {
		return nil, false
	}
	if maxUnitPrice == nil || current.Cmp(maxUnitPrice) <= 0 {
		return current, true
	}
	promo := item.Promo
	if promo == nil || promo.Price == "" || now.Before(promo.EndsAt) || now.Sub(promo.EndsAt) > PromotionGrace {
		return nil, false
	}
	honoured, _ := new(big.Rat).SetString(promo.Price)
	if honoured == nil || honoured.Cmp(maxUnitPrice) > 0 {
		return nil, false
	}
	return honoured, true
}

// --- what a shop is shown ---

// ShopView is the catalog as one shop's backend reads it.
type ShopView struct {
	Version     string         `json:"version"`
	Currency    string         `json:"currency"`
	TestMode    bool           `json:"test_mode"`
	GeneratedAt time.Time      `json:"generated_at"`
	Categories  []ShopCategory `json:"categories"`
	Countries   []ShopCountry  `json:"countries"`
	Brands      []ShopBrand    `json:"brands"`
}

type ShopCategory struct {
	Key  string `json:"key"`
	Name string `json:"name"`
	Rank int    `json:"rank"`
}

type ShopCountry struct {
	Code string `json:"code"`
	Name string `json:"name"`
	Flag string `json:"flag"`
}

type ShopBrand struct {
	Key        string     `json:"key"`
	Name       string     `json:"name"`
	Aliases    []string   `json:"aliases"`
	Category   string     `json:"category"`
	Rank       int        `json:"rank"`
	Featured   bool       `json:"featured"`
	Badge      string     `json:"badge"`
	RedeemHint string     `json:"redeem_hint"`
	Logo       string     `json:"logo"`
	PrintLogo  string     `json:"print_logo"`
	Items      []ShopItem `json:"items"`
}

type ShopItem struct {
	Key                string     `json:"key"`
	Country            string     `json:"country"`
	Label              string     `json:"label"`
	FaceValue          string     `json:"face_value"`
	FaceCurrency       string     `json:"face_currency"`
	UnitPrice          string     `json:"unit_price"`
	RetailPrice        string     `json:"retail_price"`
	RegularUnitPrice   string     `json:"regular_unit_price"`
	RegularRetailPrice string     `json:"regular_retail_price"`
	Promo              *ShopPromo `json:"promo"`
	Available          bool       `json:"available"`
	Rank               int        `json:"rank"`
}

type ShopPromo struct {
	Badge  string    `json:"badge"`
	EndsAt time.Time `json:"ends_at"`
}

// Availability reports whether a listed item can be bought right now, from
// what the relay knows about its supplier.
type Availability func(Located) bool

// Shop is what a shop is shown at now. Only active categories, brands and
// items are listed: what disappears is withdrawn. A listed item the supplier
// cannot sell right now says available: false. catalogSHA identifies the
// document; the view's version also moves with promotions and availability,
// so a shop's cached copy is refreshed exactly when something it shows
// changed.
func Shop(document Document, catalogSHA string, now time.Time, testMode bool, available Availability) ShopView {
	view := ShopView{
		Currency:    Currency,
		TestMode:    testMode,
		GeneratedAt: now.UTC(),
		Categories:  []ShopCategory{},
		Countries:   []ShopCountry{},
		Brands:      []ShopBrand{},
	}
	categories := map[string]Category{}
	for _, category := range document.Categories {
		if isActive(category.Active) {
			categories[category.Key] = category
		}
	}
	countryOrder := map[string]int{}
	countryEntries := map[string]Country{}
	for i, country := range document.Countries {
		countryOrder[country.Code] = i
		countryEntries[country.Code] = country
	}

	type rankedBrand struct {
		brand Brand
		items []Item
	}
	var brands []rankedBrand
	for _, brand := range document.Brands {
		if !isActive(brand.Active) {
			continue
		}
		if _, ok := categories[brand.Category]; !ok {
			continue
		}
		var items []Item
		for _, item := range brand.Items {
			if isActive(item.Active) {
				items = append(items, item)
			}
		}
		if len(items) == 0 {
			continue
		}
		sortItems(items, countryOrder)
		brands = append(brands, rankedBrand{brand: brand, items: items})
	}
	sort.SliceStable(brands, func(i, j int) bool {
		a, b := brands[i].brand, brands[j].brand
		if a.Featured != b.Featured {
			return a.Featured
		}
		if a.Sort != b.Sort {
			return a.Sort < b.Sort
		}
		return a.Key < b.Key
	})

	usedCategories := map[string]bool{}
	usedCountries := map[string]bool{}
	fingerprint := sha256.New()
	fmt.Fprintf(fingerprint, "%s|%t\n", catalogSHA, testMode)
	for rank, ranked := range brands {
		brand := ranked.brand
		usedCategories[brand.Category] = true
		shopBrand := ShopBrand{
			Key:        brand.Key,
			Name:       brand.Name,
			Aliases:    append([]string{}, brand.Aliases...),
			Category:   brand.Category,
			Rank:       rank,
			Featured:   brand.Featured,
			Badge:      brand.Badge,
			RedeemHint: brand.RedeemHint,
			Logo:       brand.Logo.Display,
			PrintLogo:  brand.Logo.Print,
			Items:      make([]ShopItem, 0, len(ranked.items)),
		}
		for itemRank, item := range ranked.items {
			if item.Country != "" {
				usedCountries[item.Country] = true
			}
			pricing := PriceAt(item, now)
			located := Located{Brand: brand, Category: categories[brand.Category], Item: item}
			if refs, err := ParseRefs(item); err == nil {
				located.Ref, located.Refs = refs[0], refs
			}
			shopItem := ShopItem{
				Key:                item.Key,
				Country:            item.Country,
				Label:              item.Label,
				FaceValue:          item.FaceValue,
				FaceCurrency:       item.FaceCurrency,
				UnitPrice:          pricing.UnitPrice,
				RetailPrice:        pricing.RetailPrice,
				RegularUnitPrice:   pricing.RegularUnitPrice,
				RegularRetailPrice: pricing.RegularRetailPrice,
				Available:          available == nil || available(located),
				Rank:               itemRank,
			}
			if pricing.Promo != nil {
				shopItem.Promo = &ShopPromo{Badge: pricing.Promo.Badge, EndsAt: pricing.Promo.EndsAt}
			}
			fmt.Fprintf(fingerprint, "%s|%s|%s|%t|%t\n",
				item.Key, shopItem.UnitPrice, shopItem.RetailPrice, shopItem.Promo != nil, shopItem.Available)
			shopBrand.Items = append(shopBrand.Items, shopItem)
		}
		view.Brands = append(view.Brands, shopBrand)
	}

	var listedCategories []Category
	for key := range usedCategories {
		listedCategories = append(listedCategories, categories[key])
	}
	sort.Slice(listedCategories, func(i, j int) bool {
		if listedCategories[i].Sort != listedCategories[j].Sort {
			return listedCategories[i].Sort < listedCategories[j].Sort
		}
		return listedCategories[i].Key < listedCategories[j].Key
	})
	for rank, category := range listedCategories {
		view.Categories = append(view.Categories, ShopCategory{Key: category.Key, Name: category.Name, Rank: rank})
	}

	var codes []string
	for code := range usedCountries {
		codes = append(codes, code)
	}
	sort.Slice(codes, func(i, j int) bool { return countryLess(codes[i], codes[j], countryOrder) })
	for _, code := range codes {
		entry := countryEntries[code]
		view.Countries = append(view.Countries, ShopCountry{
			Code: code,
			Name: countryLabel(code, &entry),
			Flag: entry.Flag,
		})
	}
	view.Version = hex.EncodeToString(fingerprint.Sum(nil))[:16]
	return view
}

// sortItems orders a brand's items: the operator's sort first, then by region
// in the order the catalog lists regions, then by face value, then by key —
// so "10, 25, 100" never reads "10, 100, 25".
func sortItems(items []Item, countryOrder map[string]int) {
	sort.SliceStable(items, func(i, j int) bool {
		a, b := items[i], items[j]
		if a.Sort != b.Sort {
			return a.Sort < b.Sort
		}
		if a.Country != b.Country {
			return countryLess(a.Country, b.Country, countryOrder)
		}
		if cmp := compareDecimal(a.FaceValue, b.FaceValue); cmp != 0 {
			return cmp < 0
		}
		if cmp := compareDecimal(a.RetailPrice, b.RetailPrice); cmp != 0 {
			return cmp < 0
		}
		return a.Key < b.Key
	})
}

func countryLess(a, b string, order map[string]int) bool {
	ai, aListed := order[a]
	bi, bListed := order[b]
	switch {
	case aListed && bListed:
		return ai < bi
	case aListed != bListed:
		return aListed
	}
	return a < b
}

func compareDecimal(a, b string) int {
	x, xOK := new(big.Rat).SetString(strings.TrimSpace(a))
	y, yOK := new(big.Rat).SetString(strings.TrimSpace(b))
	switch {
	case xOK && yOK:
		return x.Cmp(y)
	case xOK:
		return -1
	case yOK:
		return 1
	}
	return 0
}

// countryLabel is a region's Arabic name: the operator's own when the catalog
// gives one, else the relay's table.
func countryLabel(code string, entry *Country) string {
	if entry != nil && strings.TrimSpace(entry.Name) != "" {
		return strings.TrimSpace(entry.Name)
	}
	return CountryName(code)
}

// Item price modes.
const (
	PriceModeStatic = "static"
	PriceModeAuto   = "auto"
)

// AutoPriced reports whether the relay prices the item from its supplier cost.
func (d Document) AutoPriced(item Item) bool {
	mode := strings.ToLower(strings.TrimSpace(item.PriceMode))
	if mode == "" {
		mode = strings.ToLower(strings.TrimSpace(d.PriceMode))
	}
	return mode == PriceModeAuto
}

// WithPrices is a copy of the document in which every item for which price
// returns ok carries the returned prices. The original is untouched.
func (d Document) WithPrices(price func(Item) (shop, retail string, ok bool)) Document {
	out := d
	out.Brands = make([]Brand, len(d.Brands))
	for i, brand := range d.Brands {
		brand.Items = append([]Item(nil), brand.Items...)
		for j, item := range brand.Items {
			if shop, retail, ok := price(item); ok {
				brand.Items[j].Price, brand.Items[j].RetailPrice = shop, retail
			}
		}
		out.Brands[i] = brand
	}
	return out
}
