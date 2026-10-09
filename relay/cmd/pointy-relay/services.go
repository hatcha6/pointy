package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"log/slog"
	"strings"
	"time"

	relayserver "pointy/relay/internal/relay"
	"pointy/relay/internal/services"
)

// The services of the company's shelf besides cards: direct top-up (credit sent
// to a phone number abroad) and bill payments, bought from Reloadly with the
// same account and the same client as the gift cards, and paid from the shop's
// voucher balance like a card. They are on when Reloadly is configured or the
// vouchers are in test mode:
//
//	POINTY_RELAY_RELOADLY_CLIENT_ID / _CLIENT_SECRET / _SANDBOX / _REQUEST_TIMEOUT   (see vouchers.go)
//	POINTY_RELAY_RELOADLY_DIRECTORY_INTERVAL   how often countries, operators and billers are re-read (15m; 0 = once)
//	POINTY_RELAY_SERVICES_SETTLE_WAIT          how long a bill Reloadly accepted is waited for (20s)
//	POINTY_RELAY_VOUCHERS_TEST_MODE            fake orders; the directory comes from Reloadly when configured, else
//	                                           from the embedded fixture

const (
	defaultServicesDirectoryInterval = 15 * time.Minute
	defaultServicesSettleWait        = 20 * time.Second
)

// servicesSettings are the knobs of the services besides Reloadly's credentials.
type servicesSettings struct {
	// DirectoryInterval is how often the directory is read again; 0 reads it once.
	DirectoryInterval time.Duration
	// RequestTimeout bounds one order's call to Reloadly (the same setting as the
	// gift cards': POINTY_RELAY_RELOADLY_REQUEST_TIMEOUT).
	RequestTimeout time.Duration
	// SettleWait is how long an accepted order is waited for.
	SettleWait time.Duration
	// TargetKey keys the digest of an order's target (deriveServicesTargetKey).
	TargetKey []byte
}

// servicesTargetKeyLabel namespaces the HMAC so the key of the order-target
// digests is a value of its own, not the admin token itself. Bumping the suffix
// retires every digest made with the old key (a replay of such an order is then
// judged by its masked target, as before digests existed).
const servicesTargetKeyLabel = "pointy-relay-service-target/v1"

// deriveServicesTargetKey makes the secret that keys the digest of who a service
// order is for (a phone number or an account: too few digits to hash without a
// key). It comes from the admin token, the way the node-proxy token does: every
// instance of a deployment holds the same admin token, so they all derive the
// same key without it being stored or distributed, it is stable across restarts,
// and it is a secret the database does not hold. Rotating the admin token
// changes the key; an order placed before is then judged by its masked target
// (see services.SameTarget), never refused as a different order. With no admin
// token (open admin, development only) the key is a constant: the digest keeps
// its shape and loses its secrecy.
func deriveServicesTargetKey(adminToken string) []byte {
	mac := hmac.New(sha256.New, []byte(strings.TrimSpace(adminToken)))
	mac.Write([]byte(servicesTargetKeyLabel))
	return mac.Sum(nil)
}

// buildServices makes the services of this relay out of its voucher
// configuration: Reloadly's client when it is configured, the test supplier in
// test mode, nothing otherwise (an unconfigured service sells nothing and says so).
func buildServices(voucherConfig relayserver.VoucherConfig, settings servicesSettings, logger *slog.Logger) *services.Service {
	config := services.Config{
		TestMode:       voucherConfig.TestMode,
		Interval:       settings.DirectoryInterval,
		RequestTimeout: settings.RequestTimeout,
		SettleWait:     settings.SettleWait,
		TargetKey:      settings.TargetKey,
		Logger:         logger,
	}
	switch client := voucherConfig.Reloadly; {
	case client != nil:
		// Reloadly's sandbox is really called, with fake money: it is not test
		// mode, and everything a shop sees is marked as a test all the same. One
		// definition for cards and services: the voucher configuration's.
		config.Sandbox = voucherConfig.SandboxMode()
		config.Source = services.ReloadlySource{Client: client}
		config.Detector = services.ReloadlyDetector{Client: client}
		config.Reloadly = &services.ReloadlyExecutor{Client: client, SettleWait: settings.SettleWait}
		config.Balances = services.ReloadlyBalances{Client: client}
	case voucherConfig.TestMode:
		// Development without a Reloadly account: the embedded fixture, run through
		// the very same normalization as the live data.
		config.Source = services.FixtureSource{}
	}
	return services.New(config)
}

// servicesStartupMode is how the startup log says where the services get their
// directory and who fills their orders.
func servicesStartupMode(voucherConfig relayserver.VoucherConfig) string {
	switch {
	case voucherConfig.Reloadly != nil && voucherConfig.TestMode:
		return "reloadly directory, TEST orders (nothing is bought)"
	case voucherConfig.Reloadly != nil:
		return "reloadly " + reloadlyStartupMode(voucherConfig.Reloadly)
	case voucherConfig.TestMode:
		return "fixture directory, TEST orders (nothing is bought)"
	}
	return "off"
}
