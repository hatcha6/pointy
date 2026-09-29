package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"text/tabwriter"
)

// runIntegrations switches a provider integration off (or back on) for every
// shop at once: how a provider's request to stop — a cease-and-desist — is
// honoured in one command instead of one shop at a time. Each shop's backend
// picks the change up on its next switch check (every few minutes) and stops
// talking to that provider: no logins, no purchases, its cards off the till.
func runIntegrations(args []string) error {
	if len(args) == 0 {
		return usageError("missing integrations command (status, disable, enable)")
	}
	switch args[0] {
	case "status", "list":
		return runIntegrationsStatus(args[1:])
	case "disable":
		return runIntegrationsSet(args[1:], true)
	case "enable":
		return runIntegrationsSet(args[1:], false)
	default:
		return usageError("unknown integrations command %q", args[0])
	}
}

type integrationSwitchRow struct {
	Provider  string `json:"provider"`
	Disabled  bool   `json:"disabled"`
	Reason    string `json:"reason"`
	Actor     string `json:"actor"`
	UpdatedAt string `json:"updated_at"`
}

func runIntegrationsStatus(args []string) error {
	flags := flag.NewFlagSet("integrations status", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/fleet/integrations", nil, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Integrations []integrationSwitchRow `json:"integrations"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	if len(response.Integrations) == 0 {
		fmt.Println("Every integration is on: none has ever been switched off.")
		return nil
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(writer, "PROVIDER\tSTATE\tSINCE\tBY\tREASON")
	for _, row := range response.Integrations {
		state := "on"
		if row.Disabled {
			state = "OFF"
		}
		fmt.Fprintf(
			writer,
			"%s\t%s\t%s\t%s\t%s\n",
			row.Provider,
			state,
			dashIfEmpty(row.UpdatedAt),
			dashIfEmpty(row.Actor),
			dashIfEmpty(row.Reason),
		)
	}
	return writer.Flush()
}

func runIntegrationsSet(args []string, disable bool) error {
	name := "integrations enable"
	if disable {
		name = "integrations disable"
	}
	flags := flag.NewFlagSet(name, flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	reason := flags.String("reason", "", "why, e.g. the provider's letter and its date (required to disable)")
	actor := flags.String("actor", "", "who is making the change (default POINTY_RELAY_OPERATOR, then $USER)")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return usageError("missing provider key as the first argument (e.g. qareeb)")
	}
	provider := strings.ToLower(strings.TrimSpace(args[0]))
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if disable && strings.TrimSpace(*reason) == "" {
		return usageError("--reason is required to switch an integration off: say why, so the record answers it later")
	}
	raw, err := admin.requestJSON(
		http.MethodPut,
		"/v1/fleet/integrations/"+url.PathEscape(provider),
		nil,
		map[string]any{
			"disabled": disable,
			"reason":   strings.TrimSpace(*reason),
			"actor":    resolveActor(*actor),
		},
	)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var row integrationSwitchRow
	if err := json.Unmarshal(raw, &row); err != nil {
		return err
	}
	if row.Disabled {
		fmt.Printf(
			"%s is OFF for every shop. Each shop stops it on its next switch check (within about 5 minutes of being online).\n",
			row.Provider,
		)
	} else {
		fmt.Printf("%s is back ON for every shop, from each shop's next switch check.\n", row.Provider)
	}
	return nil
}
