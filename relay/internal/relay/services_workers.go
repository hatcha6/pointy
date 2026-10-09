package relay

import (
	"context"
	"errors"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/services"
	"pointy/relay/internal/vouchers"
)

// billAbsentAfter is how long a bill the supplier does not list is waited for
// before its absence is believed. A payment can stay PROCESSING at the biller for
// up to a day, and Reloadly's history may not show one whose answer was lost
// while it does; a top-up answers its final state on the call (or errors), so it
// keeps the quarter hour of voucherAbsentAfter.
const billAbsentAfter = 25 * time.Hour

// heldNoun names a held purchase in a log line by what it is: a card purchase, or
// a service order (a direct top-up or a bill payment).
func heldNoun(purchase control.VoucherPurchase) string {
	if control.NormalizeVoucherKind(purchase.Kind) == control.VoucherKindCard {
		return "card purchase"
	}
	return "service order"
}

// redactedError is a supplier's error with the digits of any number or account
// it may have echoed hidden: the reconciler logs what checkServiceOrder returns,
// and a log line never holds a customer's full number.
func redactedError(err error) error {
	if err == nil {
		return nil
	}
	return errors.New(services.RedactError(err))
}

// serviceAbsentAfter is how long an order of this kind that the supplier does not
// list is waited for.
func serviceAbsentAfter(kind string) time.Duration {
	if kind == control.VoucherKindBill {
		return billAbsentAfter
	}
	return voucherAbsentAfter
}

// checkServiceOrder asks the supplier what became of a pending service order and
// settles it when the answer is clear, exactly as checkVoucherPurchase does for a
// card: an order the supplier named is read by its id, one it did not is searched
// by the identifier it was placed with (the purchase's id, which Reloadly records
// on every accepted order), and one that is nowhere is believed absent only after
// serviceAbsentAfter. An answer that cannot be read leaves the order held, and
// after voucherOperatorAfter asks for a person.
//
//	SUCCESSFUL                 carried out: the charge stands
//	FAILED / REFUNDED          not carried out, nothing debited: the price comes back
//	PROCESSING / anything else still open: asked again next time (a bill can stay
//	                           so for a day; it is never refunded before Reloadly says)
//
// Several orders under one identifier (Reloadly's duplicate check is not atomic):
// a SUCCESSFUL one wins over any FAILED or REFUNDED, so a paid order is never
// refunded because a failed twin was listed first; two SUCCESSFUL ones, or a
// failed one beside one still open, are held for a person.
func (s HTTPServer) checkServiceOrder(
	ctx context.Context,
	store control.VoucherStore,
	purchase control.VoucherPurchase,
) (control.VoucherPurchase, string, error) {
	if purchase.Status != control.VoucherPurchasePending {
		return purchase, "settled", nil
	}
	kind := control.NormalizeVoucherKind(purchase.Kind)
	executor, ok := s.Services.ExecutorFor(purchase.Supplier)
	if !ok {
		return purchase, "supplier_unconfigured", nil
	}
	now := s.clock().Now()
	age := now.Sub(purchase.CreatedAt)
	callCtx, cancel := context.WithTimeout(ctx, s.Services.RequestTimeout())
	defer cancel()

	// An order still unresolved after two days needs a person; the reconciler
	// looks every minute, the line is said every hour.
	needsPerson := func(reason string) {
		if age >= voucherOperatorAfter && s.Services.Every("unresolved:"+purchase.ID, time.Hour) {
			s.logger().Error("a service order is still unresolved; settle it with pointy-relay vouchers resolve",
				"purchase_id", purchase.ID, "installation_id", purchase.InstallationID, "kind", kind, "target", purchase.Target,
				"supplier_order_id", purchase.SupplierOrderID, "age", age.Round(time.Minute).String(), "reason", reason)
		}
	}

	if purchase.SupplierOrderID != "" {
		result, err := executor.Lookup(callCtx, kind, services.SplitOrderRef(kind, purchase.SupplierOrderID))
		if err != nil {
			reason := "the supplier could not be read: " + services.RedactError(err)
			needsPerson(reason)
			return purchase, "unreadable", redactedError(err)
		}
		switch result.Status {
		case vouchers.StatusSucceeded:
			return s.resolveServiceOrder(ctx, store, purchase, control.VoucherPurchaseResolution{
				Found:            true,
				SupplierOrderID:  purchase.SupplierOrderID,
				SupplierCost:     result.CostUSD,
				SupplierCurrency: "USD",
				Detail:           "the supplier's order shows it was carried out",
			})
		case vouchers.StatusFailed:
			return s.resolveServiceOrder(ctx, store, purchase, control.VoucherPurchaseResolution{
				Found:           false,
				SupplierOrderID: purchase.SupplierOrderID,
				Detail:          strings.TrimSpace("the supplier did not carry out the order " + result.Message),
			})
		}
		needsPerson("the supplier's order is still open")
		return purchase, "open", nil
	}

	from := purchase.CreatedAt.Add(-voucherSearchBefore)
	to := purchase.CreatedAt.Add(s.Services.RequestTimeout() + s.Services.SettleWait() + voucherSearchAfter)
	found, err := executor.FindByClientRef(callCtx, kind, purchase.ID, from, to)
	if err != nil {
		needsPerson("the supplier's history could not be read: " + services.RedactError(err))
		return purchase, "unreadable", redactedError(err)
	}
	if len(found) > 1 {
		s.logger().Error("the supplier holds several orders for one service order; keep one and settle the others by hand",
			"purchase_id", purchase.ID, "kind", kind, "orders", len(found))
	}
	ids := make([]string, 0, len(found))
	for _, candidate := range found {
		ids = append(ids, services.OrderRef(kind, candidate.OrderID))
	}
	claimed, err := store.VoucherClaimedSupplierOrders(ctx, purchase.Supplier, ids)
	if err != nil {
		return purchase, "unreadable", err
	}
	var paid, refused, open []services.Result
	for _, candidate := range found {
		if ref := services.OrderRef(kind, candidate.OrderID); ref == "" || claimed[ref] {
			continue
		}
		switch candidate.Status {
		case vouchers.StatusSucceeded:
			paid = append(paid, candidate)
		case vouchers.StatusFailed:
			refused = append(refused, candidate)
		default:
			open = append(open, candidate)
		}
	}
	switch {
	case len(paid) > 1:
		// Two orders were carried out under one identifier: the company paid twice.
		// Which one the ledger keeps, and what to do about the other, is for a person.
		if s.Services.Every("twice:"+purchase.ID, time.Hour) {
			s.logger().Error("the supplier holds several SUCCESSFUL orders for one service order; it stays held, settle it by hand (pointy-relay vouchers resolve)",
				"purchase_id", purchase.ID, "installation_id", purchase.InstallationID, "kind", kind, "target", purchase.Target, "orders", len(paid))
		}
		return purchase, "ambiguous", nil
	case len(paid) == 1:
		return s.resolveServiceOrder(ctx, store, purchase, control.VoucherPurchaseResolution{
			Found:            true,
			SupplierOrderID:  services.OrderRef(kind, paid[0].OrderID),
			SupplierCost:     paid[0].CostUSD,
			SupplierCurrency: "USD",
			Detail:           "found in the supplier's order history",
		})
	case len(open) > 0:
		// Found, and still open at the supplier: nothing is refunded while an
		// order may yet be carried out. Its id is kept so the next look reads the
		// order itself.
		needsPerson("the supplier's order is still open")
		return purchase, "open", nil
	case len(refused) > 0:
		return s.resolveServiceOrder(ctx, store, purchase, control.VoucherPurchaseResolution{
			Found:           false,
			SupplierOrderID: services.OrderRef(kind, refused[0].OrderID),
			Detail:          strings.TrimSpace("the supplier did not carry out the order " + refused[0].Message),
		})
	}
	if age < serviceAbsentAfter(kind) {
		if kind == control.VoucherKindBill && age >= voucherAbsentAfter && s.Services.Every("waiting:"+purchase.ID, time.Hour) {
			// Not an error: a payment may stay processing for a day. But somebody
			// reading the log should see that a bill is being waited for.
			s.logger().Warn("a bill the supplier does not list yet is still waited for; a payment can stay processing for a day",
				"purchase_id", purchase.ID, "installation_id", purchase.InstallationID, "target", purchase.Target,
				"age", age.Round(time.Minute).String(), "refund_after", serviceAbsentAfter(kind).String())
		}
		return purchase, "waiting", nil
	}
	return s.resolveServiceOrder(ctx, store, purchase, control.VoucherPurchaseResolution{
		Found:  false,
		Detail: "not in the supplier's order history",
	})
}

func (s HTTPServer) resolveServiceOrder(
	ctx context.Context,
	store control.VoucherStore,
	purchase control.VoucherPurchase,
	resolution control.VoucherPurchaseResolution,
) (control.VoucherPurchase, string, error) {
	resolved, applied, err := store.ResolveVoucherPurchase(ctx, purchase.ID, resolution)
	if err != nil {
		if errors.Is(err, control.ErrVoucherOrderClaimed) {
			s.logger().Error("a supplier order matched two purchases; settle by hand",
				"purchase_id", purchase.ID, "supplier_order_id", resolution.SupplierOrderID)
		}
		return purchase, "unrecorded", err
	}
	if !applied {
		return resolved, "settled", nil
	}
	verdict := "refunded"
	if resolved.Status == control.VoucherPurchaseSucceeded {
		verdict = "carried out"
	}
	s.logger().Info("a held service order was settled",
		"purchase_id", resolved.ID, "installation_id", resolved.InstallationID, "kind", resolved.Kind, "target", resolved.Target,
		"verdict", verdict, "supplier_order_id", resolved.SupplierOrderID, "detail", services.Redact(resolution.Detail))
	return resolved, verdict, nil
}
