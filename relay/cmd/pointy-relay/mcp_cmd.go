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
	"time"
)

// The Claude connector's grants (internal/agentmcp):
//
//	pointy-relay mcp grants                     every grant: who approved it, last use, revoked
//	pointy-relay mcp token --name "daily agent" [--days 90]
//	                                            a static read-only token for Claude Code or a
//	                                            script (claude.ai connects with OAuth instead)
//	pointy-relay mcp revoke <grant-id>          cut one connector off now
func runMCP(args []string) error {
	if len(args) == 0 {
		return usageError("missing mcp command (grants, token, revoke)")
	}
	switch args[0] {
	case "grants":
		return runMCPGrants(args[1:])
	case "token":
		return runMCPToken(args[1:])
	case "revoke":
		return runMCPRevoke(args[1:])
	default:
		return usageError("unknown mcp command %q", args[0])
	}
}

type mcpGrantView struct {
	ID             string     `json:"id"`
	Name           string     `json:"name"`
	Kind           string     `json:"kind"`
	GrantedBy      string     `json:"granted_by"`
	CreatedAt      time.Time  `json:"created_at"`
	LastUsedAt     *time.Time `json:"last_used_at"`
	AccessExpires  *time.Time `json:"access_expires_at"`
	RefreshExpires *time.Time `json:"refresh_expires_at"`
	RevokedAt      *time.Time `json:"revoked_at"`
	RevokedBy      string     `json:"revoked_by"`
}

func runMCPGrants(args []string) error {
	flags := flag.NewFlagSet("mcp grants", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/mcp/grants", nil, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var result struct {
		Grants   []mcpGrantView `json:"grants"`
		Resource string         `json:"resource"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return err
	}
	fmt.Printf("Connector URL: %s\n\n", result.Resource)
	table := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(table, "ID\tNAME\tKIND\tGRANTED BY\tCREATED\tLAST USED\tSTATE")
	for _, g := range result.Grants {
		state := "live"
		switch {
		case g.RevokedAt != nil:
			state = "revoked by " + g.RevokedBy
		case g.Kind == "token" && g.AccessExpires != nil:
			state = "expires " + g.AccessExpires.Local().Format("2006-01-02")
		}
		fmt.Fprintf(table, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", g.ID, g.Name, g.Kind, g.GrantedBy,
			g.CreatedAt.Local().Format("2006-01-02 15:04"), formatOptionalTime(g.LastUsedAt), state)
	}
	return table.Flush()
}

func formatOptionalTime(at *time.Time) string {
	if at == nil {
		return "-"
	}
	return at.Local().Format("2006-01-02 15:04")
}

func runMCPToken(args []string) error {
	flags := flag.NewFlagSet("mcp token", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	name := flags.String("name", "", "what uses the token, shown in the audit log (required)")
	days := flags.Int("days", 90, "days the token works (at most 365)")
	actor := flags.String("actor", "", "who is minting it (default POINTY_RELAY_OPERATOR, then $USER)")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*name) == "" {
		return usageError("--name is required")
	}
	raw, err := admin.requestJSON(http.MethodPost, "/v1/mcp/grants", nil, map[string]any{
		"name": *name, "days": *days, "actor": resolveActor(*actor),
	})
	if err != nil {
		return err
	}
	var result struct {
		Grant    mcpGrantView `json:"grant"`
		Token    string       `json:"token"`
		Resource string       `json:"resource"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return err
	}
	fmt.Printf("Read-only MCP token %q (grant %s), shown once:\n\n  %s\n\n", result.Grant.Name, result.Grant.ID, result.Token)
	fmt.Printf("Claude Code:\n  claude mcp add --transport http daftar %s --header \"Authorization: Bearer <token>\"\n\n", result.Resource)
	fmt.Printf("Revoke it with: pointy-relay mcp revoke %s\n", result.Grant.ID)
	return nil
}

func runMCPRevoke(args []string) error {
	flags := flag.NewFlagSet("mcp revoke", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	actor := flags.String("actor", "", "who is revoking (default POINTY_RELAY_OPERATOR, then $USER)")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return usageError("usage: pointy-relay mcp revoke <grant-id>")
	}
	if _, err := admin.requestJSON(http.MethodPost, "/v1/mcp/grants/"+url.PathEscape(flags.Arg(0))+"/revoke", nil,
		map[string]any{"actor": resolveActor(*actor)}); err != nil {
		return err
	}
	fmt.Printf("Revoked %s; its tokens stop working now.\n", flags.Arg(0))
	return nil
}
