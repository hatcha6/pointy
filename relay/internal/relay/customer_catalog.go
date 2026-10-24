package relay

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// What a «دفتر كروت» customer is shown: the shops' card catalog at the price a
// shop sells at (the retail price), never what a shop pays, and only the
// categories the app build may sell.
//
// The App Store lets an app take payment outside Apple only for services used
// outside the app (guideline 3.1.3(e)): phone recharge, internet, bills. Game
// and gift cards are digital goods and would need Apple's in-app purchase
// (3.1.1). So the iOS build is shown the service categories only, by the
// server and openly, never switched after review.

// Customer app channels: the build that is asking.
const (
	CustomerChannelIOS  = "ios"
	CustomerChannelPlay = "play"
	CustomerChannelAPK  = "apk"
	CustomerChannelWeb  = "web"
)

var customerChannels = []string{CustomerChannelIOS, CustomerChannelPlay, CustomerChannelAPK, CustomerChannelWeb}

// defaultCustomerIOSCategories are the catalog's service categories.
var defaultCustomerIOSCategories = []string{"telecom", "intl_topup", "internet"}

func validCustomerChannel(channel string) bool {
	for _, known := range customerChannels {
		if channel == known {
			return true
		}
	}
	return false
}

// ParseCustomerChannelCategories reads POINTY_RELAY_CUSTOMER_CHANNEL_CATEGORIES:
// a JSON object of channel -> the category keys it may sell. A channel left out
// sells every category, except ios, which defaults to the service categories.
func ParseCustomerChannelCategories(raw string) (map[string][]string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	parsed := map[string][]string{}
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		return nil, fmt.Errorf(`must be a JSON object such as {"ios":["telecom","internet"]}: %w`, err)
	}
	for channel, categories := range parsed {
		if !validCustomerChannel(channel) {
			return nil, fmt.Errorf("unknown channel %q (known: %s)", channel, strings.Join(customerChannels, ", "))
		}
		if categories == nil {
			// null would read as "sells everything": for ios that is the
			// whole shelf the App Store forbids. Leave a channel out to
			// keep its default.
			return nil, fmt.Errorf("channel %q must list its categories (leave it out for the default)", channel)
		}
		for i, category := range categories {
			categories[i] = strings.TrimSpace(category)
		}
	}
	return parsed, nil
}

// channelCategories is what a channel may sell; nil means everything.
func (c CustomerConfig) channelCategories(channel string) []string {
	// A nil entry (set in code, not parsed) is no list at all: the default
	// applies, never "everything".
	if categories, ok := c.ChannelCategories[channel]; ok && categories != nil {
		return categories
	}
	if channel == CustomerChannelIOS {
		return defaultCustomerIOSCategories
	}
	return nil
}

func (c CustomerConfig) channelSells(channel, category string) bool {
	allowed := c.channelCategories(channel)
	if allowed == nil {
		return true
	}
	for _, key := range allowed {
		if key == category {
			return true
		}
	}
	return false
}

// CustomerCatalogView is the catalog as the app reads it.
type CustomerCatalogView struct {
	Version     string                  `json:"version"`
	Channel     string                  `json:"channel"`
	Currency    string                  `json:"currency"`
	TestMode    bool                    `json:"test_mode"`
	GeneratedAt time.Time               `json:"generated_at"`
	Categories  []vouchers.ShopCategory `json:"categories"`
	Countries   []vouchers.ShopCountry  `json:"countries"`
	Brands      []customerBrand         `json:"brands"`
}

type customerBrand struct {
	Key        string         `json:"key"`
	Name       string         `json:"name"`
	Aliases    []string       `json:"aliases"`
	Category   string         `json:"category"`
	Rank       int            `json:"rank"`
	Featured   bool           `json:"featured"`
	Badge      string         `json:"badge"`
	RedeemHint string         `json:"redeem_hint"`
	Logo       string         `json:"logo"`
	Items      []customerItem `json:"items"`
}

type customerItem struct {
	Key          string `json:"key"`
	Country      string `json:"country"`
	Label        string `json:"label"`
	FaceValue    string `json:"face_value"`
	FaceCurrency string `json:"face_currency"`
	// Price is what the customer pays; RegularPrice the same without a
	// running promotion.
	Price        string              `json:"price"`
	RegularPrice string              `json:"regular_price"`
	Promo        *vouchers.ShopPromo `json:"promo"`
	Available    bool                `json:"available"`
	Rank         int                 `json:"rank"`
}

// customerCatalog narrows the shops' view to a channel and to retail prices.
func (c CustomerConfig) customerCatalog(view vouchers.ShopView, channel string) CustomerCatalogView {
	out := CustomerCatalogView{
		Channel:     channel,
		Currency:    view.Currency,
		TestMode:    view.TestMode,
		GeneratedAt: view.GeneratedAt,
		Categories:  []vouchers.ShopCategory{},
		Countries:   []vouchers.ShopCountry{},
		Brands:      []customerBrand{},
	}
	usedCategories := map[string]bool{}
	usedCountries := map[string]bool{}
	for _, brand := range view.Brands {
		if !c.channelSells(channel, brand.Category) {
			continue
		}
		items := []customerItem{}
		for _, item := range brand.Items {
			items = append(items, customerItem{
				Key:          item.Key,
				Country:      item.Country,
				Label:        item.Label,
				FaceValue:    item.FaceValue,
				FaceCurrency: item.FaceCurrency,
				Price:        item.RetailPrice,
				RegularPrice: item.RegularRetailPrice,
				Promo:        item.Promo,
				Available:    item.Available,
				Rank:         item.Rank,
			})
			usedCountries[item.Country] = true
		}
		if len(items) == 0 {
			continue
		}
		usedCategories[brand.Category] = true
		aliases := brand.Aliases
		if aliases == nil {
			aliases = []string{}
		}
		out.Brands = append(out.Brands, customerBrand{
			Key: brand.Key, Name: brand.Name, Aliases: aliases, Category: brand.Category, Rank: brand.Rank,
			Featured: brand.Featured, Badge: brand.Badge, RedeemHint: brand.RedeemHint, Logo: brand.Logo, Items: items,
		})
	}
	for _, category := range view.Categories {
		if usedCategories[category.Key] {
			out.Categories = append(out.Categories, category)
		}
	}
	for _, country := range view.Countries {
		if usedCountries[country.Code] {
			out.Countries = append(out.Countries, country)
		}
	}
	allowed := append([]string(nil), c.channelCategories(channel)...)
	sort.Strings(allowed)
	sum := sha256.Sum256([]byte(view.Version + "|" + channel + "|" + strings.Join(allowed, ",")))
	out.Version = hex.EncodeToString(sum[:16])
	return out
}

// handleCustomerCatalog serves GET /v1/customers/catalog?channel=…, with no
// sign-in: people browse before they have an account.
func (s HTTPServer) handleCustomerCatalog(w http.ResponseWriter, r *http.Request) {
	channel := strings.TrimSpace(r.URL.Query().Get("channel"))
	if !validCustomerChannel(channel) {
		writeCustomerError(w, http.StatusBadRequest, "invalid_channel",
			"channel must be one of "+strings.Join(customerChannels, ", "), nil)
		return
	}
	store, ok := s.customerVoucherStore(w)
	if !ok {
		return
	}
	view, err := s.voucherShopView(r.Context(), store)
	if err != nil {
		s.customerInternalError(w, "customer catalog read failed", err)
		return
	}
	catalog := s.Customers.customerCatalog(view, channel)
	etag := `"` + catalog.Version + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "public, no-cache")
	if match := strings.TrimSpace(r.Header.Get("If-None-Match")); match != "" && match == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	writeJSON(w, http.StatusOK, catalog)
}

// handleCustomerImage serves GET /v1/customers/images/{sha256}: a brand logo
// or a flag, public like the catalog that names it.
func (s HTTPServer) handleCustomerImage(w http.ResponseWriter, r *http.Request, sum string) {
	store, ok := s.voucherStore()
	if !ok {
		writeNotFound(w)
		return
	}
	s.writeVoucherImage(w, r, store, sum)
}

// customerVoucherStore is the card store when the relay sells cards.
func (s HTTPServer) customerVoucherStore(w http.ResponseWriter) (control.VoucherStore, bool) {
	store, ok := s.voucherStore()
	if !ok || !s.Vouchers.Configured() {
		writeCustomerError(w, http.StatusServiceUnavailable, "cards_unavailable", "this relay sells no cards", nil)
		return nil, false
	}
	return store, true
}

// handleCustomerPaymentMethods serves GET /v1/customers/payment-methods: what
// the checkout offers and what each method asks of the payer.
func (s HTTPServer) handleCustomerPaymentMethods(w http.ResponseWriter, _ *http.Request) {
	methods := []map[string]any{}
	if s.Wallet.TopUpsConfigured() {
		for _, method := range s.Wallet.enabledMethods() {
			methods = append(methods, map[string]any{
				"key":        method.Key,
				"provider":   method.Provider.ID,
				"name":       method.NameAr,
				"kind":       method.kind(),
				"payer":      string(method.Provider.Payer),
				"birth_year": method.Provider.BirthYear,
			})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"methods":          methods,
		"max_quantity":     maxVoucherQuantity,
		"max_otp_attempts": maxWalletOTPAttempts,
		// The checkout shows the fee before the customer pays: the part paid
		// through Dafa is grossed up so the gateway's share is covered
		// (control.CustomerOrderCharge); the order's own figure is the one
		// charged.
		"fee_percent": s.Wallet.feePercent().FloatString(2),
		"test_mode":   s.Wallet.TestMode && len(methods) > 0,
	})
}
