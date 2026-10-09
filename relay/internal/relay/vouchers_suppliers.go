package relay

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"
	"sync"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// An item may list the same card at several suppliers. At purchase the relay
// compares what each would cost the company, in dinars, and buys from the
// cheapest; when that supplier definitely sells nothing it tries the next. What
// the shop pays never depends on the supplier — only the company's margin does.

// supplierEvaluation is what the relay knows about one supplier of an item.
type supplierEvaluation struct {
	// Index is the supplier's place in the item's listing, 0 first. It breaks
	// price ties, so the operator decides who wins a tie by listing order.
	Index int
	Ref   vouchers.Ref
	// Supplier is who to call; nil when the relay is not configured for it.
	Supplier vouchers.Supplier
	// Offer is the supplier's last read price and stock for the card; nil when
	// its offers have never covered this card.
	Offer *control.VoucherOffer
	// Cost is the card's price in dinars at the current settings; nil when it
	// cannot be told (no offer, no dollar rate).
	Cost *big.Rat
	// Candidate says the supplier can sell the card now. Reason says why not
	// otherwise.
	Candidate bool
	Reason    string
	// Attention marks a reason an operator should know about: a price over its
	// guard, a card no longer sold, a missing dollar rate.
	Attention bool
	// Note is a caveat that does not stop a sale: the supplier's price and stock
	// are unknown (never read, or read too long ago to be believed), so it is
	// tried after every supplier whose price is known.
	Note string
}

// voucherBalanceMaxAge is how old a balance read at a supplier may be and still
// keep a card off the shelf: the offer sync reads it, so a longer silence means
// the sync is not working and the number says nothing.
const voucherBalanceMaxAge = 2 * time.Hour

// supplierBreakerPause is how long a supplier that just failed in a way the next
// purchase would meet again is left alone, when another supplier can sell the
// card.
const supplierBreakerPause = 5 * time.Minute

// SupplierBreaker remembers, in memory, which suppliers just failed in a way
// that will repeat: the company's balance there is empty (supplier_credit), its
// credentials are refused (supplier_unauthorized), or it cannot be reached or
// does not answer (supplier_unreachable, a timeout, a 5xx). Such a supplier is
// skipped for a few minutes whenever another can sell the card, so one broken
// account does not make every purchase of every card it is cheapest for wait on
// a call that fails, and a hang there does not hold shops' money. The relay
// still tries it when it is the only candidate, and a purchase it serves closes
// the breaker. Each relay node keeps its own memory; a restart forgets it. The
// zero pointer is a breaker that never opens.
type SupplierBreaker struct {
	mu    sync.Mutex
	until map[string]time.Time
	why   map[string]string
}

// NewSupplierBreaker is a breaker with every supplier closed.
func NewSupplierBreaker() *SupplierBreaker {
	return &SupplierBreaker{until: map[string]time.Time{}, why: map[string]string{}}
}

// trip opens the breaker for a supplier (or keeps it open for longer) and says
// whether it was closed until now.
func (b *SupplierBreaker) trip(supplier, why string, now time.Time) bool {
	if b == nil {
		return false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	opened := !now.Before(b.until[supplier])
	b.until[supplier] = now.Add(supplierBreakerPause)
	b.why[supplier] = why
	return opened
}

// paused says whether the breaker is open for a supplier, until when and why.
func (b *SupplierBreaker) paused(supplier string, now time.Time) (time.Time, string, bool) {
	if b == nil {
		return time.Time{}, "", false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	until := b.until[supplier]
	return until, b.why[supplier], now.Before(until)
}

// reset closes the breaker for a supplier.
func (b *SupplierBreaker) reset(supplier string) {
	if b == nil {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.until, supplier)
	delete(b.why, supplier)
}

// breakerWorthy reports whether a failure says the supplier will fail the next
// purchase too, rather than this one card being unavailable or refused.
func breakerWorthy(failure *vouchers.Failure) bool {
	switch failure.Code {
	case vouchers.FailureCredit, vouchers.FailureUnauthorized, vouchers.FailureUnreachable:
		return true
	case vouchers.FailureUnknown:
		// A timeout or a 5xx after the request left: nobody knows whether the card
		// was bought, and the supplier is not answering sensibly.
		return !failure.Definite
	}
	return false
}

// failureOf reads any error a supplier's Buy returned as a Failure.
func failureOf(err error) *vouchers.Failure {
	var failure *vouchers.Failure
	if errors.As(err, &failure) {
		return failure
	}
	return &vouchers.Failure{Code: vouchers.FailureUnknown, Detail: err.Error()}
}

// supplierRanking is the verdict on an item's suppliers.
type supplierRanking struct {
	// Listed is false for an item that is not on sale at all.
	Listed bool
	// Evaluations has every supplier the item lists, in listing order.
	Evaluations []supplierEvaluation
	// Candidates are the suppliers to try, in the order to try them: known cost
	// first, cheapest first (listing order on a tie), then those whose cost is
	// unknown.
	Candidates []supplierEvaluation
}

// rankSuppliers decides who an item's card can be bought from right now, and
// in what order. A supplier is a candidate when the relay is configured for it,
// it sells the card (the card is in its last read offers, in stock, and a
// supplier never read at all is "unknown": allowed, but tried after every
// supplier whose price is known) and its price, in dinars, is within the
// supplier block's max_cost. Reloadly is never unknown: its price depends on
// the dollar rate and on the amount, so a Reloadly card with no read offer or
// no rate is not sold. Test mode buys from the one built-in supplier.
func (c VoucherConfig) rankSuppliers(located vouchers.Located, offers voucherOffers, settings vouchers.Settings) supplierRanking {
	ranking := supplierRanking{Listed: located.Listed()}
	refs := located.Refs
	if len(refs) == 0 {
		refs = []vouchers.Ref{located.Ref}
	}
	for index, ref := range refs {
		ranking.Evaluations = append(ranking.Evaluations, c.evaluateSupplier(index, ref, offers, settings))
	}
	if !ranking.Listed {
		// Nothing is bought, but the operator still sees each supplier's price.
		for i := range ranking.Evaluations {
			ranking.Evaluations[i].Candidate = false
			ranking.Evaluations[i].Reason = "the item is not on sale"
		}
		return ranking
	}
	if c.TestMode {
		// Nothing is bought from anyone: the first listed supplier stands for
		// the built-in one, and the others are only shown.
		for i := range ranking.Evaluations {
			evaluation := &ranking.Evaluations[i]
			evaluation.Candidate = i == 0
			evaluation.Reason, evaluation.Attention = "", false
			if i == 0 {
				evaluation.Supplier = vouchers.TestSupplier{}
			} else {
				evaluation.Reason = "test mode buys from nobody"
			}
		}
		ranking.Candidates = ranking.Evaluations[:1]
		return ranking
	}
	for _, evaluation := range ranking.Evaluations {
		if evaluation.Candidate {
			ranking.Candidates = append(ranking.Candidates, evaluation)
		}
	}
	sort.SliceStable(ranking.Candidates, func(i, j int) bool {
		a, b := ranking.Candidates[i], ranking.Candidates[j]
		switch {
		case a.Cost != nil && b.Cost != nil:
			if order := a.Cost.Cmp(b.Cost); order != 0 {
				return order < 0
			}
		case a.Cost != nil:
			return true
		case b.Cost != nil:
			return false
		}
		return a.Index < b.Index
	})
	c.skipPaused(&ranking, offers.at())
	return ranking
}

// skipPaused leaves out the candidates whose supplier the breaker has open,
// provided another candidate remains: a supplier that failed a moment ago is
// not tried first while someone else can sell, and when everyone is paused all
// are tried, because something has to be.
func (c VoucherConfig) skipPaused(ranking *supplierRanking, now time.Time) {
	if c.Breaker == nil || len(ranking.Candidates) < 2 {
		return
	}
	healthy := make([]supplierEvaluation, 0, len(ranking.Candidates))
	paused := map[int]string{}
	for _, candidate := range ranking.Candidates {
		if until, why, open := c.Breaker.paused(candidate.Ref.Supplier, now); open {
			paused[candidate.Index] = fmt.Sprintf("skipped for now: it failed a moment ago (%s) and is left alone until %s while another supplier can sell",
				why, until.UTC().Format("15:04:05 MST"))
		} else {
			healthy = append(healthy, candidate)
		}
	}
	if len(paused) == 0 || len(healthy) == 0 {
		return
	}
	ranking.Candidates = healthy
	for i := range ranking.Evaluations {
		if reason, skipped := paused[ranking.Evaluations[i].Index]; skipped {
			ranking.Evaluations[i].Candidate, ranking.Evaluations[i].Reason = false, reason
		}
	}
}

// evaluateSupplier judges one supplier of an item (outside test mode).
func (c VoucherConfig) evaluateSupplier(index int, ref vouchers.Ref, offers voucherOffers, settings vouchers.Settings) supplierEvaluation {
	evaluation := supplierEvaluation{Index: index, Ref: ref}
	supplier, configured := c.Suppliers[ref.Supplier]
	if !configured {
		evaluation.Reason = "the relay does not buy from " + ref.Supplier
		return evaluation
	}
	evaluation.Supplier = supplier
	offer, known := offers.offer(ref)
	if known {
		evaluation.Offer = &offer
	}
	if age, old := offers.stale(ref.Supplier); old {
		// Offers this old say nothing about today's price and stock: they are no
		// more known than if they had never been read.
		note := fmt.Sprintf("its offers were last read %s ago (more than %s): price and stock unknown", age.Round(time.Minute), offers.maxAge)
		if ref.Supplier == vouchers.SupplierReloadly {
			evaluation.Reason, evaluation.Attention = "the price at Reloadly is not known: "+note, true
			return evaluation
		}
		evaluation.Candidate, evaluation.Note = true, note
		return evaluation
	}
	var costReason string
	if known {
		evaluation.Cost, costReason = offerCostLYD(offer, settings)
	}
	switch {
	case !known && offers.listed[ref.Supplier]:
		evaluation.Reason, evaluation.Attention = "the supplier no longer sells this card", true
	case !known && ref.Supplier == vouchers.SupplierReloadly:
		// Never priced blind: a Reloadly price is known only from its offers.
		evaluation.Reason = "the price at Reloadly is not known yet: its offers have not been read"
	case !known:
		// A supplier whose offers were never read is not judged.
		evaluation.Candidate, evaluation.Note = true, "its offers have not been read: price and stock unknown"
	case !offer.InStock:
		evaluation.Reason = "the supplier is out of stock"
	case evaluation.Cost == nil:
		evaluation.Reason, evaluation.Attention = costReason, true
	default:
		if guard := strings.TrimSpace(ref.MaxCost); guard != "" {
			limit, limitOK := new(big.Rat).SetString(guard)
			if limitOK && evaluation.Cost.Cmp(limit) > 0 {
				evaluation.Reason, evaluation.Attention = overGuardReason(offer, evaluation.Cost, guard), true
				return evaluation
			}
		}
		if reason := balanceReason(supplier, ref.Supplier, offer, evaluation.Cost, settings, offers.at()); reason != "" {
			evaluation.Reason, evaluation.Attention = reason, true
			return evaluation
		}
		evaluation.Candidate = true
	}
	return evaluation
}

// balanceReason says why the company's last read balance at a supplier cannot
// pay for the card ("" when it can, or when nothing believable is known). A
// balance that never arrived, or was read longer ago than voucherBalanceMaxAge,
// is not believed; the cost is compared in dinars, the balance converted the same
// way the card's price is.
func balanceReason(
	supplier vouchers.Supplier,
	key string,
	offer control.VoucherOffer,
	cost *big.Rat,
	settings vouchers.Settings,
	now time.Time,
) string {
	reader, ok := supplier.(vouchers.BalanceReader)
	if !ok || cost == nil {
		return ""
	}
	balance, currency, readAt, known := reader.LastBalance()
	if !known || now.Sub(readAt) >= voucherBalanceMaxAge || !strings.EqualFold(strings.TrimSpace(currency), strings.TrimSpace(offer.Currency)) {
		return ""
	}
	funds, ok := balance, true
	if strings.EqualFold(currency, "USD") {
		funds, ok = settings.USDToLYD(balance)
	}
	if !ok || cost.Cmp(funds) <= 0 {
		return ""
	}
	return fmt.Sprintf("the company's balance at %s is %s %s (read %s ago), below this card's price of %s %s",
		key, balance.FloatString(2), strings.ToUpper(currency), now.Sub(readAt).Round(time.Minute), offer.Price, offer.Currency)
}

// overGuardReason says a supplier's price is above the item's max_cost, in the
// supplier's own currency and, when that is not dinars, in dinars too.
func overGuardReason(offer control.VoucherOffer, cost *big.Rat, guard string) string {
	if currency := strings.ToUpper(strings.TrimSpace(offer.Currency)); currency == "" || currency == "LYD" {
		return fmt.Sprintf("the supplier's price %s %s is above max_cost %s", offer.Price, offer.Currency, guard)
	}
	return fmt.Sprintf("the supplier's price %s %s (%s LYD) is above max_cost %s",
		offer.Price, offer.Currency, cost.FloatString(2), guard)
}

// offerCostLYD is a supplier's price for one card in dinars at the current
// settings: as it is for a price in dinars, converted with the dollar rate for
// one in dollars. Nothing is converted by guess: with no rate, or a currency
// the relay has no rate for, the cost is unknown and reason says why.
func offerCostLYD(offer control.VoucherOffer, settings vouchers.Settings) (*big.Rat, string) {
	price, ok := new(big.Rat).SetString(strings.TrimSpace(offer.Price))
	if !ok || price.Sign() < 0 {
		return nil, fmt.Sprintf("the supplier's price %q is not a number", offer.Price)
	}
	switch strings.ToUpper(strings.TrimSpace(offer.Currency)) {
	case "", "LYD":
		return price, ""
	case "USD":
		if cost, ok := settings.USDToLYD(price); ok {
			return cost, ""
		}
		return nil, "rate_unset: the supplier prices in USD and the dollar rate is not set " +
			"(pointy-relay vouchers settings set --usd-rate)"
	}
	return nil, fmt.Sprintf("the supplier prices in %s, which cannot be compared in dinars", strings.TrimSpace(offer.Currency))
}

// unavailable says why the item cannot be bought now ("" when it can), and
// whether that is worth an operator's attention. A single supplier's reason is
// told as it is; with several, each supplier says its own.
func (r supplierRanking) unavailable() (string, bool) {
	if !r.Listed {
		return "the item is not on sale", false
	}
	if len(r.Candidates) > 0 {
		return "", false
	}
	if len(r.Evaluations) == 0 {
		return "the item names no supplier", true
	}
	attention := false
	for _, evaluation := range r.Evaluations {
		attention = attention || evaluation.Attention
	}
	if len(r.Evaluations) == 1 {
		return r.Evaluations[0].Reason, attention
	}
	parts := make([]string, 0, len(r.Evaluations))
	for _, evaluation := range r.Evaluations {
		parts = append(parts, evaluation.Ref.Supplier+": "+evaluation.Reason)
	}
	return strings.Join(parts, "; "), attention
}

// supplies is the ranking as the operator's catalog view shows it: every
// supplier the item lists, with its offer, what it costs in dinars, and its place
// in the order a purchase tries them.
func (r supplierRanking) supplies(offers voucherOffers) []voucherSupplierSupply {
	rank := map[int]int{}
	for position, candidate := range r.Candidates {
		rank[candidate.Index] = position + 1
	}
	supplies := make([]voucherSupplierSupply, 0, len(r.Evaluations))
	for _, evaluation := range r.Evaluations {
		supply := voucherSupplierSupply{
			Supplier:  evaluation.Ref.Supplier,
			Ref:       evaluation.Ref.ID,
			MaxCost:   evaluation.Ref.MaxCost,
			Candidate: evaluation.Candidate && rank[evaluation.Index] > 0,
			Rank:      rank[evaluation.Index],
			Reason:    evaluation.Reason,
			Note:      evaluation.Note,
		}
		if offer, known := offers.offer(evaluation.Ref); known {
			supply.Offer = &offer
		}
		if evaluation.Cost != nil {
			supply.CostLYD = evaluation.Cost.FloatString(4)
		}
		supplies = append(supplies, supply)
	}
	return supplies
}

// skipped describes the suppliers left out of a purchase, for the log.
func (r supplierRanking) skipped() string {
	var parts []string
	for _, evaluation := range r.Evaluations {
		if !evaluation.Candidate {
			parts = append(parts, evaluation.Ref.Supplier+": "+evaluation.Reason)
		}
	}
	return strings.Join(parts, "; ")
}

// voucherSettingsForCards is the pricing settings a card sale reads. Card sales
// must not depend on the settings document being parseable: it prices Reloadly
// (the dollar rate) and nothing a BN Plus card needs. A stored document that
// does not parse (a field a rolling update just added, a hand-edited value) is
// therefore taken as "no dollar rate": Reloadly is unpriced and dropped, the
// suppliers priced in dinars go on selling, and the log says so once per
// version. Only a failure to read the store itself fails the request.
func (s HTTPServer) voucherSettingsForCards(ctx context.Context, store control.VoucherStore) (vouchers.Settings, error) {
	settings, _, err := s.currentVoucherSettings(ctx, store)
	var unreadable *voucherSettingsUnreadableError
	if errors.As(err, &unreadable) {
		if s.VoucherSettingsCache.firstReport(unreadable.ID) {
			s.logger().Error("the stored voucher settings cannot be read, so Reloadly is unpriced and card sales go on without it; "+
				"publish a corrected document: pointy-relay vouchers settings set --file settings.json",
				"settings_id", unreadable.ID, "error", unreadable.Err)
		}
		return vouchers.DefaultSettings(), nil
	}
	return settings, err
}

// voucherAvailability decides whether a listed item can be bought now (see
// rankSuppliers). Test mode sells everything.
func (s HTTPServer) voucherAvailability(offers voucherOffers, settings vouchers.Settings) vouchers.Availability {
	return func(located vouchers.Located) bool {
		reason, _ := s.voucherUnavailable(located, offers, settings)
		return reason == ""
	}
}

// voucherUnavailable says why an item cannot be bought now ("" when it can),
// and whether that is worth an operator's attention.
func (s HTTPServer) voucherUnavailable(located vouchers.Located, offers voucherOffers, settings vouchers.Settings) (string, bool) {
	return s.Vouchers.rankSuppliers(located, offers, settings).unavailable()
}

// supplierAttempt is one supplier's go at a purchase.
type supplierAttempt struct {
	Supplier string
	Ref      string
	// Err is nil when the supplier took the order.
	Err error
}

func (a supplierAttempt) String() string {
	if a.Err == nil {
		return a.Supplier + ": ok"
	}
	var failure *vouchers.Failure
	if errors.As(a.Err, &failure) {
		return a.Supplier + ": " + failure.Error()
	}
	return a.Supplier + ": " + a.Err.Error()
}

// supplierPurchase is how a purchase went at the suppliers it was tried with.
type supplierPurchase struct {
	// Bought and Err are the LAST supplier's answer: the one that stands.
	Bought vouchers.Purchase
	Err    error
	// Claim is the purchase row as it stands after any re-pointing.
	Claim    control.VoucherPurchase
	Attempts []supplierAttempt
}

// summary lists the suppliers tried and how each went.
func (p supplierPurchase) summary() string {
	parts := make([]string, 0, len(p.Attempts))
	for _, attempt := range p.Attempts {
		parts = append(parts, attempt.String())
	}
	return strings.Join(parts, " -> ")
}

// definiteFailure reports whether err proves the supplier bought nothing.
func definiteFailure(err error) bool {
	var failure *vouchers.Failure
	return errors.As(err, &failure) && failure.Definite
}

// buyFromSuppliers places a claimed purchase with the first candidate. While a
// supplier DEFINITELY sold nothing and another candidate is left, the row is
// re-pointed at the next (RedirectVoucherPurchase) and that one is tried. An
// answer that leaves it open whether anything was bought, or a sale, ends the
// loop: the caller records that answer. A re-pointing the store refuses (the row
// was settled or held meanwhile) or fails also ends it, with the last answer.
// ctx must not be cancelled with the shop's request: past the claim the
// suppliers may sell whatever happens.
func (s HTTPServer) buyFromSuppliers(
	ctx context.Context,
	store control.VoucherStore,
	claim control.VoucherPurchase,
	candidates []supplierEvaluation,
	quantity int,
) supplierPurchase {
	result := supplierPurchase{Claim: claim}
	for i, candidate := range candidates {
		if i > 0 {
			redirected, applied, err := store.RedirectVoucherPurchase(ctx, claim.ID, candidate.Supplier.Key(), candidate.Ref.ID)
			if err != nil || !applied {
				s.logger().Warn("a voucher purchase could not be re-pointed at its next supplier; it ends with the last one's answer",
					"purchase_id", claim.ID, "next_supplier", candidate.Supplier.Key(), "applied", applied, "error", err)
				break
			}
			result.Claim = redirected
		}
		callCtx, cancel := context.WithTimeout(ctx, s.Vouchers.requestTimeout())
		bought, err := candidate.Supplier.Buy(callCtx, candidate.Ref, quantity, claim.ID)
		cancel()
		result.Bought, result.Err = bought, err
		result.Attempts = append(result.Attempts, supplierAttempt{
			Supplier: candidate.Supplier.Key(), Ref: candidate.Ref.ID, Err: err,
		})
		var next *supplierEvaluation
		if i+1 < len(candidates) {
			next = &candidates[i+1]
		}
		s.noteSupplierHealth(claim.ID, candidate, err, next)
		if !definiteFailure(err) {
			break
		}
	}
	return result
}

// noteSupplierHealth learns from an attempt: a sale closes the supplier's
// breaker; a failure that will repeat opens it (and says so once, at ERROR, when
// it opens). Without a breaker, a fall-back that hides a problem with the
// company's own account (balance empty, credentials refused) is still made loud.
func (s HTTPServer) noteSupplierHealth(purchaseID string, attempted supplierEvaluation, err error, next *supplierEvaluation) {
	key := attempted.Ref.Supplier
	breaker := s.Vouchers.Breaker
	if err == nil {
		breaker.reset(key)
		return
	}
	failure := failureOf(err)
	if breaker != nil && breakerWorthy(failure) {
		if breaker.trip(key, failure.Code+": "+failure.Detail, s.clock().Now()) {
			s.logger().Error("a supplier failed in a way the next purchase would meet again; it is skipped for a few minutes "+
				"whenever another supplier can sell the card (the breaker opens, in memory)",
				"supplier", key, "purchase_id", purchaseID, "code", failure.Code, "detail", failure.Detail,
				"paused_for", supplierBreakerPause.String())
		}
		return
	}
	if next != nil {
		s.logSupplierAccountProblem(purchaseID, attempted, failure, *next)
	}
}

// logSupplierAccountProblem makes noise about a fall-back that hides a problem
// with the company's own account at a supplier (its balance is empty, its
// credentials are refused): the purchase succeeds elsewhere, so the final line
// of the log would read as a success while every shop's purchases keep trying the
// broken account first.
func (s HTTPServer) logSupplierAccountProblem(purchaseID string, failed supplierEvaluation, failure *vouchers.Failure, next supplierEvaluation) {
	if failure.Code != vouchers.FailureCredit && failure.Code != vouchers.FailureUnauthorized {
		return
	}
	s.logger().Error("the company's account at a supplier cannot buy; the purchase went on to the next supplier",
		"purchase_id", purchaseID, "supplier", failed.Ref.Supplier, "code", failure.Code, "detail", failure.Detail,
		"next_supplier", next.Ref.Supplier)
	s.alertSupplierAccount(failed.Ref.Supplier, failure)
}

// withAttempts adds the earlier suppliers' failures to a failed purchase's
// detail, so the operator reads the whole story from the row. A purchase tried
// at one supplier keeps that supplier's detail as it was.
func (p supplierPurchase) withAttempts(outcome control.VoucherPurchaseOutcome) control.VoucherPurchaseOutcome {
	if len(p.Attempts) < 2 || outcome.Status != control.VoucherPurchaseFailed {
		return outcome
	}
	outcome.ErrorDetail = p.summary()
	return outcome
}
