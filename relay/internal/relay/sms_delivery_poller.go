package relay

import (
	"context"
	"errors"
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
	result.Candidates = len(candidates)
	if len(candidates) == 0 {
		// Nothing awaits a report, so the provider is not asked at all.
		return result, nil
	}
	oldest := smsCandidateTime(candidates[0])
	for _, candidate := range candidates[1:] {
		if at := smsCandidateTime(candidate); at.Before(oldest) {
			oldest = at
		}
	}
	floor := oldest.Add(-smsDeliveryPageSlack)

	var rows []resala.SentMessage
	for page := 1; page <= smsDeliveryMaxPages; page++ {
		sent, err := p.Client.ListSent(ctx, resala.SentQuery{
			Source:  "message",
			Page:    page,
			PerPage: smsDeliveryPageSize,
		})
		if err != nil {
			if page == 1 {
				return result, err
			}
			// Match what was read; the next sync reads the rest.
			p.logger().Warn("sms delivery log page failed", "page", page, "error", err)
			break
		}
		rows = append(rows, sent.Messages...)
		if len(sent.Messages) == 0 {
			break
		}
		if last := sent.Messages[len(sent.Messages)-1]; !last.CreatedAt.IsZero() && last.CreatedAt.Before(floor) {
			break
		}
		if sent.LastPage > 0 && page >= sent.LastPage {
			break
		}
		if sent.LastPage == 0 && len(sent.Messages) < smsDeliveryPageSize {
			break
		}
	}
	result.LogRows = len(rows)

	for _, match := range matchSMSDeliveries(candidates, rows) {
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
	if result.Matched > 0 {
		p.logger().Info(
			"sms delivery sync",
			"candidates", result.Candidates,
			"log_rows", result.LogRows,
			"delivered", result.Delivered,
			"undelivered", result.Undelivered,
			"tagged", result.Tagged,
		)
	}
	return result, nil
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
func matchSMSDeliveries(candidates []control.SMSMessage, rows []resala.SentMessage) []smsDeliveryMatch {
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
			distance := row.CreatedAt.Sub(sentAt)
			if distance < 0 {
				distance = -distance
			}
			if distance > smsDeliveryMatchWindow {
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
