package cardsweb

import (
	"encoding/xml"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// robots.txt and sitemap.xml: where a search engine starts. The map lists
// every page worth finding (the shelf, each category, each brand with its
// picture, each card on sale, the legal pages), read from the catalog as it
// is at that moment, so a new brand is found without anyone telling Google.

// serveRobots lets every page be read (a page that should not be listed says
// so itself, which a crawler must be allowed in to see) and keeps crawlers
// off campaign links, which only count and redirect.
func (h *Handler) serveRobots(w http.ResponseWriter, r *http.Request) {
	body := "User-agent: *\nAllow: /\nDisallow: /" + campaignPrefix + "\n\nSitemap: " + h.origin + "/sitemap.xml\n"
	header := w.Header()
	header.Set("Content-Type", "text/plain; charset=utf-8")
	header.Set("Cache-Control", "public, max-age=3600")
	header.Set("Content-Length", strconv.Itoa(len(body)))
	if r.Method != http.MethodHead {
		_, _ = w.Write([]byte(body))
	}
}

// serveSitemap lists the pages. While the catalog cannot be read it asks the
// crawler to come back, rather than hand it a map with the brands gone.
func (h *Handler) serveSitemap(w http.ResponseWriter, r *http.Request) {
	p := h.pages(r)
	header := w.Header()
	if h.previews.source != nil && !p.read {
		header.Set("Retry-After", "600")
		header.Set("Cache-Control", "no-store")
		http.Error(w, "the catalog is not readable right now", http.StatusServiceUnavailable)
		return
	}
	var out strings.Builder
	out.WriteString(xml.Header)
	out.WriteString(`<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">` + "\n")
	add := func(path, picture string) {
		out.WriteString("<url><loc>" + xmlText(h.origin+path) + "</loc>")
		if picture != "" {
			out.WriteString("<image:image><image:loc>" + xmlText(h.origin+"/"+picture) + "</image:loc></image:image>")
		}
		out.WriteString("</url>\n")
	}
	add("/", "")
	for _, key := range p.categories() {
		add(categoryPath(key), "")
	}
	brands := p.brandsIn("")
	for _, key := range brands {
		// The picture's address, not the picture: nothing is drawn here.
		p.h.previews.mu.Lock()
		id := p.h.previews.brandLocked(key, p.shelf.Brands[key]).id
		p.h.previews.mu.Unlock()
		add(brandPath(key), "og/brand/"+url.PathEscape(key)+"."+id+".jpg")
	}
	for _, key := range brands {
		for _, item := range p.shelf.Brands[key].Items {
			if item.Available {
				add(itemPath(key, item.Key), "")
			}
		}
	}
	// The eSIM shelf and its destinations, while they are on sale to everyone.
	if keys := p.esimKeys(); len(keys) > 0 {
		add("/esim", p.h.previews.esimPicture(""))
		for _, key := range keys {
			add(esimPath(key), p.h.previews.esimPicture(p.shelf.ESIMs[key].Country))
		}
	}
	for _, name := range []string{"about", "privacy", "terms"} {
		add("/"+name, "")
	}
	out.WriteString("</urlset>\n")

	header.Set("Content-Type", "application/xml; charset=utf-8")
	header.Set("Cache-Control", "public, max-age=900")
	h.sendText(w, r, []byte(out.String()))
}

func xmlText(text string) string {
	var out strings.Builder
	_ = xml.EscapeText(&out, []byte(text))
	return out.String()
}
