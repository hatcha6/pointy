package cardsweb

import (
	"html"
	"io/fs"
	"strings"
)

// A page's content as plain HTML: what the app draws on its canvas, written
// out for whoever cannot run the app. A search engine reads it, and a browser
// without scripts shows it as the page, its links leading to the same pages
// of the other brands.
//
// It carries no pictures (the app has already fetched its own) and is a few
// kilobytes compressed. Where the app runs it is kept out of sight and out of
// the keyboard's way (staticHead): the app is the page.

// staticHead styles the content for a browser without scripts, and puts it
// aside in one that runs the app.
const staticHead = `  <style>
    #static{font:16px/1.8 system-ui,-apple-system,"Segoe UI",Tahoma,sans-serif;color:#1c1917;max-width:760px;margin:0 auto;padding:24px 20px 64px}
    #static a{color:#0f766e}
    #static table{border-collapse:collapse;width:100%}
    #static th,#static td{padding:8px 4px;border-bottom:1px solid #e7e5e4;text-align:start}
    #static ul{padding-inline-start:20px}
    #static nav,#static footer{font-size:14px}
    .app #static{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip-path:inset(50%);white-space:nowrap}
    @media (prefers-color-scheme:dark){#static{color:#e7e5e4}#static a{color:#5eead4}#static th,#static td{border-color:#292524}}
  </style>
  <script>document.documentElement.classList.add("app")</script>
  <noscript><style>#splash{display:none}</style></noscript>
`

// staticTail takes the content out of the keyboard's and a screen reader's
// way once the app is the page.
const staticTail = `<script>document.getElementById("static").inert=true</script>`

var esc = html.EscapeString

func link(path, text string) string {
	return `<a href="` + esc(path) + `">` + esc(text) + `</a>`
}

// frame is a page's content between the site's header and footer.
func (p pages) frame(crumbs []crumb, inner string) string {
	var out strings.Builder
	out.WriteString(`<div id="static">` + "\n<header><p>" + link("/", siteName) + "</p></header>\n")
	if len(crumbs) > 1 {
		out.WriteString(`<nav aria-label="مسار الصفحة">`)
		for i, c := range crumbs {
			if i > 0 {
				out.WriteString(" ‹ ")
			}
			if i == len(crumbs)-1 {
				out.WriteString(esc(c.name))
			} else {
				out.WriteString(link(c.path, c.name))
			}
		}
		out.WriteString("</nav>\n")
	}
	out.WriteString("<main>\n" + inner + "</main>\n<footer>\n")
	if categories := p.categories(); len(categories) > 0 {
		out.WriteString("<p>الأقسام: ")
		for i, key := range categories {
			if i > 0 {
				out.WriteString(" · ")
			}
			out.WriteString(link(categoryPath(key), p.shelf.Categories[key]))
		}
		out.WriteString("</p>\n")
	}
	out.WriteString("<p>" + link("/about", "عن التطبيق") + " · " + link("/privacy", "سياسة الخصوصية") +
		" · " + link("/terms", "شروط الاستخدام"))
	if store := p.h.stores.IOS; store != "" {
		out.WriteString(` · <a href="` + esc(store) + `" rel="noopener">التطبيق على App Store</a>`)
	}
	if store := p.h.stores.Android; store != "" {
		out.WriteString(` · <a href="` + esc(store) + `" rel="noopener">التطبيق على Google Play</a>`)
	}
	out.WriteString("</p>\n</footer>\n</div>\n" + staticTail + "\n")
	return out.String()
}

func (p pages) homeContent() string {
	var out strings.Builder
	out.WriteString("<h1>" + esc(siteName+": كروت الشحن والإنترنت والألعاب في "+country) + "</h1>\n")
	out.WriteString("<p>" + esc(homeDescription) + "</p>\n")
	for _, key := range p.categories() {
		out.WriteString("<section>\n<h2>" + link(categoryPath(key), p.shelf.Categories[key]) + "</h2>\n")
		out.WriteString(p.brandList(p.brandsIn(key)))
		out.WriteString("</section>\n")
	}
	return p.frame(nil, out.String())
}

func (p pages) categoryContent(key, name string, crumbs []crumb) string {
	var out strings.Builder
	out.WriteString("<h1>" + esc("كروت "+name+" في "+country) + "</h1>\n")
	out.WriteString("<p>" + esc("اختر الكرت، ادفع إلكترونياً، ويصلك فوراً من "+siteName+".") + "</p>\n")
	out.WriteString(p.brandList(p.brandsIn(key)))
	return p.frame(crumbs, out.String())
}

// brandList links brands, each with where its prices start.
func (p pages) brandList(keys []string) string {
	var out strings.Builder
	out.WriteString("<ul>\n")
	for _, key := range keys {
		brand := p.shelf.Brands[key]
		out.WriteString("<li>" + link(brandPath(key), brandPhrase(brand)))
		prices := pricesOf(brand.Items)
		switch {
		case !prices.available:
			out.WriteString(" (غير متوفر حالياً)")
		case prices.low != "":
			out.WriteString(esc(priced("، من ", prices.low, p.shelf.Currency)))
		}
		out.WriteString("</li>\n")
	}
	out.WriteString("</ul>\n")
	return out.String()
}

// brandContent is a brand's page, led by the chosen card when there is one.
func (p pages) brandContent(key string, brand PreviewBrand, chosen *PreviewItem, crumbs []crumb) string {
	currency := p.shelf.Currency
	phrase := brandPhrase(brand)
	var out strings.Builder
	if chosen != nil {
		name := brand.Name + " " + p.itemName(brand, *chosen)
		out.WriteString("<h1>" + esc(name) + "</h1>\n")
		out.WriteString("<p>" + esc("السعر: "+money(chosen.Price, currency)+"، متوفر الآن. ادفع إلكترونياً ويصلك فوراً من "+siteName+".") + "</p>\n")
		out.WriteString("<p>" + link(brandPath(key), "كل فئات "+brand.Name) + "</p>\n")
	} else {
		out.WriteString("<h1>" + esc(phrase+" في "+country) + "</h1>\n")
		prices := pricesOf(brand.Items)
		lead := phrase + " أونلاين في " + country + " من " + siteName
		if prices.available {
			lead += priced("، والأسعار تبدأ من ", prices.low, currency)
		}
		out.WriteString("<p>" + esc(lead+". ادفع إلكترونياً ويصلك فوراً.") + "</p>\n")
	}
	if len(brand.Aliases) > 0 {
		out.WriteString("<p>" + esc("يُعرف أيضاً باسم: "+strings.Join(brand.Aliases, "، ")+".") + "</p>\n")
	}

	if len(brand.Items) > 0 {
		countries := false
		for _, item := range brand.Items {
			countries = countries || item.Country != brand.Items[0].Country
		}
		out.WriteString("<h2>" + esc("فئات "+brand.Name+" وأسعارها") + "</h2>\n<table>\n<thead><tr><th>الفئة</th>")
		if countries {
			out.WriteString("<th>الدولة</th>")
		}
		out.WriteString("<th>السعر</th><th>التوفر</th></tr></thead>\n<tbody>\n")
		for _, item := range brand.Items {
			out.WriteString("<tr><td>")
			if item.Available {
				out.WriteString(link(itemPath(key, item.Key), item.Label))
			} else {
				out.WriteString(esc(item.Label))
			}
			out.WriteString("</td>")
			if countries {
				name := p.shelf.Countries[item.Country]
				if name == "" {
					name = item.Country
				}
				out.WriteString("<td>" + esc(name) + "</td>")
			}
			out.WriteString("<td>" + esc(money(item.Price, currency)) + "</td><td>")
			if item.Available {
				out.WriteString("متوفر")
			} else {
				out.WriteString("غير متوفر حالياً")
			}
			out.WriteString("</td></tr>\n")
		}
		out.WriteString("</tbody>\n</table>\n")
	}
	if hint := strings.TrimSpace(brand.RedeemHint); hint != "" {
		out.WriteString("<h2>طريقة الاستخدام</h2>\n<p>" + esc(hint) + "</p>\n")
	}
	others := []string{}
	for _, other := range p.brandsIn(brand.Category) {
		if other != key && len(others) < 24 {
			others = append(others, other)
		}
	}
	if name := p.shelf.Categories[brand.Category]; name != "" && len(others) > 0 {
		out.WriteString("<h2>" + esc("المزيد من "+name) + "</h2>\n" + p.brandList(others))
	}
	return p.frame(crumbs, out.String())
}

// documents are the app's own pages of words.
var documents = map[string]struct{ title, description, file string }{
	"privacy": {"سياسة الخصوصية", "ما يجمعه تطبيق " + siteName + " من بيانات، ولماذا، وكيف تتحكم فيها.", "privacy"},
	"terms":   {"شروط الاستخدام", "شروط استخدام تطبيق " + siteName + " وشراء الكروت منه.", "terms"},
	"about":   {"عن " + siteName, homeDescription, ""},
}

func (p pages) document(name string) webPage {
	doc := documents[name]
	page := p.plain()
	page.canonical = "/" + name
	page.title = doc.title + " | " + siteName
	if name == "about" {
		page.title = doc.title
	}
	page.description = doc.description
	crumbs := []crumb{{"الرئيسية", "/"}, {doc.title, page.canonical}}
	page.schema = []map[string]any{p.breadcrumbs(crumbs)}
	body := "<p>" + esc(homeDescription) + "</p>\n"
	if doc.file != "" {
		// The text the app itself shows (cards/assets/legal), from the build.
		if text, err := fs.ReadFile(p.h.files, "assets/assets/legal/"+doc.file+".ar.md"); err == nil {
			body = legalHTML(string(text))
		}
	}
	page.content = p.frame(crumbs, "<h1>"+esc(doc.title)+"</h1>\n"+body)
	return page
}

// legalHTML renders the legal texts' own small format: "## " headings, "- "
// items, and paragraphs.
func legalHTML(text string) string {
	var out strings.Builder
	list := false
	closeList := func() {
		if list {
			out.WriteString("</ul>\n")
			list = false
		}
	}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case line == "":
			closeList()
		case strings.HasPrefix(line, "## "):
			closeList()
			out.WriteString("<h2>" + esc(strings.TrimPrefix(line, "## ")) + "</h2>\n")
		case strings.HasPrefix(line, "- "):
			if !list {
				out.WriteString("<ul>\n")
				list = true
			}
			out.WriteString("<li>" + esc(strings.TrimPrefix(line, "- ")) + "</li>\n")
		default:
			closeList()
			out.WriteString("<p>" + esc(line) + "</p>\n")
		}
	}
	closeList()
	return out.String()
}
