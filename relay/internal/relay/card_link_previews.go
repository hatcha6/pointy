package relay

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"pointy/relay/internal/cardsweb"
	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// The card app's web build (cards.dftr.ly) previews a brand's link with the
// brand's name and art, read here: the shelf the web build itself is shown.

var _ cardsweb.Source = HTTPServer{}

// PreviewCatalog is the web build's shelf; empty on a relay that sells no cards.
func (s HTTPServer) PreviewCatalog(ctx context.Context) (cardsweb.PreviewCatalog, error) {
	out := cardsweb.PreviewCatalog{
		Brands: map[string]cardsweb.PreviewBrand{}, Categories: map[string]string{}, Countries: map[string]string{},
	}
	store, ok := s.voucherStore()
	if !ok || !s.Vouchers.Configured() {
		return out, nil
	}
	view, err := s.voucherShopView(ctx, store)
	if err != nil {
		return out, err
	}
	catalog := s.Customers.customerCatalog(view, CustomerChannelWeb, "")
	out.Currency = catalog.Currency
	for order, brand := range catalog.Brands {
		items := make([]cardsweb.PreviewItem, 0, len(brand.Items))
		for _, item := range brand.Items {
			items = append(items, cardsweb.PreviewItem{
				Key: item.Key, Label: item.Label, Country: item.Country, Price: item.Price, Available: item.Available,
			})
		}
		out.Brands[brand.Key] = cardsweb.PreviewBrand{
			Name: brand.Name, Category: brand.Category, Art: brand.Logo, Aliases: brand.Aliases,
			Order: order, RedeemHint: brand.RedeemHint, Items: items,
		}
	}
	for _, category := range catalog.Categories {
		out.Categories[category.Key] = category.Name
		out.CategoryOrder = append(out.CategoryOrder, category.Key)
	}
	for _, country := range catalog.Countries {
		out.Countries[country.Code] = country.Name
	}
	s.previewESIMs(ctx, &out)
	return out, nil
}

// PreviewArt is an uploaded brand image's bytes.
func (s HTTPServer) PreviewArt(ctx context.Context, ref string) ([]byte, error) {
	sum, ok := strings.CutPrefix(ref, vouchers.ImagePrefix)
	if !ok {
		return nil, errors.New("not an uploaded image: " + ref)
	}
	store, ok := s.voucherStore()
	if !ok {
		return nil, errors.New("this relay keeps no card images")
	}
	image, err := store.GetVoucherImage(ctx, sum)
	if err != nil {
		return nil, err
	}
	return image.Data, nil
}

// previewESIMs adds the eSIM shelf, while it is on sale to everyone: a shelf
// only the stores' review account sees has no public pages.
func (s HTTPServer) previewESIMs(ctx context.Context, out *cardsweb.PreviewCatalog) {
	if s.ESIM.reviewOnly() || !s.esimSells() {
		return
	}
	catalog := s.esimCatalogNow(ctx)
	pricing, priced := s.esimPricingNow(ctx)
	if catalog == nil || !priced {
		return
	}
	out.ESIMs = map[string]cardsweb.PreviewESIM{}
	for _, destination := range catalog.Destinations {
		row := cardsweb.PreviewESIM{
			Name: destination.Name, Kind: destination.Kind, Country: destination.Country,
			Countries: len(destination.Countries),
		}
		for _, plan := range destination.Plans {
			offer, ok := pricing.offer(destination.Key, plan)
			if !ok {
				continue
			}
			if offer.Promo != nil && row.PromoBadge == "" {
				row.PromoBadge = offer.Promo.Badge
				if row.PromoBadge == "" {
					row.PromoBadge = "خصم " + strconv.Itoa(offer.Promo.Percent) + "%"
				}
			}
			row.Plans = append(row.Plans, cardsweb.PreviewESIMPlan{
				ID: plan.ID, Data: plan.Data, Days: plan.Days, Unlimited: plan.Unlimited,
				Price: control.FormatWalletAmount(offer.Price),
			})
		}
		if len(row.Plans) == 0 {
			continue
		}
		out.ESIMs[destination.Key] = row
		out.ESIMOrder = append(out.ESIMOrder, destination.Key)
	}
}
