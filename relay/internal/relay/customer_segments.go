package relay

import (
	"context"
	"crypto/rand"
	"errors"
	"math/big"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/fcm"
	"pointy/relay/internal/segments"
)

// «دفتر كروت» customer segments (internal/segments): who buys how, what each
// segment brings, what to do about it, and the means to do it: a notification
// to chosen segments, and offers (control/customer_offers.go) made for them.
//
//	GET   /v1/customers/admin/segments                the segments, their numbers and the insights
//	GET   /v1/customers/admin/customers?rfm=a,b       the customers of chosen segments (customer_admin.go)
//	POST  /v1/customers/admin/notifications           {audience: "segments", segments: [...]}
//	GET   /v1/customers/admin/offers                  every offer, with what it did
//	POST  /v1/customers/admin/offers                  {name, title, description, kind, value, max_discount,
//	                                                   min_order, segments, uses_per_customer,
//	                                                   max_redemptions, starts_at, ends_at,
//	                                                   holdout_percent, notify: {title, body, link}}
//	PATCH /v1/customers/admin/offers/{id}             {name, title, description, ends_at, active}
//	GET   /v1/customers/me/offers                     the offers this customer can use now
//	GET   /v1/customers/offers                        the offers for everyone, for visitors

// customerSegmentationFresh is how long one segmentation is used: the console
// pages through customers, and a page must not cost a whole reading.
const customerSegmentationFresh = time.Minute

// CustomerSegmentCache keeps the last segmentation. Nil computes every time.
type CustomerSegmentCache struct {
	mu    sync.Mutex
	value *customerSegmentation
}

// customerSegmentation is every live customer placed, at one moment.
type customerSegmentation struct {
	at       time.Time
	profiles map[string]*segments.Profile
	orders   []segments.Order
	stats    []segments.Stats
	overview segments.Overview
	insights []segments.Insight
}

// members are the customers of keys, in id order.
func (c *customerSegmentation) members(keys map[string]bool, reachableOnly bool) []segments.Profile {
	out := []segments.Profile{}
	for _, profile := range c.profiles {
		if keys[profile.Segment] && (!reachableOnly || profile.Reachable) {
			out = append(out, *profile)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CustomerID < out[j].CustomerID })
	return out
}

func (s HTTPServer) customerInsightStore(w http.ResponseWriter) (control.CustomerInsightStore, bool) {
	store, ok := s.Store.(control.CustomerInsightStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "customers_unconfigured", "this relay keeps no customers", nil)
	}
	return store, ok
}

// customerSegmentation is the segmentation, from the cache while it is fresh
// (fresh asks for a new one: an offer or a send acts on who is in a segment
// now).
func (s HTTPServer) customerSegmentation(r *http.Request, store control.CustomerInsightStore, fresh bool) (*customerSegmentation, error) {
	now := s.clock().Now()
	cache := s.CustomerSegments
	if cache != nil && !fresh {
		cache.mu.Lock()
		value := cache.value
		cache.mu.Unlock()
		if value != nil && now.Sub(value.at) < customerSegmentationFresh {
			return value, nil
		}
	}
	ctx := r.Context()
	facts, err := store.CustomerFacts(ctx)
	if err != nil {
		return nil, err
	}
	orderFacts, err := store.CustomerOrderFacts(ctx)
	if err != nil {
		return nil, err
	}
	customers := make([]segments.Customer, 0, len(facts))
	for _, fact := range facts {
		// A deleted or blocked account is in no segment: it cannot buy.
		if fact.DeletedAt != nil || fact.BlockedAt != nil {
			continue
		}
		customers = append(customers, segments.Customer{ID: fact.ID, CreatedAt: fact.CreatedAt, Reachable: fact.PushDevices > 0})
	}
	since := now
	if len(orderFacts) > 0 {
		since = orderFacts[0].PurchaseAt
		if orderFacts[0].CompletedAt.Before(since) || since.IsZero() {
			since = orderFacts[0].CompletedAt
		}
	}
	rates, _ := s.financeRatesFor(r, since)
	orders := make([]segments.Order, 0, len(orderFacts))
	for _, fact := range orderFacts {
		revenue, err := control.ParseWalletAmount(fact.Total)
		if err != nil {
			continue
		}
		discount, err := control.ParseWalletAmount(fact.Discount)
		if err != nil {
			discount = new(big.Rat)
		}
		order := segments.Order{ID: fact.ID, CustomerID: fact.CustomerID, At: fact.CompletedAt,
			Revenue: revenue, Discount: discount, OfferID: fact.OfferID}
		if fact.SupplierCost != "" {
			// The cost at the dollar rate of the hour it was bought, as the
			// books count it (finance_rates.go).
			if cost, ok := costInDinars(fact.SupplierCost, fact.SupplierCurrency,
				rates.usdAt(fact.PurchaseAt.UTC().Truncate(time.Hour))); ok {
				order.Cost = cost
			}
		}
		orders = append(orders, order)
	}
	profiles := segments.Assign(customers, orders, now)
	stats, overview := segments.Summarize(profiles, orders, now)
	value := &customerSegmentation{
		at: now, profiles: profiles, orders: orders, stats: stats, overview: overview,
		insights: segments.Insights(stats, overview),
	}
	if cache != nil {
		cache.mu.Lock()
		cache.value = value
		cache.mu.Unlock()
	}
	return value, nil
}

// forgetCustomerSegmentation drops the cached segmentation: an offer was made
// or ended, and the numbers must say so.
func (s HTTPServer) forgetCustomerSegmentation() {
	if cache := s.CustomerSegments; cache != nil {
		cache.mu.Lock()
		cache.value = nil
		cache.mu.Unlock()
	}
}

func money(value *big.Rat) string {
	if value == nil {
		return control.FormatWalletAmount(new(big.Rat))
	}
	return control.FormatWalletAmount(value)
}

func segmentStatsView(stats segments.Stats) map[string]any {
	return map[string]any{
		"key": stats.Key, "customers": stats.Customers, "share": stats.Share, "reachable": stats.Reachable,
		"buyers": stats.Buyers, "repeat_buyers": stats.RepeatBuyers, "orders": stats.Orders,
		"recent_orders": stats.RecentOrders, "revenue": money(stats.Revenue), "recent_revenue": money(stats.RecentRevenue),
		"profit": money(stats.Profit), "recent_profit": money(stats.RecentProfit), "discounts": money(stats.Discounts),
		"unpriced_orders": stats.UnpricedOrders, "revenue_share": stats.RevenueShare, "profit_share": stats.ProfitShare,
		"margin": stats.Margin(), "average_order": money(stats.AverageOrder()),
		"revenue_per_customer": money(stats.RevenuePerCustomer()),
		"cycle_days":           stats.CycleDays, "days_since_last": stats.DaysSinceLast,
	}
}

func (s HTTPServer) handleCustomerAdminSegments(w http.ResponseWriter, r *http.Request) {
	store, ok := s.customerInsightStore(w)
	if !ok {
		return
	}
	segmentation, err := s.customerSegmentation(r, store, r.URL.Query().Get("fresh") == "1")
	if err != nil {
		s.customerInternalError(w, "customer segmentation failed", err)
		return
	}
	views := make([]map[string]any, 0, len(segmentation.stats))
	for _, stats := range segmentation.stats {
		views = append(views, segmentStatsView(stats))
	}
	o := segmentation.overview
	writeJSON(w, http.StatusOK, map[string]any{
		"generated_at": segmentation.at,
		"segments":     views,
		"overview": map[string]any{
			"customers": o.Customers, "reachable": o.Reachable, "buyers": o.Buyers, "repeat_buyers": o.RepeatBuyers,
			"repeat_rate": o.RepeatRate, "active_buyers": o.ActiveBuyers, "orders": o.Orders,
			"revenue": money(o.Revenue), "recent_revenue": money(o.RecentRevenue), "profit": money(o.Profit),
			"recent_profit": money(o.RecentProfit), "discounts": money(o.Discounts),
			"margin":                segmentsRatio(o.Profit, o.PricedRevenue),
			"median_days_to_second": o.MedianDaysToSecond, "second_within_30": o.SecondWithin30,
		},
		"insights": segmentation.insights,
		// How the segments are drawn, for the console to say.
		"rules": map[string]any{
			"new_days": int(segments.NewFor.Hours() / 24), "first_purchase_days": int(segments.FirstPurchaseFor.Hours() / 24),
			"lost_days": int(segments.LostAfter.Hours() / 24), "window_days": int(segments.Window.Hours() / 24),
			"on_rhythm": segments.OnRhythm, "slipping_to": segments.SlippingTo,
			"champion_orders": segments.ChampionOrders, "loyal_orders": segments.LoyalOrders,
			"high_value_share": segments.HighValueShare, "recent_days": int(segments.Recent.Hours() / 24),
		},
		"push_configured": s.CustomerPush != nil,
	})
}

func segmentsRatio(part, whole *big.Rat) float64 {
	if part == nil || whole == nil || whole.Sign() == 0 {
		return 0
	}
	value, _ := new(big.Rat).Quo(part, whole).Float64()
	return value
}

// requestedSegments reads segment keys (a list, or a comma-separated
// string); false when one is not a segment or there is none.
func requestedSegments(keys []string) (map[string]bool, bool) {
	out := map[string]bool{}
	for _, key := range keys {
		for _, part := range strings.Split(key, ",") {
			part = strings.TrimSpace(part)
			if part == "" {
				continue
			}
			if !segments.Known(part) {
				return nil, false
			}
			out[part] = true
		}
	}
	return out, len(out) > 0
}

// customerSegmentFilter narrows a customer listing to the segments named by
// ?rfm=, and says each listed customer's segment. ok false is a bad request.
func (s HTTPServer) customerSegmentFilter(r *http.Request, filter *control.CustomerListFilter) (*customerSegmentation, bool, error) {
	store, has := s.Store.(control.CustomerInsightStore)
	raw := strings.TrimSpace(r.URL.Query().Get("rfm"))
	if !has {
		return nil, raw == "", nil
	}
	segmentation, err := s.customerSegmentation(r, store, false)
	if err != nil || raw == "" {
		return segmentation, true, err
	}
	keys, ok := requestedSegments([]string{raw})
	if !ok {
		return nil, false, nil
	}
	filter.OnlyIDs = true
	for _, profile := range segmentation.members(keys, false) {
		filter.IDs = append(filter.IDs, profile.CustomerID)
	}
	return segmentation, true, nil
}

// pushToCustomers sends message to every live device of ids.
func (s HTTPServer) pushToCustomers(ctx context.Context, store customerAdminStore, ids []string, message fcm.Message, record *control.CustomerNotification) error {
	insights, ok := s.Store.(control.CustomerInsightStore)
	if !ok {
		return errors.New("this relay keeps no customers")
	}
	tokens, err := insights.CustomerPushTokens(ctx, ids)
	if err != nil {
		return err
	}
	var sessions []control.CustomerSession
	for _, id := range ids {
		for _, token := range tokens[id] {
			sessions = append(sessions, control.CustomerSession{CustomerID: id, PushToken: token})
		}
	}
	s.pushToDevices(ctx, store, sessions, message, record)
	return nil
}

// --- offers ------------------------------------------------------------------

func (s HTTPServer) customerOfferStore(w http.ResponseWriter) (control.CustomerOfferStore, control.CustomerInsightStore, bool) {
	offers, ok := s.Store.(control.CustomerOfferStore)
	insights, ok2 := s.Store.(control.CustomerInsightStore)
	if !ok || !ok2 {
		writeCustomerError(w, http.StatusServiceUnavailable, "customers_unconfigured", "this relay keeps no customers", nil)
		return nil, nil, false
	}
	return offers, insights, true
}

func customerOfferError(w http.ResponseWriter, err error) bool {
	switch {
	case errors.Is(err, control.ErrCustomerOfferInvalid):
		message := strings.TrimSpace(strings.TrimPrefix(err.Error(), control.ErrCustomerOfferInvalid.Error()))
		writeCustomerError(w, http.StatusBadRequest, "invalid_offer", strings.TrimSpace(message), nil)
		return true
	case errors.Is(err, control.ErrCustomerOfferNotFound):
		writeCustomerError(w, http.StatusNotFound, "offer_not_found", "no such offer", nil)
		return true
	}
	return false
}

// offerView is an offer with what it did so far.
func offerView(offer control.CustomerOffer, result segments.OfferResult, use control.CustomerOfferUse) map[string]any {
	spent := use.Spent
	if spent == nil {
		spent = new(big.Rat)
	}
	return map[string]any{
		"offer": offer,
		// What it has given so far, unpaid orders too: what its budget counts.
		"use": map[string]any{"orders": use.Redeemed, "spent": money(spent)},
		"result": map[string]any{
			"redeemers": result.Redeemers, "orders": result.Orders, "revenue": money(result.Revenue),
			"discounts": money(result.Discounts), "profit": money(result.Profit),
			"recipients_bought": result.RecipientsBought, "holdouts_bought": result.HoldoutsBought,
			"recipient_rate": result.RecipientRate, "holdout_rate": result.HoldoutRate, "lift": result.Lift,
			"revenue_per_recipient": money(result.RevenuePerRecipient),
			"revenue_per_holdout":   money(result.RevenuePerHoldout),
		},
	}
}

func (s HTTPServer) measureOffer(ctx context.Context, store control.CustomerOfferStore, segmentation *customerSegmentation, offer control.CustomerOffer) (segments.OfferResult, error) {
	people, err := store.CustomerOfferRecipients(ctx, offer.ID)
	if err != nil {
		return segments.OfferResult{}, err
	}
	recipients, holdouts := map[string]bool{}, map[string]bool{}
	for _, person := range people {
		if person.Holdout {
			holdouts[person.CustomerID] = true
		} else {
			recipients[person.CustomerID] = true
		}
	}
	return segments.MeasureOffer(offer.ID, recipients, holdouts, segmentation.orders, offer.StartsAt, offer.EndsAt, s.clock().Now()), nil
}

func (s HTTPServer) handleCustomerAdminOffers(w http.ResponseWriter, r *http.Request) {
	store, insights, ok := s.customerOfferStore(w)
	if !ok {
		return
	}
	offers, err := store.ListCustomerOffers(r.Context())
	if err != nil {
		s.customerInternalError(w, "customer offers failed", err)
		return
	}
	segmentation, err := s.customerSegmentation(r, insights, false)
	if err != nil {
		s.customerInternalError(w, "customer segmentation failed", err)
		return
	}
	views := make([]map[string]any, 0, len(offers))
	for _, offer := range offers {
		result, err := s.measureOffer(r.Context(), store, segmentation, offer)
		if err != nil {
			s.customerInternalError(w, "customer offer results failed", err)
			return
		}
		_, use, err := store.CustomerOfferUses(r.Context(), offer.ID)
		if err != nil {
			s.customerInternalError(w, "customer offer uses failed", err)
			return
		}
		views = append(views, offerView(offer, result, use))
	}
	writeJSON(w, http.StatusOK, map[string]any{"offers": views, "push_configured": s.CustomerPush != nil})
}

type customerOfferRequest struct {
	Name            string     `json:"name"`
	Title           string     `json:"title"`
	Description     string     `json:"description"`
	Kind            string     `json:"kind"`
	Value           string     `json:"value"`
	MaxDiscount     string     `json:"max_discount"`
	MinOrder        string     `json:"min_order"`
	Segments        []string   `json:"segments"`
	UsesPerCustomer int        `json:"uses_per_customer"`
	MaxRedemptions  int        `json:"max_redemptions"`
	StartsAt        *time.Time `json:"starts_at"`
	EndsAt          *time.Time `json:"ends_at"`
	HoldoutPercent  int        `json:"holdout_percent"`
	// Audience is segments (the default) or everyone.
	Audience    string                      `json:"audience"`
	Tiers       []control.CustomerOfferTier `json:"tiers"`
	TierUnit    string                      `json:"tier_unit"`
	BuyQuantity int                         `json:"buy_quantity"`
	GetQuantity int                         `json:"get_quantity"`
	GetPercent  string                      `json:"get_percent"`
	Scope       control.CustomerOfferScope  `json:"scope"`
	Badge       string                      `json:"badge"`
	// Budget caps the discounts it gives in all ("" or "0": no cap).
	Budget string `json:"budget"`
	// Notify, when it has words, tells the recipients (not the holdout) when
	// it starts; Remind, the day before it ends, those who have not used it.
	Notify *struct {
		Title  string `json:"title"`
		Body   string `json:"body"`
		Link   string `json:"link"`
		Remind bool   `json:"remind"`
	} `json:"notify"`
	Actor string `json:"actor"`
}

// splitHoldout draws percent of members, at random, to hold out.
func splitHoldout(members []segments.Profile, percent int) ([]control.CustomerOfferRecipient, error) {
	out := make([]control.CustomerOfferRecipient, len(members))
	for i, member := range members {
		out[i] = control.CustomerOfferRecipient{CustomerID: member.CustomerID, Segment: member.Segment}
	}
	held := len(members) * percent / 100
	// Fisher–Yates over a cryptographic source: nobody chooses who is held.
	for i := len(out) - 1; i > 0; i-- {
		j, err := rand.Int(rand.Reader, big.NewInt(int64(i+1)))
		if err != nil {
			return nil, err
		}
		out[i], out[int(j.Int64())] = out[int(j.Int64())], out[i]
	}
	for i := 0; i < held; i++ {
		out[i].Holdout = true
	}
	return out, nil
}

func (s HTTPServer) handleCustomerAdminCreateOffer(w http.ResponseWriter, r *http.Request, admin customerAdminStore) {
	store, insights, ok := s.customerOfferStore(w)
	if !ok {
		return
	}
	var request customerOfferRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	everyone := request.Audience == control.CustomerOfferForEveryone
	keys, ok := requestedSegments(request.Segments)
	if everyone {
		// Every customer: told all at once, if told; none held out.
		keys, ok = map[string]bool{}, len(request.Segments) == 0
		for _, key := range segments.Keys {
			keys[key] = true
		}
	}
	if !ok {
		writeCustomerError(w, http.StatusBadRequest, "invalid_segments", "segments must name one known segment or more (none for everyone)", nil)
		return
	}
	var notice control.CustomerOfferNotice
	if request.Notify != nil {
		link, ok := customerNotificationLink(request.Notify.Link)
		title, body := strings.TrimSpace(request.Notify.Title), strings.TrimSpace(request.Notify.Body)
		if !ok || (title == "") != (body == "") {
			writeCustomerError(w, http.StatusBadRequest, "invalid_notification",
				"a notification needs a title, words and a https://cards.dftr.ly/… link or none", nil)
			return
		}
		if s.CustomerPush == nil && (title != "" || request.Notify.Remind) {
			writeCustomerError(w, http.StatusServiceUnavailable, "push_unconfigured", "notifications are not configured", nil)
			return
		}
		notice = control.CustomerOfferNotice{Title: title, Body: body, Link: link, Remind: request.Notify.Remind}
	}
	segmentation, err := s.customerSegmentation(r, insights, true)
	if err != nil {
		s.customerInternalError(w, "customer segmentation failed", err)
		return
	}
	members := segmentation.members(keys, false)
	var recipients []control.CustomerOfferRecipient
	names := []string{}
	if !everyone {
		if recipients, err = splitHoldout(members, max(request.HoldoutPercent, 0)); err != nil {
			s.customerInternalError(w, "offer holdout failed", err)
			return
		}
		for key := range keys {
			names = append(names, key)
		}
	}
	offer := control.CustomerOffer{
		Name: request.Name, Title: request.Title, Description: request.Description, Kind: request.Kind,
		Value: request.Value, MaxDiscount: request.MaxDiscount, MinOrder: request.MinOrder, Segments: names,
		UsesPerCustomer: request.UsesPerCustomer, MaxRedemptions: request.MaxRedemptions,
		EndsAt: request.EndsAt, HoldoutPercent: request.HoldoutPercent, CreatedBy: adminActor(r, request.Actor),
		Audience: request.Audience, Tiers: request.Tiers, TierUnit: request.TierUnit, BuyQuantity: request.BuyQuantity,
		GetQuantity: request.GetQuantity, GetPercent: request.GetPercent, Scope: request.Scope, Badge: request.Badge,
		Budget: request.Budget, Notice: notice,
	}
	if request.StartsAt != nil {
		offer.StartsAt = *request.StartsAt
	}
	created, err := store.CreateCustomerOffer(r.Context(), offer, recipients)
	if customerOfferError(w, err) {
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer offer create failed", err)
		return
	}
	s.forgetCustomerSegmentation()
	s.logger().Info("operator made an offer", "offer_id", created.ID, "kind", created.Kind, "audience", created.Audience,
		"segments", strings.Join(created.Segments, ","), "recipients", created.Recipients, "holdouts", created.Holdouts,
		"actor", created.CreatedBy)
	payload := map[string]any{"offer": created}
	// Told now when it starts now: the operator asked for it. One that starts
	// later is told then, in the day (customer_offer_notices.go).
	if offerNoticeDue(created, s.clock().Now()) == control.CustomerOfferLaunchNotice {
		record, err := s.sendOfferNotice(context.WithoutCancel(r.Context()), created, control.CustomerOfferLaunchNotice, created.CreatedBy)
		if err != nil {
			s.logger().Warn("offer launch notice failed", "offer_id", created.ID, "error", err)
		} else if record != nil {
			payload["notification"] = record
		}
		if fresh, err := store.GetCustomerOffer(r.Context(), created.ID); err == nil {
			payload["offer"] = fresh
		}
	}
	writeJSON(w, http.StatusCreated, payload)
}

func (s HTTPServer) handleCustomerAdminUpdateOffer(w http.ResponseWriter, r *http.Request, id string) {
	store, _, ok := s.customerOfferStore(w)
	if !ok {
		return
	}
	var request struct {
		Name        *string          `json:"name"`
		Title       *string          `json:"title"`
		Description *string          `json:"description"`
		Badge       *string          `json:"badge"`
		EndsAt      optionalTimeJSON `json:"ends_at"`
		Active      *bool            `json:"active"`
		Remind      *bool            `json:"remind"`
	}
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	update := control.CustomerOfferUpdate{Name: request.Name, Title: request.Title, Description: request.Description,
		Badge: request.Badge, Active: request.Active, Remind: request.Remind}
	if request.EndsAt.set {
		update.EndsAt = &request.EndsAt.value
	}
	updated, err := store.UpdateCustomerOffer(r.Context(), id, update)
	if customerOfferError(w, err) {
		return
	}
	if err != nil {
		s.customerInternalError(w, "customer offer update failed", err)
		return
	}
	s.forgetCustomerSegmentation()
	writeJSON(w, http.StatusOK, map[string]any{"offer": updated})
}

// optionalTimeJSON tells a time left out from one set to null (no end).
type optionalTimeJSON struct {
	set   bool
	value *time.Time
}

func (o *optionalTimeJSON) UnmarshalJSON(raw []byte) error {
	o.set = true
	if string(raw) == "null" {
		o.value = nil
		return nil
	}
	var at time.Time
	if err := at.UnmarshalJSON(raw); err != nil {
		return err
	}
	o.value = &at
	return nil
}

// customerOfferView is an offer as the app reads it: its terms, scope and
// badge, never who it was made for.
func customerOfferView(offer control.CustomerOffer, usesLeft int) map[string]any {
	return map[string]any{
		"id": offer.ID, "title": offer.Title, "description": offer.Description, "kind": offer.Kind,
		"value": offer.Value, "max_discount": offer.MaxDiscount, "min_order": offer.MinOrder,
		"tiers": offer.Tiers, "tier_unit": offer.TierUnit, "buy_quantity": offer.BuyQuantity,
		"get_quantity": offer.GetQuantity, "get_percent": offer.GetPercent, "scope": offer.Scope,
		"badge": offer.Badge, "ends_at": offer.EndsAt, "uses_left": usesLeft,
		"for_everyone": offer.Audience == control.CustomerOfferForEveryone,
	}
}

// handleCustomerOffers serves GET /v1/customers/me/offers: the offers this
// customer can use now, for the badges on the shelf and the checkout.
func (s HTTPServer) handleCustomerOffers(w http.ResponseWriter, r *http.Request, customer control.Customer) {
	store, ok := s.Store.(control.CustomerOfferStore)
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"offers": []any{}})
		return
	}
	offers, err := store.CustomerOffersFor(r.Context(), customer.ID, s.clock().Now())
	if err != nil {
		s.customerInternalError(w, "customer offers failed", err)
		return
	}
	views := make([]map[string]any, 0, len(offers))
	for _, offer := range offers {
		views = append(views, customerOfferView(offer.CustomerOffer, offer.UsesLeft))
	}
	writeJSON(w, http.StatusOK, map[string]any{"offers": views})
}

// handlePublicCustomerOffers serves GET /v1/customers/offers: the offers for
// everyone, for a visitor who has not signed in (they sign in to use one).
func (s HTTPServer) handlePublicCustomerOffers(w http.ResponseWriter, r *http.Request) {
	store, ok := s.Store.(control.CustomerOfferStore)
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"offers": []any{}})
		return
	}
	offers, err := store.PublicCustomerOffers(r.Context(), s.clock().Now())
	if err != nil {
		s.customerInternalError(w, "public offers failed", err)
		return
	}
	views := make([]map[string]any, 0, len(offers))
	for _, offer := range offers {
		views = append(views, customerOfferView(offer, offer.UsesPerCustomer))
	}
	// The same for every visitor, for a minute.
	w.Header().Set("Cache-Control", "public, max-age=60")
	writeJSON(w, http.StatusOK, map[string]any{"offers": views})
}

// notifySegments sends a notification to every reachable customer of the
// segments named (POST /v1/customers/admin/notifications, audience
// "segments"), and records it as sent to "segments:<keys>".
func (s HTTPServer) notifySegments(w http.ResponseWriter, r *http.Request, store customerAdminStore, keys []string, title, body, rawLink, campaign, actor string) {
	insights, ok := s.customerInsightStore(w)
	if !ok {
		return
	}
	chosen, ok := requestedSegments(keys)
	if !ok {
		writeCustomerError(w, http.StatusBadRequest, "invalid_segments", "segments must name one known segment or more", nil)
		return
	}
	link, ok := customerNotificationLink(rawLink)
	if !ok {
		writeCustomerError(w, http.StatusBadRequest, "invalid_link", "a link must be a https://cards.dftr.ly/… address", nil)
		return
	}
	segmentation, err := s.customerSegmentation(r, insights, true)
	if err != nil {
		s.customerInternalError(w, "customer segmentation failed", err)
		return
	}
	members := segmentation.members(chosen, true)
	ids := make([]string, 0, len(members))
	for _, member := range members {
		ids = append(ids, member.CustomerID)
	}
	names := make([]string, 0, len(chosen))
	for key := range chosen {
		names = append(names, key)
	}
	sort.Strings(names)
	message := fcm.Message{Title: title, Body: body, Link: link, Campaign: strings.TrimSpace(campaign)}
	record := control.CustomerNotification{
		Audience: "segments:" + strings.Join(names, ","), Title: title, Body: body, Link: link,
		Campaign: message.Campaign, SentBy: adminActor(r, actor),
	}
	ctx := r.Context()
	if err := s.pushToCustomers(context.WithoutCancel(ctx), store, ids, message, &record); err != nil {
		s.customerInternalError(w, "segment notification failed", err)
		return
	}
	if record.Devices == 0 {
		writeCustomerError(w, http.StatusConflict, "no_devices", "no customer in these segments accepts notifications", nil)
		return
	}
	stored, err := store.RecordCustomerNotification(ctx, record)
	if err != nil {
		s.customerInternalError(w, "customer notification log failed", err)
		return
	}
	s.logger().Info("operator notified segments", "segments", strings.Join(names, ","), "customers", len(ids),
		"sent", record.Sent, "failed", record.Failed, "actor", record.SentBy)
	status := http.StatusOK
	if record.Sent == 0 {
		status = http.StatusBadGateway
	}
	writeJSON(w, status, map[string]any{"notification": stored, "customers": len(ids)})
}

// customerOffer reads an offer, for an order naming it.
func (s HTTPServer) customerOffer(ctx context.Context, id string) (control.CustomerOffer, error) {
	store, ok := s.Store.(control.CustomerOfferStore)
	if !ok {
		return control.CustomerOffer{}, control.ErrCustomerOfferUnavailable
	}
	return store.GetCustomerOffer(ctx, id)
}

func orZeroAmount(value string) string {
	if strings.TrimSpace(value) == "" {
		return control.FormatWalletAmount(new(big.Rat))
	}
	return value
}
