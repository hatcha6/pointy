package main

import (
	"fmt"
	"os"
	"strings"
)

// usageSection is one top-level command's slice of the help text: the synopsis
// lines shown under "Usage:" and the block shown under "Commands:". Keeping them
// together lets `pointy-relay wallet` print only the wallet help.
type usageSection struct {
	name     string
	synopsis []string
	detail   string
	// adminAPI commands take POINTY_RELAY_CONTROL_URL / POINTY_RELAY_ADMIN_TOKEN.
	adminAPI bool
	// flagsOnly commands parse flags directly, so their -h/--help is left to the
	// flag package, which lists every flag.
	flagsOnly bool
}

var usageSections = []usageSection{
	{
		name:      "server",
		synopsis:  []string{"pointy-relay server [flags]"},
		detail:    `  server         Run relay control, remote HTTP, and connector listeners.`,
		flagsOnly: true,
	},
	{
		name:      "connector",
		synopsis:  []string{"pointy-relay connector [flags]"},
		detail:    `  connector      Run the on-prem connector beside a Pointy backend.`,
		flagsOnly: true,
	},
	{
		name:     "installations",
		synopsis: []string{"pointy-relay installations <list|show|status|diagnostics|audit|provision> [args]"},
		detail: `  installations  Fleet management over the admin API:
                   list [--query q] [--active|--inactive] [--limit n] [--json]
                   show <id> [--json]        full subscription + connector state
                   status <id> [--json]      live connector / certificate health
                   diagnostics <id> [--out f]    pull tracking/usage/error export
                   diagnostics --all [--out-dir d]   pull from every reachable shop
                   audit <id> [--json]       recent subscription change history
                   provision [--shop-name .. --relay-enabled ..]   create remotely`,
		adminAPI: true,
	},
	{
		name:     "subscription",
		synopsis: []string{"pointy-relay subscription <set|update|enable|disable|extend|audit> <id> [flags]"},
		detail: `  subscription   Fast subscription changes over the admin API (audited):
                   set <id> --months N [--ai|--no-ai] [--remote|--no-remote]
                                             give an N-month subscription + add-ons
                   enable <id>               turn relay + subscription on
                   disable <id>              turn relay + subscription off
                   extend <id> --days N      set the end date N days out, active
                   update <id> [flags]       explicit field-by-field control
                                             (--ai-enabled, --relay-enabled, ...)
                   audit <id>                change history (alias)`,
		adminAPI: true,
	},
	{
		name:     "enrollment",
		synopsis: []string{"pointy-relay enrollment mint [--count N] [--relay] [--ai] [--subscription DUR]"},
		detail: `  enrollment     Mint single-use license keys (redeemed at /v1/enroll):
                   mint [--count N] [--expires-in 720h]
                                             plain keys (operator activates later)
                   mint [--relay] [--ai] [--subscription 1y|6mo|30d|perpetual]
                                             bake a subscription in — the shop is
                                             activated the moment it redeems`,
		adminAPI: true,
	},
	{
		name:     "fleet",
		synopsis: []string{"pointy-relay fleet <status|set-version|rollout|pause|pin|unpin|channel> [args]"},
		detail: `  fleet          Remote on-prem update control plane (admin API):
                   status [--query q] [--json]   versions across the fleet
                   set-version <v> [--channel stable] [--rollout canary|all|N%]
                   rollout <canary|all|N%> [--channel]   advance the rollout
                   pause [--channel]         kill switch: stop the rollout
                   pin <id> <v> / unpin <id> / channel <id> <channel>`,
		adminAPI: true,
	},
	{
		name:     "sms",
		synopsis: []string{"pointy-relay sms <usage|log|config> [flags]"},
		detail: `  sms            Relay-hosted SMS (Resala) over the admin API:
                   usage [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--json]
                                             messages + cost per shop, busiest first
                   log [--installation ID] [--status S] [--limit N] [--json]
                                             recent sends, newest first
                   config [--json]           templates, test mode, limits (no token)`,
		adminAPI: true,
	},
	{
		name:     "wallet",
		synopsis: []string{"pointy-relay wallet <list|show|topups|check|credit|debit|refund|confirm|config> [args]"},
		detail: `  wallet         Shop wallets (prepaid balance, Dafa top-ups) over the admin API:
                   list [--limit N] [--json] balances, largest first, with the total
                   show <id> [--limit N]     one shop's statement, newest first
                   topups [--installation ID] [--status S] [--limit N] [--json]
                                             top-ups; expired = nobody finished paying
                   check <top-up id | DFW-reference>
                                             ask Dafa now; credits it if it is paid
                   credit <id> --amount N --reason "..."        hand-made credit
                   debit <id> --amount N --reason "..." [--service S]
                                             a charge (with --service) or adjustment
                   refund <id> --amount N --service S --reason "..." [--reference E]
                   confirm <top-up id> --transaction-id T --reason "..."
                                             credit by hand what Dafa will not show paid
                   config                    gateway, mode, methods, limits (no key)`,
		adminAPI: true,
	},
	{
		name:     "vouchers",
		synopsis: []string{"pointy-relay vouchers <catalog|settings|offers|compare|purchases|check|resolve|bnplus|reloadly|config> [args]"},
		detail: `  vouchers       The company's card shop (BN Plus and Reloadly) over the admin API:
                   catalog example           a starter catalog.json
                   catalog check <file>      validate a catalog and its images locally
                   catalog push <file> [--note "..."]
                                             upload its images, then publish it
                   catalog show [--json]     what shops see: order, prices, promos, supply
                   catalog history           published versions, newest first
                   settings show [--json]    pricing of direct top-up and bills: the dollar
                                             rate, markups, retail step; marks the knobs
                                             still at a demo default nobody decided
                   settings set [--file F] [--usd-rate N] [--funding-percent N]
                                [--airtime-shop-markup N] [--airtime-retail-markup N]
                                [--airtime-order-mode usd|local] [--airtime-usd-buffer N] [--airtime-service-fee N]
                                [--bills-shop-markup N] [--bills-retail-markup N]
                                [--bills-order-mode auto|local] [--bills-usd-buffer N]
                                [--retail-step N] [--min-shop-margin N] [--popular NE,ML,..]
                                [--note "..."] [--dry-run]
                                             publish new settings; flags override the
                                             published ones (or --file); a blank value is
                                             the default (--usd-rate "" unsets the rate)
                   settings history          published versions, newest first
                   offers [--supplier S] [--sync]   what suppliers sell the company, in their
                                             own currency and in dinars (bnplus, reloadly)
                   compare [--brand KEY]     every item with two or more suppliers: each one's
                                             cost in dinars, who wins, the saving, the margin
                   purchases [--installation ID] [--status S] [--kind K] [--held] [--limit N]
                   check <purchase id>       ask the supplier about an open purchase now
                   resolve <purchase id> (--refund | --found ORDER) --reason "..."
                                             settle a purchase the reconciler could not
                   bnplus wallets|groups [--type T]|companies [--group N]|cards --branch N|orders|order <id>
                                             read BN Plus with the company's credentials
                   reloadly balance          the company's gift card balance at Reloadly
                   config                    suppliers, test mode, limits (no secrets)`,
		adminAPI: true,
	},
	{
		name:     "services",
		synopsis: []string{"pointy-relay services <directory|quote|names|balance|status> [flags]"},
		detail: `  services       Direct top-up and bill payments (Reloadly) over the admin API:
                   directory [--country ML,NE] [--refresh [--accept]] [--json]
                                             countries, operators, billers and what each
                                             amount costs the shop and the customer;
                                             --accept believes a far smaller directory
                                             after a reading was REJECTED (see status)
                   quote --kind airtime --operator ID --amount N [--currency C]
                   quote --kind bill --biller ID --amount N [--amount-id PLAN]
                                             one price, and how it is ordered from Reloadly
                   names --missing           operators, billers and plans with no Arabic
                                             spelling yet (shown in Latin until added)
                   balance                   the company's balance at Reloadly, per product
                   status                    configured? test mode or sandbox? when the directory was
                                             read, stale? a reading rejected?
                 Orders are listed with: vouchers purchases --kind airtime|bill`,
		adminAPI: true,
	},
	{
		name:     "integrations",
		synopsis: []string{"pointy-relay integrations <status|disable|enable> [provider] [flags]"},
		detail: `  integrations   Fleet-wide switch per provider integration (hdbox, lnet, qareeb):
                   status [--json]           which are off, since when, by whom, why
                   disable <provider> --reason "..."
                                             off in every shop (a cease-and-desist)
                   enable <provider> [--reason "..."]   back on in every shop`,
		adminAPI: true,
	},
	{
		name:     "alerts",
		synopsis: []string{"pointy-relay alerts <setup|rotate|status|test> [flags]"},
		detail: `  alerts         The company's ntfy alert channel (low balances, supplier refusals, wallet payments):
                   setup                     generate the topic once; prints where to subscribe
                   rotate                    replace the topic (cuts off every subscribed phone)
                   status [--json]           the topic and its subscribe link
                   test                      send a test notification`,
		adminAPI: true,
	},
	{
		name:     "console",
		synopsis: []string{"pointy-relay console <invite|operators|disable|enable> [args]"},
		detail: `  console        The operator web console (/console/, passkeys only):
                   invite --name "..." [--ttl-hours 24]
                                             one-time link that registers a passkey;
                                             an existing name adds another device
                   operators [--json]        who can sign in, devices, open sessions
                   disable <id> / enable <id>    lock an operator out (signs them out)`,
		adminAPI: true,
	},
	{
		name: "artifacts",
		synopsis: []string{
			"pointy-relay artifacts upload --version X --bundle pointy-update-X.zip",
			"pointy-relay artifacts upload --version X --url https://host/pointy-update-X.zip [--sha256 H]",
			"pointy-relay artifacts status --version X [--wait]",
		},
		detail: `  artifacts      upload --version X --bundle pointy-update-X.zip   serve a bundle
                   upload --version X --url URL   the relay downloads it itself (slow line)
                   status --version X [--wait]    progress of a --url download`,
		adminAPI: true,
	},
	{
		name:      "provision",
		synopsis:  []string{"pointy-relay provision [flags]"},
		detail:    `  provision      Create an installation directly against the database (host-side).`,
		flagsOnly: true,
	},
	{
		name:      "migrate",
		synopsis:  []string{"pointy-relay migrate [flags]"},
		detail:    `  migrate        Apply relay PostgreSQL migrations.`,
		flagsOnly: true,
	},
	{
		name:      "gen-token",
		synopsis:  []string{"pointy-relay gen-token [flags]"},
		detail:    `  gen-token      Print a strong random admin token for POINTY_RELAY_ADMIN_TOKEN.`,
		flagsOnly: true,
	},
}

const adminAPIUsageNote = `Admin API commands read POINTY_RELAY_CONTROL_URL and POINTY_RELAY_ADMIN_TOKEN
from the environment; export them once for terse, repeatable management.`

const deploymentProfilesUsage = `Deployment profiles (server --platform / POINTY_RELAY_PLATFORM):
  paas          Single public endpoint behind a TLS-terminating load balancer,
                bearer-token admin, auto-bind 0.0.0.0, edge TLS, auto-migrate.
                Requires a strong POINTY_RELAY_ADMIN_TOKEN.
  (empty)       Self-hosted private-network deployment (set --production to
                enforce split admin listener + mTLS).`

// usageTopic is the top-level command being run, so a usage error prints that
// command's help instead of the whole tool's. Empty means the full help.
var usageTopic string

func findUsageSection(name string) *usageSection {
	for i := range usageSections {
		if usageSections[i].name == name {
			return &usageSections[i]
		}
	}
	return nil
}

// wantsCommandHelp reports whether `pointy-relay <command> <arg>` asks for that
// command's help. Flag-only commands keep -h/--help for the flag listing.
func wantsCommandHelp(command, arg string) bool {
	section := findUsageSection(command)
	if section == nil {
		return false
	}
	switch arg {
	case "help":
		return true
	case "-h", "-help", "--help":
		return !section.flagsOnly
	}
	return false
}

func usageError(format string, args ...any) error {
	printCommandUsage(usageTopic)
	return fmt.Errorf(format, args...)
}

// printCommandUsage prints one command's help, or the full help when the name
// is not a known command.
func printCommandUsage(name string) {
	section := findUsageSection(name)
	if section == nil {
		printUsage()
		return
	}
	fmt.Fprintln(os.Stderr, renderUsage([]usageSection{*section}))
}

func printUsage() {
	fmt.Fprintln(os.Stderr, renderUsage(usageSections))
}

func renderUsage(sections []usageSection) string {
	var b strings.Builder
	b.WriteString("Usage:\n")
	adminAPI, server := false, false
	for _, section := range sections {
		for _, line := range section.synopsis {
			b.WriteString("  " + line + "\n")
		}
		adminAPI = adminAPI || section.adminAPI
		server = server || section.name == "server"
	}
	b.WriteString("\nCommands:\n")
	for _, section := range sections {
		b.WriteString(section.detail + "\n")
	}
	if len(sections) > 1 {
		b.WriteString("  version        Print the build version.\n")
	}
	if adminAPI {
		b.WriteString("\n" + adminAPIUsageNote + "\n")
	}
	if server {
		b.WriteString("\n" + deploymentProfilesUsage + "\n")
	}
	return strings.TrimRight(b.String(), "\n")
}
