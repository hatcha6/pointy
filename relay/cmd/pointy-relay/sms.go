package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"pointy/relay/internal/control"
	"pointy/relay/internal/ratelimit"
	relayserver "pointy/relay/internal/relay"
)

// smsSettings is the raw SMS configuration as the server command reads it.
type smsSettings struct {
	Token                string
	BaseURL              string
	Templates            string
	TestMode             bool
	Price                string
	MonthlyLimit         int
	RateLimit            string
	RequestTimeout       time.Duration
	MaxVariableRunes     int
	DeliverySyncInterval time.Duration
}

// buildSMSConfig validates the SMS settings into the server's config. Every
// mistake here is a startup error: a relay that boots with a broken template
// map would otherwise fail each shop's sends one by one, silently.
func buildSMSConfig(settings smsSettings) (relayserver.SMSConfig, []string, error) {
	templates, warnings, err := relayserver.ParseSMSTemplates(settings.Templates)
	if err != nil {
		return relayserver.SMSConfig{}, nil, err
	}
	rate, err := ratelimit.ParsePolicy(settings.RateLimit)
	if err != nil {
		return relayserver.SMSConfig{}, nil, fmt.Errorf("POINTY_RELAY_SMS_RATE_LIMIT: %w", err)
	}
	if settings.MonthlyLimit < 0 {
		return relayserver.SMSConfig{}, nil, fmt.Errorf("POINTY_RELAY_SMS_MONTHLY_LIMIT must be 0 (no brake) or positive")
	}
	price := strings.TrimSpace(settings.Price)
	if price != "" {
		value, err := control.ParseWalletAmount(price)
		if err != nil || value.Sign() <= 0 {
			return relayserver.SMSConfig{}, nil, fmt.Errorf(
				"POINTY_RELAY_SMS_PRICE must be a positive amount of dinars with at most three decimals, got %q", settings.Price)
		}
		price = control.FormatWalletAmount(value)
	}
	if settings.MaxVariableRunes < 0 {
		return relayserver.SMSConfig{}, nil, fmt.Errorf("POINTY_RELAY_SMS_MAX_VARIABLE_RUNES must be positive")
	}
	if settings.DeliverySyncInterval < 0 {
		return relayserver.SMSConfig{}, nil, fmt.Errorf("POINTY_RELAY_SMS_DELIVERY_SYNC_INTERVAL must be 0 (off) or positive")
	}
	timeout := settings.RequestTimeout
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	token := strings.TrimSpace(settings.Token)
	if token == "" && len(templates) > 0 {
		warnings = append(warnings, "templates are configured but POINTY_RELAY_RESALA_API_TOKEN is empty; SMS stays off")
	}
	return relayserver.SMSConfig{
		BaseURL:              strings.TrimSpace(settings.BaseURL),
		Token:                token,
		Templates:            templates,
		TestMode:             settings.TestMode,
		Price:                price,
		MonthlyLimit:         settings.MonthlyLimit,
		RateLimit:            rate,
		RequestTimeout:       timeout,
		MaxVariableRunes:     settings.MaxVariableRunes,
		DeliverySyncInterval: settings.DeliverySyncInterval,
	}, warnings, nil
}

// runSMS is the operator's view of relay-hosted SMS.
func runSMS(args []string) error {
	if len(args) == 0 {
		return usageError("missing sms command (usage, log, config)")
	}
	switch args[0] {
	case "usage":
		return runSMSUsage(args[1:])
	case "log":
		return runSMSLog(args[1:])
	case "config":
		return runSMSConfig(args[1:])
	default:
		return usageError("unknown sms command %q", args[0])
	}
}

type smsUsageRow struct {
	InstallationID string         `json:"installation_id"`
	ShopName       string         `json:"shop_name"`
	Messages       int            `json:"messages"`
	Sent           int            `json:"sent"`
	Failed         int            `json:"failed"`
	Delivered      int            `json:"delivered"`
	Undelivered    int            `json:"undelivered"`
	Test           int            `json:"test"`
	Parts          int            `json:"parts"`
	Cost           string         `json:"cost"`
	Charged        string         `json:"charged"`
	LastSentAt     *string        `json:"last_sent_at"`
	Kinds          map[string]int `json:"kinds"`
}

type smsUsageResponse struct {
	From          string        `json:"from"`
	To            string        `json:"to"`
	Installations []smsUsageRow `json:"installations"`
	Totals        struct {
		Installations int    `json:"installations"`
		Messages      int    `json:"messages"`
		Sent          int    `json:"sent"`
		Failed        int    `json:"failed"`
		Delivered     int    `json:"delivered"`
		Test          int    `json:"test"`
		Parts         int    `json:"parts"`
		Cost          string `json:"cost"`
		Charged       string `json:"charged"`
	} `json:"totals"`
}

// runSMSUsage answers "which shop sends the most, and what does it cost?" —
// and whether the price per part still covers what Resala charges: MARGIN is
// what the shops paid less what Resala charged the company.
func runSMSUsage(args []string) error {
	flags := flag.NewFlagSet("sms usage", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	from := flags.String("from", "", "first day, YYYY-MM-DD (Libya time); default: start of this month")
	to := flags.String("to", "", "last day INCLUSIVE, YYYY-MM-DD (Libya time); default: end of this month")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	params := url.Values{}
	if raw := strings.TrimSpace(*from); raw != "" {
		start, err := smsReportBound(raw, false)
		if err != nil {
			return usageError("--from: %v", err)
		}
		params.Set("from", start)
	}
	if raw := strings.TrimSpace(*to); raw != "" {
		end, err := smsReportBound(raw, true)
		if err != nil {
			return usageError("--to: %v", err)
		}
		params.Set("to", end)
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/sms/usage", params, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response smsUsageResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	return renderSMSUsage(response)
}

// smsReportBound turns a CLI day into the API's instant. A day is a Libyan
// calendar day; --to includes the whole day, so it becomes the next midnight.
// An RFC3339 instant passes through unchanged.
func smsReportBound(raw string, endOfDay bool) (string, error) {
	if parsed, err := time.Parse(time.RFC3339, raw); err == nil {
		return parsed.Format(time.RFC3339), nil
	}
	day, err := time.Parse("2006-01-02", raw)
	if err != nil {
		return "", fmt.Errorf("%q is not YYYY-MM-DD", raw)
	}
	bound := control.SMSDay(day.Year(), day.Month(), day.Day())
	if endOfDay {
		bound = bound.AddDate(0, 0, 1)
	}
	return bound.Format(time.RFC3339), nil
}

// formatPeriodBound keeps a period bound in the offset the relay reports it in
// — Libya time for the default month — so "2026-09-01 00:00 +02:00" reads as
// the first of the month rather than 22:00 UTC the day before.
func formatPeriodBound(value string) string {
	parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(value))
	if err != nil {
		return dashIfEmpty(value)
	}
	return parsed.Format("2006-01-02 15:04 -07:00")
}

func renderSMSUsage(response smsUsageResponse) error {
	fmt.Printf("SMS usage %s → %s\n\n", formatPeriodBound(response.From), formatPeriodBound(response.To))
	if len(response.Installations) == 0 {
		fmt.Println("No messages in this period.")
		return nil
	}
	rows := append([]smsUsageRow(nil), response.Installations...)
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Messages > rows[j].Messages })
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "SHOP\tINSTALLATION\tMESSAGES\tSMS PARTS\tSENT\tFAILED\tDELIVERED\tCOST\tCHARGED\tMARGIN\tLAST SENT")
	for _, row := range rows {
		fmt.Fprintf(
			writer,
			"%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n",
			dashIfEmpty(row.ShopName),
			row.InstallationID,
			row.Messages,
			row.Parts,
			row.Sent,
			row.Failed,
			row.Delivered,
			dashIfEmpty(row.Cost),
			dashIfEmpty(row.Charged),
			smsMargin(row.Charged, row.Cost),
			formatTimeField(row.LastSentAt),
		)
	}
	if err := writer.Flush(); err != nil {
		return err
	}
	totals := response.Totals
	margin := smsMargin(totals.Charged, totals.Cost)
	fmt.Printf(
		"\n%d shop(s): %d message(s) in %d SMS part(s), %d sent, %d failed, %d delivered, %d test; "+
			"cost %s LYD, charged %s LYD, margin %s LYD.\n",
		totals.Installations, totals.Messages, totals.Parts, totals.Sent, totals.Failed, totals.Delivered, totals.Test,
		dashIfEmpty(totals.Cost), dashIfEmpty(totals.Charged), margin,
	)
	if strings.HasPrefix(margin, "-") {
		fmt.Println("The shops paid less than Resala charged: raise POINTY_RELAY_SMS_PRICE.")
	}
	return nil
}

// smsMargin is what the shops paid less what Resala charged, exactly.
func smsMargin(charged, cost string) string {
	if strings.TrimSpace(charged) == "" || strings.TrimSpace(cost) == "" {
		return "-"
	}
	return control.SumSMSCosts([]string{charged, "-" + strings.TrimSpace(cost)})
}

type smsLogRow struct {
	ID             string  `json:"id"`
	InstallationID string  `json:"installation_id"`
	ShopName       string  `json:"shop_name"`
	Kind           string  `json:"kind"`
	Recipient      string  `json:"recipient"`
	Status         string  `json:"status"`
	TestMode       bool    `json:"test_mode"`
	Parts          int     `json:"parts"`
	Cost           string  `json:"cost"`
	Price          string  `json:"price"`
	ErrorCode      string  `json:"error_code"`
	CreatedAt      *string `json:"created_at"`
	HeldSince      *string `json:"held_since"`
}

type smsLogResponse struct {
	Messages []smsLogRow `json:"messages"`
	Count    int         `json:"count"`
}

// runSMSLog lists recent ledger rows, newest first.
func runSMSLog(args []string) error {
	flags := flag.NewFlagSet("sms log", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	installation := flags.String("installation", "", "only this installation id")
	status := flags.String("status", "", "only this status: pending, sent, failed, delivered, undelivered")
	limit := flags.Int("limit", 50, "maximum rows (1-500)")
	asJSON := flags.Bool("json", false, "print the raw JSON response (includes full phone numbers)")
	if err := flags.Parse(args); err != nil {
		return err
	}
	params := url.Values{}
	if id := strings.TrimSpace(*installation); id != "" {
		params.Set("installation_id", id)
	}
	if value := strings.ToLower(strings.TrimSpace(*status)); value != "" {
		if !control.ValidSMSStatus(value) {
			return usageError("--status must be pending, sent, failed, delivered or undelivered")
		}
		params.Set("status", value)
	}
	if *limit < 1 || *limit > 500 {
		return usageError("--limit must be between 1 and 500")
	}
	params.Set("limit", strconv.Itoa(*limit))
	raw, err := admin.requestJSON(http.MethodGet, "/v1/sms/messages", params, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response smsLogResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	return renderSMSLog(response)
}

func renderSMSLog(response smsLogResponse) error {
	if len(response.Messages) == 0 {
		fmt.Println("No messages found.")
		return nil
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "TIME\tSHOP\tKIND\tTO\tSTATUS\tTEST\tPARTS\tCOST\tCHARGED\tERROR")
	for _, message := range response.Messages {
		shop := message.ShopName
		if strings.TrimSpace(shop) == "" {
			shop = message.InstallationID
		}
		test := ""
		if message.TestMode {
			test = "test"
		}
		// A message that never went out was given its price back — unless it
		// may still have gone out, and its price waits on the sent-log check.
		status, charged := message.Status, message.Price
		switch {
		case message.HeldSince != nil:
			status = "checking"
			charged += " held"
		case message.TestMode || message.Status == control.SMSStatusFailed:
			charged = ""
		}
		fmt.Fprintf(
			writer,
			"%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\n",
			formatTimeField(message.CreatedAt),
			dashIfEmpty(shop),
			dashIfEmpty(message.Kind),
			maskPhone(message.Recipient),
			dashIfEmpty(status),
			dashIfEmpty(test),
			max(message.Parts, 1),
			dashIfEmpty(message.Cost),
			dashIfEmpty(charged),
			dashIfEmpty(message.ErrorCode),
		)
	}
	if err := writer.Flush(); err != nil {
		return err
	}
	fmt.Printf("\n%d message(s).\n", response.Count)
	for _, message := range response.Messages {
		if message.HeldSince != nil {
			fmt.Println("\"checking\": the send failed but may have gone out; its price is held until Resala's sent log settles it.")
			break
		}
	}
	return nil
}

// maskPhone keeps a terminal (and whoever is looking over the operator's
// shoulder) from showing customers' numbers; --json has the full value.
func maskPhone(phone string) string {
	phone = strings.TrimSpace(phone)
	if len(phone) <= 6 {
		return dashIfEmpty(phone)
	}
	return phone[:3] + strings.Repeat("•", len(phone)-6) + phone[len(phone)-3:]
}

type smsConfigResponse struct {
	Configured           bool              `json:"configured"`
	TestMode             bool              `json:"test_mode"`
	BaseURL              string            `json:"base_url"`
	Templates            map[string]string `json:"templates"`
	Price                string            `json:"price"`
	MonthlyLimitDefault  int               `json:"monthly_limit_default"`
	RateLimit            string            `json:"rate_limit"`
	RequestTimeout       string            `json:"request_timeout"`
	MaxVariableRunes     int               `json:"max_variable_runes"`
	DeliverySyncInterval string            `json:"delivery_sync_interval"`
	Catalog              []struct {
		Kind         string `json:"kind"`
		ConsentClass string `json:"consent_class"`
		Variables    int    `json:"variables"`
		Configured   bool   `json:"configured"`
		TextKnown    bool   `json:"text_known"`
	} `json:"catalog"`
}

// runSMSConfig shows what the relay is configured to send, and which template
// ids are still missing. The Resala token is never part of it.
func runSMSConfig(args []string) error {
	flags := flag.NewFlagSet("sms config", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/sms/config", nil, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response smsConfigResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	return renderSMSConfig(response)
}

func renderSMSConfig(response smsConfigResponse) error {
	monthly := strconv.Itoa(response.MonthlyLimitDefault)
	if response.MonthlyLimitDefault == 0 {
		monthly = "unlimited"
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	for _, row := range [][2]string{
		{"configured", onOff(response.Configured)},
		{"test mode", onOff(response.TestMode)},
		{"base url", dashIfEmpty(response.BaseURL)},
		{"price per SMS part", dashIfEmpty(response.Price)},
		{"monthly limit (default)", monthly},
		{"rate limit", dashIfEmpty(response.RateLimit)},
		{"request timeout", dashIfEmpty(response.RequestTimeout)},
		{"max variable length", strconv.Itoa(response.MaxVariableRunes)},
		{"delivery sync", dashIfEmpty(response.DeliverySyncInterval)},
	} {
		fmt.Fprintf(writer, "%s\t%s\n", row[0], row[1])
	}
	if err := writer.Flush(); err != nil {
		return err
	}

	fmt.Println()
	writer = tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "KIND\tCONSENT\tVARS\tTEMPLATE\tTEXT")
	listed := map[string]bool{}
	missing, unseen := 0, 0
	for _, kind := range response.Catalog {
		listed[kind.Kind] = true
		templateID := response.Templates[kind.Kind]
		text := "—"
		switch {
		case templateID == "":
			templateID = "MISSING"
			missing++
		case kind.TextKnown:
			text = "known"
		default:
			text = "not sent yet"
			unseen++
		}
		fmt.Fprintf(writer, "%s\t%s\t%d\t%s\t%s\n", kind.Kind, kind.ConsentClass, kind.Variables, templateID, text)
	}
	var extra []string
	for kind := range response.Templates {
		if !listed[kind] {
			extra = append(extra, kind)
		}
	}
	sort.Strings(extra)
	for _, kind := range extra {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\n", kind, "—", "—", response.Templates[kind], "—")
	}
	if err := writer.Flush(); err != nil {
		return err
	}
	if missing > 0 {
		fmt.Printf(
			"\n%d kind(s) have no template id: their sends fail with template_not_configured.\n"+
				"Register the text in the Resala dashboard and add its id to POINTY_RELAY_SMS_TEMPLATES.\n",
			missing,
		)
	}
	if unseen > 0 {
		fmt.Printf(
			"\n%d template(s) have not been sent yet, so the relay cannot count their parts: the first\n"+
				"message of each is held as if 160 letters long, and Resala's answer gives the rest back.\n",
			unseen,
		)
	}
	return nil
}
