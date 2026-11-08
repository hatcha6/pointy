package relay

import (
	"context"
	"net/url"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/fcm"
	"pointy/relay/internal/vouchers"
)

// customerOrderPushBudget bounds telling one customer's phones.
const customerOrderPushBudget = 10 * time.Second

// customerOrderWaitWindow is how long the app's waiting page asks the
// customer to stay: until then it shows the ending itself, and only after it
// says «يتأخر المورّد» and that a notification will come. An order that ends
// inside it is not pushed. The app reads it from every order (wait_seconds),
// so this is the one place it is set.
const customerOrderWaitWindow = 3 * time.Minute

// tellCustomerOrderEnded lets the customer know how an order ended that their
// app was not asking about: a code a supplier delivered minutes later, or a
// card that could not be had and went back to their credit. Tapping it opens
// the order in «كروتي». Only an order that outlasted the app's waiting page
// ([customerOrderWaitWindow]) is told: one that ended sooner, even through a
// supplier's webhook, is on the customer's screen already. The app also keeps
// quiet while it shows that very order.
func (s HTTPServer) tellCustomerOrderEnded(ctx context.Context, order control.CustomerOrder, toAccount bool) {
	if s.CustomerPush == nil || order.Review || endedWithinTheWait(order, s.clock().Now()) {
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

// endedWithinTheWait reports whether the order ended inside the app's waiting
// window, counted from its payment (or from when it was placed, for one the
// customer's credit paid).
func endedWithinTheWait(order control.CustomerOrder, now time.Time) bool {
	start := order.CreatedAt
	if order.PaidAt != nil {
		start = *order.PaidAt
	}
	end := now
	if order.CompletedAt != nil {
		end = *order.CompletedAt
	}
	return end.Sub(start) < customerOrderWaitWindow
}

// customerOrderMessage is what a customer's phone says about an order that
// ended without them watching; toAccount is a card sent to an account, which
// has no code to show. A top-up names the account as the customer knows it:
// the player's account, Telegram, the Steam wallet, or a Steam gift.
func customerOrderMessage(order control.CustomerOrder, toAccount bool) (fcm.Message, bool) {
	link := customerOrderLink(order.ID)
	toAccount = toAccount || len(order.Account) > 0
	kind := orderAccountKind(order.BrandKey)
	switch order.Status {
	case control.CustomerOrderDelivered:
		if item, isESIM := parseESIMItem(order.ItemKey); isESIM {
			if item.topUp() {
				return fcm.Message{Title: "تمّ شحن شريحتك", Body: order.ItemName + " أُضيفت إلى شريحتك.", Link: customerESIMLink(item.ICCID), Order: order.ID}, true
			}
			return fcm.Message{Title: "شريحتك جاهزة للتثبيت", Body: order.ItemName + ": اضغط لتثبيتها.", Link: link, Order: order.ID}, true
		}
		if toAccount {
			title, body := "تمّ الشحن", order.ItemName+" وصل إلى "+accountPlace(kind)+"."
			switch kind {
			case vouchers.TargetSteamInvite:
				title, body = "أُرسلت الهدية", "اقبل طلب الصداقة في ستيم لتصلك "+order.ItemName+"."
			case vouchers.TargetSteam:
				title, body = "أُضيف الرصيد", order.ItemName+" أُضيف إلى محفظة ستيم."
			}
			return fcm.Message{Title: title, Body: body, Link: link, Order: order.ID}, true
		}
		return fcm.Message{Title: "رمز بطاقتك جاهز", Body: order.ItemName + ": اضغط لعرض الرمز.", Link: link, Order: order.ID}, true
	case control.CustomerOrderRefunded:
		if toAccount {
			if kind == vouchers.TargetSteamInvite {
				return fcm.Message{
					Title: "تعذّر إرسال الهدية",
					Body:  "لم نتمكن من إرسال " + order.ItemName + "، وأعدنا المبلغ إلى رصيدك.",
					Link:  link, Order: order.ID,
				}, true
			}
			return fcm.Message{
				Title: "تعذّر الشحن",
				Body:  "لم يصل " + order.ItemName + " إلى " + accountPlace(kind) + "، وأعدنا المبلغ إلى رصيدك.",
				Link:  link, Order: order.ID,
			}, true
		}
		return fcm.Message{
			Title: "تعذّر تسليم بطاقتك",
			Body:  "لم نتمكن من الحصول على " + order.ItemName + "، وأعدنا المبلغ إلى رصيدك.",
			Link:  link, Order: order.ID,
		}, true
	}
	return fcm.Message{}, false
}

// orderAccountKind is the kind of account an order's brand sends to, by the
// catalog's brand prefixes: tg- Telegram, steam- a Steam wallet, sg- a Steam
// gift; anything else a game's player account.
func orderAccountKind(brandKey string) string {
	switch {
	case strings.HasPrefix(brandKey, "tg-"):
		return vouchers.TargetTelegram
	case strings.HasPrefix(brandKey, "steam-"):
		return vouchers.TargetSteam
	case strings.HasPrefix(brandKey, "sg-"):
		return vouchers.TargetSteamInvite
	}
	return vouchers.TargetGameAccount
}

// accountPlace is where a top-up lands, as a sentence ends («إلى حساب
// اللاعب»), in the app's own words: the customer may top up someone else.
func accountPlace(kind string) string {
	switch kind {
	case vouchers.TargetTelegram:
		return "حساب تيليجرام"
	case vouchers.TargetSteam:
		return "محفظة ستيم"
	}
	return "حساب اللاعب"
}

// customerOrderLink opens one order in «كروتي».
func customerOrderLink(orderID string) string {
	return "https://cards.dftr.ly/my-cards/" + url.PathEscape(orderID)
}
