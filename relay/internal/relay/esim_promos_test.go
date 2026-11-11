package relay

import (
	"context"
	"errors"
	"math/big"
	"net/http"
	"testing"
	"time"

	"pointy/relay/internal/control"
)

func (h *esimAccessHarness) promote(promos ...control.ESIMPromo) {
	h.t.Helper()
	if _, err := h.store.SetESIMPromos(context.Background(), control.ESIMPromoSettings{Promos: promos, Actor: "test"}); err != nil {
		h.t.Fatal(err)
	}
	h.server.forgetESIMPromos()
}

func (h *esimAccessHarness) shelfRow(key string) map[string]any {
	h.t.Helper()
	_, body := h.do(http.MethodGet, "/v1/customers/esim/destinations", "", nil)
	for _, raw := range body["destinations"].([]any) {
		if row := raw.(map[string]any); row["key"] == key {
			return row
		}
	}
	h.t.Fatalf("no %s on the shelf: %v", key, body)
	return nil
}

// A promotion shows on the shelf and the destination's page, and is what the
// order is charged; other destinations keep their price, and it ends on time.
func TestESIMPromoCutsThePriceShownAndCharged(t *testing.T) {
	h := newESIMAccessHarness(t, false, nil)
	now := h.server.clock().Now()
	if row := h.shelfRow("tunisia"); row["from_price"] != "15.000" || row["promo"] != nil || len(row["plan_list"].([]any)) == 0 {
		t.Fatalf("before: %v", row)
	}
	h.promote(control.ESIMPromo{ID: "p1", Destination: "tunisia", Percent: 20, Badge: "عرض الصيف", StartsAt: now.Add(-time.Hour), EndsAt: now.Add(time.Hour)})

	row := h.shelfRow("tunisia")
	promo, _ := row["promo"].(map[string]any)
	if row["from_price"] != "12.000" || row["regular_from_price"] != "15.000" || promo["badge"] != "عرض الصيف" || promo["percent"] != float64(20) {
		t.Fatalf("shelf row: %v", row)
	}
	if turkey := h.shelfRow("turkey"); turkey["from_price"] != "8.000" || turkey["promo"] != nil {
		t.Fatalf("Turkey has no promotion: %v", turkey)
	}
	plan := h.plan("tunisia", 1024, 7)
	if plan["price"] != "12.000" || plan["regular_price"] != "15.000" || plan["promo"] == nil {
		t.Fatalf("plan: %v", plan)
	}
	token := h.customer("0911111111")
	if order := h.buy(token, plan, "promo-1"); order["status"] != "delivered" || order["total"] != "12.000" {
		t.Fatalf("order at the promotion's price: %v", order)
	}

	// Over: the regular price again, everywhere.
	h.promote(control.ESIMPromo{ID: "p1", Destination: "tunisia", Percent: 20, StartsAt: now.Add(-2 * time.Hour), EndsAt: now.Add(-time.Hour)})
	if row := h.shelfRow("tunisia"); row["from_price"] != "15.000" || row["promo"] != nil {
		t.Fatalf("after: %v", row)
	}
}

// However deep the operator writes it, a promotion never sells under what the
// margin asks on the plan's cost; one on the whole shelf reaches every plan.
func TestESIMPromoNeverSellsUnderTheFloor(t *testing.T) {
	h := newESIMAccessHarness(t, false, nil)
	now := h.server.clock().Now()
	h.promote(control.ESIMPromo{ID: "all", Percent: 90, StartsAt: now.Add(-time.Hour), EndsAt: now.Add(time.Hour)})
	pricing, ok := h.server.esimPricingNow(context.Background())
	if !ok {
		t.Fatal("no pricing")
	}
	catalog := h.server.esimCatalogNow(context.Background())
	cut := 0
	for _, destination := range catalog.Destinations {
		for _, plan := range destination.Plans {
			offer, ok := pricing.offer(destination.Key, plan)
			if !ok {
				continue
			}
			cost := new(big.Rat).Mul(new(big.Rat).SetFloat64(plan.NetUSD), pricing.rate)
			if offer.Price.Cmp(cost) <= 0 {
				t.Fatalf("%s %s sells at %s under its cost %s", destination.Key, plan.ID, offer.Price.FloatString(3), cost.FloatString(3))
			}
			if offer.Promo != nil {
				cut++
				if offer.Price.Cmp(offer.Regular) >= 0 {
					t.Fatalf("a promotion that cuts nothing is shown: %s", plan.ID)
				}
			}
		}
	}
	if cut == 0 {
		t.Fatal("a promotion on the whole shelf cut nothing")
	}
}

func TestESIMPromosAreValidated(t *testing.T) {
	h := newESIMAccessHarness(t, false, nil)
	now := h.server.clock().Now()
	for name, promo := range map[string]control.ESIMPromo{
		"no id":        {Percent: 10, StartsAt: now, EndsAt: now.Add(time.Hour)},
		"zero percent": {ID: "a", StartsAt: now, EndsAt: now.Add(time.Hour)},
		"too deep":     {ID: "a", Percent: 95, StartsAt: now, EndsAt: now.Add(time.Hour)},
		"ends first":   {ID: "a", Percent: 10, StartsAt: now, EndsAt: now.Add(-time.Hour)},
		"no dates":     {ID: "a", Percent: 10},
		"a long badge": {ID: "a", Percent: 10, Badge: "هذه شارة أطول بكثير مما يتسع له المكان", StartsAt: now, EndsAt: now.Add(time.Hour)},
	} {
		if _, err := h.store.SetESIMPromos(context.Background(), control.ESIMPromoSettings{Promos: []control.ESIMPromo{promo}}); !errors.Is(err, control.ErrInvalidESIMPromo) {
			t.Fatalf("%s: %v", name, err)
		}
	}
}
