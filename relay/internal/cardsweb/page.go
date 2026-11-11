package cardsweb

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"html"
	"net/http"
	"regexp"
	"strconv"
	"strings"
)

// A page of the app is index.html with its own head: the title, words and
// picture a messaging app shows for its link, and what a search engine lists
// it by (seo.go).

const (
	siteName        = "دفتر كروت"
	siteDescription = "كروت الاتصالات والإنترنت والألعاب، تصلك فوراً"
)

var (
	titleTag       = regexp.MustCompile(`(?s)<title>.*?</title>`)
	descriptionTag = regexp.MustCompile(`<meta name="description"[^>]*>\s*`)
	bodyTag        = regexp.MustCompile(`<body[^>]*>`)
)

// servePage sends index.html as the page at name: its words in the head,
// its content under the app (seo.go, static.go).
func (h *Handler) servePage(w http.ResponseWriter, r *http.Request, name string) {
	page := h.pageFor(r, name)
	header := w.Header()
	header.Set("Content-Type", "text/html; charset=utf-8")
	if page.noindex {
		header.Set("X-Robots-Tag", "noindex")
	}
	h.send(w, r, page.status, h.page(page))
}

// sendText sends body, compressed for a browser that takes it and not at
// all to one that already has it.
func (h *Handler) sendText(w http.ResponseWriter, r *http.Request, body []byte) {
	h.send(w, r, http.StatusOK, body)
}

func (h *Handler) send(w http.ResponseWriter, r *http.Request, status int, body []byte) {
	header := w.Header()
	header.Add("Vary", "Accept-Encoding")
	sum := sha256.Sum256(body)
	etag := hex.EncodeToString(sum[:8])
	gzipped := accepts(r.Header.Get("Accept-Encoding"), "gzip")
	if gzipped {
		etag += "-gz"
	}
	etag = `"` + etag + `"`
	header.Set("ETag", etag)
	if status == http.StatusOK && strings.TrimSpace(r.Header.Get("If-None-Match")) == etag {
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
	w.WriteHeader(status)
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write(body)
}

// page is index.html with the page's own head in place of its title and
// description, and the page's content first in its body.
func (h *Handler) page(page webPage) []byte {
	attr := html.EscapeString
	shareTitle := page.shareTitle
	if shareTitle == "" {
		shareTitle = page.title
	}
	pageURL := h.origin + page.canonical
	var head strings.Builder
	head.WriteString("<title>" + attr(page.title) + "</title>\n")
	for _, meta := range [][2]string{
		{"name", "description"}, {"property", "og:description"},
	} {
		head.WriteString(`  <meta ` + meta[0] + `="` + meta[1] + `" content="` + attr(page.description) + "\">\n")
	}
	if page.noindex {
		head.WriteString(`  <meta name="robots" content="noindex">` + "\n")
	} else {
		head.WriteString(`  <meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1">` + "\n")
	}
	if page.canonical != "" {
		head.WriteString(`  <link rel="canonical" href="` + attr(pageURL) + "\">\n")
	}
	kind := "website"
	if page.offer != nil {
		kind = "product"
	}
	properties := [][2]string{
		{"og:title", shareTitle},
		{"og:site_name", siteName},
		{"og:type", kind},
		{"og:locale", "ar_LY"},
	}
	if page.canonical != "" {
		properties = append(properties, [2]string{"og:url", pageURL})
	}
	properties = append(properties, [][2]string{
		{"og:image", h.origin + "/" + page.picture},
		{"og:image:type", "image/jpeg"},
		{"og:image:width", strconv.Itoa(bannerWidth)},
		{"og:image:height", strconv.Itoa(bannerHeight)},
		{"og:image:alt", shareTitle},
	}...)
	if page.offer != nil && page.offer.price != "" {
		availability := "out of stock"
		if page.offer.available {
			availability = "in stock"
		}
		properties = append(properties, [][2]string{
			{"product:price:amount", page.offer.price},
			{"product:price:currency", page.offer.currency},
			{"product:availability", availability},
		}...)
	}
	for _, property := range properties {
		head.WriteString(`  <meta property="` + property[0] + `" content="` + attr(property[1]) + "\">\n")
	}
	head.WriteString(`  <meta name="twitter:card" content="summary_large_image">`)
	if len(page.schema) > 0 {
		// json.Marshal writes <, > and & as \u escapes, so the data cannot
		// close its own script element.
		if data, err := json.Marshal(map[string]any{"@context": "https://schema.org", "@graph": page.schema}); err == nil {
			head.WriteString("\n  <script type=\"application/ld+json\">" + string(data) + "</script>")
		}
	}
	if page.content != "" {
		head.WriteString("\n" + strings.TrimRight(staticHead, "\n"))
	}

	index := descriptionTag.ReplaceAll(h.index, nil)
	out := make([]byte, 0, len(index)+head.Len()+len(page.content))
	if at := titleTag.FindIndex(index); at != nil {
		out = append(out, index[:at[0]]...)
		out = append(out, head.String()...)
		out = append(out, index[at[1]:]...)
	} else {
		out = append(append(out, head.String()...), '\n')
		out = append(out, index...)
	}
	if page.content == "" {
		return out
	}
	if at := bodyTag.FindIndex(out); at != nil {
		rest := append([]byte(nil), out[at[1]:]...)
		out = append(append(out[:at[1]], "\n"+page.content...), rest...)
		return out
	}
	return append(out, "\n"+page.content...)
}

// servePicture answers og/site.<id>.jpg, og/brand/<key>.<id>.jpg and
// og/esim/<country>.<id>.jpg; a
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
	case strings.HasPrefix(which, "esim/"):
		// A flag's own picture, whatever the shelf holds today.
		b = h.previews.esimBanner(strings.TrimPrefix(which, "esim/"))
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
