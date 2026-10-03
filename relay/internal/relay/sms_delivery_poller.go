package relay

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/observability"
	"pointy/relay/internal/resala"
)

// SMSDeliveryPoller learns what happened to sent messages.
//
// Resala has no delivery webhook and its send answer carries no message id, so
// the only way to know whether an SMS reached a phone is to read the account's
// delivery log back and recognise our own messages in it: same number, sent
// within minutes of the ledger row, and — when the ledger has it — the same
// content hash. The poller does that on an interval for the last 48 hours of
// real sends still at "sent", so the ledger can say "delivered" or
// "undelivered" instead of only "handed to the provider".
//
// The same read settles held messages: sends that failed in a way that leaves
// it unknown whether the SMS went out, whose price is kept until the log is
// checked. One found in the log — same number, same text, within minutes —
// went out after all and stays paid for; one the log does not show once it has
// had time to, in a read that reached back past it, is refunded.
type SMSDeliveryPoller struct {
	Client   SMSSentLister
	Store    control.SMSStore
	Interval time.Duration
	Logger   *slog.Logger
	Clock    control.Clock
	Metrics  *observability.Metrics
}

// SMSSentLister is the part of the Resala client the poller reads with.
type SMSSentLister interface {
	ListSent(ctx context.Context, query resala.SentQuery) (resala.SentPage, error)
}

const (
	defaultSMSDeliverySyncInterval = 5 * time.Minute
	minSMSDeliverySyncInterval     = time.Minute
	// A carrier that has not reported after two days is not going to.
	smsDeliveryLookback       = 48 * time.Hour
	smsDeliveryCandidateLimit = 500
	smsDeliveryPageSize       = 100
	// The log is the whole fleet's traffic, newest first; ten pages is the
	// most one sync reads, however far back the oldest candidate is.
	smsDeliveryMaxPages = 10
	// Paging stops once rows are older than the oldest candidate by this much.
	smsDeliveryPageSlack = 15 * time.Minute
	// A log row and a ledger row are the same message only if Resala stamped
	// it within this long of our send.
	smsDeliveryMatchWindow = 10 * time.Minute

	// A held message is its log row only with the same text, stamped within
	// this long of the send — longer than for a delivery report, because a
	// Resala that timed out may have finished the send late.
	smsSentLogCheckWindow = 15 * time.Minute
	// A held message the log does not show is refunded once it has been held
	// this long, and only after a read that reached back past it.
	smsSentLogCheckGrace = 15 * time.Minute
	// A hold the log could not settle in this long — Resala's log unreadable
	// all that time — is refunded unchecked rather than kept forever.
	smsSentLogCheckDeadline = 48 * time.Hour
	smsSentLogCheckLimit    = 200
	// Paging may go this deep to reach back past the oldest held message.
	smsSentLogCheckMaxPages = 50
)

// SMSDeliverySyncResult is what one sync did.
type SMSDeliverySyncResult struct {
	Candidates  int
	LogRows     int
	Matched     int
	Delivered   int
	Undelivered int
	// Tagged counts rows still at "sent" whose provider id was recorded, which
	// pins their match for every later sync.
	Tagged int
	// Held is how many held messages were checked: Kept went out after all,
	// Refunded never did, Expired were refunded unchecked past the deadline.
	Held     int
	Kept     int
	Refunded int
	Expired  int
}

// smsSentLogRead is how far back one sync read the log.
type smsSentLogRead struct {
	// Oldest is the earliest stamp among the rows read.
	Oldest time.Time
	// Complete means the log had nothing older: every row was read.
	Complete bool
}

// covers reports whether the read reached back past a message's window, so a
// message it did not find is not in the log.
func (r smsSentLogRead) covers(message control.SMSMessage) bool {
	if r.Complete {
		return true
	}
	return !r.Oldest.IsZero() && r.Oldest.Before(smsCandidateTime(message).Add(-smsSentLogCheckWindow))
}

func (p *SMSDeliveryPoller) interval() time.Duration {
	switch {
	case p.Interval >= minSMSDeliverySyncInterval:
		return p.Interval
	case p.Interval > 0:
		return minSMSDeliverySyncInterval
	default:
		return defaultSMSDeliverySyncInterval
	}
}

func (p *SMSDeliveryPoller) logger() *slog.Logger {
	if p.Logger != nil {
		return p.Logger
	}
	return slog.Default()
}

func (p *SMSDeliveryPoller) now() time.Time {
	if p.Clock != nil {
		return p.Clock.Now()
	}
	return time.Now().UTC()
}

// Enabled reports whether there is anything to poll with.
func (p *SMSDeliveryPoller) Enabled() bool {
	return p != nil && p.Client != nil && p.Store != nil
}

// Run syncs until ctx is cancelled: once at startup, then on the interval.
// Failures are logged and retried on the next tick; a provider outage never
// takes the relay down.
func (p *SMSDeliveryPoller) Run(ctx context.Context) {
	if !p.Enabled() {
		p.logger().Info("sms delivery sync disabled")
		return
	}
	p.logger().Info("sms delivery sync started", "interval", p.interval().String())
	ticker := time.NewTicker(p.interval())
	defer ticker.Stop()
	for {
		if _, err := p.SyncOnce(ctx); err != nil && !errors.Is(err, context.Canceled) {
			p.logger().Warn("sms delivery sync failed", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// SyncOnce reads the delivery log and applies what it can match.
func (p *SMSDeliveryPoller) SyncOnce(ctx context.Context) (SMSDeliverySyncResult, error) {
	var result SMSDeliverySyncResult
	now := p.now()
	candidates, err := p.Store.ListSMSAwaitingDelivery(ctx, now.Add(-smsDeliveryLookback), smsDeliveryCandidateLimit)
	if err != nil {
		return result, err
	}
	held, err := p.Store.ListSMSAwaitingCheck(ctx, smsSentLogCheckLimit)
	if err != nil {
		return result, err
	}
	result.Candidates = len(candidates)
	result.Held = len(held)
	if len(candidates) == 0 && len(held) == 0 {
		// Nothing awaits a report, so the provider is not asked at all.
		return result, nil
	}

	rows, read, err := p.readSentLog(ctx, candidates, held)
	if err != nil {
		// Unreadable: holds past the deadline are refunded unchecked rather
		// than kept forever; the rest wait for the next sync.
		p.expireHolds(ctx, held, now, &result)
		return result, err
	}
	result.LogRows = len(rows)
	claimed, checkHeld := p.claimedLogRows(ctx, held, rows)

	pool := candidates
	if checkHeld {
		pool = append(append([]control.SMSMessage(nil), candidates...), held...)
	}
	found := map[string]bool{}
	for _, match := range matchSMSDeliveries(pool, rows, claimed) {
		if match.Message.HeldSince != nil {
			found[match.Message.ID] = true
			p.keepHeld(ctx, match, &result)
			continue
		}
		status, known := smsDeliveryStatus(match.Row.Status)
		if !known {
			// Accepted but not reported yet; nothing to record.
			continue
		}
		if status == control.SMSStatusSent && match.Message.ProviderMessageID == match.Row.ID {
			continue
		}
		at := match.Row.UpdatedAt
		if at.IsZero() {
			at = now
		}
		if err := p.Store.UpdateSMSDelivery(ctx, match.Message.ID, status, match.Row.ID, at); err != nil {
			if errors.Is(err, context.Canceled) {
				return result, err
			}
			p.logger().Error("recording an sms delivery failed", "ledger_id", match.Message.ID, "error", err)
			continue
		}
		result.Matched++
		switch status {
		case control.SMSStatusDelivered:
			result.Delivered++
		case control.SMSStatusUndelivered:
			result.Undelivered++
		default:
			result.Tagged++
		}
		p.Metrics.RecordSMSDelivery(status)
	}
	if checkHeld {
		for _, message := range held {
			if !found[message.ID] {
				p.settleUnseen(ctx, message, read, now, &result)
			}
		}
	} else {
		p.expireHolds(ctx, held, now, &result)
	}
	if result.Matched > 0 || result.Kept > 0 || result.Refunded > 0 || result.Expired > 0 {
		p.logger().Info(
			"sms delivery sync",
			"candidates", result.Candidates,
			"log_rows", result.LogRows,
			"delivered", result.Delivered,
			"undelivered", result.Undelivered,
			"tagged", result.Tagged,
			"held", result.Held,
			"kept", result.Kept,
			"refunded", result.Refunded,
			"expired", result.Expired,
		)
	}
	return result, nil
}

// readSentLog reads the log newest first: back past the oldest delivery
// candidate within the usual page budget, and further — within a larger one —
// when a held message needs it, so a busy log does not leave a hold unsettled.
func (p *SMSDeliveryPoller) readSentLog(
	ctx context.Context,
	candidates, held []control.SMSMessage,
) ([]resala.SentMessage, smsSentLogRead, error) {
	deliveryFloor := smsOldestCandidate(candidates).Add(-smsDeliveryPageSlack)
	checkFloor := smsOldestCandidate(held).Add(-smsSentLogCheckWindow - smsDeliveryPageSlack)
	var rows []resala.SentMessage
	var read smsSentLogRead
	var last time.Time
	reached := func(floor time.Time) bool { return !last.IsZero() && last.Before(floor) }
	for page := 1; ; page++ {
		needDelivery := len(candidates) > 0 && page <= smsDeliveryMaxPages && !reached(deliveryFloor)
		needCheck := len(held) > 0 && page <= smsSentLogCheckMaxPages && !reached(checkFloor)
		if !needDelivery && !needCheck {
			break
		}
		sent, err := p.Client.ListSent(ctx, resala.SentQuery{
			Source:  "message",
			Page:    page,
			PerPage: smsDeliveryPageSize,
		})
		if err != nil {
			if page == 1 {
				return nil, read, err
			}
			// Match what was read; the next sync reads the rest.
			p.logger().Warn("sms delivery log page failed", "page", page, "error", err)
			break
		}
		rows = append(rows, sent.Messages...)
		for _, row := range sent.Messages {
			if !row.CreatedAt.IsZero() && (read.Oldest.IsZero() || row.CreatedAt.Before(read.Oldest)) {
				read.Oldest = row.CreatedAt
			}
		}
		if len(sent.Messages) == 0 ||
			(sent.LastPage > 0 && page >= sent.LastPage) ||
			(sent.LastPage == 0 && len(sent.Messages) < smsDeliveryPageSize) {
			read.Complete = true
			break
		}
		last = sent.Messages[len(sent.Messages)-1].CreatedAt
	}
	return rows, read, nil
}

// claimedLogRows is the set of log rows another message already owns, among
// those a held message could match. checkHeld is false when that cannot be
// known right now, and the holds then wait for the next sync.
func (p *SMSDeliveryPoller) claimedLogRows(
	ctx context.Context,
	held []control.SMSMessage,
	rows []resala.SentMessage,
) (map[string]bool, bool) {
	if len(held) == 0 {
		return nil, false
	}
	recipients := map[string]bool{}
	for _, message := range held {
		recipients[message.Recipient] = true
	}
	var ids []string
	for _, row := range rows {
		if row.ID != "" && recipients[smsLogRecipient(row)] {
			ids = append(ids, row.ID)
		}
	}
	claimed, err := p.Store.SMSClaimedProviderIDs(ctx, ids)
	if err != nil {
		p.logger().Warn("reading which sms log rows are matched failed; held messages wait", "error", err)
		return nil, false
	}
	return claimed, true
}

// keepHeld records that a held message went out after all: it stays paid
// for, settled to the parts its log text took, and joins delivery tracking.
func (p *SMSDeliveryPoller) keepHeld(ctx context.Context, match smsDeliveryMatch, result *SMSDeliverySyncResult) {
	message, row := match.Message, match.Row
	status, known := smsDeliveryStatus(row.Status)
	if !known {
		// Accepted and on its way: it went out, the carrier has not said more.
		status = control.SMSStatusSent
	}
	resolution := control.SMSCheckResolution{
		WentOut:           true,
		Status:            status,
		ProviderMessageID: row.ID,
		SentAt:            row.CreatedAt,
		Detail: fmt.Sprintf(
			"resala's sent log shows the message went out after the send failed (%s); it stays paid for",
			message.ErrorCode,
		),
	}
	if row.Content != "" {
		resolution.Parts = resala.CountParts(row.Content)
		resolution.SettleDescription = smsChargeDescription(message.Kind, resolution.Parts)
	}
	// The answer that carries the cost was lost: price the parts at what
	// Resala charged per part on the latest send, so the usage report's cost
	// and margin stay true.
	if perPart, err := p.Store.SMSPartCost(ctx); err != nil {
		p.logger().Warn("reading resala's latest per-part cost failed", "error", err)
	} else if perPart != "" {
		parts := resolution.Parts
		if parts == 0 {
			parts = message.Parts
		}
		resolution.Cost = control.SMSCostOfParts(perPart, parts)
		resolution.Detail += "; its cost is estimated at resala's latest per-part rate"
	}
	if status == control.SMSStatusDelivered && !row.UpdatedAt.IsZero() {
		at := row.UpdatedAt
		resolution.DeliveredAt = &at
	}
	resolved, applied, err := p.Store.ResolveSMSCheck(ctx, message.ID, resolution)
	if err != nil {
		p.logger().Error("keeping a held sms failed", "ledger_id", message.ID, "error", err)
		return
	}
	if !applied {
		return
	}
	result.Kept++
	p.Metrics.RecordSMSCheck("kept")
	p.logger().Info(
		"a held sms went out after all; it stays paid for",
		"installation_id", resolved.InstallationID,
		"ledger_id", resolved.ID,
		"failed_with", message.ErrorCode,
		"status", resolved.Status,
		"parts", resolved.Parts,
		"charged", resolved.Price,
	)
}

// settleUnseen decides a held message the log did not show: refunded once it
// has been held long enough and the read reached back past it, refunded
// unchecked past the deadline, otherwise left for the next sync.
func (p *SMSDeliveryPoller) settleUnseen(
	ctx context.Context,
	message control.SMSMessage,
	read smsSentLogRead,
	now time.Time,
	result *SMSDeliverySyncResult,
) {
	heldFor := now.Sub(*message.HeldSince)
	switch {
	case heldFor >= smsSentLogCheckDeadline:
		p.expireHold(ctx, message, result)
	case heldFor >= smsSentLogCheckGrace && read.covers(message):
		resolved, applied, err := p.Store.ResolveSMSCheck(ctx, message.ID, control.SMSCheckResolution{
			Detail: fmt.Sprintf(
				"resala's sent log does not show the message after the send failed (%s); refunded",
				message.ErrorCode,
			),
		})
		if err != nil {
			p.logger().Error("refunding a held sms failed", "ledger_id", message.ID, "error", err)
			return
		}
		if !applied {
			return
		}
		result.Refunded++
		p.Metrics.RecordSMSCheck("refunded")
		p.logger().Info(
			"a held sms never went out; refunded",
			"installation_id", resolved.InstallationID,
			"ledger_id", resolved.ID,
			"failed_with", message.ErrorCode,
			"refunded", resolved.Price,
		)
	}
}

// expireHolds refunds, unchecked, every hold past the deadline.
func (p *SMSDeliveryPoller) expireHolds(
	ctx context.Context,
	held []control.SMSMessage,
	now time.Time,
	result *SMSDeliverySyncResult,
) {
	for _, message := range held {
		if now.Sub(*message.HeldSince) >= smsSentLogCheckDeadline {
			p.expireHold(ctx, message, result)
		}
	}
}

func (p *SMSDeliveryPoller) expireHold(ctx context.Context, message control.SMSMessage, result *SMSDeliverySyncResult) {
	resolved, applied, err := p.Store.ResolveSMSCheck(ctx, message.ID, control.SMSCheckResolution{
		Detail: fmt.Sprintf(
			"resala's sent log could not be checked for %s after the send failed (%s); refunded unchecked",
			smsSentLogCheckDeadline, message.ErrorCode,
		),
	})
	if err != nil {
		p.logger().Error("refunding an expired sms hold failed", "ledger_id", message.ID, "error", err)
		return
	}
	if !applied {
		return
	}
	result.Expired++
	p.Metrics.RecordSMSCheck("expired")
	p.logger().Error(
		"a held sms was refunded without the sent-log check: resala's log could not be read in time",
		"installation_id", resolved.InstallationID,
		"ledger_id", resolved.ID,
		"failed_with", message.ErrorCode,
		"refunded", resolved.Price,
	)
}

// smsOldestCandidate is the earliest send among messages; zero for none.
func smsOldestCandidate(messages []control.SMSMessage) time.Time {
	var oldest time.Time
	for _, message := range messages {
		if at := smsCandidateTime(message); oldest.IsZero() || at.Before(oldest) {
			oldest = at
		}
	}
	return oldest
}

// smsDeliveryMatch pairs one ledger row with the delivery-log row it became.
type smsDeliveryMatch struct {
	Message control.SMSMessage
	Row     resala.SentMessage
}

// matchSMSDeliveries pairs ledger rows with delivery-log rows, each side used
// at most once.
//
// A ledger row whose provider id is already known matches only that row. Any
// other pairing needs the same number and a Resala timestamp within ten minutes
// of the send. Among the qualifying pairs, the best go first — a pinned id,
// then an identical content hash, then the nearest in time — and are taken
// greedily across ALL candidates, so one message cannot take a row that is a
// better (content-identical) match for another message to the same phone.
//
// A held message decides money, so it is held to more: the identical text,
// within fifteen minutes, and never a row in claimed (one some other message
// already owns).
func matchSMSDeliveries(
	candidates []control.SMSMessage,
	rows []resala.SentMessage,
	claimed map[string]bool,
) []smsDeliveryMatch {
	type pairing struct {
		candidate   int
		row         int
		pinned      bool
		sameContent bool
		distance    time.Duration
	}
	recipients := make([]string, len(rows))
	hashes := make([]string, len(rows))
	for i, row := range rows {
		recipients[i] = smsLogRecipient(row)
		if row.Content != "" {
			hashes[i] = smsContentSHA256(row.Content)
		}
	}
	var pairings []pairing
	for ci, candidate := range candidates {
		sentAt := smsCandidateTime(candidate)
		held := candidate.HeldSince != nil
		window := smsDeliveryMatchWindow
		if held {
			window = smsSentLogCheckWindow
		}
		for ri, row := range rows {
			if recipients[ri] == "" || recipients[ri] != candidate.Recipient || !smsLogRowIsReal(row) {
				continue
			}
			if candidate.ProviderMessageID != "" {
				if row.ID != "" && row.ID == candidate.ProviderMessageID {
					pairings = append(pairings, pairing{candidate: ci, row: ri, pinned: true})
				}
				continue
			}
			if row.CreatedAt.IsZero() {
				continue
			}
			if held && (candidate.ContentSHA256 == "" || candidate.ContentSHA256 != hashes[ri] || claimed[row.ID]) {
				continue
			}
			distance := row.CreatedAt.Sub(sentAt)
			if distance < 0 {
				distance = -distance
			}
			if distance > window {
				continue
			}
			pairings = append(pairings, pairing{
				candidate:   ci,
				row:         ri,
				sameContent: candidate.ContentSHA256 != "" && candidate.ContentSHA256 == hashes[ri],
				distance:    distance,
			})
		}
	}
	sort.SliceStable(pairings, func(i, j int) bool {
		a, b := pairings[i], pairings[j]
		if a.pinned != b.pinned {
			return a.pinned
		}
		if a.sameContent != b.sameContent {
			return a.sameContent
		}
		if a.distance != b.distance {
			return a.distance < b.distance
		}
		if candidates[a.candidate].ID != candidates[b.candidate].ID {
			return candidates[a.candidate].ID < candidates[b.candidate].ID
		}
		return rows[a.row].ID < rows[b.row].ID
	})
	takenCandidates := map[int]bool{}
	takenRows := map[int]bool{}
	var matches []smsDeliveryMatch
	for _, pair := range pairings {
		if takenCandidates[pair.candidate] || takenRows[pair.row] {
			continue
		}
		takenCandidates[pair.candidate] = true
		takenRows[pair.row] = true
		matches = append(matches, smsDeliveryMatch{Message: candidates[pair.candidate], Row: rows[pair.row]})
	}
	return matches
}

// smsDeliveryStatus maps Resala's delivery state (whatever its casing) to the
// ledger's. known is false while the carrier has not reported: "" (null) and
// "accepted" mean the message is on its way, not that anything happened.
func smsDeliveryStatus(raw string) (status string, known bool) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "delivered":
		return control.SMSStatusDelivered, true
	case "undelivered", "undeliverable", "failed", "rejected", "expired":
		return control.SMSStatusUndelivered, true
	case "sent":
		return control.SMSStatusSent, true
	default:
		return "", false
	}
}

// smsLogRecipient puts a delivery-log number in the ledger's "218…" form.
// Resala writes the national number and the calling code separately.
func smsLogRecipient(row resala.SentMessage) string {
	if normalized, ok := resala.NormalizeLibyanMobile(row.Number); ok {
		return normalized
	}
	if normalized, ok := resala.NormalizeLibyanMobile(row.Code + row.Number); ok {
		return normalized
	}
	return ""
}

// smsLogRowIsReal skips log rows that cannot be one of our real sends: test
// sends (a non-production env) and anything that is not a template message.
func smsLogRowIsReal(row resala.SentMessage) bool {
	if env := strings.ToLower(strings.TrimSpace(row.Env)); env != "" && env != "production" && env != "prod" {
		return false
	}
	if source := strings.ToLower(strings.TrimSpace(row.Source)); source != "" && source != "message" {
		return false
	}
	return true
}

// smsCandidateTime is when the ledger saw the send go out: after Resala
// answered when known, else when the row was claimed just before the call.
func smsCandidateTime(message control.SMSMessage) time.Time {
	if message.SentAt != nil {
		return *message.SentAt
	}
	return message.CreatedAt
}
