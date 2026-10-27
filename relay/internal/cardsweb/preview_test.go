package cardsweb

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeShelf struct {
	mu      sync.Mutex
	catalog PreviewCatalog
	err     error
	art     map[string][]byte
	asked   map[string]int
}

func (f *fakeShelf) PreviewCatalog(context.Context) (PreviewCatalog, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.catalog, f.err
}

func (f *fakeShelf) PreviewArt(_ context.Context, ref string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked[ref]++
	if data, ok := f.art[ref]; ok {
		return data, nil
	}
	return nil, errors.New("no such image")
}

// cardArt is an 800×500 PNG in one colour, as the catalog's art is shaped.
func cardArt(t testing.TB, fill color.RGBA) []byte {
	t.Helper()
	art := image.NewRGBA(image.Rect(0, 0, 800, 500))
	for i := 0; i < len(art.Pix); i += 4 {
		art.Pix[i], art.Pix[i+1], art.Pix[i+2], art.Pix[i+3] = fill.R, fill.G, fill.B, 255
	}
	var out bytes.Buffer
	if err := png.Encode(&out, art); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func shelf(t *testing.T) *fakeShelf {
	return &fakeShelf{
		catalog: PreviewCatalog{
			Brands: map[string]PreviewBrand{
				"libyana": {Name: "ليبيانا", Category: "telecom", Art: "sha256:libyana"},
				"pubg":    {Name: `ببجي "موبايل" <x>`, Category: "gaming"},
				"broken":  {Name: "مكسور", Category: "tv", Art: "sha256:missing"},
			},
			Categories: map[string]string{"gaming": "الألعاب"},
		},
		art:   map[string][]byte{"sha256:libyana": cardArt(t, color.RGBA{0x8e, 0x2a, 0x9c, 255})},
		asked: map[string]int{},
	}
}

func previewHandler(t *testing.T, source Source) *Handler {
	t.Helper()
	h, err := Wrap(http.NotFoundHandler(), Config{Hosts: []string{"cards.dftr.ly"}, Files: build(), Previews: source})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

// drawn waits for the catalog's first reading and every picture it started.
func drawn(t *testing.T, h *Handler) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		h.previews.mu.Lock()
		read := !h.previews.readAt.IsZero() || !h.previews.retryAt.IsZero()
		reading := h.previews.refreshing
		pending := []*banner{}
		for _, b := range h.previews.banners {
			pending = append(pending, b)
		}
		h.previews.mu.Unlock()
		if reading != nil {
			<-reading
			continue
		}
		if !read && time.Now().Before(deadline) {
			time.Sleep(5 * time.Millisecond)
			continue
		}
		for _, b := range pending {
			<-b.done
		}
		return
	}
}

var ogImage = regexp.MustCompile(`<meta property="og:image" content="https://cards\.dftr\.ly/([^"]+)">`)

func pictureOf(t *testing.T, page string) string {
	t.Helper()
	match := ogImage.FindStringSubmatch(page)
	if match == nil {
		t.Fatalf("no og:image in %q", page)
	}
	return "/" + match[1]
}

func TestEveryBrandIsDrawnBeforeAnyoneAsks(t *testing.T) {
	source := shelf(t)
	h := previewHandler(t, source)
	drawn(t, h)
	source.mu.Lock()
	defer source.mu.Unlock()
	if source.asked["sha256:libyana"] != 1 || source.asked["sha256:missing"] != 1 {
		t.Fatalf("art read %v", source.asked)
	}
	h.previews.mu.Lock()
	defer h.previews.mu.Unlock()
	if b := h.previews.banners["libyana"]; b == nil || len(b.jpeg) == 0 {
		t.Fatal("libyana was not drawn ahead")
	}
	if b := h.previews.banners["pubg"]; b == nil || len(b.jpeg) == 0 {
		t.Fatal("a brand without art was not drawn in its colours")
	}
}

func TestABrandLinkPreviewsTheBrand(t *testing.T) {
	h := previewHandler(t, shelf(t))
	drawn(t, h)
	page := get(h, http.MethodGet, "cards.dftr.ly", "/brand/libyana?item=x").Body.String()
	for _, want := range []string{
		"<title>كروت ليبيانا | دفتر كروت</title>",
		`<meta property="og:title" content="كروت ليبيانا | دفتر كروت">`,
		`<meta name="description" content="اشترِ كروت ليبيانا من دفتر كروت، ويصلك الرمز فوراً.">`,
		`<meta property="og:url" content="https://cards.dftr.ly/brand/libyana">`,
		`<meta name="twitter:card" content="summary_large_image">`,
	} {
		if !strings.Contains(page, want) {
			t.Fatalf("missing %s in %s", want, page)
		}
	}
	if strings.Count(page, "<title>") != 1 {
		t.Fatalf("titles: %s", page)
	}

	picture := get(h, http.MethodGet, "cards.dftr.ly", pictureOf(t, page))
	if picture.Code != http.StatusOK || picture.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("picture: %d %q", picture.Code, picture.Header().Get("Content-Type"))
	}
	if cache := picture.Header().Get("Cache-Control"); !strings.Contains(cache, "immutable") {
		t.Fatalf("picture cache %q", cache)
	}
	config, err := jpeg.DecodeConfig(picture.Body)
	if err != nil || config.Width != 1200 || config.Height != 630 {
		t.Fatalf("picture %dx%d: %v", config.Width, config.Height, err)
	}
}

func TestANameIsWrittenSafelyIntoThePage(t *testing.T) {
	h := previewHandler(t, shelf(t))
	drawn(t, h)
	page := get(h, http.MethodGet, "cards.dftr.ly", "/brand/pubg").Body.String()
	if strings.Contains(page, "<x>") || !strings.Contains(page, "&#34;موبايل&#34; &lt;x&gt;") {
		t.Fatalf("name not escaped: %s", page)
	}
}

func TestOtherPagesPreviewTheShelf(t *testing.T) {
	h := previewHandler(t, shelf(t))
	drawn(t, h)
	for target, title := range map[string]string{
		"/":                "دفتر كروت",
		"/brand/unknown":   "دفتر كروت",
		"/my-cards":        "دفتر كروت",
		"/category/gaming": "الألعاب | دفتر كروت",
		"/category/nope":   "دفتر كروت",
	} {
		page := get(h, http.MethodGet, "cards.dftr.ly", target).Body.String()
		if !strings.Contains(page, `<meta property="og:title" content="`+title+`">`) {
			t.Fatalf("%s: %s", target, page)
		}
		if !strings.HasPrefix(pictureOf(t, page), "/og/site.") {
			t.Fatalf("%s picture %s", target, pictureOf(t, page))
		}
	}
	site := get(h, http.MethodGet, "cards.dftr.ly", pictureOf(t, get(h, http.MethodGet, "cards.dftr.ly", "/").Body.String()))
	if site.Code != http.StatusOK || site.Body.Len() == 0 {
		t.Fatalf("site picture: %d", site.Code)
	}
}

func TestArtThatCannotBeReadStandsInWithTheShelfPicture(t *testing.T) {
	h := previewHandler(t, shelf(t))
	drawn(t, h)
	page := get(h, http.MethodGet, "cards.dftr.ly", "/brand/broken").Body.String()
	picture := get(h, http.MethodGet, "cards.dftr.ly", pictureOf(t, page))
	if picture.Code != http.StatusOK || picture.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("picture: %d", picture.Code)
	}
	if cache := picture.Header().Get("Cache-Control"); cache != "public, max-age=300" {
		t.Fatalf("a stand-in was cached as %q", cache)
	}
}

func TestNewArtIsANewAddress(t *testing.T) {
	source := shelf(t)
	h := previewHandler(t, source)
	drawn(t, h)
	before := pictureOf(t, get(h, http.MethodGet, "cards.dftr.ly", "/brand/libyana").Body.String())

	source.mu.Lock()
	source.art["sha256:libyana2"] = cardArt(t, color.RGBA{0xe0, 0x1b, 0x24, 255})
	source.catalog.Brands["libyana"] = PreviewBrand{Name: "ليبيانا", Category: "telecom", Art: "sha256:libyana2"}
	source.mu.Unlock()
	h.previews.mu.Lock()
	h.previews.readAt = time.Now().Add(-2 * catalogFresh)
	h.previews.mu.Unlock()
	get(h, http.MethodGet, "cards.dftr.ly", "/") // answered from the old reading, starts a new one
	drawn(t, h)

	after := pictureOf(t, get(h, http.MethodGet, "cards.dftr.ly", "/brand/libyana").Body.String())
	if after == before {
		t.Fatal("new art kept the old address")
	}
	// The old address still answers, with today's picture, briefly cached.
	old := get(h, http.MethodGet, "cards.dftr.ly", before)
	if old.Code != http.StatusOK || old.Header().Get("Cache-Control") != "public, max-age=300" {
		t.Fatalf("old address: %d %q", old.Code, old.Header().Get("Cache-Control"))
	}
}

func TestAnUnreadableCatalogNeverHoldsAPageUp(t *testing.T) {
	source := shelf(t)
	source.err = errors.New("database down")
	h := previewHandler(t, source)
	drawn(t, h)
	started := time.Now()
	page := get(h, http.MethodGet, "cards.dftr.ly", "/brand/libyana")
	if took := time.Since(started); took > 200*time.Millisecond {
		t.Fatalf("page waited %v", took)
	}
	if page.Code != http.StatusOK || !strings.Contains(page.Body.String(), `content="دفتر كروت"`) {
		t.Fatalf("page: %d %s", page.Code, page.Body.String())
	}
}

func TestARevisitIsNotModified(t *testing.T) {
	h := previewHandler(t, shelf(t))
	drawn(t, h)
	first := getAccepting(h, "/brand/libyana", "gzip")
	request := httptest.NewRequest(http.MethodGet, "http://cards.dftr.ly/brand/libyana", nil)
	request.Header.Set("Accept-Encoding", "gzip")
	request.Header.Set("If-None-Match", first.Header().Get("ETag"))
	again := httptest.NewRecorder()
	h.ServeHTTP(again, request)
	if again.Code != http.StatusNotModified {
		t.Fatalf("revisit: %d", again.Code)
	}
}

// BenchmarkBrandBanner is one brand's picture drawn from its art: the cost
// paid ahead for each brand, never while a messaging app waits.
func BenchmarkBrandBanner(b *testing.B) {
	art, _, err := image.Decode(bytes.NewReader(cardArt(b, color.RGBA{0x8e, 0x2a, 0x9c, 255})))
	if err != nil {
		b.Fatal(err)
	}
	for b.Loop() {
		if _, err := renderBrandBanner(art, "telecom"); err != nil {
			b.Fatal(err)
		}
	}
}
