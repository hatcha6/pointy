package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"text/tabwriter"

	"pointy/relay/internal/moamalat"
)

// buildMoamalatSealer reads POINTY_RELAY_MOAMALAT_TOKEN_KEY. Empty: the relay
// keeps no shop's token warm (the shops' backends still do).
func buildMoamalatSealer(text string, logger *slog.Logger) (*moamalat.Sealer, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		logger.Warn("the relay's Moamalat keepalive is OFF: POINTY_RELAY_MOAMALAT_TOKEN_KEY is not set (pointy-relay gen-moamalat-key); shops keep their own tokens warm alone")
		return nil, nil
	}
	key, err := moamalat.ParseKey(text)
	if err != nil {
		return nil, fmt.Errorf("POINTY_RELAY_MOAMALAT_TOKEN_KEY: %w", err)
	}
	sealer, err := moamalat.NewSealer(key)
	if err != nil {
		return nil, fmt.Errorf("POINTY_RELAY_MOAMALAT_TOKEN_KEY: %w", err)
	}
	return sealer, nil
}

// runGenMoamalatKey prints a fresh key for POINTY_RELAY_MOAMALAT_TOKEN_KEY.
func runGenMoamalatKey() error {
	key, err := moamalat.GenerateKey()
	if err != nil {
		return err
	}
	fmt.Println(key)
	return nil
}

func runMoamalat(args []string) error {
	if len(args) == 0 {
		return usageError("missing moamalat command (status)")
	}
	switch args[0] {
	case "status", "list":
		return runMoamalatStatus(args[1:])
	default:
		return usageError("unknown moamalat command %q", args[0])
	}
}

type moamalatLinkRow struct {
	InstallationID string `json:"installation_id"`
	ShopName       string `json:"shop_name"`
	MID            string `json:"mid"`
	State          string `json:"state"`
	AtRisk         bool   `json:"at_risk"`
	LastOKAt       string `json:"last_ok_at"`
	Failures       int    `json:"failures"`
	LastError      string `json:"last_error"`
	DiedAt         string `json:"died_at"`
	DeathSource    string `json:"death_source"`
}

func runMoamalatStatus(args []string) error {
	flags := flag.NewFlagSet("moamalat status", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/moamalat/admin/links", nil, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Links       []moamalatLinkRow `json:"links"`
		Available   bool              `json:"available"`
		SwitchedOff bool              `json:"switched_off"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	if !response.Available {
		fmt.Println("The relay's keepalive is OFF (POINTY_RELAY_MOAMALAT_TOKEN_KEY is not set).")
	}
	if response.SwitchedOff {
		fmt.Println("Moamalat is SWITCHED OFF fleet-wide: no token is kept warm or accepted.")
	}
	if len(response.Links) == 0 {
		fmt.Println("No shop has linked Moamalat.")
		return nil
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(writer, "SHOP\tMID\tSTATE\tLAST OK\tFAILURES\tDETAIL")
	for _, row := range response.Links {
		state := row.State
		if row.AtRisk {
			state = "AT RISK"
		}
		detail := row.LastError
		if row.DiedAt != "" {
			detail = "died " + row.DiedAt + " (seen by " + row.DeathSource + ")"
		}
		shop := row.ShopName
		if shop == "" {
			shop = row.InstallationID
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%d\t%s\n",
			shop, row.MID, state, dashIfEmpty(row.LastOKAt), row.Failures, dashIfEmpty(detail))
	}
	return writer.Flush()
}
