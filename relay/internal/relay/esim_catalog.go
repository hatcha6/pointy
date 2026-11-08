package relay

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/airalo"
	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
	"pointy/relay/internal/vouchers"
)

// The eSIM shelf of «دفتر كروت», from Airalo's Partner API:
//
//	GET  /v1/customers/esim/destinations         where eSIMs are sold, with a "from" price (public)
//	GET  /v1/customers/esim/destinations/{key}   a destination's plans (public)
//	POST /v1/customers/esim/device               does this phone model take eSIMs? (public)
//	GET  /v1/customers/esims[?order=]            the customer's eSIMs (Bearer)
//	GET  /v1/customers/esims/{iccid}             one eSIM: how to install it, what is left (Bearer)
//	PUT  /v1/customers/esims/{iccid}             {label}: who it is for (Bearer)
//	GET  /v1/customers/esims/{iccid}/topups      what it can be topped up with (Bearer)
//	HEAD|POST /v1/customers/esim/webhook         Airalo's low-data and credit alerts (signed)
//
// An eSIM is bought with POST /v1/customers/orders like any card, with the item
// a plan names: see esim_orders.go.

// ESIMConfig is the eSIM shelf. The zero value leaves it off, and the app
// shows no eSIMs.
type ESIMConfig struct {
	// Client is the company's Airalo account. Nil: no eSIMs, unless the
	// vouchers run in test mode and a catalog was stored.
	Client *airalo.Client
	// RRPPercent is the share of Airalo's recommended retail price the shelf
	// sells at. Nil: 100.
	RRPPercent *big.Rat
	// Sandbox marks the Airalo account as being in Sandbox mode: nothing real
	// is issued, so its orders are test money on the books.
	Sandbox bool
	// WebhookURL is where Airalo posts its alerts (this relay's public
	// address plus /v1/customers/esim/webhook). Empty: never opted in.
	WebhookURL string
	// DeviceRateLimit bounds the public device check per address.
	DeviceRateLimit ratelimit.Policy

	// Shared state; New builds it.
	state *esimState
}

// NewESIMConfig completes a config with its shared state.
func NewESIMConfig(config ESIMConfig) ESIMConfig {
	config.state = &esimState{devices: map[string]esimDeviceAnswer{}, topups: map[string]esimTopUpsAnswer{}}
	return config
}

func (c ESIMConfig) rrpPercent() *big.Rat {
	if c.RRPPercent != nil {
		return c.RRPPercent
	}
	return big.NewRat(100, 1)
}

// esimState is what the handlers share, in memory.
type esimState struct {
	mu        sync.Mutex
	version   string
	checkedAt time.Time
	catalog   *esimCatalog

	devices map[string]esimDeviceAnswer
	topups  map[string]esimTopUpsAnswer
}

// --- the catalog -----------------------------------------------------------

// Destination kinds.
const (
	esimKindLocal    = "local"
	esimKindRegional = "regional"
	esimKindGlobal   = "global"
)

const (
	// esimCatalogRecheck is how often a node asks whether the stored catalog
	// moved on: a version read, not the whole document.
	esimCatalogRecheck = time.Minute
	// esimSyncInterval: "packages synced hourly" on Airalo's go-live checklist.
	esimSyncInterval = time.Hour
	// esimSyncSkip leaves a sync to the node that just did it.
	esimSyncSkip = 50 * time.Minute
)

// esimCatalog is Airalo's catalog cut down to what the shelf shows and sells.
type esimCatalog struct {
	Destinations []esimDestination `json:"destinations"`
}

type esimDestination struct {
	Key       string        `json:"key"`
	Kind      string        `json:"kind"`
	Country   string        `json:"country,omitempty"`
	Name      string        `json:"name"`
	Image     string        `json:"image,omitempty"`
	Countries []esimCountry `json:"countries,omitempty"`
	Plans     []esimPlan    `json:"plans"`
}

type esimCountry struct {
	Code     string   `json:"code"`
	Name     string   `json:"name"`
	Networks []string `json:"networks,omitempty"`
}

type esimPlan struct {
	ID        string  `json:"id"`
	Title     string  `json:"title"`
	Data      string  `json:"data"`
	AmountMB  int     `json:"amount_mb"`
	Days      int     `json:"days"`
	Unlimited bool    `json:"unlimited,omitempty"`
	Voice     int     `json:"voice,omitempty"`
	Text      int     `json:"text,omitempty"`
	NetUSD    float64 `json:"net_usd"`
	RetailUSD float64 `json:"retail_usd"`
	Info      string  `json:"info,omitempty"`
	Operator  string  `json:"operator"`
	// PlanType is "data" or "data-voice-text" as Airalo writes it.
	PlanType     string `json:"plan_type,omitempty"`
	Rechargeable bool   `json:"rechargeable"`
	// ActivationPolicy: when the validity starts ("first-usage", "installation").
	ActivationPolicy string `json:"activation_policy,omitempty"`
	// InstallWindowDays: an eSIM not installed in this time is recycled.
	InstallWindowDays int `json:"install_window_days,omitempty"`
	// TopUpGraceDays: after the plan ends, how long a top-up can still revive it.
	TopUpGraceDays int    `json:"topup_grace_days,omitempty"`
	OtherInfo      string `json:"other_info,omitempty"`
}

func (c *esimCatalog) find(packageID string) (esimDestination, esimPlan, bool) {
	for _, destination := range c.Destinations {
		for _, plan := range destination.Plans {
			if plan.ID == packageID {
				return destination, plan, true
			}
		}
	}
	return esimDestination{}, esimPlan{}, false
}

func (c *esimCatalog) destination(key string) (esimDestination, bool) {
	for _, destination := range c.Destinations {
		if destination.Key == key {
			return destination, true
		}
	}
	return esimDestination{}, false
}

// shapeESIMCatalog cuts Airalo's answer down. A plan that needs identity checks
// is left off (the partner catalog has no-eKYC variants of those).
func shapeESIMCatalog(pricing airalo.Pricing, destinations []airalo.Destination) esimCatalog {
	// Airalo names a coverage's country by its code alone; the same catalog has
	// each country's own entry, under its name in the language asked for.
	names := map[string]string{}
	for _, source := range destinations {
		if code := strings.ToUpper(strings.TrimSpace(source.CountryCode)); code != "" {
			names[code] = strings.TrimSpace(source.Title)
		}
	}
	catalog := esimCatalog{Destinations: make([]esimDestination, 0, len(destinations))}
	for _, source := range destinations {
		destination := esimDestination{
			Key:     strings.TrimSpace(source.Slug),
			Kind:    esimKindRegional,
			Country: strings.ToUpper(strings.TrimSpace(source.CountryCode)),
			Name:    strings.TrimSpace(source.Title),
			Image:   source.Image.URL,
			Plans:   []esimPlan{},
		}
		switch {
		case destination.Country != "":
			destination.Kind = esimKindLocal
		case destination.Key == "world" || strings.HasPrefix(destination.Key, "world"):
			destination.Kind = esimKindGlobal
		}
		countries := map[string]esimCountry{}
		for _, operator := range source.Operators {
			if operator.KYC {
				continue
			}
			for _, coverage := range operator.Coverages {
				country := countries[coverage.Code]
				country.Code, country.Name = coverage.Code, firstNonEmpty(names[strings.ToUpper(coverage.Code)], coverage.Name)
				for _, network := range coverage.Networks {
					if network.Name != "" && !containsString(country.Networks, network.Name) {
						country.Networks = append(country.Networks, network.Name)
					}
				}
				if coverage.Code != "" {
					countries[coverage.Code] = country
				}
			}
			info := ""
			if len(operator.Info) > 0 {
				info = strings.Join(operator.Info, " · ")
			}
			if destination.Image == "" {
				destination.Image = operator.Image.URL
			}
			for _, source := range operator.Packages {
				if source.Type != "" && source.Type != "sim" {
					continue
				}
				plan := esimPlan{
					ID: source.ID, Title: source.Title, Data: esimDataLabel(source),
					AmountMB: source.AmountMB.Int(), Days: source.Days.Int(),
					Unlimited: source.Unlimited, Voice: source.Voice.Int(), Text: source.Text.Int(),
					NetUSD:    pricing.CostUSD(source),
					RetailUSD: airaloPlanRetail(source),
					Info:      firstNonEmpty(source.ShortInfo, info),
					Operator:  operator.Title, PlanType: operator.PlanType,
					Rechargeable: operator.Rechargeable, ActivationPolicy: operator.ActivationPolicy,
					InstallWindowDays: operator.InstallWindow.Int(), TopUpGraceDays: operator.TopUpGrace.Int(),
					OtherInfo: operator.OtherInfo,
				}
				if plan.ID != "" && plan.NetUSD > 0 {
					destination.Plans = append(destination.Plans, plan)
				}
			}
		}
		if destination.Key == "" || destination.Name == "" || len(destination.Plans) == 0 {
			continue
		}
		sort.SliceStable(destination.Plans, func(i, j int) bool {
			a, b := destination.Plans[i], destination.Plans[j]
			if a.Unlimited != b.Unlimited {
				return b.Unlimited
			}
			if a.AmountMB != b.AmountMB {
				return a.AmountMB < b.AmountMB
			}
			return a.Days < b.Days
		})
		destination.Countries = make([]esimCountry, 0, len(countries))
		for _, country := range countries {
			destination.Countries = append(destination.Countries, country)
		}
		sort.Slice(destination.Countries, func(i, j int) bool { return destination.Countries[i].Code < destination.Countries[j].Code })
		catalog.Destinations = append(catalog.Destinations, destination)
	}
	sort.SliceStable(catalog.Destinations, func(i, j int) bool { return catalog.Destinations[i].Key < catalog.Destinations[j].Key })
	return catalog
}

// esimDataLabel is a plan's amount as the app shows it, the same on every plan and
// in every language: "1 GB", "500 MB". Airalo's own text is translated ("1 غيغا
// بايت") and reads backwards among Arabic words. An unlimited plan has none.
func esimDataLabel(source airalo.Package) string {
	if source.Unlimited {
		return ""
	}
	megabytes := source.AmountMB.Int()
	switch {
	case megabytes <= 0:
		return source.Data
	case megabytes < 1024:
		return fmt.Sprintf("%d MB", megabytes)
	case megabytes%1024 == 0:
		return fmt.Sprintf("%d GB", megabytes/1024)
	}
	return fmt.Sprintf("%.1f GB", float64(megabytes)/1024)
}

// airaloPlanRetail is Airalo's recommended price in dollars.
func airaloPlanRetail(source airalo.Package) float64 {
	if retail := source.Prices.Recommended["USD"]; retail > 0 {
		return retail
	}
	return numberFloat(source.Price)
}

func numberFloat(number airalo.Number) float64 {
	rat, ok := new(big.Rat).SetString(strings.TrimSpace(number.String()))
	if !ok {
		return 0
	}
	value, _ := rat.Float64()
	return value
}

// esimCatalogNow is the stored catalog, re-read when another node's sync moved
// it on. Nil when there is none.
func (s HTTPServer) esimCatalogNow(ctx context.Context) *esimCatalog {
	state := s.ESIM.state
	store, ok := s.Store.(control.CustomerESIMStore)
	if state == nil || !ok {
		return nil
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	now := s.clock().Now()
	if state.catalog != nil && now.Sub(state.checkedAt) < esimCatalogRecheck {
		return state.catalog
	}
	version, _, err := store.ESIMCatalogVersion(ctx)
	if err != nil {
		s.logger().Warn("reading the eSIM catalog version failed", "error", err)
		return state.catalog
	}
	state.checkedAt = now
	if version == "" || version == state.version {
		return state.catalog
	}
	stored, err := store.ReadESIMCatalog(ctx)
	if err != nil {
		s.logger().Warn("reading the eSIM catalog failed", "error", err)
		return state.catalog
	}
	var catalog esimCatalog
	if err := json.Unmarshal([]byte(stored.Document), &catalog); err != nil {
		s.logger().Error("the stored eSIM catalog does not read", "error", err)
		return state.catalog
	}
	state.catalog, state.version = &catalog, stored.Version
	return state.catalog
}

// syncESIMCatalog reads the catalog from Airalo and stores it. A read that
// finds nothing keeps what is stored: an outage must not empty the shelf.
func (s HTTPServer) syncESIMCatalog(ctx context.Context, store control.CustomerESIMStore) error {
	pricing, destinations, err := s.ESIM.Client.Packages(ctx, "ar")
	if err != nil {
		return err
	}
	catalog := shapeESIMCatalog(pricing, destinations)
	if len(catalog.Destinations) == 0 {
		s.logger().Error("Airalo answered an empty catalog; keeping the stored one")
		return nil
	}
	raw, err := json.Marshal(catalog)
	if err != nil {
		return err
	}
	digest := sha256.Sum256(raw)
	if err := store.SaveESIMCatalog(ctx, control.ESIMCatalogDocument{
		Version: hex.EncodeToString(digest[:12]), Document: string(raw), SyncedAt: s.clock().Now(),
	}); err != nil {
		return err
	}
	if state := s.ESIM.state; state != nil {
		state.mu.Lock()
		state.checkedAt = time.Time{}
		state.mu.Unlock()
	}
	s.logger().Info("eSIM catalog synced", "destinations", len(catalog.Destinations))
	return nil
}

// ensureESIMWebhooks opts the webhook in, for low-data alerts (customers hear
// them, and are asked to top up) and credit alerts (the operator hears them).
func (s HTTPServer) ensureESIMWebhooks(ctx context.Context) {
	if s.ESIM.WebhookURL == "" {
		return
	}
	for _, kind := range []string{airalo.NotifyLowData, airalo.NotifyCreditLimit} {
		current, found, err := s.ESIM.Client.Notification(ctx, kind)
		if err != nil {
			s.logger().Warn("reading an Airalo opt-in failed", "kind", kind, "error", err)
			continue
		}
		if found && current.ContactPoint == s.ESIM.WebhookURL {
			continue
		}
		if err := s.ESIM.Client.OptIn(ctx, kind, s.ESIM.WebhookURL); err != nil {
			s.logger().Error("opting in to an Airalo webhook failed", "kind", kind, "error", err)
			continue
		}
		s.logger().Info("opted in to an Airalo webhook", "kind", kind)
	}
}

// ESIMCatalogSync keeps the catalog an hour fresh at most, as Airalo asks, and
// the webhooks opted in. Every node runs it; one that finds the catalog just
// synced leaves it.
type ESIMCatalogSync struct {
	Server   HTTPServer
	Interval time.Duration
	Logger   *slog.Logger
}

// Run syncs until ctx ends.
func (e *ESIMCatalogSync) Run(ctx context.Context) {
	interval := e.Interval
	if interval <= 0 {
		interval = esimSyncInterval
	}
	e.once(ctx)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			e.once(ctx)
		}
	}
}

func (e *ESIMCatalogSync) once(ctx context.Context) {
	store, ok := e.Server.Store.(control.CustomerESIMStore)
	if !ok || e.Server.ESIM.Client == nil {
		return
	}
	callCtx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	e.Server.ensureESIMWebhooks(callCtx)
	if _, syncedAt, err := store.ESIMCatalogVersion(callCtx); err == nil &&
		!syncedAt.IsZero() && e.Server.clock().Now().Sub(syncedAt) < esimSyncSkip {
		return
	}
	if err := e.Server.syncESIMCatalog(callCtx, store); err != nil {
		e.Server.logger().Error("syncing the eSIM catalog failed", "error", err)
	}
	if balance, found, err := e.Server.ESIM.Client.Balance(callCtx); err == nil && found {
		e.Server.logger().Info("Airalo balance", "amount", balance.Amount, "currency", balance.Currency)
	}
}

// --- prices ----------------------------------------------------------------

// esimPricing is what prices are worked out with right now.
type esimPricing struct {
	rate   *big.Rat
	margin vouchers.Margin
	rrp    *big.Rat
}

// esimPricingNow reads the dollar rate and the margin the cards are priced with.
// ok is false without a dollar rate: nothing is sold on a guess.
func (s HTTPServer) esimPricingNow(ctx context.Context) (esimPricing, bool) {
	cards, ok := s.voucherStore()
	if !ok {
		return esimPricing{}, false
	}
	settings, err := s.voucherSettingsForCards(ctx, cards)
	if err != nil {
		return esimPricing{}, false
	}
	rate, _ := settings.EffectiveUSDRate()
	if rate == nil || rate.Sign() <= 0 {
		return esimPricing{}, false
	}
	return esimPricing{rate: rate, margin: settings.MarginFor(vouchers.ServiceKindCard), rrp: s.ESIM.rrpPercent()}, true
}

func (p esimPricing) price(netUSD, retailUSD float64) (*big.Rat, bool) {
	return vouchers.ESIMPrice(vouchers.AiraloDollars(netUSD), vouchers.AiraloDollars(retailUSD), p.rate, p.margin, p.rrp)
}

func (p esimPricing) fingerprint() string {
	raw, _ := json.Marshal(p.margin)
	return p.rate.RatString() + "|" + p.rrp.RatString() + "|" + string(raw)
}

// --- public routes ---------------------------------------------------------

// handleESIMDestinations serves the shelf's front page.
func (s HTTPServer) handleESIMDestinations(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	catalog := s.esimCatalogNow(ctx)
	pricing, priced := s.esimPricingNow(ctx)
	if catalog == nil || !priced || !s.esimSells() {
		writeJSON(w, http.StatusOK, map[string]any{"available": false, "destinations": []any{}})
		return
	}
	state := s.ESIM.state
	state.mu.Lock()
	version := state.version
	state.mu.Unlock()
	digest := sha256.Sum256([]byte(version + "|" + pricing.fingerprint()))
	etag := `"` + hex.EncodeToString(digest[:10]) + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "no-cache")
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	rows := make([]map[string]any, 0, len(catalog.Destinations))
	for _, destination := range catalog.Destinations {
		var from *big.Rat
		for _, plan := range destination.Plans {
			if price, ok := pricing.price(plan.NetUSD, plan.RetailUSD); ok && (from == nil || price.Cmp(from) < 0) {
				from = price
			}
		}
		if from == nil {
			continue
		}
		rows = append(rows, map[string]any{
			"key": destination.Key, "kind": destination.Kind, "country": destination.Country,
			"name": destination.Name, "image": destination.Image, "plans": len(destination.Plans),
			"countries":  len(destination.Countries),
			"from_price": control.FormatWalletAmount(from),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"available":    len(rows) > 0,
		"test_mode":    s.ESIM.Sandbox || s.Vouchers.MarksTest(),
		"destinations": rows,
	})
}

// While Airalo is in Sandbox the shelf is the stores' review account's alone:
// a Sandbox eSIM cannot be installed, and a customer's payment would be real.
// Everyone else is answered as if there were no shelf, on every route, so the
// app shows nothing; customers get the shelf when the relay moves to a live
// Airalo account. Disclose it in the review notes: it is a feature still in
// review with Airalo, not one hidden from the stores.

// esimOpenTo says whether customer may see and buy eSIMs.
func (s HTTPServer) esimOpenTo(customer control.Customer) bool {
	return !s.ESIM.Sandbox || s.Customers.isReviewPhone(customer.Phone)
}

// esimShelfVisible says whether the caller of a public eSIM route may see the
// shelf. answered is true when it already answered: a stale session is told to
// refresh, so the review account does not lose the shelf for an hour's token.
func (s HTTPServer) esimShelfVisible(w http.ResponseWriter, r *http.Request, store control.CustomerStore) (visible, answered bool) {
	if !s.ESIM.Sandbox {
		return true, false
	}
	raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	raw = strings.TrimSpace(raw)
	if !ok || !strings.HasPrefix(raw, customerAccessTokenPrefix+".") || store == nil {
		return false, false
	}
	customer, _, err := store.CustomerByAccessToken(r.Context(), control.TokenHash(raw))
	if errors.Is(err, control.ErrCustomerSessionNotFound) {
		writeCustomerError(w, http.StatusUnauthorized, "token_expired", "refresh the session", nil)
		return false, true
	}
	if err != nil {
		return false, false
	}
	return s.esimOpenTo(customer), false
}

// esimSells says whether a purchase can be made: from Airalo or, in test mode,
// from the test supplier.
func (s HTTPServer) esimSells() bool {
	return s.ESIM.Client != nil || s.Vouchers.TestMode
}

// handleESIMDestination serves one destination with its plans.
func (s HTTPServer) handleESIMDestination(w http.ResponseWriter, r *http.Request, key string) {
	ctx := r.Context()
	catalog := s.esimCatalogNow(ctx)
	pricing, priced := s.esimPricingNow(ctx)
	if catalog == nil || !priced {
		writeCustomerError(w, http.StatusNotFound, "esim_unavailable", "eSIMs are not on sale right now", nil)
		return
	}
	destination, found := catalog.destination(key)
	if !found {
		writeCustomerError(w, http.StatusNotFound, "unknown_destination", "no such destination", nil)
		return
	}
	plans := make([]map[string]any, 0, len(destination.Plans))
	for _, plan := range destination.Plans {
		price, ok := pricing.price(plan.NetUSD, plan.RetailUSD)
		if !ok {
			continue
		}
		plans = append(plans, map[string]any{
			"item": esimItemPrefix + plan.ID, "id": plan.ID, "title": plan.Title, "data": plan.Data,
			"amount_mb": plan.AmountMB, "days": plan.Days, "unlimited": plan.Unlimited,
			"voice": plan.Voice, "text": plan.Text, "info": plan.Info,
			"operator": plan.Operator, "plan_type": plan.PlanType, "rechargeable": plan.Rechargeable,
			"activation_policy":   plan.ActivationPolicy,
			"install_window_days": plan.InstallWindowDays,
			"topup_grace_days":    plan.TopUpGraceDays,
			"other_info":          plan.OtherInfo,
			"price":               control.FormatWalletAmount(price),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"key": destination.Key, "kind": destination.Kind, "country": destination.Country,
		"name": destination.Name, "image": destination.Image, "countries": destination.Countries,
		"plans": plans,
	})
}

// --- does this phone take eSIMs? --------------------------------------------

type esimDeviceAnswer struct {
	body map[string]any
	at   time.Time
}

const (
	esimDeviceTTL     = 24 * time.Hour
	esimDevicesKept   = 4096
	esimDeviceTimeout = 8 * time.Second
)

var esimDeviceModel = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 ,._+\-]{0,63}$`)

type esimDeviceRequest struct {
	Model string `json:"model"`
}

// handleESIMDevice serves POST /v1/customers/esim/device. "known": false means
// nobody can tell right now, which the app treats as no warning. Airalo's
// list is about hardware: a carrier-locked phone can still refuse an eSIM, and
// a model missing from the list may well take one. So the app warns and asks;
// it never blocks a purchase on this answer.
func (s HTTPServer) handleESIMDevice(w http.ResponseWriter, r *http.Request) {
	var request esimDeviceRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	model := strings.TrimSpace(request.Model)
	if !esimDeviceModel.MatchString(model) {
		writeCustomerError(w, http.StatusBadRequest, "invalid_request", "a hardware model is required", nil)
		return
	}
	state := s.ESIM.state
	if s.ESIM.Client == nil || state == nil {
		writeJSON(w, http.StatusOK, map[string]any{"known": false})
		return
	}
	if policy := s.ESIM.DeviceRateLimit; policy.Enabled() && s.RateLimiter != nil {
		if decision, err := s.RateLimiter.Allow(r.Context(), "esim-device:"+s.customerClientIP(r), policy); err == nil && !decision.Allowed {
			writeJSON(w, http.StatusOK, map[string]any{"known": false})
			return
		}
	}
	now := s.clock().Now()
	state.mu.Lock()
	cached, hit := state.devices[model]
	state.mu.Unlock()
	if hit && now.Sub(cached.at) < esimDeviceTTL {
		writeJSON(w, http.StatusOK, cached.body)
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), esimDeviceTimeout)
	defer cancel()
	check, err := s.ESIM.Client.CheckDevice(ctx, model)
	if err != nil {
		s.logger().Warn("eSIM device check failed", "model", model, "error", err)
		writeJSON(w, http.StatusOK, map[string]any{"known": false})
		return
	}
	body := map[string]any{"known": true, "supported": check.Supported, "listed": check.Reason != airalo.ReasonNotInList}
	if check.Device != nil {
		body["name"] = check.Device.Name
	}
	state.mu.Lock()
	if len(state.devices) >= esimDevicesKept {
		state.devices = map[string]esimDeviceAnswer{}
	}
	state.devices[model] = esimDeviceAnswer{body: body, at: now}
	state.mu.Unlock()
	writeJSON(w, http.StatusOK, body)
}
