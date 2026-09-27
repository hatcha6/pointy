package ratelimit

import (
	"testing"
	"time"
)

func TestParsePolicy(t *testing.T) {
	cases := map[string]Policy{
		"60/minute":  {Limit: 60, Window: time.Minute},
		" 5/Second ": {Limit: 5, Window: time.Second},
		"1000/hour":  {Limit: 1000, Window: time.Hour},
		"20000/day":  {Limit: 20000, Window: 24 * time.Hour},
		"30/90s":     {Limit: 30, Window: 90 * time.Second},
		"10/m":       {Limit: 10, Window: time.Minute},
		"":           {},
		"0":          {},
		"off":        {},
		"0/minute":   {},
	}
	for spec, want := range cases {
		got, err := ParsePolicy(spec)
		if err != nil {
			t.Fatalf("ParsePolicy(%q): %v", spec, err)
		}
		if got != want {
			t.Fatalf("ParsePolicy(%q) = %+v, want %+v", spec, got, want)
		}
	}
	for _, bad := range []string{"60", "sixty/minute", "-1/minute", "60/fortnight", "60/-5s", "60/"} {
		if _, err := ParsePolicy(bad); err == nil {
			t.Fatalf("ParsePolicy(%q) should fail", bad)
		}
	}
}

func TestPolicyStringRoundTrips(t *testing.T) {
	for _, spec := range []string{"60/minute", "5/second", "1000/hour", "20000/day", "30/1m30s", "off"} {
		policy, err := ParsePolicy(spec)
		if err != nil {
			t.Fatal(err)
		}
		if got := policy.String(); got != spec {
			t.Fatalf("Policy(%q).String() = %q", spec, got)
		}
	}
}
