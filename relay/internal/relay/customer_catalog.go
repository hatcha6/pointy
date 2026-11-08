package relay

import (
	"context"
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
//
// Google Play draws the line elsewhere. Its Payments policy FAQ
// (support.google.com/googleplay/android-developer/answer/10281818) says Play's
// billing "is not required for the sale of in-app gift cards", nor for digital
// goods that "can only be consumed outside of a Play-distributed app and cannot
// be accessed in a Play-distributed app"; bills and telecoms must not use it at
// all (§3). So the Play build sells gift cards, prepaid game codes, games played
// on a computer or console, and the services. What still wants Play's billing
// is a top-up sent straight to an account in a game or an app: "virtual
// currencies" and subscriptions are named (§2), and they are spent in a game or
// in Telegram, which are themselves on Play. Those follow the operator's switch.
// The APK and the web sell everything.

// Customer app channels: the build that is asking.
const (
	CustomerChannelIOS  = "ios"
	CustomerChannelPlay = "play"
	CustomerChannelAPK  = "apk"
	CustomerChannelWeb  = "web"
)

var customerChannels = []string{CustomerChannelIOS, CustomerChannelPlay, CustomerChannelAPK, CustomerChannelWeb}

// defaultCustomerServiceCategories are the catalog's service categories: what
// the iOS build sells by default.
var defaultCustomerServiceCategories = []string{"telecom", "intl_topup", "internet"}

// playHeldBrands are gift cards the Play build still leaves to the operator's
// switch: value into a crypto exchange and a prepaid payment card read as
// financial products, and the app's Play declaration says it has none. The
// Payments policy is not the question for these; Play's financial and crypto
// policies are.
//
// Rewarble turns into crypto, a virtual Visa or an e-wallet balance, so it is both
// of those. Discord and Adobe are not gift cards at all: they activate a
// subscription to an app that is itself on Play, and the FAQ names subscriptions.
var playHeldBrands = map[string]bool{
	"binance": true, "mastercard": true, "gc-rewarble": true, "gc-discord": true, "gc-adobe": true,
}

// iosRealWorldBrands are gift cards the App Store allows without in-app purchase
// although their category is otherwise left to the operator's switch. Guideline
// 3.1.1 bars only cards "redeemed for digital goods or services", and 3.1.3(e)
// requires another payment method for services consumed outside the app: an
// Airbnb card pays for a stay. A card that also buys digital goods (Amazon,
// GameStop) does not qualify.
var iosRealWorldBrands = map[string]bool{"gc-airbnb": true}

// shelfBrand is what a channel's rules look at.
type shelfBrand struct {
	Key      string
	Category string
	Target   *vouchers.Target
}

// playWantsItsBilling reports whether Google Play's policies leave a brand out
// of what its build sells by default (see the top of this file).
func playWantsItsBilling(brand shelfBrand) bool {
	if playHeldBrands[brand.Key] {
		return true
	}
	if brand.Target == nil {
		return false
	}
	switch brand.Target.Kind {
	case vouchers.TargetSteam, vouchers.TargetSteamInvite:
		// Played on a computer, outside any app on Play.
		return false
	}
	return true
}

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
// sells every category, except ios, which defaults to the service categories,
// and play, which leaves out what playWantsItsBilling names. A list given for
// play stands as written.
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
		return defaultCustomerServiceCategories
	}
	return nil
}

// sells reports whether a channel sells a brand before the operator's switch
// has its say.
func (c CustomerConfig) sells(channel string, brand shelfBrand) bool {
	if channel == CustomerChannelIOS && iosRealWorldBrands[brand.Key] {
		return true
	}
	if !c.channelSells(channel, brand.Category) {
		return false
	}
	return channel != CustomerChannelPlay || c.ChannelCategories[channel] != nil || !playWantsItsBilling(brand)
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

// shelf is whether a channel shows a brand, and whether it sells it. A brand
// the channel may not sell is listed as bought on the website, except on the
// store builds (iOS, Play), where the operator's choice
// ([control.CustomerShelfSettings]) can also hide it or sell it after all.
func (c CustomerConfig) shelf(channel string, brand shelfBrand, mobileGiftCards string) (show, sell bool) {
	if c.sells(channel, brand) {
		return true, true
	}
	if channel == CustomerChannelIOS || channel == CustomerChannelPlay {
		switch mobileGiftCards {
		case control.MobileGiftCardsHidden:
			return false, false
		case control.MobileGiftCardsSell:
			return true, true
		}
	}
	return true, false
}

// mobileGiftCards is the operator's choice for the store builds' shelf. A
// store that cannot say keeps the default: listed, bought on the website.
func (s HTTPServer) mobileGiftCards(ctx context.Context) string {
	store, ok := s.Store.(control.CustomerShelfStore)
	if !ok {
		return control.MobileGiftCardsWebOnly
	}
	settings, err := store.CustomerShelfSettings(ctx)
	if err != nil {
		s.logger().Warn("customer shelf setting read failed", "error", err)
		return control.MobileGiftCardsWebOnly
	}
	return settings.MobileGiftCards
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
	Key        string   `json:"key"`
	Name       string   `json:"name"`
	Aliases    []string `json:"aliases"`
	Category   string   `json:"category"`
	Rank       int      `json:"rank"`
	Featured   bool     `json:"featured"`
	Badge      string   `json:"badge"`
	RedeemHint string   `json:"redeem_hint"`
	// Redeem is what the app does with a bought code: dials it or opens the
	// issuer's page. Nil where only the hint is known.
	Redeem *vouchers.Redeem `json:"redeem,omitempty"`
	Logo   string           `json:"logo"`
	// WebOnly is a brand this channel may show but not sell (the App Store
	// build and gift cards, the Play build and a top-up by player ID): the app
	// lists it with its prices and says it is bought on the website, and an
	// order for it is still refused.
	WebOnly bool `json:"web_only"`
	// Target is what the customer types for a brand sent to an account (a
	// player ID, a Telegram username, a Steam login); nil for a brand of codes.
	Target *vouchers.Target `json:"target,omitempty"`
	// Platform is the store a game is played on ("steam"), which the app
	// names on its tile; empty for the rest.
	Platform string         `json:"platform,omitempty"`
	Items    []customerItem `json:"items"`
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
// What the channel may not sell stays on the shelf, marked web only.
func (c CustomerConfig) customerCatalog(view vouchers.ShopView, channel, mobileGiftCards string) CustomerCatalogView {
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
		show, sell := c.shelf(channel, shelfBrand{Key: brand.Key, Category: brand.Category, Target: brand.Target}, mobileGiftCards)
		if !show {
			continue
		}
		webOnly := !sell
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
			Featured: brand.Featured, Badge: brand.Badge, RedeemHint: brand.RedeemHint, Redeem: brand.Redeem, Logo: brand.Logo,
			WebOnly: webOnly, Target: brand.Target, Platform: brand.Platform, Items: items,
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
	// The operator's choice changes what the shelf version means only on the
	// store builds, but naming it always is simpler and costs one 200
	// elsewhere. ("mobile:" was "ios:" while Play hid these cards outright:
	// renaming it retires every version an app cached under the old rule.)
	sum := sha256.Sum256([]byte(view.Version + "|" + channel + "|" + strings.Join(allowed, ",") + "|mobile:" + mobileGiftCards))
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
	if !wantsAccountBrands(r) {
		// An app that cannot ask for an account is not shown cards sent to one.
		view = withoutAccountBrands(view)
	}
	catalog := s.Customers.customerCatalog(view, channel, s.mobileGiftCards(r.Context()))
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
