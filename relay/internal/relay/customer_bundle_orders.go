package relay

import (
	"context"
	"fmt"
	"math/big"
	"net/http"
	"strings"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// An order for a bundle (customer_bundles.go) names its size as `item` and
// the card picked for each part as `bundle_items`. It is one order and one
// payment; each card is then its own supplier purchase, bought the way a card
// on its own is. A card that cannot be bought after the payment gives the
// customer back its share as credit, and the rest are delivered; only when
// none can be bought is the whole order refunded.
//
// On the books each card is a sale at its shelf price, except the card that
// carries the saving (the first part the company fixed, the game card),
// which is sold for its price less the saving.

// pricedBundle is a bundle order as the shelf prices it now.
type pricedBundle struct {
	bundle control.CustomerBundle
	tier   control.CustomerBundleTier
	cards  []control.CustomerBundleCard
	price  *big.Rat
	name   string
}

// quoteKey names a bundle order's exact cards, for a price-changed answer's
// quote: a quote for one pick never prices another.
func (p pricedBundle) quoteKey() string {
	items := make([]string, len(p.cards))
	for i, card := range p.cards {
		items[i] = card.Item
	}
	return p.tier.Key + "|" + strings.Join(items, ",")
}

// priceCustomerBundle checks a bundle order against the shelf and prices it:
// every picked card one of its part's, sold as a code on this channel, on
// sale now; the saving under the cards' prices.
func (s HTTPServer) priceCustomerBundle(
	ctx context.Context,
	customer control.Customer,
	cards control.VoucherStore,
	tierKey string,
	items []string,
	channel string,
) (pricedBundle, *customerRefusal) {
	unavailable := &customerRefusal{http.StatusConflict, "item_unavailable", "this bundle cannot be bought right now", nil}
	bundle, tier, found := findBundleTier(s.customerBundles(ctx), tierKey)
	if !found {
		return pricedBundle{}, &customerRefusal{http.StatusNotFound, "unknown_item", "no bundle has this size", nil}
	}
	if len(items) != len(tier.Parts) {
		return pricedBundle{}, &customerRefusal{http.StatusBadRequest, "invalid_bundle_items",
			fmt.Sprintf("bundle_items names one card for each of the %d parts", len(tier.Parts)), nil}
	}
	saving, err := control.ParseWalletAmount(tier.Saving)
	if err != nil {
		return pricedBundle{}, unavailable
	}
	out := pricedBundle{bundle: bundle, tier: tier}
	prices := make([]*big.Rat, len(items))
	apart := new(big.Rat)
	labels := []string{}
	for i, item := range items {
		item = strings.TrimSpace(item)
		inPart := false
		for _, option := range tier.Parts[i] {
			inPart = inPart || option == item
		}
		if !inPart {
			return pricedBundle{}, &customerRefusal{http.StatusBadRequest, "invalid_bundle_items",
				fmt.Sprintf("bundle_items[%d] is not a card of this part", i), nil}
		}
		if _, isESIM := parseESIMItem(item); isESIM {
			return pricedBundle{}, unavailable
		}
		priced, refusal := s.priceCustomerItem(ctx, customer, cards, item, 1, channel)
		if refusal != nil {
			return pricedBundle{}, unavailable
		}
		if priced.located.Brand.Target != nil {
			// A card sent to an account is never bundled.
			return pricedBundle{}, unavailable
		}
		prices[i] = priced.price
		apart.Add(apart, priced.price)
		label := itemLabel(priced.located.Item)
		labels = append(labels, label)
		out.cards = append(out.cards, control.CustomerBundleCard{
			Item: priced.itemKey, Brand: priced.brandKey, Label: label,
			Price: control.FormatWalletAmount(priced.price), Booked: control.FormatWalletAmount(priced.price),
		})
	}
	carrier := savingCarrier(tier.Parts)
	booked := new(big.Rat).Sub(prices[carrier], saving)
	if booked.Sign() <= 0 {
		// The saving would take the game card to nothing: not sold.
		return pricedBundle{}, unavailable
	}
	out.cards[carrier].Booked = control.FormatWalletAmount(booked)
	out.price = new(big.Rat).Sub(apart, saving)
	out.name = bundle.Name + " · " + strings.Join(labels, " + ")
	return out, nil
}

// sameBundleRequest reports whether a replayed request picks the cards the
// order it names was placed with.
func sameBundleRequest(order control.CustomerOrder, items []string) bool {
	if len(order.Bundle) != len(items) {
		return false
	}
	for i, card := range order.Bundle {
		if card.Item != strings.TrimSpace(items[i]) {
			return false
		}
	}
	return true
}

// --- moving a bundle order along --------------------------------------------------

func customerBundlePurchaseKey(orderID string, part int) string {
	return fmt.Sprintf("%s%s:%d", customerOrderKeyPrefix, orderID, part)
}

// advanceCustomerBundle is advanceCustomerOrder for a bundle: it claims and
// buys each card not bought yet, then, once every card's purchase has ended,
// delivers those bought and refunds those not.
func (s HTTPServer) advanceCustomerBundle(
	ctx context.Context,
	orders control.CustomerOrderStore,
	cards control.VoucherStore,
	order control.CustomerOrder,
	watching bool,
) (control.CustomerOrder, []vouchers.Code, bool) {
	if order.Status == control.CustomerOrderDelivered {
		return s.customerBundleCodes(ctx, cards, order, nil)
	}
	if order.Status != control.CustomerOrderPaid && order.Status != control.CustomerOrderFulfilling {
		return order, nil, false
	}
	bundles, ok := s.Store.(control.CustomerBundleStore)
	if !ok {
		return order, nil, false
	}
	n := len(order.Bundle)
	purchases := make([]control.VoucherPurchase, n)
	claimed := make([]bool, n)
	failures := make([]string, n)
	fresh := make([][]vouchers.Code, n)
	for i := range order.Bundle {
		existing, found, err := cards.FindVoucherPurchaseByKey(ctx, "", customerBundlePurchaseKey(order.ID, i))
		if err != nil {
			s.logger().Error("customer bundle purchase lookup failed", "order_id", order.ID, "part", i, "error", err)
			return order, nil, false
		}
		if found {
			purchases[i], claimed[i] = existing, true
		}
	}
	missing := 0
	for i := range claimed {
		if !claimed[i] {
			missing++
		}
	}
	if missing > 0 {
		shelf := s.loadBundleShelf(ctx, cards)
		type ready struct {
			located vouchers.Located
			ranking supplierRanking
		}
		found := make([]*ready, n)
		for i, card := range order.Bundle {
			if claimed[i] {
				continue
			}
			located, ranking, ok := s.locateOnShelf(shelf, card.Item, order.Review)
			if !ok {
				failures[i] = "the card left the catalog before it could be bought"
				continue
			}
			if reason, _ := ranking.unavailable(); reason != "" {
				failures[i] = reason
				continue
			}
			found[i] = &ready{located, ranking}
		}
		if missing == n {
			// Nothing bought yet: a card that cannot be had stops the whole
			// order before any is bought.
			for i := range failures {
				if failures[i] != "" {
					if _, _, err := orders.FinishCustomerOrder(ctx, order.ID, false, "item_unavailable", failures[i]); err != nil {
						s.logger().Error("refunding a customer bundle failed", "order_id", order.ID, "error", err)
					} else {
						s.logger().Warn("customer bundle refunded to credit before buying", "order_id", order.ID, "part", i)
					}
					refreshed, err := orders.GetCustomerOrder(ctx, order.ID)
					if err == nil {
						order = refreshed
					}
					return order, nil, false
				}
			}
		}
		for i, card := range order.Bundle {
			if claimed[i] || found[i] == nil {
				continue
			}
			located, ranking := found[i].located, found[i].ranking
			first := ranking.Candidates[0]
			claim, created, err := cards.BeginVoucherPurchase(ctx, control.VoucherPurchase{
				IdempotencyKey: customerBundlePurchaseKey(order.ID, i),
				ItemKey:        located.Item.Key,
				BrandKey:       located.Brand.Key,
				ItemName:       located.Name(),
				Quantity:       1,
				// What the order books for this card: the saving comes off
				// the game card's line.
				UnitPrice:   card.Booked,
				Supplier:    first.Supplier.Key(),
				SupplierRef: first.Ref.ID,
				TestMode:    s.Vouchers.MarksTest() || order.TestMode,
				Purpose:     control.VoucherPurposeCustomer,
				Note:        order.ID,
			})
			if err != nil {
				s.logger().Error("customer bundle purchase claim failed", "order_id", order.ID, "part", i, "error", err)
				return order, nil, false
			}
			claimed[i], purchases[i] = true, claim
			if created {
				purchases[i], fresh[i] = s.buyClaimedCards(vouchers.WithoutSettling(ctx), cards, claim, ranking, 1, nil)
			}
		}
		ids := make([]string, n)
		firstID := ""
		for i := range purchases {
			if claimed[i] {
				ids[i] = purchases[i].ID
				if firstID == "" {
					firstID = purchases[i].ID
				}
			}
		}
		if firstID != "" {
			if order.Status == control.CustomerOrderPaid {
				started, err := orders.StartCustomerOrderFulfilment(ctx, order.ID, firstID)
				if err != nil {
					s.logger().Error("tying a customer bundle to its purchases failed", "order_id", order.ID, "error", err)
					return order, nil, false
				}
				order = started
			}
			if recorded, err := bundles.RecordCustomerBundlePurchases(ctx, order.ID, ids); err == nil {
				order = recorded
			} else {
				s.logger().Error("recording a customer bundle's purchases failed", "order_id", order.ID, "error", err)
			}
		}
	}

	// Every card's purchase must have ended before the order does.
	pending := false
	for i := range purchases {
		if !claimed[i] || purchases[i].Status != control.VoucherPurchasePending {
			continue
		}
		purchase := purchases[i]
		if purchase.HeldSince != nil || s.clock().Now().Sub(purchase.CreatedAt) >= s.Vouchers.staleAfter() {
			if checked, _, err := s.checkVoucherPurchase(ctx, cards, purchase); err == nil {
				purchases[i] = checked
			}
		}
		pending = pending || purchases[i].Status == control.VoucherPurchasePending
	}
	if pending {
		return order, nil, true
	}
	delivered := 0
	code, detail := "", ""
	for i := range purchases {
		switch {
		case claimed[i] && purchases[i].Status == control.VoucherPurchaseSucceeded:
			delivered++
		case claimed[i]:
			code = shopFailureCode(purchases[i].ErrorCode)
			detail = shopFailureDetail(purchases[i].ErrorCode, purchases[i].ErrorDetail)
		default:
			code, detail = "item_unavailable", failures[i]
		}
	}
	if delivered == 0 {
		finished, applied, err := orders.FinishCustomerOrder(ctx, order.ID, false, code, detail)
		if err != nil {
			s.logger().Error("refunding a customer bundle failed", "order_id", order.ID, "error", err)
			return order, nil, false
		}
		if applied {
			s.logger().Warn("customer bundle refunded to credit", "order_id", order.ID, "total", finished.Total, "code", code)
			if !watching {
				s.tellCustomerOrderEnded(ctx, finished, false)
			}
		}
		return finished, nil, false
	}
	for i := range purchases {
		if claimed[i] && purchases[i].Status == control.VoucherPurchaseSucceeded {
			continue
		}
		partCode, partDetail := "item_unavailable", failures[i]
		if claimed[i] {
			partCode = shopFailureCode(purchases[i].ErrorCode)
			partDetail = shopFailureDetail(purchases[i].ErrorCode, purchases[i].ErrorDetail)
		}
		refunded, applied, err := bundles.RefundCustomerBundleCard(ctx, order.ID, i, partCode, partDetail)
		if err != nil {
			s.logger().Error("refunding a customer bundle's card failed", "order_id", order.ID, "part", i, "error", err)
			return order, nil, false
		}
		order = refunded
		if applied {
			s.logger().Warn("a card of a customer bundle refunded to credit", "order_id", order.ID, "part", i,
				"item", order.Bundle[i].Item, "amount", order.Bundle[i].Booked, "code", partCode)
		}
	}
	finished, applied, err := orders.FinishCustomerOrder(ctx, order.ID, true, "", "")
	if err != nil {
		s.logger().Error("recording a delivered customer bundle failed", "order_id", order.ID, "error", err)
		return order, nil, false
	}
	if applied {
		s.logger().Info("customer bundle delivered", "order_id", order.ID, "cards", delivered, "of", n)
		if !watching {
			s.tellCustomerOrderEnded(ctx, finished, false)
		}
	}
	return s.customerBundleCodes(ctx, cards, finished, fresh)
}

// customerBundleCodes reads a delivered bundle's codes, each marked with its
// card; fresh are codes a supplier just handed over, by part.
func (s HTTPServer) customerBundleCodes(
	ctx context.Context,
	cards control.VoucherStore,
	order control.CustomerOrder,
	fresh [][]vouchers.Code,
) (control.CustomerOrder, []vouchers.Code, bool) {
	out := []vouchers.Code{}
	pending := false
	for i, card := range order.Bundle {
		if card.Refunded || card.PurchaseID == "" {
			continue
		}
		var codes []vouchers.Code
		if i < len(fresh) && len(fresh[i]) > 0 {
			codes = fresh[i]
		} else {
			purchase, err := cards.GetVoucherPurchase(ctx, card.PurchaseID)
			if err != nil {
				pending = true
				continue
			}
			var waiting bool
			codes, waiting = s.voucherCodes(ctx, purchase)
			pending = pending || waiting
		}
		for _, code := range codes {
			code.Brand, code.Item = card.Brand, card.Item
			out = append(out, code)
		}
	}
	return order, out, pending
}

// customerBundlePayload is what a bundle order adds to its JSON.
func customerBundlePayload(order control.CustomerOrder, payload map[string]any) {
	items := make([]string, len(order.Bundle))
	refunded := []string{}
	for i, card := range order.Bundle {
		items[i] = card.Item
		if card.Refunded {
			refunded = append(refunded, card.Item)
		}
	}
	payload["bundle_items"] = items
	payload["bundle_refunded"] = refunded
	payload["refunded"] = control.NormalizeWalletAmount(order.Refunded)
}
