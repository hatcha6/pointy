package relay

import (
	"math/big"
	"net/http"
	"testing"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// autoCatalog: the catalog default is auto; one item opts out, one has no
// supplier offer, one is a local LYD card whose face caps the price.
const autoCatalog = `{
  "price_mode": "auto",
  "categories": [{"key": "gaming", "name": "ألعاب", "sort": 1}],
  "brands": [{
    "key": "psn", "name": "بلايستيشن", "category": "gaming", "logo": {},
    "items": [
      {"key": "psn-20", "country": "US", "face_value": "20", "face_currency": "USD", "price": "999.00", "retail_price": "999.00",
       "supplier": {"key": "bnplus", "card_id": 201}},
      {"key": "psn-nooffer", "country": "US", "face_value": "10", "face_currency": "USD", "price": "60.00", "retail_price": "66.00",
       "supplier": {"key": "bnplus", "card_id": 202}},
      {"key": "psn-static", "country": "US", "face_value": "5", "face_currency": "USD", "price": "30.00", "retail_price": "33.00",
       "price_mode": "static", "supplier": {"key": "bnplus", "card_id": 203}},
      {"key": "lyd-10", "country": "LY", "face_value": "10", "face_currency": "LYD", "price": "10.00", "retail_price": "10.00",
       "supplier": {"key": "bnplus", "card_id": 204}}
    ]
  }]
}`

func autoOffers(prices map[string]string) voucherOffers {
	index := voucherOffers{byKey: map[string]control.VoucherOffer{}, listed: map[string]bool{vouchers.SupplierBNPlus: true}}
	for ref, price := range prices {
		index.byKey[vouchers.SupplierBNPlus+"/"+ref] = control.VoucherOffer{
			Supplier: vouchers.SupplierBNPlus, Ref: ref, Price: price, Currency: "LYD", InStock: true,
		}
	}
	return index
}

func autoItem(t *testing.T, document vouchers.Document, key string) vouchers.Item {
	t.Helper()
	located, ok := vouchers.Find(document, key)
	if !ok {
		t.Fatalf("no item %s", key)
	}
	return located.Item
}

func TestAutoPricedDocumentPricesFromTheCheapestSupplierCost(t *testing.T) {
	document, err := vouchers.ParseDocument([]byte(autoCatalog))
	if err != nil {
		t.Fatal(err)
	}
	server := HTTPServer{Vouchers: VoucherConfig{Suppliers: map[string]vouchers.Supplier{vouchers.SupplierBNPlus: newFakeSupplier()}}}
	settings := vouchers.DefaultSettings()
	offers := autoOffers(map[string]string{"201": "104.50", "203": "28.00", "204": "9.00"})

	priced := server.autoPricedDocument(document, offers, settings)

	want, ok := settings.MarginFor(vouchers.ServiceKindCard).Prices(big.NewRat(10450, 100))
	if !ok {
		t.Fatal("margin must price 104.50")
	}
	item := autoItem(t, priced, "psn-20")
	if item.Price != vouchers.FormatDinars(want.ShopPays) || item.RetailPrice != vouchers.FormatDinars(want.Retail) {
		t.Fatalf("psn-20 priced %s/%s, want %s/%s", item.Price, item.RetailPrice,
			vouchers.FormatDinars(want.ShopPays), vouchers.FormatDinars(want.Retail))
	}
	if want.ShopPays.Cmp(big.NewRat(10450, 100)) <= 0 || want.Retail.Cmp(want.ShopPays) <= 0 {
		t.Fatalf("the margin must put shop price above cost and retail above that: %v", want)
	}

	// No offer for the card: the written prices stay.
	if item := autoItem(t, priced, "psn-nooffer"); item.Price != "60.00" || item.RetailPrice != "66.00" {
		t.Fatalf("static fallback lost: %+v", item)
	}
	// An item that opts out of the catalog-wide auto mode keeps its prices even with an offer.
	if item := autoItem(t, priced, "psn-static"); item.Price != "30.00" || item.RetailPrice != "33.00" {
		t.Fatalf("static item repriced: %+v", item)
	}
	// The original document is untouched.
	if autoItem(t, document, "psn-20").Price != "999.00" {
		t.Fatal("the source document was mutated")
	}
}

func TestAutoPricedLYDCardNeverSellsAboveItsFace(t *testing.T) {
	document, err := vouchers.ParseDocument([]byte(autoCatalog))
	if err != nil {
		t.Fatal(err)
	}
	server := HTTPServer{Vouchers: VoucherConfig{Suppliers: map[string]vouchers.Supplier{vouchers.SupplierBNPlus: newFakeSupplier()}}}
	// Cost 9.00 plus any margin overshoots a 10 LYD face.
	priced := server.autoPricedDocument(document, autoOffers(map[string]string{"204": "9.00"}), vouchers.DefaultSettings())
	item := autoItem(t, priced, "lyd-10")
	if item.RetailPrice != "10.00" {
		t.Fatalf("retail %s must be capped at the face value", item.RetailPrice)
	}
	if shop, _ := new(big.Rat).SetString(item.Price); shop.Cmp(big.NewRat(10, 1)) > 0 || shop.Cmp(big.NewRat(9, 1)) <= 0 {
		t.Fatalf("shop price %s must sit between cost and the capped retail", item.Price)
	}
}

func TestThePurchaseChargesTheAutoPrice(t *testing.T) {
	h := newVoucherHarness(t)
	status, body := h.admin(t, http.MethodPut, "/v1/vouchers/admin/catalog", "application/json",
		[]byte(`{"document": `+autoCatalog+`, "actor": "ops", "note": "auto"}`))
	if status != http.StatusCreated {
		t.Fatalf("publish: %d %v", status, body)
	}
	h.storeOffers(t, vouchers.SupplierBNPlus,
		control.VoucherOffer{Ref: "201", Name: "PSN 20", Price: "104.50", Currency: "LYD", InStock: true})
	shopper := h.provision(t)
	h.fundVouchers(t, shopper.AccessToken, shopper.Installation.ID, "500")

	want, _ := vouchers.DefaultSettings().MarginFor(vouchers.ServiceKindCard).Prices(big.NewRat(10450, 100))
	price := vouchers.FormatDinars(want.ShopPays)

	status, body = h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shopper.AccessToken,
		purchaseRequest("psn-20", "auto-1", ""))
	if status != http.StatusCreated {
		t.Fatalf("purchase: %d %v", status, body)
	}
	// Not the 999.00 written in the catalog.
	got, _ := new(big.Rat).SetString(body["purchase"].(map[string]any)["unit_price"].(string))
	if wantRat, _ := new(big.Rat).SetString(price); got.Cmp(wantRat) != 0 {
		t.Fatalf("charged %v, want the auto price %s", got.FloatString(3), price)
	}

	// A max price below the auto price is refused as a price change.
	status, body = h.shop(t, h.server, http.MethodPost, "/v1/vouchers/purchases", shopper.AccessToken,
		purchaseRequest("psn-20", "auto-2", "100.00"))
	if status != http.StatusConflict {
		t.Fatalf("a quote below the auto price must be refused: %d %v", status, body)
	}
}
