package relay

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"pointy/relay/internal/alerts"
	"pointy/relay/internal/control"
	"pointy/relay/internal/esimaccess"
	"pointy/relay/internal/vouchers"
)

// An eSIM order is a customer order whose item names a supplier's package (one
// of eSIM Access's starts with "ea."):
//
//	esim:<package>                 a new eSIM
//	esim-topup:<iccid>:<package>   a top-up of one the customer owns
//
// Payment, credit, the fee, refunds and the reconcilers are the card order's.
// The supplier purchase is an ordinary voucher purchase too, claimed once under
// the order's key: that claim, and never resending an unanswered order, are what
// stop a duplicate (the checklist's "safeguards against duplicate orders").

const (
	esimItemPrefix      = "esim:"
	esimTopUpItemPrefix = "esim-topup:"
	esimBrandKey        = "esim"
	// Order account fields: who the eSIM is for.
	esimAccountLabel = "label"
	esimAccountGift  = "gift"
)

// esimItem is an order's item read back.
type esimItem struct {
	PackageID string
	// ICCID is set on a top-up.
	ICCID string
}

func (i esimItem) topUp() bool { return i.ICCID != "" }

func parseESIMItem(key string) (esimItem, bool) {
	if rest, ok := strings.CutPrefix(key, esimTopUpItemPrefix); ok {
		iccid, packageID, found := strings.Cut(rest, ":")
		if !found || iccid == "" || packageID == "" {
			return esimItem{}, false
		}
		return esimItem{PackageID: packageID, ICCID: iccid}, true
	}
	if packageID, ok := strings.CutPrefix(key, esimItemPrefix); ok && packageID != "" {
		return esimItem{PackageID: packageID}, true
	}
	return esimItem{}, false
}

// esimOrderAccount keeps only what an eSIM order may say about who it is for.
func esimOrderAccount(typed map[string]string) map[string]string {
	account := map[string]string{}
	if label := strings.TrimSpace(typed[esimAccountLabel]); label != "" {
		account[esimAccountLabel] = label
	}
	if typed[esimAccountGift] != "" {
		account[esimAccountGift] = "1"
	}
	return account
}

// esimOrderBrand is an order's brand: "esim:TR" carries the flag the app draws on
// the order's card, for an order it has only just been told about.
func esimOrderBrand(country string) string {
	if country == "" {
		return esimBrandKey
	}
	return esimBrandKey + ":" + country
}

// isESIMOrder tells an eSIM order from a card order.
func isESIMOrder(order control.CustomerOrder) bool {
	_, ok := parseESIMItem(order.ItemKey)
	return ok
}

// esimQuote is what a plan sells for now, and what is frozen on the purchase.
type esimQuote struct {
	Name    string
	Price   *big.Rat
	Details esimPurchaseDetails
	// Ref is what the supplier is asked for.
	Ref vouchers.Ref
}

// esimPurchaseDetails is the plan as sold, kept on the purchase row until the
// eSIM is issued: the catalog may have moved on by then.
type esimPurchaseDetails struct {
	PackageID       string `json:"package_id"`
	Title           string `json:"title"`
	Data            string `json:"data"`
	Days            int    `json:"days"`
	AmountMB        int    `json:"amount_mb"`
	Operator        string `json:"operator"`
	Destination     string `json:"destination"`
	DestinationName string `json:"destination_name"`
	Country         string `json:"country,omitempty"`
	Image           string `json:"image,omitempty"`
	Unlimited       bool   `json:"unlimited,omitempty"`
	Rechargeable    bool   `json:"rechargeable,omitempty"`
	// Supplier is who the plan is bought from; empty is Airalo.
	Supplier string `json:"supplier,omitempty"`
}

// esimPlanRef is what a supplier is asked for to issue a first eSIM on a plan.
func esimPlanRef(plan esimPlan) vouchers.Ref {
	if planSupplier(plan) == vouchers.SupplierESIMAccess {
		return vouchers.ESIMAccessSIMRef(plan.Ref, plan.CostUnits)
	}
	return vouchers.AiraloSIMRef(plan.ID)
}

// esimTopUpRef is what a supplier is asked for to top an eSIM up with a plan.
func esimTopUpRef(esim control.CustomerESIM, plan esimPlan) vouchers.Ref {
	if planSupplier(plan) == vouchers.SupplierESIMAccess {
		return vouchers.ESIMAccessTopUpRef(esim.SupplierRef, esimAccessICCID(esim), plan.Ref, plan.CostUnits)
	}
	return vouchers.AiraloTopUpRef(esim.ICCID, plan.ID)
}

// quoteESIMOrder prices the plan an order item names. The failure is an error
// code the app knows, with its HTTP status.
func (s HTTPServer) quoteESIMOrder(ctx context.Context, customer control.Customer, item esimItem) (esimQuote, int, string) {
	if !s.esimSells() {
		return esimQuote{}, 404, "unknown_item"
	}
	pricing, ok := s.esimPricingNow(ctx)
	if !ok {
		return esimQuote{}, 409, "item_unavailable"
	}
	if item.topUp() {
		return s.quoteESIMTopUp(ctx, customer, item, pricing)
	}
	catalog := s.esimCatalogNow(ctx)
	if catalog == nil {
		return esimQuote{}, 404, "unknown_item"
	}
	destination, plan, found := catalog.find(item.PackageID)
	if !found {
		return esimQuote{}, 404, "unknown_item"
	}
	// The price the shelf showed: a running promotion's, else the plan's own.
	offer, ok := pricing.offer(destination.Key, plan)
	if !ok || offer.Price.Sign() <= 0 {
		return esimQuote{}, 409, "item_unavailable"
	}
	return esimQuote{
		Name:  esimOrderName(destination.Name, plan),
		Price: offer.Price,
		Ref:   esimPlanRef(plan),
		Details: esimPurchaseDetails{
			PackageID: plan.ID, Title: plan.Title, Data: plan.Data, Days: plan.Days, AmountMB: plan.AmountMB,
			Operator: plan.Operator, Destination: destination.Key, DestinationName: destination.Name, Country: destination.Country,
			Image: destination.Image, Unlimited: plan.Unlimited, Rechargeable: plan.Rechargeable,
			Supplier: planSupplier(plan),
		},
	}, 0, ""
}

func (s HTTPServer) quoteESIMTopUp(ctx context.Context, customer control.Customer, item esimItem, pricing esimPricing) (esimQuote, int, string) {
	store, ok := s.Store.(control.CustomerESIMStore)
	if !ok {
		return esimQuote{}, 404, "unknown_item"
	}
	esim, err := store.GetCustomerESIM(ctx, item.ICCID)
	if err != nil || esim.CustomerID != customer.ID {
		return esimQuote{}, 404, "unknown_item"
	}
	plans, err := s.esimTopUps(ctx, esim)
	if err != nil {
		return esimQuote{}, 409, "item_unavailable"
	}
	for _, plan := range plans {
		if plan.ID != item.PackageID {
			continue
		}
		price, ok := pricing.price(plan)
		if !ok || price.Sign() <= 0 {
			break
		}
		return esimQuote{
			Name:  esimOrderName(esim.DestinationName, plan),
			Price: price,
			Ref:   esimTopUpRef(esim, plan),
			Details: esimPurchaseDetails{
				PackageID: plan.ID, Title: plan.Title, Data: plan.Data, Days: plan.Days, AmountMB: plan.AmountMB,
				Operator: esim.Operator, Destination: esim.Destination, DestinationName: esim.DestinationName, Country: esim.Country,
				Image: esim.Image, Unlimited: plan.Unlimited, Rechargeable: true,
				Supplier: planSupplier(plan),
			},
		}, 0, ""
	}
	return esimQuote{}, 409, "item_unavailable"
}

// esimSupplierFor is who sells an order of a plan from supplier: the stores'
// review account and test mode buy for show, everyone else from the plan's
// supplier. While Airalo is in Sandbox the review account buys an Airalo plan
// there too: its eSIM is Airalo's dummy one, on Airalo's Sandbox dashboard, and
// nothing is paid for it. Against a live account (and eSIM Access has no other
// kind) a review order would be a real eSIM, so it stays with the test supplier.
func (s HTTPServer) esimSupplierFor(order control.CustomerOrder, supplier string) (vouchers.Supplier, bool) {
	if supplier == "" {
		supplier = vouchers.SupplierAiralo
	}
	switch {
	case order.Review:
		if airalo, ok := s.Vouchers.Suppliers[vouchers.SupplierAiralo]; ok && s.ESIM.Sandbox && supplier == vouchers.SupplierAiralo {
			return airalo, true
		}
		return vouchers.TestSupplier{Plain: true}, true
	case s.Vouchers.TestMode:
		return vouchers.TestSupplier{}, true
	}
	found, ok := s.Vouchers.Suppliers[supplier]
	return found, ok
}

// claimCustomerESIM claims the order's purchase and places it with Airalo. Called
// only when no purchase exists for the order: see claimCustomerPurchase.
func (s HTTPServer) claimCustomerESIM(
	ctx context.Context,
	orders control.CustomerOrderStore,
	cards control.VoucherStore,
	order control.CustomerOrder,
	item esimItem,
	key string,
) (control.VoucherPurchase, []vouchers.Code, bool) {
	refund := func(code, detail string) {
		if _, _, err := orders.FinishCustomerOrder(ctx, order.ID, false, code, detail); err != nil {
			s.logger().Error("refunding an eSIM order failed", "order_id", order.ID, "error", err)
			return
		}
		s.logger().Warn("eSIM order refunded to credit before buying", "order_id", order.ID, "code", code)
	}
	// The plan as the customer saw it: a sale already paid for goes ahead at its
	// paid price even if the catalog just re-priced it.
	quote, _, failure := s.quoteESIMOrder(ctx, control.Customer{ID: order.CustomerID}, item)
	if failure != "" {
		refund("item_unavailable", "the plan left the catalog before it could be bought")
		return control.VoucherPurchase{}, nil, false
	}
	supplier, ok := s.esimSupplierFor(order, quote.Details.Supplier)
	if !ok {
		refund("item_unavailable", "the plan's supplier is not configured on this relay")
		return control.VoucherPurchase{}, nil, false
	}
	details, err := json.Marshal(quote.Details)
	if err != nil {
		s.logger().Error("encoding an eSIM order's details failed", "order_id", order.ID, "error", err)
		return control.VoucherPurchase{}, nil, false
	}
	ref := quote.Ref
	claim, created, err := cards.BeginVoucherPurchase(ctx, control.VoucherPurchase{
		IdempotencyKey: key,
		ItemKey:        order.ItemKey,
		BrandKey:       esimBrandKey,
		ItemName:       order.ItemName,
		Quantity:       1,
		UnitPrice:      order.UnitPrice,
		Supplier:       supplier.Key(),
		SupplierRef:    ref.ID,
		TestMode:       s.Vouchers.MarksTest() || order.TestMode,
		Purpose:        control.VoucherPurposeCustomer,
		Note:           order.ID,
		Details:        details,
	})
	if err != nil {
		s.logger().Error("eSIM purchase claim failed", "order_id", order.ID, "error", err)
		return control.VoucherPurchase{}, nil, false
	}
	if !created {
		return claim, nil, true
	}
	ranking := supplierRanking{Listed: true, Candidates: []supplierEvaluation{{Ref: ref, Supplier: supplier, Candidate: true}}}
	finished, codes := s.buyClaimedCards(ctx, cards, claim, ranking, 1, vouchers.Account{})
	return finished, codes, true
}

// completeESIMOrder writes down what a succeeded purchase issued, before the
// order is told delivered: a delivered order always has its eSIM row. A failure
// leaves the order to be finished by the next read or sweep.
func (s HTTPServer) completeESIMOrder(ctx context.Context, order control.CustomerOrder, purchase control.VoucherPurchase, item esimItem) error {
	store, ok := s.Store.(control.CustomerESIMStore)
	if !ok {
		return errors.New("this relay's store keeps no eSIMs")
	}
	s.warnESIMSoldAtALoss(ctx, order, purchase)
	if item.topUp() {
		// The new package will cross the same levels; the usage read is stale.
		if err := store.ClearCustomerESIMNotices(ctx, item.ICCID); err != nil {
			return err
		}
		if state := s.ESIM.state; state != nil {
			state.mu.Lock()
			delete(state.topups, item.ICCID)
			state.mu.Unlock()
		}
		return store.UpdateCustomerESIMUsage(ctx, item.ICCID, control.CustomerESIMUsage{})
	}
	if _, err := store.CustomerESIMByOrder(ctx, order.CustomerID, order.ID); err == nil {
		return nil
	} else if !errors.Is(err, control.ErrCustomerESIMNotFound) {
		return err
	}
	var details esimPurchaseDetails
	if err := json.Unmarshal(purchase.Details, &details); err != nil {
		return fmt.Errorf("reading an eSIM purchase's details: %w", err)
	}
	row := control.CustomerESIM{
		CustomerID: order.CustomerID, OrderID: order.ID, PackageID: details.PackageID,
		Title: details.Title, Data: details.Data, Days: details.Days, Operator: details.Operator,
		Destination: details.Destination, DestinationName: details.DestinationName, Country: details.Country, Image: details.Image,
		Unlimited: details.Unlimited, Rechargeable: details.Rechargeable,
		Label: order.Account[esimAccountLabel], Gift: order.Account[esimAccountGift] != "",
		TestMode: order.TestMode,
	}
	switch purchase.Supplier {
	case vouchers.SupplierESIMAccess:
		if s.ESIM.Access == nil {
			return errors.New("eSIM Access is not configured on this relay")
		}
		profiles, _, err := s.ESIM.Access.Profiles(ctx, esimaccess.ProfileQuery{OrderNo: purchase.SupplierOrderID, Size: 5})
		if err != nil {
			return err
		}
		if len(profiles) == 0 || profiles[0].ICCID == "" {
			return errors.New("eSIM Access's order holds no eSIM yet")
		}
		row.ICCID, row.Supplier, row.SupplierRef = profiles[0].ICCID, vouchers.SupplierESIMAccess, profiles[0].TranNo
		// eSIM Access issues an ICCID again once its eSIM has ended. The earlier
		// eSIM keeps its row under another key, and the number names the new one.
		if held, err := store.GetCustomerESIM(ctx, row.ICCID); err == nil && held.OrderID != order.ID &&
			esimSupplierOf(held) == vouchers.SupplierESIMAccess && held.SupplierRef != row.SupplierRef {
			if _, err := store.RetireCustomerESIM(ctx, row.ICCID); err != nil {
				return err
			}
		}
	case vouchers.SupplierAiralo:
		supplier, ok := s.Vouchers.Suppliers[vouchers.SupplierAiralo]
		if !ok {
			return errors.New("Airalo is not configured on this relay")
		}
		read, err := supplier.Lookup(ctx, vouchers.Ref{Supplier: purchase.Supplier, ID: purchase.SupplierRef}, purchase.SupplierOrderID)
		if err != nil {
			return err
		}
		if len(read.Codes) == 0 || read.Codes[0].Serial == "" {
			return errors.New("Airalo's order holds no eSIM yet")
		}
		row.ICCID, row.Supplier = read.Codes[0].Serial, vouchers.SupplierAiralo
	default:
		row.ICCID, row.Simulated = simulatedICCID(order.ID), true
	}
	saved, err := store.SaveCustomerESIM(ctx, row)
	if err != nil {
		return err
	}
	// An ICCID already held by someone else: never tell this customer it arrived.
	if saved.CustomerID != order.CustomerID || saved.OrderID != order.ID {
		return fmt.Errorf("the eSIM ending %s already belongs to another customer", iccidTail(row.ICCID))
	}
	return nil
}

// warnESIMSoldAtALoss tells the operator when the supplier charged more than the
// customer paid: prices come from the catalog, the charge only with the order. In
// Sandbox a top-up listed at $4 came back charged $7.20.
func (s HTTPServer) warnESIMSoldAtALoss(ctx context.Context, order control.CustomerOrder, purchase control.VoucherPurchase) {
	pricing, ok := s.esimPricingNow(ctx)
	// A review order is bought in Sandbox, whose prices Airalo only emulates.
	if !ok || purchase.SupplierCost == "" || order.Review {
		return
	}
	cost, costOK := new(big.Rat).SetString(purchase.SupplierCost)
	sold, err := control.ParseWalletAmount(order.UnitPrice)
	if !costOK || err != nil {
		return
	}
	inDinars := new(big.Rat).Mul(cost, pricing.rate)
	if inDinars.Cmp(sold) <= 0 {
		return
	}
	s.logger().Error("an eSIM was sold below what its supplier charged", "order_id", order.ID, "supplier", purchase.Supplier,
		"cost_usd", purchase.SupplierCost, "cost_lyd", inDinars.FloatString(3), "sold_lyd", order.UnitPrice)
	if s.Alerts != nil {
		s.Alerts.Send(alerts.Message{
			Title:    "eSIM sold at a loss: " + order.ItemName,
			Body:     "Order: " + order.ID + "\n" + purchase.Supplier + " charged " + purchase.SupplierCost + " USD (" + inDinars.FloatString(3) + " LYD)\nSold for " + order.UnitPrice + " LYD",
			Priority: alerts.PriorityUrgent,
			Tags:     []string{"warning"},
		})
	}
}

// simulatedICCID is a test eSIM's number: stable, and plainly not a real one
// (89 is telecom, 999 no country).
func simulatedICCID(orderID string) string {
	digest := sha256.Sum256([]byte(orderID))
	digits := make([]byte, 0, 15)
	for _, b := range []byte(hex.EncodeToString(digest[:])) {
		if b >= '0' && b <= '9' {
			digits = append(digits, b)
		}
		if len(digits) == 15 {
			break
		}
	}
	for len(digits) < 15 {
		digits = append(digits, '0')
	}
	return "89999" + string(digits)
}

// esimOrderName is a plan as the order, the books and a push name it: the amount
// isolated, so "3 GB" keeps its direction in Arabic text.
func esimOrderName(destination string, plan esimPlan) string {
	amount := "غير محدودة"
	if !plan.Unlimited && plan.Data != "" {
		amount = "\u2066" + plan.Data + "\u2069"
	}
	if plan.Days <= 0 {
		return destination + " · " + amount
	}
	return destination + " · " + amount + " · " + arabicDays(plan.Days)
}

// arabicDays counts days the way Arabic does.
func arabicDays(days int) string {
	switch {
	case days == 1:
		return "يوم واحد"
	case days == 2:
		return "يومان"
	case days%100 >= 3 && days%100 <= 10:
		return fmt.Sprintf("%d أيام", days)
	}
	return fmt.Sprintf("%d يوماً", days)
}

// esimAlertWhose names an eSIM in an alert to its buyer, who may have bought it
// for someone else.
func esimAlertWhose(esim control.CustomerESIM) string {
	name := esim.DestinationName
	if esim.Label != "" {
		name = esim.Label + " · " + name
	}
	return name
}

// esimTopUps is what an eSIM can be topped up with, kept briefly: the list and
// its prices are read for the page and again for the order.
type esimTopUpsAnswer struct {
	plans []esimPlan
	at    time.Time
}

const (
	esimTopUpsTTL     = 5 * time.Minute
	esimTopUpsTimeout = 10 * time.Second
)

func (s HTTPServer) esimTopUps(ctx context.Context, esim control.CustomerESIM) ([]esimPlan, error) {
	if esim.Simulated {
		return simulatedESIMTopUps(), nil
	}
	state := s.ESIM.state
	access := esimSupplierOf(esim) == vouchers.SupplierESIMAccess
	if state == nil || (access && s.ESIM.Access == nil) || (!access && s.ESIM.Client == nil) {
		return nil, errors.New("eSIMs are not configured")
	}
	now := s.clock().Now()
	state.mu.Lock()
	cached, hit := state.topups[esim.ICCID]
	state.mu.Unlock()
	if hit && now.Sub(cached.at) < esimTopUpsTTL {
		return cached.plans, nil
	}
	callCtx, cancel := context.WithTimeout(ctx, esimTopUpsTimeout)
	defer cancel()
	var plans []esimPlan
	if access {
		read, err := s.esimAccessTopUps(callCtx, esim)
		if err != nil {
			return nil, err
		}
		plans = read
	} else {
		pricing, packages, err := s.ESIM.Client.TopUps(callCtx, esim.ICCID, "ar")
		if err != nil {
			return nil, err
		}
		plans = make([]esimPlan, 0, len(packages))
		for _, source := range packages {
			plan := esimPlan{
				ID: source.ID, Title: source.Title, Data: esimDataLabel(source), AmountMB: source.AmountMB.Int(),
				Days: source.Days.Int(), Unlimited: source.Unlimited, Voice: source.Voice.Int(), Text: source.Text.Int(),
				NetUSD: pricing.CostUSD(source), RetailUSD: airaloPlanRetail(source), Info: source.ShortInfo,
			}
			if plan.ID != "" && plan.NetUSD > 0 {
				plans = append(plans, plan)
			}
		}
	}
	state.mu.Lock()
	if len(state.topups) >= esimDevicesKept {
		state.topups = map[string]esimTopUpsAnswer{}
	}
	state.topups[esim.ICCID] = esimTopUpsAnswer{plans: plans, at: now}
	state.mu.Unlock()
	return plans, nil
}

func simulatedESIMTopUps() []esimPlan {
	return []esimPlan{
		{ID: "test-topup-1gb-7d", Title: "1 GB - 7 Days", Data: "1 GB", AmountMB: 1024, Days: 7, NetUSD: 2, RetailUSD: 4.5},
		{ID: "test-topup-3gb-30d", Title: "3 GB - 30 Days", Data: "3 GB", AmountMB: 3072, Days: 30, NetUSD: 5, RetailUSD: 11},
	}
}

// parseAiraloTime reads Airalo's "2006-01-02 15:04:05" (UTC). Nil when empty.
func parseAiraloTime(text string) *time.Time {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil
	}
	for _, layout := range []string{"2006-01-02 15:04:05", time.RFC3339} {
		if at, err := time.Parse(layout, text); err == nil {
			return &at
		}
	}
	return nil
}
