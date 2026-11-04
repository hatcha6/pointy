package relay

import (
	"testing"

	"pointy/relay/internal/vouchers"
)

// The app's redeem button comes from here: a brand's redeem has to reach it.
func TestCustomerCatalogCarriesRedeem(t *testing.T) {
	redeem := &vouchers.Redeem{Kind: vouchers.RedeemDial, Template: "120{code}"}
	view := vouchers.ShopView{Brands: []vouchers.ShopBrand{
		{Key: "libyana", Name: "ليبيانا", Category: "telecom", Redeem: redeem, Items: []vouchers.ShopItem{{Key: "libyana-5", RetailPrice: "5", Available: true}}},
		{Key: "ltt", Name: "LTT", Category: "telecom", Items: []vouchers.ShopItem{{Key: "ltt-5", RetailPrice: "5", Available: true}}},
	}}
	got := CustomerConfig{}.customerCatalog(view, "apk", "")
	seen := map[string]*vouchers.Redeem{}
	for _, brand := range got.Brands {
		seen[brand.Key] = brand.Redeem
	}
	if _, ok := seen["libyana"]; !ok {
		t.Fatalf("libyana not on the shelf: %+v", got.Brands)
	}
	if seen["libyana"] != redeem {
		t.Fatalf("redeem lost: %+v", seen["libyana"])
	}
	if seen["ltt"] != nil {
		t.Fatalf("a brand without one got %+v", seen["ltt"])
	}
}
