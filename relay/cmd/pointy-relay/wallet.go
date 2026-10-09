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
	"strings"
	"text/tabwriter"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/dafa"
	"pointy/relay/internal/ratelimit"
	relayserver "pointy/relay/internal/relay"
)

// walletSettings is the raw wallet configuration as the server command reads
// it.
type walletSettings struct {
	DafaBaseURL    string
	DafaAPIKey     string
	Methods        string
	PublicURL      string
	MinTopUp       string
	MaxTopUp       string
	QuickAmounts   string
	TopUpTTL       time.Duration
	TopUpRateLimit string
	RequestTimeout time.Duration
	// LegacyPlutu says a Plutu credential is still in the environment.
	LegacyPlutu bool
	// RemoteAccessPrice and AIPrice are what one PlanDays-long period of each
	// plan costs, paid from the wallet; empty leaves a plan unsold.
	RemoteAccessPrice string
	AIPrice           string
	PlanDays          int
}

// buildWalletConfig validates the wallet settings into the server's config.
//
// A key the relay cannot read switches top-ups OFF and says why; it does not
// stop the relay, because the relay carries every shop's remote access, AI and
// SMS, and a wallet setting must never take those down. The key's prefix is
// the environment — dafa_test_ makes only simulated payments — so a test key
// can never be booted as real money. What DOES stop the relay is a setting
// that makes no sense: bounds, a method list, a base URL.
func buildWalletConfig(settings walletSettings) (relayserver.WalletConfig, []string, error) {
	var warnings []string
	if settings.LegacyPlutu {
		warnings = append(warnings,
			"POINTY_RELAY_PLUTU_* are no longer read: Dafa replaced Plutu; set POINTY_RELAY_DAFA_API_KEY and remove them")
	}
	apiKey := strings.TrimSpace(settings.DafaAPIKey)
	testMode, known := dafa.KeyEnvironment(apiKey)
	if apiKey != "" && !known {
		warnings = append(warnings, fmt.Sprintf(
			"wallet top-ups are OFF: POINTY_RELAY_DAFA_API_KEY must start with %s or %s, the environment it pays in",
			dafa.TestKeyPrefix, dafa.LiveKeyPrefix))
		apiKey = ""
	}
	configured := apiKey != ""

	baseURL := strings.TrimRight(strings.TrimSpace(settings.DafaBaseURL), "/")
	if baseURL != "" {
		parsed, err := url.Parse(baseURL)
		if err != nil || parsed.Host == "" || parsed.RawQuery != "" ||
			(parsed.Scheme != "https" && !(parsed.Scheme == "http" && loopbackHost(parsed.Hostname()))) {
			return relayserver.WalletConfig{}, nil, fmt.Errorf(
				"POINTY_RELAY_DAFA_BASE_URL must be the https API root, e.g. %s, got %q", dafa.DefaultBaseURL, settings.DafaBaseURL)
		}
	}
	methods, err := relayserver.ParseWalletMethods(settings.Methods)
	if err != nil {
		return relayserver.WalletConfig{}, nil, fmt.Errorf("POINTY_RELAY_WALLET_METHODS: %w", err)
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

	plans, err := buildWalletPlans(settings)
	if err != nil {
		return relayserver.WalletConfig{}, nil, err
	}

	publicURL := strings.TrimRight(strings.TrimSpace(settings.PublicURL), "/")
	if publicURL != "" {
		parsed, err := url.Parse(publicURL)
		if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" ||
			(parsed.Path != "" && parsed.Path != "/") || parsed.RawQuery != "" {
			return relayserver.WalletConfig{}, nil, fmt.Errorf(
				"POINTY_RELAY_PUBLIC_URL must be the relay's public origin, e.g. https://relay.example.com, got %q", settings.PublicURL)
		}
		if parsed.Scheme == "http" && configured {
			warnings = append(warnings,
				"POINTY_RELAY_PUBLIC_URL is plain http: Dafa's webhook is not sent there, and bank-card payments are found by the sweep instead")
		}
	} else if configured {
		warnings = append(warnings,
			"POINTY_RELAY_PUBLIC_URL is empty: each top-up's webhook address is derived from the request that started it")
	}
	// Without a key there is nothing for a test mode to describe, and the
	// wallet must not claim its balance is test money.
	testMode = testMode && configured
	if testMode {
		warnings = append(warnings,
			"wallet top-ups run on a Dafa TEST key: every payment is simulated (code 111111 pays, 222222 is declined)")
	}
	return relayserver.WalletConfig{
		DafaBaseURL:    baseURL,
		DafaAPIKey:     apiKey,
		TestMode:       testMode,
		Methods:        methods,
		PublicURL:      publicURL,
		MinTopUp:       minimum.FloatString(2),
		MaxTopUp:       maximum.FloatString(2),
		QuickAmounts:   quickAmounts,
		TopUpTTL:       settings.TopUpTTL,
		TopUpRateLimit: rate,
		RequestTimeout: settings.RequestTimeout,
		Plans:          plans,
	}, warnings, nil
}

// buildWalletPlans reads what the wallet sells. A price that is not an amount
// stops the relay: shops would otherwise be offered a plan at a wrong price,
// or none at all, with nothing in the log.
func buildWalletPlans(settings walletSettings) (map[string]relayserver.WalletPlan, error) {
	days := settings.PlanDays
	if days < 0 {
		return nil, fmt.Errorf("POINTY_RELAY_PLAN_DAYS must be at least 1, got %d", settings.PlanDays)
	}
	if days == 0 {
		days = 30
	}
	plans := map[string]relayserver.WalletPlan{}
	for _, plan := range []struct {
		key, env, raw string
	}{
		{control.WalletPlanRemoteAccess, "POINTY_RELAY_REMOTE_ACCESS_PRICE", settings.RemoteAccessPrice},
		{control.WalletPlanAI, "POINTY_RELAY_AI_PRICE", settings.AIPrice},
	} {
		raw := strings.TrimSpace(plan.raw)
		if raw == "" {
			continue
		}
		price, err := control.ParseWalletAmount(raw)
		if err != nil || price.Sign() <= 0 {
			return nil, fmt.Errorf("%s must be a positive amount of dinars with at most three decimals, got %q", plan.env, plan.raw)
		}
		plans[plan.key] = relayserver.WalletPlan{Price: control.FormatWalletAmount(price), Days: days}
	}
	return plans, nil
}

// parseTopUpBound reads a positive amount of dinars with at most two places,
// the way a bound is written.
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
		return usageError("missing wallet command (list, show, topups, check, credit, debit, refund, confirm, config)")
	}
	switch args[0] {
	case "list":
		return runWalletList(args[1:])
	case "show":
		return runWalletShow(args[1:])
	case "topups":
		return runWalletTopUps(args[1:])
	case "check":
		return runWalletCheck(args[1:])
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

// walletAccountFlag registers --account: the main wallet, the SMS balance each
// message is paid from, or the voucher balance each card is paid from.
func walletAccountFlag(flags *flag.FlagSet) *string {
	return flags.String("account", control.WalletAccountMain,
		"which balance: main (the wallet), sms (paid per message) or vouchers (paid per card)")
}

func checkWalletAccount(raw string) (string, error) {
	account := control.NormalizeWalletAccount(raw)
	if !control.ValidWalletAccount(account) {
		return "", usageError("--account must be main, sms or vouchers")
	}
	return account, nil
}

// runWalletList answers "who holds how much?".
func runWalletList(args []string) error {
	flags := flag.NewFlagSet("wallet list", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	limit := flags.Int("limit", 50, "most wallets to list, largest balance first")
	accountFlag := walletAccountFlag(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	account, err := checkWalletAccount(*accountFlag)
	if err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/wallet/admin/wallets",
		url.Values{"limit": {fmt.Sprint(*limit)}, "account": {account}}, nil)
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
	Account      string `json:"account"`
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

// runWalletShow prints one shop's statement for one balance, newest first.
func runWalletShow(args []string) error {
	flags := flag.NewFlagSet("wallet show", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	limit := flags.Int("limit", 30, "most entries to show")
	accountFlag := walletAccountFlag(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	id, err := idAndFlags(args, flags)
	if err != nil {
		return err
	}
	account, err := checkWalletAccount(*accountFlag)
	if err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/wallet/admin/entries",
		url.Values{"installation_id": {id}, "limit": {fmt.Sprint(*limit)}, "account": {account}}, nil)
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
		fmt.Printf("no %s movements for this installation (balance 0.000)\n", account)
		return nil
	}
	fmt.Printf("%s balance: %s LYD\n\n", account, response.Entries[0].BalanceAfter)
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
	Method                string  `json:"method"`
	Amount                string  `json:"amount"`
	Status                string  `json:"status"`
	InvoiceNo             string  `json:"invoice_no"`
	ProviderTransactionID string  `json:"provider_transaction_id"`
	PayerHint             string  `json:"payer_hint"`
	ErrorCode             string  `json:"error_code"`
	ErrorDetail           string  `json:"error_detail"`
	ConfirmedBy           string  `json:"confirmed_by"`
	TestMode              bool    `json:"test_mode"`
	CreatedAt             string  `json:"created_at"`
	PaidAt                *string `json:"paid_at"`
}

// runWalletTopUps lists top-ups — the reconciliation view: an "expired" row
// Dafa shows as paid is a payment the sweep gave up on; "wallet check" settles it.
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
	fmt.Fprintln(writer, "TOP-UP ID\tINVOICE\tSHOP\tMETHOD\tPAYER\tAMOUNT\tSTATUS\tDAFA PAYMENT\tBY\tCREATED")
	for _, topUp := range response.TopUps {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", topUp.ID, topUp.InvoiceNo, dashIfEmpty(topUp.ShopName),
			strings.TrimPrefix(topUp.Method, "dafa_"), dashIfEmpty(topUp.PayerHint), topUp.Amount, walletTopUpStatusText(topUp),
			dashIfEmpty(topUp.ProviderTransactionID), dashIfEmpty(topUp.ConfirmedBy), topUp.CreatedAt)
	}
	return writer.Flush()
}

func walletTopUpStatusText(topUp walletTopUpRow) string {
	status := topUp.Status
	if topUp.ErrorCode != "" {
		status += " (" + topUp.ErrorCode + ")"
	}
	if topUp.TestMode {
		status += " [test]"
	}
	return status
}

// runWalletCheck asks Dafa where a top-up's payment stands, now, and credits
// it if Dafa shows it paid — the first answer to "I paid and nothing came".
func runWalletCheck(args []string) error {
	flags := flag.NewFlagSet("wallet check", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return usageError("missing top-up id or DFW- reference as the first argument")
	}
	id := strings.TrimSpace(args[0])
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodPost, "/v1/wallet/admin/topups/"+url.PathEscape(id)+"/check", nil, map[string]any{})
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		TopUp   walletTopUpRow `json:"top_up"`
		Applied bool           `json:"applied"`
		Dafa    struct {
			PaymentID string `json:"payment_id"`
			IsPaid    bool   `json:"is_paid"`
			Amount    string `json:"amount"`
			Gateway   string `json:"gateway"`
			Test      *bool  `json:"test"`
			LastError *struct {
				Code            string `json:"code"`
				ProviderMessage string `json:"provider_message"`
			} `json:"last_error"`
		} `json:"dafa"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	paid := "not paid"
	if response.Dafa.IsPaid {
		paid = "PAID"
	}
	fmt.Printf("dafa payment %s (%s): %s, %s LYD", response.Dafa.PaymentID, dashIfEmpty(response.Dafa.Gateway), paid, response.Dafa.Amount)
	if response.Dafa.Test != nil && *response.Dafa.Test {
		fmt.Print(" [test]")
	}
	fmt.Println()
	if lastError := response.Dafa.LastError; lastError != nil {
		fmt.Printf("last failed attempt: %s %s\n", lastError.Code, lastError.ProviderMessage)
	}
	switch {
	case response.Applied:
		fmt.Printf("top-up %s credited: %s LYD to %s\n", response.TopUp.InvoiceNo, response.TopUp.Amount, response.TopUp.InstallationID)
	default:
		fmt.Printf("top-up %s is %s; nothing changed\n", response.TopUp.InvoiceNo, walletTopUpStatusText(response.TopUp))
		if response.TopUp.ErrorDetail != "" {
			fmt.Printf("detail: %s\n", response.TopUp.ErrorDetail)
		}
	}
	return nil
}

// runWalletPost is credit, debit and refund: one hand-made movement with the
// operator's name and reason on it.
func runWalletPost(args []string, action string) error {
	flags := flag.NewFlagSet("wallet "+action, flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	amount := flags.String("amount", "", "dinars, up to three decimals (required)")
	reason := flags.String("reason", "", "why — it is printed on the shop's statement (required)")
	service := flags.String("service", "", "the service a debit is a charge for (remote_access, ai, sms, vouchers); a debit without one is an adjustment")
	accountFlag := walletAccountFlag(flags)
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
	account, err := checkWalletAccount(*accountFlag)
	if err != nil {
		return err
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
		"account":         account,
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
	fmt.Printf("%s %s LYD recorded on %s; balance now %s LYD\n", response.Entry.Kind, response.Entry.Amount,
		dashIfEmpty(response.Entry.Account), response.Entry.BalanceAfter)
	return nil
}

// runWalletConfirm credits by hand a top-up Dafa will not show as paid. Try
// "wallet check" first: it reads Dafa and credits what Dafa shows.
func runWalletConfirm(args []string) error {
	flags := flag.NewFlagSet("wallet confirm", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	transactionID := flags.String("transaction-id", "", "Dafa's payment id, from its dashboard (required)")
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
		return usageError("--transaction-id and --reason are required: confirm only a payment you have seen go through")
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
