package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	"pointy/relay/internal/services"
)

// runServices is the operator's side of direct top-up and bill payments, over
// the admin API (the supplier's credentials never leave the relay):
//
//	pointy-relay services directory [--country ML,NE] [--refresh] [--json]
//	pointy-relay services quote --kind airtime --operator 289 --amount 5000
//	pointy-relay services names --missing
//	pointy-relay services balance
//	pointy-relay services status
//
// A phone number or an account is never an argument of any of them: the numbers
// of customers travel only in the body of an order.
func runServices(args []string) error {
	if len(args) == 0 {
		return usageError("missing services command (directory, quote, names, balance, status)")
	}
	switch args[0] {
	case "directory":
		return runServicesDirectory(args[1:])
	case "quote":
		return runServicesQuote(args[1:])
	case "names":
		return runServicesNames(args[1:])
	case "balance":
		return runServicesBalance(args[1:])
	case "status":
		return runServicesStatus(args[1:])
	default:
		return usageError("unknown services command %q", args[0])
	}
}

func runServicesDirectory(args []string) error {
	flags := flag.NewFlagSet("services directory", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	country := flags.String("country", "", "only these countries, e.g. ML or ML,NE,NG")
	refresh := flags.Bool("refresh", false, "read Reloadly again first")
	accept := flags.Bool("accept", false, "with --refresh: believe a directory far smaller than the one in use (use when the last reading was REJECTED and Reloadly really dropped that much)")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	params := url.Values{}
	if value := strings.TrimSpace(*country); value != "" {
		params.Set("country", value)
	}
	if *refresh {
		params.Set("refresh", "1")
		if *accept {
			params.Set("accept", "1")
		}
	} else if *accept {
		return usageError("--accept goes with --refresh")
	}
	raw, err := admin.requestRaw(http.MethodGet, "/v1/services/admin/directory", params, "", nil, 3*time.Minute)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Directory services.Directory `json:"directory"`
		Stats     services.Stats     `json:"stats"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	renderServicesDirectory(os.Stdout, response.Directory, response.Stats, strings.TrimSpace(*country) != "")
	return nil
}

// renderServicesDirectory prints the directory the way an operator reads it:
// per country, its operators and billers with the amounts and what each costs
// the shop and the customer.
func renderServicesDirectory(w io.Writer, directory services.Directory, stats services.Stats, filtered bool) {
	switch {
	case !directory.Configured:
		fmt.Fprintln(w, "Services are NOT configured on this relay: set POINTY_RELAY_RELOADLY_CLIENT_ID and _CLIENT_SECRET (or POINTY_RELAY_VOUCHERS_TEST_MODE=true for the fixture).")
		return
	case directory.TestMode && stats.Sandbox:
		fmt.Fprintln(w, "SANDBOX: orders are really placed at Reloadly's sandbox (fake money); shops are told it is a test.")
	case directory.TestMode:
		fmt.Fprintln(w, "TEST MODE: orders are filled by a fake supplier; nothing is bought.")
	}
	state := "priced"
	if !directory.Priced {
		state = "NOT PRICED (no usd_rate: nothing can be sold; `pointy-relay vouchers settings set --usd-rate ...`)"
	}
	fmt.Fprintf(w, "Directory %s, %s, read from the supplier %s.\n", directory.Version, state, formatPeriodBound(directory.GeneratedAt.Format(time.RFC3339)))
	fmt.Fprintf(w, "%d countries with a service, %d without (popular first: %s).\n\n",
		len(directory.Countries), len(directory.Unsupported), strings.Join(directory.Popular, " "))
	if stats.Untranslated > 0 {
		fmt.Fprintf(w, "%d name(s) have no Arabic spelling yet and show in Latin: `pointy-relay services names --missing`.\n\n", stats.Untranslated)
	}
	for _, country := range directory.Countries {
		rank := ""
		if country.Popular > 0 {
			rank = fmt.Sprintf(" popular #%d", country.Popular)
		}
		fmt.Fprintf(w, "%s  %s / %s  +%s  %s (%s)%s\n", country.Code, country.Name, country.NameEN,
			strings.Join(country.Dial, ",+"), country.Currency, country.CurrencyName, rank)
		writer := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
		if country.Airtime != nil {
			fmt.Fprintln(writer, "  ID\tOPERATOR\tMODE\tLIMITS\tAMOUNT\tRECEIVES\tSHOP PAYS\tCUSTOMER PAYS")
			for _, operator := range country.Airtime.Operators {
				limits := "-"
				if operator.Mode == services.ModeRange {
					limits = operator.Min + ".." + operator.Max + " " + operator.AmountCurrency
				}
				approximate := ""
				if operator.Approximate {
					approximate = "≈"
				}
				for i, amount := range operator.Amounts {
					name, id, mode, lim := "", "", "", ""
					if i == 0 {
						name, id, mode, lim = operator.NameEN, fmt.Sprint(operator.ID), operator.Mode, limits
					}
					fmt.Fprintf(writer, "  %s\t%s\t%s\t%s\t%s %s\t%s%s %s\t%s\t%s\n", id, name, mode, lim,
						amount.Amount, operator.AmountCurrency, approximate, amount.Receive, amount.ReceiveCurrency,
						dashIfEmpty(amount.UnitPrice), dashIfEmpty(amount.RetailPrice))
				}
			}
		}
		if country.Bills != nil {
			fmt.Fprintln(writer, "  ID\tBILLER\tTYPE\tMODE\tLIMITS / PLAN\tAMOUNT\tSHOP PAYS\tCUSTOMER PAYS")
			for _, biller := range country.Bills.Billers {
				kind := biller.Type + "/" + biller.Service
				if biller.RequiresInvoice {
					kind += " (invoice)"
				}
				limits := "-"
				if biller.Mode == services.ModeRange {
					limits = biller.Min + ".." + biller.Max + " " + biller.AmountCurrency
				}
				id, name := fmt.Sprint(biller.ID), biller.NameEN
				for _, suggestion := range biller.Suggested {
					fmt.Fprintf(writer, "  %s\t%s\t%s\t%s\t%s\t%s %s\t%s\t%s\n", id, name, kind, biller.Mode, limits,
						suggestion.Amount, biller.AmountCurrency, dashIfEmpty(suggestion.UnitPrice), dashIfEmpty(suggestion.RetailPrice))
					id, name, kind, limits = "", "", "", ""
				}
				for _, plan := range biller.Plans {
					fmt.Fprintf(writer, "  %s\t%s\t%s\t%s\t#%d %s\t%s %s\t%s\t%s\n", id, name, kind, biller.Mode, plan.ID, plan.DescriptionEN,
						plan.Amount, biller.AmountCurrency, dashIfEmpty(plan.UnitPrice), dashIfEmpty(plan.RetailPrice))
					id, name, kind = "", "", ""
				}
			}
		}
		_ = writer.Flush()
		fmt.Fprintln(w)
	}
	if filtered && len(directory.Unsupported) > 0 {
		names := make([]string, 0, len(directory.Unsupported))
		for _, country := range directory.Unsupported {
			names = append(names, country.Code+" "+country.Name)
		}
		fmt.Fprintf(w, "No service: %s\n", strings.Join(names, ", "))
	}
}

func runServicesQuote(args []string) error {
	flags := flag.NewFlagSet("services quote", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	kind := flags.String("kind", "", "airtime or bill")
	operator := flags.Int64("operator", 0, "airtime: the operator's id (see `services directory`)")
	biller := flags.Int64("biller", 0, "bill: the biller's id")
	amount := flags.String("amount", "", "the amount, in the operator's or biller's amount currency")
	currency := flags.String("currency", "", "the amount's currency (defaults to the operator's own)")
	amountID := flags.Int64("amount-id", 0, "bill: the plan of a fixed biller")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*kind) == "" || strings.TrimSpace(*amount) == "" || (*operator <= 0 && *biller <= 0) {
		return usageError("quote needs --kind, --operator or --biller, and --amount")
	}
	body := map[string]any{"kind": strings.TrimSpace(*kind), "amount": strings.TrimSpace(*amount)}
	if *operator > 0 {
		body["operator_id"] = *operator
	}
	if *biller > 0 {
		body["biller_id"] = *biller
	}
	if value := strings.TrimSpace(*currency); value != "" {
		body["amount_currency"] = value
	}
	if *amountID > 0 {
		body["amount_id"] = *amountID
	}
	raw, err := admin.requestJSON(http.MethodPost, "/v1/services/admin/quote", nil, body)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Quote         services.Quote `json:"quote"`
		CostLYD       string         `json:"cost_lyd"`
		InDollars     bool           `json:"order_in_dollars"`
		OrderAmount   string         `json:"order_amount"`
		OrderCurrency string         `json:"order_currency"`
		OrderCostUSD  string         `json:"order_cost_usd"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	quote := response.Quote
	approximate := ""
	if quote.Approximate {
		approximate = " (approximate)"
	}
	fmt.Printf("%s\n", quote.Name)
	fmt.Printf("  the recipient receives   %s %s%s\n", quote.Receive.Amount, quote.Receive.Currency, approximate)
	fmt.Printf("  the shop pays            %s LYD\n", quote.UnitPrice)
	fmt.Printf("  the customer is asked    %s LYD\n", quote.RetailPrice)
	fmt.Printf("  it costs the company     %s LYD (%s USD at Reloadly)\n", response.CostLYD, response.OrderCostUSD)
	how := "in the local currency, no commission"
	if response.InDollars {
		how = "in dollars, keeping Reloadly's commission"
	}
	fmt.Printf("  ordered from Reloadly    %s %s, %s\n", response.OrderAmount, response.OrderCurrency, how)
	return nil
}

func runServicesNames(args []string) error {
	flags := flag.NewFlagSet("services names", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	missing := flags.Bool("missing", false, "list the names that have no Arabic spelling yet")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if !*missing {
		return usageError("names needs --missing")
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/services/admin/names", url.Values{"missing": {"1"}}, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Missing []services.MissingName `json:"missing"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	if len(response.Missing) == 0 {
		fmt.Println("Every name in the directory has an Arabic spelling.")
		return nil
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "KIND\tCOUNTRY\tNAME (shown in Latin until it is added to names_ar.json)")
	for _, name := range response.Missing {
		fmt.Fprintf(writer, "%s\t%s\t%s\n", name.Kind, dashIfEmpty(name.Country), name.Name)
	}
	_ = writer.Flush()
	fmt.Printf("\n%d name(s). Add each to relay/internal/services/names_ar.json (\"operators\", \"billers\", \"plan_words\") and redeploy.\n", len(response.Missing))
	return nil
}

func runServicesBalance(args []string) error {
	flags := flag.NewFlagSet("services balance", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestRaw(http.MethodGet, "/v1/services/admin/balance", nil, "", nil, time.Minute)
	if err != nil {
		if strings.Contains(err.Error(), "services_unconfigured") {
			return fmt.Errorf("Reloadly is not configured on this relay: set POINTY_RELAY_RELOADLY_CLIENT_ID and POINTY_RELAY_RELOADLY_CLIENT_SECRET")
		}
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Balances []services.ProductBalance `json:"balances"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "PRODUCT\tBALANCE\tFROZEN\tNOTE")
	for _, line := range response.Balances {
		if line.Error != "" {
			fmt.Fprintf(writer, "%s\t-\t-\t%s\n", line.Product, line.Error)
			continue
		}
		fmt.Fprintf(writer, "%s\t%s %s\t%s\t\n", line.Product, line.Balance, line.Currency, dashIfEmpty(line.Frozen))
	}
	_ = writer.Flush()
	fmt.Println("\nOne USD account pays for gift cards, top-ups and bills: the three lines are the same number.")
	return nil
}

func runServicesStatus(args []string) error {
	flags := flag.NewFlagSet("services status", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/services/admin/config", nil, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		Stats services.Stats `json:"stats"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	stats := response.Stats
	fmt.Printf("configured: %v   test mode: %v   sandbox: %v   supplier: %s\n", stats.Configured, stats.TestMode, stats.Sandbox, dashIfEmpty(stats.Supplier))
	fmt.Printf("directory loaded: %v   refresh interval: %s\n", stats.Loaded, stats.Interval)
	if stats.ReadAt != nil {
		fmt.Printf("last read: %s", formatPeriodBound(stats.ReadAt.Format(time.RFC3339)))
		if stats.Changed != nil {
			fmt.Printf("   last change: %s", formatPeriodBound(stats.Changed.Format(time.RFC3339)))
		}
		fmt.Println()
	}
	if stats.LastError != "" {
		fmt.Printf("last error: %s (the last good directory stands)\n", stats.LastError)
	}
	if rejected := stats.Rejected; rejected != nil {
		fmt.Printf("LAST READING REJECTED (%s): %s\n  it listed %d countries, %d operators, %d billers; the directory in use keeps %d, %d, %d.\n"+
			"  If Reloadly really dropped that much: pointy-relay services directory --refresh --accept\n",
			formatPeriodBound(rejected.At.Format(time.RFC3339)), rejected.Reason,
			rejected.Countries, rejected.Operators, rejected.Billers, rejected.KeptCountries, rejected.KeptOperators, rejected.KeptBillers)
	}
	if stats.Stale {
		fmt.Printf("STALE: the supplier was last read successfully more than %s ago, so quotes and orders are refused (service_unavailable, stale) until it is read again.\n", stats.StaleAfter)
	}
	fmt.Printf("countries: %d   operators: %d   billers: %d   names without Arabic: %d\n",
		stats.Build.Countries, stats.Build.Operators, stats.Build.Billers, stats.Untranslated)
	if len(stats.Build.Skipped) > 0 {
		fmt.Printf("left out (cannot be sold): %v\n", stats.Build.Skipped)
	}
	for _, country := range stats.Build.Dropped {
		fmt.Printf("never offered, no Arabic country name: %s\n", country)
	}
	if stats.Build.HiddenPlans > 0 {
		fmt.Printf("bill plans hidden on purpose (hiddenPlanWords): %d\n", stats.Build.HiddenPlans)
	}
	if stats.ShortDeliveries > 0 {
		fmt.Printf("top-ups that credited less than quoted since the relay started: %d\n", stats.ShortDeliveries)
	}
	return nil
}
