package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"
	"text/tabwriter"
	"time"
)

// The operator console's bootstrap: the first operator cannot invite
// themselves, so the CLI (with the admin token) mints invite links.
//
//	pointy-relay console invite --name "Hatem" [--ttl-hours 24]
//	                                   a one-time link that registers a passkey;
//	                                   an existing name adds another device
//	pointy-relay console operators     who can sign in, their devices and sessions
//	pointy-relay console disable <id>  lock an operator out (signs them out now)
//	pointy-relay console enable <id>
func runConsole(args []string) error {
	if len(args) == 0 {
		return usageError("missing console command (invite, operators, disable, enable)")
	}
	switch args[0] {
	case "invite":
		return runConsoleInvite(args[1:])
	case "operators":
		return runConsoleOperators(args[1:])
	case "disable", "enable":
		return runConsoleSetDisabled(args[0], args[1:])
	default:
		return usageError("unknown console command %q", args[0])
	}
}

func runConsoleInvite(args []string) error {
	flags := flag.NewFlagSet("console invite", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	name := flags.String("name", "", "the operator's name as shown in the console and the audit log (required)")
	ttlHours := flags.Int("ttl-hours", 24, "hours the link works (at most 168)")
	actor := flags.String("actor", "", "who is inviting (default POINTY_RELAY_OPERATOR, then $USER)")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*name) == "" {
		return usageError("--name is required")
	}
	raw, err := admin.requestJSON(http.MethodPost, "/v1/console/invites", nil, map[string]any{
		"name": *name, "ttl_hours": *ttlHours, "actor": resolveActor(*actor),
	})
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var result struct {
		Operator  struct{ Name string } `json:"operator"`
		Created   bool                  `json:"created"`
		Link      string                `json:"link"`
		ExpiresAt time.Time             `json:"expires_at"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return err
	}
	if result.Created {
		fmt.Printf("New operator %q. Open this link on their device to register a passkey:\n\n", result.Operator.Name)
	} else {
		fmt.Printf("Adds another device for %q. Open this link on that device:\n\n", result.Operator.Name)
	}
	fmt.Printf("  %s\n\n", result.Link)
	fmt.Printf("It works once, until %s. Anyone holding it can register, so send it privately.\n",
		result.ExpiresAt.Local().Format("2006-01-02 15:04"))
	return nil
}

func runConsoleOperators(args []string) error {
	flags := flag.NewFlagSet("console operators", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/console/operators", nil, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var result struct {
		Operators []struct {
			ID         string     `json:"id"`
			Name       string     `json:"name"`
			DisabledAt *time.Time `json:"disabled_at"`
			Passkeys   []struct {
				Label string `json:"label"`
			} `json:"passkeys"`
			Sessions []json.RawMessage `json:"sessions"`
		} `json:"operators"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return err
	}
	if len(result.Operators) == 0 {
		fmt.Println("No operators yet. Start with: pointy-relay console invite --name \"<your name>\"")
		return nil
	}
	table := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(table, "ID\tNAME\tSTATE\tPASSKEYS\tSESSIONS")
	for _, operator := range result.Operators {
		state := "active"
		if operator.DisabledAt != nil {
			state = "disabled"
		}
		labels := make([]string, 0, len(operator.Passkeys))
		for _, passkey := range operator.Passkeys {
			labels = append(labels, passkey.Label)
		}
		fmt.Fprintf(table, "%s\t%s\t%s\t%d %s\t%d\n", operator.ID, operator.Name, state,
			len(labels), strings.Join(labels, ", "), len(operator.Sessions))
	}
	return table.Flush()
}

func runConsoleSetDisabled(action string, args []string) error {
	flags := flag.NewFlagSet("console "+action, flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	actor := flags.String("actor", "", "who is making the change (default POINTY_RELAY_OPERATOR, then $USER)")
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return usageError("usage: pointy-relay console %s <operator id>", action)
	}
	id := strings.TrimSpace(args[0])
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if _, err := admin.requestJSON(http.MethodPost, "/v1/console/operators/"+id+"/"+action, nil,
		map[string]any{"actor": resolveActor(*actor)}); err != nil {
		return err
	}
	fmt.Printf("Operator %s %sd.\n", id, action)
	return nil
}
