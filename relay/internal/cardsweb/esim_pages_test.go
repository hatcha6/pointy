package cardsweb

import (
	"bytes"
	"image"
	"net/http"
	"os"
	"strings"
	"testing"
)

// travelling is the stocked shelf with eSIMs on sale: Turkey on a promotion,
// and a region.
func travelling() *fakeShelf {
	shelf := stocked()
	shelf.catalog.ESIMs = map[string]PreviewESIM{
		"turkey": {
			Name: "تركيا", Kind: "local", Country: "TR", Countries: 1, PromoBadge: "خصم 20%",
			Plans: []PreviewESIMPlan{
				{ID: "ea.PTR1G7", Data: "1 GB", Days: 7, Price: "8.000"},
				{ID: "ea.PTR5G30", Data: "5 GB", Days: 30, Price: "27.500"},
			},
		},
		"europe": {
			Name: "أوروبا", Kind: "regional", Countries: 33,
			Plans: []PreviewESIMPlan{{ID: "ea.EU1", Data: "3 GB", Days: 15, Price: "40.000"}},
		},
	}
	shelf.catalog.ESIMOrder = []string{"turkey", "europe"}
	return shelf
}

// A destination's link shows its name, its lowest price and its own picture,
// in every chat app: the page's og: tags say them and the picture is served.
func TestAnESIMLinkPreviewsItsDestination(t *testing.T) {
	h := seoHandler(t, travelling())
	got := get(h, http.MethodGet, "cards.dftr.ly", "/esim/turkey")
	page := got.Body.String()
	if got.Code != http.StatusOK || got.Header().Get("X-Robots-Tag") != "" {
		t.Fatalf("%d, robots %q", got.Code, got.Header().Get("X-Robots-Tag"))
	}
	mustContain(t, page,
		`<meta property="og:title" content="شريحة eSIM تركيا · من 8 د.ل · خصم 20%">`,
		`<link rel="canonical" href="https://cards.dftr.ly/esim/turkey">`,
		`<meta property="og:url" content="https://cards.dftr.ly/esim/turkey">`,
		`<meta property="og:type" content="product">`,
		`<meta property="og:image:width" content="1200">`,
		`<meta property="product:price:amount" content="8.000">`,
		`<meta name="twitter:card" content="summary_large_image">`,
		`id="splash"`,
	)
	picture := pictureOf(t, page)
	if !strings.HasPrefix(picture, "/og/esim/tr.") {
		t.Fatalf("picture address: %s", picture)
	}
	image := get(h, http.MethodGet, "cards.dftr.ly", picture)
	if image.Code != http.StatusOK || image.Header().Get("Content-Type") != "image/jpeg" || image.Body.Len() < 10_000 {
		t.Fatalf("picture: %d %s %d bytes", image.Code, image.Header().Get("Content-Type"), image.Body.Len())
	}
	offers := schemaOf(t, page)["Product"]["offers"].(map[string]any)
	if offers["@type"] != "AggregateOffer" || offers["lowPrice"] != "8.000" || offers["highPrice"] != "27.500" {
		t.Fatalf("offers: %v", offers)
	}

	// A region keeps the globe; the shelf has its own words.
	region := get(h, http.MethodGet, "cards.dftr.ly", "/esim/europe").Body.String()
	mustContain(t, region, `og:title" content="شريحة eSIM أوروبا · من 40 د.ل"`, "33 دولة")
	if !strings.HasPrefix(pictureOf(t, region), "/og/esim/world.") {
		t.Fatalf("a region's picture: %s", pictureOf(t, region))
	}
	shelfPage := get(h, http.MethodGet, "cards.dftr.ly", "/esim?days=30&offers=1").Body.String()
	mustContain(t, shelfPage, `og:title" content="شرائح eSIM للسفر"`, `rel="canonical" href="https://cards.dftr.ly/esim"`, "تبدأ من 8 د.ل")
}

// A plan's link names the plan and its price; an unknown plan is its
// destination, an unknown destination is missing.
func TestAnESIMPlanHasItsOwnPreview(t *testing.T) {
	h := seoHandler(t, travelling())
	page := get(h, http.MethodGet, "cards.dftr.ly", "/esim/turkey/ea.PTR5G30").Body.String()
	mustContain(t, page,
		`og:title" content="شريحة eSIM تركيا · 5 GB · 30 يوماً · 27.5 د.ل · خصم 20%"`,
		`rel="canonical" href="https://cards.dftr.ly/esim/turkey/ea.PTR5G30"`,
		`product:price:amount" content="27.500"`,
	)
	if offer := schemaOf(t, page)["Product"]["offers"].(map[string]any); offer["@type"] != "Offer" || offer["price"] != "27.500" {
		t.Fatalf("offer: %v", offer)
	}
	unknown := get(h, http.MethodGet, "cards.dftr.ly", "/esim/turkey/nope").Body.String()
	mustContain(t, unknown, `rel="canonical" href="https://cards.dftr.ly/esim/turkey"`)
	if got := get(h, http.MethodGet, "cards.dftr.ly", "/esim/atlantis"); got.Code != http.StatusNotFound {
		t.Fatalf("an unknown destination: %d", got.Code)
	}
}

// While eSIMs are not on sale to everyone their addresses stay unlisted and
// out of the map; on sale, the map names them with their pictures.
func TestESIMPagesAreListedOnlyWhileOnSale(t *testing.T) {
	closed := seoHandler(t, stocked())
	if got := get(closed, http.MethodGet, "cards.dftr.ly", "/esim/turkey"); got.Header().Get("X-Robots-Tag") != "noindex" {
		t.Fatalf("a shelf not on sale is listed: %v", got.Header())
	}
	if strings.Contains(get(closed, http.MethodGet, "cards.dftr.ly", "/sitemap.xml").Body.String(), "/esim") {
		t.Fatal("the map names eSIMs that are not on sale")
	}
	open := seoHandler(t, travelling())
	sitemap := get(open, http.MethodGet, "cards.dftr.ly", "/sitemap.xml").Body.String()
	mustContain(t, sitemap, "<loc>https://cards.dftr.ly/esim</loc>", "<loc>https://cards.dftr.ly/esim/turkey</loc>", "/og/esim/tr.", "/og/esim/world.")
}

func TestTheESIMPictureCarriesTheFlag(t *testing.T) {
	flagged, err := renderESIMBanner("TR")
	if err != nil {
		t.Fatal(err)
	}
	plain, err := renderESIMBanner("")
	if err != nil {
		t.Fatal(err)
	}
	decoded, _, err := image.Decode(bytes.NewReader(flagged))
	if err != nil || decoded.Bounds().Dx() != bannerWidth || decoded.Bounds().Dy() != bannerHeight {
		t.Fatalf("picture: %v %v", decoded.Bounds(), err)
	}
	// Turkey's red where the flag sits, not the card's teal.
	r, g, b, _ := decoded.At((bannerWidth-cardWidth)/2+60, bannerHeight/2-150).RGBA()
	if r>>8 < 180 || g>>8 > 90 || b>>8 > 90 {
		t.Fatalf("no flag on the card: %d %d %d", r>>8, g>>8, b>>8)
	}
	if bytes.Equal(flagged, plain) || esimFlag("zz") != nil || esimFlag("../x") != nil {
		t.Fatal("a region or an unknown code must keep the globe")
	}
	if dir := os.Getenv("CARDSWEB_WRITE_PICTURES"); dir != "" {
		_ = os.WriteFile(dir+"/esim_tr.jpg", flagged, 0o644)
		_ = os.WriteFile(dir+"/esim_world.jpg", plain, 0o644)
	}
}
