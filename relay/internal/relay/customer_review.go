package relay

import (
	"context"
	"crypto/subtle"
	"net/http"

	"pointy/relay/internal/control"
	"pointy/relay/internal/vouchers"
)

// The app stores' review account (CustomerConfig.ReviewPhone) buys like any
// customer, through the same screens and the same order states, but nothing
// it does is real:
//
//   - its payment is simulated: Dafa is never called. A wallet asks for a
//     code, and the review code (the same one it signs in with) is the right
//     one; any other is refused the way a wallet refuses it. A bank card is
//     paid at once, as there is no bank page to show.
//   - its cards come from the built-in test supplier: nothing is bought.
//   - the order is test money, so it stays out of the books.
//
// The order carries Review from the moment it is placed, so it keeps being a
// review order whatever the configuration says later. The app is told
// nothing: no flag in any answer, nothing on screen.

// reviewPaymentPrefix names a review order's simulated payment.
const reviewPaymentPrefix = "review-"

// startReviewPayment stands in for Dafa when a review order starts paying.
func (s HTTPServer) startReviewPayment(
	ctx context.Context,
	orders control.CustomerOrderStore,
	order control.CustomerOrder,
	method walletMethod,
) (control.CustomerOrder, error) {
	paymentID := reviewPaymentPrefix + order.ID
	attached, err := orders.AttachCustomerOrderPayment(ctx, order.ID, paymentID, "")
	if err != nil {
		return order, err
	}
	if method.kind() == walletKindOTP {
		// Waits for its code, as a wallet does.
		return attached, nil
	}
	paid, _, err := orders.PayCustomerOrder(ctx, order.ID, paymentID)
	if err != nil {
		return attached, err
	}
	s.logger().Info("review order paid (simulated)", "order_id", order.ID)
	return paid, nil
}

// confirmReviewPayment checks a review order's wallet code: the review code
// pays it, anything else is a wrong code (the attempt is already counted).
func (s HTTPServer) confirmReviewPayment(
	w http.ResponseWriter,
	ctx context.Context,
	orders control.CustomerOrderStore,
	cards control.VoucherStore,
	order control.CustomerOrder,
	otp string,
) {
	if subtle.ConstantTimeCompare([]byte(otp), []byte(s.Customers.ReviewCode)) != 1 ||
		s.Customers.ReviewCode == "" {
		attemptsLeft := max(0, maxWalletOTPAttempts-order.OTPAttempts)
		if attemptsLeft == 0 {
			s.closeCustomerOrderAnswer(w, ctx, orders, order, walletCodeOTPAttemptsExceeded, "too many wrong codes")
			return
		}
		writeCustomerError(w, http.StatusUnprocessableEntity, walletCodeOTPRejected, walletFailureMessage(walletCodeOTPRejected),
			map[string]any{"order": customerOrderPayload(order, nil, false), "attempts_left": attemptsLeft})
		return
	}
	paid, _, err := orders.PayCustomerOrder(ctx, order.ID, order.PaymentID)
	if err != nil {
		s.customerInternalError(w, "recording a review payment failed", err)
		return
	}
	s.logger().Info("review order paid (simulated)", "order_id", order.ID)
	paid, codes, pending := s.advanceCustomerOrder(ctx, orders, cards, paid)
	writeJSON(w, http.StatusOK, map[string]any{"order": customerOrderPayload(paid, codes, pending)})
}

// reviewSuppliers is the card configuration a review order is bought with:
// the built-in test supplier, whatever the relay really buys from, handing
// out codes that look like any card's.
func (c VoucherConfig) reviewSuppliers() VoucherConfig {
	c.TestMode = true
	c.testSupplier = vouchers.TestSupplier{Plain: true}
	return c
}
