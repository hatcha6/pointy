package relay

import (
	"math/rand/v2"
	"strconv"
	"sync"
	"time"
)

// HandshakeLimiter is a token bucket on connector handshakes, shared by the
// TCP listener and the WebSocket tunnel route of one node.
//
// A node that restarts would otherwise take every shop's reconnect at once:
// each is a TLS handshake plus a token lookup and a certificate check, and a
// few thousand of those together starve the node of CPU, so handshakes time
// out and the shops come back again. Refusing the excess cheaply, before any
// TLS work, spreads the herd out instead.
type HandshakeLimiter struct {
	mu     sync.Mutex
	rate   float64
	burst  float64
	tokens float64
	last   time.Time
	now    func() time.Time
}

// NewHandshakeLimiter allows perSecond handshakes on average with bursts of
// up to burst. perSecond <= 0 turns the limit off (nil).
func NewHandshakeLimiter(perSecond float64, burst int) *HandshakeLimiter {
	if perSecond <= 0 {
		return nil
	}
	if burst < 1 {
		burst = 1
	}
	return &HandshakeLimiter{
		rate:   perSecond,
		burst:  float64(burst),
		tokens: float64(burst),
		now:    time.Now,
	}
}

// Allow takes one token if there is one. A nil limiter allows everything.
func (l *HandshakeLimiter) Allow() bool {
	if l == nil {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if !l.last.IsZero() {
		l.tokens += now.Sub(l.last).Seconds() * l.rate
		if l.tokens > l.burst {
			l.tokens = l.burst
		}
	}
	l.last = now
	if l.tokens < 1 {
		return false
	}
	l.tokens--
	return true
}

// tunnelRetryAfter is the Retry-After told to a connector the node turned
// away: 1-3 s, random, so the shops refused in one burst don't all come back
// in the same second.
func tunnelRetryAfter() string {
	return strconv.Itoa(1 + rand.IntN(3))
}
