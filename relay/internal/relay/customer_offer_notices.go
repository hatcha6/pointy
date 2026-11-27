package relay

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/fcm"
)

// An offer's notices (control.CustomerOfferNotice): it tells its recipients
// when it starts, and reminds those who have not used it the day before it
// ends. Both are sent once, by whichever node claims them first, to the
// recipients only (never its holdout, whose orders measure it), and only in
// the day in Libya: a discount is not worth waking anyone for.

const (
	// offerNoticeFrom and offerNoticeUntil are the hours, in Libya, an offer
	// may be told in.
	offerNoticeFrom  = 10
	offerNoticeUntil = 21
	// The reminder goes in the last day, but not in its last hours (too late
	// to act on), and only for an offer that ran a day and a half: a shorter
	// one was just told.
	offerReminderAhead  = 24 * time.Hour
	offerReminderLatest = 2 * time.Hour
	offerReminderMinRun = 36 * time.Hour
	// offerReminderGap keeps a reminder from following its own launch.
	offerReminderGap = 12 * time.Hour
	// offerDefaultLink is the app's page of a customer's offers.
	offerDefaultLink = "https://cards.dftr.ly/offers"
)

// libyaTime is Libya's clock (UTC+2 all year).
var libyaTime = time.FixedZone("Africa/Tripoli", 2*60*60)

// offerNoticeHours reports whether now is in the hours offers are told in.
func offerNoticeHours(now time.Time) bool {
	hour := now.In(libyaTime).Hour()
	return hour >= offerNoticeFrom && hour < offerNoticeUntil
}

// offerNoticeDue is the notice offer owes at now ("" for none).
func offerNoticeDue(offer control.CustomerOffer, now time.Time) string {
	if !offer.LiveAt(now) {
		return ""
	}
	notice := offer.Notice
	if notice.Title != "" && notice.SentAt == nil {
		return control.CustomerOfferLaunchNotice
	}
	if !notice.Remind || notice.RemindedAt != nil || offer.EndsAt == nil {
		return ""
	}
	left := offer.EndsAt.Sub(now)
	if left > offerReminderAhead || left <= offerReminderLatest || offer.EndsAt.Sub(offer.StartsAt) < offerReminderMinRun {
		return ""
	}
	if notice.SentAt != nil && now.Sub(*notice.SentAt) < offerReminderGap {
		return ""
	}
	return control.CustomerOfferReminderNotice
}

// offerNoticeMessage is what notice says.
func offerNoticeMessage(offer control.CustomerOffer, notice string) fcm.Message {
	link := offer.Notice.Link
	if link == "" {
		link = offerDefaultLink
	}
	if notice == control.CustomerOfferReminderNotice {
		return fcm.Message{
			Title:    "عرضك ينتهي غداً",
			Body:     fmt.Sprintf("«%s» ينتهي خلال يوم، ولم تستخدمه بعد.", offer.Title),
			Link:     link,
			Campaign: "offer-reminder:" + offer.ID,
		}
	}
	return fcm.Message{Title: offer.Notice.Title, Body: offer.Notice.Body, Link: link, Campaign: "offer:" + offer.ID}
}

// offerNoticeAudience is who notice goes to: the recipients (or, for an
// offer for everyone, every customer who takes notifications) and, for the
// reminder, only those with a use of it left.
func (s HTTPServer) offerNoticeAudience(ctx context.Context, store control.CustomerOfferStore, offer control.CustomerOffer, notice string) ([]string, error) {
	var ids []string
	if offer.Audience == control.CustomerOfferForEveryone {
		insights, ok := s.Store.(control.CustomerInsightStore)
		if !ok {
			return nil, errors.New("this relay keeps no customers")
		}
		facts, err := insights.CustomerFacts(ctx)
		if err != nil {
			return nil, err
		}
		for _, fact := range facts {
			if fact.DeletedAt == nil && fact.BlockedAt == nil && fact.PushDevices > 0 {
				ids = append(ids, fact.ID)
			}
		}
	} else {
		people, err := store.CustomerOfferRecipients(ctx, offer.ID)
		if err != nil {
			return nil, err
		}
		for _, person := range people {
			if !person.Holdout {
				ids = append(ids, person.CustomerID)
			}
		}
	}
	if notice != control.CustomerOfferReminderNotice {
		return ids, nil
	}
	each, all, err := store.CustomerOfferUses(ctx, offer.ID)
	if err != nil {
		return nil, err
	}
	// Used up for everyone: nothing to remind of.
	if control.OfferUsesLeft(offer, all) <= 0 {
		return nil, nil
	}
	left := ids[:0]
	for _, id := range ids {
		if each[id] < max(offer.UsesPerCustomer, 1) {
			left = append(left, id)
		}
	}
	return left, nil
}

// sendOfferNotice claims notice on offer and sends it. nil, nil when another
// node had claimed it, or no one is left to tell.
func (s HTTPServer) sendOfferNotice(ctx context.Context, offer control.CustomerOffer, notice, actor string) (*control.CustomerNotification, error) {
	store, ok := s.Store.(control.CustomerOfferStore)
	admin, ok2 := s.Store.(customerAdminStore)
	if !ok || !ok2 || s.CustomerPush == nil {
		return nil, errors.New("offer notices need customers and notifications")
	}
	ids, err := s.offerNoticeAudience(ctx, store, offer, notice)
	if err != nil {
		return nil, err
	}
	claimed, err := store.ClaimCustomerOfferNotice(ctx, offer.ID, notice, s.clock().Now())
	if err != nil || !claimed || len(ids) == 0 {
		return nil, err
	}
	message := offerNoticeMessage(offer, notice)
	record := control.CustomerNotification{
		Audience: "offer", Title: message.Title, Body: message.Body, Link: message.Link,
		Campaign: message.Campaign, SentBy: actor,
	}
	if err := s.pushToCustomers(ctx, admin, ids, message, &record); err != nil {
		record.Error = err.Error()
	}
	stored, err := admin.RecordCustomerNotification(ctx, record)
	if err != nil {
		return nil, err
	}
	s.logger().Info("offer notice sent", "offer_id", offer.ID, "notice", notice, "customers", len(ids),
		"sent", record.Sent, "failed", record.Failed)
	return &stored, nil
}

// CustomerOfferNotices sends the offer notices that come due: launches of
// offers that start later, and reminders before an offer ends.
type CustomerOfferNotices struct {
	Server   HTTPServer
	Interval time.Duration
	Logger   *slog.Logger
}

// Run sends on every interval until ctx ends.
func (n *CustomerOfferNotices) Run(ctx context.Context) {
	interval := n.Interval
	if interval <= 0 {
		interval = 5 * time.Minute
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		n.Round(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Round sends what is due now, and says how many notices went.
func (n *CustomerOfferNotices) Round(ctx context.Context) int {
	logger := n.Logger
	if logger == nil {
		logger = slog.Default()
	}
	store, ok := n.Server.Store.(control.CustomerOfferStore)
	now := n.Server.clock().Now()
	if !ok || n.Server.CustomerPush == nil || !offerNoticeHours(now) {
		return 0
	}
	offers, err := store.ListCustomerOffers(ctx)
	if err != nil {
		logger.Warn("offer notices: offers unreadable", "error", err)
		return 0
	}
	sent := 0
	for _, offer := range offers {
		notice := offerNoticeDue(offer, now)
		if notice == "" {
			continue
		}
		record, err := n.Server.sendOfferNotice(ctx, offer, notice, "offer-notices")
		if err != nil {
			logger.Warn("offer notice failed", "offer_id", offer.ID, "notice", notice, "error", err)
			continue
		}
		if record != nil {
			sent++
		}
	}
	return sent
}
