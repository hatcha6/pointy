package relay

import (
	"context"
	"errors"
	"math/big"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// eSIM promotions: a percentage off a destination's plans, or the whole
// shelf's, for a time. The operator writes them in the console; the shelf, a
// destination's page and the order's quote all read the same offer, so the
// price shown is the price charged.
//
//	GET /v1/customers/admin/esim-promos   the list, and the destinations to pick from
//	PUT /v1/customers/admin/esim-promos   {promos}: replaces the list

// esimPromosTTL is how long the promotions are believed before the store is
// read again. A change from this relay's console is seen at once.
const esimPromosTTL = 30 * time.Second

// esimPromoStep is what a promotion's price is rounded up to, in dinars.
var esimPromoStep = big.NewRat(1, 4)

// esimPromosNow is the promotions as stored, read at most every esimPromosTTL.
// A store that cannot be read sells at the regular price.
func (s HTTPServer) esimPromosNow(ctx context.Context) []control.ESIMPromo {
	store, ok := s.Store.(control.ESIMPromoStore)
	state := s.ESIM.state
	if !ok || state == nil {
		return nil
	}
	now := s.clock().Now()
	state.mu.Lock()
	if !state.promosAt.IsZero() && now.Sub(state.promosAt) < esimPromosTTL {
		promos := state.promos
		state.mu.Unlock()
		return promos
	}
	state.mu.Unlock()
	settings, err := store.ESIMPromos(ctx)
	if err != nil {
		s.logger().Warn("reading the eSIM promotions failed", "error", err)
		return nil
	}
	state.mu.Lock()
	state.promos, state.promosAt = settings.Promos, now
	state.mu.Unlock()
	return settings.Promos
}

func (s HTTPServer) forgetESIMPromos() {
	if state := s.ESIM.state; state != nil {
		state.mu.Lock()
		state.promosAt = time.Time{}
		state.mu.Unlock()
	}
}

// esimOffer is what a plan sells for now: Price, and when a promotion runs on
// it, the Regular price it is cut from and the Promo doing it.
type esimOffer struct {
	Price, Regular *big.Rat
	Promo          *control.ESIMPromo
}

// fields writes the offer into a plan's or a row's answer.
func (o esimOffer) fields(into map[string]any, priceKey string) {
	into[priceKey] = control.FormatWalletAmount(o.Price)
	if o.Promo != nil {
		into["regular_"+priceKey] = control.FormatWalletAmount(o.Regular)
		into["promo"] = esimPromoBody(*o.Promo)
	}
}

func esimPromoBody(promo control.ESIMPromo) map[string]any {
	return map[string]any{"badge": promo.Badge, "percent": promo.Percent, "ends_at": promo.EndsAt}
}

// promoFor is the deepest promotion running on destination now.
func (p esimPricing) promoFor(destination string) *control.ESIMPromo {
	var best *control.ESIMPromo
	for i := range p.promos {
		promo := &p.promos[i]
		if !promo.Running(p.now) || (promo.Destination != "" && !strings.EqualFold(promo.Destination, destination)) {
			continue
		}
		if best == nil || promo.Percent > best.Percent {
			best = promo
		}
	}
	return best
}

// offer is plan's price with destination's promotion taken off. A promotion
// never sells under what the margin asks on the plan's real cost: where it
// would, the price stops there, and a promotion that takes nothing off is not
// shown as one.
func (p esimPricing) offer(destination string, plan esimPlan) (esimOffer, bool) {
	regular, ok := p.price(plan)
	if !ok {
		return esimOffer{}, false
	}
	offer := esimOffer{Price: regular, Regular: regular}
	promo := p.promoFor(destination)
	if promo == nil {
		return offer, true
	}
	cut := new(big.Rat).Mul(regular, big.NewRat(int64(100-promo.Percent), 100))
	steps := new(big.Rat).Quo(cut, esimPromoStep)
	whole := new(big.Int).Div(steps.Num(), steps.Denom())
	if !steps.IsInt() {
		whole.Add(whole, big.NewInt(1))
	}
	cut = new(big.Rat).Mul(new(big.Rat).SetInt(whole), esimPromoStep)
	net := vouchers.AiraloDollars(plan.NetUSD)
	if net == nil {
		return offer, true
	}
	floor, ok := p.margin.Prices(new(big.Rat).Mul(net, p.rate))
	if !ok || floor.Retail == nil {
		return offer, true
	}
	if cut.Cmp(floor.Retail) < 0 {
		cut = floor.Retail
	}
	if cut.Cmp(regular) >= 0 {
		return offer, true
	}
	offer.Price, offer.Promo = cut, promo
	return offer, true
}

// promoFingerprint names the promotions running now, so a shelf cached before
// one started or ended is stale.
func (p esimPricing) promoFingerprint() string {
	var parts []string
	for _, promo := range p.promos {
		if promo.Running(p.now) {
			parts = append(parts, promo.ID+":"+promo.Destination+":"+strconv.Itoa(promo.Percent)+":"+promo.Badge+":"+promo.EndsAt.Format(time.RFC3339))
		}
	}
	sort.Strings(parts)
	return strings.Join(parts, ",")
}

// --- console ---------------------------------------------------------------

func (s HTTPServer) esimPromoStore(w http.ResponseWriter) (control.ESIMPromoStore, bool) {
	store, ok := s.Store.(control.ESIMPromoStore)
	if !ok {
		writeCustomerError(w, http.StatusServiceUnavailable, "customers_unconfigured", "this relay keeps no customers", nil)
	}
	return store, ok
}

// esimPromoAnswer is the list as the console shows it: each promotion with
// what it does today to its cheapest plan, and the destinations to pick from.
func (s HTTPServer) esimPromoAnswer(ctx context.Context, settings control.ESIMPromoSettings) map[string]any {
	destinations := []map[string]any{}
	catalog := s.esimCatalogNow(ctx)
	pricing, priced := s.esimPricingNow(ctx)
	if catalog != nil {
		for _, destination := range catalog.Destinations {
			row := map[string]any{"key": destination.Key, "name": destination.Name, "kind": destination.Kind, "country": destination.Country}
			if priced {
				var from *big.Rat
				for _, plan := range destination.Plans {
					if price, ok := pricing.price(plan); ok && (from == nil || price.Cmp(from) < 0) {
						from = price
					}
				}
				if from != nil {
					row["from_price"] = control.FormatWalletAmount(from)
				}
			}
			destinations = append(destinations, row)
		}
	}
	now := s.clock().Now()
	promos := make([]map[string]any, 0, len(settings.Promos))
	for _, promo := range settings.Promos {
		state := "scheduled"
		switch {
		case promo.Running(now):
			state = "running"
		case !now.Before(promo.EndsAt):
			state = "ended"
		}
		row := map[string]any{
			"id": promo.ID, "destination": promo.Destination, "percent": promo.Percent, "badge": promo.Badge,
			"starts_at": promo.StartsAt, "ends_at": promo.EndsAt, "state": state,
		}
		// How many plans it really cuts, and how many the floor holds back.
		if catalog != nil && priced {
			only := pricing
			only.promos, only.now = []control.ESIMPromo{promo}, promo.StartsAt
			cut, held := 0, 0
			for _, destination := range catalog.Destinations {
				if promo.Destination != "" && !strings.EqualFold(promo.Destination, destination.Key) {
					continue
				}
				for _, plan := range destination.Plans {
					offer, ok := only.offer(destination.Key, plan)
					if !ok {
						continue
					}
					full := new(big.Rat).Mul(offer.Regular, big.NewRat(int64(100-promo.Percent), 100))
					if offer.Promo == nil || new(big.Rat).Sub(offer.Price, full).Cmp(esimPromoStep) > 0 {
						held++
					}
					if offer.Promo != nil {
						cut++
					}
				}
			}
			row["plans_cut"], row["plans_held"] = cut, held
		}
		promos = append(promos, row)
	}
	return map[string]any{
		"promos": promos, "actor": settings.Actor, "updated_at": settings.UpdatedAt,
		"destinations": destinations, "max_percent": control.MaxESIMPromoPercent,
	}
}

func (s HTTPServer) handleCustomerAdminESIMPromos(w http.ResponseWriter, r *http.Request) {
	store, ok := s.esimPromoStore(w)
	if !ok {
		return
	}
	settings, err := store.ESIMPromos(r.Context())
	if err != nil {
		s.customerInternalError(w, "eSIM promotions read failed", err)
		return
	}
	writeJSON(w, http.StatusOK, s.esimPromoAnswer(r.Context(), settings))
}

// handleCustomerAdminSetESIMPromos replaces the promotions. One on a
// destination the shelf does not have is refused: it would never run.
func (s HTTPServer) handleCustomerAdminSetESIMPromos(w http.ResponseWriter, r *http.Request) {
	store, ok := s.esimPromoStore(w)
	if !ok {
		return
	}
	var request struct {
		Promos []control.ESIMPromo `json:"promos"`
		Actor  string              `json:"actor"`
	}
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	if catalog := s.esimCatalogNow(r.Context()); catalog != nil {
		for _, promo := range request.Promos {
			key := strings.ToLower(strings.TrimSpace(promo.Destination))
			if key == "" {
				continue
			}
			if _, found := catalog.destination(key); !found {
				writeCustomerError(w, http.StatusBadRequest, "invalid_promo", "no such destination: "+key, nil)
				return
			}
		}
	}
	settings, err := store.SetESIMPromos(r.Context(), control.ESIMPromoSettings{
		Promos: request.Promos, Actor: adminActor(r, request.Actor),
	})
	if errors.Is(err, control.ErrInvalidESIMPromo) {
		writeCustomerError(w, http.StatusBadRequest, "invalid_promo", err.Error(), nil)
		return
	}
	if err != nil {
		s.customerInternalError(w, "eSIM promotions write failed", err)
		return
	}
	s.forgetESIMPromos()
	s.logger().Info("operator changed the eSIM promotions", "promotions", len(settings.Promos), "actor", settings.Actor)
	writeJSON(w, http.StatusOK, s.esimPromoAnswer(r.Context(), settings))
}
