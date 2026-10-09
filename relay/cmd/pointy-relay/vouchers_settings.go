package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"

	"pointy/relay/internal/vouchers"
)

// The pricing knobs of the services the company sells besides cards — direct
// top-up and bill payments, bought from Reloadly in dollars:
//
//	pointy-relay vouchers settings show
//	pointy-relay vouchers settings set --usd-rate 9.71 --note 'October rate'
//	pointy-relay vouchers settings set --file settings.json
//	pointy-relay vouchers settings history
//
// They are published like a catalog (every version kept, the newest current).
// The numbers a fresh relay starts with are DEMONSTRATION values, not
// decisions, and every output here says which knobs are still those.

// voucherSettingsKnob is one flag of `settings set` and the field it sets.
type voucherSettingsKnob struct {
	flag  string
	usage string
	set   func(*vouchers.Settings, string)
}

var voucherSettingsKnobs = []voucherSettingsKnob{
	{"usd-rate", "dinars the company pays for one dollar, e.g. 9.71 (empty: unset, which makes Reloadly unavailable)",
		func(s *vouchers.Settings, v string) { s.USDRate = v }},
	{"funding-percent", "% fee of filling the Reloadly account (empty: the default, 0)",
		func(s *vouchers.Settings, v string) { s.FundingPercent = v }},
	{"airtime-shop-markup", "% the company adds for the shop on direct top-up (demo default 2)",
		func(s *vouchers.Settings, v string) { s.Airtime.ShopMarkupPercent = v }},
	{"airtime-retail-markup", "% suggested to the customer on direct top-up (demo default 5.5)",
		func(s *vouchers.Settings, v string) { s.Airtime.RetailMarkupPercent = v }},
	{"airtime-order-mode", "currency top-ups are ordered in: usd (default: dollars, keeps Reloadly's commission) or local (the exact local amount, no commission)",
		func(s *vouchers.Settings, v string) { s.Airtime.OrderMode = v }},
	{"airtime-usd-buffer", "% a dollar top-up order is rounded up by, so the recipient never gets less than asked (demo default 0.5)",
		func(s *vouchers.Settings, v string) { s.Airtime.USDBufferPercent = v }},
	{"airtime-service-fee", "flat dinars added on top of the margin to BOTH what the shop pays and the suggested retail; the company keeps it (demo default 2, 0 for none)",
		func(s *vouchers.Settings, v string) { s.Airtime.ServiceFeeLYD = v }},
	{"bills-service-fee", "the same flat service fee for bill payments (demo default 0)",
		func(s *vouchers.Settings, v string) { s.Bills.ServiceFeeLYD = v }},
	{"bills-shop-markup", "% the company adds for the shop on bill payments (demo default 2)",
		func(s *vouchers.Settings, v string) { s.Bills.ShopMarkupPercent = v }},
	{"bills-retail-markup", "% suggested to the customer on bill payments (demo default 5.5)",
		func(s *vouchers.Settings, v string) { s.Bills.RetailMarkupPercent = v }},
	{"bills-order-mode", "currency bills are paid in: auto (default: dollars only where cheaper and the payment need not be exact) or local (always exact)",
		func(s *vouchers.Settings, v string) { s.Bills.OrderMode = v }},
	{"bills-usd-buffer", "% a dollar bill order is rounded up by (demo default 0.5)",
		func(s *vouchers.Settings, v string) { s.Bills.USDBufferPercent = v }},
	{"retail-step", "retail prices round UP to a multiple of this many dinars (demo default 0.25)",
		func(s *vouchers.Settings, v string) { s.Margin.RoundStep = v }},
	{"min-shop-margin", "the least a shop earns on one sale, in dinars (demo default 0.10)",
		func(s *vouchers.Settings, v string) { s.Margin.MinShopMargin = v }},
	{"margin-fixed", "fixed dinars the company earns on every sale (demo default 0.50)",
		func(s *vouchers.Settings, v string) { s.Margin.FixedLYD = v }},
	{"margin-min", "the least margin on one sale, in dinars (demo default 0.50)",
		func(s *vouchers.Settings, v string) { s.Margin.MinMarginLYD = v }},
	{"margin-brackets", "marginal percentages of cost as up_to:percent pairs, the last open, e.g. 50:8,200:6,1000:5,:4",
		func(s *vouchers.Settings, v string) { s.Margin.Brackets = splitBrackets(v) }},
	{"shop-share", "% of the margin the shop keeps (default 35)",
		func(s *vouchers.Settings, v string) { s.Margin.ShopSharePercent = v }},
	{"market-gap", "% under the cheapest competitor a card is sold at (default 3)",
		func(s *vouchers.Settings, v string) { s.Margin.MarketGapPercent = v }},
	{"market-max-age", "days a competitor price is believed (default 30)",
		func(s *vouchers.Settings, v string) { s.Margin.MarketMaxAgeDays = v }},
	{"company-min-percent", "least % of cost the company keeps on a card: funding + FX risk (default 3)",
		func(s *vouchers.Settings, v string) { s.Margin.CompanyMinPct = v }},
	{"company-min-lyd", "least dinars the company keeps on a card (default 0.50)",
		func(s *vouchers.Settings, v string) { s.Margin.CompanyMinLYD = v }},
	{"shop-min-percent", "least % of retail the shop keeps on a card (default 2.5)",
		func(s *vouchers.Settings, v string) { s.Margin.ShopMinPct = v }},
	{"shop-min-lyd", "least dinars the shop keeps on a card (default 0.50)",
		func(s *vouchers.Settings, v string) { s.Margin.ShopMinLYD = v }},
	{"local-company-share", "% of a local (LYD-face) card's discount the company keeps; sold at face, the shop keeps the rest (default 20)",
		func(s *vouchers.Settings, v string) { s.Margin.LocalCompanyShare = v }},
	{"airtime-margin", "override the margin of direct top-up: fixed:min:share:brackets, blank parts inherit, e.g. 0.3:::50:8,:4",
		func(s *vouchers.Settings, v string) { s.Airtime.Margin = parseMarginOverride(v) }},
	{"bills-margin", "override the margin of bill payments (same format as --airtime-margin)",
		func(s *vouchers.Settings, v string) { s.Bills.Margin = parseMarginOverride(v) }},
	{"card-margin", "override the margin of auto-priced cards (same format as --airtime-margin)",
		func(s *vouchers.Settings, v string) { s.CardMargin = parseMarginOverride(v) }},
	{"rate-source", "where the dollar rate comes from: fulus (default, live; usd-rate is the fallback) or manual",
		func(s *vouchers.Settings, v string) { s.USDRateSource = v }},
	{"rate-series", "fulus.ly series: cash (default) or bank",
		func(s *vouchers.Settings, v string) { s.USDRateSeries = v }},
	{"rate-bank", "bank code when the series is bank",
		func(s *vouchers.Settings, v string) { s.USDRateBankCode = v }},
	{"rate-buffer", "% added on top of the live rate (default 0)",
		func(s *vouchers.Settings, v string) { s.USDRateBufferPercent = v }},
	{"rate-max-age", "a live rate older than this is stale, e.g. 48h (default)",
		func(s *vouchers.Settings, v string) { s.USDRateMaxAge = v }},
	{"popular", "country codes shown first, in order, e.g. NE,ML,NG (empty: the default list)",
		func(s *vouchers.Settings, v string) { s.Popular = splitCountryCodes(v) }},
}

// splitBrackets reads "50:8,200:6,:4" into brackets (up_to:percent).
func splitBrackets(value string) []vouchers.Bracket {
	var out []vouchers.Bracket
	for _, part := range strings.Split(value, ",") {
		if part = strings.TrimSpace(part); part == "" {
			continue
		}
		upTo, percent, _ := strings.Cut(part, ":")
		out = append(out, vouchers.Bracket{UpToLYD: strings.TrimSpace(upTo), Percent: strings.TrimSpace(percent)})
	}
	return out
}

// parseMarginOverride reads "fixed:min:share:brackets" (brackets themselves
// hold colons and commas, so they come last); nil for an empty value.
func parseMarginOverride(value string) *vouchers.Margin {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.SplitN(value, ":", 4)
	for len(parts) < 4 {
		parts = append(parts, "")
	}
	return &vouchers.Margin{FixedLYD: parts[0], MinMarginLYD: parts[1], ShopSharePercent: parts[2], Brackets: splitBrackets(parts[3])}
}

func splitCountryCodes(value string) []string {
	var codes []string
	for _, code := range strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == ' ' || r == ';' }) {
		if code = strings.TrimSpace(code); code != "" {
			codes = append(codes, code)
		}
	}
	return codes
}

// mergeVoucherSettings is base with the knobs the operator named set over it.
// A blank value is "the default" for every knob but the dollar rate, whose blank
// is "unset".
func mergeVoucherSettings(base vouchers.Settings, given map[string]string) vouchers.Settings {
	merged := base.Clone()
	for _, knob := range voucherSettingsKnobs {
		if value, ok := given[knob.flag]; ok {
			knob.set(&merged, strings.TrimSpace(value))
		}
	}
	return merged
}

// voucherSettingsAnswer mirrors what the admin route says about settings.
type voucherSettingsAnswer struct {
	Stored   bool              `json:"stored"`
	Settings vouchers.Settings `json:"settings"`
	Record   *struct {
		ID        string `json:"id"`
		SHA256    string `json:"sha256"`
		Actor     string `json:"actor"`
		Note      string `json:"note"`
		CreatedAt string `json:"created_at"`
	} `json:"record"`
	Priced    bool `json:"priced"`
	Unchanged bool `json:"unchanged"`
	// Heading, when set, replaces the line that says where the settings come
	// from (a dry run has no published version to name).
	Heading string `json:"-"`
}

func runVoucherSettings(args []string) error {
	if len(args) == 0 {
		return usageError("missing settings command (show, set, history)")
	}
	switch args[0] {
	case "show":
		return runVoucherSettingsShow(args[1:])
	case "set":
		return runVoucherSettingsSet(args[1:])
	case "history":
		return runVoucherSettingsHistory(args[1:])
	default:
		return usageError("unknown settings command %q", args[0])
	}
}

func readVoucherSettings(admin *adminControlFlags) (json.RawMessage, voucherSettingsAnswer, error) {
	raw, err := admin.requestJSON(http.MethodGet, "/v1/vouchers/admin/settings", nil, nil)
	if err != nil {
		if strings.Contains(err.Error(), "settings_unreadable") {
			// The relay keeps selling cards without a dollar rate; the operator must
			// know, and has a way out that does not read the broken document.
			return nil, voucherSettingsAnswer{}, fmt.Errorf("THE STORED VOUCHER SETTINGS CANNOT BE READ - card sales go on without a dollar rate, "+
				"so Reloadly is unpriced and sells nothing. Publish a corrected document with "+
				"`pointy-relay vouchers settings set --file settings.json` (it does not read the stored one).\n%w", err)
		}
		return nil, voucherSettingsAnswer{}, err
	}
	var answer voucherSettingsAnswer
	if err := json.Unmarshal(raw, &answer); err != nil {
		return nil, voucherSettingsAnswer{}, fmt.Errorf("unexpected answer from the relay: %w", err)
	}
	return raw, answer, nil
}

func runVoucherSettingsShow(args []string) error {
	flags := flag.NewFlagSet("vouchers settings show", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, answer, err := readVoucherSettings(admin)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	renderVoucherSettings(os.Stdout, answer)
	return nil
}

func runVoucherSettingsSet(args []string) error {
	flags := flag.NewFlagSet("vouchers settings set", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	file := flags.String("file", "", "start from this settings JSON file instead of the published settings")
	isKnob := map[string]bool{}
	for _, knob := range voucherSettingsKnobs {
		flags.String(knob.flag, "", knob.usage)
		isKnob[knob.flag] = true
	}
	note := flags.String("note", "", "why (kept with the version)")
	actor := flags.String("actor", "", "who publishes (defaults to POINTY_RELAY_OPERATOR, then $USER)")
	dryRun := flags.Bool("dry-run", false, "show the resulting settings without publishing them")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	given := map[string]string{}
	flags.Visit(func(f *flag.Flag) {
		if isKnob[f.Name] {
			given[f.Name] = f.Value.String()
		}
	})
	if *file == "" && len(given) == 0 {
		return usageError("nothing to set: pass --file, or at least one of --%s", strings.Join(voucherSettingsKnobNames(), ", --"))
	}

	// What the flags override: the file, else what is published now (the demo
	// defaults before the first version).
	var base vouchers.Settings
	if *file != "" {
		raw, err := os.ReadFile(*file)
		if err != nil {
			return err
		}
		if base, err = vouchers.ParseSettings(raw); err != nil {
			return reportVoucherSettingsProblems(os.Stderr, *file, err)
		}
	} else {
		_, answer, err := readVoucherSettings(admin)
		if err != nil {
			return err
		}
		base = answer.Settings
	}
	merged := mergeVoucherSettings(base, given)
	encoded, err := json.Marshal(merged.Normalized())
	if err != nil {
		return err
	}
	settings, err := vouchers.ParseSettings(encoded)
	if err != nil {
		return reportVoucherSettingsProblems(os.Stderr, "the settings", err)
	}

	if *dryRun {
		renderVoucherSettings(os.Stdout, voucherSettingsAnswer{
			Settings: settings,
			Priced:   settings.Priced(),
			Heading:  "DRY RUN: nothing is published. These are the settings that would be:",
		})
		return nil
	}
	body := map[string]any{}
	if err := json.Unmarshal(encoded, &body); err != nil {
		return err
	}
	body["note"] = *note
	body["actor"] = resolveActor(*actor)
	raw, err := admin.requestJSON(http.MethodPut, "/v1/vouchers/admin/settings", nil, body)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var answer voucherSettingsAnswer
	if err := json.Unmarshal(raw, &answer); err != nil {
		return printRawJSON(raw)
	}
	if answer.Unchanged {
		fmt.Println("Unchanged: the relay already uses exactly these settings.")
	} else {
		fmt.Println("Published. The relay prices with these from now on (other relay nodes within seconds); shops pick up the new prices on their next sync.")
	}
	fmt.Println()
	renderVoucherSettings(os.Stdout, answer)
	return nil
}

func voucherSettingsKnobNames() []string {
	names := make([]string, 0, len(voucherSettingsKnobs))
	for _, knob := range voucherSettingsKnobs {
		names = append(names, knob.flag)
	}
	return names
}

// reportVoucherSettingsProblems lists everything wrong with settings, one per
// line, and returns the error that stops the command.
func reportVoucherSettingsProblems(w io.Writer, what string, err error) error {
	var problems vouchers.SettingsProblems
	if errors.As(err, &problems) {
		for _, problem := range problems {
			fmt.Fprintf(w, "  %s: %s\n", problem.Path, problem.Message)
		}
		return fmt.Errorf("%d problem(s) in %s", len(problems), what)
	}
	return fmt.Errorf("%s: %w", what, err)
}

func runVoucherSettingsHistory(args []string) error {
	flags := flag.NewFlagSet("vouchers settings history", flag.ExitOnError)
	admin := registerAdminControlFlags(flags)
	limit := flags.Int("limit", 20, "how many versions")
	asJSON := flags.Bool("json", false, "print the raw JSON response")
	if err := flags.Parse(args); err != nil {
		return err
	}
	raw, err := admin.requestJSON(http.MethodGet, "/v1/vouchers/admin/settings/history", url.Values{"limit": {strconv.Itoa(*limit)}}, nil)
	if err != nil {
		return err
	}
	if *asJSON {
		return printRawJSON(raw)
	}
	var response struct {
		History []struct {
			ID        string `json:"id"`
			SHA256    string `json:"sha256"`
			Actor     string `json:"actor"`
			Note      string `json:"note"`
			CreatedAt string `json:"created_at"`
		} `json:"history"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return err
	}
	if len(response.History) == 0 {
		fmt.Println("No settings have been published: the relay runs on the demo defaults, with no dollar rate.")
		return nil
	}
	writer := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "PUBLISHED\tVERSION\tBY\tNOTE")
	for _, record := range response.History {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", formatPeriodBound(record.CreatedAt), record.ID,
			dashIfEmpty(record.Actor), dashIfEmpty(record.Note))
	}
	return writer.Flush()
}

// renderVoucherSettings prints settings the way the operator reads them: every
// knob with its value, the ones still at a demonstration value marked as such,
// and what the settings make of a ten-dollar order.
func renderVoucherSettings(w io.Writer, answer voucherSettingsAnswer) {
	settings := answer.Settings.Normalized()
	switch {
	case answer.Heading != "":
		fmt.Fprintf(w, "%s\n\n", answer.Heading)
	case answer.Record != nil:
		fmt.Fprintf(w, "Pricing settings of direct top-up and bill payments, published %s by %s%s (version %s).\n\n",
			formatPeriodBound(answer.Record.CreatedAt), dashIfEmpty(answer.Record.Actor), noteSuffix(answer.Record.Note), answer.Record.ID)
	default:
		fmt.Fprintf(w, "Pricing settings of direct top-up and bill payments: NEVER PUBLISHED, these are the demo defaults.\n\n")
	}

	demo := map[string]bool{}
	for _, path := range settings.DemoDefaults() {
		demo[path] = true
	}
	decided := func(path string) string {
		if demo[path] {
			return "DEMO DEFAULT - nobody has decided this"
		}
		return ""
	}
	writer := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	fmt.Fprintln(writer, "KNOB\tVALUE\tMEANING\t")
	rate, rateNote := settings.USDRate, "dinars the company pays for one dollar"
	if !settings.Priced() {
		rate, rateNote = "(unset)", "NOT SET - the manual fallback; Reloadly is priced by the live fulus.ly rate while usd_rate_source is fulus and one is fresh"
	}
	fmt.Fprintf(writer, "usd_rate\t%s\t%s\t\n", rate, rateNote)
	fmt.Fprintf(writer, "funding_percent\t%s\t%% added for the fee of filling the Reloadly account\t%s\n", settings.FundingPercent, decided("funding_percent"))
	fmt.Fprintf(writer, "airtime.order_mode\t%s\tusd: ordered in dollars, keeping Reloadly's commission; local: the exact local amount, no commission\t%s\n", settings.Airtime.OrderMode, decided("airtime.order_mode"))
	fmt.Fprintf(writer, "airtime.usd_buffer_percent\t%s\t%% a dollar top-up order is rounded up by, so the recipient never gets less than asked\t%s\n", settings.Airtime.USDBufferPercent, decided("airtime.usd_buffer_percent"))
	fmt.Fprintf(writer, "airtime.service_fee_lyd\t%s\tflat dinars added on top of the margin to what the shop pays AND the suggested retail; the company keeps it\t%s\n", settings.Airtime.ServiceFeeLYD, decided("airtime.service_fee_lyd"))
	fmt.Fprintf(writer, "bills.order_mode\t%s\tauto: dollars only where cheaper and the payment need not be exact; local: always exact\t%s\n", settings.Bills.OrderMode, decided("bills.order_mode"))
	fmt.Fprintf(writer, "bills.usd_buffer_percent\t%s\t%% a dollar bill order is rounded up by\t%s\n", settings.Bills.USDBufferPercent, decided("bills.usd_buffer_percent"))
	margin := settings.Margin
	fmt.Fprintf(writer, "margin.fixed_lyd\t%s\tdinars the company earns on every sale\t%s\n", margin.FixedLYD, decided("margin"))
	fmt.Fprintf(writer, "margin.min_margin_lyd\t%s\tthe least margin on one sale\t\n", margin.MinMarginLYD)
	fmt.Fprintf(writer, "margin.brackets\t%s\tmarginal %% of cost: up_to_lyd:percent\t\n", formatBrackets(margin.Brackets))
	fmt.Fprintf(writer, "margin.shop_share_percent\t%s\t%% of the margin the shop keeps (the rest is the company's)\t\n", margin.ShopSharePercent)
	fmt.Fprintf(writer, "margin.round_step\t%s\tretail prices round UP to a multiple of this many dinars\t\n", margin.RoundStep)
	fmt.Fprintf(writer, "margin.min_shop_margin\t%s\tthe least a shop earns on one sale, in dinars\t\n", margin.MinShopMargin)
	for _, o := range []struct {
		name string
		m    *vouchers.Margin
	}{{"airtime.margin", settings.Airtime.Margin}, {"bills.margin", settings.Bills.Margin}, {"card_margin", settings.CardMargin}} {
		if o.m != nil {
			fmt.Fprintf(writer, "%s\t%s\toverrides the global margin for this kind\t\n", o.name, formatMarginOverride(*o.m))
		}
	}
	fmt.Fprintf(writer, "usd_rate_source\t%s\tfulus: the live fulus.ly rate (usd_rate is the fallback); manual: usd_rate only\t\n", settings.USDRateSource)
	series := settings.USDRateSeries
	if settings.USDRateSeries == vouchers.RateSeriesBank {
		series += " " + settings.USDRateBankCode
	}
	fmt.Fprintf(writer, "usd_rate_series\t%s\tfulus.ly series\t\n", series)
	fmt.Fprintf(writer, "usd_rate_buffer_percent\t%s\t%% added on top of the live rate\t\n", settings.USDRateBufferPercent)
	fmt.Fprintf(writer, "usd_rate_max_age\t%s\ta live rate older than this is stale\t\n", settings.USDRateMaxAge)
	_ = writer.Flush()
	fmt.Fprintf(w, "\npopular (countries shown first on the till, in order): %s", strings.Join(settings.Popular, " "))
	if note := decided("popular"); note != "" {
		fmt.Fprintf(w, "\n  %s", note)
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w)

	if !settings.Priced() {
		fmt.Fprintln(w, "Reloadly is NOT PRICED: with no usd_rate every Reloadly card, top-up and bill is unavailable (rate_unset).")
		fmt.Fprintln(w, "Set it:  pointy-relay vouchers settings set --usd-rate <dinars per dollar> --note '...'")
	} else {
		fmt.Fprintf(w, "Reloadly is priced: one dollar costs the company %s dinars", settings.USDRate)
		if funded := voucherFundedDollar(settings); funded != "" {
			fmt.Fprintf(w, " (%s with the funding fee)", funded)
		}
		fmt.Fprintln(w, ".")
		for _, line := range voucherSettingsExamples(settings) {
			fmt.Fprintln(w, "  "+line)
		}
	}
	fmt.Fprintln(w)
	for _, line := range voucherMarginLadder(settings) {
		fmt.Fprintln(w, line)
	}
	if len(demo) > 0 {
		fmt.Fprintf(w, "\n%d knob(s) are still demonstration values, not decisions by the owner:\n  %s\n",
			len(demo), strings.Join(settings.DemoDefaults(), ", "))
		fmt.Fprintln(w, "They price real sales as soon as a dollar rate is set. Change them with `settings set --<knob> ...`.")
	}
}

// voucherFundedDollar is the cost of one dollar with the funding fee on top,
// "" when there is no fee.
func voucherFundedDollar(settings vouchers.Settings) string {
	fee, ok := new(big.Rat).SetString(settings.FundingPercent)
	if !ok || fee.Sign() == 0 {
		return ""
	}
	one, ok := settings.USDToLYD(big.NewRat(1, 1))
	if !ok {
		return ""
	}
	return strings.TrimRight(strings.TrimRight(one.FloatString(4), "0"), ".")
}

// voucherSettingsExamples shows what ten dollars of Reloadly's price becomes,
// for each kind of service: a sanity check on the rate and the markups.
func voucherSettingsExamples(settings vouchers.Settings) []string {
	cost, ok := settings.USDToLYD(big.NewRat(10, 1))
	if !ok {
		return nil
	}
	var lines []string
	for _, service := range []struct{ kind, label string }{
		{vouchers.ServiceKindAirtime, "direct top-up"},
		{vouchers.ServiceKindBill, "bill payment"},
	} {
		shop, retail := settings.ShopPrice(service.kind, cost), settings.RetailPrice(service.kind, cost)
		if shop == nil || retail == nil {
			continue
		}
		lines = append(lines, fmt.Sprintf("a %s that costs Reloadly 10 USD (%s LYD): the shop pays %s, the customer is asked %s",
			service.label, vouchers.FormatDinars(cost), vouchers.FormatDinars(shop), vouchers.FormatDinars(retail)))
	}
	return lines
}

func formatBrackets(brackets []vouchers.Bracket) string {
	parts := make([]string, 0, len(brackets))
	for _, b := range brackets {
		parts = append(parts, b.UpToLYD+":"+b.Percent)
	}
	return strings.Join(parts, ",")
}

func formatMarginOverride(m vouchers.Margin) string {
	return fmt.Sprintf("%s:%s:%s:%s", m.FixedLYD, m.MinMarginLYD, m.ShopSharePercent, formatBrackets(m.Brackets))
}

// voucherMarginLadder shows what the margin policy makes of a few costs: the
// margin, what the shop pays and the suggested retail price.
func voucherMarginLadder(settings vouchers.Settings) []string {
	lines := []string{"Margin ladder for direct top-up (cost in dinars -> margin + service fee, the shop pays, suggested retail):"}
	for _, cost := range []int64{20, 100, 500, 1000} {
		value := big.NewRat(cost, 1)
		prices, ok := settings.ServicePrices(vouchers.ServiceKindAirtime, value)
		if !ok {
			continue
		}
		lines = append(lines, fmt.Sprintf("  cost %s -> margin %s + service fee %s, shop pays %s, retail %s", vouchers.FormatDinars(value),
			vouchers.FormatDinars(prices.Margin), vouchers.FormatDinars(prices.Fee), vouchers.FormatDinars(prices.ShopPays), vouchers.FormatDinars(prices.Retail)))
	}
	return lines
}
