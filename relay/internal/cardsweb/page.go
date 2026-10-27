package cardsweb

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"html"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// A page of the app is index.html with its own og: tags: the title, words
// and picture a messaging app shows for its link.

const (
	siteName        = "دفتر كروت"
	siteDescription = "كروت الاتصالات والإنترنت والألعاب، تصلك فوراً"
)

var (
	titleTag       = regexp.MustCompile(`(?s)<title>.*?</title>`)
	descriptionTag = regexp.MustCompile(`<meta name="description"[^>]*>\s*`)
)

// pageTags is what a page's link preview says.
type pageTags struct {
	title, description string
	// picture is the image's path ("og/site.<id>.jpg").
	picture string
}

// tagsFor is the preview of the page at name ("brand/libyana").
func (h *Handler) tagsFor(r *http.Request, name string) pageTags {
	site := pageTags{
		title:       siteName,
		description: siteDescription,
		picture:     "og/site." + h.previews.site().id + ".jpg",
	}
	section, key, _ := strings.Cut(name, "/")
	key, _, _ = strings.Cut(key, "/")
	if key == "" || (section != "brand" && section != "category") {
		return site
	}
	shelf, ok := h.previews.shelf(r.Context())
	if !ok {
		return site
	}
	if section == "category" {
		if category, ok := shelf.Categories[key]; ok {
			site.title = category + " | " + siteName
			site.description = "كروت " + category + " من " + siteName + "، تصلك فوراً."
		}
		return site
	}
	brand, ok := shelf.Brands[key]
	if !ok {
		return site
	}
	b := h.previews.brandBanner(key, brand)
	return pageTags{
		title:       "كروت " + brand.Name + " | " + siteName,
		description: "اشترِ كروت " + brand.Name + " من " + siteName + "، ويصلك الرمز فوراً.",
		picture:     "og/brand/" + url.PathEscape(key) + "." + b.id + ".jpg",
	}
}

// servePage sends index.html carrying the page's preview.
func (h *Handler) servePage(w http.ResponseWriter, r *http.Request, name string) {
	tags := h.tagsFor(r, name)
	origin := "https://" + hostOf(r.Host)
	body := h.page(tags, origin+"/"+name, origin+"/"+tags.picture)

	header := w.Header()
	header.Add("Vary", "Accept-Encoding")
	header.Set("Content-Type", "text/html; charset=utf-8")
	sum := sha256.Sum256(body)
	etag := hex.EncodeToString(sum[:8])
	gzipped := accepts(r.Header.Get("Accept-Encoding"), "gzip")
	if gzipped {
		etag += "-gz"
	}
	etag = `"` + etag + `"`
	header.Set("ETag", etag)
	if strings.TrimSpace(r.Header.Get("If-None-Match")) == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	if gzipped {
		var packed bytes.Buffer
		zw, _ := gzip.NewWriterLevel(&packed, gzip.BestCompression)
		_, _ = zw.Write(body)
		_ = zw.Close()
		body = packed.Bytes()
		header.Set("Content-Encoding", "gzip")
	}
	header.Set("Content-Length", strconv.Itoa(len(body)))
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write(body)
}

// page is index.html with tags in place of its own title and description.
func (h *Handler) page(tags pageTags, pageURL, pictureURL string) []byte {
	attr := html.EscapeString
	var head strings.Builder
	head.WriteString("<title>" + attr(tags.title) + "</title>\n")
	for _, meta := range [][2]string{
		{"name", "description"}, {"property", "og:description"},
	} {
		head.WriteString(`  <meta ` + meta[0] + `="` + meta[1] + `" content="` + attr(tags.description) + "\">\n")
	}
	for _, property := range [][2]string{
		{"og:title", tags.title},
		{"og:site_name", siteName},
		{"og:type", "website"},
		{"og:locale", "ar_LY"},
		{"og:url", pageURL},
		{"og:image", pictureURL},
		{"og:image:type", "image/jpeg"},
		{"og:image:width", strconv.Itoa(bannerWidth)},
		{"og:image:height", strconv.Itoa(bannerHeight)},
		{"og:image:alt", tags.title},
	} {
		head.WriteString(`  <meta property="` + property[0] + `" content="` + attr(property[1]) + "\">\n")
	}
	head.WriteString(`  <meta name="twitter:card" content="summary_large_image">`)

	page := descriptionTag.ReplaceAll(h.index, nil)
	at := titleTag.FindIndex(page)
	if at == nil {
		return append(append([]byte(head.String()), '\n'), page...)
	}
	out := make([]byte, 0, len(page)+head.Len())
	out = append(out, page[:at[0]]...)
	out = append(out, head.String()...)
	return append(out, page[at[1]:]...)
}

// servePicture answers og/site.<id>.jpg and og/brand/<key>.<id>.jpg; a
// picture asked for by an address it no longer has gets today's, briefly
// cached.
func (h *Handler) servePicture(w http.ResponseWriter, r *http.Request, name string) {
	rest, ok := strings.CutSuffix(strings.TrimPrefix(name, "og/"), ".jpg")
	dot := strings.LastIndexByte(rest, '.')
	if !ok || dot < 0 {
		http.NotFound(w, r)
		return
	}
	which, id := rest[:dot], rest[dot+1:]
	var b *banner
	switch {
	case which == "site":
		b = h.previews.site()
	case strings.HasPrefix(which, "brand/"):
		// Unknown today (or the catalog unreadable): the shelf's picture.
		key := strings.TrimPrefix(which, "brand/")
		shelf, _ := h.previews.shelf(r.Context())
		if brand, ok := shelf.Brands[key]; ok {
			b = h.previews.brandBanner(key, brand)
		}
	default:
		http.NotFound(w, r)
		return
	}
	picture, own := h.previews.picture(r.Context(), b)
	header := w.Header()
	if !own || id != b.id {
		header.Set("Cache-Control", "public, max-age=300")
	}
	header.Set("Content-Type", "image/jpeg")
	header.Set("Content-Length", strconv.Itoa(len(picture)))
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write(picture)
}
