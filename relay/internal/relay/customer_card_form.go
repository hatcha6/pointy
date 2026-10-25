package relay

// The card app's own bank-card form (dafa/cards.go has the background).
//
// A bank-card order still starts at Dafa, which answers a payment and its
// hosted page. Instead of opening that page, the app asks the relay for the
// Moamalat session Dafa signed for the payment, takes the card in its own
// form, pays Moamalat directly from the phone, and hands Moamalat's receipt
// back here. The card number never reaches the relay.
//
// Nothing the app sends is believed: the receipt is passed to Dafa, which
// holds the key that checks it, and the order is paid only when the payment
// read back with the relay's own key says so. Any failure leaves the order
// where Dafa's page would have: the app falls back to the page, and the
// sweep reads bank-card payments back for a day.

import (
	"context"
	"errors"
	"math/big"
	"net/http"
	"net/url"
	"strings"

	"pointy/relay/internal/control"
	"pointy/relay/internal/dafa"
)

// handleCustomerOrderCard serves POST /v1/customers/orders/{id}/card: the
// signed Moamalat session for a bank-card order still waiting for payment.
// An order past waiting comes back without one, as it is.
func (s HTTPServer) handleCustomerOrderCard(w http.ResponseWriter, r *http.Request, customer control.Customer, id string) {
	orders, _, ok := s.customerOrderStores(w)
	if !ok {
		return
	}
	order, ok := s.ownCustomerOrder(w, r, orders, customer, id)
	if !ok {
		return
	}
	method, known := lookupWalletMethod(order.Method)
	if !known || method.kind() != walletKindHostedPage {
		writeCustomerError(w, http.StatusConflict, "not_a_card_order", "this order is not paid by bank card", nil)
		return
	}
	if order.Status != control.CustomerOrderAwaitingPayment || order.PaymentID == "" || order.Review {
		s.answerCustomerOrder(w, r, orders, order, http.StatusOK)
		return
	}
	if s.Wallet.CardFormOff {
		writeCustomerError(w, http.StatusNotFound, "card_form_unavailable", "pay on the payment page", nil)
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), s.Wallet.requestTimeout())
	session, err := s.Wallet.cardGateway().Session(ctx, order.PaymentID)
	cancel()
	if err != nil {
		s.logger().Warn("dafa card session unavailable; the app falls back to the payment page",
			"order_id", order.ID, "error", err)
		writeCustomerError(w, http.StatusBadGateway, "card_form_unavailable", "pay on the payment page", nil)
		return
	}
	if session.Confirmed {
		// Paid on another try already: read it back and move on.
		if verified, err := s.verifyCustomerPayment(r.Context(), orders, order, "card"); err == nil {
			order = verified
		}
		s.answerCustomerOrder(w, r, orders, order, http.StatusOK)
		return
	}
	if !sessionMatchesOrder(session, order, s.Wallet.TestMode) {
		s.logger().Error("dafa's card session does not match its order; not offered",
			"order_id", order.ID, "payment_id", order.PaymentID, "session_amount", session.Amount, "session_test", session.Test)
		writeCustomerError(w, http.StatusBadGateway, "card_form_unavailable", "pay on the payment page", nil)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"order": customerOrderPayload(order, nil, false),
		"card_session": map[string]any{
			"mid":                session.MID,
			"tid":                session.TID,
			"amount":             session.Amount,
			"merchant_reference": session.MerchantReference,
			"trx_date_time":      session.TrxDateTime,
			"secure_hash":        session.SecureHash,
			"test":               session.Test,
		},
	})
}

// sessionMatchesOrder checks Dafa signed the figure the customer was shown,
// on the gateway the relay's key pays on.
func sessionMatchesOrder(session dafa.CardSession, order control.CustomerOrder, testMode bool) bool {
	if session.Test != testMode {
		return false
	}
	charge, err := control.ParseWalletAmount(control.CustomerOrderCharge(order))
	if err != nil {
		return false
	}
	dirhams := new(big.Rat).Mul(charge, big.NewRat(1000, 1))
	return dirhams.IsInt() && dirhams.Num().IsInt64() && dirhams.Num().Int64() == session.Amount
}

type customerCardCompleteRequest struct {
	Receipt dafa.CardReceipt `json:"receipt"`
}

// handleCustomerOrderCardComplete serves POST
// /v1/customers/orders/{id}/card/complete: Moamalat's receipt from the app,
// passed to Dafa, then the payment read back.
func (s HTTPServer) handleCustomerOrderCardComplete(w http.ResponseWriter, r *http.Request, customer control.Customer, id string) {
	orders, _, ok := s.customerOrderStores(w)
	if !ok {
		return
	}
	var request customerCardCompleteRequest
	if !decodeCustomerBody(w, r, &request) {
		return
	}
	order, ok := s.ownCustomerOrder(w, r, orders, customer, id)
	if !ok {
		return
	}
	if order.Status != control.CustomerOrderAwaitingPayment || order.PaymentID == "" {
		s.answerCustomerOrder(w, r, orders, order, http.StatusOK)
		return
	}
	receipt := request.Receipt
	// Only a receipt for this order's payment: references Dafa mints for a
	// payment are its id and a timestamp.
	if !strings.HasPrefix(strings.TrimSpace(receipt.MerchantReference), order.PaymentID+"-") {
		writeCustomerError(w, http.StatusBadRequest, "receipt_mismatch", "the receipt is for another payment", nil)
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), s.Wallet.requestTimeout())
	confirmed, err := s.Wallet.cardGateway().Complete(ctx, receipt)
	cancel()
	if err != nil {
		// Dafa confirms a paid card on its own too; the read-back and the
		// sweep still find it.
		var apiError *dafa.APIError
		if !errors.As(err, &apiError) || apiError.Status >= 500 {
			s.logger().Warn("dafa card confirm failed; left to the read-back", "order_id", order.ID, "error", err)
		} else {
			s.logger().Warn("dafa refused a card receipt", "order_id", order.ID, "status", apiError.Status)
		}
	} else if !confirmed {
		s.logger().Info("dafa has not confirmed a card receipt yet", "order_id", order.ID)
	}
	if verified, err := s.verifyCustomerPayment(r.Context(), orders, order, "card"); err == nil {
		order = verified
	}
	s.answerCustomerOrder(w, r, orders, order, http.StatusOK)
}

// customerCardReturnPath is where the card's bank sends the payer back after
// its 3-D Secure step (the code it texts). The app names it as Moamalat's
// ReturnURL and its web view stops on it, reading the bank's answer from the
// address; nothing here is believed or kept.
const customerCardReturnPath = "/v1/customers/card-return"

// handleCustomerCardReturn serves the return address. A bank that posts its
// answer is redirected to the same address with the answer in the query, so
// the web view always finds it there; the page itself is only a fallback.
func handleCustomerCardReturn(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
		if err := r.ParseForm(); err != nil || len(r.PostForm) == 0 {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		query := url.Values{}
		for key, values := range r.PostForm {
			query[key] = values
		}
		http.Redirect(w, r, customerCardReturnPath+"?"+query.Encode(), http.StatusSeeOther)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	_, _ = w.Write([]byte(`<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8">` +
		`<meta name="viewport" content="width=device-width,initial-scale=1"><title>دفتر كروت</title>` +
		`<body style="font-family:system-ui;text-align:center;padding:48px 16px">` +
		`<p>تم التحقق. ارجع إلى تطبيق دفتر كروت لإكمال الدفع.</p></body></html>`))
}
