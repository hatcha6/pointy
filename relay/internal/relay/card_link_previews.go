package relay

import (
	"context"
	"errors"
	"strings"

	"pointy/relay/internal/cardsweb"
	"pointy/relay/internal/vouchers"
)

// The card app's web build (cards.dftr.ly) previews a brand's link with the
// brand's name and art, read here: the shelf the web build itself is shown.

var _ cardsweb.Source = HTTPServer{}

// PreviewCatalog is the web build's shelf; empty on a relay that sells no cards.
func (s HTTPServer) PreviewCatalog(ctx context.Context) (cardsweb.PreviewCatalog, error) {
	out := cardsweb.PreviewCatalog{Brands: map[string]cardsweb.PreviewBrand{}, Categories: map[string]string{}}
	store, ok := s.voucherStore()
	if !ok || !s.Vouchers.Configured() {
		return out, nil
	}
	view, err := s.voucherShopView(ctx, store)
	if err != nil {
		return out, err
	}
	catalog := s.Customers.customerCatalog(view, CustomerChannelWeb, "")
	for _, brand := range catalog.Brands {
		out.Brands[brand.Key] = cardsweb.PreviewBrand{Name: brand.Name, Category: brand.Category, Art: brand.Logo}
	}
	for _, category := range catalog.Categories {
		out.Categories[category.Key] = category.Name
	}
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
