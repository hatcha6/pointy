package relay

import (
	"context"
	"errors"
	"log/slog"
	"math/rand/v2"
	"sync"
	"time"

	"pointy/relay/internal/alerts"
	"pointy/relay/internal/control"
	"pointy/relay/internal/moamalat"
)

// MoamalatKeeper keeps every shop's Moamalat token warm: the relay half of the
// keepalive (TOKEN_CUSTODY_DESIGN.md). It runs on every relay instance; the
// store's claim queue hands each due poke to exactly one of them, so a shop is
// poked once per tick however many instances run.
type MoamalatKeeper struct {
	Store  control.InstallationStore
	Client *moamalat.Client
	Sealer *moamalat.Sealer
	Alerts *alerts.Ntfy
	Logger *slog.Logger
	// Interval is how often an instance looks for due pokes; the cadence
	// itself lives on the rows.
	Interval time.Duration
	// Concurrency bounds the pokes in flight on one instance.
	Concurrency int
	// Jitter returns a value in [-1, 1]; nil uses math/rand.
	Jitter func() float64
}

const (
	moamalatClaimBatch = 50
	// moamalatClaimLease outlives a poke (15 s timeout) with room to write
	// it back; a row whose instance died is poked again after it.
	moamalatClaimLease       = 60 * time.Second
	defaultMoamalatInterval  = 5 * time.Second
	defaultMoamalatInFlight  = 8
	moamalatAtRiskCooldown   = 24 * time.Hour
	moamalatReauthCooldown   = 30 * 24 * time.Hour
	moamalatAlertPrefixRisk  = "moamalat_at_risk:"
	moamalatAlertPrefixDeath = "moamalat_reauth:"
)

// Enabled reports whether the keeper has what it needs to run.
func (k *MoamalatKeeper) Enabled() bool {
	if k == nil || k.Sealer == nil || k.Client == nil {
		return false
	}
	_, ok := k.Store.(control.MoamalatStore)
	return ok
}

func (k *MoamalatKeeper) logger() *slog.Logger {
	if k.Logger != nil {
		return k.Logger
	}
	return slog.Default()
}

func (k *MoamalatKeeper) alerter() moamalatAlerter {
	return moamalatAlerter{store: k.Store, ntfy: k.Alerts, logger: k.logger()}
}

// Run pokes until ctx is cancelled.
func (k *MoamalatKeeper) Run(ctx context.Context) {
	if !k.Enabled() {
		k.logger().Info("moamalat keeper disabled (POINTY_RELAY_MOAMALAT_TOKEN_KEY not set)")
		return
	}
	interval := k.Interval
	if interval <= 0 {
		interval = defaultMoamalatInterval
	}
	k.logger().Info("moamalat keeper started", "interval", interval)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		// A full batch means more are due: go again at once.
		for k.RunOnce(ctx) >= moamalatClaimBatch && ctx.Err() == nil {
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// RunOnce claims the due pokes and makes them. Returns how many it claimed.
func (k *MoamalatKeeper) RunOnce(ctx context.Context) int {
	store := k.Store.(control.MoamalatStore)
	if k.switchedOff(ctx) {
		// The kill switch reaches the relay's copies too: stop poking and
		// delete them, so nothing keeps a token warm against the switch.
		if deleted, err := store.DeleteAllMoamalatLinks(ctx); err != nil {
			k.logger().Error("moamalat kill switch: copies not deleted", "error", err)
		} else if deleted > 0 {
			k.logger().Warn("moamalat kill switch: deleted every token copy", "count", deleted)
		}
		return 0
	}
	claims, err := store.ClaimMoamalatPokes(ctx, moamalatClaimBatch, moamalatClaimLease)
	if err != nil {
		if !errors.Is(err, context.Canceled) {
			k.logger().Error("moamalat claim failed", "error", err)
		}
		return 0
	}
	inFlight := k.Concurrency
	if inFlight <= 0 {
		inFlight = defaultMoamalatInFlight
	}
	slots := make(chan struct{}, inFlight)
	var wg sync.WaitGroup
	for _, claim := range claims {
		wg.Add(1)
		slots <- struct{}{}
		go func(claim control.MoamalatClaim) {
			defer wg.Done()
			defer func() { <-slots }()
			k.poke(ctx, store, claim)
		}(claim)
	}
	wg.Wait()
	return len(claims)
}

// switchedOff reads the fleet switch before every claim. An unreadable switch
// table pauses the keeper (claims nothing) but deletes nothing.
func (k *MoamalatKeeper) switchedOff(ctx context.Context) bool {
	switches, ok := k.Store.(control.IntegrationSwitchStore)
	if !ok {
		return false
	}
	list, err := switches.ListIntegrationSwitches(ctx)
	if err != nil {
		return false
	}
	for _, sw := range list {
		if sw.Provider == control.MoamalatIntegrationKey && sw.Disabled {
			return true
		}
	}
	return false
}

func (k *MoamalatKeeper) jitter() float64 {
	if k.Jitter != nil {
		return k.Jitter()
	}
	return rand.Float64()*2 - 1
}

func (k *MoamalatKeeper) poke(ctx context.Context, store control.MoamalatStore, claim control.MoamalatClaim) {
	link := claim.Link
	token, err := k.Sealer.Open(link.InstallationID, link.MID, link.SealedToken)
	if err != nil {
		// Sealed under another key: useless here. Drop it — the shop's
		// backend sees the copy gone on its next tick and hands it over again.
		k.logger().Error("moamalat token unreadable; copy dropped", "installation_id", link.InstallationID, "error", err)
		if _, err := store.DeleteMoamalatLink(ctx, link.InstallationID); err != nil {
			k.logger().Error("moamalat unreadable copy not dropped", "installation_id", link.InstallationID, "error", err)
		}
		return
	}
	result := k.Client.Poke(ctx, token)
	switch result.Outcome {
	case moamalat.Alive:
		if _, _, err := store.RecordMoamalatPoke(ctx, control.MoamalatPoke{
			InstallationID: link.InstallationID,
			TokenID:        link.TokenID,
			Outcome:        "alive",
			NextIn:         moamalat.NextAfterSuccess(k.jitter()),
		}); err != nil {
			k.logger().Error("moamalat poke not recorded", "installation_id", link.InstallationID, "error", err)
			return
		}
		k.alerter().recovered(ctx, link)
	case moamalat.Dead:
		dead, applied, err := store.MarkMoamalatDead(ctx, link.InstallationID, link.TokenID, "relay")
		if err != nil {
			k.logger().Error("moamalat death not recorded", "installation_id", link.InstallationID, "error", err)
			return
		}
		if applied {
			k.logger().Warn("moamalat token died; the shop must re-link", "installation_id", link.InstallationID, "token_id", link.TokenID)
			k.alerter().reauth(ctx, link.InstallationID, dead)
		}
	default:
		next := moamalat.NextAfterFailure(claim.Age, link.Failures+1, result.RetryAfter)
		if _, _, err := store.RecordMoamalatPoke(ctx, control.MoamalatPoke{
			InstallationID: link.InstallationID,
			TokenID:        link.TokenID,
			Outcome:        "transient",
			NextIn:         next,
			Error:          result.Detail,
		}); err != nil {
			k.logger().Error("moamalat failure not recorded", "installation_id", link.InstallationID, "error", err)
			return
		}
		k.logger().Warn("moamalat poke failed", "installation_id", link.InstallationID, "detail", result.Detail, "age", claim.Age.Round(time.Second), "next_in", next)
		if moamalat.AtRisk(claim.Age) {
			k.alerter().atRisk(ctx, link, claim.Age, result.Detail)
		}
	}
}

// --- alerts -----------------------------------------------------------------

// moamalatAlerter raises the keepalive's alerts on the company's channel, once
// per condition across every instance (the store's alert marks).
type moamalatAlerter struct {
	store  control.InstallationStore
	ntfy   *alerts.Ntfy
	logger *slog.Logger
}

func (a moamalatAlerter) shopName(ctx context.Context, installationID string) string {
	if installation, err := a.store.GetInstallation(ctx, installationID); err == nil && installation.ShopName != "" {
		return installation.ShopName
	}
	return installationID
}

func (a moamalatAlerter) claim(ctx context.Context, key string, cooldown time.Duration) bool {
	if a.ntfy == nil {
		return false
	}
	marks, ok := a.store.(control.AlertStore)
	if !ok {
		return false
	}
	won, err := marks.ClaimAlert(ctx, key, cooldown)
	if err != nil {
		a.logger.Warn("alert mark unclaimable; alert not sent", "key", key, "error", err)
		return false
	}
	return won
}

func (a moamalatAlerter) release(ctx context.Context, key string) bool {
	marks, ok := a.store.(control.AlertStore)
	if !ok {
		return false
	}
	released, err := marks.ReleaseAlert(ctx, key)
	if err != nil {
		a.logger.Warn("alert mark not released", "key", key, "error", err)
		return false
	}
	return released
}

func (a moamalatAlerter) atRisk(ctx context.Context, link control.MoamalatLink, age time.Duration, detail string) {
	key := moamalatAlertPrefixRisk + link.InstallationID + ":" + link.TokenID
	if !a.claim(ctx, key, moamalatAtRiskCooldown) {
		return
	}
	a.ntfy.Send(alerts.Message{
		Title:    "Moamalat token at risk: " + a.shopName(ctx, link.InstallationID),
		Body:     "The relay has not kept this shop's card-verification token warm for " + age.Round(time.Minute).String() + " (" + detail + "). It dies after ~15 minutes without an accepted call; the shop's own server may still be keeping it alive.",
		Priority: alerts.PriorityHigh,
		Tags:     []string{"warning"},
		Click:    "/moamalat",
	})
}

func (a moamalatAlerter) recovered(ctx context.Context, link control.MoamalatLink) {
	if !a.release(ctx, moamalatAlertPrefixRisk+link.InstallationID+":"+link.TokenID) || a.ntfy == nil {
		return
	}
	a.ntfy.Send(alerts.Message{
		Title:    "Moamalat token warm again: " + a.shopName(ctx, link.InstallationID),
		Body:     "The relay's keepalive is getting through again.",
		Priority: alerts.PriorityDefault,
		Tags:     []string{"white_check_mark"},
		Click:    "/moamalat",
	})
}

func (a moamalatAlerter) reauth(ctx context.Context, installationID string, link control.MoamalatLink) {
	a.release(ctx, moamalatAlertPrefixRisk+installationID+":"+link.TokenID)
	if !a.claim(ctx, moamalatAlertPrefixDeath+installationID+":"+link.TokenID, moamalatReauthCooldown) {
		return
	}
	a.ntfy.Send(alerts.Message{
		Title:    "Moamalat needs re-linking: " + a.shopName(ctx, installationID),
		Body:     "This shop's card-verification token died (seen by the " + link.DeathSource + "). Card sales go on as pending verification until the shop's supervisor re-links with an OTP in Shop settings.",
		Priority: alerts.PriorityHigh,
		Tags:     []string{"credit_card"},
		Click:    "/moamalat",
	})
}

// releaseAll forgets every mark of a shop's token: it was replaced or removed.
func (a moamalatAlerter) releaseAll(ctx context.Context, installationID string) {
	marks, ok := a.store.(control.AlertStore)
	if !ok {
		return
	}
	for _, prefix := range []string{moamalatAlertPrefixRisk, moamalatAlertPrefixDeath} {
		list, err := marks.ListAlertMarks(ctx, prefix+installationID+":")
		if err != nil {
			continue
		}
		for _, mark := range list {
			a.release(ctx, mark.Key)
		}
	}
}

func (s HTTPServer) moamalatAlerter() moamalatAlerter {
	return moamalatAlerter{store: s.Store, ntfy: s.Alerts, logger: s.logger()}
}

func (s HTTPServer) alertMoamalatReauth(installationID string, link control.MoamalatLink) {
	s.moamalatAlerter().reauth(context.Background(), installationID, link)
}

func (s HTTPServer) releaseMoamalatAlerts(installationID string) {
	s.moamalatAlerter().releaseAll(context.Background(), installationID)
}
