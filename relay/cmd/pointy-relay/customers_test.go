package main

import (
	"strings"
	"testing"

	relayserver "pointy/relay/internal/relay"
)

func TestBuildCustomerConfig(t *testing.T) {
	base := customerSettings{OTPRateLimit: "10/hour", VerifyLimit: "30/10m"}

	config, warnings, err := buildCustomerConfig(base)
	if err != nil || config.Sender != nil || len(warnings) != 0 {
		t.Fatalf("no template: %+v %v %v", config, warnings, err)
	}

	withTemplate := base
	withTemplate.OTPTemplate = "tpl"
	config, warnings, err = buildCustomerConfig(withTemplate)
	if err != nil || config.Sender != nil || len(warnings) != 1 {
		t.Fatalf("template without a Resala token must warn and stay off: %+v %v %v", config, warnings, err)
	}

	withTemplate.SMS = relayserver.SMSConfig{Token: "resala"}
	withTemplate.AndroidAppHash = "FA+9qCX9VSu"
	config, _, err = buildCustomerConfig(withTemplate)
	if err != nil || config.Sender == nil || config.OTPRateLimit.Limit != 10 {
		t.Fatalf("configured: %+v %v", config, err)
	}

	testMode := base
	testMode.TestMode = true
	if _, warnings, _ := buildCustomerConfig(testMode); len(warnings) != 1 || !strings.Contains(warnings[0], "TEST MODE") {
		t.Fatalf("test mode warnings = %v", warnings)
	}

	for name, bad := range map[string]customerSettings{
		"rate":         {OTPRateLimit: "ten"},
		"app hash":     {AndroidAppHash: "short"},
		"review alone": {ReviewPhone: "0910000001"},
		"review phone": {ReviewPhone: "0212345678", ReviewCode: "123456"},
		"review code":  {ReviewPhone: "0910000001", ReviewCode: "12ab56"},
		"daily limit":  {DailyLimit: -1},
		"negative ttl": {CodeTTL: -1},
	} {
		if _, _, err := buildCustomerConfig(bad); err == nil {
			t.Errorf("%s: accepted %+v", name, bad)
		}
	}
}
