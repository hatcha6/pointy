package relay

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"time"

	"pointy/relay/internal/control"
)

// FulusPoller is the backstop behind the webhook.
//
// Webhooks are the fast path: fulus pushes a rate the moment it is published
// and shops see it within seconds. But a webhook is a single delivery attempt
// over a network we do not control — a relay restart, a deploy, a transient
// 502, a misconfigured secret upstream, or fulus simply dropping the retry all
// end the same way: a rate that was published and never stored. Nothing about
// that failure is visible, either. The fleet would quietly go on pricing
// imports off a stale number.
//
// So the poller sweeps the provider on an interval and upserts whatever it
// finds. Because the store keys on the publication's natural identity
// (from, to, instrument, bank, effective_at), a rate that arrived by webhook
// and again by poll collapses into one row — the two paths cost nothing when
// they overlap, and the poll is the one that heals the gap when the webhook
// did not arrive.
type FulusPoller struct {
	Client   *FulusClient
	Store    control.ExchangeRateStore
	Interval time.Duration
	Logger   *slog.Logger
	Clock    control.Clock
}

const (
	defaultFulusPollInterval = 30 * time.Minute
	minFulusPollInterval     = time.Minute
	// fulus resets its daily quota at midnight UTC+2. Burning the quota would
	// disable the very backstop this type exists to be, so a 429 parks the
	// poller until the reset instead of retrying into a wall.
	fulusQuotaResetOffsetHours = 2
)

func (p *FulusPoller) interval() time.Duration {
	if p.Interval >= minFulusPollInterval {
		return p.Interval
	}
	if p.Interval > 0 {
		return minFulusPollInterval
	}
	return defaultFulusPollInterval
}

func (p *FulusPoller) logger() *slog.Logger {
	if p.Logger != nil {
		return p.Logger
	}
	return slog.Default()
}

func (p *FulusPoller) now() time.Time {
	if p.Clock != nil {
		return p.Clock.Now()
	}
	return time.Now()
}

// Enabled reports whether there is anything to poll. A relay with no fulus
// token still serves rates that arrived by webhook or were entered by an
// operator; it simply has no upstream to sweep.
func (p *FulusPoller) Enabled() bool {
	return p != nil && p.Client != nil && p.Store != nil && p.Client.config.configured()
}

// Run sweeps until ctx is cancelled. It polls once immediately — a relay that
// has just restarted is exactly when the webhook gap is most likely — and then
// on the interval.
func (p *FulusPoller) Run(ctx context.Context) {
	if !p.Enabled() {
		p.logger().Info("fulus poller disabled (no token configured)")
		return
	}
	p.logger().Info("fulus poller started", "interval", p.interval())

	ticker := time.NewTicker(p.interval())
	defer ticker.Stop()

	var quotaBlockedUntil time.Time
	for {
		if now := p.now(); quotaBlockedUntil.IsZero() || now.After(quotaBlockedUntil) {
			if blocked := p.PollOnce(ctx); blocked {
				quotaBlockedUntil = nextFulusQuotaReset(p.now())
				p.logger().Warn(
					"fulus daily quota exhausted; poller paused until reset",
					"resumes_at", quotaBlockedUntil,
				)
			} else {
				quotaBlockedUntil = time.Time{}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// PollOnce fetches both series and stores what it finds. It returns true when
// the provider reported its daily quota exhausted, so the caller can park.
//
// Errors are logged and swallowed: a provider outage must never take the relay
// down, and the fleet keeps serving the rates it already holds.
func (p *FulusPoller) PollOnce(ctx context.Context) (quotaExhausted bool) {
	stored := 0
	for _, source := range []struct {
		name  string
		fetch func(context.Context) ([]control.ExchangeRate, error)
	}{
		{"current", p.Client.FetchCurrentRates},
		{"banks", p.Client.FetchBankRates},
	} {
		rates, err := source.fetch(ctx)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return false
			}
			if isFulusQuotaError(err) {
				p.logger().Warn("fulus poll hit the daily quota", "series", source.name)
				return true
			}
			p.logger().Warn("fulus poll failed", "series", source.name, "error", err)
			continue
		}
		for _, rate := range rates {
			if _, err := p.Store.UpsertExchangeRate(ctx, rate); err != nil {
				p.logger().Error(
					"storing a polled fulus rate failed",
					"from", rate.FromCode,
					"instrument", rate.Instrument,
					"error", err,
				)
				continue
			}
			stored++
		}
	}
	if stored > 0 {
		// Logged at info because this is the line that tells an operator the
		// backstop is doing its job when the webhook silently is not.
		p.logger().Info("fulus poll stored rates", "count", stored)
	}
	return false
}

func isFulusQuotaError(err error) bool {
	return err != nil && strings.Contains(err.Error(), "daily quota exhausted")
}

// nextFulusQuotaReset is the next midnight in UTC+2, where fulus resets.
func nextFulusQuotaReset(now time.Time) time.Time {
	zone := time.FixedZone("UTC+2", fulusQuotaResetOffsetHours*60*60)
	local := now.In(zone)
	midnight := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, zone)
	return midnight.Add(24 * time.Hour).UTC()
}
