package relay

import (
	"context"
	"net/url"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/fcm"
)

// customerOrderPushBudget bounds telling one customer's phones.
const customerOrderPushBudget = 10 * time.Second

// tellCustomerOrderEnded lets the customer know how an order ended that their
// app was not asking about: a code a supplier delivered minutes later, or a
// card that could not be had and went back to their credit. Tapping it opens
// the order in «كروتي». The app keeps quiet while it shows that very order, so
// a customer still on the waiting screen sees the code there instead.
func (s HTTPServer) tellCustomerOrderEnded(ctx context.Context, order control.CustomerOrder, toAccount bool) {
	if s.CustomerPush == nil || order.Review {
		return
	}
	store, ok := s.Store.(customerAdminStore)
	if !ok {
		return
	}
	message, ok := customerOrderMessage(order, toAccount)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), customerOrderPushBudget)
	defer cancel()
	sessions, err := store.CustomerSessions(ctx, order.CustomerID)
	if err != nil {
		s.logger().Warn("telling a customer their order ended: sessions unreadable", "order_id", order.ID, "error", err)
		return
	}
	var record control.CustomerNotification
	s.pushToDevices(ctx, store, sessions, message, &record)
	if record.Devices > 0 {
		s.logger().Info("told a customer their order ended", "order_id", order.ID, "status", order.Status,
			"devices", record.Devices, "sent", record.Sent, "failed", record.Failed)
	}
}

// customerOrderMessage is what a customer's phone says about an order that
// ended without them watching; toAccount is a card sent to an account, which
// has no code to show.
func customerOrderMessage(order control.CustomerOrder, toAccount bool) (fcm.Message, bool) {
	link := customerOrderLink(order.ID)
	switch order.Status {
	case control.CustomerOrderDelivered:
		if toAccount {
			return fcm.Message{Title: "تمّ الشحن", Body: order.ItemName + " وصل إلى حسابك.", Link: link, Order: order.ID}, true
		}
		return fcm.Message{Title: "رمز بطاقتك جاهز", Body: order.ItemName + ": اضغط لعرض الرمز.", Link: link, Order: order.ID}, true
	case control.CustomerOrderRefunded:
		return fcm.Message{
			Title: "تعذّر تسليم بطاقتك",
			Body:  "لم نتمكن من الحصول على " + order.ItemName + "، وأعدنا المبلغ إلى رصيدك.",
			Link:  link, Order: order.ID,
		}, true
	}
	return fcm.Message{}, false
}

// customerOrderLink opens one order in «كروتي».
func customerOrderLink(orderID string) string {
	return "https://cards.dftr.ly/my-cards/" + url.PathEscape(orderID)
}
