package cardsweb

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// The eSIM shelf's pages, as a chat app previews them and a search engine
// lists them: the shelf, each destination, and each plan of a destination.
// They are sent only while eSIMs are on sale to everyone; until then the
// addresses answer as the shelf, unlisted.

const (
	esimShelfShare = "شرائح eSIM للسفر"
	esimPerks      = "تثبّتها بلمسة، بلا شريحة بلاستيكية"
)

// PreviewESIM is one eSIM destination as its link's preview shows it.
type PreviewESIM struct {
	Name string
	// Kind is "local", "regional" or "global".
	Kind string
	// Country is a local destination's ISO code; empty for a region.
	Country string
	// Countries is how many countries a region reaches.
	Countries int
	// PromoBadge is the running promotion's words ("خصم 20%"); empty: none.
	PromoBadge string
	// Plans are on sale, cheapest first is not promised.
	Plans []PreviewESIMPlan
}

// PreviewESIMPlan is one plan at the price a customer pays now.
type PreviewESIMPlan struct {
	ID string
	// Data is the plan's size as sold ("1 GB").
	Data      string
	Days      int
	Unlimited bool
	Price     string
}

func esimPath(key string) string { return "/esim/" + url.PathEscape(key) }

func esimPlanPath(key, plan string) string { return esimPath(key) + "/" + url.PathEscape(plan) }

// esimDays is "7 أيام", "30 يوماً".
func esimDays(days int) string {
	switch {
	case days == 1:
		return "يوم واحد"
	case days == 2:
		return "يومان"
	case days >= 3 && days <= 10:
		return strconv.Itoa(days) + " أيام"
	}
	return strconv.Itoa(days) + " يوماً"
}

func esimPlanName(plan PreviewESIMPlan) string {
	data := plan.Data
	if plan.Unlimited {
		data = "بيانات غير محدودة"
	}
	return data + " · " + esimDays(plan.Days)
}

// esimPrices is the plans' price range.
func esimPrices(plans []PreviewESIMPlan) priceRange {
	items := make([]PreviewItem, 0, len(plans))
	for _, plan := range plans {
		items = append(items, PreviewItem{Price: plan.Price, Available: true})
	}
	return pricesOf(items)
}

// esimKeys are the destinations in the shelf's order.
func (p pages) esimKeys() []string {
	keys := make([]string, 0, len(p.shelf.ESIMs))
	for _, key := range p.shelf.ESIMOrder {
		if _, ok := p.shelf.ESIMs[key]; ok {
			keys = append(keys, key)
		}
	}
	return keys
}

// esim is the page at rest: "" the shelf, "turkey" a destination,
// "turkey/ea.PTR1G7" one of its plans.
func (p pages) esim(rest string) webPage {
	if len(p.shelf.ESIMs) == 0 {
		// Not on sale to everyone: the address opens the app, unlisted.
		page := p.plain()
		page.noindex = true
		return page
	}
	key, planID, _ := strings.Cut(strings.Trim(rest, "/"), "/")
	if key == "" {
		return p.esimShelf()
	}
	destination, ok := p.shelf.ESIMs[key]
	if !ok {
		return p.missing()
	}
	return p.esimDestination(key, destination, planID)
}

func (p pages) esimShelf() webPage {
	currency := p.shelf.Currency
	low := ""
	var lowest float64
	for _, destination := range p.shelf.ESIMs {
		prices := esimPrices(destination.Plans)
		if value, err := strconv.ParseFloat(prices.low, 64); err == nil && (low == "" || value < lowest) {
			low, lowest = prices.low, value
		}
	}
	page := webPage{
		status:     http.StatusOK,
		canonical:  "/esim",
		picture:    p.h.previews.esimPicture(""),
		shareTitle: esimShelfShare,
		title:      esimShelfShare + ": إنترنت في " + strconv.Itoa(len(p.shelf.ESIMs)) + " وجهة | " + siteName,
		description: "إنترنت فور وصولك في " + strconv.Itoa(len(p.shelf.ESIMs)) + " وجهة حول العالم: اختر وجهتك و" +
			esimPerks + priced(". الباقات تبدأ من ", low, currency) + ". ادفع إلكترونياً من " + siteName + ".",
	}
	keys := p.esimKeys()
	list := make([]map[string]any, 0, len(keys))
	for i, key := range keys {
		list = append(list, map[string]any{
			"@type": "ListItem", "position": i + 1,
			"name": "شريحة eSIM " + p.shelf.ESIMs[key].Name, "url": p.origin + esimPath(key),
		})
	}
	page.schema = []map[string]any{
		{
			"@type": "CollectionPage", "@id": p.origin + page.canonical, "url": p.origin + page.canonical,
			"name": page.title, "description": page.description, "inLanguage": "ar",
			"isPartOf":   map[string]any{"@id": p.origin + "/#site"},
			"mainEntity": map[string]any{"@type": "ItemList", "itemListElement": list},
		},
		p.breadcrumbs([]crumb{{"الرئيسية", "/"}, {esimShelfShare, page.canonical}}),
	}
	return page
}

// esimDestination is a destination's page, or one plan's when planID names
// one on sale; an unknown plan is listed as its destination.
func (p pages) esimDestination(key string, destination PreviewESIM, planID string) webPage {
	currency := p.shelf.Currency
	picture := p.h.previews.esimPicture(destination.Country)
	name := "شريحة eSIM " + destination.Name
	page := webPage{status: http.StatusOK, canonical: esimPath(key), picture: picture}
	crumbs := []crumb{{"الرئيسية", "/"}, {esimShelfShare, "/esim"}, {destination.Name, page.canonical}}
	reach := "إنترنت في " + destination.Name + " فور وصولك"
	if destination.Kind != "local" && destination.Countries > 1 {
		reach = "إنترنت في " + strconv.Itoa(destination.Countries) + " دولة بشريحة واحدة (" + destination.Name + ")"
	}
	promo := ""
	if destination.PromoBadge != "" {
		promo = " · " + destination.PromoBadge
	}
	product := map[string]any{
		"@type":    "Product",
		"image":    []string{p.origin + "/" + picture},
		"brand":    map[string]any{"@type": "Brand", "name": siteName},
		"category": esimShelfShare,
	}

	var chosen *PreviewESIMPlan
	for i := range destination.Plans {
		if planID != "" && destination.Plans[i].ID == planID {
			chosen = &destination.Plans[i]
		}
	}
	if chosen != nil {
		plan := *chosen
		planName := esimPlanName(plan)
		page.canonical = esimPlanPath(key, plan.ID)
		crumbs = append(crumbs, crumb{planName, page.canonical})
		page.shareTitle = name + " · " + planName + priced(" · ", plan.Price, currency) + promo
		page.title = name + " " + planName + priced(" بسعر ", plan.Price, currency) + " | " + siteName
		page.description = reach + ": باقة " + planName + priced(" بسعر ", plan.Price, currency) + "، " +
			esimPerks + ". ادفع إلكترونياً من " + siteName + "."
		page.offer = &offer{price: plan.Price, currency: currency, available: true}
		product["name"] = name + " " + planName
		product["sku"] = plan.ID
		product["offers"] = map[string]any{
			"@type": "Offer", "url": p.origin + page.canonical,
			"price": plan.Price, "priceCurrency": currency,
			"availability":  "https://schema.org/InStock",
			"itemCondition": "https://schema.org/NewCondition",
			"seller":        map[string]any{"@id": p.origin + "/#org"},
		}
	} else {
		prices := esimPrices(destination.Plans)
		page.shareTitle = name + priced(" · من ", prices.low, currency) + promo
		page.title = name + ": باقات إنترنت للسفر" + priced(" من ", prices.low, currency) + " | " + siteName
		page.description = reach + ": " + strconv.Itoa(len(destination.Plans)) + " باقة" +
			priced(" تبدأ من ", prices.low, currency) + "، " + esimPerks + ". ادفع إلكترونياً من " + siteName + "."
		product["name"] = name
		if prices.count > 0 {
			page.offer = &offer{price: prices.low, currency: currency, available: true}
			product["offers"] = map[string]any{
				"@type": "AggregateOffer", "url": p.origin + page.canonical,
				"lowPrice": prices.low, "highPrice": prices.high, "priceCurrency": currency,
				"offerCount": prices.count, "availability": "https://schema.org/InStock",
				"seller": map[string]any{"@id": p.origin + "/#org"},
			}
		}
	}
	product["@id"] = p.origin + page.canonical + "#product"
	product["url"] = p.origin + page.canonical
	product["description"] = page.description
	page.schema = []map[string]any{product, p.organization(), p.breadcrumbs(crumbs)}
	return page
}
