package moamalat

import "time"

// The keepalive cadence. Both holders of a token — the shop's backend and the
// relay — follow the same rules, each on its own clock and unaware of the
// other (TOKEN_CUSTODY_DESIGN.md §Keepalive cadence). The design window is 14
// minutes: the longest silence measured to survive; the first measured death
// was at 15.
const (
	// Tick is the routine gap between pokes: three fit in the window.
	Tick = 4 * time.Minute
	// TickJitter spreads the fleet so every shop is not poked in step.
	TickJitter = 15 * time.Second
	// AtRiskAfter is how long without an accepted poke before the holder
	// retries every AtRiskRetry and raises the at-risk alert.
	AtRiskAfter = 8 * time.Minute
	AtRiskRetry = 30 * time.Second
	// Window is the design window: the latest a 429's Retry-After may push
	// the next attempt.
	Window = 14 * time.Minute
	// LapsedAfter is past the window. The token may still live — the other
	// holder may have kept it warm — and only Moamalat's answer settles it, so
	// the holder keeps asking, just slower.
	LapsedAfter = 15 * time.Minute
	LapsedRetry = 2 * time.Minute
	// minDelay keeps a misbehaving clock from turning into a hot loop.
	minDelay = 5 * time.Second
)

// retryLadder is the spacing of retries after consecutive transient failures,
// before the at-risk cadence takes over.
var retryLadder = []time.Duration{20 * time.Second, 60 * time.Second, 120 * time.Second}

// NextAfterSuccess is the gap to the next poke after an accepted one. jitter
// is a value in [-1, 1].
func NextAfterSuccess(jitter float64) time.Duration {
	if jitter > 1 {
		jitter = 1
	} else if jitter < -1 {
		jitter = -1
	}
	return Tick + time.Duration(jitter*float64(TickJitter))
}

// NextAfterFailure is the gap to the next poke after a transient failure.
//
// age is the time since this holder's last accepted poke (or since it was
// handed the token, if it never had one), failures the consecutive transient
// failures including this one, retryAfter a 429's Retry-After.
func NextAfterFailure(age time.Duration, failures int, retryAfter time.Duration) time.Duration {
	var delay time.Duration
	switch {
	case age >= LapsedAfter:
		delay = LapsedRetry
	case age >= AtRiskAfter:
		delay = AtRiskRetry
	default:
		if failures >= 1 && failures <= len(retryLadder) {
			delay = retryLadder[failures-1]
		} else {
			delay = Tick
		}
		// Never sleep past the point where the at-risk cadence should start.
		if age+delay > AtRiskAfter {
			delay = AtRiskAfter - age
		}
	}
	if retryAfter > delay {
		delay = retryAfter
		// Politeness must not kill the token: land before the window closes.
		if age < Window && age+delay > Window-AtRiskRetry {
			delay = Window - AtRiskRetry - age
		}
	}
	if delay < minDelay {
		delay = minDelay
	}
	return delay
}

// AtRisk reports whether a holder that last succeeded age ago is at risk.
func AtRisk(age time.Duration) bool {
	return age >= AtRiskAfter
}
