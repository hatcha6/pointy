package cardsweb

import (
	"encoding/json"
	"encoding/xml"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"testing/fstest"
)

// stocked is a shelf with prices: a game sold for two countries, one card of
// it out of stock, and a phone company.
func stocked() *fakeShelf {
	return &fakeShelf{
		catalog: PreviewCatalog{
			Currency:      "LYD",
			Categories:    map[string]string{"telecom": "اتصالات", "gaming": "الألعاب"},
			CategoryOrder: []string{"telecom", "gaming"},
			Countries:     map[string]string{"TR": "تركيا", "US": "الولايات المتحدة"},
			Brands: map[string]PreviewBrand{
				"libyana": {
					Name: "ليبيانا", Category: "telecom", Order: 0, RedeemHint: "اتصل بالرقم 120",
					Items: []PreviewItem{
						{Key: "libyana-5lyd", Label: "5 دينار", Price: "5.00", Available: true},
						{Key: "libyana-10lyd", Label: "10 دينار", Price: "10.00", Available: true},
					},
				},
				"pubg": {
					Name: "ببجي موبايل", Category: "gaming", Order: 1, Aliases: []string{"PUBG", "شدات"},
					Items: []PreviewItem{
						{Key: "pubg-tr-60", Label: "60 شدة", Country: "TR", Price: "10.25", Available: true},
						{Key: "pubg-us-60", Label: "60 شدة", Country: "US", Price: "4.00", Available: false},
						{Key: "pubg-us-325", Label: "325 <شدة>", Country: "US", Price: "52.50", Available: true},
					},
				},
				"sold_out": {
					Name: "نافد", Category: "gaming", Order: 2,
					Items: []PreviewItem{{Key: "gone", Label: "1", Price: "3.00"}},
				},
			},
		},
		asked: map[string]int{},
	}
}

func seoHandler(t *testing.T, source Source) *Handler {
	t.Helper()
	files := build()
	files["index.html"] = &fstest.MapFile{Data: []byte(
		`<!doctype html><html lang="ar" dir="rtl"><head><meta name="description" content="x"><title>دفتر كروت</title></head><body><picture id="splash"></picture></body></html>`)}
	files["assets/assets/legal/privacy.ar.md"] = &fstest.MapFile{Data: []byte("آخر تحديث\n\n## ما نجمعه\n\n- رقم <هاتفك>\n- طلباتك\n\nنص.")}
	h, err := Wrap(http.NotFoundHandler(), Config{
		Hosts: []string{"cards.dftr.ly", "kroot.example"}, Files: files, Previews: source,
		Stores: StoreLinks{Android: "https://play.google.com/store/apps/details?id=ly.dftr.cards&utm=x"},
	})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

var schemaScript = regexp.MustCompile(`<script type="application/ld\+json">(.*?)</script>`)

// schemaOf is the page's schema.org nodes by type.
func schemaOf(t *testing.T, page string) map[string]map[string]any {
	t.Helper()
	match := schemaScript.FindStringSubmatch(page)
	if match == nil {
		t.Fatalf("no structured data in %s", page)
	}
	var data struct {
		Context string           `json:"@context"`
		Graph   []map[string]any `json:"@graph"`
	}
	if err := json.Unmarshal([]byte(match[1]), &data); err != nil || data.Context != "https://schema.org" {
		t.Fatalf("structured data %q: %v", match[1], err)
	}
	out := map[string]map[string]any{}
	for _, node := range data.Graph {
		out[node["@type"].(string)] = node
	}
	return out
}

func mustContain(t *testing.T, page string, wants ...string) {
	t.Helper()
	for _, want := range wants {
		if !strings.Contains(page, want) {
			t.Fatalf("missing %s in:\n%s", want, page)
		}
	}
}

func TestABrandPageIsAProductWithItsPrices(t *testing.T) {
	h := seoHandler(t, stocked())
	got := get(h, http.MethodGet, "cards.dftr.ly", "/brand/pubg?utm_source=ad")
	page := got.Body.String()
	if got.Code != http.StatusOK || got.Header().Get("X-Robots-Tag") != "" {
		t.Fatalf("status %d, robots %q", got.Code, got.Header().Get("X-Robots-Tag"))
	}
	mustContain(t, page,
		"<title>شحن ببجي موبايل في ليبيا من 10.25 د.ل | دفتر كروت</title>",
		`<link rel="canonical" href="https://cards.dftr.ly/brand/pubg">`,
		`<meta name="robots" content="index, follow`,
		`<meta property="og:type" content="product">`,
		`<meta property="product:price:amount" content="10.25">`,
		`<meta property="product:price:currency" content="LYD">`,
		// The content: every card with its price, the ones on sale linked.
		"<h1>شحن ببجي موبايل في ليبيا</h1>",
		"يُعرف أيضاً باسم: PUBG، شدات.",
		`<td><a href="/brand/pubg?item=pubg-tr-60">60 شدة</a></td><td>تركيا</td><td>10.25 د.ل</td><td>متوفر</td>`,
		`<td>60 شدة</td><td>الولايات المتحدة</td><td>4 د.ل</td><td>غير متوفر حالياً</td>`,
		`325 &lt;شدة&gt;`,
		`<a href="/category/gaming">الألعاب</a>`,
		`<a href="/brand/sold_out">شحن نافد</a> (غير متوفر حالياً)`,
	)
	if strings.Count(page, `<meta name="description"`) != 1 || strings.Contains(page, `content="x"`) {
		t.Fatalf("descriptions: %s", page)
	}
	// The content comes first in the body, ahead of the app's own elements.
	if !regexp.MustCompile(`<body>\s*<div id="static">`).MatchString(page) || strings.Index(page, `id="static"`) > strings.Index(page, `id="splash"`) {
		t.Fatalf("content is not first in the body: %s", page)
	}

	schema := schemaOf(t, page)
	product := schema["Product"]
	offers, _ := product["offers"].(map[string]any)
	// The range is of what is on sale: the 4.00 card is out of stock.
	if offers["@type"] != "AggregateOffer" || offers["lowPrice"] != "10.25" || offers["highPrice"] != "52.50" ||
		offers["offerCount"] != float64(2) || offers["priceCurrency"] != "LYD" ||
		offers["availability"] != "https://schema.org/InStock" {
		t.Fatalf("offers %v", offers)
	}
	if product["name"] != "شحن ببجي موبايل" || product["url"] != "https://cards.dftr.ly/brand/pubg" {
		t.Fatalf("product %v", product)
	}
	if images, _ := product["image"].([]any); len(images) != 1 || !strings.HasPrefix(images[0].(string), "https://cards.dftr.ly/og/brand/pubg.") {
		t.Fatalf("image %v", product["image"])
	}
	crumbs, _ := schema["BreadcrumbList"]["itemListElement"].([]any)
	if len(crumbs) != 3 || crumbs[1].(map[string]any)["item"] != "https://cards.dftr.ly/category/gaming" {
		t.Fatalf("breadcrumbs %v", crumbs)
	}
}

func TestACardOnSaleHasItsOwnPage(t *testing.T) {
	h := seoHandler(t, stocked())
	page := get(h, http.MethodGet, "cards.dftr.ly", "/brand/pubg?item=pubg-tr-60&c=AHMED").Body.String()
	mustContain(t, page,
		"<title>ببجي موبايل 60 شدة تركيا بسعر 10.25 د.ل | دفتر كروت</title>",
		`<link rel="canonical" href="https://cards.dftr.ly/brand/pubg?item=pubg-tr-60">`,
		"<h1>ببجي موبايل 60 شدة تركيا</h1>",
		`<a href="/brand/pubg">كل فئات ببجي موبايل</a>`,
	)
	offers, _ := schemaOf(t, page)["Product"]["offers"].(map[string]any)
	if offers["@type"] != "Offer" || offers["price"] != "10.25" || offers["availability"] != "https://schema.org/InStock" ||
		offers["url"] != "https://cards.dftr.ly/brand/pubg?item=pubg-tr-60" {
		t.Fatalf("offer %v", offers)
	}

	// A card out of stock, or one the brand does not have, is its brand's page.
	for _, item := range []string{"pubg-us-60", "nope"} {
		page := get(h, http.MethodGet, "cards.dftr.ly", "/brand/pubg?item="+item).Body.String()
		mustContain(t, page, `<link rel="canonical" href="https://cards.dftr.ly/brand/pubg">`, "<h1>شحن ببجي موبايل في ليبيا</h1>")
	}
}

func TestABrandWithNothingOnSaleSaysSo(t *testing.T) {
	h := seoHandler(t, stocked())
	page := get(h, http.MethodGet, "cards.dftr.ly", "/brand/sold_out").Body.String()
	offers, _ := schemaOf(t, page)["Product"]["offers"].(map[string]any)
	if offers["availability"] != "https://schema.org/OutOfStock" || offers["lowPrice"] != "3.00" {
		t.Fatalf("offers %v", offers)
	}
	mustContain(t, page, `<meta property="product:availability" content="out of stock">`)
}

func TestTheShelfAndACategoryListTheirBrands(t *testing.T) {
	h := seoHandler(t, stocked())
	home := get(h, http.MethodGet, "cards.dftr.ly", "/").Body.String()
	mustContain(t, home,
		"<title>"+homeTitle+"</title>",
		`<meta property="og:title" content="دفتر كروت">`,
		`<link rel="canonical" href="https://cards.dftr.ly/">`,
		`<h2><a href="/category/telecom">اتصالات</a></h2>`,
		`<li><a href="/brand/libyana">كروت شحن ليبيانا</a>، من 5 د.ل</li>`,
		`<a href="/privacy">سياسة الخصوصية</a>`,
		`<a href="https://play.google.com/store/apps/details?id=ly.dftr.cards&amp;utm=x" rel="noopener">`,
	)
	// Telecom comes before gaming, as on the shelf.
	if strings.Index(home, "/category/telecom") > strings.Index(home, "/category/gaming") {
		t.Fatal("categories out of the shelf's order")
	}
	schema := schemaOf(t, home)
	if schema["WebSite"]["name"] != "دفتر كروت" || schema["Organization"]["logo"] != "https://cards.dftr.ly/icons/Icon-512.png" {
		t.Fatalf("site %v", schema)
	}
	if same, _ := schema["Organization"]["sameAs"].([]any); len(same) != 1 || same[0] != "https://play.google.com/store/apps/details?id=ly.dftr.cards" {
		t.Fatalf("sameAs %v", schema["Organization"]["sameAs"])
	}

	category := get(h, http.MethodGet, "cards.dftr.ly", "/category/gaming").Body.String()
	mustContain(t, category,
		"<title>كروت الألعاب في ليبيا | دفتر كروت</title>",
		`<link rel="canonical" href="https://cards.dftr.ly/category/gaming">`,
		"<h1>كروت الألعاب في ليبيا</h1>",
		`<li><a href="/brand/pubg">شحن ببجي موبايل</a>، من 10.25 د.ل</li>`,
	)
	list, _ := schemaOf(t, category)["CollectionPage"]["mainEntity"].(map[string]any)
	if elements, _ := list["itemListElement"].([]any); len(elements) != 2 {
		t.Fatalf("category list %v", list)
	}
}

func TestPagesAreListedUnderTheFirstHost(t *testing.T) {
	h := seoHandler(t, stocked())
	page := get(h, http.MethodGet, "kroot.example", "/brand/libyana").Body.String()
	mustContain(t, page,
		`<link rel="canonical" href="https://cards.dftr.ly/brand/libyana">`,
		`<meta property="og:url" content="https://cards.dftr.ly/brand/libyana">`,
	)
}

func TestPrivatePagesAndUnknownAddressesAreNotListed(t *testing.T) {
	h := seoHandler(t, stocked())
	for target, status := range map[string]int{
		"/my-cards":         http.StatusOK,
		"/my-cards/order-1": http.StatusOK,
		"/account":          http.StatusOK,
		"/search?q=ببجي":    http.StatusOK,
		"/esims/8944":       http.StatusOK,
		"/esim":             http.StatusOK,
		"/brand/unknown":    http.StatusNotFound,
		"/category/nope":    http.StatusNotFound,
		"/anything-else":    http.StatusNotFound,
	} {
		got := get(h, http.MethodGet, "cards.dftr.ly", target)
		page := got.Body.String()
		if got.Code != status || got.Header().Get("X-Robots-Tag") != "noindex" {
			t.Fatalf("%s: %d, robots %q", target, got.Code, got.Header().Get("X-Robots-Tag"))
		}
		// Still the app, which opens the shelf; never listed, never a copy.
		mustContain(t, page, "<title>دفتر كروت</title>", `<meta name="robots" content="noindex">`, `id="splash"`)
		if strings.Contains(page, `rel="canonical"`) || strings.Contains(page, `id="static"`) {
			t.Fatalf("%s is written as a listed page: %s", target, page)
		}
	}
}

func TestAnUnreadableCatalogCallsNothingMissing(t *testing.T) {
	source := stocked()
	source.err = errors.New("database down")
	h := seoHandler(t, source)
	<-h.previews.refreshLocked()
	got := get(h, http.MethodGet, "cards.dftr.ly", "/brand/pubg")
	if got.Code != http.StatusOK || got.Header().Get("X-Robots-Tag") != "noindex" {
		t.Fatalf("brand: %d %q", got.Code, got.Header().Get("X-Robots-Tag"))
	}
	if home := get(h, http.MethodGet, "cards.dftr.ly", "/"); home.Code != http.StatusOK || home.Header().Get("X-Robots-Tag") != "" {
		t.Fatalf("home: %d", home.Code)
	}
	if sitemap := get(h, http.MethodGet, "cards.dftr.ly", "/sitemap.xml"); sitemap.Code != http.StatusServiceUnavailable || sitemap.Header().Get("Retry-After") == "" {
		t.Fatalf("sitemap: %d", sitemap.Code)
	}
}

func TestTheLegalPagesCarryTheAppsOwnText(t *testing.T) {
	h := seoHandler(t, stocked())
	page := get(h, http.MethodGet, "cards.dftr.ly", "/privacy").Body.String()
	mustContain(t, page,
		"<title>سياسة الخصوصية | دفتر كروت</title>",
		`<link rel="canonical" href="https://cards.dftr.ly/privacy">`,
		"<h1>سياسة الخصوصية</h1>",
		"<h2>ما نجمعه</h2>\n<ul>\n<li>رقم &lt;هاتفك&gt;</li>\n<li>طلباتك</li>\n</ul>\n<p>نص.</p>",
	)
	// A build without the text still has the page.
	mustContain(t, get(h, http.MethodGet, "cards.dftr.ly", "/terms").Body.String(), "<h1>شروط الاستخدام</h1>")
}

func TestRobotsAndTheSitemap(t *testing.T) {
	h := seoHandler(t, stocked())
	robots := get(h, http.MethodGet, "cards.dftr.ly", "/robots.txt")
	if robots.Code != http.StatusOK || !strings.HasPrefix(robots.Header().Get("Content-Type"), "text/plain") {
		t.Fatalf("robots: %d %q", robots.Code, robots.Header().Get("Content-Type"))
	}
	mustContain(t, robots.Body.String(), "User-agent: *\nAllow: /\nDisallow: /go/\n", "Sitemap: https://cards.dftr.ly/sitemap.xml")

	got := get(h, http.MethodGet, "cards.dftr.ly", "/sitemap.xml")
	if got.Code != http.StatusOK || !strings.HasPrefix(got.Header().Get("Content-Type"), "application/xml") {
		t.Fatalf("sitemap: %d %q", got.Code, got.Header().Get("Content-Type"))
	}
	var sitemap struct {
		URLs []struct {
			Loc   string `xml:"loc"`
			Image string `xml:"http://www.google.com/schemas/sitemap-image/1.1 image>loc"`
		} `xml:"url"`
	}
	if err := xml.Unmarshal(got.Body.Bytes(), &sitemap); err != nil {
		t.Fatalf("sitemap does not parse: %v\n%s", err, got.Body.String())
	}
	locs := []string{}
	for _, entry := range sitemap.URLs {
		locs = append(locs, strings.TrimPrefix(entry.Loc, "https://cards.dftr.ly"))
		if strings.HasPrefix(entry.Loc, "https://cards.dftr.ly/brand/pubg") && !strings.Contains(entry.Loc, "?") &&
			!strings.HasPrefix(entry.Image, "https://cards.dftr.ly/og/brand/pubg.") {
			t.Fatalf("pubg's picture: %q", entry.Image)
		}
	}
	want := []string{
		"/", "/category/telecom", "/category/gaming",
		"/brand/libyana", "/brand/pubg", "/brand/sold_out",
		"/brand/libyana?item=libyana-5lyd", "/brand/libyana?item=libyana-10lyd",
		"/brand/pubg?item=pubg-tr-60", "/brand/pubg?item=pubg-us-325",
		"/about", "/privacy", "/terms",
	}
	if strings.Join(locs, " ") != strings.Join(want, " ") {
		t.Fatalf("sitemap lists\n%v\nwant\n%v", locs, want)
	}
	// Every address the map lists is a page that asks to be listed, under
	// that same address.
	for _, loc := range locs {
		page := get(h, http.MethodGet, "cards.dftr.ly", loc)
		if page.Code != http.StatusOK || page.Header().Get("X-Robots-Tag") != "" ||
			!strings.Contains(page.Body.String(), `<link rel="canonical" href="https://cards.dftr.ly`+strings.ReplaceAll(loc, "&", "&amp;")+`">`) {
			t.Fatalf("%s is in the sitemap but is not listed under it", loc)
		}
	}
}

func TestMoney(t *testing.T) {
	for price, want := range map[string]string{"5.00": "5 د.ل", "10.25": "10.25 د.ل", "10.50": "10.5 د.ل", "100": "100 د.ل"} {
		if got := money(price, "LYD"); got != want {
			t.Fatalf("money(%s) = %s", price, got)
		}
	}
	if got := money("3.00", "USD"); got != "3 USD" {
		t.Fatal(got)
	}
}
