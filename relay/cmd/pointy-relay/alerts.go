package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"time"

	"pointy/relay/internal/alerts"
	"pointy/relay/internal/control"
	relayserver "pointy/relay/internal/relay"
)

// The company's alert channel: an ntfy topic (on the public ntfy.sh unless
// POINTY_RELAY_NTFY_SERVER says otherwise) the relay publishes to — supplier
// and API balances running low, a supplier refusing the company's account,
// and every shop wallet payment with its amount and outcome.
//
//	pointy-relay alerts setup     generate the topic (once) and print where to subscribe
//	pointy-relay alerts rotate    replace the topic: every subscribed phone is cut off
//	pointy-relay alerts status    show the topic and where to subscribe
//	pointy-relay alerts test      send a test notification
func runAlerts(args []string) error {
	if len(args) == 0 {
		return usageError("missing alerts command (setup, rotate, status, test)")
	}
	switch args[0] {
	case "setup":
		return runAlertsTopic(args[1:], false)
	case "rotate":
		return runAlertsTopic(args[1:], true)
	case "status":
		return runAlertsStatus(args[1:])
	case "test":
		return runAlertsTest(args[1:])
	default:
		return usageError("unknown alerts command %q", args[0])
	}
}

type alertStatus struct {
	Configured   bool   `json:"configured"`
	Server       string `json:"server"`
	Topic        string `json:"topic"`
	SubscribeURL string `json:"subscribe_url"`
	Actor        string `json:"actor"`
	UpdatedAt    string `json:"updated_at"`
}

func readAlertStatus(admin *adminControlFlags) (alertStatus, json.RawMessage, error) {
	raw, err := admin.requestJSON(http.MethodGet, "/v1/alerts", nil, nil)
	if err != nil {
		return alertStatus{}, nil, err
	}
	var status alertStatus
	err = json.Unmarshal(raw, &status)
	return status, raw, err
}

func printAlertStatus(status alertStatus) {
	if !status.Configured {
		fmt.Printf("No alert topic yet (server %s). Run `pointy-relay alerts setup`.\n", status.Server)
		return
	}
	fmt.Printf("Topic:      %s\n", status.Topic)
	fmt.Printf("Subscribe:  %s\n", status.SubscribeURL)
	fmt.Printf("Set:        %s by %s\n", dashIfEmpty(status.UpdatedAt), dashIfEmpty(status.Actor))
	fmt.Println()
	fmt.Println("In the ntfy app (Android/iOS): + → topic name above; for a server other than ntfy.sh,")
	fmt.Println("tick \"Use another server\" and give its URL. Anyone with the topic name can read it: keep it private.")
}

func runAlertsStatus(args []string) error {
	flags := flag.NewFlagSet("alerts status", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	status, raw, err := readAlertStatus(admin)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	printAlertStatus(status)
	return nil
}

func runAlertsTopic(args []string, rotate bool) error {
	name := "alerts setup"
	if rotate {
		name = "alerts rotate"
	}
	flags := flag.NewFlagSet(name, flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	actor := flags.String("actor", "", "who is making the change (default POINTY_RELAY_OPERATOR, then $USER)")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if !rotate {
		status, raw, err := readAlertStatus(admin)
		if err != nil {
			return err
		}
		if status.Configured {
			// Setup is safe to repeat: it never cuts off the phones already
			// subscribed. Replacing the topic is `rotate`, on purpose.
			if *asJSON {
				return printRawJSON(raw)
			}
			fmt.Println("The alert topic is already set up (use `alerts rotate` to replace it):")
			fmt.Println()
			printAlertStatus(status)
			return nil
		}
	}
	raw, err := admin.requestJSON(http.MethodPost, "/v1/alerts/topic", nil, map[string]any{"actor": resolveActor(*actor)})
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var status alertStatus
	if err := json.Unmarshal(raw, &status); err != nil {
		return err
	}
	if rotate {
		fmt.Println("New alert topic set. Phones subscribed to the old one no longer receive alerts; resubscribe them:")
	} else {
		fmt.Println("Alert topic set. Every relay instance publishes to it within a minute.")
	}
	fmt.Println()
	printAlertStatus(status)
	fmt.Println()
	fmt.Println("Then send a test: pointy-relay alerts test")
	return nil
}

func runAlertsTest(args []string) error {
	flags := flag.NewFlagSet("alerts test", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if _, err := admin.requestJSON(http.MethodPost, "/v1/alerts/test", nil, map[string]any{}); err != nil {
		return err
	}
	fmt.Println("Test notification sent.")
	return nil
}

// --- server wiring -----------------------------------------------------------

// alertSettings are the server's alert flags.
type alertSettings struct {
	Server string
	Token  string
	Prefix string
	// ConsoleOrigin makes every alert open its console page when tapped.
	ConsoleOrigin   string
	BalanceInterval time.Duration
	ReloadlyFloor   string
	BNPlusFloor     string
	OpenRouterFloor string
	SerperFloor     string
	// OpenRouter and Serper are read with the keys the relay already holds.
	OpenRouterAPIKey        string
	OpenRouterBaseURL       string
	OpenRouterManagementKey string
	SerperAPIKey            string
	SerperBaseURL           string
}

// consoleLinkBase is where alert links point: the operator console, when it
// is served.
func consoleLinkBase(origin string) string {
	origin = strings.TrimRight(strings.TrimSpace(origin), "/")
	if origin == "" {
		return ""
	}
	return origin + "/console"
}

// buildAlerts makes the alert channel and the balance watcher over every
// provider the relay has credentials for. An empty floor leaves that balance
// unwatched; a floor that is not a number stops the relay at startup.
func buildAlerts(
	settings alertSettings,
	store control.InstallationStore,
	vouchers relayserver.VoucherConfig,
	client *http.Client,
	logger *slog.Logger,
) (*alerts.Ntfy, *alerts.BalanceWatcher, error) {
	notifier := &alerts.Ntfy{
		Server:     strings.TrimSpace(settings.Server),
		Token:      strings.TrimSpace(settings.Token),
		Prefix:     strings.TrimSpace(settings.Prefix),
		LinkBase:   consoleLinkBase(settings.ConsoleOrigin),
		Topics:     relayserver.AlertTopicSource(store),
		HTTPClient: client,
		Logger:     logger,
	}
	marks, ok := store.(control.AlertStore)
	if !ok {
		return notifier, nil, nil
	}
	watcher := &alerts.BalanceWatcher{
		Notifier: notifier,
		Marks:    marks,
		Interval: settings.BalanceInterval,
		Logger:   logger,
	}
	add := func(key, name, unit, floor string, read func() alerts.BalanceSource) error {
		floor = strings.TrimSpace(floor)
		if floor == "" {
			return nil
		}
		value, ok := new(big.Rat).SetString(floor)
		if !ok {
			return fmt.Errorf("alert floor for %s %q is not a number", key, floor)
		}
		source := read()
		source.Key, source.Name, source.Unit, source.Floor = key, name, unit, value
		if source.Link == "" {
			source.Link = "/suppliers?tab=balances"
		}
		watcher.Sources = append(watcher.Sources, source)
		return nil
	}
	var errs []error
	if vouchers.Reloadly != nil {
		errs = append(errs, add("reloadly", "Reloadly", "USD", settings.ReloadlyFloor, func() alerts.BalanceSource {
			return alerts.BalanceSource{Read: alerts.ReloadlyBalance(vouchers.Reloadly)}
		}))
	}
	if vouchers.BNPlus != nil {
		errs = append(errs, add("bnplus_lyd", "BN Plus", "LYD", settings.BNPlusFloor, func() alerts.BalanceSource {
			return alerts.BalanceSource{Read: alerts.BNPlusBalance(vouchers.BNPlus, "LYD")}
		}))
	}
	if strings.TrimSpace(settings.OpenRouterAPIKey) != "" || strings.TrimSpace(settings.OpenRouterManagementKey) != "" {
		errs = append(errs, add("openrouter", "OpenRouter", "USD", settings.OpenRouterFloor, func() alerts.BalanceSource {
			return alerts.BalanceSource{Read: alerts.OpenRouterBalance(client, settings.OpenRouterBaseURL,
				settings.OpenRouterAPIKey, settings.OpenRouterManagementKey), Link: "/integrations"}
		}))
	}
	if strings.TrimSpace(settings.SerperAPIKey) != "" {
		errs = append(errs, add("serper", "Serper", "credits", settings.SerperFloor, func() alerts.BalanceSource {
			return alerts.BalanceSource{Read: alerts.SerperBalance(client, settings.SerperBaseURL, settings.SerperAPIKey), Link: "/integrations"}
		}))
	}
	for _, err := range errs {
		if err != nil {
			return nil, nil, err
		}
	}
	return notifier, watcher, nil
}
