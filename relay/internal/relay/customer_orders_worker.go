package relay

import (
	"context"
	"log/slog"
	"time"

	"pointy/relay/internal/control"
)

// CustomerOrderReconciler keeps «دفتر كروت» orders moving when nobody is
// asking about them: the app closed mid-payment, a webhook that never came, a
// relay that died between the payment and the card.
//
// Each round it writes off orders whose payment never came (their held credit
// goes back), reads unproven payments back from Dafa (recent ones every round,
// the rest every fifteenth), and takes paid orders on to their card. A
// payment proven after its order was written off becomes the customer's
// credit. Several relay nodes may run it at once: every step is exactly-once
// in the store.
type CustomerOrderReconciler struct {
	Server   HTTPServer
	Interval time.Duration
	Logger   *slog.Logger
	rounds   int
}

const (
	customerReconcileFresh   = time.Hour
	customerReconcileHorizon = 24 * time.Hour
	customerReconcileSlow    = 15
	customerReconcileBatch   = 500
)

// Round runs one pass and reports how many orders it moved.
func (c *CustomerOrderReconciler) Round(ctx context.Context) int {
	logger := c.Logger
	if logger == nil {
		logger = slog.Default()
	}
	orders, ok := c.Server.Store.(control.CustomerOrderStore)
	if !ok {
		return 0
	}
	cards, hasCards := c.Server.voucherStore()
	now := c.Server.clock().Now().UTC()
	slowTurn := c.rounds%customerReconcileSlow == 0
	c.rounds++
	moved := 0
	if expired, err := orders.ExpireCustomerOrders(ctx, now.Add(-c.Server.Customers.orderTTL())); err != nil {
		logger.Warn("expiring unpaid customer orders failed", "error", err)
	} else {
		moved += expired
	}
	list, err := orders.ListCustomerOrders(ctx, control.CustomerOrderFilter{
		Sweep: true, CreatedAfter: now.Add(-customerReconcileHorizon), Limit: customerReconcileBatch,
	})
	if err != nil {
		logger.Warn("listing customer orders failed", "error", err)
		return moved
	}
	for _, order := range list {
		if ctx.Err() != nil {
			break
		}
		before := order.Status
		if c.paymentWorthReading(order, now, slowTurn) {
			verified, err := c.Server.verifyCustomerPayment(ctx, orders, order, "sweep")
			if err != nil {
				logger.Warn("customer order sweep: reading a payment back failed", "order_id", order.ID, "error", err)
				continue
			}
			order = verified
		}
		if hasCards && (order.Status == control.CustomerOrderPaid || order.Status == control.CustomerOrderFulfilling) {
			order, _, _ = c.Server.advanceCustomerOrder(ctx, orders, cards, order)
		}
		if order.Status != before {
			moved++
		}
	}
	return moved
}

// paymentWorthReading reports whether an order's payment may have landed
// without the relay hearing: a payment started and the payer engaged with it
// (a bank-card page is always worth reading), or one written off that Dafa
// may still complete.
func (c *CustomerOrderReconciler) paymentWorthReading(order control.CustomerOrder, now time.Time, slowTurn bool) bool {
	if order.PaymentID == "" || order.LatePaid {
		return false
	}
	switch order.Status {
	case control.CustomerOrderAwaitingPayment:
	case control.CustomerOrderExpired, control.CustomerOrderCancelled, control.CustomerOrderFailed:
		// Only a bank-card page can complete a payment the relay wrote off.
		if order.CheckoutURL == "" {
			return false
		}
	default:
		return false
	}
	method, known := lookupWalletMethod(order.Method)
	if known && method.kind() == walletKindOTP && order.OTPAttempts == 0 {
		// Only the relay confirms a wallet payment, and it never sent a code.
		return false
	}
	return now.Sub(order.CreatedAt) < customerReconcileFresh || slowTurn
}

// Run rounds on every interval until ctx ends.
func (c *CustomerOrderReconciler) Run(ctx context.Context) {
	interval := c.Interval
	if interval <= 0 {
		interval = 30 * time.Second
	}
	logger := c.Logger
	if logger == nil {
		logger = slog.Default()
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if moved := c.Round(ctx); moved > 0 {
			logger.Info("customer order sweep moved orders", "moved", moved)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
