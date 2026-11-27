package relay

import (
	"context"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// The funding-aware dollar rate (vouchers/fx.go, FX_FUNDING_PLAN.md): what
// the relay gathers for it, and the console's side of it.
//
//	GET  /v1/vouchers/admin/fx                         the rate cards are priced at, every step to it,
//	                                                   each supplier's held capital, the ledger, the series
//	POST /v1/vouchers/admin/fx/fundings                record a top-up {supplier, usd, lyd, method,
//	                                                   reference, note, funded_at, market_rate}
//	POST /v1/vouchers/admin/fx/preview                 the same body: what the top-up would do, nothing stored
//	POST /v1/vouchers/admin/fx/fundings/{id}/void      {reason}

// fxInputsTTL is how long the ledger and the series are reused between
// pricing reads. A top-up recorded on this node drops them at once; another
// relay node picks it up within this long.
const fxInputsTTL = 20 * time.Second

// fxInputs reads the ledger and the series of the settings' rate (cached).
func (s HTTPServer) fxInputs(ctx context.Context, settings vouchers.Settings) ([]control.SupplierFunding, []control.ExchangeRate, bool) {
	fundingStore, ok1 := s.Store.(control.SupplierFundingStore)
	seriesStore, ok2 := s.Store.(control.ExchangeRateSeriesStore)
	if !ok1 || !ok2 {
		return nil, nil, false
	}
	series, bank := settings.RateSeries()
	key := series + "/" + bank
	now := s.clock().Now()
	if c := s.VoucherSettingsCache; c != nil {
		c.mu.Lock()
		if !c.fxAt.IsZero() && c.fxKey == key && now.Sub(c.fxAt) < fxInputsTTL {
			fundings, rates := c.fxFundings, c.fxSeries
			c.mu.Unlock()
			return fundings, rates, true
		}
		c.mu.Unlock()
	}

	fundings, err := fundingStore.ListSupplierFundings(ctx)
	if err != nil {
		s.logger().Warn("the supplier fundings could not be read; cards are priced without them", "error", err)
		return nil, nil, false
	}
	rates, err := seriesStore.ListExchangeRateSeries(ctx, "USD", "LYD", series, bank, now.AddDate(0, 0, -vouchers.FXSeriesDays))
	if err != nil {
		s.logger().Warn("the dollar rate series could not be read; cards are priced without it", "error", err)
		return nil, nil, false
	}
	if c := s.VoucherSettingsCache; c != nil {
		c.mu.Lock()
		c.fxAt, c.fxKey, c.fxFundings, c.fxSeries = now, key, fundings, rates
		c.mu.Unlock()
	}
	return fundings, rates, true
}

// fxBalances is each dollar supplier's balance as last read.
func (s HTTPServer) fxBalances() map[string]vouchers.Balance {
	out := map[string]vouchers.Balance{}
	for key, supplier := range s.Vouchers.Suppliers {
		reader, ok := supplier.(vouchers.BalanceReader)
		if !ok {
			continue
		}
		amount, currency, readAt, known := reader.LastBalance()
		if !known || amount == nil || !strings.EqualFold(strings.TrimSpace(currency), "USD") {
			continue
		}
		out[key] = vouchers.Balance{USD: amount, ReadAt: readAt}
	}
	return out
}

func ratOrNil(raw string) *big.Rat {
	r, ok := new(big.Rat).SetString(strings.TrimSpace(raw))
	if !ok || r.Sign() <= 0 {
		return nil
	}
	return r
}

// fxInputsFor turns what the store holds into the pure inputs.
func fxInputsFor(settings vouchers.Settings, live *big.Rat, liveAt time.Time, fundings []control.SupplierFunding,
	series []control.ExchangeRate, balances map[string]vouchers.Balance, now time.Time) vouchers.FXInputs {
	in := vouchers.FXInputs{Policy: settings.FXRules(), Live: live, LiveAt: liveAt, Balances: balances, Now: now}
	if buffer, ok := new(big.Rat).SetString(strings.TrimSpace(settings.USDRateBufferPercent)); ok {
		in.Buffer = buffer
	}
	for _, f := range fundings {
		if f.VoidedAt != nil {
			continue
		}
		usd, lyd := ratOrNil(f.USD), ratOrNil(f.LYD)
		if usd == nil || lyd == nil {
			continue
		}
		in.Fundings = append(in.Fundings, vouchers.Funding{ID: f.ID, Supplier: f.Supplier, USD: usd, LYD: lyd, MarketRate: ratOrNil(f.MarketRate), At: f.FundedAt})
	}
	for _, r := range series {
		if rate := ratOrNil(r.Rate); rate != nil {
			in.Series = append(in.Series, vouchers.RatePoint{At: r.EffectiveAt, Rate: rate})
		}
	}
	return in
}

// fxQuoteFor works the quote out from a live rate, or — none fresh — from the
// last rate and top-up (FallbackFX). ok is false when nothing can price.
func (s HTTPServer) fxQuoteFor(settings vouchers.Settings, live *big.Rat, liveAt time.Time, fundings []control.SupplierFunding,
	series []control.ExchangeRate, extraBalances map[string]vouchers.Balance) (vouchers.FXQuote, bool) {
	balances := extraBalances
	if balances == nil {
		balances = s.fxBalances()
	}
	in := fxInputsFor(settings, live, liveAt, fundings, series, balances, s.clock().Now())
	if live != nil {
		return vouchers.ComputeFX(in)
	}
	return vouchers.FallbackFX(in)
}

// withFX lays the funding-aware rate on settings. live is nil when no fresh
// rate was received: then, unless the operator set a manual fallback rate, the
// last known rate and top-up price the cards with the full cushion, so an
// outage at fulus.ly does not take every dollar card off the shelf.
func (s HTTPServer) withFX(ctx context.Context, settings vouchers.Settings, live *big.Rat, liveAt time.Time) vouchers.Settings {
	if !settings.FXRules().On() {
		return settings
	}
	if live == nil {
		if rate, _ := settings.EffectiveUSDRate(); rate != nil {
			return settings // the manual fallback rate is the operator's choice
		}
	}
	fundings, series, ok := s.fxInputs(ctx, settings)
	if !ok {
		return settings
	}
	quote, ok := s.fxQuoteFor(settings, live, liveAt, fundings, series, nil)
	if !ok {
		return settings
	}
	if quote.Fallback {
		s.logger().Warn("no fresh dollar rate: dollar cards are priced from the last rate and top-up with the full cushion",
			"rate", quote.Market.FloatString(4), "problem", settings.RateProblem)
	}
	return settings.WithFX(quote)
}

// --- the console ---------------------------------------------------------------

func fxRate(r *big.Rat) string {
	if r == nil {
		return ""
	}
	return r.FloatString(4)
}

func fxMoney(r *big.Rat) string {
	if r == nil {
		return ""
	}
	return r.FloatString(2)
}

func fxPct(r *big.Rat) string {
	if r == nil {
		return ""
	}
	return new(big.Rat).Mul(r, big.NewRat(100, 1)).FloatString(2)
}

func fxTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC()
}

// fxQuoteView is a quote as the console reads it: rates to 4 places, money to
// 2, percentages as percent.
func fxQuoteView(q vouchers.FXQuote, settings vouchers.Settings) map[string]any {
	margin := settings.MarginFor(vouchers.ServiceKindCard)
	priced := settings.WithFX(q)
	books := []map[string]any{}
	names := make([]string, 0, len(q.Books))
	for name := range q.Books {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		b := q.Books[name]
		examples := []map[string]any{}
		for _, usd := range []int64{10, 50, 100} {
			cost, ok := priced.USDToLYDFrom(name, big.NewRat(usd, 1))
			if !ok {
				continue
			}
			prices, ok := margin.Prices(cost)
			if !ok {
				continue
			}
			examples = append(examples, map[string]any{
				"usd": usd, "cost_lyd": fxMoney(cost), "shop_pays": fxMoney(prices.ShopPays), "retail": fxMoney(prices.Retail),
				"margin_percent": fxPct(new(big.Rat).Quo(new(big.Rat).Sub(prices.Retail, cost), cost)),
			})
		}
		view := map[string]any{
			"supplier": name, "rate": fxRate(b.Rate), "binding": b.Binding,
			"covered_usd": fxMoney(b.Covered), "cost_lyd": fxMoney(b.Cost), "average": fxRate(b.Average),
			"uncovered_usd": fxMoney(b.Uncovered), "examples": examples,
		}
		if b.Held != nil {
			view["held_usd"], view["read_at"] = fxMoney(b.Held), fxTime(b.ReadAt)
			view["value_lyd"], view["gain_lyd"] = fxMoney(b.Value), fxMoney(b.Gain)
		}
		books = append(books, view)
	}
	from := q.PremiumFrom
	if from == nil {
		from = []string{}
	}
	return map[string]any{
		"live": fxRate(q.Live), "live_at": fxTime(q.LiveAt),
		"premium_percent": fxPct(q.Premium), "premium_source": q.PremiumSource, "premium_from": from,
		"premium_high": q.PremiumHigh,
		"replacement":  fxRate(q.Replacement),
		"peak":         fxRate(q.Peak), "peak_raw": fxRate(q.PeakRaw), "peak_at": fxTime(q.PeakAt),
		"momentum_percent": fxPct(q.Momentum), "cushion_percent": fxPct(q.Cushion),
		"market": fxRate(q.Market), "binding": q.Binding, "fallback": q.Fallback,
		"shock_percent": fxPct(q.Shock), "shocked": q.Shocked,
		"books": books,
	}
}

// fxState is everything GET /fx answers, with an optional funding not yet
// recorded laid on top (the preview of the top-up dialog).
func (s HTTPServer) fxState(ctx context.Context, store control.VoucherStore, extra *control.SupplierFunding) (map[string]any, error) {
	stored, _, err := s.currentStoredSettings(ctx, store)
	if err != nil {
		return nil, err
	}
	rules := stored.FXRules()
	out := map[string]any{"policy": rules, "enabled": rules.On(), "source": stored.USDRateSource}
	series, bank := stored.RateSeries()
	out["series"] = map[string]string{"instrument": series, "bank_code": bank}

	rateStore, ok := s.Store.(control.ExchangeRateStore)
	if !ok {
		out["problem"] = "exchange rates are not supported by this relay's store"
		return out, nil
	}
	fundings, history, ok := s.fxInputs(ctx, stored)
	if !ok {
		out["problem"] = "the supplier fundings or the rate series cannot be read"
		return out, nil
	}
	out["fundings"] = fundings
	points := []map[string]any{}
	for _, r := range history {
		points = append(points, map[string]any{"at": r.EffectiveAt.UTC(), "rate": r.Rate})
	}
	out["history"] = points
	switch {
	case !stored.UsesLiveRate():
		out["problem"] = "manual"
		return out, nil
	case !rules.On():
		out["problem"] = "off"
		return out, nil
	}
	now := s.clock().Now()
	rates, err := rateStore.ListExchangeRates(ctx, now.Add(-liveRateWindow), liveRateLimit)
	if err != nil {
		return nil, err
	}
	live, liveAt, problem := pickUSDRate(rates, stored, now)
	if live == nil {
		out["rate_problem"] = problem
		if rate, _ := stored.EffectiveUSDRate(); rate != nil {
			out["problem"] = "manual_fallback"
			return out, nil
		}
	}
	quote, ok := s.fxQuoteFor(stored, live, liveAt, fundings, history, nil)
	if !ok {
		out["problem"] = problem
		return out, nil
	}
	out["quote"] = fxQuoteView(quote, stored)
	if extra != nil {
		// A top-up dated after a supplier's balance was read counts on top of
		// it, one dated before as already in it (vouchers.books).
		next, _ := s.fxQuoteFor(stored, live, liveAt, append([]control.SupplierFunding{*extra}, fundings...), history, nil)
		out["after"] = fxQuoteView(next, stored)
	}
	return out, nil
}

// currentStoredSettings is the published settings without any live rate.
func (s HTTPServer) currentStoredSettings(ctx context.Context, store control.VoucherStore) (vouchers.Settings, bool, error) {
	loaded, err := s.loadStoredVoucherSettings(ctx, store)
	if err != nil {
		return vouchers.Settings{}, false, err
	}
	return loaded.settings, loaded.stored, nil
}

func (s HTTPServer) handleVoucherAdminFX(w http.ResponseWriter, r *http.Request, store control.VoucherStore, path string) {
	switch {
	case path == "" && r.Method == http.MethodGet:
		state, err := s.fxState(r.Context(), store, nil)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, state)
	case path == "/fundings" && r.Method == http.MethodPost:
		s.handleFXFundingCreate(w, r, store, false)
	case path == "/preview" && r.Method == http.MethodPost:
		// The top-up dialog's what-if: the same body, nothing stored.
		s.handleFXFundingCreate(w, r, store, true)
	case strings.HasPrefix(path, "/fundings/") && strings.HasSuffix(path, "/void") && r.Method == http.MethodPost:
		s.handleFXFundingVoid(w, r, strings.TrimSuffix(strings.TrimPrefix(path, "/fundings/"), "/void"))
	default:
		writeNotFound(w)
	}
}

var fundingReferenceSplit = regexp.MustCompile(`[\s,]+`)

// referenceTokens are the ids a funding's reference names (company purchase
// ids, a bank reference).
func referenceTokens(reference string) []string {
	out := []string{}
	for _, token := range fundingReferenceSplit.Split(strings.TrimSpace(reference), -1) {
		if token != "" {
			out = append(out, strings.ToLower(token))
		}
	}
	return out
}

func writeFundingProblem(w http.ResponseWriter, field, message string) {
	writeJSON(w, http.StatusBadRequest, map[string]any{"error": field + ": " + message, "field": field})
}

func (s HTTPServer) handleFXFundingCreate(w http.ResponseWriter, r *http.Request, store control.VoucherStore, preview bool) {
	fundingStore, ok := s.Store.(control.SupplierFundingStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "supplier fundings are not supported by this relay's store"})
		return
	}
	var body struct {
		control.SupplierFunding
		DryRun bool `json:"dry_run"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	preview = preview || body.DryRun
	funding := body.SupplierFunding
	funding.Actor = adminActor(r, funding.Actor)
	now := s.clock().Now()
	normalized, err := control.NormalizeSupplierFunding(funding, now)
	var problem control.SupplierFundingProblem
	if errors.As(err, &problem) {
		writeFundingProblem(w, problem.Field, problem.Message)
		return
	}
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	stored, _, err := s.currentStoredSettings(r.Context(), store)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	fundings, series, ok := s.fxInputs(r.Context(), stored)
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the supplier fundings or the rate series cannot be read"})
		return
	}
	// The same purchase or transfer recorded twice would count its dollars
	// twice: a reference already named by a top-up still in force is refused.
	used := map[string]string{}
	for _, f := range fundings {
		if f.VoidedAt == nil {
			for _, token := range referenceTokens(f.Reference) {
				used[token] = f.ID
			}
		}
	}
	for _, token := range referenceTokens(normalized.Reference) {
		if id, taken := used[token]; taken {
			writeFundingProblem(w, "reference", "already recorded in top-up "+id+": void that one first to record it again")
			return
		}
	}
	// The bank rate the day the dollars were bought: what the premium is
	// learned against. With none in the series, the operator types it.
	if normalized.MarketRate == "" {
		normalized.MarketRate = rateAt(series, normalized.FundedAt)
		if normalized.MarketRate == "" {
			writeFundingProblem(w, "market_rate", "no bank rate is stored for that date: type the bank rate of the day it was bought")
			return
		}
		if market := ratOrNil(normalized.MarketRate); market != nil {
			normalized.MarketRate = market.FloatString(4)
		}
	}

	if preview {
		normalized.ID = "preview"
		state, err := s.fxState(r.Context(), store, &normalized)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		state["funding"] = normalized
		writeJSON(w, http.StatusOK, state)
		return
	}
	funding.MarketRate = normalized.MarketRate
	created, err := fundingStore.CreateSupplierFunding(r.Context(), funding)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	s.VoucherSettingsCache.invalidate()
	s.logger().Info("supplier funding recorded", "id", created.ID, "supplier", created.Supplier,
		"usd", created.USD, "lyd", created.LYD, "market_rate", created.MarketRate, "actor", created.Actor)
	writeJSON(w, http.StatusCreated, created)
}

func (s HTTPServer) handleFXFundingVoid(w http.ResponseWriter, r *http.Request, id string) {
	fundingStore, ok := s.Store.(control.SupplierFundingStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "supplier fundings are not supported by this relay's store"})
		return
	}
	var body struct {
		Reason string `json:"reason"`
		Actor  string `json:"actor"`
	}
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&body)
	if strings.TrimSpace(body.Reason) == "" {
		writeFundingProblem(w, "reason", "a reason is required")
		return
	}
	voided, err := fundingStore.VoidSupplierFunding(r.Context(), id, body.Reason, adminActor(r, body.Actor))
	switch {
	case errors.Is(err, control.ErrSupplierFundingNotFound):
		writeNotFound(w)
		return
	case errors.Is(err, control.ErrSupplierFundingVoided):
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	case err != nil:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	s.VoucherSettingsCache.invalidate()
	s.logger().Info("supplier funding voided", "id", id, "reason", body.Reason)
	writeJSON(w, http.StatusOK, voided)
}

// rateAt is the series' rate in force at t: the last published at or before
// it ("" when none was).
func rateAt(series []control.ExchangeRate, t time.Time) string {
	best := ""
	var bestAt time.Time
	for _, r := range series {
		if r.EffectiveAt.After(t) || (best != "" && r.EffectiveAt.Before(bestAt)) {
			continue
		}
		best, bestAt = r.Rate, r.EffectiveAt
	}
	return best
}
