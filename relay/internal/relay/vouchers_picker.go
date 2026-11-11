package relay

import (
	"net/http"
	"strings"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// The console's pickers (buy a card for the company, add stock, link a
// notification to a brand) need the names on the shelf, not the shelf: the
// full admin catalog prices and ranks every card at every supplier and
// carries the whole document, megabytes a phone waits for before the first
// letter can be typed.
//
//	GET /v1/vouchers/admin/catalog/items        every listed card by name, and the brands
//	GET /v1/vouchers/admin/catalog/items/{key}  one card as a purchase made now would find it
//
// The list reads the published document alone: no offers, no settings, no
// ranking. The one card the operator picks is then priced and ranked by
// itself.

type voucherPickerItem struct {
	Key   string `json:"key"`
	Brand string `json:"brand"`
	// Name is the brand, the region and the denomination ("آيتونز · الولايات المتحدة · 10 دولار").
	Name string `json:"name"`
}

type voucherPickerBrand struct {
	Key  string `json:"key"`
	Name string `json:"name"`
}

func (s HTTPServer) handleVoucherAdminPickerItems(w http.ResponseWriter, r *http.Request, store control.VoucherStore) {
	loaded, err := s.currentVoucherCatalog(r.Context(), store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher catalog read failed", err)
		return
	}
	items := []voucherPickerItem{}
	brands := []voucherPickerBrand{}
	if !loaded.empty {
		hidden := map[string]bool{}
		for _, category := range loaded.document.Categories {
			if category.Active != nil && !*category.Active {
				hidden[category.Key] = true
			}
		}
		for _, brand := range loaded.document.Brands {
			if (brand.Active != nil && !*brand.Active) || hidden[brand.Category] {
				continue
			}
			listed := 0
			for _, item := range brand.Items {
				if item.Active != nil && !*item.Active {
					continue
				}
				label := item.Label
				if label == "" {
					label = vouchers.FaceLabel(item.FaceValue, item.FaceCurrency)
				}
				name := brand.Name
				if country := vouchers.CountryName(item.Country); country != "" {
					name += " · " + country
				}
				items = append(items, voucherPickerItem{Key: item.Key, Brand: brand.Key, Name: name + " · " + label})
				listed++
			}
			if listed > 0 {
				brands = append(brands, voucherPickerBrand{Key: brand.Key, Name: brand.Name})
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "brands": brands, "test_mode": s.Vouchers.MarksTest()})
}

func (s HTTPServer) handleVoucherAdminPickerItem(w http.ResponseWriter, r *http.Request, store control.VoucherStore, key string) {
	ctx := r.Context()
	loaded, err := s.currentVoucherCatalog(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher catalog read failed", err)
		return
	}
	located, ok := vouchers.Find(loaded.document, strings.TrimSpace(key))
	if loaded.empty || !ok {
		writeSMSError(w, http.StatusNotFound, voucherCodeUnknownItem, "no such item in the published catalog", nil)
		return
	}
	offers, err := s.loadVoucherOffers(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher offers read failed", err)
		return
	}
	settings, err := s.voucherSettingsForCards(ctx, store)
	if err != nil {
		s.writeVoucherInternalError(w, "", "voucher settings read failed", err)
		return
	}
	located = s.autoPricedItem(loaded.document, located, offers, settings)
	ranking := s.Vouchers.rankSuppliers(located, offers, settings)
	reason, _ := ranking.unavailable()
	answer := map[string]any{
		"key":        located.Item.Key,
		"brand":      located.Brand.Key,
		"name":       located.Name(),
		"unit_price": vouchers.PriceAt(located.Item, s.clock().Now()).UnitPrice,
		"available":  reason == "" && located.Listed(),
		"reason":     reason,
		"suppliers":  ranking.supplies(offers),
		"test_mode":  s.Vouchers.MarksTest(),
	}
	if located.Brand.Target != nil {
		answer["target"] = located.Brand.Target
	}
	writeJSON(w, http.StatusOK, answer)
}
