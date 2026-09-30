package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"text/tabwriter"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
	relayserver "pointy/relay/internal/relay"
)

// walletSettings is the raw wallet configuration as the server command reads
// it.
type walletSettings struct {
	PlutuBaseURL     string
	PlutuAPIKey      string
	PlutuAccessToken string
	PlutuSecretKey   string
	PlutuMode        string
	PublicURL        string
	MinTopUp         string
	MaxTopUp         string
	QuickAmounts     string
	TopUpTTL         time.Duration
	TopUpRateLimit   string
	RequestTimeout   time.Duration
}

// buildWalletConfig validates the wallet settings into the server's config.
//
// Half a Plutu account switches top-ups OFF and says which value is missing;
// it does not stop the relay, because the relay carries every shop's remote
// access, AI and SMS, and a wallet setting must never take those down. What
// DOES stop the relay is a complete account with no stated mode — booting in
// the wrong mode would credit test payments as real money — and bounds that
// make no sense.
func buildWalletConfig(settings walletSettings) (relayserver.WalletConfig, []string, error) {
	var warnings []string
	apiKey := strings.TrimSpace(settings.PlutuAPIKey)
	accessToken := strings.TrimSpace(settings.PlutuAccessToken)
	secretKey := strings.TrimSpace(settings.PlutuSecretKey)
	var missing []string
	for name, value := range map[string]string{
		"POINTY_RELAY_PLUTU_API_KEY":      apiKey,
		"POINTY_RELAY_PLUTU_ACCESS_TOKEN": accessToken,
		"POINTY_RELAY_PLUTU_SECRET_KEY":   secretKey,
	} {
		if value == "" {
			missing = append(missing, name)
		}
	}
	sort.Strings(missing)
	set := 3 - len(missing)
	if set != 0 && set != 3 {
		warnings = append(warnings, fmt.Sprintf(
			"wallet top-ups are OFF: the Plutu account is incomplete, %s is empty (all three are needed)",
			strings.Join(missing, " and ")))
		apiKey, accessToken, secretKey = "", "", ""
		set = 0
	}
	mode := strings.ToLower(strings.TrimSpace(settings.PlutuMode))
	testMode := false
	switch mode {
	case "test":
		testMode = true
	case "live":
	case "":
		if set == 3 {
			return relayserver.WalletConfig{}, nil, fmt.Errorf(
				"POINTY_RELAY_PLUTU_MODE must say test or live: it must match the access token, and the relay cannot tell them apart")
		}
	default:
		return relayserver.WalletConfig{}, nil, fmt.Errorf("POINTY_RELAY_PLUTU_MODE must be test or live, got %q", settings.PlutuMode)
	}

	minimum, err := parseTopUpBound("POINTY_RELAY_WALLET_TOPUP_MIN", settings.MinTopUp)
	if err != nil {
		return relayserver.WalletConfig{}, nil, err
	}
	maximum, err := parseTopUpBound("POINTY_RELAY_WALLET_TOPUP_MAX", settings.MaxTopUp)
	if err != nil {
		return relayserver.WalletConfig{}, nil, err
	}
	if minimum.Cmp(maximum) > 0 {
		return relayserver.WalletConfig{}, nil, fmt.Errorf("POINTY_RELAY_WALLET_TOPUP_MIN is above POINTY_RELAY_WALLET_TOPUP_MAX")
	}
	var quickAmounts []string
	for _, raw := range strings.Split(settings.QuickAmounts, ",") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if _, err := parseTopUpBound("POINTY_RELAY_WALLET_QUICK_AMOUNTS", raw); err != nil {
			return relayserver.WalletConfig{}, nil, err
		}
		quickAmounts = append(quickAmounts, raw)
	}
	rate, err := ratelimit.ParsePolicy(settings.TopUpRateLimit)
	if err != nil {
		return relayserver.WalletConfig{}, nil, fmt.Errorf("POINTY_RELAY_WALLET_TOPUP_RATE_LIMIT: %w", err)
	}
	if settings.TopUpTTL != 0 && settings.TopUpTTL < time.Minute {
		return relayserver.WalletConfig{}, nil, fmt.Errorf("POINTY_RELAY_WALLET_TOPUP_TTL must be at least 1m")
	}

	publicURL := strings.TrimRight(strings.TrimSpace(settings.PublicURL), "/")
	if publicURL != "" {
		parsed, err := url.Parse(publicURL)
		if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" ||
			(parsed.Path != "" && parsed.Path != "/") || parsed.RawQuery != "" {
			return relayserver.WalletConfig{}, nil, fmt.Errorf(
				"POINTY_RELAY_PUBLIC_URL must be the relay's public origin, e.g. https://relay.example.com, got %q", settings.PublicURL)
		}
		if parsed.Scheme == "http" && !loopbackHost(parsed.Hostname()) {
			warnings = append(warnings, "POINTY_RELAY_PUBLIC_URL is plain http: the payer's browser returns from the gateway unencrypted")
		}
	} else if set == 3 {
		warnings = append(warnings,
			"POINTY_RELAY_PUBLIC_URL is empty: each top-up's return address is derived from the request that started it")
	}
	// The mode describes the credentials; without them there is nothing for it
	// to describe, and the wallet must not claim its balance is test money.
	testMode = testMode && set == 3
	if testMode {
		warnings = append(warnings, "wallet top-ups run in Plutu TEST mode: every top-up is test money, capped at the sandbox's 500")
	}
	return relayserver.WalletConfig{
		PlutuBaseURL:     strings.TrimSpace(settings.PlutuBaseURL),
		PlutuAPIKey:      apiKey,
		PlutuAccessToken: accessToken,
		PlutuSecretKey:   secretKey,
		TestMode:         testMode,
		PublicURL:        publicURL,
		MinTopUp:         minimum.FloatString(2),
		MaxTopUp:         maximum.FloatString(2),
		QuickAmounts:     quickAmounts,
		TopUpTTL:         settings.TopUpTTL,
		TopUpRateLimit:   rate,
		RequestTimeout:   settings.RequestTimeout,
	}, warnings, nil
}

// parseTopUpBound reads a positive amount of dinars with the gateway's two
// places at most.
func parseTopUpBound(name, raw string) (*big.Rat, error) {
	value, err := control.ParseWalletAmount(raw)
	if err != nil || value.Sign() <= 0 || control.WalletAmountDecimals(raw) > 2 {
		return nil, fmt.Errorf("%s must be a positive amount of dinars with at most two decimals, got %q", name, raw)
	}
	return value, nil
}

func loopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// runWallet is the operator's view of the shops' wallets.
func runWallet(args []string) error {
	if len(args) == 0 {
		return usageError("missing wallet command (list, show, topups, credit, debit, refund, confirm, config)")
	}
	switch args[0] {
	case "list":
		return runWalletList(args[1:])
	case "show":
		return runWalletShow(args[1:])
	case "topups":
		return runWalletTopUps(args[1:])
	case "credit":
		return runWalletPost(args[1:], "credit")
	case "debit":
		return runWalletPost(args[1:], "debit")
	case "refund":
		return runWalletPost(args[1:], "refund")
	case "confirm":
		return runWalletConfirm(args[1:])
	case "config":
		return runWalletConfig(args[1:])
	default:
		return usageError("unknown wallet command %q", args[0])
	}
}

type walletRow struct {
	InstallationID string  `json:"installation_id"`
	ShopName       string  `json:"shop_name"`
	Balance        string  `json:"balance"`
	UpdatedAt      *string `json:"updated_at"`
}

// runWalletList answers "who holds how much?".
func runWalletList(args []string) error {
	flags := flag.NewFlagSet("wallet list", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	limit := flags.Int("limit", 50, "most wallets to list, largest balance first")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/wallet/admin/wallets", url.Values{"limit": {fmt.Sprint(*limit)}}, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Wallets []walletRow `json:"wallets"`
		Total   string      `json:"total"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "ID\tSHOP\tBALANCE (LYD)\tLAST MOVEMENT")
	for _, wallet := range response.Wallets {
		updated := "-"
		if wallet.UpdatedAt != nil {
			updated = *wallet.UpdatedAt
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", wallet.InstallationID, dashIfEmpty(wallet.ShopName), wallet.Balance, updated)
	}
	fmt.Fprintf(writer, "\t\t%s\t(total)\n", response.Total)
	return writer.Flush()
}

type walletEntryRow struct {
	ID           string `json:"id"`
	Kind         string `json:"kind"`
	Service      string `json:"service"`
	Amount       string `json:"amount"`
	BalanceAfter string `json:"balance_after"`
	Reference    string `json:"reference"`
	Description  string `json:"description"`
	Actor        string `json:"actor"`
	TestMode     bool   `json:"test_mode"`
	CreatedAt    string `json:"created_at"`
}

// runWalletShow prints one shop's statement, newest first.
func runWalletShow(args []string) error {
	flags := flag.NewFlagSet("wallet show", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	limit := flags.Int("limit", 30, "most entries to show")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/wallet/admin/entries",
		url.Values{"installation_id": {id}, "limit": {fmt.Sprint(*limit)}}, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Entries []walletEntryRow `json:"entries"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	if len(response.Entries) == 0 {
		fmt.Println("no wallet movements for this installation (balance 0.000)")
		return nil
	}
	fmt.Printf("balance: %s LYD\n\n", response.Entries[0].BalanceAfter)
	writer := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "WHEN\tKIND\tSERVICE\tAMOUNT\tBALANCE\tBY\tNOTE")
	for _, entry := range response.Entries {
		note := entry.Description
		if entry.TestMode {
			note = "[test] " + note
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", entry.CreatedAt, entry.Kind, dashIfEmpty(entry.Service),
			entry.Amount, entry.BalanceAfter, dashIfEmpty(entry.Actor), dashIfEmpty(note))
	}
	return writer.Flush()
}

type walletTopUpRow struct {
	ID                    string  `json:"id"`
	InstallationID        string  `json:"installation_id"`
	ShopName              string  `json:"shop_name"`
	Amount                string  `json:"amount"`
	Status                string  `json:"status"`
	InvoiceNo             string  `json:"invoice_no"`
	ProviderTransactionID string  `json:"provider_transaction_id"`
	ErrorCode             string  `json:"error_code"`
	ConfirmedBy           string  `json:"confirmed_by"`
	TestMode              bool    `json:"test_mode"`
	CreatedAt             string  `json:"created_at"`
	PaidAt                *string `json:"paid_at"`
}

// runWalletTopUps lists top-ups — the reconciliation view: an "expired" row
// whose invoice the gateway shows as paid is a payer who never came back.
func runWalletTopUps(args []string) error {
	flags := flag.NewFlagSet("wallet topups", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	installation := flags.String("installation", "", "only this installation")
	status := flags.String("status", "", "pending, paid, canceled, failed or expired")
	limit := flags.Int("limit", 50, "most top-ups to list")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	query := url.Values{"limit": {fmt.Sprint(*limit)}}
	if value := strings.TrimSpace(*installation); value != "" {
		query.Set("installation_id", value)
	}
	if value := strings.TrimSpace(*status); value != "" {
		query.Set("status", value)
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/wallet/admin/topups", query, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		TopUps []walletTopUpRow `json:"topups"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "TOP-UP ID\tINVOICE\tSHOP\tAMOUNT\tSTATUS\tGATEWAY TX\tBY\tCREATED")
	for _, topUp := range response.TopUps {
		status := topUp.Status
		if topUp.ErrorCode != "" {
			status += " (" + topUp.ErrorCode + ")"
		}
		if topUp.TestMode {
			status += " [test]"
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", topUp.ID, topUp.InvoiceNo, dashIfEmpty(topUp.ShopName),
			topUp.Amount, status, dashIfEmpty(topUp.ProviderTransactionID), dashIfEmpty(topUp.ConfirmedBy), topUp.CreatedAt)
	}
	return writer.Flush()
}

// runWalletPost is credit, debit and refund: one hand-made movement with the
// operator's name and reason on it.
func runWalletPost(args []string, action string) error {
	flags := flag.NewFlagSet("wallet "+action, flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	amount := flags.String("amount", "", "dinars, up to three decimals (required)")
	reason := flags.String("reason", "", "why — it is printed on the shop's statement (required)")
	service := flags.String("service", "", "the service a debit is a charge for (subscription, sms, ai, vouchers); a debit without one is an adjustment")
	reference := flags.String("reference", "", "what it is about, e.g. the entry id a refund answers")
	key := flags.String("key", "", "idempotency key; repeat it to make a retry safe")
	allowOverdraft := flags.Bool("allow-overdraft", false, "let an adjustment take the balance below zero")
	actor := flags.String("actor", "", "who is making the change (default POINTY_RELAY_OPERATOR, then $USER)")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	value, err := control.ParseWalletAmount(*amount)
	if err != nil || value.Sign() <= 0 {
		return usageError("--amount must be a positive amount of dinars")
	}
	if strings.TrimSpace(*reason) == "" {
		return usageError("--reason is required: the shop reads it on its statement")
	}
	kind := control.WalletEntryAdjustment
	signed := control.FormatWalletAmount(value)
	switch action {
	case "debit":
		signed = "-" + signed
		if strings.TrimSpace(*service) != "" {
			kind = control.WalletEntryCharge
		}
	case "refund":
		if strings.TrimSpace(*service) == "" {
			return usageError("--service is required for a refund: say which charge it gives back")
		}
		kind = control.WalletEntryRefund
	}
	raw, err := admin.requestJSON(http.MethodPost, "/v1/wallet/admin/entries", nil, map[string]any{
		"installation_id": id,
		"kind":            kind,
		"service":         strings.TrimSpace(*service),
		"amount":          signed,
		"reference":       strings.TrimSpace(*reference),
		"description":     strings.TrimSpace(*reason),
		"idempotency_key": strings.TrimSpace(*key),
		"actor":           resolveActor(*actor),
		"allow_overdraft": *allowOverdraft,
	})
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Entry   walletEntryRow `json:"entry"`
		Created bool           `json:"created"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	if !response.Created {
		fmt.Printf("already recorded (same --key): %s %s, balance %s LYD\n", response.Entry.Kind, response.Entry.Amount, response.Entry.BalanceAfter)
		return nil
	}
	fmt.Printf("%s %s LYD recorded; balance now %s LYD\n", response.Entry.Kind, response.Entry.Amount, response.Entry.BalanceAfter)
	return nil
}

// runWalletConfirm credits a top-up the payer paid but never came back from.
func runWalletConfirm(args []string) error {
	flags := flag.NewFlagSet("wallet confirm", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	transactionID := flags.String("transaction-id", "", "the gateway's transaction id, from its dashboard (required)")
	reason := flags.String("reason", "", "what you checked (required)")
	actor := flags.String("actor", "", "who is confirming (default POINTY_RELAY_OPERATOR, then $USER)")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return usageError("missing top-up id as the first argument (see: pointy-relay wallet topups --status expired)")
	}
	id := strings.TrimSpace(args[0])
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if strings.TrimSpace(*transactionID) == "" || strings.TrimSpace(*reason) == "" {
		return usageError("--transaction-id and --reason are required: confirm only what the gateway's dashboard shows as paid")
	}
	raw, err := admin.requestJSON(http.MethodPost, "/v1/wallet/admin/topups/"+url.PathEscape(id)+"/confirm", nil, map[string]any{
		"provider_transaction_id": strings.TrimSpace(*transactionID),
		"reason":                  strings.TrimSpace(*reason),
		"actor":                   resolveActor(*actor),
	})
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		TopUp   walletTopUpRow `json:"top_up"`
		Applied bool           `json:"applied"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	if !response.Applied {
		fmt.Printf("top-up %s was already paid (confirmed by %s); nothing changed\n", response.TopUp.InvoiceNo, response.TopUp.ConfirmedBy)
		return nil
	}
	fmt.Printf("top-up %s confirmed: %s LYD credited to %s\n", response.TopUp.InvoiceNo, response.TopUp.Amount, response.TopUp.InstallationID)
	return nil
}

// runWalletConfig shows what the relay's wallet is set up to do (no secrets).
func runWalletConfig(args []string) error {
	flags := flag.NewFlagSet("wallet config", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/wallet/admin/config", nil, nil)
	if err != nil {
		return err
	}
	return printRawJSON(raw)
}
