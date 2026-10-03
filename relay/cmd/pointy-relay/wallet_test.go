package main

import (
	"strings"
	"testing"
	"time"
)

func validWalletSettings() walletSettings {
	return walletSettings{
		DafaBaseURL:    "https://dev.dafa.ly/api/v1/",
		DafaAPIKey:     " dafa_live_key ",
		PublicURL:      "https://relay.example.com/",
		MinTopUp:       "10",
		MaxTopUp:       "5000",
		QuickAmounts:   "50, 100,200",
		TopUpTTL:       30 * time.Minute,
		TopUpRateLimit: "10/minute",
	}
}

func TestBuildWalletConfigAcceptsALiveKey(t *testing.T) {
	config, warnings, err := buildWalletConfig(validWalletSettings())
	if err != nil {
		t.Fatal(err)
	}
	if !config.TopUpsConfigured() || config.TestMode || config.DafaAPIKey != "dafa_live_key" ||
		config.DafaBaseURL != "https://dev.dafa.ly/api/v1" || config.PublicURL != "https://relay.example.com" ||
		config.MinTopUp != "10.00" || config.MaxTopUp != "5000.00" || len(config.QuickAmounts) != 3 || len(config.Methods) != 0 {
		t.Fatalf("unexpected config %+v", config)
	}
	if len(warnings) != 0 {
		t.Fatalf("a complete live setup needs no warning: %v", warnings)
	}
}

func TestBuildWalletConfigReadsTheEnvironmentFromTheKey(t *testing.T) {
	settings := validWalletSettings()
	settings.DafaAPIKey = "dafa_test_key"
	config, warnings, err := buildWalletConfig(settings)
	if err != nil || !config.TopUpsConfigured() || !config.TestMode {
		t.Fatalf("a test key is test money: %+v %v", config, err)
	}
	if !strings.Contains(strings.Join(warnings, "|"), "TEST key") {
		t.Fatalf("test mode must be announced: %v", warnings)
	}
}

func TestBuildWalletConfigWithoutAKeyLeavesTopUpsOff(t *testing.T) {
	config, warnings, err := buildWalletConfig(walletSettings{MinTopUp: "10", MaxTopUp: "5000"})
	if err != nil || config.TopUpsConfigured() || config.TestMode || len(warnings) != 0 {
		t.Fatalf("no key, no top-ups, no error, no noise: %+v %v %v", config, warnings, err)
	}
}

func TestBuildWalletConfigAKeyOfNoKnownEnvironmentTurnsTopUpsOffWithoutStoppingTheRelay(t *testing.T) {
	settings := validWalletSettings()
	settings.DafaAPIKey = "sk_live_somethingelse"
	config, warnings, err := buildWalletConfig(settings)
	if err != nil {
		t.Fatalf("a wrong key must not take the relay down: %v", err)
	}
	if config.TopUpsConfigured() || config.DafaAPIKey != "" || config.TestMode {
		t.Fatalf("top-ups must be off, holding no key: %+v", config)
	}
	joined := strings.Join(warnings, "|")
	if !strings.Contains(joined, "OFF") || !strings.Contains(joined, "dafa_test_") {
		t.Fatalf("the warning must say what a key looks like: %v", warnings)
	}
}

func TestBuildWalletConfigNarrowsAndOrdersTheMethods(t *testing.T) {
	settings := validWalletSettings()
	settings.Methods = "sadad, dafa_moamalat ,edfali,sadad"
	config, _, err := buildWalletConfig(settings)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"dafa_sadad", "dafa_moamalat", "dafa_edfali"}
	if strings.Join(config.Methods, ",") != strings.Join(want, ",") {
		t.Fatalf("methods: %v", config.Methods)
	}
}

func TestBuildWalletConfigRefusesWhatWouldGoWrongLater(t *testing.T) {
	for name, mutate := range map[string]func(*walletSettings){
		"unknown method":      func(s *walletSettings) { s.Methods = "sadad,tlync" },
		"plain http base":     func(s *walletSettings) { s.DafaBaseURL = "http://dev.dafa.ly/api/v1" },
		"base with a query":   func(s *walletSettings) { s.DafaBaseURL = "https://dev.dafa.ly/api/v1?x=1" },
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
	settings := validWalletSettings()
	settings.DafaBaseURL = "http://127.0.0.1:9099/api/v1"
	if _, _, err := buildWalletConfig(settings); err != nil {
		t.Fatalf("a loopback fake Dafa is allowed plain http: %v", err)
	}
}

func TestBuildWalletConfigWarnsAboutPlainHTTPAndLeftoverPlutu(t *testing.T) {
	settings := validWalletSettings()
	settings.PublicURL = "http://relay.example.com"
	settings.LegacyPlutu = true
	_, warnings, err := buildWalletConfig(settings)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(warnings, "|")
	if !strings.Contains(joined, "plain http") || !strings.Contains(joined, "POINTY_RELAY_PLUTU_") {
		t.Fatalf("warnings: %v", warnings)
	}
	settings = validWalletSettings()
	settings.PublicURL = ""
	_, warnings, _ = buildWalletConfig(settings)
	if !strings.Contains(strings.Join(warnings, "|"), "PUBLIC_URL is empty") {
		t.Fatalf("an empty public URL is worth a word: %v", warnings)
	}
}

func TestBuildWalletConfigSellsThePricedPlans(t *testing.T) {
	settings := validWalletSettings()
	settings.RemoteAccessPrice = " 50 "
	settings.PlanDays = 30
	config, _, err := buildWalletConfig(settings)
	if err != nil {
		t.Fatal(err)
	}
	remote, sold := config.Plans["remote_access"]
	if !sold || remote.Price != "50.000" || remote.Days != 30 {
		t.Fatalf("remote access is sold at 50 for 30 days: %+v", config.Plans)
	}
	if _, sold := config.Plans["ai"]; sold {
		t.Fatalf("a plan without a price is not sold: %+v", config.Plans)
	}
	// No days set means a month.
	settings.PlanDays = 0
	settings.AIPrice = "30.5"
	config, _, err = buildWalletConfig(settings)
	if err != nil || config.Plans["ai"].Days != 30 || config.Plans["ai"].Price != "30.500" {
		t.Fatalf("defaults: %+v %v", config.Plans, err)
	}
	for _, bad := range []walletSettings{
		func() walletSettings { s := validWalletSettings(); s.AIPrice = "free"; return s }(),
		func() walletSettings { s := validWalletSettings(); s.RemoteAccessPrice = "-5"; return s }(),
		func() walletSettings { s := validWalletSettings(); s.RemoteAccessPrice = "1.2345"; return s }(),
		func() walletSettings { s := validWalletSettings(); s.PlanDays = -1; return s }(),
	} {
		if _, _, err := buildWalletConfig(bad); err == nil {
			t.Fatalf("a wrong plan setting must stop the relay: %+v", bad)
		}
	}
}

func TestBuildSMSConfigReadsThePrice(t *testing.T) {
	config, _, err := buildSMSConfig(smsSettings{RateLimit: "60/minute", Price: "0.15"})
	if err != nil || config.Price != "0.150" {
		t.Fatalf("the price is kept to the dirham: %+v %v", config, err)
	}
	if config, _, err := buildSMSConfig(smsSettings{RateLimit: "60/minute"}); err != nil || config.Price != "" {
		t.Fatalf("no price leaves the relay default: %+v %v", config, err)
	}
	for _, bad := range []string{"0", "-0.15", "0.1234", "cheap"} {
		if _, _, err := buildSMSConfig(smsSettings{RateLimit: "60/minute", Price: bad}); err == nil {
			t.Fatalf("price %q must stop the relay", bad)
		}
	}
}
