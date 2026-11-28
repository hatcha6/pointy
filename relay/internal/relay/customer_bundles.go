package relay

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"sort"
	"strings"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// Bundles of «دفتر كروت» (control/customer_bundles.go): two or more cards sold
// together for less. The operator composes them in the console:
//
//	GET    /v1/customers/admin/bundles             every bundle
//	POST   /v1/customers/admin/bundles/evaluate    {bundle}: what each size sells and makes
//	PUT    /v1/customers/admin/bundles/{key}       {bundle}: create or change one
//	DELETE /v1/customers/admin/bundles/{key}
//
// The catalog (GET /v1/customers/catalog) carries those a channel can sell,
// and an order names a size (its tier key) and the card picked for each part
// (customer_bundle_orders.go). A bundle is priced from the shelf: its cards'
// own prices now, less the tier's saving. There is no switch: no bundle
// stored is no `bundles` in the catalog.

const customerBundleBrandPrefix = "bundle:"

// customerBundle is a bundle as the app reads it in the catalog.
type customerBundle struct {
	Key     string               `json:"key"`
	Name    string               `json:"name"`
	Tagline string               `json:"tagline"`
	Rank    int                  `json:"rank"`
	Art     map[string]string    `json:"art"`
	Tiers   []customerBundleTier `json:"tiers"`
}

type customerBundleTier struct {
	Key    string     `json:"key"`
	Saving string     `json:"saving"`
	Parts  [][]string `json:"parts"`
}

// customerBundles reads the stored bundles; none when the store keeps none.
func (s HTTPServer) customerBundles(ctx context.Context) []control.CustomerBundle {
	store, ok := s.Store.(control.CustomerBundleStore)
	if !ok {
		return nil
	}
	bundles, err := store.CustomerBundles(ctx)
	if err != nil {
		s.logger().Warn("customer bundles read failed", "error", err)
		return nil
	}
	return bundles
}

// withBundles puts on a channel's catalog the bundles it can sell: in each
// size, a card the channel does not sell as a code (missing, sent to an
// account, or bought on the website only) is left out of its part; a size
// left with an empty part is left out, and a bundle with no size left is not
// shown. The catalog's version then names the bundles too, so a phone's
// cached shelf is read again when one changes; a catalog with none keeps the
// version it always had.
func withBundles(catalog CustomerCatalogView, bundles []control.CustomerBundle) CustomerCatalogView {
	type shelfCard struct {
		brand string
		price *big.Rat
	}
	sellable := map[string]shelfCard{}
	for _, brand := range catalog.Brands {
		if brand.WebOnly || brand.Target != nil {
			continue
		}
		for _, item := range brand.Items {
			price, ok := new(big.Rat).SetString(item.Price)
			if !ok {
				price = nil
			}
			sellable[item.Key] = shelfCard{brand: brand.Key, price: price}
		}
	}
	served := []customerBundle{}
	for _, bundle := range bundles {
		out := customerBundle{Key: bundle.Key, Name: bundle.Name, Tagline: bundle.Tagline, Rank: bundle.Rank,
			Art: bundle.Art, Tiers: []customerBundleTier{}}
		if out.Art == nil {
			out.Art = map[string]string{}
		}
		for _, tier := range bundle.Tiers {
			parts := [][]string{}
			for _, part := range tier.Parts {
				options := []string{}
				brands := map[string]bool{}
				for _, item := range part {
					card, ok := sellable[item]
					// A part's choices are one per brand: the app picks by
					// brand, so a second card of the same brand is never
					// reachable.
					if !ok || brands[card.brand] {
						continue
					}
					brands[card.brand] = true
					options = append(options, item)
				}
				if len(options) == 0 {
					parts = nil
					break
				}
				parts = append(parts, options)
			}
			if len(parts) < 2 || !savingFits(tier.Saving, parts[savingCarrier(tier.Parts)], func(item string) *big.Rat { return sellable[item].price }) {
				continue
			}
			out.Tiers = append(out.Tiers, customerBundleTier{Key: tier.Key, Saving: tier.Saving, Parts: parts})
		}
		if len(out.Tiers) > 0 {
			served = append(served, out)
		}
	}
	if len(served) == 0 {
		return catalog
	}
	catalog.Bundles = served
	encoded, _ := json.Marshal(served)
	sum := sha256.Sum256([]byte(catalog.Version + "|bundles|" + string(encoded)))
	catalog.Version = hex.EncodeToString(sum[:16])
	return catalog
}

// --- the shelf a bundle is priced from ----------------------------------------

// bundleShelf finds cards in the priced catalog, read once for every card of a
// bundle.
type bundleShelf struct {
	document vouchers.Document
	offers   voucherOffers
	settings vouchers.Settings
	ok       bool
}

func (s HTTPServer) loadBundleShelf(ctx context.Context, cards control.VoucherStore) bundleShelf {
	loaded, err := s.currentVoucherCatalog(ctx, cards)
	if err != nil || loaded.empty {
		return bundleShelf{}
	}
	offers, err := s.loadVoucherOffers(ctx, cards)
	if err != nil {
		return bundleShelf{}
	}
	settings, err := s.voucherSettingsForCards(ctx, cards)
	if err != nil {
		return bundleShelf{}
	}
	return bundleShelf{document: loaded.document, offers: offers, settings: settings, ok: true}
}

// locate is locateCustomerCard on the shelf read once.
func (s HTTPServer) locateOnShelf(shelf bundleShelf, itemKey string, review bool) (vouchers.Located, supplierRanking, bool) {
	if !shelf.ok {
		return vouchers.Located{}, supplierRanking{}, false
	}
	located, found := vouchers.Find(shelf.document, itemKey)
	if !found {
		return vouchers.Located{}, supplierRanking{}, false
	}
	located = s.autoPricedItem(shelf.document, located, shelf.offers, shelf.settings)
	suppliers := s.Vouchers
	if review {
		suppliers = suppliers.reviewSuppliers()
	}
	return located, suppliers.rankSuppliers(located, shelf.offers, shelf.settings), true
}

// bundleItemCost is what a card costs the company now: the supplier a
// purchase would try first, else the cheapest of its suppliers' last-read
// offers (a relay in test mode, or one not configured for that supplier, still
// shows the operator the real cost). Nil when no price is known.
func bundleItemCost(shelf bundleShelf, located vouchers.Located, ranking supplierRanking) *big.Rat {
	if len(ranking.Candidates) > 0 && ranking.Candidates[0].Cost != nil {
		return ranking.Candidates[0].Cost
	}
	refs := located.Refs
	if len(refs) == 0 {
		refs = []vouchers.Ref{located.Ref}
	}
	var cheapest *big.Rat
	for _, ref := range refs {
		offer, known := shelf.offers.offer(ref)
		if !known {
			continue
		}
		if cost, _ := offerCostLYD(offer, shelf.settings); cost != nil && (cheapest == nil || cost.Cmp(cheapest) < 0) {
			cheapest = cost
		}
	}
	return cheapest
}

func itemLabel(item vouchers.Item) string {
	if label := strings.TrimSpace(item.Label); label != "" {
		return label
	}
	return strings.TrimSpace(item.FaceValue + " " + item.FaceCurrency)
}

// savingFits reports whether a tier's saving is a sale: no negative amount,
// and under the price of every card of the part that carries it (savingCarrier,
// judged on the stored parts as an order books it), since the order books
// that card at its price less the saving. A card of unknown price fits.
func savingFits(raw string, carrier []string, price func(string) *big.Rat) bool {
	saving, err := control.ParseWalletAmount(raw)
	if err != nil || saving.Sign() < 0 {
		return false
	}
	for _, item := range carrier {
		if p := price(item); p != nil && saving.Cmp(p) >= 0 {
			return false
		}
	}
	return true
}

// savingCarrier is the part whose card the tier's saving is taken from on the
// books: the first part the company fixed (the game card), else the first.
func savingCarrier(parts [][]string) int {
	for i, part := range parts {
		if len(part) == 1 {
			return i
		}
	}
	return 0
}

func findBundleTier(bundles []control.CustomerBundle, tierKey string) (control.CustomerBundle, control.CustomerBundleTier, bool) {
	for _, bundle := range bundles {
		for _, tier := range bundle.Tiers {
			if tier.Key == tierKey {
				return bundle, tier, true
			}
		}
	}
	return control.CustomerBundle{}, control.CustomerBundleTier{}, false
}

// --- the operator's composer -------------------------------------------------

// bundleItemView is one card a part offers, as the composer shows it.
type bundleItemView struct {
	Item      string `json:"item"`
	Brand     string `json:"brand"`
	BrandName string `json:"brand_name"`
	Label     string `json:"label"`
	Name      string `json:"name"`
	Logo      string `json:"logo"`
	// Price is the card's shelf price now; Cost what its first supplier
	// charges in dinars ("" when unknown).
	Price     string `json:"price"`
	Cost      string `json:"cost"`
	Found     bool   `json:"found"`
	Available bool   `json:"available"`
	Reason    string `json:"reason,omitempty"`
	ToAccount bool   `json:"to_account"`
	// WebOnly are the channels that list the card but sell it on the
	// website only: a bundle with it is not shown there.
	WebOnly []string `json:"web_only"`
}

// bundleChoiceView is one size with one pick: what it sells and makes.
type bundleChoiceView struct {
	Pick []string `json:"pick"`
	// Choice is the art key of the pick (customer_bundles.go in control).
	Choice   string   `json:"choice"`
	Label    string   `json:"label"`
	Apart    string   `json:"apart"`
	Price    string   `json:"price"`
	Saving   string   `json:"saving"`
	Cost     string   `json:"cost"`
	Margin   string   `json:"margin"`
	Percent  string   `json:"margin_percent"`
	Warnings []string `json:"warnings"`
}

type bundleTierView struct {
	Key      string             `json:"key"`
	Saving   string             `json:"saving"`
	Parts    [][]bundleItemView `json:"parts"`
	Choices  []bundleChoiceView `json:"choices"`
	Warnings []string           `json:"warnings"`
	// Broken are the warnings that keep the size, or a card of it, off the
	// app whatever the prices: a card gone from the catalog or sent to an
	// account, two choices of one brand, a size key that is a card's.
	Broken []string `json:"broken"`
}

type bundleEvaluation struct {
	Tiers []bundleTierView `json:"tiers"`
	// Choices are the art keys the bundle's picks come to, so each gets art.
	Choices  []string `json:"choices"`
	Warnings []string `json:"warnings"`
	// Channels says whether each app build shows the bundle, and with how
	// many sizes.
	Channels map[string]int `json:"channels"`
}

var channelNames = map[string]string{
	CustomerChannelIOS: "الآيفون", CustomerChannelPlay: "جوجل بلاي", CustomerChannelAPK: "أندرويد", CustomerChannelWeb: "الموقع",
}

// evaluateBundle prices every size of a bundle with every pick, as the
// composer shows it while it is edited.
func (s HTTPServer) evaluateBundle(ctx context.Context, cards control.VoucherStore, bundle control.CustomerBundle) bundleEvaluation {
	return s.evaluateBundleOn(s.loadBundleShelf(ctx, cards), s.mobileGiftCards(ctx), bundle)
}

// evaluateBundleOn is evaluateBundle on a shelf already read, so a list of
// bundles reads the catalog, offers and settings once, not once per bundle.
func (s HTTPServer) evaluateBundleOn(shelf bundleShelf, mobile string, bundle control.CustomerBundle) bundleEvaluation {
	now := s.clock().Now()
	views := map[string]bundleItemView{}
	view := func(key string) bundleItemView {
		if cached, ok := views[key]; ok {
			return cached
		}
		out := bundleItemView{Item: key, WebOnly: []string{}}
		located, ranking, found := s.locateOnShelf(shelf, key, false)
		if found {
			out.Found = true
			out.Brand, out.BrandName = located.Brand.Key, located.Brand.Name
			out.Label, out.Name, out.Logo = itemLabel(located.Item), located.Name(), located.Brand.Logo.Display
			out.Price = control.NormalizeWalletAmount(vouchers.PriceAt(located.Item, now).RetailPrice)
			out.ToAccount = located.Brand.Target != nil
			reason, _ := ranking.unavailable()
			out.Reason = reason
			out.Available = reason == ""
			if cost := bundleItemCost(shelf, located, ranking); cost != nil {
				out.Cost = control.FormatWalletAmount(cost)
			}
			brand := shelfBrand{Key: located.Brand.Key, Category: located.Brand.Category, Target: located.Brand.Target}
			for _, channel := range customerChannels {
				if show, sell := s.Customers.shelf(channel, brand, mobile); show && !sell {
					out.WebOnly = append(out.WebOnly, channel)
				} else if !show {
					out.WebOnly = append(out.WebOnly, channel)
				}
			}
		}
		views[key] = out
		return out
	}
	evaluation := bundleEvaluation{Tiers: []bundleTierView{}, Choices: []string{}, Warnings: []string{},
		Channels: map[string]int{}}
	choices := map[string]bool{}
	for _, tier := range bundle.Tiers {
		tv := bundleTierView{Key: tier.Key, Saving: control.NormalizeWalletAmount(tier.Saving),
			Parts: [][]bundleItemView{}, Choices: []bundleChoiceView{}, Warnings: []string{}, Broken: []string{}}
		broken := func(warning string) {
			tv.Warnings = append(tv.Warnings, warning)
			tv.Broken = append(tv.Broken, warning)
		}
		if shelf.ok {
			if _, isCard := vouchers.Find(shelf.document, tier.Key); isCard {
				broken("مفتاح الحجم «" + tier.Key + "» هو مفتاح بطاقة في الكتالوج")
			}
		}
		saving, err := control.ParseWalletAmount(tier.Saving)
		if err != nil || saving.Sign() < 0 {
			if strings.TrimSpace(tier.Saving) != "" {
				tv.Warnings = append(tv.Warnings, "التوفير ليس مبلغاً صحيحاً")
			}
			saving = new(big.Rat)
		}
		for p, part := range tier.Parts {
			items := []bundleItemView{}
			prices := map[string]bool{}
			for _, key := range part {
				item := view(key)
				items = append(items, item)
				switch {
				case !item.Found:
					broken("«" + key + "» ليس في الكتالوج")
				case item.ToAccount:
					broken("«" + item.Name + "» يُشحن إلى حساب ولا يدخل في باقة")
				case !item.Available:
					tv.Warnings = append(tv.Warnings, "«"+item.Name+"» غير متوفر الآن: "+item.Reason)
				}
				if item.Found && len(item.WebOnly) > 0 {
					names := []string{}
					for _, channel := range item.WebOnly {
						names = append(names, channelNames[channel])
					}
					tv.Warnings = append(tv.Warnings, "«"+item.Name+"» لا يُباع في "+strings.Join(names, " و")+": لا تظهر الباقة فيها")
				}
				if item.Found {
					prices[item.Price] = true
				}
			}
			if len(part) > 1 {
				seen := map[string]bool{}
				for _, item := range items {
					if item.Found && seen[item.Brand] {
						broken("البطاقة " + itoa(p+1) + ": خياران من «" + item.BrandName + "»، والزبون يختار الشبكة لا البطاقة")
					}
					seen[item.Brand] = true
				}
			}
			if len(part) > 1 && len(prices) > 1 {
				tv.Warnings = append(tv.Warnings, "خيارات البطاقة "+itoa(p+1)+" ليست بسعر واحد: يتغيّر سعر الباقة مع الاختيار")
			}
			tv.Parts = append(tv.Parts, items)
		}
		if len(tier.Parts) < 2 {
			tv.Warnings = append(tv.Warnings, "الباقة بطاقتان على الأقل")
		}
		carrier := savingCarrier(tier.Parts)
		for _, pick := range bundlePicks(tier.Parts) {
			cv := bundleChoiceView{Pick: pick, Saving: control.FormatWalletAmount(saving), Warnings: []string{}}
			apart, cost := new(big.Rat), new(big.Rat)
			costKnown, priced := true, true
			labels, picked := []string{}, []string{}
			for i, key := range pick {
				item := view(key)
				if len(tier.Parts[i]) > 1 {
					picked = append(picked, item.Brand)
				}
				labels = append(labels, item.Label)
				price, err := control.ParseWalletAmount(item.Price)
				if !item.Found || err != nil {
					priced = false
					continue
				}
				apart.Add(apart, price)
				if c, ok := new(big.Rat).SetString(item.Cost); ok && item.Cost != "" {
					cost.Add(cost, c)
				} else {
					costKnown = false
				}
				if i == carrier && saving.Cmp(price) >= 0 {
					cv.Warnings = append(cv.Warnings, "التوفير يساوي سعر «"+item.Name+"» أو يزيد عليه: لا يُباع هذا الاختيار")
				}
				if i == carrier && item.Cost != "" {
					gameMargin := new(big.Rat).Sub(price, ratOrZero(item.Cost))
					if saving.Cmp(gameMargin) > 0 {
						cv.Warnings = append(cv.Warnings, "التوفير أكبر من ربح «"+item.Name+"» ("+
							control.FormatWalletAmount(gameMargin)+")")
					}
				}
			}
			cv.Choice = strings.Join(picked, ",")
			cv.Label = strings.Join(labels, " + ")
			choices[cv.Choice] = true
			if priced {
				price := new(big.Rat).Sub(apart, saving)
				cv.Apart, cv.Price = control.FormatWalletAmount(apart), control.FormatWalletAmount(price)
				if price.Sign() <= 0 {
					cv.Warnings = append(cv.Warnings, "التوفير يساوي سعر البطاقات أو يزيد عليه")
				}
				if costKnown {
					margin := new(big.Rat).Sub(price, cost)
					cv.Cost, cv.Margin = control.FormatWalletAmount(cost), control.FormatWalletAmount(margin)
					if price.Sign() > 0 {
						percent := new(big.Rat).Mul(new(big.Rat).Quo(margin, price), big.NewRat(100, 1))
						cv.Percent = percent.FloatString(1)
					}
					if margin.Sign() < 0 {
						cv.Warnings = append(cv.Warnings, "تُباع بخسارة")
					}
				} else {
					cv.Warnings = append(cv.Warnings, "تكلفة بعض البطاقات غير معروفة")
				}
			}
			tv.Choices = append(tv.Choices, cv)
		}
		evaluation.Tiers = append(evaluation.Tiers, tv)
	}
	for choice := range choices {
		evaluation.Choices = append(evaluation.Choices, choice)
	}
	sort.Strings(evaluation.Choices)
	for _, choice := range evaluation.Choices {
		if bundle.Art[choice] == "" && bundle.Art[""] == "" {
			evaluation.Warnings = append(evaluation.Warnings, "لا صورة للاختيار «"+choiceLabel(choice)+"»")
		}
	}
	for _, channel := range customerChannels {
		sizes := 0
		for _, tier := range bundle.Tiers {
			whole := len(tier.Parts) >= 2
			for _, part := range tier.Parts {
				any := false
				for _, key := range part {
					item := view(key)
					webOnly := false
					for _, c := range item.WebOnly {
						webOnly = webOnly || c == channel
					}
					any = any || (item.Found && !item.ToAccount && !webOnly)
				}
				whole = whole && any
			}
			if whole {
				sizes++
			}
		}
		evaluation.Channels[channel] = sizes
	}
	return evaluation
}

// bundleDraftTooLarge is why a draft has more sizes, cards or choices than a
// bundle may ("" when it fits): the picks priced grow as the product of them.
func bundleDraftTooLarge(bundle control.CustomerBundle) string {
	if len(bundle.Tiers) > control.MaxCustomerBundleTiers {
		return fmt.Sprintf("a bundle has at most %d sizes", control.MaxCustomerBundleTiers)
	}
	for _, tier := range bundle.Tiers {
		if len(tier.Parts) > control.MaxCustomerBundleParts {
			return fmt.Sprintf("a bundle is at most %d cards", control.MaxCustomerBundleParts)
		}
		for _, part := range tier.Parts {
			if len(part) > control.MaxCustomerBundleOptions {
				return fmt.Sprintf("a card of a bundle has at most %d choices", control.MaxCustomerBundleOptions)
			}
		}
	}
	return ""
}

func choiceLabel(choice string) string {
	if choice == "" {
		return "الافتراضي"
	}
	return choice
}

// bundlePicks is every pick of a tier's parts (one card per part).
func bundlePicks(parts [][]string) [][]string {
	picks := [][]string{{}}
	for _, part := range parts {
		next := [][]string{}
		for _, pick := range picks {
			for _, item := range part {
				next = append(next, append(append([]string{}, pick...), item))
			}
		}
		picks = next
	}
	if len(parts) == 0 {
		return nil
	}
	return picks
}

func ratOrZero(value string) *big.Rat {
	out, ok := new(big.Rat).SetString(value)
	if !ok {
		return new(big.Rat)
	}
	return out
}

func itoa(value int) string {
	return big.NewInt(int64(value)).String()
}

// --- admin routes --------------------------------------------------------------

func (s HTTPServer) customerBundleStore(w http.ResponseWriter) (control.CustomerBundleStore, bool) {
	store, ok := s.Store.(control.CustomerBundleStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "bundles_unavailable", "this relay keeps no bundles", nil)
	}
	return store, ok
}

func (s HTTPServer) handleCustomerAdminBundles(w http.ResponseWriter, r *http.Request) {
	store, ok := s.customerBundleStore(w)
	if !ok {
		return
	}
	bundles, err := store.CustomerBundles(r.Context())
	if err != nil {
		s.customerInternalError(w, "customer bundles read failed", err)
		return
	}
	// What keeps a bundle, or a size of it, off the app whatever the prices,
	// for the list to flag (a card since deleted from the catalog, say).
	issues := map[string][]string{}
	if cards, ok := s.voucherStore(); ok && len(bundles) > 0 {
		shelf, mobile := s.loadBundleShelf(r.Context(), cards), s.mobileGiftCards(r.Context())
		for _, bundle := range bundles {
			for _, tier := range s.evaluateBundleOn(shelf, mobile, bundle).Tiers {
				issues[bundle.Key] = append(issues[bundle.Key], tier.Broken...)
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"bundles": bundles, "issues": issues})
}

type customerBundleRequest struct {
	Bundle control.CustomerBundle `json:"bundle"`
	Actor  string                 `json:"actor"`
}

func (s HTTPServer) handleCustomerAdminEvaluateBundle(w http.ResponseWriter, r *http.Request) {
	cards, ok := s.customerVoucherStore(w)
	if !ok {
		return
	}
	var request customerBundleRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	// A draft is evaluated as it is typed, so it is not held to every rule a
	// save is; but every pick of every size is priced, so its size is bounded
	// as a saved bundle's is.
	if message := bundleDraftTooLarge(request.Bundle); message != "" {
		writeCustomerError(w, http.StatusBadRequest, "invalid_bundle", message, nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"evaluation": s.evaluateBundle(r.Context(), cards, request.Bundle)})
}

func (s HTTPServer) handleCustomerAdminSaveBundle(w http.ResponseWriter, r *http.Request, key string) {
	store, ok := s.customerBundleStore(w)
	if !ok {
		return
	}
	var request customerBundleRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	bundle := request.Bundle
	if strings.TrimSpace(bundle.Key) == "" {
		bundle.Key = key
	}
	if bundle.Key != key {
		writeCustomerError(w, http.StatusBadRequest, "invalid_bundle", "the bundle's key is the path's", nil)
		return
	}
	// A size is ordered by its key alone, next to cards ordered by theirs.
	if cards, ok := s.voucherStore(); ok {
		if loaded, err := s.currentVoucherCatalog(r.Context(), cards); err == nil && !loaded.empty {
			for _, tier := range bundle.Tiers {
				if _, found := vouchers.Find(loaded.document, strings.TrimSpace(tier.Key)); found {
					writeCustomerError(w, http.StatusBadRequest, "invalid_bundle",
						"size key "+tier.Key+" is a card's key in the catalog", nil)
					return
				}
				// The buyer picks a part's card by its brand (their network):
				// two choices of one brand could never both be reached.
				for p, part := range tier.Parts {
					brands := map[string]bool{}
					for _, item := range part {
						located, found := vouchers.Find(loaded.document, strings.TrimSpace(item))
						if !found || len(part) < 2 {
							continue
						}
						if brands[located.Brand.Key] {
							writeCustomerError(w, http.StatusBadRequest, "invalid_bundle",
								fmt.Sprintf("size %s, card %d: two choices of brand %s", tier.Key, p+1, located.Brand.Key), nil)
							return
						}
						brands[located.Brand.Key] = true
					}
				}
			}
		}
	}
	bundle.Actor = adminActor(r, request.Actor)
	saved, err := store.SaveCustomerBundle(r.Context(), bundle)
	if errors.Is(err, control.ErrInvalidCustomerBundle) {
		writeCustomerError(w, http.StatusBadRequest, "invalid_bundle", strings.TrimPrefix(err.Error(), control.ErrInvalidCustomerBundle.Error()+": "), nil)
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer bundle write failed", err)
		return
	}
	s.logger().Warn("operator saved a cards-app bundle", "bundle", saved.Key, "tiers", len(saved.Tiers), "actor", saved.Actor)
	writeJSON(w, http.StatusOK, map[string]any{"bundle": saved})
}

func (s HTTPServer) handleCustomerAdminDeleteBundle(w http.ResponseWriter, r *http.Request, key string) {
	store, ok := s.customerBundleStore(w)
	if !ok {
		return
	}
	err := store.DeleteCustomerBundle(r.Context(), key)
	if errors.Is(err, control.ErrCustomerBundleNotFound) {
		writeNotFound(w)
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer bundle delete failed", err)
		return
	}
	s.logger().Warn("operator deleted a cards-app bundle", "bundle", key, "actor", adminActor(r, ""))
	writeJSON(w, http.StatusOK, map[string]any{"deleted": key})
}
