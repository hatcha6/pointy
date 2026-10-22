package alerts

import (
	"context"
	"fmt"
	"log/slog"
	"math/big"
	"strings"
	"sync"
	"time"
)

// BalanceSource is one account the company keeps money (or credits) in at a
// provider, read on an interval and compared with a floor.
type BalanceSource struct {
	// Key names the account in alert marks and logs ("reloadly", "openrouter").
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
	// Owed, when set, answers what this balance has to cover and how many
	// holders share it: the shops' card balances, which the company owes
	// them as cards bought from this account. A balance under it alerts on
	// its own, whatever the floor says.
	Owed func(ctx context.Context) (amount *big.Rat, holders int, err error)
	// SupplementOf, when set, is the Key of the account this one only backs
	// up. While that account is healthy (read, above its floor, covering the
	// shops) this one is not read and says nothing: an unused backup left
	// low on purpose is not news.
	SupplementOf string
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
	// healthy is which sources the last check found fine, for the sources
	// that only back them up.
	healthy map[string]bool
	// nudges asks Run to re-check what the shops hold now; one waiting nudge
	// covers any number sent meanwhile.
	nudgeOnce sync.Once
	nudges    chan struct{}
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
	balanceShortMarkPrefix  = "balance_short:"
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
		case <-w.nudgeChannel():
			w.SweepOwed(ctx)
		}
	}
}

func (w *BalanceWatcher) nudgeChannel() chan struct{} {
	w.nudgeOnce.Do(func() { w.nudges = make(chan struct{}, 1) })
	return w.nudges
}

// CheckOwedSoon asks Run to compare the balances that cover the shops with
// what the shops hold, now rather than at the next sweep: a shop just moved
// money into its card balance. It never blocks, and is safe on a nil or
// disabled watcher.
func (w *BalanceWatcher) CheckOwedSoon() {
	if !w.Enabled() {
		return
	}
	select {
	case w.nudgeChannel() <- struct{}{}:
	default: // a check is already waiting; it will see this change too
	}
}

// SweepOwed checks only the sources that cover what the shops hold.
func (w *BalanceWatcher) SweepOwed(ctx context.Context) {
	w.sweep(ctx, func(source BalanceSource) bool { return source.Owed != nil })
}

// Sweep reads every source once.
func (w *BalanceWatcher) Sweep(ctx context.Context) {
	w.sweep(ctx, func(BalanceSource) bool { return true })
}

func (w *BalanceWatcher) sweep(ctx context.Context, include func(BalanceSource) bool) {
	if w.failures == nil {
		w.failures = map[string]int{}
	}
	if w.healthy == nil {
		w.healthy = map[string]bool{}
	}
	if !w.Notifier.Ready(ctx) {
		// Nobody to tell: reading now would only claim marks that would then
		// hold back the first alert once the channel is set up.
		return
	}
	// Primaries first, so a supplement is judged by this sweep's answer.
	for _, supplements := range []bool{false, true} {
		for _, source := range w.Sources {
			if ctx.Err() != nil {
				return
			}
			if (source.SupplementOf != "") != supplements || !include(source) {
				continue
			}
			if supplements && w.healthy[source.SupplementOf] {
				w.quiet(ctx, source)
				continue
			}
			w.check(ctx, source)
		}
	}
}

// quiet stands a supplement down while its primary is healthy: its marks go
// without a "back up" message, since nothing was fixed, and a later alert
// starts fresh.
func (w *BalanceWatcher) quiet(ctx context.Context, source BalanceSource) {
	w.failures[source.Key] = 0
	for _, prefix := range []string{balanceLowMarkPrefix, balanceUnreadMarkPrefix, balanceShortMarkPrefix} {
		w.release(ctx, prefix+source.Key, Message{})
	}
}

func (w *BalanceWatcher) check(ctx context.Context, source BalanceSource) {
	readCtx, cancel := context.WithTimeout(ctx, balanceReadTimeout)
	balance, err := source.Read(readCtx)
	cancel()
	if err != nil {
		w.healthy[source.Key] = false
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

	healthy := w.checkFloor(ctx, source, balance)
	if source.Owed != nil {
		healthy = w.checkOwed(ctx, source, balance) && healthy
	}
	w.healthy[source.Key] = healthy
}

func (w *BalanceWatcher) repeat() time.Duration {
	if w.Repeat <= 0 {
		return defaultBalanceRepeat
	}
	return w.Repeat
}

// checkFloor reports whether the balance is above its floor.
func (w *BalanceWatcher) checkFloor(ctx context.Context, source BalanceSource, balance *big.Rat) bool {
	amount := formatAmount(balance, source.Unit)
	if source.Floor != nil && balance.Cmp(source.Floor) <= 0 {
		priority := PriorityHigh
		if balance.Sign() <= 0 {
			priority = PriorityUrgent
		}
		w.alertOnce(ctx, balanceLowMarkPrefix+source.Key, w.repeat(), Message{
			Title:    fmt.Sprintf("%s balance low: %s", source.Name, amount),
			Body:     fmt.Sprintf("%s balance is %s, at or under the alert floor of %s. Top it up before sales start failing.", source.Name, amount, formatAmount(source.Floor, source.Unit)),
			Priority: priority,
			Tags:     []string{"rotating_light", "moneybag"},
			Click:    source.Link,
		})
		return false
	}
	w.release(ctx, balanceLowMarkPrefix+source.Key, Message{
		Title:    fmt.Sprintf("%s balance back up: %s", source.Name, amount),
		Body:     fmt.Sprintf("%s balance is %s again, above the alert floor.", source.Name, amount),
		Priority: PriorityDefault,
		Tags:     []string{"white_check_mark"},
		Click:    source.Link,
	})
	return true
}

// checkOwed alerts while the balance cannot cover what the shops hold against
// it: a shop that paid for a card in advance must never be the one to find
// the supplier account short. It reports whether the balance covers them; an
// unreadable store counts as not proven.
func (w *BalanceWatcher) checkOwed(ctx context.Context, source BalanceSource, balance *big.Rat) bool {
	readCtx, cancel := context.WithTimeout(ctx, balanceReadTimeout)
	owed, holders, err := source.Owed(readCtx)
	cancel()
	if err != nil {
		// The store is unreadable; the next sweep tries again. Neither alert
		// nor release: a missing number proves nothing either way.
		w.logger().Warn("owed balance unreadable", "source", source.Key, "error", err)
		return false
	}
	amount, owedAmount := formatAmount(balance, source.Unit), formatAmount(owed, source.Unit)
	if balance.Cmp(owed) < 0 {
		short := new(big.Rat).Sub(owed, balance)
		priority := PriorityHigh
		if balance.Sign() <= 0 {
			priority = PriorityUrgent
		}
		w.alertOnce(ctx, balanceShortMarkPrefix+source.Key, w.repeat(), Message{
			Title: fmt.Sprintf("%s short of shop card balances by %s", source.Name, formatAmount(short, source.Unit)),
			Body: fmt.Sprintf("%s balance is %s, but %s hold %s in their card balances. "+
				"A shop may be refused a card it already paid for. Top up %s by at least %s.",
				source.Name, amount, shopCount(holders), owedAmount, source.Name, formatAmount(short, source.Unit)),
			Priority: priority,
			Tags:     []string{"rotating_light", "credit_card"},
			Click:    source.Link,
		})
		return false
	}
	w.release(ctx, balanceShortMarkPrefix+source.Key, Message{
		Title:    fmt.Sprintf("%s covers shop card balances again", source.Name),
		Body:     fmt.Sprintf("%s balance is %s; %s hold %s in their card balances.", source.Name, amount, shopCount(holders), owedAmount),
		Priority: PriorityDefault,
		Tags:     []string{"white_check_mark"},
		Click:    source.Link,
	})
	return true
}

func shopCount(n int) string {
	if n == 1 {
		return "1 shop"
	}
	return fmt.Sprintf("%d shops", n)
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
