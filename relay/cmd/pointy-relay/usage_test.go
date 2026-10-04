package main

import (
	"strings"
	"testing"
)

func TestCommandUsageShowsOnlyThatCommand(t *testing.T) {
	wallet := renderUsage([]usageSection{*findUsageSection("wallet")})
	if !strings.Contains(wallet, "pointy-relay wallet <list|") || !strings.Contains(wallet, "POINTY_RELAY_ADMIN_TOKEN") {
		t.Fatalf("wallet usage is missing its synopsis or admin note:\n%s", wallet)
	}
	for _, other := range []string{"pointy-relay fleet", "installations", "Deployment profiles", "version"} {
		if strings.Contains(wallet, other) {
			t.Fatalf("wallet usage leaks %q:\n%s", other, wallet)
		}
	}

	server := renderUsage([]usageSection{*findUsageSection("server")})
	if !strings.Contains(server, "Deployment profiles") || strings.Contains(server, "Admin API commands") {
		t.Fatalf("server usage has the wrong footers:\n%s", server)
	}

	full := renderUsage(usageSections)
	for _, section := range usageSections {
		if !strings.Contains(full, section.detail) {
			t.Fatalf("full usage is missing %s", section.name)
		}
	}
}

func TestWantsCommandHelp(t *testing.T) {
	cases := []struct {
		command, arg string
		want         bool
	}{
		{"wallet", "help", true},
		{"wallet", "--help", true},
		{"wallet", "-h", true},
		{"wallet", "list", false},
		{"server", "help", true},
		{"server", "-h", false}, // the flag package lists server's flags
		{"nope", "help", false},
	}
	for _, c := range cases {
		if got := wantsCommandHelp(c.command, c.arg); got != c.want {
			t.Errorf("wantsCommandHelp(%q, %q) = %v, want %v", c.command, c.arg, got, c.want)
		}
	}
}
