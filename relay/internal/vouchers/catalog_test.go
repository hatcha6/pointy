package vouchers

import (
	"encoding/json"
	"math/big"
	"strings"
	"testing"
	"time"
)

var (
	logoDisplay = "sha256:" + strings.Repeat("a", 64)
	logoPrint   = "sha256:" + strings.Repeat("b", 64)
	flagUS      = "sha256:" + strings.Repeat("c", 64)
)

func sampleDocument() Document {
	raw := `{
  "categories": [
    {"key": "telecom", "name": "اتصالات", "sort": 30},
    {"key": "gift_cards", "name": "بطاقات الهدايا", "sort": 10},
    {"key": "empty", "name": "فارغة", "sort": 5}
  ],
  "countries": [
    {"code": "us", "flag": "` + flagUS + `"},
    {"code": "GB", "name": "بريطانيا"},
    {"code": "WW"}
  ],
  "brands": [
    {
      "key": "libyana", "name": "ليبيانا", "category": "telecom", "sort": 1,
      "logo": {},
      "items": [
        {"key": "libyana-10", "face_value": "10", "face_currency": "LYD", "price": "9.7", "retail_price": "10",
         "supplier": {"key": "bnplus", "card_id": 12}}
      ]
    },
    {
      "key": "itunes", "name": "آيتونز", "aliases": [" iTunes "], "category": "gift_cards", "sort": 50,
      "featured": true, "badge": "الأكثر مبيعاً",
      "logo": {"display": "` + logoDisplay + `", "print": "` + logoPrint + `"},
      "items": [
        {"key": "itunes-us-100", "country": "US", "face_value": "100", "face_currency": "usd",
         "price": "520.00", "retail_price": "560.00", "supplier": {"key": "bnplus", "card_id": 3}},
        {"key": "itunes-gb-10", "country": "GB", "face_value": "10", "face_currency": "GBP",
         "price": "68", "retail_price": "78", "supplier": {"key": "bnplus", "card_id": 4}},
        {"key": "itunes-us-10", "country": "US", "face_value": "10.00", "face_currency": "USD",
         "price": "52.00", "retail_price": "60.00",
         "promo": {"price": "50.00", "badge": "ربح أكبر",
                   "starts_at": "2026-10-10T00:00:00+02:00", "ends_at": "2026-10-20T00:00:00+02:00"},
         "supplier": {"key": "bnplus", "card_id": 1, "max_cost": "10.30"}},
        {"key": "itunes-us-25", "country": "US", "face_value": "25", "face_currency": "USD",
         "price": "130.00", "retail_price": "145.00", "supplier": {"key": "bnplus", "card_id": 2}},
        {"key": "itunes-us-50", "country": "US", "face_value": "50", "face_currency": "USD", "active": false,
         "price": "260.00", "retail_price": "285.00", "supplier": {"key": "bnplus", "card_id": 5}}
      ]
    },
    {
      "key": "steam", "name": "ستيم", "category": "gift_cards", "sort": 10, "active": false,
      "logo": {},
      "items": [
        {"key": "steam-ww-20", "country": "WW", "label": "20 دولار", "price": "100", "retail_price": "110",
         "supplier": {"key": "bnplus", "card_id": 9}}
      ]
    }
  ]
}`
	document, err := ParseDocument([]byte(raw))
	if err != nil {
		panic(err)
	}
	return document
}

func TestTheSampleIsValidAndNormalizes(t *testing.T) {
	document := sampleDocument()
	if problems := Validate(document, ValidateOptions{}); len(problems) > 0 {
		t.Fatalf("problems: %v", problems)
	}
	normalized := Normalize(document)
	itunes := normalized.Brands[1]
	if itunes.Aliases[0] != "iTunes" {
		t.Fatalf("aliases not trimmed: %q", itunes.Aliases)
	}
	us100 := itunes.Items[0]
	if us100.FaceCurrency != "USD" || us100.Label != "100 دولار" || us100.Price != "520.00" {
		t.Fatalf("item not normalized: %+v", us100)
	}
	if label := itunes.Items[2].Label; label != "10 دولار" {
		t.Fatalf("trailing zeros kept in the label: %q", label)
	}
	if normalized.Brands[0].Items[0].Price != "9.70" || normalized.Countries[0].Code != "US" {
		t.Fatalf("price or country not canonical: %+v", normalized)
	}
	if steam := normalized.Brands[2]; steam.Active == nil || *steam.Active {
		t.Fatal("an inactive brand must stay inactive")
	}
}

func TestEncodingIsStable(t *testing.T) {
	first, sumA, err := Encode(Normalize(sampleDocument()))
	if err != nil {
		t.Fatal(err)
	}
	second, sumB, err := Encode(Normalize(sampleDocument()))
	if err != nil {
		t.Fatal(err)
	}
	if string(first) != string(second) || sumA != sumB || len(sumA) != 64 {
		t.Fatal("the same catalog must encode to the same bytes and fingerprint")
	}
	reparsed, err := ParseDocument(first)
	if err != nil {
		t.Fatalf("the stored form must parse back: %v", err)
	}
	if again, _, _ := Encode(Normalize(reparsed)); string(again) != string(first) {
		t.Fatal("normalizing a stored catalog must not change it")
	}
}

func TestValidationFindsEveryProblem(t *testing.T) {
	document := sampleDocument()
	item := &document.Brands[1].Items[0]
	item.RetailPrice = "500.00"                      // below price
	item.Price = "520.125"                           // three decimals
	document.Brands[1].Items[1].Key = "itunes-us-10" // duplicate key
	document.Brands[1].Items[3].Country = "ZZ"
	document.Brands[0].Category = "nowhere"
	document.Brands[1].Logo.Display = "logos/itunes.png"
	document.Brands[1].Items[2].Promo.Price = "60.00" // not a discount
	document.Brands[1].Items[3].Supplier = json.RawMessage(`{"key": "reloadly", "product_id": 1}`)
	problems := Validate(document, ValidateOptions{})
	want := []string{
		"brands[0].category",
		"brands[1].logo.display",
		"brands[1].items[0].price",
		"brands[1].items[2].key",
		"brands[1].items[2].promo.price",
		"brands[1].items[3].country",
		"brands[1].items[3].supplier",
	}
	for _, path := range want {
		found := false
		for _, problem := range problems {
			if problem.Path == path {
				found = true
			}
		}
		if !found {
			t.Errorf("no problem reported at %s; got %v", path, problems)
		}
	}
}

func TestAPathIsAcceptedOnlyWhenAllowed(t *testing.T) {
	document := sampleDocument()
	document.Brands[1].Logo.Display = "logos/itunes.png"
	if problems := Validate(document, ValidateOptions{PathsAllowed: true}); len(problems) > 0 {
		t.Fatalf("a local check accepts paths: %v", problems)
	}
	known := func(ref string) bool { return ref != logoPrint }
	problems := Validate(sampleDocument(), ValidateOptions{KnownImage: known})
	if len(problems) != 1 || problems[0].Path != "brands[1].logo.print" {
		t.Fatalf("an image the relay does not have must be reported: %v", problems)
	}
}

func TestAPromotionMustNotSellBelowCost(t *testing.T) {
	document := sampleDocument()
	promo := document.Brands[1].Items[2].Promo
	promo.Price = ""
	promo.RetailPrice = "40.00" // below the 52.00 cost
	problems := Validate(document, ValidateOptions{})
	found := false
	for _, problem := range problems {
		if problem.Path == "brands[1].items[2].promo" && strings.Contains(problem.Message, "below the shop's cost") {
			found = true
		}
	}
	if !found {
		t.Fatalf("problems: %v", problems)
	}
}

func TestUnknownFieldsAreRefused(t *testing.T) {
	if _, err := ParseDocument([]byte(`{"categories": [], "brands": [], "colour": "red"}`)); err == nil {
		t.Fatal("an unknown field must be refused")
	}
	if _, err := ParseRef(json.RawMessage(`{"key": "bnplus", "card_id": 1, "card": 2}`)); err == nil {
		t.Fatal("an unknown supplier field must be refused")
	}
}

func TestTheShopSeesOurOrderAndOnlyWhatIsOnSale(t *testing.T) {
	document := Normalize(sampleDocument())
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	view := Shop(document, "sha", now, false, nil)

	if len(view.Brands) != 2 || view.Brands[0].Key != "itunes" || view.Brands[1].Key != "libyana" {
		t.Fatalf("featured first, the inactive brand gone: %+v", view.Brands)
	}
	if len(view.Categories) != 2 || view.Categories[0].Key != "gift_cards" || view.Categories[1].Key != "telecom" {
		t.Fatalf("categories by sort, the empty one gone: %+v", view.Categories)
	}
	var keys []string
	for _, item := range view.Brands[0].Items {
		keys = append(keys, item.Key)
	}
	// US before GB (the catalog's order of regions), then face value: never
	// "10, 100, 25". The inactive 50 is withdrawn.
	if got := strings.Join(keys, ","); got != "itunes-us-10,itunes-us-25,itunes-us-100,itunes-gb-10" {
		t.Fatalf("items = %s", got)
	}
	if len(view.Countries) != 2 || view.Countries[0].Code != "US" || view.Countries[0].Name != "الولايات المتحدة" ||
		view.Countries[0].Flag != flagUS || view.Countries[1].Name != "بريطانيا" {
		t.Fatalf("countries = %+v", view.Countries)
	}
	itunes := view.Brands[0]
	if itunes.Logo != logoDisplay || itunes.PrintLogo != logoPrint || !itunes.Featured || itunes.Rank != 0 {
		t.Fatalf("brand = %+v", itunes)
	}
	if item := itunes.Items[0]; item.Promo != nil || item.UnitPrice != "52.00" || !item.Available {
		t.Fatalf("no promotion runs before it starts: %+v", item)
	}
}

func TestAPromotionChangesPricesAndTheVersion(t *testing.T) {
	document := Normalize(sampleDocument())
	before := Shop(document, "sha", time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC), false, nil)
	during := Shop(document, "sha", time.Date(2026, 10, 12, 12, 0, 0, 0, time.UTC), false, nil)
	item := during.Brands[0].Items[0]
	if item.Promo == nil || item.Promo.Badge != "ربح أكبر" || item.UnitPrice != "50.00" ||
		item.RegularUnitPrice != "52.00" || item.RetailPrice != "60.00" {
		t.Fatalf("promotion not applied: %+v", item)
	}
	if before.Version == during.Version {
		t.Fatal("a promotion starting must change the version a shop caches")
	}
	unavailable := Shop(document, "sha", time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC), false,
		func(located Located) bool { return located.Item.Key != "itunes-us-25" })
	if unavailable.Version == before.Version || unavailable.Brands[0].Items[1].Available {
		t.Fatal("availability must show and change the version")
	}
	if again := Shop(document, "sha", time.Date(2026, 10, 7, 13, 0, 0, 0, time.UTC), false, nil); again.Version != before.Version {
		t.Fatal("nothing changed, so the version must not")
	}
}

func TestChargePriceHonoursAPromotionTheShopSaw(t *testing.T) {
	document := Normalize(sampleDocument())
	item := document.Brands[1].Items[2] // itunes-us-10, promo 50 until 2026-10-20 00:00 +02
	end := time.Date(2026, 10, 19, 22, 0, 0, 0, time.UTC)
	quoted := big.NewRat(50, 1)

	if price, ok := ChargePrice(item, end.Add(-time.Hour), quoted); !ok || price.Cmp(quoted) != 0 {
		t.Fatalf("during the promotion: %v %v", price, ok)
	}
	if price, ok := ChargePrice(item, end.Add(10*time.Minute), quoted); !ok || price.Cmp(quoted) != 0 {
		t.Fatalf("within the grace the promotion's price stands: %v %v", price, ok)
	}
	if _, ok := ChargePrice(item, end.Add(PromotionGrace+time.Minute), quoted); ok {
		t.Fatal("after the grace the higher price is refused")
	}
	if price, ok := ChargePrice(item, end.Add(time.Hour), big.NewRat(51, 1)); ok || price != nil {
		t.Fatalf("after the grace, a quote below the regular price is refused: %v", price)
	}
	if price, ok := ChargePrice(item, end.Add(time.Hour), nil); !ok || price.Cmp(big.NewRat(52, 1)) != 0 {
		t.Fatalf("no limit charges the current price: %v", price)
	}
	if price, ok := ChargePrice(item, end.Add(time.Hour), big.NewRat(60, 1)); !ok || price.Cmp(big.NewRat(52, 1)) != 0 {
		t.Fatalf("a higher limit still charges the current price: %v", price)
	}
}

func TestFindNamesTheItemFully(t *testing.T) {
	document := Normalize(sampleDocument())
	located, ok := Find(document, "itunes-gb-10")
	if !ok {
		t.Fatal("not found")
	}
	if name := located.Name(); name != "آيتونز · بريطانيا · 10 جنيه إسترليني" {
		t.Fatalf("name = %q", name)
	}
	if located.Ref.Supplier != SupplierBNPlus || located.Ref.ID != "4" || !located.Listed() {
		t.Fatalf("located = %+v", located)
	}
	libyana, _ := Find(document, "libyana-10")
	if libyana.Name() != "ليبيانا · 10 دينار" {
		t.Fatalf("a card with no region names none: %q", libyana.Name())
	}
	steam, _ := Find(document, "steam-ww-20")
	if steam.Listed() {
		t.Fatal("an item of an inactive brand is not on sale")
	}
	if _, ok := Find(document, "nope"); ok {
		t.Fatal("unknown items are not found")
	}
}

func TestCountryAndCurrencyNames(t *testing.T) {
	if CountryName("us") != "الولايات المتحدة" || CountryName("WW") != "عالمي" || CountryName("ZZ") != "" {
		t.Fatal("country table")
	}
	if FaceLabel("25", "EUR") != "25 يورو" || FaceLabel("5.500", "XYZ") != "5.5 XYZ" || FaceLabel("", "USD") != "" {
		t.Fatal("face labels")
	}
}
