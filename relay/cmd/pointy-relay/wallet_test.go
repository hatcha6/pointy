package main

import (
	"strings"
	"testing"
	"time"
)

func validWalletSettings() walletSettings {
	return walletSettings{
		PlutuAPIKey:      "key",
		PlutuAccessToken: "token",
		PlutuSecretKey:   "sk_secret",
		PlutuMode:        "live",
		PublicURL:        "https://relay.example.com/",
		MinTopUp:         "10",
		MaxTopUp:         "5000",
		QuickAmounts:     "50, 100,200",
		TopUpTTL:         30 * time.Minute,
		TopUpRateLimit:   "10/minute",
	}
}

func TestBuildWalletConfigAcceptsACompleteAccount(t *testing.T) {
	config, warnings, err := buildWalletConfig(validWalletSettings())
	if err != nil {
		t.Fatal(err)
	}
	if !config.TopUpsConfigured() || config.TestMode || config.PublicURL != "https://relay.example.com" ||
		config.MinTopUp != "10.00" || config.MaxTopUp != "5000.00" || len(config.QuickAmounts) != 3 {
		t.Fatalf("unexpected config %+v", config)
	}
	if len(warnings) != 0 {
		t.Fatalf("a complete live setup needs no warning: %v", warnings)
	}
}

func TestBuildWalletConfigWithoutCredentialsLeavesTopUpsOff(t *testing.T) {
	config, _, err := buildWalletConfig(walletSettings{MinTopUp: "10", MaxTopUp: "5000"})
	if err != nil || config.TopUpsConfigured() {
		t.Fatalf("no credentials, no top-ups, no error: %+v %v", config, err)
	}
}

func TestBuildWalletConfigHalfAnAccountTurnsTopUpsOffWithoutStoppingTheRelay(t *testing.T) {
	settings := validWalletSettings()
	settings.PlutuAccessToken = ""
	config, warnings, err := buildWalletConfig(settings)
	if err != nil {
		t.Fatalf("a missing access token must not take the relay down: %v", err)
	}
	if config.TopUpsConfigured() || config.PlutuAPIKey != "" || config.PlutuSecretKey != "" {
		t.Fatalf("top-ups must be off, holding no half account: %+v", config)
	}
	joined := strings.Join(warnings, "|")
	if !strings.Contains(joined, "OFF") || !strings.Contains(joined, "POINTY_RELAY_PLUTU_ACCESS_TOKEN") {
		t.Fatalf("the warning must name what is missing: %v", warnings)
	}
}

func TestBuildWalletConfigRefusesWhatWouldGoWrongLater(t *testing.T) {
	for name, mutate := range map[string]func(*walletSettings){
		"mode unstated":       func(s *walletSettings) { s.PlutuMode = "" },
		"mode misspelt":       func(s *walletSettings) { s.PlutuMode = "production" },
		"min above max":       func(s *walletSettings) { s.MinTopUp = "6000" },
		"three decimals":      func(s *walletSettings) { s.MaxTopUp = "10.005" },
		"bad quick amount":    func(s *walletSettings) { s.QuickAmounts = "50,abc" },
		"public url path":     func(s *walletSettings) { s.PublicURL = "https://relay.example.com/api" },
		"public url scheme":   func(s *walletSettings) { s.PublicURL = "ftp://relay.example.com" },
		"ttl under a minute":  func(s *walletSettings) { s.TopUpTTL = 10 * time.Second },
		"malformed rate rule": func(s *walletSettings) { s.TopUpRateLimit = "lots" },
	} {
		settings := validWalletSettings()
		mutate(&settings)
		if _, _, err := buildWalletConfig(settings); err == nil {
			t.Errorf("%s: must stop the relay at startup", name)
		}
	}
}

func TestBuildWalletConfigWarnsAboutTestModeAndPlainHTTP(t *testing.T) {
	settings := validWalletSettings()
	settings.PlutuMode = "TEST"
	settings.PublicURL = "http://relay.example.com"
	config, warnings, err := buildWalletConfig(settings)
	if err != nil || !config.TestMode {
		t.Fatalf("test mode: %+v %v", config, err)
	}
	joined := strings.Join(warnings, "|")
	if !strings.Contains(joined, "TEST mode") || !strings.Contains(joined, "plain http") {
		t.Fatalf("warnings: %v", warnings)
	}
	settings.PublicURL = "http://127.0.0.1:8091"
	_, warnings, _ = buildWalletConfig(settings)
	if strings.Contains(strings.Join(warnings, "|"), "plain http") {
		t.Fatal("a loopback dev relay is allowed plain http without a warning")
	}
}
