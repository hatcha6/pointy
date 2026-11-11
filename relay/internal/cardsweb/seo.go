package cardsweb

import (
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
)

// What a search engine is told about each page (the words are in page.go's
// head, the readable copy in static.go, the site's map in sitemap.go).
//
// The app draws itself on a canvas, which a crawler reads as an empty page.
// So every address the app answers is sent with what that page shows, read
// from the same catalog: its own title and description, the one address it
// should be listed under, schema.org data (a brand is a Product with its
// prices), and the page's content as plain HTML under the app.
//
// Pages that are one person's (their cards, their account) or that repeat
// another page (a search) ask not to be listed. An address the app does not
// know answers 404 with the app still in it, so a mistyped link opens the
// shelf for a person and is not listed as a copy of the shelf.

const (
	homeTitle       = siteName + " | كروت شحن واتصالات وإنترنت وألعاب في ليبيا"
	homeDescription = "اشترِ كروت ليبيانا والمدار والإنترنت، وبطاقات الألعاب والهدايا مثل ببجي وبلايستيشن وآيتونز، " +
		"أونلاين في ليبيا من " + siteName + ". ادفع إلكترونياً وتصلك فوراً."
	siteLatinName = "Daftar Cards"
	country       = "ليبيا"
)

// webPage is one address as it is sent.
type webPage struct {
	status  int
	noindex bool
	// canonical is the path (and query) the page is listed under; empty for
	// a page that is not listed.
	canonical string
	title     string
	// shareTitle is the title a messaging app shows, when not title.
	shareTitle  string
	description string
	// picture is the image's path ("og/site.<id>.jpg").
	picture string
	// offer is a brand's or a card's price, for shops' link previews.
	offer *offer
	// schema is the page's schema.org nodes.
	schema []map[string]any
	// content is the page as HTML (trusted: built by static.go).
	content string
}

type offer struct {
	price, currency string
	available       bool
}

// crumb is one step of the path to a page.
type crumb struct{ name, path string }

// pages builds the site's pages from one reading of the shelf.
type pages struct {
	h      *Handler
	origin string
	shelf  PreviewCatalog
	// read is whether the shelf could be read; without it no page claims a
	// brand is missing.
	read bool
}

func (h *Handler) pages(r *http.Request) pages {
	shelf, ok := h.previews.shelf(r.Context())
	return pages{h: h, origin: h.origin, shelf: shelf, read: ok && len(shelf.Brands) > 0}
}

// pageFor is the page at name ("brand/libyana"), on the card ?item= names.
func (h *Handler) pageFor(r *http.Request, name string) webPage {
	section, key, _ := strings.Cut(name, "/")
	key, _, _ = strings.Cut(key, "/")
	p := h.pages(r)
	switch section {
	case "":
		return p.home()
	case "category":
		if name, ok := p.shelf.Categories[key]; ok {
			return p.category(key, name)
		}
		return p.missing()
	case "brand":
		if brand, ok := p.shelf.Brands[key]; ok {
			return p.brand(key, brand, r.URL.Query().Get("item"))
		}
		return p.missing()
	case "privacy", "terms", "about":
		return p.document(section)
	case "esim":
		return p.esim(strings.TrimPrefix(name, "esim"))
	case "search", "my-cards", "account", "esims":
		// A search repeats the shelf, the rest are one person's own.
		page := p.plain()
		page.noindex = true
		return page
	}
	page := p.plain()
	page.status, page.noindex = http.StatusNotFound, true
	return page
}

// plain is a page with the shelf's own words and nothing of its own.
func (p pages) plain() webPage {
	return webPage{
		status:      http.StatusOK,
		title:       siteName,
		description: siteDescription,
		picture:     "og/site." + p.h.previews.site().id + ".jpg",
	}
}

// missing is a brand or category the shelf does not have. While the shelf
// cannot be read nothing is called missing: the page goes out unlisted.
func (p pages) missing() webPage {
	page := p.plain()
	page.noindex = true
	if p.read {
		page.status = http.StatusNotFound
	}
	return page
}

func (p pages) home() webPage {
	page := p.plain()
	page.canonical = "/"
	page.title, page.shareTitle = homeTitle, siteName
	page.description = homeDescription
	page.schema = []map[string]any{p.organization(), {
		"@type":      "WebSite",
		"@id":        p.origin + "/#site",
		"url":        p.origin + "/",
		"name":       siteName,
		"inLanguage": "ar",
		"alternateName": []string{
			siteLatinName, "دفتر",
		},
		"publisher": map[string]any{"@id": p.origin + "/#org"},
	}}
	if categories := p.categories(); len(categories) > 0 {
		list := make([]map[string]any, 0, len(categories))
		for i, key := range categories {
			list = append(list, map[string]any{
				"@type": "ListItem", "position": i + 1,
				"name": p.shelf.Categories[key], "url": p.origin + categoryPath(key),
			})
		}
		page.schema = append(page.schema, map[string]any{"@type": "ItemList", "itemListElement": list})
	}
	page.content = p.homeContent()
	return page
}

func (p pages) category(key, name string) webPage {
	page := p.plain()
	page.canonical = categoryPath(key)
	page.title = "كروت " + name + " في " + country + " | " + siteName
	page.description = "تصفّح كروت " + name + " واشترِها أونلاين في " + country + " من " + siteName +
		p.brandNames(key) + ". ادفع إلكترونياً وتصلك فوراً."
	crumbs := []crumb{{"الرئيسية", "/"}, {name, page.canonical}}
	brands := p.brandsIn(key)
	list := make([]map[string]any, 0, len(brands))
	for i, brandKey := range brands {
		list = append(list, map[string]any{
			"@type": "ListItem", "position": i + 1,
			"name": p.shelf.Brands[brandKey].Name, "url": p.origin + brandPath(brandKey),
		})
	}
	page.schema = []map[string]any{
		{
			"@type": "CollectionPage", "@id": p.origin + page.canonical, "url": p.origin + page.canonical,
			"name": page.title, "description": page.description, "inLanguage": "ar",
			"isPartOf":   map[string]any{"@id": p.origin + "/#site"},
			"mainEntity": map[string]any{"@type": "ItemList", "itemListElement": list},
		},
		p.breadcrumbs(crumbs),
	}
	page.content = p.categoryContent(key, name, crumbs)
	return page
}

// brand is a brand's page, or one of its cards' when itemKey names one on
// sale. A card that is out of stock, or unknown, is listed as its brand.
func (p pages) brand(key string, brand PreviewBrand, itemKey string) webPage {
	b := p.h.previews.brandBanner(key, brand)
	picture := "og/brand/" + url.PathEscape(key) + "." + b.id + ".jpg"
	phrase := brandPhrase(brand)
	prices := pricesOf(brand.Items)
	currency := p.shelf.Currency
	page := webPage{status: http.StatusOK, picture: picture, canonical: brandPath(key)}
	crumbs := []crumb{{"الرئيسية", "/"}}
	if name, ok := p.shelf.Categories[brand.Category]; ok {
		crumbs = append(crumbs, crumb{name, categoryPath(brand.Category)})
	}
	crumbs = append(crumbs, crumb{brand.Name, page.canonical})

	product := map[string]any{
		"@type":    "Product",
		"image":    []string{p.origin + "/" + picture},
		"brand":    map[string]any{"@type": "Brand", "name": brand.Name},
		"category": p.shelf.Categories[brand.Category],
	}
	if len(brand.Aliases) > 0 {
		product["alternateName"] = brand.Aliases
	}

	var chosen *PreviewItem
	for i := range brand.Items {
		if brand.Items[i].Key == itemKey && itemKey != "" {
			chosen = &brand.Items[i]
		}
	}
	if chosen != nil && chosen.Available {
		item := *chosen
		name := brand.Name + " " + p.itemName(brand, item)
		page.canonical = itemPath(key, item.Key)
		crumbs = append(crumbs, crumb{p.itemName(brand, item), page.canonical})
		page.title = name + priced(" بسعر ", item.Price, currency) + " | " + siteName
		page.description = "اشترِ " + name + " أونلاين في " + country + " من " + siteName +
			priced(" بسعر ", item.Price, currency) + ". ادفع إلكترونياً ويصلك فوراً."
		page.offer = &offer{price: item.Price, currency: currency, available: true}
		product["name"] = name
		product["sku"] = item.Key
		product["offers"] = map[string]any{
			"@type": "Offer", "url": p.origin + page.canonical,
			"price": item.Price, "priceCurrency": currency,
			"availability":  "https://schema.org/InStock",
			"itemCondition": "https://schema.org/NewCondition",
			"seller":        map[string]any{"@id": p.origin + "/#org"},
		}
	} else {
		chosen = nil
		page.title = phrase + " في " + country + priced(" من ", prices.low, currency) + " | " + siteName
		page.description = phrase + " أونلاين في " + country + " من " + siteName +
			priced("، والأسعار تبدأ من ", prices.low, currency) + ". ادفع إلكترونياً ويصلك فوراً."
		product["name"] = phrase
		if prices.count > 0 {
			availability := "https://schema.org/OutOfStock"
			if prices.available {
				availability = "https://schema.org/InStock"
			}
			page.offer = &offer{price: prices.low, currency: currency, available: prices.available}
			product["offers"] = map[string]any{
				"@type": "AggregateOffer", "url": p.origin + page.canonical,
				"lowPrice": prices.low, "highPrice": prices.high, "priceCurrency": currency,
				"offerCount": prices.count, "availability": availability,
				"seller": map[string]any{"@id": p.origin + "/#org"},
			}
		}
	}
	product["@id"] = p.origin + page.canonical + "#product"
	product["url"] = p.origin + page.canonical
	product["description"] = page.description
	page.schema = []map[string]any{product, p.organization(), p.breadcrumbs(crumbs)}
	page.content = p.brandContent(key, brand, chosen, crumbs)
	return page
}

func (p pages) organization() map[string]any {
	org := map[string]any{
		"@type": "Organization", "@id": p.origin + "/#org",
		"name": siteName, "alternateName": siteLatinName,
		"url": p.origin + "/", "logo": p.origin + "/icons/Icon-512.png",
		"areaServed": "LY",
	}
	same := []string{}
	for _, store := range []string{p.h.stores.IOS, p.h.stores.Android} {
		link, err := url.Parse(store)
		if err != nil || store == "" {
			continue
		}
		// The store page itself, without a campaign's own parameters.
		query := url.Values{}
		if id := link.Query().Get("id"); id != "" {
			query.Set("id", id)
		}
		link.RawQuery = query.Encode()
		same = append(same, link.String())
	}
	if len(same) > 0 {
		org["sameAs"] = same
	}
	return org
}

func (p pages) breadcrumbs(crumbs []crumb) map[string]any {
	list := make([]map[string]any, 0, len(crumbs))
	for i, c := range crumbs {
		list = append(list, map[string]any{
			"@type": "ListItem", "position": i + 1, "name": c.name, "item": p.origin + c.path,
		})
	}
	return map[string]any{"@type": "BreadcrumbList", "itemListElement": list}
}

// categories are the shelf's categories in its order (by key where the
// source gave none).
func (p pages) categories() []string {
	if len(p.shelf.CategoryOrder) > 0 {
		return p.shelf.CategoryOrder
	}
	keys := make([]string, 0, len(p.shelf.Categories))
	for key := range p.shelf.Categories {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// brandsIn are a category's brand keys in the shelf's order; every brand's
// for an empty category.
func (p pages) brandsIn(category string) []string {
	keys := []string{}
	for key, brand := range p.shelf.Brands {
		if category == "" || brand.Category == category {
			keys = append(keys, key)
		}
	}
	sort.Slice(keys, func(i, j int) bool {
		a, b := p.shelf.Brands[keys[i]], p.shelf.Brands[keys[j]]
		if a.Order != b.Order {
			return a.Order < b.Order
		}
		return keys[i] < keys[j]
	})
	return keys
}

// brandNames names a category's first brands, for its description.
func (p pages) brandNames(category string) string {
	names := []string{}
	for _, key := range p.brandsIn(category) {
		if len(names) == 4 {
			break
		}
		names = append(names, p.shelf.Brands[key].Name)
	}
	if len(names) == 0 {
		return ""
	}
	return "، مثل " + strings.Join(names, " و")
}

// itemName is a card's label, with its country where the brand sells the
// same card for several.
func (p pages) itemName(brand PreviewBrand, item PreviewItem) string {
	if item.Country == "" {
		return item.Label
	}
	for _, other := range brand.Items {
		if other.Country != item.Country {
			if name := p.shelf.Countries[item.Country]; name != "" {
				return item.Label + " " + name
			}
			return item.Label + " " + item.Country
		}
	}
	return item.Label
}

// brandPhrase is how people ask for a brand's cards: «كروت شحن ليبيانا»,
// «شحن ببجي موبايل», «مفتاح لعبة Arma 3».
func brandPhrase(brand PreviewBrand) string {
	switch brand.Category {
	case "telecom", "intl_topup":
		return "كروت شحن " + brand.Name
	case "internet":
		return "كروت إنترنت " + brand.Name
	case "gaming":
		return "شحن " + brand.Name
	case "game_keys":
		return "مفتاح لعبة " + brand.Name
	case "gift_cards":
		return "بطاقات " + brand.Name
	case "tv":
		return "اشتراك " + brand.Name
	}
	return "كروت " + brand.Name
}

type priceRange struct {
	low, high string
	// count is how many cards the range covers.
	count     int
	available bool
}

// pricesOf is the range of the cards on sale, or of every card when none is.
func pricesOf(items []PreviewItem) priceRange {
	out := priceRange{}
	for _, item := range items {
		out.available = out.available || item.Available
	}
	var low, high float64
	for _, item := range items {
		value, err := strconv.ParseFloat(item.Price, 64)
		if err != nil || value <= 0 || (out.available && !item.Available) {
			continue
		}
		if out.count == 0 || value < low {
			low, out.low = value, item.Price
		}
		if out.count == 0 || value > high {
			high, out.high = value, item.Price
		}
		out.count++
	}
	return out
}

// priced is " من 10.25 د.ل" for a known price, nothing otherwise.
func priced(lead, price, currency string) string {
	if price == "" {
		return ""
	}
	return lead + money(price, currency)
}

// money writes a price as people read it: "5 د.ل", "10.25 د.ل".
func money(price, currency string) string {
	if strings.Contains(price, ".") {
		price = strings.TrimRight(strings.TrimRight(price, "0"), ".")
	}
	if currency == "LYD" || currency == "" {
		return price + " د.ل"
	}
	return price + " " + currency
}

func categoryPath(key string) string { return "/category/" + url.PathEscape(key) }

func brandPath(key string) string { return "/brand/" + url.PathEscape(key) }

func itemPath(brand, item string) string {
	return brandPath(brand) + "?item=" + url.QueryEscape(item)
}
