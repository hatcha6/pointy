package relay

import (
	"fmt"
	"net/http"
	"testing"
)

func TestCustomerCatalogFirstPartIsAskedForAndMarked(t *testing.T) {
	h := newOrderHarness(t)
	status, whole := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk", "", nil)
	if status != http.StatusOK {
		t.Fatalf("whole: %d", status)
	}
	if _, marked := whole["partial"]; marked {
		t.Fatal("the whole shelf is marked: an older app is answered differently")
	}
	status, first := h.do(http.MethodGet, "/v1/customers/catalog?channel=apk&part=first", "", nil)
	if status != http.StatusOK || first["partial"] != true {
		t.Fatalf("first: %d %v", status, first["partial"])
	}
	if first["version"] == whole["version"] {
		t.Fatal("the first part shares the whole shelf's version: a 304 would keep it")
	}
}

func TestFirstPartKeepsFeaturedAndTheFirstOfEachCategory(t *testing.T) {
	var catalog CustomerCatalogView
	for i := range 20 {
		catalog.Brands = append(catalog.Brands, customerBrand{
			Key: fmt.Sprintf("game-%d", i), Category: "games", Rank: 20 - i,
		})
	}
	catalog.Brands = append(catalog.Brands,
		customerBrand{Key: "star", Category: "games", Rank: 99, Featured: true},
		customerBrand{Key: "phone", Category: "telecom"},
	)
	part := catalog.firstPart()
	kept := map[string]bool{}
	for _, brand := range part.Brands {
		kept[brand.Key] = true
	}
	// The games row leads with the featured brand, then the best-ranked
	// games (19 down to 13): eight in all. And the one telecom brand.
	if len(part.Brands) != firstPartPerCategory+1 || !kept["star"] || !kept["phone"] ||
		!kept["game-19"] || !kept["game-13"] || kept["game-12"] {
		t.Fatalf("first part = %v", kept)
	}
	if part.Brands[0].Key != "game-13" {
		t.Fatalf("the shelf's order was not kept: %s first", part.Brands[0].Key)
	}
}
