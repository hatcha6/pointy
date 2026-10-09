package alerts

import (
	"context"
	"fmt"
	"log/slog"
	"math/big"
	"strings"
	"time"
)

// BalanceSource is one account the company keeps money (or credits) in at a
// provider, read on an interval and compared with a floor.
type BalanceSource struct {
	// Key names the account in alert marks and logs ("reloadly", "serper").
	Key string
	// Name is how the alert names it ("Reloadly", "BN Plus (LYD)").
	Name string
	// Unit is what the balance counts ("USD", "LYD", "credits").
	Unit string
	// Floor is the balance at or under which the alert fires.
	Floor *big.Rat
	// Read answers the balance now.
	Read func(ctx context.Context) (*big.Rat, error)
	// Link is the console page about this account, opened from the alert.
	Link string
}

// Marks is how relay instances agree on what was alerted (see
// control.AlertStore).
type Marks interface {
	ClaimAlert(ctx context.Context, key string, cooldown time.Duration) (bool, error)
	ReleaseAlert(ctx context.Context, key string) (bool, error)
}

// BalanceWatcher reads every source on an interval and alerts once when one
// falls to its floor, again every Repeat while it stays there, and once more
// when it is topped back up. A source that cannot be read UnreadableAfter
// times running is alerted too: a revoked key hides a balance just as well as
// an empty one.
type BalanceWatcher struct {
	Sources  []BalanceSource
	Notifier *Ntfy
	Marks    Marks
	Interval time.Duration
	// Repeat is how often a balance still low is said again.
	Repeat          time.Duration
	UnreadableAfter int
	Logger          *slog.Logger

	failures map[string]int
}

const (
	defaultBalanceInterval  = 15 * time.Minute
	defaultBalanceRepeat    = 12 * time.Hour
	defaultUnreadableAfter  = 4
	defaultUnreadableRepeat = 24 * time.Hour
	balanceReadTimeout      = 30 * time.Second
	balanceStartupStagger   = 30 * time.Second
	balanceLowMarkPrefix    = "balance_low:"
	balanceUnreadMarkPrefix = "balance_unreadable:"
)

func (w *BalanceWatcher) logger() *slog.Logger {
	if w.Logger != nil {
		return w.Logger
	}
	return slog.Default()
}

// Enabled reports whether there is anything to watch and anywhere to say it.
func (w *BalanceWatcher) Enabled() bool {
	return w != nil && w.Notifier != nil && w.Marks != nil && len(w.Sources) > 0
}

// Run watches until ctx ends. The first sweep waits a little, so a relay that
// is still starting (or crash-looping) does not hammer every provider.
func (w *BalanceWatcher) Run(ctx context.Context) {
	if !w.Enabled() {
		return
	}
	interval := w.Interval
	if interval <= 0 {
		interval = defaultBalanceInterval
	}
	select {
	case <-ctx.Done():
		return
	case <-time.After(balanceStartupStagger):
	}
	w.Sweep(ctx)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			w.Sweep(ctx)
		}
	}
}

// Sweep reads every source once.
func (w *BalanceWatcher) Sweep(ctx context.Context) {
	if w.failures == nil {
		w.failures = map[string]int{}
	}
	if !w.Notifier.Ready(ctx) {
		// Nobody to tell: reading now would only claim marks that would then
		// hold back the first alert once the channel is set up.
		return
	}
	for _, source := range w.Sources {
		if ctx.Err() != nil {
			return
		}
		w.check(ctx, source)
	}
}

func (w *BalanceWatcher) check(ctx context.Context, source BalanceSource) {
	readCtx, cancel := context.WithTimeout(ctx, balanceReadTimeout)
	balance, err := source.Read(readCtx)
	cancel()
	if err != nil {
		w.failures[source.Key]++
		w.logger().Warn("provider balance unreadable", "source", source.Key, "failures", w.failures[source.Key], "error", err)
		after := w.UnreadableAfter
		if after <= 0 {
			after = defaultUnreadableAfter
		}
		if w.failures[source.Key] >= after {
			w.alertOnce(ctx, balanceUnreadMarkPrefix+source.Key, defaultUnreadableRepeat, Message{
				Title:    source.Name + " balance unreadable",
				Body:     fmt.Sprintf("The relay could not read the %s balance %d times running.\nLast error: %s", source.Name, w.failures[source.Key], truncate(err.Error(), 300)),
				Priority: PriorityHigh,
				Tags:     []string{"warning"},
				Click:    source.Link,
			})
		}
		return
	}
	w.failures[source.Key] = 0
	w.release(ctx, balanceUnreadMarkPrefix+source.Key, Message{})

	amount := formatAmount(balance, source.Unit)
	if source.Floor != nil && balance.Cmp(source.Floor) <= 0 {
		repeat := w.Repeat
		if repeat <= 0 {
			repeat = defaultBalanceRepeat
		}
		priority := PriorityHigh
		if balance.Sign() <= 0 {
			priority = PriorityUrgent
		}
		w.alertOnce(ctx, balanceLowMarkPrefix+source.Key, repeat, Message{
			Title:    fmt.Sprintf("%s balance low: %s", source.Name, amount),
			Body:     fmt.Sprintf("%s balance is %s, at or under the alert floor of %s. Top it up before sales start failing.", source.Name, amount, formatAmount(source.Floor, source.Unit)),
			Priority: priority,
			Tags:     []string{"rotating_light", "moneybag"},
			Click:    source.Link,
		})
		return
	}
	w.release(ctx, balanceLowMarkPrefix+source.Key, Message{
		Title:    fmt.Sprintf("%s balance back up: %s", source.Name, amount),
		Body:     fmt.Sprintf("%s balance is %s again, above the alert floor.", source.Name, amount),
		Priority: PriorityDefault,
		Tags:     []string{"white_check_mark"},
		Click:    source.Link,
	})
}

// alertOnce sends message when this instance wins the mark.
func (w *BalanceWatcher) alertOnce(ctx context.Context, key string, repeat time.Duration, message Message) {
	won, err := w.Marks.ClaimAlert(ctx, key, repeat)
	if err != nil {
		w.logger().Warn("alert mark unclaimable; alert not sent", "key", key, "error", err)
		return
	}
	if !won {
		return
	}
	if err := w.Notifier.Publish(ctx, message); err != nil {
		// Undelivered: give the mark back so the next sweep tries again.
		w.logger().Warn("relay alert not delivered", "title", message.Title, "error", err)
		if _, releaseErr := w.Marks.ReleaseAlert(ctx, key); releaseErr != nil {
			w.logger().Warn("alert mark not released", "key", key, "error", releaseErr)
		}
	}
}

// release drops the mark and, when it was there and message has a title, says
// the condition is over.
func (w *BalanceWatcher) release(ctx context.Context, key string, message Message) {
	had, err := w.Marks.ReleaseAlert(ctx, key)
	if err != nil {
		w.logger().Warn("alert mark not released", "key", key, "error", err)
		return
	}
	if had && message.Title != "" {
		if err := w.Notifier.Publish(ctx, message); err != nil {
			w.logger().Warn("relay alert not delivered", "title", message.Title, "error", err)
		}
	}
}

// formatAmount writes a balance for a phone screen: two decimals for money,
// none for a count of credits.
func formatAmount(amount *big.Rat, unit string) string {
	places := 2
	if strings.EqualFold(unit, "credits") {
		places = 0
	}
	return strings.TrimSpace(amount.FloatString(places) + " " + unit)
}

func truncate(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit]) + "…"
}
